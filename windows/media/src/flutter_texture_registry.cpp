#include "honey_media_windows/windows_media_plugin.h"

#include <flutter/texture_registrar.h>

#include <algorithm>
#include <cstdint>
#include <list>
#include <limits>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>

namespace hmw {
namespace {

class FlutterTextureRegistry final : public TextureRegistry {
 public:
  FlutterTextureRegistry(flutter::TextureRegistrar* registrar,
                         std::function<void()> before_insert = {})
      : state_(std::make_shared<State>(
            registrar, std::move(before_insert))) {}

  ~FlutterTextureRegistry() override {
    RetryPendingRollbacksForDestruction(state_);
    for (;;) {
      int64_t texture_id = -1;
      {
        std::lock_guard<std::mutex> lock(state_->mutex);
        for (const auto& registration : state_->entries) {
          if (!registration.second.unregistering) {
            texture_id = registration.first;
            break;
          }
        }
      }
      if (texture_id < 0) {
        break;
      }
      if (!RequestUnregister(state_, texture_id)) {
        std::lock_guard<std::mutex> lock(state_->mutex);
        const auto found = state_->entries.find(texture_id);
        if (found != state_->entries.end()) {
          found->second.unregistering = true;
        }
      }
    }
  }

  int64_t RegisterPixelBufferTexture(
      PixelBufferProvider provider) override {
    std::shared_ptr<State> state = state_;
    if (!provider || state->registrar == nullptr) {
      return -1;
    }
    try {
      auto entry =
          std::make_shared<Entry>(std::move(provider));
      if (!entry->Refresh()) {
        return -1;
      }
      auto rollback =
          std::make_shared<PendingRollback>(entry);
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->pending_rollbacks.push_back(rollback);
        // If RegisterTexture itself throws after retaining the raw pointer,
        // there is no texture id to unregister. Keep the Entry safely leaked.
        rollback->unregister_keepalive = rollback;
      }
      const int64_t texture_id =
          state->registrar->RegisterTexture(&entry->texture);
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        rollback->texture_id = texture_id;
        rollback->unregister_keepalive.reset();
        if (texture_id < 0) {
          RemovePendingRollbackLocked(state.get(), rollback);
          return -1;
        }
      }
      try {
        if (state->before_insert) {
          state->before_insert();
        }
        bool inserted = false;
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          inserted = state->entries.emplace(
              texture_id, Registration{entry, false}).second;
          if (inserted) {
            RemovePendingRollbackLocked(state.get(), rollback);
          }
        }
        if (!inserted) {
          (void)RequestRollback(state, rollback);
          return -1;
        }
      } catch (...) {
        (void)RequestRollback(state, rollback);
        return -1;
      }
      return texture_id;
    } catch (...) {
      return -1;
    }
  }

  bool MarkFrameAvailable(int64_t texture_id) override {
    std::shared_ptr<State> state = state_;
    std::shared_ptr<Entry> entry;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      const auto found = state->entries.find(texture_id);
      if (found == state->entries.end()) {
        return false;
      }
      entry = found->second.entry;
    }
    return entry != nullptr && state->registrar != nullptr &&
           state->registrar->MarkTextureFrameAvailable(texture_id);
  }

  bool UnregisterTexture(int64_t texture_id) override {
    return RequestUnregister(state_, texture_id);
  }

 private:
  struct Entry {
    explicit Entry(PixelBufferProvider pixel_provider)
        : provider(std::move(pixel_provider)),
          pixel_texture([this](size_t, size_t) {
            return Refresh() ? &pixel_buffer : nullptr;
          }),
          texture(std::move(pixel_texture)) {}

    bool Refresh() {
      std::lock_guard<std::mutex> lock(mutex);
      const PixelBufferView view = provider();
      if (!view.owner || view.rgba == nullptr ||
          view.rgba != view.owner->data() ||
          view.width == 0 || view.height == 0 ||
          view.width >
              (std::numeric_limits<size_t>::max)() / 4U /
                  view.height) {
        return false;
      }
      const size_t required =
          static_cast<size_t>(view.width) * view.height * 4U;
      if (view.byte_count != required) {
        return false;
      }
      if (stable_rgba.empty()) {
        stable_rgba.assign(view.rgba, view.rgba + view.byte_count);
      } else {
        if (stable_rgba.size() != view.byte_count) {
          return false;
        }
        std::copy(view.rgba, view.rgba + view.byte_count,
                  stable_rgba.begin());
      }
      pixel_buffer.buffer = stable_rgba.data();
      pixel_buffer.width = view.width;
      pixel_buffer.height = view.height;
      pixel_buffer.release_callback = nullptr;
      pixel_buffer.release_context = nullptr;
      return true;
    }

    std::mutex mutex;
    PixelBufferProvider provider;
    std::vector<uint8_t> stable_rgba;
    FlutterDesktopPixelBuffer pixel_buffer{};
    flutter::PixelBufferTexture pixel_texture;
    flutter::TextureVariant texture;
    std::shared_ptr<Entry> unregister_keepalive;
  };

  struct Registration {
    std::shared_ptr<Entry> entry;
    bool unregistering;
  };

  struct PendingRollback {
    explicit PendingRollback(std::shared_ptr<Entry> retained_entry)
        : entry(std::move(retained_entry)) {}

    std::shared_ptr<Entry> entry;
    std::shared_ptr<PendingRollback> unregister_keepalive;
    int64_t texture_id = -1;
    bool unregistering = false;
  };

  struct State {
    State(flutter::TextureRegistrar* texture_registrar,
          std::function<void()> insert_hook)
        : registrar(texture_registrar),
          before_insert(std::move(insert_hook)) {}

    flutter::TextureRegistrar* registrar;
    std::function<void()> before_insert;
    std::mutex mutex;
    std::unordered_map<int64_t, Registration> entries;
    std::list<std::shared_ptr<PendingRollback>> pending_rollbacks;
  };

  static void RemovePendingRollbackLocked(
      State* state, const std::shared_ptr<PendingRollback>& rollback) {
    for (auto found = state->pending_rollbacks.begin();
         found != state->pending_rollbacks.end(); ++found) {
      if (*found == rollback) {
        state->pending_rollbacks.erase(found);
        return;
      }
    }
  }

  static bool RequestRollback(
      const std::shared_ptr<State>& state,
      const std::shared_ptr<PendingRollback>& rollback) noexcept {
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (rollback->unregistering || rollback->texture_id < 0) {
        return rollback->unregistering;
      }
      rollback->unregistering = true;
      // Flutter stores a raw TextureVariant pointer. Establish a no-throw
      // self-reference before constructing the callback, which may allocate.
      rollback->unregister_keepalive = rollback;
    }
    if (state->registrar == nullptr) {
      std::lock_guard<std::mutex> lock(state->mutex);
      rollback->unregistering = false;
      return false;
    }
    try {
      state->registrar->UnregisterTexture(
          rollback->texture_id, [state, rollback] {
            {
              std::lock_guard<std::mutex> lock(state->mutex);
              RemovePendingRollbackLocked(state.get(), rollback);
            }
            rollback->entry.reset();
            rollback->unregister_keepalive.reset();
          });
      return true;
    } catch (...) {
      std::lock_guard<std::mutex> lock(state->mutex);
      rollback->unregistering = false;
      return false;
    }
  }

  static void RetryPendingRollbacksForDestruction(
      const std::shared_ptr<State>& state) noexcept {
    for (;;) {
      std::shared_ptr<PendingRollback> rollback;
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        for (const auto& candidate : state->pending_rollbacks) {
          if (!candidate->unregistering && candidate->texture_id >= 0) {
            rollback = candidate;
            break;
          }
        }
      }
      if (!rollback) {
        return;
      }
      if (!RequestRollback(state, rollback)) {
        // No callback exists to prove Flutter released its raw pointer.
        // Leave the self-cycle intact as an intentional process-lifetime leak.
        std::lock_guard<std::mutex> lock(state->mutex);
        rollback->unregistering = true;
      }
    }
  }

  static bool RequestUnregister(const std::shared_ptr<State>& state,
                                int64_t texture_id) {
    std::shared_ptr<Entry> entry;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      const auto found = state->entries.find(texture_id);
      if (found == state->entries.end()) {
        return false;
      }
      if (found->second.unregistering) {
        return true;
      }
      found->second.unregistering = true;
      entry = found->second.entry;
      // Keep TextureVariant alive even if std::function construction or the
      // registrar call throws before Flutter accepts the callback.
      entry->unregister_keepalive = entry;
    }
    if (state->registrar == nullptr) {
      std::lock_guard<std::mutex> lock(state->mutex);
      const auto found = state->entries.find(texture_id);
      if (found != state->entries.end()) {
        found->second.unregistering = false;
      }
      return false;
    }
    try {
      state->registrar->UnregisterTexture(
          texture_id, [state, texture_id, entry] {
            {
              std::lock_guard<std::mutex> lock(state->mutex);
              state->entries.erase(texture_id);
            }
            entry->unregister_keepalive.reset();
          });
      return true;
    } catch (...) {
      std::lock_guard<std::mutex> lock(state->mutex);
      const auto found = state->entries.find(texture_id);
      if (found != state->entries.end()) {
        found->second.unregistering = false;
      }
      return false;
    }
  }

  std::shared_ptr<State> state_;
};

}  // namespace

std::unique_ptr<TextureRegistry> CreateFlutterTextureRegistry(
    flutter::TextureRegistrar* registrar) {
  if (registrar == nullptr) {
    return nullptr;
  }
  return std::make_unique<FlutterTextureRegistry>(registrar);
}

std::unique_ptr<TextureRegistry> CreateFlutterTextureRegistryForTesting(
    flutter::TextureRegistrar* registrar,
    std::function<void()> before_insert) {
  if (registrar == nullptr) {
    return nullptr;
  }
  return std::make_unique<FlutterTextureRegistry>(
      registrar, std::move(before_insert));
}

}  // namespace hmw
