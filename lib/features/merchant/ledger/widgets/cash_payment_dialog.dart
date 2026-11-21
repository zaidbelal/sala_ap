import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/constants/app_adaptive_colors.dart';
import '../models/ledger_customer.dart';
import '../services/ledger_service.dart';

class CashPaymentDialog extends StatefulWidget {
  final LedgerCustomer customer;
  final VoidCallback? onPaymentSuccess;

  const CashPaymentDialog({
    super.key,
    required this.customer,
    this.onPaymentSuccess,
  });

  static Future<void> show(
    BuildContext context, {
    required LedgerCustomer customer,
    VoidCallback? onPaymentSuccess,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => CashPaymentDialog(
        customer: customer,
        onPaymentSuccess: onPaymentSuccess,
      ),
    );
  }

  @override
  State<CashPaymentDialog> createState() => _CashPaymentDialogState();
}

class _CashPaymentDialogState extends State<CashPaymentDialog> {
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _setAmount(double amount) {
    if (amount <= 0) return;
    _amountController.text = amount.toStringAsFixed(0);
    setState(() => _errorMessage = null);
  }

  Future<void> _submitPayment() async {
    final text = _amountController.text.trim();
    final amount = double.tryParse(text);

    if (amount == null || amount <= 0) {
      setState(() => _errorMessage = 'يرجى إدخال مبلغ صحيح أكبر من الصفر');
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
        type: 'payment',
        amount: amount,
        notes: _notesController.text.trim().isNotEmpty
            ? _notesController.text.trim()
            : 'سداد نقدي (كاش)',
      );

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ تم تسجيل سداد مبلغ ${amount.toStringAsFixed(0)} ريال بنجاح',
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
            backgroundColor: const Color(0xFF27AE60),
            behavior: SnackBarBehavior.floating,
          ),
        );
        widget.onPaymentSuccess?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'حدث خطأ أثناء تسجيل السداد: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final curBal = widget.customer.currentBalance;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: context.bgCard,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2ECC71).withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.payments_rounded,
                      color: Color(0xFF27AE60),
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'سداد دفعة نقدية (كاش)',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          'العميل: ${widget.customer.name}',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // بطاقة الرصيد الحالي
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'إجمالي الدين المستحق:',
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 13),
                    ),
                    Text(
                      '${curBal.toStringAsFixed(0)} ريال',
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Color(0xFFE74C3C),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // أزرار الاختيار السريع
              if (curBal > 0) ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isLoading ? null : () => _setAmount(curBal),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF27AE60)),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text(
                          'سداد كامل المبلغ',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF27AE60),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isLoading ? null : () => _setAmount((curBal / 2).roundToDouble()),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Colors.grey[400]!),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text(
                          'سداد النصف (50%)',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],

              // حقل إدخال المبلغ
              TextField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}'))],
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'المبلغ المدفوع (ريال) *',
                  labelStyle: const TextStyle(fontFamily: 'Cairo'),
                  prefixIcon: const Icon(Icons.money_rounded, color: Color(0xFF27AE60)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF27AE60), width: 2),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // حقل الملاحظات
              TextField(
                controller: _notesController,
                decoration: InputDecoration(
                  labelText: 'ملاحظات السداد (اختياري)',
                  labelStyle: const TextStyle(fontFamily: 'Cairo'),
                  hintText: 'مثال: حوالة، نقداً باليد، دفعة جزئية...',
                  hintStyle: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.grey[400]),
                  prefixIcon: const Icon(Icons.notes_rounded, color: Colors.grey),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),

              if (_errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  _errorMessage!,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],

              const SizedBox(height: 20),

              // أزرار التحكم
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _isLoading ? null : () => Navigator.pop(context),
                      child: const Text(
                        'إلغاء',
                        style: TextStyle(fontFamily: 'Cairo', color: Colors.grey),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _submitPayment,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF27AE60),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        elevation: 0,
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text(
                              'تأكيد السداد النقدي',
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
