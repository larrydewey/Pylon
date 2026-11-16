package dev.pylon.pylon

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps Pylon's network while it has connections open. Android blocks the
 * network of an app that is not in front and destroys its TCP sockets a few
 * seconds later (blocked reason APP_BACKGROUND): an SSH session ended as
 * soon as the principal looked at another app, and a login ended while
 * Symbolon's consent sheet was in front, before they could sign. An app
 * with a foreground service keeps its network, and the notification says
 * that connections are open.
 *
 * Started and updated with the number of live connections (EXTRA_COUNT);
 * stopped at 0.
 */
class ConnectionService : Service() {
    companion object {
        private const val CHANNEL = "connections"
        private const val ID = 1
        private const val EXTRA_COUNT = "count"

        /** Live connections: the service runs while there are any. */
        fun update(ctx: Context, count: Int) {
            val i = Intent(ctx, ConnectionService::class.java).putExtra(EXTRA_COUNT, count)
            when {
                count <= 0 -> ctx.stopService(i)
                Build.VERSION.SDK_INT >= 26 -> ctx.startForegroundService(i)
                else -> ctx.startService(i)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = intent?.getIntExtra(EXTRA_COUNT, 1) ?: 1
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(CHANNEL, "Open connections", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while Pylon keeps SSH and Pylon connections open"
                setShowBadge(false)
            })
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val text = if (n == 1) "1 connection open" else "$n connections open"
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val note = b
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle("Pylon")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID, note)
        }
        return START_NOT_STICKY
    }

    // The task swiped away: the connections' processes end with the app.
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }
}
