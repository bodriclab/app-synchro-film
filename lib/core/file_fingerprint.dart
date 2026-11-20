import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Empreinte légère d'un fichier média : taille + SHA-256 partiel
/// (premier et dernier Mo). Suffit à détecter un fichier différent
/// sans lire plusieurs Go (économie batterie / temps).
class FileFingerprint {
  const FileFingerprint({required this.size, required this.partialHash});

  static const int defaultChunkSize = 1024 * 1024;

  final int size;
  final String partialHash;

  /// Calcule l'empreinte de [path].
  static Future<FileFingerprint> compute(
    String path, {
    int chunkSize = defaultChunkSize,
  }) async {
    final raf = await File(path).open();
    try {
      final size = await raf.length();
      final sizeBytes = ByteData(8)..setInt64(0, size, Endian.little);
      final builder = BytesBuilder(copy: false)
        ..add(sizeBytes.buffer.asUint8List());
      final headLen = size < chunkSize ? size : chunkSize;
      builder.add(await raf.read(headLen));
      if (size > chunkSize) {
        final tailStart = size - chunkSize > headLen ? size - chunkSize : headLen;
        await raf.setPosition(tailStart);
        builder.add(await raf.read(size - tailStart));
      }
      final digest = sha256.convert(builder.takeBytes());
      return FileFingerprint(size: size, partialHash: digest.toString());
    } finally {
      await raf.close();
    }
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
