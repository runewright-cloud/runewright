# M4 — Findings Log (live, updated per milestone)

## Summons UI vertical slice — Rune Craft toggle, personality picker, battle display (2026-07-14, follow-up)

Closed the gap the previous entry flagged: the Summons engine had no way to
actually be *reached* from the UI. Added the missing UI plumbing so summon
spells can be inscribed and battle-tested, per Soren's ask after noticing the
Rune Craft screen had no Incantation/Summon toggle.

**What shipped:**
- `lib/main.dart` (Rune Craft / `GameScreen`): an Incantation/Summon `_ModeBar`
  toggle styled like the existing `_RuleBar`; a live `_SummonPreview` widget
  (swaps in for `FormulaBar` in Summon mode, built from
  `CreatureSpec.fromElements(_formulaTracker.committed)` — no new tracker
  plumbing needed, `committed` was already the full flat sequence); a
  personality picker folded into `_SpellNameDialog` (returns a small
  `_InscribeDetails` record instead of a bare `String` now); `isSummon`/
  `summonPersonality` threaded into the existing `inscribeSpell()` call.
  `GameScreen(loadedSpell:)` (the "view/re-edit a spell" path — see below)
  now also restores `_isSummonMode`/`_summonPersonality` from the loaded
  spell in `initState()`, so re-opening a summon spell shows it correctly
  instead of silently defaulting back to Incantation mode.
- `lib/battle/models/creature_spec.dart`: new display-only additions
  (`kSummonAbilityLabel`, `summonSummaryLabel`, `summonSummaryFromFormula`) —
  the single shared formatter every UI call site uses, mirroring
  `formulaEffectLabels`/`kEffectKindLabel`'s existing pattern in the sibling
  `effect_kind.dart`. `kSummonPersonalityLabel` went in `minion.dart` instead
  (it defines `SummonPersonality`; `creature_spec.dart` doesn't import
  `minion.dart` and adding that import would create a cycle, since
  `minion.dart` already imports `creature_spec.dart`).
- `lib/ui/battle_screen.dart` / `lib/ui/library_screen.dart`: the
  selected-spell caption and library list both branch on `spell.isSummon` to
  show `summonSummaryFromFormula(...)` instead of incantation effect labels;
  both spellbook/library card lists get a small `Icons.pets` corner badge on
  summon-mode cards (added by *wrapping* `SpellCardWidget` in a `Stack` at
  each call site, not by editing `SpellCardWidget`/`SpellCardPainter`
  themselves — that widget's rendering is pinned by
  `test/ui/spell_card_widget_test.dart`).

**Two scope cuts, made from evidence, not guesswork:**
- `lib/ui/spell_view_screen.dart` (`SpellViewScreen`) is **dead code** —
  grepped every call site; `library_screen.dart`'s actual "View" action
  navigates to `GameScreen(loadedSpell: spell)`, not `SpellViewScreen`. It's
  never instantiated anywhere. Skipped touching it; the loaded-spell path
  through `GameScreen` already got the mode-restore fix above, which is the
  thing that's actually reachable.
- `kEnhancementDescription` (`lib/spells/enhancement_zone.dart`) is **also
  dead** — defined, but no widget currently renders it (the cast-time
  `_EnhancementPicker` only shows the short zone label, e.g. "POTENCY", never
  the longer description string). The plan assumed swapping its Potency
  entry for a summon-aware one; since nothing displays it today, there was
  nothing to swap. Didn't invent a new description tooltip just to have a
  branch to write.

