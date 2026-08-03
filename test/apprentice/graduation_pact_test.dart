// SPDX-License-Identifier: GPL-3.0-or-later
//
// graduation_pact_test.dart — GraduationPact/SignedGraduationPact
// (docs/MASTER_APPRENTICE_PLAN.md §7.2/§7.5): the pre-agreed, both-signed
// terms of a graduation battle. Covers canonical-message order-independence
// (both sides must build identical bytes regardless of collection order),
// tampering invalidating signatures, and persistence.
//
// Needs the real FFI bridge (Poseidon2, via Identity.ownerPubkeyMatches) --
// run with `flutter test`, not `dart test`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/apprentice/graduation_pact.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

import '../spells/fake_path_provider.dart';

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

  Future<GraduationPact> samplePact(Identity master, Identity apprentice) async {
    return GraduationPact(
      pactIdHex: generatePactIdHex(),
      masterPubkeyHex: await master.ownerPubkeyHex(),
      apprenticePubkeyHex: await apprentice.ownerPubkeyHex(),
      chapterName: 'Starter Chapter',
      chapterCommitments: ['0xaa1122', '0xbb3344'],
      stakeCommitments: ['0xcc5566'],
      agreedAt: DateTime.utc(2026, 7, 30),
    );
  }

  test('generatePactIdHex produces distinct, 32-hex-char (16-byte) ids', () {
    final a = generatePactIdHex();
    final b = generatePactIdHex();
    expect(a, isNot(equals(b)));
    expect(a.startsWith('0x'), isTrue);
    expect(a.length, 2 + 32);
  });

  group('canonical message', () {
    test('is stable regardless of commitment list order', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final pactId = generatePactIdHex();
      final agreedAt = DateTime.utc(2026, 7, 30);

      final a = GraduationPact(
        pactIdHex: pactId,
        masterPubkeyHex: await master.ownerPubkeyHex(),
        apprenticePubkeyHex: await apprentice.ownerPubkeyHex(),
        chapterName: 'Starter Chapter',
        chapterCommitments: ['0xaa1122', '0xbb3344'],
        stakeCommitments: ['0xcc5566', '0xdd7788'],
        agreedAt: agreedAt,
      );
      final b = GraduationPact(
        pactIdHex: pactId,
        masterPubkeyHex: await master.ownerPubkeyHex(),
        apprenticePubkeyHex: await apprentice.ownerPubkeyHex(),
        chapterName: 'Starter Chapter', // not part of the signed message at all
        chapterCommitments: ['0xbb3344', '0xaa1122'], // reversed
        stakeCommitments: ['0xdd7788', '0xcc5566'], // reversed
        agreedAt: agreedAt,
      );
      expect(a.canonicalMessage, equals(b.canonicalMessage));
    });

    test('an empty stakeCommitments list is legal and produces a stable message', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final pact = GraduationPact(
        pactIdHex: generatePactIdHex(),
        masterPubkeyHex: await master.ownerPubkeyHex(),
        apprenticePubkeyHex: await apprentice.ownerPubkeyHex(),
        chapterName: 'Starter Chapter',
        chapterCommitments: ['0xaa1122'],
        stakeCommitments: const [],
        agreedAt: DateTime.utc(2026, 7, 30),
      );
      expect(pact.canonicalMessage, isNotEmpty);
    });
  });

  group('signing and validation', () {
    test('a pact signed by both parties is fully valid', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final pact = await samplePact(master, apprentice);

      var signed = await SignedGraduationPact.proposedByMaster(pact: pact, masterIdentity: master);
      expect(signed.isFullySigned, isFalse);
      expect(await signed.isMasterSignatureValid(), isTrue);

      signed = await signed.signedByApprentice(apprenticeIdentity: apprentice);
      expect(signed.isFullySigned, isTrue);
      expect(await signed.isFullyValid(), isTrue);
    });

    test('tampering stakeCommitments after both signatures invalidates both', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final pact = await samplePact(master, apprentice);
      var signed = await SignedGraduationPact.proposedByMaster(pact: pact, masterIdentity: master);
      signed = await signed.signedByApprentice(apprenticeIdentity: apprentice);

      final tamperedPact = GraduationPact(
        pactIdHex: pact.pactIdHex,
        masterPubkeyHex: pact.masterPubkeyHex,
        apprenticePubkeyHex: pact.apprenticePubkeyHex,
        chapterName: pact.chapterName,
        chapterCommitments: pact.chapterCommitments,
        stakeCommitments: [...pact.stakeCommitments, '0xffffff'], // added a stake after signing
        agreedAt: pact.agreedAt,
      );
      final tampered = SignedGraduationPact(
        pact: tamperedPact,
        masterSignatureBase64: signed.masterSignatureBase64,
        masterRawPubkeyBase64: signed.masterRawPubkeyBase64,
        apprenticeSignatureBase64: signed.apprenticeSignatureBase64,
        apprenticeRawPubkeyBase64: signed.apprenticeRawPubkeyBase64,
      );
      expect(await tampered.isMasterSignatureValid(), isFalse);
      expect(await tampered.isApprenticeSignatureValid(), isFalse);
      expect(await tampered.isFullyValid(), isFalse);
    });

    test('a half-signed pact (master only) is not fully valid', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final pact = await samplePact(master, apprentice);
      final signed = await SignedGraduationPact.proposedByMaster(pact: pact, masterIdentity: master);
      expect(await signed.isFullyValid(), isFalse);
    });

    test('a forged apprentice signature (wrong signer) is rejected', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final attacker = await Identity.ephemeral();
      final pact = await samplePact(master, apprentice);
      var signed = await SignedGraduationPact.proposedByMaster(pact: pact, masterIdentity: master);
      // The attacker signs, but the pact still claims `apprentice`'s pubkey.
      signed = await signed.signedByApprentice(apprenticeIdentity: attacker);
      expect(await signed.isApprenticeSignatureValid(), isFalse);
      expect(await signed.isFullyValid(), isFalse);
    });
  });

  group('persistence', () {
    test('save()/loadByPactId() round-trips a fully-signed pact', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final pact = await samplePact(master, apprentice);
      var signed = await SignedGraduationPact.proposedByMaster(pact: pact, masterIdentity: master);
      signed = await signed.signedByApprentice(apprenticeIdentity: apprentice);
      await signed.save();

      final loaded = await SignedGraduationPact.loadByPactId(pact.pactIdHex);
      expect(loaded, isNotNull);
      expect(loaded!.pact.pactIdHex, pact.pactIdHex);
      expect(await loaded.isFullyValid(), isTrue);
    });

    test('loadByPactId returns null for an unknown pact', () async {
      expect(await SignedGraduationPact.loadByPactId('0x${'00' * 16}'), isNull);
    });
  });
}
