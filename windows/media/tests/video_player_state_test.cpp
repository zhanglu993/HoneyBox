#include "video_texture_player.h"

#include "honey_media_windows/media_source.h"
#include "honey_media_windows/platform_dispatcher.h"
#include "honey_media_windows/texture_registry.h"
#include "test_support.h"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <system_error>
#include <utility>
#include <vector>

namespace {

hmw::RgbaFrame TestFrame(int64_t pts_100ns, uint8_t red) {
  return hmw::RgbaFrame{
      2,
      1,
      pts_100ns,
      1'000'000,
      {red, 20, 30, 255, 40, 50, 60, 255},
  };
}

class FakeFrameSource final : public hmw::FrameSource {
 public:
  explicit FakeFrameSource(std::vector<hmw::RgbaFrame> frames,
                           bool block_second_read = false,
                           int64_t duration_100ns = 10'000'000)
      : frames_(std::move(frames)),
        block_second_read_(block_second_read) {
    info_.duration_100ns = duration_100ns;
  }

  const hmw::SourceInfo& info() const override { return info_; }

  hmw::Result<bool> ReadNext(hmw::RgbaFrame* frame) override {
    std::unique_lock<std::mutex> lock(mutex_);
    if (next_ >= frames_.size()) {
      return hmw::Result<bool>{false, std::nullopt};
    }
    const size_t index = next_++;
    if (block_second_read_ && index == 1) {
      second_read_started_ = true;
      condition_.notify_all();
      condition_.wait(lock, [this] { return release_second_read_; });
    }
    *frame = frames_[index];
    return hmw::Result<bool>{true, std::nullopt};
  }

  hmw::Outcome Seek(int64_t pts_100ns) override {
    std::lock_guard<std::mutex> lock(mutex_);
    next_ = 0;
    while (next_ < frames_.size() &&
           frames_[next_].pts_100ns < pts_100ns) {
      ++next_;
    }
    return hmw::Outcome{std::nullopt};
  }

  bool WaitForSecondRead() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(
        lock, std::chrono::seconds(2),
        [this] { return second_read_started_; });
  }

  void ReleaseSecondRead() {
    std::lock_guard<std::mutex> lock(mutex_);
    release_second_read_ = true;
    condition_.notify_all();
  }

 private:
  hmw::SourceInfo info_{2, 1, 10'000'000, 10.0, 0, false};
  std::vector<hmw::RgbaFrame> frames_;
  bool block_second_read_;
  std::mutex mutex_;
  std::condition_variable condition_;
  size_t next_ = 0;
  bool second_read_started_ = false;
  bool release_second_read_ = false;
};

class CountingLoopSource final : public hmw::FrameSource {
 public:
  const hmw::SourceInfo& info() const override { return info_; }

  hmw::Result<bool> ReadNext(hmw::RgbaFrame* frame) override {
    std::lock_guard<std::mutex> lock(mutex_);
    ++read_count_;
    if (!frame_available_) {
      return hmw::Result<bool>{false, std::nullopt};
    }
    frame_available_ = false;
    *frame = TestFrame(0, 10);
    return hmw::Result<bool>{true, std::nullopt};
  }

  hmw::Outcome Seek(int64_t) override {
    std::lock_guard<std::mutex> lock(mutex_);
    frame_available_ = true;
    return hmw::Outcome{std::nullopt};
  }

  size_t read_count() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return read_count_;
  }

 private:
  hmw::SourceInfo info_{2, 1, 1, 10.0, 0, false};
  mutable std::mutex mutex_;
  size_t read_count_ = 0;
  bool frame_available_ = true;
};

class ThrowingCreateSource final : public hmw::FrameSource {
 public:
  enum class Stage {
    kInfo,
    kRead,
  };

  explicit ThrowingCreateSource(Stage stage) : stage_(stage) {}

  const hmw::SourceInfo& info() const override {
    if (stage_ == Stage::kInfo) {
      throw std::runtime_error("info failed");
    }
    return info_;
  }

  hmw::Result<bool> ReadNext(hmw::RgbaFrame*) override {
    if (stage_ == Stage::kRead) {
      throw std::runtime_error("read failed");
    }
    return hmw::Result<bool>{false, std::nullopt};
  }

  hmw::Outcome Seek(int64_t) override {
    return hmw::Outcome{std::nullopt};
  }

