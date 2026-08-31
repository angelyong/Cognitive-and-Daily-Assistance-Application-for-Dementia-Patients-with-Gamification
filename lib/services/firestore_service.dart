// getPatientTasks()
// updateTaskStatus()
// getPatientStatus()
// getDashboardSummary()
//addPatientToCaregiver()
// Task CRUD
//Dashboard Summary
//Add Patient
//Exercise Result
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/models/game_difficulty.dart';
import 'package:testproject/models/dementia_profile.dart';
import 'package:testproject/models/task_recurrence.dart';
import 'package:testproject/models/occurrence_status.dart';


class FirestoreService {

  FirebaseFirestore firestore =
      FirebaseFirestore.instance;

/// PHASE 2 (see phase2_recurring_tasks_prompt.md): [recurrenceType] /
/// [recurrenceRule] / [endDate] are optional — omitted entirely for a
/// plain one-off task, exactly as before this phase. `dueDate` is always
/// the task's own due date/time; for a recurring task that's also its
/// start date (Step 8 — one doc per series, never one per occurrence).
Future<String> addTask({
    required String caregiverId,
    required String patientId,
    required String title,
    required String category,
    DateTime? dueDate,
    DateTime? reminderAt,
    required String description,
    String? dosage,
    RecurrenceType recurrenceType = RecurrenceType.none,
    RecurrenceRule? recurrenceRule,
    DateTime? endDate,
    int reminderIntervalMinutes = defaultReminderIntervalMinutes,
  }) async {
    final doc = await firestore.collection('tasks').add({
      'caregiverId': caregiverId,
      'patientId': patientId,
      'title': title,
      'category': category,
      'dueDate': dueDate != null ? Timestamp.fromDate(dueDate) : null,
      'reminderAt': reminderAt != null ? Timestamp.fromDate(reminderAt) : null,
      'description': description,
      'dosage': dosage,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
      RecurrenceTypeX.firestoreField: recurrenceType.firestoreValue,
      'recurrenceRule': recurrenceType == RecurrenceType.none
          ? null
          : recurrenceRule?.toMap(),
      'endDate': endDate != null ? Timestamp.fromDate(endDate) : null,
      // PHASE 3: the patient's own device uses this to space the
      // due-time reminder chain (see notification_service.dart). Missing
      // on old docs -> defaultReminderIntervalMinutes (read via
      // getReminderIntervalMinutes below), same backward-compat pattern
      // as recurrenceType.
      'reminderIntervalMinutes': reminderIntervalMinutes,
    });
    return doc.id;
  }

  Future<void> updateTask({
    required String taskId,
    required String patientId,
    required String title,
    required String category,
    DateTime? dueDate,
    DateTime? reminderAt,
    required String description,
    String? dosage,
    RecurrenceType recurrenceType = RecurrenceType.none,
    RecurrenceRule? recurrenceRule,
    DateTime? endDate,
    int reminderIntervalMinutes = defaultReminderIntervalMinutes,
  }) async {
    await firestore.collection('tasks').doc(taskId).update({
      'patientId': patientId,
      'title': title,
      'category': category,
      'dueDate': dueDate != null ? Timestamp.fromDate(dueDate) : null,
      'reminderAt': reminderAt != null ? Timestamp.fromDate(reminderAt) : null,
      'description': description,
      // Always written (even when null) so switching a task away from
      // Medication clears any previously-set dosage rather than leaving
      // stale data behind. Same reasoning for the recurrence fields below.
      'dosage': dosage,
      RecurrenceTypeX.firestoreField: recurrenceType.firestoreValue,
      'recurrenceRule': recurrenceType == RecurrenceType.none
          ? null
          : recurrenceRule?.toMap(),
      'endDate': endDate != null ? Timestamp.fromDate(endDate) : null,
      'reminderIntervalMinutes': reminderIntervalMinutes,
    });
  }

  /// Backward-compatible read: an old task doc has no
  /// `reminderIntervalMinutes` field at all -> [defaultReminderIntervalMinutes].
  int reminderIntervalMinutesOf(Map<String, dynamic> data) {
    return (data['reminderIntervalMinutes'] as int?) ??
        defaultReminderIntervalMinutes;
  }