**Real finding: `testWidgets()` + real `dart:io` hangs, and why the fix only
gets you halfway.** Wrote `test/ui/battle_screen_summon_test.dart` to widget-test
the badge/caption end-to-end through the real `BattleScreen` tree. It hung
indefinitely — not slow, *actually stuck*, confirmed by killing it after 5+
minutes with zero progress and no timeout error (a genuine infinite loop or
zone deadlock would look exactly like this; a slow-but-alive process would
have eventually printed `package:test`'s own timeout failure).

Bisected with throwaway probe scripts (`dart run` doesn't work for
Flutter-dependent code — `dart:ui` isn't resolvable outside a `flutter test`
binding; had to probe via a real `testWidgets`/`test` pair instead):
`SpellAsset.save()` alone, under a plain `test()`, resolves instantly. The
*identical* call, under `testWidgets()`, hangs forever. Root cause:
`testWidgets` runs its body inside `package:fake_async`'s `FakeAsync` zone
(so animation timing is deterministic and controllable via `pump(duration)`)
— and genuine `dart:io` operations awaited from inside that zone never get a
chance to complete, because nothing pumps the *real* event loop while the
fake zone is driving. This is `flutter_test`'s own documented gotcha
(`WidgetTester.runAsync` exists specifically for it), just not one this
codebase had hit before — `spell_asset_test.dart` only ever uses plain
`test()`, and no existing widget test does real `SpellAsset` I/O mid-test.

Wrapping the direct `spell.save()` call in `tester.runAsync()` fixed *that*
call — but `BattleScreen.initState()` also fires `_loadSpells()`
(`SpellAsset.loadAll()`, a real disk read) as an un-awaited side effect of
`pumpWidget()`, which runs *outside* any `runAsync` wrapping (it has to —
`pumpWidget` needs the fake-async clock). That Future's completion can't be
reliably synchronized with from outside; the widget has no constructor seam
to inject pre-loaded spells for a test. Concluded this specific widget
(real-disk-loaded `BattleScreen`) isn't practically testable via
`testWidgets` without a production-code change (a spell-injection seam)
that's a real architecture decision, not something to sneak in to satisfy a
test. **Didn't make that change without asking** — deleted the widget test
and covered the same logic instead with direct unit tests on
`summonSummaryLabel`/`summonSummaryFromFormula` (`creature_spec_test.dart`,
+8 cases: ability-clause formatting, zone-name parsing, case-insensitivity,
void-formula null case) — the part that actually needed verifying was the
*string content* the caption shows, not that `Stack`/`Icon`/`Text` render
(Flutter's own job to guarantee that).
`test/ui/game_screen_summon_mode_test.dart` (the Rune Craft toggle, added
alongside the main pass below) hit none of this, because `GameScreen` does
no disk I/O until the player explicitly presses Inscribe.

**Verification run:**
- `flutter analyze`: clean project-wide (same pre-existing warnings only).
- `flutter test`: 310 run (up from 303 pre-slice), same 6 pre-existing
  unrelated `proof_intake_test.dart` failures, zero new failures, zero
  hangs after the above fix/cut.
- Manual: confirmed `flutter run -d linux` still boots cleanly; full
  interactive click-through (toggle → draw → inscribe → battle → cast) not
  independently re-driven this pass beyond the automated widget test for the
  Rune Craft half — no GUI automation tooling (`xdotool`/`scrot`/etc.) or
  `integration_test` harness exists in this sandbox to drive a real mouse
  through the battle-screen half, and building one was out of scope for a
  UI-plumbing pass. Flagging this explicitly: `game_screen_summon_mode_test.dart`
  is real automated verification of the Rune Craft toggle/preview through
  the actual widget tree; the battle-screen badge/caption verification is
  one level down (unit-tested string content + code review + `flutter analyze`),
  for the reasons above.

## Summons system implemented — engine + battle wiring, no crafting/casting UI yet (2026-07-14)

Implemented the design doc's "Summons" section: a summon-mode spell reads its
element sequence as a creature instead of an incantation effect. Scope was
explicitly limited (per plan) to the engine + battle wiring — no Rune Craft
"summons mode" toggle, personality-glyph picker, or in-battle summon-casting
UI. Every summon this pass is created programmatically (tests, or a future
UI pass); `SpellAsset.isSummon`/`summonPersonality` exist and round-trip
through JSON, but nothing in `main.dart`/`battle_screen.dart` sets them yet.

**New module: `lib/battle/models/creature_spec.dart`.** Pure, no-Flutter,
fully unit-tested (`test/battle/models/creature_spec_test.dart`, 41 cases).
`CreatureSpec.fromElements(List<BorderZone>)` derives affinity (most-common
element, first-appearance tiebreak), stats, and the 8 ability patterns from
a flat element sequence. Also carries the resistance wheel
(`applyResistance`/`resistanceTierOf`) and `morphicReducedSequence` (WWWW
death-reform selection).

**Stat formula — a real design gap, resolved with a documented default.**
The design's "logarithm base 1" for Earth/HP is mathematically undefined
(division by ln(1) = 0). Read as linear growth instead: `maxHp =
max(1, earthCount)`. Fire/Air/Water use `1 + floor(log_base(count))` with
base 2/2/3 respectively. Used **integer repeated-division log**, not
`dart:math`'s `log(n)/log(base)` — the latter lands on the wrong side of
exact powers due to float error (`log(4)/log(2)` can evaluate to
`1.9999999999999998`, silently off-by-one at every power-of-base boundary).
This would have been a very easy bug to ship undetected without the boundary
tests in `creature_spec_test.dart` (counts 1/2/3/4/7/8 for damage/move,
0/2/3/8/9 for range).

**`Minion` collapsed from a sealed Sprite/Hound hierarchy to one concrete
class.** The v2.4 model (kept dormant in the codebase since the v3.0
effect-table rework, per `effect_kind.dart`'s own comment) is gone:
`spiritStats`/`houndStats`/`ignoresTerrain`/`splashRadius`/`knockback` all
deleted. A creature's identity is now `affinity` + `stats` (from
`CreatureSpec`) + `abilities` (`Set<SummonAbility>`) + `personality`
(`SummonPersonality`, glyph-assigned in the design, defaults to
`aggressive` — no picker UI yet) + `elementSequence` (retained for Morphic
reform, not just the derived spec).

**A real `actedThisTurn` bug caught by the integration tests, not by
inline reasoning.** First-pass logic set `actedThisTurn: !enhancements.isPotent`
at creation — backwards. `actedThisTurn` is a transient "acted this
Summons-phase pass" flag, unconditionally reset to `false` at the end of
every `_resolveSummons` call; a creature created during action resolution
(phase 5) never participates in the *current* turn's already-finished
Summons phase (phase 4) regardless of this flag's value — it only
determines eligibility for the *next* turn's Summons phase. Setting it
`true` for non-Potent summons made them skip their actual first turn
entirely; the "Potent = immediate turn" case needs the flag to *stay*
`false` after the bonus action too, since Potency grants an *additional*
action, not a replacement for the next Summons-phase turn. Two of the eleven
`summon_cast_test.dart` cases failed against the first-pass code and pinned
the fix — the kind of bug that reads as obviously correct until you trace
the phase-4/phase-5 ordering by hand.

**Big (EEEE) footprint is a pure function of position, not stored state.**
`footprintFor(center, abilities)` = `[center]` normally, or `[center,
neighbor0, neighbor1]` for Big (two *consecutive* hex-neighbor directions,
which are themselves mutually adjacent — a true triangle). This meant the
state-hash serialization (`battle_state.dart toCanonicalBytes`) only needs
to write `position` once, not three coordinates — footprint, spawn-tile
validity, targeting distance, and knockback-immunity all derive it on
demand via `Minion.occupiedTiles`/`distanceTo`.

**Molten Carapace (EFEF) reflects through the *effect's* attacker position,
not a per-ability special case.** `EffectApplicator._hitMinion(ctx, m,
amount)` now takes the `ApplyContext` directly and derives both the
resistance-wheel `attackType` (`ctx.descriptor.affinity`) and the carapace
check (`hexDistance(ctx.caster.position, m.position) <= 1`) from it — every
existing damage path (direct/traversal/splash/knockback) gets both behaviors
for free, no new call-site plumbing needed beyond the signature change.

**Peer trust boundary extended, not reinvented.** Added
`TrajectoryParser.certifiedElementSequence` (refactored `parse` and it to
share one `_drive(outputs)` helper) and threaded a parallel
`certifiedPeerElementSequences` map through `_verifyPeerSpellCast` /
`_resolveActions` / `_applySpell`, alongside the existing `certifiedPeerFormulas`
(B-1/B-8). A peer's summoned creature is derived from the SNARK-certified
trajectory, never the wire-declared `SpellAsset.formula` — same pattern,
same verification gate (`verifyProof`/`vkBytes` non-null), no new trust
surface. **Not covered by a full two-client forgery integration test this
pass** — that would need real proof bytes through the whole
`_TurnSessionPair` harness (see `turn_loop_determinism_test.dart`), which is
heavy (FFI proving, ~7s/proof). Covered instead at the unit level
(`certifiedElementSequence` correctness, `trajectory_parser_test.dart`) plus
structural analogy to the already-tested `certFormulas` mechanism it
mirrors exactly (`formula_certified_test.dart`'s "wire-formula bypass"
case). Flagging this gap explicitly rather than overclaiming coverage.

**Verification run:**
- `flutter analyze`: clean project-wide (only pre-existing warnings in files
  this change never touched: `spell_test_lab_screen.dart`,
  `scripts/find_mask_vector.dart`).
- `flutter test`: 299 run, only the same 6 pre-existing
  `test/battle/engine/proof_intake_test.dart` failures (confirmed via
  `git stash` — reproduce identically with this change removed; a
  proof-field-count fixture mismatch unrelated to Summons).
- `flutter build linux --debug`: succeeds; the binary boots and runs cleanly
  for 8s with no error output (no summon UI exists yet to drive
  interactively, so this is a boot/regression check on the screens this
  change's files feed — spell cards, battlefield rendering, inscription).
- No `RULESET_VERSION` bump (summon derivation is off-circuit Dart, no CA
  rule changed). The `BattleState.toCanonicalBytes` format *did* change
  (new creature identity fields) — fine pre-release, but both clients need
  the same build for the state-hash exchange to agree.

**Not built this pass (flagged for the next one, per the locked plan
scope):** Rune Craft summons-mode toggle, personality-glyph assignment UI,
in-battle summon-casting affordance, and a full two-client peer-forgery
integration test for the certified element sequence.

## Practice Mode — reverted to whole-word checkpoints after mid-word bleed-through on real speech (2026-07-10, fifth follow-up)

First proper multi-word real-device session (Pixel, quiet room) surfaced a
structural bug the floor value couldn't fix: sometimes a checkpoint would
clear semi-instantly mid-word. Soren's own diagnosis, confirmed correct:
saying "terra" could register the first syllable ("ter") as a poor-but-
sufficient match for terra's first phoneme checkpoint, crossing it
prematurely, and then the trailing "-ra" would get scored against
whatever checkpoint came *next* (e.g. aer's first phoneme, if aer followed
in the formula) — a wrong-word match purely from bad luck of onset timing.

**Root cause:** `LatinPhonemes`' per-phoneme checkpoint boundaries within a
word were static, duration-weighted splits of the *reference* audio's own
frame count — never real forced alignment. They have no way to know where
a given speaker's actual articulation transitions between phones, which
varies a lot person to person and even utterance to utterance. Once wrong,
a boundary crossed too early doesn't just mis-score one phoneme, it feeds
that segment's leftover audio into the next checkpoint's window, so an
error at one boundary propagates into the next word entirely with no
recovery mechanism.

**Fix: reverted to one checkpoint per whole word**, not per phoneme.
`VocalTemplate.checkpointFrameIndices`/`checkpointLabels` are now always
length 1 in `SingleVoiceTemplateSource` (see that file's updated header).
This removes the mid-word-bleed failure mode structurally — there's no
sub-word boundary left to misplace — at the cost of losing "which specific
phoneme within a word stalled" feedback granularity (still keeping "which
*word* stalled," via `wordIndex`). This matches the granularity real
Sorcerer-mode casting already uses successfully. `LatinPhonemes` itself
(the phoneme table + G2P derivation trail) is kept, unused by the scorer
for now, as groundwork for a real future forced-alignment source rather
than deleted.

Renamed `phonemeLabel(s)` -> `label`/`checkpointLabels` throughout
(`_Segment`, `CheckpointClarity`, `VocalTemplate`, `PracticeScreen`) since
the field no longer ever holds a phoneme — it's the whole word now, and
the old name would have been actively misleading, not just imprecise.

**Not yet re-tested:** this needs a fresh real-device pass to confirm the
mid-word-bleed symptom is actually gone (it should be, structurally, but
"should be" isn't "confirmed" — see the standing verification-hierarchy
rule). The floor (7.0) and CMN/windowing fixes from the last several
entries are unchanged and still apply on top of this.

## Cast-time enhancement selection — dormant wire/UI gaps found and fixed (2026-07-13)

Moved spell enhancement choice (Potency/Velocity/Efficiency/Mystery) from
library/chapter-add time (`ChapterEntry.embellishment`) to cast time in
battle (`battle_screen.dart`'s new `_EnhancementPicker`). Eligibility rule
unchanged: still gated on `SpellAsset.supremeTags` (supreme/torrential
dominance achieved during that spell's own simulation).

**This was not a pure UI relocation — the old mechanism was already dead.**
Investigation before touching anything found the add-time choice never
actually reached battle: `battle_screen.dart`'s `_loadSpells()` discarded
`ChapterEntry.embellishment` entirely, both `SpellCastAction(...)`
construction sites never passed `isPotent`/`isVelocity`, and — the real
find — `turn_loop.dart`'s wire encoder (`_encodeAction`, case `0x01`
`SpellCastAction`) never serialized `isPotent`/`isVelocity` onto the wire at
all, unlike `0x03` (`MysterySpellCastAction`), which already did. Since
`_resolveActions` rebuilds `CastingEnhancements` from the wire-decoded
action for *both* players every turn, this meant a peer's enhancement choice
would have silently desynced effect magnitude/mana cost between the two
devices in any real (non-solo) duel — invisible in solo practice, where the
"peer" is the same local action object. Fixed by mirroring `0x03`'s pattern
exactly for `0x01` (3 new bytes: isPotent/isVelocity/isEfficiency).

**Added a fourth enhancement flag, `isEfficiency` (Water), that never
existed before** — only a sorcerer-mode vocal-quality `manaCostMultiplier`
existed previously, unrelated to loadout enhancements. Because Efficiency
directly reduces mana cost (not just effect magnitude, like Potency), Soren
opted to have it — and, for consistency, Potency/Velocity/Mystery too —
cryptographically verified rather than trusted from the wire: added
`TrajectoryParser.certifiedSupremeTags(VerifiedSpellOutputs)` (mirrors
`_deriveSupremeTags`'s local-CA-replay logic, but reads the SNARK-certified
`dominanceTrajectory`/`supremeDominanceFlags` instead) and a check in
`_verifyPeerSpellCast` that forfeits the match if a peer claims an
enhancement zone their spell's own certified data doesn't back. This
subsumes the older, narrower precedent at the old `_certifiedManaCost` call
site ("hasPotentLoadout/hasVelocityLoadout only gate effects, not cost; pass
false") — all four claims are now verified up front, so the cost/effect
formulas can trust the wire flags directly afterward.

**Velocity's "+2 range" has no engine seam to attach to, confirmed by
investigation, not assumed.** `_applySpell`/`_resolveActions` apply a cast
to whatever `targetHex` is on the action unconditionally — there is no
server/engine-side range enforcement anywhere in `turn_loop.dart`. The only
range concept is `battle_screen.dart`'s `_maxCastRange`, which is
client-side UX only (gates which taps the local player's own device
accepts). `isVelocity` is now wired correctly everywhere (data model, wire,
certified verification, effect-resolution eligibility) but the actual
mechanical range bonus remains a no-op, same as before this change —
flagged to Soren explicitly as a follow-up rather than inventing new range
mechanics unprompted.

**Also extracted `_deriveSupremeTags` (formerly private to
`library_screen.dart`) into `lib/spells/supreme_tags.dart`**, since
`battle_screen.dart` now needs the same eligibility derivation to backfill
`supremeTags` for spells added to a chapter before that tracking existed —
previously only the library screen's add-to-chapter flow did this backfill,
so a spell added to a chapter long ago and never re-touched in the library
could reach battle with stale/empty `supremeTags`.

Verification: `flutter analyze` clean project-wide; `flutter test`
(excluding `proof_intake_test.dart`, which has 6 pre-existing failures
confirmed unrelated — that file and `proof_intake.dart` are byte-identical
to `HEAD`, untouched by this change) — 241/241 pass, including
`turn_loop_determinism_test.dart`'s two-client determinism test, which
exercises the exact wire encode/decode path that was fixed.

## Custom Spell Art P1 — on-device verification pass, Pixel 6 (2026-07-13)

Ran the full P1 on-device checklist against a real Pixel 6 (Android 16, 8 GB)
over adb (no `xvfb`/`xdotool` in this environment, so driven via
`input tap`/`swipe` + screenshots rather than a scripted UI driver). Required
rebuilding the Android `.so` first (`bash scripts/build_android_ffi.sh` —
`ffi/src/{bin/desktop_vk_test.rs,api/prover.rs}` had drifted ahead of the
bundled `.so`; CLAUDE.md Bug Avoidance #3). All five checklist sections pass.

**Memory (Section 1).** Baseline app PSS ~555 MB (post-proving from an
earlier real inscription in the same session — proving itself hit
RSS ~1.5 GB / wall 14.8s on-device for a T12 proof, logged separately here as
a useful data point). A single MAX import (4096×4096, 7.5 MB JPEG — the
worst legally-importable case: right at both the dimension and byte
ceilings) didn't produce a measurable spike in 0.5s-granularity sampling,
suggesting the decode+resize+encode is fast enough on Tensor G1 that the
~67 MB decode buffer comes and goes within a fraction of a second. Five
back-to-back re-imports of the same MAX file (real `Replace Custom Art`
round trips, continuously sampled at 300ms) peaked at **PSS 991,769 KB
(~968 MB)**, settling to ~653 MB five seconds after the last one — no
climbing trend across repeats, no crash, no ANR. The blob store correctly
*overwrites* the same `spellHashHex` key rather than accumulating files
(confirmed only 2 files present in `spell_art/` after 6+ total imports across
the session). `compute()` isolate confirmed: UI stayed tap-responsive
throughout every import (never needed a retry tap), and the 20s timeout
never fired on any legitimate image.

**Visual (Section 2).** 84dp library card and the full-screen 512² overlay
both render cleanly — no visible JPEG blocking at quality=96 (MAX's
selected quality step). Swipe-to-reveal-emblem works correctly and feels
right (a plain horizontal `tester.drag`-equivalent gesture, no fighting with
scroll). **Open finding, not yet a `[DECISION]`:** ALPHA (PNG with a
transparent background) flattens to **plain white** on import — but this is
*not* an explicit compositing choice in `_encodeCanonical`; it's the
`image` package's implicit default when its JPEG encoder drops the alpha
channel. Looked clean and intentional-reading in practice (not garbage), but
relying on an unstated library default for a design-visible outcome is
fragile — a future `image` version bump could silently change it. If white
is in fact the desired background, it should become an explicit
`compositeOnto(white)` step in the code so it can't drift.

**Persistence & correctness (Section 3).** Survives `am force-stop` +
relaunch (fresh PID confirmed) — art reloads from the blob store immediately
on the new process, no re-import needed. Old-shaped (pre-P1, no
artHash/artSource/artUpdatedAt keys at all) spell JSON hand-fabricated and
dropped into `app_flutter/spells/` loads with zero parse errors, renders the
vector emblem, and is even correctly grouped into the existing Kin badge —
the nullable-field migration path is solid on-device, not just in
`spell_asset_test.dart`. `Revert to Coat of Arms` deletes both
`.full.jpg`/`.thumb.jpg` from `spell_art/` (confirmed empty directory after,
not just hidden) and clears all three metadata fields from the JSON.

**EXIF / privacy (Section 4) — confirmed on genuine camera hardware, not
just the synthetic test fixture.** Shot two real photos on the Pixel 6 with
location services on (`location_mode=3`); pulled EXIF showed real GPS
(lat/lon + altitude), timestamp, and `Make=Google`/`Model=Pixel 6`/HDR+
software tag — a full, real EXIF payload, not a stub. After import, the
stored blob's EXIF is completely empty (`imageIfd` empty, no GPS IFD) at the
correct 512×512 canonical size. **Treat "stored spell art is always
EXIF-stripped" as a confirmed invariant, not just a code-level intention** —
this is the finding P2 most needs, since it's the one that becomes a real
privacy leak the moment art starts crossing the wire.

**Failure paths (Section 5).** OVERSIZE (>8 MB, pushed via `adb push`,
rejected before decode) → clean snackbar "That image is too large
(max 8 MB)." JUNK (text file renamed `.jpg`) → clean snackbar "Unrecognized
image format (PNG, JPEG, or WebP only)." Neither crashed, neither left a
partial/corrupt file in `spell_art/` (checked directly on-device both times).

**Not a bug, but noted:** immediately after a scripted rapid-fire
`import → screenshot` sequence, the small library card occasionally still
showed the *previous* art for one frame/screenshot despite the underlying
`SpellAsset` JSON and blob store already being correctly updated. Root-caused
via a new widget test (`spell_card_widget_test.dart`, "reload transition..."
— the exact no-art→art transition on an already-mounted `SpellCardWidget`)
which passes cleanly, and confirmed harmless on-device by forcing a full tab
remount (data was always correct; only the very next paint occasionally
lagged the disk write by a beat under back-to-back scripted taps faster than
a human would drive the UI). Not a P1 blocker.

**P1 is playtest-ready per this pass.** P2 (opponent art, sync,
`SpellSighting`) can proceed against this baseline whenever it's greenlit.

## Custom Spell Art P1 landed — own-library art, image caps, data-layout decision (2026-07-10)

Built P1 of the custom-spell-art feature (see the CLAUDE.md custom-art
umbrella prompt + P1 go-ahead): a player can import an image to replace the
coat of arms on their own library spells. Own spells only, no networking, no
opponent art — those stay gated behind P2/P3.

**Format substitution: JPEG, not WebP.** The umbrella prompt specified
canonical WebP; Phase 0 accepted the `image` pub package (^4.8.0) as the new
dependency without checking encode support. Turns out `image` 4.8.0 can
*decode* WebP (`lib/src/formats/webp_decoder.dart`) but has no WebP encoder
at all. Re-encoding to WebP would need a second package or a native binary.
Rather than block P1 on that, canonicalized to JPEG instead — same caps, same
hashing, same "small bounded raster" goal, just a different container. See
`lib/spells/spell_art_import.dart`'s header comment. Worth revisiting if a
future phase (P4 trading, or a nicer transparency story) actually needs
alpha/WebP.

**Confirmed image caps** (pre-decode guards, then re-encode targets):
pre-decode ≤ 8 MB source / ≤ 4096×4096 declared dimensions (checked via a
header-only `Decoder.startDecode()` parse, so a compression-bomb file is
rejected before the expensive full pixel decode); re-encode full art to
512×512 canonical JPEG ≤ 256 KB, thumbnail to 256×256 ≤ 32 KB (quality
backed off 90→80→65→50→35 until it fits, keeping whichever step first hits
the ceiling). Decode + resize + encode all run off the UI isolate via
`compute()`, wrapped in a 20s wall-clock timeout on the caller side.

**Data-layout decision: art bytes are NEVER inlined on `SpellAsset`.**
`inscribeSpell()` calls `SpellAsset.loadAll()` on every inscription to check
for a duplicate `spellHashHex`, which parses every persisted spell's full
JSON file. Inlining full-size art blobs there would make that dedup scan
read tens of MB per inscription on a mature library. Instead: `SpellAsset`
gained only lightweight metadata (`artHash`, `artSource`, `artUpdatedAt`);
the actual bytes live in a new side store (`lib/spells/spell_art_store.dart`)
keyed by `spellHashHex`, loaded only when a card is actually rendered.
Confirmed `SpellAsset.loadAll()` is a genuine load-all (parses every file),
so this split was mandatory, not a nice-to-have.

**Two-layer front/back card model.** `SpellCardWidget`
(`lib/ui/spell_card_painter.dart`) now resolves custom art at the small-card
level (falls back to the existing `commitmentHex`-keyed vector coat of arms
while loading or on a store miss — the pre-P1 rendering path is untouched
when no art is set). The full-screen overlay is a genuine two-layer flip:
custom art shows by default when present, a horizontal swipe reveals the
true, locally-derived emblem underneath, and a text hint ("Swipe to see the
true sigil" / "...the custom art") makes the gesture discoverable. This is
the anti-spoof guarantee from the umbrella prompt's hard invariant 3 — the
true emblem must never be fully unreachable — verified end-to-end by a real
widget test (swipe, assert the emblem `CustomPaint` is now showing), not
just by reading the code.

**Bug the tests actually caught: EXIF wasn't being stripped.** The first
draft of `_encodeCanonical` in `spell_art_import.dart` assumed re-encoding
through a fresh `Image` object would drop source metadata for free. A test
asserting `decoded.exif.imageIfd.isEmpty` failed: `copyCrop`/`copyResize`
deliberately *carry the source `Image`'s EXIF forward* (so orientation-aware
resizing works), so a camera photo's make/model/GPS/timestamp would have
survived into stored spell art untouched. Fix: explicitly
`resized.exif = img.ExifData()` before encoding. Left as a test, not just a
comment, so a future refactor of that function can't silently regress it.

**Flutter test gotcha: real file I/O + `Image.memory` hang `pump()`
forever, not just fail.** Widget tests that populate `SpellArtStore` (real
`dart:io` file writes/reads) and then render the result via `Image.memory`
(real `dart:ui` codec decode) must wrap the whole sequence in
`tester.runAsync()` — `AutomatedTestWidgetsFlutterBinding`'s fake-clock test
zone doesn't drive real async I/O forward, so plain `pump()`/`pumpAndSettle()`
just hangs (observed: 2+ minute timeout, not a fast failure). Even inside
`runAsync`, `pumpAndSettle()` alone raced the real file read once; added a
short real `Future.delayed` before the final pump. See
`test/ui/spell_card_widget_test.dart`.

**Pre-existing, unrelated flakiness noted in passing:** `test/spells/
inscribe_test.dart`'s "second inscription reuses the on-disk SRS cache" test
can blow its fixed 30s per-test timeout when `flutter test` runs multiple
proving test files concurrently (default concurrency) — three real
UltraHonk proofs run back-to-back with growing RSS (1.3 GB → 2.2 GB →
2.8 GB+), and under CPU contention the third can miss the deadline. Confirmed
via `git stash` that this reproduces on the pre-P1 codebase too (not caused
by this work) and disappears entirely with `--concurrency=1`. Not fixed here
— flagging since it'll bite the next person who runs the full suite by
default.

## Practice Mode — floor was too loose on-device, not just drift-inflated (2026-07-10, fourth follow-up)

First real-device (Pixel, good mic, quiet room) pass exposed the floor
problem directly rather than as a slow plateau: the formula completed the
instant capture started, before any word was spoken -- too fast to even
read the live quality number. This is the same root cause flagged as
"still unresolved" in the previous entry (synthetic noise settling at
~10.6 against the bounded window, uncomfortably close to
`kDefaultCheckpointFloor = 11.0`), now confirmed as the actual bug rather
than a synthetic-test artifact: **11.0 doesn't discriminate real speech
from near-silence/ambient audio at all.**

Likely trigger mechanics: Android's mic backend appears to deliver a
larger first buffered chunk than Linux's `parecord`-piped stream did, so
the very first `acceptPcmChunk` call processes many frames of
mostly-pre-speech ambient audio in one synchronous burst (the per-frame
evaluation loop can cross multiple segments within a single call — see
`acceptPcmChunk`). On Linux's finer-grained delivery the same underlying
looseness only ever showed up as a slow plateau (the 8-8.5 real-voice
numbers, themselves gathered before the windowing-drift fix and so already
suspect); on Android's chunkier delivery it's severe enough to cascade
through the entire formula in one callback.

**Fix:** dropped `kDefaultCheckpointFloor` from 11.0 to 7.0 — real margin
below the ~10.6 noise baseline. The 8.0-8.5 real-voice data point that
justified 11.0 is now explicitly treated as stale in the code comment;
using it again to justify the next number would be repeating the same
mistake. Confirmed `flutter test`/`flutter analyze` still clean at 7.0 (no
constant-dependent test assertions — see the "explicit strict test-only
floor" note in the previous entry).

**Not yet confirmed:** whether 7.0 lets genuine correct speech complete on
this device at all, or is now too strict given the disruption of removing the
drift crutch. That's the next real-device data point, not something
resolved in this session — and this time, get it with the live quality
readout actually visible (the previous device's completion was too fast to
read a number; watch for whether that's still true at 7.0, since if it is,
the "floor too loose" diagnosis may not be the whole story and the large-
initial-chunk hypothesis itself needs checking, e.g. via a debug log of
chunk sizes as they arrive on Android).

## Practice Mode — unbounded query window let ANY sustained sound eventually pass (2026-07-09, third follow-up)

While chasing why real speech plateaued around 8-8.5 (previous entry),
built a synthetic stress test feeding pure random noise against a toy
reference and watching `currentNormalizedQuality` over time via the new
live-diagnostic getters, rather than trusting real-mic sessions to
localize it. Result was a real, previously-invisible bug: **quality drifted
downward over time from ~12 to ~9.8 purely from feeding more (still
random, still wrong) audio** — meaning if a player just kept making any
sound at all long enough, the checkpoint would eventually cross regardless
of content. This directly breaks the "anti-gabble is emergent" design
requirement (mumbling/wrong content must never complete, full stop).

**Root cause:** `_evaluateCurrentSegment` compared "every query frame since
this segment started" against the fixed-length reference via corner-
anchored DTW (both endpoints forced). As query length grows far past the
reference's length, most of the excess collapses onto repeated reference
columns, and cost/steps asymptotically approaches the reference's own
*typical* nearest-neighbour distance — a property of the reference's scale,
not of whether the query matches it. This is a known failure mode of
naively-unbounded online DTW; real online-DTW/score-following
implementations bound the comparison to a sliding window for exactly this
reason, which this design had not done.

**Fix:** capped the comparison window to the most recent `2x` the
segment's reference length (`_evaluateCurrentSegment`'s `windowCap`), not
"everything since the segment started." This is a sliding window, not a
timeout — there is still no limit on how long the pointer may stall; it
just can no longer coast to a pass purely from elapsed wrong audio. `2x`
was chosen because the "identical audio" test independently showed a
genuine match converges to near-zero cost by roughly that point.

**Still unresolved:** even with the bounded window, synthetic noise against
the toy sine-sweep reference used in unit tests settles at a steady-state
quality (~10.6) close to the real-voice range (8-8.5) that had prompted
`kDefaultCheckpointFloor = 11.0`. This might mean CMN + a short reference
genuinely leaves too little dynamic range to separate "correct" from
"wrong" — or it might mean a synthetic sine-sweep reference (extremely
regular, unlike real speech's formant structure) is simply not a
representative stand-in for real word templates and shouldn't be trusted
as a proxy for calibration decisions either way. Split the difference: the
unit test asserting rejection now uses an explicit, deliberately strict
test-only floor (3.0) to verify the mechanism works, decoupled from
whatever `kDefaultCheckpointFloor`'s real value should be — that's now
clearly a real-data question, not a synthetic-test question.

**Next real step, not done in this session:** re-test with a real voice
now that the drift bug is fixed (the previous 8-8.5 plateau may itself have
been partly drift-inflated, so that data point should be treated as stale),
AND get a real *wrong-word* attempt's quality number (e.g. deliberately
saying "terra" against an "aqua" target) — calibrating the floor needs both
a real correct-case and a real incorrect-case number to know if there's
enough separation between them, not just the correct-case number gathered
so far.

## Practice Mode — cepstral mean normalization added after real-voice calibration data (2026-07-09, second follow-up)

After the c0-drop fix (below), Soren's real voice against the Piper
reference "couldn't get under 9" on the live quality readout (floor is
6.0) — a real, hard number, not a hang. A quality stuck a few points above
the floor (not wildly high) is the signature of a *systematic* per-
coefficient offset (mic/room/vocal-tract-length differences between a real
voice and Piper's studio-quality render), not random mismatch — the standard
fix for that in speech processing is cepstral mean normalization (CMN):
subtract each segment's own per-coefficient mean from its frames before
comparing, so a roughly-constant bias cancels on both sides while the
frame-to-frame pattern (the actual phonetic content) survives.

**First attempt broke a unit test, and rightly so.** Applying CMN naively
made the "audio that never matches the reference" test start reporting a
false match. Root cause: that test's reference fixture was all-zero silence
— every frame literally identical, zero internal variance. Mean-centering a
set of identical frames zeroes them out completely, wiping out the one
thing CMN is supposed to preserve. This could have been a real design flaw
(CMN destroying signal at phoneme-checkpoint granularity generally) or a
test-fixture artifact (degenerate-by-construction silence reference) —
checked empirically against an actual generated template
(`assets/practice_templates/aqua.json`) before deciding: even a 10-frame
slice of real reference audio has meaningful per-coefficient stddev (1-3,
not 0). Silence was never representative of real word references. Fixed
the test fixture (a frequency sweep, not silence/a steady tone) rather than
reverting the feature — see `_chirpPcm` in
`test/practice/streaming_phoneme_scorer_test.dart`.

**Second empirical surprise while fixing the test:** matching audio only
converges to a clean (near-zero) DTW cost once *more* than one
reference-length of matching content has been fed — feeding exactly one
reference-length's worth left quality still measurably above zero. The
corner-anchored DTW alignment needs some slack (more query frames than
reference frames) to fully resolve minor across-computation numerical
differences even for literally-identical underlying signal content. Not
itself a bug, just a real property of this design worth knowing before
tuning `kDefaultDebounceFrames`/expecting instant convergence.

Also added `StreamingPhonemeScorer.floor`/`currentNormalizedQuality`
getters and a live "quality: X / floor: Y" readout in `PracticeScreen`,
specifically so the floor can keep being calibrated against real voices
with real numbers rather than guessed at blind — this is what surfaced the
"9" data point in the first place. **Still open:** whether CMN closes
enough of the gap on Soren's actual voice, or whether the floor also needs
raising, is unconfirmed — next step is another real-mic pass with this
build.

## Practice Mode — first real-mic pass found two live bugs (2026-07-09, same day follow-up)

First `flutter run -d linux` pass (device-testing note from the entry below
is now partially resolved) surfaced two real bugs the unit tests couldn't
catch because they only ever used synthetic all-zero-PCM "speech":

1. **`_startCapture` had no error handling.** A failure inside it (permission
   check or `record`'s `startStream` throwing) died completely silently —
   the Start button's press ripple would show and nothing else would ever
   happen, no error, no snackbar, nothing in the UI. Root cause turned out to
   be environmental (missing `ffmpeg`/`pulseaudio-utils` on the test
   machine — `record_linux` shells out to `parecord`/`ffmpeg` rather than
   using a native binding; its actual plugin `.cc` file is a no-op stub,
   all real capture logic is in Dart via `Process.start`), but the real fix
   is structural: wrapped the whole body in try/catch, surfacing failures
   via SnackBar + `debugPrint`. Any future capture-path failure (on any
   platform) will now be visible instead of silent.

2. **The DTW distance included MFCC coefficient c0 (log-energy/loudness).**
   Once capture actually started, the pointer never advanced past word 1
   against real speech, despite passing every unit test. c0 encodes overall
   loudness, not phonetic shape — so a real mic recording at some arbitrary
   gain/distance, compared against Piper's fixed studio-quality render, would
   inflate the DTW distance for reasons that have nothing to do with
   pronunciation. This is a known pitfall in DTW-based pronunciation scoring
   (c0 is conventionally dropped for exactly this reason) that the unit
   tests couldn't surface, because they fed literally-identical synthetic
   audio as both "reference" and "query" — identical audio matches at any
   loudness, including with c0 included, so the bug was invisible until
   real, differently-recorded audio was used. Fixed by dropping index 0 from
   every MFCC frame before any distance comparison in
   `streaming_phoneme_scorer.dart` (`_dropC0`/`_dropC0All`), applied
   symmetrically to both reference and query frames. Confirmed one of the
   existing unit tests (the "audio that never matches" stall test) had
   accidentally been testing loudness-invariance rather than content-
   mismatch — a differently-loud *constant* signal produces ~zero AC content
   regardless of amplitude (same as silence), so once c0 is excluded it
   spuriously "passes" as a match. Replaced with a genuine tone (non-constant
   waveform) as the mismatch case.

Also added a live diagnostic readout to `PracticeScreen` (current
normalized quality vs. the floor, shown while capturing) specifically so
`kDefaultCheckpointFloor`/`kDefaultDebounceFrames` can be calibrated against
real voices with real numbers, rather than guessed at again. **Still open:**
neither constant has been tuned against an actual human voice yet — that's
the next real-device step, not done in this session.

## Practice Mode (vocal, Phase 1) — scoring architecture and asset pipeline (2026-07-09)

Built on `feature/practice-mode`, branched from `origin/feature/ink-substrate`
(not `main` — `main` predates the entire sorcerer/battle/menu codebase; see
"main is far behind ink-substrate" below). Pure client scaffolding under
`lib/practice/` + `lib/ui/practice_screen.dart`; does not touch the circuit,
proving, commitments, lockstep, or networking.

### `finis` renamed to `finitus`

`VocalWord.finis` (`lib/sorcerer/vocal_score.dart`) is now `VocalWord.finitus`,
per Soren's explicit decision. Grep-confirmed zero wire-format impact (the
wire encoding is 3 quantised score bytes, never the word enum itself) and
only 3 total references repo-wide before the rename (the enum value plus two
comments in `sherpa_vocal_scorer.dart`) — safe, contained change.

### Sherpa-ONNX cannot satisfy the no-static-window requirement even once integrated

`lib/sorcerer/sherpa_vocal_scorer.dart` was already an explicit
"NOT YET INTEGRATED" stub, but its own integration checklist targets a
**KWS (keyword-spotter)** model — whole-keyword confidence, not streaming
per-phoneme/forced-alignment output. Real Sorcerer-mode casting itself is
also static-window today (`battle_screen.dart`'s `_onCast`: fixed
`Future.delayed(_voiceCaptureWindow)` then whole-utterance MFCC+DTW). Neither
existing nor planned infrastructure could have supported Practice Mode's
rate-invariant, no-fixed-window pointer model — this was a real architectural
gap, not a corner we cut.

### Chosen fallback: checkpoint-based online DTW, not a phoneme classifier

`lib/practice/streaming_phoneme_scorer.dart` reuses the existing
`lib/sorcerer/mfcc.dart` MFCC/DTW machinery rather than standing up a trained
acoustic model. Each word's reference audio is sliced into "checkpoint"
segments (a coarse duration-weighted heuristic over `LatinPhonemes`'
hardcoded phoneme table, **not** true forced-alignment boundaries — see that
file's header). A pointer advances checkpoint-by-checkpoint; on every new
~10ms MFCC frame, a fresh corner-anchored DTW runs between "all query frames
since the last checkpoint crossed" and that checkpoint's reference slice
(`DtwMatcher.distanceWithSteps`, added alongside the existing `distance()` —
additive, doesn't touch real Sorcerer-mode's call path).

**Length-normalized floor, the load-bearing fix:** the checkpoint-clear
condition is `cost / steps` (cost-per-DTW-step), not raw accumulated cost.
Raw cost is a running sum that grows with path length even for a perfect
match (more frames → more nonnegative terms), so a fixed threshold on raw
cost would force slower speech to match tighter per frame than fast speech
just to clear the same bar — exactly backwards for a "fast and slow clean
casts score identically" requirement. Dividing by step count removes that
bias. `test/sorcerer/mfcc_dtw_steps_test.dart` proves this directly: raw cost
triples when the same content is stretched 3x, cost/steps stays close.
Debounce (`kDefaultDebounceFrames`, currently 4) requires this to hold for
several consecutive frames — a real hysteresis, not a listening window; there
is no timeout anywhere in the scorer, so a floor that's never cleared simply
stalls the pointer forever (this **is** the anti-gabble mechanism, not a
separate check).

**What made this non-trivial to express:** the natural per-call granularity
(evaluate once per `acceptPcmChunk` call) would have made the debounce
duration depend on the host platform's audio-stream chunk size rather than
elapsed audio time — a real bug I caught via the unit tests, not by
inspection. Fixed by evaluating one new MFCC frame at a time inside
`acceptPcmChunk`'s loop, so `_framesClear` counts actual ~10ms frames
regardless of how many frames a single chunk delivers.

### Template-source shape: single Piper voice now, swappable by design

`lib/practice/vocal_template_source.dart` defines `VocalTemplateSource`
(one method, `templateFor(VocalWord)`) with `SingleVoiceTemplateSource` as
the only implementation shipped. Per Soren's decision: Piper (not a human
recording) is the reference speaker, chosen for reproducibility — a Piper
render is deterministic and regenerable as a build artifact keyed to the
voice model version (`it_IT-paola-medium`, sha256 pinned in
`scripts/generate_practice_assets.dart`), unlike a one-off human take.
`MultiVoiceTemplateSource` (average several Piper voices to dilute
speaker-timbre bias) and `PerUserEnrolledTemplateSource` (record the
player's own voice) are documented as deferred fast-follows in that file's
header, not built. **Known limitation, accepted for this playtest:** MFCC
encodes timbre/vocal-tract length, which DTW doesn't correct for, so a single
voice is still speaker-dependent — but it's an *impartial* bias (not tuned to
any one player), which is the bar for a first friends-playtest, not for
ship.

### One Piper render feeds both the trainer clip and the scoring template

`scripts/generate_practice_assets.dart` renders each word exactly once
through Piper's Italian voice; the same output is copied verbatim to
`assets/audio/practice/<word>.wav` (playback) and separately resampled
22050→16000 Hz + run through `MfccExtractor.extract()` to produce
`assets/practice_templates/<word>.json` (scoring). No second render, no
phoneme-driven pass distinct from the trainer audio — per Soren's explicit
requirement that what the player hears and what they're scored against can't
silently diverge.

### `ignis`/`finitus` G2P verified empirically, not assumed

Ran the actual `espeak-ng` binary bundled inside the Piper release (not a
guess) before writing `lib/practice/latin_phonemes.dart`:
```
ignis   -> ˈiɲɲis    (gn palatalizes+geminates, as the design brief predicted)
aer     -> aˈɛr
aqua    -> ˈakwa
terra   -> tˈɛrɾa     (rr -> geminate trill+tap)
finitus -> finˈitʊs   (Italian /ʊ/ on the un-Italian "-us" ending, not /u/)
```
No spelling workarounds were needed — Italian orthographic rules already
produce the intended targets for all 5 words. The phoneme table is a
hardcoded 5-entry lookup (the vocabulary is closed), not a general G2P
engine.

### Piper toolchain (not committed to the repo)

No root/apt access in this dev environment (`sudo` requires a password,
`pip`/`ensurepip` both absent). Used the self-contained Piper release
instead of system packages:
- Piper 2023.11.14-2, `piper_linux_x86_64.tar.gz` from
  `github.com/rhasspy/piper` releases — bundles its own `espeak-ng` +
  `onnxruntime`, no system install needed. Installed to `~/.piper/piper-bin/`
  (persistent, not `/tmp` — `/tmp/nargo` already taught this lesson once).
- Voice: `rhasspy/piper-voices` `it_IT-paola-medium` (medium quality; the
  other Italian voice, `riccardo`, is x_low only). Installed to
  `~/.piper/voices/`. sha256 of the `.onnx` pinned in
  `scripts/generate_practice_assets.dart` (`6fc918b5...c04210c`) so a re-fetch
  can be verified byte-identical.
- No `ffmpeg`/`sox` available either (no apt access) — the 22050→16000 Hz
  resample in `scripts/generate_practice_assets.dart` is a small
  hand-written linear-interpolation resampler. Adequate for MFCC feature
  extraction on short offline-generated clips; not used anywhere at runtime.

### `main` is far behind `feature/ink-substrate` — branch bases need care

Asked to branch off `main` for decoupling from ink-substrate's in-flight
work; discovered `main` predates the *entire* current game (`lib/sorcerer/`,
`lib/battle/`, `MenuScreen`, the current `formula.dart` — 146 files / ~28k
lines of diff) — it's the old crypto-core-only milestone. Branched off
`origin/feature/ink-substrate` instead (last pushed commit — has everything
Practice Mode depends on, excludes only the uncommitted local WIP). **If
"branch off main" comes up again before ink-substrate merges, check this
first** — the ask is almost always "decouple from uncommitted work," not
"decouple from everything built since the crypto-core milestone."

### Not device-tested this pass

Everything above is `flutter analyze` clean and covered by
`flutter test test/practice/ test/sorcerer/mfcc_dtw_steps_test.dart` (21/21
pass) plus a full-suite regression run (pre-existing SRS-network-download
and temp-dir-race flakes only, none touching Practice Mode files). Per the
verification hierarchy, "it compiles"/unit tests are not the top of the
ladder — a real-device or at least `flutter run -d linux` interactive pass
(mic permission prompt, real audio playback, live checkpoint highlighting)
was handed to Soren to run manually rather than automated in this session.
**Do not call Phase 1 done until that pass happens.**

## Mod-system seam orientation — deferred-feature findings (2026-07-05)

Orientation pass for a possible future mod system (player-toggleable formula
length 3/4/5, community-defined effect tables for longer patterns, an
ordered per-player mod-precedence stack). No code was written — the feature
stays documented-but-unbuilt, deferred until popular demand. Two findings
below matter independent of whether it ever ships; the third corrects a
type-level bug in the seam proposal itself before anyone builds against it.

### Latent exploit: mana cost is coupled to formula count, not just activation count

`_certifiedManaCost` (`lib/battle/engine/turn_loop.dart:1529`) computes
`effectCount` from `certFormulas.length`, i.e. `1.5^(effectCount-1)` scales
with how many complete formula-groups a trajectory produces. At the current
fixed formula length (3) this is an inert, faithful proxy for activation
count. It becomes a live, exploitable cost difference the moment formula
length is player-toggleable: the same trajectory (e.g. 9 committed
activations) would cost `1.5^2` at length 3 vs `1.5^0` at length 5 — same
work, cosmetic toggle producing a real cost delta.

**Fix, when the length toggle is built:** pin the cost divisor to a fixed
accounting constant (`BASE_FORMULA_LENGTH = 3`), independent of the
player's chosen display length —
`cost = 1.5^(floor(committed.length / BASE_FORMULA_LENGTH) - 1)` always. The
length toggle regroups the trajectory for effect lookup and display only,
never for cost accounting. This preserves all existing tests byte-for-byte;
do not switch to raw `committed.length` as the divisor, since that's a
different curve shape and silently rebalances existing length-3 play.

**This fix must land inside the same change as the length toggle, never as
a follow-up** — pre-toggle it's dormant, but shipping the toggle without it
arms a real exploit on day one.

### The v1-committed signed match record does not exist yet

Per `runewright_design_v3_0.md` ("Signed Match Records", `[APPLIED — ships
in v1]`), the match-record format is supposed to reserve three fields now,
even though Talewright itself is post-ship: **N signers** (not a hardcoded
pair — same trap as ruleset versioning), **embedded match config** (custom
HP, loadouts, grid size, toggle set), and an **optional stakes-hash**
(pre-committed, both-signed statement of what the outcome means; empty for
ordinary duels).

Orientation for the mod-system pass found no such struct in the codebase.
The only implemented Ed25519-signed struct is `SpellPermission`
(`lib/spells/spell_permission.dart`) — a loan/permission grant with no
config field — and `docs/BATTLE_PROTOCOL.md` §6 has only a stubbed per-turn
state-hash signature (`// TODO(battle)`).

**When this record is built** (for stakes/Talewright or any other reason),
reserve these additional fields in its config bundle at the same time, per
the same cheap-now/expensive-retrofit logic that motivated the original
three: `modStackHash` (nullable, absent = no mods active), `rulesetVersion`,
`tierMax`.

**No action needed now** — do not create this struct solely to hold these
fields. This is a note for whoever builds the v1 record next, whatever
motivates that work.

### Correction to the mod-manifest seam proposal: coverage-set element type

The mod-system orientation proposal (chat-only, not yet written to any
file) sketched `ModManifest.coverage: Map<int, Set<List<BorderZone>>>`.
That has a latent bug worth fixing in the design, not the code — nothing is
built yet: `Set<List<BorderZone>>` uses identity equality on a raw `List`,
so two structurally-equal patterns would be treated as distinct set
members, and coverage checks would silently misclassify.

Whatever immutable `Pattern` wrapper (value equality + `hashCode`) gets
introduced for the resolver's map key (the `resolvePattern` seam) must also
be the element type in the manifest's coverage sets — one wrapper type, not
two ad hoc solutions to the same problem. Recording this here since it's
the only standing note on the mod-system seams; a future implementer should
read this section before building `ModManifest` or the resolver.

## Battle protocol security audit (B-round) — pre-existing divergence findings

### `nextSpellCostDouble` state-hash desync (pre-existing, fixed in B-1/B-8 pass)

**Severity:** State-hash mismatch (protocol violation / match abort) whenever
`nextSpellCostDouble` fires for a peer spell.

**Root cause:** `nextSpellCostDouble` is a status effect tracked in
`WizardAvatar.activeStatusEffects`, which is included verbatim in
`BattleState.toCanonicalBytes()` (the end-of-turn state hash). When a peer
casts a spell while the effect is active, the caster's client deducts the
doubled cost and removes the effect in phase 1 via `_spellManaCost`.
The verifier's former `_spellManaCostFromProof` never touched `activeStatusEffects`
at all — it didn't consume `nextSpellCostDouble`, didn't apply the HP-shortfall
conversion, and didn't remove the entry. At state-hash exchange, the caster has
removed one status effect; the verifier still holds it. The hashes diverge
deterministically every time the effect fires on a peer spell.

**The same bug pattern applies to the sorcerer-mode `manaCostMultiplier`:** the
caster applied the vocal-quality penalty multiplier in phase 1 via
`CastingEnhancements.fromSorcererQuality`; the verifier's
`_spellManaCostFromProof` did not, causing the two devices to deduct different
mana amounts from the peer's avatar — a live ledger divergence, though not a
state-hash divergence (mana is in the hash, but the effect list removal is the
immediate trigger).

**Fix:** `_spellManaCostFromProof` replaced by `_certifiedManaCost`
(B-1/B-8 pass, `lib/battle/engine/turn_loop.dart`). The new function applies
operations in the same sequence as `_spellManaCost`: certified base → chain
discount → sorcerer multiplier → `nextSpellCostDouble` (consume + HP shortfall +
effect removal). Both paths now produce identical mana deductions and identical
`activeStatusEffects` mutations for the peer, so the end-of-turn state hash
agrees.

**Scope:** 2-player only. Affects any match turn where a peer casts a spell and
`nextSpellCostDouble` is active in their status-effect list. Was silently
unreachable in hardware testing because `nextSpellCostDouble` is not yet granted
by any effect — first cast to grant it would have triggered the mismatch.

---

## M4.7 — Loose-ends cleanup sweep (post-gate)

Five items logged during the M4.6 hardware run, addressed in order of
importance. None of these block the gate result (M4.6) -- this is hardening
and trap-removal. A sixth, unplanned item came directly out of fixing
item 4 (below) -- see "Bonus finding."

### Bonus finding: item 4's fix exposed a real frame-drop race in `MatchSession`

Verifying "the full suite stays green" surfaced a genuine bug, not a test
artifact. After fixing item 2 from M4.6 (`runVerifierFlow` now calls
`initSrsCached` before `verifyIncomingProof`, to initialize the CRS),
`test/ui/gate_runner_test.dart`'s rejection-path test started reliably
**hanging** for the full 60s timeout -- both standalone and in the full
suite.

Root cause, in `lib/protocol/match_session.dart`: `_onFrame` only delivers
an incoming frame if `_pending` (a completer set by `_awaitNextFrame()`) is
already non-null -- **a frame that arrives before anything is waiting for
it was silently dropped**, not buffered. This was always a latent race
(any verifier-side setup latency before the first `_awaitNextFrame()` call
-- asset loads, anything -- could lose this race against a prover fast
enough to have already sent), but the window had apparently never been
wide enough in practice to lose reliably until item 4's fix added a real
disk-I/O `await` (the CRS init) in front of `verifyIncomingProof()`'s call.
**This is not a test-only concern: in the real game, any verifier-side
setup work before the first frame is awaited creates the identical window
against a prover peer who already sent.**

Fix: `MatchSession` now buffers at most one frame (`_bufferedFrame`) when
`_onFrame` fires with nothing waiting; `_awaitNextFrame()` checks that
buffer before creating a new completer. Matches the existing strict
request/response, no-pipelining design (`FrameReader`'s own doc comment)
-- only ever one frame in flight, so buffering exactly one is sufficient
and correct, not a partial fix.

Verified: the previously-hanging test now passes in ~8s, standalone and
inside the full suite; the entire protocol suite (`wire_test.dart`,
`match_session_test.dart`, `match_session_socket_test.dart`,
`lan_discovery_test.dart` -- 26+ tests) re-confirmed green afterward, so
the fix didn't regress anything the relay-attack/replay/rejection tests
depend on.

### 1. mDNS interface selection -- logic fixed and unit-tested; end-to-end discovery still a hardware follow-up

`lib/protocol/lan_discovery.dart` gained `filterRealWifiAddresses` and
`selectBestAddressFrom`/`selectBestAddress`: excludes Wi-Fi-Direct-named
interfaces (substring match on `p2p`, covers OEM variants like
`p2p-wlan0-0`) and Android's reliable Wi-Fi Direct subnet
(`192.168.49.0/24`) as a second, independent check (defense in depth in
case an OEM names a p2p interface something that doesn't contain "p2p").
When picking among a peer's resolved addresses, prefers one sharing this
device's own real-Wi-Fi /24 subnet -- both duel peers on the same AP share
a subnet; their respective Wi-Fi Direct addresses never do. Falls back
gracefully (excludes-Wi-Fi-Direct, then "first address") rather than
failing outright if every candidate looks suspect. `gate_screen.dart`'s
"Listening on ..." display hint now calls the same `preferredLocalAddress()`
instead of duplicating its own (buggy) interface-picking logic.

10 unit tests in `test/protocol/lan_discovery_test.dart`, all green,
against representative interface lists modeled on exactly what the M4.6
hardware run saw (a real `wlan0` alongside a `p2p0`/`192.168.49.x`
interface).

**Still open, flagged explicitly per the M4 plan's done-state:** this
closes the *logic* gap, but automatic mDNS discovery connecting two real
devices over real Wi-Fi has not been re-confirmed on hardware since this
fix landed -- `nsd` has no Linux desktop backend at all (M4.4), so this dev
machine cannot exercise real discovery regardless. **The M4.6 hardware run
used manual IP entry, not automatic discovery, and that remains the
validated path.** Confirming automatic discovery now correctly prefers the
real Wi-Fi address end-to-end is a two-device follow-up for Soren's next
hardware session, not something closable from this machine.

### 2. Stale `.so` guard

`scripts/check_ffi_fresh.sh` (new): compares the deployed Android `.so`'s
mtime against every file under `ffi/src/`; prints a clear "stale, run
build_android_ffi.sh" message and exits 1 if any source file is newer.
Converts the M4.6 launch-crash failure mode ("Content hash on Dart side is
different from Rust side") into an early, legible warning. Verified both
directions: flags staleness correctly when a source file is touched, and
reports clean once rebuilt. Added as Bug Avoidance Reminder #3 in
`CLAUDE.md` (alongside a new #4 for the CRS-init bug, M4.6) so it's
actually run, not just available. Confirmed via dogfooding: correctly
flagged itself stale again after this cleanup's own edit to
`ffi/src/api/prover.rs` (the atomic-write change, item 4 below) -- left
that staleness in place since no device run is needed for this cleanup
pass; rebuild before the next one.

### 3. Undersized dev SRS fixture -- deleted, not routed around

`~/.bb-crs/bn254_g1.dat` (16 MB, exactly 2^18 G1 points -- correctly sized
for tier-12's *unmultiplied* requirement specifically, not generically
"undersized") was a dev-machine-local artifact, never part of the repo,
left behind after `lib/ffi/prover.dart`'s `initSrs(srsPath:)` forwarding
was reverted in favor of `initSrsCached`. Confirmed via grep that nothing
in the codebase referenced it any more. Deleted outright, and rewrote the
stale comment in `prover.dart` (which named a Dart constant,
`gate_runner_test.dart`'s `_kSrsCachePath`, that no longer exists --
already-removed in M4.6) to explain the actual failure mode (file sized
for one circuit's point count breaks silently if reused for a bigger tier
or a multiplied-margin code path) without pointing at a fixture that could
trap a future session into the same confusion again.

### 4. Atomic SRS cache write

`ffi/src/api/prover.rs`'s `get_srs_cached` previously wrote a freshly
downloaded SRS straight to `cache_path` via `LocalSrs::save` (a single
non-atomic `std::fs::write` internally, confirmed by reading the `noir_rs`
source). An interrupted write (app killed mid-save, flaky in-person
network) could leave `cache_path` itself half-written -- and since
`get_srs_cached` only checks "does the file exist," every subsequent run
would hit the existing corrupt-file error path forever, never
self-healing.

New `save_srs_cache_atomic`: serializes to a uniquely-named temp file in
the same directory as `cache_path` (same filesystem -> the final rename is
atomic per POSIX), `fsync`s the temp file's actual on-disk contents
(`LocalSrs::save`'s internal `fs::write` doesn't fsync, so without this an
interrupted-at-power-loss case could still rename in data that was never
flushed to disk), then renames into place. A failure or panic at any point
before the rename leaves only the never-read temp file behind --
`cache_path` is either still absent or still holds its previous contents,
never a partial write. Confirmed corrupt-cache handling (the pre-existing
`corrupt_cache_file_returns_err_not_panic` test) still covers the
genuinely-corrupt case (e.g. an old version's cache format, or
filesystem-level bit rot) -- atomicity prevents *new* corruption from
interrupted writes; it doesn't and shouldn't change how an
already-corrupt file already on disk is handled.

Two new Rust tests: `atomic_save_round_trips_and_leaves_no_temp_file`
(happy path, plus confirms no `.tmp-*` leftovers) and
`failed_save_does_not_create_a_partial_file_at_cache_path` (forces a
write failure by targeting a nonexistent parent directory; confirms
`cache_path` is never touched, not even partially). All 7 Rust tests pass
(5 pre-existing + 2 new; 1 of the pre-existing 6 is `#[ignore]`d by design,
requires a real network-denial environment).

### 5. `connect_path` label imprecision -- fixed

`gate_screen.dart`'s `_listenAndAdvertise` labeled every incoming
connection `connect_path=mdns`, even though the listening side cannot
actually tell whether the peer found it via mDNS discovery or typed the
address manually (both produce an identical incoming TCP connection) --
this is exactly what the M4.6 hardware run's log showed (Pixel 9 logged
`connect_path=mdns` even though Pixel 6 connected via manual IP entry).
Relabeled to `connect_path=listening`, with a code comment explaining why
`mdns` would overclaim a path that was never actually observed from the
acceptor's side. The *initiating* side's label was already accurate
(`manual_ip` / will be `mdns` once discovery is hardware-confirmed) and is
unchanged.

### Verification run

- `flutter test test/protocol/lan_discovery_test.dart`: 10/10 pass.
- `cargo test --lib` (ffi/): 7/7 pass (1 ignored by design).
- Full protocol suite after the bonus frame-buffering fix
  (`wire_test.dart`, `match_session_test.dart`,
  `match_session_socket_test.dart`, `lan_discovery_test.dart`): all green,
  confirming the fix didn't regress the relay-attack/replay/rejection
  tests that depend on this exact dispatch path.
- **Full `flutter test` suite (94 tests across every file, including the
  parallel onboarding/spell-inscription work's tests): 93/94 pass.** The
  one failure, `test/widget_test.dart`'s "Game screen renders hex grid",
  is **pre-existing and unrelated** to M4 -- it asserts against the old
  `GameScreen`-direct UI (`find.text('Rune Duel')`, a "Step" button, a
  "Fire" rule button), but `main.dart`'s `home` now points to `AppRoot()`
  (the Step 1 onboarding flow, from the parallel onboarding session, not
  touched by M4 at all). Confirmed via reading `main.dart`/`widget_test.dart`
  directly, not just "presumed pre-existing" -- this is a stale smoke test
  left behind by the onboarding work's app-structure change, out of this
  cleanup's scope to fix (not an M4/networking concern, and fixing it would
  mean editing test assumptions about in-progress, not-mine onboarding UI
  work). Flagged here rather than silently left unmentioned.
- Full golden-vector corpus + Dart stepper regression: zero regression
  (circuits/stepper untouched by this cleanup).
- `flutter analyze`: clean throughout.
- The Android `.so` is currently flagged stale by `scripts/check_ffi_fresh.sh`
  (the bonus `match_session.dart` fix + item 4's `prover.rs` change
  postdate the last `cargo ndk` build). Deliberately left unrebuilt --
  no device run is part of this cleanup pass -- run
  `bash scripts/build_android_ffi.sh` before the next one.

---

## M4.6 — THE GATE: real two-device hardware run, ACCEPTED on both sides

### Result

Full success, both directions of the M4 plan's milestone gate, on real
hardware (Pixel 6 + Pixel 9, both on the same real Wi-Fi AP, no special
network configuration). Pixel 6 = Prover/Signer, Pixel 9 = Verifier/
Challenger, connected via the manual-IP path. Every step passed on both
devices:

```
Pixel 6 (prover):  connect → handshake → identity → proof_generated
                    (wall_ms=5702, matches the historical ~5.9s Pixel 6
                    tier-12 figure from M3.4) → proof_sent → final=accepted
Pixel 9 (verifier): connect → handshake → vk (CRS initialized) →
                    proof_received (17028B) → proof_verified=true →
                    owner_pubkey_matched=true → challenge_issued →
                    signature_verified=true → final=accepted
```

Full `RUNEWRIGHT_GATE` logcat trace from both devices, real timestamps:

```
Pixel 6:
15:50:34.928 step=discovered  value=n/a      connect_path=manual_ip detail="manual entry 192.168.1.229:42223"
15:50:34.928 step=connected   value=true     connect_path=manual_ip detail="manual_ip"
15:50:35.387 step=identity_loaded value=true connect_path=manual_ip detail="owner_pubkey=0x0e4a6a966b1a198563bdc672c3e412b3e915fc9e9ee19db1a4e118720e0bf94e"
15:50:42.246 step=proof_generated value=true connect_path=manual_ip detail="wall_ms=5702"
15:50:42.246 step=proof_sent  value=true     connect_path=manual_ip
15:50:43.458 step=signature_returned value=true connect_path=manual_ip
15:50:43.458 step=final       value=accepted connect_path=manual_ip

Pixel 9:
15:50:04.270 step=discovered  value=n/a      connect_path=mdns detail="host: listening on 192.0.0.4:42223"
15:50:05.165 step=discovered  value=true     connect_path=mdns detail="advertised as Runewright Duel"
15:50:35.369 step=connected   value=true     connect_path=mdns detail="mdns/manual host"
15:50:42.704 step=proof_received value=true  connect_path=mdns detail="17028B"
15:50:42.763 step=proof_verified value=true  connect_path=mdns
15:50:43.824 step=owner_pubkey_matched value=true connect_path=mdns
15:50:43.824 step=challenge_issued value=true connect_path=mdns
15:50:43.824 step=signature_verified value=true connect_path=mdns
15:50:43.824 step=final       value=accepted connect_path=mdns
```

This closes the M4 milestone: identity, the match protocol, the LAN
transport, and on-device proving all confirmed working together, end to
end, on two physical devices.

### A real bug the hardware run found that no automated test had caught

`verify_ultra_honk` requires barretenberg's global CRS initialized via a
prior `srs_init` call. On the prover side this always happened
incidentally (proving calls `initSrsCached` first). The verifier path
(`GateRunner.runVerifierFlow`) never called anything that initializes it,
and the first hardware run failed with `circuit_verify failed: Backend
error: You need to initialize the global CRS with a call to
init_crs_factory(...)`.

**This is a real bug in the production match-protocol path, not a
harness-only issue:** any real duel verifier who hasn't proven anything in
that app session yet would hit the identical failure the first time they
verify an opponent's proof. **No desktop test caught it** because
`test/ui/gate_runner_test.dart`'s happy-path test runs both prover and
verifier in the *same process* -- the prover's SRS init incidentally
populates the same global barretenberg state the verifier's `verify_proof`
then reads, masking the missing initialization entirely. Two separate
device processes, each with their own process-local global CRS state, was
the only thing that surfaced this. This is exactly why the M4 plan called
the two-device run a milestone gate rather than trusting automated tests
alone to close M4.

**Fix:** `GateRunner.runVerifierFlow` now also calls `initSrsCached` (sized
to the same circuit bytecode) before verifying, even though it never
proves. `runVerifierFlow`'s signature gained `circuitJson`/`srsCachePath`
parameters to match `runProverFlow`'s shape. Confirmed fixed by the
hardware run above. The same fix should be carried into the real (non-
diagnostic) match protocol wiring whenever it's built -- **a verifier must
initialize the SRS/CRS before its first `verify_ultra_honk` call,
independent of whether it has ever proven anything in that session.**

### Two smaller findings from the hardware run (logged, not blockers)

- **`_localIpHint()` picks the wrong interface on real Android hardware.**
  Pixel 9 displayed "Listening on 192.0.0.4:42223" -- that's a Wi-Fi Direct
  p2p interface, not the real Wi-Fi address (192.168.1.229, confirmed via
  `adb shell ip addr show wlan0`). The underlying socket is still correct
  (bound to `InternetAddress.anyIPv4`, reachable on every interface
  including the real one) -- this only affects the *displayed* hint text
  used for manual-IP entry. `_localIpHint()`'s "first non-loopback IPv4
  from `NetworkInterface.list()`" is too naive on real devices with
  multiple interfaces; it should prefer the `wlan0`-equivalent
  specifically. Cosmetic for the gate harness (worked around by knowing
  the real IP independently for this run); worth fixing before this UI
  pattern is reused anywhere a player relies on the displayed hint.
- **`connect_path=mdns` is logged on the listening side even when the
  peer actually used manual IP entry.** `_connectPath` is set to `'mdns'`
  as soon as "Listen + Advertise" is tapped (since that path always also
  advertises via mDNS), but doesn't distinguish "a peer discovered me via
  mDNS" from "a peer typed my IP manually" -- both arrive as the same
  `acceptOnce()` completion. The *initiating* side's log is accurate
  (`connect_path=manual_ip` correctly reflects what Pixel 6 did); only the
  listening side's label is imprecise. Logged for awareness, not fixed --
  doesn't affect this run's validity since Pixel 6's own log is unambiguous
  about which path was actually used.

### Verification run

- Real hardware: Pixel 6 (`18261FDF60069A`) + Pixel 9 (`4B070DLAQ002FQ`),
  both on the same Wi-Fi AP, full ACCEPTED both directions (see above).
- `flutter analyze`: clean throughout.
- `test/ui/gate_runner_test.dart` re-confirmed green after the CRS-init fix
  (now more faithfully exercises the verifier's independent SRS init,
  rather than incidentally relying on the prover's in-process state).
- Found and fixed, before it could affect a real build: an Android `.so`
  staleness issue (content-hash mismatch between Dart FRB bindings and the
  compiled Rust `.so` -- `ffi/src/api/identity.rs` and the `init_srs_cached`
  addition to `prover.rs` postdated the last `cargo ndk` build, causing an
  immediate crash on launch: "Content hash on Dart side is different from
  Rust side"). Rebuilt via `scripts/build_android_ffi.sh`; all linkage
  checks passed. **General lesson for next time:** after any Rust-side FFI
  change, the Android `.so` needs an explicit rebuild before the next
  device run -- it is not regenerated automatically by `flutter build`.

---

## M4.5 — Two-device gate harness (diagnostic UI, not game UI)

### What was built

- **`lib/ui/gate_runner.dart`**: pure async orchestration (no Flutter
  widget dependency) for the prover/signer and verifier/challenger flows.
  Calls only existing, already-tested entry points -- `MatchSession`,
  `Identity`, the FFI prover -- in the same sequence those modules already
  define; adds no new protocol/crypto logic.
- **`lib/ui/gate_screen.dart`**: the actual screen. Two first-class connect
  paths (Listen+Advertise via `lan_discovery.dart`/mDNS, and a manual
  host:port field that bypasses discovery entirely), a role toggle
  (Prover/Signer vs Verifier/Challenger), and a per-step status list. Wired
  as the app's `home` (superseding `SpikeScreen` the same way `SpikeScreen`
  superseded the M2 spike before it -- not deleted, just no longer `home`).
- **Per-step visibility, without touching protocol logic:** most steps
  (`owner_pubkey_matched`, `challenge_signature`, etc.) are reconstructed
  from a thrown `ProtocolException`'s `(reason, message)` or from
  `presentProof`/`verifyIncomingProof`'s successful completion --
  `match_session.dart` was **not** modified to add progress callbacks, per
  the explicit instruction to stop and flag rather than touch protocol
  logic. This works because `RejectReason` is already an ordered,
  exhaustive enum of exactly where a rejection happens (a consequence of
  how the protocol was designed in M4.1, not a new mechanism). The one step
  with genuine **live** visibility, `proof_verified`, uses the
  `verifyIncomingProof(verifyProof: ...)` injection seam that already
  existed for testing -- the harness's `verifyProof` callback reports status
  before returning the bool, which is not a protocol change either.
- **Minimal, additive lifecycle methods added to the transport layer**
  (flagged, not silently done): `LanListener.close()` (cancel a listener
  before it accepts -- was previously impossible to release without an
  incoming connection) and using the already-existing but previously-unused
  `MatchSession.close()` in the screen's teardown path. Neither changes any
  existing behavior; both fill a gap any well-behaved caller of `bind()`
  would eventually hit.
- **Connect-path layer isolation, by design:** mDNS advertise failing does
  not block the listening socket from accepting a manual-IP connection --
  the advertise call is wrapped separately and logged as its own
  found/not-found event, so a real-device run can tell "mDNS doesn't work
  here" apart from "sockets don't work here" instead of one opaque failure.
- **Caught a real bug before it shipped:** the first draft used the name
  `StepState` for the harness's own enum, which collides with
  `package:flutter/material.dart`'s `Stepper` widget's own `StepState` --
  silently ambiguous-import errors, not a runtime bug, but would have
  blocked compilation. Renamed to `GateStepState`.

### Verification run

- **`test/ui/gate_runner_test.dart` -- the harness's logic confirmed against
  the real stack**, not mocks: real on-device (desktop) proving of the
  fixed tier-12 witness with a real `Identity.ephemeral()` key, real
  `MatchSession` exchange over real localhost TCP sockets, real
  `verify_ultra_honk`. Two tests:
  - Happy path: both sides reach `final = pass`; `proof_generated` carries
    a real `wall_ms` (~2.3-2.4 s on this desktop, consistent with prior
    M2/M3 desktop-proving figures); `proof_verified` confirmed to fire live
    via the injection seam, not just inferred from success.
  - Rejection path: a real, cryptographically valid proof presented under
    the *wrong* pubkey -- confirms `proof_verified = pass` but
    `owner_pubkey_matched = fail` are correctly distinguished, i.e. the
    granular reporting genuinely isolates *which* check failed rather than
    collapsing to one generic failure.
  - Both used the cached SRS (`~/.bb-crs/bn254_g1.dat`, 16 MB) -- no
    network download needed in this environment.
- `flutter analyze`: clean.
- Golden-vector corpus: zero regression (untouched by this milestone).

### What this does NOT verify (the actual gate)

- mDNS advertise/discover on real hardware (no Linux backend at all --
  same limitation as M4.4).
- Real radio behavior (Wi-Fi association, AP/client isolation, multicast
  deprioritization).
- The actual UI rendering/interaction (button taps, step list updates) --
  `gate_runner_test.dart` exercises the orchestration logic the screen
  calls into, not the screen itself.
- A second physical device, full stop.

This harness is ready for the two-device run. It needs two phones on a
controlled Wi-Fi network -- Soren's to perform.

---

## M4.4 — mDNS/NSD discovery + Android manifest permissions

### What was built

- **`lib/protocol/lan_discovery.dart`**: `advertiseDuelHost`/
  `stopAdvertisingDuelHost` (register/unregister an `_runewright._tcp`
  service) and `discoverDuelHosts`/`stopDiscoveringDuelHosts` (start/stop
  discovery), plus `connectToDiscoveredService(Service)` which feeds a
  resolved service's address/port straight into
  `LanSocketTransport.connectTo`. Uses `package:nsd` rather than
  `multicast_dns`: `nsd` wraps the native NSD/Bonjour stack on each platform
  and supports *registering* (advertising) a service, not just resolving
  one -- `multicast_dns` is a pure-Dart mDNS *client* only and would need a
  hand-rolled mDNS responder to advertise.
- **Deliberately not wired into `Transport`'s `advertise()`/`discover()`/
  `connect()` methods.** Those three thin method signatures don't fit
  `nsd`'s actual shape (a `Service` object, a `Registration` handle to
  unregister later, a `Discovery` that streams multiple found/lost peers
  over time) without losing information or stashing hidden state. Both
  `InMemoryTransport` and `LanSocketTransport` already treat
  advertise/discover/connect as no-ops, with real connection setup via
  dedicated static factories instead (`pair()`, `bind()`+`connectTo()`).
  `lan_discovery.dart` follows the same shape: a separate layer that
  *produces* a connected `LanSocketTransport`, not a method bolted onto
  one. Consistent with the existing pattern, not a new exception to it.
- **Android manifest** (`android/app/src/main/AndroidManifest.xml`): added
  `CHANGE_WIFI_MULTICAST_STATE`, per `nsd`'s own README-documented Android
  requirement. `INTERNET` was already present (covers the LAN sockets).
  **Correction to the M4 brief's guess:** the brief suggested
  `ACCESS_WIFI_STATE` would "likely" be needed too -- checked against the
  package's actual documented requirements rather than assuming, and it
  isn't; only `CHANGE_WIFI_MULTICAST_STATE` is listed. Not added, since
  nothing in this codebase uses it for anything (no Wi-Fi-state queries
  exist), and unused permissions are something to avoid, not hedge in.
- **Caught a real bug before it shipped:** the first draft of the manifest
  comment used `--` (double hyphen) inside an XML comment, which is invalid
  per the XML spec and would have broken the Android build. Caught by
  validating the manifest with a parser before moving on, not by trusting
  the edit -- worth calling out since it's exactly the kind of error that's
  invisible in a diff review but fails at build time.

### Known limitation: cannot be tested in this dev environment

- `nsd`'s platform support is Android/iOS/macOS/Windows -- **no Linux
  desktop backend at all** (unlike `flutter_secure_storage`, which at least
  has a native Linux plugin reachable only outside `flutter test`; `nsd`
  has no Linux implementation to reach regardless of how it's run). There
  is no way to exercise real mDNS advertise/discover from this machine.
- This isn't a gap to paper over: real mDNS discovery is inherently a
  real-network concern (AP/client isolation on guest Wi-Fi, multicast
  deprioritization, platform-specific timing) that **only the two-device
  validation gate can actually test**, per the M4 plan's own "characterize,
  don't assume a code bug" guidance. Nothing here substitutes for that.

### Verification run

- `flutter analyze`: clean (after fixing the manifest XML comment bug
  above; re-validated with `xml.etree.ElementTree` before considering it
  done).
- `dart pub get`: `nsd` resolves cleanly alongside the rest of the M4
  dependencies.
- No automated test for `lan_discovery.dart` itself (see limitation above);
  the code is exercised for the first time at the two-device gate.

---

## M4.3 — LAN socket Transport: localhost checkpoint (abstraction-integrity confirmed)

### What was built

- **`LanSocketTransport`** (`lib/protocol/lan_socket_transport.dart`): a
  `Transport` adapter over `dart:io` TCP sockets. `LanSocketTransport.bind()`
  + `LanListener.acceptOnce()` for the listening side (split into two steps
  so the caller learns the OS-assigned port before a peer connects),
  `LanSocketTransport.connectTo(host, port)` for the dialing side -- mirrors
  `InMemoryTransport.pair()`'s "two already-connected ends" shape rather
  than using the interface's `advertise/discover/connect` methods directly
  (same as `InMemoryTransport`; those become meaningful once mDNS discovery
  is wired in as a separate piece).
- **Zero changes to `MatchSession` or the protocol logic.** Confirmed by
  literally sharing the test bodies: `test/protocol/match_session_suite.dart`
  holds all 6 protocol tests parameterized over a `Transport`-pair factory;
  `match_session_test.dart` (in-memory) and `match_session_socket_test.dart`
  (real localhost sockets) both call the identical suite. This is the
  abstraction-integrity check the plan asked for, made structurally
  impossible to fake (the same test code runs against both transports, not
  just "tests with the same names").
- **Why `LanSocketTransport` needed no framing logic of its own:** TCP is a
  byte stream, not message-delimited, but `MatchSession` already routes
  every incoming chunk through `wire.dart`'s `FrameReader`, which was built
  generically (not socket-specific) to reassemble a byte stream into frames
  regardless of how it's chunked. A `Socket` is already a `Stream<Uint8List>`,
  so the adapter is a thin pass-through (`send` -> `_socket.add`, `onReceive`
  -> `_socket` directly). The correctness work for partial/coalesced reads
  lives in exactly one place, not duplicated per transport.
- **`FrameReader` stress-tested directly, not just incidentally** -- added
  `test/protocol/wire_test.dart` because localhost sockets are fast enough
  that the socket-transport tests might never actually trigger a split-
  across-many-reads or two-coalesced-frames scenario in practice (timing-
  dependent, not guaranteed). Tests force both directly: a frame fed to
  `FrameReader.addChunk()` one byte at a time, two frames coalesced into a
  single chunk, and three frames re-chunked at arbitrary non-frame-aligned
  boundaries (mid-header and mid-payload cuts). All four pass.

### Verification run

- `flutter test test/protocol/wire_test.dart test/protocol/match_session_test.dart test/protocol/match_session_socket_test.dart -d linux`:
  **16/16 pass** -- 4 `FrameReader` stress tests + 6 protocol tests over
  in-memory + the identical 6 over real localhost sockets, zero failures,
  zero `MatchSession` changes between the two transport variants.
- `flutter analyze`: clean.

### Not yet built (remaining in Task B)

- mDNS/NSD discovery (`advertise()`/`discover()`/`connect(peerId)` are still
  no-ops on `LanSocketTransport` -- connection setup currently requires
  already knowing host:port, fine for the localhost checkpoint, not for
  real field use).
- Android manifest permissions for NSD/multicast.
- The real LAN-between-two-devices run and the two-device validation gate.

---

## M4.2 — Identity backup (export/import) + third poseidon2_hash2 cross-check vector

### What was built

- **Identity backup** (`lib/identity/backup_format.dart`, `backup.dart`,
  `backup_io.dart`): manual, no-server export/import of the on-device Ed25519
  seed. Self-describing PEM-armored binary format (magic + version, fails
  loudly on unknown formats rather than corrupt-importing). Encryption
  on-by-default: Argon2id (OWASP-recommended interactive minimum: 19 MiB
  memory, 2 iterations, parallelism 1) -> XChaCha20-Poly1305 AEAD, both from
  `package:cryptography` (already a dependency, vetted, nothing hand-rolled).
  Plaintext export requires an explicit `acknowledgedPlaintextRisk: true`
  the UI must only set after showing the key-exposure warning. Import
  requires `confirmOverwrite: true` the same way -- destructive by design,
  never silently overwrites. File save/pick glue uses one plugin
  (`file_picker`, both `saveFile(bytes:)` and `pickFiles(withData: true)`
  work in bytes, not paths, so Android scoped storage is a non-issue).
- **Key rotation note, flagged not solved:** importing a different seed than
  the one currently on-device is, semantically, a key rotation event. This
  code does not re-sign or otherwise touch any in-flight delegation
  (master/apprentice loans, scrolls) bound to the old `owner_pubkey` -- the
  delegation system doesn't exist yet, so there's nothing to re-sign today,
  but **when it's built, key rotation must account for invalidating/
  re-issuing delegations tied to the old key.** Recorded here so it isn't
  rediscovered as a surprise later.
- **Third `poseidon2_hash2` cross-check vector** (`ffi/src/api/identity.rs`):
  a cryptographically random 32-byte key (not the second vector's sequential
  `0..31` pattern), split via the same first16/last16-LE convention
  (`key_hi = 0xc99502afe3f0288a3add28af7f7f1e1e`,
  `key_lo = 0xcb2712a65f5ad1234bf601a8d349c6ec`), run through
  `poseidon2_hash2` to get
  `owner_pubkey = 0x1c2b369adc1352bf11e6db4989574f413e7d8d43bd3edfc3b87c281f41129aa7`,
  then through `nargo execute` against `circuits/ca_v2_4_tier12` --
  **"Circuit witness successfully solved."** `Prover.toml` restored
  afterward. `poseidon2_hash2` now has three cross-oracle vectors (zero,
  sequential non-zero, random non-zero), all agreeing with the real circuit.

### Toolchain/test-environment notes

- **`flutter_secure_storage_linux` is a native-only plugin (no Dart code at
  all)**, registered at native engine startup -- only reachable from a real
  `flutter run -d linux` process, never from `flutter test` (which always
  runs on the headless Flutter Tester engine regardless of `-d`). Backup
  tests that exercise `Identity.loadOrCreate`/`overwriteWithSeed` install an
  in-memory mock for the `plugins.it_nomads.com/flutter_secure_storage`
  method channel (`test/identity/fake_secure_storage.dart`) rather than
  hitting real storage -- confirmed via a throwaway smoketest that the real
  channel is genuinely unreachable under `flutter test`, not a transient
  failure.
- **`flutter test <directory>` has a cosmetic output-interleaving quirk** in
  this environment -- test names from one file occasionally print duplicated
  against the wrong index when multiple files in a directory are discovered
  together (final pass/fail count is still correct). Running explicit file
  paths (`flutter test test/identity/foo_test.dart test/identity/bar_test.dart`)
  gives clean, correctly-attributed output; used throughout M4 for that
  reason.
- `file_picker`'s public API is `FilePicker.saveFile(...)` /
  `FilePicker.pickFiles(...)` (static methods directly on the `FilePicker`
  class), not `FilePicker.platform.saveFile(...)` -- the `.platform`
  indirection is internal, not part of the public surface in 11.0.2.

### Verification run

- `flutter test test/identity/key_packing_test.dart test/identity/backup_test.dart -d linux`:
  15/15 pass (5 key-packing including the new high-entropy vector + 10
  backup), zero failures.
- `cargo test --lib` (ffi/): 3/3 pass (all three `poseidon2_hash2`
  cross-checks).
- `flutter analyze`: clean.

---

## M4.1 — Identity module + transport-agnostic protocol layer, green over in-memory transport

### What was built

- **Identity** (`lib/identity/`): on-device Ed25519 keypair generation, secure
  storage (`flutter_secure_storage`, Android Keystore-backed), the
  `key_hi`/`key_lo` split (`key_packing.dart`), and the ownership-challenge
  signing primitives (`identity.dart`).
- **A new Rust FFI surface** (`ffi/src/api/identity.rs`): `poseidon2_hash2`,
  exposed to Dart for the first time. Not anticipated in the original plan
  ("no FFI changes needed" turned out to be wrong) -- see below.
- **Protocol layer** (`lib/protocol/`): the pluggable `Transport` interface,
  an in-memory loopback implementation for tests, the wire framing
  (`wire.dart`), the confirmed proof-wire-format reader (`proof_wire.dart`),
  and the match protocol state machine (`match_session.dart`).
- **Tests**: a Dart round-trip test for the key split, a Rust cross-oracle
  test for `poseidon2_hash2`, an FFI smoke test, and 6 protocol tests over
  the in-memory transport (happy path, tampered proof, owner_pubkey
  mismatch, wrong signer, replayed/stale signature, relay attack). All green
  on first run.

### Finding: "Gamemaster mode" is not a duel-networking concept

The M4 brief asked to confirm which of two networking modes was in scope:
"peer-to-peer with both parties signing" vs. "a Gamemaster mode with single
merge authority." Reading `runewright_design_v2_4.md` end to end: Gamemaster
Mode only exists as one of three *storytelling* modes under Talewright
(line 918) -- a GM narrates a TTRPG-by-text and "cannot override
battle-outcome signatures." It has no networking/merge-authority concept and
Talewright is explicitly post-ship/out of scope. There is exactly one duel
protocol in the design (Battle Integrity / Owner Binding sections): two
co-present peers, per-turn signing, commit-reveal randomness, a per-match
Ed25519 ownership challenge. No decision was needed; the brief's premise was
incorrect.

### Finding: a new FFI surface was required, not anticipated in the plan

`CIRCUIT_IO.md` §5 requires "the verifying client recomputes
`Poseidon2(split(presented_key))` and checks equality" -- but no Poseidon2
function was exposed to Dart, and `CLAUDE.md` invariant 1 forbids
reimplementing Poseidon2 in Dart. Closed by exposing
`bn254_blackbox_solver::poseidon2_permutation` (acvm-repo, part of the noir
monorepo, pinned via `rev = "v1.0.0-beta.20"` to the **exact commit**
(`b4236c19...`) noir_rs already resolves transitively) through a new thin
FFI function, `poseidon2_hash2`, mirroring
`circuits/ca_v2_4_tier12/src/main.nr`'s helper of the same name exactly
(state = `[a, b, 0, iv]`, `iv = 2 * 2^64`, permute, take `state[0]`). This is
the literal ACVM/Noir-stdlib implementation, not a second one.

**Cross-oracle confirmation (two separate checks):**
1. `poseidon2_hash2("0x0", "0x0")` reproduces the known-good
   `owner_pubkey` value already verified end-to-end against the real
   circuit in `tamper_test.rs`/`desktop_vk_test.rs`
   (`0x0b63a53787021a4a962a452c2921b3663aff1ffd8d5510540f8e659e782956f1`).
2. A **non-zero** key vector (bytes `0..31` split first-16/last-16-LE,
   `key_hi = 0xf0e0d0c0b0a09080706050403020100`,
   `key_lo = 0x1f1e1d1c1b1a19181716151413121110`) was run through
   `poseidon2_hash2` to get
   `owner_pubkey = 0x228e9a8a908419c3c66a519957e70f0b45d5d1375a4b3bbe4b4662cd03aa3d89`,
   then fed into `circuits/ca_v2_4_tier12`'s `Prover.toml` and run through
   `nargo execute` (`~/.nargo/bin/nargo`, beta.20, commit `b4236c19` --
   matches the pinned toolchain exactly). **Result: "Circuit witness
   successfully solved"** -- the circuit's
   `assert(owner_pubkey == poseidon2_hash2(key_hi, key_lo))` held for a real
   non-zero key, not just the zero stub. `Prover.toml` was restored
   afterward; this was a throwaway cross-check, not a permanent vector.

### Finding: the `key_hi`/`key_lo` split is confirmed pure client convention (plan amendment 2)

Read `circuits/ca_v2_4_tier12/src/main.nr` lines 84-96: the only constraint
touching `key_hi`/`key_lo` is `assert(owner_pubkey ==
poseidon2_hash2(key_hi, key_lo))` over whatever two field values they are.
Zero in-circuit byte-order or half-assignment logic. The first-16/last-16,
little-endian split (`lib/identity/key_packing.dart`) is therefore entirely
a Dart-side convention -- closing the `CIRCUIT_IO.md` §5
`[CONFIRM vs stepper/client]` flag. A future platform (iOS) needing a
different native byte order can revise this function alone; the VK is
unaffected.

**iOS interop note (logged, not built):** when an iOS port is attempted, its
Ed25519 implementation must produce keys that, once split via this same
convention, are byte-compatible with Android's -- both platforms must agree
on `key_hi`/`key_lo` for the same logical key, not merely be internally
consistent each on its own.

### The relay-attack defense (plan amendment 1), as implemented

`MatchSession` (`lib/protocol/match_session.dart`) binds the ownership
challenge to `SHA256(len-prefixed(nonce, proof_public_inputs, match_id))`,
not the bare nonce. `match_id` is established once per session at handshake
time (`MatchSession.initiate`/`.accept`) and is never re-read from any later
message -- this is what defeats relaying a challenge from one session into
another: the relayed signature is bound to the *relaying* session's
match_id, which necessarily differs from the victim session's. Tested
directly in `test/protocol/match_session_test.dart`'s relay-attack case by
constructing the cross-session digest explicitly and confirming
`Identity.verify` rejects it.

**Known limitation, not silently ignored:** this defeats relaying an
*established* challenge across sessions. It does not by itself authenticate
the very first handshake against an active on-path adversary who controls
the transport during initial connection setup -- a deeper channel-binding
question, out of scope for M4's protocol layer.

### Toolchain note: `flutter pub add` / `dart pub add` / `flutter pub get` report exit 255 in this snap environment

All three report exit code 255 with **zero stdout/stderr**, even though the
underlying operation (resolving and writing `pubspec.lock`, modifying
`pubspec.yaml` for `add`) **succeeds** -- confirmed by inspecting the
resulting files after each "failed" call. `dart pub get` (not `add`) reports
exit 0 normally. Root cause not pinned down (snap-confine intercepts ptrace
and refuses under `strace`, which masks rather than explains the silent
255). Workaround used throughout M4.1: edit `pubspec.yaml` by hand, then run
plain `dart pub get` and verify via `pubspec.lock`/file diffs rather than
trusting the exit code.

### Toolchain note: `flutter_rust_bridge_codegen generate` needs explicit flags here

No `flutter_rust_bridge.yaml` config file exists in this repo, so the bare
`flutter_rust_bridge_codegen generate` (as documented in `M2_ffi_spike.md`)
now fails with "Please provide `rust_input`". Working invocation from repo
root:
```
~/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root ffi --dart-output lib/src/rust
```
(`~/.cargo/bin` is not on `$PATH` in this shell either.)

### Verification run, end to end

- `cargo test --lib` (ffi/): 2/2 pass (the two `poseidon2_hash2` cross-checks).
- `flutter test test/ffi/identity_ffi_smoketest.dart -d linux`: real FFI
  round-trip confirmed (not faked).
- `flutter test test/protocol/match_session_test.dart -d linux`: 6/6 pass,
  first run, including the relay-attack and replay cases.
- `flutter test test/identity/key_packing_test.dart`: 4/4 pass.
- `NARGO_BIN=~/.nargo/bin/nargo bash scripts/run_vectors.sh`: full
  stepper-regression + golden/negative corpus, **zero regression** -- same
  OK/SKIP pattern as the established M3 baseline (13 vectors, 0 failures).
- `flutter analyze`: clean (pre-existing unrelated `avoid_print` infos in
  `scripts/find_mask_vector.dart` only).

### Not yet built (next in the M4 plan)

- The real LAN-socket + mDNS transport adapter (plan step 3).
- Two-device validation (plan step 4).
- Wiring real (non-ephemeral) `Identity.loadOrCreate()` + real proofs into a
  minimal harness screen.
