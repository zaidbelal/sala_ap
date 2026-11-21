import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'app_cache.dart';
import 'realtime_hub.dart';
import 'image_precache_service.dart';

// ══════════════════════════════════════════════════════════
// CatalogService — Production-Grade
//
// استراتيجيات التحمّل العالي:
//
//  ① RealtimeHub-First   — إذا RealtimeHub عنده البيانات لا يُفتح
//                          طلب Firestore إضافي أبداً
//  ② Cache-First         — الكاش يُرجع فوراً (0ms)، Firestore
//                          يعمل في الخلفية بصمت
//  ③ Request Coalescing  — إذا 100 widget طلبوا نفس البيانات
//                          في نفس اللحظة → طلب Firestore واحد فقط
//                          (Completer pattern)
//  ④ Silent Errors       — أي خطأ شبكي لا يكسر الـ UI أبداً
//  ⑤ No Manual Timeout   — Firestore SDK يدير timeout داخلياً.
//                          .timeout() يسبب debugger freezes + zombie requests
//  ⑥ Exponential Backoff — retry واحد فقط بتأخير تصاعدي (لا cascading)
// ══════════════════════════════════════════════════════════

final _db = FirebaseFirestore.instance;

// ─────────────────────────────────────────────────────────
// Providers
// ─────────────────────────────────────────────────────────

/// حقن الاعتماديات عبر مزودات مركزية
final appCacheProvider = Provider<AppCache>((ref) => AppCache.instance);
final categoriesProvider =
    AsyncNotifierProvider<CategoriesNotifier, List<Map<String, dynamic>>>(
  CategoriesNotifier.new,
);

final productsProvider = AsyncNotifierProviderFamily<ProductsNotifier,
    List<Map<String, dynamic>>, String?>(ProductsNotifier.new);

// تم حذف ordersProvider غير المستخدم لتقليل استهلاك موارد السحابة

// ══════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════

class _Coalescer<T> {
  Completer<T>? _inflight;

  Future<T> run(Future<T> Function() task) {
    if (_inflight != null) return _inflight!.future;
    _inflight = Completer<T>();
    // 🚀 استخدام Future.sync لحماية الوعاء من التعليق الدائم في حال رمي خطأ متزامن
    Future.sync(task).then((v) {
      if (_inflight != null && !_inflight!.isCompleted) {
        _inflight!.complete(v);
      }
    }).catchError((Object e, StackTrace st) {
      if (_inflight != null && !_inflight!.isCompleted) {
        _inflight!.completeError(e, st);
      }
    }).whenComplete(() {
      _inflight = null;
    });
    return _inflight!.future;
  }
}

/// Silent Execution:
/// ينفّذ المهمة ويمسك أي exception بصمت — لا crash، لا debugger pause.

Future<T?> _silently<T>(
  Future<T> Function() task, {
  String tag = 'task',
}) async {
  try {
    return await task();
  } catch (e, st) {
    if (kDebugMode) debugPrint('⚠️ [$tag] silent error: $e');
    if (!kIsWeb) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'Silent failure in $tag',
        fatal: false,
      );
    }
    return null;
  }
}

/// Retry مرة واحدة مع Exponential Backoff.
/// عند الفشل الكامل يُرجع [fallback] بصمت بدل رمي exception.
Future<T> _retry<T>(
  Future<T> Function() task, {
  int maxAttempts = 2,
  Duration baseDelay = const Duration(milliseconds: 800),
  String tag = 'task',
}) async {
  Object? lastError;
  StackTrace? lastStackTrace;

  for (int i = 0; i < maxAttempts; i++) {
    try {
      return await task();
    } catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;

      if (kDebugMode) {
        debugPrint(
          '[$tag] attempt ${i + 1}/$maxAttempts failed: $error',
        );
      }

      if (i < maxAttempts - 1) {
        await Future.delayed(baseDelay * (1 << i));
      }
    }
  }

  Error.throwWithStackTrace(
    lastError ?? StateError('Unknown retry failure'),
    lastStackTrace ?? StackTrace.current,
  );
}

// ══════════════════════════════════════════════════════════
// Categories Notifier
// ══════════════════════════════════════════════════════════
class CategoriesNotifier extends AsyncNotifier<List<Map<String, dynamic>>> {
  final _coalescer = _Coalescer<List<Map<String, dynamic>>>();
  bool _isDisposed = false;

