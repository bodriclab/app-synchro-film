/// Les 4 modes d'utilisation de l'application.
enum SessionMode {
  /// Mode 1 : chaque appareil lit son propre fichier, seules les commandes transitent.
  doubleFile('double_file'),

  /// Mode 2 : l'hôte diffuse le fichier en HTTP progressif à l'app invitée.
  stream('stream'),

  /// Mode 3 : l'hôte diffuse uniquement le son (Opus/UDP) vers l'invité.
  audioOnly('audio_only'),

  /// Mode 4 : l'invité regarde depuis un navigateur web.
  browser('browser');

  const SessionMode(this.wireName);

  /// Nom utilisé dans le protocole, le QR code et le TXT mDNS.
  final String wireName;

  static SessionMode fromWire(String? value) => SessionMode.values.firstWhere(
        (m) => m.wireName == value,
        orElse: () => SessionMode.doubleFile,
      );
}
