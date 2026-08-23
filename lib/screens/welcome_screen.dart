import 'package:flutter/material.dart';

import 'auth/login_screen.dart';
import 'auth/register_screen.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      body: Center(
        child: Padding(
          padding:
              const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment:
                MainAxisAlignment.center,
            children: [

              const Text(
                "MindCare",
                style: TextStyle(
                  fontSize: 36,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              const SizedBox(height: 50),

              ElevatedButton(
                onPressed: () {

                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const LoginScreen(),
                    ),
                  );

                },
                child: const Text(
                  "Login",
                ),
              ),

              const SizedBox(height: 15),

              ElevatedButton(
                onPressed: () {

                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const RegisterScreen(),
                    ),
                  );

                },
                child: const Text(
                  "Register",
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}