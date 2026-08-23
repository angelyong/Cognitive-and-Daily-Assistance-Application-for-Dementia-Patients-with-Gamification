import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/models/occurrence_status.dart';
import 'package:testproject/models/streak_data.dart';
import 'package:testproject/models/task_recurrence.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/services/streak_service.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/widgets/SideDrawer.dart';
import 'package:testproject/widgets/timeline_card.dart' show categoryDotColor, formatCardTime;

/// Redesigned to match the reference layout: a gradient streak-count card,
/// a real CALENDAR-WEEK view (Mon-Sun, today highlighted) rather than the
/// old abstract "day N of a 7-day reward cycle" strip, two stat cards
/// (points/level), and a new "Keep the streak" section listing today's
/// still-pending tasks — reusing the same today-visibility +
/// recurring-occurrence-aware live status pattern PatientDashboard/
/// HomeScreen/SideDrawer's patient body all already use (see
/// [_visibleDocsToday]/[_withResolvedTasks]'s own doc comments).
///
/// [StreakData] only stores currentStreak/longestStreak/lastLoginDate — it
/// has no record of exactly WHICH past calendar days were logged in. The
/// week view below derives "done" days from that: the last [currentStreak]
/// consecutive days ending today (if already logged in today) or
/// yesterday (if not yet) are the completed ones — correct as long as the
/// streak hasn't reset mid-week, which is the only case this app tracks.
class StreakScreen extends StatelessWidget {
  const StreakScreen({super.key});

  // Not a field initializer (this widget stays const-constructible, per
  // main.dart's `const StreakScreen()` call site) — FirestoreService()
  // isn't a const constructor, so it's created fresh where needed instead.
  FirestoreService get _firestoreService => FirestoreService();

