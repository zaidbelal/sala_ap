import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_adaptive_colors.dart';
import '../../../../core/services/image_precache_service.dart';
import '../services/products_service.dart';
import '../../cart/providers/cart_provider.dart';
import 'package:wissal/core/models/product_unit.dart';
import 'package:wissal/core/utils/arabic_normalizer.dart';
import 'product_details_sheet.dart';

class ProductCard extends ConsumerStatefulWidget {
  final ProductModel product;
  const ProductCard({super.key, required this.product});

  @override
  ConsumerState<ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends ConsumerState<ProductCard> {
  int _qty = 1;
  int _selectedVariantIndex = 0;
  ProductUnit? _selectedUnit;

  List<ProductVariant> get _allVariants => widget.product.hasVariants
      ? widget.product.allVariantsWithBase
      : const [];

  ProductVariant? get _activeVariant =>
      _allVariants.isNotEmpty ? _allVariants[_selectedVariantIndex] : null;

  @override
  void initState() {
    super.initState();
    _initSelection();
  }

  @override
  void didUpdateWidget(covariant ProductCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.product.id != widget.product.id) {
      _initSelection();
    }
  }

  void _initSelection() {
    _qty = 1;
    _selectedVariantIndex = 0;
    _updateSelectedUnit();
  }

  void _updateSelectedUnit() {
    final v = _activeVariant;
    final units =
        (v != null && v.units.isNotEmpty) ? v.units : widget.product.units;
    _selectedUnit = units.isNotEmpty ? units.first : null;
  }

  double get _currentUnitPrice {
    if (_selectedUnit != null) return _selectedUnit!.price;
    if (_activeVariant != null) return _activeVariant!.price;
    return widget.product.price;
  }

  String get _currentUnitLabel => _selectedUnit?.label ?? 'كرتون';

  String? get _currentImage {
    if (_selectedUnit?.imageUrl != null &&
        _selectedUnit!.imageUrl!.trim().isNotEmpty) {
      return _selectedUnit!.imageUrl!.trim();
    }
    if (_activeVariant?.imageUrl != null &&
        _activeVariant!.imageUrl!.trim().isNotEmpty) {
      return _activeVariant!.imageUrl!.trim();
    }
    return widget.product.imageUrl;
  }

  double get _currentStock => _activeVariant?.stock ?? widget.product.baseStock;
  void _onVariantSelected(int index) {
    if (_selectedVariantIndex == index) return;
    HapticFeedback.selectionClick();
    setState(() {
      _selectedVariantIndex = index;
      _qty = 1;
      _updateSelectedUnit();
    });
  }

  void _onUnitSelected(ProductUnit unit) {
    if (_selectedUnit?.label == unit.label) return;
    HapticFeedback.selectionClick();
    setState(() {
      _selectedUnit = unit;
      _qty = 1;
    });
  }

