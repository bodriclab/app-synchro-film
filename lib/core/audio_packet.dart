import 'dart:typed_data';

/// Paramètres audio du mode 3 : Opus 48 kHz stéréo, trames de 20 ms.
const int kAudioSampleRate = 48000;
const int kAudioChannels = 2;
const int kAudioFrameMs = 20;
const int kAudioSamplesPerFrame = kAudioSampleRate * kAudioFrameMs ~/ 1000;

/// Octets PCM s16le d'une trame (960 échantillons × 2 canaux × 2 octets).
const int kAudioFrameBytes = kAudioSamplesPerFrame * kAudioChannels * 2;

/// Paquet UDP du mode 3.
///
/// En-tête (16 octets, big-endian) :
/// `'S' 'F'` | version (1) | flags (1) | epoch (u16) | réservé (u16) |
/// seq (u32) | position (u32, ms dans le film) | charge utile Opus.
///
/// L'`epoch` change à chaque redémarrage du flux (seek) : l'invité vide son
/// buffer de gigue quand il voit un epoch plus récent.
class AudioPacket {
  const AudioPacket({
    required this.epoch,
    required this.seq,
    required this.positionMs,
    required this.payload,
    this.flags = 0,
  });

  static const int headerSize = 16;
  static const int version = 1;

  final int epoch;
  final int seq;
  final int positionMs;
  final int flags;
  final Uint8List payload;

  /// Index de trame (positions alignées sur 20 ms).
  int get frameIndex => positionMs ~/ kAudioFrameMs;

  Uint8List encode() {
    final out = Uint8List(headerSize + payload.length);
    final b = ByteData.sublistView(out);
    b
      ..setUint8(0, 0x53) // 'S'
      ..setUint8(1, 0x46) // 'F'
      ..setUint8(2, version)
      ..setUint8(3, flags)
      ..setUint16(4, epoch & 0xffff)
      ..setUint16(6, 0)
      ..setUint32(8, seq & 0xffffffff)
      ..setUint32(12, positionMs);
    out.setAll(headerSize, payload);
    return out;
  }

  /// Décode un datagramme ; null s'il n'est pas valide.
  static AudioPacket? decode(Uint8List data) {
    if (data.length < headerSize) return null;
    final b = ByteData.sublistView(data);
    if (b.getUint8(0) != 0x53 || b.getUint8(1) != 0x46) return null;
    if (b.getUint8(2) != version) return null;
    return AudioPacket(
      flags: b.getUint8(3),
      epoch: b.getUint16(4),
      seq: b.getUint32(8),
      positionMs: b.getUint32(12),
      payload: Uint8List.sublistView(data, headerSize),
    );
  }

  /// Compare deux epochs sur 16 bits (gère le rebouclage).
  static bool isNewerEpoch(int a, int b) {
    final d = (a - b) & 0xffff;
    return d != 0 && d < 0x8000;
  }
}
