// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_card_painter.dart — default art for a spell card in the library.
//
// Layout: a square parchment card holding, at its center, the spell's heraldic
// coat of arms (the same generative-heraldry escutcheon as the identity sigil,
// keyed here to the spell's grid commitment), surrounded by a ring of elemental
// symbols.
//
//   • Central shield  — SigilPainter.paintShield, keyed to the spell's
//     TRAJECTORY (spell_identity.dart's heraldicArmsKey), so "Kin" spells —
//     spells that do the same thing — share the same arms. This used to be
//     keyed to the grid commitment, back when kinship meant "same grid".
//   • Symbol ring     — one symbol per CA step the spell ran for (spell.t).
//     Symbols are drawn from the spell's effect affinities: a flame (fire), a
//     water drop (water), a whirlwind (air), a rock (earth). A spell of a
//     single affinity shows all-identical symbols; mixed affinities split the
//     count by the effect ratio (see [elementSymbolsFor]).
//
// The fullscreen trading card (_CardFrame) additionally shows a dominance-tags
// strip across its top: the same four element glyphs, small and in a fixed
// row, colored where SpellAsset.supremeTags was achieved and dimmed where not
// — signaling which cast-time enhancement (Potency/Velocity/Efficiency/
// Mystery) this spell is eligible for. See _DominanceTagsStrip.
//
// ── Wild magic ────────────────────────────────────────────────────────────────
// A spell that carries wild magic (wild_magic_preview.dart) gets two extra
// treatments, and only such spells get them:
//
//   • a foil luster (FoilSheen) over the whole card, at both sizes, so the
//     wild ones are findable by eye in a library page or a hand tray, and
//   • a rubric-red WILD MAGIC panel below the rules box naming each effect it
//     fires, with the symmetric description ("all players") verbatim from
//     kWildMagicEffectDescription.
//
// Wild magic is untelegraphed DURING a duel by design — the resolution reveal
// is where an opponent learns it fired — but it is a fixed, public property of
// the rune, and hiding it from the card's owner would just be a memory tax.
// The panel previews under whichever leyline seed is in force
// (activeLeylineSeed); see wild_magic_preview.dart on why that is not always
// the player's own.

import 'dart:async' show Timer;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../battle/models/creature_spec.dart';
import '../battle/models/effect_kind.dart';
import '../battle/models/wild_magic_effect.dart';
import '../engine/border_zone.dart';
import '../spells/spell_art_resolver.dart';
import '../spells/spell_identity.dart';
import '../spells/spell_asset.dart';
import '../spells/wild_magic_preview.dart';
import 'foil_sheen.dart';
import 'manuscript_theme.dart';
import 'sigil_painter.dart';

// ── Elemental palette (illuminated folio tones) ───────────────────────────────

const _kFireColor = Color(0xFFB84040); // cinnabar / vermillion
const _kAirColor = Color(0xFF6E93B8); // cerulean sky (deepened for contrast)
const _kWaterColor = Color(0xFF2B4D8C); // ultramarine
const _kEarthColor = Color(0xFF8B6228); // raw umber

Color _elementColor(String element) => switch (element) {
  'fire' => _kFireColor,
  'air' => _kAirColor,
  'water' => _kWaterColor,
  'earth' => _kEarthColor,
  _ => kIlluminationGold,
};

/// Canonical element order (matches BorderZone) — used as a deterministic
/// tiebreak when distributing symbols and ordering them around the ring.
const List<String> _elementOrder = ['fire', 'air', 'water', 'earth'];

const Map<String, String> _kElementDisplayName = {
  'fire': 'Fire',
  'air': 'Air',
  'water': 'Water',
  'earth': 'Earth',
};

/// Cast-time enhancement each element's supreme dominance unlocks — mirrors
/// the mapping documented in casting_enhancements.dart (Fire=Potency,
/// Air=Velocity, Water=Efficiency, Earth=Mystery). Used to label the card's
/// dominance-tags strip.
const Map<String, String> _kCastingStyleName = {
  'fire': 'Potency',
  'air': 'Velocity',
  'water': 'Efficiency',
  'earth': 'Mystery',
};

const Map<SpellAffinity, String> _kSpellAffinityName = {
  SpellAffinity.fire: 'Fire',
  SpellAffinity.air: 'Air',
  SpellAffinity.water: 'Water',
  SpellAffinity.earth: 'Earth',
};

/// Effect-affinity counts for [formula]: the first entry of each complete
/// triplet, falling back to raw activation counts when there's no complete
/// triplet (legacy/very short castings so the result isn't empty). Shared by
/// [elementSymbolsFor] and the frame color helpers below.
Map<String, int> _formulaAffinityCounts(List<String> formula) {
  final counts = <String, int>{};
  for (var i = 0; i + 3 <= formula.length; i += 3) {
    final a = formula[i].toLowerCase();
    if (_elementOrder.contains(a)) counts[a] = (counts[a] ?? 0) + 1;
  }
  if (counts.isEmpty) {
    for (final z in formula) {
      final a = z.toLowerCase();
      if (_elementOrder.contains(a)) counts[a] = (counts[a] ?? 0) + 1;
    }
  }
  return counts;
}

/// [formula]'s zone-name entries, parsed into [BorderZone]s (unrecognised
/// entries dropped) — used to derive a summon's [CreatureSpec].
List<BorderZone> _borderZoneSequence(List<String> formula) => formula
    .map(
      (n) => switch (n.toLowerCase()) {
        'fire' => BorderZone.fire,
        'earth' => BorderZone.earth,
        'water' => BorderZone.water,
        'air' => BorderZone.air,
        _ => null,
      },
    )
    .whereType<BorderZone>()
    .toList();

/// The card frame's color(s) for [formula]'s effect-affinity mix, paired with
/// each color's share of the total (fractions sum to 1), in canonical
/// fire/air/water/earth order. A single-element formula (or one with no
/// recognisable elements, e.g. a legacy spell predating formula tracking)
/// returns a single entry — callers should paint a solid frame; two or more
/// elements returns a proportional blend.
List<(Color, double)> frameColorShares(List<String> formula) {
  final counts = _formulaAffinityCounts(formula);
  if (counts.isEmpty) return [(kIlluminationGold, 1.0)];
  final total = counts.values.fold<int>(0, (s, v) => s + v);
  return [
    for (final e in _elementOrder.where(counts.containsKey))
      (_elementColor(e), counts[e]! / total),
  ];
}

