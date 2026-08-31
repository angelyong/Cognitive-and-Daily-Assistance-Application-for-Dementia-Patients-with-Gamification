# Undone / Outstanding Work

Everything previously flagged as deferred, still-open, or awaiting your
sign-off, pulled together from every report written so far. Grouped by
source document, newest first. Nothing in this file has been changed —
it's a punch list only.

---

## 1. Hidden-bug findings you explicitly held back (`HIDDEN_BUGS.md`) — ✅ now fixed

Findings #1–#4 were fixed earlier this session. #5, #6, #7 were
deliberately held back at the time ("solve until 4 first, others hold
on") — all three are now fixed too:

| # | Severity | What | Fix applied | File |
|---|---|---|---|---|
| 5 | LOW | `_diffOrder` in Spot the Difference has exactly 4 entries; if a future level ever raises `differenceCount` past 4, `sublist()` would throw a `RangeError` and crash the game on load. | `differenceCount` is now clamped to `_diffOrder.length` before the `sublist()` call — caps at 4 differences instead of throwing, even if a future level config exceeds it. | `lib/screens/patient/games/spot_the_difference_game.dart` |
| 6 | LOW | Custom "every N weeks" recurrence computed "weeks" as consecutive 7-day blocks from the series' start date, not calendar weeks — could misclassify a weekday landing in the *next* real calendar week as part of the *current* bucket, producing uneven gaps and wrong inclusion/exclusion for interval > 1. | Added `_mondayOf(date)` and rebucket by the Monday-aligned calendar week for both `day` and `start` before computing `weekIndex`, so "every 2 weeks on Mon, Wed" now lands both weekdays in the same real calendar week consistently, regardless of which weekday the series started on. | `lib/models/task_recurrence.dart`, `_isOccurrence`'s weeks branch |
| 7 | LOW-MEDIUM | `String role = userData['role'];` — an unchecked cast; a user doc missing `role` threw a raw `TypeError` (caught by the outer generic `catch`, but shown to the user as a raw technical error string) instead of failing gracefully. | Changed to `final String? role = userData['role'] as String?;` with an explicit null check that shows a clear "your account is missing a role — contact support" message and returns, instead of routing on a cast that could throw. Deliberately does **not** silently default to a role, since guessing wrong would misroute a real caregiver/patient. | `lib/screens/auth/login_screen.dart` |

`flutter analyze` clean (no new issues) and `flutter build apk --debug`
succeeded after all three.

---

## 2. Codebase cleanup items (`CODEBASE_CLEANUP.md`) — small items now fixed, two large refactors still deferred

Items 1–4 (dead file removal, file/variable naming, try/catch wrapping)
were executed earlier this session. The two large, explicitly-deferred
refactors are **still deferred, on purpose** — see below. Every smaller
"analysis only" item from the same report is now fixed:

- ✅ **`AuthService`'s 3 methods unified.** `registerUser`/`loginUser`/`logout`
  each used to fail differently (nullable string / rethrow / bool). All 3
  now return a shared `AuthResult<T>` (`.success`/`.data`/`.error`), and
  none of them throw — every caller (`register_screen.dart`,
  `login_screen.dart`, `side_drawer.dart`'s logout) checks `.success` the
  same way. `lib/services/auth_service.dart`.
- ✅ **`currentUser!.uid` force-unwraps guarded.** Was in 5 screens
  (`game_statistic_screen`, `create_task_screen`, `activity_progress_screen`,
  caregiver `task_history_screen`, `add_patient_screen`) plus
  `patient_performance_screen` (added after the original report, same
  pattern). Added a shared `requireSessionUid(context)` helper
  (`lib/widgets/session_guard.dart`) — returns null instead of crashing on
  a missing session, schedules a redirect to `/login`, and the screen shows
  a brief `SessionRedirectPlaceholder` for the one frame in between. All 6
  screens now use it.
- ✅ **Ungated `print()` calls gated.** `auth_service.dart` (7, including a
  raw UID) and `login_screen.dart` now wrap every `print()` in
  `if (kDebugMode)`, matching `notification_service.dart`'s existing
  pattern.
- ✅ **`pubspec.yaml` dependency check done.** `confetti`, `audioplayers`,
  `webview_flutter`, `table_calendar` — each confirmed genuinely imported
  by exactly one file. Nothing unused; nothing removed.

`flutter analyze` (full project) — 0 errors, 53 pre-existing info/warning
lints, none new. `flutter build apk --debug` succeeded.

**Still deferred, on purpose — these are the two CODEBASE_CLEANUP.md
explicitly called "substantial, behavior-touching refactors" needing their
own focused session, plus two related items in the same category:**

- **Extract a shared lifecycle base class for the 13 game files** — every
  game duplicates the same `_uid`/`_level`/`_config`/`_loadingLevel`/
  `_difficultyService` fields, `_loadLevelAndStart()`, hint-counting
  pattern, and `_finishGame()` shape. Largest duplication surface in the
  codebase, and the highest-value refactor available — but it means
  changing the control flow of all 13 already-working game files at once,
  and I have no way to interactively play through each one afterward to
  catch a subtle regression. Not attempted this pass either.
- **Split `FirestoreService` (384 lines, 28 call sites) and
  `side_drawer.dart` (668 lines, 6 classes in one file)** into smaller,
  single-responsibility files/classes. Lower risk than the above, but still
  a design change touching what every caller imports — not attempted.
- `create_task_screen.dart`'s `build()` is ~415 lines; `home_screen.dart`
  and `patient_dashboard.dart` duplicate most of their task-rendering logic
  (`_visibleDocs`/`_toggleTaskStatus`/the per-occurrence tally). Neither
  attempted — both are core, frequently-used screens where a slip would be
  visible immediately to every caregiver/patient.

My honest read: these four are pure code-organization refactors with no
functional bug attached, on files this app depends on constantly. I can
verify a mechanical fix compiles and builds, but not that a sweeping
control-flow change across 13 gameplay screens or two dashboards behaves
identically on-device — I have no way to click through the app myself in
this environment. Given that, and that these were already flagged as
needing their own dedicated, individually-verified session, I've left them
alone rather than rushing a change I can't fully verify. Say the word if
you'd like me to tackle one of these specifically — happy to take them one
at a time rather than all at once, so each can be checked in isolation.

---

## 3. Notification system — low-priority items (`NOTIFICATION_BUGS.md`)

From an earlier Phase 3 pass. #1–#3 (critical/high/medium) were already
fixed. Of #4–#7: **#4 and #6 are now fixed too**; #5 and #7 are
deliberately left as-is (not oversights — see why below).

- **#4 — ✅ fixed.** `ReminderPopup` used to fetch the occurrence's status
  once, on open, so a native notification action button (or another
  device) resolving the same occurrence while the popup was still open
  left it stale and still-tappable. It now subscribes live
  (`FirestoreService.getOccurrenceStatusStream` for recurring tasks, and a
  new `getTaskStatusStream` for non-recurring ones) via a
  `StreamSubscription` cancelled in `dispose()` — the footer flips to the
  "already resolved" acknowledgment the instant that happens, from
  whichever channel did it. `lib/widgets/reminder_popup.dart`,
  `lib/services/firestore_service.dart`.
- **#5 — left as-is, by design.** Dismissing a reminder popup via
  barrier-tap (no response) still cancels all further reminders for that
  occurrence for the rest of the session immediately. This was flagged as
  "confirm this is still the intended behavior," not a bug — changing it
  is a product decision (should an accidental outside-tap really go
  permanently silent?) that needs your call, not something to silently
  change. Let me know if you'd rather it re-prompt or snooze instead.
- **#6 — ✅ fixed.** The "closest occurrence" fallback (used when a
  notification tap or TaskDetailScreen needs to guess which occurrence of
  a recurring task a reminder was about) picked whichever occurrence was
  closest in *absolute* time — which could pick tomorrow's occurrence over
  today's already-overdue one late at night. Added a shared
  `closestRelevantOccurrence()` helper (`lib/models/task_recurrence.dart`)
  that now prefers the closest **already-due** occurrence, only falling
  back to a future one if none are due yet — used by both
  `NotificationService._showReminderPopupForTap` and
  `TaskDetailScreen._loadData`, which had duplicated the same buggy sort
  independently.
- **#7 — left as-is, not fixable in Dart.** When exact-alarm permission
  isn't granted, Android's own `inexactAllowWhileIdle` scheduling can
  batch/delay/reorder the follow-up reminder chain. This is an OS-level
  constraint on inexact alarms, not something the app's code controls —
  noted so it isn't mistaken for an app bug if observed on a real device
  with exact-alarm permission denied.

`flutter analyze` clean (no new issues beyond pre-existing ones) and
`flutter build apk --debug` succeeded after both fixes.

---

## 4. Design decisions flagged for your review, not yet explicitly confirmed (`ADAPTIVE_DIFFICULTY_PROGRESS.md`)

Not bugs or unfinished code — these shipped and work — but they were
unilateral judgment calls the report asked you to sign off on, and no
explicit confirmation has been given yet:

- **Every game's accuracy signal was redefined** from "items completed"
  (which is trivially always 1.0 under this app's errorless-learning
  design) to a real struggle signal — "correct on first attempt" or
  "correct taps ÷ total taps," depending on what each game already
  tracked. Called out as "the single biggest judgment call in this
  implementation."
- **"Inactivity" (risk indicator) = max(last game session, last login)**,
  since there's no dedicated "last seen" tracker.
- **Recurring-task occurrence lookback for the missed-tasks risk signal is
  capped at 7 days**, not full history.
- **Risk level is binary** (none/at-risk), not graded — no "2 of 3
  signals" amber state.

---

## 5. Pre-existing audit, partially superseded (`INCOMPLETE_WORK.md`)

This file predates the Adaptive Difficulty Engine and this session's
cleanup pass — some of its items are now **out of date** and listed here
only for completeness, cross-checked against what's actually true today:

**No longer accurate** (contradicted by work already done):
- "Auto-adjusting difficulty based on live performance — no adaptive/ML
  logic exists" → done (the entire Adaptive Difficulty Engine).
- "Per-game difficulty override — one tier applies to all games" → done
  (per-game override now lives in Game Statistics).
- The 6 empty/stub screen files it lists (`patient_status_screen.dart`,
  `CaregiverUI.dart`, `task_screen.dart`, `exercise_screen.dart`,
  `medicationScreen.dart`, `dashboard_card.dart`) → all confirmed gone
  (checked directly): the first 4 were named in the cleanup pass's own
  delete list; `exercise_screen.dart` isn't in that list but no longer
  exists on disk either, so it must have been removed separately at some
  point.
- "No caregiver-facing notification history" → a `notificationHistory`
  Firestore collection/index exists live and the current functional
  requirements list it as a real drawer item, so this appears to have been
  built in a phase this file predates.

**Not re-verified this session, still plausibly true** — treat these as
"needs a fresh look," not confirmed facts:
- `welcome_screen.dart` — a complete, working Login/Register landing
  screen with zero references anywhere (`main.dart` routes straight to
  `/login`). Deliberately left in place pending your call each time it's
  come up.
- Dead/no-op UI, re-checked directly against the current code: LoginScreen's
  "Forgot Password?" link still just shows a snackbar
  (`'Forgot Password tapped'`), no reset flow — confirmed still present.
  LoginScreen's "Remember me" checkbox — confirmed still present, not
  re-checked whether its value is read anywhere. HomeScreen's old
  "Start Cognitive Activities" dead card is **gone** — no `TODO` or that
  label exists in `home_screen.dart` anymore, so this one item is stale
  and no longer applicable. CreateTaskScreen's bottom-nav "Home" tab
  no-op — not re-checked this session.
- Explicitly-scoped-out features: Google Calendar / external calendar
  sync, push notifications via FCM (everything is local
  `flutter_local_notifications`), caregiver preview of both dementia-type
  game sets, recurring-task completions not counted in the "Today's
  Progress" X/Y tally.
- `HomeScreen`'s task query window only catches a recurring task if its
  own series-start date falls in the ±3-day window — an old recurring
  series can silently stop appearing on the caregiver's Home dashboard
  even on a day it still recurs. (Note: this is a different mechanism from
  the missed-status sweep bug already fixed this session — that fix
  addressed *status persistence*, not this *display query* gap.)
- No Firestore security rules file exists anywhere in this repo — can't
  confirm from code alone whether patients are actually restricted to
  their own data at the database level.
- Two items needing on-device verification, not resolvable by reading
  code: notification action buttons (Complete/Missed) while the app is
  fully closed; exact-alarm reliability across different Android OEM skins.

---

## 6. Documentation/report follow-ups (yours to action, not code)

From `functional_requirements.md`'s own "Consistency notes for your
report" section — still open, not something I can fix in code since it's
about your separate FYP report document, not the app:

1. If your target-user/objectives section still says "early (mild) stage
   only," it needs updating — 6 of 13 games are middle-stage-specific, and
   the game set now depends on dementia type as well as stage.
2. If your report describes registration as letting a user "choose"
   patient vs. caregiver, that's out of date — self-registration only ever
   creates a caregiver account.
3. If any other section (system design, screenshots, a "personalization"
   write-up) still describes difficulty as a single caregiver-set
   Foundations/Standard/Challenge tier, it needs updating to describe the
   automatic per-game engine instead.
