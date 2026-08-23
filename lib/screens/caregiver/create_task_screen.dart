import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:testproject/models/occurrence_status.dart';
import 'package:testproject/models/task_recurrence.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/services/notification_service.dart';
import '../../widgets/side_drawer.dart';

import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_decorations.dart';

class CreateTaskScreen extends StatefulWidget {
  /// When set, the screen opens in "update" mode for this existing task.
  final String? taskId;
  /// The existing task's Firestore fields, used to pre-fill the form.
  final Map<String, dynamic>? existingData;
  /// When creating a new task (not editing), pre-selects this category —
  /// e.g. HomeScreen's "Add Med" button opens straight to 'Medication'.
  final String? initialCategory;

  const CreateTaskScreen({
    super.key,
    this.taskId,
    this.existingData,
    this.initialCategory,
  });

  @override
  State<CreateTaskScreen> createState() => _CreateTaskScreenState();
}

class _CreateTaskScreenState extends State<CreateTaskScreen> {
  final FirestoreService _firestoreService = FirestoreService();

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _dosageController = TextEditingController();
  final String caregiverId = FirebaseAuth.instance.currentUser!.uid;

  bool get _isEditing => widget.taskId != null;

  String? _selectedPatientId;
  String? _selectedCategory;

  // Due deadline
  DateTime? _dueDate;
  TimeOfDay? _dueTime;

  // Reminder (notification)
  DateTime? _reminderDate;
  TimeOfDay? _reminderTime;

  // Recurrence (Phase 2 — see phase2_recurring_tasks_prompt.md). _dueDate/
  // _dueTime above double as the series' start date/time when recurrence
  // is enabled — same fields, no separate start-date state needed.
  RecurrenceType _recurrenceType = RecurrenceType.none;
  List<int> _selectedWeekdays = []; // weekly, and custom when unit=weeks
  final TextEditingController _customIntervalController =
      TextEditingController(text: '1');
  RecurrenceUnit _customUnit = RecurrenceUnit.days;
  bool _endsNever = true;
  DateTime? _endDate;

  // PHASE 3 (see phase3_reminder_notifications_prompt.md): how often the
  // patient's own device re-reminds them after the due-time notification,
  // until they respond Complete/Missed.
  int _reminderIntervalMinutes = defaultReminderIntervalMinutes;

  List<Map<String, dynamic>> _patients = [];
  bool _loadingPatients = true;

  /// [_patients] plus a placeholder for the currently-selected patient if
  /// they're no longer in that list (e.g. unlinked since this task was
  /// created) — without this, DropdownButtonFormField crashes because its
  /// `value` wouldn't match any item.
  List<Map<String, dynamic>> get _dropdownPatients {
    if (_selectedPatientId == null ||
        _patients.any((p) => p['uid'] == _selectedPatientId)) {
      return _patients;
    }
    return [
      ..._patients,
      {'uid': _selectedPatientId, 'name': 'Unknown patient (no longer linked)'},
    ];
  }

  final List<String> _categories = [
    'Medication',
    'Exercise',
    'Meal',
    'Hygiene',
    'Social',
    'Appointment',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    _prefillFromExistingData();
    _loadPatients();
  }

  void _prefillFromExistingData() {
    final data = widget.existingData;
    if (data == null) {
      _selectedCategory = widget.initialCategory;
      return;
    }

    _titleController.text = (data['title'] ?? '') as String;
    _descriptionController.text = (data['description'] ?? '') as String;
    _dosageController.text = (data['dosage'] ?? '') as String;
    _selectedCategory = data['category'] as String?;
    _selectedPatientId = data['patientId'] as String?;

    final dueTs = data['dueDate'];
    if (dueTs is Timestamp) {
      final due = dueTs.toDate();
      _dueDate = due;
      _dueTime = TimeOfDay(hour: due.hour, minute: due.minute);
    }

    final reminderTs = data['reminderAt'];
    if (reminderTs is Timestamp) {
      final reminder = reminderTs.toDate();
      _reminderDate = reminder;
      _reminderTime = TimeOfDay(hour: reminder.hour, minute: reminder.minute);
    }

    // Missing/unrecognized recurrenceType -> RecurrenceType.none, so an
    // old single-shot task simply opens with "Does not repeat" selected.
    _recurrenceType =
        RecurrenceTypeX.fromFirestore(data['recurrenceType'] as String?);
    final rule =
        RecurrenceRule.fromMap(data['recurrenceRule'] as Map<String, dynamic>?);
    _selectedWeekdays = List<int>.from(rule.weekdays);
    _customIntervalController.text = rule.interval.toString();
    _customUnit = rule.unit;

    final endTs = data['endDate'];
    if (endTs is Timestamp) {
      _endsNever = false;
      _endDate = endTs.toDate();
    }

    // Missing on an old task doc -> defaultReminderIntervalMinutes.
    _reminderIntervalMinutes =
        (data['reminderIntervalMinutes'] as int?) ?? defaultReminderIntervalMinutes;
  }

