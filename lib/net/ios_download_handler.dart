import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/media_source.dart';
import '../core/mp4_scan.dart';
import '../core/remux.dart';
import '../platform/ffmpeg_runner.dart';
import 'media_http_handler.dart';

/// État de la copie compatible iOS.
enum IosCopyState { idle, preparing, ready, error }

/// Mode 4 : copie MP4 lisible par Safari iOS, à télécharger puis ouvrir en
/// local (zéro latence).
///
/// - `GET|HEAD /download?token=…` : le fichier (`Content-Disposition:
///   attachment; filename="nom_ios.mp4"`, `video/mp4`, `Range`). Attend la
///   préparation si besoin.
/// - `GET /download/status?token=…` : `{state, native, progress, name, size}`.
/// - `POST /download/prepare?token=…` : lance la préparation (sans attendre).
///
/// Un MP4/MOV déjà lisible sur iOS (H.264 `avc1` ou HEVC `hvc1`, audio AAC)
/// est servi tel quel. Sinon FFmpeg le réemballe une seule fois par session
/// dans un fichier temporaire ([iosCopyArgs] : vidéo copiée, `hvc1` pour le
/// HEVC, audio AAC), supprimé par [dispose].
class IosDownloadHandler {
  IosDownloadHandler({
    required this.token,
    required this.mediaId,
    required this.media,
    required this.ffmpeg,
    required this.direct,
    required this.videoCodec,
    Future<Directory> Function()? tempDir,
  }) : _tempDir = tempDir ?? (() async => Directory.systemTemp);

  final String token;
  final String mediaId;
  final MediaRef media;
  final FfmpegRunner ffmpeg;

  /// Sert les octets (Range, en-têtes) : on ne duplique pas cette logique.
  final MediaHttpHandler direct;

  /// Codec vidéo du film (`h264`, `hevc`…), sondé par FFmpeg (partagé avec
  /// le remux temps réel).
  final Future<String?> Function() videoCodec;
  final Future<Directory> Function() _tempDir;

  static const String path = '/download';

  IosCopyState _state = IosCopyState.idle;
  bool _native = false;
  String? _error;
  Future<MediaRef>? _ready;
  FfmpegFileJob? _job;
  File? _out, _part;
  int? _sourceSize;
  bool _disposed = false;

  IosCopyState get state => _state;

  /// Nom proposé au navigateur : `<nom sans extension>_ios.mp4`.
  String get downloadName {
    final n = media.name;
    final dot = n.lastIndexOf('.');
    return '${dot > 0 ? n.substring(0, dot) : n}_ios.mp4';
  }

  Map<String, Object?> status() {
    double? progress;
    if (_state == IosCopyState.ready) progress = 1;
    if (_state == IosCopyState.preparing) {
      final part = _part, size = _sourceSize;
      if (part != null && size != null && size > 0) {
        try {
          progress = (part.lengthSync() / size).clamp(0.0, 0.99);
        } catch (_) {
          progress = 0;
        }
      }
    }
    return {
      'state': _state.name,
      'native': _native,
      'progress': ?progress,
      'name': downloadName,
      'error': ?_error,
    };
  }

  Future<void> call(HttpRequest req) async {
    final res = req.response;
    final p = req.uri.path;
    if (p != path && p != '$path/status' && p != '$path/prepare') {
      return _status(res, HttpStatus.notFound);
    }
    if (req.uri.queryParameters['token'] != token) {
      return _status(res, HttpStatus.forbidden);
    }
    if (p == '$path/status' || p == '$path/prepare') {
      if (p == '$path/prepare') unawaited(prepare().catchError((_) => media));
      res.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      res.write(jsonEncode(status()));
      await res.close();
      return;
    }
    final MediaRef file;
    try {
      file = await prepare();
    } catch (e) {
      res.statusCode = HttpStatus.internalServerError;
      res.headers.contentType = ContentType.text;
      res.write('Copie compatible iOS impossible : $e');
      await res.close();
      return;
    }
    await direct.serve(req, source: file, attachmentName: downloadName);
  }

  /// Prépare (une seule fois) la copie et renvoie ce qu'il faut servir.
  Future<MediaRef> prepare() {
    final r = _ready;
    if (r != null && _state != IosCopyState.error) return r;
    return _ready = _prepare();
  }

  Future<MediaRef> _prepare() async {
    _state = IosCopyState.preparing;
    _error = null;
    try {
      final src = await direct.opener(media.uri);
      Mp4Codecs? codecs;
      try {
        _sourceSize = src.length;
        codecs = await scanMp4Codecs(src);
      } finally {
        await src.close();
      }
      final asIs = MediaRef(
        uri: media.uri,
        name: downloadName,
        size: _sourceSize,
      );
      if (codecs != null && codecs.iosNative) {
        _native = true;
        _state = IosCopyState.ready;
        return asIs;
      }
      final hevc =
          (codecs?.video.any((c) => c == 'hev1' || c == 'hvc1') ?? false) ||
          (await videoCodec()) == 'hevc';
      final dir = await _tempDir();
      final out = _out = File('${dir.path}/synchro-ios-$mediaId.mp4');
      final part = _part = File('${dir.path}/synchro-ios-$mediaId.part.mp4');
      if (await out.exists()) await out.delete();
      final input = await ffmpeg.inputFor(media.uri);
      final job = _job = await ffmpeg.startFile(
        iosCopyArgs(input, part.path, hevc: hevc),
      );
      final ok = await job.done;
      _job = null;
      if (_disposed || job.isCancelled) throw StateError('session fermée');
      if (!ok) throw const FfmpegException('FFmpeg a échoué');
      await part.rename(out.path);
      _state = IosCopyState.ready;
      return MediaRef(
        uri: out.path,
        name: downloadName,
        size: await out.length(),
      );
    } catch (e) {
      _state = IosCopyState.error;
      _error = '$e';
      try {
        await _part?.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Arrête une préparation en cours et supprime les fichiers temporaires.
  Future<void> dispose() async {
    _disposed = true;
    await _job?.cancel();
    for (final f in [_part, _out]) {
      try {
        if (f != null && await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  static Future<void> _status(HttpResponse res, int code) async {
    res.statusCode = code;
    res.contentLength = 0;
    await res.close();
  }
}
