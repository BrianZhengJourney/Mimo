#!/usr/bin/env python3
"""Drive the drawn character itself with the extracted walk curves.

This is the other half of the experiment.  `extract_walk_motion_curves.py`
kept Wan's timing and threw its pixels away; this keeps the drawn pixels and
throws away everything else.  Nothing here generates or repaints image content:
every pixel on screen is cut from the source portrait and moved.

That is the whole argument for a rig over a video model.  A repainting model
re-imagines the character each frame, which is where the hair colour and the
line work went.  A rig cannot drift, because there is nothing to drift — the
transform is analytic, so it also evaluates at any phase and any frame rate.

Deliberately crude, to answer one question cheaply: is the motion good enough
to be worth cutting proper layers for?  Limbs are cut as horizontal bands of
the silhouette, the occluded far side is a darkened copy of the near side, and
joints are butted rather than skinned.

Usage:
    python3 mac/tools/rig_walk_preview.py \
        --character mac/assets/motion-driver/mimo-side-walk-v1/character.png \
        --curves mac/assets/motion-curves/side-walk-v1.json \
        --out artifacts/walk-image-experiments/rig-walk.gif
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

# Fraction of a leg length each band overlaps its neighbour, so a bent joint
# shows a seam of overlapping pixels rather than a gap.
JOINT_OVERLAP = 0.045
FAR_SIDE_SHADE = 0.88


def evaluate(series: dict, phase: float) -> float:
    value = series["mean"]
    for k, (c, s) in enumerate(zip(series["cos"], series["sin"]), start=1):
        value += c * math.cos(2 * math.pi * k * phase) + s * math.sin(2 * math.pi * k * phase)
    return value


def deviation(series: dict, phase: float) -> float:
    """Motion only, with the segment's average pose removed.

    Channels whose average encodes anatomy rather than gait — an ankle-to-toe
    vector points forward, a shoulder-to-nose vector points forward and up —
    would tip a drawn limb out of its rest pose if applied whole.
    """
    return evaluate(series, phase) - series["mean"]


@dataclass(frozen=True)
class Rig:
    """Where the drawn character's joints are, in its own pixel space."""

    image: Image.Image
    hip: tuple[float, float]
    shoulder: tuple[float, float]
    knee_y: float
    ankle_y: float
    ground_y: float
    leg_px: float


def build_rig(character: Path, curves: dict) -> Rig:
    image = Image.open(character).convert("RGBA")
    alpha = np.array(image)[:, :, 3]
    rows = np.nonzero((alpha > 8).any(axis=1))[0]
    ground_y = float(rows.max())

    # Measured on the drawing: shoulders and hips are the two joints a pose
    # estimator gets right on a side-on standing figure.
    hip = (245.0, 280.0)
    shoulder = (248.0, 157.0)

    # Legs are derived rather than detected.  With both legs drawn together the
    # estimator cannot tell them apart, but the curves already state where a
    # knee and an ankle sit along a leg, and the drawing states where the floor
    # is.  Deriving keeps the rig consistent with the motion it will play.
    leg_px = (ground_y - hip[1]) / curves["groundHeightLegUnits"]
    knee_y = hip[1] + curves["segmentLengths"]["thigh"] * leg_px
    ankle_y = knee_y + curves["segmentLengths"]["calf"] * leg_px
    return Rig(image, hip, shoulder, knee_y, ankle_y, ground_y, leg_px)


def band(rig: Rig, top: float, bottom: float, feather: float = 0.0) -> Image.Image:
    """One horizontal slice of the drawing, kept on the full canvas."""
    layer = rig.image.copy()
    alpha = np.array(layer)[:, :, 3].astype(np.float32)
    rows = np.arange(layer.height)[:, None].astype(np.float32)
    keep = np.ones_like(alpha)
    if feather > 0:
        keep *= np.clip((rows - (top - feather)) / feather, 0, 1)
        keep *= np.clip(((bottom + feather) - rows) / feather, 0, 1)
    else:
        keep *= ((rows >= top) & (rows < bottom)).astype(np.float32)
    out = np.array(layer)
    out[:, :, 3] = (alpha * keep).astype(np.uint8)
    return Image.fromarray(out)


def shaded(layer: Image.Image, factor: float) -> Image.Image:
    data = np.array(layer).astype(np.float32)
    data[:, :, :3] *= factor
    return Image.fromarray(data.astype(np.uint8))


def place(layer: Image.Image, pivot: tuple[float, float], degrees: float,
          to: tuple[float, float], canvas: Image.Image) -> None:
    """Rotate a layer about `pivot` and composite it with `pivot` landing on `to`."""
    if abs(degrees) > 1e-6:
        layer = layer.rotate(-degrees, resample=Image.BICUBIC, center=pivot)
    canvas.alpha_composite(layer, (round(to[0] - pivot[0]), round(to[1] - pivot[1])))


