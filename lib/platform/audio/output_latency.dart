import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Sortie audio active et sa latence estimée par l'OS.
class AudioOutputInfo {
  const AudioOutputInfo({
    required this.id,
    required this.label,
    required this.autoLatencyMs,
    this.source = 'none',
  });

  /// Identifiant stable de la sortie (ex. `bt:WH-1000XM4`), clé du réglage manuel.
  final String id;
  final String label;

  /// Latence de sortie rapportée / estimée par l'OS (0 si inconnue).
  final int autoLatencyMs;

  /// `os` (valeur rapportée), `estimate` (estimation par type) ou `none`.
  final String source;

  static const fallback = AudioOutputInfo(
    id: 'default',
    label: 'Sortie par défaut',
    autoLatencyMs: 0,
  );
}

/// Interroge l'OS : Android via le canal natif (AudioManager), sinon
/// réglage manuel seul (Windows : WASAPI non branché pour l'instant).
Future<AudioOutputInfo> currentAudioOutput() async {
  if (!Platform.isAndroid) return AudioOutputInfo.fallback;
  try {
    final m = await const MethodChannel('com.bodriclab.synchrofilm/media')
        .invokeMapMethod<String, Object?>('audioOutput');
    if (m == null) return AudioOutputInfo.fallback;
    return AudioOutputInfo(
      id: m['id'] as String? ?? 'default',
      label: m['label'] as String? ?? 'Sortie audio',
      autoLatencyMs: (m['latencyMs'] as num?)?.toInt() ?? 0,
      source: m['source'] as String? ?? 'none',
    );
  } on PlatformException {
    return AudioOutputInfo.fallback;
  } on MissingPluginException {
    return AudioOutputInfo.fallback;
  }
}

/// Réglage manuel du décalage (−500…+500 ms) mémorisé par sortie audio,
/// dans un petit fichier JSON du dossier de l'app.
class LatencyOffsetStore {
  LatencyOffsetStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const int minMs = -500;
  static const int maxMs = 500;

  final Future<Directory> Function() _directory;
  Map<String, int>? _cache;

  Future<File> _file() async =>
      File('${(await _directory()).path}/latency_offsets.json');

  Future<Map<String, int>> _load() async {
    if (_cache != null) return _cache!;
    try {
      final f = await _file();
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return _cache = {
          for (final e in data.entries) e.key: (e.value as num).toInt(),
        };
      }
    } catch (_) {}
    return _cache = {};
  }

  Future<int> get(String outputId) async => (await _load())[outputId] ?? 0;

  Future<void> set(String outputId, int ms) async {
    final map = await _load();
    map[outputId] = ms.clamp(minMs, maxMs);
    final f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(map));
  }
}
