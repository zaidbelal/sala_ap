import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/services/local_storage.dart';
import '../../../orders/models/order_model.dart';
import '../../../orders/screens/order_status_screen.dart';
import '../../../widgets/order_card.dart';
import 'package:wissal/core/constants/app_adaptive_colors.dart';
import 'dart:async';
import 'package:wissal/core/services/realtime_hub.dart';

class OrdersTab extends ConsumerStatefulWidget {
  final VoidCallback? onNavigateToHistory;
  const OrdersTab({super.key, this.onNavigateToHistory});

  @override
  ConsumerState<OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends ConsumerState<OrdersTab>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  static const int _ordersPageSize = 100;
  DocumentSnapshot<Map<String, dynamic>>? _ordersCursor;
  final Map<String, Map<String, dynamic>> _olderOrders = {};
  bool _hasMoreOrders = true;
  bool _isLoadingMoreOrders = false;
  String? _orderLoadError;
  Stream<QuerySnapshot<Map<String, dynamic>>>? ordersStream;

  static const _tabs = [
    (label: 'الكل', icon: Icons.list_alt_rounded),
    (label: 'الجارية', icon: Icons.pending_actions_rounded),
    (label: 'مُسلَّمة', icon: Icons.check_circle_rounded),
    (label: 'مرفوضة', icon: Icons.cancel_rounded),
    (label: 'مرتجعات', icon: Icons.assignment_return_rounded),
  ];

  bool historyTriggered = false;
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  Future<void> _refreshOrders(String merchantId) async {
    if (merchantId.isEmpty) return;
    setState(() {
      _ordersCursor = null;
      _olderOrders.clear();
      _hasMoreOrders = true;
      _orderLoadError = null;
    });
    try {
      final initialDocs = await FirebaseFirestore.instance
          .collection('orders')
          .where('merchant_id', isEqualTo: merchantId)
          .orderBy('created_at', descending: true)
          .limit(_ordersPageSize)
          .get(const GetOptions(source: Source.server));
      if (!mounted) return;
      if (initialDocs.docs.isNotEmpty) {
        _ordersCursor = initialDocs.docs.last;
        for (final doc in initialDocs.docs) {
          _olderOrders[doc.id] = {'id': doc.id, ...doc.data()};
        }
      }
      setState(() {
        _hasMoreOrders = initialDocs.docs.length == _ordersPageSize;
      });
    } catch (_) {}
  }

