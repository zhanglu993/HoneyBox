#pragma once

#include "honey_camera_windows/camera_texture_cleanup.h"

#include <functional>
#include <memory>
#include <mutex>

#include "honey_media_windows/platform_dispatcher.h"
#include "honey_media_windows/status.h"
#include "honey_media_windows/texture_registry.h"

namespace hcw {

class CameraPluginCleanupGate {
 public:
  virtual ~CameraPluginCleanupGate() = default;

  virtual hmw::Outcome Shutdown() noexcept = 0;
  virtual CameraOperationCompletionRegistration RunAfterCurrentOperation(
      std::function<void()> callback) noexcept = 0;
};

std::unique_ptr<CameraPluginCleanupGate> CreateCameraPluginCleanupGate(
    std::shared_ptr<CameraTextureCleanupCoordinator> cleanup);

class CameraPluginTeardownOwner final
    : public std::enable_shared_from_this<CameraPluginTeardownOwner> {
 public:
  static std::shared_ptr<CameraPluginTeardownOwner> Create(
      std::unique_ptr<CameraPluginCleanupGate> cleanup_gate,
      std::unique_ptr<hmw::TextureRegistry> texture_registry,
      std::unique_ptr<hmw::PlatformDispatcher> dispatcher);

  ~CameraPluginTeardownOwner();
  CameraPluginTeardownOwner(const CameraPluginTeardownOwner&) = delete;
  CameraPluginTeardownOwner& operator=(const CameraPluginTeardownOwner&) =
      delete;

  hmw::Outcome Teardown() noexcept;

 private:
  CameraPluginTeardownOwner(
      std::unique_ptr<CameraPluginCleanupGate> cleanup_gate,
      std::unique_ptr<hmw::TextureRegistry> texture_registry,
      std::unique_ptr<hmw::PlatformDispatcher> dispatcher);

  void ResumeAfterCurrentOperation() noexcept;
  hmw::Outcome CompleteShutdown() noexcept;

  std::mutex mutex_;
  bool attempting_ = false;
  bool deferred_ = false;
  bool complete_ = false;
  std::unique_ptr<CameraPluginCleanupGate> cleanup_gate_;
  std::unique_ptr<hmw::TextureRegistry> texture_registry_;
  std::unique_ptr<hmw::PlatformDispatcher> dispatcher_;
};

}  // namespace hcw
