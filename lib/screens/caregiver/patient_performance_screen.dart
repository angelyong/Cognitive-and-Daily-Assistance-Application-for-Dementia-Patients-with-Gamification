import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:testproject/models/performance_snapshot.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/services/performance_analytics_service.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_decorations.dart';
import 'package:testproject/theme/app_text_styles.dart';
import 'package:testproject/widgets/session_guard.dart';
import 'package:testproject/widgets/side_drawer.dart';
import 'game_statistic_screen.dart';

enum _TrendTab { accuracy, sessions, hints }

/// Bird's-eye, all-games-at-once view of a patient's cognitive-game and
/// task performance (see PERFORMANCE_DASHBOARD_PLAN.md) — the KPI-tiles-
/// plus-charts dashboard shape, as opposed to GameStatisticScreen's
/// per-game depth (level/override/history for one game at a time).
/// Everything here is computed by PerformanceAnalyticsService from
/// `gameSessions`/`tasks`/`users` — this screen owns no aggregation logic
/// of its own, same separation GameStatisticScreen already has from
/// AdaptiveDifficultyService.
///
/// This is now the screen the caregiver drawer's "Statistics" item opens;
/// GameStatisticScreen is reached FROM here (or from Edit Patient), not
/// directly from the drawer anymore.
class PatientPerformanceScreen extends StatefulWidget {
  final String? initialPatientId;
  const PatientPerformanceScreen({super.key, this.initialPatientId});

  @override
  State<PatientPerformanceScreen> createState() => _PatientPerformanceScreenState();
}

