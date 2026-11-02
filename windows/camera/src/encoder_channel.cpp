#include "honey_camera_windows/encoder_channel.h"

#include "honey_media_windows/status.h"

#include <cmath>
#include <limits>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace hcw {
namespace {

// Android's encoder wire defaults, mirrored so a Windows run of the same Dart
// `EncoderConfig` produces the same encoder configuration.
constexpr int64_t kDefaultPreviewWidth = 640;
constexpr int64_t kDefaultPreviewHeight = 480;
constexpr int64_t kDefaultFps = 15;
constexpr int64_t kDefaultBitrate = 2000000;
constexpr int64_t kDefaultIFrameIntervalSec = 1;
constexpr int64_t kDefaultMsv1SkipThreshold = 0;
constexpr int64_t kDefaultJpegQuality = 80;

constexpr int64_t kMaxEncodedEdge = 8192;
constexpr int64_t kMaxFps = 240;
constexpr int64_t kMaxBitrate = 100000000;
constexpr int64_t kMaxIFrameIntervalSec = 3600;
constexpr int64_t kMaxMsv1SkipThreshold = 65535;
constexpr double kMaxCropZoom = 100.0;
constexpr size_t kMaxErrorDetails = 128;

const flutter::EncodableMap* ArgumentsMap(
    const flutter::EncodableValue* arguments) {
  return arguments == nullptr
             ? nullptr
             : std::get_if<flutter::EncodableMap>(arguments);
}

const flutter::EncodableValue* FindArgument(
    const flutter::EncodableMap* arguments, const char* key) {
  if (arguments == nullptr) {
    return nullptr;
  }
  const auto found = arguments->find(flutter::EncodableValue(key));
  return found == arguments->end() ? nullptr : &found->second;
}

std::optional<int64_t> IntegerArgument(
    const flutter::EncodableMap* arguments, const char* key,
    int64_t fallback) {
  const flutter::EncodableValue* value = FindArgument(arguments, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* integer = std::get_if<int64_t>(value)) {
    return *integer;
  }
  if (const auto* integer = std::get_if<int32_t>(value)) {
    return static_cast<int64_t>(*integer);
  }
  return std::nullopt;
}

std::optional<bool> BooleanArgument(const flutter::EncodableMap* arguments,
                                    const char* key, bool fallback) {
  const flutter::EncodableValue* value = FindArgument(arguments, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* flag = std::get_if<bool>(value)) {
    return *flag;
  }
  return std::nullopt;
}

std::optional<double> DoubleArgument(const flutter::EncodableMap* arguments,
                                     const char* key, double fallback) {
  const flutter::EncodableValue* value = FindArgument(arguments, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* number = std::get_if<double>(value)) {
    return *number;
  }
  if (const auto* integer = std::get_if<int64_t>(value)) {
    return static_cast<double>(*integer);
  }
  if (const auto* integer = std::get_if<int32_t>(value)) {
    return static_cast<double>(*integer);
  }
  return std::nullopt;
}

std::optional<std::string> StringArgument(
    const flutter::EncodableMap* arguments, const char* key,
    const char* fallback) {
  const flutter::EncodableValue* value = FindArgument(arguments, key);
  if (value == nullptr) {
    return std::string(fallback);
  }
  if (const auto* text = std::get_if<std::string>(value)) {
    return *text;
  }
  return std::nullopt;
}

bool FacingArgumentIsValid(const flutter::EncodableMap* arguments) {
  const flutter::EncodableValue* value =
      FindArgument(arguments, "facingFront");
  return value == nullptr || std::get_if<bool>(value) != nullptr;
}

hmw::Error InvalidArgument(std::string message) {
  return {hmw::Status::kInvalidArgument, std::move(message)};
}

hmw::Error InvalidState(std::string message) {
  return {hmw::Status::kInvalidState, std::move(message)};
}

std::optional<hmw::EncoderFormat> ParseFormat(std::string_view wire) {
  if (wire == "h264") {
    return hmw::EncoderFormat::kH264;
  }
  if (wire == "jpeg") {
    return hmw::EncoderFormat::kJpeg;
  }
  // The Dart enum spells MSV1 as `mvs1`; that spelling is the wire contract.
  if (wire == "mvs1") {
    return hmw::EncoderFormat::kMsv1;
  }
  return std::nullopt;
}

// MSV1 needs 4-aligned dimensions and JPEG/H.264 need even ones. Android
// silently clamps MSV1 up to the 4-pixel floor; a requested size that cannot
// reach the even floor is a caller error.
bool NormalizeDimensions(hmw::EncoderFormat format, int64_t width,
                         int64_t height, uint32_t* out_width,
                         uint32_t* out_height) {
  if (format == hmw::EncoderFormat::kMsv1) {
    const int64_t aligned_width = width & ~int64_t{3};
    const int64_t aligned_height = height & ~int64_t{3};
    *out_width = static_cast<uint32_t>(aligned_width < 4 ? 4 : aligned_width);
    *out_height =
        static_cast<uint32_t>(aligned_height < 4 ? 4 : aligned_height);
    return true;
  }
  const int64_t aligned_width = width & ~int64_t{1};
  const int64_t aligned_height = height & ~int64_t{1};
  if (aligned_width < 2 || aligned_height < 2) {
    return false;
  }
  *out_width = static_cast<uint32_t>(aligned_width);
  *out_height = static_cast<uint32_t>(aligned_height);
  return true;
}

hmw::Result<hmw::EncodingConfig> ParseEncodingConfig(
    const flutter::EncodableMap* arguments) {
  const std::optional<std::string> format_wire =
      StringArgument(arguments, "format", "h264");
  if (!format_wire) {
    return {std::nullopt, InvalidArgument("format must be a string")};
  }
  const std::optional<hmw::EncoderFormat> format = ParseFormat(*format_wire);
  if (!format) {
    return {std::nullopt,
            InvalidArgument("unsupported encoder format: " + *format_wire)};
  }

  const std::optional<int64_t> width =
      IntegerArgument(arguments, "width", kDefaultPreviewWidth);
  const std::optional<int64_t> height =
      IntegerArgument(arguments, "height", kDefaultPreviewHeight);
  const std::optional<int64_t> fps =
      IntegerArgument(arguments, "fps", kDefaultFps);
  const std::optional<int64_t> bitrate =
      IntegerArgument(arguments, "bitrate", kDefaultBitrate);
  const std::optional<int64_t> i_frame_interval_sec =
      IntegerArgument(arguments, "iFrameIntervalSec",
                      kDefaultIFrameIntervalSec);
  const std::optional<int64_t> msv1_skip_threshold =
      IntegerArgument(arguments, "msv1SkipThr", kDefaultMsv1SkipThreshold);
  const std::optional<int64_t> jpeg_quality =
      IntegerArgument(arguments, "jpegQuality", kDefaultJpegQuality);
  const std::optional<double> crop_zoom =
      DoubleArgument(arguments, "cropZoom", 1.0);
  const std::optional<bool> msv1_skip =
      BooleanArgument(arguments, "msv1Skip", true);
  const std::optional<bool> record_to_file =
      BooleanArgument(arguments, "recordToFile", false);
  const std::optional<bool> stream = BooleanArgument(arguments, "stream", false);

  if (!width || !height || !fps || !bitrate || !i_frame_interval_sec ||
      !msv1_skip_threshold || !jpeg_quality || !crop_zoom || !msv1_skip ||
      !record_to_file || !stream) {
    return {std::nullopt,
            InvalidArgument("encoder arguments have unexpected value types")};
  }
  if (*width <= 0 || *width > kMaxEncodedEdge || *height <= 0 ||
      *height > kMaxEncodedEdge) {
    return {std::nullopt,
            InvalidArgument("encoder width and height are out of range")};
  }
  if (*fps <= 0 || *fps > kMaxFps) {
    return {std::nullopt, InvalidArgument("encoder fps is out of range")};
  }
  if (*bitrate <= 0 || *bitrate > kMaxBitrate) {
    return {std::nullopt, InvalidArgument("encoder bitrate is out of range")};
  }
  if (*i_frame_interval_sec < 0 ||
      *i_frame_interval_sec > kMaxIFrameIntervalSec) {
    return {std::nullopt,
            InvalidArgument("encoder key-frame interval is out of range")};
  }
  if (*msv1_skip_threshold < 0 ||
      *msv1_skip_threshold > kMaxMsv1SkipThreshold) {
    return {std::nullopt,
            InvalidArgument("MSV1 skip threshold is out of range")};
  }
  if (*jpeg_quality < 1 || *jpeg_quality > 100) {
    return {std::nullopt, InvalidArgument("JPEG quality is out of range")};
  }
  if (!std::isfinite(*crop_zoom) || *crop_zoom > kMaxCropZoom) {
    return {std::nullopt, InvalidArgument("crop zoom is out of range")};
  }
  if (*record_to_file) {
    return {std::nullopt,
            hmw::Error{hmw::Status::kUnsupportedFeature,
                       "Windows encoding does not record to a local file"}};
  }

  hmw::EncodingConfig config{};
  if (!NormalizeDimensions(*format, *width, *height, &config.width,
                           &config.height)) {
    return {std::nullopt,
            InvalidArgument("encoder width and height are too small")};
  }
  config.format = *format;
  config.fps = static_cast<uint32_t>(*fps);
  config.bitrate = static_cast<uint32_t>(*bitrate);
  config.i_frame_interval_sec = static_cast<uint32_t>(*i_frame_interval_sec);
  config.crop_zoom = *crop_zoom < 1.0 ? 1.0 : *crop_zoom;
  config.msv1_skip = *msv1_skip;
  config.msv1_skip_threshold = static_cast<uint32_t>(*msv1_skip_threshold);
  config.jpeg_quality = static_cast<uint32_t>(*jpeg_quality);
  config.record_to_file = false;
  config.stream = *stream;
  return {config, std::nullopt};
}

void CompleteError(const std::unique_ptr<hmw::FlutterResult>& result,
                   const hmw::Error& error) {
  result->Error(std::string(hmw::StatusCode(error.status)), error.message);
}

flutter::EncodableValue OptionalPath(const std::optional<std::string>& path) {
  return path.has_value() ? flutter::EncodableValue(*path)
                          : flutter::EncodableValue();
}

flutter::EncodableValue Count(uint64_t value) {
  return flutter::EncodableValue(static_cast<int64_t>(value));
}

flutter::EncodableValue ReadyEvent(CameraReady ready) {
  using flutter::EncodableMap;
  using flutter::EncodableValue;
  return EncodableValue(EncodableMap{
      {EncodableValue("event"), EncodableValue("camera")},
      {EncodableValue("textureId"), EncodableValue(ready.texture_id)},
      {EncodableValue("previewWidth"),
       EncodableValue(static_cast<int64_t>(ready.width))},
      {EncodableValue("previewHeight"),
       EncodableValue(static_cast<int64_t>(ready.height))},
      {EncodableValue("sensorOrientation"), EncodableValue(int32_t{0})},
      {EncodableValue("facingFront"), EncodableValue(false)},
      {EncodableValue("evMin"), EncodableValue(0.0)},
      {EncodableValue("evMax"), EncodableValue(0.0)},
      {EncodableValue("evStep"), EncodableValue(0.0)},
      {EncodableValue("focusSupported"), EncodableValue(false)},
  });
}

// Android emits only `message`; Windows adds a stable status `code` and a
// bounded `details` origin so a failure can be attributed without parsing it.
flutter::EncodableValue ErrorEvent(const hmw::Error& error,
                                   std::string_view origin) {
  using flutter::EncodableMap;
  using flutter::EncodableValue;
  return EncodableValue(EncodableMap{
      {EncodableValue("event"), EncodableValue("error")},
      {EncodableValue("message"), EncodableValue(error.message)},
      {EncodableValue("code"),
       EncodableValue(std::string(hmw::StatusCode(error.status)))},
      {EncodableValue("details"),
       EncodableValue(std::string(origin.substr(
           0, origin.size() < kMaxErrorDetails ? origin.size()
                                               : kMaxErrorDetails)))},
  });
}

flutter::EncodableValue StartedEvent(const std::optional<std::string>& path,
                                     uint32_t width, uint32_t height) {
  using flutter::EncodableMap;
  using flutter::EncodableValue;
  return EncodableValue(EncodableMap{
      {EncodableValue("event"), EncodableValue("started")},
      {EncodableValue("path"), OptionalPath(path)},
      {EncodableValue("width"), EncodableValue(static_cast<int64_t>(width))},
      {EncodableValue("height"), EncodableValue(static_cast<int64_t>(height))},
  });
}

flutter::EncodableValue FrameEvent(const hmw::EncodedFrame& frame) {
  using flutter::EncodableMap;
  using flutter::EncodableValue;
  std::vector<uint8_t> bytes;
  if (frame.bytes) {
    bytes = *frame.bytes;
  }
  return EncodableValue(EncodableMap{
      {EncodableValue("event"), EncodableValue("frame")},
      {EncodableValue("data"), EncodableValue(std::move(bytes))},
      {EncodableValue("key"), EncodableValue(frame.key)},
  });
}

flutter::EncodableValue StatsEvent(const hmw::EncodingStats& stats) {
  using flutter::EncodableMap;
  using flutter::EncodableValue;
  return EncodableValue(EncodableMap{
      {EncodableValue("event"), EncodableValue("stats")},
      {EncodableValue("frames"), Count(stats.frames)},
      {EncodableValue("keyframes"), Count(stats.keyframes)},
      {EncodableValue("bytes"), Count(stats.bytes)},
      {EncodableValue("keyBytes"), Count(stats.key_bytes)},
      {EncodableValue("fps"), EncodableValue(stats.fps)},
      {EncodableValue("lastBytes"), Count(stats.last_bytes)},
  });
}

flutter::EncodableValue StoppedEvent(const std::optional<std::string>& path,
                                     const hmw::EncodingStats& stats) {
  using flutter::EncodableMap;
  using flutter::EncodableValue;
  return EncodableValue(EncodableMap{
      {EncodableValue("event"), EncodableValue("stopped")},
      {EncodableValue("path"), OptionalPath(path)},
      {EncodableValue("frames"), Count(stats.frames)},
      {EncodableValue("keyframes"), Count(stats.keyframes)},
      {EncodableValue("bytes"), Count(stats.bytes)},
  });
}

flutter::EncodableValue InfoEvent(const std::string& message) {
  using flutter::EncodableMap;
  using flutter::EncodableValue;
  return EncodableValue(EncodableMap{
      {EncodableValue("event"), EncodableValue("info")},
      {EncodableValue("message"), EncodableValue(message)},
  });
}

}  // namespace

