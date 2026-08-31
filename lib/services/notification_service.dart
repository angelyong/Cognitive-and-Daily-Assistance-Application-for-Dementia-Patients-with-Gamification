import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:testproject/firebase_options.dart';
import 'package:testproject/models/occurrence_status.dart';
import 'package:testproject/models/task_recurrence.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/services/navigator_key.dart';
import 'package:testproject/widgets/reminder_popup.dart';

const String _completeActionId = 'complete_action';
const String _missedActionId = 'missed_action';
const String _iosActionCategoryId = 'reminder_actions';

/// Android-only bridge to the fancy native reminder notification — see
/// FancyReminderScheduler.kt/FancyReminderReceiver.kt/ReminderActionReceiver.kt.
/// A fully custom RemoteViews notification layout (matching ReminderPopup's
/// look: category icon, colors, styled Complete/Missed buttons) isn't
/// achievable through flutter_local_notifications' own Dart API — it only
/// exposes Android's built-in notification styles, not arbitrary custom
/// layouts — so this specific piece has to go through native code instead.
const MethodChannel _fancyReminderChannel =
    MethodChannel('com.example.testproject/fancy_reminders');

/// Central service for scheduling local (on-device) task reminder
/// notifications. Scheduled reminders are handled by the OS alarm
/// scheduler, so they still fire even if the app has been closed.
///
/// UC-05 exceptional flow 8c ("if device is offline, queue and deliver
/// when back online"): satisfied inherently by this architecture. Local
/// notifications are scheduled with the OS alarm system (zonedSchedule),
/// not sent from a server, so delivery never depends on connectivity —
/// there's no separate offline queue to build.
///
/// PHASE 3 (see phase3_reminder_notifications_prompt.md) adds a SEPARATE
/// due-time reminder chain (scheduleOccurrenceChain / reconcilePatientReminders
/// / cancelOccurrenceReminders) alongside the pre-existing single-shot
/// [scheduleReminder]/[cancelReminder] — that original method is untouched
/// and still does exactly what it did before this phase.
///
/// IMPORTANT architecture note: local notifications can only be scheduled
/// on the device that runs this code. [scheduleReminder] is called from
/// CreateTaskScreen (caregiver-only), so it fires on the CAREGIVER's
/// device. Phase 3's due-time chain is patient-facing (the patient
/// responds Complete/Missed), so [reconcilePatientReminders] must instead
/// be called from the PATIENT's own session (see main.dart and
/// patient_dashboard.dart) — there is no way to schedule "for a different
/// device" without a server/FCM component, which is out of scope.
class NotificationService {
  NotificationService._internal();
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialised = false;

  static const String _channelId = 'task_reminders';
  static const String _channelName = 'Task Reminders';
  static const String _channelDesc = 'Reminders for scheduled tasks.';

