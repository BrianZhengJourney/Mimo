# Mimo 米墨

A local-first macOS work companion that **feeds on focus, reflects distraction,
and remembers lost context**.

Mimo combines a quiet desktop familiar, an ambient focus journal, and a studio
for turning a person, pet, or original character into a custom companion.

## Status

**v0.2 Alpha · complete working baseline + default Starter Actions (2026-07-31).**

The current native app is complete and directly usable. Starter Actions now
extend this working version without making motion generation a prerequisite
for adopting or using a DIY familiar.

The repository has moved beyond the original browser concept:

- Native AppKit/CALayer companion with alpha hit testing, HiDPI rendering,
  drag/throw physics, screen surfaces, gaze, and data-driven behavior packs.
- Local app/browser activity classification, 25/50-minute Focus timers,
  a complete Today journal, Week view, and a full-page HTML archive.
- A native Reflection Browser joins raw local activity with explicitly selected
  Notion reflections, evidence-linked analysis, and preview-before-confirm
  writeback. Missing Notion/OpenAI credentials never block local browsing.
- Mimo Studio reference preprocessing, canonical character generation,
  expression assets, provider abstraction, generation ledger, and recovery.
- Mimo Studio includes four default Starter Actions after adoption: cursor
  gaze, sleep, tennis, and wall stand/sit. One click runs them in sequence.
- Each card discloses calls and estimated cost, checkpoints every completed
  three-frame batch, survives restart, and resumes only after an explicit click.
- Generated strips pass through local shared-scale/baseline processing, desktop
  preview, hard-QA checking, and explicit Accept before manifest installation.

See the [current status](docs/companion/STATUS.md) and
[custom pet integration plan](docs/companion/11-custom-pet-integration.md). The
[Reflection Browser guide](docs/reflection-browser.md) documents its data,
privacy, and Notion boundaries.

## Build and test

```bash
mac/build.sh                      # builds mac/build/Mimo.app with swiftc
mac/test.sh                       # compiles and runs the unit tests
cp -R mac/build/Mimo.app /Applications/Mimo.app
open /Applications/Mimo.app
```

`build.sh` ad-hoc signs by default, which mints a new identity every build —
macOS then re-prompts for browser Automation and invalidates the Keychain ACL
on the stored API key. Set `MIMO_SIGN_IDENTITY` to a stable self-signed
certificate in your login keychain to keep both across rebuilds.

Activity history stays local. Reference images leave the Mac only after the
user confirms the identity board and starts a provider generation.

## Product flow

```text
work context ──> local activity journal ──> focus/mood semantics
                                              │
reference images ──> canonical familiar ──> behavior + action assets
                                              │
                                              v
                               native companion runtime
```

The intended custom-pet flow is:

```text
references → identity board → canonical master → action families
           → local normalization/QA → user preview → atomic install
```

This resumable Studio workflow is now implemented for the four-action starter
pack. Paid visual generation remains user-triggered; the app never silently
spends, retries, or installs.

### Full-page journal

The ↗ button in Today renders the day timeline, complete lists, and week
heatmap as a standalone HTML page in the browser. It writes one dated file to
`~/Library/Application Support/Mimo/exports/journal-YYYY-MM-DD.html`; opening
it again updates that file instead of creating duplicates.

## Repository map

- `mac/` — native app, runtime, Studio, tests, action tooling, and curated assets.
- `docs/companion/` — architecture decisions, generation research, roadmap,
  current status, archived handoff, and integration plan.
- `mac/evals/` — fixed DIY eval datasets, gates, round records, and runner.
- `skills/mimo-animate-pet/` — reproducible hybrid action-generation workflow.
- `artifacts/wan/README.md` — retained-run layout; generated runs stay local and
  are intentionally ignored by Git.
- `index.html`, `styles.css`, `js/` — original browser concept demo.

Large generated intermediates under `output/`, Wan run outputs, retired walk experiments,
build products, and raw personal reference images are local-only.

## Archived browser concept demo

The original two-minute walkthrough is a historical design archive, not a
release surface. It intentionally preserves the retired quest/XP/flame concept:

```bash
python3 -m http.server 5199 --directory .
# open http://localhost:5199
```

- `index.html` — desktop shell, familiar SVG, overlays
- `styles.css` — all theming; familiar states are CSS palettes on `[data-state]`
- `js/windows.js` — fake app windows (VS Code, Terminal, KiCad, paper, Notion, X, Shorts)
- `js/familiar.js` — creature state machine, resources, pickups, speech bubble
- `js/demo.js` — the 7-scene scripted concept demo
- `js/questmap.js` — daily quest map overlay
- `js/main.js` — app switching, sandbox focus engine, boot
