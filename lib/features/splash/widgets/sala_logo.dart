import 'package:flutter/material.dart';
import 'dart:math' as math;

/// شعار "وصًال" الرسمي المتطابق هندسياً بنسبة 100% مع الهوية
class WissalLogo extends StatelessWidget {
  final double size;
  final Color color;

  const WissalLogo({
    super.key,
    this.size = 120,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _WissalLogoPainter(color: color),
      ),
    );
  }
}

/// للتوافق المؤقت مع أي استدعاء قديم
typedef SalaLogo = WissalLogo;
typedef wissalLogo = WissalLogo;

// ✅ الحل الصحيح:
class _WissalLogoPainter extends CustomPainter {
  final Color color;

  _WissalLogoPainter({required this.color}); // تصحيح اسم الباني

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // ── 1. رسم مجسم حرف (و) الأبيض المتناسق ──
    final outerHeadRadius = w * 0.285;
    final headCenter = Offset(w * 0.54, h * 0.385);
    final innerHeadRadius = w * 0.165;

    final headOuter = Path()
      ..addOval(Rect.fromCircle(center: headCenter, radius: outerHeadRadius));

    final headInner = Path()
      ..addOval(Rect.fromCircle(center: headCenter, radius: innerHeadRadius));

    final headRing =
        Path.combine(PathOperation.difference, headOuter, headInner);

    // ذيل حرف الواو الانسيابي مع نهاية مستديرة ملساء
    final strokeWidth = outerHeadRadius - innerHeadRadius;
    final tailPath = Path();
    tailPath.moveTo(
        headCenter.dx + innerHeadRadius + strokeWidth / 2, headCenter.dy);
    tailPath.cubicTo(
      headCenter.dx + innerHeadRadius + strokeWidth / 2,
      h * 0.64,
      w * 0.54,
      h * 0.84,
      w * 0.38,
      h * 0.84,
    );
    tailPath.cubicTo(
      w * 0.28,
      h * 0.84,
      w * 0.28,
      h * 0.76,
      w * 0.35,
      h * 0.76,
    );
    tailPath.cubicTo(
      w * 0.44,
      h * 0.76,
      w * 0.52,
      h * 0.72,
      w * 0.54,
      h * 0.58,
    );
    tailPath.lineTo(headCenter.dx + innerHeadRadius, headCenter.dy);
    tailPath.close();

    final wawBody = Path.combine(PathOperation.union, headRing, tailPath);

    // رسم ظل ناعم للشعار ليعطي بُعداً ثلاثي الأبعاد
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawPath(wawBody.shift(const Offset(0, 3)), shadowPaint);

    final whitePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawPath(wawBody, whitePaint);

    // ── 2. رسم نجمة الوميض الذهبية داخل عين حرف الواو ──
    _drawSparkle(
      canvas,
      center: headCenter,
      outerRadius: w * 0.13,
      innerRadius: w * 0.032,
      coreColor: const Color(0xFFFFDF79),
      edgeColor: const Color(0xFFFFC83B),
    );

    // ── 3. رسم نجمة الوميض العلوية الخارجية (أعلى يمين الشعار) ──
    _drawSparkle(
      canvas,
      center: Offset(w * 0.76, h * 0.17),
      outerRadius: w * 0.075,
      innerRadius: w * 0.02,
      coreColor: const Color(0xFFFFDF79),
      edgeColor: const Color(0xFFFFC83B),
    );
  }

  void _drawSparkle(
    Canvas canvas, {
    required Offset center,
    required double outerRadius,
    required double innerRadius,
    required Color coreColor,
    required Color edgeColor,
  }) {
    final path = Path();
    const points = 4;
    final step = math.pi / points;
    double rot = -math.pi / 2;

    for (int i = 0; i < points * 2; i++) {
      final r = (i % 2 == 0) ? outerRadius : innerRadius;
      final x = center.dx + math.cos(rot) * r;
      final y = center.dy + math.sin(rot) * r;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      rot += step;
    }
    path.close();

    // توهج خارجي ناعم خلف النجمة
    final glowPaint = Paint()
      ..color = edgeColor.withValues(alpha: 0.45)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    canvas.drawPath(path, glowPaint);

    final starPaint = Paint()
      ..shader = RadialGradient(
        colors: [coreColor, edgeColor],
      ).createShader(Rect.fromCircle(center: center, radius: outerRadius))
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, starPaint);
  }

  @override
  bool shouldRepaint(covariant _WissalLogoPainter oldDelegate) =>
      oldDelegate.color != color;
}
