import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Dossier temporaire de l'app (repli : dossier temporaire du système, ex.
/// dans les tests où les plugins ne sont pas disponibles).
Future<Directory> appTempDir() async {
  try {
    return await getTemporaryDirectory();
  } catch (_) {
    return Directory.systemTemp;
  }
}
