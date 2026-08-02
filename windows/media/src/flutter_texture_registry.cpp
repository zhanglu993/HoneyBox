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
  explicit FlutterTextureRegistry(flutter::TextureRegistrar* registrar)
      : registrar_(registrar) {}

  int64_t RegisterPixelBufferTexture(
      PixelBufferProvider provider) override {
    if (!provider || registrar_ == nullptr) {
      return -1;
    }
    auto entry = std::make_shared<Entry>(std::move(provider));
    if (!entry->Refresh()) {
      return -1;
    }
    const int64_t texture_id =
        registrar_->RegisterTexture(&entry->texture);
    if (texture_id < 0) {
      return -1;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    entries_[texture_id] = std::move(entry);
    return texture_id;
  }

  bool MarkFrameAvailable(int64_t texture_id) override {
    std::shared_ptr<Entry> entry;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const auto found = entries_.find(texture_id);
      if (found == entries_.end()) {
        return false;
      }
      entry = found->second;
    }
    return entry != nullptr && registrar_ != nullptr &&
           registrar_->MarkTextureFrameAvailable(texture_id);
  }

  bool UnregisterTexture(int64_t texture_id) override {
    std::shared_ptr<Entry> entry;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const auto found = entries_.find(texture_id);
      if (found == entries_.end()) {
        return false;
      }
      entry = found->second;
    }
    if (registrar_ == nullptr ||
        !registrar_->UnregisterTexture(texture_id)) {
      return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.erase(texture_id);
    return true;
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
      if (view.bgra == nullptr || view.width == 0 || view.height == 0 ||
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

  flutter::TextureRegistrar* registrar_;
  std::mutex mutex_;
  std::unordered_map<int64_t, std::shared_ptr<Entry>> entries_;
};

}  // namespace

std::unique_ptr<TextureRegistry> CreateFlutterTextureRegistry(
    flutter::TextureRegistrar* registrar) {
  if (registrar == nullptr) {
    return nullptr;
  }
  return std::make_unique<FlutterTextureRegistry>(registrar);
}

}  // namespace hmw
