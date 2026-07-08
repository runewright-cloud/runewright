// SPDX-License-Identifier: GPL-3.0-or-later
//
// recipes_screen.dart — reference screen listing every discovered
// three-element formula (affinity + the second/third-element pair that
// selects the base effect), reachable from Rune Craft's app bar. A card
// appears the first time its exact formula completes during Rune Craft play
// (main.dart's GameScreen, via RecipeBook). Descriptions are transcribed
// from the Effect Table in docs/runewright_design_v3_0.md §Effect Table,
// base values only. That table's bracketed numbers are the Potency
// enhancement -- a modifier the CA may independently attach to *any*
// formula, not something intrinsic to the formula itself -- so they're
// deliberately omitted here. That table is flagged "Needs Playtesting" in
// the design doc -- these are display text only and don't drive battle
// resolution (effect_resolver.dart does, from the same table).

import 'package:flutter/material.dart';

import '../battle/models/effect_kind.dart';
import '../spells/recipe_book.dart';
import 'manuscript_theme.dart';

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
  final String note;
  final Map<SpellAffinity, String> variants;
  const _Recipe({
    required this.kind,
    required this.pairLabel,
    required this.note,
    required this.variants,
  });
}

const List<_Recipe> _recipes = [
  _Recipe(
    kind: EffectKind.damage,
    pairLabel: 'Fire - Fire',
    note: 'Instant.',
    variants: {
      SpellAffinity.fire: '4 damage.',
      SpellAffinity.earth:
          '2 damage; also damages walls or sprites it intersects en route to the target.',
      SpellAffinity.water: '2 splash damage (area radius 2).',
      SpellAffinity.air: '2 damage and 1 knockback.',
    },
  ),
  _Recipe(
    kind: EffectKind.barrier,
    pairLabel: 'Earth - Earth',
    note: 'Barrier lasts 2 turns.',
    variants: {
      SpellAffinity.fire: '2 HP; adjacent tiles take 1 fire damage at end of turn.',
      SpellAffinity.earth: '4 HP.',
      SpellAffinity.water: '2 HP, plus 10% mana regen while active.',
      SpellAffinity.air: '2 HP; caster gets a free move when it collapses.',
    },
  ),
  _Recipe(
    kind: EffectKind.reflections,
    pairLabel: 'Water - Water',
    note: '2 triggers. Only valid if the spell resolves on an enemy.',
    variants: {
      SpellAffinity.fire: 'Whenever the caster takes damage, the target takes equal damage.',
      SpellAffinity.earth:
          'Whenever the target creates a summon, the caster creates an identical summon under the caster\'s control.',
      SpellAffinity.water: 'Whenever the target gains mana, the caster gains equal mana.',
      SpellAffinity.air:
          'Whenever the target gains a status effect it cast on itself, the caster gains the same status effect.',
    },
  ),
  _Recipe(
    kind: EffectKind.speedManipulation,
    pairLabel: 'Air - Air',
    note: 'Self-targeted flavors are instant; targeted flavors have a duration.',
    variants: {
      SpellAffinity.fire:
          'Move n extra tiles at a cost of n(n+1)/2 health (1 tile free).',
      SpellAffinity.earth: 'Reduce target move speed by 1 for 3 turns.',
      SpellAffinity.water:
          'High Liquidity: move n extra tiles at a cost of n(n+1)/2 × 100 mana (1 tile free).',
      SpellAffinity.air: 'Increase target move speed by 1 for 2 turns.',
    },
  ),
  _Recipe(
    kind: EffectKind.statusEffectInteraction,
    pairLabel: 'Fire - Earth',
    note: 'Acts on active status effects.',
    variants: {
      SpellAffinity.fire: '1 damage per active status effect.',
      SpellAffinity.earth: 'All status effects go dormant for 2 turns.',
      SpellAffinity.water: 'Status effects lose 1 turn.',
      SpellAffinity.air: 'All status effects gain 1 turn.',
    },
  ),
  _Recipe(
    kind: EffectKind.chainInteraction,
    pairLabel: 'Fire - Water',
    note: 'Acts on the caster\'s elemental chain bonuses.',
    variants: {
      SpellAffinity.fire: 'Chain bonuses accumulate twice as fast for the next 2 turns.',
      SpellAffinity.earth: 'Chain bonuses grow at half speed for the next 3 turns.',
      SpellAffinity.water:
          'Gain all chain status of the affected target, overwriting your existing chains.',
      SpellAffinity.air: 'All chain bonuses removed.',
    },
  ),
  _Recipe(
    kind: EffectKind.spellInteraction,
    pairLabel: 'Fire - Air',
    note: 'Acts on the target\'s next spell cast.',
    variants: {
      SpellAffinity.fire:
          'Next spell\'s cost is paid twice; any mana shortfall converts to health damage at 1 HP per 10 mana.',
      SpellAffinity.earth:
          '"Sluggish" — always resolves last unless others are also sluggish, for 3 turns.',
      SpellAffinity.water: 'Copy the enemy\'s spell.',
      SpellAffinity.air:
          '"Quick" — always resolves first unless others are also quick, for 2 turns.',
    },
  ),
  _Recipe(
    kind: EffectKind.fuelTransmutation,
    pairLabel: 'Earth - Fire',
    note: 'Trades one resource for another.',
    variants: {
      SpellAffinity.fire:
          'Wither 1 random active spell, found via bookmark; gain 1 random non-counter-charm artifact.',
      SpellAffinity.earth: 'Burn 4 life; reactivate 1 withered spell.',
      SpellAffinity.water: 'Burn 100 mana; gain 4 life.',
      SpellAffinity.air: 'Burn 1 random artifact; gain 100 mana.',
    },
  ),
  _Recipe(
    kind: EffectKind.tileModification,
    pairLabel: 'Earth - Water',
    note: '',
    variants: {
      SpellAffinity.fire: 'Floor is Lava: 2 damage to pass through.',
      SpellAffinity.earth:
          'Impassable terrain that also blocks spells passing through it for line of sight.',
      SpellAffinity.water: 'Costs 2 movement to enter and drains mana on entry.',
      SpellAffinity.air:
          'Conveyor tile force-moves whatever stands on it; direction is chosen at effect resolution and is permanent.',
    },
  ),
  _Recipe(
    kind: EffectKind.rangeModification,
    pairLabel: 'Earth - Air',
    note: 'Acts on spell range, for 2 turns unless noted.',
    variants: {
      SpellAffinity.fire:
          'Penetrating: spells can\'t be blocked by walls; 1 damage to anything in hexes en route.',
      SpellAffinity.earth: 'Reduce spell range by 1 for 3 turns.',
      SpellAffinity.water:
          'Turbulent: next spell fires in the intended direction but its range is randomized 1–max.',
      SpellAffinity.air: 'Increase spell range by 1.',
    },
  ),
  _Recipe(
    kind: EffectKind.clouds,
    pairLabel: 'Water - Fire',
    note: 'Radius 1 (2 for Water), 2 turns. Entities in the cloud may only '
        'target/be targeted by adjacent entities.',
    variants: {
      SpellAffinity.fire: 'Entities entering or ending their turn in the cloud take 1 damage.',
      SpellAffinity.earth:
          'The adjacent-only targeting restriction lingers 2 turns after leaving the cloud.',
      SpellAffinity.water: 'The cloud is radius 2 instead of 1.',
      SpellAffinity.air:
          'The cloud moves 1 tile each turn, trying to center on the closest enemy (players before summons).',
    },
  ),
  _Recipe(
    kind: EffectKind.artifactsInteraction,
    pairLabel: 'Water - Earth',
    note: '',
    variants: {
      SpellAffinity.fire:
          'Burn a random player artifact to deal 1 damage (random target via joint entropy; can\'t hit the core gem; burning a counter charm reveals its target).',
      SpellAffinity.earth: 'Summon 1 Absorption Totem.',
      SpellAffinity.water: 'Summon 1 mana gem.',
      SpellAffinity.air: 'Summon 1 bookmark.',
    },
  ),
  _Recipe(
    kind: EffectKind.illusions,
    pairLabel: 'Water - Air',
    note: 'Illusory copies.',
    variants: {
      SpellAffinity.fire:
          'Copy the summon on the target tile for yourself; the copy attacks aggressively and has 1 HP.',
      SpellAffinity.earth:
          'Copy the terrain on the target tile onto every terrain-free neighboring tile; the copies have 1 HP.',
      SpellAffinity.water:
          'Create 3 illusions of yourself spaced around your position. When you\'re subjected to a spell or '
          'attack, a chance of 1 in the number of illusions remaining means you\'re hit; otherwise a random '
          'illusion is destroyed and you\'re moved to its tile instead.',
      SpellAffinity.air: 'The non-wizard entity on the target tile is reduced to 1 HP.',
    },
  ),
  _Recipe(
    kind: EffectKind.multiplierCycles,
    pairLabel: 'Air - Fire',
    note: 'Doubles the power of the caster\'s next effect of the named element.',
    variants: {
      SpellAffinity.fire: 'Your next air effect is twice as powerful.',
      SpellAffinity.earth: 'Your next fire effect is twice as powerful.',
      SpellAffinity.water: 'Your next earth effect is twice as powerful.',
      SpellAffinity.air: 'Your next water effect is twice as powerful.',
    },
  ),
  _Recipe(
    kind: EffectKind.haymakerInteraction,
    pairLabel: 'Air - Earth',
    note: 'Lasts 2 turns.',
    variants: {
      SpellAffinity.fire:
          'Stacking fire damage-over-time; damage equals turns remaining, 2 turns at a time.',
      SpellAffinity.earth: 'Target move speed reduced by 1.',
      SpellAffinity.water: 'Target\'s status effects lose a turn.',
      SpellAffinity.air: 'Bonus damage equal to spaces moved toward the target.',
    },
  ),
  _Recipe(
    kind: EffectKind.divination,
    pairLabel: 'Air - Water',
    note: 'Information effects.',
    variants: {
      SpellAffinity.fire:
          'See the target\'s counter-charm alignment; turns bookmarks marking those spells red for the rest of the match.',
      SpellAffinity.earth: 'Identify illusions and see through clouds, 1 turn.',
      SpellAffinity.water: 'See the target\'s available spells, 2 turns.',
      SpellAffinity.air: 'See the target\'s spell target tile, 2 turns.',
    },
  ),
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

  String get description => recipe.variants[affinity]!;
}

