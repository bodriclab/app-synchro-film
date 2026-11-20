# Composants tiers

Le code de ce dépôt est sous licence **MIT** (voir `LICENSE`). Les binaires
distribués (APK, build Windows) embarquent des composants tiers soumis à
leurs propres licences :

| Composant | Licence | Remarque |
|---|---|---|
| media_kit, media_kit_video, media_kit_libs_* (Dart/Flutter) | MIT | |
| libmpv + FFmpeg embarqués par media_kit (`libmpv-android-video-build`, builds Windows media_kit) | **LGPL v2.1+** (builds sans composants GPL) | Bibliothèques dynamiques (`libmpv.so`, `libav*.so`) remplaçables par l'utilisateur |
| ffmpeg_kit_flutter_new_min / FFmpegKit « min » | **LGPL v3** | Bibliothèques dynamiques (`libffmpegkit.so`, `libav*.so`) |
| libopus, opus_codec, opus_codec_dart | BSD 3 clauses | |
| mp_audio_stream (miniaudio) | MIT (miniaudio : domaine public / MIT-0) | |
| mobile_scanner | BSD 3 clauses | utilise Google ML Kit (conditions Google, redistribution autorisée) |
| nsd | MIT | |
| qr_flutter | BSD 3 clauses | |
| file_picker | MIT | |
| crypto, path_provider, Flutter | BSD 3 clauses | |

**Conséquences LGPL** (sans incidence sur la licence MIT de notre code, car
les bibliothèques LGPL sont liées dynamiquement et non modifiées) : en
redistribuant un APK, on doit mentionner ces bibliothèques et leur licence, et
permettre d'obtenir leur code source (projets amont : FFmpeg, mpv,
media-kit/libmpv-android-video-build, FFmpegKit) ainsi que de les remplacer
(`.so` séparés dans l'APK). Aucune bibliothèque **GPL** n'est incluse : ne pas
passer à une variante « full-gpl » de FFmpegKit sans réexaminer la licence
(cela imposerait la GPL à l'application distribuée).
