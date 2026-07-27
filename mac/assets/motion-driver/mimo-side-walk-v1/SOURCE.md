# Mimo side-walk driver v1

`driver.mp4` is a 77-frame, 30 fps preparation of Eadweard Muybridge's
1887 *Animal Locomotion, Plate 2*: a real human photographed from a locked
side view over one complete walking cycle. The public-domain 12-frame source
was motion-compensated to a 24-phase cycle, repeated so Wan can generate and
the postprocessor can select the middle complete cycle.

The final preparation applies one fixed transform to every frame: horizontal
flip so the human faces the same left direction as the Mimo reference, then a
single 290 x 521 scale placed at `(111, 10)` on a 512 x 512 canvas. Nothing is
recentered or rescaled per frame. This keeps the head-to-ground span and ground
line close to the reference while preserving the real gait's vertical motion.

- Source: https://commons.wikimedia.org/wiki/File:Muybridge_human_male_walking_animated.gif
- Original file: https://upload.wikimedia.org/wikipedia/commons/f/fa/Muybridge_human_male_walking_animated.gif
- License: Public Domain Mark 1.0; first published in 1887.
- Source dimensions / timing: 404 x 725, 12 frames, 4 seconds as distributed.
- Prepared driver: 512 x 512, left-facing, 77 frames, 30 fps, H.264, no audio.
- Prepared driver SHA-256: `3c25f097705da97b966f76028d322345865d8cd634c4130f712112e6111d9ee0`

`character.png` is the local Mimo test character's side-view identity frame.
It intentionally retains its alpha channel; the Modal preprocessing stage
flattens it once onto the request's recorded neutral matte before invoking
Wan's OpenCV preprocessor. It is RGBA, 512 x 512, SHA-256
`5bfac03f7c5c23475fa77c6fd58d3abcdc3899798aa12745fa0698eee3bcc714`.

The prepared driver is an acceptance fixture, not a universal walk. A later
production capture should use the same contract: one full-body subject,
locked orthographic side camera, no occlusion, constant light, and a sidecar
that names one exact left-plus-right cycle without a duplicated endpoint.
