/// Les 5 modes d'utilisation de l'application.
enum SessionMode {
  /// Mode 1 : chaque appareil lit son propre fichier, seules les commandes transitent.
  doubleFile('double_file'),

  /// Mode 2 : l'hôte diffuse le fichier en HTTP progressif à l'app invitée.
  stream('stream'),

  /// Mode 3 : l'hôte diffuse uniquement le son (Opus/UDP) vers l'invité.
  audioOnly('audio_only'),

  /// Mode 4 : l'invité regarde depuis un navigateur web.
  browser('browser'),

  /// Mode 5 : l'invité écoute seulement le son dans son navigateur
  /// (PCM sur WebSocket, Web Audio).
  browserAudio('browser_audio');

  const SessionMode(this.wireName);

  /// L'invité utilise un navigateur (pas l'app) : le QR code encode
  /// directement l'adresse http de la page.
  bool get usesBrowser => this == browser || this == browserAudio;

  /// Nom utilisé dans le protocole, le QR code et le TXT mDNS.
  final String wireName;

  static SessionMode fromWire(String? value) => SessionMode.values.firstWhere(
    (m) => m.wireName == value,
    orElse: () => SessionMode.doubleFile,
  );
}
