#include "honey_media_windows/windows_media_plugin.h"

#include "video_texture_player.h"

#include <flutter/encodable_value.h>

#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace hmw {
namespace {

const flutter::EncodableMap* ArgumentsMap(
    const flutter::EncodableValue* arguments) {
  return arguments == nullptr
             ? nullptr
             : std::get_if<flutter::EncodableMap>(arguments);
}

const flutter::EncodableValue* FindArgument(
    const flutter::EncodableMap* arguments, const char* key) {
  if (arguments == nullptr) {
    return nullptr;
  }
  const auto found = arguments->find(flutter::EncodableValue(key));
  return found == arguments->end() ? nullptr : &found->second;
}

std::optional<int64_t> IntegerArgument(
    const flutter::EncodableMap* arguments, const char* key) {
  const flutter::EncodableValue* value = FindArgument(arguments, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  if (const auto* integer = std::get_if<int64_t>(value)) {
    return *integer;
  }
  if (const auto* integer = std::get_if<int32_t>(value)) {
    return static_cast<int64_t>(*integer);
  }
  return std::nullopt;
}

void CompleteOutcome(const std::shared_ptr<FlutterResult>& result,
                     Outcome outcome) {
  if (!outcome.ok()) {
    CompleteFlutterError(result, *outcome.error);
    return;
  }
  result->Success();
}

void CompleteInvalidPlayer(
    const std::shared_ptr<FlutterResult>& result) {
  CompleteFlutterError(
      result,
      Error{Status::kInvalidState, "video player id is not active"});
}

}  // namespace

struct PlayerChannel::State {
  State(TextureRegistry& registry, PlatformDispatcher& platform_dispatcher,
        PlayerSourceOpener opener, PlayerOperationGate gate)
      : texture_registry(registry),
        dispatcher(platform_dispatcher),
        source_opener(std::move(opener)),
        operation_gate(std::move(gate)) {}

