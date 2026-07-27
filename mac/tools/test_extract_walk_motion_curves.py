from __future__ import annotations

import math
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from extract_walk_motion_curves import (  # noqa: E402
    eval_fourier,
    fill_gaps,
    fit_fourier,
    half_cycle_correlation,
    residual_degrees,
    segment_angles,
    solve_root_motion,
    verify_planted_foot,
)

FACING_LEFT = -1.0


class SegmentAngleTests(unittest.TestCase):
    """0 degrees is straight down; positive turns toward the way we walk."""

    def angle(self, parent, child, facing=FACING_LEFT):
        points = np.array([[parent, child]], dtype=float)
        return float(segment_angles(points, facing)[0])

    def test_straight_down_is_zero(self):
        self.assertAlmostEqual(self.angle((0, 0), (0, 10)), 0.0)

    def test_forward_is_positive_when_facing_left(self):
        # Image x grows right, so forward for a left-facing walker is -x.
        self.assertAlmostEqual(self.angle((0, 0), (-10, 10)), 45.0)

    def test_backward_is_negative_when_facing_left(self):
        self.assertAlmostEqual(self.angle((0, 0), (10, 10)), -45.0)

    def test_facing_right_flips_the_sign(self):
        self.assertAlmostEqual(self.angle((0, 0), (10, 10), facing=1.0), 45.0)

    def test_a_whole_frame_shift_cannot_change_an_angle(self):
        """Why the driver's plate jitter is survivable: angles are translation invariant."""
        plain = self.angle((100, 100), (80, 140))
        shifted = self.angle((100 + 37, 100 - 19), (80 + 37, 140 - 19))
        self.assertAlmostEqual(plain, shifted)


class GapFillingTests(unittest.TestCase):
    def test_interior_gap_is_interpolated(self):
        values = np.array([0.0, np.nan, 2.0, 3.0])
        np.testing.assert_allclose(fill_gaps(values), [0.0, 1.0, 2.0, 3.0])

    def test_gap_at_the_wrap_uses_the_far_end(self):
        # Periodic data: the hole at the end must see index 0 as its neighbour.
        values = np.array([0.0, 10.0, 20.0, np.nan])
        filled = fill_gaps(values)
        self.assertTrue(0.0 <= filled[3] <= 20.0)
        self.assertFalse(np.isnan(filled).any())

    def test_an_empty_track_is_rejected(self):
        with self.assertRaises(ValueError):
            fill_gaps(np.array([np.nan, np.nan]))


class FourierTests(unittest.TestCase):
    def test_a_pure_harmonic_round_trips(self):
        n = 48
        t = np.arange(n) / n
        signal = 7.0 + 3.0 * np.sin(2 * np.pi * 2 * t)
        series = fit_fourier(signal, harmonics=4)
        self.assertAlmostEqual(series["mean"], 7.0, places=6)
        self.assertAlmostEqual(series["sin"][1], 3.0, places=6)
        self.assertLess(residual_degrees(signal, series), 1e-6)

    def test_the_fit_evaluates_between_the_samples(self):
        n = 24
        t = np.arange(n) / n
        signal = np.cos(2 * np.pi * t)
        series = fit_fourier(signal, harmonics=3)
        # A phase that was never sampled still lands on the true curve.
        self.assertAlmostEqual(
            float(eval_fourier(series, 1 / 96)), math.cos(2 * math.pi / 96), places=6
        )

    def test_the_curve_closes_on_itself(self):
        series = fit_fourier(np.arange(24, dtype=float) % 5, harmonics=4)
        self.assertAlmostEqual(
            float(eval_fourier(series, 0.0)), float(eval_fourier(series, 1.0)), places=9
        )

    def test_high_frequency_noise_is_rejected(self):
        n = 24
        t = np.arange(n) / n
        clean = 10.0 * np.sin(2 * np.pi * t)
        noisy = clean + 4.0 * ((-1.0) ** np.arange(n))  # Nyquist-rate jitter.
        fitted = eval_fourier(fit_fourier(noisy, harmonics=4), t)
        self.assertLess(float(np.sqrt(np.mean((fitted - clean) ** 2))), 1.0)


