import 'dart:convert';

import 'constants.dart';
import 'file_fingerprint.dart';
import 'playback_state.dart';
import 'session_mode.dart';

/// Erreur de décodage d'un message du protocole.
class ProtocolException implements Exception {
  ProtocolException(this.message);
  final String message;
  @override
  String toString() => 'ProtocolException: $message';
}

/// Rôle d'un pair dans la session.
enum PeerRole { host, guest }

/// Actions de lecture que peut demander n'importe quel pair.
enum CommandAction { play, pause, seek }

/// Messages JSON échangés sur le WebSocket : `hello`, `ping`, `pong`,
/// `state`, `cmd` (+ `error`). Le champ `type` discrimine le message.
sealed class SyncMessage {
  const SyncMessage();

  String get type;

  Map<String, dynamic> toJson();

  String encode() => jsonEncode({'type': type, ...toJson()});

  static SyncMessage decode(String raw) {
    final Object? data;
    try {
      data = jsonDecode(raw);
    } on FormatException catch (e) {
      throw ProtocolException('JSON invalide : ${e.message}');
    }
    if (data is! Map<String, dynamic>) {
      throw ProtocolException('objet JSON attendu');
    }
    try {
      switch (data['type']) {
        case HelloMsg.kType:
          return HelloMsg.fromJson(data);
        case PingMsg.kType:
          return PingMsg((data['t0'] as num).toInt());
        case PongMsg.kType:
          return PongMsg(
            t0: (data['t0'] as num).toInt(),
            t1: (data['t1'] as num).toInt(),
            t2: (data['t2'] as num).toInt(),
          );
        case StateMsg.kType:
          return StateMsg(
            PlaybackState.fromJson(data['state'] as Map<String, dynamic>),
          );
        case CmdMsg.kType:
          return CmdMsg.fromJson(data);
        case ErrorMsg.kType:
          return ErrorMsg(
            data['code'] as String,
            data['message'] as String? ?? '',
          );
        default:
          throw ProtocolException('type inconnu : ${data['type']}');
      }
    } on ProtocolException {
      rethrow;
    } catch (e) {
      throw ProtocolException('message ${data['type']} mal formé : $e');
    }
  }
}

/// Présentation mutuelle à la connexion.
class HelloMsg extends SyncMessage {
  const HelloMsg({
    required this.role,
    required this.deviceName,
    required this.mode,
    this.version = kProtocolVersion,
    this.fingerprint,
    this.durationMs,
    this.fileMatch,
    this.mediaPath,
  });

  static const kType = 'hello';

  final PeerRole role;
  final int version;
  final String deviceName;
  final SessionMode mode;

  /// Empreinte du fichier local (mode 1), null sinon.
  final FileFingerprint? fingerprint;

  /// Durée du média si connue.
  final int? durationMs;

  /// Renseigné par l'hôte dans sa réponse : les empreintes correspondent-elles ?
  final bool? fileMatch;

  /// Chemin HTTP du média servi par l'hôte (mode 2), ex. `/media/ab12cd`.
  final String? mediaPath;

  @override
  String get type => kType;

  @override
  Map<String, dynamic> toJson() => {
        'v': version,
        'role': role.name,
        'name': deviceName,
        'mode': mode.wireName,
        if (fingerprint != null) 'fingerprint': fingerprint!.toJson(),
        if (durationMs != null) 'duration': durationMs,
        if (fileMatch != null) 'fileMatch': fileMatch,
        if (mediaPath != null) 'media': mediaPath,
      };

  static HelloMsg fromJson(Map<String, dynamic> json) => HelloMsg(
        version: (json['v'] as num).toInt(),
        role: PeerRole.values.byName(json['role'] as String),
        deviceName: json['name'] as String? ?? '?',
        mode: SessionMode.fromWire(json['mode'] as String?),
        fingerprint: FileFingerprint.fromJson(json['fingerprint']),
        durationMs: (json['duration'] as num?)?.toInt(),
        fileMatch: json['fileMatch'] as bool?,
        mediaPath: json['media'] as String?,
      );
}

/// Ping d'horloge envoyé par l'invité (t0 = horloge invité).
class PingMsg extends SyncMessage {
  const PingMsg(this.t0);
  static const kType = 'ping';
  final int t0;
  @override
  String get type => kType;
  @override
  Map<String, dynamic> toJson() => {'t0': t0};
}

/// Réponse de l'hôte : t1 = réception, t2 = émission (horloge hôte).
class PongMsg extends SyncMessage {
  const PongMsg({required this.t0, required this.t1, required this.t2});
  static const kType = 'pong';
  final int t0;
  final int t1;
  final int t2;
  @override
  String get type => kType;
  @override
  Map<String, dynamic> toJson() => {'t0': t0, 't1': t1, 't2': t2};
}

/// État de référence diffusé par l'hôte.
class StateMsg extends SyncMessage {
  const StateMsg(this.state);
  static const kType = 'state';
  final PlaybackState state;
  @override
  String get type => kType;
  @override
  Map<String, dynamic> toJson() => {'state': state.toJson()};
}

/// Commande de lecture émise par n'importe quel pair ; l'hôte arbitre.
class CmdMsg extends SyncMessage {
  const CmdMsg(this.action, {this.positionMs});

  const CmdMsg.play() : this(CommandAction.play);
  const CmdMsg.pause() : this(CommandAction.pause);
  const CmdMsg.seek(int positionMs)
      : this(CommandAction.seek, positionMs: positionMs);

  static const kType = 'cmd';
  final CommandAction action;

  /// Position cible (seek uniquement).
  final int? positionMs;

  @override
  String get type => kType;

  @override
  Map<String, dynamic> toJson() => {
        'action': action.name,
        if (positionMs != null) 'position': positionMs,
      };

  static CmdMsg fromJson(Map<String, dynamic> json) {
    final action = CommandAction.values.byName(json['action'] as String);
    final pos = (json['position'] as num?)?.round();
    if (action == CommandAction.seek && pos == null) {
      throw ProtocolException('seek sans position');
    }
    return CmdMsg(action, positionMs: pos);
  }
}

/// Erreur signalée par un pair (ex. `bad_version`, `busy`).
class ErrorMsg extends SyncMessage {
  const ErrorMsg(this.code, [this.message = '']);
  static const kType = 'error';
  final String code;
  final String message;
  @override
  String get type => kType;
  @override
  Map<String, dynamic> toJson() => {'code': code, 'message': message};
}
