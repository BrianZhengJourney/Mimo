#!/usr/bin/env python3
"""Render the published walk curves as a stick figure, to judge them by eye.

This deliberately reads nothing but the emitted JSON and evaluates it the way
the runtime will — at an arbitrary frame rate rather than at the driver's 24
sampled phases.  If the figure walks smoothly here, the curves themselves are
smooth; anything that still stutters is the renderer's fault, not the data's.

Usage:
    python3 mac/tools/preview_walk_motion_curves.py \
        --curves mac/assets/motion-curves/side-walk-v1.json \
        --out artifacts/walk-image-experiments/curve-preview.gif --fps 60
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw

NEAR = (34, 34, 34)
FAR = (176, 176, 176)
SPINE = (198, 62, 62)
GROUND = (203, 199, 190)
BG = (250, 249, 246)


def evaluate(series: dict, phase: float) -> float:
    value = series["mean"]
    for k, (c, s) in enumerate(zip(series["cos"], series["sin"]), start=1):
        value += c * math.cos(2 * math.pi * k * phase) + s * math.sin(2 * math.pi * k * phase)
    return value


def skeleton(curves: dict, phase: float, facing: float) -> dict:
    """Joint positions in leg-length units; +x is forward, +y is down."""
    ch, seg = curves["channels"], curves["segmentLengths"]

    def chain(offset: float) -> dict:
        p = (phase + offset) % 1.0
        thigh = math.radians(evaluate(ch["thigh"], p))
        calf = math.radians(evaluate(ch["calf"], p))
        foot = math.radians(evaluate(ch["foot"], p))
        arm = math.radians(evaluate(ch["upperArm"], p))
        fore = math.radians(evaluate(ch["forearm"], p))
        knee = (seg["thigh"] * math.sin(thigh), seg["thigh"] * math.cos(thigh))
        ankle = (knee[0] + seg["calf"] * math.sin(calf),
                 knee[1] + seg["calf"] * math.cos(calf))
        toe = (ankle[0] + seg["foot"] * math.sin(foot),
               ankle[1] + seg["foot"] * math.cos(foot))
        elbow = (seg["upperArm"] * math.sin(arm), seg["upperArm"] * math.cos(arm))
        wrist = (elbow[0] + seg["forearm"] * math.sin(fore),
                 elbow[1] + seg["forearm"] * math.cos(fore))
        return {"knee": knee, "ankle": ankle, "toe": toe, "elbow": elbow, "wrist": wrist}

    hip = (0.0, evaluate(ch["pelvisBob"], phase))
    lean = math.radians(evaluate(ch["torsoLean"], phase))
    torso_len = 0.85
    shoulder = (hip[0] + torso_len * math.sin(lean), hip[1] - torso_len * math.cos(lean))
    head_lean = math.radians(evaluate(ch["headLean"], phase))
    head = (shoulder[0] + 0.32 * math.sin(head_lean),
            shoulder[1] - 0.32 * math.cos(head_lean))

    def anchor(base: tuple[float, float], limb: dict, keys: tuple[str, ...]) -> dict:
        return {k: (base[0] + limb[k][0] * facing, base[1] + limb[k][1]) for k in keys}

    near, far = chain(0.0), chain(0.5)
    out = {"hip": (hip[0] * facing, hip[1]),
           "shoulder": (shoulder[0] * facing, shoulder[1]),
           "head": (head[0] * facing, head[1])}
    for tag, limb in (("near", near), ("far", far)):
        out[tag] = {
            **anchor(out["hip"], limb, ("knee", "ankle", "toe")),
            **anchor(out["shoulder"], limb, ("elbow", "wrist")),
        }
    return out


def render(curves: dict, fps: int, cycles: float, size: int) -> list[Image.Image]:
    facing = -1.0 if curves["facing"] == "left" else 1.0
    period_seconds = curves["periodFrames"] / curves["driverFPS"]
    total = max(1, round(fps * period_seconds * cycles))

    poses = [skeleton(curves, (i / total * cycles) % 1.0, facing) for i in range(total)]

    def every_point(pose: dict):
        yield pose["head"]
        yield pose["hip"]
        for tag in ("near", "far"):
            yield from pose[tag].values()

    xs = [p[0] for pose in poses for p in every_point(pose)]
    ys = [p[1] for pose in poses for p in every_point(pose)]
    ys.append(curves["groundHeightLegUnits"])
    margin = 0.12
    scale = size * (1 - 2 * margin) / max(max(xs) - min(xs), max(ys) - min(ys))
    cx = size / 2 - (max(xs) + min(xs)) / 2 * scale
    cy = size / 2 - (max(ys) + min(ys)) / 2 * scale
    ground_y = cy + curves["groundHeightLegUnits"] * scale

    def to_px(p: tuple[float, float]) -> tuple[float, float]:
        return (cx + p[0] * scale, cy + p[1] * scale)

    frames = []
    for i, joints in enumerate(poses):
        phase = (i / total * cycles) % 1.0
        image = Image.new("RGB", (size, size), BG)
        draw = ImageDraw.Draw(image)
        draw.line([(0, ground_y), (size, ground_y)], fill=GROUND, width=3)

        for tag, colour, width in (("far", FAR, 5), ("near", NEAR, 7)):
            limb = joints[tag]
            for chain in (("hip", "knee", "ankle", "toe"), ("shoulder", "elbow", "wrist")):
                points = [to_px(joints[chain[0]])] + [to_px(limb[k]) for k in chain[1:]]
                draw.line(points, fill=colour, width=width, joint="curve")

        draw.line([to_px(joints["hip"]), to_px(joints["shoulder"])], fill=SPINE, width=8)
        hx, hy = to_px(joints["head"])
        r = 0.17 * scale
        draw.ellipse([hx - r, hy - r, hx + r, hy + r], fill=SPINE)
        draw.text((12, 12), f"phase {phase:5.3f}   {fps}fps from "
                            f"{curves['periodFrames']} sampled phases", fill=(120, 120, 120))
        frames.append(image)
    return frames


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--curves", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--fps", type=int, default=60)
    parser.add_argument("--cycles", type=float, default=2.0)
    parser.add_argument("--size", type=int, default=420)
    args = parser.parse_args()

    curves = json.loads(args.curves.read_text())
    frames = render(curves, args.fps, args.cycles, args.size)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(args.out, save_all=True, append_images=frames[1:],
                   duration=round(1000 / args.fps), loop=0, optimize=True)
    print(f"wrote {args.out} ({len(frames)} frames at {args.fps}fps)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
