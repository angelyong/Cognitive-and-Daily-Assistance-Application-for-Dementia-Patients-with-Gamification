import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/models/occurrence_status.dart';
import 'package:testproject/models/risk_assessment.dart';
import 'package:testproject/models/task_recurrence.dart';

/// PART 2 — Patient Risk Indicator (adaptive_difficulty_and_risk_indicator_prompt.md).
///
/// Evaluates the 3-signal rule (see risk_assessment.dart's doc comment) and
/// caches the result on `users/{patientId}` (`currentRiskLevel`/
/// `riskEvaluatedAt`/`riskSignals`), writing an audit doc to `riskHistory`
/// whenever the cached LEVEL actually changes — the same "cache + write an
/// audit record only on a real transition" shape as
/// AdaptiveDifficultyService/difficultyHistory in Part 1.
///
/// EVALUATION TRIGGER: this app has no server/scheduler, so instead of
/// hooking every call site that could move one of the 3 signals (a task
/// flipping to missed, a game session finishing — and "3 days of inactivity"
/// has no write to hook AT ALL, since by definition nothing is happening),
/// [evaluateAndCache] is called once whenever a caregiver-facing screen
/// that shows the risk badge is opened (see PatientRiskBadge in
/// widgets/risk_badge.dart, used by PatientListScreen/HomeScreen/
/// GameStatisticScreen). Reads are cheap and bounded (a handful of task docs
/// plus up to 10 game sessions per patient), so re-evaluating on every
/// dashboard open is simple and correct at this app's scale; a version
/// serving many more patients would rate-limit this using the cached
/// [RiskAssessment.evaluatedAt] instead — flagged here rather than silently
/// assumed to scale.
class RiskService {
  RiskService._internal();
  static final RiskService _instance = RiskService._internal();
  factory RiskService() => _instance;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _userDoc(String patientId) =>
      _db.collection('users').doc(patientId);

  Future<RiskAssessment> getAssessment(String patientId) async {
    final doc = await _userDoc(patientId).get();
    return RiskAssessment.fromMap(doc.data());
  }

  Stream<RiskAssessment> watchAssessment(String patientId) {
    return _userDoc(patientId).snapshots().map((doc) => RiskAssessment.fromMap(doc.data()));
  }

  /// Full audit trail of risk-level CHANGES for a patient, newest first —
  /// mirrors AdaptiveDifficultyService.watchHistory.
  Stream<QuerySnapshot<Map<String, dynamic>>> watchHistory(String patientId, {int limit = 20}) {
    return _db
        .collection('riskHistory')
        .where('patientId', isEqualTo: patientId)
        .orderBy('evaluatedAt', descending: true)
        .limit(limit)
        .snapshots();
  }

  /// Recomputes all 3 signals from source data (tasks/occurrences,
  /// gameSessions, the user doc's own lastLoginDate). If the resulting
  /// level differs from what's cached, the new cache fields AND a
  /// `riskHistory` audit doc are written in one transaction, so a level
  /// change and its audit record can never happen one without the other —
  /// same guarantee difficultyHistory gives in Part 1.
  Future<RiskAssessment> evaluateAndCache(String patientId) async {
    final _MissedTasksResult missed = await _evaluateMissedTasks(patientId);
    final _ScoreDropResult scoreDrop = await _evaluateScoreDrop(patientId);
    final _InactivityResult inactivity =
        await _evaluateInactivity(patientId, scoreDrop.mostRecentSessionAt);

    final RiskSignals signals = RiskSignals(
      missedTasks: missed.isSignal,
      consecutiveMissedCount: missed.consecutiveCount,
      scoreDrop: scoreDrop.isSignal,
      scoreDropPercent: scoreDrop.dropPercent,
      sessionsConsidered: scoreDrop.sessionsConsidered,
      inactivity: inactivity.isSignal,
      inactivityDays: inactivity.days,
    );
    final RiskLevel level = signals.allThree ? RiskLevel.atRisk : RiskLevel.none;

    final docRef = _userDoc(patientId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      final RiskAssessment previous = RiskAssessment.fromMap(snap.data());

      tx.set(
        docRef,
        {
          RiskLevelX.firestoreField: level.firestoreValue,
          'riskEvaluatedAt': FieldValue.serverTimestamp(),
          'riskSignals': signals.toMap(),
        },
        SetOptions(merge: true),
      );

      if (previous.level != level) {
        tx.set(_db.collection('riskHistory').doc(), {
          'patientId': patientId,
          'fromLevel': previous.level.firestoreValue,
          'toLevel': level.firestoreValue,
          'signals': signals.toMap(),
          'evaluatedAt': FieldValue.serverTimestamp(),
        });
      }
    });

