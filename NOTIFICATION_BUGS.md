# Notification System — Bug Findings

Code review of `notification_service.dart`, `reminder_popup.dart`, and `patient_dashboard.dart`'s notification-related code. Companion to `NOTIFICATION_STRUCTURE.md` (which documents the intended design) — this file documents where the current implementation diverges from it.

**Status: #1 (critical), #2 (high), and #3 (medium) are fixed** — see the ✅ markers below for what changed. #4–#7 are still open, lower-priority notes.

---

## 1. ✅ FIXED — CRITICAL — Auto-popup can re-prompt Complete/Missed for an already-completed recurring occurrence

**Where:** `patient_dashboard.dart`, `_maybeShowDueReminder` (~line 348)

```dart
final String stored = (entry.data['status'] ?? 'pending') as String;
if (stored != 'pending') continue;
```

**The bug:** `entry.data` is the raw **task document's** map. For a recurring task, the top-level `status` field is written **once, at creation** (`'status': 'pending'`, see `firestore_service.dart:52`) and is **never updated again** — every real completion write for a recurring task goes to the separate `tasks/{taskId}/occurrences/{yyyy-MM-dd}` subcollection instead (`setOccurrenceStatus`), exactly as documented in this class's own doc comment ("a recurring task has no single status of its own... reads/writes its status via the subcollection instead of the shared doc's own status field").

So for **any** recurring task, `entry.data['status']` reads `'pending'` forever, regardless of whether today's specific occurrence has actually been completed. The `stored != 'pending'` check is effectively dead for recurring tasks — it never filters anything.

**Failure scenario:**
1. Patient completes today's occurrence of a recurring task via its **timeline card** (or a native notification action button) — before the auto-popup has ever fired for it.
2. The next rebuild (Firestore snapshot update, or the 1-minute status timer) re-runs `_maybeShowDueReminder`.
3. `stored` still reads `'pending'` (top-level field, untouched). The occurrence's key isn't in `_shownReminderKeys` yet (this is the *first* time the auto-popup logic has looked at it).
4. `ReminderPopup` pops up asking the patient to Complete/Missed an occurrence they already completed.

**Why this wasn't caught by the existing "known tradeoff" precedent:** the doc comment justifies this by pointing at `_nextUpIndex`, which uses the same raw-status approximation — but `_nextUpIndex` only picks a cosmetic highlight (worst case: a stale "Up Next" badge). Here the same approximation drives whether to interrupt the patient with a modal dialog, which is a much higher-stakes use of a data source that's known to be wrong for recurring tasks specifically.

**Suggested fix direction:** the recurring branch needs the *live* per-occurrence status (`FirestoreService.getOccurrenceStatus`/`getOccurrenceStatusStream`), not the task doc's top-level field. Since `_maybeShowDueReminder` currently runs as a plain synchronous scan, the simplest fix is to make it `async` and `await getOccurrenceStatus(taskId, occurrenceDate)` for recurring entries right before deciding to show the popup (it's already called from an `addPostFrameCallback`, which tolerates async work fine).

