"""Run pinned Wan preprocessing with conservative temporal pose repair."""

from __future__ import annotations

import json
from pathlib import Path
import runpy
import sys
from typing import Any

from wan_pose_repair import repair_temporal_pose_metas


WAN_PREPROCESS_ROOT = Path("/opt/Wan2.2/wan/modules/animate/preprocess")
WAN_ENTRY = WAN_PREPROCESS_ROOT / "preprocess_data.py"


def _argument_value(name: str) -> str:
    try:
        return sys.argv[sys.argv.index(name) + 1]
    except (ValueError, IndexError) as error:
        raise ValueError(f"Missing required argument {name}") from error


def main() -> None:
    sys.path.insert(0, str(WAN_PREPROCESS_ROOT))
    import pose2d  # type: ignore[import-not-found]

    original_loader = pose2d.load_pose_metas_from_kp2ds_seq
    reports: list[dict[str, Any]] = []

    def repaired_loader(
        keypoints_sequence: Any,
        width: int,
        height: int,
    ) -> list[dict[str, Any]]:
        metas = original_loader(keypoints_sequence, width=width, height=height)
        if len(metas) < 3:
            return metas
        repaired, report = repair_temporal_pose_metas(metas)
        reports.append(report)
        return repaired

    pose2d.load_pose_metas_from_kp2ds_seq = repaired_loader
    runpy.run_path(str(WAN_ENTRY), run_name="__main__")

    destination = Path(_argument_value("--save_path")) / "pose-repair.json"
    destination.write_text(
        json.dumps(
            {
                "status": "applied",
                "runs": reports,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
