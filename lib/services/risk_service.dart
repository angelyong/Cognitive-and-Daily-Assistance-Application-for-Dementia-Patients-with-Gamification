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
    final RiskLevel level = signals.level;

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

  /// How many recent occurrences of each task to consider for the
  /// "3 consecutive missed" signal. We only ever need the latest 3 per
  /// series, computed directly from its recurrence rule (see
  /// [previousOccurrences]) — this replaces the old fixed 7-day window,
  /// which couldn't find 3 occurrences of a weekly/monthly/yearly task.
  static const int _recentOccurrencesPerTask = 3;

  Future<_MissedTasksResult> _evaluateMissedTasks(String patientId) async {
    final tasksSnap =
        await _db.collection('tasks').where('patientId', isEqualTo: patientId).get();
    final DateTime now = DateTime.now();

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
        // Frequency-independent: the last N due dates straight from the rule,
        // so a weekly/monthly/yearly task's recent misses are found without a
        // fixed-window scan (and a daily task reads only these N docs).
        final dates = previousOccurrences(series, now, count: _recentOccurrencesPerTask);
        for (final date in dates) {
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

  // ---- Signal 2: cognitive score down >=20%, compared LIKE-WITH-LIKE ----

  /// Recent-vs-previous window size per comparable bucket: the latest [_scoreDropK]
  /// sessions vs the [_scoreDropK] before them.
  static const int _scoreDropK = 3;

  /// Bounded slice of recent history to bucket. Generous enough to give a few
  /// games a full [_scoreDropK]×2 window each, still a single bounded read.
  static const int _scoreDropFetchLimit = 60;

  static const double _scoreDropThreshold = 0.20;

  /// Rewritten to compare only like-with-like sessions
  /// (DESIGN_DECISIONS_IMPLEMENTATION_PLAN.md #1): the old version pooled the
  /// last 5 vs previous 5 accuracies across ALL games, but "accuracy" means
  /// different things per game (first-attempt rate vs tap efficiency), so a
  /// patient merely shifting which games they play could swing it. Now:
  /// group sessions into buckets keyed by (gameId, difficultyLevel,
  /// metricVersion), compute a recent-vs-previous drop within each eligible
  /// bucket, and combine those per-bucket drops with EQUAL weight so a
  /// frequently-played game can't dominate. If no bucket has enough
  /// comparable sessions, the signal is simply not evaluable (false) — shown
  /// as such in the breakdown, never as "no risk".
  Future<_ScoreDropResult> _evaluateScoreDrop(String patientId) async {
    final snap = await _db
        .collection('gameSessions')
        .where('patientId', isEqualTo: patientId)
        .orderBy('completedAt', descending: true)
        .limit(_scoreDropFetchLimit)
        .get();

    final List<Map<String, dynamic>> sessions = snap.docs.map((d) => d.data()).toList();
    final DateTime? mostRecentAt =
        sessions.isEmpty ? null : (sessions.first['completedAt'] as Timestamp?)?.toDate();

    // Bucket by (gameId, difficultyLevel, metricVersion). Sessions arrive
    // newest-first, so each bucket's accuracy list stays newest-first too.
    final Map<String, List<double>> buckets = {};
    for (final s in sessions) {
      final String gameId = (s['gameId'] ?? '') as String;
      final int level = (s['difficultyLevel'] as num?)?.toInt() ?? 0;
      final int version = (s['metricVersion'] as num?)?.toInt() ?? 0;
      final String key = '$gameId|$level|$version';
      (buckets[key] ??= <double>[]).add((s['accuracy'] as num?)?.toDouble() ?? 0.0);
    }

    final List<double> perBucketDrops = [];
    for (final accs in buckets.values) {
      if (accs.length < _scoreDropK * 2) continue; // not enough to compare
      final recent = accs.sublist(0, _scoreDropK);
      final previous = accs.sublist(_scoreDropK, _scoreDropK * 2);
      final double avgRecent = recent.reduce((a, b) => a + b) / _scoreDropK;
      final double avgPrev = previous.reduce((a, b) => a + b) / _scoreDropK;
      if (avgPrev <= 0) continue; // can't express a % drop from a zero baseline
      perBucketDrops.add((avgPrev - avgRecent) / avgPrev);
    }

    if (perBucketDrops.isEmpty) {
      // Not evaluable — e.g. a recently-promoted patient whose sessions are
      // split across levels so no single bucket has _scoreDropK*2 yet.
      return _ScoreDropResult(
        isSignal: false,
        dropPercent: null,
        sessionsConsidered: sessions.length,
        mostRecentSessionAt: mostRecentAt,
      );
    }

    final double combined = perBucketDrops.reduce((a, b) => a + b) / perBucketDrops.length;
    return _ScoreDropResult(
      isSignal: combined >= _scoreDropThreshold,
      dropPercent: combined,
      sessionsConsidered: sessions.length,
      mostRecentSessionAt: mostRecentAt,
    );
  }

  // ---- Signal 3: >=3 days of inactivity ----

  /// "Last activity" = the most recent of: the dedicated `lastActiveAt`
  /// tracker (written on real patient activity — see
  /// FirestoreService.touchLastActive), the patient's last game session, and
  /// their last recorded app login (`lastLoginDate`). Taking the max means
  /// the newer, more accurate `lastActiveAt` wins when present, while old
  /// accounts that predate it still work via the session/login fallback —
  /// and "more recent" only ever reduces false "inactive" flags. See
  /// DESIGN_DECISIONS_IMPLEMENTATION_PLAN.md #2.
  Future<_InactivityResult> _evaluateInactivity(
    String patientId,
    DateTime? mostRecentSessionAt,
  ) async {
    final data = (await _userDoc(patientId).get()).data();
    final activeTs = data?['lastActiveAt'];
    final loginTs = data?['lastLoginDate'];
    final DateTime? lastActive = activeTs is Timestamp ? activeTs.toDate() : null;
    final DateTime? lastLogin = loginTs is Timestamp ? loginTs.toDate() : null;

    final List<DateTime> candidates =
        [lastActive, mostRecentSessionAt, lastLogin].whereType<DateTime>().toList();

    if (candidates.isEmpty) {
      // Never active at all — trivially satisfies "inactive", but with no
      // day count to show (there's nothing to count from).
      return const _InactivityResult(isSignal: true, days: null);
    }

    final DateTime lastActivity = candidates.reduce((a, b) => a.isAfter(b) ? a : b);
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
