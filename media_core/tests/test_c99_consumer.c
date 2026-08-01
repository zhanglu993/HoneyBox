#include "honey_media_core/media_core.h"

#ifndef HMC_MEDIA_CORE_H
#error "media_core.h must expose the HMC_MEDIA_CORE_H include guard"
#endif

#ifndef HMC_API
#error "media_core.h must expose HMC_API"
#endif

#ifndef HMC_CALL
#error "media_core.h must expose HMC_CALL"
#endif

#if defined(HMC_EXPECT_USE_SHARED) && !defined(HMC_USE_SHARED)
#error "a shared C99 consumer must compile with HMC_USE_SHARED"
#endif

#if !defined(HMC_EXPECT_USE_SHARED) && defined(HMC_USE_SHARED)
#error "a static C99 consumer must not compile with HMC_USE_SHARED"
#endif

typedef char hmc_status_must_be_32_bits[
    sizeof(hmc_status_t) == sizeof(int32_t) ? 1 : -1];
typedef char hmc_encode_flags_must_be_32_bits[
    sizeof(hmc_encode_flags_t) == sizeof(uint32_t) ? 1 : -1];
typedef char hmc_frame_flags_must_be_32_bits[
    sizeof(hmc_frame_flags_t) == sizeof(uint32_t) ? 1 : -1];
typedef char hmc_abi_1_0_must_be_packed[
    HMC_ABI_VERSION_1_0 == UINT32_C(0x00010000) ? 1 : -1];
typedef char hmc_status_values_must_be_frozen[
    HMC_STATUS_OK == 0 &&
    HMC_STATUS_INVALID_ARGUMENT == 1 &&
    HMC_STATUS_OUT_OF_MEMORY == 2 &&
    HMC_STATUS_MALFORMED_DATA == 3 &&
    HMC_STATUS_OVERFLOW == 4 &&
    HMC_STATUS_INTERNAL_ERROR == 5 &&
    HMC_STATUS_UNSUPPORTED == 6 &&
    HMC_STATUS_BUFFER_TOO_SMALL == 7 &&
    HMC_STATUS_INVALID_STATE == 8 ? 1 : -1];
typedef char hmc_flag_values_must_be_frozen[
    HMC_ENCODE_FLAG_NONE == UINT32_C(0) &&
    HMC_ENCODE_FLAG_FORCE_KEY == UINT32_C(0x00000001) &&
    HMC_FRAME_FLAG_NONE == UINT32_C(0) &&
    HMC_FRAME_FLAG_KEY == UINT32_C(0x00000001) &&
    HMC_FRAME_FLAG_KEY_KNOWN == UINT32_C(0x00000002) ? 1 : -1];
typedef char hmc_msv1_encoder_config_v1_size_must_be_frozen[
    sizeof(hmc_msv1_encoder_config_t) == HMC_MSV1_ENCODER_CONFIG_V1_SIZE ? 1 : -1];
typedef char hmc_msv1_decoder_config_v1_size_must_be_frozen[
    sizeof(hmc_msv1_decoder_config_t) == HMC_MSV1_DECODER_CONFIG_V1_SIZE ? 1 : -1];
typedef char hmc_cinepak_decoder_config_v1_size_must_be_frozen[
    sizeof(hmc_cinepak_decoder_config_t) ==
        HMC_CINEPAK_DECODER_CONFIG_V1_SIZE ? 1 : -1];
typedef char hmc_cinepak_encoder_config_v1_size_must_be_frozen[
    sizeof(hmc_cinepak_encoder_config_t) ==
        HMC_CINEPAK_ENCODER_CONFIG_V1_SIZE ? 1 : -1];
typedef char hmc_avi_muxer_config_v1_size_must_be_frozen[
    sizeof(hmc_avi_muxer_config_t) == HMC_AVI_MUXER_CONFIG_V1_SIZE ? 1 : -1];
typedef char hmc_avi_info_v1_size_must_be_frozen[
    sizeof(hmc_avi_info_t) == HMC_AVI_INFO_V1_SIZE ? 1 : -1];
typedef char hmc_avi_frame_info_v1_size_must_be_frozen[
    sizeof(hmc_avi_frame_info_t) == HMC_AVI_FRAME_INFO_V1_SIZE ? 1 : -1];

