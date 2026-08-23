import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'dart:async';

import 'package:testproject/models/occurrence_status.dart';
import 'package:testproject/models/task_recurrence.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/services/notification_service.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_text_styles.dart';
import 'package:testproject/theme/app_decorations.dart';
import 'package:testproject/widgets/reminder_popup.dart';
import 'package:testproject/widgets/timeline_card.dart';
import '../../widgets/SideDrawer.dart';
import '../task_detail_screen.dart';

/// A patient's own view of their day: a single chronological timeline of
/// everything due today (see daily_routine_timeline_prompt.md) — no
/// create/edit actions, a patient can only tick things done.
///
/// PHASE 3 (see phase3_reminder_notifications_prompt.md): a recurring task
/// (Phase 2) has no single "status" of its own — each occurrence needs its
/// own state (Step 3, CRITICAL). A single (non-recurring) task keeps using
/// its legacy top-level `status` field exactly as before this phase,
/// completely unchanged. A recurring task instead: (a) only shows here at
/// all if it has an occurrence TODAY (getOccurrencesForDateRange for just
/// today), and (b) reads/writes its status via the
/// `tasks/{id}/occurrences/{yyyy-MM-dd}` subcollection
/// (FirestoreService.getOccurrenceStatusStream/setOccurrenceStatus) instead
/// of the shared doc's own status field.
///
/// DAILY ROUTINE TIMELINE (see daily_routine_timeline_prompt.md): tasks and
/// medications are merged into ONE list sorted by time, instead of two
/// separate sections — see [_buildTimelineEntries]. A task saved with no
/// due date at all (allowed for a non-recurring task — see
/// CreateTaskScreen) is deliberately still shown here, in an "Anytime"
/// slot at the end, per that doc's explicit instruction — this is a
/// conscious DEVIATION from HomeScreen's own convention of excluding such
/// tasks entirely, made only for this patient timeline.
///
/// Known scope cut: the "Today's Progress" done/total counts below only
/// tally non-recurring tasks — recurring completion needs the async
/// per-occurrence stream above, and folding that into a synchronous count
/// would be a much larger rework for a secondary display stat. Flagged in
/// the Phase 3 report, not silently dropped.
///
/// This screen also calls [NotificationService.reconcilePatientReminders]
/// on open — see that method's doc comment for why patient reminders must
/// be scheduled from the patient's OWN device/session.
class PatientDashboard extends StatefulWidget {
  const PatientDashboard({super.key});

  @override
  State<PatientDashboard> createState() => _PatientDashboardState();
}

