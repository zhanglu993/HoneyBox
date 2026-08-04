# HoneyBox Windows BLE Camera Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reuse HoneyBox's Android/Dart streaming framework to encode the Windows camera as H.264, JPEG, and MSV1 and deliver the frames over the existing FFC4/FFC5 BLE Stream Service.

**Architecture:** Shared Dart keeps ownership of BLE discovery, the raw-L2 stream protocol, transport lifecycle, and the page send pump. Windows publishes the same immutable RGBA camera frame to both the Flutter texture and a bounded `CameraEncodingSession`; codec backends live in `windows/media`, while `windows/camera` owns the worker, generation gates, and Android-compatible encoder channels/events. Delivery is deliberately vertical: harden Dart first, complete and device-verify H.264, then add JPEG and MSV1 through the same backend interface.

**Tech Stack:** Flutter/Dart, `flutter_blue_plus`, Windows C++17, Media Foundation synchronous H.264 Encoder MFT, Windows Imaging Component, `honey_media_core`, CMake/CTest, PowerShell.

## Global Constraints

- Work only in the existing `codex/windows-media-parity` worktree.
- Preserve the existing MethodChannel `ebadge/encoder`, EventChannel `ebadge/encoder/events`, FFC4/FFC5 raw-L2 bytes, `KS_OPEN/ACK/FRAME/CLOSE/CREDIT/REPORT`, MTU calculation, and Android normal behavior.
- Implementation and acceptance order is fixed: H.264, then JPEG, then MSV1. Do not start JPEG/MSV1 production code until the H.264 device gate passes.
- H.264 defaults are exactly `368x368`, `15fps`, `150000bps`, Baseline/Constrained Baseline semantics, CBR, zero B frames, Annex-B, and SPS/PPS before every streamed IDR.
- H.264 streaming starts with two encoder permits; a permit is replenished after each complete frame send attempt. Skip camera input before encoding when no permit exists; never drop an already encoded H.264 P-frame.
- JPEG uses WIC and marks every frame as key. MSV1 calls the existing `hmc_msv1_encode` C ABI directly and preserves previous-frame, skip-threshold, explicit-key, and periodic-key semantics.
- The same transformed immutable RGBA frame feeds preview and encoding. Capture callbacks and Flutter platform threads must never perform codec work.
- All queues are bounded, every pending Future completes on failure/abort/dispose, and camera, encoding, BLE connection, projection, and EventChannel sink generations remain separate.
- `recordToFile=true` returns `unsupported_feature`; no local recording, WiFi work, external codec/runtime, camera controls, encoded preview, or generated plugin registration edits are in scope.
- A missing local H.264 MFT returns `codec_unavailable`; a nonzero device ACK is `stream_rejected`. Never infer a proprietary meaning from an unknown ACK result byte.
- Windows 10/11 x64 is the floor. The first H.264 slice enumerates synchronous/local Media Foundation encoders; hardware asynchronous MFT support is a separate future milestone.
- H.264 must pass the current real target device. JPEG/MSV1 software and protocol tests are mandatory; device output is conditional on the current firmware accepting their `KS_OPEN` codec values.
- Every task follows RED -> GREEN -> focused regression -> task-local Chinese commit. Stage only the files listed by that task.

## File Map

### Shared Dart

- `lib/services/ble_write_queue.dart`: generation-safe FIFO for every FFC1/FFC4 GATT write.
- `lib/services/ble_gatt_profile.dart`: pure characteristic-pair selection and write-mode policy.
- `lib/services/ble_manager.dart`: connection lifecycle, independent command/stream initialization, MTU, notifications, and stream availability changes.
- `lib/services/stream_protocol.dart`: `StreamSession` open/credit/retransmit state machine and strict FFC5 parser.
- `lib/services/stream_transport.dart`: transport adapter plus availability-change contract.
- `lib/pages/stream/stream_page.dart`: projection generation, handshake ordering, send pump, disconnect teardown, and H.264 permit replenishment.

### Windows media layer

- `windows/media/include/honey_media_windows/encoder_types.h`: codec-independent config, input view, encoded frame, stats, and callbacks.
- `windows/media/include/honey_media_windows/encoder_backend.h`: one backend lifecycle with 0..N outputs per input.
- `windows/media/src/encoder_backend_factory.cpp`: the only format-to-backend switch.
- `windows/media/src/rgba_nv12.{h,cpp}`: deterministic RGBA8888-to-NV12 conversion.
- `windows/media/src/h264_annex_b.{h,cpp}`: NAL parsing, sequence-header caching, and IDR normalization.
- `windows/media/src/media_foundation_h264_encoder.{h,cpp}`: synchronous Media Foundation H.264 MFT backend.
- `windows/media/include/honey_media_windows/jpeg_codec.h` and `windows/media/src/jpeg_codec.cpp`: public, memory-backed WIC JPEG primitive.
- `windows/media/src/jpeg_encoder_backend.{h,cpp}`: JPEG implementation of `EncoderBackend`.
- `windows/media/src/msv1_encoder_backend.{h,cpp}`: `honey_media_core` MSV1 implementation of `EncoderBackend`.

### Windows camera layer

- `windows/camera/include/honey_camera_windows/camera_encoding_session.h` and `windows/camera/src/camera_encoding_session.cpp`: bounded latest-frame worker, fps gate, permits, stats, and generation-safe callbacks.
- `windows/camera/include/honey_camera_windows/encoder_channel.h`: camera frame tap plus encoding-session dependency.
- `windows/camera/src/camera_texture_controller.cpp`: nonblocking fan-out of the same RGBA owner.
- `windows/camera/src/encoder_channel.cpp`: parse Android wire config and emit exact Android event maps.
- `windows/media/src/windows_media_plugin.cpp`: construct and tear down the backend factory/session before closing the camera.

### Tests and evidence

- New Dart tests: `stream_protocol_test.dart`, `ble_write_queue_test.dart`, `ble_gatt_profile_test.dart`, `stream_transport_test.dart`, and `stream_page_transport_test.dart`.
- New Windows tests: RGBA/NV12, Annex-B, H.264 MFT, JPEG codec/backend, MSV1 backend, and camera encoding session.
- `docs/superpowers/reports/2026-08-04-windows-ble-camera-streaming-verification.md`: actual build, automated, BLE device, and stability evidence.

---

### Task 1: Make `StreamSession` generation-safe and strict

**Files:**
- Modify: `lib/services/stream_protocol.dart:87-369`
- Create: `test/services/stream_protocol_test.dart`

**Interfaces:**
- Consumes: existing `SendL2`, `buildStreamOpen`, `buildStreamChunk`, and frozen protocol constants.
- Produces: the existing `open/sendFrame/close/onDisconnect/onNotify` API plus injectable timeouts, `StreamOpenFailure lastOpenFailure`, and `int? lastAckResult`.

