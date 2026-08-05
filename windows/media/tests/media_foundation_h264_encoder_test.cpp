#include "media_foundation_h264_encoder.h"

#include "test_support.h"
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <codecapi.h>
#include <icodecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mftransform.h>
#include <objbase.h>
#include <wrl/client.h>


#include <cstddef>
#include <cstdint>
#include <vector>
#include <atomic>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

namespace {

hmw::EncodingConfig H264Config(uint32_t width = 368U,
                               uint32_t height = 368U) {
  return {hmw::EncoderFormat::kH264, width, height, 15U, 150000U, 6U, 1.0,
          false, 0U, 0U, false, true};
}

struct SolidInput {
  SolidInput()
      : rgba(368U * 368U * 4U, 0x80U),
        frame{368U, 368U, 0, 10'000'000 / 15, rgba.data(), rgba.size()} {}

  std::vector<uint8_t> rgba;
  hmw::EncoderInputFrame frame;
};

bool IsAnnexB(const hmw::EncodedFrame& frame) {
  return frame.bytes && frame.bytes->size() >= 4U &&
         (*frame.bytes)[0] == 0U && (*frame.bytes)[1] == 0U &&
         (*frame.bytes)[2] == 0U && (*frame.bytes)[3] == 1U;
}

bool HasNal(const std::vector<uint8_t>& bytes, uint8_t type) {
  for (size_t i = 0U; i + 4U < bytes.size(); ++i) {
    if (bytes[i] == 0U && bytes[i + 1U] == 0U && bytes[i + 2U] == 0U &&
        bytes[i + 3U] == 1U && (bytes[i + 4U] & 0x1fU) == type) {
      return true;
    }
  }
  return false;
}

// True when this machine actually exposes a synchronous local H.264 encoder.
// Only a machine without one may skip the real-transform acceptance test; a
// present-but-rejected encoder is a real failure, not an allowed skip.
bool SystemHasSynchronousH264Encoder() {
  if (FAILED(MFStartup(MF_VERSION))) {
    return false;
  }
  MFT_REGISTER_TYPE_INFO input_info{MFMediaType_Video, MFVideoFormat_NV12};
  MFT_REGISTER_TYPE_INFO output_info{MFMediaType_Video, MFVideoFormat_H264};
  IMFActivate** activates = nullptr;
  UINT32 count = 0U;
  const HRESULT result = MFTEnumEx(
      MFT_CATEGORY_VIDEO_ENCODER,
      MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
          MFT_ENUM_FLAG_SORTANDFILTER,
      &input_info, &output_info, &activates, &count);
  if (SUCCEEDED(result) && activates != nullptr) {
    for (UINT32 i = 0U; i < count; ++i) {
      activates[i]->Release();
    }
    CoTaskMemFree(activates);
  }
  MFShutdown();
  return SUCCEEDED(result) && count != 0U;
}

}  // namespace

HMW_TEST(media_foundation_h264_encoder_rejects_odd_dimensions) {
  auto backend = hmw::internal::CreateMediaFoundationH264Encoder();
  const auto started = backend->Start(H264Config(367U, 368U));
  HMW_EXPECT(!started.ok());
  HMW_EXPECT(started.error.has_value());
  if (started.error) {
    HMW_EXPECT(started.error->status == hmw::Status::kInvalidArgument);
  }
}

HMW_TEST(media_foundation_h264_encoder_drains_annex_b_idr_before_stop) {
  const bool encoder_present = SystemHasSynchronousH264Encoder();
  auto backend = hmw::internal::CreateMediaFoundationH264Encoder();
  const auto started = backend->Start(H264Config());
  if (!encoder_present && !started.ok() && started.error &&
      started.error->status == hmw::Status::kCodecUnavailable) {
    // No synchronous local H.264 encoder exists on this machine at all.
    HMW_EXPECT(!started.error->message.empty());
    return;
  }
  // An encoder is installed, so the production configuration must be accepted.
  HMW_EXPECT(started.ok());
  if (!started.ok()) {
    if (started.error) {
      HMW_EXPECT(started.error->message.empty());
    }
    return;
  }

  HMW_EXPECT(backend->RequestKeyframe().ok());
  SolidInput input;
  auto encoded = backend->Encode(input.frame);
  HMW_EXPECT(encoded.ok());
  auto drained = backend->Drain();
  HMW_EXPECT(drained.ok());
  if (!encoded.ok() || !drained.ok()) {
    backend->Stop();
    return;
  }
  encoded.value->insert(encoded.value->end(), drained.value->begin(),
                        drained.value->end());
  HMW_EXPECT(!encoded.value->empty());
  bool found_key = false;
  for (const auto& frame : *encoded.value) {
    HMW_EXPECT(IsAnnexB(frame));
    if (frame.key && frame.bytes) {
      found_key = true;
      HMW_EXPECT(HasNal(*frame.bytes, 7U));
      HMW_EXPECT(HasNal(*frame.bytes, 8U));
      HMW_EXPECT(HasNal(*frame.bytes, 5U));
    }
  }
  HMW_EXPECT(found_key);
  HMW_EXPECT(backend->Stop().ok());
}