void honey_media_core_c99_compile_test(void)
{
    hmc_status_t (HMC_CALL *cinepak_encoder_init_fn)(
        hmc_cinepak_encoder_config_t *, uint32_t) =
        &hmc_cinepak_encoder_config_init;
    hmc_status_t (HMC_CALL *cinepak_encoder_create_fn)(
        const hmc_cinepak_encoder_config_t *, hmc_cinepak_encoder_t **) =
        &hmc_cinepak_encoder_create;
    hmc_status_t (HMC_CALL *cinepak_encoder_reset_fn)(hmc_cinepak_encoder_t *) =
        &hmc_cinepak_encoder_reset;
    void (HMC_CALL *cinepak_encoder_destroy_fn)(hmc_cinepak_encoder_t *) =
        &hmc_cinepak_encoder_destroy;
    hmc_status_t (HMC_CALL *cinepak_encoder_encode_fn)(
        hmc_cinepak_encoder_t *, const uint8_t *, size_t,
        hmc_encode_flags_t, hmc_owned_buffer_t *, hmc_frame_flags_t *) =
        &hmc_cinepak_encoder_encode;
    hmc_owned_buffer_t buffer = {NULL, 0u};
    hmc_bytes_view_t view = {NULL, 0u};
    const uint32_t fourcc = HMC_MEDIA_FOURCC('R', 'G', 'B', 'A');
    const hmc_status_t status = HMC_STATUS_OK;
    const uint32_t abi_major = HMC_ABI_VERSION_GET_MAJOR(HMC_ABI_VERSION_CURRENT);
    const uint32_t abi_minor = HMC_ABI_VERSION_GET_MINOR(HMC_ABI_VERSION_CURRENT);
    hmc_encode_flags_t encode_flags = HMC_ENCODE_FLAG_NONE;
    hmc_frame_flags_t frame_flags = HMC_FRAME_FLAG_NONE;
    hmc_msv1_encoder_config_t msv1_encoder_config;
    hmc_msv1_decoder_config_t msv1_decoder_config;
    hmc_cinepak_decoder_config_t cinepak_decoder_config;
    hmc_cinepak_encoder_config_t cinepak_encoder_config;
    hmc_avi_muxer_config_t muxer_config;
    hmc_avi_info_t avi_info = {HMC_AVI_INFO_V1_SIZE, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u};
    hmc_avi_frame_info_t avi_frame_info = {
        HMC_AVI_FRAME_INFO_V1_SIZE, 0u, 0u, 0u};
    hmc_avi_muxer_t *muxer = NULL;
    hmc_avi_reader_t *reader = NULL;
    hmc_cinepak_decoder_t *cinepak_decoder = NULL;
    hmc_cinepak_encoder_t *cinepak_encoder = NULL;

    (void)view;
    (void)fourcc;
    (void)status;
    (void)abi_major;
    (void)abi_minor;
    (void)encode_flags;
    (void)frame_flags;
    (void)avi_info;
    (void)avi_frame_info;
    (void)muxer;
    (void)reader;
    (void)cinepak_decoder;
    (void)cinepak_encoder;
    (void)cinepak_encoder_init_fn;
    (void)cinepak_encoder_create_fn;
    (void)cinepak_encoder_reset_fn;
    (void)cinepak_encoder_destroy_fn;
    (void)cinepak_encoder_encode_fn;
    (void)hmc_avi_muxer_config_init(&muxer_config, sizeof(muxer_config));
    (void)hmc_msv1_encoder_config_init(
        &msv1_encoder_config, sizeof(msv1_encoder_config));
    (void)hmc_msv1_decoder_config_init(
        &msv1_decoder_config, sizeof(msv1_decoder_config));
    (void)hmc_cinepak_decoder_config_init(
        &cinepak_decoder_config, sizeof(cinepak_decoder_config));
    (void)hmc_cinepak_encoder_config_init(
        &cinepak_encoder_config, sizeof(cinepak_encoder_config));
    (void)hmc_cinepak_encoder_create(
        &cinepak_encoder_config, &cinepak_encoder);
    (void)hmc_cinepak_encoder_reset(cinepak_encoder);
    (void)hmc_cinepak_encoder_encode(
        cinepak_encoder, NULL, 0u, HMC_ENCODE_FLAG_NONE,
        &buffer, &frame_flags);
    hmc_cinepak_encoder_destroy(cinepak_encoder);
    (void)hmc_cinepak_decoder_create(
        &cinepak_decoder_config, &cinepak_decoder);
    (void)hmc_cinepak_decoder_reset(cinepak_decoder);
    (void)hmc_cinepak_decoder_decode(
        cinepak_decoder, NULL, 0u, NULL, 0u);
    hmc_cinepak_decoder_destroy(cinepak_decoder);
    hmc_owned_buffer_release(&buffer);
}
