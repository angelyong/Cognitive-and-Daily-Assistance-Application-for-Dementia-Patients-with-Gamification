import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:testproject/models/game_catalog.dart';
import 'package:testproject/models/game_session.dart';
import 'package:testproject/models/risk_assessment.dart';
import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/services/risk_service.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_decorations.dart';
import 'package:testproject/theme/app_text_styles.dart';
import 'package:testproject/widgets/risk_badge.dart';
import '../../widgets/side_drawer.dart';

/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md), Section 1.6:
/// data surfacing + caregiver override UI for the Adaptive Difficulty
/// Engine. Per selected patient (same patient-selector pattern as
/// ActivityProgressScreen): every game's current level/source/frozen
/// state with Override/Resume-auto controls, an accuracy trend chart for
/// whichever game card is expanded (fl_chart — no chart package existed
/// before this task), and a combined, readable difficulty-change history
/// (the audit trail from `difficultyHistory` — a demo highlight).
///
/// PART 2: also shows the selected patient's risk status (badge + tap for
/// a signal breakdown + the riskHistory audit trail) right below the
/// patient selector, plus a debug-only "seed demo risk data" action so the
/// hard-to-trigger-live 3-signal rule can still be demonstrated (see
/// RiskService.seedDemoRiskData's doc comment).
class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final String _caregiverId = FirebaseAuth.instance.currentUser!.uid;

  List<Map<String, dynamic>> _patients = [];
  bool _loadingPatients = true;
  String? _selectedPatientId;
  String? _expandedGameId;

  String get _selectedPatientName {
    final match = _patients.where((p) => p['uid'] == _selectedPatientId);
    return match.isEmpty ? 'Patient' : (match.first['name'] ?? 'Patient') as String;
  }

  @override
  void initState() {
    super.initState();
    _loadPatients();
  }

  Future<void> _loadPatients() async {
    setState(() => _loadingPatients = true);
    try {
      final patients = await _firestoreService.getPatientsForCaregiver(_caregiverId);
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
            const Text('Statistics', style: AppTextStyles.heading),
            const SizedBox(height: 4),
            const Text(
              "A patient's game difficulty, accuracy trend, and change history.",
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
                        onChanged: (value) => setState(() {
                          _selectedPatientId = value;
                          _expandedGameId = null;
                        }),
                      ),
            const SizedBox(height: 18),
            if (_selectedPatientId == null)
              const Text(
                'Select a patient to view their statistics.',
                style: AppTextStyles.muted,
              )
            else ...[
              const Text('Risk Status', style: AppTextStyles.sectionTitle),
              const SizedBox(height: 10),
              _RiskStatusCard(
                patientId: _selectedPatientId!,
                patientName: _selectedPatientName,
              ),
              const SizedBox(height: 8),
              const Text('Risk Change History', style: AppTextStyles.sectionTitle),
              const SizedBox(height: 10),
              _RiskHistoryList(patientId: _selectedPatientId!),
              const SizedBox(height: 18),
              const Text('Game Difficulty', style: AppTextStyles.sectionTitle),
              const SizedBox(height: 4),
              const Text(
                'Tap a game to see its accuracy trend.',
                style: AppTextStyles.muted,
              ),
              const SizedBox(height: 10),
              for (final game in kGameCatalog) ...[
                _GameDifficultyCard(
                  patientId: _selectedPatientId!,
                  caregiverId: _caregiverId,
                  game: game,
                  expanded: _expandedGameId == game.id,
                  onToggleExpanded: () => setState(() {
                    _expandedGameId = _expandedGameId == game.id ? null : game.id;
                  }),
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 8),
              const Text('Difficulty Change History', style: AppTextStyles.sectionTitle),
              const SizedBox(height: 10),
              _HistoryList(patientId: _selectedPatientId!),
              const SizedBox(height: 20),
            ],
          ],
        ),
      ),
    );
  }
}

class _LevelDots extends StatelessWidget {
  final int level;
  const _LevelDots({required this.level});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final bool filled = i < level;
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? AppColors.orangeStart : AppColors.cardPurpleLight,
            ),
          ),
        );
      }),
    );
  }
}

class _GameDifficultyCard extends StatelessWidget {
  final String patientId;
  final String caregiverId;
  final GameCatalogEntry game;
  final bool expanded;
  final VoidCallback onToggleExpanded;

