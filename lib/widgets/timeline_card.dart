import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:testproject/theme/app_colors.dart';

/// Shared time-display formatting for task cards — cards used to read a
/// `time` String field nothing in the app ever wrote (always blank in
/// practice). Every display site derives this from `dueDate` instead,
/// through this one helper, rather than scattering `DateFormat` calls.
String formatCardTime(DateTime dateTime) => DateFormat('h:mm a').format(dateTime);

/// "in 1h 5m" / "in 45m" / "now" — used by the "Up Next" caption.
String formatCountdown(Duration remaining) {
  if (remaining.isNegative) return 'now';
  final int hours = remaining.inHours;
  final int minutes = remaining.inMinutes.remainder(60);
  if (hours > 0 && minutes > 0) return 'in ${hours}h ${minutes}m';
  if (hours > 0) return 'in ${hours}h';
  return 'in ${minutes}m';
}

/// Small accent colour per category, shown as a dot next to the category
/// label on each timeline card — purely visual grouping, not a new data
/// concept (categories are still the same plain strings CreateTaskScreen
/// already saves).
Color categoryDotColor(String category) {
  switch (category.toLowerCase()) {
    case 'medication':
      return const Color(0xFFFF9AB8);
    case 'exercise':
      return AppColors.greenCheck;
    case 'meal':
      return AppColors.orangeStart;
    case 'hygiene':
      return const Color(0xFF5AC8FA);
    case 'social':
      return const Color(0xFFB39DDB);
    case 'appointment':
      return const Color(0xFF7C83FD);
    default:
      return AppColors.textMuted;
  }
}

/// One row of the daily timeline — see daily_routine_timeline_prompt.md.
/// Draws its own vertical connector-line segment + dot, so stacking many
/// of these in a Column produces one continuous line down the list; each
/// row's line spans its own full height (via IntrinsicHeight, matching
/// the card's height including its bottom margin), so consecutive dots
/// connect with no visible gaps. [isFirst]/[isLast] trim the stray line
/// stub above the first dot / below the last one.
///
/// Replaces TaskCard/MedicationCard wherever a merged chronological
/// timeline is shown (patient dashboard; each patient's section on the
/// caregiver's HomeScreen) — those two widgets are still used wherever a
/// screen isn't a timeline (e.g. none currently, kept for potential reuse).
class TimelineCard extends StatelessWidget {
  final String title;
  final String category;
  final String dosage;
  final String status; // 'pending' | 'completed' | 'missed'
  final DateTime? time; // null = "Anytime" (no due date)
  final bool isNext;
  final bool isFirst;
  final bool isLast;
  final VoidCallback? onToggle;
  final VoidCallback? onTap;

  const TimelineCard({
    super.key,
    required this.title,
    required this.category,
    this.dosage = '',
    required this.status,
    required this.time,
    this.isNext = false,
    this.isFirst = false,
    this.isLast = false,
    required this.onToggle,
    this.onTap,
  });

  bool get _isCompleted => status == 'completed';
  bool get _isMissed => status == 'missed';
  bool get _isMedication => category.toLowerCase() == 'medication';

  Color get _dotColor {
    if (_isCompleted) return AppColors.greenCheck;
    if (_isMissed) return AppColors.orangeEnd;
    if (isNext) return AppColors.orangeStart;
    return AppColors.cardPurpleLight;
  }

  double get _dotSize => isNext ? 14 : 10;

  TextStyle get _titleStyle => TextStyle(
        color: _isMissed ? AppColors.orangeEnd : (_isCompleted ? Colors.white54 : Colors.white),
        fontSize: 15,
        fontWeight: FontWeight.w600,
        decoration: (_isCompleted || _isMissed) ? TextDecoration.lineThrough : TextDecoration.none,
        decorationColor: _isMissed ? AppColors.orangeEnd : Colors.white54,
      );

  @override
  Widget build(BuildContext context) {
    final String categoryLabel = category.toUpperCase() +
        (_isMedication && dosage.isNotEmpty ? ' · Dosage $dosage' : '');

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Time column.
          SizedBox(
            width: 48,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: time != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          DateFormat('h:mm').format(time!),
                          style: TextStyle(
                            color: isNext ? AppColors.orangeStart : Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          DateFormat('a').format(time!).toUpperCase(),
                          style: TextStyle(
                            color: isNext ? AppColors.orangeStart : AppColors.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    )
                  : const Text(
                      'Anytime',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),

          // Connector: line above + dot + line below.
          SizedBox(
            width: 24,
            child: Column(
              children: [
                Expanded(
                  child: isFirst
                      ? const SizedBox()
                      : Container(width: 2, color: AppColors.cardPurpleLight),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Container(
                    width: _dotSize,
                    height: _dotSize,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _dotColor),
                  ),
                ),
                Expanded(
                  child: isLast
                      ? const SizedBox()
                      : Container(width: 2, color: AppColors.cardPurpleLight),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Card + "Up Next" caption — bottom margin here is what the
          // connector column's IntrinsicHeight stretch also covers, so the
          // line runs through the gap to the next row too.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: onTap,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.cardPurple,
                        borderRadius: BorderRadius.circular(14),
                        border: isNext
                            ? Border.all(color: AppColors.orangeStart, width: 1.5)
                            : null,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: _titleStyle),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: categoryDotColor(category),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        categoryLabel,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: 0.3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          _ToggleCircle(status: status, onTap: onToggle),
                        ],
                      ),
                    ),
                  ),
                  if (isNext && time != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 2),
                      child: Text(
                        'UP NEXT ${formatCountdown(time!.difference(DateTime.now()))}',
                        style: const TextStyle(
                          color: AppColors.orangeStart,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleCircle extends StatelessWidget {
  final String status;
  final VoidCallback? onTap;
  const _ToggleCircle({required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final bool isCompleted = status == 'completed';
    final bool isMissed = status == 'missed';

    if (isCompleted) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 32,
          height: 32,
          decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.greenCheck),
          child: const Icon(Icons.check, color: Colors.white, size: 18),
        ),
      );
    }
    if (isMissed) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 32,
          height: 32,
          decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.orangeEnd),
          child: const Icon(Icons.close, color: Colors.white, size: 18),
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.cardPurpleLight, width: 2),
        ),
      ),
    );
  }
}
