import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/order_model.dart';
import 'package:wissal/core/services/app_cache.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:async';
import 'package:wissal/core/services/local_storage.dart';

class OrdersService {
  static final _db = FirebaseFirestore.instance;

  static void _assertMerchantSession(String merchantId) {
    final cleanMerchantId = merchantId.trim();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? AppStorage.userId;

    if (uid == null ||
        uid.isEmpty ||
        cleanMerchantId.isEmpty ||
        uid != cleanMerchantId) {
      throw StateError('جلسة التاجر غير صالحة');
    }
  }

  /// 🚀 تنفيذ آمن للمعاملات مع ترك إدارة المهلة لمحرك Firestore داخلياً لمنع تعارض الـ Completer
  static Future<T> runContentionSafeTransaction<T>(
    Future<T> Function(Transaction tx) action,
  ) async {
    return _db.runTransaction<T>(action);
  }

// ════════════════════════════════════════
  // استلام السائق للطلب (عبر السيرفر حصراً)
  // ════════════════════════════════════════
// ✅ عقد برمجي موثق ومطابق للسيرفر: يتم التحقق من السائق عبر سياق المصادقة السحابي
  static Future<void> assignOrderToDriver({
    required String orderId,
  }) async {
    final cleanOrderId = orderId.trim();
    if (cleanOrderId.isEmpty) throw ArgumentError('معرّف الطلب غير صالح');

    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('assignOrderToDriver',
            options:
                HttpsCallableOptions(timeout: const Duration(seconds: 15)));

    await callable.call({'orderId': cleanOrderId});
  }

  // ════════════════════════════════════════
  // تأكيد تسليم السائق للطلب واعتماد الأرباح والتوقيع سحابياً
  // ════════════════════════════════════════
  static Future<void> deliverOrderByDriver({
    required String orderId,
    String? signatureUrl,
  }) async {
    final cleanOrderId = orderId.trim();
    if (cleanOrderId.isEmpty) throw ArgumentError('معرّف الطلب غير صالح');

    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('deliverOrderByDriver',
            options:
                HttpsCallableOptions(timeout: const Duration(seconds: 25)));

    await callable.call({
      'orderId': cleanOrderId,
      'signatureData': signatureUrl,
    });
  }

// ════════════════════════════════════════
// تقديم طلب جديد (عبر السيرفر حصراً)
// ════════════════════════════════════════
  static Future<OrderModel> placeOrder({
    required String merchantId,
    required List<Map<String, dynamic>> items,
    required double expectedTotal,
    String? notes,
    Map<String, dynamic>? extraData,
    String? orderId,
  }) async {
    final cleanMerchantId = merchantId.trim();
    _assertMerchantSession(cleanMerchantId);

    final resolvedOrderId = (orderId != null && orderId.trim().isNotEmpty)
        ? orderId.trim()
        : _db.collection('orders').doc().id;

    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('placeOrder',
            options:
                HttpsCallableOptions(timeout: const Duration(seconds: 25)));

    final response = await callable.call({
      'orderId': resolvedOrderId,
      'items': items,
      'expectedTotal': expectedTotal,
      'notes': notes?.trim(),
      'extraData': extraData,
    });

    final data = Map<String, dynamic>.from(response.data as Map);
    final orderMap = Map<String, dynamic>.from(data['order'] as Map);
    final createdOrder = OrderModel.fromJson(orderMap);

    try {
      await AppCache.instance.invalidateProducts();
    } catch (_) {}

    return createdOrder;
  }

  // ════════════════════════════════════════
  // مراقبة طلب واحد (Realtime)
  // ════════════════════════════════════════
  static Stream<OrderModel?> watchOrder(String orderId) {
    return _db.collection('orders').doc(orderId).snapshots().map(
          (d) =>
              d.exists ? OrderModel.fromJson({'id': d.id, ...d.data()!}) : null,
        );
  }

// ════════════════════════════════════════
  // مراقبة كل طلبات التاجر (Realtime)
  // ════════════════════════════════════════
  static Stream<List<OrderModel>> watchMerchantOrders(String merchantId) {
    return _db
        .collection('orders')
        .where('merchant_id', isEqualTo: merchantId)
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots(includeMetadataChanges: false)
        .map((snap) {
      return snap.docs
          .map((d) => OrderModel.fromJson({'id': d.id, ...d.data()}))
          .toList();
    });
  }

  // ════════════════════════════════════════
  // مراقبة طلبات التاجر بحالات محددة (محمية معمارياً من انهيار الفهارس)
  // ════════════════════════════════════════
  static Stream<List<OrderModel>> watchMerchantOrdersByStatuses(
    String merchantId,
    List<String> statuses,
  ) {
    if (statuses.isEmpty) return const Stream.empty();

    return _db
        .collection('orders')
        .where('merchant_id', isEqualTo: merchantId)
        .where('status', whereIn: statuses.take(30).toList())
        .orderBy('created_at', descending: true)
        .limit(200)
        .snapshots(includeMetadataChanges: false)
        .map((snap) {
      return snap.docs
          .map((d) => OrderModel.fromJson({'id': d.id, ...d.data()}))
          .toList();
    });
  }

