import 'dart:io';

/// Adresses IPv4 locales utilisables pour le QR code, triées par
/// pertinence (réseaux privés d'abord, interfaces Wi-Fi / hotspot en tête).
Future<List<String>> localIPv4Addresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  final scored = <(int, String)>[];
  for (final iface in interfaces) {
    for (final addr in iface.addresses) {
      scored.add((_score(iface.name, addr.address), addr.address));
    }
  }
  scored.sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final s in scored) s.$2];
}

int _score(String ifaceName, String ip) {
  var score = 0;
  if (isPrivateIPv4(ip)) score += 10;
  if (ip.startsWith('169.254.')) score -= 20; // lien local sans DHCP
  final name = ifaceName.toLowerCase();
  // Android : wlan0 (client), ap0 / swlan0 / wlan1 (partage de connexion).
  // Windows : « Wi-Fi », « Connexion au réseau local* N » (point d'accès mobile).
  if (name.contains('wlan') ||
      name.contains('wi-fi') ||
      name.contains('wifi') ||
      name.startsWith('ap') ||
      name.contains('local')) {
    score += 5;
  }
  if (name.contains('rmnet') || name.contains('ccmni')) score -= 15; // mobile
  if (name.contains('vethernet') || name.contains('virtual')) score -= 5;
  return score;
}

bool isPrivateIPv4(String ip) {
  final parts = ip.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null)) return false;
  final a = parts[0]!, b = parts[1]!;
  return a == 10 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168);
}
