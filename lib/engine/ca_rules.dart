class CARules {
  final String name;
  final Set<int> surviveOn;
  final Set<int> bornOn;

  const CARules({
    required this.name,
    required this.surviveOn,
    required this.bornOn,
  });

  static const neutral = CARules(name: 'Neutral', surviveOn: {2}, bornOn: {2});

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
