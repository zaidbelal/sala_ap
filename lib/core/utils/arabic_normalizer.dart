import 'package:cloud_firestore/cloud_firestore.dart';

class ArabicNormalizer {
  ArabicNormalizer._();

  static const Map<String, String> _numeralsMap = {
    '٠': '0',
    '١': '1',
    '٢': '2',
    '٣': '3',
    '٤': '4',
    '٥': '5',
    '٦': '6',
    '٧': '7',
    '٨': '8',
    '٩': '9',
    '۰': '0',
    '۱': '1',
    '۲': '2',
    '۳': '3',
    '۴': '4',
    '۵': '5',
    '۶': '6',
    '۷': '7',
    '۸': '8',
    '۹': '9',
  };

  static final RegExp _diacriticsRegex = RegExp(r'[\u064B-\u065F\u0670\u0640]');
  static final RegExp _alefRegex = RegExp(r'[أإآٱ]');
  static final RegExp _spacesRegex = RegExp(r'\s+');

  /// تطبيع قياسي للبحث والفرز
  static String normalize(String text) {
    if (text.isEmpty) return '';
    var clean = text.trim();
    clean = clean.replaceAll(_diacriticsRegex, '');
    clean = clean.replaceAll(_alefRegex, 'ا');
    clean = clean
        .replaceAll('ة', 'ه')
        .replaceAll('ى', 'ي')
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي')
        .replaceAll('ء', '');
    _numeralsMap.forEach((ar, en) => clean = clean.replaceAll(ar, en));
    return clean.replaceAll(_spacesRegex, ' ').toLowerCase().trim();
  }

  /// تطبيع مخصص للمواقع والأسماء بلهجة صنعاء
  static String normalizeDialect(String text) {
    return normalize(text).replaceAll('ظ', 'ض');
  }

  /// تقسيم النص إلى كلمات بحثية مطبعة
  static List<String> tokenize(String query) {
    return normalize(query)
        .split(' ')
        .where((token) => token.trim().length > 1)
        .toList();
  }

  /// تحويل الأرقام العربية المشرقية والفارسية إلى أرقام لاتينية (آمن للـ Isolates)
  static String normalizeDigits(String text) {
    if (text.isEmpty) return '';
    var clean = text;
    _numeralsMap.forEach((ar, en) => clean = clean.replaceAll(ar, en));
    return clean;
  }

  /// فحص مطابقة الكلمات
  static bool matches(String target, List<String> tokens) {
    if (tokens.isEmpty) return true;
    final normalizedTarget = normalize(target);
    return tokens.every((token) => normalizedTarget.contains(token));
  }
}

/// فئة معمارية موحدة لمعالجة وفرز وتنسيق كافة تواريخ التطبيق (Single Source of Truth)
class AppDateParser {
  AppDateParser._();

  static DateTime parse(dynamic value, [DateTime? fallback]) {
    if (value == null) return fallback ?? DateTime(2000);
    if (value is DateTime) return value;
    if (value is dynamic && value.runtimeType.toString() == 'Timestamp') {
      return (value as dynamic).toDate() as DateTime;
    }
    if (value is String && value.trim().isNotEmpty) {
      return DateTime.tryParse(value.trim()) ?? (fallback ?? DateTime(2000));
    }
    return fallback ?? DateTime(2000);
  }

  static String formatDate(dynamic value, {bool includeTime = false}) {
    final dt = parse(value);
    final dateStr =
        '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
    if (!includeTime) return dateStr;
    final timeStr =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '$dateStr  $timeStr';
  }
}
