class CARules {
  final String name;
  final Set<int> surviveOn;
  final Set<int> bornOn;

  /// True only for [neutral]. CAStep.step dispatches on this explicit flag
  /// rather than `== CARules.neutral` identity -- a future refactor that
  /// constructs an equivalent-valued CARules (even a `const` one with the
  /// same surviveOn/bornOn) would silently fall through to count-based
  /// stepping with identity dispatch; this flag can't be spoofed by accident.
  final bool isNeutral;

  const CARules({
    required this.name,
    required this.surviveOn,
    required this.bornOn,
    this.isNeutral = false,
  });

  // surviveOn/bornOn below are vestigial for actual stepping -- CAStep.step
  // routes isNeutral==true to the ink ruleset (ink_step.dart) instead. They
  // remain here only because ca_run_test.dart's circuit-comparison test
  // still checks them against the not-yet-reworked circuit's FLAT_TRANSITION
  // table (the circuit is intentionally out of sync until its own rework --
  // see CLAUDE.md / feature/ink-substrate).
  static const neutral =
      CARules(name: 'Neutral', surviveOn: {2}, bornOn: {2}, isNeutral: true);

  static const fire = CARules(name: 'Fire', surviveOn: {1}, bornOn: {1});

  static const earth = CARules(
    name: 'Earth',
    surviveOn: {1, 2, 3, 4, 5, 6},
    bornOn: {2},
  );

  static const water = CARules(
    name: 'Water',
    surviveOn: {3, 4, 5, 6},
    bornOn: {1, 2},
  );

  static const wind = CARules(name: 'Wind', surviveOn: {0, 1, 2}, bornOn: {2});
}
