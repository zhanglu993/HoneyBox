#include "honey_camera_windows/camera_preview.h"
#include "honey_media_windows/rgba_transform.h"
#include "media_foundation_camera_internal.h"

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

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
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
  const uint64_t left =
      static_cast<uint64_t>(lhs.fps_numerator) * rhs.fps_denominator;
  const uint64_t right =
      static_cast<uint64_t>(rhs.fps_numerator) * lhs.fps_denominator;
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

std::vector<CaptureMode> RankCaptureModes(
    const std::vector<CaptureMode>& candidates,
    const CameraPreviewConfig& requested) {
  std::vector<CaptureMode> ranked;
  for (const CaptureMode& candidate : candidates) {
    if (ValidMode(candidate)) {
      ranked.push_back(candidate);
    }
  }
  std::stable_sort(ranked.begin(), ranked.end(),
                   [&](const CaptureMode& lhs, const CaptureMode& rhs) {
                     const bool lhs_covers = lhs.width >= requested.width &&
                                             lhs.height >= requested.height &&
                                             FpsAtLeast(lhs, requested.fps);
                     const bool rhs_covers = rhs.width >= requested.width &&
                                             rhs.height >= requested.height &&
                                             FpsAtLeast(rhs, requested.fps);
                     return lhs_covers != rhs_covers
                                ? lhs_covers
                                : (lhs_covers ? BetterCoveringMode(lhs, rhs)
                                              : BetterFallbackMode(lhs, rhs));
                   });
  return ranked;
}

}  // namespace

std::optional<CaptureMode> SelectCaptureMode(
    const std::vector<CaptureMode>& candidates,
    const CameraPreviewConfig& requested) {
  if (requested.width == 0 || requested.height == 0 || requested.fps == 0) {
    return std::nullopt;
  }
  const std::vector<CaptureMode> ranked =
      RankCaptureModes(candidates, requested);
  return ranked.empty() ? std::nullopt
                        : std::optional<CaptureMode>(ranked.front());
}

std::optional<CaptureMode> SelectNegotiatedCaptureMode(
    const std::vector<CaptureMode>& candidates,
    const CameraPreviewConfig& requested,
    const CaptureModeNegotiator& negotiate) {
  if (!negotiate || requested.width == 0 || requested.height == 0 ||
      requested.fps == 0) {
    return std::nullopt;
  }
  for (const CaptureMode& candidate : RankCaptureModes(candidates, requested)) {
    if (negotiate(candidate)) {
      return candidate;
    }
  }
  return std::nullopt;
}

std::string FormatHresultDetail(std::string_view context, uint32_t result) {
  constexpr size_t kMaximumContext = 120;
  char message[160]{};
  const int context_length =
      static_cast<int>(std::min(context.size(), kMaximumContext));
  std::snprintf(message, sizeof(message), "%.*s (HRESULT 0x%08X)",
                context_length, context.data(), result);
  return message;
}

AsyncFlushBarrier::Generation AsyncFlushBarrier::Arm() noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  const Generation generation = ++next_generation_;
  active_generation_ = generation;
  return generation;
}

void AsyncFlushBarrier::Complete() noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  if (active_generation_ == 0) {
    return;
  }
  completed_generation_ = active_generation_;
  active_generation_ = 0;
  condition_.notify_all();
}

void AsyncFlushBarrier::Cancel(Generation generation) noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  if (active_generation_ == generation) {
    active_generation_ = 0;
  }
  if (generation > cancelled_generation_) {
    cancelled_generation_ = generation;
  }
  condition_.notify_all();
}

void AsyncFlushBarrier::Wait(Generation generation) noexcept {
  std::unique_lock<std::mutex> lock(mutex_);
  condition_.wait(lock, [this, generation] {
    return completed_generation_ >= generation ||
           cancelled_generation_ >= generation;
  });
}

