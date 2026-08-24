# M4 engine-v4 two-device validation gate — evidence log

## Baseline (verified 2026-08-23 ~05:58)
- Commit on BOTH devices: `8ee51fc7e555bd96f56e104241607b3617ac8938`
  ("fix(battle): Mystery cannot resurrect a mana-fizzled cast (M4.21)")
- Working tree: CLEAN (`git status --porcelain` empty)
- kBattleEngineVersion == 4   (lib/battle/engine/battle_engine_version.dart:165)
- kRulesetVersion == 3        (lib/spells/inscribe.dart:41)
- kBattleProtocolVersion == 5 (lib/battle/networking/match_discovery.dart:68)
- Provenance: HEAD reached 8ee51fc at 04:03:28. Pixel APK installed 04:29:24;
  Linux bundle built 04:33:39, `flutter run -d linux` synced 05:03. Both AFTER
  the commit, tree clean throughout -> identical source on both peers.
  Both are debug/JIT builds (code pushed from host at run start).

## Devices
- Device A (host): Pixel 6 `<device serial redacted>`, 192.0.2.10, identity "Pixel"
  - display density overridden 420 -> 380 (workaround for HOST SETTINGS overflow bug)
- Device B (join): Linux desktop, 192.0.2.11, DISPLAY=:1, window id 58720263
  - transport: manual IP (nsd has no Linux backend)

## Chapter under test ("Gate", both peers)
- Basic Firebolt   ♦13
- Basic Earthworks ♦13
- Basic Windhound  ♦83 (summon)

## Scenario results
| # | Scenario | A result | B result | state-hash gate | PASS/FAIL |
|---|----------|----------|----------|-----------------|-----------|
| 1 | Ordinary spell exchange | | | | NOT RUN |
| 2 | Counter charm | | | | NOT RUN |
| 3 | Spell components / recall | | | | NOT RUN |
| 4 | Summon replication | | | | NOT RUN |
| 5 | Potent summon (M4.17) | | | | NOT RUN |
| 6 | Forced cast (M4.20) | | | | NOT RUN |
| 7 | Phase-5 settlement (M4.10b) | | | | NOT RUN |
| 8 | Mystery (M4.21) | | | | NOT RUN |
| 9 | Free movement / ordering (M4.18) | | | | NOT RUN |
| 10 | Disconnect behavior (M4.13) | | | | NOT RUN |
| NC | Engine-version mismatch negative control | | | | NOT RUN |

## Notes / friction
- HOST SETTINGS overflows viewport at stock density 420 on Pixel 6
  ("BOTTOM OVERFLOWED BY 21 PIXELS"), clipping the HOST button. Genuine bug.
- "Add to Chapter" silently targets the ACTIVE chapter, not the one just created.
- Summon add pops a personality dialog; dismissing it silently cancels the add.

## PAIRING — SUCCESS (2026-08-23 06:08)
Pixel hosted at 192.0.2.10:44191; Linux joined via manual IP.
Both devices entered the battle screen, TurnLoop init completed on both
(no _loopReady error screen). Mirrored state: HP 24 / MP 50/100 both sides,
Deck: 2, hand shows "Basic Windhound". Opponent named correctly on each
("Pixel" on Linux, "a" on Pixel).

### Setup friction encountered (not product defects)
1. Linux peer reported "THIS DEVICE IS NOT READY TO DUEL" despite an SRS
   existing at ~/.local/share/com.runeduel.rune_duel/. Cause: the app was
   launched from VS Code's snap-confined terminal, so path_provider resolved
   the application-support dir to ~/snap/code/254/.local/share/... where no
   SRS existed. "PREPARE THIS DEVICE" fetched it (134,217,940 bytes, 06:03:50).
   Environment artifact of launch context, NOT a code bug.
2. X keyboard layout is `us,us` variant `dvorak,` (group 0 = Dvorak) but the
   Flutter Linux embedder interprets keys as US, so xdotool's ':' arrived as
   'S'. Worked around by `setxkbmap us` for the typing then restoring
   `-layout us,us -variant dvorak,`. Layout was restored.
3. Ubuntu dock overlaps the app window at X<~100; window moved to X=120,Y=40.

### Observation affecting scenario planning
Hand size is 1 (bookmarkCount+1, no bookmarks). Opening hand on BOTH peers is
Basic Windhound ♦83, but MP is 50 — i.e. the only card in hand is unaffordable
at turn 1. Firebolt/Earthworks (♦13) are in the 2-card deck, not the hand.

### Turn 0 -> Turn 1 (Meditate both, Linux moves 1 tile, Pixel stands fast)
- A (Pixel): chose Meditate, stood fast. After: HP 24, MP 75/100.
- B (Linux): chose Meditate, stepped 1 tile north. After: HP 24, MP 75/100.
- Both devices render the SAME absolute board (not per-player mirrored):
  purple="a"(Linux) bottom, blue="Pixel" top. Both show purple advanced one
  tile, blue unmoved.
