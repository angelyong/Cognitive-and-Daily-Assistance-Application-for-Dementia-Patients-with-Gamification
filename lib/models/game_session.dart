import 'package:cloud_firestore/cloud_firestore.dart';

/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): one record of
/// a patient finishing one game session — the raw material the Adaptive
/// Difficulty Engine's promote/demote rules run against (see
/// AdaptiveDifficultyService), and what GameStatisticScreen's trend chart
/// reads. Stored at `gameSessions/{sessionId}` with a CLIENT-GENERATED
/// deterministic id (see AdaptiveDifficultyService.recordSessionAndAdapt)
/// so an accidental double-submit overwrites the same doc rather than
/// creating a duplicate.
/// What a session's `accuracy` actually MEASURES — see
/// DESIGN_DECISIONS_IMPLEMENTATION_PLAN.md #1. Under this app's errorless
/// design, "items completed" is always 100%, so accuracy is really a
/// struggle signal, computed one of two ways depending on the game. Stored
/// on every new session so the risk score-drop signal only ever compares
/// like-with-like (never a first-attempt game's accuracy against a
/// tap-efficiency game's).
class GameMetricType {
  static const String firstAttempt = 'first_attempt'; // correct-on-first-try ÷ rounds
  static const String tapEfficiency = 'tap_efficiency'; // correct taps ÷ total taps
  static const String unknown = 'unknown'; // legacy docs written before this field
}

/// Bumped only if the struggle-signal formula itself changes, so a future
/// change can't silently mix old and new numbers in the same comparison.
/// Legacy docs with no field are treated as version 0.
const int kCurrentMetricVersion = 1;

class GameSession {
  final String sessionId;
  final String patientId;
  final String gameId;
  final String gameSet; // 'ad_early' | 'ad_middle' | 'vad_early' | 'vad_middle'
  final int difficultyLevel; // 1..3 — the level this session was PLAYED at
  final int totalItems;
  final int correctItems;
  final int hintsUsed;
  final int durationSeconds;
  final DateTime completedAt;
  final String metricType; // see GameMetricType
  final int metricVersion; // see kCurrentMetricVersion

  const GameSession({
    required this.sessionId,
    required this.patientId,
    required this.gameId,
    required this.gameSet,
    required this.difficultyLevel,
    required this.totalItems,
    required this.correctItems,
    required this.hintsUsed,
    required this.durationSeconds,
    required this.completedAt,
    this.metricType = GameMetricType.unknown,
    this.metricVersion = 0,
  });

  double get accuracy => totalItems == 0 ? 0.0 : correctItems / totalItems;

  Map<String, dynamic> toMap() => {
        'patientId': patientId,
        'gameId': gameId,
        'gameSet': gameSet,
        'difficultyLevel': difficultyLevel,
        'totalItems': totalItems,
        'correctItems': correctItems,
        'accuracy': accuracy,
        'hintsUsed': hintsUsed,
        'durationSeconds': durationSeconds,
        'completedAt': FieldValue.serverTimestamp(),
        'metricType': metricType,
        'metricVersion': metricVersion,
      };

  factory GameSession.fromMap(String sessionId, Map<String, dynamic> map) {
    final ts = map['completedAt'];
    return GameSession(
      sessionId: sessionId,
      patientId: (map['patientId'] ?? '') as String,
      gameId: (map['gameId'] ?? '') as String,
      gameSet: (map['gameSet'] ?? '') as String,
      difficultyLevel: (map['difficultyLevel'] as num?)?.toInt() ?? 1,
      totalItems: (map['totalItems'] as num?)?.toInt() ?? 0,
      correctItems: (map['correctItems'] as num?)?.toInt() ?? 0,
      hintsUsed: (map['hintsUsed'] as num?)?.toInt() ?? 0,
      durationSeconds: (map['durationSeconds'] as num?)?.toInt() ?? 0,
      completedAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
      metricType: (map['metricType'] ?? GameMetricType.unknown) as String,
      metricVersion: (map['metricVersion'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Per-(patient, game) difficulty state — `users/{patientId}/difficultyState/{gameId}`.
///
/// MIGRATION NOTE: the pre-existing `GameDifficultyTier` (foundations/
/// standard/challenge on the user doc, applying to ALL of a patient's
/// games at once) is superseded by this PER-GAME level for the 4 games
/// that used it (memory_matching, category_naming, name_face,
/// prospective_memory) — see each game's own doc comment for the
/// foundations→1 / standard→2 / challenge→3 initial-level mapping applied
/// the first time that game reads its (previously nonexistent)
/// difficultyState doc. `GameDifficultyTier` itself is left entirely
/// intact (still readable/settable via FirestoreService) — nothing reads
/// it anymore after this migration, but nothing deletes the field either,
/// so no data is lost if this needs to be reverted.
class DifficultyState {
  final int level; // 1 (easiest) .. 3 (hardest)
  final String source; // 'auto' | 'caregiver'
  final bool frozen; // true = caregiver override active, auto paused
  final int version; // optimistic-concurrency counter
  final DateTime? updatedAt;

  const DifficultyState({
    required this.level,
    required this.source,
    required this.frozen,
    required this.version,
    required this.updatedAt,
  });

  /// Default for a patient/game with no state doc yet — dementia-appropriate:
  /// start easy, not at a migrated tier (a game only migrates an old tier
  /// on its OWN first read, done in-game, not here).
  static const DifficultyState initial = DifficultyState(
    level: 1,
    source: 'auto',
    frozen: false,
    version: 0,
    updatedAt: null,
  );

  factory DifficultyState.fromMap(Map<String, dynamic>? map) {
    if (map == null) return initial;
    final ts = map['updatedAt'];
    return DifficultyState(
      level: (map['level'] as num?)?.toInt() ?? 1,
      source: (map['source'] as String?) ?? 'auto',
      frozen: (map['frozen'] as bool?) ?? false,
      version: (map['version'] as num?)?.toInt() ?? 0,
      updatedAt: ts is Timestamp ? ts.toDate() : null,
    );
  }
}
