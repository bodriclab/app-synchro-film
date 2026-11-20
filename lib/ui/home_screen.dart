import 'package:flutter/material.dart';

import '../modes/mode_handler.dart';
import '../modes/mode_registry.dart';
import 'host_screen.dart';
import 'join_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ModeHandler _mode = kAllModes.first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('App Synchro Film')),
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
                        m.isImplemented ? m.subtitle : '${m.subtitle} — bientôt',
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.cast),
              label: const Text('Créer une session (hôte)'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => HostScreen(mode: _mode),
              )),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Rejoindre une session'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => JoinScreen(mode: _mode),
              )),
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
