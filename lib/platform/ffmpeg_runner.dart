import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

/// Une exécution FFmpeg dont la sortie est lue en flux.
class FfmpegJob {
  FfmpegJob(this.output, this._cancel);

  /// Octets produits par FFmpeg (abonnement unique). Mettre l'abonnement en
  /// pause bloque FFmpeg (contrôle de flux TCP) : rythme sans tampon géant.
  final Stream<Uint8List> output;
  final Future<void> Function() _cancel;
  bool _cancelled = false;

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    await _cancel();
  }
}

/// Lance FFmpeg en envoyant sa sortie vers une socket TCP locale
/// (`{out}` dans les arguments → `tcp://127.0.0.1:port`).
///
/// Le même mécanisme fonctionne avec ffmpeg-kit (Android, Windows) et avec
/// un exécutable `ffmpeg` (tests, Linux) : pas de pipe nommé, contrôle de
/// flux naturel, arrêt propre en fermant la socket.
abstract class FfmpegRunner {
  /// Valeur à passer après `-i` pour [uri] (chemin ou content://).
  Future<String> inputFor(String uri);

  /// Démarre FFmpeg. [args] doit contenir `{out}`.
  Future<FfmpegJob> start(List<String> args, {Duration connectTimeout});

  /// Lance FFmpeg et retourne toute sa sortie (sondes courtes).
  Future<Uint8List> run(List<String> args) async {
    final job = await start(args);
    final b = BytesBuilder(copy: false);
    await for (final chunk in job.output) {
      b.add(chunk);
    }
    await job.cancel();
    return b.takeBytes();
  }

  /// Lance FFmpeg avec une sortie fichier déjà présente dans [args].
  Future<FfmpegFileJob> startFile(List<String> args) =>
      throw UnsupportedError('Sortie fichier non prise en charge');

  /// Ouvre la socket d'écoute, remplace `{out}`, lance [launch] et attend
  /// la connexion de FFmpeg (ou son échec).
  static Future<FfmpegJob> startWithSocket(
    List<String> args, {
    required Future<({Future<void> done, Future<void> Function() kill})>
    Function(List<String> args)
    launch,
    Duration connectTimeout = const Duration(seconds: 15),
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final out = 'tcp://127.0.0.1:${server.port}';
    final realArgs = [for (final a in args) a == '{out}' ? out : a];
    final proc = await launch(realArgs);
    Socket socket;
    try {
      socket = await Future.any<Socket>([
        server.first,
        proc.done.then<Socket>(
          (_) => throw const FfmpegException(
            'FFmpeg s\'est arrêté avant '
            'de produire une sortie (fichier illisible ?)',
          ),
        ),
      ]).timeout(connectTimeout);
    } catch (e) {
      await proc.kill();
      await server.close();
      rethrow;
    }
    await server.close();
    return FfmpegJob(socket, () async {
      socket.destroy();
      await proc.kill();
    });
  }
}

/// FFmpeg qui écrit lui-même un fichier (sortie seekable, ex. `+faststart`).
class FfmpegFileJob {
  FfmpegFileJob(this.done, this._cancel);

  /// Vrai si FFmpeg s'est terminé avec succès.
  final Future<bool> done;
  final Future<void> Function() _cancel;
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    await _cancel();
  }
}

class FfmpegException implements Exception {
  const FfmpegException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// FFmpeg embarqué via ffmpeg-kit (Android, Windows).
class KitFfmpegRunner extends FfmpegRunner {
  @override
  Future<String> inputFor(String uri) async {
    if (uri.startsWith('content://')) {
      final saf = await FFmpegKitConfig.getSafParameterForRead(uri);
      if (saf == null) throw FfmpegException('Accès SAF impossible : $uri');
      return saf;
    }
    return uri;
  }

  @override
  Future<FfmpegJob> start(
    List<String> args, {
    Duration connectTimeout = const Duration(seconds: 15),
  }) => FfmpegRunner.startWithSocket(
    ['-hide_banner', '-loglevel', 'error', ...args],
    connectTimeout: connectTimeout,
    launch: (a) async {
      final done = Completer<void>();
      final session = await FFmpegKit.executeWithArgumentsAsync(a, (_) {
        if (!done.isCompleted) done.complete();
      });
      final id = session.getSessionId();
      return (
        done: done.future,
        kill: () async {
          if (!done.isCompleted) await FFmpegKit.cancel(id);
        },
      );
    },
  );

  @override
  Future<FfmpegFileJob> startFile(List<String> args) async {
    final done = Completer<bool>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      ['-hide_banner', '-loglevel', 'error', ...args],
      (s) async {
        final rc = await s.getReturnCode();
        if (!done.isCompleted) done.complete(ReturnCode.isSuccess(rc));
      },
    );
    final id = session.getSessionId();
    return FfmpegFileJob(done.future, () async {
      if (!done.isCompleted) await FFmpegKit.cancel(id);
    });
  }
}

/// Exécutable `ffmpeg` du système (tests sur la box, Linux).
class ProcessFfmpegRunner extends FfmpegRunner {
  ProcessFfmpegRunner({this.executable = 'ffmpeg'});

  final String executable;

  @override
  Future<String> inputFor(String uri) async => uri;

  @override
  Future<FfmpegJob> start(
    List<String> args, {
    Duration connectTimeout = const Duration(seconds: 15),
  }) => FfmpegRunner.startWithSocket(
    ['-hide_banner', '-loglevel', 'error', '-nostdin', ...args],
    connectTimeout: connectTimeout,
    launch: (a) async {
      final p = await Process.start(executable, a);
      p.stdout.drain<void>();
      p.stderr.drain<void>();
      return (
        done: p.exitCode.then((_) {}),
        kill: () async {
          p.kill();
        },
      );
    },
  );

  @override
  Future<FfmpegFileJob> startFile(List<String> args) async {
    final p = await Process.start(executable, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      ...args,
    ]);
    p.stdout.drain<void>();
    p.stderr.drain<void>();
    return FfmpegFileJob(p.exitCode.then((c) => c == 0), () async {
      p.kill();
      await p.exitCode;
    });
  }
}

FfmpegRunner? _default;

/// FFmpeg par défaut de la plateforme.
FfmpegRunner defaultFfmpegRunner() => _default ??=
    (Platform.isAndroid ||
        Platform.isWindows ||
        Platform.isIOS ||
        Platform.isMacOS)
    ? KitFfmpegRunner()
    : ProcessFfmpegRunner();
