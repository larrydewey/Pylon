package dev.pylon.pylon

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.IBinder
import android.os.Parcel
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Symbolon's SSH agent service (SPEC 7.3), called with the agent protocol's
 * messages unchanged. Each terminal session is one agent connection (a
 * number of Pylon's choosing), so a session-bind holds for the signature
 * that follows it:
 *
 *   CALL  conn, request -> 0, reply | 1, PendingIntent | -1
 *   WAIT  conn          -> 0, reply | -1
 *   CLOSE conn
 *
 * A 1 means Symbolon needs the principal's consent: Pylon, in front, starts
 * Symbolon's consent sheet from the PendingIntent and then WAITs for the
 * reply. A -1 is answered to the core as the agent's failure message.
 *
 * The service protects itself with a signature-level permission and checks
 * the caller; here, Pylon checks the service: only the Symbolon package
 * signed by a pinned certificate is bound, so another app cannot pose as
 * the agent and collect what Pylon asks it to sign.
 *
 * Calls block: never on the main thread.
 */
class SymbolonAgent(private val ctx: Context) {
    companion object {
        const val PACKAGE = "dev.symbolon.app"
        const val ACTION = "dev.symbolon.action.SSH_AGENT"
        const val CALL = IBinder.FIRST_CALL_TRANSACTION
        const val WAIT = IBinder.FIRST_CALL_TRANSACTION + 1
        const val CLOSE = IBinder.FIRST_CALL_TRANSACTION + 2
        val FAILURE = byteArrayOf(0, 0, 0, 1, 5)
        const val DESCRIPTOR = "dev.symbolon.ISshAgent"

        /** SHA-256 of Symbolon's release signing certificates (lower-case hex), set at build time. */
        val PINNED: Set<String> = BuildConfig.SYMBOLON_CERTS.split(",").map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toSet()
    }

    @Volatile private var binder: IBinder? = null

    private fun signerOk(): Boolean {
        if (PINNED.isEmpty()) return false
        val info = try {
            ctx.packageManager.getPackageInfo(PACKAGE, PackageManager.GET_SIGNING_CERTIFICATES)
        } catch (e: PackageManager.NameNotFoundException) {
            return false
        }
        val si = info.signingInfo ?: return false
        if (si.hasMultipleSigners()) return false
        val certs = si.signingCertificateHistory ?: return false
        val md = MessageDigest.getInstance("SHA-256")
        return certs.any { c -> md.digest(c.toByteArray()).joinToString("") { "%02x".format(it) } in PINNED }
    }

    private fun bind(): IBinder? {
        binder?.let { if (it.isBinderAlive) return it }
        if (!signerOk()) return null
        val got = CountDownLatch(1)
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                binder = service
                got.countDown()
            }
            override fun onServiceDisconnected(name: ComponentName) { binder = null }
        }
        val i = Intent(ACTION).setPackage(PACKAGE)
        if (!ctx.bindService(i, conn, Context.BIND_AUTO_CREATE)) return null
        got.await(10, TimeUnit.SECONDS)
        return binder
    }

    private fun <T> transact(code: Int, fill: (Parcel) -> Unit, read: (Parcel) -> T): T? {
        val b = bind() ?: return null
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(DESCRIPTOR)
            fill(data)
            if (!b.transact(code, data, reply, 0)) return null
            reply.readException()
            read(reply)
        } catch (e: Exception) {
            null
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    /**
     * One agent message in, the reply message out; null when there is no
     * agent. [consent] starts Symbolon's consent sheet (on the main thread,
     * with Pylon in front) when the request needs the principal.
     */
    fun call(conn: Long, request: ByteArray, consent: (PendingIntent) -> Boolean): ByteArray? {
        val first = transact(CALL, { it.writeLong(conn); it.writeByteArray(request) }) { r ->
            when (r.readInt()) {
                0 -> Pair(r.createByteArray(), null)
                1 -> Pair(null, PendingIntent.readPendingIntentOrNullFromParcel(r))
                else -> Pair(FAILURE, null)
            }
        } ?: return null
        first.first?.let { return it }
        val pi = first.second ?: return FAILURE
        if (!consent(pi)) return FAILURE
        return transact(WAIT, { it.writeLong(conn) }) { r -> if (r.readInt() == 0) r.createByteArray() else FAILURE } ?: FAILURE
    }

    fun close(conn: Long) {
        transact(CLOSE, { it.writeLong(conn) }) { }
    }
}
