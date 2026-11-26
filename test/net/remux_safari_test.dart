import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/net/host_server.dart';
import 'package:app_synchro_film/net/remux_http_handler.dart';
import 'package:app_synchro_film/net/remux_spool.dart';
import 'package:app_synchro_film/platform/ffmpeg_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  final skip = hasFfmpeg ? null : 'ffmpeg absent';
  late Directory dir;
  late HostServer server;
  late RemuxHttpHandler handler;
  final client = HttpClient();

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('safari');
  });
  tearDownAll(() => dir.delete(recursive: true));

  Future<void> serve(String film) async {
    server = HostServer(token: 'secret', preferredPort: 0);
    handler = RemuxHttpHandler(
      token: 'secret',
      mediaId: 'abc',
      media: MediaRef.file(film),
      ffmpeg: ProcessFfmpegRunner(),
      tempDir: () async => dir,
    );
    server.addRoute('/remux/', handler.call);
    await server.start();
  }

  tearDown(() async {
    await handler.dispose();
    await server.dispose();
  });

  Uri url(String path, [Map<String, String>? q]) => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: server.port,
    path: path,
    queryParameters: {'token': 'secret', ...?q},
  );

  Future<(int, Uint8List, HttpHeaders)> get(Uri u, {String? range}) async {
    final req = await client.getUrl(u);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    final b = BytesBuilder();
    await for (final c in res) {
      b.add(c);
    }
    return (res.statusCode, b.takeBytes(), res.headers);
  }

  Future<Map<String, dynamic>> ffprobe(String path) async {
    final r = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_streams',
      '-show_format',
      '-of',
      'json',
      path,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return jsonDecode(r.stdout as String) as Map<String, dynamic>;
  }

  test(
    'Safari : HEVC hvc1 + Opus → AAC, Range 206 et taille fixe',
    () async {
      final film = await makeTestFilm(
        dir,
        name: 'hevc.mkv',
        seconds: 12,
        videoCodec: 'libx265',
        audioCodec: 'libopus',
        channels: 6,
      );
      await serve(film);
      final (ci, info, _) = await get(url('/remux/abc/info', {'safari': '1'}));
      expect(ci, 200);
      final j = jsonDecode(utf8.decode(info)) as Map<String, dynamic>;
      expect(j['videoCodec'], 'hevc');
      expect(j['audioCodec'], 'opus');
      expect(j['transcodeAudio'], isTrue);
      expect(j['hevc'], isTrue);
      // Hors Safari, l'Opus passe tel quel.
      final (_, info2, _) = await get(url('/remux/abc/info'));
      expect(jsonDecode(utf8.decode(info2))['transcodeAudio'], isFalse);

      final stream = url('/remux/abc.mp4', {'safari': '1'});
      final (c1, b1, h1) = await get(stream, range: 'bytes=0-1');
      expect(c1, 206);
      expect(b1.length, 2);
      expect(h1.contentType?.mimeType, 'video/mp4');
      expect(h1.value(HttpHeaders.acceptRangesHeader), 'bytes');
      final cr = h1.value(HttpHeaders.contentRangeHeader)!;
      expect(cr, startsWith('bytes 0-1/'));
      final total = int.parse(cr.split('/').last);

      final (c2, all, h2) = await get(stream, range: 'bytes=0-');
      expect(c2, 206);
      expect(all.length, total);
      expect(
        h2.value(HttpHeaders.contentRangeHeader),
        'bytes 0-${total - 1}/$total',
      );
      expect(all.sublist(0, 2), b1);

      // Une plage au milieu est identique aux octets du flux complet.
      final (c3, mid, _) = await get(stream, range: 'bytes=1000-1999');
      expect(c3, 206);
      expect(mid, all.sublist(1000, 2000));

      // Le fichier (bourrage `free` compris) est un MP4 valide.
      final out = File('${dir.path}/out.mp4')..writeAsBytesSync(all);
      final p = await ffprobe(out.path);
      final streams = (p['streams'] as List).cast<Map<String, dynamic>>();
      final v = streams.firstWhere((s) => s['codec_type'] == 'video');
      final a = streams.firstWhere((s) => s['codec_type'] == 'audio');
      expect(v['codec_tag_string'], 'hvc1');
      expect(a['codec_name'], 'aac');
      expect(a['channels'], 2);
      expect(double.parse(p['format']['duration'] as String), greaterThan(10));

      final (c4, _, h4) = await get(stream, range: 'bytes=$total-');
      expect(c4, 416);
      expect(h4.value(HttpHeaders.contentRangeHeader), 'bytes */$total');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('bourrage : boîte MP4 free bien formée', () {
    final b = RemuxSpool.paddingBytes(100, 140, 100, 40);
    expect(ByteData.sublistView(b).getUint32(0), 40);
    expect(ascii.decode(b.sublist(4, 8)), 'free');
    expect(b.sublist(8).every((x) => x == 0), isTrue);
    // Lecture au milieu de l'en-tête.
    expect(RemuxSpool.paddingBytes(100, 140, 104, 4), ascii.encode('free'));
  });

  test(
    'POST /remux/{id}/stop arrête le remux temps réel (fichier du spool supprimé)',
    () async {
      final film = await makeTestFilm(
        dir,
        name: 'stop.mkv',
        seconds: 20,
        audioCodec: 'ac3',
      );
      await serve(film);
      final stream = url('/remux/abc.mp4', {'start': '0', 'safari': '1'});
      final (c, b, _) = await get(stream, range: 'bytes=0-1023');
      expect(c, 206);
      expect(b.length, 1024);
      final spool = File('${dir.path}/synchro-remux-abc-0.mp4');
      expect(spool.existsSync(), isTrue);

      final bad = await (await client.getUrl(url('/remux/abc/stop'))).close();
      await bad.drain<void>();
      expect(bad.statusCode, HttpStatus.methodNotAllowed);

      final forbidden = await (await client.postUrl(
        url('/remux/abc/stop', {'token': 'x'}),
      )).close();
      await forbidden.drain<void>();
      expect(forbidden.statusCode, HttpStatus.forbidden);

      final ok = await (await client.postUrl(url('/remux/abc/stop'))).close();
      await ok.drain<void>();
      expect(ok.statusCode, HttpStatus.noContent);
      expect(spool.existsSync(), isFalse);

      // Retour au stream : un nouveau remux repart normalement.
      final (c2, b2, _) = await get(stream, range: 'bytes=0-99');
      expect(c2, 206);
      expect(b2.length, 100);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
