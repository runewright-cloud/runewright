# Master / Apprentice — Implementation Plan

*Target implementer: Sonnet. Design notes captured 2026-07-28; promoted to a full plan
2026-07-29, on `feature/practice-mode`. Scope decisions ratified by Soren (§2).*

*This supersedes the design-notes version of this file. §§1–2 preserve the original
decision record; §3 onward is the build.*

---

## 1. Why this is a distinct primitive, not just another trade

`docs/COMMUNE_TRADE_PLAN.md` already gives two players a way to loan or transfer
individual spells to each other. Master/Apprentice is **not** that, used repeatedly — it's
a coarser-grained primitive aimed at teaching a new player, not at trading between peers
who already know the game.

The design motivation: a new player's on-ramp works best when learning to *duel* is
decoupled from learning to *craft* a spell (the CA-design step is a much colder, more
solo-feeling task than being walked through a duel live). Magic: the Gathering solves this
by letting an experienced player hand a newcomer a finished precon deck; the newcomer
plays immediately and picks up deckbuilding later, if ever. Master/Apprentice is
Runewright's equivalent: a master hands an apprentice a **whole premade Chapter**, not a
hand-picked handful of spells, so the apprentice has a complete, coherent, already-balanced
casting pool for their first few duels without needing to author anything.

## 2. Ratified decisions (do not re-litigate)

### 2.1 The unit of the loan

1. **The unit is a whole `ChapterAsset`, not an individually curated set of spells.** A
   master offering an apprenticeship picks one existing chapter (presumably a
   premade/starter one) and loans it in full. This is what distinguishes it from a regular
   Trade offer, which is always an explicit per-spell selection.
2. **Loaning a chapter populates the apprentice's loan library with one `SpellPermission`
   (`kind: loan`) per distinct spell commitment the chapter contains** — not a single
   permission scoped to the chapter as an opaque unit. The existing authorization gates
   (`localIdentityMayUse`/`castingPlayerMayUse` in `lib/spells/spell_authorization.dart`)
   check permissions per `commitmentHex`; there is no chapter-level concept at that layer,
   and this decision keeps it that way — the chapter loan is sugar over "grant every spell
   in this chapter," not a new authorization primitive.
3. **A chapter is only eligible to be offered if every spell in it is natively owned by the
   master** (`spell.ownerPubkeyHex == master's own ownerPubkeyHex`) **— not merely usable by
   them via a loan or transfer grant.** This mirrors the trade-offer rule in
   `COMMUNE_TRADE_PLAN.md` §5.2, applied at chapter-offer time instead of per-spell-offer
   time. The point is to close off unbounded re-lending chains: a master can't launder a
   spell they themselves only hold on loan into a "new" grant to someone else, which would
   make the original owner's expiry assumptions unreliable.
   - This is a **new** gate, distinct from `localIdentityMayUse` — that check is
     deliberately permissive (it allows a loaned-in spell to enter your own chapter for
     personal casting) and is the wrong function to reuse here.
   - **Exception: Basic spells pass regardless of `ownerPubkeyHex`** (`isBasicSpell`,
     `lib/spells/basic_spells.dart`). Their grids ship in every client and need no grant at
     all. They must be *skipped* when emitting permissions — `SpellPermission.createAndSign`
     throws if the signer isn't the owner, and a Basic spell in the master's chapter
     generally isn't owner-matched.

### 2.2 Relationship shape (new this revision, from Soren)

4. **A master may have unlimited apprentices. An apprentice has exactly one master, and an
   apprentice may not take on apprentices of their own.** Both restrictions are
   **client-local** — there is no server and no global view, so a modified client can lie.
   Enforce them honestly in the local UI/model and document the limit; do not invent
   cryptographic machinery that can't actually work without a coordinator.
   - Note the one structurally-enforced piece that falls out for free: because §2.1.3
     requires native ownership, an apprentice *cannot* re-lend their master's chapter to a
     third party even with a modified client — the grants they hold name a foreign owner,
     and a peer verifying them will reject.
5. **One apprenticeship per (master, apprentice) pair.** A second offer from the same
   master to the same apprentice is a **renewal**, not a new record (§5.4).

### 2.3 The clock

6. **Renewal is the loan expiry.** Every grant in an apprenticeship bundle carries
   `expiresAt = now + 30 days` (`kApprenticeshipTermDays`). Renewal means the master
   **re-signs the whole bundle in a fresh in-person LAN session**, re-snapshotting the
   chapter as it stands at that moment. There is no second clock and no new enforcement
   path: lapse falls out of the existing signed-`expiresAt` check in
   `localIdentityMayUse` for free. The cost — the pair must meet in person monthly — is
   accepted and is thematically correct.
7. **The chapter is a snapshot at grant time, not a live view.** If the master edits the
   chapter afterwards, the apprentice's set is unchanged until the next renewal, which
   re-snapshots (adding new entries, dropping removed ones).

### 2.4 Ending the apprenticeship

An apprenticeship ends in exactly one of four ways:

8. **Lapse.** The 30-day grants expire and are not renewed. No protocol action, no
   notification — the spells simply stop passing `localIdentityMayUse`.
9. **Abandonment.** The apprentice chooses to walk away. Purely local: delete the loan
   permissions, the grid-withheld assets, and the cloned chapter. No notification to the
   master (there is no channel); the master learns of it at the next lapse or meeting.
10. **Bequeathed graduation.** The master decides the apprentice is ready. The chapter's
    spells convert to **perpetual transfer grants with their grids revealed** — the trade
    system's `SpellGrantKind.transfer` model verbatim (`COMMUNE_TRADE_PLAN.md` §4.3). The
    apprentice may later re-inscribe to naturalize ownership.
11. **Graduation battle.** The master challenges; the two duel; the winner takes the
    stakes (§7).

### 2.5 Graduation battle terms

