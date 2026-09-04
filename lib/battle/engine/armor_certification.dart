// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_certification.dart — turning an armor declaration into armor semantics
// both devices agree on, or refusing the match.
//
// ## The asymmetry, and why the result is nonetheless identical
//
//   local  : SpellAsset.proofBytes -> ProofIntake.parseOwn      -> outputs
//   peer   : ArmorEnvelope         -> ProofIntake.verifyAndParse -> outputs
//   both   : outputs -> validate -> CertifiedArmor.fromOutputs(agreed lexicon)
//
// The two paths differ only in whether the bytes are cryptographically
// verified first — ours are ours, and re-verifying a proof this device
// authored buys nothing but seconds. Everything after that point is one code
// path, so the same proof cannot mean one thing to its wearer and another to
// their opponent. `armor_certification_test.dart` pins exactly that.
//
// ## What is checked, and why each one
//
//   * ruleset epoch — a proof attesting a different CA ruleset describes an
//     armor this build cannot reproduce. Refuse rather than score it under
//     whichever rules happen to be compiled in.
//   * owner — the certified `owner_pubkey` must be the authenticated wearer.
//     Without this a peer could wear any proof they had ever seen, including
//     one lifted off the wire in an earlier duel. Armor is wearable only by
//     its proof's owner this slice: there are no armor loans.
//   * tier — the declared tier must be a canonical inscription tier AND must
//     be the tier the certified T actually implies. The declaration routes
//     parsing before T is readable; this closes the loop afterward so it
//     cannot be used to reinterpret the same bytes.
//   * budget — ordinary artifacts + `CertifiedArmor.slotCost` must fit
//     [ChapterAsset.maxArtifactSlots], recomputed from the CERTIFIED T. The
//     editor's accounting used the locally stored T, which is unbound; a
//     locally edited asset understating its cost dies here.
//
// Failure throws. Setup fails closed — never build a BattleState and ignore
// bad armor.
//
// Deliberately NOT routed through PeerCastVerifier: armor is public setup
// equipment, not a cast. It has no hand slot, no Merkle membership proof, no
// mana price, no chain state. Reusing that path would mean teaching it about a
// thing that is not a spell.

import 'dart:typed_data';

import 'package:rune_duel/protocol/match_session.dart' show ProofVerifier;
import 'package:rune_duel/spells/chapter_asset.dart' show ChapterAsset;
import 'package:rune_duel/spells/inscribe.dart' show kInscribeTiers, kRulesetVersion;
import 'package:rune_duel/spells/spell_asset.dart' show SpellAsset;
import 'package:rune_duel/spells/spell_asset_integrity.dart' show tierForProof;

import '../models/armor_envelope.dart';
import '../models/certified_armor.dart';
import 'proof_intake.dart';

/// Raised when an armor declaration cannot be certified. Always fatal to the
/// handshake: the caller forfeits and rethrows.
class ArmorCertificationException implements Exception {
  ArmorCertificationException(this.reason);
  final String reason;
  @override
  String toString() => 'ArmorCertificationException: $reason';
}

/// The circuit tier [armor]'s proof was generated at, re-derived from its T
/// exactly as `inscribeSpell` chose it — NOT read from `SpellAsset.tier`,
/// which is authored like every other field on the asset.
///
/// One function so the tier we declare on the wire and the tier we parse our
/// own proof at can never be two different numbers.
int armorProofTier(SpellAsset armor) => tierForProof(armor.t, armor.tier);

/// Certifies the armor THIS device is wearing, from the asset it resolved
/// locally. Returns null when [armor] is null (nothing equipped).
///
/// [armor] must already have been resolved from `ChapterAsset.armorSpellId`;
/// `isArmor` is checked here as local equipment-selection metadata (it decides
/// what we are allowed to equip), never as anything a peer is told or trusts.
///
/// [lexicon] is the match's agreed leyline reading. REQUIRED rather than
/// defaulted: a certification boundary must not be able to fall back to the
/// ordinary tradition by omission — that is how one device reads Flying off an
/// armor the other reads nothing off. Callers pass
/// `ArmorLexicon.of(effectiveConfig.leyline)`.
CertifiedArmor? certifyOwnArmor({
  required SpellAsset? armor,
  required String wearerOwnerPubkeyHex,
  required int ordinaryArtifactCount,
  required ArmorLexicon lexicon,
}) {
  if (armor == null) return null;
  if (!armor.isArmor) {
    throw ArmorCertificationException(
      'chapter equips "${armor.name}", which is not marked as an armor',
    );
  }
  if (armor.proofBytes.isEmpty) {
    throw ArmorCertificationException(
      'equipped armor "${armor.name}" carries no proof',
    );
  }
  final tier = armorProofTier(armor);
  final VerifiedSpellOutputs outputs;
  try {
    outputs = ProofIntake.parseOwn(armor.proofBytes, tier);
  } on ProofIntakeException catch (e) {
    throw ArmorCertificationException('local armor proof is unreadable: ${e.reason}');
  }
  return _validateAndDerive(
    outputs: outputs,
    declaredTier: tier,
    wearerOwnerPubkeyHex: wearerOwnerPubkeyHex,
    ordinaryArtifactCount: ordinaryArtifactCount,
    lexicon: lexicon,
    side: 'local',
  );
}

