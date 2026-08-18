// SPDX-License-Identifier: GPL-3.0-or-later
//
// peer_cast_verifier.dart — PeerCastVerifier: the peer-cast trust boundary.
//
// ## What this is
//
// Everything that decides whether a peer's declared spell cast may be believed,
// and — if it may — exactly which facts about it are believable. Nothing else.
//
// A peer's `SpellAsset` crossing the wire carries two very different kinds of
// field (certified_cast.dart's header spells this out): a commitment and proof
// bytes, which are cryptographically bound, and everything else — `formula`,
// `segmentCount`, `dotCount`, `t`, `name` — which a modified client writes
// freely. This class is the one place that turns the first kind into trusted
// facts, and the [CertifiedPeerCast] it returns is the only channel by which
// those facts reach resolution.
//
// ## What this is NOT
//
// It owns no [BattleSession], sends no forfeit, performs no I/O, mutates no
// battle state, and knows nothing about turn sequencing. A rejection is
// *returned*, as data ([PeerCastRejected]), and `TurnLoop` decides what the
// protocol does about it — which today is exactly what it did before: send the
// same forfeit tag and abort the turn with the same message.
//
// That split is deliberate. A verifier that can end the match is a verifier
// whose failure modes cannot be unit-tested without a network, and every
// rejection branch here is a branch an attacker chooses to enter.
//
// Also deliberately absent: the commit/reveal hash checks, the free-move and
// melee reveal verification, and the session handshake checks. Those are
// protocol-integrity checks — they establish that the peer said what they
// committed to saying, not that what they said is backed by a proof. They stay
// in `TurnLoop`.
//
// ## Ordering is behaviour
//
// The checks below run in a fixed order and the FIRST failure is the one
// reported. A peer whose cast is both unauthorized and unaffordable forfeits on
// authorization; swapping two checks changes which tag the losing device shows.
// Every branch is pinned by a negative test — see
// test/battle/engine/peer_cast_rejection_test.dart and the five older files it
// lists — so the order is enforced, not merely documented.
//
// ## Single source of truth (B-1 / B-8)
//
// [semanticsOf] is the ONLY derivation of a cast's certified meaning in the
// codebase. Both sides of the trust boundary reach it: the peer path via
// [certifyPeerCast] (verify, then derive), the owner's own path via
// [certifyOwnProof] (parse, then derive). One function, so the two devices
// cannot disagree about what a proof said.
//
// [certifiedBaseManaCost] is likewise the only proof-derived base price. The
// modifier chain that layers on top of it (chain discount, Efficiency, recall,
// nextSpellCostDouble) lives in `DeterministicResolution.certifiedManaCost`,
// because applying
// it consumes status effects and can convert a shortfall into HP damage — it
// mutates the caster. What crosses into it from here is the certified base and
// the certified formulas, so there is still exactly one path from proof bytes
// to a peer's mana deduction.

import 'dart:math' show max, pow;
import 'dart:typed_data';

import 'package:rune_duel/battle/models/certified_cast.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/protocol/match_session.dart' show ProofVerifier;
import 'package:rune_duel/spells/basic_spells.dart' show isBasicGridAndT;
import 'package:rune_duel/spells/inscribe.dart'
    show kMaxInscribableSteps, tierForSteps;
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_authorization.dart';
import 'package:rune_duel/spells/spell_identity.dart' show isCantripElementCount;
import 'package:rune_duel/spells/spell_permission.dart';

import 'book_commitment.dart' show MembershipProof;
import 'draw_schedule.dart' show DrawSchedule;
import 'proof_intake.dart';
import 'trajectory_parser.dart' show ParsedFormula, TrajectoryParser;
import 'turn_actions.dart';
import 'wild_magic.dart' show WildMagic;

// ── Result type ───────────────────────────────────────────────────────────────

/// The outcome of asking [PeerCastVerifier] about one peer declaration.
///
/// Three cases, not two: "certified", "rejected", and "nothing to certify".
/// Collapsing the third into either of the others would be a behaviour change —
/// a solo match, a test without a wired verifier, and a `kAllowProoflessSpells`
/// test spell all reach resolution with no certified data and fall back to the
/// wire formula on BOTH devices, which is desync-safe even though it is not
/// trust-safe. Reporting that as a rejection would forfeit those matches;
/// reporting it as a certification would invent facts no proof attests.
sealed class PeerCastVerdict {
  const PeerCastVerdict();
}

