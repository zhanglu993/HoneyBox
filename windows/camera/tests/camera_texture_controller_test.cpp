#include "honey_camera_windows/encoder_channel.h"

#include "test_support.h"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
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

hcw::CameraFrame TextureFrame(uint8_t marker) {
  return {2, 1, 10'000,
          std::make_shared<const std::vector<uint8_t>>(
              std::vector<uint8_t>{marker, 0, 0, 255,
                                   marker, 0, 0, 255})};
}

class SourceState final {
 public:
  void Push(hcw::CameraFrame frame) {
    std::lock_guard<std::mutex> lock(mutex_);
    frames_.push_back(std::move(frame));
    condition_.notify_all();
  }

  bool WaitForRead(size_t minimum = 1) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s,
                               [&] { return reads_ >= minimum; });
  }

  hmw::Result<hcw::CameraFrame> ReadNext() {
    std::unique_lock<std::mutex> lock(mutex_);
    ++reads_;
    condition_.notify_all();
    condition_.wait(lock,
                    [&] { return stopped_ || !frames_.empty(); });
    if (stopped_) {
      return {std::nullopt,
              hmw::Error{hmw::Status::kCancelled, "source stopped"}};
    }
    hcw::CameraFrame frame = std::move(frames_.front());
    frames_.pop_front();
    return {std::move(frame), std::nullopt};
  }

  void Stop() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    stopped_ = true;
    condition_.notify_all();
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<hcw::CameraFrame> frames_;
  size_t reads_ = 0;
  bool stopped_ = false;
};

class Source final : public hcw::CameraFrameSource {
 public:
  explicit Source(std::shared_ptr<SourceState> state)
      : state_(std::move(state)) {}
  hmw::Result<hcw::CameraFrame> ReadNext() override {
    return state_->ReadNext();
  }
  void RequestStop() noexcept override { state_->Stop(); }

 private:
  std::shared_ptr<SourceState> state_;
};

class QueueDispatcher final : public hmw::PlatformDispatcher {
 public:
  bool Post(std::function<void()> callback) override {
    std::lock_guard<std::mutex> lock(mutex_);
    callbacks_.push_back(std::move(callback));
    condition_.notify_all();
    return true;
  }

  bool WaitForPending(size_t minimum = 1) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s, [&] {
      return callbacks_.size() >= minimum;
    });
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

class RecordingRegistry final : public hmw::TextureRegistry {
 public:
  int64_t RegisterPixelBufferTexture(
      hmw::PixelBufferProvider provider) override {
    threads.push_back(std::this_thread::get_id());
    events.push_back("register");
    providers.push_back(std::move(provider));
    if (!Valid(providers.back()())) {
      return -1;
    }
    const int64_t id = next_id++;
    ids.push_back(id);
    return id;
  }

  bool MarkFrameAvailable(int64_t id) override {
    threads.push_back(std::this_thread::get_id());
    events.push_back("mark");
    ++marks;
    const size_t index = Find(id);
    return index < providers.size() && Valid(providers[index]());
  }

  bool UnregisterTexture(int64_t id) override {
    threads.push_back(std::this_thread::get_id());
    events.push_back("unregister");
    unregistered.push_back(id);
    return true;
  }

  hmw::PixelBufferView Snapshot(int64_t id) const {
    const size_t index = Find(id);
    return index < providers.size() ? providers[index]()
                                    : hmw::PixelBufferView{};
  }

  static bool Valid(const hmw::PixelBufferView& view) {
    return view.owner && view.bgra == view.owner->data() &&
           view.width == 2 && view.height == 1 && view.byte_count == 8;
  }

  size_t Find(int64_t id) const {
    for (size_t index = 0; index < ids.size(); ++index) {
      if (ids[index] == id) {
        return index;
      }
    }
    return providers.size();
  }

