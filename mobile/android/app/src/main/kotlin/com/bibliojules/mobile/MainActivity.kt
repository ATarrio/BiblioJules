package com.bibliojules.mobile

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.OutputStream

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
 * The shared library uses the same machinery with one difference: the user picks
 * a *folder* once ("pickSyncFolder"), Android remembers the grant across
 * restarts, and every sync after that copies one fixed file in or out of it
 * ("syncPull", "syncPush"). The folder is never held open — a snapshot is
 * copied to the app's own cache, merged there, and copied back — so a cloud
 * provider only ever sees whole files.
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
        const val REQUEST_FOLDER = 7303

        /** The one file name every client uses inside a shared folder. */
        const val SNAPSHOT_NAME = "bibliojules-library.sqlite"
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
        when (call.method) {
            "export" -> askForExport(call, result)
            "pick" -> askForImport(call, result)
            "pickSyncFolder" -> askForFolder(result)
            "syncPull" -> syncPull(call, result)
            "syncPush" -> syncPush(call, result)
            "syncFolderName" -> syncFolderName(call, result)
            "syncPermission" -> syncPermission(call, result)
            else -> result.notImplemented()
        }
    }

    private fun busy(result: MethodChannel.Result) {
        // A second picker on top of the first would lose the first answer.
        result.error("busy", "Another file operation is still open.", null)
    }

    // --- the pickers -------------------------------------------------------- //

    private fun askForExport(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("source")
        if (path == null) {
            result.error("bad_arguments", "No file to export.", null)
            return
        }
        if (pendingResult != null) {
            busy(result)
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
        launch(intent, REQUEST_EXPORT, result)
    }

    private fun askForImport(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("target")
        if (path == null) {
            result.error("bad_arguments", "Nowhere to copy the file to.", null)
            return
        }
        if (pendingResult != null) {
            busy(result)
            return
        }
        pendingSource = null
        pendingTarget = File(path)
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // Wide by default: a database file usually has no useful type,
            // and the app validates whatever comes back. CSV/image pickers
            // pass a narrower hint.
            type = call.argument<String>("type") ?: "*/*"
        }
        launch(intent, REQUEST_PICK, result)
    }

    /**
     * Start a picker, clearing the pending request if the activity refuses.
     *
     * Without this, a throw from `startActivityForResult` (for example when no
     * activity can handle the intent) leaves `pendingResult` set forever and
     * every later pick reports "busy".
     */
    private fun launch(intent: Intent, requestCode: Int, result: MethodChannel.Result) {
        try {
            startActivityForResult(intent, requestCode)
        } catch (error: Exception) {
            pendingResult = null
            pendingSource = null
            pendingTarget = null
            result.error("launch_failed", error.message ?: "Could not open the file picker.", null)
        }
    }

    /**
     * Ask for the folder snapshots are exchanged through, and keep the grant.
     *
     * `takePersistableUriPermission` is what makes "sync when the app starts"
     * possible: without it the permission would die with the activity and the
     * app would have to ask again on every launch.
     */
    private fun askForFolder(result: MethodChannel.Result) {
        if (pendingResult != null) {
            busy(result)
            return
        }
        pendingResult = result
        pendingSource = null
        pendingTarget = null
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        launch(intent, REQUEST_FOLDER, result)
    }

    // --- moving a snapshot in and out of a granted folder ------------------- //

    private fun syncPull(call: MethodCall, result: MethodChannel.Result) {
        val tree = call.argument<String>("uri")
        val target = call.argument<String>("target")
        if (tree == null || target == null) {
            result.error("bad_arguments", "No shared folder or destination.", null)
            return
        }
        try {
            val document = findSnapshot(Uri.parse(tree))
            if (document == null) {
                // Nothing there yet: the first sync publishes this library.
                result.success(false)
                return
            }
            val stream = contentResolver.openInputStream(document)
                ?: throw IllegalStateException("That folder cannot be read.")
            stream.use { input ->
                File(target).outputStream().use { output -> input.copyTo(output) }
            }
            result.success(true)
        } catch (error: Exception) {
            result.error(
                "transfer_failed",
                error.message ?: "The shared folder could not be read.",
                null,
            )
        }
    }

    private fun syncPush(call: MethodCall, result: MethodChannel.Result) {
        val tree = call.argument<String>("uri")
        val source = call.argument<String>("source")
        if (tree == null || source == null) {
            result.error("bad_arguments", "No shared folder or snapshot.", null)
            return
        }
        try {
            val folder = Uri.parse(tree)
            val document = findSnapshot(folder) ?: createSnapshot(folder)
            val stream = openForRewrite(folder, document)
            stream.use { output ->
                File(source).inputStream().use { input -> input.copyTo(output) }
            }
            result.success(true)
        } catch (error: Exception) {
            result.error(
                "transfer_failed",
                error.message ?: "The shared folder cannot be written to.",
                null,
            )
        }
    }

    private fun syncFolderName(call: MethodCall, result: MethodChannel.Result) {
        val tree = call.argument<String>("uri")
        if (tree == null) {
            result.error("bad_arguments", "No shared folder.", null)
            return
        }
        result.success(folderName(Uri.parse(tree)))
    }

    private fun syncPermission(call: MethodCall, result: MethodChannel.Result) {
        val tree = call.argument<String>("uri")
        if (tree == null) {
            result.error("bad_arguments", "No shared folder.", null)
            return
        }
        result.success(canWrite(Uri.parse(tree)))
    }

    /** The snapshot inside a granted tree, or `null` when it is not there yet. */
    private fun findSnapshot(tree: Uri): Uri? {
        val parentId = DocumentsContract.getTreeDocumentId(tree)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            OpenableColumns.DISPLAY_NAME,
        )
        contentResolver.query(children, columns, null, null, null)?.use { cursor ->
            val idColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            while (cursor.moveToNext()) {
                if (idColumn >= 0 && nameColumn >= 0 &&
                    cursor.getString(nameColumn) == SNAPSHOT_NAME
                ) {
                    return DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(idColumn))
                }
            }
        }
        return null
    }

    private fun createSnapshot(tree: Uri): Uri {
        val parent = DocumentsContract.buildDocumentUriUsingTree(
            tree,
            DocumentsContract.getTreeDocumentId(tree),
        )
        return DocumentsContract.createDocument(
            contentResolver,
            parent,
            "application/octet-stream",
            SNAPSHOT_NAME,
        ) ?: throw IllegalStateException("The shared folder cannot be written to.")
    }

    /**
     * An output stream that starts at zero bytes.
     *
     * `"wt"` is the documented way to say that, but not every provider honours
     * it — older Google Drive builds reject the mode outright. Where it is
     * refused, the old document is deleted and a fresh one created instead:
     * writing over a longer file with `"w"` would leave the tail of the previous
     * snapshot behind, and a snapshot with a tail is a corrupt database.
     */
    private fun openForRewrite(folder: Uri, document: Uri): OutputStream {
        val truncated = try {
            contentResolver.openOutputStream(document, "wt")
        } catch (error: Exception) {
            null
        }
        if (truncated != null) return truncated
        DocumentsContract.deleteDocument(contentResolver, document)
        val fresh = createSnapshot(folder)
        return contentResolver.openOutputStream(fresh)
            ?: throw IllegalStateException("The shared folder cannot be written to.")
    }

    private fun folderName(tree: Uri): String? {
        val document = DocumentsContract.buildDocumentUriUsingTree(
            tree,
            DocumentsContract.getTreeDocumentId(tree),
        )
        return try {
            contentResolver.query(document, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (index >= 0 && !cursor.isNull(index)) cursor.getString(index) else null
                    } else {
                        null
                    }
                }
        } catch (error: Exception) {
            null
        }
    }

    /** Is the folder the user granted still writable on this launch? */
    private fun canWrite(tree: Uri): Boolean = try {
        contentResolver.persistedUriPermissions.any {
            it.uri == tree && it.isWritePermission
        }
    } catch (error: Exception) {
        false
    }

    @Deprecated("FlutterActivity is a plain Activity; this is the only hook it offers.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_EXPORT &&
            requestCode != REQUEST_PICK &&
            requestCode != REQUEST_FOLDER
        ) {
            return
        }

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
            when (requestCode) {
                REQUEST_EXPORT -> {
                    val from = source ?: throw IllegalStateException("The library is no longer open.")
                    val stream = contentResolver.openOutputStream(uri)
                        ?: throw IllegalStateException("That folder cannot be written to.")
                    stream.use { output ->
                        from.inputStream().use { input -> input.copyTo(output) }
                    }
                    result.success(displayName(uri) ?: uri.lastPathSegment ?: "")
                }

                REQUEST_PICK -> {
                    val to = target ?: throw IllegalStateException("Nowhere to copy the file to.")
                    val stream = contentResolver.openInputStream(uri)
                        ?: throw IllegalStateException("That file cannot be read.")
                    stream.use { input ->
                        to.outputStream().use { output -> input.copyTo(output) }
                    }
                    result.success(to.absolutePath)
                }

                else -> {
                    // Keep the read/write grant across restarts.
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                    result.success(
                        mapOf(
                            "uri" to uri.toString(),
                            "name" to (folderName(uri) ?: uri.lastPathSegment ?: ""),
                        ),
                    )
                }
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
