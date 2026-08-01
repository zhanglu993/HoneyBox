#include "honey_media_windows/media_source.h"

#include "media_foundation_runtime.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <objbase.h>
#include <propvarutil.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <utility>
#include <vector>

namespace hmw {
namespace {

using Microsoft::WRL::ComPtr;

constexpr int64_t kHundredNanosecondsPerSecond = 10000000;
constexpr DWORD kAllStreams =
    static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
constexpr DWORD kFirstVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

class ComApartment final {
 public:
  ComApartment() : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
  ~ComApartment() {
    if (result_ == S_OK || result_ == S_FALSE) {
      CoUninitialize();
    }
  }

  HRESULT result() const {
    return result_ == RPC_E_CHANGED_MODE ? S_OK : result_;
  }

 private:
  HRESULT result_;
};

class ScopedPropVariant final {
 public:
  ScopedPropVariant() { PropVariantInit(&value_); }
  ~ScopedPropVariant() { PropVariantClear(&value_); }

  PROPVARIANT* get() { return &value_; }
  const PROPVARIANT& value() const { return value_; }

 private:
  PROPVARIANT value_;
};

class ScopedBufferLock final {
 public:
  explicit ScopedBufferLock(IMFMediaBuffer* buffer) : buffer_(buffer) {}
  ~ScopedBufferLock() {
    if (data_ != nullptr) {
      buffer_->Unlock();
    }
  }

  HRESULT Lock() { return buffer_->Lock(&data_, &maximum_length_, &length_); }
  const uint8_t* data() const { return data_; }
  DWORD length() const { return length_; }

 private:
  IMFMediaBuffer* buffer_;
  BYTE* data_ = nullptr;
  DWORD maximum_length_ = 0;
  DWORD length_ = 0;
};

class Scoped2DBufferLock final {
 public:
  explicit Scoped2DBufferLock(IMF2DBuffer* buffer) : buffer_(buffer) {}
  ~Scoped2DBufferLock() {
    if (scanline_zero_ != nullptr) {
      buffer_->Unlock2D();
    }
  }

  HRESULT Lock() { return buffer_->Lock2D(&scanline_zero_, &pitch_); }
  const uint8_t* scanline_zero() const { return scanline_zero_; }
  LONG pitch() const { return pitch_; }

