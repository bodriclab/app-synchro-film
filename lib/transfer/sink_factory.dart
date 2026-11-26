import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/http_range.dart' show mimeTypeFor;
import 'android_download_sink.dart';
import 'download_sink.dart';

/// Destination d'un fichier reçu : Téléchargements/SynchroFilm.
Future<DownloadSink> downloadSinkFor(String fileName) async {
  final safe = fileName.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
  if (Platform.isAndroid) {
    return AndroidDownloadSink(safe, mime: mimeTypeFor(safe));
  }
  final downloads =
      await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  return FileDownloadSink(Directory('${downloads.path}/SynchroFilm'), safe);
}
