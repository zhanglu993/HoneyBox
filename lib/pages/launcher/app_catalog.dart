import 'package:flutter/material.dart';

/// 应用启动器内可选的应用标识。新增应用时：先扩展本枚举，然后在
/// [kAppCatalog] 追加一条对应记录，最后在 lib/app.dart 的路由分发里
/// 增加对应 <App>AppRoot 的构造。
enum AppId { ebadge, watch, dashboard, capture }

@immutable
class AppEntry {
  final AppId id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final String deviceFilter;
  final bool implemented;

  const AppEntry({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.deviceFilter,
    required this.implemented,
  });
}

const List<AppEntry> kAppCatalog = <AppEntry>[
  AppEntry(
    id: AppId.ebadge,
    title: 'eBadge',
    subtitle: '电子胸牌调试与内容管理',
    icon: Icons.badge_outlined,
    accent: Color(0xFF19519C),
    deviceFilter: 'eBadge',
    implemented: true,
  ),
  AppEntry(
    id: AppId.watch,
    title: 'Watch',
    subtitle: '智能手表配对与调试',
    icon: Icons.watch_outlined,
    accent: Color(0xFF2E7D6B),
    deviceFilter: 'Watch',
    implemented: true,
  ),
  AppEntry(
    id: AppId.dashboard,
    title: 'Dashboard',
    subtitle: '高德地图模拟导航与仪表投屏',
    icon: Icons.dashboard_outlined,
    accent: Color(0xFFB0603A),
    deviceFilter: 'Dashboard',
    implemented: true,
  ),
  AppEntry(
    id: AppId.capture,
    title: '数据采集',
    subtitle: '多设备 BLE 原始数据采集与配置管理',
    icon: Icons.sensors,
    accent: Color(0xFF6B50A1),
    deviceFilter: '*',
    implemented: true,
  ),
];

String routeNameFor(AppId id) {
  switch (id) {
    case AppId.ebadge:
      return '/ebadge-root';
    case AppId.watch:
      return '/watch-root';
    case AppId.dashboard:
      return '/dashboard-root';
    case AppId.capture:
      return '/capture-root';
  }
}
