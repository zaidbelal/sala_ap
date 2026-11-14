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
