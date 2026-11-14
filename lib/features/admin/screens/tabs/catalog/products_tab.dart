import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../services/admin_service.dart';
import 'catalog_providers.dart';
import 'catalog_helpers.dart';
import 'catalog_widgets.dart';
import 'product_units_editor.dart';
import 'package:wissal/core/models/product_unit.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../merchant/barcode/barcode_scanner_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:wissal/core/services/image_precache_service.dart';
import 'package:wissal/core/utils/arabic_normalizer.dart';
import 'dart:async';

String formatFirestoreDate(dynamic value) {
  DateTime? date;

  if (value is Timestamp) {
    date = value.toDate();
  } else if (value is DateTime) {
    date = value;
  } else if (value is String && value.trim().isNotEmpty) {
    date = DateTime.tryParse(value.trim());
  }

  if (date == null) return '';

  return '${date.year}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

class DateInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final normalizedOld = ArabicNormalizer.normalizeDigits(oldValue.text);
    final normalizedNew = ArabicNormalizer.normalizeDigits(newValue.text);

    var digits = normalizedNew.replaceAll(RegExp(r'[^0-9]'), '');
    final oldDigits = normalizedOld.replaceAll(RegExp(r'[^0-9]'), '');

    if (normalizedNew.length < normalizedOld.length &&
        digits == oldDigits &&
        digits.isNotEmpty) {
      digits = digits.substring(0, digits.length - 1);
    }

    final buffer = StringBuffer();
    for (int i = 0; i < digits.length && i < 8; i++) {
      if (i == 4 || i == 6) {
        buffer.write('-');
      }
      buffer.write(digits[i]);
    }

    final formatted = buffer.toString();
    final rawOffset =
        newValue.selection.baseOffset.clamp(0, normalizedNew.length);
    final digitsBeforeCursor = normalizedNew
        .substring(0, rawOffset)
        .replaceAll(RegExp(r'[^0-9]'), '')
        .length;

    int cursorPosition = formatted.length;
    if (normalizedNew.length >= normalizedOld.length || digits != oldDigits) {
      int seenDigits = 0;
      cursorPosition = 0;
      while (cursorPosition < formatted.length &&
          seenDigits < digitsBeforeCursor) {
        if (formatted[cursorPosition] != '-') seenDigits++;
        cursorPosition++;
      }
      if (cursorPosition < formatted.length &&
          formatted[cursorPosition] == '-' &&
          digitsBeforeCursor > 0) {
        cursorPosition++;
      }
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: cursorPosition),
    );
  }
}

class ProductsTab extends ConsumerStatefulWidget {
  const ProductsTab({super.key});
  @override
  ConsumerState<ProductsTab> createState() => _ProductsTabState();
}

class _ProductsTabState extends ConsumerState<ProductsTab> {
  String _search = '';
  String? _filterCategoryId;
  String? _filterBrandId;
  String _adminSort =
      'default'; // default, bestSelling, lowStock, cheapest, expensive
  Timer? _searchDebounce;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _reloadServerFilter() {
    ref.read(adminProductsProvider.notifier).loadInitial(
          silent: true,
          forceServer: true,
          categoryId: _filterCategoryId ?? '',
          brandId: _filterBrandId ?? '',
          search: _search,
        );
  }

