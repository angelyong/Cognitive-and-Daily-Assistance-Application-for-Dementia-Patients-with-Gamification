# Notification Structure & Recurrence

How MindCare's reminder notifications work together with recurring tasks. Companion to `RECURRENCE_AND_STATUS_QA.md` (which covers recurrence date math + status generally); this file is specifically about what fires, when, and where the data lives.

---

## 1. Two independent notification mechanisms

MindCare currently reminds a patient about a due task in **two separate, independently-triggered ways**. Neither depends on the other; both can fire for the same occurrence.

| | Native OS notification | In-app `ReminderPopup` |
|---|---|---|
| Where | `lib/services/notification_service.dart` | `lib/widgets/reminder_popup.dart` |
| Delivery | Scheduled ahead of time via the OS alarm system (`flutter_local_notifications` `zonedSchedule`) — fires even if the app is closed/backgrounded | Only fires while `PatientDashboard` is mounted and running, driven by a live Firestore check + a 1-minute timer |
| Trigger | The OS wakes the app (or a background isolate) at the scheduled time | `PatientDashboard._maybeShowDueReminder` scans today's visible tasks each rebuild; also shown when a delivered notification's body is tapped |
| Response UI | Plain-text "Complete"/"Missed" notification action buttons | Floating dialog — category icon, title, time, big Complete/Missed buttons |
| Why both exist | Only mechanism that works when the app isn't open — important for medication reminders | Nicer, on-brand UI while the patient is already looking at the app |

When the in-app popup takes over (either trigger), it immediately calls `NotificationService.cancelOccurrenceReminders(taskId, occurrenceDate)` so the native banner doesn't linger alongside it.

---

## 2. The recurrence data model (recap)

A recurring task is **one Firestore document**, never one doc per future date (`lib/models/task_recurrence.dart`):

```
tasks/{taskId}
  dueDate          -> the series' START date/time
  recurrenceType    -> none | daily | weekly | monthly | yearly | custom
  recurrenceRule    -> { weekdays, interval, unit }   (only used by weekly/custom)
  endDate           -> optional, null = never ends
  reminderIntervalMinutes -> follow-up cadence (default 5, caregiver-configurable to 10/15)
```

`getOccurrencesForDateRange(series, start, end)` is the single source of truth for turning that doc into concrete occurrence dates within a range — every screen and the notification scheduler all call through this one function, so they can't drift apart.

**Per-occurrence status** lives in a subcollection, not on the task doc itself:

```
tasks/{taskId}/occurrences/{yyyy-MM-dd}
  status     -> pending | completed | missed
  updatedAt  -> server timestamp
```

A **non-recurring** task instead keeps using its own legacy top-level `tasks/{taskId}.status` field, completely unchanged — the subcollection is only ever read/written when `recurrenceType != none`. This split is why almost every method touching status in this codebase branches on `isRecurring` first.

---

## 3. The native OS reminder chain

### 3.1 Scheduling — `scheduleOccurrenceChain`

For **one occurrence**, schedules the due-time notification plus up to `maxFollowupReminders` (= **12**) follow-ups, spaced `reminderIntervalMinutes` apart (default 5 min, so 12 follow-ups ≈ 1 hour of nagging by default; longer intervals nag proportionally longer since the cap is a *count*, not a duration):

```
occurrenceDueTime + 0×interval   -> "due" notification    (names the task)
occurrenceDueTime + 1×interval   -> "followup1"            (gentle generic nudge)
occurrenceDueTime + 2×interval   -> "followup2"
...
occurrenceDueTime + 12×interval  -> "followup12"
```

Each slot gets a **stable id** derived from `idFor('$taskId|$dateKey|due')` / `idFor('$taskId|$dateKey|followup$n')` — re-scheduling the same occurrence just replaces the existing alarm at that id rather than stacking duplicates. Any slot whose fire time has already passed is **skipped, not scheduled late** — this is what makes catch-up reconciliation (§3.2) safe to re-run on every app open without restarting the cadence from scratch.

### 3.2 Reconciliation — `reconcilePatientReminders`

