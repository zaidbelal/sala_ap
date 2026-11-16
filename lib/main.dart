import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:wissal/core/services/firebase_service.dart';
import 'package:wissal/core/services/local_storage.dart';
import 'package:wissal/core/services/realtime_hub.dart';
import 'package:wissal/core/services/notification_service.dart';
import 'package:wissal/core/services/app_cache.dart';
import 'package:wissal/core/services/catalog_service.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:wissal/core/constants/app_colors.dart';
import 'package:wissal/core/constants/app_theme.dart';
import 'package:wissal/app_router.dart';
import 'package:wissal/core/services/image_precache_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// إعدادات الويب
const webFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyC_O1Uu7f5sCrg5Xy2uP1JNeb_qgBPMqjo',
  appId: '1:846679653389:web:f155633d42da3784902944',
  messagingSenderId: '846679653389',
  projectId: 'app-sala-b42dd',
  authDomain: 'app-sala-b42dd.firebaseapp.com',
  storageBucket: 'app-sala-b42dd.firebasestorage.app',
);
// ✅ إعدادات الآيفون مأخوذة مباشرة من ملفك لحل مشكلة عدم الربط في Xcode
const iosFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyC_O1Uu7f5sCrg5Xy2uP1JNeb_qgBPMqjo',
  appId: '1:846679653389:ios:362d95f5793128e5902944',
  messagingSenderId: '846679653389',
  projectId: 'app-sala-b42dd',
  storageBucket: 'app-sala-b42dd.firebasestorage.app',
  iosBundleId: 'com.zaidsalaapp.sala',
);

// تحديد الإعداد المناسب لكل منصة
FirebaseOptions? get platformFirebaseOptions {
  if (kIsWeb) return webFirebaseOptions;
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return iosFirebaseOptions;
  }
  return null; // نظام أندرويد يقرأ من google-services.json تلقائياً
}

@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: platformFirebaseOptions);
    }
    // إذا كانت الرسالة تحتوي notification فإن نظام Android يعرضها تلقائياً، فلا نكررها محلياً
    if (defaultTargetPlatform == TargetPlatform.android &&
        message.notification != null) {
      return;
    }
    await AppStorage.initialize();
    await NotificationService.instance
        .initLocalNotifications(isBackground: true);
    await NotificationService.instance.showNotification(message);
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  GoogleFonts.config.allowRuntimeFetching = false;

  String? initError;
  bool isFirebaseReady = false;

  // 1. تهيئة فايربيز بالخيارات البرمجية المباشرة (حل الشاشة البيضاء)
  try {
    await Firebase.initializeApp(
      options: platformFirebaseOptions,
    );
    isFirebaseReady = true;
  } catch (e, st) {
    initError = 'خطأ تهيئة فايربيز: $e';
    debugPrint('❌ Firebase Init Error: $e\n$st');
  }

  // 2. إعداد رصد الأخطاء
  if (isFirebaseReady && !kIsWeb) {
    FlutterError.onError = (details) {
      final errorStr = details.exception.toString();
      if (errorStr.contains('fonts.gstatic.com') ||
          errorStr.contains('Failed to load font')) {
        return;
      }
      // تجاهل أخطاء تزامن لوحة المفاتيح والماسحات الضوئية الخارجية في محرك فلاتر
      if (errorStr.contains('KeyDownEvent is dispatched') ||
          errorStr.contains('hardware_keyboard.dart')) {
        return;
      }
      if (errorStr.contains('MultiImageStreamCompleter')) {
        FlutterError.presentError(details);
        try {
          unawaited(
            FirebaseCrashlytics.instance
                .recordError(
              details.exception,
              details.stack,
              reason: 'Image stream error',
              fatal: false,
            )
                .catchError((Object error) {
              debugPrint('Failed to report image stream error: $error');
            }),
          );
        } catch (error) {
          debugPrint('Failed to report image stream error: $error');
        }
        return;
      }

      // تجاوزات التخطيط المرئي (RenderFlex overflow) ليست انهيارات قاتلة للتطبيق
      if (errorStr.contains('RenderFlex overflowed')) {
        FlutterError.presentError(details);
        try {
          FirebaseCrashlytics.instance.recordFlutterError(details, fatal: false);
        } catch (_) {}
        return;
      }

      FlutterError.presentError(details);
      try {
        if (details.silent) {
          FirebaseCrashlytics.instance.recordFlutterError(details, fatal: false);
        } else {
          FirebaseCrashlytics.instance.recordFlutterFatalError(details);
        }
      } catch (_) {}
    };

    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };

    try {
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
    } catch (_) {}
  }

  // 3. فحص المستخدم مع مهلة أمان
  if (isFirebaseReady) {
    try {
      await FirebaseAuth.instance
          .authStateChanges()
          .first
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  // 4. تهيئة التخزين المحلي
  try {
    await AppStorage.initialize();
  } catch (e) {
    debugPrint('❌ AppStorage Error: $e');
  }

// 5. تهيئة الكاش المحلي قبل بدء الـ ProviderContainer
  try {
    await AppCache.instance.init();
  } catch (e) {
    debugPrint('❌ Cache Initialization Warning: $e');
  }
  if (isFirebaseReady) {
    FirebaseService.initialize();
  }
  final container = ProviderContainer();

  // 6. تشغيل واجهة التطبيق فوراً لمنع الشاشة البيضاء
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: initError != null
          ? _CriticalErrorApp(error: initError)
          : const WissalApp(),
    ),
  );
  if (isFirebaseReady) {
    RealtimeHub().init(container);
    _warmUpCache(container);
    unawaited(_initializeSystemConfig());

    if (!kIsWeb) {
      unawaited(_initializeNotifications());
    }
  }
}

