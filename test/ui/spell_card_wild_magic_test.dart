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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/wild_magic_preview.dart';
import 'package:rune_duel/ui/foil_sheen.dart';
import 'package:rune_duel/ui/spell_card_painter.dart';

import '../support/wild_magic_fixture.dart';

/// The CASTER key that fires one Row-1 fire effect (Burning Hot) under
/// "universal" for the shared fixture — see
/// test/spells/wild_magic_preview_test.dart, which pins the derivation and
/// shares these two keys.
///
/// A caster, not an owner: since Wild Magic v2 the card keys on the WIZARD
/// HOLDING IT and the spell's certified behaviour — never on the inscriber
/// recorded on the asset, and never on the grid (the commitment left the
/// preimage in v2, docs/WILD_MAGIC_PLAN_VNEXT.md §3).
const String _wildCaster =
    '0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a00000013';

/// A caster key that fires nothing for the same fixture.
const String _quietCaster =
    '0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a00000000';

/// Points every card in the test at [caster] under [seed].
void _viewAs(String? caster, {String seed = 'universal'}) {
  debugClearWildMagicPreviewCache();
  activeWildMagicContext.value = WildMagicPreviewContext(
    casterPubkeyHex: caster,
    leyline: LeylineConfig.ordinary(seed),
  );
}

SpellAsset _spell() => fixtureSpell(name: 'Fixture');

Widget _host(SpellAsset spell) =>
    MaterialApp(home: Scaffold(body: Center(child: SpellCardWidget(spell: spell))));

void main() {
  setUp(() {
    // Widget tests never load the player's identity or stored seed (no secure
    // storage), so pin the whole preview context rather than leaning on
    // whatever a previous test left behind.
    _viewAs(_wildCaster);
  });

  tearDown(() {
    activeWildMagicContext.value = const WildMagicPreviewContext();
    debugClearWildMagicPreviewCache();
  });

  testWidgets('a wild-magic spell gets the foil luster on its thumbnail',
      (tester) async {
    await tester.pumpWidget(_host(_spell()));
    await tester.pump();

    expect(find.byType(FoilSheen), findsOneWidget);
  });

  testWidgets('an ordinary spell gets no foil', (tester) async {
    _viewAs(_quietCaster);
    await tester.pumpWidget(_host(_spell()));
    await tester.pumpAndSettle();

    expect(find.byType(FoilSheen), findsNothing);
  });

  testWidgets('the full card prints the effect it fires', (tester) async {
    await tester.pumpWidget(_host(_spell()));
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
    _viewAs(_quietCaster);
    await tester.pumpWidget(_host(_spell()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SpellCardWidget));
    await tester.pumpAndSettle();

    expect(find.text('✦ WILD MAGIC ✦'), findsNothing);
    expect(find.byType(FoilSheen), findsNothing);
  });

  testWidgets('a card with no viewer identity shows no wild magic',
      (tester) async {
    // The fail-closed surface: before the local Runekey has been read (and on
    // any screen that has none), a card must show nothing rather than fall
    // back to the inscriber or to a zero identity.
    _viewAs(null);
    await tester.pumpWidget(_host(_spell()));
    await tester.pumpAndSettle();

    expect(find.byType(FoilSheen), findsNothing);

    await tester.tap(find.byType(SpellCardWidget));
    await tester.pumpAndSettle();
    expect(find.text('✦ WILD MAGIC ✦'), findsNothing);
  });

  testWidgets('rotating the leyline seed re-rolls a mounted card', (tester) async {
    await tester.pumpWidget(_host(_spell()));
    await tester.pump();
    expect(find.byType(FoilSheen), findsOneWidget);

    // Exactly what the settings screen does after saving a new seed word: the
    // library must visibly re-roll without being popped and re-pushed.
    _viewAs(_wildCaster, seed: 'rivendell');
    await tester.pumpAndSettle();

    expect(find.byType(FoilSheen), findsNothing);
  });
}
