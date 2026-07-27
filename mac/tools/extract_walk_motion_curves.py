#!/usr/bin/env python3
"""Extract continuous walk-cycle joint curves from the side-view motion driver.

Wan-Animate produced believable gait timing but repainted the character every
frame, so its identity drifted.  This tool keeps the timing and throws the
pixels away: it reads the driver that fed Wan, recovers per-frame joint angles,
and fits them as a Fourier series over one gait period.

Why a Fourier series rather than a frame table:

  * a gait cycle is periodic, so the series closes the loop exactly — no seam;
  * low harmonics reject pose-estimator jitter without hand-tuned smoothing;
  * the runtime can evaluate any continuous phase, so a rig can render at the
    display's refresh rate instead of stepping through a baked strip.

Only the near-side limbs are measured.  In a locked side view the far arm is
behind the torso, and the estimator openly reports it as a guess.  The far side
is synthesised by shifting the near-side curve half a period, which
`--report` verifies against the measured legs before relying on it.

Usage:
    python3 mac/tools/extract_walk_motion_curves.py \
        --driver mac/assets/motion-driver/mimo-side-walk-v1 \
        --model /path/to/pose_landmarker_heavy.task \
        --out mac/assets/motion-curves/side-walk-v1.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np

# MediaPipe pose landmark indices we care about.
LANDMARKS = {
    0: "nose", 11: "Lshoulder", 12: "Rshoulder", 13: "Lelbow", 14: "Relbow",
    15: "Lwrist", 16: "Rwrist", 23: "Lhip", 24: "Rhip", 25: "Lknee",
    26: "Rknee", 27: "Lankle", 28: "Rankle", 29: "Lheel", 30: "Rheel",
    31: "Ltoe", 32: "Rtoe",
}

# Segment name -> (parent landmark, child landmark), written for the near side.
SEGMENTS = {
    "thigh": ("hip", "knee"),
    "calf": ("knee", "ankle"),
    "foot": ("ankle", "toe"),
    "upperArm": ("shoulder", "elbow"),
    "forearm": ("elbow", "wrist"),
}


# --------------------------------------------------------------------------
# Pure maths — no I/O, so the curve fitting stays testable on synthetic input.
# --------------------------------------------------------------------------


def segment_angles(points: np.ndarray, facing: float) -> np.ndarray:
    """Absolute segment angles in degrees: 0 = straight down, + = toward facing.

    `points` is (frames, 2, 2): [frame][parent|child][x|y] in image pixels,
    where y grows downward.
    """
    delta = points[:, 1, :] - points[:, 0, :]
    return np.degrees(np.arctan2(facing * delta[:, 0], delta[:, 1]))


def fill_gaps(values: np.ndarray) -> np.ndarray:
    """Periodically interpolate frames the estimator dropped."""
    index = np.arange(len(values))
    known = ~np.isnan(values)
    if not known.any():
        raise ValueError("every frame is missing")
    return np.interp(index, index[known], values[known], period=len(values))


def fit_fourier(values: np.ndarray, harmonics: int) -> dict:
    """Least-squares fit of a periodic signal to `harmonics` harmonics."""
    n = len(values)
    t = np.arange(n) / n
    basis = [np.ones(n)]
    for k in range(1, harmonics + 1):
        basis.append(np.cos(2 * np.pi * k * t))
        basis.append(np.sin(2 * np.pi * k * t))
    design = np.stack(basis, axis=1)
    coeffs, *_ = np.linalg.lstsq(design, values, rcond=None)
    return {
        "mean": float(coeffs[0]),
        "cos": [float(c) for c in coeffs[1::2]],
        "sin": [float(c) for c in coeffs[2::2]],
    }


def eval_fourier(series: dict, phase: np.ndarray | float) -> np.ndarray | float:
    """Evaluate a fitted series at any continuous phase in [0, 1)."""
    phase = np.asarray(phase, dtype=float)
    out = np.full(phase.shape, series["mean"], dtype=float)
    for k, (c, s) in enumerate(zip(series["cos"], series["sin"]), start=1):
        out = out + c * np.cos(2 * np.pi * k * phase) + s * np.sin(2 * np.pi * k * phase)
    return out


def residual_degrees(values: np.ndarray, series: dict) -> float:
    """RMS gap between the raw measurement and the fitted curve."""
    phase = np.arange(len(values)) / len(values)
    return float(np.sqrt(np.mean((values - eval_fourier(series, phase)) ** 2)))


def half_cycle_correlation(near: np.ndarray, far: np.ndarray) -> tuple[float, float]:
    """How well the far limb matches the near limb shifted half a period."""
    shifted = np.roll(far, len(far) // 2)
    corr = float(np.corrcoef(near, shifted)[0, 1])
    rms = float(np.sqrt(np.mean((near - shifted) ** 2)))
    return corr, rms


def solve_root_motion(fitted: dict, lengths: dict, samples: int = 720) -> dict:
    """Derive pelvis height and forward travel from the planted-foot constraint.

    The driver is a photographic plate: its frames carry registration jitter, so
    the measured pelvis position wanders by a sixth of a leg length.  Segment
    *angles* are immune to that — shifting a whole frame cannot change an angle
    between two points inside it — so the angles are trusted and the root is
    recovered instead of measured.

    A foot in stance is fixed to the ground.  That pins the pelvis height (the
    supporting leg spans hip to floor) and, differentiated, gives the forward
    speed: whatever rearward rate the planted foot shows relative to the hip is
    exactly the rate the body is travelling forward.
    """
    thigh_len, calf_len = lengths["thigh"], lengths["calf"]
    phase = np.arange(samples) / samples

    def ankle_offset(offset: float) -> tuple[np.ndarray, np.ndarray]:
        p = (phase + offset) % 1.0
        thigh = np.radians(eval_fourier(fitted["thigh"], p))
        calf = np.radians(eval_fourier(fitted["calf"], p))
        drop = thigh_len * np.cos(thigh) + calf_len * np.cos(calf)
        reach = thigh_len * np.sin(thigh) + calf_len * np.sin(calf)
        return drop, reach

    drop_near, reach_near = ankle_offset(0.0)
    drop_far, reach_far = ankle_offset(0.5)

    # The supporting leg is whichever reaches further below the hip.
    near_supports = drop_near >= drop_far
    support_drop = np.where(near_supports, drop_near, drop_far)
    support_reach = np.where(near_supports, reach_near, reach_far)

    # Ground is fixed, so the pelvis rides at a constant height above the
    # supporting ankle.  Mean-removed, that is the bob.
    bob = -(support_drop - support_drop.mean())

    # Forward travel: the planted foot's rearward drift relative to the hip.
    # Differentiate each leg on its own branch so the stance handover does not
    # register as an impulse.
    d_near = np.gradient(reach_near, 1.0 / samples)
    d_far = np.gradient(reach_far, 1.0 / samples)
    forward_rate = -np.where(near_supports, d_near, d_far)
    stride = float(np.mean(forward_rate))

    return {
        "bob": fit_fourier(bob, 4),
        "strideLengthPerCycle": stride,
        "bobAmplitudeLegUnits": float(np.ptp(bob)),
        "supportReachSpan": float(np.ptp(support_reach)),
    }


# --------------------------------------------------------------------------
# Driver reading
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class DriverSpec:
    directory: Path
    frame_count: int
    fps: int
    cycle_start: int
    cycle_end: int
    facing: float
    driver_id: str

    @classmethod
    def load(cls, directory: Path) -> "DriverSpec":
        phase = json.loads((directory / "phase.json").read_text())
        if phase.get("duplicateEndpoint"):
            raise SystemExit("driver repeats its endpoint; the period would be wrong")
        return cls(
            directory=directory,
            frame_count=int(phase["frameCount"]),
            fps=int(phase["framesPerSecond"]),
            cycle_start=int(phase["cycleStartFrame"]),
            cycle_end=int(phase["cycleEndFrameExclusive"]),
            facing=-1.0 if phase["direction"] == "left" else 1.0,
            driver_id=str(phase["driverID"]),
        )


def explode_frames(video: Path, into: Path) -> list[Path]:
    into.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", str(video),
         "-vsync", "0", str(into / "f%03d.png")],
        check=True,
    )
    return sorted(into.glob("f*.png"))


def detect_landmarks(frames: list[Path], model: Path) -> list[dict | None]:
    import mediapipe as mp
    from mediapipe.tasks.python import vision
    from mediapipe.tasks.python.core import base_options as bo

    landmarker = vision.PoseLandmarker.create_from_options(
        vision.PoseLandmarkerOptions(
            base_options=bo.BaseOptions(model_asset_path=str(model)),
            running_mode=vision.RunningMode.IMAGE,
            num_poses=1,
            min_pose_detection_confidence=0.2,
            min_pose_presence_confidence=0.2,
        )
    )

    rows: list[dict | None] = []
    for frame in frames:
        image = mp.Image.create_from_file(str(frame))
        result = landmarker.detect(image)
        if not result.pose_landmarks:
            rows.append(None)
            continue
        marks = result.pose_landmarks[0]
        rows.append({
            name: (marks[i].x * image.width, marks[i].y * image.height,
                   marks[i].visibility)
            for i, name in LANDMARKS.items()
        })
    return rows


def joint_track(rows: list[dict | None], joint: str) -> np.ndarray:
    """(frames, 2) pixel track for one joint; NaN where the frame was dropped."""
    track = np.full((len(rows), 2), np.nan)
    for i, row in enumerate(rows):
        if row is not None:
            track[i] = row[joint][:2]
    return track


def mean_visibility(rows: list[dict | None], joint: str) -> float:
    seen = [row[joint][2] for row in rows if row is not None]
    return float(np.mean(seen)) if seen else 0.0


# --------------------------------------------------------------------------
# Extraction
# --------------------------------------------------------------------------


def build_curves(rows: list[dict | None], spec: DriverSpec, harmonics: int,
                 near: str, far: str) -> tuple[dict, dict]:
    cycle = rows[spec.cycle_start:spec.cycle_end]
    period = len(cycle)

    def track(joint: str) -> np.ndarray:
        raw = joint_track(cycle, joint)
        return np.stack([fill_gaps(raw[:, 0]), fill_gaps(raw[:, 1])], axis=1)

    joints = {name: track(name) for name in LANDMARKS.values()}

    def angles(side: str, parent: str, child: str) -> np.ndarray:
        pair = np.stack([joints[side + parent], joints[side + child]], axis=1)
        return segment_angles(pair, spec.facing)

    raw_near = {seg: angles(near, p, c) for seg, (p, c) in SEGMENTS.items()}
    raw_far = {seg: angles(far, p, c) for seg, (p, c) in SEGMENTS.items()}

    mid_hip = (joints[near + "hip"] + joints[far + "hip"]) / 2
    mid_shoulder = (joints[near + "shoulder"] + joints[far + "shoulder"]) / 2

    # Scale everything by the leg so the curves retarget to any body.
    thigh_len = np.linalg.norm(joints[near + "knee"] - joints[near + "hip"], axis=1)
    calf_len = np.linalg.norm(joints[near + "ankle"] - joints[near + "knee"], axis=1)
    leg_length = float(np.median(thigh_len + calf_len))

    # Torso and head lean, 0 = upright, + = leaning the way we walk.
    spine = mid_shoulder - mid_hip
    torso_lean = np.degrees(np.arctan2(spec.facing * spine[:, 0], -spine[:, 1]))
    neck = joints["nose"] - mid_shoulder
    head_lean = np.degrees(np.arctan2(spec.facing * neck[:, 0], -neck[:, 1]))

    channels = {seg: raw_near[seg] for seg in SEGMENTS}
    channels["torsoLean"] = torso_lean
    channels["headLean"] = head_lean

    fitted = {name: fit_fourier(values, harmonics) for name, values in channels.items()}

    segment_lengths = {
        seg: float(np.median(np.linalg.norm(
            joints[near + child] - joints[near + parent], axis=1)) / leg_length)
        for seg, (parent, child) in SEGMENTS.items()
    }

    # The root comes from the ground constraint, not from the plate.
    root = solve_root_motion(fitted, segment_lengths)
    fitted["pelvisBob"] = root["bob"]

    measured_bob = (mid_hip[:, 1] - mid_hip[:, 1].mean()) / leg_length

    report = {
        "period": period,
        "legLengthPx": leg_length,
        "strideLengthPerCycle": root["strideLengthPerCycle"],
        "segmentLengths": segment_lengths,
        "rootMotion": {
            "source": "derived from the planted-foot constraint",
            "derivedBobAmplitudeLegUnits": root["bobAmplitudeLegUnits"],
            "measuredBobAmplitudeLegUnits": float(np.ptp(measured_bob)),
            "supportReachSpanLegUnits": root["supportReachSpan"],
        },
        "residualDegrees": {
            name: residual_degrees(channels[name], fitted[name])
            for name in SEGMENTS
        },
        "halfCycleSymmetry": {
            seg: dict(zip(("correlation", "rmsDegrees"),
                          half_cycle_correlation(raw_near[seg], raw_far[seg])))
            for seg in SEGMENTS
        },
        "meanVisibility": {
            f"{side}{joint}": mean_visibility(cycle, f"{side}{joint}")
            for side in (near, far)
            for joint in ("shoulder", "elbow", "wrist", "hip", "knee", "ankle", "toe")
        },
        "droppedFrames": [
            spec.cycle_start + i for i, row in enumerate(cycle) if row is None
        ],
        "rawNearDegrees": {seg: [float(v) for v in raw_near[seg]] for seg in SEGMENTS},
    }
    return fitted, report


def verify_planted_foot(fitted: dict, report: dict, samples: int = 720,
                        tolerance: float = 0.02) -> dict:
    """Replay the published curves the way the runtime will, and check the floor.

    The root was solved so that the supporting ankle sits on a fixed ground
    line, but the solution is then refit as a Fourier series, which can only
    approximate it.  This replays the published coefficients end to end and
    measures what survives: how far the planted foot still drifts, and whether
    each leg carries a plausible share of stance.  A real walk plants each foot
    for roughly 60% of the cycle, the overlap being double support.
    """
    thigh = report["segmentLengths"]["thigh"]
    calf = report["segmentLengths"]["calf"]
    phase = np.arange(samples) / samples
    hip_y = eval_fourier(fitted["pelvisBob"], phase)

    def ankle_height(offset: float) -> np.ndarray:
        p = (phase + offset) % 1.0
        thigh_a = np.radians(eval_fourier(fitted["thigh"], p))
        calf_a = np.radians(eval_fourier(fitted["calf"], p))
        return hip_y + thigh * np.cos(thigh_a) + calf * np.cos(calf_a)

    near, far = ankle_height(0.0), ankle_height(0.5)
    ground = float(np.maximum(near, far).max())

    # Drift is measured over the window where a leg is *the* support leg, not
    # over a height threshold — thresholding the height would cap the very
    # quantity being measured and always report success.
    supporting = near >= far
    drift = max(
        float(np.ptp(near[supporting])) if supporting.any() else 0.0,
        float(np.ptp(far[~supporting])) if (~supporting).any() else 0.0,
    )
    return {
        "groundHeightLegUnits": ground,
        "stanceFractionNear": float((near > ground - tolerance).mean()),
        "stanceFractionFar": float((far > ground - tolerance).mean()),
        "doubleSupportFraction": float(
            ((near > ground - tolerance) & (far > ground - tolerance)).mean()
        ),
        "plantedFootDriftLegUnits": drift,
        "footLiftLegUnits": float(ground - min(near.min(), far.min())),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--driver", type=Path, required=True,
                        help="motion-driver directory holding driver.mp4 and phase.json")
    parser.add_argument("--model", type=Path, required=True,
                        help="MediaPipe pose_landmarker .task file")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--harmonics", type=int, default=4,
                        help="Muybridge supplies 12 real samples, so 6 is the ceiling")
    parser.add_argument("--near", default="L", choices=("L", "R"),
                        help="side of the body closest to camera")
    parser.add_argument("--report", action="store_true",
                        help="print the diagnostics that justify the fit")
    args = parser.parse_args()

    spec = DriverSpec.load(args.driver)
    far = "R" if args.near == "L" else "L"

    with tempfile.TemporaryDirectory() as tmp:
        frames = explode_frames(args.driver / "driver.mp4", Path(tmp))
        if len(frames) < spec.cycle_end:
            raise SystemExit(f"driver has {len(frames)} frames, cycle needs {spec.cycle_end}")
        rows = detect_landmarks(frames, args.model)

    fitted, report = build_curves(rows, spec, args.harmonics, args.near, far)
    report["plantedFoot"] = verify_planted_foot(fitted, report)

    document = {
        "schemaVersion": 1,
        "sourceDriver": spec.driver_id,
        "driverSHA256": hashlib.sha256((args.driver / "driver.mp4").read_bytes()).hexdigest(),
        "facing": "left" if spec.facing < 0 else "right",
        "nearSide": args.near,
        "periodFrames": report["period"],
        "driverFPS": spec.fps,
        "harmonics": args.harmonics,
        "units": {
            "angles": "degrees, 0 = straight down, positive = toward facing",
            "lean": "degrees, 0 = upright, positive = toward facing",
            "lengths": "multiples of hip-to-ankle leg length",
        },
        "evaluate": "value(t) = mean + sum_k cos[k]*cos(2*pi*(k+1)*t) + sin[k]*sin(2*pi*(k+1)*t)",
        "farSidePhaseOffset": 0.5,
        "strideLengthPerCycle": report["strideLengthPerCycle"],
        "segmentLengths": report["segmentLengths"],
        "groundHeightLegUnits": report["plantedFoot"]["groundHeightLegUnits"],
        "channels": fitted,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(document, indent=2) + "\n")
    print(f"wrote {args.out}")

    if args.report:
        print(json.dumps({k: v for k, v in report.items() if k != "rawNearDegrees"},
                         indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
