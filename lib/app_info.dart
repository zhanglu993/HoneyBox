import 'package:package_info_plus/package_info_plus.dart';

/// Central app metadata.
///
/// [version] is filled in at startup from the platform package info (see
/// [init]), so it always matches the `version:` field in pubspec.yaml with no
/// manual syncing. The literal below is only a pre-[init] fallback.
class AppInfo {
  AppInfo._();

  static String version = '0.8.11';

  /// Reads the real package version. Call once during startup, before the UI
  /// reads [version] (e.g. the drawer footer or the update check).
  static Future<void> init() async {
    final info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) version = info.version;
  }
}