def render_frame(rig: Rig, layers: dict, curves: dict, phase: float,
                 canvas_size: tuple[int, int], offset: tuple[float, float]) -> Image.Image:
    ch = curves["channels"]
    facing = -1.0 if curves["facing"] == "left" else 1.0
    canvas = Image.new("RGBA", canvas_size, (0, 0, 0, 0))

    bob = evaluate(ch["pelvisBob"], phase) * rig.leg_px
    hip = (rig.hip[0] + offset[0], rig.hip[1] + offset[1] + bob)

    def limb(side_phase: float, tag: str) -> None:
        # Thigh and calf take their absolute angles: the drawing stands with
        # its legs vertical, which is zero in the curves' convention, so the
        # ankle lands exactly where the solved ground says it should.
        thigh = facing * evaluate(ch["thigh"], side_phase)
        calf = facing * evaluate(ch["calf"], side_phase)
        foot = facing * deviation(ch["foot"], side_phase)

        knee = (hip[0] - math.sin(math.radians(thigh)) * curves["segmentLengths"]["thigh"] * rig.leg_px,
                hip[1] + math.cos(math.radians(thigh)) * curves["segmentLengths"]["thigh"] * rig.leg_px)
        ankle = (knee[0] - math.sin(math.radians(calf)) * curves["segmentLengths"]["calf"] * rig.leg_px,
                 knee[1] + math.cos(math.radians(calf)) * curves["segmentLengths"]["calf"] * rig.leg_px)

        place(layers[f"thigh_{tag}"], (rig.hip[0], rig.hip[1]), thigh, hip, canvas)
        place(layers[f"calf_{tag}"], (rig.hip[0], rig.knee_y), calf, knee, canvas)
        place(layers[f"foot_{tag}"], (rig.hip[0], rig.ankle_y), foot, ankle, canvas)

    limb((phase + curves["farSidePhaseOffset"]) % 1.0, "far")

    lean = facing * deviation(ch["torsoLean"], phase)
    shoulder = (hip[0] - math.sin(math.radians(lean)) * (rig.hip[1] - rig.shoulder[1]),
                hip[1] - math.cos(math.radians(lean)) * (rig.hip[1] - rig.shoulder[1]))
    place(layers["torso"], (rig.hip[0], rig.hip[1]), lean, hip, canvas)
    limb(phase, "near")
    place(layers["head"], (rig.shoulder[0], rig.shoulder[1]),
          lean + facing * deviation(ch["headLean"], phase), shoulder, canvas)
    return canvas


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--character", type=Path, required=True)
    parser.add_argument("--curves", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--fps", type=int, default=50)
    parser.add_argument("--cycles", type=float, default=2.0)
    parser.add_argument("--background", default="#f7f5f0")
    args = parser.parse_args()

    curves = json.loads(args.curves.read_text())
    rig = build_rig(args.character, curves)

    overlap = JOINT_OVERLAP * rig.leg_px
    cuts = {
        "head": (0.0, rig.shoulder[1] + overlap),
        "torso": (rig.shoulder[1] - overlap, rig.hip[1] + overlap),
        "thigh": (rig.hip[1] - overlap, rig.knee_y + overlap),
        "calf": (rig.knee_y - overlap, rig.ankle_y + overlap),
        "foot": (rig.ankle_y - overlap, float(rig.image.height)),
    }
    layers = {}
    for name, (top, bottom) in cuts.items():
        cut = band(rig, top, bottom, feather=overlap * 0.5)
        if name in ("thigh", "calf", "foot"):
            layers[f"{name}_near"] = cut
            layers[f"{name}_far"] = shaded(cut, FAR_SIDE_SHADE)
        else:
            layers[name] = cut

    size = (rig.image.width, rig.image.height)
    offset = (0.0, -0.02 * rig.leg_px)
    period_seconds = curves["periodFrames"] / curves["driverFPS"]
    total = max(1, round(args.fps * period_seconds * args.cycles))

    frames = []
    for i in range(total):
        phase = (i / total * args.cycles) % 1.0
        rendered = render_frame(rig, layers, curves, phase, size, offset)
        flat = Image.new("RGB", size, args.background)
        flat.paste(rendered, mask=rendered.split()[3])
        frames.append(flat)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(args.out, save_all=True, append_images=frames[1:],
                   duration=round(1000 / args.fps), loop=0, optimize=True)
    print(f"wrote {args.out} ({len(frames)} frames at {args.fps}fps, leg {rig.leg_px:.1f}px)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
