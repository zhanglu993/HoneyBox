#include <algorithm>
#include <limits>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <utility>
#include <vector>

#include "honey_camera_windows/encoder_channel.h"

namespace hcw {

struct CameraTextureController::State {
  State(hmw::TextureRegistry& texture_registry,
        hmw::PlatformDispatcher& platform_dispatcher,
        std::shared_ptr<CameraTextureCleanupCoordinator> cleanup_owner)
      : registry(texture_registry),
        dispatcher(platform_dispatcher),
        cleanup(std::move(cleanup_owner)) {}

  hmw::TextureRegistry& registry;
  hmw::PlatformDispatcher& dispatcher;
  std::shared_ptr<CameraTextureCleanupCoordinator> cleanup;
  std::mutex mutex;
  bool alive = true;
  bool open = false;
  bool registration_pending = false;
  bool terminal = false;
  uint64_t generation = 0;
  uint64_t preview_generation = 0;
  int64_t texture_id = -1;
  uint32_t width = 0;
  uint32_t height = 0;
  std::shared_ptr<const std::vector<uint8_t>> latest_rgba;
  CameraControllerCallbacks callbacks;
};

namespace {

hmw::Outcome DispatchFailure(const char* message) {
  return {hmw::Error{hmw::Status::kInvalidState, message}};
}

bool ValidFrame(const CameraFrame& frame) {
  if (frame.width == 0 || frame.height == 0 || !frame.rgba ||
      frame.width > (std::numeric_limits<size_t>::max)() / 4U / frame.height) {
    return false;
  }
  const size_t expected = static_cast<size_t>(frame.width) * frame.height * 4U;
  return frame.rgba->size() == expected;
}

}  // namespace

CameraTextureController::CameraTextureController(
    std::shared_ptr<CameraTextureCleanupCoordinator> cleanup,
    CameraSourceFactory source_factory)
    : cleanup_(std::move(cleanup)) {
  if (!cleanup_) {
    throw std::invalid_argument("camera texture cleanup is required");
  }
  state_ =
      std::make_shared<State>(cleanup_->RegistryForController(),
                              cleanup_->DispatcherForController(), cleanup_);
  const std::weak_ptr<State> weak_state = state_;
  session_ = std::make_unique<CameraPreviewSession>(
      std::move(source_factory),
      CameraPreviewCallbacks{[weak_state](uint64_t preview_generation,
                                          CameraFrame frame) {
                               PublishFrame(weak_state, preview_generation,
                                            std::move(frame));
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
  state_->latest_rgba.reset();
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
    state_->preview_generation = 0;
    state_->registration_pending = false;
    state_->callbacks = std::move(callbacks);
  }

  hmw::Outcome opened = session_->Open(config);
  if (opened.ok()) {
    const uint64_t preview_generation = session_->generation();
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->generation == generation && state_->open) {
      // Frames racing Open are dropped while the binding is zero. Once Open
      // returns, only the exact CameraPreviewSession generation is accepted.
      state_->preview_generation = preview_generation;
    }
    return opened;
  }

  if (!opened.ok()) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->generation == generation) {
      state_->open = false;
      state_->callbacks = {};
      state_->preview_generation = 0;
      ++state_->generation;
    }
  }
  return opened;
}

hmw::Outcome CameraTextureController::Close() {
  int64_t retired_texture_id = -1;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    ++state_->generation;
    state_->open = false;
    state_->terminal = false;
    state_->registration_pending = false;
    state_->preview_generation = 0;
    state_->callbacks = {};
    state_->latest_rgba.reset();
    state_->width = 0;
    state_->height = 0;
    if (state_->texture_id >= 0) {
      retired_texture_id = state_->texture_id;
      state_->texture_id = -1;
    }
  }
  if (retired_texture_id >= 0) {
    cleanup_->Retain(retired_texture_id);
  }

  hmw::Outcome closed = session_ ? session_->Close() : hmw::Outcome{};
  hmw::Outcome unregistered = cleanup_->RetryPending();
  return !closed.ok() ? closed : unregistered;
}

void CameraTextureController::PublishFrame(
    const std::weak_ptr<State>& weak_state, uint64_t preview_generation,
    CameraFrame frame) noexcept {
  const std::shared_ptr<State> state = weak_state.lock();
  if (!state) {
    return;
  }
  if (!ValidFrame(frame)) {
    {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->alive || !state->open || state->terminal ||
        state->preview_generation != preview_generation) {
      return;
    }
  }

    PublishError(weak_state, hmw::Error{hmw::Status::kIoError,
                                        "camera RGBA frame size is invalid"});
    return;
  }

  uint64_t generation = 0;
  CameraFrame callback_frame{};
  std::function<void(uint64_t, CameraFrame)> on_frame;
  int64_t texture_id = -1;
  bool register_texture = false;
  bool registration_already_pending = false;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->alive || !state->open || state->terminal ||
        state->preview_generation != preview_generation) {
      return;
    }
    state->latest_rgba = std::move(frame.rgba);
    state->width = frame.width;
    state->height = frame.height;
    generation = state->generation;
    on_frame = state->callbacks.on_frame;
    callback_frame = CameraFrame{frame.width, frame.height, frame.pts_100ns,
                                 state->latest_rgba};
    texture_id = state->texture_id;
    if (texture_id < 0) {
      if (state->registration_pending) {
        registration_already_pending = true;
      } else {
        state->registration_pending = true;
        register_texture = true;
      }
    }
  }

  if (on_frame) {
    try {
      on_frame(preview_generation, std::move(callback_frame));
    } catch (...) {
    }
  }
  if (registration_already_pending) {
    return;
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
              current->registry.RegisterPixelBufferTexture(
                  [weak_state, cleanup = current->cleanup] {
                    (void)cleanup;
                    const std::shared_ptr<State> provider_state =
                        weak_state.lock();
                    if (!provider_state) {
                      return hmw::PixelBufferView{};
                    }
                    std::lock_guard<std::mutex> lock(provider_state->mutex);
                    const auto snapshot = provider_state->latest_rgba;
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
            }
          }
          if (!active) {
            current->cleanup->RetainAndUnregisterOnPlatform(registered);
            return;
          }
          if (!current->registry.MarkFrameAvailable(registered)) {
            {
              std::lock_guard<std::mutex> lock(current->mutex);
              if (current->generation == generation &&
                  current->texture_id == registered) {
                current->texture_id = -1;
              }
            }
            current->cleanup->RetainAndUnregisterOnPlatform(registered);
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
