import 'dart:convert';
import 'dart:io';

import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/core/monotonic_clock.dart';
import 'package:app_synchro_film/core/session_endpoint.dart';
import 'package:app_synchro_film/core/subtitles.dart';
import 'package:app_synchro_film/modes/stream_mode.dart';
import 'package:app_synchro_film/net/session/guest_session.dart';
import 'package:app_synchro_film/net/session/host_session.dart';
import 'package:app_synchro_film/net/session/sync_session.dart';
import 'package:app_synchro_film/platform/ffmpeg_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../player/fake_engine.dart';
import '../support/fixtures.dart';
import 'session_test.dart' show waitFor;

const srt =
    '1\n00:00:01,000 --> 00:00:04,000\nBonjour à tous\n\n'
    '2\n00:00:10,000 --> 00:00:12,500\n<i>Fin</i>\n';

void main() {
  late Directory dir;
  late HostSession host;
  late FakeEngine hostEngine;
  final client = HttpClient();

  Future<void> startHost(String film) async {
    final clock = MonotonicClock();
    hostEngine = FakeEngine(now: clock.nowMs);
    host = HostSession(
      engine: hostEngine,
      mode: const StreamMode(),
      media: MediaRef.file(film),
      preferredPort: 0,
      clock: clock,
      ffmpeg: () => ProcessFfmpegRunner(),
    );
    await host.start();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('subs');
  });
  tearDown(() async {
    await host.close();
    await dir.delete(recursive: true);
  });

  GuestSession guest() {
    final clock = MonotonicClock();
    return GuestSession(
      engine: FakeEngine(now: clock.nowMs),
      mode: const StreamMode(),
      endpoint: SessionEndpoint(
        host: '127.0.0.1',
        port: host.port,
        token: host.token,
      ),
      clock: clock,
    );
  }

  Future<(int, String, String?)> get(String path, [String query = '']) async {
    final res = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:${host.port}$path?token=${host.token}$query'),
    )).close();
    return (
      res.statusCode,
      await utf8.decodeStream(res),
      res.headers.contentType?.mimeType,
    );
  }

  test('fichier externe : appliqué chez l\'hôte et chez l\'invité, '
      'servi en WebVTT décalé', () async {
    await File('${dir.path}/film.mkv').writeAsBytes(List.filled(5000, 1));
    await startHost('${dir.path}/film.mkv');
    final g = guest();
    await g.start();
    await waitFor(() => g.status == SessionStatus.connected);

    const ext = SubtitleSelection.external('film.fr.srt');
    await host.selectSubtitle(ext, text: srt);
    expect(hostEngine.shownSubtitles.last, (ext, srt));
    final ge = g.engine as FakeEngine;
    await waitFor(() => ge.shownSubtitles.isNotEmpty);
    expect(ge.shownSubtitles.last.$1, ext);
    expect(ge.shownSubtitles.last.$2, srt);
    expect(g.subtitle, ext);

    final (c1, vtt, mime) = await get('/subs/track.vtt', '&shift=-2000');
    expect(c1, 200);
    expect(mime, 'text/vtt');
    expect(vtt, startsWith('WEBVTT'));
    // 1 s - 2 s < 0 → début ramené à 0 ; 10 s → 8 s.
    expect(vtt, contains('00:00:00.000 --> 00:00:02.000'));
    expect(vtt, contains('00:00:08.000 --> 00:00:10.500'));
    expect(vtt, contains('Bonjour à tous'));

    final (c403, _, _) = await client
        .getUrl(Uri.parse('http://127.0.0.1:${host.port}/subs/file'))
        .then((r) => r.close())
        .then((r) async => (r.statusCode, '', null));
    expect(c403, 403);

    // Désactivation propagée ; plus de VTT servi.
    await host.selectSubtitle(const SubtitleSelection.off());
    await waitFor(() => ge.shownSubtitles.last.$1.isOff);
    final (c404, _, _) = await get('/subs/track.vtt');
    expect(c404, 404);
    await g.close();
  });

  test(
    'un invité qui arrive après le choix reçoit la piste intégrée',
    () async {
      await File('${dir.path}/film.mkv').writeAsBytes(List.filled(5000, 1));
      await startHost('${dir.path}/film.mkv');
      const emb = SubtitleSelection.embedded(
        1,
        language: 'eng',
        codec: 'subrip',
      );
      await host.selectSubtitle(emb);
      final g = guest();
      await g.start();
      final ge = g.engine as FakeEngine;
      await waitFor(() => ge.shownSubtitles.isNotEmpty);
      expect(ge.shownSubtitles.last.$1, emb);
      expect(ge.shownSubtitles.last.$1.index, 1);
      await g.close();
    },
  );

  test(
    'piste intégrée extraite par FFmpeg ; sous-titres image refusés',
    () async {
      final film = await makeTestFilm(dir, seconds: 6);
      final subs = File('${dir.path}/s.srt')..writeAsStringSync(srt);
      final withSubs = '${dir.path}/avec-sous-titres.mkv';
      final r = await Process.run('ffmpeg', [
        '-v', 'error', '-y', '-i', film, '-i', subs.path, //
        '-map', '0', '-map', '1', '-c', 'copy', '-c:s', 'srt', withSubs,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      await startHost(withSubs);
      await host.selectSubtitle(
        const SubtitleSelection.embedded(0, codec: 'subrip'),
      );
      final (c, vtt, _) = await get('/subs/track.vtt', '&shift=500');
      expect(c, 200);
      expect(vtt, contains('00:00:01.500 --> 00:00:04.500'));
      expect(vtt, contains('Bonjour à tous'));

      await host.selectSubtitle(
        const SubtitleSelection.embedded(0, codec: 'hdmv_pgs_subtitle'),
      );
      final (c415, _, _) = await get('/subs/track.vtt');
      expect(c415, 415);
    },
    skip: hasFfmpeg ? null : 'ffmpeg absent',
  );

  test('ASS converti en WebVTT par FFmpeg', () async {
    await File('${dir.path}/film.mkv').writeAsBytes(List.filled(5000, 1));
    await startHost('${dir.path}/film.mkv');
    final tmp = File('${dir.path}/s.srt')..writeAsStringSync(srt);
    final conv = await Process.run('ffmpeg', [
      '-v', 'error', '-i', tmp.path, '-f', 'ass', '-', //
    ], stdoutEncoding: utf8);
    final assText = conv.stdout as String;
    expect(assText, contains('[Script Info]'));
    await host.selectSubtitle(
      const SubtitleSelection.external('film.ass'),
      text: assText,
    );
    final (c, vtt, _) = await get('/subs/track.vtt');
    expect(c, 200);
    expect(vtt, startsWith('WEBVTT'));
    expect(vtt, contains('Bonjour à tous'));
  }, skip: hasFfmpeg ? null : 'ffmpeg absent');
}
