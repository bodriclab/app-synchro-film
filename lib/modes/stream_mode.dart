import '../core/session_endpoint.dart';
import '../core/session_mode.dart';
import '../net/host_server.dart';
import 'mode_handler.dart';

/// Mode 2 — Stream complet App ↔ App (NON IMPLÉMENTÉ).
///
/// TODO(mode2) :
/// - `attachHost` : enregistrer `server.addRoute('/media/', ...)` servant le
///   fichier en HTTP progressif avec support `Range` (206 Partial Content),
///   puis retourner [filePath] pour la lecture locale de l'hôte.
/// - `resolveGuestSource` : retourner `${endpoint.httpBase}media/<id>?token=…`
///   que media_kit lit directement (aucun réencodage).
/// - La synchro réutilise tel quel le protocole du mode 1.
class StreamMode extends ModeHandler {
  const StreamMode();

  @override
  SessionMode get mode => SessionMode.stream;

  @override
  String get title => 'Stream app ↔ app';

  @override
  String get subtitle => 'Un seul a le fichier, il le diffuse à l\'autre';

  @override
  bool get isImplemented => false;

  @override
  bool get guestNeedsLocalFile => false;

  @override
  Future<String> attachHost({
    required HostServer server,
    required String filePath,
  }) =>
      throw UnimplementedError('Mode 2 (stream) pas encore implémenté');

  @override
  Future<String> resolveGuestSource({
    required SessionEndpoint endpoint,
    String? localFilePath,
  }) =>
      throw UnimplementedError('Mode 2 (stream) pas encore implémenté');
}
