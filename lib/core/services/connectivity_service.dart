import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityHelper {
  ConnectivityHelper._();
  static Future<bool> hasActiveInternet() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.every((r) => r == ConnectivityResult.none)) {
        return false;
      }
      if (kIsWeb) return true;

      // فحص نطاق رسمي خفيف وسريع عبر DNS مع مهلة واقعية لشبكات اليمن
      final lookup = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 4));
      return lookup.isNotEmpty && lookup[0].rawAddress.isNotEmpty;
    } catch (_) {
      try {
        final lookupFallback =
            await InternetAddress.lookup('firebase.google.com')
                .timeout(const Duration(seconds: 3));
        return lookupFallback.isNotEmpty &&
            lookupFallback[0].rawAddress.isNotEmpty;
      } catch (_) {
        return false;
      }
    }
  }

  static Stream<bool> get onConnectivityChanged {
    return Connectivity().onConnectivityChanged.map(
          (results) => results.any((r) => r != ConnectivityResult.none),
        );
  }

  /// 🔒 المصنف المركزي الشامل: يكشف كافة أشكال أخطاء الشبكة والمهلة (عربية، إنجليزية، ونظامية)
  static bool isNetworkException(Object? error) {
    if (error == null) return false;

    // 1. استثناءات الإدخال/الإخراج والمهلة الصريحة
    if (error is SocketException ||
        error is TimeoutException ||
        error is HttpException) {
      return true;
    }
    final errStr = error.toString().toLowerCase();

    // 3. استثناءات Firebase Cloud Functions و Firestore
    if (errStr.contains('unavailable') &&
        !errStr.contains('product_unavailable')) return true;
    if (errStr.contains('deadline-exceeded') ||
        errStr.contains('network-request-failed') ||
        errStr.contains('network_error') ||
        errStr.contains('retry exhausted') ||
        errStr.contains('channel error') ||
        errStr.contains('connection closed') ||
        errStr.contains('connection reset') ||
        errStr.contains('host lookup')) {
      return true;
    }

    // 4. مطابقة النصوص العربية الناتجة عن تعثر الاتصال
    return errStr.contains('لا يوجد اتصال') ||
        errStr.contains('انقطع الاتصال') ||
        errStr.contains('تعذر الاتصال') ||
        errStr.contains('انتهت المهلة') ||
        errStr.contains('فشل الاتصال') ||
        errStr.contains('غير متصل') ||
        errStr.contains('تحقق من اتصال');
  }
}
