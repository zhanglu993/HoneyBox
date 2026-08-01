# Windows Media Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让现有 HoneyBox Windows 应用完整实现 `ebadge/converter` 与 `ebadge/player`，通过 Media Foundation/WIC 处理源媒体，并通过 `honey_media_core` 生成和解析设备使用的 Cinepak/AVI。

**Architecture:** 在 `windows/media` 建立两层目标：不依赖 Flutter 的 `honey_media_windows_core` 负责系统媒体解码、像素处理和 `hmc_` 调用；`honey_media_windows_plugin` 只负责 Flutter MethodChannel、平台线程派发和纹理生命周期。Windows Runner 注册本地插件，生成文件保持不变。

**Tech Stack:** C++17、C99 `hmc_` ABI、CMake、CTest、Media Foundation Source Reader、WIC、Flutter Windows C++ wrapper、Win32 message dispatch、PowerShell、Flutter/Dart。

## Global Constraints

- 核心库名称保持 `honey_media_core`，公开 C ABI 仅使用 `hmc_` 前缀。
- `media_core` 不得包含 Flutter、Dart、Win32 UI、Media Foundation、WIC 或 Windows 类型。
- 不新增 FFmpeg、OpenCV、media_kit、video_player_windows 等第三方原生媒体依赖。
- 保持现有 Dart `ebadge/converter` 和 `ebadge/player` 方法名、参数及返回 Map 兼容。
- 转换、解码和视频播放不得在 Flutter 平台线程执行长任务。
- 同一时刻最多一个转换任务；旧 generation 不得发送进度、结果或错误到新任务。
- 本阶段不实现 Windows 摄像头、`ebadge/encoder`、热点或 Wi-Fi 视频通道。
- 每项生产行为必须先有失败测试并观察到预期失败，再写最小实现。

---

## File structure

- `windows/media/include/honey_media_windows/`: 状态、媒体类型、transform、source、converter、controller、player 和 plugin 接口。
- `windows/media/src/`: Media Foundation、WIC、`hmc_` pipeline、Channel 与 texture 实现。
- `windows/media/tests/`: 原生单元测试、fixture 和端到端 smoke。
- `windows/CMakeLists.txt`: 引入 `media_core`、adapter targets 和 CTest。
- `windows/runner/CMakeLists.txt`: 链接 project-owned plugin。
- `windows/runner/flutter_window.cpp`: 注册 project-owned plugin。
- `scripts/test-media-windows-adapter.ps1`: Debug/Release 原生验收入口。

---

### Task 1: Establish the Windows adapter build and channel contract

**Files:**
- Create: `windows/media/CMakeLists.txt`
- Create: `windows/media/include/honey_media_windows/status.h`
- Create: `windows/media/include/honey_media_windows/channel_contract.h`
- Create: `windows/media/src/channel_contract.cpp`
- Create: `windows/media/tests/CMakeLists.txt`
- Create: `windows/media/tests/test_main.cpp`
- Create: `windows/media/tests/test_support.h`
- Create: `windows/media/tests/channel_contract_test.cpp`
- Create: `scripts/test-media-windows-adapter.ps1`
- Modify: `windows/CMakeLists.txt`

**Interfaces:**
- Produces: `hmw::Status`, `hmw::Error`, `hmw::ConverterMethodNames()`, `hmw::PlayerMethodNames()`.
- Consumes: `honey_media_core` CMake target.

- [ ] **Step 1: Write the failing channel-contract test**

```cpp
HMW_TEST(channel_contract_lists_every_existing_dart_method) {
  HMW_EXPECT(hmw::ConverterMethodNames() == std::vector<std::string_view>{
      "getVideoThumbnail", "previewFrames", "convertVideo", "encodeScroll",
      "encodeFrames", "decodeCvid", "cancelConvert"});
  HMW_EXPECT(hmw::PlayerMethodNames() == std::vector<std::string_view>{
      "create", "play", "pause", "seekTo", "position", "dispose"});
}
```

