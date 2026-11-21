import 'package:cloud_firestore/cloud_firestore.dart';

class LedgerCustomer {
  final String id;
  final String merchantId;
  final String name;
  final String phone;
  final double creditLimit;
  final double currentBalance;
  final String notes;
  final bool isDeleted;
  final DateTime? lastTransactionAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const LedgerCustomer({
    required this.id,
    required this.merchantId,
    required this.name,
    this.phone = '',
    this.creditLimit = 0.0,
    this.currentBalance = 0.0,
    this.notes = '',
    this.isDeleted = false,
    this.lastTransactionAt,
    this.createdAt,
    this.updatedAt,
  });

  /// الرصيد المتبقي من سقف الائتمان (إذا كان السقف محدداً)
  double get remainingCredit {
    if (creditLimit <= 0) return 0.0;
    final rem = creditLimit - currentBalance;
    return rem > 0 ? rem : 0.0;
  }

  /// هل تجاوز العميل سقف الدين المسموح؟
  bool get isOverLimit => creditLimit > 0 && currentBalance > creditLimit;

  /// نسبة استهلاك سقف الدين (بين 0.0 و 1.0 أو أكثر)
  double get creditUsageRatio {
    if (creditLimit <= 0) return 0.0;
    return (currentBalance / creditLimit).clamp(0.0, 2.0);
  }

  factory LedgerCustomer.fromMap(String id, Map<String, dynamic> map) {
    DateTime? parseDate(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is String) return DateTime.tryParse(val);
      return null;
    }

    return LedgerCustomer(
      id: id,
      merchantId: (map['merchant_id'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      phone: (map['phone'] ?? '').toString(),
      creditLimit: (map['credit_limit'] as num?)?.toDouble() ?? 0.0,
      currentBalance: (map['current_balance'] as num?)?.toDouble() ?? 0.0,
      notes: (map['notes'] ?? '').toString(),
      isDeleted: map['is_deleted'] == true,
      lastTransactionAt: parseDate(map['last_transaction_at']),
      createdAt: parseDate(map['created_at']),
      updatedAt: parseDate(map['updated_at']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'merchant_id': merchantId,
      'name': name,
      'phone': phone,
      'credit_limit': creditLimit,
      'current_balance': currentBalance,
      'notes': notes,
      'is_deleted': isDeleted,
      'last_transaction_at': lastTransactionAt != null ? Timestamp.fromDate(lastTransactionAt!) : null,
      'created_at': createdAt != null ? Timestamp.fromDate(createdAt!) : null,
      'updated_at': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
    };
  }

  LedgerCustomer copyWith({
    String? name,
    String? phone,
    double? creditLimit,
    double? currentBalance,
    String? notes,
    bool? isDeleted,
    DateTime? lastTransactionAt,
  }) {
    return LedgerCustomer(
      id: id,
      merchantId: merchantId,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      creditLimit: creditLimit ?? this.creditLimit,
      currentBalance: currentBalance ?? this.currentBalance,
      notes: notes ?? this.notes,
      isDeleted: isDeleted ?? this.isDeleted,
      lastTransactionAt: lastTransactionAt ?? this.lastTransactionAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}
