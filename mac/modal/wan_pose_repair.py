"""Conservative temporal repair for isolated Wan pose-detector dropouts."""

from __future__ import annotations

from copy import deepcopy
from typing import Any

import numpy as np


def _body_array(meta: dict[str, Any]) -> np.ndarray:
    body = np.asarray(meta["keypoints_body"], dtype=np.float32)
    if body.ndim != 2 or body.shape[1] < 3:
        raise ValueError("keypoints_body must be a [joint, x/y/confidence] array")
    return body


def repair_temporal_pose_metas(
    metas: list[dict[str, Any]],
    *,
    confidence_threshold: float = 0.5,
    minimum_neighbor_valid_joints: int = 10,
    catastrophic_ratio: float = 0.60,
    max_normalized_joint_displacement: float = 0.20,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Repair only isolated catastrophic body-keypoint dropouts.

    A frame is eligible only when both immediate neighbours retain enough body
    joints and its own valid-joint count falls below ``catastrophic_ratio`` of
    the weaker neighbour. Existing confident joints are never changed. A
    missing joint is filled only when the same joint is confident on both
    sides and its normalized displacement is small enough to preserve identity.
    First and last frames are never extrapolated.
    """

    if not 0 < confidence_threshold <= 1:
        raise ValueError("confidence_threshold must be in (0, 1]")
    if minimum_neighbor_valid_joints < 1:
        raise ValueError("minimum_neighbor_valid_joints must be positive")
    if not 0 < catastrophic_ratio < 1:
        raise ValueError("catastrophic_ratio must be in (0, 1)")
    if max_normalized_joint_displacement <= 0:
        raise ValueError("max_normalized_joint_displacement must be positive")

    repaired = deepcopy(metas)
    bodies = [_body_array(meta) for meta in repaired]
    valid_before = [
        int(np.count_nonzero(body[:, 2] >= confidence_threshold))
        for body in bodies
    ]
    repaired_frames: list[int] = []
    repaired_counts: dict[str, int] = {}

    for frame_index in range(1, len(bodies) - 1):
        left = bodies[frame_index - 1]
        current = bodies[frame_index]
        right = bodies[frame_index + 1]
        if left.shape != current.shape or right.shape != current.shape:
            raise ValueError("All keypoints_body arrays must have the same shape")

        weaker_neighbor = min(
            valid_before[frame_index - 1],
            valid_before[frame_index + 1],
        )
        if weaker_neighbor < minimum_neighbor_valid_joints:
            continue
        if valid_before[frame_index] >= weaker_neighbor * catastrophic_ratio:
            continue

        repaired_joint_count = 0
        for joint_index in range(current.shape[0]):
            if current[joint_index, 2] >= confidence_threshold:
                continue
            if (
                left[joint_index, 2] < confidence_threshold
                or right[joint_index, 2] < confidence_threshold
            ):
                continue
            displacement = float(
                np.linalg.norm(right[joint_index, :2] - left[joint_index, :2])
            )
            if displacement > max_normalized_joint_displacement:
                continue
            current[joint_index, :2] = (
                left[joint_index, :2] + right[joint_index, :2]
            ) / 2
            current[joint_index, 2] = min(
                float(left[joint_index, 2]),
                float(right[joint_index, 2]),
            )
            repaired_joint_count += 1

        if repaired_joint_count:
            repaired_frames.append(frame_index)
            repaired_counts[str(frame_index)] = repaired_joint_count

    valid_after = [
        int(np.count_nonzero(body[:, 2] >= confidence_threshold))
        for body in bodies
    ]
    report = {
        "algorithm": "isolated-body-dropout-linear-v1",
        "confidenceThreshold": confidence_threshold,
        "minimumNeighborValidJoints": minimum_neighbor_valid_joints,
        "catastrophicRatio": catastrophic_ratio,
        "maxNormalizedJointDisplacement": max_normalized_joint_displacement,
        "frameCount": len(metas),
        "validBodyJointsBefore": valid_before,
        "validBodyJointsAfter": valid_after,
        "repairedFrames": repaired_frames,
        "repairedBodyJointCounts": repaired_counts,
    }
    return repaired, report
