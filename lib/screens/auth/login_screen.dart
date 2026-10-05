import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:testproject/services/auth_service.dart';
import 'package:testproject/services/session_prefs.dart';
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
  void initState() {
    super.initState();
    // If the user previously ticked "Remember me", pre-fill their email and
    // re-tick the box so the choice carries over between sessions.
    SessionPrefs.rememberedEmail().then((email) {
      if (!mounted || email == null || email.isEmpty) return;
      setState(() {
        emailController.text = email;
        rememberMe = true;
      });
    });
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

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
                    onPressed: _showForgotPasswordDialog,
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

    // Persist the "Remember me" choice now that login has succeeded. When
    // ticked, the next cold start auto-resumes this session (see AuthGate in
    // main.dart) and pre-fills this email; when unticked, the session is
    // signed out on next launch so login is required again.
    await SessionPrefs.setRemembered(
      rememberMe,
      email: emailController.text.trim(),
    );

    if (!mounted) return;

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

  /// Prompts for an email (pre-filled from the login field) and sends a
  /// Firebase password-reset link to it.
  Future<void> _showForgotPasswordDialog() async {
    // The dialog owns its own TextEditingController (see _ForgotPasswordDialog)
    // so Flutter disposes it only after the dialog route is fully gone. Doing
    // the dispose here, right after the dialog closed, tore the controller out
    // from under the still-animating TextField and tripped a framework
    // assertion (_dependents.isEmpty).
    final String? email = await showDialog<String>(
      context: context,
      builder: (_) => _ForgotPasswordDialog(
        initialEmail: emailController.text.trim(),
      ),
    );

    // Null means the dialog was cancelled/dismissed.
    if (email == null) return;

    if (email.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your email address.')),
      );
      return;
    }

    final AuthResult<void> result =
        await AuthService().sendPasswordReset(email);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.success
              ? 'Password reset link sent to $email. Check your inbox.'
              : (result.error ?? 'Could not send reset email.'),
        ),
      ),
    );
  }
}

/// The "Reset Password" dialog body. Kept as its own [StatefulWidget] so the
/// [TextEditingController] is created and disposed by Flutter alongside the
/// dialog route — disposing it manually the moment the dialog closed crashed
/// with a `_dependents.isEmpty` assertion while the TextField was still
/// animating out. Pops with the trimmed email string, or null if cancelled.
class _ForgotPasswordDialog extends StatefulWidget {
  const _ForgotPasswordDialog({required this.initialEmail});

  final String initialEmail;

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialEmail);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.cardPurple,
      title: const Text(
        'Reset Password',
        style: TextStyle(color: Colors.white),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Enter your account email and we'll send you a link to reset "
            'your password.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 14),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.emailAddress,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            onSubmitted: (_) =>
                Navigator.pop(context, _controller.text.trim()),
            decoration: AppDecorations.darkInput(
              'Email Address',
              hint: 'Enter your email',
              prefixIcon: const Icon(
                Icons.email_outlined,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.orangeStart,
            foregroundColor: Colors.white,
          ),
          child: const Text('Send Link'),
        ),
      ],
    );
  }
}
