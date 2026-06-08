import 'border_zone.dart';
import 'ca_rules.dart';

// Tracks which elements activate during a simulation, in order.
//
// Neutral between activations does not split the formula — it only allows the
// same element to appear consecutively (fire→neutral→fire counts as two fires).
//
// Activations are grouped into formulas of exactly 3.  Any remainder (1 or 2)
// is held as residuals until enough activations arrive to complete the next group.
class FormulaTracker {
  final List<BorderZone> _committed = [];
  BorderZone? _pendingZone;

  // All finalized activations.
  List<BorderZone> get committed => List.unmodifiable(_committed);

  // Complete formula groups of 3 activations each.
  List<List<BorderZone>> get formulas {
    final result = <List<BorderZone>>[];
    for (int i = 0; i + 3 <= _committed.length; i += 3) {
      result.add(List.unmodifiable(_committed.sublist(i, i + 3)));
    }
    return result;
  }

  // Activations that haven't yet filled a group of 3 (length 0–2).
  List<BorderZone> get residuals {
    final start = (_committed.length ~/ 3) * 3;
    return List.unmodifiable(_committed.sublist(start));
  }

  BorderZone? get pendingZone => _pendingZone;

  static BorderZone? zoneFor(CARules rules) {
    const map = {
      'Fire':  BorderZone.fire,
      'Wind':  BorderZone.air,
      'Water': BorderZone.water,
      'Earth': BorderZone.earth,
    };
    return map[rules.name];
  }

  void step(BorderZone? zone, {bool supremeDominant = false}) {
    if (supremeDominant && zone != null) {
      // During supreme dominance each turn commits directly — no buffering.
      _flush();
      _pendingZone = null;
      _committed.add(zone);
    } else if (zone == _pendingZone) {
      // Same zone continues — nothing to do until it changes.
    } else {
      _flush();
      _pendingZone = zone;
    }
  }

  void _flush() {
    if (_pendingZone == null) return;
    _committed.add(_pendingZone!);
  }

  void reset() {
    _committed.clear();
    _pendingZone = null;
  }
}