  @override
  Widget build(BuildContext context) {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: AppColors.bgDark,
      drawer: const SideDrawer(),
      appBar: AppBar(
        title: const Text('Streak Progress', style: TextStyle(color: Colors.white)),
        backgroundColor: AppColors.bgDark,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: uid == null
          ? const Center(
              child: Text('Not logged in', style: TextStyle(color: Colors.white)),
            )
          : StreamBuilder<StreakData>(
              stream: StreakService().watchStreak(uid),
              builder: (context, streakSnapshot) {
                if (streakSnapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: AppColors.orangeStart),
                  );
                }
                final StreakData streak = streakSnapshot.data ?? StreakData.empty;

                return StreamBuilder<QuerySnapshot>(
                  stream: _firestoreService.getTasksForPatient(uid),
                  builder: (context, taskSnapshot) {
                    final allDocs = taskSnapshot.data?.docs.cast<QueryDocumentSnapshot>() ??
                        <QueryDocumentSnapshot>[];
                    final visibleDocs = _visibleDocsToday(allDocs);

                    return _withResolvedTasks(visibleDocs, 0, const [], (doneCount, pendingItems) {
                      final int total = visibleDocs.length;
                      return SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildStreakCard(streak),
                            const SizedBox(height: 20),
                            _buildWeekCard(streak),
                            const SizedBox(height: 20),
                            _buildStatsRow(streak),
                            if (total > 0) ...[
                              const SizedBox(height: 20),
                              _buildKeepStreakCard(doneCount, total, pendingItems),
                            ],
                          ],
                        ),
                      );
                    });
                  },
                );
              },
            ),
    );
  }

  // ==========================================================================
  // Today's tasks — same visibility/status pattern as PatientDashboard/
  // HomeScreen/SideDrawer's patient body (see their own identical methods).
  // ==========================================================================

  DateTime? _todaysOccurrence(TaskSeries series) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final occurrences = getOccurrencesForDateRange(series, todayStart, todayEnd);
    return occurrences.isEmpty ? null : occurrences.first;
  }

  List<QueryDocumentSnapshot> _visibleDocsToday(List<QueryDocumentSnapshot> docs) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = todayStart.add(const Duration(days: 1));
    return docs.where((d) {
      final data = d.data() as Map<String, dynamic>;
      final dueTs = data['dueDate'];
      if (dueTs is! Timestamp) return true; // Anytime
      final series = TaskSeries.fromDoc(d);
      if (series.recurrenceType == RecurrenceType.none) {
        final DateTime due = dueTs.toDate();
        return !due.isBefore(todayStart) && due.isBefore(todayEnd);
      }
      return _todaysOccurrence(series) != null;
    }).toList();
  }

  /// Recursively wraps one StreamBuilder per recurring doc (reading its
  /// LIVE per-occurrence status, same as elsewhere) to resolve every
  /// visible doc's completion state, folding the running (doneCount,
  /// stillPendingItems) tuple as it goes — then calls [builder] once
  /// every doc has been accounted for. Non-recurring/Anytime docs resolve
  /// synchronously off their own top-level `status` field (the correct
  /// source of truth for them), no stream needed.
  Widget _withResolvedTasks(
    List<QueryDocumentSnapshot> remainingDocs,
    int doneCount,
    List<_TaskItem> pendingItems,
    Widget Function(int doneCount, List<_TaskItem> pendingItems) builder,
  ) {
    if (remainingDocs.isEmpty) return builder(doneCount, pendingItems);

    final doc = remainingDocs.first;
    final rest = remainingDocs.sublist(1);
    final data = doc.data() as Map<String, dynamic>;
    final String title = (data['title'] ?? '') as String;
    final String category = (data['category'] ?? '') as String;
    final dueTs = data['dueDate'];

    if (dueTs is! Timestamp) {
      // Anytime task — no due date, so no occurrence stream applies; use
      // the raw stored status directly.
      final bool done = (data['status'] ?? 'pending') == 'completed';
      return _withResolvedTasks(
        rest,
        done ? doneCount + 1 : doneCount,
        done ? pendingItems : [...pendingItems, _TaskItem(title: title, category: category, time: null)],
        builder,
      );
    }

    final series = TaskSeries.fromDoc(doc);
    if (series.recurrenceType == RecurrenceType.none) {
      final bool done = (data['status'] ?? 'pending') == 'completed';
      return _withResolvedTasks(
        rest,
        done ? doneCount + 1 : doneCount,
        done
            ? pendingItems
            : [...pendingItems, _TaskItem(title: title, category: category, time: dueTs.toDate())],
        builder,
      );
    }

    // Recurring: _visibleDocsToday already guarantees an occurrence today.
    final DateTime occurrenceDate = _todaysOccurrence(series)!;
    final int intervalMinutes = _firestoreService.reminderIntervalMinutesOf(data);
    return StreamBuilder<String>(
      stream: _firestoreService.getOccurrenceStatusStream(doc.id, occurrenceDate),
      builder: (context, snapshot) {
        final String status = effectiveStatus(
          storedStatus: snapshot.data ?? 'pending',
          dueDate: occurrenceDate,
          reminderIntervalMinutes: intervalMinutes,
        );
        final bool done = status == 'completed';
        return _withResolvedTasks(
          rest,
          done ? doneCount + 1 : doneCount,
          done
              ? pendingItems
              : [...pendingItems, _TaskItem(title: title, category: category, time: occurrenceDate)],
          builder,
        );
      },
    );
  }

  // ==========================================================================
  // Visual sections
  // ==========================================================================

  Widget _buildStreakCard(StreakData streak) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.orangeStart, AppColors.orangeEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.22),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.local_fire_department, color: Colors.white, size: 30),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: '${streak.currentStreak}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const TextSpan(
                        text: '  day streak',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Best so far: ${streak.longestStreak} days',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _buildWeekCard(StreakData streak) {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime weekStart = today.subtract(Duration(days: today.weekday - 1));

    final bool loggedInToday =
        streak.lastLoginDate != null && _isSameDate(streak.lastLoginDate!, today);
    final DateTime streakEnd = loggedInToday ? today : today.subtract(const Duration(days: 1));
    final DateTime streakStart = streak.currentStreak == 0
        ? streakEnd.add(const Duration(days: 1)) // empty range
        : streakEnd.subtract(Duration(days: streak.currentStreak - 1));

    const List<String> labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    int doneThisWeek = 0;

    final List<Widget> dayWidgets = List.generate(7, (i) {
      final DateTime date = weekStart.add(Duration(days: i));
      final bool isToday = _isSameDate(date, today);
      final bool isDone = streak.currentStreak > 0 &&
          !date.isBefore(streakStart) &&
          !date.isAfter(streakEnd);
      if (isDone) doneThisWeek++;

      return Column(
        children: [
          Text(
            labels[i],
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDone ? AppColors.orangeEnd : AppColors.cardPurpleLight,
              border: (isToday && !isDone) ? Border.all(color: AppColors.orangeEnd, width: 2) : null,
            ),
            child: isDone
                ? const Icon(Icons.check, color: Colors.white, size: 16)
                : Text(
                    '${date.day}',
                    style: TextStyle(
                      color: isToday ? AppColors.orangeEnd : AppColors.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ],
      );
    });

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardPurple,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'This week',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Text(
                '$doneThisWeek of 7 days',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: dayWidgets),
          const SizedBox(height: 14),
          if (!loggedInToday)
            Row(
              children: [
                const Icon(Icons.bolt, color: AppColors.orangeStart, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Finish today to earn +${StreakData.pointsForStreakDay(streak.currentStreak + 1)} points',
                  style: const TextStyle(
                    color: AppColors.orangeStart,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            )
          else
            const Row(
              children: [
                Icon(Icons.check_circle, color: AppColors.greenCheck, size: 16),
                SizedBox(width: 6),
                Text(
                  "You're checked in for today!",
                  style: TextStyle(
                    color: AppColors.greenCheck,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildStatsRow(StreakData streak) {
    final int pointsToNext = 50 - (streak.totalPoints % 50);
    return Row(
      children: [
        Expanded(
          child: _statCard(
            icon: Icons.emoji_events,
            label: 'POINTS',
            value: '${streak.totalPoints}',
            subtitle: '$pointsToNext to next level',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _statCard(
            icon: Icons.shield,
            label: 'LEVEL',
            value: '${streak.level}',
            subtitle: _levelName(streak.level),
          ),
        ),
      ],
    );
  }

  String _levelName(int level) {
    switch (level) {
      case 1:
        return 'Getting started';
      case 2:
        return 'Building momentum';
      case 3:
        return 'Staying consistent';
      case 4:
        return 'On a roll';
      default:
        return 'Streak master';
    }
  }

  Widget _statCard({
    required IconData icon,
    required String label,
    required String value,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardPurple,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.orangeStart, size: 16),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildKeepStreakCard(int doneCount, int total, List<_TaskItem> pendingItems) {
    final double progress = total == 0 ? 0 : doneCount / total;
    // Capped so this card can't grow unbounded on a day with many tasks —
    // the progress bar/count above still reflects the true total.
    final displayed = pendingItems.take(5).toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardPurple,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Keep the streak',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Text(
                '$doneCount of $total done',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: AppColors.cardPurpleLight,
              valueColor: const AlwaysStoppedAnimation(AppColors.orangeEnd),
            ),
          ),
          const SizedBox(height: 14),
          if (displayed.isEmpty)
            const Text(
              'All done for today! 🎉',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            )
          else
            ...displayed.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: categoryDotColor(item.category).withOpacity(0.18),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(_categoryIcon(item.category),
                            color: categoryDotColor(item.category), size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          item.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        item.time != null ? formatCardTime(item.time!) : 'Anytime',
                        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                )),
        ],
      ),
    );
  }

  IconData _categoryIcon(String category) {
    switch (category.toLowerCase()) {
      case 'medication':
        return Icons.medication;
      case 'exercise':
        return Icons.directions_run;
      case 'meal':
        return Icons.restaurant;
      case 'hygiene':
        return Icons.clean_hands;
      case 'social':
        return Icons.people_alt;
      case 'appointment':
        return Icons.event;
      default:
        return Icons.notifications_active;
    }
  }
}

class _TaskItem {
  final String title;
  final String category;
  final DateTime? time; // null = Anytime
  const _TaskItem({required this.title, required this.category, required this.time});
}
