# Adaptive Difficulty Engine — Concept & Flow

## 1. The problem it solves

Before this engine, every cognitive game in MindCare used one shared setting — `GameDifficultyTier` (Foundations / Standard / Challenge) — that a caregiver picked once for a patient, applied identically to *every* game, and had to manually revisit if the patient got better or started struggling. It never responded to how the patient was actually doing.

This is also the direct answer to an examiner's "the app lacks complexity" feedback. Static CRUD (a caregiver types a value, it gets saved, it gets displayed back) is shallow. **Deep CRUD** means a write triggers business logic, data is interlinked across collections, state changes follow rules instead of just being whatever was last typed, and every change leaves an audit trail. The adaptive engine is exactly that: finishing a game round doesn't just save a score — it can trigger a promotion, a demotion, or nothing, decided by a rule the system enforces, with a permanent record of why.

## 2. The core idea

Each **(patient, game)** pair has its own independent difficulty level from 1 (easiest) to 3 (hardest). After every round, the engine looks at that specific game's recent performance and decides whether to leave the level alone, raise it, or lower it — automatically, with no caregiver involvement required. A caregiver can still override a specific game's level by hand when they know something the numbers don't (and freeze it there), but that's now the exception path, not the only path.

This design follows two pieces of literature cited directly in the code:
- **Bouchard, Imbeault, Bouzouane & Menelas (2012)**, *SGDA*, LNCS 7528 — the case for dynamic difficulty adjustment in serious games for Alzheimer's patients, adjusting from the player's own performance rather than a fixed setting.
- **Ortega Morán et al. (2024)**, *JMIR Aging* 7:e41437 — parameterising difficulty through concrete knobs (item count, time allowance, hint strength/frequency) rather than a single vague "hard/easy" toggle.

Every game's own `_LevelConfig`/`_TierConfig` class is that second idea in code — level 1/2/3 map to concrete parameter changes (how many rounds, how many options, how many misses before a hint appears), not just a label.

## 3. Why "accuracy" needed a second look

Every game in MindCare is deliberately **errorless-learning**: the patient is never allowed to fail outright — wrong taps get gentle correction and eventually the round finishes successfully no matter what. That's the right design for dementia patients, but it creates a trap: if "accuracy" is measured as *items completed ÷ total items*, it is **always 1.0**, because errorless design guarantees every round eventually completes. Difficulty would ratchet up almost immediately for everyone and could almost never come back down.

Every game was built (or fixed) to use a real struggle signal instead:
- **Correct on the first attempt** — for games that already tracked this (e.g. name-face recognition, word-picture pairing).
- **Total taps made (correct + wrong) vs. correct taps** — for everything else, so a round full of wrong guesses before eventually succeeding scores low, even though it still "completed."

This is the single most important, least obvious design decision in the whole engine — without it, the promote/demote rules below would be evaluating a number that never actually reflects how the patient did.

## 4. Data model

Three Firestore locations work together:

| Location | Purpose |
|---|---|
| `gameSessions/{sessionId}` | One immutable record per finished round: which game, which level it was played at, accuracy, hints used, duration. `sessionId` is client-generated and deterministic (`uid_gameId_startTimeMillis`), so an accidental double-submit overwrites the same doc instead of creating a duplicate. |
| `users/{patientId}/difficultyState/{gameId}` | The current, live state for one game: `level` (1–3), `source` (`'auto'` or `'caregiver'`), `frozen` (true once a caregiver has overridden it), `version` (an audit counter), `updatedAt`. |
| `difficultyHistory/{autoId}` | One record per level *change* (not per session) — old level, new level, why, and who/what caused it. This is the audit trail a caregiver reads in Statistics. |

`GameSession.accuracy` is a getter (`correctItems / totalItems`, zero-guarded), not a stored field — it's always derived from the same two numbers the promote/demote rule reads, so there's no way for a displayed accuracy to drift from the number actually driving the decision.

## 5. The promote/demote rule

Evaluated fresh after every single round, for that specific game only:

- **Demote** (level − 1, floor 1) if *either*:
  - the most recent session's accuracy is below **50%**, or
  - the last **2** sessions both have accuracy below **60%**.
