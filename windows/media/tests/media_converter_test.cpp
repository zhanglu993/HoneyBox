#include "honey_media_windows/media_converter.h"
#include "honey_media_windows/rgba_transform.h"
#include "../src/media_converter_internal.h"

#include "honey_media_core/media_core.h"
#include "benchmark_support.h"
#include "test_support.h"

#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace {

constexpr uint32_t kCvid = HMC_MEDIA_FOURCC('c', 'v', 'i', 'd');

std::string Sha256Hex(const std::vector<uint8_t>& bytes) {
  HMW_EXPECT(bytes.size() <= (std::numeric_limits<ULONG>::max)());
  if (bytes.size() > (std::numeric_limits<ULONG>::max)()) {
    return {};
  }
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  NTSTATUS status = BCryptOpenAlgorithmProvider(
      &algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0U);
  HMW_EXPECT(status >= 0);
  std::array<UCHAR, 32U> digest{};
  if (status >= 0) {
    status = BCryptHash(
        algorithm, nullptr, 0U,
        const_cast<PUCHAR>(reinterpret_cast<const UCHAR*>(bytes.data())),
        static_cast<ULONG>(bytes.size()), digest.data(),
        static_cast<ULONG>(digest.size()));
    HMW_EXPECT(status >= 0);
  }
  if (algorithm != nullptr) {
    HMW_EXPECT(BCryptCloseAlgorithmProvider(algorithm, 0U) >= 0);
  }
  if (status < 0) {
    return {};
  }
  std::ostringstream hex;
  hex << std::hex << std::setfill('0');
  for (const UCHAR byte : digest) {
    hex << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return hex.str();
}

std::filesystem::path ProjectPath(const std::filesystem::path& relative) {
  return std::filesystem::path(HMW_PROJECT_SOURCE_DIR) / relative;
}

std::filesystem::path MovFixturePath() {
  return ProjectPath("assets/example/video/badge-preset-video-1.mov");
}

std::filesystem::path GifFixturePath() {
  return std::filesystem::path(HMW_TEST_SOURCE_DIR) / "fixtures" /
         "animated_disposal.gif";
}

class TemporaryFile {
 public:
  TemporaryFile(std::string extension, const std::vector<uint8_t>& bytes) {
    std::error_code error;
    const std::filesystem::path directory =
        std::filesystem::temp_directory_path(error);
    HMW_EXPECT(!error);
    for (uint32_t attempt = 0; attempt < 1000 && path_.empty(); ++attempt) {
      const std::filesystem::path candidate =
          directory / ("hmw-media-converter-" + std::to_string(attempt) +
                       extension);
      if (!std::filesystem::exists(candidate, error)) {
        path_ = candidate;
      }
      HMW_EXPECT(!error);
    }
    std::ofstream output(path_, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char*>(bytes.data()),
                 static_cast<std::streamsize>(bytes.size()));
    HMW_EXPECT(output.good());
  }

  ~TemporaryFile() {
    std::error_code error;
    std::filesystem::remove(path_, error);
  }

  TemporaryFile(const TemporaryFile&) = delete;
  TemporaryFile& operator=(const TemporaryFile&) = delete;

  const std::filesystem::path& path() const { return path_; }

 private:
  std::filesystem::path path_;
};

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

using Reader = std::unique_ptr<hmc_avi_reader_t, ReaderDeleter>;
using Decoder = std::unique_ptr<hmc_cinepak_decoder_t, DecoderDeleter>;

struct OpenedAvi {
  Reader reader;
  hmc_avi_info_t info;
};

OpenedAvi OpenAvi(const hmw::ConversionResult& result) {
  hmc_avi_reader_t* raw = nullptr;
  const hmc_status_t opened = hmc_avi_reader_create_copy(
      result.avi.data(), result.avi.size(), &raw);
  HMW_EXPECT(opened == HMC_STATUS_OK);
  OpenedAvi avi{Reader(raw), {}};
  avi.info.struct_size = sizeof(avi.info);
  if (avi.reader) {
    HMW_EXPECT(hmc_avi_reader_get_info(avi.reader.get(), &avi.info) ==
               HMC_STATUS_OK);
  }
  HMW_EXPECT(avi.info.handler_fourcc == kCvid);
  HMW_EXPECT(avi.info.compression_fourcc == kCvid);
  HMW_EXPECT(avi.info.bit_count == 24);
  HMW_EXPECT(avi.info.width == result.width);
  HMW_EXPECT(avi.info.height == result.height);
  HMW_EXPECT(avi.info.frame_count == result.frame_count);
  if (avi.reader) {
    for (uint32_t index = 0; index < avi.info.frame_count; ++index) {
      hmc_avi_frame_info_t frame_info{};
      frame_info.struct_size = sizeof(frame_info);
      HMW_EXPECT(hmc_avi_reader_get_frame_info(avi.reader.get(), index,
                                               &frame_info) == HMC_STATUS_OK);
      HMW_EXPECT((frame_info.frame_flags & HMC_FRAME_FLAG_KEY_KNOWN) != 0);
    }
  }
  return avi;
}

std::vector<uint32_t> DecodeThrough(OpenedAvi* avi, uint32_t target) {
  hmc_cinepak_decoder_config_t config{};
  HMW_EXPECT(hmc_cinepak_decoder_config_init(&config, sizeof(config)) ==
             HMC_STATUS_OK);
  config.width = avi->info.width;
  config.height = avi->info.height;
  hmc_cinepak_decoder_t* raw = nullptr;
  HMW_EXPECT(hmc_cinepak_decoder_create(&config, &raw) == HMC_STATUS_OK);
  Decoder decoder(raw);
  const uint64_t count64 =
      static_cast<uint64_t>(avi->info.width) * avi->info.height;
  HMW_EXPECT(count64 <= std::numeric_limits<size_t>::max());
  std::vector<uint32_t> pixels(static_cast<size_t>(count64));
  for (uint32_t index = 0; index <= target && decoder; ++index) {
    hmc_avi_frame_info_t frame_info{};
    frame_info.struct_size = sizeof(frame_info);
    HMW_EXPECT(hmc_avi_reader_get_frame_info(avi->reader.get(), index,
                                             &frame_info) == HMC_STATUS_OK);
    HMW_EXPECT((frame_info.frame_flags & HMC_FRAME_FLAG_KEY_KNOWN) != 0);
    hmc_bytes_view_t frame{};
    HMW_EXPECT(hmc_avi_reader_get_frame_view(avi->reader.get(), index, &frame) ==
               HMC_STATUS_OK);
    HMW_EXPECT(hmc_cinepak_decoder_decode(decoder.get(), frame.data, frame.size,
                                          pixels.data(), pixels.size()) ==
               HMC_STATUS_OK);
  }
  return pixels;
}

hmw::RgbaFrame SolidFrame(uint32_t size, uint8_t red, uint8_t green,
                          uint8_t blue) {
  const size_t count = static_cast<size_t>(size) * size;
  std::vector<uint8_t> pixels(count * 4U);
  for (size_t index = 0; index < count; ++index) {
    pixels[index * 4U] = red;
    pixels[index * 4U + 1U] = green;
    pixels[index * 4U + 2U] = blue;
    pixels[index * 4U + 3U] = 255;
  }
  return hmw::RgbaFrame{size, size, 0, 0, std::move(pixels)};
}
hmw::RgbaFrame NonuniformStrip() {
  hmw::RgbaFrame strip = SolidFrame(8, 0, 0, 0);
  const uint8_t colors[4][3] = {
      {255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 0}};
  for (uint32_t y = 0; y < strip.height; ++y) {
    for (uint32_t x = 0; x < strip.width; ++x) {
      const size_t offset = (static_cast<size_t>(y) * strip.width + x) * 4U;
      const uint32_t color = x / 2U;
      strip.pixels[offset] = colors[color][0];
      strip.pixels[offset + 1U] = colors[color][1];
      strip.pixels[offset + 2U] = colors[color][2];
    }
  }
  return strip;
}

hmw::ConversionRequest SmallConversion(const std::filesystem::path& path) {
  return hmw::ConversionRequest{path,
                                8,
                                8,
                                2,
                                80,
                                1,
                                1,
                                0,
                                0,
                                3,
                                0xff000000U,
                                hmw::FitMode::kCover,
                                std::nullopt};
}

bool ChannelNear(uint32_t argb, uint8_t red, uint8_t green, uint8_t blue,
                 int tolerance = 45) {
  const int actual_red = static_cast<int>((argb >> 16U) & 0xffU);
  const int actual_green = static_cast<int>((argb >> 8U) & 0xffU);
  const int actual_blue = static_cast<int>(argb & 0xffU);
  return std::abs(actual_red - static_cast<int>(red)) <= tolerance &&
         std::abs(actual_green - static_cast<int>(green)) <= tolerance &&
         std::abs(actual_blue - static_cast<int>(blue)) <= tolerance;
}

uint32_t ReadBigEndian32(const uint8_t* bytes) {
  return (static_cast<uint32_t>(bytes[0]) << 24U) |
         (static_cast<uint32_t>(bytes[1]) << 16U) |
         (static_cast<uint32_t>(bytes[2]) << 8U) |
         static_cast<uint32_t>(bytes[3]);
}

std::pair<uint32_t, uint32_t> PngDimensions(
    const std::vector<uint8_t>& png) {
  HMW_EXPECT(png.size() >= 24);
  if (png.size() < 24) {
    return {0, 0};
  }
  HMW_EXPECT(std::equal(png.begin(), png.begin() + 8,
                        std::vector<uint8_t>{137, 80, 78, 71, 13, 10, 26, 10}
                            .begin()));
  return {ReadBigEndian32(png.data() + 16),
          ReadBigEndian32(png.data() + 20)};
}

}  // namespace

