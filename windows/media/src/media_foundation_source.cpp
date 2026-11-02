#include "honey_media_windows/media_source.h"

#include "media_foundation_runtime.h"
#include "media_foundation_source_internal.h"

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

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <utility>

namespace hmw {
namespace {

using Microsoft::WRL::ComPtr;

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
      result == MF_E_INVALIDSTREAMNUMBER ||
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

class MediaFoundationFrameSource final : public FrameSource {
 public:
  MediaFoundationFrameSource(std::shared_ptr<internal::MediaFoundationRuntime>
                                 runtime,
                             ComPtr<IMFSourceReader> reader, SourceInfo info,
                             internal::VideoLayout layout,
                             LONG default_stride)
      : runtime_(std::move(runtime)),
        reader_(std::move(reader)),
        info_(info),
        layout_(layout),
        default_stride_(default_stride) {}

  ~MediaFoundationFrameSource() override {
    ComApartment apartment;
    (void)apartment.result();
    reader_.Reset();
    runtime_.reset();
  }

  const SourceInfo& info() const override { return info_; }

  Outcome PrimeTimeline() {
    RgbaFrame first_frame{};
    Result<bool> read = ReadNext(&first_frame);
    if (!read.ok()) {
      return Outcome{std::move(read.error)};
    }
    if (*read.value) {
      pending_first_frame_ = std::move(first_frame);
    }
    return Outcome{std::nullopt};
  }

  Result<bool> ReadNext(RgbaFrame* frame) override {
    if (frame == nullptr) {
      return Failure<bool>(Status::kInvalidArgument,
                           "video output frame must not be null");
    }
    ComApartment apartment;
    if (FAILED(apartment.result())) {
      return MediaFoundationFailure<bool>(
          apartment.result(), Status::kDecodeFailed,
          "COM initialization for video reading failed");
    }
    Result<bool> before_read = read_state_.BeforeRead();
    if (!before_read.ok() || !*before_read.value) {
      return before_read;
    }
    if (pending_first_frame_.has_value()) {
      *frame = std::move(*pending_first_frame_);
      pending_first_frame_.reset();
      return Result<bool>{true, std::nullopt};
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
        Result<bool> failure = MediaFoundationFailure<bool>(
            read_result, StatusForReadFailure(read_result),
            "video sample read failed");
        read_state_.Fail(*failure.error);
        return failure;
      }
      Result<bool> observed = read_state_.ObserveFlags(flags);
      if (!observed.ok() || !*observed.value) {
        return observed;
      }
      if ((flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0) {
        Outcome refreshed = RefreshOutputFormat();
        if (!refreshed.ok()) {
          return Result<bool>{std::nullopt, std::move(refreshed.error)};
        }
      }
      if (sample == nullptr) {
        continue;
      }

      if (timeline_.IsPreroll(timestamp)) {
        continue;
      }
      Result<int64_t> pts = timeline_.AcceptTimestamp(timestamp);
      if (!pts.ok()) {
        read_state_.Fail(*pts.error);
        return Result<bool>{std::nullopt, std::move(pts.error)};
      }
      LONGLONG sample_duration = 0;
      std::optional<int64_t> reported_duration;
      if (SUCCEEDED(sample->GetSampleDuration(&sample_duration))) {
        reported_duration = sample_duration;
      }

      Result<RgbaFrame> converted = ConvertSample(
          sample.Get(), *pts.value,
          internal::NormalizeSampleDuration(reported_duration));
      if (!converted.ok()) {
        if (converted.error) {
          read_state_.Fail(*converted.error);
        }
        return Result<bool>{std::nullopt, std::move(converted.error)};
      }
      *frame = std::move(*converted.value);
      return Result<bool>{true, std::nullopt};
    }
  }