- [ ] **Step 1: Write the failing lifecycle and parser tests**

```dart
enum StreamOpenFailure { none, timeout, rejected, transport }

final sent = <Uint8List>[];
final session = StreamSession(
  send: (l2) async => sent.add(Uint8List.fromList(l2)),
  chunkSize: () => 4,
  openTimeout: const Duration(milliseconds: 20),
  creditTimeout: const Duration(milliseconds: 20),
);

test('matching ACK opens and mismatched or truncated ACK is ignored', () async {
  final opening = session.open(StreamCodec.h264, 368, 368, 15);
  session.onNotify(Uint8List.fromList([BleCmd.stream, 0, BleCmdStreamKey.ack, 0, 1, 0xff]));
  expect(session.state, StreamState.opening);
  session.onNotify(_ack(sid: _sidFromOpen(sent.single), result: 0, credits: 2));
  expect(await opening, isTrue);
  expect(session.credits, 2);
});

test('close and disconnect complete pending waits and stale ACK cannot reopen', () async {
  final opening = session.open(StreamCodec.h264, 368, 368, 15);
  session.onDisconnect();
  expect(await opening, isFalse);
  session.onNotify(_ack(sid: 1, result: 0, credits: 2));
  expect(session.state, StreamState.idle);
});

test('sendFrame observes every queued write failure', () async {
  var write = 0;
  final failing = StreamSession(
    send: (_) => ++write == 1 ? Future<void>.error(StateError('first')) : Future<void>.value(),
    chunkSize: () => 2,
  );
  await _openUnlimited(failing);
  expect(await failing.sendFrame(Uint8List(6)), isFalse);
});
```

Include named cases for open timeout, nonzero ACK result, foreign CREDIT, credit timeout, REPORT intersection retransmission, eviction after three frames, and malformed declared lengths.

- [ ] **Step 2: Run the new tests and verify RED**

Run: `flutter test test/services/stream_protocol_test.dart`

Expected: FAIL because timeout injection, strict SID/length handling, failure classification, generation cancellation, and all-write observation are absent.

- [ ] **Step 3: Add constructor seams and operation generation**

```dart
StreamSession({
  required this.send,
  required this.chunkSize,
  Duration openTimeout = const Duration(seconds: 5),
  Duration creditTimeout = const Duration(seconds: 5),
  int retransmitFrameLimit = 3,
})  : _openTimeout = openTimeout,
      _creditTimeout = creditTimeout,
      _retxKeep = retransmitFrameLimit;

int _operationGeneration = 0;
StreamOpenFailure _lastOpenFailure = StreamOpenFailure.none;
int? _lastAckResult;
```

Every `open`, `close`, and `onDisconnect` increments `_operationGeneration`; each timer and async continuation captures it and exits if it is stale. `close` completes the old open Future with `false` before clearing it.

- [ ] **Step 4: Make parsing exact and observe every frame write**

```dart
if (vlen > l2.length - 5) return;
final v = Uint8List.sublistView(l2, 5, 5 + vlen);

final writes = <Future<void>>[];
// Build chunks without changing byte order, credits, or retransmit cache.
writes.add(send(buildStreamChunk(seq, off, total, chunk)));
try {
  await Future.wait(writes, eagerError: false);
} catch (_) {
  return false;
}
return generation == _operationGeneration && _state == StreamState.open;
```

Require matching SID before accepting ACK/CREDIT/REPORT. Validate `gapCount * 6` without overflow before reading gaps.

- [ ] **Step 5: Run focused and neighboring protocol tests**

Run: `flutter test test/services/stream_protocol_test.dart test/services/l1_engine_test.dart test/services/l2_file_transfer_test.dart`

Expected: PASS; existing L1/file-transfer bytes remain unchanged.

- [ ] **Step 6: Commit**

```powershell
git add lib/services/stream_protocol.dart test/services/stream_protocol_test.dart
git commit -m "fix: 加固BLE投屏会话状态机"
```

### Task 2: Replace the GATT write bookkeeping with one bounded FIFO

**Files:**
- Create: `lib/services/ble_write_queue.dart`
- Create: `test/services/ble_write_queue_test.dart`

**Interfaces:**
- Consumes: an operation closure that performs one plugin characteristic write.
- Produces: `BleWriteQueue.enqueue`, `abort`, and `dispose`; every returned Future terminates exactly once.

- [ ] **Step 1: Write failing FIFO, abort, and stale-completion tests**

```dart
typedef BleWriteOperation = Future<void> Function();

final first = Completer<void>();
final order = <int>[];
final fatal = <Object>[];
final queue = BleWriteQueue(onFatalError: (e, _) => fatal.add(e));
final a = queue.enqueue(() async { order.add(1); await first.future; });
final b = queue.enqueue(() async { order.add(2); });
expect(order, [1]);
queue.abort(StateError('disconnect'));
await expectLater(a, throwsStateError);
await expectLater(b, throwsStateError);
first.complete();
await queue.enqueue(() async => order.add(3));
expect(order, [1, 3]);
```

Add exact cases for FIFO, active failure failing all queued entries, one fatal callback, late success/late error after abort, and dispose rejecting new writes.

- [ ] **Step 2: Run the test and verify RED**

Run: `flutter test test/services/ble_write_queue_test.dart`

Expected: FAIL because `BleWriteQueue` does not exist.

- [ ] **Step 3: Implement one entry object and an internal generation**

```dart
class _BleWriteEntry {
  _BleWriteEntry(this.generation, this.operation);
  final int generation;
  final BleWriteOperation operation;
  final Completer<void> done = Completer<void>();
}

class BleWriteQueue {
  BleWriteQueue({required this.onFatalError});
  final void Function(Object, StackTrace) onFatalError;
  final List<_BleWriteEntry> _pending = [];
  _BleWriteEntry? _active;
  int _generation = 0;
  bool _running = false;
  bool _disposed = false;
  Future<void> enqueue(BleWriteOperation operation) {
    if (_disposed) return Future<void>.error(StateError('queue disposed'));
    final entry = _BleWriteEntry(_generation, operation);
    _pending.add(entry);
    _flush();
    return entry.done.future;
  }
  void abort(Object error, [StackTrace? stackTrace]) {
    final failed = <_BleWriteEntry>[
      if (_active case final active?) active,
      ..._pending,
    ];
    _generation++;
    _active = null;
    _pending.clear();
    _running = false;
    for (final entry in failed) {
      if (!entry.done.isCompleted) entry.done.completeError(error, stackTrace);
    }
  }
  void dispose() {
    if (_disposed) return;
    abort(StateError('queue disposed'));
    _disposed = true;
  }
}
```

