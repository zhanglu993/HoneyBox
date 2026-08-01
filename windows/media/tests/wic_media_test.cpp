#include "honey_media_windows/media_source.h"
#include "honey_media_windows/png_codec.h"

#include "../src/wic_helpers.h"

#include "test_support.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <objbase.h>
#include <wincodec.h>
#include <wrl/client.h>

#include "../src/wic_metadata_internal.h"

#include <array>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;

class ScopedCom {
 public:
  ScopedCom() : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
  ~ScopedCom() {
    if (result_ == S_OK || result_ == S_FALSE) {
      CoUninitialize();
    }
  }

  bool ok() const { return SUCCEEDED(result_) || result_ == RPC_E_CHANGED_MODE; }

 private:
  HRESULT result_;
};

class TemporaryFile {
 public:
  TemporaryFile(std::string_view extension, const std::vector<uint8_t>& bytes) {
    const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
    path_ = std::filesystem::temp_directory_path() /
            ("hmw_wic_" + std::to_string(stamp) + std::string(extension));
    std::ofstream output(path_, std::ios::binary);
    output.write(reinterpret_cast<const char*>(bytes.data()),
                 static_cast<std::streamsize>(bytes.size()));
  }

  ~TemporaryFile() {
    std::error_code ignored;
    std::filesystem::remove(path_, ignored);
  }

  const std::filesystem::path& path() const { return path_; }

 private:
  std::filesystem::path path_;
};

std::filesystem::path FixturePath() {
  return std::filesystem::path(HMW_TEST_SOURCE_DIR) / "fixtures" /
         "animated_disposal.gif";
}

std::filesystem::path BackgroundFixturePath() {
  return std::filesystem::path(HMW_TEST_SOURCE_DIR) / "fixtures" /
         "background_keep_local_palette.gif";
}

std::vector<uint8_t> Pixel(const hmw::RgbaFrame& frame, uint32_t x,
                           uint32_t y) {
  const size_t offset =
      (static_cast<size_t>(y) * frame.width + x) * static_cast<size_t>(4);
  return std::vector<uint8_t>(frame.pixels.begin() + offset,
                              frame.pixels.begin() + offset + 4);
}

std::vector<hmw::RgbaFrame> ReadAll(hmw::FrameSource* source) {
  std::vector<hmw::RgbaFrame> frames;
  for (;;) {
    hmw::RgbaFrame frame{};
    const hmw::Result<bool> result = source->ReadNext(&frame);
    HMW_EXPECT(result.ok());
    if (!result.ok() || !*result.value) {
      break;
    }
    frames.push_back(std::move(frame));
  }
  return frames;
}

std::vector<uint8_t> SinglePixelGifWithDelay(uint16_t centiseconds) {
  return {
      'G', 'I', 'F', '8', '9', 'a', 1, 0, 1, 0, 0x80, 0, 0,
      0, 0, 0, 255, 255, 255,
      0x21, 0xf9, 4, 0x04,
      static_cast<uint8_t>(centiseconds & 0xffU),
      static_cast<uint8_t>((centiseconds >> 8) & 0xffU), 0, 0,
      0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0,
      2, 2, 0x44, 0x01, 0, 0x3b,
  };
}

int64_t GifDuration(const std::vector<uint8_t>& bytes) {
  const TemporaryFile file(".gif", bytes);
  hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenGifSource(file.path());
  HMW_EXPECT(opened.ok());
  return opened.ok() ? (*opened.value)->info().duration_100ns : -1;
}

std::vector<uint8_t> ReadFile(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(input),
                              std::istreambuf_iterator<char>());
}

