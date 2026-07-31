# C++17 Honey Media Core Android Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox state so work can resume safely after interruption.

**Goal:** Replace the Android production implementations of Cinepak, MSV1, and AVI handling with one portable C++17 core exposed through a stable C ABI, while preserving the Flutter contract and proving the same core builds and passes conformance tests on Windows.

**Architecture:** A standalone `media_core` library owns only byte-oriented codec and container logic. Its public surface is a C99 header with opaque handles and explicit buffer ownership. Android adds a narrow JNI library and a Kotlin facade; `VideoConverter` and `CameraEncoder` continue to own Android frame extraction, crop/scale, JPEG, H.264, progress, cancellation, and Flutter `MethodChannel` behavior. Windows builds the same standalone core and native tests without adding a Windows Flutter converter UI.

**Tech Stack:** C++17, C99 ABI, CMake 3.18+, Android NDK/JNI, Kotlin, Gradle/Flutter, MSVC on Windows, CTest, JUnit 4 reference-vector generation.

**Global Constraints:**

- Keep every existing Flutter method name, argument, result map, progress event, cache path, and error mapping unchanged.
- Do not move Android `Bitmap`, `Canvas`, `MediaMetadataRetriever`, `Movie`, `MediaCodec`, JPEG, BLE, or product workflow code into `media_core`.
- Do not add FFmpeg or another codec/container dependency.
- Treat all external sizes and offsets as untrusted; validate multiplication/addition before allocation or indexing.
- Keep C++ exceptions and RTTI out of the public/runtime path. No exception may cross C or JNI boundaries.
- The public library/CMake target is `honey_media_core`; its header is `honey_media_core/media_core.h`, public C symbols/types use `hmc_`, macros/status values use `HMC_`, and internal C++ namespaces use `honey::media`.
- Fixed-layout transport structs `hmc_owned_buffer_t` and `hmc_bytes_view_t` contain only pointer/size fields and do not contain `struct_size`; extensible configuration structs introduced by later tasks begin with `struct_size`.
- The library owns every returned `hmc_owned_buffer_t`; callers release it with `hmc_owned_buffer_release`.
- A borrowed `hmc_bytes_view_t` returned by an AVI reader remains valid only until `hmc_avi_reader_destroy`.
- First prove Kotlin/C++ byte parity, then switch production call sites, then move legacy Kotlin codec implementations to test-only reference sources.
- A passing host build is not a device-runtime claim. Record Android build, emulator/device, and physical eBadge checks separately.

---

## Task 1: Establish the standalone C ABI and native test harness

**Files:**

- Create: `media_core/CMakeLists.txt`
- Create: `media_core/include/honey_media_core/media_core.h`
- Create: `media_core/src/c_api.cpp`
- Create: `media_core/src/core_types.hpp`
- Create: `media_core/tests/CMakeLists.txt`
- Create: `media_core/tests/test_main.cpp`
- Create: `media_core/tests/test_support.hpp`
- Create: `scripts/test-media-core-windows.ps1`
- Modify: `.gitignore`

**Interfaces:**

```c
#define HMC_MEDIA_ABI_VERSION 1u
#define HMC_MEDIA_FOURCC(a, b, c, d) \
    ((uint32_t)(uint8_t)(a) | ((uint32_t)(uint8_t)(b) << 8u) | \
     ((uint32_t)(uint8_t)(c) << 16u) | ((uint32_t)(uint8_t)(d) << 24u))

typedef enum hmc_status {
    HMC_STATUS_OK = 0,
    HMC_STATUS_INVALID_ARGUMENT = 1,
    HMC_STATUS_OUT_OF_MEMORY = 2,
    HMC_STATUS_MALFORMED_DATA = 3,
    HMC_STATUS_OVERFLOW = 4,
    HMC_STATUS_INTERNAL_ERROR = 5
} hmc_status_t;

typedef struct hmc_owned_buffer {
    uint8_t *data;
    size_t size;
} hmc_owned_buffer_t;

typedef struct hmc_bytes_view {
    const uint8_t *data;
    size_t size;
} hmc_bytes_view_t;

uint32_t hmc_abi_version(void);
const char *hmc_status_message(hmc_status_t status);
void hmc_owned_buffer_release(hmc_owned_buffer_t *buffer);
```

