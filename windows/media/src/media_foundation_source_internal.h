#pragma once

#include "honey_media_windows/status.h"
#include "honey_media_windows/types.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <mfidl.h>

#include <cstddef>
#include <cstdint>
#include <optional>

namespace hmw::internal {

struct VideoLayout {
  uint32_t coded_width;
  uint32_t coded_height;
  uint32_t visible_width;
  uint32_t visible_height;
  int64_t visible_left_16_16;
  int64_t visible_top_16_16;
  uint32_t clockwise_rotation;
};

Result<VideoLayout> ParseVideoLayout(IMFMediaType* media_type,
                                     uint32_t clockwise_rotation);

Result<RgbaFrame> ConvertBgraFrame(const uint8_t* scanline_zero,
                                   ptrdiff_t pitch,
                                   const VideoLayout& layout,
                                   int64_t pts_100ns,
                                   int64_t duration_100ns);

double ReadNominalFrameRate(IMFMediaType* media_type);
int64_t NormalizeSampleDuration(std::optional<int64_t> duration_100ns);

class MediaTimeline final {
 public:
  Result<int64_t> AcceptTimestamp(int64_t raw_pts_100ns);
  Result<int64_t> RawSeekTarget(int64_t public_pts_100ns) const;
  void BeginSeek(int64_t raw_target_100ns);
  bool IsPreroll(int64_t raw_pts_100ns) const;

 private:
  std::optional<int64_t> rebase_origin_100ns_;
  std::optional<int64_t> previous_raw_pts_100ns_;
  std::optional<int64_t> seek_floor_raw_100ns_;
};

class MediaFoundationReadState final {
 public:
  Result<bool> BeforeRead() const;
  Outcome BeforeSeek() const;
  Result<bool> ObserveFlags(uint32_t flags);
  void Fail(Error error);
  void ResetAfterSeek();

 private:
  std::optional<Error> terminal_error_;
  bool end_of_stream_ = false;
};

}  // namespace hmw::internal
