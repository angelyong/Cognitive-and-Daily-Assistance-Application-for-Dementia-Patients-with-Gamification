import 'dart:math';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// VaD-EARLY game, 2nd slot (see claude_code_four_game_sets_prompt.md): a
/// letter is named and the patient taps every word on screen that starts
/// with it, mixed in among words starting with other letters — a
/// phonemic-fluency task. Phonemic fluency (finding words by starting
/// SOUND, as opposed to semantic fluency's finding words by MEANING/
/// category) is the fluency subtype more specifically impaired in
/// Vascular Dementia (Frontiers in Aging Neuroscience, 2023;
/// Olmos-Villaseñor et al., 2023, find phonemic fluency the
/// VaD-distinguishing deficit, the mirror of AD's semantic-fluency
/// deficit exercised by Category Naming). NEW game built for this task.
///
/// Errorless design: tapping a non-matching word is never a hard fail —
/// it's met with encouragement that names the tapped word's actual
/// starting letter ("This starts with D, try another"), then after
/// repeated misses a correct word is highlighted as a vanishing cue.
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3) — this game had no
/// [GameDifficultyTier] integration before, so a patient with no
/// difficultyState doc yet simply starts at level 1. Only 3 letter-rounds
/// are authored, so round COUNT can only scale down (fewer rounds at
/// level 1), not up; the hint threshold (misses before a vanishing cue)
/// is the level axis that actually differentiates level 2 from level 3 —
/// per Ortega Morán et al. (2024).
const String _gameId = 'letter_fluency';
const String _gameSet = 'vad_early';

class _LevelConfig {
  final int roundCount;
  final int missesBeforeHint;
  const _LevelConfig({required this.roundCount, required this.missesBeforeHint});

  static _LevelConfig forLevel(int level) {
    switch (level) {
      case 1:
        return const _LevelConfig(roundCount: 2, missesBeforeHint: 1);
      case 3:
        return const _LevelConfig(roundCount: 3, missesBeforeHint: 2);
      case 2:
      default:
        return const _LevelConfig(roundCount: 3, missesBeforeHint: 1);
    }
  }
}

class LetterFluencyGame extends StatefulWidget {
  const LetterFluencyGame({super.key});

  @override
  State<LetterFluencyGame> createState() => _LetterFluencyGameState();
}

class _LetterRound {
  final String letter;
  final List<String> matchingWords;
  final List<String> distractorWords;
  const _LetterRound(this.letter, this.matchingWords, this.distractorWords);
}

class _WordTile {
  final String word;
  final bool matches;
  bool found = false;
  _WordTile(this.word, this.matches);
}

class _LetterFluencyGameState extends State<LetterFluencyGame> {
  static const List<_LetterRound> _rounds = [
    _LetterRound(
      'B',
      ['Ball', 'Banana', 'Bed', 'Book'],
      ['Apple', 'Chair', 'Dog', 'Fish'],
    ),
    _LetterRound(
      'S',
      ['Sun', 'Spoon', 'Shoe', 'Star'],
      ['Table', 'Moon', 'Cup', 'Kite'],
    ),
    _LetterRound(
      'C',
      ['Cat', 'Cup', 'Chair', 'Car'],
      ['Dog', 'Ball', 'Hat', 'Pen'],
    ),
  ];

  final Random _random = Random();
  final FirestoreService _firestoreService = FirestoreService();
  final AdaptiveDifficultyService _difficultyService = AdaptiveDifficultyService();

  String? _uid;
  int _level = 1;
  late _LevelConfig _config;
  bool _loadingLevel = true;

