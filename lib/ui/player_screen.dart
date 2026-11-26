import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../net/session/sync_session.dart';
import '../core/session_mode.dart';
import '../core/audio_gain.dart';
import '../core/subtitles.dart';
import '../modes/audio/audio_latency_control.dart';
import '../platform/settings_store.dart';
import '../platform/subtitle_picker.dart';
import '../net/session/guest_session.dart';
import '../player/media_kit_engine.dart';
import '../player/playback_engine.dart';
import '../player/sync_controller.dart';
import 'ui_utils.dart';

/// Lecture synchronisée. L'écran possède la session et la ferme en sortant.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.session});

  final SyncSession session;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlaybackEngine _engine;
  VideoController? _video;
  Timer? _uiTimer;
  bool _showControls = true;
  double? _dragMs;
  bool _muted = false;
  bool _fullscreen = false;
  Timer? _hideTimer;

  /// Hôte d'un mode « son chez l'invité » (3, 5) : il peut couper son propre son.
  bool get _canMuteHost =>
      _engine is MediaKitEngine &&
      _session.isHost &&
      (_session.sessionMode == SessionMode.audioOnly ||
          _session.sessionMode == SessionMode.browserAudio);

  SyncSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _engine = _session.engine;
    final e = _engine;
    if (e is MediaKitEngine) _video = VideoController(e.player);
    if (e is MediaKitEngine) _restoreAudio(e);
    _session.addListener(_refresh);
    // Rafraîchit la barre de progression (4 Hz suffit, économie batterie).
    _uiTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _refresh(),
    );
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  static const _gainKey = 'player.gain';
  static const _boostKey = 'player.dialogBoost';

  Future<void> _restoreAudio(MediaKitEngine e) async {
    final st = SettingsStore.instance;
    final gain = await st.getDouble(_gainKey, 1.0);
    final boost = await st.getBool(_boostKey, false);
    if (gain != 1.0) await e.setGain(gain);
    if (boost) await e.setDialogBoost(true);
  }

  // ---------- Plein écran ----------
  Future<void> _setFullscreen(bool on) async {
    if (on == _fullscreen) return;
    setState(() {
      _fullscreen = on;
      _showControls = !on;
    });
    if (on) {
      await defaultEnterNativeFullscreen();
    } else {
      _hideTimer?.cancel();
      await defaultExitNativeFullscreen();
    }
  }

  /// En plein écran, les commandes réapparaissent au toucher puis se
  /// masquent seules au bout de 4 s pendant la lecture.
  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    _hideTimer?.cancel();
    if (_fullscreen && _showControls) {
      _hideTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _fullscreen && _session.isPlaying && _dragMs == null) {
          setState(() => _showControls = false);
        }
      });
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    if (_fullscreen) defaultExitNativeFullscreen();
    _uiTimer?.cancel();
    _session.removeListener(_refresh);
    _session.close().whenComplete(_engine.dispose);
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.space:
        _session.togglePlay();
      case LogicalKeyboardKey.arrowLeft:
        _session.seekBy(-10000);
      case LogicalKeyboardKey.arrowRight:
        _session.seekBy(10000);
      case LogicalKeyboardKey.keyF:
        _setFullscreen(!_fullscreen);
      case LogicalKeyboardKey.escape when _fullscreen:
        _setFullscreen(false);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Retour (Android) en plein écran : on sort du plein écran d'abord.
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) _setFullscreen(false);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_video != null)
                  Video(
                    controller: _video!,
                    controls: NoVideoControls,
                    // En arrière-plan on continue : sinon le pair dériverait.
                    pauseUponEnteringBackgroundMode: false,
                  )
                else
                  _AudioOnlyPanel(session: _session),
                if (_showControls) ..._buildOverlay(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSubtitleSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SubtitleSheet(session: _session),
    );
  }

  void _openSoundSheet() {
    final e = _engine as MediaKitEngine;
    showModalBottomSheet<void>(
      context: context,
      builder: (context) =>
          _SoundSheet(engine: e, gainKey: _gainKey, boostKey: _boostKey),
    );
  }

  List<Widget> _buildOverlay(BuildContext context) {
    final duration =
        _engine.durationMs ??
        (_session is GuestSession
            ? (_session as GuestSession).hostDurationMs
            : null) ??
        0;
    final position =
        _dragMs?.round() ??
        _session.controller.expectedPositionMs() ??
        _engine.positionMs;
    return [
      if (!_fullscreen)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Row(
              children: [
                const BackButton(color: Colors.white),
                Expanded(child: _StatusChip(session: _session)),
              ],
            ),
          ),
        ),
      if (_session.fileMatch == false && !_fullscreen)
        const Positioned(
          top: 64,
          left: 16,
          right: 16,
          child: SafeArea(
            child: Material(
              color: Colors.orange,
              borderRadius: BorderRadius.all(Radius.circular(8)),
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Attention : les deux fichiers semblent différents '
                  '(taille ou contenu). La synchro peut être décalée.',
                  style: TextStyle(color: Colors.black),
                ),
              ),
            ),
          ),
        ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: SafeArea(
          child: Container(
            color: Colors.black54,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      formatDuration(position),
                      style: const TextStyle(color: Colors.white),
                    ),
                    Expanded(
                      child: Slider(
                        value: duration > 0
                            ? position.clamp(0, duration).toDouble()
                            : 0,
                        max: duration > 0 ? duration.toDouble() : 1,
                        onChanged: duration > 0
                            ? (v) => setState(() => _dragMs = v)
                            : null,
                        onChangeEnd: (v) {
                          _session.seekTo(v.round());
                          setState(() => _dragMs = null);
                        },
                      ),
                    ),
                    Text(
                      formatDuration(duration),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.replay_10),
                      onPressed: () => _session.seekBy(-10000),
                    ),
                    IconButton(
                      color: Colors.white,
                      iconSize: 48,
                      icon: Icon(
                        _session.isPlaying
                            ? Icons.pause_circle
                            : Icons.play_circle,
                      ),
                      onPressed: _session.togglePlay,
                    ),
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.forward_10),
                      onPressed: () => _session.seekBy(10000),
                    ),
                    if (_engine is MediaKitEngine && !_muted)
                      IconButton(
                        color: Colors.white,
                        tooltip: 'Volume et dialogues',
                        icon: const Icon(Icons.tune),
                        onPressed: _openSoundSheet,
                      ),
                    if (_video != null)
                      IconButton(
                        color: Colors.white,
                        tooltip: 'Sous-titres',
                        icon: Icon(
                          _session.subtitle.isOff
                              ? Icons.subtitles_off_outlined
                              : Icons.subtitles,
                        ),
                        onPressed: _openSubtitleSheet,
                      ),
                    if (_video != null)
                      IconButton(
                        color: Colors.white,
                        tooltip: _fullscreen
                            ? 'Quitter le plein écran'
                            : 'Passer en plein écran',
                        icon: Icon(
                          _fullscreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                        ),
                        onPressed: () => _setFullscreen(!_fullscreen),
                      ),
                    if (_canMuteHost)
                      IconButton(
                        color: Colors.white,
                        tooltip: _muted
                            ? 'Rétablir le son de cet appareil'
                            : 'Couper le son de cet appareil',
                        icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
                        onPressed: () {
                          setState(() => _muted = !_muted);
                          (_engine as MediaKitEngine).setMuted(_muted);
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }
}

