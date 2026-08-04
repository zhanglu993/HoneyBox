#include "test_support.h"

#include "honey_media_windows/windows_media_plugin.h"

#include <flutter/texture_registrar.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace hmw {
std::unique_ptr<TextureRegistry> CreateFlutterTextureRegistryForTesting(
    flutter::TextureRegistrar* registrar,
    std::function<void()> before_insert);
}

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
      ++async_unregister_count;
    }
    if (throw_next_unregister) {
      throw_next_unregister = false;
      throw std::runtime_error("unregister rejected");
    }
    auto complete = [this, texture_id, callback = std::move(callback)] {
      if (texture_id == 41) {
        texture_ = nullptr;
      }
      if (callback) {
        callback();
      }
    };
    if (delay_unregister) {
      pending_unregister = std::move(complete);
    } else {
      complete();
    }
  }

  bool UnregisterTexture(int64_t texture_id) override {
    if (texture_id != 41) {
      return false;
    }
    ++unregister_count;
    ++sync_unregister_count;
    texture_ = nullptr;
    return true;
  }

  void CompletePendingUnregister() {
    std::function<void()> pending = std::move(pending_unregister);
    if (pending) {
      pending();
    }
  }

  flutter::TextureVariant* texture_ = nullptr;
  const uint8_t* last_buffer = nullptr;
  size_t last_width = 0;
  size_t last_height = 0;
  int register_count = 0;
  int mark_count = 0;
  int unregister_count = 0;
  int async_unregister_count = 0;
  int sync_unregister_count = 0;
  bool delay_unregister = false;
  bool throw_next_unregister = false;
  std::function<void()> pending_unregister;
  std::vector<uint8_t> last_bytes;
};

}  // namespace

HMW_TEST(flutter_texture_registry_keeps_stable_rgba_storage) {
  FakeFlutterTextureRegistrar flutter_registrar;
  std::unique_ptr<hmw::TextureRegistry> registry =
      hmw::CreateFlutterTextureRegistry(&flutter_registrar);
  HMW_EXPECT(registry != nullptr);
  if (!registry) {
    return;
  }

  auto source = std::make_shared<std::vector<uint8_t>>(
      std::initializer_list<uint8_t>{255, 0, 0, 17, 0, 0, 255, 23});
  const int64_t texture_id = registry->RegisterPixelBufferTexture(
      [&source] {
        return hmw::PixelBufferView{
            source, source->data(), source->size(), 2, 1};
      });
  HMW_EXPECT(texture_id == 41);
  HMW_EXPECT(flutter_registrar.register_count == 1);

  HMW_EXPECT(registry->MarkFrameAvailable(texture_id));
  const uint8_t* first_buffer = flutter_registrar.last_buffer;
  HMW_EXPECT(first_buffer != nullptr);
  HMW_EXPECT(flutter_registrar.last_width == 2);
  HMW_EXPECT(flutter_registrar.last_height == 1);
  HMW_EXPECT(flutter_registrar.last_bytes == *source);

  *source = {0, 0, 255, 31, 255, 0, 0, 37};
  HMW_EXPECT(registry->MarkFrameAvailable(texture_id));
  HMW_EXPECT(flutter_registrar.last_buffer == first_buffer);
  HMW_EXPECT(flutter_registrar.last_bytes == *source);

  HMW_EXPECT(registry->UnregisterTexture(texture_id));
  HMW_EXPECT(flutter_registrar.unregister_count == 1);
}

HMW_TEST(flutter_texture_registry_owns_rgba_snapshot_during_concurrent_copy) {
  FakeFlutterTextureRegistrar flutter_registrar;
  std::unique_ptr<hmw::TextureRegistry> registry =
      hmw::CreateFlutterTextureRegistry(&flutter_registrar);
  HMW_EXPECT(registry != nullptr);
  if (!registry) {
    return;
  }

  std::mutex mutex;
  std::condition_variable condition;
  auto initial = std::make_shared<const std::vector<uint8_t>>(
      std::initializer_list<uint8_t>{255, 0, 0, 17, 0, 0, 255, 23});
  std::weak_ptr<const std::vector<uint8_t>> old_snapshot = initial;
  std::shared_ptr<const std::vector<uint8_t>> current = initial;
  bool second_snapshot_captured = false;
  bool publisher_replaced_snapshot = false;
  int provider_calls = 0;

  const int64_t texture_id = registry->RegisterPixelBufferTexture([&] {
    std::unique_lock<std::mutex> lock(mutex);
    std::shared_ptr<const std::vector<uint8_t>> snapshot = current;
    ++provider_calls;
    if (provider_calls == 2) {
      second_snapshot_captured = true;
      condition.notify_all();
      condition.wait(lock, [&] { return publisher_replaced_snapshot; });
    }
    return hmw::PixelBufferView{
        snapshot, snapshot->data(), snapshot->size(), 2, 1};
  });
  HMW_EXPECT(texture_id == 41);

  bool marked = false;
  std::thread mark_thread([&] {
    marked = registry->MarkFrameAvailable(texture_id);
  });
  {
    std::unique_lock<std::mutex> lock(mutex);
    HMW_EXPECT(condition.wait_for(
        lock, std::chrono::seconds(2),
        [&] { return second_snapshot_captured; }));
    current = std::make_shared<const std::vector<uint8_t>>(
        std::initializer_list<uint8_t>{0, 0, 255, 31, 255, 0, 0, 37});
    initial.reset();
    HMW_EXPECT(!old_snapshot.expired());
    publisher_replaced_snapshot = true;
    condition.notify_all();
  }
  mark_thread.join();

  HMW_EXPECT(marked);
  HMW_EXPECT(flutter_registrar.last_bytes ==
             std::vector<uint8_t>({255, 0, 0, 17, 0, 0, 255, 23}));
  HMW_EXPECT(old_snapshot.expired());
}

