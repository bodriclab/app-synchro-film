import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Nom affiché à l'autre pair.
String localDeviceName() {
  final host = Platform.localHostname;
  final os = Platform.isAndroid
      ? 'Android'
      : Platform.isWindows
          ? 'Windows'
          : Platform.operatingSystem;
  return host.isEmpty || host == 'localhost' ? os : '$host ($os)';
}

/// Sélection d'un fichier vidéo/audio local. Retourne son chemin.
///
/// Limite connue : sous Android, file_picker copie le fichier choisi dans le
/// cache de l'app (URI `content://`). Voir TODO dans le README.
Future<String?> pickMediaFile() async {
  final files = await FilePicker.pickFiles(
    dialogTitle: 'Choisir le film',
    type: FileType.media,
  );
  if (files.isEmpty) return null;
  return files.first.path;
}

String formatDuration(int ms) {
  final d = Duration(milliseconds: ms < 0 ? 0 : ms);
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String fileName(String path) => path.split(RegExp(r'[\\/]')).last;

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Erreur : $error')),
  );
}
