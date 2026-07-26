// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_card_painter.dart — default art for a spell card in the library.
//
// Layout: a square parchment card holding, at its center, the spell's heraldic
// coat of arms (the same generative-heraldry escutcheon as the identity sigil,
// keyed here to the spell's grid commitment), surrounded by a ring of elemental
// symbols.
//
//   • Central shield  — SigilPainter.paintShield, keyed to commitmentHex, so
//     "Kin" spells (same grid) share the same arms.
//   • Symbol ring     — one symbol per CA step the spell ran for (spell.t).
//     Symbols are drawn from the spell's effect affinities: a flame (fire), a
//     water drop (water), a whirlwind (air), a rock (earth). A spell of a
//     single affinity shows all-identical symbols; mixed affinities split the
//     count by the effect ratio (see [elementSymbolsFor]).

import 'dart:async' show Timer;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../battle/models/creature_spec.dart';
import '../battle/models/effect_kind.dart';
import '../engine/border_zone.dart';
import '../spells/spell_art_store.dart';
import '../spells/spell_asset.dart';
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
  ) {
    final path = _elementIconPath(element, r);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.drawPath(path, Paint()..color = _elementColor(element));
    canvas.drawPath(
      path,
      Paint()
        ..color = kInkColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.5, r * 0.11)
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  /// Element glyph centered at the origin, sized to roughly fill radius [r].
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

SpellCardPainter _painterFor(SpellAsset spell) => SpellCardPainter(
  shieldBytes: _hexToBytes(spell.commitmentHex),
  symbols: elementSymbolsFor(spell.formula, spell.t),
);

/// True iff [spell] has custom art to look up in [SpellArtStore]. Both the
/// hash pointer and a non-empty key must be present -- the latter guards
/// against pre-P1 spells that somehow round-tripped a stray artHash with no
/// spellHashHex (shouldn't happen, but the store key would be meaningless).
bool _hasCustomArt(SpellAsset spell) =>
    spell.artHash != null && spell.spellHashHex.isNotEmpty;

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
/// shows just the max, as before.
/// [countered] stamps a "COUNTERED" ribbon across the card and dims/desaturates
/// it — battle_screen.dart's resolution reveal sets this for a cast a bound
/// counter charm nullified (TurnLoop.ResolvedSpellEvent.wasCountered).
/// [counteredByLabel], shown under the ribbon, names whose charm blocked it
/// (e.g. "Blocked by your ward" / "Blocked by the opponent's ward").
Future<void> showSpellCardFullscreen(
  BuildContext context,
  SpellAsset spell, {
  Duration? autoDismissAfter,
  int? liveHp,
  Offset? growFrom,
  Offset? shrinkTo,
  bool countered = false,
  String? counteredByLabel,
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
      growFrom: growFrom,
      shrinkTo: shrinkTo,
      countered: countered,
      counteredByLabel: counteredByLabel,
    ),
  );
}

/// Full-screen overlay for a spell card. When the spell has custom art, this
/// is a two-layer flip: art in front, the commitmentHex-derived coat of arms
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
    this.growFrom,
    this.shrinkTo,
    this.countered = false,
    this.counteredByLabel,
  });

  final SpellAsset spell;
  final SpellCardPainter emblemPainter;
  final Duration? autoDismissAfter;
  final int? liveHp;

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

  @override
  State<_FullscreenSpellCard> createState() => _FullscreenSpellCardState();
}

class _FullscreenSpellCardState extends State<_FullscreenSpellCard>
    with SingleTickerProviderStateMixin {
  bool _showEmblem = false;
  Future<Uint8List?>? _fullArtFuture;
  Timer? _autoDismissTimer;
  late final AnimationController _intro;
  bool _exiting = false;

  bool get _hasArt => _hasCustomArt(widget.spell);
  bool get _animated => widget.growFrom != null;

  @override
  void initState() {
    super.initState();
    if (_hasArt) {
      _fullArtFuture = SpellArtStore.loadFull(widget.spell.spellHashHex);
    }
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1020),
    );
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
    super.dispose();
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
      onHorizontalDragEnd: _hasArt
          ? (_) => setState(() => _showEmblem = !_showEmblem)
          : null,
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
                          _CardFrame(
                            spell: widget.spell,
                            emblemPainter: widget.emblemPainter,
                            showEmblem: _showEmblem,
                            hasArt: _hasArt,
                            fullArtFuture: _fullArtFuture,
                            liveHp: widget.liveHp,
                          ),
                          if (widget.countered)
                            Positioned.fill(
                              child: _CounteredOverlay(
                                sublabel: widget.counteredByLabel,
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

/// Dims the card and stamps a rubric-red "COUNTERED" ribbon diagonally
/// across it — battle_screen.dart's resolution reveal shows this over a
/// spell a bound counter charm nullified. [sublabel] (e.g. "Blocked by your
/// ward") renders under the ribbon when given.
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

/// The MTG/Pokémon-style trading-card frame: a gradient border (keyed to the
/// spell's elemental affinity mix, see [frameGradient]) around an art window,
/// a type line, and a rules-text box listing incantation effects or, for
/// summons, stats and abilities.
class _CardFrame extends StatelessWidget {
  const _CardFrame({
    required this.spell,
    required this.emblemPainter,
    required this.showEmblem,
    required this.hasArt,
    required this.fullArtFuture,
    this.liveHp,
  });

  final SpellAsset spell;
  final SpellCardPainter emblemPainter;
  final bool showEmblem;
  final bool hasArt;
  final Future<Uint8List?>? fullArtFuture;

  /// Current battlefield HP for a live summon — see [showSpellCardFullscreen]'s
  /// doc comment. Null shows just the formula-derived max (unchanged default).
  final int? liveHp;

  @override
  Widget build(BuildContext context) {
    return Container(
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
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          color: kParchmentColor,
          borderRadius: BorderRadius.circular(9),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _titleBar(),
            AspectRatio(aspectRatio: 1, child: _artWindow()),
            _typeLineBar(),
            Expanded(child: _rulesBox()),
          ],
        ),
      ),
    );
  }

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

  Widget _artWindow() {
    if (!hasArt || showEmblem) return CustomPaint(painter: emblemPainter);
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
                ? _statChipText('HP', '$liveHp/${spec.stats.maxHp}')
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

/// Default card art for a [SpellAsset].
///
/// A heraldic coat of arms (keyed to [SpellAsset.commitmentHex], so Kin spells
/// share it) ringed by one elemental symbol per CA step the spell ran for
/// ([SpellAsset.t]), split across elements by the spell's effect affinities.
///
/// If [SpellAsset.artHash] is set, the small thumbnail shows the player's
/// imported custom art instead (loaded from [SpellArtStore]) while it's
/// available, falling back to the coat of arms while loading or on a store
/// miss. Tapping always opens a full-screen overlay; when custom art is set,
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
    return SpellArtStore.loadThumb(widget.spell.spellHashHex);
  }

  @override
  Widget build(BuildContext context) {
    final painter = _painterFor(widget.spell);
    final art = SizedBox(
      width: widget.size,
      height: widget.size,
      child: FutureBuilder<Uint8List?>(
        future: _thumbFuture,
        builder: (context, snap) {
          final thumb = snap.data;
          if (thumb == null) return CustomPaint(painter: painter);
          return Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true);
        },
      ),
    );
    if (!widget.interactive) return art;
    return GestureDetector(
      onTap: () => showSpellCardFullscreen(context, widget.spell),
      child: art,
    );
  }
}
