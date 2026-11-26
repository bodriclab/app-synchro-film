/// Choix de sous-titres partagé par l'hôte (protocole `subs`).
library;

enum SubtitleKind { off, embedded, external }

/// Codecs de sous-titres « image » : non convertibles en WebVTT et non
/// affichés par le lecteur de l'app (rendu texte uniquement).
const Set<String> kBitmapSubtitleCodecs = {
  'hdmv_pgs_subtitle',
  'pgssub',
  'dvd_subtitle',
  'dvdsub',
  'dvb_subtitle',
  'dvbsub',
  'xsub',
};

bool isBitmapSubtitleCodec(String? codec) =>
    codec != null && kBitmapSubtitleCodecs.contains(codec.toLowerCase());

/// Extensions acceptées pour un fichier de sous-titres externe.
const Set<String> kSubtitleExtensions = {'srt', 'ass', 'ssa', 'vtt'};

class SubtitleSelection {
  const SubtitleSelection._(
    this.kind, {
    this.index,
    this.title,
    this.language,
    this.codec,
    this.name,
  });

  const SubtitleSelection.off() : this._(SubtitleKind.off);

  /// Piste intégrée n° [index] (0 = première piste de sous-titres du
  /// fichier, comme `0:s:0` pour FFmpeg).
  const SubtitleSelection.embedded(
    int index, {
    String? title,
    String? language,
    String? codec,
  }) : this._(
         SubtitleKind.embedded,
         index: index,
         title: title,
         language: language,
         codec: codec,
       );

  /// Fichier externe choisi par l'utilisateur (nom affiché).
  const SubtitleSelection.external(String name)
    : this._(SubtitleKind.external, name: name);

  final SubtitleKind kind;
  final int? index;
  final String? title;
  final String? language;
  final String? codec;
  final String? name;

  bool get isOff => kind == SubtitleKind.off;
  bool get isBitmap => isBitmapSubtitleCodec(codec);

  /// Libellé lisible : « Français (subrip) », « Piste 2 », nom du fichier.
  String get label => switch (kind) {
    SubtitleKind.off => 'Désactivés',
    SubtitleKind.external => name ?? 'Fichier externe',
    SubtitleKind.embedded => [
      if (title != null && title!.isNotEmpty) title!,
      if (language != null && language!.isNotEmpty) '[${language!}]',
      if ((title ?? '').isEmpty && (language ?? '').isEmpty)
        'Piste ${index! + 1}',
      if (isBitmap) '(image)',
    ].join(' '),
  };

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    if (index != null) 'index': index,
    if (title != null) 'title': title,
    if (language != null) 'language': language,
    if (codec != null) 'codec': codec,
    if (name != null) 'name': name,
  };

  factory SubtitleSelection.fromJson(Map<String, dynamic> j) =>
      switch (SubtitleKind.values.byName(j['kind'] as String)) {
        SubtitleKind.off => const SubtitleSelection.off(),
        SubtitleKind.embedded => SubtitleSelection.embedded(
          (j['index'] as num).toInt(),
          title: j['title'] as String?,
          language: j['language'] as String?,
          codec: j['codec'] as String?,
        ),
        SubtitleKind.external => SubtitleSelection.external(
          j['name'] as String? ?? 'sous-titres',
        ),
      };

  @override
  bool operator ==(Object other) =>
      other is SubtitleSelection &&
      other.kind == kind &&
      other.index == index &&
      other.name == name;

  @override
  int get hashCode => Object.hash(kind, index, name);
}

/// FFmpeg : extrait la piste intégrée [index] en WebVTT.
List<String> embeddedVttArgs(String input, int index) => [
  '-i',
  input,
  '-map',
  '0:s:$index',
  '-f',
  'webvtt',
  '{out}',
];

/// FFmpeg : convertit un fichier ASS/SSA (ou SRT) en WebVTT.
List<String> fileVttArgs(String path) => ['-i', path, '-f', 'webvtt', '{out}'];
