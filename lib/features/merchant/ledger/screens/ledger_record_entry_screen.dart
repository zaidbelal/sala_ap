import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_adaptive_colors.dart';
import '../models/ledger_customer.dart';
import '../models/ledger_item.dart';
import '../services/ledger_service.dart';
import '../widgets/barcode_debt_scanner_sheet.dart';
import '../widgets/credit_limit_indicator.dart';

class LedgerRecordEntryScreen extends StatefulWidget {
  final LedgerCustomer customer;
  final String initialType; // 'debt' or 'payment'

  const LedgerRecordEntryScreen({
    super.key,
    required this.customer,
    this.initialType = 'debt',
  });

  @override
  State<LedgerRecordEntryScreen> createState() => _LedgerRecordEntryScreenState();
}

class _LedgerRecordEntryScreenState extends State<LedgerRecordEntryScreen> {
  late String _type; // 'debt' or 'payment'
  final List<LedgerItem> _items = [];
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
  }

  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  double get _totalAmount {
    if (_type == 'payment') {
      return double.tryParse(_amountController.text.trim()) ?? 0.0;
    }
    return _items.fold(0.0, (sum, item) => sum + item.subtotal);
  }

  void _openBarcodeScanner() {
    BarcodeDebtScannerSheet.show(
      context,
      onItemAdded: (item) {
        setState(() {
          _items.add(item);
          _errorMessage = null;
        });
      },
    );
  }

  void _showAddManualItemDialog() {
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة صنف يدوي', style: TextStyle(fontFamily: 'Cairo')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'اسم الصنف أو البيان *',
                labelStyle: TextStyle(fontFamily: 'Cairo'),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: priceCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'سعر الحبة (ريال) *',
                labelStyle: TextStyle(fontFamily: 'Cairo'),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: qtyCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'الكمية *',
                labelStyle: TextStyle(fontFamily: 'Cairo'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء', style: TextStyle(fontFamily: 'Cairo')),
          ),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final price = double.tryParse(priceCtrl.text.trim()) ?? 0.0;
              final qty = double.tryParse(qtyCtrl.text.trim()) ?? 1.0;
              if (name.isEmpty || price <= 0 || qty <= 0) return;

              setState(() {
                _items.add(
                  LedgerItem(
                    productId: 'manual_${DateTime.now().millisecondsSinceEpoch}',
                    name: name,
                    quantity: qty,
                    unitLabel: 'حبة',
                    unitPrice: price,
                    subtotal: price * qty,
                  ),
                );
              });
              Navigator.pop(ctx);
            },
            child: const Text('إضافة', style: TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
  }

  Future<void> _submitTransaction() async {
    final total = _totalAmount;
    if (total <= 0) {
      setState(() => _errorMessage = 'يرجى إضافة أصناف أو تحديد مبلغ صحيح أكبر من الصفر');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      HapticFeedback.mediumImpact();
      await LedgerService.recordTransaction(
        customerId: widget.customer.id,
        type: _type,
        amount: total,
        notes: _notesController.text.trim(),
        items: _type == 'debt' ? _items : null,
      );

      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _type == 'debt'
                  ? '✅ تم تسجيل دين بمبلغ ${total.toStringAsFixed(0)} ريال'
                  : '✅ تم تسجيل سداد نقدي بمبلغ ${total.toStringAsFixed(0)} ريال',
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
            backgroundColor: const Color(0xFF27AE60),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'حدث خطأ أثناء حفظ القيد: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _totalAmount;
    final projectedBalance = _type == 'debt'
        ? widget.customer.currentBalance + total
        : widget.customer.currentBalance - total;
    final isProjectedOverLimit = widget.customer.creditLimit > 0 &&
        _type == 'debt' &&
        projectedBalance > widget.customer.creditLimit;

    return Scaffold(
      backgroundColor: context.bgPage,
      appBar: AppBar(
        title: Text(
          _type == 'debt' ? 'تسجيل دين مشتريات' : 'تسجيل سداد نقدي',
          style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
        ),
        backgroundColor: context.bgHeader,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // بطاقة بيانات العميل
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.bgCard,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        widget.customer.name,
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        'الرصيد الحالي: ${widget.customer.currentBalance.toStringAsFixed(0)} ريال',
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Color(0xFFE74C3C),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  CreditLimitIndicator(customer: widget.customer),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // التبديل بين دين وسداد
            Container(
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _type = 'debt'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _type == 'debt' ? context.bgCard : Colors.transparent,
                          borderRadius: BorderRadius.circular(9),
                          boxShadow: _type == 'debt'
                              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4)]
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'دين مشتريات (+)',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight: FontWeight.bold,
                            color: _type == 'debt' ? const Color(0xFFE74C3C) : Colors.grey,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _type = 'payment'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _type == 'payment' ? context.bgCard : Colors.transparent,
                          borderRadius: BorderRadius.circular(9),
                          boxShadow: _type == 'payment'
                              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4)]
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'سداد نقدي (-)',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight: FontWeight.bold,
                            color: _type == 'payment' ? const Color(0xFF27AE60) : Colors.grey,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // محتوى تسجيل الدين (الأصناف والباركود)
            if (_type == 'debt') ...[
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _openBarcodeScanner,
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      label: const Text(
                        'مسح بالباركود',
                        style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _showAddManualItemDialog,
                      icon: const Icon(Icons.edit_note_rounded),
                      label: const Text(
                        'إضافة يدوية',
                        style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // قائمة الأصناف المضافة
              if (_items.isEmpty)
                Container(
                  padding: const EdgeInsets.all(28),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: context.bgCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.inventory_2_outlined, size: 40, color: Colors.grey[400]),
                      const SizedBox(height: 8),
                      const Text(
                        'لم تتم إضافة أصناف بعد\nامسح الباركود أو أضف يدوياً لإدراج المنتجات بالحبة',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontFamily: 'Cairo', color: Colors.grey, fontSize: 13),
                      ),
                    ],
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.bgCard,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.withValues(alpha: 0.15)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(
                                  '${item.quantity.toStringAsFixed(0)} ${item.unitLabel} × ${item.unitPrice.toStringAsFixed(0)} ريال',
                                  style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.grey[600]),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '${item.subtotal.toStringAsFixed(0)} ريال',
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: Color(0xFFE74C3C),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                            onPressed: () => setState(() => _items.removeAt(index)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ] else ...[
              // إدخال مبلغ السداد
              TextField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'مبلغ السداد النقدي (ريال) *',
                  labelStyle: const TextStyle(fontFamily: 'Cairo'),
                  prefixIcon: const Icon(Icons.money_rounded, color: Color(0xFF27AE60)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],

            const SizedBox(height: 16),

            // ملاحظات القيد
            TextField(
              controller: _notesController,
              decoration: InputDecoration(
                labelText: 'ملاحظات القيد (اختياري)',
                labelStyle: const TextStyle(fontFamily: 'Cairo'),
                hintText: 'اكتب أي ملاحظة لتوثيقها في كشف الحساب...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),

            const SizedBox(height: 16),

            // تنبيه سقف الدين إذا تم تجاوزه
            if (isProjectedOverLimit)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFFE74C3C).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFE74C3C)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Color(0xFFC0392B), size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '⚠️ تنبيه: سيصبح إجمالي دين العميل (${projectedBalance.toStringAsFixed(0)} ريال)، متجاوزاً السقف المسموح (${widget.customer.creditLimit.toStringAsFixed(0)} ريال).',
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF922B21),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // الإجمالي وزر الحفظ
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.bgCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'إجمالي القيد:',
                        style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        '${total.toStringAsFixed(0)} ريال',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                          color: _type == 'debt' ? const Color(0xFFE74C3C) : const Color(0xFF27AE60),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'الرصيد بعد هذه العملية:',
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: Colors.grey),
                      ),
                      Text(
                        '${projectedBalance.toStringAsFixed(0)} ريال',
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],

            const SizedBox(height: 20),

            ElevatedButton(
              onPressed: _isLoading ? null : _submitTransaction,
              style: ElevatedButton.styleFrom(
                backgroundColor: _type == 'debt' ? const Color(0xFFE74C3C) : const Color(0xFF27AE60),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                    )
                  : Text(
                      _type == 'debt' ? 'ترحيل وتأكيد الدين' : 'تأكيد السداد النقدي',
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
