# Wild Magic v2 — Slice 3 review: preview semantics & solo/practice identity

*Written 2026-09-02, on `main`, against `54db4a7` ("Rekey wild magic to certified spell
semantics"). This is the review-gate record for the slice, not a plan — the design lives in
`WILD_MAGIC_PLAN_VNEXT.md`, the implementation record in `WILD_MAGIC_PLAN.md` §7.5.*

## Goal

After this slice Wild Magic means one thing everywhere:

> `current caster × certified spell behavior × active LeylineConfig`

in the battle engine **and** on every player-facing preview. The inscriber of a spell is not
its Wild Magic identity unless that person is also the one casting.

---

## 1. Preview derivation path, before → after

**Before** (`lib/spells/wild_magic_preview.dart` as of `54db4a7`) — a second, approximate
derivation that could disagree with the duel on all three axes:

```
caster   ← spell.ownerPubkeyHex            (the INSCRIBER)
behavior ← spell.formula → borderZonesFromNames → completedFormulasFromZones
           + _authoredBaseManaCost(5·segmentCount + dotCount, 1.05^spell.t, 1.5^n)
leyline  ← LeylineConfig.ordinary(activeLeylineSeed.value)
         → WildMagic.triggersFor(...)
```

**After** — one derivation, the engine's:

```
caster   ← activeWildMagicContext.value.casterPubkeyHex   (the VIEWER / CASTER)
leyline  ← activeWildMagicContext.value.leyline           (structured LeylineConfig)
behavior ← PeerCastVerifier.certifyOwnProof(spell, caster, leyline).wildMagic
           i.e. ProofIntake.parseOwn(spell.proofBytes, tierForSpell(t) ?? spell.tier)
                → semanticsOf → TrajectoryParser + certifiedBaseManaCost + WildMagic
```

`certifyOwnProof` is literally the call `TurnLoop.certifiedFromProofBytes`
(`lib/battle/engine/turn_loop.dart:2640`) makes for a local cast, so preview and engine
cannot disagree given the same `(proof, caster, leyline)` triple.

Neither the grid commitment nor the proof bytes enter the preimage — proof bytes are only
parsed to recover certified semantic outputs, per §3/§4.

**Caching.** Keyed on `caster | leylineConfigHash | tier | t | SHA-256(proofBytes)`, via
`wildMagicPreviewCacheKey`. The parse tier depends on `tier`/`t` because the **engine's**
parse does — that is agreement, not a preimage dependency. See §10 for why the digest is
exact rather than sampled, and for the scope limit on that digest.

## 2. Identity / config plumbing

**Removed:** `activeLeylineSeed` (`ValueNotifier<String>`), `refreshActiveLeylineSeed`,
`overrideLeylineSeed`, `_authoredBaseManaCost`.

**Added:** `WildMagicPreviewContext {casterPubkeyHex, leyline}` — immutable and value-equal,
so cards only rebuild on a real change — behind **one** authoritative
`ValueNotifier<WildMagicPreviewContext> activeWildMagicContext`, with read-only getters
`activeLeylineConfig` / `activeCasterPubkeyHex`, plus `refreshActiveWildMagicContext()`,
`resolveLocalCasterPubkeyHex()`, `overrideWildMagicContext()` and a test-only
`debugClearWildMagicPreviewCache()`.

Primed at the session boundaries:

| Surface | Primes | Note |
|---|---|---|
| `app_root.dart` | leyline | from `Identity.loadCommunitySeed()`; `Identity.exists()` now resolves the boot route **before** priming starts, and the refresh never calls `loadOrCreate` unless an identity already exists — so it cannot mint a Runekey behind the router's back |
| `menu_screen.dart` | caster | reuses the `ownerPubkeyHex()` the sigil `FutureBuilder` already computes; this is what covers the post-onboarding case, where no identity existed at boot |
| `settings_screen.dart` | leyline | rotating the seed pushes a new `LeylineConfig.ordinary(raw)` through the notifier, so the library visibly re-rolls |
| `battle_screen.dart` | **both** | `MatchConfig.leyline` + the local `WizardAvatar.ownerPubkeyHex` for the duration of the duel, restored on dispose |

`BattleScreen` reading the **avatar's** key rather than the device identity is what makes
card/duel agreement structural: whatever was seated is what will actually cast.

## 3. Solo / practice identity

`buildSoloBattleState`'s `localOwnerPubkeyHex` is now a **required** named parameter — there
is no honest default — and both solo screens resolve it through
`resolveLocalCasterPubkeyHex()` before pushing. `_beginBattle` / `_beginTestBattle` became
async and surface *"Could not read your Runekey"* rather than seating a stub wizard.

No pre-existing deterministic bot identity existed in the codebase, so the practice dummy
got one:

```dart
const kPracticeOpponentPubkeyHex =
    '0x000052756e657772696768742f50726163746963654f70706f6e656e742f7631';
// = utf8("Runewright/PracticeOpponent/v1") in the low 30 bytes, high bytes zero
```

Stable across runs, a canonical 32-byte BE Field comfortably under the BN254 modulus, and
self-documenting in its own bytes: it is recognizable and distinct **by construction** —
readable as what it is, and assigned to a player by no code path — which is a structural
claim, not a cryptographic one about `Poseidon2` outputs. Both all-zero keys are gone from
the solo path.

## 4. Trade / borrowed spells

* **Borrowed or traded spells in the library — case (a).** They preview under the local
  player's identity, because `SpellAsset.ownerPubkeyHex` is no longer consulted anywhere.
* **Trade-offer previews — case (b).** `TradeItem.previewSpellAsset()` carries
  `proofBytes: Uint8List(0)` by design (the proof does not exist locally until the grant
  arrives post-confirm), so there is no certified data to derive from and the card renders
  **no** Wild Magic panel. Test-pinned rather than left to chance.

Inscriber-keyed behaviour was not reintroduced anywhere to preserve the old UI.

## 5. Remaining `spell.ownerPubkeyHex` in a Wild Magic context

**None.** Every surviving mention in `lib/` is a doc comment stating why it is *not* read.

The remaining `ownerPubkeyHex: ''` literals — `battle_wire_codec.dart:516/620`,
`trade_offer.dart:137`, `forced_cast.dart:454`, `main.dart:1345` — are all *spell inscriber*
fields on decoded/synthetic assets, not caster identities, and the engine keys Wild Magic on
the avatar.

## 6. Tests

New / changed:

* `test/support/wild_magic_fixture.dart` — **new.** Shared structurally-real proof blob and
  fixture spell. The preview now needs a parseable proof, so a hand-built `SpellAsset` is no
  longer a sufficient fixture.
* `test/spells/wild_magic_preview_test.dart` — **rewritten**, 24 tests, covering required
  items 1–5, 8 and 9. Caster keys re-pinned by brute force against the new fixture.
* `test/battle/models/solo_practice_identity_test.dart` — **new**, 8 tests, items 6 and 7.
* `test/ui/spell_card_wild_magic_test.dart` — repointed from owner keys to caster keys, plus
  a new UI-level fail-closed test (no viewer identity → no foil, no panel).

The independence tests (item 8) clear the paint cache between the two sides, so they compare
two real derivations rather than one derivation and a cache hit.

```
targeted:  wild_magic_preview_test        28/28
           solo_practice_identity_test      8/8
           spell_card_wild_magic_test       6/6
preserved: wild_magic_test, wild_magic_resolution_test, leyline_config_test,
           test/battle/replay/             unmodified, all green
full:      flutter test → 2223/2223 passed
```

**One flake worth recording, not chasing.** Across four full-suite runs of this tree, one
run failed `test/battle/engine/basic_spell_duplicate_chapter_test.dart` (the duplicate-grid
forfeit case). It passes standalone and passed the other three full runs. It is an ENGINE
test, which widens the known rotating-flake pattern beyond the UI tests recorded on
2026-08-16 — nothing in this slice touches `_verifyPeerSpellCast` or the duplicate-grid
guard.

## 7. Analyzer

`flutter analyze` → **0 errors**, 39 info/warning. Verified against a true baseline
(`git stash --include-untracked`, re-analyze): the pristine tree reports the same **39**, so
this slice adds none. All are pre-existing `avoid_print` in `scripts/`,
`curly_braces_in_flow_control_structures`, `use_null_aware_elements`, two `unnecessary_import`
in `battle_screen.dart` predating this work, and one `unused_element_parameter`.

## 8. Versions and goldens — unchanged

`git status` reports **unmodified** for `circuits/`, `ffi/`, `test_vectors/`,
`test/battle/replay/`, `wild_magic.dart`, `leyline_config.dart`, `peer_cast_verifier.dart`
and all three version files.

| | |
|---|---|
| BattleEngine | **8** (unchanged) |
| BattleProtocol | **7** (unchanged) |
| Ruleset | **3** (unchanged) |
| Circuit / VK | untouched |
| Replay goldens | unchanged |

No canonical `BattleState` byte moved. This slice changed no consensus semantics.

## 9. Surfaces that cannot yet produce an authoritative preview

1. **Trade-offer stubs** — no proof exists locally until the grant lands. Blank, by design.
2. **Bestiary sightings** (`sighting_asset.dart:420`, `proofBytes: Uint8List(0)`) — now
   blank where they previously showed an inscriber-keyed approximation. This is arguably the
   *correct* end state rather than a gap: VNEXT §15 says opponents must not learn Wild Magic
   from a card, and under v2 a sighting is another wizard's spell in another wizard's hands
   anyway.
3. **Any card painted before the Runekey is read** — a one-frame window between
   AppRoot/MenuScreen priming and the first paint. Blank, then repaints via the notifier.

## 10. Cache-key hardening (pre-commit, at review)

The first implementation keyed the paint cache on length + first/last 8 bytes of the proof.
That is not merely theoretically weak here — it **aliased in practice**. Every proof of a
given tier shares a length, the same leading field-count bytes, and the same trailing
`dotCount` field, so two spells differing only in their trajectory produced an identical
key and one card painted the other's Wild Magic.

Replaced with the exact digest:

```dart
String proofIdentityForPreview(Uint8List proofBytes) =>
    _proofDigests[proofBytes] ??= uniqueSpellId(proofBytes);   // SHA-256(proofBytes)

final Expando<String> _proofDigests = Expando<String>('wildMagicProofDigest');
```

`uniqueSpellId` (`lib/spells/spell_identity.dart:137`) is canonically
`SHA-256(proofBytes)`, but it is a **pure function with no memo** — calling it per paint
would rehash ~14 KB per card per frame, which is the cost the cache exists to avoid. So it
is **lazily computed once per proof blob and memoized outside the paint path**. An `Expando`
rather than a map because it is keyed by object identity and holds keys weakly: entries
vanish with the `SpellAsset`, so it needs no cap and cannot outlive a library.

**Scope limit, stated in the source as well as here.** This digest is a *local preview-cache
identity only*. It is **not** a new gameplay spell identity, and its suitability here is not
a precedent for moving any commitment consumer onto `uniqueSpellId` — grid-commitment
transmission, book Merkle leaves, duplicate-grid / duplicate-spell guards, spell permissions
and grants, trade protocol identity, wire binding and canonical hand ordering are all
untouched and belong to the separate commitment-exposure / privacy audit.

Four tests cover it, in `wild_magic_preview_test.dart` → *"the paint cache identifies a
proof exactly"*: two real fixture proofs are shown to be exact old-fingerprint aliases
(same length, same leading 8, same trailing 8, different bytes); their cache keys differ;
the digest equals `uniqueSpellId`; and — with no cache clear between the calls — the second
spell does not read the first one's triggers out of the cache.

---

## 11. Scope discipline

Not begun, per the brief: Mountains cap, Spontaneous Combustion count, Phoenix expiry,
Statuesque, Rippling Reflections expiry, Scattered Gusts redesign, trigger coalescing,
Mutable Leyline dictionaries. `LeylineConfig.mutable` is *hashed* in one test to prove the
preview reacts to a structured config change — no dictionary behaviour was implemented.

## 12. Two calls left open for Soren

1. **`localOwnerPubkeyHex` is required, not defaulted.** Deliberate — fail-loud beats a
   silent stub wizard — but it touched three unrelated test call sites
   (`safe_layout_test`, `innate_mana_pool_test`, `duel_battle_setup_armor_test`), each of
   which now names a test key explicitly.
2. **Solo practice hard-stops when the Runekey cannot be read.** Unreachable in the app,
   since routing already gates on `Identity.exists()`, but it is a hard stop rather than a
   degrade. The alternative — practising as a stub wizard — is the bug this slice removed.
