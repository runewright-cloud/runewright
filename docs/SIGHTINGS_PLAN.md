# Sightings — Implementation Plan

*Written 2026-07-19 for a Sonnet implementation pass. Confirms the current
(unimplemented) state of the Library's **Sightings** tab and specifies the full
build. Decisions in §1 were made by Soren; do not re-litigate them.*

---

## 0. Current state (confirmed)

The **Sightings** tab is a **static placeholder** — no data source, no
persistence, no capture logic:

- `lib/ui/library_screen.dart:201-207` wires the tab to `_PlaceholderTab`
  (defined at `:2189`), which renders only an icon + descriptive text.
- The file header comment (`:4-7`) flags it as a placeholder for an "upcoming
  protocol feature." (That comment is stale — it says only Craftings and
  Chapters hold real data, but Loans is now wired too. Update it in this pass.)
- The sibling tabs are all real: Craftings (`SpellAsset.loadAll`), Loans
  (`_LoansTab`, `:2030` — filters `gridWithheld` spells by `SpellPermission`),
  Chapters (`ChapterAsset`), Tests.

## 0a. Blocker you must know about (does NOT block this task)

**There is no LAN → `BattleScreen` flow yet.** `BattleScreen` is only ever
constructed from `solo_practice_settings_screen.dart:337` and
`spell_test_lab_screen.dart:284`, both passing a `SoloBattleSession`. The battle
lobby (`battle_lobby_screen.dart`) connects a `Transport` and then shows a
`const _ConnectedSection()` — it never navigates into a networked battle.

Consequence: **real opponent casts do not occur in the app today.** The Sightings
capture hook you build will be correct and will fire the moment a real
(non-solo) `BattleTurnSession` is wired into `BattleScreen`, but it will not
populate the tab through normal play until that separate wiring exists. This is
expected. Build the full vertical slice; prove it with the synthetic-event test
in §5, not by playing a duel. Add a short note to `docs/M4_findings.md` recording
that Sightings capture is wired but dormant pending the LAN-battle flow.

---

## 1. Decisions (settled — Soren, 2026-07-19)

1. **Data model: grouped by opponent.** Sightings are organized under each foe's
   identity (sigil + name/hex), with the distinct spells that opponent has cast
   listed beneath. Not a flat per-cast log, not a global spell catalogue.
2. **Read-only this pass.** Sightings are a viewable card list only. No gameplay
   hooks. (Counter-charm attunement to a sighted `commitmentHex` is the obvious
   phase-2 follow-up — see §7 — but is explicitly out of scope now.)
3. **LAN duels only.** Record opponent casts only in real peer-to-peer battles.
   Exclude solo/practice dummy casts (`SoloBattleSession`, whose casts use a
   sentinel commitment — `solo_battle_session.dart:59`).

---

## 2. The data that is already available (verified)

When an opponent casts, the receiving device reconstructs a partial `SpellAsset`
at `lib/battle/engine/turn_loop.dart:2900` carrying exactly:

- **`commitmentHex`** — the grid commitment; the spell's stable identity and the
  counter-charm targeting key. This is the dedup key for "distinct spells."
- **`t`** — generation count.
- **`formula`** — `List<String>` of zone names (the public effect breakdown).
- `tier` (hardcoded 24) and `proofBytes`.
- **Empty on the reconstructed asset:** `initialGrid` (never revealed — the
  `gridWithheld` model; correct to omit), `name`, `ownerPubkeyHex`, `manaCost`.
  The card + formula labels render fine from `commitmentHex` + `formula` alone.

**Mana and name ARE to be included** (Soren, 2026-07-19) — they are not withheld
by design, they just aren't on the reconstructed asset. They come from two
different places:

