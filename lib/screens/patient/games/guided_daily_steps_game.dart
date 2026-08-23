import 'dart:math';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// VaD-MIDDLE game, 2nd slot (see claude_code_four_game_sets_prompt.md): a
/// short 2-3 step daily task, walked through with heavy, constant visual
/// prompting — the next correct step is always shown lit up/glowing,
/// rather than only appearing as a hint after a wrong tap (as in the
/// VaD-Early Sequencing game). This models guided task-completion support
/// rather than testing recall of step order, matching the extra scaffolding
/// Regier et al. (2017, The Gerontologist) and de Werd et al. (2013) find
/// appropriate for middle-stage patients generally, applied here to the
/// planning/sequencing domain most impaired in Vascular Dementia
/// specifically. NEW game built for this task.
///
/// Extremely errorless design at level 1: the correct next step is ALWAYS
/// highlighted from the very first tap — there is no "figure it out first"
/// phase at all, and a wrong tap simply pulses the correct tile again
/// rather than registering as any kind of failure.
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3) — this game had no
/// [GameDifficultyTier] integration before, so a patient with no
/// difficultyState doc yet simply starts at level 1 (the original,
/// always-glowing behavior, unchanged). As level increases the constant
/// glow is withdrawn — level 2 allows 1 free miss and level 3 allows 2
/// free misses per step before the glowing cue appears — so a patient who
/// consistently demonstrates they don't need the cue gradually graduates
/// toward the lighter scaffolding used in the Early-stage Sequencing game,
/// per Ortega Morán et al. (2024).
const String _gameId = 'guided_daily_steps';
const String _gameSet = 'vad_middle';

class _LevelConfig {
  final int missesBeforeHint;
  const _LevelConfig({required this.missesBeforeHint});

  static _LevelConfig forLevel(int level) {
    switch (level) {
      case 2:
        return const _LevelConfig(missesBeforeHint: 1);
      case 3:
        return const _LevelConfig(missesBeforeHint: 2);
      case 1:
      default:
        return const _LevelConfig(missesBeforeHint: 0);
    }
  }
}

class GuidedDailyStepsGame extends StatefulWidget {
  const GuidedDailyStepsGame({super.key});

  @override
  State<GuidedDailyStepsGame> createState() => _GuidedDailyStepsGameState();
}

class _DailyTask {
  final String name;
  final String emoji;
  final List<String> steps;
  const _DailyTask(this.name, this.emoji, this.steps);
}

class _GuidedDailyStepsGameState extends State<GuidedDailyStepsGame> {
  static const List<_DailyTask> _tasks = [
    _DailyTask('Wash Your Hands', '🧼', [
      'Turn on the water',
      'Rub soap on your hands',
      'Rinse and dry your hands',
    ]),
    _DailyTask('Make the Bed', '🛏️', [
      'Pull up the blanket',
      'Fluff the pillow',
      'Smooth it flat',
    ]),
    _DailyTask('Have a Drink', '🥤', [
      'Pick up the cup',
      'Take a sip',
      'Put the cup down',
    ]),
  ];

  final Random _random = Random();
  final FirestoreService _firestoreService = FirestoreService();
  final AdaptiveDifficultyService _difficultyService = AdaptiveDifficultyService();

  String? _uid;
  int _level = 1;
  late _LevelConfig _config;
  bool _loadingLevel = true;

  late _DailyTask _task;
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
    _task = _tasks[_random.nextInt(_tasks.length)];
    final shuffled = List<String>.from(_task.steps)..shuffle(_random);
    setState(() {
      _options = shuffled;
      _placed.clear();
      _wrongAttemptsThisStep = 0;
      _totalWrongTapsSession = 0;
      _hintsUsedThisSession = 0;
      _sessionStart = DateTime.now();
      _hintActive = _config.missesBeforeHint == 0;
      _feedback = null;
    });
  }

  void _onOptionTap(String step) {
    final String correctStep = _task.steps[_placed.length];

    if (step == correctStep) {
      setState(() {
        _placed.add(step);
        _options.remove(step);
        _wrongAttemptsThisStep = 0;
        _hintActive = _config.missesBeforeHint == 0;
        _feedback = 'Great job! ✅';
      });
      if (_placed.length == _task.steps.length) {
        Future.delayed(const Duration(milliseconds: 500), _finishGame);
      }
    } else {
      // Extremely errorless: this never counts as a mistake — once the
      // glowing cue is showing it just pulses the correct tile again. Below
      // the level's miss threshold, no cue is shown yet (the patient is
      // expected to try on their own first). Hint transitions (not the
      // level-1 baseline glow, which isn't a struggle signal) are counted
      // once, matching the convention used elsewhere.
      final bool isNewHint = !_hintActive;
      setState(() {
        _wrongAttemptsThisStep++;
        _totalWrongTapsSession++;
        _feedback = _hintActive ? 'Try the glowing step!' : 'Not quite — try again!';
        if (_wrongAttemptsThisStep >= _config.missesBeforeHint) {
          _hintActive = true;
          if (isNewHint) _hintsUsedThisSession++;
        }
      });
    }
  }

  Future<void> _finishGame() async {
    const int pointsPerStep = 5;
    final int pointsEarned = _task.steps.length * pointsPerStep;
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
          // (always equals task length under errorless design) — see
          // memory_matching_game.dart's identical note.
          final int totalTaps = _task.steps.length + _totalWrongTapsSession;
          _level = await _difficultyService.recordSessionAndAdapt(
            sessionId: '${uid}_${_gameId}_${_sessionStart!.millisecondsSinceEpoch}',
            patientId: uid,
            gameId: _gameId,
            gameSet: _gameSet,
            difficultyLevel: _level,
            totalItems: totalTaps,
            correctItems: _task.steps.length,
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
          'You completed "${_task.name}" step by step.\n\n'
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
        title: const Text('Guided Daily Steps', style: TextStyle(color: Colors.white)),
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
                Text(_task.emoji, style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 8),
                Text(
                  _task.name,
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
              'Tap the glowing step to follow along.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),

            // Steps completed so far, in order.
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

            Expanded(
              child: ListView(
                children: _options.map((step) {
                  // At level 1 always glowing from the start; at higher
                  // levels only once the miss threshold for this step is
                  // reached (see _hintActive).
                  final bool isNextStep =
                      _hintActive && step == _task.steps[_placed.length];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => _onOptionTap(step),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: isNextStep
                                ? AppColors.orangeStart
                                : AppColors.cardPurpleLight,
                            width: isNextStep ? 3 : 1,
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
                          backgroundColor: isNextStep
                              ? AppColors.orangeStart.withOpacity(0.18)
                              : AppColors.cardPurple,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.centerLeft,
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        child: Row(
                          children: [
                            if (isNextStep)
                              const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: Icon(Icons.arrow_forward, color: AppColors.orangeStart),
                              ),
                            Expanded(child: Text(step)),
                          ],
                        ),
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
