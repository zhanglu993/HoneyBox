#pragma once

#include "honey_media_windows/conversion_controller.h"

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <flutter_windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string_view>

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