 private:
  IMF2DBuffer* buffer_;
  BYTE* scanline_zero_ = nullptr;
  LONG pitch_ = 0;
};

template <typename T>
Result<T> Failure(Status status, const char* message) {
  return Result<T>{std::nullopt, Error{status, message}};
}

Status StatusForOpenFailure(HRESULT result) {
  if (result == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
      result == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND)) {
    return Status::kNotFound;
  }
  if (result == MF_E_UNSUPPORTED_BYTESTREAM_TYPE ||
      result == MF_E_UNSUPPORTED_SCHEME || result == MF_E_INVALIDMEDIATYPE ||
      result == MF_E_INVALID_FILE_FORMAT ||
      result == MF_E_TOPO_CODEC_NOT_FOUND ||
      result == MF_E_UNSUPPORTED_REPRESENTATION ||
      result == MF_E_NO_MORE_TYPES) {
    return Status::kUnsupportedMedia;
  }
  return Status::kDecodeFailed;
}

Status StatusForReadFailure(HRESULT result) {
  if (result == MF_E_TOPO_CODEC_NOT_FOUND ||
      result == MF_E_TOPO_CANNOT_FIND_DECRYPTOR) {
    return Status::kUnsupportedMedia;
  }
  return Status::kDecodeFailed;
}

template <typename T>
Result<T> MediaFoundationFailure(HRESULT result, Status status,
                                 const char* context) {
  char message[160]{};
  std::snprintf(message, sizeof(message), "%s (HRESULT 0x%08lX)", context,
                static_cast<unsigned long>(result));
  return Failure<T>(status, message);
}

bool CheckedPixelByteCount(uint32_t width, uint32_t height,
                           size_t* byte_count) {
  if (width == 0 || height == 0 ||
      static_cast<size_t>(width) >
          std::numeric_limits<size_t>::max() / static_cast<size_t>(height)) {
    return false;
  }
  const size_t pixels = static_cast<size_t>(width) * height;
  if (pixels > std::numeric_limits<size_t>::max() / 4U) {
    return false;
  }
  *byte_count = pixels * 4U;
  return true;
}

bool IsSupportedRotation(uint32_t rotation) {
  return rotation == 0 || rotation == 90 || rotation == 180 ||
         rotation == 270;
}

HRESULT GetVisibleOrigin(IMFMediaType* media_type, uint32_t buffer_width,
                         uint32_t buffer_height, uint32_t visible_width,
                         uint32_t visible_height, uint32_t* left,
                         uint32_t* top) {
  *left = 0;
  *top = 0;
  const GUID* aperture_attributes[] = {
      &MF_MT_MINIMUM_DISPLAY_APERTURE,
      &MF_MT_GEOMETRIC_APERTURE,
      &MF_MT_PAN_SCAN_APERTURE,
  };
  for (const GUID* attribute : aperture_attributes) {
    MFVideoArea area{};
    UINT32 bytes = 0;
    const HRESULT result = media_type->GetBlob(
        *attribute, reinterpret_cast<UINT8*>(&area), sizeof(area), &bytes);
    if (result == MF_E_ATTRIBUTENOTFOUND) {
      continue;
    }
    if (FAILED(result)) {
      return result;
    }
    if (bytes != sizeof(area) || area.OffsetX.value < 0 ||
        area.OffsetY.value < 0 || area.OffsetX.fract != 0 ||
        area.OffsetY.fract != 0 || area.Area.cx <= 0 || area.Area.cy <= 0 ||
        static_cast<uint32_t>(area.Area.cx) != visible_width ||
        static_cast<uint32_t>(area.Area.cy) != visible_height) {
      return MF_E_INVALIDMEDIATYPE;
    }
    const uint32_t candidate_left =
        static_cast<uint32_t>(area.OffsetX.value);
    const uint32_t candidate_top = static_cast<uint32_t>(area.OffsetY.value);
    if (candidate_left > buffer_width || candidate_top > buffer_height ||
        visible_width > buffer_width - candidate_left ||
        visible_height > buffer_height - candidate_top) {
      return MF_E_INVALIDMEDIATYPE;
    }
    *left = candidate_left;
    *top = candidate_top;
    return S_OK;
  }
  return buffer_width == visible_width && buffer_height == visible_height
             ? S_OK
             : MF_E_INVALIDMEDIATYPE;
}

void MapRotatedPixel(uint32_t output_x, uint32_t output_y,
                     uint32_t source_width, uint32_t source_height,
                     uint32_t rotation, uint32_t* source_x,
                     uint32_t* source_y) {
  switch (rotation) {
    case 90:
      *source_x = output_y;
      *source_y = source_height - 1U - output_x;
      return;
    case 180:
      *source_x = source_width - 1U - output_x;
      *source_y = source_height - 1U - output_y;
      return;
    case 270:
      *source_x = source_width - 1U - output_y;
      *source_y = output_x;
      return;
    default:
      *source_x = output_x;
      *source_y = output_y;
      return;
  }
}

class MediaFoundationFrameSource final : public FrameSource {
 public:
  MediaFoundationFrameSource(std::unique_ptr<ComApartment> apartment,
                             std::shared_ptr<internal::MediaFoundationRuntime>
                                 runtime,
                             ComPtr<IMFSourceReader> reader, SourceInfo info,
                             uint32_t source_width, uint32_t source_height,
                             LONG default_stride, uint32_t source_rotation,
                             int64_t fallback_frame_duration)
      : apartment_(std::move(apartment)),
        runtime_(std::move(runtime)),
        reader_(std::move(reader)),
        info_(info),
        source_width_(source_width),
        source_height_(source_height),
        buffer_width_(source_width),
        buffer_height_(source_height),
        default_stride_(default_stride),
        source_rotation_(source_rotation),
        fallback_frame_duration_(fallback_frame_duration) {}

  const SourceInfo& info() const override { return info_; }

