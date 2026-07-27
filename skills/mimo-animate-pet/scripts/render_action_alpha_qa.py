#!/usr/bin/env python3
"""Render an alpha strip over light, dark, and checkerboard QA backgrounds."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw


def checker(size: tuple[int, int], tile: int = 16) -> Image.Image:
    image = Image.new("RGB", size, "#E5E5E5")
    draw = ImageDraw.Draw(image)
    for y in range(0, size[1], tile):
        for x in range(0, size[0], tile):
            if (x // tile + y // tile) % 2:
                draw.rectangle(
                    (x, y, min(x + tile - 1, size[0] - 1),
                     min(y + tile - 1, size[1] - 1)),
                    fill="#B7B7B7",
                )
    return image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("strip", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", type=int, default=2304)
    args = parser.parse_args()

    source = Image.open(args.strip).convert("RGBA")
    if args.width <= 0:
        raise SystemExit("width must be positive")
    height = max(1, round(source.height * args.width / source.width))
    strip = source.resize((args.width, height), Image.Resampling.LANCZOS)
    backgrounds = [
        Image.new("RGB", strip.size, "#F5F2EC"),
        Image.new("RGB", strip.size, "#181818"),
        checker(strip.size),
    ]
    rows = []
    for background in backgrounds:
        background.paste(strip, (0, 0), strip.getchannel("A"))
        rows.append(background)

    output = Image.new("RGB", (args.width, height * len(rows)))
    for index, row in enumerate(rows):
        output.paste(row, (0, index * height))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    output.save(args.output)
    print(f"wrote {args.output} at {output.width}x{output.height}")


if __name__ == "__main__":
    main()
