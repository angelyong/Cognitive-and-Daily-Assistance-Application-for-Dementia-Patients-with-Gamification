import 'package:intl/intl.dart';

/// PHASE 3 (see phase3_reminder_notifications_prompt.md): shared constants
/// and helpers for the due-time reminder loop and per-occurrence status.
///
/// Kept separate from task_recurrence.dart (which is purely recurrence
/// date math) since this is about STATUS/reminder timing, not which dates
/// a series occurs on.

/// Safety cap on repeat reminders per occurrence (Step 5) — a COUNT, not a
/// fixed duration, so a longer configured interval still nags persistently
/// rather than being throttled to only a couple of reminders. At the
/// default 5-minute interval this is 1 hour; at 15 minutes, ~3 hours.
const int maxFollowupReminders = 12;

/// Caregiver-configurable re-reminder interval choices (CreateTaskScreen).
const List<int> reminderIntervalChoicesMinutes = [5, 10, 15];
const int defaultReminderIntervalMinutes = 5;

/// yyyy-MM-dd key for a specific occurrence date — used both as the
/// `tasks/{taskId}/occurrences/{key}` subcollection doc id and inside
/// notification payloads/ids, so the same key always round-trips.
String occurrenceDateKey(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

/// The moment an occurrence's reminder chain runs out and, per existing
/// business logic (HomeScreen/PatientDashboard's old immediate-flip rule),
/// it's fair to auto-mark it missed. Reconciles the pre-Phase-3 "missed the
/// instant dueDate passes" behaviour with the new reminder loop — a task
/// now stays 'pending' (and keeps reminding) until this later point,
/// instead of flipping to 'missed' the second it becomes due while a
/// reminder chain is still actively trying to reach the patient.
DateTime missedThreshold(DateTime dueDate, int reminderIntervalMinutes) {
  return dueDate.add(
    Duration(minutes: reminderIntervalMinutes * maxFollowupReminders),
  );
}

/// Single shared definition of "what should the UI show right now" for one
/// occurrence (whether backed by a task's legacy `status` field or a
/// recurring occurrence's subcollection doc) — used identically by
/// HomeScreen and PatientDashboard so the two views can't drift apart the
/// way their independent copies of this logic did pre-Phase-3.
String effectiveStatus({
  required String storedStatus,
  required DateTime dueDate,
  required int reminderIntervalMinutes,
}) {
  if (storedStatus == 'completed') return 'completed';
  if (storedStatus == 'missed') return 'missed';

  if (DateTime.now().isAfter(missedThreshold(dueDate, reminderIntervalMinutes))) {
    return 'missed';
  }
  return 'pending';
}
