# Spell Sound Pack — plan

*Proposed 2026-08-03, on `feature/practice-mode`, immediately after commit `4908565`
("Sound effects imported"). Ships a curated built-in **sound** pack — the audio sibling of
docs/SPELL_ART_PACK_PLAN.md — plus the playback layer the game currently lacks, and the
licensing/attribution scaffolding the pack legally requires.*

Status: **§2 decisions OPEN — needs Soren.** Provenance verified (§1). Do not start
Phase A until D-1 … D-7 are ratified.

---

## 1. What is actually in `assets/audio/spells/` right now

75 files, **47 MB**, committed wholesale in `4908565` (already pushed to `origin`).

### The files are not what their extension says

**65 of the 75 `.ogg` files are actually RIFF/WAVE, 16-bit stereo PCM at 44.1 kHz.**
Only 10 are genuine Ogg Vorbis. Verified with `file` + `ffprobe` across all 75:

| Container | Count | Notes |
|---|---|---|
| RIFF/WAVE PCM s16le stereo 44100 | 65 | mislabeled `.ogg` |
| Ogg Vorbis stereo 44100 | 10 | genuine (`forcepush`, `zap2a`–`zap2g`, …) |

That is the whole 47 MB: the file sizes are conspicuously quantised (605 228 / 907 308 /
1 210 412 / 1 512 492 bytes — 3.43 s / 5.14 s / 6.86 s / 8.57 s of stereo PCM), which is
the tell. Flutter's `audioplayers` sniffs container by content on Android and Linux so
these *do* play, but the extension lie is a trap for any tooling that trusts it, and it
is not something to ship.

### They are heavily silence-padded

The quantised durations are padding, not content. Measured trailing-silence trim at −50 dB:

| File | Source duration | Actual content |
|---|---|---|
| `zap.ogg` | 3.43 s | **0.57 s** |
| `heal.ogg` | 5.14 s | 2.13 s |
| `blessing.ogg` | 5.14 s | 2.56 s |
| `explode.ogg` | 5.14 s | 3.43 s |
| `wind.ogg` | 6.86 s | 5.15 s |
| `freeze.ogg` | 8.57 s | 6.87 s |

This matters beyond bytes: an `AudioPlayer` completion callback on `zap.ogg` fires **3
seconds** after the sound is over. Any "play the cast sound, then advance the animation"
sequencing built on the raw files would be wrong by that margin.

### Content inventory

75 sounds, 306 s total, mean 4.1 s. **No duplicate content** (75 distinct SHA-256s).
Families:

| Family | n | Members |
|---|---|---|
| `zap` | 22 | `zap`, `zap2`, `zap2a`–`zap2g`, `zap4a`–`zap16` |
| `explode` | 5 | `explode`, `explode1`–`explode5` |
| `curse` | 5 | `curse`, `curse2`–`curse5` |
| `blessing` | 3 | `blessing`, `blessing2`, `blessing3` |
| `interlude` | 3 | `interlude`, `interlude2`, `interlude2a` |
| `warp` | 3 | `warp`, `warp2`, `warp3` |
| `enchant` / `freeze` / `shot` / `wind` / `cheer` / `magicfail` / `forcepush` | 2 each | |
| singletons | 20 | `spell`, `steam`, `sand`, `water`, `heal`, `teleport`, `magicshield`, `flamethrower`, `confusion`, `disenchant`, `transmision`, `pestilence`, `insect`, `magicdrop`, `magicerase`, `forcepulse`, `spring`, `moving`, `entrance`, `cheer-crowd` |

The 22-strong `zap` family is the useful one: it makes **deterministic per-spell variation**
possible (§5 C-4) — the same spell always sounds the same, different spells don't.

### Provenance and licence — **verified 2026-08-03**

The pack is **"Spell Sounds Starter Pack" by `p0ss`**, OpenGameArt, archive `spells.zip`
(9.8 MB). Identification is not a guess: the listing's own breakdown ("22 zap effects,
5 explosions, 5 curse spells, 3 blessing spells, 2 cheering sounds, 2 enchant spells,
2 freeze spells, 2 shot spells, 2 wind spell sounds, 3 interlude sounds, 3 warp sounds")
matches our family counts **exactly**, family for family. The files' mtimes are 2011-03-03,
consistent with the listing's vintage.

- Source page: https://opengameart.org/content/spell-sounds-starter-pack
- LPC mirror: https://lpc.opengameart.org/content/spell-sounds-starter-pack

