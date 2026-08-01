// test/services/update_service_asset_match_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/update_service.dart';

void main() {
  test('picks first .apk asset, ignores source archives', () {
    final assets = [
      {'name': 'v0.9.0.zip', 'browser_download_url': 'https://x/z.zip'},
      {'name': 'v0.9.0.tar.gz', 'browser_download_url': 'https://x/t.tgz'},
      {'name': 'HoneyBox.apk', 'browser_download_url': 'https://x/a.apk'},
    ];
    expect(UpdateService.pickApkUrl(assets), 'https://x/a.apk');
  });

  test('matches legacy ebadge-named apk too', () {
    final assets = [
      {'name': 'ebadge-0.8.5.apk', 'browser_download_url': 'https://x/e.apk'},
    ];
    expect(UpdateService.pickApkUrl(assets), 'https://x/e.apk');
  });

  test('returns empty when no apk asset', () {
    final assets = [
      {'name': 'src.zip', 'browser_download_url': 'https://x/s.zip'},
    ];
    expect(UpdateService.pickApkUrl(assets), '');
  });

  test('skips apk asset with empty url', () {
    final assets = [
      {'name': 'HoneyBox.apk', 'browser_download_url': ''},
      {'name': 'backup.apk', 'browser_download_url': 'https://x/b.apk'},
    ];
    expect(UpdateService.pickApkUrl(assets), 'https://x/b.apk');
  });
}
