#!/usr/bin/env python3
"""Transcodes the raw Screaming Brain Studios hex-tile sheet (assets/art/, gitignored --
same convention as build_art_pack.py) into the shipped battle-scenery atlas:

    assets/art_pack/terrain/hex_terrain_atlas.png   (18-tile RGBA atlas, 6x3)
    assets/art_pack/terrain/ATTRIBUTION.md          (provenance record)

The source sheet is an RGB PNG with a hard colour key (teal #008080) and no alpha, so
it cannot be drawn by Flutter as-is. This script does three things the runtime should
not have to:

  1. **Keys out the teal** and replaces it with a real alpha channel.
  2. **Rebuilds the edge alpha analytically.** The source key is hard-edged (no
     antialiasing), which reads as jaggies once the tiles are scaled to hex size. We
     know the exact silhouette -- a flat-top hex 128 wide x 128 tall extruded 16px
     downward -- so alpha is recomputed as supersampled polygon coverage. Because the
     hexes tessellate exactly, complementary coverage along shared edges means adjacent
     tiles composite seam-free.
  3. **Bleeds RGB outward into the transparent margin.** Bilinear filtering at draw
     time samples just outside the silhouette; without a bleed it would pull the teal
     key in as a halo.

Deterministic and idempotent: output is a pure function of the input sheet.

Usage: python3 scripts/build_hex_terrain.py
"""

from __future__ import annotations

import hashlib
import os
import sys

from PIL import Image

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(
    REPO_ROOT, "assets", "art", "sbs_-_realistic_hex_tiles",
    "Bonus", "Hex Terrain 1 - 128x144.png",
)
OUT_DIR = os.path.join(REPO_ROOT, "assets", "art_pack", "terrain")
OUT_ATLAS = os.path.join(OUT_DIR, "hex_terrain_atlas.png")
OUT_ATTRIBUTION = os.path.join(OUT_DIR, "ATTRIBUTION.md")

# ── Sheet geometry ────────────────────────────────────────────────────────────
# Measured from the source, not assumed. See the module docstring.
TILE_W, TILE_H = 128, 144
COLS, ROWS = 6, 3
KEY = (0, 128, 128)          # teal colour key, exact match (source has no AA)
FACE_H = 128                 # top-face hex height; rows 128..143 are the extrusion
EXTRUDE = TILE_H - FACE_H    # 16px straight-down extrusion

# Silhouette = the flat-top hex face unioned with itself translated down EXTRUDE.
SILHOUETTE = [
    (32, 0), (96, 0), (128, 64), (128, 64 + EXTRUDE),
    (96, FACE_H + EXTRUDE), (32, FACE_H + EXTRUDE), (0, 64 + EXTRUDE), (0, 64),
]

SUPERSAMPLE = 8              # 8x8 coverage samples per pixel
BLEED_PASSES = 6             # dilation passes pushing RGB into the transparent margin


def point_in_polygon(x: float, y: float, poly: list[tuple[int, int]]) -> bool:
    """Standard ray-cast test. Polygon is closed implicitly."""
    inside = False
    n = len(poly)
    for i in range(n):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % n]
        if (y0 > y) != (y1 > y):
            xc = x0 + (y - y0) * (x1 - x0) / (y1 - y0)
            if x < xc:
                inside = not inside
    return inside


def build_coverage_mask() -> list[int]:
    """Supersampled coverage alpha for the tile silhouette, 0..255, row-major.

    Identical for all 18 tiles, so it is computed once and reused.
    """
    mask = [0] * (TILE_W * TILE_H)
    step = 1.0 / SUPERSAMPLE
    offsets = [(i + 0.5) * step for i in range(SUPERSAMPLE)]
    for py in range(TILE_H):
        for px in range(TILE_W):
            hits = 0
            for oy in offsets:
                for ox in offsets:
                    if point_in_polygon(px + ox, py + oy, SILHOUETTE):
                        hits += 1
            mask[py * TILE_W + px] = round(255 * hits / (SUPERSAMPLE * SUPERSAMPLE))
    return mask


