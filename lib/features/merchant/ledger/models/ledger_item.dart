class LedgerItem {
  final String productId;
  final String name;
  final double quantity;
  final String unitLabel;
  final double unitPrice;
  final double subtotal;
  final int cartonCapacity;
  final String? barcode;

  const LedgerItem({
    required this.productId,
    required this.name,
    required this.quantity,
    this.unitLabel = 'حبة',
    required this.unitPrice,
    required this.subtotal,
    this.cartonCapacity = 1,
    this.barcode,
  });

  factory LedgerItem.fromMap(Map<String, dynamic> map) {
    return LedgerItem(
      productId: (map['product_id'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      quantity: (map['quantity'] as num?)?.toDouble() ?? 1.0,
      unitLabel: (map['unit_label'] ?? 'حبة').toString(),
      unitPrice: (map['unit_price'] as num?)?.toDouble() ?? 0.0,
      subtotal: (map['subtotal'] as num?)?.toDouble() ?? 0.0,
      cartonCapacity: (map['carton_capacity'] as num?)?.toInt() ?? 1,
      barcode: map['barcode']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'product_id': productId,
      'name': name,
      'quantity': quantity,
      'unit_label': unitLabel,
      'unit_price': unitPrice,
      'subtotal': subtotal,
      'carton_capacity': cartonCapacity,
      if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
    };
  }
}