  Outcome Seek(int64_t pts_100ns) override {
    Outcome before_seek = read_state_.BeforeSeek();
    if (!before_seek.ok()) {
      return before_seek;
    }
    if (pts_100ns > info_.duration_100ns) {
      return Outcome{Error{Status::kInvalidArgument,
                           "video seek timestamp exceeds source duration"}};
    }
    Result<int64_t> raw_target = timeline_.RawSeekTarget(pts_100ns);
    if (!raw_target.ok()) {
      return Outcome{std::move(raw_target.error)};
    }
    ComApartment apartment;
    if (FAILED(apartment.result())) {
      return Outcome{MediaFoundationFailure<bool>(
                         apartment.result(), Status::kDecodeFailed,
                         "COM initialization for video seeking failed")
                         .error};
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
    position.get()->hVal.QuadPart = *raw_target.value;
    result = reader_->SetCurrentPosition(GUID_NULL, *position.get());
    if (FAILED(result)) {
      return Outcome{MediaFoundationFailure<bool>(
                         result, Status::kDecodeFailed,
                         "video source seek failed")
                         .error};
    }
    read_state_.ResetAfterSeek();
    timeline_.BeginSeek(*raw_target.value);
    pending_first_frame_.reset();
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
    Result<internal::VideoLayout> layout =
        internal::ParseVideoLayout(media_type.Get(),
                                   layout_.clockwise_rotation);
    if (!layout.ok()) {
      return Outcome{std::move(layout.error)};
    }
    LONG stride = 0;
    if (SUCCEEDED(result)) {
      result = media_type->GetUINT32(
          MF_MT_DEFAULT_STRIDE, reinterpret_cast<UINT32*>(&stride));
      if (result == MF_E_ATTRIBUTENOTFOUND) {
        result = MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1,
                                                layout.value->coded_width,
                                                &stride);
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
    if (layout.value->visible_width != layout_.visible_width ||
        layout.value->visible_height != layout_.visible_height) {
      return Outcome{Error{Status::kDecodeFailed,
                           "video visible rectangle changed unexpectedly"}};
    }
    layout_ = *layout.value;
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
          pitch_magnitude <
              static_cast<uint64_t>(layout_.coded_width) * 4U) {
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
      const uint64_t required = stride_magnitude * layout_.coded_height;
      if (stride_magnitude <
              static_cast<uint64_t>(layout_.coded_width) * 4U ||
          required > lock_contiguous->length()) {
        return Failure<RgbaFrame>(Status::kDecodeFailed,
                                  "video sample stride or size is invalid");
      }
      contiguous_data = lock_contiguous->data();
      contiguous_stride = static_cast<size_t>(stride_magnitude);
    }
    if (lock_2d) {
      return internal::ConvertBgraFrame(
          lock_2d->scanline_zero(), lock_2d->pitch(), layout_, pts, duration);
    }
    const uint8_t* scanline_zero =
        default_stride_ >= 0
            ? contiguous_data
            : contiguous_data +
                  static_cast<size_t>(layout_.coded_height - 1U) *
                      contiguous_stride;
    return internal::ConvertBgraFrame(scanline_zero, default_stride_, layout_,
                                      pts, duration);
  }

  std::shared_ptr<internal::MediaFoundationRuntime> runtime_;
  ComPtr<IMFSourceReader> reader_;
  SourceInfo info_;
  internal::VideoLayout layout_;
  LONG default_stride_;
  std::optional<RgbaFrame> pending_first_frame_;
  internal::MediaTimeline timeline_;
  internal::MediaFoundationReadState read_state_;
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
    ComApartment apartment;
    if (FAILED(apartment.result())) {
      return MediaFoundationFailure<std::unique_ptr<FrameSource>>(
          apartment.result(), Status::kDecodeFailed,
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
    uint32_t rotation = 0;
    if (SUCCEEDED(result)) {
      result = GetRotation(native_type.Get(), output_type.Get(), &rotation);
    }
    Result<internal::VideoLayout> layout =
        internal::ParseVideoLayout(output_type.Get(), rotation);
    if (!layout.ok()) {
      return Result<std::unique_ptr<FrameSource>>{
          std::nullopt, std::move(layout.error)};
    }
    LONG default_stride = 0;
    if (SUCCEEDED(result)) {
      result = output_type->GetUINT32(
          MF_MT_DEFAULT_STRIDE, reinterpret_cast<UINT32*>(&default_stride));
      if (result == MF_E_ATTRIBUTENOTFOUND) {
        result = MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1,
                                                layout.value->coded_width,
                                                &default_stride);
      }
    }
    if (FAILED(result) || default_stride == 0) {
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

    const bool swaps_dimensions = rotation == 90 || rotation == 270;
    const uint32_t output_width =
        swaps_dimensions ? layout.value->visible_height
                         : layout.value->visible_width;
    const uint32_t output_height =
        swaps_dimensions ? layout.value->visible_width
                         : layout.value->visible_height;
    const double nominal_fps =
        internal::ReadNominalFrameRate(output_type.Get());
    const SourceInfo info{
        output_width,
        output_height,
        static_cast<int64_t>(duration.value().uhVal.QuadPart),
        nominal_fps,
        0,
        false,
    };
    std::unique_ptr<MediaFoundationFrameSource> source =
        std::make_unique<MediaFoundationFrameSource>(
            std::move(*runtime.value), std::move(reader), info,
            *layout.value, default_stride);
    Outcome primed = source->PrimeTimeline();
    if (!primed.ok()) {
      return Result<std::unique_ptr<FrameSource>>{
          std::nullopt, std::move(primed.error)};
    }
    return Result<std::unique_ptr<FrameSource>>{std::move(source),
                                                std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<std::unique_ptr<FrameSource>>(
        Status::kIoError, "video source allocation failed");
  }
}

}  // namespace hmw
