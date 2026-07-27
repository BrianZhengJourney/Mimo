#!/usr/bin/env python3
"""PROTOTYPE ONLY — deterministic 2D walk rig, not production rendering.

Question: does an authored gait cycle with planted support feet, weight transfer,
pelvis bob, and explicit contact/down/pass/up phases read more like walking than
asking an image model to invent every in-between frame?

The pure gait functions below are deliberately independent from file I/O.  The
rest of this file is a disposable renderer for judging the answer visually.
"""

from __future__ import annotations

import argparse
import math
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


FRAME_SIZE = 512
FRAME_COUNT = 24
FPS_MS = 42
PHASE_NAMES = (
    "L CONTACT",
    "L DOWN",
    "R PASS",
    "L TOE-OFF",
    "R CONTACT",
    "R DOWN",
    "L PASS",
    "R TOE-OFF",
)


@dataclass(frozen=True)
class FootPose:
    x: float
    y: float
    planted: bool


@dataclass(frozen=True)
class GaitPose:
    t: float
    phase: int
    pelvis_y: float
    torso_roll: float
    left: FootPose
    right: FootPose


def foot_trajectory(phase: float, ground_y: float = 455.0) -> FootPose:
    """One complete stride: long planted stance, short lifted swing."""
    p = phase % 1.0
    stance_end = 0.60
    stride = 104.0
    if p < stance_end:
        q = p / stance_end
        return FootPose(stride * (0.5 - q), ground_y, True)
    q = (p - stance_end) / (1.0 - stance_end)
    x = -stride * 0.5 + stride * (q * q * (3.0 - 2.0 * q))
    y = ground_y - 55.0 * math.sin(math.pi * q)
    return FootPose(x, y, False)


def gait_pose(frame_index: int, frame_count: int = FRAME_COUNT) -> GaitPose:
    """Pure, loop-safe gait timeline. No generated frame-to-frame guessing."""
    t = (frame_index % frame_count) / frame_count
    left = foot_trajectory(t)
    right = foot_trajectory(t + 0.5)
    # Two weight-transfer arcs per stride: lower at double support, higher at pass.
    pelvis_y = 277.0 + 6.0 * math.cos(4.0 * math.pi * t)
    torso_roll = 1.8 * math.sin(2.0 * math.pi * t)
    return GaitPose(t, int(t * 8.0) % 8, pelvis_y, torso_roll, left, right)


def two_bone_ik(
    hip: tuple[float, float],
    ankle: tuple[float, float],
    upper: float = 91.0,
    lower: float = 101.0,
) -> tuple[float, float]:
    """Return the forward-bending knee for a two-segment leg."""
    hx, hy = hip
    ax, ay = ankle
    dx, dy = ax - hx, ay - hy
    distance = max(1.0, min(math.hypot(dx, dy), upper + lower - 0.5))
    ux, uy = dx / distance, dy / distance
    along = (upper * upper - lower * lower + distance * distance) / (2.0 * distance)
    height = math.sqrt(max(0.0, upper * upper - along * along))
    base_x, base_y = hx + along * ux, hy + along * uy
    perp_x, perp_y = -uy, ux
    a = (base_x + height * perp_x, base_y + height * perp_y)
    b = (base_x - height * perp_x, base_y - height * perp_y)
    return a if a[0] > b[0] else b


def load_font(size: int, bold: bool = False) -> ImageFont.ImageFont:
    candidates = (
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    )
    for candidate in candidates:
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            pass
    return ImageFont.load_default()


FONT_16 = load_font(16, True)
FONT_20 = load_font(20, True)
FONT_28 = load_font(28, True)


def split_strip(path: Path) -> list[Image.Image]:
    strip = Image.open(path).convert("RGBA")
    size = strip.height
    if size <= 0 or strip.width % size:
        raise ValueError(f"Expected a horizontal square-frame strip, got {strip.size}")
    return [strip.crop((x, 0, x + size, size)).resize((512, 512), Image.Resampling.LANCZOS)
            for x in range(0, strip.width, size)]


def extract_identity_head(frame: Image.Image) -> Image.Image:
    """Keep the current face/hair identity; the body uses one coherent rig skin."""
    layer = Image.new("RGBA", frame.size)
    alpha = frame.getchannel("A")
    cutoff = Image.new("L", frame.size, 0)
    mask = ImageDraw.Draw(cutoff)
    mask.rectangle((0, 0, 511, 218), fill=255)
    # Feather through the shoulders/hair instead of cutting across the hips.
    for y, value in ((219, 225), (220, 185), (221, 140), (222, 95), (223, 45)):
        mask.line((0, y, 511, y), fill=value)
    clipped = Image.new("L", frame.size)
    clipped.point(lambda _: 0)
    clipped = Image.frombytes("L", frame.size,
                              bytes(min(a, b) for a, b in zip(alpha.tobytes(), cutoff.tobytes())))
    layer.paste(frame, (0, 0), clipped)
    return layer


