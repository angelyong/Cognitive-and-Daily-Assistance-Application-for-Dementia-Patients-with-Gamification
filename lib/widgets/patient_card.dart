import 'package:flutter/material.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_decorations.dart';
import 'package:testproject/widgets/dementia_badges.dart';
import 'package:testproject/widgets/risk_badge.dart';

/// A single patient row shown in the caregiver's "Manage Patients" list.
class PatientCard extends StatelessWidget {
  final String name;
  final VoidCallback? onTap;
  /// Null for a patient created before this field existed — badges are
  /// simply omitted rather than showing a default/guessed value.
  final String? dementiaStage;
  final String? dementiaType;
  /// PART 2: when set, shows the caregiver-only red "At Risk" badge next
  /// to the name (see risk_badge.dart) — null simply omits it, same
  /// pattern as the stage/type badges above.
  final String? patientId;

  const PatientCard({
    super.key,
    required this.name,
    this.onTap,
    this.dementiaStage,
    this.dementiaType,
    this.patientId,
  });

  String get _initials {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed.split(' ');
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: AppDecorations.card,
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: AppColors.orangeEnd,
              child: Text(
                _initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (patientId != null)
                        PatientRiskBadge(patientId: patientId!, patientName: name),
                    ],
                  ),
                  if (dementiaStage != null || dementiaType != null) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (dementiaStage != null)
                          DementiaStageBadge(stage: dementiaStage!),
                        if (dementiaType != null)
                          DementiaTypeBadge(type: dementiaType!),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
