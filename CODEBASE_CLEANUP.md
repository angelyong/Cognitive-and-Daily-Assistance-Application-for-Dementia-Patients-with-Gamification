# MindCare Codebase Cleanup & Structure Review

Full audit of `lib/` (66 Dart files, ~19,400 lines) as of 2026-08-23. Every finding below was verified by reading the actual file or cross-referencing imports project-wide — nothing here is guessed. Nothing has been deleted or changed; this is a report for you to act on selectively.

## 1. Files that can be removed

Verified by searching every `.dart` file under `lib/` and `test/` for an import referencing each candidate's filename — these 10 have **zero** references anywhere, and reading each confirms why:

| File | What it actually contains |
|---|---|
| `lib/screens/caregiver/CaregiverUI.dart` | 1 line, empty. |
| `lib/screens/caregiver/patient_status_screen.dart` | 1 line, empty. |
| `lib/screens/patient/medicationScreen.dart` | 1 line, empty. |
| `lib/widgets/dashboard_card.dart` | 1 line, empty. |
| `lib/screens/patient/task_screen.dart` | 1 line: `//Task UI`. A placeholder that was never filled in. |
| `lib/models/medication_model.dart` | 1 line, empty. Consistent with medication inventory being on hold. |
| `lib/models/task_model.dart` | A real `TaskModel` class, but the rest of the app reads/writes raw `Map<String, dynamic>` for tasks everywhere (see `task_recurrence.dart`'s own comment: "the app already reads raw Firestore maps everywhere, this mirrors that rather than fighting it"). Never constructed anywhere. |
| `lib/models/user_model.dart` | Same story as `task_model.dart` — a real `UserModel` with `fromMap`/`toMap`, but every screen reads the raw user doc map directly instead. Never constructed anywhere. |
| `lib/widgets/task_card.dart` | **Not a stub** — a fully-built, well-documented `TaskCard` + `MedicationCard` pair (245 lines) referencing "UC-05 step 7" and "PatientDashboard". This was superseded by `widgets/timeline_card.dart`'s `TimelineCard` when Daily Tasks and Medication Schedule were merged into one timeline (see `HomeScreen.dart`'s file-level comment) — the old widget was never deleted after the replacement. |
| `lib/screens/welcome_screen.dart` | A real, fully-built Login/Register landing screen — but `main.dart`'s `initialRoute` is `/login` directly, and nothing navigates here. Possibly intentionally bypassed rather than dead; worth a quick "do we still want this?" before deleting. |

**Also:** `test/widget_test.dart` is the default Flutter counter-app template (asserts tapping a `+` icon increments a counter shown as `'0'`/`'1'`) — MindCare has no such screen, so this test doesn't exercise anything real and would fail if run. Either replace it with a real smoke test (e.g. "app launches to the login screen") or remove it.

**Not flagged, but worth a mention:** `pubspec.yaml` lists `confetti`, `audioplayers`, `webview_flutter`, `table_calendar` as dependencies — these weren't part of anything I read this session (games/statistics/risk work), so I can't confirm they're all still used. Worth a `flutter pub deps` / manual grep pass if you want to trim `pubspec.yaml` too.

## 2. File naming consistency

Dart convention is `lower_case_with_underscores.dart` — `flutter analyze` already flags every violation as a `file_names` info. 7 files break it, all in `screens/`:

- `screens/HomeScreen.dart` → `home_screen.dart`
- `screens/caregiver/CaregiverUI.dart` (dead anyway, see above)
- `screens/caregiver/StatisticsScreen.dart` → `statistics_screen.dart`
- `screens/caregiver/TaskHistoryScreen.dart` → `task_history_screen.dart` (**note:** `screens/patient/task_history_screen.dart` already uses this exact name for the patient-side equivalent — renaming the caregiver one to match would make two same-named files in different folders, which is fine in Dart but worth being deliberate about)
- `screens/caregiver/ActivityProgressScreen.dart` → `activity_progress_screen.dart`
- `screens/caregiver/createTaskScreen.dart` → `create_task_screen.dart`
- `widgets/SideDrawer.dart` → `side_drawer.dart`

