import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/models/dementia_profile.dart';
import 'package:testproject/models/reward_game.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';
import '../../widgets/SideDrawer.dart';
import 'games/category_naming_game.dart';
import 'games/familiar_sound_game.dart';
import 'games/guided_daily_steps_game.dart';
import 'games/letter_fluency_game.dart';
import 'games/memory_matching_game.dart';
import 'games/name_face_game.dart';
import 'games/odd_one_out_game.dart';
import 'games/picture_recognition_game.dart';
import 'games/prospective_memory_game.dart';
import 'games/sequencing_game.dart';
import 'games/sorting_game.dart';
import 'games/spot_the_difference_game.dart';
import 'games/word_picture_pairing_game.dart';
import 'reward_game_screen.dart';

/// Hub for the patient's cognitive games. Each card here is a short,
/// self-contained brain exercise — patients only, reached via the
/// "Cognitive Games" item in the drawer.
///
/// Per claude_code_four_game_sets_prompt.md, MindCare offers FOUR distinct
/// game sets — not the same games at different difficulty — crossing the
/// patient's [DementiaStage] (Early/Middle) with their [DementiaType]
/// (Alzheimer's/Vascular), each set targeting that type's specific
/// cognitive-deficit profile (Frontiers in Aging Neuroscience, 2023): AD
/// targets episodic memory / semantic fluency / recognition memory; VaD
/// targets executive function / phonemic fluency / attention. A patient
/// sees only their own type+stage's set — no caregiver preview toggle
/// (Design Decision, resolved by explicit user choice: skipped for now,
/// matching the precedent already set for the stage-only split).
class CognitiveExerciseScreen extends StatefulWidget {
  const CognitiveExerciseScreen({super.key});

  @override
  State<CognitiveExerciseScreen> createState() => _CognitiveExerciseScreenState();
}

