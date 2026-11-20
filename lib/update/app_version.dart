/// Version « x.y.z » (préfixe `v`, suffixe `-pre` / `+build` tolérés).
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.parts, {this.preRelease = ''});

  final List<int> parts;

  /// Suffixe `-beta.1` éventuel : une pré-version passe avant la finale.
  final String preRelease;

  static AppVersion? tryParse(String? text) {
    if (text == null) return null;
    final m = RegExp(
      r'^\s*v?(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?\s*$',
    ).firstMatch(text);
    if (m == null) return null;
    return AppVersion(
      m.group(1)!.split('.').map(int.parse).toList(),
      preRelease: m.group(2) ?? '',
    );
  }

  @override
  int compareTo(AppVersion other) {
    final n = parts.length > other.parts.length
        ? parts.length
        : other.parts.length;
    for (var i = 0; i < n; i++) {
      final a = i < parts.length ? parts[i] : 0;
      final b = i < other.parts.length ? other.parts[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    if (preRelease == other.preRelease) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;
    return preRelease.compareTo(other.preRelease);
  }

  bool operator >(AppVersion o) => compareTo(o) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll([...parts, preRelease]);

  @override
  String toString() =>
      parts.join('.') + (preRelease.isEmpty ? '' : '-$preRelease');
}
