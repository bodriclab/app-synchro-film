import '../core/session_endpoint.dart';
import '../core/session_mode.dart';
import '../net/host_server.dart';

/// Point d'extension commun aux 4 modes.
///
/// Une session (hôte ou invité) délègue au mode tout ce qui concerne
/// « d'où vient le média » ; la synchro (horloge, état, commandes,
/// correction douce) reste identique pour tous les modes.
abstract class ModeHandler {
  const ModeHandler();

  SessionMode get mode;

  /// Libellé court pour l'UI.
  String get title;

  /// Description d'une ligne pour l'UI.
  String get subtitle;

  /// Faux tant que le mode n'est pas encore implémenté.
  bool get isImplemented;

  /// L'invité doit-il choisir son propre fichier (mode 1) ?
  bool get guestNeedsLocalFile;

  /// Les empreintes de fichier doivent-elles être comparées au `hello` ?
  bool get checksFingerprint => guestNeedsLocalFile;

  /// Côté hôte : prépare la diffusion (routes HTTP sur [server], pipeline
  /// audio…) et retourne la source à ouvrir dans le lecteur local de l'hôte.
  Future<String> attachHost({
    required HostServer server,
    required String filePath,
  });

  /// Côté invité : source à ouvrir dans le lecteur local
  /// (chemin local en mode 1, URL HTTP en mode 2…).
  Future<String> resolveGuestSource({
    required SessionEndpoint endpoint,
    String? localFilePath,
  });

  /// Libère les ressources du mode (routes, encodeurs…).
  Future<void> detach() async {}
}
