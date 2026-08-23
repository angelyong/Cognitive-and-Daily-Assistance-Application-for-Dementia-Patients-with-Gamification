import 'dart:math';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// VaD-EARLY game, 3rd slot (see claude_code_four_game_sets_prompt.md):
/// four items are shown, three sharing a category and one different, and
/// the patient taps the one that doesn't belong. This is a selective-
/// attention/inhibition task — noticing and acting on the one item that
/// breaks the pattern while ignoring the rest — which de Oliveira et al.
/// (2017) and Graham (2004) both associate with the executive-function/
/// attention domain most impaired in Vascular Dementia specifically. NEW
/// game built for this task.
///
/// Errorless design: tapping a wrong item is never a hard fail — it's met
/// with encouragement, and after repeated misses the correct odd item is
/// highlighted as a vanishing cue, matching the pattern used elsewhere.
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3) — this game had no
/// [GameDifficultyTier] integration before, so a patient with no
/// difficultyState doc yet simply starts at level 1. Level scales round
/// count and the hint threshold, per Ortega Morán et al. (2024).
const String _gameId = 'odd_one_out';
const String _gameSet = 'vad_early';

class _LevelConfig {
  final int roundCount;
  final int missesBeforeHint;
  const _LevelConfig({required this.roundCount, required this.missesBeforeHint});

  static _LevelConfig forLevel(int level) {
    switch (level) {
      case 1:
        return const _LevelConfig(roundCount: 4, missesBeforeHint: 1);
      case 3:
        return const _LevelConfig(roundCount: 6, missesBeforeHint: 3);
      case 2:
      default:
        return const _LevelConfig(roundCount: 6, missesBeforeHint: 2);
    }
  }
}

class OddOneOutGame extends StatefulWidget {
  const OddOneOutGame({super.key});

  @override
  State<OddOneOutGame> createState() => _OddOneOutGameState();
}

class _OddRound {
  final List<String> items; // 4 items, index [oddIndex] is the odd one out
  final int oddIndex;
  const _OddRound(this.items, this.oddIndex);
}

class _OddOneOutGameState extends State<OddOneOutGame> {
  static const List<_OddRound> _rounds = [
    _OddRound(['🍎', '🍌', '🍇', '🚗'], 3),
    _OddRound(['🐶', '🐱', '🐘', '🛋️'], 3),
    _OddRound(['👕', '👖', '👗', '🍳'], 3),
    _OddRound(['☀️', '🌙', '⭐', '🍽️'], 3),
    _OddRound(['🚗', '🚌', '🚲', '🐟'], 3),
    _OddRound(['🔴', '🟠', '🟡', '🟦'], 3),
  ];

  final Random _random = Random();
  final FirestoreService _firestoreService = FirestoreService();
  final AdaptiveDifficultyService _difficultyService = AdaptiveDifficultyService();

  String? _uid;
  int _level = 1;
  late _LevelConfig _config;
  bool _loadingLevel = true;

  int _roundIndex = 0;
  int _correctCount = 0;
  int _totalWrongTapsSession = 0;
  int _hintsUsedThisSession = 0;
  DateTime? _sessionStart;
  late List<String> _shuffledItems;
  late String _correctItem;
  int _wrongAttemptsThisRound = 0;
  bool _hintActive = false;
  String? _feedback;

  @override
  void initState() {
    super.initState();
    _loadLevelAndStart();
  }

  Future<void> _loadLevelAndStart() async {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    _uid = uid;
    if (uid != null) {
      final state = await _difficultyService.getState(uid, _gameId);
      _level = state.level;
    }
    _config = _LevelConfig.forLevel(_level);
    if (!mounted) return;
    setState(() {
      _loadingLevel = false;
      _roundIndex = 0;
      _correctCount = 0;
      _totalWrongTapsSession = 0;
      _hintsUsedThisSession = 0;
      _sessionStart = DateTime.now();
    });
    _setUpRound();
  }

  void _setUpRound() {
    final round = _rounds[_roundIndex];
    final correctItem = round.items[round.oddIndex];
    final shuffled = List<String>.from(round.items)..shuffle(_random);

    setState(() {
      _shuffledItems = shuffled;
      _correctItem = correctItem;
      _wrongAttemptsThisRound = 0;
      _hintActive = false;
      _feedback = null;
    });
  }

  void _onItemTap(String item) {
    if (item == _correctItem) {
      setState(() {
        _correctCount++;
        _feedback = 'Spotted it! 🎉';
      });
      Future.delayed(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        if (_roundIndex + 1 >= _config.roundCount) {
          _finishGame();
        } else {
          setState(() => _roundIndex++);
          _setUpRound();
        }
      });
    } else {
      // Errorless learning: no hard fail. After a level-scaled number of
      // misses, highlight the correct odd item as a vanishing cue.
      final bool isNewHint = !_hintActive;
      setState(() {
        _wrongAttemptsThisRound++;
        _totalWrongTapsSession++;
        _feedback = 'Not that one — look for the item that\'s different!';
        if (_wrongAttemptsThisRound >= _config.missesBeforeHint) {
          _hintActive = true;
          if (isNewHint) _hintsUsedThisSession++;
        }
      });
    }
  }

  Future<void> _finishGame() async {
    const int pointsPerCorrect = 4;
    final int pointsEarned = _correctCount * pointsPerCorrect;
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
          // ACCURACY: total taps (correct + wrong), not just rounds completed
          // (always equals roundCount under errorless design) — see
          // memory_matching_game.dart's identical note.
          final int totalTaps = _correctCount + _totalWrongTapsSession;
          _level = await _difficultyService.recordSessionAndAdapt(
            sessionId: '${uid}_${_gameId}_${_sessionStart!.millisecondsSinceEpoch}',
            patientId: uid,
            gameId: _gameId,
            gameSet: _gameSet,
            difficultyLevel: _level,
            totalItems: totalTaps,
            correctItems: _correctCount,
            hintsUsed: _hintsUsedThisSession,
            durationSeconds: DateTime.now().difference(_sessionStart!).inSeconds,
          );
          _config = _LevelConfig.forLevel(_level);
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
        title: const Text('All done! 🎉', style: TextStyle(color: Colors.white)),
        content: Text(
          'You found the odd one out $_correctCount of ${_config.roundCount} '
          'times.\n\nYou earned $pointsEarned points!',
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
              setState(() {
                _roundIndex = 0;
                _correctCount = 0;
                _totalWrongTapsSession = 0;
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDark,
      appBar: AppBar(
        title: const Text('Odd One Out', style: TextStyle(color: Colors.white)),
        backgroundColor: AppColors.bgDark,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _loadingLevel
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.orangeStart),
            )
          : Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Round ${_roundIndex + 1} of ${_config.roundCount}',
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
            const SizedBox(height: 4),
            Text(
              'Level $_level of 3',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.orangeStart,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Which one is different from the rest?',
              style: TextStyle(fontSize: 16, color: Colors.white),
            ),
            const SizedBox(height: 24),
            if (_feedback != null) ...[
              Center(
                child: Text(
                  _feedback!,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.orangeStart,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              children: _shuffledItems.map((item) {
                final bool isHint = _hintActive && item == _correctItem;
                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _onItemTap(item),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isHint
                          ? AppColors.orangeStart.withOpacity(0.15)
                          : AppColors.cardPurple,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isHint
                            ? AppColors.orangeStart
                            : AppColors.cardPurpleLight,
                        width: isHint ? 3 : 2,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(item, style: const TextStyle(fontSize: 48)),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
