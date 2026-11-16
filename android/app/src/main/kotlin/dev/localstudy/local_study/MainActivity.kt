package dev.localstudy.local_study

import android.content.Intent
import android.os.Bundle
import androidx.core.view.WindowCompat
import dev.localstudy.ocr.OcrPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val platformPlugin = AndroidPlatformPlugin()

    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
        platformPlugin.attachActivity(this)
        platformPlugin.handleIncomingIntent(intent, isColdStart = true)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(OcrPlugin())
        flutterEngine.plugins.add(platformPlugin)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        platformPlugin.handleIncomingIntent(intent, isColdStart = false)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (platformPlugin.onActivityResult(requestCode, resultCode, data)) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        platformPlugin.detachActivity(this)
        super.onDestroy()
    }
}
