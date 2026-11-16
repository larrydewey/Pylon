package dev.pylon.pylon

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * An isolatedProcess service that runs one of Pylon's confined programs per
 * request and relays a socket pair the activity hands it to the program's
 * standard input and output unchanged (frames: type (1) | length (4) |
 * payload); the program's error output goes back as frames of type 7, text
 * for the principal. Nothing else crosses. [LocalShellService] runs the
 * local shell, [TermService] the terminal emulator.
 */
abstract class IsolatedRelayService : Service() {
    companion object {
        const val START = IBinder.FIRST_CALL_TRANSACTION
    }

    /** The interface token the activity writes. */
    abstract val descriptor: String

    /** The program and its arguments, run with an empty environment. */
    abstract fun command(exeDir: String, rows: Int, cols: Int): List<String>

    /** Shown when the program cannot be started at all. */
    abstract fun cannotStart(why: String?): String

    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != START) return super.onTransact(code, data, reply, flags)
            data.enforceInterface(descriptor)
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
        val p = try {
            ProcessBuilder(command(applicationInfo.nativeLibraryDir, rows, cols)).also { it.environment().clear() }.start()
        } catch (e: IOException) {
            // Never a fallback to Pylon's own process: no sandbox, no program.
            send(frame(7, cannotStart(e.message).toByteArray()))
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
            // The app closed it: end of input ends it.
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