- [ ] **Step 2: Run the focused test and verify RED**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-windows-adapter.ps1 -Configuration Debug -TestRegex channel_contract
```

Expected: configure/build fails because the adapter target and contract symbols do not exist.

- [ ] **Step 3: Add the minimal status and contract implementation**

```cpp
namespace hmw {
enum class Status {
  kOk, kInvalidArgument, kNotFound, kUnsupportedMedia, kDecodeFailed,
  kEncodeFailed, kIoError, kBusy, kCancelled, kInvalidState
};
struct Error { Status status; std::string message; };
template <typename T>
struct Result {
  std::optional<T> value;
  std::optional<Error> error;
  bool ok() const { return value.has_value(); }
};
struct Outcome {
  std::optional<Error> error;
  bool ok() const { return !error.has_value(); }
};
std::vector<std::string_view> ConverterMethodNames();
std::vector<std::string_view> PlayerMethodNames();
}
```

Configure `honey_media_windows_core`, link `honey_media_core`, add the CTest target, and make the script configure `-DBUILD_TESTING=ON`, build one or both configurations, and run CTest with `--output-on-failure`.

- [ ] **Step 4: Run focused and full Debug tests**

Expected: channel contract and existing core tests pass.

- [ ] **Step 5: Commit**

```powershell
git add windows/CMakeLists.txt windows/media scripts/test-media-windows-adapter.ps1
git commit -m "build: 建立Windows媒体适配测试目标"
```

---

### Task 2: Implement deterministic RGBA transformation

**Files:**
- Create: `windows/media/include/honey_media_windows/types.h`
- Create: `windows/media/include/honey_media_windows/rgba_transform.h`
- Create: `windows/media/src/rgba_transform.cpp`
- Create: `windows/media/tests/rgba_transform_test.cpp`
- Modify: `windows/media/CMakeLists.txt`

**Interfaces:**

```cpp
struct RgbaFrame {
  uint32_t width, height;
  int64_t pts_100ns, duration_100ns;
  std::vector<uint8_t> pixels;
};
struct CropRect { double x, y, width, height; };
enum class FitMode { kCover, kContain };
struct TransformRequest {
  uint32_t output_width, output_height;
  FitMode fit;
  std::optional<CropRect> crop;
  uint32_t background_argb;
  uint32_t clockwise_rotation;
};
Result<RgbaFrame> TransformRgba(const RgbaFrame&, const TransformRequest&);
```

- [ ] **Step 1: Write failing tests**

```cpp
HMW_TEST(transform_rejects_empty_or_non_four_aligned_output);
HMW_TEST(transform_explicit_crop_overrides_cover);
HMW_TEST(transform_cover_center_crops_wide_source);
HMW_TEST(transform_contain_uses_requested_argb_background);
HMW_TEST(transform_rotates_before_crop_coordinates);
HMW_TEST(transform_bilinear_result_is_deterministic);
HMW_TEST(transform_never_changes_source_on_failure);
```

Use hand-authored 2x2 and 4x4 RGBA arrays with explicit expected bytes.

- [ ] **Step 2: Run `rgba_transform` and verify RED**

Expected: missing `TransformRgba` symbol.

- [ ] **Step 3: Implement minimal validation, rotation, crop and bilinear scaling**

Use checked `size_t` multiplication. Rotate into scratch, compute crop in upright coordinates, allocate a fresh destination, and commit only after success.

- [ ] **Step 4: Run focused and all adapter tests**

Expected: pass under `/W4 /WX /permissive-`.

- [ ] **Step 5: Commit**

```powershell
git add windows/media
git commit -m "feat: 实现Windows RGBA画面变换"
```

---

### Task 3: Add WIC PNG and GIF services

**Files:**
- Create: `windows/media/include/honey_media_windows/media_source.h`
- Create: `windows/media/include/honey_media_windows/png_codec.h`
- Create: `windows/media/src/wic_helpers.h`
- Create: `windows/media/src/wic_helpers.cpp`
- Create: `windows/media/src/png_codec.cpp`
- Create: `windows/media/src/gif_source.cpp`
- Create: `windows/media/tests/wic_media_test.cpp`
- Create: `windows/media/tests/fixtures/animated_disposal.gif`
- Modify: `windows/media/CMakeLists.txt`

**Interfaces:**

```cpp
struct SourceInfo {
  uint32_t width, height;
  int64_t duration_100ns;
  double nominal_fps;
  uint32_t clockwise_rotation;
  bool is_gif;
};
class FrameSource {
 public:
  virtual ~FrameSource() = default;
  virtual const SourceInfo& info() const = 0;
  virtual Result<bool> ReadNext(RgbaFrame* frame) = 0;
  virtual Outcome Seek(int64_t pts_100ns) = 0;
};
Result<std::vector<uint8_t>> EncodePng(const RgbaFrame&);
Result<std::unique_ptr<FrameSource>> OpenGifSource(const std::filesystem::path&);
```

- [ ] **Step 1: Add fixture and failing tests**

The checked-in 4x4 GIF has three frames, delays 50/100/150 ms, an offset transparent frame, and keep/background/previous disposal modes.

```cpp
HMW_TEST(png_round_trip_preserves_rgba_and_dimensions);
HMW_TEST(gif_reports_canvas_and_total_duration);
HMW_TEST(gif_composes_offsets_and_transparency);
HMW_TEST(gif_applies_background_and_previous_disposal);
HMW_TEST(gif_missing_delay_uses_bounded_fallback);
HMW_TEST(wic_rejects_non_gif_without_partial_frames);
```

- [ ] **Step 2: Run `wic_media` and verify RED**

Expected: missing WIC symbols.

- [ ] **Step 3: Implement COM/WIC RAII, PNG and GIF composition**

Read logical screen, image rectangle, delay, disposal and transparency through `IWICMetadataQueryReader`. Convert frames to RGBA, composite on a persistent canvas, snapshot for restore-previous, and expose composed frames through `FrameSource`.

- [ ] **Step 4: Run Debug and Release WIC tests**

Expected: identical timing, dimensions and pixels.

- [ ] **Step 5: Commit**

```powershell
git add windows/media
git commit -m "feat: 增加Windows WIC媒体处理"
```

---

### Task 4: Decode MP4 and MOV through Media Foundation

**Files:**
- Create: `windows/media/src/media_foundation_runtime.h`
- Create: `windows/media/src/media_foundation_runtime.cpp`
- Create: `windows/media/src/media_foundation_source.cpp`
- Create: `windows/media/src/media_source_factory.cpp`
- Create: `windows/media/tests/media_foundation_source_test.cpp`
- Modify: `windows/media/CMakeLists.txt`

**Interfaces:**

```cpp
Result<std::unique_ptr<FrameSource>> OpenMediaSource(
    const std::filesystem::path& path);
