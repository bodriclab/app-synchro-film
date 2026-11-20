import 'package:app_synchro_film/core/playback_arbiter.dart';
import 'package:app_synchro_film/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late int now;
  late PlaybackArbiter arbiter;

  setUp(() {
    now = 1000;
    arbiter = PlaybackArbiter(() => now)..durationMs = 60000;
  });

  test('play / pause / seek, la dernière commande gagne', () {
    arbiter.apply(const CmdMsg.play());
    expect(arbiter.state.playing, isTrue);
    now += 2500;
    final paused = arbiter.apply(const CmdMsg.pause());
    expect(paused.playing, isFalse);
    expect(paused.positionMs, 2500);
    final seeked = arbiter.apply(const CmdMsg.seek(30000));
    expect(seeked.positionMs, 30000);
    expect(seeked.playing, isFalse);
    expect(seeked.seq, 3);
  });

  test('seek borné à [0, durée]', () {
    expect(arbiter.apply(const CmdMsg.seek(-50)).positionMs, 0);
    expect(arbiter.apply(const CmdMsg.seek(999999)).positionMs, 60000);
  });

  test('fin de média : pause automatique, play repart du début', () {
    arbiter.apply(const CmdMsg.seek(59000));
    arbiter.apply(const CmdMsg.play());
    now += 500;
    expect(arbiter.checkEnd(), isNull);
    now += 1000;
    final ended = arbiter.checkEnd();
    expect(ended, isNotNull);
    expect(ended!.playing, isFalse);
    expect(ended.positionMs, 60000);
    expect(arbiter.apply(const CmdMsg.play()).positionMs, 0);
  });
}
