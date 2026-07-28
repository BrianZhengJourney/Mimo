#!/usr/bin/env python3
"""Prepare a high-fidelity Mimo action run without generating visual assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw


CHROMA_KEY = "#FF00FF"

BATCH_LAYOUT = {
    "columns": 3,
    "rows": 1,
    "width": 1536,
    "height": 1024,
    "source_cell_width": 512,
    "source_cell_height": 1024,
}

# Product action whitelist. Historical experiments may remain on disk for
# provenance, but no other action may enter a new production run.
PROFILES = {
    "idle": {
        "motion_class": "ambient",
        "final_frames": 3,
        "holds": [0.70, 0.55, 0.85],
        "pose_contract": (
            "Keep both feet, hips, and the body root fixed. Use only a readable "
            "chest/shoulder breath and tiny hair or clothing follow-through."
        ),
        "batches": [[
            "settled neutral at the end of an exhale",
            "gentle inhale crest with slightly larger readable breathing",
            "settled neutral, returning cleanly to frame 1",
        ]],
    },
    "walk": {
        "motion_class": "locomotion",
        "final_frames": 8,
        "preview_cycle_seconds": 1.6,
        "mirror_for_opposite_direction": True,
        "pose_contract": (
            "Use one fixed side camera walking toward screen-left. Keep the "
            "root horizontally centered; runtime supplies translation. Preserve "
            "near/far limb order, hair silhouette, tattoo/watch arm, head size, "
            "torso length, and one ground baseline through the two-step cycle."
        ),
        "batches": [
            [
                "K1 left foot contact",
                "K2 left-side weight acceptance",
                "K3 right leg passing",
            ],
            [
                "K4 right leg high point",
                "K5 right foot contact",
                "K6 right-side weight acceptance",
            ],
            [
                "K7 left leg passing",
                "K8 left leg high point",
                "closure check: recreate K1 left foot contact; discard this frame",
            ],
        ],
        "keep_per_batch": [3, 3, 2],
    },
    "sleep": {
        "motion_class": "segmented",
        "final_frames": 9,
        "holds": [0.26, 0.30, 0.48, 0.90, 0.75, 1.10, 0.24, 0.28, 0.42],
        "segments": [
            {"name": "lie-down", "start": 0, "count": 3},
            {"name": "breathing-loop", "start": 3, "count": 3},
            {"name": "rise", "start": 6, "count": 3},
        ],
        "pose_contract": (
            "Frames 1-3 transition from standing into the supplied cute sleeping "
            "construction: the low torso and curled legs trail toward screen-left; "
            "the head is at screen-right with one cheek resting on crossed forearms; "
            "eyes are closed and the long hair falls beside the face toward "
            "screen-right. Frames 4-6 keep exactly that construction and only "
            "breathe. Frames 7-9 reverse the physical path back to the canonical "
            "stand. Keep limb order, the complete solid hair silhouette, accessory "
            "sides, and ground contact physically continuous."
        ),
        "batches": [
            [
                "standing, preparing to settle",
                "body lowers with hands reaching support",
                "side-lying sleep pose becomes fully established",
            ],
            [
                "same sleep pose at settled exhale",
                "same sleep pose at slow inhale crest",
                "same sleep pose returning to settled exhale",
            ],
            [
                "sleep pose wakes and torso rises",
                "supported crouch transitioning upward",
                "stable canonical standing pose",
            ],
        ],
    },
    "gaze": {
        "motion_class": "directional",
        "final_frames": 5,
        "directions": ["neutral", "up", "right", "down", "left"],
        "pose_contract": (
            "Keep feet and lower body fixed. Eyes lead; head/neck and only a "
            "restrained upper-body follow may move. Never rotate the whole sprite."
        ),
        "batches": [
            ["neutral gaze", "look up", "look toward screen-right"],
            [
                "look down",
                "look toward screen-left",
                "closure check: recreate neutral gaze; discard this frame",
            ],
        ],
        "keep_per_batch": [3, 2],
    },
    "tennis": {
        "motion_class": "gesture",
        "final_frames": 9,
        "holds": [0.24, 0.18, 0.14, 0.10, 0.09, 0.16, 0.20, 0.24, 0.36],
        "pose_contract": (
            "Perform one readable forehand rally loop. The same tennis racket "
            "must keep identical frame shape, handle, strings, scale, and hand "
            "attachment throughout. Draw no tennis ball: runtime adds its "
            "trajectory deterministically so the ball cannot duplicate or drift."
        ),
        "batches": [
            [
                "athletic ready stance holding the racket",
                "weight shift and racket preparation",
                "forehand backswing reaches its useful extreme",
            ],
            [
                "forward acceleration begins",
                "clean forehand contact pose; no ball is drawn",
                "follow-through crosses the body",
            ],
            [
                "follow-through settles",
                "feet and racket recover toward ready stance",
                "original athletic ready stance, closing the loop",
            ],
        ],
    },
    "wall": {
        "motion_class": "ambient",
        "final_frames": 6,
        "holds": [0.70, 0.55, 0.95, 0.75, 0.55, 0.95],
        "segments": [
            {"name": "wall-stand", "start": 0, "count": 3},
            {"name": "ledge-sit", "start": 3, "count": 3},
        ],
        "pose_contract": (
            "The first family stands against an invisible screen wall; the second "
            "sits on an invisible edge with legs hanging. Keep the authored wall "
            "or ledge contact fixed and draw no scenery."
        ),
        "batches": [
            [
                "relaxed wall-standing pose at settled exhale",
                "same wall contact with a small inhale and weight shift",
                "same relaxed wall-standing pose, closing the seam",
            ],
            [
                "sitting on an invisible screen-edge ledge, legs hanging",
                "same ledge contact with one gentle alternating leg swing",
                "same settled ledge-sit pose, closing the seam",
            ],
        ],
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--canonical-master", required=True)
    parser.add_argument("--action", required=True, choices=sorted(PROFILES))
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--identity-notes", default="")
    parser.add_argument("--style-board")
    parser.add_argument("--motion-guide")
    parser.add_argument("--pose-reference")
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def safe_reset(path: Path, force: bool) -> None:
    if not path.exists():
        return
    if not force:
        raise SystemExit(f"output directory exists; pass --force to replace it: {path}")
    resolved = path.resolve()
    forbidden = {Path("/"), Path.home().resolve(), Path.cwd().resolve()}
    if resolved in forbidden or len(resolved.parts) < 4:
        raise SystemExit(f"refusing to replace broad path: {resolved}")
    shutil.rmtree(resolved)


def image_info(path: Path) -> dict:
    try:
        with Image.open(path) as image:
            image.load()
            return {
                "width": image.width,
                "height": image.height,
                "mode": image.mode,
                "format": image.format,
            }
    except Exception as error:
        raise SystemExit(f"unreadable image {path}: {error}") from error


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_reference(source: Path, references: Path, stem: str) -> tuple[str, dict]:
    if not source.is_file():
        raise SystemExit(f"missing reference: {source}")
    info = image_info(source)
    suffix = source.suffix.lower() or ".png"
    destination = references / f"{stem}{suffix}"
    shutil.copy2(source, destination)
    return destination.relative_to(references.parent).as_posix(), {
        **info,
        "sha256": sha256(destination),
        "source_path": str(source),
    }


def make_keyed_reference(source: Path, destination: Path) -> dict:
    """Flatten a transparent identity reference onto the generation key color."""
    with Image.open(source) as loaded:
        foreground = loaded.convert("RGBA")
    canvas = Image.new("RGBA", foreground.size, CHROMA_KEY)
    canvas.alpha_composite(foreground)
    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(destination)
    return {
        **image_info(destination),
        "sha256": sha256(destination),
        "source_path": str(source),
        "purpose": (
            "ImageGen identity reference flattened onto the same chroma key so "
            "transparent exterior pixels cannot be learned as opaque white"
        ),
    }


def make_layout_guide(path: Path) -> None:
    columns = BATCH_LAYOUT["columns"]
    panel_width = BATCH_LAYOUT["source_cell_width"]
    panel_height = BATCH_LAYOUT["source_cell_height"]
    image = Image.new(
        "RGB", (BATCH_LAYOUT["width"], BATCH_LAYOUT["height"]), "#F1EDF8")
    draw = ImageDraw.Draw(image)
    for index in range(columns):
        x = index * panel_width
        draw.rectangle(
            (x + 2, 2, x + panel_width - 3, panel_height - 3),
            outline="#392F5A", width=4)
        draw.rectangle(
            (x + 48, 48, x + panel_width - 49, panel_height - 97),
            outline="#F6BD60", width=3)
        draw.line(
            (x + panel_width // 2, 48, x + panel_width // 2, panel_height - 97),
            fill="#87CEEB", width=2)
        draw.line(
            (x + 48, panel_height - 96, x + panel_width - 49, panel_height - 96),
            fill="#E05A47", width=3)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8")


def batch_prompt(action: str, profile: dict, batch_index: int,
                 identity_notes: str, has_style: bool, has_motion: bool,
                 has_pose: bool) -> str:
    phases = profile["batches"][batch_index]
    previous = batch_index > 0
    phases = "\n".join(
        f"- FRAME {index + 1:02d}: {phase}"
        for index, phase in enumerate(phases)
    )
    pose_contract = profile.get(
        "pose_contract",
        "Use one stable pose construction across the family; only the named "
        "motion phases may change it.")
    reference_lines = [
        "Image 1 is the CANONICAL MASTER and ABSOLUTE IDENTITY LOCK.",
    ]
    next_image = 2
    if has_pose:
        reference_lines.append(
            f"Image {next_image} is a POSE REFERENCE. Use body mechanics and "
            "composition only; never copy its identity, outfit, accessories, "
            "resolution, or rendering style.")
        next_image += 1
    if has_style:
        reference_lines.append(
            f"Image {next_image} is Mimo's STYLE BOARD. Use rendering language only.")
        next_image += 1
    if has_motion:
        reference_lines.append(
            f"Image {next_image} is a MOTION GUIDE. Use timing and joint mechanics only.")
        next_image += 1
    if previous:
        reference_lines.append(
            f"Image {next_image} is the PREVIOUS APPROVED THREE-FRAME BATCH. "
            "Use it only for local motion continuity and appearance evidence; "
            "the canonical master remains authoritative.")
        next_image += 1
    reference_lines.append(
        f"Image {next_image} is a LAYOUT GUIDE. Use slots, safe margins, and baseline only.")

    extra = ""
    if profile["motion_class"] == "locomotion":
        extra = """
