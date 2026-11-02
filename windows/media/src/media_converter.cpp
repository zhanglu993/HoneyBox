#include "honey_media_windows/media_converter.h"
#include "media_converter_internal.h"

#include "honey_media_core/media_core.h"
#include "honey_media_windows/media_source.h"
#include "honey_media_windows/png_codec.h"
#include "honey_media_windows/rgba_transform.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace hmw::internal {

Result<ConversionResult> EncodeCinepakFrames(
    uint32_t width, uint32_t height, uint32_t frame_rate_num,
    uint32_t frame_rate_den, uint32_t frame_count, uint32_t quality,
    uint32_t refine, uint32_t strips, uint32_t skip_threshold,
    uint32_t key_interval,
    const std::function<Result<std::reference_wrapper<const RgbaFrame>>(
        uint32_t)>& produce_frame,
    const std::function<bool(uint32_t)>& force_key, Progress progress,
    IsCancelled cancelled);

}  // namespace hmw::internal

namespace hmw {
namespace {

constexpr uint32_t kCvid = HMC_MEDIA_FOURCC('c', 'v', 'i', 'd');

template <typename T>
Result<T> Failure(Status status, std::string message) {
  return Result<T>{std::nullopt, Error{status, std::move(message)}};
}

template <typename T, typename U>
Result<T> ForwardError(Result<U> failed) {
  return Result<T>{std::nullopt, std::move(failed.error)};
}

bool IsCancellationRequested(const IsCancelled& cancelled) {
  return cancelled && cancelled();
}

template <typename T>
Result<T> Cancelled() {
  return Failure<T>(Status::kCancelled, "media operation cancelled");
}

bool CheckedPixelBytes(uint32_t width, uint32_t height, size_t* bytes) {
  const uint64_t count = static_cast<uint64_t>(width) * height * 4U;
  if (count > std::numeric_limits<size_t>::max()) {
    return false;
  }
  *bytes = static_cast<size_t>(count);
  return true;
}

bool IsTightlyPacked(const RgbaFrame& frame) {
  size_t bytes = 0;
  return frame.width != 0 && frame.height != 0 &&
         CheckedPixelBytes(frame.width, frame.height, &bytes) &&
         frame.pixels.size() == bytes;
}

bool ValidFit(FitMode fit) {
  return fit == FitMode::kCover || fit == FitMode::kContain;
}

bool ValidCrop(const std::optional<CropRect>& crop) {
  if (!crop) {
    return true;
  }
  return std::isfinite(crop->x) && std::isfinite(crop->y) &&
         std::isfinite(crop->width) && std::isfinite(crop->height) &&
         crop->width > 0.0 && crop->height > 0.0 && crop->x < 1.0 &&
         crop->y < 1.0 && crop->x + crop->width > 0.0 &&
         crop->y + crop->height > 0.0;
}

bool AlignUpFour(uint32_t value, uint32_t* aligned) {
  if (value == 0 || value > 65532U) {
    return false;
  }
  *aligned = (value + 3U) & ~UINT32_C(3);
  return *aligned <= 65532U;
}

bool ValidFps(uint32_t fps) {
  return fps != 0 && fps <= 1000000U;
}

bool ValidQuality(uint32_t quality) { return quality <= 100U; }

void CompositeOverOpaqueBackground(RgbaFrame* frame, uint32_t background_argb) {
  const uint32_t opaque = background_argb | UINT32_C(0xff000000);
  const uint32_t background_red = (opaque >> 16U) & 0xffU;
  const uint32_t background_green = (opaque >> 8U) & 0xffU;
  const uint32_t background_blue = opaque & 0xffU;
  for (size_t offset = 0; offset < frame->pixels.size(); offset += 4U) {
    const uint32_t alpha = frame->pixels[offset + 3U];
    const uint32_t inverse = 255U - alpha;
    frame->pixels[offset] = static_cast<uint8_t>(
        (frame->pixels[offset] * alpha + background_red * inverse + 127U) /
        255U);
    frame->pixels[offset + 1U] = static_cast<uint8_t>(
        (frame->pixels[offset + 1U] * alpha + background_green * inverse +
         127U) /
        255U);
    frame->pixels[offset + 2U] = static_cast<uint8_t>(
        (frame->pixels[offset + 2U] * alpha + background_blue * inverse +
         127U) /
        255U);
    frame->pixels[offset + 3U] = 255U;
  }
}

Result<RgbaFrame> ResizeToMaxEdge(const RgbaFrame& source,
                                  uint32_t max_edge) {
  if (!IsTightlyPacked(source) || max_edge == 0) {
    return Failure<RgbaFrame>(Status::kInvalidArgument,
                              "preview frame or maximum edge is invalid");
  }
  const uint32_t source_edge = std::max(source.width, source.height);
  if (source_edge <= max_edge) {
    return Result<RgbaFrame>{source, std::nullopt};
  }
  const double scale = static_cast<double>(max_edge) / source_edge;
  const uint32_t width = std::max(
      1U, static_cast<uint32_t>(std::floor(source.width * scale + 0.5)));
  const uint32_t height = std::max(
      1U, static_cast<uint32_t>(std::floor(source.height * scale + 0.5)));
  size_t byte_count = 0;
  if (!CheckedPixelBytes(width, height, &byte_count)) {
    return Failure<RgbaFrame>(Status::kInvalidArgument,
                              "preview dimensions overflow");
  }
  try {
    std::vector<uint8_t> pixels(byte_count);
    for (uint32_t y = 0; y < height; ++y) {
      const uint32_t source_y = static_cast<uint32_t>(
          static_cast<uint64_t>(y) * source.height / height);
      for (uint32_t x = 0; x < width; ++x) {
        const uint32_t source_x = static_cast<uint32_t>(
            static_cast<uint64_t>(x) * source.width / width);
        const size_t source_offset =
            (static_cast<size_t>(source_y) * source.width + source_x) * 4U;
        const size_t output_offset =
            (static_cast<size_t>(y) * width + x) * 4U;
        std::copy_n(source.pixels.data() + source_offset, 4U,
                    pixels.data() + output_offset);
      }
    }
    return Result<RgbaFrame>{
        RgbaFrame{width, height, source.pts_100ns, source.duration_100ns,
                  std::move(pixels)},
        std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<RgbaFrame>(Status::kIoError,
                              "preview resize allocation failed");
  }
}

internal::PngEncoder& PngEncoderOverride() {
  static thread_local internal::PngEncoder encoder;
  return encoder;
}

Result<std::vector<uint8_t>> EncodePngForMedia(const RgbaFrame& frame) {
  internal::PngEncoder& encoder = PngEncoderOverride();
  return encoder ? encoder(frame) : EncodePng(frame);
}

Result<std::vector<uint8_t>> PreviewPng(const RgbaFrame& frame,
                                        uint32_t max_edge,
                                        const IsCancelled& cancelled) {
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<std::vector<uint8_t>>();
  }
  Result<RgbaFrame> resized = ResizeToMaxEdge(frame, max_edge);
  if (!resized.ok()) {
    return ForwardError<std::vector<uint8_t>>(std::move(resized));
  }
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<std::vector<uint8_t>>();
  }
  Result<std::vector<uint8_t>> png = EncodePngForMedia(*resized.value);
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<std::vector<uint8_t>>();
  }
  if (!png.ok()) {
    return png;
  }
  return png;
}

