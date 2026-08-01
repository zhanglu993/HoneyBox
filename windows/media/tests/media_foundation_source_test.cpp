#include "honey_media_windows/media_source.h"

#include "media_foundation_source_internal.h"
#include "media_source_factory_internal.h"
#include "test_support.h"

#include <mfapi.h>
#include <mfreadwrite.h>
#include <objbase.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

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

std::filesystem::path RotationFixturePath() {
  return std::filesystem::path(HMW_TEST_SOURCE_DIR) / "fixtures" /
         "mf_rotation_90.mov";
}

std::filesystem::path NegativePtsFixturePath() {
  return std::filesystem::path(HMW_TEST_SOURCE_DIR) / "fixtures" /
         "mf_negative_start.mp4";
}

std::filesystem::path AudioOnlyFixturePath() {
  return std::filesystem::path(HMW_TEST_SOURCE_DIR) / "fixtures" /
         "mf_audio_only.wav";
}

std::unique_ptr<hmw::FrameSource> OpenFixture(
    const std::filesystem::path& path) {
  hmw::Result<std::unique_ptr<hmw::FrameSource>> result =
      hmw::OpenMediaSource(path);
  if (!result.ok() && result.error) {
    std::fprintf(stderr, "fixture open error: %s\n",
                 result.error->message.c_str());
  }
  HMW_EXPECT(result.ok());
  if (!result.ok()) {
    return nullptr;
  }
  return std::move(*result.value);
}

std::unique_ptr<hmw::FrameSource> OpenVideoFixture() {
  return OpenFixture(VideoFixturePath());
}

template <typename T>
void PrintError(const hmw::Result<T>& result) {
  if (!result.ok() && result.error) {
    std::fprintf(stderr, "media source error: %s\n",
                 result.error->message.c_str());
  }
}

void PrintError(const hmw::Outcome& outcome) {
  if (!outcome.ok() && outcome.error) {
    std::fprintf(stderr, "media source error: %s\n",
                 outcome.error->message.c_str());
  }
}

bool PixelIsNear(const hmw::RgbaFrame& frame, uint32_t x, uint32_t y,
                 uint8_t red, uint8_t green, uint8_t blue) {
  const size_t offset =
      (static_cast<size_t>(y) * frame.width + x) * static_cast<size_t>(4);
  constexpr int kTolerance = 8;
  const auto channel_is_near = [](uint8_t actual, uint8_t expected) {
    return std::abs(static_cast<int>(actual) - static_cast<int>(expected)) <=
           kTolerance;
  };
  return channel_is_near(frame.pixels[offset], red) &&
         channel_is_near(frame.pixels[offset + 1], green) &&
         channel_is_near(frame.pixels[offset + 2], blue) &&
         frame.pixels[offset + 3] == 255U;
}

Microsoft::WRL::ComPtr<IMFMediaType> MakeVideoMediaType(uint32_t width,
                                                        uint32_t height) {
  Microsoft::WRL::ComPtr<IMFMediaType> media_type;
  HRESULT result = MFCreateMediaType(&media_type);
  if (SUCCEEDED(result)) {
    result = MFSetAttributeSize(media_type.Get(), MF_MT_FRAME_SIZE, width,
                                height);
  }
  HMW_EXPECT(SUCCEEDED(result));
  return media_type;
}

