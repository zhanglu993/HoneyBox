#include "honey_camera_windows/encoder_channel.h"

#include "honey_media_windows/windows_media_plugin.h"
#include "test_support.h"

#include <flutter/encodable_value.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;
using flutter::EncodableMap;
using flutter::EncodableValue;

// Shared ordering log so a test can assert that encoding is retired before the
// camera that feeds it.
class Trace final {
 public:
  void Push(std::string entry) {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.push_back(std::move(entry));
  }
  std::vector<std::string> entries() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return entries_;
  }

 private:
  mutable std::mutex mutex_;
  std::vector<std::string> entries_;
};

class SourceState final {
 public:
  explicit SourceState(std::shared_ptr<Trace> trace = nullptr)
      : trace_(std::move(trace)) {}

  void Push(hcw::CameraFrame frame) {
    std::lock_guard<std::mutex> lock(mutex_);
    frame_ = std::move(frame);
    condition_.notify_all();
  }
  bool WaitForRead() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s, [&] { return reading_; });
  }
  hmw::Result<hcw::CameraFrame> ReadNext() {
    std::unique_lock<std::mutex> lock(mutex_);
    reading_ = true;
    condition_.notify_all();
    condition_.wait(lock, [&] { return stopped_ || frame_; });
    if (stopped_) {
      return {std::nullopt,
              hmw::Error{hmw::Status::kCancelled, "source stopped"}};
    }
    hcw::CameraFrame frame = std::move(*frame_);
    frame_.reset();
    return {std::move(frame), std::nullopt};
  }
  void Stop() noexcept {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!stopped_ && trace_) {
        trace_->Push("camera");
      }
      stopped_ = true;
    }
    condition_.notify_all();
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  std::shared_ptr<Trace> trace_;
  std::optional<hcw::CameraFrame> frame_;
  bool reading_ = false;
  bool stopped_ = false;
};

class Source final : public hcw::CameraFrameSource {
 public:
  explicit Source(std::shared_ptr<SourceState> state)
      : state_(std::move(state)) {}
  hmw::Result<hcw::CameraFrame> ReadNext() override {
    return state_->ReadNext();
  }
  void RequestStop() noexcept override { state_->Stop(); }

 private:
  std::shared_ptr<SourceState> state_;
};

// Records everything the channel asks of the encoding session and replays the
// encoder callbacks on demand, so the wire contract is tested without a codec.
class FakeSession final : public hcw::EncodingSession {
 public:
  explicit FakeSession(std::shared_ptr<Trace> trace = nullptr)
      : trace_(std::move(trace)) {}

  hmw::Result<uint64_t> Start(uint64_t camera_generation,
                              hmw::EncodingConfig started_config,
                              hmw::EncoderCallbacks started_callbacks) override {
    ++starts;
    camera_generations.push_back(camera_generation);
    config = started_config;
    callbacks = std::move(started_callbacks);
    if (start_error) {
      return {std::nullopt, *start_error};
    }
    return {++generation, std::nullopt};
  }

  void OfferFrame(uint64_t camera_generation,
                  hcw::CameraFrame frame) noexcept override {
    offered_generations.push_back(camera_generation);
    offered_markers.push_back(
        frame.rgba && !frame.rgba->empty() ? frame.rgba->front() : 0U);
  }

  void GrantFramePermit() noexcept override { ++permits; }
  void RequestKeyframe() noexcept override { ++keyframe_requests; }

  hmw::Outcome Stop() override {
    ++stops;
    if (trace_) {
      trace_->Push("encoder");
    }
    return stop_outcome;
  }

  void Shutdown() override { ++shutdowns; }

  void EmitStartedFromConfig(std::optional<std::string> path = std::nullopt) {
    if (callbacks.on_started && config) {
      callbacks.on_started(generation, std::move(path), config->width,
                           config->height);
    }
  }
  void EmitFrame(hmw::EncodedFrame frame) {
    if (callbacks.on_frame) {
      callbacks.on_frame(generation, std::move(frame));
    }
  }
  void EmitStats(hmw::EncodingStats stats) {
    if (callbacks.on_stats) {
      callbacks.on_stats(generation, stats);
    }
  }
  void EmitStopped(std::optional<std::string> path, hmw::EncodingStats stats) {
    if (callbacks.on_stopped) {
      callbacks.on_stopped(generation, std::move(path), stats);
    }
  }
  void EmitError(hmw::Error error) {
    if (callbacks.on_error) {
      callbacks.on_error(generation, std::move(error));
    }
  }
  void EmitInfo(std::string message) {
    if (callbacks.on_info) {
      callbacks.on_info(generation, std::move(message));
    }
  }

