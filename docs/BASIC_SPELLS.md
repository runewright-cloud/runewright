# BASIC_SPELLS.md — the shipped starter spells

Implemented 2026-07-27 on `feature/practice-mode`, per `docs/BASIC_SPELLS_PLAN.md`
(that file has the full design rationale and settled decisions; this file is the
quick-reference + maintenance recipe).

## What ships

Five spells bundled at `assets/basic_spells/*.json`, registered in the generated
`lib/spells/basic_spells.dart` (`kBasicSpells`):

| Slug | Name | T | tier | mana | notes |
|---|---|---|---|---|---|
| `basic_firebolt` | Basic Firebolt | 6 | 12 | 13 | Fire |
| `basic_speedboost` | Basic Speedboost | 6 | 12 | 13 | Air |
| `basic_manabond` | Basic Manabond | 6 | 12 | 13 | Water |
| `basic_earthworks` | Basic Earthworks | 6 | 12 | 13 | Earth |
| `basic_windhound` | Basic Windhound | 23 | 24 | 83 | Summon |

Every install seeds all five into the local library on first launch (and on any
subsequent launch where the marker version is behind — see `basic_spell_seed.dart`),
via `lib/ui/app_root.dart`'s `AppRoot._identityExistsAfterSeeding`.

## What "Basic" means, mechanically

A spell is Basic iff its `(commitmentHex, T)` matches one of `kBasicSpells`
(`isBasicGridAndT`) — checked against **verified proof outputs only** at any trust
boundary, never a wire-supplied claim. Being Basic grants two exemptions, both scoped
narrowly (see `docs/BASIC_SPELLS_PLAN.md` §5/§7 and `docs/BATTLE_AUTH_PLAN.md` §4a for
the full reasoning):

1. **Ownership.** `localIdentityMayUse`/`castingPlayerMayUse` authorize anyone to use
   or cast a Basic spell, regardless of the dev `owner_pubkey` its shipped proof
   declares.
2. **Kin-stacking.** `TurnLoop`'s per-match "no casting the same grid twice" guard
   (`_seenPeerCommitments`) is skipped for a Basic grid/T — a chapter may hold
   unlimited copies, and casting more than one per match is legitimate.

Chapters may also hold unlimited **library-add** duplicates of a Basic spell (the
one-copy-per-chapter UI guard in `lib/ui/library_screen.dart` is skipped via the same
`isBasicSpell` check). Making that safe required `BookCommitment.proveMembershipAt`
(prove-by-position) plus `SpellCastAction.handIndex`/`TurnLoop._localCastPosition` —
casting a specific copy resolves to the caster's own known hand SLOT, not a
commitment search, which would otherwise always resolve to the first duplicate
occurrence (see `BASIC_SPELLS_PLAN.md` §7 for why that's unsafe: it desyncs
`DrawSchedule` hand/wither bookkeeping between clients).

Counter Charms may target a Basic spell's grid like any other (no exemption there —
public grids are deliberately counterable, a settled tradeoff).

## Deleting / restoring

A player may delete a Basic spell from their library; it stays deleted on normal
launches (the seed marker only ever adds spells that are *missing*, keyed by
`spellHashHex`). The Library's overflow menu → **Restore basic spells** re-adds any
of the five currently missing (`seedBasicSpells(force: true)`).

## Adding a sixth Basic spell

1. Inscribe it normally (Rune Craft → Inscribe), name it however you like.
2. Add its `spellHashHex` + a new slug to `_kSelection` in
   `scripts/export_basic_spells.dart`.
3. Bump `kBasicSpellSetVersion` (top of that same script).
4. Run `dart run scripts/export_basic_spells.dart` — regenerates
   `assets/basic_spells/<slug>.json` and `lib/spells/basic_spells.dart`.
5. `dart format` the two touched files if the script's own formatting drifts.
6. Re-run `flutter test test/spells/basic_spells_test.dart
   test/spells/basic_spell_seed_test.dart test/spells/spell_authorization_test.dart` —
   the version bump means existing installs will pick up the new spell on next
   launch without disturbing the ones they already have (per-`spellHashHex`
   existence check in `seedBasicSpells`).
7. No circuit change, no `RULESET_VERSION` bump — the proof already exists and
   already verifies; this whole feature is client-side bookkeeping only.

## Key files

| File | Role |
|---|---|
| `scripts/export_basic_spells.dart` | Source of truth for the selection; (re)generates the two outputs below. |
| `assets/basic_spells/*.json` | Bundled `SpellAsset` JSON, byte-identical to what the script wrote. |
| `lib/spells/basic_spells.dart` | GENERATED registry + `isBasicSpell`/`isBasicGridAndT`. Do not hand-edit. |
| `lib/spells/basic_spell_seed.dart` | `seedBasicSpells()` — idempotent, marker-gated library seeding. |
| `lib/ui/app_root.dart` | Calls `seedBasicSpells()` on every launch (fire-and-forget, never blocks routing). |
| `lib/spells/spell_authorization.dart` | Ownership exemption. |
| `lib/battle/engine/turn_loop.dart` | Kin-stacking exemption (`_verifyPeerSpellCast` §2); `handIndex` plumbing for duplicate-safe casts. |
| `lib/battle/engine/book_commitment.dart` | `proveMembershipAt` — prove-by-position, the duplicate-copy fix. |
| `lib/ui/library_screen.dart` | Chapter-add dedup exemption; Basic mark on the card; Restore action. |

## Tests

- `test/spells/basic_spells_test.dart` — registry ↔ bundled-asset transcription check.
- `test/spells/basic_spell_seed_test.dart` — seeding idempotency, delete-stays-deleted, restore.
- `test/spells/spell_authorization_test.dart` — ownership exemption, incl. the
  proof-forgery negative case.
- `test/battle/engine/book_commitment_test.dart` — `proveMembershipAt`, incl. duplicate leaves.
- `test/battle/engine/basic_spell_duplicate_chapter_test.dart` — end-to-end: three
  copies of one Basic spell cast across three turns without crashing or forfeiting;
  a non-Basic duplicate still forfeits (Kin-stacking exemption is scoped, not general).

Not yet done: a real two-device LAN duel casting a Basic spell from a non-dev
identity (see `BASIC_SPELLS_PLAN.md` §10 — real-device gate, not optional for a
trust-boundary change).
