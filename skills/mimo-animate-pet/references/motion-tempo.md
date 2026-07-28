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
- Keep historical walking playback distance-driven; do not generate it as a
  current Starter Action.
- Keep previews faithful to authored per-frame holds.

## 2. Default profiles

These are starting values, not universal laws. Holds are seconds.

| Motion | Frames | Timing | Target feel |
|---|---:|---|---|
| idle / breathe | 3 | `.70, .55, .85` | ~2.1s readable calm loop |
| sleep: prone lie-down | 3 | `.55, .65, .95` | calm readable one-shot transition |
| sleep: breathing | 3 | `1.40, 1.20, 1.60` | ~4.2s slow loop |
| gaze | 8 directions | cursor angle | eight compass directions; base art inside neutral radius |
| tennis | 9 | `.42, .32, .24, .18, .16, .26, .34, .42, .62` | readable forehand loop |
| wall: stand | 3 | `.95, .85, 1.25` | ~3.05s relaxed loop |
| wall: ledge-sit | 3 | `1.00, .85, 1.25` | ~3.1s gentle leg-swing loop |

Do not replay the settling transition as part of the sleep loop. Preview and
runtime play frames 0–2 once, then loop frames 3–5 until user interaction or a
physical state change interrupts sleep.

## 3. Runtime mapping

### Ambient, segmented, and tennis

Use the behavior pack's per-pose `hold` values. Action manifest FPS is a preview
fallback, not the behavioral source of truth.

### Historical locomotion compatibility

Existing accepted walk assets retain authored `cycleDistanceCellPixels`:

```text
phase = travelledDistance / cycleDistance
frame = floor(fract(phase) × frameCount)
```

This remains compatibility behavior, not a current generation instruction.

### Gaze

Map cursor angle to the nearest of eight authored direction cells. If smoothing
is added, ease the angle or apply a short 120–260ms transition; do not loop gaze.

## 4. Preview rules

- Preview with the exact per-frame holds used by the behavior pack.
- For distance-driven motion, use the target cycle duration only for visual QA.
- Show at the real desktop display height.
- Run at least three complete loops.
- Include the seam in review.
- Provide reduced-motion behavior separately; do not make every user's default
  animation unnaturally static.
