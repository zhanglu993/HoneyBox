#include "honey_camera_windows/camera_preview.h"

#include "media_foundation_camera_internal.h"
#include "media_foundation_runtime.h"

#include "honey_media_windows/rgba_transform.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <objbase.h>
#include <windows.h>
#include <wrl/client.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <utility>
#include <vector>

namespace hcw::internal {
namespace {

bool CheckedMultiply(size_t lhs, size_t rhs, size_t* product) {
  if (lhs != 0 && rhs > (std::numeric_limits<size_t>::max)() / lhs) {
    return false;
  }
  *product = lhs * rhs;
  return true;
}

bool PixelByteCount(uint32_t width, uint32_t height, size_t* byte_count) {
  size_t pixels = 0;
  return CheckedMultiply(static_cast<size_t>(width),
                         static_cast<size_t>(height), &pixels) &&
         CheckedMultiply(pixels, static_cast<size_t>(4), byte_count);
}

template <typename T>
hmw::Result<T> Failure(hmw::Status status, const char* message) {
  return hmw::Result<T>{std::nullopt, hmw::Error{status, message}};
}

bool ValidMode(const CaptureMode& mode) {
  return mode.width != 0 && mode.height != 0 && mode.fps_numerator != 0 &&
         mode.fps_denominator != 0;
}

uint64_t Area(const CaptureMode& mode) {
  return static_cast<uint64_t>(mode.width) * mode.height;
}

bool FpsAtLeast(const CaptureMode& mode, uint32_t requested_fps) {
  return static_cast<uint64_t>(mode.fps_numerator) >=
         static_cast<uint64_t>(requested_fps) * mode.fps_denominator;
}

int CompareFps(const CaptureMode& lhs, const CaptureMode& rhs) {
  const uint64_t left = static_cast<uint64_t>(lhs.fps_numerator) *
                        rhs.fps_denominator;
  const uint64_t right = static_cast<uint64_t>(rhs.fps_numerator) *
                         lhs.fps_denominator;
  return left < right ? -1 : (left > right ? 1 : 0);
}

bool BetterCoveringMode(const CaptureMode& candidate,
                        const CaptureMode& current) {
  if (Area(candidate) != Area(current)) {
    return Area(candidate) < Area(current);
  }
  const int fps_comparison = CompareFps(candidate, current);
  if (fps_comparison != 0) {
    return fps_comparison < 0;
  }
  if (candidate.width != current.width) {
    return candidate.width < current.width;
  }
  if (candidate.height != current.height) {
    return candidate.height < current.height;
  }
  return candidate.native_type_index < current.native_type_index;
}

bool BetterFallbackMode(const CaptureMode& candidate,
                        const CaptureMode& current) {
  if (Area(candidate) != Area(current)) {
    return Area(candidate) > Area(current);
  }
  const int fps_comparison = CompareFps(candidate, current);
  if (fps_comparison != 0) {
    return fps_comparison > 0;
  }
  if (candidate.width != current.width) {
    return candidate.width > current.width;
  }
  if (candidate.height != current.height) {
    return candidate.height > current.height;
  }
  return candidate.native_type_index < current.native_type_index;
}

}  // namespace

std::optional<CaptureMode> SelectCaptureMode(
    const std::vector<CaptureMode>& candidates,
    const CameraPreviewConfig& requested) {
  if (requested.width == 0 || requested.height == 0 || requested.fps == 0) {
    return std::nullopt;
  }
  std::optional<CaptureMode> covering;
  std::optional<CaptureMode> fallback;
  for (const CaptureMode& candidate : candidates) {
    if (!ValidMode(candidate)) {
      continue;
    }
    if (!fallback || BetterFallbackMode(candidate, *fallback)) {
      fallback = candidate;
    }
    const bool covers = candidate.width >= requested.width &&
                        candidate.height >= requested.height &&
                        FpsAtLeast(candidate, requested.fps);
    if (covers && (!covering || BetterCoveringMode(candidate, *covering))) {
      covering = candidate;
    }
  }
  return covering ? covering : fallback;
}

hmw::Result<std::vector<uint8_t>> CopyBgraRows(
    const uint8_t* scanline_zero, size_t buffer_size, uint32_t width,
    uint32_t height, ptrdiff_t stride) {
  size_t row_bytes = 0;
  if (!CheckedMultiply(static_cast<size_t>(width), static_cast<size_t>(4),
                       &row_bytes) ||
      scanline_zero == nullptr || width == 0 || height == 0 || stride == 0) {
    return Failure<std::vector<uint8_t>>(
        hmw::Status::kIoError, "camera BGRA frame layout is invalid");
  }
  const uint64_t stride_magnitude =
      stride < 0 ? static_cast<uint64_t>(-(stride + 1)) + 1U
                 : static_cast<uint64_t>(stride);
  if (height > 1U &&
      stride_magnitude >
          (std::numeric_limits<uint64_t>::max)() /
              static_cast<uint64_t>(height - 1U)) {
    return Failure<std::vector<uint8_t>>(
        hmw::Status::kIoError, "camera BGRA frame dimensions are too large");
  }
  const uint64_t row_offset =
      stride_magnitude * static_cast<uint64_t>(height - 1U);
  const uint64_t required = row_offset + row_bytes;
  if (stride_magnitude < row_bytes ||
      row_offset >
          static_cast<uint64_t>((std::numeric_limits<ptrdiff_t>::max)()) ||
      required < row_offset || required > buffer_size) {
    return Failure<std::vector<uint8_t>>(
        hmw::Status::kIoError, "camera BGRA frame buffer is too short");
  }
  size_t output_bytes = 0;
  if (!CheckedMultiply(row_bytes, static_cast<size_t>(height),
                       &output_bytes)) {
    return Failure<std::vector<uint8_t>>(
        hmw::Status::kIoError, "camera BGRA frame dimensions are too large");
  }
  try {
    std::vector<uint8_t> output(output_bytes);
    for (uint32_t row = 0; row < height; ++row) {
      const ptrdiff_t offset = static_cast<ptrdiff_t>(row) * stride;
      std::memcpy(output.data() + static_cast<size_t>(row) * row_bytes,
                  scanline_zero + offset, row_bytes);
    }
    return hmw::Result<std::vector<uint8_t>>{std::move(output), std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<std::vector<uint8_t>>(
        hmw::Status::kIoError, "camera BGRA frame allocation failed");
  }
}

hmw::Result<hmw::RgbaFrame> BgraToRgba(
    uint32_t width, uint32_t height, int64_t pts_100ns,
    const std::vector<uint8_t>& bgra) {
  size_t byte_count = 0;
  if (!PixelByteCount(width, height, &byte_count) ||
      bgra.size() != byte_count) {
    return Failure<hmw::RgbaFrame>(
        hmw::Status::kIoError, "camera BGRA pixels are not tightly packed");
  }
  try {
    std::vector<uint8_t> rgba(byte_count);
    for (size_t offset = 0; offset < byte_count; offset += 4) {
      rgba[offset] = bgra[offset + 2];
      rgba[offset + 1] = bgra[offset + 1];
      rgba[offset + 2] = bgra[offset];
      rgba[offset + 3] = bgra[offset + 3];
    }
    return hmw::Result<hmw::RgbaFrame>{
        hmw::RgbaFrame{width, height, pts_100ns, 0, std::move(rgba)},
        std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<hmw::RgbaFrame>(
        hmw::Status::kIoError, "camera RGBA frame allocation failed");
  }
}

hmw::Result<std::vector<uint8_t>> RgbaToBgra(
    const hmw::RgbaFrame& rgba) {
  size_t byte_count = 0;
  if (!PixelByteCount(rgba.width, rgba.height, &byte_count) ||
      rgba.pixels.size() != byte_count) {
    return Failure<std::vector<uint8_t>>(
        hmw::Status::kIoError, "camera RGBA pixels are not tightly packed");
  }
  try {
    std::vector<uint8_t> bgra(byte_count);
    for (size_t offset = 0; offset < byte_count; offset += 4) {
      bgra[offset] = rgba.pixels[offset + 2];
      bgra[offset + 1] = rgba.pixels[offset + 1];
      bgra[offset + 2] = rgba.pixels[offset];
      bgra[offset + 3] = rgba.pixels[offset + 3];
    }
    return hmw::Result<std::vector<uint8_t>>{std::move(bgra), std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<std::vector<uint8_t>>(
        hmw::Status::kIoError, "camera BGRA snapshot allocation failed");
  }
}

}  // namespace hcw::internal

namespace hcw {
namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kAllStreams =
    static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
constexpr DWORD kVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

class ComApartment final {
 public:
  ComApartment() : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
  ~ComApartment() {
    if (result_ == S_OK || result_ == S_FALSE) {
      CoUninitialize();
    }
  }

  ComApartment(const ComApartment&) = delete;
  ComApartment& operator=(const ComApartment&) = delete;

  HRESULT result() const {
    return result_ == RPC_E_CHANGED_MODE ? S_OK : result_;
  }

 private:
  HRESULT result_;
};

class DeviceActivates final {
 public:
  ~DeviceActivates() {
    if (items != nullptr) {
      for (UINT32 index = 0; index < count; ++index) {
        if (items[index] != nullptr) {
          items[index]->Release();
        }
      }
    }
    CoTaskMemFree(items);
  }

  IMFActivate** items = nullptr;
  UINT32 count = 0;
};

class ScopedSourceShutdown final {
 public:
  explicit ScopedSourceShutdown(IMFMediaSource* source) : source_(source) {}
  ~ScopedSourceShutdown() {
    if (source_) {
      source_->Shutdown();
    }
  }

  ScopedSourceShutdown(const ScopedSourceShutdown&) = delete;
  ScopedSourceShutdown& operator=(const ScopedSourceShutdown&) = delete;

  void Disarm() { source_.Reset(); }

 private:
  ComPtr<IMFMediaSource> source_;
};

class ScopedBufferLock final {
 public:
  explicit ScopedBufferLock(IMFMediaBuffer* buffer) : buffer_(buffer) {}
  ~ScopedBufferLock() {
    if (locked_) {
      buffer_->Unlock();
    }
  }

  HRESULT Lock() {
    const HRESULT result = buffer_->Lock(&data_, &maximum_length_, &length_);
    locked_ = SUCCEEDED(result);
    return result;
  }
  const uint8_t* data() const { return data_; }
  DWORD length() const { return length_; }

 private:
  IMFMediaBuffer* buffer_;
  BYTE* data_ = nullptr;
  DWORD maximum_length_ = 0;
  DWORD length_ = 0;
  bool locked_ = false;
};

class Scoped2DBufferLock final {
 public:
  explicit Scoped2DBufferLock(IMF2DBuffer* buffer) : buffer_(buffer) {}
  ~Scoped2DBufferLock() {
    if (locked_) {
      buffer_->Unlock2D();
    }
  }

  HRESULT Lock() {
    const HRESULT result = buffer_->Lock2D(&scanline_zero_, &pitch_);
    locked_ = SUCCEEDED(result);
    return result;
  }
  const uint8_t* scanline_zero() const { return scanline_zero_; }
  LONG pitch() const { return pitch_; }

 private:
  IMF2DBuffer* buffer_;
  BYTE* scanline_zero_ = nullptr;
  LONG pitch_ = 0;
  bool locked_ = false;
};

template <typename T>
hmw::Result<T> Failure(hmw::Status status, const char* message) {
  return hmw::Result<T>{std::nullopt, hmw::Error{status, message}};
}

hmw::Status OpenFailureStatus(HRESULT result) {
  if (result == E_ACCESSDENIED ||
      result == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)) {
    return hmw::Status::kPermissionDenied;
  }
  return hmw::Status::kDeviceUnavailable;
}

bool IsDeviceLost(HRESULT result) {
  return result == MF_E_VIDEO_RECORDING_DEVICE_INVALIDATED ||
         result == MF_E_VIDEO_RECORDING_DEVICE_PREEMPTED ||
         result == MF_E_SHUTDOWN ||
         result == HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED) ||
         result == HRESULT_FROM_WIN32(ERROR_DEVICE_REMOVED);
}

template <typename T>
hmw::Result<T> HresultFailure(HRESULT result, hmw::Status status,
                             const char* context) {
  char message[160]{};
  std::snprintf(message, sizeof(message), "%s (HRESULT 0x%08lX)", context,
                static_cast<unsigned long>(result));
  return Failure<T>(status, message);
}

hmw::Result<std::vector<uint8_t>> CopySampleBgra(
    IMFMediaBuffer* buffer, uint32_t width, uint32_t height,
    LONG default_stride) {
  ComPtr<IMF2DBuffer> buffer_2d;
  if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&buffer_2d)))) {
    DWORD contiguous_length = 0;
    HRESULT result = buffer_2d->GetContiguousLength(&contiguous_length);
    if (FAILED(result)) {
      return HresultFailure<std::vector<uint8_t>>(
          result, hmw::Status::kIoError,
          "camera 2D buffer length query failed");
    }
    Scoped2DBufferLock lock(buffer_2d.Get());
    result = lock.Lock();
    if (FAILED(result)) {
      return HresultFailure<std::vector<uint8_t>>(
          result, hmw::Status::kIoError,
          "camera 2D sample buffer lock failed");
    }
    return internal::CopyBgraRows(
        lock.scanline_zero(), contiguous_length, width, height, lock.pitch());
  }

  ScopedBufferLock lock(buffer);
  HRESULT result = lock.Lock();
  if (FAILED(result)) {
    return HresultFailure<std::vector<uint8_t>>(
        result, hmw::Status::kIoError, "camera sample buffer lock failed");
  }
  const uint64_t stride_magnitude =
      default_stride < 0
          ? static_cast<uint64_t>(-static_cast<int64_t>(default_stride))
          : static_cast<uint64_t>(default_stride);
  const uint8_t* scanline_zero = lock.data();
  if (default_stride < 0 && height != 0) {
    const uint64_t offset = stride_magnitude * (height - 1U);
    if (offset > lock.length()) {
      return Failure<std::vector<uint8_t>>(
          hmw::Status::kIoError, "camera sample stride is invalid");
    }
    scanline_zero += static_cast<size_t>(offset);
  }
  return internal::CopyBgraRows(scanline_zero, lock.length(), width, height,
                                default_stride);
}

