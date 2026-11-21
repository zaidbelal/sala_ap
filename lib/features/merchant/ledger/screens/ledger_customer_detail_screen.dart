import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_adaptive_colors.dart';
import '../../../../core/services/local_storage.dart';
import '../models/ledger_customer.dart';
import '../models/ledger_entry.dart';
import '../services/ledger_pdf_service.dart';
import '../services/ledger_service.dart';
import '../widgets/cash_payment_dialog.dart';
import '../widgets/credit_limit_indicator.dart';
import 'ledger_record_entry_screen.dart';

class LedgerCustomerDetailScreen extends StatefulWidget {
  final LedgerCustomer customer;

  const LedgerCustomerDetailScreen({
    super.key,
    required this.customer,
  });

  @override
  State<LedgerCustomerDetailScreen> createState() => _LedgerCustomerDetailScreenState();
}

class _LedgerCustomerDetailScreenState extends State<LedgerCustomerDetailScreen> {
  late LedgerCustomer _customer;
  bool _isLoadingPdf = false;

  @override
  void initState() {
    super.initState();
    _customer = widget.customer;
  }

  void _openRecordEntry({required String type}) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => LedgerRecordEntryScreen(
          customer: _customer,
          initialType: type,
        ),
      ),
    );
    if (result == true) {
      // إعادة المطابقة السريعة للرصيد
      _reconcileBalance();
    }
  }

  void _openCashPayment() {
    CashPaymentDialog.show(
      context,
      customer: _customer,
      onPaymentSuccess: _reconcileBalance,
    );
  }

  Future<void> _exportPdf(List<LedgerEntry> entries) async {
    setState(() => _isLoadingPdf = true);
    try {
      HapticFeedback.lightImpact();
      await LedgerPdfService.printOrShareStatement(
        customer: _customer,
        entries: entries,
        storeName: AppStorage.userName,
        storePhone: AppStorage.userPhone,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('حدث خطأ أثناء إصدار الـ PDF: $e', style: const TextStyle(fontFamily: 'Cairo')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingPdf = false);
    }
  }

  Future<void> _sendWhatsAppReminder() async {
    if (_customer.phone.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('العميل ليس لديه رقم هاتف مسجل', style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final storeName = AppStorage.userName ?? 'المتجر';
    final now = DateTime.now();
    final dateStr = LedgerPdfService.formatFullDateTime(now);

    final message = '''
السلام عليكم أخي ${_customer.name} 🌸
تحية طيبة من $storeName،

نود تذكيركم بكشف الحساب الآجل حتى $dateStr:
▪️ إجمالي المبلغ المستحق: ${_customer.currentBalance.toStringAsFixed(0)} ريال.

شاكرين لكم حسن تعاونكم وتفضلكم بالسداد.
''';

    final digitsOnly = _customer.phone.replaceAll(RegExp(r'[^\d]'), '');
    final uri = Uri.parse('https://wa.me/$digitsOnly?text=${Uri.encodeComponent(message)}');

    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw 'تعذر فتح تطبيق واتساب';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ في إرسال الواتساب: $e', style: const TextStyle(fontFamily: 'Cairo')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _reconcileBalance() async {
    try {
      final newBal = await LedgerService.reconcileCustomer(_customer.id);
      if (mounted) {
        setState(() {
          _customer = _customer.copyWith(currentBalance: newBal);
        });
      }
    } catch (_) {}
  }

  void _showEditCustomerDialog() {
    final nameCtrl = TextEditingController(text: _customer.name);
    final phoneCtrl = TextEditingController(text: _customer.phone);
    final limitCtrl = TextEditingController(
      text: _customer.creditLimit > 0 ? _customer.creditLimit.toStringAsFixed(0) : '',
    );
    final notesCtrl = TextEditingController(text: _customer.notes);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعديل بيانات العميل', style: TextStyle(fontFamily: 'Cairo')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'اسم العميل *',
                  labelStyle: TextStyle(fontFamily: 'Cairo'),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'رقم الهاتف',
                  labelStyle: TextStyle(fontFamily: 'Cairo'),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: limitCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'سقف الدين المحدد (ريال)',
                  labelStyle: TextStyle(fontFamily: 'Cairo'),
                  hintText: 'اتركه فارغاً إذا كان السقف مفتوحاً',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: notesCtrl,
                decoration: const InputDecoration(
                  labelText: 'ملاحظات إضافية',
                  labelStyle: TextStyle(fontFamily: 'Cairo'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء', style: TextStyle(fontFamily: 'Cairo')),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final limit = double.tryParse(limitCtrl.text.trim()) ?? 0.0;
              Navigator.pop(ctx);

              try {
                await LedgerService.saveCustomer(
                  customerId: _customer.id,
                  name: name,
                  phone: phoneCtrl.text.trim(),
                  creditLimit: limit,
                  notes: notesCtrl.text.trim(),
                );
                setState(() {
                  _customer = _customer.copyWith(
                    name: name,
                    phone: phoneCtrl.text.trim(),
                    creditLimit: limit,
                    notes: notesCtrl.text.trim(),
                  );
                });
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('فشل التعديل: $e', style: const TextStyle(fontFamily: 'Cairo')),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('حفظ', style: TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteCustomer() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف العميل من الدفتر', style: TextStyle(fontFamily: 'Cairo')),
        content: Text(
          'هل أنت متأكد من حذف العميل (${_customer.name})؟ سيتم أرشفة حسابه وتحديث ملخص الديون.',
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء', style: TextStyle(fontFamily: 'Cairo')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await LedgerService.deleteCustomer(_customer.id);
                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('تم حذف العميل بنجاح', style: TextStyle(fontFamily: 'Cairo')),
                      backgroundColor: Colors.black,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('فشل الحذف: $e', style: const TextStyle(fontFamily: 'Cairo')),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('تأكيد الحذف', style: TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _confirmVoidEntry(LedgerEntry entry) {
    if (entry.isVoided) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إلغاء القيد المالي', style: TextStyle(fontFamily: 'Cairo')),
        content: Text(
          'هل تريد إلغاء قيد (${entry.typeLabel}) بمبلغ ${entry.amount.toStringAsFixed(0)} ريال؟ سيتم عكس الرصيد فوراً وبشكل آمن.',
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('تراجع', style: TextStyle(fontFamily: 'Cairo')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await LedgerService.voidTransaction(
                  customerId: _customer.id,
                  entryId: entry.id,
                );
                _reconcileBalance();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('✅ تم إلغاء القيد وعكس الرصيد بنجاح', style: TextStyle(fontFamily: 'Cairo')),
                      backgroundColor: Colors.black,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('فشل إلغاء القيد: $e', style: const TextStyle(fontFamily: 'Cairo')),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('تأكيد الإلغاء', style: TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final merchantId = AppStorage.userId ?? '';

    return Scaffold(
      backgroundColor: context.bgPage,
      appBar: AppBar(
        title: Text(
          _customer.name,
          style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
        ),
        backgroundColor: context.bgHeader,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'تدقيق ومطابقة الرصيد',
            onPressed: _reconcileBalance,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (val) {
              if (val == 'edit') _showEditCustomerDialog();
              if (val == 'delete') _confirmDeleteCustomer();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_rounded, size: 20),
                    SizedBox(width: 8),
                    Text('تعديل البيانات والسقف', style: TextStyle(fontFamily: 'Cairo')),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, size: 20, color: Colors.red),
                    SizedBox(width: 8),
                    Text('حذف العميل', style: TextStyle(fontFamily: 'Cairo', color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: StreamBuilder<List<LedgerEntry>>(
        stream: LedgerService.streamCustomerEntries(merchantId, _customer.id),
        builder: (context, snapshot) {
          final entries = snapshot.data ?? [];

          return CustomScrollView(
            slivers: [
              // ══ بطاقة رأس العميل والرصيد ══
              SliverToBoxAdapter(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: context.bgCard,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
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
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'الرصيد المتبقي للدفع',
                                style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.grey),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${_customer.currentBalance.toStringAsFixed(0)} ريال',
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontWeight: FontWeight.bold,
                                  fontSize: 26,
                                  color: _customer.isOverLimit
                                      ? const Color(0xFFC0392B)
                                      : const Color(0xFFE74C3C),
                                ),
                              ),
                            ],
                          ),
                          if (_customer.phone.isNotEmpty)
                            IconButton.filledTonal(
                              icon: const Icon(Icons.phone_rounded, color: AppColors.primary),
                              onPressed: () {
                                final uri = Uri.parse('tel:${_customer.phone}');
                                launchUrl(uri);
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      CreditLimitIndicator(customer: _customer),
                    ],
                  ),
                ),
              ),

              // ══ أزرار العمليات الأربعة السريعة ══
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 2.3,
                    children: [
                      // 1. تسجيل دين بالباركود أو يدوي
                      _buildQuickActionCard(
                        icon: Icons.add_shopping_cart_rounded,
                        title: 'تسجيل دين (+)',
                        subtitle: 'باركود أو يدوي',
                        color: const Color(0xFFE74C3C),
                        onTap: () => _openRecordEntry(type: 'debt'),
                      ),
                      // 2. سداد دفعة نقدية
                      _buildQuickActionCard(
                        icon: Icons.payments_rounded,
                        title: 'سداد نقدي (-)',
                        subtitle: 'قبض كاش فوري',
                        color: const Color(0xFF27AE60),
                        onTap: _openCashPayment,
                      ),
                      // 3. تصدير كشف حساب PDF
                      _buildQuickActionCard(
                        icon: _isLoadingPdf ? Icons.hourglass_top_rounded : Icons.picture_as_pdf_rounded,
                        title: 'كشف حساب PDF',
                        subtitle: 'تاريخ ووقت 12 س',
                        color: const Color(0xFF2980B9),
                        onTap: _isLoadingPdf ? null : () => _exportPdf(entries),
                      ),
                      // 4. تذكير واتساب
                      _buildQuickActionCard(
                        icon: Icons.chat_rounded,
                        title: 'تذكير واتساب',
                        subtitle: 'رسالة سريعة',
                        color: const Color(0xFF16A085),
                        onTap: _sendWhatsAppReminder,
                      ),
                    ],
                  ),
                ),
              ),

              // ══ شريط عنوان سجل الحركات ══
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'سجل الحركات المالية:',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        '(${entries.length} حركة)',
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ),

              // ══ قائمة الحركات ══
              if (entries.isEmpty)
                SliverToBoxAdapter(
                  child: Container(
                    margin: const EdgeInsets.all(20),
                    padding: const EdgeInsets.all(30),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: context.bgCard,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.history_rounded, size: 40, color: Colors.grey[400]),
                        const SizedBox(height: 8),
                        const Text(
                          'لا توجد حركات مسجلة لهذا العميل بعد\nابدأ بتسجيل أول دين مشتريات أو سداد نقدي',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontFamily: 'Cairo', color: Colors.grey, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final entry = entries[index];
                      final dateStr = entry.createdAt != null
                          ? LedgerPdfService.formatFullDateTime(entry.createdAt!)
                          : '-';

                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: context.bgCard,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: entry.isVoided
                                ? Colors.grey.withValues(alpha: 0.2)
                                : (entry.isDebt
                                    ? const Color(0xFFE74C3C).withValues(alpha: 0.15)
                                    : const Color(0xFF27AE60).withValues(alpha: 0.15)),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      entry.isDebt ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                                      size: 18,
                                      color: entry.isVoided
                                          ? Colors.grey
                                          : (entry.isDebt ? const Color(0xFFE74C3C) : const Color(0xFF27AE60)),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      entry.typeLabel,
                                      style: TextStyle(
                                        fontFamily: 'Cairo',
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                        color: entry.isVoided ? Colors.grey : null,
                                        decoration: entry.isVoided ? TextDecoration.lineThrough : null,
                                      ),
                                    ),
                                    if (entry.isVoided) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.red.withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'ملغي',
                                          style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Colors.red),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                Text(
                                  '${entry.amount.toStringAsFixed(0)} ريال',
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                    color: entry.isVoided
                                        ? Colors.grey
                                        : (entry.isDebt ? const Color(0xFFE74C3C) : const Color(0xFF27AE60)),
                                    decoration: entry.isVoided ? TextDecoration.lineThrough : null,
                                  ),
                                ),
                              ],
                            ),

                            // تفاصيل الأصناف المشتراة
                            if (entry.items.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              ...entry.items.map(
                                (item) => Text(
                                  '• ${item.name} (${item.quantity.toStringAsFixed(0)} ${item.unitLabel} × ${item.unitPrice.toStringAsFixed(0)} ريال)',
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 11,
                                    color: entry.isVoided ? Colors.grey[400] : Colors.grey[700],
                                  ),
                                ),
                              ),
                            ],

                            if (entry.notes.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                'ملاحظة: ${entry.notes}',
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 11,
                                  color: Colors.grey[600],
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ],

                            const SizedBox(height: 8),
                            const Divider(height: 1),
                            const SizedBox(height: 6),

                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  dateStr,
                                  style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Colors.grey[500]),
                                ),
                                if (!entry.isVoided)
                                  InkWell(
                                    onTap: () => _confirmVoidEntry(entry),
                                    child: const Text(
                                      'إلغاء القيد',
                                      style: TextStyle(
                                        fontFamily: 'Cairo',
                                        fontSize: 11,
                                        color: Colors.red,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                    childCount: entries.length,
                  ),
                ),

              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildQuickActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: color,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
