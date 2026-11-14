import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_adaptive_colors.dart';
import '../../../../core/services/image_precache_service.dart';
import '../services/products_service.dart';
import '../../cart/providers/cart_provider.dart';
import 'product_details_sheet.dart';

class ProductCard extends ConsumerStatefulWidget {
  final ProductModel product;
  const ProductCard({super.key, required this.product});

  @override
  ConsumerState<ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends ConsumerState<ProductCard> {
  int _qty = 1;

  Future<void> _showManualQtyDialog() async {
    HapticFeedback.mediumImpact();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => _ManualQtyDialog(
        initialQty: _qty,
        unitLabel: 'كرتون',
      ),
    );

    if (result != null && result > 0 && mounted) {
      setState(() => _qty = result);
    }
  }

  void _addToCart() {
    if (widget.product.stock <= 0) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('عذراً، هذا الصنف غير متوفر حالياً في المستودع',
              style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (widget.product.stock < 1) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'المتبقي أقل من كرتون كامل، اختر وحدة أصغر من تفاصيل الصنف',
              style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: Colors.orange,
        ),
      );
      _openSheet();
      return;
    }
    final cartonCap = (widget.product.itemsPerCarton ?? 1) > 0
        ? widget.product.itemsPerCarton!
        : 1;
    double usedCartons = 0.0;
    for (final item in ref.read(cartProvider).values) {
      if (item.product.id == widget.product.id) {
        final uQty = item.selectedUnit?.qty ?? cartonCap;
        usedCartons += (item.quantity * uQty) / cartonCap;
      }
    }
    final remainingCartons = (widget.product.stock - usedCartons).floor();
    if (remainingCartons <= 0) {
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

    final qtyToAdd = _qty > remainingCartons ? remainingCartons : _qty;
    if (qtyToAdd != _qty) {
      setState(() => _qty = qtyToAdd);
    }
    HapticFeedback.mediumImpact();

    ref.read(cartProvider.notifier).addItem(
          widget.product,
          qtyToAdd,
        );

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          qtyToAdd < _qty
              ? '⚠️ تم إضافة المتبقي فقط ($qtyToAdd كرتون) من (${widget.product.name})'
              : '✅ تمت إضافة $qtyToAdd من (${widget.product.name}) إلى السلة',
          style: const TextStyle(fontFamily: 'Cairo'),
          textAlign: TextAlign.right,
        ),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
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
      builder: (_) => ProductDetailsSheet(product: widget.product),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cartQty = ref.watch(
      cartProvider.select((c) => c.values
          .where((item) => item.product.id == widget.product.id)
          .fold<int>(0, (sum, item) => sum + item.quantity)),
    );
    final hasVariants = widget.product.hasVariants;
    final isOutOfStock = hasVariants
        ? widget.product.totalStock <= 0
        : widget.product.stock <= 0;
    final pageTotal = (hasVariants
            ? widget.product.effectiveMinPrice
            : widget.product.price) *
        _qty;

    return GestureDetector(
      onTap: _openSheet,
      child: Container(
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
              // ── اسم المنتج ──
              Text(
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
              const SizedBox(height: 10),

              // ── السعر والإجمالي والصورة ──
              Row(
                children: [
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
                        Text(
                          '${pageTotal.toStringAsFixed(0)} ر.ي',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            color: context.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          hasVariants ? 'ابتداءً من' : 'سعر الكرتون',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            color: context.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${(hasVariants ? widget.product.effectiveMinPrice : widget.product.price).toStringAsFixed(0)} ر.ي',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: context.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _openSheet,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        width: 76,
                        height: 76,
                        color: context.bgInput,
                        child: widget.product.imageUrl != null &&
                                widget.product.imageUrl!.isNotEmpty
                            ? CachedNetworkImage(
                                cacheManager:
                                    ImagePrecacheService.instance.cacheManager,
                                imageUrl: widget.product.imageUrl!,
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

              if (hasVariants) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: widget.product.variants.map((v) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.2)),
                      ),
                      child: Text(
                        '${v.label} (${v.price.toStringAsFixed(0)} ر.ي)',
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ] else ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (cartQty > 0) ...[
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            const Icon(Icons.shopping_cart_rounded,
                                size: 16, color: AppColors.primary),
                            Positioned(
                              top: -7,
                              right: -7,
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: const BoxDecoration(
                                    color: Colors.red, shape: BoxShape.circle),
                                child: Text(
                                  '$cartQty',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 8,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),
                    ],
                    GestureDetector(
                      onTap: () {
                        if (_qty > 1) {
                          HapticFeedback.lightImpact();
                          setState(() => _qty--);
                        }
                      },
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: context.bgInput,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Icon(
                          Icons.remove_rounded,
                          color: _qty > 1
                              ? context.textPrimary
                              : Colors.grey.shade400,
                          size: 20,
                        ),
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onDoubleTap: _showManualQtyDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        child: Text(
                          '$_qty',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: context.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        final maxWholeCartons =
                            widget.product.stock.floor().clamp(1, 999);
                        if (_qty < maxWholeCartons) {
                          HapticFeedback.lightImpact();
                          setState(() => _qty++);
                        }
                      },
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.add_rounded,
                            color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  onPressed: isOutOfStock
                      ? null
                      : (hasVariants ? _openSheet : _addToCart),
                  icon: Icon(
                      isOutOfStock
                          ? Icons.remove_shopping_cart_rounded
                          : (hasVariants
                              ? Icons.tune_rounded
                              : Icons.shopping_cart_outlined),
                      size: 19),
                  label: Text(
                    isOutOfStock
                        ? 'نفد المخزون'
                        : (hasVariants
                            ? 'اختيار الحجم والكمية${cartQty > 0 ? " ($cartQty بالسلة)" : ""}'
                            : 'إضافة للسلة'),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 14.5,
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
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
// نافذة إدخال الكمية اليدوية الآمنة والخالية من الأخطاء
// ══════════════════════════════════════════════════════
class _ManualQtyDialog extends StatefulWidget {
  final int initialQty;
  final String unitLabel;

  const _ManualQtyDialog({
    required this.initialQty,
    required this.unitLabel,
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
    _controller.dispose(); // يُحذف بأمان تام فقط بعد إغلاق النافذة بالكامل
    super.dispose();
  }

  void _submit() {
    const arabic = {
      '٠': '0',
      '١': '1',
      '٢': '2',
      '٣': '3',
      '٤': '4',
      '٥': '5',
      '٦': '6',
      '٧': '7',
      '٨': '8',
      '٩': '9'
    };
    var text = _controller.text.trim();
    arabic.forEach((k, v) => text = text.replaceAll(k, v));
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
            'أدخل عدد الكراتين / الحبات المطلوبة مباشرة:',
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
                const arabic = {
                  '٠': '0',
                  '١': '1',
                  '٢': '2',
                  '٣': '3',
                  '٤': '4',
                  '٥': '5',
                  '٦': '6',
                  '٧': '7',
                  '٨': '8',
                  '٩': '9',
                  '۰': '0',
                  '۱': '1',
                  '۲': '2',
                  '۳': '3',
                  '۴': '4',
                  '۵': '5',
                  '۶': '6',
                  '۷': '7',
                  '۸': '8',
                  '۹': '9'
                };
                var t = newVal.text;
                arabic.forEach((k, v) => t = t.replaceAll(k, v));
                t = t.replaceAll(RegExp(r'[^0-9]'), '');
                return TextEditingValue(
                  text: t,
                  selection: TextSelection.collapsed(offset: t.length),
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
