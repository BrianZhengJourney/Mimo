# Mimo Wan artifacts

> Current local retention layout, checked 2026-08-31. Generated runs remain ignored; only contracts and source inputs are versioned.

All retained Mimo/Wan inputs, preprocessing previews, inference outputs,
postprocessed sprites, QA reports, logs, and cost manifests live under this
repository:

```text
artifacts/wan/runs/<job-id>/
  preprocess-attempt-*/
  preprocess-approved/
  output/
  mimo-preview/
  diagnostics/
```

Do not use Downloads, `~/.codex/visualizations`, `/tmp`, or
`~/Library/Application Support` as the canonical location for Mimo/Wan
artifacts. Tools may use temporary working directories internally, but every
retained result must be downloaded or moved back here.

Run artifacts are ignored by Git because they contain generated videos and
large binary images. The source code, immutable driver inputs, and pipeline
contracts remain versioned under `mac/`.
