---
name: browserbro-media
description: "Use when making BrowserBro screenshots, GIFs or videos for README/site. Demo mode only, privacy check."
---

# BrowserBro screenshots, GIFs and videos

## Rules

- **Demo mode only**: `BROWSERBRO_DEMO=1 BROWSERBRO_SUPPORT_DIR=$(mktemp -d)`. Real profiles show personal names and profile photos; they must never appear in committed media.
- Look at every image or GIF frame before committing. Allowed: demo profiles (Work, Personal, Side project), `example.org`/`acme.com` domains. Anything else → redo.
- README media: `docs/media/` (GIF, GitHub doesn't autoplay repo mp4). Site media: `site/assets/media/` (mp4 + poster PNG). Light and dark variants; README uses `<picture>` with `prefers-color-scheme`.
- Keep each GIF under ~4 MB.

## How

- Demo launch args (`--demo-url`, `--demo-pane`, `--demo-point`, `--demo-pick`, `--demo-tour`, …) are documented in `docs/DEMO.md`.
- Capture with `screencapture -v -R x,y,w,h out.mov`; convert with ffmpeg (palette) or `gifski` for GIFs.
- After a site change, check the deployed page at 390 and 1440 px, light and dark, with 0 console errors and no horizontal scroll.