/// Certifies the armor the PEER declared, verifying its proof first.
///
/// Returns null when [envelope] is null ("no armor"), which is a complete and
/// legitimate declaration — the frame is exchanged either way.
///
/// [vkBytesForTier] supplies the verification key for the declared tier;
/// returning null for a tier means this device cannot verify it, which is a
/// refusal, not a pass. The SRS/CRS must already be initialised (CLAUDE.md
/// bug-avoidance #4) — that is the caller's job and it must happen before the
/// first [verifyProof] call in the process.
Future<CertifiedArmor?> certifyPeerArmor({
  required ArmorEnvelope? envelope,
  required String wearerOwnerPubkeyHex,
  required int ordinaryArtifactCount,
  required ProofVerifier? verifyProof,
  required Uint8List? Function(int tier)? vkBytesForTier,
  required ArmorLexicon lexicon,
}) async {
  if (envelope == null) return null;

  // Reject an off-menu tier BEFORE parsing: the tier decides the public-input
  // layout, so parsing at an unsupported one is not a smaller error, it is a
  // read at meaningless offsets.
  if (!kInscribeTiers.contains(envelope.tier)) {
    throw ArmorCertificationException(
      'peer declared unsupported armor circuit tier ${envelope.tier}',
    );
  }
  if (envelope.proofBytes.isEmpty) {
    throw ArmorCertificationException('peer declared an armor with no proof');
  }
  if (verifyProof == null || vkBytesForTier == null) {
    throw ArmorCertificationException(
      'peer declared an armor but this device has no verifier initialised — '
      'refusing to accept it unverified',
    );
  }
  final vk = vkBytesForTier(envelope.tier);
  if (vk == null) {
    throw ArmorCertificationException(
      'no verification key available for armor tier ${envelope.tier}',
    );
  }

  final VerifiedSpellOutputs outputs;
  try {
    outputs = await ProofIntake.verifyAndParse(
      envelope.proofBytes,
      vk,
      verifyProof,
      envelope.tier,
    );
  } on ProofIntakeException catch (e) {
    throw ArmorCertificationException('peer armor proof rejected: ${e.reason}');
  }
  return _validateAndDerive(
    outputs: outputs,
    declaredTier: envelope.tier,
    wearerOwnerPubkeyHex: wearerOwnerPubkeyHex,
    ordinaryArtifactCount: ordinaryArtifactCount,
    lexicon: lexicon,
    side: 'peer',
  );
}

/// The shared half: everything after "we have trustworthy public outputs".
/// Both sides run this identical function, which is what makes the local and
/// peer readings of one proof the same reading.
CertifiedArmor _validateAndDerive({
  required VerifiedSpellOutputs outputs,
  required int declaredTier,
  required String wearerOwnerPubkeyHex,
  required int ordinaryArtifactCount,
  required ArmorLexicon lexicon,
  required String side,
}) {
  if (outputs.rulesetVersion != kRulesetVersion) {
    throw ArmorCertificationException(
      '$side armor proof attests ruleset version ${outputs.rulesetVersion}, '
      'but this build implements $kRulesetVersion',
    );
  }
  if (!_hexEq(outputs.ownerPubkeyHex, wearerOwnerPubkeyHex)) {
    throw ArmorCertificationException(
      '$side armor proof is bound to another wizard\'s Runekey — armor is '
      'wearable only by its owner',
    );
  }
  // T is range-checked inside the parser (1 <= t <= tier_max); this is the
  // other half — that the tier we were told to parse at is the tier this T
  // implies. Without it a peer could declare tier 48 for a T=5 proof and read
  // the same bytes through a different layout.
  final impliedTier = tierForProof(outputs.t, declaredTier);
  if (impliedTier != declaredTier) {
    throw ArmorCertificationException(
      '$side armor declares tier $declaredTier but its certified T=${outputs.t} '
      'belongs to tier $impliedTier',
    );
  }

  // Both sides derive under the SAME agreed leyline, which is what makes one
  // proof plus one accepted config one armor. Nothing about the keyword set
  // crosses the wire — the envelope carries a proof and a routing tier.
  final armor = CertifiedArmor.fromOutputs(outputs, lexicon: lexicon);

  // Recomputed from the certified T, never from a persisted or transmitted
  // slot cost.
  final used = ordinaryArtifactCount + armor.slotCost;
  if (used > ChapterAsset.maxArtifactSlots) {
    throw ArmorCertificationException(
      '$side loadout needs $used artifact slots '
      '($ordinaryArtifactCount artifacts + ${armor.slotCost} for a T=${armor.t} '
      'armor), over the ${ChapterAsset.maxArtifactSlots}-slot limit',
    );
  }
  return armor;
}

/// Numeric hex comparison — the convention duel_setup.dart and
/// library_screen.dart already use for owner keys, so "0x0a", "0A" and a
/// differently padded encoding of the same field all compare equal.
bool _hexEq(String a, String b) {
  // The `0x` strip is case-insensitive where the copies in duel_setup.dart and
  // library_screen.dart only handle lowercase. Same semantics, one less way to
  // read two encodings of one field as two different wizards. A false negative
  // here is fail-closed (a refused match, never an accepted forgery), which is
  // exactly why it is worth not having at all.
  BigInt parse(String s) => BigInt.parse(
        s.length >= 2 && (s.startsWith('0x') || s.startsWith('0X'))
            ? s.substring(2)
            : s,
        radix: 16,
      );
  try {
    return parse(a) == parse(b);
  } on FormatException {
    return false;
  }
}
