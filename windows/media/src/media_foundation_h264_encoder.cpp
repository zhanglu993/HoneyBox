#include "media_foundation_h264_encoder.h"

#include "h264_annex_b.h"
#include "media_foundation_runtime.h"
#include "rgba_nv12.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <icodecapi.h>
#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <objbase.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

namespace hmw::internal {
namespace {

using Microsoft::WRL::ComPtr;

template <typename T>
Result<T> Failure(Status status, const char* message) {
  return {std::nullopt, Error{status, message}};
}

Outcome Failure(Status status, const char* message) {
  return {Error{status, message}};
}

Error HresultError(Status status, const char* context, HRESULT result) {
  char message[192]{};
  std::snprintf(message, sizeof(message), "%s (HRESULT 0x%08lX)", context,
                static_cast<unsigned long>(result));
  return {status, message};
}

class ComApartment final {
 public:
  HRESULT Initialize() {
    if (active_) {
      return S_OK;
    }
    result_ = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (result_ == RPC_E_CHANGED_MODE) {
      result_ = S_OK;
      owns_initialization_ = false;
    } else if (SUCCEEDED(result_)) {
      owns_initialization_ = true;
    }
    active_ = SUCCEEDED(result_);
    if (active_) {
      owner_thread_ = std::this_thread::get_id();
    }
    return result_;
  }

  void Reset() {
    if (active_ && owner_thread_ != std::this_thread::get_id()) {
      return;
    }
    if (owns_initialization_) {
      CoUninitialize();
    }
    active_ = false;
    owns_initialization_ = false;
    result_ = E_FAIL;
    owner_thread_ = {};
  }

  void Abandon() {
    active_ = false;
    owns_initialization_ = false;
    result_ = E_FAIL;
    owner_thread_ = {};
  }

  ~ComApartment() { Reset(); }

 private:
  HRESULT result_ = E_FAIL;
  bool active_ = false;
  bool owns_initialization_ = false;
  std::thread::id owner_thread_{};
};

class ActivateArray final {
 public:
  ~ActivateArray() { Reset(); }

  IMFActivate*** put() { return &values_; }
  UINT32* count_put() { return &count_; }
  IMFActivate* operator[](UINT32 index) const { return values_[index]; }
  UINT32 count() const { return count_; }

 private:
  void Reset() {
    for (UINT32 i = 0; i < count_; ++i) {
      if (values_[i] != nullptr) {
        values_[i]->Release();
      }
    }
    CoTaskMemFree(values_);
    values_ = nullptr;
    count_ = 0;
  }

  IMFActivate** values_ = nullptr;
  UINT32 count_ = 0;
};

class BufferLock final {
 public:
  explicit BufferLock(IMFMediaBuffer* buffer) : buffer_(buffer) {}
  ~BufferLock() {
    if (data_ != nullptr) {
      buffer_->Unlock();
    }
  }

  HRESULT Lock() { return buffer_->Lock(&data_, &maximum_, &length_); }
  uint8_t* data() const { return data_; }
  DWORD length() const { return length_; }

