package dev.pylon.pylon

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.SystemClock
import java.security.SecureRandom

/**
 * Copies from the terminal (Pylon's own selection, and a program's OSC 52
 * write the principal allowed) go on the clipboard marked sensitive, so
 * the system and keyboards don't preview, suggest or keep them
 * (ClipDescription.EXTRA_IS_SENSITIVE; the same key, spelled out, before
 * Android 13), and are cleared after 60 seconds if the clipboard still
 * holds them (SPEC 15, H5).
 *
 * Since Android 10 an app that is not in front cannot read the clipboard,
 * not even to see whether its own clip is still there; when the 60
 * seconds end with Pylon in the background, the check waits until Pylon
 * is next in front ([focused]) rather than clearing a clip some other app
 * may have put there since.
 */
object SensitiveClip {
    private const val TTL_MS = 60_000L
    private const val IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    private val main = Handler(Looper.getMainLooper())
    private val random = SecureRandom()

    private var app: Context? = null
    private var label: String? = null
    private var setAt = 0L
    private val expire = Runnable { app?.let { check(it) } }

    /** Whether Pylon's window has the focus (and so may read the clipboard). */
    var focused = false
        set(value) {
            field = value
            if (value) app?.let { check(it) }
        }

    /** On the main thread. */
    fun copy(ctx: Context, text: String): Boolean {
        val cm = ctx.getSystemService(ClipboardManager::class.java) ?: return false
        // A label of its own, so the check below knows the clip is still ours.
        val tag = ByteArray(8).also { random.nextBytes(it) }.joinToString("") { "%02x".format(it) }
        val l = "Pylon $tag"
        val clip = ClipData.newPlainText(l, text)
        clip.description.extras = PersistableBundle().apply {
            putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else IS_SENSITIVE, true)
        }
        cm.setPrimaryClip(clip)
        app = ctx.applicationContext
        label = l
        setAt = SystemClock.elapsedRealtime()
        main.removeCallbacks(expire)
        main.postDelayed(expire, TTL_MS)
        return true
    }

    private fun check(ctx: Context) {
        val l = label ?: return
        val left = setAt + TTL_MS - SystemClock.elapsedRealtime()
        if (left > 0) {
            main.removeCallbacks(expire)
            main.postDelayed(expire, left)
            return
        }
        val cm = ctx.getSystemService(ClipboardManager::class.java) ?: return
        val d = try { cm.primaryClipDescription } catch (_: Exception) { null }
        when {
            d != null && d.label?.toString() == l -> {
                try { cm.clearPrimaryClip() } catch (_: Exception) {}
                label = null
            }
            // Something else is on the clipboard now: not ours to clear.
            d != null -> label = null
            // In front and nothing there: already gone.
            focused -> label = null
            // In the background the clipboard cannot be seen: checked again
            // when Pylon is next in front.
            else -> {}
        }
    }
}
