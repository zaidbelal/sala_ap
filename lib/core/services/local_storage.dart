import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// ═══════════════════════════════════════════════════════════
/// LocalStorage — خدمة التخزين المحلي لمنصة وَمْض
/// نمط Singleton مع تهيئة مسبقة في main.dart
/// ═══════════════════════════════════════════════════════════
class AppStorage {
  AppStorage._();

  static SharedPreferences? _prefs;
  static bool _initialized = false;
  static String? _appDocsPath;
  static String? get appDocsPath => _appDocsPath;
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  // ══════════════════════════════════════════
  // المفاتيح — private constants
  // ══════════════════════════════════════════
  static const _kUserId = 'user_id';
  static const _kUserRole = 'user_role';
  static const _kUserName = 'user_name';
  static const _kStoreName = 'store_name';
  static const _kUserPhone = 'user_phone';
  static const _kWarehouseId = 'warehouse_id';
  static const _kFcmToken = 'fcm_token';
  static const _kFirstLaunch = 'first_launch';
  static const _kAppVersion = 'app_version';
  static const _kThemeMode = 'theme_mode'; // 'light' | 'dark' | 'system'
  static const _kLanguage = 'language'; // 'ar' | 'en'
  static const _kLastLoginAt = 'last_login_at';
  static const _kSessionToken = 'session_token';
  static const _kNotifEnabled = 'notif_enabled';
  static const _kOnboardingDone = 'onboarding_done';
  static const _kIsActive = 'is_active';
  static const _kIsBanned = 'is_banned';
  // ══════════════════════════════════════════
  // التهيئة — يُستدعى مرة واحدة في main.dart
  // ══════════════════════════════════════════
  static Future<void> initialize() async {
    if (_initialized) return;
    try {
      _prefs = await SharedPreferences.getInstance();
      if (!kIsWeb) {
        try {
          final dir = await getApplicationDocumentsDirectory();
          _appDocsPath = dir.path;
        } catch (_) {}
      }
      _initialized = true;
      if (kDebugMode) debugPrint('✅ LocalStorage: initialized');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ LocalStorage: failed to initialize — $e');
      rethrow;
    }
  }

  static SharedPreferences get _db {
    if (!_initialized || _prefs == null) {
      throw StateError(
        '❌ LocalStorage لم يتم تهيئته — استدعِ AppStorage.initialize() في main.dart أولاً',
      );
    }
    return _prefs!;
  }

  // ══════════════════════════════════════════
  // حالة التهيئة
  // ══════════════════════════════════════════
  static bool get isInitialized => _initialized;

