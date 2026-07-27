from __future__ import annotations

import unittest

import numpy as np

from mac.modal.wan_pose_repair import repair_temporal_pose_metas


def _meta(
    x_offset: float,
    *,
    body_confidence: float = 0.95,
    visible_body_joints: int = 20,
) -> dict[str, object]:
    body = np.zeros((20, 3), dtype=np.float32)
    for index in range(20):
        body[index, 0] = 0.25 + x_offset + index * 0.005
        body[index, 1] = 0.15 + index * 0.03
        body[index, 2] = body_confidence if index < visible_body_joints else 0.05
    return {
        "width": 512,
        "height": 512,
        "keypoints_body": body,
        "keypoints_left_hand": np.zeros((21, 3), dtype=np.float32),
        "keypoints_right_hand": np.zeros((21, 3), dtype=np.float32),
        "keypoints_face": np.zeros((69, 3), dtype=np.float32),
    }


class WanPoseRepairTests(unittest.TestCase):
    def test_repairs_only_low_confidence_joints_in_a_catastrophic_middle_frame(self):
        left = _meta(0.00)
        broken = _meta(0.01, visible_body_joints=3)
        right = _meta(0.02)
        original_confident_joint = np.array(broken["keypoints_body"][1], copy=True)

        repaired, report = repair_temporal_pose_metas([left, broken, right])

        self.assertEqual(report["repairedFrames"], [1])
        self.assertEqual(report["validBodyJointsBefore"], [20, 3, 20])
        self.assertEqual(report["validBodyJointsAfter"], [20, 20, 20])
        self.assertEqual(report["repairedBodyJointCounts"], {"1": 17})
        np.testing.assert_array_equal(
            repaired[1]["keypoints_body"][1],
            original_confident_joint,
        )
        self.assertAlmostEqual(
            float(repaired[1]["keypoints_body"][10, 0]),
            float(
                (
                    left["keypoints_body"][10, 0]
                    + right["keypoints_body"][10, 0]
                )
                / 2
            ),
            places=6,
        )
        self.assertGreaterEqual(float(repaired[1]["keypoints_body"][10, 2]), 0.5)

    def test_does_not_repair_normal_side_profile_occlusion(self):
        metas = [_meta(0.00, visible_body_joints=13),
                 _meta(0.01, visible_body_joints=11),
                 _meta(0.02, visible_body_joints=13)]

        repaired, report = repair_temporal_pose_metas(metas)

        self.assertEqual(report["repairedFrames"], [])
        np.testing.assert_array_equal(
            repaired[1]["keypoints_body"],
            metas[1]["keypoints_body"],
        )

    def test_never_extrapolates_first_or_last_frame(self):
        metas = [
            _meta(0.00, visible_body_joints=2),
            _meta(0.01),
            _meta(0.02, visible_body_joints=2),
        ]

        repaired, report = repair_temporal_pose_metas(metas)

        self.assertEqual(report["repairedFrames"], [])
        np.testing.assert_array_equal(
            repaired[0]["keypoints_body"],
            metas[0]["keypoints_body"],
        )
        np.testing.assert_array_equal(
            repaired[2]["keypoints_body"],
            metas[2]["keypoints_body"],
        )

    def test_rejects_neighbor_joint_identity_jump(self):
        left = _meta(0.00)
        broken = _meta(0.01, visible_body_joints=3)
        right = _meta(0.02)
        right["keypoints_body"][10, 0] = 0.95

        repaired, report = repair_temporal_pose_metas(
            [left, broken, right],
            max_normalized_joint_displacement=0.20,
        )

        self.assertIn(1, report["repairedFrames"])
        self.assertLess(float(repaired[1]["keypoints_body"][10, 2]), 0.5)


if __name__ == "__main__":
    unittest.main()
