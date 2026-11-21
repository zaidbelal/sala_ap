import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import '../../../../core/services/app_cache.dart';
import '../../products/services/products_service.dart';
import '../models/ledger_customer.dart';
import '../models/ledger_entry.dart';
import '../models/ledger_item.dart';
import '../models/ledger_summary.dart';

class LedgerService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  // ذاكرة تخزين مؤقتة محلية لأسعار التجزئة
  static final Map<String, double> _retailPriceCache = {};

  /// جلب تدفق قائمة العملاء النشطين للتاجر
  static Stream<List<LedgerCustomer>> streamCustomers(String merchantId) {
    return _db
        .collection('merchant_customers')
        .where('merchant_id', isEqualTo: merchantId)
        .where('is_deleted', isEqualTo: false)
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs
          .map((doc) => LedgerCustomer.fromMap(doc.id, doc.data()))
          .toList();
      // ترتيب تنازلي حسب تاريخ آخر حركة أو التعديل
      list.sort((a, b) {
        final aTime = a.lastTransactionAt ?? a.updatedAt ?? DateTime(2000);
        final bTime = b.lastTransactionAt ?? b.updatedAt ?? DateTime(2000);
        return bTime.compareTo(aTime);
      });
      return list;
    });
  }

  /// جلب ملخص ديون السوق للتاجر
  static Stream<LedgerSummary> streamSummary(String merchantId) {
    return _db
        .collection('merchant_ledger_summaries')
        .doc(merchantId)
        .snapshots()
        .map((doc) {
      if (!doc.exists || doc.data() == null) {
        return LedgerSummary(merchantId: merchantId);
      }
      return LedgerSummary.fromMap(merchantId, doc.data()!);
    });
  }

  /// جلب تدفق سجل الحركات لعميل محدد
  static Stream<List<LedgerEntry>> streamCustomerEntries(String merchantId, String customerId) {
    return _db
        .collection('merchant_ledger_entries')
        .where('merchant_id', isEqualTo: merchantId)
        .where('customer_id', isEqualTo: customerId)
        .snapshots()
        .map((snapshot) {
      final entries = snapshot.docs
          .map((doc) => LedgerEntry.fromMap(doc.id, doc.data()))
          .toList();
      entries.sort((a, b) {
        final aDate = a.createdAt ?? DateTime(2000);
        final bDate = b.createdAt ?? DateTime(2000);
        return bDate.compareTo(aDate);
      });
      return entries;
    });
  }

  /// تسجيل قيد مالي جديد (دين أو سداد دفعة نقدية) عبر Cloud Function الآمنة
  static Future<Map<String, dynamic>> recordTransaction({
    required String customerId,
    required String type, // 'debt' or 'payment'
    required double amount,
    String? notes,
    List<LedgerItem>? items,
  }) async {
    try {
      final callable = _functions.httpsCallable('recordLedgerTransaction');
      final result = await callable.call({
        'customerId': customerId,
        'type': type,
        'amount': amount,
        'notes': notes,
        'items': items?.map((i) => i.toMap()).toList(),
      });
      return Map<String, dynamic>.from(result.data as Map);
    } catch (e) {
      debugPrint('❌ Error in recordTransaction: $e');
      rethrow;
    }
  }

  /// إلغاء قيد مالي وعكس الحساب ذرياً
  static Future<Map<String, dynamic>> voidTransaction({
    required String customerId,
    required String entryId,
  }) async {
    try {
      final callable = _functions.httpsCallable('voidLedgerTransaction');
      final result = await callable.call({
        'customerId': customerId,
        'entryId': entryId,
      });
      return Map<String, dynamic>.from(result.data as Map);
    } catch (e) {
      debugPrint('❌ Error in voidTransaction: $e');
      rethrow;
    }
  }

  /// حفظ أو تعديل عميل في الدفتر
  static Future<String> saveCustomer({
    String? customerId,
    required String name,
    String? phone,
    double creditLimit = 0.0,
    String? notes,
  }) async {
    try {
      final callable = _functions.httpsCallable('saveLedgerCustomer');
      final result = await callable.call({
        if (customerId != null && customerId.isNotEmpty) 'customerId': customerId,
        'name': name,
        'phone': phone ?? '',
        'creditLimit': creditLimit,
        'notes': notes ?? '',
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      return data['customerId']?.toString() ?? '';
    } catch (e) {
      debugPrint('❌ Error in saveCustomer: $e');
      rethrow;
    }
  }

  /// حذف عميل من الدفتر
  static Future<void> deleteCustomer(String customerId) async {
    try {
      final callable = _functions.httpsCallable('deleteLedgerCustomer');
      await callable.call({'customerId': customerId});
    } catch (e) {
      debugPrint('❌ Error in deleteCustomer: $e');
      rethrow;
    }
  }

  /// مطابقة وتدقيق رصيد العميل
  static Future<double> reconcileCustomer(String customerId) async {
    try {
      final callable = _functions.httpsCallable('reconcileLedgerBalance');
      final result = await callable.call({'customerId': customerId});
      final data = Map<String, dynamic>.from(result.data as Map);
      return (data['balance'] as num?)?.toDouble() ?? 0.0;
    } catch (e) {
      debugPrint('❌ Error in reconcileCustomer: $e');
      rethrow;
    }
  }

  // ════════════════════════════════════════════════════════════
  // 🏷️ ذاكرة تسعير الحبة للبقالة (Retail Unit Pricing Memory)
  // ════════════════════════════════════════════════════════════

  /// جلب سعر بيع الحبة المخزن لهذا التاجر
  static Future<double?> getStoredRetailPrice(String merchantId, String productId) async {
    if (_retailPriceCache.containsKey(productId)) {
      return _retailPriceCache[productId];
    }
    try {
      final doc = await _db
          .collection('profiles')
          .doc(merchantId)
          .collection('retail_pricing')
          .doc(productId)
          .get();
      if (doc.exists && doc.data() != null) {
        final price = (doc.data()!['price'] as num?)?.toDouble();
        if (price != null && price > 0) {
          _retailPriceCache[productId] = price;
          return price;
        }
      }
    } catch (_) {}
    return null;
  }

  /// حفظ سعر بيع الحبة المخصص للتاجر لاستخدامه دائماً عند مسح الباركود
  static Future<void> saveRetailPrice({
    required String merchantId,
    required String productId,
    required double price,
  }) async {
    if (price <= 0) return;
    _retailPriceCache[productId] = price;
    try {
      await _db
          .collection('profiles')
          .doc(merchantId)
          .collection('retail_pricing')
          .doc(productId)
          .set({
        'price': price,
        'updated_at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('❌ Error saving retail price: $e');
    }
  }

  /// البحث عن المنتج بالباركود واحتساب سعر الحبة الافتراضي
  static ProductModel? findProductByBarcode(String barcode) {
    final cleanCode = barcode.trim();
    if (cleanCode.isEmpty) return null;

    final cachedProducts = AppCache.instance.getProducts() ?? [];
    for (final raw in cachedProducts) {
      final p = ProductModel.fromMap(raw);
      // فحص الباركود الرئيسي
      if (p.barcode != null && p.barcode!.trim() == cleanCode) {
        return p;
      }
      // فحص مصفوفة الباركودات
      if (p.allBarcodes.any((b) => b.trim() == cleanCode)) {
        return p;
      }
      // فحص وحدات البيع
      for (final u in p.units) {
        if (u.barcode != null && u.barcode!.trim() == cleanCode) {
          return p;
        }
      }
      // فحص المتغيرات
      for (final v in p.variants) {
        if (v.barcode != null && v.barcode!.trim() == cleanCode) {
          return p;
        }
      }
    }
    return null;
  }

  /// احتساب سعر الحبة الافتراضي بناءً على الكرتون أو وحدات البيع
  static double calculateDefaultPiecePrice(ProductModel product) {
    // 1. هل توجد وحدة حبة معرفة؟
    for (final unit in product.units) {
      if (unit.qty == 1 || unit.label.contains('حبة') || unit.label.contains('قطعة')) {
        if (unit.price > 0) return unit.price;
      }
    }
    // 2. حساب من سعة الكرتون
    final capacity = (product.itemsPerCarton != null && product.itemsPerCarton! > 0)
        ? product.itemsPerCarton!
        : 1;
    final pieceWholesale = product.price / capacity;
    // إضافة هامش ربح تجزئة تقديري (15%) وتقريب لأقرب 50 أو 100 ريال
    final estimatedRetail = pieceWholesale * 1.15;
    return double.parse(estimatedRetail.toStringAsFixed(2));
  }
}