HMW_TEST(benchmark_fixture_default_avi_sha256_baseline) {
  const hmw::Result<hmw::ConversionResult> converted = hmw::ConvertMedia(
      hmw::test::DefaultBenchmarkRequest(hmw::test::MovFixturePath()),
      IgnoreProgress, NeverCancel);
  HMW_EXPECT(converted.ok());
  if (!converted.ok()) {
    return;
  }
  const size_t length = converted.value->avi.size();
  const std::string sha256 = Sha256Hex(converted.value->avi);
  std::printf("ROUND3A_BASELINE_LENGTH=%zu\n", length);
  std::printf("ROUND3A_BASELINE_SHA256=%s\n", sha256.c_str());
  HMW_EXPECT(length == 2098498U);
  HMW_EXPECT(sha256 == "f48ebfb6abf4327e5bff5a6ada68bf942a5b73e8d6a7f4a8da15a7be78d46ef2");
}

HMW_TEST(benchmark_fixture_sampled_frames_equal_old_transform_bytes) {
  hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenMediaSource(hmw::test::MovFixturePath());
  HMW_EXPECT(opened.ok());
  if (!opened.ok()) {
    return;
  }
  std::unique_ptr<hmw::FrameSource> source = std::move(*opened.value);
  const hmw::SourceInfo info = source->info();
  HMW_EXPECT(info.width == 360U);
  HMW_EXPECT(info.height == 360U);
  HMW_EXPECT(info.clockwise_rotation == 0U);
  HMW_EXPECT(!info.is_gif);

  hmw::internal::ForwardFrameSampler sampler(source.get());
  constexpr uint32_t kFrameCount = 120U;
  constexpr int64_t kFrameDuration100ns = 1000000;
  for (uint32_t index = 0U; index < kFrameCount; ++index) {
    const hmw::Result<std::reference_wrapper<const hmw::RgbaFrame>> sampled =
        sampler.Sample(static_cast<int64_t>(index) * kFrameDuration100ns,
                       NeverCancel);
    HMW_EXPECT(sampled.ok());
    if (!sampled.ok()) {
      return;
    }
    const hmw::RgbaFrame& frame = sampled.value->get();
    const hmw::Result<hmw::RgbaFrame> transformed = hmw::TransformRgba(
        frame,
        hmw::TransformRequest{360U, 360U, hmw::FitMode::kCover, std::nullopt,
                              0xff000000U, 0U});
    HMW_EXPECT(transformed.ok());
    if (!transformed.ok()) {
      return;
    }
    HMW_EXPECT(transformed.value->width == frame.width);
    HMW_EXPECT(transformed.value->height == frame.height);
    HMW_EXPECT(transformed.value->pts_100ns == frame.pts_100ns);
    HMW_EXPECT(transformed.value->duration_100ns == frame.duration_100ns);
    HMW_EXPECT(transformed.value->pixels == frame.pixels);
  }
}

