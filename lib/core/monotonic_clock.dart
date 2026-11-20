/// Horloge locale monotone (insensible aux changements d'heure système).
///
/// La valeur absolue n'a pas d'importance : seule la différence avec
/// l'horloge de l'hôte est estimée par [ClockSync].
class MonotonicClock {
  MonotonicClock() : _base = DateTime.now().millisecondsSinceEpoch {
    _sw.start();
  }

  final int _base;
  final Stopwatch _sw = Stopwatch();

  /// Temps local courant, en millisecondes.
  int nowMs() => _base + _sw.elapsedMilliseconds;
}

/// Source de « temps hôte » utilisée par la synchro.
abstract interface class SharedClock {
  /// Temps courant exprimé dans l'horloge de l'hôte (ms).
  int hostNowMs();
}