Result<std::vector<uint8_t>> ReadFile(const std::filesystem::path& path,
                                      const IsCancelled& cancelled) {
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<std::vector<uint8_t>>();
  }
  std::error_code error;
  const uintmax_t file_size = std::filesystem::file_size(path, error);
  if (error == std::errc::no_such_file_or_directory) {
    return Failure<std::vector<uint8_t>>(Status::kNotFound,
                                         "cached AVI file was not found");
  }
  if (error) {
    return Failure<std::vector<uint8_t>>(Status::kIoError,
                                         "cached AVI size query failed");
  }
  if (file_size == 0 || file_size > std::numeric_limits<size_t>::max() ||
      file_size > static_cast<uintmax_t>(
                      std::numeric_limits<std::streamsize>::max())) {
    return Failure<std::vector<uint8_t>>(Status::kDecodeFailed,
                                         "cached AVI size is invalid");
  }
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<std::vector<uint8_t>>();
  }
  try {
    std::vector<uint8_t> bytes(static_cast<size_t>(file_size));
    std::ifstream input(path, std::ios::binary);
    if (!input) {
      return Failure<std::vector<uint8_t>>(Status::kIoError,
                                           "cached AVI open failed");
    }
    if (IsCancellationRequested(cancelled)) {
      return Cancelled<std::vector<uint8_t>>();
    }
    input.read(reinterpret_cast<char*>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
    if (!input || input.gcount() != static_cast<std::streamsize>(bytes.size())) {
      return Failure<std::vector<uint8_t>>(Status::kIoError,
                                           "cached AVI read failed");
    }
    return Result<std::vector<uint8_t>>{std::move(bytes), std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<std::vector<uint8_t>>(Status::kIoError,
                                         "cached AVI allocation failed");
  }
}

struct ReaderDeleter {
  void operator()(hmc_avi_reader_t* reader) const {
    hmc_avi_reader_destroy(reader);
  }
};

struct DecoderDeleter {
  void operator()(hmc_cinepak_decoder_t* decoder) const {
    hmc_cinepak_decoder_destroy(decoder);
  }
};

template <class... Visitors>
struct Overloaded : Visitors... {
  using Visitors::operator()...;
};

template <class... Visitors>
Overloaded(Visitors...) -> Overloaded<Visitors...>;

template <typename T>
Result<MediaJobResult> Promote(Result<T> concrete) {
  if (!concrete.ok()) {
    return Result<MediaJobResult>{std::nullopt, concrete.error};
  }
  return Result<MediaJobResult>{
      MediaJobResult{std::move(*concrete.value)}, std::nullopt};
}

}  // namespace