HMW_TEST(identity_conversion_frame_requires_exact_safe_context) {
  hmw::RgbaFrame sampled = SolidFrame(4U, 10U, 20U, 30U);
  const hmw::SourceInfo source_info{4U, 4U, 10000000, 10.0, 0U, false};
  hmw::ConversionRequest request =
      hmw::test::DefaultBenchmarkRequest("unused.mov");
  request.width = 4U;
  request.height = 4U;

  HMW_EXPECT(hmw::internal::CanUseIdentityConversionFrame(
      sampled, source_info, 4U, 4U, request));

  hmw::SourceInfo changed_info = source_info;
  changed_info.is_gif = true;
  HMW_EXPECT(!hmw::internal::CanUseIdentityConversionFrame(
      sampled, changed_info, 4U, 4U, request));
  changed_info = source_info;
  changed_info.clockwise_rotation = 90U;
  HMW_EXPECT(!hmw::internal::CanUseIdentityConversionFrame(
      sampled, changed_info, 4U, 4U, request));
  changed_info = source_info;
  changed_info.width = 8U;
  HMW_EXPECT(!hmw::internal::CanUseIdentityConversionFrame(
      sampled, changed_info, 4U, 4U, request));

  hmw::ConversionRequest changed_request = request;
  changed_request.crop = hmw::CropRect{0.0, 0.0, 1.0, 1.0};
  HMW_EXPECT(!hmw::internal::CanUseIdentityConversionFrame(
      sampled, source_info, 4U, 4U, changed_request));
  changed_request = request;
  changed_request.background_argb = 0xffffffffU;
  HMW_EXPECT(!hmw::internal::CanUseIdentityConversionFrame(
      sampled, source_info, 4U, 4U, changed_request));
  changed_request = request;
  changed_request.fit = hmw::FitMode::kContain;
  HMW_EXPECT(!hmw::internal::CanUseIdentityConversionFrame(
      sampled, source_info, 4U, 4U, changed_request));

  HMW_EXPECT(!hmw::internal::CanUseIdentityConversionFrame(
      sampled, source_info, 8U, 4U, request));
  hmw::RgbaFrame malformed = sampled;
  malformed.pixels.pop_back();
  HMW_EXPECT(!hmw::internal::CanUseIdentityConversionFrame(
      malformed, source_info, 4U, 4U, request));
}

