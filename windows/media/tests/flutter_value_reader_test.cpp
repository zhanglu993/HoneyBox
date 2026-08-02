#include "flutter_value_reader.h"
#include "test_support.h"

#include <flutter/encodable_value.h>

#include <cstdint>
#include <string>
#include <variant>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

const EncodableValue* MapValue(const EncodableValue& value,
                               const char* key) {
  const auto* map = std::get_if<EncodableMap>(&value);
  if (map == nullptr) {
    return nullptr;
  }
  const auto found = map->find(EncodableValue(key));
  return found == map->end() ? nullptr : &found->second;
}

HMW_TEST(convert_args_apply_android_compatible_defaults) {
  const EncodableMap arguments = {
      {EncodableValue("path"), EncodableValue("input.gif")},
  };
  const EncodableValue arguments_value(arguments);

  auto parsed = hmw::ParseConverterRequest("convertVideo", &arguments_value);

  HMW_EXPECT(parsed.ok());
  if (!parsed.ok()) {
    return;
  }
  const auto* request = std::get_if<hmw::ConversionRequest>(&*parsed.value);
  HMW_EXPECT(request != nullptr);
  if (request == nullptr) {
    return;
  }
  HMW_EXPECT(request->path == L"input.gif");
  HMW_EXPECT(request->width == 360);
  HMW_EXPECT(request->height == 360);
  HMW_EXPECT(request->fps == 10);
  HMW_EXPECT(request->quality == 60);
  HMW_EXPECT(request->refine == 3);
  HMW_EXPECT(request->strips == 2);
  HMW_EXPECT(request->skip_threshold == 720);
  HMW_EXPECT(request->key_interval == 0);
  HMW_EXPECT(request->max_frames == 300);
  HMW_EXPECT(request->background_argb == UINT32_C(0xFF000000));
  HMW_EXPECT(request->fit == hmw::FitMode::kCover);
  HMW_EXPECT(!request->crop.has_value());
}

HMW_TEST(convert_args_reject_wrong_types_and_bad_crop) {
  const EncodableMap wrong_path = {
      {EncodableValue("path"), EncodableValue(int32_t{7})},
  };
  const EncodableValue wrong_path_value(wrong_path);
  auto wrong_path_result =
      hmw::ParseConverterRequest("convertVideo", &wrong_path_value);
  HMW_EXPECT(!wrong_path_result.ok());
  HMW_EXPECT(wrong_path_result.error.has_value());
  if (wrong_path_result.error.has_value()) {
    HMW_EXPECT(wrong_path_result.error->status == hmw::Status::kInvalidArgument);
  }

  const EncodableMap crop = {
      {EncodableValue("nx"), EncodableValue(0.0)},
      {EncodableValue("ny"), EncodableValue(0.0)},
      {EncodableValue("nw"), EncodableValue(0.0)},
      {EncodableValue("nh"), EncodableValue(1.0)},
  };
  const EncodableMap bad_crop = {
      {EncodableValue("path"), EncodableValue("input.gif")},
      {EncodableValue("crop"), EncodableValue(crop)},
  };
  const EncodableValue bad_crop_value(bad_crop);
  auto bad_crop_result =
      hmw::ParseConverterRequest("convertVideo", &bad_crop_value);
  HMW_EXPECT(!bad_crop_result.ok());
  HMW_EXPECT(bad_crop_result.error.has_value());
  if (bad_crop_result.error.has_value()) {
    HMW_EXPECT(bad_crop_result.error->status == hmw::Status::kInvalidArgument);
  }
}

