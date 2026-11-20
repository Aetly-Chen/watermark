import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_tokens.dart';

/// 底部三 Tab 的外壳。
///
/// 由 `StatefulShellRoute.indexedStack` 驱动：每个 Tab 有自己的 Navigator，
/// 来回切 Tab 不会丢滚动位置与页面栈 —— 这是 go_router 相比「一个 Navigator 到处 push」
/// 最实际的收益，也是历史页 / 编辑页会反复进出的场景所必需的。
class AppShell extends StatelessWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  static const List<({IconData icon, IconData activeIcon, String label})>
  _tabs = [
    (icon: Icons.home_outlined, activeIcon: Icons.home_rounded, label: '首页'),
    (icon: Icons.history_outlined, activeIcon: Icons.history_rounded, label: '历史'),
    (icon: Icons.person_outline_rounded, activeIcon: Icons.person_rounded, label: '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: t.paper,
          border: Border(top: BorderSide(color: t.line)),
        ),
        child: SafeArea(
          top: false,
          child: NavigationBarTheme(
            data: NavigationBarThemeData(
              height: 60,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              indicatorColor: t.flameSoft,
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) {
                  return t.flame.withValues(alpha: 0.14);
                }
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)) {
                  return t.hoverTint;
                }
                return null;
              }),
              labelTextStyle: WidgetStateProperty.resolveWith((states) {
                final selected = states.contains(WidgetState.selected);
                return TextStyle(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? t.flameTxt : t.ink3,
                );
              }),
              iconTheme: WidgetStateProperty.resolveWith((states) {
                final selected = states.contains(WidgetState.selected);
                return IconThemeData(
                  size: 22,
                  color: selected ? t.flameTxt : t.ink3,
                );
              }),
            ),
            child: NavigationBar(
              height: 60,
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: (index) => navigationShell.goBranch(
                index,
                // 重复点当前 Tab → 回到该分支的初始页（iOS/微信 的通行行为）
                initialLocation: index == navigationShell.currentIndex,
              ),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [
                for (var i = 0; i < _tabs.length; i++)
                  NavigationDestination(
                    icon: Icon(_tabs[i].icon, color: t.ink3),
                    selectedIcon: Icon(_tabs[i].activeIcon, color: t.flameTxt),
                    label: _tabs[i].label,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