 private:
  Stage stage_;
  hmw::SourceInfo info_{2, 1, 10'000'000, 10.0, 0, false};
};

class FakeTextureRegistry final : public hmw::TextureRegistry {
 public:
  int64_t RegisterPixelBufferTexture(
      hmw::PixelBufferProvider provider) override {
    provider_ = std::move(provider);
    ++register_count;
    return texture_id;
  }

  bool MarkFrameAvailable(int64_t id) override {
    ++mark_attempt_count;
    if (id != texture_id || !provider_) {
      return false;
    }
    const hmw::PixelBufferView view = provider_();
    if (view.rgba == nullptr || view.byte_count == 0) {
      return false;
    }
    last_width = view.width;
    last_height = view.height;
    last_bytes.assign(view.rgba, view.rgba + view.byte_count);
    marked_reds.push_back(last_bytes.at(0));
    ++mark_count;
    return true;
  }

  bool UnregisterTexture(int64_t id) override {
    if (id != texture_id) {
      return false;
    }
    ++unregister_count;
    return true;
  }

  const int64_t texture_id = 41;
  int register_count = 0;
  int mark_attempt_count = 0;
  int mark_count = 0;
  int unregister_count = 0;
  uint32_t last_width = 0;
  uint32_t last_height = 0;
  std::vector<uint8_t> last_bytes;
  std::vector<uint8_t> marked_reds;
  hmw::PixelBufferProvider provider_;
};

class ThrowingWorkerReadSource final : public hmw::FrameSource {
 public:
  const hmw::SourceInfo& info() const override { return info_; }

  hmw::Result<bool> ReadNext(hmw::RgbaFrame* frame) override {
    if (read_count_++ == 0) {
      *frame = TestFrame(0, 10);
      return hmw::Result<bool>{true, std::nullopt};
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      throw_attempted_ = true;
      condition_.notify_all();
    }
    throw std::runtime_error("worker read failed");
  }

  hmw::Outcome Seek(int64_t) override {
    return hmw::Outcome{std::nullopt};
  }

  bool WaitForThrowAttempt() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(
        lock, std::chrono::seconds(2),
        [this] { return throw_attempted_; });
  }

 private:
  hmw::SourceInfo info_{2, 1, 10'000'000, 10.0, 0, false};
  size_t read_count_ = 0;
  std::mutex mutex_;
  std::condition_variable condition_;
  bool throw_attempted_ = false;
};

class ThrowingDispatcher final : public hmw::PlatformDispatcher {
 public:
  bool Post(std::function<void()>) override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      throw_attempted_ = true;
      condition_.notify_all();
    }
    throw std::runtime_error("dispatcher post failed");
  }

  bool WaitForThrowAttempt() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(
        lock, std::chrono::seconds(2),
        [this] { return throw_attempted_; });
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  bool throw_attempted_ = false;
};

struct AllocationFailureGate {
  std::vector<uint8_t> Allocate(size_t byte_count) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      ++call_count;
      if (call_count == 2) {
        failure_attempted = true;
        condition.notify_all();
        throw std::bad_alloc();
      }
    }
    return std::vector<uint8_t>(byte_count);
  }

  bool WaitForFailureAttempt() {
    std::unique_lock<std::mutex> lock(mutex);
    return condition.wait_for(
        lock, std::chrono::seconds(2),
        [this] { return failure_attempted; });
  }

  std::mutex mutex;
  std::condition_variable condition;
  size_t call_count = 0;
  bool failure_attempted = false;
};

bool WaitForWorkerFailure(hmw::VideoTexturePlayer* player) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (std::chrono::steady_clock::now() < deadline) {
    if (!player->Play().ok()) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return false;
}

class QueueDispatcher final : public hmw::PlatformDispatcher {
 public:
  bool Post(std::function<void()> callback) override {
    std::lock_guard<std::mutex> lock(mutex_);
    callbacks_.push_back(std::move(callback));
    condition_.notify_all();
    return true;
  }

  bool WaitForCallbacks(size_t count) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(
        lock, std::chrono::seconds(2),
        [this, count] { return callbacks_.size() >= count; });
  }

  void RunAll() {
    std::vector<std::function<void()>> callbacks;
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
  std::vector<std::function<void()>> callbacks_;
};

}  // namespace

