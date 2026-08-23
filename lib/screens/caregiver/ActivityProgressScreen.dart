import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import 'package:testproject/models/calendar_event.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_decorations.dart';
import 'package:testproject/theme/app_text_styles.dart';
import 'package:testproject/widgets/timeline_card.dart';
import '../../widgets/SideDrawer.dart';
import '../task_detail_screen.dart';

/// Phase 1 (see phase1_calendar_ui_prompt.md): an in-app month calendar so
/// a caregiver can pick a patient and see that patient's tasks by date.
/// No notifications, no Google Calendar integration, and no task
/// creation/editing here — tapping a task opens the existing read-only
/// TaskDetailScreen (same as TaskHistoryScreen already does).
///
/// Phase 2 (see phase2_recurring_tasks_prompt.md) added recurring tasks:
/// each visible month is expanded into concrete occurrences via
/// [CalendarEvent.occurrencesFromDoc] (backed by the single
/// `getOccurrencesForDateRange` source of truth in task_recurrence.dart) —
/// this screen never computes recurrence dates itself.
///
/// Reuses `FirestoreService.getTaskHistory`, which already returns a
/// patient's full dated task list (no separate query/index needed) —
/// each doc is then expanded into 0+ occurrences for the visible month.
class ActivityProgress extends StatefulWidget {
  const ActivityProgress({super.key});

  @override
  State<ActivityProgress> createState() => _ActivityProgressState();
}

class _ActivityProgressState extends State<ActivityProgress> {
  final FirestoreService _firestoreService = FirestoreService();
  final String caregiverId = FirebaseAuth.instance.currentUser!.uid;

