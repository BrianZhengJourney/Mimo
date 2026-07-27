#!/usr/bin/env python3
"""Fit each generated part back onto the original drawing to recover its scale.

The model does not honour a request to hold the reference's scale; it fills
each cell instead, so the four parts come back at four different sizes.  Rather
than eyeball a scale per part, each one is registered against the drawing it
came from: the parts are redrawn but faithful, so the correct scale and
position are the ones that make a part sit on top of its own source pixels.

Registration also fixes the pivots for free.  The hip and shoulder are known in
the drawing's coordinates, so once a part's placement is known, a joint's
position inside that part is just the inverse transform.

The torso is the weak case — in the source it is partly hidden behind the near
arm — so its fit is reported alongside the others and should be read with that
in mind.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

SEARCH_SCALES = np.arange(0.30, 0.75, 0.01)


def greyscale(image: Image.Image) -> tuple[np.ndarray, np.ndarray]:
    """Edge magnitude, not tone.

    This character is mostly flat white cloth, so matching on tone lets any
    small white patch sit anywhere on the trousers at near-zero cost, and the
    search collapses to the smallest scale it is allowed.  The line work is
    where the information is, so the gradient is what gets matched.
    """
    rgba = np.array(image.convert("RGBA")).astype(np.float32)
    grey = rgba[:, :, :3] @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    alpha = rgba[:, :, 3] / 255.0
    grey = grey * alpha  # keep the silhouette edge, drop halo from transparent pixels
    dy, dx = np.gradient(grey)
    return np.hypot(dx, dy), alpha


def best_offset(part_edges: np.ndarray, part_alpha: np.ndarray,
                base_edges: np.ndarray, base_alpha: np.ndarray,
                stride: int) -> tuple[float, int, int]:
    """Slide the part over the drawing, scoring by masked correlation.

    Correlation is used rather than a difference so the score cannot be driven
    down simply by covering less, and it is taken zero-mean so a part is
    rewarded for lining its edges up rather than for landing somewhere blank.
    """
    ph, pw = part_edges.shape
    bh, bw = base_edges.shape
    if ph > bh or pw > bw or part_alpha.sum() < 1.0:
        return (float("inf"), 0, 0)

    mask = part_alpha
    weight = mask.sum()
    part_mean = (part_edges * mask).sum() / weight
    part_dev = (part_edges - part_mean) * mask
    part_norm = np.sqrt((part_dev ** 2).sum()) or 1.0

    best = (float("inf"), 0, 0)
    for y in range(0, bh - ph + 1, stride):
        for x in range(0, bw - pw + 1, stride):
            covered = (mask * base_alpha[y:y + ph, x:x + pw]).sum() / weight
            if covered < 0.6:
                continue  # the part is hanging off the subject
            window = base_edges[y:y + ph, x:x + pw]
            window_mean = (window * mask).sum() / weight
            window_dev = (window - window_mean) * mask
            window_norm = np.sqrt((window_dev ** 2).sum()) or 1.0
            correlation = float((part_dev * window_dev).sum() / (part_norm * window_norm))
            score = 1.0 - correlation
            if score < best[0]:
                best = (score, x, y)
    return best


def register(part: Image.Image, base: Image.Image,
             scales: np.ndarray) -> dict:
    base_edges, base_alpha = greyscale(base)
    results = []
    for scale in scales:
        size = (max(1, round(part.width * scale)), max(1, round(part.height * scale)))
        resized = part.resize(size, Image.LANCZOS)
        part_edges, part_alpha = greyscale(resized)
        score, x, y = best_offset(part_edges, part_alpha, base_edges, base_alpha, stride=3)
        results.append((score, float(scale), x, y))

    results.sort()
    score, scale, x, y = results[0]

    # Refine the winner at full resolution.
    size = (max(1, round(part.width * scale)), max(1, round(part.height * scale)))
    resized = part.resize(size, Image.LANCZOS)
    part_edges, part_alpha = greyscale(resized)
    ph, pw = part_edges.shape
    mask = part_alpha
    weight = mask.sum()
    part_mean = (part_edges * mask).sum() / weight
    part_dev = (part_edges - part_mean) * mask
    part_norm = np.sqrt((part_dev ** 2).sum()) or 1.0
    best = (score, x, y)
    for dy in range(-6, 7):
        for dx in range(-6, 7):
            ny, nx = y + dy, x + dx
            if nx < 0 or ny < 0 or nx + pw > base.width or ny + ph > base.height:
                continue
            covered = (mask * base_alpha[ny:ny + ph, nx:nx + pw]).sum() / weight
            if covered < 0.6:
                continue
            window = base_edges[ny:ny + ph, nx:nx + pw]
            window_mean = (window * mask).sum() / weight
            window_dev = (window - window_mean) * mask
            window_norm = np.sqrt((window_dev ** 2).sum()) or 1.0
            value = 1.0 - float((part_dev * window_dev).sum() / (part_norm * window_norm))
            if value < best[0]:
                best = (float(value), nx, ny)

    score, x, y = best
    runner_up = min((r for r in results[1:] if abs(r[1] - scale) > 0.03),
                    default=(float("inf"), 0, 0, 0))[0]
    return {
        "scale": round(float(scale), 4),
        "offset": [int(x), int(y)],
        "score": round(float(score), 3),
        "margin": round(float(runner_up - score), 3),
        "scaledSize": [pw, ph],
        "scaleCurve": [[round(s, 2), round(v, 4)] for v, s, _, _ in sorted(results, key=lambda r: r[1])],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--character", type=Path, required=True)
    parser.add_argument("--layers", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    base = Image.open(args.character).convert("RGBA")
    manifest = json.loads((args.layers / "parts.json").read_text())
    joints = manifest["sourceJoints"]

    fitted = {}
    for name in manifest["parts"]:
        part = Image.open(args.layers / f"{name}.png").convert("RGBA")
        fit = register(part, base, SEARCH_SCALES)
        # Express the drawing's known joints inside this part's own pixels.
        fit["jointsInPart"] = {
            joint: [round((joints[joint][0] - fit["offset"][0]) / fit["scale"], 1),
                    round((joints[joint][1] - fit["offset"][1]) / fit["scale"], 1)]
            for joint in ("hip", "shoulder")
        }
        fitted[name] = fit
        print(f"{name:6s} scale {fit['scale']:.3f}  offset {fit['offset']}  "
              f"score {fit['score']:7.2f}  margin {fit['margin']:6.2f}")

    manifest["registration"] = fitted
    (args.layers / "parts.json").write_text(json.dumps(manifest, indent=2) + "\n")

    # Diagnostic: every part laid back onto the drawing at its fitted place.
    canvas = base.copy()
    faded = np.array(canvas).astype(np.float32)
    faded[:, :, 3] *= 0.35
    canvas = Image.fromarray(faded.astype(np.uint8))
    for name, fit in fitted.items():
        part = Image.open(args.layers / f"{name}.png").convert("RGBA")
        part = part.resize(tuple(fit["scaledSize"]), Image.LANCZOS)
        canvas.alpha_composite(part, tuple(fit["offset"]))
    flat = Image.new("RGB", canvas.size, (240, 238, 233))
    flat.paste(canvas, mask=canvas.split()[3])
    flat.save(args.out)
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
