import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../modes/mode_handler.dart';
import '../net/discovery.dart';
import '../net/network_info.dart';
import '../net/session/host_session.dart';
import '../net/session/sync_session.dart';
import '../player/media_kit_engine.dart';
import 'player_screen.dart';
import 'ui_utils.dart';

/// Hôte : choix du fichier, démarrage de la session, QR code + mDNS.
class HostScreen extends StatefulWidget {
  const HostScreen({super.key, required this.mode});

  final ModeHandler mode;

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  HostSession? _session;
  List<String> _ips = const [];
  String? _ip;
  bool _starting = false;
  bool _handedOff = false;

  Future<void> _pickAndStart() async {
    final path = await pickMediaFile();
    if (path == null || !mounted) return;
    setState(() => _starting = true);
    final session = HostSession(
      engine: MediaKitEngine(),
      mode: widget.mode,
      filePath: path,
      deviceName: localDeviceName(),
      announcer: NsdSessionAnnouncer(),
    );
    try {
      await session.start();
      final ips = await localIPv4Addresses();
      if (!mounted) {
        await _dispose(session);
        return;
      }
      session.addListener(_onSessionChanged);
      setState(() {
        _session = session;
        _ips = ips;
        _ip = ips.isEmpty ? null : ips.first;
      });
    } catch (e) {
      await _dispose(session);
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _onSessionChanged() {
    final s = _session;
    if (s == null || !mounted) return;
    if (s.status == SessionStatus.connected && !_handedOff) _openPlayer();
    setState(() {});
  }

  void _openPlayer() {
    final s = _session!;
    _handedOff = true;
    s.removeListener(_onSessionChanged);
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => PlayerScreen(session: s),
    ));
  }

  static Future<void> _dispose(HostSession s) async {
    await s.close();
    await s.engine.dispose();
  }

  @override
  void dispose() {
    final s = _session;
    if (s != null && !_handedOff) {
      s.removeListener(_onSessionChanged);
      _dispose(s);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    return Scaffold(
      appBar: AppBar(title: Text('Hôte — ${widget.mode.title}')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: s == null ? _buildPick() : _buildWaiting(s),
          ),
        ),
      ),
    );
  }

  Widget _buildPick() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Choisissez le film à regarder ensemble.'),
          const SizedBox(height: 16),
          _starting
              ? const CircularProgressIndicator()
              : FilledButton.icon(
                  icon: const Icon(Icons.movie),
                  label: const Text('Choisir le fichier'),
                  onPressed: _pickAndStart,
                ),
        ],
      );

  Widget _buildWaiting(HostSession s) {
    final ip = _ip;
    final endpoint = ip == null ? null : s.endpointFor(ip);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(fileName(s.filePath),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        if (endpoint == null)
          const Text('Aucune adresse Wi-Fi locale trouvée. Activez le Wi-Fi '
              'ou le partage de connexion.')
        else ...[
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(
              data: endpoint.toUri().toString(),
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          SelectableText('${endpoint.host}:${endpoint.port}'
              '   code : ${endpoint.token}'),
          if (_ips.length > 1)
            DropdownButton<String>(
              value: ip,
              items: [
                for (final a in _ips)
                  DropdownMenuItem(value: a, child: Text(a)),
              ],
              onChanged: (v) => setState(() => _ip = v),
            ),
        ],
        const SizedBox(height: 24),
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('En attente de l\'invité…'),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'L\'invité voit la session automatiquement (mDNS) ou scanne le QR code.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: _openPlayer,
          child: const Text('Ouvrir le lecteur sans attendre'),
        ),
      ],
    );
  }
}
