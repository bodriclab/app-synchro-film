import 'dart:convert';
import 'dart:io';

/// Destination d'un téléchargement, avec reprise : les octets déjà reçus
/// sont conservés entre deux tentatives (et deux lancements de l'app).
abstract interface class DownloadSink {
  /// Octets déjà présents pour ce fichier de [totalSize] octets (0 si rien,
  /// ou si le fichier partiel correspond à un autre fichier).
  Future<int> prepare(int? totalSize);

  /// Repart de zéro (le serveur ne gère pas la reprise).
  Future<void> truncate();

  Future<void> write(List<int> data);

  /// Termine : rend le fichier visible et renvoie son emplacement lisible.
  Future<String> finish();

  /// Interrompt en gardant le fichier partiel (reprise possible).
  Future<void> close();
}

/// Fichier local (Windows, tests) : `nom.ext.part` + `nom.ext.part.json`
/// (taille attendue), renommé en `nom.ext` à la fin — sans écraser un
/// fichier existant (`nom (2).ext`).
class FileDownloadSink implements DownloadSink {
  FileDownloadSink(this.directory, this.fileName);

  final Directory directory;
  final String fileName;
  RandomAccessFile? _raf;

  File get _part => File('${directory.path}/$fileName.part');
  File get _meta => File('${directory.path}/$fileName.part.json');

  @override
  Future<int> prepare(int? totalSize) async {
    await directory.create(recursive: true);
    var have = 0;
    if (await _part.exists()) {
      try {
        final meta = jsonDecode(await _meta.readAsString()) as Map;
        if (totalSize != null && meta['size'] == totalSize) {
          have = await _part.length();
        }
      } catch (_) {}
    }
    await _meta.writeAsString(jsonEncode({'size': totalSize}));
    _raf = await _part.open(mode: have > 0 ? FileMode.append : FileMode.write);
    if (totalSize != null && have > totalSize) {
      await _raf!.truncate(0);
      have = 0;
    }
    return have;
  }

  @override
  Future<void> truncate() async {
    await _raf?.truncate(0);
    await _raf?.setPosition(0);
  }

  @override
  Future<void> write(List<int> data) => _raf!.writeFrom(data);

  @override
  Future<String> finish() async {
    await _raf?.close();
    _raf = null;
    var target = File('${directory.path}/$fileName');
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    for (var i = 2; await target.exists(); i++) {
      target = File('${directory.path}/$base ($i)$ext');
    }
    await _part.rename(target.path);
    await _meta.delete().catchError((_) => _meta);
    return target.path;
  }

  @override
  Future<void> close() async {
    await _raf?.close();
    _raf = null;
  }
}
