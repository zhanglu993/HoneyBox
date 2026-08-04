#include "honey_camera_windows/camera_preview.h"

#include "test_support.h"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;

class BurstState final {
 public:
  BurstState(size_t frame_count, uint8_t first_marker)
      : frame_count_(frame_count), first_marker_(first_marker) {}

  bool WaitForProduced() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s,
                               [this] { return produced_ == frame_count_; });
  }

  void ReleaseBurst() {
    std::lock_guard<std::mutex> lock(mutex_);
    burst_released_ = true;
    condition_.notify_all();
  }

  size_t LiveBuffers() const {
    std::lock_guard<std::mutex> lock(mutex_);
    size_t live = 0;
    for (const auto& buffer : buffers_) {
      if (!buffer.expired()) {
        ++live;
      }
    }
    return live;
  }

  hmw::Result<hcw::CameraFrame> ReadNext() {
    std::unique_lock<std::mutex> lock(mutex_);
    if (produced_ < frame_count_) {
      if (produced_ == 1 && !burst_released_) {
        condition_.wait(lock,
                        [this] { return stop_requested_ || burst_released_; });
        if (stop_requested_) {
          return {std::nullopt,
                  hmw::Error{hmw::Status::kCancelled, "stopped"}};
        }
      }
      const uint8_t marker =
          static_cast<uint8_t>(first_marker_ + static_cast<uint8_t>(produced_));
      auto buffer = std::make_shared<const std::vector<uint8_t>>(
          std::vector<uint8_t>(64, marker));
      buffers_.push_back(buffer);
      ++produced_;
      condition_.notify_all();
      return {hcw::CameraFrame{2, 1, 10'000, std::move(buffer)}, std::nullopt};
    }
    condition_.wait(lock, [this] { return stop_requested_; });
    return {std::nullopt, hmw::Error{hmw::Status::kCancelled, "stopped"}};
  }

  void RequestStop() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    stop_requested_ = true;
    condition_.notify_all();
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  const size_t frame_count_;
  const uint8_t first_marker_;
  std::vector<std::weak_ptr<const std::vector<uint8_t>>> buffers_;
  size_t produced_ = 0;
  bool burst_released_ = false;
  bool stop_requested_ = false;
};

class BurstSource final : public hcw::CameraFrameSource {
 public:
  explicit BurstSource(std::shared_ptr<BurstState> state)
      : state_(std::move(state)) {}

  hmw::Result<hcw::CameraFrame> ReadNext() override {
    return state_->ReadNext();
  }

  void RequestStop() noexcept override { state_->RequestStop(); }

 private:
  std::shared_ptr<BurstState> state_;
};

class CallbackGate final {
 public:
  void Block() {
    std::unique_lock<std::mutex> lock(mutex_);
    started_ = true;
    condition_.notify_all();
    condition_.wait(lock, [this] { return released_; });
  }

  bool WaitForStart() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s, [this] { return started_; });
  }

  void Release() {
    std::lock_guard<std::mutex> lock(mutex_);
    released_ = true;
    condition_.notify_all();
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  bool started_ = false;
  bool released_ = false;
};

bool WaitFor(std::condition_variable& condition, std::mutex& mutex,
             const std::function<bool()>& predicate) {
  std::unique_lock<std::mutex> lock(mutex);
  return condition.wait_for(lock, 2s, predicate);
}

}  // namespace

HMW_TEST(camera_preview_slow_callback_keeps_frame_buffers_bounded) {
  const auto source_state = std::make_shared<BurstState>(64U, uint8_t{1});
  CallbackGate gate;
  hcw::CameraPreviewSession session(
      [source_state](const hcw::CameraPreviewConfig&) {
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<BurstSource>(source_state), std::nullopt};
      },
      {[&](uint64_t, hcw::CameraFrame) { gate.Block(); }, {}});

  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  HMW_EXPECT(gate.WaitForStart());
  source_state->ReleaseBurst();
  HMW_EXPECT(source_state->WaitForProduced());
  HMW_EXPECT(source_state->LiveBuffers() <= 2);
  HMW_EXPECT(session.Close().ok());
  gate.Release();
}

HMW_TEST(camera_preview_reopen_discards_old_frame_backlog_before_new_frame) {
  const auto old_state = std::make_shared<BurstState>(64U, uint8_t{1});
  const auto new_state = std::make_shared<BurstState>(1U, uint8_t{200});
  size_t source_index = 0;
  CallbackGate gate;
  std::mutex mutex;
  std::condition_variable condition;
  std::vector<uint8_t> delivered_markers;
  hcw::CameraPreviewSession session(
      [&](const hcw::CameraPreviewConfig&) {
        const auto state = source_index++ == 0 ? old_state : new_state;
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<BurstSource>(state), std::nullopt};
      },
      {[&](uint64_t, hcw::CameraFrame frame) {
         if (frame.rgba->at(0) == 1) {
           gate.Block();
           return;
         }
         std::lock_guard<std::mutex> lock(mutex);
         delivered_markers.push_back(frame.rgba->at(0));
         condition.notify_all();
       }, {}});

  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  HMW_EXPECT(gate.WaitForStart());
  old_state->ReleaseBurst();
  HMW_EXPECT(old_state->WaitForProduced());
  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  HMW_EXPECT(old_state->LiveBuffers() <= 1);
  HMW_EXPECT(new_state->WaitForProduced());
  gate.Release();
  HMW_EXPECT(WaitFor(condition, mutex,
                     [&] { return delivered_markers.size() == 1; }));
  HMW_EXPECT(delivered_markers.size() == 1);
  if (!delivered_markers.empty()) {
    HMW_EXPECT(delivered_markers.front() == 200);
  }
  HMW_EXPECT(session.Close().ok());
}

HMW_TEST(camera_preview_error_callback_exception_is_contained) {
  std::mutex mutex;
  std::condition_variable condition;
  size_t error_callbacks = 0;
  hcw::CameraPreviewSession session(
      [](const hcw::CameraPreviewConfig&)
          -> hmw::Result<std::unique_ptr<hcw::CameraFrameSource>> {
        return {std::nullopt,
                hmw::Error{hmw::Status::kDeviceUnavailable, "unavailable"}};
      },
      { {},
       [&](uint64_t, hmw::Error) {
         {
           std::lock_guard<std::mutex> lock(mutex);
           ++error_callbacks;
           condition.notify_all();
         }
         throw std::runtime_error("error callback failed");
       }});

  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  HMW_EXPECT(WaitFor(condition, mutex, [&] { return error_callbacks == 1; }));
  HMW_EXPECT(error_callbacks == 1);
  HMW_EXPECT(session.Close().ok());
}
