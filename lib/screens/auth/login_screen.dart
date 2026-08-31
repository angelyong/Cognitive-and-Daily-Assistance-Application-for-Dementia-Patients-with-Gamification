import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:testproject/services/auth_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:testproject/models/streak_data.dart';
import 'package:testproject/widgets/login_success_effect.dart';
import 'package:testproject/theme/app_colors.dart';
import 'package:testproject/theme/app_decorations.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool rememberMe = false;
  bool obscurePassword = true; // for show/hide toggle

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDark,
      // No AppBar – clean full‑screen design
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Brand Header
              const Text(
                'MindCare',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              const Text(
                'Cognitive & Daily Assistance',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textMuted,
                  letterSpacing: 0.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),

              // "Welcome Back"
              const Text(
                'Welcome Back',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
                textAlign: TextAlign.left,
              ),
              const SizedBox(height: 20),

              // Email Field
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: Colors.white),
                decoration: AppDecorations.darkInput(
                  'Email Address',
                  hint: 'Enter your email',
                  prefixIcon: const Icon(
                    Icons.email_outlined,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Password Field with show/hide toggle
              TextField(
                controller: passwordController,
                obscureText: obscurePassword,
                style: const TextStyle(color: Colors.white),
                decoration: AppDecorations.darkInput(
                  'Password',
                  hint: 'Enter your password',
                  prefixIcon: const Icon(
                    Icons.lock_outline,
                    color: AppColors.textMuted,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscurePassword
                          ? Icons.visibility_off
                          : Icons.visibility,
                      color: AppColors.textMuted,
                    ),
                    onPressed: () {
                      setState(() {
                        obscurePassword = !obscurePassword;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Remember me & Forgot Password row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Checkbox(
                        value: rememberMe,
                        onChanged: (value) {
                          setState(() {
                            rememberMe = value!;
                          });
                        },
                        activeColor: AppColors.orangeStart,
                        checkColor: Colors.white,
                        side: const BorderSide(color: AppColors.textMuted),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const Text(
                        'Remember me',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: () {
                      // TODO: Implement forgot password
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Forgot Password tapped'),
                        ),
                      );
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.orangeStart,
                    ),
                    child: const Text('Forgot Password?'),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Sign In Button
              ElevatedButton(
                onPressed: _signIn,
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
                child: const Text('Sign In'),
              ),
              const SizedBox(height: 20),

              // Sign Up link
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    "Don't have an account? ",
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textMuted,
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      // Navigate to Register Screen
                      Navigator.pushNamed(context, '/register');
                    },
                    child: const Text(
                      'Sign Up',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppColors.orangeStart,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // Placeholder sign‑in logic – can be extended later
Future<void> _signIn() async {
  if (emailController.text.isEmpty || passwordController.text.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Please fill in all fields')),
    );
    return;
  }

  try {
    final AuthResult<Map<String, dynamic>> result = await AuthService().loginUser(
      email: emailController.text.trim(),
      password: passwordController.text.trim(),
    );

    if (!mounted) return;

    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'Login failed.')),
      );
      return;
    }

    final userData = result.data!;
    if (kDebugMode) {
      print("Login Success");
      print(userData);
    }

    // Unlike every other Firestore field read in this codebase, this used
    // to be an unchecked `String role = userData['role'];` cast — a user
    // doc missing `role` (hand-edited in console, migration gap) threw a
    // raw TypeError instead of failing gracefully (HIDDEN_BUGS.md #7).
    final String? role = userData['role'] as String?;
    if (kDebugMode) print("Role: $role");

    if (role == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Your account is missing a role — please contact support."),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Login Successful')),
    );

    if (role == 'patient') {
      // ---- Patient-only: streak dialog, then the visual/sound effect ----
      final StreakResult? streak = userData['streakResult'] as StreakResult?;

      if (streak != null && streak.awarded) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppColors.cardPurple,
            title: Text(
              'Day ${streak.data.currentStreak} Streak!',
              style: const TextStyle(color: Colors.white),
            ),
            content: Text(
              'You earned ${streak.pointsEarned} points today.\n'
              'Total points: ${streak.data.totalPoints}',
              style: const TextStyle(color: AppColors.textMuted),
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.orangeStart,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text('Great!'),
              ),
            ],
          ),
        );
      }

      if (!mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => LoginSuccessEffect(
          message: 'Welcome back!',
          onComplete: () {
            Navigator.of(context).pop(); // close overlay
            Navigator.pushReplacementNamed(context, '/patientdashboard');
          },
        ),
      );
    } else {
      // ---- Caregiver: navigate straight through, no effect ----
      Navigator.pushReplacementNamed(context, '/homescreen');
    }
  } on FirebaseAuthException catch (e) {
    if (kDebugMode) {
      print("FirebaseAuthException");
      print("Code: ${e.code}");
      print("Message: ${e.message}");
    }

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("${e.code}: ${e.message}")),
    );
  } catch (e, stackTrace) {
    if (kDebugMode) {
      print("LOGIN ERROR: $e");
      print(stackTrace);
    }

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString())),
    );
  }
}
}