  std::optional<hmw::EncodingConfig> config;
  hmw::EncoderCallbacks callbacks;
  std::optional<hmw::Error> start_error;
  hmw::Outcome stop_outcome;
  std::vector<uint64_t> camera_generations;
  std::vector<uint64_t> offered_generations;
  std::vector<uint8_t> offered_markers;
  uint64_t generation = 0;
  size_t starts = 0;
  size_t stops = 0;
  size_t shutdowns = 0;
  size_t permits = 0;
  size_t keyframe_requests = 0;

 private:
  std::shared_ptr<Trace> trace_;
};

class QueueDispatcher final : public hmw::PlatformDispatcher {
 public:
  bool Post(std::function<void()> callback) override {
    std::lock_guard<std::mutex> lock(mutex_);
    callbacks_.push_back(std::move(callback));
    condition_.notify_all();
    return true;
  }
  bool WaitForPending(size_t minimum = 1) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s, [&] {
      return callbacks_.size() >= minimum;
    });
  }
  void Drain() {
    for (;;) {
      std::function<void()> callback;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (callbacks_.empty()) {
          return;
        }
        callback = std::move(callbacks_.front());
        callbacks_.pop_front();
      }
      callback();
    }
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<std::function<void()>> callbacks_;
};

class Registry final : public hmw::TextureRegistry {
 public:
  int64_t RegisterPixelBufferTexture(
      hmw::PixelBufferProvider provider) override {
    provider_ = std::move(provider);
    return provider_().owner ? 73 : -1;
  }
  bool MarkFrameAvailable(int64_t id) override {
    ++marks;
    return id == 73 && provider_ && provider_().owner;
  }
  bool UnregisterTexture(int64_t id) override {
    if (id != 73) {
      return false;
    }
    ++unregisters;
    return true;
  }

  hmw::PixelBufferProvider provider_;
  size_t marks = 0;
  size_t unregisters = 0;
};

struct ResultCapture {
  size_t successes = 0;
  size_t errors = 0;
  size_t not_implemented = 0;
  std::string error_code;
  std::string error_message;
};

class Result final : public hmw::FlutterResult {
 public:
  explicit Result(std::shared_ptr<ResultCapture> capture)
      : capture_(std::move(capture)) {}

 protected:
  void SuccessInternal(const EncodableValue*) override {
    ++capture_->successes;
  }
  void ErrorInternal(const std::string& code, const std::string& message,
                     const EncodableValue*) override {
    ++capture_->errors;
    capture_->error_code = code;
    capture_->error_message = message;
  }
  void NotImplementedInternal() override {
    ++capture_->not_implemented;
  }

 private:
  std::shared_ptr<ResultCapture> capture_;
};

std::shared_ptr<ResultCapture> Invoke(
    hcw::EncoderChannel& channel, std::string_view method,
    const EncodableValue* arguments = nullptr) {
  auto capture = std::make_shared<ResultCapture>();
  channel.Handle(method, arguments, std::make_unique<Result>(capture));
  return capture;
}

const EncodableValue* Field(const EncodableValue& value, const char* key) {
  const auto* map = std::get_if<EncodableMap>(&value);
  if (map == nullptr) {
    return nullptr;
  }
  const auto found = map->find(EncodableValue(key));
  return found == map->end() ? nullptr : &found->second;
}

int64_t Integer(const EncodableValue* value) {
  if (const auto* number = std::get_if<int64_t>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return *number;
  }
  return -1;
}

std::string String(const EncodableValue* value) {
  const auto* text = value == nullptr ? nullptr : std::get_if<std::string>(value);
  return text == nullptr ? std::string{} : *text;
}

bool Boolean(const EncodableValue* value) {
  const auto* flag = value == nullptr ? nullptr : std::get_if<bool>(value);
  return flag != nullptr && *flag;
}

bool IsNull(const EncodableValue* value) {
  return value != nullptr && std::holds_alternative<std::monostate>(*value);
}

double Double(const EncodableValue* value) {
  const auto* number = value == nullptr ? nullptr : std::get_if<double>(value);
  return number == nullptr ? -1.0 : *number;
}

std::vector<uint8_t> Binary(const EncodableValue* value) {
  const auto* bytes =
      value == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(value);
  return bytes == nullptr ? std::vector<uint8_t>{} : *bytes;
}

EncodableValue Arguments(int64_t width, int64_t height, int64_t fps) {
  return EncodableValue(EncodableMap{
      {EncodableValue("width"), EncodableValue(width)},
      {EncodableValue("height"), EncodableValue(height)},
      {EncodableValue("fps"), EncodableValue(fps)},
      {EncodableValue("facingFront"), EncodableValue(true)},
  });
}

// The exact `EncoderConfig.toWire()` payload plus the `stream` flag that
// `startEncoding` appends.
struct WireConfig {
  std::string format = "h264";
  int64_t width = 368;
  int64_t height = 368;
  double crop_zoom = 1.0;
  int64_t fps = 15;
  int64_t bitrate = 150000;
  int64_t i_frame_interval_sec = 6;
  bool msv1_skip = true;
  int64_t msv1_skip_thr = 0;
  int64_t jpeg_quality = 80;
  bool record_to_file = false;
  bool stream = true;
};

