import 'package:app_synchro_film/player/soft_correction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SoftCorrector c;
  setUp(() => c = SoftCorrector());

  Correction run(int drift, {bool playing = true, int now = 0}) => c.update(
        driftMs: drift,
        targetPositionMs: 10000,
        playing: playing,
        nowMs: now,
      );

  group('SoftCorrector', () {
    test('< 40 ms : rien', () {
      for (final d in [0, 10, -39, 39]) {
        final r = run(d);
        expect(r.kind, CorrectionKind.none, reason: 'drift $d');
        expect(r.rate, 1.0);
      }
    });

    test('40 ms – 1 s en avance : ralentit de 2 %', () {
      final r = run(200);
      expect(r.kind, CorrectionKind.rate);
      expect(r.rate, closeTo(0.98, 1e-9));
    });

    test('40 ms – 1 s en retard : accélère de 2 %', () {
      final r = run(-40);
      expect(r.kind, CorrectionKind.rate);
      expect(r.rate, closeTo(1.02, 1e-9));
      expect(run(-1000).rate, closeTo(1.02, 1e-9));
    });

    test('> 1 s : seek direct vers la position attendue', () {
      final r = run(1500);
      expect(r.kind, CorrectionKind.seek);
      expect(r.seekToMs, 10000);
      expect(r.rate, 1.0);
      expect(run(-1001, now: 5000).kind, CorrectionKind.seek);
    });

    test('hystérésis : la correction continue sous 40 ms jusqu\'à 15 ms', () {
      expect(run(100).kind, CorrectionKind.rate);
      expect(run(30).kind, CorrectionKind.rate);
      expect(c.isCorrecting, isTrue);
      final r = run(10);
      expect(r.kind, CorrectionKind.none);
      expect(r.rate, 1.0);
      expect(c.isCorrecting, isFalse);
      expect(run(30).kind, CorrectionKind.none);
    });

    test('changement de signe pendant la correction', () {
      expect(run(100).rate, closeTo(0.98, 1e-9));
      expect(run(-60).rate, closeTo(1.02, 1e-9));
    });

    test('pas de correction pendant le délai après un seek', () {
      expect(run(5000, now: 0).kind, CorrectionKind.seek);
      expect(run(5000, now: 1000).kind, CorrectionKind.none);
      expect(run(5000, now: 1600).kind, CorrectionKind.seek);
    });

    test('en pause : seek exact dès 40 ms, jamais de vitesse', () {
      expect(run(20, playing: false).kind, CorrectionKind.none);
      final r = run(300, playing: false);
      expect(r.kind, CorrectionKind.seek);
      expect(r.rate, 1.0);
    });

    test('la vitesse est relative à la vitesse nominale', () {
      final r = c.update(
        driftMs: 100,
        targetPositionMs: 0,
        playing: true,
        nowMs: 0,
        baseRate: 1.5,
      );
      expect(r.rate, closeTo(1.47, 1e-9));
    });
  });
}