hmw::Result<hmw::RgbaFrame> DecodePngWithWic(
    const std::vector<uint8_t>& encoded) {
  if (encoded.size() > std::numeric_limits<DWORD>::max()) {
    return {std::nullopt,
            hmw::Error{hmw::Status::kDecodeFailed, "test PNG is too large"}};
  }
  ScopedCom com;
  if (!com.ok()) {
    return {std::nullopt,
            hmw::Error{hmw::Status::kDecodeFailed, "COM initialization failed"}};
  }
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  ComPtr<IWICStream> stream;
  if (SUCCEEDED(hr)) {
    hr = factory->CreateStream(&stream);
  }
  if (SUCCEEDED(hr)) {
    hr = stream->InitializeFromMemory(
        const_cast<BYTE*>(encoded.data()), static_cast<DWORD>(encoded.size()));
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (SUCCEEDED(hr)) {
    hr = factory->CreateDecoderFromStream(stream.Get(), nullptr,
                                          WICDecodeMetadataCacheOnLoad,
                                          &decoder);
  }
  ComPtr<IWICBitmapFrameDecode> decoded_frame;
  if (SUCCEEDED(hr)) {
    hr = decoder->GetFrame(0, &decoded_frame);
  }
  UINT width = 0;
  UINT height = 0;
  if (SUCCEEDED(hr)) {
    hr = decoded_frame->GetSize(&width, &height);
  }
  ComPtr<IWICFormatConverter> converter;
  if (SUCCEEDED(hr)) {
    hr = factory->CreateFormatConverter(&converter);
  }
  if (SUCCEEDED(hr)) {
    hr = converter->Initialize(decoded_frame.Get(), GUID_WICPixelFormat32bppRGBA,
                               WICBitmapDitherTypeNone, nullptr, 0.0,
                               WICBitmapPaletteTypeCustom);
  }
  const uint64_t byte_count = static_cast<uint64_t>(width) * height * 4U;
  if (FAILED(hr) || byte_count > std::numeric_limits<UINT>::max()) {
    return {std::nullopt,
            hmw::Error{hmw::Status::kDecodeFailed, "WIC PNG decode failed"}};
  }
  std::vector<uint8_t> pixels(static_cast<size_t>(byte_count));
  hr = converter->CopyPixels(nullptr, width * 4U,
                             static_cast<UINT>(pixels.size()), pixels.data());
  if (FAILED(hr)) {
    return {std::nullopt,
            hmw::Error{hmw::Status::kDecodeFailed, "WIC PNG copy failed"}};
  }
  return {hmw::RgbaFrame{width, height, 0, 0, std::move(pixels)}, std::nullopt};
}

}  // namespace

HMW_TEST(wic_media_gif_ui1_metadata_rejects_ui2) {
  PROPVARIANT correct{};
  correct.vt = VT_UI1;
  correct.bVal = 3;
  uint32_t output = 0;
  HMW_EXPECT(SUCCEEDED(hmw::internal::GifUnsignedMetadataValue(
      correct, VT_UI1, &output)));
  HMW_EXPECT(output == 3);

  PROPVARIANT wrong{};
  wrong.vt = VT_UI2;
  wrong.uiVal = 3;
  HMW_EXPECT(FAILED(hmw::internal::GifUnsignedMetadataValue(
      wrong, VT_UI1, &output)));
}

HMW_TEST(wic_media_gif_ui2_metadata_rejects_ui1) {
  PROPVARIANT correct{};
  correct.vt = VT_UI2;
  correct.uiVal = 15;
  uint32_t output = 0;
  HMW_EXPECT(SUCCEEDED(hmw::internal::GifUnsignedMetadataValue(
      correct, VT_UI2, &output)));
  HMW_EXPECT(output == 15);

  PROPVARIANT wrong{};
  wrong.vt = VT_UI1;
  wrong.bVal = 15;
  HMW_EXPECT(FAILED(hmw::internal::GifUnsignedMetadataValue(
      wrong, VT_UI2, &output)));
}

HMW_TEST(wic_media_gif_boolean_metadata_rejects_ui1) {
  PROPVARIANT correct{};
  correct.vt = VT_BOOL;
  correct.boolVal = VARIANT_TRUE;
  bool output = false;
  HMW_EXPECT(SUCCEEDED(
      hmw::internal::GifBooleanMetadataValue(correct, &output)));
  HMW_EXPECT(output);

  PROPVARIANT wrong{};
  wrong.vt = VT_UI1;
  wrong.bVal = 1;
  HMW_EXPECT(FAILED(hmw::internal::GifBooleanMetadataValue(wrong, &output)));
}

HMW_TEST(wic_media_png_round_trip_preserves_rgba_and_dimensions) {
  const hmw::RgbaFrame original{2, 2, 0, 0, {
      1, 2, 3, 4, 10, 20, 30, 128,
      40, 50, 60, 255, 250, 240, 230, 0,
  }};

  const hmw::Result<std::vector<uint8_t>> encoded = hmw::EncodePng(original);
  HMW_EXPECT(encoded.ok());
  if (!encoded.ok()) {
    return;
  }
  HMW_EXPECT(encoded.value->size() > 8);
  HMW_EXPECT(std::equal(encoded.value->begin(), encoded.value->begin() + 8,
                        std::array<uint8_t, 8>{137, 80, 78, 71, 13, 10, 26, 10}.begin()));

  const hmw::Result<hmw::RgbaFrame> decoded = DecodePngWithWic(*encoded.value);
  HMW_EXPECT(decoded.ok());
  if (decoded.ok()) {
    HMW_EXPECT(decoded.value->width == original.width);
    HMW_EXPECT(decoded.value->height == original.height);
    HMW_EXPECT(decoded.value->pixels == original.pixels);
  }
}

