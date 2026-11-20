import '../core/audio_packet.dart';
import '../core/media_source.dart';
import '../core/protocol.dart';
import '../core/session_endpoint.dart';
import '../core/session_mode.dart';
import '../net/audio_ws_handler.dart';
import '../net/web_client_handler.dart';
import 'audio/audio_host_streamer.dart';
import 'mode_handler.dart';

/// Mode 5 — Audio seul vers un navigateur.
///
/// Comme le mode 4, l'invité n'a pas l'app : il scanne le QR code
/// (`http://IP:port/?token=…`) et la page `web_client/audio.html` s'ouvre.
/// L'hôte décode la piste audio (FFmpeg → PCM s16le 48 kHz stéréo, trames de
/// 20 ms horodatées) et l'envoie ~1,2 s en avance sur un WebSocket binaire
/// (`/pcm`) — même pipeline que le mode 3, sans Opus (pas de WebCodecs ni
/// d'AudioWorklet hors contexte sécurisé). La page programme chaque trame
/// avec Web Audio (`AudioBufferSourceNode.start(t)`) à l'instant exact,
/// calculé avec l'horloge NTP partagée.
class BrowserAudioMode extends ModeHandler {
  const BrowserAudioMode();

  @override
  SessionMode get mode => SessionMode.browserAudio;

  @override
  String get title => 'Audio seul vers navigateur';

  @override
  String get subtitle =>
      'L\'invité écoute le son dans son navigateur, sans l\'app';

  @override
  bool get isImplemented => true;

  @override
  bool get guestNeedsLocalFile => false;

  @override
  bool get guestUsesApp => false;

  @override
  Future<HostAttachment> attachHost(HostContext ctx) async {
    final server = ctx.server;
    late final AudioHostStreamer streamer;
    final sink = WebSocketAudioSink(
      token: server.token,
      onListener: () => streamer.resync(),
    );
    streamer = AudioHostStreamer(
      ffmpeg: ctx.ffmpeg(),
      media: ctx.media,
      sender: sink,
      encode: pcmFrame,
      flags: kAudioFlagPcm,
      hostNowMs: ctx.hostNowMs,
      state: ctx.state,
      durationMs: ctx.durationMs,
    )..start();
    final web = WebClientHandler(
      token: server.token,
      loadAsset: ctx.loadAsset,
      page: 'audio.html',
    );
    server
      ..addRoute('/pcm', sink.call)
      ..addRoute('/', web.call);
    return HostAttachment(
      localSource: ctx.media.uri,
      onDetach: () async {
        server
          ..removeRoute('/pcm')
          ..removeRoute('/');
        await streamer.dispose();
        await sink.close();
      },
    );
  }

  @override
  Future<String> resolveGuestSource({
    required SessionEndpoint endpoint,
    required HelloMsg hostHello,
    MediaRef? localMedia,
  }) => throw UnsupportedError('En mode 5, l\'invité utilise un navigateur.');
}