Runs once per patient app open/resume (`main.dart` on login-as-patient, `PatientDashboard.initState`). **Must** run on the patient's own device — local notifications can only be scheduled on the device that calls the API, so a caregiver's device can never schedule a reminder that fires on the patient's phone.

- One-shot `.get()` (not a live stream) over all of the patient's tasks.
- Expands each into occurrences over the **next 7 days** — bounded so a daily task can't schedule unboundedly far ahead (worst case ≈ 7 × 13 = 91 alarms, comfortably inside Android's per-app `AlarmManager` limits).
- For each occurrence still `pending` (checked via the per-occurrence subcollection for recurring tasks, or the legacy field for non-recurring), calls `scheduleOccurrenceChain` — which itself no-ops any already-passed slot, so calling this on every app open never duplicates or resets alarms.

### 3.3 Stopping the chain

`flutter_local_notifications` has no "check a condition right before displaying" hook for a plain scheduled alarm — the OS will fire whatever was scheduled regardless of what happened in the app since. So "stop reminding once responded" is enforced **proactively**: the instant a Complete/Missed response is recorded (from the native action button, an in-app tap, or the `ReminderPopup` showing), `cancelOccurrenceReminders(taskId, occurrenceDate)` cancels every id that occurrence's chain could possibly be using (due + all 12 follow-ups), via `occurrenceChainIds()`. Cancelling an id that was never scheduled, or already fired, is a harmless no-op — so this is safe to call defensively from multiple places (it currently is: the tap handler, the background action handler, `TaskDetailScreen`, and both `ReminderPopup` trigger paths).

The only residual gap: a response arriving in the exact same instant an already-in-flight alarm fires. Worst case is one stale notification whose own action buttons just re-write the same (already correct) status — harmless.

### 3.4 Responding — two paths into the same write

| Path | Where | What it does |
|---|---|---|
| Native action button tap (app backgrounded/closed) | `notificationActionBackgroundHandler` (background isolate) | Re-initializes just enough (Firebase + a throwaway plugin instance) to write the status and cancel the chain, then exits |
| Native action button tap (app foregrounded) / body tap / in-app `ReminderPopup` button | `NotificationService._onNotificationTap` / `ReminderPopup._respond` | Same write, via the normal `FirestoreService` instance |

Both paths funnel into the same branch: `recurrenceType == none` → `updateTaskStatus(taskId, status)` (legacy field); otherwise → `setOccurrenceStatus(taskId, occurrenceDate, status)` (subcollection doc). Idempotent either way — a double-tap or a race between two paths just overwrites the same status twice.

---

## 4. The in-app `ReminderPopup`

### 4.1 Trigger 1 — auto-shown while the app is open