hmw::Result<std::vector<uint8_t>> CopyBgraRows(const BgraBufferView& view,
                                               uint32_t width,
                                               uint32_t height) {
  size_t row_bytes = 0;
  if (!CheckedMultiply(static_cast<size_t>(width), static_cast<size_t>(4),
                       &row_bytes) ||
      view.buffer_start == nullptr || view.scanline_zero == nullptr ||
      width == 0 || height == 0 || view.pitch == 0) {
    return Failure<std::vector<uint8_t>>(hmw::Status::kIoError,
                                         "camera BGRA frame layout is invalid");
  }
  const uint64_t pitch_magnitude =
      view.pitch < 0 ? static_cast<uint64_t>(-(view.pitch + 1)) + 1U
                     : static_cast<uint64_t>(view.pitch);
  if (height > 1U && pitch_magnitude > (std::numeric_limits<uint64_t>::max)() /
                                           static_cast<uint64_t>(height - 1U)) {
    return Failure<std::vector<uint8_t>>(
        hmw::Status::kIoError, "camera BGRA frame dimensions are too large");
  }
  const uint64_t row_offset =
      pitch_magnitude * static_cast<uint64_t>(height - 1U);
  const uintptr_t buffer_start = reinterpret_cast<uintptr_t>(view.buffer_start);
  const uintptr_t scanline_zero =
      reinterpret_cast<uintptr_t>(view.scanline_zero);
  const bool buffer_end_overflows =
      view.buffer_length >
      (std::numeric_limits<uintptr_t>::max)() - buffer_start;
  const uintptr_t buffer_end =
      buffer_end_overflows ? 0 : buffer_start + view.buffer_length;
  const bool row_address_overflows =
      view.pitch > 0
          ? row_offset > (std::numeric_limits<uintptr_t>::max)() - scanline_zero
          : row_offset > scanline_zero;
  const uintptr_t lowest_row =
      row_address_overflows
          ? 0
          : (view.pitch > 0 ? scanline_zero : scanline_zero - row_offset);
  const uintptr_t highest_row =
      row_address_overflows
          ? 0
          : (view.pitch > 0 ? scanline_zero + row_offset : scanline_zero);
  if (pitch_magnitude < row_bytes ||
      row_offset >
          static_cast<uint64_t>((std::numeric_limits<ptrdiff_t>::max)()) ||
      buffer_end_overflows || row_address_overflows ||
      lowest_row < buffer_start || highest_row > buffer_end ||
      row_bytes > buffer_end - highest_row) {
    return Failure<std::vector<uint8_t>>(
        hmw::Status::kIoError, "camera BGRA frame buffer is too short");
  }
  size_t output_bytes = 0;
  if (!CheckedMultiply(row_bytes, static_cast<size_t>(height), &output_bytes)) {
    return Failure<std::vector<uint8_t>>(
        hmw::Status::kIoError, "camera BGRA frame dimensions are too large");
  }
  try {
    std::vector<uint8_t> output(output_bytes);
    for (uint32_t row = 0; row < height; ++row) {
      const ptrdiff_t offset = static_cast<ptrdiff_t>(row) * view.pitch;
      std::memcpy(output.data() + static_cast<size_t>(row) * row_bytes,
                  view.scanline_zero + offset, row_bytes);
    }
    return hmw::Result<std::vector<uint8_t>>{std::move(output), std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<std::vector<uint8_t>>(hmw::Status::kIoError,
                                         "camera BGRA frame allocation failed");
  }
}

hmw::Result<hmw::RgbaFrame> BgraToRgba(uint32_t width, uint32_t height,
                                       int64_t pts_100ns,
                                       const std::vector<uint8_t>& bgra) {
  size_t byte_count = 0;
  if (!PixelByteCount(width, height, &byte_count) ||
      bgra.size() != byte_count) {
    return Failure<hmw::RgbaFrame>(hmw::Status::kIoError,
                                   "camera BGRA pixels are not tightly packed");
  }
  try {
    std::vector<uint8_t> rgba(byte_count);
    for (size_t offset = 0; offset < byte_count; offset += 4) {
      rgba[offset] = bgra[offset + 2];
      rgba[offset + 1] = bgra[offset + 1];
      rgba[offset + 2] = bgra[offset];
      rgba[offset + 3] = 255;
    }
    return hmw::Result<hmw::RgbaFrame>{
        hmw::RgbaFrame{width, height, pts_100ns, 0, std::move(rgba)},
        std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<hmw::RgbaFrame>(hmw::Status::kIoError,
                                   "camera RGBA frame allocation failed");
  }
}

hmw::Result<CameraFrame> PrepareCameraTextureFrame(
    uint32_t source_width, uint32_t source_height, int64_t pts_100ns,
    const std::vector<uint8_t>& bgra,
    const CameraPreviewConfig& requested) {
  hmw::Result<hmw::RgbaFrame> rgba =
      BgraToRgba(source_width, source_height, pts_100ns, bgra);
  if (!rgba.ok()) {
    return hmw::Result<CameraFrame>{std::nullopt, std::move(rgba.error)};
  }
  hmw::Result<hmw::RgbaFrame> transformed = hmw::TransformRgba(
      *rgba.value, hmw::TransformRequest{
                       requested.width, requested.height,
                       hmw::FitMode::kCover, std::nullopt, 0xff000000U, 0});
  if (!transformed.ok()) {
    return hmw::Result<CameraFrame>{std::nullopt,
                                    std::move(transformed.error)};
  }
  try {
    std::shared_ptr<const std::vector<uint8_t>> snapshot =
        std::make_shared<const std::vector<uint8_t>>(
            std::move(transformed.value->pixels));
    return hmw::Result<CameraFrame>{
        CameraFrame{requested.width, requested.height, pts_100ns,
                    std::move(snapshot)},
        std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<CameraFrame>(hmw::Status::kIoError,
                                "camera RGBA snapshot allocation failed");
  }
}

}  // namespace hcw::internal

namespace hcw {
namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kAllStreams = static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
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

class MediaFoundationRuntime final {
 public:
  MediaFoundationRuntime() = default;
  ~MediaFoundationRuntime() {
    if (started_) {
      MFShutdown();
    }
  }

  MediaFoundationRuntime(const MediaFoundationRuntime&) = delete;
  MediaFoundationRuntime& operator=(const MediaFoundationRuntime&) = delete;

  MediaFoundationRuntime(MediaFoundationRuntime&& other) noexcept
      : started_(std::exchange(other.started_, false)) {}
  MediaFoundationRuntime& operator=(MediaFoundationRuntime&& other) noexcept {
    if (this != &other) {
      if (started_) {
        MFShutdown();
      }
      started_ = std::exchange(other.started_, false);
    }
    return *this;
  }

  HRESULT Start() {
    const HRESULT result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    started_ = SUCCEEDED(result);
    return result;
  }

 private:
  bool started_ = false;
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

class Scoped2DBuffer2Lock final {
 public:
  explicit Scoped2DBuffer2Lock(IMF2DBuffer2* buffer) : buffer_(buffer) {}
  ~Scoped2DBuffer2Lock() {
    if (locked_) {
      buffer_->Unlock2D();
    }
  }

  HRESULT Lock() {
    const HRESULT result =
        buffer_->Lock2DSize(MF2DBuffer_LockFlags_Read, &scanline_zero_, &pitch_,
                            &buffer_start_, &buffer_length_);
    locked_ = SUCCEEDED(result);
    return result;
  }

  internal::BgraBufferView view() const {
    return {buffer_start_, buffer_length_, scanline_zero_, pitch_};
  }

 private:
  IMF2DBuffer2* buffer_;
  BYTE* scanline_zero_ = nullptr;
  LONG pitch_ = 0;
  BYTE* buffer_start_ = nullptr;
  DWORD buffer_length_ = 0;
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
  return hmw::Result<T>{
      std::nullopt,
      hmw::Error{status, internal::FormatHresultDetail(
                             context, static_cast<uint32_t>(result))}};
}

hmw::Result<std::vector<uint8_t>> CopySampleBgra(IMFMediaBuffer* buffer,
                                                 uint32_t width,
                                                 uint32_t height,
                                                 LONG default_stride) {
  ComPtr<IMF2DBuffer2> buffer_2d_2;
  if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&buffer_2d_2)))) {
    Scoped2DBuffer2Lock lock(buffer_2d_2.Get());
    const HRESULT result = lock.Lock();
    if (FAILED(result)) {
      return HresultFailure<std::vector<uint8_t>>(
          result, hmw::Status::kIoError, "camera 2D sample buffer lock failed");
    }
    return internal::CopyBgraRows(lock.view(), width, height);
  }

  ComPtr<IMF2DBuffer> buffer_2d;
  if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&buffer_2d)))) {
    Scoped2DBufferLock lock(buffer_2d.Get());
    const HRESULT result = lock.Lock();
    if (FAILED(result)) {
      return HresultFailure<std::vector<uint8_t>>(
          result, hmw::Status::kIoError, "camera 2D sample buffer lock failed");
    }
    if (width == 0 || height == 0 || lock.pitch() == 0) {
      return Failure<std::vector<uint8_t>>(
          hmw::Status::kIoError, "camera 2D sample layout is invalid");
    }
    const uint64_t pitch_magnitude =
        lock.pitch() < 0
            ? static_cast<uint64_t>(-static_cast<int64_t>(lock.pitch()))
            : static_cast<uint64_t>(lock.pitch());
    const uint64_t row_count = static_cast<uint64_t>(height - 1U);
    if (row_count != 0 &&
        pitch_magnitude > (std::numeric_limits<uint64_t>::max)() / row_count) {
      return Failure<std::vector<uint8_t>>(
          hmw::Status::kIoError, "camera 2D sample dimensions are too large");
    }
    const uint64_t row_offset = pitch_magnitude * row_count;
    const uint64_t row_bytes = static_cast<uint64_t>(width) * 4U;
    if (row_bytes > (std::numeric_limits<size_t>::max)() ||
        row_offset >
            static_cast<uint64_t>((std::numeric_limits<ptrdiff_t>::max)()) ||
        row_offset > (std::numeric_limits<size_t>::max)() - row_bytes) {
      return Failure<std::vector<uint8_t>>(
          hmw::Status::kIoError, "camera 2D sample dimensions are too large");
    }
    const uintptr_t scanline_address =
        reinterpret_cast<uintptr_t>(lock.scanline_zero());
    if (lock.pitch() < 0 && row_offset > scanline_address) {
      return Failure<std::vector<uint8_t>>(
          hmw::Status::kIoError, "camera 2D sample address is invalid");
    }
    const uintptr_t buffer_start_address =
        lock.pitch() < 0 ? scanline_address - row_offset : scanline_address;
    const uint8_t* buffer_start =
        reinterpret_cast<const uint8_t*>(buffer_start_address);
    return internal::CopyBgraRows(
        internal::BgraBufferView{buffer_start,
                                 static_cast<size_t>(row_offset + row_bytes),
                                 lock.scanline_zero(), lock.pitch()},
        width, height);
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
      return Failure<std::vector<uint8_t>>(hmw::Status::kIoError,
                                           "camera sample stride is invalid");
    }
    scanline_zero += static_cast<size_t>(offset);
  }
  return internal::CopyBgraRows(
      internal::BgraBufferView{lock.data(), lock.length(), scanline_zero,
                               default_stride},
      width, height);
}

