#!/usr/bin/env python3
"""Remove generator-added panel dividers from a transparent action batch."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--columns", type=int, default=3)
    parser.add_argument("--band", type=int, default=8)
    args = parser.parse_args()

    image = Image.open(args.source).convert("RGBA")
    if args.columns <= 0 or image.width % args.columns:
        raise SystemExit("image width must divide evenly into columns")
    if args.band < 0 or args.band * 2 >= image.width // args.columns:
        raise SystemExit("divider band is invalid")

    alpha = image.getchannel("A")
    pixels = alpha.load()
    boundaries = [index * image.width // args.columns
                  for index in range(args.columns + 1)]
    for boundary in boundaries:
        start = max(0, boundary - args.band)
        end = min(image.width, boundary + args.band)
        for y in range(image.height):
            for x in range(start, end):
                pixels[x, y] = 0
    for y in range(min(args.band, image.height)):
        for x in range(image.width):
            pixels[x, y] = 0
            pixels[x, image.height - 1 - y] = 0

    image.putalpha(alpha)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    image.save(args.output)
    print(f"cleaned {args.columns} panels with {args.band}px divider bands")


if __name__ == "__main__":
    main()