namespace {

using Microsoft::WRL::ComPtr;

const std::vector<uint8_t> kFakeAvccHeader = {
    1U, 66U, 0U, 30U, 0xffU, 0xe1U, 0U, 4U, 0x67U, 0x42U,
    0U, 30U, 1U, 0U, 4U, 0x68U, 0xceU, 6U, 0xe2U};
const std::vector<uint8_t> kFakeAnnexBHeader = {
    0U, 0U, 0U, 1U, 0x67U, 0x42U, 0U, 30U,
    0U, 0U, 0U, 1U, 0x68U, 0xceU, 6U, 0xe2U};

struct FakeOutput {
  std::vector<uint8_t> bytes;
  int64_t pts;
  bool clean_point;
};

class FakeH264Transform final : public IMFTransform, public ICodecAPI {
 public:
  FakeH264Transform(bool provides_samples, bool annex_b_header,
                    bool not_accept_once, bool omit_sequence_header = false)
      : provides_samples_(provides_samples),
        sequence_header_(annex_b_header ? kFakeAnnexBHeader
                                       : kFakeAvccHeader),
        not_accept_once_(not_accept_once),
        omit_sequence_header_(omit_sequence_header) {}

  void PushOutput(FakeOutput output) {
    outputs_.push_back(std::move(output));
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,
                                           void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    *object = nullptr;
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IMFTransform)) {
      *object = static_cast<IMFTransform*>(this);
    } else if (iid == __uuidof(ICodecAPI)) {
      *object = static_cast<ICodecAPI*>(this);
    } else {
      return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
  }

  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }

  ULONG STDMETHODCALLTYPE Release() override {
    ULONG_PTR context_token = 0U;
    const bool apartment_active =
        CoGetContextToken(&context_token) == S_OK;
    {
      std::lock_guard<std::mutex> lock(release_mutex_);
      release_threads_.push_back(std::this_thread::get_id());
      release_apartment_active_.push_back(apartment_active);
    }
    const ULONG references = --references_;
    if (references == 0U) {
      delete this;
    }
    return references;
  }

  HRESULT STDMETHODCALLTYPE GetStreamLimits(
      DWORD* input_minimum, DWORD* input_maximum,
      DWORD* output_minimum, DWORD* output_maximum) override {
    if (input_minimum == nullptr || input_maximum == nullptr ||
        output_minimum == nullptr || output_maximum == nullptr) {
      return E_POINTER;
    }
    *input_minimum = *input_maximum = 1U;
    *output_minimum = *output_maximum = 1U;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetStreamCount(DWORD* inputs,
                                            DWORD* outputs) override {
    if (inputs == nullptr || outputs == nullptr) {
      return E_POINTER;
    }
    *inputs = *outputs = 1U;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetStreamIDs(DWORD, DWORD*, DWORD,
                                          DWORD*) override {
    return E_NOTIMPL;
  }

  HRESULT STDMETHODCALLTYPE GetInputStreamInfo(
      DWORD, MFT_INPUT_STREAM_INFO* info) override {
    if (info == nullptr) {
      return E_POINTER;
    }
    *info = {};
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetOutputStreamInfo(
      DWORD, MFT_OUTPUT_STREAM_INFO* info) override {
    if (info == nullptr) {
      return E_POINTER;
    }
    *info = {};
    info->dwFlags = provides_samples_
                        ? MFT_OUTPUT_STREAM_PROVIDES_SAMPLES
                        : 0U;
    info->cbSize = provides_samples_ ? 0U : 1024U;
    info->cbAlignment = provides_samples_ ? 0U : 16U;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetAttributes(IMFAttributes**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetInputStreamAttributes(
      DWORD, IMFAttributes**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetOutputStreamAttributes(
      DWORD, IMFAttributes**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE DeleteInputStream(DWORD) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE AddInputStreams(DWORD, DWORD*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetInputAvailableType(
      DWORD, DWORD, IMFMediaType**) override {
    return MF_E_NO_MORE_TYPES;
  }
  HRESULT STDMETHODCALLTYPE GetOutputAvailableType(
      DWORD, DWORD, IMFMediaType**) override {
    return MF_E_NO_MORE_TYPES;
  }

  HRESULT STDMETHODCALLTYPE SetInputType(
      DWORD, IMFMediaType* type, DWORD) override {
    calls.push_back("input_type");
    input_type_ = type;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE SetOutputType(
      DWORD, IMFMediaType* type, DWORD) override {
    calls.push_back("output_type");
    if (!omit_sequence_header_) {
      const HRESULT result = type->SetBlob(
          MF_MT_MPEG_SEQUENCE_HEADER, sequence_header_.data(),
          static_cast<UINT32>(sequence_header_.size()));
      if (FAILED(result)) {
        return result;
      }
    }
    output_type_ = type;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetInputCurrentType(
      DWORD, IMFMediaType** type) override {
    return input_type_.CopyTo(type);
  }

  HRESULT STDMETHODCALLTYPE GetOutputCurrentType(
      DWORD, IMFMediaType** type) override {
    return output_type_.CopyTo(type);
  }

  HRESULT STDMETHODCALLTYPE GetInputStatus(DWORD,
                                            DWORD* flags) override {
    if (flags == nullptr) {
      return E_POINTER;
    }
    *flags = MFT_INPUT_STATUS_ACCEPT_DATA;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetOutputStatus(DWORD* flags) override {
    if (flags == nullptr) {
      return E_POINTER;
    }
    *flags = outputs_.empty() ? 0U : MFT_OUTPUT_STATUS_SAMPLE_READY;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE SetOutputBounds(
      LONGLONG, LONGLONG) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE ProcessEvent(
      DWORD, IMFMediaEvent*) override {
    return E_NOTIMPL;
  }

  HRESULT STDMETHODCALLTYPE ProcessMessage(
      MFT_MESSAGE_TYPE message, ULONG_PTR) override {
    switch (message) {
      case MFT_MESSAGE_NOTIFY_BEGIN_STREAMING:
        calls.push_back("begin_streaming");
        break;
      case MFT_MESSAGE_NOTIFY_START_OF_STREAM:
        calls.push_back("start_stream");
        break;
      case MFT_MESSAGE_NOTIFY_END_OF_STREAM:
        calls.push_back("end_of_stream");
        break;
      case MFT_MESSAGE_COMMAND_DRAIN:
        calls.push_back("drain");
        break;
      case MFT_MESSAGE_NOTIFY_END_STREAMING:
        calls.push_back("end_streaming");
        break;
      default:
        calls.push_back("message");
        break;
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE ProcessInput(
      DWORD, IMFSample* sample, DWORD) override {
    calls.push_back("input");
    ++process_input_calls;
    if (not_accept_once_ && process_input_calls == 1U) {
      return MF_E_NOTACCEPTING;
    }
    if (FAILED(sample->GetSampleTime(&last_input_pts)) ||
        FAILED(sample->GetSampleDuration(&last_input_duration))) {
      return E_FAIL;
    }
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT result = sample->ConvertToContiguousBuffer(&buffer);
    if (SUCCEEDED(result)) {
      DWORD length = 0U;
      result = buffer->GetCurrentLength(&length);
      last_input_size = length;
    }
    return result;
  }

  HRESULT STDMETHODCALLTYPE ProcessOutput(
      DWORD, DWORD output_count, MFT_OUTPUT_DATA_BUFFER* output,
      DWORD*) override {
    if (output_count != 1U || output == nullptr) {
      return E_INVALIDARG;
    }
    if (outputs_.empty()) {
      return MF_E_TRANSFORM_NEED_MORE_INPUT;
    }
    FakeOutput scripted = std::move(outputs_.front());
    outputs_.pop_front();

    ComPtr<IMFSample> provided;
    IMFSample* sample = output->pSample;
    if (provides_samples_) {
      HRESULT result = MFCreateSample(&provided);
      ComPtr<IMFMediaBuffer> buffer;
      if (SUCCEEDED(result)) {
        result = MFCreateMemoryBuffer(
            static_cast<DWORD>(scripted.bytes.size()), &buffer);
      }
      if (SUCCEEDED(result)) {
        result = provided->AddBuffer(buffer.Get());
      }
      if (FAILED(result)) {
        return result;
      }
      sample = provided.Get();
    }
    if (sample == nullptr) {
      return E_POINTER;
    }

    ComPtr<IMFMediaBuffer> buffer;
    HRESULT result = sample->GetBufferByIndex(0U, &buffer);
    BYTE* data = nullptr;
    DWORD maximum = 0U;
    DWORD current = 0U;
    if (SUCCEEDED(result)) {
      result = buffer->Lock(&data, &maximum, &current);
    }
    if (SUCCEEDED(result)) {
      last_output_address = reinterpret_cast<uintptr_t>(data);
      if (maximum < scripted.bytes.size()) {
        result = MF_E_BUFFERTOOSMALL;
      } else {
        std::copy(scripted.bytes.begin(), scripted.bytes.end(), data);
      }
      buffer->Unlock();
    }
    if (SUCCEEDED(result)) {
      result = buffer->SetCurrentLength(
          static_cast<DWORD>(scripted.bytes.size()));
    }
    if (SUCCEEDED(result)) {
      result = sample->SetSampleTime(scripted.pts);
    }
    if (SUCCEEDED(result) && scripted.clean_point) {
      result = sample->SetUINT32(MFSampleExtension_CleanPoint, TRUE);
    }
    if (FAILED(result)) {
      return result;
    }
    if (provides_samples_) {
      output->pSample = provided.Detach();
    } else {
      caller_sample_seen = true;
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE IsSupported(const GUID* property) override {
    return property != nullptr && *property == CODECAPI_AVLowLatencyMode
               ? low_latency_support
               : required_support;
  }
  HRESULT STDMETHODCALLTYPE IsModifiable(const GUID* property) override {
    return property != nullptr && *property == CODECAPI_AVLowLatencyMode
               ? low_latency_modifiable
               : required_modifiable;
  }
  HRESULT STDMETHODCALLTYPE GetParameterRange(
      const GUID*, VARIANT*, VARIANT*, VARIANT*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetParameterValues(
      const GUID*, VARIANT**, ULONG*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetDefaultValue(
      const GUID*, VARIANT*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetValue(const GUID*, VARIANT*) override {
    return E_NOTIMPL;
  }

  HRESULT STDMETHODCALLTYPE SetValue(
      const GUID* property, VARIANT* value) override {
    if (property == nullptr || value == nullptr) {
      return E_POINTER;
    }
    if (*property == CODECAPI_AVLowLatencyMode) {
      ++low_latency_set_calls;
      return low_latency_set_result;
    }
    if (required_set_result != S_OK) {
      return required_set_result;
    }
    if (*property == CODECAPI_AVEncCommonRateControlMode) {
      rate_control = value->ulVal;
    } else if (*property == CODECAPI_AVEncCommonMeanBitRate) {
      mean_bitrate = value->ulVal;
    } else if (*property == CODECAPI_AVEncMPVDefaultBPictureCount) {
      b_picture_count = value->ulVal;
    } else if (*property == CODECAPI_AVEncMPVGOPSize) {
      gop_size = value->ulVal;
    } else if (*property == CODECAPI_AVEncVideoForceKeyFrame) {
      calls.push_back("force_key");
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE RegisterForEvent(
      const GUID*, LONG_PTR) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE UnregisterForEvent(
      const GUID*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE SetAllDefaults() override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE SetValueWithNotify(
      const GUID*, VARIANT*, GUID**, ULONG*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE SetAllDefaultsWithNotify(
      GUID**, ULONG*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetAllSettings(IStream*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE SetAllSettings(IStream*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE SetAllSettingsWithNotify(
      IStream*, GUID**, ULONG*) override {
    return E_NOTIMPL;
  }

  std::vector<std::string> calls;
  uint32_t process_input_calls = 0U;
  int64_t last_input_pts = -1;
  int64_t last_input_duration = -1;
  DWORD last_input_size = 0U;
  uintptr_t last_output_address = 0U;
  bool caller_sample_seen = false;
  uint32_t rate_control = 0U;
  uint32_t mean_bitrate = 0U;
  uint32_t b_picture_count = 99U;
  uint32_t gop_size = 0U;
  HRESULT required_support = S_OK;
  HRESULT required_modifiable = S_OK;
  HRESULT required_set_result = S_OK;
  HRESULT low_latency_support = S_OK;
  HRESULT low_latency_modifiable = S_OK;
  HRESULT low_latency_set_result = S_OK;
  uint32_t low_latency_set_calls = 0U;

  size_t ReleasesOn(std::thread::id thread) {
    std::lock_guard<std::mutex> lock(release_mutex_);
    return static_cast<size_t>(std::count(release_threads_.begin(),
                                         release_threads_.end(), thread));
  }
  bool AllReleasesOnHadApartment(std::thread::id thread) {
    std::lock_guard<std::mutex> lock(release_mutex_);
    bool found = false;
    for (size_t i = 0U; i < release_threads_.size(); ++i) {
      if (release_threads_[i] != thread) {
        continue;
      }
      found = true;
      if (!release_apartment_active_[i]) {
        return false;
      }
    }
    return found;
  }

 private:
  ~FakeH264Transform() = default;

  std::atomic<ULONG> references_{1U};
  bool provides_samples_;
  std::vector<uint8_t> sequence_header_;
  bool not_accept_once_;
  bool omit_sequence_header_;
  std::deque<FakeOutput> outputs_;
  ComPtr<IMFMediaType> input_type_;
  ComPtr<IMFMediaType> output_type_;
  std::mutex release_mutex_;
  std::vector<std::thread::id> release_threads_;
  std::vector<bool> release_apartment_active_;
};

class FakeH264Provider final
    : public hmw::internal::H264TransformProvider {
 public:
  hmw::Result<std::vector<std::shared_ptr<IMFTransform>>>
  EnumerateSynchronousLocal() override {
    if (move_on_enumerate) {
      return {std::move(transforms), std::nullopt};
    }
    return {transforms, std::nullopt};
  }

  std::vector<std::shared_ptr<IMFTransform>> transforms;
  bool move_on_enumerate = false;
};

std::pair<std::shared_ptr<FakeH264Provider>, FakeH264Transform*>
FakeBackend(bool provides_samples, bool annex_b_header,
            bool not_accept_once, bool omit_sequence_header = false) {
  auto provider = std::make_shared<FakeH264Provider>();
  auto* transform =
      new FakeH264Transform(provides_samples, annex_b_header,
                            not_accept_once, omit_sequence_header);
  provider->transforms.emplace_back(
      static_cast<IMFTransform*>(transform),
      [](IMFTransform* value) { value->Release(); });
  return {std::move(provider), transform};
}

size_t CallIndex(const std::vector<std::string>& calls,
                 const char* name) {
  const auto found = std::find(calls.begin(), calls.end(), name);
  return found == calls.end()
             ? calls.size()
             : static_cast<size_t>(found - calls.begin());
}

struct ApartmentReleaseProbe {
  void Record() {
    ULONG_PTR context_token = 0U;
    released = true;
    apartment_active = CoGetContextToken(&context_token) == S_OK;
    thread = std::this_thread::get_id();
  }

  bool released = false;
  bool apartment_active = false;
  std::thread::id thread{};
};

}  // namespace

HMW_TEST(media_foundation_h264_encoder_reports_missing_provider_codec) {
  auto provider = std::make_shared<FakeH264Provider>();
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);

  const auto started = backend->Start(H264Config());

  HMW_EXPECT(!started.ok());
  HMW_EXPECT(started.error.has_value());
  if (started.error) {
    HMW_EXPECT(started.error->status == hmw::Status::kCodecUnavailable);
  }
}

HMW_TEST(media_foundation_h264_encoder_caller_buffer_preserves_contract) {
  auto [provider, transform] = FakeBackend(false, false, false);
  transform->PushOutput(
      {{0U, 0U, 0U, 3U, 0x65U, 0x88U, 0x84U}, 1'230'000, true});
  transform->PushOutput(
      {{0U, 0U, 0U, 2U, 0x41U, 0x9aU}, 1'896'666, false});
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
  HMW_EXPECT(backend->Start(H264Config()).ok());
  HMW_EXPECT(backend->RequestKeyframe().ok());
  SolidInput input;
  input.frame.pts_100ns = 1'230'000;
  input.frame.duration_100ns = 666'666;

  const auto encoded = backend->Encode(input.frame);

  HMW_EXPECT(encoded.ok());
  if (!encoded.ok()) {
    backend->Stop();
    return;
  }
  HMW_EXPECT(encoded.value->size() == 2U);
  if (encoded.value->size() == 2U) {
    HMW_EXPECT((*encoded.value)[0].pts_100ns == 1'230'000);
    HMW_EXPECT((*encoded.value)[0].key);
    HMW_EXPECT(IsAnnexB((*encoded.value)[0]));
    HMW_EXPECT(HasNal(*(*encoded.value)[0].bytes, 7U));
    HMW_EXPECT(HasNal(*(*encoded.value)[0].bytes, 8U));
    HMW_EXPECT(HasNal(*(*encoded.value)[0].bytes, 5U));
    HMW_EXPECT((*encoded.value)[1].pts_100ns == 1'896'666);
    HMW_EXPECT(!(*encoded.value)[1].key);
  }
  HMW_EXPECT(CallIndex(transform->calls, "output_type") <
             CallIndex(transform->calls, "input_type"));
  HMW_EXPECT(transform->rate_control ==
             eAVEncCommonRateControlMode_CBR);
  HMW_EXPECT(transform->mean_bitrate == 150000U);
  HMW_EXPECT(transform->b_picture_count == 0U);
  HMW_EXPECT(transform->gop_size == 90U);
  HMW_EXPECT(CallIndex(transform->calls, "force_key") + 1U ==
             CallIndex(transform->calls, "input"));
  HMW_EXPECT(transform->last_input_pts == 1'230'000);
  HMW_EXPECT(transform->last_input_duration == 666'666);
  HMW_EXPECT(transform->last_input_size == 368U * 368U * 3U / 2U);
  HMW_EXPECT(transform->caller_sample_seen);
  HMW_EXPECT(transform->last_output_address % 16U == 0U);

  const auto drained = backend->Drain();
  HMW_EXPECT(drained.ok());
  HMW_EXPECT(backend->Stop().ok());
  HMW_EXPECT(CallIndex(transform->calls, "end_of_stream") <
             CallIndex(transform->calls, "drain"));
  HMW_EXPECT(CallIndex(transform->calls, "drain") <
             CallIndex(transform->calls, "end_streaming"));
}

HMW_TEST(media_foundation_h264_encoder_retries_not_accepting_with_provided_sample) {
  auto [provider, transform] = FakeBackend(true, true, true);
  transform->PushOutput(
      {{0U, 0U, 1U, 0x65U, 0x88U, 0x84U}, 9'000'000, true});
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
  HMW_EXPECT(backend->Start(H264Config()).ok());
  SolidInput input;
  input.frame.pts_100ns = 9'000'000;
  input.frame.duration_100ns = 666'666;

  const auto encoded = backend->Encode(input.frame);

  HMW_EXPECT(encoded.ok());
  if (encoded.ok()) {
    HMW_EXPECT(encoded.value->size() == 1U);
    if (encoded.value->size() == 1U) {
      HMW_EXPECT((*encoded.value)[0].key);
      HMW_EXPECT(IsAnnexB((*encoded.value)[0]));
      HMW_EXPECT(HasNal(*(*encoded.value)[0].bytes, 7U));
      HMW_EXPECT(HasNal(*(*encoded.value)[0].bytes, 8U));
      HMW_EXPECT(HasNal(*(*encoded.value)[0].bytes, 5U));
    }
  }
  HMW_EXPECT(transform->process_input_calls == 2U);
  HMW_EXPECT(!transform->caller_sample_seen);
  HMW_EXPECT(backend->Stop().ok());
  HMW_EXPECT(CallIndex(transform->calls, "end_streaming") <
             transform->calls.size());
  HMW_EXPECT(CallIndex(transform->calls, "end_of_stream") ==
             transform->calls.size());
  HMW_EXPECT(CallIndex(transform->calls, "drain") ==
             transform->calls.size());
}

HMW_TEST(media_foundation_h264_encoder_rejects_repeated_start_deterministically) {
  auto [provider, transform] = FakeBackend(false, false, false);
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
  HMW_EXPECT(backend->Start(H264Config()).ok());

  const auto repeated = backend->Start(H264Config());

  HMW_EXPECT(!repeated.ok());
  HMW_EXPECT(repeated.error.has_value());
  if (repeated.error) {
    HMW_EXPECT(repeated.error->status == hmw::Status::kInvalidState);
  }
  HMW_EXPECT(backend->Stop().ok());
}

HMW_TEST(media_foundation_h264_encoder_requires_exact_success_for_required_properties) {
  struct Case {
    HRESULT support;
    HRESULT modifiable;
    HRESULT set;
  };
  const Case cases[] = {
      {S_FALSE, S_OK, S_OK},
      {E_NOTIMPL, S_OK, S_OK},
      {S_OK, S_FALSE, S_OK},
      {S_OK, S_OK, S_FALSE},
      {S_OK, S_OK, E_ACCESSDENIED},
  };
  for (const auto& scripted : cases) {
    auto [provider, transform] = FakeBackend(false, false, false);
    transform->required_support = scripted.support;
    transform->required_modifiable = scripted.modifiable;
    transform->required_set_result = scripted.set;
    auto backend =
        hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);

    const auto started = backend->Start(H264Config());

    HMW_EXPECT(!started.ok());
    HMW_EXPECT(started.error.has_value());
    if (started.error) {
      HMW_EXPECT(started.error->status == hmw::Status::kCodecUnavailable);
    }
  }
}

HMW_TEST(media_foundation_h264_encoder_accepts_codec_without_is_modifiable) {
  // The Microsoft software "H264 Encoder MFT" answers IsSupported with S_OK,
  // does not implement IsModifiable, and still accepts every required
  // SetValue. A codec that never implements the query must not be rejected;
  // SetValue is the authority on whether the property was applied.
  auto [provider, transform] = FakeBackend(false, false, false);
  transform->required_support = S_OK;
  transform->required_modifiable = E_NOTIMPL;
  transform->required_set_result = S_OK;
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);

  const auto started = backend->Start(H264Config());

  HMW_EXPECT(started.ok());
  if (!started.ok() && started.error) {
    HMW_EXPECT(started.error->message.empty());
  }
  HMW_EXPECT(backend->Stop().ok());
}

HMW_TEST(media_foundation_h264_encoder_still_rejects_unmodifiable_property) {
  // E_NOTIMPL means "the codec does not answer the question". S_FALSE means
  // "the codec answered: not modifiable right now", which stays a rejection.
  auto [provider, transform] = FakeBackend(false, false, false);
  transform->required_support = S_OK;
  transform->required_modifiable = S_FALSE;
  transform->required_set_result = S_OK;
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);

  const auto started = backend->Start(H264Config());

  HMW_EXPECT(!started.ok());
  if (started.error) {
    HMW_EXPECT(started.error->status == hmw::Status::kCodecUnavailable);
  }
}

HMW_TEST(media_foundation_h264_encoder_skips_unsupported_optional_low_latency) {
  struct Case {
    HRESULT support;
    HRESULT modifiable;
  };
  const Case unsupported[] = {
      {S_FALSE, S_OK}, {E_NOTIMPL, S_OK},
      {S_OK, S_FALSE}, {S_OK, E_NOTIMPL}};
  for (const auto& scripted : unsupported) {
    auto [provider, transform] = FakeBackend(false, false, false);
    transform->low_latency_support = scripted.support;
    transform->low_latency_modifiable = scripted.modifiable;
    auto backend =
        hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);

    HMW_EXPECT(backend->Start(H264Config()).ok());
    HMW_EXPECT(transform->low_latency_set_calls == 0U);
    HMW_EXPECT(backend->Stop().ok());
  }
}

HMW_TEST(media_foundation_h264_encoder_rejects_failed_optional_low_latency_set) {
  const HRESULT failed[] = {S_FALSE, E_NOTIMPL, E_ACCESSDENIED};
  for (const HRESULT scripted : failed) {
    auto [provider, transform] = FakeBackend(false, false, false);
    transform->low_latency_set_result = scripted;
    auto backend =
        hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);

    const auto started = backend->Start(H264Config());

    HMW_EXPECT(!started.ok());
    HMW_EXPECT(started.error.has_value());
    if (started.error) {
      HMW_EXPECT(started.error->status == hmw::Status::kCodecUnavailable);
    }
  }
}

HMW_TEST(media_foundation_h264_encoder_rejects_bare_idr_without_parameter_sets) {
  auto [provider, transform] = FakeBackend(false, false, false, true);
  transform->PushOutput(
      {{0U, 0U, 0U, 1U, 0x65U, 0x88U, 0x84U}, 1'000'000, true});
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
  HMW_EXPECT(backend->Start(H264Config()).ok());
  SolidInput input;

  const auto encoded = backend->Encode(input.frame);

  HMW_EXPECT(!encoded.ok());
  HMW_EXPECT(encoded.error.has_value());
  if (encoded.error) {
    HMW_EXPECT(encoded.error->status == hmw::Status::kEncodeFailed);
  }
  HMW_EXPECT(backend->Stop().ok());
}

HMW_TEST(media_foundation_h264_encoder_accepts_self_contained_idr_without_header) {
  auto [provider, transform] = FakeBackend(false, false, false, true);
  transform->PushOutput(
      {{0U, 0U, 0U, 1U, 0x67U, 0x42U, 0U, 30U,
        0U, 0U, 0U, 1U, 0x68U, 0xceU, 6U, 0xe2U,
        0U, 0U, 0U, 1U, 0x65U, 0x88U, 0x84U},
       1'000'000, true});
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
  HMW_EXPECT(backend->Start(H264Config()).ok());
  SolidInput input;

  const auto encoded = backend->Encode(input.frame);

  HMW_EXPECT(encoded.ok());
  if (encoded.ok()) {
    HMW_EXPECT(encoded.value->size() == 1U);
    if (encoded.value->size() == 1U) {
      HMW_EXPECT(HasNal(*(*encoded.value)[0].bytes, 7U));
      HMW_EXPECT(HasNal(*(*encoded.value)[0].bytes, 8U));
      HMW_EXPECT(HasNal(*(*encoded.value)[0].bytes, 5U));
    }
  }
  HMW_EXPECT(backend->Stop().ok());
}

HMW_TEST(media_foundation_h264_encoder_allows_zero_outputs_for_one_input) {
  auto [provider, transform] = FakeBackend(false, false, false);
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
  HMW_EXPECT(backend->Start(H264Config()).ok());
  SolidInput input;

  const auto encoded = backend->Encode(input.frame);

  HMW_EXPECT(encoded.ok());
  if (encoded.ok()) {
    HMW_EXPECT(encoded.value->empty());
  }
  HMW_EXPECT(backend->Stop().ok());
}

HMW_TEST(media_foundation_h264_encoder_rejects_cross_thread_calls) {
  auto [provider, transform] = FakeBackend(false, false, false);
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
  HMW_EXPECT(backend->Start(H264Config()).ok());
  SolidInput input;
  hmw::Outcome requested;
  hmw::Result<std::vector<hmw::EncodedFrame>> encoded;
  hmw::Result<std::vector<hmw::EncodedFrame>> drained;
  std::thread caller([&] {
    requested = backend->RequestKeyframe();
    encoded = backend->Encode(input.frame);
    drained = backend->Drain();
  });
  caller.join();

  HMW_EXPECT(!requested.ok());
  HMW_EXPECT(requested.error.has_value());
  HMW_EXPECT(!encoded.ok());
  HMW_EXPECT(encoded.error.has_value());
  HMW_EXPECT(!drained.ok());
  HMW_EXPECT(drained.error.has_value());
  if (requested.error) {
    HMW_EXPECT(requested.error->status == hmw::Status::kInvalidState);
  }
  if (encoded.error) {
    HMW_EXPECT(encoded.error->status == hmw::Status::kInvalidState);
  }
  if (drained.error) {
    HMW_EXPECT(drained.error->status == hmw::Status::kInvalidState);
  }
  HMW_EXPECT(backend->Stop().ok());
}

HMW_TEST(media_foundation_h264_encoder_rejects_cross_thread_stop) {
  auto [provider, transform] = FakeBackend(false, false, false);
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
  HMW_EXPECT(backend->Start(H264Config()).ok());
  hmw::Outcome stopped;
  std::thread caller([&] { stopped = backend->Stop(); });
  caller.join();

  HMW_EXPECT(!stopped.ok());
  HMW_EXPECT(stopped.error.has_value());
  if (stopped.error) {
    HMW_EXPECT(stopped.error->status == hmw::Status::kInvalidState);
  }
  HMW_EXPECT(backend->Stop().ok());
}

HMW_TEST(media_foundation_h264_encoder_wrong_thread_destructor_does_not_release_com) {
  auto [provider, transform] = FakeBackend(false, false, false);
  std::unique_ptr<hmw::EncoderBackend> backend;
  hmw::Outcome started;
  std::thread owner([&] {
    backend =
        hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
    started = backend->Start(H264Config());
  });
  owner.join();
  HMW_EXPECT(started.ok());

  const std::thread::id destroy_thread = std::this_thread::get_id();
  backend.reset();

  HMW_EXPECT(transform->ReleasesOn(destroy_thread) == 0U);
}

HMW_TEST(media_foundation_h264_encoder_rejects_unexpected_positive_optional_hresult) {
  constexpr HRESULT kUnexpectedSuccess = static_cast<HRESULT>(2L);
  struct Case {
    HRESULT support;
    HRESULT modifiable;
  };
  const Case cases[] = {
      {kUnexpectedSuccess, S_OK},
      {S_OK, kUnexpectedSuccess},
  };
  for (const auto& scripted : cases) {
    auto [provider, transform] = FakeBackend(false, false, false);
    transform->low_latency_support = scripted.support;
    transform->low_latency_modifiable = scripted.modifiable;
    auto backend =
        hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);

    const auto started = backend->Start(H264Config());

    HMW_EXPECT(!started.ok());
    HMW_EXPECT(started.error.has_value());
    if (started.error) {
      HMW_EXPECT(started.error->status == hmw::Status::kCodecUnavailable);
    }
  }
}

HMW_TEST(media_foundation_h264_encoder_releases_rejected_candidate_before_apartment_shutdown) {
  auto [provider, transform] = FakeBackend(false, false, false);
  provider->move_on_enumerate = true;
  transform->required_support = S_FALSE;
  transform->AddRef();
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
  hmw::Outcome started;
  std::thread::id owner_thread;
  std::thread owner([&] {
    owner_thread = std::this_thread::get_id();
    started = backend->Start(H264Config());
  });
  owner.join();

  HMW_EXPECT(!started.ok());
  HMW_EXPECT(transform->AllReleasesOnHadApartment(owner_thread));
  backend.reset();
  transform->Release();
}

HMW_TEST(media_foundation_h264_encoder_releases_unusable_candidate_before_apartment_shutdown) {
  auto provider = std::make_shared<FakeH264Provider>();
  provider->move_on_enumerate = true;
  auto probe = std::make_shared<ApartmentReleaseProbe>();
  provider->transforms.emplace_back(
      static_cast<IMFTransform*>(nullptr),
      [probe](IMFTransform*) { probe->Record(); });
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
  hmw::Outcome started;
  std::thread::id owner_thread;
  std::thread owner([&] {
    owner_thread = std::this_thread::get_id();
    started = backend->Start(H264Config());
  });
  owner.join();

  HMW_EXPECT(!started.ok());
  HMW_EXPECT(probe->released);
  HMW_EXPECT(probe->apartment_active);
  HMW_EXPECT(probe->thread == owner_thread);
}

HMW_TEST(media_foundation_h264_encoder_can_start_again_after_stop) {
  auto [provider, transform] = FakeBackend(false, false, false);
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);

  HMW_EXPECT(backend->Start(H264Config()).ok());
  HMW_EXPECT(backend->Stop().ok());
  HMW_EXPECT(backend->Start(H264Config()).ok());
  HMW_EXPECT(backend->Stop().ok());
}

HMW_TEST(media_foundation_h264_encoder_accepts_true_double_stop) {
  auto [provider, transform] = FakeBackend(false, false, false);
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);

  HMW_EXPECT(backend->Start(H264Config()).ok());
  HMW_EXPECT(backend->Stop().ok());
  HMW_EXPECT(backend->Stop().ok());
}

HMW_TEST(media_foundation_h264_encoder_owner_worker_stop_releases_normally) {
  auto [provider, transform] = FakeBackend(false, false, false);
  provider->move_on_enumerate = true;
  transform->AddRef();
  auto backend =
      hmw::internal::CreateMediaFoundationH264EncoderForTesting(provider);
  hmw::Outcome started;
  hmw::Outcome stopped;
  std::thread::id owner_thread;
  std::thread owner([&] {
    owner_thread = std::this_thread::get_id();
    started = backend->Start(H264Config());
    if (started.ok()) {
      stopped = backend->Stop();
    }
  });
  owner.join();

  HMW_EXPECT(started.ok());
  HMW_EXPECT(stopped.ok());
  HMW_EXPECT(transform->ReleasesOn(owner_thread) >= 3U);
  HMW_EXPECT(transform->AllReleasesOnHadApartment(owner_thread));
  HMW_EXPECT(transform->ReleasesOn(std::this_thread::get_id()) == 0U);
  backend.reset();
  HMW_EXPECT(transform->ReleasesOn(std::this_thread::get_id()) == 0U);
  transform->Release();
}
