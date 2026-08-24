import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:testproject/models/game_catalog.dart';
import 'package:testproject/models/occurrence_status.dart';
import 'package:testproject/models/performance_snapshot.dart';
import 'package:testproject/models/task_recurrence.dart';

/// PatientPerformanceScreen's data layer (see PERFORMANCE_DASHBOARD_PLAN.md).
/// Read-and-aggregate only — no state machine, no writes of its own outside
/// the debug demo-seed/clear pair at the bottom, unlike
/// AdaptiveDifficultyService's transactional promote/demote writes. Closer
/// in shape to how RiskService computes its 3 signals: pull raw docs,
/// derive numbers client-side, return a plain data object for the screen
/// to render — the screen itself never touches Firestore directly.
class PerformanceAnalyticsService {
  PerformanceAnalyticsService._internal();
  static final PerformanceAnalyticsService _instance = PerformanceAnalyticsService._internal();
  factory PerformanceAnalyticsService() => _instance;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Bounded scope decision, same spirit as RiskService's
  /// _occurrenceLookbackDays: recurring-task occurrences are only expanded
  /// over the last 90 days regardless of the selected period (even for
  /// "All Time"), rather than however long a series has existed — flagged
  /// here rather than silently assumed, matching the pattern used
  /// throughout this codebase for bounded fan-out reads.
  static const int _taskLookbackDays = 90;

  Future<PerformanceSnapshot> loadSnapshot(String patientId, PerformancePeriod period) async {
    final DateTime now = DateTime.now();
    final int? periodDays = period.days;
    final DateTime? currentStart = periodDays == null ? null : now.subtract(Duration(days: periodDays));
    final DateTime? previousStart =
        (currentStart == null || periodDays == null) ? null : currentStart.subtract(Duration(days: periodDays));

    final results = await Future.wait([
      _loadSessionStats(patientId, currentStart, previousStart, now),
      _loadTaskStats(patientId, currentStart, previousStart, now),
      _loadStreakInfo(patientId),
    ]);
    final _SessionStats sessionStats = results[0] as _SessionStats;
    final _TaskStats taskStats = results[1] as _TaskStats;
    final _StreakInfo streakInfo = results[2] as _StreakInfo;

    return PerformanceSnapshot(
      averageAccuracy: sessionStats.accuracyKpi,
      sessionsPlayed: sessionStats.sessionsKpi,
      taskCompletionRate: taskStats.completionRateKpi,
      averageHints: sessionStats.hintsKpi,
      streakPoints: streakInfo.streakPoints,
      currentStreak: streakInfo.currentStreak,
      dailyAccuracy: sessionStats.dailyAccuracy,
      dailySessions: sessionStats.dailySessions,
      dailyHints: sessionStats.dailyHints,
      accuracyByGame: sessionStats.accuracyByGame,
      tasksByCategory: taskStats.tasksByCategory,
    );
  }

  // ---- gameSessions: accuracy / sessions / hints KPIs + trend charts + per-game bars ----