The completion callback checks its captured generation before draining the queue or invoking `onFatalError`. `abort` clears the active/pending logical generation but leaves the object reusable for a later BLE connection; `dispose` does not.

- [ ] **Step 4: Run the queue tests**

Run: `flutter test test/services/ble_write_queue_test.dart`

Expected: PASS with no unresolved Future after each test tear-down.

- [ ] **Step 5: Commit**

```powershell
git add lib/services/ble_write_queue.dart test/services/ble_write_queue_test.dart
git commit -m "feat: 增加BLE串行写队列"
```

### Task 3: Initialize command and stream GATT pairs independently

**Files:**
- Create: `lib/services/ble_gatt_profile.dart`
- Create: `test/services/ble_gatt_profile_test.dart`
- Modify: `lib/services/ble_manager.dart:44-519`

**Interfaces:**
- Consumes: `BleWriteQueue` from Task 2 and plugin characteristic properties.
- Produces: independent `commandAvailable`, `streamAvailable`, actual write mode, actual MTU, and `Stream<bool> onStreamAvailabilityChanged`.

- [ ] **Step 1: Write failing pure profile tests**

```dart
final profile = BleGattProfile.select(<BleGattCharacteristic<String>>[
  const BleGattCharacteristic('ffc4', '0000FFC4-0000-1000-8000-00805F9B34FB', write: true),
  const BleGattCharacteristic('ffc5', '0000FFC5-0000-1000-8000-00805F9B34FB', notify: true),
]);
expect(profile.commandReady, isFalse);
expect(profile.streamReady, isTrue);
expect(profile.streamTx!.withoutResponse, isFalse);
```

Cover exact four-character UUIDs, Bluetooth-base UUIDs, incomplete pairs, notification/indication, and preference for write-without-response with write-with-response fallback.

- [ ] **Step 2: Run the profile test and verify RED**

Run: `flutter test test/services/ble_gatt_profile_test.dart`

Expected: FAIL because the selector does not exist.

- [ ] **Step 3: Implement the pure descriptor and selector**

```dart
class BleGattEndpoint<T> {
  const BleGattEndpoint(this.value, {required this.withoutResponse});
  final T value;
  final bool withoutResponse;
}

class BleGattProfile<T> {
  final BleGattEndpoint<T>? commandTx;
  final T? commandRx;
  final BleGattEndpoint<T>? streamTx;
  final T? streamRx;
  bool get commandReady => commandTx != null && commandRx != null;
  bool get streamReady => streamTx != null && streamRx != null;
}
```

- [ ] **Step 4: Route all FFC1/FFC4 writes through `BleWriteQueue`**

```dart
Future<void> _write(BleGattEndpoint<BluetoothCharacteristic> endpoint,
                    Uint8List bytes) =>
    _writeQueue.enqueue(() => endpoint.value.write(
      bytes,
      withoutResponse: endpoint.withoutResponse,
    ));
```

Remove the `Map<Uint8List, Completer<void>>`. On cleanup call `abort(StateError('BLE connection ended'))`; on dispose call `dispose()`. Capture a connection generation in the connection-state subscription so an old callback cannot disconnect a replacement connection.

- [ ] **Step 5: Refactor discovery without the FFC1/FFC2 early return**

Request MTU once after discovery. Initialize L1/file transfer only when `commandReady`; initialize and subscribe FFC5 whenever `streamReady`, regardless of command availability. Emit `true` only after FFC5 subscription succeeds and emit `false` before clearing an active pair.

- [ ] **Step 6: Run focused and existing BLE tests**

Run: `flutter test test/services/ble_write_queue_test.dart test/services/ble_gatt_profile_test.dart test/services/l1_engine_test.dart test/services/l2_file_transfer_test.dart`

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File test/windows/flutter_blue_plus_winrt_patch_test.ps1`

Expected: PASS; no hard-coded 512-byte stream chunk and no generated plugin edit.

- [ ] **Step 7: Commit**

```powershell
git add lib/services/ble_gatt_profile.dart lib/services/ble_manager.dart test/services/ble_gatt_profile_test.dart
git commit -m "fix: 分离BLE命令与投屏通道初始化"
```

### Task 4: Propagate transport availability and projection generation

**Files:**
- Modify: `lib/services/stream_transport.dart:20-78`
- Modify: `lib/pages/stream/stream_page.dart:31-47,136-151,495-732`
- Create: `test/services/stream_transport_test.dart`
- Create: `test/pages/stream/stream_page_transport_test.dart`

**Interfaces:**
- Consumes: `BleManager.onStreamAvailabilityChanged` and Task 1's failure metadata.
- Produces: `Stream<bool> StreamTransport.availabilityChanges`, injectable `transportFactory`, and a projection generation gate.

- [ ] **Step 1: Write failing transport delegation tests**

```dart
abstract class StreamTransport {
  bool get isAvailable;
  Stream<bool> get availabilityChanges;
  int get chunkSize;
  Future<void> send(Uint8List l2);
  Stream<Uint8List> get notifications;
}

test('BLE transport forwards only stream availability changes', () async {
  final manager = _FakeBleManager();
  final transport = BleStreamTransport(manager);
  expectLater(transport.availabilityChanges, emitsInOrder([true, false]));
  manager.emitStreamAvailability(true);
  manager.emitStreamAvailability(false);
});
```

- [ ] **Step 2: Write failing widget tests for ordering and stale teardown**

```dart
testWidgets('disconnect while opening never starts native encoding', (tester) async {
  final transport = FakeStreamTransport(available: true);
  await mountReadyPage(tester, transport: transport, encoder: encoder);
  await tester.tap(find.byKey(const Key('stream-shutter')));
  transport.emitAvailability(false);
  await tester.pump();
  expect(encoder.startCalls, isEmpty);
  expect(find.textContaining('连接已断开'), findsOneWidget);
});

testWidgets('late false from an old transport cannot stop a replacement', (tester) async {
  // Start, stop, start with a second transport; then emit false on the first.
  expect(encoder.stopCount, equals(1));
  expect(find.text('正在投屏'), findsWidgets);
});
```

Also cover handshake-before-encoding, rejected ACK message with raw result, one CLOSE on user stop, H.264 permit after success/failure, subscription cancellation, and late events after dispose.

- [ ] **Step 3: Add the transport contract and test seam**

```dart
final StreamTransport Function(StreamTransportKind kind)? transportFactory;
int _projectionGeneration = 0;
StreamSubscription<bool>? _availabilitySub;

StreamTransport _transportFor(StreamTransportKind kind) =>
    widget.transportFactory?.call(kind) ?? _defaultTransportFor(kind);
