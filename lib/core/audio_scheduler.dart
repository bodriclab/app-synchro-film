import 'audio_packet.dart';

/// Décide quelles trames pousser dans la sortie audio de l'invité (mode 3),
/// et quand.
///
/// Principe : la sortie audio est une file à débit constant. Une trame
/// poussée maintenant sera entendue à `fin de la file + latence de sortie`.
/// On choisit donc la trame dont la position dans le film correspond à la
/// position attendue (timeline de l'hôte) à cet instant-là.
///
/// - Latence de sortie = latence auto (OS, Bluetooth) + réglage manuel.
/// - Écart > [resyncThresholdMs] entre la trame suivante naturelle et la
///   position attendue → on saute / répète des trames (resynchronisation).
/// - En pause : on ne pousse rien.
class AudioPlayoutScheduler {
  AudioPlayoutScheduler({this.targetFillMs = 80, this.resyncThresholdMs = 40});

  /// Quantité d'audio qu'on garde d'avance dans la file de sortie.
  final int targetFillMs;
  final int resyncThresholdMs;

  int? _nextIndex;
  int? _queueEndsAt; // heure locale de fin de lecture de la file
  int resyncs = 0;

  /// Dernier index planifié (pour ignorer les paquets arrivés trop tard).
  int? get lastPlannedIndex => _nextIndex == null ? null : _nextIndex! - 1;

  /// Heure locale (ms) à laquelle la file de sortie sera vide.
  int? get queueEndsAt => _queueEndsAt;

  /// À appeler quand la sortie a manqué de données (underrun) ou après pause.
  void reset() {
    _nextIndex = null;
    _queueEndsAt = null;
  }

  /// Planifie les trames à pousser maintenant.
  ///
  /// [expectedPositionAt] : position attendue (ms) à une heure locale donnée,
  /// ou null si la lecture est en pause.
  List<int> plan({
    required int nowMs,
    required int? Function(int localMs) expectedPositionAt,
    required int outputLatencyMs,
  }) {
    final out = <int>[];
    var end = _queueEndsAt;
    if (end == null || end < nowMs) {
      // File vide (démarrage, underrun) : on repart de maintenant.
      end = nowMs;
      _nextIndex = null;
    }
    while (end! < nowMs + targetFillMs) {
      final heardAt = end + outputLatencyMs;
      final expected = expectedPositionAt(heardAt);
      if (expected == null) {
        reset();
        return out;
      }
      final next = _nextIndex;
      if (next == null ||
          (next * kAudioFrameMs - expected).abs() > resyncThresholdMs) {
        if (next != null) resyncs++;
        _nextIndex = (expected / kAudioFrameMs).round();
      }
      out.add(_nextIndex!);
      _nextIndex = _nextIndex! + 1;
      end += kAudioFrameMs;
    }
    _queueEndsAt = end;
    return out;
  }
}
