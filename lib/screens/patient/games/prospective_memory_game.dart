import 'dart:math';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/models/game_difficulty.dart';
import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// Prospective memory game: the patient is given an instruction up front
/// ("remember to act when you see X"), then does an unrelated simple
/// filler task, and must remember to act on the earlier instruction when
/// the trigger appears — without being reminded again (except on
/// Foundations tier).
///
/// This directly mirrors MindCare's core task-reminder feature: a
/// caregiver sets a task now that the patient must remember to act on
/// later, exactly the cognitive skill this game exercises. Unlike the
/// app's real reminders it isn't a push notification, but the underlying
/// memory demand — "remember a deferred intention while doing something
/// else" — is the same one MindCare's reminder system exists to support.
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3), migrated once from the old
/// caregiver-set [GameDifficultyTier] (foundations→1, standard→2,
/// challenge→3) — see [_ProspectiveMemoryGameState._loadLevelAndStart].
///
/// AD-EARLY game, 4th slot in that set (see
/// claude_code_four_game_sets_prompt.md): the 4-set AD/VaD doc doesn't
/// mention this game at all — it predates that doc, same as it predated
/// the earlier two-stage split. Placed in AD-Early as an explicit scope
/// decision (not a literature-mandated placement from either doc):
/// remembering a deferred intention is fundamentally an episodic-memory
/// task, and episodic memory is the domain most impaired early in
/// Alzheimer's Disease specifically (Frontiers in Aging Neuroscience,
/// 2023) — a closer fit to AD than to VaD's executive-function profile.
/// Regier et al. (2017) separately associate multi-step recall tasks like
/// this with early-stage patients generally. AD-Early therefore has 4
/// games (Memory Matching, Category Naming, this, and the new
/// Word-Picture Pairing) rather than the doc's stated 3.
const String _gameId = 'prospective_memory';
const String _gameSet = 'ad_early';

class ProspectiveMemoryGame extends StatefulWidget {
  const ProspectiveMemoryGame({super.key});

  @override
  State<ProspectiveMemoryGame> createState() => _ProspectiveMemoryGameState();
}

enum _Phase { instruction, filler, finished }

class _TierConfig {
  final int fillerRoundsBeforeTrigger;
  final bool midSessionReminder;
  final int maxRetries;
  final int pointsForSuccess;

  const _TierConfig({
    required this.fillerRoundsBeforeTrigger,
    required this.midSessionReminder,
    required this.maxRetries,
    required this.pointsForSuccess,
  });