namespace internal {

uint32_t PlannedFrameCount(int64_t duration_100ns, double fps,
                           uint32_t maximum,
                           bool preserve_partial_interval) {
  if (duration_100ns <= 0) {
    return 1;
  }
  const long double count =
      static_cast<long double>(duration_100ns) *
      static_cast<long double>(fps) / 10000000.0L;
  const long double nearest_integer = std::round(count);
  const long double tolerance =
      1.0e-9L * std::max(1.0L, std::abs(count));
  const long double normalized =
      std::abs(count - nearest_integer) <= tolerance ? nearest_integer : count;
  if (normalized >= static_cast<long double>(maximum)) {
    return maximum;
  }
  const long double planned =
      preserve_partial_interval ? std::ceil(normalized) : std::floor(normalized);
  return std::max(1U, static_cast<uint32_t>(planned));
}

int64_t PresentationTimestamp(uint32_t index, double fps,
                              int64_t duration_100ns) {
  const long double timestamp =
      static_cast<long double>(index) * 10000000.0L /
      static_cast<long double>(fps);
  int64_t rounded = static_cast<int64_t>(std::floor(timestamp + 0.5L));
  if (duration_100ns > 0 && rounded >= duration_100ns) {
    rounded = duration_100ns - 1;
  }
  return std::max<int64_t>(0, rounded);
}

ForwardFrameSampler::ForwardFrameSampler(FrameSource* source) : source_(source) {}

Result<std::reference_wrapper<const RgbaFrame>> ForwardFrameSampler::Sample(
    int64_t target_pts_100ns, const IsCancelled& cancelled) {
  using SampleResult = Result<std::reference_wrapper<const RgbaFrame>>;
  if (source_ == nullptr || target_pts_100ns < 0 ||
      (last_target_pts_100ns_ &&
       target_pts_100ns < *last_target_pts_100ns_)) {
    return Failure<std::reference_wrapper<const RgbaFrame>>(
        Status::kInvalidArgument,
        "forward frame sample targets must be nonnegative and monotonic");
  }
  const auto read_pending = [&]() -> Result<bool> {
    if (eof_) {
      return Result<bool>{false, std::nullopt};
    }
    if (IsCancellationRequested(cancelled)) {
      return Cancelled<bool>();
    }
    RgbaFrame next{};
    Result<bool> read = source_->ReadNext(&next);
    if (!read.ok()) {
      return read;
    }
    if (IsCancellationRequested(cancelled)) {
      return Cancelled<bool>();
    }
    if (!*read.value) {
      eof_ = true;
      return Result<bool>{false, std::nullopt};
    }
    pending_ = std::move(next);
    return Result<bool>{true, std::nullopt};
  };

  if (!current_) {
    Result<bool> read = read_pending();
    if (!read.ok()) {
      return SampleResult{std::nullopt, std::move(read.error)};
    }
    if (!pending_) {
      return Failure<std::reference_wrapper<const RgbaFrame>>(
          Status::kDecodeFailed, "media source has no frames");
    }
    current_ = std::move(pending_);
    pending_.reset();
  }
  for (;;) {
    if (!pending_ && !eof_) {
      Result<bool> read = read_pending();
      if (!read.ok()) {
        return SampleResult{std::nullopt, std::move(read.error)};
      }
    }
    if (!pending_ || pending_->pts_100ns > target_pts_100ns) {
      break;
    }
    current_ = std::move(pending_);
    pending_.reset();
  }
  last_target_pts_100ns_ = target_pts_100ns;
  return SampleResult{std::cref(*current_), std::nullopt};
}

bool CanUseIdentityConversionFrame(const RgbaFrame& sampled,
                                   const SourceInfo& source_info,
                                   uint32_t output_width,
                                   uint32_t output_height,
                                   const ConversionRequest& request) {
  return !source_info.is_gif && source_info.clockwise_rotation == 0U &&
         source_info.width == sampled.width &&
         source_info.height == sampled.height && !request.crop.has_value() &&
         request.fit == FitMode::kCover &&
         request.background_argb == 0xff000000U &&
         output_width == sampled.width && output_height == sampled.height &&
         IsTightlyPacked(sampled);
}

ScopedPngEncoderOverride::ScopedPngEncoderOverride(PngEncoder encoder)
    : previous_(std::move(PngEncoderOverride())) {
  PngEncoderOverride() = std::move(encoder);
}

ScopedPngEncoderOverride::~ScopedPngEncoderOverride() {
  PngEncoderOverride() = std::move(previous_);
}

}  // namespace internal