class _PatientDashboardState extends State<PatientDashboard> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final FirestoreService _firestoreService = FirestoreService();
  final String? _uid = FirebaseAuth.instance.currentUser?.uid;

  Timer? _statusTimer;
  String? _userName;

  // In-app companion to the OS reminder notification (see ReminderPopup's
  // own doc comment): the moment a task/occurrence becomes due while the
  // patient already has this screen open, pop it up automatically. Each
  // key ("taskId|occurrenceIso") is shown at most once per dashboard
  // session — dismissing without responding doesn't re-trigger it, same
  // as ignoring the OS notification would. _popupOpen prevents stacking a
  // second dialog while one is already showing.
  final Set<String> _shownReminderKeys = {};
  bool _popupOpen = false;

  static const int _pointsPerCompletion = 2;

  @override
  void initState() {
    super.initState();
    _loadUserName();
    // Re-check task statuses every minute so overdue tasks flip to
    // "missed" automatically without the user interacting, and so the
    // "Next Up" highlight moves on as time passes.
    _statusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    // PHASE 3: (re)schedule this patient's own upcoming reminder chains —
    // see the class doc comment for why this runs here, not on the
    // caregiver's device. Fire-and-forget; a one-shot pass, not a stream.
    final String? uid = _uid;
    if (uid != null) {
      NotificationService().reconcilePatientReminders(uid);
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUserName() async {
    if (_uid == null) return;
    final name = await _firestoreService.getUserName(_uid);
    if (mounted) setState(() => _userName = name);
  }

  /// UC-05 sub-flow 8a/8b: view a task's full details, read-only (no Edit
  /// button shows for a patient — that's decided inside TaskDetailScreen
  /// itself based on role, not passed in from here).
  void _openTaskDetail(String taskId) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: taskId)),
    );
  }

  /// Non-recurring path only — see [_toggleOccurrenceStatus] for recurring.
  /// Patients can only mark a task complete, never untick it back to
  /// pending once done (the card's tick is disabled for a completed task —
  /// see [_occurrenceAwareCard] — this guard is just a defensive backstop).
  Future<void> _toggleTaskStatus(String taskId, bool isCurrentlyDone) async {
    if (isCurrentlyDone) return;
    final String? uid = _uid;
    if (uid == null) return;
    await _firestoreService.updateTaskStatus(taskId, 'completed');
    await _firestoreService.awardPoints(uid, _pointsPerCompletion);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('+2 points!'),
          duration: Duration(seconds: 1),
          backgroundColor: AppColors.orangeStart,
        ),
      );
    }
  }

  /// PHASE 3: the recurring-task equivalent of [_toggleTaskStatus] — writes
  /// to the per-occurrence subcollection instead of the shared series doc,
  /// and cancels that occurrence's remaining reminder chain (Step 6).
  /// Patients can only mark an occurrence complete, never untick it back
  /// to pending once done — same reasoning as [_toggleTaskStatus].
  Future<void> _toggleOccurrenceStatus(
    String taskId,
    DateTime occurrenceDate,
    bool isCurrentlyDone,
  ) async {
    if (isCurrentlyDone) return;
    final String? uid = _uid;
    if (uid == null) return;
    await _firestoreService.setOccurrenceStatus(taskId, occurrenceDate, 'completed');
    await _firestoreService.awardPoints(uid, _pointsPerCompletion);
    await NotificationService().cancelOccurrenceReminders(taskId, occurrenceDate);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('+2 points!'),
          duration: Duration(seconds: 1),
          backgroundColor: AppColors.orangeStart,
        ),
      );
    }
  }

  /// Today's occurrence of [series], if it has one — null for a recurring
  /// series that simply doesn't recur today (e.g. a weekly Wednesday task
  /// checked on a Tuesday).
  DateTime? _todaysOccurrence(TaskSeries series) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final occurrences = getOccurrencesForDateRange(series, todayStart, todayEnd);
    return occurrences.isEmpty ? null : occurrences.first;
  }

  /// PHASE 3 (Step 11): a pending occurrence only auto-flips to 'missed'
  /// once its reminder chain's safety cap is exhausted
  /// ([occurrence_status.missedThreshold]), not the instant its due time
  /// passes — reconciling the pre-existing immediate-flip rule with the
  /// new reminder loop, which needs the occurrence to stay 'pending' (and
  /// keep reminding) for a while after it becomes due.
  Future<void> _persistMissedStatus(List<QueryDocumentSnapshot> docs) async {
    final now = DateTime.now();
    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      // A task with no due date at all can never be "missed" (there's no
      // time to compare against) — same guard that avoids the
      // TaskSeries.fromDoc crash this had before (it hard-casts dueDate).
      if (data['dueDate'] is! Timestamp) continue;
      final int intervalMinutes = _firestoreService.reminderIntervalMinutesOf(data);
      final series = TaskSeries.fromDoc(doc);

      if (series.recurrenceType == RecurrenceType.none) {
        final stored = (data['status'] ?? 'pending').toString();
        final ts = data['dueDate'];
        if (stored == 'pending' &&
            ts is Timestamp &&
            now.isAfter(missedThreshold(ts.toDate(), intervalMinutes))) {
          await _firestoreService.updateTaskStatus(doc.id, 'missed');
        }
      } else {
        final DateTime? occurrenceDate = _todaysOccurrence(series);
        if (occurrenceDate == null) continue;
        final String stored =
            await _firestoreService.getOccurrenceStatus(doc.id, occurrenceDate);
        if (stored == 'pending' &&
            now.isAfter(missedThreshold(occurrenceDate, intervalMinutes))) {
          await _firestoreService.setOccurrenceStatus(doc.id, occurrenceDate, 'missed');
        }
      }
    }
  }

  /// A task/occurrence belongs on today's timeline if: it has no due date
  /// at all (shown as "Anytime" — see class doc comment), OR it's a single
  /// task due today (see legacy status handling below), OR it's a
  /// recurring series that actually recurs today.
  ///
  /// BUGFIX: the non-recurring branch previously returned `true`
  /// unconditionally for ANY task with a due date, regardless of whether
  /// that date was today, last month, or next year — so every one-off
  /// task ever created for this patient showed up on "today's" timeline,
  /// which is also what made the drawer's own (correctly today-scoped)
  /// task count look wrong/mismatched next to this screen's list.
  List<QueryDocumentSnapshot> _visibleDocs(List<QueryDocumentSnapshot> docs) {
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

  /// Renders [buildCard] with the right live status + toggle handler —
  /// legacy top-level status for a single task, per-occurrence subcollection
  /// for a recurring one, or the raw stored status (no time-based logic
  /// possible) for a no-due-date "Anytime" task.
  Widget _occurrenceAwareCard(
    QueryDocumentSnapshot doc,
    Map<String, dynamic> data,
    Widget Function(String status, VoidCallback? onToggle) buildCard,
  ) {
    final dueTs = data['dueDate'];
    if (dueTs is! Timestamp) {
      // Anytime task — no due date, so no occurrence math or effective-
      // status threshold applies; just the raw stored status.
      final String stored = (data['status'] ?? 'pending') as String;
      return buildCard(
        stored,
        stored == 'completed' ? null : () => _toggleTaskStatus(doc.id, false),
      );
    }

    final series = TaskSeries.fromDoc(doc);
    final int intervalMinutes = _firestoreService.reminderIntervalMinutesOf(data);

    if (series.recurrenceType == RecurrenceType.none) {
      final String stored = (data['status'] ?? 'pending') as String;
      final String status = effectiveStatus(
        storedStatus: stored,
        dueDate: dueTs.toDate(),
        reminderIntervalMinutes: intervalMinutes,
      );
      return buildCard(
        status,
        status == 'completed' ? null : () => _toggleTaskStatus(doc.id, false),
      );
    }

    // Recurring: only called for docs already filtered to "has an
    // occurrence today" (see _visibleDocs) so this is never null in practice.
    final DateTime occurrenceDate = _todaysOccurrence(series)!;
    return StreamBuilder<String>(
      stream: _firestoreService.getOccurrenceStatusStream(doc.id, occurrenceDate),
      builder: (context, snapshot) {
        final String stored = snapshot.data ?? 'pending';
        final String status = effectiveStatus(
          storedStatus: stored,
          dueDate: occurrenceDate,
          reminderIntervalMinutes: intervalMinutes,
        );
        return buildCard(
          status,
          status == 'completed'
              ? null
              : () => _toggleOccurrenceStatus(doc.id, occurrenceDate, status == 'completed'),
        );
      },
    );
  }

  /// Merges every visible doc into one chronologically-sorted list — the
  /// single source of the timeline's ordering. A doc with no due date at
  /// all sorts to the end (null sortTime), after every timed entry, in
  /// whatever order the stream returned them (no further tiebreak needed —
  /// see daily_routine_timeline_prompt.md's "Anytime" requirement).
  List<_TimelineEntry> _buildTimelineEntries(List<QueryDocumentSnapshot> docs) {
    final entries = docs.map((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final dueTs = data['dueDate'];
      if (dueTs is! Timestamp) {
        return _TimelineEntry(doc: doc, data: data, sortTime: null);
      }
      final series = TaskSeries.fromDoc(doc);
      final DateTime sortTime = series.recurrenceType == RecurrenceType.none
          ? dueTs.toDate()
          : _todaysOccurrence(series)!; // _visibleDocs guarantees non-null
      return _TimelineEntry(doc: doc, data: data, sortTime: sortTime);
    }).toList();

    entries.sort((a, b) {
      if (a.sortTime == null && b.sortTime == null) return 0;
      if (a.sortTime == null) return 1;
      if (b.sortTime == null) return -1;
      return a.sortTime!.compareTo(b.sortTime!);
    });
    return entries;
  }

  /// Auto-shows [ReminderPopup] for the first still-pending, already-due
  /// entry that hasn't been shown yet this session — the in-app companion
  /// to the OS notification (see class field doc comments).
  ///
  /// BUGFIX (NOTIFICATION_BUGS.md #1): this used to check `entry.data['status']`
  /// — the raw TASK DOC's top-level field — for every entry, including
  /// recurring ones. A recurring task's top-level `status` is written once
  /// at creation and never touched again (see class doc comment: a
  /// recurring task's real status lives per-occurrence, in the
  /// `occurrences` subcollection, via setOccurrenceStatus), so it reads
  /// 'pending' forever regardless of whether today's occurrence was
  /// actually completed via its timeline card or a notification action
  /// button — meaning this could pop up "Complete/Missed?" for an
  /// occurrence already resolved through another channel. Now awaits the
  /// LIVE per-occurrence status for recurring entries before deciding to
  /// show anything; non-recurring entries still use the (correct, since
  /// it's the actual source of truth for them) top-level field directly.
  ///
  /// BUGFIX: the OS alarm that fires this same occurrence's reminder runs
  /// completely independently of this in-app check, so — while the app is
  /// open — the system notification banner used to appear ALONGSIDE this
  /// popup instead of being replaced by it. Cancelling the occurrence's
  /// reminder chain the instant the in-app popup takes over (same call
  /// Complete/Missed already uses) dismisses that banner from the shade so
  /// only the popup remains, and stops its follow-ups from firing behind it.
  Future<void> _maybeShowDueReminder(List<_TimelineEntry> entries) async {
    final DateTime now = DateTime.now();
    for (final entry in entries) {
      // Re-checked on every iteration (not just once up front) since this
      // loop awaits — another call to this same method (triggered by a
      // different rebuild while this one is mid-await) could have shown a
      // popup in the meantime.
      if (_popupOpen) return;

      final DateTime? sortTime = entry.sortTime;
      if (sortTime == null || sortTime.isAfter(now)) continue;
      final String key = '${entry.doc.id}|${sortTime.toIso8601String()}';
      if (_shownReminderKeys.contains(key)) continue;

      final dueTs = entry.data['dueDate'];
      final bool isRecurring = dueTs is Timestamp &&
          TaskSeries.fromDoc(entry.doc).recurrenceType != RecurrenceType.none;

      final String stored = isRecurring
          ? await _firestoreService.getOccurrenceStatus(entry.doc.id, sortTime)
          : (entry.data['status'] ?? 'pending') as String;

      if (!mounted || _popupOpen) return;
      if (stored != 'pending') continue;
      if (_shownReminderKeys.contains(key)) continue; // may have been shown while awaiting above

      _shownReminderKeys.add(key);
      _popupOpen = true;
      NotificationService().cancelOccurrenceReminders(entry.doc.id, sortTime);
      ReminderPopup.show(
        context,
        taskId: entry.doc.id,
        occurrenceDate: sortTime,
        isRecurring: isRecurring,
        title: (entry.data['title'] ?? '') as String,
        category: (entry.data['category'] ?? '') as String,
      ).then((_) {
        if (mounted) _popupOpen = false;
      });
      return;
    }
  }

  /// "Next Up" (see daily_routine_timeline_prompt.md — optional but
  /// implemented): the first entry, in chronological order, whose time
  /// hasn't passed yet and isn't already completed/missed. Uses the
  /// series doc's own raw `status` field as a fast, synchronous
  /// approximation rather than the live per-occurrence stream
  /// [_occurrenceAwareCard] uses for display — for a recurring task this
  /// can occasionally be stale (e.g. right after completing today's
  /// occurrence, before the series doc happens to reflect it, which for a
  /// recurring task it usually never does — see class doc comment on the
  /// per-occurrence model). Accepted tradeoff to avoid prefetching every
  /// occurrence's live status just to pick a highlight; documented rather
  /// than silently approximated.
  int _nextUpIndex(List<_TimelineEntry> entries) {
    final DateTime now = DateTime.now();
    for (int i = 0; i < entries.length; i++) {
      final DateTime? sortTime = entries[i].sortTime;
      if (sortTime == null || sortTime.isBefore(now)) continue;
      final String stored = (entries[i].data['status'] ?? 'pending') as String;
      if (stored == 'completed' || stored == 'missed') continue;
      return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final String todayLabel = DateFormat('EEEE, MMMM d').format(now);
    final String clockLabel = DateFormat('h:mm').format(now);

    return Scaffold(
      key: _scaffoldKey,
      drawer: const SideDrawer(),
      backgroundColor: AppColors.bgDark,
      body: SafeArea(
        child: _uid == null
            ? const Center(
                child: Text(
                  'Not logged in',
                  style: TextStyle(color: Colors.white),
                ),
              )
            : StreamBuilder<QuerySnapshot>(
                stream: _firestoreService.getTasksForPatient(_uid),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        'Something went wrong: ${snapshot.error}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    );
                  }

                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child:
                          CircularProgressIndicator(color: AppColors.orangeStart),
                    );
                  }

                  final allDocs = snapshot.data?.docs ?? [];
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _persistMissedStatus(allDocs.cast<QueryDocumentSnapshot>());
                  });

                  final visibleDocs = _visibleDocs(allDocs.cast<QueryDocumentSnapshot>());

                  final medicationDocs = visibleDocs.where((d) {
                    final data = d.data() as Map<String, dynamic>;
                    final category =
                        (data['category'] ?? '').toString().toLowerCase();
                    return category == 'medication';
                  }).toList();

                  final dailyTaskDocs = visibleDocs.where((d) {
                    final data = d.data() as Map<String, dynamic>;
                    final category =
                        (data['category'] ?? '').toString().toLowerCase();
                    return category != 'medication';
                  }).toList();

                  // Scope cut (see class doc comment): only non-recurring
                  // tasks count toward these totals — recurring completion
                  // lives behind an async per-occurrence stream that a
                  // synchronous count can't cheaply reflect. The merged
                  // DISPLAY below doesn't affect this — the clinical
                  // distinction (tasks vs meds) is preserved in the counter
                  // exactly as before.
                  //
                  // visibleDocs now includes "Anytime" (no dueDate) docs —
                  // TaskSeries.fromDoc hard-casts dueDate, so it must not be
                  // called for those; an Anytime task can never actually be
                  // recurring anyway (CreateTaskScreen requires a due date
                  // whenever recurrence is enabled), so it's counted the
                  // same as a non-recurring one without needing the call.
                  final tasksDone = dailyTaskDocs.where((d) {
                    final data = d.data() as Map<String, dynamic>;
                    if (data['dueDate'] is! Timestamp) {
                      return data['status'] == 'completed';
                    }
                    final series = TaskSeries.fromDoc(d);
                    return series.recurrenceType == RecurrenceType.none &&
                        data['status'] == 'completed';
                  }).length;

                  final medsDone = medicationDocs.where((d) {
                    final data = d.data() as Map<String, dynamic>;
                    if (data['dueDate'] is! Timestamp) {
                      return data['status'] == 'completed';
                    }
                    final series = TaskSeries.fromDoc(d);
                    return series.recurrenceType == RecurrenceType.none &&
                        data['status'] == 'completed';
                  }).length;

                  final recurringDocs = visibleDocs.where((d) {
                    final data = d.data() as Map<String, dynamic>;
                    if (data['dueDate'] is! Timestamp) return false; // Anytime, can't recur
                    return TaskSeries.fromDoc(d).recurrenceType != RecurrenceType.none;
                  }).toList();

                  final timelineEntries = _buildTimelineEntries(visibleDocs);
                  final int nextUpIndex = _nextUpIndex(timelineEntries);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _maybeShowDueReminder(timelineEntries);
                  });

                  return CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildTopBar(),
                              const SizedBox(height: 16),
                              // Daily Routine Timeline: the patient's own
                              // name/greeting isn't shown here (they know
                              // who they are) — the date is what matters
                              // for temporal orientation.
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Today', style: AppTextStyles.heading),
                                  Text(
                                    clockLabel,
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 15,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                todayLabel,
                                style: const TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 14),
                              _buildProgressCardReactive(
                                baseTasksDone: tasksDone,
                                baseMedsDone: medsDone,
                                tasksTotal: dailyTaskDocs.length,
                                medsTotal: medicationDocs.length,
                                recurringDocs: recurringDocs,
                              ),
                              const SizedBox(height: 12),
                            ],
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: timelineEntries.isEmpty
                            ? const SliverToBoxAdapter(
                                child: _EmptyState(text: 'No tasks scheduled for today'),
                              )
                            : SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    final entry = timelineEntries[index];
                                    return _occurrenceAwareCard(
                                      entry.doc,
                                      entry.data,
                                      (status, onToggle) => TimelineCard(
                                        title: (entry.data['title'] ?? '') as String,
                                        category: (entry.data['category'] ?? '') as String,
                                        dosage: (entry.data['dosage'] ?? '') as String,
                                        status: status,
                                        time: entry.sortTime,
                                        isNext: index == nextUpIndex,
                                        isFirst: index == 0,
                                        isLast: index == timelineEntries.length - 1,
                                        onToggle: onToggle,
                                        onTap: () => _openTaskDetail(entry.doc.id),
                                      ),
                                    );
                                  },
                                  childCount: timelineEntries.length,
                                ),
                              ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 20)),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        InkWell(
          onTap: () {
            _scaffoldKey.currentState?.openDrawer();
          },
          child: const Icon(Icons.menu, color: Colors.white, size: 28),
        ),
        const SizedBox(width: 12),
        const Text(
          'MindCare',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const Spacer(),
        CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.orangeEnd,
          child: Text(
            _initials(_userName),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }

  String _initials(String? name) {
    if (name == null || name.trim().isEmpty) return '?';
    final parts = name.trim().split(' ');
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  /// Wraps [_buildProgressCard] with the live completion tally for
  /// [recurringDocs] (see [_withRecurringTally]) added on top of the
  /// already-known non-recurring counts — this is what makes the progress
  /// bar actually move when a recurring task gets ticked, instead of only
  /// ever counting non-recurring tasks (the scope cut this used to have).
  Widget _buildProgressCardReactive({
    required int baseTasksDone,
    required int baseMedsDone,
    required int tasksTotal,
    required int medsTotal,
    required List<QueryDocumentSnapshot> recurringDocs,
  }) {
    return _withRecurringTally(recurringDocs, const _RecurringTally(0, 0), (tally) {
      return _buildProgressCard(
        done: baseTasksDone + baseMedsDone + tally.tasksDone + tally.medsDone,
        total: tasksTotal + medsTotal,
        medsDone: baseMedsDone + tally.medsDone,
        medsTotal: medsTotal,
      );
    });
  }

  /// Recursively wraps one [StreamBuilder] per recurring doc in
  /// [remainingDocs], each reading that occurrence's LIVE status and
  /// folding whether it's completed into [acc], until every doc has been
  /// accounted for — then calls [builder] with the final tally. See
  /// HomeScreen's identical method for the full reasoning (N nested
  /// StreamBuilders combining several independent streams into one
  /// derived value, without a reactive-streams package).
  Widget _withRecurringTally(
    List<QueryDocumentSnapshot> remainingDocs,
    _RecurringTally acc,
    Widget Function(_RecurringTally tally) builder,
  ) {
    if (remainingDocs.isEmpty) return builder(acc);

    final doc = remainingDocs.first;
    final rest = remainingDocs.sublist(1);
    final data = doc.data() as Map<String, dynamic>;
    final series = TaskSeries.fromDoc(doc);
    // recurringDocs is already filtered to occurrence-today docs, so this
    // is never null in practice.
    final DateTime occurrenceDate = _todaysOccurrence(series)!;
    final int intervalMinutes = _firestoreService.reminderIntervalMinutesOf(data);
    final bool isMedication = (data['category'] ?? '').toString().toLowerCase() == 'medication';

    return StreamBuilder<String>(
      stream: _firestoreService.getOccurrenceStatusStream(doc.id, occurrenceDate),
      builder: (context, snapshot) {
        final String status = effectiveStatus(
          storedStatus: snapshot.data ?? 'pending',
          dueDate: occurrenceDate,
          reminderIntervalMinutes: intervalMinutes,
        );
        final bool done = status == 'completed';
        final next = _RecurringTally(
          acc.tasksDone + (done && !isMedication ? 1 : 0),
          acc.medsDone + (done && isMedication ? 1 : 0),
        );
        return _withRecurringTally(rest, next, builder);
      },
    );
  }

  /// New progress card design (see daily_routine_timeline_prompt.md
  /// follow-up): a big combined "X of Y done" + linear progress bar, with
  /// the medication count called out separately in the corner — the
  /// clinical tasks-vs-meds distinction still exists in the numbers, it's
  /// just no longer two equal-weight stat tiles side by side.
  Widget _buildProgressCard({
    required int done,
    required int total,
    required int medsDone,
    required int medsTotal,
  }) {
    final double progress = total == 0 ? 0 : done / total;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.gradientCard(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'PROGRESS',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('Meds', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  Text(
                    '$medsDone/$medsTotal',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$done',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextSpan(
                  text: ' of $total done',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineEntry {
  final QueryDocumentSnapshot doc;
  final Map<String, dynamic> data;
  final DateTime? sortTime; // null = Anytime (no due date)
  const _TimelineEntry({required this.doc, required this.data, required this.sortTime});
}

/// Running total accumulated by [_PatientDashboardState._withRecurringTally].
class _RecurringTally {
  final int tasksDone;
  final int medsDone;
  const _RecurringTally(this.tasksDone, this.medsDone);
}

class _EmptyState extends StatelessWidget {
  final String text;
  const _EmptyState({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(
          text,
          style: const TextStyle(color: AppColors.textMuted),
        ),
      ),
    );
  }
}
