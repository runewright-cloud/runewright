# AETHERIAL_ARMOR.md — inscribed armor: derivation, persistence, local UX

*Written 2026-08-25 on `main`. Implementation record for Aetherial Armor slices
1 through 4.6, built in sequence in one session. This is what shipped, not a plan —
where a slice's brief and the code diverged, the code is described and the
divergence called out.*

**Status: slices 1–6 complete and green; slice 5 gated on hardware (§10), slice 6
not yet (§11).** The networking/trust work closed at slice 4.6;
armor crosses the wire and is certified at duel setup (§3b). **Slice 5 (§9) makes the
certified armor canonical battle state and turns its four numerical bonuses into
deterministic gameplay**; **slice 6 (§11) activates exactly two keywords — Charger and
Muddy — through the haymaker hooks that already existed**, at `kBattleEngineVersion`
**7**. The other five keywords are canonical, hashed and still completely inert.

---

## 0. What an Aetherial Armor is

An armor is an inscribed spell that is *worn* rather than cast. Its CA trajectory
is what the armor **is**: the same grid → proof → persist pipeline as any other
spell, read through a different lens at the far end. It occupies a variable number
of a chapter's 12 artifact slots, grants stat bonuses from its element counts, and
grants keywords from four-element patterns in its trajectory.

The load-bearing rule, inherited from M4.22: **an armor's properties are what its
proof attests, never what the asset says about itself.** `SpellAsset.formula`,
`manaCost`, `supremeTags` and `isArmor` are authored fields nothing binds; a stale
or edited one must not move a single number the player sees, and must never be
what a peer trusts.

---

## 1. Slice 1 — the derivation (`CertifiedArmor`)

`lib/battle/models/certified_armor.dart` is a pure, deterministic
`VerifiedSpellOutputs -> CertifiedArmor`. No I/O, no Flutter, no networking, no
BattleState.

### Public API

```dart
enum ArmorKeyword { flying, cleave, charger, muddy, moltenCarapace, stealthy, anchored }
const Map<ArmorKeyword, List<BorderZone>> armorKeywordPatterns
const List<({int count, int bonus})> armorElementLadder   // 4/10/18/28/40 → 1..5
const List<({int count, int bonus})> armorEarthLadder     // 2/6/12/20/30/42 → 2/5/8/11/14/17
int armorLadderBonus(int count, List<({int count, int bonus})> ladder)
int armorSlotCostForT(int t)                              // (t + 3) ~/ 4

class CertifiedArmor {
  factory CertifiedArmor.fromOutputs(VerifiedSpellOutputs);        // authoritative
  factory CertifiedArmor.previewFromElementSequence(List<BorderZone>, {required int t});
  final int t, slotCost;
  final int fireCount, airCount, waterCount, earthCount;
  final int meleeBonus, moveSpeedBonus, spellRangeBonus;  // fire / air / water
  final int armorHpBonus;                                 // earth, held separately
  final Set<ArmorKeyword> keywords;                       // unmodifiable
  final List<BorderZone> elementSequence;                 // unmodifiable
  bool hasKeyword(ArmorKeyword);
}
```

`fromOutputs` takes `VerifiedSpellOutputs` and nothing else, so authored fields
cannot participate *by construction*. It is the one derivation both the local
(`parseOwn`) and future peer (`verifyAndParse`) paths call — one proof, one
meaning.

### Numbers

| | breakpoints | effect |
|---|---|---|
| Fire | 4 / 10 / 18 / 28 / 40 → +1..+5 | melee |
| Air | same ladder | move speed |
| Water | same ladder | spell range |
| Earth | 2 / 6 / 12 / 20 / 30 / 42 → +2/+5/+8/+11/+14/+17 | **armor** HP |
| Slots | `ceil(T/4)` | 1 (T 1–4) … 12 (T 45–48), no diminishing returns |

Earth's result is stored as `armorHpBonus`, separate from any innate HP, so a
later armor-breaking mechanic can strip exactly the HP the armor granted.

Keywords are contiguous four-element substrings of the certified sequence.
Elements may be reused, matches may overlap, and each keyword is granted at most
once however often its pattern occurs:

`AAAA` Flying · `FFFF` Cleave · `FAFA` Charger · `WEWE` Muddy ·
`EFEF` Molten Carapace · `AWAW` Stealthy · `EEEE` Anchored

**Morphic (`WWWW`) is deliberately not implemented** — it is designed but not
built, so a WWWW armor grants no keyword rather than a placeholder one.

**Under a Mutable Leyline those seven patterns are rekeyed** (engine 15; audit
R-8). The table above is the ORDINARY tradition and stays the reference reading
everywhere no leyline is in force. A mutable leyline derives its own bijection
over the same 256 four-element patterns from its tradition hash, so `AAAA` may
name nothing and some other run may name Flying. What does NOT change: the
recogniser (four elements, sliding, overlapping, at-most-once), the count (seven
of 256 — the density is not rerolled), and **every intrinsic number** — T, slot
cost, the element counts and all four ladders are identical under every leyline.
`CertifiedArmor.fromOutputs` takes an `ArmorLexicon`; both duellists pass the
config they agreed at the handshake, and nothing about a derived keyword crosses
the wire. See `lib/battle/models/armor_lexicon.dart`.

### The trajectory reading, and the trap in it

Armor reads `TrajectoryParser.certifiedPerGenerationDominantSequence` — one
element per non-neutral generation, **repeats kept**, generations `0..T-1` only.

It must **not** use `TrajectoryParser.certifiedElementSequence`, which is the
compressed spell-*formula* view: that one drives `FormulaTracker`, which commits an
element only on a lead change, a supreme generation, or a cadence-4 pulse. Under
it `FFFF` yields **two** fires, not four — halving every count and making the
keyword patterns unable to match themselves.

Both readings live in `trajectory_parser.dart` and share the same
`ruleFromIndex`/`activeZoneFor` pair, so there is still exactly one interpretation
of a dominance index in the codebase; only the accumulation rule on top differs.
Both methods carry doc comments saying which is which. **This is the single
easiest mistake to make in this feature** — a future caller reaching for the
older, more familiar name silently halves every stat.

`previewFromElementSequence` (added in slice 3) applies the same rules to a sequence
supplied directly, for the one case where no proof exists yet: the Rune Craft
editor's live preview. Never reach for it to read a spell that *has* a proof.

---

## 2. Slice 2 — persistence and slot accounting

### Persisted schema

Two optional keys, both omitted when absent, so a non-armor spell and a no-armor
chapter serialise byte-identically to how they did before armor existed:

```jsonc
// spells/<id>.json
"isArmor": true          // written only when true
// chapters/<id>.json
"armorSpellId": "1724…"  // written only when bound
```

Backward compatibility: `isArmor` reads `(json['isArmor'] as bool?) ?? false`;
`armorSpellId` reads `as String?`. Old files load as ordinary spells and no-armor
chapters. Tests assert the keys are *absent* for the default cases, not merely
that the defaults are right.

### Mode exclusivity

A spell cannot be both a Summon and an Armor. The `SpellAsset` constructor throws
`ArgumentError`; `fromJson` **sanitises instead of throwing** (summon wins, armor
marker dropped) so a hand-edited file cannot brick a library load. `inscribeSpell`
guards the same combination up front, before ~7s of proving.

### Why armor is a chapter binding, not an `ArtifactEntry`

It costs a variable number of slots, it is permanent equipment rather than
something activated or consumed, it carries a proof-backed inscription, and at
most one may be worn — which a single nullable field enforces structurally, with
no validation to forget.

Stored as an **ID, not an embedded asset**: a second copy would go stale the
moment the spell was renamed and would double every proof's bytes in the chapter
file. The trade-off is that `ChapterAsset` cannot resolve its own armor.

### The accounting seam

`ChapterAsset` is deliberately repository-free, so the cost is a **required**
parameter:

```dart
int artifactSlotsUsed({required int armorSlotCost});
int artifactSlotsRemaining({required int armorSlotCost});
```

Required, not defaulted to 0 — a caller cannot silently under-count a chapter's
armor and let it slip past the budget; forgetting becomes a compile error rather
than a gameplay exploit.

`lib/spells/chapter_armor.dart` is the narrow seam that has both chapter and
spell:

```dart
int localArmorSlotCost(SpellAsset armor);          // ceil(T/4) from stored T
int chapterSlotsUsed / chapterSlotsRemaining(ChapterAsset, SpellAsset? armor);
enum ArmorBindError { notAnArmor, exceedsSlotBudget }
ArmorBindError? armorBindError(ChapterAsset, SpellAsset);
ChapterAsset? bindArmor(ChapterAsset, SpellAsset);
ChapterAsset unbindArmor(ChapterAsset);
ChapterAsset? addArtifactWithinBudget(ChapterAsset, ArtifactEntry, {required SpellAsset? armor});
```

**Trust note:** everything here reads `SpellAsset.t`, a local persisted field no
proof binds. That is enough to decide what the player may equip *on their own
device*, and is not network semantics. Duel setup must recompute from
`CertifiedArmor.fromOutputs`. No slot cost is persisted anywhere. Both readings
share `armorSlotCostForT`, so only the source of T can differ, never the formula.

### Every place enforcing the 12-slot budget

1. `ChapterAsset.artifactSlotsUsed/Remaining` — the arithmetic.
2. `armorBindError` / `bindArmor` — rejects an armor that won't fit.
3. `addArtifactWithinBudget` — the checked front door for ordinary artifacts;
   this is what stops armor being bypassed by equipping first and adding after.
4. `_ChapterDetailScreenState._slotsRemaining` — gates the Add button, and
   **fails closed** while a bound armor is still resolving (cost unknown ⇒ 0
   remaining). A transient bypass is worse than a transient inconvenience.
5. `ChapterAsset.removeSpellFromAllChapters` — clears the binding when the armor
   spell is deleted.

`ChapterAsset.withArtifact` / `withArmor` stay unchecked deliberately (they are
also the load and migration paths); their docs point at the checked wrappers.

### Sharing: one armor, many chapters

