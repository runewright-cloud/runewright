# Attribution — Realistic Hex Tiles (battle scenery)

This directory contains a derived form of third-party artwork: the raw sheet is keyed,
alpha-antialiased and edge-bled by `scripts/build_hex_terrain.py`. This file is the
authoritative provenance record.

## Source

**SBS - Realistic Hex Tiles**, by **Screaming Brain Studios**.

Licence, verbatim from the pack's `License.txt`:

> All Screaming Brain Studios assets have been released under the CC0/Public Domain
> License. You are free to use these assets in any and all projects, commercial or
> non-commercial, with no restrictions, and can be released with or without credit.

CC0 imposes no attribution requirement; this record exists for our own provenance
tracking and to keep the regeneration inputs pinned.

| Field | Value |
|---|---|
| Sheet | `Bonus/Hex Terrain 1 - 128x144.png` |
| Size | 537595 bytes |
| SHA-256 | `3482dd2d73d591e0f8669ba40eb3b7ab799df4005b5403631522428f52c4b0f0` |

Raw sources live under `assets/art/` and are **gitignored** (see `.gitignore`); only
this derived directory is tracked. Regenerate with:

    python3 scripts/build_hex_terrain.py

## Atlas layout

`hex_terrain_atlas.png` is 768x432 RGBA — an 18-tile atlas, 6 columns x 3 rows, each
cell 128x144. Each cell holds a flat-top hex **top face 128 wide x 128 tall** (rows
0..127) plus a **16px straight-down extrusion** (rows 128..143) that overlaps the tile
behind it when drawn back-to-front.

Tiling step: dx = 96, dy = 128, odd-column y-offset 64.

Atlas index (row-major) maps to `SceneryTile` in `lib/ui/scenery/scenery_tile.dart`;
that enum is the canonical index → terrain mapping.
