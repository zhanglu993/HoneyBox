#pragma once

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>

#include <memory>
#include <string_view>

#include "honey_media_windows/bluetooth_link.h"

namespace hmw {

using FlutterResult = flutter::MethodResult<flutter::EncodableValue>;

/// Serves `ebadge/ble_link`: lets Dart ask Windows for a throughput-optimized
/// LE connection interval while projection is running.
class BluetoothLinkChannel final {
 public:
  explicit BluetoothLinkChannel(std::unique_ptr<BluetoothLinkTuner> tuner);
  ~BluetoothLinkChannel();

  BluetoothLinkChannel(const BluetoothLinkChannel&) = delete;
  BluetoothLinkChannel& operator=(const BluetoothLinkChannel&) = delete;

  void Handle(std::string_view method,
              const flutter::EncodableValue* arguments,
              std::unique_ptr<FlutterResult> result);
  void Shutdown();

 private:
  std::unique_ptr<BluetoothLinkTuner> tuner_;
};

}  // namespace hmw
