import 'dart:math';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// VaD-EARLY game (see claude_code_four_game_sets_prompt.md): a multi-step
/// COGNITIVE / problem-solving task — the patient rebuilds a familiar
/// daily routine by tapping its steps in the correct order, targeting the
/// executive-function/sequencing deficit specific to Vascular Dementia.
/// Regier et al. (2017, The Gerontologist) separately find multi-step
/// sequencing/problem-solving activities like this appropriate for the
/// early stage generally.
///
/// Errorless design: an out-of-order tap is never a hard failure — it's
/// met with encouragement, and after repeated misses on the same step the
/// correct next tile is highlighted (a vanishing cue, matching the pattern
/// used elsewhere — de Werd et al., 2013).
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3) — this game had no
/// [GameDifficultyTier] integration before, so a patient with no
/// difficultyState doc yet simply starts at level 1. Routine step COUNT
/// stays fixed across levels (each routine is a coherent real-world
/// sequence — truncating "Making Tea" to 3 of 5 steps would stop making
/// sense as a completable task); only the hint threshold (misses allowed
/// before a vanishing cue appears) scales with level, per Ortega Morán et
/// al. (2024) — a deliberate, narrower scope than the item-count scaling
/// other games use, documented rather than silently assumed.
const String _gameId = 'sequencing';
const String _gameSet = 'vad_early';

class _LevelConfig {
  final int missesBeforeHint;
  const _LevelConfig({required this.missesBeforeHint});

  static _LevelConfig forLevel(int level) {
    switch (level) {
      case 1:
        return const _LevelConfig(missesBeforeHint: 1);
      case 3:
        return const _LevelConfig(missesBeforeHint: 3);
      case 2:
      default:
        return const _LevelConfig(missesBeforeHint: 2);
    }
  }
}

class SequencingGame extends StatefulWidget {
  const SequencingGame({super.key});

  @override
  State<SequencingGame> createState() => _SequencingGameState();
}

class _Routine {
  final String name;
  final String emoji;
  final List<String> steps;
  const _Routine(this.name, this.emoji, this.steps);
}

class _SequencingGameState extends State<SequencingGame> {
  static const List<_Routine> _routines = [
    _Routine('Making Tea', '🍵', [
      'Fill the kettle with water',
      'Boil the water',
      'Put a tea bag in the cup',
      'Pour the hot water into the cup',
      'Add milk or sugar if you like',
    ]),
    _Routine('Getting Dressed', '👕', [
      'Take off your pyjamas',
      'Put on your underwear',
      'Put on your trousers',
      'Put on your shirt',
      'Put on your shoes',
    ]),
    _Routine('Brushing Teeth', '🪥', [
      'Wet your toothbrush',
      'Put toothpaste on the brush',
      'Brush your teeth',
      'Rinse your mouth with water',
      'Rinse the toothbrush',
    ]),
  ];

  final Random _random = Random();
  final FirestoreService _firestoreService = FirestoreService();
  final AdaptiveDifficultyService _difficultyService = AdaptiveDifficultyService();

  String? _uid;
  int _level = 1;
  late _LevelConfig _config;
  bool _loadingLevel = true;

  late _Routine _routine;
  late List<String> _options; // steps not yet placed, shuffled
  final List<String> _placed = [];
  int _wrongAttemptsThisStep = 0;
  int _totalWrongTapsSession = 0;
  int _hintsUsedThisSession = 0;
  DateTime? _sessionStart;
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
    setState(() => _loadingLevel = false);
    _setUpGame();
  }

  void _setUpGame() {
    _routine = _routines[_random.nextInt(_routines.length)];
    final shuffled = List<String>.from(_routine.steps)..shuffle(_random);
    setState(() {
      _options = shuffled;
      _placed.clear();
      _wrongAttemptsThisStep = 0;
      _totalWrongTapsSession = 0;
      _hintsUsedThisSession = 0;
      _sessionStart = DateTime.now();
      _hintActive = false;
      _feedback = null;
    });
  }

  void _onOptionTap(String step) {
    final String correctStep = _routine.steps[_placed.length];

    if (step == correctStep) {
      setState(() {
        _placed.add(step);
        _options.remove(step);
        _wrongAttemptsThisStep = 0;
        _hintActive = false;
        _feedback = 'Nice! ✅';
      });
      if (_placed.length == _routine.steps.length) {
        Future.delayed(const Duration(milliseconds: 500), _finishGame);
      }
    } else {
      // Errorless learning: no hard fail. After a few misses on the same
      // step (level-scaled), highlight the correct next tile as a
      // vanishing cue.
      final bool isNewHint = !_hintActive;
      setState(() {
        _wrongAttemptsThisStep++;
        _totalWrongTapsSession++;
        _feedback = 'Nearly! Try this one.';
        if (_wrongAttemptsThisStep >= _config.missesBeforeHint) {
          _hintActive = true;
          if (isNewHint) _hintsUsedThisSession++;
        }
      });
    }
  }

  Future<void> _finishGame() async {
    const int pointsPerStep = 5;
    final int pointsEarned = _routine.steps.length * pointsPerStep;
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
          // ACCURACY: total taps (correct + wrong), not just steps placed
          // (which always equals routine length under errorless design) — see
          // memory_matching_game.dart's identical note.
          final int totalTaps = _routine.steps.length + _totalWrongTapsSession;
          _level = await _difficultyService.recordSessionAndAdapt(
            sessionId: '${uid}_${_gameId}_${_sessionStart!.millisecondsSinceEpoch}',
            patientId: uid,
            gameId: _gameId,
            gameSet: _gameSet,
            difficultyLevel: _level,
            totalItems: totalTaps,
            correctItems: _routine.steps.length,
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
          'You put all the steps of "${_routine.name}" in the right order.\n\n'
          'You earned $pointsEarned points!',
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDark,
      appBar: AppBar(
        title: const Text('Daily Routine', style: TextStyle(color: Colors.white)),
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
            Row(
              children: [
                Text(_routine.emoji, style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 8),
                Text(
                  _routine.name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
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
            const SizedBox(height: 4),
            const Text(
              'Tap the steps in the order you would do them.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),

            // Steps placed so far, in order.
            if (_placed.isNotEmpty) ...[
              ...List.generate(_placed.length, (i) {
                return Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.greenCheck.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.greenCheck),
                  ),
                  child: Text(
                    '${i + 1}. ${_placed[i]}',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                );
              }),
              const SizedBox(height: 8),
            ],

            if (_feedback != null) ...[
              Text(
                _feedback!,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.orangeStart,
                ),
              ),
              const SizedBox(height: 8),
            ],

            const Text(
              'What comes next?',
              style: TextStyle(fontSize: 14, color: AppColors.textMuted),
            ),
            const SizedBox(height: 8),

            Expanded(
              child: ListView(
                children: _options.map((step) {
                  final bool isHint = _hintActive && step == _routine.steps[_placed.length];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => _onOptionTap(step),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: isHint
                                ? AppColors.orangeStart
                                : AppColors.cardPurpleLight,
                            width: isHint ? 2.5 : 1,
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                          backgroundColor: isHint
                              ? AppColors.orangeStart.withOpacity(0.15)
                              : AppColors.cardPurple,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.centerLeft,
                          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        child: Text(step),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
