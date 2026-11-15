package dev.pylon.pylon

import android.app.ActivityOptions
import android.app.PendingIntent
import android.os.Build
import android.view.WindowManager
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The Dart side runs the Resid core as processes: `libpylon.so` (the
 * connection) and `libpylon_term.so` (the confined emulator) are static
 * executables packaged as native libraries, so Android extracts them to
 * nativeLibraryDir, the one place an app may execute its own code from.
 * Terminal content is kept out of screenshots and recents (FLAG_SECURE)
 * unless the principal turns that off (SPEC 15).
 */
class MainActivity : FlutterActivity() {
    private val agent by lazy { SymbolonAgent(applicationContext) }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
    }

    // Symbolon's consent sheet, started by Pylon while it is in front (the
    // principal is using it): Symbolon's service, in the background, may
    // not start an activity itself. Called off the main thread.
    private fun startConsent(pi: PendingIntent): Boolean {
        val done = CountDownLatch(1)
        var ok = false
        runOnUiThread {
            ok = try {
                val opts = if (Build.VERSION.SDK_INT >= 34) {
                    @Suppress("DEPRECATION")
                    ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED).toBundle()
                } else null
                startIntentSender(pi.intentSender, null, 0, 0, 0, opts)
                true
            } catch (e: Exception) {
                false
            }
            done.countDown()
        }
        done.await(10, TimeUnit.SECONDS)
        return ok
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pylon/platform").setMethodCallHandler { call, result ->
            when (call.method) {
                "paths" -> result.success(
                    mapOf(
                        "bin" to applicationInfo.nativeLibraryDir,
                        "files" to filesDir.absolutePath,
                    )
                )
                "agent" -> {
                    val conn = (call.argument<Number>("conn"))?.toLong()
                    val req = call.argument<ByteArray>("request")
                    if (conn == null || req == null) { result.success(null) } else {
                        Thread {
                            val r = agent.call(conn, req) { pi -> startConsent(pi) }
                            runOnUiThread { result.success(r) }
                        }.start()
                    }
                }
                "agentClose" -> {
                    val conn = (call.arguments as? Number)?.toLong()
                    if (conn != null) Thread { agent.close(conn) }.start()
                    result.success(null)
                }
                "secure" -> {
                    val on = call.arguments as? Boolean ?: true
                    runOnUiThread {
                        if (on) window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
                        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
