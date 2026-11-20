import 'package:media_kit/media_kit.dart';

import 'playback_engine.dart';

/// Implémentation de [PlaybackEngine] sur media_kit (libmpv) :
/// quasi tous formats, décodage matériel activé par défaut.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine()
    : player = Player(
        configuration: const PlayerConfiguration(
          title: 'App Synchro Film',
          // Cache modéré : suffisant pour un fichier local ou un flux LAN.
          bufferSize: 32 * 1024 * 1024,
        ),
      );

  /// Exposé pour le widget `Video` de media_kit_video.
  final Player player;

  @override
  Future<void> open(String source) => player.open(Media(source), play: false);

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(int positionMs) =>
      player.seek(Duration(milliseconds: positionMs));

  @override
  Future<void> setRate(double rate) => player.setRate(rate);

  /// Coupe / rétablit le son local (hôte des modes 3 et 5).
  Future<void> setMuted(bool muted) => player.setVolume(muted ? 0 : 100);

  @override
  int get positionMs => player.state.position.inMilliseconds;

  @override
  bool get isPlaying => player.state.playing;

  @override
  double get rate => player.state.rate;

  @override
  int? get durationMs {
    final d = player.state.duration.inMilliseconds;
    return d > 0 ? d : null;
  }

  @override
  bool get isBuffering => player.state.buffering;

  @override
  Future<void> dispose() => player.dispose();
}