/// Choix des sous-titres : pistes intégrées, fichier externe, désactivés.
/// Chez l'hôte, le choix est transmis à l'invité (app ou navigateur).
class _SubtitleSheet extends StatefulWidget {
  const _SubtitleSheet({required this.session});

  final SyncSession session;

  @override
  State<_SubtitleSheet> createState() => _SubtitleSheetState();
}

class _SubtitleSheetState extends State<_SubtitleSheet> {
  late final Future<List<SubtitleSelection>> _tracks = widget.session
      .embeddedSubtitles();
  String? _error;
  bool _loading = false;

  SyncSession get _s => widget.session;

  Future<void> _select(SubtitleSelection sel, {String? text}) async {
    await _s.selectSubtitle(sel, text: text);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickFile() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final f = await pickSubtitleFile();
      if (f != null) {
        await _select(SubtitleSelection.external(f.name), text: f.text);
        return;
      }
    } on FormatException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Lecture impossible : $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final current = _s.subtitle;
    Widget option(SubtitleSelection sel, {bool enabled = true, String? sub}) =>
        ListTile(
          enabled: enabled,
          leading: Icon(
            sel == current
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
          ),
          title: Text(sel.label),
          subtitle: sub == null ? null : Text(sub),
          onTap: enabled && sel != current ? () => _select(sel) : null,
        );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                'Sous-titres',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (_s.isHost)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'La piste choisie ici s\'affiche aussi chez l\'invité.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            option(const SubtitleSelection.off()),
            FutureBuilder<List<SubtitleSelection>>(
              future: _tracks,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const ListTile(
                    leading: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    title: Text('Recherche des pistes…'),
                  );
                }
                if (snap.data!.isEmpty) {
                  return const ListTile(
                    enabled: false,
                    title: Text('Aucune piste intégrée'),
                  );
                }
                return Column(
                  children: [
                    for (final t in snap.data!)
                      option(
                        t,
                        enabled: !t.isBitmap,
                        sub: t.isBitmap
                            ? 'Sous-titres image (PGS/VobSub) : non pris en '
                                  'charge'
                            : t.codec,
                      ),
                  ],
                );
              },
            ),
            if (current.kind == SubtitleKind.external) option(current),
            ListTile(
              leading: _loading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_open),
              title: const Text('Charger un fichier (.srt, .ass, .vtt)…'),
              subtitle: _error == null
                  ? null
                  : Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
              onTap: _loading ? null : _pickFile,
            ),
          ],
        ),
      ),
    );
  }
}

/// Réglages du son local : volume jusqu'à 300 % et renfort des dialogues.
class _SoundSheet extends StatefulWidget {
  const _SoundSheet({
    required this.engine,
    required this.gainKey,
    required this.boostKey,
  });

