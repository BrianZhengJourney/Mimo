# Mimo 米墨

A local-first macOS work companion that **feeds on focus, reflects distraction,
and remembers lost context**.

Mimo combines a quiet desktop familiar, an ambient focus journal, and a studio
for turning a person, pet, or original character into a custom companion.

## Status

**v0.2 Alpha · release baseline in progress (2026-07-27).**

The repository has moved beyond the original browser concept:

- Native AppKit/CALayer companion with alpha hit testing, HiDPI rendering,
  drag/throw physics, screen surfaces, gaze, and data-driven behavior packs.
- Local app/browser activity classification, focus quests, context restore,
  daily journal, week view, and Markdown/HTML export.
- Mimo Studio reference preprocessing, canonical character generation,
  expression assets, provider abstraction, generation ledger, and recovery.
- Generated action strips can be safely imported, previewed on the desktop,
  hard-QA checked, and explicitly installed into a custom pet manifest.
- Action generation itself is still an external/experimental production step.
  Bringing it into the Studio is the next product milestone.

See the [custom pet integration plan](docs/companion/11-custom-pet-integration.md)
and [current handoff](docs/companion/SESSION-HANDOFF.md).

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

The first three stages and the final import/install seam exist. The next
milestone connects them into one resumable Studio workflow.

### Exports

- `◐ → Export today's journal` — markdown to
  `~/Library/Application Support/Mimo/exports/journal-YYYY-MM-DD.md`
  (+ clipboard). `◐ → Open journal as page ↗` renders the full journal
  (strip, quest log, complete lists, week heatmap) as a standalone HTML page
  in the browser.
- Exports are **idempotent**: one dated file per day, newer exports overwrite
  older ones. The same rule applies to Notion pushes — a day page
  ("Focus Journal — <date>") lives under the current week's Reflection page
  and is **updated in place** (`replace_content`) when newer data exists,
  never duplicated.

## Repository map

- `mac/` — native app, runtime, Studio, tests, action tooling, and curated assets.
- `docs/companion/` — architecture decisions, generation research, roadmap,
  handoff, and integration plan.
- `skills/mimo-animate-pet/` — reproducible hybrid action-generation workflow.
- `artifacts/wan/README.md` — retained-run layout; generated runs stay local and
  are intentionally ignored by Git.
- `index.html`, `styles.css`, `js/` — original browser concept demo.

Large generated intermediates under `output/`, Wan run outputs, walk experiments,
build products, and raw personal reference images are local-only.

## Browser concept demo

The original two-minute concept walkthrough remains useful for product demos:

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
