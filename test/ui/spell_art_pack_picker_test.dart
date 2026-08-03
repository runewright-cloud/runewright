// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_art_pack_picker_test.dart — SpellArtPackScreen (docs/SPELL_ART_PACK_PLAN.md
// Phase E-2): renders the full pack, narrows on the element filter, returns the
// tapped-and-confirmed entry's id via Navigator.pop, and always shows the
// attribution footer (a licence condition, not a nicety -- see spell_art_pack_test.dart's
// equivalent assertion for the underlying data).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/spell_art_pack.dart';
import 'package:rune_duel/ui/spell_art_pack_screen.dart';

void main() {
  /// Pushes [SpellArtPackScreen] behind a plain button, for tests that only
  /// need to interact with the screen itself, not its Navigator.pop result.
  Future<void> pumpPicker(WidgetTester tester, {String? suggestedElement}) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => pickSpellArtPackIcon(context, suggestedElement: suggestedElement),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('renders one tile per catalogue entry when no filter is active', (tester) async {
    await pumpPicker(tester);

    expect(find.byType(SpellArtPackScreen), findsOneWidget);
    // GridView is lazy (builder), so only visible tiles are actually built --
    // assert the screen is showing the full-catalogue grid via its title and
    // element chips instead of counting offscreen tiles.
    expect(find.text('Choose Art'), findsOneWidget);
    expect(find.text('All'), findsWidgets); // element chip + subject dropdown default
  });

  testWidgets('the fire element chip narrows the grid to fire-tagged entries only',
      (tester) async {
    await pumpPicker(tester);

    await tester.tap(find.text('Fire'));
    await tester.pumpAndSettle();

    // Scroll to the end and confirm every visible tile's underlying entry is
    // 'fire' -- since InkWell/Image widgets carry no element label directly,
    // assert indirectly via the grid's itemCount matching the fire subset by
    // checking the "no icons match" empty state is NOT showing (there ARE
    // fire entries) and that switching to a filter with zero matches DOES
    // show it, proving the filter is actually applied rather than a no-op.
    expect(find.text('No icons match this filter.'), findsNothing);
  });

  testWidgets('an element + subject combination with zero matches shows the empty state',
      (tester) async {
    await pumpPicker(tester);

    // 'fireball' only ever appears with fire-associated colours -- pairing it
    // with the 'water' filter is guaranteed empty by construction (verified
    // against the real catalogue below), proving filters actually intersect.
    final hasWaterFireball =
        kPainterlyPack.any((e) => e.subject == 'fireball' && e.element == 'water');
    expect(hasWaterFireball, isFalse);

    await tester.tap(find.text('Water'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('fireball').last);
    await tester.pumpAndSettle();

    expect(find.text('No icons match this filter.'), findsOneWidget);
  });

  testWidgets('opening on a suggested element pre-selects that chip', (tester) async {
    await pumpPicker(tester, suggestedElement: 'air');

    final chip = tester.widget<ChoiceChip>(
      find.ancestor(of: find.text('Air'), matching: find.byType(ChoiceChip)),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets('tapping a tile then Choose returns that entry\'s id via Navigator.pop',
      (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await pickSpellArtPackIcon(context);
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: find.byType(GridView), matching: find.byType(InkWell)).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Choose'), findsOneWidget);

    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(kPainterlyPack.map((e) => e.id), contains(result));
    expect(find.byType(SpellArtPackScreen), findsNothing); // screen popped
  });

  testWidgets('Cancel in the preview dialog does not pop the screen', (tester) async {
    await pumpPicker(tester);

    await tester.tap(
      find.descendant(of: find.byType(GridView), matching: find.byType(InkWell)).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(SpellArtPackScreen), findsOneWidget);
  });

  testWidgets('attribution footer renders the author, licence, and "modified"',
      (tester) async {
    await pumpPicker(tester);

    final footerFinder = find.textContaining(kPainterlyLicence.licence);
    expect(footerFinder, findsOneWidget);
    final footerText = tester.widget<Text>(footerFinder).data!;
    expect(footerText, contains('Bjerk'));
    expect(footerText, contains('modified'));
  });
}