HMW_TEST(convert_mov_produces_readable_cvid_avi) {
  const hmw::Result<hmw::ConversionResult> converted = hmw::ConvertMedia(
      SmallConversion(MovFixturePath()), IgnoreProgress, NeverCancel);
  HMW_EXPECT(converted.ok());
  if (!converted.ok()) {
    return;
  }
  HMW_EXPECT(converted.value->frame_count == 3);
  HMW_EXPECT(converted.value->fps == 2.0);
  OpenedAvi avi = OpenAvi(*converted.value);
  const std::vector<uint32_t> first = DecodeThrough(&avi, 0);
  const std::vector<uint32_t> last = DecodeThrough(&avi, 2);
  HMW_EXPECT(first != last);
  HMW_EXPECT(std::any_of(first.begin(), first.end(), [](uint32_t pixel) {
    return (pixel & 0x00ffffffU) != 0;
  }));
  HMW_EXPECT(std::any_of(last.begin(), last.end(), [](uint32_t pixel) {
    return (pixel & 0x00ffffffU) != 0;
  }));
}

HMW_TEST(frame_plan_preserves_a_short_gif_tail_without_changing_mov) {
  constexpr int64_t kDuration100ns = 1'400'000;
  HMW_EXPECT(
      hmw::internal::PlannedFrameCount(kDuration100ns, 10.0, 10, true) == 2);
  HMW_EXPECT(
      hmw::internal::PlannedFrameCount(kDuration100ns, 10.0, 10, false) == 1);
  HMW_EXPECT(
      hmw::internal::PresentationTimestamp(0, 10.0, kDuration100ns) == 0);
  HMW_EXPECT(
      hmw::internal::PresentationTimestamp(1, 10.0, kDuration100ns) == 1'000'000);
  const double native_fps = 2.0 / 0.14;
  HMW_EXPECT(hmw::internal::PlannedFrameCount(
                 kDuration100ns, native_fps, 10, true) == 2);
  constexpr int64_t kThreeFrameDuration100ns = 1'800'000;
  const double three_frame_native_fps = 3.0 / 0.18;
  HMW_EXPECT(hmw::internal::PlannedFrameCount(
                 kThreeFrameDuration100ns, three_frame_native_fps, 10, true) == 3);
  HMW_EXPECT(hmw::internal::PlannedFrameCount(
                 kThreeFrameDuration100ns, three_frame_native_fps, 1, true) == 1);
}

HMW_TEST(convert_gif_uses_requested_background_and_timeline) {
  hmw::ConversionRequest request = SmallConversion(GifFixturePath());
  request.width = 4;
  request.height = 4;
  request.fps = 10;
  request.max_frames = 10;
  request.background_argb = 0xffff00ffU;
  const hmw::Result<hmw::ConversionResult> converted =
      hmw::ConvertMedia(request, IgnoreProgress, NeverCancel);
  HMW_EXPECT(converted.ok());
  if (!converted.ok()) {
    return;
  }
  HMW_EXPECT(converted.value->frame_count == 3);
  HMW_EXPECT(converted.value->fps == 10.0);
  OpenedAvi avi = OpenAvi(*converted.value);
  HMW_EXPECT(avi.info.usec_per_frame == 100000);
  const std::vector<uint32_t> pixels = DecodeThrough(&avi, 1);
  HMW_EXPECT(pixels.size() == 16);
  if (pixels.size() == 16) {
    HMW_EXPECT(ChannelNear(pixels[6], 255, 0, 255, 70));
  }
}

HMW_TEST(convert_gif_keeps_a_partial_tail_on_the_sampling_timeline) {
  hmw::ConversionRequest request = SmallConversion(GifFixturePath());
  request.width = 4;
  request.height = 4;
  request.fps = 5;
  request.max_frames = 10;

  const hmw::Result<hmw::ConversionResult> converted =
      hmw::ConvertMedia(request, IgnoreProgress, NeverCancel);
  HMW_EXPECT(converted.ok());
  if (!converted.ok()) {
    return;
  }
  HMW_EXPECT(converted.value->frame_count == 2);
  if (converted.value->frame_count != 2) {
    return;
  }
  OpenedAvi avi = OpenAvi(*converted.value);
  const std::vector<uint32_t> first = DecodeThrough(&avi, 0);
  const std::vector<uint32_t> second = DecodeThrough(&avi, 1);
  HMW_EXPECT(!first.empty());
  HMW_EXPECT(!second.empty());
  HMW_EXPECT(first != second);
}

