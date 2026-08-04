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

class SourceState final {
 public:
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
    std::lock_guard<std::mutex> lock(mutex_);
    stopped_ = true;
    condition_.notify_all();
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
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
};

class Result final : public hmw::FlutterResult {
 public:
  explicit Result(std::shared_ptr<ResultCapture> capture)
      : capture_(std::move(capture)) {}

 protected:
  void SuccessInternal(const EncodableValue*) override {
    ++capture_->successes;
  }
  void ErrorInternal(const std::string& code, const std::string&,
                     const EncodableValue*) override {
    ++capture_->errors;
    capture_->error_code = code;
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

EncodableValue Arguments(int64_t width, int64_t height, int64_t fps) {
  return EncodableValue(EncodableMap{
      {EncodableValue("width"), EncodableValue(width)},
      {EncodableValue("height"), EncodableValue(height)},
      {EncodableValue("fps"), EncodableValue(fps)},
      {EncodableValue("facingFront"), EncodableValue(true)},
  });
}

hcw::CameraFrame Frame(uint8_t marker, uint32_t width = 2,
                       uint32_t height = 1) {
  return {width, height, 0,
          std::make_shared<const std::vector<uint8_t>>(
              static_cast<size_t>(width) * height * 4U, marker)};
}

std::shared_ptr<hcw::CameraTextureCleanupCoordinator> Cleanup(
    hmw::TextureRegistry& registry, hmw::PlatformDispatcher& dispatcher) {
  return hcw::CameraTextureCleanupCoordinator::Create(registry, dispatcher);
}

}  // namespace

HMW_TEST(encoder_channel_open_accepts_then_emits_exact_ready_payload) {
  auto source = std::make_shared<SourceState>();
  Registry registry;
  QueueDispatcher dispatcher;
  std::vector<hcw::CameraPreviewConfig> requested;
  std::vector<EncodableValue> events;
  hcw::CameraTextureController controller(
      Cleanup(registry, dispatcher),
      [&](const hcw::CameraPreviewConfig& config) {
        requested.push_back(config);
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<Source>(source), std::nullopt};
      });
  hcw::EncoderChannel channel(
      controller,
      [&](EncodableValue event) { events.push_back(std::move(event)); });
  EncodableValue arguments = Arguments(2, 1, 15);

  const auto result = Invoke(channel, "openCamera", &arguments);
  HMW_EXPECT(result->successes == 1 && result->errors == 0);
  HMW_EXPECT(events.empty());
  HMW_EXPECT(source->WaitForRead());
  source->Push(Frame(9));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();

  HMW_EXPECT(requested.size() == 1);
  HMW_EXPECT(events.size() == 1);
  if (!events.empty()) {
    const auto* map = std::get_if<EncodableMap>(&events.front());
    HMW_EXPECT(map != nullptr && map->size() == 10);
    const auto* event = std::get_if<std::string>(Field(events.front(), "event"));
    HMW_EXPECT(event != nullptr && *event == "camera");
    HMW_EXPECT(Integer(Field(events.front(), "textureId")) == 73);
    HMW_EXPECT(Integer(Field(events.front(), "previewWidth")) == 2);
    HMW_EXPECT(Integer(Field(events.front(), "previewHeight")) == 1);
    HMW_EXPECT(Integer(Field(events.front(), "sensorOrientation")) == 0);
    const auto* facing = std::get_if<bool>(Field(events.front(), "facingFront"));
    const auto* focus = std::get_if<bool>(Field(events.front(), "focusSupported"));
    HMW_EXPECT(facing != nullptr && !*facing);
    HMW_EXPECT(focus != nullptr && !*focus);
    for (const char* name : {"evMin", "evMax", "evStep"}) {
      const auto* value = std::get_if<double>(Field(events.front(), name));
      HMW_EXPECT(value != nullptr && *value == 0.0);
    }
  }
  channel.Shutdown();
  dispatcher.Drain();
}

