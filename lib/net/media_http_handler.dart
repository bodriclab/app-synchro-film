import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../core/http_range.dart';
import '../core/media_source.dart';

/// Sert un média en HTTP progressif (`GET`/`HEAD /media/{id}?token=…`)
/// avec support `Range` (206), sans réencodage ni copie : les octets sont
/// lus à la demande depuis le fichier ou l'URI content:// d'origine.
class MediaHttpHandler {
  MediaHttpHandler({
    required this.token,
    required this.mediaId,
    required this.media,
    required this.opener,
    this.chunkSize = 256 * 1024,
  });

  final String token;
  final String mediaId;
  final MediaRef media;
  final MediaOpener opener;
  final int chunkSize;

  String get path => '/media/$mediaId';

  Future<void> call(HttpRequest req) async {
    final res = req.response;
    if (req.uri.path != path) {
      return _status(res, HttpStatus.notFound);
    }
    if (req.uri.queryParameters['token'] != token) {
      return _status(res, HttpStatus.forbidden);
    }
    final isHead = req.method == 'HEAD';
    if (!isHead && req.method != 'GET') {
      res.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      return _status(res, HttpStatus.methodNotAllowed);
    }

    final RandomAccessMedia source;
    try {
      source = await opener(media.uri);
    } catch (_) {
      return _status(res, HttpStatus.internalServerError);
    }
    try {
      final size = source.length;
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..contentType = ContentType.parse(mimeTypeFor(media.name))
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      final range = parseRange(
        req.headers.value(HttpHeaders.rangeHeader),
        size,
      );
      final ByteRange body;
      switch (range) {
        case UnsatisfiableRange():
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          return await _status(res, HttpStatus.requestedRangeNotSatisfiable);
        case PartialContent(:final range):
          res.statusCode = HttpStatus.partialContent;
          res.headers.set(
            HttpHeaders.contentRangeHeader,
            range.contentRange(size),
          );
          body = range;
        case FullContent():
          res.statusCode = HttpStatus.ok;
          body = ByteRange(0, size - 1);
      }
      res.contentLength = size == 0 ? 0 : body.length;
      if (!isHead && size > 0) {
        await res.addStream(_chunks(source, body));
      }
      await res.close();
    } on HttpException {
      // Client parti (seek de media_kit, navigateur fermé…) : normal.
    } on SocketException {
      // idem
    } finally {
      await source.close();
    }
  }

  Stream<List<int>> _chunks(RandomAccessMedia source, ByteRange range) async* {
    var pos = range.start;
    while (pos <= range.end) {
      final n = min(chunkSize, range.end - pos + 1);
      final bytes = await source.read(pos, n);
      if (bytes.isEmpty) break;
      yield bytes;
      pos += bytes.length;
    }
  }

  static Future<void> _status(HttpResponse res, int code) async {
    res.statusCode = code;
    res.contentLength = 0;
    await res.close();
  }
}
