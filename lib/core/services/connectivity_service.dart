import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityHelper {
  ConnectivityHelper._();
  static Future<bool> hasActiveInternet() async {
    try {
      final results = await Connectivity().checkConnectivity();
      // التحقق الأساسي من وجود اتصال عبر بطاقة الشبكة أو الواي فاي
      if (results.every((r) => r == ConnectivityResult.none)) {
        return false;
      }
      if (kIsWeb) return true;

      try {
        // فحص DNS سريع مع استيعاب التأخير في الشبكات المحلية
        final lookup = await InternetAddress.lookup('dns.google')
            .timeout(const Duration(seconds: 6));
        return lookup.isNotEmpty && lookup[0].rawAddress.isNotEmpty;
      } catch (_) {
        // إذا تعثر فحص DNS بسبب بطء المزود المحلي، لا يتم حظر التاجر ونعتمد على استجابة السيرفر المباشرة
        return true;
      }
    } catch (_) {
      return true;
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
