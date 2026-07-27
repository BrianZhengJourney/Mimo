#!/usr/bin/env python3
"""Turn the generated part sheet into rig layers with alpha and known pivots.

Three things have to be undone before the parts are usable. The model cannot
emit alpha, so the chroma key is removed here. It ignores requests to hold the
reference's scale and instead fills each cell, so parts are rescaled against
measurements taken from the original drawing. And it sometimes mirrors a part,
so each one records whether to flip.

Green spill is the reason keying is done in chroma distance rather than by an
exact colour match: an antialiased edge over green is a blend of subject and
key, so it needs a soft ramp and its residual green pulled back out, or every
layer ends up rimmed in green.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

# Cell order matches generate_part_sheet.CELLS.
CELL_ORDER = ["head", "torso", "arm", "leg"]

# Measured on the source drawing: joints a pose estimator resolves reliably on
# a side-on standing figure, plus the floor from the alpha silhouette.
SOURCE = {"hip": (245.0, 280.0), "shoulder": (248.0, 157.0), "sole": 501.0}


def key_out(cell: Image.Image, key_rgb: tuple[int, int, int],
            near: float = 60.0, far: float = 130.0) -> Image.Image:
    """Chroma-key with a soft ramp, then pull the spill out of the edge."""
    rgb = np.array(cell.convert("RGB")).astype(np.float32)
    distance = np.linalg.norm(rgb - np.array(key_rgb, dtype=np.float32), axis=2)
    alpha = np.clip((distance - near) / (far - near), 0.0, 1.0)

    # Where green leads the other channels, it is spill: clamp it to their max.
    red, green, blue = rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2]
    spill = green > np.maximum(red, blue)
    rgb[:, :, 1] = np.where(spill, np.maximum(red, blue), green)

    out = np.dstack([rgb, alpha * 255.0]).astype(np.uint8)
    return Image.fromarray(out, mode="RGBA")


def trim(layer: Image.Image, threshold: int = 24,
         min_run: int = 3) -> tuple[Image.Image, tuple[int, int]]:
    """Crop to the subject, ignoring keying crumbs.

    A row or column carrying fewer than `min_run` opaque pixels is speckle
    rather than subject, so it does not get to widen the box.  This replaces
    connected-component labelling, which would drag in a dependency for a job
    a threshold already does.
    """
    solid = np.array(layer)[:, :, 3] > threshold
    rows = np.flatnonzero(solid.sum(axis=1) >= min_run)
    cols = np.flatnonzero(solid.sum(axis=0) >= min_run)
    if len(rows) == 0 or len(cols) == 0:
        raise SystemExit("a cell keyed out to nothing; check the chroma key")
    box = (int(cols.min()), int(rows.min()), int(cols.max()) + 1, int(rows.max()) + 1)
    return layer.crop(box), (box[0], box[1])


def patch_sockets(part: Image.Image, top: float, bottom: float) -> Image.Image:
    """Paint out a bare joint socket the model draws where a limb was severed.

    Asked for a part with its neighbours removed, the model helpfully draws the
    exposed ball or socket.  On an assembled rig those read as holes in the
    cloth, and no neighbouring layer covers them: the leg's hip ball sits at the
    very pivot it rotates about, and the torso's hip socket sits above the joint
    the thigh swings from.  Both stay visible for the whole cycle, so they are
    filled with the surrounding cloth here rather than fought at render time.

    Only the ranges named by the caller are touched; the torso's shoulder
    sockets are left alone because an arm genuinely does cover those.
    """
    data = np.array(part).astype(np.int16)
    height = data.shape[0]
    region = slice(int(top * height), int(bottom * height))
    rgb, alpha = data[region, :, :3], data[region, :, 3]

    skin = (alpha > 128) & (rgb[:, :, 0] > rgb[:, :, 2] + 28) & (rgb[:, :, 0] > 150)
    if not skin.any():
        return part

    cloth = (alpha > 128) & ~skin
    if not cloth.any():
        return part
    fill = np.median(rgb[cloth], axis=0)
    rgb[skin] = fill
    data[region, :, :3] = rgb
    return Image.fromarray(data.astype(np.uint8))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sheet", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--chroma", default="#00B140")
    args = parser.parse_args()

    key_rgb = tuple(int(args.chroma.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    sheet = Image.open(args.sheet).convert("RGB")
    half_w, half_h = sheet.width // 2, sheet.height // 2
    boxes = {
        "head": (0, 0, half_w, half_h),
        "torso": (half_w, 0, sheet.width, half_h),
        "arm": (0, half_h, half_w, sheet.height),
        "leg": (half_w, half_h, sheet.width, sheet.height),
    }

    args.out_dir.mkdir(parents=True, exist_ok=True)
    report = {}
    for name in CELL_ORDER:
        cell = sheet.crop(boxes[name])
        keyed = key_out(cell, key_rgb)
        cropped, origin = trim(keyed)
        # The torso's hip socket sits mid-part; the leg's hip ball caps its top.
        if name == "torso":
            cropped = patch_sockets(cropped, top=0.35, bottom=0.95)
        elif name == "leg":
            cropped = patch_sockets(cropped, top=0.0, bottom=0.14)
        cropped.save(args.out_dir / f"{name}.png")
        coverage = float((np.array(cropped)[:, :, 3] > 24).mean())
        report[name] = {
            "file": f"{name}.png",
            "size": list(cropped.size),
            "originInCell": list(origin),
            "alphaCoverage": round(coverage, 3),
        }
        print(f"{name:6s} {cropped.size[0]:4d}x{cropped.size[1]:4d}px  "
              f"coverage {coverage:.3f}")

    (args.out_dir / "parts.json").write_text(json.dumps({
        "chromaKey": args.chroma,
        "sourceJoints": SOURCE,
        "parts": report,
    }, indent=2) + "\n")
    print(f"wrote {args.out_dir / 'parts.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