  void _addToCart() {
    final v = _activeVariant;
    final isBaseVariant = v == null || v.id == 'base_default';
    final effectiveVariant = isBaseVariant ? null : v;
    final availableStock = _currentStock;

    if (availableStock <= 0) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('عذراً، هذا الحجم غير متوفر حالياً في المستودع',
              style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final cartonCap = (v?.itemsPerCarton ?? widget.product.itemsPerCarton ?? 1);
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
      ScaffoldMessenger.of(context).clearSnackBars();
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
        ? '${widget.product.name} (${v.label}) - $_currentUnitLabel'
        : '${widget.product.name} - $_currentUnitLabel';

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '✅ تمت إضافة $qtyToAdd من $title للسلة',
          style: const TextStyle(fontFamily: 'Cairo'),
          textAlign: TextAlign.right,
        ),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 85),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  void _openSheet() {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ProductDetailsSheet(
        product: widget.product,
        initialVariant: _activeVariant,
        initialUnit: _selectedUnit,
      ),
    );
  }

  Future<void> _showManualQtyDialog() async {
    HapticFeedback.mediumImpact();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => _ManualQtyDialog(
        initialQty: _qty,
        unitLabel: _currentUnitLabel,
        productName: _activeVariant != null
            ? '${widget.product.name} (${_activeVariant!.label})'
            : widget.product.name,
      ),
    );

    if (result != null && result > 0 && mounted) {
      final v = _activeVariant;
      final availableStock = _currentStock;
      final cartonCap =
          (v?.itemsPerCarton ?? widget.product.itemsPerCarton ?? 1);
      final safeCap = cartonCap > 0 ? cartonCap : 1;
      final unitQty = (_selectedUnit?.qty ?? safeCap) > 0
          ? (_selectedUnit?.qty ?? safeCap)
          : 1;

      final maxUnits = availableStock > 0
          ? ((availableStock * safeCap) / unitQty).floor().clamp(1, 999)
          : 999;

      final finalQty = result > maxUnits ? maxUnits : result;
      setState(() => _qty = finalQty);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _activeVariant;
    final isOutOfStock = _currentStock <= 0;
    final currentPrice = _currentUnitPrice;
    final pageTotal = currentPrice * _qty;
    final availableUnits =
        (v != null && v.units.isNotEmpty) ? v.units : widget.product.units;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: context.bgCard,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: context.borderColor),
        boxShadow: [
          BoxShadow(
            color: context.shadowColor.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 1. اسم المنتج + شريط الأحجام المتوفرة ──
            GestureDetector(
              onTap: _openSheet,
              child: Text(
                widget.product.name,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                  color: context.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // شريط اختيار الحجم بنقرة واحدة فائقة السلاسة
            if (_allVariants.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 32,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: _allVariants.length,
                  itemBuilder: (ctx, idx) {
                    final variant = _allVariants[idx];
                    final isSel = idx == _selectedVariantIndex;
                    final vOut = variant.stock <= 0;

                    return GestureDetector(
                      onTap: () => _onVariantSelected(idx),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: const EdgeInsetsDirectional.only(end: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isSel
                              ? AppColors.primary
                              : AppColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSel
                                ? AppColors.primary
                                : (vOut
                                    ? Colors.red.withValues(alpha: 0.3)
                                    : AppColors.primary.withValues(alpha: 0.2)),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (vOut) ...[
                              const Icon(Icons.block_rounded,
                                  size: 11, color: Colors.red),
                              const SizedBox(width: 3),
                            ],
                            Text(
                              variant.label,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 11,
                                fontWeight:
                                    isSel ? FontWeight.w800 : FontWeight.w700,
                                color: isSel
                                    ? Colors.white
                                    : (vOut ? Colors.red : AppColors.primary),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],

            const SizedBox(height: 10),

            // ── 2. المنطقة الوسطى (الصورة + الأسعار مع التحديث الفوري) ──
            Row(
              children: [
                // الإجمالي
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'الإجمالي',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          color: context.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Text(
                          key: ValueKey(pageTotal),
                          '${pageTotal.toStringAsFixed(0)} ر.ي',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            color: context.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // سعر الوحدة المحددة
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'سعر $_currentUnitLabel',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          color: context.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Text(
                          key: ValueKey('${currentPrice}_$_currentUnitLabel'),
                          '${currentPrice.toStringAsFixed(0)} ر.ي',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: context.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 10),

                // صورة المنتج أو الحجم أو الوحدة المحددة
                GestureDetector(
                  onTap: _openSheet,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: 76,
                      height: 76,
                      color: context.bgInput,
                      child: _currentImage != null && _currentImage!.isNotEmpty
                          ? CachedNetworkImage(
                              cacheManager:
                                  ImagePrecacheService.instance.cacheManager,
                              imageUrl: _currentImage!,
                              fit: BoxFit.contain,
                              memCacheWidth: 200,
                              placeholder: (_, __) => const Center(
                                child: Icon(Icons.inventory_2_outlined,
                                    color: Colors.grey, size: 28),
                              ),
                              errorWidget: (_, __, ___) => const Center(
                                child: Icon(Icons.inventory_2_outlined,
                                    color: AppColors.primary, size: 28),
                              ),
                            )
                          : const Center(
                              child: Icon(Icons.inventory_2_outlined,
                                  color: AppColors.primary, size: 28),
                            ),
                    ),
                  ),
                ),
              ],
            ),

            // ── 3. شريط وحدات الحجم المحدد (كرتون / نصف كرتون / حبة) ──
            if (availableUnits.length > 1) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 28,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: availableUnits.length,
                  itemBuilder: (ctx, uIdx) {
                    final unit = availableUnits[uIdx];
                    final isSelUnit = _selectedUnit?.label == unit.label;

                    return GestureDetector(
                      onTap: () => _onUnitSelected(unit),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: const EdgeInsetsDirectional.only(end: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: isSelUnit
                              ? const Color(0xFF1B8E3D)
                              : context.bgInput,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelUnit
                                ? const Color(0xFF1B8E3D)
                                : context.borderColor,
                          ),
                        ),
                        child: Text(
                          '${unit.label} (${unit.price.toStringAsFixed(0)} ر.ي)',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 10.5,
                            fontWeight:
                                isSelUnit ? FontWeight.w800 : FontWeight.w600,
                            color:
                                isSelUnit ? Colors.white : context.textPrimary,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],

            const SizedBox(height: 12),

            // ── 4. عداد الكمية (+ / -) وزر الإضافة للسلة المباشر ──
            Row(
              children: [
                // أزرار التحكم بالكمية
                Container(
                  decoration: BoxDecoration(
                    color: context.bgInput,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () {
                          if (_qty > 1) {
                            HapticFeedback.lightImpact();
                            setState(() => _qty--);
                          }
                        },
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: context.bgInput,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.remove_rounded,
                            color: _qty > 1
                                ? context.textPrimary
                                : Colors.grey.shade400,
                            size: 18,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _showManualQtyDialog,
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          child: Text(
                            '$_qty',
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: context.textPrimary,
                            ),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          setState(() => _qty++);
                        },
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.add_rounded,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 10),

                // زر الإضافة للسلة المباشر
                Expanded(
                  child: SizedBox(
                    height: 42,
                    child: ElevatedButton.icon(
                      onPressed: isOutOfStock ? null : _addToCart,
                      icon: Icon(
                        isOutOfStock
                            ? Icons.remove_shopping_cart_rounded
                            : Icons.shopping_cart_outlined,
                        size: 17,
                      ),
                      label: Text(
                        isOutOfStock
                            ? 'نفد المخزون'
                            : 'إضافة ($_currentUnitLabel)',
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            isOutOfStock ? Colors.grey : AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
// نافذة إدخال الكمية اليدوية وتدعم الأرقام العربية والإنجليزية
// ══════════════════════════════════════════════════════
class _ManualQtyDialog extends StatefulWidget {
  final int initialQty;
  final String unitLabel;
  final String productName;

  const _ManualQtyDialog({
    required this.initialQty,
    required this.unitLabel,
    required this.productName,
  });

  @override
  State<_ManualQtyDialog> createState() => _ManualQtyDialogState();
}

class _ManualQtyDialogState extends State<_ManualQtyDialog> {
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
    final text = ArabicNormalizer.normalizeDigits(_controller.text).trim();
    final val = int.tryParse(text);
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
            widget.productName,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.textSecondary,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            'أدخل عدد (${widget.unitLabel}) المطلوبة:',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              color: context.textSecondary,
            ),
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
            inputFormatters: [
              TextInputFormatter.withFunction((oldVal, newVal) {
                // تحويل الأرقام العربية المشرقية (١، ٢، ٣...) تلقائياً لأرقام قياسية
                final normalized =
                    ArabicNormalizer.normalizeDigits(newVal.text);
                final digitsOnly = normalized.replaceAll(RegExp(r'[^0-9]'), '');
                return TextEditingValue(
                  text: digitsOnly,
                  selection: TextSelection.collapsed(offset: digitsOnly.length),
                );
              }),
              LengthLimitingTextInputFormatter(4),
            ],
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: AppColors.primary,
            ),
            decoration: InputDecoration(
              filled: true,
              fillColor: context.bgInput,
              hintText: '1',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    const BorderSide(color: AppColors.primary, width: 1.5),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    const BorderSide(color: AppColors.primary, width: 2),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.pop(context);
          },
          child: const Text(
            'إلغاء',
            style: TextStyle(fontFamily: 'Cairo', color: Colors.grey),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: _submit,
          child: const Text(
            'تأكيد',
            style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
