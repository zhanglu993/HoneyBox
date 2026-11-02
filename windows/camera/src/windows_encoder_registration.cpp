#include "honey_camera_windows/windows_encoder_registration.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <exception>
#include <mutex>
#include <string>
#include <utility>

namespace hcw {

struct WindowsEncoderRegistration::State {
  State(hmw::PlatformDispatcher& platform_dispatcher,
        EncoderMethodForwarder forwarder)
      : dispatcher(platform_dispatcher),
        method_forwarder(std::move(forwarder)) {}

  hmw::PlatformDispatcher& dispatcher;
  std::mutex mutex;
  bool active = true;
  uint64_t sink_generation = 0;
  EncoderMethodForwarder method_forwarder;
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink;
};

class WindowsEncoderRegistration::Channels {
 public:
  Channels(flutter::BinaryMessenger& messenger,
           const std::shared_ptr<State>& state)
      : method_channel(&messenger, std::string(kMethodChannelName),
                       &flutter::StandardMethodCodec::GetInstance()),
        event_channel(&messenger, std::string(kEventChannelName),
                      &flutter::StandardMethodCodec::GetInstance()) {
    const std::weak_ptr<State> weak_state = state;
    method_channel.SetMethodCallHandler(
        [weak_state](
            const flutter::MethodCall<flutter::EncodableValue>& call,
            std::unique_ptr<hmw::FlutterResult> result) {
          const std::shared_ptr<State> current = weak_state.lock();
          EncoderMethodForwarder forwarder;
          if (current) {
            std::lock_guard<std::mutex> lock(current->mutex);
            if (current->active) {
              forwarder = current->method_forwarder;
            }
          }
          if (!forwarder) {
            result->NotImplemented();
            return;
          }
          forwarder(call.method_name(), call.arguments(), std::move(result));
        });

    event_channel.SetStreamHandler(std::make_unique<
        flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
        [weak_state](
            const flutter::EncodableValue*,
            std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                sink)
            -> std::unique_ptr<
                flutter::StreamHandlerError<flutter::EncodableValue>> {
          const std::shared_ptr<State> current = weak_state.lock();
          if (!current) {
            return std::make_unique<
                flutter::StreamHandlerError<flutter::EncodableValue>>(
                "invalid_state", "encoder registration is unavailable",
                nullptr);
          }
          std::lock_guard<std::mutex> lock(current->mutex);
          if (!current->active) {
            return std::make_unique<
                flutter::StreamHandlerError<flutter::EncodableValue>>(
                "invalid_state", "encoder registration is shut down",
                nullptr);
          }
          ++current->sink_generation;
          current->sink =
              std::shared_ptr<flutter::EventSink<flutter::EncodableValue>>(
                  std::move(sink));
          return nullptr;
        },
        [weak_state](const flutter::EncodableValue*)
            -> std::unique_ptr<
                flutter::StreamHandlerError<flutter::EncodableValue>> {
          const std::shared_ptr<State> current = weak_state.lock();
          if (!current) {
            return nullptr;
          }
          std::lock_guard<std::mutex> lock(current->mutex);
          ++current->sink_generation;
          current->sink.reset();
          return nullptr;
        }));
  }

  void Detach() {
    event_channel.SetStreamHandler(nullptr);
    method_channel.SetMethodCallHandler(nullptr);
  }

  flutter::MethodChannel<flutter::EncodableValue> method_channel;
  flutter::EventChannel<flutter::EncodableValue> event_channel;
};

WindowsEncoderRegistration::WindowsEncoderRegistration(
    flutter::BinaryMessenger& messenger, hmw::PlatformDispatcher& dispatcher,
    EncoderMethodForwarder method_forwarder)
    : state_(std::make_shared<State>(dispatcher, std::move(method_forwarder))),
      channels_(std::make_unique<Channels>(messenger, state_)) {}

WindowsEncoderRegistration::~WindowsEncoderRegistration() { Shutdown(); }

void WindowsEncoderRegistration::SendEvent(flutter::EncodableValue event) {
  uint64_t generation = 0;
  hmw::PlatformDispatcher* dispatcher = nullptr;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->active || !state_->sink) {
      return;
    }
    generation = state_->sink_generation;
    dispatcher = &state_->dispatcher;
  }

  const std::weak_ptr<State> weak_state = state_;
  (void)dispatcher->Post(
      [weak_state, generation, event = std::move(event)]() mutable {
        const std::shared_ptr<State> current = weak_state.lock();
        if (!current) {
          return;
        }
        std::lock_guard<std::mutex> lock(current->mutex);
        if (!current->active || current->sink_generation != generation ||
            !current->sink) {
          return;
        }
        try {
          current->sink->Success(event);
        } catch (const std::exception&) {
        } catch (...) {
        }
      });
}

void WindowsEncoderRegistration::Shutdown() {
  bool detach = false;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->active) {
      state_->active = false;
      ++state_->sink_generation;
      state_->sink.reset();
      state_->method_forwarder = {};
      detach = true;
    }
  }
  if (detach && channels_) {
    channels_->Detach();
  }
}

}  // namespace hcw
