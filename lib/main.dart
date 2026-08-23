
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
import 'package:testproject/screens/caregiver/statistics_screen.dart';
import 'package:testproject/screens/patient/task_history_screen.dart';
import 'package:testproject/screens/task_detail_screen.dart';
import 'package:testproject/services/navigator_key.dart';
import 'package:testproject/screens/settings_screen.dart';

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

        '/statistics': (context) =>
            const StatisticsScreen(),

        '/patienttaskhistory': (context) =>
            const PatientTaskHistoryScreen(),

        '/taskdetail': (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final String taskId = args is String ? args : '';
          return TaskDetailScreen(taskId: taskId);
        },
      },
      initialRoute: '/login',
    );
  }
}