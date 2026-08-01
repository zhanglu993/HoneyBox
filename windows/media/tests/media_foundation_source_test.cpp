#include "honey_media_windows/media_source.h"

#include "test_support.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <system_error>
#include <utility>

namespace {

std::filesystem::path ProjectPath(const std::filesystem::path& relative) {
  return std::filesystem::path(HMW_PROJECT_SOURCE_DIR) / relative;
}

std::filesystem::path VideoFixturePath() {
  return ProjectPath("assets/example/video/badge-preset-video-1.mov");
}

std::filesystem::path GifFixturePath() {
  return std::filesystem::path(HMW_TEST_SOURCE_DIR) / "fixtures" /
         "animated_disposal.gif";
}

std::unique_ptr<hmw::FrameSource> OpenVideoFixture() {
  hmw::Result<std::unique_ptr<hmw::FrameSource>> result =
      hmw::OpenMediaSource(VideoFixturePath());
  if (!result.ok() && result.error) {
    std::fprintf(stderr, "video fixture open error: %s\n",
                 result.error->message.c_str());
  }
  HMW_EXPECT(result.ok());
  if (!result.ok()) {
    return nullptr;
  }
  return std::move(*result.value);
}

template <typename T>
void PrintError(const hmw::Result<T>& result) {
  if (!result.ok() && result.error) {
    std::fprintf(stderr, "media source error: %s\n",
                 result.error->message.c_str());
  }
}

bool PixelIsNear(const hmw::RgbaFrame& frame, uint32_t x, uint32_t y,
                 uint8_t red, uint8_t green, uint8_t blue) {
  const size_t offset =
      (static_cast<size_t>(y) * frame.width + x) * static_cast<size_t>(4);
  constexpr int kTolerance = 8;
  const auto near = [](uint8_t actual, uint8_t expected) {
    return std::abs(static_cast<int>(actual) - static_cast<int>(expected)) <=
           kTolerance;
  };
  return near(frame.pixels[offset], red) &&
         near(frame.pixels[offset + 1], green) &&
         near(frame.pixels[offset + 2], blue) &&
         frame.pixels[offset + 3] == 255U;
}

class TemporaryDirectory {
 public:
  TemporaryDirectory() {
    std::error_code error;
    const std::filesystem::path base =
        std::filesystem::temp_directory_path(error);
    HMW_EXPECT(!error);
    for (uint32_t attempt = 0; attempt < 1000 && path_.empty(); ++attempt) {
      const std::filesystem::path candidate =
          base / ("hmw-mf-source-test-" + std::to_string(attempt));
      if (std::filesystem::create_directory(candidate, error)) {
        path_ = candidate;
      } else if (error) {
        HMW_EXPECT(!error);
        break;
      }
    }
    HMW_EXPECT(!path_.empty());
  }

  ~TemporaryDirectory() {
    std::error_code error;
    std::filesystem::remove_all(path_, error);
  }

  TemporaryDirectory(const TemporaryDirectory&) = delete;
  TemporaryDirectory& operator=(const TemporaryDirectory&) = delete;

  const std::filesystem::path& path() const { return path_; }

 private:
  std::filesystem::path path_;
};

}  // namespace

HMW_TEST(mf_source_reports_nonzero_upright_geometry_and_duration) {
  std::unique_ptr<hmw::FrameSource> source = OpenVideoFixture();
  if (!source) {
    return;
  }

  const hmw::SourceInfo& info = source->info();
  std::printf("fixture: %ux%u duration=%lld fps=%.3f\n", info.width,
              info.height, static_cast<long long>(info.duration_100ns),
              info.nominal_fps);
  HMW_EXPECT(info.width == 360);
  HMW_EXPECT(info.height == 360);
  HMW_EXPECT(info.width > 0);
  HMW_EXPECT(info.height > 0);
  HMW_EXPECT(info.duration_100ns > 0);
  HMW_EXPECT(info.nominal_fps > 0.0);
  HMW_EXPECT(info.clockwise_rotation == 0);
  HMW_EXPECT(!info.is_gif);
}

HMW_TEST(mf_source_frames_are_top_down_tightly_packed_rgba) {
  std::unique_ptr<hmw::FrameSource> source = OpenVideoFixture();
  if (!source) {
    return;
  }

  hmw::RgbaFrame frame{};
  hmw::Result<bool> read = source->ReadNext(&frame);
  PrintError(read);
  HMW_EXPECT(read.ok());
  HMW_EXPECT(read.ok() && *read.value);
  if (!read.ok() || !*read.value) {
    return;
  }
  HMW_EXPECT(frame.width == source->info().width);
  HMW_EXPECT(frame.height == source->info().height);
  HMW_EXPECT(frame.width == 360);
  HMW_EXPECT(frame.height == 360);
  HMW_EXPECT(frame.pixels.size() ==
             static_cast<size_t>(frame.width) * frame.height * 4U);
  if (frame.width != 360 || frame.height != 360 ||
      frame.pixels.size() != 360U * 360U * 4U) {
    return;
  }
  HMW_EXPECT(PixelIsNear(frame, 0, 0, 109, 119, 128));
  HMW_EXPECT(PixelIsNear(frame, 0, 359, 115, 112, 107));
  for (size_t index = 3; index < frame.pixels.size(); index += 4) {
    HMW_EXPECT(frame.pixels[index] == 255U);
  }
}