```

`BleStreamTransport` forwards the manager stream; the reserved WiFi adapter exposes an empty stream without changing current behavior.

- [ ] **Step 4: Gate every asynchronous page continuation**

At start, capture `final generation = ++_projectionGeneration`. Subscribe before `KS_OPEN`. After `open`, every frame send, and every availability callback, compare both generation and session identity. On `false`: call `session.onDisconnect()` first, stop native encoding, cancel notifications, clear the queue, stop stats, and exit projection UI. `_teardownSession` increments the generation and must not set `_sending=false` in a way that lets an old pump operate a new queue.

- [ ] **Step 5: Run projection and camera widget tests**

Run: `flutter test test/services/stream_transport_test.dart test/pages/stream/stream_page_transport_test.dart test/pages/stream/stream_page_camera_test.dart`

Expected: PASS, including rapid stop/restart and dispose races.

- [ ] **Step 6: Commit**

```powershell
git add lib/services/stream_transport.dart lib/pages/stream/stream_page.dart test/services/stream_transport_test.dart test/pages/stream/stream_page_transport_test.dart
git commit -m "fix: 加固投屏断线与快速重启"
```

### Task 5: Freeze the platform-neutral Windows encoder contract

**Files:**
- Create: `windows/media/include/honey_media_windows/encoder_types.h`
- Create: `windows/media/include/honey_media_windows/encoder_backend.h`
- Create: `windows/media/src/encoder_backend_factory.cpp`
- Modify: `windows/media/include/honey_media_windows/status.h:9-23`
- Modify: `windows/media/src/status.cpp:5-20`
- Modify: `windows/media/tests/status_contract_test.cpp`
- Modify: `windows/media/CMakeLists.txt`

**Interfaces:**
- Consumes: `hmw::Result/Outcome/Error` and immutable RGBA byte ownership from the camera layer.
- Produces: a codec-independent 0..N-output backend contract used by all later Windows tasks.

- [ ] **Step 1: Add failing status-code tests**

```cpp
HMW_TEST(status_contract_exposes_streaming_failures) {
  HMW_EXPECT(hmw::StatusCode(hmw::Status::kCodecUnavailable) ==
             "codec_unavailable");
  HMW_EXPECT(hmw::StatusCode(hmw::Status::kUnsupportedFeature) ==
             "unsupported_feature");
}
```

- [ ] **Step 2: Run status tests and verify RED**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1 -Configuration Debug -TestRegex status_contract`

Expected: compile FAIL because the two enum values are absent.

- [ ] **Step 3: Define exact shared types**

```cpp
enum class EncoderFormat { kH264, kJpeg, kMsv1 };

struct EncodingConfig {
  EncoderFormat format;
  uint32_t width, height, fps, bitrate, i_frame_interval_sec;
  double crop_zoom;
  bool msv1_skip;
  uint32_t msv1_skip_threshold, jpeg_quality;
  bool record_to_file, stream;
};

struct EncoderInputFrame {
  uint32_t width, height;
  int64_t pts_100ns, duration_100ns;
  const uint8_t* rgba;
  size_t rgba_size;
};

struct EncodedFrame {
  std::shared_ptr<const std::vector<uint8_t>> bytes;
  int64_t pts_100ns;
  bool key;
};
```

`EncodingStats` contains `frames`, `keyframes`, `bytes`, `key_bytes`, `fps`, and `last_bytes`. `EncoderCallbacks` carries the encoding generation on every callback; started/stopped use `std::optional<std::string> path`, which is `nullopt` for this slice.

```cpp
struct EncoderCallbacks {
  std::function<void(uint64_t, std::optional<std::string>, uint32_t, uint32_t)>
      on_started;
  std::function<void(uint64_t, EncodedFrame)> on_frame;
  std::function<void(uint64_t, EncodingStats)> on_stats;
  std::function<void(uint64_t, std::optional<std::string>, EncodingStats)>
      on_stopped;
  std::function<void(uint64_t, hmw::Error)> on_error;
  std::function<void(uint64_t, std::string)> on_info;
};
```

- [ ] **Step 4: Define backend lifecycle and one factory switch**

```cpp
class EncoderBackend {
 public:
  virtual ~EncoderBackend() = default;
  virtual hmw::Outcome Start(const EncodingConfig&) = 0;
  virtual hmw::Result<std::vector<EncodedFrame>> Encode(
      const EncoderInputFrame&) = 0;
  virtual hmw::Outcome RequestKeyframe() = 0;
  virtual hmw::Result<std::vector<EncodedFrame>> Drain() = 0;
  virtual hmw::Outcome Stop() = 0;
};

using EncoderBackendFactory = std::function<
    hmw::Result<std::unique_ptr<EncoderBackend>>(EncoderFormat)>;
EncoderBackendFactory CreateDefaultEncoderBackendFactory();
```

Keep the factory cases explicit; until later tasks register a format, return `kCodecUnavailable` rather than a null backend.

- [ ] **Step 5: Run media Debug tests**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1 -Configuration Debug`

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add windows/media/include/honey_media_windows/encoder_types.h windows/media/include/honey_media_windows/encoder_backend.h windows/media/include/honey_media_windows/status.h windows/media/src/encoder_backend_factory.cpp windows/media/src/status.cpp windows/media/tests/status_contract_test.cpp windows/media/CMakeLists.txt
git commit -m "feat: 定义Windows实时编码后端合同"
```

### Task 6: Implement deterministic RGBA/NV12 and Annex-B helpers

**Files:**
- Create: `windows/media/src/rgba_nv12.h`
- Create: `windows/media/src/rgba_nv12.cpp`
- Create: `windows/media/src/h264_annex_b.h`
- Create: `windows/media/src/h264_annex_b.cpp`
- Create: `windows/media/tests/rgba_nv12_test.cpp`
- Create: `windows/media/tests/h264_annex_b_test.cpp`
- Modify: `windows/media/CMakeLists.txt`
- Modify: `windows/media/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: tightly packed RGBA8888 and raw H.264 samples/sequence headers.
- Produces: `RgbaToNv12` and `H264AnnexBNormalizer::Normalize`, both pure and COM-free.

- [ ] **Step 1: Write failing color and validation tests**

```cpp
HMW_TEST(rgba_nv12_converts_known_2x2_rgba_layout) {
  const std::array<uint8_t, 16> rgba = {
      255, 0, 0, 255, 0, 255, 0, 255,
      0, 0, 255, 255, 255, 255, 255, 255};
  const auto nv12 = hmw::internal::RgbaToNv12(2, 2, rgba.data(), rgba.size());
  HMW_EXPECT(nv12.ok());
  HMW_EXPECT(nv12.value->size() == 6U);
  HMW_EXPECT(nv12.value->at(0) != nv12.value->at(2));
}
```

Add exact tests for NV12 UV interleaving, neutral gray, odd dimensions, short input, and multiplication overflow.

- [ ] **Step 2: Write failing H.264 normalization tests**

```cpp
HMW_TEST(h264_annex_b_idr_gets_cached_sps_pps_once) {
  H264AnnexBNormalizer normalizer;
  HMW_EXPECT(normalizer.SetSequenceHeader(kAvccSpsPps).ok());
  const auto out = normalizer.Normalize(kLengthPrefixedIdr, true);
  HMW_EXPECT(out.ok() && out.value->key);
  HMW_EXPECT(CountNalType(out.value->bytes, 7) == 1);
  HMW_EXPECT(CountNalType(out.value->bytes, 8) == 1);
  HMW_EXPECT(CountNalType(out.value->bytes, 5) == 1);
}
```

Cover three/four-byte Annex-B start codes, AVCC length prefixes, already-present SPS/PPS, P-frame key=false, truncated NAL length, and malformed sequence header.

- [ ] **Step 3: Run both filters and verify RED**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1 -Configuration Debug -TestRegex "^(rgba_nv12|h264_annex_b)$"`

