import 'package:shared_preferences/shared_preferences.dart';

/// Persists the login screen's "Remember me" choice across app launches.
///
/// Firebase Auth already keeps the signed-in session on disk, so on a cold
/// start [FirebaseAuth.instance.currentUser] is non-null even without this.
/// What this flag decides is whether the app should *honour* that persisted
/// session (auto-login, see AuthGate in main.dart) or sign it out and make the
/// user log in again. It also remembers the email so the login field can be
/// pre-filled the next time the login screen is shown.
class SessionPrefs {
  static const String _rememberKey = 'remember_me';
  static const String _emailKey = 'remembered_email';

  /// Records the user's choice after a successful login. When [remember] is
  /// false the stored email is cleared so nothing lingers on the device.
  static Future<void> setRemembered(bool remember, {String? email}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rememberKey, remember);
    if (remember && email != null && email.isNotEmpty) {
      await prefs.setString(_emailKey, email);
    } else {
      await prefs.remove(_emailKey);
    }
  }

  static Future<bool> isRemembered() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_rememberKey) ?? false;
  }

  static Future<String?> rememberedEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_emailKey);
  }

  /// Wipes the flag and email — used on logout so the next launch lands on the
  /// login screen regardless of the previous "Remember me" state.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_rememberKey);
    await prefs.remove(_emailKey);
  }
}
