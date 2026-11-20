/// Abstraction minimale d'un lecteur, pour découpler la logique de synchro
/// de media_kit (et la tester en Dart pur avec un faux lecteur).
abstract interface class PlaybackEngine {
  /// Ouvre un média : chemin local (mode 1) ou URL HTTP (mode 2).
  Future<void> open(String source);

  Future<void> play();

  Future<void> pause();

  Future<void> seek(int positionMs);

  /// Vitesse de lecture locale (utilisée par la correction douce).
  Future<void> setRate(double rate);

  int get positionMs;

  bool get isPlaying;

  double get rate;

  /// Durée connue du média, null tant qu'elle n'est pas connue.
  int? get durationMs;

  /// Vrai pendant une mise en mémoire tampon (la correction est suspendue).
  bool get isBuffering;

  Future<void> dispose();
}