def bleed_rgb(rgb: list[tuple[int, int, int]], known: list[bool]) -> None:
    """Dilate RGB outward into unknown (keyed-out) pixels, in place.

    Each pass gives every unknown pixel with known neighbours the average of those
    neighbours, then marks it known. Prevents the teal key bleeding in under bilinear
    filtering at draw time.
    """
    for _ in range(BLEED_PASSES):
        writes = []
        for y in range(TILE_H):
            for x in range(TILE_W):
                i = y * TILE_W + x
                if known[i]:
                    continue
                r = g = b = n = 0
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        nx, ny = x + dx, y + dy
                        if not (0 <= nx < TILE_W and 0 <= ny < TILE_H):
                            continue
                        j = ny * TILE_W + nx
                        if not known[j]:
                            continue
                        r += rgb[j][0]
                        g += rgb[j][1]
                        b += rgb[j][2]
                        n += 1
                if n:
                    writes.append((i, (r // n, g // n, b // n)))
        if not writes:
            return
        for i, c in writes:
            rgb[i] = c
            known[i] = True


def main() -> int:
    if not os.path.isfile(SOURCE):
        sys.stderr.write(
            f"error: source sheet not found:\n  {SOURCE}\n"
            "Unpack the Screaming Brain Studios hex tile pack under assets/art/ first "
            "(see assets/art_pack/terrain/ATTRIBUTION.md).\n"
        )
        return 1

    raw = open(SOURCE, "rb").read()
    digest = hashlib.sha256(raw).hexdigest()

    sheet = Image.open(SOURCE).convert("RGB")
    if sheet.size != (COLS * TILE_W, ROWS * TILE_H):
        sys.stderr.write(
            f"error: expected a {COLS * TILE_W}x{ROWS * TILE_H} sheet, got {sheet.size}. "
            "The tile pack layout changed -- re-measure before regenerating.\n"
        )
        return 1

    print(f"source : {os.path.relpath(SOURCE, REPO_ROOT)}")
    print(f"sha256 : {digest}")
    print(f"mask   : building {SUPERSAMPLE}x{SUPERSAMPLE} supersampled coverage ...")
    mask = build_coverage_mask()

    out = Image.new("RGBA", sheet.size, (0, 0, 0, 0))

    for index in range(COLS * ROWS):
        col, row = index % COLS, index // COLS
        tile = sheet.crop(
            (col * TILE_W, row * TILE_H, col * TILE_W + TILE_W, row * TILE_H + TILE_H)
        )
        px = list(tile.getdata())
        known = [p != KEY for p in px]
        rgb = list(px)
        bleed_rgb(rgb, known)
        rgba = [
            (rgb[i][0], rgb[i][1], rgb[i][2], mask[i]) for i in range(TILE_W * TILE_H)
        ]
        outTile = Image.new("RGBA", (TILE_W, TILE_H))
        outTile.putdata(rgba)
        out.paste(outTile, (col * TILE_W, row * TILE_H))
        print(f"  tile {index:2d}  ({col},{row})  keyed + bled")

    os.makedirs(OUT_DIR, exist_ok=True)
    out.save(OUT_ATLAS, optimize=True)
    print(f"wrote  : {os.path.relpath(OUT_ATLAS, REPO_ROOT)} ({os.path.getsize(OUT_ATLAS)} bytes)")

    with open(OUT_ATTRIBUTION, "w") as f:
        f.write(ATTRIBUTION_TEMPLATE.format(digest=digest, bytes=len(raw)))
    print(f"wrote  : {os.path.relpath(OUT_ATTRIBUTION, REPO_ROOT)}")
    return 0


ATTRIBUTION_TEMPLATE = """\
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
| Size | {bytes} bytes |
| SHA-256 | `{digest}` |

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
"""


if __name__ == "__main__":
    raise SystemExit(main())
