package dev.localstudy.ocr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Handler
import android.os.Looper
import com.googlecode.tesseract.android.TessBaseAPI
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/** Bundled Tesseract and tessdata_fast; no model downloads or cloud SDK. */
class OcrPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var assets: FlutterPlugin.FlutterAssets
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)
    private val detached = AtomicBoolean(false)
    private val apiLock = Any()
    private var activeApi: TessBaseAPI? = null
    // These fields are accessed only by the single OCR worker.
    private var engine: TessBaseAPI? = null
    private var engineLanguage = ""

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        assets = binding.flutterAssets
        detached.set(false)
        channel = MethodChannel(binding.binaryMessenger, "local_study/ocr")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "availability" -> executor.execute {
                val value = try {
                    getEngine("chi_sim+eng")
                    mapOf("available" to true, "backend" to "tesseract_bundled",
                        "languages" to listOf("zh-Hans", "en"),
                        "message" to "中英文 OCR 模型随应用内置，可离线识别正文。公式与表格请核对原图。")
                } catch (_: LinkageError) {
                    unavailable("本机无法加载内置 OCR 运行库，请检查设备架构。")
                } catch (_: Exception) {
                    unavailable("内置 OCR 模型不可读，请重新安装完整应用。")
                }
                main.post { if (!detached.get()) result.success(value) }
            }
            "recognizeImage" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank() || !ownedFile(path)) {
                    result.error("invalid_path", "应用内图片不存在。", null)
                    return
                }
                if (!busy.compareAndSet(false, true)) {
                    result.error("ocr_busy", "另一页正在识别，请稍后重试。", null)
                    return
                }
                val language = if (call.argument<String>("language")?.startsWith("en") == true)
                    "eng" else "chi_sim+eng"
                executor.execute { recognize(path, language, result) }
            }
            else -> result.notImplemented()
        }
    }

    private fun unavailable(message: String) = mapOf(
        "available" to false, "backend" to "tesseract_bundled",
        "languages" to emptyList<String>(), "message" to message)

    private fun ownedFile(path: String): Boolean = try {
        val file = File(path).canonicalFile
        val root = File(context.applicationInfo.dataDir).canonicalFile.path + File.separator
        file.isFile && file.path.startsWith(root)
    } catch (_: Exception) { false }

    private fun getEngine(language: String): TessBaseAPI {
        if (engine != null && engineLanguage == language) return engine!!
        engine?.recycle()
        engine = null
        val root = File(context.noBackupFilesDir, "tesseract-fast-4.1.0")
        val tessdata = File(root, "tessdata")
        check(tessdata.mkdirs() || tessdata.isDirectory)
        for (name in listOf("chi_sim.traineddata", "eng.traineddata")) {
            val target = File(tessdata, name)
            // APK assets are the only source. Atomic rename survives a first
            // offline launch interrupted while the model is being copied.
            if (!target.isFile || target.length() == 0L) {
                val temp = File(tessdata, "$name.tmp")
                context.assets.open(assets.getAssetFilePathByName("assets/ocr/$name")).use { input ->
                    temp.outputStream().use { output -> input.copyTo(output) }
                }
                check(temp.renameTo(target))
            }
        }
        val created = TessBaseAPI()
        try {
            check(created.init(root.absolutePath + File.separator, language, TessBaseAPI.OEM_LSTM_ONLY))
            created.setPageSegMode(TessBaseAPI.PageSegMode.PSM_AUTO)
            engine = created
            engineLanguage = language
            return created
        } catch (error: Throwable) {
            created.recycle()
            throw error
        }
    }

    private fun recognize(path: String, language: String, result: MethodChannel.Result) {
        var bitmap: Bitmap? = null
        val timedOut = AtomicBoolean(false)
        val timeout = Runnable {
            timedOut.set(true)
            synchronized(apiLock) { activeApi?.stop() }
        }
        try {
            val api = getEngine(language)
            bitmap = decodeOriented(path)
            check(!detached.get())
            val width = bitmap.width
            val height = bitmap.height
            api.setImage(bitmap)
            synchronized(apiLock) { activeApi = api }
            main.postDelayed(timeout, 80_000)
            // hOCR performs interruptible recognition. Subsequent getters reuse
            // that result. Plain getUTF8Text() alone cannot be cancelled.
            api.getHOCRText(0)
            check(!timedOut.get() && !detached.get())
            val text = api.getUTF8Text() ?: ""
            val lines = mutableListOf<Map<String, Any>>()
            val iterator = api.getResultIterator()
            if (iterator != null) {
                try {
                    iterator.begin()
                    val level = TessBaseAPI.PageIteratorLevel.RIL_TEXTLINE
                    do {
                        val line = iterator.getUTF8Text(level)?.trim() ?: ""
                        val box = iterator.getBoundingBox(level)
                        if (line.isNotEmpty() && box != null && box.size >= 4 &&
                            box[2] > box[0] && box[3] > box[1]) {
                            lines.add(mapOf("text" to line,
                                "left" to (box[0].toDouble() / width).coerceIn(0.0, 1.0),
                                "top" to (box[1].toDouble() / height).coerceIn(0.0, 1.0),
                                "right" to (box[2].toDouble() / width).coerceIn(0.0, 1.0),
                                "bottom" to (box[3].toDouble() / height).coerceIn(0.0, 1.0),
                                "confidence" to (iterator.confidence(level) / 100.0).coerceIn(0.0, 1.0)))
                        }
                    } while (iterator.next(level))
                } finally { iterator.delete() }
            }
            val output = mapOf("text" to text, "blocks" to lines,
                "width" to width, "height" to height, "backend" to "tesseract_bundled")
            main.post { if (!detached.get()) result.success(output) }
        } catch (_: OutOfMemoryError) {
            main.post { if (!detached.get()) result.error("image_too_large", "本页图片过大，请缩小后重试。", null) }
        } catch (_: LinkageError) {
            main.post { if (!detached.get()) result.error("ocr_unavailable", "本机无法加载内置 OCR 运行库。", null) }
        } catch (_: Exception) {
            val message = if (timedOut.get()) "本页 OCR 超时，请缩小图片后重试。" else "本地 OCR 失败，请核对图片后重试。"
            main.post { if (!detached.get()) result.error("ocr_failed", message, null) }
        } finally {
            main.removeCallbacks(timeout)
            synchronized(apiLock) { activeApi = null }
            engine?.clear()
            bitmap?.recycle()
            busy.set(false)
        }
    }

    private fun decodeOriented(path: String): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0)
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / sample > 2800) sample *= 2
        val bitmap = requireNotNull(BitmapFactory.decodeFile(path,
            BitmapFactory.Options().apply { inSampleSize = sample }))
        val orientation = ExifInterface(path).getAttributeInt(
            ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        val matrix = Matrix().apply {
            when (orientation) {
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> postScale(-1f, 1f)
                ExifInterface.ORIENTATION_ROTATE_180 -> postRotate(180f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> postScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> { postRotate(90f); postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_ROTATE_90 -> postRotate(90f)
                ExifInterface.ORIENTATION_TRANSVERSE -> { postRotate(-90f); postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_ROTATE_270 -> postRotate(-90f)
            }
        }
        if (matrix.isIdentity) return bitmap
        val oriented = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        if (oriented !== bitmap) bitmap.recycle()
        return oriented
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detached.set(true)
        channel.setMethodCallHandler(null)
        synchronized(apiLock) { activeApi?.stop() }
        executor.execute { engine?.recycle(); engine = null }
        executor.shutdown()
    }
}