HMW_TEST(convert_progress_is_monotonic_and_finishes_at_total) {
  std::vector<std::pair<uint32_t, uint32_t>> updates;
  const hmw::Result<hmw::ConversionResult> converted = hmw::ConvertMedia(
      SmallConversion(MovFixturePath()),
      [&updates](uint32_t done, uint32_t total) {
        updates.emplace_back(done, total);
      },
      NeverCancel);
  HMW_EXPECT(converted.ok());
  HMW_EXPECT(!updates.empty());
  for (size_t index = 1; index < updates.size(); ++index) {
    HMW_EXPECT(updates[index].first >= updates[index - 1].first);
    HMW_EXPECT(updates[index].second == updates[index - 1].second);
  }
  if (converted.ok() && !updates.empty()) {
    HMW_EXPECT(updates.back().first == updates.back().second);
    HMW_EXPECT(updates.back().second == converted.value->frame_count);
    OpenedAvi avi = OpenAvi(*converted.value);
    HMW_EXPECT(avi.info.frame_count == converted.value->frame_count);
  }
}

HMW_TEST(convert_cancel_returns_no_partial_avi) {
  bool cancel = false;
  const hmw::Result<hmw::ConversionResult> converted = hmw::ConvertMedia(
      SmallConversion(MovFixturePath()),
      [&cancel](uint32_t, uint32_t) { cancel = true; },
      [&cancel]() { return cancel; });
  HMW_EXPECT(!converted.ok());
  HMW_EXPECT(!converted.value.has_value());
  HMW_EXPECT(converted.error.has_value());
  if (converted.error) {
    HMW_EXPECT(converted.error->status == hmw::Status::kCancelled);
  }
}

HMW_TEST(slideshow_forces_key_frame_for_each_source_slide) {
  const hmw::SlideshowRequest request{
      {SolidFrame(4, 255, 0, 0), SolidFrame(4, 0, 0, 255)},
      {2, 2}, 4, 10, 100};
  const hmw::Result<hmw::ConversionResult> encoded =
      hmw::EncodeSlideshow(request, IgnoreProgress, NeverCancel);
  HMW_EXPECT(encoded.ok());
  if (!encoded.ok()) {
    return;
  }
  HMW_EXPECT(encoded.value->frame_count == 4);
  OpenedAvi avi = OpenAvi(*encoded.value);
  for (uint32_t index : {0U, 2U}) {
    hmc_avi_frame_info_t info{};
    info.struct_size = sizeof(info);
    HMW_EXPECT(hmc_avi_reader_get_frame_info(avi.reader.get(), index, &info) ==
               HMC_STATUS_OK);
    HMW_EXPECT((info.frame_flags & HMC_FRAME_FLAG_KEY) != 0);
  }
  const std::vector<uint32_t> pixels = DecodeThrough(&avi, 3);
  HMW_EXPECT(!pixels.empty());
  if (!pixels.empty()) {
    HMW_EXPECT(ChannelNear(pixels[0], 0, 0, 255));
  }
}

HMW_TEST(scroll_output_loops_without_visible_seam) {
  const hmw::ScrollRequest request{NonuniformStrip(),
                                   8,
                                   0xff000000U,
                                   16,
                                   4,
                                   8,
                                   100,
                                   20};
  const hmw::Result<hmw::ConversionResult> encoded =
      hmw::EncodeScroll(request, IgnoreProgress, NeverCancel);
  HMW_EXPECT(encoded.ok());
  if (!encoded.ok()) {
    return;
  }
  HMW_EXPECT(encoded.value->frame_count == 4);
  OpenedAvi avi = OpenAvi(*encoded.value);
  const std::vector<uint32_t> last = DecodeThrough(&avi, 3);
  const std::vector<uint32_t> first = DecodeThrough(&avi, 0);
  const std::vector<uint32_t> middle = DecodeThrough(&avi, 2);
  HMW_EXPECT(last.size() == 64 && first.size() == 64 && middle.size() == 64);
  if (last.size() == 64 && first.size() == 64 && middle.size() == 64) {
    HMW_EXPECT(ChannelNear(first[0], 255, 0, 0));
    HMW_EXPECT(ChannelNear(first[2], 0, 255, 0));
    HMW_EXPECT(ChannelNear(first[4], 0, 0, 255));
    HMW_EXPECT(ChannelNear(first[6], 255, 255, 0));
    HMW_EXPECT(std::all_of(middle.begin(), middle.end(), [](uint32_t pixel) {
      return ChannelNear(pixel, 0, 0, 0);
    }));
    HMW_EXPECT(ChannelNear(last[0], 0, 0, 0));
    HMW_EXPECT(ChannelNear(last[2], 0, 0, 0));
    HMW_EXPECT(ChannelNear(last[4], 255, 0, 0));
    HMW_EXPECT(ChannelNear(last[6], 0, 255, 0));
    HMW_EXPECT(last[4] == first[0]);
    HMW_EXPECT(last[6] == first[2]);
  }
}