  @override
  Widget build(BuildContext context) {
    final categoriesList = ref.watch(adminCategoriesProvider).value ?? [];
    final brandsAsync = ref.watch(brandsProvider);
    final productsAsync = ref.watch(adminProductsProvider);
    final brandsList = brandsAsync.value ?? [];

    return Column(
      children: [
        // ── 1. فورم الإضافة ──
        AddProductBar(
          brands: brandsList,
          onAdd: (data) async {
            await ref.read(adminServiceProvider).addProduct(
                  name: data['name'],
                  brandId: data['brandId'],
                  price: data['price'],
                  costPrice: data['cost_price'],
                  itemsPerCarton: data['items'],
                  sizeMl: data['size'],
                  sizeText: data['size_text'],
                  stock: (data['stock'] as num?)?.toDouble() ?? 0.0,
                  imageUrl: data['imageUrl'],
                  productionDate: data['production_date'],
                  expiryDate: data['expiry_date'],
                  barcode: data['barcode'],
                  units: List<Map<String, dynamic>>.from(
                    data['units'] as List? ?? const [],
                  ),
                  variants: List<Map<String, dynamic>>.from(
                    data['variants'] as List? ?? const [],
                  ),
                );
            ref
                .read(adminProductsProvider.notifier)
                .loadInitial(silent: true, forceServer: true);
          },
        ),

        // ── 2. شريط البحث ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) {
                    setState(() => _search = v.trim().toLowerCase());
                    _searchDebounce?.cancel();
                    _searchDebounce = Timer(
                      const Duration(milliseconds: 300),
                      _reloadServerFilter,
                    );
                  },
                  decoration: InputDecoration(
                    hintText: 'بحث بالاسم أو الباركود...',
                    hintStyle: const TextStyle(
                        fontFamily: 'Cairo',
                        color: Color(0xFFAAAAAA),
                        fontSize: 13),
                    prefixIcon: const Icon(Icons.search_rounded,
                        color: Colors.grey, size: 20),
                    suffixIcon: _search.isNotEmpty
                        ? GestureDetector(
                            onTap: () {
                              setState(() => _search = '');
                              _reloadServerFilter();
                            },
                            child: const Icon(Icons.close_rounded,
                                size: 18, color: Colors.grey),
                          )
                        : null,
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                  ),
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  productsAsync.maybeWhen(
                      data: (l) => '${l.length}', orElse: () => '0'),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary),
                ),
              ),
            ],
          ),
        ),

        // ── 3. شريط فلاتر الإدارة (الصنف، الشركة، نوع الترتيب) ──
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // فلتر الصنف
              DropdownButton<String?>(
                value: categoriesList
                        .any((c) => c['id'].toString() == _filterCategoryId)
                    ? _filterCategoryId
                    : null,
                hint: const Text('كل الأصناف',
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 11)),
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(
                      value: null,
                      child: Text('كل الأصناف',
                          style: TextStyle(fontFamily: 'Cairo', fontSize: 11))),
                  ...categoriesList.map((c) => DropdownMenuItem(
                      value: c['id'].toString(),
                      child: Text(c['name'] ?? '',
                          style: const TextStyle(
                              fontFamily: 'Cairo', fontSize: 11)))),
                ],
                onChanged: (v) {
                  setState(() {
                    _filterCategoryId = v;
                    if (v != null && _filterBrandId != null) {
                      final stillValid = brandsList.any((b) =>
                          b['id'].toString() == _filterBrandId &&
                          b['category_id']?.toString() == v);
                      if (!stillValid) _filterBrandId = null;
                    }
                  });
                  _reloadServerFilter();
                },
              ),
              const SizedBox(width: 8),

              // فلتر الشركة (مصفّى تلقائياً حسب الصنف المختار)
              Builder(
                builder: (_) {
                  final scopedBrands = _filterCategoryId == null
                      ? brandsList
                      : brandsList
                          .where((b) =>
                              b['category_id']?.toString() == _filterCategoryId)
                          .toList();
                  final validBrandValue = scopedBrands
                          .any((b) => b['id'].toString() == _filterBrandId)
                      ? _filterBrandId
                      : null;
                  return DropdownButton<String?>(
                    value: validBrandValue,
                    hint: const Text('كل الشركات',
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 11)),
                    underline: const SizedBox.shrink(),
                    items: [
                      const DropdownMenuItem(
                          value: null,
                          child: Text('كل الشركات',
                              style: TextStyle(
                                  fontFamily: 'Cairo', fontSize: 11))),
                      ...scopedBrands.map((b) => DropdownMenuItem(
                          value: b['id'].toString(),
                          child: Text(b['name'] ?? '',
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontSize: 11)))),
                    ],
                    onChanged: (v) {
                      setState(() => _filterBrandId = v);
                      _reloadServerFilter();
                    },
                  );
                },
              ),
              const SizedBox(width: 8),

              // نوع الترتيب للأدمن
              DropdownButton<String>(
                value: _adminSort,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(
                      value: 'default',
                      child: Text('الترتيب العادي',
                          style: TextStyle(fontFamily: 'Cairo', fontSize: 11))),
                  DropdownMenuItem(
                      value: 'bestSelling',
                      child: Text('الأكثر مبيعاً 🔥',
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 11,
                              fontWeight: FontWeight.bold))),
                  DropdownMenuItem(
                      value: 'lowStock',
                      child: Text('أوشك على النفاد ⚠️',
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 11,
                              color: Colors.red))),
                  DropdownMenuItem(
                      value: 'cheapest',
                      child: Text('الأرخص سعراً',
                          style: TextStyle(fontFamily: 'Cairo', fontSize: 11))),
                  DropdownMenuItem(
                      value: 'expensive',
                      child: Text('الأعلى سعراً',
                          style: TextStyle(fontFamily: 'Cairo', fontSize: 11))),
                ],
                onChanged: (v) => setState(() => _adminSort = v ?? 'default'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // ── 3. القائمة فقط هي التي تتغير حالتها (Loading / Error / Data) ──
        Expanded(
          child: productsAsync.when(
            loading: () => const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
            error: (e, _) => Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 48, color: Colors.red[300]),
                  const SizedBox(height: 12),
                  const Text('فشل تحميل المنتجات',
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 15)),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: () =>
                        ref.read(adminProductsProvider.notifier).loadInitial(),
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('إعادة المحاولة',
                        style: TextStyle(fontFamily: 'Cairo')),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12))),
                  ),
                ],
              ),
            ),
            data: (list) {
              final filtered = list.where((p) {
                if (p['is_deleted'] == true) return false;

                // فلترة الصنف للأدمن
                if (_filterCategoryId != null &&
                    p['category_id']?.toString() != _filterCategoryId) {
                  return false;
                }

                // فلترة الماركة للأدمن (مثلاً: نانا)
                if (_filterBrandId != null &&
                    p['brand_id']?.toString() != _filterBrandId) {
                  return false;
                }

                // بحث شامل بالاسم المطبع أو الباركود (الأساسي والوحدات والأحجام)
                if (_search.isNotEmpty) {
                  final normQuery = ArabicNormalizer.normalize(_search);
                  final cleanBarcodeQuery =
                      BarcodeScannerScreen.cleanBarcode(_search);
                  final normName =
                      ArabicNormalizer.normalize(p['name']?.toString() ?? '');
                  final tokens =
                      normQuery.split(' ').where((t) => t.isNotEmpty).toList();
                  final matchesName = tokens.isNotEmpty &&
                      tokens.every((t) => normName.contains(t));
                  final matchesMainBarcode = (p['barcode'] ?? '')
                      .toString()
                      .toLowerCase()
                      .contains(_search);
                  final allBarcodes = p['all_barcodes'];
                  final matchesAllBarcodes = cleanBarcodeQuery.isNotEmpty &&
                      allBarcodes is List &&
                      allBarcodes
                          .any((b) => b.toString().contains(cleanBarcodeQuery));
                  if (!matchesName &&
                      !matchesMainBarcode &&
                      !matchesAllBarcodes) {
                    return false;
                  }
                }

                return true;
              }).toList();

              // تطبيق الترتيب المختار في الإدارة
              if (_adminSort == 'bestSelling') {
                filtered.sort((a, b) =>
                    ((b['sales_count'] as num?)?.toInt() ?? 0)
                        .compareTo((a['sales_count'] as num?)?.toInt() ?? 0));
              } else if (_adminSort == 'lowStock') {
                filtered.sort((a, b) =>
                    ((a['stock'] as num?)?.toDouble() ?? 0.0)
                        .compareTo((b['stock'] as num?)?.toDouble() ?? 0.0));
              } else if (_adminSort == 'cheapest') {
                filtered.sort((a, b) =>
                    ((a['price'] as num?)?.toDouble() ?? 0.0)
                        .compareTo((b['price'] as num?)?.toDouble() ?? 0.0));
              } else if (_adminSort == 'expensive') {
                filtered.sort((a, b) =>
                    ((b['price'] as num?)?.toDouble() ?? 0.0)
                        .compareTo((a['price'] as num?)?.toDouble() ?? 0.0));
              }
              if (filtered.isEmpty) {
                return _search.isNotEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.search_off_rounded,
                                size: 48, color: Colors.grey[300]),
                            const SizedBox(height: 12),
                            Text('لا نتائج لـ "$_search"',
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 14,
                                    color: Colors.grey[400])),
                          ],
                        ),
                      )
                    : const CatalogEmptyState(
                        label: 'لا توجد منتجات',
                        icon: Icons.inventory_2_outlined);
              }

              final hasMore = ref.watch(adminProductsProvider.notifier).hasMore;

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                itemCount: filtered.length + (hasMore ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == filtered.length) {
                    final isLoadingMore =
                        ref.watch(productsLoadingMoreProvider);
                    return Center(
                      child: TextButton.icon(
                        onPressed: isLoadingMore
                            ? null
                            : () => ref
                                .read(adminProductsProvider.notifier)
                                .loadMore(),
                        icon: isLoadingMore
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.arrow_downward_rounded),
                        label: const Text('تحميل المزيد',
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontWeight: FontWeight.w700)),
                      ),
                    );
                  }
                  final brandId = filtered[i]['brand_id']?.toString();
                  final brand = brandsList.firstWhere(
                    (b) => b['id'].toString() == brandId,
                    orElse: () => <String, dynamic>{},
                  );
                  return _ProductTile(
                    product: filtered[i],
                    brandName: brand['name'] as String?,
                    onDelete: () async {
                      if (await confirmDelete(
                          context, filtered[i]['name'] ?? '')) {
                        await ref
                            .read(adminServiceProvider)
                            .deleteProduct(filtered[i]['id'].toString());
                        _reloadServerFilter();
                      }
                    },
                    onEdit: () =>
                        _showEditSheet(context, ref, filtered[i], brandsList),
                    onToggleActive: (val) async {
                      await ref.read(adminServiceProvider).updateProduct(
                          filtered[i]['id'].toString(), {'is_active': val});
                      _reloadServerFilter();
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _showEditSheet(BuildContext context, WidgetRef ref,
      Map<String, dynamic> product, List<Map<String, dynamic>> brands) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ProductEditSheet(
        product: product,
        brands: brands,
        onSaved: () {
          _reloadServerFilter();
        },
      ),
    );
  }
}

// ════════════════════════════════════════
// كارت المنتج
// ════════════════════════════════════════
class _ProductTile extends StatelessWidget {
  final Map<String, dynamic> product;
  final String? brandName;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggleActive;

  const _ProductTile({
    required this.product,
    required this.onDelete,
    required this.onEdit,
    required this.onToggleActive,
    this.brandName,
  });

