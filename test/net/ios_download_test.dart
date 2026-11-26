import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/net/host_server.dart';
import 'package:app_synchro_film/net/ios_download_handler.dart';
import 'package:app_synchro_film/net/media_http_handler.dart';
import 'package:app_synchro_film/platform/ffmpeg_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  final skip = hasFfmpeg ? null : 'ffmpeg absent';
  late Directory dir;
  late HostServer server;
  late IosDownloadHandler handler;
  final client = HttpClient();

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('ios_download_test');
  });
  tearDownAll(() async {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  Future<void> serve(String film, {String? codec}) async {
    server = HostServer(token: 'secret', preferredPort: 0);
    final direct = MediaHttpHandler(
      token: 'secret',
      mediaId: 'abc',
      media: MediaRef.file(film),
      opener: FileRandomAccessMedia.open,
    );
    handler = IosDownloadHandler(
      token: 'secret',
      mediaId: 'abc',
      media: MediaRef.file(film),
      ffmpeg: ProcessFfmpegRunner(),
      direct: direct,
      videoCodec: () async => codec,
      tempDir: () async => dir,
    );
    server.addRoute('/download', handler.call);
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

  Future<List<String>> topLevelBoxes(String path) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final boxes = <String>[];
    int offset = 0;
    while (offset + 8 <= bytes.length) {
      final size32 = ByteData.sublistView(
        bytes,
        offset,
        offset + 4,
      ).getUint32(0, Endian.big);
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      boxes.add(type);
      if (size32 == 1) {
        if (offset + 16 > bytes.length) break;
        final size64 = ByteData.sublistView(
          bytes,
          offset + 8,
          offset + 16,
        ).getUint64(0, Endian.big);
        if (size64 < 16) break;
        offset += size64;
      } else if (size32 == 0) {
        break;
      } else {
        if (size32 < 8) break;
        offset += size32;
      }
    }
    return boxes;
  }

  test(
    'MKV H.264 + AC3 : transcodage vers MP4 compatible iOS',
    () async {
      final filmPath = await makeTestFilm(
        dir,
        name: 'film.mkv',
        seconds: 20,
        audioCodec: 'ac3',
        videoCodec: 'libx264',
        channels: 2,
      );

      await serve(filmPath);

      final u = url('/download');
      final (status, body, headers) = await get(u);

      expect(status, 200);
      expect(headers.contentType?.mimeType, 'video/mp4');
      final contentDisposition = headers.value('content-disposition');
      expect(contentDisposition, contains('filename="film_ios.mp4"'));

      final outPath = '${dir.path}/downloaded_film.mp4';
      await File(outPath).writeAsBytes(body);

      final probe = await ffprobe(outPath);
      final streams = probe['streams'] as List;
      final videoStream = streams.firstWhere((s) => s['codec_type'] == 'video');
      final audioStream = streams.firstWhere((s) => s['codec_type'] == 'audio');

      expect(videoStream['codec_name'], 'h264');
      expect(videoStream['codec_tag_string'], 'avc1');
      expect(audioStream['codec_name'], 'aac');
      expect(audioStream['channels'], 2);

      final boxes = await topLevelBoxes(outPath);
      final moovIdx = boxes.indexOf('moov');
      final mdatIdx = boxes.indexOf('mdat');
      expect(moovIdx, isNot(-1));
      expect(mdatIdx, isNot(-1));
      expect(moovIdx, lessThan(mdatIdx));

      final tempFilePath = '${dir.path}/synchro-ios-abc.mp4';
      expect(await File(tempFilePath).exists(), isTrue);

      final statusUri = url('/download/status');
      final (statusCodeStatus, statusBodyBytes, _) = await get(statusUri);
      expect(statusCodeStatus, 200);
      final statusJson =
          jsonDecode(utf8.decode(statusBodyBytes)) as Map<String, dynamic>;
      expect(statusJson['state'], 'ready');
      expect(statusJson['native'], false);
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: skip,
  );

  test(
    'MKV HEVC : transcodage vers HEVC avec tag hvc1',
    () async {
      final filmPath = await makeTestFilm(
        dir,
        name: 'hevc.mkv',
        seconds: 5,
        audioCodec: 'aac',
        videoCodec: 'libx265',
        channels: 2,
      );

      await serve(filmPath, codec: 'hevc');

      final u = url('/download');
      final (status, body, _) = await get(u);
      expect(status, 200);

      final outPath = '${dir.path}/downloaded_hevc.mp4';
      await File(outPath).writeAsBytes(body);

      final probe = await ffprobe(outPath);
      final streams = probe['streams'] as List;
      final videoStream = streams.firstWhere((s) => s['codec_type'] == 'video');

      expect(videoStream['codec_name'], 'hevc');
      expect(videoStream['codec_tag_string'], 'hvc1');
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: skip,
  );

  test(
    'MP4 HEVC étiqueté hev1 : copie et réétiquetage en hvc1',
    () async {
      final filmPath = await makeTestFilm(
        dir,
        name: 'hev1.mp4',
        seconds: 5,
        audioCodec: 'aac',
        videoCodec: 'libx265',
        channels: 2,
      );

      final sourceProbe = await ffprobe(filmPath);
      final sourceVideo = (sourceProbe['streams'] as List).firstWhere(
        (s) => s['codec_type'] == 'video',
      );
      expect(sourceVideo['codec_tag_string'], 'hev1');

      await serve(filmPath, codec: 'hevc');

      final u = url('/download');
      final (status, body, _) = await get(u);
      expect(status, 200);

      final outPath = '${dir.path}/downloaded_hev1.mp4';
      await File(outPath).writeAsBytes(body);

      final probe = await ffprobe(outPath);
      final videoStream = (probe['streams'] as List).firstWhere(
        (s) => s['codec_type'] == 'video',
      );
      expect(videoStream['codec_tag_string'], 'hvc1');
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: skip,
  );

  test(
    'MP4 H.264 + AAC natif : servi tel quel',
    () async {
      final filmPath = await makeTestFilm(
        dir,
        name: 'natif.mp4',
        seconds: 5,
        audioCodec: 'aac',
        videoCodec: 'libx264',
        channels: 2,
      );

      await serve(filmPath);

      final u = url('/download');
      final (status, body, _) = await get(u);
      expect(status, 200);

      final sourceFile = File(filmPath);
      expect(body.length, await sourceFile.length());

      final sourceBytes = await sourceFile.readAsBytes();
      expect(body, sourceBytes);

      final statusUri = url('/download/status');
      final (_, statusBodyBytes, _) = await get(statusUri);
      final statusJson =
          jsonDecode(utf8.decode(statusBodyBytes)) as Map<String, dynamic>;
      expect(statusJson['native'], true);

      final tempFilePath = '${dir.path}/synchro-ios-abc.mp4';
      expect(await File(tempFilePath).exists(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: skip,
  );

  test(
    'Range : requête partielle bytes=0-99 renvoie 206',
    () async {
      final filmPath = await makeTestFilm(
        dir,
        name: 'range.mp4',
        seconds: 10,
        audioCodec: 'aac',
        videoCodec: 'libx264',
        channels: 2,
      );

      await serve(filmPath);

      final u = url('/download');
      final (status, body, headers) = await get(u, range: 'bytes=0-99');

      expect(status, 206);
      expect(body.length, 100);
      final contentRange = headers.value(HttpHeaders.contentRangeHeader);
      expect(contentRange, startsWith('bytes 0-99/'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: skip,
  );

  test(
    'Mauvais token : renvoie 403 sur /download et /download/status',
    () async {
      final filmPath = await makeTestFilm(
        dir,
        name: 'token.mp4',
        seconds: 5,
        audioCodec: 'aac',
        videoCodec: 'libx264',
        channels: 2,
      );

      await serve(filmPath);

      final badDownloadUrl = url('/download', {'token': 'wrong'});
      final (statusDownload, _, _) = await get(badDownloadUrl);
      expect(statusDownload, 403);

      final badStatusUrl = url('/download/status', {'token': 'wrong'});
      final (statusStatus, _, _) = await get(badStatusUrl);
      expect(statusStatus, 403);
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: skip,
  );

  test(
    'POST /download/prepare et /download/status polling',
    () async {
      final filmPath = await makeTestFilm(
        dir,
        name: 'prepare.mkv',
        seconds: 10,
        audioCodec: 'ac3',
        videoCodec: 'libx264',
        channels: 2,
      );

      await serve(filmPath);

      final prepareUri = url('/download/prepare');
      final req = await client.postUrl(prepareUri);
      final res = await req.close();
      expect(res.statusCode, 200);

      final b = BytesBuilder();
      await for (final c in res) {
        b.add(c);
      }
      final initialJson =
          jsonDecode(utf8.decode(b.takeBytes())) as Map<String, dynamic>;
      expect(['preparing', 'ready'], contains(initialJson['state']));

      String currentState = initialJson['state'] as String;
      final stopwatch = Stopwatch()..start();
      while (currentState != 'ready' &&
          stopwatch.elapsed < const Duration(seconds: 60)) {
        await Future.delayed(const Duration(milliseconds: 200));
        final statusUri = url('/download/status');
        final (_, statusBodyBytes, _) = await get(statusUri);
        final statusJson =
            jsonDecode(utf8.decode(statusBodyBytes)) as Map<String, dynamic>;
        currentState = statusJson['state'] as String;
        if (currentState == 'error') {
          fail('Erreur pendant la préparation : ${statusJson['error']}');
        }
      }
      expect(currentState, 'ready');

      final tempFilePath = '${dir.path}/synchro-ios-abc.mp4';
      final tempFile = File(tempFilePath);
      expect(await tempFile.exists(), isTrue);
      final firstModified = await tempFile.lastModified();

      // Second GET /download ne doit pas relancer ffmpeg (date de modif inchangée)
      await Future.delayed(const Duration(seconds: 1));
      final u = url('/download');
      final (status2, _, _) = await get(u);
      expect(status2, 200);

      final secondModified = await tempFile.lastModified();
      expect(secondModified, firstModified);
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: skip,
  );

  test(
    'dispose() supprime le fichier temporaire',
    () async {
      final filmPath = await makeTestFilm(
        dir,
        name: 'dispose.mkv',
        seconds: 5,
        audioCodec: 'ac3',
        videoCodec: 'libx264',
        channels: 2,
      );

      await serve(filmPath);

      // Force préparation
      final u = url('/download');
      await get(u);

      final tempFilePath = '${dir.path}/synchro-ios-abc.mp4';
      final tempFile = File(tempFilePath);
      expect(await tempFile.exists(), isTrue);

      await handler.dispose();
      expect(await tempFile.exists(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: skip,
  );
}