  const _GameDifficultyCard({
    required this.patientId,
    required this.caregiverId,
    required this.game,
    required this.expanded,
    required this.onToggleExpanded,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardPurple,
        borderRadius: BorderRadius.circular(16),
      ),
      child: StreamBuilder<DifficultyState>(
        stream: AdaptiveDifficultyService().watchState(patientId, game.id),
        builder: (context, snapshot) {
          final DifficultyState state = snapshot.data ?? DifficultyState.initial;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: onToggleExpanded,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            game.label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              _LevelDots(level: state.level),
                              Text(
                                'Level ${state.level}',
                                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                              ),
                              Text(
                                state.source == 'caregiver' ? 'Set by caregiver' : 'Auto',
                                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                              ),
                              if (state.frozen)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppColors.orangeEnd.withOpacity(0.18),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Text(
                                    'Frozen',
                                    style: TextStyle(
                                      color: AppColors.orangeEnd,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      color: AppColors.textMuted,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _showOverrideDialog(context, state),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.orangeStart,
                        side: const BorderSide(color: AppColors.orangeStart),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('Override'),
                    ),
                  ),
                  if (state.frozen) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => AdaptiveDifficultyService().resumeAuto(
                          patientId: patientId,
                          gameId: game.id,
                          caregiverId: caregiverId,
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.greenCheck,
                          side: const BorderSide(color: AppColors.greenCheck),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text('Resume Auto'),
                      ),
                    ),
                  ],
                ],
              ),
              if (expanded) ...[
                const SizedBox(height: 14),
                _AccuracyTrend(patientId: patientId, gameId: game.id),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _showOverrideDialog(BuildContext context, DifficultyState currentState) async {
    int selectedLevel = currentState.level;
    final TextEditingController reasonController = TextEditingController();

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final bool canSave = reasonController.text.trim().isNotEmpty;
          return AlertDialog(
            backgroundColor: AppColors.cardPurple,
            title: Text('Override — ${game.label}', style: const TextStyle(color: Colors.white)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Level', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                const SizedBox(height: 8),
                Row(
                  children: [1, 2, 3].map((level) {
                    final bool selected = selectedLevel == level;
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: OutlinedButton(
                          onPressed: () => setDialogState(() => selectedLevel = level),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: selected ? AppColors.orangeStart : Colors.transparent,
                            foregroundColor: selected ? Colors.white : AppColors.textMuted,
                            side: BorderSide(
                              color: selected ? AppColors.orangeStart : AppColors.cardPurpleLight,
                            ),
                          ),
                          child: Text('$level'),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: reasonController,
                  maxLines: 2,
                  style: const TextStyle(color: Colors.white),
                  decoration: AppDecorations.darkInput(
                    'Reason (required)',
                    hint: "e.g. patient frustrated this week",
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.orangeStart,
                  foregroundColor: Colors.white,
                ),
                onPressed: canSave ? () => Navigator.pop(dialogContext, true) : null,
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    if (confirmed != true) return;
    try {
      await AdaptiveDifficultyService().setCaregiverOverride(
        patientId: patientId,
        gameId: game.id,
        level: selectedLevel,
        caregiverId: caregiverId,
        reason: reasonController.text,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save override: $e')),
        );
      }
    }
  }
}

class _AccuracyTrend extends StatelessWidget {
  final String patientId;
  final String gameId;
  const _AccuracyTrend({required this.patientId, required this.gameId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<GameSession>>(
      stream: AdaptiveDifficultyService().watchRecentSessions(patientId, gameId, limit: 10),
      builder: (context, snapshot) {
        final List<GameSession> sessions = snapshot.data ?? const [];
        if (sessions.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No sessions played yet.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          );
        }

        // watchRecentSessions is newest-first; reverse for a left-to-right
        // (oldest-to-newest) trend line.
        final List<GameSession> chronological = sessions.reversed.toList();
        final List<FlSpot> spots = [
          for (int i = 0; i < chronological.length; i++)
            FlSpot(i.toDouble(), chronological[i].accuracy * 100),
        ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Accuracy trend (last ${chronological.length} session${chronological.length == 1 ? '' : 's'})',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 130,
              child: LineChart(
                LineChartData(
                  minY: 0,
                  maxY: 100,
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    show: true,
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 32,
                        interval: 50,
                        getTitlesWidget: (value, meta) => Text(
                          '${value.round()}%',
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
                      barWidth: 3,
                      dotData: const FlDotData(show: true),
                      belowBarData: BarAreaData(
                        show: true,
                        color: AppColors.orangeStart.withOpacity(0.12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HistoryList extends StatelessWidget {
  final String patientId;
  const _HistoryList({required this.patientId});

  String _reasonText(Map<String, dynamic> data) {
    final String reason = (data['reason'] ?? '') as String;
    switch (reason) {
      case 'auto_promote':
        return 'auto — 3 sessions ≥80% accuracy & ≤1 hint';
      case 'auto_demote':
        final stats = data['triggeringStats'] as Map<String, dynamic>?;
        final String rule = (stats?['rule'] as String?) ?? '';
        if (rule == 'most_recent_below_50') return 'auto — most recent session <50% accuracy';
        if (rule == 'last_2_below_60') return 'auto — last 2 sessions both <60% accuracy';
        return 'auto';
      case 'caregiver_override':
        final String overrideReason = (data['overrideReason'] as String?) ?? '';
        return "caregiver: '$overrideReason'";
      case 'caregiver_unfreeze':
        return 'caregiver resumed auto-adjustment';
      default:
        return reason;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: AdaptiveDifficultyService().watchHistory(patientId),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? const [];
        if (docs.isEmpty) {
          return const Text(
            'No difficulty changes yet.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          );
        }

        return Column(
          children: docs.map((doc) {
            final data = doc.data();
            final String gameId = (data['gameId'] ?? '') as String;
            final int fromLevel = (data['fromLevel'] as num?)?.toInt() ?? 0;
            final int toLevel = (data['toLevel'] as num?)?.toInt() ?? 0;
            final bool isUnfreeze = data['reason'] == 'caregiver_unfreeze';
            final ts = data['createdAt'];
            final String when = ts is Timestamp
                ? DateFormat('MMM d, h:mm a').format(ts.toDate())
                : 'just now';

            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.cardPurple,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isUnfreeze
                        ? '${gameLabelFor(gameId)}: resumed auto-adjustment'
                        : '${gameLabelFor(gameId)}: Level $fromLevel → $toLevel',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_reasonText(data)} · $when',
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

/// PART 2: current risk status for the selected patient — tap anywhere on
/// the card to see the full 3-signal breakdown (same dialog the badge
/// elsewhere opens). Re-evaluates once whenever the selected patient
/// changes (see RiskService's class doc comment for why "evaluate on
/// screen load" is this app's chosen trigger strategy) so the cached
/// status shown here is never more than one Statistics-screen visit stale.
class _RiskStatusCard extends StatefulWidget {
  final String patientId;
  final String patientName;
  const _RiskStatusCard({required this.patientId, required this.patientName});

  @override
  State<_RiskStatusCard> createState() => _RiskStatusCardState();
}

class _RiskStatusCardState extends State<_RiskStatusCard> {
  bool _seeding = false;

  @override
  void initState() {
    super.initState();
    RiskService().evaluateAndCache(widget.patientId);
  }

  @override
  void didUpdateWidget(covariant _RiskStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.patientId != widget.patientId) {
      RiskService().evaluateAndCache(widget.patientId);
    }
  }

  Future<void> _seedDemoData() async {
    setState(() => _seeding = true);
    try {
      await RiskService().seedDemoRiskData(widget.patientId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Demo risk data seeded — all 3 signals should now be active.'),
          ),
        );
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

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<RiskAssessment>(
      stream: RiskService().watchAssessment(widget.patientId),
      builder: (context, snapshot) {
        final RiskAssessment assessment = snapshot.data ?? RiskAssessment.initial;
        final bool atRisk = assessment.level == RiskLevel.atRisk;
        final Color statusColor = atRisk ? AppColors.riskRed : AppColors.greenCheck;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.cardPurple,
            borderRadius: BorderRadius.circular(16),
            border: atRisk ? Border.all(color: AppColors.riskRed, width: 1.5) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () => showRiskBreakdownDialog(context, widget.patientName, assessment),
                child: Row(
                  children: [
                    Icon(
                      atRisk ? Icons.warning_rounded : Icons.shield_outlined,
                      color: statusColor,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            atRisk ? 'At Risk' : 'No Risk Detected',
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Text(
                            'Tap for the signal breakdown',
                            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: AppColors.textMuted),
                  ],
                ),
              ),
              if (kDebugMode) ...[
                const SizedBox(height: 12),
                const Divider(color: AppColors.cardPurpleLight, height: 1),
                const SizedBox(height: 12),
                const Row(
                  children: [
                    Icon(Icons.science_outlined, size: 14, color: AppColors.textMuted),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Debug tool: fabricates data to trigger all 3 signals for a live demo.',
                        style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _seeding ? null : _seedDemoData,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.riskRed,
                      side: const BorderSide(color: AppColors.riskRed),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: _seeding
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.riskRed),
                          )
                        : const Text('Seed Demo Risk Data (Debug)'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _RiskHistoryList extends StatelessWidget {
  final String patientId;
  const _RiskHistoryList({required this.patientId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: RiskService().watchHistory(patientId),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? const [];
        if (docs.isEmpty) {
          return const Text(
            'No risk-level changes yet.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          );
        }

        return Column(
          children: docs.map((doc) {
            final data = doc.data();
            final bool becameAtRisk = (data['toLevel'] ?? 'none') == 'at_risk';
            final ts = data['evaluatedAt'];
            final String when = ts is Timestamp
                ? DateFormat('MMM d, h:mm a').format(ts.toDate())
                : 'just now';

            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.cardPurple,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    becameAtRisk ? Icons.warning_rounded : Icons.check_circle_outline,
                    size: 16,
                    color: becameAtRisk ? AppColors.riskRed : AppColors.greenCheck,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          becameAtRisk ? 'Became At Risk' : 'Risk cleared',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(when, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
