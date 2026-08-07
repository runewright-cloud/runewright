#!/usr/bin/env python3
"""Transcodes the raw spell-sound source files (assets/audio/spells/, gitignored --
see docs/SPELL_SOUND_PACK_PLAN.md D-2) into the shipped built-in sound pack:

    assets/sound_pack/spells/<stem>.ogg   (one per sound)
    assets/sound_pack/spells/manifest.json  (licence header + per-clip metadata)
    lib/spells/spell_sound_pack.dart        (generated Dart catalogue)

Mirrors scripts/build_art_pack.py structure-for-structure -- see
docs/SPELL_SOUND_PACK_PLAN.md for the plan this implements.

Requires ffmpeg/ffprobe on $PATH. Deterministic and idempotent modulo ffmpeg/libvorbis
version drift (unlike the art pack's WebP encode, Vorbis encoding is not bit-exact
across encoder versions -- the manifest hashes are pinned to what THIS run produced).

Finding 1 (see plan §1): despite the '.ogg' extension, 65 of the 75 source files are
actually RIFF WAV. This script never dispatches on file extension -- it hands every
source file straight to ffmpeg, which sniffs the real container.

Usage: python3 scripts/build_sound_pack.py
"""

from __future__ import annotations

import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_GLOB = os.path.join(REPO_ROOT, "assets", "audio", "spells", "*.ogg")
OUT_DIR = os.path.join(REPO_ROOT, "assets", "sound_pack", "spells")
MANIFEST_PATH = os.path.join(OUT_DIR, "manifest.json")
DART_OUT_PATH = os.path.join(REPO_ROOT, "lib", "spells", "spell_sound_pack.dart")

SAMPLE_RATE = 44100
VORBIS_QUALITY = "2"
LOUDNORM_I = "-16"
LOUDNORM_TP = "-1.5"
LOUDNORM_LRA = "11"
SILENCE_THRESHOLD_DB = "-50dB"

# ---------------------------------------------------------------------------
# Licence header -- see assets/sound_pack/spells/ATTRIBUTION.md (the authoritative,
# hand-maintained record) and docs/SPELL_SOUND_PACK_PLAN.md §2 D-1.
# ---------------------------------------------------------------------------
LICENCE = {
    "name": "Spell Sounds Starter Pack",
    "author": "p0ss",
    "sourceUrls": [
        "https://opengameart.org/content/spell-sounds-starter-pack",
    ],
    "licence": "CC BY-SA 4.0",
    "licenceUrl": "https://creativecommons.org/licenses/by-sa/4.0/",
    "attribution": "p0ss -- https://opengameart.org/content/spell-sounds-starter-pack",
    "modifications": (
        "Adapted: transcoded to mono Vorbis, loudness-normalized (two-pass loudnorm, "
        "I=-16 LUFS, TP=-1.5 dBTP, LRA=11), leading silence trimmed; adaptation "
        "licensed CC BY-SA 4.0."
    ),
}

ELEMENTS = ("neutral", "fire", "air", "water", "earth")

# Ambient / non-spell clips (plan §4 B-2) -- excluded from the spell picker but kept
# in the pack.
AMBIENT_IDS = {"interlude", "interlude2", "interlude2a", "cheer", "cheer-crowd", "entrance", "moving"}

# Trailing-variant-suffix stripper for the family label shown in the picker, e.g.
# 'zap2a' / 'zap10' / 'explode1' -> 'zap' / 'zap' / 'explode'. Strips one run of
# trailing digits optionally followed by a single trailing letter.
_VARIANT_SUFFIX_RE = re.compile(r"\d+[a-z]?$")


def derive_subject(stem: str) -> str:
    stripped = _VARIANT_SUFFIX_RE.sub("", stem)
    return stripped or stem


def derive_element(stem: str) -> str:
    """Plan §4 B-3's filename table, by prefix/exact match."""
    if stem.startswith("explode") or stem.startswith("flamethrower"):
        return "fire"
    if stem == "water" or stem.startswith("freeze") or stem == "steam":
        return "water"
    if stem.startswith(("wind", "forcepush", "forcepulse", "zap", "warp", "shot")):
        return "air"
    if stem in ("sand", "spring", "insect"):
        return "earth"
    return "neutral"


def derive_category(stem: str) -> str:
    return "ambient" if stem in AMBIENT_IDS else "spell"


@dataclass
class SoundEntry:
    id: str
    asset: str
    subject: str
    element: str
    category: str
    duration_ms: int
    sha256: str
    bytes: int


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def _ffprobe_duration_ms(path: str) -> int:
    result = _run([
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=nk=1:nw=1", path,
    ])
    if result.returncode != 0:
        raise RuntimeError(f"ffprobe failed on {path}: {result.stderr}")
    return round(float(result.stdout.strip()) * 1000)


