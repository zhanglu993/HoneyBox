# Honey Media Core

Honey Media Core is the framework-independent C++17 codec and AVI container
library used by the eBadge Android application. Its public boundary is a C99
header, `honey_media_core/media_core.h`, with `hmc_` functions and opaque
handles. The core has no Flutter, Dart, Java, Kotlin, JNI, Android graphics, or
operating-system UI dependency.

The library currently owns:

- Cinepak encoding and decoding for the documented project subset;
- Microsoft Video 1 (MSV1) frame encoding and decoding;
- incremental AVI muxing and immutable AVI reading;
- stable status codes, frame flags, owned buffers, and C ABI versioning.

It does not decode MP4/MOV/GIF source media and does not implement JPEG or
H.264. Those responsibilities remain with each platform adapter.

## Building and testing on Windows

Run the native acceptance entry point from a plain PowerShell prompt:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-core-windows.ps1
```

With no configuration argument, the script configures Visual Studio 2022 x64
once, then builds and runs CTest for both Debug and Release. A focused build is
also supported:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-core-windows.ps1 -Configuration Debug
```

Windows acceptance builds the standalone native core, its C++ conformance
suite, and a C99 compile consumer. It does not add media conversion to the
Flutter Windows runner and does not prove Windows camera, source-video decode,
preview, or device-transfer behavior.

For direct CMake integration, add `media_core` as a subdirectory and link the
`honey_media_core` target. It is static by default. With
`BUILD_SHARED_LIBS=ON`, the library exports its C ABI and consumers inherit
`HMC_USE_SHARED`.

## Stable C ABI

The current ABI version is `HMC_ABI_VERSION_1_0` (`0x00010000`). ABI versions
are packed as `major << 16 | minor`. Published status values, flag values,
field order, field types, and V1 structure sizes must not be renumbered or
reused. Compatible fields may only be appended to extensible structures; an
incompatible change requires a new major ABI.

Every public function uses `HMC_API` and `HMC_CALL`:

- Windows and Cygwin use `__cdecl`;
- Windows shared-library producers define `HMC_BUILD_SHARED`;
- Windows shared-library consumers define `HMC_USE_SHARED`;
- static Windows builds need neither shared-library macro;
- GCC and Clang use default symbol visibility and their normal C calling
  convention.

No C++ type, exception, STL container, reference, or class crosses the ABI.
Public statuses are `int32_t`; flags and serialized logical indexes are
`uint32_t`; `size_t` is used only for in-process buffer sizes and capacities.
The core is compiled without C++ exceptions and RTTI. Failures are returned as
`hmc_status_t` and never escape as C++ exceptions.

### Extensible structures

Configuration and metadata structures begin with `struct_size`. Callers must:

1. allocate and zero their complete structure;
2. call the matching config initializer, or set `struct_size` for output
   structures;
3. leave unknown/reserved tail bytes zero.

Config initializers clear the supplied capacity, write known defaults, and set
`struct_size` to the supplied size. A null pointer returns
`HMC_STATUS_INVALID_ARGUMENT`; a buffer smaller than V1 returns
`HMC_STATUS_BUFFER_TOO_SMALL`. Failed calls do not modify caller-owned output
structures.

## Data representation and ownership

- Encoder input is tightly packed, top-down RGBA8888 in byte order
  `R, G, B, A`.
- Decoder output pixels are numeric `uint32_t` values `0xAARRGGBB`, independent
  of the host memory byte order.
- Codec and AVI integer fields are read and written with explicit endianness;
  the core does not depend on host endianness.
- Input spans remain owned by the caller and must stay valid for the duration
  of the call.
- `(NULL, 0)` is valid only where the specific API documents an optional empty
  span. `(NULL, nonzero)` is always invalid.

An `hmc_owned_buffer_t` output must be `{NULL, 0}` before the call. On success,
the caller owns the returned allocation and must release it only with
`hmc_owned_buffer_release`. On failure, the output remains empty.

An `hmc_bytes_view_t` is borrowed. AVI frame views remain valid until their
reader is destroyed and must not be freed. Bindings that cannot safely express
that lifetime, including typical Swift and Node wrappers, should use
`hmc_avi_reader_copy_frame` instead.

Create outputs must point to a null handle. A failed create keeps them null.
Destroy functions and `hmc_owned_buffer_release` accept null. Decoder, encoder,
and muxer failures are transactional: caller output and previously committed
handle state remain unchanged, so recoverable failures may be retried.

## Thread safety and state