- [ ] Write `test_main.cpp` with a small registration/assertion harness and initial tests that require ABI version `1`, stable non-empty status messages, and safe release of `{NULL, 0}`.
- [ ] Add `scripts/test-media-core-windows.ps1`. It must resolve `cmake.exe` from `PATH` or the current Visual Studio installation, use repository-relative source/build paths, and return the failing command's exit code.
- [ ] Run the native configure/build script and confirm the test target fails because the public header and functions do not exist:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\test-media-core-windows.ps1 -Configuration Debug
  ```

- [ ] Add `media_core.h`, internal checked-size helpers in `core_types.hpp`, and the minimum `c_api.cpp` implementation. Use `extern "C"` guards and fixed-width integer types.
- [ ] Make CMake build `honey_media_core` as a static library with public include directory `media_core/include`, C++17 required, extensions disabled, and warning-as-error options for MSVC and Clang/GCC.
- [ ] Add only generated native build directories such as `/build/media-core-*` to `.gitignore`; do not ignore fixture binaries under `media_core/tests/fixtures`.
- [ ] Run:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\test-media-core-windows.ps1 -Configuration Debug
  ```

  Expected: ABI and buffer-ownership tests pass on Windows.

- [ ] Commit:

  ```powershell
  git add .gitignore media_core scripts/test-media-core-windows.ps1
  git commit -m "feat: 建立跨平台媒体核心C接口"
  ```

---

## Task 2: Freeze deterministic Kotlin reference vectors

**Files:**

- Modify: `android/app/build.gradle`
- Modify: `android/gradle/wrapper/gradle-wrapper.properties`
- Create: `scripts/run-android-gradle.ps1`
- Create: `android/app/src/test/kotlin/com/honeygui/honeybox/MediaReferenceFixturesTest.kt`
- Create: `media_core/tests/fixtures/README.md`
- Create: `media_core/tests/fixtures/input_8x8_a.rgba`
- Create: `media_core/tests/fixtures/input_8x8_b.rgba`
- Create: `media_core/tests/fixtures/msv1_key.bin`
- Create: `media_core/tests/fixtures/msv1_all_skip.bin`
- Create: `media_core/tests/fixtures/msv1_inter.bin`
- Create: `media_core/tests/fixtures/msv1_key.argb`
- Create: `media_core/tests/fixtures/msv1_all_skip.argb`
- Create: `media_core/tests/fixtures/msv1_inter.argb`
- Create: `media_core/tests/fixtures/msvc_sample.avi`
- Create: `media_core/tests/fixtures/cinepak_key.bin`
- Create: `media_core/tests/fixtures/cinepak_all_skip.bin`
- Create: `media_core/tests/fixtures/cinepak_inter.bin`
- Create: `media_core/tests/fixtures/cinepak_key.argb`
- Create: `media_core/tests/fixtures/cinepak_all_skip.argb`
- Create: `media_core/tests/fixtures/cinepak_inter.argb`
- Create: `media_core/tests/fixtures/cvid_sample.avi`
- Create: `media_core/tests/reference_fixture_test.cpp`
- Modify: `media_core/tests/CMakeLists.txt`

**Reference input definition:**

```kotlin
private fun rgbaA(): ByteArray = ByteArray(8 * 8 * 4).also { out ->
    for (y in 0 until 8) for (x in 0 until 8) {
        val p = (y * 8 + x) * 4
        out[p] = (x * 31).toByte()
        out[p + 1] = (y * 29).toByte()
        out[p + 2] = ((x * 17 + y * 13) and 0xff).toByte()
        out[p + 3] = 0xff.toByte()
    }
}

private fun rgbaB(): ByteArray = rgbaA().also { out ->
    for (y in 0 until 4) for (x in 0 until 4) {
        val p = (y * 8 + x) * 4
        out[p] = 0xf0.toByte()
        out[p + 1] = 0x30
        out[p + 2] = 0x80.toByte()
    }
}
```

