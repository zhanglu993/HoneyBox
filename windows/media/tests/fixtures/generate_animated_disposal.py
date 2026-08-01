"""Deterministically generate the small GIF used by the WIC integration tests."""

from pathlib import Path

from PIL import GifImagePlugin, Image


WIDTH = 4
HEIGHT = 4
TRANSPARENT = 0
RED = 1
GREEN = 2
BLUE = 3
PALETTE = [
    0, 0, 0,
    255, 0, 0,
    0, 255, 0,
    0, 0, 255,
] + [0, 0, 0] * 252


def make_frame(width: int, height: int, pixels: list[int]) -> Image.Image:
    frame = Image.new("P", (width, height), TRANSPARENT)
    frame.putpalette(PALETTE)
    frame.putdata(pixels)
    frame.info["transparency"] = TRANSPARENT
    return frame


first = make_frame(WIDTH, HEIGHT, [RED] * (WIDTH * HEIGHT))

second = make_frame(2, 2, [GREEN, TRANSPARENT, TRANSPARENT, GREEN])

third = make_frame(2, 2, [BLUE, TRANSPARENT, BLUE, TRANSPARENT])

output = Path(__file__).with_name("animated_disposal.gif")
logical_screen = Image.new("P", (WIDTH, HEIGHT), TRANSPARENT)
logical_screen.putpalette(PALETTE)
header, _ = GifImagePlugin.getheader(
    logical_screen, info={"loop": 0, "transparency": TRANSPARENT}
)
blocks = list(header)
for frame, offset, duration, disposal in [
    (first, (0, 0), 50, 3),
    (second, (1, 1), 100, 2),
    (third, (0, 0), 150, 1),
]:
    blocks.extend(
        GifImagePlugin.getdata(
            frame,
            offset=offset,
            duration=duration,
            disposal=disposal,
            transparency=TRANSPARENT,
            include_color_table=False,
        )
    )
output.write_bytes(b"".join(blocks) + b";")

with Image.open(output) as check:
    assert check.size == (WIDTH, HEIGHT)
    assert check.n_frames == 3
    expected_durations = [50, 100, 150]
    expected_disposals = [3, 2, 1]
    expected_extents = [(0, 0, 4, 4), (1, 1, 3, 3), (0, 0, 2, 2)]
    for index in range(check.n_frames):
        check.seek(index)
        assert check.info["duration"] == expected_durations[index]
        assert check.disposal_method == expected_disposals[index]
        assert check.dispose_extent == expected_extents[index]

    check.seek(1)
    second_composited = check.convert("RGBA")
    assert second_composited.getpixel((1, 1)) == (0, 255, 0, 255)
    assert second_composited.getpixel((3, 3)) == (0, 0, 0, 0)
    check.seek(2)
    third_composited = check.convert("RGBA")
    assert third_composited.getpixel((0, 0)) == (0, 0, 255, 255)
    assert third_composited.getpixel((1, 1)) == (0, 0, 0, 0)