  // ════════════════════════════════════════
  // مراقبة فواتير المرتجعات للتاجر (مطلوبة لشاشة السجل)
  // ════════════════════════════════════════
  static Stream<List<Map<String, dynamic>>> watchMerchantReturns(
    String merchantId,
  ) {
    return _db
        .collection('order_returns')
        .where('merchant_id', isEqualTo: merchantId)
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots(includeMetadataChanges: false)
        .map(
            (snap) => snap.docs.map((d) => {'id': d.id, ...d.data()}).toList());
  }

  static Future<List<Map<String, dynamic>>> getOrderItems(
      String orderId) async {
    final snap = await _db
        .collection('order_items')
        .where('order_id', isEqualTo: orderId)
        .get(const GetOptions(source: Source.serverAndCache));
    return snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
  }

  // ════════════════════════════════════════
  // جلب الطلبات حسب الحالة — فرز بالذاكرة لمنع FAILED_PRECONDITION
  // ════════════════════════════════════════
  static Future<List<Map<String, dynamic>>> getOrdersByStatus({
    required String merchantId,
    required String status,
  }) async {
    final snap = await _db
        .collection('orders')
        .where('merchant_id', isEqualTo: merchantId)
        .where('status', isEqualTo: status)
        .orderBy('created_at', descending: true)
        .limit(200)
        .get(const GetOptions(source: Source.serverAndCache));
    final list = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
    list.sort((a, b) {
      final aDate = a['created_at'] is Timestamp
          ? (a['created_at'] as Timestamp).toDate()
          : DateTime(2000);
      final bDate = b['created_at'] is Timestamp
          ? (b['created_at'] as Timestamp).toDate()
          : DateTime(2000);
      return bDate.compareTo(aDate);
    });
    return list;
  }

  // ════════════════════════════════════════
  // جلب الطلبات متعددة الحالات دفعةً واحدة
  // ════════════════════════════════════════
  static Future<List<Map<String, dynamic>>> getOrdersByStatuses({
    required String merchantId,
    required List<String> statuses,
  }) async {
    if (statuses.isEmpty) return [];

    final statusGroups = <List<String>>[
      for (var i = 0; i < statuses.length; i += 30)
        statuses.skip(i).take(30).toList(),
    ];
    final snapshots = await Future.wait(statusGroups.map((group) {
      return _db
          .collection('orders')
          .where('merchant_id', isEqualTo: merchantId)
          .where('status', whereIn: group)
          .orderBy('created_at', descending: true)
          .limit(200)
          .get(const GetOptions(source: Source.serverAndCache));
    }));
    final docsById = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final snap in snapshots) {
      for (final doc in snap.docs) {
        docsById[doc.id] = doc;
      }
    }
    final list = docsById.values.map((d) => {'id': d.id, ...d.data()}).toList();
    list.sort((a, b) {
      final aDate = a['created_at'] is Timestamp
          ? (a['created_at'] as Timestamp).toDate()
          : DateTime(2000);
      final bDate = b['created_at'] is Timestamp
          ? (b['created_at'] as Timestamp).toDate()
          : DateTime(2000);
      return bDate.compareTo(aDate);
    });
    return list.take(200).toList();
  }

// ════════════════════════════════════════
  // إرسال طلب إرجاع (معالجة سحابية آمنة وموثقة 100%)
  // ════════════════════════════════════════
  static Future<void> submitReturns({
    required String orderId,
    required List<Map<String, dynamic>> itemsToReturn,
    required String merchantId,
    String? storeName,
    String? contact,
    double? latitude,
    double? longitude,
    required String reason,
  }) async {
    final cleanOrderId = orderId.trim();
    final cleanMerchantId = merchantId.trim();
    final cleanReason = reason.trim();

    if (cleanOrderId.isEmpty) {
      throw ArgumentError('معرّف الطلب غير صالح');
    }
    if (cleanMerchantId.isEmpty) {
      throw ArgumentError('معرّف التاجر غير صالح');
    }
    _assertMerchantSession(cleanMerchantId);

    if (itemsToReturn.isEmpty) {
      throw ArgumentError('يجب تحديد عنصر واحد على الأقل للإرجاع');
    }
    if (cleanReason.isEmpty) {
      throw ArgumentError('سبب الإرجاع مطلوب');
    }

    // 🚀 استدعاء الدالة السحابية الآمنة لمعالجة الطلب في السيرفر
    final callable =
        FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable(
      'submitReturnRequest',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 25)),
    );

    try {
      await callable.call({
        'orderId': cleanOrderId,
        'itemsToReturn': itemsToReturn,
        'storeName': storeName?.trim(),
        'contact': contact?.trim(),
        'latitude': latitude,
        'longitude': longitude,
        'reason': cleanReason,
      });
    } on FirebaseFunctionsException catch (e) {
      throw StateError(e.message ?? 'فشل تقديم طلب الإرجاع من الخادم');
    }
  }

// ════════════════════════════════════════
// إلغاء الطلب واسترجاع المخزون (عبر السيرفر حصراً)
// ════════════════════════════════════════
  static Future<void> cancelOrder(
    String orderId,
    String merchantId,
  ) async {
    final cleanOrderId = orderId.trim();
    _assertMerchantSession(merchantId.trim());

    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('cancelOrder',
            options:
                HttpsCallableOptions(timeout: const Duration(seconds: 15)));

    await callable.call({'orderId': cleanOrderId});
    await AppCache.instance.invalidateProducts();
  }
}