- [ ] Add `scripts/run-android-gradle.ps1`. Resolve the root from `$PSScriptRoot`, require a usable `JAVA_HOME`, use `android/gradlew.bat` when available, otherwise unescape the exact HTTPS wrapper URL, require and verify its SHA-256 under ignored `build/tools`, expand it, and invoke the matching `bin/gradle.bat`. If ignored `android/local.properties` is absent, derive and validate `flutter.sdk` from `FLUTTER_ROOT` and `sdk.dir` from `ANDROID_SDK_ROOT`; invoke Gradle from `android` and return its exact exit code.
- [ ] Add JUnit 4.13.2 as `testImplementation` and write a reference test that first asserts every listed fixture exists. Run:

  ```powershell
  $env:PUB_CACHE='F:\sourcecode\8773EWE\.codex-build-tools\pub-cache'
  & 'F:\sourcecode\8773EWE\.codex-build-tools\flutter\bin\flutter.bat' test --no-pub
  & .\scripts\run-android-gradle.ps1 `
    :app:testDebugUnitTest `
    --tests com.honeygui.honeybox.MediaReferenceFixturesTest
  ```

  Expected: the new unit test fails because fixture files are absent.

- [ ] Add JUnit `testImplementation "junit:junit:4.13.2"`, forward `ebadge.repositoryRoot` and the JVM property `ebadge.regenerateFixtures` (default `false`) to every Gradle `Test` worker, and add the Gradle 8.13 binary ZIP checksum `20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78`.
- [ ] Implement an explicit regeneration path selected by JVM property `ebadge.regenerateFixtures=true`. It writes RGBA, MSV1 key/all-skip/inter frames, sequential persistent ARGB snapshots, MSVC AVI at 10 FPS with `[true, false, false]` flags, and Cinepak key/all-skip/inter frames plus sequential decoder snapshots and CVID AVI. Normal mode regenerates bytes only in memory and byte-compares every committed fixture without writing; ARGB is explicitly `BB GG RR AA` little-endian. Assert a one-channel RGB555 step skips at threshold 1 and does not skip at 0.
- [ ] Generate once:

  ```powershell
  & .\scripts\run-android-gradle.ps1 `
    :app:testDebugUnitTest `
    --tests com.honeygui.honeybox.MediaReferenceFixturesTest `
    -Debadge.regenerateFixtures=true
  ```

- [ ] Add `README.md` documenting generator command, dimensions, encoder options/state order, 10 FPS/key flags, explicit ARGB byte order, and the rule that fixture changes require intentional Kotlin-reference review.
- [ ] Add a native test that loads every file, checks non-zero sizes, validates the two RGBA files are exactly 256 bytes, and validates both AVI files contain `RIFF` at byte 0 and `AVI ` at byte 8.
- [ ] Run the normal Kotlin fixture test and native CTest. Expected: both pass without modifying fixture files.
- [ ] Commit:

  ```powershell
  git add android/app/build.gradle android/app/src/test media_core/tests scripts/run-android-gradle.ps1
  git commit -m "test: 固化Kotlin媒体格式基准数据"
  ```

---

## Task 3: Port AVI muxing and parsing with strict bounds checks

**Files:**

- Modify: `media_core/include/honey_media_core/media_core.h`
- Create: `media_core/src/avi.hpp`
- Create: `media_core/src/avi.cpp`
- Modify: `media_core/src/c_api.cpp`
- Create: `media_core/tests/avi_test.cpp`
- Modify: `media_core/tests/CMakeLists.txt`

**Interfaces:**

```c
typedef struct hmc_avi_reader hmc_avi_reader_t;

typedef struct hmc_avi_build_config {
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
    uint32_t fps;
    uint32_t fourcc;
    uint16_t bit_count;
    uint16_t reserved;
} hmc_avi_build_config_t;

hmc_status_t hmc_avi_build(
    const hmc_avi_build_config_t *config,
    const hmc_bytes_view_t *frames,
    const uint8_t *key_flags,
    size_t frame_count,
    hmc_owned_buffer_t *output);

hmc_status_t hmc_avi_reader_create(
    const uint8_t *data,
    size_t size,
    hmc_avi_reader_t **reader);
void hmc_avi_reader_destroy(hmc_avi_reader_t *reader);
uint32_t hmc_avi_reader_width(const hmc_avi_reader_t *reader);
uint32_t hmc_avi_reader_height(const hmc_avi_reader_t *reader);
uint32_t hmc_avi_reader_usec_per_frame(const hmc_avi_reader_t *reader);
size_t hmc_avi_reader_frame_count(const hmc_avi_reader_t *reader);
hmc_status_t hmc_avi_reader_frame(
    const hmc_avi_reader_t *reader,
    size_t index,
    hmc_bytes_view_t *frame);
