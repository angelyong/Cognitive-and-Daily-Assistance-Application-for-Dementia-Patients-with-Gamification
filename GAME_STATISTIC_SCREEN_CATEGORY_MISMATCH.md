**Status: fixed.** See "Where a fix would go" below — that's exactly what
was implemented. Kept as a record of the root cause and the reasoning
behind the fix.

# Why Game Statistics shows games that don't belong to the patient's dementia type/stage

## The behavior

Open **Game Statistics**, select any patient, and the "Game Difficulty"
section lists **all 13 cognitive games** — Memory Matching, Category
Naming, Picture Match, Daily Routine, Color/Shape Sorting, all of them —
regardless of that patient's assigned dementia type and stage. A patient
who is Alzheimer's-Early (and can therefore only ever play 4 specific
games) still gets difficulty cards shown for Vascular-Middle games they've
never seen and never will.

## Root cause

Every cognitive game belongs to exactly one of 4 **game sets**, determined
by crossing dementia **type** (Alzheimer's / Vascular) with **stage**
(Early / Middle):

| | Alzheimer's | Vascular |
|---|---|---|
| **Early** | `ad_early` — Memory Matching, Category Naming, Remember This, Word & Picture | `vad_early` — Daily Routine, Letter Search, Odd One Out |
| **Middle** | `ad_middle` — Picture Match, Who Is This?, What Made That Sound? | `vad_middle` — Color/Shape Sorting, Guided Daily Steps, Spot the Difference |

A patient only ever sees, and can only ever play, the one game set
matching their own `dementiaType` + `dementiaStage`. This routing is real
and correctly enforced — but only in **one** place:

**`CognitiveExerciseScreen._gameCardsFor()`** (`lib/screens/patient/cognitive_exercise_screen.dart:234-244`)
reads the patient's own `dementiaType`/`dementiaStage` from Firestore and
explicitly branches:

```dart
if (type == DementiaType.alzheimers && stage == DementiaStage.early) {
  cards = _adEarlyCards();
} else if (type == DementiaType.alzheimers && stage == DementiaStage.middle) {
  cards = _adMiddleCards();
} else if (type == DementiaType.vascular && stage == DementiaStage.early) {
  cards = _vadEarlyCards();
} else {
  cards = _vadMiddleCards();
}
```

This is why the *patient's own* game hub correctly shows only their 3–4
relevant games.

**`GameStatisticScreen`** (`lib/screens/caregiver/game_statistic_screen.dart:176`),
by contrast, never reads the selected patient's type or stage at all. It
just loops over the entire shared catalog unconditionally:

```dart
for (final game in kGameCatalog) ...[
  _GameDifficultyCard(
    patientId: _selectedPatientId!,
    caregiverId: _caregiverId,
    game: game,
    ...
  ),
  ...
]
```

`kGameCatalog` (`lib/models/game_catalog.dart:15-33`) is the full,
unfiltered list of all 13 games across all 4 game sets — it's a shared
reference table, not something scoped to one patient. `GameStatisticScreen`
takes that list and renders a card for every entry, with no `gameSet`
filter applied against the selected patient's profile anywhere in the
file.

## Why this wasn't caught by the adaptive difficulty engine itself

It's not a data-integrity bug — a patient's `difficultyState` doc for a
game outside their own set simply never gets written to (they can never
play that game to generate one), so `_GameDifficultyCard` just renders the
untouched default: **Level 1, Auto, no sessions yet**. The card is inert,
not wrong — but it's still noise: a caregiver has to scroll past 9–10
cards that can never change for that patient to find the 3–4 that
actually matter, and nothing on screen explains *why* those extra cards
exist.

## The fix

`lib/models/game_catalog.dart` gained two small helpers:

```dart
String gameSetFor(DementiaType type, DementiaStage stage) { ... }   // same crossing as CognitiveExerciseScreen
List<GameCatalogEntry> gamesForSet(String gameSet) =>
    kGameCatalog.where((g) => g.gameSet == gameSet).toList();
```

`GameStatisticScreen` already fetches each patient's full Firestore doc for
the patient dropdown (`getPatientsForCaregiver`), so it already has
`dementiaType`/`dementiaStage` on hand — no extra read needed. A new
`_selectedPatientGameSet` getter derives the selected patient's game set
from those two fields, and the "Game Difficulty" loop now iterates
`gamesForSet(_selectedPatientGameSet)` instead of the full `kGameCatalog`.
Result: a caregiver viewing an Alzheimer's-Early patient now sees exactly
the 4 AD-Early cards, not all 13.

`PerformanceAnalyticsService`'s
`_accuracyByGame` (the dashboard's "Accuracy by Game" list) has the same
property — it also just iterates whatever games a patient *has* sessions
for, which happens to self-limit correctly since a patient can only ever
generate sessions for their own set, so that one isn't affected in
practice.
