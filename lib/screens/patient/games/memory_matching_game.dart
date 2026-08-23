import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/models/game_difficulty.dart';
import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// Classic "concentration" card game: flip two cards at a time and find
/// every matching picture pair.
///
/// AD-EARLY game (see claude_code_four_game_sets_prompt.md): episodic
/// memory is the cognitive domain most impaired early in Alzheimer's
/// Disease specifically (Frontiers in Aging Neuroscience, 2023 — AD shows
/// significantly worse episodic-memory performance than VaD, βg = −0.73),
/// and this working-memory/recall pairing task targets exactly that.
/// Regier et al. (2017, The Gerontologist) separately find multi-step
/// cognitive tasks like this appropriate for early-stage patients
/// generally — shown only in the AD-Early set on the Cognitive Games hub
/// (previously shown to all Early-stage patients regardless of type,
/// before the 4-set AD/VaD split).
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3) driven by
/// AdaptiveDifficultyService, migrated from the old caregiver-set
/// [GameDifficultyTier] (foundations→1, standard→2, challenge→3) the
/// first time this game is ever played after this change — see
/// [_loadLevelAndStart]. [GameDifficultyTier] itself is unchanged/still
/// caregiver-settable elsewhere; this game just no longer reads it after
/// that one-time migration. Level→parameter design (item count / time /
/// hint strength) follows Ortega Morán et al. (2024, JMIR Aging 7:e41437).
const String _gameId = 'memory_matching';
const String _gameSet = 'ad_early';

class MemoryMatchingGame extends StatefulWidget {
  const MemoryMatchingGame({super.key});

  @override
  State<MemoryMatchingGame> createState() => _MemoryMatchingGameState();
}

class _CardModel {
  final String emoji;
  bool isFaceUp = false;
  bool isMatched = false;
  _CardModel(this.emoji);
}

/// Per-level tuning, now keyed by the adaptive engine's 1..3 level instead
/// of [GameDifficultyTier] directly — the three configs are unchanged from
/// before (still "Tier 1 Foundations / 2 Standard / 3 Challenge" in spirit,
/// per claude_code_new_games_and_difficulty_prompt.md Part 2), only the
/// lookup key changed.
class _TierConfig {
  final int pairCount;
  final int gridCrossAxisCount;
  final int? timeLimitSeconds; // null = untimed (level 1)
  final int hintUses; // 0 = no hint button (level 3: minimal cueing)
  final bool hintRevealsAll; // level 1: strong cue; level 2: one pair
  final int pointsForWin;

  const _TierConfig({
    required this.pairCount,
    required this.gridCrossAxisCount,
    required this.timeLimitSeconds,
    required this.hintUses,
    required this.hintRevealsAll,
    required this.pointsForWin,
  });

  static _TierConfig forLevel(int level) {
    switch (level) {
      case 1:
        // Fewer items, no time pressure, strong/generous hints, larger
        // cards (lower crossAxisCount = bigger touch targets).
        return const _TierConfig(
          pairCount: 3,
          gridCrossAxisCount: 3,
          timeLimitSeconds: null,
          hintUses: 3,
          hintRevealsAll: true,
          pointsForWin: 8,
        );
      case 3:
        // More items, tighter timer, minimal cueing (no hint button).
        return const _TierConfig(
          pairCount: 6,
          gridCrossAxisCount: 4,
          timeLimitSeconds: 45,
          hintUses: 0,
          hintRevealsAll: false,
          pointsForWin: 16,
        );
      case 2:
      default:
        return const _TierConfig(
          pairCount: 4,
          gridCrossAxisCount: 4,
          timeLimitSeconds: 90,
          hintUses: 1,
          hintRevealsAll: false,
          pointsForWin: 10,
        );
    }
  }

  /// Display label only — preserves the familiar Foundations/Standard/
  /// Challenge wording the patient/caregiver already know, now describing
  /// an auto-adjusting per-game level rather than a caregiver-set tier.
  static String labelForLevel(int level) {
    switch (level) {
      case 1:
        return 'Foundations';
      case 3:
        return 'Challenge';
      case 2:
      default:
        return 'Standard';
    }
  }
}

/// One-time migration lookup (old tier -> initial per-game level), used
/// only by [_MemoryMatchingGameState._loadLevelAndStart] the first time
/// this game reads a difficultyState doc that doesn't exist yet.
int _levelFromTier(GameDifficultyTier tier) {
  switch (tier) {
    case GameDifficultyTier.foundations:
      return 1;
    case GameDifficultyTier.standard:
      return 2;
    case GameDifficultyTier.challenge:
      return 3;
  }
}

class _MemoryMatchingGameState extends State<MemoryMatchingGame> {
  static const List<String> _picturePool = [
    '🐶', '🐱', '🐘', '🦁', '🐦', '🐮', '🍎', '🚗',
    '🌸', '⭐', '🎈', '🍉',
  ];

  final Random _random = Random();
  final FirestoreService _firestoreService = FirestoreService();
  final AdaptiveDifficultyService _difficultyService = AdaptiveDifficultyService();

