# App Synchro Film — Architecture

Application légère Android + Windows pour synchroniser la lecture d'un fichier multimédia local entre deux appareils, en Wi-Fi, **100 % hors-ligne** (partage de connexion ou réseau local sans Internet).

## 1. Choix techniques

| Domaine | Choix | Raison |
|---|---|---|
| Framework | **Flutter** (Android + Windows, une seule base de code) | Un seul code, bonnes perfs, écosystème mature |
| Lecteur | **media_kit** (libmpv) | Quasi tous formats (MKV, HEVC, AC3/DTS…), décodage matériel |
| Découverte | **mDNS** (`_synchrofilm._tcp`) + **QR code** (IP:port) en secours | Zéro saisie ; le QR couvre les hotspots qui filtrent le multicast |
| Contrôle / synchro | **WebSocket** + synchro d'horloge type **NTP** | Léger, bidirectionnel, compatible navigateur |
| Stream vidéo | **HTTP progressif** (requêtes Range) + **remux FFmpeg à la volée** vers MP4 si besoin | Aucun réencodage, coût CPU/batterie minimal |
| Stream audio seul | **Opus** sur **UDP** + compensation auto de la latence Bluetooth + curseur manuel | ~20 ms de latence codec, robuste, faible débit (~128 kb/s) |
| Audio seul vers navigateur | **PCM** s16le 48 kHz sur **WebSocket binaire** + **Web Audio** (`AudioBufferSourceNode` programmé) | Page en http simple (pas de contexte sécurisé : ni AudioWorklet ni WebCodecs) ; ~1,5 Mb/s, négligeable en Wi-Fi local |
| Politique de synchro | Hôte = horloge de référence, **les deux pilotent**, **correction douce** | Lecture fluide, écart cible < 50 ms |

## 2. Vue d'ensemble

```mermaid
flowchart LR
  subgraph Hote[Appareil hôte]
    UIH[UI Flutter] --> PH[media_kit]
    UIH --> SS[Session service]
    SS --> WS[Serveur WebSocket]
    SS --> HTTP[Serveur HTTP Range + page web]
    HTTP --> FF[FFmpeg remux optionnel]
    SS --> AUD[Encodeur Opus -> UDP]
    SS --> MDNS[Annonce mDNS + QR]
  end
  subgraph Invite[Appareil invité]
    UII[UI Flutter] --> PI[media_kit]
    UII --> SC[Session client]
    SC --> WS
    PI --> HTTP
    SC --> DEC[Décodeur Opus + buffer de gigue]
    AUD --> DEC
  end
  NAV[Navigateur invité, mode 4] --> HTTP
  NAV --> WS
```

## 3. Les 5 modes

### Mode 1 — Synchro double fichier
- Chaque appareil lit **son propre fichier** ; vérification d'identité du fichier (taille + hash partiel des premiers/derniers Mo) à la connexion.
- Seules les commandes et la position transitent par WebSocket.

### Mode 2 — Stream complet App ↔ App
- L'hôte expose `GET /media/{id}` avec support `Range` ; l'invité ouvre l'URL dans media_kit (aucun réencodage, tous formats).
- Synchro identique au mode 1.

### Mode 3 — Stream audio seul (écran partagé)
- L'hôte affiche la vidéo et joue (ou non) le son localement ; la piste audio décodée est réencodée en **Opus** (trames de 20 ms) et envoyée en **UDP**.
- L'invité : buffer de gigue adaptatif → décodage → sortie audio.
- **Compensation Bluetooth** : lecture de la latence de sortie rapportée par l'OS (Android `AudioTrack`/`AudioManager`, Windows WASAPI) + **curseur manuel** (−500 à +500 ms) ; la valeur est mémorisée par appareil de sortie.
- L'hôte peut aussi retarder sa propre vidéo si l'écouteur le plus lent dépasse un seuil.

### Mode 4 — Stream vers navigateur
- L'hôte sert une petite page web statique (HTML/JS, embarquée dans l'app) + `/media/{id}`.
- Si le conteneur n'est pas lisible (ex. MKV), **remux FFmpeg à la volée** en MP4 fragmenté, sans réencodage.
- La page se connecte au même WebSocket pour la synchro (`playbackRate` pour la correction douce).
- **Limite** : codecs non supportés par le navigateur (HEVC, AC3/DTS selon navigateur) → message clair à l'utilisateur ; pas de transcodage vidéo par défaut.

