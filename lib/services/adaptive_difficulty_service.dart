import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:testproject/models/game_session.dart';

/// PART 1 — Adaptive Difficulty Engine
/// (adaptive_difficulty_and_risk_indicator_prompt.md).
///
/// Implements the dynamic difficulty adjustment recommended by Bouchard, B.,
/// Imbeault, F., Bouzouane, A., & Menelas, B.-A. J. (2012), "Developing
/// serious games specifically adapted to people suffering from Alzheimer,"
/// SGDA 2012, LNCS 7528 — a rule-based state machine adjusts a patient's
/// per-game difficulty level from their own recent session performance,
/// instead of a caregiver having to manually re-tier every game by feel.
/// The level→parameter design each game applies (item count / time
/// allowance / cue strength / attempts) follows Ortega Morán et al. (2024,
/// JMIR Aging 7:e41437) — see each game file's own `_levelConfig`-style
/// mapping.
///
/// ONE service, called by every game (recordSessionAndAdapt) and by
/// GameStatisticScreen (getState/watchState/setCaregiverOverride/resumeAuto/
/// watchRecentSessions/watchHistory) — no rule logic duplicated in UI code.
class AdaptiveDifficultyService {
  AdaptiveDifficultyService._internal();
  static final AdaptiveDifficultyService _instance = AdaptiveDifficultyService._internal();
  factory AdaptiveDifficultyService() => _instance;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _stateDoc(String patientId, String gameId) => _db
      .collection('users')
      .doc(patientId)
      .collection('difficultyState')
      .doc(gameId);

  /// Current level+state for one (patient, game) — level 1 (easiest) for a
  /// patient with no state doc yet (see [DifficultyState.initial]).
  Future<DifficultyState> getState(String patientId, String gameId) async {
    final doc = await _stateDoc(patientId, gameId).get();
    return DifficultyState.fromMap(doc.data());
  }

  Stream<DifficultyState> watchState(String patientId, String gameId) {
    return _stateDoc(patientId, gameId)
        .snapshots()
        .map((doc) => DifficultyState.fromMap(doc.data()));
  }

