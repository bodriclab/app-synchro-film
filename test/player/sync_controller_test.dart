import 'package:app_synchro_film/core/monotonic_clock.dart';
import 'package:app_synchro_film/core/playback_state.dart';
import 'package:app_synchro_film/player/sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_engine.dart';

class FakeClock implements SharedClock {
  int t = 100000;
  @override
  int hostNowMs() => t;
}

void main() {
  late FakeClock clock;
  late FakeEngine engine;
  late SyncController ctrl;

  setUp(() {
    clock = FakeClock();
    engine = FakeEngine(now: () => clock.t);
    ctrl = SyncController(
      engine: engine,
      clock: clock,
      localNowMs: () => clock.t,
    );
  });

  tearDown(() => ctrl.dispose());

  test(
    'play : se cale sur la position attendue puis lance la lecture',
    () async {
      await ctrl.applyState(
        PlaybackState(playing: true, positionMs: 5000, atHostMs: clock.t - 200),
      );
      expect(engine.isPlaying, isTrue);
      expect(engine.positionMs, 5200);
    },
  );

  test('pause : s\'arrête à la position exacte', () async {
    await ctrl.applyState(
      PlaybackState(playing: true, positionMs: 0, atHostMs: clock.t),
    );
    clock.t += 3000;
    await ctrl.applyState(
      PlaybackState(
        playing: false,
        positionMs: 3000,
        atHostMs: clock.t,
        seq: 1,
      ),
    );
    expect(engine.isPlaying, isFalse);
    expect(engine.positionMs, 3000);
  });

  test('dérive moyenne résorbée par la vitesse ±2 %', () async {
    await ctrl.applyState(
      PlaybackState(playing: true, positionMs: 0, atHostMs: clock.t),
    );
    engine.jumpTo(engine.positionMs + 300); // 300 ms d'avance
    await ctrl.step();
    expect(engine.rate, closeTo(0.98, 1e-9));
    expect(ctrl.lastStats.driftMs, 300);

    // Simulation par pas de 250 ms : l'écart doit converger vers 0.
    for (var i = 0; i < 100; i++) {
      clock.t += 250;
      await ctrl.step();
    }
    expect(ctrl.lastStats.driftMs!.abs(), lessThanOrEqualTo(40));
    expect(engine.rate, 1.0);
    expect(engine.calls.where((c) => c.startsWith('seek')), isEmpty);
  });

  test('grosse dérive : seek direct', () async {
    await ctrl.applyState(
      PlaybackState(playing: true, positionMs: 0, atHostMs: clock.t),
    );
    engine.jumpTo(engine.positionMs - 5000);
    await ctrl.step();
    expect(engine.calls.last, startsWith('seek:'));
    expect((engine.positionMs - ctrl.expectedPositionMs()!).abs(), lessThan(5));
  });

  test('état obsolète (seq inférieur) ignoré', () async {
    await ctrl.applyState(
      PlaybackState(playing: true, positionMs: 0, atHostMs: clock.t, seq: 5),
    );
    await ctrl.applyState(
      PlaybackState(playing: false, positionMs: 0, atHostMs: clock.t, seq: 4),
    );
    expect(engine.isPlaying, isTrue);
  });

  test('rien n\'est appliqué tant que l\'horloge n\'est pas prête', () async {
    var ready = false;
    final c2 = SyncController(
      engine: engine,
      clock: clock,
      localNowMs: () => clock.t,
      isReady: () => ready,
    );
    await c2.applyState(
      PlaybackState(playing: true, positionMs: 0, atHostMs: clock.t),
    );
    expect(engine.isPlaying, isFalse);
    ready = true;
    await c2.step();
    expect(engine.isPlaying, isTrue);
    await c2.dispose();
  });
}
