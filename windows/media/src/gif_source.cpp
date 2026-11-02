#include "honey_media_windows/media_source.h"

#include "wic_helpers.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <utility>
#include <vector>

namespace hmw {
namespace {

template <typename T>
Result<T> Failure(Status status, const char* message) {
  return Result<T>{std::nullopt, Error{status, message}};
}

size_t PixelOffset(uint32_t x, uint32_t y, uint32_t width) {
  return (static_cast<size_t>(y) * width + x) * static_cast<size_t>(4);
}

void ClearRectangle(const internal::GifFrameData& frame, uint32_t canvas_width,
                    const std::array<uint8_t, 4>& background_rgba,
                    std::vector<uint8_t>* canvas) {
  for (uint32_t y = 0; y < frame.height; ++y) {
    for (uint32_t x = 0; x < frame.width; ++x) {
      const size_t destination =
          PixelOffset(frame.left + x, frame.top + y, canvas_width);
      std::copy(background_rgba.begin(), background_rgba.end(),
                canvas->begin() + destination);
    }
  }
}

void Composite(const internal::GifFrameData& frame, uint32_t canvas_width,
               std::vector<uint8_t>* canvas) {
  for (uint32_t y = 0; y < frame.height; ++y) {
    for (uint32_t x = 0; x < frame.width; ++x) {
      const size_t source = PixelOffset(x, y, frame.width);
      if (frame.pixels[source + 3] == 0) {
        continue;
      }
      const size_t destination =
          PixelOffset(frame.left + x, frame.top + y, canvas_width);
      std::copy_n(frame.pixels.begin() + source, 4,
                  canvas->begin() + destination);
    }
  }
}

class GifFrameSource final : public FrameSource {
 public:
  GifFrameSource(SourceInfo info, std::vector<RgbaFrame> frames)
      : info_(info), frames_(std::move(frames)) {}

  const SourceInfo& info() const override { return info_; }

  Result<bool> ReadNext(RgbaFrame* frame) override {
    if (frame == nullptr) {
      return Failure<bool>(Status::kInvalidArgument,
                           "GIF output frame must not be null");
    }
    if (next_frame_ == frames_.size()) {
      return Result<bool>{false, std::nullopt};
    }
    try {
      *frame = frames_[next_frame_];
      ++next_frame_;
      return Result<bool>{true, std::nullopt};
    } catch (const std::bad_alloc&) {
      return Failure<bool>(Status::kIoError, "GIF frame copy allocation failed");
    }
  }

  Outcome Seek(int64_t pts_100ns) override {
    if (pts_100ns < 0) {
      return Outcome{Error{Status::kInvalidArgument,
                           "GIF seek timestamp must not be negative"}};
    }
    next_frame_ = frames_.size();
    for (size_t index = 0; index < frames_.size(); ++index) {
      const RgbaFrame& frame = frames_[index];
      if (pts_100ns < frame.pts_100ns + frame.duration_100ns) {
        next_frame_ = index;
        break;
      }
    }
    return Outcome{std::nullopt};
  }

 private:
  SourceInfo info_;
  std::vector<RgbaFrame> frames_;
  size_t next_frame_ = 0;
};

}  // namespace

Result<std::unique_ptr<FrameSource>> OpenGifSource(
    const std::filesystem::path& path) {
  Result<internal::DecodedGif> decoded = internal::DecodeGifWithWic(path);
  if (!decoded.ok()) {
    return Result<std::unique_ptr<FrameSource>>{std::nullopt,
                                                std::move(decoded.error)};
  }
  try {
    const size_t canvas_bytes = static_cast<size_t>(decoded.value->width) *
                                decoded.value->height * 4U;
    std::vector<uint8_t> canvas(canvas_bytes, 0);
    std::vector<RgbaFrame> frames;
    frames.reserve(decoded.value->frames.size());
    const internal::GifFrameData* previous_frame = nullptr;
    std::vector<uint8_t> restore_previous;
    int64_t pts = 0;
    for (const internal::GifFrameData& raw : decoded.value->frames) {
      if (previous_frame != nullptr) {
        if (previous_frame->disposal == 2) {
          ClearRectangle(*previous_frame, decoded.value->width,
                         decoded.value->background_rgba, &canvas);
        } else if (previous_frame->disposal == 3) {
          canvas = restore_previous;
        }
      }
      if (raw.disposal == 3) {
        restore_previous = canvas;
      }
      if (raw.duration_100ns <= 0 ||
          pts > std::numeric_limits<int64_t>::max() - raw.duration_100ns) {
        return Failure<std::unique_ptr<FrameSource>>(
            Status::kDecodeFailed, "GIF duration overflows source timeline");
      }
      Composite(raw, decoded.value->width, &canvas);
      frames.push_back(RgbaFrame{decoded.value->width, decoded.value->height,
                                 pts, raw.duration_100ns, canvas});
      pts += raw.duration_100ns;
      previous_frame = &raw;
    }
    const double seconds = static_cast<double>(pts) / 10000000.0;
    const SourceInfo info{
        decoded.value->width,
        decoded.value->height,
        pts,
        seconds > 0.0 ? static_cast<double>(frames.size()) / seconds : 0.0,
        0,
        true,
    };
    std::unique_ptr<FrameSource> source =
        std::make_unique<GifFrameSource>(info, std::move(frames));
    return Result<std::unique_ptr<FrameSource>>{std::move(source), std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<std::unique_ptr<FrameSource>>(
        Status::kIoError, "GIF composition buffer allocation failed");
  }
}

}  // namespace hmw
