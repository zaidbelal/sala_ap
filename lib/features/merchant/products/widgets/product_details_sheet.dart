import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_radius.dart';
import '../../cart/providers/cart_provider.dart';
import '../services/products_service.dart';
import 'package:wissal/core/models/product_unit.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/services/image_precache_service.dart';
import 'package:wissal/core/constants/app_adaptive_colors.dart';

class ProductDetailsSheet extends ConsumerStatefulWidget {
  final ProductModel product;
  final ProductVariant? initialVariant;
  final ProductUnit? initialUnit;
  const ProductDetailsSheet({
    super.key,
    required this.product,
    this.initialVariant,
    this.initialUnit,
  });

  @override
  ConsumerState<ProductDetailsSheet> createState() =>
      _ProductDetailsSheetState();
}

class _ProductDetailsSheetState extends ConsumerState<ProductDetailsSheet> {
  int _qty = 1;
  int _variantIndex = 0;
  ProductUnit? _selectedUnit;
  final Map<int, ProductUnit?> _variantUnits = {};
  final Map<int, int> _variantQtys = {};
  PageController? _pageController;

  List<ProductVariant> get _effectiveVariants => widget.product.hasVariants
      ? widget.product.allVariantsWithBase
      : const [];

  ProductVariant? get _currentVariant =>
      _effectiveVariants.isNotEmpty ? _effectiveVariants[_variantIndex] : null;
  ProductUnit? _unitForIndex(int idx) {
    if (!widget.product.hasVariants) return _selectedUnit;
    if (_variantUnits.containsKey(idx) && _variantUnits[idx] != null) {
      return _variantUnits[idx];
    }
    final v = _effectiveVariants[idx];
    final units = v.units.isNotEmpty ? v.units : widget.product.units;
    return units.isNotEmpty ? units.first : null;
  }

  int _qtyForIndex(int idx) {
    if (!widget.product.hasVariants) return _qty;
    return _variantQtys[idx] ?? 1;
  }

