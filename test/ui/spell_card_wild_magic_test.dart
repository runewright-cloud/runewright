// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_card_wild_magic_test.dart — the card's two wild-magic treatments:
// the printed WILD MAGIC panel and the foil luster, both of which must appear
// for exactly the spells that carry wild magic and for no others.
//
// Note the absence of `pumpAndSettle` around a foil card: FoilSheen runs a
// repeating animation for as long as it is mounted, so settling never
// completes. Pumping fixed durations is the correct way to drive it, and a
// future test that reaches for pumpAndSettle here will hang rather than fail
// — hence this comment rather than a bare convention.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/wild_magic_preview.dart';
import 'package:rune_duel/ui/foil_sheen.dart';
import 'package:rune_duel/ui/spell_card_painter.dart';

/// Fires one Row-1 fire effect (Burning Hot) under "universal" at T=7 — see
/// test/spells/wild_magic_preview_test.dart, which pins the derivation.
const String _wildCommitment =
    '0xf9bce34e2b06068661f4537c136070f5b15e9a59ed3f302c3134f6084796d5af';

/// Fires nothing under "universal" at T=7.
const String _quietCommitment =
    '0x5a118d8d2ee3639ad4f4b729acd8eaeb2c08da393de9f3c265fadee25f28e93c';

SpellAsset _spell({required String commitmentHex}) => SpellAsset(
  id: 'card-fixture',
  createdAt: DateTime.utc(2026, 8, 5),
  tier: 12,
  t: 7,
  ownerPubkeyHex: '0x00',
  manaCost: 10,
  segmentCount: 1,
  dotCount: 0,
  initialGrid: List<int>.filled(469, 0)..[234] = 1,
  proofBytes: Uint8List.fromList(const [1, 2, 3]),
  name: 'Fixture',
  commitmentHex: commitmentHex,
  spellHashHex: '0xfeed',
  // Three fire activations: one complete formula, so the spell is eligible
  // for the fire column of the effects table.
  formula: const ['fire', 'fire', 'fire'],
);

Widget _host(SpellAsset spell) =>
    MaterialApp(home: Scaffold(body: Center(child: SpellCardWidget(spell: spell))));

void main() {
  setUp(() {
    // Widget tests never load the player's stored seed (no secure storage), so
    // pin it rather than leaning on whatever a previous test left behind.
    activeLeylineSeed.value = 'universal';
  });

  testWidgets('a wild-magic spell gets the foil luster on its thumbnail',
      (tester) async {
    await tester.pumpWidget(_host(_spell(commitmentHex: _wildCommitment)));
    await tester.pump();

    expect(find.byType(FoilSheen), findsOneWidget);
  });

  testWidgets('an ordinary spell gets no foil', (tester) async {
    await tester.pumpWidget(_host(_spell(commitmentHex: _quietCommitment)));
    await tester.pumpAndSettle();

    expect(find.byType(FoilSheen), findsNothing);
  });

  testWidgets('the full card prints the effect it fires', (tester) async {
    await tester.pumpWidget(_host(_spell(commitmentHex: _wildCommitment)));
    await tester.pump();

    await tester.tap(find.byType(SpellCardWidget));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('✦ WILD MAGIC ✦'), findsOneWidget);
    // The effect's in-world name and its symmetric description, verbatim from
    // kWildMagicEffectLabel/Description — a player must be able to read that
    // this one hits them too.
    expect(
      find.textContaining('Burning Hot', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Every spell effect next turn burns hotter',
          findRichText: true),
      findsOneWidget,
    );
    // Foil on the full card as well as the thumbnail.
    expect(find.byType(FoilSheen), findsWidgets);
  });

  testWidgets('the full card of an ordinary spell has no wild-magic panel',
      (tester) async {
    await tester.pumpWidget(_host(_spell(commitmentHex: _quietCommitment)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SpellCardWidget));
    await tester.pumpAndSettle();

    expect(find.text('✦ WILD MAGIC ✦'), findsNothing);
    expect(find.byType(FoilSheen), findsNothing);
  });

  testWidgets('rotating the leyline seed re-rolls a mounted card', (tester) async {
    await tester.pumpWidget(_host(_spell(commitmentHex: _wildCommitment)));
    await tester.pump();
    expect(find.byType(FoilSheen), findsOneWidget);

    // Exactly what the settings screen does after saving a new seed word: the
    // library must visibly re-roll without being popped and re-pushed.
    activeLeylineSeed.value = 'rivendell';
    await tester.pumpAndSettle();

    expect(find.byType(FoilSheen), findsNothing);
  });
}
