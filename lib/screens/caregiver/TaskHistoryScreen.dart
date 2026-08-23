import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_decorations.dart';
import 'package:testproject/theme/app_text_styles.dart';
import '../../widgets/SideDrawer.dart';
import '../task_detail_screen.dart';

enum _StatusFilter { all, pending, completed, missed }

/// Caregiver-facing history of one patient's tasks — every task ever
/// assigned to them, not just today's (compare HomeScreen, which is
/// today-only). Reuses the same patient-fetch pattern as
/// createTaskScreen.dart's "Assign to Patient" dropdown.
///
/// Tapping a card opens the read-only detail view (UC-05 8a/8b), which
/// itself offers an Edit button — this is the only way to fix a task
/// that's missing a due date, since such a task can never appear on
/// HomeScreen (its date-range query excludes tasks with no dueDate) and
/// so is otherwise unreachable for editing.
class TaskHistoryScreen extends StatefulWidget {
  const TaskHistoryScreen({super.key});

  @override
  State<TaskHistoryScreen> createState() => _TaskHistoryScreenState();
}

class _TaskHistoryScreenState extends State<TaskHistoryScreen> {
  final FirestoreService _firestore = FirestoreService();
  final String caregiverId = FirebaseAuth.instance.currentUser!.uid;

  List<Map<String, dynamic>> _patients = [];
  bool _loadingPatients = true;
  String? _selectedPatientId;

  _StatusFilter _statusFilter = _StatusFilter.all;

  @override
  void initState() {
    super.initState();
    _loadPatients();
  }

  Future<void> _loadPatients() async {
    setState(() => _loadingPatients = true);
    try {
      final patients = await _firestore.getPatientsForCaregiver(caregiverId);
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

  bool _matchesFilter(String status) {
    switch (_statusFilter) {
      case _StatusFilter.all:
        return true;
      case _StatusFilter.pending:
        return status == 'pending';
      case _StatusFilter.completed:
        return status == 'completed';
      case _StatusFilter.missed:
        return status == 'missed';
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
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Task History', style: AppTextStyles.heading),
            const SizedBox(height: 4),
            const Text(
              "Browse a patient's full task history. Tap a task to edit it.",
              style: AppTextStyles.muted,
            ),
            const SizedBox(height: 20),

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
                        onChanged: (value) =>
                            setState(() => _selectedPatientId = value),
                      ),
            const SizedBox(height: 16),

            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _statusChip('All', _StatusFilter.all),
                  const SizedBox(width: 8),
                  _statusChip('Pending', _StatusFilter.pending),
                  const SizedBox(width: 8),
                  _statusChip('Completed', _StatusFilter.completed),
                  const SizedBox(width: 8),
                  _statusChip('Missed', _StatusFilter.missed),
                ],
              ),
            ),
            const SizedBox(height: 16),

            Expanded(
              child: _selectedPatientId == null
                  ? const SizedBox.shrink()
                  : StreamBuilder<QuerySnapshot>(
                      stream: _firestore.getTaskHistory(_selectedPatientId!),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Center(
                            child: Text(
                              'Something went wrong: ${snapshot.error}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          );
                        }
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(
                              color: AppColors.orangeStart,
                            ),
                          );
                        }

                        final docs = (snapshot.data?.docs ?? []).where((d) {
                          final data = d.data() as Map<String, dynamic>;
                          final status =
                              (data['status'] ?? 'pending').toString();
                          return _matchesFilter(status);
                        }).toList();

                        if (docs.isEmpty) {
                          return const Center(
                            child: Text(
                              'No tasks match this filter.',
                              style: AppTextStyles.muted,
                            ),
                          );
                        }

                        return ListView.separated(
                          itemCount: docs.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final doc = docs[index];
                            final data = doc.data() as Map<String, dynamic>;
                            return _TaskHistoryCard(
                              data: data,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TaskDetailScreen(taskId: doc.id),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String label, _StatusFilter filter) {
    final bool selected = _statusFilter == filter;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _statusFilter = filter),
      labelStyle: TextStyle(
        color: selected ? Colors.white : AppColors.textMuted,
        fontWeight: FontWeight.w600,
      ),
      backgroundColor: AppColors.cardPurple,
      selectedColor: AppColors.orangeStart,
      side: BorderSide.none,
    );
  }
}

class _TaskHistoryCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  const _TaskHistoryCard({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final String title = (data['title'] ?? '') as String;
    final String category = (data['category'] ?? '') as String;
    final String status = (data['status'] ?? 'pending') as String;
    final dueTs = data['dueDate'];
    final String dateLabel = dueTs is Timestamp
        ? DateFormat('MMM d, y • h:mm a').format(dueTs.toDate())
        : 'No due date';

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: AppDecorations.card,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.cardTitle),
                  const SizedBox(height: 4),
                  Text(
                    dateLabel,
                    style: dueTs is Timestamp
                        ? AppTextStyles.muted
                        : const TextStyle(
                            color: AppColors.orangeEnd,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                  ),
                  if (category.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
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
                ],
              ),
            ),
            _StatusBadge(status: status),
          ],
        ),
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
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
