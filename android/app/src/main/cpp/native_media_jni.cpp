#include <jni.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>

#include "honey_media_core/media_core.h"

namespace {

static_assert(sizeof(jint) == sizeof(uint32_t), "JNI jint must be 32-bit");

struct NativeBytes {
    uint8_t *data = nullptr;
    size_t size = 0;

    ~NativeBytes()
    {
        std::free(data);
    }

    NativeBytes(const NativeBytes &) = delete;
    NativeBytes &operator=(const NativeBytes &) = delete;
    NativeBytes() = default;
};

struct NativeInts {
    jint *data = nullptr;
    size_t count = 0;

    ~NativeInts()
    {
        std::free(data);
    }

    NativeInts(const NativeInts &) = delete;
    NativeInts &operator=(const NativeInts &) = delete;
    NativeInts() = default;
};

void throw_java(JNIEnv *env, const char *class_name, const char *message)
{
    if (env->ExceptionCheck()) {
        return;
    }
    jclass exception_class = env->FindClass(class_name);
    if (exception_class == nullptr) {
        return;
    }
    env->ThrowNew(exception_class, message);
    env->DeleteLocalRef(exception_class);
}

bool status_ok(JNIEnv *env, hmc_status_t status)
{
    if (status == HMC_STATUS_OK) {
        return true;
    }
    if (env->ExceptionCheck()) {
        return false;
    }

    const char *class_name = "java/lang/IllegalStateException";
    switch (status) {
    case HMC_STATUS_INVALID_ARGUMENT:
    case HMC_STATUS_OVERFLOW:
    case HMC_STATUS_BUFFER_TOO_SMALL:
        class_name = "java/lang/IllegalArgumentException";
        break;
    case HMC_STATUS_OUT_OF_MEMORY:
        class_name = "java/lang/OutOfMemoryError";
        break;
    case HMC_STATUS_MALFORMED_DATA:
        class_name = "java/io/IOException";
        break;
    case HMC_STATUS_UNSUPPORTED:
        class_name = "java/lang/UnsupportedOperationException";
        break;
    case HMC_STATUS_INVALID_STATE:
    case HMC_STATUS_INTERNAL_ERROR:
    default:
        break;
    }
    throw_java(env, class_name, hmc_status_message(status));
    return false;
}

bool checked_multiply(size_t left, size_t right, size_t *result)
{
    if (result == nullptr) {
        return false;
    }
    if (left != 0 && right > std::numeric_limits<size_t>::max() / left) {
        return false;
    }
    *result = left * right;
    return true;
}

bool required_rgba_bytes(JNIEnv *env, jint width, jint height, size_t *required)
{
    if (width <= 0 || height <= 0) {
        throw_java(env, "java/lang/IllegalArgumentException", "width and height must be positive");
        return false;
    }
    size_t pixels = 0;
    if (!checked_multiply(static_cast<size_t>(width), static_cast<size_t>(height), &pixels) ||
        !checked_multiply(pixels, size_t{4}, required)) {
        throw_java(env, "java/lang/IllegalArgumentException", "pixel buffer size overflows size_t");
        return false;
    }
    return true;
}

bool copy_byte_array(JNIEnv *env, jbyteArray source, NativeBytes *destination)
{
    if (source == nullptr || destination == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "byte array must not be null");
        return false;
    }
    const jsize length = env->GetArrayLength(source);
    if (env->ExceptionCheck()) {
        return false;
    }
    destination->size = static_cast<size_t>(length);
    if (length == 0) {
        return true;
    }
    destination->data = static_cast<uint8_t *>(std::malloc(destination->size));
    if (destination->data == nullptr) {
        throw_java(env, "java/lang/OutOfMemoryError", "unable to copy byte array");
        return false;
    }
    env->GetByteArrayRegion(
        source,
        0,
        length,
        reinterpret_cast<jbyte *>(destination->data));
    return !env->ExceptionCheck();
}

