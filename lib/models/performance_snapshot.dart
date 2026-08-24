// PatientPerformanceScreen (see PERFORMANCE_DASHBOARD_PLAN.md): the
// bird's-eye, all-games-at-once dashboard, as opposed to GameStatisticScreen's
// per-game depth. This file holds the plain data shapes
// PerformanceAnalyticsService.loadSnapshot returns — the screen itself
// owns no aggregation logic, same "service decides, screen only renders"
// separation the Adaptive Difficulty Engine already has from
// GameStatisticScreen (see ADAPTIVE_DIFFICULTY_AND_STATISTICS_SCREEN.md).

/// How far back a snapshot looks. [days] is null for [allTime], which also
/// means "no previous period to compare against" — there's no meaningful
/// "the all-time period before all time."
enum PerformancePeriod { last7Days, last30Days, allTime }

extension PerformancePeriodX on PerformancePeriod {
  String get label {
    switch (this) {
      case PerformancePeriod.last7Days:
        return 'Last 7 Days';
      case PerformancePeriod.last30Days:
        return 'Last 30 Days';
      case PerformancePeriod.allTime:
        return 'All Time';
    }
  }

  int? get days {
    switch (this) {
      case PerformancePeriod.last7Days:
        return 7;
      case PerformancePeriod.last30Days:
        return 30;
      case PerformancePeriod.allTime:
        return null;
    }
  }
}

/// One KPI tile: the current period's value, and — when a previous period
/// of equal length exists to compare against — the percent change vs. it.
/// [deltaPercent] is null (shown as "—", not "0%") when there's nothing
/// meaningful to compare against, e.g. [PerformancePeriod.allTime] or a
/// previous period with zero activity.
class KpiValue {
  final double current;
  final double? previous;
  const KpiValue({required this.current, this.previous});

  double? get deltaPercent {
    final double? prev = previous;
    if (prev == null || prev == 0) return null;
    return ((current - prev) / prev) * 100;
  }

  static const KpiValue zero = KpiValue(current: 0);
}

/// One point on a daily trend line.
class ChartPoint {
  final DateTime day;
  final double value;
  const ChartPoint(this.day, this.value);
}

/// One bar in the "accuracy by game" chart.
class GameBar {
  final String gameId;
  final String label;
  final double averageAccuracy; // 0..1
  final int sessionCount;
  const GameBar({
    required this.gameId,
    required this.label,
    required this.averageAccuracy,
    required this.sessionCount,
  });
}

/// One bar in the "tasks by category" chart.
class CategoryBar {
  final String category;
  final int completedCount;
  const CategoryBar({required this.category, required this.completedCount});
}

class PerformanceSnapshot {
  final KpiValue averageAccuracy; // 0..1 scale
  final KpiValue sessionsPlayed;
  final KpiValue taskCompletionRate; // 0..1 scale
  final KpiValue averageHints;
  final int streakPoints;
  final int currentStreak;
  final List<ChartPoint> dailyAccuracy; // 0..1 scale per point
  final List<ChartPoint> dailySessions; // count per point
  final List<ChartPoint> dailyHints; // average per point
  final List<GameBar> accuracyByGame;
  final List<CategoryBar> tasksByCategory;

  const PerformanceSnapshot({
    required this.averageAccuracy,
    required this.sessionsPlayed,
    required this.taskCompletionRate,
    required this.averageHints,
    required this.streakPoints,
    required this.currentStreak,
    required this.dailyAccuracy,
    required this.dailySessions,
    required this.dailyHints,
    required this.accuracyByGame,
    required this.tasksByCategory,
  });

  static const PerformanceSnapshot empty = PerformanceSnapshot(
    averageAccuracy: KpiValue.zero,
    sessionsPlayed: KpiValue.zero,
    taskCompletionRate: KpiValue.zero,
    averageHints: KpiValue.zero,
    streakPoints: 0,
    currentStreak: 0,
    dailyAccuracy: [],
    dailySessions: [],
    dailyHints: [],
    accuracyByGame: [],
    tasksByCategory: [],
  );
}
