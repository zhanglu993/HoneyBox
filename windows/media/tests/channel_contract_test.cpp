#include "honey_media_windows/channel_contract.h"

#include "test_support.h"

#include <string_view>
#include <vector>

HMW_TEST(channel_contract_lists_every_existing_dart_method) {
  HMW_EXPECT(hmw::ConverterMethodNames() == std::vector<std::string_view>{
      "getVideoThumbnail", "previewFrames", "convertVideo", "encodeScroll",
      "encodeFrames", "decodeCvid", "cancelConvert"});
  HMW_EXPECT(hmw::PlayerMethodNames() == std::vector<std::string_view>{
      "create", "play", "pause", "seekTo", "position", "dispose"});
}
