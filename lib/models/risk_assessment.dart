import 'package:cloud_firestore/cloud_firestore.dart';

/// PART 2 — Patient Risk Indicator
/// (adaptive_difficulty_and_risk_indicator_prompt.md).
///
/// A caregiver-only red warning badge shown next to a patient's name when
/// THREE independent risk signals are true AT THE SAME TIME:
///   1. missedTasks  — the patient's most recent 3 task occurrences (in
///      date order, across both one-off and recurring tasks) were all
///      missed.
///   2. scoreDrop    — average game-session accuracy over the last 5
///      sessions is >=20% lower than the previous 5 (across ALL games —
///      this is about the patient's overall cognitive trend, not any one
///      game — and only evaluated once >=10 total sessions exist).
///   3. inactivity   — >=3 days since the patient's last recorded activity
///      (a game session or an app login).
/// A graded scale, not a single strict-AND boolean: all THREE signals →
/// [atRisk] (red), exactly TWO → [monitor] (amber, an earlier/softer
/// heads-up), zero or one → [none]. The red 3-of-3 alert keeps the original
/// "require real evidence, never false-alarm on one bad day" spirit; the
/// amber tier only ADDS an early-warning state that used to be invisible
/// (a 2-of-3 patient previously looked identical to a 0-of-3 one).
enum RiskLevel { none, monitor, atRisk }

extension RiskLevelX on RiskLevel {
  static const String firestoreField = 'currentRiskLevel';

  static RiskLevel fromFirestore(String? value) {
    switch (value) {
      case 'at_risk':
        return RiskLevel.atRisk;
      case 'monitor':
        return RiskLevel.monitor;
      default:
        return RiskLevel.none;
    }
  }

  String get firestoreValue {
    switch (this) {
      case RiskLevel.atRisk:
        return 'at_risk';
      case RiskLevel.monitor:
        return 'monitor';
      case RiskLevel.none:
        return 'none';
    }
  }
}

/// Supporting stats behind [RiskAssessment.level] — feeds the caregiver's
/// tap-to-see-breakdown dialog so "at risk" is never a black box.
class RiskSignals {
  final bool missedTasks;
  final int consecutiveMissedCount;
  final bool scoreDrop;
  final double? scoreDropPercent; // e.g. 0.23 == 23% drop
  final int sessionsConsidered; // out of the >=10 required to evaluate
  final bool inactivity;
  final int? inactivityDays;

  const RiskSignals({
    required this.missedTasks,
    required this.consecutiveMissedCount,
    required this.scoreDrop,
    required this.scoreDropPercent,
    required this.sessionsConsidered,
    required this.inactivity,
    required this.inactivityDays,
  });

  static const RiskSignals empty = RiskSignals(
    missedTasks: false,
    consecutiveMissedCount: 0,
    scoreDrop: false,
    scoreDropPercent: null,
    sessionsConsidered: 0,
    inactivity: false,
    inactivityDays: null,
  );

  factory RiskSignals.fromMap(Map<String, dynamic>? map) {
    if (map == null) return empty;
    return RiskSignals(
      missedTasks: (map['missedTasks'] as bool?) ?? false,
      consecutiveMissedCount: (map['consecutiveMissedCount'] as num?)?.toInt() ?? 0,
      scoreDrop: (map['scoreDrop'] as bool?) ?? false,
      scoreDropPercent: (map['scoreDropPercent'] as num?)?.toDouble(),
      sessionsConsidered: (map['sessionsConsidered'] as num?)?.toInt() ?? 0,
      inactivity: (map['inactivity'] as bool?) ?? false,
      inactivityDays: (map['inactivityDays'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toMap() => {
        'missedTasks': missedTasks,
        'consecutiveMissedCount': consecutiveMissedCount,
        'scoreDrop': scoreDrop,
        'scoreDropPercent': scoreDropPercent,
        'sessionsConsidered': sessionsConsidered,
        'inactivity': inactivity,
        'inactivityDays': inactivityDays,
      };

  bool get allThree => missedTasks && scoreDrop && inactivity;

  /// How many of the 3 signals are currently active (0..3).
  int get metCount =>
      (missedTasks ? 1 : 0) + (scoreDrop ? 1 : 0) + (inactivity ? 1 : 0);

  /// The graded level these signals map to: 3 → at-risk, 2 → monitor,
  /// 0-1 → none. Single source of truth for the none/monitor/at-risk cutoffs.
  RiskLevel get level {
    if (metCount >= 3) return RiskLevel.atRisk;
    if (metCount == 2) return RiskLevel.monitor;
    return RiskLevel.none;
  }
}

/// Cached read model for `users/{patientId}`'s `currentRiskLevel` /
/// `riskEvaluatedAt` / `riskSignals` fields. The UI always reads this
/// cache (via [RiskService.watchAssessment]) rather than recomputing the 3
/// signals itself — [RiskService.evaluateAndCache] is the only thing that
/// (re)computes them.
class RiskAssessment {
  final RiskLevel level;
  final RiskSignals signals;
  final DateTime? evaluatedAt;

  const RiskAssessment({
    required this.level,
    required this.signals,
    required this.evaluatedAt,
  });

  static const RiskAssessment initial = RiskAssessment(
    level: RiskLevel.none,
    signals: RiskSignals.empty,
    evaluatedAt: null,
  );

  factory RiskAssessment.fromMap(Map<String, dynamic>? map) {
    if (map == null) return initial;
    final ts = map['riskEvaluatedAt'];
    return RiskAssessment(
      level: RiskLevelX.fromFirestore(map[RiskLevelX.firestoreField] as String?),
      signals: RiskSignals.fromMap(map['riskSignals'] as Map<String, dynamic>?),
      evaluatedAt: ts is Timestamp ? ts.toDate() : null,
    );
  }
}
