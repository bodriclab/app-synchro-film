import 'dart:math';

import 'constants.dart';
import 'session_mode.dart';

/// Adresse d'une session hôte : ce que contient le QR code
/// (`synchrofilm://IP:port?token=...&mode=...`) ou ce que résout le mDNS.
class SessionEndpoint {
  const SessionEndpoint({
    required this.host,
    required this.port,
    required this.token,
    this.mode = SessionMode.doubleFile,
  });

  final String host;
  final int port;
  final String token;
  final SessionMode mode;

  /// URI à encoder dans le QR code. En modes 4 et 5 (navigateur), c'est
  /// directement l'adresse de la page web : `http://IP:port/?token=…`.
  Uri toUri() => mode.usesBrowser
      ? Uri(
          scheme: 'http',
          host: host,
          port: port,
          path: '/',
          queryParameters: {'token': token},
        )
      : Uri(
          scheme: kUriScheme,
          host: host,
          port: port,
          queryParameters: {'token': token, 'mode': mode.wireName},
        );

  /// URI WebSocket de contrôle.
  Uri get wsUri => Uri(
    scheme: 'ws',
    host: host,
    port: port,
    path: kWsPath,
    queryParameters: {'token': token},
  );

  /// URL HTTP de base (modes 2 et 4).
  Uri get httpBase => Uri(scheme: 'http', host: host, port: port, path: '/');

  @override
  String toString() => toUri().toString();

  @override
  bool operator ==(Object other) =>
      other is SessionEndpoint &&
      other.host == host &&
      other.port == port &&
      other.token == token &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(host, port, token, mode);

  /// Analyse une saisie : `synchrofilm://IP:port?token=...` (QR code)
  /// ou une saisie manuelle `IP:port` (+ [fallbackToken]).
  /// Retourne null si la saisie est invalide.
  static SessionEndpoint? tryParse(String input, {String? fallbackToken}) {
    final text = input.trim();
    if (text.isEmpty) return null;
    final Uri? uri = Uri.tryParse(
      text.contains('://') ? text : '$kUriScheme://$text',
    );
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != kUriScheme && uri.scheme != 'ws') return null;
    final port = uri.hasPort ? uri.port : kDefaultPort;
    if (port <= 0 || port > 65535) return null;
    final token = uri.queryParameters['token'] ?? fallbackToken;
    if (token == null || token.isEmpty) return null;
    return SessionEndpoint(
      host: uri.host,
      port: port,
      token: token,
      mode: SessionMode.fromWire(uri.queryParameters['mode']),
    );
  }
}

/// Génère un token de session court (sans caractères ambigus).
String generateSessionToken({int length = 8, Random? random}) {
  const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
  final rnd = random ?? Random.secure();
  return List.generate(
    length,
    (_) => alphabet[rnd.nextInt(alphabet.length)],
  ).join();
}
