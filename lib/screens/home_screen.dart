import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'package:testproject/models/occurrence_status.dart';
import 'package:testproject/models/task_recurrence.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/widgets/side_drawer.dart';

import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_text_styles.dart';
import 'package:testproject/theme/app_decorations.dart';
import 'package:testproject/widgets/timeline_card.dart';
import 'package:testproject/widgets/dementia_badges.dart';
import 'package:testproject/widgets/risk_badge.dart';
import 'package:testproject/screens/task_detail_screen.dart';

// PHASE 3 (see phase3_reminder_notifications_prompt.md): this screen's
// _effectiveStatus/_persistMissedStatus are extended the same way as
// PatientDashboard's — see that screen's class doc comment for the full
// reasoning (per-occurrence status for recurring tasks; missed only flips
// once the reminder chain's safety cap is exhausted, not the instant
// dueDate passes).
//
// fix_recurring_task_homescreen_visibility.md: this screen used to query
// getTasks(caregiverId), which windows by the doc's own dueDate (today +/-
// 3 days) — for a recurring task, that's its START date, so an older
// recurring series whose start date had scrolled out of the window would
// silently stop appearing here even on a day it still recurred. Fixed by
// switching to getAllTasksForCaregiver (unbounded by date, same pattern
// the calendar already uses) and reproducing the ±3-day visibility rule
// client-side instead — see _visibleDocs below. A single task's
// visibility is unchanged; a recurring task is now visible whenever it
// has an occurrence TODAY specifically (not extended to the 3-day grace
// window used for single tasks — a recurring series gets a fresh
// occurrence every day it recurs, so "still show yesterday's" would mean
// something different, and murkier, than it does for a one-off task; this
// was a deliberate scope decision, flagged rather than silently assumed).
//
// daily_routine_timeline_prompt.md (follow-up): Daily Tasks and
// Medication Schedule are now ONE merged, chronologically-sorted timeline
// PER PATIENT — same TimelineCard/vertical-line treatment as the patient's
// own dashboard, matching it "exactly the same" except the caregiver keeps
// per-patient grouping (name + stage/type badges) since they monitor more
// than one patient. The old "Good Morning, {name}!" greeting is replaced
// by the same "Today" + live-clock header the patient screen uses, and
// the old Daily Tasks/"Add Task" + Medication Schedule/"Add Med" section
// headers are replaced by one generic "+ Add Task" link (CreateTaskScreen
// already lets the category, including Medication, be chosen in the form
// itself, so nothing is lost by consolidating the entry point).

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final FirestoreService _firestoreService = FirestoreService();
  final String? _uid = FirebaseAuth.instance.currentUser?.uid;
  int _currentNavIndex = 0;
  Timer? _statusTimer;
  String? _userName;

  /// patientId -> patient name, so task groups can show a name heading
  /// instead of a raw uid. A task whose patientId isn't in this map
  /// (missing, or pointing at a patient that's since been unlinked) is
  /// grouped under "Unassigned" rather than silently dropped.
  Map<String, String> _patientNames = {};

  /// patientId -> dementiaStage ('early'/'middle'), shown as a
  /// DementiaStageBadge next to the patient's name heading (see
  /// _buildGroupedSection) — same lookup pattern as [_patientNames].
  Map<String, String> _patientStages = {};

  /// patientId -> dementiaType ('alzheimers'/'vascular'), shown as a
  /// DementiaTypeBadge alongside the stage badge — same lookup pattern as
  /// [_patientStages].
  Map<String, String> _patientTypes = {};

  @override
  void initState() {
    super.initState();
    _loadUserName();
    _loadPatientNames();
    // Re-check task statuses every minute so overdue tasks flip to
    // "missed" automatically without the user interacting, and so the
    // clock/"Up Next" countdown moves on as time passes.
    _statusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadUserName() async {
    if (_uid == null) return;
    final name = await _firestoreService.getUserName(_uid);
    if (mounted) setState(() => _userName = name);
  }

  Future<void> _loadPatientNames() async {
    if (_uid == null) return;
    final patients = await _firestoreService.getPatientsForCaregiver(_uid);
    if (!mounted) return;
    setState(() {
      _patientNames = {
        for (final p in patients)
          if (p['uid'] != null)
            p['uid'] as String: (p['name'] ?? 'Unnamed') as String,
      };
      _patientStages = {
        for (final p in patients)
          if (p['uid'] != null && p['dementiaStage'] != null)
            p['uid'] as String: p['dementiaStage'] as String,
      };
      _patientTypes = {
        for (final p in patients)
          if (p['uid'] != null && p['dementiaType'] != null)
            p['uid'] as String: p['dementiaType'] as String,
      };
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
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
                stream: _firestoreService.getAllTasksForCaregiver(_uid),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    // 3a (exceptional flow): prompt the user to refresh,
                    // not just display the error.
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Something went wrong: ${snapshot.error}',
                            style: const TextStyle(color: Colors.white),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: () => setState(() {}),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.orangeStart,
                              foregroundColor: Colors.white,
                            ),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                          ),
                        ],
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
                  // getAllTasksForCaregiver is unbounded by date — narrow
                  // to what should actually show on "today's" dashboard
                  // before anything else touches this list. See the
                  // file-level comment for the visibility rule. visibleDocs
                  // is DISPLAY-ONLY (see _visibleDocs' own doc comment) —
                  // the missed-status sweep below deliberately does NOT use
                  // it (see BUGFIX there).
                  final visibleDocs = _visibleDocs(allDocs.cast<QueryDocumentSnapshot>());
                  // BUGFIX (hidden-bugs review): this used to sweep only
                  // visibleDocs, which is bounded by
                  // FirestoreService.homeWindowDays (+/-3 days) for DISPLAY
                  // purposes — so a non-recurring task overdue by more than
                  // 3 days was invisible to this sweep and stayed 'pending'
                  // forever from HomeScreen's perspective, while
                  // PatientDashboard's own (already unbounded) sweep would
                  // correctly flip that SAME task to 'missed' the next time
                  // the patient opened their dashboard — the two screens
                  // could silently disagree on a task's persisted status
                  // depending on which one last touched it. Sweeping
                  // allDocs (unbounded, exactly like PatientDashboard)
                  // instead keeps both screens' sweeps in agreement, with
                  // no ±3-day window involved in deciding whether an old
                  // task becomes missed.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _persistMissedStatus(allDocs.cast<QueryDocumentSnapshot>());
                  });

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

                  // Non-recurring tasks count synchronously here — their
                  // status is a plain field on the doc already in hand.
                  // Recurring tasks' completion lives in the per-occurrence
                  // subcollection (a live stream, not a field on this doc),
                  // so they're tallied separately by _withRecurringTally
                  // and added in below — see that method's doc comment for
                  // why this used to be skipped entirely.
                  final tasksDone = dailyTaskDocs.where((d) {
                    final series = TaskSeries.fromDoc(d);
                    final data = d.data() as Map<String, dynamic>;
                    return series.recurrenceType == RecurrenceType.none &&
                        data['status'] == 'completed';
                  }).length;

                  final medsDone = medicationDocs.where((d) {
                    final series = TaskSeries.fromDoc(d);
                    final data = d.data() as Map<String, dynamic>;
                    return series.recurrenceType == RecurrenceType.none &&
                        data['status'] == 'completed';
                  }).length;

                  final recurringDocs = visibleDocs
                      .where((d) => TaskSeries.fromDoc(d).recurrenceType != RecurrenceType.none)
                      .toList();

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
                              const SizedBox(height: 10),
                              Align(
                                alignment: Alignment.centerRight,
                                child: InkWell(
                                  onTap: () => Navigator.pushNamed(context, '/createtask'),
                                  child: const Text('+ Add Task', style: AppTextStyles.actionLink),
                                ),
                              ),
                              const SizedBox(height: 4),
                            ],
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverToBoxAdapter(
                          child: visibleDocs.isEmpty
                              ? const _EmptyState(
                                  text: 'No tasks or medications scheduled for today',
                                )
                              : _buildGroupedSection(visibleDocs),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 12)),
                    ],
                  );
                },
              ),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  /// Groups [docs] by patientId and renders one indented block per patient:
  /// the patient's name (+ stage/type badges) as a sub-heading, then their
  /// own chronologically-sorted mini-timeline beneath it. Docs with no
  /// matching patient (missing patientId, or a patient that's since been
  /// unlinked) are grouped under "Unassigned" instead of disappearing.
  Widget _buildGroupedSection(List<QueryDocumentSnapshot> docs) {
    final Map<String, List<QueryDocumentSnapshot>> grouped = {};
    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      final String patientId = (data['patientId'] as String?)?.trim() ?? '';
      grouped.putIfAbsent(patientId, () => []).add(doc);
    }

    final entries = grouped.entries.toList()
      ..sort((a, b) {
        final String nameA = _patientNames[a.key] ?? '';
        final String nameB = _patientNames[b.key] ?? '';
        // Unassigned/unknown patients sort last.
        if (nameA.isEmpty != nameB.isEmpty) {
          return nameA.isEmpty ? 1 : -1;
        }
        return nameA.compareTo(nameB);
      });

    // Each patient's own card list, sorted earliest-first — their own
    // independent mini-timeline, not one big cross-patient sort.
    for (final entry in entries) {
      entry.value.sort((a, b) => _sortTimeFor(a).compareTo(_sortTimeFor(b)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in entries) ...[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            // Wrap, not Row: name + both badges (esp. the longer type
            // labels like "Frontotemporal Dementia (FTD)") can exceed a
            // narrow phone's width — wrapping to a second line beats a
            // RenderFlex overflow.
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(
                  _patientNames[entry.key] ?? 'Unassigned',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_patientStages[entry.key] != null)
                  DementiaStageBadge(stage: _patientStages[entry.key]!),
                if (_patientTypes[entry.key] != null)
                  DementiaTypeBadge(type: _patientTypes[entry.key]!),
                // PART 2: entry.key is empty for the synthetic
                // "Unassigned" group (see the grouping loop above) — never
                // shown a risk badge, since there's no real patientId.
                if (entry.key.isNotEmpty)
                  PatientRiskBadge(
                    patientId: entry.key,
                    patientName: _patientNames[entry.key] ?? 'Unassigned',
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: _buildPatientTimeline(entry.value),
          ),
        ],
      ],
    );
  }

  /// One patient's own chronological mini-timeline — same TimelineCard
  /// connector-line rendering the patient dashboard uses, with "Up Next"
  /// computed within just this patient's list (a caregiver monitoring
  /// several patients gets one highlight per patient, not one overall).
  Widget _buildPatientTimeline(List<QueryDocumentSnapshot> docs) {
    final int nextUpIndex = _nextUpIndexForDocs(docs);
    return Column(
      children: [
        for (int i = 0; i < docs.length; i++)
          _occurrenceAwareCard(docs[i], docs[i].data() as Map<String, dynamic>,
              (status, onToggle) {
            final data = docs[i].data() as Map<String, dynamic>;
            return TimelineCard(
              title: (data['title'] ?? '') as String,
              category: (data['category'] ?? '') as String,
              dosage: (data['dosage'] ?? '') as String,
              status: status,
              time: _sortTimeFor(docs[i]),
              isNext: i == nextUpIndex,
              isFirst: i == 0,
              isLast: i == docs.length - 1,
              onToggle: onToggle,
              onTap: () => _openTaskDetail(docs[i].id),
            );
          }),
      ],
    );
  }

  /// Same "Up Next" approximation as PatientDashboard's _nextUpIndex — the
  /// first entry, in chronological order, whose time hasn't passed yet and
  /// isn't already completed/missed, using each doc's own raw `status`
  /// field as a fast synchronous check rather than the live per-occurrence
  /// stream (see that method's doc comment for the full reasoning).
  int _nextUpIndexForDocs(List<QueryDocumentSnapshot> docs) {
    final DateTime now = DateTime.now();
    for (int i = 0; i < docs.length; i++) {
      if (_sortTimeFor(docs[i]).isBefore(now)) continue;
      final data = docs[i].data() as Map<String, dynamic>;
      final String stored = (data['status'] ?? 'pending') as String;
      if (stored == 'completed' || stored == 'missed') continue;
      return i;
    }
    return -1;
  }

  /// The doc's own dueDate for a single task, or today's occurrence time
  /// for a recurring one — same time the card displays and the same key
  /// _buildGroupedSection sorts by. Docs reaching here are already from
  /// _visibleDocs, so a valid dueDate (and, for a recurring series, a
  /// today occurrence) is guaranteed.
  DateTime _sortTimeFor(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final DateTime due = (data['dueDate'] as Timestamp).toDate();
    final series = TaskSeries.fromDoc(doc);
    return series.recurrenceType == RecurrenceType.none ? due : _todaysOccurrence(series)!;
  }

  /// UC-05 sub-flow 8a/8b: tapping a card's body opens the read-only
  /// detail view (which itself offers an Edit button for caregivers) —
  /// the tick icon's own tap target still toggles completion directly.
  void _openTaskDetail(String taskId) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: taskId)),
    );
  }

  static const int _pointsPerCompletion = 2;

  /// Non-recurring path only — see [_toggleOccurrenceStatus] for recurring.
  Future<void> _toggleTaskStatus(
    String taskId,
    String patientId,
    bool isCurrentlyDone,
  ) async {
    await _firestoreService.updateTaskStatus(
      taskId,
      isCurrentlyDone ? 'pending' : 'completed',
    );
    await _firestoreService.awardPoints(
      patientId,
      isCurrentlyDone ? -_pointsPerCompletion : _pointsPerCompletion,
    );

    if (!isCurrentlyDone && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('+2 points!'),
          duration: Duration(seconds: 1),
          backgroundColor: AppColors.orangeStart,
        ),
      );
    }
  }

  /// PHASE 3: recurring-task equivalent of [_toggleTaskStatus] — see
  /// PatientDashboard's identical method for the full reasoning. Cancels
  /// this occurrence's remaining reminder chain, which lives on the
  /// PATIENT's own device — this caregiver-side toggle just needs to make
  /// sure the chain doesn't keep nagging the patient after the caregiver
  /// has already resolved it here.
  Future<void> _toggleOccurrenceStatus(
    String taskId,
    String patientId,
    DateTime occurrenceDate,
    bool isCurrentlyDone,
  ) async {
    final String newStatus = isCurrentlyDone ? 'pending' : 'completed';
    await _firestoreService.setOccurrenceStatus(taskId, occurrenceDate, newStatus);
    await _firestoreService.awardPoints(
      patientId,
      isCurrentlyDone ? -_pointsPerCompletion : _pointsPerCompletion,
    );

    if (!isCurrentlyDone && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('+2 points!'),
          duration: Duration(seconds: 1),
          backgroundColor: AppColors.orangeStart,
        ),
      );
    }
  }

  DateTime? _todaysOccurrence(TaskSeries series) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final occurrences = getOccurrencesForDateRange(series, todayStart, todayEnd);
    return occurrences.isEmpty ? null : occurrences.first;
  }

  /// fix_recurring_task_homescreen_visibility.md: narrows
  /// getAllTasksForCaregiver's unbounded results down to what should
  /// actually show on "today's" dashboard — a single task due within the
  /// same +/-[FirestoreService.homeWindowDays] window getTasks() used to
  /// enforce server-side (unchanged behaviour, just computed here now),
  /// or a recurring task that has an occurrence TODAY specifically
  /// (regardless of how long ago its series started — this is the bug
  /// this fix resolves). A missing/invalid dueDate is excluded either way,
  /// matching getTasks()'s old implicit behaviour (its range filter could
  /// never match a doc with no dueDate) and avoiding a crash in
  /// TaskSeries.fromDoc, which assumes dueDate is present.
  ///
  /// BUGFIX: the +/-[FirestoreService.homeWindowDays] grace window exists
  /// so an overdue-but-still-PENDING single task doesn't silently drop off
  /// the caregiver's view (its whole point, per the doc comment above) —
  /// but the check below used to apply that window unconditionally,
  /// showing an already-completed/missed task from up to
  /// [FirestoreService.homeWindowDays] days ago on "Today" too, with
  /// nothing left to act on. Now a task carried over from BEFORE today
  /// only keeps showing while it's still `pending`; a task actually due
  /// today shows regardless of status, same as before (its own day's
  /// completed/missed items are legitimately part of "today").
  List<QueryDocumentSnapshot> _visibleDocs(List<QueryDocumentSnapshot> docs) {
    final DateTime now = DateTime.now();
    final DateTime startOfToday = DateTime(now.year, now.month, now.day);
    final DateTime windowStart =
        startOfToday.subtract(const Duration(days: FirestoreService.homeWindowDays));
    final DateTime endOfToday = startOfToday.add(const Duration(days: 1));

    return docs.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final dueTs = data['dueDate'];
      if (dueTs is! Timestamp) return false;

      final series = TaskSeries.fromDoc(doc);
      if (series.recurrenceType == RecurrenceType.none) {
        final DateTime due = dueTs.toDate();
        if (due.isBefore(windowStart) || !due.isBefore(endOfToday)) return false;
        if (!due.isBefore(startOfToday)) return true; // due today — always show
        final String status = (data['status'] ?? 'pending') as String;
        return status == 'pending'; // carried over from before today — only if still actionable
      }
      return _todaysOccurrence(series) != null;
    }).toList();
  }

  /// Renders [buildCard] with the right live status + toggle handler —
  /// see PatientDashboard's identical method for the full reasoning
  /// (legacy top-level status for a single task, per-occurrence
  /// subcollection for a recurring one).
  ///
  /// BUGFIX (hidden-bugs review): 'missed' is now a terminal status here,
  /// same as 'completed' already was — the toggle callback is disabled
  /// (null) for either, instead of only for 'completed'. Previously a
  /// missed task's tick icon was still fully wired, so tapping it called
  /// _toggleTaskStatus/_toggleOccurrenceStatus with isCurrentlyDone=false
  /// (since 'missed' != 'completed') and silently flipped it straight to
  /// 'completed' — a task the missed-status sweep had already resolved
  /// could be reopened by a single accidental tap.
  Widget _occurrenceAwareCard(
    QueryDocumentSnapshot doc,
    Map<String, dynamic> data,
    Widget Function(String status, VoidCallback? onToggle) buildCard,
  ) {
    final series = TaskSeries.fromDoc(doc);
    final int intervalMinutes = _firestoreService.reminderIntervalMinutesOf(data);
    final String patientId = (data['patientId'] ?? '') as String;

    if (series.recurrenceType == RecurrenceType.none) {
      final dueTs = data['dueDate'];
      final String stored = (data['status'] ?? 'pending') as String;
      final String status = dueTs is Timestamp
          ? effectiveStatus(
              storedStatus: stored,
              dueDate: dueTs.toDate(),
              reminderIntervalMinutes: intervalMinutes,
            )
          : stored;
      return buildCard(
        status,
        status == 'missed'
            ? null
            : () => _toggleTaskStatus(doc.id, patientId, status == 'completed'),
      );
    }

    // Only called for docs already filtered to "has an occurrence today"
    // (see _visibleDocs) so this is never null in practice.
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
          status == 'missed'
              ? null
              : () => _toggleOccurrenceStatus(
                    doc.id,
                    patientId,
                    occurrenceDate,
                    status == 'completed',
                  ),
        );
      },
    );
  }

  /// PHASE 3 (Step 11): see PatientDashboard's identical method — a
  /// pending occurrence only auto-flips to 'missed' once its reminder
  /// chain's safety cap is exhausted, not the instant its due time passes.
  Future<void> _persistMissedStatus(List<QueryDocumentSnapshot> docs) async {
    final now = DateTime.now();
    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      // Currently only ever called with _visibleDocs' output (already
      // guaranteed a valid dueDate), but TaskSeries.fromDoc hard-casts
      // dueDate to Timestamp — guarding here too so this stays safe even
      // if a future caller passes an unfiltered doc list (see the crash
      // this exact gap caused in PatientDashboard).
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
  /// ever counting non-recurring tasks.
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
  /// [remainingDocs], each reading that occurrence's LIVE status (the same
  /// per-occurrence subcollection stream every other screen already uses)
  /// and folding whether it's completed into [acc], until every doc has
  /// been accounted for — then calls [builder] with the final tally.
  ///
  /// This is what a synchronous `.where(...).length` can't do: a
  /// recurring task's completion isn't a field on the doc already in
  /// hand, it's a separate live document this has to subscribe to. N
  /// nested StreamBuilders (one per recurring task actually visible
  /// today — a small number at FYP scale) is a plain-Flutter way to
  /// combine several independent streams into one derived value without
  /// pulling in a reactive-streams package for it.
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
    // recurringDocs is already filtered to occurrence-today docs (see
    // _visibleDocs), so this is never null in practice.
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
  /// follow-up) — same as PatientDashboard's: a big combined "X of Y done"
  /// + linear progress bar, with the medication count called out
  /// separately in the corner.
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

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.cardPurple,
        border: Border(
          top: BorderSide(color: AppColors.cardPurpleLight, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _navItem(Icons.home_rounded, 'Home', 0),
          // Calendar icon, not the old brain/psychology one — this tab
          // opens ActivityProgressScreen, which is a per-patient task
          // CALENDAR, not a cognitive-exercise screen (that's the brain
          // icon's job elsewhere, e.g. patient Cognitive Games).
          _navItem(
            Icons.calendar_month_rounded,
            'Activities',
            1,
            onTap: () => Navigator.pushReplacementNamed(context, '/activityprogress'),
          ),
        ],
      ),
    );
  }

  Widget _navItem(IconData icon, String label, int index, {VoidCallback? onTap}) {
    final bool isActive = _currentNavIndex == index;
    final Color color = isActive ? AppColors.orangeStart : AppColors.textMuted;
    return InkWell(
      onTap: onTap ?? () => setState(() => _currentNavIndex = index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// Running total accumulated by [_HomeScreenState._withRecurringTally].
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
