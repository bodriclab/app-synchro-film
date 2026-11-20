import 'dart:io';

import 'package:flutter/material.dart';

import '../core/media_source.dart';
import '../core/session_endpoint.dart';
import '../modes/mode_handler.dart';
import '../modes/mode_registry.dart';
import '../net/discovery.dart';
import '../net/session/guest_session.dart';
import '../platform/media_access.dart';
import '../player/media_kit_engine.dart';
import 'player_screen.dart';
import 'qr_scan_screen.dart';
import 'ui_utils.dart';

/// Invité : (mode 1) choix du fichier local, puis connexion via mDNS,
/// QR code (Android) ou saisie manuelle de l'adresse.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, required this.mode});

  final ModeHandler mode;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final SessionBrowser _browser = SessionBrowser();
  final _addressCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  MediaRef? _localMedia;
  bool _askFile = false;
  bool _connecting = false;
  String? _discoveryError;

  bool get _canScan => Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    _browser.start().catchError((Object e) {
      if (mounted) setState(() => _discoveryError = '$e');
    });
  }

  @override
  void dispose() {
    _browser.dispose();
    _addressCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final media = await pickMedia();
    if (media != null && mounted) setState(() => _localMedia = media);
  }

  Future<void> _scan() async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (value == null || !mounted) return;
    final ep = SessionEndpoint.tryParse(value);
    if (ep == null) {
      showError(context, 'QR code non reconnu');
      return;
    }
    await _connect(ep);
  }

  Future<void> _connectManual() async {
    final ep = SessionEndpoint.tryParse(
      _addressCtrl.text,
      fallbackToken: _tokenCtrl.text.trim(),
    );
    if (ep == null) {
      showError(context, 'Adresse ou code invalide (ex. 192.168.43.1:47470)');
      return;
    }
    await _connect(ep);
  }

  Future<void> _connect(SessionEndpoint endpoint) async {
    // Le mode réel est celui annoncé par l'hôte (QR / mDNS).
    final mode = modeHandlerFor(endpoint.mode);
    if (!mode.isImplemented) {
      showError(context, '« ${mode.title} » n\'est pas encore disponible');
      return;
    }
    if (mode.guestNeedsLocalFile && _localMedia == null) {
      setState(() => _askFile = true);
      showError(context, 'Choisissez d\'abord votre copie du film');
      return;
    }
    setState(() => _connecting = true);
    final engine = MediaKitEngine();
    final session = GuestSession(
      engine: engine,
      mode: mode,
      endpoint: endpoint,
      localMedia: mode.guestNeedsLocalFile ? _localMedia : null,
      deviceName: localDeviceName(),
    );
    try {
      await session.start();
      await _browser.stop(); // économie batterie
      if (!mounted) {
        await session.close();
        await engine.dispose();
        return;
      }
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => PlayerScreen(session: session),
      ));
    } catch (e) {
      await session.close();
      await engine.dispose();
      if (mounted) {
        showError(context, e);
        setState(() => _connecting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Rejoindre — ${widget.mode.title}')),
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _connecting,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_connecting) const LinearProgressIndicator(),
              if (widget.mode.guestNeedsLocalFile || _askFile) ...[
                Text('Votre copie du film', style: theme.textTheme.titleMedium),
                ListTile(
                  leading: const Icon(Icons.movie),
                  title: Text(_localMedia?.name ?? 'Aucun fichier choisi'),
                  trailing: TextButton(
                    onPressed: _pickFile,
                    child: const Text('Choisir'),
                  ),
                ),
                const Divider(),
              ],
              Text('Sessions trouvées sur le réseau',
                  style: theme.textTheme.titleMedium),
              ValueListenableBuilder<List<DiscoveredSession>>(
                valueListenable: _browser.sessions,
                builder: (context, sessions, _) {
                  if (sessions.isEmpty) {
                    return ListTile(
                      leading: const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      title: Text(_discoveryError == null
                          ? 'Recherche… (sinon, scannez le QR code)'
                          : 'Découverte indisponible : utilisez le QR code'),
                    );
                  }
                  return Column(children: [
                    for (final s in sessions)
                      ListTile(
                        leading: const Icon(Icons.tv),
                        title: Text(s.name),
                        subtitle: Text(
                          '${s.endpoint.host}:${s.endpoint.port} · '
                          '${modeHandlerFor(s.endpoint.mode).title}',
                        ),
                        onTap: () => _connect(s.endpoint),
                      ),
                  ]);
                },
              ),
              const Divider(),
              if (_canScan)
                FilledButton.icon(
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scanner le QR code'),
                  onPressed: _scan,
                ),
              const SizedBox(height: 16),
              ExpansionTile(
                title: const Text('Saisie manuelle'),
                initiallyExpanded: !_canScan,
                childrenPadding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  TextField(
                    controller: _addressCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Adresse (IP:port ou synchrofilm://…)',
                      hintText: '192.168.43.1:47470',
                    ),
                  ),
                  TextField(
                    controller: _tokenCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Code affiché sur l\'hôte',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _connectManual,
                      child: const Text('Se connecter'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
