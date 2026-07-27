#!/usr/bin/env python3
"""Generate Mimo's deterministic 16-key-pose biped walk reference."""

from math import cos, floor, pi, sin
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


CELL = 240
COLS = 4
ROWS = 4
BACKGROUND = "#F1ECE2"
INK = "#252331"
LEFT = "#2374D8"
RIGHT = "#E06B32"
GRID = "#B7B1A9"

# One leg from heel contact through stance, toe-off, swing, and pre-contact.
# Coordinates are offsets from the hip; y=0 below means the shared ground.
FOOT_PHASES = [
    (-42, 0), (-32, 0), (-20, 0), (-8, 0),
    (5, 0), (18, 0), (30, 0), (36, -2),
    (34, 0), (38, -2), (34, -12), (22, -32),
    (4, -48), (-18, -40), (-34, -20), (-42, -4),
]


def font(size: int):
    try:
        return ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    except OSError:
        return ImageFont.load_default()


def point(x: float, y: float, origin_x: int, origin_y: int):
    return (origin_x + x, origin_y + y)


def limb(draw: ImageDraw.ImageDraw, joints, color: str, width: int):
    draw.line(joints, fill=color, width=width, joint="curve")
    radius = width // 2 + 2
    for x, y in joints:
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)


def foot_at(phase: float):
    base = floor(phase) % len(FOOT_PHASES)
    fraction = phase - floor(phase)
    following = (base + 1) % len(FOOT_PHASES)
    return tuple(FOOT_PHASES[base][axis] * (1 - fraction)
                 + FOOT_PHASES[following][axis] * fraction for axis in range(2))


def draw_frame(draw: ImageDraw.ImageDraw, phase: float, label: str, slot: int,
               columns: int = COLS):
    col, row = slot % columns, slot // columns
    ox, oy = col * CELL, row * CELL
    hip_x = ox + 122
    # 48/240 = 20% bottom safety band, matching 96px on a 512px output cell.
    ground_y = oy + 192
    bob = 4 * cos(phase * 4 * pi / 16)
    hip_y = oy + 108 + bob
    shoulder = (hip_x, hip_y - 48)
    head = (hip_x - 2, hip_y - 70)

    # A full period is 16 key poses; the opposite limb is exactly half a period apart.
    left_dx, left_lift = foot_at(phase)
    right_dx, right_lift = foot_at((phase - 8) % 16)
    left_foot = (hip_x + left_dx, ground_y + left_lift)
    right_foot = (hip_x + right_dx, ground_y + right_lift)

    def knee(foot):
        # Forward knee bend makes leg identity readable without pretending the
        # guide is a final anatomical drawing.
        return ((hip_x + foot[0]) / 2 - 10, (hip_y + foot[1]) / 2 + 7)

    swing = cos(2 * pi * phase / 16)
    left_hand = (hip_x + 31 * swing, hip_y + 13 + 4 * sin(2 * pi * phase / 16))
    right_hand = (hip_x - 31 * swing, hip_y + 13 - 4 * sin(2 * pi * phase / 16))

    def elbow(hand, bend):
        return ((shoulder[0] + hand[0]) / 2 + bend,
                (shoulder[1] + hand[1]) / 2 + 5)

    # Far/right limbs first, then torso, then near/left limbs.
    limb(draw, [(hip_x, hip_y), knee(right_foot), right_foot], RIGHT, 7)
    limb(draw, [shoulder, elbow(right_hand, 6), right_hand], RIGHT, 6)
    draw.line([shoulder, (hip_x, hip_y)], fill=INK, width=10)
    draw.ellipse((head[0] - 15, head[1] - 15, head[0] + 15, head[1] + 15),
                 outline=INK, width=7)
    draw.line([(head[0] - 15, head[1]), (head[0] - 23, head[1] + 4)], fill=INK, width=5)
    limb(draw, [(hip_x, hip_y), knee(left_foot), left_foot], LEFT, 9)
    limb(draw, [shoulder, elbow(left_hand, -6), left_hand], LEFT, 7)

    draw.text((ox + 12, oy + 10), label, fill=INK, font=font(17))
    draw.line([(ox + 202, oy + 27), (ox + 168, oy + 27)], fill=INK, width=4)
    draw.polygon([(ox + 168, oy + 27), (ox + 179, oy + 20), (ox + 179, oy + 34)], fill=INK)
    draw.line([(ox + 18, ground_y), (ox + CELL - 18, ground_y)], fill=GRID, width=2)


def render(output: Path, phases, prefix: str, columns: int = COLS, rows: int = ROWS,
           first_label: int = 1):
    output.parent.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGB", (CELL * columns, CELL * rows), BACKGROUND)
    draw = ImageDraw.Draw(image)
    for slot, phase in enumerate(phases):
        draw_frame(draw, phase, f"{prefix}{slot + first_label:02d}", slot, columns)
    for col in range(1, columns):
        x = col * CELL
        draw.line([(x, 0), (x, CELL * rows)], fill=GRID, width=2)
    for row in range(1, rows):
        y = row * CELL
        draw.line([(0, y), (CELL * columns, y)], fill=GRID, width=2)
    image.save(output, "PNG", optimize=True)
    print(output)


def main():
    directory = Path(__file__).resolve().parents[1] / "assets" / "motion-reference"
    render(directory / "biped-walk-cycle-16.png", range(16), "K")
    render(directory / "biped-walk-inbetweens-16.png",
           [index + 0.5 for index in range(16)], "M")
    render(directory / "biped-walk-inbetweens-13-16.png",
           [index + 0.5 for index in range(12, 16)], "M",
           columns=2, rows=2, first_label=13)


if __name__ == "__main__":
    main()
