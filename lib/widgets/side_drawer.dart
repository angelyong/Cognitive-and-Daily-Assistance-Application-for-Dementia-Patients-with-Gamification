import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/occurrence_status.dart';
import '../models/streak_data.dart';
import '../models/task_recurrence.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../services/streak_service.dart';

import '../theme/app_colors.dart';

/// homescreen_cleanup_timezone_sidebar_prompt.md, Fix 3 + follow-up: both
/// the caregiver AND patient drawers use the same stat-header + grouped-
/// section style now — see [_CaregiverDrawerBody]/[_PatientDrawerBody].
/// Already role-aware before Fix 3 (fetches the user's role once); that
/// part wasn't restructured, just extended.
class SideDrawer extends StatelessWidget {
  const SideDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Drawer(child: SizedBox.shrink());

    return Drawer(
      backgroundColor: AppColors.bgDark,
      child: FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
        builder: (context, snapshot) {
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.orangeStart),
            );
          }
          final data = snapshot.data!.data() as Map<String, dynamic>;
          final bool isCaregiver = data['role'] == 'caregiver';

          return isCaregiver
              ? _CaregiverDrawerBody(caregiverId: user.uid, email: user.email ?? '')
              : _PatientDrawerBody(patientId: user.uid, email: user.email ?? '');
        },
      ),
    );
  }
}

/// Same stat-header + grouped-section style as the caregiver drawer, with
/// patient-relevant stats/items instead — "TODAY" (this patient's own task
/// completion) + "DAY STREAK" (their login streak) in the header, and only
/// the routes a patient actually has: Dashboard/Streak Progress/Cognitive
/// Games under DAILY, Settings under ACCOUNT. No Create Task/Task History/
/// Activity Progress/Manage Patient — those stay caregiver-only.
///
/// No Logout item here (unlike the caregiver drawer) — for a dementia
/// patient, a swipe-open drawer with Logout one tap away is an easy
/// accidental hit. It's been moved to a deliberate icon in the top-right
/// of SettingsScreen instead, patient-role only (see that screen), using
/// the same [showLogoutConfirmation] this drawer uses for the caregiver.
///
/// BUGFIX: the "TODAY" stat used to be a one-shot Future computed once
/// when the drawer's State was first created, and its counting logic
/// disagreed with PatientDashboard's own "today" list (it skipped
/// Anytime tasks and every recurring task entirely, undercounting the
/// total; PatientDashboard separately had its own bug inflating its total
/// — see that screen's `_visibleDocs` fix). Rebuilt below as a live
/// StreamBuilder tree using the exact same visibility + completion rules
/// PatientDashboard uses, so the two numbers always agree and ticking a
/// task updates this header immediately, the same tick after tick that
/// already works on the dashboard's own progress card.
class _PatientDrawerBody extends StatefulWidget {
  final String patientId;
  final String email;
  const _PatientDrawerBody({required this.patientId, required this.email});

  @override
  State<_PatientDrawerBody> createState() => _PatientDrawerBodyState();
}

class _PatientDrawerBodyState extends State<_PatientDrawerBody> {
  final FirestoreService _firestoreService = FirestoreService();

