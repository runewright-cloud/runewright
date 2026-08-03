# BASIC_SPELLS_PLAN.md — shipped starter spells + the `Basic` flag

*Written 2026-07-27 on `feature/practice-mode`. Implementation plan for the five
"Basic *" starter spells: bundle them with the app, seed them into every player's
library on first launch, and flag them so they may be added to a chapter any number
of times.*

**IMPLEMENTED 2026-07-27, same session.** See `docs/BASIC_SPELLS.md` for the
quick-reference + maintenance recipe and `docs/M4_findings.md`'s "Basic Spells"
entry for what this plan didn't anticipate. Two things surfaced during
implementation that this plan is silent on, both closed:
1. **A second anti-cheat guard** (`TurnLoop._seenPeerCommitments`, "Kin-stacking" —
   forbids casting the same grid twice per match) directly conflicted with
   unlimited chapter copies and needed its own scoped exemption (§4a of
   `docs/BATTLE_AUTH_PLAN.md`), on top of the ownership exemption this plan
   already called for.
2. **`§7`'s duplicate-copy fix required UI-layer plumbing** this plan didn't spell
   out in the same section: `SpellCastAction`/`MysterySpellCastAction` needed a
   `handIndex` field threaded from `battle_screen.dart`'s hand-selection state
   (`_selectedHandIndex`, keyed by slot, not by `SpellAsset.id` — duplicates share
   an id) through to `TurnLoop._localCastPosition`. Implemented as described in
   §7 E2, just more UI-side wiring than the plan enumerated.

Everything else below matches what shipped. The plan is left as originally written
(not rewritten to read as if it had predicted the above) so a future reader can see
what was anticipated vs. found.

**Scope guard:** this is a client-side feature. **No circuit change, no
`RULESET_VERSION` bump, no VK change, no new proving.** The five proofs already
exist and already verify. If you find yourself editing anything under `circuits/`,
stop — you have misread the plan.

---

## 1. What we are building

Two related things, deliberately keyed the same way:

1. **Ship the five basics.** Every install's library contains Basic Firebolt,
   Speedboost, Manabond, Earthworks and Windhound from first launch, without the
   player inscribing anything.
2. **Flag them as `Basic`.** A spell whose *(grid commitment, T)* pair is one of the
   five registry entries is Basic. Basic spells are exempt from the
   one-copy-per-chapter rule and from the owner-must-be-caster authorization rule.

Design decisions already settled by Soren (2026-07-27) — **do not re-litigate**:

| Decision | Answer |
|---|---|
| Authorization for shipped proofs | Compiled-in Basic allowlist |
| Copies of one basic per chapter | Unbounded |
| Deleting a basic | Allowed, stays deleted; add an explicit "Restore basic spells" action |
| Counter Charms targeting basics | Yes, basics are counterable — no code change |

---

## 2. The five spells (read from disk, not invented)

Currently persisted at `~/Documents/spells/` on the Linux dev machine. All five use
built-in pack art (`artSource: builtIn`), so **no art blobs need bundling** — only
the JSON. Total ~121 KB.

| Name | T | tier | mana | commitmentHex | spellHashHex | art pack id |
|---|---|---|---|---|---|---|
| Basic Firebolt | 6 | 12 | 13 | `0x21f8c1f0…a2391e` | `0x21f89f3d…7bd7f4` | `fireball-red-1` |
| Basic Speedboost | 6 | 12 | 13 | `0x0eb58f16…07215d` | `0x0e60aba7…5ecffa` | `wind-grasp-air-1` |
| Basic Manabond | 6 | 12 | 13 | `0x2a2f8e7b…ae85f3` | `0x1e9dabcf…22675a` | `beam-blue-1` |
| Basic Earthworks | 6 | 12 | 13 | `0x28507c37…a854b0` | `0x00ce1c5c…bcec52` | `rock-acid-1` |
| Basic Windhound | 23 | 24 | 83 | `0x2d587d7e…506194` | `0x1e053eb1…172919` | `haste-sky-1` |

