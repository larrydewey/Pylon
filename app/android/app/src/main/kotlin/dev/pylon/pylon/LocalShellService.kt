package dev.pylon.pylon

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * The local shell's sandbox on Android (SPEC 13, G8): an isolatedProcess
 * service, so it runs under a UID of its own that Android allocates for
 * this process alone, with no permissions (no INTERNET: no network), no
 * storage (it cannot open Pylon's files directory, where PYLON_HOME, the
 * host list and the pins live), and no binder to anything but Pylon's
 * activity, which binds it (Symbolon's agent service needs a signature
 * permission an isolated UID never holds).
 *
 * For each local shell the activity hands it one end of a socket pair;
 * the service runs `libpylon_local.so --android ROWS COLS` (the Resid
 * launcher: it starts /system/bin/sh with an empty environment on a
 * pseudo-terminal of its own and confines itself) and relays the pair
 * to the launcher's standard input and output unchanged: the frames of
 * pylon-local (cli/pylon_local.resid). The launcher's error output goes
 * back as frames of type 7, text for the principal. Nothing else crosses.
 */
class LocalShellService : Service() {
    companion object {
        const val DESCRIPTOR = "dev.pylon.pylon.LocalShell"
        const val START = IBinder.FIRST_CALL_TRANSACTION
    }

    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != START) return super.onTransact(code, data, reply, flags)
            data.enforceInterface(DESCRIPTOR)
            val sock = data.readFileDescriptor()
            val rows = data.readInt().coerceIn(1, 4095)
            val cols = data.readInt().coerceIn(1, 4095)
            if (sock != null) start(sock, rows, cols)
            reply?.writeNoException()
            return true
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    private fun frame(type: Int, payload: ByteArray): ByteArray {
        val n = payload.size
        return byteArrayOf(type.toByte(), (n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte()) + payload
    }

    private fun start(sock: ParcelFileDescriptor, rows: Int, cols: Int) {
        val toApp: OutputStream = ParcelFileDescriptor.AutoCloseOutputStream(sock.dup())
        val fromApp: InputStream = ParcelFileDescriptor.AutoCloseInputStream(sock)
        val lock = Any()
        fun send(b: ByteArray) = synchronized(lock) {
            try { toApp.write(b); toApp.flush() } catch (_: IOException) {}
        }
        val exe = File(applicationInfo.nativeLibraryDir, "libpylon_local.so")
        val p = try {
            ProcessBuilder(exe.path, "--android", "$rows", "$cols").also { it.environment().clear() }.start()
        } catch (e: IOException) {
            // Never a fallback to Pylon's own process: no sandbox, no shell.
            send(frame(7, "This device does not let Pylon's sandbox start a shell (${e.message}). The local shell does not start.".toByteArray()))
            try { toApp.close() } catch (_: IOException) {}
            try { fromApp.close() } catch (_: IOException) {}
            return
        }
        Thread {
            val buf = ByteArray(65536)
            try {
                while (true) {
                    val n = fromApp.read(buf)
                    if (n < 0) break
                    p.outputStream.write(buf, 0, n)
                    p.outputStream.flush()
                }
            } catch (_: IOException) {
            }
            // The app closed the shell: end of input hangs it up.
            try { p.outputStream.close() } catch (_: IOException) {}
        }.start()
        Thread {
            val buf = ByteArray(4096)
            try {
                while (true) {
                    val n = p.errorStream.read(buf)
                    if (n < 0) break
                    send(frame(7, buf.copyOf(n)))
                }
            } catch (_: IOException) {
            }
        }.start()
        Thread {
            // Whole frames only, so a type-7 frame never lands inside one.
            val buf = ByteArray(65536)
            var pending = ByteArray(0)
            try {
                while (true) {
                    val n = p.inputStream.read(buf)
                    if (n < 0) break
                    pending += buf.copyOf(n)
                    var at = 0
                    while (pending.size - at >= 5) {
                        val len = ((pending[at + 1].toInt() and 255) shl 24) or ((pending[at + 2].toInt() and 255) shl 16) or
                            ((pending[at + 3].toInt() and 255) shl 8) or (pending[at + 4].toInt() and 255)
                        if (len < 0 || len > (16 shl 20)) { p.destroy(); break }
                        if (pending.size - at < 5 + len) break
                        send(pending.copyOfRange(at, at + 5 + len))
                        at += 5 + len
                    }
                    pending = pending.copyOfRange(at, pending.size)
                }
            } catch (_: IOException) {
            }
            p.waitFor()
            synchronized(lock) { try { toApp.close() } catch (_: IOException) {} }
            try { fromApp.close() } catch (_: IOException) {}
        }.start()
    }
}
