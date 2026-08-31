import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:testproject/theme/app_colors.dart';

/// Returns the current signed-in user's uid, or null if there isn't one.
/// If null, schedules a redirect to `/login` on the next frame (can't
/// navigate synchronously from `initState`, which is where this is meant
/// to be called).
///
/// CODEBASE_CLEANUP.md §5: several caregiver screens used to force-unwrap
/// `FirebaseAuth.instance.currentUser!.uid` directly in a field
/// initializer — a null session there threw immediately during widget
/// construction (before `initState`/`build` even run) instead of failing
/// gracefully. This centralizes the guard in one place rather than
/// duplicating the same async-redirect timing logic in each screen.
String? requireSessionUid(BuildContext context) {
  final String? uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
      }
    });
  }
  return uid;
}

/// Minimal placeholder for the one frame between [requireSessionUid]
/// detecting a missing session and its scheduled redirect actually firing.
class SessionRedirectPlaceholder extends StatelessWidget {
  const SessionRedirectPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.bgDark,
      body: Center(child: CircularProgressIndicator(color: AppColors.orangeStart)),
    );
  }
}
