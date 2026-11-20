import '../core/media_source.dart';
import '../core/protocol.dart';
import '../core/session_endpoint.dart';
import '../core/session_mode.dart';
import '../net/host_server.dart';

/// Ce que le mode a mis en place côté hôte.
class HostAttachment {
  const HostAttachment({
    required this.localSource,
    this.mediaPath,
    this.onDetach,
  });

  /// Source ouverte par le lecteur local de l'hôte (chemin ou content://).
  final String localSource;

  /// Chemin HTTP du média servi aux invités (mode 2), transmis dans `hello`.
  final String? mediaPath;

  final Future<void> Function()? onDetach;

  Future<void> detach() async => onDetach?.call();
}

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
  /// audio…) et indique la source à ouvrir dans le lecteur local de l'hôte.
  Future<HostAttachment> attachHost({
    required HostServer server,
    required MediaRef media,
    required MediaOpener opener,
  });

  /// Côté invité, après réception du `hello` de l'hôte : source à ouvrir
  /// dans le lecteur local (chemin/URI local en mode 1, URL HTTP en mode 2…).
  Future<String> resolveGuestSource({
    required SessionEndpoint endpoint,
    required HelloMsg hostHello,
    MediaRef? localMedia,
  });
}
