import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/clock_sync.dart';
import '../../core/constants.dart';
import '../../core/file_fingerprint.dart';
import '../../core/media_source.dart';
import '../../core/monotonic_clock.dart';
import '../../core/protocol.dart';
import '../../core/subtitles.dart';
import '../../modes/stream_mode.dart';
import '../../core/session_endpoint.dart';
import '../../modes/mode_handler.dart';
import '../../platform/media_access.dart';
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
    this.localMedia,
    MediaOpener? opener,
    this.helloTimeout = const Duration(seconds: 5),
    this.deviceName = 'Invité',
    MonotonicClock? clock,
    this.minClockSamples = 3,
  }) : opener = opener ?? openMedia,
       clock = clock ?? MonotonicClock(),
       clockSync = ClockSync() {
    controller = SyncController(
      engine: engine,
      clock: GuestSharedClock(this.clock, clockSync),
      localNowMs: this.clock.nowMs,
      isReady: () => _mediaReady && clockSync.samples.length >= minClockSamples,
    );
  }

  final SessionEndpoint endpoint;

  /// Copie locale du film (mode 1 uniquement).
  final MediaRef? localMedia;
  final MediaOpener opener;
  final Duration helloTimeout;
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

  /// Mode 2 : adresse HTTP du film de l'hôte (téléchargeable avec reprise).
  Uri? hostMediaUrl;
  String? hostMediaName;
  final Completer<HelloMsg> _hostHello = Completer<HelloMsg>();
  bool _mediaReady = false;
  GuestAttachment? _attachment;

  @override
  bool get isHost => false;

  @override
  int? get rttMs => clockSync.rttMs;

  /// Connexion : `hello` → réponse de l'hôte → ouverture du média
  /// (fichier local en mode 1, URL HTTP de l'hôte en mode 2) → synchro.
  Future<void> start() async {
    update(status: SessionStatus.connecting);
    try {
      if (mode.checksFingerprint && localMedia != null) {
        fingerprint = await FileFingerprint.computeWith(
          localMedia!.uri,
          opener,
        );
      }
      final attachment = await mode.prepareGuest();
      _attachment = attachment;
      final ch = await PeerChannel.connect(endpoint.wsUri);
      _channel = ch;
      _sub = ch.messages.listen(_onMessage, onError: (_) {});
      ch.done.then((_) => _onDisconnected());
      ch.send(
        HelloMsg(
          role: PeerRole.guest,
          deviceName: deviceName,
          mode: sessionMode,
          fingerprint: fingerprint,
          audioPort: attachment.audioPort,
        ),
      );
      _ping();
      final hostHello = await _hostHello.future.timeout(helloTimeout);
      hostMediaName = hostHello.mediaName;
      final mp = hostHello.mediaPath;
      if (mp != null && mp.startsWith('/media/')) {
        hostMediaUrl = StreamMode.mediaUrl(endpoint, mp);
      }
      final source = await mode.resolveGuestSource(
        endpoint: endpoint,
        hostHello: hostHello,
        localMedia: localMedia,
      );
      await engine.open(source);
      _mediaReady = true;
      controller.start();
      await attachment.onStart?.call(
        GuestContext(
          localNowMs: clock.nowMs,
          expectedPositionAt: _expectedPositionAt,
        ),
      );
      update(
        status: SessionStatus.connected,
        peerName: hostHello.deviceName,
        fileMatch: hostHello.fileMatch,
      );
    } catch (e) {
      update(status: SessionStatus.error, error: '$e');
      await _channel?.close();
      await _attachment?.detach();
      _attachment = null;
      rethrow;
    }
  }

  /// Objet de réglage propre au mode (ex. latence audio du mode 3).
  Object? get modeControl => _attachment?.control;

  int? _expectedPositionAt(int localMs) {
    if (!_mediaReady || clockSync.samples.length < minClockSamples) return null;
    final target = controller.target;
    if (target == null || !target.playing) return null;
    return target.positionAt(
      clockSync.toHost(localMs),
      durationMs: hostDurationMs,
    );
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
        if (!_hostHello.isCompleted) _hostHello.complete(msg);
      case StateMsg():
        controller.applyState(msg.state);
        notifyListeners();
      case ErrorMsg():
        if (!_hostHello.isCompleted) {
          _hostHello.completeError(StateError(msg.message));
        }
        update(status: SessionStatus.error, error: msg.message);
      case SubsMsg():
        _onSubs(msg);
      case PingMsg() || CmdMsg():
        break; // non attendus côté invité
    }
  }

  int _subsRev = -1;

  /// Sous-titres choisis par l'hôte : même piste intégrée (même fichier) ou
  /// fichier externe téléchargé chez l'hôte. L'invité peut ensuite changer
  /// localement ; le prochain choix de l'hôte s'appliquera de nouveau.
  Future<void> _onSubs(SubsMsg msg) async {
    _subsRev = msg.rev;
    String? text;
    if (msg.selection.kind == SubtitleKind.external) {
      try {
        text = await fetchHostSubtitleText();
      } catch (_) {
        return; // hôte injoignable : on garde l'affichage actuel
      }
      if (_subsRev != msg.rev) return; // un choix plus récent est arrivé
    }
    await applySubtitle(msg.selection, text: text);
  }

  /// Télécharge le fichier de sous-titres externe de l'hôte.
  Future<String> fetchHostSubtitleText() async {
    final uri = Uri(
      scheme: 'http',
      host: endpoint.host,
      port: endpoint.port,
      path: '/subs/file',
      queryParameters: {'token': endpoint.token},
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final res = await (await client.getUrl(uri)).close();
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }
      return await utf8.decodeStream(res);
    } finally {
      client.close();
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
    await _attachment?.detach();
    await controller.dispose();
  }
}