def draw_capsule(draw: ImageDraw.ImageDraw, points: list[tuple[float, float]],
                 fill: tuple[int, int, int, int], width: int, outline_width: int = 5) -> None:
    rounded = [(round(x), round(y)) for x, y in points]
    draw.line(rounded, fill=(73, 63, 59, 255), width=width + outline_width * 2, joint="curve")
    draw.line(rounded, fill=fill, width=width, joint="curve")


def draw_leg(
    canvas: Image.Image,
    hip: tuple[float, float],
    foot: FootPose,
    near: bool,
    debug: bool = False,
) -> tuple[tuple[float, float], tuple[float, float]]:
    # The source character faces left, so positive timeline travel is mirrored.
    ankle = (hip[0] - foot.x, foot.y - 9.0)
    knee = two_bone_ik(hip, ankle, upper=93.0, lower=93.0)
    draw = ImageDraw.Draw(canvas)
    if debug:
        colour = (237, 79, 104, 255) if near else (80, 180, 255, 255)
        draw.line((hip, knee, ankle), fill=colour, width=7, joint="curve")
        for point in (hip, knee, ankle):
            x, y = point
            draw.ellipse((x - 7, y - 7, x + 7, y + 7), fill=(255, 255, 255, 255),
                         outline=colour, width=4)
    else:
        fill = (245, 242, 236, 255) if near else (207, 203, 198, 255)
        draw_capsule(draw, [hip, knee], fill, 47 if near else 41, 4)
        draw_capsule(draw, [knee, ankle], fill, 42 if near else 36, 4)
        toe = (ankle[0] - 28.0, ankle[1] + 7.0)
        draw_capsule(draw, [ankle, toe], (252, 250, 245, 255), 23 if near else 19, 3)
        # Trouser seam makes knee flexion legible at sprite scale.
        seam = (111, 102, 97, 155)
        draw.line((hip, knee, ankle), fill=seam, width=2, joint="curve")
    return knee, ankle


def transform_identity_head(layer: Image.Image, pose: GaitPose) -> Image.Image:
    rotated = layer.rotate(
        pose.torso_roll,
        resample=Image.Resampling.BICUBIC,
        center=(256, 188),
        expand=False,
    )
    shifted = Image.new("RGBA", layer.size)
    shifted.alpha_composite(rotated, (0, round(pose.pelvis_y - 277.0)))
    return shifted


def draw_arm(canvas: Image.Image, shoulder: tuple[float, float], hand: tuple[float, float], near: bool) -> None:
    elbow = two_bone_ik(shoulder, hand, upper=59.0, lower=58.0)
    draw = ImageDraw.Draw(canvas)
    sleeve = (247, 244, 238, 255) if near else (205, 201, 196, 255)
    skin = (239, 174, 125, 255) if near else (195, 139, 103, 255)
    draw_capsule(draw, [shoulder, elbow], sleeve, 24 if near else 20, 3)
    draw_capsule(draw, [elbow, hand], skin, 16 if near else 13, 3)
    x, y = hand
    draw.ellipse((x - 9, y - 9, x + 9, y + 9), fill=skin,
                 outline=(73, 63, 59, 255), width=3)


def base_scene() -> Image.Image:
    image = Image.new("RGBA", (512, 512), (248, 245, 239, 255))
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 456, 512, 512), fill=(232, 226, 217, 255))
    draw.line((0, 456, 512, 456), fill=(160, 147, 134, 255), width=2)
    return image


def render_mechanics(pose: GaitPose) -> Image.Image:
    image = base_scene()
    draw = ImageDraw.Draw(image)
    draw.text((18, 16), "A  GAIT MECHANICS", font=FONT_20, fill=(42, 36, 34, 255))
    draw.text((18, 43), PHASE_NAMES[pose.phase], font=FONT_16, fill=(104, 89, 81, 255))
    hip_left = (250.0, pose.pelvis_y)
    hip_right = (262.0, pose.pelvis_y)
    draw_leg(image, hip_right, pose.right, near=False, debug=True)
    draw_leg(image, hip_left, pose.left, near=True, debug=True)
    shoulder = (256.0, pose.pelvis_y - 130.0)
    head = (256.0, pose.pelvis_y - 185.0)
    draw.line((shoulder, (256.0, pose.pelvis_y)), fill=(60, 55, 54, 255), width=9)
    draw.ellipse((head[0] - 28, head[1] - 28, head[0] + 28, head[1] + 28),
                 fill=(255, 255, 255, 255), outline=(60, 55, 54, 255), width=5)
    arm = 48.0 * math.sin(2.0 * math.pi * pose.t)
    draw.line((shoulder, (shoulder[0] - arm, shoulder[1] + 92)),
              fill=(237, 79, 104, 255), width=7)
    draw.line((shoulder, (shoulder[0] + arm, shoulder[1] + 92)),
              fill=(80, 180, 255, 255), width=7)
    for foot, colour, label in ((pose.left, (237, 79, 104, 255), "L"),
                                (pose.right, (80, 180, 255, 255), "R")):
        x = 256 + foot.x
        if foot.planted:
            draw.rounded_rectangle((x - 27, 470, x + 27, 482), radius=6, fill=colour)
            draw.text((x - 5, 468), label, font=FONT_16, fill=(255, 255, 255, 255))
    draw.text((18, 482), "bar = planted support foot", font=FONT_16, fill=(104, 89, 81, 255))
    return image


