# HoneyBox Windows Camera Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing HoneyBox stream page open the default Windows camera and render a live embedded preview through the same `ebadge/encoder` contract used by Android.

**Architecture:** Add a Flutter-free `windows/camera` core around Media Foundation capture, then bridge its latest BGRA frame through the existing project-owned Windows plugin, platform dispatcher, and pixel-buffer texture abstraction. Dart keeps one `EncoderService`; Windows implements only preview lifecycle in this slice and reports deterministic camera/error events.

**Tech Stack:** Flutter/Dart, C++17, Windows Media Foundation, Flutter Windows MethodChannel/EventChannel, PixelBufferTexture, CMake/CTest, PowerShell, MSVC x64.

## Global Constraints

- Target Windows 10/11 x64; do not add FFmpeg, OpenCV, `camera`, `camera_windows`, codec packs, or separately installed runtimes.
- Preserve Android `ebadge/encoder` and `ebadge/encoder/events` behavior and wire fields.
- Keep camera session state, generation, worker, and buffers independent from converter/player state.
- Do not hand-edit `windows/flutter/generated_plugin_registrant.cc` or `windows/flutter/generated_plugins.cmake`.
- This slice implements default-camera preview, open/close lifecycle, and terminal errors only; still-image capture, encoding, transport, camera controls, and device selection are outside this plan.
- Use test-first Red-Green-Refactor for every production behavior and commit only files belonging to the current task.
- Build success does not replace live `FHD Camera` verification, and a visible picture does not replace automated lifecycle tests.

## Planned File Structure

- `windows/camera/include/honey_camera_windows/camera_preview.h`: platform-neutral camera preview source/session contracts.
- `windows/camera/include/honey_camera_windows/encoder_channel.h`: Flutter encoder channel/controller contract.
- `windows/camera/src/camera_preview_session.cpp`: generation-safe preview worker and terminal-state logic.
- `windows/camera/src/media_foundation_camera_internal.h`: capture-mode selection and locked-buffer normalization helpers.
- `windows/camera/src/media_foundation_camera.cpp`: Media Foundation enumeration, activation, Source Reader, and BGRA frame reads.
- `windows/camera/src/camera_texture_controller.cpp`: latest-frame ownership, texture registration, platform-thread publication, and ready/error callbacks.
- `windows/camera/src/encoder_channel.cpp`: `openCamera`/`closeCamera` parsing and Android-compatible event maps.
- `windows/camera/tests/*`: camera-core, Media Foundation helper, texture lifecycle, and channel contract tests.
- `windows/camera/CMakeLists.txt`: standalone camera targets and integration into the existing Windows plugin.
- `scripts/test-camera-windows-preview.ps1`: repeatable Debug/Release camera test entry point.
- `windows/media/src/windows_media_plugin.cpp`: register `ebadge/encoder` and `ebadge/encoder/events` in the existing project-owned plugin.
- `lib/services/encoder.dart`: injectable channels and normalized open errors for tests.
- `lib/pages/stream/stream_page.dart`: convert startup failures into an error/retry terminal state.
- `test/services/encoder_test.dart`: Dart camera/error event contract regression.
- `test/pages/stream/stream_page_camera_test.dart`: loading-to-error and retry widget regression.
- `docs/superpowers/reports/2026-08-03-windows-camera-preview-verification.md`: exact automated/build/hardware evidence.

---

### Task 1: Establish the camera target and stable error contract

**Files:**
- Create: `windows/camera/CMakeLists.txt`
- Create: `windows/camera/tests/CMakeLists.txt`
- Create: `windows/camera/tests/camera_status_test.cpp`
- Create: `scripts/test-camera-windows-preview.ps1`
- Modify: `windows/CMakeLists.txt`
- Modify: `windows/media/include/honey_media_windows/status.h`
- Modify: `windows/media/src/flutter_value_reader.cpp`
- Create: `windows/media/src/status.cpp`
- Modify: `windows/media/CMakeLists.txt`

**Interfaces:**
- Consumes: `hmw::Status`, `hmw::Error`, and existing Flutter error completion.
- Produces: `kPermissionDenied`, `kDeviceUnavailable`, `kDeviceLost`, shared `StatusCode(Status)`, and standalone `honey_camera_windows_tests` target.

- [ ] **Step 1: Write the failing status-contract test**