```

- [ ] Write failing tests for empty frame lists, odd-sized frame padding, default/fallback FPS behavior, CVID/MSVC fourcc and bit count, `idx1` offsets/flags, round-trip parsing, truncated chunks, oversized chunk lengths, invalid RIFF signatures, null arguments, and out-of-range frame indexes.
- [ ] Run CTest and confirm failures because AVI functions are absent.
- [ ] Implement little-endian writer/reader helpers with checked `size_t` addition and multiplication. The reader must own a copy of input bytes and frame views must point into that owned copy.
- [ ] Match `CvidAviMuxer` exactly for CVID: lowercase `cvid`, 24-bit `strf`, first `movi` frame offset `4`, and key status from frame byte zero when `key_flags == NULL`.
- [ ] Match `SoftwareCodec.buildAvi` exactly for MSVC/MJPG, including caller-provided key flags and `biSizeImage = width * height * 2`.
- [ ] Add exact byte comparisons against `cvid_sample.avi` and `msvc_sample.avi`.
- [ ] Run CTest with malformed/truncated corpus tests and confirm no crash, out-of-bounds access, or partial output buffer escapes.
- [ ] Commit:

  ```powershell
  git add media_core
  git commit -m "feat: 用C++实现AVI封装与解析"
  ```

---

## Task 4: Port MSV1 encode/decode

**Files:**

- Modify: `media_core/include/honey_media_core/media_core.h`
- Create: `media_core/src/msv1.hpp`
- Create: `media_core/src/msv1.cpp`
- Modify: `media_core/src/c_api.cpp`
- Create: `media_core/tests/msv1_test.cpp`
- Modify: `media_core/tests/CMakeLists.txt`

**Interfaces:**

```c
hmc_status_t hmc_msv1_encode(
    const uint8_t *rgba,
    size_t rgba_size,
    uint32_t width,
    uint32_t height,
    const uint8_t *previous_rgba,
    size_t previous_rgba_size,
    uint32_t skip_threshold,
    hmc_owned_buffer_t *output);

hmc_status_t hmc_msv1_decode(
    const uint8_t *encoded,
    size_t encoded_size,
    uint32_t width,
    uint32_t height,
    uint32_t *argb,
    size_t argb_pixel_count);
```

- [ ] Write failing tests for solid-color blocks, two-color blocks, key-frame fixture equality, inter-frame fixture equality, persistent decode output for skipped blocks, dimensions not divisible by four, short RGBA/ARGB buffers, truncated words, malformed skip runs, and size-overflow dimensions.
- [ ] Run CTest and confirm failures because MSV1 functions are absent.
- [ ] Port the Kotlin scan order, RGB555 conversion, skip-color collision handling, luminance clustering, mask inversion, bottom-up block order, skip-run splitting at `0x3ff`, and terminating word using fixed-width arithmetic.
- [ ] Port decode behavior while replacing silent Kotlin truncation returns with `HMC_STATUS_MALFORMED_DATA`. Preserve previous pixels for valid skipped blocks.
- [ ] Compare encoded bytes exactly with `msv1_key.bin` and `msv1_inter.bin`; compare decoded pixels exactly with the committed ARGB fixtures.
- [ ] Run CTest in Debug and Release configurations.
- [ ] Commit:

  ```powershell
  git add media_core
  git commit -m "feat: 用C++实现MSV1编解码"
  ```

---

## Task 5: Port the stateful Cinepak decoder

**Files:**

- Modify: `media_core/include/honey_media_core/media_core.h`
- Create: `media_core/src/cinepak_common.hpp`
- Create: `media_core/src/cinepak_decoder.hpp`
- Create: `media_core/src/cinepak_decoder.cpp`
- Modify: `media_core/src/c_api.cpp`
- Create: `media_core/tests/cinepak_decoder_test.cpp`
- Modify: `media_core/tests/CMakeLists.txt`

**Interfaces:**

```c
typedef struct hmc_cinepak_decoder hmc_cinepak_decoder_t;

hmc_status_t hmc_cinepak_decoder_create(
    uint32_t width,
    uint32_t height,
    hmc_cinepak_decoder_t **decoder);
void hmc_cinepak_decoder_reset(hmc_cinepak_decoder_t *decoder);
void hmc_cinepak_decoder_destroy(hmc_cinepak_decoder_t *decoder);
hmc_status_t hmc_cinepak_decoder_decode(
    hmc_cinepak_decoder_t *decoder,
    const uint8_t *encoded,
    size_t encoded_size,
    uint32_t *argb,
    size_t argb_pixel_count);
