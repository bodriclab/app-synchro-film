import 'playback_engine.dart';

/// Lecteur « virtuel » sans média : une simple position qui avance avec le
/// temps. Sert à l'invité du mode 3 (audio seul) pour réutiliser la même
/// synchro (SyncController, commandes, barre de progression).
class VirtualEngine implements PlaybackEngine {
  VirtualEngine({int Function()? nowMs, this.durationMs})
    : _now = nowMs ?? _stopwatchNow;

  static final Stopwatch _sw = Stopwatch()..start();
  static int _stopwatchNow() => _sw.elapsedMilliseconds;

  final int Function() _now;
  bool _playing = false;
  double _rate = 1.0;
  int _anchorPos = 0;
  int _anchorAt = 0;

  @override
  int? durationMs;

  @override
  bool get isBuffering => false;

  void _reanchor() {
    _anchorPos = positionMs;
    _anchorAt = _now();
  }

  @override
  int get positionMs => _playing
      ? _anchorPos + ((_now() - _anchorAt) * _rate).round()
      : _anchorPos;

  @override
  bool get isPlaying => _playing;

  @override
  double get rate => _rate;

  @override
  Future<void> open(String source) async {}

  @override
  Future<void> play() async {
    _reanchor();
    _playing = true;
  }

  @override
  Future<void> pause() async {
    _reanchor();
    _playing = false;
  }

  @override
  Future<void> seek(int positionMs) async {
    _anchorPos = positionMs < 0 ? 0 : positionMs;
    _anchorAt = _now();
  }

  @override
  Future<void> setRate(double rate) async {
    _reanchor();
    _rate = rate;
  }

  @override
  Future<void> dispose() async {}
}
