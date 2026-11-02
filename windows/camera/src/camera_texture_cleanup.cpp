#include "honey_camera_windows/camera_texture_cleanup.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <functional>
#include <iterator>
#include <mutex>
#include <utility>
#include <vector>

namespace hcw {

namespace {

hmw::Outcome CleanupInactive() {
  return {hmw::Error{hmw::Status::kInvalidState,
                     "camera texture cleanup is shut down"}};
}

hmw::Outcome DispatchFailure() {
  return {hmw::Error{hmw::Status::kInvalidState,
                     "unable to dispatch texture unregister"}};
}
hmw::Outcome CleanupNotQuiescent() {
  return {hmw::Error{hmw::Status::kInvalidState,
                     "camera texture cleanup is executing on this thread"}};
}

}  // namespace

struct CameraTextureCleanupCoordinator::State {
  struct Pending {
    int64_t texture_id;
    bool queued;
  };

  State(hmw::TextureRegistry& texture_registry,
        hmw::PlatformDispatcher& platform_dispatcher)
      : registry(&texture_registry), dispatcher(&platform_dispatcher) {}

  hmw::TextureRegistry* BeginRegistryOperation() {
    std::lock_guard<std::mutex> lock(mutex);
    if (!active || registry == nullptr) {
      return nullptr;
    }
    try {
      active_operations.push_back(this);
    } catch (...) {
      return nullptr;
    }
    ++operations;
    return registry;
  }

  hmw::PlatformDispatcher* BeginDispatcherOperation() {
    std::lock_guard<std::mutex> lock(mutex);
    if (!active || dispatcher == nullptr) {
      return nullptr;
    }
    try {
      active_operations.push_back(this);
    } catch (...) {
      return nullptr;
    }
    ++operations;
    return dispatcher;
  }

  void EndOperation() noexcept {
    std::function<void()> completion;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (operations != 0) {
        --operations;
      }
      const auto active_entry =
          std::find(active_operations.rbegin(), active_operations.rend(), this);
      if (active_entry != active_operations.rend()) {
        active_operations.erase(std::next(active_entry).base());
      }
      if (!active && operations == 0 && this->after_operation) {
        completion.swap(this->after_operation);
      }
    }
    condition.notify_all();
    if (completion) {
      try {
        completion();
      } catch (...) {
      }
    }
  }

  size_t CurrentThreadDepth() const noexcept {
    return static_cast<size_t>(
        std::count(active_operations.begin(), active_operations.end(), this));
  }

  std::mutex mutex;
  std::condition_variable condition;
  bool active = true;
  size_t operations = 0;
  hmw::TextureRegistry* registry;
  hmw::PlatformDispatcher* dispatcher;
  std::vector<Pending> pending;
  std::function<void()> after_operation;
  static thread_local std::vector<State*> active_operations;
};

thread_local std::vector<CameraTextureCleanupCoordinator::State*>
    CameraTextureCleanupCoordinator::State::active_operations;

class CameraTextureCleanupCoordinator::DispatchAttempt final {
 public:
  DispatchAttempt(std::shared_ptr<CameraTextureCleanupCoordinator> owner,
                  int64_t texture_id)
      : owner_(std::move(owner)), texture_id_(texture_id) {}

  ~DispatchAttempt() {
    if (!consumed_.exchange(true)) {
      owner_->ResetQueued(texture_id_);
    }
  }

  void Run() noexcept {
    if (consumed_.exchange(true)) {
      return;
    }
    owner_->UnregisterOwnedTextureOnPlatform(texture_id_);
  }

 private:
  std::shared_ptr<CameraTextureCleanupCoordinator> owner_;
  int64_t texture_id_;
  std::atomic<bool> consumed_{false};
};

std::shared_ptr<CameraTextureCleanupCoordinator>
CameraTextureCleanupCoordinator::Create(hmw::TextureRegistry& texture_registry,
                                        hmw::PlatformDispatcher& dispatcher) {
  return std::shared_ptr<CameraTextureCleanupCoordinator>(
      new CameraTextureCleanupCoordinator(texture_registry, dispatcher));
}

CameraTextureCleanupCoordinator::CameraTextureCleanupCoordinator(
    hmw::TextureRegistry& texture_registry, hmw::PlatformDispatcher& dispatcher)
    : state_(std::make_unique<State>(texture_registry, dispatcher)) {}

CameraTextureCleanupCoordinator::~CameraTextureCleanupCoordinator() {
  (void)Shutdown();
}