```

- [ ] Write failing tests for decoding the key/inter fixtures in sequence, reset behavior, incorrect frame dimensions, truncated 10-byte frame headers, truncated strip/chunk payloads, invalid strip counts, invalid codebook indexes, impossible frame/chunk sizes, and null/short output buffers.
- [ ] Run CTest and confirm failures because Cinepak decoder functions are absent.
- [ ] Port the codebook parsing, V1/V4 vector handling, strip row accumulator, signed U/V conversion, YUV reconstruction, and persistent inter-frame reconstruction.
- [ ] Require every read to pass a remaining-length check before consuming data. Return `HMC_STATUS_MALFORMED_DATA` on invalid frame structure and leave the caller output buffer unchanged on failure.
- [ ] Compare decoded ARGB exactly with `cinepak_key.argb` and `cinepak_inter.argb`.
- [ ] Parse `cvid_sample.avi` with the AVI reader, feed its frames sequentially to the decoder, and compare the same ARGB fixtures.
- [ ] Run CTest in Debug and Release configurations.
- [ ] Commit:

  ```powershell
  git add media_core
  git commit -m "feat: 用C++实现Cinepak解码"
  ```

---

## Task 6: Port the stateful Cinepak encoder

**Files:**

- Modify: `media_core/include/honey_media_core/media_core.h`
- Create: `media_core/src/cinepak_encoder.hpp`
- Create: `media_core/src/cinepak_encoder.cpp`
- Modify: `media_core/src/c_api.cpp`
- Create: `media_core/tests/cinepak_encoder_test.cpp`
- Modify: `media_core/tests/CMakeLists.txt`

**Interfaces:**

```c
typedef struct hmc_cinepak_encoder hmc_cinepak_encoder_t;

typedef struct hmc_cinepak_config {
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
} hmc_cinepak_config_t;

void hmc_cinepak_config_init(hmc_cinepak_config_t *config);
hmc_status_t hmc_cinepak_encoder_create(
    const hmc_cinepak_config_t *config,
    hmc_cinepak_encoder_t **encoder);
void hmc_cinepak_encoder_reset(hmc_cinepak_encoder_t *encoder);
void hmc_cinepak_encoder_destroy(hmc_cinepak_encoder_t *encoder);
hmc_status_t hmc_cinepak_encoder_encode(
    hmc_cinepak_encoder_t *encoder,
    const uint8_t *rgba,
    size_t rgba_size,
    uint8_t force_key,
    hmc_owned_buffer_t *output);
```

- [ ] Write failing tests for default config values, dimensions divisible by four, key-frame fixture equality, inter-frame fixture equality, explicit force-key, key interval, reset producing the original first frame, deterministic repeated runs, invalid options, short RGBA input, and overflow-sized dimensions.
- [ ] Run CTest and confirm failures because Cinepak encoder functions are absent.
- [ ] Port RGB-to-YUV fixed-point conversion, macroblock extraction, median-cut initialization, deterministic Lloyd refinement, V1/V4 decision, codebook emission, key/inter skip decisions, strip construction, frame assembly, and reconstruction state.
- [ ] Preserve Kotlin integer rounding and stable tie-breaking exactly; do not parallelize codebook generation in this version because output determinism is part of the format contract.
- [ ] Compare encoded bytes exactly with `cinepak_key.bin` and `cinepak_inter.bin`, then decode those C++ outputs and compare ARGB fixtures.
- [ ] Build C++ output into AVI and compare exactly with `cvid_sample.avi`.
- [ ] Run CTest in Debug and Release configurations.
- [ ] Commit:

  ```powershell
  git add media_core
  git commit -m "feat: 用C++实现Cinepak编码"
  ```

---

## Task 7: Add Android JNI binding and Kotlin ownership facade

**Files:**

- Modify: `android/app/build.gradle`
- Create: `android/app/src/main/cpp/CMakeLists.txt`
- Create: `android/app/src/main/cpp/native_media_jni.cpp`
- Create: `android/app/src/main/kotlin/com/honeygui/honeybox/NativeMediaCodec.kt`
- Create: `android/app/src/androidTest/kotlin/com/honeygui/honeybox/NativeMediaParityTest.kt`

**Kotlin facade:**

```kotlin
internal object NativeMediaCodec {
    init { System.loadLibrary("honey_media_jni") }