### Mode 5 — Audio seul vers navigateur
- Comme le mode 4, l'invité n'a pas l'app : il scanne le QR code (`http://IP:port/?token=…`) et la page `web_client/audio.html` s'ouvre.
- **Hôte** : même pipeline que le mode 3 (`AudioHostStreamer` : FFmpeg → PCM 48 kHz stéréo à partir de la position, trames de 20 ms horodatées, envoi ~1,2 s en avance, pré-envoi de 600 ms en pause) mais sans Opus : chaque trame part telle quelle (en-tête 16 octets, drapeau `PCM`) sur le WebSocket binaire `/pcm?token=…`. Un saut redémarre le décodage avec un nouvel `epoch` → la page vide son buffer. Plusieurs navigateurs peuvent écouter.
- **Page** (aucune dépendance) : horloge NTP partagée avec le mode 4 (`clock.js`, médiane de 8), buffer de gigue indexé par n° de trame, programmation de chaque trame avec `AudioBufferSourceNode.start(t)` à l'instant où la timeline de l'hôte l'atteint :
  `t = ctx(heure_hôte(position) − offset) − (baseLatency + outputLatency) − réglage manuel`,
  correspondance `performance.now()` ↔ `AudioContext.currentTime` réévaluée en continu (dérive des horloges suivie).
- Trames jointives (pas de clic) ; l'écart résiduel est rattrapé en jouant les trames à ±1 % de vitesse (`playbackRate`), recalage net avec fondu au-delà de 30 ms. Trame manquante : répétition de la précédente en fondu (masquage), fondu d'entrée à la reprise.
- Bouton **« Activer le son »** (geste utilisateur exigé par iOS/Chrome), curseur **−500…+500 ms** mémorisé dans `localStorage`, affichage lecture/pause, position, connexion ; lecture/pause/±10 s depuis la page.
- Programmation déclenchée aussi par l'arrivée des paquets (les minuteries d'une page masquée sont ralenties) et horizon allongé quand la page est masquée.

## 4. Protocole de synchro

Messages JSON sur WebSocket :

| Message | Contenu |
|---|---|
| `hello` | version, nom de l'appareil, mode, empreinte du fichier |
| `ping` / `pong` | t0, t1, t2 (estimation offset + RTT, type NTP, filtrage médian sur 8 échantillons) |
| `state` | `{playing, position, rate, at: hostClockMs}` — émis à chaque changement + toutes les 2 s |
| `cmd` | `play`, `pause`, `seek(pos)` — envoyé par **n'importe quel** pair, l'hôte arbitre et rediffuse un `state` |

**Correction douce** (côté invité) :
- écart < 40 ms : rien ;
- 40 ms – 1 s : vitesse ajustée de ±2 % jusqu'à résorption ;
- > 1 s : `seek` direct.

**Conflits** : l'hôte applique les commandes dans l'ordre de réception, horodatées par son horloge (la dernière gagne).

## 5. Connexion hors-ligne

1. L'hôte démarre une session → ouvre les serveurs (WS + HTTP + UDP sur ports fixes configurables) → s'annonce en mDNS → affiche un QR code `synchrofilm://IP:port?token=...`.
2. L'invité voit la session apparaître, ou scanne le QR (Android) / saisit l'adresse (Windows).
3. Un **token de session** court protège la connexion (réseau local, pas de chiffrement lourd pour économiser la batterie).
4. Mode 4 : le QR encode directement `http://IP:port/?token=…` pour ouverture dans le navigateur.

## 6. Économie de batterie
- Aucun transcodage vidéo ; remux uniquement si nécessaire.
- Décodage matériel activé par défaut dans media_kit.
- Serveurs démarrés uniquement pendant une session ; mDNS arrêté une fois l'invité connecté.
- Messages `state` espacés (2 s) hors changements ; ping d'horloge toutes les 10 s après convergence.
- Android : `WakeLock` partiel seulement pendant la lecture ; service au premier plan pour le mode hôte.

## 7. Structure de projet envisagée

```
lib/
  core/        # horloge, protocole, modèles
  net/         # mdns, websocket, http server, udp audio
  player/      # wrapper media_kit, correction douce
  modes/       # double_file, stream, audio_only, browser, browser_audio
  ui/
web_client/    # pages HTML/JS servies en modes 4 (index.html, app.js) et 5 (audio.html, audio.js) ; clock.js commun
docs/
```

## 8. Limites connues
- Mode 4 limité aux codecs lisibles par le navigateur (H.264/AAC, VP9/Opus…).
- Pas de Wi-Fi Direct (non retenu).
- FFmpeg ajoute ~10–20 Mo à l'application.
- Latence Bluetooth annoncée parfois inexacte → d'où le réglage manuel.
- Mode 5 : `outputLatency` n'est pas exposé partout (Safari) et n'inclut pas toujours le Bluetooth → réglage manuel ; iOS peut suspendre l'audio écran verrouillé.

## 9. Étapes
1. ✅ Squelette Flutter + media_kit (Android + Windows).
2. ✅ Protocole WS + synchro d'horloge + mode 1.
3. ✅ Serveur HTTP Range + mode 2.
4. ✅ Page web + remux FFmpeg (ffmpeg_kit_flutter_new_min, sortie TCP locale) + mode 4.
5. ✅ Pipeline FFmpeg → PCM → Opus/UDP + compensation de latence + mode 3.
6. ✅ Mode 5 : PCM sur WebSocket + Web Audio programmé (réutilise le pipeline du mode 3).
7. À faire : validation sur appareils réels, latence WASAPI sous Windows, reconnexion auto, service au premier plan Android.
