import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:testproject/services/adaptive_difficulty_service.dart';
import 'package:testproject/services/firestore_service.dart';
import 'package:testproject/theme/app_colors.dart';

/// VaD-MIDDLE game, 3rd slot (see claude_code_four_game_sets_prompt.md):
/// two near-identical scenes are shown side by side, and the patient taps
/// the spots where they differ. This is a visual-attention/scanning task,
/// which de Oliveira et al. (2017) and El-Shafey et al. (2025) both
/// associate with the visuospatial-attention domain impaired in Vascular
/// Dementia. NEW game built for this task.
///
/// ASSET DECISION: the doc's brief describes two real bundled photos with
/// edited differences. MindCare has no such image pair bundled, so — per
/// the doc's own suggested fallback — both scenes are simple shapes
/// (circles/squares/triangles/stars) drawn procedurally with [CustomPaint]
/// rather than real photographs; differences are a shape's color, size, or
/// presence changing between the two panels. Swapping in real photo-pair
/// assets later doesn't require changing the tap/scoring logic, only the
/// two painters.
///
/// Errorless design: tapping a spot with no difference is never a hard
/// fail — it's met with encouragement, and after repeated misses one
/// undiscovered difference pulses as a vanishing cue.
///
/// Middle-stage requirements applied here: short (1 scene) session, no
/// timer/time pressure, generous tap-hit radius around each difference so
/// precision isn't required.
///
/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): difficulty is
/// now a PER-GAME auto-adjusting level (1..3) — this game had no
/// [GameDifficultyTier] integration before, so a patient with no
/// difficultyState doc yet simply starts at level 1. Level scales both the
/// number of differences to find and the miss threshold before a vanishing
/// cue appears, per Ortega Morán et al. (2024).
const String _gameId = 'spot_the_difference';
const String _gameSet = 'vad_middle';

class _LevelConfig {
  final int differenceCount;
  final int missesBeforeHint;
  const _LevelConfig({required this.differenceCount, required this.missesBeforeHint});

  static _LevelConfig forLevel(int level) {
    switch (level) {
      case 1:
        return const _LevelConfig(differenceCount: 2, missesBeforeHint: 2);
      case 3:
        return const _LevelConfig(differenceCount: 4, missesBeforeHint: 4);
      case 2:
      default:
        return const _LevelConfig(differenceCount: 3, missesBeforeHint: 3);
    }
  }
}

class SpotTheDifferenceGame extends StatefulWidget {
  const SpotTheDifferenceGame({super.key});

  @override
  State<SpotTheDifferenceGame> createState() => _SpotTheDifferenceGameState();
}

enum _ShapeKind { circle, square, triangle, star }

class _SceneShape {
  final _ShapeKind kind;
  final Offset center;
  final double size;
  final Color color;
  final bool visible;
  const _SceneShape({
    required this.kind,
    required this.center,
    required this.size,
    required this.color,
    this.visible = true,
  });
}

class _Difference {
  final Offset location;
  bool found = false;
  _Difference(this.location);
}

const double _canvasSize = 260;
const double _hitRadius = 34;

// Base scene shared by both panels; panel B overrides 3 shapes to create
// the differences (color change, size change, and one shape disappearing).
final List<_SceneShape> _baseShapes = [
  const _SceneShape(
    kind: _ShapeKind.circle,
    center: Offset(60, 60),
    size: 40,
    color: AppColors.orangeStart,
  ),
  const _SceneShape(
    kind: _ShapeKind.square,
    center: Offset(180, 60),
    size: 44,
    color: AppColors.greenCheck,
  ),
  const _SceneShape(
    kind: _ShapeKind.triangle,
    center: Offset(60, 180),
    size: 44,
    color: AppColors.typeVascular,
  ),
  const _SceneShape(
    kind: _ShapeKind.star,
    center: Offset(180, 180),
    size: 44,
    color: AppColors.typeAlzheimers,
  ),
  const _SceneShape(
    kind: _ShapeKind.circle,
    center: Offset(120, 120),
    size: 30,
    color: Colors.white,
  ),
];

