import 'dart:typed_data';

import 'dart:io';

import 'package:app_synchro_film/core/audio_gain.dart';
import 'package:app_synchro_film/modes/audio/audio_latency_control.dart';
import 'package:app_synchro_film/platform/audio/output_latency.dart';
import 'package:app_synchro_film/platform/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const eps = 1e-6;

  test('gain 1 : même instance, inchangée', () {
    final s = Float32List.fromList([0.0, 0.5, -0.3, 1.0, -1.0]);
    expect(identical(applyGain(s, 1.0), s), isTrue);
  });

  test('linéaire sous 0,8', () {
    final s = Float32List.fromList([-0.5, -0.1, 0.0, 0.3, 0.6]);
    final out = applyGain(s, 1.3);
    for (var i = 0; i < s.length; i++) {
      expect(out[i], closeTo(s[i] * 1.3, eps));
    }
  });

  test('jamais au-delà de 1,0, même très fort (pas de NaN)', () {
    final out = applyGain(Float32List.fromList([2.0, -3.0, 10.0, -10.0]), 3);
    for (final v in out) {
      expect(v.isNaN, isFalse);
      expect(v.abs(), lessThanOrEqualTo(1.0 + eps));
    }
  });

  test('symétrique et continu autour de 0,8', () {
    final p = applyGain(Float32List.fromList([0.9]), 1.5)[0];
    final n = applyGain(Float32List.fromList([-0.9]), 1.5)[0];
    expect(p, closeTo(-n, eps));
    final below = applyGain(Float32List.fromList([0.8]), 1.0001)[0];
    expect(below, closeTo(0.8, 1e-3));
  });

  test('mode 3 : gain de l\'invité borné et mémorisé', () async {
    final dir = await Directory.systemTemp.createTemp('gain');
    addTearDown(() => dir.delete(recursive: true));
    AudioLatencyControl make() => AudioLatencyControl(
      outputInfo: () async => AudioOutputInfo.fallback,
      store: LatencyOffsetStore(directory: () async => dir),
      settings: SettingsStore(directory: () async => dir),
    );
    final a = make();
    await a.start();
    expect(a.gain, 1.0);
    await a.setGain(5);
    expect(a.gain, kMaxGain);
    await a.setGain(1.8);
    a.dispose();
    final b = make();
    await b.start();
    expect(b.gain, closeTo(1.8, 1e-9));
    b.dispose();
  });
}