  /// PHASE 3 per-occurrence status (Step 3): only meaningful for a
  /// recurring task (recurrenceType != none) — a plain single task keeps
  /// using its own top-level `status` field exactly as before this phase,
  /// untouched by any of this. Stored at
  /// `tasks/{taskId}/occurrences/{yyyy-MM-dd}` rather than a map field on
  /// the task doc, so a long-running daily/weekly series doesn't grow an
  /// ever-larger single document.
  Future<String> getOccurrenceStatus(String taskId, DateTime occurrenceDate) async {
    final doc = await firestore
        .collection('tasks')
        .doc(taskId)
        .collection('occurrences')
        .doc(occurrenceDateKey(occurrenceDate))
        .get();
    if (!doc.exists) return 'pending';
    final data = doc.data() as Map<String, dynamic>;
    return (data['status'] ?? 'pending') as String;
  }

  /// Idempotent by construction — writing the same status twice just
  /// overwrites the doc with the same values, which is safe for a
  /// double-tapped Complete/Missed action or a race between the
  /// notification action handler and the in-app button.
  Future<void> setOccurrenceStatus(
    String taskId,
    DateTime occurrenceDate,
    String status,
  ) async {
    await firestore
        .collection('tasks')
        .doc(taskId)
        .collection('occurrences')
        .doc(occurrenceDateKey(occurrenceDate))
        .set({
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Live version of [getOccurrenceStatus], for UI that should update
  /// immediately (e.g. a second device completing the same occurrence).
  /// Emits 'pending' for a not-yet-created occurrence doc, same default.
  Stream<String> getOccurrenceStatusStream(String taskId, DateTime occurrenceDate) {
    return firestore
        .collection('tasks')
        .doc(taskId)
        .collection('occurrences')
        .doc(occurrenceDateKey(occurrenceDate))
        .snapshots()
        .map((doc) => (doc.data()?['status'] as String?) ?? 'pending');
  }

  Future<void> deleteTask(String taskId) async {
    await firestore.collection('tasks').doc(taskId).delete();
  }

  /// One-time fetch of a single task, for the read-only detail view
  /// (UC-05 sub-flow 8a/8b, and the notification-tap flow in 8c/8d).
  /// Returns null if the task no longer exists (e.g. it was deleted).
  Future<Map<String, dynamic>?> getTask(String taskId) async {
    final doc = await firestore.collection('tasks').doc(taskId).get();
    if (!doc.exists) return null;
    return doc.data();
  }

  /// Live version of a single task's top-level `status` field — for a
  /// non-recurring task, this IS its status (see [getOccurrenceStatusStream]
  /// for the recurring equivalent). Emits 'pending' if the doc is missing
  /// or has no status yet.
  Stream<String> getTaskStatusStream(String taskId) {
    return firestore
        .collection('tasks')
        .doc(taskId)
        .snapshots()
        .map((doc) => (doc.data()?['status'] as String?) ?? 'pending');
  }

  Future<String?> getUserName(String uid) async {
    final doc = await firestore.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    final data = doc.data() as Map<String, dynamic>;
    return data['name'] as String?;
  }

  /// Reads a patient's caregiver-assigned cognitive game difficulty tier.
  /// Read once at the start of each game session (not a live stream — the
  /// tier isn't expected to change mid-session). Defaults to Standard if
  /// the patient doc doesn't have one set yet.
  Future<GameDifficultyTier> getPatientDifficultyTier(String patientId) async {
    final doc = await firestore.collection('users').doc(patientId).get();
    if (!doc.exists) return GameDifficultyTier.standard;
    final data = doc.data() as Map<String, dynamic>;
    return GameDifficultyTierX.fromFirestore(
      data[GameDifficultyTierX.firestoreField] as String?,
    );
  }

  /// Reads a patient's caregiver-assigned dementia stage, used to route
  /// them to the correct cognitive-game SET (early vs middle — a
  /// different set of games, not the same games at different difficulty;
  /// see claude_code_two_stage_game_sets_prompt.md). Defaults to Early,
  /// matching DementiaStageX.fromFirestore's own default for an unset
  /// patient doc.
  Future<DementiaStage> getPatientDementiaStage(String patientId) async {
    final doc = await firestore.collection('users').doc(patientId).get();
    if (!doc.exists) return DementiaStage.early;
    final data = doc.data() as Map<String, dynamic>;
    return DementiaStageX.fromFirestore(
      data[DementiaStageX.firestoreField] as String?,
    );
  }

  /// Reads a patient's caregiver-assigned dementia type, used together with
  /// [getPatientDementiaStage] to route them to 1 of the 4 cognitive-game
  /// sets (AD-Early / AD-Middle / VaD-Early / VaD-Middle — see
  /// claude_code_four_game_sets_prompt.md). Defaults to Alzheimer's,
  /// matching DementiaTypeX.fromFirestore's own default for an unset
  /// patient doc.
  Future<DementiaType> getPatientDementiaType(String patientId) async {
    final doc = await firestore.collection('users').doc(patientId).get();
    if (!doc.exists) return DementiaType.alzheimers;
    final data = doc.data() as Map<String, dynamic>;
    return DementiaTypeX.fromFirestore(
      data[DementiaTypeX.firestoreField] as String?,
    );
  }

  /// Caregiver-only setter — called from the patient management screen.
  /// One tier applies to all of that patient's games (no per-game override
  /// in this MVP).
  Future<void> setPatientDifficultyTier(
    String patientId,
    GameDifficultyTier tier,
  ) async {
    await firestore.collection('users').doc(patientId).update({
      GameDifficultyTierX.firestoreField: tier.firestoreValue,
    });
  }

  Future<void> updateTaskStatus(
      String taskId,
      String status) async {

    await firestore
        .collection('tasks')
        .doc(taskId)
        .update({
      'status': status,
    });
  }

  /// Adds (or, with a negative value, removes) points on a patient's
  /// gamification total. Used to award points when a task/medication is
  /// ticked complete, and to revoke them if it's un-ticked.
  Future<void> awardPoints(String patientId, int points) async {
    if (patientId.isEmpty) return;
    await firestore.collection('users').doc(patientId).update({
      'streakPoints': FieldValue.increment(points),
    });
  }

  /// Records that the PATIENT was genuinely active just now — the dedicated
  /// "last seen" signal for the risk inactivity check (see
  /// RiskService._evaluateInactivity). Uses a server timestamp, and stores
  /// the real activity time (unlike `lastLoginDate`, which is only the
  /// calendar date at midnight of the first login of a day).
  ///
  /// MUST only be called for genuine patient activity — dashboard use, a
  /// patient's own task response (Complete/Missed), a notification response,
  /// or finishing a game. Never for an auto-missed task (that's the ABSENCE
  /// of activity) or any caregiver action (a caregiver isn't the patient
  /// being active). See DESIGN_DECISIONS_IMPLEMENTATION_PLAN.md #2.
  ///
  /// [minInterval] throttles high-frequency callers (e.g. a dashboard that
  /// rebuilds/reopens often): if the stored `lastActiveAt` is already newer
  /// than [minInterval] ago, the write is skipped. Discrete events (task
  /// response, game finish) should pass the default (no throttle).
  Future<void> touchLastActive(String patientId, {Duration minInterval = Duration.zero}) async {
    if (patientId.isEmpty) return;
    final ref = firestore.collection('users').doc(patientId);
    if (minInterval > Duration.zero) {
      final snap = await ref.get();
      final ts = snap.data()?['lastActiveAt'];
      if (ts is Timestamp && DateTime.now().difference(ts.toDate()) < minInterval) {
        return; // recently active — don't hammer Firestore
      }
    }
    await ref.set({'lastActiveAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
  }

  /// Live total points for a patient — the SAME `streakPoints` field
  /// [awardPoints] writes and [StreakData.totalPoints]/the streak screen
  /// read, so anything gated on points (e.g. the reward game unlock in
  /// CognitiveExerciseScreen) always agrees with what the streak screen
  /// shows. Emits 0 for a missing doc/field rather than erroring.
  Stream<int> watchPatientTotalPoints(String patientId) {
    return firestore
        .collection('users')
        .doc(patientId)
        .snapshots()
        .map((doc) => (doc.data()?['streakPoints'] as int?) ?? 0);
  }

/// The "due today, or overdue by up to this many days" grace window used
/// by HomeScreen — public (not private) so HomeScreen's client-side
/// occurrence filtering (see getAllTasksForCaregiver) can reuse the exact
/// same number instead of duplicating the magic constant.
static const int homeWindowDays = 3;

/// SUPERSEDED for HomeScreen's use by [getAllTasksForCaregiver] — see
/// fix_recurring_task_homescreen_visibility.md. Kept as-is (not deleted,
/// not called from anywhere now) per that doc's explicit instruction not
/// to remove the ±[homeWindowDays]-day query behaviour; the behaviour
/// itself now lives client-side in HomeScreen instead of server-side here.
///
/// The problem this doc's fix addresses: this query range-filters on the
/// raw `dueDate` field, which for a recurring task is only its START
/// date — so a recurring series older than [homeWindowDays] days would
/// never match here again, even on a day it still has an occurrence.
/// Requires a Firestore composite index on (caregiverId ASC, dueDate ASC).
///
/// Note: tasks with no dueDate set can never match this range filter, so
/// they won't appear here (they still exist and show up in task history).
Stream<QuerySnapshot> getTasks(String caregiverId) {
  final now = DateTime.now();
  final startOfToday = DateTime(now.year, now.month, now.day);
  final windowStart = startOfToday.subtract(const Duration(days: homeWindowDays));
  final endOfDay = startOfToday.add(const Duration(days: 1));
  return firestore
      .collection('tasks')
      .where('caregiverId', isEqualTo: caregiverId)
      .where('dueDate', isGreaterThanOrEqualTo: Timestamp.fromDate(windowStart))
      .where('dueDate', isLessThan: Timestamp.fromDate(endOfDay))
      .snapshots();
}

/// All of a caregiver's tasks, unbounded by date — same pattern as
/// [getTaskHistory] (used by the calendar), which is what lets a recurring
/// series be found regardless of how long ago it started: the caller
/// expands occurrences client-side (via getOccurrencesForDateRange) rather
/// than relying on Firestore to filter by the series' own start date.
///
/// Deliberately has NO orderBy (unlike getTaskHistory) — HomeScreen groups
/// by patient rather than sorting by date, so none is needed, and a bare
/// equality filter needs no composite index at all.
Stream<QuerySnapshot> getAllTasksForCaregiver(String caregiverId) {
  return firestore
      .collection('tasks')
      .where('caregiverId', isEqualTo: caregiverId)
      .snapshots();
}

  /// A patient's own view of their tasks — everything assigned to them,
  /// regardless of which caregiver created it.
  Stream<QuerySnapshot> getTasksForPatient(String patientId) {
    return firestore
        .collection('tasks')
        .where('patientId', isEqualTo: patientId)
        .snapshots();
  }

  /// Full task history for a patient (no date limit), newest due date
  /// first. Requires a Firestore composite index on
  /// (patientId ASC, dueDate DESC) — same as above, Firestore will link to
  /// create it on first run if missing.
  ///
  /// Note: tasks with no dueDate set are excluded, since Firestore's
  /// orderBy skips documents missing the ordered field.
  Stream<QuerySnapshot> getTaskHistory(String patientId) {
    return firestore
        .collection('tasks')
        .where('patientId', isEqualTo: patientId)
        .orderBy('dueDate', descending: true)
        .snapshots();
  }

  /// Generic field update for a task — used by the patient task history
  /// screen to edit status (and, later, other fields) without needing a
  /// dedicated method per field.
  Future<void> updateTaskDetails(
    String taskId,
    Map<String, dynamic> fields,
  ) async {
    await firestore.collection('tasks').doc(taskId).update(fields);
  }

  // ---- Get patients assigned to a caregiver ----
Future<List<Map<String, dynamic>>> getPatientsForCaregiver(
    String caregiverId) async {
  final snap = await FirebaseFirestore.instance
      .collection('users')
      .where('role', isEqualTo: 'patient')
      .where('caregiverId', isEqualTo: caregiverId)
      .get();
  return snap.docs.map((d) => d.data()).toList();
}

  /// Live version of [getPatientsForCaregiver], for screens that should
  /// update immediately when a patient is added (e.g. the patient list).
  Stream<QuerySnapshot> getPatientsStream(String caregiverId) {
    return firestore
        .collection('users')
        .where('role', isEqualTo: 'patient')
        .where('caregiverId', isEqualTo: caregiverId)
        .snapshots();
  }

  /// Unlinks a patient from this caregiver by clearing their caregiverId.
  /// This is a soft removal: the patient's account, tasks and history are
  /// untouched — they just stop appearing in this caregiver's patient list
  /// (deleting the Auth account outright would need the Admin SDK).
  Future<void> unlinkPatient(String patientUid) async {
    await firestore.collection('users').doc(patientUid).update({
      'caregiverId': FieldValue.delete(),
    });
  }
}