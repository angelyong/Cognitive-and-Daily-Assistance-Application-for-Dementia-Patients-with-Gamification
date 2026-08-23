// awardLoginStreak()
//Streak Logic

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:testproject/models/streak_data.dart';

class StreakService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Strips the time so only the calendar date is compared.
  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Called once per login. Awards points only on the first login of a day.
  Future<StreakResult> checkAndUpdateStreak(String uid) async {
    final ref = _db.collection('users').doc(uid);
    final snap = await ref.get();

    if (!snap.exists) {
      return const StreakResult(
        awarded: false,
        pointsEarned: 0,
        data: StreakData.empty,
      );
    }

    final current = StreakData.fromMap(snap.data() as Map<String, dynamic>);

    final today = _dateOnly(DateTime.now());
    final last = current.lastLoginDate == null
        ? null
        : _dateOnly(current.lastLoginDate!);

    // Already logged in today: no duplicate award.
    if (last != null && last == today) {
      return StreakResult(
        awarded: false,
        pointsEarned: 0,
        data: current,
      );
    }

    // Decide the new streak count.
    int newStreak;
    if (last == null) {
      newStreak = 1; // first ever login
    } else {
      final yesterday = today.subtract(const Duration(days: 1));
      newStreak = (last == yesterday) ? current.currentStreak + 1 : 1;
      // No grace period: any gap resets to 1.
    }

    final pointsEarned = StreakData.pointsForStreakDay(newStreak);
    final newTotal = current.totalPoints + pointsEarned;
    final newLongest =
        newStreak > current.longestStreak ? newStreak : current.longestStreak;

    await ref.update({
      'currentStreak': newStreak,
      'longestStreak': newLongest,
      'streakPoints': newTotal,
      'lastLoginDate': Timestamp.fromDate(today),
    });

    return StreakResult(
      awarded: true,
      pointsEarned: pointsEarned,
      data: StreakData(
        currentStreak: newStreak,
        longestStreak: newLongest,
        totalPoints: newTotal,
        lastLoginDate: today,
      ),
    );
  }

  /// Live stream of the user's streak, for the streak screen.
  Stream<StreakData> watchStreak(String uid) {
    return _db.collection('users').doc(uid).snapshots().map((snap) {
      if (!snap.exists) return StreakData.empty;
      return StreakData.fromMap(snap.data() as Map<String, dynamic>);
    });
  }
}