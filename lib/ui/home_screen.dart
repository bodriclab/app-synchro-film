import 'package:flutter/material.dart';

import '../modes/mode_handler.dart';
import '../modes/mode_registry.dart';
import '../update/update_service.dart';
import 'about_screen.dart';
import 'host_screen.dart';
import 'transfer_screen.dart';
import 'join_screen.dart';
import 'update_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.updates, this.autoCheckUpdates = true});

  /// Service de mise à jour (injecté dans les tests).
  final UpdateService? updates;

  /// Vérification silencieuse au démarrage (au plus une fois par jour).
  final bool autoCheckUpdates;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ModeHandler _mode = kAllModes.first;
  late final UpdateService _updates = widget.updates ?? UpdateService();

  @override
  void initState() {
    super.initState();
    if (widget.autoCheckUpdates) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoCheck());
    }
  }

  Future<void> _autoCheck() async {
    final release = await _updates.autoCheck(); // hors-ligne : null, sans bruit
    if (release == null || !mounted) return;
    await showUpdateDialog(context, release: release, service: _updates);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Synchro Film'),
        actions: [
          IconButton(
            tooltip: 'À propos et mises à jour',
            icon: const Icon(Icons.info_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AboutScreen(updates: _updates)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Mode', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            RadioGroup<ModeHandler>(
              groupValue: _mode,
              onChanged: (m) => setState(() => _mode = m ?? _mode),
              child: Column(
                children: [
                  for (final m in kAllModes)
                    RadioListTile<ModeHandler>(
                      value: m,
                      enabled: m.isImplemented,
                      title: Text(m.title),
                      subtitle: Text(
                        m.isImplemented
                            ? m.subtitle
                            : '${m.subtitle} — bientôt',
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.cast),
              label: const Text('Créer une session (hôte)'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => HostScreen(mode: _mode)),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Rejoindre une session'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => JoinScreen(mode: _mode)),
              ),
            ),
            const SizedBox(height: 24),
            Text('Copier le film', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.upload),
                    label: const Text('Envoyer un film'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SendFileScreen()),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('Recevoir un film'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ReceiveFileScreen(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'Fonctionne sans Internet : connectez les deux appareils au même '
              'Wi-Fi ou au partage de connexion de l\'un des deux.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
