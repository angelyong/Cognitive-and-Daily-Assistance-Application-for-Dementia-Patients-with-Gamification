import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:testproject/models/reward_game.dart';
import 'package:testproject/theme/app_colors.dart';

/// GAMIFICATION / ENGAGEMENT ONLY — this loads a third-party web game
/// picked by [game]. Not a clinical cognitive exercise and has no
/// evidence-based design behind it (contrast with the type/stage games in
/// CognitiveExerciseScreen, which cite specific sources). Kept in its own
/// screen, reached only via a "Just for Fun" tile, so it's never confused
/// with those.
///
/// GENERALISED (tiered_reward_games_prompt.md) from the original
/// single-game version: this screen used to hardcode one URL chain
/// (`kRewardGameUrls`); it now takes [game] and plays whichever
/// [RewardGame.urls] fallback chain belongs to it — one shared
/// load/fallback/timeout code path for all four reward games (see
/// [kRewardGames]), not a copy per game.
///
/// UNVERIFIED AT WRITE TIME for any of [kRewardGames]'s URLs: whether they
/// actually render/play well inside an Android WebView (vs. just existing
/// as a real page) can only be confirmed by running the app on a
/// device/emulator — see the prompt's own explicit verification step.
const Duration _loadTimeout = Duration(seconds: 12);

class RewardGameScreen extends StatefulWidget {
  final RewardGame game;
  const RewardGameScreen({super.key, required this.game});

  @override
  State<RewardGameScreen> createState() => _RewardGameScreenState();
}

class _RewardGameScreenState extends State<RewardGameScreen> {
  late final WebViewController _controller;
  int _urlIndex = 0;
  bool _loading = true;
  bool _allFailed = false;

  // Bumped every time a new URL starts loading; callbacks/timers compare
  // against this before acting, so a late/stale callback for a PREVIOUS
  // (already-abandoned) URL attempt can't incorrectly advance/reset state
  // for the CURRENT attempt.
  int _attemptToken = 0;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted) // these game sites need it
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _onAttemptSucceeded(_attemptToken),
          onWebResourceError: (_) => _onAttemptFailed(_attemptToken),
          onHttpError: (_) => _onAttemptFailed(_attemptToken),
        ),
      );
    _loadCurrentUrl();
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  void _loadCurrentUrl() {
    _attemptToken++;
    final int token = _attemptToken;
    setState(() => _loading = true);
    _controller.loadRequest(Uri.parse(widget.game.urls[_urlIndex]));
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_loadTimeout, () => _onAttemptFailed(token));
  }

  void _onAttemptSucceeded(int token) {
    if (token != _attemptToken || !mounted) return;
    _timeoutTimer?.cancel();
    setState(() => _loading = false);
  }

  void _onAttemptFailed(int token) {
    if (token != _attemptToken || !mounted) return;
    _timeoutTimer?.cancel();
    if (_urlIndex + 1 < widget.game.urls.length) {
      _urlIndex++;
      _loadCurrentUrl();
    } else {
      setState(() {
        _loading = false;
        _allFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDark,
      appBar: AppBar(
        // Always reachable, even mid-load or on the fallback screen — a
        // dementia patient must never be able to get stuck in a WebView.
        title: Text(widget.game.label, style: const TextStyle(color: Colors.white)),
        backgroundColor: AppColors.bgDark,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _allFailed
          ? _buildFallback()
          : Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_loading)
                  const Center(
                    child: CircularProgressIndicator(color: AppColors.orangeStart),
                  ),
              ],
            ),
    );
  }

  Widget _buildFallback() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.spa_outlined, color: AppColors.textMuted, size: 56),
            const SizedBox(height: 20),
            const Text(
              'The game is taking a break. Please try again later.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.white),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.orangeStart,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
