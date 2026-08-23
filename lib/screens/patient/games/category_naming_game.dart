import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/models/game_difficulty.dart';
import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// A round-based game: a category is named (e.g. "Fruits") and the
/// patient taps every picture on screen that belongs to it, mixed in
/// among pictures from other categories.
///
/// AD-EARLY game (see claude_code_four_game_sets_prompt.md): exercises
/// semantic fluency, the specific fluency subtype impaired early in
/// Alzheimer's Disease — Olmos-Villaseñor et al. (2023) find semantic
/// fluency (not phonemic fluency, which is more VaD-associated) is the
/// fluency deficit that distinguishes AD. Bahar-Fuchs et al. (2019)
/// separately find semantic fluency tasks like this appropriate and
/// beneficial at the early stage generally — shown only in the AD-Early
/// set on the Cognitive Games hub (previously shown to all Early-stage
/// patients regardless of type, before the 4-set AD/VaD split).
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3), migrated once from the old
/// caregiver-set [GameDifficultyTier] (foundations→1, standard→2,
/// challenge→3) — see [_CategoryNamingGameState._loadLevelAndStart]. The
/// three parameter sets below are unchanged, just re-keyed by level.
const String _gameId = 'category_naming';
const String _gameSet = 'ad_early';

class CategoryNamingGame extends StatefulWidget {
  const CategoryNamingGame({super.key});

  @override
  State<CategoryNamingGame> createState() => _CategoryNamingGameState();
}

class _RoundTile {
  final String emoji;
  final bool belongsToCategory;
  _TileState state = _TileState.neutral;
  _RoundTile(this.emoji, this.belongsToCategory);
}

enum _TileState { neutral, correct, wrong, cued }

/// Per-tier tuning. See claude_code_new_games_and_difficulty_prompt.md Part 2.
class _TierConfig {
  final int totalRounds;
  final int correctPerRound;
  final int distractorsPerRound;
  final int? timeLimitSeconds; // null = untimed (Foundations)
  final bool cueAfterWrongTap; // errorless-learning hint (de Werd et al., 2013)
  final bool showEncouragement; // near-miss message (Ortega Morán et al., 2024)

  const _TierConfig({
    required this.totalRounds,
    required this.correctPerRound,
    required this.distractorsPerRound,
    required this.timeLimitSeconds,
    required this.cueAfterWrongTap,
    required this.showEncouragement,
  });

  static _TierConfig forLevel(int level) {
    switch (level) {
      case 1:
        return const _TierConfig(
          totalRounds: 3,
          correctPerRound: 2,
          distractorsPerRound: 2,
          timeLimitSeconds: null,
          cueAfterWrongTap: true,
          showEncouragement: true,
        );
      case 3:
        return const _TierConfig(
          totalRounds: 7,
          correctPerRound: 4,
          distractorsPerRound: 8,
          timeLimitSeconds: 18,
          cueAfterWrongTap: false,
          showEncouragement: false,
        );
      case 2:
      default:
        return const _TierConfig(
          totalRounds: 5,
          correctPerRound: 3,
          distractorsPerRound: 5,
          timeLimitSeconds: 30,
          cueAfterWrongTap: true,
          showEncouragement: true,
        );
    }
  }

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

class _CategoryNamingGameState extends State<CategoryNamingGame> {
  static const Map<String, List<String>> _categories = {
    'Fruits': ['🍎', '🍌', '🍇', '🍊', '🍓', '🍍', '🍉', '🍑'],
    'Animals': ['🐶', '🐱', '🐘', '🦁', '🐦', '🐮', '🐰', '🐢'],
    'Vehicles': ['🚗', '🚌', '🚲', '🚂', '✈️', '🚤', '🚕', '🚁'],
    'Furniture': ['🛋️', '🪑', '🛏️', '🚪', '🪟', '🗄️', '🪞', '🛁'],
    'Kitchen Items': ['🍽️', '🥄', '🍴', '🫖', '🍳', '🔪', '🥣', '🧂'],
    'Clothing': ['👕', '👖', '👗', '🧥', '👟', '🧢', '🧦', '👒'],
  };

  final Random _random = Random();
  final FirestoreService _firestoreService = FirestoreService();
  final AdaptiveDifficultyService _difficultyService = AdaptiveDifficultyService();

