# Recurrence & Task-Status — Technical Q&A

Answers the specific "how does X actually work under the hood" questions about the recurrence engine and task/occurrence status, with exact code references. Companion to `APP_FUNCTIONALITY.md` (behaviour-level) and `INCOMPLETE_WORK.md` (gaps) — this one is implementation-level.

---

## 1. How is `recurrenceRule` written in `CreateTaskScreen`?

File: `lib/screens/caregiver/createTaskScreen.dart`, inside `_saveTask()`.

It's built **only when recurrence is enabled**, and its shape depends on which `RecurrenceType` is selected — the other types simply don't need one:

```dart
RecurrenceRule? recurrenceRuleToSave;
if (_recurrenceType != RecurrenceType.none) {
  ...validation...
  recurrenceRuleToSave = _recurrenceType == RecurrenceType.weekly
      ? RecurrenceRule(weekdays: _selectedWeekdays)
      : _recurrenceType == RecurrenceType.custom
          ? RecurrenceRule(
              interval: customInterval,
              unit: _customUnit,
              weekdays: _customUnit == RecurrenceUnit.weeks
                  ? _selectedWeekdays
                  : const [],
            )
          : null; // daily/monthly/yearly need no extra params
}
```

- **Weekly** → just `weekdays` (the multi-select chip values, `DateTime.weekday` ints 1=Mon..7=Sun).
- **Custom** → `interval` (parsed from the "Every [n]" text field) + `unit` (Days/Weeks/Months dropdown) + `weekdays` (only populated if unit = Weeks).
- **Daily / Monthly / Yearly** → `recurrenceRuleToSave` stays `null` — nothing extra to store, since those types are fully determined by the start date alone.
- **None** → the whole block is skipped, `recurrenceRuleToSave` stays `null`.

This `RecurrenceRule?` is passed straight into `FirestoreService.addTask`/`updateTask`, which serialize it:

```dart
// lib/services/firestore_service.dart
'recurrenceRule': recurrenceType == RecurrenceType.none
    ? null
    : recurrenceRule?.toMap(),
```

`RecurrenceRule.toMap()` (in `lib/models/task_recurrence.dart`) always writes all three keys regardless of type, for a uniform shape in Firestore:
```dart
Map<String, dynamic> toMap() => {
      'weekdays': weekdays,   // [] if not applicable
      'interval': interval,   // 1 if not applicable
      'unit': unit.firestoreValue, // 'days' if not applicable
    };
```
So a Daily task actually gets `recurrenceRule: null` on the doc (not an empty-but-present map) — the ternary above short-circuits to `null` unless `recurrenceRuleToSave` was actually built.

---

## 2. How is `recurrenceRule` interpreted when displaying tasks?

Every reader goes through the same two-step path — nothing parses the raw map directly outside of this:

**Step 1 — deserialize.** `RecurrenceRule.fromMap()` (`task_recurrence.dart`):
```dart
factory RecurrenceRule.fromMap(Map<String, dynamic>? map) {
  if (map == null) return const RecurrenceRule(); // defaults: [], 1, days
  return RecurrenceRule(
    weekdays: (map['weekdays'] as List<dynamic>?)?.map((e) => e as int).toList() ?? const [],
    interval: (map['interval'] as int?) ?? 1,
    unit: RecurrenceUnitX.fromFirestore(map['unit'] as String?),
  );
}
```
A `null` map (old doc, or a Daily/Monthly/Yearly/None task) just becomes the harmless default `RecurrenceRule()` — safe because those types never read `weekdays`/`interval`/`unit` in the first place.

