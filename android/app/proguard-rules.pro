# media_kit : classes appelées depuis le code natif (JNI) — ne pas renommer/supprimer.
-keep class com.alexmercerind.** { *; }
# Canal natif de l'app (accès content:// sans copie).
-keep class com.bodriclab.app_synchro_film.** { *; }
