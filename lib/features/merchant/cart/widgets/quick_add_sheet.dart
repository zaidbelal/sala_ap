import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // 👈 تمت إضافة هذا السطر لحل الأخطاء الثلاثة فوراً
import '../../cart/providers/cart_provider.dart';
import 'package:wissal/core/constants/app_colors.dart';
import 'package:wissal/core/constants/app_radius.dart';
import 'package:wissal/core/constants/app_adaptive_colors.dart';
import 'package:wissal/core/models/product_unit.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../products/services/products_service.dart';
import 'package:wissal/core/services/app_cache.dart';
import 'package:wissal/core/services/catalog_service.dart';
import 'package:wissal/core/utils/arabic_normalizer.dart';

class QuickAddSheet extends ConsumerStatefulWidget {
  const QuickAddSheet({super.key});

  @override
  ConsumerState<QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends ConsumerState<QuickAddSheet> {
  final _searchCtrl = TextEditingController();
  List<ProductModel> _products = [];
  List<ProductModel> _filtered = [];
  bool _loading = true;
  String? _error;
  Timer? _filterDebounce;

  @override
  void initState() {
    super.initState();
    _fetchProducts();
    _searchCtrl.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 250), _filter);
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  List<ProductModel> _buildSortedModels(List<Map<String, dynamic>> raw) {
    return raw
        .where((p) => p['is_active'] != false && p['is_deleted'] != true)
        .map((p) => ProductModel.fromMap(Map<String, dynamic>.from(p)))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> _fetchProducts() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cachedData = AppCache.instance.getAllCachedProducts();
      if (cachedData.isNotEmpty) {
        final initialList = _buildSortedModels(cachedData);
        if (mounted) {
          setState(() {
            _products = initialList;
            _loading = false;
          });
          _filter();
        }
      }

      if (cachedData.isEmpty || !AppCache.instance.isProductsFresh()) {
        if (cachedData.isEmpty) {
          await ref.read(productsProvider(null).future);
        } else {
          await ref.read(productsProvider(null).notifier).refresh();
        }
        var refreshedData = AppCache.instance.getProducts() ?? [];
        if (refreshedData.isEmpty) {
          final snap = await FirebaseFirestore.instance
              .collection('products')
              .where('is_deleted', isEqualTo: false)
              .limit(500)
              .get(const GetOptions(source: Source.serverAndCache));

          refreshedData = snap.docs
              .where((d) => d.data()['is_active'] != false)
              .map((d) => {'id': d.id, ...d.data()})
              .toList();

          if (refreshedData.isNotEmpty) {
            unawaited(AppCache.instance.setProducts(refreshedData));
          }
        }

        if (!mounted) return;
        if (refreshedData.isNotEmpty || cachedData.isEmpty) {
          final fullList = _buildSortedModels(refreshedData);
          setState(() {
            _products = fullList;
            _loading = false;
          });
          _filter();
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (_products.isEmpty) {
        setState(() {
          _error = 'تعذر تحميل المنتجات، تحقق من الاتصال بالإنترنت';
          _loading = false;
        });
      }
    }
  }

  void _filter() {
    final q = ArabicNormalizer.normalize(_searchCtrl.text);
    final rawQ = ArabicNormalizer.normalizeDigits(_searchCtrl.text).trim();

    setState(() {
      _filtered = q.isEmpty
          ? _products
          : _products.where((p) {
              final productName = ArabicNormalizer.normalize(p.name);
              if (productName.contains(q)) return true;
              if (rawQ.isNotEmpty && (p.barcode ?? '').contains(rawQ)) {
                return true;
              }
              return p.variants.any((v) =>
                  ArabicNormalizer.normalize(v.label).contains(q) ||
                  (rawQ.isNotEmpty && (v.barcode ?? '').contains(rawQ)));
            }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: BoxDecoration(
        color: context.bgCard, // ✅ دارك مود
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(children: [
        // ── مقبض ──
        const SizedBox(height: 12),
        Container(
          width: 44,
          height: 4,
          decoration: BoxDecoration(
            color: context.borderColor, // ✅ دارك مود
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        // ── رأس الشيت ──
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: context.bgInput, // ✅ دارك مود
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: context.textPrimary, // ✅ دارك مود
                  ),
                ),
              ),
              const Spacer(),
              Text(
                'إضافة منتج',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: context.textPrimary, // ✅ دارك مود
                ),
              ),
              const Spacer(),
              const SizedBox(width: 36),
            ],
          ),
        ),
        // ── خانة البحث ──
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: TextField(
            controller: _searchCtrl,
            textDirection: TextDirection.rtl,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 14,
              color: context.textPrimary, // ✅ دارك مود
            ),
            decoration: InputDecoration(
              hintText: 'ابحث عن منتج...',
              hintStyle: TextStyle(
                fontFamily: 'Cairo',
                color: context.textHint, // ✅ دارك مود
                fontSize: 14,
              ),
              prefixIcon:
                  const Icon(Icons.search_rounded, color: AppColors.primary),
              filled: true,
              fillColor: context.bgInput, // ✅ دارك مود
              border: const OutlineInputBorder(
                borderRadius: AppRadius.lgAll,
                borderSide: BorderSide(color: AppColors.primary, width: 1.5),
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: AppRadius.lgAll,
                borderSide: BorderSide(color: AppColors.primary, width: 1.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: AppRadius.lgAll,
                borderSide:
                    BorderSide(color: context.borderColor), // ✅ دارك مود
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
        ),
        // ── المحتوى ──
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.primary))
              : _error != null
                  ? _ErrorState(error: _error!, onRetry: _fetchProducts)
                  : _filtered.isEmpty
                      ? _EmptyState(hasSearch: _searchCtrl.text.isNotEmpty)
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                          itemCount: _filtered.length,
                          itemBuilder: (_, i) => _ProductTile(
                              key: ValueKey(_filtered[i].id),
                              product: _filtered[i],
                              onAdd: (qty, unit, variant) {
                                final isBase = variant?.id == 'base_default';
                                ref.read(cartProvider.notifier).addItem(
                                    _filtered[i], qty,
                                    unit: unit,
                                    variant: isBase ? null : variant);

                                HapticFeedback.lightImpact();
                              }),
                        ),
        ),
      ]),
    );
  }
}

