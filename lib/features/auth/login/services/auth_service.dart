import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/services/app_cache.dart';
import '../../../../core/services/local_storage.dart';
import '../../../../core/services/firebase_service.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/services/realtime_hub.dart';
import 'quickconnect_otp_service.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:wissal/core/services/catalog_service.dart';
import 'package:wissal/core/services/prefetch_service.dart';
import 'package:wissal/features/merchant/cart/providers/cart_provider.dart';
import 'package:wissal/features/merchant/search/services/search_service.dart';
import 'package:wissal/features/merchant/barcode/barcode_scanner_screen.dart';
import 'package:wissal/core/services/connectivity_service.dart';

class OtpVerifyResponse {
  final bool success;
  final bool isDisabled;
  final String message;
  final String? customToken;

  const OtpVerifyResponse({
    required this.success,
    this.isDisabled = false,
    required this.message,
    this.customToken,
  });
}

class PhoneVerificationSession {
  final String verificationId;
  final int? resendToken;

  const PhoneVerificationSession({
    required this.verificationId,
    this.resendToken,
  });
}

final authServiceProvider = Provider<AuthService>(
  (ref) => AuthService(),
);

class AuthService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // كانت static من قبل، وهذا خطأ معماري خطير:
  // أي Instance جديد من AuthService (مثلاً في الاختبارات، أو لو تم بناؤه
  // يدويًا في مكان آخر) كان سيشارك نفس القفل مع الـ Provider الرئيسي،
  // مما قد يسبب "يوجد طلب قيد التنفيذ" بشكل خاطئ لمستخدم مختلف تمامًا.
  bool _otpRequestRunning = false;

  /// توحيد صيغة رقم الهاتف اليمني.
  ///
  /// الصيغ المدعومة:
  /// 7XXXXXXXX
  /// 07XXXXXXXX
  /// 9677XXXXXXXX
  /// +9677XXXXXXXX
  // رقم الدولة مُدمج داخل الدالة (+967) بشكل صريح، وهذا يمنع التوسع
  // مستقبلاً لأي دولة أخرى دون تعديل منطق التحقق بالكامل.
  // يُفضّل استخراجه كـ constant قابل للتهيئة (AppConfig.countryCode)
  // ليصبح formatPhone دالة عامة لا مرتبطة بدولة واحدة مباشرة.
  static const defaultCountryCode = '+967';
  static const localPrefix = '0';
  static const requiredLength = 9;
  static const validStartDigit = '7';
  static String formatPhone(String phone) {
    // ✅ تحويل الأرقام العربية المشرقية تلقائياً إلى أرقام لاتينية قياسية
    final normalized = QuickConnectOtpService.normalizeCode(phone);
    final raw = normalized.trim().replaceAll(RegExp(r'[\s()-]'), '');

    if (raw.isEmpty) {
      throw const FormatException('أدخل رقم الهاتف');
    }
    final value = raw.startsWith('00') ? '+${raw.substring(2)}' : raw;
    final countryCodeDigits = defaultCountryCode.replaceAll('+', '');

    if (value.startsWith(defaultCountryCode) &&
        value.length == defaultCountryCode.length + requiredLength) {
      return value;
    }

    if (value.startsWith(countryCodeDigits) &&
        value.length == countryCodeDigits.length + requiredLength) {
      return '+$value';
    }

    if (value.startsWith('$localPrefix$validStartDigit') &&
        value.length == requiredLength + localPrefix.length) {
      return '$defaultCountryCode${value.substring(localPrefix.length)}';
    }

    if (value.startsWith(validStartDigit) && value.length == requiredLength) {
      return '$defaultCountryCode$value';
    }

    throw FormatException(
        'رقم الهاتف يجب أن يكون $requiredLength أرقام ويبدأ بالرقم $validStartDigit');
  }

  Future<PhoneVerificationSession> sendOtp(
    String phone, {
    int? forceResendingToken,
    String purpose = 'login',
  }) async {
    if (_otpRequestRunning) {
      throw StateError(
        'يوجد طلب تحقق قيد التنفيذ، انتظر قليلاً',
      );
    }
    _otpRequestRunning = true;

    try {
      final phoneNumber = formatPhone(phone);

      final verificationId = await QuickConnectOtpService.send(
        phone: phoneNumber,
        purpose: purpose,
      );

      return PhoneVerificationSession(
        verificationId: verificationId,
      );
    } on FormatException catch (error) {
      throw StateError(error.message);
    } on FirebaseFunctionsException catch (error) {
      throw StateError(
          error.message ?? 'تعذر إرسال رمز التحقق، يرجى المحاولة لاحقاً');
    } catch (e) {
      if (ConnectivityHelper.isNetworkException(e)) {
        throw StateError('تعذر الاتصال بخدمة التحقق، تأكد من اتصال الإنترنت');
      }
      rethrow;
    } finally {
      _otpRequestRunning = false;
    }
  }

  // ══════════════════════════════════════════
  // التحقق من رمز OTP
  // ══════════════════════════════════════════

  Future<OtpVerifyResponse> verifyOtp({
    required String verificationId,
    required String otp,
    required String phone,
    String purpose = 'login',
  }) async {
    final cleanVerificationId = verificationId.trim();
    final cleanOtp = QuickConnectOtpService.normalizeCode(otp);
    if (cleanVerificationId.isEmpty) {
      return const OtpVerifyResponse(
        success: false,
        message: 'انتهت جلسة التحقق، أعد إرسال الرمز',
      );
    }

    if (!RegExp(r'^\d{6}$').hasMatch(cleanOtp)) {
      return const OtpVerifyResponse(
        success: false,
        message: 'أدخل رمز التحقق المكوّن من 6 أرقام',
      );
    }

    try {
      final customToken = await QuickConnectOtpService.verify(
        verificationId: cleanVerificationId,
        phone: formatPhone(phone),
        code: cleanOtp,
        purpose: purpose,
      );

      return OtpVerifyResponse(
        success: customToken != null,
        customToken: customToken,
        message: customToken != null
            ? 'تم التحقق بنجاح'
            : 'رمز التحقق غير صحيح أو انتهت صلاحيته',
      );
    } on OtpVerificationRejected catch (error) {
      return OtpVerifyResponse(
        success: false,
        message: error.message,
      );
    } on FormatException catch (error) {
      return OtpVerifyResponse(
        success: false,
        message: error.message,
      );
    } on FirebaseFunctionsException catch (error) {
      return OtpVerifyResponse(
        success: false,
        message: error.message ?? 'تعذر التحقق من الرمز',
      );
    } catch (error) {
      return const OtpVerifyResponse(
        success: false,
        message: 'تعذر الاتصال بخدمة التحقق',
      );
    }
  }

  // ══════════════════════════════════════════
  // حفظ بيانات المستخدم محلياً
  // ══════════════════════════════════════════
  /// مصدر الحقيقة الموحد للتحقق التشفيري من الرتبة عبر Custom Claims لجميع المستخدمين بدون أي استثناءات
  static String resolveVerifiedRole({
    required String docRole,
    required String? claimsRole,
  }) {
    final cleanDocRole = docRole.trim().toLowerCase();
    final cleanClaimRole = claimsRole?.trim().toLowerCase();
    const privilegedRoles = {
      'admin',
      'super_admin',
      'accountant',
      'warehouse_manager',
      'driver',
    };

    if (privilegedRoles.contains(cleanDocRole) ||
        (cleanClaimRole != null && privilegedRoles.contains(cleanClaimRole))) {
      if (cleanClaimRole != null && cleanClaimRole == cleanDocRole) {
        return cleanDocRole;
      }
      return 'merchant';
    }

    if (cleanClaimRole != null && cleanClaimRole.isNotEmpty) {
      return cleanClaimRole;
    }
    return cleanDocRole.isNotEmpty ? cleanDocRole : 'merchant';
  }

  Future<void> saveUserLocally(
    String userId,
  ) async {
    try {
      final firebaseUser = FirebaseAuth.instance.currentUser;
      final currentAuthUid = firebaseUser?.uid ?? userId;
      if (currentAuthUid.isEmpty) {
        throw StateError('Missing authenticated user ID');
      }

      var document = await _db
          .collection('profiles')
          .doc(currentAuthUid)
          .get()
          .timeout(const Duration(seconds: 10));

      if (!document.exists) {
        try {
          final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
              .httpsCallable(
            'syncPhoneAuthProfile',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 12)),
          );
          await callable.call();
          document = await _db
              .collection('profiles')
              .doc(currentAuthUid)
              .get(const GetOptions(source: Source.server))
              .timeout(const Duration(seconds: 8));
        } catch (_) {}
      }

      if (!document.exists) {
        throw StateError('User profile was not found');
      }
      final data = document.data();
      if (data == null || data['is_deleted'] == true) {
        throw StateError('User profile data is empty');
      }

      IdTokenResult? idTokenResult;
      try {
        idTokenResult = await firebaseUser
            ?.getIdTokenResult(true)
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        idTokenResult = null;
      }

      if (idTokenResult?.claims?['role'] == null && firebaseUser != null) {
        try {
          final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
              .httpsCallable(
            'syncPhoneAuthProfile',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 12)),
          );
          await callable.call();
          idTokenResult = await firebaseUser
              .getIdTokenResult(true)
              .timeout(const Duration(seconds: 5));
        } catch (_) {}
      }

      if (idTokenResult?.claims?['is_banned'] == true) {
        throw StateError('User account is inactive or banned');
      }

      final claimsRole =
          (idTokenResult?.claims?['role'] as String?)?.trim().toLowerCase();
      final docRole =
          (data['role'] as String?)?.trim().toLowerCase() ?? 'merchant';
      final role = resolveVerifiedRole(
        docRole: docRole,
        claimsRole: claimsRole,
      );

      final isActive = data['is_active'] as bool? ?? false;
      final isBanned = data['is_banned'] == true;
      final accountStatus =
          data['account_status']?.toString().trim().toLowerCase() ?? '';

      if (isBanned || (!isActive && accountStatus != 'pending')) {
        throw StateError('User account is inactive or banned');
      }

      await AppStorage.setIsActive(isActive);
      await AppStorage.setIsBanned(isBanned);

      await AppStorage.saveUserData(
        userId: currentAuthUid,
        role: role,
        name: data['full_name'] as String?,
        storeName: data['store_name'] as String?,
        phone: data['phone_number'] as String?,
      );
      await NotificationService.instance.saveTokenToFirestore(currentAuthUid);
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          '[AuthService] saveUserLocally failed '
          'for $userId: $error',
        );

        debugPrintStack(
          stackTrace: stackTrace,
        );
      }

      rethrow;
    }
  }

  // ══════════════════════════════════════════
  // التحقق من حالة الحساب من Firestore
  // ══════════════════════════════════════════

  Future<bool> checkIsActiveFromServer(
    String userId,
  ) async {
    try {
      final document =
          await _db.collection('profiles').doc(userId).get().timeout(
                const Duration(seconds: 8),
              );

      if (!document.exists) {
        return false;
      }

      final data = document.data();

      if (data == null) {
        return false;
      }

      final isBanned = data['is_banned'] == true;
      final isActive = data['is_active'] as bool? ?? false;

      await AppStorage.setIsBanned(
        isBanned,
      );

      await AppStorage.setIsActive(
        isActive,
      );

      return !isBanned && isActive;
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          '[AuthService] checkIsActiveFromServer failed: $error',
        );

        debugPrintStack(
          stackTrace: stackTrace,
        );
      }

      // لا نعتمد على الكاش عند فشل فحص أمني.
      return false;
    }
  }