EncodableValue EncodingArguments(const WireConfig& wire = {}) {
  return EncodableValue(EncodableMap{
      {EncodableValue("format"), EncodableValue(wire.format)},
      {EncodableValue("width"), EncodableValue(wire.width)},
      {EncodableValue("height"), EncodableValue(wire.height)},
      {EncodableValue("cropZoom"), EncodableValue(wire.crop_zoom)},
      {EncodableValue("fps"), EncodableValue(wire.fps)},
      {EncodableValue("bitrate"), EncodableValue(wire.bitrate)},
      {EncodableValue("iFrameIntervalSec"),
       EncodableValue(wire.i_frame_interval_sec)},
      {EncodableValue("msv1Skip"), EncodableValue(wire.msv1_skip)},
      {EncodableValue("msv1SkipThr"), EncodableValue(wire.msv1_skip_thr)},
      {EncodableValue("jpegQuality"), EncodableValue(wire.jpeg_quality)},
      {EncodableValue("recordToFile"), EncodableValue(wire.record_to_file)},
      {EncodableValue("stream"), EncodableValue(wire.stream)},
  });
}

hcw::CameraFrame Frame(uint8_t marker, uint32_t width = 2,
                       uint32_t height = 1) {
  return {width, height, 0,
          std::make_shared<const std::vector<uint8_t>>(
              static_cast<size_t>(width) * height * 4U, marker)};
}

hmw::EncodedFrame Encoded(std::vector<uint8_t> bytes, int64_t pts, bool key) {
  return {std::make_shared<const std::vector<uint8_t>>(std::move(bytes)), pts,
          key};
}

std::shared_ptr<hcw::CameraTextureCleanupCoordinator> Cleanup(
    hmw::TextureRegistry& registry, hmw::PlatformDispatcher& dispatcher) {
  return hcw::CameraTextureCleanupCoordinator::Create(registry, dispatcher);
}

// One open camera plus a fake encoding session, wired exactly like the plugin.
class Harness final {
 public:
  explicit Harness(std::shared_ptr<Trace> trace = nullptr)
      : trace_(std::move(trace)),
        source(std::make_shared<SourceState>(trace_)),
        session(trace_),
        controller(Cleanup(registry, dispatcher),
                   [this](const hcw::CameraPreviewConfig& config) {
                     requested.push_back(config);
                     return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
                         std::make_unique<Source>(source), std::nullopt};
                   }),
        channel(controller, session, [this](EncodableValue event) {
          events.push_back(std::move(event));
        }) {}

  // Opens the camera and drains the first frame so the ready event lands.
  bool OpenCamera() {
    EncodableValue arguments = Arguments(2, 1, 15);
    if (Invoke(channel, "openCamera", &arguments)->successes != 1) {
      return false;
    }
    if (!source->WaitForRead()) {
      return false;
    }
    source->Push(Frame(9));
    if (!dispatcher.WaitForPending()) {
      return false;
    }
    dispatcher.Drain();
    events.clear();
    return true;
  }

  const EncodableValue& last_event() const { return events.back(); }

  std::shared_ptr<Trace> trace_;
  Registry registry;
  QueueDispatcher dispatcher;
  std::shared_ptr<SourceState> source;
  FakeSession session;
  std::vector<hcw::CameraPreviewConfig> requested;
  std::vector<EncodableValue> events;
  hcw::CameraTextureController controller;
  hcw::EncoderChannel channel;
};

}  // namespace

HMW_TEST(encoder_channel_open_accepts_then_emits_exact_ready_payload) {
  Harness harness;
  EncodableValue arguments = Arguments(2, 1, 15);

  const auto result = Invoke(harness.channel, "openCamera", &arguments);
  HMW_EXPECT(result->successes == 1 && result->errors == 0);
  HMW_EXPECT(harness.events.empty());
  HMW_EXPECT(harness.source->WaitForRead());
  harness.source->Push(Frame(9));
  HMW_EXPECT(harness.dispatcher.WaitForPending());
  harness.dispatcher.Drain();

  HMW_EXPECT(harness.requested.size() == 1);
  HMW_EXPECT(harness.events.size() == 1);
  if (!harness.events.empty()) {
    const auto& event = harness.events.front();
    const auto* map = std::get_if<EncodableMap>(&event);
    HMW_EXPECT(map != nullptr && map->size() == 10);
    HMW_EXPECT(String(Field(event, "event")) == "camera");
    HMW_EXPECT(Integer(Field(event, "textureId")) == 73);
    HMW_EXPECT(Integer(Field(event, "previewWidth")) == 2);
    HMW_EXPECT(Integer(Field(event, "previewHeight")) == 1);
    HMW_EXPECT(Integer(Field(event, "sensorOrientation")) == 0);
    HMW_EXPECT(!Boolean(Field(event, "facingFront")));
    HMW_EXPECT(!Boolean(Field(event, "focusSupported")));
    for (const char* name : {"evMin", "evMax", "evStep"}) {
      HMW_EXPECT(Double(Field(event, name)) == 0.0);
    }
  }
  harness.channel.Shutdown();
  harness.dispatcher.Drain();
}

