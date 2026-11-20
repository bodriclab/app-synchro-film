import 'dart:async';

import '../core/media_source.dart';
import '../core/playback_state.dart';
import '../core/protocol.dart';
import '../core/session_endpoint.dart';
import '../core/session_mode.dart';
import '../net/host_server.dart';
import '../net/web_client_handler.dart';
import '../platform/ffmpeg_runner.dart';

/// Ce que la session hôte met à disposition des modes.
class HostContext {
  const HostContext({
    required this.server,
    required this.media,
    required this.opener,
    required this.hostNowMs,
    required this.state,
    required this.durationMs,
    required this.ffmpeg,
    required this.loadAsset,
  });

  final HostServer server;
  final MediaRef media;
  final MediaOpener opener;
  final int Function() hostNowMs;
  final PlaybackState Function() state;
  final int? Function() durationMs;
  final FfmpegRunner Function() ffmpeg;
  final AssetLoader loadAsset;
}

/// Ce que le mode a mis en place côté hôte.
class HostAttachment {
  const HostAttachment({
    required this.localSource,
    this.mediaPath,
    this.remux,
    this.onGuestHello,
    this.onGuestLeft,
    this.onDetach,
  });

  /// Source ouverte par le lecteur local de l'hôte (chemin ou content://).
  final String localSource;

  /// Chemin HTTP du média servi aux invités (modes 2 et 4), transmis dans `hello`.
  final String? mediaPath;

  /// Mode 4 : le navigateur doit passer par le remux.
  final bool? remux;

  /// Appelé quand un invité s'est présenté (adresse IP distante incluse).
  final void Function(HelloMsg hello, String? address)? onGuestHello;

  final void Function()? onGuestLeft;

  final Future<void> Function()? onDetach;

  Future<void> detach() async => onDetach?.call();
}

/// Ce que la session invitée met à disposition des modes.
class GuestContext {
  const GuestContext({
    required this.localNowMs,
    required this.expectedPositionAt,
  });

  final int Function() localNowMs;

  /// Position attendue (ms) à une heure locale donnée ; null en pause ou
  /// tant que l'état / l'horloge ne sont pas prêts.
  final int? Function(int localMs) expectedPositionAt;
}

/// Ressources propres à un mode côté invité (ex. récepteur UDP du mode 3).
class GuestAttachment {
  const GuestAttachment({
    this.audioPort,
    this.control,
    this.onStart,
    this.onDetach,
  });

  /// Annoncé à l'hôte dans `hello`.
  final int? audioPort;

  /// Objet de réglage exposé à l'UI (ex. latence audio du mode 3).
  final Object? control;
  final FutureOr<void> Function(GuestContext ctx)? onStart;
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

  /// L'invité utilise-t-il l'app (faux en mode 4 : navigateur) ?
  bool get guestUsesApp => true;

  /// L'invité affiche-t-il la vidéo (faux en mode 3 : audio seul) ?
  bool get guestShowsVideo => true;

  /// Les empreintes de fichier doivent-elles être comparées au `hello` ?
  bool get checksFingerprint => guestNeedsLocalFile;

  /// Côté hôte : prépare la diffusion (routes HTTP, pipeline audio…).
  Future<HostAttachment> attachHost(HostContext ctx);

  /// Côté invité, avant la connexion : ressources du mode (port UDP…).
  Future<GuestAttachment> prepareGuest() async => const GuestAttachment();

  /// Côté invité, après réception du `hello` de l'hôte : source à ouvrir
  /// dans le lecteur local (chemin/URI local en mode 1, URL HTTP en mode 2…).
  Future<String> resolveGuestSource({
    required SessionEndpoint endpoint,
    required HelloMsg hostHello,
    MediaRef? localMedia,
  });
}
