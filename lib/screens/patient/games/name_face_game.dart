import 'dart:math';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/models/game_difficulty.dart';
import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// AD-MIDDLE game (see claude_code_four_game_sets_prompt.md): reminiscence
/// + recognition memory — show a familiar face/photo, patient recognizes
/// (not recalls) the matching name from a few large options, with a
/// partially-obscured name giving a vanishing cue. Recognition memory is
/// the domain most impaired in AD specifically (Frontiers in Aging
/// Neuroscience, 2023), so name-face recognition targets that deficit
/// directly; Regier et al. (2017, The Gerontologist) find reminiscence/
/// recognition activities suit the middle stage generally, and Lee et al.
/// (2018) include name–face matching as a curriculum item. This is the
/// EXISTING "Who Is This?" game (originally built as a generic
/// Middle-Stage game, then retagged AD-Middle #2 under the 4-set split —
/// no near-duplicate was built) — shown only in the AD-Middle set.
///
/// DEPENDENCY NOTE: MindCare has no caregiver photo-upload feature yet, so
/// this uses placeholder family-role emoji + name pairs (see [_people])
/// standing in for real caregiver-uploaded photo+name pairs. Swap
/// [_people] for real patient-specific data once an upload feature exists
/// — the game logic below doesn't need to change, only the data source.
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3), migrated once from the old
/// caregiver-set [GameDifficultyTier] (foundations→1, standard→2,
/// challenge→3) — see [_NameFaceGameState._loadLevelAndStart].
const String _gameId = 'name_face';
const String _gameSet = 'ad_middle';

class NameFaceGame extends StatefulWidget {
  const NameFaceGame({super.key});

  @override
  State<NameFaceGame> createState() => _NameFaceGameState();
}

class _Pair {
  final String emoji;
  final String name;
  int wrongAttempts = 0;
  _Pair(this.emoji, this.name);
}

class _TierConfig {
  final int pairCount;
  final double hideFraction; // fraction of letters obscured, before misses
  final int pointsPerPair;

  const _TierConfig({
    required this.pairCount,
    required this.hideFraction,
    required this.pointsPerPair,
  });