bool copy_int_array(JNIEnv *env, jintArray source, NativeInts *destination)
{
    if (source == nullptr || destination == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "int array must not be null");
        return false;
    }
    const jsize length = env->GetArrayLength(source);
    if (env->ExceptionCheck()) {
        return false;
    }
    destination->count = static_cast<size_t>(length);
    if (length == 0) {
        return true;
    }
    size_t byte_size = 0;
    if (!checked_multiply(destination->count, sizeof(jint), &byte_size)) {
        throw_java(env, "java/lang/IllegalArgumentException", "int array size overflows size_t");
        return false;
    }
    destination->data = static_cast<jint *>(std::malloc(byte_size));
    if (destination->data == nullptr) {
        throw_java(env, "java/lang/OutOfMemoryError", "unable to copy int array");
        return false;
    }
    env->GetIntArrayRegion(source, 0, length, destination->data);
    return !env->ExceptionCheck();
}

bool validate_minimum_size(JNIEnv *env, size_t actual, size_t required, const char *message)
{
    if (actual < required) {
        throw_java(env, "java/lang/IllegalArgumentException", message);
        return false;
    }
    return true;
}

bool validate_media_not_empty(JNIEnv *env, const NativeBytes &media)
{
    if (media.size == 0) {
        throw_java(env, "java/io/IOException", "encoded media must not be empty");
        return false;
    }
    return true;
}

bool validate_flag_output(JNIEnv *env, jintArray output_flags)
{
    if (output_flags == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "frame flag output must not be null");
        return false;
    }
    const jsize length = env->GetArrayLength(output_flags);
    if (env->ExceptionCheck()) {
        return false;
    }
    if (length < 1) {
        throw_java(env, "java/lang/IllegalArgumentException", "frame flag output must contain one element");
        return false;
    }
    return true;
}

jbyteArray owned_buffer_to_java(JNIEnv *env, hmc_owned_buffer_t *owned)
{
    if (owned == nullptr) {
        throw_java(env, "java/lang/IllegalStateException", "native output buffer is missing");
        return nullptr;
    }
    if (owned->size > static_cast<size_t>(std::numeric_limits<jsize>::max())) {
        hmc_owned_buffer_release(owned);
        throw_java(env, "java/lang/IllegalArgumentException", "native output exceeds Java array limit");
        return nullptr;
    }

    const jsize length = static_cast<jsize>(owned->size);
    jbyteArray result = env->NewByteArray(length);
    if (result == nullptr || env->ExceptionCheck()) {
        hmc_owned_buffer_release(owned);
        return nullptr;
    }
    if (length > 0) {
        env->SetByteArrayRegion(
            result,
            0,
            length,
            reinterpret_cast<const jbyte *>(owned->data));
    }
    hmc_owned_buffer_release(owned);
    if (env->ExceptionCheck()) {
        return nullptr;
    }
    return result;
}

bool write_frame_flags(JNIEnv *env, jintArray output_flags, hmc_frame_flags_t frame_flags)
{
    const jint value = static_cast<jint>(frame_flags);
    env->SetIntArrayRegion(output_flags, 0, 1, &value);
    return !env->ExceptionCheck();
}

template <typename T>
jlong to_handle(T *pointer)
{
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(pointer));
}

template <typename T>
T *from_handle(JNIEnv *env, jlong handle, const char *message)
{
    if (handle == 0) {
        throw_java(env, "java/lang/IllegalStateException", message);
        return nullptr;
    }
    const auto raw = static_cast<uintptr_t>(static_cast<uint64_t>(handle));
    return reinterpret_cast<T *>(raw);
}