/// Recipe reference screen — every *discovered* three-element formula,
/// titled with all three cast elements. Starts blank: a card only appears
/// once its exact formula has been completed at least once in Rune Craft
/// (RecipeBook, marked from main.dart's GameScreen).
class RecipesScreen extends StatefulWidget {
  const RecipesScreen({super.key});

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
    final visible = discovered == null
        ? const <_DiscoveredFormula>[]
        : [
            for (final recipe in _recipes)
              for (final affinity in SpellAffinity.values)
                if (discovered.contains(recipeKey(affinity, recipe.kind)))
                  _DiscoveredFormula(affinity, recipe),
          ];

    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        title: const Text(
          'Recipes',
          style: TextStyle(color: Color(0xFFF5F0E8), letterSpacing: 3),
        ),
        backgroundColor: const Color(0xFF2C1810),
        iconTheme: const IconThemeData(color: Color(0xFFF5F0E8)),
      ),
      body: SafeArea(
        child: discovered == null
            ? const Center(child: CircularProgressIndicator())
            : visible.isEmpty
                ? const _BlankBookMessage()
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: visible.length,
                    separatorBuilder: (context, i) => const SizedBox(height: 12),
                    itemBuilder: (context, i) => _RecipeCard(formula: visible[i]),
                  ),
      ),
    );
  }
}

class _BlankBookMessage extends StatelessWidget {
  const _BlankBookMessage();

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
              'Your recipe book is blank.',
              textAlign: TextAlign.center,
              style: manuscriptHeaderStyle(fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Complete a three-element formula in Rune Craft and its effect '
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
    final note = formula.recipe.note;
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