**Intended and confirmed.** The rule is "at most one armor *per chapter*", not
"an armor belongs to at most one chapter". `armorBindError` checks only
`isArmor` and *this* chapter's budget — there is no cross-chapter query anywhere.
This mirrors spells, which already appear in several chapters at once.

Consequences: slot cost is charged per chapter independently; deleting the armor
clears it from every chapter; the picker does not hide an armor worn elsewhere.
Chapters are alternative loadouts and only one is active per duel, so a shared
armor is never worn twice at once.

### Field-enumerating paths that had to be updated

Adding a field to these classes means touching every hand-written copy site.
Carried through: all ten `SpellAsset.withX` methods; all eight `ChapterAsset` copy
helpers (`rename`, `copyAsNew`, `withEntry`, `withoutEntryAt`, `withArtifact`,
`withArtifactAt`, `withoutArtifactAt`, `attuneFirstUnattunedCounterCharm`);
`library_backup.dart`'s chapter import (armor ID remapped like entries, dropped if
unresolved); `apprentice_session.dart`'s graduation rebuild (same commitment-keyed
upgrade as entries). Tests assert survival across each path.

---

## 3. Slice 3 — local UX

### Three inscription modes

`InscriptionMode { incantation, summon, armor }` (`lib/spells/inscription_mode.dart`)
is the Rune Craft screen's state and the **only** place mapping mode onto the two
persisted booleans, so "both flags set" is not constructible from the UI.
`InscriptionMode.of(spell)` recovers the mode when an existing spell is reloaded
into the editor.

Armor uses the existing CA editor, T selection, proving, commitment and
persistence unchanged — there is no second proof pipeline. Suppressed in Armor
mode: the mana-cost readout (armor is never cast, so the number means nothing),
the FormulaBar, and the summon preview. The name prompt says "Name Your Armor".

`_ArmorPreview` replaces the FormulaBar in Armor mode — slot cost, element tally,
earned bonuses, keywords, live as you step. It reads
`CertifiedArmor.previewFromElementSequence` over the dominance the stepper is producing
*right now*, because no proof exists yet; this mirrors how `_SummonPreview`
previews `CreatureSpec.fromElements`. Every rule shown is the same code the
certified reading uses.

### The display path — this is the important one

```
SpellAsset.proofBytes
  → ProofIntake.parseOwn(bytes, tierForProof(spell.t, spell.tier))
  → VerifiedSpellOutputs
  → CertifiedArmor.fromOutputs
```

One helper — `localCertifiedArmor(SpellAsset)` in `lib/spells/armor_summary.dart`
— and every display surface calls it. No second ABI parser.

`tierForProof` (reused from `spell_asset_integrity.dart`) re-derives the parsing
tier from T exactly as `inscribeSpell` chose it at proving time, rather than
trusting `SpellAsset.tier`: the public-input count is `10 + 2*tier_max`, so a
wrong tier reads the trajectory arrays at the wrong offsets and yields **confident
garbage**.

Unreadable or absent proof bytes return null and the UI says so. There is
deliberately **no fallback to authored metadata** — a fallback would advertise an
armor the duel would not honour.

### Library representation

An armor shows a shield badge, reads `Aetherial Armor · Gen T` instead of a mana
price, and carries its proof-derived summary on the card. Castable-only
affordances are withheld: no "Add to Chapter" (a `ChapterEntry` is a castable
draw, and an armor in the hand is a spell the engine cannot resolve) and no
"Practice Incantation". `_blockedAsArmor` is the backstop on all three add routes
— Craftings, Loans, Tests batch — because a *loaned* armor would otherwise reach
a spell list without touching the Craftings card.

### Chapter equip UI

An ARMOR section sits above ARTIFACTS: equipped armor with its summary, or "No
armor equipped" plus Equip. `ArmorPickerDialog` lists only `isArmor` assets
(filtered at the call site *and* inside the dialog) and disables unaffordable ones
with the reason `armorBindError` gave. Equip / Replace / Remove all go through the
slice-2 seam; no budget arithmetic lives in widget code. Replace rebinds in one
step, releasing the outgoing armor's slots. The existing "Artifact Slots
Remaining: N / 12" readout now includes armor automatically.

---

## 3b. Slice 4 — the setup trust boundary

Armor now crosses the wire, is cryptographically verified, and is certified
before any `BattleState` exists. It is still applied to nothing.

### The asymmetry that is the point

```
local : SpellAsset.proofBytes -> ProofIntake.parseOwn       -> outputs
peer  : ArmorEnvelope         -> ProofIntake.verifyAndParse -> outputs
both  : outputs -> validate -> CertifiedArmor.fromOutputs
```

The paths differ ONLY in whether the bytes are verified first — ours are ours,
and re-verifying a proof this device authored costs seconds and buys nothing.
Everything after is one function, so one proof cannot mean two things.
`duel_setup_armor_test.dart` asserts `host.localArmor == guest.peerArmor` for
the same armor, from opposite sides of the trust boundary.

### Public API introduced

```dart
// lib/battle/models/armor_envelope.dart
class ArmorEnvelope {
  const ArmorEnvelope({required int tier, required Uint8List proofBytes});
  static Uint8List encode(ArmorEnvelope? armor);      // {"armor": null} for none
  static ArmorEnvelope? decode(Uint8List payload);    // throws FormatException
}

// lib/battle/engine/armor_certification.dart
class ArmorCertificationException implements Exception { final String reason; }
int armorProofTier(SpellAsset armor);                 // tierForProof(t, tier)
CertifiedArmor? certifyOwnArmor({SpellAsset? armor, String wearerOwnerPubkeyHex,
                                 int ordinaryArtifactCount});
Future<CertifiedArmor?> certifyPeerArmor({ArmorEnvelope? envelope,
    String wearerOwnerPubkeyHex, int ordinaryArtifactCount,
    ProofVerifier? verifyProof, Uint8List? Function(int)? vkBytesForTier});

// lib/battle/networking/battle_session.dart
Future<ArmorEnvelope?> exchangeArmorLoadout(ArmorEnvelope? ours);

// lib/battle/networking/duel_setup.dart  — new optional injected params
runDuelSetup({..., ProofVerifier? verifyProof,
                   Uint8List? Function(int tier)? vkBytesForTier});
class DuelSetupResult { ... final CertifiedArmor? localArmor, peerArmor; }

// lib/ui/battle_lobby_screen.dart
class DuelVerifierResources { ProofVerifier verifyProof; Map<int, Uint8List> vkByTier; }
Future<DuelVerifierResources> prepareDuelVerifierResources();
```

### Ordering inside step 7b

1. Resolve `ChapterAsset.armorSpellId` to its `SpellAsset` — exactly that
   binding, nothing else. A binding that no longer resolves is a hard error,
   not a silent "no armor": the player believes they are wearing something.
2. Certify our own armor FIRST, so a broken local loadout fails before we ask
   the peer to trust anything.
3. Exchange the envelope (built with `armorProofTier`, so the tier we declare
   and the tier we parse our own proof at are one number).
4. Certify the peer's.

Step 7b sits **after** identity auth — both certifications bind a proof to an
authenticated `owner_pubkey`, and before auth there is no authenticated peer key
to bind to; an armor checked against a self-declared identity is not checked at
all — and **before** `buildDuelBattleState`, so a match with armor neither side
can agree on never reaches a state at all.

### The wire frame: `armorLoadout` (0x1F)

```jsonc
{"armor": null}                                   // wearing none
{"armor": {"tier": 12, "proofB64": "<base64>"}}   // wearing one
```

Exchanged on **every** duel. A conditional frame would leave two peers in
different handshake states, each blocking on a frame the other decided not to
send — a hang at the venue, not an error message.

`tier` is **routing metadata, not semantics**: the verifier must select a VK and
a public-input layout before the proof's own T is readable (the field count is
`10 + 2*tier_max`). A lie buys nothing — only canonical tiers are accepted, and
after parsing the certified T must imply the same tier, or the match aborts.
Deliberately absent, and never to be added: `isArmor`, authored formula, mana
cost, supreme tags, element counts, stat bonuses, keywords, slot cost. A test
asserts none of those strings appears in the encoded payload.

### Every check, and what it stops

| Check | Stops |
|---|---|
| ruleset epoch == `kRulesetVersion` | an armor proven under CA rules this build cannot reproduce |
| certified `owner_pubkey` == authenticated wearer | wearing a proof lifted off the wire; there are **no armor loans** this slice |
| declared tier ∈ {12,24,48} | a parse at meaningless offsets |
| `tierForProof(certified T) == declared tier` | using the tier declaration to reinterpret the same bytes |
| `ordinaryArtifacts + slotCost <= 12`, from **certified** T | a locally edited stored T understating cost; a malicious peer's over-budget loadout |

Owner comparison is numeric (`BigInt`), not string equality. Failure throws;
setup fails closed and forfeits. No `BattleState` is ever built around armor
neither side could certify.

### Where the verifier resources come from