HMW_TEST(encoder_channel_uses_android_defaults_and_validates_explicit_values) {
  Harness harness;

  HMW_EXPECT(Invoke(harness.channel, "openCamera")->successes == 1);
  HMW_EXPECT(harness.source->WaitForRead());
  HMW_EXPECT(harness.requested.size() == 1);
  HMW_EXPECT(harness.requested.back().width == 640 &&
             harness.requested.back().height == 480 &&
             harness.requested.back().fps == 15);
  HMW_EXPECT(Invoke(harness.channel, "closeCamera")->successes == 1);
  harness.dispatcher.Drain();

  EncodableValue zero = Arguments(0, 1, 15);
  EncodableValue negative = Arguments(2, -1, 15);
  EncodableValue wrong_type(EncodableMap{
      {EncodableValue("width"), EncodableValue("2")},
      {EncodableValue("height"), EncodableValue(int32_t{1})},
      {EncodableValue("fps"), EncodableValue(int32_t{15})},
  });
  for (const EncodableValue* invalid : {&zero, &negative, &wrong_type}) {
    const auto result = Invoke(harness.channel, "openCamera", invalid);
    HMW_EXPECT(result->successes == 0 && result->errors == 1);
    HMW_EXPECT(result->error_code == "invalid_argument");
  }
}

HMW_TEST(encoder_channel_close_is_idempotent_and_other_methods_are_unimplemented) {
  Harness harness;
  EncodableValue arguments = Arguments(2, 1, 15);
  HMW_EXPECT(Invoke(harness.channel, "openCamera", &arguments)->successes == 1);
  HMW_EXPECT(harness.source->WaitForRead());
  HMW_EXPECT(Invoke(harness.channel, "closeCamera")->successes == 1);
  HMW_EXPECT(Invoke(harness.channel, "closeCamera")->successes == 1);
  // Camera controls and encoded preview stay out of this milestone.
  for (const char* method :
       {"setConfig", "focusAt", "setEv", "setZoom", "setPreviewMode",
        "takePicture"}) {
    const auto unknown = Invoke(harness.channel, method);
    HMW_EXPECT(unknown->not_implemented == 1);
    HMW_EXPECT(unknown->successes == 0 && unknown->errors == 0);
  }
  harness.dispatcher.Drain();
}

HMW_TEST(encoder_channel_emits_one_android_error_map_and_honors_cancelled_sink) {
  Harness harness;
  bool listening = true;
  std::vector<EncodableValue> received;
  hcw::EncoderChannel channel(harness.controller, harness.session,
                              [&](EncodableValue event) {
                                if (listening) {
                                  received.push_back(std::move(event));
                                }
                              });
  EncodableValue arguments = Arguments(2, 1, 15);
  HMW_EXPECT(Invoke(channel, "openCamera", &arguments)->successes == 1);
  HMW_EXPECT(harness.source->WaitForRead());
  hcw::CameraFrame invalid = Frame(4);
  invalid.rgba =
      std::make_shared<const std::vector<uint8_t>>(std::vector<uint8_t>{4});
  harness.source->Push(invalid);
  HMW_EXPECT(harness.dispatcher.WaitForPending());
  harness.dispatcher.Drain();
  harness.source->Push(invalid);
  harness.dispatcher.Drain();

  HMW_EXPECT(received.size() == 1);
  if (!received.empty()) {
    const auto* map = std::get_if<EncodableMap>(&received.front());
    HMW_EXPECT(map != nullptr && map->size() == 4);
    HMW_EXPECT(String(Field(received.front(), "event")) == "error");
    HMW_EXPECT(!String(Field(received.front(), "message")).empty());
    HMW_EXPECT(String(Field(received.front(), "code")) == "io_error");
    HMW_EXPECT(String(Field(received.front(), "details")) == "camera");
  }
  listening = false;
  channel.Shutdown();
  harness.dispatcher.Drain();
  HMW_EXPECT(received.size() == 1);
}

