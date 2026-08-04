#include "test_support.h"

#include "honey_media_windows/media_source.h"
#include "honey_media_windows/platform_dispatcher.h"
#include "honey_media_windows/texture_registry.h"
#include "honey_media_windows/windows_media_plugin.h"

#include <flutter/encodable_value.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

hmw::RgbaFrame ChannelFrame(uint8_t red) {
  return hmw::RgbaFrame{
      2, 1, 0, 1'000'000, {red, 20, 30, 255, 40, 50, 60, 255}};
}

class ChannelSource final : public hmw::FrameSource {
 public:
  const hmw::SourceInfo& info() const override { return info_; }

  hmw::Result<bool> ReadNext(hmw::RgbaFrame* frame) override {
    if (read_) {
      return hmw::Result<bool>{false, std::nullopt};
    }
    read_ = true;
    *frame = ChannelFrame(10);
    return hmw::Result<bool>{true, std::nullopt};
  }

  hmw::Outcome Seek(int64_t) override {
    read_ = false;
    return hmw::Outcome{std::nullopt};
  }

 private:
  hmw::SourceInfo info_{2, 1, 10'000'000, 10.0, 0, false};
  bool read_ = false;
};

class ChannelTextureRegistry final : public hmw::TextureRegistry {
 public:
  int64_t RegisterPixelBufferTexture(
      hmw::PixelBufferProvider provider) override {
    const int64_t id = next_id_++;
    providers_.push_back({id, std::move(provider)});
    return id;
  }

  bool MarkFrameAvailable(int64_t id) override {
    for (auto& entry : providers_) {
      if (entry.first == id) {
        const hmw::PixelBufferView view = entry.second();
        return view.rgba != nullptr && view.byte_count == 8 &&
               view.width == 2 && view.height == 1;
      }
    }
    return false;
  }

  bool UnregisterTexture(int64_t id) override {
    ++unregister_attempts;
    if (reject_next_unregister) {
      reject_next_unregister = false;
      return false;
    }
    unregistered.push_back(id);
    return true;
  }

  std::vector<int64_t> unregistered;
  int unregister_attempts = 0;
  bool reject_next_unregister = false;

 private:
  int64_t next_id_ = 41;
  std::vector<std::pair<int64_t, hmw::PixelBufferProvider>> providers_;
};

class ChannelDispatcher final : public hmw::PlatformDispatcher {
 public:
  bool Post(std::function<void()> callback) override {
    std::lock_guard<std::mutex> lock(mutex_);
    callbacks_.push_back(std::move(callback));
    return true;
  }

  void Drain() {
    std::vector<std::function<void()>> callbacks;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      callbacks.swap(callbacks_);
    }
    for (auto& callback : callbacks) {
      callback();
    }
  }

 private:
  std::mutex mutex_;
  std::vector<std::function<void()>> callbacks_;
};

struct ChannelCapture {
  uint32_t successes = 0;
  uint32_t errors = 0;
  uint32_t not_implemented = 0;
  std::string error_code;
  std::optional<EncodableValue> value;
};

class ChannelResult final : public hmw::FlutterResult {
 public:
  explicit ChannelResult(std::shared_ptr<ChannelCapture> capture)
      : capture_(std::move(capture)) {}

 protected:
  void SuccessInternal(const EncodableValue* result) override {
    ++capture_->successes;
    if (result != nullptr) {
      capture_->value = *result;
    }
  }

  void ErrorInternal(const std::string& error_code, const std::string&,
                     const EncodableValue*) override {
    ++capture_->errors;
    capture_->error_code = error_code;
  }

  void NotImplementedInternal() override {
    ++capture_->not_implemented;
  }

 private:
  std::shared_ptr<ChannelCapture> capture_;
};

std::unique_ptr<hmw::FlutterResult> CaptureResult(
    const std::shared_ptr<ChannelCapture>& capture) {
  return std::make_unique<ChannelResult>(capture);
}

const EncodableValue* MapValue(const EncodableValue& encoded,
                               const char* key) {
  const auto* map = std::get_if<EncodableMap>(&encoded);
  if (map == nullptr) {
    return nullptr;
  }
  const auto found = map->find(EncodableValue(key));
  return found == map->end() ? nullptr : &found->second;
}