```

- [ ] **Step 1: Write failing tests against bundled media**

Use `assets/example/video/badge-preset-video-1.mov`.

```cpp
HMW_TEST(mf_source_reports_nonzero_upright_geometry_and_duration);
HMW_TEST(mf_source_frames_are_top_down_tightly_packed_rgba);
HMW_TEST(mf_source_pts_are_monotonic);
HMW_TEST(mf_source_seek_returns_frame_at_or_after_target);
HMW_TEST(source_factory_selects_gif_and_video_by_probe);
HMW_TEST(source_factory_reports_not_found_and_unsupported_media);
```

- [ ] **Step 2: Run `media_foundation_source` and verify RED**

Expected: missing source factory/MF reader.

- [ ] **Step 3: Implement Media Foundation source reader**

Reference-count `MFStartup(MF_VERSION)`, select the first video stream, request `MFVideoFormat_RGB32`, read default stride and rotation, normalize BGRA into top-down RGBA, and map bounded HRESULT context to adapter status.

- [ ] **Step 4: Run Debug and Release source tests**

The bundled sample is an acceptance fixture; unavailable codecs must return `unsupported_media`, not skip the test.

- [ ] **Step 5: Commit**

```powershell
git add windows/media
git commit -m "feat: 接入Windows Media Foundation解码"
```

---

### Task 5: Implement core-backed conversion and cached preview

**Files:**
- Create: `windows/media/include/honey_media_windows/media_converter.h`
- Create: `windows/media/src/media_converter.cpp`
- Create: `windows/media/src/cinepak_pipeline.cpp`
- Create: `windows/media/tests/media_converter_test.cpp`
- Modify: `windows/media/CMakeLists.txt`

**Interfaces:**

```cpp
struct ConversionRequest {
  std::filesystem::path path;
  uint32_t width, height, fps, quality, refine, strips, skip_threshold;
  uint32_t key_interval, max_frames, background_argb;
  FitMode fit;
  std::optional<CropRect> crop;
};
struct ConversionResult {
  std::vector<uint8_t> avi;
  uint32_t width, height, frame_count;
  double fps;
};
struct ThumbnailResult {
  std::vector<uint8_t> png;
  uint32_t width, height;
  bool is_gif;
};
struct PreviewResult {
  std::vector<std::vector<uint8_t>> png_frames;
  uint32_t interval_ms;
};
struct SlideshowRequest {
  std::vector<RgbaFrame> frames;
  std::vector<uint32_t> holds;
  uint32_t size, fps, quality;
};
struct ScrollRequest {
  RgbaFrame strip;
  uint32_t size, background_argb, speed, fps, gap, quality, max_frames;
};
using Progress = std::function<void(uint32_t, uint32_t)>;
using IsCancelled = std::function<bool()>;
Result<ConversionResult> ConvertMedia(const ConversionRequest&, Progress, IsCancelled);
Result<ThumbnailResult> MakeThumbnail(const std::filesystem::path&);
Result<PreviewResult> MakePreview(const std::filesystem::path&, uint32_t, uint32_t, IsCancelled);
Result<PreviewResult> DecodeCachedCvid(const std::filesystem::path&, uint32_t, uint32_t, IsCancelled);
Result<ConversionResult> EncodeSlideshow(const SlideshowRequest&, Progress, IsCancelled);
Result<ConversionResult> EncodeScroll(const ScrollRequest&, Progress, IsCancelled);
```

- [ ] **Step 1: Write failing conversion tests**

```cpp
HMW_TEST(convert_mov_produces_readable_cvid_avi);
HMW_TEST(convert_gif_uses_requested_background_and_timeline);
HMW_TEST(convert_progress_is_monotonic_and_finishes_at_total);
HMW_TEST(convert_cancel_returns_no_partial_avi);
HMW_TEST(slideshow_forces_key_frame_for_each_source_slide);
HMW_TEST(scroll_output_loops_without_visible_seam);
HMW_TEST(cached_cvid_decodes_stateful_frames_in_order);
HMW_TEST(thumbnail_and_preview_obey_max_edge_and_count);
```

Every generated AVI is reopened with `hmc_avi_reader_create_copy`; assert handler, flags, dimensions and frame count, then decode representative frames with one stateful decoder.

- [ ] **Step 2: Run `media_converter` and verify RED**

Expected: missing converter entry points.

- [ ] **Step 3: Implement the shared Cinepak/AVI pipeline**

Use local RAII wrappers for all `hmc_` handles and owned buffers. Sample by PTS, transform, encode in presentation order, pass returned flags unchanged to the muxer, and check cancellation before every expensive boundary.

- [ ] **Step 4: Run converter, core and Release tests**

Expected: deterministic output and no partial result on failure/cancel.

- [ ] **Step 5: Commit**

```powershell
git add windows/media
git commit -m "feat: 实现Windows Cinepak视频转换"
```

---

### Task 6: Add generation-safe asynchronous conversion control

**Files:**
- Create: `windows/media/include/honey_media_windows/conversion_controller.h`
- Create: `windows/media/src/conversion_controller.cpp`
- Create: `windows/media/include/honey_media_windows/platform_dispatcher.h`
- Create: `windows/media/src/platform_dispatcher.cpp`
- Create: `windows/media/tests/conversion_controller_test.cpp`
- Modify: `windows/media/CMakeLists.txt`

**Interfaces:**

```cpp
class PlatformDispatcher {
 public:
  virtual ~PlatformDispatcher() = default;
  virtual bool Post(std::function<void()> callback) = 0;
};
class ConversionController {
 public:
  using Completion = std::function<void(Result<ConversionResult>)>;
  Result<uint64_t> Start(ConversionRequest, Progress, Completion);
  void Cancel();
  void Shutdown();
};
```

- [ ] **Step 1: Write failing deterministic state tests**

```cpp
HMW_TEST(controller_rejects_second_active_job_as_busy);
HMW_TEST(controller_cancel_only_marks_current_generation);
HMW_TEST(controller_drops_old_progress_after_new_generation);
HMW_TEST(controller_drops_completion_after_shutdown);
HMW_TEST(controller_posts_one_terminal_completion);
HMW_TEST(dispatch_failure_invalidates_completion_without_leak);
```

- [ ] **Step 2: Run `conversion_controller` and verify RED**

Expected: missing controller.

- [ ] **Step 3: Implement generation and platform-thread delivery**

Use `std::thread`, atomic cancel/generation state, and joined shutdown. Implement Windows delivery with a private `WM_APP` message and `RegisterTopLevelWindowProcDelegate`; failed `PostMessage` destroys the heap-owned callback immediately.

- [ ] **Step 4: Run the focused test 100 times in Debug and once in Release**

Expected: no intermittent stale progress, duplicate completion or hang.

- [ ] **Step 5: Commit**

```powershell
git add windows/media
git commit -m "feat: 隔离Windows媒体转换任务会话"
```

---

### Task 7: Register and implement `ebadge/converter`

**Files:**
- Create: `windows/media/include/honey_media_windows/windows_media_plugin.h`
- Create: `windows/media/src/windows_media_plugin.cpp`
- Create: `windows/media/src/converter_channel.cpp`
- Create: `windows/media/src/flutter_value_reader.h`
- Create: `windows/media/src/flutter_value_reader.cpp`
- Create: `windows/media/tests/flutter_value_reader_test.cpp`
- Modify: `windows/media/CMakeLists.txt`
- Modify: `windows/runner/CMakeLists.txt`
- Modify: `windows/runner/flutter_window.cpp`

**Interfaces:**

```cpp
void HoneyMediaWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
```

- [ ] **Step 1: Write failing map contract tests**

```cpp
HMW_TEST(convert_args_apply_android_compatible_defaults);
HMW_TEST(convert_args_reject_wrong_types_and_bad_crop);
HMW_TEST(encode_frames_rejects_size_and_hold_mismatch);
HMW_TEST(success_maps_match_converter_service_fields);
HMW_TEST(status_maps_to_stable_flutter_error_code);
HMW_TEST(cancel_convert_targets_active_generation);
```

- [ ] **Step 2: Run `flutter_value_reader` and verify RED**

Expected: missing parser/mapper symbols.

- [ ] **Step 3: Implement parser, channel and local plugin registration**

Copy Dart typed-data input before returning from the handler. Complete retained `MethodResult` exactly once on the platform thread. Deliver monotonic `onProgress`. Register after generated plugins:

```cpp
HoneyMediaWindowsPluginRegisterWithRegistrar(
    flutter_controller_->engine()->GetRegistrarForPlugin(
        "HoneyMediaWindowsPlugin"));
