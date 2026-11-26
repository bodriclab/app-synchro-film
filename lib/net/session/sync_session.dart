import 'package:flutter/foundation.dart';

import '../../core/session_mode.dart';
import '../../core/subtitles.dart';
import '../../modes/mode_handler.dart';
import '../../player/playback_engine.dart';
import '../../player/subtitle_engine.dart';
import '../../player/sync_controller.dart';

enum SessionStatus {
  idle,
  starting,
  waitingForGuest,
  connecting,
  connected,
  disconnected,
  error,
}

/// Interface commune hôte / invité utilisée par l'écran de lecture.
abstract class SyncSession extends ChangeNotifier {
  SyncSession({required this.engine, required this.mode});

  final PlaybackEngine engine;
  final ModeHandler mode;

  SyncController get controller;

  bool get isHost;

  SessionMode get sessionMode => mode.mode;

  SessionStatus _status = SessionStatus.idle;
  SessionStatus get status => _status;

  String? _peerName;
  String? get peerName => _peerName;

  /// Les deux fichiers sont-ils identiques ? null si inconnu / non applicable.
  bool? _fileMatch;
  bool? get fileMatch => _fileMatch;

  String? _error;
  String? get error => _error;

  /// RTT réseau médian (invité uniquement).
  int? get rttMs => null;

  @protected
  void update({
    SessionStatus? status,
    String? peerName,
    bool? fileMatch,
    String? error,
    bool clearPeer = false,
  }) {
    if (status != null) _status = status;
    if (peerName != null) _peerName = peerName;
    if (fileMatch != null) _fileMatch = fileMatch;
    if (error != null) _error = error;
    if (clearPeer) {
      _peerName = null;
      _fileMatch = null;
    }
    notifyListeners();
  }

  bool get isPlaying => controller.target?.playing ?? false;

  Future<void> play();

  Future<void> pause();

  Future<void> seekTo(int positionMs);

  Future<void> togglePlay() => isPlaying ? pause() : play();

  Future<void> seekBy(int deltaMs) {
    final current = controller.expectedPositionMs() ?? engine.positionMs;
    final target = current + deltaMs;
    return seekTo(target < 0 ? 0 : target);
  }

  // ---------- Sous-titres ----------
  SubtitleSelection _subtitle = const SubtitleSelection.off();

  /// Sous-titres affichés sur cet appareil.
  SubtitleSelection get subtitle => _subtitle;

  /// Pistes intégrées du film (vide si le lecteur ne gère pas les sous-titres).
  Future<List<SubtitleSelection>> embeddedSubtitles() async {
    final Object e = engine;
    return e is SubtitleEngine ? e.embeddedSubtitles() : const [];
  }

  /// Affiche [selection] localement. L'hôte le transmet en plus à l'invité
  /// (voir [HostSession]). [text] : contenu d'un fichier externe.
  Future<void> selectSubtitle(SubtitleSelection selection, {String? text}) =>
      applySubtitle(selection, text: text);

  @protected
  Future<void> applySubtitle(
    SubtitleSelection selection, {
    String? text,
  }) async {
    _subtitle = selection;
    notifyListeners();
    final Object e = engine;
    if (e is SubtitleEngine) {
      try {
        await e.showSubtitle(selection, text: text);
      } catch (_) {
        // piste illisible : la lecture continue sans sous-titres
      }
    }
  }

  Future<void> close();
}
