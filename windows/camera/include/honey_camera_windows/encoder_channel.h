#pragma once

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string_view>

#include "honey_camera_windows/camera_preview.h"
#include "honey_media_windows/platform_dispatcher.h"
#include "honey_media_windows/texture_registry.h"

namespace hmw {
using FlutterResult = flutter::MethodResult<flutter::EncodableValue>;
}

namespace hcw {

struct CameraReady {
  int64_t texture_id;
  uint32_t width;
  uint32_t height;
};

struct CameraControllerCallbacks {
  std::function<void(CameraReady)> on_ready;
  std::function<void(hmw::Error)> on_error;
};

class CameraTextureController final {
 public:
  CameraTextureController(hmw::TextureRegistry& texture_registry,
                          hmw::PlatformDispatcher& dispatcher,
                          CameraSourceFactory source_factory);
  ~CameraTextureController();

  CameraTextureController(const CameraTextureController&) = delete;
  CameraTextureController& operator=(const CameraTextureController&) = delete;

  hmw::Outcome Open(CameraPreviewConfig config,
                    CameraControllerCallbacks callbacks);
  hmw::Outcome Close();

 private:
  struct State;

  static void PublishFrame(const std::weak_ptr<State>& weak_state,
                           CameraFrame frame) noexcept;
  static void PublishError(const std::weak_ptr<State>& weak_state,
                           hmw::Error error) noexcept;
  static hmw::Outcome ScheduleUnregisters(const std::shared_ptr<State>& state);
  static void RetainUnregisterLocked(State& state, int64_t texture_id);
  static bool ClaimPendingUnregister(const std::shared_ptr<State>& state,
                                     int64_t texture_id);
  static void UnregisterOwnedTextureOnPlatform(
      const std::shared_ptr<State>& state, int64_t texture_id);
  static void ResetPendingUnregister(const std::shared_ptr<State>& state,
                                     int64_t texture_id);

  std::shared_ptr<State> state_;
  std::unique_ptr<CameraPreviewSession> session_;
};

using EncoderEventSender = std::function<void(flutter::EncodableValue event)>;

class EncoderChannel final {
 public:
  EncoderChannel(CameraTextureController& controller,
                 EncoderEventSender event_sender);
  ~EncoderChannel();

  EncoderChannel(const EncoderChannel&) = delete;
  EncoderChannel& operator=(const EncoderChannel&) = delete;

  void Handle(std::string_view method, const flutter::EncodableValue* arguments,
              std::unique_ptr<hmw::FlutterResult> result);
  void Shutdown();

 private:
  struct State;

  CameraTextureController& controller_;
  std::shared_ptr<State> state_;
};

}  // namespace hcw
