#!/usr/bin/env python3
"""Transcodes the raw painterly-spell-icons source PNGs (assets/art/, gitignored --
see docs/SPELL_ART_PACK_PLAN.md D-2) into the shipped built-in art pack:

    assets/art_pack/painterly/<original-stem>.webp   (one per spell icon)
    assets/art_pack/painterly/manifest.json          (licence header + per-icon metadata)
    lib/spells/spell_art_pack.dart                    (generated Dart catalogue)

Deterministic and idempotent: re-running with unchanged inputs reproduces byte-identical
output (WebP encode is deterministic for fixed Pillow version/quality/method, and every
other field is a pure function of the filename). Requires the four source archives to
be unpacked under assets/art/ first -- see assets/art_pack/painterly/ATTRIBUTION.md for
exact source URLs/hashes.

Usage: python3 scripts/build_art_pack.py
"""

from __future__ import annotations

import glob
import hashlib
import json
import os
import sys
from dataclasses import dataclass, field

from PIL import Image

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_GLOB = os.path.join(REPO_ROOT, "assets", "art", "painterly-spell-icons-*", "*.png")
OUT_DIR = os.path.join(REPO_ROOT, "assets", "art_pack", "painterly")
MANIFEST_PATH = os.path.join(OUT_DIR, "manifest.json")
DART_OUT_PATH = os.path.join(REPO_ROOT, "lib", "spells", "spell_art_pack.dart")

CANVAS_PX = 256
WEBP_QUALITY = 82
WEBP_METHOD = 6

# ---------------------------------------------------------------------------
# Licence header -- see assets/art_pack/painterly/ATTRIBUTION.md (the authoritative,
# hand-maintained record) and docs/SPELL_ART_PACK_PLAN.md §2 D-1. This is the single
# source of truth D-1 requires: every UI surface reads these strings from the
# generated Dart, none hardcodes them.
# ---------------------------------------------------------------------------
LICENCE = {
    "name": "Painterly Spell Icons",
    "author": "J. W. Bjerk (eleazzaar)",
    "sourceUrls": [
        "https://opengameart.org/content/painterly-spell-icons-part-1",
        "https://opengameart.org/content/painterly-spell-icons-part-2",
        "https://opengameart.org/content/painterly-spell-icons-part-3",
        "https://opengameart.org/content/painterly-spell-icons-part-4",
    ],
    "licence": "CC BY-SA 4.0",
    "licenceUrl": "https://creativecommons.org/licenses/by-sa/4.0/",
    "attribution": (
        "J. W. Bjerk (eleazzaar) -- www.jwbjerk.com/art -- find this and other open "
        "art at: http://opengameart.org"
    ),
    "modifications": (
        "Re-encoded from 256x256 PNG to 256x256 lossy WebP (quality=82, method=6), "
        "RGB (every source icon is fully opaque -- no source PNG has meaningful "
        "transparency, verified programmatically before this pack was built). No "
        "resizing, no cropping, no recolouring, no compositing, no pixel-level "
        "editing. Filenames preserved verbatim."
    ),
}

# ---------------------------------------------------------------------------
# Filename parsing (plan §4 B-2). Closed colour vocabulary: ten real aesthetic
# colours plus five "elemental flavour" words that occupy the same filename slot.
# ---------------------------------------------------------------------------
REAL_COLOURS = {"sky", "acid", "royal", "magenta", "jade", "eerie", "orange", "blue", "red", "grey"}
ELEMENT_WORDS = {"fire", "air", "water", "spirit", "plain"}
COLOUR_VOCAB = REAL_COLOURS | ELEMENT_WORDS

ELEMENTS = ("neutral", "fire", "air", "water", "earth")

# Step 1 of element derivation: an elemental-flavour word anywhere in the trailing
# vocab-token run is explicit and wins outright (plan §4 B-3 precedence #1).
ELEMENT_WORD_TO_ELEMENT = {"fire": "fire", "air": "air", "water": "water", "spirit": "neutral", "plain": "neutral"}

