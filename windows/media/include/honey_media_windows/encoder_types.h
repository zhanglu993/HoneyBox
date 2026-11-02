#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "honey_media_windows/status.h"

namespace hmw {

enum class EncoderFormat { kH264, kJpeg, kMsv1 };

struct EncodingConfig {
  EncoderFormat format;
  uint32_t width, height, fps, bitrate, i_frame_interval_sec;
  double crop_zoom;
  bool msv1_skip;
  uint32_t msv1_skip_threshold, jpeg_quality;
  bool record_to_file, stream;
};

struct EncoderInputFrame {
  uint32_t width, height;
  int64_t pts_100ns, duration_100ns;
  const uint8_t* rgba;
  size_t rgba_size;
};

struct EncodedFrame {
  std::shared_ptr<const std::vector<uint8_t>> bytes;
  int64_t pts_100ns;
  bool key;
};

struct EncodingStats {
  uint64_t frames;
  uint64_t keyframes;
  uint64_t bytes;
  uint64_t key_bytes;
  double fps;
  uint64_t last_bytes;
};

struct EncoderCallbacks {
  std::function<void(uint64_t, std::optional<std::string>, uint32_t, uint32_t)>
      on_started;
  std::function<void(uint64_t, EncodedFrame)> on_frame;
  std::function<void(uint64_t, EncodingStats)> on_stats;
  std::function<void(uint64_t, std::optional<std::string>, EncodingStats)>
      on_stopped;
  std::function<void(uint64_t, hmw::Error)> on_error;
  std::function<void(uint64_t, std::string)> on_info;
};

}  // namespace hmw
