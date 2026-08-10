// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_identity.dart — the two things "kin" used to mean, now named apart
// (docs/COUNTER_CHARM_KINSHIP_PLAN.md §3.3, Phase 3).
//
// Before this, one value — the grid commitment — answered four different
// questions: are these two spells kin, does this loan cover this spell, which
// coat of arms does this spell wear, and which spell is this art for. Making
// kinship BEHAVIOURAL means those questions stop having the same answer, and
// conflating them becomes a bug rather than a shortcut:
//
//   * BEHAVIOURAL KINSHIP ([behaviouralKinKey]) — "these two spells do the
//     same thing." Deliberately many-to-one: that is the whole anti-optimum
//     mechanic. Correct for the kin-stacking forfeit and for heraldic arms.
//
//   * UNIQUE SPELL IDENTITY ([uniqueSpellId]) — "this exact spell." Must be
//     one-to-one. Correct for anything where matching the wrong spell grants
//     something: loan and transfer permissions above all.
//
// **Never key a permission to a kinship key.** Under behavioural kinship a
// grant that "covers all Kin spells" would extend to spells with different
// grids — potentially someone else's coincidentally-matching spell. That is
// privilege escalation, not a display quirk.
//
// Migration status: kin-stacking and arms are on [behaviouralKinKey] now.
// Permissions (spell_permission.dart) and art sync (trade/sync_art_session)
// still key to `commitmentHex`, which is a grid identity — one-to-one, and
// therefore still SOUND for their purpose. They move to [uniqueSpellId] in
// Phase 4, when deleting the commitment from the circuit forces it; doing it
// early would invalidate every outstanding grant's signature for no gain.

import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

// ── Behavioural kinship ──────────────────────────────────────────────────────

/// Trajectories shorter than this are exempt from kinship (§2.6).
///
/// 9 elements is 4⁹ ≈ 262,000 combinations; 3 elements is only 64. Without the
/// floor, short spells would collide constantly and forfeit players for
/// casting two genuinely different cheap spells.
///
/// The cost is that short spells are freely kin-stackable (§3.4, open question
/// 1). There is precedent — Basic Spells already carry a scoped kin-stacking
/// exemption — and short spells are weak. Run
/// `scripts/trajectory_histogram.dart` against a real corpus before treating
/// that as settled: on the five shipped basics alone, four of five are under
/// the threshold.
const int kKinshipMinElements = 9;

/// True iff a trajectory of [elementCount] elements is short enough to carry
/// the CANTRIP tag: two effects (an incantation) or a low stat-contributor
/// count (a summon), under [kKinshipMinElements]. The floor is the same one
/// kinship-exemption already uses — a Cantrip IS a kinship-exempt spell,
/// named here for what it means to a player (unlimited copies of it may be
/// added to one chapter) rather than for what it means to the anti-stacking
/// rule.
///
/// This replaces the old hardcoded allowlist ([isBasicSpell] in
/// `basic_spells.dart`) as the unlimited-copy rule: any spell this short
/// qualifies, not just the five shipped starters. [isBasicSpell] still gates
/// something else entirely — the OWNERSHIP bypass that lets a player cast a
/// shipped starter despite its proof carrying Soren's dev key, not theirs —
/// and stays scoped to exactly those five (grid, T) pairs; do not widen it to
/// this predicate, that would let anyone cast anyone else's short spell
/// without owning it or holding a grant.
bool isCantripElementCount(int elementCount) => elementCount < kKinshipMinElements;

/// The behavioural identity of a spell: what it does and what it costs.
///
/// Two spells are KIN when this is equal and non-null. Null means the spell is
/// exempt — its trajectory is shorter than [kKinshipMinElements] — and an
/// exempt spell is kin to nothing, including another exempt spell.
///
/// Keyed to the certified trajectory plus the spell's base mana cost, per
/// §3.3. Both are derivable from proof public inputs, so a peer's kin key can
/// be computed from data they cannot lie about: the trajectory from
/// `dominanceTrajectory`/`supremeDominanceFlags`/`t` via
/// `TrajectoryParser.certifiedElementSequence`, and the base cost from
/// `segment_count`/`dot_count`/`t` plus that same trajectory's effect count
/// (`TurnLoop._certifiedBaseManaCost`).
///
/// Keying to behaviour is what kills the throwaway-dot exploit: a dead dot
/// that never changes the trajectory no longer mints a "new" spell, so
/// escaping kinship means changing what the spell actually does.
///
/// [trajectory] is lowercase element names, matching `SpellAsset.formula`.
String? behaviouralKinKey({
  required List<String> trajectory,
  required int baseManaCost,
}) {
  if (trajectory.length < kKinshipMinElements) return null;
  final canonical = '${trajectory.map((e) => e.toLowerCase()).join(",")}'
      '|$baseManaCost';
  return _sha256Hex(utf8.encode('RWKIN1$canonical'));
}