```

- [ ] **Step 4: Run channel tests and build HoneyBox Debug**

Expected: runner links both local targets and generated files are unchanged.

- [ ] **Step 5: Commit**

```powershell
git add windows/media windows/runner windows/CMakeLists.txt
git commit -m "feat: 接入Windows视频转换通道"
```

---

### Task 8: Implement the Media Foundation Flutter texture player

**Files:**
- Create: `windows/media/include/honey_media_windows/playback_clock.h`
- Create: `windows/media/src/playback_clock.cpp`
- Create: `windows/media/src/video_texture_player.h`
- Create: `windows/media/src/video_texture_player.cpp`
- Create: `windows/media/src/player_channel.cpp`
- Create: `windows/media/tests/playback_clock_test.cpp`
- Create: `windows/media/tests/video_player_state_test.cpp`
- Modify: `windows/media/src/windows_media_plugin.cpp`
- Modify: `windows/media/CMakeLists.txt`

**Interfaces:**
- Produces internal `VideoTexturePlayer::Create/Play/Pause/Seek/Position/Dispose` and the existing `ebadge/player` response maps.
- Consumes: `FrameSource`, `PlatformDispatcher`, `flutter::TextureRegistrar`.

- [ ] **Step 1: Write failing clock and player-state tests**

```cpp
HMW_TEST(clock_play_advances_from_anchor);
HMW_TEST(clock_pause_freezes_position);
HMW_TEST(clock_seek_reanchors_playing_and_paused_states);
HMW_TEST(clock_loops_at_duration);
HMW_TEST(player_create_publishes_first_frame_before_success);
HMW_TEST(player_seek_flushes_old_generation);
HMW_TEST(player_dispose_unregisters_texture_and_drops_callbacks);
```

Use fake source and fake texture registrar; do not mock the clock under test.

- [ ] **Step 2: Run player tests and verify RED**

Expected: missing clock/player symbols.

- [ ] **Step 3: Implement pixel-buffer texture and decode scheduling**

The `PixelBufferTexture` callback returns a stable `FlutterDesktopPixelBuffer` backed by current BGRA storage. Decode outside the frame mutex, swap under the mutex, call `MarkTextureFrameAvailable`, and use source timestamps plus steady clock. Seek increments generation; dispose unregisters before releasing storage.

- [ ] **Step 4: Implement and test `ebadge/player`**

`create` returns texture ID, upright geometry and duration after first frame. Unknown IDs return `invalid_state`; repeated dispose is safe.

- [ ] **Step 5: Run all Debug/Release adapter tests and commit**

```powershell
git add windows/media
git commit -m "feat: 实现Windows原视频纹理预览"
```

---

### Task 9: End-to-end Windows acceptance and documentation

**Files:**
- Create: `windows/media/tests/windows_media_smoke.cpp`
- Create: `docs/superpowers/reports/2026-08-01-windows-media-adapter-verification.md`
- Modify: `docs/media-core.md`
- Modify: `README.md`
- Modify: `.github/workflows/flutter-ci.yml`
- Modify: `scripts/test-media-windows-adapter.ps1`

**Interfaces:**
- Consumes all prior tasks.
- Produces reproducible native adapter and Windows application acceptance.

- [ ] **Step 1: Write the failing end-to-end smoke test**

```cpp
HMW_TEST(smoke_converts_bundled_mov_and_gif_and_decodes_outputs) {
  const auto mov = ConvertMedia(MovFixtureRequest(), IgnoreProgress, NeverCancel);
  const auto gif = ConvertMedia(GifFixtureRequest(), IgnoreProgress, NeverCancel);
  HMW_EXPECT(mov.ok());
  HMW_EXPECT(gif.ok());
  HMW_EXPECT(ValidateCvidAndDecodeFirstLast(mov.value->avi).ok());
  HMW_EXPECT(ValidateCvidAndDecodeFirstLast(gif.value->avi).ok());
  HMW_EXPECT(MakeThumbnail(MovFixturePath()).ok());
  HMW_EXPECT(MakeThumbnail(GifFixturePath()).ok());
  HMW_EXPECT(MakePreview(MovFixturePath(), 12u, 160u, NeverCancel).ok());
  HMW_EXPECT(MakePreview(GifFixturePath(), 12u, 160u, NeverCancel).ok());
}
```

The test must initially fail until asset paths and every operation are integrated.

- [ ] **Step 2: Add fixed fixture helpers and make smoke GREEN**

Implement `MovFixtureRequest`, `GifFixtureRequest`, fixture-path compile
definitions, and `ValidateCvidAndDecodeFirstLast` in test support. The validator
must create an AVI reader, assert `cvid`, create one Cinepak decoder, decode
frame zero through the last frame in order, and require non-empty ARGB output.
Do not add a codec fallback.

- [ ] **Step 3: Add adapter verification to Windows CI before Release build**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-windows-adapter.ps1
flutter build windows --release
```

