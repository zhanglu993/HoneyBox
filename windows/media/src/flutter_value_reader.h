#pragma once

#include "honey_media_windows/media_converter.h"

#include <flutter/encodable_value.h>

#include <string_view>

namespace hmw {

Result<MediaJobRequest> ParseConverterRequest(
    std::string_view method, const flutter::EncodableValue* arguments);
flutter::EncodableValue EncodeConverterResult(const MediaJobResult& result);
std::string_view FlutterErrorCode(Status status);

}  // namespace hmw
