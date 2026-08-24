import 'package:flutter/material.dart';

import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/services/patient_account_service.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_decorations.dart';
import '../../widgets/side_drawer.dart';
import 'game_statistic_screen.dart';

/// Lets a caregiver update a patient's name and trigger a password-reset
/// email. Email is intentionally not editable — it's the account's sign-in
/// identity, so changing it here would desync it from Firebase Auth.
class EditPatientScreen extends StatefulWidget {
  final String patientUid;
  final String name;
  final String email;

  const EditPatientScreen({
    super.key,
    required this.patientUid,
    required this.name,
    required this.email,
  });

  @override
  State<EditPatientScreen> createState() => _EditPatientScreenState();
}

class _EditPatientScreenState extends State<EditPatientScreen> {
  final PatientAccountService _patientService = PatientAccountService();
  final FirestoreService _firestoreService = FirestoreService();

  late final TextEditingController _nameController =
      TextEditingController(text: widget.name);

  bool _saving = false;
  bool _sendingReset = false;
  bool _removing = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveChanges() async {
    final String name = _nameController.text.trim();
    if (name.isEmpty) {
      _showSnackBar("Please enter the patient's name");
      return;
    }

    setState(() => _saving = true);
    try {
      if (name != widget.name) {
        await _patientService.updatePatientName(
          patientUid: widget.patientUid,
          name: name,
        );
      }

      if (!mounted) return;
      _showSnackBar('Patient updated', isSuccess: true);
      Navigator.pop(context);
    } catch (e) {
      _showSnackBar('Error updating patient: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _sendPasswordReset() async {
    setState(() => _sendingReset = true);
    try {
      await _patientService.sendPatientPasswordResetEmail(widget.email);
      if (!mounted) return;
      _showSnackBar(
        'Password reset email sent to ${widget.email}',
        isSuccess: true,
      );
    } catch (e) {
      _showSnackBar('Error sending reset email: $e');
    } finally {
      if (mounted) setState(() => _sendingReset = false);
    }
  }

  Future<void> _removePatient() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardPurple,
        title: const Text(
          'Remove Patient',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Remove ${widget.name} from your patient list?\n\n'
          "This won't delete their account or data — they just won't be "
          'linked to you anymore.',
          style: const TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _removing = true);
    try {
      await _firestoreService.unlinkPatient(widget.patientUid);
      if (!mounted) return;
      _showSnackBar('Patient removed', isSuccess: true);
      Navigator.pop(context);
    } catch (e) {
      _showSnackBar('Error removing patient: $e');
    } finally {
      if (mounted) setState(() => _removing = false);
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
          builder: (context) {
            return IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            );
          },
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Edit Patient',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _removing ? null : _removePatient,
                  tooltip: 'Remove Patient',
                  icon: const Icon(
                    Icons.person_remove,
                    color: Colors.red,
                    size: 28,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Update this patient\'s details below.',
              style: TextStyle(fontSize: 14, color: AppColors.textMuted),
            ),
            const SizedBox(height: 24),

            // Patient name
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: Colors.white),
              decoration: AppDecorations.darkInput('Patient Name'),
            ),
            const SizedBox(height: 16),

            // Patient email — read-only, it's the sign-in identity.
            TextField(
              enabled: false,
              controller: TextEditingController(text: widget.email),
              style: const TextStyle(color: AppColors.textMuted),
              decoration: AppDecorations.darkInput('Patient Email').copyWith(
                fillColor: AppColors.cardPurple,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Email can\'t be changed — it\'s the account sign-in ID.',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 30),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _saveChanges,
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
                child: _saving
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2.5,
                        ),
                      )
                    : const Text('Save Changes'),
              ),
            ),

            const SizedBox(height: 32),
            const Divider(color: AppColors.cardPurpleLight),
            const SizedBox(height: 16),

            const Text(
              'Password',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "Sends a link to the patient's email so they (or you, if you "
              'can access that inbox) can set a new password.',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _sendingReset ? null : _sendPasswordReset,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.orangeStart,
                  side: const BorderSide(color: AppColors.orangeStart),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: _sendingReset
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.orangeStart,
                        ),
                      )
                    : const Icon(Icons.email_outlined),
                label: Text(
                  _sendingReset ? 'Sending...' : 'Send Password Reset Email',
                ),
              ),
            ),

            const SizedBox(height: 32),
            const Divider(color: AppColors.cardPurpleLight),
            const SizedBox(height: 16),

            const Text(
              'Cognitive Game Difficulty',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "Each game now adjusts its own difficulty automatically based "
              "on this patient's recent accuracy. View how each game is "
              'doing, or override a specific one, in Statistics.',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GameStatisticScreen(initialPatientId: widget.patientUid),
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.orangeStart,
                  side: const BorderSide(color: AppColors.orangeStart),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.insights),
                label: const Text('View in Statistics'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
