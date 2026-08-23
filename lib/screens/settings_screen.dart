import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:testproject/services/font_scale_notifier.dart';
import 'package:testproject/theme/app_colors.dart';
import '../widgets/side_drawer.dart';

/// App-wide preferences. Currently just font size, but the layout leaves
/// room to add more (theme, notification defaults, ...) later.
///
/// Patient-only logout icon (top-right): a dementia patient's drawer no
/// longer has a Logout item at all (see SideDrawer's class doc comment on
/// _PatientDrawerBody) — it's deliberately here instead, a second,
/// intentional screen away from the drawer, to cut down on accidental
/// taps. A caregiver keeps their existing drawer Logout unchanged and
/// doesn't get this icon.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isPatient = false;

  @override
  void initState() {
    super.initState();
    _loadRole();
  }

  Future<void> _loadRole() async {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (!mounted || !doc.exists) return;
    final data = doc.data() as Map<String, dynamic>;
    setState(() => _isPatient = data['role'] == 'patient');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDark,
      drawer: const SideDrawer(),
      appBar: AppBar(
        title: const Text('MindCare', style: TextStyle(color: Colors.white)),
        backgroundColor: AppColors.bgDark,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        actions: _isPatient
            ? [
                IconButton(
                  icon: const Icon(Icons.logout, color: AppColors.orangeEnd),
                  tooltip: 'Log out',
                  onPressed: () => showLogoutConfirmation(context),
                ),
              ]
            : null,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Settings',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Adjust MindCare to suit you.',
              style: TextStyle(fontSize: 14, color: AppColors.textMuted),
            ),
            const SizedBox(height: 28),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.cardPurple,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.text_fields, color: AppColors.orangeStart),
                      SizedBox(width: 10),
                      Text(
                        'Font Size',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Make text bigger or smaller across the whole app.',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 20),

                  // Live preview of a real in-app string, so the effect is
                  // obvious before leaving this screen.
                  ValueListenableBuilder<double>(
                    valueListenable: fontScaleNotifier,
                    builder: (context, scale, _) {
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          vertical: 18,
                          horizontal: 16,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.bgDark,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Take your medication at 8:00 AM',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 16 * scale,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),

                  ValueListenableBuilder<double>(
                    valueListenable: fontScaleNotifier,
                    builder: (context, scale, _) {
                      return Row(
                        children: [
                          const Text(
                            'A',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textMuted,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: scale,
                              min: FontScaleNotifier.min,
                              max: FontScaleNotifier.max,
                              divisions: 4,
                              label: '${(scale * 100).round()}%',
                              activeColor: AppColors.orangeStart,
                              inactiveColor: AppColors.cardPurpleLight,
                              onChanged: (value) =>
                                  fontScaleNotifier.setScale(value),
                            ),
                          ),
                          const Text(
                            'A',
                            style: TextStyle(
                              fontSize: 26,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  Center(
                    child: ValueListenableBuilder<double>(
                      valueListenable: fontScaleNotifier,
                      builder: (context, scale, _) => Text(
                        '${(scale * 100).round()}%',
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: TextButton(
                      onPressed: () => fontScaleNotifier.setScale(1.0),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.orangeStart,
                      ),
                      child: const Text('Reset to Default'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
