import '../core/media_source.dart';
import '../core/protocol.dart';
import '../core/remux.dart';
import '../core/session_endpoint.dart';
import '../core/session_mode.dart';
import '../net/ios_download_handler.dart';
import '../net/media_http_handler.dart';
import '../net/remux_http_handler.dart';
import '../net/web_client_handler.dart';
import '../platform/temp_dir.dart';
import 'mode_handler.dart';

/// Mode 4 — Stream vers navigateur.
///
/// L'hôte sert :
/// - `/` : la page web embarquée (`web_client/`, HTML/JS sans dépendance,
///   100 % hors-ligne), qui parle le même protocole WebSocket ;
/// - `/media/{id}` : le fichier tel quel (HTTP Range) si le navigateur sait
///   lire le conteneur (MP4, WebM…) ;
/// - `/remux/{id}.mp4` : remux FFmpeg à la volée en MP4 fragmenté, sans
///   réencodage vidéo (MKV, AVI, TS…). L'audio AC3/DTS est converti en AAC ;
/// - `/download` : copie MP4 compatible Safari iOS à télécharger, que
///   l'invité ouvre ensuite en local (voir [IosDownloadHandler]).
///
/// Le QR code encode directement `http://IP:port/?token=…`.
class BrowserMode extends ModeHandler {
  const BrowserMode();

  @override
  SessionMode get mode => SessionMode.browser;

  @override
  String get title => 'Stream vers navigateur';

  @override
  String get subtitle => 'L\'invité regarde dans son navigateur, sans l\'app';

  @override
  bool get isImplemented => true;

  @override
  bool get guestNeedsLocalFile => false;

  @override
  bool get guestUsesApp => false;

  @override
  Future<HostAttachment> attachHost(HostContext ctx) async {
    final server = ctx.server;
    final id = generateSessionToken(length: 6);
    final direct = MediaHttpHandler(
      token: server.token,
      mediaId: id,
      media: ctx.media,
      opener: ctx.opener,
    );
    final remux = RemuxHttpHandler(
      token: server.token,
      mediaId: id,
      media: ctx.media,
      ffmpeg: ctx.ffmpeg(),
      tempDir: appTempDir,
      durationMs: ctx.durationMs,
    );
    final ios = IosDownloadHandler(
      token: server.token,
      mediaId: id,
      media: ctx.media,
      ffmpeg: ctx.ffmpeg(),
      direct: direct,
      videoCodec: () async => (await remux.probe(0)).videoCodec,
      tempDir: appTempDir,
    );
    var size = ctx.media.size;
    if (size == null) {
      try {
        final src = await ctx.opener(ctx.media.uri);
        size = src.length;
        await src.close();
      } catch (_) {}
    }
    final web = WebClientHandler(token: server.token, loadAsset: ctx.loadAsset);
    server
      ..addRoute('/media/', direct.call)
      ..addRoute('/remux/', remux.call)
      ..addRoute(IosDownloadHandler.path, ios.call)
      ..addRoute('/', web.call);
    return HostAttachment(
      localSource: ctx.media.uri,
      mediaPath: direct.path,
      remux: needsRemux(ctx.media.name),
      mediaSize: size,
      onDetach: () async {
        server
          ..removeRoute('/media/')
          ..removeRoute('/remux/')
          ..removeRoute(IosDownloadHandler.path)
          ..removeRoute('/');
        await remux.dispose();
        await ios.dispose();
      },
    );
  }

  @override
  Future<String> resolveGuestSource({
    required SessionEndpoint endpoint,
    required HelloMsg hostHello,
    MediaRef? localMedia,
  }) => throw UnsupportedError('En mode 4, l\'invité utilise un navigateur.');
}
