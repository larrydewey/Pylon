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
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import java.io.InputStream
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
 * The local shell (SPEC 13) and the terminal emulators (SPEC 12) run in
 * isolated processes under UIDs of their own ([LocalShellService]; one
 * [TermService] instance, and so one process and UID, per terminal);
 * this activity holds one end of a socket pair per program
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

    /**
     * One isolated service, bound on first use. With an [instance] name it
     * is one instance of the service, in an isolated process (and under an
     * isolated UID) of its own (Context.bindIsolatedService, Android 10):
     * each terminal emulator gets one, so an emulator a host's output took
     * over shares no process, UID or relay with another host's terminal
     * (SPEC 12). Without one, one process for every program it runs (the
     * local shells, all the principal's own).
     */
    private inner class Isolated(val cls: Class<out IsolatedRelayService>, val descriptor: String, val instance: String? = null) {
        var binder: IBinder? = null
        var bound = false
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
                // A per-terminal sandbox is never started again.
                if (instance != null) unbind()
            }

            override fun onBindingDied(name: ComponentName?) {
                onServiceDisconnected(name)
                unbind()
            }
        }

        private fun bind(): Boolean {
            val i = Intent(this@MainActivity, cls)
            bound = true
            return try {
                if (instance != null) bindIsolatedService(i, Context.BIND_AUTO_CREATE, instance, mainExecutor, conn)
                else bindService(i, conn, Context.BIND_AUTO_CREATE)
            } catch (e: RuntimeException) {
                // SecurityException, IllegalArgumentException: no sandbox, no program.
                false
            }
        }

        fun with(then: (IBinder?) -> Unit) {
            val b = binder
            if (b != null) { then(b); return }
            waiting.add(then)
            if (waiting.size == 1 && !bound && !bind()) {
                val w = ArrayList(waiting)
                waiting.clear()
                unbind()
                w.forEach { it(null) }
            }
        }

        fun unbind() {
            if (!bound) return
            bound = false
            binder = null
            val w = ArrayList(waiting)
            waiting.clear()
            try { unbindService(conn) } catch (_: IllegalArgumentException) {}
            w.forEach { it(null) }
        }
    }

    // Per-terminal sandboxes are named from this activity's own counter and
    // a random tag, never from anything the Dart side sends, so no two
    // terminals (nor a terminal of an earlier activity still going away)
    // can share an instance.
    private val termTag = java.security.SecureRandom().let { r -> ByteArray(8).also { r.nextBytes(it) } }.joinToString("") { "%02x".format(it) }
    private var nextTerm = 1

    // Documents for the Files page (SPEC 11): only ones the principal picked
    // in the system's document picker, so Pylon needs no storage
    // permission and sees nothing else. Reads and writes run in order on
    // [docIo]; a download that failed is deleted rather than left partial.
    private class Doc(val uri: Uri, val input: InputStream?, val output: OutputStream?)
    private val docs = HashMap<Int, Doc>()
    private var nextDoc = 1
    private val docIo = Executors.newSingleThreadExecutor()
    private var docPending: MethodChannel.Result? = null
    private var docName: String = ""
    private val docCreateCode = 41
    private val docOpenCode = 42

    private fun docPick(code: Int, name: String, result: MethodChannel.Result) {
        if (docPending != null) { result.error("doc", "a document picker is already open", null); return }
        val i = if (code == docCreateCode) {
            Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, name)
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
        }
        docPending = result
        docName = name
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(i, code)
        } catch (e: Exception) {
            docPending = null
            result.error("doc", "no document picker: ${e.message}", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != docCreateCode && requestCode != docOpenCode) return
        val result = docPending ?: return
        docPending = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) { result.success(null); return }
        docIo.execute {
            try {
                var name = docName
                var size = -1L
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        if (!c.isNull(0)) name = c.getString(0)
                        if (!c.isNull(1)) size = c.getLong(1)
                    }
                }
                val doc = if (requestCode == docCreateCode) Doc(uri, null, contentResolver.openOutputStream(uri, "wt")) else Doc(uri, contentResolver.openInputStream(uri), null)
                if (doc.input == null && doc.output == null) throw IOException("cannot open the document")
                runOnUiThread {
                    val id = nextDoc++
                    docs[id] = doc
                    result.success(mapOf("id" to id, "name" to name, "label" to name, "size" to size))
                }
            } catch (e: Exception) {
                runOnUiThread { result.error("doc", e.message ?: "cannot open the document", null) }
            }
        }
    }

    private val localShell = Isolated(LocalShellService::class.java, LocalShellService.DESCRIPTOR)

    /** A terminal emulator in a sandbox of its own, ended with its terminal. */
    private fun newTerm() = Isolated(TermService::class.java, TermService.DESCRIPTOR, "term_${termTag}_${nextTerm++}")

    private fun startShell(svc: Isolated, rows: Int, cols: Int, result: MethodChannel.Result) = svc.with { b ->
        if (b == null) {
            if (svc.instance != null) svc.unbind()
            result.error("local", "the isolated service cannot be bound", null)
            return@with
        }
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
            if (svc.instance != null) svc.unbind()
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
        val svc = shellOf.remove(id)
        // A terminal's own sandbox goes with it: unbinding the last
        // binding of an isolated instance ends its process.
        if (svc?.instance != null) svc.unbind()
        val out = shellOut.remove(id)
        val fd = shells.remove(id)
        writer.execute {
            try { out?.close() } catch (_: IOException) {}
            try { fd?.close() } catch (_: IOException) {}
        }
    }

    /**
     * The connection processes this app started (`libpylon.so`, children of
     * this process). When the activity goes (its task swiped away), the
     * Flutter side that held their pipes goes with it but this process may
     * stay cached, holding the pipes open: they would keep their
     * connections up with nothing left to show them. They end with it.
     */
    private fun endCoreChildren() {
        val me = android.os.Process.myPid()
        val procs = java.io.File("/proc").listFiles() ?: return
        for (d in procs) {
            val pid = d.name.toIntOrNull() ?: continue
            try {
                val stat = java.io.File(d, "stat").readText()
                val close = stat.lastIndexOf(')')
                if (close < 0) continue
                val ppid = stat.substring(close + 2).split(' ').getOrNull(1)?.toIntOrNull() ?: continue
                if (ppid == me) android.os.Process.killProcess(pid)
            } catch (_: Exception) {
            }
        }
    }

    override fun onDestroy() {
        if (!isChangingConfigurations) endCoreChildren()
        for (id in ArrayList(shells.keys)) closeShell(id)
        localShell.unbind()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        SensitiveClip.focused = hasFocus
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
                "clipCopy" -> {
                    val text = call.arguments as? String
                    result.success(text != null && SensitiveClip.copy(this, text))
                }
                "localStart" -> {
                    val rows = call.argument<Number>("rows")?.toInt() ?: 24
                    val cols = call.argument<Number>("cols")?.toInt() ?: 80
                    startShell(if (call.argument<String>("kind") == "term") newTerm() else localShell, rows, cols, result)
                }
                "localInput" -> {
                    val id = call.argument<Number>("id")?.toInt()
                    val data = call.argument<ByteArray>("data")
                    val out = if (id != null) shellOut[id] else null
                    if (out != null && data != null) writer.execute { try { out.write(data); out.flush() } catch (_: IOException) {} }
                    result.success(null)
                }
                "docCreate" -> docPick(docCreateCode, call.argument<String>("name") ?: "download", result)
                "docOpen" -> docPick(docOpenCode, "", result)
                "docWrite" -> {
                    val doc = call.argument<Number>("id")?.toInt()?.let { docs[it] }
                    val data = call.argument<ByteArray>("data")
                    if (doc?.output == null || data == null) { result.error("doc", "no such document", null) } else {
                        docIo.execute {
                            try { doc.output.write(data); runOnUiThread { result.success(null) } }
                            catch (e: IOException) { runOnUiThread { result.error("doc", e.message ?: "write failed", null) } }
                        }
                    }
                }
                "docRead" -> {
                    val doc = call.argument<Number>("id")?.toInt()?.let { docs[it] }
                    val n = call.argument<Number>("n")?.toInt() ?: 65536
                    if (doc?.input == null) { result.error("doc", "no such document", null) } else {
                        docIo.execute {
                            try {
                                val buf = ByteArray(n.coerceIn(1, 1048576))
                                val got = doc.input.read(buf)
                                runOnUiThread { result.success(if (got <= 0) ByteArray(0) else buf.copyOf(got)) }
                            } catch (e: IOException) { runOnUiThread { result.error("doc", e.message ?: "read failed", null) } }
                        }
                    }
                }
                "docClose" -> {
                    val id = call.argument<Number>("id")?.toInt()
                    val ok = call.argument<Boolean>("ok") ?: true
                    val doc = if (id != null) docs.remove(id) else null
                    docIo.execute {
                        try { doc?.input?.close() } catch (_: IOException) {}
                        try { doc?.output?.close() } catch (_: IOException) {}
                        if (doc?.output != null && !ok) {
                            try { DocumentsContract.deleteDocument(contentResolver, doc.uri) } catch (_: Exception) {}
                        }
                        runOnUiThread { result.success(null) }
                    }
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
