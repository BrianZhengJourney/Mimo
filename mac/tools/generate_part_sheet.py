#!/usr/bin/env python3
"""Ask the image model for the one thing geometry cannot produce: hidden pixels.

The rig moves drawn pixels rather than repainting them, so it never drifts —
but it can only move pixels that exist.  In a side-on portrait the far arm is
behind the torso, the shoulder is behind the near arm, and the two legs overlap
almost exactly.  Those pixels were never drawn, and no amount of warping
invents them.

So the model is asked for parts, not for animation.  It runs once per
character; every action afterwards reuses the same layers at no cost.

Four cells rather than a dozen.  Each cell is one isolated object, which is a
request image models honour reliably, and the elbow, knee and ankle are cut
afterwards by proportion — the grid failures in this project's history came
from asking one sheet to hold many *poses*, which is a much harder ask than
many parts.

The API key is read from the environment and never printed.  To use the key
this project already stores:

    OPENAI_API_KEY=$(security find-generic-password -s com.brianzheng.mimo \\
        -a mimo.openai.api-key -w) \\
      python3 mac/tools/generate_part_sheet.py --character ... --out-dir ...
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ENDPOINT = "https://api.openai.com/v1/images/edits"
# The model cannot emit alpha, so the background is keyed out afterwards.
# Saturated green sits far from this art's whites, creams, browns and blacks.
CHROMA_KEY = "#00B140"
MODEL = "gpt-image-2"

CELLS = [
    ("head", "top-left", "the complete head: face, ears, neck stump, and the "
                         "entire hairstyle including every strand that falls "
                         "behind the shoulders"),
    ("torso", "top-right", "the bare torso only, from the base of the neck to "
                           "the hips, with BOTH arms and BOTH legs removed at "
                           "the shoulder and hip sockets; draw the shoulder and "
                           "hip areas complete, including the parts normally "
                           "hidden behind an arm or a thigh"),
    ("arm", "bottom-left", "one complete arm on its own, shoulder ball down to "
                           "fingertips, hanging straight down and vertical, "
                           "keeping the sleeve, the tattoo and the wristwatch"),
    ("leg", "bottom-right", "one complete leg on its own, hip ball down to the "
                            "sole of the shoe, straight and vertical, keeping "
                            "the full trouser leg and the whole shoe"),
]


def build_prompt() -> str:
    parts = "\n".join(f"  - {position}: {what}" for _, position, what in CELLS)
    return f"""Cut the character in the reference image into separated body parts for a
cut-out animation rig. Do not redesign, restyle, or redraw the character.

Return ONE image, a 2 by 2 grid of four equal 512 by 512 cells:

{parts}

Absolute requirements:
  - Identical character. Same face, same palette, same line work, same pixel
    rendering and shading as the reference. Copy, do not reinterpret.
  - Same scale as the reference for every part, so the parts fit back together.
  - Flat solid chroma-key green {CHROMA_KEY} filling the entire background of
    all four cells, edge to edge. That green must appear nowhere else. No
    gradient, no texture, no ground, no cast shadow, no panel borders, no grid
    lines, no labels, no text, no numbers.
  - Every part complete and unoccluded, drawn as a whole object. Where a part
    is normally hidden behind another, invent only the small hidden area and
    keep it consistent with the surrounding cloth and skin.
  - Each part fully inside its own cell, centred, with clear empty margin on
    all four sides. Nothing may touch or cross a cell edge.
  - Exactly one object per cell. No duplicates, no extra limbs, no full body.
  - Side view, facing left, matching the reference's orientation.
"""


def post_multipart(url: str, fields: dict, files: dict, token: str) -> dict:
    boundary = f"----mimo{uuid.uuid4().hex}"
    body = bytearray()
    for name, value in fields.items():
        body += f"--{boundary}\r\n".encode()
        body += f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
        body += f"{value}\r\n".encode()
    for name, path in files.items():
        mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        body += f"--{boundary}\r\n".encode()
        body += (f'Content-Disposition: form-data; name="{name}"; '
                 f'filename="{path.name}"\r\n').encode()
        body += f"Content-Type: {mime}\r\n\r\n".encode()
        body += path.read_bytes() + b"\r\n"
    body += f"--{boundary}--\r\n".encode()

    request = urllib.request.Request(url, data=bytes(body), method="POST")
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:2000]
        raise SystemExit(f"OpenAI returned {error.code}: {detail}") from None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--character", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--size", default="1024x1024")
    parser.add_argument("--quality", default="high", choices=("low", "medium", "high"))
    parser.add_argument("--dry-run", action="store_true",
                        help="print the prompt and spend nothing")
    args = parser.parse_args()

    prompt = build_prompt()
    if args.dry_run:
        print(prompt)
        return 0

    token = os.environ.get("OPENAI_API_KEY", "").strip()
    if not token:
        raise SystemExit("OPENAI_API_KEY is not set; see this file's header")

    result = post_multipart(
        ENDPOINT,
        {
            "model": MODEL,
            "prompt": prompt,
            "size": args.size,
            "quality": args.quality,
            "n": "1",
            "output_format": "png",
        },
        {"image": args.character},
        token,
    )

    payload = result.get("data", [{}])[0]
    if "b64_json" not in payload:
        raise SystemExit(f"unexpected response: {json.dumps(result)[:800]}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    sheet = args.out_dir / "part-sheet.png"
    sheet.write_bytes(base64.b64decode(payload["b64_json"]))
    (args.out_dir / "part-sheet.request.json").write_text(json.dumps({
        "model": MODEL,
        "size": args.size,
        "quality": args.quality,
        "cells": [{"part": n, "position": p} for n, p, _ in CELLS],
        "chromaKey": CHROMA_KEY,
        "prompt": prompt,
        "usage": result.get("usage"),
    }, indent=2) + "\n")
    print(f"wrote {sheet}")
    print(f"usage: {json.dumps(result.get('usage'))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
