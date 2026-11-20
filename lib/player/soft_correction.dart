/// Type d'action décidée par la correction douce.
enum CorrectionKind {
  /// Rien à faire (le lecteur garde / retrouve la vitesse nominale).
  none,

  /// Ajuster la vitesse de lecture à [Correction.rate].
  rate,

  /// Sauter directement à [Correction.seekToMs].
  seek,
}

class Correction {
  const Correction.none(this.rate)
    : kind = CorrectionKind.none,
      seekToMs = null;
  const Correction.rate(this.rate)
    : kind = CorrectionKind.rate,
      seekToMs = null;
  const Correction.seek(int this.seekToMs, this.rate)
    : kind = CorrectionKind.seek;

  final CorrectionKind kind;

  /// Vitesse à appliquer au lecteur après cette décision.
  final double rate;

  final int? seekToMs;

  @override
  String toString() => switch (kind) {
    CorrectionKind.none => 'Correction.none(rate: $rate)',
    CorrectionKind.rate => 'Correction.rate($rate)',
    CorrectionKind.seek => 'Correction.seek($seekToMs)',
  };
}

/// Correction douce de l'écart de lecture (cf. docs/ARCHITECTURE.md §4) :
/// - |écart| < 40 ms : rien ;
/// - 40 ms – 1 s : vitesse ±2 % jusqu'à résorption ;
/// - > 1 s : seek direct.
///
/// Une hystérésis évite les oscillations : une fois la correction de
/// vitesse engagée, elle continue jusqu'à |écart| ≤ [releaseMs].
/// Après un seek, aucune correction pendant [seekCooldownMs] (le temps
/// que le lecteur se repositionne et rapporte une position fiable).
class SoftCorrector {
  SoftCorrector({
    this.deadbandMs = 40,
    this.seekThresholdMs = 1000,
    this.rateDelta = 0.02,
    this.releaseMs = 15,
    this.seekCooldownMs = 1500,
  }) : assert(releaseMs <= deadbandMs && deadbandMs < seekThresholdMs);

  final int deadbandMs;
  final int seekThresholdMs;
  final double rateDelta;
  final int releaseMs;
  final int seekCooldownMs;

  bool _correcting = false;
  int? _lastSeekAtMs;

  bool get isCorrecting => _correcting;

  /// [driftMs] = position locale - position attendue
  /// (positif : en avance → ralentir ; négatif : en retard → accélérer).
  /// [nowMs] : horloge locale monotone (pour le délai après seek).
  Correction update({
    required int driftMs,
    required int targetPositionMs,
    required bool playing,
    required int nowMs,
    double baseRate = 1.0,
  }) {
    final abs = driftMs.abs();

    if (_lastSeekAtMs != null && nowMs - _lastSeekAtMs! < seekCooldownMs) {
      return Correction.none(baseRate);
    }

    if (!playing) {
      // En pause : on se cale exactement, sans jouer sur la vitesse.
      _correcting = false;
      if (abs >= deadbandMs) return _seek(targetPositionMs, nowMs, baseRate);
      return Correction.none(baseRate);
    }

    if (abs > seekThresholdMs) return _seek(targetPositionMs, nowMs, baseRate);

    if (_correcting) {
      if (abs <= releaseMs) {
        _correcting = false;
        return Correction.none(baseRate);
      }
      return Correction.rate(_rateFor(driftMs, baseRate));
    }

    if (abs >= deadbandMs) {
      _correcting = true;
      return Correction.rate(_rateFor(driftMs, baseRate));
    }
    return Correction.none(baseRate);
  }

  void reset() {
    _correcting = false;
    _lastSeekAtMs = null;
  }

  Correction _seek(int target, int nowMs, double baseRate) {
    _correcting = false;
    _lastSeekAtMs = nowMs;
    return Correction.seek(target, baseRate);
  }

  double _rateFor(int driftMs, double baseRate) =>
      driftMs > 0 ? baseRate * (1 - rateDelta) : baseRate * (1 + rateDelta);
}