HMW_TEST(cached_cvid_decodes_stateful_frames_in_order) {
  const hmw::SlideshowRequest slideshow{
      {SolidFrame(4, 220, 40, 40), SolidFrame(4, 40, 220, 40),
       SolidFrame(4, 40, 40, 220)},
      {1, 1, 1}, 4, 10, 100};
  const hmw::Result<hmw::ConversionResult> encoded =
      hmw::EncodeSlideshow(slideshow, IgnoreProgress, NeverCancel);
  HMW_EXPECT(encoded.ok());
  if (!encoded.ok()) {
    return;
  }
  const TemporaryFile file(".avi", encoded.value->avi);
  const hmw::Result<hmw::PreviewResult> full = hmw::DecodeCachedCvid(
      hmw::DecodeCvidRequest{file.path(), 3, 4}, NeverCancel);
  const hmw::Result<hmw::PreviewResult> preview = hmw::DecodeCachedCvid(
      hmw::DecodeCvidRequest{file.path(), 2, 4}, NeverCancel);
  HMW_EXPECT(preview.ok());
  if (!preview.ok()) {
    return;
  }
  HMW_EXPECT(preview.value->png_frames.size() == 2);
  HMW_EXPECT(full.ok() && full.value->png_frames.size() == 3);
  HMW_EXPECT(preview.value->interval_ms == 100);
  if (preview.value->png_frames.size() == 2 && full.ok() &&
      full.value->png_frames.size() == 3) {
    HMW_EXPECT(PngDimensions(preview.value->png_frames[0]) ==
               std::make_pair(4U, 4U));
    HMW_EXPECT(full.value->png_frames[0] != full.value->png_frames[1]);
    HMW_EXPECT(full.value->png_frames[1] != full.value->png_frames[2]);
    HMW_EXPECT(preview.value->png_frames[0] == full.value->png_frames[0]);
    HMW_EXPECT(preview.value->png_frames[1] == full.value->png_frames[2]);
  }
}

HMW_TEST(png_operations_recheck_cancel_after_encoder_returns) {
  const hmw::SlideshowRequest slideshow{{SolidFrame(4, 20, 40, 60)},
                                        {1}, 4, 10, 100};
  const hmw::Result<hmw::ConversionResult> encoded =
      hmw::EncodeSlideshow(slideshow, IgnoreProgress, NeverCancel);
  HMW_EXPECT(encoded.ok());
  if (!encoded.ok()) {
    return;
  }
  const TemporaryFile cached_file(".avi", encoded.value->avi);
  bool cancel = false;
  uint32_t encode_calls = 0;
  hmw::internal::ScopedPngEncoderOverride override_encoder(
      [&cancel, &encode_calls](const hmw::RgbaFrame&) {
        ++encode_calls;
        cancel = true;
        return hmw::Result<std::vector<uint8_t>>{
            std::vector<uint8_t>{1U}, std::nullopt};
      });
  const auto expect_cancelled = [](const auto& result) {
    HMW_EXPECT(!result.ok() && !result.value.has_value());
    HMW_EXPECT(result.error.has_value());
    if (result.error) {
      HMW_EXPECT(result.error->status == hmw::Status::kCancelled);
    }
  };

  cancel = false;
  expect_cancelled(hmw::MakeThumbnail(
      hmw::ThumbnailRequest{GifFixturePath()}, [&cancel]() { return cancel; }));
  cancel = false;
  expect_cancelled(hmw::MakePreview(
      hmw::PreviewRequest{GifFixturePath(), 1, 4},
      [&cancel]() { return cancel; }));
  cancel = false;
  expect_cancelled(hmw::DecodeCachedCvid(
      hmw::DecodeCvidRequest{cached_file.path(), 1, 4},
      [&cancel]() { return cancel; }));
  HMW_EXPECT(encode_calls == 3);
}

HMW_TEST(png_encoder_error_does_not_override_cancellation) {
  const hmw::SlideshowRequest slideshow{{SolidFrame(4, 20, 40, 60)},
                                        {1}, 4, 10, 100};
  const hmw::Result<hmw::ConversionResult> encoded =
      hmw::EncodeSlideshow(slideshow, IgnoreProgress, NeverCancel);
  HMW_EXPECT(encoded.ok());
  if (!encoded.ok()) {
    return;
  }
  const TemporaryFile cached_file(".avi", encoded.value->avi);
  bool cancel = false;
  uint32_t encode_calls = 0;
  hmw::internal::ScopedPngEncoderOverride override_encoder(
      [&cancel, &encode_calls](const hmw::RgbaFrame&) {
        ++encode_calls;
        cancel = true;
        return hmw::Result<std::vector<uint8_t>>{
            std::nullopt,
            hmw::Error{hmw::Status::kEncodeFailed, "injected PNG failure"}};
      });
  const auto expect_cancelled = [](const auto& result) {
    HMW_EXPECT(!result.ok() && !result.value.has_value());
    HMW_EXPECT(result.error.has_value());
    if (result.error) {
      HMW_EXPECT(result.error->status == hmw::Status::kCancelled);
    }
  };

  cancel = false;
  expect_cancelled(hmw::MakeThumbnail(
      hmw::ThumbnailRequest{GifFixturePath()}, [&cancel]() { return cancel; }));
  cancel = false;
  expect_cancelled(hmw::MakePreview(
      hmw::PreviewRequest{GifFixturePath(), 1, 4},
      [&cancel]() { return cancel; }));
  cancel = false;
  expect_cancelled(hmw::DecodeCachedCvid(
      hmw::DecodeCvidRequest{cached_file.path(), 1, 4},
      [&cancel]() { return cancel; }));
  HMW_EXPECT(encode_calls == 3);
}