int64_t IntegerValue(const EncodableValue* value) {
  if (value == nullptr) {
    return -1;
  }
  if (const auto* integer = std::get_if<int64_t>(value)) {
    return *integer;
  }
  if (const auto* integer = std::get_if<int32_t>(value)) {
    return *integer;
  }
  return -1;
}

std::shared_ptr<ChannelCapture> Invoke(
    hmw::PlayerChannel& channel, std::string_view method,
    const EncodableValue* arguments) {
  auto capture = std::make_shared<ChannelCapture>();
  channel.Handle(method, arguments, CaptureResult(capture));
  return capture;
}

EncodableValue IdArguments(int64_t id) {
  return EncodableValue(EncodableMap{
      {EncodableValue("id"), EncodableValue(id)},
  });
}

}  // namespace

HMW_TEST(player_channel_matches_dart_contract_and_id_lifecycle) {
  ChannelTextureRegistry registry;
  ChannelDispatcher dispatcher;
  int open_count = 0;
  hmw::PlayerChannel channel(
      registry, dispatcher,
      [&open_count](const std::filesystem::path& path) {
        ++open_count;
        if (path != std::filesystem::path("sample.mp4")) {
          return hmw::Result<std::unique_ptr<hmw::FrameSource>>{
              std::nullopt,
              hmw::Error{hmw::Status::kNotFound, "missing source"}};
        }
        std::unique_ptr<hmw::FrameSource> source =
            std::make_unique<ChannelSource>();
        return hmw::Result<std::unique_ptr<hmw::FrameSource>>{
            std::move(source), std::nullopt};
      });

  EncodableValue create_arguments(EncodableMap{
      {EncodableValue("path"), EncodableValue("sample.mp4")},
  });
  auto first = Invoke(channel, "create", &create_arguments);
  HMW_EXPECT(first->successes == 1);
  HMW_EXPECT(first->value.has_value());
  if (!first->value.has_value()) {
    return;
  }
  const int64_t first_id =
      IntegerValue(MapValue(*first->value, "textureId"));
  HMW_EXPECT(first_id == 41);
  HMW_EXPECT(IntegerValue(MapValue(*first->value, "width")) == 2);
  HMW_EXPECT(IntegerValue(MapValue(*first->value, "height")) == 1);
  HMW_EXPECT(IntegerValue(MapValue(*first->value, "durationMs")) == 1000);

  auto second = Invoke(channel, "create", &create_arguments);
  HMW_EXPECT(second->successes == 1);
  HMW_EXPECT(second->value.has_value());
  const int64_t second_id =
      second->value.has_value()
          ? IntegerValue(MapValue(*second->value, "textureId"))
          : -1;
  HMW_EXPECT(second_id == 42);
  HMW_EXPECT(open_count == 2);

  EncodableValue first_id_arguments = IdArguments(first_id);
  HMW_EXPECT(Invoke(channel, "play", &first_id_arguments)->successes == 1);
  HMW_EXPECT(Invoke(channel, "pause", &first_id_arguments)->successes == 1);

  EncodableValue seek_arguments(EncodableMap{
      {EncodableValue("id"), EncodableValue(first_id)},
      {EncodableValue("positionMs"), EncodableValue(int32_t{250})},
  });
  HMW_EXPECT(Invoke(channel, "seekTo", &seek_arguments)->successes == 1);
  auto position = Invoke(channel, "position", &first_id_arguments);
  HMW_EXPECT(position->successes == 1);
  HMW_EXPECT(position->value.has_value());
  HMW_EXPECT(position->value.has_value() &&
             IntegerValue(&*position->value) == 250);

  HMW_EXPECT(Invoke(channel, "dispose", &first_id_arguments)->successes == 1);
  HMW_EXPECT(Invoke(channel, "dispose", &first_id_arguments)->successes == 1);

  EncodableValue unknown_id_arguments = IdArguments(999);
  auto unknown = Invoke(channel, "play", &unknown_id_arguments);
  HMW_EXPECT(unknown->errors == 1);
  HMW_EXPECT(unknown->error_code == "invalid_state");
  auto unknown_dispose =
      Invoke(channel, "dispose", &unknown_id_arguments);
  HMW_EXPECT(unknown_dispose->errors == 1);
  HMW_EXPECT(unknown_dispose->error_code == "invalid_state");

  auto unknown_method = Invoke(channel, "unknown", nullptr);
  HMW_EXPECT(unknown_method->not_implemented == 1);

  EncodableValue second_id_arguments = IdArguments(second_id);
  HMW_EXPECT(Invoke(channel, "dispose", &second_id_arguments)->successes == 1);
  HMW_EXPECT(registry.unregistered ==
             std::vector<int64_t>({first_id, second_id}));
  channel.Shutdown();
  dispatcher.Drain();
}
HMW_TEST(player_channel_decodes_dart_path_as_utf8) {
  ChannelTextureRegistry registry;
  ChannelDispatcher dispatcher;
  const std::string utf8_path =
      "\xE8\xA7\x86\xE9\xA2\x91.mp4";
  const std::filesystem::path expected_path =
      std::filesystem::u8path(utf8_path);
  hmw::PlayerChannel channel(
      registry, dispatcher,
      [&expected_path](const std::filesystem::path& path) {
        if (path != expected_path) {
          return hmw::Result<std::unique_ptr<hmw::FrameSource>>{
              std::nullopt,
              hmw::Error{hmw::Status::kNotFound, "path was not UTF-8"}};
        }
        std::unique_ptr<hmw::FrameSource> source =
            std::make_unique<ChannelSource>();
        return hmw::Result<std::unique_ptr<hmw::FrameSource>>{
            std::move(source), std::nullopt};
      });

  EncodableValue create_arguments(EncodableMap{
      {EncodableValue("path"), EncodableValue(utf8_path)},
  });
  auto created = Invoke(channel, "create", &create_arguments);
  HMW_EXPECT(created->successes == 1);
  HMW_EXPECT(created->value.has_value());
  if (created->value.has_value()) {
    const int64_t texture_id =
        IntegerValue(MapValue(*created->value, "textureId"));
    EncodableValue id_arguments = IdArguments(texture_id);
    HMW_EXPECT(Invoke(channel, "dispose", &id_arguments)->successes == 1);
  }
}