  Result<bool> ReadNext(RgbaFrame* frame) override {
    if (frame == nullptr) {
      return Failure<bool>(Status::kInvalidArgument,
                           "video output frame must not be null");
    }
    if (end_of_stream_) {
      return Result<bool>{false, std::nullopt};
    }
    for (;;) {
      DWORD actual_stream = 0;
      DWORD flags = 0;
      LONGLONG timestamp = 0;
      ComPtr<IMFSample> sample;
      const HRESULT read_result = reader_->ReadSample(
          kFirstVideoStream, 0, &actual_stream, &flags,
          &timestamp, &sample);
      if (FAILED(read_result)) {
        return MediaFoundationFailure<bool>(read_result,
                                            StatusForReadFailure(read_result),
                                            "video sample read failed");
      }
      if ((flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0) {
        Outcome refreshed = RefreshOutputFormat();
        if (!refreshed.ok()) {
          return Result<bool>{std::nullopt, std::move(refreshed.error)};
        }
      }
      if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
        end_of_stream_ = true;
        return Result<bool>{false, std::nullopt};
      }
      if (sample == nullptr) {
        continue;
      }

      int64_t pts = std::max<int64_t>(timestamp, 0);
      if (seek_floor_.has_value() && pts < *seek_floor_) {
        continue;
      }
      if (last_pts_ >= 0 && pts < last_pts_) {
        pts = last_pts_;
      }
      LONGLONG sample_duration = 0;
      if (FAILED(sample->GetSampleDuration(&sample_duration)) ||
          sample_duration <= 0) {
        sample_duration = fallback_frame_duration_;
      }

      Result<RgbaFrame> converted = ConvertSample(sample.Get(), pts,
                                                   sample_duration);
      if (!converted.ok()) {
        return Result<bool>{std::nullopt, std::move(converted.error)};
      }
      *frame = std::move(*converted.value);
      last_pts_ = pts;
      seek_floor_.reset();
      return Result<bool>{true, std::nullopt};
    }
  }

  Outcome Seek(int64_t pts_100ns) override {
    if (pts_100ns < 0) {
      return Outcome{Error{Status::kInvalidArgument,
                           "video seek timestamp must not be negative"}};
    }
    HRESULT result = reader_->Flush(kFirstVideoStream);
    if (FAILED(result)) {
      return Outcome{MediaFoundationFailure<bool>(
                         result, Status::kDecodeFailed,
                         "video source flush before seek failed")
                         .error};
    }
    ScopedPropVariant position;
    position.get()->vt = VT_I8;
    position.get()->hVal.QuadPart = pts_100ns;
    result = reader_->SetCurrentPosition(GUID_NULL, *position.get());
    if (FAILED(result)) {
      return Outcome{MediaFoundationFailure<bool>(
                         result, Status::kDecodeFailed,
                         "video source seek failed")
                         .error};
    }
    end_of_stream_ = false;
    last_pts_ = -1;
    seek_floor_ = pts_100ns;
    return Outcome{std::nullopt};
  }

 private:
  Outcome RefreshOutputFormat() {
    ComPtr<IMFMediaType> media_type;
    HRESULT result = reader_->GetCurrentMediaType(kFirstVideoStream,
                                                  &media_type);
    GUID subtype{};
    if (SUCCEEDED(result)) {
      result = media_type->GetGUID(MF_MT_SUBTYPE, &subtype);
    }
    uint32_t width = 0;
    uint32_t height = 0;
    if (SUCCEEDED(result)) {
      result = MFGetAttributeSize(media_type.Get(), MF_MT_FRAME_SIZE, &width,
                                  &height);
    }
    LONG stride = 0;
    if (SUCCEEDED(result)) {
      result = media_type->GetUINT32(
          MF_MT_DEFAULT_STRIDE, reinterpret_cast<UINT32*>(&stride));
      if (result == MF_E_ATTRIBUTENOTFOUND) {
        result = MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1,
                                                width, &stride);
      }
    }
    if (FAILED(result)) {
      return Outcome{MediaFoundationFailure<bool>(
                         result,
                         Status::kDecodeFailed,
                         "video output media type changed incompatibly")
                         .error};
    }
    if (subtype != MFVideoFormat_RGB32) {
      return Outcome{Error{Status::kDecodeFailed,
                           "video output subtype changed away from RGB32"}};
    }
    if (stride == 0) {
      return Outcome{Error{Status::kDecodeFailed,
                           "video output stride changed to zero"}};
    }
    uint32_t visible_left = 0;
    uint32_t visible_top = 0;
    result = GetVisibleOrigin(media_type.Get(), width, height, source_width_,
                              source_height_, &visible_left, &visible_top);
    if (FAILED(result)) {
      return Outcome{MediaFoundationFailure<bool>(
                         result, Status::kDecodeFailed,
                         "video output aperture changed incompatibly")
                         .error};
    }
    buffer_width_ = width;
    buffer_height_ = height;
    visible_left_ = visible_left;
    visible_top_ = visible_top;
    default_stride_ = stride;
    return Outcome{std::nullopt};
  }

