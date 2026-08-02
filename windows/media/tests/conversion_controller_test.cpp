#include "test_support.h"

#include "honey_media_windows/conversion_controller.h"
#include "honey_media_windows/platform_dispatcher.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;

std::filesystem::path FixturePath(const char* relative) {
  return std::filesystem::path(HMW_PROJECT_SOURCE_DIR) / relative;
}

class CountingDispatcher : public hmw::PlatformDispatcher {
 public:
  bool Post(std::function<void()>) override {
    ++post_attempts;
    return true;
  }

  std::atomic<uint32_t> post_attempts{0};
};

hmw::RgbaFrame SolidFrame() {
  hmw::RgbaFrame frame{4, 4, 0, 1000000, {}};
  frame.pixels.resize(4U * 4U * 4U, 255U);
  return frame;
}

hmw::SlideshowRequest SmallSlideshow(uint32_t hold = 1U) {
  return hmw::SlideshowRequest{{SolidFrame()}, {hold}, 4, 10, 80};
}

hmw::ScrollRequest SmallScroll() {
  return hmw::ScrollRequest{SolidFrame(), 4, 0xff000000U, 4, 4, 0, 80, 1};
}

hmw::ConversionRequest SmallConversion() {
  return hmw::ConversionRequest{
      FixturePath("windows/media/tests/fixtures/animated_disposal.gif"),
      4,
      4,
      10,
      80,
      3,
      2,
      720,
      0,
      1,
      0xff000000U,
      hmw::FitMode::kCover,
      std::nullopt};
}

class BlockingDispatcher : public hmw::PlatformDispatcher {
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

  bool RunOne() {
    std::function<void()> callback;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (callbacks_.empty()) {
        return false;
      }
      callback = std::move(callbacks_.front());
      callbacks_.pop_front();
    }
    callback();
    return true;
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
  bool entered_ = false;
  bool released_ = false;
};

class QueueDispatcher : public hmw::PlatformDispatcher {
 public:
  explicit QueueDispatcher(bool duplicate_delivery = false)
      : duplicate_delivery_(duplicate_delivery) {}

  bool Post(std::function<void()> callback) override {
    std::lock_guard<std::mutex> lock(mutex_);
    posting_threads_.push_back(std::this_thread::get_id());
    callbacks_.push_back(std::move(callback));
    condition_.notify_all();
    return true;
  }

  bool WaitForPending(size_t count) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 10s,
                               [&] { return callbacks_.size() >= count; });
  }

  bool RunOne() {
    std::function<void()> callback;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (callbacks_.empty()) {
        return false;
      }
      callback = std::move(callbacks_.front());
      callbacks_.pop_front();
    }
    callback();
    if (duplicate_delivery_) {
      callback();
    }
    return true;
  }

  void Drain() {
    while (RunOne()) {
    }
  }

  std::vector<std::thread::id> posting_threads() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return posting_threads_;
  }

 private:
  const bool duplicate_delivery_;
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<std::function<void()>> callbacks_;
  std::vector<std::thread::id> posting_threads_;
};

class RejectingDispatcher : public hmw::PlatformDispatcher {
 public:
  bool Post(std::function<void()>) override {
    std::lock_guard<std::mutex> lock(mutex_);
    ++attempts_;
    condition_.notify_all();
    return false;
  }

  bool WaitForAttempt() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 10s, [&] { return attempts_ != 0; });
  }

  size_t attempts() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return attempts_;
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  size_t attempts_ = 0;
};

template <typename Dispatcher>
bool PumpUntil(Dispatcher& dispatcher, const std::atomic<bool>& completed) {
  const auto deadline = std::chrono::steady_clock::now() + 10s;
  while (!completed.load() && std::chrono::steady_clock::now() < deadline) {
    if (!dispatcher.RunOne()) {
      std::this_thread::yield();
    }
  }
  return completed.load();
}

}  // namespace

