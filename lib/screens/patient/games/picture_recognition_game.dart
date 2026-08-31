import 'dart:math';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/models/game_session.dart';
import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// AD-MIDDLE game (see claude_code_four_game_sets_prompt.md): recognition,
/// not recall — a word names the target ("apple") and the patient picks
/// the matching picture from a small set of large option buttons.
/// Recognition memory specifically is significantly more impaired in
/// Alzheimer's Disease than in Vascular Dementia (Frontiers in Aging
/// Neuroscience, 2023, βg = −0.76), making this a targeted AD exercise
/// rather than a generic middle-stage one. Regier et al. (2017, The
/// Gerontologist) separately find recognition/sensory activities like this
/// suit the middle stage generally — shown only in the AD-Middle set
/// (previously shown to all Middle-stage patients regardless of type,
/// before the 4-set AD/VaD split).
///
/// Design note: the doc's brief describes "a target image + options"; this
/// implementation names the target in text and asks the patient to
/// recognize/point to the matching picture among 2–3 options, which is the
/// simpler, unambiguous version of the same recognition test (picking the
/// right picture, not matching two pictures).
///
/// Middle-stage requirements applied here: short (5-round) session, no
/// timer/time pressure, large touch-target option buttons, and stronger,
/// more persistent cueing than the early-stage games — a wrong tap keeps
/// the cue (a highlighted correct option) visible until answered correctly,
/// rather than a brief flash.
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3, level→round/option-count
/// mapping follows Ortega Morán et al., 2024) — this game had no
/// [GameDifficultyTier] integration before, so there's no old tier to
/// migrate; a patient with no difficultyState doc yet simply starts at
/// level 1, per the engine's own default.
const String _gameId = 'picture_recognition';
const String _gameSet = 'ad_middle';

class _LevelConfig {
  final int totalRounds;
  final int distractorCount;

  const _LevelConfig({required this.totalRounds, required this.distractorCount});

  static _LevelConfig forLevel(int level) {
    switch (level) {
      case 1:
        return const _LevelConfig(totalRounds: 4, distractorCount: 1);
      case 3:
        return const _LevelConfig(totalRounds: 6, distractorCount: 3);
      case 2:
      default:
        return const _LevelConfig(totalRounds: 5, distractorCount: 2);
    }
  }
}

class PictureRecognitionGame extends StatefulWidget {
  const PictureRecognitionGame({super.key});

  @override
  State<PictureRecognitionGame> createState() => _PictureRecognitionGameState();
}

class _Item {
  final String emoji;
  final String name;
  const _Item(this.emoji, this.name);
}

class _PictureRecognitionGameState extends State<PictureRecognitionGame> {
  static const List<_Item> _pool = [
    _Item('🍎', 'apple'),
    _Item('🐶', 'dog'),
    _Item('🚗', 'car'),
    _Item('🌞', 'sun'),
    _Item('🏠', 'house'),
    _Item('🐱', 'cat'),
    _Item('🌳', 'tree'),
    _Item('🎈', 'balloon'),
    _Item('🐟', 'fish'),
    _Item('⭐', 'star'),
  ];

  final Random _random = Random();
  final FirestoreService _firestoreService = FirestoreService();
  final AdaptiveDifficultyService _difficultyService = AdaptiveDifficultyService();

  String? _uid;
  int _level = 1;
  late _LevelConfig _config;
  bool _loadingLevel = true;

  late List<_Item> _queue;
  late _Item _current;
  List<_Item> _options = [];
  int _wrongAttemptsThisRound = 0;
  bool _hintActive = false;
  String? _feedback;
  int _correctFirstTry = 0;
  int _hintsUsedThisSession = 0;
  DateTime? _sessionStart;

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
    final shuffled = List<_Item>.from(_pool)..shuffle(_random);
    setState(() {
      _queue = shuffled.take(_config.totalRounds).toList();
      _correctFirstTry = 0;
      _hintsUsedThisSession = 0;
      _sessionStart = DateTime.now();
    });
    _prepareRound();
  }

  void _prepareRound() {
    _current = _queue.first;
    final distractorPool = _pool.where((i) => i.name != _current.name).toList()
      ..shuffle(_random);
    final options = [_current, ...distractorPool.take(_config.distractorCount)]
      ..shuffle(_random);

    setState(() {
      _options = options;
      _wrongAttemptsThisRound = 0;
      _hintActive = false;
      _feedback = null;
    });
  }

  void _onOptionTap(_Item option) {
    if (option.name == _current.name) {
      if (_wrongAttemptsThisRound == 0) _correctFirstTry++;
      setState(() => _feedback = 'That\'s it! 🎉');
      Future.delayed(const Duration(milliseconds: 800), () {
        if (!mounted) return;
        setState(() => _queue.removeAt(0));
        if (_queue.isEmpty) {
          _finishGame();
        } else {
          _prepareRound();
        }
      });
    } else {
      // Errorless + persistent cueing: the hint stays on screen (not a
      // brief flash) until the patient finds the right picture. Counted
      // as a hint once per round (the transition into hint-active), not
      // once per wrong tap while it's already showing.
      final bool isNewHint = !_hintActive;
      setState(() {
        _wrongAttemptsThisRound++;
        _feedback = "Not quite — here's a hint.";
        _hintActive = true;
        if (isNewHint) _hintsUsedThisSession++;
      });
    }
  }

  Future<void> _finishGame() async {
    const int pointsPerRound = 4;
    final int pointsEarned = _config.totalRounds * pointsPerRound;
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
          // ACCURACY: _correctFirstTry (not totalRounds, which always equals
          // itself since every round eventually succeeds under errorless
          // design) is the real struggle signal — see memory_matching_game.dart's
          // identical note.
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
        title: const Text('Well done! 🎉', style: TextStyle(color: Colors.white)),
        content: Text(
          'You found all ${_config.totalRounds} pictures '
          '($_correctFirstTry correct on the first try).\n\n'
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
        title: const Text('Picture Match', style: TextStyle(color: Colors.white)),
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
              '${_config.totalRounds - _queue.length + 1} of ${_config.totalRounds}',
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
            const SizedBox(height: 20),
            Center(
              child: Text.rich(
                TextSpan(
                  text: 'Which one is the ',
                  style: const TextStyle(fontSize: 22, color: Colors.white),
                  children: [
                    TextSpan(
                      text: _current.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppColors.orangeStart,
                      ),
                    ),
                    const TextSpan(text: '?'),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            if (_feedback != null)
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
            const SizedBox(height: 24),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                children: _options.map((option) {
                  final bool isHint = _hintActive && option.name == _current.name;
                  return InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _onOptionTap(option),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isHint
                            ? AppColors.orangeStart.withOpacity(0.20)
                            : AppColors.cardPurple,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isHint
                              ? AppColors.orangeStart
                              : AppColors.cardPurpleLight,
                          width: isHint ? 3 : 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(option.emoji, style: const TextStyle(fontSize: 64)),
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