HMW_TEST(mf_source_pts_are_monotonic) {
  std::unique_ptr<hmw::FrameSource> source = OpenVideoFixture();
  if (!source) {
    return;
  }

  int64_t previous_pts = -1;
  uint32_t frame_count = 0;
  for (;;) {
    hmw::RgbaFrame frame{};
    hmw::Result<bool> read = source->ReadNext(&frame);
    PrintError(read);
    HMW_EXPECT(read.ok());
    if (!read.ok() || !*read.value) {
      break;
    }
    HMW_EXPECT(frame.pts_100ns >= 0);
    HMW_EXPECT(frame.pts_100ns >= previous_pts);
    HMW_EXPECT(frame.duration_100ns > 0);
    previous_pts = frame.pts_100ns;
    ++frame_count;
  }
  std::printf("fixture frames=%u last_pts=%lld\n", frame_count,
              static_cast<long long>(previous_pts));
  HMW_EXPECT(frame_count > 1);
}

HMW_TEST(mf_source_seek_returns_frame_at_or_after_target) {
  std::unique_ptr<hmw::FrameSource> source = OpenVideoFixture();
  if (!source) {
    return;
  }

  const int64_t target = source->info().duration_100ns / 2;
  hmw::Outcome seek = source->Seek(target);
  HMW_EXPECT(seek.ok());
  hmw::RgbaFrame frame{};
  hmw::Result<bool> read = source->ReadNext(&frame);
  PrintError(read);
  HMW_EXPECT(read.ok());
  HMW_EXPECT(read.ok() && *read.value);
  if (read.ok() && *read.value) {
    std::printf("fixture seek target=%lld returned=%lld\n",
                static_cast<long long>(target),
                static_cast<long long>(frame.pts_100ns));
    HMW_EXPECT(frame.pts_100ns >= target);
  }
}

HMW_TEST(source_factory_selects_gif_and_video_by_probe) {
  TemporaryDirectory temporary;
  if (temporary.path().empty()) {
    return;
  }
  const std::filesystem::path disguised_gif = temporary.path() / "gif.data";
  const std::filesystem::path disguised_video = temporary.path() / "video.data";
  std::error_code error;
  std::filesystem::copy_file(GifFixturePath(), disguised_gif, error);
  HMW_EXPECT(!error);
  error.clear();
  std::filesystem::copy_file(VideoFixturePath(), disguised_video, error);
  HMW_EXPECT(!error);

  hmw::Result<std::unique_ptr<hmw::FrameSource>> gif =
      hmw::OpenMediaSource(disguised_gif);
  HMW_EXPECT(gif.ok());
  if (gif.ok()) {
    HMW_EXPECT((*gif.value)->info().is_gif);
  }
  hmw::Result<std::unique_ptr<hmw::FrameSource>> video =
      hmw::OpenMediaSource(disguised_video);
  HMW_EXPECT(video.ok());
  if (video.ok()) {
    HMW_EXPECT(!(*video.value)->info().is_gif);
  }
}

HMW_TEST(source_factory_reports_not_found_and_unsupported_media) {
  TemporaryDirectory temporary;
  if (temporary.path().empty()) {
    return;
  }
  const std::filesystem::path missing = temporary.path() / "missing.mov";
  hmw::Result<std::unique_ptr<hmw::FrameSource>> not_found =
      hmw::OpenMediaSource(missing);
  HMW_EXPECT(!not_found.ok());
  HMW_EXPECT(not_found.error.has_value());
  if (not_found.error) {
    HMW_EXPECT(not_found.error->status == hmw::Status::kNotFound);
  }

  const std::filesystem::path unsupported = temporary.path() / "invalid.mov";
  std::ofstream stream(unsupported, std::ios::binary);
  stream << "this is not media";
  stream.close();
  hmw::Result<std::unique_ptr<hmw::FrameSource>> invalid =
      hmw::OpenMediaSource(unsupported);
  HMW_EXPECT(!invalid.ok());
  HMW_EXPECT(invalid.error.has_value());
  if (invalid.error) {
    HMW_EXPECT(invalid.error->status == hmw::Status::kUnsupportedMedia);
  }
}