  final MediaKitEngine engine;
  final String gainKey;
  final String boostKey;

  @override
  State<_SoundSheet> createState() => _SoundSheetState();
}

class _SoundSheetState extends State<_SoundSheet> {
  late double _gain = widget.engine.gain;
  late bool _boost = widget.engine.dialogBoost;

  @override
  Widget build(BuildContext context) {
    final pct = (_gain * 100).round();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Son', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('Volume : $pct %'),
            Slider(
              min: 0,
              max: kMaxGain,
              divisions: 30,
              value: _gain,
              label: '$pct %',
              onChanged: (v) {
                setState(() => _gain = v);
                widget.engine.setGain(v);
              },
              onChangeEnd: (v) => SettingsStore.instance.set(widget.gainKey, v),
            ),
            const Text(
              'Au-delà de 100 %, le son est amplifié (utile si l\'appareil '
              'est moins fort que l\'autre).',
              style: TextStyle(fontSize: 12),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Renforcer les dialogues'),
              subtitle: const Text(
                'Rapproche les passages faibles et forts : les voix '
                'ressortent mieux, surtout sur un film 5.1.',
              ),
              value: _boost,
              onChanged: (v) {
                setState(() => _boost = v);
                widget.engine.setDialogBoost(v);
                SettingsStore.instance.set(widget.boostKey, v);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.session});

  final SyncSession session;

  @override
  Widget build(BuildContext context) {
    final SyncStats stats = session.controller.lastStats;
    final (IconData icon, Color color, String label) = switch (session.status) {
      SessionStatus.connected => (
        Icons.link,
        Colors.greenAccent,
        'Connecté à ${session.peerName ?? '?'}',
      ),
      SessionStatus.waitingForGuest => (
        Icons.hourglass_empty,
        Colors.amber,
        'En attente de l\'invité',
      ),
      SessionStatus.connecting ||
      SessionStatus.starting => (Icons.sync, Colors.amber, 'Connexion…'),
      SessionStatus.disconnected => (
        Icons.link_off,
        Colors.redAccent,
        'Déconnecté',
      ),
      SessionStatus.error => (
        Icons.error,
        Colors.redAccent,
        session.error ?? 'Erreur',
      ),
      SessionStatus.idle => (Icons.stop, Colors.grey, 'Inactif'),
    };
    final details = [
      if (stats.driftMs != null) 'écart ${stats.driftMs} ms',
      if (stats.correcting) 'correction ${(stats.rate * 100).round()} %',
      if (session.rttMs != null) 'RTT ${session.rttMs} ms',
    ].join(' · ');
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            details.isEmpty ? label : '$label  ·  $details',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }
}

/// Mode 3, invité : pas de vidéo, réglage de la latence audio.
class _AudioOnlyPanel extends StatelessWidget {
  const _AudioOnlyPanel({required this.session});

  final SyncSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final control = s is GuestSession ? s.modeControl : null;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 72, 24, 160),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.headphones, size: 72, color: Colors.white70),
            const SizedBox(height: 12),
            const Text(
              'Audio seul : regardez l\'écran de l\'hôte,\nle son arrive dans vos écouteurs.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white),
            ),
            if (control is AudioLatencyControl)
              ListenableBuilder(
                listenable: control,
                builder: (context, _) => _LatencyCard(control: control),
              ),
          ],
        ),
      ),
    );
  }
}

class _LatencyCard extends StatelessWidget {
  const _LatencyCard({required this.control});

  final AudioLatencyControl control;

  @override
  Widget build(BuildContext context) {
    final out = control.output;
    final player = control.player;
    final auto = out.source == 'none'
        ? 'auto : non disponible (réglage manuel)'
        : 'auto : ${out.autoLatencyMs} ms${out.source == 'estimate' ? ' (estimée)' : ''}';
    return Card(
      margin: const EdgeInsets.only(top: 24),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sortie : ${out.label}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text('Latence $auto'),
            const SizedBox(height: 12),
            Text(
              'Décalage manuel : ${control.manualMs > 0 ? '+' : ''}'
              '${control.manualMs} ms',
            ),
            Slider(
              min: -500,
              max: 500,
              divisions: 100,
              value: control.manualMs.toDouble(),
              label: '${control.manualMs} ms',
              onChanged: (v) => control.setManual(v.round()),
            ),
            const Text(
              'Le son arrive après l\'image → glissez vers la droite.\n'
              'Réglage mémorisé pour cette sortie audio.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text('Volume : ${(control.gain * 100).round()} %'),
            Slider(
              min: kMinGain,
              max: kMaxGain,
              divisions: 25,
              value: control.gain,
              label: '${(control.gain * 100).round()} %',
              onChanged: control.setGain,
            ),
            const Text(
              'Au-delà de 100 %, le son est amplifié sans saturer.',
              style: TextStyle(fontSize: 12),
            ),
            if (player != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Tampon : ${player.buffer.length * 20} ms · '
                  'pertes : ${player.buffer.missing} · '
                  'compensation totale : ${control.totalMs} ms',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
