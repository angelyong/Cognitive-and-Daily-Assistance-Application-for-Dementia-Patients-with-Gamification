import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:testproject/services/streak_service.dart';
import 'package:testproject/models/streak_data.dart';
class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<String?> registerUser({
    required String name,
    required String email,
    required String password,
    required String role,
  }) async {
    try {
      print("Creating User...");

      UserCredential userCredential =
          await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );

      print(userCredential.user!.uid);

      await _firestore
          .collection('users')
          .doc(userCredential.user!.uid)
          .set({
        'uid': userCredential.user!.uid,
        'name': name.trim(),
        'email': email.trim(),
        'role': role,
        'streakPoints': 0,
        'currentStreak': 0,
        'longestStreak': 0,
        'lastLoginDate': null,
        'createdAt': Timestamp.now(),
      });
      print("Firestore Saved");
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message;
    } catch (e) {
      print(e.toString());
      return "Registration failed.";
    }
  }

Future<Map<String, dynamic>?> loginUser({
    required String email,
    required String password,
  }) async {
    try {
      UserCredential userCredential =
          await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );

      String uid = userCredential.user!.uid;

      DocumentSnapshot userDoc =
          await _firestore.collection('users').doc(uid).get();

      if (!userDoc.exists) {
        return null;
      }

      final data = userDoc.data() as Map<String, dynamic>;

      // Award the daily streak only for patients.
      if (data['role'] == 'patient') {
        final StreakResult result =
            await StreakService().checkAndUpdateStreak(uid);
        data['streakResult'] = result;
      }

      return data;
    } on FirebaseAuthException catch (e) {
      print("FirebaseAuthException");
      print("Code: ${e.code}");
      print("Message: ${e.message}");
      rethrow;
    } catch (e) {
      print("Other error: $e");
      rethrow;
    }
  }

  Future<bool> logout() async {
  try {
    await _auth.signOut();
    return true;
  } on FirebaseAuthException catch (e) {
    print(e.message);
    return false;
  } catch (e) {
    print(e.toString());
    return false;
  }
}
}