**Fix applied:** `_maybeShowDueReminder` is now `async`; recurring entries `await FirestoreService.getOccurrenceStatus(taskId, occurrenceDate)` instead of reading `entry.data['status']`, non-recurring entries still use the top-level field directly (it's the correct source of truth for them). Since the function now awaits inside its loop, `_popupOpen` and `_shownReminderKeys` are re-checked immediately after every `await` (not just once up front) to close a race where two overlapping calls — triggered by two rebuilds firing close together — could otherwise both decide to show a popup for the same or different occurrences before either had set `_popupOpen`.

---

## 2. ✅ FIXED — HIGH — `ReminderPopup` has no role check; a caregiver's own reminder can open patient-response controls

**Where:** `notification_service.dart`, `_showReminderPopupForTap` (~line 158); `reminder_popup.dart` (whole widget)

**The bug:** `scheduleReminder` (the original, pre-Phase-3 single-shot reminder configured via `CreateTaskScreen`) is explicitly documented as firing **on the caregiver's own device** ("`[scheduleReminder]` is called from CreateTaskScreen (caregiver-only), so it fires on the CAREGIVER's device" — class doc comment). Before this session's changes, tapping *any* delivered notification opened `TaskDetailScreen`, which is role-aware — it only renders the Complete/Missed row when `_isPatient` is true; a caregiver instead sees an "Edit Task" button.

`_showReminderPopupForTap` now replaces that navigation with `ReminderPopup` for **every** notification-body tap, regardless of which payload format triggered it or which role's device received it. `ReminderPopup` itself performs **no role check at all** — it always renders working Complete/Missed buttons that write directly to `updateTaskStatus`/`setOccurrenceStatus`.

**Failure scenario:** a caregiver configures a personal single-shot reminder on a patient's task (e.g., "remind me at 8am to check in"). It fires on the caregiver's own phone. Tapping it now shows the caregiver `ReminderPopup` — letting them mark the *patient's* task Complete/Missed through UI that was designed exclusively for the patient's own self-report. This silently bypasses the role split `TaskDetailScreen` enforced.

**Suggested fix direction:** either (a) check the current user's role before choosing `ReminderPopup` vs. `TaskDetailScreen` in `_showReminderPopupForTap` (mirroring `TaskDetailScreen`'s own `_isPatient` check), or (b) only use `ReminderPopup` for payloads that came from the Phase-3 occurrence chain specifically (which is patient-only by construction, since `reconcilePatientReminders` only ever runs on the patient's device) and keep `TaskDetailScreen` for the legacy single-shot payload format.

**Fix applied:** option (a). Added `NotificationService._currentUserIsPatient()`, which reads the current device's logged-in `users/{uid}.role`, defaulting to `false` (falls back to `TaskDetailScreen`) on no session, no user doc, or a read failure — showing patient controls to the wrong role is the worse failure mode than an occasional unnecessary fallback. `_showReminderPopupForTap` now fetches this in parallel with the task data (`Future.wait`) and folds it into the existing fallback condition: `ReminderPopup` only shows when `isPatientDevice` is true; everyone else gets the same `TaskDetailScreen` navigation as before.

---

## 3. ✅ FIXED — MEDIUM — `ReminderPopup` doesn't check whether the occurrence is already resolved

**Where:** `reminder_popup.dart`, `build()`

**The bug:** `TaskDetailScreen` only shows its Complete/Missed row when `_occurrenceStatus != 'completed'` — once resolved, the response controls disappear. `ReminderPopup` has no equivalent guard: it always renders active Complete/Missed buttons regardless of the occurrence's current status, including one that's already `'completed'` or `'missed'`.

**Impact:** functionally harmless on its own (writes are idempotent — re-writing the same status is a no-op per `setOccurrenceStatus`'s own doc comment), but it's a UX gap: a patient re-opening an old notification, or two response paths racing (native action + in-app popup both live for the same occurrence — see finding 4), sees no indication the occurrence was already handled and can tap either button again with no feedback that anything changed.

**Suggested fix direction:** pass in (or fetch) the occurrence's current status before/while showing the popup, and either skip showing it entirely if already resolved, or render a "you already marked this complete" state instead of live buttons.

**Fix applied:** `ReminderPopup` now fetches its own occurrence's current status in `initState` (live per-occurrence status for recurring, the task doc's `status` field for non-recurring) and branches its footer on the result: a brief spinner while loading, an "Already marked complete/missed" acknowledgment with just a Close button if already resolved, or the normal Complete/Missed row otherwise. This is a widget-level fix (not just at today's two call sites), so any future caller of `ReminderPopup.show` gets the same protection automatically. Doesn't address finding #4 below (staying live while already open) — that's still open.

---

## 4. LOW — Popup doesn't auto-dismiss if the occurrence is resolved through another channel while it's open

**Where:** `reminder_popup.dart` / `patient_dashboard.dart` interaction

If a native notification action button (Complete/Missed) is tapped while `ReminderPopup` is *already open in-app* for the same occurrence, the popup has no live subscription to the occurrence's status — it just sits there with stale, still-tappable buttons until the patient interacts with it directly. Related to finding 3 (no current-status awareness) but specifically about staying open rather than not opening in the first place.

---

## 5. LOW — Barrier-dismiss silently ends all reminders for that occurrence, for the whole session

**Where:** `patient_dashboard.dart`, `_maybeShowDueReminder`

`cancelOccurrenceReminders` is called the **instant** the popup is decided to show — before the patient has interacted with it at all. So dismissing via barrier tap (no response) means: no more native follow-ups (already cancelled), and no in-app re-prompt this session (`_shownReminderKeys` already recorded). This matches what's documented as intentional ("no snooze/re-show, same as ignoring the OS notification would") — flagging here only to confirm that's still the intended behavior, since it's a fairly easy way for a reminder to go permanently silent for the rest of the day with a single accidental outside-tap.

---

## 6. LOW / edge case — closest-occurrence guess can pick a future occurrence over a more relevant recent one

**Where:** `notification_service.dart`, `_showReminderPopupForTap` (~line 197-209)

For a task that is **both** recurring **and** has the legacy single-shot `reminderAt` configured (payload has no `dateKey`), the fallback picks the occurrence with the smallest **absolute** time difference from now — not the most recently-due one. Late at night, this can pick tomorrow's occurrence over today's already-due one. Pre-existing logic, carried over verbatim from `TaskDetailScreen`'s own implementation (not introduced by the recent `ReminderPopup` work) — noted for completeness, not a regression.

---

## 7. LOW / operational caveat — inexact alarm fallback can bunch or reorder the follow-up chain

**Where:** `notification_service.dart`, `_scheduleOccurrenceNotification`

When `canScheduleExactNotifications()` is false (permission not granted / OEM restriction), scheduling falls back to `AndroidScheduleMode.inexactAllowWhileIdle`. Android is free to batch/delay inexact alarms, which can bunch the 5-minute-spaced follow-up chain together or fire them out of the intended cadence. Platform-level constraint, not fixable in Dart — noted so it isn't mistaken for an app bug if observed on a real device with exact-alarm permission denied.

---

## Status

- ✅ #1 (critical), #2 (high), #3 (medium) — fixed. `flutter analyze` clean (no new errors/warnings beyond the pre-existing baseline).
- ⬜ #4, #5, #6, #7 — still open, lower priority. #5 in particular is a documented-intentional behavior, not obviously a bug — worth a decision rather than a silent fix. Let me know if any of these should be addressed too.
