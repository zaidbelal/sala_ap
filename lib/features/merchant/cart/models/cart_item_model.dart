import '../../products/services/products_service.dart';
import 'package:wissal/core/models/product_unit.dart';

class CartItem {
  final ProductModel product;
  final int quantity;
  final ProductUnit? selectedUnit;
  final ProductVariant? selectedVariant;

  const CartItem({
    required this.product,
    required this.quantity,
    this.selectedUnit,
    this.selectedVariant,
  });

  String get cartKey {
    final variantPart =
        selectedVariant != null ? '__v_${selectedVariant!.id}' : '';
    final label = selectedUnit?.label.trim() ?? 'كرتون';
    final unitPart = label == 'كرتون' ? '' : '__$label';
    return '${product.id}$variantPart$unitPart';
  }

  String get displayName => selectedVariant != null
      ? '${product.name} - ${selectedVariant!.label}'
      : product.name;

  double get unitPrice =>
      selectedUnit?.price ?? selectedVariant?.price ?? product.price;

  String get unitLabel => selectedUnit?.label ?? 'كرتون';

  double get total => unitPrice * quantity;

  CartItem copyWith({
    int? quantity,
    ProductUnit? selectedUnit,
    ProductVariant? selectedVariant,
  }) =>
      CartItem(
        product: product,
        quantity: quantity ?? this.quantity,
        selectedUnit: selectedUnit ?? this.selectedUnit,
        selectedVariant: selectedVariant ?? this.selectedVariant,
      );

  Map<String, dynamic> toJson() {
    final unitMap = selectedUnit?.toJson();
    final variantMap = selectedVariant?.toJson();

    return {
      'product': {
        'id': product.id,
        'name': product.name,
        'price': product.price,
        'image_url': product.imageUrl,
        'imageUrl': product.imageUrl,
        'brandId': product.brandId,
        'size_ml': product.sizeMl,
        'size_text': product.sizeText,
        'barcode': product.barcode,
        'stock': product.stock,
        'items_per_carton': product.itemsPerCarton,
        'units': product.units.map((u) => u.toJson()).toList(),
        'variants': product.variants.map((v) => v.toJson()).toList(),
      },
      'quantity': quantity,
      'snapshot_at': DateTime.now().millisecondsSinceEpoch,
      if (unitMap != null) 'selectedUnit': unitMap,
      if (variantMap != null) 'selectedVariant': variantMap,
    };
  }

  factory CartItem.fromJson(Map<String, dynamic> j) {
    final p = j['product'] as Map<String, dynamic>;
    final unitMap = j['selectedUnit'] as Map<String, dynamic>?;
    final variantMap = j['selectedVariant'] as Map<String, dynamic>?;
    final img = (p['image_url'] ?? p['imageUrl']) as String?;

    final parsedUnit = unitMap != null ? ProductUnit.fromMap(unitMap) : null;
    final parsedVariant =
        variantMap != null ? ProductVariant.fromMap(variantMap) : null;
    final rawUnits = p['units'] as List<dynamic>?;
    final rawVariants = p['variants'] as List<dynamic>?;

    return CartItem(
      product: ProductModel.fromMap({
        'id': p['id'],
        'name': p['name'],
        'price': p['price'],
        'image_url': img,
        'brand_id': p['brandId'] ?? p['brand_id'] ?? '',
        'size_ml': p['size_ml'],
        'size_text': p['size_text'],
        'barcode': p['barcode'],
        'items_per_carton': p['items_per_carton'],
        'units': rawUnits ?? (parsedUnit != null ? [parsedUnit.toMap()] : []),
        'variants': rawVariants ??
            (parsedVariant != null ? [parsedVariant.toJson()] : []),
        'category_id': '',
        'cost_price': 0,
        'stock': (p['stock'] as num?)?.toDouble() ?? 0.0,
        'is_active': true,
      }),
      quantity: (j['quantity'] as num?)?.toInt() ?? 1,
      selectedUnit: parsedUnit,
      selectedVariant: parsedVariant,
    );
  }
}