    external fun encodeMsv1(
        rgba: ByteArray,
        width: Int,
        height: Int,
        previousRgba: ByteArray?,
        skipThreshold: Int,
    ): ByteArray

    external fun decodeMsv1(
        encoded: ByteArray,
        width: Int,
        height: Int,
        persistentArgb: IntArray,
    )

    class CinepakEncoder internal constructor(internal var handle: Long) : AutoCloseable {
        external fun encode(rgba: ByteArray, forceKey: Boolean): ByteArray
        external fun reset()
        override external fun close()
    }
}
```

- [ ] Add `externalNativeBuild.cmake` pointing to `src/main/cpp/CMakeLists.txt`; link the shared JNI target `honey_media_jni` to the standalone static `honey_media_core`.
- [ ] Add AndroidX test runner configuration and a parity test that initially calls `NativeMediaCodec` for every committed fixture. Run it on the available emulator/device and confirm it fails because JNI symbols are absent.
- [ ] Implement JNI array-size validation, `GetByteArrayRegion`/`SetIntArrayRegion` transfers, opaque handle checks, deterministic `IllegalArgumentException` for invalid input, `IOException` for malformed media, and `IllegalStateException` for closed handles/internal failures.
- [ ] Never expose a native pointer directly to Dart. Store handles only in package-internal Kotlin wrapper objects and make `close()` idempotent.
- [ ] Implement JNI methods for MSV1, Cinepak encoder/decoder, AVI build, AVI parse metadata, and AVI frame extraction. Every returned `hmc_owned_buffer_t` must be copied into a Java byte array and released on all paths.
- [ ] Make the Android instrumentation parity test compare native output byte-for-byte with committed fixture files and the still-present Kotlin implementation.
- [ ] Run:

  ```powershell
  & 'F:\sourcecode\8773EWE\.codex-build-tools\flutter\bin\flutter.bat' build apk --debug
  & .\scripts\run-android-gradle.ps1 :app:connectedDebugAndroidTest
  ```

  Expected: JNI library packages into the APK and parity tests pass on at least one Android ABI.

- [ ] Commit:

  ```powershell
  git add android/app
  git commit -m "feat: 接入Android媒体核心JNI"
  ```

---

## Task 8: Switch Cinepak production paths to the native facade

**Files:**

- Modify: `android/app/src/main/kotlin/com/honeygui/honeybox/NativeMediaCodec.kt`
- Modify: `android/app/src/main/kotlin/com/honeygui/honeybox/VideoConverter.kt`
- Modify: `android/app/src/androidTest/kotlin/com/honeygui/honeybox/NativeMediaParityTest.kt`
- Modify: relevant Dart converter tests only if an existing test imports a renamed internal symbol

**Call-site mapping:**

- `CinepakDecoder.parseAvi` → `NativeMediaCodec.openAvi`
- `CinepakDecoder.Decoder` → `NativeMediaCodec.CinepakDecoder`
- `CinepakEncoder.Encoder` → `NativeMediaCodec.CinepakEncoder`
- `CvidAviMuxer.buildAvi` → `NativeMediaCodec.buildAvi` with `fourcc = "cvid"` and 24-bit header

- [ ] Add a failing production-path instrumentation test that converts a short deterministic 8×8 frame sequence and asserts the output equals `cvid_sample.avi` while the legacy Kotlin codec is made unavailable to that test through a test-only guard.
- [ ] Run the focused test and confirm the current `VideoConverter` still reaches Kotlin codec objects.
- [ ] Replace only Cinepak/AVI calls in `VideoConverter`. Preserve Android frame extraction, crop/scale, cancellation checks, progress frequency, output path, and result maps.
- [ ] Scope every native encoder/decoder/AVI reader with `use`/`try-finally` so cancellation and exceptions release handles.
- [ ] Run Android parity tests, existing Flutter tests, and a debug APK build.
- [ ] Manually inspect one converted CVID AVI on Android and confirm its width, height, frame count, FPS, and preview decode match the pre-switch output.
- [ ] Commit:

  ```powershell
  git add android/app/src/main/kotlin/com/honeygui/honeybox/NativeMediaCodec.kt `
          android/app/src/main/kotlin/com/honeygui/honeybox/VideoConverter.kt `
          android/app/src/androidTest
  git commit -m "refactor: 切换Cinepak生产路径到C++"
  ```

---

## Task 9: Switch MSV1 and shared AVI production paths

**Files:**

- Modify: `android/app/src/main/kotlin/com/honeygui/honeybox/NativeMediaCodec.kt`
- Modify: `android/app/src/main/kotlin/com/honeygui/honeybox/CameraEncoder.kt`
- Modify: `android/app/src/main/kotlin/com/honeygui/honeybox/SoftwareCodec.kt`
- Modify: `android/app/src/androidTest/kotlin/com/honeygui/honeybox/NativeMediaParityTest.kt`

**Boundary after this task:**

- Native: MSV1 encode/decode and AVI build.
- Kotlin/Android: JPEG `Bitmap.compress`, frame acquisition/transforms, H.264 `MediaCodec`, camera and product state.

- [ ] Add failing focused tests that make `CameraEncoder` MSV1 key/inter output and AVI match committed fixtures through the production facade.
- [ ] Run the tests and confirm production still calls `SoftwareCodec.encodeMsv1`, `decodeMsv1`, and `buildAvi`.
- [ ] Replace those three call paths with `NativeMediaCodec`. Keep `SoftwareCodec.encodeJpeg` in Kotlin.
- [ ] Rename `SoftwareCodec` to a JPEG-specific production object or reduce it to `encodeJpeg`; remove all codec/container helpers from that production source.
- [ ] Confirm MSV1 previous-RGBA lifetime and persistent decode-ARGB lifetime are unchanged across frames.
- [ ] Run Android parity tests, existing Flutter tests, debug APK build, and a short MSV1 capture/preview flow.
- [ ] Commit:

  ```powershell
  git add android/app/src/main/kotlin/com/honeygui/honeybox/CameraEncoder.kt `
          android/app/src/main/kotlin/com/honeygui/honeybox/NativeMediaCodec.kt `
          android/app/src/main/kotlin/com/honeygui/honeybox/SoftwareCodec.kt `
          android/app/src/androidTest
  git commit -m "refactor: 切换MSV1与AVI生产路径到C++"
  ```

