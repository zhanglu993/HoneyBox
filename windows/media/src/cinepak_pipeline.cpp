#include "honey_media_windows/media_converter.h"

#include "honey_media_core/media_core.h"

#include <cstdint>
#include <functional>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace hmw::internal {
namespace {

struct EncoderDeleter {
  void operator()(hmc_cinepak_encoder_t* encoder) const {
    hmc_cinepak_encoder_destroy(encoder);
  }
};

struct MuxerDeleter {
  void operator()(hmc_avi_muxer_t* muxer) const {
    hmc_avi_muxer_destroy(muxer);
  }
};

class OwnedBuffer {
 public:
  OwnedBuffer() = default;
  ~OwnedBuffer() { hmc_owned_buffer_release(&buffer_); }

  OwnedBuffer(const OwnedBuffer&) = delete;
  OwnedBuffer& operator=(const OwnedBuffer&) = delete;

  hmc_owned_buffer_t* out() { return &buffer_; }
  const uint8_t* data() const { return buffer_.data; }
  size_t size() const { return buffer_.size; }

 private:
  hmc_owned_buffer_t buffer_{};
};

template <typename T>
Result<T> Failure(Status status, std::string message) {
  return Result<T>{std::nullopt, Error{status, std::move(message)}};
}

Result<ConversionResult> CoreFailure(hmc_status_t status,
                                     const char* operation) {
  const Status mapped =
      status == HMC_STATUS_INVALID_ARGUMENT || status == HMC_STATUS_OVERFLOW
          ? Status::kInvalidArgument
          : status == HMC_STATUS_OUT_OF_MEMORY ? Status::kIoError
                                                : Status::kEncodeFailed;
  return Failure<ConversionResult>(
      mapped, std::string(operation) + ": " + hmc_status_message(status));
}

bool IsCancellationRequested(const IsCancelled& cancelled) {
  return cancelled && cancelled();
}

bool CheckedPixelBytes(uint32_t width, uint32_t height, size_t* bytes) {
  const uint64_t count = static_cast<uint64_t>(width) * height * 4U;
  if (count > std::numeric_limits<size_t>::max()) {
    return false;
  }
  *bytes = static_cast<size_t>(count);
  return true;
}

}  // namespace

