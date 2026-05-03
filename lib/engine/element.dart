// The thirteen possible states a hex cell can hold.
// Note: 'void' is a reserved keyword in Dart — the transcendent state is named [voidEl].
enum Element {
  // Inscribable (player-placed)
  empty,      // 0
  fire,       // 1
  water,      // 2
  earth,      // 3
  air,        // 4

  // Emergent hybrids
  fireWater,  // 5
  fireEarth,  // 6
  fireAir,    // 7
  waterEarth, // 8
  waterAir,   // 9
  earthAir,   // 10

  // Derived transcendent
  voidEl,     // 11 — named voidEl because 'void' is reserved in Dart
  chaos;      // 12

  bool get isInscribable =>
      this == fire || this == water || this == earth || this == air;

  bool get isHybrid {
    switch (this) {
      case fireWater:
      case fireEarth:
      case fireAir:
      case waterEarth:
      case waterAir:
      case earthAir:
        return true;
      default:
        return false;
    }
  }

  bool get isDerived => this == voidEl || this == chaos;

  // Which two pure elements compose a hybrid; null for non-hybrids.
  (Element, Element)? get components {
    switch (this) {
      case fireWater:  return (fire, water);
      case fireEarth:  return (fire, earth);
      case fireAir:    return (fire, air);
      case waterEarth: return (water, earth);
      case waterAir:   return (water, air);
      case earthAir:   return (earth, air);
      default:         return null;
    }
  }
}
