#include "test_support.h"

#include "honey_media_windows/windows_media_plugin.h"

#include <flutter/encodable_value.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

class ContractQueueDispatcher final : public hmw::PlatformDispatcher {
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

class ContractBlockingDispatcher final : public hmw::PlatformDispatcher {
 public:
  bool Post(std::function<void()> callback) override {
    std::unique_lock<std::mutex> lock(mutex_);
    entered_ = true;
    condition_.notify_all();
    condition_.wait(lock, [&] { return released_; });
    callbacks_.push_back(std::move(callback));
    return true;
  }

  bool WaitUntilEntered() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 10s, [&] { return entered_; });
  }

  void Release() {
    std::lock_guard<std::mutex> lock(mutex_);
    released_ = true;
    condition_.notify_all();
  }

  void Drain() {
    std::deque<std::function<void()>> callbacks;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      callbacks.swap(callbacks_);
    }
    for (auto& callback : callbacks) {
      callback();
    }
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<std::function<void()>> callbacks_;
  bool entered_ = false;
  bool released_ = false;
};

struct ContractCapture {
  std::mutex mutex;
  uint32_t successes = 0;
  uint32_t errors = 0;
  uint32_t not_implemented = 0;
  std::string error_code;
  std::optional<EncodableValue> value;
  std::thread::id callback_thread;
};

class ContractResult final : public hmw::FlutterResult {
 public:
  explicit ContractResult(std::shared_ptr<ContractCapture> capture)
      : capture_(std::move(capture)) {}

 protected:
  void SuccessInternal(const EncodableValue* result) override {
    std::lock_guard<std::mutex> lock(capture_->mutex);
    ++capture_->successes;
    if (result != nullptr) {
      capture_->value = *result;
    }
    capture_->callback_thread = std::this_thread::get_id();
  }

  void ErrorInternal(const std::string& error_code, const std::string&,
                     const EncodableValue*) override {
    std::lock_guard<std::mutex> lock(capture_->mutex);
    ++capture_->errors;
    capture_->error_code = error_code;
    capture_->callback_thread = std::this_thread::get_id();
  }

  void NotImplementedInternal() override {
    std::lock_guard<std::mutex> lock(capture_->mutex);
    ++capture_->not_implemented;
    capture_->callback_thread = std::this_thread::get_id();
  }

 private:
  std::shared_ptr<ContractCapture> capture_;
};

std::unique_ptr<hmw::FlutterResult> ContractResultFor(
    const std::shared_ptr<ContractCapture>& capture) {
  return std::make_unique<ContractResult>(capture);
}

uint32_t ContractTotalCalls(
    const std::shared_ptr<ContractCapture>& capture) {
  std::lock_guard<std::mutex> lock(capture->mutex);
  return capture->successes + capture->errors + capture->not_implemented;
}

bool PumpUntil(ContractQueueDispatcher& dispatcher,
               const std::shared_ptr<ContractCapture>& capture) {
  const auto deadline = std::chrono::steady_clock::now() + 10s;
  while (ContractTotalCalls(capture) == 0 &&
         std::chrono::steady_clock::now() < deadline) {
    if (dispatcher.WaitForPending()) {
      dispatcher.Drain();
    }
  }
  return ContractTotalCalls(capture) != 0;
}

std::filesystem::path ContractFixturePath(const char* relative) {
  return std::filesystem::path(HMW_PROJECT_SOURCE_DIR) / relative;
}

std::vector<std::pair<std::string, EncodableValue>> AllJobArguments() {
  const auto gif = ContractFixturePath(
      "windows/media/tests/fixtures/animated_disposal.gif");
  const auto avi =
      ContractFixturePath("media_core/tests/fixtures/cvid_sample.avi");
  std::vector<std::pair<std::string, EncodableValue>> jobs;
  jobs.emplace_back(
      "getVideoThumbnail",
      EncodableValue(EncodableMap{
          {EncodableValue("path"), EncodableValue(gif.string())}}));
  jobs.emplace_back(
      "previewFrames",
      EncodableValue(EncodableMap{
          {EncodableValue("path"), EncodableValue(gif.string())},
          {EncodableValue("maxCount"), EncodableValue(int32_t{1})},
          {EncodableValue("maxEdge"), EncodableValue(int32_t{4})}}));
  jobs.emplace_back(
      "decodeCvid",
      EncodableValue(EncodableMap{
          {EncodableValue("path"), EncodableValue(avi.string())},
          {EncodableValue("maxCount"), EncodableValue(int32_t{1})},
          {EncodableValue("maxEdge"), EncodableValue(int32_t{4})}}));
  jobs.emplace_back(
      "convertVideo",
      EncodableValue(EncodableMap{
          {EncodableValue("path"), EncodableValue(gif.string())},
          {EncodableValue("width"), EncodableValue(int32_t{4})},
          {EncodableValue("height"), EncodableValue(int32_t{4})},
          {EncodableValue("maxFrames"), EncodableValue(int32_t{1})}}));
  jobs.emplace_back(
      "encodeFrames",
      EncodableValue(EncodableMap{
          {EncodableValue("frames"),
           EncodableValue(EncodableList{EncodableValue(
               std::vector<uint8_t>(4U * 4U * 4U, uint8_t{127}))})},
          {EncodableValue("holds"),
           EncodableValue(EncodableList{EncodableValue(int32_t{1})})},
          {EncodableValue("size"), EncodableValue(int32_t{4})}}));
  jobs.emplace_back(
      "encodeScroll",
      EncodableValue(EncodableMap{
          {EncodableValue("strip"),
           EncodableValue(std::vector<uint8_t>(4U * 4U * 4U,
                                                uint8_t{127}))},
          {EncodableValue("stripW"), EncodableValue(int32_t{4})},
          {EncodableValue("stripH"), EncodableValue(int32_t{4})},
          {EncodableValue("size"), EncodableValue(int32_t{4})},
          {EncodableValue("gap"), EncodableValue(int32_t{0})},
          {EncodableValue("maxFrames"), EncodableValue(int32_t{1})}}));
  return jobs;
}

