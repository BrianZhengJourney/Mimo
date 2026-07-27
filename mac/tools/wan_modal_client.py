#!/usr/bin/env python3
"""Profile-neutral client for Mimo's private Wan2.2-Animate Modal pipeline."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
from typing import Any, Sequence


APP_NAME = "mimo-wan22-animate"
JOBS_VOLUME_NAME = "mimo-wan22-jobs"
MODEL_REVISION = "cb93a225fbaf1ca100f54e79da8f994995b689b3"
WAN_COMMIT = "42bf4cfaa384bc21833865abc2f9e6c0e67233dc"
JOB_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
REQUEST_SCHEMA_VERSION = 1

STAGE_FUNCTIONS = {
    "download-preprocess": "download_preprocess_model",
    "preprocess": "preprocess",
    "download-inference": "download_inference_model",
    "validate-inputs": "validate_inference_inputs",
    "infer": "infer",
    "preflight": "preflight",
}
JOB_REQUIRED_STAGES = {"preprocess", "download-inference", "validate-inputs", "infer"}
DOWNLOAD_STAGE_PATHS = {
    "preprocess": "preprocess",
    "output": "output",
}


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def validate_job_id(job_id: str) -> str:
    if not JOB_ID_PATTERN.fullmatch(job_id):
        raise ValueError(
            "job id must be 1-64 characters, start with a letter/digit, and contain only "
            "ASCII letters, digits, '.', '_' or '-'"
        )
    return job_id


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _input_file(path_text: str, extensions: set[str], label: str) -> Path:
    path = Path(path_text).expanduser().resolve()
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"{label} is missing or empty: {path}")
    if path.suffix.lower() not in extensions:
        allowed = ", ".join(sorted(extensions))
        raise ValueError(f"{label} must use one of these extensions: {allowed}")
    return path


def build_request(
    *,
    job_id: str,
    character: Path,
    driver: Path,
    width: int,
    height: int,
    frame_num: int,
    sample_steps: int,
    seed: int,
    retarget: bool,
    neutral_background: Sequence[int],
    cycle_start_frame: int,
    cycle_end_frame_exclusive: int,
    frozen_face_frame: int,
) -> dict[str, Any]:
    validate_job_id(job_id)
    if frame_num < 5 or (frame_num - 1) % 4:
        raise ValueError("frame-num must be 4n+1 and at least 5 (for example 77)")
    if not 1 <= sample_steps <= 100:
        raise ValueError("sample-steps must be between 1 and 100")
    if not (256 <= width <= 2048 and 256 <= height <= 2048):
        raise ValueError("width and height must each be between 256 and 2048")
    if len(neutral_background) != 3 or any(not 0 <= int(value) <= 255 for value in neutral_background):
        raise ValueError("neutral background needs three RGB values from 0 to 255")
    if not 0 <= cycle_start_frame < cycle_end_frame_exclusive < frame_num:
        raise ValueError(
            "cycle frames must satisfy 0 <= cycle-start-frame < "
            "cycle-end-frame-exclusive < frame-num"
        )
    if not 0 <= frozen_face_frame < frame_num:
        raise ValueError("frozen-face-frame must be inside the generated frame range")
    return {
        "schema_version": REQUEST_SCHEMA_VERSION,
        "job_id": job_id,
        "created_at": _utc_now(),
        "character_file": "character.png",
        "driver_file": "driver.mp4",
        "resolution_area": [width, height],
        "frame_num": frame_num,
        "sample_steps": sample_steps,
        "seed": seed,
        "retarget": retarget,
        "use_flux": False,
        "cycleStartFrame": cycle_start_frame,
        "cycleEndFrameExclusive": cycle_end_frame_exclusive,
        "closureFrame": cycle_end_frame_exclusive,
        "frozenFaceFrame": frozen_face_frame,
        "neutral_background": [int(value) for value in neutral_background],
        "sha256": {
            "character": sha256_file(character),
            "driver": sha256_file(driver),
        },
        "provenance": {
            "wan_commit": WAN_COMMIT,
            "model_revision": MODEL_REVISION,
        },
    }


def _load_modal() -> Any:
    try:
        return importlib.import_module("modal")
    except ImportError as error:
        raise RuntimeError("Modal is not installed in this Python environment") from error


def _volume(modal_module: Any, environment: str | None, create: bool = True) -> Any:
    return modal_module.Volume.from_name(
        JOBS_VOLUME_NAME,
        environment_name=environment,
        create_if_missing=create,
    )


def _print_json(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))


def _read_volume_bytes(volume: Any, remote_path: str) -> bytes:
    return b"".join(volume.read_file(remote_path))


def _read_volume_json(volume: Any, remote_path: str) -> dict[str, Any]:
    value = json.loads(_read_volume_bytes(volume, remote_path).decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected JSON object at {remote_path}")
    return value


def command_upload(args: argparse.Namespace) -> dict[str, Any]:
    character = _input_file(args.character, {".png", ".jpg", ".jpeg", ".webp"}, "character")
    driver = _input_file(args.driver, {".mp4"}, "driver")
    request = build_request(
        job_id=args.job_id,
        character=character,
        driver=driver,
        width=args.width,
        height=args.height,
        frame_num=args.frame_num,
        sample_steps=args.sample_steps,
        seed=args.seed,
        retarget=args.retarget,
        neutral_background=args.neutral_background,
        cycle_start_frame=args.cycle_start_frame,
        cycle_end_frame_exclusive=args.cycle_end_frame_exclusive,
        frozen_face_frame=args.frozen_face_frame,
    )
    prefix = f"jobs/{args.job_id}/input"
    plan = {
        "operation": "upload",
        "dry_run": args.dry_run,
        "job_id": args.job_id,
        "volume": JOBS_VOLUME_NAME,
        "force": args.force,
        "files": {
            str(character): f"{prefix}/character.png",
            str(driver): f"{prefix}/driver.mp4",
            "request": f"{prefix}/request.json",
        },
        "request": request,
        "next": "spawn --stage download-preprocess, then spawn --stage preprocess",
    }
    if args.dry_run:
        return plan

    modal_module = _load_modal()
    volume = _volume(modal_module, args.environment)
    request_stream = io.BytesIO(
        (json.dumps(request, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    )
    with volume.batch_upload(force=args.force) as batch:
        batch.put_file(character, f"{prefix}/character.png")
        batch.put_file(driver, f"{prefix}/driver.mp4")
        batch.put_file(request_stream, f"{prefix}/request.json")
    plan["uploaded"] = True
    return plan


def _spawn_kwargs(stage: str, job_id: str | None, seed: int | None) -> dict[str, Any]:
    if stage in JOB_REQUIRED_STAGES and not job_id:
        raise ValueError(f"--job-id is required for stage {stage}")
    if job_id:
        validate_job_id(job_id)
    if stage == "download-preprocess":
        return {}
    if stage == "preflight":
        return {"job_id": job_id}
    if stage == "infer":
        return {"job_id": job_id, "seed": seed}
    return {"job_id": job_id}


def command_spawn(args: argparse.Namespace) -> dict[str, Any]:
    function_name = STAGE_FUNCTIONS[args.stage]
    kwargs = _spawn_kwargs(args.stage, args.job_id, args.seed)
    plan = {
        "operation": "spawn",
        "dry_run": args.dry_run,
        "app": APP_NAME,
        "stage": args.stage,
        "function": function_name,
        "kwargs": kwargs,
    }
    if args.stage == "infer":
        plan["gpu"] = "H200"
        plan["hard_timeout_seconds"] = 1800
    elif args.stage == "preprocess":
        plan["gpu"] = "L4"
        plan["hard_timeout_seconds"] = 900
    else:
        plan["gpu"] = None
    if args.dry_run:
        return plan

    modal_module = _load_modal()
    function = modal_module.Function.from_name(
        APP_NAME,
        function_name,
        environment_name=args.environment,
    )
    call = function.spawn(**kwargs)
    plan.update(
        {
            "spawned": True,
            "call_id": call.object_id,
            "status_command": f"status {call.object_id}",
        }
    )
    return plan


def command_status(args: argparse.Namespace) -> dict[str, Any]:
    modal_module = _load_modal()
    call = modal_module.FunctionCall.from_id(args.call_id)
    try:
        result = call.get(timeout=0)
    except TimeoutError:
        return {"call_id": args.call_id, "status": "running_or_pending"}
    return {"call_id": args.call_id, "status": "finished", "result": result}


def command_approve(args: argparse.Namespace) -> dict[str, Any]:
    validate_job_id(args.job_id)
    if not args.yes_reviewed_cycle_sheet:
        raise ValueError(
            "approval requires --yes-reviewed-cycle-sheet after checking every packed frame, "
            "closure frame, and frozen/dynamic face row in cycle-contact-sheet.jpg"
        )
    if args.dry_run:
        return {
            "operation": "approve",
            "dry_run": True,
            "job_id": args.job_id,
            "note": args.note,
            "warning": "No marker was written.",
        }

    modal_module = _load_modal()
    volume = _volume(modal_module, args.environment, create=False)
    ready_path = f"jobs/{args.job_id}/preprocess/READY.json"
    ready = _read_volume_json(volume, ready_path)
    if ready.get("job_id") != args.job_id or not ready.get("preprocess_id"):
        raise RuntimeError("READY.json is missing a matching job_id/preprocess_id")
    review_range = ready.get("reviewRange")
    if not isinstance(review_range, dict):
        raise RuntimeError("READY.json is missing the authoritative reviewRange")
    start = review_range.get("cycleStartFrame")
    end_exclusive = review_range.get("cycleEndFrameExclusive")
    closure = review_range.get("closureFrame")
    reviewed_frames = review_range.get("reviewedPoseFrames")
    if (
        not isinstance(start, int)
        or not isinstance(end_exclusive, int)
        or closure != end_exclusive
        or reviewed_frames != list(range(start, end_exclusive + 1))
        or not ready.get("cycleContactSheetSha256")
        or not isinstance(ready.get("frozenFaceFrame"), int)
    ):
        raise RuntimeError("READY.json contains an invalid cycle/closure review contract")
    approval = {
        "status": "approved",
        "job_id": args.job_id,
        "preprocess_id": ready["preprocess_id"],
        "reviewedCycleContactSheet": True,
        "reviewRange": review_range,
        "frozenFaceFrame": ready["frozenFaceFrame"],
        "cycleContactSheetSha256": ready["cycleContactSheetSha256"],
        "approved_at": _utc_now(),
        "approved_by": os.environ.get("USER", "unknown"),
        "note": args.note,
    }
    if ready.get("requestSha256") is not None or ready.get("inferenceInputsSha256") is not None:
        approval["requestSha256"] = ready.get("requestSha256")
        approval["inferenceInputsSha256"] = ready.get("inferenceInputsSha256")
    stream = io.BytesIO(
        (json.dumps(approval, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    )
    with volume.batch_upload(force=True) as batch:
        batch.put_file(stream, f"jobs/{args.job_id}/APPROVED.json")
    return {
        "operation": "approve",
        "job_id": args.job_id,
        "preprocess_id": ready["preprocess_id"],
        "reviewRange": review_range,
        "approved": True,
        "next": "spawn --stage validate-inputs --job-id ...",
    }


def command_download(args: argparse.Namespace) -> dict[str, Any]:
    validate_job_id(args.job_id)
    modal_module = _load_modal()
    volume = _volume(modal_module, args.environment, create=False)
    remote_root = PurePosixPath("jobs") / args.job_id / DOWNLOAD_STAGE_PATHS[args.stage]
    output_root = Path(args.out).expanduser().resolve()
    entries = volume.listdir(str(remote_root), recursive=True)
    files = [entry for entry in entries if getattr(entry.type, "name", "") == "FILE"]
    if not files:
        raise FileNotFoundError(f"No files found at {remote_root}")

    downloaded: list[str] = []
    for entry in files:
        remote_path = PurePosixPath(entry.path)
        try:
            relative = remote_path.relative_to(remote_root)
        except ValueError as error:
            raise RuntimeError(f"Modal returned path outside requested stage: {entry.path}") from error
        if not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
            raise RuntimeError(f"Unsafe artifact path: {entry.path}")
        local_path = output_root.joinpath(*relative.parts)
        local_path.parent.mkdir(parents=True, exist_ok=True)
        with local_path.open("wb") as handle:
            volume.read_file_into_fileobj(entry.path, handle)
        downloaded.append(str(local_path))
    return {
        "operation": "download",
        "job_id": args.job_id,
        "stage": args.stage,
        "files": downloaded,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Upload, gate and run Mimo Wan2.2-Animate jobs on a deployed private Modal app."
    )
    parser.add_argument(
        "--environment",
        help="Optional Modal environment name (not a profile). Select profiles with MODAL_PROFILE.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    upload = subparsers.add_parser("upload", help="Upload a reference, driver and immutable request")
    upload.add_argument("--job-id", required=True)
    upload.add_argument("--character", required=True)
    upload.add_argument("--driver", required=True)
    upload.add_argument("--width", type=int, default=512)
    upload.add_argument("--height", type=int, default=512)
    upload.add_argument("--frame-num", type=int, default=77)
    upload.add_argument("--sample-steps", type=int, default=20)
    upload.add_argument("--seed", type=int, default=42)
    upload.add_argument("--cycle-start-frame", type=int, default=24)
    upload.add_argument("--cycle-end-frame-exclusive", type=int, default=48)
    upload.add_argument("--frozen-face-frame", type=int, default=24)
    upload.add_argument("--retarget", action="store_true")
    upload.add_argument("--neutral-background", nargs=3, type=int, default=[127, 127, 127])
    upload.add_argument("--force", action="store_true")
    upload.add_argument("--dry-run", action="store_true")
    upload.set_defaults(handler=command_upload)

    spawn = subparsers.add_parser("spawn", help="Start one deployed stage asynchronously")
    spawn.add_argument("--stage", choices=sorted(STAGE_FUNCTIONS), required=True)
    spawn.add_argument("--job-id")
    spawn.add_argument("--seed", type=int)
    spawn.add_argument("--dry-run", action="store_true")
    spawn.set_defaults(handler=command_spawn)

    status = subparsers.add_parser("status", help="Poll a spawned Modal function call")
    status.add_argument("call_id")
    status.set_defaults(handler=command_status)

    approve = subparsers.add_parser("approve", help="Approve the exact downloaded preprocessing run")
    approve.add_argument("--job-id", required=True)
    approve.add_argument("--yes-reviewed-cycle-sheet", action="store_true")
    approve.add_argument("--note", default="")
    approve.add_argument("--dry-run", action="store_true")
    approve.set_defaults(handler=command_approve)

    download = subparsers.add_parser("download", help="Download preprocessing or inference artifacts")
    download.add_argument("--job-id", required=True)
    download.add_argument("--stage", choices=sorted(DOWNLOAD_STAGE_PATHS), required=True)
    download.add_argument("--out", required=True)
    download.set_defaults(handler=command_download)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        result = args.handler(args)
    except (ValueError, RuntimeError, FileNotFoundError, FileExistsError) as error:
        parser.error(str(error))
    _print_json(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
