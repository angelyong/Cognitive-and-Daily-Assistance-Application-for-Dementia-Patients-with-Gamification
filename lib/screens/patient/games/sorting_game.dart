import 'dart:math';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// VaD-MIDDLE game "Color/Shape Sorting" (see
/// claude_code_four_game_sets_prompt.md): a sorting/manipulation task —
/// one item at a time, patient taps which of two large bins it belongs to.
/// Sorting by a single perceptual attribute (color or shape, rather than
/// semantic category) is a purer executive-function/rule-application task
/// — the domain most impaired in Vascular Dementia specifically — than
/// category sorting is; Ji et al. (2024) find this kind of executive-
/// function-targeted sorting training beneficial for VaD. Regier et al.
/// (2017, The Gerontologist) separately find manipulation/sorting
/// activities like this suit the middle stage generally — shown only in
/// the VaD-Middle set. Previously a generic Middle-Stage game sorting by
/// semantic category (fruits vs. animals, etc.); item pool changed here to
/// color/shape attributes to sharpen the executive-function targeting for
/// the VaD-Middle retag.
///
/// Middle-stage requirements applied here: short session, no timer/time
/// pressure, very forgiving (a wrong bin tap just asks the patient to try
/// the other one — no penalty, no round lost), and large touch-target bin
/// buttons.
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3) — this game had no
/// [GameDifficultyTier] integration before, so a patient with no
/// difficultyState doc yet simply starts at level 1. Level scales the
/// number of items sorted per side, per Ortega Morán et al. (2024).
const String _gameId = 'sorting';
const String _gameSet = 'vad_middle';

class _LevelConfig {
  final int itemsPerSide;
  const _LevelConfig({required this.itemsPerSide});

  static _LevelConfig forLevel(int level) {
    switch (level) {
      case 1:
        return const _LevelConfig(itemsPerSide: 2);
      case 3:
        return const _LevelConfig(itemsPerSide: 4);
      case 2:
      default:
        return const _LevelConfig(itemsPerSide: 3);
    }
  }
}

class SortingGame extends StatefulWidget {
  const SortingGame({super.key});

  @override
  State<SortingGame> createState() => _SortingGameState();
}

class _CategoryPair {
  final String nameA;
  final List<String> itemsA;
  final String nameB;
  final List<String> itemsB;
  const _CategoryPair(this.nameA, this.itemsA, this.nameB, this.itemsB);
}

class _SortItem {
  final String emoji;
  final bool belongsToA;
  const _SortItem(this.emoji, this.belongsToA);
}

class _SortingGameState extends State<SortingGame> {
  static const List<_CategoryPair> _pairs = [
    _CategoryPair(
      'Red Things', ['🍎', '🍓', '🌹', '🍒'],
      'Blue Things', ['🫐', '💙', '🔵', '🔷'],
    ),
    _CategoryPair(
      'Circles', ['🔴', '🟠', '⚪', '🔵'],
      'Squares', ['🟥', '🟧', '⬜', '🟦'],
    ),
    _CategoryPair(
      'Yellow Things', ['🌻', '🍋', '🟡', '🍌'],
      'Green Things', ['🍏', '🍀', '🟢', '🥦'],
    ),
  ];

  final Random _random = Random();
  final FirestoreService _firestoreService = FirestoreService();
  final AdaptiveDifficultyService _difficultyService = AdaptiveDifficultyService();

  String? _uid;
  int _level = 1;
  late _LevelConfig _config;
  bool _loadingLevel = true;

  late _CategoryPair _pair;
  late List<_SortItem> _queue;
  int _totalItems = 0;
  int _totalWrongTapsSession = 0;
  int _hintsUsedThisSession = 0;
  DateTime? _sessionStart;
  String? _feedback;
  bool _hintActive = false;

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
    _pair = _pairs[_random.nextInt(_pairs.length)];
    final items = [
      for (int i = 0; i < _config.itemsPerSide; i++) _SortItem(_pair.itemsA[i], true),
      for (int i = 0; i < _config.itemsPerSide; i++) _SortItem(_pair.itemsB[i], false),
    ]..shuffle(_random);

    setState(() {
      _queue = items;
      _totalItems = items.length;
      _totalWrongTapsSession = 0;
      _hintsUsedThisSession = 0;
      _sessionStart = DateTime.now();
      _feedback = null;
      _hintActive = false;
    });
  }

  void _onBinTap(bool tappedA) {
    final current = _queue.first;

    if (tappedA == current.belongsToA) {
      setState(() => _feedback = 'Correct! 🎉');
      Future.delayed(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        setState(() {
          _queue.removeAt(0);
          _hintActive = false;
        });
        if (_queue.isEmpty) {
          _finishGame();
        } else {
          setState(() => _feedback = null);
        }
      });
    } else {
      // Very forgiving: no penalty, just point toward the other bin. Count
      // a hint only on the transition into hint-active state, matching the
      // convention used elsewhere.
      final bool isNewHint = !_hintActive;
      setState(() {
        _totalWrongTapsSession++;
        _feedback = 'Try the other one!';
        _hintActive = true;
        if (isNewHint) _hintsUsedThisSession++;
      });
    }
  }

  Future<void> _finishGame() async {
    const int pointsPerItem = 3;
    final int pointsEarned = _totalItems * pointsPerItem;
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
          // ACCURACY: total taps (correct + wrong), not just items sorted
          // (always equals _totalItems under errorless design) — see
          // memory_matching_game.dart's identical note.
          final int totalTaps = _totalItems + _totalWrongTapsSession;
          _level = await _difficultyService.recordSessionAndAdapt(
            sessionId: '${uid}_${_gameId}_${_sessionStart!.millisecondsSinceEpoch}',
            patientId: uid,
            gameId: _gameId,
            gameSet: _gameSet,
            difficultyLevel: _level,
            totalItems: totalTaps,
            correctItems: _totalItems,
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
        title: const Text('All sorted! 🎉', style: TextStyle(color: Colors.white)),
        content: Text(
          'You sorted all $_totalItems items into ${_pair.nameA} and ${_pair.nameB}.\n\n'
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
        title: const Text('Sort It Out', style: TextStyle(color: Colors.white)),
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
              '${_totalItems - _queue.length + 1} of $_totalItems',
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
              'Which group does this belong to?',
              style: TextStyle(fontSize: 16, color: Colors.white),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: Center(
                child: Text(
                  _queue.first.emoji,
                  style: const TextStyle(fontSize: 120),
                ),
              ),
            ),
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
              children: [
                Expanded(child: _binButton(_pair.nameA, isA: true)),
                const SizedBox(width: 16),
                Expanded(child: _binButton(_pair.nameB, isA: false)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _binButton(String label, {required bool isA}) {
    final bool isHint = _hintActive && _queue.first.belongsToA == isA;
    return ElevatedButton(
      onPressed: () => _onBinTap(isA),
      style: ElevatedButton.styleFrom(
        backgroundColor: isHint ? AppColors.orangeStart : AppColors.cardPurple,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 26),
        side: BorderSide(
          color: isHint ? AppColors.orangeStart : AppColors.cardPurpleLight,
          width: isHint ? 3 : 1,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      child: Text(label, textAlign: TextAlign.center),
    );
  }
}
