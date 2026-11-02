#include "honey_media_core/media_core.h"

#include "core_types.hpp"
#include "avi.hpp"
#include "cinepak_decoder.hpp"
#include "cinepak_encoder.hpp"
#include "msv1.hpp"

#include <cstdlib>

#if defined(_MSC_VER) && defined(_CPPUNWIND)
#error "honey_media_core must be compiled with C++ exceptions disabled"
#endif

HMC_API uint32_t HMC_CALL hmc_abi_version(void)
{
    return HMC_ABI_VERSION_CURRENT;
}

HMC_API const char *HMC_CALL hmc_status_message(hmc_status_t status)
{
    switch (status) {
    case HMC_STATUS_OK:
        return "ok";
    case HMC_STATUS_INVALID_ARGUMENT:
        return "invalid argument";
    case HMC_STATUS_OUT_OF_MEMORY:
        return "out of memory";
    case HMC_STATUS_MALFORMED_DATA:
        return "malformed data";
    case HMC_STATUS_OVERFLOW:
        return "overflow";
    case HMC_STATUS_INTERNAL_ERROR:
        return "internal error";
    case HMC_STATUS_UNSUPPORTED:
        return "unsupported";
    case HMC_STATUS_BUFFER_TOO_SMALL:
        return "buffer too small";
    case HMC_STATUS_INVALID_STATE:
        return "invalid state";
    default:
        return "unknown status";
    }
}

HMC_API void HMC_CALL hmc_owned_buffer_release(hmc_owned_buffer_t *buffer)
{
    if (buffer == nullptr) {
        return;
    }

    std::free(buffer->data);
    buffer->data = nullptr;
    buffer->size = 0u;
}

HMC_API hmc_status_t HMC_CALL hmc_msv1_encoder_config_init(
    hmc_msv1_encoder_config_t *config,
    uint32_t config_size)
{
    return honey::media::msv1_encoder_config_init(config, config_size);
}

HMC_API hmc_status_t HMC_CALL hmc_msv1_decoder_config_init(
    hmc_msv1_decoder_config_t *config,
    uint32_t config_size)
{
    return honey::media::msv1_decoder_config_init(config, config_size);
}

HMC_API hmc_status_t HMC_CALL hmc_cinepak_decoder_config_init(
    hmc_cinepak_decoder_config_t *config,
    uint32_t config_size)
{
    return honey::media::cinepak_decoder_config_init(config, config_size);
}

HMC_API hmc_status_t HMC_CALL hmc_cinepak_encoder_config_init(
    hmc_cinepak_encoder_config_t *config,
    uint32_t config_size)
{
    return honey::media::cinepak_encoder_config_init(config, config_size);
}

HMC_API hmc_status_t HMC_CALL hmc_cinepak_encoder_create(
    const hmc_cinepak_encoder_config_t *config,
    hmc_cinepak_encoder_t **encoder)
{
    return honey::media::cinepak_encoder_create(config, encoder);
}

HMC_API hmc_status_t HMC_CALL hmc_cinepak_encoder_reset(
    hmc_cinepak_encoder_t *encoder)
{
    return honey::media::cinepak_encoder_reset(encoder);
}

HMC_API void HMC_CALL hmc_cinepak_encoder_destroy(
    hmc_cinepak_encoder_t *encoder)
{
    honey::media::cinepak_encoder_destroy(encoder);
}

HMC_API hmc_status_t HMC_CALL hmc_cinepak_encoder_encode(
    hmc_cinepak_encoder_t *encoder,
    const uint8_t *rgba,
    size_t rgba_size,
    hmc_encode_flags_t encode_flags,
    hmc_owned_buffer_t *output,
    hmc_frame_flags_t *output_frame_flags)
{
    return honey::media::cinepak_encoder_encode(
        encoder, rgba, rgba_size, encode_flags, output, output_frame_flags);
}

HMC_API hmc_status_t HMC_CALL hmc_cinepak_decoder_create(
    const hmc_cinepak_decoder_config_t *config,
    hmc_cinepak_decoder_t **decoder)
{
    return honey::media::cinepak_decoder_create(config, decoder);
}

HMC_API hmc_status_t HMC_CALL hmc_cinepak_decoder_reset(
    hmc_cinepak_decoder_t *decoder)
{
    return honey::media::cinepak_decoder_reset(decoder);
}

