#include "honey_camera_windows/camera_plugin_teardown.h"

#include <utility>

#include "honey_camera_windows/camera_texture_cleanup.h"

namespace hcw {
namespace {

class CoordinatorCleanupGate final : public CameraPluginCleanupGate {
 public:
  explicit CoordinatorCleanupGate(
      std::shared_ptr<CameraTextureCleanupCoordinator> cleanup)
      : cleanup_(std::move(cleanup)) {}

  hmw::Outcome Shutdown() noexcept override { return cleanup_->Shutdown(); }

  void RunAfterCurrentOperation(
      std::function<void()> callback) noexcept override {
    cleanup_->RunAfterCurrentOperation(std::move(callback));
  }

 private:
  std::shared_ptr<CameraTextureCleanupCoordinator> cleanup_;
};

}  // namespace

std::unique_ptr<CameraPluginCleanupGate> CreateCameraPluginCleanupGate(
    std::shared_ptr<CameraTextureCleanupCoordinator> cleanup) {
  return std::make_unique<CoordinatorCleanupGate>(std::move(cleanup));
}

std::shared_ptr<CameraPluginTeardownOwner> CameraPluginTeardownOwner::Create(
    std::unique_ptr<CameraPluginCleanupGate> cleanup_gate,
    std::unique_ptr<hmw::TextureRegistry> texture_registry,
    std::unique_ptr<hmw::PlatformDispatcher> dispatcher) {
  return std::shared_ptr<CameraPluginTeardownOwner>(
      new CameraPluginTeardownOwner(std::move(cleanup_gate),
                                    std::move(texture_registry),
                                    std::move(dispatcher)));
}

CameraPluginTeardownOwner::CameraPluginTeardownOwner(
    std::unique_ptr<CameraPluginCleanupGate> cleanup_gate,
    std::unique_ptr<hmw::TextureRegistry> texture_registry,
    std::unique_ptr<hmw::PlatformDispatcher> dispatcher)
    : cleanup_gate_(std::move(cleanup_gate)),
      texture_registry_(std::move(texture_registry)),
      dispatcher_(std::move(dispatcher)) {}

void CameraPluginTeardownOwner::Teardown() noexcept {
  CameraPluginCleanupGate* cleanup_gate = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (attempting_ || deferred_ || complete_) {
      return;
    }
    attempting_ = true;
    cleanup_gate = cleanup_gate_.get();
  }

  const hmw::Outcome shutdown = cleanup_gate->Shutdown();
  if (!shutdown.ok()) {
    std::shared_ptr<CameraPluginTeardownOwner> self = shared_from_this();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      attempting_ = false;
      deferred_ = true;
    }
    cleanup_gate->RunAfterCurrentOperation(
        [self = std::move(self)] { self->ResumeAfterCurrentOperation(); });
    return;
  }

  std::unique_ptr<CameraPluginCleanupGate> stopped_cleanup;
  std::unique_ptr<hmw::TextureRegistry> texture_registry;
  std::unique_ptr<hmw::PlatformDispatcher> dispatcher;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    attempting_ = false;
    complete_ = true;
    stopped_cleanup = std::move(cleanup_gate_);
    texture_registry = std::move(texture_registry_);
    dispatcher = std::move(dispatcher_);
  }

  stopped_cleanup.reset();
  texture_registry.reset();
  dispatcher.reset();
}

void CameraPluginTeardownOwner::ResumeAfterCurrentOperation() noexcept {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (complete_) {
      return;
    }
    deferred_ = false;
  }
  Teardown();
}

}  // namespace hcw
