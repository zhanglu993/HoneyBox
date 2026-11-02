#include "flutter_value_reader.h"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <limits>
#include <optional>
#include <string>
#include <utility>

namespace hmw {
namespace {

template <typename T>
Result<T> Invalid(std::string message) {
  return Result<T>{std::nullopt,
                   Error{Status::kInvalidArgument, std::move(message)}};
}

const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                    std::string_view key) {
  const auto found = map.find(flutter::EncodableValue(std::string(key)));
  return found == map.end() ? nullptr : &found->second;
}

class MapReader {
 public:
  explicit MapReader(const flutter::EncodableMap& map) : map_(map) {}

  std::optional<std::string> RequiredString(std::string_view key) {
    const auto* value = Find(map_, key);
    if (value == nullptr || !std::holds_alternative<std::string>(*value)) {
      SetError(std::string(key) + " must be a string");
      return std::nullopt;
    }
    const auto& text = std::get<std::string>(*value);
    if (text.empty()) {
      SetError(std::string(key) + " must not be empty");
      return std::nullopt;
    }
    return text;
  }

  std::optional<std::string> String(std::string_view key,
                                    std::string default_value) {
    const auto* value = Find(map_, key);
    if (value == nullptr) {
      return default_value;
    }
    if (!std::holds_alternative<std::string>(*value)) {
      SetError(std::string(key) + " must be a string");
      return std::nullopt;
    }
    return std::get<std::string>(*value);
  }

  std::optional<uint32_t> Uint(std::string_view key, uint32_t default_value) {
    const auto* value = Find(map_, key);
    if (value == nullptr) {
      return default_value;
    }
    const auto integer = value->TryGetLongValue();
    if (!integer.has_value() || *integer < 0 ||
        static_cast<uint64_t>(*integer) >
            std::numeric_limits<uint32_t>::max()) {
      SetError(std::string(key) + " must be an unsigned 32-bit integer");
      return std::nullopt;
    }
    return static_cast<uint32_t>(*integer);
  }

  std::optional<double> Number(std::string_view key) {
    const auto* value = Find(map_, key);
    if (value == nullptr) {
      SetError(std::string(key) + " is required");
      return std::nullopt;
    }
    if (std::holds_alternative<double>(*value)) {
      return std::get<double>(*value);
    }
    const auto integer = value->TryGetLongValue();
    if (integer.has_value()) {
      return static_cast<double>(*integer);
    }
    SetError(std::string(key) + " must be numeric");
    return std::nullopt;
  }

  const flutter::EncodableValue* Value(std::string_view key) const {
    return Find(map_, key);
  }

  bool ok() const { return !error_.has_value(); }
  const std::string& error() const { return *error_; }

 private:
  void SetError(std::string message) {
    if (!error_.has_value()) {
      error_ = std::move(message);
    }
  }

