// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_fixture.dart — persisted-armor fixtures whose proof bytes are real
// enough for ProofIntake to parse, without ever running a prover.
//
// Reuses certified_cast_fixture.dart's syntheticProof (the same ABI writer the
// battle-engine tests use) so there is one place in the test tree that knows
// the wire layout, mirroring the one place in lib/ that reads it.

import 'dart:typed_data';

import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import '../battle/engine/certified_cast_fixture.dart' show syntheticProof;

/// A persisted armor whose proof attests [elements] as its per-generation
/// dominance over [t] generations.
///
/// [formula], [manaCost] and [supremeTags] default to values that CONTRADICT
/// the proof: they are authored fields, and every armor read-out must ignore
/// them. A test that passes with these lies in place is a test that proved the
/// display is proof-derived.
SpellAsset armorAsset({
  String id = 'armor-1',
  String name = 'Aetherial Plate',
  required List<BorderZone> elements,
  int? t,
  bool isArmor = true,
  List<String> formula = const ['earth', 'earth', 'earth', 'earth'],
  List<String> supremeTags = const ['earth'],
  int manaCost = 999,
  Uint8List? proofBytes,
}) {
  final generations = t ?? elements.length;
  final tier = generations <= 12 ? 12 : (generations <= 24 ? 24 : 48);
  return SpellAsset(
    id: id,
    createdAt: DateTime.utc(2026, 8, 25),
    tier: tier,
    t: generations,
    ownerPubkeyHex: '0x${'0' * 64}',
    manaCost: manaCost,
    segmentCount: 1,
    dotCount: 0,
    initialGrid: List<int>.filled(469, 0)..[234] = 1,
    proofBytes: proofBytes ??
        syntheticProof(
          tier: tier,
          t: generations,
          commitmentBytes: Uint8List(32),
          rulesetVersion: 3,
          elements: elements,
        ),
    name: name,
    commitmentHex: '0x${'a' * 64}',
    spellHashHex: '0x${'b' * 64}',
    formula: formula,
    supremeTags: supremeTags,
    isArmor: isArmor,
  );
}

/// n copies of one element — the readable way to hit a ladder breakpoint.
List<BorderZone> runOf(BorderZone zone, int n) => List.filled(n, zone);

/// A non-armor spell, for the "this must NOT be treated as armor" half of
/// every test. [isSummon] flips it between the other two inscription modes.
SpellAsset plainSpell({
  String id = 'spell-1',
  String name = 'Ember Wake',
  bool isSummon = false,
  int t = 5,
}) =>
    SpellAsset(
      id: id,
      createdAt: DateTime.utc(2026, 8, 25),
      tier: 12,
      t: t,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 10,
      segmentCount: 1,
      dotCount: 0,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List(0),
      name: name,
      commitmentHex: '0x${'c' * 64}',
      spellHashHex: '0x${'d' * 64}',
      formula: const ['fire', 'inner', 'outer'],
      isSummon: isSummon,
    );