Expected: compile FAIL because helpers are absent.

- [ ] **Step 4: Implement bounded conversion and normalization**

Use BT.601 limited-range integer conversion, average chroma over each 2x2 block, clamp every channel, and allocate exactly `width * height * 3 / 2`. Normalize every output NAL to `00 00 00 01`; derive key status from an IDR NAL or the supplied clean-point flag, and prepend cached parameter sets only when a key access unit lacks NAL 7/8.

- [ ] **Step 5: Run focused and full media Debug tests**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1 -Configuration Debug`

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add windows/media/src/rgba_nv12.h windows/media/src/rgba_nv12.cpp windows/media/src/h264_annex_b.h windows/media/src/h264_annex_b.cpp windows/media/tests/rgba_nv12_test.cpp windows/media/tests/h264_annex_b_test.cpp windows/media/CMakeLists.txt windows/media/tests/CMakeLists.txt
git commit -m "feat: 增加H264颜色转换与码流规范化"
```

### Task 7: Implement the synchronous Media Foundation H.264 backend

**Files:**
- Create: `windows/media/src/media_foundation_h264_encoder.h`
- Create: `windows/media/src/media_foundation_h264_encoder.cpp`
- Create: `windows/media/tests/media_foundation_h264_encoder_test.cpp`
- Modify: `windows/media/src/encoder_backend_factory.cpp`
- Modify: `windows/media/CMakeLists.txt`
- Modify: `windows/media/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: Task 5 backend contract and Task 6 helpers.
- Produces: default-factory `kH264` backend with synchronous/local MFT discovery, Baseline output, CBR request, key request, drain, and Annex-B frames.

- [ ] **Step 1: Write failing backend lifecycle tests**

```cpp
HMW_TEST(h264_mft_encodes_annex_b_and_marks_clean_point) {
  auto backend = hmw::internal::CreateMediaFoundationH264Encoder();
  const auto started = backend->Start(H264Config(368, 368, 15, 150000, 6));
  if (!started.ok() && started.error->status == hmw::Status::kCodecUnavailable) {
    HMW_EXPECT(!started.error->message.empty());
    return;
  }
  HMW_EXPECT(started.ok());
  HMW_EXPECT(backend->RequestKeyframe().ok());
  const auto frames = backend->Encode(SolidInputFrame(368, 368));
  HMW_EXPECT(frames.ok());
  HMW_EXPECT(AllFramesAreAnnexB(*frames.value));
  HMW_EXPECT(backend->Drain().ok());
  HMW_EXPECT(backend->Stop().ok());
  HMW_EXPECT(backend->Stop().ok());
}
```

Add config rejection, repeated start, SPS/PPS on IDR, 0..N output, `MF_E_NOTACCEPTING` drain-and-retry, and drain-before-stop cases.

- [ ] **Step 2: Run the H.264 filter and verify RED**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1 -Configuration Debug -TestRegex media_foundation_h264_encoder`

Expected: compile FAIL because the backend is absent.

- [ ] **Step 3: Enumerate only supported synchronous/local encoders**

```cpp
MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
          MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
              MFT_ENUM_FLAG_SORTANDFILTER,
          &nv12_input, &h264_output, &activates, &count);
```

Activate candidates in order and release every `IMFActivate` plus the `CoTaskMemFree` array. Return `kCodecUnavailable` only after all candidates fail. Do not add hardware/async flags in this slice.

- [ ] **Step 4: Configure the MFT in the required order**

Before media types, require CBR, mean bitrate, zero B pictures, and GOP=`fps*iFrameIntervalSec`; skip a candidate that cannot honor those Android-parity properties. Enable low latency when the property is supported. Then set H.264 output type before NV12 input type. Output includes bitrate, frame size/rate, progressive, 1:1 PAR, and `eAVEncH264VProfile_Base`; let the MFT select level. See [Microsoft H.264 encoder requirements](https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-encoder).

- [ ] **Step 5: Implement processing, key requests, and drain**

On the caller's encoding worker thread: create NV12 samples with frame PTS/duration, apply `CODECAPI_AVEncVideoForceKeyFrame` immediately before the next `ProcessInput`, process output until `MF_E_TRANSFORM_NEED_MORE_INPUT`, and handle both MFT-provided and caller-allocated output samples. Stop order is END_OF_STREAM -> DRAIN -> publish all output -> END_STREAMING -> release. Feed every raw sample through `H264AnnexBNormalizer`.

- [ ] **Step 6: Run H.264 and full media tests in Debug/Release**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1 -TestRegex "^(rgba_nv12|h264_annex_b|media_foundation_h264_encoder)$"`

Expected: PASS in Debug and Release, or the capability branch returns only the stable `codec_unavailable` result on a Windows edition with no encoder.

- [ ] **Step 7: Commit**

```powershell
git add windows/media/src/media_foundation_h264_encoder.h windows/media/src/media_foundation_h264_encoder.cpp windows/media/src/encoder_backend_factory.cpp windows/media/tests/media_foundation_h264_encoder_test.cpp windows/media/CMakeLists.txt windows/media/tests/CMakeLists.txt
git commit -m "feat: 接入Windows H264系统编码器"
```

### Task 8: Add the bounded Windows camera encoding session

**Files:**
- Create: `windows/camera/include/honey_camera_windows/camera_encoding_session.h`
- Create: `windows/camera/src/camera_encoding_session.cpp`
- Create: `windows/camera/tests/camera_encoding_session_test.cpp`
- Modify: `windows/camera/include/honey_camera_windows/encoder_channel.h:28-55`
- Modify: `windows/camera/src/camera_texture_controller.cpp:143-295`
- Modify: `windows/camera/CMakeLists.txt`
- Modify: `windows/camera/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: `hmw::EncoderBackendFactory`, camera generation, and shared `CameraFrame`.
- Produces: `Start`, `OfferFrame`, `GrantFramePermit`, `RequestKeyframe`, `Stop`, and `Shutdown` with a single latest-frame slot.