def transcode(src_path: str, dst_path: str, tmp_dir: str) -> None:
    """Trim leading silence, downmix to mono, two-pass loudnorm, Vorbis-encode.
    Never dispatches on file extension (Finding 1) -- ffmpeg sniffs the real
    container from content."""
    trimmed = os.path.join(tmp_dir, "trimmed.wav")
    trim_result = _run([
        "ffmpeg", "-y", "-v", "error", "-i", src_path,
        "-af", f"silenceremove=start_periods=1:start_threshold={SILENCE_THRESHOLD_DB}:start_duration=0",
        "-ac", "1", "-ar", str(SAMPLE_RATE), trimmed,
    ])
    if trim_result.returncode != 0:
        raise RuntimeError(f"ffmpeg trim/downmix failed on {src_path}: {trim_result.stderr}")

    # Pass 1: measure. print_format=json is emitted at INFO verbosity -- must not
    # pass -v error here or the stats never reach stderr.
    measure = _run([
        "ffmpeg", "-hide_banner", "-nostats", "-i", trimmed,
        "-af", f"loudnorm=I={LOUDNORM_I}:TP={LOUDNORM_TP}:LRA={LOUDNORM_LRA}:print_format=json",
        "-f", "null", "-",
    ])
    match = re.search(r"\{.*\}", measure.stderr, re.S)
    if not match:
        raise RuntimeError(f"loudnorm measure pass produced no JSON for {src_path}: {measure.stderr}")
    stats = json.loads(match.group(0))

    # Pass 2: apply, with the measured values fed back in (single-pass loudnorm is a
    # live estimate and won't hit the target consistently -- plan §4 B-4).
    apply_filter = (
        f"loudnorm=I={LOUDNORM_I}:TP={LOUDNORM_TP}:LRA={LOUDNORM_LRA}:"
        f"measured_I={stats['input_i']}:measured_TP={stats['input_tp']}:"
        f"measured_LRA={stats['input_lra']}:measured_thresh={stats['input_thresh']}:"
        f"offset={stats['target_offset']}:linear=true:print_format=summary"
    )
    apply_result = _run([
        "ffmpeg", "-y", "-v", "error", "-i", trimmed,
        "-af", apply_filter, "-ar", str(SAMPLE_RATE),
        "-c:a", "libvorbis", "-q:a", VORBIS_QUALITY, dst_path,
    ])
    if apply_result.returncode != 0:
        raise RuntimeError(f"ffmpeg loudnorm apply failed on {src_path}: {apply_result.stderr}")


