import 'dart:io';
import 'dart:typed_data';

/// Référence vers un média local : chemin de fichier (Windows, tests) ou
/// URI `content://` d'origine (Android, aucune copie).
class MediaRef {
  const MediaRef({required this.uri, required this.name, this.size});

  /// Chemin local ou URI `content://`. C'est ce que media_kit ouvre.
  final String uri;

  /// Nom affiché (nom du fichier).
  final String name;

  /// Taille en octets si connue.
  final int? size;

  bool get isContentUri => uri.startsWith('content://');

  factory MediaRef.file(String path) =>
      MediaRef(uri: path, name: path.split(RegExp(r'[\\/]')).last);

  @override
  String toString() => 'MediaRef($name, $uri)';
}

/// Accès aléatoire en lecture seule à un média (fichier ou content://).
/// Chaque ouverture est indépendante : une requête HTTP = un accès.
abstract interface class RandomAccessMedia {
  int get length;

  /// Lit au plus [length] octets à partir de [offset]
  /// (moins en fin de fichier, vide au-delà).
  Future<Uint8List> read(int offset, int length);

  Future<void> close();
}

/// Ouvre un [RandomAccessMedia] à partir de [MediaRef.uri].
typedef MediaOpener = Future<RandomAccessMedia> Function(String uri);

/// Implémentation dart:io pour un chemin de fichier.
class FileRandomAccessMedia implements RandomAccessMedia {
  FileRandomAccessMedia._(this._raf, this.length);

  static Future<FileRandomAccessMedia> open(String path) async {
    final raf = await File(path).open();
    return FileRandomAccessMedia._(raf, await raf.length());
  }

  final RandomAccessFile _raf;
  Future<void> _queue = Future.value();

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int length) {
    // RandomAccessFile n'accepte qu'une opération à la fois : on sérialise.
    final result = _queue.then((_) async {
      if (offset >= this.length || length <= 0) return Uint8List(0);
      await _raf.setPosition(offset);
      return _raf.read(length);
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<void> close() => _queue.then((_) => _raf.close());
}

/// Opener par défaut pour les chemins de fichiers.
Future<RandomAccessMedia> openFileMedia(String path) =>
    FileRandomAccessMedia.open(path);
