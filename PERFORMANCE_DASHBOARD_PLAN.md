# Plan: Patient Performance Dashboard (new screen)

**Status: built.** Final decisions, superseding the "open decisions" list at the bottom: the new dashboard is `PatientPerformanceScreen` (`lib/screens/caregiver/patient_performance_screen.dart`, route `/statistics` — it's now what the drawer's "Statistics" item opens). The old per-game `StatisticsScreen` was renamed to `GameStatisticScreen` (`game_statistic_screen.dart`, route `/gamestatistic`), reached via a button from the new dashboard or from Edit Patient — not from the drawer directly anymore. KPI tiles: Average Accuracy, Sessions Played, Task Completion Rate, Average Hints per Session, plus a Streak/Points card. Second bar chart: Tasks by Category. Demo data uses the recommended middle-ground — real game IDs plus a "Clear Demo Data" button. `PerformanceAnalyticsService` (`lib/services/performance_analytics_service.dart`) and `PerformanceSnapshot` (`lib/models/performance_snapshot.dart`) hold the aggregation logic and data shape respectively.

The rest of this file is kept as the original design record.

## 1. What this screen is for, and how it differs from Statistics

The existing Statistics screen is **deep and per-game** — pick a patient, then drill into one game at a time (its level, its own accuracy trend, its own override controls). `[NewScreen]` is the opposite shape: a **bird's-eye, all-games-at-once dashboard** — the KPI-tile-plus-charts layout from your reference image, showing how a patient is doing *overall* at a glance, not game-by-game. They're complementary, not a replacement for each other.

Everything on it is computed from data that already exists in Firestore — no new collections, and nothing hardcoded. The two collections doing all the work are the same ones Part 1 and Part 2 already write to every day:

| Collection | Already written by | What it gives this screen |
|---|---|---|
| `gameSessions` | Every game's `recordSessionAndAdapt` call | accuracy, hints used, duration, which game, which game set, when |
| `tasks` (+ `occurrences` subcollection for recurring ones) | Task creation / completion | completed vs. missed counts, by category |
| `users/{patientId}` | Streak service, points awards | `streakPoints`, `currentStreak` |
| `difficultyHistory` | The adaptive engine | how many times this patient has been promoted/demoted (optional extra tile) |

## 2. Proposed mapping from your reference image

Your screenshot is a generic analytics template (Views/Visits/New Users/Active Users, a tabbed chart, two bar charts, a bottom bar). Here's a proposed mapping onto MindCare's actual data — treat this as a first draft, not a final answer:

### Top row — 4 KPI tiles, each with a period-over-period trend arrow
1. **Average Accuracy** — mean of `gameSessions.accuracy` in the selected period, vs. the previous period of equal length.
2. **Sessions Played** — count of `gameSessions` in the period, vs. previous period.
3. **Task Completion Rate** — completed ÷ (completed + missed) from `tasks`/occurrences in the period, vs. previous period.
4. **Avg. Hints per Session** — mean `hintsUsed`, vs. previous period (a *falling* trend is the good direction here, worth a different arrow color from the other three).

This needs a **period selector** (Last 7 days / Last 30 days / All time) somewhere near the top — the reference image doesn't show one explicitly, but the "12.5%" style trend numbers imply one exists; without picking a period, "vs. previous period" has no defined meaning.

### Middle — tabbed line chart (reference: Users / Incidents / Operating Status tabs)
Three tabs, same `fl_chart` `LineChart` widget already used in Statistics, but aggregated **across all games** instead of one game at a time, one point per day over the selected period:
- **Accuracy** — daily average accuracy.
- **Sessions** — daily session count.
- **Hints** — daily average hints used.

### First bar chart (reference: "Device Traffic")
Proposed: **Average Accuracy by Game** — one bar per cognitive game (up to 13), height = that game's average accuracy in the period. A game with zero sessions in the period just doesn't get a bar (or shows a greyed 0 — your call).

### Second bar chart (reference: "Location Traffic")
Proposed: **Tasks by Category** — one bar per task category (Medication, Exercise, Meal, Hygiene, Social, Appointment, Other — 7 categories, which matches the ~7 bars in your reference nicely), height = tasks completed in that category during the period. An alternative, if you'd rather keep everything cognitive-games-focused: **Sessions by Game Set** (AD-Early / AD-Middle / VaD-Early / VaD-Middle — only 4 bars, a sparser chart).

### Bottom bar
Your reference shows a generic home/back icon bar. MindCare's own caregiver screens don't use a bottom nav bar for anything except HomeScreen's Home/Activities pair — every other caregiver screen (including Statistics) just uses the standard `AppBar` with a drawer-menu icon and relies on the OS/app back button to leave. Recommendation: match that existing convention (AppBar + drawer, no new bottom bar) for consistency, unless you specifically want this screen to feel like its own separate mini-app.

## 3. Data queries needed

