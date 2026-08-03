#include "honey_camera_windows/camera_preview.h"

#include "test_support.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;

hcw::CameraFrame TestFrame(uint8_t marker) {
  return {2, 1, 10'000,
          std::make_shared<const std::vector<uint8_t>>(
              std::vector<uint8_t>{marker, 0, 0, 255, marker, 0, 0, 255})};
}

class FrameState final {
 public:
  bool WaitForRead() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s, [this] { return read_started_; });
  }

  bool WaitForStop() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s, [this] { return stop_requests_ != 0; });
  }

  void Push(hcw::CameraFrame frame) {
    std::lock_guard<std::mutex> lock(mutex_);
    frame_ = std::move(frame);
    condition_.notify_all();
  }

  hmw::Result<hcw::CameraFrame> ReadNext() {
    std::unique_lock<std::mutex> lock(mutex_);
    read_started_ = true;
    condition_.notify_all();
    condition_.wait(lock, [this] { return stop_requested_ || frame_; });
    if (stop_requested_) {
      return {std::nullopt, hmw::Error{hmw::Status::kCancelled, "stopped"}};
    }
    hcw::CameraFrame frame = std::move(*frame_);
    frame_.reset();
    return {std::move(frame), std::nullopt};
  }

  void RequestStop() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    stop_requested_ = true;
    ++stop_requests_;
    condition_.notify_all();
  }

  size_t stop_requests() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stop_requests_;
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::optional<hcw::CameraFrame> frame_;
  bool read_started_ = false;
  bool stop_requested_ = false;
  size_t stop_requests_ = 0;
};

class DelayedFrameState final {
 public:
  bool WaitForRead() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s, [this] { return read_started_; });
  }

  bool WaitForStop() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s, [this] { return stop_requests_ != 0; });
  }

  void ReleaseLateFrame() {
    std::lock_guard<std::mutex> lock(mutex_);
    release_frame_ = true;
    condition_.notify_all();
  }

  hmw::Result<hcw::CameraFrame> ReadNext() {
    std::unique_lock<std::mutex> lock(mutex_);
    if (returned_frame_) {
      return {std::nullopt, hmw::Error{hmw::Status::kCancelled, "stopped"}};
    }
    read_started_ = true;
    condition_.notify_all();
    condition_.wait(lock, [this] { return release_frame_; });
    returned_frame_ = true;
    return {TestFrame(7), std::nullopt};
  }

  void RequestStop() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    ++stop_requests_;
    condition_.notify_all();
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  bool read_started_ = false;
  bool release_frame_ = false;
  bool returned_frame_ = false;
  size_t stop_requests_ = 0;
};

class FrameSource final : public hcw::CameraFrameSource {
 public:
  explicit FrameSource(std::shared_ptr<FrameState> state) : state_(std::move(state)) {}

  hmw::Result<hcw::CameraFrame> ReadNext() override {
    return state_->ReadNext();
  }

  void RequestStop() noexcept override { state_->RequestStop(); }

 private:
  std::shared_ptr<FrameState> state_;
};

class DelayedFrameSource final : public hcw::CameraFrameSource {
 public:
  explicit DelayedFrameSource(std::shared_ptr<DelayedFrameState> state)
      : state_(std::move(state)) {}

  hmw::Result<hcw::CameraFrame> ReadNext() override {
    return state_->ReadNext();
  }

  void RequestStop() noexcept override { state_->RequestStop(); }

 private:
  std::shared_ptr<DelayedFrameState> state_;
};

class ThrowingSource final : public hcw::CameraFrameSource {
 public:
  hmw::Result<hcw::CameraFrame> ReadNext() override {
    throw std::runtime_error("read failed");
  }

  void RequestStop() noexcept override {}
};

bool WaitFor(std::condition_variable& condition, std::mutex& mutex,
             const std::function<bool()>& predicate) {
  std::unique_lock<std::mutex> lock(mutex);
  return condition.wait_for(lock, 2s, predicate);
}

}  // namespace