struct AsyncReadCompletion {
  HRESULT status = S_OK;
  DWORD flags = 0;
  LONGLONG timestamp = 0;
  ComPtr<IMFSample> sample;
};

class AsyncReadState final {
 public:
  using FlushGeneration = internal::AsyncFlushBarrier::Generation;

  bool BeginRead() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) {
      return false;
    }
    completion_.reset();
    return true;
  }

  void Complete(HRESULT status, DWORD flags, LONGLONG timestamp,
                IMFSample* sample) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) {
      return;
    }
    AsyncReadCompletion completion;
    completion.status = status;
    completion.flags = flags;
    completion.timestamp = timestamp;
    completion.sample = sample;
    completion_ = std::move(completion);
    condition_.notify_all();
  }

  bool Wait(AsyncReadCompletion* completion) {
    std::unique_lock<std::mutex> lock(mutex_);
    condition_.wait(lock,
                    [this] { return stopped_ || completion_.has_value(); });
    if (stopped_) {
      return false;
    }
    *completion = std::move(*completion_);
    completion_.reset();
    return true;
  }

  void Stop() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    stopped_ = true;
    condition_.notify_all();
  }

  void ReleaseCompletedSampleOnWorker() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    completion_.reset();
  }

  FlushGeneration ArmFlush() noexcept { return flush_barrier_.Arm(); }

  void CompleteFlush() noexcept { flush_barrier_.Complete(); }

  void CancelFlush(FlushGeneration generation) noexcept {
    flush_barrier_.Cancel(generation);
  }

  void WaitForFlush(FlushGeneration generation) noexcept {
    flush_barrier_.Wait(generation);
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  std::optional<AsyncReadCompletion> completion_;
  bool stopped_ = false;
  internal::AsyncFlushBarrier flush_barrier_;
};

