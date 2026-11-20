import 'dart:typed_data';

import 'package:app_synchro_film/core/audio_pacer.dart';
import 'package:app_synchro_film/core/audio_packet.dart';
import 'package:app_synchro_film/core/audio_scheduler.dart';
import 'package:app_synchro_film/core/jitter_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

AudioPacket pkt(int pos, {int epoch = 1, int seq = 0}) => AudioPacket(
  epoch: epoch,
  seq: seq,
  positionMs: pos,
  payload: Uint8List.fromList([pos & 0xff, 1, 2]),
);

void main() {
  group('AudioPacket', () {
    test('aller-retour binaire', () {
      final p = AudioPacket(
        epoch: 65535,
        seq: 4000000000,
        positionMs: 7200000,
        flags: 3,
        payload: Uint8List.fromList(List.generate(200, (i) => i)),
      );
      final bytes = p.encode();
      expect(bytes.length, AudioPacket.headerSize + 200);
      final back = AudioPacket.decode(bytes)!;
      expect(back.epoch, 65535);
      expect(back.seq, 4000000000);
      expect(back.positionMs, 7200000);
      expect(back.flags, 3);
      expect(back.payload, p.payload);
      expect(back.frameIndex, 360000);
    });

    test('datagrammes invalides rejetés', () {
      expect(AudioPacket.decode(Uint8List(5)), isNull);
      final bad = pkt(0).encode()..[0] = 0;
      expect(AudioPacket.decode(bad), isNull);
      final v2 = pkt(0).encode()..[2] = 9;
      expect(AudioPacket.decode(v2), isNull);
    });

    test('comparaison d\'epoch avec rebouclage 16 bits', () {
      expect(AudioPacket.isNewerEpoch(2, 1), isTrue);
      expect(AudioPacket.isNewerEpoch(1, 2), isFalse);
      expect(AudioPacket.isNewerEpoch(0, 65535), isTrue);
      expect(AudioPacket.isNewerEpoch(5, 5), isFalse);
    });

    test('constantes : 20 ms à 48 kHz stéréo', () {
      expect(kAudioSamplesPerFrame, 960);
      expect(kAudioFrameBytes, 3840);
    });
  });

  group('JitterBuffer', () {
    test('désordre et doublons', () {
      final b = JitterBuffer();
      for (final pos in [40, 0, 20, 20, 60]) {
        b.add(pkt(pos));
      }
      expect(b.length, 4);
      expect(b.duplicates, 1);
      expect(b.firstIndex, 0);
      expect(b.lastIndex, 3);
      expect(b.take(0)!.positionMs, 0);
      expect(b.take(1)!.positionMs, 20);
      expect(b.take(1), isNull);
      expect(b.missing, 1);
    });

    test('paquets en retard ignorés', () {
      final b = JitterBuffer();
      expect(b.add(pkt(100), playedUpTo: 5), isFalse);
      expect(b.late, 1);
      expect(b.add(pkt(120), playedUpTo: 5), isTrue);
    });

    test('nouvel epoch : buffer vidé ; ancien epoch ignoré', () {
      final b = JitterBuffer()
        ..add(pkt(0))
        ..add(pkt(20));
      b.add(pkt(10000, epoch: 2));
      expect(b.epoch, 2);
      expect(b.length, 1);
      expect(b.add(pkt(40, epoch: 1)), isFalse);
      expect(b.stale, 1);
    });

    test('capacité bornée et purge', () {
      final b = JitterBuffer(capacityFrames: 3);
      for (var i = 0; i < 5; i++) {
        b.add(pkt(i * 20));
      }
      expect(b.length, 3);
      expect(b.firstIndex, 2);
      b.dropBefore(4);
      expect(b.length, 1);
    });
  });

  group('AudioPlayoutScheduler', () {
    // Timeline : lecture depuis 0 à l'instant local 1000.
    int? playing(int local) => local - 1000;

    test('lecture continue : trames successives, file de 80 ms', () {
      final s = AudioPlayoutScheduler();
      final first = s.plan(
        nowMs: 1000,
        expectedPositionAt: playing,
        outputLatencyMs: 0,
      );
      expect(first, [0, 1, 2, 3]);
      expect(
        s.plan(nowMs: 1010, expectedPositionAt: playing, outputLatencyMs: 0),
        [4],
      );
      expect(
        s.plan(nowMs: 1020, expectedPositionAt: playing, outputLatencyMs: 0),
        isEmpty,
      );
      final all = <int>[...first, 4];
      for (var t = 1030; t < 2000; t += 10) {
        all.addAll(
          s.plan(nowMs: t, expectedPositionAt: playing, outputLatencyMs: 0),
        );
      }
      for (var i = 1; i < all.length; i++) {
        expect(all[i], all[i - 1] + 1);
      }
      expect(s.resyncs, 0);
    });

    test('latence de sortie compensée : on joue en avance de la latence', () {
      final s = AudioPlayoutScheduler();
      final plan = s.plan(
        nowMs: 1000,
        expectedPositionAt: playing,
        outputLatencyMs: 200,
      );
      // Poussée à 1000 → entendue à 1200 → position 200 ms → trame 10.
      expect(plan.first, 10);
    });

    test('saut de timeline (seek) → resynchronisation', () {
      final s = AudioPlayoutScheduler();
      var offset = 0;
      int? timeline(int local) => local - 1000 + offset;
      s.plan(nowMs: 1000, expectedPositionAt: timeline, outputLatencyMs: 0);
      offset = 60000;
      final plan = s.plan(
        nowMs: 1020,
        expectedPositionAt: timeline,
        outputLatencyMs: 0,
      );
      expect(plan.single, 3004); // (1080 - 1000 + 60000) / 20
      expect(s.resyncs, 1);
    });

    test('petit écart < 40 ms : pas de saut audible', () {
      final s = AudioPlayoutScheduler();
      var offset = 0;
      int? timeline(int local) => local - 1000 + offset;
      s.plan(nowMs: 1000, expectedPositionAt: timeline, outputLatencyMs: 0);
      offset = 30;
      expect(
        s
            .plan(nowMs: 1020, expectedPositionAt: timeline, outputLatencyMs: 0)
            .single,
        4,
      );
      expect(s.resyncs, 0);
    });

    test('pause : rien n\'est poussé ; reprise depuis maintenant', () {
      final s = AudioPlayoutScheduler();
      s.plan(nowMs: 1000, expectedPositionAt: playing, outputLatencyMs: 0);
      expect(
        s.plan(
          nowMs: 1020,
          expectedPositionAt: (_) => null,
          outputLatencyMs: 0,
        ),
        isEmpty,
      );
      expect(s.queueEndsAt, isNull);
      final again = s.plan(
        nowMs: 5000,
        expectedPositionAt: playing,
        outputLatencyMs: 0,
      );
      expect(again.first, 200);
    });

    test('famine (underrun) : la file repart de maintenant', () {
      final s = AudioPlayoutScheduler();
      s.plan(nowMs: 1000, expectedPositionAt: playing, outputLatencyMs: 0);
      final late = s.plan(
        nowMs: 3000,
        expectedPositionAt: playing,
        outputLatencyMs: 0,
      );
      expect(late.first, 100);
      expect(late, hasLength(4));
    });
  });

  group('AudioPacer', () {
    test('démarrage : restart aligné sur 20 ms', () {
      final p = AudioPacer();
      expect(
        p.decide(nextFrameMs: null, expectedMs: 12345, playing: true),
        PacerAction.restart,
      );
      expect(p.restartPositionMs, 12340);
    });

    test('envoie jusqu\'à lead ms d\'avance, puis attend', () {
      final p = AudioPacer(leadMs: 1000);
      expect(
        p.decide(nextFrameMs: 5000, expectedMs: 5000, playing: true),
        PacerAction.send,
      );
      expect(
        p.decide(nextFrameMs: 6000, expectedMs: 5000, playing: true),
        PacerAction.send,
      );
      expect(
        p.decide(nextFrameMs: 6020, expectedMs: 5000, playing: true),
        PacerAction.wait,
      );
    });

    test('pause : attente sans redémarrage', () {
      final p = AudioPacer();
      expect(
        p.decide(nextFrameMs: 5000, expectedMs: 5000, playing: false),
        PacerAction.wait,
      );
    });

    test('seek avant/arrière ou retard : redémarrage', () {
      final p = AudioPacer(leadMs: 1000, lateToleranceMs: 300);
      expect(
        p.decide(nextFrameMs: 5000, expectedMs: 60000, playing: true),
        PacerAction.restart,
      );
      expect(p.restartPositionMs, 60000);
      expect(
        p.decide(nextFrameMs: 60000, expectedMs: 1000, playing: true),
        PacerAction.restart,
      );
      expect(
        p.decide(nextFrameMs: 4600, expectedMs: 5000, playing: true),
        PacerAction.restart,
      );
      expect(
        p.decide(nextFrameMs: 4800, expectedMs: 5000, playing: true),
        PacerAction.send,
      );
    });
  });
}