`PatientDashboard._maybeShowDueReminder`, run in a `postFrameCallback` after every rebuild (new Firestore snapshot, or the dashboard's own 1-minute status-refresh timer):

1. Scans `timelineEntries` (today's visible tasks/occurrences, already recurrence-aware — see `_visibleDocs`/`_todaysOccurrence`).
2. Finds the first entry whose time has passed, whose raw status is still `pending`, and whose key (`taskId|occurrenceIso`) hasn't been shown yet **this session**.
3. Marks it shown, cancels its native chain, and calls `ReminderPopup.show(...)`.
4. Only one popup at a time (`_popupOpen` guard); each occurrence auto-shows **at most once per session** — dismissing without responding doesn't re-trigger it, same as ignoring the OS notification would.

This uses the same raw-`status`-field approximation as the dashboard's existing `_nextUpIndex` (fast, synchronous, not a live per-occurrence stream) — a deliberate, documented tradeoff, same reasoning as elsewhere in this codebase.

### 4.2 Trigger 2 — notification body tapped

`NotificationService._showReminderPopupForTap` resolves a tap payload (`taskId`, or `taskId|dateKey` for an occurrence-chain reminder) into what the popup needs:

- If the payload carries a `dateKey` → that's the occurrence, directly.
- Else if the task isn't recurring → its own `startDate`.
- Else (recurring, no dateKey — e.g. the older single-shot `scheduleReminder` payload format) → the occurrence within ±2 days of now closest to now, same logic `TaskDetailScreen` used to run itself.

Falls back to the old `TaskDetailScreen` navigation if a context isn't ready yet (cold app launch) or the occurrence can't be resolved, so a tap never silently does nothing.

### 4.3 Responding

`ReminderPopup._respond(status)` branches on the `isRecurring` flag it was constructed with — `setOccurrenceStatus` for a recurring occurrence, `updateTaskStatus` for a single task — then calls `cancelOccurrenceReminders` for the same occurrence, then `Navigator.maybePop()`s itself closed.

---

## 5. Auto-flipping to "missed"

Neither notification mechanism marks an occurrence missed directly — that's a **derived** status, computed identically everywhere via `occurrence_status.dart`:

```dart
missedThreshold(dueDate, intervalMinutes) = dueDate + (intervalMinutes × maxFollowupReminders)
```

i.e. the moment the full reminder chain would have run out (default: due time + 1 hour). `effectiveStatus()` returns `'missed'` once `DateTime.now()` passes that threshold and the stored status is still `'pending'` — this reconciles the old "missed the instant due time passes" rule with the new reminder loop, so an occurrence stays `pending` (and keeps being nagged about) for the full chain duration rather than flipping to missed while reminders are still actively trying to reach the patient.

`HomeScreen`/`PatientDashboard` both proactively **persist** this via `_persistMissedStatus`, called in a `postFrameCallback` — once the threshold passes, the derived `'missed'` gets written back to Firestore (legacy field or subcollection doc, same branch as everywhere else) rather than staying purely computed client-side.

---

## 6. Worked example — a daily recurring task

Task: **"Take blood pressure medicine"**, daily, due 08:00, `reminderIntervalMinutes = 5` (default).

| Time | What happens |
|---|---|
| App opens (any time) | `reconcilePatientReminders` finds today's 08:00 occurrence is `pending`, schedules its chain: 08:00 (due), 08:05, 08:10, ... 09:00 (followup12) |
| 08:00 | OS fires the "due" notification (native banner, Complete/Missed action links). **If the app happens to be open**, `PatientDashboard`'s own check independently notices the same occurrence is due, auto-shows `ReminderPopup`, and cancels the whole chain (dismissing the just-shown banner from the shade) |
| 08:00–09:00, app stays closed | Native follow-ups keep firing every 5 minutes, un-suppressed, since nothing in-app ever ran to cancel them |
| Patient taps Complete (either UI, any time before 09:00) | `setOccurrenceStatus(taskId, 2026-08-16, 'completed')` written; `cancelOccurrenceReminders` cancels every remaining id in the chain immediately |
| Patient never responds, 09:00 passes | `effectiveStatus` starts returning `'missed'` everywhere it's read; `_persistMissedStatus` writes `'missed'` into the occurrence subcollection doc on the next screen that's open |
| Next day, 08:00 | A **new** occurrence date (`2026-08-17`) — its own fresh subcollection doc, own fresh chain, completely independent of yesterday's `'missed'`/`'completed'` result |

---

## 7. Known limitations (documented, not oversights)

- **Foreground suppression has a race window.** The in-app popup's due-check runs on Firestore snapshot updates or a 1-minute timer — not instantly at the due second. In the worst case, the native banner can flash for up to ~60s before the app-side check catches up and cancels it.
- **No server-side push.** Everything is on-device `flutter_local_notifications` scheduling — no FCM, no backend. A caregiver's device can never trigger a notification on the patient's device directly; the patient's own app has to reconcile and schedule its own reminders.
- **7-day reconciliation window.** A recurring task's chain is only ever scheduled for occurrences in the next 7 days from whenever the patient's app was last opened. If the patient doesn't open the app for more than 7 days, occurrences beyond that window never get alarms scheduled until the next open.
- **`reconcilePatientReminders` is a one-shot pass**, not a live stream — a task created/edited by the caregiver while the patient's app is already open won't get its reminders scheduled until the patient's app restarts or resumes (`main.dart`/`PatientDashboard.initState` are the only call sites).
