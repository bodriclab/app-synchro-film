import 'dart:async';
import 'dart:typed_data';

import '../../core/audio_packet.dart';
import '../../core/audio_scheduler.dart';
import '../../core/jitter_buffer.dart';
import '../../platform/audio/pcm_output.dart';

/// Décode un paquet Opus (null = trame perdue → masquage).
typedef FrameDecoder = Int16List Function(Uint8List? packet);

/// Invité du mode 3 : reçoit les trames Opus, les range dans le buffer de
/// gigue et les joue au bon moment (timeline de l'hôte + latence de sortie
/// compensée).
class AudioGuestPlayer {
  AudioGuestPlayer({
    required this.packets,
    required this.decode,
    required this.output,
    required this.localNowMs,
    required this.expectedPositionAt,
    required this.outputLatencyMs,
    AudioPlayoutScheduler? scheduler,
    JitterBuffer? buffer,
    this.tick = const Duration(milliseconds: 10),
  }) : scheduler = scheduler ?? AudioPlayoutScheduler(),
       buffer = buffer ?? JitterBuffer();

  final Stream<AudioPacket> packets;
  final FrameDecoder decode;
  final PcmOutput output;
  final int Function() localNowMs;

  /// Position attendue (ms) à une heure locale, null en pause.
  final int? Function(int localMs) expectedPositionAt;

  /// Latence totale à compenser (auto + manuel).
  final int Function() outputLatencyMs;

  final AudioPlayoutScheduler scheduler;
  final JitterBuffer buffer;
  final Duration tick;

  StreamSubscription<AudioPacket>? _sub;
  Timer? _timer;
  int _lastUnderruns = 0;
  bool _lastWasAudio = false;
  int framesPlayed = 0;

  /// Position (ms) de la dernière trame réellement jouée.
  int? lastPlayedPositionMs;
  int framesConcealed = 0;

  static final Float32List _silence = Float32List(
    kAudioSamplesPerFrame * kAudioChannels,
  );

  void start() {
    output.start();
    _sub = packets.listen(
      (p) => buffer.add(p, playedUpTo: scheduler.lastPlannedIndex),
    );
    _timer = Timer.periodic(tick, (_) => step());
  }

  /// Une itération (publique pour les tests).
  void step() {
    final u = output.underruns;
    if (u != _lastUnderruns) {
      _lastUnderruns = u;
      scheduler.reset();
    }
    final plan = scheduler.plan(
      nowMs: localNowMs(),
      expectedPositionAt: expectedPositionAt,
      outputLatencyMs: outputLatencyMs(),
    );
    for (final index in plan) {
      final p = buffer.take(index);
      if (p != null) {
        output.push(pcm16ToFloat(decode(p.payload)));
        lastPlayedPositionMs = p.positionMs;
        _lastWasAudio = true;
        framesPlayed++;
      } else if (_lastWasAudio) {
        output.push(pcm16ToFloat(decode(null))); // masquage Opus
        _lastWasAudio = false;
        framesConcealed++;
      } else {
        output.push(_silence);
      }
    }
    if (plan.isNotEmpty) buffer.dropBefore(plan.last + 1);
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _sub?.cancel();
    output.stop();
  }
}