def render_paper_doll(pose: GaitPose, identity_head: Image.Image) -> Image.Image:
    image = base_scene()
    draw = ImageDraw.Draw(image)
    draw.ellipse((194, 451, 326, 470), fill=(65, 51, 43, 35))
    hip_far = (250.0, pose.pelvis_y + 3.0)
    hip_near = (261.0, pose.pelvis_y)
    draw_leg(image, hip_far, pose.right, near=False)
    draw_leg(image, hip_near, pose.left, near=True)

    shoulder_y = pose.pelvis_y - 105.0
    arm_swing = 37.0 * math.sin(2.0 * math.pi * pose.t)
    draw_arm(image, (272.0, shoulder_y + 4.0), (272.0 - arm_swing, shoulder_y + 103.0), near=False)

    # Coherent fitted torso and pelvis skin; the source face/hair is layered over it.
    draw = ImageDraw.Draw(image)
    torso = ((232, shoulder_y - 4), (277, shoulder_y - 3),
             (281, pose.pelvis_y - 5), (232, pose.pelvis_y - 5))
    draw.polygon(torso, fill=(247, 244, 238, 255), outline=(73, 63, 59, 255), width=4)
    draw.rounded_rectangle((226, pose.pelvis_y - 20, 284, pose.pelvis_y + 15), radius=12,
                           fill=(245, 242, 236, 255), outline=(73, 63, 59, 255), width=4)
    draw.line(((230, pose.pelvis_y - 13), (281, pose.pelvis_y - 13)),
              fill=(115, 83, 64, 255), width=5)
    draw_arm(image, (234.0, shoulder_y), (234.0 + arm_swing, shoulder_y + 105.0), near=True)
    image.alpha_composite(transform_identity_head(identity_head, pose))

    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((14, 14, 228, 72), radius=12, fill=(31, 27, 25, 220))
    draw.text((28, 24), "B  2D RIG / 24 FRAMES", font=FONT_16, fill=(255, 255, 255, 255))
    draw.text((28, 48), PHASE_NAMES[pose.phase], font=FONT_16, fill=(213, 203, 196, 255))
    return image


def flatten_character(frame: Image.Image) -> Image.Image:
    bg = base_scene()
    bg.alpha_composite(frame)
    return bg


def labelled_panel(image: Image.Image, title: str, subtitle: str) -> Image.Image:
    panel = Image.new("RGBA", (512, 574), (31, 28, 27, 255))
    panel.alpha_composite(image, (0, 62))
    draw = ImageDraw.Draw(panel)
    draw.text((18, 10), title, font=FONT_20, fill=(255, 255, 255, 255))
    draw.text((18, 36), subtitle, font=FONT_16, fill=(190, 179, 171, 255))
    return panel


def render_comparison(old_frame: Image.Image, rig_frame: Image.Image, pose: GaitPose) -> Image.Image:
    left = labelled_panel(flatten_character(old_frame), "OLD: GPT IN-BETWEENS", "visual variations")
    right = labelled_panel(rig_frame, "NEW: AUTHORED 2D RIG", PHASE_NAMES[pose.phase])
    result = Image.new("RGBA", (1024, 574), (31, 28, 27, 255))
    result.alpha_composite(left, (0, 0))
    result.alpha_composite(right, (512, 0))
    return result


def save_gif(frames: list[Image.Image], path: Path) -> None:
    converted = [frame.convert("P", palette=Image.Palette.ADAPTIVE, colors=192) for frame in frames]
    converted[0].save(path, save_all=True, append_images=converted[1:], duration=FPS_MS,
                      loop=0, disposal=2, optimize=False)


