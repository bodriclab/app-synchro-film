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
    expect(r.sublist(0, 3), ['-noaccurate_seek', '-ss', '30.000']);
    expect(r, containsAllInOrder(['-c:v', 'copy', '-c:a', 'copy']));
    expect(r, contains('frag_keyframe+empty_moov+default_base_moof'));
    expect(r.last, '{out}');
    expect(
      remuxArgs('in.mkv', 0, transcodeAudio: true),
      containsAllInOrder(['-c:a', 'aac']),
    );
    expect(remuxArgs('in.mkv', 0).first, '-i');
    expect(
      remuxArgs('in.mkv', 0, hevc: true),
      containsAllInOrder(['-c:v', 'copy', '-tag:v', 'hvc1']),
    );
    expect(remuxArgs('in.mkv', 0), isNot(contains('-tag:v')));
    expect(
      remuxArgs('in.mkv', 0, transcodeAudio: true),
      containsAllInOrder(['-af', kDownmixFilter, '-c:a', 'aac']),
    );
    expect(pcmArgs('in.mkv', 0), containsAllInOrder(['-af', kDownmixFilter]));
    expect(
      probeArgs('in.mkv', 1500),
      containsAllInOrder(['-ss', '1.500', '-copyts']),
    );
    expect(
      pcmArgs('in.mkv', 20),
      containsAllInOrder(['-ar', '48000', '-f', 's16le']),
    );
  });

  group('iosCopyArgs', () {
    const input = '/films/a.mkv';
    const output = '/tmp/a_ios.mp4';

    test('sans hevc : vérifie la séquence attendue et l\'absence de hvc1', () {
      final args = iosCopyArgs(input, output, hevc: false);

      // '-c:v' suivi de 'copy'
      final cVIndex = args.indexOf('-c:v');
      expect(cVIndex, isNot(-1));
      expect(args[cVIndex + 1], equals('copy'));

      // aucune occurrence de 'hvc1'
      expect(args.contains('hvc1'), isFalse);

      // '-c:a' suivi de 'aac'
      final cAIndex = args.indexOf('-c:a');
      expect(cAIndex, isNot(-1));
      expect(args[cAIndex + 1], equals('aac'));

      // '-b:a' suivi de '192k'
      final bAIndex = args.indexOf('-b:a');
      expect(bAIndex, isNot(-1));
      expect(args[bAIndex + 1], equals('192k'));

      // '-ac' suivi de '2'
      final acIndex = args.indexOf('-ac');
      expect(acIndex, isNot(-1));
      expect(args[acIndex + 1], equals('2'));

      // '-movflags' suivi de '+faststart'
      final movFlagsIndex = args.indexOf('-movflags');
      expect(movFlagsIndex, isNot(-1));
      expect(args[movFlagsIndex + 1], equals('+faststart'));

      // '-map' suivi de '0:v:0'
      final mapIndex = args.indexOf('-map');
      expect(mapIndex, isNot(-1));
      expect(args[mapIndex + 1], equals('0:v:0'));

      // le dernier argument est le chemin de sortie
      expect(args.last, equals(output));
    });

    test('avec hevc : -tag:v suivi de hvc1 et placé après -c:v', () {
      final args = iosCopyArgs(input, output, hevc: true);

      // '-tag:v' suivi de 'hvc1'
      final tagVIndex = args.indexOf('-tag:v');
      expect(tagVIndex, isNot(-1));
      expect(args[tagVIndex + 1], equals('hvc1'));

      // '-c:v' doit apparaître avant '-tag:v'
      final cVIndex = args.indexOf('-c:v');
      expect(cVIndex, isNot(-1));
      expect(cVIndex < tagVIndex, isTrue);
    });

    test('l\'entrée est correctement placée après -i', () {
      final args = iosCopyArgs(input, output, hevc: false);

      final iIndex = args.indexOf('-i');
      expect(iIndex, isNot(-1));
      expect(args[iIndex + 1], equals(input));
    });
  });
}
