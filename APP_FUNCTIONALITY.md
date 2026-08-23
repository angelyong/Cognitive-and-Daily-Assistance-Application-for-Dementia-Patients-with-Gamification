# MindCare — Full Functionality Reference

Flutter Android app (package `testproject`), Firebase Auth + Cloud Firestore backend, local (on-device) notifications via `flutter_local_notifications`. Dark purple design system throughout. Two roles — **Caregiver** and **Patient** — share one codebase and are routed to different screens/navigation based on the `role` field on their `users` document.

This document describes **actual, implemented behaviour** as of the current codebase — not aspirational/planned features. Where a file exists but is empty or unreferenced anywhere in the app, it's called out explicitly in [Unused / Dead Files](#unused--dead-files) rather than documented as a feature.

---

## 1. Tech Stack

| Concern | Choice |
|---|---|
| Framework | Flutter (Dart SDK ^3.10.7) |
| Backend | Firebase Auth (email/password) + Cloud Firestore |
| Local notifications | `flutter_local_notifications` ^18.0.1 (pinned) + `timezone` ^0.10.1 |
| Calendar UI | `table_calendar` ^3.2.1 |
| Persisted local prefs | `shared_preferences` (font scale) |
| Date formatting | `intl` |
| Login celebration | `confetti` + `audioplayers` |
| No backend functions | Everything is local-notification / client-Firestore based — no Cloud Functions, no FCM, no push server |

---

## 2. Roles & Authentication

### 2.1 Registration (`RegisterScreen`, route `/register`)
- Fields: Full Name, Email, Role (dropdown: **Dementia Patient** / **Caregiver**), Password, Confirm Password.
- Validation: all fields required; password must match confirm-password.
- On submit: `AuthService.registerUser()` creates a Firebase Auth account and a `users/{uid}` document with `role`, `streakPoints: 0`, `currentStreak: 0`, `longestStreak: 0`, `lastLoginDate: null`.
- **This is a self-registration path** — anyone can register directly as either role. It exists alongside the caregiver-mediated patient-creation flow (§7.5) as a second, independent way a patient account can come into existence.
- On success: returns to `/login`.

### 2.2 Login (`LoginScreen`, route `/login`, app's `initialRoute`)
- Email + password fields, show/hide password toggle, "Remember me" checkbox (UI only, not wired to persistence), "Forgot Password?" (placeholder — shows a snackbar, not implemented).
- On submit: `AuthService.loginUser()` signs in, fetches the `users/{uid}` doc.
- **Patient login** additionally calls `StreakService.checkAndUpdateStreak()` (§10) — if a streak was awarded, a "Day N Streak!" dialog shows, then a full-screen `LoginSuccessEffect` (confetti + chime + "Welcome back!") plays for ~2.8s before routing to `/patientdashboard`.
- **Caregiver login** routes straight to `/homescreen`, no effect.
- Errors surface via `FirebaseAuthException` code/message in a snackbar.

### 2.3 Logout (`SideDrawer`, all roles)
- Confirmation dialog ("Are you sure you want to logout?") → `AuthService.logout()` → `Navigator.pushNamedAndRemoveUntil('/login')` (clears the entire nav stack).

### 2.4 Welcome Screen — **built but not routed**
`lib/screens/welcome_screen.dart` is a real, functional "MindCare — Login / Register" launcher screen, but it is not referenced in `main.dart`'s routes or anywhere else — the app's `initialRoute` goes straight to `/login`, bypassing it entirely. Currently dead weight, not part of the live app flow.

---

## 3. Navigation

### 3.1 Route table (`main.dart`)
| Route | Screen | Notes |
|---|---|---|
| `/login` (initial) | `LoginScreen` | |
| `/register` | `RegisterScreen` | |
| `/homescreen` | `HomeScreen` | Caregiver dashboard |
| `/patientdashboard` | `PatientDashboard` | Patient dashboard |
| `/activityprogress` | `ActivityProgress` | Caregiver calendar |
| `/createtask` | `CreateTaskScreen` | Also pushed directly (not via route) with constructor args for edit mode |
| `/cognitive` | `CognitiveExerciseScreen` | Patient games hub |
| `/streak` | `StreakScreen` | Patient streak/points |
| `/taskhistory` | `TaskHistoryScreen` | Caregiver, per-patient history |
| `/patienttaskhistory` | `PatientTaskHistoryScreen` | Patient's own history |
| `/addpatient` | `AddPatientScreen` | Caregiver |
| `/managepatient` | `PatientListScreen` | Caregiver |
| `/settings` | `SettingsScreen` | Shared |
| `/taskdetail` | `TaskDetailScreen` | Shared, `arguments` = taskId string |

