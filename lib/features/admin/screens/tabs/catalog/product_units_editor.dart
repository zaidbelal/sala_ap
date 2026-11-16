import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wissal/core/constants/app_colors.dart';
import 'package:wissal/core/models/product_unit.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:wissal/core/services/image_precache_service.dart';
import 'package:wissal/core/utils/arabic_normalizer.dart';
import '../../../../merchant/barcode/barcode_scanner_screen.dart';
import 'catalog_helpers.dart';
import 'products_tab.dart' show DateInputFormatter;

/// ويدجت لإضافة/تعديل/حذف وحدات البيع للمنتج في لوحة الأدمن
class ProductUnitsEditor extends StatefulWidget {
  final String? productName;
  final List<ProductUnit> initialUnits;
  final ValueChanged<List<ProductUnit>> onChanged;

  const ProductUnitsEditor({
    super.key,
    this.productName,
    required this.initialUnits,
    required this.onChanged,
  });

  @override
  State<ProductUnitsEditor> createState() => _ProductUnitsEditorState();
}

class _ProductUnitsEditorState extends State<ProductUnitsEditor> {
  late List<ProductUnit> _units;

  @override
  void initState() {
    super.initState();
    _units = List.from(widget.initialUnits);
  }

  @override
  void didUpdateWidget(covariant ProductUnitsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialUnits != widget.initialUnits) {
      _units = List.from(widget.initialUnits);
    }
  }

  void _add() async {
    final unit = await _showUnitDialog(context);
    if (unit == null || !mounted) return;
    if (_units.any((u) => u.label.trim() == unit.label.trim())) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (dCtx) => AlertDialog(
            title: const Text('تنبيه', style: TextStyle(fontFamily: 'Cairo')),
            content: const Text('هذه الوحدة موجودة مسبقاً',
                style: TextStyle(fontFamily: 'Cairo')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dCtx),
                  child: const Text('حسناً',
                      style: TextStyle(fontFamily: 'Cairo')))
            ],
          ),
        );
      }
      return;
    }
    setState(() => _units.add(unit));
    widget.onChanged(_units);
  }

  void _remove(int index) {
    setState(() => _units.removeAt(index));
    widget.onChanged(_units);
  }

  void _edit(int index) async {
    final unit = await _showUnitDialog(context, existing: _units[index]);
    if (unit == null || !mounted) return;
    final isDuplicate = _units.asMap().entries.any(
          (entry) =>
              entry.key != index &&
              entry.value.label.trim() == unit.label.trim(),
        );
    if (isDuplicate) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (dCtx) => AlertDialog(
            title: const Text('تنبيه', style: TextStyle(fontFamily: 'Cairo')),
            content: const Text('توجد كمية أخرى بنفس هذا الاسم مسبقاً',
                style: TextStyle(fontFamily: 'Cairo')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dCtx),
                  child: const Text('حسناً',
                      style: TextStyle(fontFamily: 'Cairo')))
            ],
          ),
        );
      }
      return;
    }
    setState(() => _units[index] = unit);
    widget.onChanged(_units);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.productName != null &&
            widget.productName!.trim().isNotEmpty) ...[
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.18),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.inventory_2_outlined,
                  size: 18,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.productName!.trim(),
                    textDirection: TextDirection.rtl,
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        // ── العنوان + زر الإضافة ──
        Row(
          children: [
            const Text(
              'كميات إضافية (اختياري)',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF444444),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add_circle_outline_rounded,
                  size: 16, color: AppColors.primary),
              label: const Text(
                'إضافة كمية',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ),
          ],
        ),

        // ── لا وحدات ──
        if (_units.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: const Text(
              'لا توجد كميات إضافية — المنتج سيُباع بالسعر الافتراضي فقط',
              style: TextStyle(
                  fontFamily: 'Cairo', fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),

        // ── قائمة الوحدات ──
        ..._units.asMap().entries.map((e) {
          final i = e.key;
          final unit = e.value;
          final profit = (unit.costPrice != null && unit.costPrice! > 0)
              ? unit.price - unit.costPrice!
              : 0.0;

          return Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: AppColors.primary.withValues(alpha: 0.15)),
            ),
            child: Row(
              children: [
                if (unit.imageUrl != null && unit.imageUrl!.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CachedNetworkImage(
                      cacheManager: ImagePrecacheService.instance.cacheManager,
                      imageUrl: unit.imageUrl!,
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => const SizedBox(
                          width: 36,
                          height: 36,
                          child: Icon(Icons.broken_image, color: Colors.grey)),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.productName != null &&
                                widget.productName!.trim().isNotEmpty
                            ? '${widget.productName!.trim()} - ${unit.label}'
                            : unit.label,
                        textDirection: TextDirection.rtl,
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${unit.price.toStringAsFixed(0)} ر.ي'
                        '${profit > 0 ? " (ربح ${profit.toStringAsFixed(0)} ر.ي)" : ""}'
                        '${unit.sizeMl != null ? ' • ${unit.sizeMl!.toStringAsFixed(0)} مل' : ''}'
                        '${unit.qty > 1 ? ' • ${unit.qty} حبة' : ''}',
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            color: profit > 0 ? Colors.teal : Colors.grey),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _edit(i),
                  icon: const Icon(Icons.edit_outlined,
                      size: 18, color: AppColors.primary),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: () => _remove(i),
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: Colors.red),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

// ── حوار إضافة/تعديل وحدة (محصن من تسريب الذاكرة بـ StatefulWidget) ──
Future<ProductUnit?> _showUnitDialog(
  BuildContext context, {
  ProductUnit? existing,
}) {
  return showModalBottomSheet<ProductUnit>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    builder: (_) => _UnitEditModalSheet(existing: existing),
  );
}

class _UnitEditModalSheet extends StatefulWidget {
  final ProductUnit? existing;
  const _UnitEditModalSheet({this.existing});

  @override
  State<_UnitEditModalSheet> createState() => _UnitEditModalSheetState();
}

class _UnitEditModalSheetState extends State<_UnitEditModalSheet> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _labelCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _costCtrl;
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _sizeCtrl;
  late final TextEditingController _barcodeCtrl;
  late final TextEditingController _prodDateCtrl;
  late final TextEditingController _expDateCtrl;

  XFile? _selectedImage;
  Uint8List? _selectedImageBytes;
  bool _removeOldImage = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    _labelCtrl = TextEditingController(text: ex?.label ?? '');
    _priceCtrl = TextEditingController(
        text: ex != null ? ex.price.toStringAsFixed(0) : '');
    _costCtrl = TextEditingController(
        text: ex?.costPrice != null ? ex!.costPrice!.toStringAsFixed(0) : '');
    _qtyCtrl = TextEditingController(text: ex != null ? '${ex.qty}' : '1');
    _sizeCtrl = TextEditingController(
        text: ex?.sizeMl != null ? ex!.sizeMl!.toStringAsFixed(0) : '');
    _barcodeCtrl = TextEditingController(text: ex?.barcode ?? '');
    _prodDateCtrl = TextEditingController(
        text: ex?.productionDate != null ? _fmtDate(ex!.productionDate!) : '');
    _expDateCtrl = TextEditingController(
        text: ex?.expiryDate != null ? _fmtDate(ex!.expiryDate!) : '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _priceCtrl.dispose();
    _costCtrl.dispose();
    _qtyCtrl.dispose();
    _sizeCtrl.dispose();
    _barcodeCtrl.dispose();
    _prodDateCtrl.dispose();
    _expDateCtrl.dispose();
    super.dispose();
  }

  Future<void> _chooseImage() async {
    try {
      final result = await pickCatalogImage();
      if (result.$1 == null || result.$2 == null) return;
      setState(() {
        _selectedImage = result.$1;
        _selectedImageBytes = result.$2;
        _removeOldImage = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('فشل اختيار الصورة: $e',
                style: const TextStyle(fontFamily: 'Cairo'))),
      );
    }
  }

  Future<void> _saveUnit() async {
    if (!_formKey.currentState!.validate()) return;

    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('عدد الحبات يجب أن يكون أكبر من صفر',
                style: TextStyle(fontFamily: 'Cairo'))),
      );
      return;
    }

    if (_prodDateCtrl.text.trim().isNotEmpty &&
        DateTime.tryParse(_prodDateCtrl.text.trim()) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('صيغة تاريخ الإنتاج غير صحيحة',
                style: TextStyle(fontFamily: 'Cairo')),
            backgroundColor: Colors.red),
      );
      return;
    }
    if (_expDateCtrl.text.trim().isNotEmpty &&
        DateTime.tryParse(_expDateCtrl.text.trim()) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('صيغة تاريخ الانتهاء غير صحيحة',
                style: TextStyle(fontFamily: 'Cairo')),
            backgroundColor: Colors.red),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      String? imageUrl = widget.existing?.imageUrl;

      if (_removeOldImage) {
        // لا يتم حذف الصورة فوراً من السيرفر لتفادي فقدانها إذا ألغى الأدمن تعديل المنتج قبل الحفظ
        imageUrl = null;
      }

      if (_selectedImage != null) {
        imageUrl = await uploadCatalogImage(_selectedImage!);
        if (imageUrl == null || imageUrl.trim().isEmpty) {
          throw Exception('تعذر رفع صورة الكمية');
        }
      }

      if (!mounted) return;
      final costText = ArabicNormalizer.normalizeDigits(_costCtrl.text).trim();
      final parsedCost = costText.isNotEmpty ? double.tryParse(costText) : null;

      Navigator.pop(
        context,
        ProductUnit(
          label: _labelCtrl.text.trim(),
          price: double.tryParse(
                  ArabicNormalizer.normalizeDigits(_priceCtrl.text).trim()) ??
              0,
          costPrice: parsedCost,
          qty: qty,
          sizeMl: double.tryParse(
              ArabicNormalizer.normalizeDigits(_sizeCtrl.text).trim()),
          imageUrl: imageUrl,
          productionDate: _prodDateCtrl.text.trim().isEmpty
              ? null
              : DateTime.tryParse(_prodDateCtrl.text.trim()),
          expiryDate: _expDateCtrl.text.trim().isEmpty
              ? null
              : DateTime.tryParse(_expDateCtrl.text.trim()),
          barcode: _barcodeCtrl.text.trim().isEmpty
              ? null
              : _barcodeCtrl.text.trim(),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('فشل حفظ الكمية: $e',
                style: const TextStyle(fontFamily: 'Cairo'))),
      );
    }
  }

  Widget _imagePreview() {
    if (_selectedImageBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(_selectedImageBytes!,
            width: 64, height: 64, fit: BoxFit.cover),
      );
    }
    if (!_removeOldImage &&
        widget.existing?.imageUrl != null &&
        widget.existing!.imageUrl!.trim().isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: CachedNetworkImage(
          cacheManager: ImagePrecacheService.instance.cacheManager,
          imageUrl: widget.existing!.imageUrl!,
          width: 64,
          height: 64,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => const Icon(Icons.broken_image_outlined,
              color: Colors.grey, size: 30),
        ),
      );
    }
    return const Icon(Icons.add_photo_alternate_rounded,
        color: AppColors.primary, size: 30);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.92),
        decoration: const BoxDecoration(
          color: Color(0xFFF5F7FA),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(10)),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        widget.existing == null
                            ? 'إضافة كمية جديدة'
                            : 'تعديل الكمية',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 16,
                            fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 16),
                      GestureDetector(
                        onTap: _saving ? null : _chooseImage,
                        child: Container(
                          height: 82,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE6E9ED)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  color:
                                      AppColors.primary.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: _imagePreview(),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'صورة الكمية من المعرض (اختياري)\nPNG أو JPG — سيتم ضغطها تلقائياً',
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 12,
                                      color: Colors.grey,
                                      height: 1.6),
                                ),
                              ),
                              if (_selectedImageBytes != null ||
                                  widget.existing?.imageUrl != null)
                                IconButton(
                                  onPressed: _saving
                                      ? null
                                      : () => setState(() {
                                            _selectedImage = null;
                                            _selectedImageBytes = null;
                                            _removeOldImage = true;
                                          }),
                                  icon: const Icon(Icons.close_rounded,
                                      color: Colors.red, size: 20),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _labelCtrl,
                        textDirection: TextDirection.rtl,
                        decoration: _dec(
                            'اسم الكمية، مثل: حبة، نصف كرتون، ربع كرتون *'),
                        style: const TextStyle(fontFamily: 'Cairo'),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'اسم الكمية مطلوب'
                            : null,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _priceCtrl,
                              textDirection: TextDirection.rtl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              inputFormatters: const [
                                ArabicDigitsInputFormatter()
                              ],
                              decoration: _dec('سعر البيع ر.ي *'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontSize: 13),
                              validator: (v) {
                                final p = double.tryParse(
                                    ArabicNormalizer.normalizeDigits(v ?? '')
                                        .trim());
                                return (p == null || p < 0)
                                    ? 'أدخل سعراً صحيحاً'
                                    : null;
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: _costCtrl,
                              textDirection: TextDirection.rtl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              inputFormatters: const [
                                ArabicDigitsInputFormatter()
                              ],
                              decoration: _dec('سعر الشراء 🔒'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _qtyCtrl,
                              textDirection: TextDirection.rtl,
                              keyboardType: TextInputType.number,
                              inputFormatters: const [
                                ArabicDigitsInputFormatter(allowDecimal: false)
                              ],
                              decoration: _dec('عدد الحبات الأساسية *'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontSize: 13),
                              validator: (v) {
                                final q = int.tryParse(
                                    ArabicNormalizer.normalizeDigits(v ?? '')
                                        .trim());
                                return (q == null || q <= 0)
                                    ? 'أدخل عدد الحبات'
                                    : null;
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: _sizeCtrl,
                              textDirection: TextDirection.rtl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: _dec('الحجم بالمل'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _barcodeCtrl,
                              textDirection: TextDirection.ltr,
                              decoration:
                                  _dec('باركود الوحدة (أدخل يدوياً أو امسحه)'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () async {
                              final scanned =
                                  await BarcodeScannerScreen.scan(context);
                              if (scanned != null && scanned.isNotEmpty) {
                                setState(() => _barcodeCtrl.text = scanned);
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
                      Row(
                        children: [
                          Expanded(
                            child: _UnitManualDateField(
                              ctrl: _prodDateCtrl,
                              hint: 'إنتاج: 2026-05-15',
                              icon: Icons.calendar_today_rounded,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _UnitManualDateField(
                              ctrl: _expDateCtrl,
                              hint: 'انتهاء: 2027-05-15',
                              icon: Icons.event_busy_rounded,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 52,
                        child: ElevatedButton.icon(
                          onPressed: _saving ? null : _saveUnit,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : const Icon(Icons.save_rounded, size: 19),
                          label: Text(_saving ? 'جاري الحفظ...' : 'حفظ الكمية',
                              style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontWeight: FontWeight.w700)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
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
}

// ── حقل إدخال التاريخ اليدوي المباشر والسريع ──
class _UnitManualDateField extends StatelessWidget {
  final TextEditingController ctrl;
  final String hint;
  final IconData icon;

  const _UnitManualDateField({
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
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFEEEEEE)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFEEEEEE)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
    );
  }
}

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
InputDecoration _dec(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
          fontFamily: 'Cairo', fontSize: 12, color: Colors.grey),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFEEEEEE)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFEEEEEE)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
    );

// ══════════════════════════════════════════════════════════
// محرر الأحجام / الأنواع المتعددة داخل نفس المنتج (كبير، صغير، 5 كيلو...)
// ══════════════════════════════════════════════════════════
class ProductVariantsEditor extends StatefulWidget {
  final String? productName;
  final List<ProductVariant> initialVariants;
  final ValueChanged<List<ProductVariant>> onChanged;

  const ProductVariantsEditor({
    super.key,
    this.productName,
    required this.initialVariants,
    required this.onChanged,
  });

  @override
  State<ProductVariantsEditor> createState() => _ProductVariantsEditorState();
}

class _ProductVariantsEditorState extends State<ProductVariantsEditor> {
  late List<ProductVariant> _variants;

  @override
  void initState() {
    super.initState();
    _variants = List.from(widget.initialVariants);
  }

  @override
  void didUpdateWidget(covariant ProductVariantsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialVariants != widget.initialVariants) {
      _variants = List.from(widget.initialVariants);
    }
  }

  Future<void> _add() async {
    final variant = await showModalBottomSheet<ProductVariant>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => const _VariantEditModalSheet(),
    );
    if (variant == null || !mounted) return;
    if (_variants.any((v) => v.label.trim() == variant.label.trim())) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (dCtx) => AlertDialog(
            title: const Text('تنبيه', style: TextStyle(fontFamily: 'Cairo')),
            content: const Text('هذا الحجم موجود مسبقاً في نفس المنتج',
                style: TextStyle(fontFamily: 'Cairo')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dCtx),
                  child: const Text('حسناً',
                      style: TextStyle(fontFamily: 'Cairo')))
            ],
          ),
        );
      }
      return;
    }
    setState(() => _variants.add(variant));
    widget.onChanged(_variants);
  }

  Future<void> _edit(int index) async {
    final variant = await showModalBottomSheet<ProductVariant>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => _VariantEditModalSheet(existing: _variants[index]),
    );
    if (variant == null || !mounted) return;
    setState(() => _variants[index] = variant);
    widget.onChanged(_variants);
  }

  void _remove(int index) {
    setState(() => _variants.removeAt(index));
    widget.onChanged(_variants);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Row(
          children: [
            const Expanded(
              child: Text(
                'أحجام / أنواع لنفس المنتج (كبير، صغير، 5 كيلو...)',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1A1A2E),
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add_circle_rounded,
                  size: 17, color: Colors.deepPurple),
              label: const Text(
                'إضافة حجم',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: Colors.deepPurple,
                ),
              ),
            ),
          ],
        ),
        if (_variants.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.deepPurple.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: Colors.deepPurple.withValues(alpha: 0.15)),
            ),
            child: const Text(
              'لا توجد أحجام متعددة — يمكنك إضافة (كبير / صغير / 5 كيلو) بمخزون وكميات مستقلة لكل منها بالسحب داخل نفس المنتج.',
              style: TextStyle(
                  fontFamily: 'Cairo', fontSize: 11.5, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),
        ..._variants.asMap().entries.map((e) {
          final i = e.key;
          final v = e.value;
          final double currentStock = v.stock;
          final stockColor = currentStock > 10
              ? Colors.green
              : currentStock > 0
                  ? Colors.orange
                  : Colors.red;

          return Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: Colors.deepPurple.withValues(alpha: 0.25)),
              boxShadow: [
                BoxShadow(
                  color: Colors.deepPurple.withValues(alpha: 0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                if (v.imageUrl != null && v.imageUrl!.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      cacheManager: ImagePrecacheService.instance.cacheManager,
                      imageUrl: v.imageUrl!,
                      width: 42,
                      height: 42,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => const Icon(
                        Icons.inventory_2_outlined,
                        size: 24,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.deepPurple.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              v.label,
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: Colors.deepPurple,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${v.price.toStringAsFixed(0)} ر.ي',
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'مخزون: ${v.stock % 1 == 0 ? v.stock.toInt() : v.stock.toStringAsFixed(2)} كرتون'
                        '${v.units.isNotEmpty ? " • ${v.units.length} كميات فرعية" : ""}',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: stockColor,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _edit(i),
                  icon: const Icon(Icons.edit_rounded,
                      size: 18, color: Colors.deepPurple),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: () => _remove(i),
                  icon: const Icon(Icons.delete_outline_rounded,
                      size: 18, color: Colors.red),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════
// نافذة إضافة / تعديل الحجم المستقل (كبير، صغير، 5 كيلو...)
// ══════════════════════════════════════════════════════════
class _VariantEditModalSheet extends StatefulWidget {
  final ProductVariant? existing;
  const _VariantEditModalSheet({this.existing});

  @override
  State<_VariantEditModalSheet> createState() => _VariantEditModalSheetState();
}

class _VariantEditModalSheetState extends State<_VariantEditModalSheet> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _labelCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _costCtrl;
  late final TextEditingController _stockCtrl;
  late final TextEditingController _itemsCtrl;
  late final TextEditingController _sizeCtrl;
  late final TextEditingController _barcodeCtrl;
  late final TextEditingController _prodDateCtrl;
  late final TextEditingController _expDateCtrl;

  XFile? _selectedImage;
  Uint8List? _selectedImageBytes;
  bool _removeOldImage = false;
  bool _saving = false;
  late List<ProductUnit> _subUnits;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    _labelCtrl = TextEditingController(text: ex?.label ?? '');
    _priceCtrl = TextEditingController(
        text: ex != null ? ex.price.toStringAsFixed(0) : '');
    _costCtrl = TextEditingController(
        text: ex?.costPrice != null ? ex!.costPrice!.toStringAsFixed(0) : '');
    _stockCtrl = TextEditingController(
        text: ex != null
            ? (ex.stock % 1 == 0
                ? ex.stock.toInt().toString()
                : ex.stock.toString())
            : '0');
    _itemsCtrl =
        TextEditingController(text: ex != null ? '${ex.itemsPerCarton}' : '1');
    _sizeCtrl = TextEditingController(
        text: ex?.sizeText ?? (ex?.sizeMl != null ? '${ex!.sizeMl} مل' : ''));
    _barcodeCtrl = TextEditingController(text: ex?.barcode ?? '');
    _prodDateCtrl = TextEditingController(
        text: ex?.productionDate != null ? _fmtDate(ex!.productionDate!) : '');
    _expDateCtrl = TextEditingController(
        text: ex?.expiryDate != null ? _fmtDate(ex!.expiryDate!) : '');
    _subUnits = ex != null ? List<ProductUnit>.from(ex.units) : [];
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _priceCtrl.dispose();
    _costCtrl.dispose();
    _stockCtrl.dispose();
    _itemsCtrl.dispose();
    _sizeCtrl.dispose();
    _barcodeCtrl.dispose();
    _prodDateCtrl.dispose();
    _expDateCtrl.dispose();
    super.dispose();
  }

  Future<void> _chooseImage() async {
    try {
      final result = await pickCatalogImage();
      if (result.$1 == null || result.$2 == null) return;
      setState(() {
        _selectedImage = result.$1;
        _selectedImageBytes = result.$2;
        _removeOldImage = false;
      });
    } catch (_) {}
  }

  Future<void> _saveVariant() async {
    if (!_formKey.currentState!.validate()) return;

    final parsedPrice = double.tryParse(
            ArabicNormalizer.normalizeDigits(_priceCtrl.text).trim()) ??
        0;
    final parsedStock = double.tryParse(
            ArabicNormalizer.normalizeDigits(_stockCtrl.text).trim()) ??
        0.0;
    final parsedItems = int.tryParse(
            ArabicNormalizer.normalizeDigits(_itemsCtrl.text).trim()) ??
        1;
    final costText = ArabicNormalizer.normalizeDigits(_costCtrl.text).trim();
    final parsedCost = costText.isNotEmpty ? double.tryParse(costText) : null;

    if (parsedPrice < 0 || parsedStock < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تأكد من صحة السعر والمخزون للحجم',
              style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_prodDateCtrl.text.trim().isNotEmpty &&
        DateTime.tryParse(_prodDateCtrl.text.trim()) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('صيغة تاريخ الإنتاج غير صحيحة (مثال: 2026-05-15)',
              style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_expDateCtrl.text.trim().isNotEmpty &&
        DateTime.tryParse(_expDateCtrl.text.trim()) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('صيغة تاريخ الانتهاء غير صحيحة (مثال: 2027-05-15)',
              style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      String? imageUrl = widget.existing?.imageUrl;
      if (_removeOldImage) imageUrl = null;
      if (_selectedImage != null) {
        imageUrl = await uploadCatalogImage(_selectedImage!);
      }

      final customSize = _sizeCtrl.text.trim();
      final numericSize = parseSizeMlFromText(customSize);
      final prodDate = _prodDateCtrl.text.trim().isNotEmpty
          ? DateTime.tryParse(_prodDateCtrl.text.trim())
          : null;
      final expDate = _expDateCtrl.text.trim().isNotEmpty
          ? DateTime.tryParse(_expDateCtrl.text.trim())
          : null;

      final variant = ProductVariant(
        id: widget.existing?.id ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        label: _labelCtrl.text.trim(),
        price: parsedPrice,
        costPrice: parsedCost,
        stock: parsedStock,
        itemsPerCarton: parsedItems.clamp(1, 9999),
        sizeText: customSize.isNotEmpty ? customSize : null,
        sizeMl: numericSize,
        imageUrl: imageUrl,
        barcode: _barcodeCtrl.text.trim().isNotEmpty
            ? _barcodeCtrl.text.trim()
            : null,
        productionDate: prodDate,
        expiryDate: expDate,
        units: _subUnits,
      );

      if (mounted) Navigator.pop(context, variant);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('فشل حفظ الحجم: $e',
                style: const TextStyle(fontFamily: 'Cairo')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _imagePreview() {
    if (_selectedImageBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(_selectedImageBytes!,
            width: 58, height: 58, fit: BoxFit.cover),
      );
    }
    if (!_removeOldImage &&
        widget.existing?.imageUrl != null &&
        widget.existing!.imageUrl!.trim().isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CachedNetworkImage(
          cacheManager: ImagePrecacheService.instance.cacheManager,
          imageUrl: widget.existing!.imageUrl!,
          width: 58,
          height: 58,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => const Icon(
            Icons.inventory_2_outlined,
            size: 24,
            color: Colors.grey,
          ),
        ),
      );
    }
    return const Icon(
      Icons.add_photo_alternate_rounded,
      color: Colors.deepPurple,
      size: 26,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.94),
        decoration: const BoxDecoration(
          color: Color(0xFFF8FAFB),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(10)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, color: Colors.deepPurple),
                  const SizedBox(width: 8),
                  Text(
                    widget.existing == null
                        ? 'إضافة حجم / نوع جديد'
                        : 'تعديل الحجم (${widget.existing!.label})',
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // اختيار صورة الحجم
                      GestureDetector(
                        onTap: _saving ? null : _chooseImage,
                        child: Container(
                          height: 74,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE6E9ED)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 58,
                                height: 58,
                                decoration: BoxDecoration(
                                  color:
                                      Colors.deepPurple.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: _imagePreview(),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'صورة خاصة بهذا الحجم (اختياري)',
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // اسم الحجم
                      TextFormField(
                        controller: _labelCtrl,
                        textDirection: TextDirection.rtl,
                        style: const TextStyle(
                            fontFamily: 'Cairo', fontWeight: FontWeight.bold),
                        decoration: _dec(
                            'اسم الحجم (مثال: كبير ، صغير ، 5 كجم ، عائلي) *'),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'اسم الحجم مطلوب'
                            : null,
                      ),
                      const SizedBox(height: 8),

                      // السعر وسعر الشراء
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _priceCtrl,
                              textDirection: TextDirection.rtl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              inputFormatters: const [
                                ArabicDigitsInputFormatter()
                              ],
                              decoration: _dec('سعر البيع ر.ي *'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontSize: 13),
                              validator: (v) {
                                final p = double.tryParse(
                                    ArabicNormalizer.normalizeDigits(v ?? '')
                                        .trim());
                                return (p == null || p < 0)
                                    ? 'أدخل سعر بيع صحيحاً'
                                    : null;
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: _costCtrl,
                              textDirection: TextDirection.rtl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              inputFormatters: const [
                                ArabicDigitsInputFormatter()
                              ],
                              decoration: _dec('سعر الشراء 🔒'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // المخزون وحبات الكرتون
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _stockCtrl,
                              textDirection: TextDirection.rtl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              inputFormatters: const [
                                ArabicDigitsInputFormatter()
                              ],
                              decoration: _dec('مخزون الحجم (كرتون) *'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: _itemsCtrl,
                              textDirection: TextDirection.rtl,
                              keyboardType: TextInputType.number,
                              inputFormatters: const [
                                ArabicDigitsInputFormatter(allowDecimal: false)
                              ],
                              decoration: _dec('حبات بالكرتون لهذا الحجم'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // الحجم والباركود
                      TextFormField(
                        controller: _sizeCtrl,
                        textDirection: TextDirection.rtl,
                        decoration:
                            _dec('وصف الحجم أو الوزن (مثال: 1.5 لتر ، 250 مل)'),
                        style:
                            const TextStyle(fontFamily: 'Cairo', fontSize: 13),
                      ),
                      const SizedBox(height: 8),

                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _barcodeCtrl,
                              textDirection: TextDirection.ltr,
                              decoration: _dec('باركود كرتون هذا الحجم'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () async {
                              final scanned =
                                  await BarcodeScannerScreen.scan(context);
                              if (scanned != null && scanned.isNotEmpty) {
                                setState(() => _barcodeCtrl.text = scanned);
                              }
                            },
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Colors.deepPurple,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.qr_code_scanner_rounded,
                                  color: Colors.white, size: 22),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // تواريخ الإنتاج والانتهاء
                      Row(
                        children: [
                          Expanded(
                            child: _UnitManualDateField(
                              ctrl: _prodDateCtrl,
                              hint: 'إنتاج: 2026-05-15',
                              icon: Icons.calendar_today_rounded,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _UnitManualDateField(
                              ctrl: _expDateCtrl,
                              hint: 'انتهاء: 2027-05-15',
                              icon: Icons.event_busy_rounded,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // الوحدات الفرعية الخاصة بهذا الحجم (نص كرتون، حبة...)
                      ProductUnitsEditor(
                        productName: _labelCtrl.text.trim().isNotEmpty
                            ? 'كميات حجم (${_labelCtrl.text.trim()})'
                            : 'كميات هذا الحجم',
                        initialUnits: _subUnits,
                        onChanged: (updatedUnits) {
                          setState(() => _subUnits = updatedUnits);
                        },
                      ),
                      const SizedBox(height: 20),

                      SizedBox(
                        height: 50,
                        child: ElevatedButton.icon(
                          onPressed: _saving ? null : _saveVariant,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2),
                                )
                              : const Icon(Icons.check_circle_rounded,
                                  size: 19),
                          label: Text(
                            _saving ? 'جاري الحفظ...' : 'اعتماد هذا الحجم',
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepPurple,
                            foregroundColor: Colors.white,
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
            ),
          ],
        ),
      ),
    );
  }
}
