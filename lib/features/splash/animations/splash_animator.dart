import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../controllers/session_checker.dart';

class SplashAnimator extends StatefulWidget {
  final Widget logo;
  final String appName;
  final Color textColor;
  final Future<SessionResult> sessionFuture;
  final void Function(SessionResult result) onAnimationComplete;

  const SplashAnimator({
    super.key,
    required this.logo,
    required this.appName,
    required this.sessionFuture,
    required this.onAnimationComplete,
    this.textColor = Colors.white,
  });

  @override
  State<SplashAnimator> createState() => _SplashAnimatorState();
}

class _SplashAnimatorState extends State<SplashAnimator>
    with TickerProviderStateMixin {
  // ── محركات الحركة السينمائية الأربعة ──
  late AnimationController _ambientGlowCtrl;
  late AnimationController _logoSpringCtrl;
  late AnimationController _sparkleFlashCtrl;
  late AnimationController _textRevealCtrl;

  late Animation<double> _ambientScale;
  late Animation<double> _ambientOpacity;
  late Animation<double> _logoScale;
  late Animation<double> _logoOpacity;
  late Animation<double> _sparkleRotation;
  late Animation<double> _sparkleScale;
  late Animation<double> _textSlideY;
  late Animation<double> _textOpacity;
  late Animation<double> _shimmerWave;

  SessionResult? _sessionResult;
  bool _animationDone = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _startCinematicSequence();
    _awaitSession();
  }

  void _setupAnimations() {
    // 1. هالة النور الزمردية الخلفية الناعمة
    _ambientGlowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _ambientScale = Tween<double>(begin: 0.3, end: 1.6).animate(
      CurvedAnimation(parent: _ambientGlowCtrl, curve: Curves.easeOutCubic),
    );
    _ambientOpacity = Tween<double>(begin: 0.0, end: 0.5).animate(
      CurvedAnimation(
          parent: _ambientGlowCtrl, curve: const Interval(0.0, 0.7)),
    );

    // 2. انبثاق وانطلاق حرف الواو الأبيض بحركة ارتدادية ناعمة (Spring Elastic)
    _logoSpringCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _logoScale = Tween<double>(begin: 0.25, end: 1.0).animate(
      CurvedAnimation(parent: _logoSpringCtrl, curve: Curves.elasticOut),
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _logoSpringCtrl, curve: const Interval(0.0, 0.45)),
    );

    // 3. لمعان وميض النجوم الذهبية وتوهجها اللحظي
    _sparkleFlashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _sparkleRotation = Tween<double>(begin: 0.0, end: 2 * math.pi).animate(
      CurvedAnimation(parent: _sparkleFlashCtrl, curve: Curves.linear),
    );
    _sparkleScale = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _sparkleFlashCtrl, curve: Curves.easeInOut),
    );

    // 4. انزلاق وبزوغ الاسم "وَمْـــــض" مع تموج ضوئي ذهبي
    _textRevealCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _textSlideY = Tween<double>(begin: 30.0, end: 0.0).animate(
      CurvedAnimation(parent: _textRevealCtrl, curve: Curves.easeOutCubic),
    );
    _textOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _textRevealCtrl, curve: Curves.easeIn),
    );
    _shimmerWave = Tween<double>(begin: -1.2, end: 2.2).animate(
      CurvedAnimation(parent: _textRevealCtrl, curve: Curves.easeInOut),
    );
  }

  Future<void> _startCinematicSequence() async {
    try {
      if (_disposed || !mounted) return;
      _ambientGlowCtrl.forward();
      await Future.delayed(const Duration(milliseconds: 120));

      if (_disposed || !mounted) return;
      _logoSpringCtrl.forward();
      await Future.delayed(const Duration(milliseconds: 400));

      if (_disposed || !mounted) return;
      await _textRevealCtrl.forward();

      await Future.delayed(const Duration(milliseconds: 350));
      _animationDone = true;
      _navigateIfReady();
    } catch (_) {}
  }

  Future<void> _awaitSession() async {
    try {
      _sessionResult =
          await widget.sessionFuture.timeout(const Duration(seconds: 4));
    } catch (_) {
      _sessionResult = SessionChecker.localSessionResult();
    }
    _navigateIfReady();
  }

  void _navigateIfReady() {
    if (_animationDone && _sessionResult != null && mounted) {
      widget.onAnimationComplete(_sessionResult!);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ambientGlowCtrl.dispose();
    _logoSpringCtrl.dispose();
    _sparkleFlashCtrl.dispose();
    _textRevealCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _ambientGlowCtrl,
        _logoSpringCtrl,
        _sparkleFlashCtrl,
        _textRevealCtrl,
      ]),
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── هالة النور وشعار الواو ──
            Stack(
              alignment: Alignment.center,
              children: [
                // هالة التوهج الزمردي المشع
                Transform.scale(
                  scale: _ambientScale.value,
                  child: Opacity(
                    opacity: _ambientOpacity.value,
                    child: Container(
                      width: 150,
                      height: 150,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            Color(0xFF2BD87E),
                            Color(0xFF10B981),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // مجسم الشعار بانبثاق مطاطي
                Transform.scale(
                  scale: _logoScale.value,
                  child: Opacity(
                    opacity: _logoOpacity.value.clamp(0.0, 1.0),
                    child: widget.logo,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 28),

            // ── كتابة اسم "وَمْـــــض" مع لمعان شعاع ذهبي زمردي ──
            Transform.translate(
              offset: Offset(0, _textSlideY.value),
              child: Opacity(
                opacity: _textOpacity.value.clamp(0.0, 1.0),
                child: ShaderMask(
                  shaderCallback: (bounds) {
                    return LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: const [
                        Colors.white,
                        Color(0xFFFFDF79),
                        Colors.white,
                      ],
                      stops: [
                        (_shimmerWave.value - 0.25).clamp(0.0, 1.0),
                        _shimmerWave.value.clamp(0.0, 1.0),
                        (_shimmerWave.value + 0.25).clamp(0.0, 1.0),
                      ],
                    ).createShader(bounds);
                  },
                  child: Text(
                    widget.appName,
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 44,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 4.5,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
