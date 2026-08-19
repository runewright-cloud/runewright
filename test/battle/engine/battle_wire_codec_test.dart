// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_wire_codec_test.dart — direct tests of the extracted codec.
//
// The two characterization files pin the bytes a real turn produces and what
// a real turn does with a peer's bytes. This file tests the codec on its own,
// which buys two things those cannot:
//
//   * **encode → decode symmetry**, isolated. A round trip through TurnLoop
//     resolves a whole turn, so a field that survives the wire but is then
//     overwritten by resolution looks fine. Here, what comes out is only what
//     the decoder read.
//   * **the edges no turn reaches.** Negative coordinates at the int16
//     boundary, a path at the 255-entry clamp, an activation index one past
//     the enum — inputs a well-behaved client never produces and a modified
//     one produces first.
//
// No test here asserts anything about trust. That is the point of the split:
// this layer has no opinion on whether a decoded claim is true.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/battle_wire_codec.dart';
import 'package:rune_duel/battle/engine/turn_actions.dart';
import 'package:rune_duel/battle/models/minion.dart' show SummonPersonality;
import 'package:rune_duel/battle/models/wizard_avatar.dart' show AccoutrementKind;
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/sorcerer/incantation_recall.dart';

SpellAsset _spell({
  String commitmentHex = '0xc1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1'
      'c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1',
  int t = 3,
  String name = 'Ember',
  List<String> formula = const ['fire', 'earth'],
  bool isSummon = false,
  String summonPersonality = 'aggressive',
  Uint8List? proofBytes,
}) => SpellAsset(
      id: 'x',
      createdAt: DateTime.utc(2026, 8, 18),
      tier: 12,
      t: t,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 7,
      segmentCount: 2,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0),
      proofBytes: proofBytes ?? Uint8List(0),
      name: name,
      commitmentHex: commitmentHex,
      spellHashHex: '0x${'ab' * 32}',
      formula: formula,
      isSummon: isSummon,
      summonPersonality: summonPersonality,
    );

Uint8List _encode(TurnAction a, {bool vocal = false}) =>
    ActionWire.encodeAction(a, isVocalComponents: vocal);

