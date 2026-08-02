#include "honey_media_windows/windows_media_plugin.h"

#include <flutter/texture_registrar.h>

#include <algorithm>
#include <cstdint>
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
      auto entry = std::make_shared<Entry>(std::move(provider));
      if (!entry->Refresh()) {
        return -1;
      }
      const int64_t texture_id =
          state->registrar->RegisterTexture(&entry->texture);
      if (texture_id < 0) {
        return -1;
      }
      try {
        if (state->before_insert) {
          state->before_insert();
        }
        std::lock_guard<std::mutex> lock(state->mutex);
        const auto inserted = state->entries.emplace(
            texture_id, Registration{entry, false});
        if (!inserted.second) {
          RollbackRegistration(state, texture_id, std::move(entry));
          return -1;
        }
      } catch (...) {
        RollbackRegistration(state, texture_id, std::move(entry));
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
      if (!view.owner || view.bgra == nullptr ||
          view.bgra != view.owner->data() ||
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
      if (stable_bgra.empty()) {
        stable_bgra.assign(view.bgra, view.bgra + view.byte_count);
      } else {
        if (stable_bgra.size() != view.byte_count) {
          return false;
        }
        std::copy(view.bgra, view.bgra + view.byte_count,
                  stable_bgra.begin());
      }
      pixel_buffer.buffer = stable_bgra.data();
      pixel_buffer.width = view.width;
      pixel_buffer.height = view.height;
      pixel_buffer.release_callback = nullptr;
      pixel_buffer.release_context = nullptr;
      return true;
    }

    std::mutex mutex;
    PixelBufferProvider provider;
    std::vector<uint8_t> stable_bgra;
    FlutterDesktopPixelBuffer pixel_buffer{};
    flutter::PixelBufferTexture pixel_texture;
    flutter::TextureVariant texture;
  };

  struct Registration {
    std::shared_ptr<Entry> entry;
    bool unregistering;
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
  };

  static void RollbackRegistration(
      const std::shared_ptr<State>& state, int64_t texture_id,
      std::shared_ptr<Entry> entry) noexcept {
    if (state->registrar == nullptr) {
      return;
    }
    try {
      state->registrar->UnregisterTexture(
          texture_id, [entry = std::move(entry)] {});
    } catch (...) {
      // The Flutter registrar contract is non-throwing. Returning failure is
      // still preferable to letting an embedder exception cross the channel.
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
          texture_id, [state, texture_id, entry = std::move(entry)] {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->entries.erase(texture_id);
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
