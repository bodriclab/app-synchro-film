import 'app_version.dart';

/// Dépôt GitHub public des releases.
const String kRepo = 'bodriclab/app-synchro-film';
const String kReleasesApi =
    'https://api.github.com/repos/$kRepo/releases?per_page=15';

/// Flux Atom (repli si l'API anonyme est limitée : 60 requêtes/h par IP).
const String kReleasesAtom = 'https://github.com/$kRepo/releases.atom';

/// Une release publiée (pré-versions comprises).
class Release {
  const Release({
    required this.tag,
    required this.version,
    required this.title,
    required this.notes,
    required this.pageUrl,
    required this.assets,
    this.prerelease = false,
  });

  final String tag;
  final AppVersion version;
  final String title;

  /// Notes en texte brut (Markdown laissé tel quel).
  final String notes;
  final String pageUrl;

  /// Nom de fichier → URL de téléchargement.
  final Map<String, String> assets;
  final bool prerelease;

  /// APK pour une ABI Android (`app-arm64-v8a-release.apk`…). Via le flux
  /// Atom on ne connaît pas les fichiers : URL déduite du nom standard.
  String apkUrlFor(String abi) {
    final name = 'app-$abi-release.apk';
    return assets[name] ??
        'https://github.com/$kRepo/releases/download/$tag/$name';
  }

  /// Binaire Windows éventuel (zip / exe / msix contenant « windows »).
  String? get windowsAssetUrl {
    for (final e in assets.entries) {
      final n = e.key.toLowerCase();
      if ((n.contains('windows') ||
              n.endsWith('.msix') ||
              n.endsWith('.exe')) &&
          (n.endsWith('.zip') || n.endsWith('.exe') || n.endsWith('.msix'))) {
        return e.value;
      }
    }
    return null;
  }
}

/// Réponse de `GET /repos/{repo}/releases` (liste JSON).
List<Release> parseApiReleases(Object? json) {
  if (json is! List) return const [];
  final out = <Release>[];
  for (final r in json) {
    if (r is! Map || r['draft'] == true) continue;
    final tag = r['tag_name'] as String?;
    final v = AppVersion.tryParse(tag);
    if (tag == null || v == null) continue;
    final assets = <String, String>{};
    for (final a in (r['assets'] as List? ?? const [])) {
      if (a is Map &&
          a['name'] is String &&
          a['browser_download_url'] is String) {
        assets[a['name'] as String] = a['browser_download_url'] as String;
      }
    }
    out.add(
      Release(
        tag: tag,
        version: v,
        title: (r['name'] as String?)?.trim().isNotEmpty == true
            ? r['name'] as String
            : tag,
        notes: (r['body'] as String? ?? '').trim(),
        pageUrl:
            r['html_url'] as String? ??
            'https://github.com/$kRepo/releases/tag/$tag',
        assets: assets,
        prerelease: r['prerelease'] == true,
      ),
    );
  }
  return out;
}

/// Flux Atom `releases.atom` (notes en HTML converti en texte).
List<Release> parseAtomReleases(String xml) {
  final out = <Release>[];
  for (final m in RegExp(r'<entry>([\s\S]*?)</entry>').allMatches(xml)) {
    final e = m.group(1)!;
    final link = RegExp(r'<link[^>]*href="([^"]+)"').firstMatch(e)?.group(1);
    final tag = link == null ? null : Uri.parse(link).pathSegments.last;
    final v = AppVersion.tryParse(tag);
    if (tag == null || v == null) continue;
    final title = _unescape(
      RegExp(r'<title>([\s\S]*?)</title>').firstMatch(e)?.group(1) ?? tag,
    );
    final content =
        RegExp(r'<content[^>]*>([\s\S]*?)</content>').firstMatch(e)?.group(1) ??
        '';
    out.add(
      Release(
        tag: tag,
        version: v,
        title: title.trim(),
        notes: htmlToText(_unescape(content)),
        pageUrl: link!,
        assets: const {},
      ),
    );
  }
  return out;
}

/// Release la plus récente (pré-versions comprises).
Release? newestRelease(Iterable<Release> releases) {
  Release? best;
  for (final r in releases) {
    if (best == null || r.version > best.version) best = r;
  }
  return best;
}

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

/// HTML minimal → texte lisible (listes en puces).
String htmlToText(String html) {
  var s = html
      .replaceAll(RegExp(r'<li[^>]*>'), '\n• ')
      .replaceAll(RegExp(r'<br\s*/?>|</p>|</h\d>|</ul>|</ol>'), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  s = _unescape(s);
  return s
      .split('\n')
      .map((l) => l.trimRight())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
