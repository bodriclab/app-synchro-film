import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/http_range.dart';
import '../core/media_source.dart';
import '../core/remux.dart';
import '../platform/ffmpeg_runner.dart';
import 'remux_spool.dart';

/// Mode 4 : remux FFmpeg à la volée en MP4 fragmenté, sans réencodage vidéo.
///
/// - `GET /remux/{id}/info?token=…&start=ms` → JSON [RemuxProbe]
///   (`offsetMs` = position du film au temps 0 du flux) ;
/// - `GET /remux/{id}.mp4?token=…&start=ms` → flux MP4 fragmenté (non
///   « seekable » : la page recharge avec un autre `start` pour un saut).
/// - avec `&safari=1` : audio limité à AAC/MP3, et le flux est servi avec
///   des requêtes `Range` (taille estimée, voir [RemuxSpool]) car Safari
///   (macOS/iOS) ne lit pas une vidéo sans `Range`.
///
/// Un seul remux tourne à la fois (économie CPU/batterie).
class RemuxHttpHandler {
  RemuxHttpHandler({
    required this.token,
    required this.mediaId,
    required this.media,
    required this.ffmpeg,
    Future<Directory> Function()? tempDir,
  }) : _tempDir = tempDir ?? (() async => Directory.systemTemp);

  final String token;
  final String mediaId;
  final MediaRef media;
  final FfmpegRunner ffmpeg;
  final Future<Directory> Function() _tempDir;

  final Map<int, RemuxProbe> _probes = {};
  FfmpegJob? _current;
  Future<RemuxSpool>? _spool;

  String get streamPath => '/remux/$mediaId.mp4';
  String get infoPath => '/remux/$mediaId/info';

  Future<RemuxProbe> probe(int startMs) async {
    final cached = _probes[startMs];
    if (cached != null) return cached;
    final input = await ffmpeg.inputFor(media.uri);
    final out = await ffmpeg.run(probeArgs(input, startMs));
    final p = parseFramecrc(utf8.decode(out, allowMalformed: true));
    if (_probes.length > 32) _probes.clear();
    return _probes[startMs] = p;
  }

  Future<void> call(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    if (path != streamPath && path != infoPath) {
      return _status(res, HttpStatus.notFound);
    }
    if (req.uri.queryParameters['token'] != token) {
      return _status(res, HttpStatus.forbidden);
    }
    if (req.method != 'GET' && req.method != 'HEAD') {
      return _status(res, HttpStatus.methodNotAllowed);
    }
    final start =
        int.tryParse(req.uri.queryParameters['start'] ?? '0')
            ?.clamp(0, 1 << 31) ??
        0;
    try {
      final safari = req.uri.queryParameters['safari'] == '1';
      final p = (await probe(start)).forClient(safari: safari);
      if (path == infoPath) {
        res.headers.contentType = ContentType.json;
        res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        res.write(jsonEncode(p.toJson()));
        await res.close();
        return;
      }
      if (safari) return await _serveRanges(req, start, p);
      res.headers
        ..contentType = ContentType('video', 'mp4')
        ..set(HttpHeaders.acceptRangesHeader, 'none')
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      await _current?.cancel();
      await _closeSpool();
      final input = await ffmpeg.inputFor(media.uri);
      final job = await ffmpeg.start(
        remuxArgs(input, start, transcodeAudio: p.transcodeAudio, hevc: p.hevc),
      );
      _current = job;
      try {
        await res.addStream(job.output);
        await res.close();
      } finally {
        await job.cancel();
        if (identical(_current, job)) _current = null;
      }
    } on HttpException {
      // navigateur parti (saut, onglet fermé)
    } on SocketException {
      // idem
    } catch (e) {
      try {
        res.statusCode = HttpStatus.unsupportedMediaType;
        res.write('Remux impossible : $e');
        await res.close();
      } catch (_) {}
    }
  }

  /// Taille annoncée à Safari : marge de 10 % (en-têtes de fragments) et
  /// place pour l'AAC 192 kb/s quand l'audio est converti.
  int estimateSize(RemuxProbe p) {
    var size = media.size;
    if (size == null && !media.isContentUri) {
      try {
        size = File(media.uri).lengthSync();
      } catch (_) {}
    }
    size ??= 4 << 30;
    return (size * 1.1).ceil() + (p.transcodeAudio ? 200 << 20 : 16 << 20);
  }

  Future<RemuxSpool> _spoolFor(int start, RemuxProbe p) async {
    final pending = _spool;
    if (pending != null) {
      try {
        final s = await pending;
        if (s.startMs == start && s.error == null && !s.isClosed) return s;
      } catch (_) {}
    }
    if (!identical(_spool, pending)) return _spoolFor(start, p);
    final next = () async {
      if (pending != null) {
        try {
          await (await pending).close();
        } catch (_) {}
      }
      await _current?.cancel();
      _current = null;
      final input = await ffmpeg.inputFor(media.uri);
      final job = await ffmpeg.start(
        remuxArgs(input, start, transcodeAudio: p.transcodeAudio, hevc: p.hevc),
      );
      final dir = await _tempDir();
      return RemuxSpool.begin(
        startMs: start,
        job: job,
        file: File('${dir.path}/synchro-remux-$mediaId-$start.mp4'),
        totalSize: estimateSize(p),
      );
    }();
    _spool = next;
    return next;
  }

  Future<void> _serveRanges(HttpRequest req, int start, RemuxProbe p) async {
    final res = req.response;
    final spool = await _spoolFor(start, p);
    final total = spool.totalSize;
    res.headers
      ..contentType = ContentType('video', 'mp4')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    final r = parseRange(req.headers.value(HttpHeaders.rangeHeader), total);
    late final int from, to;
    switch (r) {
      case UnsatisfiableRange():
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        res.contentLength = 0;
        await res.close();
        return;
      case PartialContent(:final range):
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          range.contentRange(total),
        );
        (from, to) = (range.start, range.end);
      case FullContent():
        (from, to) = (0, total - 1);
    }
    res.contentLength = to - from + 1;
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }
    final reader = await spool.file.open();
    try {
      var pos = from;
      while (pos <= to) {
        final n = math.min(256 << 10, to - pos + 1);
        Uint8List chunk;
        if (!spool.isDone && pos > spool.written + 2 * spool.lead) {
          // Lecture très en avant (fin de fichier) : sans attendre FFmpeg.
          chunk = Uint8List(n);
        } else {
          await spool.waitFor(pos);
          if (spool.isClosed) throw const HttpException('remux remplacé');
          chunk = await spool.readAt(reader, pos, n);
          if (chunk.isEmpty) break;
        }
        res.add(chunk);
        await res.flush();
        pos += chunk.length;
        spool.demand(pos);
      }
      await res.close();
    } finally {
      await reader.close();
    }
  }

  Future<void> _closeSpool() async {
    final s = _spool;
    _spool = null;
    if (s == null) return;
    try {
      await (await s).close();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _current?.cancel();
    _current = null;
    await _closeSpool();
  }

  static Future<void> _status(HttpResponse res, int code) async {
    res.statusCode = code;
    res.contentLength = 0;
    await res.close();
  }
}