Windhound is `isSummon: true`. All five carry
`ownerPubkeyHex = 0x2bc53f13…08eba22` (Soren's dev Runekey) — **that is the whole
reason §5 exists.**

Full-precision values are in `/home/soren/Documents/spells/*.json`. Do **not** hand-type
these hex strings into source: the export script in §3 generates the registry from
the files, per CLAUDE.md's "Do not invent these encodings — read them." Use the table
only as a cross-check that the generated file is right.

Note `Basic Earthworks`' spellHashHex begins `0x00` — a leading-zero field. Any hex
comparison you write must survive that (see §4).

---

## 3. Phase A — export the five into the asset bundle

**`scripts/export_basic_spells.dart`** (a Dart script run from the repo root; follow
the style of `scripts/generate_practice_assets.dart`):

- Read every `*.json` under a `--source` directory (default `~/Documents/spells`).
- Select the five by `spellHashHex`, from a literal list in the script — selecting by
  `name.startsWith('Basic')` is too loose to be a build input.
- Rewrite each `id` from its microsecond timestamp (e.g. `1785160295148381`) to a
  **stable slug**: `basic_firebolt`, `basic_speedboost`, `basic_manabond`,
  `basic_earthworks`, `basic_windhound`. Everything else — `proofBytesBase64`,
  `ownerPubkeyHex`, `initialGrid`, `formula`, `supremeTags`, `artPackId` — is copied
  through byte-identically. The id is a purely local filename/handle
  ([spell_asset.dart:396](../lib/spells/spell_asset.dart#L396)), so rewriting it is safe,
  and a stable id is what makes `ChapterEntry(spellId:)` portable and reseeding
  idempotent.
- Also normalise `createdAt` to a fixed timestamp so the bundled files are
  reproducible (re-running the script produces no diff).
- Write to `assets/basic_spells/<slug>.json`.
- Generate `lib/spells/basic_spells.dart` (the registry, §4) from the same data, with
  a `// GENERATED by scripts/export_basic_spells.dart — do not edit by hand.` header.

Then add to `pubspec.yaml` alongside the existing art-pack entry:

```yaml
    # Shipped starter spells (docs/BASIC_SPELLS_PLAN.md). Generated by
    # scripts/export_basic_spells.dart from an authored library; the JSON
    # carries real proofs and is loaded verbatim by lib/spells/basic_spell_seed.dart.
    - assets/basic_spells/
```

---

## 4. Phase B — the registry (`lib/spells/basic_spells.dart`)

Generated, const, no I/O. Contents:

```dart
/// Bump when the shipped set changes; drives re-seeding (see basic_spell_seed.dart).
const int kBasicSpellSetVersion = 1;

class BasicSpellEntry {
  const BasicSpellEntry({required this.slug, required this.name,
      required this.commitmentHex, required this.spellHashHex, required this.t});
  final String slug, name, commitmentHex, spellHashHex;
  final int t;
  String get assetPath => 'assets/basic_spells/$slug.json';
}

const List<BasicSpellEntry> kBasicSpells = [ /* five entries */ ];
```

Plus the predicates. **All hex comparison goes through one normaliser** — strip a
`0x` prefix, lowercase, left-pad to 64 chars — because stored fields vary in
leading zeros (`Basic Earthworks`). Do not `==` raw strings, and do not reuse
`spell_authorization.dart`'s private `_hexEq` `BigInt.parse` trick; put a single
`String _normHex(String)` in this file and route everything through it.

```dart
/// Certified identity: the (grid, T) pair. Both values are proof public inputs
/// (proof_intake.dart §ABI fields [3] and [0]), so this is the ONLY form safe to
/// call at a trust boundary.
bool isBasicGridAndT(String commitmentHex, int t);

/// Convenience for local, already-trusted assets. Checks (commitment, T) AND
/// cross-checks spellHashHex; disagreement means a corrupt asset — return false.
bool isBasicSpell(SpellAsset spell);
```

**Why `(commitment, T)` and not `spellHashHex`:** `spellHashHex` is
`Poseidon2(commitment, T)` computed off-circuit via FFI
([inscribe.dart:156](../lib/spells/inscribe.dart#L156)). At the peer-cast boundary we
have the *verified* proof outputs in hand, which already contain `commitment`
(field 3) and `T` (field 0) — so `(commitment, T)` is exactly as tight, is already
certified, and needs no async FFI call inside the verification path.

---

## 5. Phase C — the authorization exemption

This is the trust-boundary change. Read §9 before writing it.

**`lib/spells/spell_authorization.dart`:**

- `localIdentityMayUse(spell, identity)`: return `true` early when
  `isBasicSpell(spell)`, before the pubkey comparison.
- `castingPlayerMayUse(...)`: add a required `int t` parameter and return `true`
  early when `isBasicGridAndT(commitmentHex, t)`.

**`lib/battle/engine/turn_loop.dart` ~L4096:** pass `t: outputs.t` and keep
`commitmentHex: outputs.commitmentHex`.

**The one rule that must not be broken:** the peer-side check reads `commitmentHex`
and `t` from `outputs` — the *verified proof public inputs* — and from nowhere else.
Never from the wire-decoded `SpellAsset`, never from `spell.name`, never from a
`spell.spellHashHex` the peer sent. A peer controls every field of the transmitted
`SpellAsset`; they control nothing inside a verified proof. Getting this wrong turns
the exemption into "any spell a peer *claims* is Basic", which is a total bypass of
`castingPlayerMayUse`. Pair the change with the negative test in §8 that asserts
exactly this.

---

## 6. Phase D — seeding (`lib/spells/basic_spell_seed.dart`)

```dart
/// Copies any missing bundled basic into the player's library. Returns the count
/// written. Idempotent. Skips entirely when the marker records a version >=
/// kBasicSpellSetVersion, unless [force] is set.
Future<int> seedBasicSpells({bool force = false});
```

- Marker file `<app documents>/spells/_basics_seeded.txt` holding the integer
  `kBasicSpellSetVersion`. Absent or lower → run; equal or higher → no-op (unless
  `force`). Sits next to `_active.txt` in `chapters/`
  ([chapter_asset.dart:234](../lib/spells/chapter_asset.dart#L234)) as prior art for
  a sidecar control file.
- For each entry: `rootBundle.loadString(entry.assetPath)` →
  `SpellAsset.fromJson(jsonDecode(...))` → `save()`, **but only if no persisted
  spell already has that `spellHashHex`.** One `SpellAsset.loadAll()` up front, not
  one per entry.
- Never overwrite an existing file. A player who renamed or re-arted their copy keeps
  it.
- Write the marker last, after all writes succeed. Bumping `kBasicSpellSetVersion`
  later is how a sixth basic reaches existing installs, and the per-spellHash check
  means the five already present are not touched.
- Deletes stick: the marker is at version, so a normal launch never restores.
  `force: true` is the Restore action (§7).

**Hook it into [`lib/ui/app_root.dart`](../lib/ui/app_root.dart).** Today it awaits
`Identity.exists()`. Change to a small `Future<bool>` that awaits `seedBasicSpells()`
first, then returns `Identity.exists()`. Seed on **both** branches — existing installs
(which already have an identity and skip onboarding) are the main audience for the
first release of this feature. 121 KB of JSON decode is not a perceptible delay, but
keep it off the onboarding critical path by letting the existing spinner cover it.

---

## 7. Phase E — chapters may hold unlimited copies

This is the real engineering, and it is **not** just deleting the UI guard. Read this
section fully before touching anything.

### The actual problem

[`BookCommitment.proveMembership`](../lib/battle/engine/book_commitment.dart#L149)
resolves a cast's chapter position with `sorted.indexOf(leafHex)`. With N copies of
one commitment in a chapter, all N sort adjacent and `indexOf` returns the **first**
one every time. The returned `leafIndex` is what
[`DrawSchedule`](../lib/battle/engine/draw_schedule.dart) uses as a card's identity —
so casting the second copy would advance the first copy's slot, and
`isCastable`/wither state would desync between the two clients. Left unfixed, a
duplicate chapter is a hand-state desync, i.e. a forfeit
([turn_loop.dart:4077](../lib/battle/engine/turn_loop.dart#L4077)), not a cosmetic bug.

The fix is available because `DrawSchedule.hand` (positions) and `SpellDraw.hand`
(contents) are **index-parallel by construction** — see
[turn_loop.dart:725-748](../lib/battle/engine/turn_loop.dart#L725-L748) and
`draw_schedule.dart`'s header. So a hand *slot index* unambiguously names a chapter
position even when two slots hold the same spell. We stop searching by commitment and
start carrying the slot.

### E1. `BookCommitment` — prove by index

Add:

```dart
static MembershipProof? proveMembershipAt(List<String> commitmentHexes, int leafIndex)
```

Same path construction as today, but taking the sorted index directly instead of
deriving it. Refactor the existing `proveMembership(list, leafHex)` to be
`proveMembershipAt(list, sorted.indexOf(leafHex))` so behaviour is bit-identical for
unique lists and every current caller keeps working. Leave `computeRoot` and
`hashLeaves` alone — duplicate leaves are fine in the tree (it is a commitment plus a
position authenticator, not a set), and both already sort.

### E2. Carry the hand slot through the local cast path

- `SpellCastAction` and `MysterySpellCastAction`
  ([turn_loop.dart:203](../lib/battle/engine/turn_loop.dart#L203), `:332`): add
  `final int? handIndex`. Nullable, defaulting to null, so solo/test/delayed-fire
  construction sites compile untouched and fall back to today's behaviour.
- **This does not change the wire format.** The position already reaches the peer
  inside the Merkle `directions` — `handIndex` only needs to exist locally, at encode
  time, so we build the path for the *right* leaf. Do not add it to
  `_encodeAction`/`_decodeAction`.
- [`battle_screen.dart`](../lib/ui/battle_screen.dart): `_selectedSpell` and
  `selectedId: _selectedSpell?.id` (L308, L785, L1857) key selection on
  `SpellAsset.id`, which is identical across copies. Track `int? _selectedHandIndex`
  as the source of truth; derive the displayed spell as `hand[_selectedHandIndex!]`.
  The hand strip's `onSelect` passes its index. Pass `handIndex:` on both
  `SpellCastAction` (L960, L885) and `MysterySpellCastAction` (L1037, L1064)
  constructions.
- `TurnLoop`: one private helper,

  ```dart
  /// The chapter position of a local cast: the caster's own hand slot when known
  /// (the only duplicate-safe key), else a commitment lookup (legacy/solo path).
  int? _localCastPosition(SpellAsset spell, int? handIndex) { ... }
  ```

  returning `_drawSchedules[localPlayerId]!.hand[handIndex]` when the schedule is
  dealt and the index is in range, else `proveMembership(...)?.leafIndex`.

- Route all four local-side uses through it:
  - `_appendSpellProofTail` ([:3634](../lib/battle/engine/turn_loop.dart#L3634)) —
    take a `int? position` argument, use `proveMembershipAt` when non-null. Its
    caller at `:3626` has the action, so it has the `handIndex`.
  - `_advanceDrawState(localPlayerId, …)`
    ([:1233-1239](../lib/battle/engine/turn_loop.dart#L1233-L1239)).
  - The hand-reveal loop ([:3404](../lib/battle/engine/turn_loop.dart#L3404)) —
    iterate by index and use `proveMembershipAt(commitments, schedule.hand[i])`
    rather than `proveMembership(commitments, spell.commitmentHex)`.
  - `isHandSpellWithered` ([:765](../lib/battle/engine/turn_loop.dart#L765)) — add
    `bool isHandSlotWithered(int handIndex)`; keep the existing method delegating for
    callers that have no slot.

- The **peer** side needs no change: `merkleProof.leafIndex` already comes from the
  verified directions, so once the caster builds the proof for the correct occurrence,
  the peer reads the correct position.

### E3. Chapter and library

- [`Chapter.fromChapterAsset`](../lib/battle/models/chapter.dart#L49) already preserves
  duplicate `ChapterEntry`s (it maps entries → assets, it does not dedup). Add a
  comment noting duplicates are now expected and that `sort`'s instability across
  equal keys is immaterial because equal keys mean the identical asset.
- Drop the dedup rejection for basics at
  [library_screen.dart:455](../lib/ui/library_screen.dart#L455) and
  [:637](../lib/ui/library_screen.dart#L637): skip the
  "Chapter already contains a spell with these runes" branch when `isBasicSpell`.
  Non-basic spells keep the existing one-copy rule unchanged.

---

## 8. Phase F — UI surfacing

Modest, in the existing manuscript idiom — do not redesign the card.

- A small **`Basic`** mark on the library card for basic spells.
- **Suppress the creator sigil on basics.** `_creatorKeyBytes`
  ([library_screen.dart:397](../lib/ui/library_screen.dart#L397)) is the *local
  player's* pubkey, rendered on every card — which for a shipped spell would claim the
  player inscribed it. Show the Basic mark in that slot instead.
- **"Restore basic spells"** action in the Library overflow menu, calling
  `seedBasicSpells(force: true)` and reporting the count restored. This is what makes
  "deletable, stays deleted" safe.
- Chapter picker / chapter contents: show copies as `Basic Firebolt ×3` rather than
  three identical rows, or number them — your call, but a chapter with six copies must
  not read as a bug.

Not in scope, flag if you think it matters: filtering basics out of the Trade offer
list. Loaning a spell everyone already owns is noise, but it is harmless and it is
extra surface.

---

## 9. Tests — the gate

CLAUDE.md's bar: a constraint you cannot write a negative test for is one you do not
understand yet. Each item below pairs a capability with its attack.

**`test/spells/basic_spells_test.dart`**
- Every bundled asset parses as a `SpellAsset`, and its `(commitmentHex, t)` and
  `spellHashHex` match the generated registry entry. This is the transcription check —
  it fails loudly if the assets and the registry drift.
- `isBasicSpell` true for all five; false for an ordinary spell.
- Hex normalisation: a `0x00ce…`/`ce…`/`0X00CE…` triple all compare equal
  (Earthworks' leading-zero case).

**`test/spells/basic_spell_seed_test.dart`**
- Seeds five into an empty temp docs dir; a second call writes zero.
- A spell already present by `spellHashHex` is not overwritten (rename it, reseed,
  assert the rename survives).
- Delete one, run a normal seed → **not** restored. Run `force: true` → restored.
- Bumping `kBasicSpellSetVersion` re-runs without duplicating the existing five.

**`test/spells/spell_authorization_test.dart`** (extend)
- `localIdentityMayUse` true for a basic against a *stranger* identity.
- `castingPlayerMayUse` authorizes a peer casting a basic at its registered T.
- **Negative:** a basic's `commitmentHex` at a *different* T is rejected.
- **Negative:** a non-basic spell with a foreign owner and no permission is still
  rejected — the exemption must not have widened into a blanket allow.
- **Negative (the important one):** a forged `SpellAsset` claiming a basic's name and
  `spellHashHex`, but whose *proof outputs* carry a non-basic commitment, is rejected.
  This is the §5 trust-boundary attack.

**`test/battle/engine/book_commitment_test.dart`** (extend)
- With duplicate leaves, `proveMembershipAt` yields a distinct `leafIndex` per
  occurrence and each proof `verify()`s against the root.
- `proveMembership` output is unchanged for a duplicate-free list (regression guard on
  the refactor).

**`test/battle/engine/turn_loop_*`**
- Three-copy chapter: cast the copy in hand slot 1; assert the peer's `DrawSchedule`
  advances that position and both players' schedules remain identical afterwards.
- Wither one copy; assert the other copies stay castable.

**Widget test**
- Adding one basic to a chapter three times succeeds; adding a non-basic twice still
  shows the existing refusal snackbar.

Full `flutter test` green before commit (baseline was 684 passing).

---

## 10. Real-device gate — not optional

Per CLAUDE.md's verification hierarchy (hardware run > golden corpus > integration
test), and because §5 is a trust-boundary change:

1. `flutter run -d linux` — first launch on a **wiped** docs dir seeds five spells;
   they render with pack art; adding one to a chapter three times works; delete one and
   confirm it stays gone across a relaunch; Restore brings it back.
2. **Two-device LAN duel.** This is the only way to exercise `castingPlayerMayUse`
   against a foreign-owner proof. Duel from a device whose identity is *not* Soren's
   dev key, cast Basic Firebolt, and confirm no forfeit. Then cast a chapter's second
   copy of a basic and confirm hand state stays in sync on both screens.

Do not report this done on unit tests alone.

---

## 11. Docs to update

- `docs/BATTLE_AUTH_PLAN.md` §4 — record the Basic exemption and the §5 reasoning
  (why a five-grid public allowlist does not weaken the model: the proof still must
  verify, `ruleset_version` and mana/geometry are still certified; only "owner ==
  caster" is waived, for grids that are intentionally public).
- `docs/M4_findings.md` (or a new `M5_findings.md` if the milestone has rolled) —
  the `indexOf`-collapses-duplicates trap in §7, since it is exactly the kind of
  boundary bug the handoff notes warn about, and anything not written down is assumed
  unsolved.
- New `docs/BASIC_SPELLS.md` — the registry, and the recipe for adding a sixth basic:
  inscribe it, run the export script, bump `kBasicSpellSetVersion`, regenerate,
  re-run the §9 suite.

---

## 12. Suggested commit sequence

Small and legible, per CLAUDE.md:

1. `scripts/export_basic_spells.dart` + `assets/basic_spells/` + generated
   `lib/spells/basic_spells.dart` + pubspec entry + registry tests.
2. `basic_spell_seed.dart` + `app_root.dart` hook + seed tests.
3. Authorization exemption + its positive and negative tests. *(Security-relevant —
   keep it isolated so it is reviewable on its own.)*
4. `BookCommitment.proveMembershipAt` + its tests. *(Pure refactor, no behaviour
   change yet.)*
5. `handIndex` plumbing through `TurnLoop`/`battle_screen` + duplicate-position tests.
6. Library dedup exemption + UI marks + Restore action + widget tests.
7. Docs.

Steps 4 and 5 are the ones to slow down on. Everything before them is additive;
those two touch the hand/deck consensus path that both clients must compute
identically.

---

## 13. One observation, deliberately out of scope

While tracing this: a peer's `formula` — which drives their spell's actual effects —
is taken from the transmitted `SpellAsset`, not derived from the proof's
`dominanceTrajectory`. Only the *supreme tags* are certified
([turn_loop.dart:4026](../lib/battle/engine/turn_loop.dart#L4026)), and only mana cost
is certified from `segment_count`/`dot_count`. So a peer can already declare a
formula their proof does not support. This is pre-existing, unrelated to basic
spells, and **not part of this task** — noted here so it is written down somewhere
rather than rediscovered. Raise it with Soren separately.
