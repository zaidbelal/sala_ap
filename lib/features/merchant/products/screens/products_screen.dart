import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_radius.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../core/services/catalog_service.dart';
import '../../../../core/services/realtime_hub.dart';
import '../../../../core/services/app_cache.dart';
import '../../cart/providers/cart_provider.dart';
import '../../cart/screens/cart_screen.dart';
import '../widgets/product_card.dart';
import 'package:wissal/core/constants/app_adaptive_colors.dart';
import 'package:wissal/features/merchant/products/services/products_service.dart';
import 'package:cached_network_image/cached_network_image.dart';

enum ProductSortCriteria {
  defaultSort,
  cheapest,
  highestPrice,
  bestSelling,
  mostPopular,
}

class ProductsScreen extends ConsumerStatefulWidget {
  final String? categoryId;
  final String? categoryName;
  final String? brandId;
  final String? brandName;

  const ProductsScreen({
    super.key,
    this.categoryId,
    this.categoryName,
    this.brandId,
    this.brandName,
  });

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  String? _selectedBrandId;
  ProductSizeTier _selectedSizeTier = ProductSizeTier.all;
  ProductSortCriteria _selectedSort = ProductSortCriteria.defaultSort;
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedBrandId = widget.brandId;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _showSortModalSheet() {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        decoration: BoxDecoration(
          color: context.bgCard,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: context.borderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'ترتيب المنتجات حسب:',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            _buildSortOption(
              label: 'الترتيب الافتراضي (حسب التنظيم المعتمد)',
              icon: Icons.sort_rounded,
              criteria: ProductSortCriteria.defaultSort,
            ),
            _buildSortOption(
              label: 'الأرخص سعراً أولاً (أفضل توفير 💰)',
              icon: Icons.arrow_downward_rounded,
              criteria: ProductSortCriteria.cheapest,
            ),
            _buildSortOption(
              label: 'الأعلى سعراً أولاً',
              icon: Icons.arrow_upward_rounded,
              criteria: ProductSortCriteria.highestPrice,
            ),
            _buildSortOption(
              label: 'الأكثر مبيعاً في السوق (الأعلى طلباً 🔥)',
              icon: Icons.local_fire_department_rounded,
              criteria: ProductSortCriteria.bestSelling,
            ),
            _buildSortOption(
              label: 'الأكثر رواجاً وتوفراً في المستودع ⭐',
              icon: Icons.star_rounded,
              criteria: ProductSortCriteria.mostPopular,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSortOption({
    required String label,
    required IconData icon,
    required ProductSortCriteria criteria,
  }) {
    final isSelected = _selectedSort == criteria;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon,
          color: isSelected ? AppColors.primary : context.iconSecondary),
      title: Text(
        label,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 13.5,
          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
          color: isSelected ? AppColors.primary : context.textPrimary,
        ),
      ),
      trailing: isSelected
          ? const Icon(Icons.check_circle_rounded,
              color: AppColors.primary, size: 20)
          : null,
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selectedSort = criteria);
        Navigator.pop(context);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectiveCategoryId = widget.categoryId;
    final productsAsync = ref.watch(productsProvider(effectiveCategoryId));
    final displayName = widget.categoryName ?? widget.brandName ?? 'المنتجات';

    final cart = ref.watch(cartProvider);
    final cartCount = cart.values.fold(0, (s, i) => s + i.quantity);
    final cartTotal = cart.values.fold(0.0, (s, i) => s + i.total);

    return Scaffold(
      backgroundColor: context.bgPage,
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.primary,
          onRefresh: () async {
            await ref
                .read(productsProvider(effectiveCategoryId).notifier)
                .refresh();
          },
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              // ══ 1. الترويسة العليا ══
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 14, 16, 0),
                  child: Row(
                    children: [
                      Material(
                        color: context.bgCard,
                        shape: const CircleBorder(),
                        elevation: 2,
                        shadowColor: Colors.black12,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () {
                            HapticFeedback.lightImpact();
                            Navigator.of(context).pop();
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(10),
                            child: Icon(Icons.arrow_forward_ios_rounded,
                                size: 18, color: AppColors.primary),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName,
                              style: AppTextStyles.headlineSmall.copyWith(
                                fontWeight: FontWeight.w800,
                                color: context.textPrimary,
                              ),
                            ),
                            productsAsync.when(
                              data: (rawList) {
                                final count = _processProducts(rawList).length;
                                return Text(
                                  '$count صنف متاح للمقارنة',
                                  style: AppTextStyles.bodySmall
                                      .copyWith(color: Colors.grey[500]),
                                );
                              },
                              loading: () => const SizedBox.shrink(),
                              error: (_, __) => const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ),
                      // زر السلة
                      GestureDetector(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const CartScreen()),
                          );
                        },
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: context.bgCard,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.08),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.shopping_cart_rounded,
                                  color: AppColors.primary, size: 22),
                            ),
                            if (cartCount > 0)
                              Positioned(
                                top: -4,
                                left: -4,
                                child: Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle),
                                  child: Text(
                                    '$cartCount',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      fontFamily: 'Cairo',
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ══ 2. شريط السلة العائم السريع ══
              if (cartCount > 0)
                SliverToBoxAdapter(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      borderRadius: AppRadius.lgAll,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.35),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.shopping_bag_outlined,
                            color: Colors.white, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          '$cartCount كرتون بالسلة (${cartTotal.toStringAsFixed(0)} ر.ي)',
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const CartScreen()),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text(
                              'إتمام الطلب ←',
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                color: AppColors.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // ══ 3. حقل البحث وزر الترتيب المتقدم (الأرخص / الأكثر مبيعاً) ══
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 46,
                          decoration: BoxDecoration(
                            color: context.bgCard,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: context.borderColor),
                          ),
                          child: TextField(
                            controller: _searchCtrl,
                            textDirection: TextDirection.rtl,
                            onChanged: (v) => setState(
                                () => _searchQuery = v.trim().toLowerCase()),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 13,
                                color: context.textPrimary),
                            decoration: InputDecoration(
                              hintText: 'ابحث بالاسم  ...',
                              hintStyle: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 12,
                                  color: context.textHint),
                              prefixIcon: const Icon(Icons.search_rounded,
                                  size: 18, color: AppColors.primary),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? GestureDetector(
                                      onTap: () {
                                        _searchCtrl.clear();
                                        setState(() => _searchQuery = '');
                                      },
                                      child: const Icon(Icons.close_rounded,
                                          size: 16, color: Colors.grey),
                                    )
                                  : null,
                              border: InputBorder.none,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // زر الفرز السريع المتقدم
                      GestureDetector(
                        onTap: _showSortModalSheet,
                        child: Container(
                          height: 46,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color:
                                _selectedSort != ProductSortCriteria.defaultSort
                                    ? AppColors.primary.withValues(alpha: 0.12)
                                    : context.bgCard,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: _selectedSort !=
                                      ProductSortCriteria.defaultSort
                                  ? AppColors.primary
                                  : context.borderColor,
                              width: 1.2,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.tune_rounded,
                                size: 18,
                                color: _selectedSort !=
                                        ProductSortCriteria.defaultSort
                                    ? AppColors.primary
                                    : context.textSecondary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _getSortLabel(_selectedSort),
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: _selectedSort !=
                                          ProductSortCriteria.defaultSort
                                      ? AppColors.primary
                                      : context.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ══ 4. شريط الشركات والماركات في الأعلى (Brands Bar) ══
              productsAsync.when(
                data: (rawList) {
                  final liveBrands = ref.watch(realtimeBrandsProvider);
                  final allBrandsList = liveBrands.isNotEmpty
                      ? liveBrands
                      : (AppCache.instance.getBrands() ?? []);
                  final brandsMap =
                      _extractDistinctBrands(rawList, allBrandsList);

                  return SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 10),
                        if (widget.brandId == null)
                          SizedBox(
                            height: 42,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              physics: const BouncingScrollPhysics(),
                              children: [
                                _buildBrandChip(
                                  label: 'كل الشركات',
                                  isSelected: _selectedBrandId == null,
                                  count: rawList.length,
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    setState(() => _selectedBrandId = null);
                                  },
                                ),
                                ...brandsMap.entries.map((entry) {
                                  final bId = entry.key;
                                  final bData = entry.value;
                                  return _buildBrandChip(
                                    label: bData['name'] ?? 'شركة',
                                    logoUrl: bData['logo_url'],
                                    isSelected: _selectedBrandId == bId,
                                    count: bData['count'] ?? 0,
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      setState(() {
                                        _selectedBrandId =
                                            (_selectedBrandId == bId)
                                                ? null
                                                : bId;
                                      });
                                    },
                                  );
                                }),
                              ],
                            ),
                          ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  );
                },
                loading: () =>
                    const SliverToBoxAdapter(child: SizedBox(height: 16)),
                error: (_, __) =>
                    const SliverToBoxAdapter(child: SizedBox.shrink()),
              ),

              // ══ 5. قائمة المنتجات المرتبة والمصفاة بالكامل ══
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: productsAsync.when(
                  loading: () =>
                      const SliverToBoxAdapter(child: _ProductsSkeletonList()),
                  error: (e, _) => SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('تعذر تحميل المنتجات: $e',
                            style: const TextStyle(fontFamily: 'Cairo')),
                      ),
                    ),
                  ),
                  data: (rawList) {
                    final processed = _processProducts(rawList);
                    if (processed.isEmpty) {
                      return SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 60),
                          child: Center(
                            child: Column(
                              children: [
                                Icon(Icons.search_off_rounded,
                                    size: 54, color: Colors.grey[300]),
                                const SizedBox(height: 10),
                                Text(
                                  'لا توجد أصناف تطابق الفلتر والترتيب المحدد',
                                  style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 14,
                                      color: Colors.grey[500]),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }

                    return SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final product =
                              ProductModel.fromMap(processed[index]);
                          final isBestSeller = product.salesCount > 0 &&
                              index == 0 &&
                              _selectedSort == ProductSortCriteria.bestSelling;
                          final isCheapest = index == 0 &&
                              _selectedSort == ProductSortCriteria.cheapest;

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                ProductCard(
                                  key: ValueKey('product_${product.id}'),
                                  product: product,
                                ),
                                // شارات التميز الذكية
                                if (isBestSeller)
                                  Positioned(
                                    top: 10,
                                    left: 12,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade800,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text(
                                        'الأكثر مبيعاً 🔥',
                                        style: TextStyle(
                                            fontFamily: 'Cairo',
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                if (isCheapest)
                                  Positioned(
                                    top: 10,
                                    left: 12,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade700,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text(
                                        'أفضل سعر 💰',
                                        style: TextStyle(
                                            fontFamily: 'Cairo',
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                        childCount: processed.length,
                      ),
                    );
                  },
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
        ),
      ),
    );
  }

  // ── محرك المعالجة المتكامل: فلترة الماركة + فلترة الحجم + الترتيب الذكي ──
  List<Map<String, dynamic>> _processProducts(List<Map<String, dynamic>> list) {
    // 1. التصفية
    final filtered = list.where((p) {
      if (p['is_deleted'] == true || p['is_active'] == false) return false;
// فلترة الشركة
      if (_selectedBrandId != null &&
          p['brand_id']?.toString() != _selectedBrandId) {
        return false;
      }

      // فلترة البحث
      if (_searchQuery.isNotEmpty) {
        final name = (p['name'] ?? '').toString().toLowerCase();
        final barcode = (p['barcode'] ?? '').toString().toLowerCase();
        if (!name.contains(_searchQuery) && !barcode.contains(_searchQuery)) {
          return false;
        }
      }

      return true;
    }).toList();

    // 2. الترتيب والفرز المتقدم
    switch (_selectedSort) {
      case ProductSortCriteria.cheapest:
        filtered.sort((a, b) {
          final pA = (a['price'] as num?)?.toDouble() ?? 0.0;
          final pB = (b['price'] as num?)?.toDouble() ?? 0.0;
          return pA.compareTo(pB);
        });
        break;

      case ProductSortCriteria.highestPrice:
        filtered.sort((a, b) {
          final pA = (a['price'] as num?)?.toDouble() ?? 0.0;
          final pB = (b['price'] as num?)?.toDouble() ?? 0.0;
          return pB.compareTo(pA);
        });
        break;

      case ProductSortCriteria.bestSelling:
        filtered.sort((a, b) {
          final sA = (a['sales_count'] as num?)?.toInt() ?? 0;
          final sB = (b['sales_count'] as num?)?.toInt() ?? 0;
          return sB.compareTo(sA); // الأكثر مبيعاً أولاً
        });
        break;

      case ProductSortCriteria.mostPopular:
        filtered.sort((a, b) {
          // دمج الأكثر مبيعاً مع الأصناف المتوفرة بمخزون قوي
          final sA = ((a['sales_count'] as num?)?.toInt() ?? 0) * 2 +
              ((a['stock'] as num?)?.toDouble() ?? 0.0);
          final sB = ((b['sales_count'] as num?)?.toInt() ?? 0) * 2 +
              ((b['stock'] as num?)?.toDouble() ?? 0.0);
          return sB.compareTo(sA);
        });
        break;

      case ProductSortCriteria.defaultSort:
        filtered.sort((a, b) => ((a['sort_order'] as num?)?.toInt() ?? 999)
            .compareTo((b['sort_order'] as num?)?.toInt() ?? 999));
        break;
    }

    return filtered;
  }

  String _getSortLabel(ProductSortCriteria c) => switch (c) {
        ProductSortCriteria.cheapest => 'الأرخص 💰',
        ProductSortCriteria.highestPrice => 'الأعلى سعراً',
        ProductSortCriteria.bestSelling => 'الأكثر مبيعاً 🔥',
        ProductSortCriteria.mostPopular => 'الأكثر رواجاً ⭐',
        ProductSortCriteria.defaultSort => 'الترتيب',
      };
  Map<String, Map<String, dynamic>> _extractDistinctBrands(
    List<Map<String, dynamic>> list,
    List<Map<String, dynamic>> allBrands,
  ) {
    final Map<String, Map<String, dynamic>> brands = {};
    final brandsLookup = {for (final b in allBrands) b['id'].toString(): b};

    for (final p in list) {
      final bId = p['brand_id']?.toString();
      if (bId != null && bId.isNotEmpty) {
        final brandInfo = brandsLookup[bId];
        final brandName = brandInfo?['name'] ?? p['brand_name'] ?? 'شركة';
        final brandLogo = brandInfo?['logo_url'] ?? p['brand_logo'];

        if (!brands.containsKey(bId)) {
          brands[bId] = {
            'name': brandName,
            'logo_url': brandLogo,
            'count': 1,
          };
        } else {
          brands[bId]!['count'] = (brands[bId]!['count'] as int) + 1;
        }
      }
    }
    return brands;
  }

  Widget _buildBrandChip({
    required String label,
    String? logoUrl,
    required bool isSelected,
    required int count,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary : context.bgCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? AppColors.primary : context.borderColor,
            width: isSelected ? 1.5 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (logoUrl != null && logoUrl.isNotEmpty) ...[
              ClipOval(
                child: CachedNetworkImage(
                  imageUrl: logoUrl,
                  width: 18,
                  height: 18,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) =>
                      const Icon(Icons.business, size: 14),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected ? Colors.white : context.textPrimary,
              ),
            ),
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.white.withValues(alpha: 0.25)
                    : context.bgInput,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: isSelected ? Colors.white : AppColors.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildSizeTierChip(String label, ProductSizeTier tier) {
    final isSelected = _selectedSizeTier == tier;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selectedSizeTier = tier);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.15)
              : context.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.primary : context.borderColor,
            width: isSelected ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
            color: isSelected ? AppColors.primary : context.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _ProductsSkeletonList extends StatelessWidget {
  const _ProductsSkeletonList();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        4,
        (i) => Container(
          margin: const EdgeInsets.only(bottom: 12),
          height: 130,
          decoration: BoxDecoration(
            color: Colors.grey.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
    );
  }
}