/// The declaration was verified. [cast] holds every fact it established.
final class PeerCastCertified extends PeerCastVerdict {
  const PeerCastCertified(this.cast);
  final CertifiedPeerCast cast;
}

/// Verification did not run: not a spell cast, no verifier/VK wired up, or the
/// `kAllowProoflessSpells` dev-flag bypass. Nothing is certified and nothing is
/// rejected; the caller proceeds as it did before proof verification existed.
final class PeerCastUncertified extends PeerCastVerdict {
  const PeerCastUncertified();
}

/// The declaration failed certification.
///
/// [forfeitReason] is the exact tag the peer receives and `BattleScreen`
/// switches on to explain the loss; [detail] is the exact message the aborting
/// turn throws. Both are externally visible, so both are part of this type
/// rather than reconstructed by the caller from an enum.
final class PeerCastRejected extends PeerCastVerdict {
  const PeerCastRejected(this.forfeitReason, this.detail);

  /// The `sendForfeit` tag — one of `missing_spell_proof`,
  /// `invalid_spell_tier`, `missing_vk_for_tier`, `invalid_spell_proof`,
  /// `t_mismatch`, `commitment_mismatch`, `ruleset_version_mismatch`,
  /// `duplicate_spell_cast:<hex>`, `unbacked_enhancement_claim`,
  /// `book_membership_failed`, `cast_out_of_hand`, `unauthorized_spell:<hex>`.
  final String forfeitReason;

  /// The `StateError` message the turn aborts with.
  final String detail;
}

/// The facts a verified peer cast establishes — and nothing else.
///
/// Every field is here because something downstream consumes it. Deliberately
/// absent: the raw [VerifiedSpellOutputs], the certified supreme-tag set, and
/// `t`. All three are *used* during verification (tag matching, the T binding,
/// the duplicate-grid key) and none is read after it. Carrying them would
/// re-open the possibility of a second consumer re-deriving something from the
/// proof a different way, which is the exact failure mode B-1 closed.
class CertifiedPeerCast {
  const CertifiedPeerCast({
    required this.commitmentHex,
    required this.semantics,
    required this.baseManaCost,
    required this.isEfficiency,
  });

  /// The commitment the PROOF attests, bound to the wire value by the
  /// `commitment_mismatch` check. Keys the turn-scoped certified maps and
  /// `lastCertifiedBaseManaCosts`.
  final String commitmentHex;

  /// Formulas, flat element sequence, and wild-magic triggers, all derived from
  /// the verified outputs. Consumed by resolution in place of `spell.formula`.
  final CertifiedCast semantics;

  /// `5×segmentCount + dotCount`, grown by `1.05^T × 1.5^effectCount`. Step 1
  /// of the mana chain, and the clean bestiary stat Sightings capture stores
  /// (docs/SIGHTINGS_PLAN.md §2).
  final int baseManaCost;

  /// The Efficiency (Water) claim, **after** it has been checked against this
  /// spell's own certified supreme-dominance zones. Carried because it is the
  /// one enhancement claim that changes a number: it feeds the −1/3 discount in
  /// the mana chain.
  ///
  /// Potency, Velocity and Mystery are checked here too, and just as strictly,
  /// but resolution reads them off the action itself — sound precisely because
  /// an unbacked claim never gets this far.
  final bool isEfficiency;
}

// ── Verifier ──────────────────────────────────────────────────────────────────

/// Verifies a peer's declared spell cast against its ZK proof, their committed
/// book, and their authenticated identity.
///
/// Constructed once per match from the trust wiring that cannot change mid-match
/// (verifier, keys, the peer's root and identity, their grants). Everything that
/// varies per call — the declaration, its membership path, the peer's current
/// draw schedule, the negotiated epoch — is an argument to [certifyPeerCast].
class PeerCastVerifier {
  PeerCastVerifier({
    required this.verifyProof,
    required this.vkBytes,
    required this.vkBytesForTier,
    required this.peerBookRoot,
    required this.peerOwnerPubkeyHex,
    required this.peerPermissions,
    required this.allowProoflessSpells,
  });

  /// FFI verifier. Null means verification is not wired up (solo/test), and
  /// every declaration comes back [PeerCastUncertified].
  final ProofVerifier? verifyProof;

  /// Match-wide fallback key, used when [vkBytesForTier] is null or has no
  /// entry for the tier being verified.
  final Uint8List? vkBytes;

