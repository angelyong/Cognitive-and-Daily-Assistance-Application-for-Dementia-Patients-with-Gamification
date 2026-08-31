import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'package:testproject/services/streak_service.dart';
import 'package:testproject/models/streak_data.dart';

/// Unified success/failure contract for every [AuthService] method
/// (CODEBASE_CLEANUP.md §5: the 3 methods used to each fail differently —
/// a nullable error string, a rethrow, and a bool — leaving 3 different
/// error-handling shapes for callers to keep straight). [data] is only
/// meaningful when [success] is true; [error] only when it's false.
class AuthResult<T> {
  final bool success;
  final T? data;
  final String? error;

  const AuthResult.success([this.data])
      : success = true,
        error = null;

  const AuthResult.failure(this.error)
      : success = false,
        data = null;
}

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<AuthResult<void>> registerUser({
    required String name,
    required String email,
    required String password,
    required String role,
  }) async {
    try {
      if (kDebugMode) print("Creating User...");

      UserCredential userCredential =
          await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );

      if (kDebugMode) print(userCredential.user!.uid);

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
      if (kDebugMode) print("Firestore Saved");
      return const AuthResult.success();
    } on FirebaseAuthException catch (e) {
      return AuthResult.failure(e.message);
    } catch (e) {
      if (kDebugMode) print(e.toString());
      return const AuthResult.failure("Registration failed.");
    }
  }

  Future<AuthResult<Map<String, dynamic>>> loginUser({
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
        return const AuthResult.failure("User data not found");
      }

      final data = userDoc.data() as Map<String, dynamic>;

      // Award the daily streak only for patients.
      if (data['role'] == 'patient') {
        final StreakResult result =
            await StreakService().checkAndUpdateStreak(uid);
        data['streakResult'] = result;
      }

      return AuthResult.success(data);
    } on FirebaseAuthException catch (e) {
      if (kDebugMode) {
        print("FirebaseAuthException");
        print("Code: ${e.code}");
        print("Message: ${e.message}");
      }
      return AuthResult.failure(e.message ?? e.code);
    } catch (e) {
      if (kDebugMode) print("Other error: $e");
      return AuthResult.failure(e.toString());
    }
  }

  Future<AuthResult<void>> logout() async {
    try {
      await _auth.signOut();
      return const AuthResult.success();
    } on FirebaseAuthException catch (e) {
      if (kDebugMode) print(e.message);
      return AuthResult.failure(e.message);
    } catch (e) {
      if (kDebugMode) print(e.toString());
      return AuthResult.failure(e.toString());
    }
  }
}