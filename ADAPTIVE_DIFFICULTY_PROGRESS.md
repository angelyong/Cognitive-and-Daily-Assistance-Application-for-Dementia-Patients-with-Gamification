# Adaptive Difficulty Engine & Risk Indicator — Deliverables Report

Status as of 2026-08-23. Executed from `adaptive_difficulty_and_risk_indicator_prompt.md`. **Both Part 1 and Part 2 are complete.**

## Files created

| File | Purpose |
|---|---|
| `lib/models/game_session.dart` | `GameSession` (one completed round/session) and `DifficultyState` (per-game level/source/frozen/version) models. |
| `lib/services/adaptive_difficulty_service.dart` | Singleton service: state read/watch, one-time tier migration, `recordSessionAndAdapt` (the transactional promote/demote write), caregiver override, resume-auto, session/history streams. |
| `lib/models/game_catalog.dart` | Static catalog of all 13 games (id/label/game-set) used to render the Statistics screen. |
| `lib/screens/caregiver/StatisticsScreen.dart` | New caregiver screen: per-game difficulty card (level, source, Frozen badge, override dialog, resume-auto button, expandable accuracy-trend chart) + a combined reverse-chronological audit history list. |

## Files changed

| File | Change |
|---|---|
| `lib/main.dart` | Added `/statistics` route. |
| `lib/widgets/SideDrawer.dart` | Added a "Statistics" nav item under the caregiver INSIGHTS section. |
| `pubspec.yaml` | Added `fl_chart: ^1.2.0`. |
| All 13 files under `lib/screens/patient/games/*.dart` | Wired to the engine — see per-game table below. |

## Exact state-machine thresholds (as implemented, `adaptive_difficulty_service.dart` `_decide()`)

Demotion is checked **before** promotion on every rule evaluation (err toward easier).

- **Demote** (level − 1, floor 1) if **either**:
  - the most recent session's accuracy < **0.50**, **or**
  - the last 2 consecutive sessions both have accuracy < **0.60**
- **Promote** (level + 1, cap 3) if:
  - the last **3** consecutive sessions were all played *at the current level*, **and**
  - all 3 have accuracy ≥ **0.80**, **and**
  - all 3 have `hintsUsed` ≤ **1**
- Otherwise: no change.

A session is only ever recorded for the level it was actually played at (`difficultyLevel` on `GameSession`), so a caregiver override that changes the level mid-stream can't be "promoted past" using sessions played at the old level — the promote rule explicitly checks `levelOf(s) == currentLevel` for all 3.

## `difficultyTier` migration approach

