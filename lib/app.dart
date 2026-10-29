import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'pages/ebadge/ebadge_app_root.dart';
import 'pages/ebadge/ebadge_debug_page.dart';
import 'pages/launcher/app_launcher_page.dart';
import 'pages/image/image_page.dart';
import 'pages/danmaku/danmaku_page.dart';
import 'pages/video/video_page.dart';
import 'pages/slideshow/slideshow_page.dart';
import 'pages/stream/stream_page.dart';
import 'pages/wifi/wifi_page.dart';
import 'pages/chip_config/chip_config_page.dart';
import 'pages/settings/settings_page.dart';
import 'pages/settings/cache_management_page.dart';
import 'pages/qiniu/qiniu_config_page.dart';
import 'pages/qiniu/qiniu_files_page.dart';
import 'pages/ota/ota_page.dart';
import 'pages/watch/pages/watch_face_page.dart';
import 'pages/watch/pages/watch_notification_page.dart';
import 'pages/watch/pages/watch_health_page.dart';
import 'pages/watch/pages/watch_ota_page.dart';

class HoneyBoxApp extends StatelessWidget {
  const HoneyBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HoneyBox',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      // The home is a single connection-aware gate (no separate "enter scan"
      // layer). Function pages are pushed on top via named routes below.
      home: const AppLauncherPage(),
      onGenerateRoute: (settings) {
        final args = settings.arguments as Map<String, String>?;

        Widget page;
        switch (settings.name) {
          case '/image':
            page = ImagePage(
              deviceName: args?['deviceName'] ?? '',
              deviceId: args?['deviceId'] ?? '',
            );
            break;
          case '/danmaku':
            page = DanmakuPage(
              deviceName: args?['deviceName'] ?? '',
              deviceId: args?['deviceId'] ?? '',
            );
            break;
          case '/video':
            page = VideoPage(
              deviceName: args?['deviceName'] ?? '',
              deviceId: args?['deviceId'] ?? '',
            );
            break;
          case '/slideshow':
            page = SlideshowPage(
              deviceName: args?['deviceName'] ?? '',
              deviceId: args?['deviceId'] ?? '',
            );
            break;
          case '/stream':
            page = StreamPage(
              deviceName: args?['deviceName'] ?? '',
              deviceId: args?['deviceId'] ?? '',
            );
            break;
          case '/wifi':
            page = WifiPage(
              deviceName: args?['deviceName'] ?? '',
              deviceId: args?['deviceId'] ?? '',
            );
            break;
          case '/ebadge-debug':
            page = EBadgeDebugPage(
              deviceName: args?['deviceName'] ?? '',
              deviceId: args?['deviceId'] ?? '',
            );
            break;
          // Drawer / dashboard entries — device-independent, so args are ignored.
          case '/chip-config':
            page = const ChipConfigPage();
            break;
          case '/settings':
            page = const SettingsPage();
            break;
          case '/qiniu-config':
            page = const QiniuConfigPage();
            break;
          case '/qiniu-files':
            page = const QiniuFilesPage();
            break;
          case '/cache':
            page = const CacheManagementPage();
            break;
          case '/ota':
            page = const OtaPage();
            break;
          // Watch feature pages. Health consumes the connected device details.
          case '/watch-face':
            page = const WatchFacePage();
            break;
          case '/watch-notification':
            page = const WatchNotificationPage();
            break;
          case '/watch-health':
            page = WatchHealthPage(
              deviceName: args?['deviceName'] ?? 'Watch',
              deviceId: args?['deviceId'] ?? '',
            );
            break;
          case '/watch-ota':
            page = const WatchOtaPage();
            break;
          default:
            page = const EBadgeAppRoot();
        }

        return MaterialPageRoute(
          builder: (context) => page,
          settings: settings,
        );
      },
    );
  }
}
