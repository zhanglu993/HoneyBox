"""Generate deterministic-enough Media Foundation edge-case fixtures.

The committed files are consumed by tests; this script is a developer-only
reproducer. Product code and test execution do not invoke FFmpeg.
"""

from __future__ import annotations

import hashlib
import math
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import wave


HERE = Path(__file__).resolve().parent
WIDTH = 64
HEIGHT = 32
FRAME_COUNT = 4
NEGATIVE_PTS_FRAME_RATE = 4
NEGATIVE_PTS_COLORS = (
    (255, 0, 0),
    (0, 255, 0),
    (0, 0, 255),
    (255, 255, 0),
    (255, 0, 255),
    (0, 255, 255),
    (128, 128, 128),
    (255, 255, 255),
)


def find_ffmpeg() -> str:
    discovered = shutil.which("ffmpeg")
    if discovered:
        return discovered
    bundled = Path(r"C:\ffmpeg\bin\ffmpeg.exe")
    if bundled.is_file():
        return str(bundled)
    raise RuntimeError("ffmpeg is required only to regenerate the MOV fixture")


def rgb_frame() -> bytes:
    colors = ((255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0))
    output = bytearray()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            quadrant = (2 if y >= HEIGHT // 2 else 0) + (
                1 if x >= WIDTH // 2 else 0
            )
            output.extend(colors[quadrant])
    return bytes(output)


def generate_rotated_mov(ffmpeg: str) -> Path:
    output = HERE / "mf_rotation_90.mov"
    with tempfile.TemporaryDirectory(prefix="hmw-mf-fixture-") as temporary:
        temporary_path = Path(temporary)
        raw = temporary_path / "quadrants.rgb"
        raw.write_bytes(rgb_frame() * FRAME_COUNT)
        base = temporary_path / "base.mov"
        subprocess.run(
            [
                ffmpeg,
                "-v",
                "error",
                "-f",
                "rawvideo",
                "-pixel_format",
                "rgb24",
                "-video_size",
                f"{WIDTH}x{HEIGHT}",
                "-framerate",
                "2",
                "-i",
                str(raw),
                "-an",
                "-c:v",
                "libx264",
                "-profile:v",
                "baseline",
                "-pix_fmt",
                "yuv420p",
                "-crf",
                "10",
                "-g",
                "1",
                "-bf",
                "0",
                "-threads",
                "1",
                "-fflags",
                "+bitexact",
                "-flags:v",
                "+bitexact",
                "-map_metadata",
                "-1",
                "-y",
                str(base),
            ],
            check=True,
        )
        subprocess.run(
            [
                ffmpeg,
                "-v",
                "error",
                "-display_rotation:v:0",
                "90",
                "-i",
                str(base),
                "-map",
                "0:v:0",
                "-c",
                "copy",
                "-map_metadata",
                "-1",
                "-movflags",
                "+faststart",
                "-y",
                str(output),
            ],
            check=True,
        )
    return output


def generate_negative_pts_mp4(ffmpeg: str) -> Path:
    output = HERE / "mf_negative_start.mp4"
    with tempfile.TemporaryDirectory(prefix="hmw-mf-negative-pts-") as temporary:
        temporary_path = Path(temporary)
        raw = temporary_path / "colors.rgb"
        raw.write_bytes(
            b"".join(bytes(color) * (WIDTH * HEIGHT) for color in NEGATIVE_PTS_COLORS)
        )
        encoded = temporary_path / "encoded.mp4"
        subprocess.run(
            [
                ffmpeg,
                "-v",
                "error",
                "-f",
                "rawvideo",
                "-pixel_format",
                "rgb24",
                "-video_size",
                f"{WIDTH}x{HEIGHT}",
                "-framerate",
                str(NEGATIVE_PTS_FRAME_RATE),
                "-i",
                str(raw),
                "-an",
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-g",
                str(len(NEGATIVE_PTS_COLORS)),
                "-bf",
                "2",
                "-x264-params",
                "b-adapt=0:scenecut=0:keyint=8:min-keyint=8",
                "-threads",
                "1",
                "-fflags",
                "+bitexact",
                "-flags:v",
                "+bitexact",
                "-map_metadata",
                "-1",
                "-movflags",
                "+negative_cts_offsets",
                "-use_editlist",
                "0",
                "-video_track_timescale",
                "10000000",
                "-y",
                str(encoded),
            ],
            check=True,
        )

        contents = bytearray(encoded.read_bytes())
        ctts = contents.find(b"ctts")
        if ctts < 4 or contents[ctts + 4] != 1:
            raise RuntimeError("expected a version 1 signed ctts box")
        entry_count = struct.unpack_from(">I", contents, ctts + 8)[0]
        entry = ctts + 12
        for _ in range(entry_count):
            sample_count, offset = struct.unpack_from(">Ii", contents, entry)
            struct.pack_into(">Ii", contents, entry, sample_count, offset - 5_000_000)
            entry += 8
        output.write_bytes(contents)
    return output


def generate_audio_only_wav() -> Path:
    output = HERE / "mf_audio_only.wav"
    with wave.open(str(output), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(8000)
        samples = bytearray()
        for index in range(800):
            value = int(4000 * math.sin(2 * math.pi * 440 * index / 8000))
            samples.extend(struct.pack("<h", value))
        writer.writeframes(bytes(samples))
    return output


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    ffmpeg = find_ffmpeg()
    fixtures = (
        generate_rotated_mov(ffmpeg),
        generate_negative_pts_mp4(ffmpeg),
        generate_audio_only_wav(),
    )
    for fixture in fixtures:
        print(f"{fixture.name} {fixture.stat().st_size} {digest(fixture)}")
