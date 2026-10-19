package com.bibliojules.mobile

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The one piece of Android the Dart side cannot do itself: talking to the
 * system's file picker.
 *
 * Dart asks for a file to be *saved* ("export") or *loaded* ("pick"); Android
 * answers with a `content://` URI pointing at whatever the user chose —
 * Downloads, a Google Drive folder, a USB stick. This class streams the bytes in
 * the right direction and hands back the name the destination shows, which is
 * all Dart needs to report success.
 *
 * There is no plugin dependency for this. FlutterActivity extends plain
 * `Activity`, not `ComponentActivity`, so the modern
 * `registerForActivityResult` is not available and `startActivityForResult`
 * (deprecated, but still fully supported) does the job.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "bibliojules/files"
        const val REQUEST_EXPORT = 7301
        const val REQUEST_PICK = 7302
    }

    /** The Dart call waiting on the picker, and what to move for it. */
    private var pendingResult: MethodChannel.Result? = null
    private var pendingSource: File? = null
    private var pendingTarget: File? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (pendingResult != null) {
            // A second picker on top of the first would lose the first answer.
            result.error("busy", "Another file operation is still open.", null)
            return
        }

        when (call.method) {
            "export" -> {
                val path = call.argument<String>("source")
                if (path == null) {
                    result.error("bad_arguments", "No file to export.", null)
                    return
                }
                pendingSource = File(path)
                pendingTarget = null
                pendingResult = result
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/octet-stream"
                    putExtra(
                        Intent.EXTRA_TITLE,
                        call.argument<String>("name") ?: "library.sqlite",
                    )
                }
                startActivityForResult(intent, REQUEST_EXPORT)
            }

            "pick" -> {
                val path = call.argument<String>("target")
                if (path == null) {
                    result.error("bad_arguments", "Nowhere to copy the file to.", null)
                    return
                }
                pendingSource = null
                pendingTarget = File(path)
                pendingResult = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    // Deliberately wide: a database file usually has no useful
                    // type, and the app validates whatever comes back.
                    type = "*/*"
                }
                startActivityForResult(intent, REQUEST_PICK)
            }

            else -> result.notImplemented()
        }
    }

    @Deprecated("FlutterActivity is a plain Activity; this is the only hook it offers.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_EXPORT && requestCode != REQUEST_PICK) return

        val result = pendingResult
        val source = pendingSource
        val target = pendingTarget
        pendingResult = null
        pendingSource = null
        pendingTarget = null
        if (result == null) return

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // The user backed out; that is not an error.
            result.success(null)
            return
        }

        try {
            if (requestCode == REQUEST_EXPORT) {
                val from = source ?: throw IllegalStateException("The library is no longer open.")
                val stream = contentResolver.openOutputStream(uri)
                    ?: throw IllegalStateException("That folder cannot be written to.")
                stream.use { output ->
                    from.inputStream().use { input -> input.copyTo(output) }
                }
                result.success(displayName(uri) ?: uri.lastPathSegment ?: "")
            } else {
                val to = target ?: throw IllegalStateException("Nowhere to copy the file to.")
                val stream = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("That file cannot be read.")
                stream.use { input ->
                    to.outputStream().use { output -> input.copyTo(output) }
                }
                result.success(to.absolutePath)
            }
        } catch (error: Exception) {
            result.error("transfer_failed", error.message ?: "The file could not be transferred.", null)
        }
    }

    /** The name the chosen destination uses, for the "saved as …" message. */
    private fun displayName(uri: Uri): String? {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(uri, null, null, null, null)
            if (cursor != null && cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && !cursor.isNull(index)) cursor.getString(index) else null
            } else {
                null
            }
        } catch (error: Exception) {
            null
        } finally {
            cursor?.close()
        }
    }
}
