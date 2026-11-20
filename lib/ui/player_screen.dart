import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../net/session/sync_session.dart';
import '../core/session_mode.dart';
import '../modes/audio/audio_latency_control.dart';
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

  @override
  void dispose() {
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
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _showControls = !_showControls),
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
      if (_session.fileMatch == false)
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
