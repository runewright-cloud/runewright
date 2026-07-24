# Commune / Trade — Implementation Plan

*Target implementer: Sonnet. Author: planning pass, 2026-07-18, on `feature/practice-mode`.*
*Scope decisions ratified by Soren (see "Ratified decisions" below).*

---

## 1. Goal

Add a **Commune** entry to the main menu holding three options — **Trade**, **Create an
Apprenticeship**, **Sync Art**. Only **Trade** is functional this milestone; the other two
ship as visible-but-disabled buttons (like the existing `About` / `Settings`).

**Trade** lets two players, paired peer-to-peer over LAN, swap access to spells. An offer
from each side is an arbitrary set (including empty) of items, each item being either:

- **Loan** — a signed grant authorizing the peer to cast the spell in battle "as if their
  own" (run the ZK proof + resolve the effect). The **initial grid state is never sent**,
  so the loanee cannot view the runes. Every loan is **day-limited** (an integer number of
  days); the grant carries an expiry the holder's client enforces against its own clock.
  Loaned spells **cannot be re-traded**.
- **Transfer** — full rights in perpetuity, **including the initial grid state**. Gated
  behind an explicit warning dialog. Carries a provenance chain and a never-expiring,
  non-revocable grant. The recipient may optionally re-inscribe the grid under their own
  key later to fully naturalize ownership.

## 2. Ratified decisions (do not re-litigate)

1. **Battle integration is OUT of scope this milestone.** Do **not** touch the battle
   protocol (`lib/battle/networking/*`, `battle_wire.dart`, book-commitment exchange).
   Loaned/transferred spells become usable by flowing through the **existing**
   `localIdentityMayUse` gate (chapter inclusion) and appearing in the Library. Opponent-
   side verification in battle (`castingPlayerMayUse` + permission exchange in
   `BattleSession`) is a **named follow-up**, not this PR. This keeps the change reviewable
   and the battle protocol untouched.
2. **Loans are day-limited only. No indefinite loans, no revocation subsystem.** This
   *overrides* the original verbal spec's "indefinite + revocation notice" idea — Soren
   chose the enforceable model: every loan carries an expiry, enforced client-side against
   the local clock. This matches `runewright_design_v3_0.md` §"Loan Expiry Without a
   Server". Drop the indefinite toggle and the revocation-notice message entirely.