HMW_TEST(player_channel_retries_dispose_when_unregister_is_rejected) {
  ChannelTextureRegistry registry;
  ChannelDispatcher dispatcher;
  hmw::PlayerChannel channel(
      registry, dispatcher,
      [](const std::filesystem::path&) {
        std::unique_ptr<hmw::FrameSource> source =
            std::make_unique<ChannelSource>();
        return hmw::Result<std::unique_ptr<hmw::FrameSource>>{
            std::move(source), std::nullopt};
      });

  EncodableValue create_arguments(EncodableMap{
      {EncodableValue("path"), EncodableValue("retry.mp4")},
  });
  auto created = Invoke(channel, "create", &create_arguments);
  HMW_EXPECT(created->successes == 1);
  HMW_EXPECT(created->value.has_value());
  if (!created->value.has_value()) {
    return;
  }
  const int64_t texture_id =
      IntegerValue(MapValue(*created->value, "textureId"));
  EncodableValue id_arguments = IdArguments(texture_id);

  registry.reject_next_unregister = true;
  auto rejected = Invoke(channel, "dispose", &id_arguments);
  HMW_EXPECT(rejected->errors == 1);
  HMW_EXPECT(registry.unregister_attempts == 1);
  HMW_EXPECT(registry.unregistered.empty());

  auto retained = Invoke(channel, "position", &id_arguments);
  HMW_EXPECT(retained->successes == 1);
  HMW_EXPECT(retained->errors == 0);

  auto retried = Invoke(channel, "dispose", &id_arguments);
  HMW_EXPECT(retried->successes == 1);
  HMW_EXPECT(registry.unregister_attempts == 2);
  HMW_EXPECT(registry.unregistered ==
             std::vector<int64_t>({texture_id}));

  auto repeated = Invoke(channel, "dispose", &id_arguments);
  HMW_EXPECT(repeated->successes == 1);
  HMW_EXPECT(registry.unregister_attempts == 2);
}

