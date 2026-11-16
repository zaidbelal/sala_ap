import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_radius.dart';
import '../../../../../core/constants/app_text_styles.dart';
import '../../orders/services/orders_service.dart';
import '../../orders/screens/order_status_screen.dart';
import '../providers/cart_provider.dart';
import 'location_picker_screen.dart';
import 'package:wissal/core/constants/app_adaptive_colors.dart';
import '../../../../core/services/local_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:wissal/features/auth/login/services/auth_service.dart';
import '../../../../core/services/connectivity_service.dart';

class CheckoutScreen extends ConsumerStatefulWidget {
  final String merchantId;
  const CheckoutScreen({super.key, required this.merchantId});

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  final _formKey = GlobalKey<FormState>();
  final _storeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _contactCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  LatLng? _location;
  String _paymentMethod = 'cash';
  bool _isLoading = false;
  String? _orderIdempotencyKey;
  @override
  void initState() {
    super.initState();
    _prefillMerchantDetails();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final changed = await _validateCartBeforeCheckout();
      if (changed && mounted) {
        _notifyCartModified();
      }
    });
  }

  void _notifyCartModified() {
    final cartNow = ref.read(cartProvider);
    final isCartEmpty = cartNow.isEmpty;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
                isCartEmpty
                    ? Icons.remove_shopping_cart_rounded
                    : Icons.warning_amber_rounded,
                color: isCartEmpty ? Colors.red : Colors.orange),
            const SizedBox(width: 8),
            Text(isCartEmpty ? 'السلة أصبحت فارغة' : 'تنبيه في محتويات السلة',
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
          ],
        ),
        content: Text(
          isCartEmpty
              ? 'نعتذر منك، لم تعد الأصناف التي اخترتها متوفرة في المستودع حالياً. يرجى العودة للتسوق واختيار أصناف أخرى.'
              : 'تم تحديث سلتك واستبعاد بعض الأصناف أو تعديل أسعارها لعدم توفرها في المستودع. يرجى مراجعة إجمالي الطلب قبل المتابعة.',
          style:
              const TextStyle(fontFamily: 'Cairo', fontSize: 13, height: 1.6),
        ),
        actions: [
          if (!isCartEmpty)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('العودة للسلة',
                  style: TextStyle(fontFamily: 'Cairo', color: Colors.grey)),
            ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              if (isCartEmpty && Navigator.of(context).canPop()) {
                Navigator.of(context)
                    .pop(); // إرجاع المستخدم فوراً إذا فرغت السلة
              }
            },
            child: Text(isCartEmpty ? 'العودة للتسوق' : 'متابعة بالمتوفر',
                style: const TextStyle(
                    fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _prefillMerchantDetails() async {
    final localName = AppStorage.userName ?? '';
    final localPhone = AppStorage.userPhone ?? '';
    final localStore = AppStorage.storeName ?? '';
    if (localStore.isNotEmpty && _storeCtrl.text.isEmpty) {
      _storeCtrl.text = localStore;
    }
    if (localName.isNotEmpty && _nameCtrl.text.isEmpty) {
      _nameCtrl.text = localName;
    }
    if (localPhone.isNotEmpty && _contactCtrl.text.isEmpty) {
      _contactCtrl.text = localPhone.replaceFirst('+967', '0');
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('profiles')
          .doc(widget.merchantId)
          .get();
      if (!mounted || !doc.exists || doc.data() == null) return;
      final data = doc.data()!;

      setState(() {
        if (_storeCtrl.text.isEmpty) {
          _storeCtrl.text = data['store_name']?.toString() ?? '';
        }
        if (_nameCtrl.text.isEmpty) {
          _nameCtrl.text = data['full_name']?.toString() ?? '';
        }
        if (_contactCtrl.text.isEmpty) {
          final phone = data['phone_number']?.toString() ?? '';
          _contactCtrl.text = phone.replaceFirst('+967', '0');
        }
        if (_location == null) {
          final lat = (data['latitude'] as num?)?.toDouble();
          final lng = (data['longitude'] as num?)?.toDouble();
          if (lat != null && lng != null) {
            _location = LatLng(lat, lng);
          }
        }
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[CheckoutScreen] failed to prefill profile data: $e');
      }
    }
  }

  @override
  void dispose() {
    _storeCtrl.dispose();
    _nameCtrl.dispose();
    _contactCtrl.dispose();
    _addressCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickLocation() async {
    final result = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(builder: (_) => const LocationPickerScreen()),
    );
    if (result != null && mounted) setState(() => _location = result);
  }

// تم إلغاء showDialog المعرض لتعارض المسارات واستبداله بـ Overlay مدمج وآمن 100% داخل الشجرة
  bool _isPlacingOrder = false;
  Future<void> _placeOrder() async {
    if (_isPlacingOrder) return;
    setState(() {
      _isPlacingOrder = true;
      _isLoading = true;
    });
    try {
      final cartChanged = await _validateCartBeforeCheckout();
      if (mounted && cartChanged) {
        setState(() => _isLoading = false);
      }
      if (cartChanged) {
        if (mounted) {
          if (ref.read(cartProvider).isEmpty) {
            _notifyCartModified();
            return;
          }
          final proceedWithAvailable = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              backgroundColor: ctx.bgCard,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('تحديث في محتوى السلة',
                  style: TextStyle(
                      fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
              content: const Text(
                'تم استبعاد أصناف غير متوفرة أو تحديث الأسعار. هل تريد المتابعة بالأصناف المتوفرة الآن؟',
                style: TextStyle(fontFamily: 'Cairo', fontSize: 13),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('مراجعة السلة',
                      style:
                          TextStyle(fontFamily: 'Cairo', color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('متابعة بالمتوفر',
                      style:
                          TextStyle(fontFamily: 'Cairo', color: Colors.white)),
                ),
              ],
            ),
          );

          if (proceedWithAvailable != true) {
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
            return;
          }
        }
      }
      await _placeOrderInternal();
    } catch (_) {
      _showError('تعذر التحقق من أحدث الأسعار والمخزون، يرجى المحاولة مجدداً');
    } finally {
      _isLoading = false;
      if (mounted) {
        setState(() => _isPlacingOrder = false);
      } else {
        _isPlacingOrder = false;
      }
    }
  }

  Future<bool> _validateCartBeforeCheckout() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return false;
    try {
      final hasNet = await ConnectivityHelper.hasActiveInternet();
      if (!hasNet) return false;

      final productIds = cart.values.map((e) => e.product.id).toSet().toList();
      final chunks = <List<String>>[];
      for (var i = 0; i < productIds.length; i += 30) {
        chunks.add(productIds.sublist(
            i, i + 30 > productIds.length ? productIds.length : i + 30));
      }
      final liveDocs = <Map<String, dynamic>>[];
      final successfullyQueriedIds = <String>{};

      await Future.wait(
        chunks.map((chunk) async {
          try {
            final snap = await FirebaseFirestore.instance
                .collection('products')
                .where(FieldPath.documentId, whereIn: chunk)
                .get(const GetOptions(source: Source.server))
                .timeout(const Duration(seconds: 4));
            liveDocs.addAll(snap.docs.map((d) => {'id': d.id, ...d.data()}));
            successfullyQueriedIds.addAll(chunk);
          } catch (_) {}
        }),
      );

      if (!mounted || successfullyQueriedIds.isEmpty) return false;

      return ref.read(cartProvider.notifier).validateAndUpdatePrices(
            liveDocs,
            queriedBatchIds: successfullyQueriedIds,
          );
    } catch (_) {
      return false;
    }
  }

  Future<void> _placeOrderInternal() async {
    // ── 1. فحص الاتصال بالإنترنت أولاً ──
    final bool hasNet = await ConnectivityHelper.hasActiveInternet();
    if (!hasNet) {
      _showError(
          'يتطلب إرسال الطلب اتصالاً نشطاً بالإنترنت لمطابقة المخزون الفعلي');
      return;
    }

    // ── 2. التحقق من السلة ──
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) {
      _showError('السلة فارغة، أضف منتجات أولاً');
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }
    if (cart.length > AppConfig.maxOrderItems) {
      _showError(
          'عذراً، لا يمكن أن يحتوي الطلب الواحد على أكثر من ${AppConfig.maxOrderItems} صنفاً مختلفاً. يرجى تقسيم الطلب.');
      return;
    }

    // ── 3. التحقق من الحد الأدنى ──
    final double serverMinOrder = AppConfig.minOrderValue;
    final total = ref.read(cartTotalProvider);
    if (total < serverMinOrder) {
      _showError(
          'الحد الأدنى للطلب هو ${serverMinOrder.toStringAsFixed(0)} ر.ي');
      return;
    }


    if (!_formKey.currentState!.validate()) return;

    if (_location == null) {
      _showError('يرجى تحديد موقع التوصيل');
      return;
    }
    final cleanContact = _contactCtrl.text.trim();
    if (cleanContact.isEmpty || cleanContact.length < 9) {
      _showError('يرجى إدخال رقم هاتف صحيح للتواصل (9 أرقام على الأقل)');
      return;
    }

    final String normalizedPhone;
    try {
      normalizedPhone = AuthService.formatPhone(cleanContact);
    } catch (e) {
      _showError('صيغة رقم الهاتف غير صحيحة، تأكد من إدخال 9 أرقام تبدأ بـ 7');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _isLoading = true);
    HapticFeedback.heavyImpact();

    final String merchantId = widget.merchantId;
    final List<Map<String, dynamic>> itemsList = cart.values
        .map((e) => <String, dynamic>{
              'product_id': e.product.id,
              'product_name': e.displayName,
              'quantity': e.quantity,
              'price': e.unitPrice,
              if (e.selectedVariant != null) ...{
                'variant_id': e.selectedVariant!.id,
                'variant_label': e.selectedVariant!.label,
              },
              if (e.selectedUnit != null) ...{
                'unit_label': e.selectedUnit!.label,
                'unit_qty': e.selectedUnit!.qty,
              },
            })
        .toList();
    final String? notesString =
        _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim();

    final Map<String, dynamic> extraDataMap = {
      'store_name': _storeCtrl.text.trim(),
      'customer_name': _nameCtrl.text.trim(),
      'merchant_name': _nameCtrl.text.trim(),
      'contact': normalizedPhone,
      'phone_number': normalizedPhone,
      'delivery_address': _storeCtrl.text.trim(),
      'latitude': _location!.latitude,
      'longitude': _location!.longitude,
      'payment_method': _paymentMethod,
    };
    try {
      _orderIdempotencyKey ??=
          FirebaseFirestore.instance.collection('orders').doc().id;

      final order = await OrdersService.placeOrder(
        merchantId: merchantId,
        items: itemsList,
        expectedTotal: total,
        notes: notesString,
        extraData: extraDataMap,
        orderId: _orderIdempotencyKey,
      ).timeout(const Duration(seconds: 30));

      _orderIdempotencyKey = null;
      if (!mounted) return;
      ref.read(cartProvider.notifier).clear();

      Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => OrderStatusScreen(order: order),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeIn),
            child: child,
          ),
        ),
        (route) => route.isFirst,
      );
    } catch (e) {
      HapticFeedback.vibrate();

      final err = e.toString();
      final RegExp exp = RegExp(
        r'(?:PRODUCT_UNAVAILABLE_|OUT_OF_STOCK_)\[([^\]]+)\]',
        caseSensitive: false,
      );
      final matches = exp.allMatches(err);
      if (matches.isNotEmpty && mounted) {
        final cartNotifier = ref.read(cartProvider.notifier);
        final keysToRemove = <String>{};

        for (final m in matches) {
          final rawContent = m.group(1);
          if (rawContent == null || rawContent.trim().isEmpty) continue;

          final tokens = rawContent.split(RegExp(r'[,;]+'));
          for (final token in tokens) {
            final cleanToken = token.trim();
            if (cleanToken.isEmpty) continue;

            if (cleanToken.contains(':')) {
              final parts = cleanToken.split(':');
              final badProdId = parts[0].trim();

              if (parts.length >= 3) {
                final badVarId = parts[1].trim();
                final badUnit = parts.sublist(2).join(':').trim();
                for (final entry in cart.entries) {
                  final itemUnit = entry.value.unitLabel.trim();
                  final itemVarId = entry.value.selectedVariant?.id ?? '';
                  if (entry.value.product.id == badProdId &&
                      (badVarId.isEmpty || itemVarId == badVarId) &&
                      (itemUnit == badUnit || badUnit.isEmpty)) {
                    keysToRemove.add(entry.key);
                  }
                }
              } else {
                final second = parts[1].trim();
                for (final entry in cart.entries) {
                  final itemUnit = entry.value.unitLabel.trim();
                  final itemVarId = entry.value.selectedVariant?.id ?? '';
                  final matchesVariant =
                      itemVarId.isNotEmpty && itemVarId == second;
                  final matchesUnit = itemVarId.isEmpty &&
                      (itemUnit == second || second.isEmpty);
                  if (entry.value.product.id == badProdId &&
                      (matchesVariant || matchesUnit)) {
                    keysToRemove.add(entry.key);
                  }
                }
              }
            } else {
              for (final entry in cart.entries) {
                if (entry.value.product.id == cleanToken) {
                  keysToRemove.add(entry.key);
                }
              }
            }
          }
        }
        if (keysToRemove.isNotEmpty) {
          for (final k in keysToRemove) {
            cartNotifier.removeItem(k);
          }
          _orderIdempotencyKey = null;
          _showError(
              'نعتذر، تم استبعاد (${keysToRemove.length}) من الأصناف غير المتوفرة حالياً في المستودع من سلتك.');
          return;
        }
      }

      // 🔒 الحفاظ على _orderIdempotencyKey في حالات انقطاع النت/المهلة لضمان Idempotent Retry
      if (matches.isNotEmpty) {
        _orderIdempotencyKey =
            null; // تصفيره فقط إذا تغيرت محتويات السلة لاستبعاد أصناف
      }

      String friendlyMessage;
      if (e is FirebaseFunctionsException &&
          e.message != null &&
          e.message!.isNotEmpty) {
        if (e.message!.contains('PRICE_DIVERGENCE')) {
          await _validateCartBeforeCheckout();
          friendlyMessage =
              'تغيرت أسعار بعض الأصناف، تم تحديث سلتك بالأسعار الجديدة. يرجى مراجعتها وتأكيد الطلب.';
        } else {
          friendlyMessage = e.message!;
        }
      } else {
        final lowerErr = err.toLowerCase();
        friendlyMessage = (lowerErr.contains('network') ||
                lowerErr.contains('timeout') ||
                lowerErr.contains('socket'))
            ? 'تعذر الاتصال بالخادم، يرجى التحقق من اتصال الإنترنت والمحاولة مجدداً'
            : (lowerErr.contains('permission') ||
                    lowerErr.contains('banned') ||
                    lowerErr.contains('inactive'))
                ? 'حسابك بانتظار التفعيل أو معطل من قبل الإدارة'
                : 'تعذر إتمام الطلب حالياً، يرجى المحاولة بعد لحظات';
      }

      _showError(friendlyMessage);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.error_rounded, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(msg, style: const TextStyle(fontFamily: 'Cairo'))),
      ]),
      backgroundColor: Colors.red[700],
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final total = ref.watch(cartTotalProvider);

    return PopScope(
      canPop: !_isLoading,
      child: Scaffold(
        backgroundColor: context.bgPage,
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  // ─── Header ───
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: context.bgCard,
                              borderRadius: AppRadius.mdAll,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.07),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                            child: const Icon(Icons.arrow_forward_ios_rounded,
                                size: 18),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('تأكيد الطلب',
                                style: AppTextStyles.headlineMedium.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: context.textPrimary,
                                )),
                            Text(
                              '${cart.length} منتج — ${total.toStringAsFixed(0)} ر.ي',
                              style: AppTextStyles.bodySmall
                                  .copyWith(color: AppColors.primary),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const _SectionTitle(
                                title: 'بيانات العميل',
                                icon: Icons.person_rounded),
                            const SizedBox(height: 12),
                            _FormField(
                              controller: _storeCtrl,
                              label: 'اسم البقالة / المحل',
                              hint: 'مثال: بقالة النور',
                              icon: Icons.storefront_rounded,
                            ),
                            const SizedBox(height: 12),
                            _FormField(
                              controller: _nameCtrl,
                              label: 'اسم العميل',
                              hint: 'الاسم الكامل',
                              icon: Icons.badge_rounded,
                            ),
                            const SizedBox(height: 12),
                            _FormField(
                              controller: _contactCtrl,
                              label: 'رقم التواصل',
                              hint: '7XXXXXXXX',
                              icon: Icons.phone_rounded,
                              keyboardType: TextInputType.phone,
                              inputFormatters: [
                                TextInputFormatter.withFunction(
                                    (oldVal, newVal) {
                                  const arabic = {
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
                                    '۹': '9'
                                  };
                                  var t = newVal.text;
                                  arabic.forEach(
                                      (k, v) => t = t.replaceAll(k, v));
                                  t = t.replaceAll(RegExp(r'[^0-9]'), '');
                                  return TextEditingValue(
                                    text: t,
                                    selection: TextSelection.collapsed(
                                        offset: t.length),
                                  );
                                }),
                              ],
                              validator: (v) {
                                if (v == null || v.isEmpty) return 'مطلوب';
                                if (v.length < 9) return 'رقم غير صحيح';
                                return null;
                              },
                            ),
                            // تم الاستغناء عن تفاصيل العنوان والشارع والاعتماد على الخريطة واسم البقالة
                            const SizedBox(height: 24),
                            const _SectionTitle(
                                title: 'موقع التوصيل',
                                icon: Icons.location_on_rounded),
                            const SizedBox(height: 12),
                            GestureDetector(
                              onTap: _pickLocation,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: context.bgCard,
                                  borderRadius: AppRadius.lgAll,
                                  border: Border.all(
                                    color: _location == null
                                        ? context.borderColor
                                        : AppColors.primary,
                                    width: _location == null ? 1 : 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: context.shadowColor,
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: _location == null
                                            ? const Color(0xFFF0F0F0)
                                            : AppColors.primary
                                                .withValues(alpha: 0.1),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        _location == null
                                            ? Icons.add_location_rounded
                                            : Icons.location_on_rounded,
                                        color: _location == null
                                            ? Colors.grey[400]
                                            : AppColors.primary,
                                        size: 22,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _location == null
                                                ? 'تحديد موقع التوصيل'
                                                : 'تم تحديد الموقع ✓',
                                            style: TextStyle(
                                              fontFamily: 'Cairo',
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              color: _location == null
                                                  ? Colors.grey[600]
                                                  : AppColors.primary,
                                            ),
                                          ),
                                          Text(
                                            _location == null
                                                ? 'GPS أو اختيار يدوي على الخريطة *'
                                                : '${_location!.latitude.toStringAsFixed(4)}, ${_location!.longitude.toStringAsFixed(4)}',
                                            style: TextStyle(
                                              fontFamily: 'Cairo',
                                              fontSize: 12,
                                              color: Colors.grey[500],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.arrow_forward_ios_rounded,
                                        size: 14, color: context.textHint),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            const _SectionTitle(
                                title: 'ملاحظات (اختياري)',
                                icon: Icons.notes_rounded),
                            const SizedBox(height: 12),
                            Container(
                              decoration: BoxDecoration(
                                color: context.bgCard,
                                borderRadius: AppRadius.lgAll,
                                boxShadow: [
                                  BoxShadow(
                                    color: context.shadowColor,
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                              child: TextField(
                                controller: _notesCtrl,
                                textDirection: TextDirection.rtl,
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 14,
                                    color: context.textPrimary),
                                decoration: InputDecoration(
                                  hintText:
                                      'مثال: أرسل بعد العصر\nالتوصيل للباب الخلفي',
                                  hintStyle: TextStyle(
                                      fontFamily: 'Cairo',
                                      color: context.textHint,
                                      fontSize: 13),
                                  border: const OutlineInputBorder(
                                    borderRadius: AppRadius.lgAll,
                                    borderSide: BorderSide.none,
                                  ),
                                  contentPadding: const EdgeInsets.all(16),
                                ),
                                maxLines: 3,
                              ),
                            ),
                            const SizedBox(height: 24),
                            const _SectionTitle(
                                title: 'طريقة الدفع',
                                icon: Icons.payments_rounded),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.amber[50],
                                borderRadius: AppRadius.mdAll,
                                border: Border.all(color: Colors.amber[200]!),
                              ),
                              child: Row(children: [
                                Icon(Icons.info_outline_rounded,
                                    size: 15, color: Colors.amber[800]),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'التطبيق يعمل بالدفع النقدي فقط',
                                    style: TextStyle(
                                        fontFamily: 'Cairo',
                                        fontSize: 12,
                                        color: Colors.amber[900]),
                                  ),
                                ),
                              ]),
                            ),
                            const SizedBox(height: 10),
                            _PaymentOption(
                              value: 'cash',
                              groupValue: _paymentMethod,
                              label: 'نقداً عند الاستلام',
                              subtitle: 'الدفع نقداً بعد استلام البضاعة وفحصها',
                              icon: Icons.payments_outlined,
                              onChanged: (v) =>
                                  setState(() => _paymentMethod = v!),
                            ),
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ─── Bottom Bar ───
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    decoration: BoxDecoration(
                      color: context.bgCard,
                      boxShadow: [
                        BoxShadow(
                          color: context.shadowColor,
                          blurRadius: 16,
                          offset: const Offset(0, -4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _isLoading
                                ? null
                                : () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 15),
                              side: BorderSide(color: context.borderColor),
                              shape: const RoundedRectangleBorder(
                                  borderRadius: AppRadius.mdAll),
                            ),
                            child: const Text('إلغاء',
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _placeOrder,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 15),
                              shape: const RoundedRectangleBorder(
                                  borderRadius: AppRadius.mdAll),
                            ),
                            child: _isLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                        color: Colors.white, strokeWidth: 2.5),
                                  )
                                : const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.send_rounded, size: 20),
                                      SizedBox(width: 8),
                                      Text('إتمام الطلب',
                                          style: TextStyle(
                                              fontFamily: 'Cairo',
                                              fontSize: 15,
                                              fontWeight: FontWeight.w800)),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // طبقة التحميل المدمجة والآمنة التي لا تغلق الشاشة ولا تعلق للأبد
            if (_isLoading)
              Container(
                color: Colors.black.withValues(alpha: 0.5),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 36, vertical: 28),
                    decoration: BoxDecoration(
                      color: context.bgCard,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 30,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 50,
                          height: 50,
                          child: CircularProgressIndicator(
                            color: AppColors.primary,
                            strokeWidth: 3,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'جاري إرسال الطلب...',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: context.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'يرجى الانتظار',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            color: context.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════
class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData icon;
  const _SectionTitle({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 18, color: AppColors.primary),
      const SizedBox(width: 8),
      Text(
        title,
        style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: context.textPrimary),
      ),
    ]);
  }
}

