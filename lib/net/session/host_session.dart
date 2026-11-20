import 'dart:async';

import '../../core/clock_sync.dart';
import '../../core/constants.dart';
import '../../core/file_fingerprint.dart';
import '../../core/monotonic_clock.dart';
import '../../core/playback_arbiter.dart';
import '../../core/protocol.dart';
import '../../core/session_endpoint.dart';
import '../../player/sync_controller.dart';
import '../discovery.dart';
import '../host_server.dart';
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
    required this.filePath,
    this.deviceName = 'Hôte',
    this.announcer,
    String? token,
    this.preferredPort = kDefaultPort,
    MonotonicClock? clock,
  })  : clock = clock ?? MonotonicClock(),
        token = token ?? generateSessionToken() {
    server = HostServer(token: this.token, preferredPort: preferredPort);
    arbiter = PlaybackArbiter(this.clock.nowMs);
    controller = SyncController(
      engine: engine,
      clock: HostSharedClock(this.clock),
      localNowMs: this.clock.nowMs,
    );
  }

  final String filePath;
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
  PeerChannel? _guest;
  StreamSubscription<PeerChannel>? _guestsSub;
  StreamSubscription<SyncMessage>? _msgSub;
  Timer? _stateTimer;

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
        fingerprint = await FileFingerprint.compute(filePath);
      }
      await server.start();
      final source = await mode.attachHost(server: server, filePath: filePath);
      await engine.open(source);
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
      case StateMsg() || PongMsg() || ErrorMsg():
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
    final match =
        mode.checksFingerprint ? fingerprint!.matches(hello.fingerprint) : null;
    ch.send(HelloMsg(
      role: PeerRole.host,
      deviceName: deviceName,
      mode: sessionMode,
      fingerprint: fingerprint,
      durationMs: engine.durationMs,
      fileMatch: match,
    ));
    ch.send(StateMsg(arbiter.state));
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
    await mode.detach();
    await server.dispose();
    await controller.dispose();
    update(status: SessionStatus.idle, clearPeer: true);
  }
}
