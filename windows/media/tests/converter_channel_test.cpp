#include "test_support.h"

#include "honey_media_windows/windows_media_plugin.h"

#include <flutter/encodable_value.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

class QueueDispatcher final : public hmw::PlatformDispatcher {
 public:
  bool Post(std::function<void()> callback) override {
    std::lock_guard<std::mutex> lock(mutex_);
    callbacks_.push_back(std::move(callback));
    condition_.notify_all();
    return true;
  }

  bool WaitForPending() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 10s,
                               [&] { return !callbacks_.empty(); });
  }

  void Drain() {
    for (;;) {
      std::function<void()> callback;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (callbacks_.empty()) {
          return;
        }
        callback = std::move(callbacks_.front());
        callbacks_.pop_front();
      }
      callback();
    }
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<std::function<void()>> callbacks_;
};

struct ResultCapture {
  std::mutex mutex;
  uint32_t successes = 0;
  uint32_t errors = 0;
  uint32_t not_implemented = 0;
  std::string error_code;
};

class CapturingResult final : public hmw::FlutterResult {
 public:
  explicit CapturingResult(std::shared_ptr<ResultCapture> capture)
      : capture_(std::move(capture)) {}

 protected:
  void SuccessInternal(const EncodableValue*) override {
    std::lock_guard<std::mutex> lock(capture_->mutex);
    ++capture_->successes;
  }

  void ErrorInternal(const std::string& error_code,
                     const std::string&,
                     const EncodableValue*) override {
    std::lock_guard<std::mutex> lock(capture_->mutex);
    ++capture_->errors;
    capture_->error_code = error_code;
  }

  void NotImplementedInternal() override {
    std::lock_guard<std::mutex> lock(capture_->mutex);
    ++capture_->not_implemented;
  }

 private:
  std::shared_ptr<ResultCapture> capture_;
};

std::unique_ptr<hmw::FlutterResult> ResultFor(
    const std::shared_ptr<ResultCapture>& capture) {
  return std::make_unique<CapturingResult>(capture);
}

EncodableValue SlowSlideshowArguments() {
  constexpr int32_t kSize = 360;
  return EncodableValue(EncodableMap{
      {EncodableValue("frames"),
       EncodableValue(EncodableList{EncodableValue(
           std::vector<uint8_t>(static_cast<size_t>(kSize) * kSize * 4U,
                                uint8_t{127}))})},
      {EncodableValue("holds"),
       EncodableValue(EncodableList{EncodableValue(int32_t{300})})},
      {EncodableValue("size"), EncodableValue(kSize)},
  });
}

uint32_t TotalCalls(const std::shared_ptr<ResultCapture>& capture) {
  std::lock_guard<std::mutex> lock(capture->mutex);
  return capture->successes + capture->errors + capture->not_implemented;
}

HMW_TEST(cancel_convert_targets_active_generation) {
  QueueDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  hmw::ConverterChannel channel(controller, [](uint32_t, uint32_t) {});
  auto conversion = std::make_shared<ResultCapture>();
  auto arguments = SlowSlideshowArguments();
  channel.Handle("encodeFrames", &arguments, ResultFor(conversion));

  auto cancel = std::make_shared<ResultCapture>();
  channel.Handle("cancelConvert", nullptr, ResultFor(cancel));
  HMW_EXPECT(TotalCalls(cancel) == 1);
  {
    std::lock_guard<std::mutex> lock(cancel->mutex);
    HMW_EXPECT(cancel->successes == 1);
  }

  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();
  {
    std::lock_guard<std::mutex> lock(conversion->mutex);
    HMW_EXPECT(conversion->successes == 0);
    HMW_EXPECT(conversion->errors == 1);
    HMW_EXPECT(conversion->error_code == "cancelled");
  }
}

HMW_TEST(channel_drops_completion_after_plugin_shutdown) {
  QueueDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  hmw::ConverterChannel channel(controller, [](uint32_t, uint32_t) {});
  auto conversion = std::make_shared<ResultCapture>();
  auto arguments = SlowSlideshowArguments();
  channel.Handle("encodeFrames", &arguments, ResultFor(conversion));

  channel.Shutdown();
  dispatcher.Drain();

  HMW_EXPECT(TotalCalls(conversion) == 0);
}

}  // namespace
