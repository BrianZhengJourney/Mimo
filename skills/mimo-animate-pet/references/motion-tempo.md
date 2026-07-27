# Motion tempo

## Contents

1. Timing principles
2. Default profiles
3. Runtime mapping
4. Preview rules

## 1. Timing principles

Animation quality is not “more FPS.” Mimo should feel observed and alive, not
busy.

- Use fewer, stronger poses for ambient motion.
- Hold endpoints and calm poses longer than transition poses.
- Give loops an authored seam; the last frame is not automatically a pause.
- Split sequences when transition and residency need different timing.
- Drive walking from distance travelled, not elapsed time.
- Keep previews faithful to authored per-frame holds.

## 2. Default profiles

These are starting values, not universal laws. Holds are seconds.

| Motion | Frames | Timing | Target feel |
|---|---:|---|---|
| idle / breathe | 3 | `.70, .55, .85` | ~2.1s readable calm loop |
| walk | 8 key | distance phase; ~1.4–1.8s preview cycle | leisurely locomotion |
| sleep: lie-down | 3 | `.26, .30, .48` | quick transition |
| sleep: breathing | 3 | `.90, .75, 1.10` | ~2.75s slow loop |
| sleep: rise | 3 | `.24, .28, .42` | quick transition |
| gaze | 5 directions | cursor angle | neutral / up / right / down / left |
| tennis | 9 | `.24, .18, .14, .10, .09, .16, .20, .24, .36` | forehand loop |
| wall-standing | 3 | `.70, .55, .95` | ~2.2s relaxed loop |

Do not put a quick settling transition and a five-second sleep breath into one
constant-FPS action. Author separate behavior segments over one strip or
separate strips.

## 3. Runtime mapping

### Ambient, segmented, and tennis

Use the behavior pack's per-pose `hold` values. Action manifest FPS is a preview
fallback, not the behavioral source of truth.

### Locomotion

Store an authored `cycleDistanceCellPixels` for walk. The runtime maps:

```text
phase = travelledDistance / cycleDistance
frame = floor(fract(phase) × frameCount)
```

This prevents moonwalking when velocity changes. Walking should not be slowed
by lowering FPS independently of movement speed.

### Gaze

Map cursor angle to the nearest of five authored direction cells. If smoothing
is added, ease the angle or apply a short 120–260ms transition; do not loop gaze.

## 4. Preview rules

- Preview with the exact per-frame holds used by the behavior pack.
- For distance-driven motion, use the target cycle duration only for visual QA.
- Show at the real desktop display height.
- Run at least three complete loops.
- Include the seam in review.
- Provide reduced-motion behavior separately; do not make every user's default
  animation unnaturally static.