```cpp
HMW_TEST(camera_status_codes_are_stable) {
  HMW_EXPECT(hmw::StatusCode(hmw::Status::kPermissionDenied) ==
             "permission_denied");
  HMW_EXPECT(hmw::StatusCode(hmw::Status::kDeviceUnavailable) ==
             "device_unavailable");
  HMW_EXPECT(hmw::StatusCode(hmw::Status::kDeviceLost) == "device_lost");
}
```

- [ ] **Step 2: Add the CMake/test-script scaffold and run RED**

`windows/camera/CMakeLists.txt` must reuse `honey_media_windows_core` when the app already defined it and otherwise add `../media` into a private build directory. The PowerShell script configures `windows/camera` with VS 2022 x64, builds Debug/Release, and runs CTest with `--output-on-failure --no-tests=error`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -Configuration Debug -TestRegex camera_status
```

Expected: compile failure because the three camera statuses are not defined.

- [ ] **Step 3: Add the minimal status values and mappings**

Insert the values before `kIoError`, declare `std::string_view StatusCode(Status)` in `status.h`, implement all existing and new status strings in `status.cpp`, and make `FlutterErrorCode` delegate to `StatusCode`. Map the new values exactly:

```cpp
case Status::kPermissionDenied:
  return "permission_denied";
case Status::kDeviceUnavailable:
  return "device_unavailable";
case Status::kDeviceLost:
  return "device_lost";
```

Add `add_subdirectory("camera")` after `add_subdirectory("media")` in `windows/CMakeLists.txt`; leave generated files unchanged.

- [ ] **Step 4: Run GREEN in Debug and Release**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -TestRegex camera_status
```

Expected: the status test passes in both configurations.

- [ ] **Step 5: Commit**

```powershell
git add windows/CMakeLists.txt windows/camera windows/media/include/honey_media_windows/status.h windows/media/src/status.cpp windows/media/src/flutter_value_reader.cpp windows/media/CMakeLists.txt scripts/test-camera-windows-preview.ps1
git commit -m "build: 建立Windows摄像头预览目标"
```

---

### Task 2: Build the generation-safe preview session

**Files:**
- Create: `windows/camera/include/honey_camera_windows/camera_preview.h`
- Create: `windows/camera/src/camera_preview_session.cpp`
- Create: `windows/camera/tests/camera_preview_session_test.cpp`
- Modify: `windows/camera/CMakeLists.txt`
- Modify: `windows/camera/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: `hmw::Result<T>`, `hmw::Outcome`, `hmw::Error`.
- Produces: `CameraPreviewConfig`, `CameraFrame`, `CameraFrameSource`, `CameraSourceFactory`, `CameraPreviewCallbacks`, and `CameraPreviewSession`.

- [ ] **Step 1: Write tests against this exact public API**

```cpp
namespace hcw {
struct CameraPreviewConfig { uint32_t width; uint32_t height; uint32_t fps; };
struct CameraFrame {
  uint32_t width;
  uint32_t height;
  int64_t pts_100ns;
  std::shared_ptr<const std::vector<uint8_t>> bgra;
};
class CameraFrameSource {
 public:
  virtual ~CameraFrameSource() = default;
  virtual hmw::Result<CameraFrame> ReadNext() = 0;
  virtual void RequestStop() noexcept = 0;
};
using CameraSourceFactory = std::function<
    hmw::Result<std::unique_ptr<CameraFrameSource>>(
        const CameraPreviewConfig&)>;
struct CameraPreviewCallbacks {
  std::function<void(uint64_t, CameraFrame)> on_frame;
  std::function<void(uint64_t, hmw::Error)> on_error;
};
class CameraPreviewSession final {
 public:
  CameraPreviewSession(CameraSourceFactory, CameraPreviewCallbacks);
  ~CameraPreviewSession();
  hmw::Outcome Open(CameraPreviewConfig);
  hmw::Outcome Close();
  uint64_t generation() const;
};
}  // namespace hcw
```

Use a blocking fake source for four tests: active-generation frames publish; close is idempotent and joins; a new open suppresses the old generation; factory failure reports exactly once.

- [ ] **Step 2: Run RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -Configuration Debug -TestRegex camera_preview_
```

Expected: build failure because the preview session is not implemented.

- [ ] **Step 3: Implement the minimal worker/state machine**

`Open` first calls `Close`, rejects zero width/height/fps, increments generation under the state mutex, and starts exactly one worker. The worker creates the source, reads until stop, and checks generation before every callback. `Close` invalidates generation, calls `RequestStop` outside the mutex, joins outside the mutex, and clears state. Catch worker exceptions and emit one `kIoError` instead of letting them terminate the process.