# Step 2: subject override table (plan §4 B-3 precedence #2). "fire-arrows" is added
# beyond the plan's prose list because it is the one subject with a bare, colour-less
# variant (fire-arrows-1.png) -- there is no colour token for a heuristic to read, and
# the subject name is unambiguous, so it must be resolved here rather than falling
# through to step 3.
SUBJECT_OVERRIDE = {
    "fireball": "fire", "explosion": "fire", "fire-arrows": "fire",
    "ice": "water", "fog": "water",
    "wind": "air", "wind-grasp": "air", "air-burst": "air", "haste": "air",
    "lightning": "air", "lighting": "air",
    "rock": "earth", "leaf": "earth", "vines": "earth",
    "runes": "neutral", "enchant": "neutral", "link": "neutral", "protect": "neutral",
    "shielding": "neutral", "heal": "neutral", "evil-eye": "neutral", "horror": "neutral",
}

# Step 3: colour heuristic (plan §4 B-3 precedence #3), covering every real colour not
# otherwise resolved by steps 1-2.
COLOUR_HEURISTIC = {
    "red": "fire", "orange": "fire",
    "sky": "water", "blue": "water",
    "jade": "earth", "acid": "earth",
    "magenta": "neutral", "royal": "neutral", "eerie": "neutral", "grey": "neutral",
}


@dataclass
class IconEntry:
    id: str
    asset: str
    subject: str
    colour: str | None
    level: int
    element: str
    sha256: str
    bytes: int
    warnings: list[str] = field(default_factory=list)


def parse_stem(stem: str) -> tuple[str, str | None, int, list[str]]:
    """Splits a source filename stem (no extension) into (subject, colour, level,
    trailing_vocab_tokens). `colour` is the trailing vocab-token run joined with '-'
    (None if the stem has no trailing vocab token at all -- a parse "failure" per plan
    §4 B-2, kept as the whole stem rather than dropped). `trailing_vocab_tokens`
    preserves left-to-right order for element derivation (precedence #1)."""
    parts = stem.split("-")
    if not parts[-1].isdigit():
        raise ValueError(f"expected a numeric level suffix in {stem!r}, found {parts[-1]!r}")
    level = int(parts[-1])
    rest = parts[:-1]

    trail: list[str] = []
    i = len(rest) - 1
    while i >= 0 and rest[i] in COLOUR_VOCAB:
        trail.insert(0, rest[i])
        i -= 1
    subject = "-".join(rest[: i + 1])

    if not trail:
        # No colour token at all (e.g. "fire-arrows-1") -- the whole remainder is the
        # subject per plan §4 B-2; this is the "logged, never silently dropped" case.
        return stem[: -(len(parts[-1]) + 1)], None, level, []
    return subject, "-".join(trail), level, trail


def derive_element(subject: str, trail: list[str]) -> tuple[str, str | None]:
    """Returns (element, reason) where reason names which precedence step fired, for
    the generation log -- see plan §4 B-3's three-step precedence."""
    for tok in trail:
        if tok in ELEMENT_WORD_TO_ELEMENT:
            return ELEMENT_WORD_TO_ELEMENT[tok], f"explicit element token {tok!r}"
    if subject in SUBJECT_OVERRIDE:
        return SUBJECT_OVERRIDE[subject], f"subject override {subject!r}"
    for tok in trail:
        if tok in COLOUR_HEURISTIC:
            return COLOUR_HEURISTIC[tok], f"colour heuristic {tok!r}"
    return "neutral", None  # should be unreachable -- every vocab token is covered above


