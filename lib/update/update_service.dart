import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'app_version.dart';
import 'release_feed.dart';

/// Résultat d'une vérification.
enum UpdateStatus { available, upToDate, ignored, offline }

class UpdateCheck {
  const UpdateCheck(this.status, [this.release]);
  final UpdateStatus status;
  final Release? release;
}

/// Récupère un document HTTP (texte) ; lève en cas d'erreur réseau / HTTP.
typedef HttpGetText = Future<String> Function(Uri url);

/// Vérifie les releases GitHub (au plus une fois par jour au démarrage, ou à
/// la demande), mémorise la version ignorée. Hors-ligne : silencieux.
class UpdateService {
  UpdateService({
    HttpGetText? get,
    Future<String> Function()? currentVersion,
    Future<Directory> Function()? stateDir,
    DateTime Function()? now,
    this.minInterval = const Duration(hours: 24),
  }) : _get = get ?? httpGetText,
       _currentVersion = currentVersion ?? _packageVersion,
       _stateDir = stateDir ?? getApplicationSupportDirectory,
       _now = now ?? DateTime.now;

  final HttpGetText _get;
  final Future<String> Function() _currentVersion;
  final Future<Directory> Function() _stateDir;
  final DateTime Function() _now;
  final Duration minInterval;

  static Future<String> _packageVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  Future<String> currentVersion() => _currentVersion();

  /// Vérification automatique : null si pas encore le moment, hors-ligne,
  /// à jour ou version ignorée (jamais d'erreur affichée).
  Future<Release?> autoCheck() async {
    try {
      final state = await _readState();
      final last = DateTime.tryParse(state['lastCheck'] as String? ?? '');
      if (last != null && _now().difference(last) < minInterval) return null;
      final r = await check();
      return r.status == UpdateStatus.available ? r.release : null;
    } catch (_) {
      return null;
    }
  }

  /// Vérification immédiate (bouton « Vérifier les mises à jour »).
  Future<UpdateCheck> check({bool includeIgnored = false}) async {
    final List<Release> releases;
    try {
      releases = await fetchReleases();
    } catch (_) {
      return const UpdateCheck(UpdateStatus.offline);
    }
    final state = await _readState();
    state['lastCheck'] = _now().toIso8601String();
    await _writeState(state);
    final newest = newestRelease(releases);
    final current = AppVersion.tryParse(await _currentVersion());
    if (newest == null || current == null || !(newest.version > current)) {
      return UpdateCheck(UpdateStatus.upToDate, newest);
    }
    if (!includeIgnored && state['ignored'] == newest.tag) {
      return UpdateCheck(UpdateStatus.ignored, newest);
    }
    return UpdateCheck(UpdateStatus.available, newest);
  }

  /// API GitHub (anonyme), puis flux Atom si l'API refuse (limite par IP).
  Future<List<Release>> fetchReleases() async {
    try {
      final r = parseApiReleases(
        jsonDecode(await _get(Uri.parse(kReleasesApi))),
      );
      if (r.isNotEmpty) return r;
    } on SocketException {
      rethrow; // hors-ligne : inutile d'essayer le flux
    } catch (_) {}
    return parseAtomReleases(await _get(Uri.parse(kReleasesAtom)));
  }

  Future<void> ignore(Release r) async {
    final state = await _readState();
    state['ignored'] = r.tag;
    await _writeState(state);
  }

  Future<File> _stateFile() async =>
      File('${(await _stateDir()).path}/update_state.json');

  Future<Map<String, dynamic>> _readState() async {
    try {
      final f = await _stateFile();
      if (await f.exists()) {
        return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  Future<void> _writeState(Map<String, dynamic> s) async {
    try {
      final f = await _stateFile();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(s));
    } catch (_) {}
  }
}

/// GET texte avec délais courts (l'app doit rester réactive hors-ligne).
Future<String> httpGetText(Uri url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..userAgent = 'app-synchro-film-updater';
  try {
    final req = await client.getUrl(url);
    req.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json, application/atom+xml, */*',
    );
    final res = await req.close().timeout(const Duration(seconds: 10));
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    return body;
  } finally {
    client.close(force: true);
  }
}

/// Télécharge [url] dans [dest] (redirections suivies), progression 0..1
/// (null si taille inconnue). Annulable via [cancel].
Future<File> downloadFile(
  Uri url,
  File dest, {
  void Function(double? progress, int received)? onProgress,
  Future<void>? cancel,
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = 'app-synchro-film-updater';
  var cancelled = false;
  unawaited(
    cancel?.then((_) {
      cancelled = true;
      client.close(force: true);
    }),
  );
  try {
    final res = await (await client.getUrl(url)).close();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    await dest.parent.create(recursive: true);
    final tmp = File('${dest.path}.part');
    final sink = tmp.openWrite();
    final total = res.contentLength;
    var received = 0;
    try {
      await for (final chunk in res) {
        if (cancelled) throw const HttpException('Téléchargement annulé');
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total > 0 ? received / total : null, received);
      }
    } finally {
      await sink.close();
    }
    if (total > 0 && received != total) {
      throw const HttpException('Téléchargement incomplet');
    }
    if (await dest.exists()) await dest.delete();
    return await tmp.rename(dest.path);
  } finally {
    client.close(force: true);
  }
}
