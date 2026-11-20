import '../core/session_endpoint.dart';
import '../core/session_mode.dart';
import '../net/host_server.dart';
import 'mode_handler.dart';

/// Mode 4 — Stream vers navigateur (NON IMPLÉMENTÉ).
///
/// TODO(mode4) :
/// - `attachHost` : `server.addRoute('/', ...)` pour la page web embarquée
///   (`web_client/`), `server.addRoute('/media/', ...)` en HTTP Range, avec
///   remux FFmpeg à la volée en MP4 fragmenté si le conteneur n'est pas
///   lisible par le navigateur (MKV…), sans réencodage.
/// - La page JS se connecte au même WebSocket (`/ws?token=…`), parle le
///   même protocole et applique la correction douce via `playbackRate`.
/// - Le QR code encode directement `http://IP:port/?token=…`.
class BrowserMode extends ModeHandler {
  const BrowserMode();

  @override
  SessionMode get mode => SessionMode.browser;

  @override
  String get title => 'Stream vers navigateur';

  @override
  String get subtitle => 'L\'invité regarde dans son navigateur, sans l\'app';

  @override
  bool get isImplemented => false;

  @override
  bool get guestNeedsLocalFile => false;

  @override
  Future<String> attachHost({
    required HostServer server,
    required String filePath,
  }) =>
      throw UnimplementedError('Mode 4 (navigateur) pas encore implémenté');

  @override
  Future<String> resolveGuestSource({
    required SessionEndpoint endpoint,
    String? localFilePath,
  }) =>
      throw UnimplementedError('Mode 4 (navigateur) pas encore implémenté');
}
