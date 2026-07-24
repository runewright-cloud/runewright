// SPDX-License-Identifier: GPL-3.0-or-later
//
// trade_offer_test.dart — TradeItem/TradeOffer serialization and the
// offer-eligibility filter (only natively-owned spells are offerable).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/trade/trade_offer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  SpellAsset spell({required String id, required String ownerPubkeyHex}) => SpellAsset(
        id: id,
        createdAt: DateTime.utc(2026, 6, 19),
        tier: 12,
        t: 5,
        ownerPubkeyHex: ownerPubkeyHex,
        manaCost: 10,
        segmentCount: 1,
        dotCount: 0,
        initialGrid: List<int>.filled(469, 0),
        proofBytes: Uint8List.fromList([1, 2, 3]),
        name: 'Ember Wake',
        commitmentHex: '0xaabbcc',
        spellHashHex: '0xddeeff',
      );

  group('TradeItem', () {
    test('requires loanDays iff mode is loan', () {
      expect(
        () => TradeItem(spellId: 's', commitmentHex: '0x1', spellName: 'x', mode: TradeMode.loan),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => TradeItem(
          spellId: 's',
          commitmentHex: '0x1',
          spellName: 'x',
          mode: TradeMode.transfer,
          loanDays: 3,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('toJson/fromJson round-trips a loan item', () {
      final item = TradeItem(
        spellId: 's1',
        commitmentHex: '0xabc',
        spellName: 'Ember Wake',
        mode: TradeMode.loan,
        loanDays: 5,
      );
      final restored = TradeItem.fromJson(item.toJson());
      expect(restored.spellId, item.spellId);
      expect(restored.commitmentHex, item.commitmentHex);
      expect(restored.spellName, item.spellName);
      expect(restored.mode, TradeMode.loan);
      expect(restored.loanDays, 5);
    });

    test('toJson/fromJson round-trips a transfer item with null loanDays', () {
      final item = TradeItem(
        spellId: 's2',
        commitmentHex: '0xdef',
        spellName: 'Frost Bind',
        mode: TradeMode.transfer,
      );
      final restored = TradeItem.fromJson(item.toJson());
      expect(restored.mode, TradeMode.transfer);
      expect(restored.loanDays, isNull);
    });
  });

  group('TradeOffer', () {
    test('an empty offer round-trips', () {
      const offer = TradeOffer();
      final restored = TradeOffer.fromJson(offer.toJson());
      expect(restored.items, isEmpty);
    });

    test('a multi-item offer round-trips', () {
      final offer = TradeOffer(items: [
        TradeItem(spellId: 'a', commitmentHex: '0x1', spellName: 'A', mode: TradeMode.loan, loanDays: 1),
        TradeItem(spellId: 'b', commitmentHex: '0x2', spellName: 'B', mode: TradeMode.transfer),
      ]);
      final restored = TradeOffer.fromJson(offer.toJson());
      expect(restored.items, hasLength(2));
      expect(restored.items[0].mode, TradeMode.loan);
      expect(restored.items[1].mode, TradeMode.transfer);
    });
  });

  group('eligibleOfferSpells', () {
    test('includes only spells owned by the given identity', () async {
      final me = await Identity.ephemeral();
      final myPubkeyHex = await me.ownerPubkeyHex();
      final strangerPubkeyHex = await (await Identity.ephemeral()).ownerPubkeyHex();

      final mine = spell(id: 'mine', ownerPubkeyHex: myPubkeyHex);
      final foreign = spell(id: 'foreign', ownerPubkeyHex: strangerPubkeyHex);

      final eligible = eligibleOfferSpells([mine, foreign], myPubkeyHex);
      expect(eligible.map((s) => s.id).toList(), equals(['mine']));
    });

    test('excludes a spell held via a loan or transfer grant (foreign ownerPubkeyHex)', () async {
      final me = await Identity.ephemeral();
      final myPubkeyHex = await me.ownerPubkeyHex();
      final ownerPubkeyHex = await (await Identity.ephemeral()).ownerPubkeyHex();

      // A spell I hold locally (e.g. via a saved transfer) but do not own --
      // must never be offerable, enforcing "no re-trading a loan/transfer".
      final heldNotOwned = spell(id: 'held', ownerPubkeyHex: ownerPubkeyHex);

      final eligible = eligibleOfferSpells([heldNotOwned], myPubkeyHex);
      expect(eligible, isEmpty);
    });

    test('eligibleOfferSpellsFor resolves the identity to its pubkey hex', () async {
      final me = await Identity.ephemeral();
      final myPubkeyHex = await me.ownerPubkeyHex();
      final mine = spell(id: 'mine', ownerPubkeyHex: myPubkeyHex);

      final eligible = await eligibleOfferSpellsFor([mine], me);
      expect(eligible.map((s) => s.id).toList(), equals(['mine']));
    });
  });
}
