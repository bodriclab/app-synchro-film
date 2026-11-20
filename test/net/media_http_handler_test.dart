import 'dart:io';
import 'dart:typed_data';

import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/net/host_server.dart';
import 'package:app_synchro_film/net/media_http_handler.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opener qui compte les ouvertures / fermetures (pas de fuite de descripteur).
class CountingOpener {
  int opened = 0;
  int closed = 0;
  Future<RandomAccessMedia> call(String uri) async {
    opened++;
    return _Tracked(await openFileMedia(uri), this);
  }
}

class _Tracked implements RandomAccessMedia {
  _Tracked(this.inner, this.owner);
  final RandomAccessMedia inner;
  final CountingOpener owner;
  @override
  int get length => inner.length;
  @override
  Future<Uint8List> read(int o, int l) => inner.read(o, l);
  @override
  Future<void> close() async {
    owner.closed++;
    await inner.close();
  }
}

void main() {
  late Directory dir;
  late HostServer server;
  late MediaHttpHandler handler;
  late CountingOpener opener;
  late Uint8List data;
  final client = HttpClient();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('http');
    data = Uint8List.fromList(List.generate(700000, (i) => (i * 7) % 256));
    final f = File('${dir.path}/film.mp4')..writeAsBytesSync(data);
    opener = CountingOpener();
    server = HostServer(token: 'secret', preferredPort: 0);
    handler = MediaHttpHandler(
      token: 'secret',
      mediaId: 'abc',
      media: MediaRef.file(f.path),
      opener: opener.call,
      chunkSize: 64 * 1024,
    );
    server.addRoute('/media/', handler.call);
    await server.start();
  });

  tearDown(() async {
    await server.dispose();
    await dir.delete(recursive: true);
  });

  Uri url({String id = 'abc', String? token = 'secret'}) => Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: '/media/$id',
        queryParameters: token == null ? null : {'token': token},
      );

  Future<(HttpClientResponse, Uint8List)> fetch(
    Uri u, {
    String method = 'GET',
    String? range,
  }) async {
    final req = await client.openUrl(method, u);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    final b = BytesBuilder();
    await for (final c in res) {
      b.add(c);
    }
    return (res, b.takeBytes());
  }

  test('GET complet : 200, Accept-Ranges, type MIME', () async {
    final (res, body) = await fetch(url());
    expect(res.statusCode, 200);
    expect(res.headers.value('accept-ranges'), 'bytes');
    expect(res.headers.contentType?.mimeType, 'video/mp4');
    expect(res.contentLength, data.length);
    expect(body, data);
  });

  test('Range : 206 + Content-Range + bons octets', () async {
    final (res, body) = await fetch(url(), range: 'bytes=100000-299999');
    expect(res.statusCode, 206);
    expect(res.headers.value('content-range'), 'bytes 100000-299999/700000');
    expect(body, data.sublist(100000, 300000));

    final (r2, b2) = await fetch(url(), range: 'bytes=-10');
    expect(r2.statusCode, 206);
    expect(b2, data.sublist(data.length - 10));

    final (r3, b3) = await fetch(url(), range: 'bytes=699990-');
    expect(r3.statusCode, 206);
    expect(b3, data.sublist(699990));
  });

  test('Range hors fichier : 416', () async {
    final (res, _) = await fetch(url(), range: 'bytes=800000-');
    expect(res.statusCode, 416);
    expect(res.headers.value('content-range'), 'bytes */700000');
  });

  test('HEAD : en-têtes sans corps', () async {
    final (res, body) = await fetch(url(), method: 'HEAD', range: 'bytes=0-9');
    expect(res.statusCode, 206);
    expect(res.contentLength, 10);
    expect(body, isEmpty);
  });

  test('token manquant ou faux : 403 ; mauvais id : 404 ; POST : 405',
      () async {
    expect((await fetch(url(token: null))).$1.statusCode, 403);
    expect((await fetch(url(token: 'faux'))).$1.statusCode, 403);
    expect((await fetch(url(id: 'zzz'))).$1.statusCode, 404);
    expect((await fetch(url(), method: 'POST')).$1.statusCode, 405);
    expect(opener.opened, 0);
  });

  test('chaque requête ferme son accès au média, même interrompue', () async {
    await fetch(url(), range: 'bytes=0-99');
    // Client qui abandonne en cours de route.
    final req = await client.openUrl('GET', url());
    final res = await req.close();
    await res.first;
    await res.detachSocket().then((s) => s.destroy());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(opener.opened, 2);
    expect(opener.closed, 2);
  });
}
