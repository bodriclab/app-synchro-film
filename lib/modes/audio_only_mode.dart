import '../core/session_endpoint.dart';
import '../core/session_mode.dart';
import '../net/host_server.dart';
import 'mode_handler.dart';

/// Mode 3 — Stream audio seul, écran partagé (NON IMPLÉMENTÉ).
///
/// TODO(mode3) :
/// - Hôte : extraire la piste audio décodée, l'encoder en Opus (trames de
///   20 ms) et l'envoyer en UDP (plugin natif dans `native/`).
/// - Invité : buffer de gigue adaptatif → décodage Opus → sortie audio,
///   pas de vidéo.
/// - Compensation Bluetooth : latence de sortie rapportée par l'OS
///   (AudioManager / WASAPI) + curseur manuel −500…+500 ms, mémorisé par
///   appareil de sortie. Le décalage s'ajoute à la position attendue dans
///   `SyncController` (prévoir un `outputLatencyMs`).
class AudioOnlyMode extends ModeHandler {
  const AudioOnlyMode();

  @override
  SessionMode get mode => SessionMode.audioOnly;

  @override
  String get title => 'Audio seul (écran partagé)';

  @override
  String get subtitle => 'Un écran, chacun ses écouteurs Bluetooth';

  @override
  bool get isImplemented => false;

  @override
  bool get guestNeedsLocalFile => false;

  @override
  Future<String> attachHost({
    required HostServer server,
    required String filePath,
  }) =>
      throw UnimplementedError('Mode 3 (audio seul) pas encore implémenté');

  @override
  Future<String> resolveGuestSource({
    required SessionEndpoint endpoint,
    String? localFilePath,
  }) =>
      throw UnimplementedError('Mode 3 (audio seul) pas encore implémenté');
}
