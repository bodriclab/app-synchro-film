import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../core/media_source.dart';
import 'android_media.dart';

/// Ouvre un média quel que soit son type d'URI (fichier ou content://).
Future<RandomAccessMedia> openMedia(String uri) => uri.startsWith('content://')
    ? AndroidMedia.open(uri)
    : openFileMedia(uri);

/// Choix d'un film local, sans copie :
/// - Android : sélecteur système, on garde l'URI content:// d'origine ;
/// - Windows : file_picker, qui renvoie le chemin réel du fichier.
Future<MediaRef?> pickMedia() async {
  if (Platform.isAndroid) return AndroidMedia.pick();
  final files = await FilePicker.pickFiles(
    dialogTitle: 'Choisir le film',
    type: FileType.media,
  );
  final path = files.isEmpty ? null : files.first.path;
  return path == null ? null : MediaRef.file(path);
}