class _CognitiveExerciseScreenState extends State<CognitiveExerciseScreen> {
  bool _loading = true;
  bool _profileMissing = false;
  DementiaStage? _stage;
  DementiaType? _type;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  /// Reads the raw Firestore fields directly (rather than going through
  /// FirestoreService's getPatientDementiaStage/getPatientDementiaType,
  /// which both silently default when a field is absent) so a genuinely
  /// unset profile can be told apart from a profile that's explicitly set
  /// to the default value, and shown the friendly "ask your caregiver"
  /// message the doc requires instead of quietly defaulting to one set.
  Future<void> _loadProfile() async {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _profileMissing = true;
      });
      return;
    }

    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final data = doc.data();
    final String? stageValue = data?[DementiaStageX.firestoreField] as String?;
    final String? typeValue = data?[DementiaTypeX.firestoreField] as String?;

    if (!mounted) return;
    if (stageValue == null || typeValue == null) {
      setState(() {
        _loading = false;
        _profileMissing = true;
      });
      return;
    }

    setState(() {
      _loading = false;
      _profileMissing = false;
      _stage = DementiaStageX.fromFirestore(stageValue);
      _type = DementiaTypeX.fromFirestore(typeValue);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDark,
      drawer: const SideDrawer(),
      appBar: AppBar(
        title: const Text('MindCare', style: TextStyle(color: Colors.white)),
        backgroundColor: AppColors.bgDark,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.orangeStart),
            )
          : _profileMissing
              ? _buildMissingProfileMessage()
              : _buildGameHub(),
    );
  }

  Widget _buildMissingProfileMessage() {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.psychology_outlined, color: AppColors.textMuted, size: 56),
          const SizedBox(height: 20),
          const Text(
            "Your caregiver hasn't set your profile yet — please ask them "
            'to update it in Manage Patient.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildGameHub() {
    final DementiaStage stage = _stage!;
    final DementiaType type = _type!;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Cognitive Games',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _buildBadge(stage.label, stage.color),
              const SizedBox(width: 8),
              _buildBadge(type.label, type.color),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Short games to help keep your mind active.',
            style: TextStyle(fontSize: 14, color: AppColors.textMuted),
          ),
          const SizedBox(height: 24),
          ..._gameCardsFor(type, stage),
          const SizedBox(height: 8),
          const Divider(color: AppColors.cardPurpleLight, height: 32),
          const Text(
            'Just for Fun',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 12),
          ..._buildRewardGameTiles(),
        ],
      ),
    );
  }

  /// GAMIFICATION ONLY — see reward_game_screen.dart's own doc comment.
  /// Deliberately visually separated (divider + its own "Just for Fun"
  /// label) from the evidence-based games above.
  ///
  /// GENERALISED (tiered_reward_games_prompt.md) from a single hardcoded
  /// tile into a render-over-[kRewardGames] loop — one points stream feeds
  /// all four tiles (not one stream per tile), and [kRewardGames]'s own
  /// ascending-threshold ordering (30/50/80/120) is used directly, so the
  /// patient sees a clear "what's next" progression without re-sorting here.
  List<Widget> _buildRewardGameTiles() {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const [];

    return [
      StreamBuilder<int>(
        stream: FirestoreService().watchPatientTotalPoints(uid),
        builder: (context, snapshot) {
          final int totalPoints = snapshot.data ?? 0;
          return Column(
            children: [
              for (final game in kRewardGames) ...[
                _RewardGameTile(game: game, totalPoints: totalPoints),
                const SizedBox(height: 16),
              ],
            ],
          );
        },
      ),
    ];
  }

  Widget _buildBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  /// Routes to 1 of 4 game sets — AD-Early / AD-Middle / VaD-Early /
  /// VaD-Middle — per claude_code_four_game_sets_prompt.md.
  List<Widget> _gameCardsFor(DementiaType type, DementiaStage stage) {
    final List<_GameCard> cards;
    if (type == DementiaType.alzheimers && stage == DementiaStage.early) {
      cards = _adEarlyCards();
    } else if (type == DementiaType.alzheimers && stage == DementiaStage.middle) {
      cards = _adMiddleCards();
    } else if (type == DementiaType.vascular && stage == DementiaStage.early) {
      cards = _vadEarlyCards();
    } else {
      cards = _vadMiddleCards();
    }

    final List<Widget> widgets = [];
    for (final card in cards) {
      widgets.add(card);
      widgets.add(const SizedBox(height: 16));
    }
    return widgets;
  }

  // AD-Early: 4 games — the doc's stated 3 plus Remember This (see class
  // doc comment and prospective_memory_game.dart's own doc comment for
  // why it's placed here).
  List<_GameCard> _adEarlyCards() => [
        _GameCard(
          emoji: '🧠',
          title: 'Memory Matching',
          description: 'Flip the cards two at a time and find every matching pair.',
          color: AppColors.greenCheck,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const MemoryMatchingGame()),
          ),
        ),
        _GameCard(
          emoji: '🍎',
          title: 'Category Naming',
          description:
              "You'll see a category, like Fruits. Tap every picture that belongs to it.",
          color: AppColors.orangeStart,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CategoryNamingGame()),
          ),
        ),
        _GameCard(
          emoji: '⭐',
          title: 'Remember This',
          description:
              'A short memory challenge — remember to act on a cue while doing something else.',
          color: AppColors.orangeEnd,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ProspectiveMemoryGame()),
          ),
        ),
        _GameCard(
          emoji: '📖',
          title: 'Word & Picture',
          description: "You'll see a word — tap the picture that matches it.",
          color: AppColors.categoryChipText,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const WordPicturePairingGame()),
          ),
        ),
      ];

  // AD-Middle: 3 games.
  List<_GameCard> _adMiddleCards() => [
        _GameCard(
          emoji: '🖼️',
          title: 'Picture Match',
          description: 'See the name and tap the picture that matches it.',
          color: AppColors.orangeStart,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PictureRecognitionGame()),
          ),
        ),
        _GameCard(
          emoji: '👵',
          title: 'Who Is This?',
          description:
              "See a photo and pick the right name — a little help is there if you need it.",
          color: AppColors.categoryChipText,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const NameFaceGame()),
          ),
        ),
        _GameCard(
          emoji: '🔔',
          title: 'What Made That Sound?',
          description: "You'll hear a sound — tap the picture that made it.",
          color: AppColors.greenCheck,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const FamiliarSoundGame()),
          ),
        ),
      ];

  // VaD-Early: 3 games.
  List<_GameCard> _vadEarlyCards() => [
        _GameCard(
          emoji: '📋',
          title: 'Daily Routine',
          description: 'Put the steps of an everyday task in the right order.',
          color: AppColors.categoryChipText,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SequencingGame()),
          ),
        ),
        _GameCard(
          emoji: '🔤',
          title: 'Letter Search',
          description: "You'll get a letter — tap every word that starts with it.",
          color: AppColors.orangeStart,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const LetterFluencyGame()),
          ),
        ),
        _GameCard(
          emoji: '🔍',
          title: 'Odd One Out',
          description: "Four pictures, one doesn't belong — tap the one that's different.",
          color: AppColors.greenCheck,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const OddOneOutGame()),
          ),
        ),
      ];

  // VaD-Middle: 3 games.
  List<_GameCard> _vadMiddleCards() => [
        _GameCard(
          emoji: '🗂️',
          title: 'Color/Shape Sorting',
          description: 'Tap which group each picture belongs to.',
          color: AppColors.greenCheck,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SortingGame()),
          ),
        ),
        _GameCard(
          emoji: '🧭',
          title: 'Guided Daily Steps',
          description: 'Follow the glowing step to complete a simple everyday task.',
          color: AppColors.orangeStart,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const GuidedDailyStepsGame()),
          ),
        ),
        _GameCard(
          emoji: '🖼️',
          title: 'Spot the Difference',
          description: 'Two pictures, a few differences — tap the spots that changed.',
          color: AppColors.categoryChipText,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SpotTheDifferenceGame()),
          ),
        ),
      ];
}

