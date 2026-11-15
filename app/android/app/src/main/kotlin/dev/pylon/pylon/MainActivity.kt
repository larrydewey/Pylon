package dev.pylon.pylon

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.view.WindowManager
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The Dart side runs the Resid core as processes: `libpylon.so` (the
 * connection) and `libpylon_term.so` (the confined emulator) are static
 * executables packaged as native libraries, so Android extracts them to
 * nativeLibraryDir, the one place an app may execute its own code from.
 * Terminal content is kept out of screenshots and recents (FLAG_SECURE)
 * unless the principal turns that off (SPEC 15).
 *
 * The local shell (SPEC 13) runs in [LocalShellService], an isolated
 * process under a UID of its own; this activity holds one end of a socket
 * pair per shell and passes bytes between it and the Dart side
 * ("localStart", "localInput", "localClose"; output on "pylon/local").
 */
class MainActivity : FlutterActivity() {
    private val agent by lazy { SymbolonAgent(applicationContext) }

    // The local shells: their ends of the socket pairs, by id.
    private val shells = HashMap<Int, ParcelFileDescriptor>()
    private val shellOut = HashMap<Int, OutputStream>()
    private var nextShell = 1
    private var localSink: EventChannel.EventSink? = null
    private var localBinder: IBinder? = null
    private val localWaiting = ArrayList<(IBinder?) -> Unit>()
    private val writer = Executors.newSingleThreadExecutor()
    private val localConn = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            localBinder = service
            val w = ArrayList(localWaiting)
            localWaiting.clear()
            w.forEach { it(service) }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // The sandbox died: every local shell ends with it.
            localBinder = null
            for (id in ArrayList(shells.keys)) closeShell(id)
        }
    }

    private fun withLocalService(then: (IBinder?) -> Unit) {
        val b = localBinder
        if (b != null) { then(b); return }
        localWaiting.add(then)
        if (localWaiting.size == 1 && !bindService(Intent(this, LocalShellService::class.java), localConn, Context.BIND_AUTO_CREATE)) {
            localWaiting.clear()
            then(null)
        }
    }

    private fun startShell(rows: Int, cols: Int, result: MethodChannel.Result) = withLocalService { b ->
        if (b == null) { result.error("local", "the local shell service cannot be bound", null); return@withLocalService }
        val pair = ParcelFileDescriptor.createSocketPair()
        val id = nextShell++
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(LocalShellService.DESCRIPTOR)
            data.writeFileDescriptor(pair[1].fileDescriptor)
            data.writeInt(rows)
            data.writeInt(cols)
            b.transact(LocalShellService.START, data, reply, 0)
            reply.readException()
        } catch (e: Exception) {
            pair[0].close()
            pair[1].close()
            result.error("local", "the local shell service failed: ${e.message}", null)
            return@withLocalService
        } finally {
            data.recycle()
            reply.recycle()
        }
        pair[1].close()
        shells[id] = pair[0]
        shellOut[id] = ParcelFileDescriptor.AutoCloseOutputStream(pair[0].dup())
        Thread {
            val input = ParcelFileDescriptor.AutoCloseInputStream(pair[0].dup())
            val buf = ByteArray(65536)
            try {
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    val chunk = buf.copyOf(n)
                    runOnUiThread { localSink?.success(mapOf("id" to id, "data" to chunk)) }
                }
            } catch (_: IOException) {
            }
            try { input.close() } catch (_: IOException) {}
            runOnUiThread {
                localSink?.success(mapOf("id" to id, "end" to true))
                closeShell(id)
            }
        }.start()
        result.success(id)
    }

    private fun closeShell(id: Int) {
        val out = shellOut.remove(id)
        val fd = shells.remove(id)
        writer.execute {
            try { out?.close() } catch (_: IOException) {}
            try { fd?.close() } catch (_: IOException) {}
        }
    }

    override fun onDestroy() {
        for (id in ArrayList(shells.keys)) closeShell(id)
        if (localBinder != null || localWaiting.isNotEmpty()) {
            try { unbindService(localConn) } catch (_: IllegalArgumentException) {}
        }
        super.onDestroy()
    }

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
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "pylon/local").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { localSink = events }
            override fun onCancel(arguments: Any?) { localSink = null }
        })
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
                "localStart" -> {
                    val rows = call.argument<Number>("rows")?.toInt() ?: 24
                    val cols = call.argument<Number>("cols")?.toInt() ?: 80
                    startShell(rows, cols, result)
                }
                "localInput" -> {
                    val id = call.argument<Number>("id")?.toInt()
                    val data = call.argument<ByteArray>("data")
                    val out = if (id != null) shellOut[id] else null
                    if (out != null && data != null) writer.execute { try { out.write(data); out.flush() } catch (_: IOException) {} }
                    result.success(null)
                }
                "localClose" -> {
                    (call.arguments as? Number)?.toInt()?.let { closeShell(it) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