  /// Call once at app startup (after Firebase.initializeApp).
  Future<void> init() async {
    if (_initialised) return;

    // We schedule reminders anchored to tz.UTC (see scheduleReminder) rather
    // than relying on device timezone detection: on some devices/emulators
    // that detection silently fails, which desyncs the alarm's wall-clock
    // fields from its declared zone and shifts delivery by the UTC offset.
    tz_data.initializeTimeZones();

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    final iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      // PHASE 3: registers the Complete/Missed action pair as an iOS
      // notification category so occurrence reminders can attach them via
      // DarwinNotificationDetails(categoryIdentifier: _iosActionCategoryId).
      notificationCategories: [
        DarwinNotificationCategory(
          _iosActionCategoryId,
          actions: [
            DarwinNotificationAction.plain(_completeActionId, 'Complete'),
            DarwinNotificationAction.plain(_missedActionId, 'Missed'),
          ],
        ),
      ],
    );
    final initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
      // PHASE 3 (Step 8): handles Complete/Missed taps while the app is
      // backgrounded or fully closed. Must be a top-level function
      // annotated @pragma('vm:entry-point') — see
      // notificationActionBackgroundHandler below.
      onDidReceiveBackgroundNotificationResponse:
          notificationActionBackgroundHandler,
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.max,
        playSound: true,
      ),
    );

    _initialised = true;
  }

  /// UC-05 sub-flow 8c/8d, and PHASE 3 Step 8's fallback path: tapping a
  /// delivered notification (its body, not an action button) shows
  /// [ReminderPopup] — the floating, on-brand response prompt — instead of
  /// the old full-screen TaskDetailScreen navigation. The payload is the
  /// task's Firestore doc id, optionally followed by "|occurrenceDateKey"
  /// for Phase 3 occurrence reminders; either way [_showReminderPopupForTap]
  /// resolves the rest (title/category/relevant occurrence) itself.
  void _onNotificationTap(NotificationResponse response) {
    final String? actionId = response.actionId;
    final String? payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    if (actionId == _completeActionId || actionId == _missedActionId) {
      final parts = payload.split('|');
      if (parts.length < 2) return;
      final String taskId = parts[0];
      final String dateKey = parts[1];
      final String status = actionId == _completeActionId ? 'completed' : 'missed';
      // Fire-and-forget: action buttons have no UI to await against
      // (showsUserInterface: false in _occurrenceDetails).
      _applyOccurrenceResponse(taskId, dateKey, status).then((_) {
        return cancelOccurrenceReminders(
          taskId,
          DateFormat('yyyy-MM-dd').parse(dateKey),
        );
      });
      return;
    }

    // Fire-and-forget: NotificationResponse callbacks are synchronous void.
    _showReminderPopupForTap(payload);
  }

  /// Resolves a plain body-tap [payload] (taskId, or "taskId|dateKey" for
  /// an occurrence-chain reminder) into what [ReminderPopup] needs, using
  /// the same "closest occurrence within +/-2 days" logic TaskDetailScreen
  /// used to run itself. Falls back to the old TaskDetailScreen navigation
  /// if a context isn't ready yet (e.g. a cold tap that just launched the
  /// app), the task/occurrence can't be resolved, or the tapping device
  /// isn't a patient's (see BUGFIX below) — so a tap never silently does
  /// nothing.
  ///
  /// BUGFIX (NOTIFICATION_BUGS.md #2): [ReminderPopup] has no role check of
  /// its own — it always renders live Complete/Missed controls. The
  /// pre-existing single-shot [scheduleReminder] fires on the CAREGIVER's
  /// own device (see class doc comment), and its tap used to land here too,
  /// which meant a caregiver tapping their own reminder got shown
  /// patient-response controls for the patient's task. Now checks the
  /// CURRENT device's logged-in role first and only shows [ReminderPopup]
  /// for a patient; anyone else (caregiver, or role unresolvable) falls
  /// back to the same role-aware [TaskDetailScreen] navigation this
  /// replaced, which only ever shows Complete/Missed to a patient.
  Future<void> _showReminderPopupForTap(String payload) async {
    final parts = payload.split('|');
    final String taskId = parts.first;
    final String? dateKeyFromPayload = parts.length > 1 ? parts[1] : null;

    final firestoreService = FirestoreService();
    final results = await Future.wait([
      firestoreService.getTask(taskId),
      _currentUserIsPatient(),
    ]);
    final Map<String, dynamic>? data = results[0] as Map<String, dynamic>?;
    final bool isPatientDevice = results[1] as bool;
    // BUGFIX: navigatorKey.currentContext is the root Navigator WIDGET'S
    // OWN context — showDialog(context: that) has to search upward from
    // it for an enclosing Navigator, so the route it pushes onto can end
    // up on the wrong (or an effectively empty) Navigator; popping from
    // inside the dialog then hits Navigator.pop's "_history.isNotEmpty"
    // assertion. currentState.overlay.context is a proper DESCENDANT
    // inside the navigator's own subtree, so show/pop always agree on the
    // same Navigator — the standard fix for showing dialogs from code
    // with no local BuildContext of its own (services, callbacks).
    final BuildContext? context = navigatorKey.currentState?.overlay?.context;

    DateTime? occurrenceDate;
    bool isRecurring = false;

    final dueTs = data?['dueDate'];
    if (data != null && dueTs is Timestamp) {
      final endTs = data['endDate'];
      final series = TaskSeries(
        taskId: taskId,
        startDate: dueTs.toDate(),
        recurrenceType: RecurrenceTypeX.fromFirestore(
          data[RecurrenceTypeX.firestoreField] as String?,
        ),
        rule: RecurrenceRule.fromMap(data['recurrenceRule'] as Map<String, dynamic>?),
        endDate: endTs is Timestamp ? endTs.toDate() : null,
      );
      isRecurring = series.recurrenceType != RecurrenceType.none;

      if (dateKeyFromPayload != null) {
        occurrenceDate = DateFormat('yyyy-MM-dd').parse(dateKeyFromPayload);
      } else if (!isRecurring) {
        occurrenceDate = series.startDate;
      } else {
        final DateTime now = DateTime.now();
        final occurrences = getOccurrencesForDateRange(
          series,
          now.subtract(const Duration(days: 2)),
          now.add(const Duration(days: 2)),
        );
        occurrenceDate = closestRelevantOccurrence(occurrences, now);
      }
    }

    if (context == null || data == null || occurrenceDate == null || !isPatientDevice) {
      navigatorKey.currentState?.pushNamed('/taskdetail', arguments: taskId);
      return;
    }

    ReminderPopup.show(
      context,
      taskId: taskId,
      occurrenceDate: occurrenceDate,
      isRecurring: isRecurring,
      title: (data['title'] ?? '') as String,
      category: (data['category'] ?? '') as String,
    );
  }

  /// Whether the CURRENTLY logged-in user on THIS device is a patient —
  /// see [_showReminderPopupForTap]'s doc comment for why this matters.
  /// Defaults to false (falls back to TaskDetailScreen) on any ambiguity —
  /// no session, no user doc, or a read failure — since showing patient
  /// response controls to the wrong role is the worse failure mode.
  Future<bool> _currentUserIsPatient() async {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (!doc.exists) return false;
      final data = doc.data() as Map<String, dynamic>;
      return data['role'] == 'patient';
    } catch (_) {
      return false;
    }
  }

  /// Ask the OS for notification + exact-alarm permissions.
  /// Returns true if notifications are allowed.
  Future<bool> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    final bool? granted = await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();

    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);

    return granted ?? true;
  }

  NotificationDetails _details() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.max,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }

  /// PHASE 3: same channel/importance as [_details], plus the Complete/
  /// Missed action buttons — used only for occurrence due-time/follow-up
  /// reminders, never for the pre-existing single-shot [scheduleReminder].
  NotificationDetails _occurrenceDetails() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.max,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        actions: [
          AndroidNotificationAction(
            _completeActionId,
            'Complete',
            showsUserInterface: false,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            _missedActionId,
            'Missed',
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        categoryIdentifier: _iosActionCategoryId,
      ),
    );
  }

  /// Schedule a reminder for [taskTitle] under [category] at [scheduledTime].
  /// [id] should be stable per task (see [idFor]) so re-saving a task
  /// replaces its previous reminder instead of stacking duplicates.
  ///
  /// [taskId] becomes the notification's payload (UC-05, so a tap can open
  /// that task's detail view).
  ///
  /// UNCHANGED by Phase 3 — this is the pre-existing caregiver-configured
  /// single-shot reminder (`reminderAt`), a separate feature from the new
  /// due-time occurrence chain below.
  Future<void> scheduleReminder({
    required int id,
    required String category,
    required String taskTitle,
    required DateTime scheduledTime,
    required String taskId,
  }) async {
    if (!_initialised) await init();

    // Anchor to UTC using Dart's own (reliable) local->UTC conversion,
    // instead of a device-reported timezone name that may be wrong.
    final tz.TZDateTime when = tz.TZDateTime.from(scheduledTime.toUtc(), tz.UTC);

    if (!when.isAfter(tz.TZDateTime.now(tz.UTC))) {
      if (kDebugMode) print('Skipped: $scheduledTime is in the past.');
      return;
    }

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final bool canExact =
        (await android?.canScheduleExactNotifications()) ?? true;

    await _plugin.zonedSchedule(
      id,
      category,
      taskTitle,
      when,
      _details(),
      androidScheduleMode: canExact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: taskId,
    );

    if (kDebugMode) {
      print(
        'Scheduled notification #$id "$category: $taskTitle" for $when '
        '(exact alarms allowed: $canExact)',
      );
    }
  }

  Future<void> cancelReminder(int id) async {
    await _plugin.cancel(id);
  }

  Future<void> cancelAll() => _plugin.cancelAll();

  // ==========================================================================
  // PHASE 3 — due-time reminder chain (Steps 4-12)
  // ==========================================================================

  /// Schedules (or re-schedules — a stable id just replaces any existing
  /// alarm at that id, so calling this repeatedly never stacks duplicates)
  /// the due-time notification plus up to [maxFollowupReminders] follow-ups
  /// for ONE occurrence, spaced [intervalMinutes] apart (Steps 4-6).
  ///
  /// Any slot whose fire time has already passed is skipped rather than
  /// scheduled late — this single rule is what makes catch-up reconciliation
  /// (Step 11) work with no separate code path: if the app opens partway
  /// through the chain (e.g. due 09:00, opened 09:27, interval 5 min), the
  /// 09:00/09:05/.../09:25 slots are simply skipped and 09:30 onward get
  /// scheduled — same cadence, same original due-time anchor, capped from
  /// the true due time rather than restarting. If the entire chain has
  /// already elapsed, nothing gets scheduled and [occurrence_status.effectiveStatus]
  /// will correctly show the occurrence as missed once past its threshold.
  ///
  /// STOP-CONDITION LIMITATION (Step 4), documented rather than silently
  /// assumed away: flutter_local_notifications has no "check a condition
  /// right before displaying" hook for a plain zonedSchedule alarm, so
  /// "stop reminding once responded" is enforced by PROACTIVELY CANCELLING
  /// every remaining id the instant Complete/Missed is recorded (see
  /// [cancelOccurrenceReminders]), not by each alarm querying Firestore at
  /// fire time. The only residual gap is a narrow race where a response
  /// arrives in the same instant an already-in-flight alarm fires — the
  /// worst case is one stale notification whose own action buttons just
  /// re-write the same (already correct) status, which is harmless.
  ///
  /// COMBINED, per explicit user choice: this OS banner used to be a
  /// separate, plainly-styled notification alongside the in-app
  /// [ReminderPopup] (two different experiences for the same reminder).
  /// On Android it's now the FANCY custom notification instead (see
  /// FancyReminderScheduler.kt/FancyReminderReceiver.kt) — same look as
  /// [ReminderPopup] (category icon, colors, styled Complete/Missed
  /// buttons), sound, and it works even when the app is closed or
  /// backgrounded, which [ReminderPopup] alone can't do (it only fires
  /// while PatientDashboard is actually mounted and running). The plain
  /// flutter_local_notifications-based chain below is kept as the iOS
  /// path — a fully custom RemoteViews layout has no iOS equivalent
  /// reachable from Dart, so iOS still gets the plain version.
  Future<void> scheduleOccurrenceChain({
    required String taskId,
    required String category,
    required String taskTitle,
    required DateTime occurrenceDueTime,
    required int intervalMinutes,
    required String patientId,
  }) async {
    if (!_initialised) await init();
    final String dateKey = occurrenceDateKey(occurrenceDueTime);
    final DateTime now = DateTime.now();

    if (defaultTargetPlatform == TargetPlatform.android) {
      await _scheduleFancyOccurrenceChain(
        taskId: taskId,
        category: category,
        taskTitle: taskTitle,
        occurrenceDueTime: occurrenceDueTime,
        intervalMinutes: intervalMinutes,
        dateKey: dateKey,
        now: now,
      );
      return;
    }

    for (int n = 0; n <= maxFollowupReminders; n++) {
      final DateTime fireAt =
          occurrenceDueTime.add(Duration(minutes: intervalMinutes * n));
      if (!fireAt.isAfter(now)) continue;

      final String key = n == 0 ? '$taskId|$dateKey|due' : '$taskId|$dateKey|followup$n';
      final content = n == 0
          ? _initialOccurrenceContent(category, taskTitle)
          : _followupOccurrenceContent(taskTitle);

      await _scheduleOccurrenceNotification(
        id: idFor(key),
        title: content.title,
        body: content.body,
        when: fireAt,
        payload: '$taskId|$dateKey',
      );
    }
  }

  /// Android path for [scheduleOccurrenceChain]: computes the exact same
  /// "which slots are still in the future" list Dart already owns (see
  /// that method's own doc comment on catch-up reconciliation — this
  /// business logic stays here, not duplicated in Kotlin), then hands the
  /// batch off in ONE MethodChannel call to native AlarmManager scheduling
  /// + the fancy RemoteViews notification (FancyReminderScheduler.kt).
  /// A no-op (nothing scheduled) if the entire chain has already elapsed,
  /// same as the plain path.
  Future<void> _scheduleFancyOccurrenceChain({
    required String taskId,
    required String category,
    required String taskTitle,
    required DateTime occurrenceDueTime,
    required int intervalMinutes,
    required String dateKey,
    required DateTime now,
  }) async {
    final List<int> slotIds = [];
    final List<int> slotFireTimesMillis = [];
    for (int n = 0; n <= maxFollowupReminders; n++) {
      final DateTime fireAt = occurrenceDueTime.add(Duration(minutes: intervalMinutes * n));
      if (!fireAt.isAfter(now)) continue;
      final String key = n == 0 ? '$taskId|$dateKey|due' : '$taskId|$dateKey|followup$n';
      slotIds.add(idFor(key));
      slotFireTimesMillis.add(fireAt.millisecondsSinceEpoch);
    }
    if (slotIds.isEmpty) return;

    try {
      await _fancyReminderChannel.invokeMethod('scheduleFancyReminderChain', {
        'taskId': taskId,
        'dateKey': dateKey,
        'category': category,
        'title': taskTitle,
        'timeLabel': DateFormat('h:mm a').format(occurrenceDueTime),
        'notificationId': idFor('$taskId|$dateKey|due'),
        'slotIds': slotIds,
        'slotFireTimesMillis': slotFireTimesMillis,
        'allChainIds': occurrenceChainIds(taskId, dateKey),
      });
    } catch (e) {
      if (kDebugMode) print('Fancy reminder scheduling failed: $e');
    }
  }

  Future<void> _scheduleOccurrenceNotification({
    required int id,
    required String title,
    required String body,
    required DateTime when,
    required String payload,
  }) async {
    final tz.TZDateTime scheduled = tz.TZDateTime.from(when.toUtc(), tz.UTC);
    if (!scheduled.isAfter(tz.TZDateTime.now(tz.UTC))) return;

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final bool canExact =
        (await android?.canScheduleExactNotifications()) ?? true;

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      scheduled,
      _occurrenceDetails(),
      androidScheduleMode: canExact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
    );
  }

  /// Cancels every id the chain for one occurrence could possibly be using
  /// (due + all follow-up slots) — called the instant Complete/Missed is
  /// recorded, from either the foreground tap handler, the background
  /// action handler, the in-app TaskDetailScreen/ReminderPopup buttons, or
  /// PatientDashboard's auto-popup. Cancelling an id that was never
  /// scheduled (or already fired) is a harmless no-op — safe to call
  /// unconditionally on both paths below regardless of which one (if
  /// either) actually has something scheduled for this occurrence.
  Future<void> cancelOccurrenceReminders(
    String taskId,
    DateTime occurrenceDate,
  ) async {
    final String dateKey = occurrenceDateKey(occurrenceDate);
    for (final id in occurrenceChainIds(taskId, dateKey)) {
      await _plugin.cancel(id);
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _fancyReminderChannel.invokeMethod('cancelFancyReminderChain', {
          'taskId': taskId,
          'dateKey': dateKey,
        });
      } catch (e) {
        if (kDebugMode) print('Fancy reminder cancel failed: $e');
      }
    }
  }

  /// PHASE 3 (Steps 9-11): run whenever the PATIENT's own app starts or
  /// resumes (main.dart on login-as-patient, and PatientDashboard's
  /// initState) — see the class doc comment for why this must run on the
  /// patient's device, not the caregiver's.
  ///
  /// One-shot pass (a `.get()`, not a live stream): expands every one of
  /// the patient's tasks into occurrences over the next 7 days (Step 9 —
  /// bounds the number of scheduled alarms rather than scheduling
  /// unboundedly far ahead; a daily task in this window is at most
  /// 7 x (1 + maxFollowupReminders) = 91 alarms, comfortably inside what
  /// Android's AlarmManager handles per app), and for each occurrence
  /// still pending, (re)schedules its chain via [scheduleOccurrenceChain]
  /// — which itself is what makes this safe to call on every app open
  /// without duplicating alarms.
  Future<void> reconcilePatientReminders(String patientId) async {
    if (!_initialised) await init();
    final firestoreService = FirestoreService();
    final snapshot = await firestoreService.firestore
        .collection('tasks')
        .where('patientId', isEqualTo: patientId)
        .get();

    final DateTime now = DateTime.now();
    final DateTime windowEnd = now.add(const Duration(days: 7));

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final dueTs = data['dueDate'];
      if (dueTs is! Timestamp) continue;

      final series = TaskSeries.fromDoc(doc);
      final occurrences = getOccurrencesForDateRange(series, now, windowEnd);
      if (occurrences.isEmpty) continue;

      final int intervalMinutes = firestoreService.reminderIntervalMinutesOf(data);
      final String category = (data['category'] ?? '') as String;
      final String title = (data['title'] ?? '') as String;
      final bool isRecurring = series.recurrenceType != RecurrenceType.none;

      for (final occurrenceDate in occurrences) {
        final String status = isRecurring
            ? await firestoreService.getOccurrenceStatus(doc.id, occurrenceDate)
            : (data['status'] ?? 'pending') as String;
        if (status != 'pending') continue;

        await scheduleOccurrenceChain(
          taskId: doc.id,
          category: category,
          taskTitle: title,
          occurrenceDueTime: occurrenceDate,
          intervalMinutes: intervalMinutes,
          patientId: patientId,
        );
      }
    }
  }

  /// Fires a notification immediately. Use this to verify permissions and
  /// the notification channel work, independent of alarm scheduling.
  Future<void> showTestNotification() async {
    if (!_initialised) await init();
    await _plugin.show(999999, 'Test', 'This is a test notification', _details());
    if (kDebugMode) print('showTestNotification: show() call completed.');
  }

  /// Dumps permission + pending-alarm state to the console for debugging.
  Future<void> printDebugStatus() async {
    if (!_initialised) await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final bool? notificationsEnabled = await android?.areNotificationsEnabled();
    final bool? canExact = await android?.canScheduleExactNotifications();
    final pending = await _plugin.pendingNotificationRequests();
    print('==== Notification debug status ====');
    print('notifications enabled : $notificationsEnabled');
    print('can schedule exact    : $canExact');
    print('pending scheduled     : ${pending.length}');
    for (final p in pending) {
      print('   #${p.id}  ${p.title}  (${p.body})');
    }
    print('====================================');
  }

  /// Stable positive 32-bit int id from any string key (e.g. a Firestore doc id).
  static int idFor(String key) => key.hashCode & 0x7fffffff;
}

