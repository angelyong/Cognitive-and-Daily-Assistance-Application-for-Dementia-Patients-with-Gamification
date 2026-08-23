import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Reusable text styles so headings/body/muted text stay consistent
/// and you don't re-type `TextStyle(color: ..., fontSize: ..., ...)`
/// on every screen.
///
/// Use directly:            AppTextStyles.heading
/// Or tweak per-use:        AppTextStyles.heading.copyWith(fontSize: 26)
class AppTextStyles {
  AppTextStyles._();

  /// Big screen greeting, e.g. "Good Morning, Angel!"
  static const TextStyle heading = TextStyle(
    color: Colors.white,
    fontSize: 22,
    fontWeight: FontWeight.bold,
  );

  /// Section titles like "Daily Tasks", "Medication Schedule".
  static const TextStyle sectionTitle = TextStyle(
    color: Colors.white,
    fontSize: 18,
    fontWeight: FontWeight.bold,
  );

  /// Card / item titles.
  static const TextStyle cardTitle = TextStyle(
    color: Colors.white,
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );

  /// Muted secondary text (dates, times, hints).
  static const TextStyle muted = TextStyle(
    color: AppColors.textMuted,
    fontSize: 12,
  );

  /// The little "Add Task" / "Add Med" action link.
  static const TextStyle actionLink = TextStyle(
    color: AppColors.orangeStart,
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );
}
