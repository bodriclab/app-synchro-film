import 'dart:async';
import 'dart:io';

import '../core/audio_packet.dart';
import 'audio_sink.dart';

/// Mode 5 : WebSocket binaire `/pcm?token=…` vers les navigateurs.
///
/// Chaque message = un [AudioPacket] (en-tête 16 octets + PCM s16le 20 ms).
/// Plusieurs navigateurs peuvent écouter en même temps.
class WebSocketAudioSink implements AudioSink {
  WebSocketAudioSink({required this.token, this.onListener});

  final String token;

  /// Appelé à chaque nouvel auditeur (l'hôte repart de la position courante).
  final void Function()? onListener;

  final Set<WebSocket> _sockets = {};
  int sent = 0;

  int get listeners => _sockets.length;

  @override
  bool get hasTarget => _sockets.isNotEmpty;

  Future<void> call(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.badRequest;
      await req.response.close();
      return;
    }
    if (req.uri.queryParameters['token'] != token) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    ws.pingInterval = const Duration(seconds: 5);
    _sockets.add(ws);
    ws.listen(
      (_) {},
      onDone: () => _sockets.remove(ws),
      onError: (_) => _sockets.remove(ws),
      cancelOnError: true,
    );
    onListener?.call();
  }

  @override
  void send(AudioPacket packet) {
    if (_sockets.isEmpty) return;
    final bytes = packet.encode();
    for (final ws in _sockets.toList()) {
      try {
        ws.add(bytes);
      } catch (_) {
        _sockets.remove(ws);
      }
    }
    sent++;
  }

  Future<void> close() async {
    final all = _sockets.toList();
    _sockets.clear();
    for (final ws in all) {
      await ws.close().catchError((_) {});
    }
  }
}