// ════════════════════════════════════════
// صف المنتج
// ════════════════════════════════════════
class _ProductTile extends ConsumerStatefulWidget {
  final ProductModel product;
  final void Function(int qty, ProductUnit? unit, ProductVariant? variant)
      onAdd;
  const _ProductTile({super.key, required this.product, required this.onAdd});

  @override
  ConsumerState<_ProductTile> createState() => _ProductTileState();
}

class _ProductTileState extends ConsumerState<_ProductTile> {
  int _qty = 1;
  bool _added = false;
  ProductVariant? _selectedVariant;
  ProductUnit? _selectedUnit;

  @override
  void initState() {
    super.initState();
    _initUnit();
  }

  @override
  void didUpdateWidget(covariant _ProductTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.product.id != widget.product.id) {
      _initUnit();
    }
  }

  void _initUnit() {
    _qty = 1;
    _selectedVariant = widget.product.hasVariants
        ? widget.product.allVariantsWithBase.first
        : null;
    final units =
        (_selectedVariant != null && _selectedVariant!.units.isNotEmpty)
            ? _selectedVariant!.units
            : widget.product.units;
    _selectedUnit = units.isNotEmpty ? units.first : null;
  }

  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _showManualQtyDialog() async {
    HapticFeedback.mediumImpact();
    final result = await showDialog<int>(
      context: context,
      builder: (_) => _QuickAddQtyDialog(
        initialQty: _qty,
        productName: _selectedVariant != null
            ? '${widget.product.name} - ${_selectedVariant!.label}'
            : widget.product.name,
        unitLabel: _selectedUnit?.label ?? 'كرتون',
      ),
    );
    if (result != null && result > 0 && mounted) {
      setState(() => _qty = result);
    }
  }

  int _remainingMaxUnits() {
    final stock = _selectedVariant?.stock ?? widget.product.baseStock;
    if (stock <= 0) return 0;
    final cartonCap =
        (_selectedVariant?.itemsPerCarton ?? widget.product.itemsPerCarton ?? 1)
            .clamp(1, 9999);
    final unitQty = (_selectedUnit?.qty ?? cartonCap).clamp(1, 9999);

    final cart = ref.read(cartProvider);
    final targetVarId =
        (_selectedVariant == null || _selectedVariant!.id == 'base_default')
            ? ''
            : _selectedVariant!.id;
    double usedCartons = 0.0;
    for (final cItem in cart.values) {
      if (cItem.product.id == widget.product.id &&
          (cItem.selectedVariant?.id ?? '') == targetVarId) {
        final cCap = (cItem.selectedVariant?.itemsPerCarton ??
                cItem.product.itemsPerCarton ??
                1)
            .clamp(1, 9999);
        final uQty = (cItem.selectedUnit?.qty ?? cCap).clamp(1, 9999);
        usedCartons += (cItem.quantity * uQty) / cCap;
      }
    }
    final remainingCartons = (stock - usedCartons).clamp(0.0, stock);
    return ((remainingCartons * cartonCap) / unitQty).floor();
  }

  void _add() {
    final maxUnits = _remainingMaxUnits();
    if (maxUnits <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'وصلت للحد الأقصى المتوفر في المستودع لهذا الصنف داخل سلتك',
              style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final safeQty = _qty > maxUnits ? maxUnits : _qty;
    if (safeQty != _qty) {
      setState(() => _qty = safeQty);
    }
    widget.onAdd(safeQty, _selectedUnit, _selectedVariant);
    if (!mounted) return;
    setState(() => _added = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _added = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeStock = _selectedVariant?.stock ?? widget.product.baseStock;
    final activeUnits =
        (_selectedVariant != null && _selectedVariant!.units.isNotEmpty)
            ? _selectedVariant!.units
            : widget.product.units;
    final activePrice =
        _selectedUnit?.price ?? _selectedVariant?.price ?? widget.product.price;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.bgCard,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: context.borderColor),
        boxShadow: [
          BoxShadow(
            color: context.shadowColor.withValues(alpha: 0.06),
            blurRadius: 6,
          ),
        ],
      ),
      child: Row(
        children: [
          Builder(
            builder: (context) {
              final activeImg = (_selectedUnit?.imageUrl != null &&
                      _selectedUnit!.imageUrl!.trim().isNotEmpty)
                  ? _selectedUnit!.imageUrl!.trim()
                  : (_selectedVariant?.imageUrl != null &&
                          _selectedVariant!.imageUrl!.trim().isNotEmpty)
                      ? _selectedVariant!.imageUrl!.trim()
                      : widget.product.imageUrl;
              return Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.07),
                  borderRadius: AppRadius.mdAll,
                ),
                child: activeImg != null && activeImg.isNotEmpty
                    ? ClipRRect(
                        borderRadius: AppRadius.mdAll,
                        child: CachedNetworkImage(
                          imageUrl: activeImg,
                          fit: BoxFit.cover,
                          memCacheWidth: 200,
                          errorWidget: (_, __, ___) => const Icon(
                              Icons.inventory_2_outlined,
                              color: AppColors.primary,
                              size: 24),
                        ),
                      )
                    : const Icon(Icons.inventory_2_outlined,
                        color: AppColors.primary, size: 24),
              );
            },
          ),
          const SizedBox(width: 10),
          // الاسم والسعر
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.product.name,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary, // ✅ دارك مود
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${activePrice.toStringAsFixed(0)} ر.ي / ${_selectedUnit?.label ?? "كرتون"}',
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (widget.product.hasVariants) ...[
                  const SizedBox(height: 4),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: widget.product.allVariantsWithBase.map((v) {
                        final isSel = _selectedVariant?.id == v.id;
                        return GestureDetector(
                          onTap: () => setState(() {
                            _selectedVariant = v;
                            _selectedUnit =
                                v.units.isNotEmpty ? v.units.first : null;
                            _qty = 1;
                          }),
                          child: Container(
                            margin: const EdgeInsetsDirectional.only(end: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: isSel
                                  ? Colors.deepPurple
                                  : Colors.deepPurple.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              v.label,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: isSel ? Colors.white : Colors.deepPurple,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
                if (activeUnits.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: activeUnits.map((unit) {
                        final isSelected = _selectedUnit?.label == unit.label;
                        return GestureDetector(
                          onTap: () => setState(() => _selectedUnit = unit),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            margin: const EdgeInsetsDirectional.only(end: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppColors.primary
                                  : AppColors.primary.withValues(alpha: 0.07),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isSelected
                                    ? AppColors.primary
                                    : AppColors.primary.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Text(
                              unit.label,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: isSelected
                                    ? Colors.white
                                    : AppColors.primary,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          // التحكم بالكمية (يدعم النقر المزدوج لكتابة الرقم يدوياً)
          Row(
            children: [
              _QtyBtn(
                icon: Icons.remove_rounded,
                onTap: () => setState(() {
                  if (_qty > 1) _qty--;
                }),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: _showManualQtyDialog,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    '$_qty',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: context.textPrimary, // ✅ دارك مود
                    ),
                  ),
                ),
              ),
              _QtyBtn(
                icon: Icons.add_rounded,
                onTap: () {
                  final maxUnits = _remainingMaxUnits();
                  if (maxUnits > 0 && _qty < maxUnits) {
                    setState(() => _qty++);
                  }
                },
              ),
            ],
          ),
          const SizedBox(width: 8),
          // زر الإضافة
          GestureDetector(
            onTap: (activeStock <= 0 || _added) ? null : _add,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: activeStock <= 0
                    ? Colors.grey
                    : (_added ? Colors.green : AppColors.primary),
                borderRadius: AppRadius.mdAll,
              ),
              child: Icon(
                activeStock <= 0
                    ? Icons.remove_shopping_cart_rounded
                    : (_added
                        ? Icons.check_rounded
                        : Icons.add_shopping_cart_rounded),
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════
// زر الكمية
// ════════════════════════════════════════
class _QtyBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _QtyBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: context.bgInput, // ✅ دارك مود
          borderRadius: AppRadius.smAll,
        ),
        child: Icon(
          icon,
          size: 16,
          color: context.textPrimary, // ✅ دارك مود
        ),
      ),
    );
  }
}

// ════════════════════════════════════════
// حالة الخطأ
// ════════════════════════════════════════
class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off_rounded,
                size: 60, color: context.iconSecondary),
            const SizedBox(height: 16),
            Text(
              'فشل تحميل المنتجات',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: context.textPrimary, // ✅ دارك مود
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11,
                color: context.textSecondary, // ✅ دارك مود
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('إعادة المحاولة',
                  style: TextStyle(fontFamily: 'Cairo')),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape:
                    const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════
// قائمة فارغة
// ════════════════════════════════════════
class _EmptyState extends StatelessWidget {
  final bool hasSearch;
  const _EmptyState({required this.hasSearch});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            hasSearch ? Icons.search_off_rounded : Icons.inventory_2_outlined,
            size: 60,
            color: context.iconSecondary, // ✅ دارك مود
          ),
          const SizedBox(height: 16),
          Text(
            hasSearch ? 'لا نتائج للبحث' : 'لا توجد منتجات',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: context.textSecondary, // ✅ دارك مود
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickAddQtyDialog extends StatefulWidget {
  final int initialQty;
  final String productName;
  final String unitLabel;
  const _QuickAddQtyDialog({
    required this.initialQty,
    required this.productName,
    required this.unitLabel,
  });

  @override
  State<_QuickAddQtyDialog> createState() => _QuickAddQtyDialogState();
}

class _QuickAddQtyDialogState extends State<_QuickAddQtyDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.initialQty}');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final clean = ArabicNormalizer.normalizeDigits(_controller.text).trim();
    final val = int.tryParse(clean);
    FocusScope.of(context).unfocus();
    Navigator.pop(context, (val != null && val > 0) ? val : null);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      backgroundColor: context.bgCard,
      title: Text(
        'تحديد الكمية (${widget.unitLabel})',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: context.textPrimary,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'أدخل الكمية المطلوبة للمنتج (${widget.productName}):',
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                color: context.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: AppColors.primary,
            ),
            decoration: InputDecoration(
              filled: true,
              fillColor: context.bgInput,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    const BorderSide(color: AppColors.primary, width: 1.5),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء',
              style: TextStyle(fontFamily: 'Cairo', color: Colors.grey)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: _submit,
          child: const Text('تأكيد',
              style:
                  TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