  List<Map<String, dynamic>> _patients = [];
  bool _loadingPatients = true;
  String? _selectedPatientId;

  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadPatients();
  }

  Future<void> _loadPatients() async {
    setState(() => _loadingPatients = true);
    try {
      final patients = await _firestoreService.getPatientsForCaregiver(caregiverId);
      setState(() {
        _patients = patients;
        _loadingPatients = false;
        if (_selectedPatientId == null && patients.isNotEmpty) {
          _selectedPatientId = patients.first['uid'];
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingPatients = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load patients: $e')),
      );
    }
  }

  DateTime _dayKey(DateTime d) => DateTime(d.year, d.month, d.day);

  /// A real chronological timeline for the selected day — same connector-
  /// line/TimelineCard treatment used on the dashboards, so a caregiver
  /// can read the day's schedule at a glance instead of an unordered card
  /// list. Read-only (onToggle stays null on every card) — no task
  /// creation/editing from the calendar, per phase1_calendar_ui_prompt.md.
  /// "Up Next" only applies when the selected day is actually today; for
  /// a past/future date there's no "next" to highlight.
  Widget _buildEventTimeline(List<CalendarEvent> events) {
    final bool selectedIsToday = _dayKey(_selectedDay) == _dayKey(DateTime.now());
    int nextUpIndex = -1;
    if (selectedIsToday) {
      final DateTime now = DateTime.now();
      for (int i = 0; i < events.length; i++) {
        if (events[i].dueDate.isBefore(now)) continue;
        // Fast synchronous approximation for a recurring occurrence (uses
        // the series doc's own status, not the live per-occurrence stream
        // the card itself renders) — same documented tradeoff as
        // HomeScreen/PatientDashboard's "Up Next" detection.
        if (events[i].status == 'completed' || events[i].status == 'missed') continue;
        nextUpIndex = i;
        break;
      }
    }

    return Column(
      children: [
        for (int i = 0; i < events.length; i++)
          _EventTimelineRow(
            event: events[i],
            firestore: _firestoreService,
            isFirst: i == 0,
            isLast: i == events.length - 1,
            isNext: i == nextUpIndex,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TaskDetailScreen(taskId: events[i].taskId),
              ),
            ),
          ),
      ],
    );
  }

  /// The window occurrences are expanded across for the currently visible
  /// month — a 7-day buffer either side covers the leading/trailing days
  /// TableCalendar's month grid can show.
  (DateTime, DateTime) _visibleRange() {
    final DateTime firstOfMonth = DateTime(_focusedDay.year, _focusedDay.month, 1);
    final DateTime lastOfMonth =
        DateTime(_focusedDay.year, _focusedDay.month + 1, 0);
    return (
      firstOfMonth.subtract(const Duration(days: 7)),
      lastOfMonth.add(const Duration(days: 7)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDark,
      drawer: const SideDrawer(),
      appBar: AppBar(
        title: const Text('MindCare', style: TextStyle(color: Colors.white)),
        backgroundColor: AppColors.bgDark,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Activity Progress', style: AppTextStyles.heading),
            const SizedBox(height: 4),
            const Text(
              "See a patient's tasks laid out by date.",
              style: AppTextStyles.muted,
            ),
            const SizedBox(height: 14),

            _loadingPatients
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.orangeStart),
                  )
                : _patients.isEmpty
                    ? const Text(
                        'No patients yet — add one from Manage Patient.',
                        style: AppTextStyles.muted,
                      )
                    : DropdownButtonFormField<String>(
                        value: _selectedPatientId,
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                        dropdownColor: AppColors.cardPurpleLight,
                        decoration: AppDecorations.darkInput('Patient'),
                        items: _patients.map<DropdownMenuItem<String>>((patient) {
                          return DropdownMenuItem<String>(
                            value: patient['uid'],
                            child: Text(patient['name']),
                          );
                        }).toList(),
                        onChanged: (value) =>
                            setState(() => _selectedPatientId = value),
                      ),
            const SizedBox(height: 14),

            if (_selectedPatientId == null)
              const Text(
                'Select a patient to view their calendar.',
                style: AppTextStyles.muted,
              )
            else
              StreamBuilder<QuerySnapshot>(
                stream: _firestoreService.getTaskHistory(_selectedPatientId!),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Text(
                      'Something went wrong: ${snapshot.error}',
                      style: const TextStyle(color: Colors.white),
                    );
                  }
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.orangeStart,
                      ),
                    );
                  }

                  final docs = snapshot.data?.docs ?? [];
                  final (rangeStart, rangeEnd) = _visibleRange();
                  final Map<DateTime, List<CalendarEvent>> eventsByDay = {};
                  for (final doc in docs) {
                    final events = CalendarEvent.occurrencesFromDoc(
                      doc,
                      rangeStart,
                      rangeEnd,
                    );
                    for (final event in events) {
                      eventsByDay
                          .putIfAbsent(_dayKey(event.dueDate), () => [])
                          .add(event);
                    }
                  }

                  final selectedEvents = eventsByDay[_dayKey(_selectedDay)] ?? [];
                  // eventsByDay's order follows getTaskHistory's dueDate
                  // sort (each doc's own start date, not the occurrence's
                  // time on this specific day) — re-sort by the actual
                  // occurrence time so the timeline reads chronologically.
                  selectedEvents.sort((a, b) => a.dueDate.compareTo(b.dueDate));

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: AppDecorations.card,
                        child: TableCalendar<CalendarEvent>(
                          firstDay: DateTime.utc(2020, 1, 1),
                          lastDay: DateTime.utc(2100, 12, 31),
                          focusedDay: _focusedDay,
                          currentDay: DateTime.now(),
                          calendarFormat: CalendarFormat.month,
                          availableCalendarFormats: const {
                            CalendarFormat.month: 'Month',
                          },
                          selectedDayPredicate: (day) =>
                              isSameDay(_selectedDay, day),
                          eventLoader: (day) => eventsByDay[_dayKey(day)] ?? [],
                          onDaySelected: (selectedDay, focusedDay) {
                            setState(() {
                              _selectedDay = selectedDay;
                              _focusedDay = focusedDay;
                            });
                          },
                          onPageChanged: (focusedDay) {
                            // setState (not a bare assignment) because the
                            // occurrence expansion above depends on
                            // _focusedDay's month — the events shown must
                            // recompute when the caregiver flips months.
                            setState(() => _focusedDay = focusedDay);
                          },
                          headerStyle: const HeaderStyle(
                            formatButtonVisible: false,
                            titleCentered: true,
                            titleTextStyle: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            leftChevronIcon:
                                Icon(Icons.chevron_left, color: Colors.white),
                            rightChevronIcon:
                                Icon(Icons.chevron_right, color: Colors.white),
                          ),
                          daysOfWeekStyle: const DaysOfWeekStyle(
                            weekdayStyle: TextStyle(color: AppColors.textMuted),
                            weekendStyle: TextStyle(color: AppColors.textMuted),
                          ),
                          calendarStyle: CalendarStyle(
                            outsideDaysVisible: false,
                            defaultTextStyle: const TextStyle(color: Colors.white),
                            weekendTextStyle:
                                const TextStyle(color: Colors.white),
                            todayDecoration: BoxDecoration(
                              color: AppColors.cardPurpleLight,
                              shape: BoxShape.circle,
                            ),
                            todayTextStyle: const TextStyle(color: Colors.white),
                            selectedDecoration: const BoxDecoration(
                              color: AppColors.orangeStart,
                              shape: BoxShape.circle,
                            ),
                            selectedTextStyle: const TextStyle(color: Colors.white),
                            markerDecoration: const BoxDecoration(
                              color: AppColors.greenCheck,
                              shape: BoxShape.circle,
                            ),
                            markersMaxCount: 1,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Tasks for ${DateFormat('MMMM d, y').format(_selectedDay)}',
                        style: AppTextStyles.sectionTitle,
                      ),
                      const SizedBox(height: 10),
                      if (selectedEvents.isEmpty)
                        const Text(
                          'No tasks for this date.',
                          style: AppTextStyles.muted,
                        )
                      else
                        _buildEventTimeline(selectedEvents),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// One timeline row for one occurrence. A non-recurring task's status
/// comes straight off the doc (unchanged); a recurring occurrence reads
/// its own live status from the per-occurrence subcollection (Phase 3),
/// upgrading what used to be a generic "Repeats" badge into the same
/// real Pending/Completed/Missed status every other screen shows.
class _EventTimelineRow extends StatelessWidget {
  final CalendarEvent event;
  final FirestoreService firestore;
  final bool isFirst;
  final bool isLast;
  final bool isNext;
  final VoidCallback onTap;

  const _EventTimelineRow({
    required this.event,
    required this.firestore,
    required this.isFirst,
    required this.isLast,
    required this.isNext,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (!event.isRecurring) {
      return TimelineCard(
        title: event.title,
        category: event.category,
        dosage: event.dosage,
        status: event.status,
        time: event.dueDate,
        isNext: isNext,
        isFirst: isFirst,
        isLast: isLast,
        onToggle: null, // read-only calendar — no editing here
        onTap: onTap,
      );
    }

    return StreamBuilder<String>(
      stream: firestore.getOccurrenceStatusStream(event.taskId, event.dueDate),
      builder: (context, snapshot) {
        return TimelineCard(
          title: event.title,
          category: event.category,
          dosage: event.dosage,
          status: snapshot.data ?? 'pending',
          time: event.dueDate,
          isNext: isNext,
          isFirst: isFirst,
          isLast: isLast,
          onToggle: null,
          onTap: onTap,
        );
      },
    );
  }
}