void main() {
  group('WireBytes', () {
    test('int16 coordinates survive the sign boundary', () {
      for (final c in const [
        HexCoord(0, 0),
        HexCoord(-1, 1),
        HexCoord(1, -1),
        HexCoord(-32768, 32767),
        HexCoord(32767, -32768),
      ]) {
        expect(WireBytes.decodeCoord(WireBytes.encodeCoord(c), 0), c);
      }
    });

    test('be2/be4 are big-endian', () {
      expect(WireBytes.hex(WireBytes.be2(0x1234)), '1234');
      expect(WireBytes.hex(WireBytes.be4(0x89ABCDEF)), '89abcdef');
      expect(WireBytes.readBe2(WireBytes.be2(0xBEEF), 0), 0xBEEF);
      expect(WireBytes.readBe4(WireBytes.be4(0x01020304), 0), 0x01020304);
    });

    test('hex round trips with and without the 0x prefix', () {
      final bytes = Uint8List.fromList([0x00, 0x0f, 0xff]);
      expect(WireBytes.hex(bytes), '000fff');
      expect(WireBytes.hex0x(bytes), '0x000fff');
      expect(WireBytes.hexToBytes('0x000fff'), bytes);
      expect(WireBytes.hexToBytes('000fff'), bytes);
    });
  });

  group('ActionWire round trips', () {
    test('Pass, Dash and Meditate', () {
      expect(ActionWire.decodeAction(_encode(PassAction())).action,
          isA<PassAction>());
      expect(ActionWire.decodeAction(_encode(DashAction())).action,
          isA<DashAction>());
      expect(ActionWire.decodeAction(_encode(MeditateAction())).action,
          isA<MeditateAction>());
    });

    test('a spell cast preserves every transmitted field', () {
      final action = SpellCastAction(
        spell: _spell(t: 9, name: 'Cinder Vault', formula: const [
          'fire',
          'air',
          'water',
        ]),
        targetHex: const HexCoord(-3, 4),
        isPotent: true,
        isVelocity: false,
        isEfficiency: true,
        conveyorDirection: const HexCoord(0, -1),
      );
      final out = ActionWire.decodeAction(_encode(action)).action;
      expect(out, isA<SpellCastAction>());
      final cast = out as SpellCastAction;
      expect(cast.targetHex, const HexCoord(-3, 4));
      expect(cast.isPotent, isTrue);
      expect(cast.isVelocity, isFalse);
      expect(cast.isEfficiency, isTrue);
      expect(cast.conveyorDirection, const HexCoord(0, -1));
      expect(cast.spell.t, 9);
      expect(cast.spell.name, 'Cinder Vault');
      expect(cast.spell.formula, ['fire', 'air', 'water']);
      expect(cast.spell.commitmentHex, action.spell.commitmentHex);
    });

    test('an empty formula and an empty name survive as empty', () {
      final action = SpellCastAction(
        spell: _spell(name: '', formula: const []),
        targetHex: const HexCoord(1, 1),
      );
      final cast =
          ActionWire.decodeAction(_encode(action)).action as SpellCastAction;
      expect(cast.spell.formula, isEmpty);
      expect(cast.spell.name, '');
    });

    test('a mystery cast preserves its commitment and immediate opening', () {
      final action = MysterySpellCastAction(
        spell: _spell(t: 6, name: 'Veil'),
        mysteryCommitment: Uint8List(32)..fillRange(0, 32, 0x7E),
        immediateTarget: const HexCoord(2, -2),
        immediateNonce: Uint8List(16)..fillRange(0, 16, 0x6D),
        isPotent: true,
      );
      final out = ActionWire.decodeAction(_encode(action)).action;
      final cast = out as MysterySpellCastAction;
      expect(cast.mysteryCommitment, action.mysteryCommitment);
      expect(cast.immediateTarget, const HexCoord(2, -2));
      expect(cast.immediateNonce, action.immediateNonce);
      expect(cast.isPotent, isTrue);
      expect(cast.spell.name, 'Veil');
    });

    test('a delayed mystery cast carries no target', () {
      final action = MysterySpellCastAction(
        spell: _spell(),
        mysteryCommitment: Uint8List(32),
      );
      final cast = ActionWire.decodeAction(_encode(action)).action
          as MysterySpellCastAction;
      expect(cast.immediateTarget, isNull);
      expect(cast.immediateNonce, isNull);
    });

    test('the recall suffix survives only in vocal mode', () {
      final action = SpellCastAction(
        spell: _spell(),
        targetHex: const HexCoord(0, 1),
        recall: IncantationRecall.silent,
      );
      expect(
        (ActionWire.decodeAction(
          _encode(action, vocal: true),
          isVocalComponents: true,
        ).action as SpellCastAction)
            .recall,
        isNotNull,
      );
      expect(
        (ActionWire.decodeAction(_encode(action)).action as SpellCastAction)
            .recall,
        isNull,
        reason: 'wizard mode neither writes nor reads a suffix',
      );
    });
  });

  group('summon bytes (M4.19: transcribed, never audited)', () {
    test('a declared summon and its personality survive verbatim', () {
      for (final p in SummonPersonality.values) {
        final action = SpellCastAction(
          spell: _spell(isSummon: true, summonPersonality: p.name),
          targetHex: const HexCoord(0, 1),
        );
        final cast =
            ActionWire.decodeAction(_encode(action)).action as SpellCastAction;
        expect(cast.spell.isSummon, isTrue);
        expect(cast.spell.summonPersonality, p.name);
      }
    });

    test('a personality name this build does not have encodes as aggressive',
        () {
      final buf = BytesBuilder();
      ActionWire.appendSummonBytes(
        buf,
        _spell(isSummon: true, summonPersonality: 'from-the-future'),
      );
      expect(buf.toBytes(), [1, SummonPersonality.aggressive.index]);
    });

    test('an out-of-range personality index reads back as aggressive', () {
      final read = ActionWire.readSummonBytes(
        Uint8List.fromList([1, 0xFF]),
        0,
      );
      expect(read.isSummon, isTrue);
      expect(read.personality, SummonPersonality.aggressive.name);
    });

    test('reading past the end of the buffer reads as "not a summon"', () {
      expect(ActionWire.readSummonBytes(Uint8List(0), 0).isSummon, isFalse);
      expect(ActionWire.readSummonBytes(Uint8List.fromList([1]), 0),
          (isSummon: true, personality: SummonPersonality.values.first.name));
    });
  });

  group('ActionWire.splitActionTarget', () {
    test('a spell cast yields the 4-byte target and the rest', () {
      final bytes = _encode(SpellCastAction(
        spell: _spell(),
        targetHex: const HexCoord(-2, 5),
      ));
      final (target, remainder) = ActionWire.splitActionTarget(bytes);
      expect(target, WireBytes.encodeCoord(const HexCoord(-2, 5)));
      expect(remainder.length, bytes.length - 4);
      expect(remainder[0], 0x01, reason: 'the type byte stays in remainder');
    });

    test('Pass, Dash, Meditate and Mystery have no plaintext target leaf', () {
      for (final action in <TurnAction>[
        PassAction(),
        DashAction(),
        MeditateAction(),
        MysterySpellCastAction(
          spell: _spell(),
          mysteryCommitment: Uint8List(32),
        ),
      ]) {
        final bytes = _encode(action);
        final (target, remainder) = ActionWire.splitActionTarget(bytes);
        expect(target, isEmpty);
        expect(remainder, bytes);
      }
    });

    test('empty input is handled without an index error', () {
      final (target, remainder) = ActionWire.splitActionTarget(Uint8List(0));
      expect(target, isEmpty);
      expect(remainder, isEmpty);
    });

    test('the commit is stable for fixed salts and changes with the target',
        () async {
      Uint8List cast(HexCoord at) => _encode(
            SpellCastAction(spell: _spell(), targetHex: at),
          );
      final saltA = Uint8List(16)..fillRange(0, 16, 0x11);
      final saltB = Uint8List(16)..fillRange(0, 16, 0x22);
      final a = await ActionWire.splitActionCommit(
          cast(const HexCoord(0, 1)), saltA, saltB);
      final again = await ActionWire.splitActionCommit(
          cast(const HexCoord(0, 1)), saltA, saltB);
      final other = await ActionWire.splitActionCommit(
          cast(const HexCoord(0, 2)), saltA, saltB);
      expect(a, again);
      expect(a, isNot(other));
      expect(a, hasLength(32));
    });
  });

  group('MoveWire', () {
    test('flags and path round trip', () {
      for (final dash in [false, true]) {
        for (final med in [false, true]) {
          final path = const [HexCoord(1, 0), HexCoord(1, -1)];
          final out = MoveWire.decodePayload(
            MoveWire.encodePayload(
              isDashing: dash,
              meditateInMove: med,
              path: path,
            ),
            0,
          );
          expect(out.isDashing, dash);
          expect(out.meditateInMove, med);
          expect(out.path, med ? isEmpty : path,
              reason: 'meditating forces an empty path on decode');
        }
      }
    });

    test('the path count byte clamps at 255', () {
      final long = List.generate(300, (i) => HexCoord(i, 0));
      final encoded = MoveWire.encodePath(long);
      expect(encoded[0], 255);
      expect(MoveWire.decodePath(encoded, 0), hasLength(255));
    });

    test('decoding past the end of the buffer yields an empty path', () {
      expect(MoveWire.decodePath(Uint8List(0), 0), isEmpty);
      expect(MoveWire.decodePath(Uint8List.fromList([5]), 0), isEmpty);
    });
  });

  group('MeleeWire', () {
    test('null and a target round trip', () {
      expect(MeleeWire.decodeTarget(MeleeWire.encodeTarget(null), 0), isNull);
      expect(
        MeleeWire.decodeTarget(
            MeleeWire.encodeTarget(const HexCoord(-4, 2)), 0),
        const HexCoord(-4, 2),
      );
    });

    test('a truncated target frame reads as "no melee"', () {
      expect(MeleeWire.decodeTarget(Uint8List.fromList([0x01, 0x00]), 0), isNull);
      expect(MeleeWire.decodeTarget(Uint8List(0), 0), isNull);
    });
  });

  group('ArtifactActivationWire', () {
    test('every kind round trips', () {
      expect(ArtifactActivationWire.decode(
          ArtifactActivationWire.encode(null), 0), isNull);
      for (final kind in AccoutrementKind.values) {
        expect(
          ArtifactActivationWire.decode(ArtifactActivationWire.encode(kind), 0),
          kind,
        );
      }
    });

    test('an index past the enum reads as "declared nothing"', () {
      expect(
        ArtifactActivationWire.decode(Uint8List.fromList([0x01, 0xFF]), 0),
        isNull,
      );
    });

    test('a truncated or unknown lead byte reads as "declared nothing"', () {
      expect(ArtifactActivationWire.decode(Uint8List.fromList([0x01]), 0), isNull);
      expect(ArtifactActivationWire.decode(Uint8List.fromList([0x02, 0x00]), 0),
          isNull);
      expect(ArtifactActivationWire.decode(Uint8List(0), 0), isNull);
    });
  });

  group('DelayedRevealWire', () {
    test('entries round trip', () {
      final reveals = [
        (
          pendingSpellId: '0f' * 16,
          targetTile: const HexCoord(2, -3),
          delay: 2,
          nonce: Uint8List(16)..fillRange(0, 16, 0x5C),
        ),
        (
          pendingSpellId: 'a1' * 16,
          targetTile: const HexCoord(-1, 0),
          delay: 0,
          nonce: Uint8List(16)..fillRange(0, 16, 0x01),
        ),
      ];
      final out = DelayedRevealWire.decode(DelayedRevealWire.encode(reveals));
      expect(out, hasLength(2));
      expect(out[0].id, '0f' * 16);
      expect(out[0].targetTile, const HexCoord(2, -3));
      expect(out[0].delay, 2);
      expect(out[1].id, 'a1' * 16);
      expect(out[1].delay, 0);
    });

    test('an empty list encodes as one count byte', () {
      expect(DelayedRevealWire.encode(const []), [0]);
      expect(DelayedRevealWire.decode(Uint8List.fromList([0])), isEmpty);
    });

    test('a count byte larger than the payload keeps the complete entries', () {
      final good = DelayedRevealWire.encode([
        (
          pendingSpellId: '0f' * 16,
          targetTile: const HexCoord(0, 0),
          delay: 1,
          nonce: Uint8List(16),
        ),
      ]);
      final lying = Uint8List.fromList(good)..[0] = 4;
      expect(DelayedRevealWire.decode(lying), hasLength(1));
    });

    test('an empty payload decodes to nothing', () {
      expect(DelayedRevealWire.decode(Uint8List(0)), isEmpty);
    });
  });

  group('StateHashWire', () {
    test('tag, matchId, turn BE4, hash — in that order', () {
      final msg = StateHashWire.signatureMessage(
        matchId: Uint8List.fromList([0xA0, 0xA1]),
        turnNumber: 258,
        hash: Uint8List(32)..fillRange(0, 32, 0x99),
      );
      final tagLen = kStateHashSignatureTag.length;
      expect(msg.length, tagLen + 2 + 4 + 32);
      expect(WireBytes.hex(msg.sublist(tagLen, tagLen + 2)), 'a0a1');
      expect(WireBytes.hex(msg.sublist(tagLen + 2, tagLen + 6)), '00000102',
          reason: '258 as a big-endian 4-byte turn number');
    });

    test('a null matchId contributes no bytes', () {
      final msg = StateHashWire.signatureMessage(
        matchId: null,
        turnNumber: 1,
        hash: Uint8List(32),
      );
      expect(msg.length, kStateHashSignatureTag.length + 4 + 32);
    });

    test('the turn number is what separates two otherwise identical messages',
        () {
      final hash = Uint8List(32);
      expect(
        StateHashWire.signatureMessage(
            matchId: null, turnNumber: 1, hash: hash),
        isNot(StateHashWire.signatureMessage(
            matchId: null, turnNumber: 2, hash: hash)),
      );
    });
  });

  group('divination exchange framing', () {
    test('a decline is one zero byte and parses as "no key"', () {
      expect(SealedExchangeFrames.decline(), [0x00]);
      expect(
        SealedExchangeFrames.keyFramePublicKey(SealedExchangeFrames.decline()),
        isNull,
      );
    });

    test('a key frame round trips and is length-exact', () {
      final pub = Uint8List(32)..fillRange(0, 32, 0x42);
      final frame = SealedExchangeFrames.keyFrame(pub);
      expect(frame, hasLength(33));
      expect(SealedExchangeFrames.keyFramePublicKey(frame), pub);
      // One byte long or short is not an X25519 key.
      expect(
        SealedExchangeFrames.keyFramePublicKey(
            Uint8List.fromList([...frame, 0x00])),
        isNull,
      );
      expect(
        SealedExchangeFrames.keyFramePublicKey(
            Uint8List.fromList(frame.sublist(0, 32))),
        isNull,
      );
    });

    test('a sealed frame splits back into key and ciphertext', () {
      final vk = Uint8List(32)..fillRange(0, 32, 0x11);
      final box = Uint8List(48)..fillRange(0, 48, 0x22);
      final opened =
          SealedExchangeFrames.openSealedFrame(
              SealedExchangeFrames.sealedFrame(vk, box));
      expect(opened, isNotNull);
      expect(opened!.vkPub, vk);
      expect(opened.box, box);
    });

    test('a declined or too-short sealed frame opens to null', () {
      expect(SealedExchangeFrames.openSealedFrame(Uint8List(0)), isNull);
      expect(
        SealedExchangeFrames.openSealedFrame(Uint8List.fromList([0x00])),
        isNull,
      );
      expect(
        SealedExchangeFrames.openSealedFrame(
            Uint8List.fromList([0x01, ...List.filled(20, 0)])),
        isNull,
      );
    });

    test('the two exchanges derive different HKDF info for the same turn', () {
      final scry = ScryWire.hkdfInfo(matchId: null, turnNumber: 3);
      final reveal = SpellRevealWire.hkdfInfo(matchId: null, turnNumber: 3);
      expect(scry, isNot(reveal));
      expect(
        ScryWire.hkdfInfo(matchId: null, turnNumber: 3),
        isNot(ScryWire.hkdfInfo(matchId: null, turnNumber: 4)),
      );
    });

    test('a scry opening round trips with and without a target', () {
      final saltB = Uint8List(16)..fillRange(0, 16, 0xB2);
      final leafA = Uint8List(32)..fillRange(0, 32, 0xA1);
      final target = WireBytes.encodeCoord(const HexCoord(1, -1));

      final withTarget = ScryWire.decodeOpening(ScryWire.encodeOpening(
          target: target, saltB: saltB, leafA: leafA));
      expect(withTarget, isNotNull);
      expect(withTarget!.target, target);
      expect(withTarget.saltB, saltB);
      expect(withTarget.leafA, leafA);

      final without = ScryWire.decodeOpening(ScryWire.encodeOpening(
          target: Uint8List(0), saltB: saltB, leafA: leafA));
      expect(without, isNotNull);
      expect(without!.target, isEmpty);
      expect(without.saltB, saltB);
    });

    test('an opening of any other length is rejected', () {
      for (final len in [0, 47, 49, 51, 53]) {
        expect(ScryWire.decodeOpening(List<int>.filled(len, 0)), isNull,
            reason: 'length $len is neither 48 nor 52');
      }
    });
  });
}