  /// Today's occurrence of [series], if it has one — mirrors
  /// PatientDashboard's identical private method (same reasoning: a
  /// recurring series that simply doesn't recur today has none).
  DateTime? _todaysOccurrence(TaskSeries series) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final occurrences = getOccurrencesForDateRange(series, todayStart, todayEnd);
    return occurrences.isEmpty ? null : occurrences.first;
  }

  /// Same visibility rule as PatientDashboard._visibleDocs: Anytime (no
  /// due date), OR a non-recurring task due today, OR a recurring series
  /// that actually recurs today.
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

  /// Recursively wraps one StreamBuilder per recurring doc, each reading
  /// that occurrence's LIVE status and folding completion into [acc],
  /// until every doc is accounted for — same N-nested-StreamBuilders
  /// pattern PatientDashboard/HomeScreen already use to combine several
  /// independent streams into one derived value.
  Widget _withRecurringDoneTally(
    List<QueryDocumentSnapshot> remainingDocs,
    int acc,
    Widget Function(int doneCount) builder,
  ) {
    if (remainingDocs.isEmpty) return builder(acc);

    final doc = remainingDocs.first;
    final rest = remainingDocs.sublist(1);
    final data = doc.data() as Map<String, dynamic>;
    final series = TaskSeries.fromDoc(doc);
    // remainingDocs is already filtered to occurrence-today docs, so this
    // is never null in practice.
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
        return _withRecurringDoneTally(rest, acc + (status == 'completed' ? 1 : 0), builder);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? currentRoute = ModalRoute.of(context)?.settings.name;

    return SafeArea(
      child: StreamBuilder<QuerySnapshot>(
        stream: _firestoreService.getTasksForPatient(widget.patientId),
        builder: (context, taskSnapshot) {
          final allDocs =
              taskSnapshot.data?.docs.cast<QueryDocumentSnapshot>() ?? <QueryDocumentSnapshot>[];
          final visibleDocs = _visibleDocsToday(allDocs);

          final recurringDocs = visibleDocs.where((d) {
            final data = d.data() as Map<String, dynamic>;
            if (data['dueDate'] is! Timestamp) return false; // Anytime, can't recur
            return TaskSeries.fromDoc(d).recurrenceType != RecurrenceType.none;
          }).toList();

          final int nonRecurringDone = visibleDocs.where((d) {
            final data = d.data() as Map<String, dynamic>;
            if (data['dueDate'] is Timestamp &&
                TaskSeries.fromDoc(d).recurrenceType != RecurrenceType.none) {
              return false; // recurring — counted live via _withRecurringDoneTally instead
            }
            return data['status'] == 'completed';
          }).length;

          final int todayTotal = visibleDocs.length;

          return StreamBuilder<StreakData>(
            stream: StreakService().watchStreak(widget.patientId),
            builder: (context, streakSnapshot) {
              final int currentStreak = streakSnapshot.data?.currentStreak ?? 0;

              return _withRecurringDoneTally(recurringDocs, nonRecurringDone, (todayCompleted) {
                return Column(
                  children: [
                    _DrawerHeader(
                      email: widget.email,
                      statAValue: '$todayCompleted/$todayTotal',
                      statALabel: 'TODAY',
                      statBValue: '$currentStreak',
                      statBLabel: 'DAY STREAK',
                    ),
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          const SizedBox(height: 4),
                          _sectionLabel('DAILY'),
                          _navItem(
                            context,
                            icon: Icons.home_rounded,
                            label: 'Dashboard',
                            route: '/patientdashboard',
                            isActive: currentRoute == '/patientdashboard',
                          ),
                          _navItem(
                            context,
                            icon: Icons.local_fire_department,
                            label: 'Streak Progress',
                            route: '/streak',
                            isActive: currentRoute == '/streak',
                          ),
                          _navItem(
                            context,
                            icon: Icons.sports_esports,
                            label: 'Cognitive Games',
                            route: '/cognitive',
                            isActive: currentRoute == '/cognitive',
                          ),
                          _sectionLabel('ACCOUNT'),
                          _navItem(
                            context,
                            icon: Icons.settings_outlined,
                            label: 'Settings',
                            route: '/settings',
                            isActive: currentRoute == '/settings',
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              });
            },
          );
        },
      ),
    );
  }
}

/// Shared by both drawer bodies, and by SettingsScreen's patient-only
/// logout icon (see that screen) — one confirmation dialog + sign-out
/// flow, not duplicated per call site.
Future<void> showLogoutConfirmation(BuildContext context) async {
  final bool? confirm = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: AppColors.cardPurple,
        title: const Text('Logout', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to logout?',
          style: TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.orangeEnd,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Logout'),
          ),
        ],
      );
    },
  );

  if (confirm != true) return;

  final AuthResult<void> result = await AuthService().logout();
  if (!context.mounted) return;

  if (result.success) {
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.error ?? 'Logout failed.')),
    );
  }
}

class _CaregiverDrawerBody extends StatefulWidget {
  final String caregiverId;
  final String email;
  const _CaregiverDrawerBody({required this.caregiverId, required this.email});

  @override
  State<_CaregiverDrawerBody> createState() => _CaregiverDrawerBodyState();
}

/// BUGFIX: the "TODAY" stat used to be a one-shot Future computed once when
/// the drawer's State was first created (see git history for the old
/// `_loadCaregiverStats`), built on FirestoreService.getTasks — the
/// original +/-3-day-window query, since superseded on HomeScreen itself by
/// getAllTasksForCaregiver's occurrence-aware version (see
/// fix_recurring_task_homescreen_visibility.md) — narrowed further to "due
/// today," which skipped Anytime tasks and every recurring task entirely,
/// and never updated when a task got ticked. Rebuilt below as a live
/// StreamBuilder tree, same pattern as the patient drawer / HomeScreen:
/// getAllTasksForCaregiver (unbounded, all patients) -> today-only
/// visibility filter -> live per-occurrence tally for recurring docs. Patient
/// count is now live too (getPatientsStream) at no extra cost, though that
/// half was never the reported bug.
class _CaregiverDrawerBodyState extends State<_CaregiverDrawerBody> {
  final FirestoreService _firestoreService = FirestoreService();

