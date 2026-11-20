import 'dart:typed_data';

import 'package:opus_codec/opus_codec.dart' as opus_loader;
import 'package:opus_codec_dart/opus_codec_dart.dart' as opus;

import '../../core/audio_packet.dart';

bool _initialized = false;

/// Charge libopus une fois. [library] permet d'injecter une `DynamicLibrary`
/// (tests : `DynamicLibrary.open('libopus.so.0')`).
Future<void> ensureOpus({Object? library}) async {
  if (_initialized) return;
  opus.initOpus(library ?? await opus_loader.load());
  _initialized = true;
}

/// Encodeur Opus de trames de 20 ms (48 kHz stéréo, s16).
class OpusFrameEncoder {
  OpusFrameEncoder()
    : _enc = opus.SimpleOpusEncoder(
        sampleRate: kAudioSampleRate,
        channels: kAudioChannels,
        application: opus.Application.audio,
      );

  final opus.SimpleOpusEncoder _enc;

  /// [pcm] : 960 × 2 échantillons entrelacés.
  Uint8List encode(Int16List pcm) => _enc.encode(input: pcm);

  void dispose() => _enc.destroy();
}

/// Décodeur Opus ; `decode(null)` = masquage de perte (PLC).
class OpusFrameDecoder {
  OpusFrameDecoder()
    : _dec = opus.SimpleOpusDecoder(
        sampleRate: kAudioSampleRate,
        channels: kAudioChannels,
      );

  final opus.SimpleOpusDecoder _dec;

  // Attention : opus_codec_dart transmet `loss` tel quel comme taille de
  // trame à opus_decode (en échantillons, pas en ms) : on passe donc 960.
  Int16List decode(Uint8List? packet) => _dec.decode(
    input: packet,
    loss: packet == null ? kAudioSamplesPerFrame : null,
  );

  void dispose() => _dec.destroy();
}