/// A diagonal (top-left to bottom-right) gradient built from
/// [frameColorShares], for painting the fullscreen card's outer frame. Each
/// color is anchored at the midpoint of its proportional share so the blend
/// leans toward whichever element contributed more effects; a single-color
/// result degenerates to a solid fill.
Gradient frameGradient(List<String> formula) {
  final shares = frameColorShares(formula);
  final colors = [for (final s in shares) s.$1];
  if (colors.length == 1) {
    return LinearGradient(colors: [colors[0], colors[0]]);
  }
  // Each color's stop sits at the midpoint of its cumulative share -- e.g.
  // fire 0.67/water 0.33 puts fire's stop at 0.335 and water's at 0.835, so
  // fire holds solid through roughly its own half-share before blending.
  // Deliberately NOT clamped to [0, 1] at the ends: LinearGradient clamps
  // colors outside the stop range to the nearest endpoint on its own, and
  // forcing the first/last stops to 0/1 would collapse the two-color case
  // (the most common mix) into a plain unweighted blend.
  final stops = <double>[];
  var cum = 0.0;
  for (final s in shares) {
    stops.add(cum + s.$2 / 2);
    cum += s.$2;
  }
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: colors,
    stops: stops,
  );
}

Color _colorForAffinity(SpellAffinity a) => switch (a) {
  SpellAffinity.fire => _kFireColor,
  SpellAffinity.air => _kAirColor,
  SpellAffinity.water => _kWaterColor,
  SpellAffinity.earth => _kEarthColor,
};

/// The fullscreen card's frame gradient: for incantations, the ratio-weighted
/// blend from [frameGradient]; for summons, a SOLID color from the
/// creature's single derived affinity ([CreatureSpec.affinity]) rather than a
/// gradient over its casting sequence's full element mix — a summon has
/// exactly one canonical affinity (also used for its resistance wheel), even
/// though the sequence that derived it may touch several elements.
Gradient cardFrameGradient(SpellAsset spell) {
  if (!spell.isSummon) return frameGradient(spell.formula);
  final spec = CreatureSpec.fromElements(_borderZoneSequence(spell.formula));
  final color = spec == null
      ? kIlluminationGold
      : _colorForAffinity(spec.affinity);
  return LinearGradient(colors: [color, color]);
}

/// The fullscreen card's type line, e.g. "Incantation — Fire, Water" or
/// "Summon — Fire". Falls back to the bare category when no elemental data
/// is recoverable (a legacy spell with an empty formula).
String cardTypeLine(SpellAsset spell) {
  if (spell.isSummon) {
    final spec = CreatureSpec.fromElements(_borderZoneSequence(spell.formula));
    if (spec == null) return 'Summon';
    return 'Summon — ${_kSpellAffinityName[spec.affinity]}';
  }
  final counts = _formulaAffinityCounts(spell.formula);
  if (counts.isEmpty) return 'Incantation';
  final names = [
    for (final e in _elementOrder.where(counts.containsKey))
      _kElementDisplayName[e]!,
  ];
  return 'Incantation — ${names.join(', ')}';
}

// ── Symbol allocation ─────────────────────────────────────────────────────────

/// Computes the ring of elemental symbols for a spell that ran [steps] CA steps
/// with the given flat [formula] (committed activations; each complete triplet
/// is one *effect* whose FIRST entry is its elemental affinity).
///
/// Returns exactly [steps] symbols, each a list of element names: length 1 is a
/// plain symbol, length 2 is a *split* symbol (half one element, half another).
/// The symbol counts follow the ratio of effect affinities, allocated by the
/// largest-remainder method; when the leftover units fall on a tie between
/// equal fractional remainders, those tied elements are paired into split
/// symbols rather than rounded arbitrarily.
///
///   • 2 water + 1 fire effects over 12 steps → 8 water, 4 fire.
///   • 2 water + 1 fire + 1 air effects over 14 steps → 7 water, 3 fire,
///     3 air, and 1 fire/air split.
List<List<String>> elementSymbolsFor(List<String> formula, int steps) {
  if (steps <= 0) return const [];

  // Count effect affinities: the first entry of each complete triplet
  // (falling back to raw activation counts for legacy/very-short castings).
  final counts = _formulaAffinityCounts(formula);

  final total = counts.values.fold<int>(0, (s, v) => s + v);
  if (total == 0) return const [];

  final elems = _elementOrder.where(counts.containsKey).toList();

  // Real-valued share → integer base + fractional remainder.
  final base = <String, int>{};
  final frac = <String, double>{};
  for (final e in elems) {
    final exact = steps * counts[e]! / total;
    base[e] = exact.floor();
    frac[e] = exact - base[e]!;
  }
  var remaining = steps - base.values.fold<int>(0, (s, v) => s + v);

  // Leftover units go to the largest fractional remainders; ties become splits.
  final extraFull = <String>[];
  final splits = <List<String>>[];
  final byFrac = [...elems]
    ..sort((a, b) {
      final c = frac[b]!.compareTo(frac[a]!);
      if (c != 0) return c;
      return _elementOrder.indexOf(a).compareTo(_elementOrder.indexOf(b));
    });

  var i = 0;
  while (remaining > 0 && i < byFrac.length) {
    var j = i;
    while (j < byFrac.length &&
        (frac[byFrac[j]]! - frac[byFrac[i]]!).abs() < 1e-9) {
      j++;
    }
    final group = byFrac.sublist(i, j);
    if (remaining >= group.length) {
      extraFull.addAll(group);
      remaining -= group.length;
      i = j;
    } else {
      // Fewer leftover units than tied elements: pair them into split symbols.
      var g = 0;
      while (remaining > 0 && g < group.length) {
        if (g + 1 < group.length) {
          splits.add([group[g], group[g + 1]]);
          g += 2;
        } else {
          extraFull.add(group[g]);
          g += 1;
        }
        remaining--;
      }
    }
  }

  // Assemble: full symbols grouped by element (canonical order), then splits.
  final symbols = <List<String>>[];
  for (final e in elems) {
    final n = base[e]! + extraFull.where((x) => x == e).length;
    for (var k = 0; k < n; k++) {
      symbols.add([e]);
    }
  }
  symbols.addAll(splits);
  return symbols;
}

// ── SpellCardPainter ──────────────────────────────────────────────────────────

class SpellCardPainter extends CustomPainter {
  SpellCardPainter({
    required this.shieldBytes,
    required this.symbols,
    this.saturation = 1.35,
  });

  /// Key bytes driving the central heraldic shield (the spell's commitment).
  final Uint8List shieldBytes;

  /// One entry per surrounding symbol; length 1 = plain, length 2 = split.
  final List<List<String>> symbols;

  final double saturation;

  @override
  bool shouldRepaint(SpellCardPainter o) =>
      o.shieldBytes != shieldBytes ||
      o.saturation != saturation ||
      !_sameSymbols(o.symbols, symbols);

  static bool _sameSymbols(List<List<String>> a, List<List<String>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (var j = 0; j < a[i].length; j++) {
        if (a[i][j] != b[i][j]) return false;
      }
    }
    return true;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final c = Offset(size.width / 2, size.height / 2);

    _paintBackground(canvas, size);

    // Symbol ring geometry. Symbols shrink as their number grows, and the ring
    // radius pulls in just enough to keep the outermost symbol inside the card.
    final n = symbols.length;
    double symR = 0.075 * s;
    if (n > 0) {
      symR = math.min(symR, math.pi * (0.40 * s) / n * 0.92);
      symR = math.max(symR, 0.018 * s);
    }
    final ringR = math.min(0.40 * s, 0.485 * s - symR);