struct EncoderChannel::State {
  explicit State(EncoderEventSender sender)
      : event_sender(std::move(sender)) {}

  std::mutex mutex;
  bool alive = true;
  bool terminal = false;
  bool camera_open = false;
  uint64_t generation = 0;
  // A run blocks a second start until it stops or reports a terminal error.
  bool encoding_active = false;
  // A session run still has to be retired through `Stop`.
  bool run_pending = false;
  uint64_t encoding_epoch = 0;
  EncoderEventSender event_sender;
};

// Delivers a camera-session event only while that exact camera generation is
// still the live one.
void EncoderChannel::SendCameraEvent(
    const std::weak_ptr<EncoderChannel::State>& weak_state,
    uint64_t generation, bool terminal,
    flutter::EncodableValue event) noexcept {
  const std::shared_ptr<EncoderChannel::State> state = weak_state.lock();
  if (!state) {
    return;
  }
  EncoderEventSender sender;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->alive || state->terminal || state->generation != generation) {
      return;
    }
    if (terminal) {
      state->terminal = true;
      state->camera_open = false;
    }
    sender = state->event_sender;
  }
  if (sender) {
    try {
      sender(std::move(event));
    } catch (...) {
    }
  }
}

// Delivers an encoder-run event only while that exact run is still the live
// one, so a retired worker cannot reach the new generation's Dart listener.
void EncoderChannel::SendEncoderEvent(
    const std::weak_ptr<EncoderChannel::State>& weak_state, uint64_t epoch,
    flutter::EncodableValue event) noexcept {
  const std::shared_ptr<EncoderChannel::State> state = weak_state.lock();
  if (!state) {
    return;
  }
  EncoderEventSender sender;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->alive || state->encoding_epoch != epoch) {
      return;
    }
    sender = state->event_sender;
  }
  if (sender) {
    try {
      sender(std::move(event));
    } catch (...) {
    }
  }
}