  int64_t next_id = 41;
  size_t marks = 0;
  std::vector<int64_t> ids;
  std::vector<int64_t> unregistered;
  std::vector<hmw::PixelBufferProvider> providers;
  std::vector<std::thread::id> threads;
  std::vector<std::string> events;
};

hcw::CameraSourceFactory Factory(const std::shared_ptr<SourceState>& state) {
  return [state](const hcw::CameraPreviewConfig&) {
    return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
        std::make_unique<Source>(state), std::nullopt};
  };
}

}  // namespace

HMW_TEST(camera_texture_registers_once_marks_frames_and_readies_once) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  std::vector<hcw::CameraReady> ready;
  std::vector<hmw::Error> errors;
  const std::thread::id platform_thread = std::this_thread::get_id();
  hcw::CameraTextureController controller(registry, dispatcher,
                                          Factory(source));

  HMW_EXPECT(controller.Open(
      {2, 1, 15},
      {[&](hcw::CameraReady event) { ready.push_back(event); },
       [&](hmw::Error error) { errors.push_back(std::move(error)); }})
                 .ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(11));
  HMW_EXPECT(dispatcher.WaitForPending());
  HMW_EXPECT(registry.ids.empty());
  HMW_EXPECT(ready.empty());
  dispatcher.Drain();
  HMW_EXPECT(registry.ids == std::vector<int64_t>({41}));
  HMW_EXPECT(registry.marks == 1);
  HMW_EXPECT(ready.size() == 1);
  if (!ready.empty()) {
    HMW_EXPECT(ready.front().texture_id == 41);
    HMW_EXPECT(ready.front().width == 2);
    HMW_EXPECT(ready.front().height == 1);
  }

  source->Push(TextureFrame(22));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();
  HMW_EXPECT(registry.ids.size() == 1);
  HMW_EXPECT(registry.marks == 2);
  HMW_EXPECT(ready.size() == 1);
  HMW_EXPECT(errors.empty());
  for (const std::thread::id thread : registry.threads) {
    HMW_EXPECT(thread == platform_thread);
  }
  HMW_EXPECT(controller.Close().ok());
  dispatcher.Drain();
}

HMW_TEST(camera_texture_snapshot_owner_survives_later_flutter_reads) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  hcw::CameraTextureController controller(registry, dispatcher,
                                          Factory(source));
  HMW_EXPECT(controller.Open({2, 1, 15}, {}).ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(31));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();
  const hmw::PixelBufferView first = registry.Snapshot(41);
  HMW_EXPECT(RecordingRegistry::Valid(first));
  HMW_EXPECT(first.owner && first.owner->at(0) == 31);

  source->Push(TextureFrame(47));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();
  const hmw::PixelBufferView second = registry.Snapshot(41);
  HMW_EXPECT(RecordingRegistry::Valid(second));
  HMW_EXPECT(second.owner && second.owner->at(0) == 47);
  HMW_EXPECT(first.owner != second.owner);
  HMW_EXPECT(first.owner && first.owner->at(0) == 31);
  HMW_EXPECT(controller.Close().ok());
  dispatcher.Drain();
}

HMW_TEST(camera_texture_close_suppresses_queued_mark_and_unregisters_once) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  size_t ready_count = 0;
  hcw::CameraTextureController controller(registry, dispatcher,
                                          Factory(source));
  HMW_EXPECT(controller.Open(
      {2, 1, 15},
      {[&](hcw::CameraReady) { ++ready_count; }, {}}).ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(1));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();

  source->Push(TextureFrame(2));
  HMW_EXPECT(dispatcher.WaitForPending());
  HMW_EXPECT(controller.Close().ok());
  dispatcher.Drain();
  HMW_EXPECT(registry.marks == 1);
  HMW_EXPECT(registry.unregistered == std::vector<int64_t>({41}));
  HMW_EXPECT(ready_count == 1);
  HMW_EXPECT(registry.events ==
             std::vector<std::string>({"register", "mark", "unregister"}));
  HMW_EXPECT(controller.Close().ok());
  dispatcher.Drain();
  HMW_EXPECT(registry.unregistered.size() == 1);
}

