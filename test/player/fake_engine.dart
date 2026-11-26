import 'package:app_synchro_film/core/subtitles.dart';
import 'package:app_synchro_film/player/playback_engine.dart';
import 'package:app_synchro_film/player/subtitle_engine.dart';

/// Faux lecteur piloté par une horloge simulée.
class FakeEngine implements PlaybackEngine, SubtitleEngine {
  FakeEngine({required this.now, this.durationMs = 3600000});

  int Function() now;
  @override
  int? durationMs;
  String? source;
  final List<String> calls = [];

  /// Pistes intégrées simulées et sous-titres affichés (avec texte externe).
  List<SubtitleSelection> embedded = const [];
  final List<(SubtitleSelection, String?)> shownSubtitles = [];

  @override
  Future<List<SubtitleSelection>> embeddedSubtitles() async => embedded;

  @override
  Future<void> showSubtitle(SubtitleSelection selection, {String? text}) async {
    shownSubtitles.add((selection, text));
  }

  bool _playing = false;
  double _rate = 1.0;
  int _anchorPos = 0;
  int _anchorAt = 0;

  @override
  bool isBuffering = false;

  void _reanchor() {
    _anchorPos = positionMs;
    _anchorAt = now();
  }

  /// Force une position (simule une dérive).
  void jumpTo(int pos) {
    _anchorPos = pos;
    _anchorAt = now();
  }

  @override
  int get positionMs => _playing
      ? _anchorPos + ((now() - _anchorAt) * _rate).round()
      : _anchorPos;

  @override
  bool get isPlaying => _playing;

  @override
  double get rate => _rate;

  @override
  Future<void> open(String source) async {
    calls.add('open');
    this.source = source;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    _reanchor();
    _playing = true;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _reanchor();
    _playing = false;
  }

  @override
  Future<void> seek(int positionMs) async {
    calls.add('seek:$positionMs');
    _anchorPos = positionMs;
    _anchorAt = now();
  }

  @override
  Future<void> setRate(double rate) async {
    calls.add('rate:$rate');
    _reanchor();
    _rate = rate;
  }

  @override
  Future<void> dispose() async {}
}
