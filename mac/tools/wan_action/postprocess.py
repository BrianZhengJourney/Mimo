#!/usr/bin/env python3
"""Deterministic Wan video/PNG-sequence to Mimo action-strip processor.

This module intentionally does not run a generative model.  It consumes one
already-generated, fixed-camera clip plus an authoritative gait-phase sidecar,
uses one transform for the whole cycle, and emits preview artifacts that remain
manual-review-only until pose/identity evaluators are plugged in.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

import cv2
import numpy as np


class ValidationError(ValueError):
    """The source cannot safely be converted into an action strip."""


@dataclass(frozen=True)
class ProcessingResult:
    strip_path: Path
    metadata_path: Path
    qa_path: Path
    contact_sheet_path: Path
    frame_count: int
    fixed_anchor: tuple[int, int]
    qa: dict[str, Any]


@dataclass(frozen=True)
class PhaseContract:
    action_name: str
    driver_id: str | None
    direction: str | None
    source_fps: float
    source_frame_count: int
    cycle_start: int
    cycle_end_exclusive: int
    leading_foot: str
    source_anchor_mode: str
    source_anchor: tuple[float, float] | None
    output_anchor: tuple[int, int]
    output_frame_count: int
    target_character_height: float | None
    cycle_distance_cell_pixels: float | None
    matte_rgb: tuple[int, int, int] | None


@dataclass(frozen=True)
class LoadedFrames:
    rgba: tuple[np.ndarray, ...]
    fps: float | None
    source_has_alpha: tuple[bool, ...]
    digest: str


def _natural_key(path: Path) -> list[int | str]:
    return [int(part) if part.isdigit() else part.lower()
            for part in re.split(r"(\d+)", path.name)]


def _decode_image(path: Path) -> tuple[np.ndarray, bool]:
    encoded = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if encoded is None:
        raise ValidationError(f"could not decode image: {path}")
    if encoded.ndim == 2:
        rgb = cv2.cvtColor(encoded, cv2.COLOR_GRAY2RGB)
        alpha = np.full(encoded.shape, 255, dtype=np.uint8)
        return np.dstack((rgb, alpha)), False
    if encoded.shape[2] == 4:
        return cv2.cvtColor(encoded, cv2.COLOR_BGRA2RGBA), True
    if encoded.shape[2] == 3:
        rgb = cv2.cvtColor(encoded, cv2.COLOR_BGR2RGB)
        alpha = np.full(encoded.shape[:2], 255, dtype=np.uint8)
        return np.dstack((rgb, alpha)), False
    raise ValidationError(f"unsupported image channel count: {path}")


def _load_frames(source: Path) -> LoadedFrames:
    hasher = hashlib.sha256()
    frames: list[np.ndarray] = []
    alpha_flags: list[bool] = []
    fps: float | None = None

    if source.is_dir():
        paths = sorted(
            (path for path in source.iterdir()
             if path.is_file() and path.suffix.lower() == ".png"),
            key=_natural_key,
        )
        if not paths:
            raise ValidationError(f"PNG sequence is empty: {source}")
        for path in paths:
            hasher.update(path.name.encode("utf-8"))
            hasher.update(path.read_bytes())
            image, has_alpha = _decode_image(path)
            frames.append(image)
            alpha_flags.append(has_alpha)
    elif source.is_file():
        hasher.update(source.read_bytes())
        capture = cv2.VideoCapture(str(source))
        if not capture.isOpened():
            raise ValidationError(f"could not open video: {source}")
        fps_value = float(capture.get(cv2.CAP_PROP_FPS))
        fps = fps_value if math.isfinite(fps_value) and fps_value > 0 else None
        while True:
            ok, bgr = capture.read()
            if not ok:
                break
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            alpha = np.full(rgb.shape[:2], 255, dtype=np.uint8)
            frames.append(np.dstack((rgb, alpha)))
            alpha_flags.append(False)
        capture.release()
        if not frames:
            raise ValidationError(f"video contains no decodable frames: {source}")
    else:
        raise ValidationError(f"input does not exist: {source}")

    shape = frames[0].shape
    if any(frame.shape != shape for frame in frames):
        raise ValidationError("all source frames must have identical dimensions")
    return LoadedFrames(tuple(frames), fps, tuple(alpha_flags), hasher.hexdigest())


def _pair(value: Any, name: str, *, integer: bool) -> tuple[float, float] | tuple[int, int]:
    if not isinstance(value, list) or len(value) != 2:
        raise ValidationError(f"{name} must be a two-number array")
    if not all(isinstance(item, (int, float)) and math.isfinite(float(item)) for item in value):
        raise ValidationError(f"{name} must contain finite numbers")
    if integer:
        if not all(float(item).is_integer() for item in value):
            raise ValidationError(f"{name} must contain integers")
        return int(value[0]), int(value[1])
    return float(value[0]), float(value[1])


def _read_contract(path: Path) -> PhaseContract:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"could not read phase sidecar: {error}") from error
    if raw.get("schemaVersion") != 1:
        raise ValidationError("phase sidecar schemaVersion must be 1")

    cycle = raw.get("cycle")
    if cycle is None:
        required_flat = (
            "framesPerSecond",
            "frameCount",
            "cycleStartFrame",
            "cycleEndFrameExclusive",
        )
        missing = [name for name in required_flat if name not in raw]
        if missing:
            raise ValidationError(
                "flat phase sidecar is missing " + ", ".join(missing))
        source_fps = raw["framesPerSecond"]
        source_frame_count = raw["frameCount"]
        cycle_start = raw["cycleStartFrame"]
        cycle_end_exclusive = raw["cycleEndFrameExclusive"]
        leading_foot = raw.get("leadingFoot", "unknown")
        if raw.get("duplicateEndpoint") is True:
            raise ValidationError("duplicateEndpoint must be false; closure is QA-only")
        if "cycleLengthFrames" in raw:
            expected_length = int(cycle_end_exclusive) - int(cycle_start)
            if int(raw["cycleLengthFrames"]) != expected_length:
                raise ValidationError(
                    "cycleLengthFrames does not match the declared cycle range")
    else:
        if not isinstance(cycle, dict):
            raise ValidationError("cycle must be an object")
        try:
            source_fps = raw["sourceFPS"]
            source_frame_count = raw["sourceFrameCount"]
            cycle_start = cycle["startFrame"]
            # Legacy `endFrame` was already the first frame of the next cycle.
            cycle_end_exclusive = cycle["endFrame"]
        except KeyError as error:
            raise ValidationError(f"legacy phase sidecar is missing {error.args[0]}") from error
        leading_foot = cycle.get("leadingFoot", "unknown")

    numeric_values = {
        "framesPerSecond": source_fps,
        "frameCount": source_frame_count,
        "cycleStartFrame": cycle_start,
        "cycleEndFrameExclusive": cycle_end_exclusive,
    }
    if not all(isinstance(value, (int, float)) and math.isfinite(float(value))
               for value in numeric_values.values()):
        raise ValidationError("phase timing fields must contain finite numbers")
    if float(source_fps) <= 0:
        raise ValidationError("framesPerSecond must be positive")
    for name in ("frameCount", "cycleStartFrame", "cycleEndFrameExclusive"):
        if not float(numeric_values[name]).is_integer():
            raise ValidationError(f"{name} must be an integer")

    matte = raw.get("matteRGB")
    matte_rgb: tuple[int, int, int] | None = None
    if matte is not None:
        if (not isinstance(matte, list) or len(matte) != 3
                or not all(isinstance(channel, int) and 0 <= channel <= 255
                           for channel in matte)):
            raise ValidationError("matteRGB must contain three bytes")
        matte_rgb = tuple(matte)
    explicit_source_anchor = raw.get("sourceAnchor")
    if explicit_source_anchor is not None:
        source_anchor = _pair(explicit_source_anchor, "sourceAnchor", integer=False)
        source_anchor_mode = "explicit"
    else:
        source_anchor = None
        source_anchor_mode = str(raw.get("sourceAnchorMode", "union-bottom-center"))
        if source_anchor_mode != "union-bottom-center":
            raise ValidationError(
                "sourceAnchorMode must be union-bottom-center when sourceAnchor is absent")

    raw_cycle_distance = raw.get("cycleDistanceCellPixels")
    cycle_distance: float | None = None
    if raw_cycle_distance is not None:
        if (not isinstance(raw_cycle_distance, (int, float))
                or not math.isfinite(float(raw_cycle_distance))
                or not 1.0 <= float(raw_cycle_distance) <= 4096.0):
            raise ValidationError("cycleDistanceCellPixels must be within 1...4096")
        cycle_distance = float(raw_cycle_distance)

    raw_target_height = raw.get("targetCharacterHeight")
    target_character_height: float | None = None
    if raw_target_height is not None:
        if (not isinstance(raw_target_height, (int, float))
                or not math.isfinite(float(raw_target_height))
                or not 1.0 <= float(raw_target_height) <= 512.0):
            raise ValidationError("targetCharacterHeight must be within 1...512")
        target_character_height = float(raw_target_height)

    action_name = raw.get("actionName", "walk")
    if not isinstance(action_name, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", action_name):
        raise ValidationError("actionName is invalid")
    return PhaseContract(
        action_name=action_name,
        driver_id=str(raw["driverID"]) if raw.get("driverID") is not None else None,
        direction=str(raw["direction"]) if raw.get("direction") is not None else None,
        source_fps=float(source_fps),
        source_frame_count=int(source_frame_count),
        cycle_start=int(cycle_start),
        cycle_end_exclusive=int(cycle_end_exclusive),
        leading_foot=str(leading_foot),
        source_anchor_mode=source_anchor_mode,
        source_anchor=source_anchor,
        output_anchor=_pair(raw.get("outputAnchor", [256, 502]),
                            "outputAnchor", integer=True),
        output_frame_count=int(raw.get("outputFrameCount", 24)),
        target_character_height=target_character_height,
        cycle_distance_cell_pixels=cycle_distance,
        matte_rgb=matte_rgb,
    )


def _sample_indices(contract: PhaseContract, available: int) -> list[int]:
    if contract.source_frame_count != available:
        raise ValidationError(
            f"sidecar expects {contract.source_frame_count} source frames, decoded {available}")
    if contract.output_frame_count != 24:
        raise ValidationError("Mimo Wan walk export currently requires exactly 24 frames")
    if not (0 <= contract.cycle_start < contract.cycle_end_exclusive < available):
        raise ValidationError("cycle must include a real closure frame within the source")
    length = contract.cycle_end_exclusive - contract.cycle_start
    if length < contract.output_frame_count:
        raise ValidationError("cycle is too short to provide 24 unique native frames")
    indices = [contract.cycle_start + (index * length) // contract.output_frame_count
               for index in range(contract.output_frame_count)]
    if len(set(indices)) != contract.output_frame_count:
        raise ValidationError("phase sampling produced duplicate source frames")
    return indices


def _alpha_for_frame(rgba: np.ndarray, source_has_alpha: bool,
                     matte_rgb: tuple[int, int, int] | None) -> tuple[np.ndarray, str]:
    source_alpha = rgba[:, :, 3]
    if source_has_alpha and np.any(source_alpha < 250) and np.any(source_alpha > 24):
        return source_alpha.copy(), "source-alpha"
    if matte_rgb is None:
        raise ValidationError("opaque source requires matteRGB in the phase sidecar")
    rgb = rgba[:, :, :3].astype(np.float32)
    matte = np.asarray(matte_rgb, dtype=np.float32)
    distance = np.linalg.norm(rgb - matte, axis=2)
    low, high = 8.0, 42.0
    candidate = (distance <= high).astype(np.uint8)
    count, labels = cv2.connectedComponents(candidate, connectivity=8)
    border_labels = set(np.unique(np.concatenate((labels[0, :], labels[-1, :],
                                                   labels[:, 0], labels[:, -1]))).tolist())
    reachable = np.isin(labels, list(border_labels - {0})) if count > 1 else candidate.astype(bool)
    blend = np.clip((distance - low) / (high - low), 0.0, 1.0)
    blend = blend * blend * (3.0 - 2.0 * blend)
    alpha = np.full(distance.shape, 255, dtype=np.uint8)
    alpha[reachable] = np.rint(blend[reachable] * 255.0).astype(np.uint8)
    if not np.any(alpha > 24):
        raise ValidationError("matte extraction removed the entire subject")
    return alpha, "border-connected-chroma"


def _decontaminate(rgba: np.ndarray, alpha: np.ndarray,
                   matte_rgb: tuple[int, int, int] | None) -> np.ndarray:
    result = rgba.copy()
    result[:, :, 3] = alpha
    if matte_rgb is not None:
        a = alpha.astype(np.float32)[:, :, None] / 255.0
        observed = result[:, :, :3].astype(np.float32)
        matte = np.asarray(matte_rgb, dtype=np.float32)[None, None, :]
        safe = np.maximum(a, 0.05)
        foreground = (observed - (1.0 - a) * matte) / safe
        soft = (a[:, :, 0] > 0.0) & (a[:, :, 0] < 1.0)
        result[:, :, :3][soft] = np.clip(foreground[soft], 0, 255).astype(np.uint8)
    result[:, :, :3][alpha == 0] = 0
    return result


def _bounds(alpha: np.ndarray, threshold: int = 24) -> tuple[int, int, int, int] | None:
    ys, xs = np.nonzero(alpha > threshold)
    if not len(xs):
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def _union_bounds(alphas: Sequence[np.ndarray]) -> tuple[int, int, int, int]:
    found = [_bounds(alpha) for alpha in alphas]
    if any(bounds is None for bounds in found):
        raise ValidationError("the selected cycle contains an empty frame")
    concrete = [bounds for bounds in found if bounds is not None]
    return (min(bounds[0] for bounds in concrete), min(bounds[1] for bounds in concrete),
            max(bounds[2] for bounds in concrete), max(bounds[3] for bounds in concrete))


def _bbox_heights(alphas: Sequence[np.ndarray]) -> list[int]:
    heights: list[int] = []
    for alpha in alphas:
        bounds = _bounds(alpha)
        if bounds is None:
            raise ValidationError("the selected cycle contains an empty frame")
        heights.append(bounds[3] - bounds[1])
    return heights


def _global_transform(union: tuple[int, int, int, int],
                      source_anchor: tuple[float, float],
                      output_anchor: tuple[int, int], cell_size: int,
                      padding: int,
                      requested_scale: float | None = None) -> tuple[float, np.ndarray]:
    min_x, min_y, max_x, max_y = union
    source_x, source_y = source_anchor
    output_x, output_y = output_anchor
    extents = (
        (source_x - min_x, output_x - padding, "left"),
        (max_x - source_x, cell_size - padding - output_x, "right"),
        (source_y - min_y, output_y - padding, "top"),
        (max_y - source_y, cell_size - padding - output_y, "bottom"),
    )
    scales: list[float] = []
    for source_extent, available, label in extents:
        if source_extent < 0:
            raise ValidationError(f"sourceAnchor lies outside the cycle union on the {label}")
        if source_extent > 0:
            if available <= 0:
                raise ValidationError(f"outputAnchor leaves no {label} padding")
            scales.append(available / source_extent)
    if not scales:
        raise ValidationError("cycle union is degenerate")
    maximum_scale = min(scales)
    if requested_scale is not None and requested_scale > maximum_scale + 1e-9:
        raise ValidationError(
            "targetCharacterHeight cannot fit the fixed anchor and cell padding")
    scale = requested_scale if requested_scale is not None else maximum_scale
    if not math.isfinite(scale) or scale <= 0:
        raise ValidationError("could not derive a safe shared scale")
    matrix = np.asarray(
        [[scale, 0.0, output_x - source_x * scale],
         [0.0, scale, output_y - source_y * scale]],
        dtype=np.float64,
    )
    return scale, matrix


def _resolve_source_anchor(
    contract: PhaseContract,
    union: tuple[int, int, int, int],
) -> tuple[float, float]:
    """Resolve one cycle-global registration point, never one per frame."""
    if contract.source_anchor is not None:
        return contract.source_anchor
    min_x, _, max_x, max_y = union
    if contract.source_anchor_mode == "union-bottom-center":
        return ((min_x + max_x) / 2.0, float(max_y))
    raise ValidationError(f"unsupported sourceAnchorMode: {contract.source_anchor_mode}")


def _warp_rgba(rgba: np.ndarray, matrix: np.ndarray, cell_size: int) -> np.ndarray:
    alpha = rgba[:, :, 3].astype(np.float32) / 255.0
    premultiplied = rgba[:, :, :3].astype(np.float32) * alpha[:, :, None]
    # Lanczos' four-source-pixel support grows into a many-output-pixel halo
    # when enlarging pixel art. Nearest-neighbour is both faithful and keeps the
    # authored transparent safety border exact in that case. Wan's usual
    # 720p→512 downscale still takes the antialiased Lanczos path.
    interpolation = cv2.INTER_NEAREST if matrix[0, 0] > 1.0 else cv2.INTER_LANCZOS4
    warped_alpha = cv2.warpAffine(alpha, matrix, (cell_size, cell_size),
                                  flags=interpolation,
                                  borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    warped_premul = cv2.warpAffine(premultiplied, matrix, (cell_size, cell_size),
                                   flags=interpolation,
                                   borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0))
    warped_alpha = np.clip(warped_alpha, 0.0, 1.0)
    safe = np.maximum(warped_alpha[:, :, None], 1.0 / 255.0)
    rgb = np.clip(warped_premul / safe, 0.0, 255.0)
    rgb[warped_alpha <= 1.0 / 255.0] = 0
    return np.dstack((rgb.astype(np.uint8),
                      np.rint(warped_alpha * 255.0).astype(np.uint8)))


def _alpha_iou(lhs: np.ndarray, rhs: np.ndarray) -> float:
    left = lhs > 24
    right = rhs > 24
    union = np.count_nonzero(left | right)
    return 1.0 if union == 0 else float(np.count_nonzero(left & right) / union)


def _transition_distance(lhs: np.ndarray, rhs: np.ndarray) -> float:
    """Mean premultiplied RGBA change, normalized to 0...1."""
    left_alpha = lhs[:, :, 3:4].astype(np.float32) / 255.0
    right_alpha = rhs[:, :, 3:4].astype(np.float32) / 255.0
    left_rgb = lhs[:, :, :3].astype(np.float32) / 255.0 * left_alpha
    right_rgb = rhs[:, :, :3].astype(np.float32) / 255.0 * right_alpha
    left = np.concatenate((left_rgb, left_alpha), axis=2)
    right = np.concatenate((right_rgb, right_alpha), axis=2)
    return float(np.mean(np.abs(left - right)))


def _subject_appearance_distance(lhs: np.ndarray, rhs: np.ndarray) -> float:
    mask = (lhs[:, :, 3] > 24) | (rhs[:, :, 3] > 24)
    if not np.any(mask):
        return 1.0
    left = lhs[:, :, :3].astype(np.float32) / 255.0
    right = rhs[:, :, :3].astype(np.float32) / 255.0
    return float(np.mean(np.abs(left[mask] - right[mask])))


def _largest_component_share(alpha: np.ndarray) -> float:
    mask = (alpha > 24).astype(np.uint8)
    count, labels = cv2.connectedComponents(mask, connectivity=8)
    if count <= 1:
        return 0.0
    masses = np.bincount(labels.ravel(), weights=alpha.ravel(), minlength=count)
    foreground = float(masses[1:].sum())
    return 0.0 if foreground <= 0 else float(masses[1:].max() / foreground)


def _border_clear(alpha: np.ndarray, width: int = 8) -> bool:
    return not np.any(np.concatenate((alpha[:width, :].ravel(), alpha[-width:, :].ravel(),
                                      alpha[:, :width].ravel(), alpha[:, -width:].ravel())) > 8)


def _touches_source_edge(alpha: np.ndarray) -> bool:
    edge = np.concatenate((alpha[0, :], alpha[-1, :], alpha[:, 0], alpha[:, -1]))
    # Lossy video leaves isolated low-confidence chroma specks on the encoded
    # border. Treat clipping as a material, high-confidence edge contact while
    # still catching a paw/limb that reaches the frame boundary.
    required = max(2, int(math.ceil(edge.size * 0.002)))
    return int(np.count_nonzero(edge > 128)) >= required


def _write_rgba(path: Path, rgba: np.ndarray) -> None:
    if not cv2.imwrite(str(path), cv2.cvtColor(rgba, cv2.COLOR_RGBA2BGRA)):
        raise OSError(f"could not write PNG: {path}")


def _contact_sheet(frames: Sequence[np.ndarray], indices: Sequence[int],
                   anchor: tuple[int, int], destination: Path) -> None:
    columns, rows, tile = 6, 4, 256
    sheet = np.zeros((rows * tile, columns * tile, 3), dtype=np.uint8)
    checker = np.zeros((tile, tile, 3), dtype=np.uint8)
    square = 16
    for y in range(tile):
        for x in range(tile):
            checker[y, x] = (222, 222, 222) if (x // square + y // square) % 2 else (250, 250, 250)
    for output_index, (frame, source_index) in enumerate(zip(frames, indices)):
        thumb = cv2.resize(frame, (tile, tile), interpolation=cv2.INTER_AREA)
        alpha = thumb[:, :, 3:4].astype(np.float32) / 255.0
        rgb = thumb[:, :, :3].astype(np.float32)
        composite = np.rint(rgb * alpha + checker.astype(np.float32) * (1.0 - alpha)).astype(np.uint8)
        anchor_at_thumb = (int(round(anchor[0] * tile / frame.shape[1])),
                           int(round(anchor[1] * tile / frame.shape[0])))
        cv2.drawMarker(composite, anchor_at_thumb, (230, 60, 80),
                       cv2.MARKER_CROSS, 10, 1, cv2.LINE_AA)
        cv2.putText(composite, f"F{output_index + 1:02d} src {source_index}",
                    (6, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (20, 20, 20), 2, cv2.LINE_AA)
        cv2.putText(composite, f"F{output_index + 1:02d} src {source_index}",
                    (6, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (245, 245, 245), 1, cv2.LINE_AA)
        row, column = divmod(output_index, columns)
        sheet[row * tile:(row + 1) * tile, column * tile:(column + 1) * tile] = cv2.cvtColor(
            composite, cv2.COLOR_RGB2BGR)
    if not cv2.imwrite(str(destination), sheet):
        raise OSError(f"could not write contact sheet: {destination}")


def process_action(
    source: Path | str,
    sidecar: Path | str,
    output_dir: Path | str,
    *,
    cell_size: int = 512,
    padding: int = 14,
    cycle_distance_cell_pixels: float | None = None,
) -> ProcessingResult:
    """Convert one Wan clip/PNG sequence into a fixed-anchor 24-frame strip."""
    source_path, sidecar_path = Path(source), Path(sidecar)
    destination = Path(output_dir)
    contract = _read_contract(sidecar_path)
    if cycle_distance_cell_pixels is not None:
        if (not isinstance(cycle_distance_cell_pixels, (int, float))
                or not math.isfinite(float(cycle_distance_cell_pixels))
                or not 1.0 <= float(cycle_distance_cell_pixels) <= 4096.0):
            raise ValidationError(
                "cycle_distance_cell_pixels must be within 1...4096")
        authored_cycle_distance = float(cycle_distance_cell_pixels)
        cycle_distance_source = "argument"
    else:
        authored_cycle_distance = contract.cycle_distance_cell_pixels
        cycle_distance_source = (
            "phase-sidecar" if authored_cycle_distance is not None else "missing")
    loaded = _load_frames(source_path)
    if loaded.fps is not None and abs(loaded.fps - contract.source_fps) > 0.05:
        raise ValidationError(
            f"video FPS {loaded.fps:.3f} does not match sidecar {contract.source_fps:.3f}")
    indices = _sample_indices(contract, len(loaded.rgba))

    cleaned: list[np.ndarray] = []
    alpha_methods: list[str] = []
    cycle_alphas: list[np.ndarray] = []
    # The end-exclusive frame is deliberately decoded as the real closure
    # reference, but it is never packed into the output strip.
    for frame_index in range(
        contract.cycle_start,
        contract.cycle_end_exclusive + 1,
    ):
        alpha, method = _alpha_for_frame(
            loaded.rgba[frame_index], loaded.source_has_alpha[frame_index], contract.matte_rgb)
        cleaned_frame = _decontaminate(loaded.rgba[frame_index], alpha, contract.matte_rgb)
        cleaned.append(cleaned_frame)
        cycle_alphas.append(alpha)
        alpha_methods.append(method)

    union = _union_bounds(cycle_alphas)
    source_anchor = _resolve_source_anchor(contract, union)
    clipped_source_frames = [
        contract.cycle_start + index
        for index, alpha in enumerate(cycle_alphas)
        if _touches_source_edge(alpha)
    ]
    offset = contract.cycle_start
    sampled_source_heights = _bbox_heights(
        [cycle_alphas[index - offset] for index in indices])
    median_source_height = float(np.median(sampled_source_heights))
    requested_scale = (
        contract.target_character_height / median_source_height
        if contract.target_character_height is not None else None
    )
    scale, matrix = _global_transform(
        union,
        source_anchor,
        contract.output_anchor,
        cell_size,
        padding,
        requested_scale=requested_scale,
    )
    warped_cycle = [_warp_rgba(frame, matrix, cell_size) for frame in cleaned]
    output_frames = [warped_cycle[index - offset] for index in indices]
    closure = warped_cycle[contract.cycle_end_exclusive - offset]

    closure_iou = _alpha_iou(output_frames[0][:, :, 3], closure[:, :, 3])
    closure_appearance = _subject_appearance_distance(output_frames[0], closure)
    internal_transitions = [
        _transition_distance(output_frames[index], output_frames[index + 1])
        for index in range(len(output_frames) - 1)
    ]
    seam_transition = _transition_distance(output_frames[-1], output_frames[0])
    transition_reference = float(np.percentile(internal_transitions, 90))
    seam_ratio = seam_transition / max(transition_reference, 1e-4)
    component_shares = [_largest_component_share(frame[:, :, 3]) for frame in output_frames]
    alpha_areas = [float(frame[:, :, 3].astype(np.float64).sum() / 255.0)
                   for frame in output_frames]
    median_alpha_area = float(np.median(alpha_areas))
    maximum_area_deviation = (
        max(abs(area - median_alpha_area) for area in alpha_areas) / median_alpha_area
        if median_alpha_area > 0 else math.inf
    )
    borders_clear = all(_border_clear(frame[:, :, 3]) for frame in output_frames)
    all_nonempty = all(_bounds(frame[:, :, 3]) is not None for frame in output_frames)
    output_bbox_heights = _bbox_heights(
        [frame[:, :, 3] for frame in output_frames])
    median_output_height = float(np.median(output_bbox_heights))
    target_height_error = (
        abs(median_output_height - contract.target_character_height)
        / contract.target_character_height
        if contract.target_character_height is not None else 0.0
    )
    gates = {
        "frameGeometry": {
            "pass": len(output_frames) == 24,
            "value": {"frameCount": len(output_frames), "cellSize": cell_size},
        },
        "sourceClipping": {
            "pass": not clipped_source_frames,
            "frames": clipped_source_frames,
        },
        "nonemptyFrames": {"pass": all_nonempty},
        "transparentBorder": {"pass": borders_clear, "requiredPixels": 8},
        "loopAlphaClosure": {"pass": closure_iou >= 0.97, "value": closure_iou,
                             "minimum": 0.97},
        "loopAppearanceClosure": {
            "pass": closure_appearance <= 0.05,
            "value": closure_appearance,
            "maximum": 0.05,
        },
        "loopTransition": {
            "pass": seam_ratio <= 1.25,
            "seamDistance": seam_transition,
            "internalP90": transition_reference,
            "ratio": seam_ratio,
            "maximumRatio": 1.25,
        },
        "singleForeground": {
            "pass": min(component_shares, default=0.0) >= 0.995,
            "minimumShare": min(component_shares, default=0.0),
            "required": 0.995,
        },
        "alphaAreaStability": {
            "pass": maximum_area_deviation <= 0.12,
            "medianArea": median_alpha_area,
            "maximumRelativeDeviation": maximum_area_deviation,
            "maximumAllowed": 0.12,
        },
        "targetCharacterHeight": {
            "pass": contract.target_character_height is None or target_height_error <= 0.02,
            "requested": contract.target_character_height is not None,
            "target": contract.target_character_height,
            "medianOutputAlphaBBoxHeight": median_output_height,
            "relativeError": target_height_error,
            "maximumRelativeError": 0.02,
        },
        "cycleDistanceAuthored": {
            "pass": contract.action_name != "walk" or authored_cycle_distance is not None,
            "valueCellPixels": authored_cycle_distance,
            "source": cycle_distance_source,
            "requiredFor": ["walk"],
        },
    }
    hard_pass = all(bool(gate["pass"]) for gate in gates.values())
    manual_review_reasons = [
        "gait phase semantics are supplied by the driver but not independently verified",
        "identity fidelity requires the future DINO evaluator or human approval",
        "head/face size stability requires manual landmark review; alpha silhouettes "
        "cannot reliably isolate a head across arbitrary characters",
    ]
    if authored_cycle_distance is None and contract.action_name == "walk":
        manual_review_reasons.append(
            "walk cycleDistanceCellPixels is missing; preview only and install must fail closed")
    qa: dict[str, Any] = {
        "schemaVersion": 1,
        "action": contract.action_name,
        "hardPass": hard_pass,
        "automaticInstallAllowed": False,
        "manualReviewRequired": True,
        "manualReviewReasons": manual_review_reasons,
        "manualChecks": {
            "headFaceSizeStability": {
                "status": "manual-required",
                "reason": (
                    "no pose/face landmark model is present, and a top-silhouette "
                    "heuristic would confuse ears, hair, arms, tails, and shadows"
                ),
            },
        },
        "source": {
            "sha256": loaded.digest,
            "frameCount": len(loaded.rgba),
            "fps": loaded.fps or contract.source_fps,
            "dimensions": [loaded.rgba[0].shape[1], loaded.rgba[0].shape[0]],
        },
        "cycle": {
            "driverID": contract.driver_id,
            "startFrame": contract.cycle_start,
            "endFrameExclusive": contract.cycle_end_exclusive,
            "closureFrame": contract.cycle_end_exclusive,
            "leadingFoot": contract.leading_foot,
            "direction": contract.direction,
            "sampledFrames": indices,
            "cycleDistanceCellPixels": authored_cycle_distance,
            "cycleDistanceSource": cycle_distance_source,
        },
        "output": {
            "frameCount": len(output_frames),
            "cellSize": cell_size,
            "stripDimensions": [cell_size * len(output_frames), cell_size],
            "fixedAnchor": list(contract.output_anchor),
        },
        "normalization": {
            "mode": "single-union-transform",
            "sourceUnionBounds": list(union),
            "sourceAnchorMode": contract.source_anchor_mode,
            "sourceAnchor": list(source_anchor),
            "scaleMode": (
                "target-median-alpha-bbox-height"
                if contract.target_character_height is not None
                else "fit-cycle-union"
            ),
            "targetCharacterHeight": contract.target_character_height,
            "medianSourceAlphaBBoxHeight": median_source_height,
            "medianOutputAlphaBBoxHeight": median_output_height,
            "scale": scale,
            "matrix": matrix.tolist(),
            "alphaMethods": sorted(set(alpha_methods)),
        },
        "gates": gates,
    }

    destination.mkdir(parents=True, exist_ok=True)
    strip_path = destination / f"action-{contract.action_name}.png"
    metadata_path = destination / f"action-{contract.action_name}.metadata.json"
    qa_path = destination / f"action-{contract.action_name}.qa.json"
    contact_path = destination / f"action-{contract.action_name}-contact-sheet.png"
    cycle_length = contract.cycle_end_exclusive - contract.cycle_start
    output_fps = (
        contract.source_fps * contract.output_frame_count / cycle_length)
    metadata: dict[str, Any] = {
        "schemaVersion": 1,
        "action": contract.action_name,
        "stripFilename": strip_path.name,
        "frameCount": len(output_frames),
        "cellSize": cell_size,
        "framesPerSecond": output_fps,
        "anchorInCell": list(contract.output_anchor),
        "qaFilename": qa_path.name,
        "automaticInstallAllowed": False,
    }
    if authored_cycle_distance is not None:
        metadata["cycleDistanceCellPixels"] = authored_cycle_distance
    strip = np.concatenate(output_frames, axis=1)
    _write_rgba(strip_path, strip)
    metadata_path.write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    qa_path.write_text(json.dumps(qa, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    _contact_sheet(output_frames, indices, contract.output_anchor, contact_path)

    return ProcessingResult(
        strip_path=strip_path,
        metadata_path=metadata_path,
        qa_path=qa_path,
        contact_sheet_path=contact_path,
        frame_count=len(output_frames),
        fixed_anchor=contract.output_anchor,
        qa=qa,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path,
                        help="Wan MP4 or directory of zero-padded PNG frames")
    parser.add_argument("--phase", required=True, type=Path,
                        help="authoritative gait phase JSON sidecar")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--cycle-distance-cell-pixels",
        type=float,
        help="authored distance covered by one complete walk cycle in 512px cell space",
    )
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        result = process_action(
            arguments.input,
            arguments.phase,
            arguments.output_dir,
            cycle_distance_cell_pixels=arguments.cycle_distance_cell_pixels,
        )
    except ValidationError as error:
        print(f"rejected: {error}")
        return 2
    print(f"strip: {result.strip_path}")
    print(f"metadata: {result.metadata_path}")
    print(f"QA: {'hard-pass; manual review required' if result.qa['hardPass'] else 'rejected'}")
    return 0 if result.qa["hardPass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
