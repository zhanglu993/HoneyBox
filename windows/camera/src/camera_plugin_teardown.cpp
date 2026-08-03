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

  CameraOperationCompletionRegistration RunAfterCurrentOperation(
      std::function<void()> callback) noexcept override {
    return cleanup_->RunAfterCurrentOperation(std::move(callback));
  }

 private:
  std::shared_ptr<CameraTextureCleanupCoordinator> cleanup_;
};

hmw::Outcome CompletionSlotOccupied() {
  return {hmw::Error{hmw::Status::kBusy,
                     "camera cleanup completion slot is occupied"}};
}

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

CameraPluginTeardownOwner::~CameraPluginTeardownOwner() {
  std::unique_ptr<CameraPluginCleanupGate> cleanup_gate;
  std::unique_ptr<hmw::TextureRegistry> texture_registry;
  std::unique_ptr<hmw::PlatformDispatcher> dispatcher;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    cleanup_gate = std::move(cleanup_gate_);
    texture_registry = std::move(texture_registry_);
    dispatcher = std::move(dispatcher_);
  }

  // Detach the cleanup gate before releasing either dependency, including
  // when a caller abandons an owner after a reported teardown failure.
  cleanup_gate.reset();
  texture_registry.reset();
  dispatcher.reset();
}

hmw::Outcome CameraPluginTeardownOwner::Teardown() noexcept {
  CameraPluginCleanupGate* cleanup_gate = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (attempting_ || deferred_ || complete_) {
      return {};
    }
    attempting_ = true;
    cleanup_gate = cleanup_gate_.get();
  }

  const hmw::Outcome shutdown = cleanup_gate->Shutdown();
  if (shutdown.ok()) {
    return CompleteShutdown();
  }
  if (shutdown.error->status != hmw::Status::kInvalidState) {
    std::lock_guard<std::mutex> lock(mutex_);
    attempting_ = false;
    return shutdown;
  }

  std::shared_ptr<CameraPluginTeardownOwner> self = shared_from_this();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    attempting_ = false;
    deferred_ = true;
  }
  const CameraOperationCompletionRegistration registration =
      cleanup_gate->RunAfterCurrentOperation(
          [self = std::move(self)] { self->ResumeAfterCurrentOperation(); });
  if (registration == CameraOperationCompletionRegistration::kRegistered) {
    return {};
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    deferred_ = false;
  }
  if (registration == CameraOperationCompletionRegistration::kOccupied) {
    return CompletionSlotOccupied();
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    attempting_ = true;
    cleanup_gate = cleanup_gate_.get();
  }
  const hmw::Outcome retry = cleanup_gate->Shutdown();
  if (!retry.ok()) {
    std::lock_guard<std::mutex> lock(mutex_);
    attempting_ = false;
    return retry;
  }
  return CompleteShutdown();
}

hmw::Outcome CameraPluginTeardownOwner::CompleteShutdown() noexcept {
  std::unique_ptr<CameraPluginCleanupGate> stopped_cleanup;
  std::unique_ptr<hmw::TextureRegistry> texture_registry;
  std::unique_ptr<hmw::PlatformDispatcher> dispatcher;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    attempting_ = false;
    deferred_ = false;
    complete_ = true;
    stopped_cleanup = std::move(cleanup_gate_);
    texture_registry = std::move(texture_registry_);
    dispatcher = std::move(dispatcher_);
  }

  stopped_cleanup.reset();
  texture_registry.reset();
  dispatcher.reset();
  return {};
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
