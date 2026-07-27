#!/usr/bin/env python3
"""Convert a fixed-camera Higgsfield MP4 into a registered Mimo action preview.

The generator owns motion. This module only decodes, samples, removes a declared
flat matte, applies one shared transform to the complete clip, and emits visual
QA artifacts. It intentionally never aligns or rescales frames independently.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

import cv2
import numpy as np
from PIL import Image, ImageDraw


class ValidationError(ValueError):
    """The source video cannot be converted safely."""


@dataclass(frozen=True)
class VideoFrames:
    rgba: tuple[np.ndarray, ...]
    fps: float
    width: int
    height: int
    digest: str


@dataclass(frozen=True)
class ProcessingResult:
    strip_path: Path
    preview_gif_path: Path
    preview_webp_path: Path
    contact_sheet_path: Path
    qa_path: Path
    frame_count: int
    qa: dict[str, Any]


def _hex_rgb(value: str) -> tuple[int, int, int]:
    raw = value.strip().lstrip("#")
    if len(raw) != 6:
        raise ValidationError("matte must be a six-digit RGB hex value")
    try:
        return tuple(int(raw[index:index + 2], 16) for index in (0, 2, 4))
    except ValueError as error:
        raise ValidationError("matte must be a six-digit RGB hex value") from error


def _decode_video(path: Path) -> VideoFrames:
    if not path.is_file():
        raise ValidationError(f"input video does not exist: {path}")
    capture = cv2.VideoCapture(str(path))
    if not capture.isOpened():
        raise ValidationError(f"could not open video: {path}")
    fps = float(capture.get(cv2.CAP_PROP_FPS))
    if not math.isfinite(fps) or fps <= 0:
        capture.release()
        raise ValidationError("video has no valid frame rate")
    frames: list[np.ndarray] = []
    while True:
        ok, bgr = capture.read()
        if not ok:
            break
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        alpha = np.full(rgb.shape[:2], 255, dtype=np.uint8)
        frames.append(np.dstack((rgb, alpha)))
    capture.release()
    if len(frames) < 2:
        raise ValidationError("video must contain at least two decodable frames")
    shape = frames[0].shape
    if any(frame.shape != shape for frame in frames):
        raise ValidationError("all decoded frames must have the same dimensions")
    return VideoFrames(
        rgba=tuple(frames),
        fps=fps,
        width=shape[1],
        height=shape[0],
        digest=hashlib.sha256(path.read_bytes()).hexdigest(),
    )


def _sample_indices(source_count: int, output_count: int) -> list[int]:
    if output_count < 2:
        raise ValidationError("output frame count must be at least two")
    if source_count < output_count:
        raise ValidationError(
            f"video has {source_count} frames, fewer than requested {output_count}")
    # The real final frame is reserved as closure evidence. The packed loop
    # samples [0, final) so it never duplicates the endpoint.
    usable = source_count - 1
    indices = [(index * usable) // output_count for index in range(output_count)]
    if len(set(indices)) != output_count:
        raise ValidationError("sampling produced duplicate source frames")
    return indices


def _border_connected_alpha(
    rgba: np.ndarray,
    matte_rgb: tuple[int, int, int],
    *,
    low: float,
    high: float,
) -> np.ndarray:
    if not (0 <= low < high):
        raise ValidationError("matte thresholds must satisfy 0 <= low < high")
    rgb = rgba[:, :, :3].astype(np.float32)
    matte = np.asarray(matte_rgb, dtype=np.float32)[None, None, :]
    distance = np.linalg.norm(rgb - matte, axis=2)

    candidate = (distance <= high).astype(np.uint8)
    count, labels = cv2.connectedComponents(candidate, connectivity=8)
    border = np.concatenate((
        labels[0, :], labels[-1, :], labels[:, 0], labels[:, -1],
    ))
    border_labels = set(np.unique(border).tolist()) - {0}
    reachable = (
        np.isin(labels, list(border_labels))
        if count > 1 and border_labels
        else candidate.astype(bool)
    )

    blend = np.clip((distance - low) / (high - low), 0.0, 1.0)
    blend = blend * blend * (3.0 - 2.0 * blend)
    alpha = np.full(distance.shape, 255, dtype=np.uint8)
    alpha[reachable] = np.rint(blend[reachable] * 255.0).astype(np.uint8)
    # Lossy MP4 leaves a low-confidence chroma haze over the nominally flat
    # background. It is below the runtime's own alpha occupancy threshold, so
    # clear it before resampling instead of letting Lanczos spread it inward.
    alpha[alpha <= 24] = 0
    if not np.any(alpha > 24):
        raise ValidationError("matte extraction removed the complete frame")
    return alpha


def _decontaminate(
    rgba: np.ndarray,
    alpha: np.ndarray,
    matte_rgb: tuple[int, int, int],
) -> np.ndarray:
    result = rgba.copy()
    result[:, :, 3] = alpha
    a = alpha.astype(np.float32)[:, :, None] / 255.0
    observed = result[:, :, :3].astype(np.float32)
    matte = np.asarray(matte_rgb, dtype=np.float32)[None, None, :]
    safe = np.maximum(a, 0.05)
    foreground = (observed - (1.0 - a) * matte) / safe
    soft = (alpha > 0) & (alpha < 255)
    result[:, :, :3][soft] = np.clip(foreground[soft], 0, 255).astype(np.uint8)
    result[:, :, :3][alpha == 0] = 0
    return result


def _bounds(alpha: np.ndarray, threshold: int = 24) -> tuple[int, int, int, int] | None:
    ys, xs = np.nonzero(alpha > threshold)
    if not len(xs):
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def _union_bounds(alphas: Sequence[np.ndarray]) -> tuple[int, int, int, int]:
    bounds = [_bounds(alpha) for alpha in alphas]
    if any(item is None for item in bounds):
        raise ValidationError("at least one sampled frame is empty")
    concrete = [item for item in bounds if item is not None]
    return (
        min(item[0] for item in concrete),
        min(item[1] for item in concrete),
        max(item[2] for item in concrete),
        max(item[3] for item in concrete),
    )


def _shared_transform(
    union: tuple[int, int, int, int],
    *,
    cell_size: int,
    padding: int,
) -> tuple[float, np.ndarray, tuple[float, float], tuple[int, int]]:
    min_x, min_y, max_x, max_y = union
    width, height = max_x - min_x, max_y - min_y
    if width <= 0 or height <= 0:
        raise ValidationError("foreground union is degenerate")
    available = cell_size - 2 * padding
    if available <= 0:
        raise ValidationError("padding leaves no drawable cell area")
    scale = min(available / width, available / height)
    source_anchor = ((min_x + max_x) / 2.0, float(max_y))
    output_anchor = (cell_size // 2, cell_size - padding)
    matrix = np.asarray([
        [scale, 0.0, output_anchor[0] - source_anchor[0] * scale],
        [0.0, scale, output_anchor[1] - source_anchor[1] * scale],
    ], dtype=np.float64)
    return scale, matrix, source_anchor, output_anchor


def _warp_rgba(rgba: np.ndarray, matrix: np.ndarray, size: int) -> np.ndarray:
    alpha = rgba[:, :, 3].astype(np.float32) / 255.0
    premultiplied = rgba[:, :, :3].astype(np.float32) * alpha[:, :, None]
    interpolation = cv2.INTER_NEAREST if matrix[0, 0] > 1.0 else cv2.INTER_LANCZOS4
    warped_alpha = cv2.warpAffine(
        alpha, matrix, (size, size), flags=interpolation,
        borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    warped_premul = cv2.warpAffine(
        premultiplied, matrix, (size, size), flags=interpolation,
        borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0))
    warped_alpha = np.clip(warped_alpha, 0.0, 1.0)
    safe = np.maximum(warped_alpha[:, :, None], 1.0 / 255.0)
    rgb = np.clip(warped_premul / safe, 0.0, 255.0)
    rgb[warped_alpha <= 1.0 / 255.0] = 0
    return np.dstack((
        rgb.astype(np.uint8),
        np.rint(warped_alpha * 255.0).astype(np.uint8),
    ))


def _border_clear(alpha: np.ndarray, width: int = 8) -> bool:
    edge = np.concatenate((
        alpha[:width, :].ravel(),
        alpha[-width:, :].ravel(),
        alpha[:, :width].ravel(),
        alpha[:, -width:].ravel(),
    ))
    return not np.any(edge > 8)


def _largest_component_share(alpha: np.ndarray) -> float:
    mask = (alpha > 24).astype(np.uint8)
    count, labels = cv2.connectedComponents(mask, connectivity=8)
    if count <= 1:
        return 0.0
    masses = np.bincount(labels.ravel(), weights=alpha.ravel(), minlength=count)
    foreground = float(masses[1:].sum())
    return 0.0 if foreground <= 0 else float(masses[1:].max() / foreground)


def _alpha_iou(lhs: np.ndarray, rhs: np.ndarray) -> float:
    left, right = lhs > 24, rhs > 24
    union = np.count_nonzero(left | right)
    return 1.0 if union == 0 else float(np.count_nonzero(left & right) / union)


def _appearance_distance(lhs: np.ndarray, rhs: np.ndarray) -> float:
    mask = (lhs[:, :, 3] > 24) | (rhs[:, :, 3] > 24)
    if not np.any(mask):
        return 1.0
    left = lhs[:, :, :3].astype(np.float32) / 255.0
    right = rhs[:, :, :3].astype(np.float32) / 255.0
    return float(np.mean(np.abs(left[mask] - right[mask])))


def _write_rgba(path: Path, rgba: np.ndarray) -> None:
    if not cv2.imwrite(str(path), cv2.cvtColor(rgba, cv2.COLOR_RGBA2BGRA)):
        raise OSError(f"could not write image: {path}")


def _checkerboard(size: int, square: int = 16) -> np.ndarray:
    y, x = np.indices((size, size))
    cells = ((x // square + y // square) % 2)[:, :, None]
    light = np.asarray([250, 250, 250], dtype=np.uint8)
    dark = np.asarray([218, 218, 218], dtype=np.uint8)
    return np.where(cells == 0, light, dark).astype(np.uint8)


def _composite(frame: np.ndarray, background: np.ndarray) -> np.ndarray:
    alpha = frame[:, :, 3:4].astype(np.float32) / 255.0
    return np.rint(
        frame[:, :, :3].astype(np.float32) * alpha
        + background.astype(np.float32) * (1.0 - alpha)
    ).astype(np.uint8)


def _write_previews(
    frames: Sequence[np.ndarray],
    *,
    gif_path: Path,
    webp_path: Path,
    preview_fps: float,
) -> None:
    duration_ms = max(20, int(round(1000.0 / preview_fps)))
    rgba_images = [Image.fromarray(frame, "RGBA") for frame in frames]
    rgba_images[0].save(
        webp_path, save_all=True, append_images=rgba_images[1:], loop=0,
        duration=duration_ms, lossless=True, quality=100, method=6)

    checker = _checkerboard(frames[0].shape[0])
    rgb_images = [Image.fromarray(_composite(frame, checker), "RGB")
                  for frame in frames]
    rgb_images[0].save(
        gif_path, save_all=True, append_images=rgb_images[1:], loop=0,
        duration=duration_ms, optimize=False, disposal=2)


def _write_contact_sheet(
    frames: Sequence[np.ndarray],
    indices: Sequence[int],
    destination: Path,
) -> None:
    tile, columns = 256, 6
    rows = math.ceil(len(frames) / columns)
    sheet = Image.new("RGB", (columns * tile, rows * tile), (238, 238, 238))
    checker = _checkerboard(tile)
    draw = ImageDraw.Draw(sheet)
    for output_index, (frame, source_index) in enumerate(zip(frames, indices)):
        resized = cv2.resize(frame, (tile, tile), interpolation=cv2.INTER_AREA)
        tile_rgb = _composite(resized, checker)
        row, column = divmod(output_index, columns)
        origin = (column * tile, row * tile)
        sheet.paste(Image.fromarray(tile_rgb, "RGB"), origin)
        label = f"F{output_index + 1:02d} · src {source_index}"
        draw.rectangle(
            (origin[0] + 5, origin[1] + 5,
             origin[0] + 104, origin[1] + 24),
            fill=(20, 20, 20))
        draw.text((origin[0] + 9, origin[1] + 8), label, fill=(255, 255, 255))
    sheet.save(destination)


def process_video(
    source: Path | str,
    output_dir: Path | str,
    *,
    action: str,
    frame_count: int = 24,
    cell_size: int = 512,
    padding: int = 14,
    matte_hex: str = "#FF00FF",
    matte_low: float = 12.0,
    matte_high: float = 88.0,
    preview_fps: float = 12.0,
) -> ProcessingResult:
    source_path = Path(source)
    destination = Path(output_dir)
    if not action or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789-"
                         for character in action):
        raise ValidationError("action must be a lowercase slug")
    if not 2 <= frame_count <= 32:
        raise ValidationError("frame count must be within Mimo's 2...32 range")
    if not 64 <= cell_size <= 1024:
        raise ValidationError("cell size must be within 64...1024")
    if not preview_fps > 0 or not math.isfinite(preview_fps):
        raise ValidationError("preview FPS must be positive")

    matte_rgb = _hex_rgb(matte_hex)
    decoded = _decode_video(source_path)
    sample_indices = _sample_indices(len(decoded.rgba), frame_count)
    sampled_source = [decoded.rgba[index] for index in sample_indices]

    sampled_cleaned: list[np.ndarray] = []
    sampled_alphas: list[np.ndarray] = []
    for frame in sampled_source:
        alpha = _border_connected_alpha(
            frame, matte_rgb, low=matte_low, high=matte_high)
        sampled_alphas.append(alpha)
        sampled_cleaned.append(_decontaminate(frame, alpha, matte_rgb))

    closure_alpha = _border_connected_alpha(
        decoded.rgba[-1], matte_rgb, low=matte_low, high=matte_high)
    closure_cleaned = _decontaminate(decoded.rgba[-1], closure_alpha, matte_rgb)

    union = _union_bounds(sampled_alphas + [closure_alpha])
    scale, matrix, source_anchor, output_anchor = _shared_transform(
        union, cell_size=cell_size, padding=padding)
    output_frames = [_warp_rgba(frame, matrix, cell_size)
                     for frame in sampled_cleaned]
    closure_frame = _warp_rgba(closure_cleaned, matrix, cell_size)

    destination.mkdir(parents=True, exist_ok=True)
    frames_dir = destination / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    for index, frame in enumerate(output_frames):
        _write_rgba(frames_dir / f"frame-{index + 1:02d}.png", frame)

    strip = np.concatenate(output_frames, axis=1)
    strip_path = destination / f"action-{action}.png"
    _write_rgba(strip_path, strip)
    preview_gif_path = destination / f"{action}-preview.gif"
    preview_webp_path = destination / f"{action}-preview.webp"
    _write_previews(
        output_frames, gif_path=preview_gif_path, webp_path=preview_webp_path,
        preview_fps=preview_fps)
    contact_sheet_path = destination / f"{action}-contact-sheet.png"
    _write_contact_sheet(output_frames, sample_indices, contact_sheet_path)

    frame_bounds = [_bounds(frame[:, :, 3]) for frame in output_frames]
    if any(item is None for item in frame_bounds):
        raise ValidationError("an output frame became empty after normalization")
    concrete_bounds = [item for item in frame_bounds if item is not None]
    heights = [item[3] - item[1] for item in concrete_bounds]
    widths = [item[2] - item[0] for item in concrete_bounds]
    centers = [(item[0] + item[2]) / 2.0 for item in concrete_bounds]
    alpha_areas = [
        float(frame[:, :, 3].astype(np.float64).sum() / 255.0)
        for frame in output_frames
    ]
    median_area = float(np.median(alpha_areas))
    maximum_area_deviation = (
        max(abs(area - median_area) for area in alpha_areas) / median_area
        if median_area > 0 else math.inf
    )
    component_shares = [
        _largest_component_share(frame[:, :, 3]) for frame in output_frames
    ]
    borders_clear = all(_border_clear(frame[:, :, 3]) for frame in output_frames)
    qa: dict[str, Any] = {
        "schemaVersion": 1,
        "action": action,
        "source": {
            "path": str(source_path.resolve()),
            "sha256": decoded.digest,
            "frameCount": len(decoded.rgba),
            "framesPerSecond": decoded.fps,
            "width": decoded.width,
            "height": decoded.height,
        },
        "output": {
            "frameCount": frame_count,
            "cellSize": cell_size,
            "previewFramesPerSecond": preview_fps,
            "sampleIndices": sample_indices,
            "strip": str(strip_path.resolve()),
            "previewGIF": str(preview_gif_path.resolve()),
            "previewWebP": str(preview_webp_path.resolve()),
            "contactSheet": str(contact_sheet_path.resolve()),
        },
        "matte": {
            "rgb": list(matte_rgb),
            "lowDistance": matte_low,
            "highDistance": matte_high,
            "algorithm": "border-connected-rgb-distance-soft-matte",
        },
        "normalization": {
            "policy": "one-shared-transform-for-complete-clip",
            "sourceUnion": list(union),
            "sourceAnchor": list(source_anchor),
            "outputAnchor": list(output_anchor),
            "scale": scale,
            "matrix": matrix.tolist(),
        },
        "measurements": {
            "bboxHeight": {
                "min": min(heights),
                "median": float(np.median(heights)),
                "max": max(heights),
                "standardDeviation": float(np.std(heights)),
            },
            "bboxWidth": {
                "min": min(widths),
                "median": float(np.median(widths)),
                "max": max(widths),
            },
            "centerX": {
                "min": min(centers),
                "median": float(np.median(centers)),
                "max": max(centers),
            },
            "maximumAlphaAreaDeviation": maximum_area_deviation,
            "minimumLargestComponentShare": min(component_shares),
            "closureAlphaIoU": _alpha_iou(
                output_frames[0][:, :, 3], closure_frame[:, :, 3]),
            "closureAppearanceDistance": _appearance_distance(
                output_frames[0], closure_frame),
        },
        "gates": {
            "frameGeometry": {
                "pass": len(output_frames) == frame_count
                and strip.shape == (cell_size, cell_size * frame_count, 4),
            },
            "allFramesNonempty": {
                "pass": all(item is not None for item in frame_bounds),
            },
            "transparentBorder": {"pass": borders_clear},
            "componentConnectivity": {
                "pass": min(component_shares) >= 0.80,
                "minimumShare": min(component_shares),
            },
        },
    }
    qa["hardPass"] = all(gate["pass"] for gate in qa["gates"].values())
    qa_path = destination / f"{action}-qa.json"
    qa_path.write_text(
        json.dumps(qa, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return ProcessingResult(
        strip_path=strip_path,
        preview_gif_path=preview_gif_path,
        preview_webp_path=preview_webp_path,
        contact_sheet_path=contact_sheet_path,
        qa_path=qa_path,
        frame_count=frame_count,
        qa=qa,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--action", required=True)
    parser.add_argument("--frame-count", type=int, default=24)
    parser.add_argument("--cell-size", type=int, default=512)
    parser.add_argument("--padding", type=int, default=14)
    parser.add_argument("--matte", default="#FF00FF")
    parser.add_argument("--matte-low", type=float, default=12.0)
    parser.add_argument("--matte-high", type=float, default=88.0)
    parser.add_argument("--preview-fps", type=float, default=12.0)
    return parser


def main() -> int:
    args = _parser().parse_args()
    result = process_video(
        args.input,
        args.output_dir,
        action=args.action,
        frame_count=args.frame_count,
        cell_size=args.cell_size,
        padding=args.padding,
        matte_hex=args.matte,
        matte_low=args.matte_low,
        matte_high=args.matte_high,
        preview_fps=args.preview_fps,
    )
    print(json.dumps({
        "strip": str(result.strip_path),
        "preview_gif": str(result.preview_gif_path),
        "preview_webp": str(result.preview_webp_path),
        "contact_sheet": str(result.contact_sheet_path),
        "qa": str(result.qa_path),
        "hard_pass": result.qa["hardPass"],
    }, sort_keys=True))
    return 0 if result.qa["hardPass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