- [ ] **Step 4: Run GREEN and the existing media regression**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -Configuration Debug -TestRegex camera_preview_
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-media-windows-adapter.ps1 -Configuration Debug
```

Expected: focused camera and all Debug media tests pass.

- [ ] **Step 5: Commit**

```powershell
git add windows/camera
git commit -m "feat: 增加Windows摄像头预览会话"
```

---

### Task 3: Implement Media Foundation capture and frame normalization

**Files:**
- Create: `windows/camera/src/media_foundation_camera_internal.h`
- Create: `windows/camera/src/media_foundation_camera.cpp`
- Create: `windows/camera/tests/media_foundation_camera_test.cpp`
- Modify: `windows/camera/include/honey_camera_windows/camera_preview.h`
- Modify: `windows/camera/CMakeLists.txt`
- Modify: `windows/camera/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: `CameraFrameSource`, `CameraPreviewConfig`, and `hmw::TransformRgba`.
- Produces: `CameraSourceFactory CreateMediaFoundationCameraFactory()` plus pure `SelectCaptureMode`, `CopyBgraRows`, `BgraToRgba`, and `RgbaToBgra` helpers.

- [ ] **Step 1: Write failing helper tests**

Add tests for smallest covering mode, largest fallback, positive padded stride, negative stride, short-buffer rejection, and exact red/blue channel swaps in both directions. For `368x368@15`, candidates `640x480@30`, `1280x720@15`, and `320x240@30` must choose `640x480@30`.

- [ ] **Step 2: Run RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -Configuration Debug -TestRegex "camera_mode_|camera_bgra_|camera_rgba_"
```

Expected: compile failure because selection and row-copy helpers are absent.

- [ ] **Step 3: Implement helpers and the real camera source**

Use this Media Foundation sequence:

```cpp
MFCreateAttributes(&attributes, 2);
attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
MFEnumDeviceSources(attributes.Get(), &activates, &count);
activates[0]->ActivateObject(IID_PPV_ARGS(&media_source));
MFCreateAttributes(&reader_attributes, 1);
reader_attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
MFCreateSourceReaderFromMediaSource(media_source.Get(),
                                    reader_attributes.Get(), &reader);
```

Enumerate native video types, choose a mode, set it, then request `MFVideoFormat_RGB32`. `ReadNext` uses `IMF2DBuffer::Lock2D` when available and executes this exact pixel path: `CopyBgraRows` normalizes pitch into top-down BGRA, `BgraToRgba` creates `hmw::RgbaFrame`, `hmw::TransformRgba` applies `FitMode::kCover`, and `RgbaToBgra` creates the immutable Texture snapshot at requested dimensions. Unlock and release all COM resources through RAII.

Map zero devices to `kNotFound`, `E_ACCESSDENIED` to `kPermissionDenied`, open/type negotiation failures to `kDeviceUnavailable`, capture invalidation to `kDeviceLost`, and other HRESULT failures to `kIoError` with bounded hexadecimal details.

- [ ] **Step 4: Run native GREEN**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -TestRegex "camera_mode_|camera_bgra_|camera_rgba_"
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-media-windows-adapter.ps1
```

Expected: camera helper and full media suites pass in Debug and Release.

- [ ] **Step 5: Commit**

```powershell
git add windows/camera
git commit -m "feat: 接入Windows Media Foundation摄像头"
```

---

### Task 4: Publish frames through Texture and the encoder channel

**Files:**
- Create: `windows/camera/include/honey_camera_windows/encoder_channel.h`
- Create: `windows/camera/src/camera_texture_controller.cpp`
- Create: `windows/camera/src/encoder_channel.cpp`
- Create: `windows/camera/tests/camera_texture_controller_test.cpp`
- Create: `windows/camera/tests/encoder_channel_contract_test.cpp`
- Modify: `windows/camera/CMakeLists.txt`
- Modify: `windows/camera/tests/CMakeLists.txt`
- Modify: `windows/media/include/honey_media_windows/windows_media_plugin.h`

**Interfaces:**
- Consumes: preview session/factory, `hmw::TextureRegistry`, `hmw::PlatformDispatcher`, and `hmw::FlutterResult`.
- Produces: `CameraTextureController`, `EncoderChannel`, and `EncoderEventSender`.

