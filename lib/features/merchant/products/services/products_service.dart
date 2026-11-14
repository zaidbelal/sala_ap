import 'dart:async';

import 'package:wissal/core/models/product_unit.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ProductSizeTier { all, small, medium, large }

class ProductModel {
  final String id;
  final String name;
  final double price;
  final String? imageUrl;
  final String brandId;
  final String? description;
  final double? sizeMl;
  final String? sizeText;
  final int? itemsPerCarton;
  final String? productionDate;
  final String? expiryDate;
  final double costPrice;
  final double stock;
  final int salesCount; // 👈 عداد المبيعات الفعلي الموثق سحابياً
  final String? barcode;
  final List<ProductUnit> units;
  final List<ProductVariant> variants;

  const ProductModel({
    required this.id,
    required this.name,
    required this.price,
    this.imageUrl,
    required this.brandId,
    this.description,
    this.sizeMl,
    this.sizeText,
    this.itemsPerCarton,
    this.productionDate,
    this.expiryDate,
    this.costPrice = 0,
    this.stock = 0.0,
    this.salesCount = 0,
    this.barcode,
    this.units = const [],
    this.variants = const [],
  });

  bool get hasVariants => variants.isNotEmpty;

  double get effectiveMinPrice {
    if (variants.isEmpty) return price;
    return variants.map((v) => v.price).reduce((a, b) => a < b ? a : b);
  }

  double get totalStock {
    if (variants.isEmpty) return stock;
    return variants.fold(0.0, (sum, v) => sum + (v.stock > 0 ? v.stock : 0.0));
  }

  // 🚀 خوارزمية تصنيف الحجم الذكية (كبير / وسط / صغير)
  ProductSizeTier get sizeTier {
    final txt = (sizeText ?? '').toLowerCase().trim();
    final ml = sizeMl ?? 0.0;

    if (txt.contains('عائلي') ||
        txt.contains('كبير') ||
        txt.contains('لتر') ||
        txt.contains('كجم') ||
        txt.contains('كيلو') ||
        ml >= 900) {
      return ProductSizeTier.large;
    }
    if (txt.contains('صغير') || (ml > 0 && ml < 250)) {
      return ProductSizeTier.small;
    }
    if (txt.contains('وسط') || (ml >= 250 && ml < 900)) {
      return ProductSizeTier.medium;
    }
    return ProductSizeTier.all;
  }

