import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a patient's gamification streak state.
class StreakData {
  final int currentStreak;
  final int longestStreak;
  final int totalPoints;
  final DateTime? lastLoginDate;

  const StreakData({
    required this.currentStreak,
    required this.longestStreak,
    required this.totalPoints,
    required this.lastLoginDate,
  });

  /// Position within the 7 day reward cycle (1 to 7).
  /// Day 8 loops back to 1.
  int get dayInCycle =>
      currentStreak == 0 ? 0 : ((currentStreak - 1) % 7) + 1;

  /// Level derived from total points (every 50 points is one level).
  int get level => (totalPoints ~/ 50) + 1;

  /// Points awarded for a given streak day.
  /// Day 1 gives 1 point, day 7 gives 7 points, day 8 loops back to 1.
  static int pointsForStreakDay(int streakDay) =>
      ((streakDay - 1) % 7) + 1;

  factory StreakData.fromMap(Map<String, dynamic> data) {
    final ts = data['lastLoginDate'];
    return StreakData(
      currentStreak: (data['currentStreak'] ?? 0) as int,
      longestStreak: (data['longestStreak'] ?? 0) as int,
      totalPoints: (data['streakPoints'] ?? 0) as int,
      lastLoginDate: ts is Timestamp ? ts.toDate() : null,
    );
  }

  static const StreakData empty = StreakData(
    currentStreak: 0,
    longestStreak: 0,
    totalPoints: 0,
    lastLoginDate: null,
  );
}

/// The outcome of a login streak check.
class StreakResult {
  final bool awarded;      // true only if points were given this login
  final int pointsEarned;
  final StreakData data;

  const StreakResult({
    required this.awarded,
    required this.pointsEarned,
    required this.data,
  });
}