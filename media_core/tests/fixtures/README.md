# Kotlin media reference fixtures

These are deterministic 8x8 Kotlin-reference vectors frozen before the C++
media-core ports. `input_8x8_a.rgba` and `input_8x8_b.rgba` are top-down
RGBA8888 input (256 bytes each). The B input changes the top-left 4x4 block,
so the other three macroblocks exercise inter-frame skips; encoding A after A
exercises all-skip state.

Generate intentionally, after reviewing the existing Kotlin codec behavior:

```powershell
$env:JAVA_HOME='...'; $env:FLUTTER_ROOT='...'; $env:ANDROID_SDK_ROOT='...'
.\scripts\run-android-gradle.ps1 :app:testDebugUnitTest --tests com.honeygui.honeybox.MediaReferenceFixturesTest -Debadge.regenerateFixtures=true
```

MSV1 uses `encodeMsv1(A, 8, 8, null, 0)`, then A/A and B/A, and decodes all
three through one persistent `IntArray(64)`. Cinepak uses one default
`CinepakEncoder.Encoder(8, 8, Options())` and one persistent decoder in the
same A/A/B order. AVI samples contain the three frames at 10 FPS; MSVC uses
16-bit headers and key flags `[true, false, false]`, while CVID uses the
Kotlin CVID muxer.

Every `.argb` file explicitly serializes each `0xAARRGGBB` pixel in little
endian `BB GG RR AA` byte order. Normal tests regenerate expected bytes only
in memory and compare every committed binary without writing. Changes require
an intentional Kotlin-reference review.
