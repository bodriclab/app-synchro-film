import 'package:flutter/services.dart';

/// Charge un fichier de la page web embarquée (déclarée dans `pubspec.yaml`).
Future<String> loadWebClientAsset(String name) =>
    rootBundle.loadString('web_client/$name');