// A terminal encoder error ends the run; the page may start a new one without
// waiting for `stopEncoding`, but the retired run still owes a `stopped`.
void EncoderChannel::RetireEncodingRun(
    const std::weak_ptr<EncoderChannel::State>& weak_state,
    uint64_t epoch) noexcept {
  const std::shared_ptr<EncoderChannel::State> state = weak_state.lock();
  if (!state) {
    return;
  }
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->encoding_epoch == epoch) {
    state->encoding_active = false;
  }
}

EncoderChannel::EncoderChannel(CameraTextureController& controller,
                               EncodingSession& session,
                               EncoderEventSender event_sender)
    : controller_(controller),
      session_(session),
      state_(std::make_shared<State>(std::move(event_sender))) {}

EncoderChannel::~EncoderChannel() { Shutdown(); }

void EncoderChannel::Handle(
    std::string_view method, const flutter::EncodableValue* arguments,
    std::unique_ptr<hmw::FlutterResult> result) {
  if (!result) {
    return;
  }
  if (method == "openCamera") {
    HandleOpenCamera(arguments, std::move(result));
    return;
  }
  if (method == "closeCamera") {
    HandleCloseCamera(std::move(result));
    return;
  }
  if (method == "startEncoding") {
    HandleStartEncoding(arguments, std::move(result));
    return;
  }
  if (method == "stopEncoding") {
    HandleStopEncoding(std::move(result));
    return;
  }
  if (method == "requestKeyframe" || method == "requestEncoderFrame") {
    HandleEncoderRequest(method, std::move(result));
    return;
  }
  result->NotImplemented();
}

