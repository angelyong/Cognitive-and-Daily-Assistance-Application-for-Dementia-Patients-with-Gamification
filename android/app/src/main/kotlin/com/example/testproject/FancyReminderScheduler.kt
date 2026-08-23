package com.example.testproject

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/**
 * Schedules/cancels the fancy native reminder notification's AlarmManager
 * alarms (see FancyReminderReceiver, MainActivity's MethodChannel handler).
 *
 * Per-slot ids (one per due/follow-up notification, 13 total per
 * occurrence) are computed in DART (NotificationService.idFor /
 * occurrenceChainIds — the exact same scheme the plain
 * flutter_local_notifications-based chain already uses) and handed over
 * via the MethodChannel, not recomputed here. Dart's String.hashCode
 * algorithm isn't a publicly stable, guaranteed-across-versions contract,
 * so replicating it independently in Kotlin would risk silently computing
 * DIFFERENT ids on the two sides and being unable to cancel what was
 * scheduled — passing the already-computed ids across sidesteps that
 * entirely.
 *
 * [rememberIds]/[cancelChain]'s SharedPreferences persistence exists for
 * exactly one reason: a Complete/Missed button tap on this notification
 * can happen while the app is fully closed, so at THAT moment there's no
 * running Dart code to ask "what ids does this occurrence's chain use" —
 * this file has to already know, independently.
 */
object FancyReminderScheduler {
    private const val PREFS_NAME = "fancy_reminder_ids"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun occurrenceKey(taskId: String, dateKey: String) = "$taskId|$dateKey"

    /** Persists every id this occurrence's chain could be using — called
     * once per (re)scheduling pass, before the individual alarms are set. */
    fun rememberIds(context: Context, taskId: String, dateKey: String, ids: List<Int>) {
        prefs(context).edit()
            .putString(occurrenceKey(taskId, dateKey), ids.joinToString(","))
            .apply()
    }

    /** One alarm for one slot (the "due" notification, or a follow-up).
     * [id] is this SLOT's own unique PendingIntent request code (distinct
     * per slot, so cancelling one doesn't cancel another); [notificationId]
     * is the shared id EVERY slot in this occurrence's chain notifies
     * under, so a follow-up replaces the same status bar entry instead of
     * stacking a new one. */
    fun scheduleSlot(
        context: Context,
        id: Int,
        notificationId: Int,
        taskId: String,
        dateKey: String,
        title: String,
        category: String,
        timeLabel: String,
        fireAtMillis: Long,
    ) {
        val intent = Intent(context, FancyReminderReceiver::class.java).apply {
            putExtra("notificationId", notificationId)
            putExtra("taskId", taskId)
            putExtra("dateKey", dateKey)
            putExtra("title", title)
            putExtra("category", category)
            putExtra("timeLabel", timeLabel)
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context, id, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAtMillis, pendingIntent)
    }

    /** Cancels every alarm this occurrence's chain could possibly be
     * using, and forgets the persisted id list. Cancelling an id that was
     * never actually scheduled (e.g. a slot already past when scheduled)
     * is a harmless no-op — same contract as the Dart-side
     * NotificationService.cancelOccurrenceReminders this mirrors. */
    fun cancelChain(context: Context, taskId: String, dateKey: String) {
        val key = occurrenceKey(taskId, dateKey)
        val stored = prefs(context).getString(key, null) ?: return
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        for (idStr in stored.split(",")) {
            val id = idStr.toIntOrNull() ?: continue
            val intent = Intent(context, FancyReminderReceiver::class.java)
            val pendingIntent = PendingIntent.getBroadcast(
                context, id, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            alarmManager.cancel(pendingIntent)
        }
        prefs(context).edit().remove(key).apply()
    }
}
