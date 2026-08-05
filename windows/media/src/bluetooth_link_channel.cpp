#include "bluetooth_link_channel.h"

#include "honey_media_windows/status.h"

#include <string>
#include <utility>

namespace hmw {
namespace {

const flutter::EncodableValue* FindArgument(
    const flutter::EncodableValue* arguments, const char* key) {
  const auto* map = arguments == nullptr
                        ? nullptr
                        : std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return nullptr;
  }
  const auto found = map->find(flutter::EncodableValue(key));
  return found == map->end() ? nullptr : &found->second;
}

bool AddressArgument(const flutter::EncodableValue* arguments,
                     uint64_t* address) {
  const flutter::EncodableValue* value = FindArgument(arguments, "remoteId");
  const auto* text = value == nullptr ? nullptr
                                      : std::get_if<std::string>(value);
  return text != nullptr && ParseBluetoothAddress(*text, address);
}

}  // namespace

BluetoothLinkChannel::BluetoothLinkChannel(
    std::unique_ptr<BluetoothLinkTuner> tuner)
    : tuner_(std::move(tuner)) {}

BluetoothLinkChannel::~BluetoothLinkChannel() { Shutdown(); }

void BluetoothLinkChannel::Handle(
    std::string_view method, const flutter::EncodableValue* arguments,
    std::unique_ptr<FlutterResult> result) {
  if (!result) {
    return;
  }
  if (method != "requestThroughput" && method != "releaseThroughput") {
    result->NotImplemented();
    return;
  }
  uint64_t address = 0U;
  if (!AddressArgument(arguments, &address)) {
    result->Error("invalid_argument",
                  "remoteId must be an AA:BB:CC:DD:EE:FF address");
    return;
  }
  if (!tuner_) {
    result->Error("invalid_state", "Bluetooth link tuner is unavailable");
    return;
  }
  if (method == "releaseThroughput") {
    tuner_->Release(address);
    result->Success();
    return;
  }
  const Outcome requested = tuner_->RequestThroughput(address);
  if (!requested.ok()) {
    result->Error(std::string(StatusCode(requested.error->status)),
                  requested.error->message);
    return;
  }
  result->Success();
}

void BluetoothLinkChannel::Shutdown() {
  if (tuner_) {
    tuner_->Shutdown();
  }
}

}  // namespace hmw
