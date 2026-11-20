import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/update_platform.dart';
import '../update/release_feed.dart';
import '../update/update_service.dart';

/// Popup « nouvelle version » : notes + Mettre à jour / Plus tard / Ignorer.
Future<void> showUpdateDialog(
  BuildContext context, {
  required Release release,
  required UpdateService service,
  UpdatePlatform platform = const UpdatePlatform(),
}) async {
  final current = await service.currentVersion().catchError((_) => '?');
  if (!context.mounted) return;
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        'Nouvelle version ${release.version}'
        '${release.prerelease ? ' (pré-version)' : ''}',
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version installée : $current'),
            const SizedBox(height: 12),
            if (release.notes.isNotEmpty)
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(release.notes),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'ignore'),
          child: const Text('Ignorer cette version'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'later'),
          child: const Text('Plus tard'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'update'),
          child: const Text('Mettre à jour'),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'ignore':
      await service.ignore(release);
    case 'update':
      if (Platform.isAndroid) {
        await _updateAndroid(context, release, platform);
      } else {
        await platform.openUrl(release.windowsAssetUrl ?? release.pageUrl);
      }
  }
}

void _snack(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(text)));
}

Future<void> _updateAndroid(
  BuildContext context,
  Release release,
  UpdatePlatform platform,
) async {
  // 1. Autorisation « Installer des applis inconnues » (Android 8+).
  if (!await platform.canInstall()) {
    if (!context.mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Autorisation nécessaire'),
        content: const Text(
          'Pour installer la mise à jour, Android doit autoriser App Synchro '
          'Film à installer des applications. Activez « Autoriser cette '
          'source » dans l\'écran qui va s\'ouvrir, puis revenez ici.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ouvrir les réglages'),
          ),
        ],
      ),
    );
    if (go != true) return;
    if (!await platform.requestInstallPermission()) {
      if (context.mounted) {
        _snack(context, 'Installation non autorisée : mise à jour annulée.');
      }
      return;
    }
  }
  // 2. Téléchargement de l'APK de l'ABI de l'appareil, avec progression.
  final abi = await platform.androidAbi();
  final dir = await getTemporaryDirectory();
  final dest = File('${dir.path}/updates/app-synchro-film-${release.tag}.apk');
  if (!context.mounted) return;
  final file = await showDialog<File>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DownloadDialog(url: release.apkUrlFor(abi), dest: dest),
  );
  // 3. Installeur système.
  if (file == null) return;
  try {
    await platform.installApk(file.path);
  } catch (e) {
    if (context.mounted) _snack(context, 'Installation impossible : $e');
  }
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.url, required this.dest});
  final String url;
  final File dest;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  final _cancel = Completer<void>();
  double? _progress;
  int _received = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final f = await downloadFile(
        Uri.parse(widget.url),
        widget.dest,
        cancel: _cancel.future,
        onProgress: (p, r) {
          if (mounted) {
            setState(() {
              _progress = p;
              _received = r;
            });
          }
        },
      );
      if (mounted) Navigator.pop(context, f);
    } catch (e) {
      if (_cancel.isCompleted) return;
      if (mounted) {
        setState(
          () => _error = 'Échec du téléchargement (connexion Internet ?).\n$e',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mb = (_received / 1e6).toStringAsFixed(1);
    return AlertDialog(
      title: const Text('Téléchargement de la mise à jour'),
      content: _error != null
          ? Text(_error!)
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 12),
                Text(
                  _progress == null
                      ? '$mb Mo'
                      : '${(_progress! * 100).round()} % — $mb Mo',
                ),
              ],
            ),
      actions: [
        TextButton(
          onPressed: () {
            if (!_cancel.isCompleted) _cancel.complete();
            Navigator.pop(context);
          },
          child: Text(_error != null ? 'Fermer' : 'Annuler'),
        ),
      ],
    );
  }
}