HMW_TEST(player_create_publishes_first_rgba_frame_and_alpha_before_success) {
  FakeTextureRegistry registry;
  QueueDispatcher dispatcher;
  auto source = std::make_unique<FakeFrameSource>(
      std::vector<hmw::RgbaFrame>{hmw::RgbaFrame{
          2, 1, 0, 1'000'000,
          {10, 20, 30, 40, 50, 60, 70, 80}}});

  auto created =
      hmw::VideoTexturePlayer::Create(std::move(source), registry, dispatcher);

  HMW_EXPECT(created.ok());
  HMW_EXPECT(registry.register_count == 1);
  HMW_EXPECT(registry.mark_count == 1);
  HMW_EXPECT(registry.last_width == 2);
  HMW_EXPECT(registry.last_height == 1);
  HMW_EXPECT(registry.last_bytes ==
             std::vector<uint8_t>({10, 20, 30, 40, 50, 60, 70, 80}));
}

HMW_TEST(player_provider_returns_owned_immutable_snapshot) {
  FakeTextureRegistry registry;
  QueueDispatcher dispatcher;
  auto source = std::make_unique<FakeFrameSource>(
      std::vector<hmw::RgbaFrame>{TestFrame(0, 10)});
  auto created =
      hmw::VideoTexturePlayer::Create(std::move(source), registry, dispatcher);
  HMW_EXPECT(created.ok());
  if (!created.ok()) {
    return;
  }
  std::unique_ptr<hmw::VideoTexturePlayer> player =
      std::move(*created.value);

  const hmw::PixelBufferView snapshot = registry.provider_();
  HMW_EXPECT(snapshot.owner != nullptr);
  HMW_EXPECT(snapshot.rgba == snapshot.owner->data());
  HMW_EXPECT(player->Dispose().ok());
  HMW_EXPECT(*snapshot.owner ==
             std::vector<uint8_t>({10, 20, 30, 255,
                                   40, 50, 60, 255}));
}

