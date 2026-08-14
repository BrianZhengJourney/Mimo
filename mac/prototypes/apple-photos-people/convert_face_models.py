#!/usr/bin/env python3
"""THROWAWAY PROTOTYPE: convert local face embedders to Core ML.

Question: can a dedicated, fully local face embedding model collapse the many
Vision feature-print fragments into the few real people in the same Photos
sample, without unacceptable conversion error or latency?

The script intentionally writes only to an explicit output directory. Model
weights are research-only inputs supplied by the caller and are never copied
into the repository.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

import coremltools as ct
import numpy as np
from PIL import Image
import torch
from torch import nn


class FaceEmbedder(nn.Module):
    """Portable inference surface: normalized RGB face -> raw embedding.

    L2 normalization stays outside Core ML in Float32. The raw norm remains
    available as AdaFace's useful proxy for input quality.
    """

    def __init__(self, backbone: nn.Module) -> None:
        super().__init__()
        self.backbone = backbone

    def forward(
        self, face: torch.Tensor, keypoints: torch.Tensor | None = None
    ) -> torch.Tensor:
        if keypoints is None:
            return self.backbone(face)
        return self.backbone(face, keypoints)


def load_adaface_ir101(model_dir: Path) -> FaceEmbedder:
    implementation = model_dir / "models/iresnet/model.py"
    checkpoint = model_dir / "pretrained_model/model.pt"
    if not implementation.is_file() or not checkpoint.is_file():
        raise FileNotFoundError(
            "AdaFace IR101 snapshot is incomplete; expected model.py and model.pt"
        )

    spec = importlib.util.spec_from_file_location("mimo_adaface_iresnet", implementation)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load model implementation: {implementation}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    backbone = module.IR_101((112, 112)).eval()
    raw = torch.load(checkpoint, map_location="cpu", weights_only=False)
    state = {key.removeprefix("net."): value for key, value in raw.items()}
    backbone.load_state_dict(state, strict=True)
    return FaceEmbedder(backbone).eval()


def load_adaface_kprpe(model_dir: Path) -> FaceEmbedder:
    """Load the author model while forcing its portable PyTorch RPE fallback."""

    checkpoint = model_dir / "pretrained_model/model.pt"
    config_path = model_dir / "config.json"
    if not checkpoint.is_file() or not config_path.is_file():
        raise FileNotFoundError(
            "KP-RPE snapshot is incomplete; expected config.json and model.pt"
        )

    # The upstream package tries to compile a training-only C++ indexing op at
    # import time. Core ML needs the mathematically equivalent pure-Torch path.
    from omegaconf import OmegaConf

    config = OmegaConf.create(json.loads(config_path.read_text())["conf"])
    original_check_call = subprocess.check_call
    original_cwd = Path.cwd()

    def refuse_extension(*args, **kwargs):
        raise subprocess.CalledProcessError(1, args[0] if args else "rpe_ops")

    subprocess.check_call = refuse_extension
    sys.path.insert(0, str(model_dir))
    try:
        from models import get_model
        model = get_model(config).eval()
    finally:
        subprocess.check_call = original_check_call
        os.chdir(original_cwd)

    raw = torch.load(checkpoint, map_location="cpu", weights_only=False)
    model.load_state_dict(raw, strict=True)
    return FaceEmbedder(model).eval()


def convert_ir101(model_dir: Path, output_dir: Path) -> Path:
    model = load_adaface_ir101(model_dir)
    example = torch.zeros(1, 3, 112, 112, dtype=torch.float32)
    with torch.inference_mode():
        traced = torch.jit.trace(model, example)
        traced(example)

    package = output_dir / "MimoAdaFaceIR101.mlpackage"
    if package.exists():
        shutil.rmtree(package)

    started = time.perf_counter()
    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.ImageType(
                name="face",
                shape=example.shape,
                color_layout=ct.colorlayout.RGB,
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
    )
    converted.author = "Mimo research prototype; AdaFace/CVLFace authors"
    converted.license = "Research evaluation only; verify weight/data rights before shipping"
    converted.short_description = "112x112 aligned RGB face to raw identity embedding"
    converted.save(str(package))
    print(f"converted={package}")
    print(f"conversion_seconds={time.perf_counter() - started:.2f}")
    return package


def convert_kprpe(model_dir: Path, output_dir: Path) -> Path:
    model = load_adaface_kprpe(model_dir)
    face = torch.zeros(1, 3, 112, 112, dtype=torch.float32)
    keypoints = torch.tensor(
        [[[0.32, 0.38], [0.68, 0.38], [0.50, 0.56], [0.37, 0.73], [0.63, 0.73]]],
        dtype=torch.float32,
    )
    with torch.inference_mode():
        # Populate the upstream model's static 14x14 RPE index cache first so
        # tracing captures one stable graph instead of cache construction.
        model(face, keypoints)
        traced = torch.jit.trace(
            model, (face, keypoints), strict=False, check_trace=False
        )
        traced(face, keypoints)

    package = output_dir / "MimoAdaFaceKPRPE.mlpackage"
    if package.exists():
        shutil.rmtree(package)

    started = time.perf_counter()
    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.ImageType(
                name="face",
                shape=face.shape,
                color_layout=ct.colorlayout.RGB,
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
            ),
            ct.TensorType(name="keypoints", shape=keypoints.shape, dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="embedding")],
    )
    converted.author = "Mimo research prototype; KP-RPE/CVLFace authors"
    converted.license = "Research evaluation only; verify weight/data rights before shipping"
    converted.short_description = "112x112 RGB face plus five landmarks to raw identity embedding"
    converted.save(str(package))
    print(f"converted={package}")
    print(f"conversion_seconds={time.perf_counter() - started:.2f}")
    return package


def validate_ir101(model_dir: Path, package: Path) -> None:
    torch_model = load_adaface_ir101(model_dir)
    rng = np.random.default_rng(20260811)
    pixels = rng.integers(0, 256, size=(8, 112, 112, 3), dtype=np.uint8)
    tensor = torch.from_numpy(pixels.copy()).permute(0, 3, 1, 2).contiguous().float()
    tensor = tensor / 127.5 - 1.0

    with torch.inference_mode():
        expected = torch_model(tensor).numpy()

    model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.ALL)
    actual_rows: list[np.ndarray] = []
    timings: list[float] = []
    for row in pixels:
        started = time.perf_counter()
        prediction = model.predict({"face": Image.fromarray(row, mode="RGB")})
        timings.append(time.perf_counter() - started)
        actual_rows.append(np.asarray(prediction["embedding"]).reshape(-1))
    actual = np.stack(actual_rows)

    expected_unit = expected / np.linalg.norm(expected, axis=1, keepdims=True)
    actual_unit = actual / np.linalg.norm(actual, axis=1, keepdims=True)
    vector_cosines = np.sum(expected_unit * actual_unit, axis=1)
    expected_pairs = expected_unit @ expected_unit.T
    actual_pairs = actual_unit @ actual_unit.T
    pairwise_max_abs = float(np.max(np.abs(expected_pairs - actual_pairs)))

    print(f"validation_vector_cosine_min={np.min(vector_cosines):.8f}")
    print(f"validation_pairwise_max_abs={pairwise_max_abs:.8f}")
    print(f"cold_prediction_ms={timings[0] * 1000:.2f}")
    print(f"warm_prediction_median_ms={np.median(timings[1:]) * 1000:.2f}")
    if np.min(vector_cosines) < 0.99 or pairwise_max_abs > 0.02:
        raise RuntimeError("Core ML conversion changes identity similarities too much")


def validate_kprpe(model_dir: Path, package: Path) -> None:
    torch_model = load_adaface_kprpe(model_dir)
    rng = np.random.default_rng(20260811)
    pixels = rng.integers(0, 256, size=(4, 112, 112, 3), dtype=np.uint8)
    keypoints = np.array(
        [[[0.32, 0.38], [0.68, 0.38], [0.50, 0.56], [0.37, 0.73], [0.63, 0.73]]],
        dtype=np.float32,
    )
    tensor = torch.from_numpy(pixels.copy()).permute(0, 3, 1, 2).contiguous().float()
    tensor = tensor / 127.5 - 1.0
    repeated_keypoints = torch.from_numpy(np.repeat(keypoints, len(pixels), axis=0))
    with torch.inference_mode():
        expected = torch_model(tensor, repeated_keypoints).numpy()

    model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.ALL)
    actual_rows: list[np.ndarray] = []
    timings: list[float] = []
    for row in pixels:
        started = time.perf_counter()
        prediction = model.predict(
            {"face": Image.fromarray(row, mode="RGB"), "keypoints": keypoints}
        )
        timings.append(time.perf_counter() - started)
        actual_rows.append(np.asarray(prediction["embedding"]).reshape(-1))
    actual = np.stack(actual_rows)

    expected_unit = expected / np.linalg.norm(expected, axis=1, keepdims=True)
    actual_unit = actual / np.linalg.norm(actual, axis=1, keepdims=True)
    vector_cosines = np.sum(expected_unit * actual_unit, axis=1)
    pairwise_max_abs = float(
        np.max(np.abs(expected_unit @ expected_unit.T - actual_unit @ actual_unit.T))
    )
    print(f"validation_vector_cosine_min={np.min(vector_cosines):.8f}")
    print(f"validation_pairwise_max_abs={pairwise_max_abs:.8f}")
    print(f"cold_prediction_ms={timings[0] * 1000:.2f}")
    print(f"warm_prediction_median_ms={np.median(timings[1:]) * 1000:.2f}")
    if np.min(vector_cosines) < 0.99 or pairwise_max_abs > 0.05:
        raise RuntimeError("Core ML conversion changes KP-RPE similarities too much")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=["ir101", "kprpe"], default="ir101")
    parser.add_argument("--ir101-dir", type=Path)
    parser.add_argument("--kprpe-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--validate-only", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.model == "ir101":
        if args.ir101_dir is None:
            raise ValueError("--ir101-dir is required for --model ir101")
        source = args.ir101_dir.resolve()
        package = args.output_dir.resolve() / "MimoAdaFaceIR101.mlpackage"
        if not args.validate_only:
            package = convert_ir101(source, args.output_dir.resolve())
        elif not package.exists():
            raise FileNotFoundError(package)
        validate_ir101(source, package)
    else:
        if args.kprpe_dir is None:
            raise ValueError("--kprpe-dir is required for --model kprpe")
        source = args.kprpe_dir.resolve()
        package = args.output_dir.resolve() / "MimoAdaFaceKPRPE.mlpackage"
        if not args.validate_only:
            package = convert_kprpe(source, args.output_dir.resolve())
        elif not package.exists():
            raise FileNotFoundError(package)
        validate_kprpe(source, package)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
