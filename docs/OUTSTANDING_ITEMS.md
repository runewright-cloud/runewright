# Outstanding Items — Follow-ups from LAN Battle Wire-Up (Stage 1 + 2)

*Written 2026-07-20. Quick-reference checklist, not a plan — things flagged
during `LAN_BATTLE_WIREUP_PLAN.md`'s Stage 1/2 implementation that still
need attention. Full context for each lives in `docs/M4_findings.md`'s
2026-07-19/20 entries and `LAN_BATTLE_WIREUP_PLAN.md` itself.*

---

## 1. Two-device LAN run reaching Stage 2 (proof verification) — the real gate

**Status: not done.** No second physical device in this dev environment, so
this has only ever been validated headless (paired `BattleSession` over
`InMemoryTransport`, with a real FFI-generated proof in
`turn_loop_proof_verification_test.dart`).

What's been confirmed on real hardware so far: the Stage 1 two-device
attempt (Pixel 6 hosting + Linux desktop joining) — which surfaced and fixed
the `nsd`-has-no-Linux-backend gap (manual IP fallback). That attempt never
reached Stage 2's proof-verification path (Stage 2 landed after).

**To close this out:** `flutter run` on two real devices (or one device +
`-d linux` desktop as the second), same network. Host from one, join from
the other (use the manual IP field if mDNS doesn't find the peer). Cast at
least one real spell and confirm:
- `BattleScreen`'s async `TurnLoop` init (VK asset + circuit bytecode +
  `initSrsCached`) completes without hanging or erroring on both devices.
- The peer's cast round-trips through `_verifyPeerSpellCast` successfully
  (or, for a deliberately-forbidden spell, forfeits correctly).
- No `_loopReady`-gate error screen appears unless something's genuinely
  wrong.

Per CLAUDE.md's verification hierarchy (hardware run > everything else) —
M4.6's two-device gate already found one real bug no headless test caught,
so don't skip this once a second device is available.

---

## 2. Pre-existing test bug: date-rollover fixture in `spell_authorization_test.dart`

**File:** `test/spells/spell_authorization_test.dart` — test `castingPlayerMayUse
a caster holding a valid loan grant naming them may cast` (~line 189).

**Bug:** hardcodes `expiresAt: DateTime.utc(2026, 7, 20)` and calls
`castingPlayerMayUse` with no explicit `now:` override, so it silently
depended on wall-clock time staying *before* that date. The calendar rolled
to exactly 2026-07-20, so the grant now reads as already-expired at
midnight and the test fails.

**Fix:** push `expiresAt` further into the future (e.g. `DateTime.utc(2030,
1, 1)`), or pass an explicit `now:` pinned to a fixed instant — matching
the *other* tests in the same file that already do this correctly (the
ones passing `now: expiresAt.subtract(...)` etc., around lines 76/98/119/137).

Not caused by the LAN wire-up work — pre-existing, just happened to start
failing during this session because the date caught up to it.

---

## 3. Environmental: SRS-download flakiness under load (not a code bug)

**Files affected:** `test/spells/inscribe_test.dart`, `test/ui/gate_runner_test.dart`,
and now `test/battle/engine/turn_loop_proof_verification_test.dart` — all
three do a real on-device proof, needing the SRS (structured reference
string) either cached on disk or downloaded fresh.

**Observed:** intermittent `SRS download failed` /
`reqwest::Error { kind: Decode, source: TimedOut }` when running the *full*
test suite (several ~2GB-RSS provers competing for network/CPU at once).
All three pass reliably when run in isolation.

**Action:** none needed unless this becomes a recurring CI problem — then
consider running these three files with reduced concurrency or in their own
CI job/stage, separate from the rest of the suite.

---

## 5. `SpellDraw`'s full draw order is computable early (peek-ahead gap)

**Status (2026-07-22): `SpellDraw`'s own draw model fixed and tested; still not
wired into `BattleState`.** See `docs/SPELL_DRAW_ENTROPY_PLAN.md`. The rewrite
below (§"Fix, when it's tackled") is done: `SpellDraw` is now
entropy-source-agnostic draw-on-demand (`SpellDraw.opening` +
`useSpell(handIndex, drawRng)`), with a negative/peek-ahead vector in
`test/battle/engine/spell_draw_test.dart`. **What's still open:** the actual
`BattleState`/`TurnLoop` wiring (`battle_state.dart:131` TODO) — swapping
live "available spells" from whole-chapter to hand/deck touches cast
validation (currently checks `peerBookRoot` chapter membership, not hand
membership), the Divination Water-flavor reveal (currently reveals the whole
chapter — see `spell_effect.dart:527`), and the two `FuelTransmutation`
wither/reactivate stubs (`effect_applicator.dart:392,411`). Those
call-site semantics are drafted in `docs/SPELL_DRAW_WIRING_PLAN.md`
(2026-07-23). Enforcement approach decided: hand-membership is enforced via a
one-time chapter-creation sortedness proof + publicly-computed draw positions
(full enforcement, full deck privacy, zero in-match proving — §7), so the
peek-ahead *and* out-of-hand-cast holes both close. The sortedness-circuit spike
is **done — GO** (`docs/SORTEDNESS_CIRCUIT_SPIKE.md §11`: cost lands in CA
tier-12's proving bucket for chapters ≤48 spells). Open: the Dart wiring itself
(plan §§3–9), productionizing the measurement circuit + its VK/handshake wiring,
and sequencing (plan §11).

**File:** `lib/battle/engine/spell_draw.dart`.

**Found while wiring Watery Scrying Pool's spell-list reveal** (Water-flavor
Divination — see `TurnLoop._exchangeSpellRevealOpenings`). Not part of that
work; noted and deliberately left alone per Soren's call.

