# Spell Sound Pack — plan

*Proposed 2026-08-07, on `main`. Ships a curated built-in spell-sound pack plus a
player-imported custom-sound path, played when a spell resolves in battle, synced
peer-to-peer alongside custom art. Deliberately mirrors `docs/SPELL_ART_PACK_PLAN.md`
structure-for-structure — the two features share a data-model shape, a store shape, and a
sync path — and calls out by name every place where the analogy **breaks**, because those
are where the work actually is.*

Status: **§2 D-1 through D-6 all ratified (D-1 confirmed by Soren 2026-08-07: BY-SA 3.0 in,
BY-SA 4.0 out). Implementation starting.**

---

## 1. What is actually in `assets/audio/spells/` right now

75 files, 21 MB, committed to git in `4908565 Sound effects imported` (note: unlike
`assets/art/`, the raw sources are already in history — see A-2). Not currently listed in
`pubspec.yaml`'s asset section, so **nothing ships today**.

### Provenance and licence — **verified 2026-08-07**

**Spell Sounds Starter Pack** by **p0ss**, from
https://opengameart.org/content/spell-sounds-starter-pack.

| Archive | Bytes | SHA-256 |
|---|---|---|
| `spells.zip` | 9,781,493 | `194004ab3d74875d6aed6390ef061e51fa506cae0f5f0c55508e355b30670831` |

Downloaded from `https://opengameart.org/sites/default/files/spells.zip` and verified
2026-08-07. All **75 extracted files are byte-for-byte identical (SHA-256) to the 75 files
already in this repo's working tree** — not a filename match, a content match, with no
extras on either side. The page's own inventory corroborates independently: "22 assorted
zap type spell sounds" matches exactly (`zap`, `zap2`, `zap2a–g`, `zap4a–9a`, `zap10–16`
= 22), as do 3 blessings, 2 cheers, 5 curses, 1 heal, 1 teleport.

Licences stated on the source page: **CC BY-SA 3.0, GPL 3.0, GPL 2.0**. Note what is
*not* offered, since it differs from the painterly icons: **no attribution-only option,
and no 4.0-vintage option.** Attribution guidance on the page is the OGA default — credit
the asset and its creator.

Creation note from the page, worth keeping in the attribution record: *"All of these
sounds were created in Linux MultiMedia Studio and Audactity on Ubuntu 10.10"*.

### Why ShareAlike is not a problem here (the D-1 crux)

`SPELL_ART_PACK_PLAN.md` §1 could argue ShareAlike away entirely: CC BY-SA 4.0 §2(a)(4)
says a format transcode "never produces Adapted Material," so §3(b) never fires. **Neither
half of that reasoning survives the move to this pack.** 4.0 is not on offer, and our
processing (mono downmix, loudness normalization, silence trim — see D-2) goes past the
"modifications as are technically necessary" that BY-SA 3.0 §3 permits. The derived pack
is an **Adaptation**, and ShareAlike attaches to it.

That costs this project nothing, for four reasons:

1. **BY-SA 3.0 §4(b) explicitly permits licensing an Adaptation under "a later version of
   this License with the same License Elements."** So the derived pack ships as **CC BY-SA
   4.0** — which is already what `LICENSE-ASSETS` declares for Runewright's creative
   assets. Same destination as the art pack, reached by a different route.
2. **SA is file-scoped.** It reaches the derived `.ogg` files, not the GPL-3.0 app that
   plays them (no derivative relationship), not the CC0 terrain, not the CC BY 3.0
   avatars. The APK is a collection, not an adaptation of its parts.
3. **The project is already in this position.** The painterly icons ship under CC BY-SA
   4.0 in this same APK through this same credits machinery, and it has cost nothing.
4. **SA is the *cheaper* copyleft of the two on offer.** The GPL 3.0 option would arguably
   drag in GPL's source-form obligation — "the preferred form for making modifications" —
   pointing at shipping the pre-transcode 21 MB of WAVs alongside every release. CC BY-SA
   has no source-form obligation at all.

The obligations we actually take on: publish the derived files under BY-SA 4.0, credit
p0ss with a licence URI and an indication that the files were modified, and impose no
DRM or additional restrictions on the audio. All three are `ATTRIBUTION.md` + a credits
screen entry + a `manifest.json` block — machinery `build_art_pack.py` already
established.

*Not legal advice — but the operative clauses are named rather than paraphrased, so the
reasoning is checkable.*

### What the files actually are — three findings that shape the pipeline

