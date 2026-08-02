#include "video_texture_player.h"

#include "honey_media_windows/media_source.h"
#include "honey_media_windows/platform_dispatcher.h"
#include "honey_media_windows/texture_registry.h"
#include "test_support.h"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
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
                           bool block_second_read = false)
      : frames_(std::move(frames)),
        block_second_read_(block_second_read) {}

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
    if (view.bgra == nullptr || view.byte_count == 0) {
      return false;
    }
    last_width = view.width;
    last_height = view.height;
    last_bytes.assign(view.bgra, view.bgra + view.byte_count);
    marked_reds.push_back(last_bytes.at(2));
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

HMW_TEST(player_create_publishes_first_frame_before_success) {
  FakeTextureRegistry registry;
  QueueDispatcher dispatcher;
  auto source = std::make_unique<FakeFrameSource>(
      std::vector<hmw::RgbaFrame>{TestFrame(0, 10)});

  auto created =
      hmw::VideoTexturePlayer::Create(std::move(source), registry, dispatcher);

  HMW_EXPECT(created.ok());
  HMW_EXPECT(registry.register_count == 1);
  HMW_EXPECT(registry.mark_count == 1);
  HMW_EXPECT(registry.last_width == 2);
  HMW_EXPECT(registry.last_height == 1);
  HMW_EXPECT(registry.last_bytes ==
             std::vector<uint8_t>({30, 20, 10, 255, 60, 50, 40, 255}));
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
  HMW_EXPECT(disposed_view.bgra == nullptr);
  HMW_EXPECT(disposed_view.byte_count == 0);

  dispatcher.RunAll();
  HMW_EXPECT(registry.mark_attempt_count == 1);
  HMW_EXPECT(registry.mark_count == 1);
  HMW_EXPECT(player->Dispose().ok());
  HMW_EXPECT(registry.unregister_count == 1);
}