HMW_TEST(controller_rejects_start_after_shutdown_as_invalid_state) {
  CountingDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  controller.Shutdown();
  std::atomic<uint32_t> progress{0};
  std::atomic<uint32_t> completions{0};

  const hmw::Result<uint64_t> started = controller.Start(
      hmw::SlideshowRequest{}, [&](uint32_t, uint32_t) { ++progress; },
      [&](hmw::Result<hmw::MediaJobResult>) { ++completions; });

  HMW_EXPECT(!started.ok());
  HMW_EXPECT(started.error.has_value());
  if (started.error) {
    HMW_EXPECT(started.error->status == hmw::Status::kInvalidState);
  }
  HMW_EXPECT(dispatcher.post_attempts.load() == 0);
  HMW_EXPECT(progress.load() == 0);
  HMW_EXPECT(completions.load() == 0);
}

HMW_TEST(controller_rejects_second_active_job_as_busy) {
  BlockingDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  std::atomic<uint32_t> rejected_progress{0};
  std::atomic<uint32_t> rejected_completions{0};

  const hmw::Result<uint64_t> first = controller.Start(
      SmallSlideshow(100), IgnoreProgress,
      [](hmw::Result<hmw::MediaJobResult>) {});
  HMW_EXPECT(first.ok());
  if (!first.ok()) {
    return;
  }
  HMW_EXPECT(dispatcher.WaitUntilEntered());

  const hmw::Result<uint64_t> rejected = controller.Start(
      SmallSlideshow(),
      [&](uint32_t, uint32_t) { ++rejected_progress; },
      [&](hmw::Result<hmw::MediaJobResult>) { ++rejected_completions; });
  HMW_EXPECT(!rejected.ok());
  HMW_EXPECT(rejected.error.has_value());
  if (rejected.error) {
    HMW_EXPECT(rejected.error->status == hmw::Status::kBusy);
  }
  HMW_EXPECT(rejected_progress.load() == 0);
  HMW_EXPECT(rejected_completions.load() == 0);

  controller.Cancel();
  dispatcher.Release();
  controller.Shutdown();
  dispatcher.Drain();
  HMW_EXPECT(rejected_progress.load() == 0);
  HMW_EXPECT(rejected_completions.load() == 0);
}
HMW_TEST(controller_cancel_only_marks_current_generation) {
  BlockingDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  std::atomic<bool> first_completed{false};
  std::atomic<bool> first_cancelled{false};
  const hmw::Result<uint64_t> first = controller.Start(
      SmallSlideshow(100), IgnoreProgress,
      [&](hmw::Result<hmw::MediaJobResult> result) {
        first_cancelled = !result.ok() && result.error.has_value() &&
                          result.error->status == hmw::Status::kCancelled;
        first_completed = true;
      });
  HMW_EXPECT(first.ok());
  if (!first.ok()) {
    return;
  }
  HMW_EXPECT(dispatcher.WaitUntilEntered());
  controller.Cancel();
  dispatcher.Release();
  HMW_EXPECT(PumpUntil(dispatcher, first_completed));
  HMW_EXPECT(first_cancelled.load());

  std::atomic<bool> second_completed{false};
  std::atomic<bool> second_succeeded{false};
  hmw::ConversionController::Completion second_completion =
      [&](hmw::Result<hmw::MediaJobResult> result) {
        second_succeeded = result.ok();
        second_completed = true;
      };
  hmw::Result<uint64_t> second{
      std::nullopt, hmw::Error{hmw::Status::kBusy, "not started"}};
  const auto deadline = std::chrono::steady_clock::now() + 10s;
  while (!second.ok() && std::chrono::steady_clock::now() < deadline) {
    second =
        controller.Start(SmallSlideshow(), IgnoreProgress, second_completion);
    if (!second.ok()) {
      HMW_EXPECT(second.error.has_value());
      if (!second.error || second.error->status != hmw::Status::kBusy) {
        break;
      }
      std::this_thread::yield();
    }
  }
  HMW_EXPECT(second.ok());
  if (second.ok()) {
    HMW_EXPECT(*second.value == *first.value + 1U);
    HMW_EXPECT(PumpUntil(dispatcher, second_completed));
    HMW_EXPECT(second_succeeded.load());
  }
}
HMW_TEST(controller_drops_old_progress_after_new_generation) {
  QueueDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  std::atomic<uint32_t> old_progress{0};
  std::atomic<uint32_t> old_completions{0};
  const hmw::Result<uint64_t> first = controller.Start(
      SmallSlideshow(), [&](uint32_t, uint32_t) { ++old_progress; },
      [&](hmw::Result<hmw::MediaJobResult>) { ++old_completions; });
  HMW_EXPECT(first.ok());
  if (!first.ok()) {
    return;
  }
  HMW_EXPECT(dispatcher.WaitForPending(2));

  std::atomic<bool> new_completed{false};
  std::atomic<uint32_t> new_progress{0};
  hmw::Progress new_progress_callback =
      [&](uint32_t, uint32_t) { ++new_progress; };
  hmw::ConversionController::Completion new_completion =
      [&](hmw::Result<hmw::MediaJobResult>) { new_completed = true; };
  hmw::Result<uint64_t> second{
      std::nullopt, hmw::Error{hmw::Status::kBusy, "not started"}};
  const auto deadline = std::chrono::steady_clock::now() + 10s;
  while (!second.ok() && std::chrono::steady_clock::now() < deadline) {
    second = controller.Start(SmallSlideshow(), new_progress_callback,
                              new_completion);
    if (!second.ok()) {
      HMW_EXPECT(second.error.has_value());
      if (!second.error || second.error->status != hmw::Status::kBusy) {
        break;
      }
      std::this_thread::yield();
    }
  }
  HMW_EXPECT(second.ok());
  if (!second.ok()) {
    return;
  }
  HMW_EXPECT(PumpUntil(dispatcher, new_completed));
  dispatcher.Drain();
  HMW_EXPECT(old_progress.load() == 0);
  HMW_EXPECT(old_completions.load() == 0);
  HMW_EXPECT(new_progress.load() >= 1);
}
HMW_TEST(controller_drops_completion_after_shutdown) {
  QueueDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  std::atomic<uint32_t> completions{0};
  const hmw::Result<uint64_t> started = controller.Start(
      hmw::SlideshowRequest{}, IgnoreProgress,
      [&](hmw::Result<hmw::MediaJobResult>) { ++completions; });
  HMW_EXPECT(started.ok());
  if (!started.ok()) {
    return;
  }
  HMW_EXPECT(dispatcher.WaitForPending(1));
  controller.Shutdown();
  dispatcher.Drain();
  HMW_EXPECT(completions.load() == 0);
}