HMW_TEST(encoder_channel_shutdown_suppresses_queued_ready_event) {
  Harness harness;
  EncodableValue arguments = Arguments(2, 1, 15);
  HMW_EXPECT(Invoke(harness.channel, "openCamera", &arguments)->successes == 1);
  HMW_EXPECT(harness.source->WaitForRead());
  harness.source->Push(Frame(8));
  HMW_EXPECT(harness.dispatcher.WaitForPending());
  harness.channel.Shutdown();
  harness.dispatcher.Drain();
  HMW_EXPECT(harness.events.empty());
  HMW_EXPECT(harness.registry.marks == 0);
}

HMW_TEST(encoder_channel_start_encoding_parses_android_h264_contract) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue arguments = EncodingArguments();

  const auto result = Invoke(harness.channel, "startEncoding", &arguments);
  HMW_EXPECT(result->successes == 1 && result->errors == 0);
  HMW_EXPECT(harness.session.starts == 1);
  HMW_EXPECT(harness.session.config.has_value());
  if (harness.session.config) {
    const hmw::EncodingConfig& config = *harness.session.config;
    HMW_EXPECT(config.format == hmw::EncoderFormat::kH264);
    HMW_EXPECT(config.width == 368U && config.height == 368U);
    HMW_EXPECT(config.fps == 15U);
    HMW_EXPECT(config.bitrate == 150000U);
    HMW_EXPECT(config.i_frame_interval_sec == 6U);
    HMW_EXPECT(config.crop_zoom == 1.0);
    HMW_EXPECT(config.msv1_skip);
    HMW_EXPECT(config.msv1_skip_threshold == 0U);
    HMW_EXPECT(config.jpeg_quality == 80U);
    HMW_EXPECT(!config.record_to_file);
    HMW_EXPECT(config.stream);
  }
}

HMW_TEST(encoder_channel_start_encoding_applies_android_wire_defaults) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue empty(EncodableMap{});

  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &empty)->successes == 1);
  HMW_EXPECT(harness.session.config.has_value());
  if (harness.session.config) {
    const hmw::EncodingConfig& config = *harness.session.config;
    HMW_EXPECT(config.format == hmw::EncoderFormat::kH264);
    HMW_EXPECT(config.width == 640U && config.height == 480U);
    HMW_EXPECT(config.fps == 15U);
    HMW_EXPECT(config.bitrate == 2000000U);
    HMW_EXPECT(config.i_frame_interval_sec == 1U);
    HMW_EXPECT(config.crop_zoom == 1.0);
    HMW_EXPECT(config.msv1_skip);
    HMW_EXPECT(config.msv1_skip_threshold == 0U);
    HMW_EXPECT(config.jpeg_quality == 80U);
    HMW_EXPECT(!config.record_to_file && !config.stream);
  }
}

HMW_TEST(encoder_channel_start_encoding_normalizes_dimensions_per_format) {
  {
    Harness harness;
    HMW_EXPECT(harness.OpenCamera());
    WireConfig wire;
    wire.width = 369;
    wire.height = 367;
    EncodableValue arguments = EncodingArguments(wire);
    HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                   ->successes == 1);
    HMW_EXPECT(harness.session.config->width == 368U);
    HMW_EXPECT(harness.session.config->height == 366U);
    harness.session.EmitStartedFromConfig();
    HMW_EXPECT(harness.events.size() == 1);
    HMW_EXPECT(Integer(Field(harness.last_event(), "width")) == 368);
    HMW_EXPECT(Integer(Field(harness.last_event(), "height")) == 366);
  }
  {
    Harness harness;
    HMW_EXPECT(harness.OpenCamera());
    WireConfig wire;
    wire.format = "mvs1";
    wire.width = 367;
    wire.height = 366;
    EncodableValue arguments = EncodingArguments(wire);
    HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                   ->successes == 1);
    HMW_EXPECT(harness.session.config->format == hmw::EncoderFormat::kMsv1);
    HMW_EXPECT(harness.session.config->width == 364U);
    HMW_EXPECT(harness.session.config->height == 364U);
  }
  {
    Harness harness;
    HMW_EXPECT(harness.OpenCamera());
    WireConfig wire;
    wire.format = "mvs1";
    wire.width = 3;
    wire.height = 2;
    EncodableValue arguments = EncodingArguments(wire);
    HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                   ->successes == 1);
    HMW_EXPECT(harness.session.config->width == 4U);
    HMW_EXPECT(harness.session.config->height == 4U);
  }
  {
    Harness harness;
    HMW_EXPECT(harness.OpenCamera());
    WireConfig wire;
    wire.format = "jpeg";
    wire.width = 1;
    wire.height = 8;
    EncodableValue arguments = EncodingArguments(wire);
    const auto result = Invoke(harness.channel, "startEncoding", &arguments);
    HMW_EXPECT(result->errors == 1 && result->successes == 0);
    HMW_EXPECT(result->error_code == "invalid_argument");
    HMW_EXPECT(harness.session.starts == 0);
  }
}

