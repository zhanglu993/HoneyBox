import 'package:flutter_riverpod/flutter_riverpod.dart';

enum OtaOwner { ota, normalConnection, capture }

class OtaOwnershipResult {
  final bool success;
  final String? reason;
  const OtaOwnershipResult(this.success, [this.reason]);
}

class OtaOwnership extends StateNotifier<OtaOwner?> {
  OtaOwnership() : super(null);
  OtaOwner? get owner => state;

  OtaOwnershipResult acquire(OtaOwner owner) {
    if (state == null) {
      state = owner;
      return const OtaOwnershipResult(true);
    }
    final reason = switch (state!) {
      OtaOwner.capture => '采集正在占用蓝牙，请先停止采集',
      OtaOwner.normalConnection => '普通连接正在占用蓝牙，请先断开设备',
      OtaOwner.ota => 'OTA 正在占用蓝牙，请先结束升级',
    };
    return OtaOwnershipResult(false, reason);
  }

  void release(OtaOwner owner) {
    if (mounted && state == owner) state = null;
  }

  /// For widget dispose: provider state must not change while the tree is
  /// being torn down, so the release happens right after the frame.
  void releaseDeferred(OtaOwner owner) =>
      Future.microtask(() => release(owner));
}

final otaOwnershipProvider =
    StateNotifierProvider<OtaOwnership, OtaOwner?>((ref) => OtaOwnership());