def encode_webp(src_path: str, dst_path: str) -> bytes:
    with Image.open(src_path) as im:
        if im.size != (CANVAS_PX, CANVAS_PX):
            raise ValueError(
                f"{src_path}: expected {CANVAS_PX}x{CANVAS_PX}, got {im.size[0]}x{im.size[1]} "
                "-- source pack no longer matches the assumption this script was written "
                "against; resize logic would need to be added, not silently skipped."
            )
        # Every source icon in this pack is fully opaque -- some carry an RGBA plane
        # that is uniformly 255, most are plain RGB with no alpha channel at all
        # (verified across the full pack before this script was written). Encoding as
        # RGB is therefore lossless with respect to what the source actually contains,
        # and keeps the pack's ATTRIBUTION.md modification statement accurate -- it
        # does NOT claim to preserve an alpha channel because there is no meaningful
        # alpha to preserve. If a future source pack introduces real transparency,
        # this assertion catches it instead of silently flattening it away.
        rgba = im.convert("RGBA")
        alpha_extrema = rgba.getchannel("A").getextrema()
        if alpha_extrema != (255, 255):
            raise ValueError(
                f"{src_path}: has non-opaque alpha (extrema={alpha_extrema}) -- this "
                "script assumes every source icon is fully opaque and encodes as RGB. "
                "That assumption no longer holds; add real alpha handling rather than "
                "silently flattening transparency away."
            )
        rgb = rgba.convert("RGB")
        # Fresh Image built from raw pixel data only -- drops any EXIF/metadata chunk
        # the source PNG might carry, same discipline as spell_art_import.dart.
        clean = Image.new("RGB", rgb.size)
        clean.putdata(list(rgb.getdata()))
        clean.save(dst_path, format="WEBP", quality=WEBP_QUALITY, method=WEBP_METHOD)
    with open(dst_path, "rb") as f:
        return f.read()


def main() -> int:
    source_files = sorted(glob.glob(SOURCE_GLOB))
    if not source_files:
        print(f"error: no source PNGs found under {SOURCE_GLOB}", file=sys.stderr)
        print("Unpack the four source archives into assets/art/ first -- see", file=sys.stderr)
        print("assets/art_pack/painterly/ATTRIBUTION.md for source URLs.", file=sys.stderr)
        return 1

    frames = [f for f in source_files if os.path.basename(f).startswith("frame-")]
    icons = [f for f in source_files if f not in frames]
    print(f"Found {len(source_files)} source PNGs: {len(icons)} spell icons, "
          f"{len(frames)} decorative frames.")
    print(f"Skipping {len(frames)} decorative frames -- excluded from v1 per plan §2 D-3.")

    os.makedirs(OUT_DIR, exist_ok=True)
    # Clear stale .webp outputs from a prior run so a renamed/removed source icon
    # doesn't leave an orphaned file behind.
    for stale in glob.glob(os.path.join(OUT_DIR, "*.webp")):
        os.remove(stale)

    entries: list[IconEntry] = []
    seen_ids: set[str] = set()
    fallback_count = 0
    bare_colour_count = 0

    for src_path in icons:
        stem = os.path.splitext(os.path.basename(src_path))[0]
        if stem in seen_ids:
            print(f"error: duplicate id {stem!r} (from {src_path})", file=sys.stderr)
            return 1
        seen_ids.add(stem)

        subject, colour, level, trail = parse_stem(stem)
        element, reason = derive_element(subject, trail)
        if reason is None:
            fallback_count += 1
            print(f"  WARNING: {stem!r} -> element derivation fell through all three "
                  f"precedence steps (subject={subject!r}, trail={trail!r}); defaulted "
                  f"to 'neutral'. This should not happen -- investigate before shipping.",
                  file=sys.stderr)
        if colour is None:
            bare_colour_count += 1

        dst_path = os.path.join(OUT_DIR, f"{stem}.webp")
        webp_bytes = encode_webp(src_path, dst_path)
        digest = hashlib.sha256(webp_bytes).hexdigest()

        entries.append(IconEntry(
            id=stem,
            asset=f"assets/art_pack/painterly/{stem}.webp",
            subject=subject,
            colour=colour,
            level=level,
            element=element,
            sha256=digest,
            bytes=len(webp_bytes),
        ))

    entries.sort(key=lambda e: e.id)

    print(f"Encoded {len(entries)} icons to WebP (quality={WEBP_QUALITY}, "
          f"method={WEBP_METHOD}).")
    print(f"  {bare_colour_count} bare (no colour token) -- expected: fire-arrows only.")
    total_bytes = sum(e.bytes for e in entries)
    print(f"  Total: {total_bytes} bytes ({total_bytes / 1024 / 1024:.2f} MB), "
          f"avg {total_bytes // len(entries)} bytes/icon.")

    elements_seen = {e.element for e in entries}
    unknown = elements_seen - set(ELEMENTS)
    if unknown:
        print(f"error: derived element(s) {unknown} not in the five-element set {ELEMENTS}",
              file=sys.stderr)
        return 1

    manifest = {
        **LICENCE,
        "icons": [
            {
                "id": e.id, "asset": e.asset, "subject": e.subject, "colour": e.colour,
                "level": e.level, "element": e.element, "sha256": e.sha256, "bytes": e.bytes,
            }
            for e in entries
        ],
    }
    with open(MANIFEST_PATH, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"Wrote {MANIFEST_PATH}")

    write_dart(entries)
    print(f"Wrote {DART_OUT_PATH}")
    return 0


