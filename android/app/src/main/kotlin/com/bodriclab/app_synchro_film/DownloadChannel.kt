package com.bodriclab.app_synchro_film

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

// Canal de méthode pour gérer les téléchargements natifs Android
class DownloadChannel(private val context: Context) {
    // Exécuteur mono-tâche pour traiter les opérations de fichiers en arrière-plan
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // Stockage des flux et descripteurs ouverts avec un identifiant unique
    private val openFiles = ConcurrentHashMap<Int, Pair<android.os.ParcelFileDescriptor, FileOutputStream>>()
    private val idCounter = AtomicInteger(0)

    fun register(messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, "com.bodriclab.synchrofilm/download")
        channel.setMethodCallHandler { call, result ->
            executor.execute {
                try {
                    when (call.method) {
                        "create" -> {
                            val name = call.argument<String>("name") ?: "download"
                            val mime = call.argument<String>("mime")
                            val uri = createDownload(name, mime)
                            postSuccess(result, uri)
                        }
                        "size" -> {
                            val uri = call.argument<String>("uri") ?: ""
                            val size = getDownloadSize(uri)
                            postSuccess(result, size)
                        }
                        "open" -> {
                            val uri = call.argument<String>("uri") ?: ""
                            val truncate = call.argument<Boolean>("truncate") ?: false
                            val handle = openDownload(uri, truncate)
                            postSuccess(result, handle)
                        }
                        "write" -> {
                            val handle = call.argument<Int>("handle") ?: 0
                            val data = call.argument<ByteArray>("data") ?: byteArrayOf()
                            writeDownload(handle, data)
                            postSuccess(result, null)
                        }
                        "close" -> {
                            val handle = call.argument<Int>("handle") ?: 0
                            closeDownload(handle)
                            postSuccess(result, null)
                        }
                        "finish" -> {
                            val uri = call.argument<String>("uri") ?: ""
                            val name = call.argument<String>("name") ?: ""
                            val location = finishDownload(uri, name)
                            postSuccess(result, location)
                        }
                        "delete" -> {
                            val uri = call.argument<String>("uri") ?: ""
                            deleteDownload(uri)
                            postSuccess(result, null)
                        }
                        else -> {
                            mainHandler.post { result.notImplemented() }
                        }
                    }
                } catch (e: Exception) {
                    mainHandler.post {
                        result.error("download", e.message ?: "Erreur inconnue", null)
                    }
                }
            }
        }
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    // Crée un nouvel emplacement de téléchargement selon la version d'Android
    private fun createDownload(name: String, mime: String?): String {
        val mimeType = mime ?: "application/octet-stream"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val contentValues = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/SynchroFilm")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
                ?: throw IllegalStateException("Impossible de créer l'entrée MediaStore")
            return uri.toString()
        } else {
            val downloadsDir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            val synchroDir = File(downloadsDir, "SynchroFilm")
            if (!synchroDir.exists()) {
                synchroDir.mkdirs()
            }
            val file = File(synchroDir, "$name.part")
            if (file.exists()) {
                file.delete()
            }
            file.createNewFile()
            return Uri.fromFile(file).toString()
        }
    }

    // Récupère la taille actuelle du fichier de téléchargement
    private fun getDownloadSize(uriString: String): Long {
        val uri = Uri.parse(uriString)
        return if (uri.scheme == "content") {
            try {
                context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                    pfd.statSize
                } ?: -1L
            } catch (e: Exception) {
                -1L
            }
        } else {
            val file = File(uri.path ?: return -1L)
            if (file.exists()) file.length() else -1L
        }
    }

    // Ouvre un descripteur de fichier pour l'écriture
    private fun openDownload(uriString: String, truncate: Boolean): Int {
        val uri = Uri.parse(uriString)
        val pfd = if (uri.scheme == "content") {
            context.contentResolver.openFileDescriptor(uri, "rw")
                ?: throw IllegalStateException("Impossible d'ouvrir le descripteur pour $uriString")
        } else {
            val file = File(uri.path ?: throw IllegalArgumentException("Chemin invalide"))
            android.os.ParcelFileDescriptor.open(
                file,
                android.os.ParcelFileDescriptor.MODE_READ_WRITE or android.os.ParcelFileDescriptor.MODE_CREATE
            )
        }

        val fos = FileOutputStream(pfd.fileDescriptor)
        val channel = fos.channel

        if (truncate) {
            channel.truncate(0)
            channel.position(0)
        } else {
            channel.position(channel.size())
        }

        val handle = idCounter.incrementAndGet()
        openFiles[handle] = Pair(pfd, fos)
        return handle
    }

    // Écrit des données dans le flux actif
    private fun writeDownload(handle: Int, data: ByteArray) {
        val pair = openFiles[handle] ?: throw IllegalArgumentException("Handle invalide: $handle")
        pair.second.write(data)
    }

    // Ferme un flux et son descripteur associés au handle
    private fun closeDownload(handle: Int) {
        openFiles.remove(handle)?.let { (pfd, fos) ->
            try {
                fos.flush()
                fos.close()
            } catch (_: Exception) {}
            try {
                pfd.close()
            } catch (_: Exception) {}
        }
    }

    // Finalise le téléchargement (supprime le statut pending ou renomme le fichier .part)
    private fun finishDownload(uriString: String, name: String): String {
        val uri = Uri.parse(uriString)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && uri.scheme == "content") {
            val contentValues = ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            context.contentResolver.update(uri, contentValues, null, null)
            return "Téléchargements/SynchroFilm/$name"
        } else {
            val file = File(uri.path ?: throw IllegalArgumentException("Chemin invalide"))
            val parent = file.parentFile ?: throw IllegalStateException("Dossier parent introuvable")
            
            var targetFile = File(parent, name)
            if (targetFile.exists()) {
                val extension = name.substringAfterLast('.', "")
                val baseName = name.substringBeforeLast('.', name)
                var count = 2
                while (targetFile.exists()) {
                    val newName = if (extension.isNotEmpty()) "$baseName ($count).$extension" else "$baseName ($count)"
                    targetFile = File(parent, newName)
                    count++
                }
            }
            file.renameTo(targetFile)
            return targetFile.absolutePath
        }
    }

    // Supprime le fichier ou l'entrée MediaStore
    private fun deleteDownload(uriString: String) {
        val uri = Uri.parse(uriString)
        if (uri.scheme == "content") {
            try {
                context.contentResolver.delete(uri, null, null)
            } catch (_: Exception) {}
        } else {
            val file = File(uri.path ?: return)
            if (file.exists()) {
                file.delete()
            }
        }
    }
}
