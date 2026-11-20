import 'dart:async';
import 'dart:io';

import '../core/protocol.dart';

/// Canal de messages [SyncMessage] au-dessus d'un WebSocket (dart:io).
class PeerChannel {
  PeerChannel(this._socket, {this.remoteAddress}) {
    // Keep-alive léger : détecte une coupure Wi-Fi en ~10 s.
    _socket.pingInterval = const Duration(seconds: 5);
    _sub = _socket.listen(
      (data) {
        if (data is! String) return;
        try {
          _messages.add(SyncMessage.decode(data));
        } on ProtocolException catch (e) {
          _messages.addError(e);
        }
      },
      onDone: _onDone,
      onError: (Object e) => _onDone(),
      cancelOnError: true,
    );
  }

  final WebSocket _socket;
  final String? remoteAddress;
  final _messages = StreamController<SyncMessage>.broadcast();
  final _closed = Completer<void>();
  late final StreamSubscription<dynamic> _sub;

  Stream<SyncMessage> get messages => _messages.stream;

  /// Complété quand la connexion se ferme (quelle qu'en soit la cause).
  Future<void> get done => _closed.future;

  bool _closing = false;

  bool get isOpen => !_closed.isCompleted && !_closing;

  /// Envoie un message ; ignoré silencieusement si la connexion se ferme.
  void send(SyncMessage msg) {
    if (!isOpen) return;
    try {
      _socket.add(msg.encode());
    } on StateError {
      _onDone();
    }
  }

  Future<void> close([int code = WebSocketStatus.normalClosure]) async {
    if (!isOpen) return;
    _closing = true;
    await _socket.close(code);
    _onDone();
  }

  void _onDone() {
    if (_closed.isCompleted) return;
    _closed.complete();
    _sub.cancel();
    _messages.close();
  }

  /// Connexion côté invité.
  static Future<PeerChannel> connect(
    Uri wsUri, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket = await WebSocket.connect(wsUri.toString()).timeout(timeout);
    return PeerChannel(socket, remoteAddress: wsUri.host);
  }
}
