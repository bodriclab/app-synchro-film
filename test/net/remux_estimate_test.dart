import 'dart:io';

import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/core/remux.dart';
import 'package:app_synchro_film/net/remux_http_handler.dart';
import 'package:app_synchro_film/platform/ffmpeg_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late String path;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('estimate');
    path = '${dir.path}/film.bin';
    final file = File(path);
    final raf = await file.open(mode: FileMode.write);
    try {
      await raf.setPosition(99999999);
      await raf.writeByte(0);
    } finally {
      await raf.close();
    }
  });

  tearDownAll(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  RemuxHttpHandler handler({int? Function()? durationMs}) => RemuxHttpHandler(
    token: 't',
    mediaId: 'm',
    media: MediaRef.file(path),
    ffmpeg: ProcessFfmpegRunner(),
    durationMs: durationMs,
  );

  const copie = RemuxProbe(
    offsetMs: 0,
    videoCodec: 'h264',
    audioCodec: 'aac',
    safari: true,
  );
  const opus = RemuxProbe(
    offsetMs: 0,
    videoCodec: 'h264',
    audioCodec: 'opus',
    safari: true,
  );
  const mo = 16 << 20;

  group('Tests d\'estimation de taille RemuxHttpHandler', () {
    test('durée inconnue, codec copie, startMs 0', () async {
      final h = handler();
      final size = h.estimateSize(copie, startMs: 0);
      expect(size, closeTo(110000000 + mo, 2));
    });

    test('durée inconnue, codec opus, startMs 0', () async {
      final h = handler();
      final size = h.estimateSize(opus, startMs: 0);
      expect(size, closeTo(110000000 + (200 << 20) + mo, 2));
    });

    test('durée connue 1000000 ms, codec copie, startMs 500000', () async {
      final h = handler(durationMs: () => 1000000);
      final size = h.estimateSize(copie, startMs: 500000);
      expect(size, closeTo(66000000 + mo, 2));
    });

    test('durée connue 1000000 ms, codec opus, startMs 500000', () async {
      final h = handler(durationMs: () => 1000000);
      final size = h.estimateSize(opus, startMs: 500000);
      expect(size, closeTo(66000000 + 20000000 + mo, 2));
    });

    test(
      'durée connue 1000000 ms, codec copie, startMs 2000000 au-delà de la fin',
      () async {
        final h = handler(durationMs: () => 1000000);
        final size = h.estimateSize(copie, startMs: 2000000);
        expect(size, closeTo(11000000 + mo, 2));
      },
    );

    test('décroissance de l\'estimation selon startMs', () async {
      final h = handler(durationMs: () => 1000000);
      final size0 = h.estimateSize(copie, startMs: 0);
      final size300 = h.estimateSize(copie, startMs: 300000);
      final size900 = h.estimateSize(copie, startMs: 900000);

      expect(size0, greaterThan(size300));
      expect(size300, greaterThan(size900));
    });
  });
}
