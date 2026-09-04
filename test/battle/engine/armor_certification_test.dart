// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_certification_test.dart — the envelope-level attacks, at unit level.
//
// duel_setup_armor_test.dart drives the same module through two real
// handshakes; those tests cannot forge an envelope, because the envelope is
// built from the sender's own asset. These can: a declared tier is a number a
// modified client picks freely, and it is the one field in the envelope that
// changes how the same bytes are read.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/engine/armor_certification.dart';
import 'package:rune_duel/battle/models/armor_envelope.dart';
import 'package:rune_duel/battle/models/certified_armor.dart';
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/spells/inscribe.dart' show kRulesetVersion;
import 'package:rune_duel/spells/spell_asset.dart' show SpellAsset;

import 'certified_cast_fixture.dart' show syntheticProof;

const _ownerHex = '0x2a';

Uint8List _ownerBytes(int v) {
  final out = Uint8List(32);
  out[31] = v;
  return out;
}

Uint8List _proof({
  required int tier,
  required int t,
  List<BorderZone>? elements,
  int ruleset = kRulesetVersion,
  int owner = 0x2a,
}) =>
    syntheticProof(
      tier: tier,
      t: t,
      commitmentBytes: Uint8List(32),
      rulesetVersion: ruleset,
      elements: elements ?? List.filled(t, BorderZone.earth),
      ownerPubkeyBytes: _ownerBytes(owner),
    );

Future<bool> _accept(Uint8List vk, Uint8List proof) async => true;
Future<bool> _reject(Uint8List vk, Uint8List proof) async => false;
Uint8List? _vk(int tier) => Uint8List.fromList([tier]);

Future<CertifiedArmor?> certify(
  ArmorEnvelope? envelope, {
  String wearer = _ownerHex,
  int artifacts = 0,
  Future<bool> Function(Uint8List, Uint8List)? verifier = _accept,
  Uint8List? Function(int)? vk = _vk,
  ArmorLexicon lexicon = ArmorLexicon.ordinary,
}) =>
    certifyPeerArmor(
      envelope: envelope,
      wearerOwnerPubkeyHex: wearer,
      ordinaryArtifactCount: artifacts,
      verifyProof: verifier,
      vkBytesForTier: vk,
      lexicon: lexicon,
    );

Matcher throwsCertification(Matcher reason) => throwsA(
    isA<ArmorCertificationException>().having((e) => e.reason, 'reason', reason));

