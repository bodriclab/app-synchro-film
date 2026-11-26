import 'package:media_kit/media_kit.dart';

import '../core/audio_gain.dart';
import '../core/subtitles.dart';
import 'playback_engine.dart';
import 'subtitle_engine.dart';

/// Filtre mpv du renfort des dialogues (compression + gain de compensation).
const String kDialogBoostMpvFilter =
    'lavfi=[acompressor=threshold=0.1:ratio=4:attack=5:release=150:makeup=2.5,'
    'alimiter=limit=0.95:level=false]';

/// Implémentation de [PlaybackEngine] sur media_kit (libmpv) :
/// quasi tous formats, décodage matériel activé par défaut.
class MediaKitEngine implements PlaybackEngine, SubtitleEngine {
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
  Future<void> open(String source) async {
    final p = player.platform;
    // Pas de chargement automatique d'un .srt voisin : la liste des pistes
    // intégrées reste identique chez l'hôte et l'invité.
    if (p is NativePlayer) await p.setProperty('sub-auto', 'no');
    await player.open(Media(source), play: false);
  }

  @override
  Future<List<SubtitleSelection>> embeddedSubtitles() async {
    final p = player.platform;
    if (p is! NativePlayer) return const [];
    // Les pistes arrivent après l'ouverture : on patiente un peu.
    for (var attempt = 0; attempt < 20; attempt++) {
      final list = await _readEmbedded(p);
      if (list != null) return list.map((e) => e.$2).toList();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return const [];
  }

  /// (id mpv, sélection) des pistes intégrées ; null si pas encore chargé.
  Future<List<(String, SubtitleSelection)>?> _readEmbedded(
    NativePlayer p,
  ) async {
    final count = int.tryParse(await p.getProperty('track-list/count')) ?? 0;
    if (count == 0) return null;
    final out = <(String, SubtitleSelection)>[];
    for (var i = 0; i < count; i++) {
      Future<String> prop(String name) async {
        try {
          return await p.getProperty('track-list/$i/$name');
        } catch (_) {
          return '';
        }
      }

      if (await prop('type') != 'sub') continue;
      if (await prop('external') == 'yes') continue;
      final title = await prop('title');
      final lang = await prop('lang');
      final codec = await prop('codec');
      out.add((
        await prop('id'),
        SubtitleSelection.embedded(
          out.length,
          title: title.isEmpty ? null : title,
          language: lang.isEmpty ? null : lang,
          codec: codec.isEmpty ? null : codec,
        ),
      ));
    }
    return out;
  }

  @override
  Future<void> showSubtitle(SubtitleSelection selection, {String? text}) async {
    switch (selection.kind) {
      case SubtitleKind.off:
        await player.setSubtitleTrack(SubtitleTrack.no());
      case SubtitleKind.external:
        if (text == null) return;
        await player.setSubtitleTrack(
          SubtitleTrack.data(text, title: selection.name),
        );
      case SubtitleKind.embedded:
        final p = player.platform;
        if (p is! NativePlayer) return;
        for (var attempt = 0; attempt < 20; attempt++) {
          final list = await _readEmbedded(p);
          if (list != null) {
            if (selection.index! < list.length) {
              final id = list[selection.index!].$1;
              await player.setSubtitleTrack(SubtitleTrack(id, null, null));
            }
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
    }
  }

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
