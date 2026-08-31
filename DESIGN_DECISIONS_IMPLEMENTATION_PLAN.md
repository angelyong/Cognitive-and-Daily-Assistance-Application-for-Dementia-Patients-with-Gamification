# Implementation Plan — Reviewer-Approved Design Decisions + Adaptive-Engine Hardening

> **Status: all five items executed and committed** (★ `b90fef5`, #4 `d3d8de2`,
> #3 `59d8344`, #2 `c2c34bd`, #1 `a6d5a99`). `flutter analyze` 0 errors,
> `flutter build apk --debug` succeeded, 11 unit tests pass. For ★ the
> lower-risk (a)+(b) pair was implemented (idempotent `adaptationApplied`
> flag + level-aware demotion) rather than the heavier (a)+(c) buffer — it
> fully closes the cascade bug with far less change to core gameplay logic
> I can't click-test here. The rest below is the original plan, kept as the
> design record.

This supersedes the recommendations in `DESIGN_DECISIONS_REVIEW_PLAN.md`
with the reviewer's actual sign-off. Every claim below was re-verified
against the current code (file:line references throughout). Nothing here is
implemented yet — this is the "how to build it" plan.

**Reviewer verdicts:**

| # | Item | Verdict |
|---|---|---|
| 1 | Accuracy signal | Approve **with caveat** — keep struggle-based, don't compare raw accuracy across different games |
| 2 | Inactivity | **Improve** — add a dedicated `lastActiveAt` timestamp |
| 3 | Seven-day lookback | **Replace** — compute the previous 3 due occurrences directly, per recurrence rule |
| 4 | Binary risk | **Enhance** — add amber "monitor" at 2/3, keep red at 3/3 |
| ★ | Adaptive engine (newly raised) | **Fix before sign-off** — idempotent + level-aware adaptation |

Suggested order of work (safest/highest-value first): **★ → #4 → #3 → #2 →
#1**. The engine fix (★) is a correctness bug; the rest are enhancements.

---

## ★ Adaptive-engine hardening (the newly-raised, most serious issue)

### The bug, precisely

Two independent gaps in
[adaptive_difficulty_service.dart](lib/services/adaptive_difficulty_service.dart)
combine into a real defect:

1. **Demotion doesn't check the session's level.** `_decide`'s promote
   branch requires `levelOf(s) == currentLevel` for all 3 sessions
   ([line 228](lib/services/adaptive_difficulty_service.dart#L228)), but the
   demote branch checks only `accuracy`
   ([lines 202-223](lib/services/adaptive_difficulty_service.dart#L202-L223))
   — it never confirms the triggering session(s) were actually played at
   the current level.
2. **Adaptation re-runs on a repeated call.** The stable `sessionId` makes
   the session-doc *write* idempotent (`.set()` overwrites,
   [line 128](lib/services/adaptive_difficulty_service.dart#L128)), but the
   surrounding query + `_decide` + state write run again in full every time
   `recordSessionAndAdapt` is called — nothing records that a given session
   was already adapted on.

**Concrete failure trace.** Patient at level 3 finishes one weak session
(accuracy 0.40, `difficultyLevel: 3`):
- Call 1: fresh state level 3, `lastAccuracy 0.40 < 0.50` → demote **3→2**.
- Same `_finishGame` fires again (double-tap on finish, a retry after the
  "couldn't save" SnackBar, or the completion-callback firing twice):
- Call 2: session doc overwritten (same data); recent query still returns
  that same session (its stored `difficultyLevel` is still 3); transaction
  reads fresh state **level 2**; `_decide(2, …)` sees `0.40 < 0.50` again →
  demote **2→1**.

One bad session, played once at level 3, drops the patient two levels. Even
without a duplicate call, gap #1 alone means sessions played at level 3 can
keep counting toward demotion after the level has already dropped, because
the recent-sessions list isn't filtered by level.

### Fix — four coordinated changes (reviewer's list)

All four are cheap and localized to `adaptive_difficulty_service.dart` plus
one field on the `difficultyState` doc. No game files need to change.

**(a) `adaptationApplied` flag on the individual game-session document
(NOT `lastAdaptedSessionId` on the state doc).**
Make adaptation idempotent *per session*. The flag must live on the
**session doc**, not on the state doc, because a single
`lastAdaptedSessionId` only remembers the *most recent* adapted session —
it stops an immediate double-tap, but not an older session being reprocessed
after a newer one has finished:

> Trace of why state-doc tracking is insufficient: session A adapts →
> `lastAdaptedSessionId = A`; session B adapts → `= B`; now a delayed retry
> / replayed offline write / late callback for **A** re-enters. The guard
> checks `lastAdaptedSessionId (B) == A` → false → **A adapts a second
> time.** A per-session flag can't be fooled this way — A's own doc records
> that A was already applied, forever.

Read and set the flag **inside the existing transaction** so the check and
the state change commit atomically. The session doc is a specific document
reference (we already hold its `sessionId`), so a Firestore transaction is
allowed to read it:

```dart
final sessionRef = _db.collection('gameSessions').doc(sessionId);
await _db.runTransaction((tx) async {
  final sessionSnap = await tx.get(sessionRef);          // all reads first
  final stateSnap = await tx.get(docRef);
  final DifficultyState state = DifficultyState.fromMap(stateSnap.data());
  resultLevel = state.level;

  if (sessionSnap.data()?['adaptationApplied'] == true) return; // already applied
  if (state.frozen) {                                    // record attempt, no change
    tx.set(sessionRef, {'adaptationApplied': true}, SetOptions(merge: true));
    return;
  }
  // ...decide; on any outcome (change or no-change) mark the session applied:
  tx.set(sessionRef, {'adaptationApplied': true}, SetOptions(merge: true));
  // ...write new level + history only if the decision changed the level
});
```

Note the ordering rule: **all `tx.get` calls must precede any `tx.set`** in
a Firestore transaction, so read the session doc and the state doc up front.
Mark `adaptationApplied: true` on *every* processed session (even
no-change and frozen ones), so a replay of a session that produced "no
change" doesn't get a second chance to change something after the level has
since moved.

**(b) Current-level validation for demotion.** Mirror the promote branch:
only count a session toward demotion if it was played at the current level.
In `_decide`, guard each demotion check with `levelOf(recentDesc[0]) ==
currentLevel` (and the same for the 2nd session in the "last 2 below 60"
rule). A session played at level 3 then can't demote level 2.

**(c) Transactionally-maintained recent-result buffer (the robust option).**
Rather than the `.where().orderBy().limit(3)` query outside the transaction
([lines 130-136](lib/services/adaptive_difficulty_service.dart#L130-L136)),
keep a small rolling buffer of the last 3 results *on the state doc*
(`recentResults: [{level, accuracy, hints}, …]`), updated inside the
transaction, and **cleared on every promote/demote**. This solves (b) for
free — after a level change the buffer is empty, so no stale
old-level session can trigger a further change — and removes the
outside-the-transaction read entirely, making the whole operation
self-contained and atomic. This is the strongest fix; (b) is the minimal
one if you'd rather not add a buffer.

> Recommendation: do **(a) + (c)** together — the buffer subsumes (b), and
> the pair makes adaptation both idempotent and level-correct with one
> coherent mechanism. If time is tight, **(a) + (b)** alone already closes
> the cascade bug.

**(d) Keep the existing transaction + `version` audit counter** as-is —
they're already correct; these changes slot into that structure.

### Verification
Because this is core gameplay logic, verify deliberately: seed a level-3
patient with one 0.40 session, confirm it lands at level 2 and a **second**
`recordSessionAndAdapt` with the same sessionId is a no-op; confirm a
level-3 session can't demote after the level is already 2; confirm normal
promote (3 clean sessions at the current level) still works.

---

## #4 — Three-state risk (none / monitor / at-risk)

### Approved states
- **none** — 0 or 1 signal true.
- **monitor** — exactly 2 signals true → amber, "Needs Attention".
- **atRisk** — all 3 signals true → red, "At Risk" (unchanged).

This keeps the original strict-AND red alert intact and only *adds* an
earlier, softer tier — so it can't weaken the existing behavior, it can
only surface the currently-invisible 2/3 case
([risk_badge.dart:20](lib/widgets/risk_badge.dart#L20) hides everything
below red today).

### Touch points
- [risk_assessment.dart](lib/models/risk_assessment.dart): add `monitor` to
  the `RiskLevel` enum; extend `RiskLevelX.fromFirestore`/`firestoreValue`
  for a new `'monitor'` string (keep `'none'`/`'at_risk'` exactly as-is for
  backward-compat). Add a helper on `RiskSignals`, e.g. `int get metCount`
  and `RiskLevel get level` (`3 → atRisk`, `2 → monitor`, else `none`).
- [risk_service.dart:81](lib/services/risk_service.dart#L81): replace
  `signals.allThree ? atRisk : none` with the 3-way mapping. The transition
  audit write ([lines 98-106](lib/services/risk_service.dart#L98-L106))
  already fires on any level change, so none→monitor and monitor→atRisk get
  logged for free.
- [risk_badge.dart](lib/widgets/risk_badge.dart): render amber for
  `monitor` (new `AppColors` amber, or reuse `orangeEnd`), red for `atRisk`,
  nothing for `none`. Update the breakdown dialog copy so the header/intro
  reflects "2 of 3 → monitor, 3 of 3 → at risk."
- Also update the risk card + copy on
  [game_statistic_screen.dart](lib/screens/caregiver/game_statistic_screen.dart)'s
  Risk Status section, which has its own at-risk styling.

### Watch out for
Anywhere that currently treats risk as a boolean (`level == atRisk`). Grep
for `RiskLevel.atRisk` and decide per site whether "monitor" should also
count (e.g. a filter/sort that surfaces flagged patients probably wants
both). Verify the badge in all three states on every screen that shows it
(patient list, home, game-statistic), plus the breakdown dialog and the
history trail.

---

## #3 — Recurrence-aware "previous 3 occurrences" (replaces the 7-day window)

### Why 30 days isn't enough
The reviewer is right that widening `_occurrenceLookbackDays`
([risk_service.dart:121](lib/services/risk_service.dart#L121)) from 7 to 30
only moves the boundary:
- 3 **monthly** misses need ~60–90 days.
- **Yearly** / long custom recurrences remain undetectable at any fixed
  window.
- A wider window on a **daily** task reads far more occurrence docs than the
  3 it actually needs.

### Approach — compute previous dates directly from each recurrence rule
Add to [task_recurrence.dart](lib/models/task_recurrence.dart) a helper
that returns the last N due occurrence dates by **arithmetic per recurrence
type**, not by scanning a calendar window:

```dart
/// The [count] most recent occurrence dates on/before [asOf], computed
/// directly from the series' recurrence rule — works identically for daily,
/// weekly, monthly, yearly, and custom, at any frequency, because it never
/// scans a fixed day-window. Fewer than [count] are returned if the series
/// hasn't occurred that many times since its startDate.
List<DateTime> previousOccurrences(TaskSeries series, DateTime asOf, {int count = 3});
```

**Do NOT day-scan backward with an iteration cap.** A 400-day (or any fixed)
cap cannot reach 3 *yearly* occurrences — those span ~730+ days back — and
stepping day-by-day across years to find 3 dates is wasteful. Instead
compute each previous date directly:

- **none:** the single `dueDate`, if it's on/before `asOf`.
- **daily:** `asOf`, `asOf − 1d`, `asOf − 2d`, … (stop at `startDate`).
- **weekly / custom-weeks:** walk back over the selected weekdays,
  respecting `interval` weeks — generate the most recent matching weekday
  ≤ `asOf`, then the next one back, etc. (bounded to `count` results, so at
  most a few weeks of stepping even for a single weekday).
- **monthly:** subtract whole months from the anchor day, reusing the
  existing `_clampedMonthDay` logic ([task_recurrence.dart:169](lib/models/task_recurrence.dart#L169))
  so e.g. the 31st clamps correctly in short months.
- **yearly:** subtract whole years from the anchor month/day (with the same
  Feb-29 clamp the current yearly branch already uses,
  [task_recurrence.dart:197-200](lib/models/task_recurrence.dart#L197-L200)).
- **custom days:** subtract `interval` days repeatedly.

Every branch also stops at `series.startDate` (and respects `endDate` — but
here `asOf` is "now", so endDate rarely bites). This is **inherently
bounded to `count` iterations** — no cap needed, and correct for yearly.

Cross-check: the result of `previousOccurrences` should always be a subset
of what `_isOccurrence` would accept, so keep a debug `assert` that each
returned date passes `_isOccurrence`, guarding against the two
implementations drifting.

Then in `risk_service.dart` the only Firestore reads are the ≤3
`occurrences/{dateKey}` status docs per series — cheaper than today's up-to-
a-week expansion, and now correct for every frequency.

### Touch points
- `risk_service.dart` `_evaluateMissedTasks`
  ([lines 123-172](lib/services/risk_service.dart#L123-L172)): drop
  `windowStart`/`_occurrenceLookbackDays`; for each recurring series call
  `previousOccurrences(series, now, count: 3)` and read those occurrence
  status docs; for non-recurring tasks keep the single-occurrence path.
  Merge across all tasks, sort by date desc, inspect the latest 3 — the
  existing "3 consecutive missed" logic stays.
- Consider reusing the same helper in
  [performance_analytics_service.dart](lib/services/performance_analytics_service.dart),
  which has its own `_taskLookbackDays = 90` window — out of scope for this
  fix, but note it so the two don't drift.

### Verification
A weekly task with the last 3 occurrences all missed should now trigger
signal 1; a daily task should read exactly 3 occurrence docs (not 7–30).

---

## #2 — `lastActiveAt` (replaces the max(session, login) proxy)

### Why the current proxy is weaker than it looks
`lastLoginDate` is stored as `_dateOnly(today)` — **midnight of the
calendar date**, not the real activity time
([streak_service.dart:61](lib/services/streak_service.dart#L61)) — and it's
only written on the first login of a day. So the inactivity signal
([risk_service.dart:229](lib/services/risk_service.dart#L229)) is already
coarser than "when did we last see them," and misses a patient who stays
logged in and only ever completes tasks.

### Approach — a dedicated `lastActiveAt` on `users/{patientId}`
- **Written (server timestamp) on genuine patient activity:** dashboard use
  (throttled — see below), a manual task response (Complete/Missed the
  patient taps), a notification response, and game completion.
- **NOT written for:** automatically-missed tasks (that's the *absence* of
  activity — writing it would mask the very thing the signal detects), or
  any caregiver action (a caregiver editing a task isn't the patient being
  active).
- **Server timestamp** (`FieldValue.serverTimestamp()`), not device time.
- **Throttle** the dashboard-open write — e.g. skip if `lastActiveAt` is
  already within the last N minutes — so a patient reopening the dashboard
  repeatedly doesn't hammer Firestore.
- **Keep `lastLoginDate` separate** and unchanged — the streak system still
  needs its calendar-date semantics.
- **Backward-compatible fallback:** for patients with no `lastActiveAt` yet
  (existing accounts), fall back to the current `max(last game session,
  last login)` computation, so the signal keeps working during rollout.

### Touch points
- A small helper (e.g. `FirestoreService.touchLastActive(patientId)` or a
  method on a dedicated activity service) that does the throttled
  server-timestamp write.
- Call sites: `patient_dashboard.dart` (init/resume, throttled), the
  patient task-response paths (`reminder_popup.dart`, timeline card toggle,
  notification action handler in `notification_service.dart`), and every
  game's `_finishGame` (or fold it into `recordSessionAndAdapt`, which every
  game already calls — one place instead of 13).
- `risk_service.dart` `_evaluateInactivity`: prefer `lastActiveAt` when
  present, else the existing proxy.

### Watch out for
Don't write `lastActiveAt` from caregiver-authenticated sessions — guard by
the signed-in role, or only call it from patient-only code paths. Folding
the game-completion write into `recordSessionAndAdapt` is the lowest-risk
way to cover all 13 games without editing each.

---

## #1 — Struggle-based accuracy: keep it, but stop cross-game raw averaging

### What's approved
Keep the struggle-based accuracy definition (it's necessary — errorless
learning makes literal completion always 100%; see
`DESIGN_DECISIONS_REVIEW_PLAN.md` §1). **Adaptive decisions already stay
per-game** — `_decide` runs on a single `gameId`'s sessions
([adaptive_difficulty_service.dart:130-136](lib/services/adaptive_difficulty_service.dart#L130-L136)),
so no change needed there.

### The caveat to address
"Accuracy" means different things per game — **first-attempt rate**
(`name_face`, `familiar_sound`, `word_picture_pairing`,
`picture_recognition`) vs. **tap efficiency** (everyone else). Yet the risk
score-drop signal averages `accuracy` **across all games**
([risk_service.dart:197-199](lib/services/risk_service.dart#L197-L199)):
`avgLast5` vs `avgPrev5` pools sessions from different games with
different metric meanings. A patient shifting which games they play could
swing that average with no real cognitive change.

### The score-drop formula (defined now, before implementation)
Replace the current "pool last-5 vs previous-5 across all games"
([risk_service.dart:197-199](lib/services/risk_service.dart#L197-L199)) with
a like-with-like, per-game formula:

1. **Group** the patient's sessions into comparable buckets keyed by
   **(gameId, difficultyLevel, metricVersion)** — only sessions that share
   all three are ever compared to each other. (`metricVersion` comes from
   the new session field defined in "Supporting field change" below; treat a
   missing field as version 0.)
2. **Per eligible bucket, compute one drop.** A bucket is *eligible* only if
   it has at least `K` recent + `K` previous sessions (start with **K = 3**,
   a parameter to confirm). For an eligible bucket:
   `drop = (avgPrev_K − avgLast_K) / avgPrev_K`, guarded for `avgPrev_K ≤ 0`
   exactly as the current code guards it
   ([risk_service.dart:201-210](lib/services/risk_service.dart#L201-L210)).
3. **Combine eligible buckets' drops with equal weight** — a plain mean of
   the per-bucket `drop` values, **not** weighted by session count (so a
   game the patient happens to play more often doesn't dominate the signal).
4. **Fire** the score-drop signal when that equal-weighted mean drop ≥ the
   threshold (keep **0.20**).
5. **Not-evaluable → no signal.** If *no* bucket is eligible (e.g. a
   recently-promoted patient whose sessions are split across two levels so
   neither level has `K + K` at one level yet), the signal is simply
   `false` with a "not enough comparable sessions" reason — the same spirit
   as today's `<10 sessions → false` guard, surfaced in the breakdown
   dialog so a caregiver understands *why* it's not firing rather than
   reading absence as "all clear."

> Trade-off to be aware of (why step 5 matters): requiring the **same
> difficulty level** is deliberately strict — it's what makes the
> comparison honest (a level-3 accuracy isn't comparable to the same
> patient's level-1 accuracy) — but it means a mid-window promotion
> temporarily makes the signal un-evaluable for that game until enough
> same-level sessions accumulate again. That's the correct, safe behavior
> (better silent than falsely comparing across levels), but it must be
> shown as "not evaluable", never as "no risk".
### Supporting field change
Add `metricType` and `metricVersion` to future `gameSession` records
(`GameSession.toMap`, [game_session.dart:38](lib/models/game_session.dart#L38)):
`metricType` = `'first_attempt'` | `'tap_efficiency'`, `metricVersion` = an
int bumped if the formula ever changes. This makes every stored session
self-describing, so the bucketing in step 1 above can group only truly
comparable sessions, and a future formula change won't silently mix old and
new numbers. Purely additive — old docs simply lack the fields and are
treated as `metricVersion` 0. Each game passes its own `metricType`
constant into `recordSessionAndAdapt` (the four first-attempt games vs. the
rest), which is the only per-game edit this item needs.

### Report caption
Still add the one-line "accuracy = struggle signal (first-try /
tap-efficiency), because errorless learning makes literal completion always
100%" note to the FYP report and the caregiver charts, as recommended in
`DESIGN_DECISIONS_REVIEW_PLAN.md` §1.

### Scope note
The `metricType`/`metricVersion` fields are forward-looking (they only
populate on new sessions; old data is version 0). The substantive change is
the score-drop rewrite, contained to `_evaluateScoreDrop` in
`risk_service.dart`. The only game-file edits are each game passing its
`metricType` constant into `recordSessionAndAdapt` — a one-line addition per
game, no gameplay-logic change. `GameSession`/`toMap` gains the two fields;
`recordSessionAndAdapt`'s signature gains a `metricType` parameter (with a
default so nothing breaks if a caller is missed during rollout).

---

## Suggested sequencing & verification discipline

1. **★ engine fix** — correctness bug; do first, verify with the seed/replay
   steps above.
2. **#4 amber tier** — self-contained, high report value, easy to verify
   visually in 3 states.
3. **#3 recurrence-aware occurrences** — new pure helper + one call site;
   unit-checkable with a few series shapes.
4. **#2 `lastActiveAt`** — most call sites touched; roll out with the
   fallback so nothing breaks mid-migration.
5. **#1 game-aware score-drop + metric fields** — do after #2/#3 since it
   also lives in `risk_service.dart`.

Each step: `flutter analyze` (0 errors) + `flutter build apk --debug`, and
for ★ and #4 an actual on-device/emulator check, since those change
behavior a caregiver or patient sees. Commit one step at a time so any one
can be reverted independently.