- [ ] **Step 1: Write failing Texture lifecycle tests against this API**

```cpp
struct CameraReady { int64_t texture_id; uint32_t width; uint32_t height; };
struct CameraControllerCallbacks {
  std::function<void(CameraReady)> on_ready;
  std::function<void(hmw::Error)> on_error;
};
class CameraTextureController final {
 public:
  CameraTextureController(hmw::TextureRegistry&, hmw::PlatformDispatcher&,
                          CameraSourceFactory);
  ~CameraTextureController();
  hmw::Outcome Open(CameraPreviewConfig, CameraControllerCallbacks);
  hmw::Outcome Close();
};
```

Prove one texture per open, first-frame-only ready, subsequent frame marking, snapshot ownership during Flutter reads, close/unregister ordering, and queued callback suppression after close.

- [ ] **Step 2: Run Texture RED, implement, and run GREEN**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -Configuration Debug -TestRegex camera_texture_
```

Use a `shared_ptr<const vector<uint8_t>>` latest-frame snapshot behind a short mutex. Conversion happens before the lock. Texture registration, marking, ready/error callbacks, and unregistration run on `PlatformDispatcher` and recheck generation.

- [ ] **Step 3: Write failing channel tests against this API**

```cpp
using EncoderEventSender =
    std::function<void(flutter::EncodableValue event)>;
class EncoderChannel final {
 public:
  EncoderChannel(CameraTextureController&, EncoderEventSender);
  void Handle(std::string_view method,
              const flutter::EncodableValue* arguments,
              std::unique_ptr<hmw::FlutterResult> result);
  void Shutdown();
};
```

Assert positive width/height/fps validation, asynchronous open acceptance, idempotent close, `NotImplemented` for other methods, a single terminal error map, and this exact ready payload:

```cpp
EncodableMap{
  {"event", "camera"}, {"textureId", texture_id},
  {"previewWidth", width}, {"previewHeight", height},
  {"sensorOrientation", 0}, {"facingFront", false},
  {"evMin", 0.0}, {"evMax", 0.0}, {"evStep", 0.0},
  {"focusSupported", false},
};
```

- [ ] **Step 4: Implement channel and run GREEN**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -TestRegex "camera_texture_|encoder_channel_"
```

Expected: focused contract tests pass in Debug and Release.

- [ ] **Step 5: Commit**

```powershell
git add windows/camera windows/media/include/honey_media_windows/windows_media_plugin.h
git commit -m "feat: 打通Windows摄像头纹理与通道"
```

---

### Task 5: Register encoder channels in the Windows plugin

**Files:**
- Modify: `windows/media/src/windows_media_plugin.cpp`
- Modify: `windows/media/CMakeLists.txt`
- Modify: `windows/camera/CMakeLists.txt`
- Create: `windows/camera/tests/windows_encoder_registration_test.cpp`
- Modify: `windows/camera/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: `EncoderChannel`, `CreateMediaFoundationCameraFactory()`, texture registry, and dispatcher.
- Produces: live `ebadge/encoder` and `ebadge/encoder/events` Windows registrations.

- [ ] **Step 1: Write and run the failing native registration test**

The test reads `windows_media_plugin.cpp` and requires exact channel names, an EventChannel stream handler, encoder shutdown before texture/dispatcher teardown, and unchanged generated files.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -Configuration Debug -TestRegex windows_encoder_registration
```

Expected: FAIL because neither encoder channel is registered.

- [ ] **Step 2: Register both channels in the existing plugin**

Add method/event channel members, an event sink, `CameraTextureController`, and `EncoderChannel`. Use `flutter::StreamHandlerFunctions<EncodableValue>` so listen installs the sink and cancel clears it. Post events through the existing dispatcher and send only while plugin/sink generation is active. In the destructor detach both handlers, call `encoder_channel_.Shutdown()`, then run existing player/converter shutdown.