class _GameCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String description;
  final Color color;
  final VoidCallback onTap;

  const _GameCard({
    required this.emoji,
    required this.title,
    required this.description,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.cardPurple,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withOpacity(0.18),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(emoji, style: const TextStyle(fontSize: 28)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}

/// Locked/unlocked reward game tile — see reward_game_webview_unlock_prompt.md.
/// Locked: ~40% opacity, lock icon overlay, "Unlock later" label, "N more
/// points to unlock" hint; tapping shows an encouraging snackbar instead
/// of navigating. Unlocked: full opacity, no lock, "Relax & Play"; tapping
/// opens [RewardGameScreen]. [totalPoints] comes from a live stream
/// (FirestoreService.watchPatientTotalPoints) in the parent, so this
/// updates the instant the patient earns enough points without needing to
/// reopen the hub.
/// Locked/unlocked reward game tile — see tiered_reward_games_prompt.md.
/// Locked: ~40% opacity, lock icon overlay, "Unlock later" label, "N more
/// points to unlock" hint; tapping shows an encouraging snackbar instead
/// of navigating. Unlocked: full opacity, no lock, the game's own label;
/// tapping opens [RewardGameScreen] for THIS [game] specifically.
///
/// GENERALISED from the original single-game tile: now driven entirely by
/// [game] (icon/label/threshold) instead of a hardcoded icon and the old
/// module-level `kRewardGameUnlockThreshold` constant, so the same widget
/// renders all four tiers without four near-duplicate classes.
class _RewardGameTile extends StatelessWidget {
  final RewardGame game;
  final int totalPoints;
  const _RewardGameTile({required this.game, required this.totalPoints});

  bool get _isUnlocked => totalPoints >= game.unlockThreshold;
  int get _remaining => (game.unlockThreshold - totalPoints).clamp(0, game.unlockThreshold);
  String get _remainingLabel => '$_remaining more point${_remaining == 1 ? '' : 's'} to unlock';

  @override
  Widget build(BuildContext context) {
    final Widget card = Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.cardPurple,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.categoryChipText.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(game.icon, color: AppColors.categoryChipText, size: 26),
              ),
              if (!_isUnlocked)
                Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.lock, color: Colors.white, size: 22),
                ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isUnlocked ? game.label : 'Unlock later',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  _isUnlocked ? 'A fun game, just for you.' : _remainingLabel,
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        if (_isUnlocked) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => RewardGameScreen(game: game)));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Earn $_remaining more point${_remaining == 1 ? '' : 's'} to unlock this game!',
              ),
              backgroundColor: AppColors.orangeStart,
            ),
          );
        }
      },
      child: _isUnlocked ? card : Opacity(opacity: 0.4, child: card),
    );
  }
}