  @override
  Widget build(BuildContext context) {
    final imageUrl = product['image_url'] as String?;
    final price = (product['price'] as num?)?.toStringAsFixed(0) ?? '0';
    final rawVariants = product['variants'];
    final double rawStock = (rawVariants is List && rawVariants.isNotEmpty)
        ? rawVariants.whereType<Map>().fold<double>(
            0.0, (sum, v) => sum + ((v['stock'] as num?)?.toDouble() ?? 0.0))
        : ((product['stock'] as num?)?.toDouble() ?? 0.0);
    final bool isIntegerStock = (rawStock - rawStock.round()).abs() < 0.001;
    final stockStr = isIntegerStock
        ? rawStock.round().toString()
        : rawStock.toStringAsFixed(2);
    final stock = rawStock;
    final isActive = product['is_active'] as bool? ?? true;
    final expiryDate = formatFirestoreDate(product['expiry_date']);
    final costPrice = (product['cost_price'] as num?)?.toDouble() ?? 0;
    final salePrice = (product['price'] as num?)?.toDouble() ?? 0;
    final profit = salePrice - costPrice;
    final rawUnits = product['units'];

    final units = rawUnits is List
        ? rawUnits
            .whereType<Map>()
            .map((unit) => Map<String, dynamic>.from(unit))
            .toList()
        : <Map<String, dynamic>>[];
    final stockColor = stock > 10
        ? Colors.green
        : stock > 0
            ? Colors.orange
            : Colors.red;

    bool isExpiringSoon = false;
    bool isExpired = false;
    if (expiryDate.isNotEmpty) {
      final exp = DateTime.tryParse(expiryDate);
      if (exp != null) {
        final now = DateTime.now();
        isExpired = exp.isBefore(now);
        isExpiringSoon =
            !isExpired && exp.isBefore(now.add(const Duration(days: 30)));
      }
    }

    final sizeDisplay =
        (product['size_text']?.toString().trim().isNotEmpty ?? false)
            ? product['size_text'].toString().trim()
            : (product['size_ml'] != null ? '${product['size_ml']} مل' : null);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: !isActive
              ? Colors.red.withValues(alpha: 0.2)
              : isExpired
                  ? Colors.red.withValues(alpha: 0.2)
                  : isExpiringSoon
                      ? Colors.orange.withValues(alpha: 0.2)
                      : Colors.transparent,
        ),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(16),
                  bottomRight: Radius.circular(0),
                ),
                child: imageUrl != null && imageUrl.isNotEmpty
                    ? CachedNetworkImage(
                        cacheManager:
                            ImagePrecacheService.instance.cacheManager,
                        imageUrl: imageUrl,
                        width: 80,
                        height: 90,
                        memCacheWidth: 200,
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            _placeholder(product['name'] ?? ''),
                        errorWidget: (_, __, ___) =>
                            _placeholder(product['name'] ?? ''),
                      )
                    : _placeholder(product['name'] ?? ''),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(product['name'] ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14)),
                        ),
                        if (!isActive)
                          _tag('متوقف', Colors.red)
                        else if (isExpired)
                          _tag('منتهي', Colors.red)
                        else if (isExpiringSoon)
                          _tag('ينتهي قريباً', Colors.orange),
                      ]),
                      if (brandName != null) ...[
                        const SizedBox(height: 2),
                        Row(children: [
                          Icon(Icons.business_rounded,
                              size: 11, color: Colors.grey[400]),
                          const SizedBox(width: 3),
                          Text(brandName!,
                              style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 11,
                                  color: Colors.grey[500])),
                        ]),
                      ],
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _badge(
                            '$price ر.ي',
                            AppColors.primary,
                            Icons.sell_rounded,
                          ),
                          if (costPrice > 0)
                            _badge(
                              'ربح ${profit.toStringAsFixed(0)} ر.ي',
                              profit > 0 ? Colors.teal : Colors.red,
                              Icons.trending_up_rounded,
                            ),
                          _badge(
                            'المبيعات: ${(product['sales_count'] as num?)?.toInt() ?? 0}',
                            Colors.deepOrange,
                            Icons.local_fire_department_rounded,
                          ),
                          _badge(
                            '$stockStr كرتون',
                            stockColor,
                            Icons.inventory_2_rounded,
                          ),
                          if (sizeDisplay != null && sizeDisplay.isNotEmpty)
                            _badge(
                              sizeDisplay,
                              Colors.blue,
                              Icons.straighten_rounded,
                            ),
                          if (product['barcode'] != null &&
                              product['barcode'].toString().trim().isNotEmpty)
                            _badge(
                              product['barcode'].toString().trim(),
                              Colors.indigo,
                              Icons.qr_code_2_rounded,
                            ),
                        ],
                      ),
                      if (units.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: units.map((unit) {
                            final label =
                                unit['label']?.toString().trim() ?? '';
                            final unitPrice =
                                (unit['price'] as num?)?.toDouble() ?? 0;
                            final unitQty = (unit['qty'] as num?)?.toInt() ?? 0;

                            final unitText = [
                              if (label.isNotEmpty) label,
                              '${unitPrice.toStringAsFixed(0)} ر.ي',
                              if (unitQty > 0) '$unitQty حبة',
                            ].join(' • ');

                            return _badge(
                              unitText,
                              Colors.deepPurple,
                              Icons.inventory_2_outlined,
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          Container(
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFB),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
            ),
            child: Row(children: [
              _ActionBtn(
                icon: isActive
                    ? Icons.toggle_on_rounded
                    : Icons.toggle_off_rounded,
                label: isActive ? 'نشط' : 'متوقف',
                color: isActive ? Colors.green : Colors.grey,
                onTap: () => onToggleActive(!isActive),
              ),
              _Divider(),
              _ActionBtn(
                icon: Icons.edit_rounded,
                label: 'تعديل',
                color: AppColors.primary,
                onTap: onEdit,
              ),
              _Divider(),
              _ActionBtn(
                icon: Icons.delete_rounded,
                label: 'حذف',
                color: Colors.red,
                onTap: onDelete,
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(String name) => Container(
        width: 80,
        height: 90,
        color: AppColors.primary.withValues(alpha: 0.06),
        child: Center(
          child: Text(
            name.isNotEmpty ? name[0].toUpperCase() : 'P',
            style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 28,
                fontWeight: FontWeight.w900,
                color: AppColors.primary),
          ),
        ),
      );

  Widget _tag(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w700)),
      );

  Widget _badge(String label, Color color, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ]),
      );
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionBtn(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(height: 2),
                Text(label,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: color)),
              ],
            ),
          ),
        ),
      );
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 30, color: Colors.grey[200]);
}

// ════════════════════════════════════════
// فورم إضافة منتج
// ════════════════════════════════════════
class AddProductBar extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> brands;
  final Future<void> Function(Map<String, dynamic> data) onAdd;
  const AddProductBar({super.key, required this.brands, required this.onAdd});

  @override
  ConsumerState<AddProductBar> createState() => _AddProductBarState();
}

class _AddProductBarState extends ConsumerState<AddProductBar> {
  final _nameCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _costCtrl = TextEditingController();
  final _itemsCtrl = TextEditingController();
  final _sizeCtrl = TextEditingController();
  final _stockCtrl = TextEditingController();
  final _prodCtrl = TextEditingController();
  final _expCtrl = TextEditingController();
  final _barcodeCtrl = TextEditingController();
  final _brandFieldKey = GlobalKey<FormFieldState<String>>();
  String? _selectedBrandId;
  XFile? _image;
  Uint8List? _imageBytes;
  String? _uploadedImageUrl;
  bool _loading = false;
  String? _error;
  List<ProductUnit> _units = [];
  List<ProductVariant> _variants = [];
  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    _costCtrl.dispose();
    _itemsCtrl.dispose();
    _sizeCtrl.dispose();
    _stockCtrl.dispose();
    _prodCtrl.dispose();
    _expCtrl.dispose();
    _barcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    setState(() => _error = null);
    try {
      final (file, bytes) = await pickCatalogImage();
      if (!mounted) return;
      if (file != null && bytes != null) {
        if (bytes.lengthInBytes > 3 * 1024 * 1024) {
          setState(() => _error = 'الصورة كبيرة جداً، الحد الأقصى 3MB');
          return;
        }
        setState(() {
          _image = file;
          _imageBytes = bytes;
          _uploadedImageUrl = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'تعذّر فتح المعرض، تحقق من صلاحية الصور');
      }
    }
  }

