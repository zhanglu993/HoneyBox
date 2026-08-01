"""Deterministically generate the small GIF used by the WIC integration tests."""

from pathlib import Path
from struct import pack

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


def make_frame(
    width: int, height: int, pixels: list[int], palette: list[int] = PALETTE
) -> Image.Image:
    frame = Image.new("P", (width, height), TRANSPARENT)
    frame.putpalette(palette)
    frame.putdata(pixels)
    return frame


def frame_blocks(
    frame: Image.Image,
    offset: tuple[int, int],
    duration: int,
    disposal: int,
    *,
    transparency: int | None = None,
    include_color_table: bool,
) -> list[bytes]:
    params = {
        "duration": duration,
        "disposal": disposal,
        "include_color_table": include_color_table,
    }
    if transparency is not None:
        params["transparency"] = transparency
    blocks = GifImagePlugin.getdata(frame, offset=offset, **params)
    descriptor = next(block for block in blocks if block.startswith(b","))
    assert bool(descriptor[9] & 0x80) == include_color_table
    return blocks


first = make_frame(WIDTH, HEIGHT, [RED] * (WIDTH * HEIGHT))

second = make_frame(2, 2, [GREEN, TRANSPARENT, TRANSPARENT, GREEN])

third = make_frame(2, 2, [BLUE, TRANSPARENT, BLUE, TRANSPARENT])

output_directory = Path(__file__).parent
output = output_directory / "animated_disposal.gif"

# No global color table: all three frames deliberately carry local tables.
# This keeps the main fixture's transparent-background contract explicit.
blocks = [b"GIF89a" + pack("<HHBBB", WIDTH, HEIGHT, 0x70, 0, 0)]
for frame, offset, duration, disposal in [
    (first, (0, 0), 50, 3),
    (second, (1, 1), 100, 2),
    (third, (0, 0), 150, 1),
]:
    blocks.extend(
        frame_blocks(
            frame,
            offset,
            duration,
            disposal,
            transparency=TRANSPARENT,
            include_color_table=True,
        )
    )
output.write_bytes(b"".join(blocks) + b";")
assert not (output.read_bytes()[10] & 0x80)

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


# Auxiliary fixture: valid opaque logical-screen background, an observable
# keep transition, and a local palette whose index 1 differs from global index 1.
auxiliary_palette = [
    0, 0, 0,
    255, 0, 255,
    0, 255, 255,
    255, 255, 255,
] + [0, 0, 0] * 252
logical_palette = [
    0, 0, 0,
    10, 20, 30,
    255, 0, 0,
    0, 0, 255,
] + [0, 0, 0] * 252
auxiliary_header = (
    b"GIF89a"
    + pack("<HHBBB", 3, 2, 0x81, 1, 0)
    + bytes(logical_palette[: 4 * 3])
)
auxiliary_blocks = [auxiliary_header]
auxiliary_blocks.extend(
    frame_blocks(
        make_frame(2, 2, [2, 2, 2, 2], logical_palette),
        (0, 0),
        20,
        2,
        include_color_table=False,
    )
)
auxiliary_blocks.extend(
    frame_blocks(
        make_frame(1, 1, [1], auxiliary_palette),
        (0, 0),
        30,
        1,
        include_color_table=True,
    )
)
auxiliary_blocks.extend(
    frame_blocks(
        make_frame(1, 1, [3], logical_palette),
        (2, 0),
        40,
        1,
        include_color_table=False,
    )
)
auxiliary_output = output_directory / "background_keep_local_palette.gif"
auxiliary_output.write_bytes(b"".join(auxiliary_blocks) + b";")
assert auxiliary_output.read_bytes()[10] & 0x80
assert auxiliary_output.read_bytes()[11] == 1

with Image.open(auxiliary_output) as check:
    assert check.size == (3, 2)
    assert check.n_frames == 3
    check.seek(0)
    first_composited = check.convert("RGBA")
    assert first_composited.getpixel((0, 0)) == (255, 0, 0, 255)
    check.seek(1)
    second_composited = check.convert("RGBA")
    assert second_composited.getpixel((0, 0)) == (255, 0, 255, 255)
    assert second_composited.getpixel((1, 1)) == (10, 20, 30, 255)
    check.seek(2)
    third_composited = check.convert("RGBA")
    assert third_composited.getpixel((0, 0)) == (255, 0, 255, 255)
    assert third_composited.getpixel((2, 0)) == (0, 0, 255, 255)
