import 'dart:async';

import '../core/constants.dart';
import '../core/monotonic_clock.dart';
import '../core/playback_state.dart';
import 'playback_engine.dart';
import 'soft_correction.dart';

/// Statistiques exposées à l'UI (indicateur de synchro).
class SyncStats {
  const SyncStats({this.driftMs, this.rate = 1.0, this.correcting = false});
  final int? driftMs;
  final double rate;
  final bool correcting;
}

/// Fait suivre à un [PlaybackEngine] l'état de référence de l'hôte.
///
/// Utilisé des deux côtés : l'hôte et l'invité suivent la même « timeline »
/// virtuelle ancrée sur l'horloge hôte, ce qui rend la logique symétrique.
class SyncController {
  SyncController({
    required this.engine,
    required this.clock,
    required this.localNowMs,
    SoftCorrector? corrector,
    this.tick = kCorrectionTick,
    this.isReady,
  }) : corrector = corrector ?? SoftCorrector();

  final PlaybackEngine engine;
  final SharedClock clock;
  final SoftCorrector corrector;
  final Duration tick;
  final int Function() localNowMs;

  /// Faux tant que l'horloge partagée n'est pas fiable (invité qui vient
  /// de se connecter) : l'état est mémorisé mais pas encore appliqué.
  final bool Function()? isReady;

  final _stats = StreamController<SyncStats>.broadcast();
  Timer? _timer;
  PlaybackState? _target;
  bool _busy = false;
  SyncStats _last = const SyncStats();

  Stream<SyncStats> get stats => _stats.stream;
  SyncStats get lastStats => _last;
  PlaybackState? get target => _target;

  /// Position attendue maintenant selon l'état de référence.
  int? expectedPositionMs() =>
      _target?.positionAt(clock.hostNowMs(), durationMs: engine.durationMs);

  void start() {
    _timer ??= Timer.periodic(tick, (_) => step());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Nouvel état de référence (reçu de l'hôte ou produit par l'arbitre).
  Future<void> applyState(PlaybackState state) async {
    final previous = _target;
    if (previous != null && state.seq < previous.seq) return; // obsolète
    _target = state;
    final changedTimeline =
        previous == null ||
        previous.playing != state.playing ||
        previous.positionMs != state.positionMs ||
        previous.atHostMs != state.atHostMs;
    if (changedTimeline) corrector.reset();
    await step();
  }

  /// Une itération de la boucle de correction (publique pour les tests).
  Future<void> step() async {
    final target = _target;
    if (target == null || _busy) return;
    if (isReady != null && !isReady!()) return;
    _busy = true;
    try {
      final expected = target.positionAt(
        clock.hostNowMs(),
        durationMs: engine.durationMs,
      );

      if (target.playing != engine.isPlaying) {
        // Changement play/pause : on se cale puis on bascule.
        if ((engine.positionMs - expected).abs() >= corrector.deadbandMs) {
          await engine.seek(expected);
        }
        if (target.playing) {
          await engine.play();
        } else {
          await engine.pause();
        }
        if (engine.rate != target.rate) await engine.setRate(target.rate);
        corrector.reset();
        _publish(engine.positionMs - expected);
        return;
      }

      if (engine.isBuffering) return;

      final drift = engine.positionMs - expected;
      final c = corrector.update(
        driftMs: drift,
        targetPositionMs: expected,
        playing: target.playing,
        nowMs: localNowMs(),
        baseRate: target.rate,
      );
      if (c.kind == CorrectionKind.seek) await engine.seek(c.seekToMs!);
      if ((engine.rate - c.rate).abs() > 1e-6) await engine.setRate(c.rate);
      _publish(drift);
    } finally {
      _busy = false;
    }
  }

  void _publish(int drift) {
    _last = SyncStats(
      driftMs: drift,
      rate: engine.rate,
      correcting: corrector.isCorrecting,
    );
    if (!_stats.isClosed) _stats.add(_last);
  }

  Future<void> dispose() async {
    stop();
    await _stats.close();
  }
}
