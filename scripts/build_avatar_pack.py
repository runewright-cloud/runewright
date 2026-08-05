#!/usr/bin/env python3
"""Transcodes the raw Svetlana Kushnariova character sheets (assets/art/, gitignored --
same convention as build_art_pack.py / build_hex_terrain.py) into the shipped wizard
avatar pack:

    assets/art_pack/avatars/avatar_atlas.png       (one RGBA atlas, all characters' walk blocks)
    assets/art_pack/avatars/avatar_portraits.png   (one RGBA atlas, all characters' portraits)
    assets/art_pack/avatars/ATTRIBUTION.md         (provenance + licence record)
    lib/ui/avatars/avatar_catalog.g.dart           (generated Dart catalog)

The catalog is emitted as Dart rather than JSON on purpose: a CustomPainter needs the
cell lookup *synchronously* during paint, and the data is a few dozen static rows.
Only the atlases are async asset loads.

── Source format ────────────────────────────────────────────────────────────────

Each source sheet is an RPG Maker 2000 charset: a palette image whose left 72x128 block
is a 3-column x 4-row grid of 24x32 walk frames, followed on the right by a portrait.
Palette index 0 is the transparency key (teal 0,117,117); the key is hard-edged
(indexed pixel art, no antialiasing), which is why the runtime draws the walk atlas with
FilterQuality.none.

Row order is RM2000's, NOT RPG Maker XP's: **up, right, down, left**. Verified against
the art, not assumed -- row 2 is the only row showing a face, and rows 1/3 are
horizontal mirrors of each other. Column order is step / stand / step, so column 1 is
the idle pose. See AvatarFacing in lib/ui/avatars/avatar_sprites.dart.

Note the key colour also appears as a legitimate art colour inside the *portrait*
region of several sheets, so the key is only ever applied to the 72x128 walk block --
portrait cells ship fully opaque (docs/AVATAR_PICKER_PLAN.md D2).

Deterministic and idempotent: output is a pure function of the input sheets.

Usage: python3 scripts/build_avatar_pack.py
Optional: AVATAR_PORTRAIT_CONTACT_DIR=/tmp/avatars to also write a 2x contact sheet
for eyeballing all portraits at once (docs/AVATAR_PICKER_PLAN.md §3.4).
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
from collections import Counter

from PIL import Image, ImageDraw

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(
    REPO_ROOT, "assets", "art", "24x32-characters-big-pack-by-Svetlana-Kushnariova"
)
OUT_DIR = os.path.join(REPO_ROOT, "assets", "art_pack", "avatars")
OUT_ATLAS = os.path.join(OUT_DIR, "avatar_atlas.png")
OUT_PORTRAITS = os.path.join(OUT_DIR, "avatar_portraits.png")
OUT_ATTRIBUTION = os.path.join(OUT_DIR, "ATTRIBUTION.md")
OUT_DART = os.path.join(REPO_ROOT, "lib", "ui", "avatars", "avatar_catalog.g.dart")

# ── Sheet geometry ────────────────────────────────────────────────────────────
# Measured from the sources, not assumed (every sheet in the pack agrees).
FRAME_W, FRAME_H = 24, 32
COLS, ROWS = 3, 4
BLOCK_W, BLOCK_H = FRAME_W * COLS, FRAME_H * ROWS  # 72 x 128 walk block
KEY_INDEX = 0                                      # palette index 0 == teal key
KEY_RGB = (0, 117, 117)
BLEED_PASSES = 2                                   # RGB dilation into the margin

# Player-selectable source directories. Monsters are included by request (Soren,
# 2026-08-03, docs/AVATAR_PICKER_PLAN.md D1) -- appended last so every existing
# hero/NPC id keeps its current atlas cell (see ATLAS_COLS packing below).
SOURCE_SUBDIRS = ["Heroes", "NPC", "Monsters"]

# Atlas packing: characters laid out left-to-right, top-to-bottom, in the same
# order for both the walk atlas and the portrait atlas.
ATLAS_COLS = 6

# ── Portrait geometry ─────────────────────────────────────────────────────────
PORTRAIT_CELL = 96
# Grey sheet-background colour surrounding the portrait box on all but two
# sheets (measured across all 53 sources, docs/AVATAR_PICKER_PLAN.md §3.3).
PORTRAIT_MARGIN_BG = (107, 138, 139)
PORTRAIT_MIN_SIDE = 32
# Hand-measured overrides for sheets the generic detection rule can't handle --
# see docs/AVATAR_PICKER_PLAN.md §3.3 D4/table for why each one is irregular.
# Rect is (x, y, w, h) in source-sheet pixel coordinates.
PORTRAIT_OVERRIDES = {
    "Flower-01.png": (72, 0, 81, 90),
    "Mermaid_01.bmp": (13, 181, 63, 62),
}


def slug(stem: str) -> str:
    """`NPC_F-(Amanda)` -> `npc_f_amanda`. Stable id; never regenerate differently."""
    s = re.sub(r"[^A-Za-z0-9]+", "_", stem).strip("_").lower()
    return re.sub(r"_+", "_", s)


def display_name(stem: str) -> str:
    """`Townfolk-Adult-F-001` -> `Townfolk Adult F 001` — a legible default label."""
    s = re.sub(r"[^A-Za-z0-9]+", " ", stem).strip()
    return re.sub(r"\s+", " ", s)


def load_walk_block(src: Image.Image, path: str) -> Image.Image:
    """Crops the 72x128 walk block and keys palette index 0 out to real alpha."""
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


def find_portrait_rect(rgb: Image.Image, path: str) -> tuple[int, int, int, int]:
    """Locates the portrait box in sheet coordinates (docs/AVATAR_PICKER_PLAN.md §3.3).

    Detection rule: the portrait box is the bounding box of key-teal pixels within
    x >= BLOCK_W -- the box's interior is key teal, the surrounding margin is the sheet
    background grey, and any pixel-font caption underneath is white/black, so it's
    excluded automatically. Falls back to a hand-measured override when the sheet has
    no grey margin to distinguish (whole background is already key teal).
    """
    basename = os.path.basename(path)
    if basename in PORTRAIT_OVERRIDES:
        return PORTRAIT_OVERRIDES[basename]

    w, h = rgb.size
    region = rgb.crop((BLOCK_W, 0, w, h))
    rw, rh = region.size
    pixels = region.load()

    bg = Counter(region.getdata()).most_common(1)[0][0]
    if bg == KEY_RGB:
        raise SystemExit(
            f"{path}: portrait region has no grey margin (background is already key "
            "teal) -- add a PORTRAIT_OVERRIDES entry with a hand-measured rect"
        )

    min_x = min_y = max_x = max_y = None
    for y in range(rh):
        for x in range(rw):
            if pixels[x, y] == KEY_RGB:
                if min_x is None or x < min_x:
                    min_x = x
                if max_x is None or x > max_x:
                    max_x = x
                if min_y is None or y < min_y:
                    min_y = y
                if max_y is None or y > max_y:
                    max_y = y
    if min_x is None:
        raise SystemExit(f"{path}: no key-teal pixels found in the portrait region")

    return (BLOCK_W + min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


def validate_portrait_rect(rect: tuple[int, int, int, int], path: str, sheet_size: tuple[int, int]) -> None:
    x, y, w, h = rect
    sw, sh = sheet_size
    if w < PORTRAIT_MIN_SIDE or h < PORTRAIT_MIN_SIDE:
        raise SystemExit(f"{path}: detected portrait rect {rect} is smaller than {PORTRAIT_MIN_SIDE}x{PORTRAIT_MIN_SIDE}")
    if w > PORTRAIT_CELL or h > PORTRAIT_CELL:
        raise SystemExit(f"{path}: detected portrait rect {rect} is larger than {PORTRAIT_CELL}x{PORTRAIT_CELL}")
    if x < 0 or y < 0 or x + w > sw or y + h > sh:
        raise SystemExit(f"{path}: detected portrait rect {rect} falls outside the sheet {sheet_size}")


def make_portrait_cell(rgb: Image.Image, rect: tuple[int, int, int, int]) -> Image.Image:
    """Crops [rect] and pastes it centred into an opaque PORTRAIT_CELL square, padded
    with key teal (D2/D3: no colour-keying, no scaling -- relative sizes are art)."""
    x, y, w, h = rect
    crop = rgb.crop((x, y, x + w, y + h)).convert("RGBA")
    cell = Image.new("RGBA", (PORTRAIT_CELL, PORTRAIT_CELL), (*KEY_RGB, 255))
    cell.paste(crop, ((PORTRAIT_CELL - w) // 2, (PORTRAIT_CELL - h) // 2))
    return cell


def write_contact_sheet(cells: list[Image.Image], ids: list[str], out_dir: str) -> None:
    """Eyeball aid (docs/AVATAR_PICKER_PLAN.md §3.4): the whole portrait atlas at 2x
    with each cell's id printed underneath. Never shipped in assets/; opt-in via
    AVATAR_PORTRAIT_CONTACT_DIR."""
    scale = 2
    label_h = 14
    cell_size = PORTRAIT_CELL * scale
    cols = ATLAS_COLS
    rows = (len(cells) + cols - 1) // cols
    sheet = Image.new(
        "RGBA", (cols * cell_size, rows * (cell_size + label_h)), (255, 255, 255, 255)
    )
    draw = ImageDraw.Draw(sheet)
    for i, (cell, ident) in enumerate(zip(cells, ids)):
        col, row = i % cols, i // cols
        x, y = col * cell_size, row * (cell_size + label_h)
        sheet.paste(cell.resize((cell_size, cell_size), Image.NEAREST), (x, y))
        draw.text((x + 2, y + cell_size + 1), ident, fill=(0, 0, 0, 255))
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "avatar_portraits_contact.png")
    sheet.save(path)
    print(f"wrote {path}")


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
            if not (name.lower().endswith(".png") or name.lower().endswith(".bmp")):
                continue
            entries.append((subdir, os.path.join(d, name), os.path.splitext(name)[0]))

    if not entries:
        print("no source sheets found", file=sys.stderr)
        return 1

    walk_rows = (len(entries) + ATLAS_COLS - 1) // ATLAS_COLS
    atlas = Image.new(
        "RGBA", (ATLAS_COLS * BLOCK_W, walk_rows * BLOCK_H), (0, 0, 0, 0)
    )
    portrait_rows = (len(entries) + ATLAS_COLS - 1) // ATLAS_COLS
    portraits = Image.new(
        "RGBA", (ATLAS_COLS * PORTRAIT_CELL, portrait_rows * PORTRAIT_CELL), (0, 0, 0, 0)
    )

    catalog = []
    seen_ids = set()
    contact_cells = []
    contact_ids = []
    for i, (subdir, path, stem) in enumerate(entries):
        src = Image.open(path)
        block = bleed(load_walk_block(src, path), BLEED_PASSES)
        col, row = i % ATLAS_COLS, i // ATLAS_COLS
        atlas.paste(block, (col * BLOCK_W, row * BLOCK_H))

        rgb = src.convert("RGB")
        portrait_rect = find_portrait_rect(rgb, path)
        validate_portrait_rect(portrait_rect, path, src.size)
        portrait_cell = make_portrait_cell(rgb, portrait_rect)
        portraits.paste(portrait_cell, (col * PORTRAIT_CELL, row * PORTRAIT_CELL))
        contact_cells.append(portrait_cell)

        ident = slug(stem)
        if ident in seen_ids:
            print(f"duplicate avatar id {ident!r} from {path}", file=sys.stderr)
            return 1
        seen_ids.add(ident)
        contact_ids.append(ident)
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
    portraits.save(OUT_PORTRAITS, optimize=True)

    os.makedirs(os.path.dirname(OUT_DART), exist_ok=True)
    with open(OUT_DART, "w") as f:
        f.write(dart_catalog(catalog, atlas.size, portraits.size))

    with open(OUT_ATTRIBUTION, "w") as f:
        f.write(attribution(catalog, atlas.size, portraits.size))

    print(f"wrote {OUT_ATLAS} ({atlas.width}x{atlas.height}, {len(catalog)} avatars)")
    print(f"wrote {OUT_PORTRAITS} ({portraits.width}x{portraits.height})")
    print(f"wrote {OUT_DART}")
    print(f"wrote {OUT_ATTRIBUTION}")

    contact_dir = os.environ.get("AVATAR_PORTRAIT_CONTACT_DIR")
    if contact_dir:
        write_contact_sheet(contact_cells, contact_ids, contact_dir)

    return 0


def dart_catalog(catalog, atlas_size, portrait_size) -> str:
    rows = "\n".join(
        "  AvatarArt(\n"
        f"    id: '{c['id']}',\n"
        f"    name: '{c['name']}',\n"
        f"    category: AvatarCategory.{c['category']},\n"
        f"    atlasCol: {c['col']},\n"
        f"    atlasRow: {c['row']},\n"
        f"    portraitCol: {c['col']},\n"
        f"    portraitRow: {c['row']},\n"
        "  ),"
        for c in catalog
    )
    return f"""// SPDX-License-Identifier: GPL-3.0-or-later