  /// Per-tier key resolver. A single match-wide VK is not sufficient on its own:
  /// every spell is proven at the smallest tier covering its own T, so a tier-12
  /// proof presents 42 public inputs to a tier-24 VK expecting 66 and
  /// barretenberg rejects a perfectly legal cast.
  final Uint8List? Function(int tier)? vkBytesForTier;

  /// The peer's Merkle book root, received at handshake. Null in solo/test,
  /// where membership is not checked.
  final String? peerBookRoot;

  /// The peer's *authenticated* owner_pubkey — the result of a fresh-nonce
  /// Ed25519 challenge-response at handshake, NOT the unauthenticated value a
  /// proof merely declares (CLAUDE.md invariant 5: the circuit never verifies a
  /// signature). Null in solo/test; authorization is skipped.
  final String? peerOwnerPubkeyHex;

  /// Signed loan/transfer grants naming the peer as grantee, verified at
  /// handshake. Consulted when the peer casts a spell they do not own.
  final List<SpellPermission> peerPermissions;

  /// Dev flag (`kAllowProoflessSpells`): wave through a cast with NO proof
  /// bytes at all. A cast that *has* proof bytes is still fully verified.
  final bool allowProoflessSpells;

  /// Grids this peer has already cast this match. Lives here rather than in
  /// `TurnLoop` because "has this grid been spent" is a certification fact, not
  /// battle state: it is keyed on the CERTIFIED commitment and it never appears
  /// in `BattleState.toCanonicalBytes`.
  final _seenPeerCommitments = <String>{};

  /// The verification key for [tier], preferring the per-tier resolver and
  /// falling back to the single [vkBytes].
  Uint8List? _vkForTier(int tier) => vkBytesForTier?.call(tier) ?? vkBytes;

  /// The circuit tier a spell with [t] generations was proven at — the smallest
  /// tier covering it, exactly as `inscribeSpell` chose at proving time. Null
  /// when [t] is outside the circuit's supported range.
  ///
  /// [t] arrives on the wire and is therefore untrusted, but using it only to
  /// *select* a key is fail-closed: a wrong tier picks a VK the proof cannot
  /// satisfy. [certifyPeerCast] additionally re-checks the certified `outputs.t`
  /// against the claim, binding the value that chose the layout to the value the
  /// proof attests.
  static int? tierForSpell(int t) => tierForSteps(t);

  // ── The shared derivation (B-1 / B-8 single source of truth) ───────────────

  /// The full certified semantics of a cast, from its verified public outputs.
  ///
  /// The one derivation in the codebase. Both sides of the trust boundary call
  /// it — the peer path after [ProofIntake.verifyAndParse], the owner's own path
  /// after [ProofIntake.parseOwn] — so both devices produce byte-identical
  /// formulas, element sequences and wild-magic triggers for the same proof.
  static CertifiedCast semanticsOf(
    VerifiedSpellOutputs outputs,
    String communitySeed,
  ) {
    final formulas = TrajectoryParser.parse(outputs).formulas;
    return CertifiedCast(
      formulas: formulas,
      elementSequence: TrajectoryParser.certifiedElementSequence(outputs),
      wildMagic: WildMagic.triggersFor(outputs, formulas, communitySeed),
    );
  }

  /// Certified base mana cost: `5×segmentCount + dotCount`, grown by
  /// `1.05^T × 1.5^effectCount`.
  ///
  /// Step 1 of the modifier chain in
  /// `DeterministicResolution.certifiedManaCost`, kept
  /// separate so it cannot drift from the value Sightings capture stores
  /// (docs/SIGHTINGS_PLAN.md §2, "the clean bestiary stat" — every later step is
  /// a per-cast modifier, not intrinsic to the spell).
  ///
  /// NOTE(B-1, balance): the certified effectCount is tighter than the wire
  /// formula's for spells with residual activations. 4 activations = 1 complete
  /// formula + 1 residual: the wire gives effectCount 1, certified gives 0. The
  /// certified count is the correct trust boundary — the wire count was
  /// exploitable by padding the formula list.
  static int certifiedBaseManaCost(
    VerifiedSpellOutputs outputs,
    List<ParsedFormula> certFormulas,
  ) {
    final base = 5 * outputs.segmentCount + outputs.dotCount;
    final effectCount = max(0, certFormulas.length - 1);
    return (base * pow(1.05, outputs.t) * pow(1.5, effectCount)).round();
  }