HMW_TEST(png_encoder_override_restores_nested_slots) {
  uint32_t outer_calls = 0;
  uint32_t inner_calls = 0;
  {
    hmw::internal::ScopedPngEncoderOverride outer(
        [&outer_calls](const hmw::RgbaFrame&) {
          ++outer_calls;
          return hmw::Result<std::vector<uint8_t>>{
              std::vector<uint8_t>{11U}, std::nullopt};
        });
    const hmw::Result<hmw::ThumbnailResult> outer_before =
        hmw::MakeThumbnail(hmw::ThumbnailRequest{GifFixturePath()},
                           NeverCancel);
    HMW_EXPECT(outer_before.ok());
    if (outer_before.ok()) {
      HMW_EXPECT(outer_before.value->png == std::vector<uint8_t>{11U});
    }
    {
      hmw::internal::ScopedPngEncoderOverride inner(
          [&inner_calls](const hmw::RgbaFrame&) {
            ++inner_calls;
            return hmw::Result<std::vector<uint8_t>>{
                std::vector<uint8_t>{22U}, std::nullopt};
          });
      const hmw::Result<hmw::ThumbnailResult> inner_result =
          hmw::MakeThumbnail(hmw::ThumbnailRequest{GifFixturePath()},
                             NeverCancel);
      HMW_EXPECT(inner_result.ok());
      if (inner_result.ok()) {
        HMW_EXPECT(inner_result.value->png == std::vector<uint8_t>{22U});
      }
    }
    const hmw::Result<hmw::ThumbnailResult> outer_after =
        hmw::MakeThumbnail(hmw::ThumbnailRequest{GifFixturePath()},
                           NeverCancel);
    HMW_EXPECT(outer_after.ok());
    if (outer_after.ok()) {
      HMW_EXPECT(outer_after.value->png == std::vector<uint8_t>{11U});
    }
  }
  const hmw::Result<hmw::ThumbnailResult> default_result =
      hmw::MakeThumbnail(hmw::ThumbnailRequest{GifFixturePath()}, NeverCancel);
  HMW_EXPECT(default_result.ok());
  if (default_result.ok()) {
    HMW_EXPECT(PngDimensions(default_result.value->png) ==
               std::make_pair(4U, 4U));
  }
  HMW_EXPECT(outer_calls == 2);
  HMW_EXPECT(inner_calls == 1);
}

HMW_TEST(thumbnail_and_preview_obey_max_edge_and_count) {
  const hmw::Result<hmw::ThumbnailResult> thumbnail =
      hmw::MakeThumbnail(hmw::ThumbnailRequest{GifFixturePath()}, NeverCancel);
  HMW_EXPECT(thumbnail.ok());
  if (thumbnail.ok()) {
    HMW_EXPECT(thumbnail.value->width == 4);
    HMW_EXPECT(thumbnail.value->height == 4);
    HMW_EXPECT(thumbnail.value->is_gif);
    HMW_EXPECT(PngDimensions(thumbnail.value->png) == std::make_pair(4U, 4U));
  }

  const hmw::Result<hmw::PreviewResult> preview = hmw::MakePreview(
      hmw::PreviewRequest{GifFixturePath(), 2, 3}, NeverCancel);
  HMW_EXPECT(preview.ok());
  if (preview.ok()) {
    HMW_EXPECT(preview.value->png_frames.size() == 2);
    HMW_EXPECT(preview.value->interval_ms == 150);
    for (const std::vector<uint8_t>& png : preview.value->png_frames) {
      const auto dimensions = PngDimensions(png);
      HMW_EXPECT(std::max(dimensions.first, dimensions.second) <= 3);
    }
  }

  const hmw::Result<hmw::PreviewResult> zero_count = hmw::MakePreview(
      hmw::PreviewRequest{GifFixturePath(), 0, 3}, NeverCancel);
  const hmw::Result<hmw::PreviewResult> zero_edge = hmw::MakePreview(
      hmw::PreviewRequest{GifFixturePath(), 2, 0}, NeverCancel);
  HMW_EXPECT(!zero_count.ok() && zero_count.error.has_value());
  HMW_EXPECT(!zero_edge.ok() && zero_edge.error.has_value());
  if (zero_count.error && zero_edge.error) {
    HMW_EXPECT(zero_count.error->status == hmw::Status::kInvalidArgument);
    HMW_EXPECT(zero_edge.error->status == hmw::Status::kInvalidArgument);
  }
}

