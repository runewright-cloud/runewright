// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_authorization_test.dart — localIdentityMayUse: the chapter-inclusion
// gate. Covers ownership, an unexpired loan, an expired loan (must reject),
// and a perpetual transfer grant.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/spells/basic_spells.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_authorization.dart';
import 'package:rune_duel/spells/spell_permission.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

import 'fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<SpellAsset> ownedSpell(Identity owner) async {
    final ownerPubkeyHex = await owner.ownerPubkeyHex();
    return SpellAsset(
      id: 'spell-1',
      createdAt: DateTime.utc(2026, 6, 19),
      tier: 12,
      t: 5,
      ownerPubkeyHex: ownerPubkeyHex,
      manaCost: 10,
      segmentCount: 1,
      dotCount: 0,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3]),
      name: 'Ember Wake',
      commitmentHex: '0xaabbcc',
      spellHashHex: '0xddeeff',
    );
  }

  test('the owner may always use their own spell', () async {
    final owner = await Identity.ephemeral();
    final spell = await ownedSpell(owner);
    expect(await localIdentityMayUse(spell, owner), isTrue);
  });

  test('a stranger with no permission may not use the spell', () async {
    final owner = await Identity.ephemeral();
    final stranger = await Identity.ephemeral();
    final spell = await ownedSpell(owner);
    expect(await localIdentityMayUse(spell, stranger), isFalse);
  });

  test('a grantee with a valid unexpired loan may use the spell', () async {
    final owner = await Identity.ephemeral();
    final grantee = await Identity.ephemeral();
    final spell = await ownedSpell(owner);
    final granteePubkeyHex = await grantee.ownerPubkeyHex();
    final expiresAt = DateTime.utc(2026, 7, 20);

    final perm = await SpellPermission.createAndSign(
      spell: spell,
      ownerIdentity: owner,
      granteePubkeyHex: granteePubkeyHex,
      kind: SpellGrantKind.loan,
      expiresAt: expiresAt,
    );
    await perm.save();

    expect(
      await localIdentityMayUse(spell, grantee, now: expiresAt.subtract(const Duration(seconds: 1))),
      isTrue,
    );
  });

  test('a grantee is rejected once the loan has expired, even though the permission is still saved', () async {
    final owner = await Identity.ephemeral();
    final grantee = await Identity.ephemeral();
    final spell = await ownedSpell(owner);
    final granteePubkeyHex = await grantee.ownerPubkeyHex();
    final expiresAt = DateTime.utc(2026, 7, 20);

    final perm = await SpellPermission.createAndSign(
      spell: spell,
      ownerIdentity: owner,
      granteePubkeyHex: granteePubkeyHex,
      kind: SpellGrantKind.loan,
      expiresAt: expiresAt,
    );
    await perm.save();

    expect(await localIdentityMayUse(spell, grantee, now: expiresAt), isFalse);
    expect(await localIdentityMayUse(spell, grantee, now: expiresAt.add(const Duration(days: 1))), isFalse);
  });

  test('a grantee with a perpetual transfer grant may use the spell indefinitely', () async {
    final owner = await Identity.ephemeral();
    final grantee = await Identity.ephemeral();
    final spell = await ownedSpell(owner);
    final granteePubkeyHex = await grantee.ownerPubkeyHex();

    final perm = await SpellPermission.createAndSign(
      spell: spell,
      ownerIdentity: owner,
      granteePubkeyHex: granteePubkeyHex,
      kind: SpellGrantKind.transfer,
    );
    await perm.save();

    expect(await localIdentityMayUse(spell, grantee, now: DateTime.utc(3000, 1, 1)), isTrue);
  });

  test('a loan naming a different grantee does not authorize this identity', () async {
    final owner = await Identity.ephemeral();
    final grantee = await Identity.ephemeral();
    final outsider = await Identity.ephemeral();
    final spell = await ownedSpell(owner);
    final granteePubkeyHex = await grantee.ownerPubkeyHex();

    final perm = await SpellPermission.createAndSign(
      spell: spell,
      ownerIdentity: owner,
      granteePubkeyHex: granteePubkeyHex,
      kind: SpellGrantKind.loan,
      expiresAt: DateTime.utc(2026, 7, 20),
    );
    await perm.save();

    expect(await localIdentityMayUse(spell, outsider, now: DateTime.utc(2026, 7, 19)), isFalse);
  });

  // ── Basic spell exemption ───────────────────────────────────────────────────
  //
  // docs/BASIC_SPELLS_PLAN.md: the five shipped starter spells are
  // authorized for everyone regardless of the owner_pubkey their bundled
  // proof carries (that pubkey belongs to whoever originally inscribed and
  // shipped them, not the player using them).

  test('a stranger may use a bundled Basic spell with no permission at all', () async {
    final firebolt = kBasicSpells.firstWhere((e) => e.slug == 'basic_firebolt');
    final spell = SpellAsset(
      id: firebolt.slug,
      createdAt: DateTime.utc(2026, 7, 27),
      tier: 12,
      t: firebolt.t,
      ownerPubkeyHex: '0x${'9' * 64}', // some other player's dev key, not this identity's
      manaCost: 13,
      segmentCount: 2,
      dotCount: 0,
      initialGrid: List<int>.filled(469, 0),
      proofBytes: Uint8List.fromList([1, 2, 3]),
      name: firebolt.name,
      commitmentHex: firebolt.commitmentHex,
      spellHashHex: firebolt.spellHashHex,
    );
    final stranger = await Identity.ephemeral();
    expect(await localIdentityMayUse(spell, stranger), isTrue);
  });

  // ── usableGrantFor — the same predicate, with the grant it matched ─────────
  //
  // The Library's per-spell marker needs to distinguish "loaned to you, 4 days
  // left" from "you cannot cast this", which the boolean gate can't express.
  // These pin that it stays the SAME predicate: a Library that disagrees with
  // the duel about what is castable is worse than one that says nothing.

  group('usableGrantFor', () {
    test('returns null for a stranger with no grant', () async {
      final owner = await Identity.ephemeral();
      final stranger = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      expect(
        await usableGrantFor(
          spell: spell,
          granteePubkeyHex: await stranger.ownerPubkeyHex(),
        ),
        isNull,
      );
    });

    test('returns the loan grant, with its expiry, while it is current',
        () async {
      final owner = await Identity.ephemeral();
      final grantee = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final granteePubkeyHex = await grantee.ownerPubkeyHex();
      final expiresAt = DateTime.utc(2026, 7, 20);

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: granteePubkeyHex,
        kind: SpellGrantKind.loan,
        expiresAt: expiresAt,
      );
      await perm.save();

      final found = await usableGrantFor(
        spell: spell,
        granteePubkeyHex: granteePubkeyHex,
        now: expiresAt.subtract(const Duration(days: 4)),
      );
      expect(found, isNotNull);
      expect(found!.kind, SpellGrantKind.loan);
      expect(found.expiresAt, expiresAt);
    });

    test('returns null once the loan lapses — the marker must flip to '
        'uncastable the moment it expires, not at next launch', () async {
      final owner = await Identity.ephemeral();
      final grantee = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final granteePubkeyHex = await grantee.ownerPubkeyHex();
      final expiresAt = DateTime.utc(2026, 7, 20);

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: granteePubkeyHex,
        kind: SpellGrantKind.loan,
        expiresAt: expiresAt,
      );
      await perm.save();

      expect(
        await usableGrantFor(
          spell: spell,
          granteePubkeyHex: granteePubkeyHex,
          now: expiresAt,
        ),
        isNull,
      );
    });

    test('a transfer grant is perpetual and carries no expiry label', () async {
      final owner = await Identity.ephemeral();
      final grantee = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final granteePubkeyHex = await grantee.ownerPubkeyHex();

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: granteePubkeyHex,
        kind: SpellGrantKind.transfer,
      );
      await perm.save();

      final found = await usableGrantFor(
        spell: spell,
        granteePubkeyHex: granteePubkeyHex,
        now: DateTime.utc(2099),
      );
      expect(found, isNotNull);
      expect(found!.kind, SpellGrantKind.transfer);
      expect(found.expiresAt, isNull);
    });

    test('agrees with localIdentityMayUse on every case above', () async {
      final owner = await Identity.ephemeral();
      final grantee = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final granteePubkeyHex = await grantee.ownerPubkeyHex();
      final expiresAt = DateTime.utc(2026, 7, 20);

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: granteePubkeyHex,
        kind: SpellGrantKind.loan,
        expiresAt: expiresAt,
      );
      await perm.save();

      for (final now in [
        expiresAt.subtract(const Duration(days: 1)),
        expiresAt,
      ]) {
        expect(
          await usableGrantFor(
                spell: spell,
                granteePubkeyHex: granteePubkeyHex,
                now: now,
              ) !=
              null,
          await localIdentityMayUse(spell, grantee, now: now),
          reason: 'the marker and the gate must never disagree (now=$now)',
        );
      }
    });
  });

  // ── castingPlayerMayUse — the battle cast-authorization gate ────────────────
  //
  // Same authorization rule as localIdentityMayUse, but driven by proof-derived
  // hex strings (spellOwnerPubkeyHex, castingPlayerPubkeyHex) rather than a
  // local Identity, and by an explicitly-passed permissions list rather than
  // disk-loaded ones — this is what BATTLE_AUTH_PLAN.md §4 wires into
  // TurnLoop._verifyPeerSpellCast, gated on the *authenticated* peer pubkey
  // from the handshake (never an unauthenticated wire value).

  group('castingPlayerMayUse', () {
    test('the owner may cast their own spell (no permissions needed)', () async {
      final owner = await Identity.ephemeral();
      final ownerPubkeyHex = await owner.ownerPubkeyHex();
      expect(
        await castingPlayerMayUse(
          spellOwnerPubkeyHex: ownerPubkeyHex,
          commitmentHex: '0xaabbcc',
          t: 5,
          castingPlayerPubkeyHex: ownerPubkeyHex,
          permissions: const [],
        ),
        isTrue,
      );
    });

    test('a caster with no grant may not cast a foreign-owned spell', () async {
      final owner = await Identity.ephemeral();
      final caster = await Identity.ephemeral();
      final ownerPubkeyHex = await owner.ownerPubkeyHex();
      final casterPubkeyHex = await caster.ownerPubkeyHex();
      expect(
        await castingPlayerMayUse(
          spellOwnerPubkeyHex: ownerPubkeyHex,
          commitmentHex: '0xaabbcc',
          t: 5,
          castingPlayerPubkeyHex: casterPubkeyHex,
          permissions: const [],
        ),
        isFalse,
      );
    });

    test('a caster holding a valid loan grant naming them may cast', () async {
      final owner = await Identity.ephemeral();
      final caster = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final casterPubkeyHex = await caster.ownerPubkeyHex();
      final expiresAt = DateTime.utc(2030, 1, 1);

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: casterPubkeyHex,
        kind: SpellGrantKind.loan,
        expiresAt: expiresAt,
      );

      expect(
        await castingPlayerMayUse(
          spellOwnerPubkeyHex: spell.ownerPubkeyHex,
          commitmentHex: spell.commitmentHex,
          t: 5,
          castingPlayerPubkeyHex: casterPubkeyHex,
          permissions: [perm],
        ),
        isTrue,
      );
    });

    test('an expired loan grant does not authorize the cast', () async {
      final owner = await Identity.ephemeral();
      final caster = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final casterPubkeyHex = await caster.ownerPubkeyHex();
      // castingPlayerMayUse -> isCurrentlyUsable() has no injectable clock (it
      // checks the real wall time), so use a date safely in the past for any
      // real test run rather than a fixed "future" date relative to today.
      final expiresAt = DateTime.utc(2020, 1, 1);

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: casterPubkeyHex,
        kind: SpellGrantKind.loan,
        expiresAt: expiresAt,
      );

      expect(
        await castingPlayerMayUse(
          spellOwnerPubkeyHex: spell.ownerPubkeyHex,
          commitmentHex: spell.commitmentHex,
          t: 5,
          castingPlayerPubkeyHex: casterPubkeyHex,
          permissions: [perm],
        ),
        isFalse,
      );
    });

    test('a grant naming a different grantee does not authorize this caster', () async {
      final owner = await Identity.ephemeral();
      final grantee = await Identity.ephemeral();
      final impostor = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final granteePubkeyHex = await grantee.ownerPubkeyHex();
      final impostorPubkeyHex = await impostor.ownerPubkeyHex();

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: granteePubkeyHex,
        kind: SpellGrantKind.loan,
        expiresAt: DateTime.utc(2026, 7, 20),
      );

      expect(
        await castingPlayerMayUse(
          spellOwnerPubkeyHex: spell.ownerPubkeyHex,
          commitmentHex: spell.commitmentHex,
          t: 5,
          castingPlayerPubkeyHex: impostorPubkeyHex,
          permissions: [perm],
        ),
        isFalse,
      );
    });

    test('a forged grant (tampered signature) does not authorize the cast', () async {
      final owner = await Identity.ephemeral();
      final caster = await Identity.ephemeral();
      final forger = await Identity.ephemeral(); // signs, but isn't the spell owner
      final spell = await ownedSpell(owner);
      final casterPubkeyHex = await caster.ownerPubkeyHex();

      // forger signs a grant claiming to be `owner` by hand-constructing the
      // record (bypassing createAndSign's owner-identity check) with a
      // signature that does not correspond to spell.ownerPubkeyHex.
      final forgedSigBytes = await forger.sign(utf8.encode('not the real message'));
      final forged = SpellPermission(
        id: 'forged-1',
        grantedAt: DateTime.utc(2026, 7, 1),
        commitmentHex: spell.commitmentHex,
        ownerPubkeyHex: spell.ownerPubkeyHex,
        ownerRawPubkeyBase64: base64Encode(forger.publicKeyBytes),
        granteePubkeyHex: casterPubkeyHex,
        signatureBase64: base64Encode(forgedSigBytes),
        kind: SpellGrantKind.loan,
        expiresAt: DateTime.utc(2026, 7, 20),
      );

      expect(
        await castingPlayerMayUse(
          spellOwnerPubkeyHex: spell.ownerPubkeyHex,
          commitmentHex: spell.commitmentHex,
          t: 5,
          castingPlayerPubkeyHex: casterPubkeyHex,
          permissions: [forged],
        ),
        isFalse,
      );
    });

    test('a grant for a different commitmentHex does not authorize this spell', () async {
      final owner = await Identity.ephemeral();
      final caster = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final casterPubkeyHex = await caster.ownerPubkeyHex();

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: casterPubkeyHex,
        kind: SpellGrantKind.loan,
        expiresAt: DateTime.utc(2026, 7, 20),
      );

      expect(
        await castingPlayerMayUse(
          spellOwnerPubkeyHex: spell.ownerPubkeyHex,
          commitmentHex: '0x99887766', // valid hex, but ≠ spell.commitmentHex
          t: 5,
          castingPlayerPubkeyHex: casterPubkeyHex,
          permissions: [perm],
        ),
        isFalse,
      );
    });

    // ── Basic spell exemption — the trust-boundary-critical cases ──────────

    test('a peer with no grant may cast a Basic spell (its own owner_pubkey, unauthenticated)', () async {
      final firebolt = kBasicSpells.firstWhere((e) => e.slug == 'basic_firebolt');
      final caster = await Identity.ephemeral();
      final casterPubkeyHex = await caster.ownerPubkeyHex();

      expect(
        await castingPlayerMayUse(
          // The bundled proof's real owner — some other player's dev key,
          // never this caster's.
          spellOwnerPubkeyHex: '0x${'9' * 64}',
          commitmentHex: firebolt.commitmentHex,
          t: firebolt.t,
          castingPlayerPubkeyHex: casterPubkeyHex,
          permissions: const [],
        ),
        isTrue,
      );
    });

    test('a Basic grid at the WRONG T (i.e. NOT the certified proof output) is not exempt', () async {
      final firebolt = kBasicSpells.firstWhere((e) => e.slug == 'basic_firebolt');
      final caster = await Identity.ephemeral();
      final casterPubkeyHex = await caster.ownerPubkeyHex();

      expect(
        await castingPlayerMayUse(
          spellOwnerPubkeyHex: '0x${'9' * 64}',
          commitmentHex: firebolt.commitmentHex,
          t: firebolt.t + 1, // a real proof at this T would never be Basic Firebolt
          castingPlayerPubkeyHex: casterPubkeyHex,
          permissions: const [],
        ),
        isFalse,
      );
    });

    test(
      'a peer cannot bypass authorization by claiming a non-Basic proof is Basic '
      '(commitmentHex/t MUST come from verified proof outputs, never a wire claim)',
      () async {
        // This is the exact attack the Basic exemption must not enable: a
        // peer casts a spell they neither own nor hold a grant for, whose
        // REAL verified proof commitment/T is some arbitrary foreign grid —
        // not one of the five registered Basic pairs. If a caller ever wired
        // this check to an unverified, peer-supplied "this is Basic" claim
        // instead of the verified proof's own commitment/T, this is the case
        // that would start passing.
        final owner = await Identity.ephemeral();
        final caster = await Identity.ephemeral();
        final ownerPubkeyHex = await owner.ownerPubkeyHex();
        final casterPubkeyHex = await caster.ownerPubkeyHex();

        expect(
          await castingPlayerMayUse(
            spellOwnerPubkeyHex: ownerPubkeyHex,
            commitmentHex: '0xdeadbeef', // NOT one of kBasicSpells' commitments
            t: 5,
            castingPlayerPubkeyHex: casterPubkeyHex,
            permissions: const [],
          ),
          isFalse,
        );
      },
    );
  });
}
