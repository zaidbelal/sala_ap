import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_adaptive_colors.dart';
import '../../../../core/services/local_storage.dart';
import '../models/ledger_customer.dart';
import '../models/ledger_summary.dart';
import '../services/ledger_pdf_service.dart';
import '../services/ledger_service.dart';
import '../widgets/credit_limit_indicator.dart';
import 'ledger_customer_detail_screen.dart';

class LedgerHomeScreen extends StatefulWidget {
  const LedgerHomeScreen({super.key});

  @override
  State<LedgerHomeScreen> createState() => _LedgerHomeScreenState();
}

class _LedgerHomeScreenState extends State<LedgerHomeScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String _selectedFilter = 'all'; // 'all', 'with_debt', 'over_limit', 'zero_debt'

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showAddCustomerDialog() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final limitCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    bool isSaving = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.person_add_rounded, color: AppColors.primary),
              SizedBox(width: 8),
              Text('إضافة عميل جديد للدفتر', style: TextStyle(fontFamily: 'Cairo', fontSize: 16)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'اسم العميل *',
                    labelStyle: const TextStyle(fontFamily: 'Cairo'),
                    prefixIcon: const Icon(Icons.person_outline_rounded),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'رقم الهاتف (اختياري)',
                    labelStyle: const TextStyle(fontFamily: 'Cairo'),
                    hintText: 'مثال: 771234567',
                    prefixIcon: const Icon(Icons.phone_outlined),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: limitCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'سقف الدين المحدد (ريال)',
                    labelStyle: const TextStyle(fontFamily: 'Cairo'),
                    hintText: 'اتركه فارغاً إذا كان السقف مفتوحاً',
                    prefixIcon: const Icon(Icons.security_rounded),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  decoration: InputDecoration(
                    labelText: 'ملاحظات (اختياري)',
                    labelStyle: const TextStyle(fontFamily: 'Cairo'),
                    prefixIcon: const Icon(Icons.notes_rounded),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSaving ? null : () => Navigator.pop(ctx),
              child: const Text('إلغاء', style: TextStyle(fontFamily: 'Cairo', color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: isSaving
                  ? null
                  : () async {
                      final name = nameCtrl.text.trim();
                      if (name.isEmpty) return;
                      final limit = double.tryParse(limitCtrl.text.trim()) ?? 0.0;

                      setDialogState(() => isSaving = true);
                      try {
                        await LedgerService.saveCustomer(
                          name: name,
                          phone: phoneCtrl.text.trim(),
                          creditLimit: limit,
                          notes: notesCtrl.text.trim(),
                        );
                        if (context.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('✅ تمت إضافة العميل ($name) بنجاح',
                                  style: const TextStyle(fontFamily: 'Cairo')),
                              backgroundColor: const Color(0xFF27AE60),
                            ),
                          );
                        }
                      } catch (e) {
                        setDialogState(() => isSaving = false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('فشلت إضافة العميل: $e', style: const TextStyle(fontFamily: 'Cairo')),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('إضافة العميل', style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final merchantId = AppStorage.userId ?? '';

    return Scaffold(
      backgroundColor: context.bgPage,
      appBar: AppBar(
        title: const Text(
          'دفتر الديون وسجل الحسابات',
          style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
        ),
        backgroundColor: context.bgHeader,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddCustomerDialog,
        backgroundColor: AppColors.primary,
        icon: const Icon(Icons.person_add_rounded, color: Colors.white),
        label: const Text(
          'إضافة عميل',
          style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
      body: StreamBuilder<LedgerSummary>(
        stream: LedgerService.streamSummary(merchantId),
        builder: (context, summarySnap) {
          final summary = summarySnap.data ?? LedgerSummary(merchantId: merchantId);

          return StreamBuilder<List<LedgerCustomer>>(
            stream: LedgerService.streamCustomers(merchantId),
            builder: (context, customerSnap) {
              final allCustomers = customerSnap.data ?? [];

              // تطبيق البحث والفلترة
              final filtered = allCustomers.where((c) {
                if (_searchQuery.isNotEmpty) {
                  final q = _searchQuery.toLowerCase();
                  final matchName = c.name.toLowerCase().contains(q);
                  final matchPhone = c.phone.contains(q);
                  if (!matchName && !matchPhone) return false;
                }

                if (_selectedFilter == 'with_debt') return c.currentBalance > 0;
                if (_selectedFilter == 'over_limit') return c.isOverLimit;
                if (_selectedFilter == 'zero_debt') return c.currentBalance <= 0;
                return true;
              }).toList();

              return CustomScrollView(
                slivers: [
                  // ══ بطاقات الملخص المالي الإجمالي ══
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.all(16),
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1E3C72), Color(0xFF2A5298)],
                          begin: Alignment.topRight,
                          end: Alignment.bottomLeft,
                        ),
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF1E3C72).withValues(alpha: 0.3),
                            blurRadius: 14,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'إجمالي ديون السوق الآجلة',
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 13,
                                  color: Colors.white70,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  '${summary.debtorsCount} مدين',
                                  style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 11,
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${summary.totalMarketDebt.toStringAsFixed(0)} ريال',
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w900,
                              fontSize: 28,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Divider(color: Colors.white24, height: 1),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'إجمالي العملاء المسجلين: ${allCustomers.length}',
                                style: const TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.white70),
                              ),
                              Text(
                                'متجاوزو السقف: ${allCustomers.where((c) => c.isOverLimit).length}',
                                style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 11,
                                  color: Color(0xFFFFB4A2),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ══ خانة البحث ══
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (val) => setState(() => _searchQuery = val.trim()),
                        decoration: InputDecoration(
                          hintText: 'ابحث باسم العميل أو رقم هاتفه...',
                          hintStyle: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: Colors.grey[400]),
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear_rounded),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _searchQuery = '');
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: context.bgCard,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // ══ شرائح الفلترة ══
                  SliverToBoxAdapter(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          _buildFilterChip('الكل (${allCustomers.length})', 'all'),
                          const SizedBox(width: 8),
                          _buildFilterChip(
                            'عليهم ديون (${allCustomers.where((c) => c.currentBalance > 0).length})',
                            'with_debt',
                          ),
                          const SizedBox(width: 8),
                          _buildFilterChip(
                            'تجاوزوا السقف (${allCustomers.where((c) => c.isOverLimit).length})',
                            'over_limit',
                            highlightColor: Colors.red,
                          ),
                          const SizedBox(width: 8),
                          _buildFilterChip('بلا ديون', 'zero_debt'),
                        ],
                      ),
                    ),
                  ),

                  // ══ قائمة بطاقات العملاء ══
                  if (filtered.isEmpty)
                    SliverToBoxAdapter(
                      child: Container(
                        margin: const EdgeInsets.all(24),
                        padding: const EdgeInsets.all(36),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: context.bgCard,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          children: [
                            Icon(Icons.person_search_rounded, size: 48, color: Colors.grey[400]),
                            const SizedBox(height: 12),
                            Text(
                              _searchQuery.isNotEmpty
                                  ? 'لا يوجد عملاء يطابقون بحثك'
                                  : 'دفتر الديون فارغ حالياً\nاضغط على (إضافة عميل) للبدء في توثيق حسابات الزبائن',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontFamily: 'Cairo', color: Colors.grey, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final customer = filtered[index];
                          return _buildCustomerCard(context, customer);
                        },
                        childCount: filtered.length,
                      ),
                    ),

                  const SliverToBoxAdapter(child: SizedBox(height: 90)),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildFilterChip(String label, String value, {Color? highlightColor}) {
    final isSelected = _selectedFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => setState(() => _selectedFilter = value),
      labelStyle: TextStyle(
        fontFamily: 'Cairo',
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        color: isSelected ? Colors.white : (highlightColor ?? Colors.grey[700]),
      ),
      selectedColor: highlightColor ?? AppColors.primary,
      backgroundColor: context.bgCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      showCheckmark: false,
    );
  }

  Widget _buildCustomerCard(BuildContext context, LedgerCustomer customer) {
    final lastDate = customer.lastTransactionAt ?? customer.updatedAt;
    final dateStr = lastDate != null ? LedgerPdfService.formatArabicDate(lastDate) : '';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: BoxDecoration(
        color: context.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: customer.isOverLimit
              ? const Color(0xFFE74C3C).withValues(alpha: 0.5)
              : Colors.grey.withValues(alpha: 0.15),
          width: customer.isOverLimit ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LedgerCustomerDetailScreen(customer: customer),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Avatar دائري مع أول حرف من اسم العميل
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: customer.isOverLimit
                          ? const Color(0xFFE74C3C).withValues(alpha: 0.15)
                          : AppColors.primary.withValues(alpha: 0.12),
                      child: Text(
                        customer.name.isNotEmpty ? customer.name[0] : 'ع',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.bold,
                          color: customer.isOverLimit ? const Color(0xFFC0392B) : AppColors.primary,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  customer.name,
                                  style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                              if (customer.isOverLimit) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE74C3C),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'تجاوز السقف',
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 9,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (customer.phone.isNotEmpty)
                            Text(
                              customer.phone,
                              style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.grey[600]),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${customer.currentBalance.toStringAsFixed(0)} ريال',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: customer.currentBalance > 0
                                ? (customer.isOverLimit ? const Color(0xFFC0392B) : const Color(0xFFE74C3C))
                                : const Color(0xFF27AE60),
                          ),
                        ),
                        if (dateStr.isNotEmpty)
                          Text(
                            dateStr,
                            style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Colors.grey[400]),
                          ),
                      ],
                    ),
                  ],
                ),
                if (customer.creditLimit > 0) ...[
                  const SizedBox(height: 10),
                  CreditLimitIndicator(customer: customer),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
