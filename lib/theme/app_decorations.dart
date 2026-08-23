import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Reusable decorations so the same border/fill/radius isn't
/// re-typed on every form field and every card container.
class AppDecorations {
  AppDecorations._();

  /// Standard rounded card container (dark purple).
  /// Use:  Container(decoration: AppDecorations.card, ...)
  static BoxDecoration get card => BoxDecoration(
        color: AppColors.cardPurple,
        borderRadius: BorderRadius.circular(16),
      );

  /// The orange gradient card/button background.
  static BoxDecoration gradientCard({double radius = 20}) => BoxDecoration(
        gradient: AppGradients.orange,
        borderRadius: BorderRadius.circular(radius),
      );

  /// Standard input decoration for the CreateTask form fields.
  /// Pass the label (and optionally a hint) instead of re-writing
  /// the OutlineInputBorder + filled/fillColor block every time.
  ///
  /// Use:
  ///   TextField(decoration: AppDecorations.input('Task Title',
  ///       hint: 'e.g., Morning Walk'))
  static InputDecoration input(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      filled: true,
      fillColor: Colors.grey.shade200,
    );
  }

  /// Same purpose as [input], for screens on the dark purple background
  /// (HomeScreen, PatientListScreen, ...). Use with a white/light TextField
  /// `style` since this only themes the decoration, not the input text.
  static InputDecoration darkInput(
    String label, {
    String? hint,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: AppColors.textMuted),
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textMuted),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide.none,
      ),
      filled: true,
      fillColor: AppColors.cardPurpleLight,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
    );
  }
}