HMW_TEST(encoder_channel_start_encoding_rejects_wrong_types_and_ranges) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());

  std::vector<EncodableValue> invalid;
  {
    WireConfig wire;
    wire.format = "vp9";
    invalid.push_back(EncodingArguments(wire));
  }
  {
    WireConfig wire;
    wire.fps = 0;
    invalid.push_back(EncodingArguments(wire));
  }
  {
    WireConfig wire;
    wire.bitrate = 0;
    invalid.push_back(EncodingArguments(wire));
  }
  {
    WireConfig wire;
    wire.bitrate = 100000001;
    invalid.push_back(EncodingArguments(wire));
  }
  {
    WireConfig wire;
    wire.i_frame_interval_sec = -1;
    invalid.push_back(EncodingArguments(wire));
  }
  {
    WireConfig wire;
    wire.jpeg_quality = 101;
    invalid.push_back(EncodingArguments(wire));
  }
  {
    WireConfig wire;
    wire.jpeg_quality = 0;
    invalid.push_back(EncodingArguments(wire));
  }
  {
    WireConfig wire;
    wire.width = 0;
    invalid.push_back(EncodingArguments(wire));
  }
  invalid.push_back(EncodableValue(EncodableMap{
      {EncodableValue("format"), EncodableValue(int64_t{0})},
  }));
  invalid.push_back(EncodableValue(EncodableMap{
      {EncodableValue("stream"), EncodableValue("true")},
  }));
  invalid.push_back(EncodableValue(EncodableMap{
      {EncodableValue("cropZoom"), EncodableValue("1.0")},
  }));
  invalid.push_back(EncodableValue("not a map"));

  for (const EncodableValue& arguments : invalid) {
    const auto result = Invoke(harness.channel, "startEncoding", &arguments);
    HMW_EXPECT(result->successes == 0 && result->errors == 1);
    HMW_EXPECT(result->error_code == "invalid_argument");
  }
  HMW_EXPECT(harness.session.starts == 0);
}

HMW_TEST(encoder_channel_start_encoding_rejects_local_recording) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  WireConfig wire;
  wire.record_to_file = true;
  EncodableValue arguments = EncodingArguments(wire);

  const auto result = Invoke(harness.channel, "startEncoding", &arguments);
  HMW_EXPECT(result->successes == 0 && result->errors == 1);
  HMW_EXPECT(result->error_code == "unsupported_feature");
  HMW_EXPECT(harness.session.starts == 0);
}

HMW_TEST(encoder_channel_start_encoding_requires_an_open_camera) {
  Harness harness;
  EncodableValue arguments = EncodingArguments();

  const auto before = Invoke(harness.channel, "startEncoding", &arguments);
  HMW_EXPECT(before->successes == 0 && before->errors == 1);
  HMW_EXPECT(before->error_code == "invalid_state");
  HMW_EXPECT(harness.session.starts == 0);

  HMW_EXPECT(harness.OpenCamera());
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);
  HMW_EXPECT(Invoke(harness.channel, "stopEncoding")->successes == 1);
  HMW_EXPECT(Invoke(harness.channel, "closeCamera")->successes == 1);
  harness.dispatcher.Drain();

  const auto after = Invoke(harness.channel, "startEncoding", &arguments);
  HMW_EXPECT(after->successes == 0 && after->errors == 1);
  HMW_EXPECT(after->error_code == "invalid_state");
  HMW_EXPECT(harness.session.starts == 1);
}

HMW_TEST(encoder_channel_start_encoding_rejects_a_second_active_run) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue arguments = EncodingArguments();

  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);
  const auto repeated = Invoke(harness.channel, "startEncoding", &arguments);
  HMW_EXPECT(repeated->successes == 0 && repeated->errors == 1);
  HMW_EXPECT(repeated->error_code == "busy");
  HMW_EXPECT(harness.session.starts == 1);

  HMW_EXPECT(Invoke(harness.channel, "stopEncoding")->successes == 1);
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);
  HMW_EXPECT(harness.session.starts == 2);
}

HMW_TEST(encoder_channel_start_encoding_surfaces_session_failure) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  harness.session.start_error =
      hmw::Error{hmw::Status::kCodecUnavailable, "no local H.264 MFT"};
  EncodableValue arguments = EncodingArguments();

  const auto result = Invoke(harness.channel, "startEncoding", &arguments);
  HMW_EXPECT(result->successes == 0 && result->errors == 1);
  HMW_EXPECT(result->error_code == "codec_unavailable");
  HMW_EXPECT(result->error_message == "no local H.264 MFT");

  // A failed start leaves no active run, so a retry is accepted.
  harness.session.start_error.reset();
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);
}