- Meditate payout 50 -> 75 (+25) agreed on both.
- State-hash gate: PASSED (no forfeit; both advanced to TURN 1 / MAIN in step).

## *** GATE FAILURE — Turn 2 double summon -> state hash mismatch on turn 3 ***
Time: 2026-08-23 06:25. Commit 8ee51fc on both devices.

### What was done
- Turn 0: both Meditate (MP 50->75). Linux stepped 1 tile; Pixel stood fast.
- Turn 1: both Meditate (MP 75->100). Both stood fast.
- Turn 2: BOTH cast Basic Windhound (♦83, summon, enhancement = NONE),
  each targeting a tile adjacent to itself. Both then stood fast in MOVE.
- Settlement produced the error on BOTH devices simultaneously.

### Observed
Both devices showed the lockstep-broken screen:
  "This duel broke lockstep and cannot continue — the two devices no longer
   agree on the battlefield:
   Bad state: state hash mismatch on turn 3:"
  Linux: local=a19f0fa5896b1332735f58efcb7bfa1b3b1c44d46dd861d2b862aa1bcbcb2ea5
         peer =296d7f2ebb956c68f92541ecaa2215e4caedf08247f64a1a99bad4f4e8722d70
  Pixel: local=296d7f2ebb956c68f92541ecaa2215e4caedf08247f64a1a99bad4f4e8722d70
         peer =a19f0fa5896b1332735f58efcb7bfa1b3b1c44d46dd861d2b862aa1bcbcb2ea5
Exactly mirrored -> genuine state divergence, NOT one-sided transport corruption.