HMW_TEST(controller_posts_one_terminal_completion) {
  QueueDispatcher dispatcher(true);
  hmw::ConversionController controller(dispatcher);
  std::atomic<bool> completed{false};
  std::atomic<uint32_t> completions{0};
  const hmw::Result<uint64_t> started = controller.Start(
      SmallSlideshow(), IgnoreProgress,
      [&](hmw::Result<hmw::MediaJobResult> result) {
        HMW_EXPECT(result.ok());
        ++completions;
        completed = true;
      });
  HMW_EXPECT(started.ok());
  if (!started.ok()) {
    return;
  }
  HMW_EXPECT(PumpUntil(dispatcher, completed));
  dispatcher.Drain();
  HMW_EXPECT(completions.load() == 1);
}
HMW_TEST(dispatch_failure_invalidates_completion_without_leak) {
  RejectingDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  std::atomic<uint32_t> completions{0};
  auto retained = std::make_shared<uint32_t>(7U);
  std::weak_ptr<uint32_t> retained_weak = retained;
  hmw::ConversionController::Completion completion =
      [retained, &completions](hmw::Result<hmw::MediaJobResult>) {
        ++completions;
      };
  retained.reset();
  const hmw::Result<uint64_t> started = controller.Start(
      hmw::SlideshowRequest{}, IgnoreProgress, std::move(completion));
  HMW_EXPECT(started.ok());
  if (!started.ok()) {
    return;
  }
  HMW_EXPECT(dispatcher.WaitForAttempt());
  controller.Shutdown();
  HMW_EXPECT(dispatcher.attempts() == 1);
  HMW_EXPECT(completions.load() == 0);
  HMW_EXPECT(retained_weak.expired());
}

