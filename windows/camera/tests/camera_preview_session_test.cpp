#include "honey_camera_windows/camera_preview.h"

#include "test_support.h"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <utility>
#include <thread>
#include <vector>

namespace {

using namespace std::chrono_literals;

hcw::CameraFrame TestFrame(uint8_t marker) {
  return {2, 1, 10'000,
          std::make_shared<const std::vector<uint8_t>>(
              std::vector<uint8_t>{marker, 0, 0, 255, marker, 0, 0, 255})};
}

class BlockingSourceState final {
 public:
  void PushFrame(hcw::CameraFrame frame) {
    std::lock_guard<std::mutex> lock(mutex_);
    frame_ = std::move(frame);
    condition_.notify_all();
  }

  bool WaitForRead() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s, [this] { return read_started_; });
  }

  bool WaitForReadReturn() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s, [this] { return read_returned_; });
  }

  hmw::Result<hcw::CameraFrame> ReadNext() {
    std::unique_lock<std::mutex> lock(mutex_);
    read_started_ = true;
    condition_.notify_all();
    condition_.wait(lock, [this] { return stop_requested_ || frame_; });
    read_returned_ = true;
    condition_.notify_all();
    if (stop_requested_) {
      return {std::nullopt,
              hmw::Error{hmw::Status::kCancelled, "source stopped"}};
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
  bool read_returned_ = false;
  bool stop_requested_ = false;
  size_t stop_requests_ = 0;
};

class BlockingSource final : public hcw::CameraFrameSource {
 public:
  explicit BlockingSource(std::shared_ptr<BlockingSourceState> state)
      : state_(std::move(state)) {}

  hmw::Result<hcw::CameraFrame> ReadNext() override {
    return state_->ReadNext();
  }

  void RequestStop() noexcept override { state_->RequestStop(); }

 private:
  std::shared_ptr<BlockingSourceState> state_;
};

class AffinitySourceState final
    : public std::enable_shared_from_this<AffinitySourceState> {
 public:
  hmw::Result<hcw::CameraFrame> ReadNext() {
    thread_local std::shared_ptr<void> worker_exit_signal;
    worker_exit_signal = std::shared_ptr<void>(
        nullptr, [state = shared_from_this()](void*) {
          state->RecordWorkerExit();
        });
    std::unique_lock<std::mutex> lock(mutex_);
    worker_thread_ = std::this_thread::get_id();
    read_started_ = true;
    condition_.notify_all();
    condition_.wait(lock, [this] { return stop_requested_; });
    return {std::nullopt,
            hmw::Error{hmw::Status::kCancelled, "source stopped"}};
  }

  void RequestStop() noexcept {
    std::unique_lock<std::mutex> lock(mutex_);
    stop_requested_ = true;
    condition_.notify_all();
    stop_observed_worker_exit_ = condition_.wait_for(
        lock, 2s, [this] { return worker_exited_; });
  }

  void RecordWorkerExit() {
    std::lock_guard<std::mutex> lock(mutex_);
    worker_exited_ = true;
    condition_.notify_all();
  }

  void RecordWorkerTeardown() {
    std::lock_guard<std::mutex> lock(mutex_);
    ++teardown_count_;
    teardown_thread_ = std::this_thread::get_id();
    condition_.notify_all();
  }

  void RecordDestruction() {
    std::lock_guard<std::mutex> lock(mutex_);
    destruction_thread_ = std::this_thread::get_id();
    condition_.notify_all();
  }

  bool WaitForRead() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s, [this] { return read_started_; });
  }

  bool StopObservedWorkerExit() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stop_observed_worker_exit_;
  }

  bool TeardownRanExactlyOnceOnWorker() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return teardown_count_ == 1 && worker_thread_.has_value() &&
           teardown_thread_.has_value() &&
           *worker_thread_ == *teardown_thread_;
  }

  bool ShellWasDestroyedOffWorker() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return worker_thread_.has_value() && destruction_thread_.has_value() &&
           *worker_thread_ != *destruction_thread_;
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::optional<std::thread::id> worker_thread_;
  std::optional<std::thread::id> destruction_thread_;
  std::optional<std::thread::id> teardown_thread_;
  bool read_started_ = false;
  size_t teardown_count_ = 0;
  bool stop_requested_ = false;
  bool worker_exited_ = false;
  bool stop_observed_worker_exit_ = false;
};

class AffinitySource final : public hcw::CameraFrameSource {
 public:
  explicit AffinitySource(std::shared_ptr<AffinitySourceState> state)
      : state_(std::move(state)) {}
  ~AffinitySource() override { state_->RecordDestruction(); }

  hmw::Result<hcw::CameraFrame> ReadNext() override {
    return state_->ReadNext();
  }

  void RequestStop() noexcept override { state_->RequestStop(); }

  void TeardownOnWorker() noexcept override { state_->RecordWorkerTeardown(); }

 private:
  std::shared_ptr<AffinitySourceState> state_;
};

}  // namespace