Result<ConversionResult> ConvertMedia(const ConversionRequest& request,
                                      Progress progress,
                                      IsCancelled cancelled) {
  uint32_t width = 0;
  uint32_t height = 0;
  if (!AlignUpFour(request.width, &width) ||
      !AlignUpFour(request.height, &height) || !ValidFps(request.fps) ||
      !ValidQuality(request.quality) ||
      request.refine > static_cast<uint32_t>(INT32_MAX) ||
      request.strips == 0 ||
      request.strips > static_cast<uint32_t>(INT32_MAX) ||
      request.skip_threshold > static_cast<uint32_t>(INT32_MAX) ||
      request.key_interval > static_cast<uint32_t>(INT32_MAX) ||
      request.max_frames == 0 || !ValidFit(request.fit) ||
      !ValidCrop(request.crop)) {
    return Failure<ConversionResult>(Status::kInvalidArgument,
                                     "invalid media conversion request");
  }
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<ConversionResult>();
  }
  Result<std::unique_ptr<FrameSource>> opened = OpenMediaSource(request.path);
  if (!opened.ok()) {
    return ForwardError<ConversionResult>(std::move(opened));
  }
  FrameSource* source = opened.value->get();
  const SourceInfo info = source->info();
  double fps = static_cast<double>(request.fps);
  if (std::isfinite(info.nominal_fps) && info.nominal_fps > 0.0) {
    fps = std::min(fps, info.nominal_fps);
  }
  const uint32_t mux_fps = std::max(
      1U, static_cast<uint32_t>(std::floor(fps + 0.5)));
  const uint32_t frame_count =
      internal::PlannedFrameCount(info.duration_100ns, fps, request.max_frames,
                                  info.is_gif);
  internal::ForwardFrameSampler sampler(source);
  RgbaFrame generated{};
  const auto produce =
      [&sampler, info, width, height, &request, fps, &generated,
       cancelled](uint32_t index)
      -> Result<std::reference_wrapper<const RgbaFrame>> {
    if (IsCancellationRequested(cancelled)) {
      return Failure<std::reference_wrapper<const RgbaFrame>>(
          Status::kCancelled, "media conversion cancelled");
    }
    const int64_t pts =
        internal::PresentationTimestamp(index, fps, info.duration_100ns);
    Result<std::reference_wrapper<const RgbaFrame>> sampled =
        sampler.Sample(pts, cancelled);
    if (!sampled.ok()) {
      return Result<std::reference_wrapper<const RgbaFrame>>{
          std::nullopt, std::move(sampled.error)};
    }
    const RgbaFrame& sampled_frame = sampled.value->get();
    if (internal::CanUseIdentityConversionFrame(sampled_frame, info, width,
                                                height, request)) {
      return Result<std::reference_wrapper<const RgbaFrame>>{
          std::cref(sampled_frame), std::nullopt};
    }
    Result<RgbaFrame> transformed = TransformRgba(
        sampled_frame,
        TransformRequest{width, height, request.fit, request.crop,
                                  request.background_argb, 0});
    if (!transformed.ok()) {
      return Result<std::reference_wrapper<const RgbaFrame>>{
          std::nullopt, std::move(transformed.error)};
    }
    generated = std::move(*transformed.value);
    if (info.is_gif) {
      if (IsCancellationRequested(cancelled)) {
        return Failure<std::reference_wrapper<const RgbaFrame>>(
            Status::kCancelled, "media conversion cancelled");
      }
      CompositeOverOpaqueBackground(&generated, request.background_argb);
    }
    return Result<std::reference_wrapper<const RgbaFrame>>{
        std::cref(generated), std::nullopt};
  };
  Result<ConversionResult> converted = internal::EncodeCinepakFrames(
      width, height, mux_fps, 1, frame_count, request.quality,
      request.refine, request.strips, request.skip_threshold,
      request.key_interval, produce, {}, std::move(progress),
      std::move(cancelled));
  if (converted.ok()) {
    converted.value->fps = fps;
  }
  return converted;
}

