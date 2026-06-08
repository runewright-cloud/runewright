import 'border_zone.dart';
import 'hex_grid.dart';

class BorderZones {
  static final Map<int, Map<HexCoord, BorderZone>> _cache = {};

  // Returns a coord→zone map for the border ring of [radius].
  // Cached — computed once per radius value.
  static Map<HexCoord, BorderZone> forRadius(int radius) {
    return _cache.putIfAbsent(radius, () => _compute(radius));
  }

  static Map<HexCoord, BorderZone> _compute(int radius) {
    final ring = _ringClockwise(radius);
    // Counter-clockwise from the bottom vertex (0, radius), which sits at
    // index 3*radius in the clockwise ring.  Going counter-clockwise means
    // decrementing the index (wrapping around).
    // Layout: water(18) | air(18) | fire(18) | earth(18) — total 72 for r=12.
    final n = ring.length;
    final start = 3 * radius;
    const segments = [
      (BorderZone.water, 18),
      (BorderZone.air,   18),
      (BorderZone.fire,  18),
      (BorderZone.earth, 18),
    ];
    final map = <HexCoord, BorderZone>{};
    int i = 0;
    for (final (zone, count) in segments) {
      for (int j = 0; j < count; j++) {
        map[ring[(start - i + n) % n]] = zone;
        i++;
      }
    }
    return map;
  }

  // Enumerates the 6r cells on ring [r] in clockwise order starting from
  // the topmost cell (0, -r).  Each of the 6 sides contributes r cells;
  // the starting corner of each side is included, the ending corner is not.
  static List<HexCoord> _ringClockwise(int r) {
    // (corner unit vector, step direction) for each side going clockwise.
    const sides = [
      ((0, -1), ( 1,  0)), // top        → top-right
      ((1, -1), ( 0,  1)), // top-right  → right
      ((1,  0), (-1,  1)), // right      → bottom-right
      ((0,  1), (-1,  0)), // bottom-right → bottom-left
      ((-1, 1), ( 0, -1)), // bottom-left → left
      ((-1, 0), ( 1, -1)), // left       → top
    ];
    final coords = <HexCoord>[];
    for (final ((cq, cr), (dq, dr)) in sides) {
      int q = cq * r;
      int row = cr * r;
      for (int step = 0; step < r; step++) {
        coords.add(HexCoord(q, row));
        q += dq;
        row += dr;
      }
    }
    return coords;
  }
}
