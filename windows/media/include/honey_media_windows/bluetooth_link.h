#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>

#include "honey_media_windows/status.h"

namespace hmw {

/// Parses a `AA:BB:CC:DD:EE:FF` BLE address into a 48-bit value.
/// Returns false for anything that is not exactly six hex octets.
bool ParseBluetoothAddress(std::string_view text, uint64_t* address);

/// Holds Windows LE connection-parameter preferences for connected devices.
///
/// Windows defaults an LE link to its "balanced" profile (30-60 ms connection
/// interval), which caps a projection stream at roughly 30 kbps. The
/// throughput-optimized profile asks for a fixed 15 ms interval. The preference
/// only lasts while the request object is held, so this owner keeps one per
/// device until the link is released.
///
/// All Windows Runtime work happens on a private worker thread; the Flutter
/// platform thread never blocks on Bluetooth.
class BluetoothLinkTuner {
 public:
  static std::unique_ptr<BluetoothLinkTuner> Create();

  virtual ~BluetoothLinkTuner() = default;

  /// Requests the throughput-optimized profile for [address]. Replaces any
  /// request already held for that device.
  virtual Outcome RequestThroughput(uint64_t address) = 0;

  /// Drops the request for [address], returning the link to system defaults.
  virtual void Release(uint64_t address) = 0;

  /// Drops every request and stops the worker.
  virtual void Shutdown() = 0;
};

}  // namespace hmw
