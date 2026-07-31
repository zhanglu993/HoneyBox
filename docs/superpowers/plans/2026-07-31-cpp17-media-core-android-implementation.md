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
- Every public function declaration and definition uses `HMC_API` and `HMC_CALL`; Windows/Cygwin is `__cdecl`, shared builds/consumers select export/import with `HMC_BUILD_SHARED`/`HMC_USE_SHARED`, static Windows leaves `HMC_API` empty, and GCC/Clang uses default visibility with an empty calling convention.
- Status storage is fixed `int32_t`; published numeric values are append-only and may never be renumbered, reused, or removed. ABI version is packed `major << 16 | minor`.
- `size_t` is only for in-process byte/pixel buffer sizes and capacities. It is never serialized or sent across IPC; logical AVI frame counts and indexes use `uint32_t`.
- RGBA input is contiguous byte order `R,G,B,A`; ARGB output is numeric `uint32_t 0xAARRGGBB`, independent of host memory byte order.
- `(NULL, 0)` is a valid empty span only where explicitly allowed; `(NULL, nonzero)` is always invalid.
- Fixed-layout transport structs `hmc_owned_buffer_t` and `hmc_bytes_view_t` contain only pointer/size fields and do not contain `struct_size`.
- Every owned-buffer output and borrowed `hmc_bytes_view_t` output is `{NULL, 0}` on entry and remains empty on failure. Owned buffers are released only by `hmc_owned_buffer_release`; every create output handle points to NULL on entry and remains NULL on failure.
- Every encoder `output_frame_flags` pointer is non-NULL. Both MSV1 and Cinepak leave the caller's scalar value unchanged on failure and write actual normalized flags only on success.
- Extensible structs put `struct_size` first, allow only tail additions, define a fixed numeric `HMC_*_V1_SIZE`, use no packed layout, and preserve every published field/type/semantic.
- `struct_size` is caller allocation size including itself. Except for config init, callees accept at least V1 size, read/write only known bytes, require unknown input/tail bytes and reserved fields to be zero, and never change `struct_size`.
- Output structs are zeroed by the caller with `struct_size` set; failure leaves the whole output unchanged. Config init functions take `(config*, uint32_t config_size)`; NULL returns `HMC_STATUS_INVALID_ARGUMENT`, smaller than V1 returns `HMC_STATUS_BUFFER_TOO_SMALL`, and either failure leaves caller memory unchanged. Success zeros the provided capacity, sets known defaults, and sets `struct_size = config_size`.
- Unknown encode/frame flag bits return `HMC_STATUS_UNSUPPORTED`.
- A borrowed `hmc_bytes_view_t` returned by an AVI reader remains valid only until `hmc_avi_reader_destroy`.
- Independent handles may run concurrently. One encoder/decoder/muxer handle is externally serialized; immutable reader queries may run concurrently; destroy is never concurrent with another call.
- Failed decoder calls preserve output and all internal state. Failed encoder/muxer calls preserve frame index, reconstruction, keyframe tracking, and previously added frames so OOM can be retried.
- Stateful destroy functions and `hmc_owned_buffer_release` always accept NULL; other handle operations reject NULL with `HMC_STATUS_INVALID_ARGUMENT`.
- Tasks 3–6 must not use throwing `new` or default-allocator STL growth (`std::vector`/`std::string` construction/copy/reserve/resize/push/append) on any fallible runtime path. Use checked-size, malloc/realloc/free-backed internal no-throw buffers whose mutating operations return `hmc_status_t`; keep `realloc` results temporary until success.
- The internal allocator exposes a native-test-only Nth-allocation failure hook, never public ABI. Each Task 3–6 test suite sweeps every allocation point and verifies OOM status, required output values, unchanged logical state, and successful retry after fault removal.
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