HMW_TEST(encoder_channel_uses_android_defaults_and_validates_explicit_values) {
  auto source = std::make_shared<SourceState>();
  Registry registry;
  QueueDispatcher dispatcher;
  std::optional<hcw::CameraPreviewConfig> requested;
  hcw::CameraTextureController controller(
      Cleanup(registry, dispatcher),
      [&](const hcw::CameraPreviewConfig& config) {
        requested = config;
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<Source>(source), std::nullopt};
      });
  hcw::EncoderChannel channel(controller, {});

  HMW_EXPECT(Invoke(channel, "openCamera")->successes == 1);
  HMW_EXPECT(source->WaitForRead());
  HMW_EXPECT(requested.has_value() && requested->width == 640 &&
             requested->height == 480 && requested->fps == 15);
  HMW_EXPECT(Invoke(channel, "closeCamera")->successes == 1);
  dispatcher.Drain();

  EncodableValue zero = Arguments(0, 1, 15);
  EncodableValue negative = Arguments(2, -1, 15);
  EncodableValue wrong_type(EncodableMap{
      {EncodableValue("width"), EncodableValue("2")},
      {EncodableValue("height"), EncodableValue(int32_t{1})},
      {EncodableValue("fps"), EncodableValue(int32_t{15})},
  });
  for (const EncodableValue* invalid : {&zero, &negative, &wrong_type}) {
    const auto result = Invoke(channel, "openCamera", invalid);
    HMW_EXPECT(result->successes == 0 && result->errors == 1);
    HMW_EXPECT(result->error_code == "invalid_argument");
  }
}

HMW_TEST(encoder_channel_close_is_idempotent_and_other_methods_are_unimplemented) {
  auto source = std::make_shared<SourceState>();
  Registry registry;
  QueueDispatcher dispatcher;
  hcw::CameraTextureController controller(
      Cleanup(registry, dispatcher),
      [&](const hcw::CameraPreviewConfig&) {
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<Source>(source), std::nullopt};
      });
  hcw::EncoderChannel channel(controller, {});
  EncodableValue arguments = Arguments(2, 1, 15);
  HMW_EXPECT(Invoke(channel, "openCamera", &arguments)->successes == 1);
  HMW_EXPECT(source->WaitForRead());
  HMW_EXPECT(Invoke(channel, "closeCamera")->successes == 1);
  HMW_EXPECT(Invoke(channel, "closeCamera")->successes == 1);
  const auto unknown = Invoke(channel, "startEncoding");
  HMW_EXPECT(unknown->not_implemented == 1);
  HMW_EXPECT(unknown->successes == 0 && unknown->errors == 0);
  dispatcher.Drain();
}

HMW_TEST(encoder_channel_emits_one_android_error_map_and_honors_cancelled_sink) {
  auto source = std::make_shared<SourceState>();
  Registry registry;
  QueueDispatcher dispatcher;
  bool listening = true;
  std::vector<EncodableValue> events;
  hcw::CameraTextureController controller(
      Cleanup(registry, dispatcher),
      [&](const hcw::CameraPreviewConfig&) {
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<Source>(source), std::nullopt};
      });
  hcw::EncoderChannel channel(controller, [&](EncodableValue event) {
    if (listening) {
      events.push_back(std::move(event));
    }
  });
  EncodableValue arguments = Arguments(2, 1, 15);
  HMW_EXPECT(Invoke(channel, "openCamera", &arguments)->successes == 1);
  HMW_EXPECT(source->WaitForRead());
  hcw::CameraFrame invalid = Frame(4);
  invalid.rgba =
      std::make_shared<const std::vector<uint8_t>>(std::vector<uint8_t>{4});
  source->Push(invalid);
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();
  source->Push(invalid);
  dispatcher.Drain();

  HMW_EXPECT(events.size() == 1);
  if (!events.empty()) {
    const auto* map = std::get_if<EncodableMap>(&events.front());
    HMW_EXPECT(map != nullptr && map->size() == 2);
    const auto* event = std::get_if<std::string>(Field(events.front(), "event"));
    const auto* message = std::get_if<std::string>(Field(events.front(), "message"));
    HMW_EXPECT(event != nullptr && *event == "error");
    HMW_EXPECT(message != nullptr && !message->empty());
  }
  listening = false;
  channel.Shutdown();
  dispatcher.Drain();
  HMW_EXPECT(events.size() == 1);
}

HMW_TEST(encoder_channel_shutdown_suppresses_queued_ready_event) {
  auto source = std::make_shared<SourceState>();
  Registry registry;
  QueueDispatcher dispatcher;
  std::vector<EncodableValue> events;
  hcw::CameraTextureController controller(
      Cleanup(registry, dispatcher),
      [&](const hcw::CameraPreviewConfig&) {
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<Source>(source), std::nullopt};
      });
  hcw::EncoderChannel channel(
      controller,
      [&](EncodableValue event) { events.push_back(std::move(event)); });
  EncodableValue arguments = Arguments(2, 1, 15);
  HMW_EXPECT(Invoke(channel, "openCamera", &arguments)->successes == 1);
  HMW_EXPECT(source->WaitForRead());
  source->Push(Frame(8));
  HMW_EXPECT(dispatcher.WaitForPending());
  channel.Shutdown();
  dispatcher.Drain();
  HMW_EXPECT(events.empty());
  HMW_EXPECT(registry.marks == 0);
}
