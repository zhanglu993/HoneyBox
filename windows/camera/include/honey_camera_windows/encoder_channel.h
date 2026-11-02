#pragma once

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string_view>

#include "honey_camera_windows/camera_encoding_session.h"
#include "honey_camera_windows/camera_preview.h"
#include "honey_camera_windows/camera_texture_cleanup.h"
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
  std::function<void(uint64_t, CameraFrame)> on_frame;
};

class CameraTextureController final {
 public:
  CameraTextureController(
      std::shared_ptr<CameraTextureCleanupCoordinator> cleanup,
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
                           uint64_t preview_generation,
                           CameraFrame frame) noexcept;
  static void PublishError(const std::weak_ptr<State>& weak_state,
                           hmw::Error error) noexcept;
  std::shared_ptr<CameraTextureCleanupCoordinator> cleanup_;
  std::shared_ptr<State> state_;
  std::unique_ptr<CameraPreviewSession> session_;
};

using EncoderEventSender = std::function<void(flutter::EncodableValue event)>;

class EncoderChannel final {
 public:
  EncoderChannel(CameraTextureController& controller, EncodingSession& session,
                 EncoderEventSender event_sender);
  ~EncoderChannel();

  EncoderChannel(const EncoderChannel&) = delete;
  EncoderChannel& operator=(const EncoderChannel&) = delete;

  void Handle(std::string_view method, const flutter::EncodableValue* arguments,
              std::unique_ptr<hmw::FlutterResult> result);
  void Shutdown();

 private:
  struct State;

  void HandleOpenCamera(const flutter::EncodableValue* arguments,
                        std::unique_ptr<hmw::FlutterResult> result);
  void HandleCloseCamera(std::unique_ptr<hmw::FlutterResult> result);
  void HandleStartEncoding(const flutter::EncodableValue* arguments,
                           std::unique_ptr<hmw::FlutterResult> result);
  void HandleStopEncoding(std::unique_ptr<hmw::FlutterResult> result);
  void HandleEncoderRequest(std::string_view method,
                            std::unique_ptr<hmw::FlutterResult> result);
  hmw::EncoderCallbacks MakeEncoderCallbacks(uint64_t epoch);
  void StopEncodingRun();

  static void SendCameraEvent(const std::weak_ptr<State>& weak_state,
                              uint64_t generation, bool terminal,
                              flutter::EncodableValue event) noexcept;
  static void SendEncoderEvent(const std::weak_ptr<State>& weak_state,
                               uint64_t epoch,
                               flutter::EncodableValue event) noexcept;
  static void RetireEncodingRun(const std::weak_ptr<State>& weak_state,
                                uint64_t epoch) noexcept;

  CameraTextureController& controller_;
  EncodingSession& session_;
  std::shared_ptr<State> state_;
};

}  // namespace hcw