**Licences offered on the page: CC BY-SA 3.0, GPL 3.0, GPL 2.0.**

Note what is *not* on offer, because it differs from the art pack in the way that matters:

- **No attribution-only option.** Unlike the Painterly icons (CC BY 3.0 available), every
  licence here is copyleft. There is no "just credit us" path.
- **No CC BY-SA 4.0 direct.** 4.0 is reachable only via the 3.0 upgrade clause — see D-1.

The listing states **79 sounds**; we have **75**. Reconciling that gap is A-1 — most likely
the count includes a readme and/or the four `zapNa` variants got dropped in transit, but
it must be *checked* against a fresh `spells.zip`, not assumed.

### Why ShareAlike *does* bite here (unlike the art pack)

SPELL_ART_PACK_PLAN.md §1 argued ShareAlike never attaches because a PNG→WebP transcode is
definitionally not Adapted Material under CC BY-SA **4.0** §2(a)(4). **That argument does
not transfer**, for two independent reasons:

1. **We are doing more than transcoding.** The pipeline this plan proposes downmixes
   stereo→mono, trims silence, and loudness-normalises (§4 B-2). Downmix and gain staging
   are editorial choices, not "technical modifications necessary" to change format. That is
   an Adaptation on any reading.
2. **3.0 has no equivalent safe harbour.** CC BY-SA 3.0 §3's closing sentence permits
   "such modifications in any technical medium as are technically necessary to exercise the
   Rights in other media and formats" but — unlike 4.0 §2(a)(4) — it does **not** say those
   modifications never produce an Adaptation. The 4.0 escape hatch simply isn't in the 3.0 text.

So plan on shipping the derived pack as Adapted Material under a ShareAlike licence. **This
costs us nothing**: CLAUDE.md already licenses Runewright's creative assets CC BY-SA 4.0,
and ShareAlike attaches to the *sound files*, not to the GPL-3.0 Dart code that merely plays
them (playback is no more a derivative work than displaying an icon is).

The one live consequence: **never bake a pack sound together with an original Runewright
sound into a single shipped file.** Layering at playback time (two players, two files) is
fine and is what §6 specifies anyway. Baking a composite `.ogg` would make that file
CC BY-SA — again a no-op given CLAUDE.md, but worth knowing before someone "optimises" the
cast+impact layering into pre-mixed files.

*Not legal advice — but the operative clauses are named rather than paraphrased, so the
reasoning is checkable.*

---

## 2. Decisions — **OPEN, needs Soren**

Each carries a recommendation. The art plan's D-numbers are cited where the answer should
or should not mirror it.

**D-1 — Which of p0ss's licences do we take the pack under? → Recommend CC BY-SA 4.0, via
the 3.0 upgrade clause.**

CC BY-SA 3.0 §4(b) says an Adaptation may be distributed under "(ii) a later version of
this License with the same License Elements". BY-SA 4.0 is exactly that. Since §1 concludes
we *are* producing an Adaptation, the upgrade path is open to us, and taking it:

- **unifies the asset chain** — same licence as the Painterly pack (art D-1) and as
  CLAUDE.md's stated licence for Runewright creative assets. One licence, one credits row.
- **gets 4.0's improvements** — no jurisdiction ports, 30-day cure for inadvertent breach
  (3.0 terminates permanently and automatically), and §3(a)(2)'s explicit blessing of
  satisfying attribution by hyperlink, which is what the credits screen already does.

The alternative worth naming: **GPL 3.0**, which would unify with the *code* licence
instead of the asset licence. Rejected as the default because it makes the sound files
subject to GPL's source-distribution machinery (what is "source" for a `.ogg`?), a question
CC BY-SA simply doesn't raise. Recommend CC BY-SA 4.0.

*Fallback if Soren prefers minimum legal surface:* do a pure transcode only (no mono
downmix, no normalisation), argue it is not an Adaptation, and ship under CC BY-SA 3.0
unchanged. This costs ~2× the bytes and gives up loudness consistency. Not recommended.

**D-2 — The 47 MB of raw sources are already committed and pushed. What now? → Recommend
keep them tracked, move them aside, ship only the derived pack.**

Art D-2 kept 33 MB of source PNGs out of git. That ship has sailed here — `4908565` is on
`origin`, so the blobs are in history permanently whatever we do next, and a history rewrite
means a force-push on a shared branch for no real benefit (47 MB of an already-187 MB
`.git`).

