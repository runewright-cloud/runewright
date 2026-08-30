// SPDX-License-Identifier: GPL-3.0-or-later
//
// recipes_screen.dart — reference screen reachable from Rune Craft's app
// bar, showing either of two discovered-only reference lists depending on
// the mode Rune Craft is in when it's opened (RecipesScreen.isSummon):
//   - Incantation mode: every discovered three-element formula (affinity +
//     the second/third-element pair that selects the base effect).
//     Descriptions are transcribed from the Effect Table in
//     docs/runewright_design_v3_0.md §Effect Table, base values only. That
//     table's bracketed numbers are the Potency enhancement -- a modifier
//     the CA may independently attach to *any* formula, not something
//     intrinsic to the formula itself -- so they're deliberately omitted
//     here. That table is flagged "Needs Playtesting" in the design doc --
//     these are display text only and don't drive battle resolution
//     (effect_resolver.dart does, from the same table).
//   - Summon mode: every discovered creature special ability (the 8
//     element-sequence patterns from creature_spec.dart's "Abilities"
//     table), transcribed the same way.
// Both lists share the same on-disk discovered-set (RecipeBook), keyed by
// recipeKey/summonAbilityKey respectively so the two families never collide.
// A card appears the first time its formula/pattern completes during Rune
// Craft play (main.dart's GameScreen, via RecipeBook).

import 'package:flutter/material.dart';

import '../battle/models/creature_spec.dart'
    show SummonAbility, kSummonAbilityDescription, kSummonAbilityLabel, kSummonAbilityPattern;
import '../battle/models/effect_kind.dart';
import '../spells/recipe_book.dart';
import 'manuscript_theme.dart';
import 'safe_layout.dart';

const Map<SpellAffinity, Color> _kAffinityColor = {
  SpellAffinity.fire:  Color(0xFFB84040),
  SpellAffinity.air:   Color(0xFF6E93B8),
  SpellAffinity.water: Color(0xFF2B4D8C),
  SpellAffinity.earth: Color(0xFF8B6228),
};

/// Plain element name for a formula slot -- distinct from [kAffinityLabel]'s
/// flavor adjective ("Firey" etc.), which describes the effect variant
/// rather than naming the cast element.
String _elementName(SpellAffinity a) => switch (a) {
      SpellAffinity.fire  => 'Fire',
      SpellAffinity.earth => 'Earth',
      SpellAffinity.water => 'Water',
      SpellAffinity.air   => 'Air',
    };

class _Recipe {
  final EffectKind kind;
  final String pairLabel;
  const _Recipe({required this.kind, required this.pairLabel});
}

const List<_Recipe> _recipes = [
  _Recipe(kind: EffectKind.damage, pairLabel: 'Fire - Fire'),
  _Recipe(kind: EffectKind.barrier, pairLabel: 'Earth - Earth'),
  _Recipe(kind: EffectKind.reflections, pairLabel: 'Water - Water'),
  _Recipe(kind: EffectKind.speedManipulation, pairLabel: 'Air - Air'),
  _Recipe(kind: EffectKind.statusEffectInteraction, pairLabel: 'Fire - Earth'),
  _Recipe(kind: EffectKind.chainInteraction, pairLabel: 'Fire - Water'),
  _Recipe(kind: EffectKind.spellInteraction, pairLabel: 'Fire - Air'),
  _Recipe(kind: EffectKind.fuelTransmutation, pairLabel: 'Earth - Fire'),
  _Recipe(kind: EffectKind.tileModification, pairLabel: 'Earth - Water'),
  _Recipe(kind: EffectKind.rangeModification, pairLabel: 'Earth - Air'),
  _Recipe(kind: EffectKind.clouds, pairLabel: 'Water - Fire'),
  _Recipe(kind: EffectKind.artifactsInteraction, pairLabel: 'Water - Earth'),
  _Recipe(kind: EffectKind.illusions, pairLabel: 'Water - Air'),
  _Recipe(kind: EffectKind.multiplierCycles, pairLabel: 'Air - Fire'),
  _Recipe(kind: EffectKind.haymakerInteraction, pairLabel: 'Air - Earth'),
  _Recipe(kind: EffectKind.divination, pairLabel: 'Air - Water'),
];

/// A single discovered formula: one specific (affinity, effect-kind) pair,
/// i.e. one exact three-element cast (e.g. Fire-Fire-Fire), not the whole
/// four-flavor family of a base effect.
class _DiscoveredFormula {
  const _DiscoveredFormula(this.affinity, this.recipe);
  final SpellAffinity affinity;
  final _Recipe recipe;

  /// Effect name, same "[flavor adjective] [base effect]" convention the
  /// library screen uses (see [formulaEffectLabels] / [kAffinityLabel] /
  /// [kEffectKindLabel] in effect_kind.dart) -- e.g. "Firey Blast" for
  /// Fire-Fire-Fire, "Earthen Barrier" for Earth-Earth-Earth.
  String get name => '${kAffinityLabel[affinity]!} ${kEffectKindLabel[recipe.kind]!}';

  /// The exact three cast elements, e.g. "Fire - Fire - Fire".
  String get formulaLabel => '${_elementName(affinity)} - ${recipe.pairLabel}';

