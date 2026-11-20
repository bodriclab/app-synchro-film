import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/media_source.dart';
import '../core/remux.dart';
import '../platform/ffmpeg_runner.dart';

/// Mode 4 : remux FFmpeg à la volée en MP4 fragmenté, sans réencodage vidéo.
///
/// - `GET /remux/{id}/info?token=…&start=ms` → JSON [RemuxProbe]
///   (`offsetMs` = position du film au temps 0 du flux) ;
/// - `GET /remux/{id}.mp4?token=…&start=ms` → flux MP4 fragmenté (non
///   « seekable » : la page recharge avec un autre `start` pour un saut).
///
/// Un seul remux tourne à la fois (économie CPU/batterie).
class RemuxHttpHandler {
  RemuxHttpHandler({
    required this.token,
    required this.mediaId,
    required this.media,
    required this.ffmpeg,
  });

  final String token;
  final String mediaId;
  final MediaRef media;
  final FfmpegRunner ffmpeg;

  final Map<int, RemuxProbe> _probes = {};
  FfmpegJob? _current;

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
      final p = await probe(start);
      if (path == infoPath) {
        res.headers.contentType = ContentType.json;
        res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        res.write(jsonEncode(p.toJson()));
        await res.close();
        return;
      }
      res.headers
        ..contentType = ContentType('video', 'mp4')
        ..set(HttpHeaders.acceptRangesHeader, 'none')
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      await _current?.cancel();
      final input = await ffmpeg.inputFor(media.uri);
      final job = await ffmpeg.start(
        remuxArgs(input, start, transcodeAudio: p.transcodeAudio),
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

  Future<void> dispose() async {
    await _current?.cancel();
    _current = null;
  }

  static Future<void> _status(HttpResponse res, int code) async {
    res.statusCode = code;
    res.contentLength = 0;
    await res.close();
  }
}
