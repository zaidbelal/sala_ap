import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wissal/core/utils/arabic_normalizer.dart';
import '../../../../merchant/barcode/barcode_scanner_screen.dart';
import '../../../services/admin_service.dart';

final adminCategoriesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final keepAliveLink = ref.keepAlive();
  Timer? timer;
  // تفريغ الذاكرة العشوائية (RAM) تلقائياً بعد 3 دقائق من عدم استخدام الأدمن للكتالوج
  ref.onDispose(() => timer?.cancel());
  ref.onCancel(() {
    timer = Timer(const Duration(minutes: 3), () => keepAliveLink.close());
  });
  ref.onResume(() => timer?.cancel());

  return ref.watch(adminServiceProvider).getCategories();
});

final brandsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  ref.keepAlive();
  return ref.watch(adminServiceProvider).getBrands();
});

final productsLoadingMoreProvider =
    StateProvider.autoDispose<bool>((ref) => false);

class AdminProductsPaginationNotifier
    extends StateNotifier<AsyncValue<List<Map<String, dynamic>>>> {
  final Ref _ref;
  DocumentSnapshot? _lastDoc;
  bool _hasMore = true;
  static const int _pageSize = 60;
  String? _activeCategoryId;
  String? _activeBrandId;
  String _activeSearch = '';
  bool get hasMore => _hasMore;

  AdminProductsPaginationNotifier(this._ref)
      : super(const AsyncValue.loading()) {
    loadInitial();
  }
  Query<Map<String, dynamic>> _buildQuery() {
    final col = FirebaseFirestore.instance.collection('products');
    if (_activeBrandId != null) {
      return col
          .where('brand_id', isEqualTo: _activeBrandId)
          .where('is_deleted', isEqualTo: false)
          .orderBy('name');
    }
    if (_activeCategoryId != null) {
      return col
          .where('category_id', isEqualTo: _activeCategoryId)
          .where('is_deleted', isEqualTo: false);
    }
    return col
        .where('is_deleted', isEqualTo: false)
        .orderBy('updated_at', descending: true);
  }

  Future<void> loadInitial({
    bool silent = false,
    bool forceServer = false,
    String? categoryId,
    String? brandId,
    String? search,
  }) async {
    if (categoryId != null || brandId != null || search != null) {
      _activeCategoryId = categoryId?.isEmpty == true ? null : categoryId;
      _activeBrandId = brandId?.isEmpty == true ? null : brandId;
      _activeSearch = (search ?? '').trim();
    }
    if (!silent && (state.value == null || state.value!.isEmpty)) {
      state = const AsyncValue.loading();
    }
    try {
      final adminService = _ref.read(adminServiceProvider);
      final source = forceServer ? Source.server : Source.serverAndCache;
      final getOpts = GetOptions(source: source);

      if (_activeSearch.isNotEmpty) {
        final cleanBarcode = BarcodeScannerScreen.cleanBarcode(_activeSearch);
        final normQuery = ArabicNormalizer.normalize(_activeSearch);
        final tokens = normQuery.split(' ').where((t) => t.isNotEmpty).toList();

        final col = FirebaseFirestore.instance.collection('products');
        final futures = <Future<QuerySnapshot<Map<String, dynamic>>>>[
          _buildQuery().limit(400).get(getOpts),
        ];
        if (cleanBarcode.length >= 3) {
          futures.add(
            col
                .where('is_deleted', isEqualTo: false)
                .where('all_barcodes', arrayContains: cleanBarcode)
                .limit(20)
                .get(getOpts),
          );
        }

        final snaps = await Future.wait(futures);
        if (!mounted) return;

        final byId = <String, Map<String, dynamic>>{};
        for (final s in snaps) {
          for (final d in s.docs) {
            byId[d.id] = {'id': d.id, ...d.data()};
          }
        }

        final matched = byId.values.where((p) {
          if (_activeCategoryId != null &&
              p['category_id']?.toString() != _activeCategoryId) return false;
          if (_activeBrandId != null &&
              p['brand_id']?.toString() != _activeBrandId) return false;
          final normName =
              ArabicNormalizer.normalize(p['name']?.toString() ?? '');
          final nameMatch =
              tokens.isNotEmpty && tokens.every((t) => normName.contains(t));
          final mainBarcode = (p['barcode'] ?? '').toString();
          final allBarcodes = p['all_barcodes'];
          final barcodeMatch = cleanBarcode.isNotEmpty &&
              (mainBarcode.contains(cleanBarcode) ||
                  (allBarcodes is List &&
                      allBarcodes
                          .any((b) => b.toString().contains(cleanBarcode))));
          return nameMatch || barcodeMatch;
        }).toList();

        _lastDoc = null;
        _hasMore = false;
        state = AsyncValue.data(
            await adminService.attachProductFinancials(matched));
        return;
      }

      final snap = await _buildQuery().limit(_pageSize).get(getOpts);
      if (!mounted) return;

      _lastDoc = snap.docs.isNotEmpty ? snap.docs.last : null;
      _hasMore = snap.docs.length == _pageSize;

      final list = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      state = AsyncValue.data(await adminService.attachProductFinancials(list));
    } catch (e, st) {
      if (!mounted) return;
      if (!silent) state = AsyncValue.error(e, st);
    }
  }

  Future<void> loadMore() async {
    if (!_hasMore ||
        _ref.read(productsLoadingMoreProvider) ||
        _lastDoc == null) {
      return;
    }
    _ref.read(productsLoadingMoreProvider.notifier).state = true;
    try {
      final adminService = _ref.read(adminServiceProvider);
      final snap = await _buildQuery()
          .startAfterDocument(_lastDoc!)
          .limit(_pageSize)
          .get(const GetOptions(source: Source.serverAndCache));
      if (!mounted) return;

      _lastDoc = snap.docs.isNotEmpty ? snap.docs.last : null;
      _hasMore = snap.docs.length == _pageSize;

      final current = state.value ?? [];
      final more = await adminService.attachProductFinancials(
        snap.docs.map((d) => {'id': d.id, ...d.data()}).toList(),
      );
      final map = <String, Map<String, dynamic>>{
        for (final item in current) item['id'].toString(): item,
      };
      for (final item in more) {
        map[item['id'].toString()] = item;
      }
      state = AsyncValue.data(map.values.toList());
    } catch (_) {
    } finally {
      if (mounted) {
        _ref.read(productsLoadingMoreProvider.notifier).state = false;
      }
    }
  }
}

final adminProductsProvider = StateNotifierProvider.autoDispose<
    AdminProductsPaginationNotifier,
    AsyncValue<List<Map<String, dynamic>>>>((ref) {
  final keepAliveLink = ref.keepAlive();
  Timer? timer;
  ref.onDispose(() => timer?.cancel());
  ref.onCancel(() {
    timer = Timer(const Duration(minutes: 5), () => keepAliveLink.close());
  });
  ref.onResume(() => timer?.cancel());

  return AdminProductsPaginationNotifier(ref);
});