  static _TierConfig forLevel(int level) {
    switch (level) {
      case 1:
        // Short interval before the trigger, a mid-session reminder, and
        // extra retries if missed — maximum support.
        return const _TierConfig(
          fillerRoundsBeforeTrigger: 3,
          midSessionReminder: true,
          maxRetries: 2,
          pointsForSuccess: 8,
        );
      case 3:
        // Long interval, no reminder, no retry — minimal support.
        return const _TierConfig(
          fillerRoundsBeforeTrigger: 10,
          midSessionReminder: false,
          maxRetries: 0,
          pointsForSuccess: 14,
        );
      case 2:
      default:
        return const _TierConfig(
          fillerRoundsBeforeTrigger: 6,
          midSessionReminder: false,
          maxRetries: 1,
          pointsForSuccess: 10,
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

class _ProspectiveMemoryGameState extends State<ProspectiveMemoryGame> {
  static const String _cueShape = '🔴';
  static const List<String> _shapePool = [
    '🟦', '🟩', '🟨', '🟪', '🟧', '🟫', '⬛', '⬜', '🔷', '🔶',
  ];

  final Random _random = Random();
  final FirestoreService _firestoreService = FirestoreService();
  final AdaptiveDifficultyService _difficultyService = AdaptiveDifficultyService();

  String? _uid;
  int _level = 1;
  late _TierConfig _config;
  bool _loadingTier = true;

  _Phase _phase = _Phase.instruction;
  int _fillerRoundIndex = 0;
  int _retriesLeft = 0;
  int _falseAlarms = 0;
  bool _showMidReminder = false;
  int _hintsUsedThisSession = 0; // mid-session reminder + each retry reminder
  DateTime? _sessionStart;

  String _target = '';
  List<String> _options = [];
  bool _isTriggerRoundActive = false;
  String? _message;

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
    setState(() {
      _loadingTier = false;
      _retriesLeft = _config.maxRetries;
    });
  }

  void _startFillerPhase() {
    setState(() {
      _phase = _Phase.filler;
      _fillerRoundIndex = 0;
      _falseAlarms = 0;
      _hintsUsedThisSession = 0;
      _sessionStart = DateTime.now();
    });
    _setUpFillerRound();
  }

  void _setUpFillerRound() {
    final bool isTrigger =
        _fillerRoundIndex == _config.fillerRoundsBeforeTrigger;
    final bool midReminder = _config.midSessionReminder &&
        _fillerRoundIndex == (_config.fillerRoundsBeforeTrigger / 2).round();

    final pool = List<String>.from(_shapePool)..shuffle(_random);
    final target = pool[0];
    final options = [target, pool[1], pool[2], isTrigger ? _cueShape : pool[3]]
      ..shuffle(_random);

    setState(() {
      _target = target;
      _options = options;
      _isTriggerRoundActive = isTrigger;
      if (midReminder && !_showMidReminder) _hintsUsedThisSession++;
      _showMidReminder = midReminder;
      _message = null;
    });
  }

  void _onStarTap() {
    if (_isTriggerRoundActive) {
      _finishGame(succeeded: true);
    } else {
      // False alarm: no penalty, just a gentle redirect — errorless
      // learning applies here too, not just to the "real" tasks.
      setState(() {
        _falseAlarms++;
        _message = 'Not yet — keep watching for the red circle!';
      });
    }
  }

  void _onShapeTap(String shape) {
    if (_isTriggerRoundActive) {
      // Engaged with the filler task instead of the star — a miss.
      _onTriggerMissed();
      return;
    }
    setState(() => _fillerRoundIndex++);
    _setUpFillerRound();
  }

  void _onTriggerMissed() {
    if (_retriesLeft > 0) {
      setState(() {
        _retriesLeft--;
        _hintsUsedThisSession++;
      });
      _showReminderThenRetry();
    } else {
      _finishGame(succeeded: false);
    }
  }

  Future<void> _showReminderThenRetry() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardPurple,
        title: const Text('Quick reminder', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Remember: tap the ⭐ STAR when you see a 🔴 RED CIRCLE among the shapes.',
          style: TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.orangeStart,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _fillerRoundIndex = 0);
    _setUpFillerRound();
  }

  Future<void> _finishGame({required bool succeeded}) async {
    // Even a missed trigger earns partial credit — the framing stays
    // encouraging either way, never a bare "you failed".
    final int pointsEarned =
        succeeded ? _config.pointsForSuccess : (_config.pointsForSuccess / 2).round();

    final String? uid = _uid;
    if (uid != null && pointsEarned > 0) {
      await _firestoreService.awardPoints(uid, pointsEarned);
    }
    if (uid != null && _sessionStart != null) {
      // Single pass/fail event per session (not multiple items) — 1/1 on
      // success, 0/1 on a missed trigger.
      _level = await _difficultyService.recordSessionAndAdapt(
        sessionId: '${uid}_${_gameId}_${_sessionStart!.millisecondsSinceEpoch}',
        patientId: uid,
        gameId: _gameId,
        gameSet: _gameSet,
        difficultyLevel: _level,
        totalItems: 1,
        correctItems: succeeded ? 1 : 0,
        hintsUsed: _hintsUsedThisSession,
        durationSeconds: DateTime.now().difference(_sessionStart!).inSeconds,
      );
      _config = _TierConfig.forLevel(_level);
    }

    if (!mounted) return;
    setState(() => _phase = _Phase.finished);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardPurple,
        title: Text(
          succeeded ? 'You remembered! 🎉' : 'Good effort! 🙂',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          <String>[
            succeeded
                ? 'You remembered to tap the star exactly when the red '
                    'circle appeared.'
                : 'Remembering something for later while doing another '
                    "task is tricky — that's exactly what real reminders "
                    "help with. Let's practice again soon.",
            if (_falseAlarms > 0)
              '(Tapped the star $_falseAlarms time'
                  '${_falseAlarms == 1 ? '' : 's'} before the circle '
                  "appeared — that's okay, staying alert is the hard part!)",
            'You earned $pointsEarned points${succeeded ? '' : ' for trying'}!',
          ].join('\n\n'),
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
                _phase = _Phase.instruction;
                _retriesLeft = _config.maxRetries;
              });
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
        title: const Text('Remember This', style: TextStyle(color: Colors.white)),
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
              child: _phase == _Phase.instruction
                  ? _buildInstruction()
                  : _buildFiller(),
            ),
    );
  }

  Widget _buildInstruction() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Difficulty: ${_TierConfig.labelForLevel(_level)}',
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.orangeStart,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.cardPurple,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Remember this:',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Tap the ⭐ STAR when you see a 🔴 RED CIRCLE.',
                style: TextStyle(fontSize: 20, color: Colors.white),
              ),
              const SizedBox(height: 12),
              const Text(
                "You'll be doing a simple shape task first. Keep an eye "
                'out while you play!',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _startFillerPhase,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.orangeStart,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text("I'm Ready"),
          ),
        ),
      ],
    );
  }

  Widget _buildFiller() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_showMidReminder)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.orangeStart.withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.orangeStart),
            ),
            child: const Text(
              'Reminder: tap the star when you see a red circle!',
              style: TextStyle(color: AppColors.orangeStart, fontWeight: FontWeight.w600),
            ),
          ),
        const Text(
          'Tap the matching shape below:',
          style: TextStyle(fontSize: 14, color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        Center(child: Text(_target, style: const TextStyle(fontSize: 56))),
        const SizedBox(height: 20),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          children: _options.map((shape) {
            return InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _onShapeTap(shape),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.cardPurple,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.cardPurpleLight, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(shape, style: const TextStyle(fontSize: 40)),
              ),
            );
          }).toList(),
        ),
        if (_message != null) ...[
          const SizedBox(height: 16),
          Text(
            _message!,
            style: const TextStyle(color: AppColors.orangeStart, fontWeight: FontWeight.w600),
          ),
        ],
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _onStarTap,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.cardPurpleLight,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Text('⭐', style: TextStyle(fontSize: 20)),
            label: const Text('Tap the Star'),
          ),
        ),
      ],
    );
  }
}