**Finding 1 — 65 of the 75 "`.ogg`" files are RIFF WAV.** Only 10 are real Ogg Vorbis
(`forcepush`, `warp2`, `zap2`, `zap2a`–`zap2g`). The WAVs are 44.1 kHz **stereo 16-bit
PCM** at 1411 kbps. This is upstream — p0ss's own archive ships them this way, confirmed
by the byte-identical hash comparison above. **Consequence: nothing in this feature may
dispatch on file extension.** Sniff magic bytes (`RIFF`/`OggS`), always.

**Finding 2 — the pack is not level-matched, by a wide margin.** Measured with
`ffmpeg -af volumedetect` across all 75:

| | Quietest | Loudest | Spread |
|---|---|---|---|
| mean volume | `curse5.ogg` −54.3 dB | `zap2g.ogg` −16.1 dB | **38 dB** |

38 dB is roughly an 80× difference in amplitude. Seven files already peak at 0.0 dBFS
(clipping). **This is why D-4's volume cap cannot be implemented as a playback-gain
setting alone** — one gain value cannot make `curse5` audible without making `zap2g`
painful. Loudness has to be fixed at build time, which forces D-2.

**Finding 3 — durations run 0.4 s to 8.57 s** (`freeze.ogg` longest). The battle reveal
sequence holds a spell card for 2 s (`battle_screen.dart`'s
`_playResolvedSpellSequence`), so long clips will outlive their moment — see E-3.

### Measured transcode result

Pipeline from D-2, run over the whole pack as a spike:

| Encode | Total | Largest clip |
|---|---|---|
| source (44.1k stereo PCM) | 21 MB | 1,512,492 B |
| 44.1 kHz mono, Vorbis `-q:a 2`, loudnorm | **1.4 MB** | 60,866 B |
| 22.05 kHz mono, Vorbis `-q:a 1`, loudnorm | 908 KB | 30,295 B |

`ffmpeg` is present on the dev machine (`/usr/bin/ffmpeg`).

---

## 2. Decisions

**D-1 — Which licence do we take the sounds under? → CC BY-SA 3.0 in, derived pack out
under CC BY-SA 4.0.** *Recommended; needs an explicit yes from Soren before Phase A
lands.* Reasoning in §1's crux subsection. The alternative (GPL 3.0) is available and
would moot the SA analysis, but would make the audio the only creative asset in the repo
outside the CC BY-SA chain and drags in a source-form obligation CC does not have.

**D-2 — Ship transcoded, or ship the files as-is? → Transcode.** *Settled 2026-08-07 by
delegation.* 44.1 kHz **mono**, Vorbis `-q:a 2`, two-pass `loudnorm` to **I = −16 LUFS,
TP = −1.5 dBTP, LRA = 11**, leading-silence trim. Four independent reasons, any two of
which would be sufficient:

- **Loudness.** Finding 2 is the load-bearing one. Soren's D-4 ruling — "volume capped at
  some reasonable level" — is *only implementable* if the clips are level-matched first.
  Build time is the only place we can normalize, because the app has no audio decoder
  (see D-3).
- **Size.** 21 MB → 1.4 MB, on a release APK already at 79 MB with 53 MB of circuits.
- **Uniformity.** Finding 1's 65-WAV/10-Vorbis split becomes one format, so the app has
  one decode path and Phase D writes **one** header parser instead of two.
- **Fitness.** 44.1 kHz stereo PCM for a 0.6 s zap is waste; mono is correct for game SFX
  regardless, since any future spatialization happens at playback.

Chose 44.1 kHz/`q:a 2` (1.4 MB) over 22.05 kHz/`q:a 1` (908 KB): the 500 KB saved is not
worth halving the bandwidth on a pack whose most-used sounds are the 22 crisp, HF-heavy
zaps. Cost of this decision: a build step someone must be able to re-run — mitigated by
pinning the exact `ffmpeg` invocation in the script and recording the archive hash, so the
pack is reproducible from the verified source.

**D-3 — What may a player import? → Ogg Vorbis only.** *Settled 2026-08-07 by
delegation.* This is the decision where the art analogy breaks hardest, so the reasoning
is spelled out:

The art path's entire safety argument is *decode hostile bytes on a background isolate,
re-encode to canonical JPEG, hash the canonical form* (`spell_art_import.dart`). **There
is no Dart audio encoder**, so that argument has no audio equivalent — imported bytes
reach a platform codec (Android `MediaPlayer`, gstreamer on Linux) essentially as
supplied. The substitute is to make the *validation* gate carry the weight the
*canonicalization* step carries for art:

- **One container means one parser** to write, fuzz, and reason about. Ogg's page
  structure plus the Vorbis identification header yields sample rate and channel count,
  and the final page's granule position yields exact duration — all **without decoding a
  single sample**. That is a complete validation gate in pure Dart, in maybe 150 lines.
- **WAV would be a second parser** *and* an uncompressed format: 5 s of 44.1 kHz stereo
  WAV is ~880 KB versus ~40 KB of Vorbis, which fights the F-2 sync caps directly.
- **Honest downside:** players exporting from Audacity land on WAV or MP3 by default, so
  "convert it first" is real friction for a non-technical player. Mitigations: the error
  message names the fix explicitly, and the 75-sound built-in pack means most players
  never open the importer at all. **This is the decision most likely to need revisiting
  once real players hit it** — the escape hatch, if it does, is a decoder in the existing
  Rust FFI bridge (`ffi/`, e.g. `symphonia`), which is a real chunk of work and should not
  be built pre-emptively.

**D-4 — Do synced opponent sounds play by default? → Yes, with a capped volume.**
*Ratified by Soren 2026-08-07.* Implementation is E-4. Note the asymmetry this creates,
because it is the one place D-3's lack of a decoder actually hurts: pack clips are
normalized at build time and are mutually consistent, but **imported and synced clips
cannot be loudness-normalized at all** — measuring loudness requires decoding, and we
have no decoder. So peer audio gets a conservative fixed gain, a hard duration cap, and a
one-tap mute, rather than true normalization. Stated plainly here because it is a
limitation, not a design choice.

**D-5 — Built-in pack sounds travel over the wire as an *id*, never as bytes.** Sync Art
today sends built-in pack **bytes**: `_fulfillWantlist` calls `resolveSpellArtFull`, which
for `SpellArtSource.builtIn` returns the pack WebP, base64s it into the bundle, and the
peer saves a duplicate of a file already in their own APK. That is deliberate — see
`spell_asset.dart:345`, "artHash is copied from the pack's sha256, so Sync Art's integrity
check needs no special case" — and defensible for a 6 KB icon. It is the wrong shape for a
60 KB audio clip inside a single un-capped JSON frame. Sound sends `soundPackId` when the
source is built-in and bytes only for player imports. **Apply the same fix to art while
we're in there** (F-3), which also shrinks the project's SA distribution surface to
exactly one thing: the APK.

**D-6 — Every spell gets a sound with zero player effort.** Default to a pack clip chosen
deterministically from the spell's dominant formula element (`suggestedElementFor` in
`spell_art_pack_screen.dart` already computes this for art), with the picker as an
override. Art can fall back to the commitment-derived coat of arms; silence is a worse
default than a generic sigil is, and 75 clips is plenty to seed from.

---

## 3. Phase A — licensing, attribution, repo hygiene

- **A-1.** Write `assets/sound_pack/spells/ATTRIBUTION.md` in the exact shape of
  `assets/art_pack/painterly/ATTRIBUTION.md`: source page, archive name/size/SHA-256, the
  verification note above, the licence list verbatim from the page, the p0ss attribution
  line, and — different from the art pack — an explicit **"Adapted: transcoded to mono
  Vorbis, loudness-normalized, silence-trimmed; adaptation licensed CC BY-SA 4.0"**
  modification statement. The art pack's statement says "re-encoded"; ours must not,
  because ours *is* an adaptation (§1 crux).
- **A-2.** Add `/assets/audio/` to `.gitignore` and `git rm --cached` the raw sources,
  matching the `/assets/art/` precedent. **Explain to Soren:** this stops tracking them
  going forward, but they remain in history at `4908565` — that is fine and not worth
  rewriting history over; the point is that the tree and future clones stay lean, and the
  pack is regenerable from a hash-verified archive.
- **A-3.** Add the pack to `CREDITS.md` and `lib/ui/credits_screen.dart`. While there,
  fix the stale `assets/audio/practice/` path in `CREDITS.md:50` — that directory is now
  `assets/practice_templates/`.
- **A-4.** Add `assets/sound_pack/spells/` to `pubspec.yaml`'s asset list.

## 4. Phase B — asset pipeline (source WAV/Ogg → shipped pack)

- **B-1.** `scripts/build_sound_pack.py`, modelled on `build_art_pack.py`: reads
  `assets/audio/spells/`, sniffs magic bytes (never the extension — Finding 1), runs the
  D-2 `ffmpeg` invocation, writes `assets/sound_pack/spells/*.ogg` + `manifest.json`,
  and emits `lib/spells/spell_sound_pack.dart` as a GENERATED file with the same header
  banner. Per-entry fields: `id`, `asset`, `subject`, `element`, `category`,
  `durationMs`, `sha256`, `bytes`.