hmw::Outcome CameraTextureCleanupCoordinator::RetryPending() {
  std::vector<int64_t> snapshot;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->active) {
      return CleanupInactive();
    }
    snapshot.reserve(state_->pending.size());
    for (const State::Pending& pending : state_->pending) {
      if (!pending.queued) {
        snapshot.push_back(pending.texture_id);
      }
    }
  }

  for (const int64_t texture_id : snapshot) {
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      const auto pending =
          std::find_if(state_->pending.begin(), state_->pending.end(),
                       [texture_id](const State::Pending& item) {
                         return item.texture_id == texture_id;
                       });
      if (pending == state_->pending.end() || pending->queued) {
        continue;
      }
      pending->queued = true;
    }

    auto attempt =
        std::make_shared<DispatchAttempt>(shared_from_this(), texture_id);
    hmw::PlatformDispatcher* dispatcher = state_->BeginDispatcherOperation();
    if (dispatcher == nullptr) {
      attempt.reset();
      return CleanupInactive();
    }
    bool accepted = false;
    try {
      accepted = dispatcher->Post([attempt] { attempt->Run(); });
    } catch (...) {
    }
    state_->EndOperation();
    if (!accepted) {
      attempt.reset();
      return DispatchFailure();
    }
  }
  return {};
}

hmw::Outcome CameraTextureCleanupCoordinator::Shutdown() noexcept {
  std::unique_lock<std::mutex> lock(state_->mutex);
  if (!state_->active && state_->registry == nullptr &&
      state_->dispatcher == nullptr) {
    return {};
  }
  state_->active = false;
  state_->pending.clear();
  if (state_->CurrentThreadDepth() != 0) {
    return CleanupNotQuiescent();
  }
  state_->condition.wait(lock, [this] { return state_->operations == 0; });
  state_->registry = nullptr;
  state_->dispatcher = nullptr;
  return {};
}

CameraOperationCompletionRegistration
CameraTextureCleanupCoordinator::RunAfterCurrentOperation(
    std::function<void()> callback) noexcept {
  if (!callback) {
    return CameraOperationCompletionRegistration::kRunNow;
  }
  std::lock_guard<std::mutex> lock(state_->mutex);
  if (state_->operations == 0) {
    return CameraOperationCompletionRegistration::kRunNow;
  }
  if (state_->after_operation) {
    return CameraOperationCompletionRegistration::kOccupied;
  }
  state_->after_operation.swap(callback);
  return CameraOperationCompletionRegistration::kRegistered;
}

void CameraTextureCleanupCoordinator::Retain(int64_t texture_id) {
  if (texture_id < 0) {
    return;
  }
  std::lock_guard<std::mutex> lock(state_->mutex);
  if (!state_->active) {
    return;
  }
  const auto duplicate =
      std::find_if(state_->pending.begin(), state_->pending.end(),
                   [texture_id](const State::Pending& pending) {
                     return pending.texture_id == texture_id;
                   });
  if (duplicate == state_->pending.end()) {
    state_->pending.push_back(State::Pending{texture_id, false});
  }
}

void CameraTextureCleanupCoordinator::RetainAndUnregisterOnPlatform(
    int64_t texture_id) {
  Retain(texture_id);
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    const auto pending =
        std::find_if(state_->pending.begin(), state_->pending.end(),
                     [texture_id](const State::Pending& item) {
                       return item.texture_id == texture_id;
                     });
    if (pending == state_->pending.end() || pending->queued) {
      return;
    }
    pending->queued = true;
  }
  UnregisterOwnedTextureOnPlatform(texture_id);
}

void CameraTextureCleanupCoordinator::ResetQueued(int64_t texture_id) noexcept {
  std::lock_guard<std::mutex> lock(state_->mutex);
  const auto pending =
      std::find_if(state_->pending.begin(), state_->pending.end(),
                   [texture_id](const State::Pending& item) {
                     return item.texture_id == texture_id;
                   });
  if (pending != state_->pending.end()) {
    pending->queued = false;
  }
}

void CameraTextureCleanupCoordinator::UnregisterOwnedTextureOnPlatform(
    int64_t texture_id) noexcept {
  hmw::TextureRegistry* registry = state_->BeginRegistryOperation();
  if (registry == nullptr) {
    ResetQueued(texture_id);
    return;
  }
  bool accepted = false;
  try {
    accepted = registry->UnregisterTexture(texture_id);
  } catch (...) {
  }
  state_->EndOperation();

  std::lock_guard<std::mutex> lock(state_->mutex);
  const auto pending =
      std::find_if(state_->pending.begin(), state_->pending.end(),
                   [texture_id](const State::Pending& item) {
                     return item.texture_id == texture_id;
                   });
  if (pending == state_->pending.end()) {
    return;
  }
  if (accepted) {
    state_->pending.erase(pending);
  } else {
    pending->queued = false;
  }
}

hmw::TextureRegistry& CameraTextureCleanupCoordinator::RegistryForController()
    const {
  return *state_->registry;
}

hmw::PlatformDispatcher&
CameraTextureCleanupCoordinator::DispatcherForController() const {
  return *state_->dispatcher;
}

}  // namespace hcw
