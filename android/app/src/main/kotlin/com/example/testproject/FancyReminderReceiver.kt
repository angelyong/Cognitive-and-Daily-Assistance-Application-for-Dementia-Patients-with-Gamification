package com.example.testproject

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.RingtoneManager
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Fires when one slot (due, or a follow-up) of a fancy reminder chain's
 * AlarmManager alarm goes off (see FancyReminderScheduler) — builds and
 * shows the custom RemoteViews notification matching ReminderPopup's look
 * (notification_reminder_collapsed.xml / notification_reminder_expanded.xml),
 * with sound, on a dedicated channel separate from the plain
 * flutter_local_notifications one.
 */
class FancyReminderReceiver : BroadcastReceiver() {
    companion object {
        const val CHANNEL_ID = "fancy_task_reminders"
        const val CHANNEL_NAME = "Task Reminders (Fancy)"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val notificationId = intent.getIntExtra("notificationId", -1)
        if (notificationId == -1) return
        val taskId = intent.getStringExtra("taskId") ?: return
        val dateKey = intent.getStringExtra("dateKey") ?: return
        val title = intent.getStringExtra("title") ?: ""
        val category = intent.getStringExtra("category") ?: ""
        val timeLabel = intent.getStringExtra("timeLabel") ?: ""

        ensureChannel(context)

        val collapsed = buildRemoteViews(
            context, R.layout.notification_reminder_collapsed, false,
            taskId, dateKey, title, category, timeLabel, notificationId,
        )
        val expanded = buildRemoteViews(
            context, R.layout.notification_reminder_expanded, true,
            taskId, dateKey, title, category, timeLabel, notificationId,
        )

        val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setCustomContentView(collapsed)
            .setCustomBigContentView(expanded)
            .setStyle(NotificationCompat.DecoratedCustomViewStyle())
            .setSound(soundUri)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(false)
            .build()

        NotificationManagerCompat.from(context).notify(notificationId, notification)
    }

    private fun ensureChannel(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_HIGH)
            channel.description = "Reminders for scheduled tasks."
            manager.createNotificationChannel(channel)
        }
    }

    private fun categoryIconBg(category: String): Int = when (category.lowercase()) {
        "medication" -> R.drawable.bg_icon_medication
        "exercise" -> R.drawable.bg_icon_exercise
        "meal" -> R.drawable.bg_icon_meal
        "hygiene" -> R.drawable.bg_icon_hygiene
        "social" -> R.drawable.bg_icon_social
        "appointment" -> R.drawable.bg_icon_appointment
        else -> R.drawable.bg_icon_default
    }

    // Emoji instead of custom vector-path icons: renders correctly on
    // every Android version via the system emoji font, with zero risk of
    // malformed/mis-drawn path data — see the drawable resources' own
    // comments for the same reasoning applied to colors.
    private fun categoryEmoji(category: String): String = when (category.lowercase()) {
        "medication" -> "💊"
        "exercise" -> "🏃"
        "meal" -> "🍽️"
        "hygiene" -> "🧼"
        "social" -> "👥"
        "appointment" -> "📅"
        else -> "🔔"
    }

    private fun buildRemoteViews(
        context: Context,
        layoutRes: Int,
        includeButtons: Boolean,
        taskId: String,
        dateKey: String,
        title: String,
        category: String,
        timeLabel: String,
        notificationId: Int,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, layoutRes)
        views.setTextViewText(R.id.reminder_title, title)
        views.setTextViewText(R.id.reminder_time, timeLabel)
        views.setTextViewText(R.id.reminder_icon_emoji, categoryEmoji(category))
        views.setInt(R.id.reminder_icon_square, "setBackgroundResource", categoryIconBg(category))

        if (includeButtons) {
            views.setOnClickPendingIntent(
                R.id.reminder_btn_complete,
                actionPendingIntent(context, taskId, dateKey, "completed", notificationId),
            )
            views.setOnClickPendingIntent(
                R.id.reminder_btn_missed,
                actionPendingIntent(context, taskId, dateKey, "missed", notificationId),
            )
        }
        return views
    }

    // isRecurring is deliberately NOT passed through here — ReminderActionReceiver
    // re-fetches recurrenceType fresh from Firestore right before writing the
    // response instead, so a caregiver editing the task's recurrence between
    // scheduling and this tap can never make a stale flag write to the wrong place.
    private fun actionPendingIntent(
        context: Context,
        taskId: String,
        dateKey: String,
        status: String,
        notificationId: Int,
    ): PendingIntent {
        val intent = Intent(context, ReminderActionReceiver::class.java).apply {
            putExtra("taskId", taskId)
            putExtra("dateKey", dateKey)
            putExtra("status", status)
            putExtra("notificationId", notificationId)
        }
        // Complete and Missed target the SAME receiver/notificationId, so
        // they need distinct request codes to be distinct PendingIntents.
        val requestCode = notificationId * 2 + (if (status == "completed") 0 else 1)
        return PendingIntent.getBroadcast(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
