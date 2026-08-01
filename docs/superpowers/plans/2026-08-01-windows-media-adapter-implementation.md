# Windows Media Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让现有 HoneyBox Windows 应用完整实现 `ebadge/converter` 与 `ebadge/player`，通过 Media Foundation/WIC 处理源媒体，并通过 `honey_media_core` 生成和解析设备使用的 Cinepak/AVI。

**Architecture:** 在 `windows/media` 建立两层目标：不依赖 Flutter 的 `honey_media_windows_core` 负责系统媒体解码、像素处理和 `hmc_` 调用；`honey_media_windows_plugin` 只负责 Flutter MethodChannel、平台线程派发和纹理生命周期。Windows Runner 注册本地插件，生成文件保持不变。

**Tech Stack:** C++17、C99 `hmc_` ABI、CMake、CTest、Media Foundation Source Reader、WIC、Flutter Windows C++ wrapper、Win32 message dispatch、PowerShell、Flutter/Dart。

## Global Constraints

- 核心库名称保持 `honey_media_core`，公开 C ABI 仅使用 `hmc_` 前缀。
- `media_core` 不得包含 Flutter、Dart、Win32 UI、Media Foundation、WIC 或 Windows 类型。
- 本里程碑只支持 Windows 10/11 x64。
- 不新增 FFmpeg、OpenCV、media_kit、video_player_windows 等第三方原生媒体依赖。
- Release 产物不得要求用户安装 FFmpeg、外部 codec pack 或独立媒体运行时。
- 保持现有 Dart `ebadge/converter` 和 `ebadge/player` 方法名、参数及返回 Map 兼容。
- 转换、解码和视频播放不得在 Flutter 平台线程执行长任务。
- 同一时刻最多一个转换任务；旧 generation 不得发送进度、结果或错误到新任务。
- 本阶段不实现 Windows 摄像头、`ebadge/encoder`、热点或 Wi-Fi 视频通道。
- 相同 RGBA 帧序列和参数进入 `honey_media_core` 后，Cinepak/AVI 必须与 Android
  使用同一核心的结果逐字节一致；MP4/MOV/GIF 端到端按像素容差、帧数、时长、
  方向、裁剪及目标设备播放效果验收。
- 参考机以 360x360、10 fps 和页面默认质量参数执行离线转换时至少达到实时速度；
  取消必须在 1 秒内到达终态。
- 自动化测试、Windows 应用运行和目标设备接收是三类独立证据，不得用其中一种替代
  另一种。
- 里程碑 1 未满足全部验收门时，不得开始 Windows 摄像头生产实现。
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
- `windows/media/tests/windows_media_benchmark.cpp`: 手动参考机实时转换和取消性能门。
- `docs/superpowers/reports/2026-08-01-windows-media-adapter-verification.md`: 自动化、
  Windows 运行、性能和目标设备的分栏证据。

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

`test_support.h` also defines the shared callbacks used by later tasks:

```cpp
inline void IgnoreProgress(uint32_t, uint32_t) {}
inline bool NeverCancel() { return false; }
```

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
struct ThumbnailRequest { std::filesystem::path path; };
struct PreviewRequest {
  std::filesystem::path path;
  uint32_t max_count, max_edge;
};
struct DecodeCvidRequest {
  std::filesystem::path path;
  uint32_t max_count, max_edge;
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
using MediaJobRequest = std::variant<
    ThumbnailRequest, PreviewRequest, DecodeCvidRequest, ConversionRequest,
    SlideshowRequest, ScrollRequest>;
using MediaJobResult = std::variant<
    ThumbnailResult, PreviewResult, ConversionResult>;
Result<ConversionResult> ConvertMedia(const ConversionRequest&, Progress, IsCancelled);
Result<ThumbnailResult> MakeThumbnail(const ThumbnailRequest&, IsCancelled);
Result<PreviewResult> MakePreview(const PreviewRequest&, IsCancelled);
Result<PreviewResult> DecodeCachedCvid(const DecodeCvidRequest&, IsCancelled);
Result<ConversionResult> EncodeSlideshow(const SlideshowRequest&, Progress, IsCancelled);
Result<ConversionResult> EncodeScroll(const ScrollRequest&, Progress, IsCancelled);
Result<MediaJobResult> ExecuteMediaJob(
    const MediaJobRequest&, Progress, IsCancelled);
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
HMW_TEST(job_dispatch_covers_every_converter_channel_operation);
```

Every generated AVI is reopened with `hmc_avi_reader_create_copy`; assert handler, flags, dimensions and frame count, then decode representative frames with one stateful decoder.

- [ ] **Step 2: Run `media_converter` and verify RED**

Expected: missing converter entry points.

- [ ] **Step 3: Implement the shared Cinepak/AVI pipeline**

Use local RAII wrappers for all `hmc_` handles and owned buffers. Sample by PTS, transform, encode in presentation order, pass returned flags unchanged to the muxer, and check cancellation before every expensive boundary.

Dispatch every channel operation through one typed visitor so the async controller
in Task 6 cannot accidentally run thumbnail, preview or cached decode on the
Flutter platform thread:

```cpp
template <class... Visitors>
struct Overloaded : Visitors... { using Visitors::operator()...; };
template <class... Visitors>
Overloaded(Visitors...) -> Overloaded<Visitors...>;

template <typename T>
Result<MediaJobResult> Promote(Result<T> concrete) {
  if (!concrete.ok()) {
    return {std::nullopt, std::move(concrete.error)};
  }
  return {MediaJobResult{std::move(*concrete.value)}, std::nullopt};
}

Result<MediaJobResult> ExecuteMediaJob(
    const MediaJobRequest& request, Progress progress,
    IsCancelled cancelled) {
  return std::visit(
      Overloaded{
          [&](const ThumbnailRequest& r) -> Result<MediaJobResult> {
            return Promote(MakeThumbnail(r, cancelled));
          },
          [&](const PreviewRequest& r) -> Result<MediaJobResult> {
            return Promote(MakePreview(r, cancelled));
          },
          [&](const DecodeCvidRequest& r) -> Result<MediaJobResult> {
            return Promote(DecodeCachedCvid(r, cancelled));
          },
          [&](const ConversionRequest& r) -> Result<MediaJobResult> {
            return Promote(ConvertMedia(r, progress, cancelled));
          },
          [&](const SlideshowRequest& r) -> Result<MediaJobResult> {
            return Promote(EncodeSlideshow(r, progress, cancelled));
          },
          [&](const ScrollRequest& r) -> Result<MediaJobResult> {
            return Promote(EncodeScroll(r, progress, cancelled));
          }},
      request);
}
```

`Promote` moves a successful concrete result into `MediaJobResult` and copies
the existing `Error` unchanged on failure.

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
  using Completion = std::function<void(Result<MediaJobResult>)>;
  explicit ConversionController(PlatformDispatcher& dispatcher);
  ~ConversionController();
  Result<uint64_t> Start(MediaJobRequest, Progress, Completion);
  void Cancel();
  void Shutdown();

 private:
  void PostProgressIfCurrent(uint64_t, uint32_t, uint32_t);
  void PostCompletionIfCurrent(uint64_t, Result<MediaJobResult>);
  PlatformDispatcher& dispatcher_;
  std::thread worker_;
  std::atomic<uint64_t> generation_{0};
  std::atomic<bool> cancelled_{false};
  std::atomic<bool> shutting_down_{false};
  std::mutex state_mutex_;
  bool active_{false};
};
```

`Start` has an exact ownership contract: on success it returns a generation and
will attempt exactly one terminal completion unless shutdown invalidates it; on
synchronous failure it returns `busy`/`invalid_state`, starts no worker, and
never calls progress or completion. Under `state_mutex_`, `Start` rejects an
active job and joins a previously completed `worker_` before launching the next
generation; it never joins an active worker on the Flutter platform thread.

- [ ] **Step 1: Write failing deterministic state tests**

```cpp
HMW_TEST(controller_rejects_second_active_job_as_busy);
HMW_TEST(controller_cancel_only_marks_current_generation);
HMW_TEST(controller_drops_old_progress_after_new_generation);
HMW_TEST(controller_drops_completion_after_shutdown);
HMW_TEST(controller_posts_one_terminal_completion);
HMW_TEST(dispatch_failure_invalidates_completion_without_leak);
HMW_TEST(controller_runs_thumbnail_preview_decode_convert_frames_and_scroll_jobs);
```

- [ ] **Step 2: Run `conversion_controller` and verify RED**

Expected: missing controller.

- [ ] **Step 3: Implement generation and platform-thread delivery**

Use `std::thread`, atomic cancel/generation state, and joined shutdown. Implement Windows delivery with a private `WM_APP` message and `RegisterTopLevelWindowProcDelegate`; failed `PostMessage` destroys the heap-owned callback immediately.

The worker captures one request by value and uses the Task 5 dispatcher. It
must recheck the same generation before posting progress and before posting the
single terminal result:

```cpp
worker_ = std::thread([this, generation, request = std::move(request)]() mutable {
  auto cancelled = [this, generation] {
    return shutting_down_.load() || cancelled_.load() ||
           generation_.load() != generation;
  };
  auto result = ExecuteMediaJob(
      request,
      [this, generation](uint32_t done, uint32_t total) {
        PostProgressIfCurrent(generation, done, total);
      },
      cancelled);
  PostCompletionIfCurrent(generation, std::move(result));
});
```

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
using FlutterResult = flutter::MethodResult<flutter::EncodableValue>;
void HoneyMediaWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
Result<MediaJobRequest> ParseConverterRequest(
    std::string_view method, const flutter::EncodableValue* arguments);
void CompleteFlutterError(
    const std::shared_ptr<FlutterResult>& result, const Error& error);
void CompleteConverterResult(
    const std::shared_ptr<FlutterResult>& result,
    Result<MediaJobResult> completed);
void SendProgress(uint32_t done, uint32_t total);
```

- [ ] **Step 1: Write failing map contract tests**

```cpp
HMW_TEST(convert_args_apply_android_compatible_defaults);
HMW_TEST(convert_args_reject_wrong_types_and_bad_crop);
HMW_TEST(encode_frames_rejects_size_and_hold_mismatch);
HMW_TEST(success_maps_match_converter_service_fields);
HMW_TEST(status_maps_to_stable_flutter_error_code);
HMW_TEST(cancel_convert_targets_active_generation);
HMW_TEST(every_non_cancel_converter_method_runs_through_controller);
HMW_TEST(channel_drops_completion_after_plugin_shutdown);
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

Parse each method into the Task 5 request variant, then use the Task 6
controller for all six non-cancel operations. The MethodChannel handler must
return immediately after retaining the result:

```cpp
auto parsed = ParseConverterRequest(call.method_name(), call.arguments());
if (!parsed.ok()) return CompleteFlutterError(result, *parsed.error);
auto retained = std::shared_ptr<FlutterResult>(std::move(result));
auto started = controller_.Start(
    std::move(*parsed.value),
    [this](uint32_t done, uint32_t total) { SendProgress(done, total); },
    [this, retained](Result<MediaJobResult> completed) mutable {
      CompleteConverterResult(retained, std::move(completed));
    });
if (!started.ok()) CompleteFlutterError(retained, *started.error);
```

`cancelConvert` is the only synchronous control method; it calls
`controller_.Cancel()` and completes success immediately.

- [ ] **Step 4: Run channel tests and build HoneyBox Debug**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-windows-adapter.ps1 -Configuration Debug -TestRegex "flutter_value_reader|channel_contract"
flutter build windows --debug --no-pub
git diff --exit-code -- windows/flutter/generated_plugin_registrant.cc windows/flutter/generated_plugins.cmake
```

Expected: runner links both local targets, tests pass, and generated files are unchanged.

- [ ] **Step 5: Commit**

```powershell
git add windows/media windows/runner windows/CMakeLists.txt
git commit -m "feat: 接入Windows视频转换通道"
```

---

### Task 8: Implement the Media Foundation Flutter texture player

**Files:**
- Create: `windows/media/include/honey_media_windows/playback_clock.h`
- Create: `windows/media/include/honey_media_windows/texture_registry.h`
- Create: `windows/media/src/playback_clock.cpp`
- Create: `windows/media/src/flutter_texture_registry.cpp`
- Create: `windows/media/src/video_texture_player.h`
- Create: `windows/media/src/video_texture_player.cpp`
- Create: `windows/media/src/player_channel.cpp`
- Create: `windows/media/tests/playback_clock_test.cpp`
- Create: `windows/media/tests/video_player_state_test.cpp`
- Modify: `windows/media/src/windows_media_plugin.cpp`
- Modify: `windows/media/CMakeLists.txt`

**Interfaces:**
- Consumes: `FrameSource` and `PlatformDispatcher`.

```cpp
struct PixelBufferView {
  const uint8_t* bgra;
  size_t byte_count;
  uint32_t width;
  uint32_t height;
};
using PixelBufferProvider = std::function<PixelBufferView()>;
class TextureRegistry {
 public:
  virtual ~TextureRegistry() = default;
  virtual int64_t RegisterPixelBufferTexture(PixelBufferProvider) = 0;
  virtual bool MarkFrameAvailable(int64_t texture_id) = 0;
  virtual bool UnregisterTexture(int64_t texture_id) = 0;
};
class VideoTexturePlayer {
 public:
  static Result<std::unique_ptr<VideoTexturePlayer>> Create(
      std::unique_ptr<FrameSource>, TextureRegistry&, PlatformDispatcher&);
  Outcome Play();
  Outcome Pause();
  Outcome Seek(int64_t position_ms);
  Result<int64_t> Position() const;
  Outcome Dispose();
};
```

`flutter_texture_registry.cpp` is the only class in this task that directly
wraps `flutter::TextureRegistrar`; tests provide a fake `TextureRegistry`.

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

### Task 9: Add automated, CI and reference-machine acceptance

**Files:**
- Create: `windows/media/tests/windows_media_smoke.cpp`
- Create: `windows/media/tests/benchmark_support.h`
- Create: `windows/media/tests/benchmark_support.cpp`
- Create: `windows/media/tests/benchmark_support_test.cpp`
- Create: `windows/media/tests/windows_media_benchmark.cpp`
- Modify: `windows/media/CMakeLists.txt`
- Modify: `windows/media/tests/CMakeLists.txt`
- Modify: `scripts/test-media-windows-adapter.ps1`
- Modify: `.github/workflows/flutter-ci.yml`

**Interfaces:**
- Consumes: all Task 1-8 adapter, player, controller and test-support interfaces.
- Produces: `hmw::test::RunTenSecondEquivalentBenchmark`,
  `hmw_windows_media_benchmark.exe`, and PowerShell `-Performance` /
  `-EvidencePath` switches.

```cpp
struct BenchmarkEvidence {
  std::string cpu;
  uint64_t memory_bytes;
  std::string windows_version;
  double source_seconds;
  double elapsed_seconds;
  uint64_t cancel_milliseconds;
  bool realtime_pass;
  bool cancel_pass;
};
Result<BenchmarkEvidence> RunTenSecondEquivalentBenchmark(
    const std::filesystem::path& mov_fixture);
ConversionRequest DefaultBenchmarkRequest(
    const std::filesystem::path& mov_fixture);
BenchmarkEvidence EvaluateBenchmarkEvidence(
    BenchmarkEvidence evidence);
std::string BenchmarkEvidenceJson(const BenchmarkEvidence& evidence);
Result<uint64_t> MeasureRealCancellationMilliseconds(
    const std::filesystem::path& mov_fixture);
```

- [ ] **Step 1: Write the failing end-to-end smoke test**

```cpp
HMW_TEST(smoke_converts_bundled_mov_and_gif_and_decodes_outputs) {
  const auto mov = ConvertMedia(MovFixtureRequest(), IgnoreProgress, NeverCancel);
  const auto gif = ConvertMedia(GifFixtureRequest(), IgnoreProgress, NeverCancel);
  HMW_EXPECT(mov.ok());
  HMW_EXPECT(gif.ok());
  HMW_EXPECT(ValidateCvidAndDecodeFirstLast(mov.value->avi).ok());
  HMW_EXPECT(ValidateCvidAndDecodeFirstLast(gif.value->avi).ok());
  HMW_EXPECT(MakeThumbnail({MovFixturePath()}, NeverCancel).ok());
  HMW_EXPECT(MakeThumbnail({GifFixturePath()}, NeverCancel).ok());
  HMW_EXPECT(MakePreview({MovFixturePath(), 12u, 160u}, NeverCancel).ok());
  HMW_EXPECT(MakePreview({GifFixturePath(), 12u, 160u}, NeverCancel).ok());
}
```

- [ ] **Step 2: Run the smoke test and verify RED**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-windows-adapter.ps1 -Configuration Debug -TestRegex windows_media_smoke
```

Expected: FAIL because fixture compile definitions and the smoke target are not integrated.

- [ ] **Step 3: Add fixed fixture helpers and make smoke GREEN**

Implement `MovFixtureRequest`, `GifFixtureRequest`, fixture-path compile
definitions, and `ValidateCvidAndDecodeFirstLast` in `test_support.h`. The
validator must use one stateful decoder from frame zero through the last frame:

```cpp
Outcome ValidateCvidAndDecodeFirstLast(const std::vector<uint8_t>& avi) {
  hmc_avi_reader_t* raw_reader = nullptr;
  if (hmc_avi_reader_create_copy(avi.data(), avi.size(), &raw_reader) !=
      HMC_STATUS_OK) {
    return {Error{Status::kDecodeFailed, "AVI reader creation failed"}};
  }
  std::unique_ptr<hmc_avi_reader_t, decltype(&hmc_avi_reader_destroy)> reader(
      raw_reader, &hmc_avi_reader_destroy);
  hmc_avi_info_t info{};
  info.struct_size = HMC_AVI_INFO_V1_SIZE;
  if (hmc_avi_reader_get_info(reader.get(), &info) != HMC_STATUS_OK ||
      info.handler_fourcc != HMC_MEDIA_FOURCC('c', 'v', 'i', 'd')) {
    return {Error{Status::kDecodeFailed, "expected CVID AVI"}};
  }
  hmc_cinepak_decoder_config_t config{};
  if (hmc_cinepak_decoder_config_init(
          &config, HMC_CINEPAK_DECODER_CONFIG_V1_SIZE) != HMC_STATUS_OK) {
    return {Error{Status::kDecodeFailed, "decoder config failed"}};
  }
  config.width = info.width;
  config.height = info.height;
  hmc_cinepak_decoder_t* raw_decoder = nullptr;
  if (hmc_cinepak_decoder_create(&config, &raw_decoder) != HMC_STATUS_OK) {
    return {Error{Status::kDecodeFailed, "decoder creation failed"}};
  }
  std::unique_ptr<hmc_cinepak_decoder_t,
                  decltype(&hmc_cinepak_decoder_destroy)> decoder(
      raw_decoder, &hmc_cinepak_decoder_destroy);
  std::vector<uint32_t> argb(
      static_cast<size_t>(info.width) * info.height);
  bool first_nonempty = false;
  bool last_nonempty = false;
  for (uint32_t i = 0; i < info.frame_count; ++i) {
    hmc_bytes_view_t frame{};
    if (hmc_avi_reader_get_frame_view(reader.get(), i, &frame) != HMC_STATUS_OK ||
        hmc_cinepak_decoder_decode(decoder.get(), frame.data, frame.size,
                                   argb.data(), argb.size()) != HMC_STATUS_OK) {
      return {Error{Status::kDecodeFailed, "sequential decode failed"}};
    }
    if (i == 0) first_nonempty = !argb.empty();
    if (i + 1 == info.frame_count) last_nonempty = !argb.empty();
  }
  return first_nonempty && last_nonempty
      ? Outcome{std::nullopt}
      : Outcome{Error{Status::kDecodeFailed, "empty decoded smoke frame"}};
}
```

Do not add a system-codec fallback for CVID.

- [ ] **Step 4: Run the smoke test and verify GREEN**

Run the command from Step 2. Expected: PASS for MOV and GIF thumbnail, preview,
conversion, AVI reopen and first/last decode.

- [ ] **Step 5: Write failing benchmark-support tests**

```cpp
HMW_TEST(benchmark_accumulates_at_least_ten_source_seconds);
HMW_TEST(benchmark_uses_360_square_ten_fps_default_quality);
HMW_TEST(benchmark_realtime_pass_compares_elapsed_to_source_duration);
HMW_TEST(benchmark_cancel_pass_requires_at_most_one_thousand_ms);
HMW_TEST(benchmark_json_contains_machine_source_elapsed_and_cancel_fields);
```

Unit-test `DefaultBenchmarkRequest`, `EvaluateBenchmarkEvidence` and JSON
serialization with fixed values. The production benchmark must use the real
bundled MOV, real converter and real controller.

- [ ] **Step 6: Run benchmark-support tests and verify RED**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-windows-adapter.ps1 -Configuration Debug -TestRegex benchmark_support
```

Expected: FAIL because benchmark support and JSON serialization do not exist.

- [ ] **Step 7: Implement the reference-machine benchmark**

Open the bundled MOV to read its duration, then convert it repeatedly with
the exact Dart defaults `width=360`, `height=360`, `fps=10`, `quality=60`,
`refine=3`, `strips=2`, `skipThresh=720`, `keyint=0`, `cropMode=cover`,
`maxFrames=300`, `bgColor=0xFF000000` until accumulated source duration is at
least ten seconds. Measure the complete calls, not only core encoding.
Start one additional real conversion, wait for its first progress callback,
call `Cancel`, and measure until the single cancelled completion:

```cpp
evidence.source_seconds = 0.0;
auto opened = OpenMediaSource(mov_fixture);
if (!opened.ok()) return {std::nullopt, std::move(opened.error)};
const double one_source_seconds =
    static_cast<double>((*opened.value)->info().duration_100ns) / 10000000.0;
if (one_source_seconds <= 0.0) {
  return {std::nullopt,
          Error{Status::kUnsupportedMedia, "benchmark duration is zero"}};
}
const auto started = std::chrono::steady_clock::now();
do {
  auto converted = ConvertMedia(DefaultBenchmarkRequest(mov_fixture),
                                IgnoreProgress, NeverCancel);
  if (!converted.ok()) {
    return {std::nullopt, std::move(converted.error)};
  }
  evidence.source_seconds += one_source_seconds;
} while (evidence.source_seconds < 10.0);
evidence.elapsed_seconds = std::chrono::duration<double>(
    std::chrono::steady_clock::now() - started).count();
auto cancel_ms = MeasureRealCancellationMilliseconds(mov_fixture);
if (!cancel_ms.ok()) return {std::nullopt, std::move(cancel_ms.error)};
evidence.cancel_milliseconds = *cancel_ms.value;
return {EvaluateBenchmarkEvidence(std::move(evidence)), std::nullopt};
```

`hmw_windows_media_benchmark.exe --json <path>` writes the evidence atomically
and exits non-zero if either gate fails. It also records CPU, physical memory
and Windows version.

- [ ] **Step 8: Add the PowerShell performance entry and run it**

`test-media-windows-adapter.ps1 -Performance -EvidencePath <path>` must build
Release first, invoke the benchmark executable, and propagate its exit code:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-windows-adapter.ps1 `
  -Configuration Release -Performance `
  -EvidencePath .\output\windows-media-performance.json
```

Expected on the designated reference machine: JSON exists,
`realtime_pass=true`, `cancel_pass=true`, and the process exits 0. A slower
machine is a real gate failure, not an allowed test skip.

- [ ] **Step 9: Add adapter verification to Windows CI before Release build**

Insert this step before the existing Windows Release build; do not put the
hardware-dependent performance benchmark in GitHub-hosted CI:

```yaml
- name: Test Windows media adapter
  shell: pwsh
  run: .\scripts\test-media-windows-adapter.ps1

- name: Build Windows (release)
  run: flutter build windows --release
```

Keep the current artifact upload unchanged.

- [ ] **Step 10: Run complete automated verification**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-core-windows.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-windows-adapter.ps1
flutter test --no-pub
powershell -ExecutionPolicy Bypass -File .\scripts\run-android-gradle.ps1 :app:testDebugUnitTest
flutter build windows --release --no-pub
```

Expected: core and adapter Debug/Release tests pass, Flutter tests pass,
Android JVM unit tests pass, and
`build/windows/x64/runner/Release/HoneyBox.exe` exists. Record exact test counts
for Task 10; do not convert a missing toolchain into a pass.

- [ ] **Step 11: Review and commit the automated acceptance**

```powershell
git diff --check
git status --short
git add .github/workflows/flutter-ci.yml scripts/test-media-windows-adapter.ps1 windows/media
git commit -m "test: 增加Windows媒体自动化验收"
```

---

### Task 10: Complete Windows runtime and target-device acceptance

**Files:**
- Create: `docs/superpowers/reports/2026-08-01-windows-media-adapter-verification.md`
- Modify: `docs/media-core.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 9 commands and `output/windows-media-performance.json`.
- Produces: a four-section verification report with `PASS`, `FAIL`, or
  `PENDING_HARDWARE` for automated, Windows runtime, performance and target
  device evidence, plus one overall status.

- [ ] **Step 1: Create the evidence report skeleton with current command output**

Use these exact headings and tables; populate actual values rather than example
text:

```markdown
# Windows Media Adapter Verification

## Automated Evidence
| Command | Result | Test count | Evidence |

## Windows Runtime Evidence
| Flow | Result | Fixture | Evidence |

## Performance Evidence
| Machine | Source seconds | Elapsed seconds | Cancel ms | Result |

## Target Device Evidence
| Device | Payload | Transfer | Playback | Result |

## Overall Status
PASS | FAIL | PENDING_HARDWARE
```

- [ ] **Step 2: Perform the Windows application runtime smoke**

On the built Release application, record each result separately:

1. MOV thumbnail appears; play, pause, seek and loop update the source preview.
2. GIF thumbnail retains alpha and preview follows GIF frame delays.
3. MOV and GIF conversion progress is monotonic.
4. Cancel an active conversion, wait for `cancelled`, then start and complete a
   new conversion without stale progress.
5. Cached AVI preview moves from first to last frame.
6. Slideshow and scrolling-video generation complete without
   `MissingPluginException`.
7. Repeat open/convert/cancel/dispose twenty times and confirm the process does
   not show sustained memory growth after returning idle.

Any failed item makes `Windows Runtime Evidence` fail.

- [ ] **Step 3: Import and verify performance evidence**

Copy CPU, physical memory, Windows version, source seconds, elapsed seconds and
cancel milliseconds from `output/windows-media-performance.json`. Recompute the
two booleans in the report; do not trust a manually edited result field:

```text
realtime_pass = elapsed_seconds <= source_seconds
cancel_pass = cancel_milliseconds <= 1000
```

- [ ] **Step 4: Perform required target-device acceptance**

Connect an eBadge supported by the existing BLE file-transfer path and send:

1. one AVI converted from bundled MOV;
2. one AVI converted from bundled GIF;
3. one AVI generated by slideshow.

For each payload record file SHA-256, byte length, BLE transfer completion,
device playback start, motion through the last frame, duration, orientation and
color result. All three must pass. Reaching the send button is not device
evidence.

If no device is available, set `PENDING_HARDWARE` and stop: Task 10 and
milestone 1 are not complete, even if build and host tests pass.

- [ ] **Step 5: Update capability documentation from verified evidence only**

In `README.md` and `docs/media-core.md`, mark Windows converter/player support
only for flows whose runtime and device rows pass. Include the one-line native
verification command and the Windows 10/11 x64, no-external-codec boundary.

- [ ] **Step 6: Validate the final report and diff**

```powershell
rg -n "PENDING_HARDWARE|FAIL" .\docs\superpowers\reports\2026-08-01-windows-media-adapter-verification.md
git diff --check
git status --short
```

Expected for milestone completion: `rg` finds no pending/fail status, the diff
check is clean, and only Task 10 documentation files are unstaged.

- [ ] **Step 7: Commit verified documentation**

```powershell
git add README.md docs/media-core.md docs/superpowers/reports/2026-08-01-windows-media-adapter-verification.md
git commit -m "docs: 记录Windows媒体设备验收"
```

---

## Plan self-review record

- Tasks 7 and 8 own every approved `ebadge/converter` and `ebadge/player` method.
- Source decoding, GIF semantics, transform, core codec/container use, concurrency, Flutter mapping, texture playback, CI and smoke each have a test-first task.
- Task 5 defines a request/result variant for all six non-cancel converter
  operations; Task 6 schedules that complete variant, so thumbnail, preview and
  cached decode cannot fall back to the Flutter platform thread.
- Task 9 owns automated, Android-regression, Windows Release, reference-machine
  real-time and one-second cancellation evidence.
- Task 10 separately owns Windows UI runtime and mandatory target-device
  evidence; `PENDING_HARDWARE` cannot satisfy the milestone gate.
- Camera, hotspot, Wi-Fi video, notification forwarding, Windows packaging,
  application update and `ebadge/encoder` are absent from this milestone as
  required by the approved program spec.
- Cross-platform core names remain `hmc_`; `ebadge/*` exists only at the compatibility adapter boundary.
- Every interface used by a later task is introduced by an earlier task or by that task's interface block.
- Milestone 2 camera planning and implementation cannot start until every Task
  10 row and the overall report status are `PASS`.