  Future<void> _quickAddBrand(BuildContext sheetCtx, StateSetter setSt) async {
    final nameCtrl = TextEditingController();
    String? selectedCatId;
    XFile? logoFile;
    Uint8List? logoBytes;
    bool savingBrand = false;
    String? brandErr;

    final categories = ref.read(adminCategoriesProvider).value ?? [];

    await showModalBottomSheet<String>(
      context: sheetCtx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bCtx) => StatefulBuilder(
        builder: (dialogCtx, setBSt) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(dialogCtx).viewInsets.bottom,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.business_rounded,
                          color: AppColors.primary, size: 20),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'إضافة شركة جديدة سريعاً',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 20),
                GestureDetector(
                  onTap: savingBrand
                      ? null
                      : () async {
                          final (f, b) = await pickCatalogImage();
                          if (f != null && b != null) {
                            setBSt(() {
                              logoFile = f;
                              logoBytes = b;
                            });
                          }
                        },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFB),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: logoBytes != null
                              ? Image.memory(logoBytes!,
                                  width: 40, height: 40, fit: BoxFit.cover)
                              : Container(
                                  width: 40,
                                  height: 40,
                                  color: AppColors.primary
                                      .withValues(alpha: 0.08),
                                  child: const Icon(Icons.add_a_photo_rounded,
                                      color: AppColors.primary, size: 20),
                                ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            logoBytes != null
                                ? 'تم اختيار الشعار ✓'
                                : 'شعار الشركة (اختياري)',
                            style: const TextStyle(
                                fontFamily: 'Cairo', fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: catalogInputDec('اسم الشركة *'),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: selectedCatId,
                  hint: const Text('اختر الصنف التابع له *',
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 13)),
                  decoration: catalogInputDec('الصنف التابع له'),
                  items: categories
                      .map((c) => DropdownMenuItem(
                            value: c['id'].toString(),
                            child: Text(c['name'] ?? '',
                                style: const TextStyle(
                                    fontFamily: 'Cairo', fontSize: 13)),
                          ))
                      .toList(),
                  onChanged: (v) => setBSt(() => selectedCatId = v),
                ),
                if (brandErr != null) ...[
                  const SizedBox(height: 8),
                  Text(brandErr!,
                      style: const TextStyle(
                          fontFamily: 'Cairo',
                          color: Colors.red,
                          fontSize: 12)),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: savingBrand
                        ? null
                        : () async {
                            final bName = nameCtrl.text.trim();
                            if (bName.isEmpty) {
                              setBSt(() => brandErr = 'اسم الشركة مطلوب');
                              return;
                            }
                            if (selectedCatId == null) {
                              setBSt(() => brandErr = 'اختر الصنف التابع له');
                              return;
                            }
                            setBSt(() {
                              savingBrand = true;
                              brandErr = null;
                            });
                            try {
                              String? logoUrl;
                              if (logoFile != null) {
                                logoUrl = await uploadCatalogImage(logoFile!);
                              }
                              await ref.read(adminServiceProvider).addBrand(
                                    name: bName,
                                    categoryId: selectedCatId!,
                                    logoUrl: logoUrl,
                                  );
                              ref.invalidate(brandsProvider);
                              final updated =
                                  await ref.read(brandsProvider.future);
                              final match = updated.firstWhere(
                                (b) => b['name'] == bName,
                                orElse: () => updated.last,
                              );
                              final newId = match['id'].toString();
                              if (dialogCtx.mounted) {
                                Navigator.pop(dialogCtx, newId);
                              }
                            } catch (e) {
                              setBSt(() {
                                savingBrand = false;
                                brandErr = 'فشل إضافة الشركة: $e';
                              });
                            }
                          },
                    icon: savingBrand
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.add_rounded, size: 20),
                    label: Text(
                      savingBrand ? 'جاري الإضافة...' : 'حفظ واختيار الشركة',
                      style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.w800,
                          fontSize: 14),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).then((newBrandId) {
      if (newBrandId != null && mounted) {
        setSt(() {
          _selectedBrandId = newBrandId;
        });
      }
    });
  }

  void _clearForm() {
    for (final c in [
      _nameCtrl,
      _priceCtrl,
      _costCtrl,
      _stockCtrl,
      _itemsCtrl,
      _sizeCtrl,
      _prodCtrl,
      _expCtrl,
      _barcodeCtrl,
    ]) {
      c.clear();
    }
    _brandFieldKey.currentState?.reset();
    setState(() {
      _image = null;
      _imageBytes = null;
      _uploadedImageUrl = null;
      _selectedBrandId = null;
      _error = null;
      _units = [];
      _variants = [];
      _loading = false;
    });
  }

  Future<void> _submit(BuildContext sheetCtx, StateSetter setSt) async {
    setSt(() => _error = null);
    if (_nameCtrl.text.trim().isEmpty) {
      setSt(() => _error = 'اسم المنتج مطلوب');
      return;
    }
    if (_selectedBrandId == null) {
      setSt(() => _error = 'اختر الشركة أولاً');
      return;
    }
    final rawPriceText =
        ArabicNormalizer.normalizeDigits(_priceCtrl.text).trim();
    double? parsedPrice = double.tryParse(rawPriceText);
    if (parsedPrice == null && _variants.isNotEmpty) {
      parsedPrice =
          _variants.map((v) => v.price).reduce((a, b) => a < b ? a : b);
    }
    if (parsedPrice == null || parsedPrice < 0) {
      setSt(() => _error = 'أدخل سعراً صحيحاً أو أضف حجماً بسعر محدد');
      return;
    }
    final prodText = ArabicNormalizer.normalizeDigits(_prodCtrl.text).trim();
    if (prodText.isNotEmpty && DateTime.tryParse(prodText) == null) {
      setSt(() => _error = 'صيغة تاريخ الإنتاج غير صحيحة (مثال: 2026-05-15)');
      return;
    }
    final expText = ArabicNormalizer.normalizeDigits(_expCtrl.text).trim();
    if (expText.isNotEmpty && DateTime.tryParse(expText) == null) {
      setSt(() => _error = 'صيغة تاريخ الانتهاء غير صحيحة (مثال: 2027-05-15)');
      return;
    }

    setSt(() => _loading = true);
    setState(() => _loading = true);
    try {
      final imageUrl = _uploadedImageUrl ??
          (_image != null ? await uploadCatalogImage(_image!) : null);
      _uploadedImageUrl = imageUrl;

      final sizeInput = _sizeCtrl.text.trim();
      final numericSize = parseSizeMlFromText(sizeInput);
      final parsedCost = double.tryParse(
              ArabicNormalizer.normalizeDigits(_costCtrl.text).trim()) ??
          0;
      final rawStockText =
          ArabicNormalizer.normalizeDigits(_stockCtrl.text).trim();
      final parsedStock = _variants.isNotEmpty && rawStockText.isEmpty
          ? _variants.fold<double>(0.0, (sum, v) => sum + v.stock)
          : (double.tryParse(rawStockText) ?? 0.0);
      final parsedItems = int.tryParse(
          ArabicNormalizer.normalizeDigits(_itemsCtrl.text).trim());

      final payload = {
        'name': _nameCtrl.text.trim(),
        'brandId': _selectedBrandId,
        'price': parsedPrice,
        'cost_price': parsedCost,
        'stock': parsedStock,
        'items': parsedItems,
        'size': numericSize,
        'size_text': sizeInput,
        'barcode':
            _barcodeCtrl.text.trim().isEmpty ? null : _barcodeCtrl.text.trim(),
        'production_date': prodText.isEmpty ? null : prodText,
        'expiry_date': expText.isEmpty ? null : expText,
        'imageUrl': imageUrl,
        'units': _units.map((u) => u.toJson()).toList(),
        'variants': _variants.map((v) => v.toJson()).toList(),
      };

      await widget.onAdd(payload);
      _clearForm();

      if (sheetCtx.mounted && Navigator.of(sheetCtx).canPop()) {
        Navigator.of(sheetCtx).pop();
      }
    } catch (e) {
      if (sheetCtx.mounted) {
        setSt(() {
          _loading = false;
          _error = 'فشل الحفظ: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _openSheet() {
    setState(() {
      _loading = false;
      _error = null;
    });

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(
        maxWidth: 680,
        maxHeight: MediaQuery.of(context).size.height * 0.92,
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFFF5F7FA),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 4),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.add_circle_outline_rounded,
                            color: AppColors.primary, size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'إضافة منتج جديد',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon:
                            const Icon(Icons.close_rounded, color: Colors.grey),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Column(
                        children: [
                          GestureDetector(
                            onTap: _loading
                                ? null
                                : () async {
                                    await _pickImage();
                                    setSt(() {});
                                  },
                            child: Container(
                              width: double.infinity,
                              height: 70,
                              decoration: BoxDecoration(
                                color: _imageBytes != null
                                    ? AppColors.primary.withValues(alpha: 0.04)
                                    : const Color(0xFFF8FAFB),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _imageBytes != null
                                      ? AppColors.primary.withValues(alpha: 0.4)
                                      : Colors.grey.withValues(alpha: 0.2),
                                ),
                              ),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 14),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: _imageBytes != null
                                          ? Image.memory(_imageBytes!,
                                              width: 44,
                                              height: 44,
                                              fit: BoxFit.cover)
                                          : Container(
                                              width: 44,
                                              height: 44,
                                              decoration: BoxDecoration(
                                                color: AppColors.primary
                                                    .withValues(alpha: 0.07),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: const Icon(
                                                Icons
                                                    .add_photo_alternate_rounded,
                                                size: 22,
                                                color: AppColors.primary,
                                              ),
                                            ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _imageBytes != null
                                            ? 'تم اختيار الصورة ✓'
                                            : 'صورة المنتج (اختياري) • أقل من 3MB',
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: _imageBytes != null
                                              ? AppColors.primary
                                              : Colors.grey[600],
                                        ),
                                      ),
                                    ),
                                    if (_imageBytes != null)
                                      GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _image = null;
                                            _imageBytes = null;
                                            _uploadedImageUrl = null;
                                          });
                                          setSt(() {});
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: BoxDecoration(
                                            color: Colors.red
                                                .withValues(alpha: 0.1),
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.close_rounded,
                                              size: 14, color: Colors.red),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              const Text(
                                'الشركة / الماركة *',
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF555555),
                                ),
                              ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: _loading
                                    ? null
                                    : () => _quickAddBrand(sheetContext, setSt),
                                icon: const Icon(
                                    Icons.add_circle_outline_rounded,
                                    size: 15,
                                    color: AppColors.primary),
                                label: const Text(
                                  '+ شركة جديدة',
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary,
                                  ),
                                ),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Builder(builder: (_) {
                            final currentBrands =
                                ref.watch(brandsProvider).value ??
                                    widget.brands;
                            return DropdownButtonFormField<String>(
                              key: _brandFieldKey,
                              initialValue: currentBrands.any((b) =>
                                      b['id'].toString() == _selectedBrandId)
                                  ? _selectedBrandId
                                  : null,
                              hint: const Text('اختر الشركة *',
                                  style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 13,
                                      color: Colors.grey)),
                              decoration: catalogInputDec(''),
                              isExpanded: true,
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 13,
                                color: Colors.black87,
                                fontWeight: FontWeight.bold,
                              ),
                              icon: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: AppColors.primary),
                              items: currentBrands
                                  .map((b) => DropdownMenuItem(
                                        value: b['id'].toString(),
                                        child: Text(
                                          b['name'] ?? '',
                                          style: const TextStyle(
                                            fontFamily: 'Cairo',
                                            fontSize: 13,
                                            color: Colors.black87,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ))
                                  .toList(),
                              onChanged: _loading
                                  ? null
                                  : (v) => setSt(() => _selectedBrandId = v),
                            );
                          }),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _nameCtrl,
                            enabled: !_loading,
                            onChanged: (_) => setSt(() {}),
                            textDirection: TextDirection.rtl,
                            decoration: catalogInputDec('اسم المنتج *'),
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 13,
                              color: Colors.black87,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _priceCtrl,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  inputFormatters: const [
                                    ArabicDigitsInputFormatter()
                                  ],
                                  decoration: catalogInputDec('السعر ر.ي *'),
                                  style: const TextStyle(
                                      fontFamily: 'Cairo', fontSize: 13),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _costCtrl,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  inputFormatters: const [
                                    ArabicDigitsInputFormatter()
                                  ],
                                  decoration: catalogInputDec('سعر الشراء 🔒'),
                                  style: const TextStyle(
                                      fontFamily: 'Cairo', fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _stockCtrl,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  inputFormatters: const [
                                    ArabicDigitsInputFormatter()
                                  ],
                                  decoration: catalogInputDec('مخزون كرتون'),
                                  style: const TextStyle(
                                      fontFamily: 'Cairo', fontSize: 13),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _itemsCtrl,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: const [
                                    ArabicDigitsInputFormatter(
                                        allowDecimal: false)
                                  ],
                                  decoration: catalogInputDec('حبات/كرتون'),
                                  style: const TextStyle(
                                      fontFamily: 'Cairo', fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          CatalogSmallField(
                            ctrl: _sizeCtrl,
                            hint:
                                'الحجم أو الكمية (مثال: 1.5 لتر ، 10 كجم ، 500 مل)',
                            type: TextInputType.text,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: CatalogSmallField(
                                  ctrl: _barcodeCtrl,
                                  hint:
                                      'الباركود الدولي (أدخل يدوياً أو امسح بالكاميرا)',
                                  type: TextInputType.text,
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () async {
                                  final scanned =
                                      await BarcodeScannerScreen.scan(ctx);
                                  if (scanned != null && scanned.isNotEmpty) {
                                    setSt(() => _barcodeCtrl.text = scanned);
                                  }
                                },
                                child: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: AppColors.primary,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(
                                      Icons.qr_code_scanner_rounded,
                                      color: Colors.white,
                                      size: 22),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: _ManualDateField(
                                  ctrl: _prodCtrl,
                                  hint: 'إنتاج: 2026-05-15',
                                  icon: Icons.calendar_today_rounded,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _ManualDateField(
                                  ctrl: _expCtrl,
                                  hint: 'انتهاء: 2027-05-15',
                                  icon: Icons.event_busy_rounded,
                                ),
                              ),
                            ],
                          ),
                          ProductUnitsEditor(
                            productName: _nameCtrl.text.trim(),
                            initialUnits: _units,
                            onChanged: (units) {
                              _units = units;
                              setSt(() {});
                            },
                          ),
                          ProductVariantsEditor(
                            productName: _nameCtrl.text.trim(),
                            initialVariants: _variants,
                            onChanged: (variants) {
                              _variants = variants;
                              setSt(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_error != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: Colors.red.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 10,
                        offset: const Offset(0, -3),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            side: BorderSide(color: Colors.grey.shade300),
                          ),
                          child: const Text('إلغاء',
                              style: TextStyle(
                                  fontFamily: 'Cairo',
                                  color: Colors.grey,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed:
                              _loading ? null : () => _submit(ctx, setSt),
                          icon: _loading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2),
                                )
                              : const Icon(Icons.save_rounded, size: 20),
                          label: Text(
                            _loading ? 'جاري الحفظ...' : 'حفظ المنتج',
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            elevation: 0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: GestureDetector(
        onTap: _openSheet,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          child:
              const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.add_circle_outline_rounded,
                color: AppColors.primary, size: 22),
            SizedBox(width: 8),
            Text('إضافة منتج جديد',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: 14)),
          ]),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// حقل إدخال التاريخ اليدوي المباشر السريع مع التنسيق التلقائي
// ══════════════════════════════════════════════════════════
class _ManualDateField extends StatelessWidget {
  final TextEditingController ctrl;
  final String hint;
  final IconData icon;

  const _ManualDateField({
    required this.ctrl,
    required this.hint,
    required this.icon,
  });

  Future<void> _pickDate(BuildContext context) async {
    final parsed = DateTime.tryParse(ctrl.text.trim());
    final initial = parsed ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppColors.primary,
            onPrimary: Colors.white,
            onSurface: Colors.black87,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      ctrl.text = '${picked.year}-'
          '${picked.month.toString().padLeft(2, '0')}-'
          '${picked.day.toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.number,
      inputFormatters: [
        DateInputFormatter(),
      ],
      style: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          fontFamily: 'Cairo',
          fontSize: 11,
          color: Color(0xFFAAAAAA),
        ),
        prefixIcon: IconButton(
          icon: Icon(icon, size: 16, color: AppColors.primary),
          tooltip: 'اختيار من التقويم',
          onPressed: () => _pickDate(context),
        ),
        filled: true,
        fillColor: const Color(0xFFF8FAFB),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// نافذة تعديل المنتج الشاملة (تعديل كل شيء + كتابة الحجم يدوياً)
// ══════════════════════════════════════════════════════════
class _ProductEditSheet extends ConsumerStatefulWidget {
  final Map<String, dynamic> product;
  final List<Map<String, dynamic>> brands;
  final VoidCallback onSaved;

  const _ProductEditSheet({
    required this.product,
    required this.brands,
    required this.onSaved,
  });
  @override
  ConsumerState<_ProductEditSheet> createState() => _ProductEditSheetState();
}

class _ProductEditSheetState extends ConsumerState<_ProductEditSheet> {
  late final TextEditingController nameCtrl;
  late final TextEditingController priceCtrl;
  late final TextEditingController costCtrl;
  late final TextEditingController stockCtrl;
  late final TextEditingController itemsCtrl;
  late final TextEditingController sizeCtrl;
  late final TextEditingController prodCtrl;
  late final TextEditingController expCtrl;
  late final TextEditingController barcodeCtrl;
  late double initialStockValue;
  late List<ProductUnit> editUnits;
  late List<ProductVariant> editVariants;
  String? selectedBrandId;
  XFile? _newImage;
  Uint8List? _newImageBytes;
  String? _existingImageUrl;
  bool _removeImage = false;
  bool saving = false;
  String? _editError;
  @override
  void initState() {
    super.initState();
    final p = widget.product;
    // 1. اسم المنتج
    nameCtrl = TextEditingController(text: p['name']?.toString() ?? '');
    // 2. الشركة
    final rawBrand = p['brand_id']?.toString();
    selectedBrandId = widget.brands.any((b) => b['id'].toString() == rawBrand)
        ? rawBrand
        : null;
    _existingImageUrl =
        p['image_url']?.toString(); // 3. الأسعار والمخزون وحبات الكرتون
    priceCtrl =
        TextEditingController(text: (p['price'] as num?)?.toString() ?? '');
    costCtrl = TextEditingController(
        text: (p['cost_price'] as num?)?.toString() ?? '');
    itemsCtrl = TextEditingController(
        text: (p['items_per_carton'] as num?)?.toString() ?? '');

    initialStockValue = (p['stock'] as num?)?.toDouble() ?? 0.0;
    final bool isInitialInteger =
        (initialStockValue - initialStockValue.round()).abs() < 0.001;
    stockCtrl = TextEditingController(
      text: isInitialInteger
          ? initialStockValue.round().toString()
          : initialStockValue.toStringAsFixed(2),
    );

    // 4. الحجم الحر (يكتب التاجر ما يريد بيده: 1.5 لتر أو 10 كجم أو 500 مل أو يتركه فارغاً)
    sizeCtrl = TextEditingController(
      text: p['size_text']?.toString() ??
          (p['size_ml'] != null ? '${p['size_ml']} مل' : ''),
    );

    // 5. التواريخ
    prodCtrl =
        TextEditingController(text: formatFirestoreDate(p['production_date']));
    expCtrl =
        TextEditingController(text: formatFirestoreDate(p['expiry_date']));
    barcodeCtrl = TextEditingController(text: p['barcode']?.toString() ?? '');
// 6. الوحدات والكميات والأحجام
    editUnits = (p['units'] as List<dynamic>? ?? [])
        .map((e) => ProductUnit.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    editVariants = (p['variants'] as List<dynamic>? ?? [])
        .map((e) => ProductVariant.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    priceCtrl.dispose();
    costCtrl.dispose();
    stockCtrl.dispose();
    itemsCtrl.dispose();
    sizeCtrl.dispose();
    prodCtrl.dispose();
    expCtrl.dispose();
    barcodeCtrl.dispose(); // ✅ التخلص من متحكم الباركود لمنع تسريب الذاكرة
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF5F7FA),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.edit_rounded,
                      color: AppColors.primary, size: 20),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('تعديل المنتج بالكامل',
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 16,
                          fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
            const Divider(height: 20),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ── 0. تعديل أو إزالة صورة المنتج ──
                        GestureDetector(
                          onTap: saving
                              ? null
                              : () async {
                                  try {
                                    final (file, bytes) =
                                        await pickCatalogImage();
                                    if (!mounted) return;
                                    if (file != null && bytes != null) {
                                      if (bytes.lengthInBytes >
                                          3 * 1024 * 1024) {
                                        setState(() => _editError =
                                            'الصورة كبيرة جداً، الحد الأقصى 3MB');
                                        return;
                                      }
                                      setState(() {
                                        _editError = null;
                                        _newImage = file;
                                        _newImageBytes = bytes;
                                        _removeImage = false;
                                      });
                                    }
                                  } catch (_) {
                                    if (mounted) {
                                      setState(() => _editError =
                                          'تعذّر فتح المعرض، تحقق من الصلاحيات');
                                    }
                                  }
                                },
                          child: Container(
                            width: double.infinity,
                            height: 68,
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFB),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: Colors.grey.withValues(alpha: 0.25)),
                            ),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: _newImageBytes != null
                                      ? Image.memory(_newImageBytes!,
                                          width: 46,
                                          height: 46,
                                          fit: BoxFit.cover)
                                      : (!_removeImage &&
                                              _existingImageUrl != null &&
                                              _existingImageUrl!.isNotEmpty)
                                          ? CachedNetworkImage(
                                              cacheManager: ImagePrecacheService
                                                  .instance.cacheManager,
                                              imageUrl: _existingImageUrl!,
                                              width: 46,
                                              height: 46,
                                              fit: BoxFit.cover,
                                            )
                                          : Container(
                                              width: 46,
                                              height: 46,
                                              color: AppColors.primary
                                                  .withValues(alpha: 0.08),
                                              child: const Icon(
                                                  Icons.image_outlined,
                                                  color: AppColors.primary),
                                            ),
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    'تغيير صورة المنتج (اضغط للاختيار)',
                                    style: TextStyle(
                                        fontFamily: 'Cairo',
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700),
                                  ),
                                ),
                                if (_newImageBytes != null ||
                                    (!_removeImage &&
                                        _existingImageUrl != null &&
                                        _existingImageUrl!.isNotEmpty))
                                  IconButton(
                                    onPressed: saving
                                        ? null
                                        : () => setState(() {
                                              _newImage = null;
                                              _newImageBytes = null;
                                              _removeImage = true;
                                            }),
                                    icon: const Icon(Icons.close_rounded,
                                        color: Colors.red, size: 18),
                                    tooltip: 'إزالة الصورة',
                                  ),
                              ],
                            ),
                          ),
                        ),
                        // ── 1. اسم المنتج ──
                        CatalogEditField(
                          ctrl: nameCtrl,
                          hint: 'اسم المنتج *',
                          icon: Icons.edit_note_rounded,
                        ),
                        const SizedBox(height: 10),

                        // ── 2. اختيار / تغيير الشركة ──
                        Row(
                          children: [
                            const Text(
                              'الشركة / الماركة *',
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF555555),
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: saving ? null : _quickAddBrandInEdit,
                              icon: const Icon(Icons.add_circle_outline_rounded,
                                  size: 15, color: AppColors.primary),
                              label: const Text(
                                '+ شركة جديدة',
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                ),
                              ),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Builder(builder: (_) {
                          final currentBrands =
                              ref.watch(brandsProvider).value ?? widget.brands;
                          return DropdownButtonFormField<String>(
                            initialValue: currentBrands.any(
                                    (b) => b['id'].toString() == selectedBrandId)
                                ? selectedBrandId
                                : null,
                            hint: const Text('اختر الشركة / الماركة *',
                                style: TextStyle(
                                    fontFamily: 'Cairo', fontSize: 13)),
                            decoration: catalogInputDec('الشركة'),
                            isExpanded: true,
                            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                                color: AppColors.primary),
                            items: currentBrands
                                .map((b) => DropdownMenuItem(
                                      value: b['id'].toString(),
                                      child: Text(b['name'] ?? '',
                                          style: const TextStyle(
                                              fontFamily: 'Cairo',
                                              fontSize: 13)),
                                    ))
                                .toList(),
                            onChanged: (v) =>
                                setState(() => selectedBrandId = v),
                          );
                        }),
                        const SizedBox(height: 10),

                        // ── 3. السعر والمخزون ──
                        Row(children: [
                          Expanded(
                              child: CatalogEditField(
                                  ctrl: priceCtrl,
                                  hint: 'سعر البيع ر.ي *',
                                  icon: Icons.attach_money_rounded,
                                  type: const TextInputType.numberWithOptions(
                                      decimal: true),
                                  inputFormatters: const [
                                ArabicDigitsInputFormatter()
                              ])),
                          const SizedBox(width: 8),
                          Expanded(
                              child: CatalogEditField(
                                  ctrl: stockCtrl,
                                  hint: 'مخزون كرتون',
                                  icon: Icons.inventory_rounded,
                                  type: const TextInputType.numberWithOptions(
                                      decimal: true),
                                  inputFormatters: const [
                                ArabicDigitsInputFormatter()
                              ])),
                        ]),
                        const SizedBox(height: 10),

                        // ── 4. سعر الشراء وحبات الكرتون ──
                        Row(children: [
                          Expanded(
                            child: CatalogEditField(
                                ctrl: costCtrl,
                                hint: 'سعر الشراء 🔒',
                                icon: Icons.lock_rounded,
                                type: const TextInputType.numberWithOptions(
                                    decimal: true),
                                inputFormatters: const [
                                  ArabicDigitsInputFormatter()
                                ]),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: CatalogEditField(
                                ctrl: itemsCtrl,
                                hint: 'حبات بالكرتون',
                                icon: Icons.view_module_rounded,
                                type: TextInputType.number,
                                inputFormatters: const [
                                  ArabicDigitsInputFormatter(
                                      allowDecimal: false)
                                ]),
                          ),
                        ]),
                        const SizedBox(height: 10),

                        // ── 5. الحجم / الوزن / الكمية (تكتب ما تريده بيدك بدون أي قيود) ──
                        CatalogEditField(
                          ctrl: sizeCtrl,
                          hint:
                              'الحجم أو الكمية (اكتب بيدك: مثلاً 1.5 لتر ، 10 كجم ، 500 مل)',
                          icon: Icons.straighten_rounded,
                          type: TextInputType.text,
                        ),
                        const SizedBox(height: 10),

                        // ── الباركود الدولي للمنتج ──
                        Row(
                          children: [
                            Expanded(
                              child: CatalogEditField(
                                ctrl: barcodeCtrl,
                                hint:
                                    'الباركود الدولي (أدخل يدوياً أو امسح بالكاميرا)',
                                icon: Icons.qr_code_2_rounded,
                                type: TextInputType.text,
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () async {
                                final scanned =
                                    await BarcodeScannerScreen.scan(context);
                                if (scanned != null && scanned.isNotEmpty) {
                                  setState(() => barcodeCtrl.text = scanned);
                                }
                              },
                              child: Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: AppColors.primary,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(Icons.qr_code_scanner_rounded,
                                    color: Colors.white, size: 22),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // ── 6. تواريخ الإنتاج والانتهاء اليدوية ──
                        Row(children: [
                          Expanded(
                            child: _ManualDateField(
                              ctrl: prodCtrl,
                              hint: 'إنتاج: 2026-05-15',
                              icon: Icons.calendar_today_rounded,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _ManualDateField(
                              ctrl: expCtrl,
                              hint: 'انتهاء: 2027-05-15',
                              icon: Icons.event_busy_rounded,
                            ),
                          ),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── 7. محرر الوحدات والكميات ──
                  ProductUnitsEditor(
                    productName: nameCtrl.text.trim(),
                    initialUnits: editUnits,
                    onChanged: (units) {
                      setState(() => editUnits = units);
                    },
                  ),
                  const SizedBox(height: 8),

                  // ── 8. محرر الأحجام / الأنواع (كبير، صغير، 5 كجم...) ──
                  ProductVariantsEditor(
                    productName: nameCtrl.text.trim(),
                    initialVariants: editVariants,
                    onChanged: (variants) {
                      setState(() => editVariants = variants);
                    },
                  ),
                  const SizedBox(height: 16),

                  if (_editError != null) ...[
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: Colors.red.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        _editError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.red,
                        ),
                      ),
                    ),
                  ],

                  // ── زر حفظ التعديلات ──
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: saving ? null : _saveProductUpdates,
                      icon: saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.save_rounded, size: 20),
                      label: Text(
                          saving ? 'جاري الحفظ...' : 'حفظ التعديلات بالكامل',
                          style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w800,
                              fontSize: 15)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _quickAddBrandInEdit() async {
    final nameCtrl = TextEditingController();
    String? selectedCatId;
    XFile? logoFile;
    Uint8List? logoBytes;
    bool savingBrand = false;
    String? brandErr;

    final categories = ref.read(adminCategoriesProvider).value ?? [];

    await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bCtx) => StatefulBuilder(
        builder: (dialogCtx, setBSt) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(dialogCtx).viewInsets.bottom,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.business_rounded,
                          color: AppColors.primary, size: 20),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'إضافة شركة جديدة سريعاً',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 20),
                GestureDetector(
                  onTap: savingBrand
                      ? null
                      : () async {
                          final (f, b) = await pickCatalogImage();
                          if (f != null && b != null) {
                            setBSt(() {
                              logoFile = f;
                              logoBytes = b;
                            });
                          }
                        },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFB),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: logoBytes != null
                              ? Image.memory(logoBytes!,
                                  width: 40, height: 40, fit: BoxFit.cover)
                              : Container(
                                  width: 40,
                                  height: 40,
                                  color: AppColors.primary
                                      .withValues(alpha: 0.08),
                                  child: const Icon(Icons.add_a_photo_rounded,
                                      color: AppColors.primary, size: 20),
                                ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            logoBytes != null
                                ? 'تم اختيار الشعار ✓'
                                : 'شعار الشركة (اختياري)',
                            style: const TextStyle(
                                fontFamily: 'Cairo', fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: catalogInputDec('اسم الشركة *'),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: selectedCatId,
                  hint: const Text('اختر الصنف التابع له *',
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 13)),
                  decoration: catalogInputDec('الصنف التابع له'),
                  items: categories
                      .map((c) => DropdownMenuItem(
                            value: c['id'].toString(),
                            child: Text(c['name'] ?? '',
                                style: const TextStyle(
                                    fontFamily: 'Cairo', fontSize: 13)),
                          ))
                      .toList(),
                  onChanged: (v) => setBSt(() => selectedCatId = v),
                ),
                if (brandErr != null) ...[
                  const SizedBox(height: 8),
                  Text(brandErr!,
                      style: const TextStyle(
                          fontFamily: 'Cairo',
                          color: Colors.red,
                          fontSize: 12)),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: savingBrand
                        ? null
                        : () async {
                            final bName = nameCtrl.text.trim();
                            if (bName.isEmpty) {
                              setBSt(() => brandErr = 'اسم الشركة مطلوب');
                              return;
                            }
                            if (selectedCatId == null) {
                              setBSt(() => brandErr = 'اختر الصنف التابع له');
                              return;
                            }
                            setBSt(() {
                              savingBrand = true;
                              brandErr = null;
                            });
                            try {
                              String? logoUrl;
                              if (logoFile != null) {
                                logoUrl = await uploadCatalogImage(logoFile!);
                              }
                              await ref.read(adminServiceProvider).addBrand(
                                    name: bName,
                                    categoryId: selectedCatId!,
                                    logoUrl: logoUrl,
                                  );
                              ref.invalidate(brandsProvider);
                              final updated =
                                  await ref.read(brandsProvider.future);
                              final match = updated.firstWhere(
                                (b) => b['name'] == bName,
                                orElse: () => updated.last,
                              );
                              final newId = match['id'].toString();
                              if (dialogCtx.mounted) {
                                Navigator.pop(dialogCtx, newId);
                              }
                            } catch (e) {
                              setBSt(() {
                                savingBrand = false;
                                brandErr = 'فشل إضافة الشركة: $e';
                              });
                            }
                          },
                    icon: savingBrand
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.add_rounded, size: 20),
                    label: Text(
                      savingBrand ? 'جاري الإضافة...' : 'حفظ واختيار الشركة',
                      style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.w800,
                          fontSize: 14),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).then((newBrandId) {
      if (newBrandId != null && mounted) {
        setState(() {
          selectedBrandId = newBrandId;
        });
      }
    });
  }

  Future<void> _saveProductUpdates() async {
    final nameText = nameCtrl.text.trim();
    if (nameText.isEmpty) {
      setState(() => _editError = 'اسم المنتج مطلوب');
      return;
    }

    final stockText = ArabicNormalizer.normalizeDigits(stockCtrl.text).trim();
    final newStockInput = double.tryParse(stockText);
    if (newStockInput != null && newStockInput < 0) {
      setState(() => _editError = 'لا يمكن أن يكون المخزون سالباً');
      return;
    }

    final prodText = ArabicNormalizer.normalizeDigits(prodCtrl.text).trim();
    if (prodText.isNotEmpty && DateTime.tryParse(prodText) == null) {
      setState(
          () => _editError = 'صيغة تاريخ الإنتاج غير صحيحة (مثال: 2026-05-15)');
      return;
    }

    final expText = ArabicNormalizer.normalizeDigits(expCtrl.text).trim();
    if (expText.isNotEmpty && DateTime.tryParse(expText) == null) {
      setState(() =>
          _editError = 'صيغة تاريخ الانتهاء غير صحيحة (مثال: 2027-05-15)');
      return;
    }

    double? parsedPrice = double.tryParse(
        ArabicNormalizer.normalizeDigits(priceCtrl.text).trim());
    if (parsedPrice == null && editVariants.isNotEmpty) {
      parsedPrice =
          editVariants.map((v) => v.price).reduce((a, b) => a < b ? a : b);
    }
    if (parsedPrice == null || parsedPrice < 0) {
      setState(() => _editError = 'أدخل سعر بيع صحيحاً أو أضف حجماً بسعر محدد');
      return;
    }

    setState(() {
      _editError = null;
      saving = true;
    });

    final String originalStockText =
        (initialStockValue - initialStockValue.round()).abs() < 0.001
            ? initialStockValue.round().toString()
            : initialStockValue.toStringAsFixed(2);
    final bool stockWasManuallyChanged = newStockInput != null &&
        stockText != originalStockText &&
        (newStockInput - initialStockValue).abs() > 0.0001;
    final double stockDelta =
        stockWasManuallyChanged ? (newStockInput - initialStockValue) : 0.0;

    String? categoryId;
    if (selectedBrandId != null) {
      final bMatch = widget.brands.firstWhere(
        (b) => b['id'].toString() == selectedBrandId,
        orElse: () => <String, dynamic>{},
      );
      categoryId = bMatch['category_id']?.toString();
    }

    final customSizeText = sizeCtrl.text.trim();
    final numericSize = parseSizeMlFromText(customSizeText);
    final parsedCost = costCtrl.text.trim().isEmpty
        ? 0.0
        : (double.tryParse(
                ArabicNormalizer.normalizeDigits(costCtrl.text).trim()) ??
            0.0);
    final parsedItems = itemsCtrl.text.trim().isEmpty
        ? 1
        : (int.tryParse(
                ArabicNormalizer.normalizeDigits(itemsCtrl.text).trim()) ??
            1);

    final double? syncedVariantStock = editVariants.isNotEmpty
        ? editVariants.fold<double>(0.0, (sum, v) => sum + v.stock)
        : null;

    try {
      String? updatedImageUrl;
      if (_newImage != null) {
        updatedImageUrl = await uploadCatalogImage(_newImage!);
      }

      await ref
          .read(adminServiceProvider)
          .updateProduct(widget.product['id'].toString(), {
        'name': nameText,
        if (selectedBrandId != null) 'brand_id': selectedBrandId,
        if (categoryId != null) 'category_id': categoryId,
        if (updatedImageUrl != null)
          'image_url': updatedImageUrl
        else if (_removeImage)
          'image_url': null,
        'price': parsedPrice,
        'cost_price': parsedCost,
        if (syncedVariantStock != null)
          'stock': syncedVariantStock
        else if (stockWasManuallyChanged)
          'stock_delta': stockDelta,
        'items_per_carton': parsedItems,
        'size_text': customSizeText,
        'size_ml': numericSize,
        'barcode': barcodeCtrl.text.trim().isNotEmpty
            ? barcodeCtrl.text.trim()
            : FieldValue.delete(),
        'production_date': prodText.isNotEmpty
            ? Timestamp.fromDate(DateTime.parse(prodText))
            : FieldValue.delete(),
        'expiry_date': expText.isNotEmpty
            ? Timestamp.fromDate(DateTime.parse(expText))
            : FieldValue.delete(),
        'units': editUnits.map((u) => u.toJson()).toList(),
        'variants': editVariants.map((v) => v.toJson()).toList(),
      });
      widget.onSaved();

      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _editError = 'فشل التحديث: $e');
      }
    } finally {
      if (mounted) {
        setState(() => saving = false);
      }
    }
  }
}