void EncoderChannel::HandleOpenCamera(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<hmw::FlutterResult> result) {
  const flutter::EncodableMap* map = ArgumentsMap(arguments);
  if (arguments != nullptr && map == nullptr) {
    result->Error("invalid_argument", "camera arguments must be a map");
    return;
  }
  const std::optional<int64_t> width =
      IntegerArgument(map, "width", kDefaultPreviewWidth);
  const std::optional<int64_t> height =
      IntegerArgument(map, "height", kDefaultPreviewHeight);
  const std::optional<int64_t> fps = IntegerArgument(map, "fps", kDefaultFps);
  constexpr int64_t kMaxUint32 =
      static_cast<int64_t>((std::numeric_limits<uint32_t>::max)());
  if (!width || !height || !fps || *width <= 0 || *height <= 0 ||
      *fps <= 0 || *width > kMaxUint32 || *height > kMaxUint32 ||
      *fps > kMaxUint32 || !FacingArgumentIsValid(map)) {
    result->Error("invalid_argument",
                  "preview width, height, and fps must be positive integers");
    return;
  }

  uint64_t generation = 0;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->alive) {
      result->Error("invalid_state", "encoder channel is shut down");
      return;
    }
    generation = ++state_->generation;
    state_->terminal = false;
    state_->camera_open = false;
  }

  const std::weak_ptr<State> weak_state = state_;
  EncodingSession* session = &session_;
  CameraControllerCallbacks callbacks{
      [weak_state, generation](CameraReady ready) {
        SendCameraEvent(weak_state, generation, false, ReadyEvent(ready));
      },
      [weak_state, generation](hmw::Error error) {
        SendCameraEvent(weak_state, generation, true,
                        ErrorEvent(error, "camera"));
      },
      [weak_state, generation, session](uint64_t, CameraFrame frame) {
        const std::shared_ptr<State> state = weak_state.lock();
        if (!state) {
          return;
        }
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          if (!state->alive || state->generation != generation ||
              !state->encoding_active) {
            return;
          }
        }
        // The same immutable RGBA owner already published to the texture is
        // handed to the encoder; the session owns all bounding and pacing.
        session->OfferFrame(generation, std::move(frame));
      }};

  hmw::Outcome opened = controller_.Open(
      CameraPreviewConfig{static_cast<uint32_t>(*width),
                          static_cast<uint32_t>(*height),
                          static_cast<uint32_t>(*fps)},
      std::move(callbacks));
  if (!opened.ok()) {
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (state_->generation == generation) {
        state_->terminal = true;
      }
    }
    CompleteError(result, *opened.error);
    return;
  }
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->generation == generation) {
      state_->camera_open = true;
    }
  }
  result->Success();
}

