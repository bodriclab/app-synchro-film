import 'dart:io';

/// Charge un fichier de la page web embarquée (`web_client/…`).
typedef AssetLoader = Future<String> Function(String name);

/// Modes 4 et 5 : sert la page web légère (HTML/JS embarqués, aucune ressource
/// externe : fonctionne 100 % hors-ligne).
///
/// `/` exige le token (sinon page d'aide) ; les scripts et feuilles de style
/// sont publics (aucun secret dedans).
class WebClientHandler {
  WebClientHandler({
    required this.token,
    required this.loadAsset,
    this.page = 'index.html',
  });

  final String token;
  final AssetLoader loadAsset;

  /// Page servie sur `/` : `index.html` (mode 4) ou `audio.html` (mode 5).
  final String page;
  final Map<String, String> _cache = {};

  static const List<String> _public = [
    'app.js',
    'app.css',
    'clock.js',
    'audio.js',
    'audio.css',
  ];

  String? _fileFor(String path) {
    if (path == '/' || path == '/$page') return page;
    final name = path.substring(1);
    return _public.contains(name) ? name : null;
  }

  Future<void> call(HttpRequest req) async {
    final res = req.response;
    final file = _fileFor(req.uri.path);
    if (file == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    if (file == page && req.uri.queryParameters['token'] != token) {
      res.statusCode = HttpStatus.forbidden;
      res.headers.contentType = ContentType.html;
      res.write(
        '<!doctype html><meta charset="utf-8"><meta name="viewport" '
        'content="width=device-width"><body style="font-family:sans-serif;'
        'padding:2em">Lien incomplet : scannez le QR code affiché par '
        'l\'hôte App Synchro Film.</body>',
      );
      await res.close();
      return;
    }
    final body = _cache[file] ??= await loadAsset(file);
    res.headers
      ..contentType = switch (file.split('.').last) {
        'html' => ContentType.html,
        'js' => ContentType('text', 'javascript', charset: 'utf-8'),
        _ => ContentType('text', 'css', charset: 'utf-8'),
      }
      ..set(HttpHeaders.cacheControlHeader, 'no-cache');
    res.write(body);
    await res.close();
  }
}