// ════════════════════════════════
class _FormField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;

  const _FormField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.keyboardType,
    this.inputFormatters,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      textDirection: TextDirection.rtl,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      style: TextStyle(
        fontFamily: 'Cairo',
        fontSize: 14,
        color: context.textPrimary,
        fontWeight: FontWeight.w700,
      ),
      validator: validator ??
          (v) {
            if (v == null || v.trim().isEmpty) return 'هذا الحقل مطلوب';
            return null;
          },
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(
            fontFamily: 'Cairo', color: context.textSecondary, fontSize: 13),
        hintStyle: TextStyle(
            fontFamily: 'Cairo', color: context.textHint, fontSize: 13),
        prefixIcon: Icon(icon, color: context.iconSecondary, size: 20),
        filled: true,
        fillColor: context.bgInput,
        border: const OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: Color(0xFFEEEEEE)),
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: Color(0xFFEEEEEE)),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: Colors.red),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }
}

class _PaymentOption extends StatelessWidget {
  final String value;
  final String groupValue;
  final String label;
  final String subtitle;
  final IconData icon;
  final ValueChanged<String?> onChanged;

  const _PaymentOption({
    required this.value,
    required this.groupValue,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = value == groupValue;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onChanged(value);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.15)
              : context.bgCard, // 👈 متكيف تلقائياً مع خلفية الوضع الداكن
          borderRadius: AppRadius.mdAll,
          border: Border.all(
            color: isSelected ? AppColors.primary : context.borderColor,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primary.withValues(alpha: 0.15)
                    : context.bgInput,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon,
                  size: 18,
                  color:
                      isSelected ? AppColors.primary : context.iconSecondary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: isSelected
                              ? AppColors.primary
                              : context.textPrimary)), // 👈 نص أبيض وواضح
                  Text(subtitle,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          color:
                              context.textSecondary)), // 👈 نص ثانوي رمادي فاتح
                ],
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? AppColors.primary : Colors.transparent,
                border: Border.all(
                  color: isSelected ? AppColors.primary : context.borderColor,
                  width: 2,
                ),
              ),
              child: isSelected
                  ? const Icon(Icons.check_rounded,
                      size: 13, color: Colors.white)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
