#include "honey_media_windows/windows_media_plugin.h"

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
        dispatcher_(registrar->GetView() == nullptr
                        ? nullptr
                        : registrar->GetView()->GetNativeWindow()),
        controller_(dispatcher_),
        method_channel_(registrar->messenger(), "ebadge/converter",
                        &flutter::StandardMethodCodec::GetInstance()),
        converter_channel_(
            controller_,
            [this](uint32_t done, uint32_t total) {
              SendProgress(done, total);
            }) {
    window_proc_delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [](HWND, UINT message, WPARAM wparam,
           LPARAM lparam) -> std::optional<LRESULT> {
          return hmw::Win32PlatformDispatcher::HandleMessage(message, wparam,
                                                              lparam);
        });
    method_channel_.SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<hmw::FlutterResult> result) {
          converter_channel_.Handle(call.method_name(), call.arguments(),
                                    std::move(result));
        });
  }

  ~HoneyMediaWindowsPlugin() override {
    method_channel_.SetMethodCallHandler(nullptr);
    converter_channel_.Shutdown();
    if (window_proc_delegate_id_ != 0) {
      registrar_->UnregisterTopLevelWindowProcDelegate(
          window_proc_delegate_id_);
      window_proc_delegate_id_ = 0;
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
    method_channel_.InvokeMethod("onProgress", std::move(arguments));
  }

  flutter::PluginRegistrarWindows* registrar_;
  hmw::Win32PlatformDispatcher dispatcher_;
  hmw::ConversionController controller_;
  flutter::MethodChannel<flutter::EncodableValue> method_channel_;
  hmw::ConverterChannel converter_channel_;
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
