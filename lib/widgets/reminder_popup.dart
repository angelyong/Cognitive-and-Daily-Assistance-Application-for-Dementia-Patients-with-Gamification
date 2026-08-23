import 'package:flutter/material.dart';

import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/services/notification_service.dart';
import 'package:testproject/theme/app_colors.dart';
import 'timeline_card.dart' show categoryDotColor, formatCardTime;

/// Three icons shown side by side in the popup's header — one small
/// illustrative set per category (matching the reference design's 3-icon
/// "Meal" row), paired with [categoryDotColor] so the icons and their
/// shared accent color always agree.
List<IconData> categoryIcons(String category) {
  switch (category.toLowerCase()) {
    case 'medication':
      return const [Icons.medication, Icons.local_drink, Icons.medical_services];
    case 'exercise':
      return const [Icons.directions_run, Icons.fitness_center, Icons.favorite];
    case 'meal':
      return const [Icons.rice_bowl, Icons.eco, Icons.grass];
    case 'hygiene':
      return const [Icons.clean_hands, Icons.shower, Icons.bathtub];
    case 'social':
      return const [Icons.people_alt, Icons.chat_bubble_outline, Icons.favorite_border];
    case 'appointment':
      return const [Icons.event, Icons.access_time, Icons.location_on];
    default:
      return const [Icons.notifications_active, Icons.task_alt, Icons.star];
  }
}

/// "TIME TO {verb}" header text per category — matches the earlier
/// reference mockups' own per-category phrasing ("TIME FOR MEDICINE",
/// "TIME TO EAT", "TIME TO MOVE") rather than literally inserting the raw
/// category string, which reads awkwardly for some categories
/// ("TIME TO MEDICATION").
String categoryReminderHeading(String category) {
  switch (category.toLowerCase()) {
    case 'medication':
      return 'TIME FOR MEDICINE';
    case 'exercise':
      return 'TIME TO MOVE';
    case 'meal':
      return 'TIME TO EAT';
    case 'hygiene':
      return 'TIME TO FRESHEN UP';
    case 'social':
      return 'TIME TO CONNECT';
    case 'appointment':
      return 'TIME FOR YOUR APPOINTMENT';
    default:
      return 'TIME FOR YOUR TASK';
  }
}

/// A floating, on-brand reminder popup — shown two ways (both wired, per
/// explicit choice): (1) automatically, the moment a task becomes due
/// while the patient already has the app open (see PatientDashboard), and
/// (2) in place of the old full-screen TaskDetailScreen navigation when a
/// delivered notification's body is tapped (see NotificationService).
///
/// Deliberately minimal — icon, title, time, Complete/Missed — rather than
/// TaskDetailScreen's full detail view (description, dosage, repeat rule,
/// Edit for caregivers): this is a glanceable response prompt for a
/// patient reacting to a reminder, not a browsing screen. The task is
/// still reachable in full via its timeline card if more detail is ever
/// needed.
///
/// Sized ~90% of screen width / ~40% of screen height (design spec),
/// centered like a normal dialog. Dismissing without responding (tapping
/// the barrier) just leaves the occurrence pending — same as ignoring the
/// OS notification entirely; there's no snooze/re-show, and PatientDashboard
/// only auto-shows a given occurrence once per session (see its own
/// `_shownReminderKeys`).
class ReminderPopup extends StatefulWidget {
  final String taskId;
  final DateTime occurrenceDate;
  final bool isRecurring;
  final String title;
  final String category;

  const ReminderPopup({
    super.key,
    required this.taskId,
    required this.occurrenceDate,
    required this.isRecurring,
    required this.title,
    required this.category,
  });

  static Future<void> show(
    BuildContext context, {
    required String taskId,
    required DateTime occurrenceDate,
    required bool isRecurring,
    required String title,
    required String category,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => ReminderPopup(
        taskId: taskId,
        occurrenceDate: occurrenceDate,
        isRecurring: isRecurring,
        title: title,
        category: category,
      ),
    );
  }

