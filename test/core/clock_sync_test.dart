import 'package:app_synchro_film/core/clock_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// Simule un échange : l'hôte est en avance de [offset] ms sur l'invité,
/// avec des délais aller/retour [up]/[down] et un traitement [proc].
ClockSample exchange(
  ClockSync sync, {
  required int t0,
  required int offset,
  int up = 5,
  int down = 5,
  int proc = 1,
}) {
  final t1 = t0 + up + offset;
  final t2 = t1 + proc;
  final t3 = t2 - offset + down;
  return sync.addExchange(t0: t0, t1: t1, t2: t2, t3: t3);
}

void main() {
  group('ClockSync', () {
    test('offset et rtt exacts avec un réseau symétrique', () {
      final sync = ClockSync();
      final s = exchange(sync, t0: 1000, offset: 5000, up: 7, down: 7, proc: 2);
      expect(s.offsetMs, 5000);
      expect(s.rttMs, 14);
      expect(sync.offsetMs, 5000);
      expect(sync.rttMs, 14);
    });

    test('offset négatif', () {
      final sync = ClockSync();
      exchange(sync, t0: 50000, offset: -12345);
      expect(sync.offsetMs, -12345);
    });

    test('la médiane de 8 élimine les pics de latence asymétriques', () {
      final sync = ClockSync();
      // 6 échanges propres, 2 pics (aller très lent → offset faussé).
      for (var i = 0; i < 6; i++) {
        exchange(sync, t0: i * 100, offset: 300);
      }
      exchange(sync, t0: 700, offset: 300, up: 400, down: 5);
      exchange(sync, t0: 800, offset: 300, up: 5, down: 350);
      expect(sync.isConverged, isTrue);
      expect(sync.samples, hasLength(8));
      expect((sync.offsetMs - 300).abs(), lessThanOrEqualTo(1));
    });

    test('fenêtre glissante de 8 échantillons', () {
      final sync = ClockSync();
      for (var i = 0; i < 8; i++) {
        exchange(sync, t0: i * 10, offset: 100);
      }
      for (var i = 0; i < 8; i++) {
        exchange(sync, t0: 1000 + i * 10, offset: 200);
      }
      expect(sync.samples, hasLength(8));
      expect(sync.offsetMs, 200);
    });

    test('médiane paire = moyenne des deux valeurs centrales', () {
      final sync = ClockSync(windowSize: 4)
        ..addSample(const ClockSample(10, 1))
        ..addSample(const ClockSample(20, 1))
        ..addSample(const ClockSample(30, 1))
        ..addSample(const ClockSample(1000, 1));
      expect(sync.offsetMs, 25);
    });

    test('conversions local <-> hôte et rtt négatif borné', () {
      final sync = ClockSync();
      expect(sync.offsetMs, 0);
      expect(sync.rttMs, isNull);
      final s = sync.addExchange(t0: 100, t1: 200, t2: 300, t3: 150);
      expect(s.rttMs, 0);
      sync
        ..reset()
        ..addSample(const ClockSample(42, 3));
      expect(sync.toHost(1000), 1042);
      expect(sync.toLocal(1042), 1000);
    });
  });
}