  /// The certified semantics of a spell whose proof bytes this device already
  /// holds, parsed WITHOUT verification ([ProofIntake.parseOwn]).
  ///
  /// Authoritative for our own spell. For a peer's it is a *fallback*, used only
  /// when [certifyPeerCast] never ran (solo, or verification not wired up) — it
  /// parses without verifying, so it is no stronger than the bytes it was handed.
  /// When verification IS wired, the verified derivation always wins.
  ///
  /// Returns null when there are no proof bytes (the `kAllowProoflessSpells` dev
  /// flag) or they are malformed. Both devices see the same absence and fall
  /// back identically, so it is desync-SAFE even though it is not trust-safe.
  // TODO(B-1): the remaining hole is the kAllowProoflessSpells flag. Closing it
  //   means deleting the flag, then making a null CertifiedCast for a
  //   current-turn peer spell a forfeit rather than a wire-formula fallback.
  static CertifiedCast? certifyOwnProof(
    SpellAsset spell, {
    required String communitySeed,
  }) {
    if (spell.proofBytes.isEmpty) return null;
    try {
      // The spell's OWN tier, not the match ceiling — parsing at the wrong
      // tier_max reads the trajectory arrays at the wrong offsets and would
      // derive different formulas and wild-magic triggers than the peer does
      // from the same proof. The spell's recorded tier is authoritative; fall
      // back to deriving it from T for assets written before the field was
      // trustworthy.
      final ownTier = tierForSpell(spell.t) ?? spell.tier;
      return semanticsOf(
        ProofIntake.parseOwn(spell.proofBytes, ownTier),
        communitySeed,
      );
    } on ProofIntakeException {
      // A malformed local proof is a bug, not an attack; falling back is the
      // same outcome on both devices (they parse the same bytes).
      return null;
    }
  }

  // ── The peer path ─────────────────────────────────────────────────────────