/// The key a spell's heraldic coat of arms is generated from (§2.9).
///
/// Trajectory alone — NOT [behaviouralKinKey], and deliberately not gated by
/// [kKinshipMinElements]. Arms exist so kin are recognisable on sight, and
/// that visual tell should hold for short spells too even though they are
/// exempt from the kin-stacking rule. Keying arms to the kin key would give
/// every exempt spell either no arms or the same arms.
///
/// [fallbackHex] is used when [trajectory] is empty — a legacy asset with no
/// recorded formula. Passing the grid commitment there keeps such cards
/// visually distinct instead of collapsing them all onto one blank device.
String heraldicArmsKey(List<String> trajectory, {String fallbackHex = ''}) {
  if (trajectory.isEmpty) {
    return fallbackHex.isEmpty ? _sha256Hex(utf8.encode('RWARMS1')) : fallbackHex;
  }
  return _sha256Hex(
    utf8.encode('RWARMS1${trajectory.map((e) => e.toLowerCase()).join(",")}'),
  );
}

// ── Unique spell identity ────────────────────────────────────────────────────

/// The one-to-one identifier for a specific spell: `SHA-256(proofBytes)`.
///
/// Chosen over the grid commitment (§3.3) because it leaks nothing about the
/// grid, any holder of the proof can recompute it — loaned spells carry
/// `proofBytes` through `SpellAsset.withGridWithheld` — and it cannot be
/// claimed for a spell you do not own, since proofs are owner-bound at public
/// input index 1.
///
/// Deliberately NOT `SpellAsset.id`: that is self-asserted, and a recipient
/// cannot verify it ties to the actual spell.
///
/// One caveat to accept explicitly: UltraHonk proofs are randomised, so
/// **re-inscribing a spell changes its identifier**. That is why this is not
/// wired into permissions yet — see this file's header.
String uniqueSpellId(Uint8List proofBytes) => _sha256Hex(proofBytes);

// ── Kin-stacking reveal (§3.5) ───────────────────────────────────────────────

/// One player's kin-stacking reveal leaves, in the order [entries] were given.
///
/// The post-match reveal exists so an opponent can check ONE player's own list
/// for internal duplicates — kin-stacking. It used to reveal the raw sorted
/// commitment of every spell in your book, handing the opponent a stable,
/// cross-match identifier for spells you never even cast. Revealing raw
/// trajectories instead would be worse still: a trajectory is semantically
/// meaningful, so they would learn what your unplayed spells *do*.
///
/// So each leaf is `SHA-256(salt ‖ kinKey)` under a fresh per-match [salt].
/// Kin still collide, so kin-stacking is still detected; the opponent learns
/// neither the trajectory nor anything that correlates across matches. The
/// salt is never transmitted and the opponent never needs it — they only
/// compare leaves within the one list.
///
/// A kinship-exempt entry (null [SpellKinEntry.kinKey], i.e. a trajectory
/// under [kKinshipMinElements]) gets a fresh random leaf instead, so it can
/// never collide with anything. That is the exemption made concrete: short
/// spells are not checked for stacking. The two leaf kinds are
/// indistinguishable to the opponent — both are 32 opaque bytes.
List<String> kinStackingLeaves(
  List<SpellKinEntry> entries, {
  required Uint8List salt,
  Random? random,
}) {
  final rng = random ?? Random.secure();
  return [
    for (final entry in entries)
      if (entry.kinKey case final key?)
        _sha256Hex(Uint8List.fromList([...salt, ...utf8.encode(key)]))
      else
        _sha256Hex(
          Uint8List.fromList([
            ...salt,
            ...List<int>.generate(16, (_) => rng.nextInt(256)),
          ]),
        ),
  ];
}

/// One book entry's contribution to [kinStackingLeaves].
class SpellKinEntry {
  const SpellKinEntry(this.kinKey);

  /// [behaviouralKinKey] for this spell, or null if it is kinship-exempt.
  final String? kinKey;
}

/// A fresh per-match salt for [kinStackingLeaves]. 32 bytes from
/// [Random.secure]; never transmitted.
Uint8List newKinRevealSalt([Random? random]) {
  final rng = random ?? Random.secure();
  return Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
}

// ── Internals ────────────────────────────────────────────────────────────────

String _sha256Hex(List<int> bytes) =>
    '0x${sha256.convert(bytes).bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join()}';
