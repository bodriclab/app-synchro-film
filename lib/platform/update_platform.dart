import 'dart:io';

import 'package:flutter/services.dart';

/// Accès natif pour les mises à jour (Android : ABI, autorisation
/// « sources inconnues », installeur système ; Windows : navigateur).
class UpdatePlatform {
  const UpdatePlatform();

  static const _channel = MethodChannel('com.bodriclab.synchrofilm/update');

  Future<String> androidAbi() async =>
      await _channel.invokeMethod<String>('abi') ?? 'arm64-v8a';

  Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  /// Ouvre le réglage « Installer des applis inconnues » ; true si accordé.
  Future<bool> requestInstallPermission() async =>
      await _channel.invokeMethod<bool>('requestInstallPermission') ?? false;

  Future<void> installApk(String path) =>
      _channel.invokeMethod<void>('install', {'path': path});

  /// Ouvre une URL dans le navigateur par défaut (Windows/Linux).
  Future<void> openUrl(String url) async {
    if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [url]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [url]);
    }
  }
}
