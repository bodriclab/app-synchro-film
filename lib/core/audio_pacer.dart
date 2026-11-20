import 'audio_packet.dart';

/// Décision de l'émetteur audio de l'hôte (mode 3) pour la trame suivante.
enum PacerAction {
  /// Envoyer la trame maintenant.
  send,

  /// Trop d'avance (ou pause) : attendre.
  wait,

  /// Le flux ne correspond plus à la timeline (seek, retard) : redémarrer
  /// le décodage à [AudioPacer.restartPositionMs].
  restart,
}

/// Rythme l'envoi des trames : on garde [leadMs] d'avance sur la position
/// attendue (assez pour absorber la gigue Wi-Fi + la latence Bluetooth
/// compensée par l'invité), sans inonder le réseau.
class AudioPacer {
  AudioPacer({this.leadMs = 1200, this.lateToleranceMs = 300, int? prerollMs})
    : prerollMs = prerollMs ?? leadMs ~/ 2;

  final int leadMs;
  final int lateToleranceMs;

  /// En pause, on pré-envoie ce qui suit la position (l'invité a déjà le
  /// son à la reprise, sans rattrapage au démarrage).
  final int prerollMs;

  /// Position (ms, alignée sur 20 ms) où redémarrer le décodage.
  int restartPositionMs = 0;

  /// [nextFrameMs] : position de la prochaine trame décodée (null = aucun
  /// flux en cours). [expectedMs] : position attendue maintenant.
  PacerAction decide({
    required int? nextFrameMs,
    required int expectedMs,
    required bool playing,
  }) {
    if (nextFrameMs == null) {
      restartPositionMs = alignDown(expectedMs);
      return PacerAction.restart;
    }
    // Retard (seek en avant, décodage trop lent) ou seek en arrière.
    if (nextFrameMs < expectedMs - lateToleranceMs ||
        nextFrameMs > expectedMs + leadMs + 2 * lateToleranceMs) {
      restartPositionMs = alignDown(expectedMs);
      return PacerAction.restart;
    }
    if (!playing) {
      return nextFrameMs <= expectedMs + prerollMs
          ? PacerAction.send
          : PacerAction.wait;
    }
    return nextFrameMs <= expectedMs + leadMs
        ? PacerAction.send
        : PacerAction.wait;
  }

  static int alignDown(int ms) =>
      ms <= 0 ? 0 : (ms ~/ kAudioFrameMs) * kAudioFrameMs;
}
