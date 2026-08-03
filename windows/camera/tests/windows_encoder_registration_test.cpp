#include "honey_camera_windows/windows_encoder_registration.h"

#include "honey_media_windows/platform_dispatcher.h"
#include "test_support.h"

#include <flutter/binary_messenger.h>
#include <flutter/engine_method_result.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace flutter::internal {

ReplyManager::ReplyManager(BinaryReply reply_handler)
    : reply_handler_(std::move(reply_handler)) {}

ReplyManager::~ReplyManager() = default;

void ReplyManager::SendResponseData(const std::vector<uint8_t>* data) {
  if (!reply_handler_) {
    return;
  }
  BinaryReply reply = std::move(reply_handler_);
  if (data == nullptr || data->empty()) {
    reply(nullptr, 0);
    return;
  }
  reply(data->data(), data->size());
}

}  // namespace flutter::internal

namespace {

class FakeDispatcher final : public hmw::PlatformDispatcher {
 public:
  bool Post(std::function<void()> callback) override {
    if (!accept_posts) {
      return false;
    }
    callbacks.push_back(std::move(callback));
    return true;
  }

  void RunAll() {
    std::vector<std::function<void()>> pending;
    pending.swap(callbacks);
    for (auto& callback : pending) {
      callback();
    }
  }

  bool accept_posts = true;
  std::vector<std::function<void()>> callbacks;
};

class FakeMessenger final : public flutter::BinaryMessenger {
 public:
  struct SentMessage {
    std::string channel;
    std::vector<uint8_t> bytes;
  };

  void Send(const std::string& channel, const uint8_t* message,
            size_t message_size,
            flutter::BinaryReply reply = nullptr) const override {
    SentMessage sent{channel, {}};
    if (message != nullptr && message_size != 0) {
      sent.bytes.assign(message, message + message_size);
    }
    sent_messages.push_back(std::move(sent));
    if (reply) {
      reply(nullptr, 0);
    }
  }

  void SetMessageHandler(const std::string& channel,
                         flutter::BinaryMessageHandler handler) override {
    ++set_counts[channel];
    if (handler) {
      handlers[channel] = std::move(handler);
    } else {
      handlers.erase(channel);
    }
  }

  std::vector<uint8_t> Invoke(
      const std::string& channel,
      const flutter::MethodCall<flutter::EncodableValue>& call) {
    const auto encoded =
        flutter::StandardMethodCodec::GetInstance().EncodeMethodCall(call);
    std::vector<uint8_t> reply;
    handlers.at(channel)(encoded->data(), encoded->size(),
                         [&reply](const uint8_t* bytes, size_t size) {
                           if (bytes != nullptr && size != 0) {
                             reply.assign(bytes, bytes + size);
                           }
                         });
    return reply;
  }

  mutable std::vector<SentMessage> sent_messages;
  std::map<std::string, flutter::BinaryMessageHandler> handlers;
  std::map<std::string, size_t> set_counts;
};

class CapturingResult final
    : public flutter::MethodResult<flutter::EncodableValue> {
 public:
  bool success = false;
  std::optional<flutter::EncodableValue> value;

 protected:
  void SuccessInternal(const flutter::EncodableValue* result) override {
    success = true;
    if (result != nullptr) {
      value = *result;
    }
  }

  void ErrorInternal(const std::string&, const std::string&,
                     const flutter::EncodableValue*) override {}
  void NotImplementedInternal() override {}
};

flutter::EncodableValue Event(std::string name) {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("event"),
       flutter::EncodableValue(std::move(name))},
  });
}

std::string DecodeEventName(const FakeMessenger::SentMessage& sent) {
  CapturingResult result;
  const bool decoded = flutter::StandardMethodCodec::GetInstance()
                           .DecodeAndProcessResponseEnvelope(
                               sent.bytes.data(), sent.bytes.size(), &result);
  if (!decoded || !result.success || !result.value) {
    return {};
  }
  const auto* map = std::get_if<flutter::EncodableMap>(&*result.value);
  if (map == nullptr) {
    return {};
  }
  const auto found = map->find(flutter::EncodableValue("event"));
  if (found == map->end()) {
    return {};
  }
  const auto* name = std::get_if<std::string>(&found->second);
  return name == nullptr ? std::string{} : *name;
}

std::string ReadProjectFile(std::string_view relative_path) {
  std::ifstream input(std::string(HMW_PROJECT_SOURCE_DIR) + "/" +
                      std::string(relative_path));
  std::ostringstream contents;
  contents << input.rdbuf();
  return contents.str();
}

bool AppearsInOrder(const std::string& source,
                    const std::vector<std::string_view>& needles) {
  size_t offset = 0;
  for (const std::string_view needle : needles) {
    const size_t found = source.find(needle, offset);
    if (found == std::string::npos) {
      return false;
    }
    offset = found + needle.size();
  }
  return true;
}

}  // namespace

HMW_TEST(
    windows_encoder_registration_registers_android_compatible_channels_and_forwards_methods) {
  FakeMessenger messenger;
  FakeDispatcher dispatcher;
  std::string forwarded_method;
  size_t forwarded_count = 0;
  hcw::WindowsEncoderRegistration registration(
      messenger, dispatcher,
      [&forwarded_method, &forwarded_count](
          std::string_view method, const flutter::EncodableValue*,
          std::unique_ptr<hmw::FlutterResult> result) {
        forwarded_method = std::string(method);
        ++forwarded_count;
        result->Success();
      });

  HMW_EXPECT(messenger.handlers.count("ebadge/encoder") == 1);
  HMW_EXPECT(messenger.handlers.count("ebadge/encoder/events") == 1);

  const auto reply = messenger.Invoke(
      "ebadge/encoder",
      flutter::MethodCall<flutter::EncodableValue>("closeCamera", nullptr));
  HMW_EXPECT(!reply.empty());
  HMW_EXPECT(forwarded_method == "closeCamera");
  HMW_EXPECT(forwarded_count == 1);
}