  String? _uid;
  int _level = 1;
  late _TierConfig _config;
  bool _loadingTier = true;

  late List<_CardModel> _cards;
  int? _firstIndex;
  int? _secondIndex;
  bool _busy = false;
  int _moves = 0;
  int _matchedPairs = 0;

  int _hintUsesLeft = 0;
  int _hintsUsedThisSession = 0;
  DateTime? _sessionStart;
  // Vanishing cue: each successive hint on Foundations reveals for a
  // shorter duration than the last (de Werd et al., 2013).
  double _nextHintRevealSeconds = 2.5;

  Timer? _countdownTimer;
  int? _secondsLeft;

  @override
  void initState() {
    super.initState();
    _loadLevelAndStart();
  }

  /// PART 1: reads this game's per-game adaptive level, migrating the old
  /// caregiver-set [GameDifficultyTier] into an initial level exactly once
  /// (only takes effect if no difficultyState doc exists yet for this
  /// game — a no-op every session after the first).
  Future<void> _loadLevelAndStart() async {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    _uid = uid;
    if (uid != null) {
      final GameDifficultyTier tier = await _firestoreService.getPatientDifficultyTier(uid);
      await _difficultyService.migrateInitialLevelIfAbsent(uid, _gameId, _levelFromTier(tier));
      final state = await _difficultyService.getState(uid, _gameId);
      _level = state.level;
    }
    _config = _TierConfig.forLevel(_level);
    if (!mounted) return;
    setState(() => _loadingTier = false);
    _setUpGame();
  }

