import 'dart:convert';
import 'dart:io';

import 'package:app_synchro_film/update/app_version.dart';
import 'package:app_synchro_film/update/release_feed.dart';
import 'package:app_synchro_film/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> apiRelease(
  String tag, {
  bool pre = false,
  bool draft = false,
}) => {
  'tag_name': tag,
  'name': '$tag — test',
  'body': 'Notes $tag',
  'html_url': 'https://github.com/$kRepo/releases/tag/$tag',
  'prerelease': pre,
  'draft': draft,
  'assets': [
    {
      'name': 'app-arm64-v8a-release.apk',
      'browser_download_url': 'https://example.test/$tag/arm64.apk',
    },
  ],
};

void main() {
  group('AppVersion', () {
    AppVersion v(String s) => AppVersion.tryParse(s)!;
    test('comparaison', () {
      expect(v('v0.5.0') > v('0.4.0'), isTrue);
      expect(v('0.10.0') > v('0.9.9'), isTrue);
      expect(v('0.5.0+5') == v('v0.5.0'), isTrue);
      expect(v('0.5.0') > v('0.5.0-beta.1'), isTrue);
      expect(v('1.0') == v('1.0.0'), isTrue);
      expect(AppVersion.tryParse('latest'), isNull);
    });
  });

  group('flux de releases', () {
    test('API : brouillons exclus, pré-versions comptées, la plus récente', () {
      final r = parseApiReleases([
        apiRelease('v0.4.0', pre: true),
        apiRelease('v0.6.0', draft: true),
        apiRelease('v0.5.0', pre: true),
        apiRelease('v0.3.0'),
      ]);
      expect(r.map((e) => e.tag), ['v0.4.0', 'v0.5.0', 'v0.3.0']);
      final n = newestRelease(r)!;
      expect(n.tag, 'v0.5.0');
      expect(n.prerelease, isTrue);
      expect(n.apkUrlFor('arm64-v8a'), 'https://example.test/v0.5.0/arm64.apk');
      expect(
        n.apkUrlFor('x86_64'),
        'https://github.com/$kRepo/releases/download/v0.5.0/app-x86_64-release.apk',
      );
      expect(n.windowsAssetUrl, isNull);
    });

    test('flux Atom réel de GitHub (repli)', () {
      final xml = File('test/update/fixtures/releases.atom').readAsStringSync();
      final r = parseAtomReleases(xml);
      expect(r.map((e) => e.tag), containsAll(['v0.4.0', 'v0.3.0', 'v0.2.0']));
      final n = newestRelease(r)!;
      expect(n.tag, 'v0.4.0');
      expect(n.notes, contains('Mode 5'));
      expect(n.notes, isNot(contains('<')));
      expect(n.notes, contains("l'invité"));
      expect(
        n.apkUrlFor('arm64-v8a'),
        'https://github.com/$kRepo/releases/download/v0.4.0/app-arm64-v8a-release.apk',
      );
    });
  });

  group('UpdateService', () {
    late Directory dir;
    late DateTime now;
    late List<Uri> calls;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('upd');
      now = DateTime(2026, 11, 20, 10);
      calls = [];
    });
    tearDown(() => dir.delete(recursive: true));

    UpdateService svc(
      Future<String> Function(Uri) get, {
      String current = '0.4.0',
    }) => UpdateService(
      get: (u) {
        calls.add(u);
        return get(u);
      },
      currentVersion: () async => current,
      stateDir: () async => dir,
      now: () => now,
    );

    Future<String> api(Uri u) async => jsonEncode([
      apiRelease('v0.5.0', pre: true),
      apiRelease('v0.4.0', pre: true),
    ]);

    test('nouvelle version, puis au plus une vérification par jour', () async {
      final s = svc(api);
      expect((await s.autoCheck())?.tag, 'v0.5.0');
      expect(await s.autoCheck(), isNull, reason: 'déjà vérifié aujourd\'hui');
      expect(calls, hasLength(1));
      now = now.add(const Duration(hours: 25));
      expect((await s.autoCheck())?.tag, 'v0.5.0');
    });

    test('à jour', () async {
      final r = await svc(api, current: '0.5.0').check();
      expect(r.status, UpdateStatus.upToDate);
    });

    test(
      '« Ignorer cette version » : silencieux ensuite, sauf vérif manuelle',
      () async {
        final s = svc(api);
        final r = await s.check();
        await s.ignore(r.release!);
        expect((await s.check()).status, UpdateStatus.ignored);
        now = now.add(const Duration(days: 2));
        expect(await s.autoCheck(), isNull);
        expect(
          (await s.check(includeIgnored: true)).status,
          UpdateStatus.available,
        );
      },
    );

    test('hors-ligne : aucun bruit, aucune exception', () async {
      final s = svc((u) async => throw const SocketException('pas de réseau'));
      expect(await s.autoCheck(), isNull);
      expect((await s.check()).status, UpdateStatus.offline);
      expect(calls, hasLength(2), reason: 'pas de repli Atom hors-ligne');
    });

    test('API limitée (403) : repli sur le flux Atom', () async {
      final atom = File('test/update/fixtures/releases.atom')
          .readAsStringSync();
      final s = svc((u) async {
        if (u.host == 'api.github.com') throw const HttpException('HTTP 403');
        return atom;
      }, current: '0.3.0');
      final r = await s.check();
      expect(r.status, UpdateStatus.available);
      expect(r.release!.tag, 'v0.4.0');
      expect(calls.map((u) => u.host), ['api.github.com', 'github.com']);
    });
  });

  test('téléchargement avec progression', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final payload = List<int>.generate(300000, (i) => i % 251);
    server.listen((req) {
      req.response
        ..contentLength = payload.length
        ..add(payload);
      req.response.close();
    });
    final dir = await Directory.systemTemp.createTemp('dl');
    final progress = <double?>[];
    final f = await downloadFile(
      Uri.parse('http://127.0.0.1:${server.port}/app.apk'),
      File('${dir.path}/u/app.apk'),
      onProgress: (p, _) => progress.add(p),
    );
    expect(await f.length(), payload.length);
    expect(progress.last, 1.0);
    await server.close(force: true);
    await dir.delete(recursive: true);
  });
}