---

## Task 10: Remove Kotlin codecs from production while preserving test reference provenance

**Files:**

- Delete: `android/app/src/main/kotlin/com/honeygui/honeybox/CinepakEncoder.kt`
- Delete: `android/app/src/main/kotlin/com/honeygui/honeybox/CinepakDecoder.kt`
- Delete: `android/app/src/main/kotlin/com/honeygui/honeybox/CvidAviMuxer.kt`
- Create: `android/app/src/test/kotlin/com/honeygui/honeybox/reference/LegacyCinepakEncoder.kt`
- Create: `android/app/src/test/kotlin/com/honeygui/honeybox/reference/LegacyCinepakDecoder.kt`
- Create: `android/app/src/test/kotlin/com/honeygui/honeybox/reference/LegacyCvidAviMuxer.kt`
- Create: `android/app/src/test/kotlin/com/honeygui/honeybox/reference/LegacyMsv1Codec.kt`
- Modify: `android/app/src/test/kotlin/com/honeygui/honeybox/MediaReferenceFixturesTest.kt`
- Modify: `android/app/src/main/kotlin/com/honeygui/honeybox/SoftwareCodec.kt`

- [ ] Before deleting production files, copy the reviewed Kotlin implementations into the `reference` test package with class names prefixed `Legacy` and a header stating they are immutable migration references, not shipping code.
- [ ] Make the normal fixture test import only the `reference` package and confirm it passes.
- [ ] Delete production Cinepak/muxer files and remove MSV1/AVI code from production `SoftwareCodec`.
- [ ] Run `rg` and require no production reference to the removed symbols:

  ```powershell
  rg -n "CinepakEncoder|CinepakDecoder|CvidAviMuxer|encodeMsv1|decodeMsv1|buildAvi" `
    android/app/src/main
  ```

  Expected: only `NativeMediaCodec` API names and JNI binding references remain; no legacy Kotlin implementation is compiled into the APK.

- [ ] Run the fixture test, Android parity/integration tests, Flutter tests, and debug APK build.
- [ ] Inspect the APK contents and confirm `libhoney_media_jni.so` exists for configured ABIs and legacy Kotlin codec class files do not.
- [ ] Commit:

  ```powershell
  git add -A android/app
  git commit -m "refactor: 移除生产环境Kotlin软件编解码器"
  ```

---

## Task 11: Harden Windows portability and conformance

**Files:**

- Modify: `media_core/CMakeLists.txt`
- Modify: `media_core/tests/CMakeLists.txt`
- Create: `media_core/tests/malformed_corpus_test.cpp`
- Modify: `scripts/test-media-core-windows.ps1`
- Create: `docs/media-core.md`

- [ ] Extend the existing PowerShell test entry point so omitting `-Configuration` builds Debug and Release and runs CTest for both configurations.
- [ ] Add malformed/truncated test cases generated deterministically in memory from every committed frame/AVI fixture. Test every prefix length plus corrupted RIFF/chunk/frame sizes and invalid option ranges.
- [ ] On MSVC enable `/W4 /WX /permissive- /EHsc- /GR-`; on Clang/GCC enable `-Wall -Wextra -Wpedantic -Werror -fno-exceptions -fno-rtti`.
- [ ] Run the script from a plain PowerShell prompt:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\test-media-core-windows.ps1
  ```

  Expected: the same public C ABI and codec/container tests pass in Windows Debug and Release.

