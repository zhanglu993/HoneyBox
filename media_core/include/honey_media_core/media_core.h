#ifndef HMC_MEDIA_CORE_H
#define HMC_MEDIA_CORE_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) || defined(__CYGWIN__)
#define HMC_CALL __cdecl
#if defined(HMC_BUILD_SHARED)
#define HMC_API __declspec(dllexport)
#elif defined(HMC_USE_SHARED)
#define HMC_API __declspec(dllimport)
#else
#define HMC_API
#endif
#elif defined(__GNUC__) || defined(__clang__)
#define HMC_API __attribute__((visibility("default")))
#define HMC_CALL
#else
#define HMC_API
#define HMC_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define HMC_ABI_VERSION_1_0     UINT32_C(0x00010000)
#define HMC_ABI_VERSION_CURRENT HMC_ABI_VERSION_1_0
#define HMC_ABI_VERSION_GET_MAJOR(version) (((uint32_t)(version) >> 16u) & UINT32_C(0xffff))
#define HMC_ABI_VERSION_GET_MINOR(version) ((uint32_t)(version) & UINT32_C(0xffff))

#define HMC_MEDIA_FOURCC(a, b, c, d) \
    ((uint32_t)(uint8_t)(a) | ((uint32_t)(uint8_t)(b) << 8u) | \
     ((uint32_t)(uint8_t)(c) << 16u) | ((uint32_t)(uint8_t)(d) << 24u))

typedef int32_t hmc_status_t;

#define HMC_STATUS_OK               ((hmc_status_t)0)
#define HMC_STATUS_INVALID_ARGUMENT ((hmc_status_t)1)
#define HMC_STATUS_OUT_OF_MEMORY    ((hmc_status_t)2)
#define HMC_STATUS_MALFORMED_DATA   ((hmc_status_t)3)
#define HMC_STATUS_OVERFLOW         ((hmc_status_t)4)
#define HMC_STATUS_INTERNAL_ERROR   ((hmc_status_t)5)
#define HMC_STATUS_UNSUPPORTED      ((hmc_status_t)6)
#define HMC_STATUS_BUFFER_TOO_SMALL ((hmc_status_t)7)
#define HMC_STATUS_INVALID_STATE    ((hmc_status_t)8)

typedef uint32_t hmc_encode_flags_t;
typedef uint32_t hmc_frame_flags_t;

#define HMC_ENCODE_FLAG_NONE      UINT32_C(0)
#define HMC_ENCODE_FLAG_FORCE_KEY UINT32_C(0x00000001)
#define HMC_FRAME_FLAG_NONE       UINT32_C(0)
#define HMC_FRAME_FLAG_KEY        UINT32_C(0x00000001)
#define HMC_FRAME_FLAG_KEY_KNOWN  UINT32_C(0x00000002)

typedef struct hmc_owned_buffer {
    uint8_t *data;
    size_t size;
} hmc_owned_buffer_t;

typedef struct hmc_bytes_view {
    const uint8_t *data;
    size_t size;
} hmc_bytes_view_t;

typedef struct hmc_avi_muxer hmc_avi_muxer_t;
typedef struct hmc_avi_reader hmc_avi_reader_t;
typedef struct hmc_cinepak_encoder hmc_cinepak_encoder_t;
typedef struct hmc_cinepak_decoder hmc_cinepak_decoder_t;

typedef struct hmc_cinepak_encoder_config {
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
    int32_t quality;
    int32_t v1_size;
    int32_t v4_size;
    int32_t refine_iterations;
    int32_t chroma_weight;
    int32_t strips;
    int32_t skip_threshold;
    int32_t key_interval;
} hmc_cinepak_encoder_config_t;

#define HMC_CINEPAK_ENCODER_CONFIG_V1_SIZE UINT32_C(44)

typedef struct hmc_cinepak_decoder_config {
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
} hmc_cinepak_decoder_config_t;

#define HMC_CINEPAK_DECODER_CONFIG_V1_SIZE UINT32_C(12)

typedef struct hmc_msv1_encoder_config {
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
    uint32_t skip_threshold;
} hmc_msv1_encoder_config_t;

#define HMC_MSV1_ENCODER_CONFIG_V1_SIZE UINT32_C(16)

typedef struct hmc_msv1_decoder_config {
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
} hmc_msv1_decoder_config_t;

#define HMC_MSV1_DECODER_CONFIG_V1_SIZE UINT32_C(12)

typedef struct hmc_avi_muxer_config {
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
    uint32_t frame_rate_num;
    uint32_t frame_rate_den;
    uint32_t handler_fourcc;
    uint32_t compression_fourcc;
    uint32_t bit_count;
} hmc_avi_muxer_config_t;

#define HMC_AVI_MUXER_CONFIG_V1_SIZE UINT32_C(32)

typedef struct hmc_avi_info {
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
    uint32_t usec_per_frame;
    uint32_t frame_rate_num;
    uint32_t frame_rate_den;
    uint32_t handler_fourcc;
    uint32_t compression_fourcc;
    uint32_t bit_count;
    uint32_t frame_count;
} hmc_avi_info_t;

#define HMC_AVI_INFO_V1_SIZE UINT32_C(40)

typedef struct hmc_avi_frame_info {
    uint32_t struct_size;
    uint32_t chunk_fourcc;
    uint32_t avi_index_flags;
    uint32_t frame_flags;
} hmc_avi_frame_info_t;