    // Central shield, sized to sit inside the ring.
    final shieldW = 0.50 * s;
    final shieldH = 0.55 * s;
    final shieldRect = Rect.fromCenter(
      center: Offset(c.dx, c.dy + shieldH * 0.08),
      width: shieldW,
      height: shieldH,
    );
    SigilPainter(
      shieldBytes,
      saturation: saturation,
    ).paintShield(canvas, shieldRect);

    // Ring of elemental symbols, starting at 12 o'clock and going clockwise.
    for (var i = 0; i < n; i++) {
      final angle = -math.pi / 2 + 2 * math.pi * i / n;
      final center = c + Offset(math.cos(angle), math.sin(angle)) * ringR;
      _drawSymbol(canvas, center, symR, symbols[i]);
    }

    _paintFrame(canvas, size, s);
  }

  void _paintBackground(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kParchmentPanelColor);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [kParchmentColor, kParchmentPanelColor],
          radius: 0.75,
        ).createShader(Offset.zero & size),
    );
  }

  void _paintFrame(Canvas canvas, Size size, double s) {
    final c = Offset(size.width / 2, size.height / 2);
    final inset = s * 0.03;
    final rect = Rect.fromCenter(
      center: c,
      width: s - inset * 2,
      height: s - inset * 2,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = kIlluminationGold
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, s * 0.012),
    );
    canvas.drawRect(
      rect.deflate(s * 0.018),
      Paint()
        ..color = kInkColor.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.6, s * 0.004),
    );
  }

  // ── Symbols ──────────────────────────────────────────────────────────────

  void _drawSymbol(Canvas canvas, Offset center, double r, List<String> parts) {
    if (parts.length == 1) {
      _drawElementIcon(canvas, center, r, parts[0]);
      return;
    }
    // Split symbol: left half of element A, right half of element B.
    final bounds = Rect.fromCircle(center: center, radius: r * 1.2);
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(bounds.left, bounds.top, center.dx, bounds.bottom),
    );
    _drawElementIcon(canvas, center, r, parts[0]);
    canvas.restore();
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(center.dx, bounds.top, bounds.right, bounds.bottom),
    );
    _drawElementIcon(canvas, center, r, parts[1]);
    canvas.restore();
    // Dividing line.
    canvas.drawLine(
      Offset(center.dx, center.dy - r),
      Offset(center.dx, center.dy + r),
      Paint()
        ..color = kInkColor
        ..strokeWidth = math.max(0.5, r * 0.09),
    );
  }

  void _drawElementIcon(
    Canvas canvas,
    Offset center,
    double r,
    String element,
  ) => paintElementIcon(canvas, center, r, element);
}

/// Element glyph centered at the origin, sized to roughly fill radius [r].
/// Module-level (rather than a [SpellCardPainter] method) so the small
/// dominance-tags badges on the fullscreen card can reuse the same shapes.
Path _elementIconPath(String element, double r) {
  final u = r * 0.92;
  switch (element) {
    case 'fire':
      return _flame(u);
    case 'water':
      return _drop(u);
    case 'air':
      return _whirlwind(u);
    case 'earth':
      return _rock(u);
    default:
      return Path()
        ..addOval(Rect.fromCircle(center: Offset.zero, radius: u * 0.7));
  }
}

/// Paints [element]'s glyph (fill + ink outline) centered at [center] with
/// radius [r]. [opacity] fades a not-yet-achieved dominance badge without
/// changing its shape or color identity.
void paintElementIcon(
  Canvas canvas,
  Offset center,
  double r,
  String element, {
  double opacity = 1.0,
}) {
  final path = _elementIconPath(element, r);
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.drawPath(
    path,
    Paint()..color = _elementColor(element).withValues(alpha: opacity),
  );
  canvas.drawPath(
    path,
    Paint()
      ..color = kInkColor.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.5, r * 0.11)
      ..strokeJoin = StrokeJoin.round,
  );
  canvas.restore();
}

// A flame: a bulbous base rising to a tall curling tip, with a side lick —
// deliberately asymmetric so it never reads as the water drop.
Path _flame(double u) {
  final p = Path();
  p.moveTo(0.0, u); // bottom center
  // right side rising
  p.cubicTo(0.62 * u, 0.78 * u, 0.66 * u, 0.15 * u, 0.40 * u, -0.18 * u);
  // main tongue curling up, leaning left over the top
  p.cubicTo(0.26 * u, -0.42 * u, 0.10 * u, -0.52 * u, 0.16 * u, -0.82 * u);
  p.cubicTo(0.19 * u, -1.02 * u, -0.02 * u, -1.04 * u, -0.08 * u, -0.80 * u);
  // dip between main tongue and the side lick
  p.cubicTo(-0.13 * u, -0.56 * u, -0.22 * u, -0.5 * u, -0.36 * u, -0.52 * u);
  // side lick flicking out to the left
  p.cubicTo(-0.24 * u, -0.36 * u, -0.44 * u, -0.28 * u, -0.52 * u, -0.30 * u);
  p.cubicTo(-0.44 * u, -0.04 * u, -0.62 * u, 0.22 * u, -0.50 * u, 0.52 * u);
  p.cubicTo(-0.42 * u, 0.80 * u, -0.22 * u, 0.90 * u, 0.0, u);
  p.close();
  return p;
}

// A water drop: a symmetric teardrop, round bottom, pointed top.
Path _drop(double u) {
  final p = Path();
  p.moveTo(0, -u);
  p.cubicTo(0.62 * u, -0.15 * u, 0.66 * u, 0.5 * u, 0.30 * u, 0.8 * u);
  p.cubicTo(0.12 * u, 0.96 * u, -0.12 * u, 0.96 * u, -0.30 * u, 0.8 * u);
  p.cubicTo(-0.66 * u, 0.5 * u, -0.62 * u, -0.15 * u, 0, -u);
  p.close();
  // highlight glint
  p.moveTo(-0.12 * u, 0.28 * u);
  p.cubicTo(-0.34 * u, 0.28 * u, -0.34 * u, 0.6 * u, -0.12 * u, 0.62 * u);
  p.cubicTo(-0.02 * u, 0.5 * u, -0.02 * u, 0.36 * u, -0.12 * u, 0.28 * u);
  p.close();
  p.fillType = PathFillType.evenOdd;
  return p;
}

