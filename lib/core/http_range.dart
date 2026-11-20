/// Plage d'octets inclusive [start, end] d'une requête HTTP `Range`.
class ByteRange {
  const ByteRange(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;

  String contentRange(int size) => 'bytes $start-$end/$size';

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => 'ByteRange($start-$end)';
}

/// Résultat de l'analyse d'un en-tête `Range`.
sealed class RangeRequest {
  const RangeRequest();
}

/// Pas de Range (ou Range ignoré) : renvoyer tout le fichier en 200.
class FullContent extends RangeRequest {
  const FullContent();
}

/// Une plage satisfiable : 206 Partial Content.
class PartialContent extends RangeRequest {
  const PartialContent(this.range);
  final ByteRange range;
}

/// Plage hors du fichier : 416 Range Not Satisfiable.
class UnsatisfiableRange extends RangeRequest {
  const UnsatisfiableRange();
}

/// Analyse l'en-tête `Range` (RFC 9110) pour un fichier de [size] octets.
/// Formes gérées : `bytes=a-b`, `bytes=a-`, `bytes=-n`. Les en-têtes
/// multi-plages ou invalides sont ignorés (réponse complète, autorisé par la RFC).
RangeRequest parseRange(String? header, int size) {
  if (header == null) return const FullContent();
  final h = header.trim();
  if (!h.toLowerCase().startsWith('bytes=')) return const FullContent();
  final spec = h.substring(6).trim();
  if (spec.contains(',')) return const FullContent();
  final dash = spec.indexOf('-');
  if (dash < 0) return const FullContent();
  final a = spec.substring(0, dash).trim();
  final b = spec.substring(dash + 1).trim();

  if (a.isEmpty) {
    // Suffixe : les n derniers octets.
    final n = int.tryParse(b);
    if (n == null) return const FullContent();
    if (n <= 0 || size == 0) return const UnsatisfiableRange();
    final start = n >= size ? 0 : size - n;
    return PartialContent(ByteRange(start, size - 1));
  }
  final start = int.tryParse(a);
  if (start == null || start < 0) return const FullContent();
  int end;
  if (b.isEmpty) {
    end = size - 1;
  } else {
    final e = int.tryParse(b);
    if (e == null || e < start) return const FullContent();
    end = e;
  }
  if (start >= size) return const UnsatisfiableRange();
  if (end >= size) end = size - 1;
  return PartialContent(ByteRange(start, end));
}

/// Type MIME d'après l'extension (suffisant pour media_kit et les navigateurs).
String mimeTypeFor(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'mp4' || 'm4v' => 'video/mp4',
    'mkv' => 'video/x-matroska',
    'webm' => 'video/webm',
    'avi' => 'video/x-msvideo',
    'mov' => 'video/quicktime',
    'ts' || 'm2ts' => 'video/mp2t',
    'mp3' => 'audio/mpeg',
    'm4a' || 'aac' => 'audio/mp4',
    'flac' => 'audio/flac',
    'ogg' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
    _ => 'application/octet-stream',
  };
}
