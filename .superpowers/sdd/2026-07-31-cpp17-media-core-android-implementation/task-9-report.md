# Task 9 MSV1 camera production switch report

## Scope

- Switched `CameraEncoder` MSV1 encode, persistent preview decode, and end-only software AVI finishing to `CameraSoftwareMedia` backed by Honey Media Core JNI.
- Kept camera acquisition, GL readback, H.264, JPEG compression and preview, Flutter events, pacing, statistics, buffer limits, and stop-thread ordering unchanged.
- Split Android JPEG compression into production `JpegCodec` and moved the old Kotlin MSV1/decode/AVI implementation to the test-only `LegacyMsv1Codec`.
- Did not change `VideoConverter`, Cinepak production paths, Flutter/Dart production code, or the public method/event contract.

## TDD evidence

Tests were changed before production code. The valid source-gate RED was:

```text
:app:testDebugUnitTest --tests com.honeygui.honeybox.MediaReferenceFixturesTest.cameraProductionUsesSharedNativeSoftwareMediaWithoutLegacyCodecReferences
MediaReferenceFixturesTest > cameraProductionUsesSharedNativeSoftwareMediaWithoutLegacyCodecReferences FAILED
AssertionError: Production SoftwareCodec references remain
1 test completed, 1 failed
BUILD FAILED in 54s
```

The production-helper instrumentation test also failed to compile before implementation:

```text
:app:compileDebugAndroidTestKotlin
FAILED: unresolved reference CameraSoftwareMedia
```

After implementation, the complete fixture/source-gate class passed:

```text
:app:testDebugUnitTest --tests com.honeygui.honeybox.MediaReferenceFixturesTest
BUILD SUCCESSFUL in 1m 7s
4 tests, 0 failures, 0 errors, 0 skipped
```

## Production behavior

- MSV1 passes aligned dimensions, the configured skip threshold, previous RGBA only when skip is enabled and a refresh is not forced, and `forceKey=true` for periodic/requested refreshes.
- The encoded payload and key status come only from native `EncodedFrame.bytes` and normalized flags. `swFramesSinceKey`, `prevRgba`, and the requested-key consumption are advanced only after a successful native encode.
- Preview decodes into the same persistent `decodedArgb` array across frames. JNI transactional decode behavior remains responsible for leaving it untouched on malformed input.
- JPEG stays on Android Bitmap compression through `JpegCodec`; its buffered frames are tagged `KEY|KEY_KNOWN`.
- The parallel byte/key lists were replaced by one `ArrayList<NativeMediaCodec.EncodedFrame>`. The existing 600-frame and 96 MiB limits, total offered-byte counting, one-time truncation notice, and all-frame stop statistics are unchanged.
- Normal stop creates a local native AVI muxer only after queued encoder work. MSV1 uses `MSVC/MSVC/16`; JPEG uses the new `MJPG/MJPG/24` factory. Every buffered payload and flag is added, `finish()` is called, and `use` closes the handle on success or failure. Zero buffered frames still performs no write.
- Error/camera-close teardown only clears Kotlin state; no native AVI handle is held across camera or preview lifetime.

## Verification

All Android commands used the pinned JDK 17 and `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`. The mirror was required because the default Flutter artifact endpoint stalled in SSL reads; no project configuration was changed.

```text
:app:testDebugUnitTest --tests com.honeygui.honeybox.MediaReferenceFixturesTest
BUILD SUCCESSFUL in 1m 7s
4 tests, 0 failures, 0 errors, 0 skipped

:app:assembleDebugAndroidTest :app:externalNativeBuildDebug
BUILD SUCCESSFUL in 52s
app native ABIs: arm64-v8a, armeabi-v7a, x86_64

flutter test --no-pub
+67: All tests passed!

flutter build apk --debug --no-pub
Gradle assembleDebug completed in 48.8s
```

Artifacts:

- Main debug APK: `build/app/outputs/flutter-apk/app-debug.apk`, 163,044,466 bytes.
- Instrumentation APK: `build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk`, 386,915 bytes.
- Main APK contains `lib/arm64-v8a/libhoney_media_jni.so`, `lib/armeabi-v7a/libhoney_media_jni.so`, and `lib/x86_64/libhoney_media_jni.so`.
- `git diff --check` passed.
- The scoped diff contains no `VideoConverter` or Cinepak production change and no production `SoftwareCodec` reference.

## Runtime boundary

`adb devices -l` returned no attached device, and no emulator was available. The new instrumentation parity test compiles and packages but was not executed. CameraEncoder runtime capture, streaming, persistent preview, native MSV1 A/A/B exact parity, MSVC exact AVI parity, and MJPG metadata execution remain pending on an Android device/emulator; this report does not claim they passed at runtime.
