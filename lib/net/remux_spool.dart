import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../platform/ffmpeg_runner.dart';

/// Sortie d'un remux FFmpeg écrite au fil de l'eau dans un fichier temporaire
/// pour répondre aux requêtes `Range` de Safari (macOS / iOS).
///
/// Safari refuse une vidéo servie sans `Range` : il sonde `bytes=0-1`, exige
/// une réponse 206 avec une taille totale, puis lit par plages. La taille du
/// MP4 fragmenté n'est connue qu'à la fin : on annonce une estimation
/// généreuse ([totalSize]) et, une fois FFmpeg terminé, la fin est comblée
/// par une boîte MP4 `free` (bourrage standard ignoré par les lecteurs).
///
/// FFmpeg est mis en pause quand il a pris [lead] octets d'avance sur la
/// lecture la plus lointaine (disque et batterie de l'hôte).
class RemuxSpool {
  RemuxSpool._(this.startMs, this.file, this.totalSize, this.lead, this._job);

  /// Démarre l'écriture de [job] dans [file] (écrasé).
  static Future<RemuxSpool> begin({
    required int startMs,
    required FfmpegJob job,
    required File file,
    required int totalSize,
    int lead = 48 << 20,
  }) async {
    final s = RemuxSpool._(startMs, file, totalSize, lead, job);
    s._out = await file.open(mode: FileMode.write);
    s._sub = job.output.listen(
      s._onData,
      onError: s._onError,
      onDone: s._onDone,
      cancelOnError: true,
    );
    return s;
  }

  final int startMs;
  final File file;

  /// Taille annoncée au navigateur (fixe pour toute la vie du spool).
  final int totalSize;
  final int lead;
  final FfmpegJob _job;

  late final RandomAccessFile _out;
  late final StreamSubscription<Uint8List> _sub;
  final List<Uint8List> _queue = [];
  bool _writing = false;
  bool _closed = false;

  int _written = 0;
  int _demand = 0;
  bool _done = false;
  Object? _error;
  Completer<void> _progress = Completer<void>();

  /// Octets réellement produits par FFmpeg et écrits sur disque.
  int get written => _written;

  /// FFmpeg a terminé (ou a été arrêté).
  bool get isDone => _done;
  Object? get error => _error;
  bool get isClosed => _closed;

  void _onData(Uint8List chunk) {
    if (_closed) return;
    final room = totalSize - _bourrageMin - _written - _pending;
    if (room <= 0) {
      // Estimation dépassée : on coupe proprement (cas improbable).
      _sub.cancel();
      _onDone();
      return;
    }
    _queue.add(chunk.length > room ? chunk.sublist(0, room) : chunk);
    _pending += _queue.last.length;
    _drain();
  }

  int _pending = 0;

  Future<void> _drain() async {
    if (_writing) return;
    _writing = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        final c = _queue.removeAt(0);
        await _out.writeFrom(c);
        _pending -= c.length;
        _written += c.length;
        _notify();
      }
      if (_finishing && _queue.isEmpty && !_closed) {
        await _out.flush();
        _done = true;
        _notify();
      }
    } catch (e) {
      _error ??= e;
      _done = true;
      _notify();
    } finally {
      _writing = false;
    }
    _throttle();
  }

  bool _finishing = false;

  void _onError(Object e) {
    _error ??= e;
    _onDone();
  }

  void _onDone() {
    _finishing = true;
    _drain();
  }

  void _notify() {
    final c = _progress;
    _progress = Completer<void>();
    c.complete();
  }

  void _throttle() {
    if (_done || _closed) return;
    final ahead = _written + _pending - _demand;
    if (ahead > lead) {
      if (!_sub.isPaused) _sub.pause();
    } else if (_sub.isPaused) {
      _sub.resume();
    }
  }

  /// Taille minimale d'une boîte `free` (en-tête 32 bits).
  static const int _bourrageMin = 8;

  /// Signale qu'un lecteur a besoin des octets jusqu'à [offset].
  void demand(int offset) {
    if (offset > _demand) _demand = offset;
    _throttle();
  }

  /// Attend que l'octet [offset] soit disponible (ou la fin du remux).
  Future<void> waitFor(int offset) async {
    while (!_done && !_closed && _written <= offset) {
      demand(offset);
      await _progress.future;
    }
  }

  /// Lit au plus [max] octets à partir de [offset] (après [waitFor]).
  /// Au-delà des données réelles, renvoie la boîte `free` de bourrage.
  Future<Uint8List> readAt(RandomAccessFile reader, int offset, int max) async {
    if (offset < _written) {
      final n = math.min(max, _written - offset);
      await reader.setPosition(offset);
      return reader.read(n);
    }
    final n = math.min(max, totalSize - offset);
    if (n <= 0) return Uint8List(0);
    return paddingBytes(_written, totalSize, offset, n);
  }

  /// Octets [offset, offset+n) de la boîte `free` qui occupe [start, total).
  static Uint8List paddingBytes(int start, int total, int offset, int n) {
    final out = Uint8List(n);
    final header = Uint8List(16);
    final size = total - start;
    final bd = ByteData.sublistView(header);
    if (size < 8) return out;
    if (size <= 0xFFFFFFFF) {
      bd.setUint32(0, size);
      header.setAll(4, 'free'.codeUnits);
    } else {
      bd.setUint32(0, 1); // taille 64 bits
      header.setAll(4, 'free'.codeUnits);
      bd.setUint64(8, size);
    }
    for (var i = 0; i < n; i++) {
      final rel = offset + i - start;
      if (rel >= 0 && rel < 16) out[i] = header[rel];
    }
    return out;
  }

  /// Arrête FFmpeg et supprime le fichier temporaire.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _notify();
    try {
      await _sub.cancel();
    } catch (_) {}
    await _job.cancel();
    try {
      while (_writing) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await _out.close();
    } catch (_) {}
    try {
      await file.delete();
    } catch (_) {}
  }
}
