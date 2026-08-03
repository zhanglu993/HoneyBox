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

#include "honey_camera_windows/encoder_channel.h"
#include "test_support.h"

namespace {

using namespace std::chrono_literals;

hcw::CameraFrame TextureFrame(uint8_t marker) {
  return {2, 1, 10'000,
          std::make_shared<const std::vector<uint8_t>>(
              std::vector<uint8_t>{marker, 0, 0, 255, marker, 0, 0, 255})};
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
    return condition_.wait_for(lock, 2s, [&] { return reads_ >= minimum; });
  }

  hmw::Result<hcw::CameraFrame> ReadNext() {
    std::unique_lock<std::mutex> lock(mutex_);
    ++reads_;
    condition_.notify_all();
    condition_.wait(lock, [&] { return stopped_ || !frames_.empty(); });
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
    if (reject_next_post) {
      reject_next_post = false;
      return false;
    }
    if (run_inline) {
      callback();
      return true;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    callbacks_.push_back(std::move(callback));
    condition_.notify_all();
    return true;
  }

  bool WaitForPending(size_t minimum = 1) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s,
                               [&] { return callbacks_.size() >= minimum; });
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
  void DropPending() {
    std::deque<std::function<void()>> dropped;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      dropped.swap(callbacks_);
    }
  }

  bool reject_next_post = false;
  bool run_inline = false;

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
    if (on_register) {
      on_register();
    }
    return id;
  }

  bool MarkFrameAvailable(int64_t id) override {
    threads.push_back(std::this_thread::get_id());
    events.push_back("mark");
    ++marks;
    if (fail_next_mark) {
      fail_next_mark = false;
      return false;
    }
    const size_t index = Find(id);
    return index < providers.size() && Valid(providers[index]());
  }

  bool UnregisterTexture(int64_t id) override {
    threads.push_back(std::this_thread::get_id());
    events.push_back("unregister");
    ++unregister_attempts;
    if (reject_unregister || reject_next_unregister) {
      reject_next_unregister = false;
      return false;
    }
    if (on_unregister) {
      on_unregister();
    }
    unregistered.push_back(id);
    const size_t index = Find(id);
    if (index < providers.size()) {
      providers[index] = {};
    }

    return true;
  }

  hmw::PixelBufferView Snapshot(int64_t id) const {
    const size_t index = Find(id);
    return index < providers.size() ? providers[index]()
                                    : hmw::PixelBufferView{};
  }

  static bool Valid(const hmw::PixelBufferView& view) {
    return view.owner && view.bgra == view.owner->data() && view.width == 2 &&
           view.height == 1 && view.byte_count == 8;
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
  size_t unregister_attempts = 0;
  bool fail_next_mark = false;
  bool reject_next_unregister = false;
  std::function<void()> on_register;
  bool reject_unregister = false;
  std::vector<int64_t> unregistered;
  std::function<void()> on_unregister;
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

std::shared_ptr<hcw::CameraTextureCleanupCoordinator> Cleanup(
    hmw::TextureRegistry& registry, hmw::PlatformDispatcher& dispatcher) {
  return hcw::CameraTextureCleanupCoordinator::Create(registry, dispatcher);
}

}  // namespace