  const flutter::EncodableMap& map_;
  std::optional<std::string> error_;
};

Result<MediaJobRequest> ParseConversion(const flutter::EncodableMap& map) {
  MapReader reader(map);
  auto path = reader.RequiredString("path");
  auto width = reader.Uint("width", 360);
  auto height = reader.Uint("height", 360);
  auto fps = reader.Uint("fps", 10);
  auto quality = reader.Uint("quality", 60);
  auto refine = reader.Uint("refine", 3);
  auto strips = reader.Uint("strips", 2);
  auto skip = reader.Uint("skipThresh", 720);
  auto key_interval = reader.Uint("keyint", 0);
  auto max_frames = reader.Uint("maxFrames", 300);
  auto background = reader.Uint("bgColor", UINT32_C(0xFF000000));
  auto crop_mode = reader.String("cropMode", "cover");

  FitMode fit = FitMode::kCover;
  if (crop_mode.has_value() && *crop_mode == "contain") {
    fit = FitMode::kContain;
  } else if (crop_mode.has_value() && *crop_mode != "cover") {
    return Invalid<MediaJobRequest>("cropMode must be cover or contain");
  }

  std::optional<CropRect> crop;
  if (const auto* crop_value = reader.Value("crop"); crop_value != nullptr) {
    const auto* crop_map = std::get_if<flutter::EncodableMap>(crop_value);
    if (crop_map == nullptr) {
      return Invalid<MediaJobRequest>("crop must be a map");
    }
    MapReader crop_reader(*crop_map);
    auto x = crop_reader.Number("nx");
    auto y = crop_reader.Number("ny");
    auto crop_width = crop_reader.Number("nw");
    auto crop_height = crop_reader.Number("nh");
    if (!crop_reader.ok()) {
      return Invalid<MediaJobRequest>(crop_reader.error());
    }
    if (!std::isfinite(*x) || !std::isfinite(*y) ||
        !std::isfinite(*crop_width) || !std::isfinite(*crop_height) ||
        *crop_width <= 0.0 || *crop_height <= 0.0 || *x >= 1.0 ||
        *y >= 1.0 || *x + *crop_width <= 0.0 ||
        *y + *crop_height <= 0.0) {
      return Invalid<MediaJobRequest>("crop rectangle is invalid");
    }
    crop = CropRect{*x, *y, *crop_width, *crop_height};
  }

  if (!reader.ok()) {
    return Invalid<MediaJobRequest>(reader.error());
  }
  ConversionRequest request{
      std::filesystem::u8path(*path), *width, *height, *fps, *quality,
      *refine, *strips, *skip, *key_interval, *max_frames, *background,
      fit, std::move(crop)};
  return Result<MediaJobRequest>{MediaJobRequest(std::move(request)),
                                 std::nullopt};
}

Result<MediaJobRequest> ParsePathRequest(std::string_view method,
                                         const flutter::EncodableMap& map) {
  MapReader reader(map);
  auto path = reader.RequiredString("path");
  if (method == "getVideoThumbnail") {
    if (!reader.ok()) {
      return Invalid<MediaJobRequest>(reader.error());
    }
    return Result<MediaJobRequest>{
        MediaJobRequest(ThumbnailRequest{std::filesystem::u8path(*path)}),
        std::nullopt};
  }
  if (method == "previewFrames") {
    auto max_count = reader.Uint("maxCount", 48);
    auto max_edge = reader.Uint("maxEdge", 240);
    if (!reader.ok()) {
      return Invalid<MediaJobRequest>(reader.error());
    }
    return Result<MediaJobRequest>{MediaJobRequest(PreviewRequest{
                                       std::filesystem::u8path(*path),
                                       *max_count, *max_edge}),
                                   std::nullopt};
  }
  auto max_count = reader.Uint("maxCount", 60);
  auto max_edge = reader.Uint("maxEdge", 200);
  if (!reader.ok()) {
    return Invalid<MediaJobRequest>(reader.error());
  }
  return Result<MediaJobRequest>{MediaJobRequest(DecodeCvidRequest{
                                     std::filesystem::u8path(*path),
                                     *max_count, *max_edge}),
                                 std::nullopt};
}

bool CheckedRgbaBytes(uint32_t width, uint32_t height, size_t* byte_count) {
  constexpr size_t kBytesPerPixel = 4;
  if (width == 0 || height == 0 ||
      static_cast<size_t>(width) >
          std::numeric_limits<size_t>::max() / kBytesPerPixel / height) {
    return false;
  }
  *byte_count = static_cast<size_t>(width) * height * kBytesPerPixel;
  return true;
}

Result<MediaJobRequest> ParseSlideshow(const flutter::EncodableMap& map) {
  MapReader reader(map);
  auto size = reader.Uint("size", 360);
  auto fps = reader.Uint("fps", 10);
  auto quality = reader.Uint("quality", 60);
  const auto* frames_value = reader.Value("frames");
  const auto* holds_value = reader.Value("holds");
  const auto* frames = frames_value == nullptr
                           ? nullptr
                           : std::get_if<flutter::EncodableList>(frames_value);
  const auto* holds = holds_value == nullptr
                          ? nullptr
                          : std::get_if<flutter::EncodableList>(holds_value);
  if (!reader.ok()) {
    return Invalid<MediaJobRequest>(reader.error());
  }
  if (frames == nullptr || holds == nullptr || frames->empty() ||
      frames->size() != holds->size()) {
    return Invalid<MediaJobRequest>(
        "frames and holds must be non-empty lists of equal length");
  }
  size_t expected_bytes = 0;
  if (*size == 0 || !CheckedRgbaBytes(*size, *size, &expected_bytes)) {
    return Invalid<MediaJobRequest>("size is invalid");
  }

  SlideshowRequest request{{}, {}, *size, *fps, *quality};
  request.frames.reserve(frames->size());
  request.holds.reserve(holds->size());
  for (size_t index = 0; index < frames->size(); ++index) {
    const auto* pixels =
        std::get_if<std::vector<uint8_t>>(&frames->at(index));
    const auto hold = holds->at(index).TryGetLongValue();
    if (pixels == nullptr || pixels->size() != expected_bytes) {
      return Invalid<MediaJobRequest>(
          "each frame must be a tightly packed RGBA byte array");
    }
    if (!hold.has_value() || *hold < 1 ||
        static_cast<uint64_t>(*hold) >
            std::numeric_limits<uint32_t>::max()) {
      return Invalid<MediaJobRequest>("each hold must be a positive integer");
    }
    request.frames.push_back(RgbaFrame{*size, *size, 0, 0, *pixels});
    request.holds.push_back(static_cast<uint32_t>(*hold));
  }
  return Result<MediaJobRequest>{MediaJobRequest(std::move(request)),
                                 std::nullopt};
}

Result<MediaJobRequest> ParseScroll(const flutter::EncodableMap& map) {
  MapReader reader(map);
  auto strip_width = reader.Uint("stripW", 0);
  auto strip_height = reader.Uint("stripH", 0);
  auto size = reader.Uint("size", 360);
  auto background = reader.Uint("bgColor", UINT32_C(0xFF000000));
  auto speed = reader.Uint("speed", 120);
  auto fps = reader.Uint("fps", 15);
  auto quality = reader.Uint("quality", 80);
  auto max_frames = reader.Uint("maxFrames", 300);
  const auto* strip_value = reader.Value("strip");
  const auto* pixels = strip_value == nullptr
                           ? nullptr
                           : std::get_if<std::vector<uint8_t>>(strip_value);
  if (!reader.ok()) {
    return Invalid<MediaJobRequest>(reader.error());
  }
  if (*strip_width == 0 || *strip_height == 0 || pixels == nullptr) {
    return Invalid<MediaJobRequest>("strip, stripW and stripH are required");
  }
  size_t expected_bytes = 0;
  if (!CheckedRgbaBytes(*strip_width, *strip_height, &expected_bytes) ||
      pixels->size() != expected_bytes) {
    return Invalid<MediaJobRequest>(
        "strip must be a tightly packed RGBA byte array");
  }
  auto gap = reader.Uint("gap", *size);
  if (!reader.ok()) {
    return Invalid<MediaJobRequest>(reader.error());
  }
  ScrollRequest request{RgbaFrame{*strip_width, *strip_height, 0, 0, *pixels},
                        *size, *background, *speed, *fps, *gap, *quality,
                        *max_frames};
  return Result<MediaJobRequest>{MediaJobRequest(std::move(request)),
                                 std::nullopt};
}

}  // namespace

