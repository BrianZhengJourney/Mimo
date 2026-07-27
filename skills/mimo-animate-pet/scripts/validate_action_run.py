#!/usr/bin/env python3
"""Validate a prepared or partially completed Mimo action run."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:
        raise SystemExit(f"cannot read {path}: {error}") from error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir")
    parser.add_argument("--json-out")
    args = parser.parse_args()

    run_dir = Path(args.run_dir).expanduser().resolve()
    errors: list[str] = []
    warnings: list[str] = []

    request_path = run_dir / "action-request.json"
    jobs_path = run_dir / "imagegen-jobs.json"
    if not request_path.is_file():
        errors.append("missing action-request.json")
    if not jobs_path.is_file():
        errors.append("missing imagegen-jobs.json")
    if errors:
        result = {"ok": False, "errors": errors, "warnings": warnings}
        print(json.dumps(result, indent=2))
        raise SystemExit(1)

    request = load_json(request_path)
    manifest = load_json(jobs_path)
    if request.get("schema_version") != 1 or manifest.get("schema_version") != 1:
        errors.append("unsupported schema version")
    if request.get("action") != manifest.get("action"):
        errors.append("request and job manifest action mismatch")
    if request.get("cell_size") != 512:
        errors.append("Mimo action cells must remain 512px")
    if request.get("keyframe_count", 0) <= 0:
        errors.append("keyframe count must be positive")
    if request.get("final_frame_count", 0) < request.get("keyframe_count", 0):
        errors.append("final frame count cannot be smaller than keyframe count")

    quality = request.get("quality_contract") or {}
    expected_quality = {
        "canonical_detail_density_must_be_preserved": True,
        "shared_scale_baseline_anchor": True,
        "independent_final_frame_generation_allowed": False,
    }
    for key, expected in expected_quality.items():
        if quality.get(key) != expected:
            errors.append(f"quality contract has invalid {key}")

    canonical = request.get("canonical_master") or {}
    canonical_path = run_dir / str(canonical.get("path", ""))
    if not canonical_path.is_file():
        errors.append("canonical master snapshot is missing")
    else:
        if sha256(canonical_path) != canonical.get("sha256"):
            errors.append("canonical master hash changed after preparation")
        try:
            with Image.open(canonical_path) as image:
                if image.width < 256 or image.height < 256:
                    warnings.append(
                        "canonical master is under 256px on one axis; inspect fidelity carefully")
        except Exception as error:
            errors.append(f"canonical master is unreadable: {error}")

    jobs = manifest.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        errors.append("job manifest has no jobs")
        jobs = []
    ids = [job.get("id") for job in jobs]
    if len(ids) != len(set(ids)):
        errors.append("job ids must be unique")

    known = set(ids)
    for job in jobs:
        job_id = job.get("id", "<unknown>")
        dependencies = job.get("depends_on") or []
        if any(dependency not in known for dependency in dependencies):
            errors.append(f"{job_id} has an unknown dependency")
        prompt_path = run_dir / str(job.get("prompt_file", ""))
        if not prompt_path.is_file():
            errors.append(f"{job_id} prompt is missing")
        else:
            prompt = prompt_path.read_text(encoding="utf-8")
            for required in (
                "ABSOLUTE IDENTITY LOCK",
                "same rendering detail density",
                "512×512",
            ):
                if required not in prompt:
                    errors.append(f"{job_id} prompt lacks `{required}`")
        for item in job.get("input_images") or []:
            path = run_dir / str(item.get("path", ""))
            if not path.exists():
                producer = next(
                    (candidate for candidate in jobs
                     if candidate.get("output_path") == item.get("path")),
                    None,
                )
                if producer is None or producer.get("id") not in dependencies:
                    errors.append(f"{job_id} input is missing without dependency: {item.get('path')}")

        output = run_dir / str(job.get("output_path", ""))
        if output.is_file():
            try:
                with Image.open(output) as image:
                    layout = request.get("layout") or {}
                    if image.width != layout.get("width") or image.height != layout.get("height"):
                        warnings.append(
                            f"{job_id} output is {image.width}x{image.height}; "
                            f"expected {layout.get('width')}x{layout.get('height')} "
                            "before deterministic registration")
            except Exception as error:
                errors.append(f"{job_id} output is unreadable: {error}")

    timing = request.get("timing") or {}
    motion_class = timing.get("motion_class")
    holds = timing.get("frame_holds_seconds")
    if motion_class == "locomotion":
        if not str(timing.get("runtime_phase", "")).startswith("distance-based"):
            errors.append("locomotion must use distance-based phase")
        if timing.get("preview_cycle_seconds") is None:
            errors.append("locomotion needs an authored preview cycle")
    elif motion_class == "directional":
        if not str(timing.get("runtime_phase", "")).startswith("cursor-angle"):
            errors.append("directional actions must use cursor-angle mapping")
    else:
        if not isinstance(holds, list) or len(holds) != request.get("final_frame_count"):
            errors.append("non-locomotion actions need one authored hold per final frame")
        elif any(not isinstance(value, (int, float)) or value <= 0 for value in holds):
            errors.append("all authored holds must be positive")
        elif motion_class == "ambient" and sum(holds) < 1.5:
            errors.append("ambient loop is too fast; authored duration must be at least 1.5s")

    result = {
        "ok": not errors,
        "action": request.get("action"),
        "errors": errors,
        "warnings": warnings,
        "jobs": ids,
        "generated_outputs": [
            job.get("id") for job in jobs
            if (run_dir / str(job.get("output_path", ""))).is_file()
        ],
    }
    output = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.json_out:
        Path(args.json_out).expanduser().resolve().write_text(output, encoding="utf-8")
    print(output, end="")
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
