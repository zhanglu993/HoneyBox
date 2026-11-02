#pragma once

#include "honey_media_windows/conversion_controller.h"
#include "honey_media_windows/media_source.h"
#include "honey_media_windows/texture_registry.h"

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <flutter_windows.h>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <string_view>

namespace flutter {
class TextureRegistrar;
}

namespace hmw {

using FlutterResult = flutter::MethodResult<flutter::EncodableValue>;
using ProgressSender = std::function<void(uint32_t done, uint32_t total)>;

void CompleteFlutterError(const std::shared_ptr<FlutterResult>& result,
                          const Error& error);
void CompleteConverterResult(const std::shared_ptr<FlutterResult>& result,
                             Result<MediaJobResult> completed);

class ConverterChannel final {
 public:
  ConverterChannel(ConversionController& controller,
                   ProgressSender progress_sender);
  ~ConverterChannel();

  ConverterChannel(const ConverterChannel&) = delete;
  ConverterChannel& operator=(const ConverterChannel&) = delete;

  void Handle(std::string_view method,
              const flutter::EncodableValue* arguments,
              std::unique_ptr<FlutterResult> result);
  void Shutdown();

 private:
  struct State;

  ConversionController& controller_;
  std::shared_ptr<State> state_;
};

}  // namespace hmw

void HoneyMediaWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

namespace hmw {
using PlayerSourceOpener = std::function<
    Result<std::unique_ptr<FrameSource>>(const std::filesystem::path&)>;
using PlayerOperationGate = std::function<void()>;

class PlayerChannel final {
 public:
  PlayerChannel(TextureRegistry& texture_registry,
                PlatformDispatcher& dispatcher,
                PlayerSourceOpener source_opener = OpenMediaSource,
                PlayerOperationGate operation_gate = {});
  ~PlayerChannel();

  PlayerChannel(const PlayerChannel&) = delete;
  PlayerChannel& operator=(const PlayerChannel&) = delete;

  void Handle(std::string_view method,
              const flutter::EncodableValue* arguments,
              std::unique_ptr<FlutterResult> result);
  void Shutdown();

 private:
  struct State;
  std::unique_ptr<State> state_;
};

std::unique_ptr<TextureRegistry> CreateFlutterTextureRegistry(
    flutter::TextureRegistrar* registrar);


}  // namespace hmw
