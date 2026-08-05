import 'dart:async';

import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_mtu.dart';

/// Stands in for the plugin: records the request and replays whatever the test
/// scripted on [onMtuChanged].
base class _FakePlatform extends FlutterBluePlusPlatform {
  _FakePlatform({this.replyWith, this.requestThrows = false});

  final BmMtuChangedResponse? replyWith;
  final bool requestThrows;
  final List<BmMtuChangeRequest> requests = [];
  final StreamController<BmMtuChangedResponse> _mtuChanged =
      StreamController<BmMtuChangedResponse>.broadcast();
  int listens = 0;

  @override
  Stream<BmMtuChangedResponse> get onMtuChanged {
    listens++;
    return _mtuChanged.stream;
  }

  @override
  Future<bool> requestMtu(BmMtuChangeRequest request) async {
    requests.add(request);
    if (requestThrows) throw StateError('unsupported');
    final reply = replyWith;
    if (reply != null) {
      // The Windows plugin answers asynchronously through the event channel.
      scheduleMicrotask(() => _mtuChanged.add(reply));
    }
    return true;
  }

  Future<void> close() => _mtuChanged.close();
}

const DeviceIdentifier _remote = DeviceIdentifier('AA:BB:CC:DD:EE:FF');
const DeviceIdentifier _other = DeviceIdentifier('11:22:33:44:55:66');

void main() {
  group('streamChunkSizeForMtu', () {
    test('subtracts the L2 and KS headers from the ATT payload', () {
      expect(streamChunkSizeForMtu(517), 501);
      expect(streamChunkSizeForMtu(247), 231);
    });

    test('the 23-byte default leaves a chunk too small to stream', () {
      // 7 bytes per write is what stalled Windows projection; the formula is
      // kept so the regression stays visible rather than silently clamped.
      expect(streamChunkSizeForMtu(23), 7);
    });

    test('never returns a non-positive chunk', () {
      expect(streamChunkSizeForMtu(0), 1);
      expect(streamChunkSizeForMtu(16), 1);
    });
  });

  group('resolveAttMtu', () {
    test('keeps a plausible negotiated value', () {
      expect(resolveAttMtu(517), 517);
      expect(resolveAttMtu(247), 247);
      expect(resolveAttMtu(23), 23);
    });

    test('falls back to the spec minimum for missing or absurd values', () {
      expect(resolveAttMtu(null), kMinAttMtu);
      expect(resolveAttMtu(0), kMinAttMtu);
      expect(resolveAttMtu(-1), kMinAttMtu);
      expect(resolveAttMtu(kMaxAttMtu + 1), kMinAttMtu);
    });
  });

  group('negotiatePlatformMtu', () {
    test('asks the platform and adopts the reported PDU size', () async {
      final platform = _FakePlatform(
        replyWith: BmMtuChangedResponse(remoteId: _remote, mtu: 517),
      );
      addTearDown(platform.close);

      final mtu = await negotiatePlatformMtu(_remote, platform: platform);

      expect(mtu, 517);
      expect(platform.requests, hasLength(1));
      expect(platform.requests.single.remoteId, _remote);
      expect(streamChunkSizeForMtu(mtu), 501);
    });

    test('subscribes before requesting so a fast reply is not missed',
        () async {
      final platform = _FakePlatform(
        replyWith: BmMtuChangedResponse(remoteId: _remote, mtu: 247),
      );
      addTearDown(platform.close);

      expect(platform.listens, 0);
      final pending = negotiatePlatformMtu(_remote, platform: platform);

      expect(platform.listens, 1);
      expect(await pending, 247);
    });

    test('ignores reports for a different device', () async {
      final platform = _FakePlatform(
        replyWith: BmMtuChangedResponse(remoteId: _other, mtu: 517),
      );
      addTearDown(platform.close);

      final mtu = await negotiatePlatformMtu(
        _remote,
        platform: platform,
        timeout: const Duration(milliseconds: 50),
      );

      expect(mtu, kMinAttMtu);
    });

    test('falls back to the default when the platform never reports', () async {
      final platform = _FakePlatform();
      addTearDown(platform.close);

      final mtu = await negotiatePlatformMtu(
        _remote,
        platform: platform,
        timeout: const Duration(milliseconds: 50),
      );

      expect(mtu, kMinAttMtu);
    });

    test('falls back to the default when the platform call fails', () async {
      final platform = _FakePlatform(requestThrows: true);
      addTearDown(platform.close);

      final mtu = await negotiatePlatformMtu(_remote, platform: platform);

      expect(mtu, kMinAttMtu);
    });

    test('a pre-negotiation echo of 23 does not settle the result', () async {
      final platform = _FakePlatform(
        replyWith: BmMtuChangedResponse(remoteId: _remote, mtu: 23),
      );
      addTearDown(platform.close);

      final mtu = await negotiatePlatformMtu(
        _remote,
        platform: platform,
        timeout: const Duration(milliseconds: 50),
      );

      expect(mtu, kMinAttMtu);
    });
  });
}