  ProviderSubscription? _realtimeSub;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    _isDisposed = false;
    final link = ref.keepAlive();
    Timer? timer;
    ref.onDispose(() {
      _isDisposed = true;
      timer?.cancel();
      _realtimeSub?.close();
      _realtimeSub = null;
    });
    ref.onCancel(() {
      timer = Timer(const Duration(minutes: 10), () => link.close());
    });
    ref.onResume(() => timer?.cancel());
    _realtimeSub?.close();
    _realtimeSub = ref.listen<List<Map<String, dynamic>>>(
      realtimeCategoriesProvider,
      (_, next) {
        // 🔒 حظر الكتابة فوق الكاش بالمصفوفات الفارغة الناتجة عن تسجيل الخروج
        if (!_isDisposed && next.isNotEmpty) {
          state = AsyncData(next);
        }
      },
    );
    // ① RealtimeHub — صفر قراءات Firestore إضافية
    final live = ref.read(realtimeCategoriesProvider);
    if (live.isNotEmpty) {
      return live;
    }

    // ② الكاش المحلي — فوري تماماً
    final cached = AppCache.instance.getCategories();
    if (cached != null && cached.isNotEmpty) {
      if (!AppCache.instance.isCategoriesFresh()) {
        unawaited(_bgRefresh());
      }
      return cached;
    }

    // ③ الشبكة — مرة واحدة مع retry واحد وfallback فارغ
    return _retry(
      _fetchAndCache,
      tag: 'categories',
    );
  }

  Future<void> _bgRefresh() async {
    final cache = ref.read(appCacheProvider);
    final fresh = await _silently<List<Map<String, dynamic>>>(
      _fetchFromNetwork,
      tag: 'categories-bg',
    );
    if (fresh != null) {
      await cache.setCategories(fresh);
      if (!_isDisposed && ref.exists(categoriesProvider)) {
        state = AsyncValue.data(fresh);
      }
    }
  }

  Future<List<Map<String, dynamic>>> _fetchAndCache() async {
    final data = await _coalescer.run(_fetchFromNetwork);
    await AppCache.instance.setCategories(data);
    ImagePrecacheService.instance.prewarmCategories(data);
    return data;
  }

  Future<List<Map<String, dynamic>>> _fetchFromNetwork() async {
    final snap = await _db
        .collection('categories')
        .limit(200)
        .get(const GetOptions(source: Source.serverAndCache));
    final list = snap.docs
        .where((d) =>
            d.data()['is_deleted'] != true && d.data()['is_active'] != false)
        .map((d) => {'id': d.id, ...d.data()})
        .toList()
      ..sort((a, b) => ((a['sort_order'] as num?)?.toInt() ?? 999)
          .compareTo((b['sort_order'] as num?)?.toInt() ?? 999));
    return list;
  }

  /// Pull-to-refresh يدوي من الـ UI
  Future<void> refresh() async {
    final fresh = await _silently(_fetchFromNetwork, tag: 'categories-manual');
    if (fresh != null && !_isDisposed) {
      await AppCache.instance.setCategories(fresh);
      state = AsyncData(fresh);
    }
  }
}