  Result<RgbaFrame> ConvertSample(IMFSample* sample, int64_t pts,
                                  int64_t duration) const {
    ComPtr<IMFMediaBuffer> buffer;
    DWORD buffer_count = 0;
    HRESULT result = sample->GetBufferCount(&buffer_count);
    if (SUCCEEDED(result) && buffer_count == 1) {
      result = sample->GetBufferByIndex(0, &buffer);
    } else if (SUCCEEDED(result)) {
      result = sample->ConvertToContiguousBuffer(&buffer);
    }
    if (FAILED(result)) {
      return MediaFoundationFailure<RgbaFrame>(
          result, Status::kDecodeFailed,
          "video sample could not be made contiguous");
    }
    ComPtr<IMF2DBuffer> buffer_2d;
    const bool has_2d_buffer = SUCCEEDED(buffer.As(&buffer_2d));
    std::optional<Scoped2DBufferLock> lock_2d;
    std::optional<ScopedBufferLock> lock_contiguous;
    const uint8_t* contiguous_data = nullptr;
    size_t contiguous_stride = 0;
    if (has_2d_buffer) {
      lock_2d.emplace(buffer_2d.Get());
      result = lock_2d->Lock();
      const uint64_t pitch_magnitude =
          lock_2d->pitch() < 0
              ? static_cast<uint64_t>(
                    -static_cast<int64_t>(lock_2d->pitch()))
              : static_cast<uint64_t>(lock_2d->pitch());
      if (FAILED(result) ||
          pitch_magnitude < static_cast<uint64_t>(buffer_width_) * 4U) {
        return MediaFoundationFailure<RgbaFrame>(
            FAILED(result) ? result : MF_E_INVALIDMEDIATYPE,
            Status::kDecodeFailed, "video 2D sample buffer lock failed");
      }
    } else {
      lock_contiguous.emplace(buffer.Get());
      result = lock_contiguous->Lock();
      if (FAILED(result)) {
        return MediaFoundationFailure<RgbaFrame>(
            result, Status::kDecodeFailed, "video sample buffer lock failed");
      }
      const uint64_t stride_magnitude =
          default_stride_ < 0
              ? static_cast<uint64_t>(
                    -static_cast<int64_t>(default_stride_))
              : static_cast<uint64_t>(default_stride_);
      const uint64_t required = stride_magnitude * buffer_height_;
      if (stride_magnitude < static_cast<uint64_t>(buffer_width_) * 4U ||
          required > lock_contiguous->length()) {
        return Failure<RgbaFrame>(Status::kDecodeFailed,
                                  "video sample stride or size is invalid");
      }
      contiguous_data = lock_contiguous->data();
      contiguous_stride = static_cast<size_t>(stride_magnitude);
    }

    size_t byte_count = 0;
    if (!CheckedPixelByteCount(info_.width, info_.height, &byte_count)) {
      return Failure<RgbaFrame>(Status::kDecodeFailed,
                                "video output dimensions are too large");
    }
    try {
      RgbaFrame output{info_.width, info_.height, pts, duration,
                       std::vector<uint8_t>(byte_count)};
      for (uint32_t y = 0; y < info_.height; ++y) {
        for (uint32_t x = 0; x < info_.width; ++x) {
          uint32_t source_x = 0;
          uint32_t source_y = 0;
          MapRotatedPixel(x, y, source_width_, source_height_,
                          source_rotation_, &source_x, &source_y);
          source_x += visible_left_;
          source_y += visible_top_;
          const uint8_t* source_row = nullptr;
          if (lock_2d) {
            source_row = lock_2d->scanline_zero() +
                         static_cast<ptrdiff_t>(source_y) *
                             static_cast<ptrdiff_t>(lock_2d->pitch());
          } else {
            const uint32_t memory_y = default_stride_ >= 0
                                          ? source_y
                                          : buffer_height_ - 1U - source_y;
            source_row = contiguous_data +
                         static_cast<size_t>(memory_y) * contiguous_stride;
          }
          const size_t destination_offset =
              (static_cast<size_t>(y) * info_.width + x) * 4U;
          const uint8_t* bgra =
              source_row + static_cast<size_t>(source_x) * 4U;
          output.pixels[destination_offset] = bgra[2];
          output.pixels[destination_offset + 1] = bgra[1];
          output.pixels[destination_offset + 2] = bgra[0];
          output.pixels[destination_offset + 3] = 255;
        }
      }
      return Result<RgbaFrame>{std::move(output), std::nullopt};
    } catch (const std::bad_alloc&) {
      return Failure<RgbaFrame>(Status::kIoError,
                                "video frame allocation failed");
    }
  }

