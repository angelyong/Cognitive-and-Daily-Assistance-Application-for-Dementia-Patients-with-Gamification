import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:testproject/models/task_recurrence.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/services/notification_service.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_text_styles.dart';
import 'caregiver/createTaskScreen.dart';

/// UC-05 sub-flow 8a/8b (tapping a task to view its full details) and
/// 8c/8d (tapping a delivered notification does the same). Shared by both
/// roles: read-only for everyone, with an "Edit" action shown only to
/// caregivers (a patient has no use for reassigning/deleting a task).
///
/// PHASE 3 (see phase3_reminder_notifications_prompt.md, Step 8): this is
/// "the existing patient task screen" the fallback flow refers to — a
/// notification tap already opened this screen pre-Phase-3, so rather than
/// building a second response UI, patients get Complete/Missed buttons
/// here. The relevant occurrence isn't passed in explicitly (the payload
/// stays a bare taskId, unchanged from before this phase) — instead this
/// screen computes it itself: for a single task, that's just the task's
/// own dueDate/status as always; for a recurring one, it's whichever
/// occurrence within +/-2 days of now is closest to now (covers "just
/// became due", "still overdue-but-pending from earlier today", and
/// "opened right after completing it"), reading/writing that occurrence's
/// status via the Phase 2/3 per-occurrence model instead of the series
/// doc's own (otherwise meaningless, for a recurring task) status field.
class TaskDetailScreen extends StatefulWidget {
  final String taskId;
  const TaskDetailScreen({super.key, required this.taskId});

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  final FirestoreService _firestoreService = FirestoreService();

  bool _loading = true;
  bool _isCaregiver = false;
  bool _isPatient = false;
  Map<String, dynamic>? _data;