  @override
  void initState() {
    super.initState();
    final allVars = _effectiveVariants;
    if (widget.product.hasVariants && allVars.isNotEmpty) {
      if (widget.initialVariant != null) {
        final idx = allVars.indexWhere(
          (v) =>
              v.id == widget.initialVariant!.id ||
              v.label.trim() == widget.initialVariant!.label.trim(),
        );
        if (idx != -1) _variantIndex = idx;
      }
      _pageController = PageController(initialPage: _variantIndex);
      for (var i = 0; i < allVars.length; i++) {
        final units = allVars[i].units.isNotEmpty
            ? allVars[i].units
            : widget.product.units;
        _variantUnits[i] = (i == _variantIndex && widget.initialUnit != null)
            ? (units
                    .where((u) =>
                        u.label.trim() == widget.initialUnit!.label.trim())
                    .firstOrNull ??
                (units.isNotEmpty ? units.first : null))
            : (units.isNotEmpty ? units.first : null);
        _variantQtys[i] = 1;
      }
      _selectedUnit = _variantUnits[_variantIndex];
      _qty = 1;
    } else {
      _selectedUnit = widget.initialUnit ??
          (widget.product.units.isNotEmpty ? widget.product.units.first : null);
    }
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  double _priceFor(ProductVariant? v) =>
      _selectedUnit?.price ?? v?.price ?? widget.product.price;

  String get _currentUnitLabel => _selectedUnit?.label ?? 'كرتون';

  String? _imageFor(ProductVariant? v, {ProductUnit? unit}) {
    final activeUnit = unit ?? _selectedUnit;
    if (activeUnit?.imageUrl != null &&
        activeUnit!.imageUrl!.trim().isNotEmpty) {
      return activeUnit.imageUrl!.trim();
    }
    if (v?.imageUrl != null && v!.imageUrl!.trim().isNotEmpty) {
      return v.imageUrl!.trim();
    }
    return widget.product.imageUrl;
  }

  String _sizeDisplayFor(ProductVariant? v, {ProductUnit? unit}) {
    final activeUnit = unit ?? _selectedUnit;
    if (activeUnit != null &&
        activeUnit.label.trim() != 'كرتون' &&
        activeUnit.sizeMl != null) {
      final us = activeUnit.sizeMl!;
      return us % 1 == 0 ? '${us.toInt()} مل' : '$us مل';
    }
    if (v?.sizeText != null && v!.sizeText!.trim().isNotEmpty) {
      return v.sizeText!.trim();
    }
    if (widget.product.sizeText != null &&
        widget.product.sizeText!.trim().isNotEmpty) {
      return widget.product.sizeText!.trim();
    }
    final s = activeUnit?.sizeMl ?? v?.sizeMl ?? widget.product.sizeMl;
    if (s != null) {
      return s % 1 == 0 ? '${s.toInt()} مل' : '$s مل';
    }
    return '—';
  }

  int? _itemsFor(ProductVariant? v, {ProductUnit? unit}) {
    final activeUnit = unit ?? _selectedUnit;
    return activeUnit?.qty ??
        v?.itemsPerCarton ??
        widget.product.itemsPerCarton;
  }

  String _formatDate(String? date) {
    if (date == null || date.isEmpty) return '—';
    try {
      final dt = DateTime.parse(date);
      return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return date.replaceAll('-', '/');
    }
  }

  void _onVariantChanged(int newIndex) {
    HapticFeedback.selectionClick();
    setState(() {
      _variantIndex = newIndex;
      _qty = _qtyForIndex(newIndex);
      _selectedUnit = _unitForIndex(newIndex);
    });
  }

  void _addToCart() {
    final v = _currentVariant;
    final isBaseVariant = v == null || v.id == 'base_default';
    final effectiveVariant = isBaseVariant ? null : v;
    final availableStock = v?.stock ?? widget.product.baseStock;
    if (availableStock <= 0) return;

    final cartonCap = v?.itemsPerCarton ?? widget.product.itemsPerCarton ?? 1;
    final safeCap = cartonCap > 0 ? cartonCap : 1;
    final unitQty = (_selectedUnit?.qty ?? safeCap) > 0
        ? (_selectedUnit?.qty ?? safeCap)
        : 1;

    double usedCartons = 0.0;
    for (final cItem in ref.read(cartProvider).values) {
      if (cItem.product.id == widget.product.id &&
          (cItem.selectedVariant?.id ?? '') == (effectiveVariant?.id ?? '')) {
        final cCap = cItem.selectedVariant?.itemsPerCarton ??
            cItem.product.itemsPerCarton ??
            1;
        final uQty = cItem.selectedUnit?.qty ?? cCap;
        usedCartons += (cItem.quantity * uQty) / (cCap > 0 ? cCap : 1);
      }
    }

    final remainingCartons =
        (availableStock - usedCartons).clamp(0.0, availableStock);
    final maxAddableUnits = ((remainingCartons * safeCap) / unitQty).floor();

    if (maxAddableUnits <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'وصلت للحد الأقصى المتوفر في المستودع لهذا الصنف داخل سلتك',
            style: TextStyle(fontFamily: 'Cairo'),
          ),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final qtyToAdd = _qty > maxAddableUnits ? maxAddableUnits : _qty;
    HapticFeedback.mediumImpact();
    ref.read(cartProvider.notifier).addItem(
          widget.product,
          qtyToAdd,
          unit: _selectedUnit,
          variant: effectiveVariant,
        );
    final title = !isBaseVariant
        ? '${v.label} - $_currentUnitLabel'
        : '${widget.product.name} - $_currentUnitLabel';
    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '✅ تمت إضافة $title للسلة',
          style: const TextStyle(fontFamily: 'Cairo'),
          textAlign: TextAlign.right,
        ),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 85),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final currentVariant = _currentVariant;
    final activeStock = currentVariant?.stock ?? product.baseStock;
    final isOutOfStock = activeStock <= 0;
    final total = _priceFor(currentVariant) * _qty;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.90,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: context.bgCard,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // مقبض السحب
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // شريط الأحجام العلوي القابل للنقر + تلميح السحب
            if (product.hasVariants) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text(
                      'الأحجام المتوفرة:',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: context.textSecondary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '← اسحب يميناً أو يساراً →',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 38,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _effectiveVariants.length,
                  itemBuilder: (_, idx) {
                    final v = _effectiveVariants[idx];
                    final isSel = idx == _variantIndex;
                    final vOut = v.stock <= 0;
                    return GestureDetector(
                      onTap: () {
                        _pageController?.animateToPage(
                          idx,
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                        );
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: const EdgeInsetsDirectional.only(end: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: isSel ? AppColors.primary : context.bgInput,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isSel
                                ? AppColors.primary
                                : (vOut
                                    ? Colors.red.withValues(alpha: 0.3)
                                    : context.borderColor),
                          ),
                        ),
                        child: Center(
                          child: Text(
                            vOut ? '${v.label} (نفد)' : v.label,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 12,
                              fontWeight:
                                  isSel ? FontWeight.w800 : FontWeight.w600,
                              color: isSel
                                  ? Colors.white
                                  : (vOut ? Colors.red : context.textPrimary),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 6),
              Divider(height: 1, color: context.borderColor),
            ],

            // محتوى الصفحة (يدعم السحب الأفقي بالـ PageView عند وجود أحجام متعددة)
            if (product.hasVariants)
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _effectiveVariants.length,
                  onPageChanged: _onVariantChanged,
                  itemBuilder: (context, idx) => _buildPageContent(
                    context,
                    product,
                    _effectiveVariants[idx],
                    pageIndex: idx,
                  ),
                ),
              )
            else
              Flexible(
                child: _buildPageContent(context, product, null, pageIndex: 0),
              ),
            // زر الإضافة للسلة الثابت بالأسفل
            Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 8, 20, MediaQuery.of(context).padding.bottom + 16),
              child: GestureDetector(
                onTap: isOutOfStock ? null : _addToCart,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: isOutOfStock ? Colors.grey : AppColors.primary,
                    borderRadius: AppRadius.lgAll,
                    boxShadow: isOutOfStock
                        ? []
                        : [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.35),
                              blurRadius: 14,
                              offset: const Offset(0, 5),
                            ),
                          ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isOutOfStock
                            ? Icons.remove_shopping_cart_rounded
                            : Icons.shopping_cart_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Text(
                          key: ValueKey('${_variantIndex}_$_qty'),
                          isOutOfStock
                              ? 'نفد من المستودع'
                              : (total > 0
                                  ? 'إضافة $_qty $_currentUnitLabel — ${total.toStringAsFixed(0)} ر.ي'
                                  : 'إضافة للسلة'),
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageContent(
    BuildContext context,
    ProductModel product,
    ProductVariant? v, {
    int pageIndex = 0,
  }) {
    final pageUnit =
        product.hasVariants ? _unitForIndex(pageIndex) : _selectedUnit;
    final pageQty = product.hasVariants ? _qtyForIndex(pageIndex) : _qty;
    final pageUnitLabel = pageUnit?.label ?? 'كرتون';
    final currentImage = _imageFor(v, unit: pageUnit);
    final hasImage = currentImage != null && currentImage.isNotEmpty;
    final currentPrice = pageUnit?.price ?? v?.price ?? product.price;
    final units = (v != null && v.units.isNotEmpty) ? v.units : product.units;
    final currentBarcode = (v?.barcode != null && v!.barcode!.trim().isNotEmpty)
        ? v.barcode!.trim()
        : (pageUnit?.barcode != null && pageUnit!.barcode!.trim().isNotEmpty)
            ? pageUnit.barcode!.trim()
            : product.barcode;
    final currentStock = v?.stock ?? product.baseStock;
    final currentProduction = pageUnit?.productionDate ??
        v?.productionDate ??
        DateTime.tryParse(product.productionDate ?? '');
    final currentExpiry = pageUnit?.expiryDate ??
        v?.expiryDate ??
        DateTime.tryParse(product.expiryDate ?? '');
    final isExpiringSoon = currentExpiry != null &&
        currentExpiry.isBefore(DateTime.now().add(const Duration(days: 30)));
    final isCustomVariant = v != null && v.id != 'base_default';
    final titleText = isCustomVariant
        ? '${v.label} - $pageUnitLabel'
        : '${product.name} - $pageUnitLabel';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: context.bgInput,
                  borderRadius: AppRadius.lgAll,
                  border: Border.all(color: context.borderColor),
                ),
                child: ClipRRect(
                  borderRadius: AppRadius.lgAll,
                  child: hasImage
                      ? CachedNetworkImage(
                          cacheManager:
                              ImagePrecacheService.instance.cacheManager,
                          imageUrl: currentImage,
                          fit: BoxFit.contain,
                          placeholder: (_, __) => const Icon(
                            Icons.shopping_bag_outlined,
                            color: Colors.grey,
                            size: 40,
                          ),
                          errorWidget: (_, __, ___) => const Icon(
                            Icons.shopping_bag_outlined,
                            color: AppColors.primary,
                            size: 40,
                          ),
                        )
                      : const Icon(
                          Icons.shopping_bag_outlined,
                          color: AppColors.primary,
                          size: 40,
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titleText,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: context.textPrimary,
                      ),
                    ),
                    if (product.description != null &&
                        product.description!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        product.description!,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12,
                          color: context.textSecondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        borderRadius: AppRadius.circleAll,
                      ),
                      child: Text(
                        '${currentPrice.toStringAsFixed(0)} ر.ي / $pageUnitLabel',
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // اختيار الوحدة الخاصة بهذا الحجم
          if (units.isNotEmpty) ...[
            Text(
              'اختر الكمية / الوحدة المطلوبة:',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: units.map((unit) {
                final selected = pageUnit?.label == unit.label;
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      if (product.hasVariants) {
                        _variantUnits[pageIndex] = unit;
                        if (pageIndex == _variantIndex) {
                          _selectedUnit = unit;
                        }
                      } else {
                        _selectedUnit = unit;
                      }
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.primary : context.bgInput,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color:
                            selected ? AppColors.primary : context.borderColor,
                        width: selected ? 1.5 : 1,
                      ),
                    ),
                    child: Text(
                      '${unit.label} (${unit.price.toStringAsFixed(0)} ر.ي)',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w600,
                        color: selected ? Colors.white : context.textPrimary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
          ],

          // تفاصيل الحجم/المنتج
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: context.bgInput,
              borderRadius: AppRadius.lgAll,
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              children: [
                if (currentBarcode != null && currentBarcode.isNotEmpty) ...[
                  _InfoTile(
                    icon: Icons.qr_code_2_rounded,
                    label: 'الباركود الموحد',
                    value: currentBarcode,
                    valueColor: AppColors.primary,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: _BarcodeVisualBox(barcode: currentBarcode),
                  ),
                  _divider(context),
                ],
                _InfoTile(
                  icon: Icons.straighten_rounded,
                  label: 'الحجم',
                  value: _sizeDisplayFor(v, unit: pageUnit),
                ),
                _divider(context),
                _InfoTile(
                  icon: Icons.inventory_2_rounded,
                  label: 'عدد الحبات / كرتون',
                  value: _itemsFor(v, unit: pageUnit) != null
                      ? '${_itemsFor(v, unit: pageUnit)} حبة'
                      : '—',
                ),
                _divider(context),
                _InfoTile(
                  icon: Icons.layers_rounded,
                  label: 'المخزون',
                  value:
                      '${currentStock % 1 == 0 ? currentStock.toInt() : currentStock.toStringAsFixed(2)} كرتون',
                  valueColor: currentStock <= 0 ? Colors.red : null,
                ),
                _divider(context),
                _InfoTile(
                  icon: Icons.calendar_month_rounded,
                  label: 'تاريخ الإنتاج',
                  value: currentProduction == null
                      ? '—'
                      : _formatDate(currentProduction.toIso8601String()),
                ),
                _divider(context),
                _InfoTile(
                  icon: Icons.event_busy_rounded,
                  label: 'تاريخ الانتهاء',
                  value: currentExpiry == null
                      ? '—'
                      : _formatDate(currentExpiry.toIso8601String()),
                  valueColor: isExpiringSoon ? Colors.red : null,
                  badge: isExpiringSoon ? 'ينتهي قريباً' : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
// عداد الكمية (مقيد بالمخزون المتاح)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _QtyBtn(
                icon: Icons.remove_rounded,
                onTap: () {
                  if (pageQty > 1) {
                    setState(() {
                      final next = pageQty - 1;
                      if (product.hasVariants) {
                        _variantQtys[pageIndex] = next;
                        if (pageIndex == _variantIndex) _qty = next;
                      } else {
                        _qty = next;
                      }
                    });
                  }
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: Text(
                    '$pageQty',
                    key: ValueKey('${pageIndex}_$pageQty'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: context.textPrimary,
                    ),
                  ),
                ),
              ),
              _QtyBtn(
                icon: Icons.add_rounded,
                onTap: () {
                  final cartonCap =
                      (v?.itemsPerCarton ?? product.itemsPerCarton ?? 1)
                          .clamp(1, 9999);
                  final unitQty = (pageUnit?.qty ?? cartonCap).clamp(1, 9999);
                  final maxUnits = ((currentStock * cartonCap) / unitQty)
                      .floor()
                      .clamp(1, 999);
                  if (currentStock > 0 && pageQty < maxUnits) {
                    setState(() {
                      final next = pageQty + 1;
                      if (product.hasVariants) {
                        _variantQtys[pageIndex] = next;
                        if (pageIndex == _variantIndex) _qty = next;
                      } else {
                        _qty = next;
                      }
                    });
                  }
                },
                filled: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) =>
      Divider(height: 1, color: context.borderColor);
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final String? badge;

  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Icon(icon, size: 19, color: AppColors.primary),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: context.textSecondary,
              )),
          const Spacer(),
          if (badge != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(badge!,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    color: Colors.red,
                    fontWeight: FontWeight.w600,
                  )),
            ),
            const SizedBox(width: 8),
          ],
          Text(value,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: valueColor ?? context.textPrimary,
              )),
        ],
      ),
    );
  }
}

