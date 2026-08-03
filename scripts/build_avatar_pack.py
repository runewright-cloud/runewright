#!/usr/bin/env python3
"""Transcodes the raw Svetlana Kushnariova character sheets (assets/art/, gitignored --
same convention as build_art_pack.py / build_hex_terrain.py) into the shipped wizard
avatar pack:

    assets/art_pack/avatars/avatar_atlas.png   (one RGBA atlas, all characters)
    assets/art_pack/avatars/ATTRIBUTION.md     (provenance + licence record)
    lib/ui/avatars/avatar_catalog.g.dart       (generated Dart catalog)

The catalog is emitted as Dart rather than JSON on purpose: a CustomPainter needs the
cell lookup *synchronously* during paint, and the data is a few dozen static rows.
Only the atlas is an async asset load.

── Source format ────────────────────────────────────────────────────────────────

Each source PNG is an RPG Maker 2000 charset: a palette image whose left 72x128 block
is a 3-column x 4-row grid of 24x32 walk frames, followed on the right by a portrait
that this pack does not use. Palette index 0 is the transparency key (teal 0,117,117);
the key is hard-edged (indexed pixel art, no antialiasing), which is why the runtime
draws these with FilterQuality.none.

Row order is RM2000's, NOT RPG Maker XP's: **up, right, down, left**. Verified against
the art, not assumed -- row 2 is the only row showing a face, and rows 1/3 are
horizontal mirrors of each other. Column order is step / stand / step, so column 1 is
the idle pose. See AvatarFacing in lib/ui/avatars/avatar_sprites.dart.

Note the key colour also appears as a legitimate art colour inside the *portrait*
region of several sheets, so the key is only ever applied to the 72x128 walk block.

Deterministic and idempotent: output is a pure function of the input sheets.

Usage: python3 scripts/build_avatar_pack.py
"""

from __future__ import annotations

import hashlib
import os
import re
import sys

from PIL import Image

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(
    REPO_ROOT, "assets", "art", "24x32-characters-big-pack-by-Svetlana-Kushnariova"
)
OUT_DIR = os.path.join(REPO_ROOT, "assets", "art_pack", "avatars")
OUT_ATLAS = os.path.join(OUT_DIR, "avatar_atlas.png")
OUT_ATTRIBUTION = os.path.join(OUT_DIR, "ATTRIBUTION.md")
OUT_DART = os.path.join(REPO_ROOT, "lib", "ui", "avatars", "avatar_catalog.g.dart")

# ── Sheet geometry ────────────────────────────────────────────────────────────
# Measured from the sources, not assumed (every sheet in the pack agrees).
FRAME_W, FRAME_H = 24, 32
COLS, ROWS = 3, 4
BLOCK_W, BLOCK_H = FRAME_W * COLS, FRAME_H * ROWS  # 72 x 128 walk block
KEY_INDEX = 0                                      # palette index 0 == teal key
BLEED_PASSES = 2                                   # RGB dilation into the margin

# Characters wear a person, not a mushroom: Monsters/ is deliberately excluded.
# These are the directories offered as player avatars.
SOURCE_SUBDIRS = ["Heroes", "NPC"]

# Atlas packing: characters laid out left-to-right, top-to-bottom.
ATLAS_COLS = 6


def slug(stem: str) -> str:
    """`NPC_F-(Amanda)` -> `npc_f_amanda`. Stable id; never regenerate differently."""
    s = re.sub(r"[^A-Za-z0-9]+", "_", stem).strip("_").lower()
    return re.sub(r"_+", "_", s)


def display_name(stem: str) -> str:
    """`Townfolk-Adult-F-001` -> `Townfolk Adult F 001` — a legible default label."""
    s = re.sub(r"[^A-Za-z0-9]+", " ", stem).strip()
    return re.sub(r"\s+", " ", s)