  // PHASE 3: the occurrence this screen is showing Complete/Missed for —
  // null if there's no relevant occurrence right now (e.g. a monthly task
  // not due today, or the task couldn't be loaded).
  DateTime? _relevantOccurrenceDate;
  String _occurrenceStatus = 'pending';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _firestoreService.getTask(widget.taskId),
      _loadRole(),
    ]);
    final data = results[0] as Map<String, dynamic>?;
    final String role = results[1] as String;

    DateTime? occurrenceDate;
    String occurrenceStatus = 'pending';
    final dueTs = data?['dueDate'];
    if (data != null && dueTs is Timestamp) {
      final endTs = data['endDate'];
      final series = TaskSeries(
        taskId: widget.taskId,
        startDate: dueTs.toDate(),
        recurrenceType: RecurrenceTypeX.fromFirestore(
          data[RecurrenceTypeX.firestoreField] as String?,
        ),
        rule: RecurrenceRule.fromMap(data['recurrenceRule'] as Map<String, dynamic>?),
        endDate: endTs is Timestamp ? endTs.toDate() : null,
      );

      if (series.recurrenceType == RecurrenceType.none) {
        occurrenceDate = series.startDate;
        occurrenceStatus = (data['status'] ?? 'pending') as String;
      } else {
        final DateTime now = DateTime.now();
        final occurrences = getOccurrencesForDateRange(
          series,
          now.subtract(const Duration(days: 2)),
          now.add(const Duration(days: 2)),
        );
        if (occurrences.isNotEmpty) {
          occurrences.sort(
            (a, b) => a.difference(now).abs().compareTo(b.difference(now).abs()),
          );
          occurrenceDate = occurrences.first;
          occurrenceStatus =
              await _firestoreService.getOccurrenceStatus(widget.taskId, occurrenceDate);
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _data = data;
      _isCaregiver = role == 'caregiver';
      _isPatient = role == 'patient';
      _relevantOccurrenceDate = occurrenceDate;
      _occurrenceStatus = occurrenceStatus;
      _loading = false;
    });
  }

  Future<String> _loadRole() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return '';
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (!doc.exists) return '';
    final data = doc.data() as Map<String, dynamic>;
    return (data['role'] ?? '') as String;
  }

  /// PHASE 3 (Steps 4-6): records the patient's response for
  /// [_relevantOccurrenceDate] and cancels the rest of that occurrence's
  /// reminder chain. Idempotent — re-tapping Complete on an already-
  /// completed occurrence just re-writes the same status and re-cancels
  /// (a no-op either way), so a double-tap can't cause harm.
  Future<void> _respond(String status) async {
    final DateTime? occurrenceDate = _relevantOccurrenceDate;
    final Map<String, dynamic>? data = _data;
    if (occurrenceDate == null || data == null) return;

    final RecurrenceType type = RecurrenceTypeX.fromFirestore(
      data[RecurrenceTypeX.firestoreField] as String?,
    );
    if (type == RecurrenceType.none) {
      await _firestoreService.updateTaskStatus(widget.taskId, status);
    } else {
      await _firestoreService.setOccurrenceStatus(widget.taskId, occurrenceDate, status);
    }
    await NotificationService().cancelOccurrenceReminders(widget.taskId, occurrenceDate);

    if (!mounted) return;
    setState(() => _occurrenceStatus = status);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(status == 'completed' ? 'Marked complete!' : 'Marked as missed.'),
        backgroundColor: status == 'completed' ? Colors.green : AppColors.orangeEnd,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDark,
      appBar: AppBar(
        title: const Text('Task Details', style: TextStyle(color: Colors.white)),
        backgroundColor: AppColors.bgDark,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.orangeStart),
            )
          : _data == null
              ? _buildNotFound()
              : _buildDetails(_data!),
    );
  }

  Widget _buildNotFound() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, color: AppColors.textMuted, size: 48),
            const SizedBox(height: 16),
            const Text(
              'This task no longer exists',
              style: TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.orangeStart,
                foregroundColor: Colors.white,
              ),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetails(Map<String, dynamic> data) {
    final String title = (data['title'] ?? '') as String;
    final String category = (data['category'] ?? '') as String;
    final String description = (data['description'] ?? '') as String;
    final String dosage = (data['dosage'] ?? '') as String;
    // PHASE 3: the relevant OCCURRENCE's status (see class doc comment) —
    // for a single task this is exactly data['status'], unchanged.
    final String status = _occurrenceStatus;
    final dueTs = data['dueDate'];
    final String dateLabel = dueTs is Timestamp
        ? DateFormat('EEEE, MMM d, y • h:mm a').format(dueTs.toDate())
        : 'No due date set';

    // Phase 2: missing/unrecognized recurrenceType -> none, so an old
    // single-shot task (or any task without the field) is unaffected.
    final RecurrenceType recurrenceType =
        RecurrenceTypeX.fromFirestore(data['recurrenceType'] as String?);
    final bool isRecurring = recurrenceType != RecurrenceType.none;
    final RecurrenceRule recurrenceRule =
        RecurrenceRule.fromMap(data['recurrenceRule'] as Map<String, dynamic>?);
    final endTs = data['endDate'];
    final String endLabel = endTs is Timestamp
        ? 'until ${DateFormat('MMM d, y').format(endTs.toDate())}'
        : 'no end date';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: AppTextStyles.heading),
              ),
              _StatusBadge(status: status),
            ],
          ),
          if (category.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
          const SizedBox(height: 20),

          _detailRow(Icons.event, isRecurring ? 'Starts' : 'Due', dateLabel),
          if (isRecurring) ...[
            const SizedBox(height: 14),
            _detailRow(
              Icons.repeat,
              'Repeats',
              '${recurrenceSummary(recurrenceType, recurrenceRule)} ($endLabel)',
            ),
          ],
          if (category == 'Medication' && dosage.isNotEmpty) ...[
            const SizedBox(height: 14),
            _detailRow(Icons.medication_outlined, 'Dosage', dosage),
          ],
          const SizedBox(height: 14),
          _detailRow(
            Icons.notes,
            'Description',
            description.isEmpty ? 'No description provided.' : description,
          ),

          // PHASE 3 (Step 8): the patient's Complete/Missed response —
          // only shown when there's a relevant occurrence and it isn't
          // already completed (nothing left to respond to otherwise).
          if (_isPatient &&
              _relevantOccurrenceDate != null &&
              _occurrenceStatus != 'completed') ...[
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _respond('completed'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.greenCheck,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Complete'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _respond('missed'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.orangeEnd,
                      side: const BorderSide(color: AppColors.orangeEnd),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Missed'),
                  ),
                ),
              ],
            ),
          ],

          if (_isCaregiver) ...[
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CreateTaskScreen(
                      taskId: widget.taskId,
                      existingData: data,
                    ),
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.orangeStart,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.edit),
                label: const Text('Edit Task'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardPurple,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.orangeStart, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTextStyles.muted),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    switch (status) {
      case 'completed':
        color = AppColors.greenCheck;
        label = 'Completed';
        break;
      case 'missed':
        color = AppColors.orangeEnd;
        label = 'Missed';
        break;
      default:
        color = AppColors.textMuted;
        label = 'Pending';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}
