package dev.pylon.pylon

import android.view.WindowManager
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
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
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
