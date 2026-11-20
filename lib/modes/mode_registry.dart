import '../core/session_mode.dart';
import 'audio_only_mode.dart';
import 'browser_mode.dart';
import 'double_file_mode.dart';
import 'mode_handler.dart';
import 'stream_mode.dart';

/// Tous les modes, dans l'ordre d'affichage.
const List<ModeHandler> kAllModes = [
  DoubleFileMode(),
  StreamMode(),
  AudioOnlyMode(),
  BrowserMode(),
];

ModeHandler modeHandlerFor(SessionMode mode) =>
    kAllModes.firstWhere((h) => h.mode == mode);