    return RiskAssessment(level: level, signals: signals, evaluatedAt: DateTime.now());
  }

  // ---- Signal 1: 3 consecutive missed task occurrences ----

  /// Bounded scope decision: a recurring task's occurrences are only
  /// expanded over the last [_occurrenceLookbackDays] days (not its full
  /// history) — plenty to find "the last 3 occurrences" for any task due
  /// at least every few days, and avoids an unbounded per-task
  /// subcollection fan-out for a series that might have been running for
  /// months. Flagged rather than silently assumed, same spirit as
  /// sequencing_game.dart's step-count scope note from Part 1.
  static const int _occurrenceLookbackDays = 7;

  Future<_MissedTasksResult> _evaluateMissedTasks(String patientId) async {
    final tasksSnap =
        await _db.collection('tasks').where('patientId', isEqualTo: patientId).get();
    final DateTime now = DateTime.now();
    final DateTime windowStart = now.subtract(const Duration(days: _occurrenceLookbackDays));

    final List<_Occurrence> occurrences = [];
    for (final doc in tasksSnap.docs) {
      final data = doc.data();
      final dueTs = data['dueDate'];
      if (dueTs is! Timestamp) continue;
      final series = TaskSeries.fromDoc(doc);
      final int intervalMinutes =
          (data['reminderIntervalMinutes'] as num?)?.toInt() ?? defaultReminderIntervalMinutes;

      if (series.recurrenceType == RecurrenceType.none) {
        final DateTime due = dueTs.toDate();
        if (due.isAfter(now)) continue; // not due yet — not an occurrence
        final String stored = (data['status'] ?? 'pending') as String;
        occurrences.add(_Occurrence(
          due,
          effectiveStatus(storedStatus: stored, dueDate: due, reminderIntervalMinutes: intervalMinutes),
        ));
      } else {
        final dates = getOccurrencesForDateRange(series, windowStart, now);
        for (final date in dates) {
          if (date.isAfter(now)) continue;
          final occDoc =
              await doc.reference.collection('occurrences').doc(occurrenceDateKey(date)).get();
          final String stored = (occDoc.data()?['status'] as String?) ?? 'pending';
          occurrences.add(_Occurrence(
            date,
            effectiveStatus(storedStatus: stored, dueDate: date, reminderIntervalMinutes: intervalMinutes),
          ));
        }
      }
    }

    occurrences.sort((a, b) => b.date.compareTo(a.date));
    if (occurrences.length < 3) {
      return const _MissedTasksResult(isSignal: false, consecutiveCount: 0);
    }

    int consecutive = 0;
    for (final o in occurrences) {
      if (o.status != 'missed') break;
      consecutive++;
    }
    return _MissedTasksResult(isSignal: consecutive >= 3, consecutiveCount: consecutive);
  }

  // ---- Signal 2: cognitive score down >=20% (last 5 vs previous 5 of >=10 sessions) ----

  Future<_ScoreDropResult> _evaluateScoreDrop(String patientId) async {
    final snap = await _db
        .collection('gameSessions')
        .where('patientId', isEqualTo: patientId)
        .orderBy('completedAt', descending: true)
        .limit(10)
        .get();

    final List<Map<String, dynamic>> sessions = snap.docs.map((d) => d.data()).toList();
    final DateTime? mostRecentAt =
        sessions.isEmpty ? null : (sessions.first['completedAt'] as Timestamp?)?.toDate();

    if (sessions.length < 10) {
      return _ScoreDropResult(
        isSignal: false,
        dropPercent: null,
        sessionsConsidered: sessions.length,
        mostRecentSessionAt: mostRecentAt,
      );
    }

    double accuracyOf(Map<String, dynamic> s) => (s['accuracy'] as num?)?.toDouble() ?? 0.0;
    final double avgLast5 = sessions.sublist(0, 5).map(accuracyOf).reduce((a, b) => a + b) / 5;
    final double avgPrev5 = sessions.sublist(5, 10).map(accuracyOf).reduce((a, b) => a + b) / 5;

    if (avgPrev5 <= 0) {
      // A zero baseline can't meaningfully show a "20% drop" — guard the
      // division rather than produce a nonsensical/infinite ratio.
      return _ScoreDropResult(
        isSignal: false,
        dropPercent: null,
        sessionsConsidered: sessions.length,
        mostRecentSessionAt: mostRecentAt,
      );
    }

    final double drop = (avgPrev5 - avgLast5) / avgPrev5;
    return _ScoreDropResult(
      isSignal: drop >= 0.20,
      dropPercent: drop,
      sessionsConsidered: sessions.length,
      mostRecentSessionAt: mostRecentAt,
    );
  }

  // ---- Signal 3: >=3 days of inactivity ----

  /// "Last activity" = the more recent of the patient's last game session
  /// and their last recorded app login ([StreakData.lastLoginDate], the
  /// same field the streak screen already reads) — a reasonable, bounded
  /// proxy given this app has no dedicated "last seen" tracker; documented
  /// rather than silently assumed, same spirit as the other two signals'
  /// scope notes above.
  Future<_InactivityResult> _evaluateInactivity(
    String patientId,
    DateTime? mostRecentSessionAt,
  ) async {
    final userDoc = await _userDoc(patientId).get();
    final loginTs = userDoc.data()?['lastLoginDate'];
    final DateTime? lastLogin = loginTs is Timestamp ? loginTs.toDate() : null;

    DateTime? lastActivity;
    if (mostRecentSessionAt != null && lastLogin != null) {
      lastActivity = mostRecentSessionAt.isAfter(lastLogin) ? mostRecentSessionAt : lastLogin;
    } else {
      lastActivity = mostRecentSessionAt ?? lastLogin;
    }

    if (lastActivity == null) {
      // Never active at all — trivially satisfies "inactive", but with no
      // day count to show (there's nothing to count from).
      return const _InactivityResult(isSignal: true, days: null);
    }

    final int days = DateTime.now().difference(lastActivity).inDays;
    return _InactivityResult(isSignal: days >= 3, days: days);
  }

  // ---- Demo seeding (debug-only caregiver tool) ----

  /// A gameId that deliberately isn't in kGameCatalog, so seeded sessions
  /// never appear under any real game's difficulty card and never factor
  /// into AdaptiveDifficultyService's promote/demote decision for any real
  /// game (that decision is scoped to a specific gameId — see
  /// adaptive_difficulty_service.dart's _decide). Signal 2 itself queries
  /// gameSessions by patientId only (across all games), so this sentinel
  /// gameId still drives the risk score-drop signal correctly.
  static const String _demoSeedGameId = 'demo_seed_risk';

  /// Fabricates data that makes all 3 signals true at once for [patientId],
  /// then immediately runs the real [evaluateAndCache] — so this exercises
  /// the ACTUAL evaluation logic, not a hardcoded badge. Safe to call more
  /// than once (deterministic doc IDs overwrite rather than duplicate).
  ///
  /// Caller is responsible for only exposing this in a debug build (see
  /// GameStatisticScreen's `kDebugMode`-gated button) — this fabricates
  /// Firestore data and must never run in a caregiver's normal workflow.
  Future<void> seedDemoRiskData(String patientId) async {
    final DateTime now = DateTime.now();
    final WriteBatch batch = _db.batch();

    // Signal 1: 3 consecutive missed one-off tasks, most recent 3 days ago.
    for (int i = 0; i < 3; i++) {
      final DateTime due = now.subtract(Duration(days: 3 + i));
      final ref = _db.collection('tasks').doc('${patientId}_seed_risk_task_$i');
      batch.set(ref, {
        'caregiverId': FirebaseAuth.instance.currentUser?.uid ?? '',
        'patientId': patientId,
        'title': 'Demo seeded task ${i + 1}',
        'category': 'Daily Task',
        'dueDate': Timestamp.fromDate(due),
        'description': 'Fabricated by the risk-indicator demo seed tool.',
        'dosage': null,
        'status': 'missed',
        'createdAt': Timestamp.fromDate(due),
        RecurrenceTypeX.firestoreField: RecurrenceType.none.firestoreValue,
        'recurrenceRule': null,
        'endDate': null,
        'reminderIntervalMinutes': defaultReminderIntervalMinutes,
      });
    }

    // Signal 2: 10 game sessions, oldest 5 high-accuracy, most recent 5
    // low-accuracy — a clear >=20% drop. ALL backdated >=3 days so the most
    // recent one still leaves the patient >=3 days inactive (this data
    // satisfies signal 3 too, rather than contradicting it).
    for (int i = 0; i < 10; i++) {
      final bool isRecentHalf = i < 5; // i=0 is most recent
      final double accuracy = isRecentHalf ? 0.5 : 0.9;
      final DateTime completedAt = now.subtract(Duration(days: 3 + (9 - i)));
      final ref = _db.collection('gameSessions').doc('${patientId}_seed_risk_session_$i');
      batch.set(ref, {
        'patientId': patientId,
        'gameId': _demoSeedGameId,
        'gameSet': 'demo',
        'difficultyLevel': 1,
        'totalItems': 10,
        'correctItems': (accuracy * 10).round(),
        'accuracy': accuracy,
        'hintsUsed': 0,
        'durationSeconds': 60,
        'completedAt': Timestamp.fromDate(completedAt),
      });
    }

    // Signal 3: make sure lastLoginDate doesn't override the inactivity
    // picture above with a recent, unrelated write.
    batch.set(
      _userDoc(patientId),
      {'lastLoginDate': Timestamp.fromDate(now.subtract(const Duration(days: 5)))},
      SetOptions(merge: true),
    );

    await batch.commit();
    await evaluateAndCache(patientId);
  }
}

class _Occurrence {
  final DateTime date;
  final String status;
  const _Occurrence(this.date, this.status);
}

class _MissedTasksResult {
  final bool isSignal;
  final int consecutiveCount;
  const _MissedTasksResult({required this.isSignal, required this.consecutiveCount});
}

class _ScoreDropResult {
  final bool isSignal;
  final double? dropPercent;
  final int sessionsConsidered;
  final DateTime? mostRecentSessionAt;
  const _ScoreDropResult({
    required this.isSignal,
    required this.dropPercent,
    required this.sessionsConsidered,
    required this.mostRecentSessionAt,
  });
}

class _InactivityResult {
  final bool isSignal;
  final int? days;
  const _InactivityResult({required this.isSignal, required this.days});
}