  Future<void> _loadPatients() async {
    setState(() => _loadingPatients = true);
    try {
      final patients = await _firestoreService.getPatientsForCaregiver(caregiverId);
      setState(() {
        _patients = patients;
        _loadingPatients = false;
        if (_selectedPatientId == null && patients.isNotEmpty) {
          _selectedPatientId = patients.first['uid'];
        }
      });
    } catch (e) {
      setState(() => _loadingPatients = false);
      _showSnackBar('Failed to load patients: $e');
    }
  }

  Future<void> _selectDueDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _dueDate = picked);
    }
  }

  Future<void> _selectDueTime(BuildContext context) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: _dueTime ?? TimeOfDay.now(),
    );
    if (picked != null) {
      setState(() => _dueTime = picked);
    }
  }

  Future<void> _selectEndDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? _dueDate ?? DateTime.now(),
      firstDate: _dueDate ?? DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _endDate = picked);
    }
  }

  Widget _weekdaySelector() {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(7, (i) {
        final int weekday = i + 1; // DateTime.weekday: 1=Mon .. 7=Sun
        final bool selected = _selectedWeekdays.contains(weekday);
        return FilterChip(
          label: Text(names[i]),
          selected: selected,
          onSelected: (sel) => setState(() {
            if (sel) {
              _selectedWeekdays.add(weekday);
            } else {
              _selectedWeekdays.remove(weekday);
            }
          }),
          labelStyle: TextStyle(
            color: selected ? Colors.white : AppColors.textMuted,
            fontWeight: FontWeight.w600,
          ),
          backgroundColor: AppColors.cardPurple,
          selectedColor: AppColors.orangeStart,
          side: BorderSide.none,
        );
      }),
    );
  }

  Widget _endsChoice(String label, bool isNeverOption) {
    final bool selected = _endsNever == isNeverOption;
    return OutlinedButton(
      onPressed: () => setState(() => _endsNever = isNeverOption),
      style: OutlinedButton.styleFrom(
        backgroundColor: selected ? AppColors.orangeStart : AppColors.cardPurple,
        foregroundColor: Colors.white,
        side: BorderSide(
          color: selected ? AppColors.orangeStart : AppColors.cardPurpleLight,
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(label),
    );
  }

  Future<void> _openReminderPopup() async {
    // Local temp copies so Cancel discards changes.
    DateTime? tempDate = _reminderDate;
    TimeOfDay? tempTime = _reminderTime;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.cardPurple,
              title: const Text(
                'Set Reminder',
                style: TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.event, color: AppColors.orangeStart),
                    title: Text(
                      tempDate == null
                          ? 'Pick a date'
                          : '${tempDate!.month}/${tempDate!.day}/${tempDate!.year}',
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: tempDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) {
                        setDialogState(() => tempDate = picked);
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.access_time, color: AppColors.orangeStart),
                    title: Text(
                      tempTime == null
                          ? 'Pick a time'
                          : tempTime!.format(context),
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: tempTime ?? TimeOfDay.now(),
                      );
                      if (picked != null) {
                        setDialogState(() => tempTime = picked);
                      }
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    // Clear the reminder
                    setState(() {
                      _reminderDate = null;
                      _reminderTime = null;
                    });
                    Navigator.pop(context);
                  },
                  style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
                  child: const Text('Clear'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _reminderDate = tempDate;
                      _reminderTime = tempTime;
                    });
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.orangeStart,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _saveTask() async {
    if (_titleController.text.trim().isEmpty) {
      _showSnackBar('Please enter a task title');
      return;
    }
    if (_selectedCategory == null) {
      _showSnackBar('Please select a category');
      return;
    }
    if (_selectedPatientId == null) {
      _showSnackBar('Please assign a patient');
      return;
    }
    if (_selectedCategory == 'Medication' && _dosageController.text.trim().isEmpty) {
      _showSnackBar('Please enter the dosage');
      return;
    }

    RecurrenceRule? recurrenceRuleToSave;
    if (_recurrenceType != RecurrenceType.none) {
      if (_dueDate == null || _dueTime == null) {
        _showSnackBar('Please set a start date and time for the repeating task');
        return;
      }
      if (_recurrenceType == RecurrenceType.weekly && _selectedWeekdays.isEmpty) {
        _showSnackBar('Please select at least one day of the week');
        return;
      }

      int customInterval = 1;
      if (_recurrenceType == RecurrenceType.custom) {
        customInterval = int.tryParse(_customIntervalController.text.trim()) ?? 0;
        if (customInterval <= 0) {
          _showSnackBar('Please enter a valid repeat interval');
          return;
        }
        if (_customUnit == RecurrenceUnit.weeks && _selectedWeekdays.isEmpty) {
          _showSnackBar('Please select at least one day of the week');
          return;
        }
      }

      if (!_endsNever) {
        if (_endDate == null) {
          _showSnackBar('Please pick an end date, or choose Never');
          return;
        }
        final startDateOnly =
            DateTime(_dueDate!.year, _dueDate!.month, _dueDate!.day);
        final endDateOnly =
            DateTime(_endDate!.year, _endDate!.month, _endDate!.day);
        if (endDateOnly.isBefore(startDateOnly)) {
          _showSnackBar('End date cannot be before the start date');
          return;
        }
      }

      recurrenceRuleToSave = _recurrenceType == RecurrenceType.weekly
          ? RecurrenceRule(weekdays: _selectedWeekdays)
          : _recurrenceType == RecurrenceType.custom
              ? RecurrenceRule(
                  interval: customInterval,
                  unit: _customUnit,
                  weekdays: _customUnit == RecurrenceUnit.weeks
                      ? _selectedWeekdays
                      : const [],
                )
              : null;
    }

    try {
      DateTime? dueDate;
      final DateTime? dd = _dueDate;
      final TimeOfDay? dt = _dueTime;
      if (dd != null && dt != null) {
        dueDate = DateTime(dd.year, dd.month, dd.day, dt.hour, dt.minute);
      }

      DateTime? reminderAt;
      final DateTime? rd = _reminderDate;
      final TimeOfDay? rt = _reminderTime;
      if (rd != null && rt != null) {
        reminderAt = DateTime(rd.year, rd.month, rd.day, rt.hour, rt.minute);
      }

      final String? dosage = _selectedCategory == 'Medication'
          ? _dosageController.text.trim()
          : null;

      final String taskId;
      if (_isEditing) {
        taskId = widget.taskId!;
        await _firestoreService.updateTask(
          taskId: taskId,
          patientId: _selectedPatientId!,
          title: _titleController.text.trim(),
          category: _selectedCategory!,
          dueDate: dueDate,
          reminderAt: reminderAt,
          description: _descriptionController.text.trim(),
          dosage: dosage,
          recurrenceType: _recurrenceType,
          recurrenceRule: recurrenceRuleToSave,
          endDate: _endsNever ? null : _endDate,
          reminderIntervalMinutes: _reminderIntervalMinutes,
        );
      } else {
        taskId = await _firestoreService.addTask(
          caregiverId: caregiverId,
          patientId: _selectedPatientId!,
          title: _titleController.text.trim(),
          category: _selectedCategory!,
          dueDate: dueDate,
          reminderAt: reminderAt,
          description: _descriptionController.text.trim(),
          dosage: dosage,
          recurrenceType: _recurrenceType,
          recurrenceRule: recurrenceRuleToSave,
          endDate: _endsNever ? null : _endDate,
          reminderIntervalMinutes: _reminderIntervalMinutes,
        );
      }

      if (reminderAt != null) {
        await NotificationService().scheduleReminder(
          id: NotificationService.idFor(taskId),
          category: _selectedCategory!,
          taskTitle: _titleController.text.trim(),
          scheduledTime: reminderAt,
          taskId: taskId,
        );
      } else if (_isEditing) {
        await NotificationService().cancelReminder(
          NotificationService.idFor(taskId),
        );
      }

      if (!mounted) return;
      _showSnackBar(
        _isEditing ? 'Task updated successfully!' : 'Task created successfully!',
        isSuccess: true,
      );
      if (_isEditing) {
        Navigator.pop(context);
      } else {
        Navigator.pushReplacementNamed(context, '/homescreen');
      }
    } catch (e) {
      _showSnackBar('Error saving task: $e');
    }
  }

  Future<void> _deleteTask() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardPurple,
        title: const Text('Delete Task', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to delete this task? This cannot be undone.',
          style: TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final String taskId = widget.taskId!;
      await _firestoreService.deleteTask(taskId);
      await NotificationService().cancelReminder(
        NotificationService.idFor(taskId),
      );
      if (!mounted) return;
      _showSnackBar('Task deleted', isSuccess: true);
      Navigator.pop(context);
    } catch (e) {
      _showSnackBar('Error deleting task: $e');
    }
  }

  void _showSnackBar(String message, {bool isSuccess = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? Colors.green : Colors.red,
      ),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _dosageController.dispose();
    _customIntervalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reminderSet = _reminderDate != null && _reminderTime != null;

    return Scaffold(
      backgroundColor: AppColors.bgDark,
      drawer: const SideDrawer(),
      appBar: AppBar(
        title: const Text("MindCare", style: TextStyle(color: Colors.white)),
        backgroundColor: AppColors.bgDark,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: Builder(
          builder: (context) {
            return IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () {
                Scaffold.of(context).openDrawer();
              },
            );
          },
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row with reminder bell (and delete, when editing)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _isEditing ? 'Update Daily Task' : 'Create Daily Task',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _openReminderPopup,
                  tooltip: 'Set reminder',
                  icon: Icon(
                    reminderSet
                        ? Icons.notifications_active
                        : Icons.notifications_none,
                    color: reminderSet ? AppColors.orangeStart : AppColors.textMuted,
                    size: 28,
                  ),
                ),
                if (_isEditing)
                  IconButton(
                    onPressed: _deleteTask,
                    tooltip: 'Delete task',
                    icon: const Icon(Icons.delete, color: Colors.red, size: 28),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _isEditing
                  ? 'Update the task details below'
                  : 'Add a new task to the schedule',
              style: const TextStyle(fontSize: 14, color: AppColors.textMuted),
            ),
            if (reminderSet)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Reminder: ${_reminderDate!.month}/${_reminderDate!.day}/${_reminderDate!.year} at ${_reminderTime!.format(context)}',
                  style: const TextStyle(fontSize: 12, color: AppColors.orangeStart),
                ),
              ),
            const SizedBox(height: 24),

            // Task Title
            TextField(
              controller: _titleController,
              style: const TextStyle(color: Colors.white),
              decoration: AppDecorations.darkInput(
                'Task Title',
                hint: 'e.g., Morning Walk',
              ),
            ),
            const SizedBox(height: 16),

            // Category Dropdown
            DropdownButtonFormField<String>(
              value: _selectedCategory,
              hint: const Text('Select category'),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              dropdownColor: AppColors.cardPurpleLight,
              decoration: AppDecorations.darkInput('Category'),
              items: _categories.map<DropdownMenuItem<String>>((cat) {
                return DropdownMenuItem<String>(
                  value: cat,
                  child: Text(cat),
                );
              }).toList(),
              onChanged: (value) => setState(() => _selectedCategory = value),
            ),
            const SizedBox(height: 16),

            // Dosage — only relevant for medication tasks (UC-05 step 7).
            if (_selectedCategory == 'Medication') ...[
              TextField(
                controller: _dosageController,
                style: const TextStyle(color: Colors.white),
                decoration: AppDecorations.darkInput(
                  'Dosage',
                  hint: 'e.g., 500mg, 2 tablets',
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Due Date & Time — relabelled "Start" once recurrence is on,
            // since the same field is the series' start date/time.
            Text(
              _recurrenceType == RecurrenceType.none
                  ? 'Due Date & Time'
                  : 'Start Date & Time',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _selectDueDate(context),
                    child: InputDecorator(
                      decoration: AppDecorations.darkInput(
                        _recurrenceType == RecurrenceType.none
                            ? 'Due Date'
                            : 'Start Date',
                      ),
                      child: Text(
                        _dueDate == null
                            ? 'Not set'
                            : '${_dueDate!.month}/${_dueDate!.day}/${_dueDate!.year}',
                        style: const TextStyle(fontSize: 16, color: Colors.white),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: () => _selectDueTime(context),
                    child: InputDecorator(
                      decoration: AppDecorations.darkInput(
                        _recurrenceType == RecurrenceType.none
                            ? 'Due Time'
                            : 'Start Time',
                      ),
                      child: Text(
                        _dueTime == null
                            ? 'Not set'
                            : _dueTime!.format(context),
                        style: const TextStyle(fontSize: 16, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Repeat (Phase 2)
            const Text(
              'Repeat',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<RecurrenceType>(
              value: _recurrenceType,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              dropdownColor: AppColors.cardPurpleLight,
              decoration: AppDecorations.darkInput('Repeat'),
              items: RecurrenceType.values.map((t) {
                return DropdownMenuItem(value: t, child: Text(t.label));
              }).toList(),
              onChanged: (value) => setState(() {
                _recurrenceType = value ?? RecurrenceType.none;
                if (_recurrenceType == RecurrenceType.none) {
                  _selectedWeekdays = [];
                }
              }),
            ),
            if (_recurrenceType == RecurrenceType.weekly) ...[
              const SizedBox(height: 12),
              _weekdaySelector(),
            ],
            if (_recurrenceType == RecurrenceType.custom) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _customIntervalController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white),
                      decoration: AppDecorations.darkInput('Every'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<RecurrenceUnit>(
                      value: _customUnit,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      dropdownColor: AppColors.cardPurpleLight,
                      decoration: AppDecorations.darkInput('Unit'),
                      items: RecurrenceUnit.values.map((u) {
                        return DropdownMenuItem(value: u, child: Text(u.label));
                      }).toList(),
                      onChanged: (value) =>
                          setState(() => _customUnit = value ?? RecurrenceUnit.days),
                    ),
                  ),
                ],
              ),
              if (_customUnit == RecurrenceUnit.weeks) ...[
                const SizedBox(height: 12),
                _weekdaySelector(),
              ],
            ],
            if (_recurrenceType != RecurrenceType.none) ...[
              const SizedBox(height: 16),
              const Text(
                'Ends',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _endsChoice('Never', true)),
                  const SizedBox(width: 12),
                  Expanded(child: _endsChoice('End on date', false)),
                ],
              ),
              if (!_endsNever) ...[
                const SizedBox(height: 12),
                InkWell(
                  onTap: () => _selectEndDate(context),
                  child: InputDecorator(
                    decoration: AppDecorations.darkInput('End Date'),
                    child: Text(
                      _endDate == null
                          ? 'Not set'
                          : '${_endDate!.month}/${_endDate!.day}/${_endDate!.year}',
                      style: const TextStyle(fontSize: 16, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),

            // Reminder interval (Phase 3) — how often the patient's device
            // re-reminds them after the due-time notification, until they
            // respond. Applies to every task, not just recurring ones.
            const Text(
              'Reminder Interval',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              "How often to remind the patient again if they haven't responded.",
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              value: _reminderIntervalMinutes,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              dropdownColor: AppColors.cardPurpleLight,
              decoration: AppDecorations.darkInput('Remind every'),
              items: reminderIntervalChoicesMinutes.map((minutes) {
                return DropdownMenuItem(value: minutes, child: Text('$minutes minutes'));
              }).toList(),
              onChanged: (value) => setState(
                () => _reminderIntervalMinutes = value ?? defaultReminderIntervalMinutes,
              ),
            ),
            const SizedBox(height: 16),

            // Assign to Patient
            _loadingPatients
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.orangeStart),
                  )
                : DropdownButtonFormField<String>(
                    value: _selectedPatientId,
                    hint: const Text('Select patient'),
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    dropdownColor: AppColors.cardPurpleLight,
                    decoration: AppDecorations.darkInput('Assign to Patient'),
                    items: _dropdownPatients.map<DropdownMenuItem<String>>((patient) {
                      return DropdownMenuItem<String>(
                        value: patient['uid'],
                        child: Text(patient['name']),
                      );
                    }).toList(),
                    onChanged: (value) =>
                        setState(() => _selectedPatientId = value),
                  ),
            if (_selectedPatientId != null &&
                !_patients.any((p) => p['uid'] == _selectedPatientId))
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  "This patient is no longer linked to you — pick a "
                  'current patient before saving.',
                  style: TextStyle(fontSize: 12, color: Colors.red),
                ),
              ),
            const SizedBox(height: 16),

            // Description
            TextField(
              controller: _descriptionController,
              maxLines: 3,
              style: const TextStyle(color: Colors.white),
              decoration: AppDecorations.darkInput(
                'Description (Optional)',
                hint: 'Add task details or instructions...',
              ),
            ),
            const SizedBox(height: 30),

            // Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      if (_isEditing) {
                        Navigator.pop(context);
                      } else {
                        Navigator.pushReplacementNamed(context, '/homescreen');
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: AppColors.textMuted),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saveTask,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.orangeStart,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    child: Text(_isEditing ? 'Update Task' : 'Create Task'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: AppColors.cardPurple,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          // Calendar icon (not the old gym/exercise one) — this tab opens
          // ActivityProgressScreen, a per-patient task calendar.
          BottomNavigationBarItem(
              icon: Icon(Icons.calendar_month), label: 'Activities'),
        ],
        currentIndex: 0,
        selectedItemColor: AppColors.orangeStart,
        unselectedItemColor: AppColors.textMuted,
        onTap: (index) {
          if (index == 1) {
            Navigator.pushReplacementNamed(context, '/activityprogress');
          }
        },
      ),
    );
  }
}