import 'package:flutter/material.dart';
import 'package:confetti/confetti.dart';
import 'package:audioplayers/audioplayers.dart';

/// Full-screen success overlay shown right after a successful patient login.
///
/// Gold/bronze foil confetti bursts from an upper-center point and falls
/// with gravity, alongside a plain checkmark + message (no glow, no
/// circular badge — kept intentionally calm/simple since patients may
/// have dementia) and a short chime sound
/// (assets/sounds/login_success.mp3). Total time on screen is capped at
/// [_totalDuration] so it never holds up the login flow.
///
/// Usage:
///   showDialog(
///     context: context,
///     barrierDismissible: false,
///     builder: (_) => LoginSuccessEffect(
///       onComplete: () {
///         Navigator.of(context).pop(); // close the overlay
///         Navigator.pushReplacementNamed(context, '/patientdashboard');
///       },
///     ),
///   );
class LoginSuccessEffect extends StatefulWidget {
  final VoidCallback onComplete;
  final String message;

  const LoginSuccessEffect({
    super.key,
    required this.onComplete,
    this.message = 'Welcome back!',
  });

  @override
  State<LoginSuccessEffect> createState() => _LoginSuccessEffectState();
}

class _LoginSuccessEffectState extends State<LoginSuccessEffect>
    with TickerProviderStateMixin {
  static const Duration _totalDuration = Duration(milliseconds: 2800);
  static const Duration _confettiBurst = Duration(milliseconds: 1000);
  static const Duration _scaleIn = Duration(milliseconds: 400);

  static const List<Color> _confettiColors = [
    Color(0xFFFFD700), // gold
    Color(0xFFFFC94A), // light amber
    Color(0xFFCD7F32), // bronze
    Color(0xFFB8860B), // dark goldenrod
    Color(0xFFE8B923), // deep amber
  ];

  late final ConfettiController _confettiController;
  late final AnimationController _scaleController;
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();

    _confettiController = ConfettiController(duration: _confettiBurst);
    _scaleController = AnimationController(
      vsync: this,
      duration: _scaleIn,
    );

    _play();
  }

  Future<void> _play() async {
    _scaleController.forward();
    _confettiController.play();

    // Play the chime; ignore errors so a missing/failed asset (or a flaky
    // audio device during a live demo) never blocks the login flow itself.
    try {
      await _audioPlayer.play(AssetSource('sounds/login_success.mp3'));
    } catch (_) {
      // Silently continue — sound is a nice-to-have, not a requirement.
    }

    await Future.delayed(_totalDuration);
    if (mounted) widget.onComplete();
  }

  @override
  void dispose() {
    _confettiController.dispose();
    _scaleController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  /// A tall, narrow rectangle — reads as a foil confetti strip rather than
  /// the package's default particle shapes.
  Path _drawFoilRectangle(Size size) {
    final double width = size.width * 0.5;
    final double height = size.height * 1.6;
    return Path()
      ..addRect(Rect.fromCenter(center: Offset.zero, width: width, height: height));
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.55),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // ---- Success icon + message (plain — no glow, no circle badge) ----
          ScaleTransition(
            scale: CurvedAnimation(
              parent: _scaleController,
              curve: Curves.elasticOut,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_rounded,
                  color: Colors.white,
                  size: 72,
                  shadows: [
                    Shadow(color: Colors.black45, blurRadius: 12),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  widget.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          // ---- Gold/bronze foil confetti burst, upper-center origin ----
          Align(
            alignment: const Alignment(0, -0.5),
            child: ConfettiWidget(
              confettiController: _confettiController,
              blastDirectionality: BlastDirectionality.explosive,
              shouldLoop: false,
              numberOfParticles: 50,
              maxBlastForce: 28,
              minBlastForce: 10,
              gravity: 0.35,
              particleDrag: 0.04,
              createParticlePath: _drawFoilRectangle,
              colors: _confettiColors,
            ),
          ),
        ],
      ),
    );
  }
}