**Step 2 — interpret, based on `recurrenceType`**, inside `_isOccurrence()` (`task_recurrence.dart`, private, only called by `getOccurrencesForDateRange` — see Q5):
- Weekly / Custom-weeks read `rule.weekdays` (falling back to the start date's own weekday if empty) to decide whether a given calendar day's weekday qualifies.
- Custom reads `rule.interval`/`rule.unit` to step by N days/weeks/months instead of every one.
- Monthly/Yearly ignore the rule entirely — they're fully determined by the start date's day-of-month/month.

For **display text** (not date math), `recurrenceSummary(type, rule)` (also `task_recurrence.dart`) turns a type+rule into the human sentence shown in `CreateTaskScreen` and `TaskDetailScreen` ("Repeats weekly on Mon, Wed", "Repeats every 2 weeks on Fri", etc.) — same rule object, different consumer.

---

## 3. How does `getTasks()` query `dueDate`?

File: `lib/services/firestore_service.dart`.

```dart
static const int _homeWindowDays = 3;

Stream<QuerySnapshot> getTasks(String caregiverId) {
  final now = DateTime.now();
  final startOfToday = DateTime(now.year, now.month, now.day);
  final windowStart = startOfToday.subtract(const Duration(days: _homeWindowDays));
  final endOfDay = startOfToday.add(const Duration(days: 1));
  return firestore
      .collection('tasks')
      .where('caregiverId', isEqualTo: caregiverId)
      .where('dueDate', isGreaterThanOrEqualTo: Timestamp.fromDate(windowStart))
      .where('dueDate', isLessThan: Timestamp.fromDate(endOfDay))
      .snapshots();
}
```

It's a **live stream**, scoped to one caregiver, filtered by a Firestore **range query on the literal `dueDate` field** — today's start-of-day minus 3 days, up to (but not including) tomorrow's start-of-day. That's a live "today, or up to 3 days overdue" window, not "today only."

**The critical nuance**: for a recurring task, `dueDate` is the series' **start date**, not "the next occurrence." So this query only ever matches a recurring task while its *original start date* is within that ±3-day window — see Q4 and `INCOMPLETE_WORK.md` §5 for why that's a real limitation for older recurring series. It requires a Firestore composite index on `(caregiverId ASC, dueDate ASC)`.

`getTasksForPatient(patientId)` (used by `PatientDashboard`) is the patient-side equivalent but has **no date filter at all** — it returns every task ever assigned to that patient, unfiltered by date; the "today only" behaviour on that screen comes entirely from client-side filtering (Q4), not the query.

---

## 4. How does `HomeScreen` determine which tasks belong to "today"?

Two different mechanisms stack on top of each other, for two different purposes:

**a) Coarse filter — the query itself (Q3).** `getTasks(caregiverId)` already only returns docs whose own `dueDate` falls in the ±3-day window. This is the *only* filter for a non-recurring task — if it passes, it's shown; there's no further "is this actually today" check.

