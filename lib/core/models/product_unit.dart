import 'package:cloud_firestore/cloud_firestore.dart';

// ══════════════════════════════════════════════════════════
// ProductUnit — وحدة البيع مع بيانات كاملة وسعر التكلفة
// ══════════════════════════════════════════════════════════

class ProductUnit {
  final String label; // اسم الوحدة: كرتون، نصف كرتون، حبة...
  final int qty; // عدد الحبات في هذه الوحدة
  final double price; // سعر بيع هذه الوحدة
  final double? costPrice; // سعر شراء / تكلفة هذه الوحدة (لحساب الربح)
  final String? imageUrl; // صورة خاصة بهذه الوحدة (اختياري)
  final double? sizeMl; // الحجم بالمل (اختياري)
  final DateTime? productionDate; // تاريخ الإنتاج (اختياري)
  final DateTime? expiryDate; // تاريخ الانتهاء (اختياري)
  final String? barcode; // باركود الوحدة (اختياري)

  const ProductUnit({
    required this.label,
    required this.qty,
    required this.price,
    this.costPrice,
    this.imageUrl,
    this.sizeMl,
    this.productionDate,
    this.expiryDate,
    this.barcode,
  });

  factory ProductUnit.fromMap(Map<String, dynamic> m) {
    DateTime? parseDate(dynamic val) {
      if (val == null) return null;
      if (val is Timestamp) return val.toDate();
      if (val is DateTime) return val;
      if (val is String && val.trim().isNotEmpty) {
        return DateTime.tryParse(val.trim());
      }
      return null;
    }

    return ProductUnit(
      label: m['label']?.toString() ?? '',
      qty: (m['qty'] as num?)?.toInt() ?? 1,
      price: (m['price'] as num?)?.toDouble() ?? 0.0,
      costPrice: (m['cost_price'] as num?)?.toDouble() ??
          (m['costPrice'] as num?)?.toDouble(),
      imageUrl: m['image_url'] as String?,
      sizeMl: (m['size_ml'] as num?)?.toDouble(),
      productionDate: parseDate(m['production_date']),
      expiryDate: parseDate(m['expiry_date']),
      barcode: m['barcode']?.toString().trim(),
    );
  }
  Map<String, dynamic> toMap() => {
        'label': label,
        'qty': qty,
        'price': price,
        if (costPrice != null) 'cost_price': costPrice,
        if (imageUrl != null && imageUrl!.isNotEmpty) 'image_url': imageUrl,
        if (sizeMl != null) 'size_ml': sizeMl,
        if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
        if (productionDate != null)
          'production_date': Timestamp.fromDate(productionDate!),
        if (expiryDate != null) 'expiry_date': Timestamp.fromDate(expiryDate!),
      };

  Map<String, dynamic> toJson() => {
        'label': label,
        'qty': qty,
        'price': price,
        if (costPrice != null) 'cost_price': costPrice,
        if (imageUrl != null && imageUrl!.isNotEmpty) 'image_url': imageUrl,
        if (sizeMl != null) 'size_ml': sizeMl,
        if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
        if (productionDate != null)
          'production_date': productionDate!.toIso8601String(),
        if (expiryDate != null) 'expiry_date': expiryDate!.toIso8601String(),
      };
}

// ══════════════════════════════════════════════════════════
// ProductVariant — حجم/نوع مستقل داخل نفس المنتج بمخزونه ووحداته
// ══════════════════════════════════════════════════════════
class ProductVariant {
  final String id;
  final String label;
  final double price;
  final double? costPrice;
  final double stock;
  final int itemsPerCarton;
  final String? sizeText;
  final double? sizeMl;
  final String? imageUrl;
  final String? barcode;
  final DateTime? productionDate;
  final DateTime? expiryDate;
  final List<ProductUnit> units;

  const ProductVariant({
    required this.id,
    required this.label,
    required this.price,
    this.costPrice,
    this.stock = 0.0,
    this.itemsPerCarton = 1,
    this.sizeText,
    this.sizeMl,
    this.imageUrl,
    this.barcode,
    this.productionDate,
    this.expiryDate,
    this.units = const [],
  });

  factory ProductVariant.fromMap(Map<String, dynamic> m) {
    DateTime? parseDate(dynamic val) {
      if (val == null) return null;
      if (val is Timestamp) return val.toDate();
      if (val is DateTime) return val;
      if (val is String && val.trim().isNotEmpty) {
        return DateTime.tryParse(val.trim());
      }
      return null;
    }

    final rawUnits = m['units'];
    final parsedUnits = rawUnits is List
        ? rawUnits
            .whereType<Map>()
            .map((e) => ProductUnit.fromMap(Map<String, dynamic>.from(e)))
            .toList()
        : <ProductUnit>[];

    return ProductVariant(
      id: m['id']?.toString().trim().isNotEmpty == true
          ? m['id'].toString().trim()
          : (m['label']?.toString().trim() ?? 'v'),
      label: m['label']?.toString().trim() ?? '',
      price: (m['price'] as num?)?.toDouble() ?? 0.0,
      costPrice: (m['cost_price'] as num?)?.toDouble() ??
          (m['costPrice'] as num?)?.toDouble(),
      stock: (m['stock'] as num?)?.toDouble() ?? 0.0,
      itemsPerCarton:
          ((m['items_per_carton'] as num?)?.toInt() ?? 1).clamp(1, 9999),
      sizeText: m['size_text']?.toString(),
      sizeMl: (m['size_ml'] as num?)?.toDouble(),
      imageUrl: m['image_url'] as String?,
      barcode: m['barcode']?.toString().trim(),
      productionDate: parseDate(m['production_date']),
      expiryDate: parseDate(m['expiry_date']),
      units: parsedUnits,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'price': price,
        if (costPrice != null) 'cost_price': costPrice,
        'stock': stock,
        'items_per_carton': itemsPerCarton,
        if (sizeText != null && sizeText!.isNotEmpty) 'size_text': sizeText,
        if (sizeMl != null) 'size_ml': sizeMl,
        if (imageUrl != null && imageUrl!.isNotEmpty) 'image_url': imageUrl,
        if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
        if (productionDate != null)
          'production_date': productionDate!.toIso8601String(),
        if (expiryDate != null) 'expiry_date': expiryDate!.toIso8601String(),
        'units': units.map((u) => u.toJson()).toList(),
      };
}