HMW_TEST(camera_texture_registers_once_marks_frames_and_readies_once) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  std::vector<hcw::CameraReady> ready;
  std::vector<hmw::Error> errors;
  const std::thread::id platform_thread = std::this_thread::get_id();
  hcw::CameraTextureController controller(Cleanup(registry, dispatcher),
                                          Factory(source));

  HMW_EXPECT(
      controller
          .Open({2, 1, 15},
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
  hcw::CameraTextureController controller(Cleanup(registry, dispatcher),
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
  hcw::CameraTextureController controller(Cleanup(registry, dispatcher),
                                          Factory(source));
  HMW_EXPECT(
      controller
          .Open({2, 1, 15}, {[&](hcw::CameraReady) { ++ready_count; }, {}})
          .ok());
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
      Cleanup(registry, dispatcher), [&](const hcw::CameraPreviewConfig&) {
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
  HMW_EXPECT(registry.events ==
             std::vector<std::string>(
                 {"register", "mark", "unregister", "register", "mark"}));
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
        Cleanup(registry, dispatcher), Factory(source));
    HMW_EXPECT(
        controller
            ->Open({2, 1, 15}, {[&](hcw::CameraReady) { ++ready_count; }, {}})
            .ok());
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

HMW_TEST(
    camera_texture_registered_texture_unregisters_after_controller_destruction) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  auto controller = std::make_unique<hcw::CameraTextureController>(
      Cleanup(registry, dispatcher), Factory(source));

  HMW_EXPECT(controller->Open({2, 1, 15}, {}).ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(6));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();
  HMW_EXPECT(registry.ids == std::vector<int64_t>({41}));

  controller.reset();
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();
  HMW_EXPECT(registry.unregister_attempts == 1);
  HMW_EXPECT(registry.unregistered == std::vector<int64_t>({41}));
}

HMW_TEST(
    camera_texture_stale_registration_keeps_rejected_unregister_for_retry) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  auto controller = std::make_unique<hcw::CameraTextureController>(
      Cleanup(registry, dispatcher), Factory(source));
  registry.reject_next_unregister = true;
  registry.on_register = [&] {
    registry.on_register = {};
    HMW_EXPECT(controller->Close().ok());
  };

  HMW_EXPECT(controller->Open({2, 1, 15}, {}).ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(7));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();
  HMW_EXPECT(registry.unregister_attempts == 1);
  HMW_EXPECT(registry.unregistered.empty());

  HMW_EXPECT(controller->Close().ok());
  dispatcher.Drain();
  HMW_EXPECT(registry.unregister_attempts == 2);
  HMW_EXPECT(registry.unregistered == std::vector<int64_t>({41}));
  HMW_EXPECT(controller->Close().ok());
  dispatcher.Drain();
  HMW_EXPECT(registry.unregister_attempts == 2);
}

HMW_TEST(
    camera_texture_first_mark_failure_keeps_rejected_unregister_for_retry) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  size_t ready_count = 0;
  hcw::CameraTextureController controller(Cleanup(registry, dispatcher),
                                          Factory(source));
  registry.fail_next_mark = true;
  registry.reject_next_unregister = true;

  HMW_EXPECT(
      controller
          .Open({2, 1, 15}, {[&](hcw::CameraReady) { ++ready_count; }, {}})
          .ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(8));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();
  HMW_EXPECT(ready_count == 0);
  HMW_EXPECT(registry.unregister_attempts == 1);
  HMW_EXPECT(registry.unregistered.empty());

  HMW_EXPECT(controller.Close().ok());
  dispatcher.Drain();
  HMW_EXPECT(registry.unregister_attempts == 2);
  HMW_EXPECT(registry.unregistered == std::vector<int64_t>({41}));
  HMW_EXPECT(controller.Close().ok());
  dispatcher.Drain();
  HMW_EXPECT(registry.unregister_attempts == 2);
}

HMW_TEST(
    camera_texture_ready_callback_may_destroy_controller_before_unregister) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  size_t ready_count = 0;
  auto controller = std::make_unique<hcw::CameraTextureController>(
      Cleanup(registry, dispatcher), Factory(source));

  HMW_EXPECT(controller
                 ->Open({2, 1, 15}, {[&](hcw::CameraReady) {
                                       ++ready_count;
                                       controller.reset();
                                     },
                                     {}})
                 .ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(9));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();

  HMW_EXPECT(ready_count == 1);
  HMW_EXPECT(controller == nullptr);
  HMW_EXPECT(registry.unregister_attempts == 1);
  HMW_EXPECT(registry.unregistered == std::vector<int64_t>({41}));
}

HMW_TEST(camera_texture_dispatch_rejection_retains_unregister_for_retry) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  hcw::CameraTextureController controller(Cleanup(registry, dispatcher),
                                          Factory(source));

  HMW_EXPECT(controller.Open({2, 1, 15}, {}).ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(10));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();

  dispatcher.reject_next_post = true;
  HMW_EXPECT(!controller.Close().ok());
  HMW_EXPECT(registry.unregister_attempts == 0);
  HMW_EXPECT(registry.unregistered.empty());
  HMW_EXPECT(controller.Close().ok());
  dispatcher.Drain();
  HMW_EXPECT(registry.unregister_attempts == 1);
  HMW_EXPECT(registry.unregistered == std::vector<int64_t>({41}));
}

HMW_TEST(camera_texture_persistent_unregister_rejection_is_bounded) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  hcw::CameraTextureController controller(Cleanup(registry, dispatcher),
                                          Factory(source));

  HMW_EXPECT(controller.Open({2, 1, 15}, {}).ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(11));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();

  dispatcher.run_inline = true;
  registry.reject_unregister = true;
  HMW_EXPECT(controller.Close().ok());
  HMW_EXPECT(registry.unregister_attempts == 1);
  HMW_EXPECT(controller.Close().ok());
  HMW_EXPECT(registry.unregister_attempts == 2);

  registry.reject_unregister = false;
  HMW_EXPECT(controller.Close().ok());
  HMW_EXPECT(registry.unregister_attempts == 3);
  HMW_EXPECT(registry.unregistered == std::vector<int64_t>({41}));
  HMW_EXPECT(controller.Close().ok());
  HMW_EXPECT(registry.unregister_attempts == 3);
}

HMW_TEST(camera_texture_dropped_cleanup_task_keeps_registry_owned_retry_lease) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  auto cleanup =
      hcw::CameraTextureCleanupCoordinator::Create(registry, dispatcher);
  std::weak_ptr<hcw::CameraTextureCleanupCoordinator> cleanup_weak = cleanup;
  auto controller =
      std::make_unique<hcw::CameraTextureController>(cleanup, Factory(source));

  HMW_EXPECT(controller->Open({2, 1, 15}, {}).ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(12));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();

  cleanup.reset();
  controller.reset();
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.DropPending();
  HMW_EXPECT(!cleanup_weak.expired());

  auto retry_owner = cleanup_weak.lock();
  HMW_EXPECT(retry_owner != nullptr);
  HMW_EXPECT(retry_owner->RetryPending().ok());
  dispatcher.Drain();
  HMW_EXPECT(registry.unregister_attempts == 1);
  HMW_EXPECT(registry.unregistered == std::vector<int64_t>({41}));
  retry_owner.reset();
  HMW_EXPECT(cleanup_weak.expired());
}