12. **Stakes are drawn from the master's sightings only.** The master picks the apprentice
    spells they want from their own `SightingAsset` records for that apprentice
    (`lib/spells/sighting_asset.dart`, `docs/SIGHTINGS_PLAN.md`) — spells actually observed
    cast in a real duel. This is the design doc's secrecy game intact: conceal your best
    discoveries, but spells you never cast can't win you the graduation battle. The
    apprentice must accept the proposed stakes before the duel is on.
13. **Every settlement is a copy; nobody loses their own copy.** Winning stakes means
    receiving a perpetual grant + grid, exactly like a trade transfer. The loser keeps
    their file. This is the only enforceable model (we cannot make a peer delete a file),
    and it is what the codebase already does everywhere else. The wager costs **secrecy**,
    not access — your best rune is now in your master's hands. Say that plainly in the UI;
    do not imply confiscation.
14. **The apprentice sets the terms, which means the apprentice hosts.** Per
    `runewright_design_v3_0.md` §"Graduation Battle Terms Are the Apprentice's to Set", the
    apprentice chooses grid size, mode toggles, and timing. That maps exactly onto the
    existing lobby: the host authors `MatchConfig` (`battle_lobby_screen.dart`
    `_hostConfig`). So the graduation duel is launched with the **apprentice as host, master
    as guest**. No new config-authority mechanism is needed.
15. **Either outcome ends the apprenticeship.** Apprentice wins → chapter converts to
    perpetual transfers (as in a bequest), apprenticeship closed as `graduated`. Master wins
    → master receives the staked spells as perpetual transfers, the apprentice's chapter
    loans are deleted, apprenticeship closed as `graduatedByLoss`.

---

## 3. Build order

Four phases. **Phase A is a prerequisite** and is worth its own commit — it fills a real
gap in the battle system that nothing else has needed yet.

| Phase | What | Gate |
|---|---|---|
| **A** | Match end + signed outcome (§4) — **DONE 2026-07-29** | `flutter test`; a two-device duel that actually *ends* |
| **B** | Apprenticeship model, protocol, offer/accept/renew (§5, §6) — **DONE 2026-07-30** | `flutter test`; `flutter run -d linux` walkthrough |
| **C** | Graduation: bequest + battle pact + settlement (§7) — **DONE 2026-07-30** | `flutter test`; two-device graduation |
| **D** | UI polish + library/chapter labelling (§8) | visual pass |

---

## 4. Phase A — match end and the signed outcome — **DONE 2026-07-29**

