import 'dart:async';
import 'dart:io';

import '../core/constants.dart';
import 'peer_channel.dart';

/// Gestionnaire HTTP enregistré par un mode (point d'extension modes 2 et 4).
typedef RouteHandler = Future<void> Function(HttpRequest request);

/// Serveur de l'hôte : un seul port TCP pour
/// - le WebSocket de contrôle (`/ws?token=...`) ;
/// - les routes HTTP ajoutées par les modes via [addRoute]
///   (ex. `/media/` en HTTP Range pour le mode 2, `/` page web pour le mode 4).
///
/// Démarré uniquement pendant une session (économie batterie).
class HostServer {
  HostServer({required this.token, this.preferredPort = kDefaultPort});

  final String token;
  final int preferredPort;

  HttpServer? _server;
  final Map<String, RouteHandler> _routes = {};
  final _guests = StreamController<PeerChannel>.broadcast();

  /// Port effectivement ouvert (après [start]).
  int get port => _server?.port ?? 0;

  bool get isRunning => _server != null;

  /// Nouvelle connexion WebSocket authentifiée.
  Stream<PeerChannel> get guests => _guests.stream;

  /// Enregistre un gestionnaire pour les chemins commençant par [prefix].
  void addRoute(String prefix, RouteHandler handler) =>
      _routes[prefix] = handler;

  void removeRoute(String prefix) => _routes.remove(prefix);

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen(_handle, onError: (_) {});
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.uri.path == kWsPath) {
        await _handleWs(req);
        return;
      }
      // Préfixe le plus long d'abord.
      final prefixes = _routes.keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final p in prefixes) {
        if (req.uri.path.startsWith(p)) {
          await _routes[p]!(req);
          return;
        }
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleWs(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.badRequest;
      await req.response.close();
      return;
    }
    if (req.uri.queryParameters['token'] != token) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(req);
    _guests.add(PeerChannel(
      socket,
      remoteAddress: req.connectionInfo?.remoteAddress.address,
    ));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> dispose() async {
    await stop();
    await _guests.close();
  }
}
