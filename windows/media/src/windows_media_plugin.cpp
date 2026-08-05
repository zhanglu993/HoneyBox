#include "honey_media_windows/windows_media_plugin.h"

#include "honey_camera_windows/camera_plugin_teardown.h"
#include "honey_camera_windows/encoder_channel.h"
#include "honey_camera_windows/windows_encoder_registration.h"
#include "windows_media_plugin_internal.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <utility>

namespace {

class HoneyMediaWindowsPlugin final : public flutter::Plugin {
 public:
  explicit HoneyMediaWindowsPlugin(
      flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar),
        dispatcher_(std::make_unique<hmw::Win32PlatformDispatcher>(
            registrar->GetView() == nullptr
                ? nullptr
                : hmw::internal::ResolvePluginDispatchWindow(
                      registrar->GetView()->GetNativeWindow()))),
        controller_(*dispatcher_),
        texture_registry_(
            hmw::CreateFlutterTextureRegistry(
                registrar->texture_registrar())),
        converter_method_channel_(
            registrar->messenger(), "ebadge/converter",
            &flutter::StandardMethodCodec::GetInstance()),
        player_method_channel_(
            registrar->messenger(), "ebadge/player",
            &flutter::StandardMethodCodec::GetInstance()),
        converter_channel_(
            controller_,
            [this](uint32_t done, uint32_t total) {
              SendProgress(done, total);
            }),
        player_channel_(*texture_registry_, *dispatcher_) {
    camera_cleanup_ = hcw::CameraTextureCleanupCoordinator::Create(
        *texture_registry_, *dispatcher_);
    camera_controller_ = std::make_unique<hcw::CameraTextureController>(
        camera_cleanup_, hcw::CreateMediaFoundationCameraFactory());
    // The codec factory and encoding session must exist before the channel
    // that routes Dart requests into them.
    encoding_session_ = std::make_unique<hcw::CameraEncodingSession>(
        hmw::CreateDefaultEncoderBackendFactory());
    encoder_channel_ = std::make_unique<hcw::EncoderChannel>(
        *camera_controller_, *encoding_session_,
        [this](flutter::EncodableValue event) {
          if (encoder_registration_) {
            encoder_registration_->SendEvent(std::move(event));
          }
        });
    encoder_registration_ = std::make_unique<hcw::WindowsEncoderRegistration>(
        *registrar_->messenger(), *dispatcher_,
        [this](std::string_view method,
               const flutter::EncodableValue* arguments,
               std::unique_ptr<hmw::FlutterResult> result) {
          if (!encoder_channel_) {
            result->NotImplemented();
            return;
          }
          encoder_channel_->Handle(method, arguments, std::move(result));
        });

    window_proc_delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [](HWND, UINT message, WPARAM wparam,
           LPARAM lparam) -> std::optional<LRESULT> {
          return hmw::Win32PlatformDispatcher::HandleMessage(message, wparam,
                                                              lparam);
        });
    converter_method_channel_.SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<hmw::FlutterResult> result) {
          converter_channel_.Handle(call.method_name(), call.arguments(),
                                    std::move(result));
        });
    player_method_channel_.SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<hmw::FlutterResult> result) {
          player_channel_.Handle(call.method_name(), call.arguments(),
                                 std::move(result));
        });
    camera_teardown_owner_ = hcw::CameraPluginTeardownOwner::Create(
        hcw::CreateCameraPluginCleanupGate(std::move(camera_cleanup_)),
        std::move(texture_registry_), std::move(dispatcher_));
  }

  ~HoneyMediaWindowsPlugin() override {
    if (encoder_registration_) {
      encoder_registration_->Shutdown();
    }
    player_method_channel_.SetMethodCallHandler(nullptr);
    converter_method_channel_.SetMethodCallHandler(nullptr);

    // Retire encoding before the channel that owns its callbacks, and both
    // before the camera controller that feeds them.
    if (encoding_session_) {
      encoding_session_->Shutdown();
    }
    if (encoder_channel_) {
      encoder_channel_->Shutdown();
    }
    encoder_registration_.reset();
    encoder_channel_.reset();
    encoding_session_.reset();
    camera_controller_.reset();

    player_channel_.Shutdown();
    converter_channel_.Shutdown();
    if (window_proc_delegate_id_ != 0) {
      registrar_->UnregisterTopLevelWindowProcDelegate(
          window_proc_delegate_id_);
      window_proc_delegate_id_ = 0;
    }
    camera_cleanup_.reset();
    // A reentrant cleanup keeps this owner alive until the outer operation
    // ends, then retries Shutdown before releasing registry and dispatcher.
    const hmw::Outcome teardown = camera_teardown_owner_->Teardown();
    // The concrete coordinator returns only success or reentrant invalid_state;
    // this owner exclusively owns its completion slot and accepts that
    // invalid_state as deferred work. Keep the owner until member teardown if
    // that closed contract is ever violated.
    if (teardown.ok()) {
      camera_teardown_owner_.reset();
    }
  }

  HoneyMediaWindowsPlugin(const HoneyMediaWindowsPlugin&) = delete;
  HoneyMediaWindowsPlugin& operator=(const HoneyMediaWindowsPlugin&) = delete;

 private:
  void SendProgress(uint32_t done, uint32_t total) {
    auto arguments =
        std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
            {flutter::EncodableValue("done"),
             flutter::EncodableValue(static_cast<int64_t>(done))},
            {flutter::EncodableValue("total"),
             flutter::EncodableValue(static_cast<int64_t>(total))},
        });
    converter_method_channel_.InvokeMethod(
        "onProgress", std::move(arguments));
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::shared_ptr<hcw::CameraPluginTeardownOwner>
      camera_teardown_owner_;
  std::unique_ptr<hmw::Win32PlatformDispatcher> dispatcher_;
  hmw::ConversionController controller_;
  std::unique_ptr<hmw::TextureRegistry> texture_registry_;
  std::shared_ptr<hcw::CameraTextureCleanupCoordinator> camera_cleanup_;
  std::unique_ptr<hcw::CameraTextureController> camera_controller_;
  std::unique_ptr<hcw::CameraEncodingSession> encoding_session_;
  std::unique_ptr<hcw::EncoderChannel> encoder_channel_;
  std::unique_ptr<hcw::WindowsEncoderRegistration> encoder_registration_;
  flutter::MethodChannel<flutter::EncodableValue>
      converter_method_channel_;
  flutter::MethodChannel<flutter::EncodableValue>
      player_method_channel_;
  hmw::ConverterChannel converter_channel_;
  hmw::PlayerChannel player_channel_;
  int window_proc_delegate_id_ = 0;
};

}  // namespace

void HoneyMediaWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows_registrar->AddPlugin(
      std::make_unique<HoneyMediaWindowsPlugin>(windows_registrar));
}