HMW_TEST(player_duration_rounds_positive_100ns_up_to_milliseconds) {
  struct DurationCase {
    int64_t duration_100ns;
    int64_t expected_ms;
  };
  const DurationCase cases[] = {
      {1, 1},
      {9'999, 1},
      {(std::numeric_limits<int64_t>::max)(), 922'337'203'685'478},
  };
  for (const DurationCase& test_case : cases) {
    FakeTextureRegistry registry;
    QueueDispatcher dispatcher;
    auto source = std::make_unique<FakeFrameSource>(
        std::vector<hmw::RgbaFrame>{TestFrame(0, 10)}, false,
        test_case.duration_100ns);
    auto created = hmw::VideoTexturePlayer::Create(
        std::move(source), registry, dispatcher);
    HMW_EXPECT(created.ok());
    if (created.ok()) {
      HMW_EXPECT((*created.value)->duration_ms() ==
                 test_case.expected_ms);
    }
  }
}

HMW_TEST(player_sub_millisecond_video_does_not_hot_loop_at_eof) {
  FakeTextureRegistry registry;
  QueueDispatcher dispatcher;
  auto source = std::make_unique<CountingLoopSource>();
  CountingLoopSource* source_ptr = source.get();
  auto created = hmw::VideoTexturePlayer::Create(
      std::move(source), registry, dispatcher);
  HMW_EXPECT(created.ok());
  if (!created.ok()) {
    return;
  }
  std::unique_ptr<hmw::VideoTexturePlayer> player =
      std::move(*created.value);

  HMW_EXPECT(player->Play().ok());
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  HMW_EXPECT(player->Pause().ok());
  HMW_EXPECT(source_ptr->read_count() <= 200);
  HMW_EXPECT(player->Dispose().ok());
}

HMW_TEST(player_create_translates_source_exceptions_to_io_error) {
  const ThrowingCreateSource::Stage stages[] = {
      ThrowingCreateSource::Stage::kInfo,
      ThrowingCreateSource::Stage::kRead,
  };
  for (ThrowingCreateSource::Stage stage : stages) {
    FakeTextureRegistry registry;
    QueueDispatcher dispatcher;
    hmw::Result<std::unique_ptr<hmw::VideoTexturePlayer>> created;
    bool threw = false;
    try {
      created = hmw::VideoTexturePlayer::Create(
          std::make_unique<ThrowingCreateSource>(stage),
          registry, dispatcher);
    } catch (...) {
      threw = true;
    }

    HMW_EXPECT(!threw);
    HMW_EXPECT(!created.ok());
    HMW_EXPECT(created.error.has_value());
    if (created.error.has_value()) {
      HMW_EXPECT(created.error->status == hmw::Status::kIoError);
    }
    HMW_EXPECT(registry.register_count == 0);
    HMW_EXPECT(registry.unregister_count == 0);
  }
}

HMW_TEST(player_create_translates_rgba_allocation_failure_to_io_error) {
  FakeTextureRegistry registry;
  QueueDispatcher dispatcher;
  hmw::VideoPlayerDependencies dependencies;
  dependencies.allocate_rgba =
      [](size_t) -> std::vector<uint8_t> {
    throw std::bad_alloc();
  };

  bool threw = false;
  hmw::Result<std::unique_ptr<hmw::VideoTexturePlayer>> created;
  try {
    created = hmw::VideoTexturePlayer::Create(
        std::make_unique<FakeFrameSource>(
            std::vector<hmw::RgbaFrame>{TestFrame(0, 10)}),
        registry, dispatcher, std::move(dependencies));
  } catch (...) {
    threw = true;
  }

  HMW_EXPECT(!threw);
  HMW_EXPECT(!created.ok());
  HMW_EXPECT(created.error.has_value());
  if (created.error.has_value()) {
    HMW_EXPECT(created.error->status == hmw::Status::kIoError);
  }
  HMW_EXPECT(registry.register_count == 0);
}

HMW_TEST(player_create_translates_worker_start_failure_and_rolls_back_texture) {
  FakeTextureRegistry registry;
  QueueDispatcher dispatcher;
  hmw::VideoPlayerDependencies dependencies;
  dependencies.start_worker =
      [](std::function<void()>) -> std::thread {
    throw std::system_error(
        std::make_error_code(std::errc::resource_unavailable_try_again));
  };

  bool threw = false;
  hmw::Result<std::unique_ptr<hmw::VideoTexturePlayer>> created;
  try {
    created = hmw::VideoTexturePlayer::Create(
        std::make_unique<FakeFrameSource>(
            std::vector<hmw::RgbaFrame>{TestFrame(0, 10)}),
        registry, dispatcher, std::move(dependencies));
  } catch (...) {
    threw = true;
  }

  HMW_EXPECT(!threw);
  HMW_EXPECT(!created.ok());
  HMW_EXPECT(created.error.has_value());
  if (created.error.has_value()) {
    HMW_EXPECT(created.error->status == hmw::Status::kInvalidState);
  }
  HMW_EXPECT(registry.register_count == 1);
  HMW_EXPECT(registry.mark_count == 1);
  HMW_EXPECT(registry.unregister_count == 1);
}

HMW_TEST(player_worker_translates_source_exception_and_remains_disposable) {
  FakeTextureRegistry registry;
  QueueDispatcher dispatcher;
  auto source = std::make_unique<ThrowingWorkerReadSource>();
  ThrowingWorkerReadSource* source_ptr = source.get();
  auto created = hmw::VideoTexturePlayer::Create(
      std::move(source), registry, dispatcher);
  HMW_EXPECT(created.ok());
  if (!created.ok()) {
    return;
  }
  std::unique_ptr<hmw::VideoTexturePlayer> player =
      std::move(*created.value);

  HMW_EXPECT(player->Play().ok());
  HMW_EXPECT(source_ptr->WaitForThrowAttempt());
  HMW_EXPECT(WaitForWorkerFailure(player.get()));
  HMW_EXPECT(player->Dispose().ok());
  HMW_EXPECT(registry.unregister_count == 1);
}

HMW_TEST(player_worker_translates_dispatcher_exception_and_remains_disposable) {
  FakeTextureRegistry registry;
  ThrowingDispatcher dispatcher;
  auto source = std::make_unique<FakeFrameSource>(
      std::vector<hmw::RgbaFrame>{TestFrame(0, 10), TestFrame(0, 80)});
  auto created = hmw::VideoTexturePlayer::Create(
      std::move(source), registry, dispatcher);
  HMW_EXPECT(created.ok());
  if (!created.ok()) {
    return;
  }
  std::unique_ptr<hmw::VideoTexturePlayer> player =
      std::move(*created.value);

  HMW_EXPECT(player->Play().ok());
  HMW_EXPECT(dispatcher.WaitForThrowAttempt());
  HMW_EXPECT(WaitForWorkerFailure(player.get()));
  HMW_EXPECT(player->Dispose().ok());
  HMW_EXPECT(registry.unregister_count == 1);
}

HMW_TEST(player_worker_translates_allocation_failure_and_remains_disposable) {
  FakeTextureRegistry registry;
  QueueDispatcher dispatcher;
  auto allocation_gate = std::make_shared<AllocationFailureGate>();
  hmw::VideoPlayerDependencies dependencies;
  dependencies.allocate_rgba =
      [allocation_gate](size_t byte_count) {
    return allocation_gate->Allocate(byte_count);
  };
  auto source = std::make_unique<FakeFrameSource>(
      std::vector<hmw::RgbaFrame>{TestFrame(0, 10), TestFrame(0, 80)});
  auto created = hmw::VideoTexturePlayer::Create(
      std::move(source), registry, dispatcher, std::move(dependencies));
  HMW_EXPECT(created.ok());
  if (!created.ok()) {
    return;
  }
  std::unique_ptr<hmw::VideoTexturePlayer> player =
      std::move(*created.value);

  HMW_EXPECT(player->Play().ok());
  HMW_EXPECT(allocation_gate->WaitForFailureAttempt());
  HMW_EXPECT(WaitForWorkerFailure(player.get()));
  HMW_EXPECT(player->Dispose().ok());
  HMW_EXPECT(registry.unregister_count == 1);
}

HMW_TEST(player_seek_flushes_old_generation) {
  FakeTextureRegistry registry;
  QueueDispatcher dispatcher;
  auto source = std::make_unique<FakeFrameSource>(
      std::vector<hmw::RgbaFrame>{
          TestFrame(0, 10),
          TestFrame(1'000'000, 80),
          TestFrame(5'000'000, 120),
      },
      true);
  FakeFrameSource* source_ptr = source.get();
  auto created =
      hmw::VideoTexturePlayer::Create(std::move(source), registry, dispatcher);
  HMW_EXPECT(created.ok());
  if (!created.ok()) {
    return;
  }
  std::unique_ptr<hmw::VideoTexturePlayer> player =
      std::move(*created.value);

  HMW_EXPECT(player->Play().ok());
  HMW_EXPECT(source_ptr->WaitForSecondRead());
  HMW_EXPECT(player->Seek(500).ok());
  HMW_EXPECT(player->Pause().ok());
  source_ptr->ReleaseSecondRead();
  HMW_EXPECT(dispatcher.WaitForCallbacks(1));
  dispatcher.RunAll();

  HMW_EXPECT(registry.marked_reds ==
             std::vector<uint8_t>({10, 120}));
}
HMW_TEST(player_dispose_unregisters_texture_and_drops_callbacks) {
  FakeTextureRegistry registry;
  QueueDispatcher dispatcher;
  auto source = std::make_unique<FakeFrameSource>(
      std::vector<hmw::RgbaFrame>{
          TestFrame(0, 10),
          TestFrame(0, 80),
      });
  auto created =
      hmw::VideoTexturePlayer::Create(std::move(source), registry, dispatcher);
  HMW_EXPECT(created.ok());
  if (!created.ok()) {
    return;
  }
  std::unique_ptr<hmw::VideoTexturePlayer> player =
      std::move(*created.value);

  HMW_EXPECT(player->Play().ok());
  HMW_EXPECT(dispatcher.WaitForCallbacks(1));
  HMW_EXPECT(player->Dispose().ok());
  HMW_EXPECT(registry.unregister_count == 1);

  const hmw::PixelBufferView disposed_view = registry.provider_();
  HMW_EXPECT(disposed_view.rgba == nullptr);
  HMW_EXPECT(disposed_view.byte_count == 0);

  dispatcher.RunAll();
  HMW_EXPECT(registry.mark_attempt_count == 1);
  HMW_EXPECT(registry.mark_count == 1);
  HMW_EXPECT(player->Dispose().ok());
  HMW_EXPECT(registry.unregister_count == 1);
}