class _SpotTheDifferenceGameState extends State<SpotTheDifferenceGame> {
  // Order in which differences are activated as level (and therefore
  // differenceCount) increases: the two most visually obvious differences
  // (color change, disappearance) come first, the subtler size change and
  // the new harder triangle-color change are added only at higher levels.
  static const List<int> _diffOrder = [0, 4, 1, 2];

  final FirestoreService _firestoreService = FirestoreService();
  final AdaptiveDifficultyService _difficultyService = AdaptiveDifficultyService();

  String? _uid;
  int _level = 1;
  late _LevelConfig _config;
  bool _loadingLevel = true;

  late List<_SceneShape> _panelA;
  late List<_SceneShape> _panelB;
  late List<_Difference> _differences;
  int _wrongTaps = 0;
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

  static _SceneShape _panelBOverride(int index) {
    switch (index) {
      case 0:
        // The orange circle turns a different color in panel B.
        return const _SceneShape(
          kind: _ShapeKind.circle,
          center: Offset(60, 60),
          size: 40,
          color: AppColors.typeAlzheimers,
        );
      case 4:
        // The small white circle disappears in panel B.
        return const _SceneShape(
          kind: _ShapeKind.circle,
          center: Offset(120, 120),
          size: 30,
          color: Colors.white,
          visible: false,
        );
      case 1:
        // The green square shrinks in panel B.
        return const _SceneShape(
          kind: _ShapeKind.square,
          center: Offset(180, 60),
          size: 24,
          color: AppColors.greenCheck,
        );
      case 2:
      default:
        // The purple triangle turns white in panel B (level 3 only).
        return const _SceneShape(
          kind: _ShapeKind.triangle,
          center: Offset(60, 180),
          size: 44,
          color: Colors.white,
        );
    }
  }

  void _setUpGame() {
    _panelA = List<_SceneShape>.from(_baseShapes);
    _panelB = List<_SceneShape>.from(_baseShapes);

    final List<int> diffIndices = _diffOrder.sublist(0, _config.differenceCount);
    for (final index in diffIndices) {
      _panelB[index] = _panelBOverride(index);
    }

    setState(() {
      _differences = [for (final index in diffIndices) _Difference(_panelA[index].center)];
      _wrongTaps = 0;
      _hintsUsedThisSession = 0;
      _sessionStart = DateTime.now();
      _hintActive = false;
      _feedback = null;
    });
  }

  void _onPanelTap(Offset localPosition) {
    for (final diff in _differences) {
      if (diff.found) continue;
      if ((diff.location - localPosition).distance <= _hitRadius) {
        setState(() {
          diff.found = true;
          _hintActive = false;
          _feedback = 'Found one! 🎉';
        });
        if (_differences.every((d) => d.found)) {
          Future.delayed(const Duration(milliseconds: 600), _finishGame);
        }
        return;
      }
    }

    // Errorless learning: no hard fail. After a level-scaled number of
    // misses, pulse an undiscovered difference as a vanishing cue. Count a
    // hint only on the transition into hint-active state, matching the
    // convention used elsewhere.
    final bool isNewHint = !_hintActive;
    setState(() {
      _wrongTaps++;
      _feedback = 'Not there — keep looking!';
      if (_wrongTaps >= _config.missesBeforeHint) {
        _hintActive = true;
        if (isNewHint) _hintsUsedThisSession++;
      }
    });
  }

