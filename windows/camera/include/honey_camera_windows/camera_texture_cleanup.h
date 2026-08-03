#pragma once

#include <cstdint>
#include <functional>
#include <memory>

#include "honey_media_windows/platform_dispatcher.h"
#include "honey_media_windows/status.h"
#include "honey_media_windows/texture_registry.h"

namespace hcw {

class CameraTextureController;
enum class CameraOperationCompletionRegistration {
  kRegistered,
  kRunNow,
  kOccupied,
};

// Durable owner for camera texture IDs that are awaiting platform-thread
// unregistration. The plugin must retain this coordinator for at least as long
// as its camera TextureRegistry entries, then destroy controllers, call
// Shutdown(), and only afterwards destroy the dispatcher and registry.
class CameraTextureCleanupCoordinator final
    : public std::enable_shared_from_this<CameraTextureCleanupCoordinator> {
 public:
  static std::shared_ptr<CameraTextureCleanupCoordinator> Create(
      hmw::TextureRegistry& texture_registry,
      hmw::PlatformDispatcher& dispatcher);
  ~CameraTextureCleanupCoordinator();

  CameraTextureCleanupCoordinator(const CameraTextureCleanupCoordinator&) =
      delete;
  CameraTextureCleanupCoordinator& operator=(
      const CameraTextureCleanupCoordinator&) = delete;

  // Schedules at most one attempt per pending texture for this trigger.
  hmw::Outcome RetryPending();

  // Runs callback after the operation that caused a reentrant Shutdown()
  // failure has fully exited. The callback runs on that operation's thread.
  // Task 5 uses this to retry Shutdown without blocking or posting a
  // cancelable platform message.
  CameraOperationCompletionRegistration RunAfterCurrentOperation(
      std::function<void()> callback) noexcept;

  // Cancels future access to the non-owning registry/dispatcher dependencies.
  // Call only after camera controllers are destroyed and before either
  // dependency is destroyed.
  // A successful return means all operations are quiesced and both dependency
  // pointers have been detached, so the caller may destroy those dependencies.
  // A reentrant call stops new operations but returns invalid_state because the
  // current operation is not quiesced; call again after that operation returns.
  hmw::Outcome Shutdown() noexcept;

 private:
  struct State;
  class DispatchAttempt;

  CameraTextureCleanupCoordinator(hmw::TextureRegistry& texture_registry,
                                  hmw::PlatformDispatcher& dispatcher);

  void Retain(int64_t texture_id);
  void RetainAndUnregisterOnPlatform(int64_t texture_id);
  void ResetQueued(int64_t texture_id) noexcept;
  void UnregisterOwnedTextureOnPlatform(int64_t texture_id) noexcept;
  hmw::TextureRegistry& RegistryForController() const;
  hmw::PlatformDispatcher& DispatcherForController() const;

  std::unique_ptr<State> state_;

  friend class CameraTextureController;
};

}  // namespace hcw
