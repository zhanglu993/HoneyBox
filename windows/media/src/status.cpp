#include "honey_media_windows/status.h"

namespace hmw {

std::string_view StatusCode(Status status) {
  switch (status) {
    case Status::kOk: return "ok";
    case Status::kInvalidArgument: return "invalid_argument";
    case Status::kNotFound: return "not_found";
    case Status::kUnsupportedMedia: return "unsupported_media";
    case Status::kDecodeFailed: return "decode_failed";
    case Status::kEncodeFailed: return "encode_failed";
    case Status::kCodecUnavailable: return "codec_unavailable";
    case Status::kUnsupportedFeature: return "unsupported_feature";
    case Status::kPermissionDenied: return "permission_denied";
    case Status::kDeviceUnavailable: return "device_unavailable";
    case Status::kDeviceLost: return "device_lost";
    case Status::kIoError: return "io_error";
    case Status::kBusy: return "busy";
    case Status::kCancelled: return "cancelled";
    case Status::kInvalidState: return "invalid_state";
  }
  return "invalid_state";
}

}  // namespace hmw
