import 'package:cloud_firestore/cloud_firestore.dart';

class LedgerSummary {
  final String merchantId;
  final double totalMarketDebt;
  final int debtorsCount;
  final DateTime? updatedAt;

  const LedgerSummary({
    required this.merchantId,
    this.totalMarketDebt = 0.0,
    this.debtorsCount = 0,
    this.updatedAt,
  });

  factory LedgerSummary.fromMap(String merchantId, Map<String, dynamic> map) {
    DateTime? parseDate(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is String) return DateTime.tryParse(val);
      return null;
    }

    return LedgerSummary(
      merchantId: merchantId,
      totalMarketDebt: (map['total_market_debt'] as num?)?.toDouble() ?? 0.0,
      debtorsCount: (map['debtors_count'] as num?)?.toInt() ?? 0,
      updatedAt: parseDate(map['updated_at']),
    );
  }
}