The old `GameDifficultyTier {foundations, standard, challenge}` was a single caregiver-set value on `users/{uid}.difficultyTier`, applied uniformly to whichever games read it. Only 4 games ever read it: `memory_matching`, `category_naming`, `name_face`, `prospective_memory`. For exactly those 4, `migrateInitialLevelIfAbsent()` runs once on first load and seeds `difficultyState/{gameId}` from the old tier (`foundations→1`, `standard→2`, `challenge→3`); it's a no-op if a state doc already exists. The old field itself is left untouched in Firestore (not deleted) — it's simply unused going forward. The other 9 games never had a tier concept, so they just default to level 1 (the engine's own default for "no state doc yet") with no migration step.

## Chart approach

`fl_chart` (`LineChart`) — first chart package in this project. Each per-game card in the Statistics screen has an expandable accuracy-trend view plotting the last 10 sessions' accuracy (0–100%) in chronological order.

## Transaction / concurrency design (for the FYP report)

The "last 3 sessions" lookup is a `.where()/.orderBy()` query, which Firestore transactions cannot run (transactions may only re-read document references they already hold) — so it happens once, outside the transaction, before it starts. The actual state change happens inside a single `runTransaction`: it re-reads the `difficultyState` doc fresh, computes the promote/demote decision from that fresh level, then writes the updated state and the `difficultyHistory` audit record in the same atomic commit. If two sessions for the same patient/game somehow finished at the same instant, Firestore's own transaction semantics abort and re-run the losing transaction's callback from scratch against the now-current document — so the retry recomputes its decision from live data rather than blindly reapplying a stale one, without needing a manually compared version field (the `version` counter is kept only as a visible audit trail, not as the concurrency mechanism itself).

## Per-game integration table

| Game | gameId | gameSet | Level axis |
|---|---|---|---|
| memory_matching_game.dart | `memory_matching` | ad_early | migrated from tier; pairCount |
| category_naming_game.dart | `category_naming` | ad_early | migrated from tier; rounds |
| name_face_game.dart | `name_face` | ad_middle | migrated from tier; pairCount |
| prospective_memory_game.dart | `prospective_memory` | ad_early | migrated from tier; single-event |
| picture_recognition_game.dart | `picture_recognition` | ad_middle | rounds + distractor count |
| familiar_sound_game.dart | `familiar_sound` | ad_middle | rounds + option count + hint threshold |
| sequencing_game.dart | `sequencing` | vad_early | hint threshold only (steps fixed — coherent routine) |
| letter_fluency_game.dart | `letter_fluency` | vad_early | round count + hint threshold |
| odd_one_out_game.dart | `odd_one_out` | vad_early | round count + hint threshold |
| sorting_game.dart | `sorting` | vad_middle | items-per-side (2/3/4) |
| guided_daily_steps_game.dart | `guided_daily_steps` | vad_middle | hint threshold (level 1 = always-glowing baseline; higher levels withdraw the constant cue) |
| spot_the_difference_game.dart | `spot_the_difference` | vad_middle | difference count (2/3/4) + hint threshold |
| word_picture_pairing_game.dart | `word_picture_pairing` | ad_early | rounds + option count + hint threshold |

## ⚠️ Design decision made unilaterally — flagging for your review

**Every game's accuracy signal was changed from "items completed" to a real struggle signal**, because this app's errorless-learning design means every round/pair/word eventually succeeds by construction — so "items completed ÷ total items" is **always 1.0** on every normal playthrough. Left as originally written, that would make the promote rule fire almost immediately for every patient (since 1.0 ≥ 0.80 is trivially always true) and make the demote rule nearly unreachable except via a hard timeout — defeating the entire point of the engine. Fixed consistently in every game using one of two signals depending on what the game already tracked:
- **"correct on first attempt"** (games that already had this concept: `name_face`, `familiar_sound`, `word_picture_pairing`, `picture_recognition`), or
- **"total taps made (correct + wrong) vs. correct taps"** (every other game).

This is a deviation from a literal "items completed" reading and wasn't explicitly spelled out in the prompt, so please review it — it's the single biggest judgment call in this implementation.

## Part 1 `flutter analyze` / build result

**0 errors.** 77 pre-existing `info`/`warning`-level lint items unrelated to this work. `flutter build apk --debug` succeeded.

---

# Part 2 — Patient Risk Indicator

You approved this with the "build it + add a demo-seed tool" option after reviewing the design note below (kept for the record):

> ⚠️ **DESIGN NOTE** (flagged before writing any Part 2 code, per the prompt's own instruction): the rule requires all three signals — 3 consecutive missed task occurrences, ≥20% cognitive-score drop (last 5 vs. previous 5 sessions, needs ≥10 sessions total), and ≥3 days inactivity — **simultaneously**. That's a strict conjunction and hard to trigger organically in a live demo, since "≥3 days inactivity" is in tension with having 10+ *recent* sessions to compute a score drop from (resolved by backdating all 10 seeded sessions so the most recent is still ≥3 days old — see the seed tool below).

## Files created

| File | Purpose |
|---|---|
| `lib/models/risk_assessment.dart` | `RiskLevel` enum (`none`/`atRisk`, Firestore string extension mirroring `GameDifficultyTier`'s pattern), `RiskSignals` (the 3 booleans + supporting stats for the breakdown dialog), `RiskAssessment` (cached read model). |
| `lib/services/risk_service.dart` | Singleton service: `evaluateAndCache` (the 3-signal computation + transactional cache write + conditional `riskHistory` audit write), `getAssessment`/`watchAssessment`/`watchHistory`, `seedDemoRiskData` (the debug demo tool). |
| `lib/widgets/risk_badge.dart` | `RiskBadge` (the red pill), `PatientRiskBadge` (trigger-evaluation-once-then-watch wrapper, used everywhere the badge appears), `showRiskBreakdownDialog` (the tap-to-see-breakdown dialog, also used for the "no risk" case). |

## Files changed

| File | Change |
|---|---|
| `lib/theme/app_colors.dart` | Added `AppColors.riskRed` — a stronger, more saturated red than the existing `typeVascular` soft coral, so the badge reads as urgent rather than blending in with the dementia-type chips. |
| `lib/widgets/patient_card.dart` | Added optional `patientId` — when set, renders `PatientRiskBadge` next to the name. |
| `lib/screens/caregiver/patient_list_screen.dart` | Passes `patientId: doc.id` into `PatientCard`. |
| `lib/screens/HomeScreen.dart` | Renders `PatientRiskBadge` next to each patient's name in the per-patient group heading (skipped for the synthetic "Unassigned" group). |
| `lib/screens/caregiver/StatisticsScreen.dart` | New "Risk Status" section (current badge + tap-to-breakdown + debug seed button) and "Risk Change History" section, both right below the patient selector. |

Patient-facing screens (`PatientDashboard`, patient task history, etc.) were **not touched at all** — verified with a repo-wide search confirming no file under `lib/screens/patient/` references any risk code.

## The 3 signals, exactly as implemented (`risk_service.dart`)

1. **Missed tasks**: the patient's most recent 3 task occurrences (merging one-off tasks' own `status` field with recurring tasks' per-date occurrence subcollection docs, both passed through the existing `effectiveStatus()` helper) are **all** `'missed'`. Recurring-task occurrences are only expanded over the **last 7 days** — a bounded-scope decision (documented in code) rather than an unbounded per-task history scan.
2. **Score drop**: from the same `gameSessions` collection Part 1 writes to (queried by `patientId` only, across **all** games — this is about overall cognitive trend, not one game). Needs **≥10** total sessions; then average accuracy of the most recent 5 vs. the previous 5, signal fires at **≥20%** relative drop.
3. **Inactivity**: **≥3 days** since the more recent of the patient's last game session and their last recorded app login (`StreakData`'s existing `lastLoginDate` field). A patient with no recorded activity at all trivially counts as inactive.

`RiskLevel.atRisk` = all 3 booleans true at once. Cached on `users/{patientId}` as `currentRiskLevel`/`riskEvaluatedAt`/`riskSignals`; a `riskHistory` doc is written only when the cached level actually **changes** (transition-only audit trail, same shape as Part 1's `difficultyHistory`), inside the same transaction as the cache write so they can't happen one without the other.

## Evaluation trigger (no backend in this app)

There's no server/scheduler, and "3 days of inactivity" by definition has no write to hook. So `evaluateAndCache` runs once whenever a caregiver-facing screen showing the badge is opened (`PatientRiskBadge.initState`, and `StatisticsScreen`'s risk card on patient switch) rather than being wired into every task/game call site. Reads are cheap and bounded, so re-evaluating on every dashboard open is fine at this app's scale — flagged in `risk_service.dart`'s class doc comment as a design decision a larger deployment would want to rate-limit using the cached `riskEvaluatedAt` instead.

## Demo-seed tool (`RiskService.seedDemoRiskData`, debug-only)

Exposed as a **"Seed Demo Risk Data (Debug)"** button on `StatisticsScreen`'s Risk Status card, gated by `kDebugMode` (invisible in a release build). For the currently-selected patient it fabricates, with deterministic/idempotent doc IDs:
- 3 backdated one-off tasks with `status: 'missed'` (3, 4, 5 days ago).
- 10 backdated `gameSessions` docs — oldest 5 at 90% accuracy, most recent 5 at 50% (a 44% drop, well past the 20% threshold) — using a sentinel `gameId: 'demo_seed_risk'` that **isn't** in `kGameCatalog`, so seeded sessions never appear on any real game's difficulty card and never factor into a real difficulty promote/demote decision (Part 1's engine scopes its "last 3 sessions" query by `gameId`). All 10 are backdated ≥3 days, so this same data satisfies the inactivity signal too instead of contradicting it.
- Backdates `lastLoginDate` to 5 days ago so it doesn't override the inactivity picture.

It then calls the real `evaluateAndCache` — the demo exercises the actual evaluation logic, not a hardcoded badge. **Caveat worth knowing:** because it writes directly to `gameSessions`, re-running it is safe (same doc IDs overwrite), but the fabricated docs persist in Firestore until manually deleted.

## Part 2 `flutter analyze` / build result

**0 errors.** Full-project run after both parts: 78 issues total (77 pre-existing + 1 new `withOpacity` info in `risk_badge.dart`, same deprecation pattern already present everywhere else in the app). `flutter build apk --debug` succeeded.

## One new one-time Firestore setup step

`RiskService.watchHistory`'s query (`riskHistory` where `patientId ==` order by `evaluatedAt desc`) needs a composite index on that new collection, same as `difficultyHistory` needed in Part 1 — Firestore will prompt with a direct console link the first time this query runs against your project if it isn't already provisioned.

## Design decisions made unilaterally — flagging for your review

Same spirit as Part 1's trivial-accuracy disclosure — these weren't spelled out in the original prompt and are worth a second look:
- **"Inactivity" = max(last game session, last login)**, since the app has no dedicated "last seen" tracker. A patient who only ever completes tasks (never plays a game, never re-opens the app) could show as inactive sooner than feels right — reasonable given the data available, but worth knowing.
- **Recurring-task occurrence lookback capped at 7 days** for the missed-tasks signal, not full history — chosen to keep evaluation bounded and fast; a task recurring less often than every ~7 days could under-count its recent occurrences.
- **Risk level is binary** (`none`/`atRisk`), not a graded score — matches the prompt's strict-AND framing directly, but means there's no "2 of 3 signals" amber warning state.
