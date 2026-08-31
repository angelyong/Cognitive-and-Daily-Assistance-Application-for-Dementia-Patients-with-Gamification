import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:testproject/models/risk_assessment.dart';
import 'package:testproject/services/risk_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// PART 2 (adaptive_difficulty_and_risk_indicator_prompt.md) — the
/// caregiver-only red warning badge shown next to an at-risk patient's
/// name, and the tap-to-see-breakdown dialog explaining WHY. Never used on
/// any patient-facing screen — risk info is caregiver-only by design.
class RiskBadge extends StatelessWidget {
  final RiskAssessment assessment;
  final String patientName;

  const RiskBadge({super.key, required this.assessment, required this.patientName});

  @override
  Widget build(BuildContext context) {
    // none → no badge at all. monitor → amber "Needs Attention". atRisk → red
    // "At Risk". (Previously only atRisk rendered, so a 2-of-3 patient looked
    // identical to a 0-of-3 one — see DESIGN_DECISIONS_IMPLEMENTATION_PLAN.md #4.)
    if (assessment.level == RiskLevel.none) return const SizedBox.shrink();

    final bool atRisk = assessment.level == RiskLevel.atRisk;
    final Color color = atRisk ? AppColors.riskRed : AppColors.riskAmber;
    final String label = atRisk ? 'At Risk' : 'Needs Attention';
    final IconData icon = atRisk ? Icons.warning_rounded : Icons.error_outline;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => showRiskBreakdownDialog(context, patientName, assessment),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.18),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// Triggers a fresh evaluation once when first shown (see RiskService's
/// class doc comment for why "evaluate on every caregiver screen load" is
/// the chosen trigger strategy), then renders the live cached badge — used
/// identically by PatientCard/HomeScreen/GameStatisticScreen so none of them
/// duplicate this trigger-then-watch logic.
class PatientRiskBadge extends StatefulWidget {
  final String patientId;
  final String patientName;
  const PatientRiskBadge({super.key, required this.patientId, required this.patientName});

  @override
  State<PatientRiskBadge> createState() => _PatientRiskBadgeState();
}

class _PatientRiskBadgeState extends State<PatientRiskBadge> {
  @override
  void initState() {
    super.initState();
    RiskService().evaluateAndCache(widget.patientId);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<RiskAssessment>(
      stream: RiskService().watchAssessment(widget.patientId),
      builder: (context, snapshot) {
        final RiskAssessment assessment = snapshot.data ?? RiskAssessment.initial;
        return RiskBadge(assessment: assessment, patientName: widget.patientName);
      },
    );
  }
}

Future<void> showRiskBreakdownDialog(
  BuildContext context,
  String patientName,
  RiskAssessment assessment,
) {
  final RiskSignals signals = assessment.signals;
  final RiskLevel level = assessment.level;
  final bool atRisk = level == RiskLevel.atRisk;
  final bool monitor = level == RiskLevel.monitor;
  final Color statusColor = atRisk
      ? AppColors.riskRed
      : monitor
          ? AppColors.riskAmber
          : AppColors.greenCheck;
  final String title = atRisk
      ? '$patientName — At Risk'
      : monitor
          ? '$patientName — Needs Attention'
          : '$patientName — No Risk Detected';
  final IconData titleIcon = atRisk
      ? Icons.warning_rounded
      : monitor
          ? Icons.error_outline
          : Icons.shield_outlined;
  final String intro = atRisk
      ? 'All 3 signals below are true at the same time:'
      : monitor
          ? '2 of the 3 signals below are active — an early warning. At Risk (red) triggers only when all 3 are true at once:'
          : 'At Risk triggers only when all 3 signals below are true at once (2 of 3 shows an amber early warning):';

  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.cardPurple,
      title: Row(
        children: [
          Icon(titleIcon, color: statusColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 17),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            intro,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 12),
          _SignalRow(
            met: signals.missedTasks,
            label: '3+ consecutive missed tasks',
            detail: '${signals.consecutiveMissedCount} missed in a row',
          ),
          _SignalRow(
            met: signals.scoreDrop,
            label: 'Cognitive score down 20%+',
            detail: signals.sessionsConsidered < 10
                ? 'Needs 10+ sessions (has ${signals.sessionsConsidered})'
                : '${((signals.scoreDropPercent ?? 0) * 100).round()}% drop (last 5 vs previous 5 sessions)',
          ),
          _SignalRow(
            met: signals.inactivity,
            label: '3+ days inactive',
            detail: signals.inactivityDays == null
                ? 'No recorded activity yet'
                : '${signals.inactivityDays} days since last activity',
          ),
          const SizedBox(height: 12),
          Text(
            assessment.evaluatedAt == null
                ? 'Evaluated just now'
                : 'Last evaluated ${DateFormat('MMM d, h:mm a').format(assessment.evaluatedAt!)}',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: AppColors.orangeStart),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _SignalRow extends StatelessWidget {
  final bool met;
  final String label;
  final String detail;
  const _SignalRow({required this.met, required this.label, required this.detail});

  @override
  Widget build(BuildContext context) {
    final Color color = met ? AppColors.riskRed : AppColors.textMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(met ? Icons.check_circle : Icons.circle_outlined, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
                Text(detail, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
