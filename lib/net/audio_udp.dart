import 'dart:async';
import 'dart:io';

import '../core/audio_packet.dart';

/// Émetteur UDP de l'hôte (mode 3).
class AudioSender {
  AudioSender._(this._socket);

  static Future<AudioSender> bind() async =>
      AudioSender._(await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0));

  final RawDatagramSocket _socket;
  InternetAddress? _target;
  int? _port;
  int sent = 0;

  void setTarget(String address, int port) {
    _target = InternetAddress(address);
    _port = port;
  }

  void clearTarget() {
    _target = null;
    _port = null;
  }

  bool get hasTarget => _target != null;

  void send(AudioPacket p) {
    final t = _target;
    if (t == null) return;
    _socket.send(p.encode(), t, _port!);
    sent++;
  }

  void close() => _socket.close();
}

/// Récepteur UDP de l'invité (mode 3).
class AudioReceiver {
  AudioReceiver._(this._socket) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = _socket.receive()) != null) {
        final p = AudioPacket.decode(d!.data);
        if (p != null) _packets.add(p);
      }
    });
  }

  static Future<AudioReceiver> bind({int port = 0}) async => AudioReceiver._(
    await RawDatagramSocket.bind(InternetAddress.anyIPv4, port),
  );

  final RawDatagramSocket _socket;
  final _packets = StreamController<AudioPacket>.broadcast();

  int get port => _socket.port;
  Stream<AudioPacket> get packets => _packets.stream;

  void close() {
    _socket.close();
    _packets.close();
  }
}
