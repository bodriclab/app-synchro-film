import 'dart:typed_data';

import 'media_source.dart';

/// Codecs déclarés dans un MP4/MOV (entrées `stsd` de chaque piste).
class Mp4Codecs {
  const Mp4Codecs({
    required this.brand,
    required this.video,
    required this.audio,
  });

  /// Major brand de la boîte `ftyp` (ex. `isom`, `mp42`, `qt  `).
  final String brand;

  /// FourCC des pistes vidéo (`avc1`, `avc3`, `hvc1`, `hev1`…).
  final List<String> video;

  /// FourCC des pistes audio (`mp4a`, `ac-3`, `ec-3`, `Opus`, `fLaC`…).
  final List<String> audio;

  /// Lisible tel quel par Safari iOS : H.264 (`avc1`) ou HEVC étiqueté
  /// `hvc1`, et audio AAC/MP3 (`mp4a`) ou pas d'audio.
  bool get iosNative =>
      video.isNotEmpty &&
      video.every((c) => c == 'avc1' || c == 'hvc1') &&
      audio.every((c) => c == 'mp4a');

  @override
  String toString() => 'Mp4Codecs($brand, vidéo $video, audio $audio)';
}

/// Lit les codecs d'un MP4/MOV sans FFmpeg : parcourt les boîtes de premier
/// niveau (en-têtes seulement), charge `moov` (≤ [maxMoovBytes]) et descend
/// jusqu'aux `stsd`. Renvoie null si ce n'est pas un MP4 (pas de `ftyp` en
/// tête) ou si `moov` est introuvable. Ne lève jamais d'exception sur des
/// données tronquées.
Future<Mp4Codecs?> scanMp4Codecs(
  RandomAccessMedia src, {
  int maxMoovBytes = 64 << 20,
}) async {
  try {
    final total = src.length;
    var pos = 0;
    String? brand;
    while (pos + 8 <= total) {
      final h = await src.read(pos, 16);
      if (h.length < 8) break;
      final bd = ByteData.sublistView(h);
      var size = bd.getUint32(0);
      final type = String.fromCharCodes(h.sublist(4, 8));
      var header = 8;
      if (size == 1) {
        if (h.length < 16) break;
        size = bd.getUint64(8);
        header = 16;
      } else if (size == 0) {
        size = total - pos;
      }
      // Boîte tronquée : pas d'avis (un `moov` incomplet pourrait cacher
      // une piste audio non compatible).
      if (size < header || pos + size > total) break;
      if (pos == 0 && type != 'ftyp') return null;
      if (type == 'ftyp') {
        final b = await src.read(pos + header, 4);
        brand = String.fromCharCodes(b);
      } else if (type == 'moov') {
        final len = size - header;
        if (len > maxMoovBytes) return null;
        final moov = await src.read(pos + header, len);
        final video = <String>[], audio = <String>[];
        for (final trak in _children(moov, 'trak')) {
          for (final mdia in _children(trak, 'mdia')) {
            String? handler;
            for (final hdlr in _children(mdia, 'hdlr')) {
              if (hdlr.length >= 12) {
                handler = String.fromCharCodes(hdlr.sublist(8, 12));
              }
            }
            final list = handler == 'vide'
                ? video
                : handler == 'soun'
                ? audio
                : null;
            if (list == null) continue;
            for (final minf in _children(mdia, 'minf')) {
              for (final stbl in _children(minf, 'stbl')) {
                for (final stsd in _children(stbl, 'stsd')) {
                  if (stsd.length < 8) continue;
                  for (final e in _boxes(Uint8List.sublistView(stsd, 8))) {
                    list.add(e.$1);
                  }
                }
              }
            }
          }
        }
        return Mp4Codecs(brand: brand ?? '', video: video, audio: audio);
      }
      pos += size;
    }
  } catch (_) {
    // Lecture impossible ou données incohérentes : pas d'information.
  }
  return null;
}

/// Contenus des boîtes de type [type] directement contenues dans [data].
Iterable<Uint8List> _children(Uint8List data, String type) =>
    _boxes(data).where((b) => b.$1 == type).map((b) => b.$2);

/// Boîtes successives de [data] : (type, contenu). S'arrête sur une taille
/// invalide (données tronquées).
Iterable<(String, Uint8List)> _boxes(Uint8List data) sync* {
  final bd = ByteData.sublistView(data);
  var pos = 0;
  while (pos + 8 <= data.length) {
    var size = bd.getUint32(pos);
    var header = 8;
    if (size == 1) {
      if (pos + 16 > data.length) return;
      size = bd.getUint64(pos + 8);
      header = 16;
    } else if (size == 0) {
      size = data.length - pos;
    }
    if (size < header) return;
    final type = String.fromCharCodes(data.sublist(pos + 4, pos + 8));
    final end = pos + size > data.length ? data.length : pos + size;
    yield (type, Uint8List.sublistView(data, pos + header, end));
    if (pos + size > data.length) return;
    pos += size;
  }
}
