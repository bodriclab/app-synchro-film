import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/core/monotonic_clock.dart';
import 'package:app_synchro_film/core/protocol.dart';
import 'package:app_synchro_film/core/session_endpoint.dart';
import 'package:app_synchro_film/core/session_mode.dart';
import 'package:app_synchro_film/modes/browser_mode.dart';
import 'package:app_synchro_film/net/peer_channel.dart';
import 'package:app_synchro_film/net/session/host_session.dart';
import 'package:app_synchro_film/platform/ffmpeg_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../player/fake_engine.dart';
import '../support/fixtures.dart';

void main() {
  late Directory dir;
  late HostSession host;
  late String film;
  final client = HttpClient();

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('browser');
    if (hasFfmpeg) film = await makeTestFilm(dir, audioCodec: 'ac3');
  });
  tearDownAll(() => dir.delete(recursive: true));

  setUp(() async {
    final clock = MonotonicClock();
    host = HostSession(
      engine: FakeEngine(now: clock.nowMs),
      mode: const BrowserMode(),
      media: MediaRef.file(hasFfmpeg ? film : '${dir.path}/x.mkv'),
      preferredPort: 0,
      clock: clock,
      ffmpeg: () => ProcessFfmpegRunner(),
      loadAsset: (name) => File('web_client/$name').readAsString(),
    );
    if (!hasFfmpeg) await File('${dir.path}/x.mkv').writeAsBytes([1, 2, 3]);
    await host.start();
  });
  tearDown(() => host.close());

  Uri url(String path, [Map<String, String>? q]) => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: host.port,
    path: path,
    queryParameters: q,
  );

  Future<(int, Uint8List, HttpHeaders)> get(Uri u) async {
    final res = await (await client.getUrl(u)).close();
    final b = BytesBuilder();
    await for (final c in res) {
      b.add(c);
    }
    return (res.statusCode, b.takeBytes(), res.headers);
  }

  test('QR code : lien http direct vers la page', () {
    final ep = host.endpointFor('192.168.43.1');
    expect(ep.mode, SessionMode.browser);
    expect(
      ep.toUri().toString(),
      'http://192.168.43.1:${host.port}/?token=${host.token}',
    );
  });

  test(
    'page web : protégée par token, JS/CSS servis, rien d\'externe',
    () async {
      final (c403, _, _) = await get(url('/'));
      expect(c403, 403);
      final (c200, html, h) = await get(url('/', {'token': host.token}));
      expect(c200, 200);
      expect(h.contentType?.mimeType, 'text/html');
      final page = utf8.decode(html);
      expect(page, contains('app.js'));
      final (cjs, js, _) = await get(url('/app.js'));
      expect(cjs, 200);
      final script = utf8.decode(js);
      expect(script, contains('playbackRate'));
      for (final text in [page, script]) {
        expect(
          text,
          isNot(contains('https://')),
          reason: 'aucune ressource CDN',
        );
        expect(
          text,
          isNot(contains('http://')),
          reason: 'aucune ressource externe',
        );
      }
      expect((await get(url('/app.css'))).$1, 200);
      expect((await get(url('/inconnu'))).$1, 404);
    },
  );

  test('hello de la page : chemin du média, remux requis pour MKV', () async {
    final ch = await PeerChannel.connect(
      SessionEndpoint(
        host: '127.0.0.1',
        port: host.port,
        token: host.token,
        mode: SessionMode.browser,
      ).wsUri,
    );
    final first = ch.messages.firstWhere((m) => m is HelloMsg);
    ch.send(
      const HelloMsg(
        role: PeerRole.guest,
        deviceName: 'Navigateur',
        mode: SessionMode.browser,
      ),
    );
    final hello = await first as HelloMsg;
    expect(hello.mediaPath, startsWith('/media/'));
    expect(hello.remux, isTrue);
    expect(hello.mediaName, endsWith('.mkv'));
    await ch.close();
  });

  test('remux MKV → MP4 fragmenté avec offset exact (ffmpeg réel)', () async {
    final id = (await _mediaId(host));
    final (ci, info, _) = await get(
      url('/remux/$id/info', {'token': host.token, 'start': '30000'}),
    );
    expect(ci, 200);
    final j = jsonDecode(utf8.decode(info)) as Map<String, dynamic>;
    // Keyframes toutes les 4 s : la plus proche avant 30 s est à 28 s.
    expect((j['offsetMs'] as int) - 28000, inInclusiveRange(-200, 0));
    expect(j['videoCodec'], 'h264');
    expect(j['audioCodec'], 'ac3');
    expect(j['transcodeAudio'], isTrue);

    final (cs, mp4, hs) = await get(
      url('/remux/$id.mp4', {'token': host.token, 'start': '30000'}),
    );
    expect(cs, 200);
    expect(hs.contentType?.mimeType, 'video/mp4');
    expect(utf8.decode(mp4.sublist(4, 8)), 'ftyp');
    final f = File('${dir.path}/out.mp4')..writeAsBytesSync(mp4);
    final probe = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'stream=codec_name',
      '-of',
      'csv=p=0',
      f.path,
    ]);
    expect((probe.stdout as String).split('\n'), containsAll(['h264', 'aac']));
    final dur = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'csv=p=0',
      f.path,
    ]);
    // 40 s de film - 28 s d'offset ≈ 12 s.
    expect(double.parse((dur.stdout as String).trim()), closeTo(12, 0.5));

    expect((await get(url('/remux/$id.mp4'))).$1, 403);
  }, skip: !hasFfmpeg ? 'ffmpeg absent' : null);
}

Future<String> _mediaId(HostSession host) async {
  final ch = await PeerChannel.connect(
    SessionEndpoint(
      host: '127.0.0.1',
      port: host.port,
      token: host.token,
      mode: SessionMode.browser,
    ).wsUri,
  );
  final first = ch.messages.firstWhere((m) => m is HelloMsg);
  ch.send(
    const HelloMsg(
      role: PeerRole.guest,
      deviceName: 'test',
      mode: SessionMode.browser,
    ),
  );
  final hello = await first as HelloMsg;
  await ch.close();
  return hello.mediaPath!.split('/').last;
}
