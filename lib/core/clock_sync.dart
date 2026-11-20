import 'constants.dart';
import 'monotonic_clock.dart';

/// Un échange ping/pong réduit à (offset, rtt).
class ClockSample {
  const ClockSample(this.offsetMs, this.rttMs);

  /// Estimation de `horlogeHôte - horlogeLocale`.
  final int offsetMs;

  /// Aller-retour réseau, hors temps de traitement de l'hôte.
  final int rttMs;

  @override
  String toString() => 'ClockSample(offset: $offsetMs, rtt: $rttMs)';
}

/// Synchro d'horloge façon NTP.
///
/// Pour chaque échange :
/// - `t0` : envoi du ping (horloge invité)
/// - `t1` : réception du ping (horloge hôte)
/// - `t2` : envoi du pong (horloge hôte)
/// - `t3` : réception du pong (horloge invité)
///
/// offset = ((t1 - t0) + (t2 - t3)) / 2, rtt = (t3 - t0) - (t2 - t1).
/// L'offset retenu est la **médiane** des [windowSize] derniers échantillons,
/// ce qui élimine les pics de latence Wi-Fi.
class ClockSync {
  ClockSync({this.windowSize = kClockWindow})
    : assert(windowSize > 0, 'windowSize doit être > 0');

  final int windowSize;
  final List<ClockSample> _samples = <ClockSample>[];

  List<ClockSample> get samples => List.unmodifiable(_samples);

  /// Vrai dès que la fenêtre de médiane est pleine.
  bool get isConverged => _samples.length >= windowSize;

  bool get hasSamples => _samples.isNotEmpty;

  /// Offset médian (0 tant qu'aucun échantillon).
  int get offsetMs => _median(_samples.map((s) => s.offsetMs));

  /// RTT médian (null tant qu'aucun échantillon).
  int? get rttMs => hasSamples ? _median(_samples.map((s) => s.rttMs)) : null;

  /// Calcule un échantillon à partir des 4 horodatages et l'ajoute.
  ClockSample addExchange({
    required int t0,
    required int t1,
    required int t2,
    required int t3,
  }) {
    final offset = (((t1 - t0) + (t2 - t3)) / 2).round();
    var rtt = (t3 - t0) - (t2 - t1);
    if (rtt < 0) rtt = 0; // horodatages incohérents : on borne.
    final sample = ClockSample(offset, rtt);
    addSample(sample);
    return sample;
  }

  void addSample(ClockSample sample) {
    _samples.add(sample);
    if (_samples.length > windowSize) _samples.removeAt(0);
  }

  int toHost(int localMs) => localMs + offsetMs;

  int toLocal(int hostMs) => hostMs - offsetMs;

  void reset() => _samples.clear();

  static int _median(Iterable<int> values) {
    final list = values.toList()..sort();
    if (list.isEmpty) return 0;
    final mid = list.length ~/ 2;
    if (list.length.isOdd) return list[mid];
    return ((list[mid - 1] + list[mid]) / 2).round();
  }
}

/// Horloge de l'hôte : c'est la référence, offset nul.
class HostSharedClock implements SharedClock {
  HostSharedClock(this.local);

  final MonotonicClock local;

  @override
  int hostNowMs() => local.nowMs();
}

/// Horloge de l'invité : temps local corrigé par l'offset estimé.
class GuestSharedClock implements SharedClock {
  GuestSharedClock(this.local, this.sync);

  final MonotonicClock local;
  final ClockSync sync;

  @override
  int hostNowMs() => sync.toHost(local.nowMs());
}
