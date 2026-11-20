import 'dart:async';

import '../../core/clock_sync.dart';
import '../../core/constants.dart';
import '../../core/file_fingerprint.dart';
import '../../core/monotonic_clock.dart';
import '../../core/protocol.dart';
import '../../core/session_endpoint.dart';
import '../../player/sync_controller.dart';
import '../peer_channel.dart';
import 'sync_session.dart';

/// Session côté invité : synchronise son horloge sur l'hôte (ping/pong,
/// médiane de 8), suit l'état reçu avec la correction douce et envoie ses
/// propres commandes à l'hôte qui arbitre.
class GuestSession extends SyncSession {
  GuestSession({
    required super.engine,
    required super.mode,
    required this.endpoint,
    this.localFilePath,
    this.deviceName = 'Invité',
    MonotonicClock? clock,
    this.minClockSamples = 3,
  })  : clock = clock ?? MonotonicClock(),
        clockSync = ClockSync() {
    controller = SyncController(
      engine: engine,
      clock: GuestSharedClock(this.clock, clockSync),
      localNowMs: this.clock.nowMs,
      isReady: () => clockSync.samples.length >= minClockSamples,
    );
  }

  final SessionEndpoint endpoint;
  final String? localFilePath;
  final String deviceName;
  final MonotonicClock clock;
  final ClockSync clockSync;

  /// Échantillons d'horloge requis avant d'appliquer l'état reçu.
  final int minClockSamples;

  @override
  late final SyncController controller;

  PeerChannel? _channel;
  StreamSubscription<SyncMessage>? _sub;
  Timer? _pingTimer;
  FileFingerprint? fingerprint;
  int? hostDurationMs;

  @override
  bool get isHost => false;

  @override
  int? get rttMs => clockSync.rttMs;

  Future<void> start() async {
    update(status: SessionStatus.connecting);
    try {
      if (mode.checksFingerprint && localFilePath != null) {
        fingerprint = await FileFingerprint.compute(localFilePath!);
      }
      final source = await mode.resolveGuestSource(
        endpoint: endpoint,
        localFilePath: localFilePath,
      );
      await engine.open(source);
      final ch = await PeerChannel.connect(endpoint.wsUri);
      _channel = ch;
      _sub = ch.messages.listen(_onMessage, onError: (_) {});
      ch.done.then((_) => _onDisconnected());
      ch.send(HelloMsg(
        role: PeerRole.guest,
        deviceName: deviceName,
        mode: sessionMode,
        fingerprint: fingerprint,
        durationMs: engine.durationMs,
      ));
      _ping();
      controller.start();
    } catch (e) {
      update(status: SessionStatus.error, error: '$e');
      rethrow;
    }
  }

  void _ping() {
    _pingTimer?.cancel();
    final ch = _channel;
    if (ch == null || !ch.isOpen) return;
    ch.send(PingMsg(clock.nowMs()));
    _pingTimer = Timer(
      clockSync.isConverged ? kPingIntervalSlow : kPingIntervalFast,
      _ping,
    );
  }

  void _onMessage(SyncMessage msg) {
    switch (msg) {
      case PongMsg():
        clockSync.addExchange(
          t0: msg.t0,
          t1: msg.t1,
          t2: msg.t2,
          t3: clock.nowMs(),
        );
        controller.step();
        notifyListeners();
      case HelloMsg():
        hostDurationMs = msg.durationMs;
        update(
          status: SessionStatus.connected,
          peerName: msg.deviceName,
          fileMatch: msg.fileMatch,
        );
      case StateMsg():
        controller.applyState(msg.state);
        notifyListeners();
      case ErrorMsg():
        update(status: SessionStatus.error, error: msg.message);
      case PingMsg() || CmdMsg():
        break; // non attendus côté invité
    }
  }

  void _onDisconnected() {
    _pingTimer?.cancel();
    controller.stop();
    if (status != SessionStatus.idle) {
      engine.pause();
      // TODO(reconnexion) : retenter automatiquement la connexion.
      update(status: SessionStatus.disconnected);
    }
  }

  void _send(CmdMsg cmd) => _channel?.send(cmd);

  @override
  Future<void> play() async => _send(const CmdMsg.play());

  @override
  Future<void> pause() async => _send(const CmdMsg.pause());

  @override
  Future<void> seekTo(int positionMs) async => _send(CmdMsg.seek(positionMs));

  @override
  Future<void> close() async {
    update(status: SessionStatus.idle, clearPeer: true);
    _pingTimer?.cancel();
    await _sub?.cancel();
    await _channel?.close();
    await mode.detach();
    await controller.dispose();
  }
}