Result<ConversionResult> EncodeCinepakFrames(
    uint32_t width, uint32_t height, uint32_t frame_rate_num,
    uint32_t frame_rate_den, uint32_t frame_count, uint32_t quality,
    uint32_t refine, uint32_t strips, uint32_t skip_threshold,
    uint32_t key_interval,
    const std::function<Result<std::reference_wrapper<const RgbaFrame>>(
        uint32_t)>& produce_frame,
    const std::function<bool(uint32_t)>& force_key, Progress progress,
    IsCancelled cancelled) {
  if (width == 0 || height == 0 || frame_rate_num == 0 ||
      frame_rate_den == 0 || frame_count == 0 || !produce_frame ||
      quality > 100 || refine > static_cast<uint32_t>(INT32_MAX) ||
      strips == 0 || strips > static_cast<uint32_t>(INT32_MAX) ||
      skip_threshold > static_cast<uint32_t>(INT32_MAX) ||
      key_interval > static_cast<uint32_t>(INT32_MAX)) {
    return Failure<ConversionResult>(Status::kInvalidArgument,
                                     "invalid Cinepak pipeline parameters");
  }
  if (IsCancellationRequested(cancelled)) {
    return Failure<ConversionResult>(Status::kCancelled,
                                     "media conversion cancelled");
  }

  try {
    hmc_cinepak_encoder_config_t encoder_config{};
    hmc_status_t status = hmc_cinepak_encoder_config_init(
        &encoder_config, sizeof(encoder_config));
    if (status != HMC_STATUS_OK) {
      return CoreFailure(status, "Cinepak config initialization failed");
    }
    encoder_config.width = width;
    encoder_config.height = height;
    encoder_config.quality = static_cast<int32_t>(quality);
    encoder_config.v1_size = 256;
    encoder_config.v4_size = 256;
    encoder_config.refine_iterations = static_cast<int32_t>(refine);
    encoder_config.chroma_weight = 4;
    encoder_config.strips = static_cast<int32_t>(strips);
    encoder_config.skip_threshold = static_cast<int32_t>(skip_threshold);
    encoder_config.key_interval = static_cast<int32_t>(key_interval);

    hmc_cinepak_encoder_t* raw_encoder = nullptr;
    status = hmc_cinepak_encoder_create(&encoder_config, &raw_encoder);
    if (status != HMC_STATUS_OK) {
      return CoreFailure(status, "Cinepak encoder creation failed");
    }
    const std::unique_ptr<hmc_cinepak_encoder_t, EncoderDeleter> encoder(
        raw_encoder);

    if (IsCancellationRequested(cancelled)) {
      return Failure<ConversionResult>(Status::kCancelled,
                                       "media conversion cancelled");
    }
    hmc_avi_muxer_config_t muxer_config{};
    status = hmc_avi_muxer_config_init(&muxer_config, sizeof(muxer_config));
    if (status != HMC_STATUS_OK) {
      return CoreFailure(status, "AVI config initialization failed");
    }
    muxer_config.width = width;
    muxer_config.height = height;
    muxer_config.frame_rate_num = frame_rate_num;
    muxer_config.frame_rate_den = frame_rate_den;
    muxer_config.handler_fourcc = HMC_MEDIA_FOURCC('c', 'v', 'i', 'd');
    muxer_config.compression_fourcc = HMC_MEDIA_FOURCC('c', 'v', 'i', 'd');
    muxer_config.bit_count = 24;

    hmc_avi_muxer_t* raw_muxer = nullptr;
    status = hmc_avi_muxer_create(&muxer_config, &raw_muxer);
    if (status != HMC_STATUS_OK) {
      return CoreFailure(status, "AVI muxer creation failed");
    }
    const std::unique_ptr<hmc_avi_muxer_t, MuxerDeleter> muxer(raw_muxer);

    size_t expected_bytes = 0;
    if (!CheckedPixelBytes(width, height, &expected_bytes)) {
      return Failure<ConversionResult>(Status::kInvalidArgument,
                                       "Cinepak dimensions overflow RGBA size");
    }
    for (uint32_t index = 0; index < frame_count; ++index) {
      if (IsCancellationRequested(cancelled)) {
        return Failure<ConversionResult>(Status::kCancelled,
                                         "media conversion cancelled");
      }
      Result<std::reference_wrapper<const RgbaFrame>> produced =
          produce_frame(index);
      if (!produced.ok()) {
        return Result<ConversionResult>{std::nullopt,
                                        std::move(produced.error)};
      }
      const RgbaFrame& frame = produced.value->get();
      if (frame.width != width || frame.height != height ||
          frame.pixels.size() != expected_bytes) {
        return Failure<ConversionResult>(
            Status::kInvalidArgument,
            "produced frame must be tightly packed pipeline-sized RGBA");
      }

      if (IsCancellationRequested(cancelled)) {
        return Failure<ConversionResult>(Status::kCancelled,
                                         "media conversion cancelled");
      }
      OwnedBuffer encoded;
      hmc_frame_flags_t frame_flags = HMC_FRAME_FLAG_NONE;
      const hmc_encode_flags_t encode_flags =
          force_key && force_key(index) ? HMC_ENCODE_FLAG_FORCE_KEY
                                        : HMC_ENCODE_FLAG_NONE;
      status = hmc_cinepak_encoder_encode(
          encoder.get(), frame.pixels.data(), frame.pixels.size(), encode_flags,
          encoded.out(), &frame_flags);
      if (status != HMC_STATUS_OK) {
        return CoreFailure(status, "Cinepak frame encoding failed");
      }

      if (IsCancellationRequested(cancelled)) {
        return Failure<ConversionResult>(Status::kCancelled,
                                         "media conversion cancelled");
      }
      status = hmc_avi_muxer_add_frame(muxer.get(), encoded.data(),
                                       encoded.size(), frame_flags);
      if (status != HMC_STATUS_OK) {
        return CoreFailure(status, "AVI frame muxing failed");
      }
      if (progress) {
        progress(index + 1U, frame_count);
      }
    }

    if (IsCancellationRequested(cancelled)) {
      return Failure<ConversionResult>(Status::kCancelled,
                                       "media conversion cancelled");
    }
    OwnedBuffer avi;
    status = hmc_avi_muxer_finish(muxer.get(), avi.out());
    if (status != HMC_STATUS_OK) {
      return CoreFailure(status, "AVI finalization failed");
    }
    if (IsCancellationRequested(cancelled)) {
      return Failure<ConversionResult>(Status::kCancelled,
                                       "media conversion cancelled");
    }
    std::vector<uint8_t> bytes(avi.data(), avi.data() + avi.size());
    return Result<ConversionResult>{
        ConversionResult{std::move(bytes), width, height, frame_count,
                         static_cast<double>(frame_rate_num) /
                             static_cast<double>(frame_rate_den)},
        std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<ConversionResult>(Status::kIoError,
                                     "media conversion allocation failed");
  }
}

}  // namespace hmw::internal
