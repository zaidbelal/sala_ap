import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_adaptive_colors.dart';
import '../../cart/widgets/cart_floating_button.dart';
import 'tabs/home_tab.dart';
import 'tabs/history_tab.dart';
import 'tabs/orders_tab.dart';
import 'tabs/profile_tab.dart';

final _activeTabProvider = StateProvider.autoDispose<int>((ref) => 0);

class MerchantHomeScreen extends ConsumerStatefulWidget {
  const MerchantHomeScreen({super.key});

  @override
  ConsumerState<MerchantHomeScreen> createState() => _MerchantHomeScreenState();
}

class _MerchantHomeScreenState extends ConsumerState<MerchantHomeScreen> {
  @override
  Widget build(BuildContext context) {
    final activeTab = ref.watch(_activeTabProvider);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        statusBarIconBrightness:
            context.isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarIconBrightness:
            context.isDark ? Brightness.light : Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: context.bgPage,
        body: Stack(
          children: [
            IndexedStack(
              index: activeTab,
              children: [
                const HomeTab(),
                const HistoryTab(),
                OrdersTab(
                  onNavigateToHistory: () {
                    ref.read(_activeTabProvider.notifier).state = 1;
                  },
                ),
                const ProfileTab(),
              ],
            ),
            const Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: CartFloatingButton(),
            ),
          ],
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: context.bgHeader,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.07),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            child: SizedBox(
              height: 64,
              child: Row(
                children: [
                  _NavItem(
                    icon: Icons.home_rounded,
                    iconOutlined: Icons.home_outlined,
                    label: 'الرئيسية',
                    index: 0,
                    activeTab: activeTab,
                    onTap: () =>
                        ref.read(_activeTabProvider.notifier).state = 0,
                  ),
                  _NavItem(
                    icon: Icons.history_rounded,
                    iconOutlined: Icons.history_rounded,
                    label: 'السجل',
                    index: 1,
                    activeTab: activeTab,
                    onTap: () =>
                        ref.read(_activeTabProvider.notifier).state = 1,
                  ),
                  _NavItem(
                    icon: Icons.receipt_long_rounded,
                    iconOutlined: Icons.receipt_long_outlined,
                    label: 'الطلبات',
                    index: 2,
                    activeTab: activeTab,
                    onTap: () =>
                        ref.read(_activeTabProvider.notifier).state = 2,
                  ),
                  _NavItem(
                    icon: Icons.person_rounded,
                    iconOutlined: Icons.person_outline_rounded,
                    label: 'حسابي',
                    index: 3,
                    activeTab: activeTab,
                    onTap: () =>
                        ref.read(_activeTabProvider.notifier).state = 3,
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

// ══════════════════════════════════════════
// عنصر التنقل
// ══════════════════════════════════════════
class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData iconOutlined;
  final String label;
  final int index;
  final int activeTab;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.iconOutlined,
    required this.label,
    required this.index,
    required this.activeTab,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = index == activeTab;

    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.primary.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                isActive ? icon : iconOutlined,
                size: 24,
                color: isActive ? AppColors.primary : const Color(0xFFAAAAAA),
              ),
            ),
            const SizedBox(height: 2),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 250),
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'Cairo',
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: isActive ? AppColors.primary : const Color(0xFFAAAAAA),
              ),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}
