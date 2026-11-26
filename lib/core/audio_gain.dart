import 'dart:math' as math;
import 'dart:typed_data';

/// Gain réglable côté invité : 50 % à 300 %.
const double kMinGain = 0.5;
const double kMaxGain = 3.0;

double _tanh(double x) {
  if (x > 10) return 1;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

/// Applique un gain avec écrêtage doux (jamais au-delà de ±1.0).
/// Au-dessous de 0,8 le signal reste linéaire (aucune coloration).
Float32List applyGain(Float32List samples, double gain) {
  if (gain == 1.0) return samples;
  final out = Float32List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    final y = samples[i] * gain;
    final a = y.abs();
    out[i] = a <= 0.8
        ? y
        : (y >= 0 ? 1.0 : -1.0) * (0.8 + 0.2 * _tanh((a - 0.8) / 0.2));
  }
  return out;
}
