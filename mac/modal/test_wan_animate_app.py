from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import numpy as np
from PIL import Image


APP_PATH = Path(__file__).resolve().with_name("wan_animate_app.py")
SPEC = importlib.util.spec_from_file_location("mimo_wan_animate_contract_test", APP_PATH)
assert SPEC is not None and SPEC.loader is not None
APP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APP)


class WanAnimateContractTests(unittest.TestCase):
    def test_image_uses_bundled_ffmpeg_without_media_apt_chain(self):
        source = APP_PATH.read_text(encoding="utf-8")
        self.assertNotIn(".apt_install(", source)
        self.assertIn('"ninja==1.11.1.4"', source)
        self.assertIn("codeload.github.com/Wan-Video/Wan2.2/zip/", source)
        self.assertIn('"imageio-ffmpeg==0.6.0"', source)
        self.assertIn("imageio_ffmpeg.get_ffmpeg_exe()", source)
        self.assertIn('"librosa==0.10.2.post1"', source)
        self.assertIn('"tqdm==4.67.1"', source)
        self.assertIn('"wheel==0.45.1"', source)
        self.assertIn("pip install --no-build-isolation ", source)
        self.assertIn("sam2/archive/", source)
        self.assertIn("python -m pip check", source)
        self.assertIn("torch.version.cuda=='12.4'", source)
        self.assertIn("python -m py_compile", source)
        self.assertIn("wan_preprocess_entry.py", source)
        self.assertIn("wan_pose_repair.py", source)
        self.assertIn('"pose-repair.json"', source)

    def test_image_does_not_install_xfuser_or_replace_pinned_torch(self):
        source = APP_PATH.read_text(encoding="utf-8")
        self.assertNotIn("xfuser", source.lower())
        self.assertIn('"torch==2.5.1"', source)
        self.assertIn('"torchvision==0.20.1"', source)
        self.assertIn('"torchaudio==2.5.1"', source)

    def test_inference_inputs_are_staged_with_a_canonical_cv2_readable_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "staged"
            source.mkdir()
            pixels = np.zeros((32, 32, 3), dtype=np.uint8)
            pixels[:, :, 0] = np.arange(32, dtype=np.uint8)[None, :]
            pixels[:, :, 1] = 127
            pixels[:, :, 2] = 211
            Image.fromarray(pixels, mode="RGB").save(
                source / "src_ref.png",
                format="PNG",
                optimize=True,
            )
            (source / "src_pose.mp4").write_bytes(b"pose-video")
            (source / "src_face.mp4").write_bytes(b"face-video")

            details = APP._stage_inference_inputs(source, destination)

            self.assertEqual((destination / "src_pose.mp4").read_bytes(), b"pose-video")
            self.assertEqual((destination / "src_face.mp4").read_bytes(), b"face-video")
            staged = APP._decode_cv2_image(destination / "src_ref.png")
            np.testing.assert_array_equal(staged[:, :, ::-1], pixels)
            self.assertEqual((destination / "src_ref.png").read_bytes()[:2], b"BM")
            self.assertEqual(details["referencePayloadFormat"], "bmp")
            self.assertEqual(details["reference"]["width"], 32)
            self.assertEqual(details["reference"]["height"], 32)
            self.assertEqual(details["reference"]["channels"], 3)
            self.assertEqual(details["sourceReferenceSha256"], APP._sha256(source / "src_ref.png"))
            self.assertEqual(details["stagedReferenceSha256"], APP._sha256(destination / "src_ref.png"))
            self.assertEqual(details["sourcePoseSha256"], APP._sha256(source / "src_pose.mp4"))
            self.assertEqual(details["stagedPoseSha256"], APP._sha256(destination / "src_pose.mp4"))

    def test_stage_trims_extra_pose_packet_to_exact_wan_window(self):
        import cv2

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "staged"
            source.mkdir()
            Image.new("RGB", (32, 32), (127, 127, 127)).save(source / "src_ref.png")

            def write_video(path: Path, frame_count: int) -> None:
                writer = cv2.VideoWriter(
                    str(path),
                    cv2.VideoWriter_fourcc(*"mp4v"),
                    30,
                    (32, 32),
                )
                self.assertTrue(writer.isOpened())
                for index in range(frame_count):
                    frame = np.full((32, 32, 3), index % 255, dtype=np.uint8)
                    writer.write(frame)
                writer.release()

            write_video(source / "src_pose.mp4", 78)
            write_video(source / "src_face.mp4", 77)
            details = APP._stage_inference_inputs(
                source,
                destination,
                frame_num=77,
            )

            self.assertEqual(details["sourceVideos"]["src_pose.mp4"]["frames"], 78)
            self.assertEqual(APP._video_details(destination / "src_pose.mp4")["frames"], 77)
            self.assertEqual(APP._decode_video_sequence(destination / "src_pose.mp4", 77)["frames"], 77)
            self.assertNotEqual(details["sourcePoseSha256"], details["stagedPoseSha256"])
            self.assertEqual(details["sourceFaceSha256"], details["stagedFaceSha256"])

    def test_staged_inputs_are_bound_to_approved_hashes_and_request_dimensions(self):
        staged = {
            "sourceReferenceSha256": "ref",
            "stagedReferenceSha256": "canonical-ref",
            "stagedReferencePixelSha256": "pixels",
            "referencePayloadFormat": "bmp",
            "reference": {"width": 512, "height": 512, "channels": 3},
            "sourcePoseSha256": "pose",
            "sourceFaceSha256": "face",
            "stagedPoseSha256": "staged-pose",
            "stagedFaceSha256": "face",
            "sourceVideos": {
                "src_pose.mp4": {
                    "path": "src_pose.mp4",
                    "sha256": "pose",
                    "frames": 78,
                    "fps": 30,
                    "width": 512,
                    "height": 512,
                },
                "src_face.mp4": {
                    "path": "src_face.mp4",
                    "sha256": "face",
                    "frames": 77,
                    "fps": 30,
                    "width": 512,
                    "height": 512,
                },
            },
        }
        metadata = {
            "reference": {"sha256": "ref"},
            "videos": [
                {
                    "path": "src_pose.mp4",
                    "sha256": "pose",
                    "frames": 78,
                    "fps": 30,
                    "width": 512,
                    "height": 512,
                },
                {
                    "path": "src_face.mp4",
                    "sha256": "face",
                    "frames": 77,
                    "fps": 30,
                    "width": 512,
                    "height": 512,
                },
            ],
        }
        request = {"resolution_area": [512, 512], "frame_num": 77}
        video_details = [
                {
                    "path": "src_pose.mp4",
                    "sha256": "staged-pose",
                    "frames": 77,
                    "fps": 30,
                    "width": 512,
                    "height": 512,
                },
                {
                    "path": "src_face.mp4",
                    "sha256": "face",
                    "frames": 77,
                    "fps": 30,
                    "width": 512,
                    "height": 512,
                },
            ]
        decoded = {"frames": 77, "firstShape": [512, 512, 3], "lastShape": [512, 512, 3]}
        with (
            mock.patch.object(APP, "_video_details", side_effect=video_details),
            mock.patch.object(APP, "_decode_video_sequence", return_value=decoded),
        ):
            validated = APP._validate_staged_inference_inputs(
                Path("/staged"),
                staged,
                metadata,
                request,
            )
        self.assertEqual(
            validated["approvedHashes"],
            {
                "src_ref.png": "ref",
                "src_pose.mp4": "pose",
                "src_face.mp4": "face",
            },
        )
        self.assertEqual(validated["videos"]["src_pose.mp4"]["frames"], 77)

        tampered = {**staged, "sourcePoseSha256": "different"}
        with self.assertRaisesRegex(RuntimeError, "approved preprocess hashes"):
            APP._validate_staged_inference_inputs(
                Path("/staged"),
                tampered,
                metadata,
                request,
            )

    def test_default_contract_is_24_packed_frames_plus_closure(self):
        contract = APP._review_contract({"frame_num": 77})
        self.assertEqual(contract["cycleStartFrame"], 24)
        self.assertEqual(contract["cycleEndFrameExclusive"], 48)
        self.assertEqual(contract["closureFrame"], 48)
        self.assertEqual(contract["packedFrames"], list(range(24, 48)))
        self.assertEqual(contract["reviewedPoseFrames"], list(range(24, 49)))
        self.assertEqual(contract["packedFrameCount"], 24)
        self.assertEqual(contract["reviewFrameCount"], 25)
        self.assertEqual(contract["frozenFaceFrame"], 24)

    def test_closure_must_equal_exclusive_end(self):
        with self.assertRaisesRegex(ValueError, "closureFrame"):
            APP._review_contract(
                {
                    "frame_num": 77,
                    "cycleStartFrame": 24,
                    "cycleEndFrameExclusive": 48,
                    "closureFrame": 49,
                    "frozenFaceFrame": 24,
                }
            )

    def test_approval_binds_sheet_hash_range_and_frozen_face(self):
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
            "preprocess_id": "pre-1",
            "reviewRange": review_range,
            "frozenFaceFrame": 24,
            "cycleContactSheetSha256": "a" * 64,
        }
        approval = {
            "status": "approved",
            "job_id": "walk-v1",
            "preprocess_id": "pre-1",
            "reviewedCycleContactSheet": True,
            "reviewRange": review_range,
            "frozenFaceFrame": 24,
            "cycleContactSheetSha256": "a" * 64,
        }
        self.assertTrue(APP._approval_matches_ready(ready, approval))
        for key, changed in (
            ("preprocess_id", "old"),
            ("frozenFaceFrame", 25),
            ("cycleContactSheetSha256", "b" * 64),
        ):
            with self.subTest(key=key):
                stale = dict(approval)
                stale[key] = changed
                self.assertFalse(APP._approval_matches_ready(ready, stale))
        self.assertFalse(APP._approval_matches_ready({}, {"status": "approved"}))
        for key in (
            "status",
            "job_id",
            "preprocess_id",
            "reviewRange",
            "frozenFaceFrame",
            "cycleContactSheetSha256",
        ):
            with self.subTest(missing=key):
                incomplete = dict(ready)
                incomplete.pop(key)
                self.assertFalse(APP._approval_matches_ready(incomplete, approval))


if __name__ == "__main__":
    unittest.main()