Given the cost is sunk, **keeping the raws tracked is strictly better than deleting them**:
it makes `scripts/build_sound_pack.py` reproducible from a fresh clone, which the art
pipeline is *not* (art requires re-downloading four archives by hand). Concretely:

- `git mv assets/audio/spells → assets/audio_src/spells` — a rename reuses the existing
  blobs, so this adds ~0 bytes to the repo.
- derived pack lands at `assets/audio_pack/spells/`, mirroring `art/` → `art_pack/`.
- **only `assets/audio_pack/` goes in `pubspec.yaml`.** The raws never reach the APK.

Net effect on ship size: **+1.4 MB, not +47 MB.**

**D-3 — How does a spell get its sound: derived, chosen, or both? → Recommend both, derived
default + optional player override.**

Three options:

| | Storage | Opponent/basic spells | UI |
|---|---|---|---|
| (a) derived from formula only | none | works automatically | none |
| (b) player-picked, like art | `SpellAsset.soundPackId` | silent / needs fallback | picker |
| (c) derived default + override | optional field | works automatically | picker |

The art pack is (b), but art has a fallback — the commitment-derived coat of arms — that
sound has no equivalent of. A spell with no chosen sound must not be *silent*. So (a) is
load-bearing regardless, and (c) is (a) plus the art-like picker Soren asked for. It also
means the 75 shipped basic spells and every opponent spell sound correct on day one with
no migration and no wire change.

Recommend building (a) first (Phases D+E), then the override (Phase F) — so there is a
playable, audible game before any new persisted field exists.

**D-4 — Do opponents hear the sound *you* chose for your spell? → Recommend no. No sound
data on the wire in v1.**

Art has a sync path (art D-6 / Sync Art). Sound should not, in v1: each device plays from
its own local derivation, so a cast sounds right on both screens without a single new byte
in `battle_wire.dart`. If per-spell overrides should propagate later, the correct shape is
a **bounded catalogue id** (a `u16` index into the generated pack, range-checked on receipt)
— never bytes. **Never accept audio bytes over the wire**: unlike the art path, where
`SpellArtStore` writes a verified-hash image to disk, a peer-supplied audio blob is decoder
attack surface in a native codec with no upside.

**D-5 — What sounds beyond spell casts? → Recommend a fixed, small event set.**

The pack has clearly non-spell material (`interlude*`, `cheer*`, `entrance`, `moving`).
Recommend covering: **cast, impact, ward-block/counter, summon entrance, wizard walk,
inscribe-proof success/failure, victory.** Explicitly out: background music, ambient beds,
menu clicks, and anything on the sorcerer-mode capture path (a sound playing while the mic
is scoring a vocal formula is an obvious own-goal — see F-3).

**D-6 — Volume/mute control? → Recommend one master SFX slider + mute toggle, persisted,
in `settings_screen.dart`.** Minimal, but non-optional: this game is played in person,
across a table, in public. There must be a way to silence it in one tap.

**D-7 — Encode target? → Recommend mono, 44.1 kHz, Ogg Vorbis `-q:a 4`, silence-trimmed.**

Measured on the actual corpus, all 75 files:

| Setting | Size | Notes |
|---|---|---|
| source (as committed) | 47 MB | 65 files mislabeled WAV |
| mono 44.1 kHz q4, trimmed | **1.4 MB** | **recommended** |
| mono 22.05 kHz q2, trimmed + loudnorm | 0.9 MB | audibly dulls the `zap` family's top end |

Mono is right: these are point-source SFX on a shared tabletop device, and stereo doubles
the bytes for imaging nobody will hear. 44.1 kHz is worth keeping — the zaps live in the
8–16 kHz band that 22.05 kHz throws away. 1.4 MB is a rounding error next to the three
circuit VKs already in the bundle.

Trim threshold needs care: −50 dB was used for the measurements above and is probably too
aggressive for the reverb tails on `blessing`/`warp`. Recommend **−60 dB with a 30 ms
guard**, and B-4 makes it a listened-to check, not a spec.

---

## 3. Phase A — licensing, attribution, repo hygiene

**A-1 — Reconcile 75 vs 79.** Re-download `spells.zip` from the OpenGameArt page, diff
filenames against `assets/audio_src/spells/`, hash-match the overlap. Either add the four
missing sounds or record in ATTRIBUTION.md what they were and why they're absent. Do not
skip this — it is the one place the provenance chain is currently loose.