  String? _uid;
  int _level = 1;
  late _TierConfig _config;
  bool _loadingTier = true;

  int _round = 1;
  late String _targetCategory;
  late List<_RoundTile> _tiles;
  int _foundThisRound = 0;
  bool _roundComplete = false;
  String? _encouragement;

  int _totalCorrectTaps = 0;
  int _totalWrongTaps = 0;
  int _hintsUsedThisSession = 0;
  DateTime? _sessionStart;

  Timer? _countdownTimer;
  int? _secondsLeft;

  @override
  void initState() {
    super.initState();
    _loadLevelAndStart();
  }

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
    _sessionStart = DateTime.now();
    if (!mounted) return;
    setState(() => _loadingTier = false);
    _setUpRound();
  }

  void _setUpRound() {
    _countdownTimer?.cancel();

    final categoryNames = _categories.keys.toList();
    _targetCategory = categoryNames[_random.nextInt(categoryNames.length)];

    final correctPool = List<String>.from(_categories[_targetCategory]!)
      ..shuffle(_random);
    final correctItems = correctPool.take(_config.correctPerRound).toList();

    final otherCategories = categoryNames
        .where((c) => c != _targetCategory)
        .toList()
      ..shuffle(_random);
    final distractors = <String>[];
    for (final cat in otherCategories) {
      if (distractors.length >= _config.distractorsPerRound) break;
      final items = _categories[cat]!;
      distractors.add(items[_random.nextInt(items.length)]);
    }

    final tiles = [
      ...correctItems.map((e) => _RoundTile(e, true)),
      ...distractors.map((e) => _RoundTile(e, false)),
    ]..shuffle(_random);

    setState(() {
      _tiles = tiles;
      _foundThisRound = 0;
      _roundComplete = false;
      _encouragement = null;
      _secondsLeft = _config.timeLimitSeconds;
    });

    if (_config.timeLimitSeconds != null) {
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _secondsLeft = (_secondsLeft ?? 1) - 1);
        if ((_secondsLeft ?? 0) <= 0) {
          _countdownTimer?.cancel();
          setState(() => _roundComplete = true); // move on, no penalty
        }
      });
    }
  }

  void _onTileTap(_RoundTile tile) {
    if (_roundComplete || tile.state != _TileState.neutral) return;

    setState(() {
      if (tile.belongsToCategory) {
        tile.state = _TileState.correct;
        _foundThisRound++;
        _totalCorrectTaps++;
        _encouragement = null;
        if (_foundThisRound == _config.correctPerRound) {
          _roundComplete = true;
          _countdownTimer?.cancel();
        }
      } else {
        tile.state = _TileState.wrong;
        _totalWrongTaps++;

        // Errorless learning: a wrong tap is followed by support, not a
        // dead end. Near-miss encouragement (Ortega Morán et al., 2024) +
        // a cue toward one remaining correct tile (de Werd et al., 2013),
        // both tier-gated so Challenge stays minimally cued.
        if (_config.showEncouragement) {
          _encouragement = "Not quite — you're close, try again!";
        }
        if (_config.cueAfterWrongTap) {
          final remaining = _tiles
              .where((t) => t.belongsToCategory && t.state == _TileState.neutral)
              .toList();
          if (remaining.isNotEmpty) {
            final cued = remaining[_random.nextInt(remaining.length)];
            cued.state = _TileState.cued;
            _hintsUsedThisSession++;
            Future.delayed(const Duration(milliseconds: 1200), () {
              if (!mounted) return;
              setState(() {
                if (cued.state == _TileState.cued) {
                  cued.state = _TileState.neutral;
                }
              });
            });
          }
        }
      }
    });
  }

  void _nextRound() {
    if (_round >= _config.totalRounds) {
      _finishGame();
      return;
    }
    setState(() => _round++);
    _setUpRound();
  }

  Future<void> _finishGame() async {
    final int pointsEarned = _totalCorrectTaps;
    final String? uid = _uid;
    // Network/permission failures here must never strand the patient on a
    // frozen screen — the session already finished from their point of
    // view, so any save failure is reported quietly (a SnackBar) and the
    // completion dialog below still shows either way. The two saves below
    // are INDEPENDENT (separate try/catch each) — a failed points award
    // must never prevent recordSessionAndAdapt from running, since that
    // call is also what writes the raw session record other systems (the
    // accuracy trend chart, the risk indicator's score-drop signal) depend
    // on, and vice versa.
    if (uid != null) {
      if (_sessionStart != null) {
        try {
          // ACCURACY NOTE: totalRounds*correctPerRound vs. _totalCorrectTaps
          // would always be equal (a round only ends once exactly that many
          // correct items are found, by construction) — trivially 1.0 on
          // every completion, which would defeat the adaptive engine's
          // purpose (see memory_matching_game.dart's identical note). Using
          // every tap made (correct + wrong) as totalItems instead correctly
          // captures how many wrong taps it took along the way.
          _level = await _difficultyService.recordSessionAndAdapt(
            sessionId: '${uid}_${_gameId}_${_sessionStart!.millisecondsSinceEpoch}',
            patientId: uid,
            gameId: _gameId,
            gameSet: _gameSet,
            difficultyLevel: _level,
            totalItems: _totalCorrectTaps + _totalWrongTaps,
            correctItems: _totalCorrectTaps,
            hintsUsed: _hintsUsedThisSession,
            durationSeconds: DateTime.now().difference(_sessionStart!).inSeconds,
          );
          _config = _TierConfig.forLevel(_level); // reflect any promote/demote for "Play Again"
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
      if (pointsEarned > 0) {
        try {
          await _firestoreService.awardPoints(uid, pointsEarned);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("Couldn't save your points — check your connection and try again."),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardPurple,
        title: const Text(
          'Great job! 🎉',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'You found $_totalCorrectTaps correct items '
          '(and $_totalWrongTaps misses) across ${_config.totalRounds} rounds.\n\n'
          'You earned $pointsEarned points!',
          style: const TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // close dialog
              Navigator.pop(context); // back to games hub
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
              setState(() {
                _round = 1;
                _totalCorrectTaps = 0;
                _totalWrongTaps = 0;
                _hintsUsedThisSession = 0;
                _sessionStart = DateTime.now();
              });
              _setUpRound();
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
          'Category Naming',
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
                        'Round $_round of ${_config.totalRounds}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textMuted,
                        ),
                      ),
                      if (_secondsLeft != null)
                        Text(
                          '⏱ ${_secondsLeft}s',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: (_secondsLeft ?? 0) <= 5
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
                  const SizedBox(height: 12),
                  Text.rich(
                    TextSpan(
                      text: 'Tap every ',
                      style: const TextStyle(fontSize: 18, color: Colors.white),
                      children: [
                        TextSpan(
                          text: _targetCategory,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppColors.orangeStart,
                          ),
                        ),
                        const TextSpan(text: ' picture'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Found $_foundThisRound of ${_config.correctPerRound}',
                    style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                  ),
                  if (_encouragement != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _encouragement!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.orangeStart,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                      ),
                      itemCount: _tiles.length,
                      itemBuilder: (context, index) {
                        final tile = _tiles[index];
                        return _CategoryTile(
                          tile: tile,
                          onTap: () => _onTileTap(tile),
                        );
                      },
                    ),
                  ),
                  if (_roundComplete) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _nextRound,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.orangeStart,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          _round >= _config.totalRounds ? 'Finish' : 'Next Round',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final _RoundTile tile;
  final VoidCallback onTap;

  const _CategoryTile({required this.tile, required this.onTap});

  @override
  Widget build(BuildContext context) {
    Color background;
    Color border;
    switch (tile.state) {
      case _TileState.correct:
        background = AppColors.greenCheck.withOpacity(0.25);
        border = AppColors.greenCheck;
        break;
      case _TileState.wrong:
        background = AppColors.orangeEnd.withOpacity(0.25);
        border = AppColors.orangeEnd;
        break;
      case _TileState.cued:
        // Vanishing cue toward a correct-but-not-yet-found tile.
        background = AppColors.orangeStart.withOpacity(0.30);
        border = AppColors.orangeStart;
        break;
      case _TileState.neutral:
        background = AppColors.cardPurple;
        border = AppColors.cardPurpleLight;
        break;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border, width: 2),
        ),
        alignment: Alignment.center,
        child: Text(tile.emoji, style: const TextStyle(fontSize: 34)),
      ),
    );
  }
}