def load_walk_block(path: str) -> Image.Image:
    """Crops the 72x128 walk block and keys palette index 0 out to real alpha."""
    src = Image.open(path)
    if src.mode != "P":
        raise SystemExit(f"{path}: expected a palette image, got {src.mode}")
    if src.width < BLOCK_W or src.height < BLOCK_H:
        raise SystemExit(f"{path}: sheet is {src.size}, smaller than the walk block")

    block = src.crop((0, 0, BLOCK_W, BLOCK_H))
    indices = block.load()
    rgb = block.convert("RGB")
    out = Image.new("RGBA", (BLOCK_W, BLOCK_H), (0, 0, 0, 0))
    px = out.load()
    rgb_px = rgb.load()
    for y in range(BLOCK_H):
        for x in range(BLOCK_W):
            if indices[x, y] == KEY_INDEX:
                continue
            r, g, b = rgb_px[x, y]
            px[x, y] = (r, g, b, 255)
    return out


def bleed(img: Image.Image, passes: int) -> Image.Image:
    """Pushes RGB outward into transparent pixels so a filtered draw can't sample the
    key colour as a halo. Alpha is untouched; only the hidden RGB changes."""
    w, h = img.size
    px = img.load()
    for _ in range(passes):
        writes = []
        for y in range(h):
            for x in range(w):
                if px[x, y][3] != 0:
                    continue
                acc, n = [0, 0, 0], 0
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3] != 0:
                            acc[0] += px[nx, ny][0]
                            acc[1] += px[nx, ny][1]
                            acc[2] += px[nx, ny][2]
                            n += 1
                if n:
                    writes.append((x, y, (acc[0] // n, acc[1] // n, acc[2] // n, 0)))
        if not writes:
            break
        for x, y, v in writes:
            px[x, y] = v
    return img


def main() -> int:
    if not os.path.isdir(SOURCE_DIR):
        print(f"missing raw source: {SOURCE_DIR}", file=sys.stderr)
        print("Unpack the OpenGameArt archive there — see the ATTRIBUTION.md it "
              "generates for provenance.", file=sys.stderr)
        return 1

    entries = []
    for subdir in SOURCE_SUBDIRS:
        d = os.path.join(SOURCE_DIR, subdir)
        if not os.path.isdir(d):
            print(f"missing source subdir: {d}", file=sys.stderr)
            return 1
        for name in sorted(os.listdir(d)):
            if not name.lower().endswith(".png"):
                continue  # the one .bmp in the pack is a monster, and excluded anyway
            entries.append((subdir, os.path.join(d, name), os.path.splitext(name)[0]))

    if not entries:
        print("no source sheets found", file=sys.stderr)
        return 1

    rows = (len(entries) + ATLAS_COLS - 1) // ATLAS_COLS
    atlas = Image.new(
        "RGBA", (ATLAS_COLS * BLOCK_W, rows * BLOCK_H), (0, 0, 0, 0)
    )

    catalog = []
    seen_ids = set()
    for i, (subdir, path, stem) in enumerate(entries):
        block = bleed(load_walk_block(path), BLEED_PASSES)
        col, row = i % ATLAS_COLS, i // ATLAS_COLS
        atlas.paste(block, (col * BLOCK_W, row * BLOCK_H))
        ident = slug(stem)
        if ident in seen_ids:
            print(f"duplicate avatar id {ident!r} from {path}", file=sys.stderr)
            return 1
        seen_ids.add(ident)
        catalog.append(
            {
                "id": ident,
                "name": display_name(stem),
                "category": subdir.lower(),
                "col": col,
                "row": row,
                "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest(),
                "source": os.path.relpath(path, REPO_ROOT),
            }
        )

    os.makedirs(OUT_DIR, exist_ok=True)
    atlas.save(OUT_ATLAS, optimize=True)

    os.makedirs(os.path.dirname(OUT_DART), exist_ok=True)
    with open(OUT_DART, "w") as f:
        f.write(dart_catalog(catalog, atlas.size))

    with open(OUT_ATTRIBUTION, "w") as f:
        f.write(attribution(catalog, atlas.size))

    print(f"wrote {OUT_ATLAS} ({atlas.width}x{atlas.height}, {len(catalog)} avatars)")
    print(f"wrote {OUT_DART}")
    print(f"wrote {OUT_ATTRIBUTION}")
    return 0


def dart_catalog(catalog, size) -> str:
    rows = "\n".join(
        "  AvatarArt(\n"
        f"    id: '{c['id']}',\n"
        f"    name: '{c['name']}',\n"
        f"    category: AvatarCategory.{c['category']},\n"
        f"    atlasCol: {c['col']},\n"
        f"    atlasRow: {c['row']},\n"
        "  ),"
        for c in catalog
    )
    return f"""// SPDX-License-Identifier: GPL-3.0-or-later
//
// GENERATED FILE — DO NOT EDIT BY HAND.
// Regenerate with: python3 scripts/build_avatar_pack.py
//
// The shipped wizard-avatar catalog: one row per character in
// assets/art_pack/avatars/avatar_atlas.png ({size[0]}x{size[1]}). Art provenance and
// licence are recorded in assets/art_pack/avatars/ATTRIBUTION.md.

part of 'avatar_sprites.dart';

/// Atlas dimensions, for the source-rect maths in [AvatarAtlas].
const int kAvatarAtlasWidth = {size[0]};
const int kAvatarAtlasHeight = {size[1]};

/// Every avatar shipped in the pack, in stable catalog order. Ids are stable
/// across regeneration and are what a player's avatar choice is persisted as —
/// never renumber or rename one without a migration.
const List<AvatarArt> kAvatarCatalog = [
{rows}
];
"""


def attribution(catalog, size) -> str:
    rows = "\n".join(
        f"| `{c['id']}` | {c['name']} | {c['category']} | `{os.path.basename(c['source'])}` | `{c['sha256'][:16]}…` |"
        for c in catalog
    )
    return f"""# Attribution — 24x32 characters (wizard avatars)

This directory contains a derived form of third-party artwork: the walk blocks are
cropped, colour-keyed to real alpha and edge-bled by `scripts/build_avatar_pack.py`.
This file is the authoritative provenance record.

## Source

**"[LPC-ish] 24x32 characters with faces (big pack)"**, by
**Svetlana Kushnariova** (*Cabbit*), published on OpenGameArt.

Dual-licensed **CC BY 3.0** (https://creativecommons.org/licenses/by/3.0/) and
**OGA-BY 3.0** (https://opengameart.org/content/oga-by-30-faq), per the OpenGameArt
listing — confirmed 2026-08-03. Attribution is a *requirement* of both, unlike the
CC0 terrain pack. The credit line below must appear in the app's about/credits screen
for any build that ships this directory:

> Character sprites by Svetlana Kushnariova (lana-chan@yandex.ru), licensed
> CC BY 3.0 / OGA-BY 3.0.

Raw sources live under `assets/art/` and are **gitignored** (see `.gitignore`); only
this derived directory is tracked. Regenerate with:

    python3 scripts/build_avatar_pack.py

## Atlas layout

`avatar_atlas.png` is {size[0]}x{size[1]} RGBA. Each character occupies one 72x128 cell,
laid out left-to-right / top-to-bottom in catalog order. Within a cell the frames are
a 3-column x 4-row grid of 24x32 poses:

| Row | Facing | | Column | Pose |
|---|---|---|---|---|
| 0 | up (away from viewer) | | 0 | step A |
| 1 | right | | 1 | **stand / idle** |
| 2 | down (toward viewer) | | 2 | step B |
| 3 | left | | | |

That is the RPG Maker 2000 charset order, *not* RPG Maker XP's. It was verified
against the art rather than assumed — see the build script's docstring.

`lib/ui/avatars/avatar_catalog.g.dart` is generated alongside this atlas and is the
canonical id → cell mapping.

## Characters

| id | name | category | source sheet | source sha256 |
|---|---|---|---|---|
{rows}
"""


if __name__ == "__main__":
    raise SystemExit(main())