Result<ThumbnailResult> MakeThumbnail(const ThumbnailRequest& request,
                                      IsCancelled cancelled) {
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<ThumbnailResult>();
  }
  Result<std::unique_ptr<FrameSource>> opened = OpenMediaSource(request.path);
  if (!opened.ok()) {
    return ForwardError<ThumbnailResult>(std::move(opened));
  }
  const SourceInfo info = (*opened.value)->info();
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<ThumbnailResult>();
  }
  RgbaFrame frame{};
  Result<bool> read = (*opened.value)->ReadNext(&frame);
  if (!read.ok()) {
    return ForwardError<ThumbnailResult>(std::move(read));
  }
  if (!*read.value) {
    return Failure<ThumbnailResult>(Status::kDecodeFailed,
                                    "media has no thumbnail frame");
  }
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<ThumbnailResult>();
  }
  Result<std::vector<uint8_t>> png = EncodePngForMedia(frame);
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<ThumbnailResult>();
  }
  if (!png.ok()) {
    return ForwardError<ThumbnailResult>(std::move(png));
  }
  return Result<ThumbnailResult>{
      ThumbnailResult{std::move(*png.value), frame.width, frame.height,
                      info.is_gif},
      std::nullopt};
}

Result<PreviewResult> MakePreview(const PreviewRequest& request,
                                  IsCancelled cancelled) {
  if (request.max_count == 0 || request.max_edge == 0) {
    return Failure<PreviewResult>(Status::kInvalidArgument,
                                  "preview count and edge must be nonzero");
  }
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<PreviewResult>();
  }
  Result<std::unique_ptr<FrameSource>> opened = OpenMediaSource(request.path);
  if (!opened.ok()) {
    return ForwardError<PreviewResult>(std::move(opened));
  }
  FrameSource* source = opened.value->get();
  const SourceInfo info = source->info();
  double preview_fps = info.nominal_fps;
  if (!std::isfinite(preview_fps) || preview_fps <= 0.0) {
    preview_fps = 10.0;
  }
  preview_fps = std::min(12.0, preview_fps);
  const uint32_t count = internal::PlannedFrameCount(
      info.duration_100ns, preview_fps, request.max_count, info.is_gif);
  internal::ForwardFrameSampler sampler(source);
  try {
    if (IsCancellationRequested(cancelled)) {
      return Cancelled<PreviewResult>();
    }
    std::vector<std::vector<uint8_t>> frames;
    frames.reserve(count);
    for (uint32_t index = 0; index < count; ++index) {
      if (IsCancellationRequested(cancelled)) {
        return Cancelled<PreviewResult>();
      }
      int64_t pts = 0;
      if (info.duration_100ns > 0) {
        const long double target =
            static_cast<long double>(info.duration_100ns) * index / count;
        pts = static_cast<int64_t>(std::floor(target + 0.5L));
      }
      Result<std::reference_wrapper<const RgbaFrame>> sampled =
          sampler.Sample(pts, cancelled);
      if (!sampled.ok()) {
        return Result<PreviewResult>{std::nullopt,
                                     std::move(sampled.error)};
      }
      Result<std::vector<uint8_t>> png =
          PreviewPng(sampled.value->get(), request.max_edge,
                     cancelled);
      if (!png.ok()) {
        return ForwardError<PreviewResult>(std::move(png));
      }
      if (IsCancellationRequested(cancelled)) {
        return Cancelled<PreviewResult>();
      }
      frames.push_back(std::move(*png.value));
    }
    uint32_t interval_ms = 100;
    if (info.duration_100ns > 0) {
      const uint64_t duration_ms =
          static_cast<uint64_t>(info.duration_100ns) / 10000U;
      interval_ms = static_cast<uint32_t>(
          std::clamp<uint64_t>(duration_ms / count, 50U, 200U));
    }
    if (IsCancellationRequested(cancelled)) {
      return Cancelled<PreviewResult>();
    }
    return Result<PreviewResult>{
        PreviewResult{std::move(frames), interval_ms}, std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<PreviewResult>(Status::kIoError,
                                  "preview allocation failed");
  }
}