  /// Today's occurrence of [series], if it has one — mirrors
  /// HomeScreen's/PatientDashboard's identical private method.
  DateTime? _todaysOccurrence(TaskSeries series) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final occurrences = getOccurrencesForDateRange(series, todayStart, todayEnd);
    return occurrences.isEmpty ? null : occurrences.first;
  }

  /// BUGFIX: this used to mirror the PATIENT drawer/PatientDashboard's
  /// visibility rule (include Anytime tasks, non-recurring due strictly
  /// today) — but the caregiver's own "Today" list on HomeScreen uses a
  /// DIFFERENT rule (see HomeScreen._visibleDocs): it excludes Anytime
  /// tasks entirely, and includes non-recurring tasks overdue-but-still-
  /// pending from up to [FirestoreService.homeWindowDays] days back, not
  /// just ones due exactly today. Using the wrong rule here made this
  /// stat disagree with what HomeScreen actually displays either way
  /// (over-counting Anytime tasks HomeScreen never shows, under-counting
  /// older still-pending catch-up items HomeScreen does show). Now matches
  /// HomeScreen._visibleDocs exactly so the two numbers always agree.
  List<QueryDocumentSnapshot> _visibleDocsToday(List<QueryDocumentSnapshot> docs) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final windowStart =
        todayStart.subtract(const Duration(days: FirestoreService.homeWindowDays));
    final todayEnd = todayStart.add(const Duration(days: 1));
    return docs.where((d) {
      final data = d.data() as Map<String, dynamic>;
      final dueTs = data['dueDate'];
      if (dueTs is! Timestamp) return false; // Anytime — HomeScreen never shows these
      final series = TaskSeries.fromDoc(d);
      if (series.recurrenceType == RecurrenceType.none) {
        final DateTime due = dueTs.toDate();
        return !due.isBefore(windowStart) && due.isBefore(todayEnd);
      }
      return _todaysOccurrence(series) != null;
    }).toList();
  }

  /// Recursively wraps one StreamBuilder per recurring doc, each reading
  /// that occurrence's LIVE status and folding completion into [acc] —
  /// same N-nested-StreamBuilders pattern used throughout.
  Widget _withRecurringDoneTally(
    List<QueryDocumentSnapshot> remainingDocs,
    int acc,
    Widget Function(int doneCount) builder,
  ) {
    if (remainingDocs.isEmpty) return builder(acc);

    final doc = remainingDocs.first;
    final rest = remainingDocs.sublist(1);
    final data = doc.data() as Map<String, dynamic>;
    final series = TaskSeries.fromDoc(doc);
    // remainingDocs is already filtered to occurrence-today docs, so this
    // is never null in practice.
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
        return _withRecurringDoneTally(rest, acc + (status == 'completed' ? 1 : 0), builder);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? currentRoute = ModalRoute.of(context)?.settings.name;

    return SafeArea(
      child: StreamBuilder<QuerySnapshot>(
        stream: _firestoreService.getPatientsStream(widget.caregiverId),
        builder: (context, patientSnapshot) {
          final int patientCount = patientSnapshot.data?.docs.length ?? 0;

          return StreamBuilder<QuerySnapshot>(
            stream: _firestoreService.getAllTasksForCaregiver(widget.caregiverId),
            builder: (context, taskSnapshot) {
              final allDocs = taskSnapshot.data?.docs.cast<QueryDocumentSnapshot>() ??
                  <QueryDocumentSnapshot>[];
              final visibleDocs = _visibleDocsToday(allDocs);

              final recurringDocs = visibleDocs.where((d) {
                final data = d.data() as Map<String, dynamic>;
                if (data['dueDate'] is! Timestamp) return false; // Anytime, can't recur
                return TaskSeries.fromDoc(d).recurrenceType != RecurrenceType.none;
              }).toList();

              final int nonRecurringDone = visibleDocs.where((d) {
                final data = d.data() as Map<String, dynamic>;
                if (data['dueDate'] is Timestamp &&
                    TaskSeries.fromDoc(d).recurrenceType != RecurrenceType.none) {
                  return false; // recurring — counted live via _withRecurringDoneTally instead
                }
                return data['status'] == 'completed';
              }).length;

              final int todayTotal = visibleDocs.length;

              return _withRecurringDoneTally(recurringDocs, nonRecurringDone, (todayCompleted) {
                return Column(
                  children: [
                    _DrawerHeader(
                      email: widget.email,
                      statAValue: '$todayCompleted/$todayTotal',
                      statALabel: 'TODAY',
                      statBValue: '$patientCount',
                      statBLabel: 'PATIENTS',
                    ),
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          const SizedBox(height: 4),
                          _sectionLabel('DAILY'),
                          _navItem(
                            context,
                            icon: Icons.home_rounded,
                            label: 'Dashboard',
                            route: '/homescreen',
                            isActive: currentRoute == '/homescreen',
                          ),
                          _navItem(
                            context,
                            icon: Icons.edit_calendar_outlined,
                            label: 'Create Task',
                            route: '/createtask',
                            isActive: currentRoute == '/createtask',
                          ),
                          _navItem(
                            context,
                            icon: Icons.history,
                            label: 'Task History',
                            route: '/taskhistory',
                            isActive: currentRoute == '/taskhistory',
                          ),
                          _sectionLabel('INSIGHTS'),
                          _navItem(
                            context,
                            icon: Icons.bar_chart_rounded,
                            label: 'Activity Progress',
                            route: '/activityprogress',
                            isActive: currentRoute == '/activityprogress',
                          ),
                          _navItem(
                            context,
                            icon: Icons.insights,
                            label: 'Statistics',
                            route: '/statistics',
                            isActive: currentRoute == '/statistics',
                          ),
                          _sectionLabel('ACCOUNT'),
                          _navItem(
                            context,
                            icon: Icons.people_outline,
                            label: 'Manage Patient',
                            route: '/managepatient',
                            isActive: currentRoute == '/managepatient',
                          ),
                          _navItem(
                            context,
                            icon: Icons.settings_outlined,
                            label: 'Settings',
                            route: '/settings',
                            isActive: currentRoute == '/settings',
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: AppColors.cardPurpleLight, height: 1),
                    ListTile(
                      leading: const Icon(Icons.logout, color: AppColors.orangeEnd),
                      title: const Text(
                        'Log out',
                        style: TextStyle(color: AppColors.orangeEnd, fontWeight: FontWeight.w600),
                      ),
                      onTap: () => showLogoutConfirmation(context),
                    ),
                  ],
                );
              });
            },
          );
        },
      ),
    );
  }
}