class MediaFoundationCameraSource final : public CameraFrameSource {
 public:
  MediaFoundationCameraSource(
      std::unique_ptr<ComApartment> apartment,
      std::shared_ptr<hmw::internal::MediaFoundationRuntime> runtime,
      ComPtr<IMFMediaSource> media_source, ComPtr<IMFSourceReader> reader,
      CameraPreviewConfig requested, uint32_t source_width,
      uint32_t source_height, LONG default_stride)
      : apartment_(std::move(apartment)),
        runtime_(std::move(runtime)),
        media_source_(std::move(media_source)),
        reader_(std::move(reader)),
        requested_(requested),
        source_width_(source_width),
        source_height_(source_height),
        default_stride_(default_stride) {}

  ~MediaFoundationCameraSource() override {
    RequestStop();
    reader_.Reset();
    if (media_source_) {
      media_source_->Shutdown();
    }
    media_source_.Reset();
    runtime_.reset();
  }

  hmw::Result<CameraFrame> ReadNext() override {
    for (;;) {
      if (stop_requested_.load(std::memory_order_acquire)) {
        return Failure<CameraFrame>(hmw::Status::kCancelled,
                                    "camera capture stopped");
      }
      DWORD actual_stream = 0;
      DWORD flags = 0;
      LONGLONG timestamp = 0;
      ComPtr<IMFSample> sample;
      const HRESULT read_result = reader_->ReadSample(
          kVideoStream, 0, &actual_stream, &flags, &timestamp, &sample);
      if (FAILED(read_result)) {
        if (stop_requested_.load(std::memory_order_acquire)) {
          return Failure<CameraFrame>(hmw::Status::kCancelled,
                                      "camera capture stopped");
        }
        const hmw::Status read_status =
            read_result == E_ACCESSDENIED ||
                    read_result == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)
                ? hmw::Status::kPermissionDenied
                : (IsDeviceLost(read_result) ? hmw::Status::kDeviceLost
                                             : hmw::Status::kIoError);
        return HresultFailure<CameraFrame>(
            read_result, read_status,
            "camera sample read failed");
      }
      if ((flags & MF_SOURCE_READERF_ERROR) != 0 ||
          (flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0 ||
          (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0) {
        return Failure<CameraFrame>(
            hmw::Status::kDeviceLost,
            "camera capture source was invalidated");
      }
      if (sample == nullptr) {
        continue;
      }

      ComPtr<IMFMediaBuffer> buffer;
      DWORD buffer_count = 0;
      HRESULT result = sample->GetBufferCount(&buffer_count);
      if (SUCCEEDED(result) && buffer_count == 1) {
        result = sample->GetBufferByIndex(0, &buffer);
      } else if (SUCCEEDED(result)) {
        result = sample->ConvertToContiguousBuffer(&buffer);
      }
      if (FAILED(result)) {
        return HresultFailure<CameraFrame>(
            result, hmw::Status::kIoError,
            "camera sample could not be made contiguous");
      }
      hmw::Result<std::vector<uint8_t>> copied = CopySampleBgra(
          buffer.Get(), source_width_, source_height_, default_stride_);
      if (!copied.ok()) {
        return hmw::Result<CameraFrame>{std::nullopt,
                                        std::move(copied.error)};
      }
      hmw::Result<hmw::RgbaFrame> rgba = internal::BgraToRgba(
          source_width_, source_height_, timestamp, *copied.value);
      if (!rgba.ok()) {
        return hmw::Result<CameraFrame>{std::nullopt, std::move(rgba.error)};
      }
      hmw::Result<hmw::RgbaFrame> transformed = hmw::TransformRgba(
          *rgba.value,
          hmw::TransformRequest{requested_.width, requested_.height,
                                hmw::FitMode::kCover, std::nullopt,
                                0xff000000U, 0});
      if (!transformed.ok()) {
        return hmw::Result<CameraFrame>{std::nullopt,
                                        std::move(transformed.error)};
      }
      hmw::Result<std::vector<uint8_t>> bgra =
          internal::RgbaToBgra(*transformed.value);
      if (!bgra.ok()) {
        return hmw::Result<CameraFrame>{std::nullopt, std::move(bgra.error)};
      }
      try {
        std::shared_ptr<const std::vector<uint8_t>> snapshot =
            std::make_shared<const std::vector<uint8_t>>(
                std::move(*bgra.value));
        return hmw::Result<CameraFrame>{
            CameraFrame{requested_.width, requested_.height, timestamp,
                        std::move(snapshot)},
            std::nullopt};
      } catch (const std::bad_alloc&) {
        return Failure<CameraFrame>(
            hmw::Status::kIoError, "camera snapshot allocation failed");
      }
    }
  }

  void RequestStop() noexcept override {
    if (stop_requested_.exchange(true, std::memory_order_acq_rel)) {
      return;
    }
    ComApartment apartment;
    if (FAILED(apartment.result())) {
      return;
    }
    if (media_source_) {
      (void)media_source_->Shutdown();
    }
    if (reader_) {
      (void)reader_->Flush(kVideoStream);
    }
  }

 private:
  std::unique_ptr<ComApartment> apartment_;
  std::shared_ptr<hmw::internal::MediaFoundationRuntime> runtime_;
  ComPtr<IMFMediaSource> media_source_;
  ComPtr<IMFSourceReader> reader_;
  CameraPreviewConfig requested_;
  uint32_t source_width_;
  uint32_t source_height_;
  LONG default_stride_;
  std::atomic<bool> stop_requested_{false};
};

hmw::Result<std::unique_ptr<CameraFrameSource>> OpenCamera(
    const CameraPreviewConfig& requested) {
  if (requested.width == 0 || requested.height == 0 || requested.fps == 0) {
    return Failure<std::unique_ptr<CameraFrameSource>>(
        hmw::Status::kInvalidArgument,
        "camera preview dimensions and fps must be positive");
  }
  try {
    auto apartment = std::make_unique<ComApartment>();
    if (FAILED(apartment->result())) {
      return HresultFailure<std::unique_ptr<CameraFrameSource>>(
          apartment->result(), hmw::Status::kIoError,
          "camera COM initialization failed");
    }
    auto runtime = hmw::internal::AcquireMediaFoundationRuntime();
    if (!runtime.ok()) {
      return Failure<std::unique_ptr<CameraFrameSource>>(
          hmw::Status::kIoError,
          "camera Media Foundation initialization failed");
    }

    ComPtr<IMFAttributes> attributes;
    HRESULT result = MFCreateAttributes(&attributes, 2);
    if (SUCCEEDED(result)) {
      result = attributes->SetGUID(
          MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
          MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    }
    DeviceActivates activates;
    if (SUCCEEDED(result)) {
      result = MFEnumDeviceSources(attributes.Get(), &activates.items,
                                   &activates.count);
    }
    if (FAILED(result)) {
      return HresultFailure<std::unique_ptr<CameraFrameSource>>(
          result, OpenFailureStatus(result),
          "camera device enumeration failed");
    }
    if (activates.count == 0 || activates.items == nullptr) {
      return Failure<std::unique_ptr<CameraFrameSource>>(
          hmw::Status::kNotFound, "no camera device was found");
    }

    ComPtr<IMFMediaSource> media_source;
    result = activates.items[0]->ActivateObject(IID_PPV_ARGS(&media_source));
    if (FAILED(result)) {
      return HresultFailure<std::unique_ptr<CameraFrameSource>>(
          result, OpenFailureStatus(result), "camera activation failed");
    }
    ScopedSourceShutdown source_shutdown(media_source.Get());

    ComPtr<IMFAttributes> reader_attributes;
    result = MFCreateAttributes(&reader_attributes, 1);
    if (SUCCEEDED(result)) {
      result = reader_attributes->SetUINT32(
          MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    }
    ComPtr<IMFSourceReader> reader;
    if (SUCCEEDED(result)) {
      result = MFCreateSourceReaderFromMediaSource(
          media_source.Get(), reader_attributes.Get(), &reader);
    }
    if (SUCCEEDED(result)) {
      result = reader->SetStreamSelection(kAllStreams, FALSE);
    }
    if (SUCCEEDED(result)) {
      result = reader->SetStreamSelection(kVideoStream, TRUE);
    }
    if (FAILED(result)) {
      return HresultFailure<std::unique_ptr<CameraFrameSource>>(
          result, OpenFailureStatus(result),
          "camera source reader creation failed");
    }

    std::vector<internal::CaptureMode> candidates;
    for (DWORD native_index = 0;; ++native_index) {
      ComPtr<IMFMediaType> native_type;
      result = reader->GetNativeMediaType(kVideoStream, native_index,
                                          &native_type);
      if (result == MF_E_NO_MORE_TYPES) {
        break;
      }
      if (FAILED(result)) {
        return HresultFailure<std::unique_ptr<CameraFrameSource>>(
            result, OpenFailureStatus(result),
            "camera native media type enumeration failed");
      }
      GUID major_type{};
      UINT32 width = 0;
      UINT32 height = 0;
      UINT32 fps_numerator = 0;
      UINT32 fps_denominator = 0;
      if (SUCCEEDED(native_type->GetGUID(MF_MT_MAJOR_TYPE, &major_type)) &&
          major_type == MFMediaType_Video &&
          SUCCEEDED(MFGetAttributeSize(native_type.Get(), MF_MT_FRAME_SIZE,
                                       &width, &height)) &&
          SUCCEEDED(MFGetAttributeRatio(native_type.Get(), MF_MT_FRAME_RATE,
                                        &fps_numerator,
                                        &fps_denominator))) {
        candidates.push_back(internal::CaptureMode{
            width, height, fps_numerator, fps_denominator, native_index});
      }
    }
    const std::optional<internal::CaptureMode> selected =
        internal::SelectCaptureMode(candidates, requested);
    if (!selected) {
      return Failure<std::unique_ptr<CameraFrameSource>>(
          hmw::Status::kDeviceUnavailable,
          "camera exposes no usable video capture mode");
    }

    ComPtr<IMFMediaType> native_type;
    result = reader->GetNativeMediaType(kVideoStream,
                                        selected->native_type_index,
                                        &native_type);
    if (SUCCEEDED(result)) {
      result = reader->SetCurrentMediaType(kVideoStream, nullptr,
                                           native_type.Get());
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
      result = MFSetAttributeSize(requested_type.Get(), MF_MT_FRAME_SIZE,
                                  selected->width, selected->height);
    }
    if (SUCCEEDED(result)) {
      result = MFSetAttributeRatio(requested_type.Get(), MF_MT_FRAME_RATE,
                                   selected->fps_numerator,
                                   selected->fps_denominator);
    }
    if (SUCCEEDED(result)) {
      result = reader->SetCurrentMediaType(kVideoStream, nullptr,
                                           requested_type.Get());
    }
    ComPtr<IMFMediaType> output_type;
    if (SUCCEEDED(result)) {
      result = reader->GetCurrentMediaType(kVideoStream, &output_type);
    }
    UINT32 output_width = 0;
    UINT32 output_height = 0;
    if (SUCCEEDED(result)) {
      result = MFGetAttributeSize(output_type.Get(), MF_MT_FRAME_SIZE,
                                  &output_width, &output_height);
    }
    LONG default_stride = 0;
    UINT32 stride_bits = 0;
    if (SUCCEEDED(result)) {
      result = output_type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_bits);
      if (result == MF_E_ATTRIBUTENOTFOUND) {
        result = MFGetStrideForBitmapInfoHeader(
            MFVideoFormat_RGB32.Data1, output_width, &default_stride);
      } else if (SUCCEEDED(result)) {
        default_stride = static_cast<LONG>(stride_bits);
      }
    }
    if (FAILED(result) || output_width == 0 || output_height == 0 ||
        default_stride == 0) {
      return HresultFailure<std::unique_ptr<CameraFrameSource>>(
          FAILED(result) ? result : MF_E_INVALIDMEDIATYPE,
          FAILED(result) ? OpenFailureStatus(result)
                         : hmw::Status::kDeviceUnavailable,
          "camera RGB32 media type negotiation failed");
    }

    std::unique_ptr<CameraFrameSource> source =
        std::make_unique<MediaFoundationCameraSource>(
            std::move(apartment), std::move(*runtime.value),
            std::move(media_source), std::move(reader), requested,
            output_width, output_height, default_stride);
    source_shutdown.Disarm();
    return hmw::Result<std::unique_ptr<CameraFrameSource>>{
        std::move(source), std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<std::unique_ptr<CameraFrameSource>>(
        hmw::Status::kIoError, "camera source allocation failed");
  }
}

}  // namespace

CameraSourceFactory CreateMediaFoundationCameraFactory() {
  return [](const CameraPreviewConfig& config) { return OpenCamera(config); };
}

}  // namespace hcw