Keep planted-foot contacts physically credible and preserve left/right limb
identity. The loop is a complete two-step cycle. No foot skate, repeated wide
stride, phase reversal, speed line, dust, blur, or floor shadow."""
    elif profile["motion_class"] == "ambient":
        extra = """
Keep motion deliberately small. Feet/base and lower-body registration stay
fixed. Do not invent a larger gesture merely to make neighboring frames differ."""
    elif profile["motion_class"] == "directional":
        extra = """
Use approved natural eye/head/body mechanics. Directions are viewer/screen
coordinates. Do not rotate the whole sprite or replace the character's eyes."""
    elif profile["motion_class"] == "segmented":
        extra = """
This batch belongs to a larger authored transition/loop sequence. Match the
approved neighboring batch at its boundary; do not jump directly to a later
segment or redesign the settled sleep pose."""

    return f"""Create batch {batch_index + 1} of one high-fidelity Mimo action: `{action}`.

REFERENCES
{chr(10).join(reference_lines)}
Reference priority is canonical master > accepted identity evidence > pose
mechanics > accepted action family > style board > motion guide > layout guide.

IDENTITY AND FIDELITY LOCK
Reproduce the exact same individual in every frame. Preserve face geometry,
hair silhouette, body proportions, clothing cut, asymmetric markings and
accessories, palette, anti-aliasing, outline weight, lighting, shading, material
rendering, and the same rendering detail density as Image 1.
Identity notes: {identity_notes or "preserve every stable trait visible in the canonical master"}.
Only pose and physically necessary secondary motion may change.
Do not simplify the character into a mascot, enlarge pixel blocks, reduce the
palette, flatten the shading, genericize the face, or redesign any detail.

COHERENT FAMILY
Draw exactly three consecutive frames together as one coherent generation.
Never treat them as unrelated illustrations. Use the same camera, scale,
baseline, registration, light, renderer, hair mass, face, and body proportions
for all three. Do not infer identity from the previous batch when it conflicts
with the canonical master.

OUTPUT
Create exactly three active frames as three vertical panels on one
1536×1024 canvas. Each source panel is 512×1024 and will later be registered
into one 512×512 runtime cell. Read left to right.
Use one perfectly flat, opaque {CHROMA_KEY} chroma-key background over the complete
canvas for local background removal. The background must have no shadow,
gradient, texture, reflection, floor plane, guide marks, or lighting variation.
Do not use {CHROMA_KEY} anywhere inside the character. Magenta visible around
the outside of the canonical subject is BACKGROUND, never white material.
Preserve only genuine open space outside the authored character contour. The
hair must remain one continuous solid mass behind and beside the face: never
create an enclosed magenta window between a front hair lock and the forehead,
eye, nose, cheek, jaw, neck, or shoulder. Such a window becomes a white-looking
hole after keying and is a hard failure. Keep the complete pose inside
each panel with at least 48px clear side/top padding and 96px clear background
below the authored baseline. Preserve a crisp, solid, fully enclosed hair
silhouette and its dark outline; never cut holes into hair strands or the main
hair mass.
Do not copy guide lines, boxes, center lines, labels, numbers, or marks.

POSES
{phases}

POSE CONSTRUCTION
{pose_contract}

MOTION
{extra}
Match the preceding approved batch when one exists. Closure-check frames are QA
only and will be discarded after comparison with the original first frame.

No scenery, text, grid, shadow, glow, blur, afterimage, detached effect, cropped
limb, floor, or chroma-key color inside the character.
"""


