import 'dart:async';
import 'dart:io';

import 'download_sink.dart';

/// Avancement d'un téléchargement.
class TransferProgress {
  const TransferProgress({
    required this.received,
    required this.total,
    required this.bytesPerSecond,
    this.resumedFrom = 0,
    this.retrying = false,
  });

  final int received;
  final int? total;
  final double bytesPerSecond;

  /// Octets repris d'une tentative précédente (0 = depuis le début).
  final int resumedFrom;

  /// Connexion perdue : nouvelle tentative en cours.
  final bool retrying;

  double? get fraction =>
      total == null || total == 0 ? null : (received / total!).clamp(0, 1);

  Duration? get eta {
    if (total == null || bytesPerSecond <= 1) return null;
    return Duration(
      seconds: ((total! - received) / bytesPerSecond).ceil().clamp(0, 359999),
    );
  }
}

class TransferCancelled implements Exception {
  const TransferCancelled();
  @override
  String toString() => 'Transfert annulé';
}

class TransferFailed implements Exception {
  const TransferFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Téléchargement HTTP direct (Wi-Fi local) avec reprise par `Range` :
/// une coupure relance automatiquement la requête à partir des octets déjà
/// écrits ; un fichier partiel d'un lancement précédent est repris aussi.
class Downloader {
  Downloader({
    required this.url,
    required this.sink,
    this.maxRetries = 30,
    this.retryDelay = const Duration(seconds: 2),
    this.idleTimeout = const Duration(seconds: 20),
  });

  final Uri url;
  final DownloadSink sink;
  final int maxRetries;
  final Duration retryDelay;

  /// Aucun octet reçu pendant ce délai : connexion considérée perdue.
  final Duration idleTimeout;

  final _progress = StreamController<TransferProgress>.broadcast();
  Stream<TransferProgress> get progress => _progress.stream;

  HttpClient? _client;
  bool _cancelled = false;
  int _received = 0;
  int? _total;
  int _resumedFrom = 0;
  bool _prepared = false;

  // Vitesse : moyenne glissante sur ~2 s.
  final _samples = <(int, int)>[];
  final _watch = Stopwatch()..start();
  int _lastEmit = -1000;

  /// Lance le téléchargement ; renvoie l'emplacement du fichier terminé.
  Future<String> run() async {
    var attempt = 0;
    try {
      while (true) {
        if (_cancelled) throw const TransferCancelled();
        try {
          return await _once();
        } on TransferCancelled {
          rethrow;
        } on TransferFailed {
          rethrow;
        } catch (e) {
          if (_cancelled) throw const TransferCancelled();
          if (++attempt > maxRetries) {
            throw TransferFailed('Connexion perdue : $e');
          }
          _emit(force: true, retrying: true);
          await Future<void>.delayed(retryDelay);
        }
      }
    } catch (_) {
      await sink.close();
      rethrow;
    } finally {
      _client?.close(force: true);
      await _progress.close();
    }
  }

  /// Annule (le fichier partiel est gardé pour une reprise ultérieure).
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<String> _once() async {
    _client?.close(force: true);
    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 5);
    if (!_prepared) {
      // Taille annoncée par le serveur (HEAD) pour valider un partiel.
      final head = await (await client.headUrl(url)).close();
      await head.drain<void>();
      if (head.statusCode == HttpStatus.forbidden) {
        throw const TransferFailed('Lien expiré ou invalide (403).');
      }
      if (head.statusCode != HttpStatus.ok) {
        throw TransferFailed('Le serveur a répondu ${head.statusCode}.');
      }
      _total = head.contentLength >= 0 ? head.contentLength : null;
      _received = _resumedFrom = await sink.prepare(_total);
      _prepared = true;
    }
    if (_total != null && _received >= _total!) return sink.finish();

    final req = await client.getUrl(url);
    if (_received > 0) {
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$_received-');
    }
    final res = await req.close();
    switch (res.statusCode) {
      case HttpStatus.partialContent:
        final cr = res.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        final m = RegExp(r'bytes (\d+)-\d+/(\d+|\*)').firstMatch(cr);
        if (m == null || int.parse(m.group(1)!) != _received) {
          throw const TransferFailed('Réponse de reprise incohérente.');
        }
      case HttpStatus.ok:
        if (_received > 0) {
          await sink.truncate(); // pas de reprise côté serveur
          _received = _resumedFrom = 0;
        }
        if (res.contentLength >= 0) _total = res.contentLength;
      case HttpStatus.requestedRangeNotSatisfiable:
        await res.drain<void>();
        throw const TransferFailed('Le fichier a changé chez l\'expéditeur.');
      default:
        await res.drain<void>();
        throw TransferFailed('Le serveur a répondu ${res.statusCode}.');
    }
    await for (final chunk in res.timeout(idleTimeout)) {
      if (_cancelled) throw const TransferCancelled();
      await sink.write(chunk);
      _received += chunk.length;
      _emit();
    }
    if (_total != null && _received < _total!) {
      throw const HttpException('transfert interrompu');
    }
    _emit(force: true);
    return sink.finish();
  }

  void _emit({bool force = false, bool retrying = false}) {
    final t = _watch.elapsedMilliseconds;
    if (!force && t - _lastEmit < 200) return;
    _lastEmit = t;
    _samples.add((t, _received));
    while (_samples.length > 2 && t - _samples.first.$1 > 2000) {
      _samples.removeAt(0);
    }
    final (t0, b0) = _samples.first;
    final speed = t > t0 ? (_received - b0) * 1000 / (t - t0) : 0.0;
    if (_progress.isClosed) return;
    _progress.add(
      TransferProgress(
        received: _received,
        total: _total,
        bytesPerSecond: speed,
        resumedFrom: _resumedFrom,
        retrying: retrying,
      ),
    );
  }
}
