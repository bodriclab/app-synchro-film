import 'playback_state.dart';
import 'protocol.dart';

/// Arbitre côté hôte : applique les commandes des deux pairs dans l'ordre
/// de réception, horodatées sur l'horloge hôte (la dernière gagne), et
/// produit le nouvel état de référence à rediffuser.
class PlaybackArbiter {
  PlaybackArbiter(this._hostNowMs, {PlaybackState? initial})
    : _state = initial ?? const PlaybackState.initial();

  final int Function() _hostNowMs;
  PlaybackState _state;

  /// Durée du média (sert à borner les seek et la position).
  int? durationMs;

  PlaybackState get state => _state;

  /// Position de référence actuelle.
  int get currentPositionMs =>
      _state.positionAt(_hostNowMs(), durationMs: durationMs);

  /// Applique [cmd] et retourne le nouvel état.
  PlaybackState apply(CmdMsg cmd) {
    final now = _hostNowMs();
    final current = _state.positionAt(now, durationMs: durationMs);
    final seq = _state.seq + 1;
    switch (cmd.action) {
      case CommandAction.play:
        _state = PlaybackState(
          playing: true,
          positionMs: _isAtEnd(current) ? 0 : current,
          atHostMs: now,
          seq: seq,
        );
      case CommandAction.pause:
        _state = PlaybackState(
          playing: false,
          positionMs: current,
          atHostMs: now,
          seq: seq,
        );
      case CommandAction.seek:
        _state = PlaybackState(
          playing: _state.playing,
          positionMs: _clamp(cmd.positionMs ?? current),
          atHostMs: now,
          seq: seq,
        );
    }
    return _state;
  }

  /// Si la lecture a atteint la fin, passe en pause à la fin.
  /// Retourne le nouvel état si quelque chose a changé.
  PlaybackState? checkEnd() {
    if (!_state.playing) return null;
    final now = _hostNowMs();
    final current = _state.positionAt(now, durationMs: durationMs);
    if (!_isAtEnd(current)) return null;
    _state = PlaybackState(
      playing: false,
      positionMs: current,
      atHostMs: now,
      seq: _state.seq + 1,
    );
    return _state;
  }

  bool _isAtEnd(int pos) =>
      durationMs != null && durationMs! > 0 && pos >= durationMs!;

  int _clamp(int pos) {
    if (pos < 0) return 0;
    if (durationMs != null && durationMs! > 0 && pos > durationMs!) {
      return durationMs!;
    }
    return pos;
  }
}