`duel_setup.dart` still loads no Flutter assets — it takes `verifyProof` and
`vkBytesForTier` **injected**. `prepareDuelVerifierResources()` in
`battle_lobby_screen.dart` loads all three tiers' VKs and calls
`initSrsCached` before the handshake starts. Finding the SRS cache on disk is
not the same as initialising the process's global CRS, and a pure-verify path
initialises it nowhere else (CLAUDE.md bug-avoidance #4).

BattleScreen still runs its own copy afterwards. That duplicate is a few KB and
an already-warm SRS init, and keeping it was chosen over threading a shared
proof-resource lifetime through lobby → setup → screen on the eve of a
playtest.

The injected parameters are optional so a caller with no armor needs no proving
stack. That is not a loophole: if the peer declares armor and they are absent,
certification refuses it. A missing verifier can only ever cost you a match.

### Protocol version

`kBattleProtocolVersion` 5 → 6 (and → 7 in §3d). `kBattleEngineVersion` and
`kRulesetVersion` are **unchanged** — canonical state has not moved yet. The
engine bump belongs to the state/gameplay slice.

### Setup abort left the peer blocked — found here, fixed in slice 4.5

When one side refused mid-handshake it forfeited and threw, but the other side
was already blocked in `_awaitFrame`, which did **not** wake on a forfeit frame;
it waited until the transport died and then reported a connection loss — the one
explanation certainly wrong when the peer has just told you the real one. Never
specific to armor (it is why `battle_engine_version_test.dart` drives refusals
against a hand-rolled fake peer rather than a second real `runDuelSetup`), but
armor added five fresh ways to reach it. **Fixed generically at the session
layer — see §3c.**

---

## 3c. Slice 4.5 — setup abort propagation

A reliability repair, not a feature: making an already-existing forfeit actually
interrupt blocked exchanges. No protocol/engine/ruleset version moved, no armor
semantics changed.

### `_awaitFrame`, before and after

| | before | after |
|---|---|---|
| ends on | the requested frame, only | the frame, a peer forfeit, **or** a connection drop |
| peer forfeits | blocks until TCP teardown, then reports a connection loss | throws `PeerForfeitException(reason)` immediately, reason verbatim |
| connection drops | blocks until teardown surfaces elsewhere | throws `PeerConnectionLostException(reason)` |
| started after the event | blocks forever on a peer that is already gone | fails immediately from the latched `_abortError` |

Two typed exceptions, deliberately distinct: *"they decided to stop, and here is
why"* and *"they vanished"* are different events, and only the first has a
diagnosis in it. Conflating them is how a rejected armor comes to read as bad
Wi-Fi.

### One consumer, many observers

`framesOfType` is queue-backed and **consumptive** — two listeners on a type
race, and the loser waits forever. `peerForfeit` was already the single logical
consumer of the forfeit frame; slice 4.5 pumps it from the constructor
(`_pumpPeerForfeit`, mirroring `_pumpComponentsDone`) so the claim is staked
before any exchange starts, and fans the result out through `_abortWaiters`
rather than opening a second listener.

That made the invariant load-bearing rather than incidental, and three existing
auth tests were reaching under it with their own `framesOfType(forfeit)`
listener; they now read `session.peerForfeit`, which is the API they wanted. The
invariant is documented on `framesOfType` itself.

`_abortWaiters` holds only genuinely blocked waits (registered on entry, removed
in `finally`), so it does not grow with the match — the reason for a waiter set
rather than a `.then` per wait on a shared future.

### What did NOT change

`peerForfeit` and `peerConnectionLost` behave exactly as before;
battle_screen.dart's `.then` callbacks are untouched. One consequential edit
there: `_submitTurn`'s catch now declines to set `_turnError` for these two
exception types. `_turnError` outranks both dedicated banners in `build()`, so
without it a mid-turn forfeit — which can now surface as a thrown exchange for
the first time — would have replaced *"they ended the duel, and here is what
they said"* with *"this duel broke lockstep"*.

### The one shape that was bounded but not symmetric — closed in §3d

When the peer's armor was rejected by the **verifier**, the rejecting side
aborted *after* the exchange, so the other side was no longer blocked on it: it
finished setup normally and only learned the truth from `peerForfeit` once the
battle screen was already up. Bounded and correct, but it meant a device could
enter a battle screen for a match that no longer existed. Slice 4.6's
setup-ready barrier closes it.

### Armor forfeit reasons

Unchanged: `armor_certification_failed` for every certification failure,
`armor_loadout_malformed` for a bad payload. Both gained a sentence in
`_forfeitExplanation`, following the existing convention for canonical reasons —
no error-code taxonomy was introduced.

---

## 3d. Slice 4.6 — the setup-finalization barrier

### The shape

```
exchange armor
certify local + peer armor
validate every setup invariant
        ↓
send setupReady          ← "I found no reason to refuse this match"
await peer setupReady
        ↓
ONLY NOW buildDuelBattleState and return
```

`setupReady` is **0x47**, empty payload — the 0x10–0x1F setup block is full, so
it sits in the 0x4x block for the same reason `artifactCommit` does. Sent
unconditionally: a conditional barrier is not a barrier.

### What it makes impossible

Setup validation is asymmetric *in time*. The side whose own armor is fine has
nothing left to check while the other side is still verifying, so before the
barrier a rejected match could leave one device in a battle screen and the other
in the lobby. Now readiness is mutual, and because every refusal path forfeits
and a forfeit interrupts a blocked typed wait (§3c), a refusal on either side
aborts BOTH on the same cause.

The core test is the case that motivated it: A accepts B's armor, B rejects A's.
B fails its own certification and forfeits; A, blocked at the barrier, wakes with
`PeerForfeitException('armor_certification_failed')`. Neither returns a result;
neither can enter a battle screen. Mirror image pinned too.

### Two gaps found while wiring it

Both were paths that threw WITHOUT forfeiting — harmless before, because the
peer was not blocked on anything; hangs afterwards, because now it is.

1. **A dangling armor binding** (`_resolveEquippedArmor` throwing `StateError`)
   forfeits before rethrowing.
2. **Everything else.** `runDuelSetup` now wraps its steps in a backstop that
   sends `setup_failed` for any refusal path that did not forfeit on its own —
   corrupt library JSON, an unreadable identity, anything unforeseen. A second
   forfeit on a path that already sent one is harmless: the peer consumes the
   first and the rest sit unread. `PeerForfeitException` /
   `PeerConnectionLostException` are excluded, since forfeiting back at a device
   that has already gone is noise.

The body moved into `_runSetupSteps` so the wrapper could hold the session
without re-indenting the whole handshake.

### Protocol version 6 → 7

A mandatory frame was added, so the version moved again — even though neither v6
nor v7 has shipped and both land in the same uncommitted series. The scenario is
real and immediate: two dev devices flashed a day apart during a playtest week
would otherwise both call themselves v6 and hang at the barrier. The gate runs
before any setup frame is exchanged, so a mismatched pair is refused rather than
hung. Bumps are free while nothing has shipped, which is exactly when the habit
is worth keeping.

`kBattleEngineVersion` and `kRulesetVersion` are still unchanged.

---

## 4. Files

**New (lib)**
```
lib/battle/models/certified_armor.dart     derivation, ladders, keywords, slot cost
lib/spells/chapter_armor.dart              binding validation + slot accounting seam
lib/spells/armor_summary.dart              localCertifiedArmor + keyword display names
lib/spells/inscription_mode.dart           the three-way mode enum
lib/ui/widgets/armor_summary_view.dart     proof-derived summary widget
lib/ui/widgets/armor_picker_dialog.dart    equip picker
lib/battle/models/armor_envelope.dart      the armorLoadout (0x1F) wire payload
lib/battle/engine/armor_certification.dart setup-time validation + derivation
```

**Modified (lib)**
```
lib/battle/engine/trajectory_parser.dart   + certifiedPerGenerationDominantSequence
lib/spells/spell_asset.dart                + isArmor (all 10 copy sites)
lib/spells/chapter_asset.dart              + armorSpellId, slot accounting, delete cleanup
lib/spells/inscribe.dart                   + isArmor pass-through + mode guard
lib/spells/library_backup.dart             chapter import carries/remaps armor
lib/apprentice/apprentice_session.dart     graduation rebuild carries armor
lib/main.dart                              three-way mode, armor preview, mana suppression
lib/ui/library_screen.dart                 badge, affordance gating, ARMOR section
lib/battle/models/chapter.dart             armor filtered out of the castable hand
lib/battle/networking/battle_wire.dart     + armorLoadout(0x1F)
lib/battle/networking/battle_session.dart  + exchangeArmorLoadout
lib/battle/networking/match_discovery.dart kBattleProtocolVersion 5 -> 6
lib/battle/networking/duel_setup.dart      step 7b + injected verifier + result fields
lib/ui/battle_lobby_screen.dart            prepareDuelVerifierResources (VKs + SRS)
lib/battle/networking/battle_session.dart  4.5: forfeit/loss wake blocked waits
lib/ui/battle_screen.dart                  4.5: forfeit is not a lockstep break
lib/battle/networking/battle_wire.dart     4.6: + setupReady(0x47)
lib/battle/networking/duel_setup.dart      4.6: barrier + forfeit backstop
```

**Tests**
```
test/battle/models/certified_armor_test.dart   derivation: ladders, keywords, trust
test/spells/chapter_armor_test.dart            persistence, binding, slot budget
test/spells/armor_summary_test.dart            local proof → CertifiedArmor
test/spells/inscription_mode_test.dart         mode ↔ flag mapping
test/spells/armor_fixture.dart                 shared fixtures (synthetic proofs)
test/ui/game_screen_armor_mode_test.dart       mode bar + live preview
test/ui/armor_summary_view_test.dart           displayed values are proof-derived
test/ui/armor_picker_dialog_test.dart          picker contents + rejection
test/ui/library_armor_test.dart                full equip/replace/remove through the real screen
test/battle/networking/duel_setup_armor_test.dart   end-to-end setup, all four loadout combinations
test/battle/networking/armor_loadout_frame_test.dart the 0x1F frame + the v5/v6 gate
test/battle/engine/armor_certification_test.dart    envelope-level attacks (tier forging, owner, budget)
test/battle/models/chapter_armor_filter_test.dart   armor never enters the castable hand
test/battle/networking/setup_abort_propagation_test.dart  4.5: blocked waits wake on forfeit/loss
test/battle/networking/setup_ready_barrier_test.dart      4.6: asymmetric rejection aborts BOTH sides
```

Test fixtures build synthetic proof bytes via `certified_cast_fixture.dart`'s
`syntheticProof` — no proving, no FFI — and deliberately carry authored metadata
that *contradicts* the proof, so a passing test is evidence the display is
proof-derived. One real end-to-end armor inscription lives in
`test/spells/inscribe_test.dart`.

---

## 5. Test results at the end of slice 4.6

```
flutter test (full suite)  → 1956 passed, 2 failed
dart analyze lib/ test/    → no issues in any touched file
```

The 2 failures are pre-existing `test/ui/vocabulary_screen_test.dart` failures,
reproduced on a stashed clean HEAD (`1789 +, 2 -`) — an ambiguous-text finder,
unrelated to armor. Separately, one *rotating* UI test
(`dev_surfaces_hidden_test` on one run, `spell_test_lab_drive_test` on the next)
fails only under full-suite load and passes alone and within `test/ui/` — the
known load-sensitive flake; adding ~100 tests shifted which one it lands on.

---

## 6. Traps paid for during this work

- **The two trajectory readings** (§1). The single easiest way to silently halve
  every armor stat.
- **`tierForProof`, not `SpellAsset.tier`** (§3). A wrong tier does not fail
  loudly; it produces plausible wrong numbers.
- **Dangling armor bindings.** `SpellAsset.delete()` stripped chapter *entries*
  but nothing cleared an armor binding — the ID would have consumed `ceil(T/4)`
  slots forever with no asset left to price it. Fixed in
  `removeSpellFromAllChapters`.
- **The async resolve window.** The chapter editor resolves armor asynchronously;
  treating "not loaded yet" as cost 0 is a real, if brief, budget bypass. Both the
  slot readout and the ARMOR section fail closed instead.
- **Hand-written copy methods.** `SpellAsset` has ten; `ChapterAsset` has eight.
  Adding a field means touching all of them, and the class gives no help.

### Slice 4's own traps

- **A synthetic proof's owner field defaults to zero.** `syntheticProof` never
  wrote field 1, which no earlier test needed — armor is the first thing that
  binds a proof to a wearer. Every armor fixture was refused as "another
  wizard's" until the fixture learned to carry an owner. The check was working;
  the test was lying. `syntheticProof` now takes `ownerPubkeyBytes`.
- **`Future.wait` on two real `runDuelSetup` calls hangs whenever either side
  refuses.** See §3b's finding. Abort tests must await only the refusing side
  and swallow the blocked one.

### A deliberate deviation worth knowing about

`_hexEq` in `armor_certification.dart` strips the `0x` prefix
**case-insensitively**, where the copies in `duel_setup.dart` and
`library_screen.dart` handle lowercase only. Same semantics, one less way to
read two encodings of one field as two different wizards — and a false negative
there is fail-closed (a refused match, never an accepted forgery). It does mean
the armor module's comparison is marginally more permissive than its
neighbours; unifying the three copies is a separate cleanup.

### Known pre-existing bug, deliberately not fixed

`SpellAsset.withSupremeTags`, `withArt`, `withPackArt`, `withoutArt`, `withSound`,
`withPackSound` and `withoutSound` **all drop `gridWithheld`**. Setting art on a
loaned, grid-withheld spell silently marks it as not withheld. Each of those
methods re-lists every field by hand, which is exactly how the field was missed.
`isArmor` is carried through all ten, but the class is one field-addition away
from the same bug again. Consolidating them into a single `copyWith` is worth a
slice of its own — **deferred by decision, after armor works end-to-end**, not
forgotten.

---

## 7. The boundary — what slices 1–4 deliberately did NOT do

*Historical: this section describes the state at the end of slice 4.6. Item 1 of
"Open before the gameplay slice" was closed by slice 5 — see §9.*

Slices 1–3 touched no wire at all. Slice 4 touches the battle protocol,
`BattleSession` and `runDuelSetup` — and stops there.

Still untouched by armor: `WizardAvatar`, `buildDuelBattleState`, canonical
`BattleState` bytes, melee/movement/range/HP, keyword gameplay,
`PeerCastVerifier`, the spell-book Merkle membership system, armor loans,
`kBattleEngineVersion` and `kRulesetVersion`.

The one-slice gap between "both devices agree on the armor" and "armor does
anything" is deliberate: it lets the agreement be proven before armor can move
the lockstep state.

### Closed by slice 4

`Chapter.fromChapterAsset` now filters armor out of the castable hand; the
setup envelope, proof-resource initialisation and certification are built; slot
cost is recomputed from the certified T. All pinned by tests.

### Open before the gameplay slice

1. ~~**The next slice applies the armor**~~ — **CLOSED 2026-08-26 by slice 5, §9.**
   Numerical effects only; keyword behaviour is still open and deliberately so.
2. **Armor loans are not implemented and are not a gap** — armor is wearable
   only by its proof owner, enforced at certification. If loans are ever wanted,
   they need a `SpellPermission` analogue, not a relaxation of the owner check.
3. ~~A two-device hardware pass has not run.~~ **CLOSED 2026-08-26 — see §8.**
   Everything in slices 1–4.6 was exercised against synthetic proofs and an
   injected verifier; the real-device run validating the VK/SRS plumbing added
   to the lobby has now happened, and passed on all four cases.

---

## 8. The two-device hardware gate (2026-08-26) — PASS

Run before slice 5, so that any failure would have stayed isolated inside the
setup/proof/networking surface rather than tangling with canonical state.
Epochs during the gate were the intended ones and unchanged by it: **protocol
v7, engine v5, ruleset v3.**

### Rig

| | host | guest |
|---|---|---|
| device | Pixel 6 (oriole), Android 17 (API 37), debug APK | Linux desktop, Ubuntu 24.04, `flutter build linux --debug` |
| armor | `Gate Plate (Pixel)` — **T=10, tier 12**, 3 slots | `Gate Plate (Linux)` — **T=20, tier 24**, 5 slots |
| derived | F/A/W/E 7/0/0/0 → melee +1, kw `[cleave]` | F/A/W/E 2/5/1/1 → move +1, kw `[]` |

Different T *and* different circuit tier on the two sides, deliberately: it is
the only configuration in which a VK-routing bug is visible, because each
device must verify at the **peer's** tier rather than its own.

Driven over `adb shell input` + `xdotool`, the same way the M4.22 gate was.
Linux still cannot advertise over mDNS ("Automatic discovery isn't available
here" — the known nsd gap), so the Pixel hosted and Linux joined by manual
address every time.

### Results

| case | result |
|---|---|
| 1. no armor ↔ no armor | **PASS** — mandatory `{"armor":null}` both ways, both crossed the barrier |
| 2. armor ↔ no armor | **PASS** — asymmetric envelopes, peer verified the armored side's real proof |
| 3. armor ↔ armor, different tiers | **PASS** — the critical case; correct VK routing in both directions |
| 4. deliberate rejection | **PASS** — real cryptographic refusal, two-sided abort, correct UI |

### The decisive evidence — one proof, one meaning, across the wire

Case 3, the two derivations of each armor, read off the two devices' logs:

```
Pixel  LOCAL armor certified: T=10 slots=3 F/A/W/E=7/0/0/0 melee=+1 kw=[cleave]
Linux  PEER  armor certified: T=10 slots=3 F/A/W/E=7/0/0/0 melee=+1 kw=[cleave]

Linux  LOCAL armor certified: T=20 slots=5 F/A/W/E=2/5/1/1 move=+1  kw=[]
Pixel  PEER  armor certified: T=20 slots=5 F/A/W/E=2/5/1/1 move=+1  kw=[]
```

`parseOwn` on the owner and `verifyAndParse` on the peer produced **identical**
readings of the same bytes — the hardware form of what
`duel_setup_armor_test.dart` asserts offline (`host.localArmor ==
guest.peerArmor`). Slot cost was recomputed from the certified T on both sides.

**VK routing was correct in both directions:** the Pixel verified at `tier=24`
and Linux at `tier=12` — each at the peer's tier, neither at its own.

**CRS init preceded first verification** on both devices (CLAUDE.md
bug-avoidance #4), by ~2.6 s on the Pixel and ~4.7 s on Linux;
`prepareDuelVerifierResources` loaded all three tiers' VKs (3680 bytes each)
and ran `initSrsCached` (12–13 s) before the handshake started. No delayed
verifier/SRS error appeared after either device entered BattleScreen.

Peer verification cost, measured: **~15 ms at tier 12, ~116 ms at tier 24.**
Negligible against the SRS init that precedes it.

### Case 4 — the rejection, and why it is the interesting half

Constructed by flipping one byte at offset 16000 of the Pixel armor's proof —
past the tier-12 public-input block (10 + 2·12 fields = 1088 bytes), so the
**public inputs still parse identically** and the owner's own `parseOwn`
accepts, while the proof body is cryptographically dead. That is precisely the
shape §3d was built for: the side whose armor is fine finishes first and blocks,
and the refusal has to reach it.

It did. Barretenberg refused it for real —

```
UltraVerifier: verification failed at pairing check
```

— and the two devices ended on the same cause, from opposite roles:

* **Linux (rejecting):** `Duel setup failed: Bad state: peer armor cannot be certified: peer armor proof rejected: verify_ultra_honk rejected the proof — match aborted`
* **Pixel (blocked at the barrier):** `Duel setup failed: PeerForfeitException: the other device ended the match (armor_certification_failed)`

The Pixel had logged `setupReady SENT — blocking for peer readiness` and never
logged the barrier crossing. It woke on the forfeit within seconds, **not** on a
transport death — the §3c fix working on hardware. Neither `runDuelSetup`
returned; neither device reached a BattleScreen; and the message named the real
cause rather than a connection loss or a lockstep break.

The backstop also fired as designed: Linux sent `armor_certification_failed`
and then `setup_failed` from the §3d wrapper. The second forfeit was harmless
exactly as documented — the peer consumed the first and the rest sat unread.

### How the armor was obtained, and why it is not a shortcut

No armor existed on either device, and armor inscription is slice-3 UI whose
correctness this gate is not about. The two armors were forged off-device by a
throwaway harness that **replicates `inscribeSpell`'s body** rather than calling
it, for one reason: `inscribeSpell` takes an `Identity` (a keypair), and an
armor the Pixel can wear needs only the Pixel's **public** key halves — the
circuit binds `owner_pubkey = Poseidon2(key_hi, key_lo)` and never sees a
private key (CLAUDE.md invariant 5). Everything else was the real pipeline: real
prover, real SRS, real self-verification, real `ProofIntake` parse. The packed
grids were copied verbatim from `Basic Firebolt` and `Basic Speedboost` rather
than hand-written, so no cell index was invented.

The resulting proofs are byte-for-byte what those devices would have produced
themselves — which is why each device's own `certifyOwnArmor` accepted its
armor, and the peer's `verifyAndParse` verified it.

### Scaffolding, and what was left behind

All gate instrumentation was **reverted**: the setup path has no logging of its
own, so tagged `gateTrace` lines were added to `duel_setup.dart`,
`battle_session.dart`, `armor_certification.dart`, `battle_lobby_screen.dart`
and `identity.dart` to make certification and the barrier observable, then
removed. Seeing BattleScreen was explicitly not accepted as evidence that both
sides crossed the barrier; the log lines were.

Left in place: the two **valid** forged armors, still installed on their
respective devices but **unequipped** (both `Gate` chapters back to
`armorSpellId: null`), as ready-made fixtures for the slice-5 gameplay pass. The
corrupted case-4 asset was deleted from the Pixel.

### Unrelated pre-existing failure noticed

`test/ui/vocabulary_screen_test.dart` has two failing tests ("a too-short word
is refused with a reason", "suggests a number of attunements per word, with no
ceiling") — an ambiguous text finder matching two `Text` widgets. They fail in
isolation as well as under the full suite, and both the screen and its test are
unmodified by the armor series, so this predates it and is not the known
full-suite flake. Suite otherwise green: 1954 of 1956.


---

## 9. Slice 5 — canonical numerical effects (2026-08-26)

*Engine epoch* **v5 → v6**. Protocol stays **v7**, ruleset stays **v3**. Nothing
here parses, verifies or reinterprets a proof: `DuelSetupResult.localArmor` /
`peerArmor` are already-certified `CertifiedArmor`s and are treated as equipment
from this point on.

### What went live

| element | bonus | where it is applied |
|---|---|---|
| Fire | `meleeBonus` | `DeterministicResolution.applyHaymaker` — the one wizard melee path |
| Air | `moveSpeedBonus` | `WizardAvatar.effectiveMoveSpeed` |
| Water | `spellRangeBonus` | `WizardAvatar.effectiveSpellRange` |
| Earth | `armorHpBonus` | starting HP in `buildDuelBattleState`, and the Statuesque full heal |

Keywords — `flying`, `cleave`, `charger`, `muddy`, `moltenCarapace`, `stealthy`,
`anchored` — are certified, hashed and **inert**. None is wired to anything.

### Armor as equipment

`WizardAvatar` gains `final CertifiedArmor? armor`, an optional named parameter
defaulting to null, so every solo/practice call site is unchanged and no
`armor: null` arguments were added. No `copyWith`, no JSON, no value equality, no
canonical deserialization — the class has none of those and slice 5 added none.

`buildDuelBattleState` gains `localArmor` / `peerArmor` and routes them through
**the existing pubkey-ordered local/peer → bottom/top selector**, the same one the
artifact loadouts ride. There is deliberately no second host/guest mapping: a
guest that seated its own armor on its own bottom wizard would desync on turn 1,
and `duel_battle_setup_armor_test.dart` pins both the correct mapping and that
swapped state hashing differently.

`buildNetworkBattleState` (still callerless) was not touched; its signature was
unaffected.

### Earth — one HP pool

```dart
hp: config.playerHp + (armor?.armorHpBonus ?? 0)
```

No max-HP, no healing cap, no `armorHpRemaining`, no separate armor HP bar, no
breaking or degradation. Provenance is recoverable through
`avatar.armor?.armorHpBonus` rather than by storing a second, mutable copy of the
number on the avatar.

**The Statuesque regression, closed.** `deterministic_resolution.dart`'s
Statuesque wild-magic latch is the only other path that *assigns* a full pool;
it now restores to `state.config.playerHp + (av.armor?.armorHpBonus ?? 0)`.
Left as it was, a Statuesque refill would have quietly stripped an Earth armor's
contribution and made the effect a downgrade for its wearer. Ordinary healing
(`av.hp += e.gainLife`) stays uncapped and untouched.

### Fire — melee

```dart
var damage = 1 + (actor.armor?.meleeBonus ?? 0);
```

placed above the `hasHaymakerDistanceBonus` addition, so the two compose
additively. It is applied exactly once, reaches a punch thrown at a wizard and a
punch thrown at a minion alike, and reaches nothing else: spell damage is priced
elsewhere and a creature strike is priced in `_creatureAttack` from its own stats.

### Air and Water — the composition ruling

`effectiveMoveSpeed` and `effectiveSpellRange` are **the single authoritative
definitions** of those stats, so every consumer inherits the armor term. Three
consequences are intended and are pinned by tests rather than special-cased:

* **Dash.** The movement snapshot is `av.effectiveMoveSpeed * (isDashing ? 2 : 1)`,
  so base 2 + Air 1 walks **3** and dashes **6** — the armor is doubled with the
  rest of the stat, not added after it.
* **Turbulent.** Watery Inertia re-rolls `1..effectiveSpellRange`, so a Water
  armor widens the scatter.
* **Wild-magic random targeting.** `TurnLoop._randomTileInRange` builds its
  candidate pool from `effectiveSpellRange`, so a forced cast can land further
  out on an armored wizard.

There is no "base excluding armor" reading anywhere.

### Canonical encoding

Armor now moves gameplay, so it is hashed. Per avatar, appended at the end of the
avatar record in `BattleState.toCanonicalBytes()`:

```
uint8   present (0 / 1)
  -- only when present --
uint8   t
uint8   slotCost
uint8   fireCount, airCount, waterCount, earthCount
uint8   meleeBonus, moveSpeedBonus, spellRangeBonus, armorHpBonus
uint16  keyword bitmask   (1 << ArmorKeyword.index, per the minion abilityMask pattern)
uint8   elementSequence length
uint8   BorderZone.index  x length
```

Three deliberate choices:

* **Presence is its own byte**, so "no armor" and "an armor whose certified
  sequence happens to be empty" cannot collide.
* **The complete certified semantics go in, not just the four live numbers.** Two
  armors can grant identical active bonuses off different counts, keyword sets and
  trajectories; encoding only the bonuses would let such a pair hash equal while
  the two devices disagreed about what is worn — and the first keyword to go live
  would then desync a match that had looked in lockstep.
* **`t` rides alongside `slotCost`**, which is one field beyond the slice brief's
  list. Slot cost is a lossy function of T (four T values share each rung), so
  agreeing on the cost is not agreeing on the armor.

Nothing authored participates: no proof bytes, no `SpellAsset` metadata. Keywords
go in as a bitmask rather than as `Set` iteration order (insertion order would make
the bytes depend on which pattern matched first), and the element sequence uses the
**existing** counter-charm trajectory encoding — length-prefixed, one byte per
`BorderZone.index` — rather than a second `BorderZone` encoding.

### The epoch

`kBattleEngineVersion` 5 → 6. The gate fires on the usual test: the same wire
transcript hashes differently on either side of the change the moment either peer
wears anything, and even an armourless match moves every hash by the added
presence byte. Beyond the bytes, v5 and v6 resolve an armored match differently in
HP, damage, reach and movement. `kBattleProtocolVersion` stays 7 (no framing
changed — the `armorLoadout` frame shipped in slice 4) and `kRulesetVersion` stays
3 (no proof semantics changed).

### Goldens

Every one of the ten existing replay goldens was regenerated: the per-avatar
presence byte moves every state hash, which is the epoch bump made visible. No
summary field was added, so the readable half of each transcript is unchanged and
the diffs are hashes only.

One script was added — `armor_bonuses_across_a_duel` — putting an armored wizard
(`F×7 A×4 W×4 E×6`: melee +1, move +1, range +1, HP +5, keywords
`{cleave, flying, anchored}`) against an unarmored one over four turns, so all four
bonuses appear in one transcript on **both** devices:

| turn | what the golden records |
|---|---|
| 1 | opening HP 29 vs 24 (Earth); a's punch takes 2, b's takes 1 (Fire) |
| 2 | a walks all three declared tiles to `0,3` — base speed 2 would stop at `0,2` (Air) |
| 3 | a steps to `0,4`, four hexes from b |
| 4 | a casts from there: `resolvedSpells: 1` and b drops 22 → 18 — base range 3 would have refused it (Water) |

The harness gained `MatchScript.localArmor` / `peerArmor` and
`localMeleePicker` / `peerMeleePicker` (melee is its own commit-reveal round, not
part of `TurnInput`). Both devices' `makeDuelState` receive the *same* armor pair,
because both sides of a real duel derive one reading of each proof.

### Tests

New: `test/battle/models/certified_armor_fixture.dart` (shared, builds a
`CertifiedArmor` through `fromOutputs` over synthetic outputs — never through the
editor's `previewFromElementSequence`),
`armor_avatar_stats_test.dart` (18), `armor_canonical_bytes_test.dart` (10),
`duel_battle_setup_armor_test.dart` (10),
`test/battle/engine/armor_numerical_effects_test.dart` (24). Extended:
`battle_engine_version_test.dart` with an explicit v5 ↔ v6 refusal and the
epoch triple pinned as literals.

The keyword-inertness proof is enumerated rather than sampled: one test walks
**every** `ArmorKeyword`, certifies an armor carrying it, and asserts that
`isFlying`, `hasHaymakerDistanceBonus`, `hasHaymakerSlow`, `hasHaymakerDot`,
`hasHaymakerStatusDrain`, `hasPenetrating`, `hasTurbulent`, `isSluggish`,
`isQuick` and `canRevealCounterCharms` are all still false. A keyword added to the
enum without a decision about its behaviour fails there rather than silently
acquiring one.

### Scope fence held

Not implemented: any keyword behaviour, Morphic, armor breaking/destruction/
degradation, separate armor HP, `armorHpRemaining`, max-HP or healing caps, new
networking or setup frames, new proof verification or semantics, circuit changes.
No armor is re-parsed or re-verified after setup.

---

## 10. The slice-5 two-device hardware gate (2026-08-27) — PASS

The slice-4 gate (§8) validated proof exchange, VK routing, certification, abort
propagation and the setup barrier. This one validates what slice 5 added on top:
certified armor entering canonical `WizardAvatar` state, the pubkey-ordered
local/peer → bottom/top seating, canonical state hashing under `engine v6`, and
the Fire/Air numbers actually moving a duel. Epochs during the gate were the
intended ones and unchanged by it: **protocol v7, engine v6, ruleset v3**
(read off `match_discovery.dart:88`, `battle_engine_version.dart:262`,
`inscribe.dart:41`).

### Rig

| | Pixel | Linux |
|---|---|---|
| device | Pixel 6 (oriole), Android 17, `flutter build apk --debug` | Ubuntu 24.04 desktop, `flutter build linux --debug` |
| identity | `0x30094c53…` ("Pixel") | `0x1d93eacc…` ("a") |
| armor | `Gate Plate (Pixel)` — T=10, tier 12, 3 slots, F/A/W/E **7/0/0/0** → melee **+1**, kw `[cleave]` | `Gate Plate (Linux)` — T=20, tier 24, 5 slots, F/A/W/E **2/5/1/1** → move **+1**, kw `[]` |
| chapter | `Gate` (Firebolt / Earthworks / Windhound) | `Gate` (same three) |

Both armors are the §8 fixtures, left installed and unequipped by that gate and
equipped here through the real slice-3 chapter UI — the Pixel's slot line went
`12/12 → 9/12` and Linux's armor card read `+1 move` before either match started.
Both builds came from the same working tree, so both ran engine v6. Driven over
`adb shell input` + `xdotool`, ground truth read from `logcat`/stdout, never
inferred from the picture.

Linux still cannot advertise over mDNS (the known `nsd` gap), so every join used
the manual-address fallback.

### Instrumentation

The setup and turn paths log nothing of their own, so four temporary `gateTrace`
prints were added and **reverted afterwards** (`flutter test test/battle`:
**1124 passing** on the reverted tree):

* `duel_battle_setup.dart` — per-seat: which hex, local or peer, HP, move, range, full certified armor reading;
* `turn_loop.dart` `_exchangeStateHash` — turn number, both hashes, and the per-avatar state behind them;
* `turn_loop.dart` movement phase — the per-player movement budget, dash flags and declared paths;
* `deterministic_resolution.dart` `applyHaymaker` — actor, final damage, armor melee bonus, cleave.

The state-hash exchange runs at the **end** of each turn (`turn_loop.dart:2234`),
so "turn 1" below is the initial state plus one turn of resolution.

### Test 1 — asymmetric armor (Pixel armored, Linux bare) — PASS

Pixel hosted, radius 3, four turns.

**Seating, read off both devices** — the decisive mapping evidence:

```
Pixel  seat bottom hex=0x1d93ea isLocal=false hp=24 move=2 range=3 armor=none
Pixel  seat top    hex=0x30094c isLocal=true  hp=24 move=2 range=3 armor=T=10 slots=3 F/A/W/E=7/0/0/0 melee=+1 kw=[cleave]
Linux  seat bottom hex=0x1d93ea isLocal=true  hp=24 move=2 range=3 armor=none
Linux  seat top    hex=0x30094c isLocal=false hp=24 move=2 range=3 armor=T=10 slots=3 F/A/W/E=7/0/0/0 melee=+1 kw=[cleave]
```

Same armor, same wizard, opposite `isLocal` — the pubkey ordering put the armor
on `0x30094c` on **both** machines, with no host/guest reading anywhere.

| turn | what happened | result |
|---|---|---|
| 1 | both meditate, both walk 2 (budgets `2 / 2`) | hash `0e6793f4` both sides |
| 2 | Pixel steps adjacent; **both punch** | Pixel `damage=2 armorMelee=+1`, Linux `damage=1 armorMelee=+0`; HP 24→22 (Linux) and 24→23 (Pixel); hash `7f1c3c62` |
| 3 | both punch again | same 2 vs 1; HP 20 / 22; hash `3a846292` |
| 4 | both step apart | hash `714d95a6` |

Fire armor moved **only** melee: the wearer's `move` stayed 2, `range` stayed 3
and starting HP stayed 24 (`armorHpBonus` 0) on both devices.

### Test 2 — both sides armored — PASS

Roles deliberately **reversed** for this one (Linux hosted, Pixel joined), radius
4, five turns. Same seating agreement, now with two armors:

```
Linux  seat bottom hex=0x1d93ea isLocal=true  hp=24 move=3 range=3 armor=T=20 slots=5 F/A/W/E=2/5/1/1 move=+1 kw=[]
Linux  seat top    hex=0x30094c isLocal=false hp=24 move=2 range=3 armor=T=10 slots=3 F/A/W/E=7/0/0/0 melee=+1 kw=[cleave]
Pixel  seat bottom hex=0x1d93ea isLocal=false hp=24 move=3 range=3 armor=T=20 slots=5 F/A/W/E=2/5/1/1 move=+1 kw=[]
Pixel  seat top    hex=0x30094c isLocal=true  hp=24 move=2 range=3 armor=T=10 slots=3 F/A/W/E=7/0/0/0 melee=+1 kw=[cleave]
```

Byte-identical initial readings from opposite roles, and the seating did not
follow the host/guest swap — which is the failure this test exists to catch.

| turn | what happened | result |
|---|---|---|
| 1 | Linux walks **3** (budget `3` vs Pixel's `2`); UI accepted exactly 3 steps | all three tiles walked, `(0,4)→(0,1)`; hash `94b28a83` |
| 2 | Linux **dashes**: budget `6`, six tiles declared and walked `(1,0)→…→(3,-4)` | `localDash=true` / `peerDash=true` agreed; hash `d2933c96` |
| 3 | Linux closes 2 tiles; **both punch** | Pixel `damage=2`, Linux `damage=1` — an *armored* Linux still punches for 1, because Air grants no melee; hash `ec3765fe` |
| 4 | Linux steps back 2 | hash `1891fcc1` |
| 5 | Pixel casts Basic Firebolt at range 3 | Linux 22→18, Pixel mana 100→87; hash `1e739316` |

Dash confirms the composition ruling on hardware: base 2 + Air 1 walks **3** and
dashes **6** — the armor is doubled with the rest of the stat, not added after it.

### Hash agreement

Nine state-hash exchanges across the two matches, every one identical on both
devices; **zero** `match=false`, no forfeit, no `state_hash_mismatch`:

```
match 1 (radius 3):  0e6793f4  7f1c3c62  3a846292  714d95a6
match 2 (radius 4):  94b28a83  d2933c96  ec3765fe  1891fcc1  1e739316
```

Both devices printed the same 32-byte hash *and* the same per-avatar HP / mana /
position / move / range / armor line behind it, on every turn.

### Cleave stayed inert

The Pixel's armor certifies `[cleave]` on both devices (it is in the seating
lines above, so it is in the canonical bytes and in the hash). Every punch it
threw dealt exactly `1 + meleeBonus = 2` to the single targeted wizard, applied
once, with no splash, no status and no second damage event — three punches, in
two matches. A 1v1 with no minions cannot show a splash *not* happening to a
second body, so the enumerated inertness proof in
`armor_numerical_effects_test.dart` (every keyword, ten behaviour getters) remains
the stronger evidence; hardware adds that the keyword is carried, hashed and
agreed without altering resolution.

### Test 3 — Earth and Water — NOT RUN, deliberately

Neither existing fixture reaches the Earth or Water ladders (Pixel is 7/0/0/0;
Linux's single water and single earth are below the 4 and 2 breakpoints), so this
test needed **new forged armors** — a throwaway harness, two fresh proofs bound to
each device's public key, and an install on each device. The basic spells cannot
be reused as armor: their proofs are owned by the shipped key `0x2bc53f13…`, and
`certifyOwnArmor`'s owner check refuses any proof whose certified `owner_pubkey`
is not the wearer's (correctly). Under the gate brief's own instruction not to
spend significant time on inconvenient fixtures, this was skipped.

What that leaves uncovered on hardware: `hp: config.playerHp + armorHpBonus` with
a non-zero bonus, and a cast landing at a Water-extended range. Both are pinned
offline by `duel_battle_setup_armor_test.dart`, `armor_avatar_stats_test.dart` and
the `armor_bonuses_across_a_duel` replay golden (turn 1 opening HP 29 vs 24; turn
4 casting at four hexes, which base range 3 would refuse). The degenerate half of
the HP formula *was* observed on hardware: both wearers started at 24 = 24 + 0.

### Anomalies

* **None in the product.** No mismatch, no misseated armor, no wrong number, no
  keyword firing, no setup regression, nothing engine-v6-specific.
* **Tooling, not product:** `xdotool type` cannot produce `:` under this machine's
  keymap (keycode 47 carries `s S semicolon colon`, so xdotool presses shift and
  gets `S`), which broke manual-address entry *from* Linux. Worked around by
  swapping host/guest for match 2 and typing the address on the Pixel with
  `adb shell input text`, which handles the colon. Worth remembering for the next
  gate: **the Pixel is the reliable side for typing an address.** The swap turned
  out to be a bonus — it made match 2 a role-reversed rerun of the seating check.

### Device state left behind

Both `Gate` chapters are left with their armor **equipped** (unlike §8, which left
them unequipped), so the next gate can host a duel without re-equipping. Test
chapters and the two armor assets are otherwise untouched; no scaffolding remains
in the source tree.

### Verdict

**PASS.** Certified armor becomes canonical state, seats on the same wizard on
both devices under either role, hashes identically every turn, and Fire and Air
produce exactly their documented numbers in a real duel. Earth and Water were not
exercised on hardware and rest on their offline coverage.

---

## 11. Slice 6 — Charger and Muddy go live (2026-08-27)

*Engine epoch* **v6 → v7**. Protocol stays **7**, ruleset stays **3**. Nothing
parses, verifies or re-reads a proof; nothing changes on the wire; **nothing
changes in the canonical encoding**.

Exactly two of the seven certified keywords stop being inert:

| keyword | pattern | capability it turns on | mechanic that runs |
|---|---|---|---|
| Charger | `FAFA` | `WizardAvatar.hasHaymakerDistanceBonus` | the Air haymaker's `tilesWalked ~/ 2`, unchanged |
| Muddy | `WEWE` | `WizardAvatar.hasHaymakerSlow` | the Earth haymaker's `speedDown −1` for 2 turns, unchanged |

`flying`, `cleave`, `moltenCarapace`, `stealthy` and `anchored` stay inert;
Morphic stays unbuilt.

### The whole integration is two OR clauses

```dart
bool get hasHaymakerSlow =>
    (armor?.hasKeyword(ArmorKeyword.muddy) ?? false) ||
    activeStatusEffects.any(… haymakerSlow …);

bool get hasHaymakerDistanceBonus =>
    (armor?.hasKeyword(ArmorKeyword.charger) ?? false) ||
    activeStatusEffects.any(… haymakerDistanceBonus …);
```

That is the entire behavioural change. `DeterministicResolution.applyHaymaker`
was **not touched**: it still reads each capability as a single boolean, once,
and it remains the only definition of what the distance bonus and the slow
mean. The keywords buy a wearer into those mechanics; they do not restate them.

Three consequences fall out of reusing the getter rather than adding a branch,
and all three are pinned by tests rather than argued:

* **Composition is free and additive.** A punch is
  `1 + armor.meleeBonus + tilesWalked ~/ 2`, in that order, because slice 5's
  Fire term already sits above the distance term in the one melee path. Fire
  and Charger on the same armor pay once each — three contributions, no
  interaction.
* **Rounding, Dash and walked-distance semantics are inherited verbatim.**
  Distance is the *walked path length* from `resolveAvatarMovement` (conveyor
  detours included), not net displacement; it rounds down (`~/ 2`); a Dash
  changes it only by making the path longer. Three tiles is +1, not +1.5;
  standing still is +0. The tests assert this as an **equality against the
  status-driven source**, not as a number of its own, because the claim is
  "same mechanic", not "same arithmetic today".
* **Two sources cannot double-apply.** Armor and status feed one boolean, and
  the resolution reads that boolean once, so a wearer who also holds the Air
  haymaker buff gets one bonus and one slow.

### Certified armor is the only authority

Both reads are `avatar.armor?.hasKeyword(...)` against the `CertifiedArmor`
seated at setup. No `SpellAsset`, no authored formula, no `supremeTags`, no
proof bytes, no element-sequence matching, and no re-verification — the
proof → `CertifiedArmor` boundary closed in slice 4 and is not reopened here.

### Canonical state is byte-identical to v6

No field was added. Charger and Muddy already rode in the keyword bitmask that
shipped in slice 5, so the same `BattleState` hashes the same under v6 and v7 —
which is exactly why the epoch has to move. A v6 device and a v7 device would
agree on the opening hash and diverge the first time an armored wizard threw a
punch: same bytes, different meaning, the one failure mode
`kBattleEngineVersion` exists to refuse.

`armor_canonical_bytes_test.dart` now pins the record itself — 14 bytes plus
the element sequence, re-encoded by hand in the test and compared field for
field, with the tail asserted byte-identical to the unarmored stream — so a
future keyword that tries to buy itself a serialization field fails there.

### Goldens

The ten pre-existing goldens are **unchanged**, which is the corpus stating that
no transcript without a Charger or Muddy armor moved — including
`armor_bonuses_across_a_duel`, whose armor certifies `{cleave, flying,
anchored}` and still resolves exactly as it did under v6.

One script was added — `charger_and_muddy_through_the_haymaker` — because
Muddy's whole point outlives the turn that applies it:

| turn | what the golden records |
|---|---|
| 1 | a walks two tiles to `1,-1` and punches: b drops 24 → **21** (1 base + 1 Fire + 1 Charger) and carries **one** status. Under v6 the same punch is 2. a opens at 26 (the two earths inside `WEWE`). |
| 2 | b declares two tiles and arrives at `2,0`, one short — the slow is still on it. Nobody is adjacent, so nothing else happens and the turn is purely the status's consequence. |

Its armor is `F A F A F F W E W E`: fire 4 (melee +1), earth 2 (HP +2), keywords
`{charger, muddy}` — deliberately not four *consecutive* fires, so Cleave is
absent and cannot be mistaken for the damage.

### Tests

* `armor_avatar_stats_test.dart` — the two capability grants, the pre-armor
  status source still standing alone, a dormant/removed status not suppressing
  the armor's grant, and armor-without-the-keyword granting nothing. Its
  blanket enumeration is now a **table of approved live hooks**: every keyword
  is walked, the approved one must flip its own hook, and every other hook must
  stay false. A new `ArmorKeyword` — or an old one quietly wired to something —
  fails there until it is explicitly approved.
* `armor_numerical_effects_test.dart` — the behavioural half, through real
  turns: distance bonus earned and not earned, equal to the status source,
  rounding down, zero-movement, Dash, applied once with both sources, composing
  with Fire, reaching a minion punch; Muddy's slow landing once with the
  status source's own magnitude, duration and representation; Fire + Charger +
  Muddy together; and Cleave failing to splash onto a second body while Flying,
  Molten Carapace, Stealthy and Anchored change no punch at all.
* `battle_engine_version_test.dart` — the v6 ↔ v7 refusal, both directions
  (peer capabilities and host config), with the epoch triple pinned as literals.

### Scope fence held

Not implemented: the other five keywords, Morphic, any new movement or
walked-distance rule, any new haymaker or slow mechanic, armor breaking or
degradation, proof/networking/setup changes, canonical encoding changes, UI
changes. `applyHaymaker` was not refactored to accommodate its new callers.

### Hardware validation

Closed by §12 — **Aetherial Armor engine-v7 hardware gate: PASS** (2026-08-28).

---

## 12. The slice-6 two-device hardware gate (2026-08-28) — PASS

**Aetherial Armor engine-v7 hardware gate: PASS.**

§10 validated slice 5's numbers at engine v6. This validates *only* what slice 6
added on top — Charger and Muddy stopping being inert — on the real Pixel ↔ Linux
path. The rest of the surface (proof exchange, VK routing, certification, the
abort/barrier shapes, the Fire/Air numbers, the seating) was gated in §8 and §10
and was deliberately **not** re-run as a matrix. Epochs during the gate were the
intended ones and unchanged by it: **protocol 7, engine 7, ruleset 3**.

### Rig

| | Pixel | Linux |
|---|---|---|
| device | Pixel 6 (oriole), Android 17 (API 37), `flutter run` debug | Ubuntu 24.04 desktop, `flutter run -d linux` debug |
| identity | `0x30094c53…` ("Pixel") | `0x1d93eacc…` ("a") |
| armor | **Charger Plate** | **Muddy Plate** |
| chapter | `Gate` (Firebolt / Earthworks / Windhound) | `Gate` (same three) |

Linux hosted and the Pixel joined by manual address — the same arrangement §10
landed on, for the same two reasons: Linux still cannot advertise over mDNS
(`MissingPluginException … com.haberey/nsd`, logged verbatim again this run), and
`xdotool` on this machine cannot type `:`, so the address has to be typed on the
Pixel with `adb shell input text`.

### The two new fixtures, and how they were made

The `Gate Plate` armors from §8/§10 carry neither keyword (Pixel `7/0/0/0`,
Linux `2/5/1/1`), so this gate needed two new proof-backed armors. Both were
made **on the devices themselves**, through the real pipeline — real `Identity`,
real grid, real prover, real self-verification, real `SpellAsset.save()` — by a
throwaway entrypoint (`lib/gate_armor_forge.dart`) that calls `inscribeSpell`
and nothing else, then deletes itself. This is stronger than §8's off-device
forging: the proving key, the SRS and the private key are the device's own, and
the asset lands in the real library the chapter UI reads.

Nothing about the encoding was invented. The two grids were **found** by
searching the canonical Dart stepper (`runStepper`) for initial states whose
per-generation dominance sequence contains the required run, and the certified
readings below were then re-derived from the *proofs* by
`CertifiedArmor.fromOutputs` — the same one authoritative derivation the duel
uses:

```
Pixel   CERTIFIED armor T=12 slots=3 F/A/W/E=4/2/0/0 melee=+1 move=+0 range=+0 hp=+0 kw=[charger] seq=FFFAFA
Linux   CERTIFIED armor T=12 slots=3 F/A/W/E=0/0/2/2 melee=+0 move=+0 range=+0 hp=+2 kw=[muddy]   seq=WEWE
```

Both audit clean against their own proofs (`auditSpellJson` → 0 faults; the
three authored fields were rewritten from the proof by `repairSpellJson` before
the asset was used, so the M4.22 class of drift cannot be what a result here
means).

The Charger fixture is deliberately `FFFAFA` and not, say, `FFFFAFA`: four fires
reach the melee ladder's first rung (**+1**) while three *consecutive* fires
leave **Cleave absent**, so the punch's third point cannot be confused with a
second keyword. `WEWE` is the minimal Muddy armor — two earths put it on the
Earth ladder's first rung (+2 HP) and nothing else.

Both were equipped through the real slice-3 chapter UI (Replace → pick), which
read them back proof-derived — the Pixel's card showed `Fire 4 / +1 melee /
Charger`, Linux's `Earth 2 / +2 armor HP / Muddy`, slots `9/12` on both.

### Instrumentation

The setup and turn paths log nothing of their own, so five temporary `gateTrace`
prints were added and **reverted afterwards** (`duel_battle_setup.dart` seating,
`turn_loop.dart` state-hash exchange and movement, `deterministic_resolution.dart`
`applyHaymaker`, `duel_setup.dart`'s engine gate, plus a battlefield tap-geometry
print used only to aim the driver). Nothing was inferred from an animation; every
claim below is a log line from **both** devices.

### Seating — read off both devices

```
Linux  seat bottom hex=0x1d93ea isLocal=true  hp=26 move=2 range=3 armor=T=12 slots=3 F/A/W/E=0/0/2/2 hp=+2 kw=[muddy]   charger=false muddy=true
Linux  seat top    hex=0x30094c isLocal=false hp=24 move=2 range=3 armor=T=12 slots=3 F/A/W/E=4/2/0/0 melee=+1 kw=[charger] charger=true  muddy=false
Pixel  seat bottom hex=0x1d93ea isLocal=false hp=26 move=2 range=3 armor=T=12 slots=3 F/A/W/E=0/0/2/2 hp=+2 kw=[muddy]   charger=false muddy=true
Pixel  seat top    hex=0x30094c isLocal=true  hp=24 move=2 range=3 armor=T=12 slots=3 F/A/W/E=4/2/0/0 melee=+1 kw=[charger] charger=true  muddy=false
```

Byte-identical readings from opposite roles, and the two capability booleans are
seated on the right wizards: **Charger on the Pixel only, Muddy on Linux only**.

This also closes, incidentally, the one thing §10 left untested on hardware: the
Earth HP path with a **non-zero** bonus. Muddy Plate's two earths opened Linux at
**26 = 24 + 2**, agreed by both devices and shown in the HUD.

### The duel — seven turns, radius 3

| turn | what happened | result |
|---|---|---|
| 1 | Pixel walks 2 `(0,-3)→(0,-1)`, Linux walks 1 `(0,3)→(0,2)`; both meditate | budgets `2 / 2`; hash `04ecef15` |
| 2 | **Turn A.** Pixel walks 2 `(0,-1)→(0,1)`, arrives adjacent, punches | `damage=3`; Linux 26 → **23**; hash `104d2b7f` |
| 3 | **Turn B.** Both stand; Linux punches, Pixel passes | `damage=1`; Pixel 24 → 23, gains **one** slow; hash `3970abe0` |
| 4 | **Persistence.** Pixel declares its full walk while slowed | budget **1**, walked **1** tile; hash `7f93f059` |
| 5 | Pixel walks 2 again (slow expired) | budget back to **2**, walked 2; hash `53d43b6d` |
| 6 | Both step one tile closer | hash `6aef73bf` |
| 7 | Pixel casts Basic Earthworks (13 mana) | mana 100 → **87** both sides; hash `e58d312c` |

**Turn A — Charger, and the Fire composition.** The decisive line, identical on
both devices:

```
gateTrace haymaker actor=0x30094c damage=3 base=1 armorMelee=+1 distBonus=1
          hasDistance=true hasSlow=false tilesWalked=2 kw=[charger]
```

`1 + 1 + 1 = 3`, in the documented order, from an armor carrying **no** status
effect (`fx=[]` on the actor all turn) — so `hasDistance=true` came from the
Charger keyword and nothing else. The target dropped exactly 3 (26 → 23), once:
one haymaker line, one HP change, no second damage event.

**Turn B — Muddy.** Again identical on both:

```
gateTrace haymaker actor=0x1d93ea damage=1 base=1 armorMelee=+0 distBonus=0
          hasDistance=false hasSlow=true tilesWalked=0 kw=[muddy]
...        av=0x30094c hp=23 move=1 fx=[speedDown:1{speedDelta: -1}]
```

Muddy grants the slow and *only* the slow: its wearer's punch is a plain 1 (no
melee bonus, no distance bonus even though it had walked earlier in the match).
The victim carries **exactly one** `speedDown` entry with the Earth haymaker's
own magnitude (`-1`) and representation — not a second armor-specific status —
and its effective move fell 2 → 1.

**The following turn is the point.** On turn 4 the slowed wizard declared the
walk it would normally have: both devices independently computed
`budget=1` for it (and `budget=2` for the unslowed opponent), and it resolved
`tiles=1 path=(0,1)>(0,0)` — one tile short. The UI agreed ahead of the engine:
the path builder refused the second tile. On turn 5, with the status ticked
away, the same wizard walked 2 again — so the slow expired identically on both
devices too.

### Hash agreement

Seven state-hash exchanges, every one identical on both devices, **zero**
`match=false`, no forfeit, no `state_hash_mismatch`:

```
04ecef15  104d2b7f  3970abe0  7f93f059  53d43b6d  6aef73bf  e58d312c
```

Both devices also printed the same per-avatar HP / mana / position / move /
range / keyword / status line behind every one of them. Three of the seven come
*after* both keyword effects had resolved (turns 5–7, including a proof-backed
cast), which is the evidence the effects leave no divergent state behind them.

### The other five keywords stayed inert

Neither fixture certifies `flying`, `cleave`, `moltenCarapace`, `stealthy` or
`anchored` — the seating lines show `kw=[charger]` and `kw=[muddy]` and nothing
else — and no unrelated effect appeared: no flight, no splash, no status other
than the one slow, no stat the ladders did not account for. §10's `[cleave]`
fixture was replaced on the Pixel for this gate and so was not re-exercised;
five-keyword inertness continues to rest on `armor_numerical_effects_test.dart`'s
enumeration and `armor_avatar_stats_test.dart`'s approved-hook table, which are
the stronger evidence anyway (a 1v1 cannot show a splash *not* reaching a second
body).

### Negative control — v6 ↔ v7, refused before battle

A genuine engine-**v6** Linux build was made for this (the epoch constant back to
6 **and** the two OR clauses removed, so it is v6 in behaviour and not merely in
its declaration) and paired against the v7 Pixel. Both roles refused, independently,
at **step 2b** — the capabilities exchange, before the match config, before
identity auth, before any `BattleState` exists:

```
Pixel  gateTrace engineGate step=2b role=DuelRole.guest local=7 peerCaps=6 verdict=REFUSE
Linux  gateTrace engineGate step=2b role=DuelRole.host  local=6 peerCaps=7 verdict=REFUSE
```

Neither device printed a seating line, so `buildDuelBattleState` was never
reached; neither reached a BattleScreen; both returned to the battle menu, and
the forfeit sent was `battle_engine_mismatch`. **This is the check that matters
most for slice 6**: canonical armor bytes are byte-identical between v6 and v7,
so a v6/v7 pair would have agreed on the opening hash and diverged on the first
punch. It is refused at the handshake instead — the failure mode the epoch exists
to abolish.

One product observation worth writing down: the refusal is **silent in the UI**.
Both devices simply return to the battle menu with no message naming the cause,
which is why this gate needed a log print to see it at all. Not a slice-6 defect
and not fixed here (the scope fence holds), but a real UX gap — a player on a
stale build is told nothing. Logged as a follow-up.

### Anomalies

* **None in the product.** No mismatch, no misseated armor, no wrong number, no
  double application, no unexpected keyword, no setup or networking regression.
* **Tooling, not product:** the `xdotool` colon gap (§10) again, plus the
  manual-address field not clearing between attempts, so a second address typed
  into it concatenates. Both are driver problems, not app defects.
* **A destructive cleanup mistake, after the gate had passed:** `flutter install`
  wiped the Pixel's app data, including its identity. See *Scaffolding and device
  state* below — no gate result depends on it, but the device does not survive
  the session intact.

### Scaffolding and device state

All five `gateTrace` prints reverted; `lib/gate_armor_forge.dart` and the three
throwaway search/check scripts deleted; the v6 patch reverted (epoch back to 7,
both OR clauses restored). Post-revert: `flutter analyze lib/` reports **0
errors**, `flutter test test/battle -j 1` is **1150 passing**, and
`flutter test test/spells test/ui/armor_*_test.dart -j 1` is **302 passing**.
Both devices were rebuilt from the clean v7 tree afterwards.

**Linux** is left as the gate found it: identity `0x1d93eacc…`, `Muddy Plate`
**equipped** on the `Gate` chapter, `Gate Plate (Linux)` still present and
unequipped.

**The Pixel's app data was destroyed during cleanup, after the gate finished.**
Rebuilding "a clean v7 build onto both devices" was done with `flutter install`,
which defaults to the **release** APK; a release APK cannot update a
debug-signed install, so the tool uninstalled first and Android deleted the app's
data with it. Lost: the identity `0x30094c53…`, the spell library, the `Gate`
chapter, and both armor fixtures (`Charger Plate` and the §8 `Gate Plate
(Pixel)`). The debug build was reinstalled and the device now sits on onboarding.

This cost the gate nothing — every result above was logged while the run was
live, hours before — but it did cost the Pixel's identity and its fixtures. An
encrypted identity backup dated 2026-08-07 survives on the device at
`/sdcard/Download/runewright_identity_backup.txt` (shared storage is not touched
by an uninstall), and restoring it needs **Soren's passphrase** — the in-app
restore refused a blank one. Until it is restored the Pixel has no Runekey.

**The lesson, for whoever runs the next gate:** never use `flutter install` on a
device carrying state you care about. `flutter run -d <device>` builds and
installs the **debug** APK, which updates in place and preserves app data;
`flutter install` silently means "release", and on this project that means a
signature change, an uninstall, and a wiped Runekey. Take an identity backup
*and* a library backup before any gate that will reinstall.

### Verdict

**PASS.** Every applicable success criterion met: real Charger and real Muddy
armor certified on hardware; Charger using the existing distance semantics;
Fire + Charger composing to exactly 3; Muddy applying the existing slow, once;
that slow changing the *following* turn's movement on both devices; seven
identical state hashes including three after the effects; unrelated keywords
inert; and v6 ↔ v7 refused before battle rather than as a later divergence.

---

## 13. Feature freeze for the Friday playtest (2026-08-28)

With §12 passing, **Aetherial Armor is feature-frozen**. The playtest set is:

* **Core** — proof-certified armor inscription; one armor per chapter; the
  shared 12-slot artifact budget; `ceil(T/4)` slot cost; public setup
  certification; canonical armor state.
* **Numerical** — Fire → melee, Air → movement, Water → spell range, Earth →
  starting HP.
* **Keywords** — Charger, Muddy.

Not to be started before the playtest: Flying, Cleave, Molten Carapace,
Stealthy, Anchored, Morphic; armor breaking or destruction; additional armor
stats; and any balance change prompted only by reading the code. Balance numbers
stay exactly as they are — the point of the playtest is to find out what they
are worth in play.

Open follow-ups, deliberately not acted on here:

* the silent engine-mismatch refusal (§12) — the player sees no reason;
* the Pixel's Runekey needs restoring from its encrypted backup (§12, needs
  Soren's passphrase), and its `Charger Plate` fixture re-forging afterwards if a
  future gate wants it;
* Earth/Water on hardware is now partly covered (a non-zero `armorHpBonus` was
  observed at 26 = 24 + 2 in §12); a Water-extended cast range remains
  offline-only coverage.