HMC_API uint32_t HMC_CALL hmc_abi_version(void);
HMC_API const char *HMC_CALL hmc_status_message(hmc_status_t status);
HMC_API void HMC_CALL hmc_owned_buffer_release(hmc_owned_buffer_t *buffer);
```

- [ ] Write `test_main.cpp` with a small registration/assertion harness and initial tests that require packed ABI version 1.0, fixed 32-bit status/flag storage and values, stable non-empty status messages, and safe release of `{NULL, 0}`.
- [ ] Add `scripts/test-media-core-windows.ps1`. It must resolve `cmake.exe` from `PATH` or the current Visual Studio installation, use repository-relative source/build paths, and return the failing command's exit code.
- [ ] Run the native configure/build script and confirm the test target fails because the public header and functions do not exist:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\test-media-core-windows.ps1 -Configuration Debug
  ```

- [ ] Add `media_core.h`, internal checked-size helpers in `core_types.hpp`, and the minimum `c_api.cpp` implementation. Use `extern "C"` guards and fixed-width integer types.
- [ ] Make CMake build `honey_media_core` as a static library by default (and a correctly exported shared library when `BUILD_SHARED_LIBS` is enabled), with public include directory `media_core/include`, C++17 required, extensions disabled, and warning-as-error options for MSVC and Clang/GCC.
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

## Task 2.5: Freeze the general-purpose C ABI

**Files:**

- Modify: `media_core/include/honey_media_core/media_core.h`
- Modify: `media_core/src/c_api.cpp`
- Modify: `media_core/CMakeLists.txt`
- Modify: `media_core/tests/test_main.cpp`
- Modify: `media_core/tests/test_c99_consumer.c`
- Modify: `docs/superpowers/specs/2026-07-31-cpp17-media-core-android-design.md`
- Modify: `docs/superpowers/plans/2026-07-31-cpp17-media-core-android-implementation.md`

- [ ] First make the native and C99 tests require 32-bit status/flag types, packed ABI 1.0, all exact status/flag values, public export/calling-convention macros, and stable non-empty messages for every status. Run the unchanged implementation and record the expected compile/test failure.
- [ ] Replace the public C enum with fixed `int32_t`, append `UNSUPPORTED`, `BUFFER_TOO_SMALL`, and `INVALID_STATE`, add stable 32-bit encode/frame flags, return the packed current ABI version, and annotate all current declarations/definitions with `HMC_API`/`HMC_CALL`.
- [ ] Configure CMake to define `HMC_BUILD_SHARED` for a shared-library implementation and propagate `HMC_USE_SHARED` to its consumers while preserving the default static build. Make the C99 object a real target consumer and compile-assert that shared receives `HMC_USE_SHARED` while static does not.
- [ ] Freeze the ABI-wide layout, ownership, byte-order, flags, concurrency, and failure-atomicity rules in this plan and the design; rewrite Tasks 3-7 before their public symbols are implemented.
- [ ] Run Windows Debug configure/build, the C99 consumer, CTest, `git diff --check`, and stale-symbol scans.
- [ ] Commit:

  ```powershell
  git add media_core docs/superpowers/specs/2026-07-31-cpp17-media-core-android-design.md docs/superpowers/plans/2026-07-31-cpp17-media-core-android-implementation.md
  git commit -m "refactor: 固化媒体核心跨平台ABI"
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
typedef struct hmc_avi_muxer hmc_avi_muxer_t;
typedef struct hmc_avi_reader hmc_avi_reader_t;

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
```