  // ╔══════════════════════════════════════════╗
  // ║           بيانات المستخدم               ║
  // ╚══════════════════════════════════════════╝
  static Future<void> clearUserData() async {
    final uid = userId;
    final clearSecureStorage = _secureStorage
        .delete(key: _kSessionToken)
        .timeout(const Duration(seconds: 2), onTimeout: () => null)
        .catchError((_) => null);

    final clearCartFile = Future<void>(() async {
      if (uid != null && !kIsWeb) {
        try {
          final dir = await getApplicationDocumentsDirectory();
          final file = File('${dir.path}/wamd_cart_v2_$uid.json');
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    });
    await Future.wait([
      clearSecureStorage,
      clearCartFile,
      _db.remove('first_login_at'),
      _db.remove(_kLastLoginAt),
      _db.remove(_kFcmToken),
      _db.remove(_kIsActive),
      _db.remove(_kIsBanned),
      _db.remove(_kUserId),
      _db.remove(_kUserRole),
      _db.remove(_kUserName),
      _db.remove(_kStoreName),
      _db.remove(_kUserPhone),
      _db.remove(_kWarehouseId),
      if (uid != null) _db.remove('wamd_cart_v2_$uid'),
    ]);
    if (kDebugMode) {
      debugPrint('🗑️ LocalStorage: user data cleared safely');
    }
  }

  // ── Getters ──
  static String? get userId => _db.getString(_kUserId);
  static String? get userRole => _db.getString(_kUserRole);
  static String? get userName => _db.getString(_kUserName);
  static String? get storeName => _db.getString(_kStoreName);
  static String? get userPhone => _db.getString(_kUserPhone);
  static String? get warehouseId => _db.getString(_kWarehouseId);
  static String? get fcmToken => _db.getString(_kFcmToken);
  static Future<String?> getSessionToken() async {
    try {
      return await _secureStorage
          .read(key: _kSessionToken)
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  static String? get lastLoginAt => _db.getString(_kLastLoginAt);

  // ── فحص تسجيل الدخول ──
  static bool get isLoggedIn => userId != null && userId!.isNotEmpty;
  static bool get isActive => _db.getBool(_kIsActive) ?? false;
  static Future<void> setIsActive(bool value) => _db.setBool(_kIsActive, value);

  static bool get isBanned => _db.getBool(_kIsBanned) ?? false;
  static Future<void> setIsBanned(bool value) => _db.setBool(_kIsBanned, value);
  // ── آخر وقت دخول كـ DateTime ──
  static DateTime? get lastLoginDateTime {
    final raw = lastLoginAt;
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  // ╔══════════════════════════════════════════╗
  // ║            أدوار المستخدمين             ║
  // ╚══════════════════════════════════════════╝
  static String get normalizedUserRole => (userRole ?? '').trim().toLowerCase();

  static bool get isMerchant => normalizedUserRole == 'merchant';

  static bool get isDriver => normalizedUserRole == 'driver';

  static bool get isAdmin =>
      normalizedUserRole == 'admin' || normalizedUserRole == 'super_admin';

  static bool get isAccountant => normalizedUserRole == 'accountant';

  static bool get isWarehouseManager =>
      normalizedUserRole == 'warehouse_manager';
  static bool get hasAdminAccess =>
      isAdmin || isAccountant || isWarehouseManager;

  // ╔══════════════════════════════════════════╗
  // ║             إعدادات التطبيق             ║
  // ╚══════════════════════════════════════════╝

  // ── الفتح الأول ──
  static bool get isFirstLaunch => _db.getBool(_kFirstLaunch) ?? true;
  static Future<void> markLaunched() => _db.setBool(_kFirstLaunch, false);

  // ── الإعداد الأولي (Onboarding) ──
  static bool get isOnboardingDone => _db.getBool(_kOnboardingDone) ?? false;
  static Future<void> markOnboardingDone() =>
      _db.setBool(_kOnboardingDone, true);

  // ── الثيم ──
  static String get themeMode => _db.getString(_kThemeMode) ?? 'system';
  static Future<void> saveThemeMode(String mode) =>
      _db.setString(_kThemeMode, mode);

  // ── اللغة ──
  static String get language => _db.getString(_kLanguage) ?? 'ar';
  static Future<void> saveLanguage(String lang) =>
      _db.setString(_kLanguage, lang);

  // ── الإشعارات ──
  static bool get notificationsEnabled => _db.getBool(_kNotifEnabled) ?? true;
  static Future<void> setNotifications(bool enabled) =>
      _db.setBool(_kNotifEnabled, enabled);

  // ── إصدار التطبيق ──
  static String? get appVersion => _db.getString(_kAppVersion);
  static Future<void> saveAppVersion(String version) =>
      _db.setString(_kAppVersion, version);

  // ╔══════════════════════════════════════════╗
  // ║              FCM Token                  ║
  // ╚══════════════════════════════════════════╝
  static Future<void> saveFcmToken(String token) async {
    if (fcmToken == token) return; // لا تحديث إذا لم يتغير
    await _db.setString(_kFcmToken, token);
    if (kDebugMode) debugPrint('🔔 LocalStorage: FCM token updated');
  }

  // ╔══════════════════════════════════════════╗
  // ║          قيم عامة (Generic API)         ║
  // ╚══════════════════════════════════════════╝
  static Future<void> setString(String key, String value) =>
      _db.setString(key, value);
  static Future<void> setBool(String key, bool value) =>
      _db.setBool(key, value);
  static Future<void> setInt(String key, int value) => _db.setInt(key, value);
  static Future<void> remove(String key) => _db.remove(key);

  static String? getString(String key) => _db.getString(key);
  static bool? getBool(String key) => _db.getBool(key);
  static int? getInt(String key) => _db.getInt(key);
  static bool hasKey(String key) => _db.containsKey(key);

  // ╔══════════════════════════════════════════╗
  // ║                  المسح                  ║
  // ╚══════════════════════════════════════════╝
  static Future<void> saveUserData({
    required String userId,
    required String role,
    String? name,
    String? storeName,
    String? phone,
    String? warehouseId,
    String? sessionToken,
  }) async {
    final nowIso = DateTime.now().toIso8601String();
    final batch = <Future>[
      _db.setString(_kUserId, userId),
      _db.setString(_kUserRole, role),
      _db.setString(_kLastLoginAt, nowIso),
    ];
    // ✅ كتابة تاريخ أول دخول إذا لم يكن مسجلاً لتفعيل سقف الـ 90 يوماً
    if (!hasKey('first_login_at')) {
      batch.add(_db.setString('first_login_at', nowIso));
    }
    if (name != null) batch.add(_db.setString(_kUserName, name));
    if (storeName != null) batch.add(_db.setString(_kStoreName, storeName));
    if (phone != null) batch.add(_db.setString(_kUserPhone, phone));
    if (warehouseId != null) {
      batch.add(_db.setString(_kWarehouseId, warehouseId));
    }
    if (sessionToken != null) {
      try {
        await _secureStorage
            .write(key: _kSessionToken, value: sessionToken)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    await Future.wait(batch.cast<Future<void>>());
    if (kDebugMode) debugPrint('💾 LocalStorage: user saved — role=$role');
  }

  /// مسح كل شيء مع الاحتفاظ بحالة الفتح الأول والإعدادات
  static Future<void> clearAll() async {
    final isFirst = isFirstLaunch;
    final theme = themeMode;
    final lang = language;
    final onboard = isOnboardingDone;

    await _db.clear();

    await Future.wait([
      _db.setBool(_kFirstLaunch, isFirst),
      _db.setString(_kThemeMode, theme),
      _db.setString(_kLanguage, lang),
      _db.setBool(_kOnboardingDone, onboard),
    ]);
    if (kDebugMode) {
      debugPrint('🗑️ LocalStorage: cleared all (settings preserved)');
    }
  }

  /// مسح شامل كامل — عند حذف الحساب فقط
  static Future<void> nukeAll() async {
    await _db.clear();
    if (kDebugMode) debugPrint('💥 LocalStorage: full wipe');
  }

  // ╔══════════════════════════════════════════╗
  // ║            Debug / DevTools             ║
  // ╚══════════════════════════════════════════╝
  @visibleForTesting
  static void debugPrintAll() {
    assert(kDebugMode, 'debugPrintAll يجب ألا يُستدعى في production');
    if (!kDebugMode) return;
    final keys = _db.getKeys().where((k) => k != _kSessionToken).toList();
    debugPrint('━━━━━━ LocalStorage Debug ━━━━━━');
    for (final key in keys) {
      debugPrint('  $key = ${_db.get(key)}');
    }
    debugPrint('  session_token = [REDACTED]');
    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  }
}