void EncoderChannel::HandleCloseCamera(
    std::unique_ptr<hmw::FlutterResult> result) {
  StopEncodingRun();
  hmw::Outcome closed = controller_.Close();
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->camera_open = false;
  }
  if (!closed.ok()) {
    CompleteError(result, *closed.error);
    return;
  }
  result->Success();
}

void EncoderChannel::HandleStartEncoding(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<hmw::FlutterResult> result) {
  const flutter::EncodableMap* map = ArgumentsMap(arguments);
  if (arguments != nullptr && map == nullptr) {
    result->Error("invalid_argument", "encoder arguments must be a map");
    return;
  }
  hmw::Result<hmw::EncodingConfig> parsed = ParseEncodingConfig(map);
  if (!parsed.ok()) {
    CompleteError(result, *parsed.error);
    return;
  }

  uint64_t camera_generation = 0;
  uint64_t epoch = 0;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->alive) {
      CompleteError(result, InvalidState("encoder channel is shut down"));
      return;
    }
    if (!state_->camera_open) {
      CompleteError(result, InvalidState("camera is not open"));
      return;
    }
    if (state_->encoding_active) {
      CompleteError(result,
                    hmw::Error{hmw::Status::kBusy, "encoding is already running"});
      return;
    }
    camera_generation = state_->generation;
    epoch = ++state_->encoding_epoch;
    state_->encoding_active = true;
    state_->run_pending = true;
  }

  hmw::Result<uint64_t> started = session_.Start(
      camera_generation, std::move(*parsed.value), MakeEncoderCallbacks(epoch));
  if (!started.ok()) {
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (state_->encoding_epoch == epoch) {
        state_->encoding_active = false;
        state_->run_pending = false;
        ++state_->encoding_epoch;
      }
    }
    CompleteError(result, started.error.value_or(
                              InvalidState("encoder session did not start")));
    return;
  }
  result->Success();
}