HMW_TEST(flutter_texture_registry_keeps_entry_until_async_unregister_completes) {
  FakeFlutterTextureRegistrar flutter_registrar;
  flutter_registrar.delay_unregister = true;
  std::unique_ptr<hmw::TextureRegistry> registry =
      hmw::CreateFlutterTextureRegistry(&flutter_registrar);
  HMW_EXPECT(registry != nullptr);
  if (!registry) {
    return;
  }

  auto source = std::make_shared<const std::vector<uint8_t>>(
      std::initializer_list<uint8_t>{11, 12, 13, 255,
                                     14, 15, 16, 255});
  std::weak_ptr<const std::vector<uint8_t>> source_lifetime = source;
  const int64_t texture_id = registry->RegisterPixelBufferTexture(
      [source] {
        return hmw::PixelBufferView{
            source, source->data(), source->size(), 2, 1};
      });
  HMW_EXPECT(texture_id == 41);

  HMW_EXPECT(registry->UnregisterTexture(texture_id));
  source.reset();
  HMW_EXPECT(flutter_registrar.async_unregister_count == 1);
  HMW_EXPECT(flutter_registrar.sync_unregister_count == 0);
  HMW_EXPECT(flutter_registrar.texture_ != nullptr);
  HMW_EXPECT(!source_lifetime.expired());
  HMW_EXPECT(flutter_registrar.MarkTextureFrameAvailable(texture_id));

  flutter_registrar.CompletePendingUnregister();
  HMW_EXPECT(flutter_registrar.texture_ == nullptr);
  HMW_EXPECT(source_lifetime.expired());
}

HMW_TEST(flutter_texture_registry_retries_rejected_unregister_request) {
  FakeFlutterTextureRegistrar flutter_registrar;
  flutter_registrar.throw_next_unregister = true;
  std::unique_ptr<hmw::TextureRegistry> registry =
      hmw::CreateFlutterTextureRegistry(&flutter_registrar);
  HMW_EXPECT(registry != nullptr);
  if (!registry) {
    return;
  }

  auto source = std::make_shared<const std::vector<uint8_t>>(
      std::initializer_list<uint8_t>{21, 22, 23, 255,
                                     24, 25, 26, 255});
  const int64_t texture_id = registry->RegisterPixelBufferTexture(
      [source] {
        return hmw::PixelBufferView{
            source, source->data(), source->size(), 2, 1};
      });
  HMW_EXPECT(texture_id == 41);

  HMW_EXPECT(!registry->UnregisterTexture(texture_id));
  HMW_EXPECT(flutter_registrar.texture_ != nullptr);
  HMW_EXPECT(registry->MarkFrameAvailable(texture_id));

  flutter_registrar.delay_unregister = true;
  HMW_EXPECT(registry->UnregisterTexture(texture_id));
  HMW_EXPECT(flutter_registrar.async_unregister_count == 2);
  HMW_EXPECT(flutter_registrar.texture_ != nullptr);
  flutter_registrar.CompletePendingUnregister();
  HMW_EXPECT(flutter_registrar.texture_ == nullptr);
}

HMW_TEST(flutter_texture_registry_destructor_keeps_entry_until_unregister_done) {
  FakeFlutterTextureRegistrar flutter_registrar;
  flutter_registrar.delay_unregister = true;
  std::unique_ptr<hmw::TextureRegistry> registry =
      hmw::CreateFlutterTextureRegistry(&flutter_registrar);
  HMW_EXPECT(registry != nullptr);
  if (!registry) {
    return;
  }

  auto source = std::make_shared<const std::vector<uint8_t>>(
      std::initializer_list<uint8_t>{31, 32, 33, 255,
                                     34, 35, 36, 255});
  std::weak_ptr<const std::vector<uint8_t>> source_lifetime = source;
  const int64_t texture_id = registry->RegisterPixelBufferTexture(
      [source] {
        return hmw::PixelBufferView{
            source, source->data(), source->size(), 2, 1};
      });
  HMW_EXPECT(texture_id == 41);

  source.reset();
  registry.reset();
  HMW_EXPECT(flutter_registrar.async_unregister_count == 1);
  HMW_EXPECT(flutter_registrar.sync_unregister_count == 0);
  HMW_EXPECT(flutter_registrar.texture_ != nullptr);
  HMW_EXPECT(!source_lifetime.expired());
  HMW_EXPECT(flutter_registrar.MarkTextureFrameAvailable(texture_id));

  flutter_registrar.CompletePendingUnregister();
  HMW_EXPECT(flutter_registrar.texture_ == nullptr);
  HMW_EXPECT(source_lifetime.expired());
}

