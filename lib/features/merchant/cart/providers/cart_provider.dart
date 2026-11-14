import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wissal/core/services/local_storage.dart';
import 'package:wissal/core/models/product_unit.dart';
import '../models/cart_item_model.dart';
import '../../products/services/products_service.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

final cartProvider =
    StateNotifierProvider<CartNotifier, Map<String, CartItem>>((ref) {
  return CartNotifier();
});

final cartTotalProvider = Provider<double>((ref) {
  final cart = ref.watch(cartProvider);
  return cart.values.fold(0.0, (sum, item) => sum + item.total);
});

final cartCountProvider = Provider<int>((ref) {
  final cart = ref.watch(cartProvider);
  return cart.values.fold(0, (sum, item) => sum + item.quantity);
});

class CartNotifier extends StateNotifier<Map<String, CartItem>> {
  CartNotifier() : super({}) {
    _loadFuture = _load();
  }

  late final Future<void> _loadFuture;
  static String get _key {
    final uid = AppStorage.userId ?? 'guest';
    return 'wissal_cart_v2_$uid';
  }

  static const int _maxQuantity = 999;
  final _repository = const CartStorageRepository();
  bool _isLoaded = false;
  final List<VoidCallback> _pendingMutations = [];
  Future<void> _cartSaveChain = Future.value();
  Timer? _saveDebounceTimer;
  Future<void> _load() async {
    if (kIsWeb) {
      _isLoaded = true;
      return;
    }
    try {
      var loaded = await _repository.readCart(_key);

      final currentUid = AppStorage.userId;
      if (currentUid != null && currentUid.isNotEmpty) {
        const guestKey = 'wissal_cart_v2_guest';
        final guestCart = await _repository.readCart(guestKey);
        if (guestCart != null && guestCart.isNotEmpty) {
          final mergedCart = Map<String, CartItem>.from(loaded ?? {});
          guestCart.forEach((key, guestItem) {
            if (mergedCart.containsKey(key)) {
              final existing = mergedCart[key]!;
              mergedCart[key] = existing.copyWith(
                quantity: (existing.quantity + guestItem.quantity)
                    .clamp(1, _maxQuantity),
              );
            } else {
              mergedCart[key] = guestItem;
            }
          });
          loaded = mergedCart;
          await _repository.saveCart(
            key: _key,
            items: mergedCart,
          );
          await _repository.deleteCart(guestKey);
        }
      }

      if (loaded != null && loaded.isNotEmpty) {
        final merged = Map<String, CartItem>.from(loaded);
        state.forEach((key, freshItem) {
          if (merged.containsKey(key)) {
            final diskItem = merged[key]!;
            final combinedQty =
                (diskItem.quantity + freshItem.quantity).clamp(1, _maxQuantity);
            merged[key] = diskItem.copyWith(quantity: combinedQty);
          } else {
            merged[key] = freshItem;
          }
        });
        state = merged;
      }
    } catch (e, st) {
      if (kDebugMode) debugPrint('❌ CartNotifier._load failed: $e\n$st');
    } finally {
      _isLoaded = true;
      if (_pendingMutations.isNotEmpty) {
        for (final mutation in _pendingMutations) {
          mutation();
        }
        _pendingMutations.clear();
      }
    }
  }

