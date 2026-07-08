// SPDX-License-Identifier: GPL-3.0-or-later
//
// effect_descriptor.dart — EffectDescriptor: resolved formula → typed effect.
//
// Returned by EffectResolver.resolve(). Carries the affinity, the effect kind
// (which of the 16 base types), and the fully-constructed SpellEffect with
// potency already folded in. EffectApplicator.apply() consumes this.
//
// SpellAffinity and spellAffinityFromZone live in effect_kind.dart (alongside
// EffectKind) to keep the effect layer self-contained and to avoid import
// cycles with spell_effect.dart.

// Re-export SpellAffinity so callers that used to import it from here continue
// to compile — they get it from effect_kind.dart via this file.
export 'package:rune_duel/battle/models/effect_kind.dart'
    show SpellAffinity, spellAffinityFromZone, primaryFormulaAffinity;

import 'package:rune_duel/battle/models/effect_kind.dart'
    show EffectKind, SpellAffinity;
import 'package:rune_duel/battle/models/spell_effect.dart' show SpellEffect;

/// A fully-resolved formula: affinity (table row), effect kind (table column
/// group), and the concrete [spellEffect] with all parameters pre-computed.
class EffectDescriptor {
  const EffectDescriptor({
    required this.affinity,
    required this.effectKind,
    required this.spellEffect,
  });

  /// First triplet entry — selects the flavor column in the effect table.
  final SpellAffinity affinity;

  /// Which of the 16 base effect types this formula produced.
  final EffectKind effectKind;

  /// Concrete effect with potency folded in, ready for EffectApplicator.
  final SpellEffect spellEffect;

  @override
  String toString() => 'EffectDescriptor($affinity, $effectKind)';
}
