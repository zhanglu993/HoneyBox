#include <algorithm>
#include <limits>
#include <mutex>
#include <optional>
#include <utility>
#include <vector>

#include "honey_camera_windows/encoder_channel.h"

namespace hcw {

struct CameraTextureController::State {
  struct PendingUnregister {
    int64_t texture_id;
    bool queued;
  };

  State(hmw::TextureRegistry& texture_registry,
        hmw::PlatformDispatcher& platform_dispatcher)
      : registry(texture_registry), dispatcher(platform_dispatcher) {}

  hmw::TextureRegistry& registry;
  hmw::PlatformDispatcher& dispatcher;
  std::mutex mutex;
  bool alive = true;
  bool open = false;
  bool registration_pending = false;
  bool terminal = false;
  uint64_t generation = 0;
  int64_t texture_id = -1;
  uint32_t width = 0;
  uint32_t height = 0;
  std::shared_ptr<const std::vector<uint8_t>> latest_bgra;
  CameraControllerCallbacks callbacks;
  std::vector<PendingUnregister> pending_unregisters;
};

namespace {

hmw::Outcome DispatchFailure(const char* message) {
  return {hmw::Error{hmw::Status::kInvalidState, message}};
}

bool ValidFrame(const CameraFrame& frame) {
  if (frame.width == 0 || frame.height == 0 || !frame.bgra ||
      frame.width > (std::numeric_limits<size_t>::max)() / 4U / frame.height) {
    return false;
  }
  const size_t expected = static_cast<size_t>(frame.width) * frame.height * 4U;
  return frame.bgra->size() == expected;
}

}  // namespace

CameraTextureController::CameraTextureController(
    hmw::TextureRegistry& texture_registry, hmw::PlatformDispatcher& dispatcher,
    CameraSourceFactory source_factory)
    : state_(std::make_shared<State>(texture_registry, dispatcher)) {
  const std::weak_ptr<State> weak_state = state_;
  session_ = std::make_unique<CameraPreviewSession>(
      std::move(source_factory),
      CameraPreviewCallbacks{[weak_state](uint64_t, CameraFrame frame) {
                               PublishFrame(weak_state, std::move(frame));
                             },
                             [weak_state](uint64_t, hmw::Error error) {
                               PublishError(weak_state, std::move(error));
                             }});
}

CameraTextureController::~CameraTextureController() {
  (void)Close();
  std::lock_guard<std::mutex> lock(state_->mutex);
  state_->alive = false;
  state_->open = false;
  ++state_->generation;
  state_->callbacks = {};
  state_->latest_bgra.reset();
}

hmw::Outcome CameraTextureController::Open(
    CameraPreviewConfig config, CameraControllerCallbacks callbacks) {
  hmw::Outcome closed = Close();
  if (!closed.ok()) {
    return closed;
  }

  uint64_t generation = 0;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->alive) {
      return DispatchFailure("camera texture controller is shut down");
    }
    generation = ++state_->generation;
    state_->open = true;
    state_->terminal = false;
    state_->registration_pending = false;
    state_->callbacks = std::move(callbacks);
  }

  hmw::Outcome opened = session_->Open(config);
  if (!opened.ok()) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->generation == generation) {
      state_->open = false;
      state_->callbacks = {};
      ++state_->generation;
    }
  }
  return opened;
}

hmw::Outcome CameraTextureController::Close() {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    ++state_->generation;
    state_->open = false;
    state_->terminal = false;
    state_->registration_pending = false;
    state_->callbacks = {};
    state_->latest_bgra.reset();
    state_->width = 0;
    state_->height = 0;
    if (state_->texture_id >= 0) {
      RetainUnregisterLocked(*state_, state_->texture_id);
      state_->texture_id = -1;
    }
  }

  hmw::Outcome closed = session_ ? session_->Close() : hmw::Outcome{};
  hmw::Outcome unregistered = ScheduleUnregisters(state_);
  return !closed.ok() ? closed : unregistered;
}