  @override
  State<ReminderPopup> createState() => _ReminderPopupState();
}

class _ReminderPopupState extends State<ReminderPopup> {
  final FirestoreService _firestoreService = FirestoreService();
  bool _submitting = false;

  // BUGFIX (NOTIFICATION_BUGS.md #3): this widget used to always render
  // live Complete/Missed buttons with no idea whether the occurrence had
  // already been resolved through another channel (timeline card, a
  // native notification action button, or a stale re-opened notification)
  // — harmless to write (idempotent), but confusing: no acknowledgment
  // the occurrence was already handled. Null = still loading.
  String? _currentStatus;

  @override
  void initState() {
    super.initState();
    _loadCurrentStatus();
  }

  Future<void> _loadCurrentStatus() async {
    final String status;
    if (widget.isRecurring) {
      status = await _firestoreService.getOccurrenceStatus(widget.taskId, widget.occurrenceDate);
    } else {
      final data = await _firestoreService.getTask(widget.taskId);
      status = (data?['status'] ?? 'pending') as String;
    }
    if (!mounted) return;
    setState(() => _currentStatus = status);
  }

  Future<void> _respond(String status) async {
    if (_submitting) return;
    setState(() => _submitting = true);

    if (widget.isRecurring) {
      await _firestoreService.setOccurrenceStatus(widget.taskId, widget.occurrenceDate, status);
    } else {
      await _firestoreService.updateTaskStatus(widget.taskId, status);
    }
    await NotificationService().cancelOccurrenceReminders(widget.taskId, widget.occurrenceDate);

    if (!mounted) return;
    // maybePop instead of pop: defensive against the dialog having already
    // been dismissed some other way (e.g. a barrier tap) during the awaits
    // above — pop() would assert if there's nothing left to pop.
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final Size screenSize = MediaQuery.of(context).size;
    final double width = screenSize.width * 0.75;
    final double height = screenSize.height * 0.4;
    final Color accent = categoryDotColor(widget.category);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.zero,
      child: Container(
        width: width,
        height: height,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.cardPurple,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.cardPurpleLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(Icons.notifications, color: accent, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    categoryReminderHeading(widget.category),
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const Text(
                  'now',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final icon in categoryIcons(widget.category))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Container(
                      width: 64,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: accent.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Icon(icon, color: accent, size: 28),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.access_time, color: AppColors.textMuted, size: 16),
                const SizedBox(width: 6),
                Text(
                  formatCardTime(widget.occurrenceDate),
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const Spacer(),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  /// Branches on [_currentStatus] (BUGFIX, NOTIFICATION_BUGS.md #3): a
  /// brief loading spinner while it's still being fetched, an
  /// already-resolved acknowledgment (no live buttons — nothing left to
  /// respond to) if the occurrence was already handled through another
  /// channel, or the normal Complete/Missed row otherwise.
  Widget _buildFooter() {
    if (_currentStatus == null) {
      return const SizedBox(
        height: 48,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.orangeStart),
          ),
        ),
      );
    }

    if (_currentStatus == 'completed' || _currentStatus == 'missed') {
      final bool isCompleted = _currentStatus == 'completed';
      return Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isCompleted ? Icons.check_circle : Icons.watch_later_outlined,
                color: isCompleted ? AppColors.greenCheck : AppColors.orangeEnd,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                isCompleted ? 'Already marked complete' : 'Already marked missed',
                style: TextStyle(
                  color: isCompleted ? AppColors.greenCheck : AppColors.orangeEnd,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).maybePop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textMuted,
                side: const BorderSide(color: AppColors.cardPurpleLight),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Close'),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _submitting ? null : () => _respond('completed'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.greenCheck,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.check_circle),
            label: const Text('Complete'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _submitting ? null : () => _respond('missed'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.orangeEnd,
              side: const BorderSide(color: AppColors.orangeEnd),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.watch_later_outlined),
            label: const Text('Missed'),
          ),
        ),
      ],
    );
  }
}