3. **Transfer = grid + perpetual grant, re-inscribe optional.** The recipient receives the
   grid state + provenance + a never-expiring, non-revocable grant (castable immediately,
   like a permanent loan). They can **later** re-inscribe from Rune Craft to mint a proof
   under their own key (same commitment — grid-only commitment rule holds). Do **not**
   auto-re-inscribe on receipt (proving is 9–32 s and can't happen on the spot for tier-48).
4. **No escrow / no atomicity.** Per `runewright_design_v3_0.md` §"Spell Transfer": a trade
   is a mutual, non-atomic exchange. Nothing guarantees both sides deliver; the binding is
   social cost. Do **not** build a two-phase commit. Each side, on mutual confirm, simply
   transmits its promised grants. (A peer could confirm and then not send — surface that in
   the result summary, don't try to prevent it cryptographically.)

## 3. What already exists (reuse, don't rebuild)

- **`lib/spells/spell_permission.dart` — `SpellPermission`.** The loan primitive already
  exists: an owner-signed (Ed25519, off-circuit) grant at the **grid-commitment** level
  (`commitment = Poseidon2(packed_grid)`), embedding the owner's raw pubkey so a peer can
  bind it to the circuit-level `ownerPubkeyHex` via Poseidon2 and verify the signature with
  **no prior key exchange**. Persists to `<docs>/permissions/<id>.json`. Currently wired
  into **nothing**. **This is the spine of the whole feature.** It needs two additions
  (kind + expiry) — see §4.1.
- **`lib/spells/spell_authorization.dart`** — `localIdentityMayUse(spell, identity)` (the
  chapter-inclusion gate) and `castingPlayerMayUse(...)` (battle-time, unused). Extend the
  former for expiry (§4.2); leave the latter for the battle follow-up.
- **`lib/identity/identity.dart` — `Identity`.** `sign` / `verify` / `ownerPubkeyHex()` /
  `ownerPubkeyMatches(...)` / `publicKeyBytes`. Everything the trade handshake and grant
  signing/verification needs. Use `Identity.ephemeral()` in tests.
- **Transport stack** (reuse wholesale, parameterized for a new service type):
  - `lib/protocol/transport.dart` — the `Transport` seam.
  - `lib/protocol/lan_socket_transport.dart` — `LanSocketTransport` / `LanListener`.
  - `lib/protocol/lan_discovery.dart` — mDNS via `nsd`. **`advertiseDuelHost` /
    `discoverDuelHosts` hardcode `_runewright._tcp`** — parameterize the service type
    (default = battle's) so trade can advertise on a **distinct** `_runewright-trade._tcp`
    and not collide with battle discovery.
  - `lib/protocol/wire.dart` — `Frame` / `FrameReader` (`[1 type][4 BE len][payload]`),
    `lengthPrefixedConcat` / `lengthPrefixedSplit`. Reuse `FrameReader` as-is with a new
    message enum (below).
  - `lib/battle/networking/match_discovery.dart` — `LanMatchDiscovery` / `DiscoveredPeer`.
    Either generalize it to take a service type, or write a thin `LanTradeDiscovery`
    mirroring it. **Prefer parameterizing** over copy-paste.
- **UI patterns:** `lib/ui/menu_screen.dart` (`_MenuButton`), `lib/ui/battle_lobby_screen.dart`
  (the host/join/discover/connect state machine — mirror it for trade pairing),
  `lib/ui/library_screen.dart` (spell list + selection).

## 4. Data-model changes

### 4.1 `SpellPermission` → add `kind` + `expiresAt` + provenance (bump canonical message to V2)

Nothing has shipped and there are **no permission files on disk**, so bumping the signed
message's domain separator is free — do it cleanly, don't try to stay V1-compatible.

Add fields:
- `SpellGrantKind kind` — `enum SpellGrantKind { loan, transfer }`.
- `DateTime? expiresAt` — **required non-null for `loan`**, **must be null for `transfer`**
  (perpetual). Validate this invariant in `createAndSign`.
- `List<ProvenanceStep> provenance` — for `transfer` only; empty for loans. A
  `ProvenanceStep` is `{ String pubkeyHex, DateTime at }` recording custody (original
  creator first, then each transfer). Keep it minimal — a signed chain is a later
  enhancement; for now record the ordered pubkey list so heirloom lineage is *captured*
  even if not yet independently verifiable.

**Canonical signed message V2** (null-byte delimited, hex lowercased — extend the existing
`_buildMessage`):

```
utf8("RUNEWRIGHT_SPELL_GRANT_V2\x00")
|| utf8(kind.name) || 0x00
|| utf8(ownerPubkeyHex.lower) || 0x00
|| utf8(commitmentHex.lower) || 0x00
|| utf8(granteePubkeyHex.lower) || 0x00
|| utf8(expiresAt?.toUtc().toIso8601String() ?? "never")
```

`expiresAt` **must** be inside the signed message — otherwise a loanee could edit the JSON
and extend their own loan. (This is the whole point of the day-limited model.)

Add methods:
- `bool isExpired({DateTime? now})` — `kind == loan && now >= expiresAt` (default `now =
  DateTime.now().toUtc()`).
- `Future<bool> isCurrentlyUsable({DateTime? now})` — `!isExpired(now) &&
  await isSignatureValid()`.
- Extend `toJson`/`fromJson` for the new fields (default `kind: loan` absent → but there are
  no legacy files, so a hard requirement is fine; defaulting is only defensive).

### 4.2 `spell_authorization.dart` — honor expiry in `localIdentityMayUse`

Currently trusts stored permissions without checking expiry. Change the `perms.any(...)`
predicate to also require **not expired** (`!p.isExpired()`). Keep trusting the stored
signature (it was verified on receipt), but the **clock check must be live** every call so a
loan silently drops out of the usable set the day it lapses. Add a unit test for the
boundary (loan valid at `expiresAt - 1s`, unusable at `expiresAt`).

### 4.3 Received transfers — persisting a foreign-owned `SpellAsset`

A transfer delivers **both**:
1. The full `SpellAsset` JSON (includes `initialGrid` + `proofBytes`; `ownerPubkeyHex` is
   the **sender's**). Save it via `SpellAsset.save()` as-is. It is foreign-owned but now
   locally held. (Give it a fresh `id` on receipt to avoid collision; keep `commitmentHex`.)
2. A perpetual `SpellPermission(kind: transfer, granteePubkeyHex: me, expiresAt: null)` with
   the provenance chain. Save via `SpellPermission.save()`.

`localIdentityMayUse` then returns true for that spell (transfer grant, never expires), so it
is chapter-eligible and Library-visible immediately, **without** re-inscription.
Re-inscription (optional, later) is just: load `initialGrid` into Rune Craft → inscribe →
produces a **native** `SpellAsset` under the recipient's key with the same commitment.

> No `SpellAsset` schema change is strictly required — the sender's asset carries everything.
> Optionally add a nullable `receivedFrom`/`isForeign` marker for Library UI labeling; if you
> do, follow the existing additive-nullable-field pattern (see `artHash`/`artSource`).

## 5. Trade protocol (`lib/trade/`)

New directory `lib/trade/`. Non-atomic mutual exchange over one `Transport`.

### 5.1 Wire (`lib/trade/trade_wire.dart`)

Reuse `FrameReader` from `lib/protocol/wire.dart`. Define `enum TradeMsgType` with type bytes
in **`0x50–0x5F`** (distinct from proof-exchange `0x01–0x07` and battle `0x10–0x4F`):

- `tradeHello (0x50)` / `tradeHelloAck (0x51)` — handshake; payload = sender's raw 32-byte
  Ed25519 pubkey. Each side derives the peer's `ownerPubkeyHex` via
  `Identity.ownerPubkeyMatches`/Poseidon2 seam. Establish a local `tradeId` (16 random
  bytes, initiator-generated, never re-read from later messages — same discipline as
  `MatchSession.matchId`).
- `offer (0x52)` — JSON: the sender's list of `TradeItem` (see §5.2). Advisory/preview only.
- `confirm (0x53)` / `cancel (0x54)` — mutual agreement gate.
- `grantBundle (0x55)` — JSON array of `SpellPermission.toJson()` (loans + transfer grants)
  **plus** the `SpellAsset.toJson()` for each transfer item.
- `bundleAck (0x56)` — receipt acknowledgement (best-effort; no atomicity implied).

Payloads may be UTF-8 JSON here (unlike the battle wire's raw-binary preference) — trade is
low-frequency and the objects already have `toJson`. Length-prefix multi-field frames with
`lengthPrefixedConcat`.

### 5.2 Offer model (`lib/trade/trade_offer.dart`)

```
enum TradeMode { loan, transfer }
class TradeItem {
  final String spellId;          // local SpellAsset.id being offered
  final String commitmentHex;    // resolved for the grant
  final String spellName;        // display
  final TradeMode mode;
  final int? loanDays;           // required iff mode == loan; >= 1
}
class TradeOffer { final List<TradeItem> items; }   // may be empty
```

**Offer-eligibility filter (enforce in the picker AND re-check before signing):** only
**natively-owned** spells may be offered — `spell.ownerPubkeyHex == myOwnerPubkeyHex`. A spell
held via loan or transfer-grant (foreign `ownerPubkeyHex`) is **not** offerable. This is what
enforces both "loaned spells cannot be re-traded" and the design's deliberate asymmetry (no
re-loaning a transferred spell). A re-inscribed transfer *is* native and therefore offerable.

### 5.3 Session (`lib/trade/trade_session.dart`)

Mirror `MatchSession`'s shape (request/response over `FrameReader`, single buffered frame,
`tradeId` fixed at handshake). Roles are symmetric (both give and receive). Flow:

1. **Pair + handshake** — exchange raw pubkeys (`tradeHello`/`tradeHelloAck`), derive peer
   `ownerPubkeyHex`, fix `tradeId`.
2. **Exchange offers** (`offer`) — advisory preview so each UI can show "you give / you get".
3. **Confirm** (`confirm`, both sides) or **cancel** (`cancel`, either side).
4. **On mutual confirm, build + send `grantBundle`:** for each of *my* offered items, create
   and sign a `SpellPermission` (loan: `expiresAt = now + loanDays`; transfer: `expiresAt =
   null`, provenance = existing chain + me), and for transfers also include the `SpellAsset`
   JSON. Send the bundle.
5. **On receiving peer's `grantBundle`,** for each grant: verify
   `grant.granteePubkeyHex == myOwnerPubkeyHex` (it names me), verify
   `await grant.isCurrentlyUsable()` (signature + owner-binding + not-already-expired), then
   `save()`. For each accompanying transfer `SpellAsset`, assign a fresh id and `save()`.
   Reject (log + surface, skip that item) anything that fails a check. Send `bundleAck`.
6. **Result summary** — what was sent, what was received-and-saved, what failed/was skipped,
   and (honestly) that a confirmed peer is not *forced* to send.

**Testability:** the session must run over `InMemoryTransport` with two `Identity.ephemeral()`
peers, exactly like the `MatchSession` tests. No FFI needed except the Poseidon2 owner-binding
already used by `SpellPermission.isSignatureValid` (already covered in existing tests).

### 5.4 Discovery (`lib/trade/trade_discovery.dart` or param on `LanMatchDiscovery`)

Advertise/discover on **`_runewright-trade._tcp`** so trade peers and battle peers don't
cross-list. Prefer adding an optional `serviceType` parameter to `advertiseDuelHost` /
`discoverDuelHosts` (default `kRunewrightServiceType`) and to `LanMatchDiscovery`, over
copy-pasting the discovery class. Reuse `selectBestAddress` (Wi-Fi-Direct address filtering)
unchanged.

## 6. UI

### 6.1 Menu (`lib/ui/menu_screen.dart`)

Add a `Commune` `_MenuButton` (suggest between `Library` and `Practice`) → `CommuneScreen`.

### 6.2 `lib/ui/commune_screen.dart` (new)

Three `_MenuButton`-style buttons: **Trade** (→ `TradeScreen`), **Create an Apprenticeship**
(`onTap: null`, disabled), **Sync Art** (`onTap: null`, disabled). Match the manuscript theme
(`Color(0xFFF5F0E8)` bg, `Color(0xFF2C1810)` ink) used in `menu_screen.dart`. Factor
`_MenuButton` into a shared widget if convenient, or duplicate the small class.

### 6.3 `lib/ui/trade_screen.dart` (new) — state machine mirroring `battle_lobby_screen.dart`

States: `idle → hosting|joining → connecting → connected → buildingOffer → confirming →
exchanging → done` (+ `error`). Sub-steps:

- **Pairing:** host (advertise + `acceptOnce`) / join (discover list + `connect`). Reuse the
  lobby's structure and the parameterized trade discovery.
- **Offer builder:** list `SpellAsset.loadAll()` filtered to natively-owned (§5.2); per
  spell, pick **Loan** (+ a day-count field, integer ≥ 1) or **Transfer**. Selecting Transfer
  pops a **warning dialog**: "This gives {peer} permanent full rights to this magic,
  including the ability to see the grid state you used to create it. This cannot be undone."
  Require explicit confirm.
- **Confirm:** show both offers side by side ("You give … / You receive …"), Confirm / Cancel.
- **Result:** summary from §5.3 step 6.

### 6.4 Library (`lib/ui/library_screen.dart`)

Minimal: since `loadAll()` already lists everything, transferred spells appear once saved. If
you added the optional `isForeign`/`receivedFrom` marker (§4.3), label such cards ("Received"
/ provenance) and offer a **"Make it yours (re-inscribe)"** action that routes to Rune Craft
with `initialGrid` preloaded. If you skip the marker, at minimum confirm received transfers
render correctly and are addable to a chapter (they will pass `localIdentityMayUse`).

## 7. Tests (write alongside, run before commit)

- `test/spells/spell_permission_test.dart` (extend): V2 message includes `kind` + `expiresAt`;
  **tampering `expiresAt` in the JSON invalidates the signature**; `isExpired` boundary;
  loan-requires-expiry / transfer-requires-null invariant in `createAndSign`; provenance
  round-trips.
- `test/spells/spell_authorization_test.dart`: `localIdentityMayUse` accepts a valid unexpired
  loan, **rejects the same loan past `expiresAt`**, accepts a perpetual transfer grant.
- `test/trade/trade_session_test.dart`: full round-trip over `InMemoryTransport` w/ two
  ephemeral identities — offers exchanged, mutual confirm, both bundles saved; grantee-check
  rejects a grant naming someone else; a tampered/expired grant is skipped not saved; a
  transfer delivers the `SpellAsset` (grid present) + perpetual grant.
- `test/trade/trade_offer_test.dart`: eligibility filter excludes foreign-owned spells.
- `test/trade/trade_wire_test.dart`: `TradeMsgType` bytes don't overlap `MsgType` /
  `BattleMsgType`; frame round-trips.
- Verify with `flutter test` and a `flutter run -d linux` smoke of the menu → Commune → Trade
  pairing screens (real mDNS/two-device pairing is a follow-up, not gate-able on this dev box —
  see `lan_discovery.dart` header + M4 findings).

## 8. Invariant checklist (must hold at PR time)

- [ ] Grid state is **never** placed in a loan bundle — only in a **transfer** bundle.
- [ ] `expiresAt` is inside the signed message; editing it on disk breaks verification.
- [ ] Only natively-owned spells are offerable (loan re-trade / transfer re-loan both blocked).
- [ ] No `commitment` folding, no Poseidon2 in Dart, no in-circuit signatures — this feature is
      pure off-circuit Ed25519 + the existing FFI Poseidon2 seam (CLAUDE.md invariants 1, 2, 5).
- [ ] Battle protocol files untouched (`lib/battle/networking/*`, `battle_wire.dart`).
- [ ] Full `flutter test` green; new trade tests included.

## 9. Explicitly deferred (name them in the PR, don't build)

- Battle-time opponent verification of loans (`castingPlayerMayUse` + `SpellPermission`
  exchange in `BattleSession` + loaned commitments in the book commitment).
- Apprenticeship (graduation battles, lineage) and Sync Art — buttons only.
- Signed/verifiable provenance chain (this milestone records the pubkey lineage but does not
  independently verify each hop).
- Real two-device mDNS pairing validation (needs hardware; follow-up gate).
