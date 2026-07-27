from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from mac.tools.higgsfield_action.postprocess import (
    ValidationError,
    process_video,
)


class HiggsfieldPostprocessTests(unittest.TestCase):
    def make_video(self, root: Path, frames: int = 49) -> Path:
        path = root / "source.mp4"
        writer = cv2.VideoWriter(
            str(path), cv2.VideoWriter_fourcc(*"mp4v"), 24.0, (192, 192))
        self.assertTrue(writer.isOpened())
        matte_bgr = (255, 0, 255)
        for index in range(frames):
            canvas = np.full((192, 192, 3), matte_bgr, dtype=np.uint8)
            phase = 2.0 * np.pi * index / (frames - 1)
            x = 86 + int(round(5 * np.sin(phase)))
            y = 43 + int(round(2 * np.cos(phase)))
            cv2.circle(canvas, (x + 10, y + 15), 13, (35, 125, 235), -1)
            cv2.rectangle(canvas, (x, y + 28), (x + 20, y + 92),
                          (70, 180, 245), -1)
            cv2.line(canvas, (x + 2, y + 45), (x - 9, y + 68),
                     (30, 90, 200), 5)
            cv2.line(canvas, (x + 18, y + 45), (x + 29, y + 68),
                     (30, 90, 200), 5)
            writer.write(canvas)
        writer.release()
        return path

    def test_mp4_becomes_registered_transparent_action(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_video(root)
            result = process_video(
                source, root / "out", action="walk", frame_count=24)

            self.assertTrue(result.qa["hardPass"], result.qa["gates"])
            self.assertEqual(result.frame_count, 24)
            strip = cv2.imread(str(result.strip_path), cv2.IMREAD_UNCHANGED)
            self.assertEqual(strip.shape, (512, 24 * 512, 4))
            self.assertTrue(np.all(strip[0, :, 3] == 0))
            self.assertTrue(result.preview_gif_path.is_file())
            self.assertTrue(result.preview_webp_path.is_file())
            self.assertTrue(result.contact_sheet_path.is_file())
            self.assertEqual(len(list((root / "out" / "frames").glob("*.png"))), 24)

            qa = json.loads(result.qa_path.read_text(encoding="utf-8"))
            self.assertEqual(
                qa["normalization"]["policy"],
                "one-shared-transform-for-complete-clip")
            self.assertGreater(qa["measurements"]["closureAlphaIoU"], 0.85)
            with Image.open(result.preview_webp_path) as preview:
                self.assertTrue(getattr(preview, "is_animated", False))
                self.assertEqual(preview.n_frames, 24)

    def test_rejects_more_output_frames_than_source_motion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_video(root, frames=10)
            with self.assertRaisesRegex(ValidationError, "fewer than requested"):
                process_video(
                    source, root / "out", action="sleep", frame_count=24)

    def test_rejects_non_slug_action(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_video(root)
            with self.assertRaisesRegex(ValidationError, "lowercase slug"):
                process_video(
                    source, root / "out", action="Playing Tennis", frame_count=24)


if __name__ == "__main__":
    unittest.main()