  void _setUpGame() {
    _countdownTimer?.cancel();

    final chosen = List<String>.from(_picturePool)..shuffle(_random);
    final pictures = chosen.take(_config.pairCount).toList();
    final cards = [...pictures, ...pictures]
        .map((emoji) => _CardModel(emoji))
        .toList()
      ..shuffle(_random);

    setState(() {
      _cards = cards;
      _firstIndex = null;
      _secondIndex = null;
      _busy = false;
      _moves = 0;
      _matchedPairs = 0;
      _hintUsesLeft = _config.hintUses;
      _hintsUsedThisSession = 0;
      _sessionStart = DateTime.now();
      _nextHintRevealSeconds = 2.5;
      _secondsLeft = _config.timeLimitSeconds;
    });

    if (_config.timeLimitSeconds != null) {
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _secondsLeft = (_secondsLeft ?? 1) - 1);
        if ((_secondsLeft ?? 0) <= 0) {
          _countdownTimer?.cancel();
          _onTimeUp();
        }
      });
    }
  }

  void _onCardTap(int index) {
    final card = _cards[index];
    if (_busy || card.isFaceUp || card.isMatched) return;

    setState(() => card.isFaceUp = true);

    if (_firstIndex == null) {
      _firstIndex = index;
      return;
    }

    _secondIndex = index;
    _moves++;

    final first = _cards[_firstIndex!];
    final second = _cards[_secondIndex!];

    if (first.emoji == second.emoji) {
      setState(() {
        first.isMatched = true;
        second.isMatched = true;
        _matchedPairs++;
        _firstIndex = null;
        _secondIndex = null;
      });
      if (_matchedPairs == _config.pairCount) {
        _countdownTimer?.cancel();
        _finishGame(timedOut: false);
      }
    } else {
      // Errorless learning: a mismatch is never a dead end — cards simply
      // flip back and the patient tries again, no penalty screen.
      setState(() => _busy = true);
      Future.delayed(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        setState(() {
          first.isFaceUp = false;
          second.isFaceUp = false;
          _firstIndex = null;
          _secondIndex = null;
          _busy = false;
        });
      });
    }
  }

  /// Hint (vanishing cue, tier-gated): Foundations briefly reveals every
  /// unmatched card; Standard reveals one still-hidden pair; Challenge has
  /// no hint button at all (minimal cueing).
  void _useHint() {
    if (_hintUsesLeft <= 0 || _busy) return;

    final unmatched = _cards.where((c) => !c.isMatched).toList();
    final List<_CardModel> toReveal;
    if (_config.hintRevealsAll) {
      toReveal = unmatched;
    } else {
      // Find one matching pair among the still-hidden cards to reveal.
      final byEmoji = <String, List<_CardModel>>{};
      for (final c in unmatched) {
        byEmoji.putIfAbsent(c.emoji, () => []).add(c);
      }
      final pair = byEmoji.values.firstWhere(
        (g) => g.length == 2,
        orElse: () => const [],
      );
      toReveal = pair;
    }
    if (toReveal.isEmpty) return;

    final double revealSeconds = _nextHintRevealSeconds;
    setState(() {
      _hintUsesLeft--;
      _hintsUsedThisSession++;
      _busy = true;
      for (final c in toReveal) {
        c.isFaceUp = true;
      }
      // Each subsequent hint fades a little faster than the last.
      _nextHintRevealSeconds = (_nextHintRevealSeconds - 0.4).clamp(1.0, 2.5);
    });

    Future.delayed(Duration(milliseconds: (revealSeconds * 1000).round()), () {
      if (!mounted) return;
      setState(() {
        for (final c in toReveal) {
          if (!c.isMatched) c.isFaceUp = false;
        }
        _busy = false;
      });
    });
  }

  void _onTimeUp() {
    // Errorless learning: running out of time is never framed as failure —
    // we reveal the board and celebrate what was found.
    setState(() {
      for (final c in _cards) {
        c.isFaceUp = true;
      }
    });
    _finishGame(timedOut: true);
  }

  Future<void> _finishGame({required bool timedOut}) async {
    // Partial credit even on a timeout — proportional to pairs actually
    // matched, so the patient is always rewarded for progress made.
    final int pointsEarned = timedOut
        ? ((_config.pointsForWin * _matchedPairs) / _config.pairCount).round()
        : _config.pointsForWin;

    final String? uid = _uid;
    // Network/permission failures here must never strand the patient on a
    // frozen screen — the session already finished from their point of
    // view, so any save failure is reported quietly (a SnackBar) and the
    // completion dialog below still shows either way.
    if (uid != null) {
      try {
        if (pointsEarned > 0) {
          await _firestoreService.awardPoints(uid, pointsEarned);
        }
        // PART 1: record this session and let the engine decide whether to
        // promote/demote — sessionId is derived from this round's own start
        // time (captured once in _setUpGame), so it's stable for this round's
        // lifetime (idempotent against an accidental double-call of this
        // method for the same round).
        if (_sessionStart != null) {
          // ACCURACY NOTE: using pairCount/matchedPairs here would make
          // accuracy trivially 1.0 on every non-timeout completion (errorless
          // design means every round DOES eventually finish), which would
          // make promotion fire almost immediately and demotion never fire at
          // all except via a timeout — defeating the adaptive engine's whole
          // purpose. Using _moves (every flip-comparison attempted, including
          // mismatches) as totalItems and _matchedPairs (successful
          // comparisons) as correctItems instead measures the real signal:
          // how many attempts it took to find each pair, not just whether the
          // round eventually completed.
          _level = await _difficultyService.recordSessionAndAdapt(
            sessionId: '${uid}_${_gameId}_${_sessionStart!.millisecondsSinceEpoch}',
            patientId: uid,
            gameId: _gameId,
            gameSet: _gameSet,
            difficultyLevel: _level,
            totalItems: _moves,
            correctItems: _matchedPairs,
            hintsUsed: _hintsUsedThisSession,
            durationSeconds: DateTime.now().difference(_sessionStart!).inSeconds,
          );
          _config = _TierConfig.forLevel(_level); // reflect any promote/demote for "Play Again"
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Couldn't save your progress — check your connection and try again."),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardPurple,
        title: Text(
          timedOut ? "Time's up! 🙂" : 'All matched! 🎉',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          timedOut
              ? 'You found $_matchedPairs of ${_config.pairCount} pairs — '
                  'nice work!\n\nYou earned $pointsEarned points!'
              : 'You found all ${_config.pairCount} pairs in $_moves tries.'
                  '\n\nYou earned $pointsEarned points!',
          style: const TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
            child: const Text('Back to Games'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.orangeStart,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(context);
              _setUpGame();
            },
            child: const Text('Play Again'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDark,
      appBar: AppBar(
        title: const Text(
          'Memory Matching',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: AppColors.bgDark,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _loadingTier
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.orangeStart),
            )
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Matched $_matchedPairs of ${_config.pairCount} pairs '
                        '· $_moves tries',
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppColors.textMuted,
                        ),
                      ),
                      if (_secondsLeft != null)
                        Text(
                          '⏱ ${_secondsLeft}s',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: (_secondsLeft ?? 0) <= 10
                                ? AppColors.orangeEnd
                                : Colors.white,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Difficulty: ${_TierConfig.labelForLevel(_level)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.orangeStart,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: _config.gridCrossAxisCount,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: _cards.length,
                      itemBuilder: (context, index) {
                        return _MemoryCard(
                          card: _cards[index],
                          onTap: () => _onCardTap(index),
                        );
                      },
                    ),
                  ),
                  if (_hintUsesLeft > 0) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _useHint,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.orangeStart,
                          side: const BorderSide(color: AppColors.orangeStart),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.lightbulb_outline),
                        label: Text('Hint ($_hintUsesLeft left)'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  final _CardModel card;
  final VoidCallback onTap;

  const _MemoryCard({required this.card, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final bool showFace = card.isFaceUp || card.isMatched;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: card.isMatched
              ? AppColors.greenCheck.withOpacity(0.25)
              : showFace
                  ? AppColors.cardPurpleLight
                  : AppColors.cardPurple,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: card.isMatched
                ? AppColors.greenCheck
                : AppColors.cardPurpleLight,
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        child: showFace
            ? Text(card.emoji, style: const TextStyle(fontSize: 28))
            : const Icon(Icons.help_outline, color: AppColors.textMuted, size: 24),
      ),
    );
  }
}
