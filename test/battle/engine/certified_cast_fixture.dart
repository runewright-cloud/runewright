// SPDX-License-Identifier: GPL-3.0-or-later
//
// certified_cast_fixture.dart — shared fixture for the tests that probe the
// certified-cast trust boundary: a spell whose PROOF and whose WIRE FIELDS
// disagree, so a test can tell which one resolution actually read.
//
// Nothing binds `SpellAsset.formula` to the proof — the commitment is
// grid-only (CLAUDE.md invariant 2) — so every non-proof field on a peer's
// SpellAsset is free text a modified client can write anything into. These
// builders make that concrete rather than hypothetical.
//
// Extracted alongside turn_session_pair.dart so the delayed-fire (B-1) and
// ruleset-epoch tests can share one fixture instead of each growing their own
// synthetic-proof builder.

import 'dart:typed_data';

import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/inscribe.dart'
    show kRulesetVersion, tierForSteps;
import 'package:rune_duel/spells/spell_asset.dart';

/// Dominance indices, CLAUDE.md: [0=neutral, 1=fire, 2=air, 3=water, 4=earth].
const kEarthDominance = 4;

const kSegmentCount = 3;
const kDotCount = 2;
const kStartMana = 500;

/// One complete formula, no residual.
const kActivations = 3;

/// Verification stub. Every test here is about what happens to a proof's
/// *contents* once it verifies, so the verification itself is not the subject.
Future<bool> alwaysOk(Uint8List vk, Uint8List proof) async => true;

/// The attack fixture: a spell whose PROOF attests three supreme **earth**
/// activations, but whose wire `formula` claims **fire**.
///
/// Everything a well-behaved client fills in honestly is filled in honestly
/// (tier, segment/dot counts, mana cost), so the only difference between this
/// and a legitimate spell is the field under test. A fixture that also lied
/// about its cost would fail for the wrong reason.
///
/// Earth rather than some other element because a Mystery claim must be backed
/// by certified supreme dominance in the earth zone — the same proof has to
/// justify the delay itself.
SpellAsset forgedSpell({int? rulesetVersion}) => _spell(
      id: 'forged-mystery',
      name: 'Forged Mystery',
      // THE LIE. An honest client would write earth here, matching its proof.
      formula: List.filled(kActivations, 'fire'),
      rulesetVersion: rulesetVersion,
    );

SpellAsset _spell({
  required String id,
  required String name,
  required List<String> formula,
  int? rulesetVersion,
  int commitmentByte = 0xab,
}) {
  const t = kActivations;
  final tier = tierForSteps(t)!;
  final commitmentBytes = Uint8List.fromList(List.filled(32, commitmentByte));
  final commitmentHex =
      '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  // Matches _certifiedManaCost: (5*seg + dot) * 1.05^T * 1.5^effectCount,
  // effectCount = max(0, formulas - 1) = 0 for a single complete formula.
  var cost = (5 * kSegmentCount + kDotCount).toDouble();
  for (var i = 0; i < t; i++) {
    cost *= 1.05;
  }

  return SpellAsset(
    id: id,
    createdAt: DateTime.utc(2026, 8, 13),
    tier: tier,
    t: t,
    ownerPubkeyHex: '0x${'00' * 32}',
    manaCost: cost.round(),
    segmentCount: kSegmentCount,
    dotCount: kDotCount,
    initialGrid: const [],
    proofBytes: syntheticProof(
      tier: tier,
      t: t,
      commitmentBytes: commitmentBytes,
      rulesetVersion: rulesetVersion ?? kRulesetVersion,
    ),
    name: name,
    commitmentHex: commitmentHex,
    spellHashHex: '',
    formula: formula,
  );
}

/// The same spell told honestly: its wire `formula` matches the earth
/// trajectory its proof attests.
///
/// Needed for any positive-path test, because an immediate cast of
/// [forgedSpell] **legitimately desyncs**: the verifier resolves from the
/// certified trajectory (earth) while the caster resolves from its own wire
/// formula (fire), and `_exchangeStateHash` forfeits the match on the
/// difference.
///
/// That contrast is the whole reason the Mystery delay mattered. An immediate
/// forgery is caught by the state hash; a delayed one used to have BOTH
/// devices fall back to the wire formula, so they agreed with each other and
/// nothing fired. See docs/M4_findings.md M4.15.
SpellAsset honestSpell() => _spell(
      id: 'honest-earth',
      name: 'Honest Earth',
      formula: List.filled(kActivations, 'earth'),
    );

/// A distinct honest spell per [variant].
///
/// The duplicate-grid guard forfeits a peer who casts the same grid twice, so
/// any script that casts more than once needs grids that differ. The
/// commitment is grid-only, so varying its bytes is what makes two fixtures
/// count as different spells.
SpellAsset honestSpellVariant(int variant) => _spell(
      id: 'honest-earth-$variant',
      name: 'Honest Earth $variant',
      formula: List.filled(kActivations, 'earth'),
      commitmentByte: 0x20 + variant,
    );

/// `[4 BE bytes: field count N][N × 32-byte fields][proof body]`, the wire
/// shape ProofIntake parses. Field map (proof_intake.dart): 0=T, 1=owner,
/// 2=ruleset, 3=commitment, 4..7=border, 8..8+tier-1=dominance trajectory,
/// 8+tier..=supreme flags, then segmentCount, dotCount.
Uint8List syntheticProof({
  required int tier,
  required int t,
  required Uint8List commitmentBytes,
  required int rulesetVersion,
}) {
  final count = 10 + 2 * tier;
  final bytes = Uint8List(4 + count * 32 + 1);
  final data = ByteData.sublistView(bytes);
  void setField(int i, int v) => data.setUint32(4 + i * 32 + 28, v, Endian.big);

  data.setUint32(0, count, Endian.big);
  setField(0, t);
  setField(2, rulesetVersion);
  bytes.setRange(4 + 3 * 32, 4 + 3 * 32 + 32, commitmentBytes);
  for (var gen = 0; gen < kActivations; gen++) {
    setField(8 + gen, kEarthDominance);
    // Supreme earth is doing double duty: it makes the activations count, and
    // it is what backs the Mystery enhancement claim itself.
    setField(8 + tier + gen, 1);
  }
  setField(8 + 2 * tier, kSegmentCount);
  setField(8 + 2 * tier + 1, kDotCount);
  return bytes;
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Two wizards, adjacent, with mana to spare.
BattleState makeDuelState() {
  final battlefield = Battlefield();
  const posA = HexCoord(0, 0);
  const posB = HexCoord(1, 0);
  battlefield.occupancy['player_a'] = posA;
  battlefield.occupancy['player_b'] = posB;

  return BattleState(
    config: const MatchConfig(),
    avatars: [
      WizardAvatar(
        playerId: 'player_a',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: kStartMana,
        maxMana: kStartMana,
        position: posA,
        teamId: 'team_a',
        baseSpellRange: 3,
      ),
      WizardAvatar(
        playerId: 'player_b',
        ownerPubkeyHex: '0x${'11' * 32}',
        hp: 24,
        mana: kStartMana,
        maxMana: kStartMana,
        position: posB,
        teamId: 'team_b',
        baseSpellRange: 3,
      ),
    ],
    teams: [
      const Team(id: 'team_a', playerIds: ['player_a']),
      const Team(id: 'team_b', playerIds: ['player_b']),
    ],
    battlefield: battlefield,
  );
}
