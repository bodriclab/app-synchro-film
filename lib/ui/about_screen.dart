import 'package:flutter/material.dart';

import '../update/release_feed.dart';
import '../update/update_service.dart';
import 'update_dialog.dart';

/// À propos : version, licence, vérification manuelle des mises à jour.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, required this.updates});

  final UpdateService updates;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _version = '…';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    widget.updates.currentVersion().then(
      (v) => mounted ? setState(() => _version = v) : null,
      onError: (_) {},
    );
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final r = await widget.updates.check(includeIgnored: true);
    if (!mounted) return;
    setState(() => _checking = false);
    final messenger = ScaffoldMessenger.of(context);
    switch (r.status) {
      case UpdateStatus.available:
      case UpdateStatus.ignored:
        await showUpdateDialog(
          context,
          release: r.release!,
          service: widget.updates,
        );
      case UpdateStatus.upToDate:
        messenger.showSnackBar(
          SnackBar(content: Text('Vous avez la dernière version ($_version).')),
        );
      case UpdateStatus.offline:
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Impossible de vérifier : pas de connexion Internet ?',
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('À propos')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.movie_filter),
            title: const Text('App Synchro Film'),
            subtitle: Text('Version $_version'),
          ),
          ListTile(
            leading: _checking
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.system_update),
            title: const Text('Vérifier les mises à jour'),
            subtitle: const Text('Nécessite Internet (releases GitHub)'),
            onTap: _checking ? null : _check,
          ),
          const ListTile(
            leading: Icon(Icons.code),
            title: Text('Code source'),
            subtitle: SelectableText('https://github.com/$kRepo'),
          ),
          ListTile(
            leading: const Icon(Icons.gavel),
            title: const Text('Licences'),
            subtitle: const Text('MIT ; FFmpeg et libmpv sous LGPL'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'App Synchro Film',
              applicationVersion: _version,
            ),
          ),
        ],
      ),
    );
  }
}
