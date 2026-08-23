import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide text scale, persisted across launches. Wrapping [MaterialApp]
/// with a [MediaQuery] that reads this value (see main.dart) means every
/// screen's text resizes together — a single accessibility setting rather
/// than something each screen has to opt into individually.
class FontScaleNotifier extends ValueNotifier<double> {
  FontScaleNotifier() : super(1.0);

  static const double min = 0.8;
  static const double max = 1.6;
  static const String _prefsKey = 'font_scale';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = prefs.getDouble(_prefsKey) ?? 1.0;
  }

  Future<void> setScale(double scale) async {
    value = scale.clamp(min, max);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsKey, value);
  }
}

/// Single instance shared by main.dart (applies it) and SettingsScreen
/// (lets the user change it).
final FontScaleNotifier fontScaleNotifier = FontScaleNotifier();