def _dart_string(s: str) -> str:
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def _dart_string_or_null(s: str | None) -> str:
    return "null" if s is None else _dart_string(s)


def write_dart(entries: list[IconEntry]) -> None:
    lines = []
    lines.append("// GENERATED FILE -- do not edit by hand.")
    lines.append("// Regenerate with: python3 scripts/build_art_pack.py")
    lines.append("//")
    lines.append("// SPDX-License-Identifier: GPL-3.0-or-later")
    lines.append("//")
    lines.append("// spell_art_pack.dart -- the built-in spell art pack catalogue. Every")
    lines.append("// field here is a pure function of the source filenames in the")
    lines.append("// Painterly Spell Icons pack (assets/art_pack/painterly/ATTRIBUTION.md);")
    lines.append("// see docs/SPELL_ART_PACK_PLAN.md for the derivation rules.")
    lines.append("")
    lines.append("import 'dart:typed_data';")
    lines.append("")
    lines.append("import 'package:flutter/services.dart' show rootBundle;")
    lines.append("")
    lines.append("/// One icon in a built-in art pack.")
    lines.append("class SpellArtPackEntry {")
    lines.append("  const SpellArtPackEntry({")
    lines.append("    required this.id,")
    lines.append("    required this.asset,")
    lines.append("    required this.subject,")
    lines.append("    required this.colour,")
    lines.append("    required this.level,")
    lines.append("    required this.element,")
    lines.append("    required this.sha256,")
    lines.append("    required this.bytes,")
    lines.append("  });")
    lines.append("")
    lines.append("  /// Stable identifier, stored on SpellAsset.artPackId. Equal to the")
    lines.append("  /// original source filename's stem (no extension).")
    lines.append("  final String id;")
    lines.append("")
    lines.append("  /// Asset bundle path, loadable via rootBundle / Image.asset.")
    lines.append("  final String asset;")
    lines.append("")
    lines.append("  /// Filter-label subject, e.g. 'fireball', 'wind-grasp'.")
    lines.append("  final String subject;")
    lines.append("")
    lines.append("  /// Trailing colour-vocabulary token(s) from the filename, joined")
    lines.append("  /// with '-' if more than one (e.g. 'water-air'). Null if the source")
    lines.append("  /// filename had no colour token at all (only 'fire-arrows').")
    lines.append("  final String? colour;")
    lines.append("")
    lines.append("  /// Intensity level from the filename (1, 2, or 3). Cosmetic filter")
    lines.append("  /// dimension only -- never drives formula/manaCost/supremeTags.")
    lines.append("  final int level;")
    lines.append("")
    lines.append("  /// One of 'neutral', 'fire', 'air', 'water', 'earth' -- derived from")
    lines.append("  /// the filename per docs/SPELL_ART_PACK_PLAN.md §4 B-3.")
    lines.append("  final String element;")
    lines.append("")
    lines.append("  /// Hex SHA-256 of the WebP bytes at [asset], unprefixed.")
    lines.append("  final String sha256;")
    lines.append("")
    lines.append("  /// Byte length of the WebP file at [asset].")
    lines.append("  final int bytes;")
    lines.append("}")
    lines.append("")
    lines.append("/// Licence/attribution metadata for a built-in art pack. The single")
    lines.append("/// source of truth every UI surface (picker footer, credits screen)")
    lines.append("/// reads from -- see docs/SPELL_ART_PACK_PLAN.md §2 D-1.")
    lines.append("class SpellArtPackLicence {")
    lines.append("  const SpellArtPackLicence({")
    lines.append("    required this.name,")
    lines.append("    required this.author,")
    lines.append("    required this.sourceUrls,")
    lines.append("    required this.licence,")
    lines.append("    required this.licenceUrl,")
    lines.append("    required this.attribution,")
    lines.append("    required this.modifications,")
    lines.append("  });")
    lines.append("")
    lines.append("  final String name;")
    lines.append("  final String author;")
    lines.append("  final List<String> sourceUrls;")
    lines.append("  final String licence;")
    lines.append("  final String licenceUrl;")
    lines.append("  final String attribution;")
    lines.append("  final String modifications;")
    lines.append("}")
    lines.append("")
    lines.append("const SpellArtPackLicence kPainterlyLicence = SpellArtPackLicence(")
    lines.append(f"  name: {_dart_string(LICENCE['name'])},")
    lines.append(f"  author: {_dart_string(LICENCE['author'])},")
    lines.append("  sourceUrls: [")
    for url in LICENCE["sourceUrls"]:
        lines.append(f"    {_dart_string(url)},")
    lines.append("  ],")
    lines.append(f"  licence: {_dart_string(LICENCE['licence'])},")
    lines.append(f"  licenceUrl: {_dart_string(LICENCE['licenceUrl'])},")
    lines.append(f"  attribution: {_dart_string(LICENCE['attribution'])},")
    lines.append(f"  modifications: {_dart_string(LICENCE['modifications'])},")
    lines.append(");")
    lines.append("")
    lines.append(f"const List<SpellArtPackEntry> kPainterlyPack = [")
    for e in entries:
        lines.append("  SpellArtPackEntry(")
        lines.append(f"    id: {_dart_string(e.id)},")
        lines.append(f"    asset: {_dart_string(e.asset)},")
        lines.append(f"    subject: {_dart_string(e.subject)},")
        lines.append(f"    colour: {_dart_string_or_null(e.colour)},")
        lines.append(f"    level: {e.level},")
        lines.append(f"    element: {_dart_string(e.element)},")
        lines.append(f"    sha256: {_dart_string(e.sha256)},")
        lines.append(f"    bytes: {e.bytes},")
        lines.append("  ),")
    lines.append("];")
    lines.append("")
    lines.append("/// Loads the WebP bytes for a built-in art pack entry by [id], or null")
    lines.append("/// if [id] doesn't match any entry in [kPainterlyPack] (e.g. a spell")
    lines.append("/// carrying an artPackId from a pack version this build no longer")
    lines.append("/// ships -- callers should fall back to the coat of arms, not crash).")
    lines.append("Future<Uint8List?> loadPackArt(String id) async {")
    lines.append("  for (final entry in kPainterlyPack) {")
    lines.append("    if (entry.id == id) {")
    lines.append("      final data = await rootBundle.load(entry.asset);")
    lines.append("      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);")
    lines.append("    }")
    lines.append("  }")
    lines.append("  return null;")
    lines.append("}")
    lines.append("")

    with open(DART_OUT_PATH, "w") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    sys.exit(main())
