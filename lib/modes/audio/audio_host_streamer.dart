import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../core/audio_pacer.dart';
import '../../core/audio_packet.dart';
import '../../core/media_source.dart';
import '../../core/playback_state.dart';
import '../../core/remux.dart';
import '../../net/audio_sink.dart';
import '../../platform/ffmpeg_runner.dart';

/// Encode une trame PCM (960 × 2 échantillons s16) : Opus (mode 3) ou PCM
/// brut (mode 5, voir [pcmFrame]).
typedef FrameEncoder = Uint8List Function(Int16List pcm);

/// « Encodeur » du mode 5 : PCM s16le tel quel.
Uint8List pcmFrame(Int16List pcm) =>
    pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);

/// Hôte des modes 3 et 5 : décode la piste audio du film avec FFmpeg (PCM 48 kHz
/// stéréo, à partir de la position de la timeline), l'encode en Opus par
/// trames de 20 ms (ou les laisse en PCM) et les envoie à l'invité (UDP ou
/// WebSocket), avec ~1,2 s d'avance.
///
/// FFmpeg est rythmé par le contrôle de flux TCP (abonnement mis en pause
/// quand assez de trames attendent) : pas de décodage inutile.
class AudioHostStreamer {
  AudioHostStreamer({
    required this.ffmpeg,
    required this.media,
    required this.sender,
    required this.encode,
    this.flags = 0,
    required this.hostNowMs,
    required this.state,
    this.durationMs,
    AudioPacer? pacer,
    this.tick = const Duration(milliseconds: 10),
  }) : pacer = pacer ?? AudioPacer();

  final FfmpegRunner ffmpeg;
  final MediaRef media;
  final AudioSink sender;
  final FrameEncoder encode;

  /// Drapeaux des paquets (ex. [kAudioFlagPcm]).
  final int flags;
  final int Function() hostNowMs;
  final PlaybackState Function() state;
  final int? Function()? durationMs;
  final AudioPacer pacer;
  final Duration tick;

  Timer? _timer;
  FfmpegJob? _job;
  StreamSubscription<Uint8List>? _sub;
  final Queue<Int16List> _frames = Queue();
  final BytesBuilder _pending = BytesBuilder(copy: true);
  int? _nextPos;
  int _epoch = 0;
  int _seq = 0;
  bool _eof = false;
  bool _starting = false;
  int _eofSeq = -1;

  /// Trames décodées gardées en attente avant de bloquer FFmpeg.
  static const int maxQueuedFrames = 15;

  int get epoch => _epoch;
  int get packetsSent => _seq;

  void start() => _timer ??= Timer.periodic(tick, (_) => _pump());

  /// Repart de la position courante (nouvel auditeur : pas d'attente de
  /// l'avance déjà envoyée aux autres).
  void resync() {
    if (_starting) return;
    _nextPos = null;
  }

  Future<void> _pump() async {
    if (_starting) return;
    if (!sender.hasTarget) {
      if (_job != null) await _stopDecoding();
      _nextPos = null;
      return;
    }
    final st = state();
    final expected = st.positionAt(hostNowMs(), durationMs: durationMs?.call());
    while (true) {
      if (_eof && _frames.isEmpty) {
        // Fin du film : on attend un changement d'état (seek, play).
        if (st.seq == _eofSeq) return;
      }
      final action = pacer.decide(
        nextFrameMs: _nextPos,
        expectedMs: expected,
        playing: st.playing,
      );
      switch (action) {
        case PacerAction.restart:
          if (!st.playing && _job == null && _nextPos != null) return;
          await _restart(pacer.restartPositionMs, st.seq);
          return;
        case PacerAction.wait:
          return;
        case PacerAction.send:
          if (_frames.isEmpty) {
            if (_eof) _eofSeq = st.seq;
            _sub?.resume();
            return;
          }
          final pcm = _frames.removeFirst();
          sender.send(
            AudioPacket(
              epoch: _epoch,
              flags: flags,
              seq: _seq++,
              positionMs: _nextPos!,
              payload: encode(pcm),
            ),
          );
          _nextPos = _nextPos! + kAudioFrameMs;
          if (_frames.length < maxQueuedFrames ~/ 2) _sub?.resume();
      }
    }
  }

  Future<void> _restart(int positionMs, int seq) async {
    _starting = true;
    try {
      await _stopDecoding();
      _epoch = (_epoch + 1) & 0xffff;
      _nextPos = positionMs;
      _eof = false;
      final input = await ffmpeg.inputFor(media.uri);
      final job = await ffmpeg.start(pcmArgs(input, positionMs));
      _job = job;
      _sub = job.output.listen(
        _onBytes,
        onDone: () {
          _eof = true;
          _eofSeq = -1;
        },
        onError: (_) => _eof = true,
        cancelOnError: true,
      );
    } catch (_) {
      _eof = true;
      _eofSeq = seq;
    } finally {
      _starting = false;
    }
  }

  void _onBytes(Uint8List chunk) {
    _pending.add(chunk);
    if (_pending.length < kAudioFrameBytes) return;
    final all = _pending.takeBytes();
    var off = 0;
    while (all.length - off >= kAudioFrameBytes) {
      final frame = Uint8List.fromList(
        all.sublist(off, off + kAudioFrameBytes),
      );
      _frames.add(frame.buffer.asInt16List());
      off += kAudioFrameBytes;
    }
    if (off < all.length) _pending.add(all.sublist(off));
    if (_frames.length >= maxQueuedFrames) _sub?.pause();
  }

  Future<void> _stopDecoding() async {
    await _sub?.cancel();
    _sub = null;
    await _job?.cancel();
    _job = null;
    _frames.clear();
    _pending.clear();
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _stopDecoding();
  }
}
