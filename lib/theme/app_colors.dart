import 'package:flutter/material.dart';

/// Central colour palette for MindCare.

/// Import this anywhere instead of re-declaring colours:
///   import 'package:testproject/theme/app_colors.dart';
/// Then use `AppColors.orangeStart`, `AppColors.bgDark`, etc.
///
/// The private constructor stops anyone from accidentally
/// doing `AppColors()` — it's a constants holder, not an object.
class AppColors {
  AppColors._();

  // ---- Backgrounds / surfaces ----
  static const Color bgDark = Color(0xFF1A1530);
  static const Color cardPurple = Color(0xFF2E2750);
  static const Color cardPurpleLight = Color(0xFF3A3160);

  // ---- Accent / brand ----
  static const Color orangeStart = Color(0xFFFF7A59);
  static const Color orangeEnd = Color(0xFFFF4D6D);

  // ---- Status ----
  static const Color greenCheck = Color(0xFF2ED9A4);
  static const Color textMuted = Color(0xFFB8B0D4);

  // ---- Chips / small accents ----
  static const Color categoryChipBg = Color(0xFF4A2E5A);
  static const Color categoryChipText = Color(0xFFFF9AB8);
  static const Color medIconBg = Color(0xFF1E3A36);

  // ---- Dementia stage ----
  static const Color stageEarly = Color(0xFF2ED9A4); // reuse greenCheck
  static const Color stageMiddle = Color(0xFFFFB020); // amber

  // ---- Dementia type ----
  // Only Alzheimer's and Vascular are supported (Lewy Body / FTD were
  // deliberately dropped — see DementiaType's doc comment).
  static const Color typeAlzheimers = Color(0xFF7C83FD); // soft indigo
  static const Color typeVascular = Color(0xFFE5484D); // soft red

  // ---- Risk indicator (Part 2) ----
  // Deliberately a stronger, more saturated red than typeVascular's soft
  // coral above — this is a caregiver warning badge, not a category label,
  // and needs to read as urgent at a glance.
  static const Color riskRed = Color(0xFFD32F2F);
  // Amber "monitor" tier — 2 of 3 risk signals active. A softer,
  // less-urgent warning than riskRed's full 3-of-3 alert, but still clearly
  // distinct from the no-risk (absent-badge) state.
  static const Color riskAmber = Color(0xFFFFB020);
}

/// Reusable gradients so you never copy-paste the same LinearGradient again.
class AppGradients {
  AppGradients._();

  /// The orange brand gradient used on the progress card,
  /// the cognitive-activities button, and the drawer header.
  static const LinearGradient orange = LinearGradient(
    colors: [AppColors.orangeStart, AppColors.orangeEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}