HMW_TEST(job_dispatch_covers_every_converter_channel_operation) {
  const hmw::SlideshowRequest slideshow{{SolidFrame(4, 100, 150, 200)},
                                        {2}, 4, 10, 80};
  const hmw::Result<hmw::ConversionResult> cached =
      hmw::EncodeSlideshow(slideshow, IgnoreProgress, NeverCancel);
  HMW_EXPECT(cached.ok());
  if (!cached.ok()) {
    return;
  }
  const TemporaryFile file(".avi", cached.value->avi);
  const std::vector<hmw::MediaJobRequest> requests{
      hmw::ThumbnailRequest{GifFixturePath()},
      hmw::PreviewRequest{GifFixturePath(), 1, 4},
      hmw::DecodeCvidRequest{file.path(), 1, 4},
      SmallConversion(GifFixturePath()),
      slideshow,
      hmw::ScrollRequest{SolidFrame(4, 255, 255, 255), 4, 0xff000000U,
                         8, 4, 4, 80, 2},
  };
  for (size_t index = 0; index < requests.size(); ++index) {
    const hmw::Result<hmw::MediaJobResult> result = hmw::ExecuteMediaJob(
        requests[index], IgnoreProgress, NeverCancel);
    HMW_EXPECT(result.ok());
    if (!result.ok()) {
      continue;
    }
    if (index == 0) {
      HMW_EXPECT(std::holds_alternative<hmw::ThumbnailResult>(*result.value));
    } else if (index <= 2) {
      HMW_EXPECT(std::holds_alternative<hmw::PreviewResult>(*result.value));
    } else {
      HMW_EXPECT(std::holds_alternative<hmw::ConversionResult>(*result.value));
      OpenedAvi avi = OpenAvi(
          std::get<hmw::ConversionResult>(*result.value));
      HMW_EXPECT(avi.info.frame_count != 0);
    }
  }


  std::vector<hmw::ConversionRequest> invalid_conversions;
  hmw::ConversionRequest invalid = SmallConversion(GifFixturePath());
  invalid.quality = 101;
  invalid_conversions.push_back(invalid);
  invalid = SmallConversion(GifFixturePath());
  invalid.refine = std::numeric_limits<uint32_t>::max();
  invalid_conversions.push_back(invalid);
  invalid = SmallConversion(GifFixturePath());
  invalid.strips = 0;
  invalid_conversions.push_back(invalid);
  invalid = SmallConversion(GifFixturePath());
  invalid.skip_threshold = std::numeric_limits<uint32_t>::max();
  invalid_conversions.push_back(invalid);
  invalid = SmallConversion(GifFixturePath());
  invalid.key_interval = std::numeric_limits<uint32_t>::max();
  invalid_conversions.push_back(invalid);
  invalid = SmallConversion(GifFixturePath());
  invalid.max_frames = 0;
  invalid_conversions.push_back(invalid);
  invalid = SmallConversion(GifFixturePath());
  invalid.fit = static_cast<hmw::FitMode>(99);
  invalid_conversions.push_back(invalid);
  invalid = SmallConversion(GifFixturePath());
  invalid.crop = hmw::CropRect{std::numeric_limits<double>::quiet_NaN(), 0.0,
                               1.0, 1.0};
  invalid_conversions.push_back(invalid);
  for (const hmw::ConversionRequest& invalid_request : invalid_conversions) {
    const hmw::Result<hmw::ConversionResult> result = hmw::ConvertMedia(
        invalid_request, IgnoreProgress, NeverCancel);
    HMW_EXPECT(!result.ok() && !result.value.has_value());
    HMW_EXPECT(result.error.has_value());
    if (result.error) {
      HMW_EXPECT(result.error->status == hmw::Status::kInvalidArgument);
    }
  }

  hmw::SlideshowRequest invalid_slideshow = slideshow;
  invalid_slideshow.holds[0] = 0;
  const hmw::Result<hmw::ConversionResult> bad_slideshow =
      hmw::EncodeSlideshow(invalid_slideshow, IgnoreProgress, NeverCancel);
  HMW_EXPECT(!bad_slideshow.ok() && bad_slideshow.error.has_value());
  hmw::ScrollRequest invalid_scroll{SolidFrame(4, 255, 255, 255),
                                    4,
                                    0xff123456U,
                                    8,
                                    4,
                                    4,
                                    80,
                                    0};
  const hmw::Result<hmw::ConversionResult> bad_scroll =
      hmw::EncodeScroll(invalid_scroll, IgnoreProgress, NeverCancel);
  HMW_EXPECT(!bad_scroll.ok() && bad_scroll.error.has_value());

  const hmw::Result<hmw::MediaJobResult> dispatched_error =
      hmw::ExecuteMediaJob(hmw::PreviewRequest{GifFixturePath(), 0, 4},
                           IgnoreProgress, NeverCancel);
  HMW_EXPECT(!dispatched_error.ok() && !dispatched_error.value.has_value());
  HMW_EXPECT(dispatched_error.error.has_value());
  if (dispatched_error.error) {
    HMW_EXPECT(dispatched_error.error->status == hmw::Status::kInvalidArgument);
    HMW_EXPECT(dispatched_error.error->message ==
               "preview count and edge must be nonzero");
  }
}
