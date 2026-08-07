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

## 24x32 characters with faces, big pack (wizard avatar sprites)

**Author:** Svetlana Kushnariova (*Cabbit*) — lana-chan@yandex.ru
**Source:** OpenGameArt.org (see `assets/art_pack/avatars/ATTRIBUTION.md` for the
per-sheet source hashes)
**Licence:** dual-licensed **CC BY 3.0** (https://creativecommons.org/licenses/by/3.0/)
**and OGA-BY 3.0** (https://opengameart.org/content/oga-by-30-faq). Both require
attribution; Runewright credits the author under both.
**Modified:** yes — the 72×128 walk block cropped out of each RPG Maker 2000 charset,
the teal colour key replaced with a real alpha channel, edge colour bled outward, and
all characters packed into one atlas. Full statement in
`assets/art_pack/avatars/ATTRIBUTION.md`.

Used as the wizard tokens on the battlefield (`lib/ui/avatars/`). **Attribution is a
licence condition here, not a courtesy** — this entry and the matching section in the
in-app credits screen must ship with any build that bundles
`assets/art_pack/avatars/`.

## Spell Sounds Starter Pack (built-in spell sound pack)

**Author:** p0ss
**Source:** OpenGameArt.org — https://opengameart.org/content/spell-sounds-starter-pack
(see `assets/sound_pack/spells/ATTRIBUTION.md` for the archive hash)
**Licence taken:** CC BY-SA 3.0. **Licence shipped:** CC BY-SA 4.0 — the transcode is an
Adaptation (not just a technical format-shift, unlike the art pack above), and BY-SA
3.0 §4(b) permits relicensing an Adaptation under a later same-family version. Full
reasoning in `docs/SPELL_SOUND_PACK_PLAN.md` §1/§2 D-1.
**Modified:** yes — downmixed to mono Vorbis, loudness-normalized (two-pass `loudnorm`,
I=−16 LUFS), leading silence trimmed. Full statement in
`assets/sound_pack/spells/ATTRIBUTION.md`.

Used as the built-in sound pack a spell resolution plays by default (see
`docs/SPELL_SOUND_PACK_PLAN.md`).

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
`assets/practice_templates/` (see `scripts/generate_practice_assets.dart` and
`docs/M4_findings.md`'s "Piper toolchain" notes). Piper and the voice model are not
themselves bundled into the app — only their rendered output is.