Keep current Windows artifact upload unchanged.

- [ ] **Step 4: Run complete verification**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-core-windows.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-windows-adapter.ps1
flutter test --no-pub
flutter build windows --release --no-pub
```

Expected: core and adapter Debug/Release tests pass, Flutter tests pass, and `build/windows/x64/runner/Release/HoneyBox.exe` exists.

- [ ] **Step 5: Perform application smoke**

1. MOV thumbnail appears and play/pause/seek/stop update preview.
2. GIF thumbnail keeps alpha and animation follows delays.
3. MOV and GIF conversion progress is monotonic; a restarted task can be cancelled.
4. Cached AVI preview shows motion from first to last frame.
5. Slideshow and scrolling-danmaku complete without `MissingPluginException`.
6. Existing BLE send action is reached; without a connected eBadge, device receipt remains explicitly pending.

- [ ] **Step 6: Document evidence and limitations**

Record toolchain, commands, test counts, executable path/hash, fixture results and hardware status. Update Windows capability claims only after smoke passes.

- [ ] **Step 7: Review and commit**

```powershell
git diff --check master...HEAD
git status --short
git add .github/workflows/flutter-ci.yml README.md docs scripts windows/media
git commit -m "test: 完成Windows媒体转换验收"
```

---

## Plan self-review record

- Tasks 7 and 8 own every approved `ebadge/converter` and `ebadge/player` method.
- Source decoding, GIF semantics, transform, core codec/container use, concurrency, Flutter mapping, texture playback, CI and smoke each have a test-first task.
- Camera, hotspot, Wi-Fi video and `ebadge/encoder` are absent as required.
- Cross-platform core names remain `hmc_`; `ebadge/*` exists only at the compatibility adapter boundary.
- Every interface used by a later task is introduced by an earlier task or by that task's interface block.
