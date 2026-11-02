#include "honey_media_windows/channel_contract.h"

namespace hmw {

std::vector<std::string_view> ConverterMethodNames() {
  return {"getVideoThumbnail", "previewFrames", "convertVideo", "encodeScroll",
          "encodeFrames", "decodeCvid", "cancelConvert"};
}

std::vector<std::string_view> PlayerMethodNames() {
  return {"create", "play", "pause", "seekTo", "position", "dispose"};
}

}  // namespace hmw