  /// Verify a peer's declared spell cast and certify what it establishes.
  ///
  /// Checks, in the order they are reported:
  ///
  ///   1. Proof bytes present, the declared T covers a real circuit tier, a VK
  ///      exists for it, and the proof verifies and parses under that VK.
  ///   2. The certified `T`, `commitment` and `ruleset_version` match what the
  ///      wire declared and what the match negotiated.
  ///   3. The grid has not already been cast this match — unless it is a shipped
  ///      Basic spell or a Cantrip, either of which a chapter may legitimately
  ///      hold in unlimited copies. Keyed on VERIFIED outputs, never on the wire
  ///      values, and on the CERTIFIED element count for the Cantrip exemption.
  ///   4. Every cast-time enhancement claimed is backed by this spell's own
  ///      certified supreme-dominance zones.
  ///   5. The spell is a member of [peerBookRoot], at a position that is in the
  ///      peer's publicly-computed castable hand.
  ///   6. The authenticated caster owns the spell or holds a current grant for
  ///      it.
  ///
  /// [forcedCast] marks a reveal the peer did not choose to make (wild magic's
  /// Spontaneous Combustion). It exempts the reveal from the duplicate-grid
  /// guard: a forced cast must not consume that player's once-per-match right to
  /// cast the grid, nor trip the duplicate forfeit. Everything else applies
  /// unchanged.
  ///
  /// [peerDrawSchedule] is this device's public position-only bookkeeping for
  /// the peer, or null when it is not dealt yet — a local chapter-load race, not
  /// the peer's fault, so hand membership is skipped rather than failed.
  Future<PeerCastVerdict> certifyPeerCast(
    TurnAction action,
    MembershipProof? merkleProof, {
    required int rulesetVersion,
    required String communitySeed,
    required DrawSchedule? peerDrawSchedule,
    bool forcedCast = false,
  }) async {
    final verify = verifyProof;
    final bookRoot = peerBookRoot;
    if (verify == null || (vkBytes == null && vkBytesForTier == null)) {
      return const PeerCastUncertified(); // solo or verification not wired up
    }

    final SpellAsset spell;
    if (action is SpellCastAction) {
      spell = action.spell;
    } else if (action is MysterySpellCastAction) {
      spell = action.spell;
    } else {
      return const PeerCastUncertified();
    }

    // 1. Proof verification.
    if (spell.proofBytes.isEmpty) {
      // DEV FLAG (kAllowProoflessSpells — lib/dev_flags.dart): let a Spell Test
      // Lab spell through so effects can be exercised on two devices. Delete
      // this branch along with the flag.
      //
      // Nothing is charged here, and the caster's side doesn't charge either —
      // free-on-both-sides is the only option that can't desync. Nothing is
      // certified, so resolution falls back to `spell.formula`: the wire value,
      // which is also what the caster resolves from. Same source on both
      // devices, so effects and chain state agree. That fallback is exactly the
      // TODO(B-1) hole this flag leans on — closing that TODO means removing
      // this flag first.
      if (allowProoflessSpells) return const PeerCastUncertified();
      return const PeerCastRejected(
        'missing_spell_proof',
        'peer sent a spell cast with no proof bytes — match forfeit',
      );
    }
    // The tier this spell was PROVEN at, not the match's negotiated ceiling.
    // Getting this wrong is not a soft failure: the public-input count is
    // 10 + 2*tier_max (+8 for barretenberg's pairing-point object), so a
    // tier-12 proof checked against the tier-24 VK aborts in the backend with
    // "num_public_inputs mismatch with VK" (42 vs 66) and forfeits a duel that
    // was perfectly legal. Every cast whose T fell outside the match tier used
    // to break lockstep this way.
    final spellTier = tierForSpell(spell.t);
    if (spellTier == null) {
      return PeerCastRejected(
        'invalid_spell_tier',
        'peer spell declares T=${spell.t}, outside the circuit range '
            '(1..$kMaxInscribableSteps) — match forfeit',
      );
    }
    final vk = _vkForTier(spellTier);
    if (vk == null) {
      return PeerCastRejected(
        'missing_vk_for_tier',
        'no bundled verification key for tier $spellTier — match forfeit',
      );
    }
    final VerifiedSpellOutputs outputs;
    try {
      outputs = await ProofIntake.verifyAndParse(
        spell.proofBytes,
        vk,
        verify,
        spellTier,
      );
    } on ProofIntakeException catch (e) {
      return PeerCastRejected(
        'invalid_spell_proof',
        'peer spell proof rejected: $e',
      );
    }
    // Binds the wire-declared T (which selected the VK and the parse layout)
    // to the T the proof actually attests. Without this a peer could steer
    // tier selection with a value nothing checked.
    if (outputs.t != spell.t) {
      return PeerCastRejected(
        't_mismatch',
        'peer proof certifies T=${outputs.t} but the wire declared T=${spell.t}'
            ' — match forfeit',
      );
    }
    if (outputs.commitmentHex != spell.commitmentHex) {
      return PeerCastRejected(
        'commitment_mismatch',
        'peer proof commitmentHex ${outputs.commitmentHex} '
            'does not match wire value ${spell.commitmentHex} — match forfeit',
      );
    }
    // Binds the ruleset epoch the proof attests to the one this match
    // negotiated. [ProofIntake] has parsed `ruleset_version` since it was added,
    // but nothing read it: the field named itself a negotiated consensus
    // parameter while enforcing nothing.
    //
    // Defence-in-depth rather than a live hole — RULESET_VERSION is a circuit
    // global, so it is baked into each tier's verification key and a proof under
    // a different epoch cannot satisfy the bundled VK. That makes this
    // unreachable between honest clients on matched builds, which is exactly why
    // it must be explicit: the implicit guarantee evaporates the moment two VKs
    // are bundled, and a silent cross-epoch acceptance is the sort of thing a
    // version field exists to make impossible.
    if (outputs.rulesetVersion != rulesetVersion) {
      return PeerCastRejected(
        'ruleset_version_mismatch',
        'peer proof certifies ruleset_version ${outputs.rulesetVersion} but '
            'the match negotiated $rulesetVersion — match forfeit',
      );
    }

    // The certified semantics, derived once here and returned to the caller —
    // never re-derived downstream. Computed before the duplicate-grid check
    // because the Cantrip exemption needs the CERTIFIED element count, not the
    // peer-claimed `spell.formula.length`.
    final semantics = semanticsOf(outputs, communitySeed);
    final certFormulas = semantics.formulas;
    final List<BorderZone> certElementSequence = semantics.elementSequence;

    // 2. Duplicate grid detection — skipped for a shipped Basic spell or a
    // Cantrip (certified trajectory under kKinshipMinElements), either of which
    // may legitimately be cast more than once per match.
    if (!forcedCast &&
        !isBasicGridAndT(outputs.commitmentHex, outputs.t) &&
        !isCantripElementCount(certElementSequence.length) &&
        !_seenPeerCommitments.add(outputs.commitmentHex)) {
      return PeerCastRejected(
        'duplicate_spell_cast:${outputs.commitmentHex}',
        'peer cast the same grid twice — match forfeit '
            '(commitmentHex=${outputs.commitmentHex})',
      );
    }

    // 2b. Enhancement-claim verification. isPotent/isVelocity/isEfficiency (and
    // Mystery, implied by the action type itself) must each be backed by this
    // spell's own certified supreme-dominance zones — a peer cannot claim
    // Efficiency's mana discount (or Potency/Velocity's effect gating) on a
    // spell that never achieved supreme dominance in the matching zone.
    final certifiedTags = TrajectoryParser.certifiedSupremeTags(outputs);
    final claimsPotent = action is SpellCastAction
        ? action.isPotent
        : (action as MysterySpellCastAction).isPotent;
    final claimsVelocity = action is SpellCastAction
        ? action.isVelocity
        : (action as MysterySpellCastAction).isVelocity;
    final claimsEfficiency =
        action is SpellCastAction ? action.isEfficiency : false;
    final claimsMystery = action is MysterySpellCastAction;

    if ((claimsPotent && !certifiedTags.contains('fire')) ||
        (claimsVelocity && !certifiedTags.contains('air')) ||
        (claimsEfficiency && !certifiedTags.contains('water')) ||
        (claimsMystery && !certifiedTags.contains('earth'))) {
      return PeerCastRejected(
        'unbacked_enhancement_claim',
        'peer claimed a cast-time enhancement not backed by certified '
            'supreme-dominance data — match forfeit '
            '(commitmentHex=${spell.commitmentHex})',
      );
    }

    // 3. Book membership.
    if (bookRoot != null && merkleProof != null) {
      final proofWithRoot = MembershipProof(
        root: bookRoot,
        leafHex: merkleProof.leafHex,
        siblings: merkleProof.siblings,
        directions: merkleProof.directions,
      );
      if (!proofWithRoot.verify()) {
        return PeerCastRejected(
          'book_membership_failed',
          'peer spell ${spell.commitmentHex} is not a member of their '
              'committed book — match forfeit',
        );
      }

      // 3a. Hand membership (SPELL_DRAW_WIRING_PLAN.md §6). The Merkle path just
      // verified doesn't only prove chapter membership — its directions
      // authenticate *which* position was cast (proofWithRoot.leafIndex). That
      // position must be in the caster's publicly-computed in-hand set and not
      // withered. This is the "interim soft" enforcement §6 calls for: correct
      // against an honest client; a malicious client could still forge an
      // unsorted book tree (closed by the §7 sortedness circuit, not yet
      // landed). Skipped (not failed) when our own bookkeeping for the peer
      // isn't dealt yet — a local chapter-load race, not the peer's fault.
      if (peerDrawSchedule != null &&
          !peerDrawSchedule.isCastable(proofWithRoot.leafIndex)) {
        return PeerCastRejected(
          'cast_out_of_hand',
          'peer spell ${spell.commitmentHex} at position '
              '${proofWithRoot.leafIndex} is not in their castable hand '
              '— match forfeit',
        );
      }
    }

    // 3b. Cast authorization (BATTLE_AUTH_PLAN.md §4). The proof declares an
    // owner_pubkey (outputs.ownerPubkeyHex), but per CLAUDE.md invariant 5 the
    // circuit never proves the caster holds that key — a proof alone can declare
    // any owner. [peerOwnerPubkeyHex] is the peer's *authenticated* identity, so
    // this check is what actually stops a peer casting a spell they neither own
    // nor hold a grant for. Null in solo/test (no authenticated peer — skip).
    final authenticatedPeerPubkeyHex = peerOwnerPubkeyHex;
    if (authenticatedPeerPubkeyHex != null) {
      final authorized = await castingPlayerMayUse(
        spellOwnerPubkeyHex: outputs.ownerPubkeyHex,
        commitmentHex: outputs.commitmentHex,
        t: outputs.t,
        castingPlayerPubkeyHex: authenticatedPeerPubkeyHex,
        permissions: peerPermissions,
      );
      if (!authorized) {
        return PeerCastRejected(
          'unauthorized_spell:${outputs.commitmentHex}',
          'peer cast a spell they neither own nor hold a grant for '
              '(owner=${outputs.ownerPubkeyHex}, '
              'caster=$authenticatedPeerPubkeyHex) — match forfeit',
        );
      }
    }

    return PeerCastCertified(CertifiedPeerCast(
      commitmentHex: outputs.commitmentHex,
      semantics: semantics,
      baseManaCost: certifiedBaseManaCost(outputs, certFormulas),
      isEfficiency: claimsEfficiency,
    ));
  }
}
