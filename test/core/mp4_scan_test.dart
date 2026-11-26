import 'dart:convert';
import 'dart:typed_data';

import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/core/mp4_scan.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryMedia implements RandomAccessMedia {
  MemoryMedia(this._data);

  final Uint8List _data;

  @override
  int get length => _data.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset >= _data.length) return Uint8List(0);
    final end = (offset + length > _data.length)
        ? _data.length
        : offset + length;
    return _data.sublist(offset, end);
  }

  @override
  Future<void> close() async {}
}

Uint8List box(String type, List<int> content) {
  final typeBytes = ascii.encode(type);
  if (typeBytes.length != 4) throw ArgumentError('Type must be 4 chars');
  final size = 8 + content.length;
  final bd = ByteData(8);
  bd.setUint32(0, size);
  final result = Uint8List(size);
  result.setRange(0, 4, bd.buffer.asUint8List(0, 4));
  result.setRange(4, 8, typeBytes);
  result.setRange(8, size, content);
  return result;
}

Uint8List fullBox(String type, int versionAndFlags, List<int> content) {
  final body = Uint8List(4 + content.length);
  ByteData.sublistView(body).setUint32(0, versionAndFlags);
  body.setRange(4, body.length, content);
  return box(type, body);
}

Uint8List buildMp4({
  required String brand,
  required List<int> tracksContent,
  List<int>? extraTopBoxes,
}) {
  final ftypContent = ascii.encode(brand);
  final ftyp = box('ftyp', [...ftypContent, 0, 0, 0, 0, ...ftypContent]);
  final moov = box('moov', tracksContent);

  final List<int> allBytes = [];
  allBytes.addAll(ftyp);
  if (extraTopBoxes != null) {
    allBytes.addAll(extraTopBoxes);
  }
  allBytes.addAll(moov);
  return Uint8List.fromList(allBytes);
}

Uint8List buildTrack({
  required String handlerType,
  required String sampleEntryType,
}) {
  final hdlr = fullBox('hdlr', 0, [
    0, 0, 0, 0, // pre_defined
    ...ascii.encode(handlerType),
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // name
  ]);

  final sampleEntry = box(sampleEntryType, List.filled(78, 0));
  final stsd = fullBox('stsd', 0, [
    0, 0, 0, 1, // entry_count = 1
    ...sampleEntry,
  ]);

  final stbl = box('stbl', stsd);
  final minf = box('minf', stbl);
  final mdia = box('mdia', [...hdlr, ...minf]);
  return box('trak', mdia);
}