HMW_TEST(camera_preview_frame_callback_can_close_session) {
  const auto state = std::make_shared<FrameState>();
  std::mutex mutex;
  std::condition_variable condition;
  bool callback_finished = false;
  hmw::Outcome close_result;
  std::unique_ptr<hcw::CameraPreviewSession> session;
  session = std::make_unique<hcw::CameraPreviewSession>(
      [state](const hcw::CameraPreviewConfig&) {
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<FrameSource>(state), std::nullopt};
      },
      hcw::CameraPreviewCallbacks{[&](uint64_t, hcw::CameraFrame) {
        close_result = session->Close();
        std::lock_guard<std::mutex> lock(mutex);
        callback_finished = true;
        condition.notify_all();
      }, {}});

  HMW_EXPECT(session->Open({2, 1, 15}).ok());
  HMW_EXPECT(state->WaitForRead());
  state->Push(TestFrame(23));
  HMW_EXPECT(WaitFor(condition, mutex, [&] { return callback_finished; }));
  HMW_EXPECT(close_result.ok());
  HMW_EXPECT(state->stop_requests() == 1);
}

HMW_TEST(camera_preview_error_callback_can_close_session) {
  std::mutex mutex;
  std::condition_variable condition;
  bool callback_finished = false;
  hmw::Outcome close_result;
  std::unique_ptr<hcw::CameraPreviewSession> session;
  session = std::make_unique<hcw::CameraPreviewSession>(
      [](const hcw::CameraPreviewConfig&)
          -> hmw::Result<std::unique_ptr<hcw::CameraFrameSource>> {
        return {std::nullopt,
                hmw::Error{hmw::Status::kDeviceUnavailable, "unavailable"}};
      },
      hcw::CameraPreviewCallbacks{{},
        [&](uint64_t, hmw::Error) {
          close_result = session->Close();
          std::lock_guard<std::mutex> lock(mutex);
          callback_finished = true;
          condition.notify_all();
        }});

  HMW_EXPECT(session->Open({2, 1, 15}).ok());
  HMW_EXPECT(WaitFor(condition, mutex, [&] { return callback_finished; }));
  HMW_EXPECT(close_result.ok());
}

HMW_TEST(camera_preview_late_old_frame_is_suppressed_after_reopen) {
  const auto old_state = std::make_shared<DelayedFrameState>();
  const auto new_state = std::make_shared<FrameState>();
  std::atomic<size_t> source_index{0};
  std::mutex mutex;
  std::condition_variable condition;
  std::vector<hcw::CameraFrame> frames;
  hcw::CameraPreviewSession session(
      [&](const hcw::CameraPreviewConfig&) {
        if (source_index.fetch_add(1) == 0) {
          return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
              std::make_unique<DelayedFrameSource>(old_state), std::nullopt};
        }
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<FrameSource>(new_state), std::nullopt};
      },
      {[&](uint64_t, hcw::CameraFrame frame) {
         std::lock_guard<std::mutex> lock(mutex);
         frames.push_back(std::move(frame));
         condition.notify_all();
       }, {}});

  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  HMW_EXPECT(old_state->WaitForRead());
  hmw::Outcome reopen_result;
  std::thread reopen([&] { reopen_result = session.Open({2, 1, 15}); });
  HMW_EXPECT(old_state->WaitForStop());
  old_state->ReleaseLateFrame();
  reopen.join();
  HMW_EXPECT(reopen_result.ok());
  HMW_EXPECT(new_state->WaitForRead());
  {
    std::lock_guard<std::mutex> lock(mutex);
    HMW_EXPECT(frames.empty());
  }
  new_state->Push(TestFrame(29));
  HMW_EXPECT(WaitFor(condition, mutex, [&] { return frames.size() == 1; }));
  HMW_EXPECT(frames.size() == 1);
  if (!frames.empty()) {
    HMW_EXPECT(frames.front().bgra->at(0) == 29);
  }
  HMW_EXPECT(session.Close().ok());
}

HMW_TEST(camera_preview_open_rejects_zero_config) {
  size_t factory_calls = 0;
  hcw::CameraPreviewSession session(
      [&](const hcw::CameraPreviewConfig&) {
        ++factory_calls;
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::nullopt,
            hmw::Error{hmw::Status::kIoError, "factory must not run"}};
      }, {});

  const hmw::Outcome opened = session.Open({0, 1, 15});
  HMW_EXPECT(!opened.ok());
  HMW_EXPECT(opened.error.has_value());
  if (opened.error) {
    HMW_EXPECT(opened.error->status == hmw::Status::kInvalidArgument);
  }
  HMW_EXPECT(factory_calls == 0);
}

