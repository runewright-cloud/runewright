// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_authorization.dart — ownership and loan-permission checks.
//
// Three contexts:
//
//   localIdentityMayUse — call this before ChapterAsset.withEntry to enforce
//     that only owned or loaned spells enter a chapter.
//
//   castingPlayerMayUse — call this when an opponent declares a spellCast in
//     battle, given the SpellPermission records they transmitted at session start.
//     Each matching permission's signature is verified before granting access.
//     The exchange is wired through BattleSession.exchangeSpellPermissions
//     (BattleMsgType.spellPermissions), invoked from runDuelSetup step 5.
//
//   chapterEligibleForApprenticeLoan — call this before offering a chapter as
//     a Master/Apprentice loan (docs/MASTER_APPRENTICE_PLAN.md §2.1 decision
//     3, §5.2). Deliberately separate from localIdentityMayUse, which is
//     permissive by design (it lets a loaned-in spell enter your own chapter
//     for personal casting) — the apprentice-loan gate is the opposite: only
//     NATIVELY owned spells (or shipped Basic spells) may be lent onward, so
//     a master can't launder a spell they only hold on loan into a "new"
//     grant to someone else.

import '../identity/identity.dart';
import 'basic_spells.dart' show isBasicGridAndT, isBasicSpell;
import 'chapter_asset.dart' show ChapterAsset;
import 'spell_asset.dart';
import 'spell_permission.dart';

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

/// Returns true if [identity] may use [spell] — i.e., their Poseidon2 pubkey
/// matches [spell.ownerPubkeyHex], the spell is one of the shipped Basic
/// starter spells (docs/BASIC_SPELLS_PLAN.md — public grids anyone may use,
/// regardless of the owner_pubkey their proof happens to carry), or a
/// locally stored, currently-unexpired SpellPermission covers
/// [spell.commitmentHex] and names the identity as grantee.
///
/// Call this before [ChapterAsset.withEntry] to enforce the ownership gate.
///
/// Locally stored permissions' signatures are trusted without re-verifying —
/// they were verified when received and saved (see [SpellPermission.isSignatureValid]).
/// Expiry, however, is checked live against [now] (defaults to the current
/// UTC time) on every call: a day-limited loan must drop out of the usable
/// set the moment it lapses, not just when it was first saved.
Future<bool> localIdentityMayUse(SpellAsset spell, Identity identity, {DateTime? now}) async {
  if (isBasicSpell(spell)) return true;
  final myPubkeyHex = await identity.ownerPubkeyHex();
  if (_hexEq(spell.ownerPubkeyHex, myPubkeyHex)) return true;
  final perms = await SpellPermission.loadForCommitment(spell.commitmentHex);
  return perms.any(
    (p) =>
        _hexEq(p.granteePubkeyHex, myPubkeyHex) &&
        _hexEq(p.ownerPubkeyHex, spell.ownerPubkeyHex) &&
        !p.isExpired(now: now),
  );
}

/// Returns true if the player identified by [castingPlayerPubkeyHex] (their
/// circuit-level Poseidon2(key_hi, key_lo), extracted from their verified spell
/// proof) is authorized to cast a spell whose proof carries [spellOwnerPubkeyHex],
/// [commitmentHex], and generation count [t].
///
/// [commitmentHex] and [t] MUST come from the caster's VERIFIED proof public
/// inputs (ProofIntake/VerifiedSpellOutputs — proof_intake.dart ABI fields
/// [3] and [0]), never from a wire-decoded SpellAsset field the caster
/// transmitted unverified. [isBasicGridAndT] is checked against exactly those
/// two values for that reason: a peer fully controls every field of a
/// transmitted SpellAsset, but controls nothing inside a proof this function
/// has already verified. Widening this check to accept an unverified
/// commitment/T (e.g. from `spell.commitmentHex` before proof verification)
/// would let any peer claim any spell is Basic and bypass this gate entirely.
///
/// [permissions] are the SpellPermission records the casting player transmitted
/// at battle session start (via BattleSession.exchangeSpellPermissions). Each
/// candidate permission's signature and (for loans) expiry are checked via
/// [SpellPermission.isCurrentlyUsable] before authorization is granted. On the
/// solo/test path an empty list is passed — owned spells are still authorized
/// by the first branch.
Future<bool> castingPlayerMayUse({
  required String spellOwnerPubkeyHex,
  required String commitmentHex,
  required int t,
  required String castingPlayerPubkeyHex,
  required List<SpellPermission> permissions,
}) async {
  if (isBasicGridAndT(commitmentHex, t)) return true;
  if (_hexEq(spellOwnerPubkeyHex, castingPlayerPubkeyHex)) return true;
  for (final perm in permissions) {
    if (_hexEq(perm.commitmentHex, commitmentHex) &&
        _hexEq(perm.granteePubkeyHex, castingPlayerPubkeyHex) &&
        _hexEq(perm.ownerPubkeyHex, spellOwnerPubkeyHex) &&
        await perm.isCurrentlyUsable()) {
      return true;
    }
  }
  return false;
}

// ── Master/Apprentice chapter-loan eligibility ──────────────────────────────

/// Result of [chapterEligibleForApprenticeLoan]: whether the whole chapter
/// may be offered, and — for the picker UI's benefit, MASTER_APPRENTICE_PLAN
/// §6.3's "greyed out with the reason" treatment — one human-readable reason
/// per entry that failed.
class ChapterEligibility {
  const ChapterEligibility({required this.eligible, this.reasons = const []});

  final bool eligible;
  final List<String> reasons;
}

/// True iff every spell in [chapter] is either a shipped Basic spell (public
/// grids anyone may use — no grant is ever needed or emitted for them, see
/// apprentice_session.dart) or natively owned by [master]
/// (`spell.ownerPubkeyHex == master's own ownerPubkeyHex`) — never merely
/// usable via a loan or transfer grant.
///
/// This is a NEW, stricter gate than [localIdentityMayUse] — that check is
/// deliberately permissive (a loaned-in spell may enter your own chapter for
/// personal casting); reusing it here would let a master re-lend a spell
/// they themselves only hold on loan, laundering it into a "new" grant whose
/// expiry the original owner never agreed to. See this file's header
/// comment and docs/MASTER_APPRENTICE_PLAN.md §2.1 decision 3.
///
/// An empty chapter is ineligible ("nothing to teach"). Call this both in
/// the chapter picker AND immediately before signing grants — the same
/// belt-and-braces discipline `COMMUNE_TRADE_PLAN.md`'s offer-eligibility
/// filter uses.
Future<ChapterEligibility> chapterEligibleForApprenticeLoan({
  required ChapterAsset chapter,
  required List<SpellAsset> localSpells,
  required Identity master,
}) async {
  if (chapter.entries.isEmpty) {
    return const ChapterEligibility(eligible: false, reasons: ['nothing to teach']);
  }
  final byId = {for (final s in localSpells) s.id: s};
  final myOwnerPubkeyHex = await master.ownerPubkeyHex();
  final reasons = <String>[];

  for (final entry in chapter.entries) {
    final spell = byId[entry.spellId];
    if (spell == null) {
      reasons.add('spell no longer in library');
      continue;
    }
    if (isBasicSpell(spell)) continue;
    if (!_hexEq(spell.ownerPubkeyHex, myOwnerPubkeyHex)) {
      reasons.add("'${spell.name}' is held on loan, not owned");
    }
  }

  return ChapterEligibility(eligible: reasons.isEmpty, reasons: reasons);
}
