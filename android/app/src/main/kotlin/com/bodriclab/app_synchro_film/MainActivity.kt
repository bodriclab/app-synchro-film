package com.bodriclab.app_synchro_film

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Accès aux films via leur URI d'origine (content://), SANS copie :
 * - `pick`  : sélecteur système (ACTION_OPEN_DOCUMENT), permission persistante ;
 * - `info`  : nom + taille ;
 * - `open` / `read` / `close` : lecture aléatoire (empreinte, serveur HTTP du mode 2).
 *
 * Les lectures se font hors du thread UI (pool de 2 threads) avec des lectures
 * positionnelles (FileChannel.read(buf, position)), donc sûres en parallèle.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.bodriclab.synchrofilm/media"
    private val pickRequestCode = 4747
    private var pendingPick: MethodChannel.Result? = null

    private val io = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private val nextId = AtomicInteger(1)
    private val handles = ConcurrentHashMap<Int, Handle>()

    private class Handle(val pfd: ParcelFileDescriptor, val stream: FileInputStream) {
        val channel: FileChannel = stream.channel
        fun close() {
            try { stream.close() } catch (_: Exception) {}
            try { pfd.close() } catch (_: Exception) {}
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler(::onCall)
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(result)
            "info" -> background(result) { info(Uri.parse(call.argument<String>("uri")!!)) }
            "open" -> background(result) { open(call.argument<String>("uri")!!) }
            "read" -> background(result) {
                read(
                    call.argument<Int>("id")!!,
                    (call.argument<Number>("offset")!!).toLong(),
                    call.argument<Int>("length")!!,
                )
            }
            "close" -> {
                handles.remove(call.argument<Int>("id"))?.close()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("io_error", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun pick(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "Sélection déjà en cours", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("video/*", "audio/*"))
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, pickRequestCode)
    }

    @Deprecated("API Activity historique, suffisante ici")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickRequestCode) return
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (_: SecurityException) {
            // Fournisseur sans permission persistante : valable pour la session.
        }
        background(result) { info(uri) }
    }

    private fun info(uri: Uri): Map<String, Any?> {
        var name: String? = null
        var size: Long? = null
        contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null, null, null
        )?.use { c ->
            if (c.moveToFirst()) {
                val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val s = c.getColumnIndex(OpenableColumns.SIZE)
                if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
            }
        }
        if (size == null || size!! < 0) {
            contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                if (pfd.statSize >= 0) size = pfd.statSize
            }
        }
        return mapOf("uri" to uri.toString(), "name" to name, "size" to size)
    }

    private fun open(uri: String): Map<String, Any> {
        val pfd = contentResolver.openFileDescriptor(Uri.parse(uri), "r")
            ?: throw IllegalStateException("Impossible d'ouvrir $uri")
        val handle = Handle(pfd, FileInputStream(pfd.fileDescriptor))
        val size = handle.channel.size()
        val id = nextId.getAndIncrement()
        handles[id] = handle
        return mapOf("id" to id, "size" to size)
    }

    private fun read(id: Int, offset: Long, length: Int): ByteArray {
        val handle = handles[id] ?: throw IllegalStateException("Descripteur $id fermé")
        val buffer = ByteBuffer.allocate(length)
        var pos = offset
        while (buffer.hasRemaining()) {
            val n = handle.channel.read(buffer, pos)
            if (n <= 0) break
            pos += n
        }
        return if (buffer.position() == length) buffer.array()
        else buffer.array().copyOf(buffer.position())
    }

    override fun onDestroy() {
        handles.values.forEach { it.close() }
        handles.clear()
        io.shutdown()
        super.onDestroy()
    }
}
