# MindCare — Hidden Bug Analysis

Analysis of `lib/` as of 2026-08-23. Every finding below was verified by tracing the actual code paths involved — not pattern-matched or guessed. Nothing has been changed; this is a report only. Ordered most to least impactful.

## 1. [HIGH] The caregiver's "Cognitive Game Difficulty" control in Edit Patient silently does nothing anymore

**File:** `lib/screens/caregiver/edit_patient_screen.dart` (the "Cognitive Game Difficulty" section, `_setTier`/`_loadTier`)

This screen still shows a Foundations/Standard/Challenge picker, with the caption "Applies to all of this patient's cognitive games — memory matching, category naming, and more." Both the caption and the control are now **stale** — this is left over from before the Adaptive Difficulty Engine (Part 1) shipped this session, and nothing wires it up anymore:

- 9 of the 13 games (`picture_recognition`, `familiar_sound`, `sequencing`, `letter_fluency`, `odd_one_out`, `sorting`, `guided_daily_steps`, `spot_the_difference`, `word_picture_pairing`) **never read `GameDifficultyTier` at all** — they've always defaulted to their own per-game level 1 and adapted independently.
- The other 4 (`memory_matching`, `category_naming`, `name_face`, `prospective_memory`) read `GameDifficultyTier` on every load, but only *act* on it via `AdaptiveDifficultyService.migrateInitialLevelIfAbsent`, which is a one-time, no-op-after-the-first-call migration:
  ```dart
  Future<void> migrateInitialLevelIfAbsent(...) async {
    final doc = await ref.get();
    if (doc.exists) return;   // <-- every call after the first does nothing
    await ref.set({...});
  }
  ```
  Once a patient has played any of these 4 games even once since Part 1 shipped, their `difficultyState` doc exists — and every future read of `GameDifficultyTier` is fetched, passed to `migrateInitialLevelIfAbsent`, and silently discarded.

**Failure scenario:** a caregiver opens Edit Patient, taps "Foundations" to make games easier for a struggling patient, sees no error and presumably a save confirmation, and reasonably believes it worked. It has **no effect whatsoever** on any of the 13 games for any patient who has played even one game since this session's changes shipped. The caregiver has no way to know their action was a no-op — there's no error, no warning, nothing. The *actual* per-game control now lives in the new Statistics screen (Override/Resume Auto), which this screen doesn't mention or link to.

**Fix direction:** either remove this section from Edit Patient entirely (with a note pointing to Statistics for per-game control), or have it read/display the new per-game `DifficultyState` instead of the retired `GameDifficultyTier`.

## 2. [HIGH] The daily login streak effectively never advances for a patient who doesn't fully close the app

**Files:** `lib/services/streak_service.dart`, `lib/services/auth_service.dart`, `lib/screens/auth/login_screen.dart`, `lib/screens/patient/patient_dashboard.dart`, `lib/main.dart`

`StreakService.checkAndUpdateStreak` — the only place that increments the daily streak — is called from exactly one place in the entire app: `AuthService.loginUser`, which is itself called from exactly one place: `LoginScreen._signIn()`. Traced every other candidate call site to confirm this:

- `main.dart`'s startup code only calls `NotificationService().reconcilePatientReminders(uid)` for an already-signed-in user — no streak check.
- `PatientDashboard.initState()` only calls `_loadUserName()` and `reconcilePatientReminders` — no streak check.
- `LoginScreen` has no `initState`/session-check logic that would auto-skip the form for an already-authenticated user — but that cuts the other way: it means the *only* way `checkAndUpdateStreak` ever runs is by physically typing credentials into the login form and pressing "Sign In."

Firebase Auth sessions persist by default (this app never calls `signOut()` except via the explicit logout action), and mobile OSes overwhelmingly *resume* an already-running app rather than restarting its Dart VM from `main()` when reopened from the home screen or recent-apps. In that (extremely common) case, the app just resumes wherever it left off — typically `PatientDashboard` — and `_signIn()` never runs again.

**Failure scenario:** a patient opens MindCare once, logs in, and then simply taps the app icon each day without ever force-closing it. Their streak silently never advances past day 1, since nothing re-checks the day boundary outside the login form. This directly undermines the app's core engagement/gamification mechanic for exactly the population (dementia patients) least likely to think to "log out and back in."