//
// GENERATED FILE — DO NOT EDIT BY HAND.
// Regenerate with: python3 scripts/build_avatar_pack.py
//
// The shipped wizard-avatar catalog: one row per character in
// assets/art_pack/avatars/avatar_atlas.png ({atlas_size[0]}x{atlas_size[1]}), with a
// matching portrait cell in assets/art_pack/avatars/avatar_portraits.png
// ({portrait_size[0]}x{portrait_size[1]}) at the same col/row. Art provenance and
// licence are recorded in assets/art_pack/avatars/ATTRIBUTION.md.

part of 'avatar_sprites.dart';

/// Atlas dimensions, for the source-rect maths in [AvatarAtlas].
const int kAvatarAtlasWidth = {atlas_size[0]};
const int kAvatarAtlasHeight = {atlas_size[1]};

/// Portrait atlas dimensions, for the source-rect maths in [AvatarPortraitAtlas].
const int kAvatarPortraitAtlasWidth = {portrait_size[0]};
const int kAvatarPortraitAtlasHeight = {portrait_size[1]};

/// Every avatar shipped in the pack, in stable catalog order. Ids are stable
/// across regeneration and are what a player's avatar choice is persisted as —
/// never renumber or rename one without a migration.
const List<AvatarArt> kAvatarCatalog = [
{rows}
];
"""


def attribution(catalog, atlas_size, portrait_size) -> str:
    rows = "\n".join(
        f"| `{c['id']}` | {c['name']} | {c['category']} | `{os.path.basename(c['source'])}` | `{c['sha256'][:16]}…` |"
        for c in catalog
    )
    return f"""# Attribution — 24x32 characters (wizard avatars)

This directory contains a derived form of third-party artwork: the walk blocks are
cropped, colour-keyed to real alpha and edge-bled, and the portraits are cropped
uncropped-art (opaque, not colour-keyed) by `scripts/build_avatar_pack.py`. This file
is the authoritative provenance record.

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

`avatar_atlas.png` is {atlas_size[0]}x{atlas_size[1]} RGBA. Each character occupies one 72x128 cell,
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

`avatar_portraits.png` is {portrait_size[0]}x{portrait_size[1]} RGBA. Each character occupies one
96x96 cell at the same col/row as its walk-atlas cell, packed left-to-right /
top-to-bottom in the same catalog order. Portraits are **uncropped source art**,
pad-centred with the sheet's own background where the source is smaller than the
cell, and ship fully **opaque** — unlike the walk atlas, they are not colour-keyed
(the transparency key colour also appears as legitimate art colour inside several
portraits, so keying would punch holes in hair and clothing).

`lib/ui/avatars/avatar_catalog.g.dart` is generated alongside both atlases and is the
canonical id → cell mapping.

## Characters

| id | name | category | source sheet | source sha256 |
|---|---|---|---|---|
{rows}
"""


if __name__ == "__main__":
    raise SystemExit(main())