HMW_TEST(flutter_texture_registry_rolls_back_when_map_insert_throws) {
  FakeFlutterTextureRegistrar flutter_registrar;
  flutter_registrar.delay_unregister = true;
  std::unique_ptr<hmw::TextureRegistry> registry =
      hmw::CreateFlutterTextureRegistryForTesting(
          &flutter_registrar, [] { throw std::bad_alloc(); });
  HMW_EXPECT(registry != nullptr);
  if (!registry) {
    return;
  }

  auto source = std::make_shared<const std::vector<uint8_t>>(
      std::initializer_list<uint8_t>{41, 42, 43, 255,
                                     44, 45, 46, 255});
  std::weak_ptr<const std::vector<uint8_t>> source_lifetime = source;
  int64_t texture_id = 0;
  bool threw = false;
  try {
    texture_id = registry->RegisterPixelBufferTexture(
        [source] {
          return hmw::PixelBufferView{
              source, source->data(), source->size(), 2, 1};
        });
  } catch (...) {
    threw = true;
  }

  HMW_EXPECT(!threw);
  HMW_EXPECT(texture_id < 0);
  source.reset();
  HMW_EXPECT(flutter_registrar.register_count == 1);
  HMW_EXPECT(flutter_registrar.async_unregister_count == 1);
  HMW_EXPECT(flutter_registrar.sync_unregister_count == 0);
  HMW_EXPECT(flutter_registrar.texture_ != nullptr);
  HMW_EXPECT(!source_lifetime.expired());
  HMW_EXPECT(flutter_registrar.MarkTextureFrameAvailable(41));

  flutter_registrar.CompletePendingUnregister();
  HMW_EXPECT(flutter_registrar.texture_ == nullptr);
  HMW_EXPECT(source_lifetime.expired());
}

HMW_TEST(
    flutter_texture_registry_keeps_failed_insert_entry_when_rollback_throws) {
  FakeFlutterTextureRegistrar flutter_registrar;
  flutter_registrar.delay_unregister = true;
  flutter_registrar.throw_next_unregister = true;
  std::unique_ptr<hmw::TextureRegistry> registry =
      hmw::CreateFlutterTextureRegistryForTesting(
          &flutter_registrar, [] { throw std::bad_alloc(); });
  HMW_EXPECT(registry != nullptr);
  if (!registry) {
    return;
  }

  auto source = std::make_shared<const std::vector<uint8_t>>(
      std::initializer_list<uint8_t>{51, 52, 53, 255,
                                     54, 55, 56, 255});
  std::weak_ptr<const std::vector<uint8_t>> source_lifetime = source;
  const int64_t texture_id = registry->RegisterPixelBufferTexture(
      [source] {
        return hmw::PixelBufferView{
            source, source->data(), source->size(), 2, 1};
      });

  HMW_EXPECT(texture_id < 0);
  source.reset();
  HMW_EXPECT(flutter_registrar.register_count == 1);
  HMW_EXPECT(flutter_registrar.async_unregister_count == 1);
  HMW_EXPECT(flutter_registrar.texture_ != nullptr);
  HMW_EXPECT(!source_lifetime.expired());

  registry.reset();
  HMW_EXPECT(flutter_registrar.async_unregister_count == 2);
  HMW_EXPECT(flutter_registrar.texture_ != nullptr);
  HMW_EXPECT(!source_lifetime.expired());

  flutter_registrar.CompletePendingUnregister();
  HMW_EXPECT(flutter_registrar.texture_ == nullptr);
  HMW_EXPECT(source_lifetime.expired());
}

HMW_TEST(
    flutter_texture_registry_destructor_safely_leaks_when_unregister_throws) {
  FakeFlutterTextureRegistrar flutter_registrar;
  std::unique_ptr<hmw::TextureRegistry> registry =
      hmw::CreateFlutterTextureRegistry(&flutter_registrar);
  HMW_EXPECT(registry != nullptr);
  if (!registry) {
    return;
  }

  auto source = std::make_shared<const std::vector<uint8_t>>(
      std::initializer_list<uint8_t>{61, 62, 63, 255,
                                     64, 65, 66, 255});
  std::weak_ptr<const std::vector<uint8_t>> source_lifetime = source;
  const int64_t texture_id = registry->RegisterPixelBufferTexture(
      [source] {
        return hmw::PixelBufferView{
            source, source->data(), source->size(), 2, 1};
      });
  HMW_EXPECT(texture_id == 41);

  source.reset();
  flutter_registrar.throw_next_unregister = true;
  registry.reset();

  HMW_EXPECT(flutter_registrar.async_unregister_count == 1);
  HMW_EXPECT(flutter_registrar.sync_unregister_count == 0);
  HMW_EXPECT(flutter_registrar.texture_ != nullptr);
  HMW_EXPECT(!source_lifetime.expired());
}