  int _roundIndex = 0;
  int _totalFound = 0;
  int _totalWrongTapsSession = 0;
  int _hintsUsedThisSession = 0;
  DateTime? _sessionStart;
  late List<_WordTile> _tiles;
  int _matchesFoundThisRound = 0;
  int _matchesNeededThisRound = 0;
  int _wrongTapsThisRound = 0;
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
      _totalFound = 0;
      _totalWrongTapsSession = 0;
      _hintsUsedThisSession = 0;
      _sessionStart = DateTime.now();
    });
    _setUpRound();
  }

  void _setUpRound() {
    final round = _rounds[_roundIndex];
    final tiles = [
      ...round.matchingWords.map((w) => _WordTile(w, true)),
      ...round.distractorWords.map((w) => _WordTile(w, false)),
    ]..shuffle(_random);

    setState(() {
      _tiles = tiles;
      _matchesFoundThisRound = 0;
      _matchesNeededThisRound = round.matchingWords.length;
      _wrongTapsThisRound = 0;
      _hintActive = false;
      _feedback = null;
    });
  }

  void _onTileTap(_WordTile tile) {
    if (tile.found) return;

    if (tile.matches) {
      setState(() {
        tile.found = true;
        _matchesFoundThisRound++;
        _totalFound++;
        _hintActive = false;
        _feedback = 'Yes! ✅';
      });
      if (_matchesFoundThisRound >= _matchesNeededThisRound) {
        Future.delayed(const Duration(milliseconds: 600), () {
          if (!mounted) return;
          if (_roundIndex + 1 >= _config.roundCount) {
            _finishGame();
          } else {
            setState(() => _roundIndex++);
            _setUpRound();
          }
        });
      }
    } else {
      // Errorless learning: no hard fail — name the actual starting
      // letter of the word tapped, then after a level-scaled number of
      // misses highlight an unfound match as a vanishing cue.
      final bool isNewHint = !_hintActive;
      setState(() {
        _wrongTapsThisRound++;
        _totalWrongTapsSession++;
        _feedback = 'This starts with "${tile.word[0]}" — try another!';
        if (_wrongTapsThisRound >= _config.missesBeforeHint) {
          _hintActive = true;
          if (isNewHint) _hintsUsedThisSession++;
        }
      });
    }
  }

  Future<void> _finishGame() async {
    const int pointsPerMatch = 3;
    final int pointsEarned = _totalFound * pointsPerMatch;
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
        if (_sessionStart != null) {
          // ACCURACY: total taps (correct matches + wrong distractor taps),
          // not just matches found (which always equals the round's total
          // under errorless design) — see memory_matching_game.dart's
          // identical note.
          final int totalTaps = _totalFound + _totalWrongTapsSession;
          _level = await _difficultyService.recordSessionAndAdapt(
            sessionId: '${uid}_${_gameId}_${_sessionStart!.millisecondsSinceEpoch}',
            patientId: uid,
            gameId: _gameId,
            gameSet: _gameSet,
            difficultyLevel: _level,
            totalItems: totalTaps,
            correctItems: _totalFound,
            hintsUsed: _hintsUsedThisSession,
            durationSeconds: DateTime.now().difference(_sessionStart!).inSeconds,
          );
          _config = _LevelConfig.forLevel(_level);
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
        title: const Text('All done! 🎉', style: TextStyle(color: Colors.white)),
        content: Text(
          'You found $_totalFound matching words across all rounds.\n\n'
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
              setState(() {
                _roundIndex = 0;
                _totalFound = 0;
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
    if (_loadingLevel) {
      return Scaffold(
        backgroundColor: AppColors.bgDark,
        appBar: AppBar(
          title: const Text('Letter Search', style: TextStyle(color: Colors.white)),
          backgroundColor: AppColors.bgDark,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: const Center(
          child: CircularProgressIndicator(color: AppColors.orangeStart),
        ),
      );
    }
    final round = _rounds[_roundIndex];
    return Scaffold(
      backgroundColor: AppColors.bgDark,
      appBar: AppBar(
        title: const Text('Letter Search', style: TextStyle(color: Colors.white)),
        backgroundColor: AppColors.bgDark,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
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
            RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 16, color: Colors.white),
                children: [
                  const TextSpan(text: 'Tap all words starting with '),
                  TextSpan(
                    text: round.letter,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppColors.orangeStart,
                      fontSize: 20,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$_matchesFoundThisRound of $_matchesNeededThisRound found',
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            if (_feedback != null) ...[
              Text(
                _feedback!,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.orangeStart,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 2.2,
                children: _tiles.map((tile) {
                  final bool isHint = _hintActive && tile.matches && !tile.found;
                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _onTileTap(tile),
                    child: Container(
                      decoration: BoxDecoration(
                        color: tile.found
                            ? AppColors.greenCheck.withOpacity(0.18)
                            : isHint
                                ? AppColors.orangeStart.withOpacity(0.15)
                                : AppColors.cardPurple,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: tile.found
                              ? AppColors.greenCheck
                              : isHint
                                  ? AppColors.orangeStart
                                  : AppColors.cardPurpleLight,
                          width: isHint || tile.found ? 2.5 : 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        tile.word,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
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