- `gameSessions` where `patientId == X` and `completedAt` within the selected period, **no `gameId` filter** (all games at once) — this is the same query shape `RiskService._evaluateScoreDrop` already runs (`where(patientId).orderBy(completedAt)`), so the Firestore composite index it needs is very likely already provisioned from Part 2; a date-range version of the same index should not require a new one, but Firestore will prompt with a direct console link the first time if it does.
- `tasks` where `patientId == X` (already exists as `FirestoreService.getTaskHistory`/`getTasksForPatient`) — for the completion-rate tile and the category bar chart, reuse the exact same "non-recurring status is a doc field, recurring status lives in the `occurrences` subcollection" handling `RiskService._evaluateMissedTasks` already implements, rather than writing a third version of that logic.
- `users/{patientId}` — a single doc read for `streakPoints`/`currentStreak` if you want those as an extra tile.

All aggregation (averages, per-day buckets, per-game/category grouping) happens **client-side** in Dart after these reads — the same pattern `RiskService` already uses, not a server-side aggregation feature.

## 4. Where the logic should live

Recommend a small new service — e.g. `PerformanceAnalyticsService` — that takes a `patientId` and a period and returns a plain data object (KPI numbers, per-day chart points, per-game bars, per-category bars). `[NewScreen]` then just renders whatever that object contains, the same "screen owns no logic" separation Statistics already has from `AdaptiveDifficultyService` (see `ADAPTIVE_DIFFICULTY_AND_STATISTICS_SCREEN.md`). Unlike `AdaptiveDifficultyService`, this new service has no state machine and no writes of its own (aside from the demo-seed tool below) — it's read-and-aggregate only, closer in shape to how `RiskService`'s signal calculations work than to the difficulty engine's transactional writes.

## 5. Navigation from the current Statistics screen

Add a button (an `AppBar` action icon, or a card near the top, your call) on `StatisticsScreen` — visible once a patient is selected — that opens `[NewScreen]` for that same patient, pre-selected. This mirrors the `initialPatientId` pattern already built for the Edit Patient → Statistics link, so the caregiver never has to re-pick the patient when moving between the two screens.

## 6. The "Send Demo Data" button — what it's actually for

This deserves its own explanation since it's easy to read as just "fake data for a screenshot," but the real reason is more specific:

**The problem it solves:** almost every chart on this dashboard is a *time series* — "accuracy per day over the last 30 days," "sessions per day." That kind of data cannot be generated organically in a short testing window, no matter how many times you play a game *today* — you'd need to actually use the app on 30 different real calendar days to see a real 30-day trend line. For a demo to an examiner, or just to check the screen looks right while building it, that's not practical.

**What it should do:** write a batch of **backdated** `gameSessions` (and optionally task completions) spread across the selected period, with varied accuracy/hints/games, so every tile and chart has enough realistic, non-trivial data to render meaningfully — the same idea as `RiskService.seedDemoRiskData` from Part 2, just producing a *spread* of data across many simulated days instead of a single specific 3-signal scenario.

**Why it must be debug-only:** exactly like the risk indicator's seed tool — gated behind `kDebugMode` so it's structurally impossible for it to appear in a release build or be tapped by an actual caregiver. It fabricates Firestore data; it must never be reachable in production.

**Why it should exercise the real code path, not a mock:** the seeded documents should be genuine `gameSessions`/task docs, read back through the exact same `PerformanceAnalyticsService` queries and aggregation a real patient's data would go through — so what you're demonstrating (to yourself while building it, or to an examiner later) is proof the *real* dashboard code works, not a separate fake-preview mode that could silently diverge from what real usage looks like.

**One real design decision this raises** (worth deciding before building, since it affects the adaptive difficulty engine from Part 1): should seeded sessions use the patient's **real game IDs**, or a sentinel/fake one?
- **Real game IDs** → the "Accuracy by Game" bar chart actually populates meaningfully. Downside: `AdaptiveDifficultyService`'s promote/demote rule looks at "the last 3 sessions" for a game *regardless of whether they're real or seeded* — so seeded sessions under a real game's ID could nudge that game's live difficulty level the next time the patient actually plays it, exactly the tradeoff Part 2's risk-seed tool avoided by using a sentinel `demo_seed_risk` ID instead.
- **Sentinel IDs** → completely inert to the difficulty engine, but then the by-game bar chart either shows a fake "Demo" pseudo-game (defeating the point) or has to filter seeded data out (meaning the seed tool wouldn't actually demonstrate that specific chart).
- **Recommended middle ground:** seed under real game IDs so every chart populates properly, but also add a **"Clear Demo Data"** button next to it that deletes exactly the docs the seed tool created (same deterministic-ID trick as the risk seeder, so they're easy to find and remove) — giving you a full demo when you want one, without permanently contaminating a game's real difficulty history afterward.

## 7. Open decisions for you to confirm before this gets built

- Final screen name and route.
- Whether the 4 KPI tiles above are the right ones, or you'd rather show different numbers.
- Task-category bars vs. game-set bars for the second chart.
- Whether to add the streak/points tile.
- Real game IDs + a "Clear Demo Data" button (recommended), vs. sentinel IDs only.
