import '../core/media_source.dart';
import '../core/protocol.dart';
import '../core/session_endpoint.dart';
import '../core/session_mode.dart';
import '../net/media_http_handler.dart';
import 'mode_handler.dart';

/// Mode 2 — Stream complet App ↔ App.
///
/// L'hôte sert son fichier en HTTP progressif (`GET`/`HEAD /media/{id}`,
/// requêtes `Range`, protégé par le token de session) ; l'invité ouvre
/// cette URL dans media_kit (aucun réencodage, tous formats lus par libmpv).
/// La synchro est exactement celle du mode 1.
class StreamMode extends ModeHandler {
  const StreamMode();

  @override
  SessionMode get mode => SessionMode.stream;

  @override
  String get title => 'Stream app ↔ app';

  @override
  String get subtitle => 'Un seul a le fichier, il le diffuse à l\'autre';

  @override
  bool get isImplemented => true;

  @override
  bool get guestNeedsLocalFile => false;

  @override
  Future<HostAttachment> attachHost(HostContext ctx) async {
    final handler = MediaHttpHandler(
      token: ctx.server.token,
      mediaId: generateSessionToken(length: 6),
      media: ctx.media,
      opener: ctx.opener,
    );
    const prefix = '/media/';
    ctx.server.addRoute(prefix, handler.call);
    return HostAttachment(
      localSource: ctx.media.uri,
      mediaPath: handler.path,
      onDetach: () async => ctx.server.removeRoute(prefix),
    );
  }

  @override
  Future<String> resolveGuestSource({
    required SessionEndpoint endpoint,
    required HelloMsg hostHello,
    MediaRef? localMedia,
  }) async {
    final path = hostHello.mediaPath;
    if (path == null) {
      throw StateError('L\'hôte n\'a pas indiqué d\'URL de média.');
    }
    return mediaUrl(endpoint, path).toString();
  }

  /// URL HTTP du média pour l'invité.
  static Uri mediaUrl(SessionEndpoint endpoint, String mediaPath) => Uri(
    scheme: 'http',
    host: endpoint.host,
    port: endpoint.port,
    path: mediaPath,
    queryParameters: {'token': endpoint.token},
  );
}