HMW_TEST(
    windows_encoder_registration_listen_cancel_and_generation_gate_events) {
  FakeMessenger messenger;
  FakeDispatcher dispatcher;
  hcw::WindowsEncoderRegistration registration(
      messenger, dispatcher,
      [](std::string_view, const flutter::EncodableValue*,
         std::unique_ptr<hmw::FlutterResult> result) { result->Success(); });

  messenger.Invoke(
      "ebadge/encoder/events",
      flutter::MethodCall<flutter::EncodableValue>("listen", nullptr));
  registration.SendEvent(Event("camera"));
  dispatcher.RunAll();
  HMW_EXPECT(messenger.sent_messages.size() == 1);
  HMW_EXPECT(messenger.sent_messages[0].channel == "ebadge/encoder/events");
  HMW_EXPECT(DecodeEventName(messenger.sent_messages[0]) == "camera");

  registration.SendEvent(Event("error"));
  messenger.Invoke(
      "ebadge/encoder/events",
      flutter::MethodCall<flutter::EncodableValue>("cancel", nullptr));
  dispatcher.RunAll();
  HMW_EXPECT(messenger.sent_messages.size() == 1);

  messenger.Invoke(
      "ebadge/encoder/events",
      flutter::MethodCall<flutter::EncodableValue>("listen", nullptr));
  registration.SendEvent(Event("error"));
  dispatcher.RunAll();
  HMW_EXPECT(messenger.sent_messages.size() == 2);
  HMW_EXPECT(DecodeEventName(messenger.sent_messages[1]) == "error");
}

HMW_TEST(
    windows_encoder_registration_shutdown_is_idempotent_and_suppresses_queued_events) {
  FakeMessenger messenger;
  FakeDispatcher dispatcher;
  {
    hcw::WindowsEncoderRegistration registration(
        messenger, dispatcher,
        [](std::string_view, const flutter::EncodableValue*,
           std::unique_ptr<hmw::FlutterResult> result) { result->Success(); });
    messenger.Invoke(
        "ebadge/encoder/events",
        flutter::MethodCall<flutter::EncodableValue>("listen", nullptr));
    registration.SendEvent(Event("camera"));
    registration.Shutdown();
    registration.Shutdown();
    dispatcher.RunAll();
    HMW_EXPECT(messenger.sent_messages.empty());
    HMW_EXPECT(messenger.handlers.count("ebadge/encoder") == 0);
    HMW_EXPECT(messenger.handlers.count("ebadge/encoder/events") == 0);
  }

  HMW_EXPECT(messenger.set_counts["ebadge/encoder"] == 2);
  HMW_EXPECT(messenger.set_counts["ebadge/encoder/events"] == 2);
}

HMW_TEST(windows_encoder_registration_rejects_post_without_leaking_an_event) {
  FakeMessenger messenger;
  FakeDispatcher dispatcher;
  dispatcher.accept_posts = false;
  hcw::WindowsEncoderRegistration registration(
      messenger, dispatcher,
      [](std::string_view, const flutter::EncodableValue*,
         std::unique_ptr<hmw::FlutterResult> result) { result->Success(); });

  messenger.Invoke(
      "ebadge/encoder/events",
      flutter::MethodCall<flutter::EncodableValue>("listen", nullptr));
  registration.SendEvent(Event("error"));
  dispatcher.RunAll();
  HMW_EXPECT(messenger.sent_messages.empty());
}

HMW_TEST(
    windows_encoder_registration_plugin_uses_the_existing_registrar_path) {
  const std::string source =
      ReadProjectFile("windows/media/src/windows_media_plugin.cpp");
  HMW_EXPECT(!source.empty());
  HMW_EXPECT(source.find("CameraTextureCleanupCoordinator::Create") !=
             std::string::npos);
  HMW_EXPECT(source.find("CreateMediaFoundationCameraFactory") !=
             std::string::npos);
  HMW_EXPECT(source.find("WindowsEncoderRegistration") != std::string::npos);
  const std::string registrar =
      "HoneyMediaWindowsPluginRegisterWithRegistrar";
  const size_t first = source.find(registrar);
  HMW_EXPECT(first != std::string::npos);
  HMW_EXPECT(source.find(registrar, first + registrar.size()) ==
             std::string::npos);
}

HMW_TEST(
    windows_encoder_registration_plugin_tears_down_camera_before_existing_media) {
  const std::string source =
      ReadProjectFile("windows/media/src/windows_media_plugin.cpp");
  HMW_EXPECT(AppearsInOrder(
      source,
      {"encoder_registration_->Shutdown()",
       "encoder_channel_->Shutdown()",
       "encoder_channel_.reset()",
       "camera_controller_.reset()",
       "camera_cleanup_->Shutdown()", "player_channel_.Shutdown()",
       "converter_channel_.Shutdown()"}));
}

HMW_TEST(windows_encoder_registration_leaves_generated_files_camera_free) {
  const std::string registrant =
      ReadProjectFile("windows/flutter/generated_plugin_registrant.cc");
  const std::string generated_cmake =
      ReadProjectFile("windows/flutter/generated_plugins.cmake");
  HMW_EXPECT(!registrant.empty());
  HMW_EXPECT(!generated_cmake.empty());
  HMW_EXPECT(registrant.find("ebadge/encoder") == std::string::npos);
  HMW_EXPECT(registrant.find("WindowsEncoderRegistration") ==
             std::string::npos);
  HMW_EXPECT(generated_cmake.find("honey_camera_windows") ==
             std::string::npos);
}