- [ ] **Step 1: Write failing worker and generation tests**

```cpp
HMW_TEST(camera_encoding_session_starts_with_two_h264_permits) {
  FakeBackend backend;
  CameraEncodingSession session(FakeFactory(backend));
  const auto generation = session.Start(7, H264StreamConfig(), callbacks);
  HMW_EXPECT(generation.ok());
  session.OfferFrame(7, Frame(1));
  session.OfferFrame(7, Frame(2));
  session.OfferFrame(7, Frame(3));
  HMW_EXPECT(backend.WaitForEncodeCount(2));
  session.GrantFramePermit();
  HMW_EXPECT(backend.WaitForLastMarker(3));
}
```

Add latest-slot bound, stale camera generation, stale encoding callbacks, fps sampling, key request serialized before encode, request arriving during encode retained, `Drain` before `Stop`, terminal error once, and idempotent joined stop.

- [ ] **Step 2: Run the camera-session filter and verify RED**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-camera-windows-preview.ps1 -Configuration Debug -TestRegex camera_encoding_session`

Expected: compile FAIL because the session is absent.

- [ ] **Step 3: Implement the public session contract**

```cpp
class CameraEncodingSession final {
 public:
  explicit CameraEncodingSession(hmw::EncoderBackendFactory factory);
  hmw::Result<uint64_t> Start(uint64_t camera_generation,
                              hmw::EncodingConfig config,
                              hmw::EncoderCallbacks callbacks);
  void OfferFrame(uint64_t camera_generation, CameraFrame frame) noexcept;
  void GrantFramePermit() noexcept;
  void RequestKeyframe() noexcept;
  hmw::Outcome Stop();
  void Shutdown();
};
```

The worker owns all COM/backend calls. `OfferFrame` only swaps a `std::optional<CameraFrame>` and signals. H.264 stream permits start at two and saturate at two. JPEG/MSV1 do not use permits. Target fps uses `pts_100ns`, not wall time.
When the capture frame has no explicit duration, construct `EncoderInputFrame.duration_100ns` as `10'000'000 / config.fps`. Reject frames whose dimensions or RGBA byte count do not match the normalized active config.

- [ ] **Step 4: Fan out the same immutable RGBA owner**

Append `on_frame(uint64_t, CameraFrame)` to `CameraControllerCallbacks`. In `PublishFrame`, copy the callback, controller generation, and `shared_ptr<const vector<uint8_t>>` while locked; invoke outside the lock before any `registration_pending` early return. The callback may only call `OfferFrame`.

- [ ] **Step 5: Run camera session plus existing preview tests**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-camera-windows-preview.ps1 -Configuration Debug -TestRegex "^(camera_encoding_session|camera_preview|camera_texture)"`

Expected: PASS; preview queue remains bounded and color contract stays RGBA.

- [ ] **Step 6: Commit**

```powershell
git add windows/camera/include/honey_camera_windows/camera_encoding_session.h windows/camera/include/honey_camera_windows/encoder_channel.h windows/camera/src/camera_encoding_session.cpp windows/camera/src/camera_texture_controller.cpp windows/camera/tests/camera_encoding_session_test.cpp windows/camera/CMakeLists.txt windows/camera/tests/CMakeLists.txt
git commit -m "feat: 增加Windows摄像头实时编码会话"
```

### Task 9: Wire Windows encoder methods/events and Dart contract tests

**Files:**
- Modify: `windows/camera/include/honey_camera_windows/encoder_channel.h`
- Modify: `windows/camera/src/encoder_channel.cpp`
- Modify: `windows/media/src/windows_media_plugin.cpp:18-155`
- Modify: `windows/camera/tests/encoder_channel_contract_test.cpp`
- Modify: `windows/camera/tests/windows_encoder_registration_test.cpp`
- Modify: `test/services/encoder_test.dart`

**Interfaces:**
- Consumes: `CameraEncodingSession`, existing Windows registration, and `EncoderConfig.toWire()`.
- Produces: `startEncoding`, `stopEncoding`, `requestKeyframe`, `requestEncoderFrame` and exact `started/frame/stats/stopped/error/info` payloads.

- [ ] **Step 1: Write failing C++ channel contract tests**

```cpp
HMW_TEST(encoder_channel_start_encoding_parses_android_h264_contract) {
  EncodableValue args = EncodingArguments("h264", 368, 368, 15, 150000);
  const auto result = Invoke(channel, "startEncoding", &args);
  HMW_EXPECT(result->successes == 1);
  HMW_EXPECT(fake_session.config->stream);
  HMW_EXPECT(fake_session.config->i_frame_interval_sec == 6U);
}

HMW_TEST(encoder_channel_frame_event_matches_android_payload) {
  fake_session.EmitFrame({Bytes({0,0,0,1,0x65}), 0, true});
  HMW_EXPECT(String(Field(events.back(), "event")) == "frame");
  HMW_EXPECT(Binary(Field(events.back(), "data")).size() == 5U);
  HMW_EXPECT(Boolean(Field(events.back(), "key")));
}
```

Cover all wire fields, start-before-camera, repeated start, bitrate range, `recordToFile=true -> unsupported_feature`, stop idempotence, request forwarding, close-before-camera ordering, queued stale events, and error `code/message/details`. Lock Android's dimension rule: H.264/JPEG clear the low bit and require at least 2 pixels; MSV1 clears the low two bits and clamps to at least 4 pixels. `started.width/height` must equal those normalized dimensions and therefore match `KS_OPEN`.

- [ ] **Step 2: Write failing Dart channel/event tests**

```dart
test('startEncoding sends Android-compatible H264 stream configuration', () async {
  await service.startEncoding(const EncoderConfig(), stream: true);
  expect(calls.single.method, 'startEncoding');
  expect(calls.single.arguments, containsPair('stream', true));
  expect(calls.single.arguments, containsPair('bitrate', 150000));
});

test('frame event forwards Uint8List and key flag', () async {
  final received = Completer<void>();
  late Uint8List data;
  late bool key;
  service.onFrame = (value, isKey) {
    data = value;
    key = isKey;
    received.complete();
  };
  events.add({'event': 'frame', 'data': Uint8List.fromList([1,2]), 'key': true});
  await received.future;
  expect(data, [1, 2]);
  expect(key, isTrue);
});
```

