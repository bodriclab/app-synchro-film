import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

import '../core/constants.dart';
import '../core/session_endpoint.dart';
import '../core/session_mode.dart';

/// Annonce / découverte mDNS (`_synchrofilm._tcp`) via le plugin `nsd`
/// (NsdManager sous Android, DNS-SD sous Windows).
///
/// Sur certains partages de connexion le multicast est filtré : le QR code
/// reste alors le moyen de connexion (cf. ARCHITECTURE §5).
abstract interface class SessionAnnouncer {
  Future<void> start({
    required String name,
    required int port,
    required String token,
    required SessionMode mode,
  });

  Future<void> stop();
}

class NsdSessionAnnouncer implements SessionAnnouncer {
  nsd.Registration? _registration;

  @override
  Future<void> start({
    required String name,
    required int port,
    required String token,
    required SessionMode mode,
  }) async {
    await stop();
    _registration = await nsd.register(
      nsd.Service(
        name: name,
        type: kServiceType,
        port: port,
        txt: {
          'v': _utf8('$kProtocolVersion'),
          'mode': _utf8(mode.wireName),
          // Le token voyage en clair sur le LAN : acceptable sur un hotspot
          // privé ; voir TODO (appairage par code) dans le README.
          'token': _utf8(token),
        },
      ),
    );
  }

  @override
  Future<void> stop() async {
    final r = _registration;
    _registration = null;
    if (r != null) {
      try {
        await nsd.unregister(r);
      } catch (_) {}
    }
  }

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));
}

/// Session trouvée sur le réseau.
class DiscoveredSession {
  const DiscoveredSession({required this.name, required this.endpoint});
  final String name;
  final SessionEndpoint endpoint;
}

/// Écoute les sessions annoncées. [sessions] est mis à jour en continu.
class SessionBrowser {
  final ValueNotifier<List<DiscoveredSession>> sessions = ValueNotifier(
    const [],
  );
  nsd.Discovery? _discovery;

  Future<void> start() async {
    if (_discovery != null) return;
    final discovery = await nsd.startDiscovery(
      kServiceType,
      ipLookupType: nsd.IpLookupType.v4,
    );
    _discovery = discovery;
    discovery.addListener(
      () =>
          sessions.value = [for (final s in discovery.services) ?_toSession(s)],
    );
  }

  Future<void> stop() async {
    final d = _discovery;
    _discovery = null;
    if (d != null) {
      try {
        await nsd.stopDiscovery(d);
      } catch (_) {}
    }
  }

  void dispose() {
    stop();
    sessions.dispose();
  }

  static DiscoveredSession? _toSession(nsd.Service s) {
    final port = s.port;
    final token = _txt(s, 'token');
    if (port == null || token == null) return null;
    final ip = s.addresses
        ?.where((a) => a.type == InternetAddressType.IPv4)
        .map((a) => a.address)
        .firstOrNull;
    final host = ip ?? s.host;
    if (host == null) return null;
    return DiscoveredSession(
      name: s.name ?? host,
      endpoint: SessionEndpoint(
        host: host,
        port: port,
        token: token,
        mode: SessionMode.fromWire(_txt(s, 'mode')),
      ),
    );
  }

  static String? _txt(nsd.Service s, String key) {
    final bytes = s.txt?[key];
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }
}
