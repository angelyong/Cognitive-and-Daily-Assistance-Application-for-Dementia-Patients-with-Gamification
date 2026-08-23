import 'package:flutter/material.dart';

/// GAMIFICATION / ENGAGEMENT layer only — see reward_game_screen.dart's own
/// doc comment. These are NOT clinical cognitive exercises and have no
/// evidence-based design behind them; no therapeutic value is claimed for
/// any of them.
///
/// One entry per points-unlocked WebView reward game shown as a "Just for
/// Fun" tile in CognitiveExerciseScreen. [urls] is an ordered fallback
/// chain — RewardGameScreen tries each in turn until one loads, or shows a
/// friendly "taking a break" message if all fail (never a blank WebView).
class RewardGame {
  final String id;
  final String label;
  final IconData icon;
  final int unlockThreshold;
  final List<String> urls;

  const RewardGame({
    required this.id,
    required this.label,
    required this.icon,
    required this.unlockThreshold,
    required this.urls,
  });
}

/// Ordered by ascending [RewardGame.unlockThreshold] — the hub renders
/// these directly in this order so the patient sees a clear "what's next"
/// progression (see tiered_reward_games_prompt.md).
///
/// "Relax & Play" is the original game (migrated here unchanged, including
/// its 3-URL fallback chain — the third, 2048game.com, was added as extra
/// robustness beyond the original 2-URL spec). "Number Puzzle" (2048) is
/// deliberately the HIGHEST tier — the most cognitively demanding and
/// potentially frustrating of the four, positioned as a late "challenge"
/// reward rather than an early unlock; not a threshold to lower.
const List<RewardGame> kRewardGames = [
  RewardGame(
    id: 'relax_play',
    label: 'Relax & Play',
    icon: Icons.spa,
    unlockThreshold: 30,
    urls: [
      'https://memorygames.net/for-seniors',
      'https://www.lofiandgames.com/',
      'https://2048game.com/',
    ],
  ),
  RewardGame(
    id: 'merge_cooking',
    label: 'Merge Cooking',
    icon: Icons.cake,
    unlockThreshold: 50,
    urls: ['https://www.madkidgames.com/game/merge-cake-merge-cooking'],
  ),
  RewardGame(
    id: 'magic_sort',
    label: 'Magic Sort',
    icon: Icons.sort,
    unlockThreshold: 80,
    urls: ['https://gamezipper.com/magic-sort/'],
  ),
  RewardGame(
    id: 'number_puzzle',
    label: 'Number Puzzle',
    icon: Icons.grid_4x4,
    unlockThreshold: 120,
    urls: ['https://gamezipper.com/2048/'],
  ),
];