- [ ] **Step 3: Run native GREEN and compile the Flutter plugin**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -TestRegex windows_encoder_registration
flutter build windows --debug --no-pub
```

Expected: registration tests pass in Debug and Release and the Windows Debug runner links the camera plugin.

- [ ] **Step 4: Commit**

```powershell
git add windows/media windows/camera
git commit -m "feat: 注册Windows摄像头平台通道"
```

---

### Task 6: Give Flutter camera startup a deterministic error/retry state

**Files:**
- Modify: `lib/services/encoder.dart`
- Modify: `lib/pages/stream/stream_page.dart`
- Create: `test/services/encoder_test.dart`
- Create: `test/pages/stream/stream_page_camera_test.dart`

**Interfaces:**
- Consumes: unchanged `CameraInfo` event map and encoder channel names.
- Produces: injectable service channels, injectable permission request, and loading-to-error/retry behavior.

- [ ] **Step 1: Write the failing Dart service test**

Make channel injection the wished-for constructor:

```dart
EncoderService({
  MethodChannel method = const MethodChannel('ebadge/encoder'),
  EventChannel events = const EventChannel('ebadge/encoder/events'),
})  : _method = method,
      _events = events;
```

Mock the binary messenger; assert `openCamera` sends `368x368@15` and a `camera` event yields texture `41` and dimensions `368x368`.

- [ ] **Step 2: Run Dart RED, implement injection, and run GREEN**

```powershell
flutter test --no-pub test/services/encoder_test.dart
```

Expected RED: constructor lacks injected channels. Expected GREEN: service contract passes.

- [ ] **Step 3: Write and run failing StreamPage tests**

Add optional `EncoderService encoder` and `Future<PermissionStatus> Function() requestCameraPermission` constructor dependencies. Inject a method channel whose first open throws `PlatformException(code: 'device_unavailable', message: '摄像头被占用')` and second open succeeds. Assert loading disappears, the message and “重试” appear, and tapping retry invokes open exactly twice.

```powershell
flutter test --no-pub test/pages/stream/stream_page_camera_test.dart
```

Expected: FAIL because startup exceptions leave the loading branch active.

- [ ] **Step 4: Implement the minimal error/retry branch**

Wrap `_bootstrapCamera` in `try/on PlatformException/catch`, clear `_error` before each attempt, store the platform message on failure, and render error/retry before loading in `_buildPreview`. Retry calls `_bootstrapCamera`. Do not change shutter, encoding, settings, or transport.

- [ ] **Step 5: Run Flutter and Windows Debug GREEN**

```powershell
flutter test --no-pub
flutter build windows --debug --no-pub
```

Expected: all tests pass and the Debug runner builds.

- [ ] **Step 6: Commit**

```powershell
git add lib/services/encoder.dart lib/pages/stream/stream_page.dart test/services/encoder_test.dart test/pages/stream/stream_page_camera_test.dart
git commit -m "fix: 修复Windows摄像头启动卡死"
```

---

### Task 7: Complete Release regression and live FHD Camera verification

**Files:**
- Create: `docs/superpowers/reports/2026-08-03-windows-camera-preview-verification.md`
- Modify only when evidence exposes a failure: the Task 1–6 owner file, preceded by a focused failing test.

**Interfaces:**
- Consumes: complete native camera target, plugin registration, and Dart terminal state.
- Produces: reproducible automated/build/runtime evidence and the Release artifact.

- [ ] **Step 1: Run all automated regressions**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-media-core-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-media-windows-adapter.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1
flutter test --no-pub
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\windows_plugin_registration_test.ps1
flutter build windows --release --no-pub
```

Expected: all Debug/Release CTest, Flutter, PowerShell, and Release build steps pass.

- [ ] **Step 2: Verify the actual `FHD Camera`**

Inspect exact running `HoneyBox.exe` paths before rebuilding. Ask the user to close a process locking the Release artifact; do not force-terminate without approval. Launch the new Release application and record first-frame time, requested/output dimensions and fps, orientation, continuous motion, return/back release, successful second entry, occupied-device error, and retry after releasing the competing app.

- [ ] **Step 3: Record bounded stability evidence**

Keep preview open for 10 minutes and sample working set at 0, 5, and 10 minutes. Confirm no unbounded monotonic growth. The complete camera milestone retains its separate 30-minute camera/encoding gate.

- [ ] **Step 4: Write the verification report**

Record exact commands, pass/fail counts, Release executable path/time/size, Windows version, camera model, runtime observations, memory samples, unimplemented functions, and environmental limitations. Do not describe build-only evidence as camera success.

- [ ] **Step 5: Review and commit evidence**

```powershell
git status --short
git diff --check
git log --oneline --decorate -8
git add -f docs/superpowers/reports/2026-08-03-windows-camera-preview-verification.md
git commit -m "test: 记录Windows摄像头预览验收"
```

Expected: the worktree is clean and each implementation commit contains only its task-owned files.