HMW_TEST(other_converter_args_map_to_requests_and_copy_typed_data) {
  const EncodableValue thumbnail_args(EncodableMap{
      {EncodableValue("path"), EncodableValue("thumb.mov")},
  });
  auto thumbnail =
      hmw::ParseConverterRequest("getVideoThumbnail", &thumbnail_args);
  HMW_EXPECT(thumbnail.ok());
  HMW_EXPECT(thumbnail.ok() &&
             std::holds_alternative<hmw::ThumbnailRequest>(*thumbnail.value));

  const EncodableValue preview_args(EncodableMap{
      {EncodableValue("path"), EncodableValue("preview.gif")},
  });
  auto preview = hmw::ParseConverterRequest("previewFrames", &preview_args);
  HMW_EXPECT(preview.ok());
  const auto* preview_request =
      preview.ok() ? std::get_if<hmw::PreviewRequest>(&*preview.value) : nullptr;
  HMW_EXPECT(preview_request != nullptr);
  if (preview_request != nullptr) {
    HMW_EXPECT(preview_request->max_count == 48);
    HMW_EXPECT(preview_request->max_edge == 240);
  }

  const EncodableValue decode_args(EncodableMap{
      {EncodableValue("path"), EncodableValue("cache.avi")},
  });
  auto decode = hmw::ParseConverterRequest("decodeCvid", &decode_args);
  HMW_EXPECT(decode.ok());
  const auto* decode_request =
      decode.ok() ? std::get_if<hmw::DecodeCvidRequest>(&*decode.value) : nullptr;
  HMW_EXPECT(decode_request != nullptr);
  if (decode_request != nullptr) {
    HMW_EXPECT(decode_request->max_count == 60);
    HMW_EXPECT(decode_request->max_edge == 200);
  }

  EncodableValue frames_args(EncodableMap{
      {EncodableValue("frames"),
       EncodableValue(flutter::EncodableList{
           EncodableValue(std::vector<uint8_t>(16, uint8_t{1}))})},
      {EncodableValue("holds"),
       EncodableValue(flutter::EncodableList{EncodableValue(int32_t{2})})},
      {EncodableValue("size"), EncodableValue(int32_t{2})},
  });
  auto frames = hmw::ParseConverterRequest("encodeFrames", &frames_args);
  HMW_EXPECT(frames.ok());
  const auto* frames_request =
      frames.ok() ? std::get_if<hmw::SlideshowRequest>(&*frames.value) : nullptr;
  HMW_EXPECT(frames_request != nullptr);
  if (frames_request != nullptr) {
    HMW_EXPECT(frames_request->holds == std::vector<uint32_t>{2});
    HMW_EXPECT(frames_request->fps == 10);
    HMW_EXPECT(frames_request->quality == 60);
    auto& source_map = std::get<EncodableMap>(frames_args);
    auto& source_frames = std::get<flutter::EncodableList>(
        source_map.at(EncodableValue("frames")));
    std::get<std::vector<uint8_t>>(source_frames[0])[0] = 9;
    HMW_EXPECT(frames_request->frames[0].pixels[0] == 1);
  }

  const EncodableValue scroll_args(EncodableMap{
      {EncodableValue("strip"),
       EncodableValue(std::vector<uint8_t>{1, 2, 3, 4})},
      {EncodableValue("stripW"), EncodableValue(int32_t{1})},
      {EncodableValue("stripH"), EncodableValue(int32_t{1})},
      {EncodableValue("size"), EncodableValue(int32_t{24})},
  });
  auto scroll = hmw::ParseConverterRequest("encodeScroll", &scroll_args);
  HMW_EXPECT(scroll.ok());
  const auto* scroll_request =
      scroll.ok() ? std::get_if<hmw::ScrollRequest>(&*scroll.value) : nullptr;
  HMW_EXPECT(scroll_request != nullptr);
  if (scroll_request != nullptr) {
    HMW_EXPECT(scroll_request->strip.pixels ==
               std::vector<uint8_t>({1, 2, 3, 4}));
    HMW_EXPECT(scroll_request->size == 24);
    HMW_EXPECT(scroll_request->gap == 24);
    HMW_EXPECT(scroll_request->background_argb == UINT32_C(0xFF000000));
    HMW_EXPECT(scroll_request->speed == 120);
    HMW_EXPECT(scroll_request->fps == 15);
    HMW_EXPECT(scroll_request->quality == 80);
    HMW_EXPECT(scroll_request->max_frames == 300);
  }
}