 private:
  IMFMediaBuffer* buffer_;
  BYTE* data_ = nullptr;
  DWORD maximum_ = 0;
  DWORD length_ = 0;
};

bool CheckedNv12Size(uint32_t width, uint32_t height, DWORD* byte_count) {
  const uint64_t pixels = static_cast<uint64_t>(width) * height;
  const uint64_t bytes = pixels + pixels / 2U;
  if (pixels == 0U || bytes > (std::numeric_limits<DWORD>::max)()) {
    return false;
  }
  *byte_count = static_cast<DWORD>(bytes);
  return true;
}

bool StartsWithAnnexB(const std::vector<uint8_t>& bytes) {
  return bytes.size() >= 3U && bytes[0] == 0U && bytes[1] == 0U &&
         (bytes[2] == 1U ||
          (bytes.size() >= 4U && bytes[2] == 0U && bytes[3] == 1U));
}

size_t StartCodeSizeAt(const std::vector<uint8_t>& bytes, size_t position) {
  if (position > bytes.size()) {
    return 0U;
  }
  const size_t remaining = bytes.size() - position;
  if (remaining >= 4U && bytes[position] == 0U &&
      bytes[position + 1U] == 0U && bytes[position + 2U] == 0U &&
      bytes[position + 3U] == 1U) {
    return 4U;
  }
  if (remaining >= 3U && bytes[position] == 0U &&
      bytes[position + 1U] == 0U && bytes[position + 2U] == 1U) {
    return 3U;
  }
  return 0U;
}

bool ContainsNalType(const std::vector<uint8_t>& bytes, uint8_t type) {
  for (size_t i = 0U; i < bytes.size(); ++i) {
    const size_t start_code = StartCodeSizeAt(bytes, i);
    if (start_code != 0U && i + start_code < bytes.size() &&
        (bytes[i + start_code] & 0x1fU) == type) {
      return true;
    }
  }
  return false;
}

bool CacheAnnexBParameterSets(
    const std::vector<uint8_t>& header,
    std::vector<std::vector<uint8_t>>* sps,
    std::vector<std::vector<uint8_t>>* pps) {
  if (!StartsWithAnnexB(header)) {
    return false;
  }
  size_t position = 0U;
  while (position < header.size()) {
    const size_t start_code = StartCodeSizeAt(header, position);
    if (start_code == 0U) {
      return false;
    }
    const size_t nal_start = position + start_code;
    if (nal_start >= header.size()) {
      return false;
    }
    size_t nal_end = nal_start;
    while (nal_end < header.size() &&
           StartCodeSizeAt(header, nal_end) == 0U) {
      ++nal_end;
    }
    const uint8_t type = header[nal_start] & 0x1fU;
    if (type == 7U || type == 8U) {
      std::vector<uint8_t> nal(
          header.begin() + static_cast<std::ptrdiff_t>(nal_start),
          header.begin() + static_cast<std::ptrdiff_t>(nal_end));
      (type == 7U ? *sps : *pps).push_back(std::move(nal));
    }
    position = nal_end;
  }
  return !sps->empty() && !pps->empty();
}

void PrependParameterSets(const std::vector<std::vector<uint8_t>>& sets,
                          std::vector<uint8_t>* bytes) {
  std::vector<uint8_t> prefixed;
  size_t prefix_size = 0U;
  for (const auto& set : sets) {
    prefix_size += 4U + set.size();
  }
  prefixed.reserve(prefix_size + bytes->size());
  for (const auto& set : sets) {
    prefixed.insert(prefixed.end(), {0U, 0U, 0U, 1U});
    prefixed.insert(prefixed.end(), set.begin(), set.end());
  }
  prefixed.insert(prefixed.end(), bytes->begin(), bytes->end());
  *bytes = std::move(prefixed);
}

HRESULT SetCodecU32(ICodecAPI* codec_api, const GUID& property,
                    uint32_t value) {
  HRESULT result = codec_api->IsSupported(&property);
  if (result != S_OK) {
    return FAILED(result) ? result : E_NOINTERFACE;
  }
  result = codec_api->IsModifiable(&property);
  // The Microsoft software "H264 Encoder MFT" does not implement this query
  // yet accepts every required SetValue. E_NOTIMPL means the codec declined to
  // answer, so SetValue stays the authority; S_FALSE is an actual "not
  // modifiable now" answer and still rejects the candidate.
  if (result != S_OK && result != E_NOTIMPL) {
    return FAILED(result) ? result : E_ACCESSDENIED;
  }
  VARIANT setting;
  VariantInit(&setting);
  setting.vt = VT_UI4;
  setting.ulVal = value;
  result = codec_api->SetValue(&property, &setting);
  return result == S_OK ? S_OK
                        : (FAILED(result) ? result : E_FAIL);
}

HRESULT SetCodecBoolIfSupported(ICodecAPI* codec_api,
                                const GUID& property, bool value) {
  HRESULT result = codec_api->IsSupported(&property);
  if (result == S_FALSE || result == E_NOTIMPL) {
    return S_FALSE;
  }
  if (result != S_OK) {
    return FAILED(result) ? result : E_FAIL;
  }
  result = codec_api->IsModifiable(&property);
  if (result == S_FALSE || result == E_NOTIMPL) {
    return S_FALSE;
  }
  if (result != S_OK) {
    return FAILED(result) ? result : E_FAIL;
  }
  VARIANT setting;
  VariantInit(&setting);
  setting.vt = VT_BOOL;
  setting.boolVal = value ? VARIANT_TRUE : VARIANT_FALSE;
  result = codec_api->SetValue(&property, &setting);
  return result == S_OK ? S_OK
                        : (FAILED(result) ? result : E_FAIL);
}

class MediaFoundationH264Encoder final : public EncoderBackend {
 public:
  explicit MediaFoundationH264Encoder(
      std::shared_ptr<H264TransformProvider> provider) {
    if (provider != nullptr) {
      provider_holder_ =
          std::make_unique<std::shared_ptr<H264TransformProvider>>(
              std::move(provider));
    }
  }
  ~MediaFoundationH264Encoder() override {
    if (started_ && !IsOwnerThread()) {
      AbandonWrongThreadResources();
    } else {
      (void)Stop();
    }
  }