  Future<_SessionStats> _loadSessionStats(
    String patientId,
    DateTime? currentStart,
    DateTime? previousStart,
    DateTime now,
  ) async {
    Query<Map<String, dynamic>> query =
        _db.collection('gameSessions').where('patientId', isEqualTo: patientId);
    final DateTime? queryFloor = previousStart ?? currentStart;
    if (queryFloor != null) {
      query = query.where('completedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(queryFloor));
    }
    final snap = await query.orderBy('completedAt', descending: false).get();

    final List<_Session> all = snap.docs.map((d) {
      final data = d.data();
      final ts = data['completedAt'];
      return _Session(
        gameId: (data['gameId'] ?? '') as String,
        accuracy: (data['accuracy'] as num?)?.toDouble() ?? 0.0,
        hintsUsed: (data['hintsUsed'] as num?)?.toInt() ?? 0,
        completedAt: ts is Timestamp ? ts.toDate() : now,
      );
    }).toList();

    final List<_Session> current =
        currentStart == null ? all : all.where((s) => !s.completedAt.isBefore(currentStart)).toList();
    final List<_Session> previous = (currentStart == null || previousStart == null)
        ? const []
        : all
            .where((s) => s.completedAt.isBefore(currentStart) && !s.completedAt.isBefore(previousStart))
            .toList();

    double avgAccuracy(List<_Session> l) => l.isEmpty ? 0 : l.map((s) => s.accuracy).reduce((a, b) => a + b) / l.length;
    double avgHints(List<_Session> l) =>
        l.isEmpty ? 0 : l.map((s) => s.hintsUsed).reduce((a, b) => a + b) / l.length;
    final bool hasComparison = currentStart != null && previousStart != null;

    // Even "All Time" shows a bounded trailing 30-day trend line — an
    // unbounded x-axis stretching back to account creation isn't a useful
    // chart. A defined period (7/30 days) uses exactly that many buckets.
    final int bucketDays = currentStart == null ? 30 : now.difference(currentStart).inDays.clamp(1, 30);

    return _SessionStats(
      accuracyKpi: KpiValue(current: avgAccuracy(current), previous: hasComparison ? avgAccuracy(previous) : null),
      sessionsKpi: KpiValue(
        current: current.length.toDouble(),
        previous: hasComparison ? previous.length.toDouble() : null,
      ),
      hintsKpi: KpiValue(current: avgHints(current), previous: hasComparison ? avgHints(previous) : null),
      dailyAccuracy: _bucketDailyAverage(current, bucketDays, now, (s) => s.accuracy),
      dailySessions: _bucketDailyCount(current, bucketDays, now),
      dailyHints: _bucketDailyAverage(current, bucketDays, now, (s) => s.hintsUsed.toDouble()),
      accuracyByGame: _accuracyByGame(current),
    );
  }

  List<GameBar> _accuracyByGame(List<_Session> sessions) {
    final Map<String, List<_Session>> byGame = {};
    for (final s in sessions) {
      byGame.putIfAbsent(s.gameId, () => []).add(s);
    }
    final List<GameBar> bars = [
      for (final entry in byGame.entries)
        GameBar(
          gameId: entry.key,
          label: gameLabelFor(entry.key),
          averageAccuracy: entry.value.map((s) => s.accuracy).reduce((a, b) => a + b) / entry.value.length,
          sessionCount: entry.value.length,
        ),
    ];
    // Catalog order (AD-Early -> AD-Middle -> VaD-Early -> VaD-Middle) so
    // the chart reads left-to-right the same way the game hub does, rather
    // than an arbitrary map-iteration order.
    final Map<String, int> catalogOrder = {
      for (int i = 0; i < kGameCatalog.length; i++) kGameCatalog[i].id: i,
    };
    bars.sort((a, b) => (catalogOrder[a.gameId] ?? 999).compareTo(catalogOrder[b.gameId] ?? 999));
    return bars;
  }

  List<ChartPoint> _bucketDailyAverage(
    List<_Session> sessions,
    int days,
    DateTime now,
    double Function(_Session) valueOf,
  ) {
    final DateTime todayStart = DateTime(now.year, now.month, now.day);
    final Map<DateTime, List<double>> byDay = {};
    for (final s in sessions) {
      final DateTime day = DateTime(s.completedAt.year, s.completedAt.month, s.completedAt.day);
      byDay.putIfAbsent(day, () => []).add(valueOf(s));
    }
    return [
      for (int i = days - 1; i >= 0; i--)
        () {
          final DateTime day = todayStart.subtract(Duration(days: i));
          final List<double> values = byDay[day] ?? const [];
          final double avg = values.isEmpty ? 0 : values.reduce((a, b) => a + b) / values.length;
          return ChartPoint(day, avg);
        }(),
    ];
  }

  List<ChartPoint> _bucketDailyCount(List<_Session> sessions, int days, DateTime now) {
    final DateTime todayStart = DateTime(now.year, now.month, now.day);
    final Map<DateTime, int> byDay = {};
    for (final s in sessions) {
      final DateTime day = DateTime(s.completedAt.year, s.completedAt.month, s.completedAt.day);
      byDay[day] = (byDay[day] ?? 0) + 1;
    }
    return [
      for (int i = days - 1; i >= 0; i--)
        () {
          final DateTime day = todayStart.subtract(Duration(days: i));
          return ChartPoint(day, (byDay[day] ?? 0).toDouble());
        }(),
    ];
  }

  // ---- tasks: completion-rate KPI + tasks-by-category bars ----

  Future<_TaskStats> _loadTaskStats(
    String patientId,
    DateTime? currentStart,
    DateTime? previousStart,
    DateTime now,
  ) async {
    final DateTime windowStart = previousStart ?? now.subtract(const Duration(days: _taskLookbackDays));
    final tasksSnap = await _db.collection('tasks').where('patientId', isEqualTo: patientId).get();

    final List<_TaskOccurrence> occurrences = [];
    for (final doc in tasksSnap.docs) {
      final data = doc.data();
      final dueTs = data['dueDate'];
      if (dueTs is! Timestamp) continue;
      final series = TaskSeries.fromDoc(doc);
      final int intervalMinutes =
          (data['reminderIntervalMinutes'] as num?)?.toInt() ?? defaultReminderIntervalMinutes;
      final String category = (data['category'] ?? 'Other') as String;

      if (series.recurrenceType == RecurrenceType.none) {
        final DateTime due = dueTs.toDate();
        if (due.isAfter(now) || due.isBefore(windowStart)) continue;
        final String stored = (data['status'] ?? 'pending') as String;
        occurrences.add(_TaskOccurrence(
          date: due,
          category: category,
          status:
              effectiveStatus(storedStatus: stored, dueDate: due, reminderIntervalMinutes: intervalMinutes),
        ));
      } else {
        final dates = getOccurrencesForDateRange(series, windowStart, now);
        for (final date in dates) {
          if (date.isAfter(now)) continue;
          final occDoc =
              await doc.reference.collection('occurrences').doc(occurrenceDateKey(date)).get();
          final String stored = (occDoc.data()?['status'] as String?) ?? 'pending';
          occurrences.add(_TaskOccurrence(
            date: date,
            category: category,
            status: effectiveStatus(
                storedStatus: stored, dueDate: date, reminderIntervalMinutes: intervalMinutes),
          ));
        }
      }
    }

    final List<_TaskOccurrence> current =
        currentStart == null ? occurrences : occurrences.where((o) => !o.date.isBefore(currentStart)).toList();
    final List<_TaskOccurrence> previous = (currentStart == null || previousStart == null)
        ? const []
        : occurrences
            .where((o) => o.date.isBefore(currentStart) && !o.date.isBefore(previousStart))
            .toList();

    double completionRate(List<_TaskOccurrence> list) {
      final resolved = list.where((o) => o.status == 'completed' || o.status == 'missed').toList();
      if (resolved.isEmpty) return 0;
      return resolved.where((o) => o.status == 'completed').length / resolved.length;
    }

    final bool hasComparison = currentStart != null && previousStart != null;

    final Map<String, int> byCategory = {};
    for (final o in current) {
      if (o.status == 'completed') {
        byCategory[o.category] = (byCategory[o.category] ?? 0) + 1;
      }
    }
    final List<CategoryBar> bars = [
      for (final entry in byCategory.entries) CategoryBar(category: entry.key, completedCount: entry.value),
    ]..sort((a, b) => b.completedCount.compareTo(a.completedCount));

    return _TaskStats(
      completionRateKpi:
          KpiValue(current: completionRate(current), previous: hasComparison ? completionRate(previous) : null),
      tasksByCategory: bars,
    );
  }

  // ---- users/{patientId}: streak + points ----

  Future<_StreakInfo> _loadStreakInfo(String patientId) async {
    final doc = await _db.collection('users').doc(patientId).get();
    final data = doc.data();
    return _StreakInfo(
      streakPoints: (data?['streakPoints'] as num?)?.toInt() ?? 0,
      currentStreak: (data?['currentStreak'] as num?)?.toInt() ?? 0,
    );
  }

  // ---- Demo seeding (debug-only caregiver tool) ----

  static const int _seedSessionCount = 24;
  static const int _seedTaskCount = 14;
  static const List<String> _seedCategories = [
    'Medication',
    'Exercise',
    'Meal',
    'Hygiene',
    'Social',
    'Appointment',
    'Other',
  ];

  /// Fabricates ~3-4 weeks of spread-out activity (backdated `gameSessions`
  /// across real games + backdated one-off `tasks`) so every tile and
  /// chart on the performance dashboard has real, varied, non-trivial data
  /// to render — most of what this screen shows is a TIME SERIES ("accuracy
  /// per day over the last 30 days"), which can't be produced organically
  /// in a short testing window no matter how many times a game is played
  /// today; it needs data points spread across many different past days.
  ///
  /// Uses REAL game ids (per PERFORMANCE_DASHBOARD_PLAN.md's "middle
  /// ground" decision) so the accuracy-by-game chart is actually
  /// meaningful — the trade-off is that AdaptiveDifficultyService's
  /// promote/demote rule looks at "the last 3 sessions" for a game
  /// regardless of whether they're real or seeded, so these COULD nudge a
  /// game's live difficulty level the next time the patient genuinely
  /// plays it. [clearDemoPerformanceData] is the safety valve — it deletes
  /// exactly these documents by their deterministic ids, no scanning
  /// needed, so a demo can be fully undone afterward.
  ///
  /// Seeded tasks are written WITHOUT a `caregiverId` field on purpose:
  /// every real task-list query in this app (HomeScreen, the missed-status
  /// sweeps) filters by `caregiverId`, so omitting it keeps these fabricated
  /// tasks invisible to the caregiver's own real dashboard. They are still
  /// visible to a patient's own dashboard/task history (which queries by
  /// `patientId` only) if that patient's real device is signed in during a
  /// debug session — the same accepted trade-off Part 2's
  /// `RiskService.seedDemoRiskData` already makes, bounded by this whole
  /// method only ever being reachable from a `kDebugMode`-gated button.
  Future<void> seedDemoPerformanceData(String patientId) async {
    final DateTime now = DateTime.now();
    final Random random = Random();
    final WriteBatch batch = _db.batch();

    for (int i = 0; i < _seedSessionCount; i++) {
      final GameCatalogEntry game = kGameCatalog[i % kGameCatalog.length];
      final DateTime completedAt =
          now.subtract(Duration(days: random.nextInt(30), hours: random.nextInt(12)));
      final int totalItems = 6 + random.nextInt(5);
      final double targetAccuracy = 0.4 + random.nextDouble() * 0.55;
      final int correctItems = (totalItems * targetAccuracy).round().clamp(0, totalItems);
      final ref = _db.collection('gameSessions').doc('${patientId}_perf_seed_session_$i');
      batch.set(ref, {
        'patientId': patientId,
        'gameId': game.id,
        'gameSet': game.gameSet,
        'difficultyLevel': 1 + random.nextInt(3),
        'totalItems': totalItems,
        'correctItems': correctItems,
        'accuracy': totalItems == 0 ? 0.0 : correctItems / totalItems,
        'hintsUsed': random.nextInt(4),
        'durationSeconds': 40 + random.nextInt(80),
        'completedAt': Timestamp.fromDate(completedAt),
      });
    }

    for (int i = 0; i < _seedTaskCount; i++) {
      final String category = _seedCategories[i % _seedCategories.length];
      final DateTime due = now.subtract(Duration(days: random.nextInt(30)));
      final bool completed = random.nextDouble() < 0.75;
      final ref = _db.collection('tasks').doc('${patientId}_perf_seed_task_$i');
      batch.set(ref, {
        'patientId': patientId,
        'title': 'Demo seeded task ${i + 1}',
        'category': category,
        'dueDate': Timestamp.fromDate(due),
        'description': 'Fabricated by the performance dashboard demo seed tool.',
        'dosage': null,
        'status': completed ? 'completed' : 'missed',
        'createdAt': Timestamp.fromDate(due),
        RecurrenceTypeX.firestoreField: RecurrenceType.none.firestoreValue,
        'recurrenceRule': null,
        'endDate': null,
        'reminderIntervalMinutes': defaultReminderIntervalMinutes,
      });
    }

    await batch.commit();
  }

  /// Deletes exactly what [seedDemoPerformanceData] created, by the same
  /// deterministic ids — no query/scan needed since both sides agree on
  /// the id scheme and the fixed counts.
  Future<void> clearDemoPerformanceData(String patientId) async {
    final WriteBatch batch = _db.batch();
    for (int i = 0; i < _seedSessionCount; i++) {
      batch.delete(_db.collection('gameSessions').doc('${patientId}_perf_seed_session_$i'));
    }
    for (int i = 0; i < _seedTaskCount; i++) {
      batch.delete(_db.collection('tasks').doc('${patientId}_perf_seed_task_$i'));
    }
    await batch.commit();
  }
}

class _Session {
  final String gameId;
  final double accuracy;
  final int hintsUsed;
  final DateTime completedAt;
  const _Session({
    required this.gameId,
    required this.accuracy,
    required this.hintsUsed,
    required this.completedAt,
  });
}

class _SessionStats {
  final KpiValue accuracyKpi;
  final KpiValue sessionsKpi;
  final KpiValue hintsKpi;
  final List<ChartPoint> dailyAccuracy;
  final List<ChartPoint> dailySessions;
  final List<ChartPoint> dailyHints;
  final List<GameBar> accuracyByGame;
  const _SessionStats({
    required this.accuracyKpi,
    required this.sessionsKpi,
    required this.hintsKpi,
    required this.dailyAccuracy,
    required this.dailySessions,
    required this.dailyHints,
    required this.accuracyByGame,
  });
}

class _TaskOccurrence {
  final DateTime date;
  final String category;
  final String status;
  const _TaskOccurrence({required this.date, required this.category, required this.status});
}

class _TaskStats {
  final KpiValue completionRateKpi;
  final List<CategoryBar> tasksByCategory;
  const _TaskStats({required this.completionRateKpi, required this.tasksByCategory});
}

class _StreakInfo {
  final int streakPoints;
  final int currentStreak;
  const _StreakInfo({required this.streakPoints, required this.currentStreak});
}