class _CriticalErrorApp extends StatelessWidget {
  final String error;
  const _CriticalErrorApp({required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.orange, size: 64),
                  const SizedBox(height: 16),
                  const Text(
                    'تنبيه في إعدادات التطبيق',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Cairo'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _initializeSystemConfig() async {
  // 🔒 1. توحيد مصدر الحقيقة: القراءة المباشرة من نفس مستند Firestore الذي يعتمده السيرفر
  try {
    final snap = await FirebaseFirestore.instance
        .collection('system_config')
        .doc('app_config')
        .get(const GetOptions(source: Source.serverAndCache))
        .timeout(const Duration(seconds: 4));

    if (snap.exists && snap.data() != null) {
      final val = (snap.data()!['min_order_value'] as num?)?.toDouble();
      if (val != null && val > 0) {
        AppConfig.minOrderValue = val;
        return; // تم التطابق التام مع السيرفر
      }
    }
  } catch (_) {}

  // 2. بديل احتياطي عبر Remote Config في حال تعذر الوصول للوثيقة أو ضعف الاتصال
  try {
    final remoteConfig = FirebaseRemoteConfig.instance;
    await remoteConfig.setConfigSettings(
      RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 4),
        minimumFetchInterval: const Duration(minutes: 15),
      ),
    );
    await remoteConfig.setDefaults({'min_order_value': 4250.0});
    await remoteConfig.fetchAndActivate();
    final double fetchedMinOrder = remoteConfig.getDouble('min_order_value');
    if (fetchedMinOrder > 0) {
      AppConfig.minOrderValue = fetchedMinOrder;
    }
  } catch (_) {}
}

Future<void> _initializeNotifications() async {
  try {
    await NotificationService.instance.init();
    final userId = AppStorage.userId;
    if (userId != null && userId.trim().isNotEmpty) {
      await NotificationService.instance.saveTokenToFirestore(userId);
    }
  } catch (_) {}
}

void _warmUpCache(ProviderContainer container) {
  final categoriesFuture = container
      .read(categoriesProvider.future)
      .catchError((_) => <Map<String, dynamic>>[]);

  categoriesFuture.then((categories) async {
    if (categories.isEmpty) return;
    ImagePrecacheService.instance.prewarmCategories(categories);
  });
}

class WissalApp extends ConsumerStatefulWidget {
  const WissalApp({super.key});

  @override
  ConsumerState<WissalApp> createState() => _WissalAppState();
}

class _WissalAppState extends ConsumerState<WissalApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && AppStorage.isLoggedIn) {
      AppStorage.setString('last_login_at', DateTime.now().toIso8601String());
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final currentTheme = ref.watch(themeProvider);

    return MaterialApp.router(
      title: 'وصًال',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: currentTheme,
      routerConfig: router,
      locale: const Locale('ar'),
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
    );
  }
}
