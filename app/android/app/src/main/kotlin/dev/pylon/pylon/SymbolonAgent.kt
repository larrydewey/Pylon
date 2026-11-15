package dev.pylon.pylon

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
 * Symbolon's SSH agent service (SPEC 7.3), bound and called with the agent
 * protocol's messages unchanged: one transaction (code [CALL]) carries a
 * whole request message as a byte array and returns the whole reply. The
 * service protects itself with a signature-level permission and checks
 * the caller; here, Pylon checks the service: only the Symbolon package
 * signed by a pinned certificate is bound, so another app cannot pose as
 * the agent and collect what Pylon asks it to sign.
 *
 * Calls block (a signature waits for the principal's consent in
 * Symbolon's own sheet): never on the main thread.
 */
class SymbolonAgent(private val ctx: Context) {
    companion object {
        const val PACKAGE = "dev.symbolon.app"
        const val ACTION = "dev.symbolon.action.SSH_AGENT"
        const val CALL = IBinder.FIRST_CALL_TRANSACTION
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

    /** One agent message in, the reply message out; null when there is no agent. */
    fun call(request: ByteArray): ByteArray? {
        val b = bind() ?: return null
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(DESCRIPTOR)
            data.writeByteArray(request)
            if (!b.transact(CALL, data, reply, 0)) return null
            reply.readException()
            reply.createByteArray()
        } catch (e: Exception) {
            null
        } finally {
            data.recycle()
            reply.recycle()
        }
    }
}