void main() {
  test('a null envelope is a complete declaration, not an error', () async {
    expect(await certify(null), isNull);
  });

  test('a well-formed envelope certifies', () async {
    final armor = await certify(ArmorEnvelope(
      tier: 12,
      proofBytes: _proof(tier: 12, t: 9),
    ));
    expect(armor!.t, 9);
    expect(armor.slotCost, 3);
    expect(armor.earthCount, 9);
  });

  // ── Tier routing ───────────────────────────────────────────────────────────

  group('the declared tier is routing metadata and cannot be abused', () {
    test('an unsupported tier is refused before the proof is even parsed',
        () async {
      for (final bad in [0, 1, 13, 25, 36, 49, 1 << 20]) {
        await expectLater(
          certify(ArmorEnvelope(tier: bad, proofBytes: _proof(tier: 12, t: 4))),
          throwsCertification(contains('unsupported armor circuit tier')),
          reason: 'tier $bad',
        );
      }
    });

    test('a supported but WRONG tier fails: the parse cannot find its fields',
        () async {
      // Bytes laid out for tier 12, declared as tier 24. The field count check
      // inside the parser catches it; either way it never yields an armor.
      await expectLater(
        certify(ArmorEnvelope(tier: 24, proofBytes: _proof(tier: 12, t: 4))),
        throwsCertification(contains('rejected')),
      );
    });

    test('a tier that parses but does not match the certified T is refused',
        () async {
      // A T=4 proof genuinely laid out at tier 24 — internally consistent, so
      // it parses cleanly — but T=4 belongs to tier 12. Accepting this would
      // let a peer choose which layout the same trajectory is read through.
      await expectLater(
        certify(ArmorEnvelope(tier: 24, proofBytes: _proof(tier: 24, t: 4))),
        throwsCertification(allOf(
          contains('declares tier 24'),
          contains('certified T=4'),
          contains('belongs to tier 12'),
        )),
      );
    });

    test('each canonical tier is accepted at a T that belongs to it', () async {
      expect((await certify(ArmorEnvelope(tier: 12, proofBytes: _proof(tier: 12, t: 12))))!.t, 12);
      expect((await certify(ArmorEnvelope(tier: 24, proofBytes: _proof(tier: 24, t: 24))))!.t, 24);
      expect((await certify(ArmorEnvelope(tier: 48, proofBytes: _proof(tier: 48, t: 48))))!.t, 48);
    });
  });

  // ── Verification is not optional ───────────────────────────────────────────

  group('verification resources', () {
    test('a rejected proof is refused', () async {
      await expectLater(
        certify(ArmorEnvelope(tier: 12, proofBytes: _proof(tier: 12, t: 4)),
            verifier: _reject),
        throwsCertification(contains('rejected')),
      );
    });

    test('a missing verifier refuses the armor rather than trusting it',
        () async {
      await expectLater(
        certify(ArmorEnvelope(tier: 12, proofBytes: _proof(tier: 12, t: 4)),
            verifier: null),
        throwsCertification(contains('no verifier initialised')),
      );
    });

    test('a missing VK for the declared tier refuses the armor', () async {
      await expectLater(
        certify(ArmorEnvelope(tier: 48, proofBytes: _proof(tier: 48, t: 48)),
            vk: (t) => t == 48 ? null : Uint8List(1)),
        throwsCertification(contains('no verification key')),
      );
    });

    test('an empty proof is refused', () async {
      await expectLater(
        certify(ArmorEnvelope(tier: 12, proofBytes: Uint8List(0))),
        throwsCertification(contains('no proof')),
      );
    });
  });

  // ── Owner, ruleset, budget ─────────────────────────────────────────────────

  test('the certified owner must be the authenticated wearer', () async {
    await expectLater(
      certify(ArmorEnvelope(tier: 12, proofBytes: _proof(tier: 12, t: 4, owner: 0x99))),
      throwsCertification(contains('another wizard')),
    );
  });

  test('owner comparison is numeric, not string equality', () async {
    // Same field, three encodings the wire and the library both produce.
    for (final hex in ['0x2a', '2a', '0x${'0' * 62}2a', '0X2A']) {
      expect(
        (await certify(ArmorEnvelope(tier: 12, proofBytes: _proof(tier: 12, t: 4)),
            wearer: hex))!.t,
        4,
        reason: hex,
      );
    }
  });

  test('a proof from another ruleset epoch is refused', () async {
    await expectLater(
      certify(ArmorEnvelope(
          tier: 12, proofBytes: _proof(tier: 12, t: 4, ruleset: kRulesetVersion + 1))),
      throwsCertification(contains('ruleset version')),
    );
  });

  group('the 12-slot budget is recomputed from the certified T', () {
    test('exactly 12 is allowed', () async {
      // T=9 -> 3 slots, + 9 artifacts.
      expect(
        (await certify(ArmorEnvelope(tier: 12, proofBytes: _proof(tier: 12, t: 9)),
            artifacts: 9))!.slotCost,
        3,
      );
    });

    test('13 is refused', () async {
      await expectLater(
        certify(ArmorEnvelope(tier: 12, proofBytes: _proof(tier: 12, t: 9)),
            artifacts: 10),
        throwsCertification(contains('over the 12-slot limit')),
      );
    });

    test('a T=48 armor alone consumes the whole budget', () async {
      expect(
        (await certify(ArmorEnvelope(tier: 48, proofBytes: _proof(tier: 48, t: 48))))!
            .slotCost,
        12,
      );
      await expectLater(
        certify(ArmorEnvelope(tier: 48, proofBytes: _proof(tier: 48, t: 48)),
            artifacts: 1),
        throwsCertification(contains('over the 12-slot limit')),
      );
    });
  });

  // ── The wire envelope itself ───────────────────────────────────────────────

  group('ArmorEnvelope encoding', () {
    test('"no armor" round-trips as an explicit declaration', () {
      expect(ArmorEnvelope.decode(ArmorEnvelope.encode(null)), isNull);
    });

    test('an armor round-trips proof bytes and tier, and nothing else', () {
      final proof = _proof(tier: 12, t: 4);
      final decoded =
          ArmorEnvelope.decode(ArmorEnvelope.encode(ArmorEnvelope(tier: 12, proofBytes: proof)))!;
      expect(decoded.tier, 12);
      expect(decoded.proofBytes, proof);

      // The payload carries exactly two keys under "armor" — a new one would
      // be a fact about the armor that no proof binds.
      final json = String.fromCharCodes(
          ArmorEnvelope.encode(ArmorEnvelope(tier: 12, proofBytes: proof)));
      expect(json.contains('"tier"'), isTrue);
      expect(json.contains('"proofB64"'), isTrue);
      for (final forbidden in [
        'isArmor', 'formula', 'manaCost', 'supremeTags', 'slotCost',
        'keywords', 'fireCount', 'meleeBonus', 'commitment', 'name',
      ]) {
        expect(json.contains(forbidden), isFalse, reason: forbidden);
      }
    });

    test('a malformed payload throws rather than decoding as "no armor"', () {
      for (final bad in ['[]', '{"armor": 7}', '{"armor": {"tier": 12}}', 'null']) {
        expect(
          () => ArmorEnvelope.decode(Uint8List.fromList(bad.codeUnits)),
          throwsA(isA<FormatException>()),
          reason: bad,
        );
      }
    });
  });

  // ── Mutable Leylines: one proof + one agreed config = one armor ───────────
  //
  // Slice F (R-8). The two paths already differ only in whether the bytes were
  // verified first; the lexicon is the second input both sides must agree on,
  // which is why it is REQUIRED here rather than defaulted. Nothing about the
  // derived keywords crosses the wire — the envelope test above pins that the
  // payload carries a tier and a proof and nothing else.
  group('the agreed leyline reaches both certifications', () {
    final rivendell4 =
        LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: 4);

    // AAAA (Flying ordinarily, inert under rivendell 4) then EFWA (inert
    // ordinarily, Muddy under rivendell 4), padded with earth for a real T.
    final elements = <BorderZone>[
      ...List.filled(4, BorderZone.air),
      BorderZone.earth,
      BorderZone.fire,
      BorderZone.water,
      BorderZone.air,
      ...List.filled(4, BorderZone.earth),
    ];

    SpellAsset localArmorAsset() => SpellAsset(
          id: 'armor-mutable',
          createdAt: DateTime.utc(2026, 9, 4),
          tier: 12,
          t: elements.length,
          ownerPubkeyHex: _ownerHex,
          manaCost: 1,
          segmentCount: 0,
          dotCount: 0,
          initialGrid: List<int>.filled(469, 0)..[234] = 1,
          proofBytes: _proof(tier: 12, t: elements.length, elements: elements),
          name: 'Mutable Plate',
          commitmentHex: '0x00',
          spellHashHex: '0x01',
          formula: const ['earth'],
          isArmor: true,
        );

    test('local and peer derive identical semantics under one config', () async {
      final local = certifyOwnArmor(
        armor: localArmorAsset(),
        wearerOwnerPubkeyHex: _ownerHex,
        ordinaryArtifactCount: 0,
        lexicon: ArmorLexicon.of(rivendell4),
      )!;
      final peer = await certify(
        ArmorEnvelope(
          tier: 12,
          proofBytes: _proof(tier: 12, t: elements.length, elements: elements),
        ),
        lexicon: ArmorLexicon.of(rivendell4),
      );

      expect(peer!.keywords, local.keywords);
      expect(peer.t, local.t);
      expect(peer.slotCost, local.slotCost);
      expect(peer.meleeBonus, local.meleeBonus);
      expect(peer.moveSpeedBonus, local.moveSpeedBonus);
      expect(peer.armorHpBonus, local.armorHpBonus);
    });

    test('the leyline moves the keywords and nothing else', () async {
      final ordinary = await certify(
        ArmorEnvelope(
          tier: 12,
          proofBytes: _proof(tier: 12, t: elements.length, elements: elements),
        ),
      );
      final mutable = await certify(
        ArmorEnvelope(
          tier: 12,
          proofBytes: _proof(tier: 12, t: elements.length, elements: elements),
        ),
        lexicon: ArmorLexicon.of(rivendell4),
      );

      expect(ordinary!.keywords, contains(ArmorKeyword.flying));
      expect(mutable!.keywords, {ArmorKeyword.muddy});
      // Everything else is arithmetic over the same certified trajectory.
      expect(mutable.t, ordinary.t);
      expect(mutable.slotCost, ordinary.slotCost);
      expect(mutable.fireCount, ordinary.fireCount);
      expect(mutable.airCount, ordinary.airCount);
      expect(mutable.waterCount, ordinary.waterCount);
      expect(mutable.earthCount, ordinary.earthCount);
      expect(mutable.meleeBonus, ordinary.meleeBonus);
      expect(mutable.moveSpeedBonus, ordinary.moveSpeedBonus);
      expect(mutable.spellRangeBonus, ordinary.spellRangeBonus);
      expect(mutable.armorHpBonus, ordinary.armorHpBonus);
      expect(mutable.elementSequence, ordinary.elementSequence);
    });

    test('the budget check still runs on the certified T, not the keywords',
        () async {
      // The lexicon must not have become a way to smuggle a different slot
      // cost: the refusal below is unchanged from the ordinary case.
      expect(
        certify(
          ArmorEnvelope(tier: 48, proofBytes: _proof(tier: 48, t: 48)),
          artifacts: 11,
          lexicon: ArmorLexicon.of(rivendell4),
        ),
        throwsCertification(contains('artifact slots')),
      );
    });
  });
}
