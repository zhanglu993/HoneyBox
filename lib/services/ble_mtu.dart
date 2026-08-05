import 'dart:async';

import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

/// Minimum ATT MTU mandated by the BLE spec. Every platform also reports this
/// value before negotiation has produced anything better.
const int kMinAttMtu = 23;

/// Largest ATT MTU the BLE spec allows.
const int kMaxAttMtu = 517;

/// Bytes of frame data per KS_FRAME write = `(MTU - 3) - 13` (L2 + KS header,
/// no L1). Floored at 1.
int streamChunkSizeForMtu(int mtu) {
  final chunk = (mtu - 3) - 13;
  return chunk < 1 ? 1 : chunk;
}

/// Keep only a plausible negotiated MTU, otherwise fall back to the spec
/// minimum.
int resolveAttMtu(int? reported) {
  if (reported == null || reported < kMinAttMtu || reported > kMaxAttMtu) {
    return kMinAttMtu;
  }
  return reported;
}

/// Read the ATT MTU the stack has already negotiated for [remoteId].
///
/// `BluetoothDevice.requestMtu` is Android-only in flutter_blue_plus: on every
/// other platform it throws before the plugin is consulted, which leaves the
/// connection pinned at [kMinAttMtu] and chunks stream frames into 7-byte
/// writes. The Windows plugin does answer the platform-level call, replying
/// through `onMtuChanged` with the PDU size the GATT session negotiated, so ask
/// it directly.
///
/// Returns [kMinAttMtu] when the platform reports nothing usable in [timeout].
Future<int> negotiatePlatformMtu(
  DeviceIdentifier remoteId, {
  int desired = 512,
  Duration timeout = const Duration(seconds: 2),
  FlutterBluePlusPlatform? platform,
}) async {
  final api = platform ?? FlutterBluePlusPlatform.instance;
  final reported = Completer<int>();
  // Subscribe before requesting: the plugin may answer synchronously enough
  // that a later subscription would miss the only report.
  final subscription = api.onMtuChanged.listen(
    (response) {
      if (reported.isCompleted ||
          response.remoteId != remoteId ||
          response.mtu <= kMinAttMtu) {
        return;
      }
      reported.complete(response.mtu);
    },
    onError: (Object _) {
      if (!reported.isCompleted) reported.complete(kMinAttMtu);
    },
  );
  try {
    await api.requestMtu(
      BmMtuChangeRequest(remoteId: remoteId, mtu: desired),
    );
    return resolveAttMtu(await reported.future.timeout(timeout));
  } catch (_) {
    return kMinAttMtu;
  } finally {
    await subscription.cancel();
  }
}
