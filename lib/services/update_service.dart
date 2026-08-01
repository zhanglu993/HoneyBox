import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Outcome of an update check against the project's Gitee release page.
class UpdateInfo {
  /// Latest release version, leading `v` stripped (e.g. `0.8.0`).
  final String latestVersion;

  /// The version this app is currently running.
  final String currentVersion;

  /// Direct download URL of the latest release's `.apk` asset (empty if none).
  final String apkUrl;

  /// The release notes (`body`) as shown on Gitee.
  final String releaseNotes;

  /// True when [latestVersion] is newer than [currentVersion] and an APK asset
  /// is available to download.
  final bool hasUpdate;

  /// SHA-256 the release declares for the APK (lower-case hex), parsed from the
  /// release notes; empty when the release doesn't declare one. When present it
  /// enables a strong integrity check on both download and cache reuse.
  final String apkSha256;

  const UpdateInfo({
    required this.latestVersion,
    required this.currentVersion,
    required this.apkUrl,
    required this.releaseNotes,
    required this.hasUpdate,
    this.apkSha256 = '',
  });
}

/// Checks the project's **public** Gitee repository for a newer release APK and
/// downloads it. The repo is public, so the Releases API is read anonymously —
/// no access token is embedded in the shipped app.
class UpdateService {
  UpdateService._();

  static const String _owner = 'realmcu';
  static const String _repo = 'HoneyBox';

  /// Gitee Releases API — latest release of the repo.
  static const String _latestReleaseApi =
      'https://gitee.com/api/v5/repos/$_owner/$_repo/releases/latest';