// A whirlwind: a funnel (wide top, narrow foot) with swept swirl lines.
Path _whirlwind(double u) {
  final p = Path();
  // funnel outline
  p.moveTo(-0.9 * u, -0.85 * u);
  p.cubicTo(0.1 * u, -1.05 * u, 0.95 * u, -0.7 * u, 0.78 * u, -0.5 * u);
  p.cubicTo(0.55 * u, -0.28 * u, -0.35 * u, -0.42 * u, 0.28 * u, -0.15 * u);
  p.cubicTo(0.6 * u, 0.02 * u, -0.1 * u, 0.05 * u, 0.32 * u, 0.28 * u);
  p.cubicTo(0.55 * u, 0.42 * u, 0.05 * u, 0.5 * u, 0.16 * u, 0.72 * u);
  p.cubicTo(0.24 * u, 0.9 * u, -0.05 * u, u, -0.12 * u, u);
  p.cubicTo(-0.35 * u, 0.9 * u, -0.2 * u, 0.62 * u, -0.5 * u, 0.42 * u);
  p.cubicTo(-0.85 * u, 0.18 * u, -0.2 * u, 0.12 * u, -0.7 * u, -0.12 * u);
  p.cubicTo(-1.0 * u, -0.32 * u, -0.35 * u, -0.4 * u, -0.9 * u, -0.62 * u);
  p.close();
  return p;
}

// A rock: an irregular faceted boulder with an internal facet crease.
Path _rock(double u) {
  final p = Path();
  p.moveTo(-0.85 * u, 0.15 * u);
  p.lineTo(-0.5 * u, -0.55 * u);
  p.lineTo(0.15 * u, -0.8 * u);
  p.lineTo(0.7 * u, -0.4 * u);
  p.lineTo(0.9 * u, 0.25 * u);
  p.lineTo(0.5 * u, 0.8 * u);
  p.lineTo(-0.35 * u, 0.82 * u);
  p.lineTo(-0.8 * u, 0.45 * u);
  p.close();
  // facet creases (drawn as thin sub-paths; even-odd keeps them as cuts)
  p.moveTo(0.15 * u, -0.8 * u);
  p.lineTo(0.02 * u, 0.0 * u);
  p.lineTo(0.5 * u, 0.8 * u);
  p.lineTo(0.42 * u, 0.02 * u);
  p.close();
  p.moveTo(0.02 * u, 0.0 * u);
  p.lineTo(-0.8 * u, 0.45 * u);
  p.lineTo(-0.34 * u, 0.06 * u);
  p.close();
  p.fillType = PathFillType.evenOdd;
  return p;
}

// ── SpellCardWidget ───────────────────────────────────────────────────────────