Result<PreviewResult> DecodeCachedCvid(const DecodeCvidRequest& request,
                                      IsCancelled cancelled) {
  if (request.max_count == 0 || request.max_edge == 0) {
    return Failure<PreviewResult>(Status::kInvalidArgument,
                                  "cached preview count and edge must be nonzero");
  }
  Result<std::vector<uint8_t>> bytes = ReadFile(request.path, cancelled);
  if (!bytes.ok()) {
    return ForwardError<PreviewResult>(std::move(bytes));
  }
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<PreviewResult>();
  }
  hmc_avi_reader_t* raw_reader = nullptr;
  hmc_status_t status = hmc_avi_reader_create_copy(
      bytes.value->data(), bytes.value->size(), &raw_reader);
  if (status != HMC_STATUS_OK) {
    return Failure<PreviewResult>(Status::kDecodeFailed,
                                  "cached AVI container is invalid");
  }
  const std::unique_ptr<hmc_avi_reader_t, ReaderDeleter> reader(raw_reader);
  hmc_avi_info_t info{};
  info.struct_size = sizeof(info);
  status = hmc_avi_reader_get_info(reader.get(), &info);
  if (status != HMC_STATUS_OK || info.handler_fourcc != kCvid ||
      info.compression_fourcc != kCvid || info.bit_count != 24 ||
      info.width == 0 || info.height == 0 || info.frame_count == 0) {
    return Failure<PreviewResult>(Status::kUnsupportedMedia,
                                  "cached AVI is not a supported CVID clip");
  }
  size_t pixel_bytes = 0;
  if (!CheckedPixelBytes(info.width, info.height, &pixel_bytes)) {
    return Failure<PreviewResult>(Status::kDecodeFailed,
                                  "cached AVI dimensions overflow");
  }
  const size_t pixel_count = pixel_bytes / 4U;
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<PreviewResult>();
  }
  hmc_cinepak_decoder_config_t config{};
  status = hmc_cinepak_decoder_config_init(&config, sizeof(config));
  config.width = info.width;
  config.height = info.height;
  hmc_cinepak_decoder_t* raw_decoder = nullptr;
  if (status == HMC_STATUS_OK) {
    status = hmc_cinepak_decoder_create(&config, &raw_decoder);
  }
  if (status != HMC_STATUS_OK) {
    return Failure<PreviewResult>(Status::kDecodeFailed,
                                  "cached Cinepak decoder creation failed");
  }
  const std::unique_ptr<hmc_cinepak_decoder_t, DecoderDeleter> decoder(
      raw_decoder);
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<PreviewResult>();
  }
  try {
    const uint32_t output_count =
        std::min(request.max_count, info.frame_count);
    std::vector<bool> selected(info.frame_count, false);
    for (uint32_t index = 0; index < output_count; ++index) {
      const uint32_t selected_index =
          output_count == 1 ? 0U :
              static_cast<uint32_t>(static_cast<uint64_t>(index) *
                  (info.frame_count - 1U) / (output_count - 1U));
      selected[selected_index] = true;
    }
    std::vector<uint32_t> argb(pixel_count);
    std::vector<uint8_t> rgba(pixel_bytes);
    std::vector<std::vector<uint8_t>> frames;
    frames.reserve(output_count);
    for (uint32_t index = 0; index < info.frame_count; ++index) {
      if (IsCancellationRequested(cancelled)) {
        return Cancelled<PreviewResult>();
      }
      hmc_bytes_view_t encoded{};
      status = hmc_avi_reader_get_frame_view(reader.get(), index, &encoded);
      if (status != HMC_STATUS_OK) {
        return Failure<PreviewResult>(Status::kDecodeFailed,
                                      "cached AVI frame read failed");
      }
      if (IsCancellationRequested(cancelled)) {
        return Cancelled<PreviewResult>();
      }
      status = hmc_cinepak_decoder_decode(
          decoder.get(), encoded.data, encoded.size, argb.data(), argb.size());
      if (status != HMC_STATUS_OK) {
        return Failure<PreviewResult>(Status::kDecodeFailed,
                                      "cached Cinepak frame decode failed");
      }
      if (!selected[index]) {
        continue;
      }
      if (IsCancellationRequested(cancelled)) {
        return Cancelled<PreviewResult>();
      }
      for (size_t pixel = 0; pixel < argb.size(); ++pixel) {
        rgba[pixel * 4U] = static_cast<uint8_t>(argb[pixel] >> 16U);
        rgba[pixel * 4U + 1U] = static_cast<uint8_t>(argb[pixel] >> 8U);
        rgba[pixel * 4U + 2U] = static_cast<uint8_t>(argb[pixel]);
        rgba[pixel * 4U + 3U] = static_cast<uint8_t>(argb[pixel] >> 24U);
      }
      const RgbaFrame frame{info.width, info.height, 0, 0, rgba};
      Result<std::vector<uint8_t>> png =
          PreviewPng(frame, request.max_edge, cancelled);
      if (!png.ok()) {
        return ForwardError<PreviewResult>(std::move(png));
      }
      if (IsCancellationRequested(cancelled)) {
        return Cancelled<PreviewResult>();
      }
      frames.push_back(std::move(*png.value));
    }
    const uint32_t interval_ms = std::clamp(
        info.usec_per_frame / 1000U, UINT32_C(50), UINT32_C(200));
    if (IsCancellationRequested(cancelled)) {
      return Cancelled<PreviewResult>();
    }
    return Result<PreviewResult>{
        PreviewResult{std::move(frames), interval_ms}, std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<PreviewResult>(Status::kIoError,
                                  "cached preview allocation failed");
  }
}

