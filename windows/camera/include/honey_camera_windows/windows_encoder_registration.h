#pragma once

#include "honey_camera_windows/encoder_channel.h"
#include "honey_media_windows/platform_dispatcher.h"

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>

#include <functional>
#include <memory>
#include <string_view>

namespace hcw {

using EncoderMethodForwarder = std::function<void(
    std::string_view method, const flutter::EncodableValue* arguments,
    std::unique_ptr<hmw::FlutterResult> result)>;

class WindowsEncoderRegistration final {
 public:
  static constexpr std::string_view kMethodChannelName = "ebadge/encoder";
  static constexpr std::string_view kEventChannelName =
      "ebadge/encoder/events";

  WindowsEncoderRegistration(flutter::BinaryMessenger& messenger,
                             hmw::PlatformDispatcher& dispatcher,
                             EncoderMethodForwarder method_forwarder);
  ~WindowsEncoderRegistration();

  WindowsEncoderRegistration(const WindowsEncoderRegistration&) = delete;
  WindowsEncoderRegistration& operator=(const WindowsEncoderRegistration&) =
      delete;

  void SendEvent(flutter::EncodableValue event);
  void Shutdown();

 private:
  struct State;
  class Channels;

  std::shared_ptr<State> state_;
  std::unique_ptr<Channels> channels_;
};

}  // namespace hcw
