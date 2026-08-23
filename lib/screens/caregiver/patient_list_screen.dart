import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/widgets/side_drawer.dart';
import 'package:testproject/widgets/patient_card.dart';
import 'add_patient_screen.dart';
import 'edit_patient_screen.dart';

/// Lists every patient linked to the logged-in caregiver.
/// The "+" action (top right) opens [AddPatientScreen] to onboard a new one.
class PatientListScreen extends StatelessWidget {
  const PatientListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final FirestoreService firestoreService = FirestoreService();
    final String? caregiverId = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: AppColors.bgDark,
      drawer: const SideDrawer(),
      appBar: AppBar(
        backgroundColor: AppColors.bgDark,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Manage Patients',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Patient',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AddPatientScreen()),
            ),
          ),
        ],
      ),
      body: caregiverId == null
          ? const Center(
              child: Text(
                'Not logged in',
                style: TextStyle(color: Colors.white),
              ),
            )
          : StreamBuilder<QuerySnapshot>(
              stream: firestoreService.getPatientsStream(caregiverId),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'Something went wrong: ${snapshot.error}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  );
                }

                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.orangeStart,
                    ),
                  );
                }

                final docs = snapshot.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'No patients yet.\nTap + to add one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: docs.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    return PatientCard(
                      name: (data['name'] ?? 'Unnamed') as String,
                      dementiaStage: data['dementiaStage'] as String?,
                      dementiaType: data['dementiaType'] as String?,
                      patientId: doc.id,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => EditPatientScreen(
                            patientUid: doc.id,
                            name: (data['name'] ?? '') as String,
                            email: (data['email'] ?? '') as String,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
