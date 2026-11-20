import '../core/media_source.dart';
import '../core/protocol.dart';
import '../core/session_endpoint.dart';
import '../core/session_mode.dart';
import '../net/host_server.dart';
import 'mode_handler.dart';

/// Mode 1 — Synchro double fichier.
///
/// Chaque appareil lit son propre exemplaire du fichier ; seules les
/// commandes et l'état transitent sur le WebSocket. L'identité des deux
/// fichiers est vérifiée au `hello` (taille + hash partiel).
class DoubleFileMode extends ModeHandler {
  const DoubleFileMode();

  @override
  SessionMode get mode => SessionMode.doubleFile;

  @override
  String get title => 'Synchro double fichier';

  @override
  String get subtitle => 'Chacun a le même fichier, la lecture est synchronisée';

  @override
  bool get isImplemented => true;

  @override
  bool get guestNeedsLocalFile => true;

  @override
  Future<HostAttachment> attachHost({
    required HostServer server,
    required MediaRef media,
    required MediaOpener opener,
  }) async =>
      HostAttachment(localSource: media.uri);

  @override
  Future<String> resolveGuestSource({
    required SessionEndpoint endpoint,
    required HelloMsg hostHello,
    MediaRef? localMedia,
  }) async {
    if (localMedia == null) {
      throw StateError('Le mode double fichier exige un fichier local.');
    }
    return localMedia.uri;
  }
}
