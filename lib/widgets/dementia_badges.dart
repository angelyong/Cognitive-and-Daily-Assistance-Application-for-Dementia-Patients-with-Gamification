import 'package:flutter/material.dart';

import 'package:testproject/models/dementia_profile.dart';

/// Small pill badge for a patient's dementia stage — a 2-dot progression
/// indicator (chosen over a numbered icon like Icons.looks_one/looks_two,
/// which reads as a plain number rather than "how far along") + label.
/// Matches the existing category-chip style from task_card.dart
/// (low-opacity background, full-opacity icon/text).
class DementiaStageBadge extends StatelessWidget {
  final String stage; // 'early' | 'middle'
  const DementiaStageBadge({super.key, required this.stage});

  @override
  Widget build(BuildContext context) {
    final DementiaStage value = DementiaStageX.fromFirestore(stage);
    final Color color = value.color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StageDots(filled: value.filledDots, color: color),
          const SizedBox(width: 6),
          Text(
            value.label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _StageDots extends StatelessWidget {
  final int filled; // out of 2
  final Color color;
  const _StageDots({required this.filled, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(2, (i) {
        final bool isFilled = i < filled;
        return Padding(
          padding: EdgeInsets.only(right: i == 0 ? 3 : 0),
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isFilled ? color : Colors.transparent,
              border: Border.all(color: color, width: 1.2),
            ),
          ),
        );
      }),
    );
  }
}

/// Small pill badge for a patient's dementia type — icon + label. Icons
/// are chosen for quick, distinct visual identification when scanning a
/// list, not as clinical symbolism.
class DementiaTypeBadge extends StatelessWidget {
  final String type; // 'alzheimers' | 'vascular'
  const DementiaTypeBadge({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    final DementiaType value = DementiaTypeX.fromFirestore(type);
    final Color color = value.color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(value.icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            value.label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