def save_contact_sheet(frames: list[Image.Image], path: Path) -> None:
    thumb = 256
    rows, columns = 4, 6
    sheet = Image.new("RGBA", (columns * thumb, rows * (thumb + 26)), (31, 28, 27, 255))
    draw = ImageDraw.Draw(sheet)
    for index, frame in enumerate(frames):
        x = (index % columns) * thumb
        y = (index // columns) * (thumb + 26)
        sheet.alpha_composite(frame.resize((thumb, thumb), Image.Resampling.LANCZOS), (x, y))
        draw.text((x + 8, y + thumb + 4), f"F{index + 1:02d}  {PHASE_NAMES[gait_pose(index).phase]}",
                  font=FONT_16, fill=(242, 236, 231, 255))
    sheet.save(path)


def save_strip(frames: list[Image.Image], path: Path) -> None:
    strip = Image.new("RGBA", (len(frames) * 512, 512), (0, 0, 0, 0))
    for index, frame in enumerate(frames):
        # Restore transparent background for the engine-facing artifact.
        rgba = frame.copy()
        pixels = rgba.load()
        for y in range(512):
            for x in range(512):
                r, g, b, a = pixels[x, y]
                if (r, g, b) in ((248, 245, 239), (232, 226, 217)):
                    pixels[x, y] = (r, g, b, 0)
        strip.alpha_composite(rgba, (index * 512, 0))
    strip.save(path)


def write_html(output: Path) -> None:
    html = """<!doctype html>
<meta charset="utf-8">
<title>Mimo walk rig prototype</title>
<style>
  * { box-sizing:border-box } body { margin:0; background:#1f1c1b; color:#fff; font:16px -apple-system,sans-serif }
  main { min-height:100vh; display:grid; place-items:center; padding:32px 32px 96px }
  img { max-width:min(1100px,94vw); max-height:82vh; border-radius:16px; box-shadow:0 24px 80px #0009 }
  #switcher { position:fixed; left:50%; bottom:24px; transform:translateX(-50%); display:flex; gap:18px;
    align-items:center; background:#fff; color:#231f1d; padding:10px 14px; border-radius:999px; box-shadow:0 8px 32px #0008 }
  button { width:38px; height:38px; border:0; border-radius:50%; font-size:22px; cursor:pointer }
  strong { min-width:210px; text-align:center }
</style>
<main><img id="preview" alt="walk prototype"></main>
<div id="switcher"><button id="prev">←</button><strong id="label"></strong><button id="next">→</button></div>
<script>
const variants = [
  ['A', 'Gait mechanics', 'mechanics.gif'],
  ['B', '2D character rig', 'paper-doll.gif'],
  ['C', 'Old vs rig', 'comparison.gif'],
];
const params = new URLSearchParams(location.search); let i = Math.max(0, variants.findIndex(v => v[0] === (params.get('variant') || 'C')));
function render(){ const v=variants[i]; preview.src=v[2]; label.textContent=`${v[0]} — ${v[1]}`; params.set('variant',v[0]); history.replaceState(null,'',`?${params}`); }
function move(n){ i=(i+n+variants.length)%variants.length; render(); }
prev.onclick=()=>move(-1); next.onclick=()=>move(1);
addEventListener('keydown', e=>{ if(e.key==='ArrowLeft')move(-1); if(e.key==='ArrowRight')move(1); }); render();
</script>
"""
    (output / "index.html").write_text(html, encoding="utf-8")


def main() -> None:
    default_old = Path.home() / "Library/Application Support/Mimo/exports/walk32-v2/walk32-strip.png"
    default_identity = Path.home() / "Library/Application Support/Mimo/exports/walk16-v2/walk-strip-best-unaccepted.png"
    parser = argparse.ArgumentParser(description="Generate the disposable Mimo walk-rig prototype.")
    parser.add_argument("--old", type=Path, default=default_old)
    parser.add_argument("--identity", type=Path, default=default_identity)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "output")
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    old_frames = split_strip(args.old if args.old.exists() else args.identity)
    identity_frames = split_strip(args.identity)
    identity_head = extract_identity_head(identity_frames[min(5, len(identity_frames) - 1)])

    poses = [gait_pose(index) for index in range(FRAME_COUNT)]
    mechanics = [render_mechanics(pose) for pose in poses]
    paper_doll = [render_paper_doll(pose, identity_head) for pose in poses]
    comparison = [render_comparison(old_frames[int(index * len(old_frames) / FRAME_COUNT) % len(old_frames)],
                                    paper_doll[index], poses[index])
                  for index in range(FRAME_COUNT)]

    save_gif(mechanics, args.output / "mechanics.gif")
    save_gif(paper_doll, args.output / "paper-doll.gif")
    save_gif(comparison, args.output / "comparison.gif")
    save_contact_sheet(paper_doll, args.output / "rig-walk-24-frames.png")
    save_strip(paper_doll, args.output / "rig-walk-24-strip.png")
    write_html(args.output)
    print(f"Generated walk-rig prototype: {args.output.resolve()}")
    print("Open index.html?variant=C, or inspect comparison.gif and rig-walk-24-frames.png")


if __name__ == "__main__":
    main()