  TextureRegistry& texture_registry;
  PlatformDispatcher& dispatcher;
  PlayerSourceOpener source_opener;
  PlayerOperationGate operation_gate;
  std::mutex mutex;
  bool alive = true;
  std::unordered_map<int64_t, std::shared_ptr<VideoTexturePlayer>> players;
  std::unordered_set<int64_t> disposed_ids;
};

PlayerChannel::PlayerChannel(TextureRegistry& texture_registry,
                             PlatformDispatcher& dispatcher,
                             PlayerSourceOpener source_opener,
                             PlayerOperationGate operation_gate)
    : state_(std::make_unique<State>(
          texture_registry, dispatcher, std::move(source_opener),
          std::move(operation_gate))) {}

PlayerChannel::~PlayerChannel() { Shutdown(); }

void PlayerChannel::Handle(
    std::string_view method, const flutter::EncodableValue* arguments,
    std::unique_ptr<FlutterResult> result) {
  if (!result) {
    return;
  }
  auto retained = std::shared_ptr<FlutterResult>(std::move(result));
  if (method != "create" && method != "play" && method != "pause" &&
      method != "seekTo" && method != "position" &&
      method != "dispose") {
    retained->NotImplemented();
    return;
  }

  const flutter::EncodableMap* map = ArgumentsMap(arguments);
  if (method == "create") {
    const flutter::EncodableValue* path_value =
        FindArgument(map, "path");
    const auto* path =
        path_value == nullptr
            ? nullptr
            : std::get_if<std::string>(path_value);
    if (path == nullptr || path->empty()) {
      retained->Error("bad_args", "path required");
      return;
    }

    PlayerSourceOpener opener;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!state_->alive) {
        CompleteInvalidPlayer(retained);
        return;
      }
      opener = state_->source_opener;
    }
    Result<std::unique_ptr<FrameSource>> source =
        opener(std::filesystem::u8path(*path));
    if (!source.ok()) {
      retained->Error(
          "player_failed",
          source.error.has_value() ? source.error->message
                                   : "video source open failed");
      return;
    }
    Result<std::unique_ptr<VideoTexturePlayer>> created =
        VideoTexturePlayer::Create(std::move(*source.value),
                                   state_->texture_registry,
                                   state_->dispatcher);
    if (!created.ok()) {
      retained->Error(
          "player_failed",
          created.error.has_value() ? created.error->message
                                    : "video player create failed");
      return;
    }
    std::shared_ptr<VideoTexturePlayer> player(
        std::move(*created.value));
    const int64_t texture_id = player->texture_id();
    const uint32_t width = player->width();
    const uint32_t height = player->height();
    const int64_t duration_ms = player->duration_ms();
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!state_->alive ||
          state_->players.find(texture_id) != state_->players.end()) {
        (void)player->Dispose();
        CompleteInvalidPlayer(retained);
        return;
      }
      state_->disposed_ids.erase(texture_id);
      state_->players.emplace(texture_id, std::move(player));
    }
    retained->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("textureId"),
         flutter::EncodableValue(texture_id)},
        {flutter::EncodableValue("width"),
         flutter::EncodableValue(static_cast<int64_t>(width))},
        {flutter::EncodableValue("height"),
         flutter::EncodableValue(static_cast<int64_t>(height))},
        {flutter::EncodableValue("durationMs"),
         flutter::EncodableValue(duration_ms)},
    }));
    return;
  }

  const std::optional<int64_t> id = IntegerArgument(map, "id");
  if (!id.has_value() || *id < 0) {
    CompleteInvalidPlayer(retained);
    return;
  }

  if (method == "dispose") {
    std::shared_ptr<VideoTexturePlayer> player;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      auto found = state_->players.find(*id);
      if (found == state_->players.end()) {
        if (state_->disposed_ids.find(*id) !=
            state_->disposed_ids.end()) {
          retained->Success();
        } else {
          CompleteInvalidPlayer(retained);
        }
        return;
      }
      player = found->second;
    }
    Outcome disposed = player->Dispose();
    if (!disposed.ok()) {
      CompleteOutcome(retained, std::move(disposed));
      return;
    }
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      const auto found = state_->players.find(*id);
      if (found != state_->players.end() &&
          found->second == player) {
        state_->players.erase(found);
      }
      state_->disposed_ids.insert(*id);
    }
    retained->Success();
    return;
  }

  std::shared_ptr<VideoTexturePlayer> player;
  PlayerOperationGate operation_gate;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    const auto found = state_->players.find(*id);
    if (!state_->alive || found == state_->players.end()) {
      CompleteInvalidPlayer(retained);
      return;
    }
    player = found->second;
    operation_gate = state_->operation_gate;
  }
  if (operation_gate) {
    try {
      operation_gate();
    } catch (...) {
      CompleteFlutterError(
          retained, Error{Status::kInvalidState,
                          "video player operation gate failed"});
      return;
    }
  }

  if (method == "play") {
    CompleteOutcome(retained, player->Play());
  } else if (method == "pause") {
    CompleteOutcome(retained, player->Pause());
  } else if (method == "seekTo") {
    const std::optional<int64_t> position =
        IntegerArgument(map, "positionMs");
    CompleteOutcome(retained, player->Seek(position.value_or(0)));
  } else {
    Result<int64_t> position = player->Position();
    if (!position.ok()) {
      CompleteFlutterError(retained, *position.error);
    } else {
      retained->Success(
          flutter::EncodableValue(*position.value));
    }
  }
}

void PlayerChannel::Shutdown() {
  std::unordered_map<int64_t, std::shared_ptr<VideoTexturePlayer>>
      players;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->alive) {
      return;
    }
    state_->alive = false;
    players.swap(state_->players);
  }
  for (auto& entry : players) {
    (void)entry.second->Dispose();
  }
}

}  // namespace hmw
