import '../core/audio_packet.dart';

/// Destination des paquets audio de l'hôte : UDP vers l'app (mode 3) ou
/// WebSocket binaire vers un navigateur (mode 5).
abstract interface class AudioSink {
  /// Au moins un auditeur connecté (sinon l'hôte ne décode rien).
  bool get hasTarget;

  void send(AudioPacket packet);
}
