#include "honey_media_windows/windows_media_plugin.h"

#include "flutter_value_reader.h"

#include <atomic>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

namespace hmw {
namespace {

bool IsConverterMethod(std::string_view method) {
  return method == "getVideoThumbnail" || method == "previewFrames" ||
         method == "convertVideo" || method == "encodeScroll" ||
         method == "encodeFrames" || method == "decodeCvid";
}

struct ProgressState {
  std::mutex mutex;
  bool seen = false;
  bool terminal = false;
  uint32_t done = 0;
  uint32_t total = 0;
};

}  // namespace

struct ConverterChannel::State {
  explicit State(ProgressSender sender)
      : progress_sender(std::move(sender)) {}

  std::mutex mutex;
  bool alive = true;
  ProgressSender progress_sender;
};

void CompleteFlutterError(const std::shared_ptr<FlutterResult>& result,
                          const Error& error) {
  result->Error(std::string(FlutterErrorCode(error.status)), error.message);
}

void CompleteConverterResult(const std::shared_ptr<FlutterResult>& result,
                             Result<MediaJobResult> completed) {
  if (!completed.ok()) {
    CompleteFlutterError(result,
                         completed.error.value_or(Error{
                             Status::kInvalidState,
                             "media operation returned no result"}));
    return;
  }
  const flutter::EncodableValue encoded =
      EncodeConverterResult(*completed.value);
  result->Success(encoded);
}

ConverterChannel::ConverterChannel(ConversionController& controller,
                                   ProgressSender progress_sender)
    : controller_(controller),
      state_(std::make_shared<State>(std::move(progress_sender))) {}

ConverterChannel::~ConverterChannel() { Shutdown(); }

void ConverterChannel::Handle(std::string_view method,
                              const flutter::EncodableValue* arguments,
                              std::unique_ptr<FlutterResult> result) {
  if (!result) {
    return;
  }
  if (method == "cancelConvert") {
    controller_.Cancel();
    result->Success();
    return;
  }
  if (!IsConverterMethod(method)) {
    result->NotImplemented();
    return;
  }

  auto parsed = ParseConverterRequest(method, arguments);
  if (!parsed.ok()) {
    result->Error(std::string(FlutterErrorCode(parsed.error->status)),
                  parsed.error->message);
    return;
  }

  auto retained = std::shared_ptr<FlutterResult>(std::move(result));
  auto progress_state = std::make_shared<ProgressState>();
  const std::weak_ptr<State> weak_state = state_;
  auto started = controller_.Start(
      std::move(*parsed.value),
      [weak_state, progress_state](uint32_t done, uint32_t total) {
        auto state = weak_state.lock();
        if (!state) {
          return;
        }
        ProgressSender sender;
        {
          std::lock_guard<std::mutex> lifecycle_lock(state->mutex);
          if (!state->alive) {
            return;
          }
          sender = state->progress_sender;
        }
        {
          std::lock_guard<std::mutex> progress_lock(progress_state->mutex);
          if (progress_state->terminal ||
              (progress_state->seen &&
               (done < progress_state->done ||
                total != progress_state->total))) {
            return;
          }
          progress_state->seen = true;
          progress_state->done = done;
          progress_state->total = total;
        }
        if (sender) {
          sender(done, total);
        }
      },
      [weak_state, progress_state,
       retained](Result<MediaJobResult> completed) mutable {
        {
          std::lock_guard<std::mutex> progress_lock(progress_state->mutex);
          progress_state->terminal = true;
        }
        auto state = weak_state.lock();
        if (!state) {
          return;
        }
        {
          std::lock_guard<std::mutex> lifecycle_lock(state->mutex);
          if (!state->alive) {
            return;
          }
        }
        CompleteConverterResult(retained, std::move(completed));
      });
  if (!started.ok()) {
    {
      std::lock_guard<std::mutex> progress_lock(progress_state->mutex);
      progress_state->terminal = true;
    }
    CompleteFlutterError(retained, *started.error);
  }
}

void ConverterChannel::Shutdown() {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->alive = false;
    state_->progress_sender = {};
  }
  controller_.Shutdown();
}

}  // namespace hmw