Result<ConversionResult> EncodeSlideshow(const SlideshowRequest& request,
                                         Progress progress,
                                         IsCancelled cancelled) {
  if (request.size == 0 || request.size > 65532U ||
      (request.size & 3U) != 0 || !ValidFps(request.fps) ||
      !ValidQuality(request.quality) || request.frames.empty() ||
      request.frames.size() != request.holds.size()) {
    return Failure<ConversionResult>(Status::kInvalidArgument,
                                     "invalid slideshow request");
  }
  size_t expected_bytes = 0;
  if (!CheckedPixelBytes(request.size, request.size, &expected_bytes)) {
    return Failure<ConversionResult>(Status::kInvalidArgument,
                                     "slideshow dimensions overflow");
  }
  uint64_t total64 = 0;
  std::vector<uint32_t> starts;
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<ConversionResult>();
  }
  try {
    starts.reserve(request.frames.size());
    for (size_t index = 0; index < request.frames.size(); ++index) {
      if (IsCancellationRequested(cancelled)) {
        return Cancelled<ConversionResult>();
      }
      const RgbaFrame& frame = request.frames[index];
      if (request.holds[index] == 0 || frame.width != request.size ||
          frame.height != request.size ||
          frame.pixels.size() != expected_bytes) {
        return Failure<ConversionResult>(Status::kInvalidArgument,
                                         "invalid slideshow frame or hold");
      }
      if (total64 > std::numeric_limits<uint32_t>::max()) {
        return Failure<ConversionResult>(Status::kInvalidArgument,
                                         "slideshow frame count overflow");
      }
      starts.push_back(static_cast<uint32_t>(total64));
      total64 += request.holds[index];
    }
  } catch (const std::bad_alloc&) {
    return Failure<ConversionResult>(Status::kIoError,
                                     "slideshow allocation failed");
  }
  if (total64 == 0 || total64 > std::numeric_limits<uint32_t>::max()) {
    return Failure<ConversionResult>(Status::kInvalidArgument,
                                     "slideshow frame count overflow");
  }
  const auto slide_for = [starts](uint32_t frame_index) {
    const auto after = std::upper_bound(starts.begin(), starts.end(), frame_index);
    return static_cast<size_t>(std::distance(starts.begin(), after) - 1);
  };
  const auto produce = [&request, slide_for](uint32_t index)
      -> Result<std::reference_wrapper<const RgbaFrame>> {
    return Result<std::reference_wrapper<const RgbaFrame>>{
        std::cref(request.frames[slide_for(index)]), std::nullopt};
  };
  const auto force_key = [starts](uint32_t index) {
    return std::binary_search(starts.begin(), starts.end(), index);
  };
  return internal::EncodeCinepakFrames(
      request.size, request.size, request.fps, 1, static_cast<uint32_t>(total64),
      request.quality, 3, 2, 720, 0, produce, force_key,
      std::move(progress), std::move(cancelled));
}

