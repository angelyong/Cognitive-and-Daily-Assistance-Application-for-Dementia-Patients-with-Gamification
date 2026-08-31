import 'package:cloud_firestore/cloud_firestore.dart';

/// PHASE 2 (see phase2_recurring_tasks_prompt.md): recurrence support for
/// the `tasks` collection. A recurring task is still ONE Firestore document
/// (never one doc per future date — Step 8) whose existing `dueDate` field
/// keeps meaning exactly what it always meant: this document's own due
/// date/time, which for a recurring task is also its start. These fields
/// are optional additions on top of the existing schema — an old task doc
/// simply has none of them, and [RecurrenceTypeX.fromFirestore] treats a
/// missing/unrecognized value as [RecurrenceType.none] (Step 9).
enum RecurrenceType { none, daily, weekly, monthly, yearly, custom }

extension RecurrenceTypeX on RecurrenceType {
  static const String firestoreField = 'recurrenceType';

  static RecurrenceType fromFirestore(String? value) {
    switch (value) {
      case 'daily':
        return RecurrenceType.daily;
      case 'weekly':
        return RecurrenceType.weekly;
      case 'monthly':
        return RecurrenceType.monthly;
      case 'yearly':
        return RecurrenceType.yearly;
      case 'custom':
        return RecurrenceType.custom;
      case 'none':
      default:
        return RecurrenceType.none;
    }
  }

  String get firestoreValue => name;

  String get label {
    switch (this) {
      case RecurrenceType.none:
        return 'Does not repeat';
      case RecurrenceType.daily:
        return 'Daily';
      case RecurrenceType.weekly:
        return 'Weekly';
      case RecurrenceType.monthly:
        return 'Monthly';
      case RecurrenceType.yearly:
        return 'Yearly';
      case RecurrenceType.custom:
        return 'Custom';
    }
  }
}

/// Only meaningful for [RecurrenceType.custom] — the unit the caregiver's
/// "every [n] ___" interval is measured in.
enum RecurrenceUnit { days, weeks, months }

extension RecurrenceUnitX on RecurrenceUnit {
  static RecurrenceUnit fromFirestore(String? value) {
    switch (value) {
      case 'weeks':
        return RecurrenceUnit.weeks;
      case 'months':
        return RecurrenceUnit.months;
      case 'days':
      default:
        return RecurrenceUnit.days;
    }
  }

  String get firestoreValue => name;

  String get label {
    switch (this) {
      case RecurrenceUnit.days:
        return 'Days';
      case RecurrenceUnit.weeks:
        return 'Weeks';
      case RecurrenceUnit.months:
        return 'Months';
    }
  }
}

/// Structured recurrence parameters, stored under the `recurrenceRule` map
/// field. Only the fields relevant to the task's [RecurrenceType] are
/// meaningful — e.g. [weekdays] is read for weekly/custom-weeks, [interval]
/// only for custom.
class RecurrenceRule {
  /// DateTime.weekday values (1=Mon .. 7=Sun). Used by weekly, and by
  /// custom when [unit] is weeks. Empty means "the start date's weekday".
  final List<int> weekdays;

  /// "Every [interval] [unit]" — only used by [RecurrenceType.custom].
  final int interval;
  final RecurrenceUnit unit;

  const RecurrenceRule({
    this.weekdays = const [],
    this.interval = 1,
    this.unit = RecurrenceUnit.days,
  });

  factory RecurrenceRule.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const RecurrenceRule();
    return RecurrenceRule(
      weekdays: (map['weekdays'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toList() ??
          const [],
      interval: (map['interval'] as int?) ?? 1,
      unit: RecurrenceUnitX.fromFirestore(map['unit'] as String?),
    );
  }

  Map<String, dynamic> toMap() => {
        'weekdays': weekdays,
        'interval': interval,
        'unit': unit.firestoreValue,
      };
}

/// The minimal read view of a task doc needed to expand it into calendar
/// occurrences — not a general-purpose task model (see TaskModel note in
/// the Phase 2 report: the app already reads raw Firestore maps
/// everywhere, this mirrors that rather than fighting it).
class TaskSeries {
  final String taskId;
  final DateTime startDate; // = the doc's own dueDate
  final RecurrenceType recurrenceType;
  final RecurrenceRule rule;
  final DateTime? endDate; // null = never

