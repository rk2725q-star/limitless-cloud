package com.limitlesscloud.limitless_cloud

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * TransferForegroundService — Real Android Foreground Service for uploads/downloads.
 *
 * Why this matters for Samsung devices:
 *   • A plain notification (from flutter_local_notifications) does NOT prevent Android
 *     from killing the app process. Samsung One UI's aggressive battery optimizer kills
 *     any background app without a proper startForeground() call.
 *   • startForeground() elevates the process to FOREGROUND priority — the highest
 *     priority short of the visible UI. Samsung (and all OEMs) are legally prohibited
 *     from killing foreground services under Android's process priority contract.
 *   • This eliminates "frequent crashes" in Samsung's battery stats because Android
 *     no longer kills the process mid-transfer.
 *
 * Lifecycle:
 *   START  → startForeground() with indeterminate progress bar
 *   UPDATE → update notification with % progress (no new sound/vibration)
 *   STOP   → stopForeground(remove) + stopSelf() — notification dismissed immediately
 */
class TransferForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID  = "limitless_transfer"
        private const val NOTIF_ID    = 42
        const val ACTION_START  = "com.limitlesscloud.START_TRANSFER"
        const val ACTION_UPDATE = "com.limitlesscloud.UPDATE_TRANSFER"
        const val ACTION_STOP   = "com.limitlesscloud.STOP_TRANSFER"
        const val EXTRA_TITLE    = "title"
        const val EXTRA_PROGRESS = "progress"

        /** Start the foreground service — call when a transfer begins. */
        fun start(context: Context, title: String) {
            val intent = Intent(context, TransferForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Update the progress notification — call periodically during transfer. */
        fun update(context: Context, title: String, progressPct: Int) {
            val intent = Intent(context, TransferForegroundService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_PROGRESS, progressPct)
            }
            context.startService(intent)
        }

        /** Stop the foreground service and dismiss notification. */
        fun stop(context: Context) {
            val intent = Intent(context, TransferForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    private lateinit var notificationManager: NotificationManager

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "Transferring…"
                // startForeground MUST be called within 5 seconds of startForegroundService()
                startForeground(NOTIF_ID, buildNotification(title, -1))
            }
            ACTION_UPDATE -> {
                val title    = intent.getStringExtra(EXTRA_TITLE) ?: "Transferring…"
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                // Update in-place — no sound, no vibration (onlyAlertOnce equivalent)
                notificationManager.notify(NOTIF_ID, buildNotification(title, progress))
            }
            ACTION_STOP -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
            }
        }
        // START_STICKY: if killed (OOM), Android restarts service with last intent
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── Private helpers ────────────────────────────────────────────────────────

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Transfers",
                NotificationManager.IMPORTANCE_LOW          // No sound, no heads-up
            ).apply {
                description       = "Upload and download progress"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    /**
     * Build the notification.
     * @param progress -1 = indeterminate (at start), 0..99 = determinate progress
     */
    private fun buildNotification(title: String, progress: Int): Notification {
        // Tap notification → open the app
        val tapIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val contentText = if (progress in 0..99) "$title  —  $progress%" else title

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Limitless Cloud")
            .setContentText(contentText)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)           // NOT dismissible while transfer runs
            .setSilent(true)            // No sound
            .setOnlyAlertOnce(true)     // No vibration on updates
            .setContentIntent(pendingIntent)
            .apply {
                if (progress < 0) {
                    // Indeterminate — "starting" phase
                    setProgress(0, 0, true)
                } else {
                    setProgress(100, progress.coerceIn(0, 100), false)
                }
            }
            .build()
    }
}