  factory ProductModel.fromMap(Map<String, dynamic> m) {
    final rawUnits = m['units'];

    final units = rawUnits is List
        ? rawUnits
            .whereType<Map>()
            .map(
              (e) => ProductUnit.fromMap(
                Map<String, dynamic>.from(e),
              ),
            )
            .toList()
        : <ProductUnit>[];

    String? readDate(dynamic value) {
      if (value == null) return null;
      if (value is Timestamp) {
        return value.toDate().toIso8601String();
      }
      if (value is DateTime) {
        return value.toIso8601String();
      }
      return value.toString();
    }

    final basePrice = (m['price'] as num?)?.toDouble() ?? 0.0;
    final cartonItems = (m['items_per_carton'] as num?)?.toInt() ?? 1;
    final sizeMl = (m['size_ml'] as num?)?.toDouble();
    final prodDate = readDate(m['production_date']);
    final expDate = readDate(m['expiry_date']);
    final imageUrl = m['image_url'] as String?;
    final barcode = m['barcode']?.toString().trim();

    // حجب أسعار التكلفة تماماً عن هواتف التجار وتأمين الوحدات
    final sanitizedUnits = units
        .map((u) => ProductUnit(
              label: u.label,
              qty: u.qty,
              price: u.price,
              costPrice: null, // حجب التكلفة
              imageUrl: u.imageUrl,
              sizeMl: u.sizeMl,
              productionDate: u.productionDate,
              expiryDate: u.expiryDate,
              barcode: u.barcode,
            ))
        .toList();

    final cartonIndex =
        sanitizedUnits.indexWhere((u) => u.label.trim() == 'كرتون');
    if (cartonIndex == -1) {
      sanitizedUnits.insert(
        0,
        ProductUnit(
          label: 'كرتون',
          qty: cartonItems > 0 ? cartonItems : 1,
          price: basePrice,
          costPrice: null,
          imageUrl: imageUrl,
          sizeMl: sizeMl,
          productionDate: prodDate != null ? DateTime.tryParse(prodDate) : null,
          expiryDate: expDate != null ? DateTime.tryParse(expDate) : null,
          barcode: barcode,
        ),
      );
    } else {
      final existingCarton = sanitizedUnits[cartonIndex];
      sanitizedUnits[cartonIndex] = ProductUnit(
        label: 'كرتون',
        qty: existingCarton.qty > 0
            ? existingCarton.qty
            : (cartonItems > 0 ? cartonItems : 1),
        // الحفاظ على السعر المخصص للكرتون إن وُجد وإلا استخدام basePrice
        price: existingCarton.price > 0 ? existingCarton.price : basePrice,
        costPrice: null,
        imageUrl: existingCarton.imageUrl ?? imageUrl,
        sizeMl: existingCarton.sizeMl ?? sizeMl,
        productionDate: existingCarton.productionDate ??
            (prodDate != null ? DateTime.tryParse(prodDate) : null),
        expiryDate: existingCarton.expiryDate ??
            (expDate != null ? DateTime.tryParse(expDate) : null),
        barcode: existingCarton.barcode ?? barcode,
      );
    }
    final rawVariants = m['variants'];
    final sanitizedVariants = rawVariants is List
        ? rawVariants.whereType<Map>().map((rawV) {
            final v = ProductVariant.fromMap(Map<String, dynamic>.from(rawV));
            final vUnits = v.units
                .map((u) => ProductUnit(
                      label: u.label,
                      qty: u.qty,
                      price: u.price,
                      costPrice: null,
                      imageUrl: u.imageUrl,
                      sizeMl: u.sizeMl,
                      productionDate: u.productionDate,
                      expiryDate: u.expiryDate,
                      barcode: u.barcode,
                    ))
                .toList();
            final cIdx = vUnits.indexWhere((u) => u.label.trim() == 'كرتون');
            if (cIdx == -1) {
              vUnits.insert(
                0,
                ProductUnit(
                  label: 'كرتون',
                  qty: v.itemsPerCarton > 0 ? v.itemsPerCarton : 1,
                  price: v.price,
                  costPrice: null,
                  imageUrl: v.imageUrl ?? imageUrl,
                  sizeMl: v.sizeMl,
                  productionDate: v.productionDate,
                  expiryDate: v.expiryDate,
                  barcode: v.barcode,
                ),
              );
            } else {
              final existingC = vUnits[cIdx];
              vUnits[cIdx] = ProductUnit(
                label: 'كرتون',
                qty: existingC.qty > 0
                    ? existingC.qty
                    : (v.itemsPerCarton > 0 ? v.itemsPerCarton : 1),
                price: existingC.price > 0 ? existingC.price : v.price,
                costPrice: null,
                imageUrl: existingC.imageUrl ?? v.imageUrl ?? imageUrl,
                sizeMl: existingC.sizeMl ?? v.sizeMl,
                productionDate: existingC.productionDate ?? v.productionDate,
                expiryDate: existingC.expiryDate ?? v.expiryDate,
                barcode: existingC.barcode ?? v.barcode,
              );
            }
            return ProductVariant(
              id: v.id,
              label: v.label,
              price: v.price,
              costPrice: null,
              stock: v.stock,
              itemsPerCarton: v.itemsPerCarton,
              sizeText: v.sizeText,
              sizeMl: v.sizeMl,
              imageUrl: v.imageUrl ?? imageUrl,
              barcode: v.barcode,
              productionDate: v.productionDate,
              expiryDate: v.expiryDate,
              units: vUnits,
            );
          }).toList()
        : <ProductVariant>[];

    return ProductModel(
      id: m['id']?.toString() ?? '',
      name: (m['name'] as String?)?.trim() ?? '',
      price: basePrice,
      imageUrl: imageUrl,
      brandId: m['brand_id']?.toString() ?? '',
      description: m['description'] as String?,
      sizeMl: sizeMl,
      sizeText: m['size_text']?.toString() ?? m['size_label']?.toString(),
      itemsPerCarton: (m['items_per_carton'] as num?)?.toInt(),
      productionDate: prodDate,
      expiryDate: expDate,
      costPrice: 0.0,
      stock: (m['stock'] as num?)?.toDouble() ?? 0.0,
      salesCount: (m['sales_count'] as num?)?.toInt() ?? 0,
      barcode: barcode,
      units: sanitizedUnits,
      variants: sanitizedVariants,
    );
  }

  factory ProductModel.fromJson(Map<String, dynamic> m) =>
      ProductModel.fromMap(m);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'price': price,
      'image_url': imageUrl,
      'brand_id': brandId,
      'description': description,
      'size_ml': sizeMl,
      'items_per_carton': itemsPerCarton,
      'production_date': productionDate,
      'expiry_date': expiryDate,
      'cost_price': costPrice,
      'stock': stock,
      if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
      'units': units.map((unit) => unit.toMap()).toList(),
      'variants': variants.map((v) => v.toJson()).toList(),
    };
  }
}

