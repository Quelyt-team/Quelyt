package dev.localstudy.local_study

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android platform bridge for Storage Access Framework (SAF), FileProvider
 * sharing/opening, and incoming VIEW/SEND intents without requiring broad
 * MANAGE_EXTERNAL_STORAGE permission.
 */
class AndroidPlatformPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val REQUEST_PICK_TREE = 4101
        private const val REQUEST_SAVE_DOCUMENT = 4102
        private const val DEFAULT_MAX_FILES = 5000
        private const val BUFFER_BYTES = 64 * 1024
        private val SUPPORTED_EXTENSIONS = setOf("pdf", "jpg", "jpeg", "png", "ppt", "pptx", "doc", "docx", "mp4", "webm", "mkv")
    }

    private lateinit var appContext: android.content.Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val detached = AtomicBoolean(false)

    private var activity: Activity? = null
    private var eventSink: EventChannel.EventSink? = null
    private val pendingShares = ArrayList<Map<String, Any?>>()
    private val handledIntentSignatures = HashSet<String>()

    private var pendingTreeResult: MethodChannel.Result? = null
    private var pendingTreeMaxFiles: Int = DEFAULT_MAX_FILES
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSourcePath: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        detached.set(false)
        methodChannel = MethodChannel(binding.binaryMessenger, "quelyt/android_platform")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "quelyt/android_platform/events")
        eventChannel.setStreamHandler(this)
        executor.execute { pruneStaleCaches() }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detached.set(true)
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
    }

    fun attachActivity(host: Activity) {
        activity = host
    }

    fun detachActivity(host: Activity) {
        if (activity === host) {
            activity = null
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        flushPendingShareEvents()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun handleIncomingIntent(intent: Intent?, isColdStart: Boolean) {
        if (intent == null) return
        val action = intent.action ?: return
        if (action != Intent.ACTION_VIEW &&
            action != Intent.ACTION_SEND &&
            action != Intent.ACTION_SEND_MULTIPLE
        ) {
            return
        }

        val uris = extractIntentUris(intent, action)
        val hasTextExtra = !intent.getStringExtra(Intent.EXTRA_TEXT).isNullOrBlank()
        if (uris.isEmpty() && !hasTextExtra) return

        val signature = buildString {
            append(action)
            append('|')
            append(intent.type ?: "")
            for (uri in uris) {
                append('|')
                append(uri.toString())
            }
            if (hasTextExtra) append("|text")
        }
        if (isColdStart && !handledIntentSignatures.add(signature)) {
            return
        }
        if (!isColdStart) {
            // SingleTop hot intents carry a distinct payload when opened anew;
            // allow distinct triggers while ignoring exact bundle replays.
            handledIntentSignatures.add(signature)
        }

        val opId = UUID.randomUUID().toString()
        val copiedUris = ArrayList<Uri>(uris)
        executor.execute {
            val payload = stageIncomingShare(
                opId = opId,
                action = action,
                mimeHint = intent.type,
                uris = copiedUris,
                hasTextOnly = copiedUris.isEmpty() && hasTextExtra,
            )
            mainHandler.post {
                if (detached.get()) return@post
                synchronized(pendingShares) {
                    pendingShares.add(payload)
                }
                flushPendingShareEvents()
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        return when (requestCode) {
            REQUEST_PICK_TREE -> {
                val result = pendingTreeResult ?: return true
                pendingTreeResult = null
                val maxFiles = pendingTreeMaxFiles
                if (resultCode != Activity.RESULT_OK || data?.data == null) {
                    result.success(null)
                    return true
                }
                val treeUri = data.data!!
                try {
                    val flags = data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
                    if (flags != 0) {
                        appContext.contentResolver.takePersistableUriPermission(treeUri, flags)
                    }
                } catch (_: SecurityException) {
                    // Not all document providers grant persistable permissions; transient session read is still valid.
                }
                executor.execute {
                    val staged = stageTreeDocuments(treeUri, maxFiles)
                    mainHandler.post {
                        if (!detached.get()) {
                            result.success(staged)
                        }
                    }
                }
                true
            }
            REQUEST_SAVE_DOCUMENT -> {
                val result = pendingSaveResult ?: return true
                val sourcePath = pendingSaveSourcePath
                pendingSaveResult = null
                pendingSaveSourcePath = null
                if (resultCode != Activity.RESULT_OK || data?.data == null || sourcePath.isNullOrBlank()) {
                    result.success(mapOf("saved" to false, "cancelled" to true, "bytes" to 0L))
                    return true
                }
                val destinationUri = data.data!!
                executor.execute {
                    val outcome = writeToContentUri(sourcePath, destinationUri)
                    mainHandler.post {
                        if (!detached.get()) {
                            result.success(outcome)
                        }
                    }
                }
                true
            }
            else -> false
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(
                mapOf(
                    "safTree" to true,
                    "safSaveAs" to true,
                    "shareFile" to true,
                    "openExternal" to true,
                    "incomingShare" to true,
                ),
            )
            "consumePendingShares" -> {
                val drained: List<Map<String, Any?>>
                synchronized(pendingShares) {
                    drained = ArrayList(pendingShares)
                    pendingShares.clear()
                }
                result.success(drained)
            }
            "availableBytes" -> {
                val path = call.argument<String>("path")
                try {
                    result.success(path?.let { android.os.StatFs(it).availableBytes })
                } catch (error: IllegalArgumentException) {
                    result.success(null)
                }
            }
            "pickDirectoryAndStage" -> {
                val host = activity
                if (host == null) {
                    result.error("no_activity", "当前页面不可用。", null)
                    return
                }
                if (pendingTreeResult != null) {
                    result.error("busy", "正在等待上一个文件夹选择完成。", null)
                    return
                }
                pendingTreeMaxFiles = (call.argument<Number>("maxFiles")?.toInt() ?: DEFAULT_MAX_FILES)
                    .coerceIn(1, 20000)
                pendingTreeResult = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                    )
                }
                try {
                    host.startActivityForResult(intent, REQUEST_PICK_TREE)
                } catch (e: ActivityNotFoundException) {
                    pendingTreeResult = null
                    result.error("unavailable", "当前系统未提供目录选择器，请尝试多选文件导入。", null)
                }
            }
            "saveFileToUserLocation" -> {
                val host = activity
                if (host == null) {
                    result.error("no_activity", "当前页面不可用。", null)
                    return
                }
                if (pendingSaveResult != null) {
                    result.error("busy", "正在等待上一次保存完成。", null)
                    return
                }
                val sourcePath = call.argument<String>("sourcePath")
                val fileName = call.argument<String>("fileName") ?: "export"
                val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                if (sourcePath.isNullOrBlank() || !isOwnedReadableFile(sourcePath)) {
                    result.error("invalid_path", "待保存的应用内文件不存在或不可读。", null)
                    return
                }
                pendingSaveResult = result
                pendingSaveSourcePath = sourcePath
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mimeType
                    putExtra(Intent.EXTRA_TITLE, sanitizeFileName(fileName, "export"))
                }
                try {
                    host.startActivityForResult(intent, REQUEST_SAVE_DOCUMENT)
                } catch (_: ActivityNotFoundException) {
                    pendingSaveResult = null
                    pendingSaveSourcePath = null
                    result.error("unavailable", "当前系统未提供文件保存器，可改为直接分享。", null)
                }
            }
            "shareFile" -> {
                val path = call.argument<String>("path")
                val mimeType = call.argument<String>("mimeType")
                val title = call.argument<String>("title") ?: "分享文件"
                if (path.isNullOrBlank() || !isOwnedReadableFile(path)) {
                    result.success(mapOf("ok" to false, "code" to "invalid_path", "error" to "找不到要分享的文件。"))
                    return
                }
                executor.execute {
                    val outcome = launchShareIntent(path, mimeType, title)
                    mainHandler.post { if (!detached.get()) result.success(outcome) }
                }
            }
            "openFileExternally" -> {
                val path = call.argument<String>("path")
                val mimeType = call.argument<String>("mimeType")
                if (path.isNullOrBlank() || !isOwnedReadableFile(path)) {
                    result.success(mapOf("ok" to false, "code" to "invalid_path", "error" to "找不到要打开的文件。"))
                    return
                }
                executor.execute {
                    val outcome = launchExternalViewIntent(path, mimeType)
                    mainHandler.post { if (!detached.get()) result.success(outcome) }
                }
            }
            "cleanupStagedDirectory" -> {
                val path = call.argument<String>("path")
                if (!path.isNullOrBlank()) {
                    executor.execute { deleteIfStagedPath(path) }
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun flushPendingShareEvents() {
        val sink = eventSink ?: return
        val items: List<Map<String, Any?>>
        synchronized(pendingShares) {
            if (pendingShares.isEmpty()) return
            items = ArrayList(pendingShares)
            pendingShares.clear()
        }
        for (item in items) {
            sink.success(item)
        }
    }

    private fun extractIntentUris(intent: Intent, action: String): List<Uri> {
        val out = ArrayList<Uri>()
        when (action) {
            Intent.ACTION_VIEW -> intent.data?.let { out.add(it) }
            Intent.ACTION_SEND -> {
                val uri = parcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                    ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
                if (uri != null) out.add(uri)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val list = parcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                if (!list.isNullOrEmpty()) {
                    out.addAll(list)
                } else {
                    val clip = intent.clipData
                    if (clip != null) {
                        for (i in 0 until clip.itemCount) {
                            clip.getItemAt(i).uri?.let { out.add(it) }
                        }
                    }
                }
            }
        }
        return out
    }

    @Suppress("DEPRECATION")
    private fun <T> parcelableExtra(intent: Intent, key: String, clazz: Class<T>): T? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(key, clazz)
        } else {
            @Suppress("UNCHECKED_CAST")
            intent.getParcelableExtra<Uri>(key) as? T
        }
    }

    @Suppress("DEPRECATION")
    private fun <T : android.os.Parcelable> parcelableArrayListExtra(
        intent: Intent,
        key: String,
        clazz: Class<T>,
    ): ArrayList<T>? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(key, clazz)
        } else {
            @Suppress("UNCHECKED_CAST")
            intent.getParcelableArrayListExtra<T>(key)
        }
    }

    private fun stageIncomingShare(
        opId: String,
        action: String,
        mimeHint: String?,
        uris: List<Uri>,
        hasTextOnly: Boolean,
    ): Map<String, Any?> {
        val root = File(File(appContext.cacheDir, "shared_inbox"), opId)
        root.mkdirs()
        val stagedItems = ArrayList<Map<String, Any?>>()
        val rejected = ArrayList<String>()

        if (hasTextOnly) {
            rejected.add("纯文本或网页链接分享暂不直接生成 PDF；请分享 PDF、JPG 或 PNG 原件。")
        }

        val resolver = appContext.contentResolver
        for ((index, uri) in uris.withIndex()) {
            val meta = queryMeta(uri)
            val resolvedMime = meta.mimeType ?: mimeHint
            val displayName = sanitizeFileName(
                meta.displayName ?: uri.lastPathSegment ?: "shared_${index + 1}",
                "shared_${index + 1}",
            )
            val ext = inferSupportedExtension(displayName, resolvedMime)
            if (ext == null) {
                rejected.add("$displayName：暂不支持的学习资料格式")
                continue
            }
            val finalName = if (displayName.lowercase().endsWith(".$ext")) {
                displayName
            } else {
                "$displayName.$ext"
            }
            val target = uniqueChildFile(root, finalName)
            try {
                if (meta.sizeBytes > 0 && android.os.StatFs(root.absolutePath).availableBytes < meta.sizeBytes) {
                    throw IllegalStateException("设备空间不足")
                }
                val input = resolver.openInputStream(uri)
                    ?: throw IllegalStateException("无法打开授权内容流")
                val copied = input.use { src ->
                    target.outputStream().use { dst -> copyStream(src, dst) }
                }
                if (copied <= 0L) {
                    target.delete()
                    rejected.add("$finalName：文件内容为空或不可读")
                    continue
                }
                stagedItems.add(
                    mapOf(
                        "name" to finalName,
                        "path" to target.absolutePath,
                        "mime" to (resolvedMime ?: ""),
                        "sizeBytes" to copied,
                    ),
                )
            } catch (e: Exception) {
                target.delete()
                rejected.add("$finalName：读取失败（${e.message ?: "权限失效或远端文件不可用"}）")
            }
        }

        return mapOf(
            "opId" to opId,
            "action" to action,
            "stagingDirectory" to root.absolutePath,
            "items" to stagedItems,
            "rejected" to rejected,
        )
    }

    private fun stageTreeDocuments(treeUri: Uri, maxFiles: Int): Map<String, Any?> {
        val opId = UUID.randomUUID().toString()
        val rootStage = File(File(appContext.cacheDir, "saf_imports"), opId)
        rootStage.mkdirs()

        val resolver = appContext.contentResolver
        val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
        val rootDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocId)
        val rootName = sanitizeSegment(queryMeta(rootDocUri).displayName ?: "导入文件夹", "导入文件夹")

        val files = ArrayList<Map<String, Any?>>()
        val unsupported = ArrayList<String>()
        val unreadable = ArrayList<String>()
        var totalBytes = 0L
        var truncated = false

        val queue = ArrayDeque<Pair<String, String>>()
        queue.add(treeDocId to "")

        while (queue.isNotEmpty() && !truncated) {
            val (docId, relDir) = queue.removeFirst()
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
            try {
                resolver.query(
                    childrenUri,
                    arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                        DocumentsContract.Document.COLUMN_MIME_TYPE,
                        DocumentsContract.Document.COLUMN_SIZE,
                    ),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    val idCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                    val nameCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                    val mimeCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                    val sizeCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                    while (cursor.moveToNext()) {
                        val childId = if (idCol >= 0) cursor.getString(idCol) else null
                        if (childId.isNullOrBlank()) continue
                        val rawName = if (nameCol >= 0) cursor.getString(nameCol) else null
                        val name = sanitizeSegment(rawName ?: "item", "item")
                        val mime = if (mimeCol >= 0) cursor.getString(mimeCol) else null
                        val size = if (sizeCol >= 0 && !cursor.isNull(sizeCol)) cursor.getLong(sizeCol) else 0L
                        val rel = if (relDir.isEmpty()) name else "$relDir/$name"

                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            if (!name.startsWith(".")) {
                                queue.add(childId to rel)
                            }
                            continue
                        }

                        if (files.size >= maxFiles) {
                            truncated = true
                            break
                        }

                        val ext = inferSupportedExtension(name, mime)
                        if (ext == null) {
                            unsupported.add(rel)
                            continue
                        }

                        val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childId)
                        val targetName = if (name.lowercase().endsWith(".$ext")) name else "$name.$ext"
                        val stagedRel = if (relDir.isEmpty()) targetName else "$relDir/$targetName"
                        val targetFile = resolveSafeChild(rootStage, stagedRel)
                        if (targetFile == null) {
                            unreadable.add(rel)
                            continue
                        }
                        targetFile.parentFile?.mkdirs()
                        try {
                            val input = resolver.openInputStream(childUri)
                                ?: throw IllegalStateException("无法读取文件流")
                            val copied = input.use { src ->
                                targetFile.outputStream().use { dst -> copyStream(src, dst) }
                            }
                            totalBytes += copied
                            files.add(
                                mapOf(
                                    "path" to targetFile.absolutePath,
                                    "relativePath" to stagedRel,
                                    "name" to targetName,
                                    "sizeBytes" to if (copied > 0L) copied else size,
                                ),
                            )
                        } catch (_: Exception) {
                            targetFile.delete()
                            unreadable.add(rel)
                        }
                    }
                } ?: run {
                    unreadable.add(if (relDir.isEmpty()) rootName else relDir)
                }
            } catch (_: SecurityException) {
                unreadable.add(if (relDir.isEmpty()) rootName else relDir)
            } catch (_: Exception) {
                unreadable.add(if (relDir.isEmpty()) rootName else relDir)
            }
        }

        return mapOf(
            "opId" to opId,
            "rootName" to rootName,
            "stagingDirectory" to rootStage.absolutePath,
            "files" to files,
            "unsupported" to unsupported,
            "unreadable" to unreadable,
            "truncated" to truncated,
            "totalBytes" to totalBytes,
        )
    }

    private fun writeToContentUri(sourcePath: String, destinationUri: Uri): Map<String, Any?> {
        val sourceFile = File(sourcePath)
        if (!sourceFile.isFile) {
            return mapOf("saved" to false, "cancelled" to false, "bytes" to 0L, "error" to "源文件已不存在。")
        }
        return try {
            val out = appContext.contentResolver.openOutputStream(destinationUri, "wt")
                ?: return mapOf("saved" to false, "cancelled" to false, "bytes" to 0L, "error" to "无法写入选定目标。")
            val written = out.use { dst ->
                sourceFile.inputStream().use { src -> copyStream(src, dst) }
            }
            val meta = queryMeta(destinationUri)
            mapOf(
                "saved" to true,
                "cancelled" to false,
                "bytes" to written,
                "displayName" to (meta.displayName ?: sourceFile.name),
            )
        } catch (e: Exception) {
            mapOf(
                "saved" to false,
                "cancelled" to false,
                "bytes" to 0L,
                "error" to (e.message ?: "写入系统文件失败"),
            )
        }
    }

    private fun launchShareIntent(path: String, explicitMime: String?, title: String): Map<String, Any?> {
        val host = activity ?: return mapOf("ok" to false, "code" to "no_activity", "error" to "当前界面不可分享。")
        return try {
            val staged = stageExportForProvider(File(path))
            val uri = FileProvider.getUriForFile(host, "${host.packageName}.fileprovider", staged)
            val mime = explicitMime ?: mimeTypeForName(staged.name)
            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = android.content.ClipData.newRawUri(staged.name, uri)
            }
            val chooser = Intent.createChooser(sendIntent, title).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            mainHandler.post {
                try {
                    host.startActivity(chooser)
                } catch (_: Exception) {
                    // Chooser cancellation or transient window detach should not crash.
                }
            }
            mapOf("ok" to true)
        } catch (e: Exception) {
            mapOf("ok" to false, "code" to "share_failed", "error" to (e.message ?: "无法发起分享。"))
        }
    }

    private fun launchExternalViewIntent(path: String, explicitMime: String?): Map<String, Any?> {
        val host = activity ?: return mapOf("ok" to false, "code" to "no_activity", "error" to "当前界面不可打开。")
        return try {
            val staged = stageExportForProvider(File(path))
            val uri = FileProvider.getUriForFile(host, "${host.packageName}.fileprovider", staged)
            val mime = explicitMime ?: mimeTypeForName(staged.name)
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val canHandle = viewIntent.resolveActivity(host.packageManager) != null
            if (!canHandle) {
                return mapOf(
                    "ok" to false,
                    "code" to "no_receiver",
                    "error" to "设备上没有可打开此类文件的应用，请尝试分享或保存到设备。",
                )
            }
            mainHandler.post {
                try {
                    host.startActivity(viewIntent)
                } catch (_: ActivityNotFoundException) {
                    // Handled above when resolveActivity works; ignore if removed mid-flight.
                }
            }
            mapOf("ok" to true)
        } catch (_: ActivityNotFoundException) {
            mapOf(
                "ok" to false,
                "code" to "no_receiver",
                "error" to "设备上没有可打开此类文件的应用，请尝试分享或保存到设备。",
            )
        } catch (e: Exception) {
            mapOf("ok" to false, "code" to "open_failed", "error" to (e.message ?: "外部应用打开失败。"))
        }
    }

    private fun stageExportForProvider(source: File): File {
        val dir = File(appContext.cacheDir, "shared_exports")
        dir.mkdirs()
        val cleanName = sanitizeFileName(source.name, "quelyt-file")
        val target = File(dir, cleanName)
        if (source.canonicalPath != target.canonicalPath) {
            source.inputStream().use { src ->
                target.outputStream().use { dst -> copyStream(src, dst) }
            }
        }
        return target
    }

    private fun isOwnedReadableFile(path: String): Boolean {
        return try {
            val candidate = File(path).canonicalFile
            if (!candidate.isFile) return false
            val appRoot = File(appContext.applicationInfo.dataDir).canonicalFile.path + File.separator
            val cacheRoot = appContext.cacheDir.canonicalFile.path + File.separator
            val filesRoot = appContext.filesDir.canonicalFile.path + File.separator
            val extCache = appContext.externalCacheDir?.canonicalFile?.path?.let { "$it${File.separator}" }
            candidate.path.startsWith(appRoot) ||
                candidate.path.startsWith(cacheRoot) ||
                candidate.path.startsWith(filesRoot) ||
                (extCache != null && candidate.path.startsWith(extCache))
        } catch (_: Exception) {
            false
        }
    }

    private fun deleteIfStagedPath(path: String) {
        try {
            val target = File(path).canonicalFile
            val inbox = File(appContext.cacheDir, "shared_inbox").canonicalFile.path + File.separator
            val saf = File(appContext.cacheDir, "saf_imports").canonicalFile.path + File.separator
            if (target.path.startsWith(inbox) || target.path.startsWith(saf)) {
                target.deleteRecursively()
            }
        } catch (_: Exception) {
            // Best-effort cache cleanup only.
        }
    }

    private fun pruneStaleCaches() {
        val cutoff = System.currentTimeMillis() - 24L * 60L * 60L * 1000L
        for (folderName in listOf("shared_inbox", "saf_imports", "shared_exports")) {
            val dir = File(appContext.cacheDir, folderName)
            val children = dir.listFiles() ?: continue
            for (child in children) {
                if (child.lastModified() < cutoff) {
                    child.deleteRecursively()
                }
            }
        }
    }

    private data class UriMeta(
        val displayName: String?,
        val mimeType: String?,
        val sizeBytes: Long,
    )

    private fun queryMeta(uri: Uri): UriMeta {
        var name: String? = null
        var size = 0L
        val mime = appContext.contentResolver.getType(uri)
        try {
            appContext.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIdx >= 0) name = cursor.getString(nameIdx)
                    if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) size = cursor.getLong(sizeIdx)
                }
            }
        } catch (_: Exception) {
            // Fall back to URI segment/mime when provider rejects projection.
        }
        return UriMeta(name, mime, size)
    }

    private fun inferSupportedExtension(name: String, mime: String?): String? {
        val dot = name.lastIndexOf('.')
        if (dot >= 0 && dot < name.length - 1) {
            val ext = name.substring(dot + 1).lowercase()
            if (ext in SUPPORTED_EXTENSIONS) return ext
        }
        return when (mime?.lowercase()) {
            "application/pdf" -> "pdf"
            "image/jpeg", "image/jpg" -> "jpg"
            "image/png" -> "png"
            "application/vnd.ms-powerpoint" -> "ppt"
            "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> "pptx"
            "application/msword" -> "doc"
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "docx"
            "video/mp4" -> "mp4"
            "video/webm" -> "webm"
            "video/x-matroska" -> "mkv"
            else -> null
        }
    }

    private fun mimeTypeForName(name: String): String {
        val lower = name.lowercase()
        return when {
            lower.endsWith(".pdf") -> "application/pdf"
            lower.endsWith(".png") -> "image/png"
            lower.endsWith(".jpg") || lower.endsWith(".jpeg") -> "image/jpeg"
            lower.endsWith(".ppt") -> "application/vnd.ms-powerpoint"
            lower.endsWith(".pptx") -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            lower.endsWith(".doc") -> "application/msword"
            lower.endsWith(".docx") -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            lower.endsWith(".mp4") -> "video/mp4"
            lower.endsWith(".webm") -> "video/webm"
            lower.endsWith(".mkv") -> "video/x-matroska"
            lower.endsWith(".zip") -> "application/zip"
            lower.endsWith(".md") -> "text/markdown"
            else -> "application/octet-stream"
        }
    }

    private fun sanitizeFileName(raw: String, fallback: String): String {
        val trimmed = raw.replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1F]"), "_").trim()
        return if (trimmed.isEmpty() || trimmed == "." || trimmed == "..") fallback else trimmed
    }

    private fun sanitizeSegment(raw: String, fallback: String): String {
        return sanitizeFileName(raw, fallback)
    }

    private fun resolveSafeChild(root: File, relativePath: String): File? {
        val segments = relativePath.split('/').filter { it.isNotEmpty() }
        if (segments.isEmpty()) return null
        var current = root
        for (segment in segments) {
            val clean = sanitizeSegment(segment, "item")
            current = File(current, clean)
        }
        val rootPath = root.canonicalFile.path + File.separator
        val resolvedPath = current.canonicalFile.path
        return if (resolvedPath.startsWith(rootPath)) current else null
    }

    private fun uniqueChildFile(parent: File, fileName: String): File {
        var candidate = File(parent, fileName)
        if (!candidate.exists()) return candidate
        val dot = fileName.lastIndexOf('.')
        val stem = if (dot > 0) fileName.substring(0, dot) else fileName
        val ext = if (dot > 0) fileName.substring(dot) else ""
        var index = 2
        while (candidate.exists()) {
            candidate = File(parent, "${stem}_$index$ext")
            index++
        }
        return candidate
    }

    private fun copyStream(input: InputStream, output: OutputStream): Long {
        val buffer = ByteArray(BUFFER_BYTES)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            output.write(buffer, 0, read)
            total += read
        }
        output.flush()
        return total
    }
}