`EditPatientScreen` is reachable only via `Navigator.push` from `PatientListScreen` (not a named route) since it needs constructor args (patientUid/name/email).

### 3.2 Side Drawer (`SideDrawer`, all authenticated screens)
Role-aware — fetches the current user's `role` once and conditionally shows:

**Everyone:** Dashboard (routes to `/homescreen` or `/patientdashboard` depending on role), Settings, Logout.

**Caregiver only:** Create Task, Task History, Activity Progress, Manage Patient.

**Patient only:** Streak Progress, Cognitive Games.

### 3.3 Bottom navigation
- **HomeScreen** (caregiver): Home / Activities. "Activities" navigates to `ActivityProgressScreen` (calendar icon).
- **CreateTaskScreen** (caregiver): Home / Activities — same "Activities" → `ActivityProgressScreen` wiring; "Home" tab is currently a no-op tap.
- Neither patient screen has a bottom nav (drawer-only navigation for patients).

---

## 4. Firestore Data Model

### 4.1 `users/{uid}`
| Field | Type | Notes |
|---|---|---|
| `uid`, `name`, `email`, `role` (`'patient'` \| `'caregiver'`) | | |
| `caregiverId` | string | Patient docs only — the caregiver-patient link. Removed (not the doc) on unlink. |
| `dementiaStage` | `'early'` \| `'middle'` | Patient docs. Missing → defaults to `early`. Drives which Cognitive Games set is shown. |
| `dementiaType` | `'alzheimers'` \| `'vascular'` \| `'lewy_body'` \| `'ftd'` | Patient docs. Display-only badge. |
| `difficultyTier` | `'foundations'` \| `'standard'` \| `'challenge'` | Patient docs. Missing → defaults to `standard`. Applies to all cognitive games uniformly. |
| `streakPoints`, `currentStreak`, `longestStreak`, `lastLoginDate` | | Gamification (§10). |

### 4.2 `tasks/{taskId}`
One document per task **or recurring series** (never one document per occurrence).
| Field | Type | Notes |
|---|---|---|
| `caregiverId`, `patientId` | string | |
| `title`, `category`, `description`, `dosage` (nullable) | string | `category` drives the Medication vs Task split on dashboards. |
| `dueDate` | Timestamp? | For a recurring task, this is the **start** date/time. |
| `reminderAt` | Timestamp? | The **pre-existing, separate** single-shot reminder (caregiver-configured arbitrary time; independent of the due-time reminder chain below). |
| `status` | `'pending'` \| `'completed'` \| `'missed'` | Meaningful as-is only for a **non-recurring** task. For a recurring task this only reflects the literal document's own (start) occurrence — see §4.3. |
| `recurrenceType` | `'none'` \| `'daily'` \| `'weekly'` \| `'monthly'` \| `'yearly'` \| `'custom'` | Missing → `none` (old docs unaffected). |
| `recurrenceRule` | map \| null | `{weekdays: [1-7...], interval: n, unit: 'days'\|'weeks'\|'months'}` — only the fields relevant to the type are meaningful. |
| `endDate` | Timestamp? | Null = recurs forever. |
| `reminderIntervalMinutes` | int | Missing → 5. Spacing of the due-time reminder chain follow-ups (§9). |
| `createdAt` | Timestamp | |

### 4.3 `tasks/{taskId}/occurrences/{yyyy-MM-dd}` (subcollection)
Only used for **recurring** tasks — gives each calendar-date occurrence its own independent state, since one series document can't hold a single `status`.
| Field | Type |
|---|---|
| `status` | `'pending'` \| `'completed'` \| `'missed'` |
| `updatedAt` | Timestamp |

A missing doc (occurrence never touched) implicitly means `pending`.

### 4.4 Firestore indexes in use
- `tasks`: (`caregiverId` ASC, `dueDate` ASC) — HomeScreen's today ±3-day window.
- `tasks`: (`patientId` ASC, `dueDate` DESC) — task history / calendar occurrence source.

