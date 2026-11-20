/// Constantes partagées par toute l'application.
library;

/// Type de service mDNS annoncé par l'hôte.
const String kServiceType = '_synchrofilm._tcp';

/// Schéma des URI de session encodées dans le QR code.
const String kUriScheme = 'synchrofilm';

/// Port TCP par défaut (WebSocket + futur serveur HTTP des modes 2 et 4).
/// Si le port est occupé, l'hôte retombe sur un port libre choisi par l'OS.
const int kDefaultPort = 47470;

/// Chemin du point d'entrée WebSocket sur le serveur hôte.
const String kWsPath = '/ws';

/// Version du protocole de synchro (champ `v` du message `hello`).
const int kProtocolVersion = 1;

/// Intervalle de diffusion périodique de `state` par l'hôte.
const Duration kStateBroadcastInterval = Duration(seconds: 2);

/// Nombre d'échantillons ping/pong conservés (filtrage médian).
const int kClockWindow = 8;

/// Espacement des pings tant que l'horloge n'a pas convergé.
const Duration kPingIntervalFast = Duration(milliseconds: 150);

/// Espacement des pings une fois l'horloge convergée (économie batterie).
const Duration kPingIntervalSlow = Duration(seconds: 10);

/// Période de la boucle de correction douce.
const Duration kCorrectionTick = Duration(milliseconds: 250);
