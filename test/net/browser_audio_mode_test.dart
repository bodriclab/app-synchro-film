import 'dart:io';
import 'dart:typed_data';

import 'package:app_synchro_film/core/audio_packet.dart';
import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/core/monotonic_clock.dart';
import 'package:app_synchro_film/core/session_mode.dart';
import 'package:app_synchro_film/modes/browser_audio_mode.dart';
import 'package:app_synchro_film/net/session/host_session.dart';
import 'package:app_synchro_film/platform/ffmpeg_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../player/fake_engine.dart';
import '../support/fixtures.dart';

void main() {
  final skip = hasFfmpeg ? null : 'ffmpeg absent';
  late Directory dir;
  late HostSession host;
  late MonotonicClock clock;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('mode5');
  });
  tearDownAll(() => dir.delete(recursive: true));

  setUp(() async {
    final film = hasFfmpeg
        ? await makeTestFilm(dir, seconds: 20)
        : (await File('${dir.path}/x.mkv').writeAsBytes([1])).path;
    clock = MonotonicClock();
    host = HostSession(
      engine: FakeEngine(now: clock.nowMs, durationMs: 20000),
      mode: const BrowserAudioMode(),
      media: MediaRef.file(film),
      preferredPort: 0,
      clock: clock,
      ffmpeg: () => ProcessFfmpegRunner(),
      loadAsset: (n) => File('web_client/$n').readAsString(),
    );
    await host.start();
  });
  tearDown(() => host.close());

  Future<(int, String)> get(String path) async {
    final c = HttpClient();
    final res = await (await c.getUrl(
      Uri.parse('http://127.0.0.1:${host.port}$path'),
    )).close();
    final body = await res.transform(const SystemEncoding().decoder).join();
    c.close();
    return (res.statusCode, body);
  }

  test('QR code et page audio (token requis, scripts locaux)', () async {
    final ep = host.endpointFor('10.0.0.2');
    expect(ep.mode, SessionMode.browserAudio);
    expect(
      ep.toUri().toString(),
      'http://10.0.0.2:${host.port}/?token=${host.token}',
    );
    expect((await get('/')).$1, 403);
    final (code, html) = await get('/?token=${host.token}');
    expect(code, 200);
    expect(html, contains('audio.js'));
    expect(html, contains('Activer le son'));
    expect(html, isNot(contains('http')), reason: 'aucune ressource externe');
    expect((await get('/audio.js')).$1, 200);
    expect((await get('/clock.js')).$1, 200);
  });

  test(
    'WebSocket /pcm : token, trames PCM horodatées, saut = nouvel epoch',
    () async {
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:${host.port}/pcm?token=faux'),
        throwsA(isA<WebSocketException>()),
      );
      final ws = await WebSocket.connect(
        'ws://127.0.0.1:${host.port}/pcm?token=${host.token}',
      );
      final packets = <AudioPacket>[];
      final sub = ws.listen((m) {
        final p = AudioPacket.decode(m as Uint8List);
        if (p != null) packets.add(p);
      });
      // En pause : pré-envoi limité (≈ 600 ms).
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(packets, isNotEmpty);
      expect(packets.last.positionMs, lessThanOrEqualTo(620));
      final p0 = packets.first;
      expect(p0.flags & kAudioFlagPcm, kAudioFlagPcm);
      expect(p0.payload.length, kAudioFrameBytes);
      expect(p0.positionMs % kAudioFrameMs, 0);
      bool loud(AudioPacket p) => p.payload.buffer
          .asInt16List(p.payload.offsetInBytes, p.payload.length ~/ 2)
          .any((s) => s.abs() > 1000);
      expect(packets.any(loud), isTrue, reason: 'sinus audible');

      // Lecture : ~1,2 s d'avance sur la timeline.
      await host.play();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final pos = host.controller.target!.positionAt(clock.nowMs());
      expect(packets.last.positionMs - pos, inInclusiveRange(1000, 1300));

      // Saut : nouvel epoch qui repart de la nouvelle position.
      final epoch = packets.last.epoch;
      await host.seekTo(10000);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final after = packets.where((p) => p.epoch != epoch).toList();
      expect(after, isNotEmpty);
      expect(after.first.positionMs, inInclusiveRange(10000, 10100));
      await sub.cancel();
      await ws.close();
    },
    skip: skip,
  );
}