HMW_TEST(camera_texture_cleanup_false_after_destruction_remains_retryable) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  auto cleanup =
      hcw::CameraTextureCleanupCoordinator::Create(registry, dispatcher);
  std::weak_ptr<hcw::CameraTextureCleanupCoordinator> cleanup_weak = cleanup;
  auto controller =
      std::make_unique<hcw::CameraTextureController>(cleanup, Factory(source));

  HMW_EXPECT(controller->Open({2, 1, 15}, {}).ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(13));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();

  registry.reject_next_unregister = true;
  cleanup.reset();
  controller.reset();
  dispatcher.Drain();
  HMW_EXPECT(registry.unregister_attempts == 1);
  HMW_EXPECT(registry.unregistered.empty());
  HMW_EXPECT(!cleanup_weak.expired());

  auto retry_owner = cleanup_weak.lock();
  HMW_EXPECT(retry_owner != nullptr);
  HMW_EXPECT(retry_owner->RetryPending().ok());
  dispatcher.Drain();
  HMW_EXPECT(registry.unregister_attempts == 2);
  HMW_EXPECT(registry.unregistered == std::vector<int64_t>({41}));
  retry_owner.reset();
  HMW_EXPECT(cleanup_weak.expired());
}

HMW_TEST(camera_texture_cleanup_shutdown_precedes_dependency_teardown) {
  auto source = std::make_shared<SourceState>();
  auto registry = std::make_unique<RecordingRegistry>();
  auto dispatcher = std::make_unique<QueueDispatcher>();
  auto cleanup =
      hcw::CameraTextureCleanupCoordinator::Create(*registry, *dispatcher);
  auto controller =
      std::make_unique<hcw::CameraTextureController>(cleanup, Factory(source));

  HMW_EXPECT(controller->Open({2, 1, 15}, {}).ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(14));
  HMW_EXPECT(dispatcher->WaitForPending());
  dispatcher->Drain();
  controller.reset();
  HMW_EXPECT(dispatcher->WaitForPending());

  HMW_EXPECT(cleanup->Shutdown().ok());
  HMW_EXPECT(cleanup->Shutdown().ok());
  dispatcher.reset();
  registry.reset();
  HMW_EXPECT(!cleanup->RetryPending().ok());
}

HMW_TEST(camera_texture_cleanup_reentrant_shutdown_retries_after_operation) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  auto cleanup =
      hcw::CameraTextureCleanupCoordinator::Create(registry, dispatcher);
  hcw::CameraTextureController controller(cleanup, Factory(source));

  HMW_EXPECT(controller.Open({2, 1, 15}, {}).ok());
  HMW_EXPECT(source->WaitForRead());
  source->Push(TextureFrame(15));
  HMW_EXPECT(dispatcher.WaitForPending());
  dispatcher.Drain();

  bool reentrant_called = false;
  bool reentrant_succeeded = true;
  dispatcher.run_inline = true;
  bool inside_unregister = false;
  bool retry_succeeded = false;
  size_t completion_calls = 0;
  registry.on_unregister = [&] {
    inside_unregister = true;
    const hmw::Outcome result = cleanup->Shutdown();
    reentrant_called = true;
    reentrant_succeeded = result.ok();
    cleanup->RunAfterCurrentOperation([&] {
      ++completion_calls;
      HMW_EXPECT(!inside_unregister);
      retry_succeeded = cleanup->Shutdown().ok();
    });
    inside_unregister = false;
  };
  HMW_EXPECT(controller.Close().ok());
  HMW_EXPECT(reentrant_called);
  HMW_EXPECT(!reentrant_succeeded);
  registry.on_unregister = {};
  HMW_EXPECT(completion_calls == 1);
  HMW_EXPECT(retry_succeeded);
  HMW_EXPECT(cleanup->Shutdown().ok());
  HMW_EXPECT(completion_calls == 1);
}

HMW_TEST(camera_texture_invalid_bgra_emits_one_platform_thread_error) {
  auto source = std::make_shared<SourceState>();
  RecordingRegistry registry;
  QueueDispatcher dispatcher;
  std::vector<hmw::Error> errors;
  std::vector<std::thread::id> error_threads;
  hcw::CameraTextureController controller(Cleanup(registry, dispatcher),
                                          Factory(source));
  HMW_EXPECT(controller
                 .Open({2, 1, 15}, {{},
                                    [&](hmw::Error error) {
                                      errors.push_back(std::move(error));
                                      error_threads.push_back(
                                          std::this_thread::get_id());
                                    }})
                 .ok());
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
