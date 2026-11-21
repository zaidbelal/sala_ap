import 'package:cloud_firestore/cloud_firestore.dart';
import 'ledger_item.dart';

class LedgerEntry {
  final String id;
  final String merchantId;
  final String customerId;
  final String type; // 'debt' or 'payment'
  final double amount;
  final String notes;
  final List<LedgerItem> items;
  final double balanceAfter;
  final bool isVoided;
  final DateTime? voidedAt;
  final DateTime? createdAt;

  const LedgerEntry({
    required this.id,
    required this.merchantId,
    required this.customerId,
    required this.type,
    required this.amount,
    this.notes = '',
    this.items = const [],
    required this.balanceAfter,
    this.isVoided = false,
    this.voidedAt,
    this.createdAt,
  });

  bool get isDebt => type == 'debt';
  bool get isPayment => type == 'payment';

  String get typeLabel => isDebt ? 'دين مشتريات' : 'سداد نقدي (كاش)';

  factory LedgerEntry.fromMap(String id, Map<String, dynamic> map) {
    DateTime? parseDate(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is String) return DateTime.tryParse(val);
      return null;
    }

    final rawItems = map['items'];
    List<LedgerItem> parsedItems = [];
    if (rawItems is List) {
      parsedItems = rawItems
          .whereType<Map<String, dynamic>>()
          .map((m) => LedgerItem.fromMap(m))
          .toList();
    }

    return LedgerEntry(
      id: id,
      merchantId: (map['merchant_id'] ?? '').toString(),
      customerId: (map['customer_id'] ?? '').toString(),
      type: (map['type'] ?? 'debt').toString().toLowerCase(),
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      notes: (map['notes'] ?? '').toString(),
      items: parsedItems,
      balanceAfter: (map['balance_after'] as num?)?.toDouble() ?? 0.0,
      isVoided: map['is_voided'] == true,
      voidedAt: parseDate(map['voided_at']),
      createdAt: parseDate(map['created_at']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'merchant_id': merchantId,
      'customer_id': customerId,
      'type': type,
      'amount': amount,
      'notes': notes,
      'items': items.map((i) => i.toMap()).toList(),
      'balance_after': balanceAfter,
      'is_voided': isVoided,
      'voided_at': voidedAt != null ? Timestamp.fromDate(voidedAt!) : null,
      'created_at': createdAt != null ? Timestamp.fromDate(createdAt!) : null,
    };
  }
}