Result<MediaJobRequest> ParseConverterRequest(
    std::string_view method, const flutter::EncodableValue* arguments) {
  if (arguments == nullptr) {
    return Invalid<MediaJobRequest>("arguments must be a map");
  }
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return Invalid<MediaJobRequest>("arguments must be a map");
  }
  if (method == "convertVideo") {
    return ParseConversion(*map);
  }
  if (method == "getVideoThumbnail" || method == "previewFrames" ||
      method == "decodeCvid") {
    return ParsePathRequest(method, *map);
  }
  if (method == "encodeFrames") {
    return ParseSlideshow(*map);
  }
  if (method == "encodeScroll") {
    return ParseScroll(*map);
  }
  return Invalid<MediaJobRequest>("unknown converter method");
}

flutter::EncodableValue EncodeConverterResult(const MediaJobResult& result) {
  return std::visit(
      [](const auto& concrete) -> flutter::EncodableValue {
        using Concrete = std::decay_t<decltype(concrete)>;
        if constexpr (std::is_same_v<Concrete, ThumbnailResult>) {
          return flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("bytes"),
               flutter::EncodableValue(concrete.png)},
              {flutter::EncodableValue("width"),
               flutter::EncodableValue(static_cast<int64_t>(concrete.width))},
              {flutter::EncodableValue("height"),
               flutter::EncodableValue(static_cast<int64_t>(concrete.height))},
              {flutter::EncodableValue("isGif"),
               flutter::EncodableValue(concrete.is_gif)},
          });
        } else if constexpr (std::is_same_v<Concrete, PreviewResult>) {
          flutter::EncodableList frames;
          frames.reserve(concrete.png_frames.size());
          for (const auto& png : concrete.png_frames) {
            frames.emplace_back(png);
          }
          return flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("frames"),
               flutter::EncodableValue(std::move(frames))},
              {flutter::EncodableValue("intervalMs"),
               flutter::EncodableValue(
                   static_cast<int64_t>(concrete.interval_ms))},
          });
        } else {
          return flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("avi"),
               flutter::EncodableValue(concrete.avi)},
              {flutter::EncodableValue("width"),
               flutter::EncodableValue(static_cast<int64_t>(concrete.width))},
              {flutter::EncodableValue("height"),
               flutter::EncodableValue(static_cast<int64_t>(concrete.height))},
              {flutter::EncodableValue("frameCount"),
               flutter::EncodableValue(
                   static_cast<int64_t>(concrete.frame_count))},
              {flutter::EncodableValue("fps"),
               flutter::EncodableValue(concrete.fps)},
          });
        }
      },
      result);
}

std::string_view FlutterErrorCode(Status status) {
  return StatusCode(status);
}

}  // namespace hmw