HMW_TEST(win32_dispatcher_executes_owned_callback_from_private_message) {
  UINT posted_message = 0;
  WPARAM posted_wparam = 0;
  LPARAM posted_lparam = 0;
  hmw::Win32PlatformDispatcher dispatcher(
      reinterpret_cast<HWND>(static_cast<uintptr_t>(1)),
      [&](HWND, UINT message, WPARAM wparam, LPARAM lparam) {
        posted_message = message;
        posted_wparam = wparam;
        posted_lparam = lparam;
        return true;
      });
  std::atomic<uint32_t> calls{0};
  HMW_EXPECT(dispatcher.Post([&] { ++calls; }));
  HMW_EXPECT(calls.load() == 0);
  const std::optional<LRESULT> handled =
      hmw::Win32PlatformDispatcher::HandleMessage(
          posted_message, posted_wparam, posted_lparam);
  HMW_EXPECT(handled.has_value());
  HMW_EXPECT(handled.value_or(1) == 0);
  HMW_EXPECT(calls.load() == 1);
  HMW_EXPECT(!hmw::Win32PlatformDispatcher::HandleMessage(
                  WM_APP, posted_wparam, 0)
                  .has_value());
}

HMW_TEST(win32_dispatcher_failed_post_destroys_callback_immediately) {
  auto retained = std::make_shared<uint32_t>(9U);
  std::weak_ptr<uint32_t> retained_weak = retained;
  hmw::Win32PlatformDispatcher dispatcher(
      reinterpret_cast<HWND>(static_cast<uintptr_t>(1)),
      [](HWND, UINT, WPARAM, LPARAM) { return false; });
  std::function<void()> callback = [retained] {};
  retained.reset();
  HMW_EXPECT(!dispatcher.Post(std::move(callback)));
  HMW_EXPECT(retained_weak.expired());
}
HMW_TEST(controller_runs_thumbnail_preview_decode_convert_frames_and_scroll_jobs) {
  const std::filesystem::path gif =
      FixturePath("windows/media/tests/fixtures/animated_disposal.gif");
  std::vector<hmw::MediaJobRequest> requests;
  requests.emplace_back(hmw::ThumbnailRequest{gif});
  requests.emplace_back(hmw::PreviewRequest{gif, 1, 4});
  requests.emplace_back(hmw::DecodeCvidRequest{
      FixturePath("media_core/tests/fixtures/cvid_sample.avi"), 1, 4});
  requests.emplace_back(SmallConversion());
  requests.emplace_back(SmallSlideshow());
  requests.emplace_back(SmallScroll());
  const std::vector<size_t> expected_result_index{0, 1, 1, 2, 2, 2};

  QueueDispatcher dispatcher;
  hmw::ConversionController controller(dispatcher);
  const std::thread::id platform_thread = std::this_thread::get_id();
  for (size_t index = 0; index < requests.size(); ++index) {
    const size_t posts_before = dispatcher.posting_threads().size();
    std::atomic<bool> completed{false};
    std::atomic<bool> succeeded{false};
    std::thread::id callback_thread;
    const hmw::Result<uint64_t> started = controller.Start(
        requests[index], IgnoreProgress,
        [&](hmw::Result<hmw::MediaJobResult> result) {
          succeeded = result.ok();
          if (result.ok()) {
            HMW_EXPECT(result.value->index() == expected_result_index[index]);
          }
          callback_thread = std::this_thread::get_id();
          completed = true;
        });
    HMW_EXPECT(started.ok());
    if (!started.ok()) {
      return;
    }
    HMW_EXPECT(PumpUntil(dispatcher, completed));
    HMW_EXPECT(succeeded.load());
    HMW_EXPECT(callback_thread == platform_thread);
    const std::vector<std::thread::id> posting_threads =
        dispatcher.posting_threads();
    HMW_EXPECT(posting_threads.size() > posts_before);
    for (size_t post = posts_before; post < posting_threads.size(); ++post) {
      HMW_EXPECT(posting_threads[post] != platform_thread);
    }
  }
}
