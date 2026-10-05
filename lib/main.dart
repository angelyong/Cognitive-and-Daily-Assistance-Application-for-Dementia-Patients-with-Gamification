
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'package:testproject/screens/auth/register_screen.dart';
import 'package:testproject/screens/auth/login_screen.dart';
import 'package:testproject/screens/patient/patient_dashboard.dart';
import 'package:testproject/screens/caregiver/activity_progress_screen.dart';
import 'package:testproject/screens/caregiver/create_task_screen.dart';
import 'package:testproject/screens/home_screen.dart';
import 'package:testproject/screens/patient/streak_screen.dart';
import 'package:testproject/screens/patient/cognitive_exercise_screen.dart';
import 'package:testproject/services/notification_service.dart';
import 'package:testproject/services/font_scale_notifier.dart';
import 'package:testproject/screens/caregiver/add_patient_screen.dart';
import 'package:testproject/screens/caregiver/patient_list_screen.dart';
import 'package:testproject/screens/caregiver/task_history_screen.dart';
import 'package:testproject/screens/caregiver/game_statistic_screen.dart';
import 'package:testproject/screens/caregiver/patient_performance_screen.dart';
import 'package:testproject/screens/patient/task_history_screen.dart';
import 'package:testproject/screens/task_detail_screen.dart';
import 'package:testproject/services/navigator_key.dart';
import 'package:testproject/services/session_prefs.dart';
import 'package:testproject/services/streak_service.dart';
import 'package:testproject/screens/settings_screen.dart';
import 'package:testproject/theme/app_colors.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await NotificationService().init();
  await NotificationService().requestPermissions();
  await fontScaleNotifier.load();

  // PHASE 3 (see phase3_reminder_notifications_prompt.md, Step 10): a
  // persisted patient session cold-starting the app (e.g. after a device
  // reboot, or the app having been force-stopped) needs its upcoming
  // reminders reconciled here — PatientDashboard.initState() separately
  // covers the "just logged in" case. Fire-and-forget so it doesn't delay
  // startup; not run for a caregiver session (reminders are patient-only,
  // see NotificationService's class doc comment for why).
  final String? uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid != null) {
    FirebaseFirestore.instance.collection('users').doc(uid).get().then((doc) {
      if (doc.exists && doc.data()?['role'] == 'patient') {
        NotificationService().reconcilePatientReminders(uid);
      }
    });
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // Lets NotificationService push a route (task detail) from a
      // notification tap, where there's no BuildContext of its own.
      navigatorKey: navigatorKey,

      // Applies the user's chosen text scale (Settings > Font Size) to
      // every screen, the same way an OS-level accessibility setting would.
      builder: (context, child) {
        return ValueListenableBuilder<double>(
          valueListenable: fontScaleNotifier,
          builder: (context, scale, _) {
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
              ),
              child: child!,
            );
          },
        );
      },

      routes: {
        '/register': (context) =>
            const RegisterScreen(),

        '/login': (context) =>
            const LoginScreen(),

        '/patientdashboard': (context) => 
             const PatientDashboard(),

        '/activityprogress': (context) => 
            const ActivityProgress(),
      
        '/createtask': (context) => 
            const CreateTaskScreen(),

        '/homescreen': (context) => 
             HomeScreen(),

        '/streak': (context) =>
            const StreakScreen(),

        '/addpatient': (context) =>
            const AddPatientScreen(),

        '/managepatient': (context) =>
            const PatientListScreen(),

        '/settings': (context) =>
            const SettingsScreen(),

        '/cognitive': (context) =>
            const CognitiveExerciseScreen(),

        '/taskhistory': (context) =>
            const TaskHistoryScreen(),

        // Now the bird's-eye Patient Performance dashboard — the drawer's
        // "Statistics" item keeps this route name so nothing else has to
        // change, but it opens a different screen than it used to (see
        // PERFORMANCE_DASHBOARD_PLAN.md). Per-game difficulty depth moved
        // to '/gamestatistic', reached FROM this dashboard now, not
        // directly from the drawer.
        '/statistics': (context) =>
            const PatientPerformanceScreen(),

        '/gamestatistic': (context) =>
            const GameStatisticScreen(),

        '/patienttaskhistory': (context) =>
            const PatientTaskHistoryScreen(),

        '/taskdetail': (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final String taskId = args is String ? args : '';
          return TaskDetailScreen(taskId: taskId);
        },
      },
      // AuthGate decides between auto-login and the login screen based on the
      // "Remember me" flag; it replaces the old fixed initialRoute: '/login'.
      home: const AuthGate(),
    );
  }
}

/// First screen at launch. Resolves where to go:
///  - no signed-in session, or "Remember me" was off  -> LoginScreen
///  - session present and "Remember me" on            -> role's dashboard
///
/// Firebase keeps the session on disk across launches, so a returning user is
/// still signed in here; the [SessionPrefs] flag is what decides whether we
/// honour that or sign them out and require a fresh login.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final Future<String?> _routeFuture = _resolveRoute();

  /// Returns the named route to auto-navigate to, or null to show login.
  Future<String?> _resolveRoute() async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    final bool remember = await SessionPrefs.isRemembered();
    if (!remember) {
      // A session exists on disk but the user didn't opt to stay logged in.
      await FirebaseAuth.instance.signOut();
      return null;
    }

    final DocumentSnapshot doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    String? role;
    if (doc.exists) {
      final data = doc.data() as Map<String, dynamic>?;
      role = data?['role'] as String?;
    }

    if (role == 'patient') {
      // Keep the daily streak correct on auto-login too. It's a no-op after
      // the first login of the day, so it's safe to await here silently
      // (no celebratory dialog — that only shows on an explicit login).
      await StreakService().checkAndUpdateStreak(user.uid);
      return '/patientdashboard';
    }
    if (role == 'caregiver') {
      return '/homescreen';
    }

    // Unknown / missing role: fall back to login rather than guessing.
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _routeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            backgroundColor: AppColors.bgDark,
            body: Center(
              child: CircularProgressIndicator(color: AppColors.orangeStart),
            ),
          );
        }

        final String? route = snapshot.data;
        if (route == null) {
          return const LoginScreen();
        }

        // Defer navigation until after this frame — we can't push a route
        // while the widget tree for AuthGate is still being built.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          navigatorKey.currentState?.pushReplacementNamed(route);
        });
        return const Scaffold(
          backgroundColor: AppColors.bgDark,
          body: Center(
            child: CircularProgressIndicator(color: AppColors.orangeStart),
          ),
        );
      },
    );
  }
}