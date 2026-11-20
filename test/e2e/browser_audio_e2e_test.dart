// Test de bout en bout du mode 5 (audio seul vers navigateur) dans Chrome
// headless : mesure l'écart entre le son programmé par Web Audio et la
// timeline de l'hôte. Ignoré si Chrome ou ffmpeg manquent.
import 'dart:io';
import 'dart:math' as math;

import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/core/monotonic_clock.dart';
import 'package:app_synchro_film/modes/browser_audio_mode.dart';
import 'package:app_synchro_film/net/session/host_session.dart';
import 'package:app_synchro_film/platform/ffmpeg_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../player/fake_engine.dart';
import '../support/chrome.dart';
import '../support/fixtures.dart';

void main() {
  final chrome = findChrome();
  final skip = chrome == null || !hasFfmpeg ? 'Chrome ou ffmpeg absent' : null;

  test(
    'mode 5 : son programmé à l\'instant exact de la timeline hôte',
    () async {
      final dir = await Directory.systemTemp.createTemp('e2e5');
      final browser = await HeadlessChrome.start(chrome!);
      final film = await makeTestFilm(
        dir,
        name: 'film.mkv',
        seconds: 60,
        audioCodec: 'ac3',
      );
      final clock = MonotonicClock();
      final host = HostSession(
        engine: FakeEngine(now: clock.nowMs, durationMs: 60000),
        mode: const BrowserAudioMode(),
        media: MediaRef.file(film),
        preferredPort: 0,
        clock: clock,
        ffmpeg: () => ProcessFfmpegRunner(),
        loadAsset: (n) => File('web_client/$n').readAsString(),
      );
      await host.start();
      final page = await browser.open(
        host.endpointFor('127.0.0.1').toUri().toString(),
      );
      try {
        // Page prête + bouton « Activer le son ».
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          const ready =
              '!!window.synchroAudio && synchroAudio.clock.samples.length >= 8';
          if (await page.eval(ready) == true) break;
        }
        await page.eval('synchroAudio.unlock()');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(await page.eval('synchroAudio.ctx.state'), 'running');

        /// Écarts (ms) entre la position réellement jouée et celle de l'hôte au
        /// moment où ce son sera entendu (latence de sortie et réglage inclus).
        Future<List<double>> measure(int n) async {
          final out = <double>[];
          for (var i = 0; i < n; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            final p = await page.eval('synchroAudio.probe()') as Map?;
            final playing = p?['playingMs'] as num?;
            if (playing == null) continue;
            final skew =
                DateTime.now().microsecondsSinceEpoch / 1000 -
                (p!['epochMs'] as num);
            final hostAt = clock.nowMs() - skew + (p['latencyMs'] as num);
            final exp = host.controller.target!.positionAt(
              hostAt.round(),
              durationMs: 60000,
            );
            out.add((playing - (p['manualMs'] as num) - exp).toDouble());
          }
          return out;
        }

        String summary(List<double> e) {
          final abs = e.map((x) => x.abs()).toList()..sort();
          final mean = e.reduce((a, b) => a + b) / e.length;
          return 'n=${e.length} moyenne=${mean.toStringAsFixed(1)} ms, '
              'max |écart|=${abs.last.toStringAsFixed(1)} ms, '
              'p50=${abs[abs.length ~/ 2].toStringAsFixed(1)} ms';
        }

        void check(String label, List<double> e) {
          expect(e.length, greaterThan(10), reason: '$label : pas de son joué');
          for (final x in e) {
            expect(x.abs(), lessThan(25), reason: '$label : ${summary(e)}');
          }
          // ignore: avoid_print
          print('$label : ${summary(e)}');
        }

        await host.play();
        await Future<void>.delayed(const Duration(seconds: 2));
        check('lecture', await measure(25));

        await host.seekTo(30000);
        await Future<void>.delayed(const Duration(seconds: 2));
        check('après saut à 30 s', await measure(20));

        // Réglage manuel : +200 ms (son joué plus tôt), mémorisé.
        await page.eval('synchroAudio.setOffset(200)');
        await Future<void>.delayed(const Duration(seconds: 1));
        check('décalage +200 ms', await measure(15));
        expect(
          await page.eval("localStorage.getItem('synchroFilm.audioOffsetMs')"),
          '200',
        );

        // La page pilote aussi : pause depuis le navigateur.
        await page.eval("synchroAudio.cmd('pause')");
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(host.isPlaying, isFalse);
        final p = await page.eval('synchroAudio.probe()') as Map;
        expect(p['playingMs'], isNull);
        final stats = await page.eval('synchroAudio.stats') as Map;
        // ignore: avoid_print
        print(
          'stats : $stats, rtt ${await page.eval('synchroAudio.clock.rtt')} ms',
        );
        expect(stats['scheduled'], greaterThan(200));
        expect(math.max(0, stats['concealed'] as num), lessThan(5));
      } finally {
        await page.close();
        await host.close();
        await browser.close();
        await dir.delete(recursive: true).catchError((_) => dir);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