- [ ] Write failing tests for config init setting `struct_size == config_size`, V1/tail-zero rules, incremental empty/multi-frame muxing, odd-sized frame padding, invalid rational frame rates, CVID/MSVC/MJPG handler/compression/bit-count combinations, `idx1` offsets/flags, original and normalized frame flags, borrowed/copy frame access, round-trip parsing, truncated chunks, oversized chunk lengths, invalid RIFF signatures, null arguments, NULL-tolerant destroy, and out-of-range `uint32_t` indexes.
- [ ] Run CTest and confirm failures because AVI functions are absent.
- [ ] Implement little-endian writer/reader helpers with checked `size_t` addition and multiplication plus malloc/realloc/free-backed no-throw buffers. Do not use throwing STL growth. The muxer owns copies/state incrementally; the reader owns a copy of input bytes, borrowed views remain stable until destroy, and Swift/Node bindings default to `hmc_avi_reader_copy_frame`.
- [ ] Consume only explicit normalized `hmc_frame_flags_t`; never inspect codec payload to guess keyframes. Expose original `idx1` flags separately from normalized flags and reject unknown flags/unsupported FOURCC with `HMC_STATUS_UNSUPPORTED`.
- [ ] Use rational `frame_rate_num/frame_rate_den`; map the current integer FPS to `fps/1`. Match `CvidAviMuxer` exactly for CVID, including lowercase `cvid`, 24-bit `strf`, and first `movi` frame offset `4`.
- [ ] Match `SoftwareCodec.buildAvi` exactly for MSVC/MJPG, including explicit frame flags and `biSizeImage = width * height * 2`; preserve all existing CVID/MSVC/MJPG header differences.
- [ ] Add exact byte comparisons against `cvid_sample.avi` and `msvc_sample.avi`.
- [ ] Make `add_frame` validate first, then copy/append into isolated candidate byte/index/metadata buffers; only an all-buffer no-fail swap commits the frame and count, so even current capacities remain unchanged on failure. Build reader copies/metadata in an unpublished candidate handle and publish it only after complete success. Make `finish` build entirely in a scratch owned buffer; only after successful transfer does it seal the muxer.
- [ ] After successful `finish`, repeated `finish` and every later `add_frame` return `HMC_STATUS_INVALID_STATE`; the owned output stays empty and logical state is unchanged. A failed `finish` does not seal and is retryable.
- [ ] Test unchanged output structs on failure, `{NULL,0}` borrowed view and owned outputs on failure, unchanged muxer state after failed add/finish, sealed-state invalid calls, NULL-tolerant destroy, and immutable concurrent reader queries.
- [ ] Sweep the test-only Nth-allocation failure hook across create-copy, add-frame, and finish. Each injected failure must return OOM with the required empty/unchanged output and logical state, then succeed when retried without the fault.
- [ ] Run CTest with malformed/truncated corpus tests and confirm no crash, out-of-bounds access, partial output buffer, or partial muxer state escapes.
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

HMC_API hmc_status_t HMC_CALL hmc_msv1_encoder_config_init(
    hmc_msv1_encoder_config_t *config,
    uint32_t config_size);
HMC_API hmc_status_t HMC_CALL hmc_msv1_decoder_config_init(
    hmc_msv1_decoder_config_t *config,
    uint32_t config_size);

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
```

- [ ] Write failing tests for encoder config init setting `struct_size == config_size`, decoder config init setting `struct_size == config_size`, both V1 sizes/tail-zero rules, solid-color blocks, two-color blocks, key-frame fixture equality, inter-frame fixture equality, force-key and unknown encode flags, returned normalized frame flags, persistent decode output for skipped blocks, dimensions not divisible by four, short RGBA/ARGB buffers, truncated words, malformed skip runs, and size-overflow dimensions.
- [ ] Run CTest and confirm failures because MSV1 functions are absent.
- [ ] Port the Kotlin scan order, RGB555 conversion, skip-color collision handling, luminance clustering, mask inversion, bottom-up block order, skip-run splitting at `0x3ff`, and terminating word using fixed-width arithmetic.
- [ ] Encode into a checked-size malloc-backed scratch buffer and publish owned bytes/frame flags only at the final no-fail commit. Decode into a no-throw scratch pixel array and copy to caller ARGB only after complete success; do not use throwing STL growth.
- [ ] Port decode behavior while replacing silent Kotlin truncation returns with `HMC_STATUS_MALFORMED_DATA`. Preserve previous pixels for valid skipped blocks.
- [ ] On encode failure keep owned output empty and `output_frame_flags` unchanged. On decode failure preserve the caller output and all persistent pixels; reject unknown flags with `HMC_STATUS_UNSUPPORTED`.
- [ ] Sweep every encode/decode allocation point with the internal Nth-allocation failure hook; assert OOM, empty/unchanged output and frame flags, preserved decode pixels, then successful retry after clearing the fault.
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

typedef struct hmc_cinepak_decoder_config {
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
} hmc_cinepak_decoder_config_t;

#define HMC_CINEPAK_DECODER_CONFIG_V1_SIZE UINT32_C(12)

HMC_API hmc_status_t HMC_CALL hmc_cinepak_decoder_config_init(
    hmc_cinepak_decoder_config_t *config,
    uint32_t config_size);
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
```