Built as planned, with one deliberate simplification over the design below (kept here so
the reasoning isn't re-litigated): **DONE**. `TurnLoop.runTurn` used to return a
`WinCheckResult?` (`lib/battle/engine/turn_loop.dart`) that `battle_screen.dart` discarded,
and `BattleSession.sendMatchEnd` had no callers. Both are now wired end-to-end —
`lib/battle/models/match_outcome.dart`, `BattleSession.exchangeMatchOutcome`
(`battle_wire.dart`'s `matchResultSig(0x42)`), and `battle_screen.dart`'s `_handleMatchEnd`
+ `_MatchEndOverlay`. Tests: `test/battle/models/match_outcome_test.dart`,
`test/battle/networking/match_outcome_exchange_test.dart`,
`test/battle/engine/turn_loop_win_condition_test.dart`. Full `flutter test` (792 tests) and
`flutter analyze` both green.

### 4.1 `lib/battle/models/match_outcome.dart`

```dart
class MatchOutcome {
  final String matchIdHex;        // from runDuelSetup — neither side controls it
  final String victorPubkeyHex;   // circuit-level Poseidon2 owner pubkey
  final String loserPubkeyHex;
  final String finalStateHashHex;
  final String pactIdHex;         // 'none' for an ordinary duel; §7.2 for graduation
  final int endedAtTurn;          // BattleState.turnNumber, NOT a wall-clock timestamp
}
```

**Deviation from the original draft of this section:** it originally spec'd a `DateTime
endedAt` requiring a host-proposes/guest-adopts handshake so both sides' signed bytes would
match. Building it, `endedAtTurn: int` (`state.turnNumber` when `checkWinCondition()` fired)
is strictly better: it's already a value the per-turn state-hash lockstep
(`BattleSession.exchangeStateHash`) guarantees is byte-identical on both devices, so *every*
field of `MatchOutcome` is now independently derivable — no round trip needed to agree on
anything before signing. This turned `exchangeMatchOutcome` into a single simultaneous
exchange, the same shape as every other per-turn exchange in `battle_session.dart`, rather
than a special-cased host-first one. If you're reading this while building Phase B/C: there
is no host/guest asymmetry anywhere in the match-outcome path, on purpose.

Canonical signed message, null-byte delimited, hex lowercased — same discipline as
`SpellPermission._buildMessage`:

```
utf8("RUNEWRIGHT_MATCH_OUTCOME_V1\x00")
|| utf8(matchIdHex)        || 0x00
|| utf8(victorPubkeyHex)   || 0x00
|| utf8(loserPubkeyHex)    || 0x00
|| utf8(finalStateHashHex) || 0x00
|| utf8(pactIdHex)         || 0x00
|| utf8(endedAtTurn.toString())
```

`SignedMatchOutcome { MatchOutcome outcome; String signerPubkeyHex; String rawPubkeyBase64; String signatureBase64; }`
— `isSignatureValid()` mirrors `SpellPermission.isSignatureValid`: verify the raw key binds
to `signerPubkeyHex` via `Identity.ownerPubkeyMatches`, then verify Ed25519.

`MatchOutcomeRecord { MatchOutcome outcome; SignedMatchOutcome mine; SignedMatchOutcome theirs; }`
persists to `<docs>/outcomes/<matchIdHex>.json`, file-per-record like every other asset.
`isFullyValid()` checks both signatures verify, both signers are named parties in `outcome`,
and the two signers are *different* parties (two copies of one side's signature must never
count as agreement). **This record is the portable, durable artifact** — §7.4 settlement
consumes it, and a future ELO/match-history feature gets it for free.

`MatchOutcome.sameFieldsAs(other)` is the field-equality check a caller runs before trusting
a peer's returned outcome — hex fields compared case-insensitively, everything else exactly.

### 4.2 `BattleSession.exchangeMatchOutcome`

One new `BattleMsgType`: **`matchResultSig(0x42)`** (0x41 `matchEnd` is the last one used;
0x43–0x4F stay free).

```dart
Future<SignedMatchOutcome> exchangeMatchOutcome(SignedMatchOutcome mine);
```

Symmetric, like `exchangeStateHash` — both sides send and await simultaneously (see §4.1's
deviation note for why no host-first ordering is needed). The method itself is a pure
transport: it does not validate what comes back. The caller (`battle_screen.dart`'s
`_handleMatchEnd`) **rejects unless all of**:

- `MatchOutcome.sameFieldsAs` — every field of the peer's outcome equals mine;
- the peer's raw pubkey/signer hex match `widget.peerRawPubkey` /
  `widget.peerOwnerPubkeyHex` — the identity **already authenticated** by
  `exchangeIdentityAuth` at duel setup (`docs/BATTLE_AUTH_PLAN.md` §3), never a fresh claim
  accepted here;
- `MatchOutcomeRecord.isFullyValid()` on the combined pair.

Any mismatch → no record is written, and the overlay shows *"Not settled: ‹reason›"*
without disputing the LOCAL win/loss verdict — this device's own `TurnLoop` is still
authoritative for what this device displays; unsettled only means nobody else can yet prove
it (see `_MatchEndSummary`'s doc comment in `battle_screen.dart`). **Never settle stakes on
a one-sided signature.**

Scoped to real 1v1 duels only: solo/practice sessions and a draw (`winningTeamId == null`)
both skip signing entirely (nothing to settle, or no single victor to sign over); a battle
with more than two avatars also skips signing, since "the loser" isn't a single well-defined
party yet — team battles aren't a graduation-duel shape this plan covers.

### 4.3 Wiring the end of the match — as built

`_submitTurn` captures `runTurn`'s return and sets `_matchEnded = true` synchronously (in
the same `setState` that already resets turn-submission state) the instant `win.isOver` —
this is what blocks a further `_submitTurn` call, before the async settlement work below
even starts. `_handleMatchEnd(win)` then runs unawaited: it derives the local verdict from
`win.winningTeamId` + `widget.state.avatars` (no network needed for this part — every
device's own `TurnLoop` already agrees, via lockstep, on who won), and for a real 1v1 duel
additionally signs, exchanges, and validates the `MatchOutcome` per §4.2. Either way it ends
by populating `_matchEndSummary`, which `build()` renders as a full-screen
`_MatchEndOverlay` (victory/defeat/draw + settlement status + a Leave Battle button) stacked
over the existing battlefield UI.

**`sendMatchEnd`/`matchEnd (0x41)` was NOT called from this path.** It's the older,
unauthenticated advisory message (a bare `{winningTeamId, finalStateHash}` JSON blob, no
signature) and now has no callers — `matchResultSig (0x42)`'s signed, mutually-validated
exchange fully supersedes what it was for. Deleting `sendMatchEnd`/`matchEnd` outright is a
reasonable follow-up if nothing else claims it, but wasn't done here to keep Phase A's diff
additive only.

**Deferred, not built: forfeit as an outcome source.** The original draft of this section
called for treating an incoming `forfeit (0x40)` frame as "victor = the non-forfeiter."
Investigating it turned up that nothing in the codebase listens for that frame today —
`sendForfeit` is called by the side that *detects* a protocol violation, but the receiving
side never subscribes to it, so a forfeit currently only ever surfaces as the honest side's
own `StateError` (the existing "Turn error: …" snackbar in `_submitTurn`'s catch block).
Wiring real forfeit-as-outcome handling is a separate, decently-sized piece of plumbing
(subscribing to `BattleMsgType.forfeit` outside the turn-submission flow, plus deciding what
UI a "your opponent's client just violated the protocol" event gets) that doesn't naturally
fit the mutual-signature model anyway — a forfeiting/cheating peer is exactly the peer who
won't cooperate with counter-signing. Left as a named follow-up rather than silently
dropped; a graduation battle's counterweight for this gap is already covered by §7.4's "a
disconnect settles nothing" rule, which a forfeit is a special case of.

### 4.4 Phase A tests

- `test/battle/models/match_outcome_test.dart` — tampering any field (`victorPubkeyHex`,
  `pactIdHex`, `endedAtTurn`) after signing invalidates the signature; a presented rawPubkey
  that doesn't hash to the claimed signer is rejected; `MatchOutcomeRecord.isFullyValid`
  rejects a signer not named in the outcome and rejects two copies of one side's signature;
  JSON round-trips including `save()`/`loadByMatchId()`.
- `test/battle/networking/match_outcome_exchange_test.dart` — over `InMemoryTransport` with
  two ephemeral identities: both sides receive exactly what the other sent and the resulting
  record validates; a dishonest peer's outcome (different victor) still carries a valid
  signature over *its own* claim, but fails `MatchOutcome.sameFieldsAs` — the field-agreement
  check, not signature validity, is what actually stops it (matching how the real call site
  in `_handleMatchEnd` gates on `sameFieldsAs` before ever checking signatures).
- `test/battle/engine/turn_loop_win_condition_test.dart` (new file, not an extension of an
  existing one) — `runTurn` returns `isOver: true` with the correct `winningTeamId` once one
  side has 0 hp, and returns `null` while both sides are alive. Uses the existing
  `turn_session_pair.dart` fixture (two independently-driven `TurnLoop`s, real lockstep, no
  network I/O) so the assertion is on genuine two-client agreement, not a single loop's
  self-consistent view.

---

## 5. Phase B — the apprenticeship model

New directory `lib/apprentice/`.

### 5.1 `lib/apprentice/apprenticeship.dart` (new)

```dart
const int kApprenticeshipTermDays = 30;

enum ApprenticeSide { master, apprentice }   // which side of it THIS device is
enum ApprenticeshipStatus { active, abandoned, graduated, graduatedByLoss }

class ApprenticeshipRecord {
  final String id;
  final ApprenticeSide side;
  final String masterPubkeyHex;
  final String apprenticePubkeyHex;

  final String chapterName;            // display, from the master's chapter
  final String sourceChapterId;        // master side: the chapter lent
  final String? localChapterId;        // apprentice side: the cloned ChapterAsset

  final List<String> grantedCommitments;  // the snapshot (distinct commitments)
  final List<String> permissionIds;       // apprentice side: files to delete on abandon
  final List<String> receivedSpellIds;    // apprentice side: the grid-withheld assets

  final DateTime startedAt;
  final DateTime lastRenewedAt;
  final DateTime expiresAt;            // == every grant's expiresAt
  final ApprenticeshipStatus status;
  final DateTime? closedAt;
}
```

- **Derived, not stored:** `bool get isLapsed => status == active && !DateTime.now().toUtc().isBefore(expiresAt);`
  and `int get daysRemaining`. Lapse must be a live clock read, never a persisted flag —
  same reasoning as `SpellPermission.isExpired`.
- Persist to `<docs>/apprenticeships/<id>.json`; `save()` / `delete()` / `loadAll()` /
  `loadById` exactly mirroring `SpellPermission`'s block. Do not invent a new persistence
  style.
- Statics for the §2.2 constraints:
  - `Future<ApprenticeshipRecord?> activeMastership()` — my one active record where
    `side == apprentice`. Non-null blocks *both* accepting a second master and offering an
    apprenticeship of my own.
  - `Future<List<ApprenticeshipRecord>> apprentices()` — records where `side == master`.
  - `Future<ApprenticeshipRecord?> forPeer(String peerPubkeyHex)` — how renewal is detected.

### 5.2 Chapter eligibility — `lib/spells/spell_authorization.dart`

Add (do not modify the two existing functions):

```dart
class ChapterEligibility {
  final bool eligible;
  final List<String> reasons;   // human-readable, one per failing entry
}

Future<ChapterEligibility> chapterEligibleForApprenticeLoan({
  required ChapterAsset chapter,
  required List<SpellAsset> localSpells,
  required Identity master,
});
```

For each `ChapterEntry`: resolve the `SpellAsset` by `spellId` (missing → ineligible,
"spell no longer in library"); pass if `isBasicSpell(spell)`; otherwise require
`_hexEq(spell.ownerPubkeyHex, await master.ownerPubkeyHex())` (fail → "'<name>' is held on
loan, not owned"). An **empty chapter is ineligible** ("nothing to teach").

Call it in the picker *and* re-check immediately before signing — same
belt-and-braces the trade offer filter uses.

### 5.3 Wire — `lib/apprentice/apprentice_wire.dart` (new)

Copy `trade_wire.dart`'s shape (`ApprenticeFrame` / `ApprenticeFrameReader` over
`lib/protocol/wire.dart`'s `Frame`/`FrameReader`). Type bytes in **`0x70–0x7F`** — distinct
from proof `0x01–0x07`, battle `0x10–0x4F`, trade `0x50–0x5F`, sync-art `0x60–0x6F`:

| byte | message | payload |
|---|---|---|
| `0x70` | `apprHello` | `lengthPrefixedConcat([sessionId(16), rawPubkey(32)])` |
| `0x71` | `apprHelloAck` | raw pubkey (32) |
| `0x72` | `chapterOffer` | JSON: chapter name, `isRenewal`, `termDays`, manifest (§5.5) |
| `0x73` | `offerAccept` | empty |
| `0x74` | `offerDecline` | UTF-8 reason |
| `0x75` | `chapterBundle` | JSON: grants + grid-withheld assets + chapter structure |
| `0x76` | `bundleAck` | empty |
| `0x77` | `graduationOffer` | JSON: pact proposal (§7.2) |
| `0x78` | `graduationAccept` | JSON: apprentice's counter-signature on the pact |
| `0x79` | `graduationDecline` | UTF-8 reason |
| `0x7A` | `settlementBundle` | JSON: signed outcomes + perpetual grants + full assets |
| `0x7B` | `settlementAck` | empty |

Discovery: **`_rw-appr._tcp`** as `kRunewrightApprenticeServiceType` in
`lib/protocol/lan_discovery.dart`, alongside the three existing constants. (Label is
`rw-appr`, 7 chars — well inside the `nsd` 15-char RFC 6763 cap that bit us with
`runewright-trade`.) Then `lib/apprentice/apprentice_discovery.dart` as a thin copy of
`lib/trade/trade_discovery.dart` — that class hardcodes its own service type, but the
`advertiseDuelHost` / `discoverDuelHosts` helpers it calls are already parameterized, so the
copy is ~90 lines and changes one constant.

**Carry over both of its hard-won behaviours:** the advertise step must **soft-fail**
(`nsd` has no Linux desktop backend at all), and the pairing screen must offer **manual IP
entry** dialing `LanSocketTransport.connectTo` directly. A missing manual-IP fallback was
one of the three real two-device trade bugs fixed on 2026-07-28.

### 5.4 Session — `lib/apprentice/apprentice_session.dart` (new)

Model it on `TradeSession` (`lib/trade/trade_session.dart`), and **carry over its
`_nextFrame` buffering verbatim.**

> ⚠️ **This is not optional and not an optimization.** `ApprenticeFrameReader.frames` is a
> broadcast stream, which drops events delivered while nothing is subscribed. Every step of
> this protocol is gated on a human pressing a button, so the two peers are essentially
> never subscribed at the same instant — whoever acts first has their frame silently
> discarded and the other side hangs forever. This was a real two-device bug on 2026-07-28
> (`docs/M4_findings.md`); `sync_art_session.dart` reportedly still has the unfixed version.
> Read `trade_session.dart:120–183` before writing a line of this class, and copy the
> permanent-subscription + `_buffered` list pattern.

Methods:

- `static Future<ApprenticeSession> initiate(Transport, Identity)` / `accept(...)` —
  identical to `TradeSession`'s handshake, deriving `peerOwnerPubkeyHex` via
  `Identity.ownerPubkeyHexFromRawKey`.
- `Future<ChapterOfferManifest> sendChapterOffer(...)` / `Future<ChapterOfferManifest> awaitChapterOffer()`
- `Future<bool> awaitAcceptance()` / `Future<void> respondToOffer(bool accept, {String? reason})`
- `Future<ApprenticeGrantResult> sendChapterBundle({required Identity master, required ChapterAsset chapter, required List<SpellAsset> spells})`
- `Future<ApprenticeReceiveResult> receiveChapterBundleAndSave({required Identity me, required String masterPubkeyHex})`

### 5.5 What crosses the wire

**`chapterOffer` manifest** — a *preview*, no grids and no grants: chapter display name,
entry count, artifact loadout summary, and per-spell `{ name, formula, manaCost, t, tier,
isSummon, commitmentHex }`. Enough for the apprentice to decide; nothing they could use
without the grants.

**`chapterBundle`** — for each **distinct non-Basic commitment** in the chapter:

```json
{ "permission": <SpellPermission.toJson(), kind:"loan", expiresAt: now+30d>,
  "asset":      <SpellAsset.withGridWithheld().toJson()> }
```

plus the chapter structure so the clone reproduces the master's build:

```json
{ "chapterName": "...",
  "entries":   [ { "commitmentHex": "...", "summonPersonality": "..." }, ... ],
  "artifacts": [ <ArtifactEntry.toJson()>, ... ] }
```

> Note the entry list keys on `commitmentHex`, **not** `spellId` — local spell ids differ
> per device. The receiver maps commitment → its own freshly-saved local asset id.
> **Entries are 1:1 with the master's chapter and may repeat a commitment** (Basic spells
> can appear more than once). Grants and assets dedupe on commitment; entries do not.

Basic-spell entries carry a commitment the receiver already has locally — resolve those
against the receiver's own Basic assets, and emit no grant.

### 5.6 Receiving: building the clone

Mirror `TradeSession._receiveAndSaveBundle`'s validation exactly (grantee names me, owner
matches the connected peer, `isCurrentlyUsable()`, non-empty grid on a loan is a hard
reject), then additionally:

1. Save each grid-withheld `SpellAsset` under a fresh local id (`appr-<micros>-<incoming.id>`).
2. Save each `SpellPermission`.
3. Build a new `ChapterAsset` — fresh id, name `"<chapterName> (Apprentice)"`, entries
   remapped commitment → local spell id preserving `summonPersonality`, artifacts copied
   verbatim (counter-charm `targetCommitmentHex` copies through unchanged and stays valid,
   since commitments are device-independent). Save it.
4. Write the `ApprenticeshipRecord`.

**Partial failure:** if any grant fails validation, save nothing, write no record, and
report which items failed. A half-built chapter is worse than no chapter — this differs
deliberately from trade's per-item best-effort, because the chapter is the unit here.

### 5.7 Renewal

The master re-runs the offer flow with the same apprentice. Both sides detect the existing
record via `ApprenticeshipRecord.forPeer(...)` and set `isRenewal: true`. On the apprentice
side, `receiveChapterBundleAndSave` then:

- deletes the **superseded** `SpellPermission` files (by `permissionIds`) and any
  grid-withheld assets whose commitments are no longer in the snapshot;
- saves the new grants and any newly-added spells;
- **updates the cloned `ChapterAsset` in place, keeping its id** — so the apprentice's
  active-chapter selection (`_active.txt`) survives the renewal;
- updates `lastRenewedAt` / `expiresAt` on the record.

A renewal of a **lapsed** record is allowed and simply revives it. A renewal of a
`graduated`/`abandoned` record is not — that's a fresh apprenticeship, requiring a fresh
record (and, on the apprentice's side, the §2.2 one-master check again).

### 5.8 Abandonment

Apprentice-side, local only: delete the permissions, the grid-withheld assets, and the
cloned chapter; if that chapter was active, clear `saveActiveChapterId(null)`; set
`status: abandoned`, `closedAt: now`. Keep the record (it's lineage). Confirm behind a
dialog that says plainly that the master is not notified and the spells go immediately.

### 5.9 Phase B tests

- `test/apprentice/apprenticeship_test.dart` — record JSON round-trip; `isLapsed` boundary
  (active at `expiresAt - 1s`, lapsed at `expiresAt`); `activeMastership()` returns only the
  active apprentice-side record; `forPeer` finds the renewal target.
- `test/spells/chapter_eligibility_test.dart` — all-owned chapter passes; a loaned-in spell
  fails with a useful reason; a **Basic spell does not fail**; a missing spell fails; an
  empty chapter fails.
- `test/apprentice/apprentice_session_test.dart` — full round trip over `InMemoryTransport`
  with two ephemeral identities: offer → accept → bundle → clone. Assert the apprentice's
  cloned chapter has the same entry count and artifact list; assert **every received asset
  has `gridWithheld == true` and an empty `initialGrid`**; assert a bundle whose loan entry
  carries a grid is rejected wholesale; assert a grant naming a third party is rejected
  wholesale (nothing saved, no record).
- `test/apprentice/apprentice_renewal_test.dart` — second bundle supersedes the first:
  old permission files gone, chapter id unchanged, `expiresAt` pushed out, a spell removed
  from the master's chapter loses its grant and its entry.
- `test/apprentice/apprentice_wire_test.dart` — `ApprenticeMsgType` bytes don't overlap
  `MsgType` / `BattleMsgType` / `TradeMsgType` / `SyncArtMsgType`; frames round-trip.
- Basic spells emit no permission (assert grant count < entry count for a mixed chapter).

---

## 6. Phase B UI

### 6.1 `lib/ui/commune_screen.dart`

Enable the existing disabled button: `CREATE AN APPRENTICESHIP` → `ApprenticeshipScreen`.
Update the file header comment (it currently says the button is deliberately disabled).

### 6.2 `lib/ui/apprenticeship_screen.dart` (new) — the hub

Manuscript theme, `IlluminatedButton`s, mirroring `commune_screen.dart`. Three regions:

- **Your master** — chapter name, **days remaining** (prominent; the whole clock model is
  this number), and actions: `RENEW` (opens the pairing flow as the *apprentice* side),
  `REQUEST GRADUATION` (§7), `ABANDON APPRENTICESHIP`. Lapsed shows "Your studies have
  lapsed" with `RENEW` / `CLEAR`.
- **Your apprentices** — list, each with days remaining and: `RENEW`, `BEQUEATH GRADUATION`,
  `CHALLENGE TO A GRADUATION BATTLE`.
- **`OFFER AN APPRENTICESHIP`** — disabled with the explanation *"An apprentice may not
  take an apprentice. Graduate first."* when `activeMastership() != null`.

### 6.3 `lib/ui/apprentice_offer_screen.dart` (new)

The pairing + offer state machine, mirroring `trade_screen.dart` (host/join/discover/connect
→ offer → confirm → exchange → result) on `_rw-appr._tcp`. Master side adds a chapter
picker where **ineligible chapters are shown greyed with their reason** (§5.2) rather than
hidden — the reason is the teaching moment. Apprentice side shows the manifest preview and,
critically, a plain-language note: *"These runes are lent, not given. You will be able to
cast them but never to see how they were drawn, and they fade in 30 days unless your master
renews them."*

### Phase B status — **DONE 2026-07-30**

Built as planned: `lib/apprentice/{apprenticeship,apprentice_wire,apprentice_session,
apprentice_discovery}.dart`, `chapterEligibleForApprenticeLoan` in `spell_authorization.dart`
(plus a `ChapterAsset.delete()` addition it needed), `lib/ui/{apprenticeship_screen,
apprentice_offer_screen}.dart`, and `commune_screen.dart` wired live. 35 new tests across
`test/apprentice/` + `test/spells/chapter_eligibility_test.dart`; full suite is 827 passing
(up from Phase A's 792); `flutter analyze` clean. `flutter run -d linux` boots cleanly with
no compile or runtime errors — **not** independently click-driven end-to-end, though: this
sandbox has no `xdotool`/`scrot`, a limitation already documented elsewhere in this repo
(`docs/M4_findings.md`), so "boots clean" is what CLAUDE.md's verification hierarchy allows
here without real hardware.

**One finding worth carrying into Phase C/D:** `ApprenticeshipScreen`'s `FutureBuilder`
(loading `ApprenticeshipRecord.loadAll()` via real `dart:io` File/Directory calls) **never
resolves under `WidgetTester.pump()`/`pumpAndSettle()`**, and wrapping the wait in
`tester.runAsync()` does not fix it either (the `Future` is already constructed against the
fake test zone by the time `initState` runs, before `runAsync` gets a chance to bridge
anything). This is the same characteristic already noted for `LibraryScreen`
(`test/ui/commune_trade_navigation_test.dart`'s header comment) — apparently a general
property of this pattern (FutureBuilder + real file I/O) under this project's widget-test
harness, not something specific to either screen. **Any new FutureBuilder-backed screen
Phase C/D adds (a graduation-pact list, a settlement queue, etc.) will hit the same wall.**
The workaround used here: widget-test only that navigation *reaches* the screen (a static
AppBar title, present before the FutureBuilder resolves) via a couple of bounded,
duration-stepped `pump()` calls to carry the push-route transition — never `pumpAndSettle()`
on a screen with one of these. Full behavioral coverage of the loaded state lives in the
plain (non-widget) tests against the data layer instead
(`test/apprentice/apprenticeship_test.dart`, `apprentice_session_test.dart`). If this is
worth actually fixing (e.g. some FutureBuilder-friendly fake-clock shim), that's a
testing-infrastructure task orthogonal to this feature — flagged, not fixed, here.

Not built in Phase B (out of scope, per §3's table — Phase C's job): graduation buttons on
the hub (`REQUEST GRADUATION`/`BEQUEATH`/`CHALLENGE`) are visible but disabled, matching the
app's own established convention for a shipped-but-incomplete skeleton.

---

## 7. Phase C — graduation

### 7.1 Bequeathed graduation (the simple path)

Master taps `BEQUEATH GRADUATION` on an apprentice; both pair over `_rw-appr._tcp`. The
master sends a `settlementBundle` (`0x7A`) with, for each **non-Basic** commitment in the
original snapshot:

```json
{ "permission": <SpellPermission, kind:"transfer", expiresAt:null,
                 provenance: [...existing chain..., master@now]>,
  "asset":      <full SpellAsset.toJson() — GRID INCLUDED> }
```

The apprentice validates each grant as in §5.6 (minus the withheld-grid check, which is
inverted here: a transfer **must** carry a non-empty grid), saves them, **deletes the
superseded loan permissions**, updates the cloned chapter's entries to point at the newly
saved full assets, and closes the record as `graduated`. Master-side, the record closes
too.

Warning dialog on the master, reusing trade's transfer-warning language: this reveals the
grid states permanently and cannot be undone.

### 7.2 The graduation pact

A battle for stakes needs both signatures **before** the duel, or the loser can simply deny
the terms afterwards.

```dart
class GraduationPact {
  final String pactIdHex;             // 16 random bytes, master-generated
  final String masterPubkeyHex;
  final String apprenticePubkeyHex;
  final String chapterName;
  final List<String> chapterCommitments;  // what the apprentice wins
  final List<String> stakeCommitments;    // what the master wins
  final DateTime agreedAt;
}
```

Canonical message `RUNEWRIGHT_GRADUATION_PACT_V1\x00 || pactIdHex || 0 || masterPubkeyHex ||
0 || apprenticePubkeyHex || 0 || <chapterCommitments joined by 0x1F> || 0 ||
<stakeCommitments joined by 0x1F> || 0 || agreedAt.iso8601` — sorted lowercase hex in both
lists so the two sides build identical bytes. `SignedPact` holds both signatures; persist to
`<docs>/pacts/<pactIdHex>.json`.

Flow: master proposes (`graduationOffer 0x77`) with their signature; apprentice reviews,
signs, returns (`graduationAccept 0x78`) or declines with a reason (`0x79`). Both persist
the fully-signed pact. An empty `stakeCommitments` list is legal — a graduation battle with
no wager.

**Stakes picker (master side):** `SightingAsset.loadAll()` filtered to
`opponentPubkeyHex == apprenticePubkeyHex`, showing name / formula / mana cost / times seen.
Nothing else is selectable — if the master has never dueled this apprentice, the list is
empty and they can only offer an unwagered battle. That is the intended pressure.

**Apprentice-side validation on receipt:** every `stakeCommitments` entry must resolve to a
**natively owned** local `SpellAsset` (`ownerPubkeyHex == mine`, and not Basic). If one
doesn't — a spell they've since deleted, or one they only hold on loan — decline
automatically with that reason. Do not let a pact promise something that cannot be
delivered.

### 7.3 Fighting it

The apprenticeship screen hands the pact to the lobby, with the **apprentice as host** and
the master as guest (§2.5.14). The pact's `pactIdHex` is threaded through `runDuelSetup`
into `TurnLoop`/`BattleScreen` so it lands in the signed `MatchOutcome` (§4.1). Everything
else about the duel is a normal duel.

> Minimal plumbing: an optional `String? pactIdHex` on `BattleLobbyScreen` and
> `BattleScreen`, defaulting null. Do not build a general "match metadata" system.

### 7.4 Settling

Both sides return to the apprenticeship screen, which now shows *"A graduation awaits
settlement"* for any pact with a matching `MatchOutcomeRecord`. They re-pair over
`_rw-appr._tcp` and exchange `settlementBundle`.

Each side, before emitting or accepting anything, checks: the outcome record's `pactIdHex`
matches the pact; **both** signatures on the outcome verify against the pact's two pubkeys;
the victor is one of the two. Then the **loser** emits perpetual transfer grants + full
assets for their side of the stakes:

- **Apprentice won** → master emits the chapter's spells (identical to §7.1); apprentice
  closes the record `graduated`.
- **Master won** → apprentice emits the staked spells; apprentice **deletes the chapter
  loan** (permissions, withheld assets, cloned chapter — the §5.8 teardown) and closes the
  record `graduatedByLoss`. Per §2.5.13 the apprentice **keeps** their staked spells; the
  master gains copies.

Non-atomic, exactly like trade (`COMMUNE_TRADE_PLAN.md` §2.4): a loser who never settles
can't be forced to. The winner holds a fully-signed pact + outcome, and the settlement
prompt persists until it's honoured. Say that honestly in the result screen; don't build
escrow.

### 7.5 Phase C tests

- `test/apprentice/graduation_pact_test.dart` — canonical message stability across list
  order; tampering `stakeCommitments` invalidates both signatures; a pact naming a stake the
  apprentice doesn't natively own is rejected.
- `test/apprentice/graduation_bequest_test.dart` — bequest converts loans to transfers, the
  grid arrives, loan permissions are deleted, the record closes `graduated`.
- `test/apprentice/graduation_settlement_test.dart` — apprentice-win settles the chapter;
  master-win settles the stakes AND tears down the loan; **the apprentice's staked
  `SpellAsset` files still exist afterwards** (§2.5.13); a settlement whose outcome
  `pactIdHex` doesn't match is rejected; a settlement carrying only *one* valid outcome
  signature is rejected.
- `test/apprentice/apprentice_constraints_test.dart` — a device with an active mastership
  refuses to offer an apprenticeship and refuses a second master.

### Phase C status — **DONE 2026-07-30**

Built as planned, with a few real findings worth carrying forward:

- `lib/apprentice/graduation_pact.dart` (new) — `GraduationPact`, `SignedGraduationPact`,
  `unresolvableStakeCommitments`, and `resolveGraduationSettlement` (the pre-settlement trust
  gate §7.4 describes — pactIdHex match, both pact signatures valid, both outcome signatures
  valid, victor is one of the two named parties).
- `ApprenticeSession` gained: `sendGraduationOffer`/`awaitGraduationOffer`/
  `respondToGraduationOffer`/`awaitGraduationResponse` (§7.2), `sendTransferBundle`/
  `receiveTransferBundleAndSave` (the shared low-level transfer primitive §7.1/§7.4 both sit
  on), and the four orchestration wrappers `sendBequest`/`receiveBequestAndSave`/
  `sendStakeSettlement`/`receiveStakeSettlementAndSave`.
- `lib/ui/graduation_screen.dart` (new) — one screen, one `GraduationMode` enum (`bequest`,
  `challenge`, `respond`, `receiveGrant`, `settle`), not four separate near-duplicate pairing
  screens — the pairing boilerplate is identical across all four flows.
- `pactIdHex` threaded as a single optional field on `BattleLobbyScreen` and `BattleScreen`,
  landing in the signed `MatchOutcome` at match end — exactly the "minimal plumbing" this
  section called for. `runDuelSetup` was NOT touched — the pact is already fully signed
  before the duel starts, so the duel handshake itself has no need to know about it.
- Hub screen (`apprenticeship_screen.dart`) gained a "RECEIVE GRANT" action (apprentice
  side) and an "Awaiting settlement" section that scans `SignedGraduationPact.loadAll()` for
  ones with a matching, still-unapplied `MatchOutcomeRecord`.
- 26 new tests across `graduation_pact_test.dart`, `graduation_bequest_test.dart`,
  `graduation_settlement_test.dart`, `apprentice_constraints_test.dart`, plus 6 added to
  `apprenticeship_test.dart`. Combined with Phase B, `test/apprentice/` is 75 tests. Full
  suite: 849 tests, 5 failing — all five are `inscribe_test.dart`/`gate_runner_test.dart`/
  `turn_loop_proof_verification_test.dart` timing out on the real network SRS download
  (`reqwest::Error { kind: Decode, source: TimedOut }`), confirmed pre-existing (last touched
  by an unrelated commit before this session) and unrelated to anything in this phase — no
  file this phase touched is anywhere near the FFI/proving path. `flutter analyze` clean
  (same pre-existing, unrelated warnings only). `flutter run -d linux` boots cleanly.

**Two real bugs found and fixed while building this, not just findings — both fixed in
place, not deferred:**

1. **`ApprenticeshipRecord.forPeer` needed to be side-aware.** The original (Phase B)
   signature matched a peer against EITHER `masterPubkeyHex` OR `apprenticePubkeyHex` with no
   way to say which one the caller meant. This is invisible on a real single-identity device
   (a device only ever holds one relevant record per peer), but it produced a genuine wrong-
   record bug the moment a device held both a master-side AND an apprentice-side record
   touching the same peer pubkey — which the graduation-settlement test setup (both
   directions of a relationship exercised in one test run) hit immediately. Fixed by adding a
   required `side` parameter; every call site (5 in `apprentice_session.dart`, 1 in
   `apprentice_offer_screen.dart`) now says which side it means. See
   `apprenticeship_test.dart`'s "forPeer never crosses sides" test for the exact shape.
2. **`receiveBequestAndSave`'s original draft gated the wire handshake on local bookkeeping**
   (checked `ApprenticeshipRecord.forPeer` before ever reading the incoming frame), which
   deadlocks the sender — `sendTransferBundle`'s `await ackFuture` never resolves if the
   receiver never gets far enough to send `settlementAck`. Same class of bug the Phase B
   `_nextFrame` buffering fix was protecting against, in a new spot: **the frame must always
   be read and acked before any local validation that could early-return.** Fixed by
   reordering; `receiveTransferBundleAndSave` (which does the actual read+ack) now always
   runs first, unconditionally, in every caller.

**One deliberate reversion, not a bug:** an early draft added a protocol-level guard to
`sendChapterOffer` refusing to offer while the caller's own device has an active mastership
(the master-side half of §2.2 decision 4). Removed it — `ApprenticeshipRecord.activeMastership()`
reads ALL locally-saved records with no identity scoping (correct for the real
one-identity-per-device model this whole app assumes), so the guard is only meaningfully
testable with per-identity-isolated storage, which this test harness's shared-fake-
filesystem convention (both simulated devices in one directory, used throughout
`test/apprentice/` and every other protocol test in this codebase) doesn't have. It tripped
a false positive on the FIRST unrelated renewal test that exercised it. The constraint is
enforced at the UI layer instead (`apprenticeship_screen.dart` disables "Offer an
Apprenticeship" while `activeMastership() != null`) — matching how §6.2 itself originally
framed this as a UI-layer disablement, not a protocol one.

**`REQUEST GRADUATION` stays disabled, on purpose.** §7 never gives the apprentice a wire
message to initiate a pact with — only the master ever calls `sendGraduationOffer`; the
apprentice can only review and accept/decline (`respondToGraduationOffer`) or receive a
unilateral bequest. There is nothing this button could actually send. Said so directly in
the UI (a caption, not silence) rather than pretending otherwise.

---

## 8. Phase D — library and chapter surfaces

- **Library** — label apprentice-loaned spells distinctly from trade loans ("Lent by your
  master · 12 days remain"). The data is already there (`gridWithheld` + the permission's
  `expiresAt`); this is presentation only.
- **Chapter editor** — the cloned chapter should be visibly marked as the apprenticeship
  chapter and its entries not freely deletable-and-recoverable (deleting an entry loses it
  until renewal). Simplest honest answer: mark it read-only and say why.
- **Days-remaining nag** — surface the apprenticeship expiry on the main menu or the
  chapter picker when < 7 days remain. This is the only reminder that exists; there is no
  push channel.

---

## 9. Invariant checklist (must hold at PR time)

- [ ] **No grid state is ever placed in a loan bundle** — only in a bequest/settlement
      transfer bundle. Both the sender's redaction and the receiver's rejection are tested.
- [ ] `expiresAt` is inside the signed grant message (already true — don't regress it);
      editing it on disk breaks verification.
- [ ] Only **natively-owned** chapters are offerable; Basic spells are exempt from the
      ownership check *and* excluded from grant emission.
- [ ] Stakes come from sightings only; every stake resolves to a natively-owned spell on
      the apprentice's device before the pact is signed.
- [ ] Ownership moves **only** on two verified signatures — a `MatchOutcomeRecord` with both
      sides' signatures over identical bytes, matching a `SignedPact` with both sides'
      signatures. A disconnect settles nothing.
- [ ] `ApprenticeSession` copies `TradeSession`'s `_nextFrame` buffering (§5.4). No
      human-gated await reads a bare broadcast stream.
- [ ] `ApprenticeMsgType` bytes (0x70–0x7F) collide with nothing; `matchResultSig` is 0x42.
- [ ] No Poseidon2 in Dart, no commitment folding, no in-circuit signatures — this feature
      is pure off-circuit Ed25519 over the existing FFI Poseidon2 seam (CLAUDE.md
      invariants 1, 2, 5).
- [ ] `RULESET_VERSION` **not** bumped — nothing here is a consensus-visible CA rule change.
- [ ] Full `flutter test` green; `flutter run -d linux` walkthrough of Commune →
      Apprenticeship in every state (no master, active, lapsed, pending settlement).

## 10. Explicitly deferred (name in the PR, don't build)

- **Two-device hardware validation** of the whole flow — offer, renew, graduation battle,
  settlement. This needs real hardware and is the honest gate for "done"
  (CLAUDE.md: hardware run > golden corpus > integration test). Land the code, name the gate.
- ELO / match history on top of `MatchOutcomeRecord` — the record is designed to carry it,
  but nothing consumes it yet.
- Independently-verified provenance chains (still recorded, not re-verified per hop —
  inherited from `COMMUNE_TRADE_PLAN.md` §9).
- Lineage/heirloom visualization ("this rune passed through three schools").
- Any notification of abandonment or lapse to the other party — there is no channel, and
  inventing one means inventing a server.
- Fixing `sync_art_session.dart`'s outstanding broadcast-stream drop bug. Same root cause as
  §5.4's warning, but a separate concern; don't bundle it.
