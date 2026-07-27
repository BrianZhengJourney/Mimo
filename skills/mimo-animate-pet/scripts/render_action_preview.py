#!/usr/bin/env python3
"""Render a normalized horizontal action strip as transparent GIF and WebP."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("strip", type=Path)
    parser.add_argument("--gif", type=Path, required=True)
    parser.add_argument("--webp", type=Path, required=True)
    timing = parser.add_mutually_exclusive_group(required=True)
    timing.add_argument("--fps", type=float)
    timing.add_argument("--durations-ms")
    return parser.parse_args()


def gif_frame(frame: Image.Image) -> Image.Image:
    alpha = frame.getchannel("A")
    paletted = frame.convert("RGB").quantize(
        colors=255, method=Image.Quantize.FASTOCTREE
    )
    palette = (paletted.getpalette() or [])[: 255 * 3]
    palette.extend([0] * (768 - len(palette)))
    paletted.putpalette(palette)
    transparent = alpha.point(lambda value: 255 if value < 16 else 0)
    paletted.paste(255, mask=transparent)
    paletted.info["transparency"] = 255
    return paletted


def main() -> None:
    args = parse_args()
    strip = Image.open(args.strip).convert("RGBA")
    if strip.height <= 0 or strip.width % strip.height:
        raise SystemExit("strip must be exactly one square cell tall")
    cell = strip.height
    frames = [
        strip.crop((index * cell, 0, (index + 1) * cell, cell))
        for index in range(strip.width // cell)
    ]
    if args.durations_ms:
        durations = [int(value) for value in args.durations_ms.split(",")]
        if len(durations) != len(frames) or any(value <= 0 for value in durations):
            raise SystemExit("durations-ms must contain one positive value per frame")
    else:
        if not args.fps or args.fps <= 0:
            raise SystemExit("fps must be positive")
        durations = [round(1000 / args.fps)] * len(frames)

    args.gif.parent.mkdir(parents=True, exist_ok=True)
    args.webp.parent.mkdir(parents=True, exist_ok=True)
    gif_frames = [gif_frame(frame) for frame in frames]
    gif_frames[0].save(
        args.gif,
        save_all=True,
        append_images=gif_frames[1:],
        duration=durations,
        loop=0,
        disposal=2,
        transparency=255,
        optimize=False,
    )
    frames[0].save(
        args.webp,
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        lossless=True,
        quality=100,
        method=6,
    )
    print(f"{len(frames)} frames, {sum(durations)} ms")


if __name__ == "__main__":
    main()