### Ruled OUT
- Transport: frames flowed both ways all match; the hash exchange itself
  completed (each side received the other's hash).
- Verification: Linux logged "Proof verified successfully (mem: 3357.79 MiB)"
  for the peer's cast — _verifyPeerSpellCast succeeded.
- Presentation: the mismatch is over state.toCanonicalBytes(), consensus state.
- Summon personality: both chapters carry summonPersonality "aggressive".
- Hand/deck ordering: hand and deck are NOT part of toCanonicalBytes, so the
  differing chapter entry order between devices cannot affect the hash.

### Classification
DETERMINISTIC STATE divergence at Phase-5 settlement of a summon cast.
Candidate fields (all hashed): Minion.id (minted as
'<playerId>_sm_<rng.nextInt(1<<30)>' — deterministic_resolution.dart:3223, so
sensitive to rng draw COUNT/ORDER), avatar mana, or avatar chain state.

### Automation repro attempts (both PASS — did not reproduce)
New temporary file test/battle/engine/simultaneous_summon_desync_repro_test.dart
  1. Both players summon same turn, 3-earth plain creature -> PASS
  2. Both players summon same turn, real 12-element Windhound formula -> PASS
Compares minion ids AND full toCanonicalBytes across the paired TurnLoops.
=> The offline TurnSessionPair harness does not model whatever differs on
   hardware (candidates not modelled: wild magic leyline seed "universal",
   real joint entropy, real certified proof outputs vs fixture SpellAssets,
   prior meditate/move history).

### Pre-existing coverage gap this exposes
peer_summon_replication_test.dart (the M4.16 regression test) has only ONE side
summon, and asserts only `minions.hasLength(1)` on each device — it never
compares toCanonicalBytes. A summon that replicates as a creature but with a
divergent id/stat would pass that test and still desync a real duel.

## BISECT (second + third paired matches)

### Bisect A — single summoner (match 2)
Both meditate x2 to MP 100 (2 clean turns, no desync). Then LINUX ONLY cast
Basic Windhound (♦83, NONE enhancement); Pixel meditated.
RESULT: **DESYNC AGAIN** — "state hash mismatch on turn 3"
  Linux local=0f40fa829bd587aad7d3d53c9fa29488ed5a87f2ee01311cc201a264b48f4e2f
        peer =106353bd837b599e34db1236feeb726985d9f74671116b5454c2211c031a9cce
=> Simultaneity is NOT the trigger. A single summon desyncs.
=> Also explains why the offline "both summon" repro passes: when both sides
   summon, each device runs one LOCAL summon and one PEER summon, so any
   local-path vs peer-path asymmetry cancels out of the hash. With one
   summoner it cannot cancel.

### Bisect B — ordinary (non-summon) cast, match 3  ** THE BASELINE **
Linux joined with a new 2-spell chapter "GateCheap" (Basic Firebolt ♦13 +
Basic Earthworks ♦13) so the 1-card hand could not draw the summon.
Turn 0: LINUX cast Basic Earthworks (♦13, Earthen Barrier, NONE enhancement)
targeting an adjacent tile; Pixel meditated.
RESULT: **PASS — no desync.**
  - Linux MP 50 -> 37 (paid exactly 13).
  - Pixel MP 50 -> 75 (meditate +25).
  - Pixel's view of opponent "a" shows MP 37 — agrees with Linux's own value.
  - Linux gained chain status "Earth x1 (-10%)"; barrier rendered on both.
  - Hand refilled (Basic Firebolt ♦13), Deck: 0.
  - Both advanced to TURN 1 / MAIN in step. State-hash gate PASSED.

### CONCLUSION OF BISECT
Ordinary spell casts settle correctly over the real transport and hold
lockstep. **SUMMON casts break lockstep on the turn they are cast, every
time (2/2 summon attempts across two independent matches).**
Proof verification is NOT the problem — the peer proof verified successfully
in every case. The divergence is in deterministic resolution of a summon.

This is the same failure MODE that M4.16 fixed
(peer_summon_replication_test.dart's header: "Summons were unusable in any
real two-device duel"). That test asserts only `minions.hasLength(1)` on each
device and never compares toCanonicalBytes — so a creature that replicates
but with any divergent hashed field (id / stats / abilities / affinity /
personality / sizeBonus / position) passes it and still desyncs a real duel.

## FINAL SCENARIO TABLE
Device A = Pixel 6 (host), Device B = Linux desktop (join).
Both on commit 8ee51fc7e555bd96f56e104241607b3617ac8938, engine v4 / ruleset 3
/ protocol 5, clean tree, debug JIT builds from identical source.

| #  | Scenario | Result |
|----|----------|--------|
| 1  | Ordinary spell exchange | PARTIAL PASS — one-sided real cast (Earthworks ♦13) settled correctly on both devices, mana + chain + barrier agreed, lockstep held. Two-sided simultaneous ordinary exchange NOT run (1-card hand could not deal both peers an affordable non-summon). |
| 2  | Counter charm | NOT RUN — gate stopped; also needs counterCharm ARTIFACTS equipped (none on either chapter). |
| 3  | Spell components / recall | NOT RUN — gate stopped; needs vocal/somatic enabled in host settings. |
| 4  | Summon replication | **FAIL** — state hash mismatch on the summon turn, 2/2 attempts, two independent matches. |
| 5  | Potent summon (M4.17) | NOT RUN / BLOCKED — impossible with this content: POTENCY requires a 'fire' supremeTag and the only summon available (Windhound) is ['air','earth'] so POTENCY is greyed out. Candidate "Doggy" ♦70 (fire) exists but is not in any chapter; "Doggo" ♦139 exceeds the 100 mana cap. |
| 6  | Forced cast (M4.20) | NOT RUN — gate stopped. |
| 7  | Phase-5 settlement / SlowTile (M4.10b) | NOT RUN / BLOCKED — SlowTile needs (water, tileModification) = formula [water, earth, water] ("Watery Terrain Sculpting"). No such spell exists in the library; it would have to be inscribed first. |
| 8  | Mystery (M4.21) | NOT RUN — gate stopped. Reachable: MYSTERY enhancement is live for Earthworks ♦13 and Windhound ♦83 (both have the 'earth' supremeTag). |
| 9  | Free movement / ordering (M4.18) | PARTIAL PASS — a 1-tile step by B while A stood fast replicated identically on both devices; not the full M4.18 ordering case. |
| 10 | Disconnect behavior (M4.13) | NOT RUN — gate stopped. |
| NC | Engine v4 vs v3 mismatch | NOT RUN — would require rebuilding one peer at engine v3; deferred once the gate had already failed. |

## VERDICT: **REJECTED**

First defect deserving investigation: summon casts break lockstep on the turn
they are cast. Proof verification succeeds; ordinary casts are fine; the
divergence is in deterministic resolution of the summon, in a field that
toCanonicalBytes hashes (Minion id / position / stats / abilities / affinity /
personality / sizeBonus, or the caster's mana / chain state).

Strong lead: Minion.id is minted at deterministic_resolution.dart:3223 as
  '<playerId>_sm_<rng.nextInt(1 << 30).toRadixString(36)>'
so it is sensitive to how many times the shared HashRng has been drawn. If the
local-cast path and the peer-verified-cast path consume the rng a different
number of times, the two devices mint different ids and the hash diverges —
consistent with "cancels out when both sides summon, shows when only one does".

## REPO / ENVIRONMENT STATUS
- HEAD 8ee51fc, unchanged. No tracked file modified. No gameplay, protocol,
  fixture or semantic change made.
- ONE new untracked diagnostic file (uncommitted, safe to delete):
    test/battle/engine/simultaneous_summon_desync_repro_test.dart
  3 offline repro variants; all PASS, i.e. none reproduce the hardware bug.
- Outside the repo:
  - Created /home/soren/Documents/chapters/1787480000000000.json ("GateCheap",
    Firebolt + Earthworks) on the LINUX peer, to force a non-summon draw.
  - Linux SRS fetched to ~/snap/code/254/.local/share/com.runeduel.rune_duel/
    (134,217,940 bytes) — the app was launched from a snap-confined shell.
  - Pixel display density remains overridden at 380 (from the prior session).
    NOT restored on purpose: at stock 420 the HOST SETTINGS screen overflows
    and the HOST button is unreachable, so restoring it would block hosting.
  - X keyboard layout was temporarily set to `us` for text entry and RESTORED
    to `us,us` variant `dvorak,` each time.
