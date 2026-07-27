#!/usr/bin/env python3
"""Repack three disconnected action subjects into strict equal-width panels."""

from __future__ import annotations

import argparse
from collections import deque
from dataclasses import dataclass
from pathlib import Path

from PIL import Image


@dataclass
class Component:
    pixels: list[tuple[int, int]]
    bounds: tuple[int, int, int, int]

    @property
    def area(self) -> int:
        return len(self.pixels)

    @property
    def center(self) -> tuple[float, float]:
        left, top, right, bottom = self.bounds
        return ((left + right) / 2, (top + bottom) / 2)


def components(alpha: Image.Image, threshold: int) -> list[Component]:
    width, height = alpha.size
    source = alpha.load()
    seen = bytearray(width * height)
    found: list[Component] = []
    for y in range(height):
        for x in range(width):
            offset = y * width + x
            if seen[offset] or source[x, y] <= threshold:
                continue
            queue = deque([(x, y)])
            seen[offset] = 1
            pixels: list[tuple[int, int]] = []
            left = right = x
            top = bottom = y
            while queue:
                px, py = queue.popleft()
                pixels.append((px, py))
                left = min(left, px)
                right = max(right, px)
                top = min(top, py)
                bottom = max(bottom, py)
                for nx, ny in (
                    (px - 1, py), (px + 1, py),
                    (px, py - 1), (px, py + 1),
                ):
                    if not (0 <= nx < width and 0 <= ny < height):
                        continue
                    neighbor = ny * width + nx
                    if seen[neighbor] or source[nx, ny] <= threshold:
                        continue
                    seen[neighbor] = 1
                    queue.append((nx, ny))
            found.append(Component(
                pixels=pixels,
                bounds=(left, top, right + 1, bottom + 1),
            ))
    return found


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--columns", type=int, default=3)
    parser.add_argument("--alpha-threshold", type=int, default=16)
    parser.add_argument("--min-component-area", type=int, default=100)
    parser.add_argument("--side-padding", type=int, default=16)
    parser.add_argument("--top-padding", type=int, default=16)
    parser.add_argument("--bottom-padding", type=int, default=64)
    args = parser.parse_args()

    image = Image.open(args.source).convert("RGBA")
    if args.columns <= 0 or image.width % args.columns:
        raise SystemExit("source width must divide evenly into columns")
    cell_width = image.width // args.columns
    cell_height = image.height
    found = components(image.getchannel("A"), args.alpha_threshold)
    large = sorted(found, key=lambda item: item.area, reverse=True)[:args.columns]
    if len(large) != args.columns:
        raise SystemExit(f"expected {args.columns} large subjects, found {len(large)}")
    large.sort(key=lambda item: item.center[0])

    groups: list[list[Component]] = [[component] for component in large]
    large_ids = {id(component) for component in large}
    for component in found:
        if id(component) in large_ids or component.area < args.min_component_area:
            continue
        cx, cy = component.center
        target = min(
            range(args.columns),
            key=lambda index: (
                (cx - large[index].center[0]) ** 2
                + (cy - large[index].center[1]) ** 2
            ),
        )
        groups[target].append(component)

    bounds = []
    for group in groups:
        bounds.append((
            max(0, min(item.bounds[0] for item in group) - 1),
            max(0, min(item.bounds[1] for item in group) - 1),
            min(image.width, max(item.bounds[2] for item in group) + 1),
            min(image.height, max(item.bounds[3] for item in group) + 1),
        ))
    available_width = cell_width - args.side_padding * 2
    available_height = cell_height - args.top_padding - args.bottom_padding
    scale = min(
        1.0,
        min(
            available_width / (right - left)
            for left, _, right, _ in bounds
        ),
        min(
            available_height / (bottom - top)
            for _, top, _, bottom in bounds
        ),
    )

    output = Image.new("RGBA", image.size)
    source_pixels = image.load()
    for index, (left, top, right, bottom) in enumerate(bounds):
        isolated = Image.new("RGBA", image.size)
        isolated_pixels = isolated.load()
        for component in groups[index]:
            for px, py in component.pixels:
                for y in range(max(0, py - 1), min(image.height, py + 2)):
                    for x in range(max(0, px - 1), min(image.width, px + 2)):
                        if source_pixels[x, y][3] > 0:
                            isolated_pixels[x, y] = source_pixels[x, y]
        crop = isolated.crop((left, top, right, bottom))
        if scale < 1:
            crop = crop.resize(
                (max(1, round(crop.width * scale)),
                 max(1, round(crop.height * scale))),
                Image.Resampling.LANCZOS,
            )
        x = index * cell_width + (cell_width - crop.width) // 2
        y = cell_height - args.bottom_padding - crop.height
        output.alpha_composite(crop, (x, y))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    output.save(args.output)
    print(
        f"repacked {args.columns} subjects at shared scale {scale:.4f}; "
        f"bounds={bounds}"
    )


if __name__ == "__main__":
    main()
