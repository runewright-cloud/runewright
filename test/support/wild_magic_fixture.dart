// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_fixture.dart — a structurally real proof blob and the SpellAsset
// around it, shared by the wild-magic preview tests and the spell-card widget
// tests.
//
// Wild Magic v2 keys on `caster x certified spell behavior x leyline`, and
// since Slice 3 the card preview reads "certified spell behavior" out of the
// spell's own PROOF rather than out of its authored metadata. So a preview
// fixture now needs a parseable proof — hence this file, rather than another
// hand-built `SpellAsset` per test.
//
// The blob is `[4 BE field count][count x 32-byte fields]` in the ABI order
// `ProofIntake` documents. Not a valid SNARK — nothing here verifies one — but
// byte-exact everywhere the parser reads.

import 'dart:typed_data';

import 'package:rune_duel/spells/inscribe.dart' show tierForSteps;
import 'package:rune_duel/spells/spell_asset.dart';

/// The commitment every fixture spell carries. Wild Magic v2 does not hash it
/// (docs/WILD_MAGIC_PLAN_VNEXT.md §3) — it is here because `SpellAsset` and the
/// proof ABI both need one, and the preview tests deliberately vary it to prove
/// it cannot move a trigger.
final Uint8List kFixtureCommitment =
    Uint8List.fromList(List.generate(32, (i) => i + 1));

String get kFixtureCommitmentHex =>
    '0x${kFixtureCommitment.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

/// Fire, neutral, fire, neutral, fire.
///
/// `FormulaTracker` only commits an activation on a LEAD CHANGE, a supreme
/// generation, or a cadence pulse — so three consecutive fire generations
/// commit ONE activation, not three. Interleaving neutrals makes each fire a
/// fresh lead change, giving three activations = one complete fire formula.
/// (Element indices: 1=fire, 2=air, 3=water, 4=earth.)
const List<int> kFireTrajectory = [1, 0, 1, 0, 1];

/// A structurally real proof blob for a spell of [t] generations.
Uint8List fixtureProofBytes({
  int t = 5,
  // Defaults to the tier a real inscription of this T would have used, so the
  // blob's field count matches what the parser derives from T. A fixed 24 here
  // paired with a low T describes a spell that cannot exist.
  int? tier,
  List<int> trajectory = kFireTrajectory,
  List<int> supremeFlags = const [],
  int segmentCount = 1,
  int dotCount = 1,
  Uint8List? commitment,
}) {
  tier ??= tierForSteps(t)!;
  final count = 10 + 2 * tier;
  final out = Uint8List(4 + count * 32);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, count, Endian.big);

  void setSmall(int index, int value) {
    // Big-endian field; small integers live in the last 8 bytes.
    ByteData.sublistView(out, 4 + index * 32 + 24, 4 + index * 32 + 32)
        .setUint64(0, value, Endian.big);
  }

  void setBytes(int index, Uint8List value) {
    out.setRange(4 + index * 32, 4 + index * 32 + 32, value);
  }

  setSmall(0, t); // T
  setSmall(1, 0); // owner_pubkey — the INSCRIBER, which v2 never reads
  setSmall(2, 3); // ruleset_version
  setBytes(3, commitment ?? kFixtureCommitment);
  for (var i = 0; i < 4; i++) {
    setSmall(4 + i, 0); // border_activations
  }
  for (var g = 0; g < tier; g++) {
    setSmall(8 + g, g < trajectory.length ? trajectory[g] : 0);
  }
  for (var g = 0; g < tier; g++) {
    setSmall(8 + tier + g, g < supremeFlags.length ? supremeFlags[g] : 0);
  }
  setSmall(8 + 2 * tier, segmentCount);
  setSmall(8 + 2 * tier + 1, dotCount);
  return out;
}

/// A stub inscriber key. Deliberately the all-zero Field the preview refuses
/// to treat as a caster identity: nothing may read it.
const String kFixtureInscriberPubkeyHex =
    '0x0000000000000000000000000000000000000000000000000000000000000000';

/// A pure-fire fixture spell (one complete fire formula), so eligibility
/// resolves to the Fire column alone.
///
/// [ownerPubkeyHex] is the INSCRIBER. Since Slice 3 no preview reads it — it is
/// a parameter here precisely so tests can prove that.
SpellAsset fixtureSpell({
  int t = 5,
  String ownerPubkeyHex = kFixtureInscriberPubkeyHex,
  String? commitmentHex,
  List<int> trajectory = kFireTrajectory,
  List<String> formula = const ['fire', 'fire', 'fire'],
  int segmentCount = 1,
  int dotCount = 1,
  Uint8List? proofBytes,
  String name = 'Fixture',
  bool isSummon = false,
}) =>
    SpellAsset(
      id: 'wm-fixture',
      createdAt: DateTime.utc(2026, 8, 5),
      tier: tierForSteps(t)!,
      t: t,
      ownerPubkeyHex: ownerPubkeyHex,
      manaCost: 6,
      segmentCount: segmentCount,
      dotCount: dotCount,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: proofBytes ??
          fixtureProofBytes(
            t: t,
            trajectory: trajectory,
            segmentCount: segmentCount,
            dotCount: dotCount,
          ),
      name: name,
      commitmentHex: commitmentHex ?? kFixtureCommitmentHex,
      spellHashHex: '0x${'b' * 64}',
      formula: formula,
      isSummon: isSummon,
    );