- **B-2. Category tagging (the frames analogy).** The art pack excluded 37 decorative
  frames from the picker (D-3 there). The equivalent here: several clips are not spell
  sounds — `interlude`, `interlude2`, `interlude2a`, `cheer`, `cheer-crowd`, `entrance`,
  `moving`. Tag them `category: ambient` and have the picker offer only `category: spell`.
  They stay in the pack (cheap, and useful later for UI sounds) but never appear as a
  spell's resolution sound.
- **B-3. Element derivation**, by filename stem, defaulting to `neutral`:
  `fire` ← `explode*`, `flamethrower`; `water` ← `water`, `freeze*`, `steam`;
  `air` ← `wind*`, `forcepush*`, `forcepulse`, `zap*`, `warp*`, `shot*`;
  `earth` ← `sand`, `spring`, `insect`; `neutral` ← everything else (`blessing*`,
  `curse*`, `enchant*`, `heal`, `magic*`, `teleport`, …). **Eyeball the result once** —
  the art pack's alpha-channel assumption did not survive checking the actual data, and
  this table is exactly the same kind of assumption.
- **B-4.** Two-pass `loudnorm` (measure, then apply), not single-pass — single-pass is a
  live estimate and will not hit the target consistently across 75 files.
- **B-5.** Verify the output: every file decodes, every duration is within 5% of source
  (trim aside), and the measured mean-volume spread across the pack collapses from 38 dB
  to a few dB. That last check is the acceptance test for Finding 2.
  **Measured 2026-08-07:** integrated-loudness (LUFS) spread collapsed to **13.9 dB**
  (mean −17.1 LUFS, stdev 2.35 across 75 clips), not "a few dB." Root cause: a handful of
  sub-second, high-crest-factor zap transients (`zap4a`, `zap15`, …) hit ffmpeg's
  `loudnorm` true-peak ceiling (`TP=-1.5 dBTP`) hard enough that it falls back from
  `linear` to `dynamic` normalization for just those files, which undershoots the −16
  LUFS target rather than risk clipping. This is expected EBU R128 behaviour for very
  short percussive content, not a pipeline bug — the alternative (relaxing the TP
  ceiling) trades a loudness outlier for actual clipping, which is worse. 71 of 75 clips
  land within a few dB of target; the outliers are still ~20 dB quieter than the original
  38 dB spread's loudest file, so D-4's volume-cap goal (nothing painfully loud) still
  holds even though D-4's "audible" half is imperfect for those few clips.

## 5. Phase C — data model and resolution

- **C-1.** `SpellAsset` gains `soundHash`, `soundSource` (`SpellSoundSource`:
  `builtIn` / `localImport` / `synced`), `soundUpdatedAt`, `soundPackId`, with
  `withSound()` / `withPackSound()` mirroring `withArt()` / `withPackArt()`. All optional
  in JSON, so existing spell files parse unchanged.
- **C-2.** `SightingAsset` gains the same four, mirroring its art fields — including the
  rule at `sighting_asset.dart:233` that a battle-cast upsert must **never** clear them.
- **C-3.** `lib/spells/spell_sound_store.dart` — blob store keyed the same way
  `SpellArtStore` is, one variant (`<key>.ogg`) rather than full/thumb. Same reasoning for
  keeping bytes out of `SpellAsset`'s JSON: `inscribeSpell` parses every spell's JSON on
  every inscription.
- **C-4.** `lib/spells/spell_sound_resolver.dart` — the single seam, mirroring
  `spell_art_resolver.dart`: pack id → bundle, otherwise → store, null → D-6's elemental
  default.
- **C-5.** `library_backup.dart` gains `spellSound` / `sightingSound` maps, skipping
  `builtIn` exactly as the art path does. Note the backup file grows by roughly the size
  of a player's imported clips; worth a line in the export UI if it gets large.

## 6. Phase D — import validation (no canonicalization available)

- **D-1.** `lib/spells/spell_sound_import.dart`: byte cap **before** anything else, magic
  bytes must be `OggS`, then a pure-Dart Ogg/Vorbis header walk yielding sample rate,
  channel count, and duration from the final page's granule position. Reject on: not Ogg,
  not Vorbis, > 2 channels, duration > **6 s**, bytes > **256 KB**. Hash the raw bytes
  (SHA-256, `0x`-prefixed, matching `artHashHex` convention) and store as-is.
