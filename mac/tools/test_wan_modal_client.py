from __future__ import annotations

import argparse
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parent))
import wan_modal_client as client  # noqa: E402


class FakeUploadBatch:
    def __init__(self, uploads: list[tuple[object, str]], force: bool):
        self.uploads = uploads
        self.force = force

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def put_file(self, source, destination):
        self.uploads.append((source, destination))


class FakeVolume:
    def __init__(self, files: dict[str, bytes] | None = None):
        self.files = files or {}
        self.uploads: list[tuple[object, str]] = []

    def batch_upload(self, force=False):
        return FakeUploadBatch(self.uploads, force)

    def read_file(self, path):
        yield self.files[path]


class WanModalClientTests(unittest.TestCase):
    def test_job_id_rejects_path_traversal(self):
        for value in ("../escape", "/absolute", "has space", "", "a" * 65):
            with self.subTest(value=value), self.assertRaises(ValueError):
                client.validate_job_id(value)
        self.assertEqual(client.validate_job_id("walk-side.v1_02"), "walk-side.v1_02")

    def test_request_requires_wan_temporal_shape(self):
        with tempfile.TemporaryDirectory() as temporary:
            character = Path(temporary) / "character.png"
            driver = Path(temporary) / "driver.mp4"
            character.write_bytes(b"png")
            driver.write_bytes(b"mp4")
            with self.assertRaisesRegex(ValueError, "4n\\+1"):
                client.build_request(
                    job_id="walk-v1",
                    character=character,
                    driver=driver,
                    width=512,
                    height=512,
                    frame_num=76,
                    sample_steps=20,
                    seed=42,
                    retarget=False,
                    neutral_background=[127, 127, 127],
                    cycle_start_frame=24,
                    cycle_end_frame_exclusive=48,
                    frozen_face_frame=24,
                )

    def test_request_contains_pins_and_digests(self):
        with tempfile.TemporaryDirectory() as temporary:
            character = Path(temporary) / "character.png"
            driver = Path(temporary) / "driver.mp4"
            character.write_bytes(b"character")
            driver.write_bytes(b"driver")
            request = client.build_request(
                job_id="walk-v1",
                character=character,
                driver=driver,
                width=512,
                height=512,
                frame_num=77,
                sample_steps=20,
                seed=42,
                retarget=False,
                neutral_background=[127, 127, 127],
                cycle_start_frame=24,
                cycle_end_frame_exclusive=48,
                frozen_face_frame=24,
            )
        self.assertEqual(request["provenance"]["wan_commit"], client.WAN_COMMIT)
        self.assertEqual(request["provenance"]["model_revision"], client.MODEL_REVISION)
        self.assertEqual(len(request["sha256"]["character"]), 64)
        self.assertFalse(request["use_flux"])
        self.assertEqual(request["cycleStartFrame"], 24)
        self.assertEqual(request["cycleEndFrameExclusive"], 48)
        self.assertEqual(request["closureFrame"], 48)
        self.assertEqual(request["frozenFaceFrame"], 24)

    def test_cli_defaults_are_square_and_bind_cycle_plus_closure(self):
        args = client.build_parser().parse_args(
            [
                "upload",
                "--job-id",
                "walk-v1",
                "--character",
                "character.png",
                "--driver",
                "driver.mp4",
            ]
        )
        self.assertEqual((args.width, args.height), (512, 512))
        self.assertEqual(args.cycle_start_frame, 24)
        self.assertEqual(args.cycle_end_frame_exclusive, 48)
        self.assertEqual(args.frozen_face_frame, 24)

    def test_request_rejects_closure_outside_generated_frames(self):
        with tempfile.TemporaryDirectory() as temporary:
            character = Path(temporary) / "character.png"
            driver = Path(temporary) / "driver.mp4"
            character.write_bytes(b"character")
            driver.write_bytes(b"driver")
            with self.assertRaisesRegex(ValueError, "cycle frames"):
                client.build_request(
                    job_id="walk-v1",
                    character=character,
                    driver=driver,
                    width=512,
                    height=512,
                    frame_num=49,
                    sample_steps=20,
                    seed=42,
                    retarget=False,
                    neutral_background=[127, 127, 127],
                    cycle_start_frame=24,
                    cycle_end_frame_exclusive=49,
                    frozen_face_frame=24,
                )

    def test_upload_dry_run_never_imports_modal(self):
        with tempfile.TemporaryDirectory() as temporary:
            character = Path(temporary) / "character.png"
            driver = Path(temporary) / "driver.mp4"
            character.write_bytes(b"character")
            driver.write_bytes(b"driver")
            args = argparse.Namespace(
                character=str(character),
                driver=str(driver),
                job_id="walk-v1",
                width=512,
                height=512,
                frame_num=77,
                sample_steps=20,
                seed=42,
                retarget=False,
                neutral_background=[127, 127, 127],
                cycle_start_frame=24,
                cycle_end_frame_exclusive=48,
                frozen_face_frame=24,
                force=False,
                dry_run=True,
                environment=None,
            )
            with mock.patch.object(client, "_load_modal", side_effect=AssertionError("network import")):
                plan = client.command_upload(args)
        self.assertTrue(plan["dry_run"])
        self.assertEqual(plan["files"]["request"], "jobs/walk-v1/input/request.json")

    def test_stage_order_and_gpu_are_explicit(self):
        with self.assertRaisesRegex(ValueError, "job-id"):
            client._spawn_kwargs("download-inference", None, None)
        self.assertEqual(client._spawn_kwargs("download-preprocess", None, None), {})
        self.assertEqual(
            client._spawn_kwargs("download-inference", "walk-v1", None),
            {"job_id": "walk-v1"},
        )
        with self.assertRaisesRegex(ValueError, "job-id"):
            client._spawn_kwargs("validate-inputs", None, None)
        validate_args = argparse.Namespace(
            stage="validate-inputs",
            job_id="walk-v1",
            seed=None,
            dry_run=True,
            environment=None,
        )
        validate_plan = client.command_spawn(validate_args)
        self.assertEqual(validate_plan["function"], "validate_inference_inputs")
        self.assertIsNone(validate_plan["gpu"])
        self.assertNotIn("hard_timeout_seconds", validate_plan)
        args = argparse.Namespace(
            stage="infer",
            job_id="walk-v1",
            seed=7,
            dry_run=True,
            environment=None,
        )
        plan = client.command_spawn(args)
        self.assertEqual(plan["function"], "infer")
        self.assertEqual(plan["gpu"], "H200")
        self.assertEqual(plan["hard_timeout_seconds"], 1800)

    def test_spawn_returns_modal_call_id(self):
        class FakeCall:
            object_id = "fc-123"

        class FakeFunction:
            @classmethod
            def from_name(cls, app_name, function_name, environment_name=None):
                self = cls()
                self.lookup = (app_name, function_name, environment_name)
                return self

            def spawn(self, **kwargs):
                self.kwargs = kwargs
                return FakeCall()

        fake_modal = types.SimpleNamespace(Function=FakeFunction)
        args = argparse.Namespace(
            stage="preprocess",
            job_id="walk-v1",
            seed=None,
            dry_run=False,
            environment="dev",
        )
        with mock.patch.object(client, "_load_modal", return_value=fake_modal):
            result = client.command_spawn(args)
        self.assertEqual(result["call_id"], "fc-123")
        self.assertTrue(result["spawned"])

    def test_status_timeout_is_pending(self):
        class FakeCall:
            def get(self, timeout):
                self.timeout = timeout
                raise TimeoutError

        fake_modal = types.SimpleNamespace(
            FunctionCall=types.SimpleNamespace(from_id=lambda _: FakeCall())
        )
        with mock.patch.object(client, "_load_modal", return_value=fake_modal):
            result = client.command_status(argparse.Namespace(call_id="fc-123"))
        self.assertEqual(result["status"], "running_or_pending")

    def test_approval_is_bound_to_preprocess_id(self):
        review_range = {
            "cycleStartFrame": 24,
            "cycleEndFrameExclusive": 48,
            "closureFrame": 48,
            "packedFrames": list(range(24, 48)),
            "reviewedPoseFrames": list(range(24, 49)),
            "packedFrameCount": 24,
            "reviewFrameCount": 25,
        }
        ready = {
            "status": "ready_for_review",
            "job_id": "walk-v1",
            "preprocess_id": "pre-abc",
            "reviewRange": review_range,
            "frozenFaceFrame": 24,
            "cycleContactSheetSha256": "a" * 64,
            "requestSha256": "b" * 64,
            "inferenceInputsSha256": {
                "src_ref.png": "c" * 64,
                "src_pose.mp4": "d" * 64,
                "src_face.mp4": "e" * 64,
            },
        }
        volume = FakeVolume(
            {"jobs/walk-v1/preprocess/READY.json": json.dumps(ready).encode("utf-8")}
        )
        fake_modal = types.SimpleNamespace(
            Volume=types.SimpleNamespace(from_name=lambda *args, **kwargs: volume)
        )
        args = argparse.Namespace(
            job_id="walk-v1",
            yes_reviewed_cycle_sheet=True,
            note="feet and crop checked",
            dry_run=False,
            environment=None,
        )
        with mock.patch.object(client, "_load_modal", return_value=fake_modal):
            result = client.command_approve(args)
        self.assertEqual(result["preprocess_id"], "pre-abc")
        self.assertEqual(volume.uploads[0][1], "jobs/walk-v1/APPROVED.json")
        marker_stream = volume.uploads[0][0]
        marker_stream.seek(0)
        marker = json.loads(marker_stream.read().decode("utf-8"))
        self.assertTrue(marker["reviewedCycleContactSheet"])
        self.assertEqual(marker["preprocess_id"], "pre-abc")
        self.assertEqual(marker["reviewRange"], review_range)
        self.assertEqual(marker["frozenFaceFrame"], 24)
        self.assertEqual(marker["cycleContactSheetSha256"], "a" * 64)
        self.assertEqual(marker["requestSha256"], "b" * 64)
        self.assertEqual(marker["inferenceInputsSha256"], ready["inferenceInputsSha256"])

    def test_cli_dry_run_prints_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            character = Path(temporary) / "character.png"
            driver = Path(temporary) / "driver.mp4"
            character.write_bytes(b"character")
            driver.write_bytes(b"driver")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                return_code = client.main(
                    [
                        "upload",
                        "--job-id",
                        "walk-v1",
                        "--character",
                        str(character),
                        "--driver",
                        str(driver),
                        "--dry-run",
                    ]
                )
        self.assertEqual(return_code, 0)
        self.assertEqual(json.loads(output.getvalue())["operation"], "upload")


if __name__ == "__main__":
    unittest.main()
