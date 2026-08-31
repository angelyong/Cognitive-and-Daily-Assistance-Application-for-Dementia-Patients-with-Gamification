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

## 2. Codebase cleanup items explicitly deferred (`CODEBASE_CLEANUP.md`)

Items 1–4 (dead file removal, file/variable naming, try/catch wrapping)
were executed and committed. Items 5–6 were deferred as "substantial,
behavior-touching refactors" needing their own focused session:

- **Extract a shared lifecycle base class for the 13 game files** — every
  game duplicates the same `_uid`/`_level`/`_config`/`_loadingLevel`/
  `_difficultyService` fields, `_loadLevelAndStart()`, hint-counting
  pattern, and `_finishGame()` shape. Largest duplication surface in the
  codebase; not attempted.
- **Split `FirestoreService` (384 lines, 28 call sites) and `side_drawer.dart`
  (668 lines, 6 classes in one file)** into smaller, single-responsibility
  files/classes. Design changes, not mechanical — not attempted.

Smaller items flagged as "analysis only, not acted on" in the same report
and still true:
- `AuthService`'s 3 methods (`registerUser`/`loginUser`/`logout`) each fail
  differently (nullable string / rethrow / bool) — no unified error
  contract.
- `currentUser!.uid` unguarded force-unwraps remain in 5 screens
  (`game_statistic_screen` [was `statistics_screen`], `create_task_screen`,
  `activity_progress_screen`, caregiver `task_history_screen`,
  `add_patient_screen`) — each crashes on construction with no signed-in
  user.
- Ungated `print()` calls remain in `auth_service.dart` (7, including a raw
  UID) and `login_screen.dart` — `notification_service.dart`'s
  `kDebugMode`-gated pattern was never extended to these two.
- `create_task_screen.dart`'s `build()` is ~415 lines; `home_screen.dart`
  and `patient_dashboard.dart` duplicate most of their task-rendering logic
  (`_visibleDocs`/`_toggleTaskStatus`/the per-occurrence tally). Neither
  attempted.
- `pubspec.yaml`'s `confetti`/`audioplayers`/`webview_flutter`/
  `table_calendar` dependencies were never individually verified as still
  used.

---

## 3. Notification system — still-open low-priority items (`NOTIFICATION_BUGS.md`)

From an earlier Phase 3 pass. #1–#3 (critical/high/medium) are fixed; #4–#7
are still open, all explicitly logged as low priority:

- **#4** — `ReminderPopup`, once open, has no live subscription to the
  occurrence's status — if a native notification action button resolves
  the same occurrence while the in-app popup is still open, the popup sits
  there stale until the patient taps it directly.
- **#5** — Dismissing a reminder popup via barrier-tap (no response)
  cancels all further reminders for that occurrence, for the rest of the
  session, immediately — flagged as "confirm this is still the intended
  behavior," not obviously a bug.
- **#6** — For a task that's both recurring and has a legacy single-shot
  `reminderAt` set, the "closest occurrence" fallback can pick a future
  occurrence over a more relevant already-due one late at night.
  Pre-existing behavior, not a regression.
- **#7** — Inexact-alarm fallback (when exact-alarm permission isn't
  granted) can bunch or reorder the 5-minute follow-up chain. Platform
  constraint, not fixable in Dart.

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
