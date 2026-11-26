import 'package:media_kit/media_kit.dart';

import '../core/audio_gain.dart';
import 'playback_engine.dart';

/// Filtre mpv du renfort des dialogues (compression + gain de compensation).
const String kDialogBoostMpvFilter =
    'lavfi=[acompressor=threshold=0.1:ratio=4:attack=5:release=150:makeup=2.5,'
    'alimiter=limit=0.95:level=false]';

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

  bool _muted = false;
  double _gain = 1.0;
  bool _dialogBoost = false;

  double get gain => _gain;
  bool get dialogBoost => _dialogBoost;

  /// Coupe / rétablit le son local (hôte des modes 3 et 5).
  Future<void> setMuted(bool muted) {
    _muted = muted;
    return _applyVolume();
  }

  /// Volume local de 0 à 300 % (au-delà de 100 % : amplification mpv).
  Future<void> setGain(double gain) {
    _gain = gain.clamp(0.0, kMaxGain);
    return _applyVolume();
  }

  Future<void> _applyVolume() async {
    await _configureAudio();
    await player.setVolume(_muted ? 0 : _gain * 100);
  }

  bool _configured = false;

  /// mpv : volume jusqu'à 300 % et downmix multicanal sans normalisation
  /// (sinon les dialogues du canal central sont nettement plus faibles).
  Future<void> _configureAudio() async {
    if (_configured) return;
    _configured = true;
    final p = player.platform;
    if (p is NativePlayer) {
      await p.setProperty('volume-max', '${(kMaxGain * 100).round()}');
      await p.setProperty('audio-normalize-downmix', 'no');
    }
  }

  /// Renfort des dialogues : compresseur léger (sons forts atténués, sons
  /// faibles remontés), latence négligeable.
  Future<void> setDialogBoost(bool on) async {
    _dialogBoost = on;
    await _configureAudio();
    final p = player.platform;
    if (p is NativePlayer) {
      await p.setProperty('af', on ? kDialogBoostMpvFilter : '');
    }
  }

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