  Future<void> _loadMoreOrders(String merchantId) async {
    if (merchantId.isEmpty || !_hasMoreOrders || _isLoadingMoreOrders) {
      return;
    }
    var cursor = _ordersCursor;
    if (cursor == null) {
      final initialDocs = await FirebaseFirestore.instance
          .collection('orders')
          .where('merchant_id', isEqualTo: merchantId)
          .orderBy('created_at', descending: true)
          .limit(50)
          .get(const GetOptions(source: Source.serverAndCache));
      if (initialDocs.docs.isEmpty) return;
      cursor = initialDocs.docs.last;
      _ordersCursor = cursor;
    }
    setState(() {
      _isLoadingMoreOrders = true;
      _orderLoadError = null;
    });
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('orders')
          .where('merchant_id', isEqualTo: merchantId)
          .orderBy('created_at', descending: true)
          .startAfterDocument(cursor)
          .limit(_ordersPageSize)
          .get(const GetOptions(source: Source.serverAndCache));
      if (!mounted) return;
      if (snapshot.docs.isNotEmpty) {
        _ordersCursor = snapshot.docs.last;
        for (final doc in snapshot.docs) {
          _olderOrders[doc.id] = {'id': doc.id, ...doc.data()};
        }
      }
      setState(() {
        _hasMoreOrders = snapshot.docs.length == _ordersPageSize;
        _isLoadingMoreOrders = false;
      });
    } catch (error, stackTrace) {
      if (!mounted) return;
      debugPrint('Failed to load older merchant orders: $error');
      debugPrintStack(stackTrace: stackTrace);
      setState(() {
        _orderLoadError = 'تعذر تحميل الطلبات الأقدم. أعد المحاولة.';
        _isLoadingMoreOrders = false;
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final merchantId = AppStorage.userId ?? '';
    if (merchantId.isEmpty) {
      return const Scaffold(
        body:
            Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }

    return Scaffold(
      backgroundColor: context.bgPage,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──
            Container(
              color: context.bgHeader,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'طلباتي',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: context.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'اضغط على أي طلب لتتبع حالته',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12,
                      color: Color(0xFFAAAAAA),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TabBar(
                    controller: _tabController,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelStyle: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                    unselectedLabelStyle: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                    ),
                    labelColor: AppColors.primary,
                    unselectedLabelColor: const Color(0xFFAAAAAA),
                    indicatorColor: AppColors.primary,
                    indicatorWeight: 2.5,
                    tabs: _tabs
                        .map((t) => Tab(
                              child: Row(
                                children: [
                                  Icon(t.icon, size: 15),
                                  const SizedBox(width: 5),
                                  Text(t.label),
                                ],
                              ),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
// ── TabBarView الموحد عبر مزود الحالة المركزي (Zero Redundant Stream) ──
            Expanded(
              child: Builder(
                builder: (context) {
                  // الاستماع المباشر للقناة الموحدة مسبقاً في RealtimeHub
                  final liveOrders = ref.watch(merchantOrdersProvider);

                  final ordersById = <String, Map<String, dynamic>>{
                    ..._olderOrders,
                    for (final order in liveOrders)
                      order['id'].toString(): order,
                  };

                  final allOrders = ordersById.values.toList()
                    ..sort((a, b) {
                      DateTime parse(dynamic v) {
                        if (v is Timestamp) return v.toDate();
                        if (v is DateTime) return v;
                        if (v is String) {
                          return DateTime.tryParse(v) ?? DateTime(2000);
                        }
                        return DateTime(2000);
                      }

                      return parse(b['created_at'])
                          .compareTo(parse(a['created_at']));
                    });
                  List<Map<String, dynamic>> filterBy(List<String> statuses) {
                    return allOrders
                        .where((d) => statuses.contains(d['status']))
                        .toList();
                  }

                  final canLoadOlder = _hasMoreOrders && allOrders.length >= 50;

                  return TabBarView(
                    controller: _tabController,
                    physics: const BouncingScrollPhysics(),
                    children: [
                      _OrdersList(
                        orders: allOrders,
                        emptyType: _EmptyType.all,
                        hasMore: canLoadOlder,
                        isLoadingMore: _isLoadingMoreOrders,
                        loadMoreError: _orderLoadError,
                        onLoadMore: () => _loadMoreOrders(merchantId),
                        onRefresh: () => _refreshOrders(merchantId),
                      ),
                      _OrdersList(
                        orders: filterBy(const [
                          'pending',
                          'confirmed',
                          'accepted',
                          'preparing',
                          'shipped',
                          'on_the_way',
                        ]),
                        emptyType: _EmptyType.pending,
                        hasMore: canLoadOlder,
                        isLoadingMore: _isLoadingMoreOrders,
                        loadMoreError: _orderLoadError,
                        onLoadMore: () => _loadMoreOrders(merchantId),
                        onRefresh: () => _refreshOrders(merchantId),
                      ),
                      _OrdersList(
                        orders: filterBy(const ['delivered']),
                        emptyType: _EmptyType.delivered,
                        hasMore: canLoadOlder,
                        isLoadingMore: _isLoadingMoreOrders,
                        loadMoreError: _orderLoadError,
                        onLoadMore: () => _loadMoreOrders(merchantId),
                        onRefresh: () => _refreshOrders(merchantId),
                      ),
                      _OrdersList(
                        orders: filterBy(const ['cancelled', 'rejected']),
                        emptyType: _EmptyType.rejected,
                        hasMore: canLoadOlder,
                        isLoadingMore: _isLoadingMoreOrders,
                        loadMoreError: _orderLoadError,
                        onLoadMore: () => _loadMoreOrders(merchantId),
                        onRefresh: () => _refreshOrders(merchantId),
                      ),
                      _OrdersList(
                        orders:
                            filterBy(const ['returned', 'return_requested']),
                        emptyType: _EmptyType.returned,
                        hasMore: canLoadOlder,
                        isLoadingMore: _isLoadingMoreOrders,
                        loadMoreError: _orderLoadError,
                        onLoadMore: () => _loadMoreOrders(merchantId),
                        onRefresh: () => _refreshOrders(merchantId),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
enum _EmptyType { all, pending, delivered, rejected, returned }

// ══════════════════════════════════════════════════════════
class _OrdersList extends StatelessWidget {
  final List<Map<String, dynamic>> orders;
  final _EmptyType emptyType;
  final bool hasMore;
  final bool isLoadingMore;
  final String? loadMoreError;
  final VoidCallback onLoadMore;
  final Future<void> Function() onRefresh;

  const _OrdersList({
    required this.orders,
    required this.emptyType,
    required this.hasMore,
    required this.isLoadingMore,
    required this.loadMoreError,
    required this.onLoadMore,
    required this.onRefresh,
  });
  void _openOrder(BuildContext context, Map<String, dynamic> raw) {
    HapticFeedback.lightImpact();
    final order = OrderModel.fromJson(raw);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OrderStatusScreen(order: order),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool showPaginationButton = hasMore;
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh:
          onRefresh, // 👈 استدعاء التحديث الحقيقي وليس تحميل الصفحات القديمة
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        itemCount: (orders.isEmpty ? 1 : orders.length) +
            (showPaginationButton ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          if (orders.isEmpty && i == 0) {
            return _EmptyState(emptyType: emptyType);
          }
          if (i >= orders.length) {
            return Center(
              child: TextButton.icon(
                onPressed: isLoadingMore ? null : onLoadMore,
                icon: isLoadingMore
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.expand_more_rounded),
                label: Text(loadMoreError ?? 'تحميل الطلبات الأقدم'),
              ),
            );
          }
          return _TappableCard(
            key: ValueKey(orders[i]['id']?.toString() ?? '$i'),
            order: orders[i],
            onTap: () => _openOrder(context, orders[i]),
          );
        },
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// كارت قابل للنقر مع تأثير بصري
// ══════════════════════════════════════════════════════════
class _TappableCard extends StatefulWidget {
  final Map<String, dynamic> order;
  final VoidCallback onTap;

  const _TappableCard({
    super.key,
    required this.order,
    required this.onTap,
  });

  @override
  State<_TappableCard> createState() => _TappableCardState();
}

class _TappableCardState extends State<_TappableCard> {
  @override
  Widget build(BuildContext context) {
    return OrderCard(
      order: widget.order,
      onTap: widget.onTap,
    );
  }
}

// ══════════════════════════════════════════════════════════
// Skeleton Card
// ══════════════════════════════════════════════════════════
class _OrderSkeletonCard extends StatefulWidget {
  const _OrderSkeletonCard();

  @override
  State<_OrderSkeletonCard> createState() => _OrderSkeletonCardState();
}

class _OrderSkeletonCardState extends State<_OrderSkeletonCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _anim = Tween(begin: 0.4, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Widget _box(double w, double h, {double radius = 8}) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: context.borderColor,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.bgCard,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: context.shadowColor.withValues(alpha: 0.05),
              blurRadius: 8),
        ],
      ),
      child: Row(
        children: [
          _box(48, 48, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _box(double.infinity, 14),
                const SizedBox(height: 8),
                _box(120, 11),
                const SizedBox(height: 8),
                _box(80, 11),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _box(60, 16),
              const SizedBox(height: 8),
              _box(40, 24, radius: 12),
            ],
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// حالة فارغة
// ══════════════════════════════════════════════════════════
class _EmptyState extends StatelessWidget {
  final _EmptyType emptyType;
  const _EmptyState({required this.emptyType});

  @override
  Widget build(BuildContext context) {
    final (icon, color, title, subtitle) = switch (emptyType) {
      _EmptyType.all => (
          Icons.list_alt_rounded,
          AppColors.primary,
          'لا توجد طلبات بعد',
          'جميع طلباتك ستظهر هنا',
        ),
      _EmptyType.pending => (
          Icons.hourglass_empty_rounded,
          AppColors.primary,
          'لا توجد طلبات جارية',
          'طلباتك الجديدة ستظهر هنا',
        ),
      _EmptyType.delivered => (
          Icons.check_circle_outline_rounded,
          const Color(0xFF10B981),
          'لا توجد طلبات مُسلَّمة',
          'الطلبات المكتملة ستظهر هنا',
        ),
      _EmptyType.rejected => (
          Icons.cancel_outlined,
          Colors.red,
          'لا توجد طلبات مرفوضة',
          'الطلبات المرفوضة أو الملغاة ستظهر هنا',
        ),
      _EmptyType.returned => (
          Icons.assignment_return_outlined,
          Colors.orange,
          'لا توجد مرتجعات',
          'الطلبات المرتجعة ستظهر هنا',
        ),
    };

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 44, color: color.withValues(alpha: 0.45)),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 15,
              color: context.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              color: context.textHint,
            ),
          ),
        ],
      ),
    );
  }
}
