#include "honey_camera_windows/encoder_channel.h"

#include "honey_media_windows/status.h"

#include <limits>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

namespace hcw {
namespace {

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

bool FacingArgumentIsValid(const flutter::EncodableMap* arguments) {
  const flutter::EncodableValue* value =
      FindArgument(arguments, "facingFront");
  return value == nullptr || std::get_if<bool>(value) != nullptr;
}

void CompleteError(const std::unique_ptr<hmw::FlutterResult>& result,
                   const hmw::Error& error) {
  result->Error(std::string(hmw::StatusCode(error.status)), error.message);
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

flutter::EncodableValue ErrorEvent(const hmw::Error& error) {
  using flutter::EncodableMap;
  using flutter::EncodableValue;
  return EncodableValue(EncodableMap{
      {EncodableValue("event"), EncodableValue("error")},
      {EncodableValue("message"), EncodableValue(error.message)},
  });
}

}  // namespace

struct EncoderChannel::State {
  explicit State(EncoderEventSender sender)
      : event_sender(std::move(sender)) {}

  std::mutex mutex;
  bool alive = true;
  bool terminal = false;
  uint64_t generation = 0;
  EncoderEventSender event_sender;
};

EncoderChannel::EncoderChannel(CameraTextureController& controller,
                               EncoderEventSender event_sender)
    : controller_(controller),
      state_(std::make_shared<State>(std::move(event_sender))) {}

EncoderChannel::~EncoderChannel() { Shutdown(); }

void EncoderChannel::Handle(
    std::string_view method, const flutter::EncodableValue* arguments,
    std::unique_ptr<hmw::FlutterResult> result) {
  if (!result) {
    return;
  }
  if (method != "openCamera" && method != "closeCamera") {
    result->NotImplemented();
    return;
  }

  if (method == "closeCamera") {
    hmw::Outcome closed = controller_.Close();
    if (!closed.ok()) {
      CompleteError(result, *closed.error);
    } else {
      result->Success();
    }
    return;
  }

  const flutter::EncodableMap* map = ArgumentsMap(arguments);
  if (arguments != nullptr && map == nullptr) {
    result->Error("invalid_argument", "camera arguments must be a map");
    return;
  }
  const std::optional<int64_t> width = IntegerArgument(map, "width", 640);
  const std::optional<int64_t> height = IntegerArgument(map, "height", 480);
  const std::optional<int64_t> fps = IntegerArgument(map, "fps", 15);
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
  }

  const std::weak_ptr<State> weak_state = state_;
  CameraControllerCallbacks callbacks{
      [weak_state, generation](CameraReady ready) {
        const std::shared_ptr<State> state = weak_state.lock();
        if (!state) {
          return;
        }
        EncoderEventSender sender;
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          if (!state->alive || state->terminal ||
              state->generation != generation) {
            return;
          }
          sender = state->event_sender;
        }
        if (sender) {
          try {
            sender(ReadyEvent(ready));
          } catch (...) {
          }
        }
      },
      [weak_state, generation](hmw::Error error) {
        const std::shared_ptr<State> state = weak_state.lock();
        if (!state) {
          return;
        }
        EncoderEventSender sender;
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          if (!state->alive || state->terminal ||
              state->generation != generation) {
            return;
          }
          state->terminal = true;
          sender = state->event_sender;
        }
        if (sender) {
          try {
            sender(ErrorEvent(error));
          } catch (...) {
          }
        }
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
  result->Success();
}

void EncoderChannel::Shutdown() {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->alive) {
      return;
    }
    state_->alive = false;
    state_->terminal = true;
    ++state_->generation;
    state_->event_sender = {};
  }
  (void)controller_.Close();
}

}  // namespace hcw