**b) Per-occurrence resolution — for a recurring task.** Because the query's `dueDate` match doesn't mean "recurs today" (see Q3's nuance), `HomeScreen._occurrenceAwareCard()` does an extra step for any doc whose `recurrenceType != none`:

```dart
// lib/screens/HomeScreen.dart
DateTime? _todaysOccurrence(TaskSeries series) {
  final now = DateTime.now();
  final todayStart = DateTime(now.year, now.month, now.day);
  final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);
  final occurrences = getOccurrencesForDateRange(series, todayStart, todayEnd);
  return occurrences.isEmpty ? null : occurrences.first;
}
```
It re-uses the exact same `getOccurrencesForDateRange` the calendar uses (Q5), asking specifically "does this series occur anywhere in `[today 00:00, today 23:59:59]`?" If yes, that occurrence's status/toggle is wired up live; if the doc reached the query window but genuinely doesn't recur today (e.g. its start date happens to be within 3 days but it's a weekly-Wednesday task and today's Tuesday), it's rendered read-only rather than hidden outright (a deliberate compromise — see the code comment in `HomeScreen._occurrenceAwareCard`).

`PatientDashboard` does the same `_todaysOccurrence` check, but — since its underlying query has no date filter at all — uses it as a **hard filter**, dropping a recurring doc from the visible list entirely if it has no occurrence today (`build()`'s `visibleDocs` filter). `HomeScreen` doesn't need to hard-filter this way because the query already narrowed things down first.

---

## 5. How does the Calendar calculate recurring occurrences?

File: `lib/screens/caregiver/ActivityProgressScreen.dart`, backed by `lib/models/calendar_event.dart` and `lib/models/task_recurrence.dart`.

1. It fetches **every one of the selected patient's tasks** via `FirestoreService.getTaskHistory(patientId)` (a live stream, ordered by `dueDate` desc, no date range limit at all — so every series, however old, is always fetched client-side).
2. For the **currently visible month** (plus a 7-day buffer either side, to cover leading/trailing calendar-grid cells):
   ```dart
   final (rangeStart, rangeEnd) = _visibleRange(); // first-of-month -7d .. last-of-month +7d
   ```
3. Each task doc is expanded via `CalendarEvent.occurrencesFromDoc(doc, rangeStart, rangeEnd)`, which:
   - Builds a `TaskSeries` from the doc (`TaskSeries.fromDoc`).
   - Calls the single shared function `getOccurrencesForDateRange(series, rangeStart, rangeEnd)` — **the one and only place occurrence-date math is implemented**; nothing else recomputes it independently.
   - Wraps each resulting `DateTime` into a `CalendarEvent` (carrying `isRecurring`, the recurrence type, and the rule, for display).
4. `getOccurrencesForDateRange` itself just walks the range **day by day** and asks a private predicate `_isOccurrence(series, day)` "does this specific day match the series' rule?" — see Q1/Q2 for exactly how that predicate reads `recurrenceType`/`recurrenceRule`. It's a plain, synchronous, no-network function — safe to call on every rebuild.
5. Because the fetch (`getTaskHistory`) has no date bound but the *expansion* is bounded to the visible month, this scales fine: a task from a year ago still gets fetched, but its occurrence math is only ever computed for whatever month is currently on screen — recomputed fresh (and re-expanded) every time the caregiver flips months (`onPageChanged` triggers `setState`).

This is the **same function** `HomeScreen`/`PatientDashboard` use for their "does this recur today" check (Q4) and the reminder scheduler uses for "what's due in the next 7 days" (see `NotificationService.reconcilePatientReminders`) — one implementation, four call sites.

---

## 6. How are Complete and Missed currently stored?

Depends entirely on whether the task is recurring — this is the split that Q7 asks about directly, so see that answer for the "which one" decision. Mechanically, each path writes to a different place:

**Non-recurring task** — the plain top-level field on the task document itself:
```dart
// FirestoreService.updateTaskStatus
await firestore.collection('tasks').doc(taskId).update({'status': status});
```
`status` is a plain string, one of `'pending'` / `'completed'` / `'missed'`, defaulting to `'pending'` wherever it's absent.

**Recurring task, one specific occurrence** — a subcollection document keyed by date:
```dart
// FirestoreService.setOccurrenceStatus
await firestore
    .collection('tasks').doc(taskId)
    .collection('occurrences').doc(occurrenceDateKey(occurrenceDate)) // 'yyyy-MM-dd'
    .set({'status': status, 'updatedAt': FieldValue.serverTimestamp()});
```
A missing occurrence doc (never touched) is treated as `'pending'` by every reader (`getOccurrenceStatus`/`getOccurrenceStatusStream`) — so occurrence docs are only ever created the first time someone actually responds to that date, not proactively for every future date.

**Who writes which one, and when** — every write site (`PatientDashboard`'s tick, `HomeScreen`'s tick, `TaskDetailScreen`'s Complete/Missed buttons, the notification action-button handlers, foreground and background) all branch the same way: read the task's `recurrenceType`, and call `updateTaskStatus` if it's `none`, or `setOccurrenceStatus(taskId, occurrenceDate, status)` otherwise. No screen writes directly to Firestore for this — it's always through one of those two `FirestoreService` methods.

**Auto-missed** (no response, chain exhausted) writes through the exact same two methods — `HomeScreen`/`PatientDashboard`'s `_persistMissedStatus()` calls `updateTaskStatus(id, 'missed')` for a non-recurring task past its threshold, or `setOccurrenceStatus(id, date, 'missed')` for a recurring occurrence past its threshold. See `occurrence_status.dart`'s `missedThreshold()` for the exact cutoff (`dueDate + reminderIntervalMinutes × 12`).

**Display** never trusts the stored value blindly for missed-detection — `occurrence_status.effectiveStatus()` recomputes live on every read (`completed`/`missed` pass through as-is; a stored `pending` past `missedThreshold` is *displayed* as missed even before/without a Firestore write happening). The write (`_persistMissedStatus`) is opportunistic — it only actually happens while a dashboard screen is mounted and its periodic re-check timer fires.

---

## 7. Is status stored on the recurring series, or on individual occurrences?

**Individual occurrences** — that's the whole point of the `tasks/{taskId}/occurrences/{date}` subcollection (Q6). The series document's own top-level `status` field still exists (it's the same schema as a non-recurring task, since Phase 2 added recurrence as optional fields on the *same* collection rather than a new one), but for a recurring task that field is a **vestige of its own start-date occurrence only** — it is never read or written by any of the per-occurrence logic once recurrence kicks in.

Concretely:
- Completing **today's** occurrence of a daily task does **not** touch the series doc's `status` field, and does **not** affect **tomorrow's** occurrence — each date gets its own subcollection doc, independently.
- The series doc's raw `status` field, for a recurring task, is only ever meaningful if you're looking at the literal start-date occurrence specifically — every screen that shows "today's" or "the relevant" occurrence for a recurring task deliberately routes around that field and reads/writes the subcollection instead (`HomeScreen._occurrenceAwareCard`, `PatientDashboard._occurrenceAwareCard`, `TaskDetailScreen._respond`, the notification handlers — all check `recurrenceType` first, exactly as described in Q6).
- This was a deliberate Phase 3 design choice, explicitly required by the phase's own "CRITICAL" step: *"each occurrence needs its own state... do NOT store one global completed boolean on a recurring series."* A single global flag would have made completing one date's task incorrectly complete (or block reminders for) every other date of the same series.
