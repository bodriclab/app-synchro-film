/// Logique pure du remux FFmpeg du mode 4 (aucun réencodage vidéo).
library;

/// Conteneurs lus nativement par les navigateurs (pas de remux).
const Set<String> kBrowserContainers = {
  'mp4',
  'm4v',
  'webm',
  'mov',
  'mp3',
  'm4a',
  'aac',
  'ogg',
  'oga',
  'opus',
  'wav',
  'flac',
};

/// Codecs audio lus par les navigateurs dans du MP4 ; les autres (AC3, DTS,
/// TrueHD…) sont convertis en AAC — audio seulement, coût CPU faible.
const Set<String> kBrowserAudioCodecs = {'aac', 'mp3', 'opus', 'flac'};

String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// Le conteneur doit-il être réemballé pour un navigateur ?
bool needsRemux(String name) => !kBrowserContainers.contains(extensionOf(name));

/// Résultat de la sonde (premier paquet après le point de départ).
class RemuxProbe {
  const RemuxProbe({required this.offsetMs, this.videoCodec, this.audioCodec});

  /// Position dans le film correspondant au temps 0 du flux réemballé
  /// (keyframe précédant le point demandé).
  final int offsetMs;
  final String? videoCodec;
  final String? audioCodec;

  bool get transcodeAudio =>
      audioCodec != null && !kBrowserAudioCodecs.contains(audioCodec);

  Map<String, dynamic> toJson() => {
    'offsetMs': offsetMs,
    'videoCodec': videoCodec,
    'audioCodec': audioCodec,
    'transcodeAudio': transcodeAudio,
  };
}

String _sec(int ms) => (ms / 1000).toStringAsFixed(3);

/// Sonde : copie le premier paquet vidéo en gardant les horodatages
/// d'origine (`-copyts`) au format texte `framecrc`.
List<String> probeArgs(String input, int startMs) => [
  if (startMs > 0) ...['-ss', _sec(startMs)],
  '-copyts',
  '-i',
  input,
  '-map',
  '0:v:0?',
  '-map',
  '0:a:0?',
  '-c',
  'copy',
  '-frames:v',
  '1',
  '-frames:a',
  '3',
  '-f',
  'framecrc',
  '{out}',
];

/// Remux en MP4 fragmenté lisible en progressif par un navigateur.
List<String> remuxArgs(
  String input,
  int startMs, {
  bool transcodeAudio = false,
}) => [
  if (startMs > 0) ...['-ss', _sec(startMs)],
  '-i',
  input,
  '-map',
  '0:v:0?',
  '-map',
  '0:a:0?',
  '-sn',
  '-dn',
  '-c:v',
  'copy',
  if (transcodeAudio) ...[
    '-c:a',
    'aac',
    '-b:a',
    '192k',
    '-ac',
    '2',
  ] else ...[
    '-c:a',
    'copy',
  ],
  '-movflags',
  'frag_keyframe+empty_moov+default_base_moof',
  '-f',
  'mp4',
  '{out}',
];

/// Décodage audio du mode 3 : PCM s16le 48 kHz stéréo à partir de [startMs].
List<String> pcmArgs(String input, int startMs) => [
  if (startMs > 0) ...['-ss', _sec(startMs)],
  '-i',
  input,
  '-vn',
  '-sn',
  '-dn',
  '-map',
  '0:a:0',
  '-ac',
  '2',
  '-ar',
  '48000',
  '-f',
  's16le',
  '{out}',
];

/// Analyse la sortie `framecrc` de [probeArgs].
RemuxProbe parseFramecrc(String text) {
  final codecs = <int, String>{};
  final types = <int, String>{};
  final tbs = <int, (int, int)>{};
  int? minDtsMs;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      final m = RegExp(r'^#(\w+) (\d+): (.+)$').firstMatch(line);
      if (m == null) continue;
      final idx = int.parse(m.group(2)!);
      final v = m.group(3)!.trim();
      switch (m.group(1)) {
        case 'codec_id':
          codecs[idx] = v;
        case 'media_type':
          types[idx] = v;
        case 'tb':
          final p = v.split('/');
          tbs[idx] = (int.parse(p[0]), int.parse(p[1]));
      }
      continue;
    }
    final f = line.split(',').map((s) => s.trim()).toList();
    if (f.length < 3) continue;
    final idx = int.tryParse(f[0]);
    final dts = int.tryParse(f[1]);
    if (idx == null || dts == null) continue;
    final tb = tbs[idx] ?? (1, 1000);
    final ms = (dts * tb.$1 * 1000 / tb.$2).round();
    if (minDtsMs == null || ms < minDtsMs) minDtsMs = ms;
  }
  String? codecOf(String type) {
    for (final e in types.entries) {
      if (e.value == type) return codecs[e.key];
    }
    return null;
  }

  return RemuxProbe(
    offsetMs: minDtsMs == null || minDtsMs < 0 ? 0 : minDtsMs,
    videoCodec: codecOf('video'),
    audioCodec: codecOf('audio'),
  );
}