  const TaskSeries({
    required this.taskId,
    required this.startDate,
    required this.recurrenceType,
    required this.rule,
    required this.endDate,
  });

  factory TaskSeries.fromDoc(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final dueTs = data['dueDate'] as Timestamp;
    final endTs = data['endDate'];
    return TaskSeries(
      taskId: doc.id,
      startDate: dueTs.toDate(),
      recurrenceType: RecurrenceTypeX.fromFirestore(
        data[RecurrenceTypeX.firestoreField] as String?,
      ),
      rule: RecurrenceRule.fromMap(
        data['recurrenceRule'] as Map<String, dynamic>?,
      ),
      endDate: endTs is Timestamp ? endTs.toDate() : null,
    );
  }
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// The Monday of [d]'s calendar week (DateTime.weekday: Mon=1..Sun=7).
/// Used to bucket custom "every N weeks" recurrence by real calendar weeks
/// instead of consecutive 7-day blocks counted from the series' own start
/// date — see [_isOccurrence]'s weeks branch for why that distinction
/// matters (HIDDEN_BUGS.md finding #6).
DateTime _mondayOf(DateTime d) {
  final DateTime day = _dateOnly(d);
  return day.subtract(Duration(days: day.weekday - 1));
}

int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Same day-of-month as the start date, clamped to the last day of the
/// target month when it doesn't exist there (e.g. 31 Jan -> 28/29 Feb).
/// Chosen behaviour for monthly/yearly recurrence, per
/// phase2_recurring_tasks_prompt.md Steps 3-7 — documented here, not
/// silently decided.
DateTime _clampedMonthDay(int year, int month, int day) {
  final int dim = _daysInMonth(year, month);
  return DateTime(year, month, day > dim ? dim : day);
}

bool _isOccurrence(TaskSeries series, DateTime day) {
  final DateTime start = _dateOnly(series.startDate);
  if (day.isBefore(start)) return false;
  if (series.endDate != null && day.isAfter(_dateOnly(series.endDate!))) {
    return false;
  }

  switch (series.recurrenceType) {
    case RecurrenceType.none:
      return day == start;

    case RecurrenceType.daily:
      return true;

    case RecurrenceType.weekly:
      final weekdays =
          series.rule.weekdays.isNotEmpty ? series.rule.weekdays : [start.weekday];
      return weekdays.contains(day.weekday);

    case RecurrenceType.monthly:
      final target = _clampedMonthDay(day.year, day.month, start.day);
      return day == target;

    case RecurrenceType.yearly:
      // Feb 29 on a start date clamps to Feb 28 in non-leap years — same
      // clamping rule as monthly, applied to the start's month/day.
      final target = _clampedMonthDay(day.year, start.month, start.day);
      return day == target;

    case RecurrenceType.custom:
      switch (series.rule.unit) {
        case RecurrenceUnit.days:
          final int daysSince = day.difference(start).inDays;
          return daysSince % series.rule.interval == 0;
        case RecurrenceUnit.weeks:
          final weekdays = series.rule.weekdays.isNotEmpty
              ? series.rule.weekdays
              : [start.weekday];
          if (!weekdays.contains(day.weekday)) return false;
          // Bucketed by calendar week (Monday-start), not by consecutive
          // 7-day blocks from the start date — the latter could put a
          // weekday that's technically in the FOLLOWING calendar week into
          // the same bucket as the start date (whenever start isn't a
          // Monday), producing visually uneven gaps for interval-1 and
          // wrong inclusion/exclusion for interval>1 (HIDDEN_BUGS.md #6).
          final int weekIndex = _mondayOf(day).difference(_mondayOf(start)).inDays ~/ 7;
          return weekIndex % series.rule.interval == 0;
        case RecurrenceUnit.months:
          final int monthsSince =
              (day.year - start.year) * 12 + (day.month - start.month);
          if (monthsSince % series.rule.interval != 0) return false;
          final target = _clampedMonthDay(day.year, day.month, start.day);
          return day == target;
      }
  }
}

/// THE single source of truth for turning a task series into concrete
/// occurrence dates within a range (Step 10) — used by the calendar, and
/// nowhere else duplicates this logic. Returns each occurrence's full
/// date+time (start date's time-of-day applied to every occurrence).
/// [rangeStart]/[rangeEnd] are inclusive, date-only comparisons.
List<DateTime> getOccurrencesForDateRange(
  TaskSeries series,
  DateTime rangeStart,
  DateTime rangeEnd,
) {
  final DateTime from = _dateOnly(rangeStart);
  final DateTime to = _dateOnly(rangeEnd);
  final TimeOfDayParts time = TimeOfDayParts.from(series.startDate);

  final List<DateTime> occurrences = [];
  for (DateTime day = from;
      !day.isAfter(to);
      day = day.add(const Duration(days: 1))) {
    if (_isOccurrence(series, day)) {
      occurrences.add(
        DateTime(day.year, day.month, day.day, time.hour, time.minute),
      );
    }
  }
  return occurrences;
}

/// Picks the most relevant occurrence from a non-empty-checked [occurrences]
/// list near [now]: prefers the closest one that's already due (<= now),
/// only falling back to the closest future one if none are due yet.
/// Returns null for an empty list.
///
/// Both TaskDetailScreen and NotificationService's notification-tap
/// fallback need "which occurrence of this recurring task is the tap
/// about" and used to each sort by raw absolute time difference — which
/// could pick a future occurrence over a more relevant already-due one
/// (e.g. late at night, tomorrow's occurrence is closer in absolute time
/// than today's already-overdue one). See NOTIFICATION_BUGS.md finding #6.
DateTime? closestRelevantOccurrence(List<DateTime> occurrences, DateTime now) {
  if (occurrences.isEmpty) return null;
  final List<DateTime> due = occurrences.where((d) => !d.isAfter(now)).toList();
  final List<DateTime> candidates = due.isNotEmpty ? due : occurrences;
  candidates.sort((a, b) => a.difference(now).abs().compareTo(b.difference(now).abs()));
  return candidates.first;
}

/// The [count] most recent occurrence dates on/before [asOf] for [series],
/// computed DIRECTLY from the recurrence rule (date-only, newest first) —
/// works identically for daily, weekly, monthly, yearly and custom at ANY
/// frequency, because it never scans a fixed calendar window. Returns fewer
/// than [count] if the series hasn't occurred that many times since its
/// startDate.
///
/// Why not a day-by-day backward scan with a cap: 3 YEARLY occurrences span
/// ~730+ days, so any fixed-day cap either can't reach them or wastefully
/// steps over years. Direct per-rule arithmetic is bounded to [count]
/// iterations regardless of frequency. See
/// DESIGN_DECISIONS_IMPLEMENTATION_PLAN.md #3.
List<DateTime> previousOccurrences(TaskSeries series, DateTime asOf, {int count = 3}) {
  final DateTime start = _dateOnly(series.startDate);
  final DateTime end = _dateOnly(asOf);
  if (end.isBefore(start)) return const [];

  // Respect an endDate: never return an occurrence after the series ends.
  final DateTime ceiling =
      series.endDate != null && _dateOnly(series.endDate!).isBefore(end) ? _dateOnly(series.endDate!) : end;
  if (ceiling.isBefore(start)) return const [];

  final List<DateTime> out = [];

  // Appends [d] (date-only) if it's a genuine occurrence within bounds.
  // Returns true while more are still wanted, false once [count] is reached.
  bool addIfValid(DateTime d) {
    final DateTime day = _dateOnly(d);
    if (!day.isBefore(start) && !day.isAfter(ceiling) && _isOccurrence(series, day)) {
      out.add(day);
    }
    return out.length < count;
  }

  switch (series.recurrenceType) {
    case RecurrenceType.none:
      addIfValid(start); // a one-off's only occurrence is its start date
      break;

    case RecurrenceType.daily:
      for (DateTime d = ceiling; !d.isBefore(start); d = d.subtract(const Duration(days: 1))) {
        if (!addIfValid(d)) break;
      }
      break;

    case RecurrenceType.weekly:
      final weekdays = series.rule.weekdays.isNotEmpty ? series.rule.weekdays : [start.weekday];
      for (DateTime d = ceiling; !d.isBefore(start); d = d.subtract(const Duration(days: 1))) {
        if (weekdays.contains(d.weekday) && !addIfValid(d)) break;
      }
      break;

    case RecurrenceType.custom:
      switch (series.rule.unit) {
        case RecurrenceUnit.days:
          // Occurrences land on multiples of `interval` days from start.
          final int interval = series.rule.interval < 1 ? 1 : series.rule.interval;
          final int daysSince = ceiling.difference(start).inDays;
          final int stepsBack = daysSince - (daysSince % interval); // most recent occurrence <= ceiling
          for (int s = stepsBack; s >= 0; s -= interval) {
            if (!addIfValid(start.add(Duration(days: s)))) break;
          }
          break;
        case RecurrenceUnit.weeks:
          // _isOccurrence already encodes the interval-weeks + weekday-set
          // rule; walk back day-by-day, bounded by `count`.
          for (DateTime d = ceiling; !d.isBefore(start); d = d.subtract(const Duration(days: 1))) {
            if (_isOccurrence(series, d) && !addIfValid(d)) break;
          }
          break;
        case RecurrenceUnit.months:
          _addMonthlyBack(start, ceiling, series.rule.interval < 1 ? 1 : series.rule.interval, addIfValid);
          break;
      }
      break;

    case RecurrenceType.monthly:
      _addMonthlyBack(start, ceiling, 1, addIfValid);
      break;

    case RecurrenceType.yearly:
      // Subtract whole years from the anchor month/day, most recent first.
      for (int y = ceiling.year; y >= start.year; y--) {
        final DateTime cand = _clampedMonthDay(y, start.month, start.day);
        if (!cand.isAfter(ceiling) && !addIfValid(cand)) break;
      }
      break;
  }

  return out;
}

/// Shared monthly back-walk for [RecurrenceType.monthly] and custom-months:
/// subtract `intervalMonths` at a time from the anchor day (clamping short
/// months, e.g. 31st → 30/28), most recent occurrence ≤ [ceiling] first.
/// [tryAdd] returns false once enough occurrences have been collected.
void _addMonthlyBack(
  DateTime start,
  DateTime ceiling,
  int intervalMonths,
  bool Function(DateTime) tryAdd,
) {
  final int monthsSince = (ceiling.year - start.year) * 12 + (ceiling.month - start.month);
  if (monthsSince < 0) return;
  int m = monthsSince - (monthsSince % intervalMonths); // most recent step ≤ ceiling's month
  for (; m >= 0; m -= intervalMonths) {
    final int monthIndex = start.year * 12 + (start.month - 1) + m;
    final DateTime cand = _clampedMonthDay(monthIndex ~/ 12, (monthIndex % 12) + 1, start.day);
    if (cand.isAfter(ceiling)) continue; // start-day clamp can overshoot the ceiling month
    if (!tryAdd(cand)) break;
  }
}

/// Tiny helper so [getOccurrencesForDateRange] doesn't need TimeOfDay.
class TimeOfDayParts {
  final int hour;
  final int minute;
  const TimeOfDayParts(this.hour, this.minute);
  factory TimeOfDayParts.from(DateTime d) => TimeOfDayParts(d.hour, d.minute);
}

/// Human-readable summary shown in CreateTaskScreen and TaskDetailScreen,
/// e.g. "Repeats weekly on Mon, Wed" or "Repeats every 2 weeks on Fri".
String recurrenceSummary(RecurrenceType type, RecurrenceRule rule) {
  const weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String namesFor(List<int> weekdays) =>
      weekdays.map((w) => weekdayNames[w - 1]).join(', ');

  switch (type) {
    case RecurrenceType.none:
      return 'Does not repeat';
    case RecurrenceType.daily:
      return 'Repeats daily';
    case RecurrenceType.weekly:
      return 'Repeats weekly on ${namesFor(rule.weekdays)}';
    case RecurrenceType.monthly:
      return 'Repeats monthly';
    case RecurrenceType.yearly:
      return 'Repeats yearly';
    case RecurrenceType.custom:
      final String unit = rule.interval == 1
          ? rule.unit.label.toLowerCase().replaceAll(RegExp(r's$'), '')
          : rule.unit.label.toLowerCase();
      final String base = 'Repeats every ${rule.interval} $unit';
      return rule.unit == RecurrenceUnit.weeks && rule.weekdays.isNotEmpty
          ? '$base on ${namesFor(rule.weekdays)}'
          : base;
  }
}
