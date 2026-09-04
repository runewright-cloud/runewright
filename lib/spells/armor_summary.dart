// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_summary.dart — reading a locally persisted armor's semantics back out
// of its own proof.
//
// ## The rule this file exists to keep (M4.22)
//
// An armor's stats are what its PROOF attests, not what the asset says about
// itself. `SpellAsset.formula`, `manaCost`, `supremeTags` and `isArmor` are
// authored fields that nothing binds; a stale or edited one must not be able
// to change a single number the player sees. So the display path is:
//
//     SpellAsset.proofBytes
//       -> ProofIntake.parseOwn(bytes, tierForProof(t, tier))
//       -> VerifiedSpellOutputs
//       -> CertifiedArmor.fromOutputs
//
// which is the same object duel setup will later derive from the same bytes on
// the other side of the trust boundary. One proof, one meaning -- the local
// reading and the certified one are the same code, differing only in whether
// the bytes were verified first (they are ours; `parseOwn` deliberately does
// not re-verify).
//
// Nothing here synthesises armor semantics when the proof is unreadable. A
// null return means "this armor cannot be read", and the UI must say so rather
// than fall back to authored metadata -- a fallback would show numbers no
// proof stands behind, which is the failure mode this whole file prevents.

import '../battle/engine/proof_intake.dart' show ProofIntake, ProofIntakeException;
import '../battle/models/certified_armor.dart';

import 'spell_asset.dart';
import 'spell_asset_integrity.dart' show tierForProof;

/// Player-facing names for the armor keywords. Morphic (WWWW) is deliberately
/// absent -- it is designed but not implemented, so it is not granted and has
/// no name to show.
const Map<ArmorKeyword, String> kArmorKeywordLabel = {
  ArmorKeyword.flying: 'Flying',
  ArmorKeyword.cleave: 'Cleave',
  ArmorKeyword.charger: 'Charger',
  ArmorKeyword.muddy: 'Muddy',
  ArmorKeyword.moltenCarapace: 'Molten Carapace',
  ArmorKeyword.stealthy: 'Stealthy',
  ArmorKeyword.anchored: 'Anchored',
};

/// The armor semantics [spell]'s own proof attests, or null if those bytes are
/// missing or unparseable.
///
/// [tierForProof] re-derives the parsing tier from T exactly as `inscribeSpell`
/// chose it at proving time, rather than trusting `SpellAsset.tier`: the public
/// input count is `10 + 2*tier_max`, so a wrong tier reads the trajectory
/// arrays at the wrong offsets and yields confident garbage.
///
/// Does NOT check [SpellAsset.isArmor] -- that marker decides where an asset
/// may be equipped (a UI question, answered in chapter_armor.dart), while this
/// answers what its trajectory means. Any proof can be read this way; only an
/// armor has reason to.
///
/// [lexicon] rekeys only the keyword set (audit R-8) — T, slot cost and every
/// stat bonus are identical under every leyline. It defaults to the ordinary
/// tradition, which is the right reading for a library with no match in
/// progress; a surface that KNOWS an active leyline passes it, so it cannot
/// print a keyword the duel would not grant.
CertifiedArmor? localCertifiedArmor(
  SpellAsset spell, {
  ArmorLexicon lexicon = ArmorLexicon.ordinary,
}) {
  if (spell.proofBytes.isEmpty) return null;
  try {
    return CertifiedArmor.fromOutputs(
      ProofIntake.parseOwn(spell.proofBytes, tierForProof(spell.t, spell.tier)),
      lexicon: lexicon,
    );
  } on ProofIntakeException {
    return null;
  } on RangeError {
    // A truncated blob that still passes the declared-length check.
    return null;
  }
}
