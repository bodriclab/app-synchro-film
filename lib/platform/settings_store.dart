import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Petits réglages persistants (JSON dans le dossier de l'app) : gain de
/// l'invité, renfort des dialogues…
class SettingsStore {
  SettingsStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  /// Instance partagée de l'app.
  static final SettingsStore instance = SettingsStore();

  final Future<Directory> Function() _directory;
  Map<String, dynamic>? _cache;

  Future<File> _file() async =>
      File('${(await _directory()).path}/settings.json');

  Future<Map<String, dynamic>> _load() async {
    if (_cache != null) return _cache!;
    try {
      final f = await _file();
      if (await f.exists()) {
        return _cache =
            jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {}
    return _cache = {};
  }

  Future<double> getDouble(String key, double fallback) async =>
      ((await _load())[key] as num?)?.toDouble() ?? fallback;

  Future<bool> getBool(String key, bool fallback) async =>
      (await _load())[key] as bool? ?? fallback;

  Future<String?> getString(String key) async =>
      (await _load())[key] as String?;

  Future<void> set(String key, Object value) async {
    final map = await _load();
    map[key] = value;
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(map));
    } catch (_) {
      // réglage non mémorisé : sans gravité
    }
  }
}
