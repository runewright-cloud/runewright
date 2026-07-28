// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_authorization.dart — ownership and loan-permission checks.
//
// Two contexts:
//
//   localIdentityMayUse — call this before ChapterAsset.withEntry to enforce
//     that only owned or loaned spells enter a chapter.
//
//   castingPlayerMayUse — call this when an opponent declares a spellCast in
//     battle, given the SpellPermission records they transmitted at session start.
//     Each matching permission's signature is verified before granting access.
//     The exchange is wired through BattleSession.exchangeSpellPermissions
//     (BattleMsgType.spellPermissions), invoked from runDuelSetup step 5.

import '../identity/identity.dart';
import 'basic_spells.dart' show isBasicGridAndT, isBasicSpell;
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
