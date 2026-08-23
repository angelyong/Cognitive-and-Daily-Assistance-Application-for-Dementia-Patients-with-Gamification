import 'package:flutter/material.dart';
import 'package:testproject/theme/app_colors.dart';

class TaskCard extends StatelessWidget {
  final String taskId;
  final String title;
  final String time;
  final String category;
  final String status;
  // Nullable so a caller can disable the tick (e.g. a patient can't untick
  // a completed task — see PatientDashboard) by passing null instead of a
  // callback; InkWell treats onTap: null as disabled automatically.
  final VoidCallback? onToggle;
  final VoidCallback? onTap;

  const TaskCard({
    super.key,
    required this.taskId,
    required this.title,
    required this.time,
    required this.category,
    required this.status,
    required this.onToggle,
    this.onTap,
  });
 
  bool get _isCompleted => status == 'completed';
  bool get _isMissed => status == 'missed';
 
  IconData get _statusIcon {
    if (_isCompleted) return Icons.check_circle;
    if (_isMissed) return Icons.cancel;
    return Icons.radio_button_unchecked;
  }
 
  Color get _statusColor {
    if (_isCompleted) return AppColors.greenCheck;
    if (_isMissed) return AppColors.orangeEnd;
    return Colors.white54;
  }
 
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardPurple,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: _isMissed ? null : onToggle,
            child: Icon(_statusIcon, color: _statusColor, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: _isMissed
                          ? AppColors.orangeEnd
                          : (_isCompleted ? Colors.white54 : Colors.white),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      decoration: _isCompleted || _isMissed
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                      decorationColor:
                          _isMissed ? AppColors.orangeEnd : Colors.white54,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.access_time,
                          size: 13, color: AppColors.textMuted),
                      const SizedBox(width: 4),
                      Text(
                        time,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                      if (_isMissed) ...[
                        const SizedBox(width: 8),
                        const Text(
                          'Missed',
                          style: TextStyle(
                            color: AppColors.orangeEnd,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (category.isNotEmpty)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.categoryChipBg,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                category,
                style: const TextStyle(
                  color: AppColors.categoryChipText,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class MedicationCard extends StatelessWidget {
  final String taskId;
  final String title;
  final String time;
  final String description;
  final String dosage;
  final String status;
  // Nullable so a caller can disable the tick (e.g. a patient can't untick
  // a completed task — see PatientDashboard) by passing null instead of a
  // callback; InkWell treats onTap: null as disabled automatically.
  final VoidCallback? onToggle;
  final VoidCallback? onTap;

  const MedicationCard({
    super.key,
    required this.taskId,
    required this.title,
    required this.time,
    required this.description,
    this.dosage = '',
    required this.status,
    required this.onToggle,
    this.onTap,
  });

  bool get _isCompleted => status == 'completed';
  bool get _isMissed => status == 'missed';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardPurple,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.medIconBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.medication,
              color: _isMissed ? AppColors.orangeEnd : AppColors.greenCheck,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: _isMissed
                          ? AppColors.orangeEnd
                          : (_isCompleted ? Colors.white54 : Colors.white),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      decoration: _isCompleted || _isMissed
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                      decorationColor:
                          _isMissed ? AppColors.orangeEnd : Colors.white54,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description.isNotEmpty ? '$description • $time' : time,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  // Dosage is its own line — UC-05 step 7 treats time,
                  // dosage, and description as three separate pieces of
                  // information, not one merged string.
                  if (dosage.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Dosage: $dosage',
                      style: const TextStyle(
                        color: AppColors.categoryChipText,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Tappable unless the caller disabled it (onToggle: null).
          InkWell(
            onTap: onToggle,
            child: Icon(
              _isCompleted
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: _isCompleted ? AppColors.greenCheck : Colors.white54,
              size: 24,
            ),
          ),
        ],
      ),
    );
  }
}