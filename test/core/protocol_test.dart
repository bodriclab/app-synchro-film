import 'dart:io';

import 'package:app_synchro_film/core/file_fingerprint.dart';
import 'package:app_synchro_film/core/playback_state.dart';
import 'package:app_synchro_film/core/protocol.dart';
import 'package:app_synchro_film/core/session_endpoint.dart';
import 'package:app_synchro_film/core/session_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('protocole', () {
    test('aller-retour JSON de chaque message', () {
      const fp = FileFingerprint(size: 42, partialHash: 'abcdef0123456789');
      final msgs = <SyncMessage>[
        const HelloMsg(
          role: PeerRole.guest,
          deviceName: 'Pixel',
          mode: SessionMode.doubleFile,
          fingerprint: fp,
          durationMs: 1000,
          fileMatch: true,
        ),
        const PingMsg(12),
        const PongMsg(t0: 1, t1: 2, t2: 3),
        const StateMsg(PlaybackState(
          playing: true,
          positionMs: 1234,
          atHostMs: 999,
          seq: 7,
        )),
        const CmdMsg.seek(5000),
        const CmdMsg.play(),
        const ErrorMsg('busy', 'occupé'),
      ];
      for (final m in msgs) {
        final back = SyncMessage.decode(m.encode());
        expect(back.runtimeType, m.runtimeType);
        expect(back.toJson(), m.toJson());
      }
    });

    test('messages invalides', () {
      expect(() => SyncMessage.decode('pas du json'),
          throwsA(isA<ProtocolException>()));
      expect(() => SyncMessage.decode('{"type":"nope"}'),
          throwsA(isA<ProtocolException>()));
      expect(() => SyncMessage.decode('{"type":"cmd","action":"seek"}'),
          throwsA(isA<ProtocolException>()));
      expect(() => SyncMessage.decode('{"type":"ping"}'),
          throwsA(isA<ProtocolException>()));
    });

    test('PlaybackState.positionAt', () {
      const s = PlaybackState(playing: true, positionMs: 1000, atHostMs: 500);
      expect(s.positionAt(1500), 2000);
      expect(s.positionAt(1500, durationMs: 1800), 1800);
      expect(s.copyWith(playing: false).positionAt(9999), 1000);
    });
  });

  group('SessionEndpoint', () {
    test('URI du QR code aller-retour', () {
      const ep = SessionEndpoint(
        host: '192.168.43.1',
        port: 47470,
        token: 'abc23xyz',
      );
      final uri = ep.toUri().toString();
      expect(uri, 'synchrofilm://192.168.43.1:47470?token=abc23xyz&mode=double_file');
      expect(SessionEndpoint.tryParse(uri), ep);
      expect(ep.wsUri.toString(), 'ws://192.168.43.1:47470/ws?token=abc23xyz');
    });

    test('saisie manuelle IP:port + token', () {
      final ep = SessionEndpoint.tryParse('10.0.0.5:5000', fallbackToken: 't');
      expect(ep?.host, '10.0.0.5');
      expect(ep?.port, 5000);
      expect(SessionEndpoint.tryParse('10.0.0.5:5000'), isNull);
      expect(SessionEndpoint.tryParse('http://x:1?token=a'), isNull);
      expect(SessionEndpoint.tryParse(''), isNull);
    });

    test('token généré', () {
      final t = generateSessionToken();
      expect(t, hasLength(8));
      expect(RegExp(r'^[a-z2-9]+$').hasMatch(t), isTrue);
    });
  });

  group('FileFingerprint', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('fp'));
    tearDown(() => dir.delete(recursive: true));

    Future<String> write(String name, List<int> bytes) async {
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes);
      return f.path;
    }

    test('identique pour deux copies, différent si la fin change', () async {
      const chunk = 1024;
      final data = List<int>.generate(10 * chunk, (i) => i % 251);
      final a = await FileFingerprint.compute(await write('a', data),
          chunkSize: chunk);
      final b = await FileFingerprint.compute(await write('b', data),
          chunkSize: chunk);
      expect(a.matches(b), isTrue);

      final tail = List<int>.of(data)..[data.length - 1] ^= 0xff;
      final c = await FileFingerprint.compute(await write('c', tail),
          chunkSize: chunk);
      expect(a.matches(c), isFalse);
      // Le milieu n'est pas haché (compromis volontaire).
      final mid = List<int>.of(data)..[5 * chunk] ^= 0xff;
      final d = await FileFingerprint.compute(await write('d', mid),
          chunkSize: chunk);
      expect(a.matches(d), isTrue);
    });

    test('petit fichier et sérialisation', () async {
      final fp = await FileFingerprint.compute(await write('s', [1, 2, 3]));
      expect(fp.size, 3);
      expect(FileFingerprint.fromJson(fp.toJson()), fp);
      expect(FileFingerprint.fromJson('x'), isNull);
    });
  });
}
