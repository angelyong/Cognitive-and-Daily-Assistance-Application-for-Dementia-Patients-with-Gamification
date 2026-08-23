package com.example.testproject

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Dart -> the fancy native reminder notification (see
 * FancyReminderScheduler/FancyReminderReceiver/ReminderActionReceiver).
 * All the "which occurrences/times/ids" business logic stays in Dart
 * (NotificationService) — this channel just hands off the already-computed
 * schedule/cancel calls to native AlarmManager + a custom RemoteViews
 * notification, since that visual style isn't achievable through
 * flutter_local_notifications' own Dart API.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.example.testproject/fancy_reminders"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "scheduleFancyReminderChain" -> {
                    try {
                        val args = call.arguments as Map<*, *>
                        val taskId = args["taskId"] as String
                        val dateKey = args["dateKey"] as String
                        val category = args["category"] as String
                        val title = args["title"] as String
                        val timeLabel = args["timeLabel"] as String
                        val notificationId = (args["notificationId"] as Number).toInt()
                        @Suppress("UNCHECKED_CAST")
                        val slotIds = (args["slotIds"] as List<Number>).map { it.toInt() }
                        @Suppress("UNCHECKED_CAST")
                        val slotFireTimesMillis = (args["slotFireTimesMillis"] as List<Number>).map { it.toLong() }
                        @Suppress("UNCHECKED_CAST")
                        val allChainIds = (args["allChainIds"] as List<Number>).map { it.toInt() }

                        FancyReminderScheduler.rememberIds(applicationContext, taskId, dateKey, allChainIds)
                        for (i in slotIds.indices) {
                            FancyReminderScheduler.scheduleSlot(
                                applicationContext,
                                id = slotIds[i],
                                notificationId = notificationId,
                                taskId = taskId,
                                dateKey = dateKey,
                                title = title,
                                category = category,
                                timeLabel = timeLabel,
                                fireAtMillis = slotFireTimesMillis[i],
                            )
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("schedule_failed", e.message, null)
                    }
                }
                "cancelFancyReminderChain" -> {
                    try {
                        val args = call.arguments as Map<*, *>
                        val taskId = args["taskId"] as String
                        val dateKey = args["dateKey"] as String
                        FancyReminderScheduler.cancelChain(applicationContext, taskId, dateKey)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("cancel_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