class _PatientPerformanceScreenState extends State<PatientPerformanceScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  late final String _caregiverId;
  bool _hasSession = true;

  List<Map<String, dynamic>> _patients = [];
  bool _loadingPatients = true;
  String? _selectedPatientId;
  PerformancePeriod _period = PerformancePeriod.last30Days;
  _TrendTab _trendTab = _TrendTab.accuracy;
  Future<PerformanceSnapshot>? _snapshotFuture;
  bool _seeding = false;
  bool _clearing = false;

  String get _selectedPatientName {
    final match = _patients.where((p) => p['uid'] == _selectedPatientId);
    return match.isEmpty ? 'Patient' : (match.first['name'] ?? 'Patient') as String;
  }

  @override
  void initState() {
    super.initState();
    final String? uid = requireSessionUid(context);
    if (uid == null) {
      _hasSession = false;
      return;
    }
    _caregiverId = uid;
    _selectedPatientId = widget.initialPatientId;
    _loadPatients();
  }

  Future<void> _loadPatients() async {
    setState(() => _loadingPatients = true);
    try {
      final patients = await _firestoreService.getPatientsForCaregiver(_caregiverId);
      setState(() {
        _patients = patients;
        _loadingPatients = false;
        final bool selectedStillValid =
            _selectedPatientId != null && patients.any((p) => p['uid'] == _selectedPatientId);
        if (!selectedStillValid && patients.isNotEmpty) {
          _selectedPatientId = patients.first['uid'];
        }
      });
      _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingPatients = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load patients: $e')),
      );
    }
  }

  void _reload() {
    final String? patientId = _selectedPatientId;
    setState(() {
      _snapshotFuture =
          patientId == null ? null : PerformanceAnalyticsService().loadSnapshot(patientId, _period);
    });
  }

  Future<void> _seedDemoData() async {
    final String? patientId = _selectedPatientId;
    if (patientId == null) return;
    setState(() => _seeding = true);
    try {
      await PerformanceAnalyticsService().seedDemoPerformanceData(patientId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Demo performance data seeded.')),
        );
        _reload();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to seed demo data: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _seeding = false);
    }
  }

  Future<void> _clearDemoData() async {
    final String? patientId = _selectedPatientId;
    if (patientId == null) return;
    setState(() => _clearing = true);
    try {
      await PerformanceAnalyticsService().clearDemoPerformanceData(patientId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Demo performance data cleared.')),
        );
        _reload();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to clear demo data: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasSession) return const SessionRedirectPlaceholder();
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
            const Text('Patient Performance', style: AppTextStyles.heading),
            const SizedBox(height: 4),
            const Text(
              "An overall view of a patient's accuracy, sessions, and task completion.",
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
                        onChanged: (value) {
                          setState(() => _selectedPatientId = value);
                          _reload();
                        },
                      ),
            const SizedBox(height: 16),
            if (_selectedPatientId == null)
              const Text(
                'Select a patient to view their performance.',
                style: AppTextStyles.muted,
              )
            else ...[
              _PeriodSelector(
                selected: _period,
                onChanged: (p) {
                  setState(() => _period = p);
                  _reload();
                },
              ),
              const SizedBox(height: 16),
              FutureBuilder<PerformanceSnapshot>(
                future: _snapshotFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: CircularProgressIndicator(color: AppColors.orangeStart),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return Text(
                      'Failed to load performance data: ${snapshot.error}',
                      style: const TextStyle(color: Colors.white),
                    );
                  }
                  final PerformanceSnapshot data = snapshot.data ?? PerformanceSnapshot.empty;
                  return _DashboardBody(
                    data: data,
                    trendTab: _trendTab,
                    onTrendTabChanged: (t) => setState(() => _trendTab = t),
                    onOpenGameStatistic: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => GameStatisticScreen(initialPatientId: _selectedPatientId),
                      ),
                    ),
                    seeding: _seeding,
                    clearing: _clearing,
                    onSeedDemoData: _seedDemoData,
                    onClearDemoData: _clearDemoData,
                    patientName: _selectedPatientName,
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  final PerformancePeriod selected;
  final ValueChanged<PerformancePeriod> onChanged;
  const _PeriodSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final period in PerformancePeriod.values) ...[
          Expanded(
            child: OutlinedButton(
              onPressed: () => onChanged(period),
              style: OutlinedButton.styleFrom(
                backgroundColor: selected == period ? AppColors.orangeStart : AppColors.cardPurple,
                foregroundColor: selected == period ? Colors.white : AppColors.textMuted,
                side: BorderSide(
                  color: selected == period ? AppColors.orangeStart : AppColors.cardPurpleLight,
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(period.label, style: const TextStyle(fontSize: 12)),
            ),
          ),
          if (period != PerformancePeriod.values.last) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _DashboardBody extends StatelessWidget {
  final PerformanceSnapshot data;
  final _TrendTab trendTab;
  final ValueChanged<_TrendTab> onTrendTabChanged;
  final VoidCallback onOpenGameStatistic;
  final bool seeding;
  final bool clearing;
  final VoidCallback onSeedDemoData;
  final VoidCallback onClearDemoData;
  final String patientName;

  const _DashboardBody({
    required this.data,
    required this.trendTab,
    required this.onTrendTabChanged,
    required this.onOpenGameStatistic,
    required this.seeding,
    required this.clearing,
    required this.onSeedDemoData,
    required this.onClearDemoData,
    required this.patientName,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- KPI tiles (2x2) ----
        Row(
          children: [
            Expanded(
              child: _KpiTile(
                label: 'Average Accuracy',
                value: '${(data.averageAccuracy.current * 100).round()}%',
                delta: data.averageAccuracy.deltaPercent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _KpiTile(
                label: 'Sessions Played',
                value: data.sessionsPlayed.current.round().toString(),
                delta: data.sessionsPlayed.deltaPercent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _KpiTile(
                label: 'Task Completion Rate',
                value: '${(data.taskCompletionRate.current * 100).round()}%',
                delta: data.taskCompletionRate.deltaPercent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _KpiTile(
                label: 'Avg. Hints / Session',
                value: data.averageHints.current.toStringAsFixed(1),
                delta: data.averageHints.deltaPercent,
                lowerIsBetter: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // ---- Streak / points — smaller card ----
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.cardPurple,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.local_fire_department, color: AppColors.orangeStart, size: 20),
              const SizedBox(width: 10),
              Text(
                'Day ${data.currentStreak} streak',
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                '${data.streakPoints} points',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),

        const SizedBox(height: 22),
        const Text('Performance Trend', style: AppTextStyles.sectionTitle),
        const SizedBox(height: 10),
        _TrendTabBar(selected: trendTab, onChanged: onTrendTabChanged),
        const SizedBox(height: 12),
        _TrendChart(tab: trendTab, points: _pointsFor(trendTab)),

        const SizedBox(height: 22),
        const Text('Accuracy by Game', style: AppTextStyles.sectionTitle),
        const SizedBox(height: 4),
        const Text(
          'Games not played in this period are not shown.',
          style: AppTextStyles.muted,
        ),
        const SizedBox(height: 10),
        _AccuracyByGameList(bars: data.accuracyByGame),

        const SizedBox(height: 22),
        const Text('Tasks by Category', style: AppTextStyles.sectionTitle),
        const SizedBox(height: 10),
        _TasksByCategoryChart(bars: data.tasksByCategory),

        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: onOpenGameStatistic,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.orangeStart,
              side: const BorderSide(color: AppColors.orangeStart),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.tune),
            label: const Text('View / Adjust Game Difficulty'),
          ),
        ),

        if (kDebugMode) ...[
          const SizedBox(height: 20),
          const Divider(color: AppColors.cardPurpleLight),
          const SizedBox(height: 12),
          const Row(
            children: [
              Icon(Icons.science_outlined, size: 14, color: AppColors.textMuted),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Debug tools: fabricate ~30 days of spread-out activity so every '
                  'chart above has real data to render.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: seeding ? null : onSeedDemoData,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.orangeStart,
                    side: const BorderSide(color: AppColors.orangeStart),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: seeding
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.orangeStart),
                        )
                      : const Text('Seed Demo Data (Debug)'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: clearing ? null : onClearDemoData,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textMuted,
                    side: const BorderSide(color: AppColors.cardPurpleLight),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: clearing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textMuted),
                        )
                      : const Text('Clear Demo Data'),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 20),
      ],
    );
  }

  List<ChartPoint> _pointsFor(_TrendTab tab) {
    switch (tab) {
      case _TrendTab.accuracy:
        return data.dailyAccuracy;
      case _TrendTab.sessions:
        return data.dailySessions;
      case _TrendTab.hints:
        return data.dailyHints;
    }
  }
}

class _KpiTile extends StatelessWidget {
  final String label;
  final String value;
  final double? delta;
  final bool lowerIsBetter;

  const _KpiTile({
    required this.label,
    required this.value,
    required this.delta,
    this.lowerIsBetter = false,
  });

  @override
  Widget build(BuildContext context) {
    final double? d = delta;
    // For "lower is better" tiles (hints), a falling number is the good
    // direction — invert which color/arrow reads as positive.
    final bool? isGood = d == null ? null : (lowerIsBetter ? d < 0 : d > 0);
    final Color trendColor = isGood == null
        ? AppColors.textMuted
        : (isGood ? AppColors.greenCheck : AppColors.orangeEnd);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardPurple,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              ),
              if (d != null) ...[
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(
                        d >= 0 ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 12,
                        color: trendColor,
                      ),
                      Text(
                        '${d.abs().round()}%',
                        style: TextStyle(color: trendColor, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _TrendTabBar extends StatelessWidget {
  final _TrendTab selected;
  final ValueChanged<_TrendTab> onChanged;
  const _TrendTabBar({required this.selected, required this.onChanged});

  String _labelFor(_TrendTab tab) {
    switch (tab) {
      case _TrendTab.accuracy:
        return 'Accuracy';
      case _TrendTab.sessions:
        return 'Sessions';
      case _TrendTab.hints:
        return 'Hints';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final tab in _TrendTab.values) ...[
          ChoiceChip(
            label: Text(_labelFor(tab)),
            selected: selected == tab,
            onSelected: (_) => onChanged(tab),
            labelStyle: TextStyle(
              color: selected == tab ? Colors.white : AppColors.textMuted,
              fontWeight: FontWeight.w600,
            ),
            backgroundColor: AppColors.cardPurple,
            selectedColor: AppColors.orangeStart,
            side: BorderSide.none,
          ),
          const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _TrendChart extends StatelessWidget {
  final _TrendTab tab;
  final List<ChartPoint> points;
  const _TrendChart({required this.tab, required this.points});

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty || points.every((p) => p.value == 0)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Text(
          'No activity recorded in this period yet.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      );
    }

    final bool isPercent = tab == _TrendTab.accuracy;
    final List<FlSpot> spots = [
      for (int i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), isPercent ? points[i].value * 100 : points[i].value),
    ];
    final double maxY = isPercent
        ? 100
        : (spots.map((s) => s.y).fold<double>(0, (a, b) => a > b ? a : b) * 1.3).clamp(1, double.infinity);

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
      decoration: BoxDecoration(color: AppColors.cardPurple, borderRadius: BorderRadius.circular(16)),
      height: 180,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            show: true,
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                interval: (points.length / 4).clamp(1, double.infinity).roundToDouble(),
                getTitlesWidget: (value, meta) {
                  final int i = value.round();
                  if (i < 0 || i >= points.length) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      DateFormat('d/M').format(points[i].day),
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 9),
                    ),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 32,
                getTitlesWidget: (value, meta) => Text(
                  isPercent ? '${value.round()}%' : value.round().toString(),
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
                ),
              ),
            ),
          ),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: AppColors.orangeStart,
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: true, color: AppColors.orangeStart.withOpacity(0.12)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rendered as ranked horizontal bars, not a vertical fl_chart BarChart —
/// with up to 13 games and labels as long as "What Made That Sound?",
/// vertical bars with bottom-axis labels don't fit a phone width legibly.
class _AccuracyByGameList extends StatelessWidget {
  final List<GameBar> bars;
  const _AccuracyByGameList({required this.bars});

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty) {
      return const Text(
        'No games played in this period yet.',
        style: TextStyle(color: AppColors.textMuted, fontSize: 12),
      );
    }
    final sorted = [...bars]..sort((a, b) => b.averageAccuracy.compareTo(a.averageAccuracy));
    return Column(
      children: [
        for (final bar in sorted)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    bar.label,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: bar.averageAccuracy.clamp(0, 1),
                      minHeight: 10,
                      backgroundColor: AppColors.cardPurpleLight,
                      valueColor: const AlwaysStoppedAnimation(AppColors.orangeStart),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(bar.averageAccuracy * 100).round()}%',
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TasksByCategoryChart extends StatelessWidget {
  final List<CategoryBar> bars;
  const _TasksByCategoryChart({required this.bars});

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Text(
          'No completed tasks recorded in this period yet.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      );
    }
    final double maxCount =
        bars.map((b) => b.completedCount).fold<int>(0, (a, b) => a > b ? a : b).toDouble();

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
      decoration: BoxDecoration(color: AppColors.cardPurple, borderRadius: BorderRadius.circular(16)),
      height: 200,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: (maxCount * 1.3).clamp(1, double.infinity),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          barTouchData: BarTouchData(enabled: false),
          titlesData: FlTitlesData(
            show: true,
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                getTitlesWidget: (value, meta) => Text(
                  value.round().toString(),
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                getTitlesWidget: (value, meta) {
                  final int i = value.round();
                  if (i < 0 || i >= bars.length) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      bars[i].category,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 9),
                      textAlign: TextAlign.center,
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (int i = 0; i < bars.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: bars[i].completedCount.toDouble(),
                    color: AppColors.greenCheck,
                    width: 16,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