void CameraTextureController::RetainUnregisterLocked(State& state,
                                                     int64_t texture_id) {
  if (texture_id < 0) {
    return;
  }
  const auto duplicate = std::find_if(
      state.pending_unregisters.begin(), state.pending_unregisters.end(),
      [texture_id](const State::PendingUnregister& item) {
        return item.texture_id == texture_id;
      });
  if (duplicate == state.pending_unregisters.end()) {
    state.pending_unregisters.push_back(
        State::PendingUnregister{texture_id, false});
  }
}

bool CameraTextureController::ClaimPendingUnregister(
    const std::shared_ptr<State>& state, int64_t texture_id) {
  std::lock_guard<std::mutex> lock(state->mutex);
  const auto pending = std::find_if(
      state->pending_unregisters.begin(), state->pending_unregisters.end(),
      [texture_id](const State::PendingUnregister& item) {
        return item.texture_id == texture_id;
      });
  if (pending == state->pending_unregisters.end() || pending->queued) {
    return false;
  }
  pending->queued = true;
  return true;
}

void CameraTextureController::UnregisterOwnedTextureOnPlatform(
    const std::shared_ptr<State>& state, int64_t texture_id) {
  const bool accepted = state->registry.UnregisterTexture(texture_id);
  std::lock_guard<std::mutex> lock(state->mutex);
  const auto pending = std::find_if(
      state->pending_unregisters.begin(), state->pending_unregisters.end(),
      [texture_id](const State::PendingUnregister& item) {
        return item.texture_id == texture_id;
      });
  if (pending == state->pending_unregisters.end()) {
    return;
  }
  if (accepted) {
    state->pending_unregisters.erase(pending);
  } else {
    pending->queued = false;
  }
}

void CameraTextureController::ResetPendingUnregister(
    const std::shared_ptr<State>& state, int64_t texture_id) {
  std::lock_guard<std::mutex> lock(state->mutex);
  const auto pending = std::find_if(
      state->pending_unregisters.begin(), state->pending_unregisters.end(),
      [texture_id](const State::PendingUnregister& item) {
        return item.texture_id == texture_id;
      });
  if (pending != state->pending_unregisters.end()) {
    pending->queued = false;
  }
}

hmw::Outcome CameraTextureController::ScheduleUnregisters(
    const std::shared_ptr<State>& state) {
  std::vector<int64_t> attempted;
  for (;;) {
    int64_t texture_id = -1;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      const auto pending = std::find_if(
          state->pending_unregisters.begin(), state->pending_unregisters.end(),
          [&attempted](const State::PendingUnregister& item) {
            return !item.queued &&
                   std::find(attempted.begin(), attempted.end(),
                             item.texture_id) == attempted.end();
          });
      if (pending == state->pending_unregisters.end()) {
        return {};
      }
      pending->queued = true;
      texture_id = pending->texture_id;
      attempted.push_back(texture_id);
    }

    if (!state->dispatcher.Post([state, texture_id] {
          UnregisterOwnedTextureOnPlatform(state, texture_id);
        })) {
      ResetPendingUnregister(state, texture_id);
      return DispatchFailure("unable to dispatch texture unregister");
    }
  }
}