class _QtyBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;

  const _QtyBtn({
    required this.icon,
    required this.onTap,
    this.filled = false,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: filled
              ? AppColors.primary
              : AppColors.primary.withValues(alpha: 0.1),
          borderRadius: AppRadius.mdAll,
        ),
        child: Icon(
          icon,
          size: 22,
          color: filled ? Colors.white : AppColors.primary,
        ),
      ),
    );
  }
}

class _BarcodeVisualBox extends StatelessWidget {
  final String barcode;
  const _BarcodeVisualBox({required this.barcode});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300, width: 1.2),
      ),
      child: Column(
        children: [
          CustomPaint(
            size: const Size(double.infinity, 48),
            painter: _BarcodePainter(code: barcode),
          ),
          const SizedBox(height: 6),
          Text(
            barcode.split('').join('  '),
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12.5,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
              color: Color(0xFF1A1A2E),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarcodePainter extends CustomPainter {
  final String code;
  _BarcodePainter({required this.code});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    final width = size.width;
    final height = size.height;
    final hashValues = code.codeUnits;
    const totalBars = 55;
    final barUnitWidth = width / totalBars;

    for (int i = 0; i < totalBars; i++) {
      final isGuard = (i < 3) || (i > totalBars - 4) || (i >= 26 && i <= 28);
      final charVal = hashValues[i % hashValues.length];
      final isBlack = isGuard || ((charVal + i * 7) % 3 != 0);

      if (isBlack) {
        final barHeight = isGuard ? height : height * 0.88;
        canvas.drawRect(
          Rect.fromLTWH(i * barUnitWidth, 0, barUnitWidth * 0.78, barHeight),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
