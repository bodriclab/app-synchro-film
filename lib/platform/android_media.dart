import 'package:flutter/services.dart';

import '../core/media_source.dart';

/// Pont vers le code Kotlin (MainActivity) : accès aux URI `content://`
/// d'origine sans copier le film dans l'espace de l'app.
class AndroidMedia {
  static const _channel = MethodChannel('com.bodriclab.synchrofilm/media');

  /// Sélecteur système (ACTION_OPEN_DOCUMENT). Null si annulé.
  static Future<MediaRef?> pick() async {
    final res = await _channel.invokeMapMethod<String, Object?>('pick');
    if (res == null) return null;
    return _ref(res);
  }

  static Future<MediaRef> info(String uri) async {
    final res =
        await _channel.invokeMapMethod<String, Object?>('info', {'uri': uri});
    return _ref(res!);
  }

  static Future<RandomAccessMedia> open(String uri) async {
    final res =
        await _channel.invokeMapMethod<String, Object?>('open', {'uri': uri});
    return _ContentUriMedia(res!['id']! as int, (res['size']! as num).toInt());
  }

  static MediaRef _ref(Map<String, Object?> m) {
    final uri = m['uri']! as String;
    return MediaRef(
      uri: uri,
      name: (m['name'] as String?) ?? Uri.decodeComponent(uri.split('/').last),
      size: (m['size'] as num?)?.toInt(),
    );
  }
}

class _ContentUriMedia implements RandomAccessMedia {
  _ContentUriMedia(this._id, this.length);

  final int _id;
  bool _closed = false;

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (_closed) throw StateError('média fermé');
    if (offset >= this.length || length <= 0) return Uint8List(0);
    final bytes = await AndroidMedia._channel.invokeMethod<Uint8List>('read', {
      'id': _id,
      'offset': offset,
      'length': length,
    });
    return bytes ?? Uint8List(0);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await AndroidMedia._channel.invokeMethod<void>('close', {'id': _id});
  }
}
