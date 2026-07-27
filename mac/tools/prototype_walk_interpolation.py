#!/usr/bin/env python3
"""PROTOTYPE ONLY: compare repeated, blended, and optical-flow walk frames."""

import argparse
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont


def labelled(frame: Image.Image, title: str) -> Image.Image:
    canvas = Image.new("RGB", (frame.width, frame.height + 42), "#252331")
    canvas.paste(frame, (0, 42))
    draw = ImageDraw.Draw(canvas)
    draw.text((12, 11), title, fill="white", font=ImageFont.load_default(size=18))
    return canvas


def flow_midpoint(first: Image.Image, second: Image.Image) -> Image.Image:
    a = np.asarray(first, dtype=np.uint8)
    b = np.asarray(second, dtype=np.uint8)
    gray_a = cv2.cvtColor(a, cv2.COLOR_RGB2GRAY)
    gray_b = cv2.cvtColor(b, cv2.COLOR_RGB2GRAY)
    settings = (None, 0.5, 4, 25, 5, 7, 1.5, cv2.OPTFLOW_FARNEBACK_GAUSSIAN)
    forward = cv2.calcOpticalFlowFarneback(gray_a, gray_b, *settings)
    backward = cv2.calcOpticalFlowFarneback(gray_b, gray_a, *settings)
    height, width = gray_a.shape
    x, y = np.meshgrid(np.arange(width), np.arange(height))
    map_a_x = (x - forward[..., 0] * 0.5).astype(np.float32)
    map_a_y = (y - forward[..., 1] * 0.5).astype(np.float32)
    map_b_x = (x - backward[..., 0] * 0.5).astype(np.float32)
    map_b_y = (y - backward[..., 1] * 0.5).astype(np.float32)
    warped_a = cv2.remap(a, map_a_x, map_a_y, cv2.INTER_CUBIC,
                         borderMode=cv2.BORDER_REFLECT)
    warped_b = cv2.remap(b, map_b_x, map_b_y, cv2.INTER_CUBIC,
                         borderMode=cv2.BORDER_REFLECT)
    return Image.fromarray(cv2.addWeighted(warped_a, 0.5, warped_b, 0.5, 0))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("strip")
    parser.add_argument("output")
    arguments = parser.parse_args()

    strip = Image.open(arguments.strip).convert("RGBA")
    cell = strip.height
    count = strip.width // cell
    matte = Image.new("RGBA", (cell, cell), "#F1ECE2")
    keys = []
    for index in range(count):
        frame = strip.crop((index * cell, 0, (index + 1) * cell, cell))
        composed = matte.copy()
        composed.alpha_composite(frame)
        keys.append(composed.convert("RGB").resize((384, 384), Image.Resampling.LANCZOS))

    comparison = []
    for index, first in enumerate(keys):
        second = keys[(index + 1) % len(keys)]
        variants = [
            (first, first),
            (first, Image.blend(first, second, 0.5)),
            (first, flow_midpoint(first, second)),
        ]
        for phase in range(2):
            columns = [
                labelled(variants[0][phase], "A  repeated keyframe"),
                labelled(variants[1][phase], "B  cross-dissolve 32"),
                labelled(variants[2][phase], "C  optical-flow 32"),
            ]
            row = Image.new("RGB", (sum(item.width for item in columns), columns[0].height))
            offset = 0
            for column in columns:
                row.paste(column, (offset, 0))
                offset += column.width
            comparison.append(row)

    output = Path(arguments.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    comparison[0].save(output, save_all=True, append_images=comparison[1:],
                       duration=31, loop=0, optimize=True)
    print(output)


if __name__ == "__main__":
    main()
