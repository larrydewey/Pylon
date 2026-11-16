package dev.pylon.pylon

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.ConnectivityManager
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
 * connection) and `libpylon_term.so` (the emulator, in [TermService]) are
 * static executables packaged as native libraries, so Android extracts them to
 * nativeLibraryDir, the one place an app may execute its own code from.
 * Terminal content is kept out of screenshots and recents (FLAG_SECURE)
 * unless the principal turns that off (SPEC 15).
 *
 * The local shell (SPEC 13) and the terminal emulator (SPEC 12) run in
 * isolated processes under UIDs of their own ([LocalShellService],
 * [TermService]); this activity holds one end of a socket pair per program
 * and passes bytes between it and the Dart side ("localStart" with kind
 * "shell" or "term", "localInput", "localClose"; output on "pylon/local").
 */
class MainActivity : FlutterActivity() {
    private val agent by lazy { SymbolonAgent(applicationContext) }

    // The isolated programs (local shells, terminal emulators): their ends
    // of the socket pairs, by id, and which service runs each.
    private val shells = HashMap<Int, ParcelFileDescriptor>()
    private val shellOut = HashMap<Int, OutputStream>()
    private val shellOf = HashMap<Int, Isolated>()
    private var nextShell = 1
    private var localSink: EventChannel.EventSink? = null
    private val writer = Executors.newSingleThreadExecutor()

    /** One isolated service, bound on first use. */
    private inner class Isolated(val cls: Class<out IsolatedRelayService>, val descriptor: String) {
        var binder: IBinder? = null
        val waiting = ArrayList<(IBinder?) -> Unit>()
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                binder = service
                val w = ArrayList(waiting)
                waiting.clear()
                w.forEach { it(service) }
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                // The sandbox died: everything it ran ends with it.
                binder = null
                for ((id, i) in HashMap(shellOf)) if (i === this@Isolated) closeShell(id)
            }
        }

        fun with(then: (IBinder?) -> Unit) {
            val b = binder
            if (b != null) { then(b); return }
            waiting.add(then)
            if (waiting.size == 1 && !bindService(Intent(this@MainActivity, cls), conn, Context.BIND_AUTO_CREATE)) {
                waiting.clear()
                then(null)
            }
        }

        fun unbind() {
            if (binder != null || waiting.isNotEmpty()) {
                try { unbindService(conn) } catch (_: IllegalArgumentException) {}
            }
        }
    }

    private val localShell = Isolated(LocalShellService::class.java, LocalShellService.DESCRIPTOR)
    private val term = Isolated(TermService::class.java, TermService.DESCRIPTOR)

    private fun startShell(svc: Isolated, rows: Int, cols: Int, result: MethodChannel.Result) = svc.with { b ->
        if (b == null) { result.error("local", "the isolated service cannot be bound", null); return@with }
        val pair = ParcelFileDescriptor.createSocketPair()
        val id = nextShell++
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(svc.descriptor)
            data.writeFileDescriptor(pair[1].fileDescriptor)
            data.writeInt(rows)
            data.writeInt(cols)
            b.transact(IsolatedRelayService.START, data, reply, 0)
            reply.readException()
        } catch (e: Exception) {
            pair[0].close()
            pair[1].close()
            result.error("local", "the isolated service failed: ${e.message}", null)
            return@with
        } finally {
            data.recycle()
            reply.recycle()
        }
        pair[1].close()
        shells[id] = pair[0]
        shellOf[id] = svc
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
        shellOf.remove(id)
        val out = shellOut.remove(id)
        val fd = shells.remove(id)
        writer.execute {
            try { out?.close() } catch (_: IOException) {}
            try { fd?.close() } catch (_: IOException) {}
        }
    }

    override fun onDestroy() {
        for (id in ArrayList(shells.keys)) closeShell(id)
        localShell.unbind()
        term.unbind()
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

    /** The active network's DNS servers and search domains as resolv.conf
     *  text, for the core's RESID_RESOLV_CONF: Android has no
     *  /etc/resolv.conf, and the core looks names up itself. Link-local
     *  servers are left out (the text has no room for their interface).
     *  Empty when there is no active network. */
    private fun resolvConf(): String {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return ""
        val lp = cm.getLinkProperties(cm.activeNetwork) ?: return ""
        val servers = lp.dnsServers.filter { !it.isLinkLocalAddress }.mapNotNull { it.hostAddress }.map { "nameserver $it" }
        val domains = (lp.domains ?: "").split(',', ' ').map { it.trim().trimEnd('.') }.filter { it.isNotEmpty() }
        val search = if (domains.isEmpty()) emptyList() else listOf("search " + domains.joinToString(" "))
        return (servers + search).joinToString("\n")
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
                "resolvConf" -> result.success(resolvConf())
                "connections" -> {
                    val n = (call.arguments as? Number)?.toInt() ?: 0
                    if (n > 0 && Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        // The notification says connections are open; the service runs either way.
                        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 7)
                    }
                    ConnectionService.update(this, n)
                    result.success(null)
                }
                "openSymbolonKeys" -> Thread {
                    val ok = agent.openKeys()
                    runOnUiThread { result.success(ok) }
                }.start()
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
                    startShell(if (call.argument<String>("kind") == "term") term else localShell, rows, cols, result)
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
