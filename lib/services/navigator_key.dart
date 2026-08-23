import 'package:flutter/material.dart';

/// Shared navigator key so services without a BuildContext of their own
/// (namely NotificationService, reacting to a notification tap) can still
/// push routes. Kept in its own file rather than main.dart: main.dart
/// already imports notification_service.dart, so importing main.dart back
/// from there would be a circular import.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
