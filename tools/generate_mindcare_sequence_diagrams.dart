import 'dart:io';

class Participant {
  final String name;
  final String kind;
  const Participant(this.name, this.kind);
}

class Message {
  final int from;
  final int to;
  final String label;
  final bool reply;
  const Message(this.from, this.to, this.label, {this.reply = false});
}

class DiagramSpec {
  final String id;
  final String name;
  final String coverage;
  final List<Participant> participants;
  final List<Message> messages;
  final List<String> notes;

  const DiagramSpec({
    required this.id,
    required this.name,
    required this.coverage,
    required this.participants,
    required this.messages,
    this.notes = const [],
  });
}

String esc(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String participantStyle(String kind) {
  const colours = {
    'actor': ('#FF7A59', '#B85450'),
    'screen': ('#E1D5E7', '#9673A6'),
    'service': ('#DAE8FC', '#6C8EBF'),
    'firebase': ('#FFF2CC', '#D6B656'),
    'platform': ('#D5E8D4', '#82B366'),
    'model': ('#F8CECC', '#B85450'),
  };
  final colour = colours[kind] ?? colours['service']!;
  return 'rounded=1;whiteSpace=wrap;html=1;fontStyle=1;fontSize=12;'
      'fillColor=${colour.$1};strokeColor=${colour.$2};align=center;verticalAlign=middle;';
}

String buildPage(DiagramSpec spec) {
  const double startX = 55;
  const double gap = 190;
  const double headerY = 62;
  const double headerW = 150;
  const double headerH = 46;
  const double firstMessageY = 142;
  const double messageGap = 39;

  final maxMessageY = firstMessageY + (spec.messages.length - 1) * messageGap;
  final noteStartY = maxMessageY + 50;
  final pageHeight = noteStartY + spec.notes.length * 48 + 90;
  final pageWidth = startX * 2 + gap * (spec.participants.length - 1) + headerW;
  final lifeEndY = noteStartY - 18;

  final b = StringBuffer()
    ..writeln('<diagram id="${esc(spec.id)}" name="${esc(spec.name)}">')
    ..writeln(
      '<mxGraphModel dx="1422" dy="794" grid="1" gridSize="10" guides="1" '
      'tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" '
      'pageWidth="${pageWidth.ceil()}" pageHeight="${pageHeight.ceil()}" math="0" shadow="0">',
    )
    ..writeln('<root>')
    ..writeln('<mxCell id="0"/>')
    ..writeln('<mxCell id="1" parent="0"/>')
    ..writeln(
      '<mxCell id="title" value="${esc(spec.name)}" '
      'style="text;html=1;align=left;verticalAlign=middle;whiteSpace=wrap;rounded=0;'
      'fontSize=22;fontStyle=1;fontColor=#2B1747;" vertex="1" parent="1">'
      '<mxGeometry x="30" y="15" width="${pageWidth - 60}" height="32" as="geometry"/>'
      '</mxCell>',
    )
    ..writeln(
      '<mxCell id="coverage" value="FR coverage: ${esc(spec.coverage)}" '
      'style="text;html=1;align=right;verticalAlign=middle;whiteSpace=wrap;rounded=0;'
      'fontSize=11;fontColor=#666666;" vertex="1" parent="1">'
      '<mxGeometry x="${pageWidth - 390}" y="18" width="350" height="24" as="geometry"/>'
      '</mxCell>',
    );

  for (var i = 0; i < spec.participants.length; i++) {
    final x = startX + i * gap;
    final centreX = x + headerW / 2;
    final participant = spec.participants[i];
    b
      ..writeln(
        '<mxCell id="p$i" value="${esc(participant.name)}" '
        'style="${participantStyle(participant.kind)}" vertex="1" parent="1">'
        '<mxGeometry x="$x" y="$headerY" width="$headerW" height="$headerH" as="geometry"/>'
        '</mxCell>',
      )
      ..writeln(
        '<mxCell id="life$i" value="" style="endArrow=none;startArrow=none;dashed=1;'
        'dashPattern=4 4;strokeColor=#777777;html=1;" edge="1" parent="1">'
        '<mxGeometry relative="1" as="geometry">'
        '<mxPoint x="$centreX" y="${headerY + headerH}" as="sourcePoint"/>'
        '<mxPoint x="$centreX" y="$lifeEndY" as="targetPoint"/>'
        '</mxGeometry></mxCell>',
      );
  }

  for (var i = 0; i < spec.messages.length; i++) {
    final message = spec.messages[i];
    final y = firstMessageY + i * messageGap;
    final sourceX = startX + message.from * gap + headerW / 2;
    final targetX = startX + message.to * gap + headerW / 2;
    final style = message.reply
        ? 'endArrow=open;endFill=0;dashed=1;strokeWidth=1.2;strokeColor=#555555;html=1;'
        : 'endArrow=block;endFill=1;strokeWidth=1.4;strokeColor=#2B1747;html=1;';
    b.writeln(
      '<mxCell id="m$i" value="${i + 1}. ${esc(message.label)}" '
      'style="$style" edge="1" parent="1">'
      '<mxGeometry relative="1" as="geometry">'
      '<mxPoint x="$sourceX" y="$y" as="sourcePoint"/>'
      '<mxPoint x="$targetX" y="$y" as="targetPoint"/>'
      '</mxGeometry></mxCell>',
    );
  }

  for (var i = 0; i < spec.notes.length; i++) {
    final y = noteStartY + i * 48;
    b.writeln(
      '<mxCell id="note$i" value="${esc(spec.notes[i])}" '
      'style="shape=note;whiteSpace=wrap;html=1;backgroundOutline=1;size=14;'
      'fillColor=#FFF2CC;strokeColor=#D6B656;fontSize=11;align=left;spacingLeft=8;" '
      'vertex="1" parent="1">'
      '<mxGeometry x="55" y="$y" width="${pageWidth - 110}" height="38" as="geometry"/>'
      '</mxCell>',
    );
  }

  b
    ..writeln('</root>')
    ..writeln('</mxGraphModel>')
    ..writeln('</diagram>');
  return b.toString();
}

void main() {
  const diagrams = <DiagramSpec>[
    DiagramSpec(
      id: 'login-role',
      name: 'SD01 — Login and Role-Based Navigation',
      coverage: 'FR01, FR02, FR04, FR08, FR09',
      participants: [
        Participant('Caregiver / Patient', 'actor'),
        Participant('LoginScreen', 'screen'),
        Participant('AuthService', 'service'),
        Participant('Firebase Authentication', 'firebase'),
        Participant('Firestore users', 'firebase'),
        Participant('StreakService', 'service'),
        Participant('Role Dashboard', 'screen'),
      ],
      messages: [
        Message(0, 1, 'Enter email/password and tap Sign In'),
        Message(1, 2, 'loginUser(email, password)'),
        Message(2, 3, 'signInWithEmailAndPassword()'),
        Message(3, 2, 'Return authenticated UID', reply: true),
        Message(2, 4, 'Read users/{uid} profile'),
        Message(4, 2, 'Return role and profile', reply: true),
        Message(2, 5, '[patient] checkAndUpdateStreak(uid)'),
        Message(5, 4, 'Read and conditionally update streak/points'),
        Message(4, 5, 'Return current streak data', reply: true),
        Message(5, 2, 'Return StreakResult', reply: true),
        Message(2, 1, 'Return AuthResult(profile)', reply: true),
        Message(1, 6, '[caregiver] open HomeScreen'),
        Message(1, 6, '[patient] open PatientDashboard'),
        Message(2, 1, '[failure] return validation/authentication error', reply: true),
        Message(1, 0, 'Display clear error message', reply: true),
      ],
      notes: [
        'Role routing is based on users/{uid}.role. Only patient login invokes the daily streak check.',
        'AuthGate separately handles remembered sessions at cold start and routes to the same role-specific dashboard.',
      ],
    ),
    DiagramSpec(
      id: 'create-patient',
      name: 'SD02 — Caregiver Creates a Patient Account',
      coverage: 'FR13, FR14, FR15, FR16, FR17',
      participants: [
        Participant('Caregiver', 'actor'),
        Participant('AddPatientScreen', 'screen'),
        Participant('PatientAccountService', 'service'),
        Participant('Secondary FirebaseAuth', 'firebase'),
        Participant('Firebase Patient User', 'firebase'),
        Participant('Firestore users', 'firebase'),
        Participant('Manage Patient', 'screen'),
      ],
      messages: [
        Message(0, 1, 'Enter name, email, password, stage and type'),
        Message(1, 1, 'Validate required fields and password'),
        Message(1, 2, 'createPatientAccount(caregiverId, profile)'),
        Message(2, 3, 'Create/reuse secondary Firebase app'),
        Message(2, 3, 'createUserWithEmailAndPassword()'),
        Message(3, 2, 'Return patient credential and UID', reply: true),
        Message(2, 4, 'updateDisplayName(patient name)'),
        Message(2, 3, 'Sign out secondary authentication session'),
        Message(2, 5, 'Create users/{patientUid} with caregiverId, role, stage and type'),
        Message(5, 2, 'Confirm patient profile saved', reply: true),
        Message(2, 1, 'Return patient UID', reply: true),
        Message(1, 0, 'Show account-created dialog and credentials', reply: true),
        Message(1, 6, 'Return to patient management list'),
        Message(3, 2, '[failure] FirebaseAuthException', reply: true),
        Message(2, 1, 'Return friendly creation error', reply: true),
      ],
      notes: [
        'The secondary Firebase app prevents patient-account creation from signing out the caregiver.',
        'Editing, unlinking and password reset reuse the same patient profile link; unlinking clears caregiverId without deleting history.',
      ],
    ),
    DiagramSpec(
      id: 'task-recurrence',
      name: 'SD03 — Create Task/Medication, Recurrence and Reminder Schedule',
      coverage: 'FR18, FR19, FR20, FR24, FR25, FR26',
      participants: [
        Participant('Caregiver', 'actor'),
        Participant('CreateTaskScreen', 'screen'),
        Participant('Task Recurrence Model', 'model'),
        Participant('FirestoreService', 'service'),
        Participant('Firestore tasks', 'firebase'),
        Participant('NotificationService', 'service'),
        Participant('Android / Local Scheduler', 'platform'),
      ],
      messages: [
        Message(0, 1, 'Enter patient, category, dosage, due time and reminder interval'),
        Message(0, 1, 'Choose none/daily/weekly/monthly/yearly/custom recurrence'),
        Message(1, 1, 'Validate task, medication and recurrence fields'),
        Message(1, 2, 'Build RecurrenceRule and optional endDate'),
        Message(2, 1, 'Return normalized recurrence data', reply: true),
        Message(1, 3, '[new] addTask(...) / [edit] updateTask(...)'),
        Message(3, 4, 'Write one task-series document with status pending'),
        Message(4, 3, 'Return taskId / update confirmation', reply: true),
        Message(3, 1, 'Return saved taskId', reply: true),
        Message(1, 5, '[reminderAt] scheduleReminder(taskId, time)'),
        Message(5, 6, 'Schedule exact/inexact local notification'),
        Message(1, 5, '[removed reminder] cancelReminder(taskId)'),
        Message(1, 0, 'Show success and return to dashboard', reply: true),
        Message(5, 4, '[patient opens app] query assigned tasks'),
        Message(5, 2, 'Expand occurrences for the next 7 days'),
        Message(5, 6, 'Schedule pending occurrence reminder chains'),
      ],
      notes: [
        'One recurring task is stored as one task-series document. Per-date status is stored later under tasks/{taskId}/occurrences/{yyyy-MM-dd}.',
        'Deleting a task removes the task document and cancels its associated reminder identifier.',
      ],
    ),
    DiagramSpec(
      id: 'notification-response',
      name: 'SD04 — Reminder Notification and Patient Response',
      coverage: 'FR20, FR21, FR22, FR23, FR28',
      participants: [
        Participant('Android Alarm / Notification', 'platform'),
        Participant('Patient', 'actor'),
        Participant('NotificationService', 'service'),
        Participant('ReminderPopup / Background Handler', 'screen'),
        Participant('FirestoreService', 'service'),
        Participant('Firestore task/occurrence', 'firebase'),
        Participant('Patient/Caregiver Dashboard', 'screen'),
      ],
      messages: [
        Message(0, 1, 'Show styled reminder with sound and Complete/Missed actions'),
        Message(1, 2, '[body tap] deliver notification payload'),
        Message(2, 4, 'Read task and current user role'),
        Message(4, 2, 'Return task, recurrence and role data', reply: true),
        Message(2, 3, '[patient] show ReminderPopup'),
        Message(1, 3, 'Tap Complete or Missed'),
        Message(3, 4, 'Update one-off status or occurrence-specific status'),
        Message(4, 5, 'Persist completed/missed and updatedAt'),
        Message(3, 4, 'touchLastActive(patientId)'),
        Message(3, 2, 'cancelOccurrenceReminders(taskId, date)'),
        Message(2, 0, 'Cancel due/follow-up alarm IDs'),
        Message(5, 6, 'Live Firestore stream emits new status'),
        Message(6, 1, 'Refresh card and progress immediately', reply: true),
        Message(1, 3, '[action button while closed] invoke background handler'),
        Message(3, 4, 'Initialize Firebase and apply the same response'),
        Message(6, 5, '[no response after chain] persist effective missed status'),
      ],
      notes: [
        'A completed occurrence cannot be unticked by the patient. A manual Missed response still counts as patient activity; automatic missed processing does not.',
        'Foreground popup and background notification actions converge on the same Firestore status model and cancel the remaining reminder chain.',
      ],
    ),
    DiagramSpec(
      id: 'cognitive-adaptation',
      name: 'SD05 — Cognitive Game Session and Adaptive Difficulty',
      coverage: 'FR05, FR06, FR07, FR10',
      participants: [
        Participant('Patient', 'actor'),
        Participant('CognitiveExerciseScreen', 'screen'),
        Participant('Firestore patient profile', 'firebase'),
        Participant('Selected Game Screen', 'screen'),
        Participant('AdaptiveDifficultyService', 'service'),
        Participant('Firestore sessions/state/history', 'firebase'),
        Participant('FirestoreService / Points', 'service'),
        Participant('GameStatisticScreen', 'screen'),
      ],
      messages: [
        Message(0, 1, 'Open Cognitive Games'),
        Message(1, 2, 'Read dementiaStage and dementiaType'),
        Message(2, 1, 'Return profile', reply: true),
        Message(1, 1, 'Select AD/VaD + early/middle game set'),
        Message(0, 1, 'Choose an available game'),
        Message(1, 3, 'Open selected game screen'),
        Message(3, 4, 'getState(patientId, gameId)'),
        Message(4, 5, 'Read per-game difficulty state'),
        Message(5, 4, 'Return level/source/frozen', reply: true),
        Message(3, 0, 'Run error-reducing game with hints and feedback', reply: true),
        Message(3, 6, 'awardPoints(patientId, earnedPoints)'),
        Message(3, 4, 'recordSessionAndAdapt(metrics, hints, duration)'),
        Message(4, 5, 'Write session and touch lastActiveAt'),
        Message(4, 5, 'Transaction: check adaptationApplied and current state'),
        Message(4, 4, 'Apply demote / retain / promote rules'),
        Message(4, 5, '[level changed] update state and write difficultyHistory'),
        Message(5, 4, 'Commit and return resulting level', reply: true),
        Message(7, 5, 'Watch state, recent sessions and audit history'),
      ],
      notes: [
        'Difficulty decisions are per game. Accuracy is a struggle signal (first-attempt rate or tap efficiency), not literal completion percentage.',
        'Caregivers can override/freeze a level with a reason and later resume automatic adjustment; every level change is auditable.',
      ],
    ),
    DiagramSpec(
      id: 'monitoring-risk',
      name: 'SD06 — Caregiver Monitoring, Analytics and Risk Evaluation',
      coverage: 'FR27, FR28, FR31, FR32, FR33',
      participants: [
        Participant('Caregiver', 'actor'),
        Participant('Performance/Home Screen', 'screen'),
        Participant('PerformanceAnalyticsService', 'service'),
        Participant('RiskService', 'service'),
        Participant('Recurrence/Status Logic', 'model'),
        Participant('Firestore', 'firebase'),
        Participant('Charts and RiskBadge', 'screen'),
      ],
      messages: [
        Message(0, 1, 'Select patient and reporting period'),
        Message(1, 2, 'loadSnapshot(patientId, period)'),
        Message(2, 5, 'Query gameSessions, tasks and user streak data'),
        Message(5, 2, 'Return source records', reply: true),
        Message(2, 4, 'Expand recurring task occurrences and effective statuses'),
        Message(2, 2, 'Calculate KPIs, trends, rankings and categories'),
        Message(2, 1, 'Return PerformanceSnapshot', reply: true),
        Message(1, 3, 'evaluateAndCache(patientId)'),
        Message(3, 5, 'Query patient tasks and recent game sessions'),
        Message(3, 4, 'Get previous 3 due occurrences per task'),
        Message(3, 3, 'Evaluate consecutive misses'),
        Message(3, 3, 'Evaluate comparable score decline (game/level/version buckets)'),
        Message(3, 5, 'Read lastActiveAt, last game and last login'),
        Message(3, 3, 'Map 0–1 signals=none, 2=monitor, 3=atRisk'),
        Message(3, 5, 'Transaction: cache risk and audit level transition'),
        Message(3, 1, 'Return RiskAssessment', reply: true),
        Message(1, 6, 'Render charts, patient details and amber/red badge'),
      ],
      notes: [
        'Risk information is caregiver-only. Amber means 2 of 3 signals; red requires all 3 simultaneously.',
        'Task history and dashboard views use occurrence-specific status so recurring-series status is not confused with an individual date.',
      ],
    ),
    DiagramSpec(
      id: 'streak-rewards',
      name: 'SD07 — Daily Streak, Points and Reward-Game Unlocking',
      coverage: 'FR08, FR09, FR10, FR11, FR12',
      participants: [
        Participant('Patient', 'actor'),
        Participant('Login / PatientDashboard', 'screen'),
        Participant('StreakService', 'service'),
        Participant('Firestore users', 'firebase'),
        Participant('Task/Game Completion', 'screen'),
        Participant('Cognitive Game Hub', 'screen'),
        Participant('RewardGameScreen', 'screen'),
        Participant('External Web Game', 'platform'),
      ],
      messages: [
        Message(0, 1, 'Login or reopen patient dashboard'),
        Message(1, 2, 'checkAndUpdateStreak(uid)'),
        Message(2, 3, 'Read lastLoginDate, streak and points'),
        Message(3, 2, 'Return StreakData', reply: true),
        Message(2, 2, '[same day] no duplicate award'),
        Message(2, 2, '[yesterday] increment / [gap] reset to day 1'),
        Message(2, 2, 'Calculate repeating day-1-to-7 reward'),
        Message(2, 3, 'Update streakPoints/currentStreak/longestStreak/login date'),
        Message(2, 1, 'Return award result', reply: true),
        Message(4, 3, 'Task/game completion adds points'),
        Message(5, 3, 'Watch total points stream'),
        Message(3, 5, 'Emit current total points', reply: true),
        Message(5, 5, 'Compare points with 30/50/80/120 thresholds'),
        Message(0, 5, 'Tap an unlocked Just for Fun game'),
        Message(5, 6, 'Open selected RewardGame configuration'),
        Message(6, 7, 'Load URL; try fallback URL after failure/timeout'),
        Message(7, 6, 'Display external game or friendly unavailable state', reply: true),
      ],
      notes: [
        'Streak points are awarded at most once per calendar day; missing a full day resets the current streak.',
        'Reward games are engagement features, not evidence-based cognitive exercises, and remain visually separated in the hub.',
      ],
    ),
  ];

  final output = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<mxfile host="app.diagrams.net" modified="2026-09-02T00:00:00.000Z" '
      'agent="Codex" version="24.7.17" type="device" compressed="false">',
    );
  for (final diagram in diagrams) {
    output.writeln(buildPage(diagram));
  }
  output.writeln('</mxfile>');

  File('MINDCARE_SEQUENCE_DIAGRAMS.drawio').writeAsStringSync(output.toString());
  stdout.writeln('Generated MINDCARE_SEQUENCE_DIAGRAMS.drawio (${diagrams.length} pages).');
}