EncodableValue ContractSlowSlideshowArguments() {
  constexpr int32_t kSize = 360;
  return EncodableValue(EncodableMap{
      {EncodableValue("frames"),
       EncodableValue(EncodableList{EncodableValue(
           std::vector<uint8_t>(static_cast<size_t>(kSize) * kSize * 4U,
                                uint8_t{127}))})},
      {EncodableValue("holds"),
       EncodableValue(EncodableList{EncodableValue(int32_t{300})})},
      {EncodableValue("size"), EncodableValue(kSize)}});
}

HMW_TEST(every_non_cancel_converter_method_runs_through_controller) {
  ContractQueueDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  std::vector<std::pair<uint32_t, uint32_t>> progress;
  hmw::ConverterChannel channel(
      controller, [&](uint32_t done, uint32_t total) {
        progress.emplace_back(done, total);
      });
  const std::thread::id platform_thread = std::this_thread::get_id();

  for (auto& [method, arguments] : AllJobArguments()) {
    progress.clear();
    auto capture = std::make_shared<ContractCapture>();
    channel.Handle(method, &arguments, ContractResultFor(capture));
    HMW_EXPECT(PumpUntil(dispatcher, capture));
    HMW_EXPECT(ContractTotalCalls(capture) == 1);
    {
      std::lock_guard<std::mutex> lock(capture->mutex);
      HMW_EXPECT(capture->successes == 1);
      HMW_EXPECT(capture->value.has_value());
      HMW_EXPECT(capture->callback_thread == platform_thread);
    }
    for (size_t index = 1; index < progress.size(); ++index) {
      HMW_EXPECT(progress[index].first >= progress[index - 1].first);
      HMW_EXPECT(progress[index].second == progress[0].second);
    }
    if (!progress.empty()) {
      HMW_EXPECT(progress.back().first == progress.back().second);
    }
  }
}

HMW_TEST(channel_maps_busy_and_invalid_state_exactly_once) {
  ContractBlockingDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  hmw::ConverterChannel channel(controller, [](uint32_t, uint32_t) {});
  auto first = std::make_shared<ContractCapture>();
  auto arguments = ContractSlowSlideshowArguments();
  channel.Handle("encodeFrames", &arguments, ContractResultFor(first));
  HMW_EXPECT(dispatcher.WaitUntilEntered());

  auto busy = std::make_shared<ContractCapture>();
  auto second_arguments = ContractSlowSlideshowArguments();
  channel.Handle("encodeFrames", &second_arguments, ContractResultFor(busy));
  HMW_EXPECT(ContractTotalCalls(busy) == 1);
  {
    std::lock_guard<std::mutex> lock(busy->mutex);
    HMW_EXPECT(busy->errors == 1);
    HMW_EXPECT(busy->error_code == "busy");
  }

  controller.Cancel();
  dispatcher.Release();
  channel.Shutdown();
  dispatcher.Drain();

  auto invalid = std::make_shared<ContractCapture>();
  auto third_arguments = ContractSlowSlideshowArguments();
  channel.Handle("encodeFrames", &third_arguments,
                 ContractResultFor(invalid));
  HMW_EXPECT(ContractTotalCalls(invalid) == 1);
  {
    std::lock_guard<std::mutex> lock(invalid->mutex);
    HMW_EXPECT(invalid->errors == 1);
    HMW_EXPECT(invalid->error_code == "invalid_state");
  }
}

HMW_TEST(channel_rejects_bad_args_and_unknown_method_synchronously) {
  ContractQueueDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  hmw::ConverterChannel channel(controller, [](uint32_t, uint32_t) {});
  auto bad_args = std::make_shared<ContractCapture>();
  const EncodableValue bad_value(std::string("not a map"));
  channel.Handle("convertVideo", &bad_value, ContractResultFor(bad_args));
  HMW_EXPECT(ContractTotalCalls(bad_args) == 1);
  {
    std::lock_guard<std::mutex> lock(bad_args->mutex);
    HMW_EXPECT(bad_args->error_code == "invalid_argument");
  }
  auto unknown = std::make_shared<ContractCapture>();
  channel.Handle("unknown", nullptr, ContractResultFor(unknown));
  HMW_EXPECT(ContractTotalCalls(unknown) == 1);
  {
    std::lock_guard<std::mutex> lock(unknown->mutex);
    HMW_EXPECT(unknown->not_implemented == 1);
  }
}

}  // namespace
