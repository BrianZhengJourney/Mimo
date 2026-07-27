#!/usr/bin/env python3
"""Walk the drawn character using generated part layers and extracted curves.

Every pixel here is drawn art — either from the original portrait or from the
one part sheet the model produced for this character.  Nothing is repainted per
frame, so nothing can drift: the hair cannot change colour and the shoes cannot
grow patches, because no model runs while this animates.

The two inputs come from opposite places on purpose.  `side-walk-v1.json`
carries Muybridge's timing with its pixels discarded; the part layers carry the
character's pixels with all motion discarded.  This joins them.

Layer scales are half measured and half derived.  `register_parts.py` locks the
head and the arm onto the source drawing by edge correlation, but the trousers
are almost featureless white and their correlation peak is too shallow to
trust, so the leg and torso are sized from joints instead: hip to sole is a
length the drawing states outright.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image

FAR_SIDE_SHADE = 0.88
# Overlap between adjacent segments, as a fraction of the part's own length, so
# a bent joint shows doubled pixels rather than a gap.
JOINT_OVERLAP = 0.035

# `headLean` is measured shoulder-midpoint to nose, and on a strict side view
# both shoulders project to nearly the same point, so that midpoint jitters and
# the noise lands straight in this channel: it swings 43 degrees peak to peak
# where a walking head nods about four.  The gait is not in it, so the head
# follows the torso and takes only a token share of its own channel.
HEAD_LEAN_GAIN = 0.08


@dataclass
class PartSpec:
    """How one generated part maps onto the skeleton.

    Fractions are of the part's own trimmed height, measured from its top.
    """

    scale: float
    pivot: tuple[float, float]
    cuts: dict = field(default_factory=dict)


# Tuned against the rest-pose assembly this tool renders with --rest.
LAYOUT = {
    "head": PartSpec(scale=0.52, pivot=(0.35, 0.51)),
    "torso": PartSpec(scale=0.482, pivot=(0.50, 0.78)),
    "arm": PartSpec(scale=0.45, pivot=(0.50, 0.03), cuts={"elbow": 0.456}),
    "leg": PartSpec(scale=0.534, pivot=(0.50, 0.03),
                    cuts={"knee": 0.443, "ankle": 0.88}),
}

# Where the drawing puts the joints the whole rig hangs from.
SHOULDER = (248.0, 157.0)
HIP = (245.0, 280.0)


def evaluate(series: dict, phase: float) -> float:
    value = series["mean"]
    for k, (c, s) in enumerate(zip(series["cos"], series["sin"]), start=1):
        value += c * math.cos(2 * math.pi * k * phase) + s * math.sin(2 * math.pi * k * phase)
    return value


def deviation(series: dict, phase: float) -> float:
    """Motion only: a channel's average encodes anatomy, not gait."""
    return evaluate(series, phase) - series["mean"]


def load_part(path: Path, spec: PartSpec) -> Image.Image:
    part = Image.open(path).convert("RGBA")
    size = (max(1, round(part.width * spec.scale)), max(1, round(part.height * spec.scale)))
    return part.resize(size, Image.LANCZOS)


def slice_band(part: Image.Image, top: float, bottom: float,
               feather: float) -> Image.Image:
    """Cut a segment out of an isolated limb, softened at both ends."""
    data = np.array(part).astype(np.float32)
    rows = np.arange(part.height, dtype=np.float32)[:, None]
    keep = np.ones((part.height, 1), dtype=np.float32)
    if feather > 0:
        keep = keep * np.clip((rows - (top - feather)) / feather, 0, 1)
        keep = keep * np.clip(((bottom + feather) - rows) / feather, 0, 1)
    else:
        keep = ((rows >= top) & (rows < bottom)).astype(np.float32)
    data[:, :, 3] *= keep
    return Image.fromarray(data.astype(np.uint8))


def shaded(layer: Image.Image, factor: float) -> Image.Image:
    data = np.array(layer).astype(np.float32)
    data[:, :, :3] *= factor
    return Image.fromarray(data.astype(np.uint8))


def place(layer: Image.Image, pivot: tuple[float, float], degrees: float,
          to: tuple[float, float], canvas: Image.Image) -> None:
    if abs(degrees) > 1e-6:
        layer = layer.rotate(-degrees, resample=Image.BICUBIC, center=pivot)
    canvas.alpha_composite(layer, (round(to[0] - pivot[0]), round(to[1] - pivot[1])))


