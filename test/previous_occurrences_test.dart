import 'package:flutter_test/flutter_test.dart';
import 'package:testproject/models/task_recurrence.dart';

// Verifies previousOccurrences() — the recurrence-aware "last N due dates"
// helper that replaced risk_service's fixed 7-day lookback
// (DESIGN_DECISIONS_IMPLEMENTATION_PLAN.md #3). Pure date logic, no Firestore.

TaskSeries series(
  DateTime start,
  RecurrenceType type, {
  List<int> weekdays = const [],
  int interval = 1,
  RecurrenceUnit unit = RecurrenceUnit.days,
  DateTime? endDate,
}) {
  return TaskSeries(
    taskId: 't',
    startDate: start,
    recurrenceType: type,
    rule: RecurrenceRule(weekdays: weekdays, interval: interval, unit: unit),
    endDate: endDate,
  );
}

DateTime d(int y, int m, int day) => DateTime(y, m, day);

void main() {
  group('previousOccurrences', () {
    test('none returns the single start date when on/before asOf', () {
      final s = series(d(2026, 3, 10), RecurrenceType.none);
      expect(previousOccurrences(s, d(2026, 3, 20)), [d(2026, 3, 10)]);
      // asOf before start → nothing
      expect(previousOccurrences(s, d(2026, 3, 1)), isEmpty);
    });

    test('daily returns the last 3 consecutive days, newest first', () {
      final s = series(d(2026, 1, 1), RecurrenceType.daily);
      expect(previousOccurrences(s, d(2026, 6, 15)), [
        d(2026, 6, 15),
        d(2026, 6, 14),
        d(2026, 6, 13),
      ]);
    });

    test('weekly with multiple weekdays picks the latest 3 matching days', () {
      // Mon(1) & Wed(3). asOf Fri 2026-06-19.
      final s = series(d(2026, 6, 1), RecurrenceType.weekly, weekdays: [1, 3]);
      final got = previousOccurrences(s, d(2026, 6, 19));
      // Most recent Wed = 17th, Mon = 15th, prev Wed = 10th.
      expect(got, [d(2026, 6, 17), d(2026, 6, 15), d(2026, 6, 10)]);
    });

    test('monthly clamps the day in short months', () {
      // Start on the 31st; Feb/Apr must clamp.
      final s = series(d(2026, 1, 31), RecurrenceType.monthly);
      final got = previousOccurrences(s, d(2026, 4, 15));
      // Occurrences <= Apr 15: Mar 31, Feb 28, Jan 31 (Apr 30 is after asOf).
      expect(got, [d(2026, 3, 31), d(2026, 2, 28), d(2026, 1, 31)]);
    });

    test('yearly retrieves 3 occurrences spanning multiple years', () {
      final s = series(d(2020, 5, 10), RecurrenceType.yearly);
      final got = previousOccurrences(s, d(2026, 8, 1));
      expect(got, [d(2026, 5, 10), d(2025, 5, 10), d(2024, 5, 10)]);
    });

    test('yearly on Feb 29 clamps to Feb 28 in non-leap years', () {
      final s = series(d(2020, 2, 29), RecurrenceType.yearly);
      final got = previousOccurrences(s, d(2023, 6, 1));
      // 2023 & 2022 clamp to Feb 28; 2021 clamps to Feb 28.
      expect(got, [d(2023, 2, 28), d(2022, 2, 28), d(2021, 2, 28)]);
    });

    test('custom every-2-days lands on the right parity', () {
      final s = series(d(2026, 6, 1), RecurrenceType.custom, interval: 2, unit: RecurrenceUnit.days);
      // From start, occurrences are Jun 1,3,5,7,9,11,13,15...
      final got = previousOccurrences(s, d(2026, 6, 14));
      expect(got, [d(2026, 6, 13), d(2026, 6, 11), d(2026, 6, 9)]);
    });

    test('custom every-3-months clamps and steps by interval', () {
      final s = series(d(2025, 1, 31), RecurrenceType.custom, interval: 3, unit: RecurrenceUnit.months);
      // Occurrences: Jan 31, Apr 30, Jul 31, Oct 31, 2026 Jan 31 ...
      final got = previousOccurrences(s, d(2026, 2, 1));
      expect(got, [d(2026, 1, 31), d(2025, 10, 31), d(2025, 7, 31)]);
    });

    test('respects endDate — never returns an occurrence after the series ends', () {
      final s = series(d(2026, 1, 1), RecurrenceType.daily, endDate: d(2026, 1, 5));
      final got = previousOccurrences(s, d(2026, 1, 20));
      expect(got, [d(2026, 1, 5), d(2026, 1, 4), d(2026, 1, 3)]);
    });

    test('returns fewer than count when the series is young', () {
      final s = series(d(2026, 6, 18), RecurrenceType.daily);
      expect(previousOccurrences(s, d(2026, 6, 19)), [d(2026, 6, 19), d(2026, 6, 18)]);
    });

    test('every returned date is a genuine occurrence (matches the calendar)', () {
      // Cross-check against getOccurrencesForDateRange for a weekly series.
      final s = series(d(2026, 3, 2), RecurrenceType.weekly, weekdays: [1, 4]); // Mon, Thu
      final got = previousOccurrences(s, d(2026, 4, 30), count: 5);
      final all = getOccurrencesForDateRange(s, d(2026, 3, 2), d(2026, 4, 30))
          .map((e) => DateTime(e.year, e.month, e.day))
          .toList();
      for (final occ in got) {
        expect(all.contains(occ), isTrue, reason: '$occ should be a real occurrence');
      }
    });
  });
}
