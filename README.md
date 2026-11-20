# App Synchro Film

Application légère **Android + Windows** (Flutter + media_kit) pour regarder un film synchronisé à deux, en Wi-Fi local, **sans Internet** (même Wi-Fi ou partage de connexion).

| Mode | État |
|---|---|
| 1. Synchro double fichier | ✅ implémenté |
| 2. Stream app ↔ app (HTTP progressif) | ✅ implémenté |
| 3. Audio seul vers écouteurs (Opus/UDP) | ✅ implémenté (v0.3.0, à valider sur appareils) |
| 4. Stream vers navigateur (+ remux MKV → MP4) | ✅ implémenté (v0.3.0) |

Architecture détaillée : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Installation (Android)

Les APK sont publiés dans les **[Releases GitHub](https://github.com/bodriclab/app-synchro-film/releases)** (dépôt privé : être connecté à GitHub).

1. Ouvrir la dernière release (ex. `v0.3.0`, pré-version de test) sur le téléphone.
2. Télécharger **`app-arm64-v8a-release.apk`** (presque tous les téléphones récents ; `armeabi-v7a` pour les très anciens, `x86_64` pour les émulateurs).
3. Ouvrir le fichier et autoriser « Installer des applis inconnues » pour le navigateur / le gestionnaire de fichiers.

Les APK de test sont signés avec la clé *debug* : pour passer à une future version signée avec une vraie clé, il faudra désinstaller l'app d'abord.
Windows : pas encore de binaire publié, voir *Construire et lancer*.

## Utilisation (mode 1)

1. Les deux appareils sont sur le même réseau local (Wi-Fi ou partage de connexion de l'un d'eux ; Internet inutile).
2. **Hôte** : *Créer une session* → choisir le film. Un QR code et l'adresse `IP:port` + code s'affichent ; la session est aussi annoncée en mDNS.
3. **Invité** : *Rejoindre* → choisir **sa copie** du même film → toucher la session trouvée automatiquement, ou *Scanner le QR code* (Android), ou saisie manuelle `IP:port` + code (Windows).
4. Les deux peuvent faire lecture/pause/±10 s/déplacer la barre ; l'hôte arbitre. Un bandeau prévient si les deux fichiers diffèrent (taille + hash partiel).

## Utilisation (mode 2 — stream app ↔ app)

Seul l'hôte a le film. Choisir *Stream app ↔ app* sur l'accueil, puis même procédure que le mode 1, sans choix de fichier côté invité : l'invité lit le film directement depuis l'hôte (`GET /media/{id}?token=…`, requêtes `Range`, aucun réencodage ni copie). La synchro est la même qu'en mode 1.

## Utilisation (mode 3 — audio seul, écran partagé)

Un seul écran (l'hôte : PC ou téléphone sur une TV) ; l'invité écoute la bande-son dans **ses écouteurs** (Bluetooth ou filaire).
1. **Hôte** : *Audio seul* → choisir le film → QR code. L'hôte garde l'image et son propre son.
2. **Invité** : *Rejoindre* (aucun fichier à choisir) → session ou QR. L'écran invité affiche les commandes et un réglage **Décalage audio**.
3. La latence de sortie est compensée automatiquement (Android : latence rapportée par l'OS, sinon estimation par type de sortie — Bluetooth ≈ 200 ms). Si le son est en avance/retard sur l'image, ajuster le curseur **−500…+500 ms** : il est **mémorisé par sortie** (ex. un réglage par casque Bluetooth).

Technique : l'hôte décode la piste audio avec FFmpeg (PCM 48 kHz stéréo, à partir de la position de lecture), l'encode en **Opus, trames de 20 ms**, et l'envoie en **UDP** (en-tête 16 octets : époque, n° de séquence, position) ~1,2 s en avance. L'invité : buffer de gigue indexé par position, masquage de perte Opus (PLC) sur trame manquante, sortie miniaudio (AAudio/OpenSL sous Android, WASAPI sous Windows) ; chaque trame est poussée pour être *entendue* quand la timeline de l'hôte l'atteint (latence de sortie incluse) ; resynchronisation au-delà de 40 ms d'écart.

## Utilisation (mode 4 — vers un navigateur)

L'invité n'installe rien : n'importe quel navigateur (TV, tablette, PC, iPhone…) sur le même réseau.
1. **Hôte** : *Navigateur* → choisir le film. Le QR code encode directement `http://IP:port/?token=…` (lien aussi affiché).
2. **Invité** : scanner le QR avec l'appareil photo (ou taper le lien) → la page se synchronise toute seule. Si le navigateur bloque la lecture automatique, toucher *Activer la lecture*.
3. Lecture/pause/saut depuis la page ou l'app ; l'hôte arbitre.

La page (HTML/JS/CSS embarqués dans l'app, **aucun CDN**, 100 % hors-ligne) refait la synchro en JS : horloge NTP (médiane de 8 via WebSocket), correction douce par `playbackRate` (±2 %), saut au-delà de 1 s, avec compensation apprise du délai de démarrage/saut.
**Conteneurs non lisibles** (MKV, AVI…) : l'hôte **réemballe à la volée** en MP4 fragmenté avec FFmpeg (`-c:v copy`, aucun réencodage vidéo ; audio AC3/DTS… converti en AAC si le navigateur ne le lit pas). Intégration : [`ffmpeg_kit_flutter_new_min`](https://pub.dev/packages/ffmpeg_kit_flutter_new_min) (Android + Windows), sortie via socket TCP locale. Le flux réemballé n'est pas « seekable » : un saut relance la conversion à partir de l'image clé la plus proche (image figée quelques instants).

Raccourcis clavier (Windows) : `Espace` lecture/pause, `←`/`→` ±10 s.

## Construire et lancer

Prérequis : [Flutter](https://docs.flutter.dev/get-started/install) stable (testé avec 3.47, Dart 3.13).

```bash
flutter pub get
flutter analyze
flutter test                     # logique + sessions + modes 3/4 (FFmpeg et libopus requis pour certains tests,
                                 # Chrome pour le test navigateur de bout en bout ; sinon ignorés)

# Android (SDK Android + JDK 17)
flutter run -d <appareil-android>
flutter build apk --release --split-per-abi   # build/app/outputs/flutter-apk/app-<abi>-release.apk

# Windows (sur un PC Windows avec Visual Studio 2022, charge « Desktop C++ »)
flutter run -d windows
flutter build windows --release  # build/windows/x64/runner/Release/
```

Notes :
- **Windows** : au premier lancement en hôte, autoriser l'app dans le pare-feu Windows (réseaux privés), sinon l'invité ne peut pas se connecter. La découverte mDNS utilise l'API DNS-SD de Windows 10+.
- **Partage de connexion** : certains téléphones filtrent le multicast ; la session n'apparaît alors pas automatiquement → utiliser le QR code ou la saisie manuelle.
- Port par défaut : **47470/TCP** (repli automatique sur un port libre s'il est occupé) ; mode 3 : un port **UDP** libre choisi par l'invité.

## Structure

```
lib/
  core/     protocole JSON (hello/ping/pong/state/cmd), horloge NTP (médiane de 8),
            état de lecture, arbitre hôte, empreinte de fichier, URI de session,
            paquets audio, buffer de gigue, planification audio, arguments FFmpeg — Dart pur
  net/      serveur WebSocket hôte, HTTP média (Range), remux, page web, UDP audio,
            mDNS, IP locales ; session/ : HostSession, GuestSession
  player/   PlaybackEngine (abstraction), MediaKitEngine, VirtualEngine, SoftCorrector, SyncController
  modes/    ModeHandler + modes 1 à 4 ; audio/ : streamer hôte, lecteur invité, réglage latence
  platform/ médias (fichiers / content:// Android), FFmpeg (ffmpeg-kit ou exécutable), Opus,
            sortie PCM, latence de sortie (MethodChannel Kotlin)
  ui/       accueil, hôte (QR), invité (mDNS/QR/saisie), lecteur
web_client/ page du mode 4 (index.html, app.js, app.css), embarquée comme asset
test/       tests unitaires + intégration hôte/invité sur localhost (modes 1–4) + Chrome headless
```

### Synchro

- **Horloge** : l'invité envoie `ping{t0}`, l'hôte répond `pong{t0,t1,t2}` ; offset = médiane des 8 derniers échanges (pings rapprochés au début, puis toutes les 10 s).
- **État** : l'hôte diffuse `state{playing, position, rate, at}` (ancré sur son horloge) à chaque changement et toutes les 2 s.
- **Commandes** : chaque pair envoie `cmd{play|pause|seek}` ; l'hôte les applique dans l'ordre reçu (la dernière gagne) et rediffuse `state`.
- **Correction douce** (des deux côtés, sur la même timeline) : écart < 40 ms → rien ; 40 ms–1 s → vitesse ±2 % jusqu'à ≤ 15 ms (hystérésis) ; > 1 s → seek (puis 1,5 s sans correction).

## Limites / TODO

- **Modes 3 et 4 : testés sur PC (localhost, Chrome headless, FFmpeg/libopus système), pas encore sur de vrais téléphones/TV.**
- **Mode 3** : un seul invité ; latence auto sous Android uniquement (API cachée `AudioManager.getOutputLatency`, sinon estimation par type de sortie) ; **sous Windows, réglage manuel seul** (WASAPI non branché). La précision Bluetooth réelle dépend du casque : ajuster le curseur. Le son de l'hôte n'est pas coupé.
- **Mode 4** : codecs limités à ceux du navigateur (H.264/AAC partout ; HEVC/AV1 selon l'appareil — pas de réencodage vidéo). En flux réemballé (MKV…), un saut recharge le flux (image figée ~1–3 s) et l'écart initial est résorbé par la vitesse ±2 % (quelques secondes). Un seul navigateur à la fois. Safari iOS : lecture automatique souvent bloquée → bouton *Activer la lecture*.
- **Taille** : FFmpeg (ffmpeg-kit « min ») et libopus ajoutent ~10–15 Mo par APK.
- **Android, fournisseurs non « seekables »** : les films sont lus via leur URI `content://` d'origine (sélecteur système, aucune copie). Les rares fournisseurs qui ne donnent qu'un flux (certains clouds) ne sont pas gérés : choisir un fichier stocké sur le téléphone.
- **Mode 2** : un seul invité ; débit limité par le Wi-Fi (un film 4K à fort débit peut saccader sur un hotspot faible) ; pas de reprise automatique si l'hôte coupe le réseau.
- Le **token** de session circule en clair dans le TXT mDNS : suffisant sur un hotspot privé ; prévoir un appairage par code si besoin.
- Pas encore de **reconnexion automatique** de l'invité ni de **service au premier plan** Android pour l'hôte (écran éteint).
- La précision dépend de la fréquence de mise à jour de la position par libmpv ; à valider sur appareils réels (objectif < 50 ms).
- Pas de build Windows vérifié ici (nécessite un PC Windows) ; ffmpeg-kit Windows et mp_audio_stream/opus non testés sous Windows.
