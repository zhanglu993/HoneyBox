#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace hmw {

enum class Status {
  kOk,
  kInvalidArgument,
  kNotFound,
  kUnsupportedMedia,
  kDecodeFailed,
  kEncodeFailed,
  kCodecUnavailable,
  kUnsupportedFeature,
  kPermissionDenied,
  kDeviceUnavailable,
  kDeviceLost,
  kIoError,
  kBusy,
  kCancelled,
  kInvalidState,
};

struct Error {
  Status status;
  std::string message;
};

std::string_view StatusCode(Status status);

template <typename T>
struct Result {
  std::optional<T> value;
  std::optional<Error> error;

  bool ok() const { return value.has_value(); }
};

struct Outcome {
  std::optional<Error> error;

  bool ok() const { return !error.has_value(); }
};

}  // namespace hmw
