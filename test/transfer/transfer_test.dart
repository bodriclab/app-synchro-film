import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/net/media_http_handler.dart';
import 'package:app_synchro_film/transfer/download_sink.dart';
import 'package:app_synchro_film/transfer/downloader.dart';
import 'package:app_synchro_film/transfer/transfer_server.dart';
import 'package:flutter_test/flutter_test.dart';

class _SlowSink implements DownloadSink {
  _SlowSink(this._inner, this.onWrite);
  final DownloadSink _inner;
  final Future<void> Function() onWrite;

  @override
  Future<int> prepare(int? totalSize) => _inner.prepare(totalSize);

  @override
  Future<void> truncate() => _inner.truncate();

  @override
  Future<void> write(List<int> data) async {
    await onWrite();
    await _inner.write(data);
  }

  @override
  Future<String> finish() => _inner.finish();

  @override
  Future<void> close() => _inner.close();
}

void main() {
  late Directory outDir;
  late Directory recus;
  late File sourceFile;
  late TransferServer server;
  late String sourcePath;

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('transfer');
    sourcePath = '${outDir.path}/Le film é.mkv';
    recus = Directory('${outDir.path}/recus')..createSync();
    sourceFile = File(sourcePath);

    final bytes = Uint8List(3000000);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (i * 31) % 251;
    }
    await sourceFile.writeAsBytes(bytes);

    server = TransferServer(media: MediaRef.file(sourcePath), preferredPort: 0);
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    if (outDir.existsSync()) {
      await outDir.delete(recursive: true);
    }
  });

  Future<HttpClientResponse> get(Uri uri) async {
    final client = HttpClient();
    final req = await client.getUrl(uri);
    final res = await req.close();
    client.close();
    return res;
  }

  test('page navigateur, info JSON et lien', () async {
    final validUri = Uri.parse(
      'http://127.0.0.1:${server.port}/?token=${server.token}',
    );
    final res = await get(validUri);
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'text/html');
    final body = await utf8.decodeStream(res);
    expect(body.contains('Télécharger'), true);
    expect(body.contains('Le film é.mkv'), true);
    expect(body.contains('/media/f?token='), true);

    final invalidUri = Uri.parse(
      'http://127.0.0.1:${server.port}/?token=mauvais',
    );
    final resForbidden = await get(invalidUri);
    expect(resForbidden.statusCode, 403);
    await resForbidden.drain();

    final linkObj = TransferLink(
      host: '127.0.0.1',
      port: server.port,
      token: server.token,
    );
    final info = await linkObj.fetchInfo();
    expect(info.name, 'Le film é.mkv');
    expect(info.size, 3000000);

    expect(
      server.linkFor('192.168.1.5').toString(),
      'http://192.168.1.5:${server.port}/?token=${server.token}',
    );

    final parsed = TransferLink.tryParse(
      'http://192.168.1.5:${server.port}/?token=${server.token}',
    );
    expect(parsed, isNotNull);
    expect(parsed?.host, '192.168.1.5');
    expect(parsed?.port, server.port);
    expect(parsed?.token, server.token);

    expect(TransferLink.tryParse('synchrofilm://x'), isNull);
    expect(TransferLink.tryParse('http://1.2.3.4:5/'), isNull);
  });

  test('téléchargement complet avec progression', () async {
    final link = TransferLink(
      host: '127.0.0.1',
      port: server.port,
      token: server.token,
    );
    final downloader = Downloader(
      url: link.fileUri,
      sink: FileDownloadSink(recus, 'Le film é.mkv'),
    );

    final progresses = <TransferProgress>[];
    final sub = downloader.progress.listen(progresses.add);

    final resultPath = await downloader.run();
    await sub.cancel();

    expect(resultPath.endsWith('Le film é.mkv'), true);
    final downloadedBytes = await File(resultPath).readAsBytes();
    final sourceBytes = await sourceFile.readAsBytes();
    expect(downloadedBytes, sourceBytes);

    expect(progresses.isNotEmpty, true);
    expect(progresses.last.received, 3000000);
    expect(progresses.last.total, 3000000);
    expect(server.bytesSent >= 3000000, true);

    final info = await link.fetchInfo();
    expect(info.name, 'Le film é.mkv');
    expect(info.size, 3000000);
  });

  test('reprise après un fichier partiel', () async {
    final partFile = File('${recus.path}/Le film é.mkv.part');
    final metaFile = File('${recus.path}/Le film é.mkv.part.json');

    final sourceBytes = await sourceFile.readAsBytes();
    await partFile.writeAsBytes(sourceBytes.sublist(0, 1000000));
    await metaFile.writeAsString(jsonEncode({'size': 3000000}));

    final link = TransferLink(
      host: '127.0.0.1',
      port: server.port,
      token: server.token,
    );
    final downloader = Downloader(
      url: link.fileUri,
      sink: FileDownloadSink(recus, 'Le film é.mkv'),
    );

    final progresses = <TransferProgress>[];
    final sub = downloader.progress.listen(progresses.add);

    final resultPath = await downloader.run();
    await sub.cancel();

    expect(await File(resultPath).readAsBytes(), sourceBytes);
    expect(progresses.first.resumedFrom, 1000000);
    expect(server.bytesSent < 2100000, true);
  });

  test("partiel d'un autre fichier ignoré", () async {
    final partFile = File('${recus.path}/Le film é.mkv.part');
    final metaFile = File('${recus.path}/Le film é.mkv.part.json');

    final sourceBytes = await sourceFile.readAsBytes();
    await partFile.writeAsBytes(sourceBytes.sublist(0, 500));
    await metaFile.writeAsString(jsonEncode({'size': 999}));

    final link = TransferLink(
      host: '127.0.0.1',
      port: server.port,
      token: server.token,
    );
    final downloader = Downloader(
      url: link.fileUri,
      sink: FileDownloadSink(recus, 'Le film é.mkv'),
    );

    final progresses = <TransferProgress>[];
    final sub = downloader.progress.listen(progresses.add);

    final resultPath = await downloader.run();
    await sub.cancel();

    expect(await File(resultPath).readAsBytes(), sourceBytes);
    expect(progresses.first.resumedFrom, 0);
  });

  test("nom déjà pris : suffixe (2)", () async {
    final existingFile = File('${recus.path}/Le film é.mkv');
    await existingFile.writeAsBytes([1, 2, 3]);

    final link = TransferLink(
      host: '127.0.0.1',
      port: server.port,
      token: server.token,
    );
    final downloader = Downloader(
      url: link.fileUri,
      sink: FileDownloadSink(recus, 'Le film é.mkv'),
    );

    final resultPath = await downloader.run();
    expect(resultPath.endsWith('Le film é (2).mkv'), true);
    expect(await File(resultPath).length(), 3000000);
  });

  test("jeton invalide : échec immédiat", () async {
    final link = TransferLink(
      host: '127.0.0.1',
      port: server.port,
      token: 'faux',
    );
    final downloader = Downloader(
      url: link.fileUri,
      sink: FileDownloadSink(recus, 'Le film é.mkv'),
    );

    await expectLater(downloader.run(), throwsA(isA<TransferFailed>()));
  });

  test("annulation : le partiel est conservé", () async {
    final link = TransferLink(
      host: '127.0.0.1',
      port: server.port,
      token: server.token,
    );
    final slowSink = _SlowSink(
      FileDownloadSink(recus, 'Le film é.mkv'),
      () => Future.delayed(const Duration(milliseconds: 40)),
    );

    final downloader = Downloader(url: link.fileUri, sink: slowSink);

    final sub = downloader.progress.listen((p) {
      if (p.received > 100000) {
        downloader.cancel();
      }
    });

    await expectLater(downloader.run(), throwsA(isA<TransferCancelled>()));
    await sub.cancel();

    final partFile = File('${recus.path}/Le film é.mkv.part');
    expect(await partFile.exists(), true);
    expect(await partFile.length() > 0, true);
  });

  test("Content-Disposition", () async {
    final cd = MediaHttpHandler.contentDisposition('Été "x".mkv');
    expect(cd.startsWith('attachment; filename="'), true);
    expect(cd.contains("filename*=UTF-8''%C3%89t%C3%A9%20%22x%22.mkv"), true);
    expect(cd.contains('filename="_t_ _x_.mkv"'), true);

    final link = TransferLink(
      host: '127.0.0.1',
      port: server.port,
      token: server.token,
    );
    final res = await get(Uri.parse('${link.fileUri}&download=1'));
    expect(res.statusCode, 200);
    final headerCd = res.headers.value('content-disposition');
    expect(headerCd?.startsWith('attachment'), true);
    await res.drain();

    final client = HttpClient();
    final req = await client.getUrl(link.fileUri);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
    final rangeRes = await req.close();
    expect(rangeRes.statusCode, 206);
    final rangeBytes = await rangeRes.fold<List<int>>(
      [],
      (a, b) => a..addAll(b),
    );
    client.close();

    final sourceBytes = await sourceFile.readAsBytes();
    expect(rangeBytes, sourceBytes.sublist(10, 20));
  });
}
