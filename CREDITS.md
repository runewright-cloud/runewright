# Credits

Runewright's own code and creative assets are licensed as described in `LICENSE`
(code, GPL-3.0-or-later) and `LICENSE-ASSETS` (creative assets, CC BY-SA 4.0) — see
CLAUDE.md's "Licensing" section. This file credits third-party work bundled into the
app or its build.

## Painterly Spell Icons (built-in spell art pack)

**Author:** J. W. Bjerk (eleazzaar) — www.jwbjerk.com/art
**Source:** OpenGameArt.org, parts 1–4 (see `assets/art_pack/painterly/ATTRIBUTION.md`
for exact source URLs and archive hashes)
**Licence:** CC BY-SA 4.0 — https://creativecommons.org/licenses/by-sa/4.0/
**Modified:** yes — re-encoded from PNG to WebP; no other changes. Full statement in
`assets/art_pack/painterly/ATTRIBUTION.md`.

Used as the built-in art pack players can choose for their spell cards instead of
importing their own image (see `docs/SPELL_ART_PACK_PLAN.md`).

## Piper text-to-speech (Practice Mode trainer audio)

**Voice model:** `it_IT-paola-medium`
**Author:** paolapersico1
**Source:** https://huggingface.co/rhasspy/piper-voices (path `it/it_IT/paola/medium/`)
**Licence:** MIT
**Training data:** `paolapersico1/Voice-Dataset-Italian` —
https://huggingface.co/datasets/paolapersico1/Voice-Dataset-Italian (see that dataset
for the underlying corpus's own terms)

Used offline, at build time only, via the self-contained Piper release binary
(`rhasspy/piper`, also MIT) to render the trainer-clip audio under
`assets/audio/practice/` (see `scripts/generate_practice_assets.dart` and
`docs/M4_findings.md`'s "Piper toolchain" notes). Piper and the voice model are not
themselves bundled into the app — only their rendered output is.
