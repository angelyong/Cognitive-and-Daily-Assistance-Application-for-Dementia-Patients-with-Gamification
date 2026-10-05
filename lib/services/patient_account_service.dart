import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:testproject/firebase_options.dart';
import 'package:testproject/models/dementia_profile.dart';

/// Handles creation of patient accounts BY a caregiver, without
/// disturbing the caregiver's own login session.
///
/// Why a secondary Firebase app?
///   Calling createUserWithEmailAndPassword on the default FirebaseAuth
///   instance signs out the current user (the caregiver) and signs in the
///   newly created user (the patient). By creating the account on a
///   SEPARATE FirebaseApp instance, the caregiver's session on the default
///   instance is untouched.
///
/// NOTE: this file only handles account creation + linking. Add it as a
/// separate service (or merge these methods into your existing
/// auth_service.dart if you prefer one auth file).
class PatientAccountService {
  static const String _secondaryAppName = 'patientCreator';

  /// Creates a Firebase Auth account for the patient and writes their
  /// users/{uid} document linked to [caregiverId].
  ///
  /// Returns the new patient's uid on success.
  /// Throws [FirebaseAuthException] (e.g. email-already-in-use,
  /// weak-password, invalid-email) or [FirebaseException] for Firestore
  /// failures — the calling screen decides how to display them.
  Future<String> createPatientAccount({
    required String caregiverId,
    required String name,
    required String email,
    required String password,
    required DementiaStage dementiaStage,
    required DementiaType dementiaType,
  }) async {
    // 1. Get (or lazily create) the secondary app instance.
    FirebaseApp secondaryApp;
    try {
      secondaryApp = Firebase.app(_secondaryAppName);
    } on FirebaseException {
      secondaryApp = await Firebase.initializeApp(
        name: _secondaryAppName,
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }

    final FirebaseAuth secondaryAuth =
        FirebaseAuth.instanceFor(app: secondaryApp);

    // 2. Create the patient's auth account on the secondary instance.
    final UserCredential cred =
        await secondaryAuth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final String patientUid = cred.user!.uid;

    // Set the display name so the patient's HomeScreen greeting works.
    await cred.user!.updateDisplayName(name.trim());

    // 3. Sign out on the secondary instance — we only needed the account.
    await secondaryAuth.signOut();

    // 4. Write the patient's user document. The caregiverId field IS the
    //    caregiver-patient link used by getPatientsForCaregiver().
    await FirebaseFirestore.instance.collection('users').doc(patientUid).set({
      'uid': patientUid,
      'name': name.trim(),
      'email': email.trim(),
      'role': 'patient',
      'caregiverId': caregiverId,
      'linkStatus': 'linked',
      'dementiaStage': dementiaStage.firestoreValue,
      'dementiaType': dementiaType.firestoreValue,
      'createdAt': FieldValue.serverTimestamp(),
    });

    return patientUid;
  }

  /// Generates a simple starter password the caregiver can hand to the
  /// patient, e.g. "Mind4821!". Firebase requires >= 6 characters.
  static String generateStarterPassword() {
    final int n = DateTime.now().millisecondsSinceEpoch % 9000 + 1000;
    return 'Mind$n!';
  }

  /// Updates a patient's display name (Firestore is the source of truth
  /// the rest of the app reads from — see HomeScreen's greeting).
  Future<void> updatePatientName({
    required String patientUid,
    required String name,
  }) async {
    await FirebaseFirestore.instance.collection('users').doc(patientUid).update({
      'name': name.trim(),
    });
  }

  /// Sends Firebase's built-in password-reset email to the patient.
  /// This doesn't touch the caregiver's own session and needs no backend —
  /// the patient (or caregiver, if they can access that inbox) follows the
  /// emailed link to set a new password themselves.
  Future<void> sendPatientPasswordResetEmail(String email) async {
    await FirebaseAuth.instance.sendPasswordResetEmail(email: email.trim());
  }
}