  void _save() {
    if (!_isLoaded) {
      _pendingMutations.add(() => _save());
      return;
    }

    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 250), () {
      _flushSaveToDisk();
    });
  }

  void _flushSaveToDisk() {
    final itemsSnapshot = Map<String, CartItem>.from(state);

    _cartSaveChain = _cartSaveChain.then((_) async {
      await _loadFuture;
      await _repository.saveCart(
        key: _key,
        items: itemsSnapshot,
      );
    }).catchError((Object error, StackTrace stackTrace) {
      if (kDebugMode) {
        debugPrint('Cart persistence failed: $error\n$stackTrace');
      }
      if (!kIsWeb) {
        FirebaseCrashlytics.instance
            .recordError(error, stackTrace, reason: 'Cart persistence failed');
      }
    });
  }

  Future<void> forceSave() async {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    _flushSaveToDisk();
    await _loadFuture;
    return _cartSaveChain;
  }

  @override
  void dispose() {
    _saveDebounceTimer?.cancel();
    super.dispose();
  }

  void changeItemUnit(CartItem oldItem, ProductUnit newUnit) {
    final oldKey = oldItem.cartKey;
    final newItem = CartItem(
      product: oldItem.product,
      quantity: oldItem.quantity.clamp(1, _maxQuantity),
      selectedUnit: newUnit,
      selectedVariant: oldItem.selectedVariant,
    );
    final newKey = newItem.cartKey;

    if (oldKey == newKey) return;

    final newState = Map<String, CartItem>.from(state);
    newState.remove(oldKey);

    if (newState.containsKey(newKey)) {
      final existing = newState[newKey]!;
      newState[newKey] = existing.copyWith(
        quantity: (existing.quantity + oldItem.quantity).clamp(1, _maxQuantity),
      );
    } else {
      newState[newKey] = newItem;
    }
    state = newState;
    _save();
  }

  void addItem(
    ProductModel product,
    int quantity, {
    ProductUnit? unit,
    ProductVariant? variant,
  }) {
    if (quantity <= 0) return;
    final item = CartItem(
      product: product,
      quantity: quantity,
      selectedUnit: unit,
      selectedVariant: variant,
    );
    final key = item.cartKey;
    final existing = state[key];
    final currentQty = existing?.quantity ?? 0;
    final newQty = (currentQty + quantity).clamp(1, _maxQuantity);

    state = {
      ...state,
      key: item.copyWith(quantity: newQty),
    };
    _save();
  }

  void setQuantity(CartItem item, int quantity) {
    final key = item.cartKey;
    if (quantity <= 0) {
      removeItem(key);
      return;
    }
    final existing = state[key] ?? item;
    state = {
      ...state,
      key: existing.copyWith(quantity: quantity.clamp(1, _maxQuantity)),
    };
    _save();
  }

  void removeItem(String cartKey) {
    if (!state.containsKey(cartKey)) return;
    final newState = Map<String, CartItem>.from(state)..remove(cartKey);
    state = newState;
    _save();
  }

  void incrementItem(CartItem item) {
    final key = item.cartKey;
    final existing = state[key];
    if (existing == null) {
      addItem(item.product, 1, unit: item.selectedUnit);
      return;
    }
    if (existing.quantity >= _maxQuantity) return;
    state = {
      ...state,
      key: existing.copyWith(quantity: existing.quantity + 1),
    };
    _save();
  }

  void decrementItem(CartItem item) {
    final key = item.cartKey;
    final existing = state[key];
    if (existing == null) return;
    if (existing.quantity <= 1) {
      removeItem(key);
      return;
    }
    state = {
      ...state,
      key: existing.copyWith(quantity: existing.quantity - 1),
    };
    _save();
  }

  Future<void> clearAsync() async {
    await _loadFuture;
    state = {};
    await forceSave();
  }

  void clear() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    state = {};
    _flushSaveToDisk();
  }

  int quantityOf(String cartKey) => state[cartKey]?.quantity ?? 0;

  bool validateAndUpdatePrices(
    List<Map<String, dynamic>> latestProducts, {
    Set<String>? queriedBatchIds,
  }) {
    if (state.isEmpty) return false;
    bool hasChanges = false;
    final Map<String, CartItem> resolvedMap = {};
    final returnedProductsMap = {
      for (final p in latestProducts) p['id']?.toString(): p
    };

    for (final entry in state.entries) {
      final item = entry.value;
      final productId = item.product.id;

      if (queriedBatchIds != null && !queriedBatchIds.contains(productId)) {
        resolvedMap[entry.key] = item;
        continue;
      }

      final liveProductMap = returnedProductsMap[productId];

      if (liveProductMap == null ||
          liveProductMap.isEmpty ||
          liveProductMap['is_deleted'] == true ||
          liveProductMap['is_active'] == false) {
        hasChanges = true;
        continue;
      }
      final liveProduct = ProductModel.fromMap(liveProductMap);
      final currentLabel = item.selectedUnit?.label.trim() ?? 'كرتون';

      ProductVariant? matchingVariant;
      if (item.selectedVariant != null) {
        matchingVariant = liveProduct.variants
            .where((v) =>
                v.id == item.selectedVariant!.id ||
                v.label.trim() == item.selectedVariant!.label.trim())
            .firstOrNull;
        if (matchingVariant == null) {
          hasChanges = true;
          continue;
        }
      }

      final unitSource =
          matchingVariant != null ? matchingVariant.units : liveProduct.units;
      ProductUnit? matchingUnit =
          unitSource.where((u) => u.label.trim() == currentLabel).firstOrNull;

      if (matchingUnit == null && currentLabel == 'كرتون') {
        matchingUnit = ProductUnit(
          label: 'كرتون',
          qty: matchingVariant?.itemsPerCarton ??
              liveProduct.itemsPerCarton ??
              1,
          price: matchingVariant?.price ?? liveProduct.price,
          imageUrl: matchingVariant?.imageUrl ?? liveProduct.imageUrl,
          sizeMl: matchingVariant?.sizeMl ?? liveProduct.sizeMl,
        );
      }

      if (matchingUnit == null) {
        hasChanges = true;
        continue;
      }

      final availableStock = matchingVariant?.stock ?? liveProduct.stock;
      final cartonCapacity =
          matchingVariant?.itemsPerCarton ?? liveProduct.itemsPerCarton ?? 1;
      final unitQty = matchingUnit.qty > 0 ? matchingUnit.qty : 1;
      final maxUnitsAllowed =
          ((availableStock * (cartonCapacity > 0 ? cartonCapacity : 1)) /
                  unitQty)
              .floor();

      if (maxUnitsAllowed <= 0) {
        hasChanges = true;
        continue;
      }

      final safeQty = item.quantity.clamp(1, maxUnitsAllowed);
      if (safeQty != item.quantity ||
          matchingUnit.price != item.unitPrice ||
          liveProduct.price != item.product.price) {
        hasChanges = true;
      }

      final updatedItem = CartItem(
        product: liveProduct,
        quantity: safeQty,
        selectedUnit: matchingUnit,
        selectedVariant: matchingVariant,
      );
      final targetKey = updatedItem.cartKey;
      if (resolvedMap.containsKey(targetKey)) {
        final existing = resolvedMap[targetKey]!;
        resolvedMap[targetKey] = existing.copyWith(
          quantity:
              (existing.quantity + updatedItem.quantity).clamp(1, _maxQuantity),
        );
        hasChanges = true;
      } else {
        resolvedMap[targetKey] = updatedItem;
      }
    }

    if (hasChanges || resolvedMap.length != state.length) {
      state = resolvedMap;
      _save();
      return true;
    }
    return false;
  }
}

