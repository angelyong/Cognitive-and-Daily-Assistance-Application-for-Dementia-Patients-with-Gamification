package com.example.testproject

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore

/**
 * Handles Complete/Missed button taps on the fancy native reminder
 * notification (see FancyReminderReceiver, notification_reminder_expanded.xml).
 *
 * A fully custom RemoteViews notification is built with raw
 * NotificationManager calls, entirely outside flutter_local_notifications
 * — so its button taps never reach that plugin's own background-isolate
 * Dart handler (NotificationService.notificationActionBackgroundHandler).
 * This is the native equivalent: writes the response straight to
 * Firestore via the native Android SDK rather than spinning up a headless
 * Flutter engine, since the write itself is a small, stable contract.
 *
 * SCHEMA CONTRACT — must stay in sync with FirestoreService (Dart side):
 *   - non-recurring: tasks/{taskId}.status = 'completed' | 'missed'
 *   - recurring:      tasks/{taskId}/occurrences/{dateKey}.status = same,
 *                      .updatedAt = server timestamp
 *   - recurrenceType allowlist: "daily"/"weekly"/"monthly"/"yearly"/"custom"
 *     count as recurring; anything else (missing, "none", unrecognized)
 *     counts as non-recurring — mirrors RecurrenceTypeX.fromFirestore's
 *     exact default-to-none behavior (Dart side).
 * If any of this ever changes in FirestoreService/task_recurrence.dart,
 * update here too.
 */
class ReminderActionReceiver : BroadcastReceiver() {
    private val recurringTypes = setOf("daily", "weekly", "monthly", "yearly", "custom")

    override fun onReceive(context: Context, intent: Intent) {
        val taskId = intent.getStringExtra("taskId") ?: return
        val dateKey = intent.getStringExtra("dateKey") ?: return
        val status = intent.getStringExtra("status") ?: return
        val notificationId = intent.getIntExtra("notificationId", -1)

        val appContext = context.applicationContext
        if (FirebaseApp.getApps(appContext).isEmpty()) {
            FirebaseApp.initializeApp(appContext)
        }

        // Extends this receiver's lifetime briefly so the async Firestore
        // read+write below can complete before the process might be
        // frozen/killed — standard pattern for async work triggered from
        // onReceive.
        val pendingResult = goAsync()
        val firestore = FirebaseFirestore.getInstance()

        // Re-fetch the task doc fresh (not a flag captured back at
        // schedule time) to determine recurring vs non-recurring — same
        // "read recurrenceType right before writing the response" pattern
        // Dart's _applyOccurrenceResponse uses, so a caregiver editing the
        // task's recurrence between scheduling and this tap is never stale.
        firestore.collection("tasks").document(taskId).get()
            .addOnSuccessListener { doc ->
                val isRecurring = doc.getString("recurrenceType") in recurringTypes
                val write = if (isRecurring) {
                    firestore.collection("tasks").document(taskId)
                        .collection("occurrences").document(dateKey)
                        .set(mapOf("status" to status, "updatedAt" to FieldValue.serverTimestamp()))
                } else {
                    firestore.collection("tasks").document(taskId).update("status", status)
                }
                write.addOnCompleteListener {
                    finish(appContext, taskId, dateKey, notificationId, pendingResult)
                }
            }
            .addOnFailureListener {
                // Best-effort — a dropped write here is no worse than the
                // plain-notification background handler's own lack of
                // retry logic (see _handleBackgroundAction, Dart side).
                finish(appContext, taskId, dateKey, notificationId, pendingResult)
            }
    }

    private fun finish(
        context: Context,
        taskId: String,
        dateKey: String,
        notificationId: Int,
        pendingResult: PendingResult,
    ) {
        FancyReminderScheduler.cancelChain(context, taskId, dateKey)
        if (notificationId != -1) {
            NotificationManagerCompat.from(context).cancel(notificationId)
        }
        pendingResult.finish()
    }
}
