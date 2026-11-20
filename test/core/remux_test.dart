import 'package:app_synchro_film/core/remux.dart';
import 'package:flutter_test/flutter_test.dart';

const sample = '''
#extradata 0:       46, 0x34b10f92
#software: Lavf61.7.103
#tb 0: 1/1000
#media_type 0: video
#codec_id 0: h264
#dimensions 0: 320x240
#sar 0: 1/1
#tb 1: 1/48000
#media_type 1: audio
#codec_id 1: ac3
#sample_rate 1: 48000
#channel_layout_name 1: 5.1(side)
0,      27920,      28000,       40,     5870, 0xe4d064d3
1,    1340400,    1340400,     1536,      169, 0xcbcb5860
1,    1341936,    1341936,     1536,      196, 0x4c556d22
''';

void main() {
  test('conteneurs lisibles ou à réemballer', () {
    expect(needsRemux('film.mp4'), isFalse);
    expect(needsRemux('Film.WEBM'), isFalse);
    expect(needsRemux('film.mkv'), isTrue);
    expect(needsRemux('film.avi'), isTrue);
    expect(needsRemux('sans_extension'), isTrue);
  });

  test('analyse framecrc : offset = plus petit dts, codecs', () {
    final p = parseFramecrc(sample);
    expect(
      p.offsetMs,
      27920,
    ); // min(vidéo 27920 ms, audio 1340400/48000 s = 27925 ms)
    expect(p.videoCodec, 'h264');
    expect(p.audioCodec, 'ac3');
    expect(p.transcodeAudio, isTrue);
  });

  test('audio AAC : copie sans réencodage', () {
    final p = parseFramecrc(
      sample.replaceAll('codec_id 1: ac3', 'codec_id 1: aac'),
    );
    expect(p.transcodeAudio, isFalse);
    expect(parseFramecrc('').offsetMs, 0);
  });

  test('arguments FFmpeg', () {
    final r = remuxArgs('in.mkv', 30000);
    expect(r.sublist(0, 2), ['-ss', '30.000']);
    expect(r, containsAllInOrder(['-c:v', 'copy', '-c:a', 'copy']));
    expect(r, contains('frag_keyframe+empty_moov+default_base_moof'));
    expect(r.last, '{out}');
    expect(
      remuxArgs('in.mkv', 0, transcodeAudio: true),
      containsAllInOrder(['-c:a', 'aac']),
    );
    expect(remuxArgs('in.mkv', 0).first, '-i');
    expect(
      probeArgs('in.mkv', 1500),
      containsAllInOrder(['-ss', '1.500', '-copyts']),
    );
    expect(
      pcmArgs('in.mkv', 20),
      containsAllInOrder(['-ar', '48000', '-f', 's16le']),
    );
  });
}