- **Mana cost — available now, via the certified path (no wire change).** The raw
  cost is *not* transmitted, but both devices must deduct the identical amount or
  the mana ledger desyncs, so the receiver recomputes a certified cost with
  `_certifiedManaCost` (`turn_loop.dart:3172`; the B-1/B-8 trust-boundary design).
  That value is authoritative and public — the `manaCost: 0` on the reconstructed
  asset (`:2906`) is just a placeholder field. **Do not read `ev.spell.manaCost`;
  capture the certified cost.** Small engine task: `verifiedCost` is currently
  computed and immediately spent (`:3186`) and not retained — attach it to
  `ResolvedSpellEvent` (or a turn-scoped `commitmentHex → cost` map on `TurnLoop`,
  populated alongside `lastResolvedSpells`) so the capture hook can read it.
  - **Store the certified BASE cost** (Soren, 2026-07-19): `5×segmentCount +
    dotCount` grown by `1.05^T`, derived from the SNARK public `outputs` —
    intrinsic to the spell, stable across casts. Do **not** store the per-cast
    modifier-laden `verifiedCost` (Potent/chain-discount/sorcerer-vocal/
    `nextSpellCostDouble` make it wobble). The base is the clean bestiary stat.
    You can read the certified `segmentCount`/`dotCount`/`T` from the same
    `outputs` `_certifiedManaCost` consumes (`turn_loop.dart:3172-3178`); factor
    the base-cost arithmetic (step 1 of `_certifiedManaCost`, `:3196`) into a
    small helper both paths call so it can't drift.
- **Name — requires a small battle-wire change.** `spell.name` is never encoded
  today (decode hardcodes `name: ''`). Add a length-prefixed UTF-8 name to the
  `0x01` `SpellCastAction` encoding (`turn_loop.dart:2708-2714`) and the `0x03`
  `MysterySpellCastAction` encoding (`:2739-2744`), and decode it into the
  reconstructed `SpellAsset.name` (`:2900-2915`, `:2999`). Two caveats:
  1. **It's a wire-format bump.** Not a circuit/`RULESET_VERSION`/VK change (the
     name isn't consensus-visible to the CA), but it changes the encoded action
     bytes that feed action commit/reveal hashing, so old/new clients can't
     interoperate. Nothing has shipped — cheap now; just keep both peers in sync.
     Add a golden/round-trip encode↔decode test for the new field.
  2. **The name is unauthenticated flavor** — not bound in the proof the way
     `commitmentHex` is. Treat it as cosmetic: keep `commitmentHex` as the
     identity/dedup key (the grouped model already does), never dedupe on name,
     never trust it as identity. An opponent can mislabel a spell; that's fine for
     a display label.

**Opponent identity — store the full triad: pubkey (Runekey) + sigil (hash art) +
name** (Soren, 2026-07-19). Names alone are spoofable/duplicable; the pubkey and
its derived sigil are what disambiguate a same-name collision or a casual
impersonator.

- The cast event carries `casterId` (== `WizardAvatar.playerId`, an in-match path
  id — NOT a pubkey). Map it to the caster's avatar via `BattleState.avatars` to
  get **`WizardAvatar.ownerPubkeyHex`** (`wizard_avatar.dart:158`), which for a
  real peer is the pubkey bound in their proof's public inputs
  (`proof_intake.dart:173-189`). **`ownerPubkeyHex` is the canonical identity and
  the grouping key** — store it in full (the "signature"/Runekey).
- The **sigil is the hash art**: a deterministic function of the pubkey. Render it
  with `SigilWidget(keyBytes: fieldHexToLeBytes(opponentPubkeyHex, 32), …)` — the
  exact call `_SpellCard` uses at `library_screen.dart:774`. Do NOT store the
  sigil; it's re-derived from the stored pubkey every render (no bytes to persist,
  always consistent). Two identities with the same name produce visibly different
  sigils.
- The human **wizard name** is a separate, nice-to-have field. It is *not* the
  spell name from the §2 wire change — it identifies the *caster*, not the spell.
  No authenticated wizard-name reaches `BattleScreen` today (the mDNS
  `displayName` at `battle_lobby_screen.dart:434` is unplumbed, and the battle
  handshake carries no signed identity announce). So `opponentName` is nullable;
  record it when a later LAN/handshake change provides one, and always render it
  visually subordinate to the sigil + pubkey fingerprint. Never dedupe or group on
  the name.