HMW_TEST(encode_frames_rejects_size_and_hold_mismatch) {
  const auto parse = [](size_t byte_count, size_t hold_count,
                        int64_t size) {
    flutter::EncodableList holds;
    for (size_t i = 0; i < hold_count; ++i) {
      holds.emplace_back(int32_t{1});
    }
    const EncodableValue value(EncodableMap{
        {EncodableValue("frames"),
         EncodableValue(flutter::EncodableList{
             EncodableValue(std::vector<uint8_t>(byte_count, uint8_t{0}))})},
        {EncodableValue("holds"), EncodableValue(std::move(holds))},
        {EncodableValue("size"), EncodableValue(size)},
    });
    return hmw::ParseConverterRequest("encodeFrames", &value);
  };
  HMW_EXPECT(!parse(15, 1, 2).ok());
  HMW_EXPECT(!parse(16, 0, 2).ok());
  HMW_EXPECT(!parse(0, 1, INT64_C(2147483648)).ok());
}

HMW_TEST(success_maps_match_converter_service_fields) {
  const auto thumbnail = hmw::EncodeConverterResult(hmw::MediaJobResult(
      hmw::ThumbnailResult{{1, 2}, UINT32_MAX, 4, true}));
  HMW_EXPECT(MapValue(thumbnail, "bytes") != nullptr);
  HMW_EXPECT(MapValue(thumbnail, "width") != nullptr);
  HMW_EXPECT(MapValue(thumbnail, "height") != nullptr);
  HMW_EXPECT(MapValue(thumbnail, "isGif") != nullptr);
  HMW_EXPECT(MapValue(thumbnail, "bytes") != nullptr &&
             std::get<std::vector<uint8_t>>(*MapValue(thumbnail, "bytes")) ==
                 std::vector<uint8_t>({1, 2}));
  HMW_EXPECT(MapValue(thumbnail, "width") != nullptr &&
             MapValue(thumbnail, "width")->LongValue() ==
                 INT64_C(4294967295));

  const auto preview = hmw::EncodeConverterResult(hmw::MediaJobResult(
      hmw::PreviewResult{{{3}, {4, 5}}, 125}));
  const auto* frames = MapValue(preview, "frames");
  HMW_EXPECT(frames != nullptr &&
             std::get<flutter::EncodableList>(*frames).size() == 2);
  HMW_EXPECT(MapValue(preview, "intervalMs") != nullptr &&
             MapValue(preview, "intervalMs")->LongValue() == 125);

  const auto conversion = hmw::EncodeConverterResult(hmw::MediaJobResult(
      hmw::ConversionResult{{6, 7}, 8, 9, 10, 12.5}));
  HMW_EXPECT(MapValue(conversion, "avi") != nullptr);
  HMW_EXPECT(MapValue(conversion, "width") != nullptr);
  HMW_EXPECT(MapValue(conversion, "height") != nullptr);
  HMW_EXPECT(MapValue(conversion, "frameCount") != nullptr);
  HMW_EXPECT(MapValue(conversion, "fps") != nullptr &&
             std::get<double>(*MapValue(conversion, "fps")) == 12.5);
}

HMW_TEST(status_maps_to_stable_flutter_error_code) {
  HMW_EXPECT(hmw::FlutterErrorCode(hmw::Status::kInvalidArgument) ==
             "invalid_argument");
  HMW_EXPECT(hmw::FlutterErrorCode(hmw::Status::kNotFound) == "not_found");
  HMW_EXPECT(hmw::FlutterErrorCode(hmw::Status::kUnsupportedMedia) ==
             "unsupported_media");
  HMW_EXPECT(hmw::FlutterErrorCode(hmw::Status::kDecodeFailed) ==
             "decode_failed");
  HMW_EXPECT(hmw::FlutterErrorCode(hmw::Status::kEncodeFailed) ==
             "encode_failed");
  HMW_EXPECT(hmw::FlutterErrorCode(hmw::Status::kIoError) == "io_error");
  HMW_EXPECT(hmw::FlutterErrorCode(hmw::Status::kBusy) == "busy");
  HMW_EXPECT(hmw::FlutterErrorCode(hmw::Status::kCancelled) == "cancelled");
  HMW_EXPECT(hmw::FlutterErrorCode(hmw::Status::kInvalidState) ==
             "invalid_state");
}

}  // namespace