bool valid_positive_index(JNIEnv *env, jint index)
{
    if (index < 0) {
        throw_java(env, "java/lang/IllegalArgumentException", "AVI frame index must not be negative");
        return false;
    }
    return true;
}

} // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeAbiVersion(JNIEnv *, jobject)
{
    return static_cast<jint>(hmc_abi_version());
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeMsv1Encode(
    JNIEnv *env,
    jobject,
    jbyteArray rgba_array,
    jint width,
    jint height,
    jbyteArray previous_array,
    jint skip_threshold,
    jboolean force_key,
    jintArray output_flags)
{
    if (!validate_flag_output(env, output_flags)) {
        return nullptr;
    }
    size_t required = 0;
    if (!required_rgba_bytes(env, width, height, &required)) {
        return nullptr;
    }
    if (skip_threshold < 0) {
        throw_java(env, "java/lang/IllegalArgumentException", "skip threshold must not be negative");
        return nullptr;
    }

    NativeBytes rgba;
    if (!copy_byte_array(env, rgba_array, &rgba) ||
        !validate_minimum_size(env, rgba.size, required, "RGBA array is shorter than width*height*4")) {
        return nullptr;
    }

    NativeBytes previous;
    const uint8_t *previous_data = nullptr;
    size_t previous_size = 0;
    if (previous_array != nullptr) {
        if (!copy_byte_array(env, previous_array, &previous) ||
            !validate_minimum_size(
                env,
                previous.size,
                required,
                "previous RGBA array is shorter than width*height*4")) {
            return nullptr;
        }
        previous_data = previous.data;
        previous_size = previous.size;
    }

    hmc_msv1_encoder_config_t config{};
    if (!status_ok(env, hmc_msv1_encoder_config_init(&config, sizeof(config)))) {
        return nullptr;
    }
    config.width = static_cast<uint32_t>(width);
    config.height = static_cast<uint32_t>(height);
    config.skip_threshold = static_cast<uint32_t>(skip_threshold);

    hmc_owned_buffer_t output{nullptr, 0};
    hmc_frame_flags_t frame_flags = HMC_FRAME_FLAG_NONE;
    const hmc_encode_flags_t encode_flags =
        force_key == JNI_TRUE ? HMC_ENCODE_FLAG_FORCE_KEY : HMC_ENCODE_FLAG_NONE;
    if (!status_ok(
            env,
            hmc_msv1_encode(
                &config,
                rgba.data,
                rgba.size,
                previous_data,
                previous_size,
                encode_flags,
                &output,
                &frame_flags))) {
        hmc_owned_buffer_release(&output);
        return nullptr;
    }

    jbyteArray result = owned_buffer_to_java(env, &output);
    if (result == nullptr || !write_frame_flags(env, output_flags, frame_flags)) {
        return nullptr;
    }
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeMsv1Decode(
    JNIEnv *env,
    jobject,
    jbyteArray encoded_array,
    jint width,
    jint height,
    jintArray persistent_argb)
{
    size_t required_bytes = 0;
    if (!required_rgba_bytes(env, width, height, &required_bytes)) {
        return;
    }
    const size_t required_pixels = required_bytes / 4;

    NativeBytes encoded;
    NativeInts pixels;
    if (!copy_byte_array(env, encoded_array, &encoded) ||
        !validate_media_not_empty(env, encoded) ||
        !copy_int_array(env, persistent_argb, &pixels) ||
        !validate_minimum_size(
            env,
            pixels.count,
            required_pixels,
            "ARGB array is shorter than width*height")) {
        return;
    }

    hmc_msv1_decoder_config_t config{};
    if (!status_ok(env, hmc_msv1_decoder_config_init(&config, sizeof(config)))) {
        return;
    }
    config.width = static_cast<uint32_t>(width);
    config.height = static_cast<uint32_t>(height);
    if (!status_ok(
            env,
            hmc_msv1_decode(
                &config,
                encoded.data,
                encoded.size,
                reinterpret_cast<uint32_t *>(pixels.data),
                pixels.count))) {
        return;
    }
    env->SetIntArrayRegion(
        persistent_argb,
        0,
        static_cast<jsize>(required_pixels),
        pixels.data);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeCinepakEncoderCreate(
    JNIEnv *env,
    jobject,
    jint width,
    jint height,
    jint quality,
    jint v1_size,
    jint v4_size,
    jint refine_iterations,
    jint chroma_weight,
    jint strips,
    jint skip_threshold,
    jint key_interval)
{
    size_t ignored = 0;
    if (!required_rgba_bytes(env, width, height, &ignored)) {
        return 0;
    }
    hmc_cinepak_encoder_config_t config{};
    if (!status_ok(env, hmc_cinepak_encoder_config_init(&config, sizeof(config)))) {
        return 0;
    }
    config.width = static_cast<uint32_t>(width);
    config.height = static_cast<uint32_t>(height);
    config.quality = quality;
    config.v1_size = v1_size;
    config.v4_size = v4_size;
    config.refine_iterations = refine_iterations;
    config.chroma_weight = chroma_weight;
    config.strips = strips;
    config.skip_threshold = skip_threshold;
    config.key_interval = key_interval;

    hmc_cinepak_encoder_t *encoder = nullptr;
    if (!status_ok(env, hmc_cinepak_encoder_create(&config, &encoder))) {
        return 0;
    }
    return to_handle(encoder);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeCinepakEncoderEncode(
    JNIEnv *env,
    jobject,
    jlong handle,
    jbyteArray rgba_array,
    jboolean force_key,
    jintArray output_flags)
{
    hmc_cinepak_encoder_t *encoder =
        from_handle<hmc_cinepak_encoder_t>(env, handle, "Cinepak encoder is closed");
    if (encoder == nullptr || !validate_flag_output(env, output_flags)) {
        return nullptr;
    }
    NativeBytes rgba;
    if (!copy_byte_array(env, rgba_array, &rgba)) {
        return nullptr;
    }

    hmc_owned_buffer_t output{nullptr, 0};
    hmc_frame_flags_t frame_flags = HMC_FRAME_FLAG_NONE;
    const hmc_encode_flags_t encode_flags =
        force_key == JNI_TRUE ? HMC_ENCODE_FLAG_FORCE_KEY : HMC_ENCODE_FLAG_NONE;
    if (!status_ok(
            env,
            hmc_cinepak_encoder_encode(
                encoder,
                rgba.data,
                rgba.size,
                encode_flags,
                &output,
                &frame_flags))) {
        hmc_owned_buffer_release(&output);
        return nullptr;
    }
    jbyteArray result = owned_buffer_to_java(env, &output);
    if (result == nullptr || !write_frame_flags(env, output_flags, frame_flags)) {
        return nullptr;
    }
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeCinepakEncoderReset(
    JNIEnv *env,
    jobject,
    jlong handle)
{
    hmc_cinepak_encoder_t *encoder =
        from_handle<hmc_cinepak_encoder_t>(env, handle, "Cinepak encoder is closed");
    if (encoder != nullptr) {
        status_ok(env, hmc_cinepak_encoder_reset(encoder));
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeCinepakEncoderDestroy(
    JNIEnv *,
    jobject,
    jlong handle)
{
    if (handle != 0) {
        const auto raw = static_cast<uintptr_t>(static_cast<uint64_t>(handle));
        hmc_cinepak_encoder_destroy(reinterpret_cast<hmc_cinepak_encoder_t *>(raw));
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeCinepakDecoderCreate(
    JNIEnv *env,
    jobject,
    jint width,
    jint height)
{
    size_t ignored = 0;
    if (!required_rgba_bytes(env, width, height, &ignored)) {
        return 0;
    }
    hmc_cinepak_decoder_config_t config{};
    if (!status_ok(env, hmc_cinepak_decoder_config_init(&config, sizeof(config)))) {
        return 0;
    }
    config.width = static_cast<uint32_t>(width);
    config.height = static_cast<uint32_t>(height);
    hmc_cinepak_decoder_t *decoder = nullptr;
    if (!status_ok(env, hmc_cinepak_decoder_create(&config, &decoder))) {
        return 0;
    }
    return to_handle(decoder);
}

extern "C" JNIEXPORT void JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeCinepakDecoderDecode(
    JNIEnv *env,
    jobject,
    jlong handle,
    jbyteArray encoded_array,
    jintArray output_argb)
{
    hmc_cinepak_decoder_t *decoder =
        from_handle<hmc_cinepak_decoder_t>(env, handle, "Cinepak decoder is closed");
    if (decoder == nullptr) {
        return;
    }
    NativeBytes encoded;
    NativeInts pixels;
    if (!copy_byte_array(env, encoded_array, &encoded) ||
        !validate_media_not_empty(env, encoded) ||
        !copy_int_array(env, output_argb, &pixels)) {
        return;
    }
    if (!status_ok(
            env,
            hmc_cinepak_decoder_decode(
                decoder,
                encoded.data,
                encoded.size,
                reinterpret_cast<uint32_t *>(pixels.data),
                pixels.count))) {
        return;
    }
    env->SetIntArrayRegion(
        output_argb,
        0,
        static_cast<jsize>(pixels.count),
        pixels.data);
}

extern "C" JNIEXPORT void JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeCinepakDecoderReset(
    JNIEnv *env,
    jobject,
    jlong handle)
{
    hmc_cinepak_decoder_t *decoder =
        from_handle<hmc_cinepak_decoder_t>(env, handle, "Cinepak decoder is closed");
    if (decoder != nullptr) {
        status_ok(env, hmc_cinepak_decoder_reset(decoder));
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeCinepakDecoderDestroy(
    JNIEnv *,
    jobject,
    jlong handle)
{
    if (handle != 0) {
        const auto raw = static_cast<uintptr_t>(static_cast<uint64_t>(handle));
        hmc_cinepak_decoder_destroy(reinterpret_cast<hmc_cinepak_decoder_t *>(raw));
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeAviMuxerCreate(
    JNIEnv *env,
    jobject,
    jint width,
    jint height,
    jint frame_rate_num,
    jint frame_rate_den,
    jint handler_fourcc,
    jint compression_fourcc,
    jint bit_count)
{
    if (width <= 0 || height <= 0 || frame_rate_num <= 0 || frame_rate_den <= 0 || bit_count <= 0) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid AVI muxer configuration");
        return 0;
    }
    hmc_avi_muxer_config_t config{};
    if (!status_ok(env, hmc_avi_muxer_config_init(&config, sizeof(config)))) {
        return 0;
    }
    config.width = static_cast<uint32_t>(width);
    config.height = static_cast<uint32_t>(height);
    config.frame_rate_num = static_cast<uint32_t>(frame_rate_num);
    config.frame_rate_den = static_cast<uint32_t>(frame_rate_den);
    config.handler_fourcc = static_cast<uint32_t>(handler_fourcc);
    config.compression_fourcc = static_cast<uint32_t>(compression_fourcc);
    config.bit_count = static_cast<uint32_t>(bit_count);
    hmc_avi_muxer_t *muxer = nullptr;
    if (!status_ok(env, hmc_avi_muxer_create(&config, &muxer))) {
        return 0;
    }
    return to_handle(muxer);
}

extern "C" JNIEXPORT void JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeAviMuxerAddFrame(
    JNIEnv *env,
    jobject,
    jlong handle,
    jbyteArray bytes_array,
    jint frame_flags)
{
    hmc_avi_muxer_t *muxer = from_handle<hmc_avi_muxer_t>(env, handle, "AVI muxer is closed");
    if (muxer == nullptr) {
        return;
    }
    NativeBytes bytes;
    if (!copy_byte_array(env, bytes_array, &bytes)) {
        return;
    }
    status_ok(
        env,
        hmc_avi_muxer_add_frame(
            muxer,
            bytes.data,
            bytes.size,
            static_cast<hmc_frame_flags_t>(frame_flags)));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeAviMuxerFinish(
    JNIEnv *env,
    jobject,
    jlong handle)
{
    hmc_avi_muxer_t *muxer = from_handle<hmc_avi_muxer_t>(env, handle, "AVI muxer is closed");
    if (muxer == nullptr) {
        return nullptr;
    }
    hmc_owned_buffer_t output{nullptr, 0};
    if (!status_ok(env, hmc_avi_muxer_finish(muxer, &output))) {
        hmc_owned_buffer_release(&output);
        return nullptr;
    }
    return owned_buffer_to_java(env, &output);
}

extern "C" JNIEXPORT void JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeAviMuxerDestroy(
    JNIEnv *,
    jobject,
    jlong handle)
{
    if (handle != 0) {
        const auto raw = static_cast<uintptr_t>(static_cast<uint64_t>(handle));
        hmc_avi_muxer_destroy(reinterpret_cast<hmc_avi_muxer_t *>(raw));
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeAviReaderCreate(
    JNIEnv *env,
    jobject,
    jbyteArray bytes_array)
{
    NativeBytes bytes;
    if (!copy_byte_array(env, bytes_array, &bytes) || !validate_media_not_empty(env, bytes)) {
        return 0;
    }
    hmc_avi_reader_t *reader = nullptr;
    if (!status_ok(env, hmc_avi_reader_create_copy(bytes.data, bytes.size, &reader))) {
        return 0;
    }
    return to_handle(reader);
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeAviReaderInfo(
    JNIEnv *env,
    jobject,
    jlong handle)
{
    hmc_avi_reader_t *reader = from_handle<hmc_avi_reader_t>(env, handle, "AVI reader is closed");
    if (reader == nullptr) {
        return nullptr;
    }
    hmc_avi_info_t info{};
    info.struct_size = sizeof(info);
    if (!status_ok(env, hmc_avi_reader_get_info(reader, &info))) {
        return nullptr;
    }
    const jint values[] = {
        static_cast<jint>(info.width),
        static_cast<jint>(info.height),
        static_cast<jint>(info.usec_per_frame),
        static_cast<jint>(info.frame_rate_num),
        static_cast<jint>(info.frame_rate_den),
        static_cast<jint>(info.handler_fourcc),
        static_cast<jint>(info.compression_fourcc),
        static_cast<jint>(info.bit_count),
        static_cast<jint>(info.frame_count),
    };
    jintArray result = env->NewIntArray(9);
    if (result == nullptr || env->ExceptionCheck()) {
        return nullptr;
    }
    env->SetIntArrayRegion(result, 0, 9, values);
    return env->ExceptionCheck() ? nullptr : result;
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeAviReaderFrameInfo(
    JNIEnv *env,
    jobject,
    jlong handle,
    jint index)
{
    hmc_avi_reader_t *reader = from_handle<hmc_avi_reader_t>(env, handle, "AVI reader is closed");
    if (reader == nullptr || !valid_positive_index(env, index)) {
        return nullptr;
    }
    hmc_avi_frame_info_t info{};
    info.struct_size = sizeof(info);
    if (!status_ok(
            env,
            hmc_avi_reader_get_frame_info(reader, static_cast<uint32_t>(index), &info))) {
        return nullptr;
    }
    const jint values[] = {
        static_cast<jint>(info.chunk_fourcc),
        static_cast<jint>(info.avi_index_flags),
        static_cast<jint>(info.frame_flags),
    };
    jintArray result = env->NewIntArray(3);
    if (result == nullptr || env->ExceptionCheck()) {
        return nullptr;
    }
    env->SetIntArrayRegion(result, 0, 3, values);
    return env->ExceptionCheck() ? nullptr : result;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeAviReaderCopyFrame(
    JNIEnv *env,
    jobject,
    jlong handle,
    jint index)
{
    hmc_avi_reader_t *reader = from_handle<hmc_avi_reader_t>(env, handle, "AVI reader is closed");
    if (reader == nullptr || !valid_positive_index(env, index)) {
        return nullptr;
    }
    hmc_owned_buffer_t frame{nullptr, 0};
    if (!status_ok(
            env,
            hmc_avi_reader_copy_frame(reader, static_cast<uint32_t>(index), &frame))) {
        hmc_owned_buffer_release(&frame);
        return nullptr;
    }
    return owned_buffer_to_java(env, &frame);
}

extern "C" JNIEXPORT void JNICALL
Java_com_honeygui_honeybox_NativeMediaCodec_nativeAviReaderDestroy(
    JNIEnv *,
    jobject,
    jlong handle)
{
    if (handle != 0) {
        const auto raw = static_cast<uintptr_t>(static_cast<uint64_t>(handle));
        hmc_avi_reader_destroy(reinterpret_cast<hmc_avi_reader_t *>(raw));
    }
}
