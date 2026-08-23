# MindCare — Incomplete / Unfinished Work

A punch list of everything in the codebase that's **not done** — empty screens, orphaned files, dead UI elements, and explicitly deferred features. Companion to `APP_FUNCTIONALITY.md` (which documents what *is* working); this file is the mirror image of it.

---

## 1. Screens never actually built (empty stub files)

These files exist with a class declaration or a single comment and nothing else — no UI, no logic. Not reachable from anywhere in the app.

| File | Current content |
|---|---|
| `lib/screens/caregiver/patient_status_screen.dart` | Empty |
| `lib/screens/caregiver/CaregiverUI.dart` | Empty |
| `lib/screens/patient/task_screen.dart` | `//Task UI` only |
| `lib/screens/patient/exercise_screen.dart` | `// Exercise UI` only |
| `lib/screens/patient/medicationScreen.dart` | Empty |
| `lib/widgets/dashboard_card.dart` | Empty |

None of these are imported anywhere else in `lib/`. If any of them was meant to become a real screen, it hasn't been started yet — worth deciding whether to build them out or delete them as leftover scaffolding.

## 2. Built, but not wired into the app

| Item | State |
|---|---|
| `lib/screens/welcome_screen.dart` | A complete, working "MindCare" launcher screen (Login/Register buttons) — but `main.dart`'s `initialRoute` goes straight to `/login`, and no route or navigation anywhere points at it. Fully functional code that the app never actually shows. |
| `lib/models/task_model.dart`, `lib/models/user_model.dart` | Real model classes, but nothing in the app constructs or reads them — every screen uses raw Firestore `Map<String, dynamic>` instead. Dead code, not a missing feature (the functionality they'd represent already exists via the map-based approach). |

## 3. UI elements present but non-functional (dead buttons / no-ops)

| Location | What's broken |
|---|---|
| `HomeScreen` (caregiver dashboard) — "Start Cognitive Activities" card at the bottom | `onTap` is a bare `// TODO: navigate to cognitive activities screen`, does nothing. Also questionable whether it belongs on the **caregiver's** dashboard at all — caregivers don't play the cognitive games, only patients do (who already reach them via the drawer). Worth deciding: wire it somewhere sensible, or remove it. |
| `LoginScreen` — "Forgot Password?" link | `// TODO: Implement forgot password` — shows a snackbar ("Forgot Password tapped") and nothing else. No reset flow, despite `EditPatientScreen` already having a working password-reset-email pattern a caregiver can trigger *for* a patient — the patient has no self-service equivalent on the login screen itself. |
| `LoginScreen` — "Remember me" checkbox | Fully interactive (toggles state), but the value is never read anywhere — doesn't persist a session preference or change any login behaviour. Cosmetic only right now. |
| `CreateTaskScreen` bottom nav — "Home" tab | `onTap` only handles `index == 1` (Activities); tapping "Home" while already on this screen does nothing (not necessarily wrong, but inconsistent with "Activities" now being fully wired next to it). |

## 4. Explicitly deferred features (documented decisions, not oversights)

These were raised during earlier phases and deliberately scoped out — listed here so they don't get lost, not because they're bugs:

- **Google Calendar / any external calendar API** — the in-app calendar (`ActivityProgressScreen`) is MindCare-only; no OAuth, no sync.
- **Push notifications via FCM / any server-side delivery** — everything is local, on-device `flutter_local_notifications`. No backend notification infrastructure exists.
- **Auto-adjusting cognitive-game difficulty** based on live in-game performance — the difficulty tier is caregiver-set only; no adaptive/ML logic.
- **Per-game difficulty override** — one tier applies to *all* of a patient's games; there's no per-game setting.
- **Caregiver preview of both cognitive-game stage sets** — explicitly decided against; a patient only ever sees their own stage's set, caregivers can't toggle into "preview mode."
- **Recurring-task completion in the "Today's Progress" X/Y counts** on both dashboards — only non-recurring tasks are tallied; a recurring task's completion doesn't move that number (documented, not silently broken).

## 5. Known gaps in already-shipped features

- **`HomeScreen`'s task query window** (`getTasks`, ±3 days by due date) only catches a recurring task if its *own start date* falls in that window — an older recurring series (started weeks/months ago) can silently stop appearing on the caregiver's Home dashboard even on a day it still recurs, because the query filters on the stored `dueDate` (= series start), not on the occurrence date. The **calendar** (`ActivityProgressScreen`) doesn't have this problem — only the Home dashboard's task list does. Fixing it needs a different query/index shape, not just a bugfix.
- **No caregiver-facing reminder history at all** — the Notification History feature (and its `notificationHistory` collection) has been removed entirely. There's no UI for a caregiver to see "did the patient get reminded / how many times / did they respond," for either the single-shot reminder or the due-time reminder chain.
- **No Firestore security rules file** exists anywhere in this repo — can't confirm from the codebase whether patients are actually restricted to their own data at the database level, only that the app's *queries* are written to scope by `patientId`/`caregiverId`. This is a real gap worth checking directly in the Firebase console.

## 6. Needs on-device verification (can't be confirmed by reading code)

- **Notification action buttons (Complete/Missed) while the app is fully closed** — the background-isolate handler is implemented following the standard `flutter_local_notifications` pattern, but background delivery/Doze-mode behaviour can only really be confirmed by testing on a real device or emulator, not by code review. If it doesn't behave as expected, the fallback (tap the notification body → `TaskDetailScreen`'s Complete/Missed buttons) is fully implemented and doesn't depend on this working.
- **Exact-alarm scheduling on OEM Android skins** (e.g. some Xiaomi/Huawei battery-optimization behaviour can silently suppress scheduled alarms) — the app requests the standard permissions and has an inexact-alarm fallback, but real-world reliability across device manufacturers isn't something code review can verify.