- [ ] **Step 3: Run both suites and verify RED**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-camera-windows-preview.ps1 -Configuration Debug -TestRegex "^(encoder_channel_contract|windows_encoder_registration)$"`

Run: `flutter test test/services/encoder_test.dart`

Expected: FAIL because Windows still returns NotImplemented for encoding methods.

- [ ] **Step 4: Implement parsing and event builders**

Keep codec selection inside the default backend factory. Channel parsing validates types/ranges, passes the current camera generation into `Start`, and maps callbacks to the existing Android fields. `path` is null/empty when recording is disabled. `ErrorEvent` includes stable `code` and bounded `details` without removing `message`.

- [ ] **Step 5: Fix plugin construction and teardown order**

Construct the factory/session before `EncoderChannel`. Destruction order is registration shutdown -> encoding session stop/shutdown -> encoder channel reset -> camera controller close/reset. Do not register a new Flutter plugin/channel.

- [ ] **Step 6: Run channel, Dart, and camera regressions**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-camera-windows-preview.ps1 -Configuration Debug`

Run: `flutter test test/services/encoder_test.dart test/pages/stream/stream_page_camera_test.dart test/pages/stream/stream_page_transport_test.dart`

Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
git add windows/camera/include/honey_camera_windows/encoder_channel.h windows/camera/src/encoder_channel.cpp windows/media/src/windows_media_plugin.cpp windows/camera/tests/encoder_channel_contract_test.cpp windows/camera/tests/windows_encoder_registration_test.cpp test/services/encoder_test.dart
git commit -m "feat: 接通Windows实时编码通道"
```

### Task 10: Pass the H.264 real-device vertical gate

**Files:**
- Create: `docs/superpowers/reports/2026-08-04-windows-ble-camera-streaming-verification.md`

**Interfaces:**
- Consumes: Tasks 1-9 and the already working Android/target-device H.264 baseline.
- Produces: evidence that Windows camera -> MFT -> EventChannel -> Dart -> FFC4/FFC5 -> target device works before JPEG/MSV1 begins.

- [ ] **Step 1: Run the H.264 pre-device gate**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-camera-windows-preview.ps1
flutter test test/services/stream_protocol_test.dart test/services/ble_write_queue_test.dart test/services/ble_gatt_profile_test.dart test/services/stream_transport_test.dart test/pages/stream/stream_page_transport_test.dart test/services/encoder_test.dart
flutter build windows --release --no-pub
```

Expected: Debug/Release native suites, focused Flutter tests, and Release build PASS.

- [ ] **Step 2: Verify the default stream on the target device**

Launch the Release executable, connect the known device, open the camera page, keep `H.264 / 368x368 / 15fps / 150kbps`, and start projection. Record `KS_OPEN`, matching successful ACK, actual MTU, MFT friendly name, first SPS/PPS+IDR, sustained frame/stats counters, and target-device output.

- [ ] **Step 3: Exercise lifecycle failures**

Perform ten start/stop cycles; disconnect BLE once while opening and once while streaming; reconnect and start again; leave and re-enter the page. Each case must terminate without a stuck Future, stale frame, duplicate pump, camera reopen failure, or permanent permit starvation.

- [ ] **Step 4: Write actual H.264 evidence**

Create the report with sections `Environment`, `Automated Results`, `H.264 Device Gate`, `Lifecycle Cases`, and `Open Evidence`. Record only observed versions, counts, ACK bytes, paths, timestamps, and results. If the device gate fails, stop this plan at Task 10, diagnose/fix H.264, and rerun the gate; do not start Task 11.

- [ ] **Step 5: Commit the passed gate**

```powershell
git add -f docs/superpowers/reports/2026-08-04-windows-ble-camera-streaming-verification.md
git commit -m "test: 记录Windows H264投屏验收"
```

### Task 11: Add WIC JPEG and the JPEG backend

**Files:**
- Create: `windows/media/include/honey_media_windows/jpeg_codec.h`
- Create: `windows/media/src/jpeg_codec.cpp`
- Create: `windows/media/src/jpeg_encoder_backend.h`
- Create: `windows/media/src/jpeg_encoder_backend.cpp`
- Modify: `windows/media/src/encoder_backend_factory.cpp`
- Modify: `windows/media/tests/wic_media_test.cpp`
- Create: `windows/media/tests/jpeg_encoder_backend_test.cpp`
- Modify: `windows/media/CMakeLists.txt`
- Modify: `windows/media/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: the shared backend contract and WIC COM/runtime patterns.
- Produces: in-memory JPEG with quality 1..100; every encoded frame is key.

- [ ] **Step 1: Write failing WIC primitive tests**

```cpp
HMW_TEST(wic_media_jpeg_preserves_red_blue_order_with_lossy_tolerance) {
  const auto rgba = RedBlueFixture();
  const auto jpeg = hmw::EncodeJpeg(
      32, 32, rgba.data(), rgba.size(), 100);
  HMW_EXPECT(jpeg.ok());
  const auto decoded = DecodeJpegForTest(*jpeg.value);
  HMW_EXPECT(decoded.left_red > decoded.left_blue + 100);
  HMW_EXPECT(decoded.right_blue > decoded.right_red + 100);
}
```

Add invalid dimensions/buffer/quality, SOI/EOI plus decoded dimensions, and quality-output/error comparison cases.

- [ ] **Step 2: Run WIC tests and verify RED**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1 -Configuration Debug -TestRegex wic_media`

Expected: compile FAIL because `EncodeJpeg` is absent.

- [ ] **Step 3: Implement the memory-backed WIC JPEG primitive**

```cpp
Result<std::vector<uint8_t>> EncodeJpeg(
    uint32_t width, uint32_t height,
    const uint8_t* rgba, size_t rgba_size,
    uint32_t quality);
```

Use `GUID_ContainerFormatJpeg`, `IPropertyBag2` `ImageQuality=quality/100.0f`, and `GUID_WICPixelFormat24bppBGR`. Validate WIC's accepted pixel format and every UINT/size multiplication. See [Microsoft WIC encoding options](https://learn.microsoft.com/en-us/windows/win32/wic/-wic-creating-encoder).

- [ ] **Step 4: Write and run failing JPEG backend tests**

Test `Start` validation, PTS preservation, decodable output, `key=true` for every frame, no-op successful key request, empty drain, and idempotent stop.

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1 -Configuration Debug -TestRegex jpeg_encoder`

Expected: FAIL until the backend and factory case exist.

- [ ] **Step 5: Implement and register `kJpeg`**

The backend calls `EncodeJpeg` synchronously on the encoding worker and returns exactly one `EncodedFrame`. It never creates a camera thread, Flutter event, file, or BLE packet.

- [ ] **Step 6: Run JPEG Debug/Release and Flutter regression**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1 -TestRegex "^(wic_media|jpeg_encoder)$"`