Result<ConversionResult> EncodeScroll(const ScrollRequest& request,
                                      Progress progress,
                                      IsCancelled cancelled) {
  if (request.size == 0 || request.size > 65532U ||
      (request.size & 3U) != 0 || !ValidFps(request.fps) ||
      request.speed == 0 || !ValidQuality(request.quality) ||
      request.max_frames == 0 || !IsTightlyPacked(request.strip)) {
    return Failure<ConversionResult>(Status::kInvalidArgument,
                                     "invalid scrolling video request");
  }
  const uint64_t period64 =
      static_cast<uint64_t>(request.strip.width) + request.gap;
  if (period64 == 0 || period64 > std::numeric_limits<uint32_t>::max()) {
    return Failure<ConversionResult>(Status::kInvalidArgument,
                                     "scrolling period overflow");
  }
  const uint32_t period = static_cast<uint32_t>(period64);
  const long double raw_count =
      static_cast<long double>(period) * request.fps / request.speed;
  uint32_t frame_count = request.max_frames;
  if (raw_count < static_cast<long double>(request.max_frames)) {
    frame_count = std::max(
        1U, static_cast<uint32_t>(std::floor(raw_count + 0.5L)));
  }
  size_t output_bytes = 0;
  if (!CheckedPixelBytes(request.size, request.size, &output_bytes)) {
    return Failure<ConversionResult>(Status::kInvalidArgument,
                                     "scrolling dimensions overflow");
  }
  RgbaFrame generated{request.size, request.size, 0, 0, {}};
  if (IsCancellationRequested(cancelled)) {
    return Cancelled<ConversionResult>();
  }
  try {
    generated.pixels.resize(output_bytes);
  } catch (const std::bad_alloc&) {
    return Failure<ConversionResult>(Status::kIoError,
                                     "scrolling frame allocation failed");
  }
  const auto produce = [&request, period, frame_count, &generated,
                        cancelled](uint32_t index)
      -> Result<std::reference_wrapper<const RgbaFrame>> {
    if (IsCancellationRequested(cancelled)) {
      return Failure<std::reference_wrapper<const RgbaFrame>>(
          Status::kCancelled, "scrolling video cancelled");
    }
    const uint32_t background = request.background_argb | UINT32_C(0xff000000);
    const uint8_t background_red = static_cast<uint8_t>(background >> 16U);
    const uint8_t background_green = static_cast<uint8_t>(background >> 8U);
    const uint8_t background_blue = static_cast<uint8_t>(background);
    for (size_t offset = 0; offset < generated.pixels.size(); offset += 4U) {
      generated.pixels[offset] = background_red;
      generated.pixels[offset + 1U] = background_green;
      generated.pixels[offset + 2U] = background_blue;
      generated.pixels[offset + 3U] = 255U;
    }
    const int64_t vertical_offset =
        (static_cast<int64_t>(request.size) - request.strip.height) / 2;
    const double phase = static_cast<double>(period) *
                         static_cast<double>(frame_count - index) /
                         static_cast<double>(frame_count);
    for (uint32_t y = 0; y < request.size; ++y) {
      const int64_t strip_y = static_cast<int64_t>(y) - vertical_offset;
      if (strip_y < 0 ||
          strip_y >= static_cast<int64_t>(request.strip.height)) {
        continue;
      }
      for (uint32_t x = 0; x < request.size; ++x) {
        double wrapped = std::fmod(static_cast<double>(x) - phase,
                                   static_cast<double>(period));
        if (wrapped < 0.0) {
          wrapped += period;
        }
        if (wrapped >= request.strip.width) {
          continue;
        }
        const uint32_t strip_x = std::min(
            static_cast<uint32_t>(std::floor(wrapped)),
            request.strip.width - 1U);
        const size_t source_offset =
            (static_cast<size_t>(strip_y) * request.strip.width + strip_x) * 4U;
        const size_t output_offset =
            (static_cast<size_t>(y) * request.size + x) * 4U;
        const uint32_t alpha = request.strip.pixels[source_offset + 3U];
        const uint32_t inverse = 255U - alpha;
        generated.pixels[output_offset] = static_cast<uint8_t>(
            (request.strip.pixels[source_offset] * alpha +
             background_red * inverse + 127U) /
            255U);
        generated.pixels[output_offset + 1U] = static_cast<uint8_t>(
            (request.strip.pixels[source_offset + 1U] * alpha +
             background_green * inverse + 127U) /
            255U);
        generated.pixels[output_offset + 2U] = static_cast<uint8_t>(
            (request.strip.pixels[source_offset + 2U] * alpha +
             background_blue * inverse + 127U) /
            255U);
      }
    }
    return Result<std::reference_wrapper<const RgbaFrame>>{
        std::cref(generated), std::nullopt};
  };
  return internal::EncodeCinepakFrames(
      request.size, request.size, request.fps, 1, frame_count, request.quality,
      3, 2, 720, 0, produce, {}, std::move(progress), std::move(cancelled));
}

Result<MediaJobResult> ExecuteMediaJob(const MediaJobRequest& request,
                                       Progress progress,
                                       IsCancelled cancelled) {
  return std::visit(
      Overloaded{
          [&](const ThumbnailRequest& concrete) -> Result<MediaJobResult> {
            return Promote(MakeThumbnail(concrete, cancelled));
          },
          [&](const PreviewRequest& concrete) -> Result<MediaJobResult> {
            return Promote(MakePreview(concrete, cancelled));
          },
          [&](const DecodeCvidRequest& concrete) -> Result<MediaJobResult> {
            return Promote(DecodeCachedCvid(concrete, cancelled));
          },
          [&](const ConversionRequest& concrete) -> Result<MediaJobResult> {
            return Promote(ConvertMedia(concrete, progress, cancelled));
          },
          [&](const SlideshowRequest& concrete) -> Result<MediaJobResult> {
            return Promote(EncodeSlideshow(concrete, progress, cancelled));
          },
          [&](const ScrollRequest& concrete) -> Result<MediaJobResult> {
            return Promote(EncodeScroll(concrete, progress, cancelled));
          }},
      request);
}

}  // namespace hmw
