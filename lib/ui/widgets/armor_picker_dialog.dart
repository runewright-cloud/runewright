// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_picker_dialog.dart — "Equip Armor" chooser for the chapter editor.
//
// Deliberately dumb about rules: it renders whatever [rejectionFor] says, so
// the 12-slot budget and the is-it-an-armor check stay in chapter_armor.dart
// where slice 2 put them. The one rule it enforces itself is a filter, not a
// calculation -- see the build method.

import 'package:flutter/material.dart';

import '../../spells/chapter_armor.dart' show ArmorBindError, localArmorSlotCost;
import '../../spells/spell_asset.dart';
import '../manuscript_theme.dart';

/// Equip picker. Lists ONLY armor-marked assets, and disables the ones the
/// chapter cannot afford, with the reason [ArmorBindError] gave -- the widget
/// asks the accounting seam rather than measuring anything itself.
class ArmorPickerDialog extends StatelessWidget {
  const ArmorPickerDialog({
    super.key,
    required this.candidates,
    required this.equippedId,
    required this.rejectionFor,
    required this.rejectionText,
  });

  final List<SpellAsset> candidates;
  final String? equippedId;
  final ArmorBindError? Function(SpellAsset) rejectionFor;
  final String Function(ArmorBindError, SpellAsset) rejectionText;

  @override
  Widget build(BuildContext context) {
    // Defensive as well as declarative: the caller passes only armor, and
    // this drops anything that is not, so no future call site can offer an
    // incantation or a summon for the armor slot.
    final armors = candidates.where((c) => c.isArmor).toList();
    return AlertDialog(
      backgroundColor: kParchmentColor,
      title: const Text('Equip Armor', style: TextStyle(fontFamily: 'serif')),
      content: SizedBox(
        width: 320,
        child: armors.isEmpty
            ? Text(
                'You have inscribed no armor yet. Choose Armor in Rune Craft '
                'to inscribe one.',
                style: manuscriptBodyStyle(fontSize: 14),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final a in armors)
                    Builder(builder: (_) {
                      final rejection = rejectionFor(a);
                      final equipped = a.id == equippedId;
                      return ListTile(
                        dense: true,
                        enabled: rejection == null && !equipped,
                        title: Text(
                          a.name.isNotEmpty ? a.name : 'Unnamed Armor',
                          style: const TextStyle(fontFamily: 'serif', fontSize: 14),
                        ),
                        subtitle: Text(
                          equipped
                              ? 'Currently equipped'
                              : rejection != null
                                  ? rejectionText(rejection, a)
                                  : 'T ${a.t}  ·  ${localArmorSlotCost(a)} '
                                      'artifact slot${localArmorSlotCost(a) == 1 ? '' : 's'}',
                          style: manuscriptCaptionStyle(
                            color: rejection != null ? kRubricRed : kInkMutedColor,
                          ),
                        ),
                        onTap: (rejection != null || equipped)
                            ? null
                            : () => Navigator.of(context).pop(a),
                      );
                    }),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