// ══════════════════════════════════════════════════════════
// Products Notifier
// ══════════════════════════════════════════════════════════
class ProductsNotifier
    extends FamilyAsyncNotifier<List<Map<String, dynamic>>, String?> {
  final _coalescer = _Coalescer<List<Map<String, dynamic>>>();
  bool _isDisposed = false;
  ProviderSubscription? _realtimeSub;

  @override
  Future<List<Map<String, dynamic>>> build(String? arg) async {
    _isDisposed = false;
    final link = ref.keepAlive();
    Timer? timer;
    ref.onDispose(() {
      _isDisposed = true;
      timer?.cancel();
      _realtimeSub?.close();
      _realtimeSub = null;
    });
    ref.onCancel(() {
      timer = Timer(const Duration(minutes: 10), () => link.close());
    });
    ref.onResume(() => timer?.cancel());
// تفعيل الاشتراك اللحظي تلقائياً للكتالوج العام والأقسام دون إعادة كتابة الكاش
    _realtimeSub?.close();
    _realtimeSub = ref.listen<List<Map<String, dynamic>>>(
      realtimeProductsProvider,
      (_, next) {
        if (next.isEmpty || _isDisposed) return;

        final currentList = state.valueOrNull ??
            AppCache.instance.getProducts(categoryId: arg) ??
            [];
        final Map<String, Map<String, dynamic>> productMap = {
          for (final p in currentList) p['id'].toString(): p,
        };

        bool touched = false;
        for (final liveItem in next) {
          final id = liveItem['id']?.toString();
          if (id == null || id.isEmpty) continue;

          final belongsToScope =
              arg == null || liveItem['category_id']?.toString() == arg;
          final isHidden =
              liveItem['is_deleted'] == true || liveItem['is_active'] == false;

          if (isHidden || !belongsToScope) {
            if (productMap.remove(id) != null) touched = true;
          } else {
            productMap[id] = liveItem;
            touched = true;
          }
        }

        if (!touched) return;

        final merged = productMap.values.toList()
          ..sort((a, b) => ((a['sort_order'] as num?)?.toInt() ?? 999)
              .compareTo((b['sort_order'] as num?)?.toInt() ?? 999));

        state = AsyncData(merged);
        _precache(merged);
      },
    );
    return _load(categoryId: arg);
  }

  Future<List<Map<String, dynamic>>> _load({String? categoryId}) async {
// ② الكاش المحلي (Stale-While-Revalidate: إرجاع فوري وتحديث خلفي دائم لتجنب اختلاف الأسعار)
    final cached = AppCache.instance.getProducts(categoryId: categoryId);
    if (cached != null) {
      if (!AppCache.instance.isProductsFresh(categoryId: categoryId)) {
        unawaited(_bgRefresh(categoryId: categoryId));
      }
      _precache(cached);
      return cached;
    }
    // ③ الشبكة مع retry
    return _retry(
      () => _fetchAndCache(categoryId: categoryId),
      tag: 'products-${categoryId ?? "all"}',
    );
  }

  Future<void> _bgRefresh({String? categoryId}) async {
    final fresh = await _silently(
      () => _fetchFromNetwork(categoryId: categoryId),
      tag: 'products-bg-${categoryId ?? "all"}',
    );
    if (fresh != null) {
      await AppCache.instance.setProducts(fresh, categoryId: categoryId);
      if (!_isDisposed) {
        state = AsyncData(fresh);
        _precache(fresh);
      }
    }
  }

  Future<List<Map<String, dynamic>>> _fetchAndCache({
    String? categoryId,
  }) async {
    final data = await _coalescer.run(
      () => _fetchFromNetwork(categoryId: categoryId),
    );
    await AppCache.instance.setProducts(data, categoryId: categoryId);
    _precache(data);
    return data;
  }

  Future<List<Map<String, dynamic>>> _fetchFromNetwork({
    String? categoryId,
  }) async {
    const maxInitialCacheSize = 2500;
    Query<Map<String, dynamic>> query =
        _db.collection('products').where('is_deleted', isEqualTo: false);

    if (categoryId != null) {
      query = query.where('category_id', isEqualTo: categoryId);
    }

    query = query.limit(maxInitialCacheSize);
    final snap =
        await query.get(const GetOptions(source: Source.serverAndCache));

    final List<Map<String, dynamic>> results = snap.docs
        .where((d) => d.data()['is_active'] != false)
        .map((d) => {'id': d.id, ...d.data()})
        .toList()
      ..sort((a, b) => ((a['sort_order'] as num?)?.toInt() ?? 999)
          .compareTo((b['sort_order'] as num?)?.toInt() ?? 999));

    return results;
  }

  void _precache(List<Map<String, dynamic>> products) {
    if (kIsWeb) return;
    // تجاهل الـ Future لأن التحميل يعمل في الخلفية بصمت
    ImagePrecacheService.instance.prewarmProducts(products).catchError((_) {});
  }

  Future<void> refresh() async {
    final fresh = await _silently(
      () => _fetchFromNetwork(categoryId: arg),
      tag: 'products-manual-${arg ?? "all"}',
    );
    if (fresh != null) {
      await AppCache.instance.setProducts(fresh, categoryId: arg);
      state = AsyncData(fresh);
      _precache(fresh);
    }
  }
}