  String get description => kEffectDescription[recipe.kind]![affinity]!;
}

/// Recipe reference screen. In incantation mode ([isSummon] false), lists
/// every *discovered* three-element formula, titled with all three cast
/// elements. In summon mode ([isSummon] true), lists every discovered
/// creature special ability instead. Starts blank either way: a card only
/// appears once its exact formula/ability pattern has been completed at
/// least once in Rune Craft (RecipeBook, marked from main.dart's GameScreen).
class RecipesScreen extends StatefulWidget {
  const RecipesScreen({super.key, this.isSummon = false});

  final bool isSummon;

  @override
  State<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends State<RecipesScreen> {
  Set<String>? _discovered;

  @override
  void initState() {
    super.initState();
    RecipeBook.load().then((discovered) {
      if (mounted) setState(() => _discovered = discovered);
    });
  }

  @override
  Widget build(BuildContext context) {
    final discovered = _discovered;
    final visibleFormulas = widget.isSummon || discovered == null
        ? const <_DiscoveredFormula>[]
        : [
            for (final recipe in _recipes)
              for (final affinity in SpellAffinity.values)
                if (discovered.contains(recipeKey(affinity, recipe.kind)))
                  _DiscoveredFormula(affinity, recipe),
          ];
    final visibleAbilities = !widget.isSummon || discovered == null
        ? const <SummonAbility>[]
        : [
            for (final ability in SummonAbility.values)
              if (discovered.contains(summonAbilityKey(ability))) ability,
          ];
    final isEmpty = widget.isSummon ? visibleAbilities.isEmpty : visibleFormulas.isEmpty;

    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        title: Text(
          widget.isSummon ? 'Abilities' : 'Recipes',
          style: const TextStyle(color: Color(0xFFF5F0E8), letterSpacing: 3),
        ),
        backgroundColor: const Color(0xFF2C1810),
        iconTheme: const IconThemeData(color: Color(0xFFF5F0E8)),
      ),
      body: SafeScreenBody(
        child: discovered == null
            ? const Center(child: CircularProgressIndicator())
            : isEmpty
                ? _BlankBookMessage(isSummon: widget.isSummon)
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: widget.isSummon ? visibleAbilities.length : visibleFormulas.length,
                    separatorBuilder: (context, i) => const SizedBox(height: 12),
                    itemBuilder: (context, i) => widget.isSummon
                        ? _AbilityCard(ability: visibleAbilities[i])
                        : _RecipeCard(formula: visibleFormulas[i]),
                  ),
      ),
    );
  }
}

class _BlankBookMessage extends StatelessWidget {
  const _BlankBookMessage({required this.isSummon});

  final bool isSummon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book, size: 48, color: kInkMutedColor),
            const SizedBox(height: 16),
            Text(
              isSummon ? 'No abilities discovered yet.' : 'Your recipe book is blank.',
              textAlign: TextAlign.center,
              style: manuscriptHeaderStyle(fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              isSummon
                  ? 'Complete an element pattern on a Summon-mode grid in '
                      'Rune Craft and the creature ability it grants will be '
                      'recorded here.'
                  : 'Complete a three-element formula in Rune Craft and its effect '
                      'will be recorded here.',
              textAlign: TextAlign.center,
              style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecipeCard extends StatelessWidget {
  const _RecipeCard({required this.formula});

  final _DiscoveredFormula formula;

  @override
  Widget build(BuildContext context) {
    final note = kEffectNote[formula.recipe.kind]!;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF4A3020), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: kParchmentPanelColor,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 5, right: 10),
                decoration: BoxDecoration(
                  color: _kAffinityColor[formula.affinity],
                  shape: BoxShape.circle,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(formula.name, style: manuscriptHeaderStyle(fontSize: 17)),
                    const SizedBox(height: 2),
                    Text(
                      note.isEmpty ? formula.formulaLabel : '${formula.formulaLabel}  ·  $note',
                      style: manuscriptCaptionStyle(),
                    ),
                    const SizedBox(height: 6),
                    Text(formula.description, style: manuscriptBodyStyle(fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One element-sequence pattern's initials (e.g. "AWAW") spelled out as full
/// element names (e.g. "Air - Water - Air - Water"), matching
/// [_DiscoveredFormula.formulaLabel]'s convention.
String _abilityPatternLabel(String pattern) => pattern.split('').map((c) => switch (c) {
      'F' => 'Fire',
      'A' => 'Air',
      'W' => 'Water',
      'E' => 'Earth',
      _ => c,
    }).join(' - ');

class _AbilityCard extends StatelessWidget {
  const _AbilityCard({required this.ability});

  final SummonAbility ability;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF4A3020), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: kParchmentPanelColor,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.pets, size: 16, color: kIlluminationGold),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(kSummonAbilityLabel[ability]!, style: manuscriptHeaderStyle(fontSize: 17)),
                    const SizedBox(height: 2),
                    Text(
                      _abilityPatternLabel(kSummonAbilityPattern[ability]!),
                      style: manuscriptCaptionStyle(),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      kSummonAbilityDescription[ability]!,
                      style: manuscriptBodyStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