void EncoderChannel::HandleStopEncoding(
    std::unique_ptr<hmw::FlutterResult> result) {
  StopEncodingRun();
  // Android completes `stopEncoding` unconditionally; a terminal encoder
  // failure reaches Dart as an error event, never as a second failure here.
  result->Success();
}

void EncoderChannel::HandleEncoderRequest(
    std::string_view method, std::unique_ptr<hmw::FlutterResult> result) {
  bool active = false;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    active = state_->alive && state_->encoding_active;
  }
  if (active) {
    if (method == "requestKeyframe") {
      session_.RequestKeyframe();
    } else {
      session_.GrantFramePermit();
    }
  }
  result->Success();
}

hmw::EncoderCallbacks EncoderChannel::MakeEncoderCallbacks(uint64_t epoch) {
  const std::weak_ptr<State> weak_state = state_;
  return hmw::EncoderCallbacks{
      [weak_state, epoch](uint64_t, std::optional<std::string> path,
                          uint32_t width, uint32_t height) {
        SendEncoderEvent(weak_state, epoch, StartedEvent(path, width, height));
      },
      [weak_state, epoch](uint64_t, hmw::EncodedFrame frame) {
        SendEncoderEvent(weak_state, epoch, FrameEvent(frame));
      },
      [weak_state, epoch](uint64_t, hmw::EncodingStats stats) {
        SendEncoderEvent(weak_state, epoch, StatsEvent(stats));
      },
      [weak_state, epoch](uint64_t, std::optional<std::string> path,
                          hmw::EncodingStats stats) {
        SendEncoderEvent(weak_state, epoch, StoppedEvent(path, stats));
      },
      [weak_state, epoch](uint64_t, hmw::Error error) {
        RetireEncodingRun(weak_state, epoch);
        SendEncoderEvent(weak_state, epoch, ErrorEvent(error, "encoder"));
      },
      [weak_state, epoch](uint64_t, std::string message) {
        SendEncoderEvent(weak_state, epoch, InfoEvent(message));
      }};
}

void EncoderChannel::StopEncodingRun() {
  bool should_stop = false;
  uint64_t epoch = 0;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    should_stop = state_->run_pending;
    epoch = state_->encoding_epoch;
    state_->encoding_active = false;
    state_->run_pending = false;
  }
  if (!should_stop) {
    return;
  }
  // The session publishes `stopped` from inside `Stop`, so the epoch stays
  // valid until the terminal callback has been delivered.
  (void)session_.Stop();
  std::lock_guard<std::mutex> lock(state_->mutex);
  if (state_->encoding_epoch == epoch) {
    ++state_->encoding_epoch;
  }
}

void EncoderChannel::Shutdown() {
  bool should_stop = false;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->alive) {
      return;
    }
    state_->alive = false;
    state_->terminal = true;
    state_->camera_open = false;
    ++state_->generation;
    ++state_->encoding_epoch;
    should_stop = state_->run_pending;
    state_->encoding_active = false;
    state_->run_pending = false;
    state_->event_sender = {};
  }
  if (should_stop) {
    (void)session_.Stop();
  }
  (void)controller_.Close();
}

}  // namespace hcw