void SetDisplayAperture(IMFMediaType* media_type, int16_t left,
                        uint16_t left_fraction, int16_t top,
                        uint16_t top_fraction, int32_t width,
                        int32_t height) {
  MFVideoArea area{};
  area.OffsetX.value = left;
  area.OffsetX.fract = left_fraction;
  area.OffsetY.value = top;
  area.OffsetY.fract = top_fraction;
  area.Area.cx = width;
  area.Area.cy = height;
  const HRESULT result = media_type->SetBlob(
      MF_MT_MINIMUM_DISPLAY_APERTURE,
      reinterpret_cast<const UINT8*>(&area), sizeof(area));
  HMW_EXPECT(SUCCEEDED(result));
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

HMW_TEST(media_foundation_source_cross_thread_use_and_destroy_balances_com) {
  std::unique_ptr<hmw::FrameSource> source = OpenVideoFixture();
  if (!source) {
    return;
  }
  std::atomic<HRESULT> initial_result{E_UNEXPECTED};
  std::atomic<HRESULT> probe_result{E_UNEXPECTED};
  std::atomic<bool> read_succeeded{false};
  std::thread worker(
      [source = std::move(source), &initial_result, &probe_result,
       &read_succeeded]() mutable {
        const HRESULT initialized =
            CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        initial_result.store(initialized);
        hmw::RgbaFrame frame{};
        hmw::Result<bool> read = source->ReadNext(&frame);
        read_succeeded.store(read.ok() && *read.value);
        source.reset();
        const HRESULT probe = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        probe_result.store(probe);
        if (probe == S_FALSE) {
          CoUninitialize();
          CoUninitialize();
        } else if (probe == S_OK) {
          CoUninitialize();
        }
      });
  worker.join();
  HMW_EXPECT(initial_result.load() == S_OK);
  HMW_EXPECT(read_succeeded.load());
  HMW_EXPECT(probe_result.load() == S_FALSE);
}

HMW_TEST(media_foundation_source_error_flag_is_terminal) {
  hmw::internal::MediaFoundationReadState state;
  hmw::Result<bool> observed = state.ObserveFlags(
      static_cast<uint32_t>(MF_SOURCE_READERF_ERROR));
  HMW_EXPECT(!observed.ok());
  HMW_EXPECT(observed.error.has_value());
  if (observed.error) {
    HMW_EXPECT(observed.error->status == hmw::Status::kDecodeFailed);
  }
  hmw::Result<bool> repeated = state.BeforeRead();
  HMW_EXPECT(!repeated.ok());
  HMW_EXPECT(repeated.error.has_value());
  if (repeated.error) {
    HMW_EXPECT(repeated.error->status == hmw::Status::kDecodeFailed);
  }
  hmw::Outcome seek = state.BeforeSeek();
  HMW_EXPECT(!seek.ok());
  HMW_EXPECT(seek.error.has_value());
  if (seek.error) {
    HMW_EXPECT(seek.error->status == hmw::Status::kDecodeFailed);
  }
}

HMW_TEST(media_foundation_source_fractional_aperture_is_shared_and_sampled) {
  Microsoft::WRL::ComPtr<IMFMediaType> initial = MakeVideoMediaType(3, 2);
  hmw::Result<hmw::internal::VideoLayout> initial_layout =
      hmw::internal::ParseVideoLayout(initial.Get(), 0);
  HMW_EXPECT(initial_layout.ok());
  if (!initial_layout.ok()) {
    return;
  }
  HMW_EXPECT(initial_layout.value->coded_width == 3);
  HMW_EXPECT(initial_layout.value->visible_width == 3);
  HMW_EXPECT(initial_layout.value->visible_height == 2);

  Microsoft::WRL::ComPtr<IMFMediaType> dynamic = MakeVideoMediaType(4, 3);
  SetDisplayAperture(dynamic.Get(), 0, 0x8000, 0, 0x8000, 3, 2);
  hmw::Result<hmw::internal::VideoLayout> dynamic_layout =
      hmw::internal::ParseVideoLayout(dynamic.Get(), 0);
  HMW_EXPECT(dynamic_layout.ok());
  if (!dynamic_layout.ok()) {
    return;
  }
  HMW_EXPECT(dynamic_layout.value->coded_width == 4);
  HMW_EXPECT(dynamic_layout.value->coded_height == 3);
  HMW_EXPECT(dynamic_layout.value->visible_width ==
             initial_layout.value->visible_width);
  HMW_EXPECT(dynamic_layout.value->visible_height ==
             initial_layout.value->visible_height);
  HMW_EXPECT(dynamic_layout.value->visible_left_16_16 == 0x8000);
  HMW_EXPECT(dynamic_layout.value->visible_top_16_16 == 0x8000);

  std::vector<uint8_t> bgra(4U * 3U * 4U, 0);
  for (uint32_t y = 0; y < 3; ++y) {
    for (uint32_t x = 0; x < 4; ++x) {
      const size_t offset = (static_cast<size_t>(y) * 4U + x) * 4U;
      bgra[offset + 2] = static_cast<uint8_t>(x * 20U + y * 60U);
      bgra[offset + 3] = 255;
    }
  }
  hmw::Result<hmw::RgbaFrame> converted = hmw::internal::ConvertBgraFrame(
      bgra.data(), 16, *dynamic_layout.value, 7, 11);
  HMW_EXPECT(converted.ok());
  if (converted.ok()) {
    HMW_EXPECT(converted.value->width == 3);
    HMW_EXPECT(converted.value->height == 2);
    HMW_EXPECT(converted.value->pixels[0] == 40);
    const size_t last = (3U * 2U - 1U) * 4U;
    HMW_EXPECT(converted.value->pixels[last] == 140);
  }

  Microsoft::WRL::ComPtr<IMFMediaType> out_of_bounds =
      MakeVideoMediaType(4, 3);
  SetDisplayAperture(out_of_bounds.Get(), 0, 0x8000, 0, 0, 4, 3);
  hmw::Result<hmw::internal::VideoLayout> rejected =
      hmw::internal::ParseVideoLayout(out_of_bounds.Get(), 0);
  HMW_EXPECT(!rejected.ok());
  HMW_EXPECT(rejected.error.has_value());
  if (rejected.error) {
    HMW_EXPECT(rejected.error->status == hmw::Status::kDecodeFailed);
  }
}

HMW_TEST(media_foundation_source_timeline_rebases_and_rejects_regression) {
  hmw::internal::MediaTimeline timeline;
  hmw::Result<int64_t> first = timeline.AcceptTimestamp(-100);
  HMW_EXPECT(first.ok() && *first.value == 0);
  hmw::Result<int64_t> second = timeline.AcceptTimestamp(0);
  HMW_EXPECT(second.ok() && *second.value == 100);
  hmw::Result<int64_t> regression = timeline.AcceptTimestamp(-1);
  HMW_EXPECT(!regression.ok());
  HMW_EXPECT(regression.error.has_value());
  if (regression.error) {
    HMW_EXPECT(regression.error->status == hmw::Status::kDecodeFailed);
  }

  hmw::internal::MediaTimeline seek_timeline;
  HMW_EXPECT(seek_timeline.AcceptTimestamp(-100).ok());
  hmw::Result<int64_t> raw_target = seek_timeline.RawSeekTarget(50);
  HMW_EXPECT(raw_target.ok() && *raw_target.value == -50);
  if (!raw_target.ok()) {
    return;
  }
  seek_timeline.BeginSeek(*raw_target.value);
  HMW_EXPECT(seek_timeline.IsPreroll(-51));
  HMW_EXPECT(!seek_timeline.IsPreroll(-50));
  hmw::Result<int64_t> sought = seek_timeline.AcceptTimestamp(-50);
  HMW_EXPECT(sought.ok() && *sought.value == 50);
}

HMW_TEST(media_foundation_source_allows_missing_and_zero_nominal_fps) {
  Microsoft::WRL::ComPtr<IMFMediaType> media_type = MakeVideoMediaType(4, 4);
  HMW_EXPECT(hmw::internal::ReadNominalFrameRate(media_type.Get()) == 0.0);
  HMW_EXPECT(SUCCEEDED(media_type->SetUINT64(MF_MT_FRAME_RATE, 0)));
  HMW_EXPECT(hmw::internal::ReadNominalFrameRate(media_type.Get()) == 0.0);
  const int64_t missing = hmw::internal::NormalizeSampleDuration(std::nullopt);
  HMW_EXPECT(missing > 0);
  HMW_EXPECT(missing <= 10000000);
  HMW_EXPECT(hmw::internal::NormalizeSampleDuration(0) == missing);
  HMW_EXPECT(hmw::internal::NormalizeSampleDuration(123456) == 123456);
}

HMW_TEST(media_foundation_source_rotates_real_metadata_upright) {
  std::unique_ptr<hmw::FrameSource> source = OpenFixture(RotationFixturePath());
  if (!source) {
    return;
  }
  HMW_EXPECT(source->info().width == 32);
  HMW_EXPECT(source->info().height == 64);
  HMW_EXPECT(source->info().clockwise_rotation == 0);
  hmw::RgbaFrame frame{};
  hmw::Result<bool> read = source->ReadNext(&frame);
  PrintError(read);
  HMW_EXPECT(read.ok() && *read.value);
  if (!read.ok() || !*read.value || frame.width != 32 || frame.height != 64) {
    return;
  }
  HMW_EXPECT(PixelIsNear(frame, 2, 2, 0, 255, 0));
  HMW_EXPECT(PixelIsNear(frame, 29, 2, 255, 255, 0));
  HMW_EXPECT(PixelIsNear(frame, 2, 61, 255, 0, 0));
  HMW_EXPECT(PixelIsNear(frame, 29, 61, 0, 0, 255));
}

HMW_TEST(media_foundation_source_negative_start_direct_read_rebases_to_zero) {
  std::unique_ptr<hmw::FrameSource> source =
      OpenFixture(NegativePtsFixturePath());
  if (!source) {
    return;
  }
  hmw::RgbaFrame frame{};
  hmw::Result<bool> read = source->ReadNext(&frame);
  PrintError(read);
  HMW_EXPECT(read.ok() && *read.value);
  if (!read.ok() || !*read.value) {
    return;
  }
  HMW_EXPECT(frame.pts_100ns == 0);
  HMW_EXPECT(PixelIsNear(frame, 32, 16, 255, 0, 0));
}

HMW_TEST(media_foundation_source_immediate_seek_zero_preserves_timeline_head) {
  std::unique_ptr<hmw::FrameSource> source =
      OpenFixture(NegativePtsFixturePath());
  if (!source) {
    return;
  }
  hmw::Outcome seek = source->Seek(0);
  PrintError(seek);
  HMW_EXPECT(seek.ok());
  if (!seek.ok()) {
    return;
  }
  hmw::RgbaFrame frame{};
  hmw::Result<bool> read = source->ReadNext(&frame);
  PrintError(read);
  HMW_EXPECT(read.ok() && *read.value);
  if (!read.ok() || !*read.value) {
    return;
  }
  HMW_EXPECT(frame.pts_100ns == 0);
  HMW_EXPECT(PixelIsNear(frame, 32, 16, 255, 0, 0));
}

HMW_TEST(media_foundation_source_immediate_seek_positive_uses_raw_origin) {
  std::unique_ptr<hmw::FrameSource> source =
      OpenFixture(NegativePtsFixturePath());
  if (!source) {
    return;
  }
  constexpr int64_t kPublicTarget100ns = 5000000;
  hmw::Outcome seek = source->Seek(kPublicTarget100ns);
  PrintError(seek);
  HMW_EXPECT(seek.ok());
  if (!seek.ok()) {
    return;
  }
  hmw::RgbaFrame frame{};
  hmw::Result<bool> read = source->ReadNext(&frame);
  PrintError(read);
  HMW_EXPECT(read.ok() && *read.value);
  if (!read.ok() || !*read.value) {
    return;
  }
  HMW_EXPECT(frame.pts_100ns == kPublicTarget100ns);
  HMW_EXPECT(PixelIsNear(frame, 32, 16, 0, 0, 255));
}

HMW_TEST(media_foundation_source_reports_nonzero_upright_geometry_and_duration) {
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

HMW_TEST(media_foundation_source_frames_are_top_down_tightly_packed_rgba) {
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

HMW_TEST(media_foundation_source_pts_are_monotonic_and_complete) {
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
  HMW_EXPECT(frame_count == 180);
  HMW_EXPECT(previous_pts == 119333333);
  hmw::RgbaFrame after_end{};
  hmw::Result<bool> repeated_end = source->ReadNext(&after_end);
  HMW_EXPECT(repeated_end.ok() && !*repeated_end.value);
}

HMW_TEST(media_foundation_source_seek_returns_target_and_handles_overrun) {
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
  hmw::Outcome total_seek = source->Seek(source->info().duration_100ns);
  HMW_EXPECT(total_seek.ok());
  hmw::Result<bool> at_total = source->ReadNext(&frame);
  HMW_EXPECT(at_total.ok() && !*at_total.value);
  hmw::Outcome overrun_seek = source->Seek(
      source->info().duration_100ns + 1);
  HMW_EXPECT(!overrun_seek.ok());
  HMW_EXPECT(overrun_seek.error.has_value());
  if (overrun_seek.error) {
    HMW_EXPECT(overrun_seek.error->status == hmw::Status::kInvalidArgument);
  }
}

HMW_TEST(media_foundation_source_factory_selects_gif_and_video_by_probe) {
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

HMW_TEST(media_foundation_source_factory_reports_not_found_and_unsupported_media) {
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

HMW_TEST(media_foundation_source_factory_maps_filesystem_errors_before_type) {
  hmw::Result<bool> denied = hmw::internal::ValidateMediaFileStatus(
      std::filesystem::file_status{},
      std::make_error_code(std::errc::permission_denied));
  HMW_EXPECT(!denied.ok());
  HMW_EXPECT(denied.error.has_value());
  if (denied.error) {
    HMW_EXPECT(denied.error->status == hmw::Status::kIoError);
  }
  hmw::Result<bool> missing = hmw::internal::ValidateMediaFileStatus(
      std::filesystem::file_status{},
      std::make_error_code(std::errc::no_such_file_or_directory));
  HMW_EXPECT(!missing.ok());
  HMW_EXPECT(missing.error.has_value());
  if (missing.error) {
    HMW_EXPECT(missing.error->status == hmw::Status::kNotFound);
  }
}

HMW_TEST(media_foundation_source_factory_rejects_audio_only_media) {
  hmw::Result<std::unique_ptr<hmw::FrameSource>> result =
      hmw::OpenMediaSource(AudioOnlyFixturePath());
  HMW_EXPECT(!result.ok());
  HMW_EXPECT(result.error.has_value());
  if (result.error) {
    HMW_EXPECT(result.error->status == hmw::Status::kUnsupportedMedia);
  }
}