def main() -> int:
    if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
        print("error: ffmpeg/ffprobe not found on $PATH", file=sys.stderr)
        return 1

    source_files = sorted(glob.glob(SOURCE_GLOB))
    if not source_files:
        print(f"error: no source files found under {SOURCE_GLOB}", file=sys.stderr)
        print("Unpack the source archive into assets/audio/spells/ first -- see", file=sys.stderr)
        print("assets/sound_pack/spells/ATTRIBUTION.md for the source URL/hash.", file=sys.stderr)
        return 1

    print(f"Found {len(source_files)} source files.")

    os.makedirs(OUT_DIR, exist_ok=True)
    for stale in glob.glob(os.path.join(OUT_DIR, "*.ogg")):
        os.remove(stale)

    entries: list[SoundEntry] = []
    seen_ids: set[str] = set()
    source_mean_volumes: list[float] = []
    output_mean_volumes: list[float] = []

    with tempfile.TemporaryDirectory() as tmp_dir:
        for src_path in source_files:
            stem = os.path.splitext(os.path.basename(src_path))[0]
            if stem in seen_ids:
                print(f"error: duplicate id {stem!r} (from {src_path})", file=sys.stderr)
                return 1
            seen_ids.add(stem)

            dst_path = os.path.join(OUT_DIR, f"{stem}.ogg")
            print(f"  {stem} ...", end=" ", flush=True)
            transcode(src_path, dst_path, tmp_dir)

            with open(dst_path, "rb") as f:
                data = f.read()
            digest = hashlib.sha256(data).hexdigest()
            duration_ms = _ffprobe_duration_ms(dst_path)

            entries.append(SoundEntry(
                id=stem,
                asset=f"assets/sound_pack/spells/{stem}.ogg",
                subject=derive_subject(stem),
                element=derive_element(stem),
                category=derive_category(stem),
                duration_ms=duration_ms,
                sha256=digest,
                bytes=len(data),
            ))
            print(f"{len(data)} bytes, {duration_ms} ms")

    entries.sort(key=lambda e: e.id)

    unknown_elements = {e.element for e in entries} - set(ELEMENTS)
    if unknown_elements:
        print(f"error: derived element(s) {unknown_elements} not in the five-element set {ELEMENTS}",
              file=sys.stderr)
        return 1

    total_bytes = sum(e.bytes for e in entries)
    spell_count = sum(1 for e in entries if e.category == "spell")
    ambient_count = sum(1 for e in entries if e.category == "ambient")
    print(f"Encoded {len(entries)} clips ({spell_count} spell, {ambient_count} ambient).")
    print(f"  Total: {total_bytes} bytes ({total_bytes / 1024 / 1024:.2f} MB), "
          f"avg {total_bytes // len(entries)} bytes/clip.")

    manifest = {
        **LICENCE,
        "sounds": [
            {
                "id": e.id, "asset": e.asset, "subject": e.subject, "element": e.element,
                "category": e.category, "durationMs": e.duration_ms, "sha256": e.sha256,
                "bytes": e.bytes,
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


def write_dart(entries: list[SoundEntry]) -> None:
    lines = []
    lines.append("// GENERATED FILE -- do not edit by hand.")
    lines.append("// Regenerate with: python3 scripts/build_sound_pack.py")
    lines.append("//")
    lines.append("// SPDX-License-Identifier: GPL-3.0-or-later")
    lines.append("//")
    lines.append("// spell_sound_pack.dart -- the built-in spell sound pack catalogue. Every")
    lines.append("// field here is a pure function of the source filenames in the Spell")
    lines.append("// Sounds Starter Pack (assets/sound_pack/spells/ATTRIBUTION.md); see")
    lines.append("// docs/SPELL_SOUND_PACK_PLAN.md for the derivation rules.")
    lines.append("")
    lines.append("import 'dart:typed_data';")
    lines.append("")
    lines.append("import 'package:flutter/services.dart' show rootBundle;")
    lines.append("")
    lines.append("/// One clip in a built-in sound pack.")
    lines.append("class SpellSoundPackEntry {")
    lines.append("  const SpellSoundPackEntry({")
    lines.append("    required this.id,")
    lines.append("    required this.asset,")
    lines.append("    required this.subject,")
    lines.append("    required this.element,")
    lines.append("    required this.category,")
    lines.append("    required this.durationMs,")
    lines.append("    required this.sha256,")
    lines.append("    required this.bytes,")
    lines.append("  });")
    lines.append("")
    lines.append("  /// Stable identifier, stored on SpellAsset.soundPackId. Equal to the")
    lines.append("  /// original source filename's stem (no extension).")
    lines.append("  final String id;")
    lines.append("")
    lines.append("  /// Asset bundle path, loadable via rootBundle.")
    lines.append("  final String asset;")
    lines.append("")
    lines.append("  /// Filter-label family, e.g. 'zap', 'explode' -- the id with its")
    lines.append("  /// trailing variant suffix stripped.")
    lines.append("  final String subject;")
    lines.append("")
    lines.append("  /// One of 'neutral', 'fire', 'air', 'water', 'earth' -- derived from")
    lines.append("  /// the filename per docs/SPELL_SOUND_PACK_PLAN.md §4 B-3.")
    lines.append("  final String element;")
    lines.append("")
    lines.append("  /// 'spell' or 'ambient' (plan §4 B-2) -- only 'spell' entries are")
    lines.append("  /// offered as a spell's resolution sound.")
    lines.append("  final String category;")
    lines.append("")
    lines.append("  /// Duration of the transcoded clip in milliseconds.")
    lines.append("  final int durationMs;")
    lines.append("")
    lines.append("  /// Hex SHA-256 of the Ogg Vorbis bytes at [asset], unprefixed.")
    lines.append("  final String sha256;")
    lines.append("")
    lines.append("  /// Byte length of the file at [asset].")
    lines.append("  final int bytes;")
    lines.append("}")
    lines.append("")
    lines.append("/// Licence/attribution metadata for a built-in sound pack. The single")
    lines.append("/// source of truth every UI surface (picker footer, credits screen)")
    lines.append("/// reads from -- see docs/SPELL_SOUND_PACK_PLAN.md §2 D-1.")
    lines.append("class SpellSoundPackLicence {")
    lines.append("  const SpellSoundPackLicence({")
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
    lines.append("const SpellSoundPackLicence kSpellSoundLicence = SpellSoundPackLicence(")
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
    lines.append("const List<SpellSoundPackEntry> kSpellSoundPack = [")
    for e in entries:
        lines.append("  SpellSoundPackEntry(")
        lines.append(f"    id: {_dart_string(e.id)},")
        lines.append(f"    asset: {_dart_string(e.asset)},")
        lines.append(f"    subject: {_dart_string(e.subject)},")
        lines.append(f"    element: {_dart_string(e.element)},")
        lines.append(f"    category: {_dart_string(e.category)},")
        lines.append(f"    durationMs: {e.duration_ms},")
        lines.append(f"    sha256: {_dart_string(e.sha256)},")
        lines.append(f"    bytes: {e.bytes},")
        lines.append("  ),")
    lines.append("];")
    lines.append("")
    lines.append("/// Loads the Ogg Vorbis bytes for a built-in sound pack entry by [id], or")
    lines.append("/// null if [id] doesn't match any entry in [kSpellSoundPack] (e.g. a spell")
    lines.append("/// carrying a soundPackId from a pack version this build no longer ships --")
    lines.append("/// callers should fall back to the elemental default, not crash).")
    lines.append("Future<Uint8List?> loadPackSound(String id) async {")
    lines.append("  for (final entry in kSpellSoundPack) {")
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