HMW_TEST(wic_media_gif_reports_canvas_and_total_duration) {
  hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenGifSource(FixturePath());

  HMW_EXPECT(opened.ok());
  if (!opened.ok()) {
    return;
  }
  const hmw::SourceInfo& info = (*opened.value)->info();
  HMW_EXPECT(info.width == 4);
  HMW_EXPECT(info.height == 4);
  HMW_EXPECT(info.duration_100ns == 3000000);
  HMW_EXPECT(info.nominal_fps == 10.0);
  HMW_EXPECT(info.clockwise_rotation == 0);
  HMW_EXPECT(info.is_gif);

  const std::vector<hmw::RgbaFrame> frames = ReadAll(opened.value->get());
  HMW_EXPECT(frames.size() == 3);
  if (frames.size() == 3) {
    HMW_EXPECT(frames[0].pts_100ns == 0);
    HMW_EXPECT(frames[0].duration_100ns == 500000);
    HMW_EXPECT(frames[1].pts_100ns == 500000);
    HMW_EXPECT(frames[1].duration_100ns == 1000000);
    HMW_EXPECT(frames[2].pts_100ns == 1500000);
    HMW_EXPECT(frames[2].duration_100ns == 1500000);
  }
}

HMW_TEST(wic_media_gif_composes_offsets_and_transparency) {
  hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenGifSource(FixturePath());
  HMW_EXPECT(opened.ok());
  if (!opened.ok()) {
    return;
  }

  const std::vector<hmw::RgbaFrame> frames = ReadAll(opened.value->get());
  HMW_EXPECT(frames.size() == 3);
  if (frames.size() == 3) {
    HMW_EXPECT(Pixel(frames[0], 3, 3) ==
               std::vector<uint8_t>({255, 0, 0, 255}));
    HMW_EXPECT(Pixel(frames[1], 1, 1) ==
               std::vector<uint8_t>({0, 255, 0, 255}));
    HMW_EXPECT(Pixel(frames[1], 2, 1) ==
               std::vector<uint8_t>({0, 0, 0, 0}));
    HMW_EXPECT(Pixel(frames[1], 0, 0) ==
               std::vector<uint8_t>({0, 0, 0, 0}));
  }
}

HMW_TEST(wic_media_gif_applies_background_and_previous_disposal) {
  hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenGifSource(FixturePath());
  HMW_EXPECT(opened.ok());
  if (!opened.ok()) {
    return;
  }

  const std::vector<hmw::RgbaFrame> frames = ReadAll(opened.value->get());
  HMW_EXPECT(frames.size() == 3);
  if (frames.size() == 3) {
    HMW_EXPECT(Pixel(frames[1], 3, 3) ==
               std::vector<uint8_t>({0, 0, 0, 0}));
    HMW_EXPECT(Pixel(frames[2], 1, 1) ==
               std::vector<uint8_t>({0, 0, 0, 0}));
    HMW_EXPECT(Pixel(frames[2], 2, 2) ==
               std::vector<uint8_t>({0, 0, 0, 0}));
    HMW_EXPECT(Pixel(frames[2], 0, 0) ==
               std::vector<uint8_t>({0, 0, 255, 255}));
  }

  const hmw::Outcome seek = (*opened.value)->Seek(1500000);
  HMW_EXPECT(seek.ok());
  hmw::RgbaFrame sought{};
  const hmw::Result<bool> read = (*opened.value)->ReadNext(&sought);
  HMW_EXPECT(read.ok() && *read.value);
  if (read.ok() && *read.value) {
    HMW_EXPECT(sought.pts_100ns == 1500000);
    HMW_EXPECT(Pixel(sought, 0, 0) ==
               std::vector<uint8_t>({0, 0, 255, 255}));
  }
}

HMW_TEST(wic_media_gif_disposal_restores_opaque_logical_background) {
  hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenGifSource(BackgroundFixturePath());
  HMW_EXPECT(opened.ok());
  if (!opened.ok()) {
    return;
  }

  const std::vector<hmw::RgbaFrame> frames = ReadAll(opened.value->get());
  HMW_EXPECT(frames.size() == 3);
  if (frames.size() == 3) {
    HMW_EXPECT(Pixel(frames[1], 1, 1) ==
               std::vector<uint8_t>({10, 20, 30, 255}));
  }
}

HMW_TEST(wic_media_gif_invalid_background_index_falls_back_to_transparent) {
  std::vector<uint8_t> malformed = ReadFile(BackgroundFixturePath());
  HMW_EXPECT(malformed.size() > 11);
  if (malformed.size() <= 11) {
    return;
  }
  malformed[11] = 7;  // Four-entry global table: index 7 is invalid.
  const TemporaryFile file(".gif", malformed);
  hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenGifSource(file.path());
  HMW_EXPECT(opened.ok());
  if (!opened.ok()) {
    return;
  }

  const std::vector<hmw::RgbaFrame> frames = ReadAll(opened.value->get());
  HMW_EXPECT(frames.size() == 3);
  if (frames.size() == 3) {
    HMW_EXPECT(Pixel(frames[1], 1, 1) ==
               std::vector<uint8_t>({0, 0, 0, 0}));
  }
}