/// Step 7: patient-friendly, non-alarming wording — no deficit-focused
/// language. The initial due-time notification names the task; follow-ups
/// use a gentler generic nudge instead of repeating "you haven't done X"
/// every few minutes.
class _ReminderContent {
  final String title;
  final String body;
  const _ReminderContent(this.title, this.body);
}

_ReminderContent _initialOccurrenceContent(String category, String taskTitle) {
  final String body = category.isNotEmpty ? '$category: $taskTitle' : taskTitle;
  return _ReminderContent('MindCare Reminder', body);
}

_ReminderContent _followupOccurrenceContent(String taskTitle) {
  return _ReminderContent('MindCare Reminder', 'Please check your task: $taskTitle');
}

/// Every local-notification id one occurrence's chain could be using
/// (the due-time one plus every follow-up slot) — a pure, stateless
/// function so both the in-isolate foreground handler and the background
/// isolate handler compute the exact same ids without sharing any state.
List<int> occurrenceChainIds(String taskId, String dateKey) {
  final ids = <int>[NotificationService.idFor('$taskId|$dateKey|due')];
  for (int n = 1; n <= maxFollowupReminders; n++) {
    ids.add(NotificationService.idFor('$taskId|$dateKey|followup$n'));
  }
  return ids;
}

/// Writes the patient's response to the right place: the legacy top-level
/// `status` field for a plain single task (unchanged pre-Phase-3
/// behaviour), or the per-occurrence subcollection for a recurring one
/// (Step 3). Shared by the foreground and background action handlers.
Future<void> _applyOccurrenceResponse(
  String taskId,
  String dateKey,
  String status,
) async {
  final firestoreService = FirestoreService();
  final taskData = await firestoreService.getTask(taskId);
  if (taskData == null) return;

  final RecurrenceType type = RecurrenceTypeX.fromFirestore(
    taskData[RecurrenceTypeX.firestoreField] as String?,
  );

  if (type == RecurrenceType.none) {
    await firestoreService.updateTaskStatus(taskId, status);
  } else {
    final DateTime occurrenceDate = DateFormat('yyyy-MM-dd').parse(dateKey);
    await firestoreService.setOccurrenceStatus(taskId, occurrenceDate, status);
  }

  // A patient manually responding to a reminder (Complete OR Missed) is
  // genuine activity — feed the risk inactivity signal. Only patient-device
  // occurrence chains reach here, so taskData['patientId'] is the responder.
  // (This is a MANUAL response; auto-missed sweeps never come through here.)
  final String patientId = (taskData['patientId'] ?? '') as String;
  if (patientId.isNotEmpty) {
    await firestoreService.touchLastActive(patientId);
  }
}