// ══════════════════════════════════════════
  // تسجيل الخروج الآمن
  // ══════════════════════════════════════════
  Future<void> signOut(
      {VoidCallback? onClearCart, ProviderContainer? container}) async {
    final currentUserId = AppStorage.userId;
    // 🔒 التقاط كائن الحاوية قبل تصريف RealtimeHub
    final targetContainer = container ?? RealtimeHub().container;

    try {
      // ✅ تصفير اشتراكات المستخدم وقنواته الحية مع بقاء محرك التطبيق جاهزاً للدخول التالي فوراً
      await RealtimeHub().resetOnSignOut();
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('[AuthService] RealtimeHub resetOnSignOut failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }

    onClearCart?.call();
    if (currentUserId != null && currentUserId.isNotEmpty) {
      try {
        // 👈 detachTokenFromFirestore تقوم بحذف التوكن وفك قنوات البث بأمان دون الحاجة للاستدعاء المزدوج
        await NotificationService.instance
            .detachTokenFromFirestore(currentUserId)
            .timeout(const Duration(seconds: 4));
      } catch (error, stackTrace) {
        if (kDebugMode) {
          debugPrint(
              '[AuthService] failed to detach notification token: $error');
          debugPrintStack(stackTrace: stackTrace);
        }
      }
    }

    try {
      await FirebaseAuth.instance.signOut().timeout(const Duration(seconds: 5));
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('[AuthService] Firebase sign out failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
    await AppStorage.clearUserData();
    await AppCache.instance.clearAll();
    FirebaseService.clearCache();
    SearchService.clearCache();
    PrefetchService.instance.clear();
    BarcodeIndexManager.instance.rebuildIndex();

    if (targetContainer != null) {
      // 🛡️ إبطال هادئ بدون استدعاء فوري (Invalidate بدلاً من Refresh) لمنع استنزاف الباقة وطلب 2500 منتج بالخلفية
      targetContainer.invalidate(categoriesProvider);
      targetContainer.invalidate(productsProvider);
      targetContainer.invalidate(realtimeNotifsProvider);
      targetContainer.invalidate(merchantOrdersProvider);
      targetContainer.invalidate(cartProvider);
      targetContainer.invalidate(realtimeCategoriesProvider);
      targetContainer.invalidate(realtimeBrandsProvider);
      targetContainer.invalidate(realtimeConfirmedOrdersProvider);
      targetContainer.invalidate(realtimeMyShippedOrdersProvider);
      targetContainer.invalidate(realtimeAllOrdersProvider);
      targetContainer.invalidate(driverNewOrderCallbackProvider);
    }
  }

  Future<void> deleteAccount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('لا يوجد مستخدم مسجل حالياً');
    final userId = AppStorage.userId ?? user.uid;

    try {
      // 🚀 استخدام Cloud Function لحذف الحساب ذرياً وبشكل آمن من الخادم
      // (يجب أن تتأكد من كتابة دالة 'deleteUserAccount' في ملف index.js في Firebase)
      final callable =
          FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable(
        'deleteUserAccount',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 15)),
      );

      await callable.call({'userId': userId});
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) debugPrint('[AuthService] Function Error: ${e.message}');
      throw StateError(e.message ?? 'تعذر حذف الحساب من الخادم');
    } catch (error) {
      if (kDebugMode) debugPrint('[AuthService] Delete error: $error');
      throw StateError(
          'تعذّر حذف الحساب. تحقق من اتصال الإنترنت وحاول مجددًا.');
    }

    // 3. مسح كافة البيانات المحلية من الهاتف بعد نجاح الحذف النهائي
    await signOut();
  }
}
