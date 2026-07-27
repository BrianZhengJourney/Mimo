from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np

try:
    from .postprocess import ValidationError, process_action
except ImportError:  # Supports `python mac/tools/wan_action/test_postprocess.py`.
    from postprocess import ValidationError, process_action


class WanActionPostprocessorTests(unittest.TestCase):
    def make_rgba_cycle(self, root: Path, *, size: int = 128) -> tuple[Path, Path]:
        frames = root / "frames"
        frames.mkdir()
        for index in range(25):
            phase = (index % 24) / 24.0
            image = np.zeros((size, size, 4), dtype=np.uint8)
            # A fixed torso and two phase-shifted legs. Frame 24 closes frame 0.
            cv2.rectangle(image, (52, 24), (76, 82), (80, 140, 220, 255), -1)
            swing = int(round(13 * np.sin(phase * np.pi * 2)))
            cv2.line(image, (58, 80), (58 + swing, 111), (80, 140, 220, 255), 8)
            cv2.line(image, (70, 80), (70 - swing, 111), (65, 110, 190, 255), 8)
            cv2.rectangle(image, (62, 48), (66, 52), (0, 0, 255, 255), -1)
            self.assertTrue(cv2.imwrite(str(frames / f"frame-{index:04d}.png"), image))

        sidecar = root / "phase.json"
        sidecar.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "driverID": "synthetic-side-walk-v1",
                    "framesPerSecond": 30,
                    "frameCount": 25,
                    "cycleLengthFrames": 24,
                    "cycleStartFrame": 0,
                    "cycleEndFrameExclusive": 24,
                    "duplicateEndpoint": False,
                    "direction": "left",
                    "sourceAnchorMode": "union-bottom-center",
                    "targetCharacterHeight": 451,
                    "outputAnchor": [256, 502],
                    "outputFrameCount": 24,
                    "cycleDistanceCellPixels": 144,
                }
            ),
            encoding="utf-8",
        )
        return frames, sidecar

    def test_rgba_sequence_becomes_fixed_24_frame_strip(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            output = root / "output"

            result = process_action(frames, sidecar, output)

            strip = cv2.imread(str(output / "action-walk.png"), cv2.IMREAD_UNCHANGED)
            self.assertIsNotNone(strip)
            self.assertEqual(strip.shape, (512, 512 * 24, 4))
            self.assertEqual(result.frame_count, 24)
            self.assertEqual(result.fixed_anchor, (256, 502))
            frame_heights: list[int] = []
            for index in range(24):
                frame_alpha = strip[:, index * 512:(index + 1) * 512, 3]
                frame_ys = np.nonzero(frame_alpha > 24)[0]
                frame_heights.append(int(frame_ys.max() - frame_ys.min() + 1))
            median_height = float(np.median(frame_heights))
            self.assertLessEqual(abs(median_height - 451) / 451, 0.02)
            alpha = strip[:, :512, 3]
            ys, xs = np.nonzero(alpha > 8)
            diagnostics = {
                "gates": result.qa["gates"],
                "alphaBounds": [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())],
                "normalization": result.qa["normalization"],
            }
            self.assertTrue(result.qa["hardPass"], diagnostics)
            self.assertTrue(result.qa["gates"]["targetCharacterHeight"]["pass"])
            self.assertEqual(result.qa["gates"]["targetCharacterHeight"]["target"], 451)
            self.assertEqual(result.qa["gates"]["loopAlphaClosure"]["minimum"], 0.97)
            self.assertEqual(result.qa["gates"]["loopAppearanceClosure"]["maximum"], 0.05)
            self.assertEqual(result.qa["gates"]["loopTransition"]["maximumRatio"], 1.25)
            self.assertEqual(result.qa["gates"]["alphaAreaStability"]["maximumAllowed"],
                             0.12)
            self.assertEqual(
                result.qa["manualChecks"]["headFaceSizeStability"]["status"],
                "manual-required",
            )
            self.assertTrue((output / "action-walk.qa.json").is_file())
            self.assertTrue((output / "action-walk-contact-sheet.png").is_file())
            self.assertTrue((output / "action-walk.metadata.json").is_file())

            metadata = json.loads((output / "action-walk.metadata.json").read_text())
            self.assertEqual(
                set(metadata),
                {
                    "schemaVersion", "action", "stripFilename", "frameCount",
                    "cellSize", "framesPerSecond", "cycleDistanceCellPixels",
                    "anchorInCell", "qaFilename", "automaticInstallAllowed",
                },
            )
            self.assertEqual(metadata["cycleDistanceCellPixels"], 144.0)
            self.assertEqual(metadata["anchorInCell"], [256, 502])
            self.assertFalse(metadata["automaticInstallAllowed"])
            self.assertEqual(result.metadata_path,
                             output / "action-walk.metadata.json")

    def test_loop_pop_is_rejected_even_when_closure_frame_matches_start(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            bad_path = frames / "frame-0023.png"
            bad = cv2.imread(str(bad_path), cv2.IMREAD_UNCHANGED)
            foreground = bad[:, :, 3] > 24
            bad[foreground, :3] = (20, 240, 30)
            self.assertTrue(cv2.imwrite(str(bad_path), bad))

            result = process_action(frames, sidecar, root / "output")

            self.assertFalse(result.qa["hardPass"])
            self.assertFalse(result.qa["gates"]["loopTransition"]["pass"])

    def test_opaque_sequence_uses_border_connected_chroma_alpha(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            matte_bgr = np.asarray([25, 240, 35], dtype=np.uint8)
            for path in sorted(frames.glob("*.png")):
                rgba = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
                alpha = rgba[:, :, 3:4].astype(np.float32) / 255.0
                bgr = np.rint(
                    rgba[:, :, :3].astype(np.float32) * alpha
                    + matte_bgr[None, None, :].astype(np.float32) * (1.0 - alpha)
                ).astype(np.uint8)
                self.assertTrue(cv2.imwrite(str(path), bgr))
            contract = json.loads(sidecar.read_text(encoding="utf-8"))
            contract["matteRGB"] = [35, 240, 25]
            sidecar.write_text(json.dumps(contract), encoding="utf-8")

            result = process_action(frames, sidecar, root / "output")

            strip = cv2.imread(str(result.strip_path), cv2.IMREAD_UNCHANGED)
            self.assertTrue(result.qa["hardPass"], result.qa["gates"])
            self.assertEqual(result.qa["normalization"]["alphaMethods"],
                             ["border-connected-chroma"])
            self.assertEqual(int(strip[0, 0, 3]), 0)
            self.assertGreater(int(strip[:, :512, 3].max()), 250)

    def test_single_frame_scale_pulse_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            pulse_path = frames / "frame-0015.png"
            pulse = np.zeros((128, 128, 4), dtype=np.uint8)
            cv2.rectangle(pulse, (42, 24), (87, 115), (80, 140, 220, 255), -1)
            self.assertTrue(cv2.imwrite(str(pulse_path), pulse))

            result = process_action(frames, sidecar, root / "output")

            self.assertFalse(result.qa["hardPass"])
            self.assertFalse(result.qa["gates"]["alphaAreaStability"]["pass"])

    def test_target_character_height_that_cannot_fit_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            contract = json.loads(sidecar.read_text(encoding="utf-8"))
            contract["targetCharacterHeight"] = 512
            sidecar.write_text(json.dumps(contract), encoding="utf-8")

            with self.assertRaisesRegex(ValidationError, "cannot fit"):
                process_action(frames, sidecar, root / "output")

    def test_source_subject_touching_frame_edge_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            clipped_path = frames / "frame-0012.png"
            clipped = cv2.imread(str(clipped_path), cv2.IMREAD_UNCHANGED)
            cv2.rectangle(clipped, (0, 45), (30, 70), (80, 140, 220, 255), -1)
            self.assertTrue(cv2.imwrite(str(clipped_path), clipped))

            result = process_action(frames, sidecar, root / "output")

            self.assertFalse(result.qa["hardPass"])
            self.assertFalse(result.qa["gates"]["sourceClipping"]["pass"])

    def test_one_union_transform_keeps_stationary_root_marker_fixed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            result = process_action(frames, sidecar, root / "output")
            strip = cv2.imread(str(result.strip_path), cv2.IMREAD_UNCHANGED)

            centers: list[tuple[float, float]] = []
            for index in range(24):
                frame = strip[:, index * 512:(index + 1) * 512]
                marker = ((frame[:, :, 2] > 250) & (frame[:, :, 1] < 8)
                          & (frame[:, :, 0] < 8) & (frame[:, :, 3] > 250))
                ys, xs = np.nonzero(marker)
                self.assertGreater(len(xs), 0)
                centers.append((float(xs.mean()), float(ys.mean())))

            self.assertLess(max(x for x, _ in centers) - min(x for x, _ in centers), 0.01)
            self.assertLess(max(y for _, y in centers) - min(y for _, y in centers), 0.01)

    def test_same_silhouette_with_changed_closure_appearance_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            closure_path = frames / "frame-0024.png"
            closure = cv2.imread(str(closure_path), cv2.IMREAD_UNCHANGED)
            foreground = closure[:, :, 3] > 24
            closure[foreground, :3] = (20, 245, 30)
            self.assertTrue(cv2.imwrite(str(closure_path), closure))

            result = process_action(frames, sidecar, root / "output")

            self.assertTrue(result.qa["gates"]["loopAlphaClosure"]["pass"])
            self.assertFalse(result.qa["gates"]["loopAppearanceClosure"]["pass"],
                             result.qa["gates"]["loopAppearanceClosure"])
            self.assertFalse(result.qa["hardPass"])

    def test_phase_sampling_uses_unique_native_frames_and_omits_endpoint(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            result = process_action(frames, sidecar, root / "output")

            sampled = result.qa["cycle"]["sampledFrames"]
            self.assertEqual(sampled, list(range(24)))
            self.assertEqual(len(set(sampled)), 24)
            self.assertNotIn(24, sampled)

    def test_cycle_shorter_than_24_native_frames_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            contract = json.loads(sidecar.read_text(encoding="utf-8"))
            contract["cycleEndFrameExclusive"] = 23
            contract["cycleLengthFrames"] = 23
            sidecar.write_text(json.dumps(contract), encoding="utf-8")

            with self.assertRaisesRegex(ValidationError, "too short"):
                process_action(frames, sidecar, root / "output")

    def test_opaque_input_without_declared_matte_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            for path in frames.glob("*.png"):
                rgba = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
                self.assertTrue(cv2.imwrite(str(path), rgba[:, :, :3]))

            with self.assertRaisesRegex(ValidationError, "requires matteRGB"):
                process_action(frames, sidecar, root / "output")

    def test_mp4_input_uses_declared_fps_and_matte(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            video_path = root / "wan.mp4"
            writer = cv2.VideoWriter(
                str(video_path), cv2.VideoWriter_fourcc(*"mp4v"), 30.0, (128, 128))
            self.assertTrue(writer.isOpened())
            matte = np.asarray([25, 240, 35], dtype=np.uint8)
            for path in sorted(frames.glob("*.png")):
                bgra = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
                alpha = bgra[:, :, 3:4].astype(np.float32) / 255.0
                bgr = np.rint(
                    bgra[:, :, :3].astype(np.float32) * alpha
                    + matte[None, None, :].astype(np.float32) * (1.0 - alpha)
                ).astype(np.uint8)
                writer.write(bgr)
            writer.release()
            contract = json.loads(sidecar.read_text(encoding="utf-8"))
            contract["matteRGB"] = [35, 240, 25]
            sidecar.write_text(json.dumps(contract), encoding="utf-8")

            result = process_action(video_path, sidecar, root / "output")

            self.assertTrue(result.qa["hardPass"], result.qa["gates"])
            self.assertAlmostEqual(result.qa["source"]["fps"], 30.0, places=2)

    def test_missing_walk_cycle_distance_is_preview_only_and_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            contract = json.loads(sidecar.read_text(encoding="utf-8"))
            del contract["cycleDistanceCellPixels"]
            sidecar.write_text(json.dumps(contract), encoding="utf-8")

            result = process_action(frames, sidecar, root / "output")

            metadata = json.loads(result.metadata_path.read_text(encoding="utf-8"))
            self.assertNotIn("cycleDistanceCellPixels", metadata)
            self.assertFalse(result.qa["hardPass"])
            self.assertFalse(result.qa["gates"]["cycleDistanceAuthored"]["pass"])

    def test_cli_style_cycle_distance_override_is_written_to_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            contract = json.loads(sidecar.read_text(encoding="utf-8"))
            del contract["cycleDistanceCellPixels"]
            sidecar.write_text(json.dumps(contract), encoding="utf-8")

            result = process_action(
                frames,
                sidecar,
                root / "output",
                cycle_distance_cell_pixels=168,
            )

            metadata = json.loads(result.metadata_path.read_text(encoding="utf-8"))
            self.assertEqual(metadata["cycleDistanceCellPixels"], 168.0)
            self.assertTrue(result.qa["gates"]["cycleDistanceAuthored"]["pass"])

    def test_legacy_nested_phase_contract_remains_supported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frames, sidecar = self.make_rgba_cycle(root)
            sidecar.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "sourceFPS": 30,
                        "sourceFrameCount": 25,
                        "cycle": {
                            "startFrame": 0,
                            "endFrame": 24,
                            "leadingFoot": "left",
                        },
                        "sourceAnchor": [64, 116],
                        "outputAnchor": [256, 502],
                        "outputFrameCount": 24,
                        "cycleDistanceCellPixels": 144,
                    }
                ),
                encoding="utf-8",
            )

            result = process_action(frames, sidecar, root / "output")

            self.assertTrue(result.qa["hardPass"], result.qa["gates"])
            self.assertEqual(result.qa["normalization"]["sourceAnchorMode"],
                             "explicit")
            self.assertFalse(result.qa["gates"]["targetCharacterHeight"]["requested"])
            self.assertEqual(result.qa["normalization"]["scaleMode"],
                             "fit-cycle-union")


if __name__ == "__main__":
    unittest.main()
