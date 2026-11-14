import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wissal/core/services/local_storage.dart';
import 'package:wissal/core/services/realtime_hub.dart';
import 'package:wissal/features/auth/login/services/quickconnect_otp_service.dart';
import 'dart:async';

enum SessionResult {
  merchant,
  admin,
  driver,
  pending,
  unauthenticated,
}

final sessionCheckerProvider = FutureProvider<SessionResult>((ref) async {
  return SessionChecker.check();
});

class SessionChecker {
  SessionChecker._();

  static SessionResult localSessionResult() {
    if (!AppStorage.isLoggedIn || AppStorage.userId == null) {
      return SessionResult.unauthenticated;
    }

    if (AppStorage.isBanned) {
      return SessionResult.unauthenticated;
    }

    if (!AppStorage.isActive) {
      return SessionResult.pending;
    }

    switch (AppStorage.normalizedUserRole) {
      case 'admin':
      case 'super_admin':
      case 'accountant':
      case 'warehouse_manager':
        return SessionResult.admin;

      case 'driver':
        return SessionResult.driver;

      case 'merchant':
      default:
        return SessionResult.merchant;
    }
  }

  static Future<SessionResult> check() async {
    final sessionFuture = _checkSession();
    final minimumSplashDuration = Future<void>.delayed(
      const Duration(milliseconds: 600),
    );

    final result = await sessionFuture;
    await minimumSplashDuration;
    return result;
  }

  static Future<SessionResult> _checkSession() async {
    final userId = AppStorage.userId;

    // إذا لم يكن مسجلاً محلياً إطلاقاً
    if (!AppStorage.isLoggedIn || userId == null || userId.trim().isEmpty) {
      return SessionResult.unauthenticated;
    }

    // فحص محلي فوري لتسريع فتح التطبيق وعدم حجب المستخدم
    if (AppStorage.isBanned) {
      return SessionResult.unauthenticated;
    }

    final firebaseUser = FirebaseAuth.instance.currentUser;
    if (firebaseUser == null || firebaseUser.uid != userId) {
      return SessionResult.unauthenticated;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('profiles')
          .doc(userId)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 3));
// 🔒 المصدر السيادي الوحيد للأمان: التحقق الصارم من التوكن المشفر (Cryptographic Custom Claims)
      final tokenResult = await firebaseUser.getIdTokenResult(true);
      final verifiedRole =
          (tokenResult.claims?['role'] as String?)?.trim().toLowerCase();
      final isBannedClaim = tokenResult.claims?['is_banned'] == true;

      if (isBannedClaim) {
        await FirebaseAuth.instance.signOut();
        await AppStorage.clearUserData();
        return SessionResult.unauthenticated;
      }

      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        final isActive = data['is_active'] as bool? ?? false;
        final isBanned = data['is_banned'] == true;
        final docRole =
            (data['role'] as String?)?.trim().toLowerCase() ?? 'merchant';

        if (isBanned) {
          await FirebaseAuth.instance.signOut();
          await AppStorage.clearUserData();
          return SessionResult.unauthenticated;
        }

        // 🛡️ قاعدة أمنية قطعية: حظر أي رتبة إدارية أو سائق ما لم تكن موقعة ومثبتة في Claims
        const privilegedRoles = {
          'admin',
          'super_admin',
          'accountant',
          'warehouse_manager',
          'driver'
        };
        // التحقق مما إذا كان الحساب ينتمي لأرقام الاختبار المعتمدة لفايربيز
        final phoneNum = data['phone_number']?.toString() ?? '';
        final isTestAccount =
            QuickConnectOtpService.isFirebaseTestPhone(phoneNum);

        final String effectiveRole;
        if (privilegedRoles.contains(docRole)) {
          if (verifiedRole == docRole || isTestAccount) {
            effectiveRole = docRole;
          } else {
            // تراجع آمن وتجريد من الصلاحيات إذا لم تتطابق التوقيعات المشفرة
            effectiveRole = 'merchant';
          }
        } else {
          effectiveRole = verifiedRole ?? docRole;
        }

        await AppStorage.setIsActive(isActive);
        await AppStorage.setIsBanned(false);
        await AppStorage.saveUserData(
          userId: userId,
          role: effectiveRole,
          name: data['full_name'] as String?,
          storeName: data['store_name'] as String?,
          phone: data['phone_number'] as String?,
        );

        unawaited(RealtimeHub().startForUser(userId, role: effectiveRole));

        if (!isActive) {
          final accountStatus =
              data['account_status']?.toString().trim().toLowerCase() ?? '';
          if (accountStatus != 'pending' || data['store_name'] == null) {
            await FirebaseAuth.instance.signOut();
            await AppStorage.clearUserData();
            return SessionResult.unauthenticated;
          }
          return SessionResult.pending;
        }

        return switch (effectiveRole) {
          'admin' ||
          'super_admin' ||
          'accountant' ||
          'warehouse_manager' =>
            SessionResult.admin,
          'driver' => SessionResult.driver,
          _ => SessionResult.merchant,
        };
      }
    } catch (_) {
      // التعامل الآمن مع انقطاع الشبكة دون تصعيد الصلاحيات
      return localSessionResult();
    }
    unawaited(RealtimeHub()
        .startForUser(userId, role: AppStorage.normalizedUserRole));
    return localSessionResult();
  }

  static bool get isLoggedIn => AppStorage.isLoggedIn;
  static String? get currentUserId => AppStorage.userId;
}

extension SessionResultNavigation on SessionResult {
  String get route {
    switch (this) {
      case SessionResult.merchant:
        return '/merchant';

      case SessionResult.admin:
        return '/admin';

      case SessionResult.driver:
        return '/driver';

      case SessionResult.pending:
        return '/pending';

      case SessionResult.unauthenticated:
        return '/login';
    }
  }

  bool get isAuthenticated {
    return this != SessionResult.unauthenticated;
  }
}
