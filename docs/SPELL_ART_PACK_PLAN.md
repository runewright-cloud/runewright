# Spell Art Pack — plan

*Proposed 2026-07-27, on `feature/practice-mode`. Ships a curated built-in art pack that
players can pick from as an alternative to importing their own image, plus the licensing
and attribution scaffolding the pack legally requires.*

Status: **§2 decisions ratified 2026-07-27; provenance verified. Ready to implement.**

---

## 1. What is actually in `assets/art/` right now

Four unpacked OpenGameArt archives, 441 files / 33 MB (439 `.png` + 2 `README.txt`),
gitignored per D-2 (originally 470 files before Phase A's cleanup removed `__MACOSX/`
and `._*` AppleDouble junk — see §3 A-5):

| Directory | Icons (`.png`, excl. `__MACOSX`) | On disk |
|---|---|---|
| `painterly-spell-icons-1/` | 81 | 6.3 MB |
| `painterly-spell-icons-2/` | 99 | 8.8 MB |
| `painterly-spell-icons-3/` | 109 (incl. **37 decorative frames**) | 5.7 MB |
| `painterly-spell-icons-4/` | 150 | 12 MB |
| **Total** | **439 icons** (402 spell icons + 37 frames, all in pack 3) | **33 MB** |

Uniform shape: every one of the 439 is **256×256 PNG**. Every icon is fully opaque —
verified programmatically across the whole pack (`scripts/build_art_pack.py`): 261 are
plain RGB with no alpha channel at all, the remaining 141 carry an RGBA plane but it is
uniformly 255 (opaque) everywhere, and *none* has any actual transparency. (The initial
survey assumed alpha cutouts; that assumption didn't survive checking the actual pixel
data, and the modification statement in `ATTRIBUTION.md` is written to match reality —
"RGB", not "alpha preserved".) Filenames follow `<subject>-<colour>-<level>.png`, where
level `1/2/3` is an intensity ramp of the same motif (verified visually: `fireball-red-1`
is a small comet, `-3` is a full bloom), and frames follow `frame-<0..9>-<colour>.png`.

**Subjects** (≈40): `protect enchant fireball heal evil-eye beam rock lightning lighting
vines ice haste explosion wind wild runes leaf horror light fog fire-arrows wind-grasp
rip needles slice link air-burst shielding` — plus the set's own elemental variants
(`fog-water-air`, `light-air-fire`, `shielding-fire`, `slice-spirit`, `rip-water`, …).
Note `lighting` (pack 2) is the artist's typo for a *second* lightning motif, distinct
from `lightning`; both exist and both should ship.

**Colours** (10): `sky acid royal magenta jade eerie orange blue red grey`, with a few
one-off tags (`fire air water spirit plain arrows`).

### Provenance and licence — **verified 2026-07-27**

Packs 3 and 4 carry a `README.txt`; packs 1 and 2 do not. The bundled README reads:

> Painterly Spell Icon set part 3 / These icons are released by the artist under the
> following licenses: GNU GPL 2.0, GNU GPL 3.0, CC-BY 3.0, CC-BY-SA 3.0
> Attribution: J. W. Bjerk (eleazzaar) — www.jwbjerk.com/art — find this and other open
> art at: http://opengameart.org

**The bundled README is a stale subset.** It was written in 2010; CC 4.0 did not exist
until 2013, and the artist has since extended the licence list on the OpenGameArt pages
themselves. All four source pages were checked individually:

| Pack | Source page | Archive (page) | On disk | Licences stated on the page |
|---|---|---|---|---|
| 1 | [part-1](https://opengameart.org/content/painterly-spell-icons-part-1) | `painterly-spell-icons-1.zip` 6.4 MB | 6.3 MB | CC-BY 3.0, **CC-BY-SA 4.0**, CC-BY-SA 3.0, GPL 3.0, GPL 2.0 |
| 2 | [part-2](https://opengameart.org/content/painterly-spell-icons-part-2) | `painterly-spell-icons-2.zip` 8.8 MB | 8.8 MB | CC-BY 3.0, **CC-BY-SA 4.0**, CC-BY-SA 3.0, GPL 2.0 *(no GPL 3.0)* |
| 3 | [part-3](https://opengameart.org/content/painterly-spell-icons-part-3) | `painterly-spell-icons-3.zip` 5.7 MB | 5.7 MB | CC-BY 3.0, **CC-BY-SA 4.0**, CC-BY-SA 3.0, GPL 3.0, GPL 2.0 |
| 4 | [part-4](https://opengameart.org/content/painterly-spell-icons-part-4) | `painterly-spell-icons-4.zip` 11.9 MB | 12 MB | CC-BY 3.0, **CC-BY-SA 4.0**, CC-BY-SA 3.0, GPL 3.0, GPL 2.0 |

Archive sizes match the on-disk directories pack-for-pack, which together with the
identical dimensions, filename grammar, and attribution line confirms these are the
genuine archives. **Packs 1 and 2 are no longer unverified**, and every pack offers
CC BY-SA 4.0. Attribution line for all four, verbatim from the pages:

> J. W. Bjerk (eleazzaar) -- www.jwbjerk.com/art -- find this and other open art at:
> http://opengameart.org

Note that **CC BY *4.0* is not on offer** — the 4.0-vintage option is BY-**SA** 4.0 only.
That shapes D-1: attribution-only and 4.0-modern are mutually exclusive here.

### Why ShareAlike does not bite (the D-1 crux)

CC BY-SA 4.0 §3(b) triggers ShareAlike **only** "if You Share *Adapted Material* You
produce." Our only modification is a PNG → lossy WebP re-encode, and §2(a)(4) is explicit
(verbatim):

> The Licensor authorizes You to exercise the Licensed Rights in all media and formats
> whether now known or hereafter created, and to make technical modifications necessary
> to do so. […] **For purposes of this Public License, simply making modifications
> authorized by this Section 2(a)(4) never produces Adapted Material.**

A format transcode is therefore *definitionally* not Adapted Material, so ShareAlike never
attaches to the shipped pack, and it never reaches Runewright's GPL-3.0 application code
(which merely displays the icons — no copyright-derivative relationship).

The one case that *would* produce Adapted Material: **compositing** a pack icon with
something else into a single new image file — e.g. baking an icon and a `frame-*` border
together, or painting over an icon to make a new one. That composite must then ship under
CC BY-SA 4.0. Since CLAUDE.md already licenses Runewright's own creative assets CC BY-SA
4.0, that is a no-op for us. It is also why D-3 (frames excluded, composited at render
time rather than baked into files) is now a licensing convenience as well as a scope call.

*Not legal advice — but the operative clauses are quoted above rather than paraphrased,
so the reasoning is checkable.*

---

## 2. Decisions — **ratified by Soren 2026-07-27**

**D-1 — Which of the artist's licences do we accept the art under? → CC BY-SA 4.0.**

*Ratified as CC BY 3.0, then revised to **CC BY-SA 4.0** once the OpenGameArt pages were
checked and 4.0 turned out to be on offer.* Soren's stated instinct — "may need to pivot
later to 4.0, it's more internationally robust" — is correct on the merits, and since
BY-SA 4.0 is available we take it now rather than planning a pivot:

- **4.0 is genuinely the more robust licence.** One global licence with no jurisdiction
  "ports" (3.0 had dozens), explicit coverage of sui generis database rights, a **30-day
  cure provision** for inadvertent breach (3.0 terminates automatically and permanently),
  and §3(a)(2)'s explicit blessing of satisfying attribution by hyperlink to a resource —
  which is precisely what D-4's credits screen does.
- **The ShareAlike cost is zero for us** — see §1's crux subsection. A format transcode
  never produces Adapted Material, so §3(b) never fires.
- **It unifies the asset chain.** CLAUDE.md already licenses Runewright's creative assets
  CC BY-SA 4.0. Taking the pack under the same licence means one licence, one attribution
  vintage, no mixed 3.0/4.0 bookkeeping — and if we ever *do* composite a pack icon into
  new art, the result is already required to be BY-SA 4.0 anyway.

The tradeoff being accepted knowingly: CC BY **4.0** is not offered, so choosing 4.0
means accepting ShareAlike. Given the above, that is the cheaper side of the trade.

*Implementation consequence:* the licence identifier must be a **single constant**, not
prose duplicated across `ATTRIBUTION.md`, `CREDITS.md`, the picker footer, and the credits
screen. See C-1 — the pack manifest carries `licence`/`licenceUrl`/`attribution` fields,
the generated Dart exposes them, and every UI surface reads from there. Revisiting D-1
later is then a one-line change to the generator plus a regeneration, not a grep.

**D-2 — Do the raw 33 MB of source PNGs go into git? → No.**
Commit only the derived ~3 MB WebP pack plus a manifest; `.gitignore` the raw sources.
33 MB of never-again-modified binaries is permanent, unshrinkable history for a repo that
already carries 53 MB of circuit assets. Regeneration requires re-downloading from
OpenGameArt — mitigated by recording the exact URLs (now verified, §1), archive names, and
archive SHA-256s in `ATTRIBUTION.md`, so the pipeline stays reproducible even though the
inputs are not vendored.

**D-3 — Ship the 37 decorative frames in v1? → No.**
Keep the files, exclude them from the picker. They are card borders, not spell art; wiring
them in means a second orthogonal cosmetic slot (`frameId` on `SpellAsset`, compositing in
`SpellCardPainter`) unrelated to "pick an icon instead of uploading one". Ship 402 spell
icons now, frames as a follow-up. Note this now also keeps us clear of the one operation
that *would* produce Adapted Material (§1) — if frames land later, composite them at
**render** time, never by baking a new image file.

**D-4 — Where does in-app attribution live? → Both.**
A persistent one-line credit inside the art picker, plus a full
`Settings → Credits & Licences` screen. CC BY-SA 4.0 §3(a)(2) permits satisfying
attribution "in any reasonable manner based on the medium", explicitly including a
hyperlink to a resource carrying the required information — the credits screen is that
resource, and the picker credit is the contextual pointer to it. The screen carries the
complete notice (work, author, source, licence, modifications) plus Runewright's own
GPL-3.0 / CC BY-SA 4.0 statements.

---

## 3. Phase A — licensing, attribution, repo hygiene — ✅ **DONE 2026-07-27**

This phase was a prerequisite for shipping the art at all. All five items are complete
and committed to the working tree (not yet `git add`ed — see §9 commit sequence, which
this work maps to commits 1–2).

- **A-1 — Verify provenance. ✅** Results in §1. All four OpenGameArt pages checked
  individually; all four offer CC BY-SA 4.0.
- **A-2 — `assets/art_pack/painterly/ATTRIBUTION.md`. ✅** Written. Contains: the four
  source URLs, the author attribution line, an archive size + **SHA-256 for each of the
  four zips** (downloaded fresh from
  `opengameart.org/sites/default/files/painterly-spell-icons-<N>.zip` and hashed;
  pack 1's extracted contents were also spot-checked byte-identical against the files
  already on disk, confirming these are the true source archives), the chosen licence
  + link, and the exhaustive modification statement:
  **"Re-encoded from 256×256 PNG to 256×256 lossy WebP (quality=82, method=6), alpha
  preserved. No resizing, no cropping, no recolouring, no compositing, no pixel-level
  editing. Filenames preserved verbatim."** That statement is load-bearing for D-1's
  ShareAlike reasoning (§1) — if a future change makes it false (any compositing, any
  repainting), the result is Adapted Material and the analysis must be redone.
- **A-3 — Top-level `LICENSE` and `LICENSE-ASSETS`. ✅** `LICENSE` is the unmodified
  canonical GPL-3.0 text (fetched from `gnu.org/licenses/gpl-3.0.txt`). `LICENSE-ASSETS`
  is the unmodified canonical CC BY-SA 4.0 legal code (fetched from
  `creativecommons.org/licenses/by-sa/4.0/legalcode.txt`), prefixed with a short
  project-specific scope note (not a modification of the licence text itself) explaining
  it covers Runewright's own creative assets *and* `assets/art_pack/`, pointing to
  `assets/art_pack/painterly/ATTRIBUTION.md` for the pack's specific attribution. Closes
  the pre-existing gap where the repo had SPDX headers and a CLAUDE.md licensing
  statement but no actual licence file.
- **A-4 — Top-level `CREDITS.md`. ✅** Seeded with two entries: the Bjerk art pack, and
  the Piper `it_IT-paola-medium` voice model (MIT, author paolapersico1) used offline at
  build time to render the Practice Mode trainer audio under `assets/audio/practice/` —
  found while surveying for "anything else third-party" per the original plan text; it
  was previously undocumented outside `docs/M4_findings.md`'s toolchain notes.
- **A-5 — Repo hygiene. ✅** `__MACOSX/` directories (3) and `._*` AppleDouble files (29)
  deleted; `painterly-spell-icons-4/painterly-spell-icons-4/` flattened up one level
  (verified count still 151 files after flattening — 150 icons + `README.txt`);
  `assets/Art/` renamed to `assets/art/` (plain filesystem `mv` — confirmed via
  `git status` that the directory was entirely untracked, so no `git mv` history to
  preserve); `.gitignore` gained an `/assets/art/` rule with a comment pointing at D-2
  and `scripts/build_art_pack.py`. Final inventory check: 441 files under `assets/art/`
  (439 icons + 2 `README.txt`, matching §1's count exactly), 33 MB, untouched by git.

---

## 4. Phase B — asset pipeline (source PNGs → shipped pack) — ✅ **DONE 2026-07-27**

**B-1 — `scripts/build_art_pack.py`. ✅** (Python 3 + Pillow 10.2, already on this
machine; no root needed, no new Dart/Flutter dependency.) Inputs
`assets/art/painterly-spell-icons-*/*.png`, outputs:

- `assets/art_pack/painterly/<original-filename-stem>.webp` — 256×256 RGB, lossy WebP
  `quality=82, method=6`. **Measured on the real run: 402 icons, 2,963,534 bytes total
  (2.83 MB), 7,371 bytes/icon average** — down from 33 MB. Against 53 MB of circuit
  assets already in the bundle this is noise.
- `assets/art_pack/painterly/manifest.json` — pack-level licence header
  (`name, author, sourceUrls, licence, licenceUrl, attribution, modifications`) plus one
  entry per icon: `{id, asset, subject, colour, level, element, sha256, bytes}`. The
  licence header is the **single source of truth** required by D-1 — no UI surface
  hardcodes a licence string.
- `lib/spells/spell_art_pack.dart` — the generated Dart catalogue (`kPainterlyPack`,
  `kPainterlyLicence`, `loadPackArt()`) — see §5 C-1, built now because the script emits
  it as a direct byproduct of the same data.

**Finding during the build: no source icon has meaningful alpha.** §1's original survey
assumed "256×256 PNG with alpha" from a visual read of one icon; checking every pixel
programmatically found the opposite — 261 of 402 are plain RGB with no alpha channel at
all, the other 141 carry an RGBA plane but it is uniformly 255 (opaque) everywhere, and
*zero* have any actual transparency. The script encodes as **RGB**, not RGBA, and
`ATTRIBUTION.md`'s modification statement says so accurately (no "alpha preserved"
claim) rather than repeating the wrong assumption. This cost nothing in output size —
libwebp already drops a uniformly-opaque alpha plane during lossy encode, confirmed by
byte-identical output between an RGBA-forced and RGB-forced encode of the same source —
so this was a documentation-accuracy fix, not a behaviour change. §1 above is corrected.

**No separate thumbnail variant, as planned.** These icons are natively 256 px; one file
serves both the full and thumb roles the resolver (§5 C-3) will return.

**B-2 — Filename parsing. ✅** Verified against the actual filenames, not just the
prose sketch: every one of the 402 non-frame files ends in a numeric `-1`/`-2`/`-3`
suffix (134 unique subject+colour stems × 3 levels, exactly balanced), so level parsing
never fails. Colour parsing strips *all* trailing tokens from the closed vocabulary
(`sky acid royal magenta jade eerie orange blue red grey fire air water spirit plain`)
off the end of the stem:
- **134 stems → 1 trailing vocab token** (the common case, e.g. `enchant-acid`).
- **2 stems → 2 trailing tokens**: `fog-water-air` (subject `fog`, colour stored as the
  joined `water-air`) and `light-air-fire` (subject `light`, colour `air-fire`).
- **1 stem → 0 trailing tokens**: `fire-arrows` — genuinely bare, no colour token at
  all. Kept as the whole stem per plan (`colour: null`), not dropped.

**B-3 — Element tagging. ✅** Implemented exactly per the three-step precedence, plus
one addition found necessary during implementation: **`fire-arrows` was added to the
subject-override table** (→ `fire`). It has no colour token for the heuristic to read
(the bare case above), so without an explicit override it would fall through all three
steps to an unearned `neutral` default — the subject name itself is unambiguous, so
this is a correctness fix, not a judgment call. With that one addition, every one of
the 134 unique stems resolves through a real rule (verified: the script logs a warning
if any entry ever falls through all three steps to the fallback, and the actual run
logged zero). Final distribution across all 402 icons: **neutral 147, air 75, fire 66,
earth 60, water 54.**

The generated table was hand-reviewed via targeted spot-checks (the two compound
stems, the bare stem, and a dozen representative subject/colour combinations across all
five elements) rather than eyeballing all 134 rows — the manifest and Dart output are
regenerable and diff-reviewable, so a mistake found later is a one-line fix and a
re-run, not a re-litigation.

**B-4 — `pubspec.yaml`. ✅** Added `- assets/art_pack/painterly/` (directory entries are
not recursive in Flutter, so the pack stays flat — confirmed no per-subject subfolders
exist). `flutter pub get` and `flutter test test/spells/spell_art_pack_test.dart` both
green — see §8's manifest-integrity test, added now since it validates only this
phase's output.

**Verification performed:** two full runs of the script diffed byte-for-byte identical
(manifest.json, the generated Dart, and every `.webp`'s SHA-256) — the pipeline is
confirmed deterministic, not just assumed so.

---

## 5. Phase C — data model and resolution — ✅ **DONE 2026-07-27**

Design principle: **reference locally, materialise at the edges.** A spell using pack art
stores a short id, not 7 KB of duplicated bytes; anything that needs real bytes (rendering,
Sync Art) goes through one resolver.

**C-1 — `lib/spells/spell_art_pack.dart`. ✅** Built as part of Phase B (§4) — the
generator emits `kPainterlyPack`, `kPainterlyLicence`, and `loadPackArt()` as a direct
byproduct, so there was nothing left to do here except consume it.

**C-2 — `SpellAsset` gains `artPackId`; `SpellArtSource` gains `builtIn`. ✅** Both
additive and JSON-optional, confirmed by a dedicated test (`spell_asset_test.dart`:
"a spell JSON predating artPackId... still loads"). `withPackArt({required String
packId})` looks up the entry in `kPainterlyPack` (throwing `ArgumentError` for an
unknown id — this can only happen from a programming error, since the picker will only
ever offer ids that are already in the list) and copies its `sha256` into `artHash`, so
Sync Art's integrity check needs no special case, exactly as planned.

**Copy-method semantics decided during implementation** (the plan named the two new
methods but not how every existing copy method should treat the new field):
- `withArt()` (switching to a local import) does **not** carry `artPackId` forward —
  importing an image supersedes a prior pack selection, so the pointer is cleared, not
  left stale. Covered by test.
- `withoutArt()` clears `artPackId` along with the rest of the art metadata (unchanged
  behaviour, since it already omits every art field). Covered by test.
- `withSupremeTags()` carries `artPackId` through unchanged, matching how it already
  treats `artHash`/`artSource`.

**Bug found and fixed while extending the copy methods:** `withGridWithheld()` — the
method a Trade loan uses to redact a spell's grid before handing it to a borrower — was
never updated when the custom-art fields (`artHash`/`artSource`/`artUpdatedAt`) were
added; it silently dropped all three (and would have dropped `artPackId` too). Confirmed
via `git log -p`: `withGridWithheld` predates the "Custom Art Phase 1" commit that
introduced those fields. Net effect: **a spell with custom art, when loaned, arrived at
the borrower with no art** — a real, silent, pre-existing defect, not a hypothetical.
Fixed by threading all four art fields through (including the new `artPackId`), with a
regression test (`spell_asset_test.dart`: "withGridWithheld() preserves art metadata").
This was in scope because Phase C required deciding what every copy method does with the
new field regardless — leaving the bug in place would have meant propagating it into
`artPackId` too, and fixing only the new field while leaving the other three broken would
have been a stranger, harder-to-explain inconsistency than fixing all four together.

**C-3 — `lib/spells/spell_art_resolver.dart`. ✅** Implemented exactly as specified:
`resolveSpellArtFull`/`resolveSpellArtThumb`, branching on `artSource == builtIn` (→
`loadPackArt`) vs. everything else (→ `SpellArtStore`, unchanged). All three call sites
now route through it:

- `lib/ui/spell_card_painter.dart` (`_fullArtFuture`, the full-screen overlay)
- `lib/ui/spell_card_painter.dart` (`_loadThumb`, the library card thumbnail)
- `lib/trade/sync_art_session.dart` (`_fulfillWantlist`'s offer bundle)

`test/spells/spell_art_resolver_test.dart` covers both branches plus two miss cases
(a `localImport` pointer with no store blob; a `builtIn` pointer with an unknown
`artPackId`) — both resolve to `null`, never throw, matching the "cosmetic downgrade,
not a crash" invariant the plan calls for.

**C-4 — `_hasCustomArt` made source-aware. ✅** Now checks `artPackId != null` for
`builtIn` spells and `spellHashHex.isNotEmpty` for everything else, instead of always
requiring the latter. Verified by a new widget test
(`spell_card_widget_test.dart`: "spell with built-in pack art renders it without
touching SpellArtStore") — since no `SpellArtStore.save()` is ever called for a
pack-art spell, a store-shaped fallback would render the coat of arms instead of the
icon, so `Image` actually rendering is a real assertion, not a tautology.

**C-5 — Sightings left untouched, as planned.** No change to `sighting_asset.dart`.

**Verification:** `flutter analyze` clean (zero new issues beyond a handful of
pre-existing, unrelated lints); full `flutter test` green with no regressions
(see §9 for the count). New/extended tests: `spell_asset_test.dart` (+6),
`spell_art_resolver_test.dart` (new, 6 tests), `sync_art_session_test.dart` (+1, the
pack-art sync round-trip), `spell_card_widget_test.dart` (+1).

---

## 6. Phase D — Sync Art — ✅ **DONE 2026-07-27** (as a side effect of C-3)

`_offerBundle` sends `fullBase64`/`thumbBase64` and the receiver re-hashes `full` against
the claimed `artHash`. With C-3 routing the load through the resolver, a pack-art spell
materialises its 7 KB and syncs like any other art, and the receiver's integrity check
passes because `artHash` is the manifest's SHA-256 of exactly those bytes. **No wire
format change, no protocol version bump, no receiver change** — confirmed true, not just
planned: `sync_art_session_test.dart` gained a full round-trip test ("sync() delivers
built-in pack art...") that sends real pack bytes peer-to-peer over `InMemoryTransport`
and passes the receiver's integrity check unmodified.

Deliberately *not* doing: sending `artPackId` as a reference and letting the peer resolve
it locally. It would save ~7 KB per spell at the cost of a wire change, a version-skew
failure mode (peer on an older build lacks the id), and a second code path through the
integrity check. Bytes are the boring, already-audited path.

One thing noted while in this file: `_receiveAndSaveBundle` enforces no size cap on
received art, unlike `importSpellArt`'s `kSpellArtMaxImportBytes`. Pre-existing, out of
scope here — logged as `docs/OUTSTANDING_ITEMS.md` §7.

---

## 7. Phase E — the picker UI — ✅ **DONE 2026-07-27**

**E-1 — Entry point. ✅** The Craftings/Tests card menu item now opens a shared
`_chooseSpellArt` bottom sheet — **"Choose from Art Pack"** / **"Import an Image…"** —
before dispatching. The import branch calls `_setCustomArtOnSpell` exactly as before;
that whole pipeline (hostile-bytes handling, isolate decode, timeout, snackbars) is
untouched, confirmed by the existing import tests still passing unmodified.

**E-2 — `lib/ui/spell_art_pack_screen.dart`. ✅** Built as specified: element chips
(All/Fire/Air/Water/Earth, pre-selected from `suggestedElementFor(spell.formula)`),
a subject dropdown (`~28` distinct subjects in the actual data, not `~40` — §1's
subject count was always an approximation; the real generated list is what the
dropdown uses), a 3-per-row `GridView` of `cacheWidth`-bounded `Image.asset` thumbs,
a tap-to-preview-then-confirm dialog, and a persistent footer reading entirely from
`kPainterlyLicence` (no hardcoded licence string anywhere in this file) that pushes
`CreditsScreen` on tap.

**E-3 — Selection handler. ✅** `_choosePackArtOnSpell` in `library_screen.dart`:
clears any previous imported blob via `SpellArtStore.delete`, then
`spell.withPackArt(packId: id).save()`, then reloads. No decode, no progress dialog,
no failure path, exactly as planned.

**E-4 — `lib/ui/credits_screen.dart`. ✅** Reachable from a new "Credits & Licences"
tile in `SettingsScreen`, and from the picker's attribution footer. Renders
Runewright's own GPL-3.0/CC BY-SA 4.0 statement, the art pack's full licence detail
(read from `kPainterlyLicence`, not hardcoded), and the Piper voice-model credit
(hand-written, mirroring `CREDITS.md` — there is no generated data structure for it,
which would be over-engineering for one static prose block).

**Bug found and fixed via the real-engine integration test, not by inspection:**
all four `_reload()` methods in `library_screen.dart`
(`_CraftingsTabState`/`_TestsTabState`/`_LoansTabState`/`_SightingsTabState`) were
written as `setState(() => _xFuture = SomeAsset.loadAll())` — an arrow-body lambda
whose implicit return value is the assignment's result, i.e. the `Future` itself.
Flutter's `setState` asserts against exactly this ("setState() callback argument
returned a Future") — but only when the assertion actually fires, which apparently
no prior widget test had triggered through a live `setState` cycle on any of these
four methods (headless tests either constructed lower-level widgets directly or hit
a different reload path). The new `integration_test/spell_art_pack_test.dart` — the
first test to click through a real "Set Custom Art → pick → reload" cycle end to end
— hit it immediately. **This predates Phase E entirely**: it also affects the
already-shipped local-import path (`_setCustomArtOnSpell`'s `onReload` callback *is*
this same `_reload`), just never surfaced because nothing had integration-tested that
click-path before. In a release build (asserts stripped) this was harmless — the
assignment happens regardless of the flagged return value — so it was never a
user-visible defect, only a debug-mode/integration-test-mode trap. Fixed by giving
all four a block body (`setState(() { _xFuture = ...; });`), confirmed against both
integration tests (`spell_art_pack_test.dart`, `counter_charm_test.dart`) and the
full suite.

---

## 8. Tests and verification

| Level | Test | Asserts |
|---|---|---|
| unit | `test/spells/spell_art_pack_test.dart` | Every manifest entry's asset loads from `rootBundle`; its bytes' SHA-256 and length match the recorded values. This is the pack's golden-vector equivalent — it fails loudly if the pack and the generated Dart ever drift. |
| unit | `test/spells/spell_art_pack_test.dart` | Every entry has a valid element from the five-element set; every id is unique; ids are stable across two runs of the generator. |
| unit | `test/spells/spell_art_resolver_test.dart` | `builtIn` → bundle bytes; `localImport` → store bytes; unknown `artPackId` → null (falls back to coat of arms, does not throw). |
| unit | `test/spells/spell_asset_test.dart` (extend) | `artPackId` + `builtIn` JSON round-trip; a spell file *without* the new fields still loads. |
| unit | `test/trade/sync_art_session_test.dart` (extend) | A pack-art spell offers a bundle whose `artHash` survives the receiver's SHA-256 check. |
| widget | `test/ui/spell_art_pack_picker_test.dart` | Picker renders, element filter narrows the grid, selection stamps `artPackId`/`builtIn` onto the spell and leaves `SpellArtStore` untouched. |
| widget | `test/ui/spell_card_widget_test.dart` (extend) | A pack-art spell renders pack art, not the coat of arms. |
| widget | `test/ui/spell_art_pack_picker_test.dart` | The attribution footer renders the author, licence name, and "modified" from `kPainterlyLicence`. Cheap, but it is the test that fails if someone later strips the credit line — and attribution is a *licence condition*, not a nicety. |
| **device** | `flutter run -d linux` | Per CLAUDE.md's verification hierarchy: pick pack art on a real spell, confirm it renders in Library, in a Chapter, and on the battle-screen card reveal. Widget tests do not exercise real WebP decode. |

Plus `flutter test` full-suite green before commit, and `flutter build apk --release` once
to confirm the ~3 MB delta and that WebP assets survive the release bundle.

**WebP note:** Flutter decodes WebP natively through Skia on Android and Linux desktop, so
`Image.asset`/`Image.memory` need nothing extra. This is *not* the constraint that pushed
`spell_art_import.dart` to JPEG — that was the `image` package's inability to *encode*
WebP in Dart. We encode offline in Python, so that constraint does not apply here.

---

## 9. Commit sequence

Small and legible, per CLAUDE.md:

1. `Add repository licence files (GPL-3.0, CC BY-SA 4.0)` — Phase A-3.
2. `Add art pack attribution and credits` — A-1, A-2, A-4, plus the `.gitignore` rule.
3. `Add art pack build script` — B-1..B-3, no generated output yet.
4. `Add generated painterly art pack (402 icons, 2.83 MB)` — the derived assets, manifest,
   generated Dart, pubspec entry, and the manifest-integrity test. Large but purely
   mechanical.
5. `Add built-in art source to SpellAsset and art resolver` — C-2, C-3, C-4, C-5 + tests.
6. `Route card rendering and Sync Art through the art resolver` — the three call sites.
7. `Add art pack picker UI` — Phase E-1..E-3 + widget tests.
8. `Add credits screen` — E-4.

---

## 10. Explicitly out of scope

- The 37 decorative frames (D-3) — files stay, no wiring.
- Pack art for **sightings** or opponent spells (P1's boundary still holds).
- Per-spell art on `ChapterAsset` or minions.
- Animated / multi-frame art, or the icons' 1/2/3 intensity levels driving anything
  mechanical. Level is a *cosmetic filter dimension only* — it must never touch `formula`,
  `manaCost`, `supremeTags`, or anything the circuit or the battle engine reads. Card art
  is cosmetic; nothing here is consensus-visible, and no `RULESET_VERSION` bump is implied.
- Any second art pack. The manifest schema is pack-scoped (`kPainterlyPack`), so adding
  one later is additive, but v1 ships one pack.
