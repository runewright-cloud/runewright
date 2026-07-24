// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_permission_test.dart — the loan/transfer grant primitive. Covers
// the V2 signed-message contract (docs/COMMUNE_TRADE_PLAN.md §4.1): kind and
// expiresAt are inside the signed message, so tampering either on disk must
// break the signature, and a loan must become unusable at its expiry moment.
//
// Needs the real FFI bridge (Poseidon2, via Identity.ownerPubkeyMatches) --
// run with `flutter test`, not `dart test`.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/spells/spell_asset.dart';
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

  group('constructor invariant', () {
    test('loan without expiresAt throws', () async {
      final owner = await Identity.ephemeral();
      final ownerPubkeyHex = await owner.ownerPubkeyHex();
      expect(
        () => SpellPermission(
          id: '1',
          grantedAt: DateTime.now().toUtc(),
          commitmentHex: '0xaabbcc',
          ownerPubkeyHex: ownerPubkeyHex,
          ownerRawPubkeyBase64: 'irrelevant',
          granteePubkeyHex: '0xdead',
          signatureBase64: 'irrelevant',
          kind: SpellGrantKind.loan,
        ),
        throwsArgumentError,
      );
    });

    test('transfer with expiresAt throws', () async {
      final owner = await Identity.ephemeral();
      final ownerPubkeyHex = await owner.ownerPubkeyHex();
      expect(
        () => SpellPermission(
          id: '1',
          grantedAt: DateTime.now().toUtc(),
          commitmentHex: '0xaabbcc',
          ownerPubkeyHex: ownerPubkeyHex,
          ownerRawPubkeyBase64: 'irrelevant',
          granteePubkeyHex: '0xdead',
          signatureBase64: 'irrelevant',
          kind: SpellGrantKind.transfer,
          expiresAt: DateTime.now().toUtc(),
        ),
        throwsArgumentError,
      );
    });
  });

  group('createAndSign', () {
    test('throws if ownerIdentity does not own the spell', () async {
      final owner = await Identity.ephemeral();
      final impostor = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final granteePubkeyHex = await (await Identity.ephemeral()).ownerPubkeyHex();

      expect(
        () => SpellPermission.createAndSign(
          spell: spell,
          ownerIdentity: impostor,
          granteePubkeyHex: granteePubkeyHex,
          kind: SpellGrantKind.loan,
          expiresAt: DateTime.now().toUtc().add(const Duration(days: 3)),
        ),
        throwsArgumentError,
      );
    });

    test('a valid loan is usable by the grantee before expiry', () async {
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

      expect(perm.kind, SpellGrantKind.loan);
      expect(await perm.isSignatureValid(), isTrue);
      expect(perm.isExpired(now: expiresAt.subtract(const Duration(seconds: 1))), isFalse);
      expect(await perm.isCurrentlyUsable(now: expiresAt.subtract(const Duration(seconds: 1))), isTrue);
    });

    test('a loan is unusable at and after its expiry moment', () async {
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

      expect(perm.isExpired(now: expiresAt), isTrue);
      expect(perm.isExpired(now: expiresAt.add(const Duration(days: 1))), isTrue);
      expect(await perm.isCurrentlyUsable(now: expiresAt), isFalse);
    });

    test('a transfer grant never expires', () async {
      final owner = await Identity.ephemeral();
      final grantee = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final granteePubkeyHex = await grantee.ownerPubkeyHex();

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: granteePubkeyHex,
        kind: SpellGrantKind.transfer,
        provenance: [ProvenanceStep(pubkeyHex: await owner.ownerPubkeyHex(), at: DateTime.utc(2026, 1, 1))],
      );

      expect(perm.expiresAt, isNull);
      expect(perm.isExpired(now: DateTime.utc(3000, 1, 1)), isFalse);
      expect(await perm.isCurrentlyUsable(now: DateTime.utc(3000, 1, 1)), isTrue);
      expect(perm.provenance, hasLength(1));
    });
  });

  group('tamper resistance', () {
    test('editing expiresAt on the stored JSON invalidates the signature', () async {
      final owner = await Identity.ephemeral();
      final grantee = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final granteePubkeyHex = await grantee.ownerPubkeyHex();

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: granteePubkeyHex,
        kind: SpellGrantKind.loan,
        expiresAt: DateTime.utc(2026, 7, 20),
      );

      final tamperedJson = perm.toJson();
      tamperedJson['expiresAt'] = DateTime.utc(2099, 1, 1).toIso8601String();
      final tampered = SpellPermission.fromJson(tamperedJson);

      expect(await tampered.isSignatureValid(), isFalse);
    });

    test('editing granteePubkeyHex on the stored JSON invalidates the signature', () async {
      final owner = await Identity.ephemeral();
      final grantee = await Identity.ephemeral();
      final thief = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final granteePubkeyHex = await grantee.ownerPubkeyHex();
      final thiefPubkeyHex = await thief.ownerPubkeyHex();

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: granteePubkeyHex,
        kind: SpellGrantKind.loan,
        expiresAt: DateTime.utc(2026, 7, 20),
      );

      final tamperedJson = perm.toJson();
      tamperedJson['granteePubkeyHex'] = thiefPubkeyHex;
      final tampered = SpellPermission.fromJson(tamperedJson);

      expect(await tampered.isSignatureValid(), isFalse);
    });

    test('editing kind on the stored JSON invalidates the signature', () async {
      final owner = await Identity.ephemeral();
      final grantee = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final granteePubkeyHex = await grantee.ownerPubkeyHex();

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: granteePubkeyHex,
        kind: SpellGrantKind.loan,
        expiresAt: DateTime.utc(2026, 7, 20),
      );

      // Simulate a forged "upgrade" to a perpetual transfer by dropping
      // expiresAt and flipping kind -- must not verify.
      final tamperedJson = perm.toJson()
        ..remove('expiresAt')
        ..['kind'] = SpellGrantKind.transfer.name;
      final tampered = SpellPermission.fromJson(tamperedJson);

      expect(await tampered.isSignatureValid(), isFalse);
    });
  });

  group('serialization', () {
    test('toJson/fromJson round-trips kind, expiresAt, and provenance', () async {
      final owner = await Identity.ephemeral();
      final grantee = await Identity.ephemeral();
      final spell = await ownedSpell(owner);
      final granteePubkeyHex = await grantee.ownerPubkeyHex();
      final ownerPubkeyHex = await owner.ownerPubkeyHex();

      final perm = await SpellPermission.createAndSign(
        spell: spell,
        ownerIdentity: owner,
        granteePubkeyHex: granteePubkeyHex,
        kind: SpellGrantKind.transfer,
        provenance: [ProvenanceStep(pubkeyHex: ownerPubkeyHex, at: DateTime.utc(2026, 1, 1))],
      );

      final restored = SpellPermission.fromJson(perm.toJson());
      expect(restored.kind, SpellGrantKind.transfer);
      expect(restored.expiresAt, isNull);
      expect(restored.provenance, hasLength(1));
      expect(restored.provenance.first.pubkeyHex, ownerPubkeyHex);
      expect(await restored.isSignatureValid(), isTrue);
    });

    test('save()/loadForCommitment() round-trips through disk', () async {
      final owner = await Identity.ephemeral();
      final grantee = await Identity.ephemeral();
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

      final loaded = await SpellPermission.loadForCommitment(spell.commitmentHex);
      expect(loaded, hasLength(1));
      expect(loaded.first.id, perm.id);
      expect(loaded.first.kind, SpellGrantKind.loan);
      expect(await loaded.first.isSignatureValid(), isTrue);
    });
  });
}
