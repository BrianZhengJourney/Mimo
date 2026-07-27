"""Modal stages for the official Wan2.2-Animate-14B Mimo proof of concept.

This module intentionally exposes batch functions only.  It is not a public API:
inputs are uploaded to a private Modal Volume, preprocessing is reviewed by a
human, and inference is blocked until the matching preprocessing run is approved.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any
import uuid

import modal


APP_NAME = "mimo-wan22-animate"
MODEL_VOLUME_NAME = "mimo-wan22-models"
JOBS_VOLUME_NAME = "mimo-wan22-jobs"

WAN_REPOSITORY = "https://github.com/Wan-Video/Wan2.2.git"
WAN_COMMIT = "42bf4cfaa384bc21833865abc2f9e6c0e67233dc"
MODEL_REPOSITORY = "Wan-AI/Wan2.2-Animate-14B"
MODEL_REVISION = "cb93a225fbaf1ca100f54e79da8f994995b689b3"
SAM2_COMMIT = "0e78a118995e66bb27d78518c4bd9a3e95b4e266"

WAN_ROOT = Path("/opt/Wan2.2")
MIMO_RUNTIME_ROOT = Path("/opt/mimo")
MIMO_PREPROCESS_ENTRY = MIMO_RUNTIME_ROOT / "wan_preprocess_entry.py"
LOCAL_MODAL_ROOT = Path(__file__).resolve().parent
MODEL_MOUNT = Path("/models")
MODEL_ROOT = MODEL_MOUNT / "Wan2.2-Animate-14B"
JOBS_MOUNT = Path("/jobs")
JOBS_ROOT = JOBS_MOUNT / "jobs"

DEFAULT_WIDTH = 512
DEFAULT_HEIGHT = 512
DEFAULT_FRAME_NUM = 77
DEFAULT_SAMPLE_STEPS = 20
DEFAULT_SEED = 42
DEFAULT_CYCLE_START_FRAME = 24
DEFAULT_CYCLE_END_FRAME_EXCLUSIVE = 48
DEFAULT_FROZEN_FACE_FRAME = 24
CONTROL_FPS = 30
H200_GPU_USD_PER_SECOND = 0.001261  # Modal public price snapshot, 2026-07.
L4_GPU_USD_PER_SECOND = 0.000222
CPU_CORE_USD_PER_SECOND = 0.0000131
MEMORY_GIB_USD_PER_SECOND = 0.00000222
VOLUME_STORAGE_USD_PER_GIB_MONTH = 0.09
VOLUME_FREE_TIER_GIB_MONTH = 1024
H200_CPU_CORES = 8
H200_MEMORY_GIB = 96
L4_CPU_CORES = 8
L4_MEMORY_GIB = 16
H200_TOTAL_USD_PER_SECOND = (
    H200_GPU_USD_PER_SECOND
    + H200_CPU_CORES * CPU_CORE_USD_PER_SECOND
    + H200_MEMORY_GIB * MEMORY_GIB_USD_PER_SECOND
)
L4_TOTAL_USD_PER_SECOND = (
    L4_GPU_USD_PER_SECOND
    + L4_CPU_CORES * CPU_CORE_USD_PER_SECOND
    + L4_MEMORY_GIB * MEMORY_GIB_USD_PER_SECOND
)

JOB_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
REQUEST_SCHEMA_VERSION = 1

# Keep the pose gate cheap: it does not require the 14B diffusion weights.
PREPROCESS_MODEL_ALLOW_PATTERNS = (
    "config.json",
    "configuration.json",
    "process_checkpoint/det/*",
    "process_checkpoint/pose2d/*",
)

# Animation-only inference files.  Tokenizer configs are enumerated so
# snapshot_download does not fetch duplicate text-encoder model weights.
INFERENCE_MODEL_ALLOW_PATTERNS = (
    "config.json",
    "configuration.json",
    "diffusion_pytorch_model*.safetensors",
    "diffusion_pytorch_model.safetensors.index.json",
    "Wan2.1_VAE.pth",
    "models_t5_umt5-xxl-enc-bf16.pth",
    "models_clip_open-clip-xlm-roberta-large-vit-huge-14.pth",
    "google/umt5-xxl/special_tokens_map.json",
    "google/umt5-xxl/spiece.model",
    "google/umt5-xxl/tokenizer.json",
    "google/umt5-xxl/tokenizer_config.json",
    "xlm-roberta-large/config.json",
    "xlm-roberta-large/sentencepiece.bpe.model",
    "xlm-roberta-large/special_tokens_map.json",
    "xlm-roberta-large/tokenizer.json",
    "xlm-roberta-large/tokenizer_config.json",
)


app = modal.App(APP_NAME)
model_volume = modal.Volume.from_name(MODEL_VOLUME_NAME, create_if_missing=True)
jobs_volume = modal.Volume.from_name(JOBS_VOLUME_NAME, create_if_missing=True)

download_image = modal.Image.debian_slim(python_version="3.11").pip_install(
    "huggingface_hub==0.34.4",
    "hf_transfer==0.1.9",
)

wan_image = (
    modal.Image.from_registry(
        "nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04",
        add_python="3.11",
    )
    .pip_install(
        "torch==2.5.1",
        "torchvision==0.20.1",
        "torchaudio==2.5.1",
        index_url="https://download.pytorch.org/whl/cu124",
    )
    .pip_install(
        "accelerate==1.10.1",
        "av==14.0.1",
        "dashscope==1.24.1",
        "decord==0.6.0",
        "diffusers==0.35.2",
        "easydict==1.13",
        "einops==0.8.1",
        "ftfy==6.3.1",
        "huggingface_hub==0.34.4",
        "hydra-core==1.3.2",
        "imageio==2.37.0",
        "imageio-ffmpeg==0.6.0",
        "loguru==0.7.3",
        "librosa==0.10.2.post1",
        "matplotlib==3.9.4",
        "moviepy==1.0.3",
        "ninja==1.11.1.4",
        "numpy==1.26.4",
        "omegaconf==2.3.0",
        "onnxruntime-gpu==1.20.1",
        "opencv-python-headless==4.11.0.86",
        "packaging==24.2",
        "pandas==2.2.3",
        "peft==0.17.1",
        "pillow==11.1.0",
        "protobuf==5.29.3",
        "safetensors==0.5.3",
        "scipy==1.14.1",
        "sentencepiece==0.2.0",
        "tokenizers==0.21.4",
        "tqdm==4.67.1",
        "transformers==4.51.3",
    )
    .env(
        {
            "CC": "gcc",
            "CXX": "g++",
            "MAX_JOBS": "4",
            "PYTHONPATH": str(WAN_ROOT),
            "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True",
            "TORCH_CUDA_ARCH_LIST": "8.9;9.0",
        }
    )
    .pip_install("wheel==0.45.1")
    .run_commands(
        "python -m pip install --no-build-isolation "
        f"https://github.com/facebookresearch/sam2/archive/{SAM2_COMMIT}.zip"
    )
    .run_commands("python -m pip install --no-build-isolation flash-attn==2.7.4.post1")
    .run_commands(
        "python -c \"import shutil,urllib.request,zipfile;"
        f"urllib.request.urlretrieve('https://codeload.github.com/Wan-Video/Wan2.2/zip/{WAN_COMMIT}','/tmp/wan.zip');"
        "zipfile.ZipFile('/tmp/wan.zip').extractall('/tmp');"
        f"shutil.move('/tmp/Wan2.2-{WAN_COMMIT}','{WAN_ROOT}')\"",
        f"python -c \"from pathlib import Path; assert Path('{WAN_ROOT}/generate.py').is_file()\"",
    )
    .run_commands(
        "python -m pip check",
        "python -c \"import torch,torchvision,torchaudio;"
        "assert torch.__version__.split('+')[0]=='2.5.1';"
        "assert torch.version.cuda=='12.4';"
        "assert torchvision.__version__.split('+')[0]=='0.20.1';"
        "assert torchaudio.__version__.split('+')[0]=='2.5.1'\"",
        f"cd {WAN_ROOT} && python -c \"import flash_attn,librosa,sam2\"",
        f"python -m py_compile {WAN_ROOT}/generate.py "
        f"{WAN_ROOT}/wan/modules/animate/preprocess/preprocess_data.py",
        f"cd {WAN_ROOT}/wan/modules/animate/preprocess && "
        "python -c \"import process_pipepline,onnxruntime;"
        "assert 'CUDAExecutionProvider' in onnxruntime.get_available_providers()\"",
    )
    .add_local_file(
        LOCAL_MODAL_ROOT / "wan_pose_repair.py",
        str(MIMO_RUNTIME_ROOT / "wan_pose_repair.py"),
        copy=True,
    )
    .add_local_file(
        LOCAL_MODAL_ROOT / "wan_preprocess_entry.py",
        str(MIMO_PREPROCESS_ENTRY),
        copy=True,
    )
)


def _utc_now() -> str:
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).isoformat()


def _validate_job_id(job_id: str) -> str:
    if not JOB_ID_PATTERN.fullmatch(job_id):
        raise ValueError(
            "job_id must be 1-64 characters: ASCII letters, digits, '.', '_' or '-', "
            "and must start with a letter or digit"
        )
    return job_id


def _job_root(job_id: str) -> Path:
    return JOBS_ROOT / _validate_job_id(job_id)


def _read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object in {path}")
    return value


def _atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _request_for_job(job_id: str) -> dict[str, Any]:
    job_root = _job_root(job_id)
    request_path = job_root / "input" / "request.json"
    if not request_path.is_file():
        raise FileNotFoundError(f"Missing uploaded request: {request_path}")
    request = _read_json(request_path)
    if request.get("schema_version") != REQUEST_SCHEMA_VERSION:
        raise ValueError("Unsupported request schema_version")
    if request.get("job_id") != job_id:
        raise ValueError("request job_id does not match the job directory")

    frame_num = int(request.get("frame_num", DEFAULT_FRAME_NUM))
    if frame_num < 5 or (frame_num - 1) % 4 != 0:
        raise ValueError("frame_num must be 4n+1 and at least 5")
    sample_steps = int(request.get("sample_steps", DEFAULT_SAMPLE_STEPS))
    if not 1 <= sample_steps <= 100:
        raise ValueError("sample_steps must be between 1 and 100")

    area = request.get("resolution_area", [DEFAULT_WIDTH, DEFAULT_HEIGHT])
    if not (
        isinstance(area, list)
        and len(area) == 2
        and all(isinstance(value, int) for value in area)
        and all(256 <= value <= 2048 for value in area)
    ):
        raise ValueError("resolution_area must contain two integers between 256 and 2048")
    if bool(request.get("use_flux", False)):
        raise ValueError(
            "use_flux is not supported by this POC: FLUX.1-Kontext-dev is a separate "
            "checkpoint and is not part of Wan2.2-Animate-14B"
        )
    _review_contract(request)
    return request


def _review_contract(request: dict[str, Any]) -> dict[str, Any]:
    frame_num = int(request.get("frame_num", DEFAULT_FRAME_NUM))
    start = int(request.get("cycleStartFrame", DEFAULT_CYCLE_START_FRAME))
    end_exclusive = int(
        request.get("cycleEndFrameExclusive", DEFAULT_CYCLE_END_FRAME_EXCLUSIVE)
    )
    frozen_face = int(request.get("frozenFaceFrame", DEFAULT_FROZEN_FACE_FRAME))
    closure = end_exclusive
    if int(request.get("closureFrame", closure)) != closure:
        raise ValueError("closureFrame must equal cycleEndFrameExclusive")
    if not 0 <= start < end_exclusive < frame_num:
        raise ValueError(
            "cycle range must satisfy 0 <= cycleStartFrame < cycleEndFrameExclusive < frame_num"
        )
    if not 0 <= frozen_face < frame_num:
        raise ValueError("frozenFaceFrame must be inside the generated frame range")
    return {
        "cycleStartFrame": start,
        "cycleEndFrameExclusive": end_exclusive,
        "closureFrame": closure,
        "packedFrames": list(range(start, end_exclusive)),
        "reviewedPoseFrames": list(range(start, end_exclusive + 1)),
        "packedFrameCount": end_exclusive - start,
        "reviewFrameCount": end_exclusive - start + 1,
        "frozenFaceFrame": frozen_face,
    }


def _approval_matches_ready(ready: dict[str, Any], approval: dict[str, Any]) -> bool:
    ready_job = ready.get("job_id")
    approval_job = approval.get("job_id")
    preprocess_id = ready.get("preprocess_id")
    sheet_hash = ready.get("cycleContactSheetSha256")
    frozen_face = ready.get("frozenFaceFrame")
    review_range = ready.get("reviewRange")
    if not (
        ready.get("status") == "ready_for_review"
        and isinstance(ready_job, str)
        and JOB_ID_PATTERN.fullmatch(ready_job)
        and approval_job == ready_job
        and isinstance(preprocess_id, str)
        and bool(preprocess_id)
        and isinstance(sheet_hash, str)
        and SHA256_PATTERN.fullmatch(sheet_hash)
        and type(frozen_face) is int
        and isinstance(review_range, dict)
    ):
        return False

    start = review_range.get("cycleStartFrame")
    end = review_range.get("cycleEndFrameExclusive")
    closure = review_range.get("closureFrame")
    if not (
        type(start) is int
        and type(end) is int
        and type(closure) is int
        and 0 <= start < end
        and closure == end
        and review_range.get("packedFrames") == list(range(start, end))
        and review_range.get("reviewedPoseFrames") == list(range(start, end + 1))
        and review_range.get("packedFrameCount") == end - start
        and review_range.get("reviewFrameCount") == end - start + 1
    ):
        return False

    if not (
        approval.get("status") == "approved"
        and approval.get("preprocess_id") == preprocess_id
        and approval.get("reviewedCycleContactSheet") is True
        and approval.get("reviewRange") == review_range
        and approval.get("frozenFaceFrame") == frozen_face
        and approval.get("cycleContactSheetSha256") == sheet_hash
    ):
        return False

    request_hash = ready.get("requestSha256")
    input_hashes = ready.get("inferenceInputsSha256")
    if request_hash is None and input_hashes is None:
        return True
    if not (
        isinstance(request_hash, str)
        and SHA256_PATTERN.fullmatch(request_hash)
        and isinstance(input_hashes, dict)
        and all(
            isinstance(input_hashes.get(name), str)
            and SHA256_PATTERN.fullmatch(input_hashes[name])
            for name in ("src_ref.png", "src_pose.mp4", "src_face.mp4")
        )
    ):
        return False
    return bool(
        approval.get("requestSha256") == request_hash
        and approval.get("inferenceInputsSha256") == input_hashes
    )


def _approved_preprocess(job_id: str) -> tuple[Path, dict[str, Any], dict[str, Any]]:
    preprocess_root = _job_root(job_id) / "preprocess"
    ready_path = preprocess_root / "READY.json"
    metadata_path = preprocess_root / "metadata.json"
    approval_path = _job_root(job_id) / "APPROVED.json"
    if not ready_path.is_file() or not metadata_path.is_file():
        raise RuntimeError("Preprocessing is not ready")
    if not approval_path.is_file():
        raise RuntimeError(
            "Inference blocked: review cycle-contact-sheet.jpg (packed frames plus closure and "
            "frozen/dynamic face rows), then approve it with the client"
        )
    ready = _read_json(ready_path)
    metadata = _read_json(metadata_path)
    approval = _read_json(approval_path)
    if not _approval_matches_ready(ready, approval):
        raise RuntimeError(
            "Inference blocked: approval must match the exact authoritative cycle sheet, "
            "packed range, closure frame and frozen-face control"
        )
    if (
        metadata.get("status") != "ready_for_review"
        or metadata.get("job_id") != job_id
        or metadata.get("preprocess_id") != ready.get("preprocess_id")
    ):
        raise RuntimeError("Preprocess metadata does not match the approved READY marker")
    if ready.get("requestSha256") is not None and (
        metadata.get("requestSha256") != ready.get("requestSha256")
        or metadata.get("inferenceInputsSha256") != ready.get("inferenceInputsSha256")
    ):
        raise RuntimeError("Preprocess metadata does not match the approved input hashes")
    return preprocess_root, ready, metadata


def _verify_inputs(job_id: str, request: dict[str, Any]) -> tuple[Path, Path]:
    input_root = _job_root(job_id) / "input"
    character = input_root / "character.png"
    driver = input_root / "driver.mp4"
    for path in (character, driver):
        if not path.is_file() or path.stat().st_size == 0:
            raise FileNotFoundError(f"Missing or empty input: {path}")

    expected = request.get("sha256")
    if not (
        isinstance(expected, dict)
        and all(
            isinstance(expected.get(key), str)
            and SHA256_PATTERN.fullmatch(expected[key])
            for key in ("character", "driver")
        )
    ):
        raise ValueError("request.json must bind character and driver with SHA-256 digests")
    for key, path in (("character", character), ("driver", driver)):
        if _sha256(path) != expected[key]:
            raise ValueError(f"Uploaded {key} SHA-256 does not match request.json")
    return character, driver


def _require_model(stage: str) -> dict[str, Any]:
    if stage not in {"preprocess", "inference"}:
        raise ValueError(f"Unknown model stage: {stage}")
    ready_path = MODEL_ROOT / f"MIMO_{stage.upper()}_READY.json"
    if not ready_path.is_file():
        raise RuntimeError(
            f"Wan {stage} files are not ready. Run download_{stage}_model first and wait for it to finish."
        )
    manifest = _read_json(ready_path)
    if manifest.get("repository") != MODEL_REPOSITORY or manifest.get("revision") != MODEL_REVISION:
        raise RuntimeError("The cached Wan model does not match the pinned repository revision")
    return manifest


def _run_logged(command: list[str], log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line)
        return_code = process.wait()
    if return_code:
        raise RuntimeError(f"Command exited with status {return_code}; see {log_path.name}")


def _normalise_reference(source: Path, destination: Path, background: list[int]) -> None:
    from PIL import Image

    with Image.open(source) as image:
        rgba = image.convert("RGBA")
        matte = Image.new("RGBA", rgba.size, tuple(background) + (255,))
        flattened = Image.alpha_composite(matte, rgba).convert("RGB")
        destination.parent.mkdir(parents=True, exist_ok=True)
        flattened.save(destination, format="PNG", optimize=True)


def _decode_cv2_image(path: Path) -> Any:
    import cv2

    decoded = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if decoded is None:
        raise RuntimeError(f"OpenCV could not decode {path}")
    return decoded


def _trim_video_packets(source: Path, destination: Path, frame_count: int) -> None:
    try:
        import imageio_ffmpeg

        ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        ffmpeg = shutil.which("ffmpeg")
        if ffmpeg is None:
            raise RuntimeError("No ffmpeg executable is available to trim Wan controls") from None
    completed = subprocess.run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-map",
            "0:v:0",
            "-frames:v",
            str(frame_count),
            "-an",
            "-c:v",
            "copy",
            "-movflags",
            "+faststart",
            str(destination),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode or not destination.is_file() or destination.stat().st_size == 0:
        raise RuntimeError(
            f"Could not trim {source.name} to {frame_count} packets: {completed.stderr.strip()}"
        )


def _stage_inference_inputs(
    source_root: Path,
    destination_root: Path,
    *,
    frame_num: int | None = None,
) -> dict[str, Any]:
    """Copy approved controls off Volume FUSE and canonicalize the reference PNG."""

    import cv2
    import numpy as np
    from PIL import Image

    if destination_root.exists():
        raise FileExistsError(f"Inference staging destination already exists: {destination_root}")
    required = ("src_ref.png", "src_pose.mp4", "src_face.mp4")
    missing = [
        name
        for name in required
        if not (source_root / name).is_file() or (source_root / name).stat().st_size == 0
    ]
    if missing:
        raise RuntimeError(f"Approved preprocess inputs are missing or empty: {missing}")

    destination_root.mkdir(parents=True)
    source_videos: dict[str, Any] = {}
    for name in ("src_pose.mp4", "src_face.mp4"):
        source_video = source_root / name
        staged_video = destination_root / name
        source_digest = _sha256(source_video)
        shutil.copy2(source_video, staged_video)
        if _sha256(staged_video) != source_digest:
            raise RuntimeError(f"Local staging changed bytes while copying {name}")
        source_videos[name] = (
            _video_details(staged_video)
            if frame_num is not None
            else {
                "path": name,
                "bytes": staged_video.stat().st_size,
                "sha256": source_digest,
            }
        )
        if frame_num is not None:
            source_frames = int(source_videos[name]["frames"])
            if source_frames < frame_num:
                raise RuntimeError(
                    f"Approved {name} has {source_frames} frames; request requires {frame_num}"
                )
            if source_frames > frame_num:
                trimmed_video = destination_root / f"{name}.trimmed.mp4"
                _trim_video_packets(staged_video, trimmed_video, frame_num)
                os.replace(trimmed_video, staged_video)

    source_reference = source_root / "src_ref.png"
    with Image.open(source_reference) as image:
        rgb = np.asarray(image.convert("RGB"), dtype=np.uint8).copy()
    staged_temporary = destination_root / "src_ref.staging"
    staged_reference = destination_root / "src_ref.png"
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    encoded_ok, encoded = cv2.imencode(".bmp", bgr)
    if not encoded_ok:
        raise RuntimeError("OpenCV failed to encode the lossless staged reference")
    staged_temporary.write_bytes(encoded.tobytes())
    os.replace(staged_temporary, staged_reference)
    if staged_reference.read_bytes()[:2] != b"BM":
        raise RuntimeError("Staged reference does not contain the expected lossless BMP payload")
    decoded = _decode_cv2_image(staged_reference)
    if decoded.shape != bgr.shape or not np.array_equal(decoded, bgr):
        raise RuntimeError("Canonical staged reference changed pixels during BMP round-trip")

    return {
        "mode": "local-copy-and-lossless-bmp-payload-v2",
        "referencePayloadFormat": "bmp",
        "referencePathRequiredByWan": "src_ref.png",
        "sourceReferenceSha256": _sha256(source_reference),
        "stagedReferenceSha256": _sha256(staged_reference),
        "stagedReferencePixelSha256": hashlib.sha256(decoded.tobytes()).hexdigest(),
        "reference": {
            "width": int(decoded.shape[1]),
            "height": int(decoded.shape[0]),
            "channels": int(decoded.shape[2]),
        },
        "sourceVideos": source_videos,
        "sourcePoseSha256": source_videos["src_pose.mp4"]["sha256"],
        "sourceFaceSha256": source_videos["src_face.mp4"]["sha256"],
        "stagedPoseSha256": _sha256(destination_root / "src_pose.mp4"),
        "stagedFaceSha256": _sha256(destination_root / "src_face.mp4"),
    }


def _validate_staged_inference_inputs(
    staged_root: Path,
    staged: dict[str, Any],
    metadata: dict[str, Any],
    request: dict[str, Any],
) -> dict[str, Any]:
    expected_reference = metadata.get("reference", {}).get("sha256")
    expected_videos = {
        item.get("path"): item
        for item in metadata.get("videos", [])
        if isinstance(item, dict) and isinstance(item.get("path"), str)
    }
    if not isinstance(expected_reference, str) or not expected_reference:
        raise RuntimeError("Preprocess metadata is missing the reference SHA-256")
    for name in ("src_pose.mp4", "src_face.mp4"):
        if name not in expected_videos or not expected_videos[name].get("sha256"):
            raise RuntimeError(f"Preprocess metadata is missing the {name} SHA-256")

    actual_hashes = {
        "src_ref.png": staged.get("sourceReferenceSha256"),
        "src_pose.mp4": staged.get("sourcePoseSha256"),
        "src_face.mp4": staged.get("sourceFaceSha256"),
    }
    expected_hashes = {
        "src_ref.png": expected_reference,
        "src_pose.mp4": expected_videos["src_pose.mp4"]["sha256"],
        "src_face.mp4": expected_videos["src_face.mp4"]["sha256"],
    }
    if actual_hashes != expected_hashes:
        raise RuntimeError("Staged inference inputs do not match the approved preprocess hashes")

    area = request.get("resolution_area", [DEFAULT_WIDTH, DEFAULT_HEIGHT])
    expected_width, expected_height = int(area[0]), int(area[1])
    reference = staged.get("reference", {})
    if (
        reference.get("width") != expected_width
        or reference.get("height") != expected_height
        or reference.get("channels") != 3
    ):
        raise RuntimeError("Staged reference dimensions do not match the immutable request")

    source_videos = staged.get("sourceVideos", {})
    for name in ("src_pose.mp4", "src_face.mp4"):
        source_details = source_videos.get(name, {})
        expected = expected_videos[name]
        for field in ("sha256", "frames", "fps", "width", "height"):
            if source_details.get(field) != expected.get(field):
                raise RuntimeError(f"Approved source {name} {field} does not match metadata")

    videos: dict[str, Any] = {}
    exact_frames = int(request.get("frame_num", DEFAULT_FRAME_NUM))
    for name in ("src_pose.mp4", "src_face.mp4"):
        details = _video_details(staged_root / name)
        expected = expected_videos[name]
        staged_hash_key = (
            "stagedPoseSha256" if name == "src_pose.mp4" else "stagedFaceSha256"
        )
        if details["sha256"] != staged.get(staged_hash_key):
            raise RuntimeError(f"Staged {name} SHA-256 changed during validation")
        if details["frames"] != exact_frames:
            raise RuntimeError(f"Staged {name} must contain exactly {exact_frames} frames")
        if abs(float(details["fps"]) - CONTROL_FPS) > 0.01:
            raise RuntimeError(f"Staged {name} must run at exactly {CONTROL_FPS} fps")
        if name == "src_pose.mp4":
            if details["width"] != expected_width or details["height"] != expected_height:
                raise RuntimeError("Staged pose dimensions do not match the immutable request")
        elif (
            details["width"] != expected["width"]
            or details["height"] != expected["height"]
        ):
            raise RuntimeError("Staged face dimensions do not match approved preprocess metadata")
        details["decoded"] = _decode_video_sequence(staged_root / name, exact_frames)
        videos[name] = details

    return {**staged, "videos": videos, "approvedHashes": expected_hashes}


def _video_details(video_path: Path) -> dict[str, Any]:
    import cv2

    capture = cv2.VideoCapture(str(video_path))
    try:
        if not capture.isOpened():
            raise RuntimeError(f"OpenCV could not open {video_path}")
        frame_count = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = float(capture.get(cv2.CAP_PROP_FPS))
        width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    finally:
        capture.release()
    return {
        "path": video_path.name,
        "frames": frame_count,
        "fps": round(fps, 4),
        "width": width,
        "height": height,
        "duration_seconds": round(frame_count / fps, 4) if fps > 0 else None,
        "bytes": video_path.stat().st_size,
        "sha256": _sha256(video_path),
    }


def _decode_video_sequence(video_path: Path, expected_frames: int) -> dict[str, Any]:
    import cv2

    capture = cv2.VideoCapture(str(video_path))
    decoded_frames = 0
    first_shape: list[int] | None = None
    last_shape: list[int] | None = None
    try:
        if not capture.isOpened():
            raise RuntimeError(f"OpenCV could not open {video_path}")
        while True:
            ok, frame = capture.read()
            if not ok:
                break
            shape = [int(value) for value in frame.shape]
            if first_shape is None:
                first_shape = shape
            last_shape = shape
            decoded_frames += 1
    finally:
        capture.release()
    if decoded_frames != expected_frames or first_shape is None or last_shape is None:
        raise RuntimeError(
            f"{video_path.name} decoded {decoded_frames} frames; expected {expected_frames}"
        )
    if first_shape != last_shape:
        raise RuntimeError(f"{video_path.name} first/last frame dimensions differ")
    return {
        "frames": decoded_frames,
        "firstShape": first_shape,
        "lastShape": last_shape,
    }


def _inference_validation_identity(
    job_id: str,
    preprocess_root: Path,
    ready: dict[str, Any],
) -> dict[str, Any]:
    cycle_sheet = preprocess_root / "cycle-contact-sheet.jpg"
    request_path = _job_root(job_id) / "input" / "request.json"
    metadata_path = preprocess_root / "metadata.json"
    ready_path = preprocess_root / "READY.json"
    approval_path = _job_root(job_id) / "APPROVED.json"
    for path in (cycle_sheet, request_path, metadata_path, ready_path, approval_path):
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"Inference validation identity is missing {path.name}")
    sheet_hash = _sha256(cycle_sheet)
    if sheet_hash != ready.get("cycleContactSheetSha256"):
        raise RuntimeError("Authoritative cycle sheet changed after approval")
    return {
        "job_id": job_id,
        "preprocess_id": ready["preprocess_id"],
        "requestSha256": _sha256(request_path),
        "metadataSha256": _sha256(metadata_path),
        "readySha256": _sha256(ready_path),
        "approvalSha256": _sha256(approval_path),
        "cycleContactSheetSha256": sheet_hash,
        "reviewRange": ready["reviewRange"],
        "frozenFaceFrame": ready["frozenFaceFrame"],
    }


def _require_inference_validation(
    job_id: str,
    preprocess_root: Path,
    ready: dict[str, Any],
) -> dict[str, Any]:
    marker_path = preprocess_root / "INFERENCE_INPUTS_VALIDATED.json"
    if not marker_path.is_file():
        raise RuntimeError(
            "Inference blocked: run the validate-inputs CPU stage before downloading/renting GPU"
        )
    marker = _read_json(marker_path)
    identity = _inference_validation_identity(job_id, preprocess_root, ready)
    if marker.get("status") != "validated" or marker.get("identity") != identity:
        raise RuntimeError("Inference blocked: the input-validation marker is missing or stale")
    if not isinstance(marker.get("stagedInputs"), dict):
        raise RuntimeError("Inference blocked: the input-validation marker is incomplete")
    return marker


def _write_contact_sheet(videos: list[Path], destination: Path, samples: int = 8) -> None:
    import cv2
    from PIL import Image, ImageDraw

    tile_width = 240
    label_height = 26
    rows: list[list[Image.Image]] = []
    labels: list[str] = []
    for video in videos:
        capture = cv2.VideoCapture(str(video))
        if not capture.isOpened():
            capture.release()
            raise RuntimeError(f"Could not create preview for {video}")
        frame_count = max(1, int(capture.get(cv2.CAP_PROP_FRAME_COUNT)))
        indices = [round(index * (frame_count - 1) / max(1, samples - 1)) for index in range(samples)]
        row: list[Image.Image] = []
        for frame_index in indices:
            capture.set(cv2.CAP_PROP_POS_FRAMES, frame_index)
            ok, frame = capture.read()
            if not ok:
                capture.release()
                raise RuntimeError(f"Could not read frame {frame_index} from {video}")
            frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            image = Image.fromarray(frame)
            tile_height = max(1, round(image.height * tile_width / image.width))
            row.append(image.resize((tile_width, tile_height), Image.Resampling.LANCZOS))
        capture.release()
        rows.append(row)
        labels.append(video.name)

    row_height = max(tile.height for row in rows for tile in row)
    sheet = Image.new(
        "RGB",
        (tile_width * samples, (row_height + label_height) * len(rows)),
        (32, 32, 32),
    )
    draw = ImageDraw.Draw(sheet)
    for row_index, (row, label) in enumerate(zip(rows, labels)):
        y = row_index * (row_height + label_height)
        draw.text((6, y + 5), label, fill=(255, 255, 255))
        for column, tile in enumerate(row):
            sheet.paste(tile, (column * tile_width, y + label_height))
    destination.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(destination, format="JPEG", quality=90, optimize=True)


def _read_exact_frames(video_path: Path, frame_indices: list[int]) -> list[Any]:
    import cv2
    from PIL import Image

    capture = cv2.VideoCapture(str(video_path))
    if not capture.isOpened():
        capture.release()
        raise RuntimeError(f"Could not open {video_path} for exact-frame review")
    frame_count = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
    if not frame_indices or min(frame_indices) < 0 or max(frame_indices) >= frame_count:
        capture.release()
        raise ValueError(
            f"Requested frames {frame_indices[:1]}..{frame_indices[-1:]} outside "
            f"{video_path.name} frame count {frame_count}"
        )
    frames: list[Any] = []
    try:
        for frame_index in frame_indices:
            capture.set(cv2.CAP_PROP_POS_FRAMES, frame_index)
            ok, frame = capture.read()
            if not ok:
                raise RuntimeError(f"Could not read exact frame {frame_index} from {video_path}")
            frames.append(Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)))
    finally:
        capture.release()
    return frames


def _write_cycle_contact_sheet(
    *,
    pose_video: Path,
    frozen_face_video: Path,
    dynamic_face_video: Path,
    destination: Path,
    review_contract: dict[str, Any],
) -> None:
    """Write the authoritative packed-cycle + closure review artifact."""

    from PIL import Image, ImageDraw, ImageOps

    pose_indices = list(review_contract["reviewedPoseFrames"])
    start = int(review_contract["cycleStartFrame"])
    end_exclusive = int(review_contract["cycleEndFrameExclusive"])
    closure = int(review_contract["closureFrame"])
    quarter = max(1, (end_exclusive - start) // 4)
    face_indices = [start, start + quarter, start + 2 * quarter, start + 3 * quarter, closure]

    pose_frames = _read_exact_frames(pose_video, pose_indices)
    dynamic_frames = _read_exact_frames(dynamic_face_video, face_indices)
    frozen_frames = _read_exact_frames(frozen_face_video, face_indices)

    columns = 5
    tile_width = 196
    image_height = 174
    label_height = 24
    tile_height = image_height + label_height
    header_height = 48
    pose_rows = (len(pose_frames) + columns - 1) // columns
    total_rows = pose_rows + 2
    sheet = Image.new(
        "RGB",
        (columns * tile_width, header_height + total_rows * tile_height),
        (28, 28, 28),
    )
    draw = ImageDraw.Draw(sheet)
    draw.text(
        (10, 7),
        (
            f"AUTHORITATIVE CYCLE: packed [{start},{end_exclusive}) "
            f"+ closure frame {closure} | pose frames {start}..{closure} inclusive"
        ),
        fill=(255, 255, 255),
    )
    draw.text(
        (10, 26),
        f"Frozen face source frame: {review_contract['frozenFaceFrame']} | control: {CONTROL_FPS} fps",
        fill=(190, 220, 255),
    )

    def paste_tile(image: Any, row: int, column: int, label: str) -> None:
        x = column * tile_width
        y = header_height + row * tile_height
        fitted = ImageOps.contain(
            image.convert("RGB"),
            (tile_width - 8, image_height - 8),
            Image.Resampling.LANCZOS,
        )
        image_x = x + (tile_width - fitted.width) // 2
        image_y = y + 4 + (image_height - 8 - fitted.height) // 2
        sheet.paste(fitted, (image_x, image_y))
        draw.rectangle((x, y, x + tile_width - 1, y + tile_height - 1), outline=(72, 72, 72))
        draw.text((x + 6, y + image_height + 4), label, fill=(255, 255, 255))

    for offset, (frame_index, frame) in enumerate(zip(pose_indices, pose_frames)):
        suffix = " CLOSURE" if frame_index == closure else ""
        paste_tile(frame, offset // columns, offset % columns, f"POSE f{frame_index:03d}{suffix}")

    for column, (frame_index, frame) in enumerate(zip(face_indices, dynamic_frames)):
        paste_tile(frame, pose_rows, column, f"DYNAMIC FACE f{frame_index:03d}")
    for column, (frame_index, frame) in enumerate(zip(face_indices, frozen_frames)):
        paste_tile(frame, pose_rows + 1, column, f"FROZEN FACE f{frame_index:03d}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(destination, format="JPEG", quality=92, optimize=True)


def _freeze_face_control(
    *,
    dynamic_video: Path,
    frozen_video: Path,
    frozen_frame_png: Path,
    frame_index: int,
    frame_num: int,
    log_root: Path,
) -> dict[str, Any]:
    import imageio_ffmpeg

    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    _run_logged(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "warning",
            "-y",
            "-i",
            str(dynamic_video),
            "-vf",
            f"select=eq(n\\,{frame_index})",
            "-frames:v",
            "1",
            "-update",
            "1",
            str(frozen_frame_png),
        ],
        log_root / "freeze-face-extract.log",
    )
    if not frozen_frame_png.is_file() or frozen_frame_png.stat().st_size == 0:
        raise RuntimeError(f"Could not extract frozen face source frame {frame_index}")
    _run_logged(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "warning",
            "-y",
            "-loop",
            "1",
            "-framerate",
            str(CONTROL_FPS),
            "-i",
            str(frozen_frame_png),
            "-frames:v",
            str(frame_num),
            "-an",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "10",
            "-pix_fmt",
            "yuv420p",
            "-r",
            str(CONTROL_FPS),
            "-movflags",
            "+faststart",
            str(frozen_video),
        ],
        log_root / "freeze-face-video.log",
    )
    details = _video_details(frozen_video)
    if details["frames"] != frame_num or abs(float(details["fps"]) - CONTROL_FPS) > 0.01:
        raise RuntimeError(
            f"Frozen face control must be {frame_num} frames at {CONTROL_FPS} fps; got {details}"
        )
    return details


def _replace_directory(source: Path, destination: Path) -> None:
    replacement = destination.with_name(destination.name + ".incoming")
    if replacement.exists():
        shutil.rmtree(replacement)
    shutil.copytree(source, replacement)
    if destination.exists():
        shutil.rmtree(destination)
    os.replace(replacement, destination)


def _record_failure(job_id: str, stage: str, error: BaseException) -> None:
    failure = {
        "job_id": job_id,
        "stage": stage,
        "status": "failed",
        "failed_at": _utc_now(),
        "error_type": type(error).__name__,
        "error": str(error),
    }
    _atomic_write_json(_job_root(job_id) / f"FAILED-{stage}.json", failure)
    jobs_volume.commit()


@app.function(
    image=download_image,
    secrets=[modal.Secret.from_name("huggingface")],
    volumes={str(MODEL_MOUNT): model_volume},
    cpu=4,
    memory=8192,
    timeout=7200,
    retries=0,
    max_containers=1,
    scaledown_window=60,
)
def download_preprocess_model() -> dict[str, Any]:
    """Download only pose/detection checkpoints needed for the review gate."""

    from huggingface_hub import snapshot_download

    model_volume.reload()
    MODEL_ROOT.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    snapshot_download(
        repo_id=MODEL_REPOSITORY,
        revision=MODEL_REVISION,
        local_dir=str(MODEL_ROOT),
        allow_patterns=list(PREPROCESS_MODEL_ALLOW_PATTERNS),
        max_workers=8,
    )

    required = (
        MODEL_ROOT / "config.json",
        MODEL_ROOT / "process_checkpoint" / "det",
        MODEL_ROOT / "process_checkpoint" / "pose2d",
    )
    missing = [str(path.relative_to(MODEL_ROOT)) for path in required if not path.exists()]
    if missing:
        raise RuntimeError(f"Incomplete preprocess snapshot; missing={missing}")

    manifest = {
        "status": "ready",
        "stage": "preprocess",
        "repository": MODEL_REPOSITORY,
        "revision": MODEL_REVISION,
        "wan_repository": WAN_REPOSITORY,
        "wan_commit": WAN_COMMIT,
        "allow_patterns": list(PREPROCESS_MODEL_ALLOW_PATTERNS),
        "finished_at": _utc_now(),
        "elapsed_seconds": round(time.monotonic() - started, 3),
    }
    _atomic_write_json(MODEL_ROOT / "MIMO_PREPROCESS_READY.json", manifest)
    model_volume.commit()
    return manifest


@app.function(
    image=download_image,
    secrets=[modal.Secret.from_name("huggingface")],
    volumes={str(MODEL_MOUNT): model_volume, str(JOBS_MOUNT): jobs_volume},
    cpu=4,
    memory=8192,
    timeout=7200,
    retries=0,
    max_containers=1,
    scaledown_window=60,
)
def download_inference_model(job_id: str) -> dict[str, Any]:
    """Download the pinned 14B animation weights after pose review passes."""

    from huggingface_hub import snapshot_download

    _validate_job_id(job_id)
    jobs_volume.reload()
    request = _request_for_job(job_id)
    _verify_inputs(job_id, request)
    preprocess_root, ready, _ = _approved_preprocess(job_id)
    _require_inference_validation(job_id, preprocess_root, ready)
    model_volume.reload()

    MODEL_ROOT.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    snapshot_download(
        repo_id=MODEL_REPOSITORY,
        revision=MODEL_REVISION,
        local_dir=str(MODEL_ROOT),
        allow_patterns=list(INFERENCE_MODEL_ALLOW_PATTERNS),
        max_workers=8,
    )

    required = (
        MODEL_ROOT / "config.json",
        MODEL_ROOT / "Wan2.1_VAE.pth",
        MODEL_ROOT / "models_t5_umt5-xxl-enc-bf16.pth",
        MODEL_ROOT / "models_clip_open-clip-xlm-roberta-large-vit-huge-14.pth",
    )
    missing = [str(path.relative_to(MODEL_ROOT)) for path in required if not path.exists()]
    transformer_shards = list(MODEL_ROOT.glob("diffusion_pytorch_model-*.safetensors"))
    if missing or not transformer_shards:
        raise RuntimeError(
            f"Incomplete inference snapshot; missing={missing}, shards={len(transformer_shards)}"
        )

    manifest = {
        "status": "ready",
        "stage": "inference",
        "unlocked_by_job": job_id,
        "unlocked_by_preprocess_id": ready["preprocess_id"],
        "reviewRange": ready["reviewRange"],
        "frozenFaceFrame": ready["frozenFaceFrame"],
        "repository": MODEL_REPOSITORY,
        "revision": MODEL_REVISION,
        "wan_repository": WAN_REPOSITORY,
        "wan_commit": WAN_COMMIT,
        "allow_patterns": list(INFERENCE_MODEL_ALLOW_PATTERNS),
        "transformer_shards": len(transformer_shards),
        "finished_at": _utc_now(),
        "elapsed_seconds": round(time.monotonic() - started, 3),
    }
    _atomic_write_json(MODEL_ROOT / "MIMO_INFERENCE_READY.json", manifest)
    model_volume.commit()
    return manifest


@app.function(
    image=wan_image,
    gpu="L4",
    volumes={str(MODEL_MOUNT): model_volume, str(JOBS_MOUNT): jobs_volume},
    cpu=8,
    memory=16384,
    timeout=900,
    retries=0,
    max_containers=1,
    scaledown_window=60,
)
def preprocess(job_id: str) -> dict[str, Any]:
    """Extract pose/face controls; result must be reviewed before inference."""

    _validate_job_id(job_id)
    model_volume.reload()
    jobs_volume.reload()
    _require_model("preprocess")
    request = _request_for_job(job_id)
    review_contract = _review_contract(request)
    character, driver = _verify_inputs(job_id, request)
    preprocess_id = uuid.uuid4().hex
    started = time.monotonic()

    try:
        with tempfile.TemporaryDirectory(prefix=f"mimo-wan-pre-{job_id}-") as temporary:
            work_root = Path(temporary)
            normalised_reference = work_root / "character.png"
            process_root = work_root / "process"
            background = request.get("neutral_background", [127, 127, 127])
            if not (
                isinstance(background, list)
                and len(background) == 3
                and all(isinstance(value, int) and 0 <= value <= 255 for value in background)
            ):
                raise ValueError("neutral_background must contain three integers from 0 to 255")
            _normalise_reference(character, normalised_reference, background)

            width, height = request.get("resolution_area", [DEFAULT_WIDTH, DEFAULT_HEIGHT])
            command = [
                sys.executable,
                str(MIMO_PREPROCESS_ENTRY),
                "--ckpt_path",
                str(MODEL_ROOT / "process_checkpoint"),
                "--video_path",
                str(driver),
                "--refer_path",
                str(normalised_reference),
                "--save_path",
                str(process_root),
                "--resolution_area",
                str(width),
                str(height),
            ]
            if bool(request.get("retarget", False)):
                command.append("--retarget_flag")
            _run_logged(command, work_root / "preprocess.log")

            expected = [
                process_root / "src_ref.png",
                process_root / "src_pose.mp4",
                process_root / "src_face.mp4",
                process_root / "pose-repair.json",
            ]
            missing = [path.name for path in expected if not path.is_file() or path.stat().st_size == 0]
            if missing:
                raise RuntimeError(f"Wan preprocessing did not produce: {', '.join(missing)}")
            pose_repair = _read_json(process_root / "pose-repair.json")
            pose_repair_runs = pose_repair.get("runs")
            expected_frame_count = int(request.get("frame_num", DEFAULT_FRAME_NUM))
            if (
                pose_repair.get("status") != "applied"
                or not isinstance(pose_repair_runs, list)
                or len(pose_repair_runs) != 1
                or pose_repair_runs[0].get("frameCount") != expected_frame_count
            ):
                raise RuntimeError("Pose repair report does not match the requested frame sequence")

            dynamic_face = process_root / "src_face-dynamic.mp4"
            frozen_face = process_root / "src_face.mp4"
            frozen_face_frame = process_root / "frozen-face-frame.png"
            os.replace(frozen_face, dynamic_face)
            frozen_face_details = _freeze_face_control(
                dynamic_video=dynamic_face,
                frozen_video=frozen_face,
                frozen_frame_png=frozen_face_frame,
                frame_index=int(review_contract["frozenFaceFrame"]),
                frame_num=int(request.get("frame_num", DEFAULT_FRAME_NUM)),
                log_root=work_root,
            )
            review_range = {
                key: review_contract[key]
                for key in (
                    "cycleStartFrame",
                    "cycleEndFrameExclusive",
                    "closureFrame",
                    "packedFrames",
                    "reviewedPoseFrames",
                    "packedFrameCount",
                    "reviewFrameCount",
                )
            }
            cycle_sheet = process_root / "cycle-contact-sheet.jpg"
            _write_cycle_contact_sheet(
                pose_video=process_root / "src_pose.mp4",
                frozen_face_video=frozen_face,
                dynamic_face_video=dynamic_face,
                destination=cycle_sheet,
                review_contract=review_contract,
            )
            _write_contact_sheet(
                [process_root / "src_pose.mp4", frozen_face, dynamic_face],
                process_root / "overview-contact-sheet.jpg",
            )
            for log_name in (
                "preprocess.log",
                "freeze-face-extract.log",
                "freeze-face-video.log",
            ):
                shutil.copy2(work_root / log_name, process_root / log_name)
            elapsed = time.monotonic() - started
            request_sha256 = _sha256(_job_root(job_id) / "input" / "request.json")
            inference_input_hashes = {
                "src_ref.png": _sha256(process_root / "src_ref.png"),
                "src_pose.mp4": _sha256(process_root / "src_pose.mp4"),
                "src_face.mp4": _sha256(frozen_face),
            }
            metadata = {
                "status": "ready_for_review",
                "job_id": job_id,
                "preprocess_id": preprocess_id,
                "created_at": _utc_now(),
                "elapsed_seconds": round(elapsed, 3),
                "estimated_modal_compute_usd": round(elapsed * L4_TOTAL_USD_PER_SECOND, 4),
                "pricing_snapshot": {
                    "date": "2026-07",
                    "gpu": {"type": "L4", "count": 1, "usd_per_second": L4_GPU_USD_PER_SECOND},
                    "cpu": {
                        "cores": L4_CPU_CORES,
                        "usd_per_core_second": CPU_CORE_USD_PER_SECOND,
                    },
                    "memory": {
                        "gib": L4_MEMORY_GIB,
                        "usd_per_gib_second": MEMORY_GIB_USD_PER_SECOND,
                    },
                    "total_usd_per_second": L4_TOTAL_USD_PER_SECOND,
                    "note": "Elapsed-time estimate; image build and container startup may bill separately.",
                },
                "request": request,
                "requestSha256": request_sha256,
                "inferenceInputsSha256": inference_input_hashes,
                "reference": {
                    "sha256": inference_input_hashes["src_ref.png"],
                    "bytes": (process_root / "src_ref.png").stat().st_size,
                },
                "videos": [
                    _video_details(process_root / "src_pose.mp4"),
                    frozen_face_details,
                    _video_details(dynamic_face),
                ],
                "reviewRange": review_range,
                "frozenFaceFrame": review_contract["frozenFaceFrame"],
                "faceControl": {
                    "mode": "frozen",
                    "fps": CONTROL_FPS,
                    "frameCount": int(request.get("frame_num", DEFAULT_FRAME_NUM)),
                    "frozenArtifact": "src_face.mp4",
                    "dynamicArtifact": "src_face-dynamic.mp4",
                    "sourceFrameArtifact": "frozen-face-frame.png",
                },
                "poseRepair": pose_repair,
                "review": {
                    "required": True,
                    "authoritativeArtifact": "cycle-contact-sheet.jpg",
                    "authoritativeArtifactSha256": _sha256(cycle_sheet),
                    "overviewArtifact": "overview-contact-sheet.jpg",
                    "instruction": (
                        "Review every pose frame in cycle-contact-sheet.jpg: packed frames "
                        f"[{review_contract['cycleStartFrame']},{review_contract['cycleEndFrameExclusive']}) "
                        f"plus closure frame {review_contract['closureFrame']}. Compare the frozen and "
                        "dynamic face rows before approval."
                    ),
                },
                "wan_commit": WAN_COMMIT,
                "model_revision": MODEL_REVISION,
            }
            _atomic_write_json(process_root / "metadata.json", metadata)
            _atomic_write_json(
                process_root / "READY.json",
                {
                    "status": "ready_for_review",
                    "job_id": job_id,
                    "preprocess_id": preprocess_id,
                    "created_at": metadata["created_at"],
                    "authoritativePreview": "cycle-contact-sheet.jpg",
                    "cycleContactSheetSha256": metadata["review"][
                        "authoritativeArtifactSha256"
                    ],
                    "reviewRange": review_range,
                    "frozenFaceFrame": review_contract["frozenFaceFrame"],
                    "requestSha256": request_sha256,
                    "inferenceInputsSha256": inference_input_hashes,
                },
            )
            _replace_directory(process_root, _job_root(job_id) / "preprocess")

        approval_path = _job_root(job_id) / "APPROVED.json"
        if approval_path.exists():
            approval_path.unlink()
        output_path = _job_root(job_id) / "output"
        if output_path.exists():
            shutil.rmtree(output_path)
        failed_path = _job_root(job_id) / "FAILED-preprocess.json"
        if failed_path.exists():
            failed_path.unlink()
        jobs_volume.commit()
        return {
            "status": "ready_for_review",
            "job_id": job_id,
            "preprocess_id": preprocess_id,
            "elapsed_seconds": metadata["elapsed_seconds"],
            "estimated_modal_compute_usd": metadata["estimated_modal_compute_usd"],
            "reviewRange": metadata["reviewRange"],
            "frozenFaceFrame": metadata["frozenFaceFrame"],
            "artifacts": [
                f"jobs/{job_id}/preprocess/cycle-contact-sheet.jpg",
                f"jobs/{job_id}/preprocess/overview-contact-sheet.jpg",
                f"jobs/{job_id}/preprocess/src_pose.mp4",
                f"jobs/{job_id}/preprocess/src_face.mp4",
                f"jobs/{job_id}/preprocess/src_face-dynamic.mp4",
                f"jobs/{job_id}/preprocess/frozen-face-frame.png",
                f"jobs/{job_id}/preprocess/pose-repair.json",
            ],
        }
    except Exception as error:
        _record_failure(job_id, "preprocess", error)
        raise


@app.function(
    image=wan_image,
    volumes={str(JOBS_MOUNT): jobs_volume},
    cpu=2,
    memory=4096,
    timeout=120,
    retries=0,
    max_containers=1,
    scaledown_window=10,
)
def validate_inference_inputs(job_id: str) -> dict[str, Any]:
    """Exercise the exact local staging/decoding gate without renting a GPU."""

    _validate_job_id(job_id)
    jobs_volume.reload()
    request = _request_for_job(job_id)
    _verify_inputs(job_id, request)
    preprocess_root, ready, metadata = _approved_preprocess(job_id)
    frame_num = int(request.get("frame_num", DEFAULT_FRAME_NUM))
    with tempfile.TemporaryDirectory(prefix=f"mimo-wan-validate-{job_id}-") as temporary:
        staged_root = Path(temporary) / "source"
        staged = _stage_inference_inputs(
            preprocess_root,
            staged_root,
            frame_num=frame_num,
        )
        validated = _validate_staged_inference_inputs(
            staged_root,
            staged,
            metadata,
            request,
        )
    marker = {
        "status": "validated",
        "job_id": job_id,
        "preprocess_id": ready["preprocess_id"],
        "validated_at": _utc_now(),
        "identity": _inference_validation_identity(job_id, preprocess_root, ready),
        "stagedInputs": validated,
    }
    _atomic_write_json(preprocess_root / "INFERENCE_INPUTS_VALIDATED.json", marker)
    jobs_volume.commit()
    return marker


@app.function(
    image=wan_image,
    gpu="H200",
    volumes={str(MODEL_MOUNT): model_volume, str(JOBS_MOUNT): jobs_volume},
    cpu=8,
    memory=98304,
    timeout=1800,
    retries=0,
    max_containers=1,
    scaledown_window=60,
)
def infer(job_id: str, seed: int | None = None) -> dict[str, Any]:
    """Run official Wan inference after a matching human approval marker exists."""

    _validate_job_id(job_id)
    jobs_volume.reload()
    request = _request_for_job(job_id)
    _verify_inputs(job_id, request)
    preprocess_root, ready, metadata = _approved_preprocess(job_id)
    validation_marker = _require_inference_validation(job_id, preprocess_root, ready)
    model_volume.reload()
    _require_model("inference")

    effective_seed = int(request.get("seed", DEFAULT_SEED) if seed is None else seed)
    frame_num = int(request.get("frame_num", DEFAULT_FRAME_NUM))
    sample_steps = int(request.get("sample_steps", DEFAULT_SAMPLE_STEPS))
    started = time.monotonic()

    try:
        with tempfile.TemporaryDirectory(prefix=f"mimo-wan-infer-{job_id}-") as temporary:
            work_root = Path(temporary)
            staged_source_root = work_root / "source"
            staged_inputs = _stage_inference_inputs(
                preprocess_root,
                staged_source_root,
                frame_num=frame_num,
            )
            staged_inputs = _validate_staged_inference_inputs(
                staged_source_root,
                staged_inputs,
                metadata,
                request,
            )
            if staged_inputs != validation_marker["stagedInputs"]:
                raise RuntimeError("H200 staging does not match the CPU-validated inference inputs")
            raw_video = work_root / "wan-raw.mp4"
            command = [
                sys.executable,
                str(WAN_ROOT / "generate.py"),
                "--task",
                "animate-14B",
                "--ckpt_dir",
                str(MODEL_ROOT),
                "--src_root_path",
                str(staged_source_root),
                "--refert_num",
                "1",
                "--frame_num",
                str(frame_num),
                "--sample_steps",
                str(sample_steps),
                "--base_seed",
                str(effective_seed),
                "--offload_model",
                "True",
                "--convert_model_dtype",
                "--save_file",
                str(raw_video),
            ]
            _run_logged(command, work_root / "inference.log")
            if not raw_video.is_file() or raw_video.stat().st_size == 0:
                raise RuntimeError("Wan inference completed without a non-empty wan-raw.mp4")

            elapsed = time.monotonic() - started
            run = {
                "status": "done",
                "job_id": job_id,
                "preprocess_id": ready["preprocess_id"],
                "finished_at": _utc_now(),
                "elapsed_seconds": round(elapsed, 3),
                "estimated_h200_gpu_usd": round(elapsed * H200_GPU_USD_PER_SECOND, 4),
                "estimated_modal_compute_usd": round(elapsed * H200_TOTAL_USD_PER_SECOND, 4),
                "pricing_snapshot": {
                    "date": "2026-07",
                    "gpu": {
                        "type": "H200",
                        "count": 1,
                        "usd_per_second": H200_GPU_USD_PER_SECOND,
                    },
                    "cpu": {
                        "cores": H200_CPU_CORES,
                        "usd_per_core_second": CPU_CORE_USD_PER_SECOND,
                    },
                    "memory": {
                        "gib": H200_MEMORY_GIB,
                        "usd_per_gib_second": MEMORY_GIB_USD_PER_SECOND,
                    },
                    "total_usd_per_second": H200_TOTAL_USD_PER_SECOND,
                    "timeout_seconds": 1800,
                    "timeout_compute_cap_usd": round(1800 * H200_TOTAL_USD_PER_SECOND, 4),
                    "volume": {
                        "usd_per_gib_month": VOLUME_STORAGE_USD_PER_GIB_MONTH,
                        "free_tier_gib_month": VOLUME_FREE_TIER_GIB_MONTH,
                        "included_in_estimate": False,
                    },
                    "note": (
                        "Elapsed-time list-price estimate; image build/container startup and volume "
                        "usage above the free tier are not included."
                    ),
                },
                "seed": effective_seed,
                "frame_num": frame_num,
                "sample_steps": sample_steps,
                "reviewRange": ready["reviewRange"],
                "frozenFaceFrame": ready["frozenFaceFrame"],
                "cycleContactSheetSha256": ready["cycleContactSheetSha256"],
                "stagedInputs": staged_inputs,
                "output": _video_details(raw_video),
                "wan_repository": WAN_REPOSITORY,
                "wan_commit": WAN_COMMIT,
                "model_repository": MODEL_REPOSITORY,
                "model_revision": MODEL_REVISION,
            }
            _atomic_write_json(work_root / "run.json", run)
            _atomic_write_json(
                work_root / "DONE.json",
                {
                    "status": "done",
                    "job_id": job_id,
                    "preprocess_id": ready["preprocess_id"],
                    "finished_at": run["finished_at"],
                },
            )
            shutil.copy2(work_root / "inference.log", work_root / "wan-inference.log")
            shutil.rmtree(staged_source_root)
            _replace_directory(work_root, _job_root(job_id) / "output")

        failed_path = _job_root(job_id) / "FAILED-infer.json"
        if failed_path.exists():
            failed_path.unlink()
        jobs_volume.commit()
        return {
            "status": "done",
            "job_id": job_id,
            "artifact": f"jobs/{job_id}/output/wan-raw.mp4",
            "elapsed_seconds": run["elapsed_seconds"],
            "estimated_h200_gpu_usd": run["estimated_h200_gpu_usd"],
            "estimated_modal_compute_usd": run["estimated_modal_compute_usd"],
        }
    except Exception as error:
        _record_failure(job_id, "infer", error)
        raise


@app.function(
    image=download_image,
    volumes={str(MODEL_MOUNT): model_volume, str(JOBS_MOUNT): jobs_volume},
    cpu=1,
    memory=1024,
    timeout=120,
    retries=0,
    max_containers=1,
    scaledown_window=10,
)
def preflight(job_id: str | None = None) -> dict[str, Any]:
    """Read-only remote state check; this function never requests a GPU."""

    model_volume.reload()
    jobs_volume.reload()
    state: dict[str, Any] = {
        "app": APP_NAME,
        "preprocess_model_ready": (MODEL_ROOT / "MIMO_PREPROCESS_READY.json").is_file(),
        "inference_model_ready": (MODEL_ROOT / "MIMO_INFERENCE_READY.json").is_file(),
        "model_revision": MODEL_REVISION,
        "wan_commit": WAN_COMMIT,
    }
    if job_id is None:
        state["next"] = (
            "download_preprocess_model" if not state["preprocess_model_ready"] else "upload"
        )
        return state

    root = _job_root(job_id)
    ready_path = root / "preprocess" / "READY.json"
    approval_path = root / "APPROVED.json"
    validation_path = root / "preprocess" / "INFERENCE_INPUTS_VALIDATED.json"
    done_path = root / "output" / "DONE.json"
    approval_valid = False
    validation_valid = False
    if ready_path.is_file() and approval_path.is_file():
        ready = _read_json(ready_path)
        approval = _read_json(approval_path)
        approval_valid = _approval_matches_ready(ready, approval)
        if approval_valid and validation_path.is_file():
            try:
                _require_inference_validation(job_id, root / "preprocess", ready)
                validation_valid = True
            except RuntimeError:
                validation_valid = False
    state.update(
        {
            "job_id": job_id,
            "input_ready": all(
                (root / "input" / name).is_file()
                for name in ("character.png", "driver.mp4", "request.json")
            ),
            "preprocess_ready": ready_path.is_file(),
            "approval_present": approval_path.is_file(),
            "approved": approval_valid,
            "inputs_validated": validation_valid,
            "done": done_path.is_file(),
        }
    )
    if done_path.is_file():
        state["next"] = "download_output"
    elif state["approved"] and not state["inputs_validated"]:
        state["next"] = "validate_inference_inputs"
    elif state["inputs_validated"] and not state["inference_model_ready"]:
        state["next"] = "download_inference_model"
    elif state["inputs_validated"]:
        state["next"] = "infer"
    elif ready_path.is_file():
        state["next"] = "download_and_review_cycle_sheet"
    elif state["input_ready"]:
        state["next"] = "preprocess"
    elif not state["preprocess_model_ready"]:
        state["next"] = "download_preprocess_model"
    else:
        state["next"] = "upload"
    return state
