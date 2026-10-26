import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'qiniu_config.dart';
import 'qiniu_credential_store.dart';
import 'qiniu_storage_service.dart';
import 'qiniu_transfer.dart';

final qiniuControllerProvider =
    ChangeNotifierProvider<QiniuController>((ref) => QiniuController());

/// Serializes configuration changes and network operations across both pages.
class QiniuController extends ChangeNotifier {
  final QiniuCredentialStore store;
  final QiniuStorageService service;
  QiniuController(
      {this.store = const QiniuCredentialStore(), QiniuStorageService? service})
      : service = service ?? QiniuStorageService();
  QiniuConfig? config;
  Future<void>? _load;
  QiniuTransfer? _transfer;
  bool busy = false, _disposed = false;
  String status = '', error = '';
  int done = 0, total = 0;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> ensureLoaded() => _load ??= _initialize();
  Future<void> _initialize() async {
    try {
      await run('读取本机配置', (task) async {
        config = await store.load();
      });
    } catch (_) {
      /* Error is observable; the user can retry or clear credentials. */
    }
  }

  Future<T> run<T>(
      String title, Future<T> Function(QiniuTransfer) action) async {
    if (busy) throw StateError('请等待当前操作完成');
    busy = true;
    status = title;
    error = '';
    done = 0;
    total = 0;
    final transfer = QiniuTransfer(onProgress: (n, t) {
      done = n;
      total = t;
      _notify();
    });
    _transfer = transfer;
    _notify();
    try {
      final result = await action(transfer);
      status = '$title完成';
      return result;
    } catch (e) {
      // No raw platform/network exceptions: they can contain keys or signed URLs.
      error = e is QiniuException ? e.message : '操作失败，请检查本机权限、文件和配置后重试';
      status = error;
      rethrow;
    } finally {
      busy = false;
      _transfer = null;
      _notify();
    }
  }

  Future<void> save(QiniuConfig next) => run('保存配置', (task) async {
        await store.save(next);
        config = next;
      });
  Future<void> testConnection(QiniuConfig next) => run('测试连接', (task) async {
        Future<void> check() async {
          final page = await service.list(next,
              prefix: next.prefix, limit: 1, transfer: task);
          if (next.downloadDomain.isEmpty) return;
          await service.checkDownload(next, task,
              key: page.items.isEmpty ? null : page.items.first.key);
        }

        await check().timeout(const Duration(seconds: 20), onTimeout: () {
          task.cancel();
          throw const QiniuException('连接测试超时（20 秒），请检查网络或手动选择存储区域后重试');
        });
      });
  Future<void> clear() => run('清除配置', (task) async {
        await store.clear();
        config = null;
      });
  void cancel() => _transfer?.cancel();
  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