/// Shared by both roles — [statAValue]/[statALabel] and
/// [statBValue]/[statBLabel] are generic so the caregiver drawer can show
/// "TODAY"/"PATIENTS" and the patient drawer can show "TODAY"/"DAY STREAK"
/// through the same header.
class _DrawerHeader extends StatelessWidget {
  final String email;
  final String statAValue;
  final String statALabel;
  final String statBValue;
  final String statBLabel;
  const _DrawerHeader({
    required this.email,
    required this.statAValue,
    required this.statALabel,
    required this.statBValue,
    required this.statBLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: const BoxDecoration(gradient: AppGradients.orange),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: const Icon(Icons.person_outline, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'MindCare',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                    Text(
                      email,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _statChip(statAValue, statALabel)),
              const SizedBox(width: 8),
              Expanded(child: _statChip(statBValue, statBLabel)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statChip(String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
          ),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

Widget _sectionLabel(String text) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
    child: Text(
      text,
      style: const TextStyle(
        color: AppColors.textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    ),
  );
}

Widget _navItem(
  BuildContext context, {
  required IconData icon,
  required String label,
  required String route,
  bool isActive = false,
  Widget? trailing,
}) {
  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
    decoration: BoxDecoration(
      color: isActive ? AppColors.cardPurple : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
    ),
    child: ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(icon, color: isActive ? Colors.white : AppColors.textMuted, size: 21),
      title: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: isActive ? FontWeight.w700 : FontWeight.normal,
        ),
      ),
      trailing: trailing ??
          (isActive
              ? Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.orangeStart),
                )
              : null),
      onTap: () {
        Navigator.pop(context);
        if (!isActive) Navigator.pushReplacementNamed(context, route);
      },
    ),
  );
}