void main() {
  test('avc1 + mp4a donne iosNative vrai', () async {
    final videoTrack = buildTrack(handlerType: 'vide', sampleEntryType: 'avc1');
    final audioTrack = buildTrack(handlerType: 'soun', sampleEntryType: 'mp4a');
    final mp4Bytes = buildMp4(
      brand: 'isom',
      tracksContent: [...videoTrack, ...audioTrack],
    );

    final media = MemoryMedia(mp4Bytes);
    final codecs = await scanMp4Codecs(media);

    expect(codecs, isNotNull);
    expect(codecs!.brand, 'isom');
    expect(codecs.video, ['avc1']);
    expect(codecs.audio, ['mp4a']);
    expect(codecs.iosNative, isTrue);
  });

  test('hev1 + mp4a donne iosNative faux', () async {
    final videoTrack = buildTrack(handlerType: 'vide', sampleEntryType: 'hev1');
    final audioTrack = buildTrack(handlerType: 'soun', sampleEntryType: 'mp4a');
    final mp4Bytes = buildMp4(
      brand: 'isom',
      tracksContent: [...videoTrack, ...audioTrack],
    );

    final media = MemoryMedia(mp4Bytes);
    final codecs = await scanMp4Codecs(media);

    expect(codecs, isNotNull);
    expect(codecs!.video, ['hev1']);
    expect(codecs.audio, ['mp4a']);
    expect(codecs.iosNative, isFalse);
  });

  test('hvc1 sans audio donne iosNative vrai', () async {
    final videoTrack = buildTrack(handlerType: 'vide', sampleEntryType: 'hvc1');
    final mp4Bytes = buildMp4(brand: 'mp42', tracksContent: videoTrack);

    final media = MemoryMedia(mp4Bytes);
    final codecs = await scanMp4Codecs(media);

    expect(codecs, isNotNull);
    expect(codecs!.brand, 'mp42');
    expect(codecs.video, ['hvc1']);
    expect(codecs.audio, isEmpty);
    expect(codecs.iosNative, isTrue);
  });

  test('avc1 + ac-3 donne iosNative faux', () async {
    final videoTrack = buildTrack(handlerType: 'vide', sampleEntryType: 'avc1');
    final audioTrack = buildTrack(handlerType: 'soun', sampleEntryType: 'ac-3');
    final mp4Bytes = buildMp4(
      brand: 'isom',
      tracksContent: [...videoTrack, ...audioTrack],
    );

    final media = MemoryMedia(mp4Bytes);
    final codecs = await scanMp4Codecs(media);

    expect(codecs, isNotNull);
    expect(codecs!.video, ['avc1']);
    expect(codecs.audio, ['ac-3']);
    expect(codecs.iosNative, isFalse);
  });

  test('fichier sans ftyp (ex. MKV) renvoie null', () async {
    final mkvHeader = Uint8List.fromList([
      0x1A,
      0x45,
      0xDF,
      0xA3,
      0x00,
      0x00,
      0x00,
      0x10,
    ]);
    final media = MemoryMedia(mkvHeader);
    final codecs = await scanMp4Codecs(media);

    expect(codecs, isNull);
  });

  test('moov tronqué ne lève pas d`exception et renvoie null', () async {
    final videoTrack = buildTrack(handlerType: 'vide', sampleEntryType: 'avc1');
    final fullMp4 = buildMp4(brand: 'isom', tracksContent: videoTrack);
    // Tronquer le fichier au milieu du moov
    final truncated = fullMp4.sublist(0, fullMp4.length - 20);

    final media = MemoryMedia(truncated);
    final codecs = await scanMp4Codecs(media);

    expect(codecs, isNull);
  });

  test(
    'moov placé après un gros mdat avec taille 64 bits (size==1) est trouvé',
    () async {
      final videoTrack = buildTrack(
        handlerType: 'vide',
        sampleEntryType: 'avc1',
      );
      final moov = box('moov', videoTrack);

      // Créer une boîte mdat avec size == 1 (16 octets d'en-tête)
      final mdatContentSize = 50;
      final mdatTotalSize = 16 + mdatContentSize;
      final mdatHeader = Uint8List(16);
      final bd = ByteData.sublistView(mdatHeader);
      bd.setUint32(0, 1); // size 1 indique taille 64 bits
      mdatHeader.setRange(4, 8, ascii.encode('mdat'));
      bd.setUint64(8, mdatTotalSize);

      final mdat = Uint8List(mdatTotalSize);
      mdat.setRange(0, 16, mdatHeader);

      final ftyp = box('ftyp', [...ascii.encode('isom'), 0, 0, 0, 0]);

      final allBytes = [...ftyp, ...mdat, ...moov];
      final media = MemoryMedia(Uint8List.fromList(allBytes));

      final codecs = await scanMp4Codecs(media);

      expect(codecs, isNotNull);
      expect(codecs!.brand, 'isom');
      expect(codecs.video, ['avc1']);
    },
  );

  test('brand lu correctement', () async {
    final videoTrack = buildTrack(handlerType: 'vide', sampleEntryType: 'avc1');
    final mp4Bytes = buildMp4(brand: 'qt  ', tracksContent: videoTrack);

    final media = MemoryMedia(mp4Bytes);
    final codecs = await scanMp4Codecs(media);

    expect(codecs, isNotNull);
    expect(codecs!.brand, 'qt  ');
  });
}