Renaming is mechanical but touches every importer — e.g. `HomeScreen.dart` is imported by `main.dart` plus every screen that navigates to `/homescreen`. Low risk, just needs doing as one deliberate pass rather than piecemeal (a half-renamed codebase is worse than a consistently-named-wrong one).

## 3. Variable naming consistency

The same `FirestoreService()` instance is named **3 different ways** across the codebase:
- `_firestoreService` — the majority (all 13 game files, `HomeScreen`, `StatisticsScreen`, `edit_patient_screen`, `SideDrawer` ×2, `reminder_popup`)
- `_firestore` — 5 files (`task_detail_screen`, `ActivityProgressScreen`, `TaskHistoryScreen`, `patient/task_history_screen`, `createTaskScreen`)
- `firestoreService` (no underscore — it's a local variable, not a field) — `patient_list_screen.dart`

None of this is wrong, just inconsistent — pick one (`_firestoreService` already has the plurality) and it becomes a 5-file find-and-replace.

Separately: `FirestoreService` itself is instantiated fresh (`= FirestoreService()`) everywhere it's used, rather than following the singleton `factory` pattern the three newer services (`AdaptiveDifficultyService`, `RiskService`, `NotificationService`) all use. Harmless today since `FirestoreService` holds no per-instance state, but worth converting for consistency if you touch this file again.

## 4. Class / file responsibility

- **`FirestoreService` (384 lines) is a God class.** It mixes five unrelated concerns in one file: task CRUD, per-occurrence status, patient-caregiver linking, gamification points, and difficulty-tier reads. Nothing is broken by this, but it means "how do I do X with tasks" and "how do I do X with points" both send you to the same enormous class. If you have time, splitting into `TaskRepository`, `PatientRepository`, and folding points into `StreakService` (which already owns `streakPoints` semantics) would give each class one job.
- **`SideDrawer.dart` (668 lines) is actually 6 classes in one file**: `SideDrawer`, `_PatientDrawerBody`/`_PatientDrawerBodyState`, `_CaregiverDrawerBody`/`_CaregiverDrawerBodyState`, `_DrawerHeader`. That's a reasonable set of responsibilities (one drawer, two role variants, one shared header) but they'd read much more easily as 3 files (`side_drawer.dart`, `patient_drawer_body.dart`, `caregiver_drawer_body.dart`) than one 668-line file where you have to scroll past the patient variant to find the caregiver one.
- **`AuthService` has 3 different error-handling contracts across its 3 methods** (see §5 — same class, three different ways of telling the caller something went wrong).

## 5. Error handling gaps

- **`AuthService`'s 3 methods each fail differently**: `registerUser` catches `FirebaseAuthException` and returns `e.message` as a nullable string (null = success); `loginUser` catches, logs, and `rethrow`s; `logout` catches and returns a `bool`. A caller has to know, per-method, which of 3 contracts applies. Worth standardizing on one pattern (I'd suggest: always throw, let the UI's own try/catch decide what to show — that's what `loginUser` already does).
- **`currentUser!.uid` (unguarded force-unwrap) appears in 5 screens**: `StatisticsScreen`, `createTaskScreen`, `ActivityProgressScreen`, `TaskHistoryScreen` (caregiver), `add_patient_screen`. Each of these crashes immediately on screen construction if reached with no signed-in user, instead of redirecting to `/login`. Low probability given normal navigation, but a landmine if that assumption is ever wrong (e.g. a session token expiring while the screen is still mounted).
- **Ungated `print()` calls** (flagged by `flutter analyze` as `avoid_print`, 20 instances total) are concentrated in `auth_service.dart` (7, including printing a raw UID to the console) and `login_screen.dart`. Contrast with `notification_service.dart`, which wraps nearly all of its prints in `if (kDebugMode)` — that's the pattern worth extending to the other two.
- **None of the 13 game files wrap their Firestore calls in try/catch.** Every `_finishGame()` calls `AdaptiveDifficultyService.recordSessionAndAdapt(...)` and `FirestoreService.awardPoints(...)` unguarded — if either throws (permission error, a network blip mid-game), the patient is left on a frozen screen with no completion dialog and no explanation. **This is on me** — I wrote or touched all 13 of these files this session and didn't add error handling to any of them, since the adaptive-difficulty prompt didn't ask for it and I was focused on the difficulty logic itself. Worth a follow-up pass wrapping `_finishGame()`'s body in try/catch with a friendly "couldn't save your progress, check your connection" dialog, especially given these are dementia patients who won't know to retry on their own.

