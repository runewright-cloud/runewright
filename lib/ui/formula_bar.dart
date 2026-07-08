import 'package:flutter/material.dart' hide Element;
import '../battle/models/effect_kind.dart' show formulaTripletKind, kAffinityLabel, kEffectKindLabel;
import '../engine/border_zone.dart';

class FormulaBar extends StatelessWidget {
  final List<List<BorderZone>> formulas;
  final List<BorderZone> residuals;
  final BorderZone? pendingZone;

  const FormulaBar({
    super.key,
    required this.formulas,
    required this.residuals,
    required this.pendingZone,
  });

  static const _zoneColors = {
    BorderZone.fire:  Color(0xFFCC3311),
    BorderZone.air:   Color(0xFF6699BB),
    BorderZone.water: Color(0xFF2255AA),
    BorderZone.earth: Color(0xFF7A5C28),
  };

  static const _zoneNames = {
    BorderZone.fire:  'Fire',
    BorderZone.air:   'Air',
    BorderZone.water: 'Water',
    BorderZone.earth: 'Earth',
  };

  Widget _chip(BorderZone zone, {double opacity = 1.0}) {
    final color = _zoneColors[zone]!;
    return Opacity(
      opacity: opacity,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          border: Border.all(color: color, width: 1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          _zoneNames[zone]!,
          style: TextStyle(
            color: color,
            fontSize: 11,
            letterSpacing: 0.5,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  // A complete triple, visually bracketed, with the effect it produces
  // (same "[flavor] [base effect]" naming as the library/recipe book --
  // see kAffinityLabel/kEffectKindLabel in effect_kind.dart) named beneath.
  Widget _formulaGroup(List<BorderZone> zones) {
    final (affinity, kind) = formulaTripletKind(zones);
    final effectName = '${kAffinityLabel[affinity]!} ${kEffectKindLabel[kind]!}';
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF4A3020), width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < zones.length; i++) ...[
                if (i > 0)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      '·',
                      style: TextStyle(color: Color(0xFF6A5040), fontSize: 11),
                    ),
                  ),
                _chip(zones[i]),
              ],
            ],
          ),
          Text(
            effectName,
            style: const TextStyle(
              color: Color(0xFF9A9488),
              fontSize: 9,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasContent =
        formulas.isNotEmpty || residuals.isNotEmpty || pendingZone != null;

    return Container(
      color: const Color(0xFF1E0E08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text(
            'Formula',
            style: TextStyle(
              color: Color(0xFF9A9488),
              fontSize: 11,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (!hasContent)
                    const Text(
                      '—',
                      style: TextStyle(color: Color(0xFF4A3020), fontSize: 11),
                    )
                  else ...[
                    for (final formula in formulas) _formulaGroup(formula),
                    // Residuals: confirmed activations, not yet grouped
                    for (final zone in residuals) _chip(zone, opacity: 0.75),
                    // Pending: in-progress, not yet committed
                    if (pendingZone != null) _chip(pendingZone!, opacity: 0.4),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
