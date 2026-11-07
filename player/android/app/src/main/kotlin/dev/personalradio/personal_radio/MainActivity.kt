package dev.personalradio.personal_radio

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    companion object {
        private val worker = Executors.newSingleThreadExecutor()
    }

    private var tidalRedirect: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        collectRedirect(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        collectRedirect(intent)
    }

    private fun collectRedirect(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim() ?: return
        val uri = Uri.parse(text)
        if (uri.scheme == "https" && uri.authority == "tidal.com" &&
            uri.path == "/android/login/auth" && !uri.getQueryParameter("code").isNullOrEmpty()) {
            tidalRedirect = text
            intent.removeExtra(Intent.EXTRA_TEXT)
        }
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.personalradio/local_engine")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(LocalEngineBridge.available)
                    "openFirefox" -> {
                        val uri = Uri.parse(call.arguments as? String ?: "")
                        if (uri.scheme != "http" || uri.host != "127.0.0.1" || uri.path != "/connect-youtube") {
                            result.success(false)
                        } else {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage("org.mozilla.firefox"))
                                result.success(true)
                            } catch (_: android.content.ActivityNotFoundException) {
                                result.success(false)
                            }
                        }
                    }
                    "takeTidalRedirect" -> {
                        result.success(tidalRedirect)
                        tidalRedirect = null
                    }
                    "start", "stop" -> {
                        val context = applicationContext
                        worker.execute {
                            try {
                                val response = if (call.method == "start") {
                                    LocalEngineBridge.start(context)
                                } else {
                                    LocalEngineBridge.stop()
                                    null
                                }
                                runOnUiThread { result.success(response) }
                            } catch (_: Exception) {
                                runOnUiThread {
                                    result.error("engine", "Local engine could not start or stop.", null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
