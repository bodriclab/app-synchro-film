import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/audio_gain.dart';
import '../../platform/audio/output_latency.dart';
import '../../platform/settings_store.dart';
import 'audio_guest_player.dart';

/// Réglages audio de l'invité du mode 3, exposés à l'UI : sortie active,
/// latence auto, curseur manuel (−500…+500 ms) mémorisé par sortie.
class AudioLatencyControl extends ChangeNotifier {
  AudioLatencyControl({
    Future<AudioOutputInfo> Function()? outputInfo,
    LatencyOffsetStore? store,
    SettingsStore? settings,
    this.refreshEvery = const Duration(seconds: 5),
  }) : _outputInfo = outputInfo ?? currentAudioOutput,
       _store = store ?? LatencyOffsetStore(),
       _settings = settings ?? SettingsStore.instance;

  final Future<AudioOutputInfo> Function() _outputInfo;
  final LatencyOffsetStore _store;
  final SettingsStore _settings;
  static const String gainKey = 'audioOnly.gain';
  final Duration refreshEvery;

  AudioOutputInfo _output = AudioOutputInfo.fallback;
  int _manualMs = 0;
  Timer? _timer;
  AudioGuestPlayer? _player;
  double _gain = 1.0;

  AudioGuestPlayer? get player => _player;
  set player(AudioGuestPlayer? p) {
    _player = p;
    p?.gain = _gain;
  }

  /// Volume de l'invité (1.0 = 100 %), mémorisé.
  double get gain => _gain;

  Future<void> setGain(double g) async {
    _gain = g.clamp(kMinGain, kMaxGain);
    _player?.gain = _gain;
    notifyListeners();
    await _settings.set(gainKey, _gain);
  }

  AudioOutputInfo get output => _output;
  int get manualMs => _manualMs;
  int get autoMs => _output.autoLatencyMs;

  /// Latence totale compensée.
  int get totalMs => (autoMs + _manualMs).clamp(0, 2000);

  Future<void> start() async {
    _gain = (await _settings.getDouble(gainKey, 1.0)).clamp(kMinGain, kMaxGain);
    _player?.gain = _gain;
    await refresh();
    _timer = Timer.periodic(refreshEvery, (_) => refresh());
  }

  /// Relit la sortie active (ex. écouteurs Bluetooth connectés en cours).
  Future<void> refresh() async {
    final info = await _outputInfo();
    final changed = info.id != _output.id || info.autoLatencyMs != autoMs;
    if (info.id != _output.id) _manualMs = await _store.get(info.id);
    _output = info;
    if (changed) notifyListeners();
  }

  Future<void> setManual(int ms) async {
    _manualMs = ms.clamp(LatencyOffsetStore.minMs, LatencyOffsetStore.maxMs);
    notifyListeners();
    await _store.set(_output.id, _manualMs);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