**A-2 — `assets/audio_pack/spells/ATTRIBUTION.md`.** Modelled on
`assets/art_pack/avatars/ATTRIBUTION.md`: source title, author (`p0ss`), source URLs,
licence taken under (D-1) *and* the licence offered (CC BY-SA 3.0 → 4.0 upgrade path, with
the §4(b)(ii) citation), the exact credit line, the modification statement — which must
describe what we actually did (**"downmixed to mono, silence-trimmed, re-encoded to Ogg
Vorbis q4"**), and the per-file source SHA-256 table. The art pack's modification statement
was rewritten once because it claimed something the pixels didn't support; write this one
from the ffmpeg command line, not from intent.

**A-3 — `git mv assets/audio/spells assets/audio_src/spells`** (D-2). Leave
`assets/audio/practice/` exactly where it is — it is generated, already shipped, and
unrelated.

**A-4 — `.gitignore`:** no change. Unlike art D-2, the raws stay tracked.

**A-5 — Credits screen row.** `lib/ui/credits_screen.dart` already renders
`_PackLicenceDetail(licence: kPainterlyLicence)` from generated Dart. Add
`kSpellSoundLicence` the same way — read from the generated catalogue, never hardcoded, so
a licence correction is a one-file regeneration.

---

## 4. Phase B — asset pipeline (raw sources → shipped pack)

**B-1 — `scripts/build_sound_pack.py`.** Direct sibling of `build_art_pack.py`: Python 3,
deterministic, idempotent, re-runnable to byte-identical output. Reads
`assets/audio_src/spells/*.ogg`, writes:

    assets/audio_pack/spells/<stem>.ogg      one per sound
    assets/audio_pack/spells/manifest.json   licence header + per-sound metadata
    lib/audio/spell_sound_pack.dart          generated Dart catalogue

Depends on `ffmpeg`/`ffprobe`, both already on this machine (`/usr/bin/ffmpeg`). Note the
Pillow precedent: `build_art_pack.py` pins encoder settings for reproducibility. Do the
same — pin `-q:a`, channel count, sample rate, and **`-map_metadata -1`**, since libvorbis
otherwise stamps an encoder version string that breaks byte-identical re-runs across
ffmpeg upgrades.

**B-2 — Per-file processing.** In order: probe true container (never trust the extension) →
decode → downmix to mono → trim leading/trailing silence at −60 dB with a 30 ms guard →
peak-normalise → encode Vorbis q4 44.1 kHz mono. Record pre/post duration in the manifest;
**a >90 % duration reduction is a build error**, not a warning — that is the signature of a
trim that ate the sound.

**B-3 — Catalogue metadata.** Per entry: `id` (source filename stem, stable — this is what
a future `soundPackId` persists), `asset` path, `family` (`zap`, `curse`, …), `variant`
index within family, `durationMs`, `sha256`, `bytes`. Every field a pure function of the
source, exactly as the art pack's are.

**B-4 — Listen to the output.** Not optional and not automatable. Play all 75 processed
files back before committing and confirm no clipped attack and no swallowed tail. This is
the audio analogue of the art plan's "the alpha assumption didn't survive checking the
actual pixel data" — measurements said the trim was fine at −50 dB; ears are the authority.

**B-5 — `pubspec.yaml`:** add `- assets/audio_pack/spells/` with a comment pointing at this
plan and at ATTRIBUTION.md, matching the existing asset-block comment style. Do **not** add
`assets/audio_src/`.

---

## 5. Phase C — data model

**C-1 — `lib/audio/spell_sound_pack.dart`** (generated by B-1). `SpellSoundPackEntry` +
`kSpellSoundPack` + `kSpellSoundLicence`, structurally identical to `spell_art_pack.dart`.

**C-2 — `lib/audio/spell_sound_map.dart`** (hand-written, the taste layer). Pure functions,
no I/O, no Flutter imports — so it is unit-testable without a widget harness:

    String castSoundId(SpellAffinity affinity, String commitmentHex);
    String impactSoundId(EffectKind kind, String commitmentHex);
    String eventSoundId(GameSoundEvent event);

**C-3 — The mapping table (proposed; taste call, wants Soren's ear).** Two layers, because
the battle screen already has two moments — orb launch (`SpellCastEvent.affinity`) and
effect bloom (`EffectKind`, derived from the formula's 2nd/3rd triplet).

*Cast layer, by affinity:*

| Affinity | Sound |
|---|---|
| fire | `flamethrower` |
| air | `wind2` |
| water | `water` |
| earth | `sand` |
| (none / neutral) | `spell` |

*Impact layer, all 16 `EffectKind`s:*

| EffectKind | Formula pair | Sound |
|---|---|---|
| `damage` | Fire-Fire | `explode` family |
| `barrier` | Earth-Earth | `magicshield` |
| `reflections` | Water-Water | `warp2` |
| `speedManipulation` | Air-Air | `spring` |
| `statusEffectInteraction` | Fire-Earth | `curse` family |
| `chainInteraction` | Fire-Water | `zap2` family |
| `spellInteraction` | Fire-Air | `disenchant` |
| `fuelTransmutation` | Earth-Fire | `transmision` |
| `tileModification` | Earth-Water | `sand` |
| `rangeModification` | Earth-Air | `forcepush` |
| `clouds` | Water-Fire | `steam` |
| `artifactsInteraction` | Water-Earth | `enchant` |
| `illusions` | Water-Air | `confusion` |
| `multiplierCycles` | Air-Fire | `magicdrop` |
| `haymakerInteraction` | Air-Earth | `forcepulse` |
| `divination` | Air-Water | `blessing` |

*Event layer (D-5):*

| Event | Sound |
|---|---|
| ward blocks a cast (`wasCountered`) | `magicfail` |
| inscribe: proof verified | `blessing2` |
| inscribe: proof failed | `magicfail2` |
| summon appears | `entrance` |
| wizard walks | `moving` |
| wild magic fires | `magicerase` |
| victory | `cheer-crowd` |

Leaves `heal`, `freeze`, `teleport`, `warp`, `insect`, `pestilence`, `shot`, `interlude*`
unassigned — deliberately. They are the reserve for artifacts, clouds, and the summons mode.

**C-4 — Deterministic variant selection.** Where a family has variants (22 `zap`s, 5
`explode`s, 5 `curse`s), pick by `commitmentHex` — the same derivation idea as the coat of
arms. Effect: a given spell always sounds identical to itself on every device and every
cast (so players learn it by ear), while two different Fire-Fire spells don't sound alike.
Free variety, zero storage, zero network, and it stays consistent across peers without the
wire ever carrying a sound id.

**C-5 — `SpellAsset.soundPackId` (D-3 override, Phase F only).** Nullable `String?`,
serialised only when non-null, exactly like `artPackId`. **Do not add this field until
Phase F.** Anything persisted is forever.

---

## 6. Phase D — the playback layer

This is the part with no art-pack analogue, and the part most likely to eat the schedule.
Art is static bytes handed to a painter; sound is a scheduled, stateful, concurrent resource.

**D-1 — `lib/audio/sfx_player.dart`.** A small service over `audioplayers ^6.1.0` (already a
dependency, already used by `practice_screen.dart` for trainer clips — that file is the
working reference for `AssetSource` paths and the Linux/Android behaviour we know works).

Requirements:

- **A pool of `AudioPlayer`s (4–6), not one.** A single `AudioPlayer` is a single stream;
  playing a second sound on it cuts the first. Casts overlap with impacts by design, so
  one-shot SFX need round-robin over a small pool with oldest-stream stealing when
  exhausted.
- **Preload/decode on entry to the battle screen**, not on first play. First-play decode
  latency on Android is tens of milliseconds — enough to make the orb's impact sound late.
- **`fire-and-forget` API.** `SfxPlayer.play(soundId)` returns `void`, never throws, and
  never blocks an animation. Audio failure must degrade to silence, never to a stalled
  reveal sequence.
- **Respects the D-6 mute/volume setting** at the service level, so no call site checks it.

**D-2 — Lifecycle.** Dispose the pool in `BattleScreenState.dispose()` alongside the four
existing `AnimationController`s. Stop everything on app background — an SFX firing from a
pocketed phone mid-duel is a bug.

**D-3 — Do not sequence animation off audio completion.** Animation timing stays driven by
`_castAnimController` and `kCastOrbImpactFraction`, exactly as now. Sound is fired *at* an
animation phase and is otherwise ignored. Coupling reveal pacing to decoder callbacks would
make the whole reveal sequence device-dependent, and §1 already shows how wrong the source
durations are about when a sound actually ends.

---

## 7. Phase E — wiring (derived sounds, no new persisted state)

All hook points already exist in `lib/ui/battle_screen.dart`'s reveal sequence
(`_revealCasts`, around lines 2300–2420) — no restructuring needed.

**E-1 — Cast.** Fire `castSoundId(cast.affinity, …)` in the same `setState` that installs
the `CastAnimation`, i.e. at orb launch (~line 2355).

**E-2 — Impact.** Fire `impactSoundId(...)` after `await Future.delayed(impact)` — the
existing `kCastOrbImpactFraction` delay that already marks the orb reaching its target.

**E-3 — Ward block.** `magicfail` where `ev.wasCountered` is handled (~line 2385), replacing
nothing; the countered-flash UI stays.

**E-4 — Walk.** `moving` from `_playAvatarWalks`, gated to *one* play per turn regardless of
avatar count.

**E-5 — Wild magic / summon / victory.** `_showWildMagicBanner`, the summon branch of the
reveal loop, and the existing end-of-match path.

**E-6 — Inscribe.** Proof success/failure in the Rune Craft inscribe pipeline. This is the
one hook outside the battle screen and can land in its own commit.

---

## 8. Phase F — override + picker UI (D-3's second half)

Only after Phases A–E are playable and the mapping has survived Soren's ear.

**F-1 — `SpellAsset.soundPackId`** (C-5), plus the `SpellAsset` round-trip test.

**F-2 — `lib/ui/spell_sound_pack_screen.dart`.** Modelled on `spell_art_pack_screen.dart`
(343 lines): family chips instead of element chips, a row per sound, **tap to audition** —
the one thing the art picker didn't need. Entry point from the same Craftings menu that
opens the art picker. Attribution footer reading `kSpellSoundLicence`.

**F-3 — Sorcerer-mode interlock.** Audition and battle SFX must be hard-muted while the mic
is capturing for vocal scoring (`lib/sorcerer/`). Playing a sound into the microphone that
is scoring a Latin formula would corrupt the score in a way that looks like a scoring bug,
not an audio bug — and per the gesture-corpus finding, a plausible-looking scorer
regression can cost days. Interlock at the `SfxPlayer` level, one flag, not per call site.

---

## 9. Tests and verification

| | What |
|---|---|
| unit | `spell_sound_map` — all 16 `EffectKind`s map to an id **that exists in the generated catalogue** (this is the test that catches a typo'd id at build time rather than as silence in a duel); variant selection is deterministic for a fixed `commitmentHex`; every catalogue id resolves to a bundled asset |
| unit | manifest round-trip; `build_sound_pack.py` is idempotent (run twice, diff) |
| widget | `SfxPlayer` fake injected into the battle screen; assert *which* ids fire in *what order* over a scripted reveal — this is how the mapping gets regression-protected without playing audio in CI |
| widget | credits screen renders the sound licence rows (mirrors `credits_screen_test.dart`) |
| manual | **B-4 listen-through of all 75 processed files** |
| manual | `flutter run -d linux` — full duel, judge the mix by ear |
| **manual, gating** | **two-device Android duel.** Per CLAUDE.md's verification hierarchy, audio is device-facing: pool exhaustion, decode latency, background-stop, and the sorcerer interlock only show up on hardware |

CI stays silent — no audio device on the runner, and the fake-player widget tests are the
actual coverage.

## 10. Commit sequence

Small and legible, per CLAUDE.md:

1. `docs: spell sound pack plan` — this file.
2. `assets: move raw spell sounds to audio_src` — A-3, pure `git mv`.
3. `assets: build sound pack (47 MB → 1.4 MB, mono ogg)` — B-1…B-5 + generated catalogue +
   ATTRIBUTION.md + pubspec.
4. `audio: sfx player service` — Phase D, no call sites yet.
5. `audio: spell sound mapping` — C-2/C-3/C-4 + unit tests.
6. `battle: wire spell sounds into the reveal sequence` — Phase E.
7. `ui: sfx volume + mute setting` — D-6.
8. `ui: credits row for the sound pack` — A-5.
9. *(later)* Phase F.

Commits 4–6 are separately revertable, which matters: if the mix is wrong on hardware,
reverting 6 restores a silent-but-working game without touching the pipeline.

## 11. Explicitly out of scope

- Background music, ambient beds, menu/UI click sounds.
- Positional/spatial audio, reverb, or any runtime DSP.
- Sound on the wire (D-4) — including opponent-advertised sound ids.
- Accepting audio bytes from a peer, under any circumstance.
- Recording or shipping original Runewright sounds.
- Sound in Commune/Trade, Sightings, or the Master/Apprentice loan flows.
- Anything behind a `[DECISION — needs Soren]` flag in the design doc.