#define HMC_AVI_FRAME_INFO_V1_SIZE UINT32_C(16)

HMC_API uint32_t HMC_CALL hmc_abi_version(void);
HMC_API const char *HMC_CALL hmc_status_message(hmc_status_t status);
HMC_API void HMC_CALL hmc_owned_buffer_release(hmc_owned_buffer_t *buffer);
HMC_API hmc_status_t HMC_CALL hmc_msv1_encoder_config_init(
    hmc_msv1_encoder_config_t *config,
    uint32_t config_size);
HMC_API hmc_status_t HMC_CALL hmc_msv1_decoder_config_init(
    hmc_msv1_decoder_config_t *config,
    uint32_t config_size);
HMC_API hmc_status_t HMC_CALL hmc_cinepak_decoder_config_init(
    hmc_cinepak_decoder_config_t *config,
    uint32_t config_size);
HMC_API hmc_status_t HMC_CALL hmc_cinepak_encoder_config_init(
    hmc_cinepak_encoder_config_t *config,
    uint32_t config_size);
HMC_API hmc_status_t HMC_CALL hmc_cinepak_encoder_create(
    const hmc_cinepak_encoder_config_t *config,
    hmc_cinepak_encoder_t **encoder);
HMC_API hmc_status_t HMC_CALL hmc_cinepak_encoder_reset(
    hmc_cinepak_encoder_t *encoder);
HMC_API void HMC_CALL hmc_cinepak_encoder_destroy(
    hmc_cinepak_encoder_t *encoder);
HMC_API hmc_status_t HMC_CALL hmc_cinepak_encoder_encode(
    hmc_cinepak_encoder_t *encoder,
    const uint8_t *rgba,
    size_t rgba_size,
    hmc_encode_flags_t encode_flags,
    hmc_owned_buffer_t *output,
    hmc_frame_flags_t *output_frame_flags);
HMC_API hmc_status_t HMC_CALL hmc_cinepak_decoder_create(
    const hmc_cinepak_decoder_config_t *config,
    hmc_cinepak_decoder_t **decoder);
HMC_API hmc_status_t HMC_CALL hmc_cinepak_decoder_reset(
    hmc_cinepak_decoder_t *decoder);
HMC_API void HMC_CALL hmc_cinepak_decoder_destroy(
    hmc_cinepak_decoder_t *decoder);
HMC_API hmc_status_t HMC_CALL hmc_cinepak_decoder_decode(
    hmc_cinepak_decoder_t *decoder,
    const uint8_t *encoded,
    size_t encoded_size,
    uint32_t *argb,
    size_t argb_pixel_count);
HMC_API hmc_status_t HMC_CALL hmc_msv1_encode(
    const hmc_msv1_encoder_config_t *config,
    const uint8_t *rgba,
    size_t rgba_size,
    const uint8_t *previous_rgba,
    size_t previous_rgba_size,
    hmc_encode_flags_t encode_flags,
    hmc_owned_buffer_t *output,
    hmc_frame_flags_t *output_frame_flags);
HMC_API hmc_status_t HMC_CALL hmc_msv1_decode(
    const hmc_msv1_decoder_config_t *config,
    const uint8_t *encoded,
    size_t encoded_size,
    uint32_t *argb,
    size_t argb_pixel_count);
HMC_API hmc_status_t HMC_CALL hmc_avi_muxer_config_init(
    hmc_avi_muxer_config_t *config,
    uint32_t config_size);
HMC_API hmc_status_t HMC_CALL hmc_avi_muxer_create(
    const hmc_avi_muxer_config_t *config,
    hmc_avi_muxer_t **muxer);
HMC_API hmc_status_t HMC_CALL hmc_avi_muxer_add_frame(
    hmc_avi_muxer_t *muxer,
    const uint8_t *data,
    size_t size,
    hmc_frame_flags_t frame_flags);
HMC_API hmc_status_t HMC_CALL hmc_avi_muxer_finish(
    hmc_avi_muxer_t *muxer,
    hmc_owned_buffer_t *output);
HMC_API void HMC_CALL hmc_avi_muxer_destroy(hmc_avi_muxer_t *muxer);
HMC_API hmc_status_t HMC_CALL hmc_avi_reader_create_copy(
    const uint8_t *data,
    size_t size,
    hmc_avi_reader_t **reader);
HMC_API hmc_status_t HMC_CALL hmc_avi_reader_get_info(
    const hmc_avi_reader_t *reader,
    hmc_avi_info_t *info);
HMC_API hmc_status_t HMC_CALL hmc_avi_reader_get_frame_info(
    const hmc_avi_reader_t *reader,
    uint32_t index,
    hmc_avi_frame_info_t *frame_info);
HMC_API hmc_status_t HMC_CALL hmc_avi_reader_get_frame_view(
    const hmc_avi_reader_t *reader,
    uint32_t index,
    hmc_bytes_view_t *frame);
HMC_API hmc_status_t HMC_CALL hmc_avi_reader_copy_frame(
    const hmc_avi_reader_t *reader,
    uint32_t index,
    hmc_owned_buffer_t *frame);
HMC_API void HMC_CALL hmc_avi_reader_destroy(hmc_avi_reader_t *reader);

#ifdef __cplusplus
}
#endif

#endif