HMW_TEST(encoder_channel_encoding_events_match_android_payloads) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue arguments = EncodingArguments();
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);

  harness.session.EmitStartedFromConfig();
  HMW_EXPECT(harness.events.size() == 1);
  {
    const auto& event = harness.last_event();
    const auto* map = std::get_if<EncodableMap>(&event);
    HMW_EXPECT(map != nullptr && map->size() == 4);
    HMW_EXPECT(String(Field(event, "event")) == "started");
    HMW_EXPECT(IsNull(Field(event, "path")));
    HMW_EXPECT(Integer(Field(event, "width")) == 368);
    HMW_EXPECT(Integer(Field(event, "height")) == 368);
  }

  harness.session.EmitFrame(Encoded({0, 0, 0, 1, 0x65}, 1000, true));
  HMW_EXPECT(harness.events.size() == 2);
  {
    const auto& event = harness.last_event();
    const auto* map = std::get_if<EncodableMap>(&event);
    HMW_EXPECT(map != nullptr && map->size() == 3);
    HMW_EXPECT(String(Field(event, "event")) == "frame");
    HMW_EXPECT(Binary(Field(event, "data")).size() == 5U);
    HMW_EXPECT(Binary(Field(event, "data")).back() == 0x65);
    HMW_EXPECT(Boolean(Field(event, "key")));
  }

  harness.session.EmitStats({12U, 3U, 4096U, 2048U, 14.5, 256U});
  HMW_EXPECT(harness.events.size() == 3);
  {
    const auto& event = harness.last_event();
    const auto* map = std::get_if<EncodableMap>(&event);
    HMW_EXPECT(map != nullptr && map->size() == 7);
    HMW_EXPECT(String(Field(event, "event")) == "stats");
    HMW_EXPECT(Integer(Field(event, "frames")) == 12);
    HMW_EXPECT(Integer(Field(event, "keyframes")) == 3);
    HMW_EXPECT(Integer(Field(event, "bytes")) == 4096);
    HMW_EXPECT(Integer(Field(event, "keyBytes")) == 2048);
    HMW_EXPECT(Double(Field(event, "fps")) == 14.5);
    HMW_EXPECT(Integer(Field(event, "lastBytes")) == 256);
  }

  harness.session.EmitInfo("encoder note");
  HMW_EXPECT(harness.events.size() == 4);
  {
    const auto& event = harness.last_event();
    const auto* map = std::get_if<EncodableMap>(&event);
    HMW_EXPECT(map != nullptr && map->size() == 2);
    HMW_EXPECT(String(Field(event, "event")) == "info");
    HMW_EXPECT(String(Field(event, "message")) == "encoder note");
  }

  harness.session.EmitStopped(std::nullopt, {12U, 3U, 4096U, 2048U, 14.5, 256U});
  HMW_EXPECT(harness.events.size() == 5);
  {
    const auto& event = harness.last_event();
    const auto* map = std::get_if<EncodableMap>(&event);
    HMW_EXPECT(map != nullptr && map->size() == 5);
    HMW_EXPECT(String(Field(event, "event")) == "stopped");
    HMW_EXPECT(IsNull(Field(event, "path")));
    HMW_EXPECT(Integer(Field(event, "frames")) == 12);
    HMW_EXPECT(Integer(Field(event, "keyframes")) == 3);
    HMW_EXPECT(Integer(Field(event, "bytes")) == 4096);
  }
}

HMW_TEST(encoder_channel_encoder_error_event_carries_code_and_details) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue arguments = EncodingArguments();
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);

  harness.session.EmitError(
      hmw::Error{hmw::Status::kEncodeFailed, "MFT rejected the input frame"});
  HMW_EXPECT(harness.events.size() == 1);
  const auto& event = harness.last_event();
  const auto* map = std::get_if<EncodableMap>(&event);
  HMW_EXPECT(map != nullptr && map->size() == 4);
  HMW_EXPECT(String(Field(event, "event")) == "error");
  HMW_EXPECT(String(Field(event, "message")) == "MFT rejected the input frame");
  HMW_EXPECT(String(Field(event, "code")) == "encode_failed");
  HMW_EXPECT(String(Field(event, "details")) == "encoder");

  // A terminal encoder error retires the run, so the next start is accepted.
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);
  HMW_EXPECT(harness.session.starts == 2);
}

HMW_TEST(encoder_channel_stop_encoding_is_idempotent_and_forwards_once) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue arguments = EncodingArguments();

  HMW_EXPECT(Invoke(harness.channel, "stopEncoding")->successes == 1);
  HMW_EXPECT(harness.session.stops == 0);

  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);
  HMW_EXPECT(Invoke(harness.channel, "stopEncoding")->successes == 1);
  HMW_EXPECT(harness.session.stops == 1);
  HMW_EXPECT(Invoke(harness.channel, "stopEncoding")->successes == 1);
  HMW_EXPECT(harness.session.stops == 1);
}