/// PHASE 3 (Step 8): background isolate entry point for the Complete/
/// Missed action buttons, used when they're tapped while the app is
/// backgrounded or fully closed. Must be a top-level function annotated
/// @pragma('vm:entry-point') per flutter_local_notifications v18's
/// background-callback requirement — it runs in a SEPARATE isolate with no
/// access to the NotificationService singleton, any BuildContext, or the
/// main isolate's Firebase/plugin instances, so it re-initializes just
/// enough (Firebase, and its own throwaway FlutterLocalNotificationsPlugin
/// for cancellation) to do its job and nothing else.
@pragma('vm:entry-point')
void notificationActionBackgroundHandler(NotificationResponse response) {
  _handleBackgroundAction(response);
}

Future<void> _handleBackgroundAction(NotificationResponse response) async {
  final String? actionId = response.actionId;
  if (actionId != _completeActionId && actionId != _missedActionId) {
    return; // a plain body tap in the background has no UI to open here
  }
  final String? payload = response.payload;
  if (payload == null || !payload.contains('|')) return;
  final parts = payload.split('|');
  final String taskId = parts[0];
  final String dateKey = parts[1];
  final String status = actionId == _completeActionId ? 'completed' : 'missed';

  WidgetsFlutterBinding.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }

  await _applyOccurrenceResponse(taskId, dateKey, status);

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  for (final id in occurrenceChainIds(taskId, dateKey)) {
    await plugin.cancel(id);
  }
}
