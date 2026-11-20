import '../core/media_source.dart';
import '../core/protocol.dart';
import '../core/session_endpoint.dart';
import '../core/session_mode.dart';
import '../net/audio_udp.dart';
import '../platform/audio/opus_frames.dart';
import '../platform/audio/pcm_output.dart';
import 'audio/audio_guest_player.dart';
import 'audio/audio_host_streamer.dart';
import 'audio/audio_latency_control.dart';
import 'mode_handler.dart';

/// Services injectables du mode 3 (implémentations réelles par défaut,
/// remplaçables dans les tests).
class AudioServices {
  const AudioServices({
    this.initCodec = ensureOpus,
    this.newEncoder = _newEncoder,
    this.newDecoder = _newDecoder,
    this.newOutput = _newOutput,
    this.newLatencyControl = _newLatencyControl,
  });

  final Future<void> Function() initCodec;
  final FrameEncoder Function() newEncoder;
  final FrameDecoder Function() newDecoder;
  final PcmOutput Function() newOutput;
  final AudioLatencyControl Function() newLatencyControl;

  static FrameEncoder _newEncoder() => OpusFrameEncoder().encode;
  static FrameDecoder _newDecoder() => OpusFrameDecoder().decode;
  static PcmOutput _newOutput() => MiniaudioPcmOutput();
  static AudioLatencyControl _newLatencyControl() => AudioLatencyControl();
}

/// Mode 3 — Stream audio seul (écran partagé).
///
/// L'hôte affiche la vidéo (et garde son propre son) ; la piste audio est
/// décodée par FFmpeg, encodée en Opus (trames de 20 ms) et envoyée en UDP.
/// L'invité n'a pas de vidéo : buffer de gigue → décodage → sortie audio,
/// calée sur la timeline de l'hôte en compensant la latence de sortie
/// (auto via l'OS + curseur manuel mémorisé par sortie).
class AudioOnlyMode extends ModeHandler {
  const AudioOnlyMode({this.services = const AudioServices()});

  final AudioServices services;

  @override
  SessionMode get mode => SessionMode.audioOnly;

  @override
  String get title => 'Audio seul (écran partagé)';

  @override
  String get subtitle => 'Un écran, chacun ses écouteurs Bluetooth';

  @override
  bool get isImplemented => true;

  @override
  bool get guestNeedsLocalFile => false;

  @override
  bool get guestShowsVideo => false;

  @override
  Future<HostAttachment> attachHost(HostContext ctx) async {
    await services.initCodec();
    final sender = await AudioSender.bind();
    final streamer = AudioHostStreamer(
      ffmpeg: ctx.ffmpeg(),
      media: ctx.media,
      sender: sender,
      encode: services.newEncoder(),
      hostNowMs: ctx.hostNowMs,
      state: ctx.state,
      durationMs: ctx.durationMs,
    )..start();
    return HostAttachment(
      localSource: ctx.media.uri,
      onGuestHello: (hello, address) {
        final port = hello.audioPort;
        if (port != null && address != null) sender.setTarget(address, port);
      },
      onGuestLeft: sender.clearTarget,
      onDetach: () async {
        await streamer.dispose();
        sender.close();
      },
    );
  }

  @override
  Future<GuestAttachment> prepareGuest() async {
    await services.initCodec();
    final receiver = await AudioReceiver.bind();
    final control = services.newLatencyControl();
    AudioGuestPlayer? player;
    return GuestAttachment(
      audioPort: receiver.port,
      control: control,
      onStart: (ctx) async {
        await control.start();
        player = AudioGuestPlayer(
          packets: receiver.packets,
          decode: services.newDecoder(),
          output: services.newOutput(),
          localNowMs: ctx.localNowMs,
          expectedPositionAt: ctx.expectedPositionAt,
          outputLatencyMs: () => control.totalMs,
        )..start();
        control.player = player;
      },
      onDetach: () async {
        await player?.dispose();
        receiver.close();
        control.dispose();
      },
    );
  }

  @override
  Future<String> resolveGuestSource({
    required SessionEndpoint endpoint,
    required HelloMsg hostHello,
    MediaRef? localMedia,
  }) async => ''; // pas de vidéo : lecteur virtuel
}
