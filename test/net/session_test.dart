import 'dart:async';
import 'dart:io';

import 'package:app_synchro_film/core/monotonic_clock.dart';
import 'package:app_synchro_film/core/session_endpoint.dart';
import 'package:app_synchro_film/modes/double_file_mode.dart';
import 'package:app_synchro_film/net/session/guest_session.dart';
import 'package:app_synchro_film/net/session/host_session.dart';
import 'package:app_synchro_film/net/session/sync_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../player/fake_engine.dart';

Future<void> waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('condition non atteinte');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory dir;
  late HostSession host;
  late FakeEngine hostEngine;
  late MonotonicClock hostClock;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('session');
    await File('${dir.path}/film.mkv').writeAsBytes(List.filled(5000, 7));
    await File('${dir.path}/copie.mkv').writeAsBytes(List.filled(5000, 7));
    await File('${dir.path}/autre.mkv').writeAsBytes(List.filled(5000, 8));
    hostClock = MonotonicClock();
    hostEngine = FakeEngine(now: hostClock.nowMs);
    host = HostSession(
      engine: hostEngine,
      mode: const DoubleFileMode(),
      filePath: '${dir.path}/film.mkv',
      deviceName: 'PC',
      preferredPort: 0,
      clock: hostClock,
    );
    await host.start();
  });

  tearDown(() async {
    await host.close();
    await dir.delete(recursive: true);
  });

  GuestSession guestFor(String file, {String? token}) {
    final clock = MonotonicClock();
    return GuestSession(
      engine: FakeEngine(now: clock.nowMs),
      mode: const DoubleFileMode(),
      endpoint: SessionEndpoint(
        host: '127.0.0.1',
        port: host.port,
        token: token ?? host.token,
      ),
      localFilePath: '${dir.path}/$file',
      deviceName: 'Téléphone',
      clock: clock,
    );
  }

  test('connexion, empreinte identique et commandes des deux côtés', () async {
    final guest = guestFor('copie.mkv');
    await guest.start();
    await waitFor(() => guest.status == SessionStatus.connected);
    await waitFor(() => host.status == SessionStatus.connected);
    expect(guest.fileMatch, isTrue);
    expect(host.fileMatch, isTrue);
    expect(host.peerName, 'Téléphone');
    expect(guest.peerName, 'PC');

    // Horloge convergée (même machine : offset ≈ 0).
    await waitFor(() => guest.clockSync.isConverged);
    expect(guest.clockSync.offsetMs.abs(), lessThan(20));

    // L'invité pilote : play → l'hôte arbitre et rediffuse.
    await guest.play();
    await waitFor(() => hostEngine.isPlaying && guest.engine.isPlaying);
    expect(host.arbiter.state.playing, isTrue);

    // L'hôte pilote : seek → l'invité suit.
    await host.seekTo(60000);
    await waitFor(() => (guest.engine.positionMs - 60000).abs() < 500);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final drift = guest.engine.positionMs - hostEngine.positionMs;
    expect(drift.abs(), lessThan(60));

    await guest.pause();
    await waitFor(() => !hostEngine.isPlaying && !guest.engine.isPlaying);

    await guest.close();
    await waitFor(() => host.status == SessionStatus.waitingForGuest);
  });

  test('fichier différent signalé', () async {
    final guest = guestFor('autre.mkv');
    await guest.start();
    await waitFor(() => guest.status == SessionStatus.connected);
    expect(guest.fileMatch, isFalse);
    await guest.close();
  });

  test('mauvais token refusé', () async {
    final guest = guestFor('copie.mkv', token: 'mauvais');
    await expectLater(guest.start(), throwsA(isA<WebSocketException>()));
    expect(guest.status, SessionStatus.error);
  });
}
