/// The three difficulty tiers shared by every cognitive game (memory
/// matching, category naming, name-face association, prospective memory
/// recall). One tier applies to ALL of a patient's games — there is no
/// per-game override in this MVP (see claude_code_new_games_and_difficulty_prompt.md,
/// design question 3).
///
/// Tier semantics (design question 1 resolution): the CAREGIVER sets this
/// per patient — there is no automatic difficulty adjustment based on live
/// in-game performance. Auto-adjustment (Bouchard et al., 2012) is future
/// work, intentionally not built here.
enum GameDifficultyTier {
  /// Most support: fewer items, no/generous time limits, strong slow-fading
  /// cues, high attempt count, larger touch targets.
  foundations,

  /// Moderate item count and time limits, faster-fading cues, limited
  /// attempts.
  standard,

  /// More items, tighter time limits, minimal cueing, fewer attempts.
  challenge,
}

extension GameDifficultyTierX on GameDifficultyTier {
  /// Firestore stores this as a plain string on the patient's users/{uid}
  /// doc, field `difficultyTier` (design question 2 resolution).
  static const String firestoreField = 'difficultyTier';

  static GameDifficultyTier fromFirestore(String? value) {
    switch (value) {
      case 'foundations':
        return GameDifficultyTier.foundations;
      case 'challenge':
        return GameDifficultyTier.challenge;
      case 'standard':
      default:
        // Default to Standard when unset — matches a freshly-created
        // patient account that the caregiver hasn't tiered yet.
        return GameDifficultyTier.standard;
    }
  }

  String get firestoreValue {
    switch (this) {
      case GameDifficultyTier.foundations:
        return 'foundations';
      case GameDifficultyTier.standard:
        return 'standard';
      case GameDifficultyTier.challenge:
        return 'challenge';
    }
  }

  String get label {
    switch (this) {
      case GameDifficultyTier.foundations:
        return 'Foundations';
      case GameDifficultyTier.standard:
        return 'Standard';
      case GameDifficultyTier.challenge:
        return 'Challenge';
    }
  }

  String get description {
    switch (this) {
      case GameDifficultyTier.foundations:
        return 'Fewer items, no time pressure, strong hints.';
      case GameDifficultyTier.standard:
        return 'Moderate items and time, some hints.';
      case GameDifficultyTier.challenge:
        return 'More items, timed, minimal hints.';
    }
  }
}
