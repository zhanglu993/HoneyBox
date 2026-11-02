#pragma once

#include "honey_media_windows/status.h"
#include "honey_media_windows/types.h"

#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <variant>
#include <vector>

namespace hmw {

struct ConversionRequest {
  std::filesystem::path path;
  uint32_t width;
  uint32_t height;
  uint32_t fps;
  uint32_t quality;
  uint32_t refine;
  uint32_t strips;
  uint32_t skip_threshold;
  uint32_t key_interval;
  uint32_t max_frames;
  uint32_t background_argb;
  FitMode fit;
  std::optional<CropRect> crop;
};

struct ConversionResult {
  std::vector<uint8_t> avi;
  uint32_t width;
  uint32_t height;
  uint32_t frame_count;
  double fps;
};

struct ThumbnailResult {
  std::vector<uint8_t> png;
  uint32_t width;
  uint32_t height;
  bool is_gif;
};

struct PreviewResult {
  std::vector<std::vector<uint8_t>> png_frames;
  uint32_t interval_ms;
};

struct ThumbnailRequest {
  std::filesystem::path path;
};

struct PreviewRequest {
  std::filesystem::path path;
  uint32_t max_count;
  uint32_t max_edge;
};

struct DecodeCvidRequest {
  std::filesystem::path path;
  uint32_t max_count;
  uint32_t max_edge;
};

struct SlideshowRequest {
  std::vector<RgbaFrame> frames;
  std::vector<uint32_t> holds;
  uint32_t size;
  uint32_t fps;
  uint32_t quality;
};

struct ScrollRequest {
  RgbaFrame strip;
  uint32_t size;
  uint32_t background_argb;
  uint32_t speed;
  uint32_t fps;
  uint32_t gap;
  uint32_t quality;
  uint32_t max_frames;
};

using Progress = std::function<void(uint32_t, uint32_t)>;
using IsCancelled = std::function<bool()>;
using MediaJobRequest =
    std::variant<ThumbnailRequest, PreviewRequest, DecodeCvidRequest,
                 ConversionRequest, SlideshowRequest, ScrollRequest>;
using MediaJobResult =
    std::variant<ThumbnailResult, PreviewResult, ConversionResult>;

Result<ConversionResult> ConvertMedia(const ConversionRequest& request,
                                      Progress progress,
                                      IsCancelled cancelled);
Result<ThumbnailResult> MakeThumbnail(const ThumbnailRequest& request,
                                      IsCancelled cancelled);
Result<PreviewResult> MakePreview(const PreviewRequest& request,
                                  IsCancelled cancelled);
Result<PreviewResult> DecodeCachedCvid(const DecodeCvidRequest& request,
                                      IsCancelled cancelled);
Result<ConversionResult> EncodeSlideshow(const SlideshowRequest& request,
                                         Progress progress,
                                         IsCancelled cancelled);
Result<ConversionResult> EncodeScroll(const ScrollRequest& request,
                                      Progress progress,
                                      IsCancelled cancelled);
Result<MediaJobResult> ExecuteMediaJob(const MediaJobRequest& request,
                                       Progress progress,
                                       IsCancelled cancelled);

}  // namespace hmw