  std::unique_ptr<ComApartment> apartment_;
  std::shared_ptr<internal::MediaFoundationRuntime> runtime_;
  ComPtr<IMFSourceReader> reader_;
  SourceInfo info_;
  uint32_t source_width_;
  uint32_t source_height_;
  uint32_t buffer_width_;
  uint32_t buffer_height_;
  uint32_t visible_left_ = 0;
  uint32_t visible_top_ = 0;
  LONG default_stride_;
  uint32_t source_rotation_;
  int64_t fallback_frame_duration_;
  int64_t last_pts_ = -1;
  std::optional<int64_t> seek_floor_;
  bool end_of_stream_ = false;
};

HRESULT GetRotation(IMFMediaType* native_type, IMFMediaType* output_type,
                    uint32_t* rotation) {
  *rotation = 0;
  HRESULT result = native_type->GetUINT32(MF_MT_VIDEO_ROTATION, rotation);
  if (result == MF_E_ATTRIBUTENOTFOUND) {
    result = output_type->GetUINT32(MF_MT_VIDEO_ROTATION, rotation);
  }
  if (result == MF_E_ATTRIBUTENOTFOUND) {
    *rotation = 0;
    return S_OK;
  }
  return result;
}

}  // namespace

Result<std::unique_ptr<FrameSource>> OpenMediaFoundationSource(
    const std::filesystem::path& path) {
  try {
    auto apartment = std::make_unique<ComApartment>();
    if (FAILED(apartment->result())) {
      return MediaFoundationFailure<std::unique_ptr<FrameSource>>(
          apartment->result(), Status::kDecodeFailed,
          "COM initialization for video decoding failed");
    }
    Result<std::shared_ptr<internal::MediaFoundationRuntime>> runtime =
        internal::AcquireMediaFoundationRuntime();
    if (!runtime.ok()) {
      return Result<std::unique_ptr<FrameSource>>{
          std::nullopt, std::move(runtime.error)};
    }

    ComPtr<IMFAttributes> reader_attributes;
    HRESULT result = MFCreateAttributes(&reader_attributes, 1);
    if (SUCCEEDED(result)) {
      result = reader_attributes->SetUINT32(
          MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    }
    ComPtr<IMFSourceReader> reader;
    if (SUCCEEDED(result)) {
      result = MFCreateSourceReaderFromURL(path.c_str(),
                                           reader_attributes.Get(), &reader);
    }
    if (FAILED(result)) {
      return MediaFoundationFailure<std::unique_ptr<FrameSource>>(
          result, StatusForOpenFailure(result),
          "Media Foundation could not open the media source");
    }
    result = reader->SetStreamSelection(kAllStreams, FALSE);
    if (SUCCEEDED(result)) {
      result = reader->SetStreamSelection(kFirstVideoStream, TRUE);
    }
    ComPtr<IMFMediaType> native_type;
    if (SUCCEEDED(result)) {
      result = reader->GetNativeMediaType(
          kFirstVideoStream, 0, &native_type);
    }
    ComPtr<IMFMediaType> requested_type;
    if (SUCCEEDED(result)) {
      result = MFCreateMediaType(&requested_type);
    }
    if (SUCCEEDED(result)) {
      result = requested_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    }
    if (SUCCEEDED(result)) {
      result = requested_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    }
    if (SUCCEEDED(result)) {
      result = reader->SetCurrentMediaType(
          kFirstVideoStream, nullptr, requested_type.Get());
    }
    if (FAILED(result)) {
      return MediaFoundationFailure<std::unique_ptr<FrameSource>>(
          result, StatusForOpenFailure(result),
          "Media Foundation could not configure RGB32 video decoding");
    }

    ComPtr<IMFMediaType> output_type;
    result = reader->GetCurrentMediaType(kFirstVideoStream, &output_type);
    uint32_t source_width = 0;
    uint32_t source_height = 0;
    if (SUCCEEDED(result)) {
      result = MFGetAttributeSize(output_type.Get(), MF_MT_FRAME_SIZE,
                                  &source_width, &source_height);
    }
    LONG default_stride = 0;
    if (SUCCEEDED(result)) {
      result = output_type->GetUINT32(
          MF_MT_DEFAULT_STRIDE, reinterpret_cast<UINT32*>(&default_stride));
      if (result == MF_E_ATTRIBUTENOTFOUND) {
        result = MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1,
                                                source_width,
                                                &default_stride);
      }
    }
    uint32_t rotation = 0;
    if (SUCCEEDED(result)) {
      result = GetRotation(native_type.Get(), output_type.Get(), &rotation);
    }
    if (FAILED(result) || source_width == 0 || source_height == 0 ||
        default_stride == 0 || !IsSupportedRotation(rotation)) {
      return MediaFoundationFailure<std::unique_ptr<FrameSource>>(
          FAILED(result) ? result : MF_E_INVALIDMEDIATYPE,
          Status::kDecodeFailed,
          "Media Foundation returned invalid video geometry");
    }

    ScopedPropVariant duration;
    result = reader->GetPresentationAttribute(
        static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
        duration.get());
    if (FAILED(result) || duration.value().vt != VT_UI8 ||
        duration.value().uhVal.QuadPart == 0 ||
        duration.value().uhVal.QuadPart >
            static_cast<ULONGLONG>(std::numeric_limits<int64_t>::max())) {
      return MediaFoundationFailure<std::unique_ptr<FrameSource>>(
          FAILED(result) ? result : MF_E_INVALID_FILE_FORMAT,
          Status::kDecodeFailed,
          "Media Foundation returned invalid video duration");
    }

    uint32_t frame_rate_numerator = 0;
    uint32_t frame_rate_denominator = 0;
    result = MFGetAttributeRatio(output_type.Get(), MF_MT_FRAME_RATE,
                                 &frame_rate_numerator,
                                 &frame_rate_denominator);
    if (FAILED(result) || frame_rate_numerator == 0 ||
        frame_rate_denominator == 0) {
      return MediaFoundationFailure<std::unique_ptr<FrameSource>>(
          FAILED(result) ? result : MF_E_INVALIDMEDIATYPE,
          Status::kDecodeFailed,
          "Media Foundation returned invalid video frame rate");
    }

    const bool swaps_dimensions = rotation == 90 || rotation == 270;
    const uint32_t output_width =
        swaps_dimensions ? source_height : source_width;
    const uint32_t output_height =
        swaps_dimensions ? source_width : source_height;
    const double nominal_fps =
        static_cast<double>(frame_rate_numerator) / frame_rate_denominator;
    const int64_t fallback_frame_duration =
        std::max<int64_t>(
            1, static_cast<int64_t>(kHundredNanosecondsPerSecond /
                                    nominal_fps));
    const SourceInfo info{
        output_width,
        output_height,
        static_cast<int64_t>(duration.value().uhVal.QuadPart),
        nominal_fps,
        0,
        false,
    };
    std::unique_ptr<FrameSource> source =
        std::make_unique<MediaFoundationFrameSource>(
            std::move(apartment), std::move(*runtime.value),
            std::move(reader), info, source_width, source_height,
            default_stride, rotation, fallback_frame_duration);
    return Result<std::unique_ptr<FrameSource>>{std::move(source),
                                                std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<std::unique_ptr<FrameSource>>(
        Status::kIoError, "video source allocation failed");
  }
}

}  // namespace hmw