class SourceReaderCallback final : public IMFSourceReaderCallback {
 public:
  explicit SourceReaderCallback(std::shared_ptr<AsyncReadState> state)
      : state_(std::move(state)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID interface_id,
                                           void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    if (interface_id == IID_IUnknown ||
        interface_id == __uuidof(IMFSourceReaderCallback)) {
      *object = static_cast<IMFSourceReaderCallback*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return references_.fetch_add(1, std::memory_order_relaxed) + 1;
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG remaining =
        references_.fetch_sub(1, std::memory_order_acq_rel) - 1;
    if (remaining == 0) {
      delete this;
    }
    return remaining;
  }

  HRESULT STDMETHODCALLTYPE OnReadSample(HRESULT status, DWORD, DWORD flags,
                                         LONGLONG timestamp,
                                         IMFSample* sample) override {
    state_->Complete(status, flags, timestamp, sample);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnEvent(DWORD, IMFMediaEvent*) override {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnFlush(DWORD) override {
    state_->CompleteFlush();
    return S_OK;
  }

 private:
  std::atomic<ULONG> references_{1};
  std::shared_ptr<AsyncReadState> state_;
};

class MediaFoundationCameraSource final : public CameraFrameSource {
 public:
  MediaFoundationCameraSource(
      std::unique_ptr<ComApartment> apartment, MediaFoundationRuntime runtime,
      ComPtr<IMFMediaSource> media_source, ComPtr<IMFSourceReader> reader,
      ComPtr<IMFSourceReaderCallback> callback,
      std::shared_ptr<AsyncReadState> read_state, CameraPreviewConfig requested,
      uint32_t source_width, uint32_t source_height, LONG default_stride)
      : apartment_(std::move(apartment)),
        runtime_(std::move(runtime)),
        media_source_(std::move(media_source)),
        reader_(std::move(reader)),
        callback_(std::move(callback)),
        read_state_(std::move(read_state)),
        requested_(requested),
        source_width_(source_width),
        source_height_(source_height),
        default_stride_(default_stride) {}

  ~MediaFoundationCameraSource() override = default;

  hmw::Result<CameraFrame> ReadNext() override {
    for (;;) {
      if (!read_state_->BeginRead()) {
        return Failure<CameraFrame>(hmw::Status::kCancelled,
                                    "camera capture stopped");
      }
      const HRESULT read_result = reader_->ReadSample(
          kVideoStream, 0, nullptr, nullptr, nullptr, nullptr);
      if (FAILED(read_result)) {
        const hmw::Status read_status =
            read_result == E_ACCESSDENIED ||
                    read_result == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)
                ? hmw::Status::kPermissionDenied
                : (IsDeviceLost(read_result) ? hmw::Status::kDeviceLost
                                             : hmw::Status::kIoError);
        return HresultFailure<CameraFrame>(read_result, read_status,
                                           "camera sample read failed");
      }
      AsyncReadCompletion completion;
      if (!read_state_->Wait(&completion)) {
        return Failure<CameraFrame>(hmw::Status::kCancelled,
                                    "camera capture stopped");
      }
      if (FAILED(completion.status)) {
        const hmw::Status read_status =
            completion.status == E_ACCESSDENIED ||
                    completion.status == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)
                ? hmw::Status::kPermissionDenied
                : (IsDeviceLost(completion.status) ? hmw::Status::kDeviceLost
                                                   : hmw::Status::kIoError);
        return HresultFailure<CameraFrame>(completion.status, read_status,
                                           "camera sample read failed");
      }
      const DWORD flags = completion.flags;
      const LONGLONG timestamp = completion.timestamp;
      ComPtr<IMFSample> sample = std::move(completion.sample);

      if ((flags & MF_SOURCE_READERF_ERROR) != 0 ||
          (flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0 ||
          (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0) {
        return Failure<CameraFrame>(hmw::Status::kDeviceLost,
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
        return hmw::Result<CameraFrame>{std::nullopt, std::move(copied.error)};
      }
      return internal::PrepareCameraTextureFrame(
          source_width_, source_height_, timestamp, *copied.value,
          requested_);
    }
  }

  void RequestStop() noexcept override { read_state_->Stop(); }

  void TeardownOnWorker() noexcept override {
    if (teardown_completed_) {
      return;
    }
    teardown_completed_ = true;
    read_state_->Stop();
    if (reader_) {
      const AsyncReadState::FlushGeneration generation =
          read_state_->ArmFlush();
      const HRESULT result = reader_->Flush(kVideoStream);
      if (SUCCEEDED(result)) {
        read_state_->WaitForFlush(generation);
      } else {
        read_state_->CancelFlush(generation);
      }
    }
    read_state_->ReleaseCompletedSampleOnWorker();
    reader_.Reset();
    if (media_source_) {
      (void)media_source_->Shutdown();
    }
    media_source_.Reset();
    callback_.Reset();
    runtime_ = MediaFoundationRuntime{};
    apartment_.reset();
  }

 private:
  std::unique_ptr<ComApartment> apartment_;
  MediaFoundationRuntime runtime_;
  ComPtr<IMFMediaSource> media_source_;
  ComPtr<IMFSourceReader> reader_;
  ComPtr<IMFSourceReaderCallback> callback_;
  std::shared_ptr<AsyncReadState> read_state_;
  CameraPreviewConfig requested_;
  uint32_t source_width_;
  uint32_t source_height_;
  LONG default_stride_;
  bool teardown_completed_ = false;
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
    MediaFoundationRuntime runtime;
    HRESULT result = runtime.Start();
    if (FAILED(result)) {
      return HresultFailure<std::unique_ptr<CameraFrameSource>>(
          result, hmw::Status::kIoError,
          "camera Media Foundation initialization failed");
    }

    ComPtr<IMFAttributes> attributes;
    result = MFCreateAttributes(&attributes, 2);
    if (SUCCEEDED(result)) {
      result =
          attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
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

    auto read_state = std::make_shared<AsyncReadState>();
    ComPtr<SourceReaderCallback> callback;
    callback.Attach(new (std::nothrow) SourceReaderCallback(read_state));
    if (!callback) {
      return Failure<std::unique_ptr<CameraFrameSource>>(
          hmw::Status::kIoError,
          "camera source reader callback allocation failed");
    }

    ComPtr<IMFAttributes> reader_attributes;
    result = MFCreateAttributes(&reader_attributes, 2);
    if (SUCCEEDED(result)) {
      result = reader_attributes->SetUINT32(
          MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    }
    if (SUCCEEDED(result)) {
      result = reader_attributes->SetUnknown(MF_SOURCE_READER_ASYNC_CALLBACK,
                                             callback.Get());
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
      result =
          reader->GetNativeMediaType(kVideoStream, native_index, &native_type);
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
                                        &fps_numerator, &fps_denominator))) {
        candidates.push_back(internal::CaptureMode{
            width, height, fps_numerator, fps_denominator, native_index});
      }
    }
    UINT32 output_width = 0;
    UINT32 output_height = 0;
    LONG default_stride = 0;
    HRESULT last_negotiation_result = MF_E_INVALIDMEDIATYPE;
    const std::optional<internal::CaptureMode> selected =
        internal::SelectNegotiatedCaptureMode(
            candidates, requested, [&](const internal::CaptureMode& candidate) {
              ComPtr<IMFMediaType> native_type;
              result = reader->GetNativeMediaType(
                  kVideoStream, candidate.native_type_index, &native_type);
              if (SUCCEEDED(result)) {
                result = reader->SetCurrentMediaType(kVideoStream, nullptr,
                                                     native_type.Get());
              }
              ComPtr<IMFMediaType> requested_type;
              if (SUCCEEDED(result)) {
                result = MFCreateMediaType(&requested_type);
              }
              if (SUCCEEDED(result)) {
                result = requested_type->SetGUID(MF_MT_MAJOR_TYPE,
                                                 MFMediaType_Video);
              }
              if (SUCCEEDED(result)) {
                result =
                    requested_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
              }
              if (SUCCEEDED(result)) {
                result =
                    MFSetAttributeSize(requested_type.Get(), MF_MT_FRAME_SIZE,
                                       candidate.width, candidate.height);
              }
              if (SUCCEEDED(result)) {
                result = MFSetAttributeRatio(
                    requested_type.Get(), MF_MT_FRAME_RATE,
                    candidate.fps_numerator, candidate.fps_denominator);
              }
              if (SUCCEEDED(result)) {
                result = reader->SetCurrentMediaType(kVideoStream, nullptr,
                                                     requested_type.Get());
              }
              ComPtr<IMFMediaType> output_type;
              if (SUCCEEDED(result)) {
                result =
                    reader->GetCurrentMediaType(kVideoStream, &output_type);
              }
              GUID output_subtype{};
              if (SUCCEEDED(result)) {
                result = output_type->GetGUID(MF_MT_SUBTYPE, &output_subtype);
              }
              if (SUCCEEDED(result) && output_subtype != MFVideoFormat_RGB32) {
                result = MF_E_INVALIDMEDIATYPE;
              }
              UINT32 candidate_width = 0;
              UINT32 candidate_height = 0;
              if (SUCCEEDED(result)) {
                result =
                    MFGetAttributeSize(output_type.Get(), MF_MT_FRAME_SIZE,
                                       &candidate_width, &candidate_height);
              }
              LONG candidate_stride = 0;
              UINT32 stride_bits = 0;
              if (SUCCEEDED(result)) {
                result =
                    output_type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_bits);
                if (result == MF_E_ATTRIBUTENOTFOUND) {
                  result = MFGetStrideForBitmapInfoHeader(
                      MFVideoFormat_RGB32.Data1, candidate_width,
                      &candidate_stride);
                } else if (SUCCEEDED(result)) {
                  candidate_stride = static_cast<LONG>(stride_bits);
                }
              }
              if (SUCCEEDED(result) && candidate_width != 0 &&
                  candidate_height != 0 && candidate_stride != 0) {
                output_width = candidate_width;
                output_height = candidate_height;
                default_stride = candidate_stride;
                return true;
              }
              last_negotiation_result =
                  FAILED(result) ? result : MF_E_INVALIDMEDIATYPE;
              return false;
            });

    if (!selected) {
      return HresultFailure<std::unique_ptr<CameraFrameSource>>(
          last_negotiation_result, OpenFailureStatus(last_negotiation_result),
          "camera RGB32 media type negotiation failed");
    }

    std::unique_ptr<CameraFrameSource> source =
        std::make_unique<MediaFoundationCameraSource>(
            std::move(apartment), std::move(runtime), std::move(media_source),
            std::move(reader), ComPtr<IMFSourceReaderCallback>(callback),
            std::move(read_state), requested, output_width, output_height,
            default_stride);
    source_shutdown.Disarm();
    return hmw::Result<std::unique_ptr<CameraFrameSource>>{std::move(source),
                                                           std::nullopt};
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
