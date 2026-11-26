import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../core/remux.dart' show extensionOf;
import '../core/subtitle_text.dart';
import '../core/subtitles.dart';

/// Choix d'un fichier de sous-titres (.srt, .ass, .ssa, .vtt), lu en texte.
/// Renvoie null si l'utilisateur annule ; lève [FormatException] si le
/// fichier n'est pas un sous-titre reconnu.
Future<({String name, String text})?> pickSubtitleFile() async {
  // Android ne connaît pas de type MIME fiable pour .srt/.ass : filtre « tout ».
  final file = await FilePicker.pickFile(
    dialogTitle: 'Choisir un fichier de sous-titres',
    type: Platform.isAndroid ? FileType.any : FileType.custom,
    allowedExtensions: Platform.isAndroid ? null : kSubtitleExtensions.toList(),
  );
  if (file == null) return null;
  if (!kSubtitleExtensions.contains(extensionOf(file.name))) {
    throw const FormatException(
      'Choisissez un fichier .srt, .ass, .ssa ou .vtt.',
    );
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > 20 << 20) {
    throw const FormatException(
      'Fichier trop volumineux pour des sous-titres.',
    );
  }
  return (name: file.name, text: decodeSubtitleBytes(bytes));
}
