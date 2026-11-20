/// État de lecture de référence, diffusé par l'hôte (message `state`).
///
/// La position est ancrée sur l'horloge de l'hôte : à l'instant [atHostMs],
/// la lecture était à [positionMs]. Chaque pair en déduit la position
/// attendue à tout instant via [positionAt].
class PlaybackState {
  const PlaybackState({
    required this.playing,
    required this.positionMs,
    required this.atHostMs,
    this.rate = 1.0,
    this.seq = 0,
  });

  const PlaybackState.initial()
    : playing = false,
      positionMs = 0,
      atHostMs = 0,
      rate = 1.0,
      seq = 0;

  final bool playing;
  final int positionMs;
  final int atHostMs;

  /// Vitesse nominale (1.0). La correction douce ne la modifie jamais :
  /// elle ajuste seulement la vitesse locale de chaque lecteur.
  final double rate;

  /// Numéro de séquence croissant, incrémenté à chaque changement.
  final int seq;

  /// Position attendue à l'instant [hostNowMs] (horloge hôte).
  int positionAt(int hostNowMs, {int? durationMs}) {
    var pos = playing
        ? positionMs + ((hostNowMs - atHostMs) * rate).round()
        : positionMs;
    if (pos < 0) pos = 0;
    if (durationMs != null && durationMs > 0 && pos > durationMs) {
      pos = durationMs;
    }
    return pos;
  }

  PlaybackState copyWith({
    bool? playing,
    int? positionMs,
    int? atHostMs,
    double? rate,
    int? seq,
  }) => PlaybackState(
    playing: playing ?? this.playing,
    positionMs: positionMs ?? this.positionMs,
    atHostMs: atHostMs ?? this.atHostMs,
    rate: rate ?? this.rate,
    seq: seq ?? this.seq,
  );

  Map<String, dynamic> toJson() => {
    'playing': playing,
    'position': positionMs,
    'rate': rate,
    'at': atHostMs,
    'seq': seq,
  };

  static PlaybackState fromJson(Map<String, dynamic> json) => PlaybackState(
    playing: json['playing'] as bool,
    positionMs: (json['position'] as num).round(),
    rate: (json['rate'] as num?)?.toDouble() ?? 1.0,
    atHostMs: (json['at'] as num).round(),
    seq: (json['seq'] as num?)?.toInt() ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is PlaybackState &&
      other.playing == playing &&
      other.positionMs == positionMs &&
      other.atHostMs == atHostMs &&
      other.rate == rate &&
      other.seq == seq;

  @override
  int get hashCode => Object.hash(playing, positionMs, atHostMs, rate, seq);

  @override
  String toString() =>
      'PlaybackState(${playing ? '▶' : '⏸'} $positionMs ms @ $atHostMs, '
      'rate $rate, seq $seq)';
}