- [ ] Write failing tests for decoder config init setting `struct_size == config_size`, V1 size/tail-zero rules, decoding the key/inter fixtures in sequence, status-returning reset behavior, NULL-tolerant destroy, incorrect frame dimensions, truncated 10-byte frame headers, truncated strip/chunk payloads, invalid strip counts, invalid codebook indexes, impossible frame/chunk sizes, null/short output buffers, and every failure leaving caller output plus decoder state unchanged.
- [ ] Run CTest and confirm failures because Cinepak decoder functions are absent.
- [ ] Port the codebook parsing, V1/V4 vector handling, strip row accumulator, signed U/V conversion, YUV reconstruction, and persistent inter-frame reconstruction.
- [ ] Build create results in an unpublished candidate handle. Use malloc-backed no-throw scratch output plus a complete candidate reconstruction/codebook state. Require every read to pass a remaining-length check before consuming data; only publish/swap candidate state and copy output after the complete operation succeeds.
- [ ] Return `HMC_STATUS_MALFORMED_DATA` on invalid frame structure and leave both caller output and all decoder state unchanged on every failure.
- [ ] Sweep every decoder create/decode allocation point with the internal Nth-allocation failure hook; assert OOM, unchanged caller output/state, and successful retry after clearing the fault.
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
```

- [ ] Write failing tests for config init setting `struct_size == config_size`, V1 size/tail-zero rules/defaults, dimensions divisible by four, key-frame fixture equality, inter-frame fixture equality, explicit force-key and unknown flags, actual returned frame flags, `output_frame_flags` unchanged on every failure, key interval, status-returning reset producing the original first frame, NULL-tolerant destroy, deterministic repeated runs, invalid options, short RGBA input, and overflow-sized dimensions.
- [ ] Run CTest and confirm failures because Cinepak encoder functions are absent.
- [ ] Port RGB-to-YUV fixed-point conversion, macroblock extraction, median-cut initialization, deterministic Lloyd refinement, V1/V4 decision, codebook emission, key/inter skip decisions, strip construction, frame assembly, and reconstruction state.
- [ ] Build create results in an unpublished candidate handle. Use malloc-backed no-throw candidate reconstruction/codebook/frame buffers. Complete frame assembly and frame-type decision in candidates; only after success publish/swap state, advance frame index, transfer owned output, and write frame flags.
- [ ] Preserve Kotlin integer rounding and stable tie-breaking exactly; do not parallelize codebook generation in this version because output determinism is part of the format contract.
- [ ] Select and return actual normalized frame flags only after first-frame, key-interval, and force-key logic. Reject unknown encode flags with `HMC_STATUS_UNSUPPORTED`; every failed encode/reset preserves frame index, reconstruction, keyframe tracking, owned output emptiness, and the caller's `output_frame_flags` value so OOM can be retried.
- [ ] Sweep every encoder create/encode allocation point with the internal Nth-allocation failure hook; assert OOM, empty output, unchanged flags/state, and successful retry after clearing the fault.
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

    data class EncodedFrame(
        val bytes: ByteArray,
        val frameFlags: Int,
    )

    external fun encodeMsv1(
        rgba: ByteArray,
        width: Int,
        height: Int,
        previousRgba: ByteArray?,
        skipThreshold: Int,
        forceKey: Boolean,
    ): EncodedFrame

    external fun decodeMsv1(
        encoded: ByteArray,
        width: Int,
        height: Int,
        persistentArgb: IntArray,
    )

    class CinepakEncoder internal constructor(internal var handle: Long) : AutoCloseable {
        external fun encode(rgba: ByteArray, forceKey: Boolean): EncodedFrame
        external fun reset()
        override external fun close()
    }
}
```