- **D-2.** `spell_sound_io.dart` — `file_picker` glue, `allowedExtensions: ['ogg']`,
  mirroring `spell_art_io.dart`. Extension filters the *dialog*; the magic-byte check is
  what actually decides.
- **D-3.** Every rejection path returns a `SpellSoundImportException` with a
  player-facing message that names the fix ("Runewright accepts Ogg Vorbis files — most
  audio editors can export one").

## 7. Phase E — playback

- **E-1.** `lib/audio/spell_sound_player.dart`: a small pool of `audioplayers` instances
  (2–3), lazily constructed exactly as `practice_screen.dart:56` does — an `AudioPlayer`
  is a hard failure under `flutter test`, and this must not break the widget suite.
- **E-2.** Hook into `battle_screen.dart`'s `_playResolvedSpellSequence` at **card
  reveal**, not effect bloom — the card is the moment the player is looking at the spell.
  A fully countered cast (`ResolvedSpellEvent.wasCountered`) plays a fizzle, not the
  spell's own sound; a partial counter (`counteredFormulas > 0`) plays the spell normally,
  since it did resolve.
- **E-3.** Stop all playback when the reveal sequence ends and on dispose — Finding 3
  means an 8.5 s clip otherwise outlives its 2 s card and bleeds into the next phase.
- **E-4. Gain policy** (implements D-4): pack clips play at the global volume setting;
  imported and synced clips play at a fixed fraction of it (start at 0.7) since they are
  un-normalizable; global volume defaults to 0.6 with a slider in `settings_screen.dart`,
  which has no audio section today; a mute control is reachable **from inside battle**,
  not only from settings.
- **E-5.** Verify playback on Linux desktop early — audioplayers goes through gstreamer
  there, and there is no root on this machine to install anything missing. Practice mode
  already plays clips, so this is likely fine, but "likely" is not the bar for a
  device-facing path.

## 8. Phase F — sync

- **F-1.** Extend the existing `artBundle` payload with optional `soundHash`,
  `soundPackId`, `soundBase64` fields rather than minting new `SyncArtMsgType` bytes —
  nothing has shipped, both sides update together, and unknown JSON keys are ignored by
  older peers. Want-list entries gain `currentSoundHash`.
- **F-2. Caps.** Per-clip 256 KB (matching D-1's import cap) and a **total-bundle cap**,
  which does not exist today: `OUTSTANDING_ITEMS.md` §7 added a per-item cap only, and
  art items are ≤288 KB so it never mattered. Twenty spells × a 60 KB clip is fine;
  twenty × an un-capped import is not.
- **F-3.** Implement D-5 for both sound and art: send `packId` for built-in sources,
  bytes only for `localImport`.
- **F-4.** Rename the Sync Art screen's user-facing label (it now moves art *and* sound).
  Message-type names and enum identifiers stay — same discipline as the Rod of Wind
  rename, since `SpellArtSource` values are persisted by name on-device.

## 9. Tests and verification

- Unit: Ogg header parser against golden fixtures — **and negative fixtures**, which is
  where the real coverage is: truncated file, `RIFF` bytes with an `.ogg` name (Finding 1
  is the natural attack), Ogg container with a non-Vorbis codec, 9 s duration, 8-channel
  header, granule position implying a negative duration.
- Unit: `spell_sound_resolver` across all three sources plus the D-6 default.
- Unit: `SpellAsset` / `SightingAsset` round-trip with and without sound fields; a
  pre-sound JSON file must parse.
- Unit: sync bundle caps, and a built-in-source item asserting **no bytes on the wire**.
- Widget: battle reveal plays for a normal cast, fizzles for a full counter, stops on
  sequence end — with the player faked, no real audio in the suite.
- Pipeline: B-5's mean-volume-spread check, run as part of the build script.
- **Real-device:** one Linux desktop pass (E-5) and one two-device LAN pass syncing an
  imported sound. Per CLAUDE.md's verification hierarchy, this feature is not done without
  the two-device pass — it is a networking *and* an audio path, both device-facing.

## 10. Commit sequence

1. Phase A (licensing, attribution, gitignore) — lands alone, reviewable in isolation.
2. Phase B (pipeline + generated pack).
3. Phase C (data model, store, resolver) + its tests.
4. Phase D (import validation) + negative fixtures.
5. Phase E (playback + settings).
6. Phase F (sync + the D-5 art fix).

## 11. Explicitly out of scope

Music, ambient beds, UI click sounds, per-element sound layering, positional or
spatialized audio, recording sounds in-app, and anything that mixes two clips into one
file — the last of these because it would make *us* the author of Adapted Material at
runtime, which is a licensing question this plan has not answered.