**Fix direction:** call `StreakService().checkAndUpdateStreak(uid)` from `PatientDashboard.initState()` too (it's already idempotent — safe to call more than once per day, see finding below), not just from the login flow.

## 3. [MEDIUM] Bundling `awardPoints` and `recordSessionAndAdapt` in one try/catch means a points failure silently skips the difficulty/risk engines too — and drops the session record entirely

**Files:** all 13 files under `lib/screens/patient/games/*.dart`, in `_finishGame()` (introduced by this session's try/catch fix)

Every game's error-handling now looks like:
```dart
if (uid != null) {
  try {
    if (pointsEarned > 0) {
      await _firestoreService.awardPoints(uid, pointsEarned);
    }
    if (_sessionStart != null) {
      _level = await _difficultyService.recordSessionAndAdapt(...);   // never reached if awardPoints throws
      _config = ...;
    }
  } catch (e) { /* SnackBar */ }
}
```
Because both calls share one try block, if `awardPoints` throws (a transient permission/network blip), `recordSessionAndAdapt` is **never attempted at all** — and since `recordSessionAndAdapt` is what writes the `gameSessions` doc in the first place, that round's session record is silently lost, not just its difficulty evaluation. This session record also feeds `RiskService`'s score-drop signal (Part 2), so a single flaky points-award call can quietly erase a data point from both the difficulty engine and the risk indicator for that round.

This isn't strictly *new* behavior — before this session's fix, a thrown exception here would have crashed `_finishGame()` outright, which also skipped `recordSessionAndAdapt`. What's new is that it now fails quietly (a SnackBar, then the game still shows its completion dialog) instead of loudly, which paradoxically makes the silent data loss easier to miss.

**Fix direction:** wrap the two calls independently (or reorder so `recordSessionAndAdapt` — which feeds two other systems — runs first and is unaffected by whether `awardPoints` succeeds).

## 4. [LOW-MEDIUM] HomeScreen and PatientDashboard disagree on which overdue tasks get auto-flipped to "missed"

**Files:** `lib/screens/home_screen.dart` (`_persistMissedStatus(visibleDocs)`) vs. `lib/screens/patient/patient_dashboard.dart` (`_persistMissedStatus(allDocs...)`)

HomeScreen only runs its missed-status sweep over `visibleDocs` — today's tasks plus the ±3-day grace window (`FirestoreService.homeWindowDays`). PatientDashboard runs the identical sweep over **every task the patient has, unbounded**. Both are internally correct, but they disagree with each other: a single (non-recurring) task from, say, 3 weeks ago that was never addressed stays "pending" forever in the caregiver's HomeScreen sweep (it's outside the 3-day window, so HomeScreen never even looks at it), but the very next time the *patient* opens their own dashboard, that same task gets flipped to "missed" — meaning the caregiver's and patient's stored data for the same task can silently diverge depending on which screen last touched it.

**Fix direction:** either bound PatientDashboard's sweep to a similar window, or widen/remove HomeScreen's window — whichever matches the intended "how far back do we still bother auto-resolving" policy.

for this above, this is what i want:
HomeScreen should display today's tasks only. Do not use FirestoreService.homeWindowDays or any ±3-day grace window for the HomeScreen's missed-status logic.

The missed-status sweep should not be limited to visibleDocs, because visibleDocs exists only to determine which tasks are displayed on HomeScreen. Instead, the missed-status sweep should run over every task the patient has, consistent with PatientDashboard.

Both HomeScreen and PatientDashboard should use the same missed-status rules so that the stored status of a task cannot diverge depending on which screen the user opens.

For example, if a non-recurring task from 3 weeks ago was never addressed, opening HomeScreen should still detect that overdue task and change its status from pending to missed, even though the task is not displayed on HomeScreen.

Most importantly, missed must be a permanent terminal status. Once a task is changed to missed, its status must never be changed back to pending, completed, skipped, or any other status by either HomeScreen, PatientDashboard, or any subsequent status sweep.

The intended rules are:

HomeScreen displays today's tasks only.
visibleDocs is used only for HomeScreen display purposes.
Missed-status sweeps operate on all tasks belonging to the patient, without a ±3-day limit.
Only unresolved/pending overdue tasks can transition to missed.
Once a task becomes missed, it is immutable and permanently remains missed.
Existing terminal statuses such as completed or skipped must not be overwritten by the missed-status sweep.
HomeScreen and PatientDashboard must use the same logic for determining and persisting missed status.
Remove the ±3-day FirestoreService.homeWindowDays dependency from the missed-status sweep; it should not be used to determine whether an old task becomes missed.

The goal is to ensure that the same task always has the same persisted status regardless of whether the caregiver opens HomeScreen or the patient opens PatientDashboard.

## 5. [LOW] A future difficulty level above 3 differences would crash Spot the Difference

**File:** `lib/screens/patient/games/spot_the_difference_game.dart`

```dart
static const List<int> _diffOrder = [0, 4, 1, 2];
...
final List<int> diffIndices = _diffOrder.sublist(0, _config.differenceCount);
```
`_diffOrder` has exactly 4 entries. `_LevelConfig.forLevel` currently maxes out at `differenceCount: 4` (level 3), so this is safe today. But it's a landmine: if anyone ever adds a level 4 (or otherwise raises `differenceCount` past 4) without also extending `_diffOrder`, `sublist(0, 5)` on a 4-element list throws a `RangeError` immediately on `_setUpGame()`, crashing the game on load. Not currently reachable, but worth a defensive `assert` or a comment tying `_diffOrder`'s length to the maximum possible `differenceCount`.

## 6. [LOW] Custom "every N weeks" recurrence with multiple weekdays can produce unevenly-spaced occurrences

**File:** `lib/models/task_recurrence.dart`, `_isOccurrence`'s `RecurrenceUnit.weeks` branch

```dart
final int weekIndex = day.difference(start).inDays ~/ 7;
return weekIndex % series.rule.interval == 0;
```
"Weeks" are computed as consecutive 7-day blocks counted from the series' exact start date, not calendar weeks (Mon–Sun). If a caregiver picks a start date of, say, a Wednesday with weekday selection `[Monday, Wednesday]`, the two selected days land in the same "week bucket" 5 days apart, then only 2 days apart to reach the next bucket's Wednesday — an uneven gap pattern that could look like a scheduling error to a caregiver, even though the underlying math is internally consistent. Likely an acceptable, if undocumented, edge case rather than a strict bug — only manifests for `custom` + `weeks` + multiple selected weekdays, a fairly rare combination.

## 7. [LOW] Unchecked cast on a possibly-missing `role` field

**File:** `lib/screens/auth/login_screen.dart:242`

```dart
String role = userData['role'];
```
`userData` is `Map<String, dynamic>?`, so `userData['role']` is `dynamic`. If a user document were ever missing its `role` field (e.g., an account created by hand in the Firestore console, or a future migration gap), this throws `type 'Null' is not a subtype of type 'String'` at runtime instead of failing gracefully. Every other read of a Firestore field in this codebase uses `(data['x'] ?? default) as T` — this is the one place that doesn't.

## What I checked and ruled out (no bug found)

To be transparent about the sweep, not just the hits — these looked suspicious at first glance but traced out as correct or provably benign:

- **`AdaptiveDifficultyService.recordSessionAndAdapt`'s promote/demote transaction** — re-read carefully for races between a caregiver override and a patient mid-round; the `frozen` check and fresh in-transaction read of `state.level` handle this correctly.
- **`NotificationService.reconcilePatientReminders`/`_showReminderPopupForTap`** using raw (non-`effectiveStatus`-adjusted) stored status for overdue tasks — looked like it could re-schedule reminders for an already-effectively-missed task, but `scheduleOccurrenceChain`'s own "skip any slot not in the future" check means nothing ever actually gets scheduled in that case. Benign.
- **`RiskService._evaluateScoreDrop`'s sublist ranges and the `gameSessions` write-then-immediately-query sequence** — correct given Firestore's consistency guarantees for sequential awaited operations.
- **`PatientAccountService`'s secondary Firebase app reuse** — correctly signs out of the secondary instance after each patient creation, safe to call repeatedly.
