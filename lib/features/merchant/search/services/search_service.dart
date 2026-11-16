import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/services/app_cache.dart';
import '../../../../core/services/image_precache_service.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:wissal/core/utils/arabic_normalizer.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart'; // ✅ إضافة استيراد Crashlytics

final _db = FirebaseFirestore.instance;
final _cache = <String, _CachedSearchResult>{};

class _CachedSearchResult {
  final SearchResult result;
  final DateTime cachedAt;

  const _CachedSearchResult(this.result, this.cachedAt);
}

class SearchResult {
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> brands;
  final List<Map<String, dynamic>> categories;

  const SearchResult({
    required this.products,
    required this.brands,
    required this.categories,
  });

  bool get isEmpty => products.isEmpty && brands.isEmpty && categories.isEmpty;
}

class SearchService {
  static const _cacheTtl = Duration(seconds: 30);

  Future<SearchResult> search(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return const SearchResult(products: [], brands: [], categories: []);
    }

    final cached = _cache[q];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) < _cacheTtl) {
      return cached.result;
    }
    _cache.remove(q);

    // 1. البحث الفوري المحلي في الذاكرة (0ms)
    final localResult = _searchLocally(q);
    if (localResult != null && !localResult.isEmpty) {
      _putInCache(q, localResult);
      unawaited(_fetchAndUpdateCache(q));
      return localResult;
    }

    final serverResult = await _fetchAndUpdateCache(q);
    _putInCache(q, serverResult);
    return serverResult;
  }

  void _putInCache(String query, SearchResult result) {
    if (_cache.length >= 60) {
      final now = DateTime.now();
      _cache.removeWhere(
        (_, entry) => now.difference(entry.cachedAt) >= _cacheTtl,
      );
      if (_cache.length >= 60) _cache.clear();
    }
    _cache[query] = _CachedSearchResult(result, DateTime.now());
  }

  static String normalizeArabic(String text) =>
      ArabicNormalizer.normalize(text);

  static bool _matchesTokens(String target, List<String> tokens) =>
      ArabicNormalizer.matches(target, tokens);
  SearchResult? _searchLocally(String q) {
    final cache = AppCache.instance;
    final allProducts = cache.getAllCachedProducts();
    final allCategories = cache.getCategories() ?? [];
    final allBrands = cache.getBrands() ?? [];

    if (allProducts.isEmpty && allCategories.isEmpty && allBrands.isEmpty) {
      return null;
    }

    final tokens =
        normalizeArabic(q).split(' ').where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return null;

    final products = allProducts
        .where((p) {
          if (p['is_deleted'] == true || p['is_active'] == false) return false;
          final name = p['name']?.toString() ?? '';
          if (_matchesTokens(name, tokens)) return true;
          return _matchesBarcode(p, q);
        })
        .take(30)
        .toList();
    final brands = allBrands
        .where((b) {
          if (b['is_deleted'] == true || b['is_active'] == false) return false;
          return _matchesTokens(b['name']?.toString() ?? '', tokens);
        })
        .take(15)
        .toList();

    final categories = allCategories
        .where((c) {
          if (c['is_deleted'] == true || c['is_active'] == false) return false;
          return _matchesTokens(c['name']?.toString() ?? '', tokens);
        })
        .take(10)
        .toList();

    return SearchResult(
      products: products,
      brands: brands,
      categories: categories,
    );
  }

  Future<SearchResult> _fetchAndUpdateCache(String q) async {
    final tokens =
        normalizeArabic(q).split(' ').where((t) => t.isNotEmpty).toList();
    // Firestore stores the original product names; normalize only after retrieval.
    final firstToken = q.split(RegExp(r'\s+')).first;
    final prefixesToQuery = <String>{firstToken};
    if (firstToken.isNotEmpty) {
      prefixesToQuery
          .add(firstToken[0].toUpperCase() + firstToken.substring(1));
    }
    if (firstToken.startsWith('ا') ||
        firstToken.startsWith('أ') ||
        firstToken.startsWith('إ') ||
        firstToken.startsWith('آ')) {
      final rest = firstToken.substring(1);
      prefixesToQuery.addAll(['ا$rest', 'أ$rest', 'إ$rest', 'آ$rest']);
    }

    final cleanBarcode = ArabicNormalizer.normalizeDigits(q)
        .replaceAll(RegExp(r'[^0-9a-zA-Z]'), '')
        .trim();

    final results = await Future.wait([
      _safeQuery('products', () async {
        final combinedDocs = <String, Map<String, dynamic>>{};
        if (cleanBarcode.isNotEmpty) {
          final barcodeVariants = <String>{
            cleanBarcode,
            cleanBarcode.toLowerCase(),
            cleanBarcode.toUpperCase(),
          }.toList();
          final barcodeQuery = await _db
              .collection('products')
              .where('all_barcodes', arrayContainsAny: barcodeVariants)
              .limit(15)
              .get(const GetOptions(source: Source.serverAndCache));
          for (final d in barcodeQuery.docs) {
            if (d.data()['is_deleted'] != true &&
                d.data()['is_active'] != false) {
              combinedDocs[d.id] = {'id': d.id, ...d.data()};
            }
          }
        }

        await Future.wait(prefixesToQuery.map((pfx) async {
          final matchedList = await _fetchNameMatches(
            collectionName: 'products',
            prefix: pfx,
            tokens: tokens,
            resultLimit: 30,
          );
          for (final product in matchedList) {
            combinedDocs[product['id'].toString()] = product;
          }
        }));

        final filteredList = combinedDocs.values.where((p) {
          final name = p['name']?.toString() ?? '';
          return _matchesTokens(name, tokens) || _matchesBarcode(p, q);
        }).toList();

        ImagePrecacheService.instance.prewarmProducts(filteredList);
        return filteredList.take(30).toList();
      }),
      _safeQuery('brands', () async {
        final combined = <String, Map<String, dynamic>>{};
        await Future.wait(prefixesToQuery.map((pfx) async {
          final items = await _fetchNameMatches(
            collectionName: 'brands',
            prefix: pfx,
            tokens: tokens,
            resultLimit: 15,
          );
          for (final item in items) {
            combined[item['id'].toString()] = item;
          }
        }));
        final list = combined.values.take(15).toList();
        ImagePrecacheService.instance.prewarmBrands(list);
        return list;
      }),
      _safeQuery('categories', () async {
        final combined = <String, Map<String, dynamic>>{};
        await Future.wait(prefixesToQuery.map((pfx) async {
          final items = await _fetchNameMatches(
            collectionName: 'categories',
            prefix: pfx,
            tokens: tokens,
            resultLimit: 10,
          );
          for (final item in items) {
            combined[item['id'].toString()] = item;
          }
        }));
        final list = combined.values.take(10).toList();
        ImagePrecacheService.instance.prewarmCategories(list);
        return list;
      }),
    ]);
    final result = SearchResult(
      products: results[0],
      brands: results[1],
      categories: results[2],
    );

    _putInCache(q, result);
    return result;
  }

  Future<List<Map<String, dynamic>>> _fetchNameMatches({
    required String collectionName,
    required String prefix,
    required List<String> tokens,
    required int resultLimit,
  }) async {
    const pageSize = 60;
    final collection = _db.collection(collectionName);
    final matches = <String, Map<String, dynamic>>{};
    DocumentSnapshot<Map<String, dynamic>>? cursor;

    // 1. البحث السحابي المباشر بالبادئة الأولى
    while (matches.length < resultLimit) {
      Query<Map<String, dynamic>> query = collection
          .where('name', isGreaterThanOrEqualTo: prefix)
          .where('name', isLessThanOrEqualTo: '$prefix\uf8ff')
          .orderBy('name')
          .limit(pageSize);
      if (cursor != null) query = query.startAfterDocument(cursor);

      final page =
          await query.get(const GetOptions(source: Source.serverAndCache));
      if (page.docs.isEmpty) break;

      for (final doc in page.docs) {
        final data = doc.data();
        if (data['is_deleted'] == true || data['is_active'] == false) {
          continue;
        }
        final product = {'id': doc.id, ...data};
        if (_matchesTokens(data['name']?.toString() ?? '', tokens)) {
          matches[doc.id] = product;
          if (matches.length >= resultLimit) break;
        }
      }

      if (matches.length >= resultLimit || page.docs.length < pageSize) break;
      cursor = page.docs.last;
    }
// 2. بحث موسع مطبّع في الكاش ثم دفعة السيرفر (للكلمات الوسطى واختلاف ة/ه وى/ي)
    if (matches.length < resultLimit) {
      final cachedList = switch (collectionName) {
        'products' => AppCache.instance.getAllCachedProducts(),
        'brands' => AppCache.instance.getBrands() ?? const [],
        'categories' => AppCache.instance.getCategories() ?? const [],
        _ => const <Map<String, dynamic>>[],
      };

      for (final item in cachedList) {
        if (item['is_deleted'] == true || item['is_active'] == false) {
          continue;
        }
        if (_matchesTokens(item['name']?.toString() ?? '', tokens)) {
          matches[item['id'].toString()] = item;
          if (matches.length >= resultLimit) break;
        }
      }

      if (matches.length < resultLimit) {
        final fallbackLimit = collectionName == 'products' ? 300 : 150;
        final fallbackSnap = await collection
            .where('is_deleted', isEqualTo: false)
            .limit(fallbackLimit)
            .get(const GetOptions(source: Source.serverAndCache));
        for (final doc in fallbackSnap.docs) {
          final data = doc.data();
          if (data['is_active'] == false) continue;
          if (_matchesTokens(data['name']?.toString() ?? '', tokens)) {
            matches[doc.id] = {'id': doc.id, ...data};
            if (matches.length >= resultLimit) break;
          }
        }
      }
    }
    return matches.values.toList(growable: false);
  }

  bool _matchesBarcode(Map<String, dynamic> product, String query) {
    final cleanQ = ArabicNormalizer.normalizeDigits(query).trim().toLowerCase();
    if (cleanQ.isEmpty) return false;

    bool matches(Object? value) =>
        value?.toString().trim().toLowerCase().contains(cleanQ) ?? false;

    if (matches(product['barcode'])) return true;
    final barcodes = product['all_barcodes'];
    if (barcodes is List && barcodes.any(matches)) return true;
    final units = product['units'];
    if (units is List &&
        units.any((unit) => unit is Map && matches(unit['barcode']))) {
      return true;
    }
    final variants = product['variants'];
    return variants is List &&
        variants.any((v) =>
            v is Map &&
            (matches(v['barcode']) ||
                (v['units'] is List &&
                    (v['units'] as List)
                        .any((vu) => vu is Map && matches(vu['barcode'])))));
  }

  Future<List<Map<String, dynamic>>> _safeQuery(
    String tableName,
    Future<List<Map<String, dynamic>>> Function() query,
  ) async {
    try {
      return await query();
    } catch (e, st) {
      if (kDebugMode) debugPrint('SEARCH ERROR [$tableName]: $e');
      if (!kIsWeb) {
        FirebaseCrashlytics.instance
            .recordError(e, st, reason: 'Search query error in $tableName');
      }
      return [];
    }
  }

  static void clearCache() => _cache.clear();
}

final searchServiceProvider = Provider<SearchService>((ref) => SearchService());
final searchQueryProvider = StateProvider<String>((ref) => '');

final searchResultsProvider = StreamProvider.autoDispose
    .family<SearchResult, String>((ref, query) async* {
  final cleanQ = query.trim().toLowerCase();
  if (cleanQ.isEmpty) {
    yield const SearchResult(products: [], brands: [], categories: []);
    return;
  }

  final cached = _cache[cleanQ];
  if (cached != null &&
      DateTime.now().difference(cached.cachedAt) < SearchService._cacheTtl) {
    yield cached.result;
    return;
  }

  final service = ref.read(searchServiceProvider);
  final local = service._searchLocally(cleanQ);
  if (local != null && !local.isEmpty) {
    yield local;
  }

  final fresh = await service._fetchAndUpdateCache(cleanQ);
  if (!fresh.isEmpty || local == null || local.isEmpty) {
    yield fresh;
  }
});