**Bug:** `SpellDraw`'s own doc comment states the design directly — the
*entire* future draw order (not just the current hand) is fixed once, at
construction, from a single `jointEntropy` value; refilling the hand on
spell use just walks forward through that pre-shuffled list, consuming no
new randomness. A player always knows their own chapter, so the moment
`jointEntropy` is revealed, their client can compute their whole remaining
deck order immediately — killing the turn-by-turn "what will I draw next"
uncertainty a real shuffled deck would have.

**Currently low-stakes:** `SpellDraw` has zero call sites outside its own
file and tests — it is not wired into `BattleState` or `TurnLoop` at all.
Today's live "available spells" is simply a player's whole chapter (no
hand/deck split), so this gap has no live effect yet. It only matters once
someone wires `SpellDraw` in for real (the `battle_state.dart:131` TODO).

**Fix, when it's tackled:** make each future draw depend on that turn's
freshly-revealed per-turn entropy (`TurnLoop._resolveEntropy`, already
produced every turn for other purposes — see `turn_loop.dart:2435`) rather
than fixing the whole sequence at construction. Bounds peek-ahead to "one
draw ahead," same as a real shuffled deck. Larger change — touches
determinism/replay and the audit story `SpellDraw`'s header comment
describes.

**Plan:** `docs/SPELL_DRAW_ENTROPY_PLAN.md` (2026-07-22). Since `SpellDraw`
has no consumer today, this is folded into the `SpellDraw`-into-`BattleState`
wiring task (`battle_state.dart:131`) — build hand/deck with per-turn-entropy
draws from the start rather than shipping fixed-order and retrofitting the fix
later. See §9 of the plan for the two calls needed before coding.

---

## 6. Worth double-checking (unconfirmed, lower priority): ruleset_version cross-check

While wiring Stage 2's proof verification, I noticed `_verifyPeerSpellCast`
(`turn_loop.dart`) never explicitly compares the proof's certified
`outputs.rulesetVersion` against `MatchConfig.rulesetVersion` — VK selection
is keyed only by **tier** (`ca_v2_4_tier{n}.vk`), not by ruleset version.

I did *not* chase this down far enough to know whether it's a real gap
(could a proof from an old `RULESET_VERSION` verify against a current VK if
the circuit bytecode changed without the VK filename changing?) or a
non-issue (if the VK is fully regenerated/renamed on every `RULESET_VERSION`
bump, an old proof simply wouldn't verify at all, making an explicit
cross-check redundant). Given CLAUDE.md's note that `RULESET_VERSION` is
"now 3" while `MatchConfig.rulesetVersion` defaults to `2`, this seems worth
a deliberate look before the next ruleset bump — not urgent, but flagging so
it doesn't get lost.

---

## 7. Sync Art's `_receiveAndSaveBundle` has no size cap on received art

**Status: FIXED 2026-08-06** (pre-playtest sweep — see `M4_findings.md` M4.13). Capped on
the base64 string length *before* `base64Decode`, mirroring `kSpellArtMaxImportBytes`;
negative test `an oversized art payload is refused before it is decoded` in
`test/trade/sync_art_session_test.dart`. Original report below.

**File:** `lib/trade/sync_art_session.dart`.

Found while wiring the built-in spell art pack through Sync Art
(`docs/SPELL_ART_PACK_PLAN.md` Phase C/D). `_receiveAndSaveBundle` decodes
whatever `fullBase64`/`thumbBase64` a peer sends and, after the SHA-256
integrity check against the claimed `artHash` passes, saves it straight to
`SpellArtStore` — with no upper bound on decoded byte size. Contrast
`spell_art_import.dart`'s local-import path, which enforces
`kSpellArtMaxImportBytes` (8 MB) *before* decoding untrusted bytes.

A peer that controls both the art bytes and the `artHash` it claims for them
(trivial — it's their own hash to compute) can pass the integrity check with
an arbitrarily large payload, so this isn't a spoofing risk, just an
unbounded-allocation one: a malicious or buggy peer could send a very large
`fullBase64` string and force this device to base64-decode and persist it.

**Not touched here** — pre-existing, orthogonal to the art-pack work that
surfaced it, and Sync Art already requires a completed pairing handshake
(not reachable by an arbitrary unpaired peer). Worth a size-cap check
mirroring `kSpellArtMaxImportBytes` before decoding, next time this file is
touched for other reasons.
