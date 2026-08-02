#include "test_support.h"

#include "honey_media_windows/windows_media_plugin.h"

#include <flutter/texture_registrar.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <utility>
#include <vector>

namespace {

class FakeFlutterTextureRegistrar final : public flutter::TextureRegistrar {
 public:
  int64_t RegisterTexture(flutter::TextureVariant* texture) override {
    texture_ = texture;
    ++register_count;
    return 41;
  }

  bool MarkTextureFrameAvailable(int64_t texture_id) override {
    if (texture_id != 41 || texture_ == nullptr) {
      return false;
    }
    auto* pixel_texture =
        std::get_if<flutter::PixelBufferTexture>(texture_);
    if (pixel_texture == nullptr) {
      return false;
    }
    const FlutterDesktopPixelBuffer* buffer =
        pixel_texture->CopyPixelBuffer(2, 1);
    if (buffer == nullptr) {
      return false;
    }
    last_buffer = buffer->buffer;
    last_width = buffer->width;
    last_height = buffer->height;
    last_bytes.assign(buffer->buffer, buffer->buffer + 8);
    ++mark_count;
    return true;
  }

  void UnregisterTexture(int64_t texture_id,
                         std::function<void()> callback) override {
    if (texture_id == 41) {
      ++unregister_count;
      texture_ = nullptr;
    }
    if (callback) {
      callback();
    }
  }

  bool UnregisterTexture(int64_t texture_id) override {
    if (texture_id != 41) {
      return false;
    }
    ++unregister_count;
    texture_ = nullptr;
    return true;
  }

  flutter::TextureVariant* texture_ = nullptr;
  const uint8_t* last_buffer = nullptr;
  size_t last_width = 0;
  size_t last_height = 0;
  int register_count = 0;
  int mark_count = 0;
  int unregister_count = 0;
  std::vector<uint8_t> last_bytes;
};

}  // namespace

HMW_TEST(flutter_texture_registry_keeps_stable_bgra_storage) {
  FakeFlutterTextureRegistrar flutter_registrar;
  std::unique_ptr<hmw::TextureRegistry> registry =
      hmw::CreateFlutterTextureRegistry(&flutter_registrar);
  HMW_EXPECT(registry != nullptr);
  if (!registry) {
    return;
  }

  std::vector<uint8_t> source{1, 2, 3, 255, 4, 5, 6, 255};
  const int64_t texture_id = registry->RegisterPixelBufferTexture(
      [&source] {
        return hmw::PixelBufferView{
            source.data(), source.size(), 2, 1};
      });
  HMW_EXPECT(texture_id == 41);
  HMW_EXPECT(flutter_registrar.register_count == 1);

  HMW_EXPECT(registry->MarkFrameAvailable(texture_id));
  const uint8_t* first_buffer = flutter_registrar.last_buffer;
  HMW_EXPECT(first_buffer != nullptr);
  HMW_EXPECT(flutter_registrar.last_width == 2);
  HMW_EXPECT(flutter_registrar.last_height == 1);
  HMW_EXPECT(flutter_registrar.last_bytes == source);

  source = {9, 8, 7, 255, 6, 5, 4, 255};
  HMW_EXPECT(registry->MarkFrameAvailable(texture_id));
  HMW_EXPECT(flutter_registrar.last_buffer == first_buffer);
  HMW_EXPECT(flutter_registrar.last_bytes == source);

  HMW_EXPECT(registry->UnregisterTexture(texture_id));
  HMW_EXPECT(flutter_registrar.unregister_count == 1);
}