  static _TierConfig forLevel(int level) {
    switch (level) {
      case 1:
        // Fewer pairs, most letters shown (strong cue).
        return const _TierConfig(pairCount: 3, hideFraction: 0.25, pointsPerPair: 3);
      case 3:
        // More pairs, name almost fully hidden (minimal cueing).
        return const _TierConfig(pairCount: 8, hideFraction: 0.85, pointsPerPair: 5);
      case 2:
      default:
        return const _TierConfig(pairCount: 5, hideFraction: 0.5, pointsPerPair: 4);
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

class _NameFaceGameState extends State<NameFaceGame> {
  // Placeholder photo+name pairs — see class doc comment.
  static const List<_PersonSeed> _people = [
    _PersonSeed('👵', 'GRANDMA'),
    _PersonSeed('👴', 'GRANDPA'),
    _PersonSeed('👩', 'MOTHER'),
    _PersonSeed('👨', 'FATHER'),
    _PersonSeed('👧', 'DAUGHTER'),
    _PersonSeed('👦', 'SON'),
    _PersonSeed('🧑', 'FRIEND'),
    _PersonSeed('👱‍♀️', 'SISTER'),
    _PersonSeed('🧔', 'BROTHER'),
    _PersonSeed('👩‍⚕️', 'NURSE'),
  ];

  final Random _random = Random();
  final FirestoreService _firestoreService = FirestoreService();
  final AdaptiveDifficultyService _difficultyService = AdaptiveDifficultyService();

  String? _uid;
  int _level = 1;
  late _TierConfig _config;
  bool _loadingTier = true;

  late List<_Pair> _queue;
  int _totalPairs = 0;
  int _correctFirstTry = 0;
  int _totalAttempts = 0;
  int _hintsUsedThisSession = 0; // each wrong attempt reveals more letters
  DateTime? _sessionStart;
  List<String> _options = [];
  String? _feedback;
  bool _answering = true;

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
    if (!mounted) return;
    setState(() => _loadingTier = false);
    _setUpGame();
  }

  void _setUpGame() {
    final chosen = List<_PersonSeed>.from(_people)..shuffle(_random);
    final pairs = chosen
        .take(_config.pairCount)
        .map((p) => _Pair(p.emoji, p.name))
        .toList();

    setState(() {
      _queue = pairs;
      _totalPairs = pairs.length;
      _correctFirstTry = 0;
      _totalAttempts = 0;
      _hintsUsedThisSession = 0;
      _sessionStart = DateTime.now();
      _answering = true;
      _feedback = null;
    });
    _prepareRound();
  }

  void _prepareRound() {
    final current = _queue.first;

    final distractorPool = _people
        .where((p) => p.name != current.name)
        .map((p) => p.name)
        .toList()
      ..shuffle(_random);
    final options = [current.name, ...distractorPool.take(2)]..shuffle(_random);

    setState(() {
      _options = options;
      _feedback = null;
      _answering = true;
    });
  }

  /// Vanishing cue: reveals more letters after each wrong attempt on this
  /// pair (de Werd et al., 2013) — support increases right when it's
  /// needed, rather than the patient hitting a hard dead end.
  String _obscure(_Pair pair) {
    final double hideFraction =
        (_config.hideFraction - pair.wrongAttempts * 0.25).clamp(0.0, 1.0);
    final chars = pair.name.split('');
    final int hideCount = (chars.length * hideFraction).round();
    final indices = List.generate(chars.length, (i) => i)..shuffle(_random);
    final hiddenSet = indices.take(hideCount).toSet();
    return List.generate(
      chars.length,
      (i) => hiddenSet.contains(i) ? '_' : chars[i],
    ).join();
  }

  void _onOptionTap(String option) {
    if (!_answering) return;
    final current = _queue.first;
    _totalAttempts++;

    if (option == current.name) {
      final bool firstTry = current.wrongAttempts == 0;
      if (firstTry) _correctFirstTry++;

      setState(() {
        _answering = false;
        _feedback = 'That\'s right! 🎉';
      });

      Future.delayed(const Duration(milliseconds: 900), () {
        if (!mounted) return;
        setState(() {
          _queue.removeAt(0);
        });
        if (_queue.isEmpty) {
          _finishGame();
        } else {
          _prepareRound();
        }
      });
    } else {
      // Errorless learning: never a dead end. Encourage, strengthen the
      // cue, and re-queue this pair sooner (spaced retrieval — Lee et al.,
      // 2018) rather than moving straight on.
      setState(() {
        current.wrongAttempts++;
        _hintsUsedThisSession++;
        _feedback = "Not quite — here's a bit more help.";
        if (_queue.length > 1) {
          _queue.removeAt(0);
          _queue.insert(min(2, _queue.length), current);
        }
      });
      Future.delayed(const Duration(milliseconds: 900), () {
        if (!mounted) return;
        _prepareRound();
      });
    }
  }

  Future<void> _finishGame() async {
    final int pointsEarned = _totalPairs * _config.pointsPerPair;
    final String? uid = _uid;
    if (uid != null && pointsEarned > 0) {
      await _firestoreService.awardPoints(uid, pointsEarned);
    }
    if (uid != null && _sessionStart != null) {
      // correctFirstTry/totalPairs (not "eventually got every pair
      // right," which the errorless design guarantees) is the real
      // struggle signal — see memory_matching_game.dart's identical note.
      _level = await _difficultyService.recordSessionAndAdapt(
        sessionId: '${uid}_${_gameId}_${_sessionStart!.millisecondsSinceEpoch}',
        patientId: uid,
        gameId: _gameId,
        gameSet: _gameSet,
        difficultyLevel: _level,
        totalItems: _totalPairs,
        correctItems: _correctFirstTry,
        hintsUsed: _hintsUsedThisSession,
        durationSeconds: DateTime.now().difference(_sessionStart!).inSeconds,
      );
      _config = _TierConfig.forLevel(_level);
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardPurple,
        title: const Text('All done! 🎉', style: TextStyle(color: Colors.white)),
        content: Text(
          'You recognized all $_totalPairs faces in $_totalAttempts tries '
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
        title: const Text('Who Is This?', style: TextStyle(color: Colors.white)),
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
                  Text(
                    '${_totalPairs - _queue.length + 1} of $_totalPairs',
                    style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
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
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      _queue.first.emoji,
                      // Enlarged from 96 — middle-stage cueing needs a
                      // bigger, easier-to-see photo target.
                      style: const TextStyle(fontSize: 120),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      _obscure(_queue.first),
                      style: const TextStyle(
                        fontSize: 26,
                        letterSpacing: 4,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Who is this?',
                      style: const TextStyle(fontSize: 14, color: AppColors.textMuted),
                    ),
                  ),
                  if (_feedback != null) ...[
                    const SizedBox(height: 12),
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
                  ],
                  const SizedBox(height: 28),
                  ..._options.map((option) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () => _onOptionTap(option),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: AppColors.cardPurpleLight),
                            // Enlarged from vertical:16/fontSize:16 — larger
                            // touch targets for the middle-stage set.
                            padding: const EdgeInsets.symmetric(vertical: 22),
                            backgroundColor: AppColors.cardPurple,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          child: Text(option),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
    );
  }
}

class _PersonSeed {
  final String emoji;
  final String name;
  const _PersonSeed(this.emoji, this.name);
}
