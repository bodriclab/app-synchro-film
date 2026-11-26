import 'dart:io';

/// Vrai si l'exécutable `ffmpeg` est disponible (tests d'intégration).
bool get hasFfmpeg {
  try {
    return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Génère un film de test : H.264 (keyframe toutes les 4 s) + audio.
Future<String> makeTestFilm(
  Directory dir, {
  String name = 'film.mkv',
  int seconds = 40,
  String audioCodec = 'aac',
  String videoCodec = 'libx264',
  int channels = 2,
}) async {
  final path = '${dir.path}/$name';
  final r = await Process.run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=160x120:rate=25',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:sample_rate=48000',
    '-t',
    '$seconds',
    '-c:v',
    videoCodec,
    '-preset',
    'ultrafast',
    '-g',
    '100',
    '-keyint_min',
    '100',
    '-sc_threshold',
    '0',
    if (videoCodec == 'libx265') ...['-x265-params', 'log-level=error'],
    '-ac',
    '$channels',
    '-c:a',
    audioCodec,
    '-shortest',
    path,
  ]);
  if (r.exitCode != 0) throw StateError('ffmpeg: ${r.stderr}');
  return path;
}