HMW_TEST(camera_texture_reopen_unregisters_old_before_registering_new) {
  auto first = std::make_shared<SourceState>();
  auto second = std::make_shared<SourceState>();
  size_t factory_calls = 0;
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  std::vector<int64_t> ready_ids;
  hcw::CameraTextureController controller(
      registry, dispatcher,
      [&](const hcw::CameraPreviewConfig&) {
        const auto state = factory_calls++ == 0 ? first : second;
        return hmw::Result<std::unique_ptr<hcw::CameraFrameSource>>{
            std::make_unique<Source>(state), std::nullopt};
      });
  const hcw::CameraControllerCallbacks callbacks{
      [&](hcw::CameraReady event) { ready_ids.push_back(event.texture_id); },
      {}};

  HMW_EXPECT(controller.Open({2, 1, 15}, callbacks).ok());
  HMW_EXPECT(first->WaitForRead());
  first->Push(TextureFrame(3));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();
  HMW_EXPECT(controller.Open({2, 1, 15}, callbacks).ok());
  HMW_EXPECT(second->WaitForRead());
  second->Push(TextureFrame(4));
  HMW_EXPECT(dispatcher.WaitForPending(2));
  dispatcher.Drain();

  HMW_EXPECT(registry.ids == std::vector<int64_t>({41, 42}));
  HMW_EXPECT(registry.unregistered == std::vector<int64_t>({41}));
  HMW_EXPECT(ready_ids == std::vector<int64_t>({41, 42}));
  HMW_EXPECT(registry.events == std::vector<std::string>(
                                    {"register", "mark", "unregister",
                                     "register", "mark"}));
  HMW_EXPECT(controller.Close().ok());
  dispatcher.Drain();
}

HMW_TEST(camera_texture_destruction_suppresses_queued_ready_callback) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  size_t ready_count = 0;
  {
    auto controller = std::make_unique<hcw::CameraTextureController>(
        registry, dispatcher, Factory(source));
    HMW_EXPECT(controller->Open(
        {2, 1, 15},
        {[&](hcw::CameraReady) { ++ready_count; }, {}}).ok());
    HMW_EXPECT(source->WaitForRead());
    source->Push(TextureFrame(5));
    HMW_EXPECT(dispatcher.WaitForPending());
    controller.reset();
  }
  dispatcher.Drain();
  HMW_EXPECT(registry.ids.empty());
  HMW_EXPECT(registry.unregistered.empty());
  HMW_EXPECT(ready_count == 0);
}

HMW_TEST(camera_texture_invalid_bgra_emits_one_platform_thread_error) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  std::vector<hmw::Error> errors;
  std::vector<std::thread::id> error_threads;
  hcw::CameraTextureController controller(registry, dispatcher,
                                          Factory(source));
  HMW_EXPECT(controller.Open(
      {2, 1, 15},
      {{}, [&](hmw::Error error) {
         errors.push_back(std::move(error));
         error_threads.push_back(std::this_thread::get_id());
       }}).ok());
  HMW_EXPECT(source->WaitForRead());
  hcw::CameraFrame short_frame = TextureFrame(7);
  short_frame.bgra =
      std::make_shared<const std::vector<uint8_t>>(std::vector<uint8_t>{7});
  source->Push(short_frame);
  source->Push(short_frame);
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();
  HMW_EXPECT(errors.size() == 1);
  HMW_EXPECT(errors.front().status == hmw::Status::kIoError);
  HMW_EXPECT(error_threads ==
             std::vector<std::thread::id>({std::this_thread::get_id()}));
  HMW_EXPECT(registry.ids.empty());
  HMW_EXPECT(controller.Close().ok());
  dispatcher.Drain();
}
