import 'package:flutter/material.dart';
import '../models/ledger_customer.dart';

class CreditLimitIndicator extends StatelessWidget {
  final LedgerCustomer customer;
  final bool showLabel;

  const CreditLimitIndicator({
    super.key,
    required this.customer,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    if (customer.creditLimit <= 0) {
      if (!showLabel) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Text(
          'سقف مفتوح',
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11,
            color: Colors.grey,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final ratio = customer.creditUsageRatio;
    final isOver = customer.isOverLimit;
    final isWarning = ratio >= 0.8 && !isOver;

    Color color = const Color(0xFF2ECC71); // أخضر طبيعي
    if (isWarning) color = const Color(0xFFF39C12); // برتقالي تحذيري
    if (isOver) color = const Color(0xFFE74C3C); // أحمر تجاوز السقف

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showLabel) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isOver
                    ? '⚠️ تجاوز السقف المحدد!'
                    : 'استهلاك السقف: ${(ratio * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(
                'السقف: ${customer.creditLimit.toStringAsFixed(0)} ريال',
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: ratio.clamp(0.0, 1.0),
            backgroundColor: Colors.grey.withValues(alpha: 0.15),
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 6,
          ),
        ),
      ],
    );
  }
}
