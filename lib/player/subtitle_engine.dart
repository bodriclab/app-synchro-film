import '../core/subtitles.dart';

/// Lecteur capable d'afficher des sous-titres (media_kit ; doublure de test).
abstract interface class SubtitleEngine {
  /// Pistes de sous-titres intégrées au fichier, dans l'ordre du fichier.
  Future<List<SubtitleSelection>> embeddedSubtitles();

  /// Affiche [selection] ; [text] = contenu du fichier externe.
  Future<void> showSubtitle(SubtitleSelection selection, {String? text});
}
