import 'dart:math';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/models/game_session.dart';
import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// AD-MIDDLE game, 3rd slot (see claude_code_four_game_sets_prompt.md): a
/// familiar everyday sound is described, and the patient recognizes (not
/// recalls) which picture made it from a small set of large option
/// buttons. Regier et al. (2017, The Gerontologist) find
/// recognition/sensory activities like this suit the middle stage. NEW
/// game built for this task.
///
/// ASSET DECISION: the doc's brief describes an actual audio clip playing.
/// MindCare has no bundled sound-asset pipeline yet, so — per the doc's
/// own suggested fallback — each "sound" is represented as large bold text
/// plus an emoji standing in for the sound itself (e.g. "🔔 DING DONG"),
/// not a real audio file. Wiring real `just_audio`/`audioplayers` clips
/// for these prompts is flagged as future work, not implemented here.
///
/// Errorless design: a wrong tap is never a hard fail — it's met with
/// encouragement, and after repeated misses the correct picture is
/// highlighted as a vanishing cue, matching the pattern used elsewhere.
///
/// Middle-stage requirements applied here: short (5-round) session, no
/// timer/time pressure, large touch-target option buttons.
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3, level→round/option-count/
/// hint-threshold mapping follows Ortega Morán et al., 2024) — this game
/// had no [GameDifficultyTier] integration before, so a patient with no
/// difficultyState doc yet simply starts at level 1, per the engine's own
/// default.
const String _gameId = 'familiar_sound';
const String _gameSet = 'ad_middle';

class _LevelConfig {
  final int totalRounds;
  final int optionCount;
  final int missesBeforeHint;

  const _LevelConfig({
    required this.totalRounds,
    required this.optionCount,
    required this.missesBeforeHint,
  });

  static _LevelConfig forLevel(int level) {
    switch (level) {
      case 1:
        return const _LevelConfig(totalRounds: 4, optionCount: 2, missesBeforeHint: 1);
      case 3:
        return const _LevelConfig(totalRounds: 6, optionCount: 4, missesBeforeHint: 3);
      case 2:
      default:
        return const _LevelConfig(totalRounds: 5, optionCount: 3, missesBeforeHint: 2);
    }
  }
}

class FamiliarSoundGame extends StatefulWidget {
  const FamiliarSoundGame({super.key});

  @override
  State<FamiliarSoundGame> createState() => _FamiliarSoundGameState();
}

class _SoundItem {
  final String soundText;
  final String soundEmoji;
  final String pictureEmoji;
  const _SoundItem(this.soundText, this.soundEmoji, this.pictureEmoji);
}

class _FamiliarSoundGameState extends State<FamiliarSoundGame> {
  static const List<_SoundItem> _pool = [
    _SoundItem('DING DONG', '🔔', '🚪'),
    _SoundItem('RING RING', '📞', '☎️'),
    _SoundItem('MEOW', '🐾', '🐱'),
    _SoundItem('TICK TOCK', '⏱️', '🕐'),
    _SoundItem('BEEP BEEP', '🚗', '🚙'),
    _SoundItem('DRIP DRIP', '💧', '🚰'),
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
  int _correctFirstTry = 0;
  int _hintsUsedThisSession = 0;
  DateTime? _sessionStart;
  late _SoundItem _target;
  late List<String> _options;
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
      _correctFirstTry = 0;
      _hintsUsedThisSession = 0;
      _sessionStart = DateTime.now();
    });
    _setUpRound();
  }

  void _setUpRound() {
    final pool = List<_SoundItem>.from(_pool)..shuffle(_random);
    final target = pool[0];
    final options = [
      for (int i = 0; i < _config.optionCount; i++) pool[i].pictureEmoji,
    ]..shuffle(_random);

    setState(() {
      _target = target;
      _options = options;
      _wrongAttemptsThisRound = 0;
      _hintActive = false;
      _feedback = null;
    });
  }

  void _onOptionTap(String emoji) {
    if (emoji == _target.pictureEmoji) {
      if (_wrongAttemptsThisRound == 0) _correctFirstTry++;
      setState(() {
        _correctCount++;
        _feedback = 'That\'s it! 🎉';
      });
      Future.delayed(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        if (_roundIndex + 1 >= _config.totalRounds) {
          _finishGame();
        } else {
          setState(() => _roundIndex++);
          _setUpRound();
        }
      });
    } else {
      // Errorless learning: no hard fail. After a few misses, highlight
      // the correct picture as a vanishing cue.
      setState(() {
        _wrongAttemptsThisRound++;
        _feedback = 'Listen again — try another one!';
        if (_wrongAttemptsThisRound >= _config.missesBeforeHint && !_hintActive) {
          _hintActive = true;
          _hintsUsedThisSession++;
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
          // ACCURACY: _correctFirstTry (not _correctCount, which always ends
          // up equal to totalRounds under errorless design) is the real
          // struggle signal — see memory_matching_game.dart's identical note.
          _level = await _difficultyService.recordSessionAndAdapt(
            sessionId: '${uid}_${_gameId}_${_sessionStart!.millisecondsSinceEpoch}',
            patientId: uid,
            gameId: _gameId,
            gameSet: _gameSet,
            difficultyLevel: _level,
            totalItems: _config.totalRounds,
            correctItems: _correctFirstTry,
            hintsUsed: _hintsUsedThisSession,
            durationSeconds: DateTime.now().difference(_sessionStart!).inSeconds,
            metricType: GameMetricType.firstAttempt,
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
          'You matched $_correctCount of ${_config.totalRounds} sounds to their '
          'pictures.\n\nYou earned $pointsEarned points!',
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
                _correctFirstTry = 0;
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
        title: const Text('What Made That Sound?', style: TextStyle(color: Colors.white)),
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
              'Round ${_roundIndex + 1} of ${_config.totalRounds}',
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
              'You hear:',
              style: TextStyle(fontSize: 16, color: Colors.white),
            ),
            const SizedBox(height: 16),
            Center(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 24),
                decoration: BoxDecoration(
                  color: AppColors.cardPurple,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Text(_target.soundEmoji, style: const TextStyle(fontSize: 48)),
                    const SizedBox(height: 10),
                    Text(
                      _target.soundText,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Which picture made that sound?',
              style: TextStyle(fontSize: 14, color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: _options.map((emoji) {
                final bool isHint = _hintActive && emoji == _target.pictureEmoji;
                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _onOptionTap(emoji),
                  child: Container(
                    width: 90,
                    height: 90,
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
                    child: Text(emoji, style: const TextStyle(fontSize: 42)),
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