HMW_TEST(camera_preview_active_generation_publishes_frames) {
  const auto state = std::make_shared<BlockingSourceState>();
  std::mutex mutex;
  std::condition_variable condition;
  std::vector<std::pair<uint64_t, hcw::CameraFrame>> frames;
  hcw::CameraPreviewSession session(
      [state](const hcw::CameraPreviewConfig&) {
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<BlockingSource>(state), std::nullopt};
      },
      {[&](uint64_t generation, hcw::CameraFrame frame) {
         std::lock_guard<std::mutex> lock(mutex);
         frames.emplace_back(generation, std::move(frame));
         condition.notify_all();
       },
       {}});

  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  HMW_EXPECT(state->WaitForRead());
  const uint64_t generation = session.generation();
  state->PushFrame(TestFrame(23));
  {
    std::unique_lock<std::mutex> lock(mutex);
    HMW_EXPECT(condition.wait_for(lock, 2s, [&] { return frames.size() == 1; }));
  }
  HMW_EXPECT(frames.size() == 1);
  if (!frames.empty()) {
    HMW_EXPECT(frames.front().first == generation);
    HMW_EXPECT(frames.front().second.rgba->at(0) == 23);
  }
  HMW_EXPECT(session.Close().ok());
}

HMW_TEST(camera_preview_close_is_idempotent_and_joins_worker) {
  const auto state = std::make_shared<BlockingSourceState>();
  hcw::CameraPreviewSession session(
      [state](const hcw::CameraPreviewConfig&) {
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<BlockingSource>(state), std::nullopt};
      },
      {});

  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  HMW_EXPECT(state->WaitForRead());
  HMW_EXPECT(session.Close().ok());
  HMW_EXPECT(state->WaitForReadReturn());
  HMW_EXPECT(state->stop_requests() == 1);
  HMW_EXPECT(session.Close().ok());
  HMW_EXPECT(state->stop_requests() == 1);
}

HMW_TEST(camera_preview_resources_teardown_on_worker_before_ui_shell_release) {
  const auto state = std::make_shared<AffinitySourceState>();
  hcw::CameraPreviewSession session(
      [state](const hcw::CameraPreviewConfig&) {
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<AffinitySource>(state), std::nullopt};
      },
      {});

  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  HMW_EXPECT(state->WaitForRead());
  HMW_EXPECT(session.Close().ok());
  HMW_EXPECT(state->StopObservedWorkerExit());
  HMW_EXPECT(state->TeardownRanExactlyOnceOnWorker());
  HMW_EXPECT(state->ShellWasDestroyedOffWorker());
}

HMW_TEST(camera_preview_new_open_suppresses_old_generation) {
  const auto old_state = std::make_shared<BlockingSourceState>();
  const auto new_state = std::make_shared<BlockingSourceState>();
  size_t source_index = 0;
  std::mutex mutex;
  std::condition_variable condition;
  std::vector<std::pair<uint64_t, hcw::CameraFrame>> frames;
  hcw::CameraPreviewSession session(
      [&](const hcw::CameraPreviewConfig&) {
        const auto state = source_index++ == 0 ? old_state : new_state;
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<BlockingSource>(state), std::nullopt};
      },
      {[&](uint64_t generation, hcw::CameraFrame frame) {
         std::lock_guard<std::mutex> lock(mutex);
         frames.emplace_back(generation, std::move(frame));
         condition.notify_all();
       },
       {}});

  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  HMW_EXPECT(old_state->WaitForRead());
  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  HMW_EXPECT(old_state->WaitForReadReturn());
  HMW_EXPECT(old_state->stop_requests() == 1);
  HMW_EXPECT(new_state->WaitForRead());
  const uint64_t generation = session.generation();
  old_state->PushFrame(TestFrame(7));
  new_state->PushFrame(TestFrame(29));
  {
    std::unique_lock<std::mutex> lock(mutex);
    HMW_EXPECT(condition.wait_for(lock, 2s, [&] { return frames.size() == 1; }));
  }
  HMW_EXPECT(frames.size() == 1);
  if (!frames.empty()) {
    HMW_EXPECT(frames.front().first == generation);
    HMW_EXPECT(frames.front().second.rgba->at(0) == 29);
  }
  HMW_EXPECT(session.Close().ok());
}

HMW_TEST(camera_preview_factory_failure_reports_once) {
  std::mutex mutex;
  std::condition_variable condition;
  size_t errors = 0;
  hmw::Error error{hmw::Status::kOk, ""};
  hcw::CameraPreviewSession session(
      [](const hcw::CameraPreviewConfig&)
          -> hmw::Result<std::unique_ptr<hcw::CameraFrameSource>> {
        return {std::nullopt,
                hmw::Error{hmw::Status::kDeviceUnavailable,
                           "camera unavailable"}};
      },
      {{},
       [&](uint64_t, hmw::Error reported) {
         std::lock_guard<std::mutex> lock(mutex);
         ++errors;
         error = std::move(reported);
         condition.notify_all();
       }});

  HMW_EXPECT(session.Open({2, 1, 15}).ok());
  {
    std::unique_lock<std::mutex> lock(mutex);
    HMW_EXPECT(condition.wait_for(lock, 2s, [&] { return errors == 1; }));
  }
  HMW_EXPECT(session.Close().ok());
  HMW_EXPECT(errors == 1);
  HMW_EXPECT(error.status == hmw::Status::kDeviceUnavailable);
}
