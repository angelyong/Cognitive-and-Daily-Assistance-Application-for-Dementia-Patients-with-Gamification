import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/models/dementia_profile.dart';
import 'package:testproject/services/patient_account_service.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_decorations.dart';
import 'package:testproject/widgets/dementia_badges.dart';
import '../../widgets/SideDrawer.dart';

/// UC: Add & Manage Patient Accounts.
///
/// Flow (Option 1 — caregiver-mediated onboarding):
///   1. Caregiver fills in the patient's name, email and password.
///   2. PatientAccountService creates the Auth account on a secondary
///      Firebase app instance, so the caregiver stays logged in.
///   3. A users/{uid} doc is written with role 'patient' and this
///      caregiver's uid as caregiverId — that field is the monitoring link.
///   4. A success dialog shows the credentials to hand to the patient.
class AddPatientScreen extends StatefulWidget {
  const AddPatientScreen({super.key});

  @override
  State<AddPatientScreen> createState() => _AddPatientScreenState();
}

class _AddPatientScreenState extends State<AddPatientScreen> {
  final PatientAccountService _patientService = PatientAccountService();
  final String caregiverId = FirebaseAuth.instance.currentUser!.uid;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _saving = false;

  DementiaStage? _selectedStage;
  DementiaType? _selectedType;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _generatePassword() {
    setState(() {
      _passwordController.text =
          PatientAccountService.generateStarterPassword();
      _obscurePassword = false; // show it so the caregiver can note it down
    });
  }

  Future<void> _createPatient() async {
    final String name = _nameController.text.trim();
    final String email = _emailController.text.trim();
    final String password = _passwordController.text;

    // ---- Validation ----
    if (name.isEmpty) {
      _showSnackBar("Please enter the patient's name");
      return;
    }
    if (email.isEmpty || !email.contains('@')) {
      _showSnackBar('Please enter a valid email address');
      return;
    }
    if (password.length < 6) {
      _showSnackBar('Password must be at least 6 characters');
      return;
    }
    if (_selectedStage == null) {
      _showSnackBar('Please select the dementia stage');
      return;
    }
    if (_selectedType == null) {
      _showSnackBar('Please select the dementia type');
      return;
    }

    setState(() => _saving = true);

    try {
      await _patientService.createPatientAccount(
        caregiverId: caregiverId,
        name: name,
        email: email,
        password: password,
        dementiaStage: _selectedStage!,
        dementiaType: _selectedType!,
      );

      if (!mounted) return;
      // Show credentials so the caregiver can hand them to the patient.
      await _showSuccessDialog(name: name, email: email, password: password);

      if (!mounted) return;
      // Land back on the dashboard rather than the patient list/form stack.
      Navigator.pushNamedAndRemoveUntil(
        context,
        '/homescreen',
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      String message;
      switch (e.code) {
        case 'email-already-in-use':
          message = 'This email already has an account. '
              'Use a different email for the patient.';
          break;
        case 'invalid-email':
          message = 'The email address is not valid.';
          break;
        case 'weak-password':
          message = 'Password is too weak. Try a longer one.';
          break;
        default:
          message = 'Could not create account: ${e.message}';
      }
      _showSnackBar(message);
    } catch (e) {
      _showSnackBar('Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showSuccessDialog({
    required String name,
    required String email,
    required String password,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.cardPurple,
          title: const Text(
            'Patient account created',
            style: TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Give these login details to $name:',
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 12),
              _credentialRow('Email', email),
              const SizedBox(height: 6),
              _credentialRow('Password', password),
              const SizedBox(height: 12),
              const Text(
                'Tip: the patient (or a family member) can change this '
                'password after their first login.',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(text: 'Email: $email\nPassword: $password'),
                );
                _showSnackBar('Credentials copied', isSuccess: true);
              },
              child: const Text('Copy'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.orangeStart,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        );
      },
    );
  }

  Widget _credentialRow(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
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
            const Text(
              'Add Patient',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Create an account for a patient you care for. '
              'You will stay logged in.',
              style: TextStyle(fontSize: 14, color: AppColors.textMuted),
            ),
            const SizedBox(height: 24),

            // Patient name
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: Colors.white),
              decoration: AppDecorations.darkInput(
                'Patient Name',
                hint: 'e.g., Tan Ah Kow',
              ),
            ),
            const SizedBox(height: 16),

            // Patient email
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              style: const TextStyle(color: Colors.white),
              decoration: AppDecorations.darkInput(
                'Patient Email',
                hint: 'e.g., patient@example.com',
              ),
            ),
            const SizedBox(height: 16),

            // Password + generate button
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    style: const TextStyle(color: Colors.white),
                    decoration: AppDecorations.darkInput(
                      'Starter Password',
                      hint: 'At least 6 characters',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                          color: AppColors.textMuted,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _generatePassword,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.orangeStart,
                  ),
                  child: const Text('Generate'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Dementia stage
            DropdownButtonFormField<DementiaStage>(
              value: _selectedStage,
              hint: const Text('Select stage'),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              dropdownColor: AppColors.cardPurpleLight,
              decoration: AppDecorations.darkInput('Dementia Stage'),
              items: DementiaStage.values.map((stage) {
                return DropdownMenuItem<DementiaStage>(
                  value: stage,
                  child: Text(stage.label),
                );
              }).toList(),
              onChanged: (value) => setState(() => _selectedStage = value),
            ),
            if (_selectedStage != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: DementiaStageBadge(stage: _selectedStage!.firestoreValue),
              ),
            ],
            const SizedBox(height: 16),

            // Dementia type
            DropdownButtonFormField<DementiaType>(
              value: _selectedType,
              hint: const Text('Select type'),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              dropdownColor: AppColors.cardPurpleLight,
              decoration: AppDecorations.darkInput('Dementia Type'),
              items: DementiaType.values.map((type) {
                return DropdownMenuItem<DementiaType>(
                  value: type,
                  child: Text(type.label),
                );
              }).toList(),
              onChanged: (value) => setState(() => _selectedType = value),
            ),
            if (_selectedType != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: DementiaTypeBadge(type: _selectedType!.firestoreValue),
              ),
            ],
            const SizedBox(height: 30),

            // Create button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _createPatient,
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
                    : const Text('Create Patient Account'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
