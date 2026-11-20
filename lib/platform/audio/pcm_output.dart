import 'dart:typed_data';

import 'package:mp_audio_stream/mp_audio_stream.dart';

import '../../core/audio_packet.dart';

/// Sortie audio PCM temps réel (invité du mode 3).
abstract interface class PcmOutput {
  void start();

  /// Pousse des échantillons float entrelacés (stéréo, 48 kHz).
  void push(Float32List samples);

  /// Nombre cumulé de « famines » (file de sortie vide).
  int get underruns;

  void stop();
}

/// Implémentation miniaudio (mp_audio_stream) : AAudio/OpenSL sous Android,
/// WASAPI sous Windows. File courte pour une latence minimale.
class MiniaudioPcmOutput implements PcmOutput {
  final AudioStream _stream = getAudioStream();
  int _underruns = 0;

  @override
  void start() {
    _stream.init(
      bufferMilliSec: 1000,
      waitingBufferMilliSec: 40,
      channels: kAudioChannels,
      sampleRate: kAudioSampleRate,
      fadeOnExhaust: true,
    );
    _stream.resume();
  }

  @override
  void push(Float32List samples) => _stream.push(samples);

  @override
  int get underruns {
    final s = _stream.stat();
    if (s.exhaust > 0) {
      _underruns += s.exhaust;
      _stream.resetStat();
    }
    return _underruns;
  }

  @override
  void stop() => _stream.uninit();
}

/// Conversion s16 → float [-1, 1].
Float32List pcm16ToFloat(Int16List pcm) {
  final out = Float32List(pcm.length);
  for (var i = 0; i < pcm.length; i++) {
    out[i] = pcm[i] / 32768.0;
  }
  return out;
}
