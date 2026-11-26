# App Synchro Film

Application légère **Android + Windows** (Flutter + media_kit) pour regarder un film synchronisé à deux, en Wi-Fi local, **sans Internet** (même Wi-Fi ou partage de connexion).

## Nouveautés v0.6.0

- **Plein écran dans le lecteur** : bouton ⛶ (et touche `F`), masquage des bandeaux, commandes auto-masquées après 4 s, paysage immersif (Android) / fenêtre plein écran (Windows).
- **Sous-titres** : gestion des pistes intégrées (SRT, ASS, WebVTT, mov_text) et fichiers externes (`.srt`, `.ass`, `.ssa`, `.vtt` en UTF-8, UTF-16 ou Latin-1). Synchronisation hôte/invité (modes 1, 2 et 4 avec conversion WebVTT). *Note : sous-titres image (PGS, VobSub) non pris en charge.*
- **Envoi rapide de film sans Internet** : partage de fichiers de pair à pair via QR code/lien HTTP, barre de progression, reprise sur coupure et enregistrement dans *Téléchargements/SynchroFilm*.
- **Safari / iOS (mode 4)** : remuxage forcé (étiquette `hvc1` pour le HEVC, conversion audio AAC si nécessaire), support des requêtes `Range` et correction de la synchro audio après un saut.
- **Son plus fort chez l'invité** : downmix 5.1 optimisé pour les dialogues (~ +7,7 dB, limiteur anti-saturation), réglage *Son* dans le lecteur (volume 0–300 %, « Renforcer les dialogues »), volume de l'invité en mode 3 et dans la page du mode 5 (jusqu'à 300 %), mémorisés.

| Mode | État |
|---|---|
| 1. Synchro double fichier | ✅ implémenté |
| 2. Stream app ↔ app (HTTP progressif) | ✅ implémenté |
| 3. Audio seul vers écouteurs (Opus/UDP) | ✅ implémenté (v0.3.0, à valider sur appareils) |
| 4. Stream vers navigateur (+ remux MKV → MP4) | ✅ implémenté (v0.3.0) |
| 5. Audio seul vers navigateur (Web Audio) | ✅ implémenté (v0.4.0) |

Architecture détaillée : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Installation (Android)

Les APK sont publiés dans les **[Releases GitHub](https://github.com/bodriclab/app-synchro-film/releases)** (dépôt public).

1. Ouvrir la dernière release (ex. `v0.6.0`) sur le téléphone.
2. Télécharger **`app-arm64-v8a-release.apk`** (presque tous les téléphones récents ; `armeabi-v7a` pour les très anciens, `x86_64` pour les émulateurs).
3. Ouvrir le fichier et autoriser « Installer des applis inconnues » pour le navigateur / le gestionnaire de fichiers.

Les APK de test sont signés avec la clé *debug* : pour passer à une future version signée avec une vraie clé, il faudra désinstaller l'app d'abord.
Windows : pas encore de binaire publié, voir *Construire et lancer*.

### Mises à jour intégrées (v0.5.0+)

Au démarrage (au plus une fois par jour) et via *À propos → Vérifier les mises à jour*, l'app interroge les releases GitHub (`GET api.github.com/repos/bodriclab/app-synchro-film/releases`, pré-versions comprises ; repli sur le flux `releases.atom` si l'API anonyme est limitée). Si une version plus récente existe, une fenêtre affiche la version et les notes : **Mettre à jour** / **Plus tard** / **Ignorer cette version**.
- **Android** : téléchargement de l'APK de l'ABI de l'appareil (barre de progression) dans le cache de l'app, puis installeur système (FileProvider). Au premier usage, Android demande d'autoriser l'app à « installer des applis inconnues ».
- **Windows** : ouvre la page de la release (ou le binaire Windows s'il y en a un) dans le navigateur.
- **Hors-ligne** : rien ne s'affiche, rien ne bloque.
- ⚠️ Une mise à jour ne s'installe que par-dessus une app **signée avec la même clé** : les APK publiés sont signés avec la clé de build de l'auteur (sauvegardée hors du dépôt). Un APK compilé soi-même avec une autre clé impose de désinstaller d'abord.

## Utilisation (mode 1)

1. Les deux appareils sont sur le même réseau local (Wi-Fi ou partage de connexion de l'un d'eux ; Internet inutile).
2. **Hôte** : *Créer une session* → choisir le film. Un QR code et l'adresse `IP:port` + code s'affichent ; la session est aussi annoncée en mDNS.
3. **Invité** : *Rejoindre* → choisir **sa copie** du même film → toucher la session trouvée automatiquement, ou *Scanner le QR code* (Android), ou saisie manuelle `IP:port` + code (Windows).
4. Les deux peuvent faire lecture/pause/±10 s/déplacer la barre ; l'hôte arbitre. Un bandeau prévient si les deux fichiers diffèrent (taille + hash partiel).

## Utilisation (mode 2 — stream app ↔ app)

Seul l'hôte a le film. Choisir *Stream app ↔ app* sur l'accueil, puis même procédure que le mode 1, sans choix de fichier côté invité : l'invité lit le film directement depuis l'hôte (`GET /media/{id}?token=…`, requêtes `Range`, aucun réencodage ni copie). La synchro est la même qu'en mode 1. Un bouton ⬇ *« Télécharger le film »* est également disponible pour l'invité depuis l'appareil appairé.

## Utilisation (mode 3 — audio seul, écran partagé)

Un seul écran (l'hôte : PC ou téléphone sur une TV) ; l'invité écoute la bande-son dans **ses écouteurs** (Bluetooth ou filaire).
1. **Hôte** : *Audio seul* → choisir le film → QR code. L'hôte garde l'image et son propre son.
2. **Invité** : *Rejoindre* (aucun fichier à choisir) → session ou QR. L'écran invité affiche les commandes et un réglage **Décalage audio**.
3. La latence de sortie est compensée automatiquement (Android : latence rapportée par l'OS, sinon estimation par type de sortie — Bluetooth ≈ 200 ms). Si le son est en avance/retard sur l'image, ajuster le curseur **−500…+500 ms** : il est **mémorisé par sortie** (ex. un réglage par casque Bluetooth).

Technique : l'hôte décode la piste audio avec FFmpeg (PCM 48 kHz stéréo, à partir de la position de lecture), l'encode en **Opus, trames de 20 ms**, et l'envoie en **UDP** (en-tête 16 octets : époque, n° de séquence, position) ~1,2 s en avance. L'invité : buffer de gigue indexé par position, masquage de perte Opus (PLC) sur trame manquante, sortie miniaudio (AAudio/OpenSL sous Android, WASAPI sous Windows) ; chaque trame est poussée pour être *entendue* quand la timeline de l'hôte l'atteint (latence de sortie incluse) ; resynchronisation au-delà de 40 ms d'écart.

## Utilisation (mode 4 — vers un navigateur)

L'invité n'installe rien : n'importe quel navigateur (TV, tablette, PC, iPhone…) sur le même réseau.
1. **Hôte** : *Navigateur* → choisir le film. Le QR code encode directement `http://IP:port/?token=…` (lien aussi affiché).
2. **Invité** : scanner le QR avec l'appareil photo (ou taper le lien) → la page se synchronise toute seule. Si le navigateur bloque la lecture automatique, toucher *Activer la lecture*. Un lien ⬇ est également présent dans la page pour télécharger le fichier.
3. Lecture/pause/saut depuis la page ou l'app ; l'hôte arbitre.

La page (HTML/JS/CSS embarqués dans l'app, **aucun CDN**, 100 % hors-ligne) refait la synchro en JS : horloge NTP (médiane de 8 via WebSocket), correction douce par `playbackRate` (±2 %), saut au-delà de 1 s, avec compensation apprise du délai de démarrage/saut.
**Conteneurs non lisibles** (MKV, AVI…) et **Safari / iOS** : l'hôte **réemballe à la volée** en MP4 fragmenté avec FFmpeg (`-c:v copy`, étiquette `hvc1` pour le HEVC ; audio AC3/DTS/Opus/FLAC… converti en AAC si le navigateur ne le lit pas). Intégration : [`ffmpeg_kit_flutter_new_min`](https://pub.dev/packages/ffmpeg_kit_flutter_new_min) (Android + Windows), sortie via socket TCP locale. Le flux réemballé gère les requêtes `Range` (taille estimée, fin comblée par une boîte MP4 « free »). Un saut relance la conversion à partir de l'image clé la plus proche (image figée quelques instants).

### Lecture d'une copie locale et copie compatible iOS (v0.7.0)

- **Lecture locale sans latence :** Cliquez sur « 📂 Utiliser un fichier local » pour lire une vidéo depuis votre appareil tout en restant synchronisé via l'horloge NTP (sauts directs, correction douce de la vitesse, aucun rechargement).
- **Gestion des flux :** Le stream HTTP et le remux temps réel de l'hôte s'arrêtent automatiquement à l'activation, tandis que la session WebSocket reste active.
- **Compatibilité iOS :** Le bouton « 📱 Télécharger copie compatible iOS » (GET `/download`) télécharge un fichier optimisé (`_ios.mp4`), servi sans conversion si déjà compatible, ou préparé avec réencodage audio rapide et index en tête (`+faststart`).
- **Usage conseillé sur iPhone :** Téléchargez d'abord la copie compatible, puis sélectionnez-la via le bouton de fichier local pour une lecture fluide sans latence réseau.
- **Fonctionnalités associées :** Avertissement non bloquant en cas de différence de taille de fichier, gestion des formats illisibles avec options de repli, et maintien des sous-titres textuels choisis par l'hôte.

## Utilisation (mode 5 — audio seul vers un navigateur)

Un seul écran (l'hôte) ; l'invité écoute la bande-son dans **ses écouteurs**, depuis **son navigateur**, sans installer l'app (iPhone compris).
1. **Hôte** : *Audio seul vers navigateur* → choisir le film → QR code (lien `http://IP:port/?token=…` aussi affiché). Bouton 🔈 dans le lecteur pour couper le son de l'hôte si besoin.
2. **Invité** : scanner le QR avec l'appareil photo → toucher **« Activer le son »** (obligatoire sur iOS).
3. Si le son est décalé (Bluetooth), ajuster le curseur **−500…+500 ms** (mémorisé par le navigateur). Le curseur **Volume de cet appareil** (50–300 %, limiteur au-delà de 100 %) est lui aussi mémorisé. La page affiche lecture/pause, la position et l'état de connexion, et permet lecture/pause/±10 s.

Technique : même pipeline que le mode 3 côté hôte (FFmpeg → PCM 48 kHz stéréo, trames de 20 ms horodatées, ~1,2 s d'avance) mais envoyé **sans compression sur un WebSocket binaire** (`/pcm`, ~1,5 Mb/s) : la page étant servie en http sur le réseau local (pas de contexte sécurisé), ni AudioWorklet ni WebCodecs (Opus) ne sont disponibles. Chaque trame est programmée avec Web Audio (`AudioBufferSourceNode.start(t)`) à l'instant exact calculé avec l'horloge NTP partagée, en compensant `baseLatency + outputLatency` et le réglage manuel ; trames jointives, rattrapage doux à ±1 % de vitesse, masquage des trames perdues.
**Précision mesurée** (Chrome headless, localhost) : écart entre le son programmé et la timeline de l'hôte ≈ **0–2 ms** en régime établi (p50 < 1 ms), y compris après un saut ; jusqu'à ~15 ms pendant les 1–3 premières secondes de la toute première lecture, rattrapés en douceur. Hors latence réelle du casque Bluetooth (curseur).

Raccourcis clavier (Windows) : `Espace` lecture/pause, `←`/`→` ±10 s, `F` plein écran, `Échap` sortie du plein écran.

Réglage **Son** (bouton « Volume et dialogues » du lecteur) : volume 0–300 % (au-delà de 100 %, amplification) et **Renforcer les dialogues** (compresseur léger), mémorisés.

## Envoyer le film à l'autre appareil (sans Internet)

L'application permet d'envoyer rapidement une copie du film d'un appareil à l'autre en local :
1. Sur l'appareil source : dans l'accueil, sélectionner **« Envoyer un film »** et choisir le fichier. Un QR code et un lien `http://IP:port/` s'affichent.
2. Sur l'appareil destinataire : scanner le QR code (ou ouvrir le lien dans le navigateur du téléphone), ou utiliser l'option **« Recevoir un film »** dans l'application pour saisir le lien/scanner.
3. Le transfert s'affiche avec une barre de progression, la vitesse et le temps restant, avec reprise automatique en cas de coupure ou de redémarrage de l'app.
4. Le fichier est enregistré dans le dossier **Téléchargements/SynchroFilm** (Android 10+ via MediaStore ; Android 7–9 : dossier Téléchargements propre à l'app ; Windows : `Téléchargements\SynchroFilm`).

## Sous-titres

- **Gestion native** : un bouton *Sous-titres* dans le lecteur permet de basculer entre les pistes intégrées (MKV/MP4, formats texte : SRT, ASS, WebVTT, mov_text), de les désactiver, ou de charger un fichier externe (`.srt`, `.ass`, `.ssa`, `.vtt` en encodage UTF-8, UTF-16 ou Latin-1).
- **Synchronisation** : le choix de l'hôte est transmis à l'invité en modes 1 et 2 (piste intégrée identique ou fichier externe téléchargé automatiquement chez l'hôte). En mode 4, les sous-titres sont servis au navigateur en WebVTT (pistes extraites par FFmpeg, ASS convertis, SRT convertis par l'app) et décalés automatiquement après un saut en cas de remux.
- **Limites** : les sous-titres sous forme d'images (PGS, VobSub) ne sont pris en charge ni par l'application ni par le navigateur.

## Construire et lancer

Prérequis : [Flutter](https://docs.flutter.dev/get-started/install) stable (testé avec 3.47, Dart 3.13).

```bash
flutter pub get
flutter analyze
flutter test                     # logique + sessions + modes 3/4/5 (FFmpeg et libopus requis pour certains tests,
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
web_client/ pages des modes 4 (index.html, app.js) et 5 (audio.html, audio.js), horloge commune clock.js — assets embarqués
test/       tests unitaires + intégration hôte/invité sur localhost (modes 1–4) + Chrome headless
```

### Synchro

- **Horloge** : l'invité envoie `ping{t0}`, l'hôte répond `pong{t0,t1,t2}` ; offset = médiane des 8 derniers échanges (pings rapprochés au début, puis toutes les 10 s).
- **État** : l'hôte diffuse `state{playing, position, rate, at}` (ancré sur son horloge) à chaque changement et toutes les 2 s.
- **Commandes** : chaque pair envoie `cmd{play|pause|seek}` ; l'hôte les applique dans l'ordre reçu (la dernière gagne) et rediffuse `state`.
- **Correction douce** (des deux côtés, sur la même timeline) : écart < 40 ms → rien ; 40 ms–1 s → vitesse ±2 % jusqu'à ≤ 15 ms (hystérésis) ; > 1 s → seek (puis 1,5 s sans correction).

## Licence

Code sous licence **MIT** (`LICENSE`). Les binaires embarquent FFmpeg et libmpv sous **LGPL** (bibliothèques dynamiques non modifiées) et d'autres composants permissifs : voir [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Icône : `assets/icon/*.svg` (dessinée en code), rendue en PNG puis déclinée par `flutter_launcher_icons` (icône adaptative Android, `.ico` Windows).

## Limites / TODO

- **v0.6.0, non testé sur un vrai appareil** : Safari/iPhone réel (testé avec Chrome et un user-agent d'iPhone), plein écran et rendu des sous-titres sur Android/Windows, enregistrement MediaStore sur un Android réel, « Renforcer les dialogues » (dépend des filtres présents dans libmpv mobile).
- **Safari (mode 4)** : la taille du flux réemballé est estimée ; le fichier temporaire de remux grossit au fil de la lecture chez l'hôte (supprimé à la fin de la session).
- **Envoi de fichier** : sur Android 7–9, le fichier reçu est rangé dans le dossier Téléchargements propre à l'app (Android/data/…).
- **Mode 5** : le son passe en PCM non compressé (~1,5 Mb/s par auditeur, sans souci en Wi-Fi local). `outputLatency` n'est pas fourni par tous les navigateurs (Safari) ni toujours exact en Bluetooth → curseur. Sur iOS, l'audio peut s'arrêter quand l'écran se verrouille (laisser la page ouverte) ; le bouton « Activer le son » est requis à chaque ouverture. Au tout premier démarrage, un léger écart (~10–20 ms) est rattrapé en 1–3 s.
- **Modes 3, 4 et 5 : testés sur PC (localhost, Chrome headless, iPhone simulé par user-agent, FFmpeg/libopus système), pas encore sur de vrais appareils physiques (Smartphones/TV).**
- **Mode 3** : un seul invité ; latence auto sous Android uniquement (API cachée `AudioManager.getOutputLatency`, sinon estimation par type de sortie) ; **sous Windows, réglage manuel seul** (WASAPI non branché). La précision Bluetooth réelle dépend du casque : ajuster le curseur. Le son de l'hôte n'est pas coupé.
- **Mode 4** : codecs limités à ceux du navigateur (H.264/AAC partout ; HEVC/AV1 selon l'appareil — pas de réencodage vidéo). En flux réemballé (MKV…), un saut recharge le flux (image figée ~1–3 s) et l'écart initial est résorbé par la vitesse ±2 % (quelques secondes). Un seul navigateur à la fois. Safari iOS : lecture automatique souvent bloquée → bouton *Activer la lecture*.
- **Taille** : FFmpeg (ffmpeg-kit « min », en plus du FFmpeg interne de libmpv) et libopus ajoutent ~19 Mo : APK arm64 ≈ 57 Mo (38 Mo en v0.2.0).
- **Android, fournisseurs non « seekables »** : les films sont lus via leur URI `content://` d'origine (sélecteur système, aucune copie). Les rares fournisseurs qui ne donnent qu'un flux (certains clouds) ne sont pas gérés : choisir un fichier stocké sur le téléphone.
- **Mode 2** : un seul invité ; débit limité par le Wi-Fi (un film 4K à fort débit peut saccader sur un hotspot faible) ; pas de reprise automatique si l'hôte coupe le réseau.
- Le **token** de session circule en clair dans le TXT mDNS : suffisant sur un hotspot privé ; prévoir un appairage par code si besoin.
- Pas encore de **reconnexion automatique** de l'invité ni de **service au premier plan** Android pour l'hôte (écran éteint).
- La précision dépend de la fréquence de mise à jour de la position par libmpv ; à valider sur appareils réels (objectif < 50 ms).
- Pas de build Windows vérifié ici (nécessite un PC Windows) ; ffmpeg-kit Windows et mp_audio_stream/opus non testés sous Windows.