Run: `flutter test test/services/encoder_test.dart test/pages/stream/stream_page_transport_test.dart`

Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
git add windows/media/include/honey_media_windows/jpeg_codec.h windows/media/src/jpeg_codec.cpp windows/media/src/jpeg_encoder_backend.h windows/media/src/jpeg_encoder_backend.cpp windows/media/src/encoder_backend_factory.cpp windows/media/tests/wic_media_test.cpp windows/media/tests/jpeg_encoder_backend_test.cpp windows/media/CMakeLists.txt windows/media/tests/CMakeLists.txt
git commit -m "feat: 接入Windows摄像头JPEG编码"
```

### Task 12: Add the `honey_media_core` MSV1 backend

**Files:**
- Create: `windows/media/src/msv1_encoder_backend.h`
- Create: `windows/media/src/msv1_encoder_backend.cpp`
- Create: `windows/media/tests/msv1_encoder_backend_test.cpp`
- Modify: `windows/media/src/encoder_backend_factory.cpp`
- Modify: `windows/media/CMakeLists.txt`
- Modify: `windows/media/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: `hmc_msv1_encode`, existing shared fixtures, and the common backend lifecycle.
- Produces: deterministic MSV1 key/inter/skip output without JNI or ABI changes.

- [ ] **Step 1: Write failing fixture-parity and state tests**

```cpp
HMW_TEST(msv1_encoder_first_and_second_frames_match_shared_fixtures) {
  auto backend = CreateMsv1EncoderBackend();
  HMW_EXPECT(backend->Start(Msv1Config(8, 8, 15, true, 0, 1)).ok());
  const auto first = backend->Encode(InputFixture("input_8x8_a.rgba"));
  const auto second = backend->Encode(InputFixture("input_8x8_a.rgba"));
  HMW_EXPECT(Bytes(first) == FixtureBytes("msv1_key.bin"));
  HMW_EXPECT(Bytes(second) == FixtureBytes("msv1_all_skip.bin"));
}
```

Add changed-frame inter fixture, skip disabled, threshold semantics, periodic key=`fps*iFrameIntervalSec`, explicit key once, request during encode retained, allocation failure preserving request/previous state, four-pixel alignment, empty drain, and idempotent stop.

- [ ] **Step 2: Run the MSV1 filter and verify RED**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1 -Configuration Debug -TestRegex msv1_encoder`

Expected: compile FAIL because the backend is absent.

- [ ] **Step 3: Implement state changes only after successful core output**

Initialize `hmc_msv1_encoder_config_t`, pass previous RGBA only when skip is enabled and no key is forced, and set `HMC_ENCODE_FLAG_FORCE_KEY` for explicit/periodic keys. Update `previous_rgba` and key counters only after `HMC_STATUS_OK`. If an explicit-key attempt fails, restore the pending request. Always release `hmc_owned_buffer_t`; take key only from `HMC_FRAME_FLAG_KEY`.

- [ ] **Step 4: Register `kMsv1` and run core/media tests**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-core-windows.ps1`

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1 -TestRegex msv1_encoder`

Expected: shared core and backend PASS in Debug/Release with the same fixture bytes.

- [ ] **Step 5: Run camera and Flutter software-codec regressions**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-camera-windows-preview.ps1 -Configuration Debug -TestRegex "^(camera_encoding_session|encoder_channel_contract)$"`

Run: `flutter test test/services/encoder_test.dart test/pages/stream/stream_page_transport_test.dart`

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add windows/media/src/msv1_encoder_backend.h windows/media/src/msv1_encoder_backend.cpp windows/media/src/encoder_backend_factory.cpp windows/media/tests/msv1_encoder_backend_test.cpp windows/media/CMakeLists.txt windows/media/tests/CMakeLists.txt
git commit -m "feat: 接入Windows摄像头MSV1编码"
```

### Task 13: Complete conditional codec checks, full regression, and stability evidence

**Files:**
- Modify: `docs/superpowers/reports/2026-08-04-windows-ble-camera-streaming-verification.md`

**Interfaces:**
- Consumes: all implementation tasks and the physical Windows/camera/device setup.
- Produces: final evidence that distinguishes automation, local Windows encoding, BLE device behavior, and conditional firmware support.

- [ ] **Step 1: Run every automated suite in both native configurations**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-core-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-media-windows-adapter.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-camera-windows-preview.ps1
flutter test --no-pub
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-android-gradle.ps1 :app:testDebugUnitTest --offline
powershell -NoProfile -ExecutionPolicy Bypass -File test/windows/flutter_blue_plus_winrt_patch_test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File test/windows/windows_plugin_registration_test.ps1
flutter build windows --release --no-pub
```

Expected: all commands PASS. If an Android connected test target is available, additionally run `scripts/run-android-gradle.ps1 :app:connectedDebugAndroidTest --offline` and record it separately.

- [ ] **Step 2: Run JPEG and MSV1 conditional device checks**

For JPEG use `368x368@15,q80`. For MSV1 use `368x368@15,skip=true,threshold=0,I=1s`. If ACK accepts the codec, verify output, color/crop/orientation, ten start/stop cycles, disconnect/reconnect, and recovery after induced backlog. If ACK rejects, record raw FFC5 bytes, SID, result, format, and config as `not applicable: current firmware unsupported`; keep local backend/protocol PASS.

- [ ] **Step 3: Run the required H.264 30-minute stability session**

Use the Release build and default H.264 settings. Record samples at start and regular intervals for working set, private bytes, sent frames/bytes/keys, effective fps/bitrate, actual MTU, and visible latency. Pass only if queues remain bounded and memory/latency do not show sustained growth.

- [ ] **Step 4: Finish the evidence report**

Record Windows version, CPU/RAM, FHD Camera model, device and firmware, Release executable path/time/size, selected MFT, actual MTU, automated test counts, device outcomes, lifecycle outcomes, and 30-minute samples. Keep absent hardware evidence explicitly unverified; do not convert it into a pass.

- [ ] **Step 5: Verify repository scope**

Run: `git diff --check`

Run: `git status --short`

Run: `git diff -- windows/flutter/generated_plugin_registrant.cc windows/flutter/generated_plugins.cmake`

Expected: no whitespace errors, no unrelated changes, and no generated registration diff.

- [ ] **Step 6: Commit final evidence**

```powershell
git add -f docs/superpowers/reports/2026-08-04-windows-ble-camera-streaming-verification.md
git commit -m "test: 完成Windows BLE摄像头投屏回归"
```

## Final Acceptance Gate

- Shared Dart protocol bytes and Android normal behavior are unchanged.
- Disconnect/reconnect/rapid restart leave no pending Future or stale pump.
- Windows encoder methods and event maps match Android.
- H.264 local tests, Release build, current-device output, ten lifecycle cycles, and 30-minute stability pass.
- JPEG/MSV1 local encoding and protocol automation pass; device result is recorded according to actual firmware support.
- No external codec/runtime, local recording, WiFi implementation, generated plugin edit, or unrelated worktree file is included.