## 6. Complexity hotspots

By line count, the largest files are `createTaskScreen.dart` (975), `HomeScreen.dart` (927), `patient_dashboard.dart` (841), `StatisticsScreen.dart` (827), `notification_service.dart` (781), `SideDrawer.dart` (668). Not all of these need fixing — here's which do and why:

- **The 13 game files under `screens/patient/games/` share a near-identical skeleton** — I know this precisely because I wrote/extended all 13 this session: every file has `_uid`/`_level`/`_config`/`_loadingLevel`/`_difficultyService` fields, a `_loadLevelAndStart()` that reads difficulty state then calls a per-file `_setUpGame()`/`_setUpRound()`, a "count a hint only on the transition into hint-active state" pattern, a `_finishGame()` that calls `recordSessionAndAdapt` and reassigns `_level`/`_config` from the result, and a "Level $_level of 3" label plus a loading `Scaffold`. This is the single largest duplication surface in the codebase (13 files × ~300-560 lines each, a large fraction of it structurally identical). **This is the highest-value refactor available**: extracting a shared base (e.g. an `AdaptiveGameState<T extends StatefulWidget>` mixin or abstract class owning the level-loading lifecycle and hint-counting helper) would cut a few hundred duplicated lines and mean any future fix to the adaptive-difficulty wiring only needs to happen once, not 13 times.
- **`HomeScreen.dart` and `patient_dashboard.dart` duplicate most of their task-rendering logic** — both independently implement `_visibleDocs`/`_toggleTaskStatus`/the recursive per-occurrence `StreamBuilder` tally, per `HomeScreen.dart`'s own comments ("see PatientDashboard's identical method"). This is a smaller, second duplication surface — a shared `TaskTimelineController` or similar extracted into one file both screens use would remove the "keep two copies in sync by hand" risk that's already visible in the comments referencing each other.
- **`createTaskScreen.dart`'s `build()` method is ~415 lines** (title, category, dosage, due date/time, recurrence type, weekday picker, custom interval, end-date, reminder interval, patient picker, description, buttons, all inline). The complexity here is partly inherent to the feature (it's a genuinely large form), but extracting sections like the recurrence block and the reminder-interval block into their own small widgets would make this file navigable without scrolling past 200 lines to find one field.
- **`notification_service.dart` (781 lines) is large but I'd leave it alone** — it's handling background isolates, a native MethodChannel bridge, and OS alarm scheduling, which is inherently intricate, and it's thoroughly documented with the reasoning behind every non-obvious decision. This is a case where the size reflects real complexity being managed carefully, not disorganization.

## 7. What's already good (worth keeping, not changing)

- The `enum` + `XExtension` pattern for anything Firestore-backed (`GameDifficultyTier`/`DementiaStage`/`DementiaType`/`RecurrenceType`/`RiskLevel`) is applied consistently everywhere it's needed — this is a genuinely good, repeatable convention.
- `theme/app_colors.dart` / `app_decorations.dart` / `app_text_styles.dart` cleanly separate color, decoration, and text-style concerns instead of one theme dumping-ground file.
- Doc comments throughout consistently explain *why* a decision was made (scope choices, bugfixes, deliberate simplifications) rather than *what* the code does — this is unusually good discipline for a codebase this size and is exactly what makes an audit like this possible to do accurately.

## Suggested priority order

If you want to tackle this incrementally rather than all at once:

1. **Delete the 10 dead files** (§1) — zero risk, they're unreferenced.
2. **Standardize the `FirestoreService` variable name** (§3) — 5-file mechanical fix.
3. **Wrap the 13 games' `_finishGame()` in try/catch** (§5) — small, high-value, and closes a gap I left open.
4. **Rename the 7 mis-cased files** (§2) — mechanical but touches many import sites; do it as one pass.
5. **Extract the shared game-lifecycle base class** (§6) — the biggest single improvement to long-term maintainability, but also the most work; good candidate for its own dedicated session.
6. **Split `SideDrawer.dart` and `FirestoreService`** (§4) — nice-to-have, lower urgency since nothing is currently broken by either.
