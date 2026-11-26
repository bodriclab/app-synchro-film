// Test de bout en bout du mode 4 dans un vrai navigateur (Chrome headless,
// piloté via le protocole DevTools). Ignoré si Chrome ou ffmpeg manquent.
import 'dart:convert';
import 'dart:io';

import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/core/monotonic_clock.dart';
import 'package:app_synchro_film/core/subtitles.dart';
import 'package:app_synchro_film/modes/browser_mode.dart';
import 'package:app_synchro_film/net/session/host_session.dart';
import 'package:app_synchro_film/net/session/sync_session.dart';
import 'package:app_synchro_film/platform/ffmpeg_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../player/fake_engine.dart';
import '../support/chrome.dart';
import '../support/fixtures.dart';

void main() {
  final chrome = findChrome();
  final skip = chrome == null || !hasFfmpeg ? 'Chrome ou ffmpeg absent' : null;
  late Directory dir;
  HeadlessChrome? browser;
  HeadlessChrome? iphone;
  const iphoneUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
      'Mobile/15E148 Safari/604.1';

  setUpAll(() async {
    if (skip != null) return;
    dir = await Directory.systemTemp.createTemp('e2e');
    browser = await HeadlessChrome.start(chrome!);
  });

  tearDownAll(() async {
    await browser?.close();
    await iphone?.close();
    if (skip == null) await dir.delete(recursive: true).catchError((_) => dir);
  });

  Future<ChromePage> open(String url) => browser!.open(url);

  Future<void> scenario(
    String filmName,
    String audioCodec,
    bool remux, {
    bool safari = false,
  }) async {
    final film = await makeTestFilm(
      dir,
      name: filmName,
      seconds: 60,
      audioCodec: audioCodec,
    );
    final clock = MonotonicClock();
    final host = HostSession(
      engine: FakeEngine(now: clock.nowMs),
      mode: const BrowserMode(),
      media: MediaRef.file(film),
      preferredPort: 0,
      clock: clock,
      ffmpeg: () => ProcessFfmpegRunner(),
      loadAsset: (n) => File('web_client/$n').readAsString(),
    );
    await host.start();
    final url = host.endpointFor('127.0.0.1').toUri().toString();
    final page = safari
        ? await (iphone ??= await HeadlessChrome.start(
            chrome!,
            userAgent: iphoneUa,
          )).open(url)
        : await open(url);
    try {
      final sw = Stopwatch()..start();
      while (host.status != SessionStatus.connected) {
        if (sw.elapsed.inSeconds > 10) fail('la page ne s\'est pas connectée');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      Future<Map<String, dynamic>> snap() async => jsonDecode(
        await page.eval(
          'JSON.stringify({drift: synchroFilm.drift, paused: synchroFilm.video.paused,'
          ' t: synchroFilm.video.currentTime, remux: synchroFilm.useRemux,'
          ' safari: synchroFilm.safari, src: synchroFilm.video.currentSrc,'
          ' err: synchroFilm.video.error && synchroFilm.video.error.code,'
          ' lead: synchroFilm.corr.seekLead, trace: synchroFilm.trace.join(" | "),'
          ' samples: synchroFilm.clock.samples.length})',
        ) as String,
      ) as Map<String, dynamic>;

      Future<Map<String, dynamic>> settle(String label) async {
        Map<String, dynamic> s = {};
        // Jusqu'à 30 s : en flux réemballé, l'écart de démarrage est résorbé
        // par la seule correction de débit (±2 %).
        for (var i = 0; i < 120; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          s = await snap();
          final d = s['drift'] as num?;
          if (s['paused'] == false && d != null && d.abs() < 80) {
            // Stable sur 1 s ?
            var ok = true;
            for (var k = 0; k < 4; k++) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
              final s2 = await snap();
              if (((s2['drift'] as num?)?.abs() ?? 9999) >= 80) ok = false;
              s = s2;
            }
            if (ok) return s;
          }
        }
        fail('$label : pas synchronisé : $s');
      }

      await host.play();
      final a = await settle('lecture');
      expect(a['remux'], remux);
      expect(a['safari'], safari);
      if (safari) expect(a['src'] as String, contains('safari=1'));
      expect(a['err'], isNull);

      await host.seekTo(30000);
      final b = await settle('saut à 30 s');
      expect((b['drift'] as num).abs(), lessThan(80));

      // La page pilote aussi : pause depuis le navigateur.
      await page.eval("synchroFilm.cmd('pause')");
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(host.isPlaying, isFalse);
      expect((await snap())['paused'], isTrue);
      // ignore: avoid_print
      print(
        '$filmName : écart après lecture ${a['drift']} ms, après saut ${b['drift']} ms',
      );
    } finally {
      await page.close();
      await host.close();
    }
  }

  test(
    'MP4 lu directement dans Chrome, synchronisé',
    () async {
      await scenario('film.mp4', 'aac', false);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'MKV (AC3) réemballé à la volée, synchronisé',
    () async {
      await scenario('film.mkv', 'ac3', true);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'Safari iOS simulé : MP4 (Opus) forcé en remux Range + AAC, synchronisé',
    () async {
      await scenario('ios.mp4', 'libopus', true, safari: true);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'sous-titres de l\'hôte affichés dans la page (<track> WebVTT, décalé '
    'après un saut en remux)',
    () async {
      final film = await makeTestFilm(dir, name: 'st.mkv', seconds: 60);
      final srt = File('${dir.path}/st.srt')
        ..writeAsStringSync(
          '1\n00:00:02,000 --> 00:00:04,000\nDébut\n\n'
          '2\n00:00:41,000 --> 00:00:43,000\nVers la fin\n',
        );
      final withSubs = '${dir.path}/st-subs.mkv';
      final r = await Process.run('ffmpeg', [
        '-v', 'error', '-y', '-i', film, '-i', srt.path, //
        '-map', '0', '-map', '1', '-c', 'copy', '-c:s', 'srt', withSubs,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final clock = MonotonicClock();
      final host = HostSession(
        engine: FakeEngine(now: clock.nowMs),
        mode: const BrowserMode(),
        media: MediaRef.file(withSubs),
        preferredPort: 0,
        clock: clock,
        ffmpeg: () => ProcessFfmpegRunner(),
        loadAsset: (n) => File('web_client/$n').readAsString(),
      );
      await host.start();
      await host.seekTo(40000);
      final page = await open(host.endpointFor('127.0.0.1').toUri().toString());
      try {
        Future<List<dynamic>> cues(bool Function(List<dynamic>) ok) async {
          for (var i = 0; i < 80; i++) {
            final c = await page.eval(
              'window.synchroFilm ? '
              'JSON.stringify(synchroFilm.subtitleCues()) : "null"',
            );
            final list = jsonDecode(c as String) as List<dynamic>?;
            if (list != null && ok(list)) return list;
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          fail('cues non chargés');
        }

        await host.selectSubtitle(
          const SubtitleSelection.embedded(0, codec: 'subrip'),
        );
        // Page ouverte alors que l'hôte est à 40 s : flux réemballé depuis
        // l'image clé de 40 s → le sous-titre de 41 s tombe à 1 s du temps
        // vidéo, celui de 2 s est supprimé.
        final off = await () async {
          for (var i = 0; i < 80; i++) {
            final o =
                await page.eval(
                  'window.synchroFilm ? synchroFilm.remuxOffset : 0',
                ) as num? ??
                0;
            if (o > 0) return o;
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          fail('pas de remux');
        }();
        expect(off, closeTo(40000, 100));
        final b = await cues((l) => l.length == 1);
        expect(b.first['text'], 'Vers la fin');
        expect(b.first['start'], closeTo(41 - off / 1000, 0.01));
        expect(b.first['mode'], 'showing');
      } finally {
        await page.close();
        await host.close();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
