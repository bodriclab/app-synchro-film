import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'media_source.dart';

/// Empreinte légère d'un fichier média : taille + SHA-256 partiel
/// (premier et dernier Mo). Suffit à détecter un fichier différent
/// sans lire plusieurs Go (économie batterie / temps).
class FileFingerprint {
  const FileFingerprint({required this.size, required this.partialHash});

  static const int defaultChunkSize = 1024 * 1024;

  final int size;
  final String partialHash;

  /// Calcule l'empreinte du fichier [path].
  static Future<FileFingerprint> compute(
    String path, {
    int chunkSize = defaultChunkSize,
  }) =>
      computeWith(path, openFileMedia, chunkSize: chunkSize);

  /// Calcule l'empreinte de [uri] ouvert par [opener] (fichier ou content://,
  /// sans copie : seuls le premier et le dernier Mo sont lus).
  static Future<FileFingerprint> computeWith(
    String uri,
    MediaOpener opener, {
    int chunkSize = defaultChunkSize,
  }) async {
    final media = await opener(uri);
    try {
      return await computeFrom(media, chunkSize: chunkSize);
    } finally {
      await media.close();
    }
  }

  static Future<FileFingerprint> computeFrom(
    RandomAccessMedia media, {
    int chunkSize = defaultChunkSize,
  }) async {
    final size = media.length;
    final sizeBytes = ByteData(8)..setInt64(0, size, Endian.little);
    final builder = BytesBuilder(copy: false)
      ..add(sizeBytes.buffer.asUint8List());
    final headLen = size < chunkSize ? size : chunkSize;
    builder.add(await _readFully(media, 0, headLen));
    if (size > chunkSize) {
      final tailStart = size - chunkSize > headLen ? size - chunkSize : headLen;
      builder.add(await _readFully(media, tailStart, size - tailStart));
    }
    final digest = sha256.convert(builder.takeBytes());
    return FileFingerprint(size: size, partialHash: digest.toString());
  }

  static Future<Uint8List> _readFully(
    RandomAccessMedia media,
    int offset,
    int length,
  ) async {
    final out = BytesBuilder(copy: false);
    var pos = offset;
    while (pos < offset + length) {
      final chunk = await media.read(pos, offset + length - pos);
      if (chunk.isEmpty) break;
      out.add(chunk);
      pos += chunk.length;
    }
    return out.takeBytes();
  }

  bool matches(FileFingerprint? other) =>
      other != null && other.size == size && other.partialHash == partialHash;

  Map<String, dynamic> toJson() => {'size': size, 'hash': partialHash};

  static FileFingerprint? fromJson(Object? json) {
    if (json is! Map) return null;
    final size = json['size'];
    final hash = json['hash'];
    if (size is! int || hash is! String) return null;
    return FileFingerprint(size: size, partialHash: hash);
  }

  @override
  bool operator ==(Object other) => other is FileFingerprint && matches(other);

  @override
  int get hashCode => Object.hash(size, partialHash);

  @override
  String toString() =>
      'FileFingerprint($size o, ${partialHash.substring(0, 12)}…)';
}
