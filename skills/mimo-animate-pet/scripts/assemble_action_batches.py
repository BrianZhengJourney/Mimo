#!/usr/bin/env python3
"""Concatenate kept panels from chained three-frame action batches."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def parse_batch(value: str) -> tuple[Path, int]:
    try:
        path_value, keep_value = value.rsplit(":", 1)
        keep = int(keep_value)
    except (ValueError, TypeError) as error:
        raise argparse.ArgumentTypeError("expected INPUT.png:KEEP") from error
    if keep <= 0:
        raise argparse.ArgumentTypeError("KEEP must be positive")
    return Path(path_value), keep


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("batches", nargs="+", type=parse_batch)
    parser.add_argument("--source-columns", type=int, default=3)
    args = parser.parse_args()

    panels: list[Image.Image] = []
    panel_size: tuple[int, int] | None = None
    for path, keep in args.batches:
        image = Image.open(path).convert("RGBA")
        if image.width % args.source_columns:
            raise SystemExit(f"{path}: width does not divide into source columns")
        size = (image.width // args.source_columns, image.height)
        if panel_size is None:
            panel_size = size
        elif size != panel_size:
            raise SystemExit(f"{path}: panel size {size} does not match {panel_size}")
        if keep > args.source_columns:
            raise SystemExit(f"{path}: KEEP exceeds source columns")
        panels.extend(
            image.crop((index * size[0], 0, (index + 1) * size[0], size[1]))
            for index in range(keep)
        )

    if panel_size is None:
        raise SystemExit("no batches supplied")
    output = Image.new("RGBA", (panel_size[0] * len(panels), panel_size[1]))
    for index, panel in enumerate(panels):
        output.alpha_composite(panel, (index * panel_size[0], 0))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    output.save(args.output)
    print(f"assembled {len(panels)} panels at {panel_size[0]}x{panel_size[1]}")


if __name__ == "__main__":
    main()