  Outcome Start(const EncodingConfig& config) override;
  Result<std::vector<EncodedFrame>> Encode(
      const EncoderInputFrame& frame) override;
  Outcome RequestKeyframe() override;
  Result<std::vector<EncodedFrame>> Drain() override;
  Outcome Stop() override;

 private:
  Outcome ValidateConfig(const EncodingConfig& config) const;
  bool ConfigureCandidate(IMFTransform* transform,
                          const EncodingConfig& config);
  HRESULT ConfigureCodec(IMFTransform* transform,
                         const EncodingConfig& config,
                         ICodecAPI** codec_api);
  HRESULT ConfigureMediaTypes(IMFTransform* transform,
                              const EncodingConfig& config);
  HRESULT RefreshSequenceHeader();
  Result<EncodedFrame> ConvertOutputSample(IMFSample* sample);
  Result<std::vector<EncodedFrame>> ProcessOutputs();
  HRESULT CreateInputSample(const EncoderInputFrame& frame,
                            const std::vector<uint8_t>& nv12,
                            IMFSample** sample);
  HRESULT ApplyPendingKeyframe();
  void ResetResources();
  bool IsOwnerThread() const;
  void AbandonWrongThreadResources();

  std::unique_ptr<std::shared_ptr<H264TransformProvider>>
      provider_holder_;
  ComApartment apartment_;
  std::unique_ptr<std::shared_ptr<MediaFoundationRuntime>>
      runtime_holder_;
  ComPtr<IMFTransform> transform_;
  ComPtr<ICodecAPI> codec_api_;
  H264AnnexBNormalizer normalizer_;
  std::vector<std::vector<uint8_t>> annex_b_sps_;
  std::vector<std::vector<uint8_t>> annex_b_pps_;
  EncodingConfig config_{};
  DWORD input_stream_id_ = 0U;
  DWORD output_stream_id_ = 0U;
  bool started_ = false;
  bool drained_ = false;
  bool force_keyframe_ = false;
  bool sequence_header_cached_ = false;
  std::thread::id owner_thread_{};
  bool owner_thread_set_ = false;
};

}  // namespace

Outcome MediaFoundationH264Encoder::ValidateConfig(
    const EncodingConfig& config) const {
  DWORD nv12_size = 0U;
  const uint64_t gop =
      static_cast<uint64_t>(config.fps) * config.i_frame_interval_sec;
  if (config.format != EncoderFormat::kH264 || config.width == 0U ||
      config.height == 0U || (config.width & 1U) != 0U ||
      (config.height & 1U) != 0U || config.fps == 0U ||
      config.bitrate == 0U || config.i_frame_interval_sec == 0U ||
      gop > (std::numeric_limits<uint32_t>::max)() ||
      !CheckedNv12Size(config.width, config.height, &nv12_size)) {
    return Failure(Status::kInvalidArgument,
                   "H.264 encoding requires valid even dimensions, frame "
                   "rate, bitrate, and key-frame interval.");
  }
  return {};
}

HRESULT MediaFoundationH264Encoder::ConfigureCodec(
    IMFTransform* transform, const EncodingConfig& config,
    ICodecAPI** codec_api) {
  ComPtr<ICodecAPI> candidate;
  HRESULT result = transform->QueryInterface(
      __uuidof(ICodecAPI),
      reinterpret_cast<void**>(candidate.ReleaseAndGetAddressOf()));
  if (FAILED(result)) {
    return result;
  }
  result = SetCodecU32(candidate.Get(), CODECAPI_AVEncCommonRateControlMode,
                       eAVEncCommonRateControlMode_CBR);
  if (SUCCEEDED(result)) {
    result = SetCodecU32(candidate.Get(), CODECAPI_AVEncCommonMeanBitRate,
                         config.bitrate);
  }
  if (SUCCEEDED(result)) {
    result = SetCodecU32(candidate.Get(),
                         CODECAPI_AVEncMPVDefaultBPictureCount, 0U);
  }
  if (SUCCEEDED(result)) {
    result = SetCodecU32(
        candidate.Get(), CODECAPI_AVEncMPVGOPSize,
        config.fps * config.i_frame_interval_sec);
  }
  if (SUCCEEDED(result)) {
    const HRESULT low_latency = SetCodecBoolIfSupported(
        candidate.Get(), CODECAPI_AVLowLatencyMode, true);
    if (low_latency != S_OK && low_latency != S_FALSE) {
      result = FAILED(low_latency) ? low_latency : E_FAIL;
    }
  }
  if (SUCCEEDED(result)) {
    *codec_api = candidate.Detach();
  }
  return result;
}

HRESULT MediaFoundationH264Encoder::ConfigureMediaTypes(
    IMFTransform* transform, const EncodingConfig& config) {
  ComPtr<IMFMediaType> output_type;
  HRESULT result = MFCreateMediaType(&output_type);
  if (SUCCEEDED(result)) {
    result = output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  }
  if (SUCCEEDED(result)) {
    result = output_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  }
  if (SUCCEEDED(result)) {
    result = output_type->SetUINT32(MF_MT_AVG_BITRATE, config.bitrate);
  }
  if (SUCCEEDED(result)) {
    result = MFSetAttributeSize(output_type.Get(), MF_MT_FRAME_SIZE,
                                config.width, config.height);
  }
  if (SUCCEEDED(result)) {
    result = MFSetAttributeRatio(output_type.Get(), MF_MT_FRAME_RATE,
                                 config.fps, 1U);
  }
  if (SUCCEEDED(result)) {
    result = output_type->SetUINT32(
        MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  }
  if (SUCCEEDED(result)) {
    result = MFSetAttributeRatio(output_type.Get(),
                                 MF_MT_PIXEL_ASPECT_RATIO, 1U, 1U);
  }
  if (SUCCEEDED(result)) {
    result = output_type->SetUINT32(MF_MT_MPEG2_PROFILE,
                                    eAVEncH264VProfile_Base);
  }
  if (SUCCEEDED(result)) {
    result = transform->SetOutputType(output_stream_id_, output_type.Get(), 0);
  }
  if (FAILED(result)) {
    return result;
  }

  DWORD sample_size = 0U;
  if (!CheckedNv12Size(config.width, config.height, &sample_size)) {
    return E_INVALIDARG;
  }
  ComPtr<IMFMediaType> input_type;
  result = MFCreateMediaType(&input_type);
  if (SUCCEEDED(result)) {
    result = input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  }
  if (SUCCEEDED(result)) {
    result = input_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  }
  if (SUCCEEDED(result)) {
    result = MFSetAttributeSize(input_type.Get(), MF_MT_FRAME_SIZE,
                                config.width, config.height);
  }
  if (SUCCEEDED(result)) {
    result = MFSetAttributeRatio(input_type.Get(), MF_MT_FRAME_RATE,
                                 config.fps, 1U);
  }
  if (SUCCEEDED(result)) {
    result = input_type->SetUINT32(
        MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  }
  if (SUCCEEDED(result)) {
    result = MFSetAttributeRatio(input_type.Get(),
                                 MF_MT_PIXEL_ASPECT_RATIO, 1U, 1U);
  }
  if (SUCCEEDED(result)) {
    result = input_type->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE);
  }
  if (SUCCEEDED(result)) {
    result = input_type->SetUINT32(MF_MT_SAMPLE_SIZE, sample_size);
  }
  if (SUCCEEDED(result)) {
    result = transform->SetInputType(input_stream_id_, input_type.Get(), 0);
  }
  return result;
}

bool MediaFoundationH264Encoder::ConfigureCandidate(
    IMFTransform* transform, const EncodingConfig& config) {
  input_stream_id_ = 0U;
  output_stream_id_ = 0U;
  HRESULT result = transform->GetStreamIDs(
      1U, &input_stream_id_, 1U, &output_stream_id_);
  if (result == E_NOTIMPL) {
    input_stream_id_ = 0U;
    output_stream_id_ = 0U;
    result = S_OK;
  }
  ComPtr<ICodecAPI> candidate_codec;
  if (SUCCEEDED(result)) {
    result = ConfigureCodec(
        transform, config, candidate_codec.ReleaseAndGetAddressOf());
  }
  if (SUCCEEDED(result)) {
    result = ConfigureMediaTypes(transform, config);
  }
  if (FAILED(result)) {
    return false;
  }

  transform_ = transform;
  codec_api_ = std::move(candidate_codec);
  normalizer_ = H264AnnexBNormalizer{};
  annex_b_sps_.clear();
  annex_b_pps_.clear();
  sequence_header_cached_ = false;
  result = RefreshSequenceHeader();
  if (SUCCEEDED(result)) {
    result = transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  }
  if (SUCCEEDED(result)) {
    result = transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  }
  if (FAILED(result)) {
    transform_.Reset();
    codec_api_.Reset();
    return false;
  }
  return true;
}

Outcome MediaFoundationH264Encoder::Start(const EncodingConfig& config) {
  const Outcome validation = ValidateConfig(config);
  if (!validation.ok()) {
    return validation;
  }
  if (started_) {
    return Failure(Status::kInvalidState,
                   "H.264 encoder is already started.");
  }
  ResetResources();
  HRESULT result = apartment_.Initialize();
  if (FAILED(result)) {
    return {HresultError(Status::kCodecUnavailable,
                         "COM initialization for H.264 encoding failed",
                         result)};
  }
  owner_thread_ = std::this_thread::get_id();
  owner_thread_set_ = true;
  auto runtime = AcquireMediaFoundationRuntime();
  if (!runtime.ok()) {
    ResetResources();
    return Failure(Status::kCodecUnavailable,
                   "Media Foundation runtime is unavailable for H.264 "
                   "encoding.");
  }
  runtime_holder_ = std::make_unique<std::shared_ptr<MediaFoundationRuntime>>(
      std::move(*runtime.value));

  if (provider_holder_ != nullptr && *provider_holder_ != nullptr) {
    Error failure{Status::kCodecUnavailable,
                  "No injected synchronous local H.264 transform "
                  "could honor the required configuration."};
    {
      auto candidates =
          (*provider_holder_)->EnumerateSynchronousLocal();
      if (!candidates.ok()) {
        failure = candidates.error.has_value()
                      ? *candidates.error
                      : Error{Status::kCodecUnavailable,
                              "H.264 transform provider failed."};
      } else {
        for (const auto& candidate : *candidates.value) {
          if (candidate != nullptr &&
              ConfigureCandidate(candidate.get(), config)) {
            config_ = config;
            started_ = true;
            drained_ = false;
            force_keyframe_ = false;
            return {};
          }
        }
      }
    }
    ResetResources();
    return {failure};
  }

  Error failure{
      Status::kCodecUnavailable,
      "No synchronous local Media Foundation H.264 encoder "
      "could honor the required Baseline CBR configuration."};
  {
    MFT_REGISTER_TYPE_INFO input_info{MFMediaType_Video, MFVideoFormat_NV12};
    MFT_REGISTER_TYPE_INFO output_info{MFMediaType_Video, MFVideoFormat_H264};
    ActivateArray activations;
    result = MFTEnumEx(
        MFT_CATEGORY_VIDEO_ENCODER,
        MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
            MFT_ENUM_FLAG_SORTANDFILTER,
        &input_info, &output_info, activations.put(), activations.count_put());
    if (FAILED(result)) {
      failure = HresultError(
          Status::kCodecUnavailable,
          "Synchronous local H.264 encoder enumeration failed", result);
    } else {
      for (UINT32 i = 0U; i < activations.count(); ++i) {
        ComPtr<IMFTransform> candidate;
        result = activations[i]->ActivateObject(
            __uuidof(IMFTransform),
            reinterpret_cast<void**>(candidate.ReleaseAndGetAddressOf()));
        if (FAILED(result) || candidate == nullptr) {
          continue;
        }
        if (ConfigureCandidate(candidate.Get(), config)) {
          config_ = config;
          started_ = true;
          drained_ = false;
          force_keyframe_ = false;
          return {};
        }
      }
    }
  }
  ResetResources();
  return {failure};
}

HRESULT MediaFoundationH264Encoder::CreateInputSample(
    const EncoderInputFrame& frame, const std::vector<uint8_t>& nv12,
    IMFSample** sample) {
  if (nv12.size() > (std::numeric_limits<DWORD>::max)()) {
    return E_INVALIDARG;
  }
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT result =
      MFCreateMemoryBuffer(static_cast<DWORD>(nv12.size()), &buffer);
  if (SUCCEEDED(result)) {
    BufferLock lock(buffer.Get());
    result = lock.Lock();
    if (SUCCEEDED(result)) {
      std::memcpy(lock.data(), nv12.data(), nv12.size());
      result = buffer->SetCurrentLength(static_cast<DWORD>(nv12.size()));
    }
  }
  ComPtr<IMFSample> input;
  if (SUCCEEDED(result)) {
    result = MFCreateSample(&input);
  }
  if (SUCCEEDED(result)) {
    result = input->AddBuffer(buffer.Get());
  }
  if (SUCCEEDED(result)) {
    result = input->SetSampleTime(frame.pts_100ns);
  }
  if (SUCCEEDED(result)) {
    result = input->SetSampleDuration(frame.duration_100ns);
  }
  if (SUCCEEDED(result)) {
    *sample = input.Detach();
  }
  return result;
}

HRESULT MediaFoundationH264Encoder::ApplyPendingKeyframe() {
  if (!force_keyframe_) {
    return S_OK;
  }
  return SetCodecU32(codec_api_.Get(),
                     CODECAPI_AVEncVideoForceKeyFrame, 1U);
}

Result<std::vector<EncodedFrame>> MediaFoundationH264Encoder::Encode(
    const EncoderInputFrame& frame) {
  if (started_ && !IsOwnerThread()) {
    return Failure<std::vector<EncodedFrame>>(
        Status::kInvalidState,
        "H.264 encoder calls must stay on the Start thread.");
  }
  if (!started_ || transform_ == nullptr || drained_) {
    return Failure<std::vector<EncodedFrame>>(
        Status::kInvalidState, "H.264 encoder is not accepting input.");
  }
  if (frame.width != config_.width || frame.height != config_.height ||
      frame.duration_100ns <= 0) {
    return Failure<std::vector<EncodedFrame>>(
        Status::kInvalidArgument,
        "H.264 input geometry or duration does not match the session.");
  }
  auto nv12 =
      RgbaToNv12(frame.width, frame.height, frame.rgba, frame.rgba_size);
  if (!nv12.ok()) {
    return {std::nullopt, std::move(nv12.error)};
  }

  ComPtr<IMFSample> input;
  HRESULT result =
      CreateInputSample(frame, *nv12.value, input.ReleaseAndGetAddressOf());
  if (FAILED(result)) {
    return {std::nullopt,
            HresultError(Status::kEncodeFailed,
                         "H.264 input sample creation failed", result)};
  }

  std::vector<EncodedFrame> frames;
  result = ApplyPendingKeyframe();
  if (SUCCEEDED(result)) {
    result = transform_->ProcessInput(input_stream_id_, input.Get(), 0);
  }
  if (result == MF_E_NOTACCEPTING) {
    auto pending = ProcessOutputs();
    if (!pending.ok()) {
      return pending;
    }
    frames = std::move(*pending.value);
    result = ApplyPendingKeyframe();
    if (SUCCEEDED(result)) {
      result = transform_->ProcessInput(input_stream_id_, input.Get(), 0);
    }
  }
  if (FAILED(result)) {
    return {std::nullopt,
            HresultError(Status::kEncodeFailed,
                         "H.264 transform rejected the input sample", result)};
  }
  force_keyframe_ = false;

  auto output = ProcessOutputs();
  if (!output.ok()) {
    return output;
  }
  frames.insert(frames.end(),
                std::make_move_iterator(output.value->begin()),
                std::make_move_iterator(output.value->end()));
  return {std::move(frames), std::nullopt};
}

Outcome MediaFoundationH264Encoder::RequestKeyframe() {
  if (started_ && !IsOwnerThread()) {
    return Failure(Status::kInvalidState,
                   "H.264 encoder calls must stay on the Start thread.");
  }
  if (!started_ || drained_) {
    return Failure(Status::kInvalidState,
                   "H.264 encoder is not accepting key-frame requests.");
  }
  force_keyframe_ = true;
  return {};
}

HRESULT MediaFoundationH264Encoder::RefreshSequenceHeader() {
  if (sequence_header_cached_) {
    return S_OK;
  }
  ComPtr<IMFMediaType> output_type;
  HRESULT result =
      transform_->GetOutputCurrentType(output_stream_id_, &output_type);
  UINT8* blob = nullptr;
  UINT32 blob_size = 0U;
  if (SUCCEEDED(result)) {
    result = output_type->GetAllocatedBlob(
        MF_MT_MPEG_SEQUENCE_HEADER, &blob, &blob_size);
  }
  if (result == MF_E_ATTRIBUTENOTFOUND) {
    return S_OK;
  }
  if (FAILED(result)) {
    return result;
  }
  std::vector<uint8_t> header(blob, blob + blob_size);
  CoTaskMemFree(blob);
  if (header.empty()) {
    return MF_E_INVALIDMEDIATYPE;
  }

  if (header.front() == 1U) {
    const Outcome cached = normalizer_.SetSequenceHeader(header);
    if (!cached.ok()) {
      return MF_E_INVALIDMEDIATYPE;
    }
  } else {
    std::vector<std::vector<uint8_t>> sps;
    std::vector<std::vector<uint8_t>> pps;
    if (!CacheAnnexBParameterSets(header, &sps, &pps)) {
      return MF_E_INVALIDMEDIATYPE;
    }
    annex_b_sps_ = std::move(sps);
    annex_b_pps_ = std::move(pps);
  }
  sequence_header_cached_ = true;
  return S_OK;
}

Result<EncodedFrame> MediaFoundationH264Encoder::ConvertOutputSample(
    IMFSample* sample) {
  if (sample == nullptr) {
    return Failure<EncodedFrame>(Status::kEncodeFailed,
                                 "H.264 transform returned no output sample.");
  }
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT result = sample->ConvertToContiguousBuffer(&buffer);
  if (FAILED(result)) {
    return {std::nullopt,
            HresultError(Status::kEncodeFailed,
                         "H.264 output buffer conversion failed", result)};
  }
  BufferLock lock(buffer.Get());
  result = lock.Lock();
  if (FAILED(result)) {
    return {std::nullopt,
            HresultError(Status::kEncodeFailed,
                         "H.264 output buffer lock failed", result)};
  }
  std::vector<uint8_t> sample_bytes(lock.data(),
                                    lock.data() + lock.length());

  LONGLONG pts = 0;
  result = sample->GetSampleTime(&pts);
  if (FAILED(result)) {
    return {std::nullopt,
            HresultError(Status::kEncodeFailed,
                         "H.264 output timestamp is missing", result)};
  }
  UINT32 clean_point = FALSE;
  result = sample->GetUINT32(MFSampleExtension_CleanPoint, &clean_point);
  if (result == MF_E_ATTRIBUTENOTFOUND) {
    clean_point = FALSE;
    result = S_OK;
  }
  if (FAILED(result)) {
    return {std::nullopt,
            HresultError(Status::kEncodeFailed,
                         "H.264 clean-point metadata is invalid", result)};
  }
  result = RefreshSequenceHeader();
  if (FAILED(result)) {
    return {std::nullopt,
            HresultError(Status::kEncodeFailed,
                         "H.264 sequence header is invalid", result)};
  }

  auto normalized = normalizer_.Normalize(sample_bytes, clean_point != FALSE);
  if (!normalized.ok()) {
    return Failure<EncodedFrame>(Status::kEncodeFailed,
                                 "H.264 output access unit is malformed.");
  }
  if (normalized.value->key) {
    std::vector<std::vector<uint8_t>> missing;
    if (!ContainsNalType(normalized.value->bytes, 7U)) {
      missing.insert(missing.end(), annex_b_sps_.begin(),
                     annex_b_sps_.end());
    }
    if (!ContainsNalType(normalized.value->bytes, 8U)) {
      missing.insert(missing.end(), annex_b_pps_.begin(),
                     annex_b_pps_.end());
    }
    if (!missing.empty()) {
      PrependParameterSets(missing, &normalized.value->bytes);
    }
    if (!ContainsNalType(normalized.value->bytes, 7U) ||
        !ContainsNalType(normalized.value->bytes, 8U)) {
      return Failure<EncodedFrame>(
          Status::kEncodeFailed,
          "H.264 key frame is missing SPS or PPS parameter sets.");
    }
  }
  try {
    std::shared_ptr<const std::vector<uint8_t>> bytes =
        std::make_shared<const std::vector<uint8_t>>(
            std::move(normalized.value->bytes));
    return {EncodedFrame{std::move(bytes), pts, normalized.value->key},
            std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<EncodedFrame>(
        Status::kIoError, "H.264 output frame allocation failed.");
  }
}

Result<std::vector<EncodedFrame>>
MediaFoundationH264Encoder::ProcessOutputs() {
  MFT_OUTPUT_STREAM_INFO stream_info{};
  HRESULT result =
      transform_->GetOutputStreamInfo(output_stream_id_, &stream_info);
  if (FAILED(result)) {
    return {std::nullopt,
            HresultError(Status::kEncodeFailed,
                         "H.264 output stream information failed", result)};
  }
  std::vector<EncodedFrame> frames;
  for (;;) {
    const bool provides_sample =
        (stream_info.dwFlags &
         (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
          MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0U;
    ComPtr<IMFSample> caller_sample;
    if (!provides_sample) {
      if (stream_info.cbSize == 0U) {
        return Failure<std::vector<EncodedFrame>>(
            Status::kEncodeFailed,
            "H.264 transform requires a zero-sized caller buffer.");
      }
      ComPtr<IMFMediaBuffer> output_buffer;
      const DWORD alignment_mask =
          stream_info.cbAlignment == 0U ? 0U : stream_info.cbAlignment - 1U;
      result = MFCreateAlignedMemoryBuffer(
          stream_info.cbSize, alignment_mask, &output_buffer);
      if (SUCCEEDED(result)) {
        result = MFCreateSample(&caller_sample);
      }
      if (SUCCEEDED(result)) {
        result = caller_sample->AddBuffer(output_buffer.Get());
      }
      if (FAILED(result)) {
        return {std::nullopt,
                HresultError(Status::kEncodeFailed,
                             "H.264 caller output sample creation failed",
                             result)};
      }
    }

    MFT_OUTPUT_DATA_BUFFER output{};
    output.dwStreamID = output_stream_id_;
    output.pSample = caller_sample.Get();
    DWORD process_status = 0U;
    result = transform_->ProcessOutput(0U, 1U, &output, &process_status);
    if (output.pEvents != nullptr) {
      output.pEvents->Release();
      output.pEvents = nullptr;
    }
    if (result == MF_E_TRANSFORM_NEED_MORE_INPUT) {
      return {std::move(frames), std::nullopt};
    }
    if (FAILED(result)) {
      return {std::nullopt,
              HresultError(Status::kEncodeFailed,
                           "H.264 transform output processing failed",
                           result)};
    }
    if (output.pSample == nullptr) {
      return Failure<std::vector<EncodedFrame>>(
          Status::kEncodeFailed,
          "H.264 transform produced an empty output sample.");
    }

    ComPtr<IMFSample> provided_sample;
    if (caller_sample == nullptr ||
        output.pSample != caller_sample.Get()) {
      provided_sample.Attach(output.pSample);
    }
    IMFSample* produced = provided_sample != nullptr
                              ? provided_sample.Get()
                              : caller_sample.Get();
    auto frame = ConvertOutputSample(produced);
    if (!frame.ok()) {
      return {std::nullopt, std::move(frame.error)};
    }
    frames.push_back(std::move(*frame.value));
  }
}

Result<std::vector<EncodedFrame>> MediaFoundationH264Encoder::Drain() {
  if (started_ && !IsOwnerThread()) {
    return Failure<std::vector<EncodedFrame>>(
        Status::kInvalidState,
        "H.264 encoder calls must stay on the Start thread.");
  }
  if (!started_ || transform_ == nullptr) {
    return Failure<std::vector<EncodedFrame>>(
        Status::kInvalidState, "H.264 encoder is not started.");
  }
  if (drained_) {
    return {std::vector<EncodedFrame>{}, std::nullopt};
  }
  HRESULT result =
      transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
  if (SUCCEEDED(result)) {
    result = transform_->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
  }
  if (FAILED(result)) {
    return {std::nullopt,
            HresultError(Status::kEncodeFailed,
                         "H.264 transform drain command failed", result)};
  }
  drained_ = true;
  return ProcessOutputs();
}

bool MediaFoundationH264Encoder::IsOwnerThread() const {
  return owner_thread_set_ && owner_thread_ == std::this_thread::get_id();
}

void MediaFoundationH264Encoder::AbandonWrongThreadResources() {
  // Contract-violation fallback: quarantine COM/MF-owning references instead
  // of releasing them or uninitializing their apartment on the wrong thread.
  codec_api_.Detach();
  transform_.Detach();
  (void)runtime_holder_.release();
  (void)provider_holder_.release();
  normalizer_ = H264AnnexBNormalizer{};
  annex_b_sps_.clear();
  annex_b_pps_.clear();
  config_ = EncodingConfig{};
  input_stream_id_ = 0U;
  output_stream_id_ = 0U;
  started_ = false;
  drained_ = false;
  force_keyframe_ = false;
  sequence_header_cached_ = false;
  owner_thread_ = {};
  owner_thread_set_ = false;
  apartment_.Abandon();
}

void MediaFoundationH264Encoder::ResetResources() {
  codec_api_.Reset();
  transform_.Reset();
  runtime_holder_.reset();
  normalizer_ = H264AnnexBNormalizer{};
  annex_b_sps_.clear();
  annex_b_pps_.clear();
  config_ = EncodingConfig{};
  input_stream_id_ = 0U;
  output_stream_id_ = 0U;
  started_ = false;
  drained_ = false;
  force_keyframe_ = false;
  sequence_header_cached_ = false;
  apartment_.Reset();
  owner_thread_ = {};
  owner_thread_set_ = false;
}

Outcome MediaFoundationH264Encoder::Stop() {
  if (started_ && !IsOwnerThread()) {
    return Failure(Status::kInvalidState,
                   "H.264 encoder calls must stay on the Start thread.");
  }
  if (!started_) {
    ResetResources();
    return {};
  }
  HRESULT result = S_OK;
  if (transform_ != nullptr) {
    result =
        transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
  }
  ResetResources();
  if (FAILED(result)) {
    return {HresultError(Status::kEncodeFailed,
                         "H.264 transform shutdown failed", result)};
  }
  return {};
}

std::unique_ptr<EncoderBackend> CreateMediaFoundationH264Encoder() {
  return std::make_unique<MediaFoundationH264Encoder>(nullptr);
}

std::unique_ptr<EncoderBackend>
CreateMediaFoundationH264EncoderForTesting(
    std::shared_ptr<H264TransformProvider> provider) {
  return std::make_unique<MediaFoundationH264Encoder>(
      std::move(provider));
}

}  // namespace hmw::internal