HMW_TEST(wic_media_gif_decodes_frame_local_palette) {
  hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenGifSource(BackgroundFixturePath());
  HMW_EXPECT(opened.ok());
  if (!opened.ok()) {
    return;
  }

  const std::vector<hmw::RgbaFrame> frames = ReadAll(opened.value->get());
  HMW_EXPECT(frames.size() == 3);
  if (frames.size() == 3) {
    HMW_EXPECT(Pixel(frames[1], 0, 0) ==
               std::vector<uint8_t>({255, 0, 255, 255}));
  }
}

HMW_TEST(wic_media_gif_keep_preserves_pixels_for_next_frame) {
  hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenGifSource(BackgroundFixturePath());
  HMW_EXPECT(opened.ok());
  if (!opened.ok()) {
    return;
  }

  const std::vector<hmw::RgbaFrame> frames = ReadAll(opened.value->get());
  HMW_EXPECT(frames.size() == 3);
  if (frames.size() == 3) {
    HMW_EXPECT(Pixel(frames[2], 0, 0) ==
               std::vector<uint8_t>({255, 0, 255, 255}));
    HMW_EXPECT(Pixel(frames[2], 2, 0) ==
               std::vector<uint8_t>({0, 0, 255, 255}));
  }
}

HMW_TEST(wic_media_gif_seek_end_and_invalid_contract) {
  hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenGifSource(FixturePath());
  HMW_EXPECT(opened.ok());
  if (!opened.ok()) {
    return;
  }

  hmw::RgbaFrame frame{};
  const int64_t total_duration = (*opened.value)->info().duration_100ns;
  HMW_EXPECT((*opened.value)->Seek(total_duration).ok());
  hmw::Result<bool> read = (*opened.value)->ReadNext(&frame);
  HMW_EXPECT(read.ok() && !*read.value);

  HMW_EXPECT((*opened.value)->Seek(total_duration + 1).ok());
  read = (*opened.value)->ReadNext(&frame);
  HMW_EXPECT(read.ok() && !*read.value);

  const hmw::Outcome negative = (*opened.value)->Seek(-1);
  HMW_EXPECT(!negative.ok());
  HMW_EXPECT(negative.error.has_value());
  if (negative.error.has_value()) {
    HMW_EXPECT(negative.error->status == hmw::Status::kInvalidArgument);
  }
}

HMW_TEST(wic_media_gif_missing_delay_uses_bounded_fallback) {
  const std::vector<uint8_t> without_delay{
      'G', 'I', 'F', '8', '9', 'a', 1, 0, 1, 0, 0x80, 0, 0,
      0, 0, 0, 255, 255, 255, 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0,
      2, 2, 0x44, 0x01, 0, 0x3b,
  };
  const TemporaryFile file(".gif", without_delay);

  hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenGifSource(file.path());
  HMW_EXPECT(opened.ok());
  if (!opened.ok()) {
    return;
  }
  HMW_EXPECT((*opened.value)->info().duration_100ns == 1000000);
  hmw::RgbaFrame frame{};
  const hmw::Result<bool> read = (*opened.value)->ReadNext(&frame);
  HMW_EXPECT(read.ok() && *read.value);
  if (read.ok() && *read.value) {
    HMW_EXPECT(frame.duration_100ns == 1000000);
  }
}

HMW_TEST(wic_media_gif_zero_delay_uses_fallback) {
  HMW_EXPECT(GifDuration(SinglePixelGifWithDelay(0)) == 1000000);
}

HMW_TEST(wic_media_gif_delay_is_clamped_to_ten_ms_through_ten_seconds) {
  HMW_EXPECT(hmw::internal::NormalizeGifDelay100ns(50000) == 100000);
  HMW_EXPECT(GifDuration(SinglePixelGifWithDelay(1)) == 100000);
  HMW_EXPECT(GifDuration(SinglePixelGifWithDelay(2000)) == 100000000);
}

HMW_TEST(wic_media_wic_rejects_non_gif_without_partial_frames) {
  const hmw::RgbaFrame original{1, 1, 0, 0, {1, 2, 3, 4}};
  const hmw::Result<std::vector<uint8_t>> encoded = hmw::EncodePng(original);
  HMW_EXPECT(encoded.ok());
  if (!encoded.ok()) {
    return;
  }
  const TemporaryFile file(".png", *encoded.value);

  const hmw::Result<std::unique_ptr<hmw::FrameSource>> opened =
      hmw::OpenGifSource(file.path());
  HMW_EXPECT(!opened.ok());
  HMW_EXPECT(!opened.value.has_value());
  HMW_EXPECT(opened.error.has_value());
  if (opened.error.has_value()) {
    HMW_EXPECT(opened.error->status == hmw::Status::kUnsupportedMedia);
  }
}