  /// Selects the download URL of the first asset whose name ends with `.apk`
  /// (case-insensitive) and has a non-empty URL. Ignores Gitee's auto-attached
  /// source archives (`.zip` / `.tar.gz`). Returns '' when none qualifies.
  static String pickApkUrl(List<dynamic> assets) {
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = (asset['name'] as String? ?? '').toLowerCase();
      final url = asset['browser_download_url'] as String? ?? '';
      if (name.endsWith('.apk') && url.isNotEmpty) return url;
    }
    return '';
  }

  /// Queries the latest release and compares it with [currentVersion].
  /// Throws on network / parse errors so the caller can surface them.
  static Future<UpdateInfo> checkForUpdate(String currentVersion) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(_latestReleaseApi));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('Gitee 返回状态码 ${resp.statusCode}');
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final tag = (json['tag_name'] as String? ?? '').trim();
      final latest = tag.replaceFirst(RegExp(r'^[vV]'), '');
      final notes = (json['body'] as String? ?? '').trim();

      final apkUrl = pickApkUrl(json['assets'] as List<dynamic>? ?? const []);

      return UpdateInfo(
        latestVersion: latest.isEmpty ? currentVersion : latest,
        currentVersion: currentVersion,
        apkUrl: apkUrl,
        releaseNotes: notes,
        hasUpdate: latest.isNotEmpty &&
            apkUrl.isNotEmpty &&
            _isNewer(latest, currentVersion),
        apkSha256: _parseSha256(notes),
      );
    } finally {
      client.close();
    }
  }

  /// App-private directory where update APKs are stored. The app-specific
  /// external dir installs most reliably; falls back to the cache dir.
  static Future<Directory> _apkDir() async =>
      await getExternalStorageDirectory() ?? await getTemporaryDirectory();

  /// File name of the cached APK for [version], e.g. `update-0.8.3.apk`.
  static String _apkName(String version) => 'update-$version.apk';

  /// Returns the locally cached APK for [version] **only if** it passes the
  /// integrity checks: a sidecar records the expected byte count, the file's
  /// current length matches it, and the file starts with the ZIP/APK magic.
  /// When [expectedSha256] is non-empty the file must additionally hash to
  /// exactly it (strong check); when empty only the size + magic checks apply
  /// (older releases that declare no digest). Returns null when there's no
  /// trustworthy cached package — the caller should then download a fresh one.
  static Future<File?> cachedApk(String version,
      {String expectedSha256 = ''}) async {
    try {
      final dir = await _apkDir();
      final file = File('${dir.path}/${_apkName(version)}');
      if (!await file.exists()) return null;
      final sidecar = File('${file.path}.size');
      if (!await sidecar.exists()) return null;
      final expected = int.tryParse((await sidecar.readAsString()).trim());
      if (expected == null || expected <= 0) return null;
      if (await file.length() != expected) return null;
      if (!await _looksLikeApk(file)) return null;
      // Strong check when the release declares a digest: the cached bytes must
      // hash to exactly it. Falls back to the size + magic checks above when no
      // digest is available.
      if (expectedSha256.isNotEmpty &&
          await _sha256OfFile(file) != expectedSha256.toLowerCase()) {
        return null;
      }
      return file;
    } catch (_) {
      return null;
    }
  }

  /// Cheap sanity check that [file] is a real APK (a ZIP): the first four bytes
  /// are the local-file-header magic `PK\x03\x04`.
  static Future<bool> _looksLikeApk(File file) async {
    final raf = await file.open();
    try {
      final head = await raf.read(4);
      return head.length == 4 &&
          head[0] == 0x50 &&
          head[1] == 0x4B &&
          head[2] == 0x03 &&
          head[3] == 0x04;
    } finally {
      await raf.close();
    }
  }

  /// Streams [file] through SHA-256, returning the lower-case hex digest.
  static Future<String> _sha256OfFile(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  /// Extracts a declared SHA-256 (lower-case hex) from release [notes], if any.
  /// Recognises forms like `sha256: <hex>`, `SHA-256 = <hex>`, or the keyword
  /// followed by the 64-hex digest. Returns '' when none is present.
  static String _parseSha256(String notes) {
    final m =
        RegExp(r'sha-?256[^0-9a-f]{0,10}([0-9a-f]{64})', caseSensitive: false)
            .firstMatch(notes);
    return m == null ? '' : m.group(1)!.toLowerCase();
  }

  /// Downloads the [version] APK from [url] to an app-private file, reporting
  /// fractional progress (0–1), or `null` progress when the server omits a
  /// content length. Rejects a truncated transfer; when [expectedSha256] is
  /// non-empty, also rejects a digest mismatch. On success records the verified
  /// byte count in a sidecar so [cachedApk] can trust the file later, and
  /// prunes APKs left over from other versions. Returns the saved file; throws
  /// on failure.
  static Future<File> downloadApk(
    String url,
    String version, {
    void Function(double? progress)? onProgress,
    String expectedSha256 = '',
  }) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('下载失败，状态码 ${resp.statusCode}');
      }

      final dir = await _apkDir();
      final file = File('${dir.path}/${_apkName(version)}');
      final sidecar = File('${file.path}.size');
      // Drop any stale completion marker first, so an interrupted download can
      // never leave a half-written file looking "verified".
      if (await sidecar.exists()) await sidecar.delete();

      final total = resp.contentLength; // -1 when unknown
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in resp) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(total > 0 ? received / total : null);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      // A size mismatch means the connection dropped mid-transfer; discard the
      // partial file rather than offer it for install.
      if (total > 0 && received != total) {
        await file.delete();
        throw HttpException('下载不完整（$received/$total 字节）');
      }

      // Strong integrity check when the release declares a digest.
      if (expectedSha256.isNotEmpty) {
        final actual = await _sha256OfFile(file);
        if (actual != expectedSha256.toLowerCase()) {
          await file.delete();
          throw const HttpException('安装包校验失败（SHA-256 不匹配）');
        }
      }

      // Record the confirmed size, then clear out other versions' leftovers.
      await sidecar.writeAsString('$received');
      await _pruneOthers(dir, _apkName(version));
      return file;
    } finally {
      client.close();
    }
  }

  /// Deletes cached `update-*.apk` files (and their `.size` sidecars) that
  /// belong to a version other than [keepName], plus any legacy `update.apk`
  /// left by older builds. Best-effort; ignores errors.
  static Future<void> _pruneOthers(Directory dir, String keepName) async {
    try {
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final base =
            name.endsWith('.size') ? name.substring(0, name.length - 5) : name;
        final isVersioned = base.startsWith('update-') && base.endsWith('.apk');
        final isLegacy = base == 'update.apk'; // pre-versioned download name
        if ((isVersioned || isLegacy) && base != keepName) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// True when dotted version [latest] is strictly greater than [current].
  /// Missing trailing parts are treated as 0 (so `0.8` == `0.8.0`).
  static bool _isNewer(String latest, String current) {
    final l = _parts(latest);
    final c = _parts(current);
    final n = l.length > c.length ? l.length : c.length;
    for (var i = 0; i < n; i++) {
      final lv = i < l.length ? l[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (lv != cv) return lv > cv;
    }
    return false;
  }

  static List<int> _parts(String v) => v
      .split('+')
      .first
      .split('.')
      .map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
}
