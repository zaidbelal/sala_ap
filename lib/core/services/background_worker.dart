import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:wissal/core/utils/arabic_normalizer.dart';

/// مسار معالجة خلفي (Isolate) لتنفيذ مهام فك وتشفير الـ JSON والفرز لمنع تعليق الشاشة تماماً (120 FPS)
class BackgroundWorker {
  BackgroundWorker._();

  static Future<List<Map<String, dynamic>>?> decodeJsonList(String rawJson) {
    return compute(_isolateDecodeJsonList, rawJson);
  }

  static Future<String> encodeJsonList(List<Map<String, dynamic>> list) {
    return compute(_isolateEncodeJsonList, list);
  }

  static Future<List<Map<String, dynamic>>> filterAndSortCatalog({
    required List<Map<String, dynamic>> items,
    required String query,
  }) {
    return compute(_isolateFilterAndSort, {
      'items': items,
      'query': query,
    });
  }

  // ── دوال التشفير الداخلية المنفذة داخل الـ Isolate المعزول ──

  static List<Map<String, dynamic>>? _isolateDecodeJsonList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return List<Map<String, dynamic>>.from(
          decoded.map((e) => Map<String, dynamic>.from(e as Map)),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _isolateEncodeJsonList(List<Map<String, dynamic>> data) {
    return jsonEncode(data);
  }

  static List<Map<String, dynamic>> _isolateFilterAndSort(
      Map<String, dynamic> args) {
    final List<Map<String, dynamic>> rawItems = (args['items'] as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final String q = (args['query'] as String? ?? '').trim().toLowerCase();

    final normQ = ArabicNormalizer.normalize(q);

    final filtered = normQ.isEmpty
        ? rawItems
        : rawItems.where((item) {
            final name =
                ArabicNormalizer.normalize(item['name']?.toString() ?? '');
            final barcode = item['barcode']?.toString() ?? '';
            final allBarcodes = item['all_barcodes'];
            final matchesAllBarcodes = allBarcodes is List &&
                allBarcodes.any((b) => b?.toString().contains(normQ) ?? false);
            final units = item['units'];
            final matchesUnits = units is List &&
                units.any((u) =>
                    u is Map &&
                    (u['barcode']?.toString().contains(normQ) ?? false));
            return name.contains(normQ) ||
                barcode.contains(normQ) ||
                matchesAllBarcodes ||
                matchesUnits;
          }).toList();
    filtered.sort((a, b) {
      final aOrder = (a['sort_order'] as num?)?.toInt() ?? 999;
      final bOrder = (b['sort_order'] as num?)?.toInt() ?? 999;
      if (aOrder != bOrder) return aOrder.compareTo(bOrder);
      return (a['name']?.toString() ?? '')
          .compareTo(b['name']?.toString() ?? '');
    });

    return filtered;
  }
}
