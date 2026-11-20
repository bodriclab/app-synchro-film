# App Synchro Film

Application légère **Android + Windows** (Flutter + media_kit) pour regarder un film synchronisé à deux, en Wi-Fi local, **sans Internet** (même Wi-Fi ou partage de connexion).

| Mode | État |
|---|---|
| 1. Synchro double fichier | ✅ implémenté |
| 2. Stream app ↔ app (HTTP progressif) | 🚧 point d'extension prêt (`lib/modes/stream_mode.dart`) |
| 3. Audio seul vers écouteurs (Opus/UDP) | 🚧 point d'extension prêt (`lib/modes/audio_only_mode.dart`) |
| 4. Stream vers navigateur | 🚧 point d'extension prêt (`lib/modes/browser_mode.dart`) |

Architecture détaillée : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Utilisation (mode 1)

1. Les deux appareils sont sur le même réseau local (Wi-Fi ou partage de connexion de l'un d'eux ; Internet inutile).
2. **Hôte** : *Créer une session* → choisir le film. Un QR code et l'adresse `IP:port` + code s'affichent ; la session est aussi annoncée en mDNS.
3. **Invité** : *Rejoindre* → choisir **sa copie** du même film → toucher la session trouvée automatiquement, ou *Scanner le QR code* (Android), ou saisie manuelle `IP:port` + code (Windows).
4. Les deux peuvent faire lecture/pause/±10 s/déplacer la barre ; l'hôte arbitre. Un bandeau prévient si les deux fichiers diffèrent (taille + hash partiel).

Raccourcis clavier (Windows) : `Espace` lecture/pause, `←`/`→` ±10 s.

## Construire et lancer

Prérequis : [Flutter](https://docs.flutter.dev/get-started/install) stable (testé avec 3.47, Dart 3.13).

```bash
flutter pub get
flutter analyze
flutter test                     # logique horloge / correction douce / protocole / sessions

# Android (SDK Android + JDK 17)
flutter run -d <appareil-android>
flutter build apk --release      # build/app/outputs/flutter-apk/app-release.apk

# Windows (sur un PC Windows avec Visual Studio 2022, charge « Desktop C++ »)
flutter run -d windows
flutter build windows --release  # build/windows/x64/runner/Release/
```

Notes :
- **Windows** : au premier lancement en hôte, autoriser l'app dans le pare-feu Windows (réseaux privés), sinon l'invité ne peut pas se connecter. La découverte mDNS utilise l'API DNS-SD de Windows 10+.
- **Partage de connexion** : certains téléphones filtrent le multicast ; la session n'apparaît alors pas automatiquement → utiliser le QR code ou la saisie manuelle.
- Port par défaut : **47470/TCP** (repli automatique sur un port libre s'il est occupé).

## Structure

```
lib/
  core/     protocole JSON (hello/ping/pong/state/cmd), horloge NTP (médiane de 8),
            état de lecture, arbitre hôte, empreinte de fichier, URI de session — Dart pur
  net/      serveur WebSocket hôte (+ routes HTTP pour modes 2/4), mDNS, IP locales,
            session/ : HostSession, GuestSession
  player/   PlaybackEngine (abstraction), MediaKitEngine, SoftCorrector, SyncController
  modes/    ModeHandler + mode 1 (double fichier) + squelettes modes 2–4
  ui/       accueil, hôte (QR), invité (mDNS/QR/saisie), lecteur
test/       tests unitaires (Dart pur) + test d'intégration hôte/invité sur localhost
```

### Synchro

- **Horloge** : l'invité envoie `ping{t0}`, l'hôte répond `pong{t0,t1,t2}` ; offset = médiane des 8 derniers échanges (pings rapprochés au début, puis toutes les 10 s).
- **État** : l'hôte diffuse `state{playing, position, rate, at}` (ancré sur son horloge) à chaque changement et toutes les 2 s.
- **Commandes** : chaque pair envoie `cmd{play|pause|seek}` ; l'hôte les applique dans l'ordre reçu (la dernière gagne) et rediffuse `state`.
- **Correction douce** (des deux côtés, sur la même timeline) : écart < 40 ms → rien ; 40 ms–1 s → vitesse ±2 % jusqu'à ≤ 15 ms (hystérésis) ; > 1 s → seek (puis 1,5 s sans correction).

## Limites / TODO

- Modes 2, 3 et 4 non implémentés (interfaces et TODO en place).
- **Android, gros fichiers** : `file_picker` copie le fichier choisi dans le cache de l'app (lent et coûteux en stockage pour un film de plusieurs Go). À remplacer par une lecture directe de l'URI `content://` (media_kit la supporte) + calcul d'empreinte via un petit plugin natif.
- Le **token** de session circule en clair dans le TXT mDNS : suffisant sur un hotspot privé ; prévoir un appairage par code si besoin.
- Pas encore de **reconnexion automatique** de l'invité ni de **service au premier plan** Android pour l'hôte (écran éteint).
- La précision dépend de la fréquence de mise à jour de la position par libmpv ; à valider sur appareils réels (objectif < 50 ms).
- Pas de build Windows vérifié ici (nécessite un PC Windows).
