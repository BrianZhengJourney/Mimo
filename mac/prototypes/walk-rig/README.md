# Walk rig prototype (throwaway)

> Archived experiment, checked 2026-08-31. It never modifies the current Mimo runtime or installed character.

Question: can a deterministic 8-phase, support-foot-aware 2D rig produce a more
believable walk cycle than generated in-between images?

Run once:

```bash
/opt/anaconda3/bin/python3 mac/prototypes/walk-rig/generate.py
```

Open `output/index.html?variant=C`. Use `←` / `→` to switch between:

- A — gait mechanics and planted-foot state
- B — 24-frame paper-doll rig using the current character's upper body
- C — old generated frames versus the authored rig

This does not modify or install the active Mimo character.