def build_segments(layers_dir: Path) -> dict:
    """Cut the arm and the leg into their bones; keep head and torso whole."""
    segments = {}
    for name, spec in LAYOUT.items():
        part = load_part(layers_dir / f"{name}.png", spec)
        pivot = (spec.pivot[0] * part.width, spec.pivot[1] * part.height)
        if not spec.cuts:
            segments[name] = {"image": part, "pivot": pivot, "length": part.height}
            continue

        overlap = JOINT_OVERLAP * part.height
        stops = [0.0] + [f * part.height for f in spec.cuts.values()] + [float(part.height)]
        names = {"arm": ["upperArm", "forearm"],
                 "leg": ["thigh", "calf", "foot"]}[name]
        for index, bone in enumerate(names):
            top, bottom = stops[index], stops[index + 1]
            band = slice_band(part, top - overlap, bottom + overlap, feather=overlap * 0.6)
            # Each bone rotates about its own upper joint, in the part's frame.
            segments[bone] = {
                "image": band,
                "pivot": (pivot[0], top if index else pivot[1]),
                "length": bottom - top,
            }
    return segments


def render_frame(segments: dict, curves: dict, phase: float, size: tuple[int, int],
                 leg_px: float) -> Image.Image:
    ch = curves["channels"]
    facing = -1.0 if curves["facing"] == "left" else 1.0
    lengths = curves["segmentLengths"]
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))

    hip = (HIP[0], HIP[1] + evaluate(ch["pelvisBob"], phase) * leg_px)
    lean = facing * deviation(ch["torsoLean"], phase)
    torso_len = HIP[1] - SHOULDER[1]
    shoulder = (hip[0] - math.sin(math.radians(lean)) * torso_len,
                hip[1] - math.cos(math.radians(lean)) * torso_len)

    def chain(root: tuple[float, float], bones, side_phase: float, tag: str) -> None:
        point = root
        for bone, channel, absolute in bones:
            angle = facing * (evaluate(ch[channel], side_phase) if absolute
                              else deviation(ch[channel], side_phase))
            spec = segments[bone]
            layer = spec["image"] if tag == "near" else shaded(spec["image"], FAR_SIDE_SHADE)
            place(layer, spec["pivot"], angle, point, canvas)
            reach = lengths[channel] * leg_px
            point = (point[0] - math.sin(math.radians(angle)) * reach,
                     point[1] + math.cos(math.radians(angle)) * reach)

    # Thigh and calf use absolute angles: the drawn leg hangs vertical, which
    # is zero in the curves' convention, so the ankle meets the solved ground.
    leg_bones = [("thigh", "thigh", True), ("calf", "calf", True), ("foot", "foot", False)]
    arm_bones = [("upperArm", "upperArm", False), ("forearm", "forearm", False)]
    far = (phase + curves["farSidePhaseOffset"]) % 1.0

    chain(hip, leg_bones, far, "far")
    chain(shoulder, arm_bones, far, "far")
    place(segments["torso"]["image"], segments["torso"]["pivot"], lean, hip, canvas)
    chain(hip, leg_bones, phase, "near")
    # Head under the near arm.  Drawn over it instead, this character's very
    # full hair blankets the shirt and the swinging arm disappears behind it —
    # the hair really wants splitting into front and back layers.
    place(segments["head"]["image"], segments["head"]["pivot"],
          lean + facing * HEAD_LEAN_GAIN * deviation(ch["headLean"], phase),
          shoulder, canvas)
    chain(shoulder, arm_bones, phase, "near")
    return canvas


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--layers", type=Path, required=True)
    parser.add_argument("--curves", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--fps", type=int, default=50)
    parser.add_argument("--cycles", type=float, default=2.0)
    parser.add_argument("--size", type=int, default=512)
    parser.add_argument("--background", default="#f7f5f0")
    parser.add_argument("--rest", action="store_true",
                        help="render the rest pose only, for tuning the layout")
    args = parser.parse_args()

    curves = json.loads(args.curves.read_text())
    segments = build_segments(args.layers)

    # One leg unit in drawing pixels: the thigh and calf the layout just cut.
    leg_px = (segments["thigh"]["length"] + segments["calf"]["length"]) / (
        curves["segmentLengths"]["thigh"] + curves["segmentLengths"]["calf"])
    size = (args.size, args.size)

    if args.rest:
        frame = render_frame(segments, curves, 0.0, size, leg_px)
        flat = Image.new("RGB", size, args.background)
        flat.paste(frame, mask=frame.split()[3])
        flat.save(args.out)
        print(f"wrote {args.out} (rest pose, leg {leg_px:.1f}px)")
        return 0

    period_seconds = curves["periodFrames"] / curves["driverFPS"]
    total = max(1, round(args.fps * period_seconds * args.cycles))
    frames = []
    for i in range(total):
        rendered = render_frame(segments, curves, (i / total * args.cycles) % 1.0,
                                size, leg_px)
        flat = Image.new("RGB", size, args.background)
        flat.paste(rendered, mask=rendered.split()[3])
        frames.append(flat)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(args.out, save_all=True, append_images=frames[1:],
                   duration=round(1000 / args.fps), loop=0, optimize=True)
    print(f"wrote {args.out} ({len(frames)} frames at {args.fps}fps, leg {leg_px:.1f}px)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