  /// One-time write used ONLY by a game's own first-ever read, to migrate
  /// an existing caregiver-set [GameDifficultyTier] into this game's
  /// initial per-game level (foundations→1, standard→2, challenge→3) —
  /// see game_session.dart's [DifficultyState] doc comment. A no-op (via
  /// `SetOptions(merge: true)` semantics at the call site) if a
  /// difficultyState doc already exists for this game; this only ever
  /// establishes the STARTING point once.
  Future<void> migrateInitialLevelIfAbsent(
    String patientId,
    String gameId,
    int migratedLevel,
  ) async {
    final ref = _stateDoc(patientId, gameId);
    final doc = await ref.get();
    if (doc.exists) return;
    await ref.set({
      'level': migratedLevel,
      'source': 'auto',
      'frozen': false,
      'version': 0,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// STEP 1.3's deep-CRUD write flow:
  ///
  /// 1. Write the session doc with a STABLE, client-generated [sessionId]
  ///    (`.set()`, not `.add()`) — a double-submit (e.g. a double-tap on
  ///    "finish") overwrites the same doc instead of creating a duplicate.
  /// 2. Query this game's last 3 sessions for this patient, ORDERED BY
  ///    completedAt desc — done OUTSIDE the transaction below because
  ///    Firestore transactions can only re-read specific document
  ///    references they already hold; they cannot run a `.where()`/
  ///    `.orderBy()` query. Session docs are immutable once written (a
  ///    session's own accuracy/hints never change after the fact), so
  ///    there's no staleness risk in reading this list before the
  ///    transaction — the only thing that NEEDS to be read fresh, atomically,
  ///    is the CURRENT level state is compared against.
  /// 3. Run a Firestore transaction on the difficultyState doc: read it
  ///    fresh INSIDE the transaction, and make the promote/demote decision
  ///    using THAT fresh level (not any level captured before the
  ///    transaction started). Firestore's own transaction semantics
  ///    already give the "abort and retry the whole callback" behaviour
  ///    the prompt calls for if this document changes underneath the
  ///    transaction before commit (e.g. two of a patient's sessions
  ///    finishing in the same instant, each trying to adjust the same
  ///    game's level) — because the decision is computed entirely from
  ///    data read INSIDE the transaction body, a retry re-runs the
  ///    decision against the now-current state rather than blindly
  ///    reapplying a stale one. The `version` field is the visible audit
  ///    counter for this (incremented on every write), not itself the
  ///    concurrency mechanism.
  /// 4. If the level changed, the difficultyHistory record is written
  ///    inside the SAME transaction as the state update, so a state change
  ///    and its audit record can never happen one without the other.
  /// 5. Returns the (possibly new) level so the caller can show the right
  ///    level next session.
  Future<int> recordSessionAndAdapt({
    required String sessionId,
    required String patientId,
    required String gameId,
    required String gameSet,
    required int difficultyLevel,
    required int totalItems,
    required int correctItems,
    required int hintsUsed,
    required int durationSeconds,
    // What `accuracy` measures for THIS game (see GameMetricType). Defaults
    // to tap-efficiency — the 9 tap-based games inherit it; only the 4
    // first-attempt games (name_face/familiar_sound/word_picture_pairing/
    // picture_recognition) pass firstAttempt explicitly. Stored so the risk
    // score-drop signal never compares incompatible metrics.
    String metricType = GameMetricType.tapEfficiency,
  }) async {
    final session = GameSession(
      sessionId: sessionId,
      patientId: patientId,
      gameId: gameId,
      gameSet: gameSet,
      difficultyLevel: difficultyLevel,
      totalItems: totalItems,
      correctItems: correctItems,
      hintsUsed: hintsUsed,
      durationSeconds: durationSeconds,
      completedAt: DateTime.now(), // overwritten by FieldValue.serverTimestamp() in toMap()
      metricType: metricType,
      metricVersion: kCurrentMetricVersion,
    );
    await _db.collection('gameSessions').doc(sessionId).set(session.toMap());

    // Finishing a game is patient activity — feed the risk inactivity signal
    // here (one place covers all 13 games) rather than in each game file.
    // Fire-and-forget merge; never let it block the adaptation flow.
    _db.collection('users').doc(patientId).set(
      {'lastActiveAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );

    final recentSnap = await _db
        .collection('gameSessions')
        .where('patientId', isEqualTo: patientId)
        .where('gameId', isEqualTo: gameId)
        .orderBy('completedAt', descending: true)
        .limit(3)
        .get();
    final List<Map<String, dynamic>> recentDesc =
        recentSnap.docs.map((d) => d.data()).toList();

    final docRef = _stateDoc(patientId, gameId);
    final sessionRef = _db.collection('gameSessions').doc(sessionId);
    int resultLevel = difficultyLevel;

    await _db.runTransaction((tx) async {
      // ALL reads before any writes (Firestore transaction rule).
      final sessionSnap = await tx.get(sessionRef);
      final stateSnap = await tx.get(docRef);
      final DifficultyState state = DifficultyState.fromMap(stateSnap.data());
      resultLevel = state.level;

      // IDEMPOTENCY (adaptationApplied on the SESSION doc — not a single
      // lastAdaptedSessionId on the state doc, which would only block the
      // most recent session and let an older, replayed session adapt again):
      // never run adaptation twice for the same session, so a double-tapped
      // "finish", a retry after the save-failed SnackBar, or a replayed
      // offline write can't demote/promote a second time off one round.
      if (sessionSnap.data()?['adaptationApplied'] == true) return;

      // FROZEN: a caregiver override is in effect — make NO automatic change,
      // but still mark this session applied so a later replay can't act on it
      // after the override is lifted.
      if (state.frozen) {
        tx.set(sessionRef, {'adaptationApplied': true}, SetOptions(merge: true));
        return;
      }

      // Mark applied on EVERY outcome (change or no-change), so a replay of a
      // "no change" session can't get a second chance to change something
      // once the level has since moved on.
      tx.set(sessionRef, {'adaptationApplied': true}, SetOptions(merge: true));

      final _Decision? decision = _decide(state.level, recentDesc);
      if (decision == null) return;

      resultLevel = decision.toLevel;

      tx.set(
        docRef,
        {
          'level': decision.toLevel,
          'source': 'auto',
          'frozen': false,
          'version': state.version + 1,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      tx.set(_db.collection('difficultyHistory').doc(), {
        'patientId': patientId,
        'gameId': gameId,
        'fromLevel': state.level,
        'toLevel': decision.toLevel,
        'reason': decision.reason,
        'triggeringStats': decision.triggeringStats,
        'overrideReason': null,
        'changedBy': patientId,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });

    return resultLevel;
  }

  /// PROMOTE/DEMOTE rules (Section 1.2) — demotion is checked FIRST, per
  /// the prompt's explicit safety rule: err toward easier for dementia
  /// patients rather than toward challenge.
  ///
  /// PROMOTE (level +1, cap 3): the last 3 CONSECUTIVE sessions of this
  /// game, all played AT [currentLevel], each with accuracy >= 0.80 AND
  /// hintsUsed <= 1.
  /// DEMOTE (level -1, floor 1): the most recent session has accuracy
  /// < 0.50, OR the last 2 consecutive sessions both have accuracy < 0.60.
  _Decision? _decide(int currentLevel, List<Map<String, dynamic>> recentDesc) {
    if (recentDesc.isEmpty) return null;

    double accuracyOf(Map<String, dynamic> s) => (s['accuracy'] as num?)?.toDouble() ?? 0.0;
    int hintsOf(Map<String, dynamic> s) => (s['hintsUsed'] as num?)?.toInt() ?? 0;
    int levelOf(Map<String, dynamic> s) => (s['difficultyLevel'] as num?)?.toInt() ?? -1;

    final double lastAccuracy = accuracyOf(recentDesc[0]);
    // LEVEL-AWARE DEMOTION: only a session actually PLAYED at the current
    // level can trigger a demotion from it — mirroring the promote branch's
    // own `levelOf(s) == currentLevel` check below. Without this, a single
    // weak session played at level 3 could demote 3→2 and then, on a later
    // evaluation, keep counting toward demoting 2→1 (it's still in the last-3
    // list), cascading the patient down levels off sessions never actually
    // played there. See DESIGN_DECISIONS_IMPLEMENTATION_PLAN.md ★.
    final bool lastAtCurrentLevel = levelOf(recentDesc[0]) == currentLevel;
    if (currentLevel > 1 && lastAtCurrentLevel) {
      if (lastAccuracy < 0.50) {
        return _Decision(
          toLevel: currentLevel - 1,
          reason: 'auto_demote',
          triggeringStats: {'lastAccuracy': lastAccuracy, 'rule': 'most_recent_below_50'},
        );
      }
      if (recentDesc.length >= 2) {
        final double secondAccuracy = accuracyOf(recentDesc[1]);
        final bool secondAtCurrentLevel = levelOf(recentDesc[1]) == currentLevel;
        if (secondAtCurrentLevel && lastAccuracy < 0.60 && secondAccuracy < 0.60) {
          return _Decision(
            toLevel: currentLevel - 1,
            reason: 'auto_demote',
            triggeringStats: {
              'last2Accuracy': [lastAccuracy, secondAccuracy],
              'rule': 'last_2_below_60',
            },
          );
        }
      }
    }

    if (currentLevel < 3 && recentDesc.length >= 3) {
      final last3 = recentDesc.sublist(0, 3);
      final bool qualifies = last3.every(
        (s) => levelOf(s) == currentLevel && accuracyOf(s) >= 0.80 && hintsOf(s) <= 1,
      );
      if (qualifies) {
        return _Decision(
          toLevel: currentLevel + 1,
          reason: 'auto_promote',
          triggeringStats: {
            'last3Accuracy': last3.map(accuracyOf).toList(),
            'last3Hints': last3.map(hintsOf).toList(),
          },
        );
      }
    }

    return null;
  }

  /// Caregiver override (Section 1.5) — [reason] is REQUIRED (the calling
  /// UI must not let an empty reason reach here; enforced again
  /// defensively). Freezes auto-adjustment until [resumeAuto] is called.
  Future<void> setCaregiverOverride({
    required String patientId,
    required String gameId,
    required int level,
    required String caregiverId,
    required String reason,
  }) async {
    final String trimmedReason = reason.trim();
    if (trimmedReason.isEmpty) {
      throw ArgumentError('A reason is required for a caregiver override.');
    }
    final docRef = _stateDoc(patientId, gameId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      final state = DifficultyState.fromMap(snap.data());

      tx.set(
        docRef,
        {
          'level': level,
          'source': 'caregiver',
          'frozen': true,
          'version': state.version + 1,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      tx.set(_db.collection('difficultyHistory').doc(), {
        'patientId': patientId,
        'gameId': gameId,
        'fromLevel': state.level,
        'toLevel': level,
        'reason': 'caregiver_override',
        'triggeringStats': null,
        'overrideReason': trimmedReason,
        'changedBy': caregiverId,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  /// "Resume auto" (Section 1.5) — unfreezes without changing the current
  /// level; auto promote/demote resumes from wherever the level sits now.
  Future<void> resumeAuto({
    required String patientId,
    required String gameId,
    required String caregiverId,
  }) async {
    final docRef = _stateDoc(patientId, gameId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      final state = DifficultyState.fromMap(snap.data());

      tx.set(
        docRef,
        {
          'frozen': false,
          'version': state.version + 1,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      tx.set(_db.collection('difficultyHistory').doc(), {
        'patientId': patientId,
        'gameId': gameId,
        'fromLevel': state.level,
        'toLevel': state.level,
        'reason': 'caregiver_unfreeze',
        'triggeringStats': null,
        'overrideReason': null,
        'changedBy': caregiverId,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Last [limit] sessions for one (patient, game), newest first — feeds
  /// GameStatisticScreen's per-game accuracy trend.
  Stream<List<GameSession>> watchRecentSessions(String patientId, String gameId, {int limit = 10}) {
    return _db
        .collection('gameSessions')
        .where('patientId', isEqualTo: patientId)
        .where('gameId', isEqualTo: gameId)
        .orderBy('completedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map((d) => GameSession.fromMap(d.id, d.data())).toList());
  }

  /// Full difficulty-change audit trail for a patient (every game),
  /// newest first — feeds GameStatisticScreen's history list.
  Stream<QuerySnapshot<Map<String, dynamic>>> watchHistory(String patientId, {int limit = 30}) {
    return _db
        .collection('difficultyHistory')
        .where('patientId', isEqualTo: patientId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots();
  }
}

class _Decision {
  final int toLevel;
  final String reason;
  final Map<String, dynamic>? triggeringStats;
  const _Decision({required this.toLevel, required this.reason, this.triggeringStats});
}