**Authentication reality (must not be over-promised).** Storing pubkey + sigil
fully disambiguates *accidental* name collisions and *casual* name-spoofing (the
sigil differs). It does **not**, on its own, prevent a determined attacker from
*imitating a specific person's pubkey*, nor does it provide replay freshness. The
precise reason:

- `owner_pubkey = Poseidon2(key_hi, key_lo)` where the halves are the **public
  key**, split (`identity.dart:96,119`). It is a *label* (a hash of a public
  value), **not a signature** and not secret-derived. The circuit binds it but
  deliberately never verifies a signature or key possession (CLAUDE.md invariant
  5). `SpellAsset` carries no signature field.
- Therefore the proof alone proves neither that the caster holds the private key
  (an attacker with the victim's *raw* pubkey — obtainable via a trade/loan
  handshake — can witness the matching halves and forge authorship) nor that the
  cast is fresh (a static proof re-sent still verifies — no per-cast nonce).
- The intended defense is an **off-circuit, cast-time** step, and its pieces
  already exist but are **unwired in battle**: present the raw pubkey →
  `Identity.ownerPubkeyMatches` (`identity.dart:161`, "the cast-time check
  CIRCUIT_IO 5 requires") to bind it to the proof's `owner_pubkey`, **plus** an
  `Identity.sign`/`verify` (`:122-140`) Ed25519 signature over a **fresh nonce**
  to prove possession + freshness. Loans already do the signature half
  (`spell_permission.dart:177-209`); `castingPlayerMayUse`
  (`spell_authorization.dart:64`) is written but explicitly deferred ("pass an
  empty list"); and `grep` finds no `sign`/`verify`/`ownerPubkeyMatches`/challenge
  in `lib/battle/networking/`.

So a sighting faithfully records whatever `owner_pubkey` label the opponent's
proof presented — trustworthy only up to that missing cast-time authentication.
Full imitation-/replay-resistance requires wiring the cast-time challenge; track
it as a **separate security task** (see §7) — it is the load-bearing control for
the whole battle path, not a Sightings nicety. The plan must not claim Sightings
defeats intentional impersonation until that challenge lands.

**Capture hook location:** `_submitTurn` in `lib/ui/battle_screen.dart:1004-1008`
already snapshots `_loop.lastResolvedSpells` (`List<ResolvedSpellEvent>`) and
`_loop.lastCastEvents`. Each `ResolvedSpellEvent` (`turn_loop.dart:267`) has
`spell` (`SpellAsset`) and `casterId`. This is the hook: after a turn resolves,
record every resolved spell whose `casterId != widget.localPlayerId`.

Prefer `lastResolvedSpells` over `lastCastEvents` — a resolved spell is one that
actually took effect (not fizzled/countered), which is the intuitive meaning of
"a spell cast against you." (If a countered spell should also be recorded, that's
a follow-up decision; default to resolved-only.)

---

## 3. Persistence layer — `SightingAsset` + `SightingStore`

Mirror the existing `SpellAsset` file-per-record JSON pattern
(`lib/spells/spell_asset.dart` — `_spellsDir()`, `save()`, `loadAll()`,
`delete()`, `fromJson`). Create `lib/spells/sighting_asset.dart`.

**One file per (opponent, spell) pair**, keyed so repeat casts update rather than
duplicate. Suggested id: `${opponentPubkeyHex}_${commitmentHex}` (sanitized for
filesystem — strip `0x`, both are hex so already path-safe). Store in a
`sightings/` subdir of the app documents dir (parallel to `spells/`).

Fields:

```dart
class SightingAsset {
  final String opponentPubkeyHex;   // canonical grouping key
  final String? opponentName;       // opponent wizard name; null until LAN flow plumbs it
  final String commitmentHex;       // spell identity / dedup key
  final String spellName;           // the spell's own name (§2 wire change); '' if absent
  final List<String> formula;       // public effect breakdown
  final int t;                      // generation count
  final int tier;
  final int manaCost;               // certified cost (§2); 0 if unavailable
  final DateTime firstSeen;         // UTC
  final DateTime lastSeen;          // UTC — updated on each re-sighting
  final int timesSeen;              // incremented on each re-sighting
}
```

Note the two distinct names: `opponentName` (who cast it — from identity, not yet
plumbed) vs `spellName` (the spell's own flavor name — from the §2 wire change,
unauthenticated). Keep them separate. `toDisplaySpell()` should set the
`SpellAsset.name` from `spellName` and `manaCost` from the stored `manaCost` so the
card shows both.

- `record(...)`: static upsert. Load existing file for the id if present; if
  found, produce a copy with `lastSeen = now`, `timesSeen + 1`, and refreshed
  `formula`/`t` (in case a later cast carries fuller data); else create with
  `timesSeen = 1`, `firstSeen = lastSeen = now`. Then `save()`.
- `loadAll()` → `List<SightingAsset>`.
- `delete()` and a `deleteAllForOpponent(pubkeyHex)` convenience (for a future
  "forget this rival" action; wire the per-opponent one into the UI menu if
  cheap, otherwise leave the method and skip the button).
- `toDisplaySpell()` → a lightweight `SpellAsset` (empty grid, the stored
  `commitmentHex`/`formula`/`t`/`tier`) so `SpellCardWidget` and
  `formulaEffectLabels` can render it unchanged.

Write `test/spells/sighting_asset_test.dart` covering: fresh record, upsert
increments `timesSeen` + advances `lastSeen` but preserves `firstSeen`, round-trip
`toJson`/`fromJson`, `loadAll` grouping, delete. Follow the style of
`test/spells/spell_asset_test.dart`.

---

## 4. Capture wiring

In `lib/ui/battle_screen.dart`, `_submitTurn`, right where `resolved` is
snapshotted (`:1008`), add a fire-and-forget capture call **gated on session
type** so solo/practice never records:

```dart
// LAN-only (§1.3): SoloBattleSession casts are scripted dummies with a
// sentinel commitment — never record them.
if (widget.session != null && widget.session is! SoloBattleSession) {
  unawaited(_recordSightings(resolved));
}
```

`_recordSightings(List<ResolvedSpellEvent> resolved)`:
- For each event with `casterId != widget.localPlayerId`:
  - Look up the caster avatar: `widget.state.avatars.firstWhere((a) => a.playerId == ev.casterId)` (guard for not-found → skip).
  - Skip if `avatar.ownerPubkeyHex` is empty or the all-zero sentinel
    (`'0x${'0' * 64}'`, cf. `solo_battle_setup.dart:75`) — belt-and-suspenders
    against a mis-wired dummy.
  - Skip if `ev.spell.commitmentHex` is empty.
  - `await SightingAsset.record(opponentPubkeyHex: avatar.ownerPubkeyHex, commitmentHex: ev.spell.commitmentHex, spellName: ev.spell.name, formula: ev.spell.formula, t: ev.spell.t, tier: ev.spell.tier, manaCost: <certified cost for this cast>)`.
  - **Mana cost source:** read the retained certified cost (§2), not
    `ev.spell.manaCost` (always 0). This requires the engine change in §2 —
    surface `verifiedCost` on `ResolvedSpellEvent` or a `commitmentHex → cost`
    map. If the base-cost sub-decision (§2) is chosen, compute it from the
    certified `outputs` instead of the modifier-laden `verifiedCost`.
  - **Spell name source:** `ev.spell.name` — populated once the §2 wire change
    lands; `''` until then (record it either way; the card falls back to
    "Unnamed Spell").
- Never let a capture failure surface to the player or break the turn — wrap in
  try/catch, swallow (optionally `debugPrint`). Sightings are a side effect, not
  part of lockstep.

Confirm the exact field names on `ResolvedSpellEvent` (`turn_loop.dart:267-281`:
`spell`, `casterId`) and `SoloBattleSession`'s import path before writing.

Note the `mounted`/async ordering: `_recordSightings` only touches disk, not
widget state, so it needs no `setState` and no `mounted` guard.

---

## 5. UI — grouped-by-opponent Sightings tab

Replace the `_PlaceholderTab` used for Sightings (`library_screen.dart:201-207`)
with a real `_SightingsTab` (stateful, `AutomaticKeepAliveClientMixin`, matching
`_CraftingsTab`/`_LoansTab` structure). Keep the `_PlaceholderTab` class if
nothing else uses it after this change — otherwise delete it. Verify no other tab
still references it (currently only Sightings does).

Behavior:
- `initState` loads `SightingAsset.loadAll()`; group by `opponentPubkeyHex` into
  a `Map<String, List<SightingAsset>>`. Sort opponents by most-recent `lastSeen`
  across their spells; sort each opponent's spells by `lastSeen` desc.
- Empty state → reuse `_EmptyBody` (`:2229`) with `Icons.visibility_outlined` and
  copy like: *"No spells sighted yet. Spells cast against you in a duel will be
  recorded here."*
- Loading → `CircularProgressIndicator(color: kIlluminationGold)`; error →
  `_ErrorBody` (`:2257`). Follow `_CraftingsTab.build` (`:362`).
- Body: a `ListView` of opponent sections. Each section header is an
  `_OpponentHeader` showing the full identity triad (§2), sigil-first so identity
  reads visually before any spoofable text:
  - **Sigil (hash art):** `SigilWidget(keyBytes: fieldHexToLeBytes(opponentPubkeyHex, 32), size: 36, saturation: 2.5)` — same call as `library_screen.dart:774`; import `fieldHexToLeBytes` from `../identity/key_packing.dart` (already imported at `:14`). This is the primary anti-collision cue.
  - **Name (if present):** `opponentName`, rendered as the prominent label — but only when non-null. When null, fall back to the pubkey fingerprint as the label (don't invent a name).
  - **Pubkey fingerprint (the "signature"):** always show a truncated-hex form of `opponentPubkeyHex`, matching `_LoanTile._lenderLabel` (`:2143-2147`, `0x1234abcd…`), as a monospace-ish subtitle beneath/beside the name. This is what distinguishes two same-named wizards. Consider making it long-press-to-copy the full hex.
  - Optional: `"N spells sighted"` count.
  - Beneath: the opponent's spells as cards.
  - Do NOT let the name visually dominate the sigil+fingerprint — the design
    intent (§2) is that a viewer trusts the sigil/pubkey, not the name.
- Each spell → a compact card reusing `SpellCardWidget(spell: sighting.toDisplaySpell(), size: 84)` (as `_SpellCard` does at `:699`) plus text: the formula labels via `formulaEffectLabels`/`summonSummaryFromFormula` (mirror `_SpellCard._formulaText`, `:625-631`), `Gen ${t}`, and a "Last seen {date}" / "seen ×{timesSeen}" line (reuse `_SpellCard._date` formatting, `:633-640`). No mana cost (unknown for opponents). No "Add to Chapter" / art / delete-spell actions — sightings are read-only (§1.2). A per-spell or per-opponent "Forget" delete is optional; if included, confirm with an `AlertDialog` like `_SpellCard`'s delete (`:646`).
- `RefreshIndicator` → reload, matching the other tabs.

Consider extracting the card visuals shared with `_SpellCard` only if it's clean;
otherwise a purpose-built read-only `_SightingCard` is fine and lower-risk.

---

## 6. Tests

1. `test/spells/sighting_asset_test.dart` — §3.
2. Capture unit test: construct synthetic `ResolvedSpellEvent`s (one from the
   local player, one+ from an opponent avatar with a real-looking pubkey), run
   the `_recordSightings` logic, assert only opponent casts are stored and that a
   repeat cast upserts (`timesSeen == 2`, `firstSeen` unchanged). If
   `_recordSightings` is a private method, factor the pure part into a
   testable top-level/static function (e.g. `sightingsFromResolved(resolved,
   localPlayerId, avatars)`) and test that; keep the widget method a thin
   disk-writing wrapper.
3. Widget test for `_SightingsTab`: seed a couple of `SightingAsset`s across two
   opponents, pump the Library, assert two opponent sections render with the
   right sigils/labels and the right spell cards. Follow the existing library
   widget tests; heed the known `LibraryScreen` widget-test hang flagged in the
   Commune/Trade work (pre-existing, unrelated — if you hit it, isolate the
   `_SightingsTab` under test rather than the whole `LibraryScreen`).

Run the full suite (`flutter test`) before finishing; the repo was ~446 green as
of the Commune/Trade pass.

---

## 7. Out of scope (do NOT build; note as follow-ups)

- **Counter-charm attunement to a sighting.** The strategic payoff — attuning a
  Counter Charm to a sighted `commitmentHex` (today you can only attune to your
  own library spells via `_CounterCharmAttunementDialog`). Deferred by decision
  §1.2. When built, it slots into the chapter/artifact flow
  (`ArtifactEntry(kind: counterCharm, targetCommitmentHex: …)`).
- **Cast-time Ed25519 challenge** (the real imitation-resistance fix, §2
  "Authentication reality"). Wiring a handshake/cast challenge that proves the
  peer holds the private key for the `owner_pubkey` they present — using the
  existing `Identity.sign`/`verify` (`identity.dart:122-140`), currently unused in
  the battle path. Until it lands, Sightings' pubkey/sigil identity is only as
  strong as the transport. **Track as its own security task.** Sightings does not
  depend on it and must not claim to defeat impersonation without it.
- **Plumbing an authenticated opponent wizard-name** into `BattleScreen` / the
  sighting record (a signed identity announce in the battle handshake, or the
  mDNS `displayName` at `battle_lobby_screen.dart:434`). Leave `opponentName`
  null-ready; do not build it here.
- **The LAN → BattleScreen wiring itself** (§0a). Separate task.
- Anything behind a design-doc `[DECISION]`/`[TODO]` flag.

---

## 8. File checklist

| File | Change |
|---|---|
| `lib/spells/sighting_asset.dart` | **New.** `SightingAsset` model + store (§3). |
| `lib/battle/engine/turn_loop.dart` | Add spell-name to `0x01`/`0x03` cast encode+decode (§2 wire change); retain the certified `verifiedCost` (`:3172-3186`) onto `ResolvedSpellEvent` / a `commitmentHex → cost` map for the capture hook (§2/§4). |
| `lib/battle/networking/battle_wire.dart` | If the wire-format bump warrants a protocol-version marker, note it here (nothing shipped, so optional). |
| `lib/ui/battle_screen.dart` | Add gated `_recordSightings` call in `_submitTurn` (§4). |
| `lib/ui/library_screen.dart` | Replace Sightings `_PlaceholderTab` with `_SightingsTab` (§5); fix stale header comment (`:4-7`); remove `_PlaceholderTab` if now unused. |
| `test/spells/sighting_asset_test.dart` | **New** (§6.1). |
| `test/ui/` (capture + tab) | **New** (§6.2–6.3). |
| `docs/M4_findings.md` | One-line note: Sightings capture wired but dormant pending LAN-battle flow (§0a). |

## 9. Invariants & discipline (from CLAUDE.md)

- Sightings are a **local side effect** — never part of lockstep, never affect
  turn resolution, never re-derive anything from the opponent's audio/grid. A
  capture failure must be swallowed.
- Do **not** synthesize or store the opponent's **grid** — it is never revealed
  and must not be fabricated. Mana (certified, §2) and name (wire change, §2) are
  legitimately available and *are* stored. Treat the spell name as unauthenticated
  flavor: `commitmentHex` remains the identity/dedup key, never the name.
- Match the surrounding code's idiom (serif manuscript styling, `k*` color
  constants, `manuscriptCaptionStyle`, file-per-record JSON persistence).
- Small, focused commits. Run `flutter test` before commit; `flutter run -d
  linux` to eyeball the tab (seed a sighting via the test or a temporary debug
  button, since real duels can't populate it yet).
