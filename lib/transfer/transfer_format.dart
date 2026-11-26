import 'dart:convert';

/// Formate un nombre d'octets en une chaîne lisible avec des unités françaises.
///
/// Les règles d'affichage sont les suivantes :
/// - Moins de 1024 octets : affiché en octets (" o").
/// - Moins de 1 Mio : affiché en kilo-octets (" Ko") avec 1 décimale.
/// - Moins de 1 Gio : affiché en méga-octets (" Mo") avec 1 décimale.
/// - Au-delà : affiché en giga-octets (" Go") avec 2 décimales.
/// Utilise une virgule comme séparateur décimal.
String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes o';
  } else if (bytes < 1024 * 1024) {
    final val = bytes / 1024;
    return '${val.toStringAsFixed(1).replaceAll('.', ',')} Ko';
  } else if (bytes < 1024 * 1024 * 1024) {
    final val = bytes / (1024 * 1024);
    return '${val.toStringAsFixed(1).replaceAll('.', ',')} Mo';
  } else {
    final val = bytes / (1024 * 1024 * 1024);
    return '${val.toStringAsFixed(2).replaceAll('.', ',')} Go';
  }
}

/// Formate une vitesse en octets par seconde (ex: "12,3 Mo/s").
///
/// Renvoie "—" si la valeur est négative ou NaN.
String formatSpeed(double bytesPerSecond) {
  if (bytesPerSecond.isNaN || bytesPerSecond < 0) {
    return '—';
  }
  return '${formatBytes(bytesPerSecond.round())}/s';
}

/// Formate une durée estimée restante (ETA).
///
/// - Si [d] est nul, renvoie une chaîne vide.
/// - Moins d'une minute : secondes seules (ex: "45 s").
/// - Moins d'une heure : minutes et secondes (ex: "3 min 05 s").
/// - Une heure ou plus : heures et minutes (ex: "1 h 02 min").
String formatEta(Duration? d) {
  if (d == null) return '';

  final seconds = d.inSeconds;
  if (seconds < 60) {
    return '$seconds s';
  } else if (seconds < 3600) {
    final mins = d.inMinutes;
    final remSecs = seconds % 60;
    final paddedSecs = remSecs.toString().padLeft(2, '0');
    return '$mins min $paddedSecs s';
  } else {
    final hours = d.inHours;
    final remMins = d.inMinutes % 60;
    final paddedMins = remMins.toString().padLeft(2, '0');
    return '$hours h $paddedMins min';
  }
}

/// Génère une page HTML5 complète et responsive pour le téléchargement direct d'un fichier.
///
/// Utilise un thème sombre, des styles en ligne, et ne nécessite aucune ressource externe ni JavaScript.
String transferPageHtml({
  required String name,
  required int size,
  required String downloadUrl,
}) {
  final htmlEscaper = const HtmlEscape(HtmlEscapeMode.element);
  final attrEscaper = const HtmlEscape(HtmlEscapeMode.attribute);

  final escapedName = htmlEscaper.convert(name);
  final attrName = attrEscaper.convert(name);
  final escapedUrl = attrEscaper.convert(downloadUrl);
  final formattedSize = formatBytes(size);

  return '''<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>App Synchro Film — Télécharger</title>
  <style>
    body {
      background-color: #111;
      color: #ffffff;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      margin: 0;
      padding: 20px;
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
      box-sizing: border-box;
    }
    .card {
      background-color: #1a1a1a;
      border-radius: 12px;
      padding: 30px;
      max-width: 400px;
      width: 100%;
      box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5);
      text-align: center;
      box-sizing: border-box;
    }
    h1 {
      font-size: 1.5rem;
      margin-top: 0;
      margin-bottom: 10px;
    }
    .file-name {
      font-weight: bold;
      word-break: break-all;
      color: #ddd;
      margin-bottom: 5px;
    }
    .file-size {
      color: #888;
      font-size: 0.9rem;
      margin-bottom: 25px;
    }
    .btn {
      display: inline-block;
      background-color: #e50914;
      color: #ffffff;
      padding: 14px 28px;
      font-size: 1.1rem;
      font-weight: bold;
      text-decoration: none;
      border-radius: 8px;
      width: 100%;
      box-sizing: border-box;
      transition: background-color 0.2s;
      margin-bottom: 25px;
    }
    .btn:hover {
      background-color: #f6121d;
    }
    .hint {
      color: #aaa;
      font-size: 0.85rem;
      line-height: 1.4;
      margin: 0;
      text-align: left;
    }
  </style>
</head>
<body>
  <div class="card">
    <h1>Télécharger le film</h1>
    <div class="file-name">$escapedName</div>
    <div class="file-size">$formattedSize</div>
    <a class="btn" href="$escapedUrl" download="$attrName">Télécharger</a>
    <p class="hint">Transfert direct en Wi-Fi local, sans Internet. Gardez cet écran ouvert jusqu'à la fin ; en cas de coupure, relancez : le navigateur peut reprendre le téléchargement.</p>
  </div>
</body>
</html>''';
}