HMW_TEST(encoder_channel_stop_encoding_reports_success_on_session_failure) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue arguments = EncodingArguments();
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);
  harness.session.stop_outcome =
      hmw::Outcome{hmw::Error{hmw::Status::kEncodeFailed, "drain failed"}};

  // The session already published the terminal error as an event; Android's
  // stopEncoding always completes successfully.
  HMW_EXPECT(Invoke(harness.channel, "stopEncoding")->successes == 1);
  HMW_EXPECT(harness.session.stops == 1);
}

HMW_TEST(encoder_channel_forwards_keyframe_and_encoder_frame_requests) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue arguments = EncodingArguments();

  // Requests before a run are accepted and dropped, exactly like Android.
  HMW_EXPECT(Invoke(harness.channel, "requestKeyframe")->successes == 1);
  HMW_EXPECT(Invoke(harness.channel, "requestEncoderFrame")->successes == 1);
  HMW_EXPECT(harness.session.keyframe_requests == 0);
  HMW_EXPECT(harness.session.permits == 0);

  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);
  HMW_EXPECT(Invoke(harness.channel, "requestKeyframe")->successes == 1);
  HMW_EXPECT(Invoke(harness.channel, "requestEncoderFrame")->successes == 1);
  HMW_EXPECT(Invoke(harness.channel, "requestEncoderFrame")->successes == 1);
  HMW_EXPECT(harness.session.keyframe_requests == 1);
  HMW_EXPECT(harness.session.permits == 2);
}

HMW_TEST(encoder_channel_offers_the_same_camera_generation_it_started_with) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue arguments = EncodingArguments();
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);

  harness.source->Push(Frame(21));
  HMW_EXPECT(harness.dispatcher.WaitForPending());
  harness.dispatcher.Drain();

  HMW_EXPECT(harness.session.camera_generations.size() == 1);
  HMW_EXPECT(!harness.session.offered_generations.empty());
  if (!harness.session.offered_generations.empty()) {
    HMW_EXPECT(harness.session.offered_generations.back() ==
               harness.session.camera_generations.back());
    HMW_EXPECT(harness.session.offered_markers.back() == 21U);
  }
}

HMW_TEST(encoder_channel_close_camera_retires_encoding_before_the_camera) {
  const auto trace = std::make_shared<Trace>();
  Harness harness(trace);
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue arguments = EncodingArguments();
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);

  HMW_EXPECT(Invoke(harness.channel, "closeCamera")->successes == 1);
  harness.dispatcher.Drain();
  HMW_EXPECT(harness.session.stops == 1);
  const std::vector<std::string> entries = trace->entries();
  HMW_EXPECT(entries.size() == 2);
  if (entries.size() == 2) {
    HMW_EXPECT(entries[0] == "encoder");
    HMW_EXPECT(entries[1] == "camera");
  }
}

HMW_TEST(encoder_channel_drops_events_from_a_retired_encoding_run) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue arguments = EncodingArguments();
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);
  hmw::EncoderCallbacks retired = harness.session.callbacks;

  HMW_EXPECT(Invoke(harness.channel, "stopEncoding")->successes == 1);
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);
  harness.events.clear();

  // The first run's worker may still be unwinding; its queued callbacks must
  // never reach the new generation's Dart listener.
  retired.on_frame(1U, Encoded({7}, 0, false));
  retired.on_stats(1U, {1U, 0U, 1U, 0U, 15.0, 1U});
  retired.on_error(1U, hmw::Error{hmw::Status::kEncodeFailed, "stale"});
  retired.on_stopped(1U, std::nullopt, {1U, 0U, 1U, 0U, 15.0, 1U});
  HMW_EXPECT(harness.events.empty());

  harness.session.EmitFrame(Encoded({8}, 0, true));
  HMW_EXPECT(harness.events.size() == 1);
  HMW_EXPECT(String(Field(harness.last_event(), "event")) == "frame");
}

HMW_TEST(encoder_channel_shutdown_retires_encoding_and_suppresses_events) {
  Harness harness;
  HMW_EXPECT(harness.OpenCamera());
  EncodableValue arguments = EncodingArguments();
  HMW_EXPECT(Invoke(harness.channel, "startEncoding", &arguments)
                 ->successes == 1);
  hmw::EncoderCallbacks retired = harness.session.callbacks;

  harness.channel.Shutdown();
  harness.dispatcher.Drain();
  HMW_EXPECT(harness.session.stops == 1);

  retired.on_frame(1U, Encoded({9}, 0, true));
  retired.on_error(1U, hmw::Error{hmw::Status::kEncodeFailed, "after shutdown"});
  HMW_EXPECT(harness.events.empty());

  const auto after = Invoke(harness.channel, "startEncoding", &arguments);
  HMW_EXPECT(after->successes == 0 && after->errors == 1);
  HMW_EXPECT(after->error_code == "invalid_state");
  HMW_EXPECT(harness.session.starts == 1);
}