class HalfCycleSymmetryTests(unittest.TestCase):
    def test_an_antiphase_pair_correlates(self):
        t = np.arange(24) / 24
        near = np.sin(2 * np.pi * t)
        far = np.sin(2 * np.pi * (t + 0.5))
        corr, rms = half_cycle_correlation(near, far)
        self.assertGreater(corr, 0.99)
        self.assertLess(rms, 1e-9)

    def test_an_in_phase_pair_does_not(self):
        t = np.arange(24) / 24
        signal = np.sin(2 * np.pi * t)
        corr, _ = half_cycle_correlation(signal, signal)
        self.assertLess(corr, -0.99)


class RootMotionTests(unittest.TestCase):
    """The root is solved from the ground, so a synthetic gait must come back clean."""

    LENGTHS = {"thigh": 0.5, "calf": 0.5, "foot": 0.22,
               "upperArm": 0.33, "forearm": 0.30}

    def synthetic_gait(self, stride=0.8, n=720, lift=0.12, stance=0.6,
                       harmonics=16):
        """A gait built the other way round: author the foot, solve for the joints.

        Deriving joint angles from a chosen foot path is the only way to get a
        synthetic walk whose true stride is known exactly.  Guessing angle
        curves instead produces a leg that sweeps below the floor during swing,
        which has no stance phase and therefore no stride to recover.

        Through stance the ankle sits on a fixed floor and slides straight back
        by `stride`; through swing it arcs forward again, clearing by `lift`.
        """
        thigh_len, calf_len = self.LENGTHS["thigh"], self.LENGTHS["calf"]
        floor = 0.96 * (thigh_len + calf_len)
        t = np.arange(n) / n

        # Ankle path relative to the hip: +x forward, +y down.
        u = np.where(t < stance, t / stance, (t - stance) / (1 - stance))
        ankle_x = np.where(t < stance,
                           stride / 2 - stride * u,
                           -stride / 2 + stride * u)
        ankle_y = np.where(t < stance, floor, floor - lift * np.sin(np.pi * u))

        # Two-link inverse kinematics, knee carried forward as a human knee is.
        reach = np.hypot(ankle_x, ankle_y)
        reach = np.minimum(reach, thigh_len + calf_len - 1e-9)
        cos_alpha = np.clip(
            (reach ** 2 + thigh_len ** 2 - calf_len ** 2) / (2 * reach * thigh_len), -1, 1
        )
        direction = np.arctan2(ankle_x, ankle_y)
        thigh = direction + np.arccos(cos_alpha)
        knee_x, knee_y = thigh_len * np.sin(thigh), thigh_len * np.cos(thigh)
        calf = np.arctan2(ankle_x - knee_x, ankle_y - knee_y)

        return {
            "thigh": fit_fourier(np.degrees(thigh), harmonics),
            "calf": fit_fourier(np.degrees(calf), harmonics),
            "foot": fit_fourier(np.zeros(n), 1),
            "pelvisBob": fit_fourier(np.zeros(n), 1),
        }

    def test_a_compass_gait_is_flagged_rather_than_silently_solved(self):
        """A locked knee never lifts the foot, so both legs are always down.

        There is no support leg to pick, and the root solution is meaningless.
        The stance check is the tripwire that says so.
        """
        n = 360
        thigh = 25.0 * np.cos(2 * np.pi * np.arange(n) / n)
        locked = {
            "thigh": fit_fourier(thigh, 6),
            "calf": fit_fourier(thigh, 6),
            "foot": fit_fourier(np.zeros(n), 1),
            "pelvisBob": fit_fourier(np.zeros(n), 1),
        }
        locked["pelvisBob"] = solve_root_motion(locked, self.LENGTHS)["bob"]
        checked = verify_planted_foot(locked, {"segmentLengths": self.LENGTHS})
        self.assertGreater(checked["stanceFractionNear"], 0.95)
        self.assertGreater(checked["doubleSupportFraction"], 0.95)

    # The authored foot path has corners where slide meets arc, and the solved
    # bob is republished as four harmonics, so a few percent of rounding is
    # expected and is the same smoothing the shipped asset gets.
    SMOOTHING_TOLERANCE = 0.05

    def test_the_authored_stride_is_recovered(self):
        """A foot sliding back by `stride` over `stance` sets the body's speed.

        Whatever fraction of the cycle a foot is planted, the body travels at
        slide-over-stance the whole time, so that ratio is the distance covered
        in one cycle.
        """
        stride, stance = 0.8, 0.6
        root = solve_root_motion(self.synthetic_gait(stride=stride, stance=stance),
                                 self.LENGTHS, samples=2000)
        self.assertAlmostEqual(root["strideLengthPerCycle"], stride / stance,
                               delta=self.SMOOTHING_TOLERANCE)

    def test_stride_scales_with_the_authored_step(self):
        small = solve_root_motion(self.synthetic_gait(stride=0.4), self.LENGTHS, samples=2000)
        large = solve_root_motion(self.synthetic_gait(stride=0.8), self.LENGTHS, samples=2000)
        self.assertAlmostEqual(
            large["strideLengthPerCycle"] / small["strideLengthPerCycle"], 2.0, delta=0.1
        )

    def test_a_longer_stance_means_a_slower_body(self):
        quick = solve_root_motion(self.synthetic_gait(stride=0.8, stance=0.55),
                                  self.LENGTHS, samples=2000)
        slow = solve_root_motion(self.synthetic_gait(stride=0.8, stance=0.75),
                                 self.LENGTHS, samples=2000)
        self.assertGreater(quick["strideLengthPerCycle"], slow["strideLengthPerCycle"])

    def test_a_still_figure_has_no_stride_and_no_bob(self):
        n = 48
        still = {
            "thigh": fit_fourier(np.zeros(n), 1),
            "calf": fit_fourier(np.zeros(n), 1),
            "foot": fit_fourier(np.zeros(n), 1),
            "pelvisBob": fit_fourier(np.zeros(n), 1),
        }
        root = solve_root_motion(still, self.LENGTHS, samples=240)
        self.assertAlmostEqual(root["strideLengthPerCycle"], 0.0, places=9)
        self.assertAlmostEqual(root["bobAmplitudeLegUnits"], 0.0, places=9)

    def test_the_derived_bob_keeps_the_support_foot_on_the_floor(self):
        channels = self.synthetic_gait()
        channels["pelvisBob"] = solve_root_motion(channels, self.LENGTHS)["bob"]
        report = {"segmentLengths": self.LENGTHS}
        checked = verify_planted_foot(channels, report, samples=720)
        # The floor was authored flat, so what is left is the four-harmonic
        # bob's own rounding — the same bound the shipped asset is held to.
        self.assertLess(checked["plantedFootDriftLegUnits"], 0.02)

    def test_each_leg_carries_a_plausible_share_of_stance(self):
        channels = self.synthetic_gait()
        channels["pelvisBob"] = solve_root_motion(channels, self.LENGTHS)["bob"]
        checked = verify_planted_foot(channels, {"segmentLengths": self.LENGTHS})
        for side in ("stanceFractionNear", "stanceFractionFar"):
            self.assertGreater(checked[side], 0.45)
            self.assertLess(checked[side], 0.85)


