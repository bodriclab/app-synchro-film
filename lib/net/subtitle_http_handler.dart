import 'dart:convert';
import 'dart:io';

import '../core/media_source.dart';
import '../core/subtitle_text.dart';
import '../core/subtitles.dart';
import '../platform/ffmpeg_runner.dart';

/// Sous-titres choisis par l'hôte, servis aux invités :
///
/// - `GET /subs/file?token=…` → texte brut du fichier externe (UTF-8), que
///   l'app invitée charge telle quelle (SRT, ASS, VTT) ;
/// - `GET /subs/track.vtt?token=…&shift=ms` → WebVTT pour la balise `<track>`
///   du navigateur (mode 4). Piste intégrée : extraite par FFmpeg ; ASS :
///   converti par FFmpeg ; SRT : converti en Dart. `shift` décale les
///   minutages (temps 0 d'un flux réemballé ≠ début du film).
class SubtitleHttpHandler {
  SubtitleHttpHandler({
    required this.token,
    required this.media,
    required this.ffmpeg,
    required this.current,
    Future<Directory> Function()? tempDir,
  }) : _tempDir = tempDir ?? (() async => Directory.systemTemp);

  final String token;
  final MediaRef media;
  final FfmpegRunner Function() ffmpeg;

  /// Choix courant et texte du fichier externe éventuel.
  final ({SubtitleSelection selection, String? text, int rev}) Function()
  current;
  final Future<Directory> Function() _tempDir;

  int? _cachedRev;
  String? _cachedVtt;
  Future<String>? _pending;

  static const filePath = '/subs/file';
  static const vttPath = '/subs/track.vtt';

  Future<void> call(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    if (req.uri.queryParameters['token'] != token) {
      return await _plain(res, HttpStatus.forbidden, '');
    }
    final cur = current();
    try {
      if (path == filePath) {
        final text = cur.text;
        if (cur.selection.kind != SubtitleKind.external || text == null) {
          return await _plain(
            res,
            HttpStatus.notFound,
            'aucun fichier externe',
          );
        }
        return await _send(
          res,
          ContentType('text', 'plain', charset: 'utf-8'),
          text,
        );
      }
      if (path == vttPath) {
        if (cur.selection.isOff) {
          return await _plain(
            res,
            HttpStatus.notFound,
            'sous-titres désactivés',
          );
        }
        if (cur.selection.isBitmap) {
          return await _plain(
            res,
            HttpStatus.unsupportedMediaType,
            'sous-titres image (PGS/VobSub) non convertibles',
          );
        }
        final vtt = await _vtt(cur.selection, cur.text, cur.rev);
        final shift = int.tryParse(req.uri.queryParameters['shift'] ?? '') ?? 0;
        return await _send(
          res,
          ContentType('text', 'vtt', charset: 'utf-8'),
          shiftVtt(vtt, shift),
        );
      }
      return await _plain(res, HttpStatus.notFound, '');
    } catch (e) {
      return await _plain(
        res,
        HttpStatus.unsupportedMediaType,
        'Conversion : $e',
      );
    }
  }

  Future<String> _vtt(SubtitleSelection sel, String? text, int rev) {
    if (_cachedRev == rev && _cachedVtt != null) {
      return Future.value(_cachedVtt!);
    }
    if (_cachedRev == rev && _pending != null) return _pending!;
    _cachedRev = rev;
    _cachedVtt = null;
    final f = _convert(sel, text).then((v) {
      if (_cachedRev == rev) _cachedVtt = v;
      return v;
    });
    _pending = f;
    f.catchError((Object _) {
      if (_cachedRev == rev) _cachedRev = null; // réessayer plus tard
      return '';
    });
    return f;
  }

  Future<String> _convert(SubtitleSelection sel, String? text) async {
    final runner = ffmpeg();
    if (sel.kind == SubtitleKind.embedded) {
      final input = await runner.inputFor(media.uri);
      final out = await runner.run(embeddedVttArgs(input, sel.index!));
      return utf8.decode(out, allowMalformed: true);
    }
    if (text == null) throw StateError('fichier absent');
    final name = (sel.name ?? '').toLowerCase();
    if (looksLikeVtt(text)) return text;
    if (name.endsWith('.ass') ||
        name.endsWith('.ssa') ||
        text.contains('[Script Info]')) {
      final dir = await _tempDir();
      final f = File(
        '${dir.path}/synchro-subs-${DateTime.now().microsecondsSinceEpoch}.ass',
      );
      await f.writeAsString(text);
      try {
        final out = await runner.run(fileVttArgs(f.path));
        return utf8.decode(out, allowMalformed: true);
      } finally {
        await f.delete().catchError((_) => f);
      }
    }
    return subtitleToVtt(text, name.isEmpty ? 'x.srt' : name);
  }

  static Future<void> _send(HttpResponse res, ContentType type, String body) {
    final bytes = utf8.encode(body);
    res.headers
      ..contentType = type
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    res.contentLength = bytes.length;
    res.add(bytes);
    return res.close();
  }

  static Future<void> _plain(HttpResponse res, int code, String msg) {
    res.statusCode = code;
    return _send(res, ContentType('text', 'plain', charset: 'utf-8'), msg);
  }
}