HMC_API void HMC_CALL hmc_cinepak_decoder_destroy(
    hmc_cinepak_decoder_t *decoder)
{
    honey::media::cinepak_decoder_destroy(decoder);
}

HMC_API hmc_status_t HMC_CALL hmc_cinepak_decoder_decode(
    hmc_cinepak_decoder_t *decoder,
    const uint8_t *encoded,
    size_t encoded_size,
    uint32_t *argb,
    size_t argb_pixel_count)
{
    return honey::media::cinepak_decoder_decode(
        decoder, encoded, encoded_size, argb, argb_pixel_count);
}

HMC_API hmc_status_t HMC_CALL hmc_msv1_encode(
    const hmc_msv1_encoder_config_t *config,
    const uint8_t *rgba,
    size_t rgba_size,
    const uint8_t *previous_rgba,
    size_t previous_rgba_size,
    hmc_encode_flags_t encode_flags,
    hmc_owned_buffer_t *output,
    hmc_frame_flags_t *output_frame_flags)
{
    return honey::media::msv1_encode(
        config,
        rgba,
        rgba_size,
        previous_rgba,
        previous_rgba_size,
        encode_flags,
        output,
        output_frame_flags);
}

HMC_API hmc_status_t HMC_CALL hmc_msv1_decode(
    const hmc_msv1_decoder_config_t *config,
    const uint8_t *encoded,
    size_t encoded_size,
    uint32_t *argb,
    size_t argb_pixel_count)
{
    return honey::media::msv1_decode(
        config, encoded, encoded_size, argb, argb_pixel_count);
}

HMC_API hmc_status_t HMC_CALL hmc_avi_muxer_config_init(
    hmc_avi_muxer_config_t *config,
    uint32_t config_size)
{
    return honey::media::avi_muxer_config_init(config, config_size);
}

HMC_API hmc_status_t HMC_CALL hmc_avi_muxer_create(
    const hmc_avi_muxer_config_t *config,
    hmc_avi_muxer_t **muxer)
{
    return honey::media::avi_muxer_create(config, muxer);
}

HMC_API hmc_status_t HMC_CALL hmc_avi_muxer_add_frame(
    hmc_avi_muxer_t *muxer,
    const uint8_t *data,
    size_t size,
    hmc_frame_flags_t frame_flags)
{
    return honey::media::avi_muxer_add_frame(muxer, data, size, frame_flags);
}

HMC_API hmc_status_t HMC_CALL hmc_avi_muxer_finish(
    hmc_avi_muxer_t *muxer,
    hmc_owned_buffer_t *output)
{
    return honey::media::avi_muxer_finish(muxer, output);
}

HMC_API void HMC_CALL hmc_avi_muxer_destroy(hmc_avi_muxer_t *muxer)
{
    honey::media::avi_muxer_destroy(muxer);
}

HMC_API hmc_status_t HMC_CALL hmc_avi_reader_create_copy(
    const uint8_t *data,
    size_t size,
    hmc_avi_reader_t **reader)
{
    return honey::media::avi_reader_create_copy(data, size, reader);
}

HMC_API hmc_status_t HMC_CALL hmc_avi_reader_get_info(
    const hmc_avi_reader_t *reader,
    hmc_avi_info_t *info)
{
    return honey::media::avi_reader_get_info(reader, info);
}

HMC_API hmc_status_t HMC_CALL hmc_avi_reader_get_frame_info(
    const hmc_avi_reader_t *reader,
    uint32_t index,
    hmc_avi_frame_info_t *frame_info)
{
    return honey::media::avi_reader_get_frame_info(reader, index, frame_info);
}

HMC_API hmc_status_t HMC_CALL hmc_avi_reader_get_frame_view(
    const hmc_avi_reader_t *reader,
    uint32_t index,
    hmc_bytes_view_t *frame)
{
    return honey::media::avi_reader_get_frame_view(reader, index, frame);
}

HMC_API hmc_status_t HMC_CALL hmc_avi_reader_copy_frame(
    const hmc_avi_reader_t *reader,
    uint32_t index,
    hmc_owned_buffer_t *frame)
{
    return honey::media::avi_reader_copy_frame(reader, index, frame);
}

HMC_API void HMC_CALL hmc_avi_reader_destroy(hmc_avi_reader_t *reader)
{
    honey::media::avi_reader_destroy(reader);
}
