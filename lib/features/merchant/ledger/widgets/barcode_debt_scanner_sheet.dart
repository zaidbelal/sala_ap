import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_adaptive_colors.dart';
import '../../../../core/services/local_storage.dart';
import '../../products/services/products_service.dart';
import '../models/ledger_item.dart';
import '../services/ledger_service.dart';

class BarcodeDebtScannerSheet extends StatefulWidget {
  final Function(LedgerItem item) onItemAdded;

  const BarcodeDebtScannerSheet({
    super.key,
    required this.onItemAdded,
  });

  static Future<void> show(BuildContext context, {required Function(LedgerItem item) onItemAdded}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BarcodeDebtScannerSheet(onItemAdded: onItemAdded),
    );
  }

  @override
  State<BarcodeDebtScannerSheet> createState() => _BarcodeDebtScannerSheetState();
}

class _BarcodeDebtScannerSheetState extends State<BarcodeDebtScannerSheet> {
  late final MobileScannerController _scannerController;
  bool _isTorchOn = false;
  bool _isProcessing = false;

  // حالة المنتج المفحوص حالياً
  ProductModel? _matchedProduct;
  String? _scannedBarcode;
  double _unitPrice = 0.0;
  double _quantity = 1.0;
  bool _isFirstTimePrice = true;
  bool _saveForFuture = true;
  final _priceController = TextEditingController();
  final _customNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      torchEnabled: false,
    );
  }

  @override
  void dispose() {
    _scannerController.dispose();
    _priceController.dispose();
    _customNameController.dispose();
    super.dispose();
  }

  Future<void> _handleBarcodeDetected(BarcodeCapture capture) async {
    if (_isProcessing || _matchedProduct != null) return;
    final barcode = capture.barcodes.firstOrNull?.rawValue?.trim();
    if (barcode == null || barcode.isEmpty) return;

    setState(() => _isProcessing = true);
    HapticFeedback.mediumImpact();

    final merchantId = AppStorage.userId ?? '';
    final product = LedgerService.findProductByBarcode(barcode);

    if (product != null) {
      // فحص هل سُجل سعر حبة مسبقاً لهذا التاجر
      final storedPrice = await LedgerService.getStoredRetailPrice(merchantId, product.id);

      if (storedPrice != null && storedPrice > 0) {
        _isFirstTimePrice = false;
        _unitPrice = storedPrice;
      } else {
        _isFirstTimePrice = true;
        _unitPrice = LedgerService.calculateDefaultPiecePrice(product);
      }

      _matchedProduct = product;
      _scannedBarcode = barcode;
      _priceController.text = _unitPrice.toStringAsFixed(0);
      _quantity = 1.0;
    } else {
      // باركود غير موجود في الكتالوج (صنف خارجي)
      _matchedProduct = null;
      _scannedBarcode = barcode;
      _isFirstTimePrice = true;
      _unitPrice = 0.0;
      _priceController.text = '';
      _customNameController.text = '';
      _quantity = 1.0;
    }

    if (mounted) {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _confirmAndAddItem() async {
    final merchantId = AppStorage.userId ?? '';
    final parsedPrice = double.tryParse(_priceController.text.trim()) ?? _unitPrice;

    if (parsedPrice <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('يرجى تحديد سعر بيع الحبة أولاً', style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final name = _matchedProduct?.name ?? _customNameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('يرجى كتابة اسم الصنف', style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // حفظ السعر المستقبلي إذا اختار التاجر ذلك
    if (_saveForFuture && _matchedProduct != null && merchantId.isNotEmpty) {
      await LedgerService.saveRetailPrice(
        merchantId: merchantId,
        productId: _matchedProduct!.id,
        price: parsedPrice,
      );
    }

    final item = LedgerItem(
      productId: _matchedProduct?.id ?? 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      quantity: _quantity,
      unitLabel: 'حبة',
      unitPrice: parsedPrice,
      subtotal: parsedPrice * _quantity,
      cartonCapacity: _matchedProduct?.itemsPerCarton ?? 1,
      barcode: _scannedBarcode,
    );

    widget.onItemAdded(item);
    HapticFeedback.lightImpact();

    // إعادة الضبط لمسح صنف آخر فورا
    setState(() {
      _matchedProduct = null;
      _scannedBarcode = null;
      _priceController.clear();
      _customNameController.clear();
      _quantity = 1.0;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✅ أُضيف ($name) بسعر ${parsedPrice.toStringAsFixed(0)} للحبة',
            style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: const Color(0xFF27AE60),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _resetCurrentScan() {
    setState(() {
      _matchedProduct = null;
      _scannedBarcode = null;
      _priceController.clear();
      _customNameController.clear();
      _quantity = 1.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: context.bgCard,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // مقبض السحب
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // العنوان وزر الإغلاق
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.qr_code_scanner_rounded, color: AppColors.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'مسح باركود الصنف لدين الدفتر',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // محتوى الشاشة: الكاميرا أو بطاقة الصنف المفحوص
          Expanded(
            child: _matchedProduct != null || _scannedBarcode != null
                ? _buildScannedProductCard(context)
                : _buildCameraScanner(context),
          ),

          if (bottomInset > 0) SizedBox(height: bottomInset),
        ],
      ),
    );
  }

  Widget _buildCameraScanner(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        MobileScanner(
          controller: _scannerController,
          onDetect: _handleBarcodeDetected,
        ),

        // إطار الاستهداف
        Container(
          width: 250,
          height: 160,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.primary, width: 2.5),
            borderRadius: BorderRadius.circular(16),
            color: Colors.black.withValues(alpha: 0.1),
          ),
        ),

        // زر الفلاش
        Positioned(
          top: 16,
          right: 16,
          child: CircleAvatar(
            backgroundColor: Colors.black.withValues(alpha: 0.6),
            child: IconButton(
              icon: Icon(
                _isTorchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                color: Colors.white,
              ),
              onPressed: () {
                _scannerController.toggleTorch();
                setState(() => _isTorchOn = !_isTorchOn);
              },
            ),
          ),
        ),

        // نص إرشادي في الأسفل
        Positioned(
          bottom: 24,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              'وجّه الكاميرا نحو باركود الصنف (الحبة أو الكرتون)',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: Colors.white,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildScannedProductCard(BuildContext context) {
    final isCatalog = _matchedProduct != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // شارة حالة السعر (أول مرة أو مسجل سابقاً)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _isFirstTimePrice
                  ? const Color(0xFFF39C12).withValues(alpha: 0.12)
                  : const Color(0xFF2ECC71).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _isFirstTimePrice ? const Color(0xFFF39C12) : const Color(0xFF2ECC71),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _isFirstTimePrice ? Icons.new_releases_rounded : Icons.verified_rounded,
                  color: _isFirstTimePrice ? const Color(0xFFE67E22) : const Color(0xFF27AE60),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isFirstTimePrice
                            ? 'صنف جديد: حدد سعر بيع الحبة لأول مرة'
                            : 'سعر الحبة المحفوظ لمتجرك جاهز',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: _isFirstTimePrice ? const Color(0xFFD35400) : const Color(0xFF1E8449),
                        ),
                      ),
                      Text(
                        _isFirstTimePrice
                            ? 'سيتم حفظ هذا السعر تلقائياً لمرات المسح القادمة'
                            : 'يمكنك تعديل السعر إذا أردت تحديثه',
                        style: const TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // تفاصيل الصنف
          if (isCatalog) ...[
            Text(
              _matchedProduct!.name,
              style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 17),
            ),
            const SizedBox(height: 4),
            Text(
              'سعر الجملة للكرتون: ${_matchedProduct!.price.toStringAsFixed(0)} ريال (${_matchedProduct!.itemsPerCarton ?? 1} حبة)',
              style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.grey[600]),
            ),
          ] else ...[
            TextField(
              controller: _customNameController,
              decoration: InputDecoration(
                labelText: 'اسم الصنف *',
                labelStyle: const TextStyle(fontFamily: 'Cairo'),
                hintText: 'مثال: عصير مانجو، بسكويت...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],

          const SizedBox(height: 16),

          // تحديد سعر بيع الحبة
          TextField(
            controller: _priceController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}'))],
            decoration: InputDecoration(
              labelText: 'سعر بيع الحبة بالتجزئة (ريال) *',
              labelStyle: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
              prefixIcon: const Icon(Icons.sell_rounded, color: AppColors.primary),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.primary, width: 2),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // اختيار الكمية (+ / -)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'الكمية (بالحبة):',
                style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 14),
              ),
              Row(
                children: [
                  IconButton(
                    onPressed: _quantity > 1 ? () => setState(() => _quantity -= 1) : null,
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    color: Colors.red,
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _quantity.toStringAsFixed(0),
                      style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _quantity += 1),
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    color: const Color(0xFF27AE60),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 10),

          // حفظ السعر للمستقبل
          CheckboxListTile(
            value: _saveForFuture,
            onChanged: (val) => setState(() => _saveForFuture = val ?? true),
            title: const Text(
              'حفظ هذا السعر كـ سعر افتراضي عند مسح الباركود مستقبلاً',
              style: TextStyle(fontFamily: 'Cairo', fontSize: 12),
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeColor: AppColors.primary,
          ),

          const SizedBox(height: 16),

          // أزرار الحفظ أو إعادة المسح
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _resetCurrentScan,
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('مسح غيره', style: TextStyle(fontFamily: 'Cairo')),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: _confirmAndAddItem,
                  icon: const Icon(Icons.add_shopping_cart_rounded),
                  label: const Text(
                    'إضافة إلى الدين',
                    style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF27AE60),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