def main() -> None:
    args = parse_args()
    run_dir = Path(args.output_dir).expanduser().resolve()
    canonical = Path(args.canonical_master).expanduser().resolve()
    style = Path(args.style_board).expanduser().resolve() if args.style_board else None
    motion = Path(args.motion_guide).expanduser().resolve() if args.motion_guide else None
    pose = (
        Path(args.pose_reference).expanduser().resolve()
        if args.pose_reference else None
    )
    profile = PROFILES[args.action]

    safe_reset(run_dir, args.force)
    references = run_dir / "references"
    prompts = run_dir / "prompts"
    decoded = run_dir / "decoded"
    qa = run_dir / "qa"
    for directory in (references, prompts, decoded, qa):
        directory.mkdir(parents=True, exist_ok=True)

    canonical_rel, canonical_meta = copy_reference(
        canonical, references, "canonical-master")
    canonical_imagegen_rel = "references/canonical-imagegen-reference.png"
    canonical_imagegen_meta = make_keyed_reference(
        canonical, run_dir / canonical_imagegen_rel)
    style_rel = None
    style_meta = None
    if style:
        style_rel, style_meta = copy_reference(style, references, "style-board")
    motion_rel = None
    motion_meta = None
    if motion:
        motion_rel, motion_meta = copy_reference(motion, references, "motion-guide")
    pose_rel = None
    pose_meta = None
    if pose:
        pose_rel, pose_meta = copy_reference(pose, references, "pose-reference")

    layout_rel = "references/layout-guide.png"
    make_layout_guide(run_dir / layout_rel)
    jobs = []
    kept_per_batch = profile.get(
        "keep_per_batch", [3] * len(profile["batches"]))
    for index, _ in enumerate(profile["batches"]):
        batch_number = index + 1
        job_id = f"batch-{batch_number:02d}"
        prompt_rel = f"prompts/{job_id}.md"
        output_rel = f"decoded/{job_id}.png"
        (run_dir / prompt_rel).write_text(
            batch_prompt(
                args.action, profile, index, args.identity_notes,
                style is not None, motion is not None, pose is not None),
            encoding="utf-8",
        )
        inputs = [
            {
                "path": canonical_imagegen_rel,
                "role": (
                    "canonical identity and fidelity lock on the generation "
                    "chroma key; exterior magenta is background while the "
                    "canonical hair mass must stay solid"
                ),
            },
        ]
        if pose_rel:
            inputs.append({
                "path": pose_rel,
                "role": "body mechanics and composition only; never identity or style",
            })
        if style_rel:
            inputs.append(
                {"path": style_rel, "role": "rendering language only"})
        if motion_rel:
            inputs.append(
                {"path": motion_rel, "role": "motion timing and mechanics only"})
        if index > 0:
            inputs.append({
                "path": f"decoded/batch-{index:02d}.png",
                "role": "previous approved three-frame continuity evidence",
            })
        inputs.append(
            {"path": layout_rel, "role": "layout and safe-zone guide only"})
        jobs.append({
            "id": job_id,
            "kind": "chained-three-frame-family",
            "status": "pending",
            "depends_on": [f"batch-{index:02d}"] if index > 0 else [],
            "prompt_file": prompt_rel,
            "input_images": inputs,
            "output_path": output_rel,
            "expected_output": {
                "width": BATCH_LAYOUT["width"],
                "height": BATCH_LAYOUT["height"],
                "columns": BATCH_LAYOUT["columns"],
                "rows": BATCH_LAYOUT["rows"],
            },
            "keep_frames": kept_per_batch[index],
            "repair_unit": "this complete three-frame batch",
            "acceptance_gate": "explicit approval before the next batch runs",
        })

    timing = {
        "motion_class": profile["motion_class"],
        "frame_holds_seconds": profile.get("holds"),
        "preview_cycle_seconds": profile.get("preview_cycle_seconds"),
        "runtime_phase": (
            "distance-based; require authored cycleDistanceCellPixels"
            if profile["motion_class"] == "locomotion"
            else (
                "cursor-angle mapping; optional short angular easing"
                if profile["motion_class"] == "directional"
                else "behavior pose holds"
            )
        ),
    }
    request = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "action": args.action,
        "identity_notes": args.identity_notes,
        "cell_size": 512,
        "keyframe_count": profile["final_frames"],
        "final_frame_count": profile["final_frames"],
        "layout": BATCH_LAYOUT,
        "batch_plan": {
            "batch_size": 3,
            "batch_count": len(profile["batches"]),
            "keep_per_batch": kept_per_batch,
            "assembly": "register each accepted batch with one shared final scale and "
                        "baseline, then concatenate only kept frames",
        },
        "mirror_for_opposite_direction": profile.get(
            "mirror_for_opposite_direction", False),
        "segments": profile.get("segments"),
        "directions": profile.get("directions"),
        "timing": timing,
        "canonical_master": {"path": canonical_rel, **canonical_meta},
        "canonical_imagegen_reference": {
            "path": canonical_imagegen_rel,
            **canonical_imagegen_meta,
        },
        "style_board": (
            {"path": style_rel, **style_meta} if style_rel and style_meta else None),
        "motion_guide": (
            {"path": motion_rel, **motion_meta} if motion_rel and motion_meta else None),
        "pose_reference": (
            {"path": pose_rel, **pose_meta} if pose_rel and pose_meta else None),
        "quality_contract": {
            "native_cell_size": 512,
            "canonical_detail_density_must_be_preserved": True,
            "coherent_generation_unit": "chained three-frame batch",
            "shared_scale_baseline_anchor": True,
            "independent_final_frame_generation_allowed": False,
            "transparency_pipeline": "built-in-flat-chroma-key-plus-local-soft-matte",
            "direct_transparency_preferred": False,
            "alpha_edge_contract_allowed": False,
        },
    }
    write_json(run_dir / "action-request.json", request)
    write_json(run_dir / "imagegen-jobs.json", {
        "schema_version": 1,
        "action": args.action,
        "jobs": jobs,
    })
    write_json(run_dir / "qa" / "run-summary.json", {
        "ok": False,
        "status": "prepared",
        "accepted_asset": None,
        "required_checks": [
            "source geometry",
            "shared scale/baseline/anchor",
            "identity and detail density",
            "motion semantics and loop seam",
            "real-size authored-timing preview",
        ],
    })
    print(json.dumps({
        "ok": True,
        "run_dir": str(run_dir),
        "action": args.action,
        "jobs": [job["id"] for job in jobs],
        "keyframes": profile["final_frames"],
        "final_frames": profile["final_frames"],
    }, indent=2))


if __name__ == "__main__":
    main()
