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
    fixtures = (generate_rotated_mov(find_ffmpeg()), generate_audio_only_wav())
    for fixture in fixtures:
        print(f"{fixture.name} {fixture.stat().st_size} {digest(fixture)}")