void CameraTextureController::PublishFrame(
    const std::weak_ptr<State>& weak_state, CameraFrame frame) noexcept {
  const std::shared_ptr<State> state = weak_state.lock();
  if (!state) {
    return;
  }
  if (!ValidFrame(frame)) {
    PublishError(weak_state, hmw::Error{hmw::Status::kIoError,
                                        "camera BGRA frame size is invalid"});
    return;
  }

  uint64_t generation = 0;
  int64_t texture_id = -1;
  bool register_texture = false;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->alive || !state->open || state->terminal) {
      return;
    }
    state->latest_bgra = std::move(frame.bgra);
    state->width = frame.width;
    state->height = frame.height;
    generation = state->generation;
    texture_id = state->texture_id;
    if (texture_id < 0) {
      if (state->registration_pending) {
        return;
      }
      state->registration_pending = true;
      register_texture = true;
    }
  }

  if (register_texture) {
    if (!state->dispatcher.Post([weak_state, generation] {
          const std::shared_ptr<State> current = weak_state.lock();
          if (!current) {
            return;
          }
          {
            std::lock_guard<std::mutex> lock(current->mutex);
            if (!current->alive || !current->open || current->terminal ||
                current->generation != generation ||
                !current->registration_pending) {
              return;
            }
          }

          const int64_t registered =
              current->registry.RegisterPixelBufferTexture([weak_state] {
                const std::shared_ptr<State> provider_state = weak_state.lock();
                if (!provider_state) {
                  return hmw::PixelBufferView{};
                }
                std::lock_guard<std::mutex> lock(provider_state->mutex);
                const auto snapshot = provider_state->latest_bgra;
                if (!snapshot) {
                  return hmw::PixelBufferView{};
                }
                return hmw::PixelBufferView{
                    snapshot, snapshot->data(), snapshot->size(),
                    provider_state->width, provider_state->height};
              });
          if (registered < 0) {
            {
              std::lock_guard<std::mutex> lock(current->mutex);
              if (current->generation == generation) {
                current->registration_pending = false;
              }
            }
            PublishError(weak_state,
                         hmw::Error{hmw::Status::kInvalidState,
                                    "Flutter texture registration failed"});
            return;
          }

          CameraControllerCallbacks callbacks;
          CameraReady ready{};
          bool active = false;
          {
            std::lock_guard<std::mutex> lock(current->mutex);
            active = current->alive && current->open && !current->terminal &&
                     current->generation == generation;
            if (active) {
              current->texture_id = registered;
              current->registration_pending = false;
              callbacks = current->callbacks;
              ready = CameraReady{registered, current->width, current->height};
            } else {
              RetainUnregisterLocked(*current, registered);
            }
          }
          if (!active) {
            if (ClaimPendingUnregister(current, registered)) {
              UnregisterOwnedTextureOnPlatform(current, registered);
            }
            return;
          }
          if (!current->registry.MarkFrameAvailable(registered)) {
            {
              std::lock_guard<std::mutex> lock(current->mutex);
              if (current->generation == generation &&
                  current->texture_id == registered) {
                current->texture_id = -1;
                RetainUnregisterLocked(*current, registered);
              }
            }
            if (ClaimPendingUnregister(current, registered)) {
              UnregisterOwnedTextureOnPlatform(current, registered);
            }
            PublishError(weak_state,
                         hmw::Error{hmw::Status::kInvalidState,
                                    "Flutter rejected the camera frame"});
            return;
          }
          if (callbacks.on_ready) {
            try {
              callbacks.on_ready(ready);
            } catch (...) {
            }
          }
        })) {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (state->generation == generation) {
        state->registration_pending = false;
        state->terminal = true;
      }
    }
    return;
  }

  if (!state->dispatcher.Post([weak_state, generation, texture_id] {
        const std::shared_ptr<State> current = weak_state.lock();
        if (!current) {
          return;
        }
        {
          std::lock_guard<std::mutex> lock(current->mutex);
          if (!current->alive || !current->open || current->terminal ||
              current->generation != generation ||
              current->texture_id != texture_id) {
            return;
          }
        }
        if (!current->registry.MarkFrameAvailable(texture_id)) {
          PublishError(weak_state,
                       hmw::Error{hmw::Status::kInvalidState,
                                  "Flutter rejected the camera frame"});
        }
      })) {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->generation == generation) {
      state->terminal = true;
    }
  }
}

void CameraTextureController::PublishError(
    const std::weak_ptr<State>& weak_state, hmw::Error error) noexcept {
  const std::shared_ptr<State> state = weak_state.lock();
  if (!state) {
    return;
  }
  uint64_t generation = 0;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->alive || !state->open || state->terminal) {
      return;
    }
    state->terminal = true;
    generation = state->generation;
  }

  (void)state->dispatcher.Post(
      [weak_state, generation, error = std::move(error)]() mutable {
        const std::shared_ptr<State> current = weak_state.lock();
        if (!current) {
          return;
        }
        std::function<void(hmw::Error)> callback;
        {
          std::lock_guard<std::mutex> lock(current->mutex);
          if (!current->alive || !current->open ||
              current->generation != generation || !current->terminal) {
            return;
          }
          callback = current->callbacks.on_error;
        }
        if (callback) {
          try {
            callback(std::move(error));
          } catch (...) {
          }
        }
      });
}

}  // namespace hcw
