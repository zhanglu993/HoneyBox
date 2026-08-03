#include "honey_camera_windows/camera_plugin_teardown.h"

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "honey_media_windows/platform_dispatcher.h"
#include "honey_media_windows/texture_registry.h"
#include "test_support.h"

namespace {

class FakeDispatcher final : public hmw::PlatformDispatcher {
 public:
  FakeDispatcher(std::vector<std::string>& events, bool& alive,
                 std::vector<std::thread::id>& destroy_threads)
      : events_(events), alive_(alive), destroy_threads_(destroy_threads) {
    alive_ = true;
  }

  ~FakeDispatcher() override {
    events_.push_back("dispatcher_destroyed");
    destroy_threads_.push_back(std::this_thread::get_id());
    alive_ = false;
  }

  bool Post(std::function<void()>) override { return false; }

 private:
  std::vector<std::string>& events_;
  bool& alive_;
  std::vector<std::thread::id>& destroy_threads_;
};

class FakeRegistry final : public hmw::TextureRegistry {
 public:
  FakeRegistry(std::vector<std::string>& events, bool& alive,
               std::vector<std::thread::id>& destroy_threads)
      : events_(events), alive_(alive), destroy_threads_(destroy_threads) {
    alive_ = true;
  }

  ~FakeRegistry() override {
    events_.push_back("registry_destroyed");
    destroy_threads_.push_back(std::this_thread::get_id());
    alive_ = false;
  }

  int64_t RegisterPixelBufferTexture(hmw::PixelBufferProvider) override {
    return -1;
  }
  bool MarkFrameAvailable(int64_t) override { return false; }
  bool UnregisterTexture(int64_t) override { return false; }

 private:
  std::vector<std::string>& events_;
  bool& alive_;
  std::vector<std::thread::id>& destroy_threads_;
};

class FakeCleanupGate final : public hcw::CameraPluginCleanupGate {
 public:
  FakeCleanupGate(bool fail_first, size_t& shutdown_attempts)
      : fail_first_(fail_first), shutdown_attempts_(shutdown_attempts) {}

  hmw::Outcome Shutdown() noexcept override {
    ++shutdown_attempts_;
    if (fail_first_ && !outer_operation_finished) {
      return {hmw::Error{hmw::Status::kInvalidState,
                         "cleanup operation is still active"}};
    }
    return {};
  }

  void RunAfterCurrentOperation(
      std::function<void()> callback) noexcept override {
    deferred = std::move(callback);
  }

  void FinishOuterOperation() {
    outer_operation_finished = true;
    auto callback = std::move(deferred);
    if (callback) {
      callback();
    }
  }

  bool fail_first_;
  bool outer_operation_finished = false;
  size_t& shutdown_attempts_;
  std::function<void()> deferred;
};

std::shared_ptr<hcw::CameraPluginTeardownOwner> MakeOwner(
    bool fail_first, std::vector<std::string>& events, bool& registry_alive,
    bool& dispatcher_alive, std::vector<std::thread::id>& destroy_threads,
    size_t& shutdown_attempts, FakeCleanupGate** gate_out) {
  auto gate = std::make_unique<FakeCleanupGate>(fail_first, shutdown_attempts);
  *gate_out = gate.get();
  return hcw::CameraPluginTeardownOwner::Create(
      std::move(gate),
      std::make_unique<FakeRegistry>(events, registry_alive, destroy_threads),
      std::make_unique<FakeDispatcher>(events, dispatcher_alive,
                                       destroy_threads));
}

void ExpectPlatformThreadDestruction(
    const std::vector<std::thread::id>& destroy_threads,
    std::thread::id platform_thread) {
  HMW_EXPECT(destroy_threads.size() == 2);
  for (const std::thread::id thread : destroy_threads) {
    HMW_EXPECT(thread == platform_thread);
  }
}

}  // namespace

HMW_TEST(camera_plugin_teardown_success_destroys_dependencies_in_order) {
  std::vector<std::string> events;
  std::vector<std::thread::id> destroy_threads;
  bool registry_alive = false;
  bool dispatcher_alive = false;
  size_t shutdown_attempts = 0;
  FakeCleanupGate* gate = nullptr;
  auto owner = MakeOwner(false, events, registry_alive, dispatcher_alive,
                         destroy_threads, shutdown_attempts, &gate);
  const std::thread::id platform_thread = std::this_thread::get_id();

  owner->Teardown();

  HMW_EXPECT(shutdown_attempts == 1);
  HMW_EXPECT(!registry_alive && !dispatcher_alive);
  HMW_EXPECT(events == std::vector<std::string>{"registry_destroyed",
                                                "dispatcher_destroyed"});
  ExpectPlatformThreadDestruction(destroy_threads, platform_thread);
}

HMW_TEST(
    camera_plugin_teardown_invalid_state_retains_dependencies_until_retry) {
  std::vector<std::string> events;
  std::vector<std::thread::id> destroy_threads;
  bool registry_alive = false;
  bool dispatcher_alive = false;
  size_t shutdown_attempts = 0;
  FakeCleanupGate* gate = nullptr;
  auto owner = MakeOwner(true, events, registry_alive, dispatcher_alive,
                         destroy_threads, shutdown_attempts, &gate);
  const std::thread::id platform_thread = std::this_thread::get_id();

  owner->Teardown();

  HMW_EXPECT(shutdown_attempts == 1);
  HMW_EXPECT(registry_alive && dispatcher_alive);
  HMW_EXPECT(events.empty());
  HMW_EXPECT(static_cast<bool>(gate->deferred));

  gate->FinishOuterOperation();

  HMW_EXPECT(shutdown_attempts == 2);
  HMW_EXPECT(!registry_alive && !dispatcher_alive);
  HMW_EXPECT(events == std::vector<std::string>{"registry_destroyed",
                                                "dispatcher_destroyed"});
  ExpectPlatformThreadDestruction(destroy_threads, platform_thread);
}

HMW_TEST(camera_plugin_teardown_is_idempotent) {
  std::vector<std::string> events;
  std::vector<std::thread::id> destroy_threads;
  bool registry_alive = false;
  bool dispatcher_alive = false;
  size_t shutdown_attempts = 0;
  FakeCleanupGate* gate = nullptr;
  auto owner = MakeOwner(false, events, registry_alive, dispatcher_alive,
                         destroy_threads, shutdown_attempts, &gate);

  owner->Teardown();
  owner->Teardown();

  HMW_EXPECT(shutdown_attempts == 1);
  HMW_EXPECT(events.size() == 2);
}
