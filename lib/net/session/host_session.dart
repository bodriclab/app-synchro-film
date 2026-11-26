import 'dart:async';

import '../../core/clock_sync.dart';
import '../../core/constants.dart';
import '../../core/file_fingerprint.dart';
import '../../core/media_source.dart';
import '../../core/monotonic_clock.dart';
import '../../core/playback_arbiter.dart';
import '../../core/protocol.dart';
import '../../core/session_endpoint.dart';
import '../../core/subtitles.dart';
import '../../modes/mode_handler.dart';
import '../../platform/ffmpeg_runner.dart';
import '../../platform/temp_dir.dart';
import '../../platform/media_access.dart';
import '../../platform/web_assets.dart';
import '../web_client_handler.dart';
import '../../player/sync_controller.dart';
import '../discovery.dart';
import '../host_server.dart';
import '../subtitle_http_handler.dart';
import '../peer_channel.dart';
import 'sync_session.dart';

/// Session côté hôte : horloge de référence + arbitre des commandes.
///
/// - répond aux `ping` (t1/t2 sur son horloge) ;
/// - applique les `cmd` des deux pairs (la dernière reçue gagne) et
///   rediffuse `state` à chaque changement + toutes les 2 s ;
/// - suit lui-même la timeline de référence avec la correction douce.
class HostSession extends SyncSession {
  HostSession({
    required super.engine,
    required super.mode,
    required this.media,
    MediaOpener? opener,
    FfmpegRunner Function()? ffmpeg,
    AssetLoader? loadAsset,
    this.deviceName = 'Hôte',
    this.announcer,
    String? token,
    this.preferredPort = kDefaultPort,
    MonotonicClock? clock,
  }) : opener = opener ?? openMedia,
       ffmpeg = ffmpeg ?? defaultFfmpegRunner,
       loadAsset = loadAsset ?? loadWebClientAsset,
       clock = clock ?? MonotonicClock(),
       token = token ?? generateSessionToken() {
    server = HostServer(token: this.token, preferredPort: preferredPort);
    arbiter = PlaybackArbiter(this.clock.nowMs);
    controller = SyncController(
      engine: engine,
      clock: HostSharedClock(this.clock),
      localNowMs: this.clock.nowMs,
    );
  }

  /// Film de l'hôte (chemin ou URI content:// d'origine, jamais copié).
  final MediaRef media;
  final MediaOpener opener;
  final FfmpegRunner Function() ffmpeg;
  final AssetLoader loadAsset;
  final String deviceName;
  final SessionAnnouncer? announcer;
  final MonotonicClock clock;
  final String token;
  final int preferredPort;

  late final HostServer server;
  late final PlaybackArbiter arbiter;
  @override
  late final SyncController controller;

  FileFingerprint? fingerprint;
  late final SubtitleHttpHandler _subs = SubtitleHttpHandler(
    token: token,
    media: media,
    ffmpeg: ffmpeg,
    current: () =>
        (selection: subtitle, text: _subtitleText, rev: _subtitleRev),
    tempDir: appTempDir,
  );
  String? _subtitleText;
  int _subtitleRev = 0;
  PeerChannel? _guest;
  StreamSubscription<PeerChannel>? _guestsSub;
  StreamSubscription<SyncMessage>? _msgSub;
  Timer? _stateTimer;
  HostAttachment? _attachment;

  @override
  bool get isHost => true;

  int get port => server.port;

  bool get hasGuest => _guest?.isOpen ?? false;

  /// Adresse à encoder dans le QR code pour l'IP [ip].
  SessionEndpoint endpointFor(String ip) =>
      SessionEndpoint(host: ip, port: port, token: token, mode: sessionMode);

  Future<void> start() async {
    update(status: SessionStatus.starting);
    try {
      if (mode.checksFingerprint) {
        fingerprint = await FileFingerprint.computeWith(media.uri, opener);
      }
      await server.start();
      server.addRoute('/subs/', _subs.call);
      final attachment = await mode.attachHost(
        HostContext(
          server: server,
          media: media,
          opener: opener,
          hostNowMs: clock.nowMs,
          state: () => arbiter.state,
          durationMs: () => engine.durationMs,
          ffmpeg: ffmpeg,
          loadAsset: loadAsset,
        ),
      );
      _attachment = attachment;
      await engine.open(attachment.localSource);
      _guestsSub = server.guests.listen(_onGuest);
      await controller.applyState(arbiter.state);
      controller.start();
      _stateTimer = Timer.periodic(kStateBroadcastInterval, (_) => _tick());
      await _announce();
      update(status: SessionStatus.waitingForGuest);
    } catch (e) {
      update(status: SessionStatus.error, error: '$e');
      rethrow;
    }
  }