- [ ] Add `externalNativeBuild.cmake` pointing to `src/main/cpp/CMakeLists.txt`; link the shared JNI target `honey_media_jni` to the standalone static `honey_media_core`.
- [ ] Add AndroidX test runner configuration and a parity test that initially calls `NativeMediaCodec` for every committed fixture. Run it on the available emulator/device and confirm it fails because JNI symbols are absent.
- [ ] Implement JNI array-size validation, `GetByteArrayRegion`/`SetIntArrayRegion` transfers, opaque handle checks, deterministic `IllegalArgumentException` for invalid input, `IOException` for malformed media, `UnsupportedOperationException` for unsupported FOURCC/flags, and `IllegalStateException` for closed handles/invalid state/internal failures.
- [ ] Never expose a native pointer directly to Dart. Store handles only in package-internal Kotlin wrapper objects and make `close()` idempotent.
- [ ] JNI creates every extensible config through its `_config_init(config, sizeof(config))`, sets only known fields, and passes normalized `HMC_ENCODE_FLAG_*` values; Kotlin `Boolean forceKey` maps to `HMC_ENCODE_FLAG_FORCE_KEY`, never to an ABI `uint8_t`.
- [ ] Return the encoder-selected `hmc_frame_flags_t` together with each encoded byte array and pass those flags unchanged into the incremental AVI muxer. Do not inspect Cinepak/MSV1 payload bytes to infer keyframes.
- [ ] Implement JNI methods for MSV1, Cinepak encoder/decoder, incremental AVI muxing, AVI metadata/frame-info queries, and copy-frame extraction. Kotlin/Android uses `hmc_avi_reader_copy_frame`, not a borrowed native view. Every returned `hmc_owned_buffer_t` is copied into a Java byte array and released on all paths.
- [ ] Map status-returning reset calls through the same error path as encode/decode. Keep Flutter method results and legacy caller-visible behavior unchanged while adapting `VideoConverter`/`CameraEncoder` internals to `EncodedFrame`.
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

- `CinepakDecoder.parseAvi` → `NativeMediaCodec.openAvi`; metadata/frame-info use immutable reader queries and payload extraction uses copy-frame
- `CinepakDecoder.Decoder` → `NativeMediaCodec.CinepakDecoder`
- `CinepakEncoder.Encoder` → `NativeMediaCodec.CinepakEncoder`, returning `EncodedFrame(bytes, frameFlags)`
- `CvidAviMuxer.buildAvi` → scoped `NativeMediaCodec.AviMuxer` configured with rational FPS, lowercase `cvid`, and 24-bit header; add each encoded frame with its returned normalized flags, then finish

- [ ] Add a failing production-path instrumentation test that converts a short deterministic 8×8 frame sequence and asserts the output equals `cvid_sample.avi` while the legacy Kotlin codec is made unavailable to that test through a test-only guard.
- [ ] Run the focused test and confirm the current `VideoConverter` still reaches Kotlin codec objects.
- [ ] Replace only Cinepak/AVI calls in `VideoConverter`. Convert integer FPS to `fps/1`, carry encoder-returned frame flags into the incremental muxer, and preserve Android frame extraction, crop/scale, cancellation checks, progress frequency, output path, and result maps.
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

- Native: MSV1 encode/decode and incremental AVI muxing/owned-copy reading.
- Kotlin/Android: JPEG `Bitmap.compress`, frame acquisition/transforms, H.264 `MediaCodec`, camera and product state.

- [ ] Add failing focused tests that make `CameraEncoder` MSV1 key/inter output and AVI match committed fixtures through the production facade.
- [ ] Run the tests and confirm production still calls `SoftwareCodec.encodeMsv1`, `decodeMsv1`, and `buildAvi`.
- [ ] Replace those three call paths with `NativeMediaCodec`. Use separate initialized MSV1 encoder/decoder configs, carry each encoder-returned frame flag into the incremental muxer, and keep `SoftwareCodec.encodeJpeg` in Kotlin.
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