- **Promote** (level + 1, cap 3) if:
  - the last **3** sessions were all played *at the current level* (a session from before a caregiver override doesn't count toward promotion at the new level), **and**
  - all 3 have accuracy of **80%+**, **and**
  - all 3 used **1 or fewer hints**.
- Otherwise: no change.

Demotion is checked first, deliberately — for a dementia-focused app, the safer failure mode is "too easy" rather than "too hard."

## 6. End-to-end flow, start to finish

```mermaid
sequenceDiagram
    participant P as Patient (game screen)
    participant G as Game widget
    participant S as AdaptiveDifficultyService
    participant DB as Firestore

    P->>G: opens a cognitive game
    G->>S: getState(patientId, gameId)
    S->>DB: read difficultyState/{gameId}
    DB-->>S: level (defaults to 1 if no doc yet)
    S-->>G: current level
    Note over G: level 1/2/3 → _LevelConfig<br/>(round count, option count, hint threshold, etc.)
    G-->>P: round is played at that level's parameters

    P->>G: finishes the round
    G->>S: recordSessionAndAdapt(sessionId, accuracy inputs, hints, level played at)
    S->>DB: write gameSessions/{sessionId} (immutable record)
    S->>DB: query last 3 sessions for (patientId, gameId) — OUTSIDE any transaction
    DB-->>S: recent sessions, newest first

    rect rgb(245, 245, 245)
    Note over S,DB: single Firestore transaction
    S->>DB: read difficultyState/{gameId} fresh
    alt state.frozen == true
        S-->>S: no auto-change — caregiver override is in effect
    else not frozen
        S-->>S: apply promote/demote rule using the fresh level + recent sessions
        opt level actually changes
            S->>DB: write new difficultyState (level, source='auto', version+1)
            S->>DB: write difficultyHistory record (from, to, reason, stats)
        end
    end
    end

    S-->>G: resulting level (old or new)
    G-->>P: "Level N of 3" label updates; Play Again uses the new level immediately
```

Step by step, in words:

1. **Game opens.** It calls `getState` to find out what level this patient is at for *this specific game* — every other game has its own independent level. A patient with no state doc yet for this game defaults to level 1. (The 4 games that previously used the old `GameDifficultyTier` also run a one-time `migrateInitialLevelIfAbsent` here — if this is truly the first time this game has ever recorded a level for this patient, their old caregiver-set tier is used to seed the starting level; every call after that first one is a no-op.)
2. **Level → parameters.** Each game's own `_LevelConfig.forLevel(level)` turns the number into concrete settings — how many rounds, how many distractor options, how many wrong taps are allowed before a hint appears. This is where Ortega Morán et al.'s "parameterise, don't just label" idea lives.
3. **The round is played.** The game tracks the real struggle signal (first-attempt-correct, or taps made vs. correct) as it goes, plus how many hints were actually shown (counted once per *transition* into a hint appearing, not once per subsequent wrong tap while it's already showing).
4. **Round finishes → `recordSessionAndAdapt` is called**, with the session's numbers and which level it was played at.
5. **The session is written first**, unconditionally — this is the permanent record, and it's what feeds the Statistics accuracy-trend chart and the Patient Risk Indicator's score-drop signal.
6. **The last 3 sessions for this (patient, game) pair are queried** — this has to happen *outside* any transaction, because Firestore transactions can only re-read document references they already hold, not run a fresh `.where()/.orderBy()` query.
7. **A single transaction then does the actual decision**: re-read the current `difficultyState` fresh (so it reflects anything that happened since step 1), check if it's frozen (caregiver override in effect — if so, stop here), otherwise apply the promote/demote rule using that fresh level. If the level changes, the new state *and* the audit-history record are written together, in the same transaction, so a level change and its audit record can never happen one without the other.
8. **The resulting level is returned** to the game, which immediately updates its own `_level`/`_config` — so if the patient taps "Play Again" right away, the very next round already reflects the promotion or demotion that just happened.

## 7. Why this is safe under concurrency (no manual version-checking needed)

If two sessions for the same patient and game somehow finished at the same instant (e.g. two devices, or a race between an auto-write and a caregiver override), Firestore's own transaction semantics — not a manually compared `version` field — handle it: a transaction that reads a document and later finds it changed before it commits is automatically aborted and re-run from the top. Because the promote/demote decision is computed entirely from data read *inside* the transaction body, a retry re-evaluates against whatever is actually current, rather than blindly reapplying a decision made against stale data. The `version` counter that gets incremented on every write is kept purely as a visible audit trail for humans reading the history — it isn't what makes this safe.

## 8. The caregiver override path

From the Statistics screen, a caregiver can pick any specific game for any specific patient and set its level directly. Two things are required and enforced together, inside one transaction:
- A **non-empty reason** — the UI won't let the dialog submit without one, and the service throws if it somehow arrives empty anyway.
- The state is written with `source: 'caregiver'` and `frozen: true` — freezing stops the automatic promote/demote rule from touching this game for this patient until the caregiver explicitly taps **Resume Auto**, which unfreezes without changing whatever level it's currently sitting at.

Every override and every resume also writes its own `difficultyHistory` record, so the same audit trail that shows automatic promotions/demotions also shows exactly when and why a human stepped in.

## 9. What the caregiver actually sees (Statistics screen)

For a selected patient, one card per game shows: the current level (as filled dots, 1–3), whether it's `Auto` or caregiver-set, a `Frozen` badge if an override is active, an **Override** button, a **Resume Auto** button (only when frozen), and an expandable accuracy-trend line chart (`fl_chart`) built from that game's last 10 `gameSessions`. Below all the game cards, one combined, newest-first history list renders every `difficultyHistory` record in plain language — e.g. *"auto — 3 sessions ≥80% accuracy & ≤1 hint"* or *"caregiver: 'patient frustrated this week'"* — so the reasoning behind every change is always visible, not just the fact that a change happened.
