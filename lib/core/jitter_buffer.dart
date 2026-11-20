import 'audio_packet.dart';

/// Buffer de gigue du mode 3 (côté invité).
///
/// Les paquets sont rangés par index de trame (position / 20 ms) : l'ordre
/// d'arrivée et la gigue réseau n'ont donc aucune importance tant que la
/// trame arrive avant son heure de lecture. L'hôte envoie avec ~1 s
/// d'avance, ce qui absorbe largement la gigue Wi-Fi.
class JitterBuffer {
  JitterBuffer({this.capacityFrames = 250});

  /// Nombre max de trames gardées (250 × 20 ms = 5 s).
  final int capacityFrames;

  final Map<int, AudioPacket> _frames = {};
  int? _epoch;

  int received = 0;
  int duplicates = 0;
  int late = 0;
  int stale = 0;
  int missing = 0;

  int? get epoch => _epoch;
  int get length => _frames.length;
  bool contains(int index) => _frames.containsKey(index);

  /// Plus petit / plus grand index présent.
  int? get firstIndex =>
      _frames.isEmpty ? null : _frames.keys.reduce((a, b) => a < b ? a : b);
  int? get lastIndex =>
      _frames.isEmpty ? null : _frames.keys.reduce((a, b) => a > b ? a : b);

  /// Ajoute un paquet. [playedUpTo] = dernier index déjà joué (les paquets
  /// plus anciens sont en retard et ignorés). Retourne vrai si conservé.
  bool add(AudioPacket p, {int? playedUpTo}) {
    received++;
    final e = _epoch;
    if (e == null || AudioPacket.isNewerEpoch(p.epoch, e)) {
      _epoch = p.epoch;
      _frames.clear();
    } else if (p.epoch != e) {
      stale++;
      return false;
    }
    final i = p.frameIndex;
    if (playedUpTo != null && i <= playedUpTo) {
      late++;
      return false;
    }
    if (_frames.containsKey(i)) {
      duplicates++;
      return false;
    }
    _frames[i] = p;
    if (_frames.length > capacityFrames) {
      _frames.remove(firstIndex);
    }
    return true;
  }

  /// Retire et retourne la trame [index] (null si absente → perte).
  AudioPacket? take(int index) {
    final p = _frames.remove(index);
    if (p == null) missing++;
    return p;
  }

  /// Supprime les trames d'index < [index].
  void dropBefore(int index) => _frames.removeWhere((k, _) => k < index);

  void clear() {
    _frames.clear();
    _epoch = null;
  }
}