| Object or operation | Concurrency rule |
| --- | --- |
| ABI/status queries | May be called concurrently |
| Separate handles | May run concurrently |
| One encoder, decoder, or muxer | Caller must serialize all operations |
| Immutable AVI reader queries | May run concurrently after successful creation |
| Destroy or release | Must not race any operation using that object or buffer |

The core does not create worker threads. Platform adapters own scheduling,
cancellation, frame extraction, and handle serialization.

### Cinepak

The Cinepak encoder is stateful. Its first frame, configured key interval, and
`HMC_ENCODE_FLAG_FORCE_KEY` determine the returned normalized frame flags.
Reset returns it to fresh-encoder state.

The decoder is also stateful. An inter frame requires a previously committed
key reference; after reset it returns `HMC_STATUS_INVALID_STATE` until a key
frame succeeds. A malformed or allocation-failed decode changes neither the
caller ARGB output nor the decoder reconstruction state.

The decoder supports the project CVID subset: full V4/V1 codebooks
`0x20/0x22`, key mixed vectors `0x30`, inter vectors `0x31`, and all-V1 vectors
`0x32`. Selective/gray codebooks and unknown chunks are unsupported. This is
not a claim of complete Cinepak conformance.

### MSV1

MSV1 dimensions must be nonzero multiples of four. Encoding is a single-frame
operation; inter-frame skip is enabled by supplying the previous top-down RGBA
span. A null previous span or `HMC_ENCODE_FLAG_FORCE_KEY` produces key mode.
The returned flags, not payload inspection, are the authoritative key status.

MSV1 decode uses the caller's ARGB buffer as persistent reconstruction input:
skip blocks retain existing pixels. Reuse the same buffer across a key/inter
sequence. Decode occurs transactionally through scratch storage, so malformed
input leaves every caller pixel unchanged.

### AVI

The incremental muxer accepts encoded payloads plus explicit normalized frame
flags. It never guesses key status from codec bytes. A successful `finish`
seals the muxer; later add or finish calls return `HMC_STATUS_INVALID_STATE`.
A failed finish does not seal it.

The reader copies its input during creation. It exposes both original AVI
`idx1` flags and normalized Honey Media Core frame flags. The supported writer
and reader profiles are exactly:

| Handler | Compression | Bit count | Purpose |
| --- | --- | ---: | --- |
| `cvid` | `cvid` | 24 | Cinepak |
| `MSVC` | `MSVC` | 16 | Microsoft Video 1 |
| `MJPG` | `MJPG` | 24 | Android-produced JPEG frames |

MSVC and MJPG deliberately retain the legacy Kotlin AVI layout, including the
historical `strl` size exception and `biSizeImage` behavior. MJPG has audited
synthetic layout and round-trip coverage but no frozen Kotlin MJPG golden;
byte-for-byte Kotlin MJPG parity must not be claimed until such a fixture is
added.

## Android boundary

Android continues to own source-video and GIF decoding, Bitmap transforms,
crop/scale/rotation, JPEG and H.264 system codecs, sampling, progress,
cancellation, files, Flutter channels, and device transfer.

`NativeMediaCodec.kt` is the Kotlin ownership facade. JNI validates Java array
sizes, copies data across the language boundary, maps C statuses to stable
Kotlin exceptions, and closes opaque handles through `AutoCloseable` scopes.
`VideoConverter` and `CameraEncoder` pass already prepared RGBA frames to this
facade; they do not expose native pointers to Flutter.

## Additional platform adapters

The C ABI is intentionally independent of Flutter so future frontends can
reuse the same core:

- **iOS:** build the static core for device and simulator, package it as an
  XCFramework, expose the C header through an Objective-C module or bridging
  header, and wrap opaque handles in Swift classes. Prefer copied AVI frames
  unless the wrapper can prove borrowed-view lifetime.
- **Native Windows:** link the static target or a DLL with `HMC_USE_SHARED`.
  Media Foundation source decoding and any Windows UI remain separate adapter
  work.
- **Node and uni-app:** implement an N-API addon that copies JavaScript buffers,
  serializes each mutable handle, converts statuses to JavaScript errors, and
  releases owned buffers before returning. The addon, not the C ABI, owns
  asynchronous work and cancellation.
- **WebAssembly:** compile the core with Emscripten, export a narrow wrapper,
  and copy input/output through linear memory. Start with serialized handles;
  threads, SIMD, browser video decode, and JavaScript lifecycle integration are
  adapter-level extensions.

Every adapter must preserve buffer ownership, explicit frame flags, stateful
decode order, failure atomicity, and ABI-version checks. Passing native tests
on one host proves core portability and deterministic fixture behavior only;
it does not replace platform runtime, device playback, or hardware acceptance.
