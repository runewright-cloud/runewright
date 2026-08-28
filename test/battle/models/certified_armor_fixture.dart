// SPDX-License-Identifier: GPL-3.0-or-later
//
// certified_armor_fixture.dart — build a [CertifiedArmor] the way production
// does, for the tests that need an armor to equip rather than an armor to
// derive.
//
// Deliberately routed through [CertifiedArmor.fromOutputs] over synthetic
// [VerifiedSpellOutputs], NOT through `previewFromElementSequence`: preview is
// the editor's live "what will this inscribe as" path and its doc comment says
// nothing in battle, setup or networking may reach for it. A test fixture that
// used it would be testing the equipment path against semantics no proof shape
// ever produced. The one place a CertifiedArmor is built by hand is
// armor_canonical_bytes_test.dart's keyword-order check, which needs two
// objects that differ only in a Set's insertion order — something no
// derivation can produce.

import 'dart:typed_data';

import 'package:rune_duel/battle/engine/proof_outputs.dart';
import 'package:rune_duel/battle/models/certified_armor.dart';

/// Dominance index as the circuit emits it: 0=neutral, 1=fire, 2=air,
/// 3=water, 4=earth (CLAUDE.md — the stepper's order).
const Map<String, int> _codeToIndex = {'n': 0, 'F': 1, 'A': 2, 'W': 3, 'E': 4};

int _tierFor(int t) => t <= 12 ? 12 : (t <= 24 ? 24 : 48);

/// The armor a proof attesting [codes] certifies — one char per generation,
/// `n` for a neutral (contributes nothing) generation.
///
/// `armorOf('FFFF')` is a four-fire armor: melee +1 and the Cleave keyword.
/// [t] defaults to the code length; pass it to declare more active generations
/// than the sequence spends, which is what moves slot cost independently of
/// the element counts.
CertifiedArmor armorOf(String codes, {int? t}) {
  final activeT = t ?? codes.length;
  final tierMax = _tierFor(activeT > codes.length ? activeT : codes.length);
  final trajectory = List<int>.filled(tierMax, 0);
  for (var i = 0; i < codes.length; i++) {
    trajectory[i] = _codeToIndex[codes[i]]!;
  }
  return CertifiedArmor.fromOutputs(VerifiedSpellOutputs(
    proofBytes: Uint8List(0),
    t: activeT,
    ownerPubkeyHex: '0x${'00' * 32}',
    rulesetVersion: 3,
    commitmentHex: '0x00',
    tierMax: tierMax,
    borderActivations: const [0, 0, 0, 0],
    dominanceTrajectory: trajectory,
    supremeDominanceFlags: List<int>.filled(tierMax, 0),
    segmentCount: 0,
    dotCount: 0,
  ));
}

/// n copies of one element code, for reaching a ladder breakpoint readably.
String runOfCode(String code, int n) => code * n;

/// The lowest rung of each ladder, as codes:
/// four of an element is +1 melee/move/range; two earths is +2 HP.
const String kFireArmorCodes = 'FFFF'; // melee +1, keyword Cleave
const String kAirArmorCodes = 'AAAA'; // move  +1, keyword Flying
const String kWaterArmorCodes = 'WWWW'; // range +1, no keyword (Morphic unbuilt)
const String kEarthArmorCodes = 'EE'; // armor HP +2, no keyword