class ProductCatalogPage {
  final List<ProductModel> products;
  final bool hasMore;
  final bool isLoadingMore;
  final String? loadMoreError;

  const ProductCatalogPage({
    required this.products,
    required this.hasMore,
    this.isLoadingMore = false,
    this.loadMoreError,
  });

  ProductCatalogPage copyWith({
    List<ProductModel>? products,
    bool? hasMore,
    bool? isLoadingMore,
    String? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return ProductCatalogPage(
      products: products ?? this.products,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadMoreError:
          clearLoadMoreError ? null : loadMoreError ?? this.loadMoreError,
    );
  }
}

final productsStreamProvider = StateNotifierProvider.autoDispose
    .family<ProductCatalogNotifier, AsyncValue<ProductCatalogPage>, String>(
  (ref, brandId) => ProductCatalogNotifier(brandId),
);

class ProductCatalogNotifier
    extends StateNotifier<AsyncValue<ProductCatalogPage>> {
  ProductCatalogNotifier(this.brandId) : super(const AsyncValue.loading()) {
    _subscribeToFirstPage();
  }

  static const int _pageSize = 50;
  final String brandId;
  final _db = FirebaseFirestore.instance;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  final Map<String, ProductModel> _firstPage = {};
  final Map<String, ProductModel> _loadedPages = {};
  String? firstPageLastId;
  bool _hasMore = true;
  bool _isLoadingMore = false;
  Query<Map<String, dynamic>> get _baseQuery => _db
      .collection('products')
      .where('brand_id', isEqualTo: brandId)
      .where('is_deleted', isEqualTo: false)
      .orderBy('name');
  void _subscribeToFirstPage() {
    _subscription = _baseQuery
        .limit(_pageSize)
        .snapshots(includeMetadataChanges: false)
        .listen(
      (snapshot) {
        firstPageLastId = snapshot.docs.isEmpty ? null : snapshot.docs.last.id;
        if (_loadedPages.isEmpty) {
          _cursor = snapshot.docs.isEmpty ? null : snapshot.docs.last;
          _hasMore = snapshot.docs.length == _pageSize;
        }
        _firstPage
          ..clear()
          ..addEntries(
            snapshot.docs
                .where((doc) =>
                    doc.data()['is_deleted'] != true &&
                    doc.data()['is_active'] != false)
                .map((doc) {
              final product = ProductModel.fromMap({
                'id': doc.id,
                ...doc.data(),
              });
              return MapEntry(product.id, product);
            }).where((entry) => entry.value.name.trim().isNotEmpty),
          );
        for (final id in _firstPage.keys) {
          _loadedPages.remove(id);
        }
        _publish();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (state.value == null) {
          state = AsyncValue.error(error, stackTrace);
        } else {
          debugPrint('Product first-page stream failed for $brandId: $error');
        }
      },
    );
  }

  Future<void> loadMore() async {
    if (!_hasMore || _isLoadingMore || _cursor == null) return;
    _isLoadingMore = true;
    _publish(clearLoadMoreError: true);

    try {
      final snapshot = await _baseQuery
          .startAfterDocument(_cursor!)
          .limit(_pageSize)
          .get(const GetOptions(source: Source.serverAndCache));
      if (!mounted) return;

      if (snapshot.docs.isNotEmpty) {
        _cursor = snapshot.docs.last;
        for (final doc in snapshot.docs) {
          final data = doc.data();
          if (data['is_deleted'] == true || data['is_active'] == false) {
            _loadedPages.remove(doc.id);
            continue;
          }
          final product = ProductModel.fromMap({'id': doc.id, ...data});
          if (product.name.trim().isNotEmpty) {
            _loadedPages[product.id] = product;
          }
        }
      }
      _hasMore = snapshot.docs.length == _pageSize;
      _isLoadingMore = false;
      _publish();
    } catch (error, stackTrace) {
      _isLoadingMore = false;
      debugPrint('Product pagination failed for $brandId: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _publish(loadMoreError: 'تعذر تحميل المزيد من المنتجات');
      }
    }
  }

  void _publish({
    String? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    if (!mounted) return;
    final products = <String, ProductModel>{..._loadedPages, ..._firstPage};
    final sorted = products.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    state = AsyncValue.data(ProductCatalogPage(
      products: sorted,
      hasMore: _hasMore,
      isLoadingMore: _isLoadingMore,
      loadMoreError: clearLoadMoreError
          ? null
          : loadMoreError ?? state.value?.loadMoreError,
    ));
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