class CartStorageRepository {
  const CartStorageRepository();

  Future<File?> _getFile(String name) async {
    if (kIsWeb) return null;
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$name');
  }

  Future<Map<String, CartItem>?> readCart(String key) async {
    String? raw;
    final file = await _getFile('$key.json');
    if (file != null && await file.exists()) {
      try {
        raw = await file.readAsString();
      } catch (_) {}
    }

    // 🛡️ تراجع آمن (Fallback): إذا لم يتوفر الملف يُقرأ الكاش البديل من AppStorage فوراً
    if (raw == null || raw.trim().isEmpty || raw.trim() == '{}') {
      raw = AppStorage.getString(key);
    }

    if (raw == null || raw.trim().isEmpty || raw.trim() == '{}') return null;

    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map(
          (k, v) => MapEntry(k, CartItem.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteCart(String key) async {
    if (kIsWeb) return;
    try {
      final file = await _getFile('$key.json');
      if (file != null && await file.exists()) await file.delete();
      await AppStorage.remove(key);
    } catch (_) {}
  }

  Future<void> saveCart({
    required String key,
    required Map<String, CartItem> items,
  }) async {
    if (kIsWeb) return;
    final file = await _getFile('$key.json');
    if (file == null) return;

    if (items.isEmpty) {
      if (await file.exists()) await file.delete();
      await AppStorage.remove(key);
      return;
    }
    final jsonString = jsonEncode(
      items.map((k, v) => MapEntry(k, v.toJson())),
      toEncodable: (nonEncodable) {
        if (nonEncodable is Timestamp) {
          return nonEncodable.toDate().toIso8601String();
        }
        if (nonEncodable is DateTime) {
          return nonEncodable.toIso8601String();
        }
        return nonEncodable.toString();
      },
    );
    await file.writeAsString(jsonString, flush: true);
    await AppStorage.setString(key, jsonString);
  }
}