HMW_TEST(camera_preview_worker_exceptions_report_io_error) {
  std::mutex mutex;
  std::condition_variable condition;
  std::vector<hmw::Error> errors;
  const auto record_error = [&](uint64_t, hmw::Error error) {
    std::lock_guard<std::mutex> lock(mutex);
    errors.push_back(std::move(error));
    condition.notify_all();
  };

  hcw::CameraPreviewSession factory_session(
      [](const hcw::CameraPreviewConfig&)
          -> hmw::Result<std::unique_ptr<hcw::CameraFrameSource>> {
        throw std::runtime_error("factory failed");
      }, {{}, record_error});
  HMW_EXPECT(factory_session.Open({2, 1, 15}).ok());
  HMW_EXPECT(WaitFor(condition, mutex, [&] { return errors.size() == 1; }));
  HMW_EXPECT(errors.size() == 1);
  if (!errors.empty()) {
    HMW_EXPECT(errors.front().status == hmw::Status::kIoError);
  }
  HMW_EXPECT(factory_session.Close().ok());

  {
    std::lock_guard<std::mutex> lock(mutex);
    errors.clear();
  }
  hcw::CameraPreviewSession read_session(
      [](const hcw::CameraPreviewConfig&) {
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<ThrowingSource>(), std::nullopt};
      }, {{}, record_error});
  HMW_EXPECT(read_session.Open({2, 1, 15}).ok());
  HMW_EXPECT(WaitFor(condition, mutex, [&] { return errors.size() == 1; }));
  HMW_EXPECT(errors.size() == 1);
  if (!errors.empty()) {
    HMW_EXPECT(errors.front().status == hmw::Status::kIoError);
  }
  HMW_EXPECT(read_session.Close().ok());
}

HMW_TEST(camera_preview_frame_callback_can_destroy_session) {
  const auto state = std::make_shared<FrameState>();
  std::mutex mutex;
  std::condition_variable condition;
  bool destroyed = false;
  std::unique_ptr<hcw::CameraPreviewSession> session;
  session = std::make_unique<hcw::CameraPreviewSession>(
      [state](const hcw::CameraPreviewConfig&) {
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<FrameSource>(state), std::nullopt};
      },
      hcw::CameraPreviewCallbacks{[&](uint64_t, hcw::CameraFrame) {
        session.reset();
        std::lock_guard<std::mutex> lock(mutex);
        destroyed = true;
        condition.notify_all();
      }, {}});

  HMW_EXPECT(session->Open({2, 1, 15}).ok());
  HMW_EXPECT(state->WaitForRead());
  state->Push(TestFrame(31));
  HMW_EXPECT(WaitFor(condition, mutex, [&] { return destroyed; }));
  HMW_EXPECT(session == nullptr);
  HMW_EXPECT(state->WaitForStop());
}

HMW_TEST(camera_preview_frame_callback_exception_reports_io_error) {
  const auto state = std::make_shared<FrameState>();
  std::mutex mutex;
  std::condition_variable condition;
  std::vector<hmw::Error> errors;
  hcw::CameraPreviewSession session(
      [state](const hcw::CameraPreviewConfig&) {
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<FrameSource>(state), std::nullopt};
      },
      {[](uint64_t, hcw::CameraFrame) {
         throw std::runtime_error("frame callback failed");
       },
       [&](uint64_t, hmw::Error error) {
         std::lock_guard<std::mutex> lock(mutex);
         errors.push_back(std::move(error));
         condition.notify_all();
       }});

  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  HMW_EXPECT(state->WaitForRead());
  state->Push(TestFrame(37));
  HMW_EXPECT(WaitFor(condition, mutex, [&] { return errors.size() == 1; }));
  HMW_EXPECT(errors.size() == 1);
  if (!errors.empty()) {
    HMW_EXPECT(errors.front().status == hmw::Status::kIoError);
  }
  HMW_EXPECT(session.Close().ok());
}
