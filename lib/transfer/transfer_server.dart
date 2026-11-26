import 'dart:convert';
import 'dart:io';

import '../core/media_source.dart';
import '../core/session_endpoint.dart' show generateSessionToken;
import '../net/host_server.dart';
import '../net/media_http_handler.dart';
import '../platform/media_access.dart';
import 'transfer_format.dart';

/// Port par défaut de l'envoi de fichier (distinct des sessions).
const int kTransferPort = 47480;

/// Envoi direct d'un fichier en Wi-Fi local, sans Internet :
///
/// - `GET /?token=…` → page de téléchargement pour un navigateur ;
/// - `GET /info?token=…` → `{"name", "size"}` (app réceptrice) ;
/// - `GET|HEAD /media/f?token=…[&download=1]` → le fichier, avec `Range`
///   (reprise après coupure, téléchargements parallèles du navigateur).
///
/// Le lien `http://IP:port/?token=…` est encodé dans le QR code : l'appareil
/// photo d'un téléphone ouvre la page, l'app télécharge directement.
class TransferServer {
  TransferServer({
    required this.media,
    MediaOpener? opener,
    String? token,
    this.preferredPort = kTransferPort,
  }) : opener = opener ?? openMedia,
       token = token ?? generateSessionToken(length: 10) {
    server = HostServer(token: this.token, preferredPort: preferredPort);
    _media = MediaHttpHandler(
      token: this.token,
      mediaId: 'f',
      media: media,
      opener: this.opener,
      onSent: (n) => bytesSent += n,
    );
  }

  final MediaRef media;
  final MediaOpener opener;
  final String token;
  final int preferredPort;
  late final HostServer server;
  late final MediaHttpHandler _media;
  int? _size;

  /// Octets envoyés depuis le démarrage (toutes connexions confondues).
  int bytesSent = 0;

  int get port => server.port;
  int? get size => _size;

  Uri linkFor(String ip) => Uri(
    scheme: 'http',
    host: ip,
    port: port,
    path: '/',
    queryParameters: {'token': token},
  );

  Future<void> start() async {
    final m = await opener(media.uri);
    try {
      _size = m.length;
    } finally {
      await m.close();
    }
    server
      ..addRoute('/media/', _media.call)
      ..addRoute('/info', _info)
      ..addRoute('/', _page);
    await server.start();
  }

  Future<void> stop() => server.dispose();

  bool _authorized(HttpRequest req) =>
      req.uri.queryParameters['token'] == token;

  Future<void> _info(HttpRequest req) async {
    final res = req.response;
    if (!_authorized(req)) return _deny(res);
    res.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    res.write(jsonEncode({'name': media.name, 'size': _size}));
    await res.close();
  }

  Future<void> _page(HttpRequest req) async {
    final res = req.response;
    if (req.uri.path != '/' && req.uri.path != '/index.html') {
      res.statusCode = HttpStatus.notFound;
      return res.close();
    }
    if (!_authorized(req)) return _deny(res);
    final url = '/media/f?token=${Uri.encodeQueryComponent(token)}&download=1';
    res.headers
      ..contentType = ContentType.html
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    res.write(
      transferPageHtml(name: media.name, size: _size ?? 0, downloadUrl: url),
    );
    await res.close();
  }

  static Future<void> _deny(HttpResponse res) async {
    res.statusCode = HttpStatus.forbidden;
    res.headers.contentType = ContentType.text;
    res.write('Lien expiré ou invalide.');
    await res.close();
  }
}

/// Lien d'envoi scanné ou saisi : `http://IP:port/?token=…`.
class TransferLink {
  const TransferLink({
    required this.host,
    required this.port,
    required this.token,
  });

  final String host;
  final int port;
  final String token;

  Uri _u(String path) => Uri(
    scheme: 'http',
    host: host,
    port: port,
    path: path,
    queryParameters: {'token': token},
  );

  Uri get infoUri => _u('/info');
  Uri get fileUri => _u('/media/f');

  static TransferLink? tryParse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) return null;
    final token = uri.queryParameters['token'];
    if (token == null || token.isEmpty) return null;
    if (uri.path != '/' && uri.path.isNotEmpty) return null;
    return TransferLink(
      host: uri.host,
      port: uri.hasPort ? uri.port : 80,
      token: token,
    );
  }

  /// Nom et taille du fichier proposé.
  Future<({String name, int? size})> fetchInfo() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final res = await (await client.getUrl(infoUri)).close();
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: infoUri);
      }
      final j = jsonDecode(await utf8.decodeStream(res)) as Map;
      return (
        name: (j['name'] as String?) ?? 'film',
        size: (j['size'] as num?)?.toInt(),
      );
    } finally {
      client.close();
    }
  }
}
