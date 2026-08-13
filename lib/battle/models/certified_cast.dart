// SPDX-License-Identifier: GPL-3.0-or-later
//
// certified_cast.dart — the semantic content of a spell cast, as attested by
// its ZK proof rather than as claimed on the wire.
//
// ## Why this type exists
//
// A peer's `SpellAsset` carries two very different kinds of data:
//
//   * `commitment` / `proofBytes` — cryptographically bound. The commitment is
//     grid-only (CLAUDE.md invariant 2), and the proof attests the trajectory
//     that grid produces.
//   * `formula`, `segmentCount`, `dotCount`, … — plain wire fields. **Nothing
//     binds these to the proof.** A modified client can put anything here.
//
// The B-1 fix established that resolution must read the first kind, never the
// second: [TurnLoop._verifyPeerSpellCast] re-derives the formula list, the flat
// element sequence, and the wild-magic triggers from the verified public
// outputs, and resolution uses those.
//
// Until now that certified data lived only in turn-scoped maps inside
// `runTurn`, which is fine for a cast that resolves on the turn it is revealed.
// A Mystery (delayed) cast resolves up to three turns later, by which time the
// maps have been cleared — so the fire fell back to `spell.formula`, the
// untrusted wire value. Both devices fell back identically, so it never
// desynced; it simply meant a delayed cast resolved from data no proof had
// attested. This type is what a [PendingDelayedSpell] carries across those
// turns so it doesn't have to.
//
// ## Invariant
//
// Every field here is a pure function of the proof's public outputs (plus the
// agreed `communitySeed` for wild magic). Both devices derive the same values
// for the same spell from opposite sides of the trust boundary — the owner via
// [ProofIntake.parseOwn], the verifier via [ProofIntake.verifyAndParse] — so
// carrying it costs nothing on the wire and cannot desync.
//
// A null [CertifiedCast] means "no proof to derive from" (a proofless dev-flag
// spell), never "trust the wire instead" for a verified peer cast. See the
// TODO(B-1) notes in turn_loop.dart.

import 'package:rune_duel/engine/border_zone.dart';

import '../engine/trajectory_parser.dart' show ParsedFormula;
import 'wild_magic_effect.dart' show WildMagicTrigger;

/// The proof-attested semantics of one spell cast.
///
/// Constructed at the point of verification and consumed by resolution; see
/// the file header for why it must not be reconstructed from wire fields.
class CertifiedCast {
  const CertifiedCast({
    required this.formulas,
    required this.elementSequence,
    required this.wildMagic,
  });

  /// Formula triplets grouped from the certified trajectory — replaces
  /// `spell.formula` for effect resolution, mana cost, and chain state.
  final List<ParsedFormula> formulas;

  /// The flat certified activation sequence, residuals included. Summons read
  /// this (`CreatureSpec.fromElements` counts every activation, while
  /// [formulas] drops a trailing 1–2), as does counter-charm matching.
  final List<BorderZone> elementSequence;

  /// Wild-magic triggers derived from the certified outputs + [formulas] +
  /// the agreed community seed (WILD_MAGIC_PLAN.md §4.6).
  final List<WildMagicTrigger> wildMagic;
}