HMW_TEST(player_channel_handle_keeps_player_alive_during_concurrent_dispose) {
  ChannelTextureRegistry registry;
  ChannelDispatcher dispatcher;
  std::mutex gate_mutex;
  std::condition_variable gate_condition;
  bool operation_captured = false;
  bool release_operation = false;
  hmw::PlayerChannel channel(
      registry, dispatcher,
      [](const std::filesystem::path&) {
        std::unique_ptr<hmw::FrameSource> source =
            std::make_unique<ChannelSource>();
        return hmw::Result<std::unique_ptr<hmw::FrameSource>>{
            std::move(source), std::nullopt};
      },
      [&] {
        std::unique_lock<std::mutex> lock(gate_mutex);
        operation_captured = true;
        gate_condition.notify_all();
        gate_condition.wait(lock, [&] { return release_operation; });
      });

  EncodableValue create_arguments(EncodableMap{
      {EncodableValue("path"), EncodableValue("concurrent.mp4")},
  });
  auto created = Invoke(channel, "create", &create_arguments);
  HMW_EXPECT(created->successes == 1);
  HMW_EXPECT(created->value.has_value());
  if (!created->value.has_value()) {
    return;
  }
  const int64_t texture_id =
      IntegerValue(MapValue(*created->value, "textureId"));
  EncodableValue id_arguments = IdArguments(texture_id);

  std::shared_ptr<ChannelCapture> position;
  std::thread operation_thread([&] {
    position = Invoke(channel, "position", &id_arguments);
  });
  {
    std::unique_lock<std::mutex> lock(gate_mutex);
    HMW_EXPECT(gate_condition.wait_for(
        lock, std::chrono::seconds(2),
        [&] { return operation_captured; }));
  }

  auto disposed = Invoke(channel, "dispose", &id_arguments);
  HMW_EXPECT(disposed->successes == 1);
  {
    std::lock_guard<std::mutex> lock(gate_mutex);
    release_operation = true;
    gate_condition.notify_all();
  }
  operation_thread.join();

  HMW_EXPECT(position != nullptr);
  HMW_EXPECT(position->errors == 1);
  HMW_EXPECT(position->error_code == "invalid_state");
  HMW_EXPECT(registry.unregister_attempts == 1);
}

HMW_TEST(player_channel_handle_keeps_player_alive_during_concurrent_shutdown) {
  ChannelTextureRegistry registry;
  ChannelDispatcher dispatcher;
  std::mutex gate_mutex;
  std::condition_variable gate_condition;
  bool operation_captured = false;
  bool release_operation = false;
  hmw::PlayerChannel channel(
      registry, dispatcher,
      [](const std::filesystem::path&) {
        std::unique_ptr<hmw::FrameSource> source =
            std::make_unique<ChannelSource>();
        return hmw::Result<std::unique_ptr<hmw::FrameSource>>{
            std::move(source), std::nullopt};
      },
      [&] {
        std::unique_lock<std::mutex> lock(gate_mutex);
        operation_captured = true;
        gate_condition.notify_all();
        gate_condition.wait(lock, [&] { return release_operation; });
      });

  EncodableValue create_arguments(EncodableMap{
      {EncodableValue("path"), EncodableValue("shutdown.mp4")},
  });
  auto created = Invoke(channel, "create", &create_arguments);
  HMW_EXPECT(created->successes == 1);
  HMW_EXPECT(created->value.has_value());
  if (!created->value.has_value()) {
    return;
  }
  const int64_t texture_id =
      IntegerValue(MapValue(*created->value, "textureId"));
  EncodableValue id_arguments = IdArguments(texture_id);

  std::shared_ptr<ChannelCapture> position;
  std::thread operation_thread([&] {
    position = Invoke(channel, "position", &id_arguments);
  });
  {
    std::unique_lock<std::mutex> lock(gate_mutex);
    HMW_EXPECT(gate_condition.wait_for(
        lock, std::chrono::seconds(2),
        [&] { return operation_captured; }));
  }

  channel.Shutdown();
  {
    std::lock_guard<std::mutex> lock(gate_mutex);
    release_operation = true;
    gate_condition.notify_all();
  }
  operation_thread.join();

  HMW_EXPECT(position != nullptr);
  HMW_EXPECT(position->errors == 1);
  HMW_EXPECT(position->error_code == "invalid_state");
  HMW_EXPECT(registry.unregister_attempts == 1);
  auto after_shutdown = Invoke(channel, "position", &id_arguments);
  HMW_EXPECT(after_shutdown->errors == 1);
}