  Future<void> _announce() async {
    try {
      await announcer?.start(
        name: deviceName,
        port: port,
        token: token,
        mode: sessionMode,
      );
    } catch (_) {
      // mDNS indisponible : le QR code reste utilisable.
    }
  }

  void _onGuest(PeerChannel channel) {
    // Un seul invité : une nouvelle connexion remplace l'ancienne (reconnexion).
    final old = _guest;
    _msgSub?.cancel();
    old?.close();
    _guest = channel;
    _msgSub = channel.messages.listen(
      (msg) => _onMessage(channel, msg),
      onError: (Object e) => channel.send(ErrorMsg('bad_message', '$e')),
    );
    channel.done.then((_) {
      if (!identical(_guest, channel)) return;
      _guest = null;
      _attachment?.onGuestLeft?.call();
      update(status: SessionStatus.waitingForGuest, clearPeer: true);
      _announce();
    });
  }

  void _onMessage(PeerChannel ch, SyncMessage msg) {
    final receivedAt = clock.nowMs();
    switch (msg) {
      case PingMsg(:final t0):
        ch.send(PongMsg(t0: t0, t1: receivedAt, t2: clock.nowMs()));
      case HelloMsg():
        _onHello(ch, msg);
      case CmdMsg():
        _apply(msg);
      case StateMsg() || PongMsg() || ErrorMsg() || SubsMsg():
        break; // non attendus côté hôte
    }
  }

  void _onHello(PeerChannel ch, HelloMsg hello) {
    if (hello.version != kProtocolVersion) {
      ch.send(const ErrorMsg('bad_version', 'Versions d\'app différentes'));
      ch.close();
      return;
    }
    if (hello.mode != sessionMode) {
      ch.send(const ErrorMsg('bad_mode', 'Mode de session différent'));
      ch.close();
      return;
    }
    final match = mode.checksFingerprint
        ? fingerprint!.matches(hello.fingerprint)
        : null;
    ch.send(
      HelloMsg(
        role: PeerRole.host,
        deviceName: deviceName,
        mode: sessionMode,
        fingerprint: fingerprint,
        durationMs: engine.durationMs,
        fileMatch: match,
        mediaPath: _attachment?.mediaPath,
        mediaName: media.name,
        remux: _attachment?.remux,
      ),
    );
    _attachment?.onGuestHello?.call(hello, ch.remoteAddress);
    ch.send(StateMsg(arbiter.state));
    if (!subtitle.isOff) ch.send(SubsMsg(subtitle, rev: _subtitleRev));
    update(
      status: SessionStatus.connected,
      peerName: hello.deviceName,
      fileMatch: match,
    );
    // Invité connecté : plus besoin d'annoncer (économie batterie).
    announcer?.stop();
  }

  void _apply(CmdMsg cmd) {
    arbiter.durationMs = engine.durationMs;
    final state = arbiter.apply(cmd);
    _guest?.send(StateMsg(state));
    controller.applyState(state);
    notifyListeners();
  }

  void _tick() {
    arbiter.durationMs = engine.durationMs;
    final ended = arbiter.checkEnd();
    if (ended != null) {
      controller.applyState(ended);
      notifyListeners();
    }
    _guest?.send(StateMsg(arbiter.state));
  }

  /// Choix de l'hôte : affiché ici et transmis à l'invité (app ou page web).
  @override
  Future<void> selectSubtitle(
    SubtitleSelection selection, {
    String? text,
  }) async {
    _subtitleText = selection.kind == SubtitleKind.external ? text : null;
    _subtitleRev++;
    await applySubtitle(selection, text: text);
    _guest?.send(SubsMsg(selection, rev: _subtitleRev));
  }

  @override
  Future<void> play() async => _apply(const CmdMsg.play());

  @override
  Future<void> pause() async => _apply(const CmdMsg.pause());

  @override
  Future<void> seekTo(int positionMs) async => _apply(CmdMsg.seek(positionMs));

  @override
  Future<void> close() async {
    _stateTimer?.cancel();
    await _guestsSub?.cancel();
    await _msgSub?.cancel();
    await _guest?.close();
    await announcer?.stop();
    await _attachment?.detach();
    await server.dispose();
    await controller.dispose();
    update(status: SessionStatus.idle, clearPeer: true);
  }
}