Uint8List _hexToBytes(String hex) {
  if (hex.isEmpty) return Uint8List(32);
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final n = clean.length ~/ 2;
  final result = Uint8List(n);
  for (var i = 0; i < n; i++) {
    result[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

/// The card's default art for [spell].
///
/// The shield is keyed to the spell's TRAJECTORY (heraldicArmsKey), not its
/// grid commitment: kinship became behavioural in
/// docs/COUNTER_CHARM_KINSHIP_PLAN.md Phase 3, and arms exist so kin are
/// recognisable on sight — so the arms had to follow the new definition or
/// stop meaning "kin" at all. A legacy asset with no recorded formula falls
/// back to its commitment, keeping such cards distinct from one another.
SpellCardPainter _painterFor(SpellAsset spell) => SpellCardPainter(
  shieldBytes: _hexToBytes(
    heraldicArmsKey(spell.formula, fallbackHex: spell.commitmentHex),
  ),
  symbols: elementSymbolsFor(spell.formula, spell.t),
);

/// True iff [spell] has custom art to resolve (spell_art_resolver.dart).
/// Source-aware: built-in pack art is keyed by [SpellAsset.artPackId], not
/// [SpellAsset.spellHashHex] (the [SpellArtStore] key), so the two sources
/// need different presence checks. Guards against a spell that somehow
/// round-tripped a stray artHash with no matching key for its source
/// (shouldn't happen, but the key would be meaningless).
bool _hasCustomArt(SpellAsset spell) {
  if (spell.artHash == null) return false;
  if (spell.artSource == SpellArtSource.builtIn) return spell.artPackId != null;
  return spell.spellHashHex.isNotEmpty;
}

/// Desaturates to luminance, then re-tints it cold blue — the "phantasmal"
/// treatment for a creature that is a copy of another rather than a real cast
/// (Reflections' mirror summon, Illusions' clone). It wears the original's
/// card art so players can see *what* it is at a glance; this filter is what
/// says it isn't the genuine article.
///
/// Luminance weights are the usual Rec. 709 triple; the per-channel scales
/// (0.38 / 0.66 / 1.05) tint toward blue while the additive offsets lift the
/// shadows so dark art doesn't collapse into an unreadable black square.
const ColorFilter kPhantasmalFilter = ColorFilter.matrix(<double>[
  0.0808, 0.2718, 0.0274, 0, 8,
  0.1403, 0.4720, 0.0477, 0, 14,
  0.2232, 0.7510, 0.0758, 0, 30,
  0, 0, 0, 1, 0,
]);

/// Opens a full-screen overlay of [spell]'s card art, dismissed by tapping
/// anywhere. Exposed publicly so callers that need a custom gesture mapping
/// (e.g. long-press instead of tap) can trigger it directly rather than
/// going through [SpellCardWidget]'s own tap handler.
///
/// When [autoDismissAfter] is set, the overlay also pops itself after that
/// duration (a tap still dismisses it early) — used by battle_screen.dart's
/// resolution-phase card reveal ("show the full card for 2 seconds").
///
/// [liveHp] is set only for a live on-grid summon (battle_screen.dart's
/// minion-thumbnail long-tap): when non-null, a summon's rules box shows
/// "HP: current/max" instead of just the formula-derived max, so players can
/// see how much damage their creature has taken. Null (the default, and
/// always the case for a library/hand card, which has no battlefield HP yet)
/// shows just the max, as before. [liveMaxHp] overrides the denominator with
/// the creature's actual max, which differs from the card's formula-derived
/// one for a copy (an Illusions clone is maxHp 1 whatever it copied).
/// [phantasmal] renders the whole card under [kPhantasmalFilter] — set for a
/// copied creature, which wears the original's art (see Minion
/// .copiedFromMinionId).
/// [countered] stamps a "COUNTERED" ribbon across the card and dims/desaturates
/// it — battle_screen.dart's resolution reveal sets this for a cast a counter
/// charm nullified ENTIRELY (TurnLoop.ResolvedSpellEvent.wasCountered).
/// [counteredByLabel], shown under the ribbon, names whose charm blocked it
/// (e.g. "Blocked by your ward" / "Blocked by the opponent's ward").
///
/// [partialCounterLabel] is the other half of the trajectory-charm redesign
/// (docs/COUNTER_CHARM_KINSHIP_PLAN.md §2.3): a charm that matched only a
/// PREFIX of the cast cancels those formulas and lets the rest resolve. That
/// card must still read as a spell that happened, so it gets a small banner
/// rather than the occluding ribbon — the two are mutually exclusive.
Future<void> showSpellCardFullscreen(
  BuildContext context,
  SpellAsset spell, {
  Duration? autoDismissAfter,
  int? liveHp,
  int? liveMaxHp,
  Offset? growFrom,
  Offset? shrinkTo,
  bool countered = false,
  String? counteredByLabel,
  String? partialCounterLabel,
  bool phantasmal = false,
}) {
  return showDialog<void>(
    context: context,
    // The resolution-phase reveal ([growFrom] set) grows the card out of the
    // tile it hit and keeps the battlefield visible behind it — a black-out
    // there would hide the very thing the card is pointing at. A manually
    // viewed card still dims the UI so the art reads on its own.
    barrierColor: growFrom != null
        ? Colors.transparent
        : Colors.black.withValues(alpha: 0.92),
    barrierDismissible: true,
    builder: (ctx) => _FullscreenSpellCard(
      spell: spell,
      emblemPainter: _painterFor(spell),
      autoDismissAfter: autoDismissAfter,
      liveHp: liveHp,
      liveMaxHp: liveMaxHp,
      growFrom: growFrom,
      shrinkTo: shrinkTo,
      countered: countered,
      counteredByLabel: counteredByLabel,
      partialCounterLabel: countered ? null : partialCounterLabel,
      phantasmal: phantasmal,
    ),
  );
}

/// Full-screen overlay for a spell card. When the spell has custom art, this
/// is a two-layer flip: art in front, the trajectory-derived coat of arms
/// behind, reachable by a horizontal swipe. The true emblem must never be
/// fully hidden (anti-spoof guarantee -- CLAUDE.md custom-art invariant 3),
/// so the swipe-to-emblem gesture is always live whenever art is set. A tap
/// dismisses the dialog either way, matching the pre-existing behavior for
/// spells with no custom art.
class _FullscreenSpellCard extends StatefulWidget {
  const _FullscreenSpellCard({
    required this.spell,
    required this.emblemPainter,
    this.autoDismissAfter,
    this.liveHp,
    this.liveMaxHp,
    this.growFrom,
    this.shrinkTo,
    this.countered = false,
    this.counteredByLabel,
    this.partialCounterLabel,
    this.phantasmal = false,
  });

  final SpellAsset spell;
  final SpellCardPainter emblemPainter;
  final Duration? autoDismissAfter;
  final int? liveHp;
  final int? liveMaxHp;

  /// Global-screen point the card should grow out of on entry (the tile a
  /// resolution-phase spell just hit). Null → the card fades in centered, the
  /// unchanged behavior for manually-viewed cards.
  final Offset? growFrom;

  /// Global-screen point the card should reverse-bloom into on exit — where
  /// its thumbnail lands (the incantation tray, or a summon's grid tile).
  /// Only used when [growFrom] is set (the resolution reveal); falls back to
  /// [growFrom] if null there.
  final Offset? shrinkTo;

  /// See [showSpellCardFullscreen]'s doc comment.
  final bool countered;
  final String? counteredByLabel;
  final String? partialCounterLabel;
  final bool phantasmal;

  @override
  State<_FullscreenSpellCard> createState() => _FullscreenSpellCardState();
}

class _FullscreenSpellCardState extends State<_FullscreenSpellCard>
    with TickerProviderStateMixin {
  bool _showEmblem = false;
  bool _prevShowEmblem = false;
  Future<Uint8List?>? _fullArtFuture;
  Timer? _autoDismissTimer;
  late final AnimationController _intro;
  late final AnimationController _flip;
  late final AnimationController _flash;
  bool _exiting = false;

  bool get _hasArt => _hasCustomArt(widget.spell);
  bool get _animated => widget.growFrom != null;

  @override
  void initState() {
    super.initState();
    if (_hasArt) {
      _fullArtFuture = resolveSpellArtFull(widget.spell);
    }
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1020),
    );
    // Idle at 1.0 (fully showing whichever face _showEmblem points at); a
    // toggle replays it from 0 so the art window rotates like a little card
    // flipping over. See _CardFrame._artWindow for the two-face math.
    _flip = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: 1.0,
    );
    // A double-pulse of rubric red across the whole card, played once on
    // entry when this cast was countered — reads as a hit landing before the
    // card settles into the static COUNTERED ribbon (_CounteredOverlay).
    // Idle at 0 (invisible) for every non-countered card.
    _flash = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    if (widget.countered) _flash.forward();
    // Grow out of the hit point when we have one; otherwise present instantly
    // (manual card views keep their original, un-animated appearance).
    if (widget.growFrom != null) {
      _intro.forward();
    } else {
      _intro.value = 1.0;
    }
    final delay = widget.autoDismissAfter;
    if (delay != null) {
      _autoDismissTimer = Timer(delay, _dismiss);
    }
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _intro.dispose();
    _flip.dispose();
    _flash.dispose();
    super.dispose();
  }

  /// Flips the art window between custom art and the true sigil. Ignored
  /// mid-flip so a fast double-swipe can't desync [_prevShowEmblem].
  void _toggleEmblem() {
    if (_flip.isAnimating) return;
    setState(() {
      _prevShowEmblem = _showEmblem;
      _showEmblem = !_showEmblem;
    });
    _flip.forward(from: 0.0);
  }

  /// Dismisses the card. For a resolution-reveal card (animated), it first
  /// reverse-blooms into [widget.shrinkTo] (where its thumbnail lands) at the
  /// same speed it grew in; a manually-viewed card just pops.
  Future<void> _dismiss() async {
    if (_exiting || !mounted) return;
    if (!_animated) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _exiting = true);
    await _intro.reverse();
    if (mounted) Navigator.of(context).pop();
  }

  /// Cold-blue monochrome for a copied creature's card; a pass-through for
  /// every other card. See [kPhantasmalFilter].
  Widget _tinted(Widget child) => widget.phantasmal
      ? ColorFiltered(colorFilter: kPhantasmalFilter, child: child)
      : child;

  /// The card content, transformed so it blooms out of [widget.growFrom] on
  /// entry and reverse-blooms into [widget.shrinkTo] on exit (scale + fade,
  /// anchored at the relevant tile). [_intro] runs 0→1 in, 1→0 out.
  Widget _grown(BuildContext context, Widget child) {
    final growFrom = widget.growFrom;
    if (growFrom == null) return child;
    final screen = MediaQuery.of(context).size;
    Alignment anchorFor(Offset p) => Alignment(
      (p.dx / screen.width * 2 - 1).clamp(-1.0, 1.0),
      (p.dy / screen.height * 2 - 1).clamp(-1.0, 1.0),
    );
    return AnimatedBuilder(
      animation: _intro,
      builder: (ctx, inner) {
        // Grow from the hit tile; shrink toward the thumbnail's resting spot.
        final anchor = anchorFor(
          _exiting ? (widget.shrinkTo ?? growFrom) : growFrom,
        );
        final scale = Curves.easeOutCubic.transform(_intro.value);
        // Fade in on entry, but stay fully opaque on exit — the card shrinks
        // straight into its (opaque) thumbnail rather than dissolving first.
        return Opacity(
          opacity: _exiting ? 1.0 : _intro.value.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.04 + 0.96 * scale,
            alignment: anchor,
            child: inner,
          ),
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _dismiss,
      onHorizontalDragEnd: _hasArt ? (_) => _toggleEmblem() : null,
      behavior: HitTestBehavior.opaque,
      child: Dialog.fullscreen(
        backgroundColor: Colors.transparent,
        child: _grown(
          context,
          Center(
            child: Builder(
              builder: (innerCtx) {
                final screen = MediaQuery.of(innerCtx).size;
                final maxW = screen.width * 0.86;
                final maxH = screen.height * 0.82;
                // Trading-card portrait aspect (~2.5:3.5), clamped to the screen.
                const cardAspect = 0.68;
                var w = maxW;
                var h = w / cardAspect;
                if (h > maxH) {
                  h = maxH;
                  w = h * cardAspect;
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: w,
                      height: h,
                      child: Stack(
                        children: [
                          // The phantasmal tint wraps the card itself, not the
                          // overlays: a countered copy still needs its red
                          // ribbon to read as red.
                          _tinted(
                            // Rebuilds on a leyline-seed change so a card left
                            // open across a settings edit can't keep claiming
                            // wild magic it no longer has.
                            ValueListenableBuilder<String>(
                              valueListenable: activeLeylineSeed,
                              builder: (_, seed, _) => AnimatedBuilder(
                                animation: _flip,
                                builder: (_, _) => _CardFrame(
                                  spell: widget.spell,
                                  emblemPainter: widget.emblemPainter,
                                  showEmblem: _showEmblem,
                                  prevShowEmblem: _prevShowEmblem,
                                  flipT: _flip.value,
                                  hasArt: _hasArt,
                                  fullArtFuture: _fullArtFuture,
                                  liveHp: widget.liveHp,
                                  liveMaxHp: widget.liveMaxHp,
                                  wildMagic: wildMagicPreviewFor(
                                    widget.spell,
                                    seed,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (widget.countered)
                            Positioned.fill(
                              child: _CounteredOverlay(
                                sublabel: widget.counteredByLabel,
                              ),
                            ),
                          if (widget.partialCounterLabel case final label?)
                            Positioned(
                              left: 0,
                              right: 0,
                              top: 0,
                              child: _PartialCounterBanner(label: label),
                            ),
                          if (widget.countered)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: AnimatedBuilder(
                                  animation: _flash,
                                  builder: (_, _) => Container(
                                    key: const Key('countered-flash'),
                                    color: kRubricRed.withValues(
                                      alpha: _kCounteredFlashCurve
                                          .transform(_flash.value),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_hasArt) ...[
                      const SizedBox(height: 16),
                      Text(
                        _showEmblem
                            ? 'Swipe to see the custom art'
                            : 'Swipe to see the true sigil',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Opacity curve for [_FullscreenSpellCardState._flash]: two quick pulses of
/// full-bleed red (0→0.85→0.1→0.75→0) over the controller's 520ms, landing at
/// 0 so the card is left showing only the persistent [_CounteredOverlay]
/// dim+ribbon underneath once it settles.
final Animatable<double> _kCounteredFlashCurve = TweenSequence<double>([
  TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.85), weight: 15),
  TweenSequenceItem(tween: Tween(begin: 0.85, end: 0.85), weight: 5),
  TweenSequenceItem(tween: Tween(begin: 0.85, end: 0.10), weight: 20),
  TweenSequenceItem(tween: Tween(begin: 0.10, end: 0.75), weight: 15),
  TweenSequenceItem(tween: Tween(begin: 0.75, end: 0.75), weight: 5),
  TweenSequenceItem(tween: Tween(begin: 0.75, end: 0.0), weight: 40),
]);

/// Dims the card and stamps a rubric-red "COUNTERED" ribbon diagonally
/// across it — battle_screen.dart's resolution reveal shows this over a
/// spell a bound counter charm nullified. [sublabel] (e.g. "Blocked by your
/// ward") renders under the ribbon when given.
/// The partial-counter treatment: a charm matched a prefix of this cast and
/// cancelled those formulas, but the rest resolved.
///
/// Deliberately a thin banner rather than [_CounteredOverlay]'s full-card
/// stamp — the art underneath still has to read, because the spell really did
/// go off. A player who sees the occluding ribbon should be able to trust it
/// means "nothing happened".
class _PartialCounterBanner extends StatelessWidget {
  const _PartialCounterBanner({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        key: const Key('partial-counter-banner'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        color: kRubricRed.withValues(alpha: 0.88),
        alignment: Alignment.center,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'serif',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: kParchmentColor,
          ),
        ),
      ),
    );
  }
}

class _CounteredOverlay extends StatelessWidget {
  const _CounteredOverlay({this.sublabel});

  final String? sublabel;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Container(
        color: kInkColor.withValues(alpha: 0.62),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.rotate(
              angle: -0.35,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                decoration: BoxDecoration(
                  color: kRubricRed,
                  border: Border.all(color: kParchmentColor, width: 2),
                ),
                child: Text(
                  'COUNTERED',
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontWeight: FontWeight.w700,
                    fontSize: 26,
                    letterSpacing: 3,
                    color: kParchmentColor,
                    shadows: [
                      Shadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 4),
                    ],
                  ),
                ),
              ),
            ),
            if (sublabel != null) ...[
              const SizedBox(height: 14),
              Text(
                sublabel!,
                style: const TextStyle(
                  fontFamily: 'serif',
                  fontSize: 14,
                  letterSpacing: 0.5,
                  color: kParchmentColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A row of four small elemental badges across the top of the fullscreen
/// card, one per BorderZone, showing which supreme-dominance tags [SpellAsset
/// .supremeTags] achieved (colored) versus not (dimmed) — and thus which
/// cast-time enhancement (Potency/Velocity/Efficiency/Mystery, see
/// casting_enhancements.dart) this spell is eligible for in battle. Always
/// shows all four so a player can see the full space of casting styles, not
/// just the ones this spell happens to unlock.
class _DominanceTagsStrip extends StatelessWidget {
  const _DominanceTagsStrip({required this.supremeTags});

  final List<String> supremeTags;

  @override
  Widget build(BuildContext context) {
    final achieved = supremeTags.map((e) => e.toLowerCase()).toSet();
    return Container(
      width: double.infinity,
      color: kParchmentPanelColor,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final e in _elementOrder) ...[
            if (e != _elementOrder.first) const SizedBox(width: 12),
            Tooltip(
              message: _tooltipFor(e, achieved.contains(e)),
              child: SizedBox(
                width: 15,
                height: 15,
                child: CustomPaint(
                  painter: _ElementBadgePainter(
                    element: e,
                    achieved: achieved.contains(e),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _tooltipFor(String element, bool achieved) {
    final name = _kElementDisplayName[element]!;
    final style = _kCastingStyleName[element]!;
    return achieved ? '$name — $style (eligible)' : '$name — $style (not achieved)';
  }
}

/// Paints a single small element glyph for [_DominanceTagsStrip], full
/// strength when [achieved] and faded when not — reuses the same icon paths
/// as the emblem's effect-affinity ring ([paintElementIcon]) so the glyph
/// vocabulary stays consistent across the card, even though this row encodes
/// a different fact (dominance eligibility, not effect counts).
class _ElementBadgePainter extends CustomPainter {
  const _ElementBadgePainter({required this.element, required this.achieved});

  final String element;
  final bool achieved;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2 * 0.92;
    paintElementIcon(
      canvas,
      Offset(size.width / 2, size.height / 2),
      r,
      element,
      opacity: achieved ? 1.0 : 0.25,
    );
  }

  @override
  bool shouldRepaint(covariant _ElementBadgePainter old) =>
      old.element != element || old.achieved != achieved;
}

/// The MTG/Pokémon-style trading-card frame: a gradient border (keyed to the
/// spell's elemental affinity mix, see [frameGradient]) around an art window,
/// a type line, and a rules-text box listing incantation effects or, for
/// summons, stats and abilities.
///
/// When [hasArt], this is one face of a physical card that flips over: the
/// front (custom art + title/type/rules, built by this class) and the back
/// (just the true coat of arms centered on parchment, see [_CardBack]) rotate
/// as a single rigid rectangle — see [build]'s 0 → π mapping.
class _CardFrame extends StatelessWidget {
  const _CardFrame({
    required this.spell,
    required this.emblemPainter,
    required this.showEmblem,
    this.prevShowEmblem = false,
    this.flipT = 1.0,
    required this.hasArt,
    required this.fullArtFuture,
    this.liveHp,
    this.liveMaxHp,
    this.wildMagic = const [],
  });

  final SpellAsset spell;
  final SpellCardPainter emblemPainter;

  /// The wild-magic effects this spell fires under the leyline seed currently
  /// in force, empty for the great majority of spells. Non-empty turns on both
  /// the foil luster and the [_WildMagicPanel] — see this file's header.
  final List<WildMagicTrigger> wildMagic;

  /// True → the back (coat of arms) is the face this flip is settling on (or
  /// has already settled on, at rest). False → the front (custom art).
  final bool showEmblem;

  /// Which face was showing before the in-progress flip started. Only
  /// consulted while [flipT] < 0.5, i.e. before the card has rotated edge-on
  /// to swap faces.
  final bool prevShowEmblem;

  /// 0 → 1 progress of the current flip (1 = at rest on [showEmblem]). Maps
  /// to a 0 → π rotation of the whole card: the first half rotates
  /// [prevShowEmblem]'s face away, the second half rotates [showEmblem]'s
  /// face in, so it reads as one continuous card turning over rather than a
  /// cross-fade.
  final double flipT;

  final bool hasArt;
  final Future<Uint8List?>? fullArtFuture;

  /// Current battlefield HP for a live summon — see [showSpellCardFullscreen]'s
  /// doc comment. Null shows just the formula-derived max (unchanged default).
  final int? liveHp;

  /// The creature's real max HP, when it differs from the card's
  /// formula-derived one (a copy). Only read alongside [liveHp].
  final int? liveMaxHp;

  @override
  Widget build(BuildContext context) {
    final angle = flipT * math.pi;
    final onFrontHalf = angle < math.pi / 2;
    final faceIsBack = onFrontHalf ? prevShowEmblem : showEmblem;
    // The back half is pre-rotated by -π so it arrives right-side-up instead
    // of mirrored when it swings past the edge-on midpoint.
    final faceAngle = onFrontHalf ? angle : angle - math.pi;
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0015)
        ..rotateY(faceAngle),
      child: _shell(faceIsBack ? _CardBack(emblemPainter: emblemPainter) : _frontContent()),
    );
  }

  /// The gradient border + parchment interior shared by both faces — the
  /// rigid "card" that rotates, regardless of which content it holds.
  ///
  /// A wild-magic card additionally gets a gold bloom in its drop shadow and
  /// the [FoilSheen] laid over everything inside the frame, clipped to the
  /// same rounded rectangle so the luster stops exactly where the card does.
  Widget _shell(Widget child) {
    final foil = wildMagic.isNotEmpty;
    final card = Container(
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        gradient: cardFrameGradient(spell),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
          if (foil)
            BoxShadow(
              color: kIlluminationGold.withValues(alpha: 0.45),
              blurRadius: 26,
              spreadRadius: 1,
            ),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          color: kParchmentColor,
          borderRadius: BorderRadius.circular(9),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
    if (!foil) return card;
    return Stack(
      children: [
        card,
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: const FoilSheen(),
          ),
        ),
      ],
    );
  }

  Widget _frontContent() => Column(
    children: [
      _DominanceTagsStrip(supremeTags: spell.supremeTags),
      _titleBar(),
      AspectRatio(aspectRatio: 1, child: _artWindow()),
      _typeLineBar(),
      Expanded(child: _rulesBox()),
      if (wildMagic.isNotEmpty) _WildMagicPanel(triggers: wildMagic),
    ],
  );

  Widget _titleBar() => Container(
    color: kInkColor,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            spell.name.isEmpty ? 'Unnamed Spell' : spell.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFF5F0E8),
              fontFamily: 'serif',
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '♦ ${spell.manaCost}',
          style: const TextStyle(
            color: kIlluminationGold,
            fontFamily: 'serif',
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
      ],
    ),
  );

  /// The front's art window. Always the custom art (falling back to the
  /// emblem while it loads, or always for a no-art spell) — the true emblem
  /// itself now lives full-size on [_CardBack], reached by flipping the
  /// whole card rather than swapping this window's content.
  Widget _artWindow() {
    if (!hasArt) return CustomPaint(painter: emblemPainter);
    return FutureBuilder<Uint8List?>(
      future: fullArtFuture,
      builder: (context, snap) {
        final full = snap.data;
        if (full == null) return CustomPaint(painter: emblemPainter);
        return Image.memory(full, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }

  Widget _typeLineBar() => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: kParchmentPanelColor,
      border: Border(
        top: BorderSide(color: kInkColor.withValues(alpha: 0.4)),
        bottom: BorderSide(color: kInkColor.withValues(alpha: 0.4)),
      ),
    ),
    child: Text(
      cardTypeLine(spell),
      style: manuscriptBodyStyle(
        fontSize: 13,
      ).copyWith(fontWeight: FontWeight.w600),
    ),
  );

  Widget _rulesBox() => Padding(
    padding: const EdgeInsets.all(10),
    child: spell.isSummon ? _summonRulesBody() : _incantationRulesBody(),
  );

  Widget _incantationRulesBody() {
    final effects = formulaEffects(spell.formula);
    if (effects.isEmpty) {
      return Text(
        'No recorded effects.',
        style: manuscriptBodyStyle(fontSize: 13, color: kInkMutedColor),
      );
    }
    return ListView.separated(
      itemCount: effects.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) =>
          _ruleLine(effects[i].name, effects[i].description),
    );
  }

  Widget _summonRulesBody() {
    final spec = CreatureSpec.fromElements(_borderZoneSequence(spell.formula));
    if (spec == null) {
      return Text(
        'Void Summon — no recorded elements.',
        style: manuscriptBodyStyle(fontSize: 13, color: kInkMutedColor),
      );
    }
    final abilities = spec.abilities.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            liveHp != null
                ? _statChipText(
                    'HP',
                    '$liveHp/${liveMaxHp ?? spec.stats.maxHp}',
                  )
                : _statChip('HP', spec.stats.maxHp),
            _statChip('DMG', spec.stats.damage),
            _statChip('Move', spec.stats.moveSpeed),
            _statChip('Range', spec.stats.attackRange),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: abilities.isEmpty
              ? Text(
                  'No abilities.',
                  style: manuscriptBodyStyle(
                    fontSize: 13,
                    color: kInkMutedColor,
                  ),
                )
              : ListView.separated(
                  itemCount: abilities.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _ruleLine(
                    kSummonAbilityLabel[abilities[i]]!,
                    kSummonAbilityDescription[abilities[i]]!,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _statChip(String label, int value) => _statChipText(label, '$value');

  Widget _statChipText(String label, String value) => Text(
    '$label $value',
    style: manuscriptBodyStyle(
      fontSize: 13,
    ).copyWith(fontWeight: FontWeight.w700),
  );

  Widget _ruleLine(String name, String description) => RichText(
    text: TextSpan(
      style: manuscriptBodyStyle(fontSize: 13),
      children: [
        TextSpan(
          text: '$name: ',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        TextSpan(text: description),
      ],
    ),
  );
}

/// The card's wild-magic panel: a rubric-red band under the rules box naming
/// every effect this spell fires, with the effect's own one-line description.
///
/// Visually separated from the rules box on purpose. A wild-magic effect is
/// not one of the spell's effects: it is GLOBAL, SYMMETRIC and ignores tile
/// targeting entirely (wild_magic_effect.dart), so it hits the caster too.
/// Printing it in the same list as "Fireball: 3 damage to the target tile"
/// would invite exactly the misreading the descriptions' "every wizard" voice
/// is written to prevent.
///
/// A balanced spell can fire a whole row at once (up to four effects, one per
/// element), so the panel is height-capped and scrolls rather than squeezing
/// the rules box off the card.
class _WildMagicPanel extends StatelessWidget {
  const _WildMagicPanel({required this.triggers});

  final List<WildMagicTrigger> triggers;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: kRubricRed,
        border: Border(top: BorderSide(color: kIlluminationGold, width: 2)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '✦ WILD MAGIC ✦',
            style: TextStyle(
              fontFamily: 'serif',
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 2,
              color: kIlluminationGold.withValues(alpha: 0.95),
            ),
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 96),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: triggers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, i) => _effectLine(triggers[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _effectLine(WildMagicTrigger trigger) => RichText(
    text: TextSpan(
      style: const TextStyle(
        fontFamily: 'serif',
        fontSize: 12,
        height: 1.25,
        color: kParchmentColor,
      ),
      children: [
        TextSpan(
          text: kWildMagicEffectLabel[trigger.effect]!,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: kIlluminationGold,
          ),
        ),
        TextSpan(
          text: ' (${_kSpellAffinityName[trigger.element]}) — ',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: kWildMagicEffectDescription[trigger.effect]!),
      ],
    ),
  );
}

/// The back of a flipped spell card: the true coat of arms (with its own
/// gold frame + elemental ring, painted by [emblemPainter]), centered on the
/// same parchment interior [_CardFrame] uses for its front. This is the
/// anti-spoof guarantee (CLAUDE.md custom-art invariant 3) made physical —
/// the true emblem is always one flip away, never just hidden.
class _CardBack extends StatelessWidget {
  const _CardBack({required this.emblemPainter});

  final SpellCardPainter emblemPainter;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.86,
        child: AspectRatio(
          aspectRatio: 1,
          child: CustomPaint(painter: emblemPainter),
        ),
      ),
    );
  }
}

/// Default card art for a [SpellAsset].
///
/// A heraldic coat of arms (keyed to the spell's trajectory, so Kin spells
/// share it) ringed by one elemental symbol per CA step the spell ran for
/// ([SpellAsset.t]), split across elements by the spell's effect affinities.
///
/// If [SpellAsset.artHash] is set, the small thumbnail shows the player's
/// custom art instead (an imported image or a built-in pack icon, resolved
/// via spell_art_resolver.dart) while it's available, falling back to the
/// coat of arms while loading or on a resolver miss. Tapping always opens a
/// full-screen overlay; when custom art is set,
/// that overlay is a two-layer flip (see [_FullscreenSpellCard]) so the true
/// emblem stays reachable.
class SpellCardWidget extends StatefulWidget {
  const SpellCardWidget({
    super.key,
    required this.spell,
    this.size = 88,
    this.interactive = true,
  });

  final SpellAsset spell;
  final double size;

  /// When false, this widget renders only the art with no gesture handling
  /// of its own -- for callers that wrap it in their own tap/long-press
  /// logic (e.g. a spell tile where a tap should select the spell rather
  /// than zoom the art).
  final bool interactive;

  @override
  State<SpellCardWidget> createState() => _SpellCardWidgetState();
}

class _SpellCardWidgetState extends State<SpellCardWidget> {
  late Future<Uint8List?> _thumbFuture;

  @override
  void initState() {
    super.initState();
    _thumbFuture = _loadThumb();
  }

  @override
  void didUpdateWidget(covariant SpellCardWidget old) {
    super.didUpdateWidget(old);
    if (old.spell.spellHashHex != widget.spell.spellHashHex ||
        old.spell.artHash != widget.spell.artHash) {
      _thumbFuture = _loadThumb();
    }
  }

  Future<Uint8List?> _loadThumb() {
    if (!_hasCustomArt(widget.spell)) return Future.value(null);
    return resolveSpellArtThumb(widget.spell);
  }

  @override
  Widget build(BuildContext context) {
    final painter = _painterFor(widget.spell);
    final art = SizedBox(
      width: widget.size,
      height: widget.size,
      child: ValueListenableBuilder<String>(
        valueListenable: activeLeylineSeed,
        builder: (context, seed, child) {
          if (wildMagicPreviewFor(widget.spell, seed).isEmpty) return child!;
          // Thumbnails run as small as 36px in the battle hand tray, where the
          // full-card intensity all but disappears — push it up so the luster
          // still reads as "this one is wild" at a glance.
          final boost = widget.size < 64 ? 1.5 : 1.15;
          return Stack(
            fit: StackFit.expand,
            children: [child!, FoilSheen(intensity: boost)],
          );
        },
        child: FutureBuilder<Uint8List?>(
          future: _thumbFuture,
          builder: (context, snap) {
            final thumb = snap.data;
            if (thumb == null) return CustomPaint(painter: painter);
            return Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true);
          },
        ),
      ),
    );
    if (!widget.interactive) return art;
    return GestureDetector(
      onTap: () => showSpellCardFullscreen(context, widget.spell),
      child: art,
    );
  }
}