No `firestore.rules` file exists in this repository — security rules (if any) are managed outside the codebase; **not** something this document can confirm.

---

## 5. Theme / Design System

- `AppColors` — `bgDark`, `cardPurple`, `cardPurpleLight`, `orangeStart`/`orangeEnd` (brand gradient), `greenCheck`, `orangeEnd` (error/missed), `textMuted`, `categoryChipBg`/`categoryChipText`, `medIconBg`, `stageEarly`/`stageMiddle`, four `typeXxx` colours for dementia type.
- `AppTextStyles` — `heading`, `sectionTitle`, `cardTitle`, `muted`, `actionLink`.
- `AppDecorations` — `card` (rounded purple container), `gradientCard()`, `darkInput()` (the standard filled dark text-field decoration used everywhere).
- `AppGradients.orange` — the brand gradient used on progress cards, buttons, drawer header.
- Font scaling: `FontScaleNotifier` (0.8×–1.6×, persisted via `shared_preferences`) is applied globally through a `MediaQuery`/`TextScaler` wrapper around the whole `MaterialApp` — every screen resizes together from one Settings slider.

---

## 6. Caregiver Functionality

### 6.1 HomeScreen (`/homescreen`) — Caregiver Dashboard
- Greeting ("Good Morning, {name}!"), today's date, avatar with initials.
- **Today's Progress** card: Tasks Done X/Y, Meds Taken X/Y (see §9's scope note — only non-recurring tasks count toward these totals).
- **Daily Tasks** and **Medication Schedule** sections, each showing tasks due today ±3 days (`getTasks(caregiverId)`), **grouped by patient** — a name sub-heading per patient, with a `DementiaStageBadge` and `DementiaTypeBadge` next to the name (wraps to a second line if the combined text is too wide for the screen).
- Each task/med row is a `TaskCard`/`MedicationCard`: tick icon to toggle complete/pending (caregiver can freely untick, unlike a patient — see §9.6), strikethrough title once done, red "Missed" tag, category chip, tap-through to `TaskDetailScreen`.
- **Occurrence-aware**: a recurring task's card shows/toggles the status of *today's* occurrence (via the `occurrences` subcollection), not a meaningless series-level field; a recurring task auto-flips to "missed" only once its reminder chain's safety cap elapses, not the instant it becomes due (§9).
- "Add Task" / "Add Med" links jump to `CreateTaskScreen`.
- "Start Cognitive Activities" card at the bottom — currently a `// TODO`, no-op (caregiver has no reason to play the patient's games, this button was never wired).
- Bottom nav: Home / Activities (→ `ActivityProgressScreen`).

### 6.2 CreateTaskScreen (`/createtask`, also pushed directly for edit mode)
Used for both **create** and **edit** (constructor takes optional `taskId`/`existingData`/`initialCategory`).

Fields:
- **Task Title** (required).
- **Category** dropdown: Medication, Exercise, Meal, Hygiene, Social, Appointment, Other.
- **Dosage** — shown only when category = Medication, required in that case.
- **Due/Start Date & Time** — date + time pickers; label switches to "Start Date/Time" once a repeat option is chosen.
- **Repeat**: Does not repeat / Daily / Weekly / Monthly / Yearly / Custom.
  - Weekly → multi-select weekday chips (Mon–Sun).
  - Custom → "Every [n] [Days/Weeks/Months]" + (if Weeks) the same weekday chips.
  - Recurrence requires a start date+time.
- **Ends**: Never / End on date (date picker) — only shown when a repeat option is active.
- **Reminder Interval** dropdown: 5 / 10 / 15 minutes (default 5) — how often the patient's own device re-reminds them after the due-time notification.
- **Assign to Patient** dropdown (populated from the caregiver's linked patients; a since-unlinked patient still shows as a locked placeholder so the form doesn't crash, with a red warning to reassign before saving).
- **Description** (optional, multi-line).
- **Reminder bell** (top-right icon): a *separate*, older feature — pick an arbitrary date+time for a one-off notification (`reminderAt`), independent of due-time/recurrence. Clear/Cancel/Save popup.
- **Delete** (edit mode only, top-right icon) — confirmation dialog, deletes the task and cancels its single-shot reminder.
- Validation covers: title non-empty, category selected, patient selected, dosage required for Medication, start date/time required when recurring, ≥1 weekday for Weekly/Custom-weeks, positive custom interval, end date not before start date.
- Save calls `FirestoreService.addTask`/`updateTask`, then schedules/cancels the single-shot `reminderAt` notification if set.
- Bottom nav: Home / Activities (Activities → `ActivityProgressScreen`).

### 6.3 ActivityProgressScreen (`/activityprogress`) — Caregiver Calendar
- Patient selector dropdown (same pattern as everywhere else).
- Month calendar (`table_calendar`), themed to match the app (orange = selected day, purple = today, green dot = a day with tasks).
- **Recurring tasks are expanded into real per-day occurrences** on the calendar (via the shared `getOccurrencesForDateRange` function) — a recurring task's dot appears on every date it actually recurs, not just its start date.
- Selecting a date shows that day's task list below: title, time, category chip, and either a status badge (Pending/Completed/Missed) for a single task, or a "Repeats" chip (with the recurrence type) for a recurring occurrence — since per-occurrence completion isn't shown here, only tracked (see §9's scope note).
- Tapping a task opens the read-only `TaskDetailScreen`. No task creation/editing from the calendar itself.
- Handles: no patient selected, patient has no tasks, empty date, loading, and Firestore errors gracefully.

### 6.4 TaskHistoryScreen (`/taskhistory`) — Caregiver
- Patient dropdown + status filter chips (All/Completed/Missed).
- Full, unfiltered-by-date task list for the selected patient (title, due date/time, category, status badge). Tap → `TaskDetailScreen`.

### 6.5 Patient Management
- **PatientListScreen** (`/managepatient`): live list of linked patients (`PatientCard` — avatar initials, name, stage badge, type badge), "+" opens `AddPatientScreen`, tap opens `EditPatientScreen`.
- **AddPatientScreen** (`/addpatient`): caregiver-mediated onboarding.
  - Fields: Patient Name, Patient Email, Starter Password (with a "Generate" button producing something like `Mind4821!`), Dementia Stage dropdown (with live badge preview), Dementia Type dropdown (with live badge preview).
  - Under the hood: `PatientAccountService` creates the Firebase Auth account on a **secondary Firebase app instance** so the caregiver's own session is untouched, writes the `users/{uid}` doc with `caregiverId` set to the current caregiver.
  - On success: a dialog shows the email/password to hand to the patient (with a Copy-to-clipboard button), then returns to `/homescreen`.
- **EditPatientScreen** (pushed with args, not a named route):
  - Edit patient name (email is read-only — it's the sign-in identity).
  - "Send Password Reset Email" button (Firebase's built-in reset flow — no backend needed).
  - "Remove Patient" (top-right icon) — confirmation dialog, unlinks (clears `caregiverId`) without deleting the patient's account/data/history.
  - **Cognitive Game Difficulty** picker (Foundations/Standard/Challenge chips + description) — sets `difficultyTier`, applies to every one of that patient's games.

---

## 7. Patient Functionality

### 7.1 PatientDashboard (`/patientdashboard`)
- Same visual shape as HomeScreen but scoped to "me" only — no patient grouping, no create/edit actions.
- **Today's Progress**, **Daily Tasks**, **Medication Schedule** sections.
- A recurring task only appears here on a day it actually has an occurrence (fixed as part of the reminder work — previously it would have shown every day forever).
- Tapping the tick icon marks a task **complete** — but **cannot be tapped again to undo it** once completed (see §9.6); a "+2 points!" snackbar confirms.
- Calls `NotificationService.reconcilePatientReminders()` on open — (re)schedules this patient's own upcoming due-time reminders (see §9 — this **must** run from the patient's own device/session).

### 7.2 PatientTaskHistoryScreen (`/patienttaskhistory`)
- Own full history (no date window), status filter chips.
- Tap a task → bottom sheet:
  - If **not yet completed**: a Status dropdown (pending/completed/missed) + Save, and a "Delete Task" button.
  - If **already completed**: the dropdown is replaced with a plain "✓ Completed" readout — a patient can't reverse a completed task from here either (Delete remains available).

### 7.3 TaskDetailScreen (`/taskdetail`, shared, patient-relevant parts)
- Read-only for everyone: title, status badge, category chip, Due/Starts date, Repeats summary (for recurring tasks — "Repeats weekly on Mon, Wed (until Sep 30, 2026)" style), Dosage (medication only), Description.
- **Patient-only Complete/Missed buttons**: shown whenever there's a "relevant occurrence" (the task's own due date for a single task; whichever recurring occurrence within ±2 days of now is closest to now) and it isn't already completed. Tapping either records the response (to the right place — legacy field or the occurrence subcollection), cancels the rest of that occurrence's reminder chain, and shows a confirmation snackbar. This is also exactly what opening a due-time reminder notification's body leads to (§9).
- **Caregiver-only Edit Task button** → opens `CreateTaskScreen` pre-filled.

### 7.4 StreakScreen (`/streak`)
See §10 — big flame + current streak count, a 7-day reward-cycle row (days 1–7, +1 to +7 points), and a stats row (Total Points, Level, Best Streak).

### 7.5 CognitiveExerciseScreen (`/cognitive`) — Games Hub
Fetches the patient's `dementiaStage` and shows **one of two entirely different game sets** (not the same games at different difficulty — that's the separate tier axis, §7.6):

**Early Stage set (4 games)** — multi-step cognitive/problem-solving tasks:
1. **Category Naming** — tap every picture matching a shown category among distractors.
2. **Memory Matching** — classic flip-two-cards pair matching.
3. **Remember This** (Prospective Memory) — remember to act on a deferred cue while doing something else.
4. **Daily Routine** (Sequencing) — tap the steps of a routine (making tea / getting dressed / brushing teeth) into the correct order.

**Middle Stage set (3 games)** — recognition/sensory/reminiscence tasks, shorter sessions, stronger cueing, larger touch targets, no time pressure:
1. **Picture Match** (Picture Recognition) — "Which one is the [apple]?" — pick the right picture from 2–3 large options.
2. **Sort It Out** (Sorting) — sort one item at a time into one of two large category bins.
3. **Who Is This?** (Name–Face Association) — see a photo + a partially-obscured name, pick the right name from options (vanishing-cue hinting).

Shared design across all 7 games:
- **Errorless learning**: a wrong answer is never a hard failure — encouragement + progressively stronger hints, never a dead end.
- **Spaced retrieval**: a missed item is re-queued to come up again shortly after, not just abandoned.
- Completion awards points via `FirestoreService.awardPoints` (feeds the same `streakPoints` total as the streak system, §10).
- Memory Matching, Category Naming, Who Is This?, and Remember This additionally scale with the caregiver-set **difficulty tier** (§7.6) — item counts, time limits, cue strength. The 3 newer games (Daily Routine, Picture Match, Sort It Out) intentionally do **not** integrate the tier system (a documented scope decision, not an oversight).

### 7.6 Difficulty Tiers (orthogonal to Stage)
Caregiver-set per patient (`EditPatientScreen`), applies uniformly to every tier-aware game:
- **Foundations** — fewest items, no/generous time limits, strong slow-fading cues, more attempts, larger touch targets.
- **Standard** (default) — moderate items/time, some hints.
- **Challenge** — more items, tighter time, minimal cueing, fewer attempts.

### 7.7 Settings (`/settings`, shared)
Font-size slider (80%–160%, live preview text, "Reset to Default") — the only setting currently exposed, deliberately left room to add more later.

---

## 8. Recurring Tasks (deep detail)

One Firestore document per series (never one per future date). `getOccurrencesForDateRange(series, rangeStart, rangeEnd)` is the **single source of truth** for turning a series into concrete calendar dates — used identically by the calendar, the reminder scheduler, and every dashboard; no duplicated recurrence math anywhere.

Semantics (all pure date math, no network calls):
- **None** — a single occurrence, exactly the stored `dueDate`.
- **Daily** — every day from start to end (inclusive).
- **Weekly** — every selected weekday (defaults to the start date's own weekday if none chosen), every week, from start to end.
- **Monthly** — same day-of-month each month, **clamped to the month's last day** if it doesn't exist (e.g. 31 Jan → 28/29 Feb). Recalculated fresh each month (not "sticky" from a clamped month).
- **Yearly** — same month/day annually; Feb 29 clamps to Feb 28 in non-leap years, back to Feb 29 in leap years.
- **Custom** — "every N days/weeks/months," with weekday filtering when the unit is weeks (same clamping/weekday rules as above, just interval-stepped).

All date arithmetic is plain local `DateTime` (no UTC conversion) — deliberately, since the app targets Malaysia (UTC+8, no DST), where local-time stepping never shifts a day.

---

## 9. Reminders & Notifications (deep detail)

MindCare has **two independent notification mechanisms** — don't conflate them:

### 9.1 Single-shot reminder (pre-existing)
Set via the bell icon in `CreateTaskScreen`, fires once at a caregiver-chosen arbitrary time (`reminderAt`), scheduled **from the caregiver's own device** (since only they open that screen), tap opens `TaskDetailScreen`. There is no in-app history/browse UI for these — that feature (Notification History) has been removed from the app.

### 9.2 Due-time reminder chain (the newer system)
When a task/occurrence becomes due and the patient hasn't responded, the app notifies repeatedly until they do.

- **Scheduled from the patient's own device/session** — `PatientDashboard.initState()` and, for an already-logged-in patient, app cold-start in `main.dart`, both call `NotificationService.reconcilePatientReminders(patientId)`. This is a deliberate architectural choice: local notifications can only fire on the device that schedules them, so a patient-facing "respond to this" flow has to be scheduled by the patient's own app instance, not the caregiver's.
- **Window**: only occurrences in the next 7 days are ever scheduled (re-derived fresh — safely re-runnable — every time reconciliation runs), keeping the number of OS-scheduled alarms bounded.
- **Chain shape per occurrence**: one notification exactly at the due time, then up to **12 follow-ups** spaced at the task's configured `reminderIntervalMinutes` (5/10/15 min) apart. 12 is a count, not a fixed duration, so a 15-minute interval genuinely nags for ~3 hours rather than being throttled.
- **Stop condition**: Complete/Missed (from an action button, or the in-app buttons on `TaskDetailScreen`) writes the response and **proactively cancels every remaining id** in that occurrence's chain. (There's no live "check Firestore before displaying" hook available in this plugin — cancellation is the enforcement mechanism, not a per-alarm database check. A response landing in the exact instant an already-in-flight alarm fires is a narrow, harmless race — worst case one stale notification whose own buttons just re-confirm the same status.)
- **Catch-up handling**: any chain slot whose time has already passed (app was closed, device was off) is simply skipped rather than fired late — the remaining future slots still schedule normally, anchored to the *original* due time, so the total nagging window and the auto-missed threshold stay correct regardless of when the app happens to reopen.
- **Auto-missed**: an occurrence that's still `pending` once its full chain has elapsed (`dueDate + 12 × interval`) is treated (and, opportunistically, persisted) as `missed` — this reconciles the pre-existing "flip to missed instantly" dashboard logic with the new reminder loop, which needs a task to stay `pending` (and keep reminding) for a while after its due time.
- **Action buttons**: notifications carry **Complete** / **Missed** buttons (Android + iOS category). Tapping one works whether the app is foreground, backgrounded, or fully closed (a background isolate handler re-initializes Firebase just enough to write the response and cancel the chain — this specific path needs on-device verification, since it can't be exercised from a dev machine). Tapping the notification's body instead (not a button) opens `TaskDetailScreen`, which shows the same Complete/Missed buttons as a reliable fallback either way.
- **Independence**: every occurrence of every task has its own deterministic id set (`hash(taskId|date|due)`, `hash(taskId|date|followup1..12)`) — completing one task's 09:00 reminder never touches another task's 09:15 reminder, and completing today's occurrence of a recurring series never touches tomorrow's.
- **Per-occurrence status**: this is what makes the chain meaningful for a recurring series — see §4.3. A single task keeps using its plain `status` field, completely unchanged from before this system existed.
- **Content**: title "MindCare Reminder" always; body names the task + category on the first notification, and a gentle "Please check your task: {title}" on follow-ups — deliberately non-alarming, no deficit-focused language.
- **Reboot survival**: already-scheduled alarms survive a device reboot via the plugin's own boot receiver (already present in the Android manifest, unmodified). The app-open reconciliation pass is a second, independent safety net on top of that (also covers the app having been force-stopped, which cancels all of an app's pending alarms on Android).
- **Not built on `Timer.periodic`** anywhere — every reminder is an OS-scheduled `zonedSchedule` alarm, so delivery doesn't depend on the app process staying alive.

### 9.3 Known, documented scope cuts
- Recurring-task completion doesn't factor into the "Today's Progress" X/Y counts on either dashboard (async per-occurrence data, a synchronous count can't cheaply reflect it) — only non-recurring tasks count there.
- `HomeScreen`'s underlying query still windows by a task's own start date (±3 days) — an older recurring series whose start date has scrolled out of that window won't surface on the caregiver's Home even on a day it still recurs (pre-existing gap, not introduced by the reminder work; fixing it needs a query/index redesign).
- Neither the single-shot reminder nor the due-time reminder chain persist any browsable history record — the `notificationHistory` collection and its caregiver-facing screen were removed from the app; nothing writes to it any more.

### 9.4 Android permissions in use
`POST_NOTIFICATIONS`, `SCHEDULE_EXACT_ALARM`, `USE_EXACT_ALARM`, `RECEIVE_BOOT_COMPLETED`, `VIBRATE`, plus the two `flutter_local_notifications` broadcast receivers (scheduled-notification + boot). All requested from `main.dart` at startup; exact-alarm scheduling falls back to inexact automatically if the OS denies it.

### 9.5 Timezone handling
Alarms are anchored to `tz.UTC` using Dart's own local→UTC conversion (not device-reported timezone name detection, which is unreliable on some emulators/devices and can silently desync delivery by the UTC offset).

### 9.6 Patient one-way completion (recent change)
A patient can mark a task **Complete**, but — unlike a caregiver — **cannot untick it back to pending** once done. Enforced at three surfaces: the dashboard tick icon (disabled once completed), `PatientTaskHistoryScreen`'s status editor (dropdown replaced with a read-only "Completed" badge), and defensively inside the toggle functions themselves. A caregiver's own tick on `HomeScreen` is unaffected and still fully bidirectional.

---

## 10. Gamification — Streak & Points

- **Login streak**: `StreakService.checkAndUpdateStreak()` runs once per patient login. Awards points only on the *first* login of a calendar day; a gap of more than one day resets the streak to 1 (no grace period). Points for streak day N = `((N-1) % 7) + 1` (a 7-day cycle: day 1 = 1pt … day 7 = 7pts, day 8 loops back to 1pt).
- **Task/game points**: `FirestoreService.awardPoints()` adds/removes points on completion/un-completion of tasks (caregiver side) and cognitive games — feeds the same `streakPoints` total.
- **Level**: `totalPoints ÷ 50 + 1`.
- **StreakScreen** visualizes: current streak (flame icon), a 7-circle "this week" reward cycle with per-day point values, and a 3-stat row (Total Points, Level, Best Streak).

---

## 11. Shared Widgets

- `SideDrawer` — role-aware nav (§3.2).
- `TaskCard` / `MedicationCard` — the task-row widgets used on both dashboards; `onToggle` is nullable so a caller can disable the tick (used for the patient one-way-completion rule, §9.6).
- `DementiaStageBadge` / `DementiaTypeBadge` — small pill badges (2-dot progression indicator for stage; icon + label for type), reused across `AddPatientScreen`, `PatientCard`, `HomeScreen`, `CognitiveExerciseScreen`.
- `PatientCard` — patient list row (avatar initials, name, stage/type badges).
- `LoginSuccessEffect` — the post-patient-login confetti/chime overlay.

---

## 12. Unused / Dead Files

These exist in the repo but are not referenced anywhere else in the app — empty stubs or orphaned scaffolding, not live functionality:
- `lib/screens/caregiver/patient_status_screen.dart`, `lib/screens/caregiver/CaregiverUI.dart`, `lib/screens/patient/task_screen.dart`, `lib/screens/patient/exercise_screen.dart`, `lib/screens/patient/medicationScreen.dart`, `lib/widgets/dashboard_card.dart` — all empty or single-comment placeholder files.
- `lib/models/task_model.dart`, `lib/models/user_model.dart` — defined but never imported/used; every screen reads raw Firestore `Map<String, dynamic>` directly instead.
- `lib/screens/welcome_screen.dart` — fully built (§2.4) but not wired into `main.dart`'s routes; currently unreachable in normal app use.

---

## 13. Not Implemented (explicitly out of scope so far)

- Google Calendar / any external calendar API integration.
- Push notifications via FCM / any server-side notification delivery.
- Auto-adjusting game difficulty based on live in-game performance (tier is caregiver-set only).
- "Forgot Password" on the login screen (UI present, not wired).
- Per-game difficulty override (one tier applies to all of a patient's games).
- Caregiver preview of both cognitive-game stage sets (explicitly decided against — a patient only ever sees their own stage's set).