class PublishedCurveTests(unittest.TestCase):
    """Guard the asset the runtime will actually load."""

    CURVES = Path(__file__).resolve().parents[1] / "assets/motion-curves/side-walk-v1.json"

    def setUp(self):
        if not self.CURVES.exists():
            self.skipTest("run extract_walk_motion_curves.py first")
        import json
        self.curves = json.loads(self.CURVES.read_text())

    def test_every_channel_the_renderer_reads_is_present(self):
        for name in ("thigh", "calf", "foot", "upperArm", "forearm",
                     "torsoLean", "headLean", "pelvisBob"):
            self.assertIn(name, self.curves["channels"])

    def test_the_stride_is_a_plausible_human_one(self):
        # Adults stride between about 1.5 and 2.0 leg lengths per cycle.
        self.assertGreater(self.curves["strideLengthPerCycle"], 1.4)
        self.assertLess(self.curves["strideLengthPerCycle"], 2.1)

    def test_the_far_side_is_half_a_cycle_behind(self):
        self.assertEqual(self.curves["farSidePhaseOffset"], 0.5)

    def test_the_published_curves_keep_the_foot_planted(self):
        checked = verify_planted_foot(
            self.curves["channels"], {"segmentLengths": self.curves["segmentLengths"]}
        )
        # Under two percent of leg length is about one pixel on screen.
        self.assertLess(checked["plantedFootDriftLegUnits"], 0.02)
        self.assertGreater(checked["doubleSupportFraction"], 0.05)
        self.assertLess(checked["doubleSupportFraction"], 0.25)


if __name__ == "__main__":
    unittest.main()