- [ ] Document public ownership, thread-safety, stateful encoder/decoder rules, supported formats, Android/JNI boundary, Windows test-only scope, and extension path for iOS Swift/Objective-C, native Windows, Node/uni-app plugins, and WASM.
- [ ] Commit:

  ```powershell
  git add media_core scripts/test-media-core-windows.ps1 docs/media-core.md
  git commit -m "test: 增加Windows媒体核心一致性验收"
  ```

---

## Task 12: Run final regression and record truthful acceptance evidence

**Files:**

- Modify: `docs/media-core.md`
- Create: `docs/superpowers/reports/2026-07-31-cpp17-media-core-android-verification.md`

- [ ] Verify the worktree is on `codex/cpp17-media-core-android` and inspect `git status --short`; preserve unrelated user changes.
- [ ] Run Windows native tests with `scripts/test-media-core-windows.ps1`.
- [ ] Run Kotlin fixture tests and Android instrumentation tests.
- [ ] Run all existing Flutter tests with the repository-pinned Flutter:

  ```powershell
  $env:PUB_CACHE='F:\sourcecode\8773EWE\.codex-build-tools\pub-cache'
  & 'F:\sourcecode\8773EWE\.codex-build-tools\flutter\bin\flutter.bat' test --no-pub
  ```

- [ ] Build Android Debug and Release APKs without changing signing policy:

  ```powershell
  & 'F:\sourcecode\8773EWE\.codex-build-tools\flutter\bin\flutter.bat' build apk --debug
  & 'F:\sourcecode\8773EWE\.codex-build-tools\flutter\bin\flutter.bat' build apk --release
  ```

- [ ] On Android, exercise at least one CVID conversion/preview and one MSV1 camera encode/preview. Record device model, Android ABI, input dimensions/frame count/FPS, output size, and result.
- [ ] If physical eBadge hardware is available, transfer one C++-generated CVID AVI and one MSV1 AVI and record open/playback results. If hardware is unavailable, state that device compatibility remains pending rather than inferring it from Android/Windows tests.
- [ ] In the verification report, list commands, exit results, generated artifact paths, exact scope of passing evidence, and any unavailable hardware checks.
- [ ] Run `git diff --check`, inspect the full branch diff against its base, and rerun any focused test affected by final documentation or cleanup.
- [ ] Commit:

  ```powershell
  git add docs/media-core.md docs/superpowers/reports/2026-07-31-cpp17-media-core-android-verification.md
  git commit -m "docs: 记录C++媒体核心迁移验收结果"
  ```

---

## Completion Gate

The first version is complete only when all of the following are true:

- Android production code no longer contains Kotlin implementations of Cinepak, MSV1, or AVI parsing/muxing.
- Flutter/Dart public behavior is unchanged and the existing test suite passes.
- C++ output matches committed Kotlin reference vectors byte-for-byte for the selected key/inter cases.
- C++ decoders reproduce committed reference pixels exactly.
- Android JNI parity/integration tests pass on a real ABI.
- Windows MSVC Debug and Release builds and CTests pass using the same `media_core` sources.
- Debug and Release Android APKs contain the JNI library.
- Android runtime flows are checked; physical eBadge status is explicitly recorded as passed or pending.
- The worktree has no accidental generated, credential, cache, or unrelated files in the diff.