  Future<void> _finishGame() async {
    const int pointsPerDifference = 6;
    final int pointsEarned = _differences.length * pointsPerDifference;
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
          // ACCURACY: total taps (correct + wrong), not just differences found
          // (always equals _differences.length under errorless design) — see
          // memory_matching_game.dart's identical note.
          final int totalTaps = _differences.length + _wrongTaps;
          _level = await _difficultyService.recordSessionAndAdapt(
            sessionId: '${uid}_${_gameId}_${_sessionStart!.millisecondsSinceEpoch}',
            patientId: uid,
            gameId: _gameId,
            gameSet: _gameSet,
            difficultyLevel: _level,
            totalItems: totalTaps,
            correctItems: _differences.length,
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
        title: const Text('All found! 🎉', style: TextStyle(color: Colors.white)),
        content: Text(
          'You spotted all ${_differences.length} differences.\n\n'
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

  Offset? get _hintLocation {
    if (!_hintActive) return null;
    for (final diff in _differences) {
      if (!diff.found) return diff.location;
    }
    return null;
  }

  Widget _buildPanel(List<_SceneShape> shapes) {
    return GestureDetector(
      onTapDown: (details) => _onPanelTap(details.localPosition),
      child: Container(
        width: _canvasSize,
        height: _canvasSize,
        decoration: BoxDecoration(
          color: AppColors.cardPurple,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.cardPurpleLight, width: 2),
        ),
        child: CustomPaint(
          painter: _ScenePainter(
            shapes: shapes,
            foundMarkers: _differences.where((d) => d.found).map((d) => d.location).toList(),
            hintLocation: _hintLocation,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int foundCount = _loadingLevel ? 0 : _differences.where((d) => d.found).length;
    return Scaffold(
      backgroundColor: AppColors.bgDark,
      appBar: AppBar(
        title: const Text('Spot the Difference', style: TextStyle(color: Colors.white)),
        backgroundColor: AppColors.bgDark,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _loadingLevel
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.orangeStart),
            )
          : SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Found $foundCount of ${_differences.length} differences',
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
              'Tap the spots that look different between the two pictures.',
              style: TextStyle(fontSize: 15, color: Colors.white),
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
            Center(child: _buildPanel(_panelA)),
            const SizedBox(height: 16),
            Center(child: _buildPanel(_panelB)),
          ],
        ),
      ),
    );
  }
}

class _ScenePainter extends CustomPainter {
  final List<_SceneShape> shapes;
  final List<Offset> foundMarkers;
  final Offset? hintLocation;

  _ScenePainter({required this.shapes, required this.foundMarkers, this.hintLocation});

  @override
  void paint(Canvas canvas, Size size) {
    for (final shape in shapes) {
      if (!shape.visible) continue;
      final paint = Paint()..color = shape.color;
      switch (shape.kind) {
        case _ShapeKind.circle:
          canvas.drawCircle(shape.center, shape.size / 2, paint);
          break;
        case _ShapeKind.square:
          canvas.drawRect(
            Rect.fromCenter(center: shape.center, width: shape.size, height: shape.size),
            paint,
          );
          break;
        case _ShapeKind.triangle:
          final path = Path()
            ..moveTo(shape.center.dx, shape.center.dy - shape.size / 2)
            ..lineTo(shape.center.dx - shape.size / 2, shape.center.dy + shape.size / 2)
            ..lineTo(shape.center.dx + shape.size / 2, shape.center.dy + shape.size / 2)
            ..close();
          canvas.drawPath(path, paint);
          break;
        case _ShapeKind.star:
          canvas.drawPath(_starPath(shape.center, shape.size / 2), paint);
          break;
      }
    }

    for (final marker in foundMarkers) {
      canvas.drawCircle(
        marker,
        _hitRadius,
        Paint()
          ..color = AppColors.greenCheck
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }

    if (hintLocation != null) {
      canvas.drawCircle(
        hintLocation!,
        _hitRadius,
        Paint()
          ..color = AppColors.orangeStart
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
  }

  Path _starPath(Offset center, double radius) {
    final path = Path();
    const int points = 5;
    final double innerRadius = radius * 0.5;
    for (int i = 0; i < points * 2; i++) {
      final double r = i.isEven ? radius : innerRadius;
      final double angle = (i * math.pi / points) - math.pi / 2;
      final Offset point = Offset(
        center.dx + r * math.cos(angle),
        center.dy + r * math.sin(angle),
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _ScenePainter oldDelegate) {
    return oldDelegate.shapes != shapes ||
        oldDelegate.foundMarkers != foundMarkers ||
        oldDelegate.hintLocation != hintLocation;
  }
}
