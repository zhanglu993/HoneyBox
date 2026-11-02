#include "honey_media_windows/bluetooth_link.h"

#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Foundation.h>

#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <thread>
#include <utility>

namespace hmw {
namespace {

namespace bt = winrt::Windows::Devices::Bluetooth;

Error LinkError(Status status, std::string message) {
  return {status, std::move(message)};
}

// Owns every Windows Runtime call on one worker thread. Bluetooth calls block,
// and the Flutter platform thread must never wait on the radio.
class WinrtBluetoothLinkTuner final : public BluetoothLinkTuner {
 public:
  WinrtBluetoothLinkTuner() {
    worker_ = std::thread([this] { Run(); });
  }

  ~WinrtBluetoothLinkTuner() override { Shutdown(); }

  Outcome RequestThroughput(uint64_t address) override {
    if (address == 0U) {
      return {LinkError(Status::kInvalidArgument,
                        "Bluetooth address must not be zero")};
    }
    if (!Post([this, address] { AcquireOnWorker(address); })) {
      return {LinkError(Status::kInvalidState,
                        "Bluetooth link tuner is shut down")};
    }
    return {};
  }

  void Release(uint64_t address) override {
    (void)Post([this, address] { ReleaseOnWorker(address); });
  }

  void Shutdown() override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!running_) return;
      running_ = false;
      condition_.notify_all();
    }
    if (worker_.joinable()) worker_.join();
  }

 private:
  bool Post(std::function<void()> work) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_) return false;
    pending_.push_back(std::move(work));
    condition_.notify_all();
    return true;
  }

  void Run() noexcept {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    for (;;) {
      std::function<void()> work;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        condition_.wait(lock, [this] { return !running_ || !pending_.empty(); });
        if (!running_ && pending_.empty()) break;
        work = std::move(pending_.front());
        pending_.pop_front();
      }
      try {
        work();
      } catch (...) {
      }
    }
    ReleaseAllOnWorker();
    winrt::uninit_apartment();
  }

  void AcquireOnWorker(uint64_t address) {
    // Replacing an existing request keeps at most one per device.
    ReleaseOnWorker(address);
    auto device = bt::BluetoothLEDevice::FromBluetoothAddressAsync(address).get();
    if (device == nullptr) return;
    // The preference lasts exactly as long as the returned request is held.
    auto request = device.RequestPreferredConnectionParameters(
        bt::BluetoothLEPreferredConnectionParameters::ThroughputOptimized());
    if (auto closable =
            request.try_as<winrt::Windows::Foundation::IClosable>()) {
      held_.emplace(address, std::move(closable));
    }
  }

  void ReleaseOnWorker(uint64_t address) {
    const auto found = held_.find(address);
    if (found == held_.end()) return;
    try {
      found->second.Close();
    } catch (...) {
    }
    held_.erase(found);
  }

  void ReleaseAllOnWorker() noexcept {
    for (auto& entry : held_) {
      try {
        entry.second.Close();
      } catch (...) {
      }
    }
    held_.clear();
  }

  std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<std::function<void()>> pending_;
  bool running_ = true;
  std::thread worker_;
  // Worker-thread only.
  std::map<uint64_t, winrt::Windows::Foundation::IClosable> held_;
};

}  // namespace

std::unique_ptr<BluetoothLinkTuner> BluetoothLinkTuner::Create() {
  return std::make_unique<WinrtBluetoothLinkTuner>();
}

}  // namespace hmw
