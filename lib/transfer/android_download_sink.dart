import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../platform/settings_store.dart';
import 'download_sink.dart';

/// Android : fichier écrit dans Téléchargements/SynchroFilm via MediaStore
/// (Android 10+), ou dans le dossier Téléchargements propre à l'app avant.

class AndroidDownloadSink implements DownloadSink {
  static const MethodChannel _channel = MethodChannel(
    'com.bodriclab.synchrofilm/download',
  );

  final String fileName;
  final String? mime;
  final Future<String?> Function(String key) _readString;

  String? _uri;
  int? _handle;
  final BytesBuilder _buffer = BytesBuilder();
  static const int _flushThreshold = 1024 * 1024; // 1 Mio

  AndroidDownloadSink(
    this.fileName, {
    this.mime,
    SettingsStore? settings,
    Future<String?> Function(String key)? readString,
  }) : _readString = readString ?? ((k) => SettingsStore.instance.getString(k));

  String? _key;

  /// Reprise : l'entrée MediaStore « en attente » d'un essai précédent pour
  /// le même nom et la même taille est réutilisée.
  @override
  Future<int> prepare(int? totalSize) async {
    _key = 'download.pending.$fileName.${totalSize ?? 'x'}';
    _uri = await _readString(_key!);
    var have = -1;
    if (_uri != null && _uri!.isNotEmpty) {
      try {
        have = await _channel.invokeMethod<int>('size', {'uri': _uri}) ?? -1;
      } catch (_) {
        have = -1;
      }
    }
    final reuse = have >= 0 && (totalSize == null || have <= totalSize);
    if (!reuse) {
      _uri = await _channel.invokeMethod<String>('create', {
        'name': fileName,
        'mime': mime,
      });
      await SettingsStore.instance.set(_key!, _uri!);
      have = 0;
    }
    _handle = await _channel.invokeMethod<int>('open', {
      'uri': _uri,
      'truncate': have == 0,
    });
    return have;
  }

  @override
  Future<void> truncate() async {
    await _flushBuffer();
    if (_handle != null) {
      await _channel.invokeMethod('close', {'handle': _handle});
    }
    _handle = await _channel.invokeMethod<int>('open', {
      'uri': _uri,
      'truncate': true,
    });
  }

  @override
  Future<void> write(List<int> data) async {
    _buffer.add(data);
    if (_buffer.length >= _flushThreshold) {
      await _flushBuffer();
    }
  }

  Future<void> _flushBuffer() async {
    if (_buffer.isEmpty || _handle == null) return;
    final bytes = _buffer.takeBytes();
    await _channel.invokeMethod('write', {'handle': _handle, 'data': bytes});
  }

  @override
  Future<String> finish() async {
    await _flushBuffer();
    await close();
    final location =
        await _channel.invokeMethod<String>('finish', {
          'uri': _uri,
          'name': fileName,
        }) ??
        '';
    await SettingsStore.instance.set(_key!, '');
    return location;
  }

  @override
  Future<void> close() async {
    try {
      await _flushBuffer();
      if (_handle != null) {
        await _channel.invokeMethod('close', {'handle': _handle});
      }
    } catch (_) {}
    _handle = null;
  }
}
