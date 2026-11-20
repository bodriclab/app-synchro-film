import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:app_synchro_film/core/media_source.dart';
import 'package:app_synchro_film/core/monotonic_clock.dart';
import 'package:app_synchro_film/core/session_endpoint.dart';
import 'package:app_synchro_film/core/session_mode.dart';
import 'package:app_synchro_film/modes/audio/audio_latency_control.dart';
import 'package:app_synchro_film/modes/audio_only_mode.dart';
import 'package:app_synchro_film/net/session/guest_session.dart';
import 'package:app_synchro_film/net/session/host_session.dart';
import 'package:app_synchro_film/platform/audio/opus_frames.dart';
import 'package:app_synchro_film/platform/audio/output_latency.dart';
import 'package:app_synchro_film/platform/audio/pcm_output.dart';
import 'package:app_synchro_film/platform/ffmpeg_runner.dart';
import 'package:app_synchro_film/player/virtual_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../player/fake_engine.dart';
import '../support/fixtures.dart';

/// Sortie factice : mémorise ce qui est poussé.
class RecordingOutput implements PcmOutput {
  int pushes = 0;
  double sumSquares = 0;
  int samples = 0;

  @override
  void start() {}

  @override
  void push(Float32List s) {
    pushes++;
    for (final v in s) {
      sumSquares += v * v;
    }
    samples += s.length;
  }

  double get rms => samples == 0 ? 0 : math.sqrt(sumSquares / samples);

  @override
  int get underruns => 0;

  @override
  void stop() {}
}

DynamicLibrary? _libopus() {
  try {
    return DynamicLibrary.open('libopus.so.0');
  } catch (_) {
    return null;
  }
}

void main() {
  final lib = _libopus();
  final skip = !hasFfmpeg || lib == null ? 'ffmpeg ou libopus absent' : null;
  late Directory dir;
  late String film;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('audio');
    if (skip == null) film = await makeTestFilm(dir, seconds: 40);
  });
  tearDownAll(() => dir.delete(recursive: true));

  test('LatencyOffsetStore : mémorisé par sortie, borné à ±500 ms', () async {
    final store = LatencyOffsetStore(directory: () async => dir);
    expect(await store.get('bt:casque'), 0);
    await store.set('bt:casque', 180);
    await store.set('speaker:', -900);
    final again = LatencyOffsetStore(directory: () async => dir);
    expect(await again.get('bt:casque'), 180);
    expect(await again.get('speaker:'), -500);
  });

  test('Opus : trame de 20 ms, masquage de perte (PLC) de 20 ms', () async {
    await ensureOpus(library: lib);
    final enc = OpusFrameEncoder();
    final dec = OpusFrameDecoder();
    final pcm = Int16List(960 * 2);
    for (var i = 0; i < 960; i++) {
      pcm[2 * i] = pcm[2 * i + 1] =
          (8000 * math.sin(i * 2 * math.pi * 440 / 48000)).round();
    }
    final packet = enc.encode(pcm);
    expect(packet.length, lessThan(400));
    expect(dec.decode(packet).length, 960 * 2);
    expect(dec.decode(null).length, 960 * 2);
  }, skip: lib == null ? 'libopus absent' : null);

  test(
    'mode 3 : l\'invité joue l\'audio de l\'hôte, calé sur sa timeline',
    () async {
      final output = RecordingOutput();
      const autoLatency = 150;
      final mode = AudioOnlyMode(
        services: AudioServices(
          initCodec: () => ensureOpus(library: lib),
          newOutput: () => output,
          newLatencyControl: () => AudioLatencyControl(
            outputInfo: () async => const AudioOutputInfo(
              id: 'bt:test',
              label: 'Casque test',
              autoLatencyMs: autoLatency,
            ),
            store: LatencyOffsetStore(directory: () async => dir),
          ),
        ),
      );
      final hostClock = MonotonicClock();
      final host = HostSession(
        engine: FakeEngine(now: hostClock.nowMs, durationMs: 40000),
        mode: mode,
        media: MediaRef.file(film),
        preferredPort: 0,
        clock: hostClock,
        ffmpeg: () => ProcessFfmpegRunner(),
      );
      await host.start();
      final guest = GuestSession(
        engine: VirtualEngine(),
        mode: mode,
        endpoint: SessionEndpoint(
          host: '127.0.0.1',
          port: host.port,
          token: host.token,
          mode: SessionMode.audioOnly,
        ),
      );
      try {
        await guest.start();
        final control = guest.modeControl! as AudioLatencyControl;

        // Avance (ms) de la dernière trame poussée sur la position de l'hôte.
        int lead() {
          final pos = host.controller.target!.positionAt(
            hostClock.nowMs(),
            durationMs: 40000,
          );
          return control.player!.lastPlayedPositionMs! - pos;
        }

        Future<List<int>> leads() async {
          final out = <int>[];
          for (var i = 0; i < 10; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            out.add(lead());
          }
          return out;
        }

        await host.play();
        await Future<void>.delayed(const Duration(seconds: 3));
        final player = control.player!;
        expect(player.framesPlayed, greaterThan(50));
        expect(output.rms, greaterThan(0.05), reason: 'sinus 440 Hz audible');
        // Trame poussée ≈ position de l'hôte + latence de sortie (+ file 80 ms).
        for (final l in await leads()) {
          expect(l, inInclusiveRange(autoLatency - 60, autoLatency + 180));
        }

        // Curseur manuel : +200 ms → les trames partent 200 ms plus tôt.
        await control.setManual(200);
        await Future<void>.delayed(const Duration(seconds: 1));
        for (final l in await leads()) {
          expect(
            l,
            inInclusiveRange(autoLatency + 200 - 60, autoLatency + 200 + 180),
          );
        }
        expect(
          await LatencyOffsetStore(directory: () async => dir).get('bt:test'),
          200,
        );

        // Saut côté hôte : l'invité suit.
        await host.seekTo(25000);
        await Future<void>.delayed(const Duration(seconds: 3));
        for (final l in await leads()) {
          expect(
            l,
            inInclusiveRange(autoLatency + 200 - 60, autoLatency + 200 + 180),
          );
        }
        expect(player.lastPlayedPositionMs, greaterThan(25000));

        // Pause : plus rien de joué.
        await host.pause();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final played = player.framesPlayed;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(player.framesPlayed, played);
        // ignore: avoid_print
        print(
          'mode 3 : ${player.framesPlayed} trames jouées, '
          '${player.framesConcealed} masquées, rms ${output.rms.toStringAsFixed(3)}',
        );
      } finally {
        await guest.close();
        await host.close();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
