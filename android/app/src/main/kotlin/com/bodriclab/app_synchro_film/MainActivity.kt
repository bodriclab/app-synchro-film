package com.bodriclab.app_synchro_film

import android.app.Activity
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
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
    private var pendingInstallPermission: MethodChannel.Result? = null
    private val installPermissionRequestCode = 4243

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.bodriclab.synchrofilm/update")
            .setMethodCallHandler(::onUpdateCall)
    }

    /**
     * Mises à jour : ABI de l'appareil, autorisation « sources inconnues »
     * (REQUEST_INSTALL_PACKAGES), installation d'un APK téléchargé dans le
     * cache via FileProvider (installeur système).
     */
    private fun onUpdateCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a")
            "canInstall" -> result.success(canInstallPackages())
            "requestInstallPermission" -> {
                if (canInstallPackages()) {
                    result.success(true)
                    return
                }
                pendingInstallPermission?.success(false)
                pendingInstallPermission = result
                val intent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                )
                @Suppress("DEPRECATION")
                startActivityForResult(intent, installPermissionRequestCode)
            }
            "install" -> {
                try {
                    val file = File(call.argument<String>("path")!!)
                    val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("install_error", e.message ?: e.toString(), null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

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
            "audioOutput" -> result.success(audioOutput())
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
        if (requestCode == installPermissionRequestCode) {
            pendingInstallPermission?.success(canInstallPackages())
            pendingInstallPermission = null
            return
        }
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

    /**
     * Sortie audio active (mode 3) et sa latence : AudioManager.getOutputLatency
     * (API cachée, inclut souvent la latence Bluetooth A2DP) si accessible,
     * sinon estimation par type de sortie. Le curseur manuel corrige le reste.
     */
    private fun audioOutput(): Map<String, Any?> {
        val am = getSystemService(AUDIO_SERVICE) as AudioManager
        val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val priority = mutableListOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        )
        if (Build.VERSION.SDK_INT >= 31) {
            priority.add(1, AudioDeviceInfo.TYPE_BLE_HEADSET)
            priority.add(2, AudioDeviceInfo.TYPE_BLE_SPEAKER)
        }
        val device = priority.firstNotNullOfOrNull { t -> outputs.firstOrNull { it.type == t } }
        val type = device?.type ?: AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        val kind = when (type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bt"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired"
            AudioDeviceInfo.TYPE_USB_HEADSET -> "usb"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
            else -> if (Build.VERSION.SDK_INT >= 31 &&
                (type == AudioDeviceInfo.TYPE_BLE_HEADSET || type == AudioDeviceInfo.TYPE_BLE_SPEAKER)) "ble" else "other"
        }
        val name = device?.productName?.toString()?.takeIf { it.isNotBlank() } ?: when (kind) {
            "bt" -> "Écouteurs Bluetooth"
            "ble" -> "Écouteurs Bluetooth LE"
            "wired" -> "Écouteurs filaires"
            "usb" -> "Casque USB"
            else -> "Haut-parleur"
        }

        var latency: Int? = null
        var source = "estimate"
        try {
            val m = AudioManager::class.java.getMethod("getOutputLatency", Int::class.javaPrimitiveType)
            val v = m.invoke(am, AudioManager.STREAM_MUSIC) as Int
            if (v in 1..2000) { latency = v; source = "os" }
        } catch (_: Throwable) { }
        if (latency == null) {
            val frames = am.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull() ?: 256
            val rate = am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull() ?: 48000
            val base = 2 * frames * 1000 / rate
            latency = base + when (kind) { "bt" -> 180; "ble" -> 80; else -> 10 }
        }
        return mapOf("id" to "$kind:$name", "label" to name, "latencyMs" to latency, "source" to source)
    }

    override fun onDestroy() {
        handles.values.forEach { it.close() }
        handles.clear()
        io.shutdown()
        super.onDestroy()
    }
}
