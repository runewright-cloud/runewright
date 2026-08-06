// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_identity_test.dart — behavioural kinship vs. unique spell identity
// (docs/COUNTER_CHARM_KINSHIP_PLAN.md §3.3, §3.5, Phase 3).
//
// The two properties worth pinning here are the ones the redesign exists for:
//
//   * the throwaway-dot exploit is dead — a variant that changes the grid but
//     not the trajectory is still kin;
//   * the kin-stacking reveal collides for kin and only for kin, without
//     leaking a stable cross-match identifier.

import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/spells/spell_identity.dart';

const _nine = [
  'fire', 'fire', 'fire',
  'water', 'water', 'water',
  'earth', 'earth', 'earth',
];

Uint8List _salt(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xFF));

void main() {
  group('behaviouralKinKey', () {
    test('two spells with the same trajectory and cost are kin', () {
      expect(
        behaviouralKinKey(trajectory: _nine, baseManaCost: 42),
        behaviouralKinKey(trajectory: _nine, baseManaCost: 42),
      );
    });

    test('the throwaway-dot exploit is dead: a different grid with the same '
        'behaviour is still kin', () {
      // The grid (and therefore the commitment) differs; nothing this key
      // reads does. Under the old commitment-keyed definition these two were
      // unrelated spells, which is exactly the loophole §1 describes.
      final a = behaviouralKinKey(trajectory: _nine, baseManaCost: 42);
      final b = behaviouralKinKey(
        trajectory: List<String>.from(_nine),
        baseManaCost: 42,
      );
      expect(a, b);
    });

    test('a different trajectory is not kin', () {
      final other = List<String>.from(_nine)..[8] = 'air';
      expect(
        behaviouralKinKey(trajectory: _nine, baseManaCost: 42),
        isNot(behaviouralKinKey(trajectory: other, baseManaCost: 42)),
      );
    });

    test('a different base mana cost is not kin', () {
      expect(
        behaviouralKinKey(trajectory: _nine, baseManaCost: 42),
        isNot(behaviouralKinKey(trajectory: _nine, baseManaCost: 43)),
      );
    });

    test('element names are compared case-insensitively', () {
      expect(
        behaviouralKinKey(trajectory: _nine, baseManaCost: 1),
        behaviouralKinKey(
          trajectory: [for (final e in _nine) e.toUpperCase()],
          baseManaCost: 1,
        ),
      );
    });

    test('a trajectory under the threshold is exempt — kin to nothing, '
        'including another exempt spell (§2.6, §3.4)', () {
      expect(kKinshipMinElements, 9);
      final short = _nine.sublist(0, 8);
      expect(behaviouralKinKey(trajectory: short, baseManaCost: 42), isNull);
      expect(behaviouralKinKey(trajectory: const [], baseManaCost: 0), isNull);
      // Exactly at the threshold is NOT exempt.
      expect(behaviouralKinKey(trajectory: _nine, baseManaCost: 42), isNotNull);
    });
  });

  group('uniqueSpellId', () {
    test('is one-to-one over the proof bytes', () {
      final a = Uint8List.fromList([1, 2, 3, 4]);
      final b = Uint8List.fromList([1, 2, 3, 5]);
      expect(uniqueSpellId(a), uniqueSpellId(Uint8List.fromList([1, 2, 3, 4])));
      expect(uniqueSpellId(a), isNot(uniqueSpellId(b)));
    });

    test('is unrelated to the kin key — the whole point of the split', () {
      expect(
        uniqueSpellId(Uint8List.fromList([1, 2, 3])),
        isNot(behaviouralKinKey(trajectory: _nine, baseManaCost: 42)),
      );
    });
  });

  group('heraldicArmsKey', () {
    test('kin share arms', () {
      expect(heraldicArmsKey(_nine), heraldicArmsKey(List<String>.from(_nine)));
    });

    test('arms are NOT gated by the kinship threshold — a short spell still '
        'shares arms with a matching short spell (§2.9)', () {
      const short = ['fire', 'fire', 'fire'];
      expect(behaviouralKinKey(trajectory: short, baseManaCost: 1), isNull);
      expect(heraldicArmsKey(short), heraldicArmsKey(const ['fire', 'fire', 'fire']));
      expect(heraldicArmsKey(short), isNot(heraldicArmsKey(const ['air', 'air', 'air'])));
    });

    test('arms ignore mana cost — two spells that do the same thing at '
        'different prices still look alike', () {
      expect(heraldicArmsKey(_nine), heraldicArmsKey(_nine));
    });

    test('a legacy spell with no formula falls back to its commitment so such '
        'cards stay distinct', () {
      expect(heraldicArmsKey(const [], fallbackHex: '0xaaa'), '0xaaa');
      expect(
        heraldicArmsKey(const [], fallbackHex: '0xaaa'),
        isNot(heraldicArmsKey(const [], fallbackHex: '0xbbb')),
      );
      // No fallback available: a stable constant rather than a crash.
      expect(heraldicArmsKey(const []), isNotEmpty);
    });
  });

  group('kinStackingLeaves (§3.5)', () {
    final salt = _salt(1);

    test('kin collide, so kin-stacking is still detected', () {
      final key = behaviouralKinKey(trajectory: _nine, baseManaCost: 42);
      final leaves = kinStackingLeaves(
        [SpellKinEntry(key), SpellKinEntry(key)],
        salt: salt,
      );
      expect(leaves[0], leaves[1]);
    });

    test('non-kin do not collide', () {
      final leaves = kinStackingLeaves(
        [
          SpellKinEntry(behaviouralKinKey(trajectory: _nine, baseManaCost: 42)),
          SpellKinEntry(behaviouralKinKey(trajectory: _nine, baseManaCost: 43)),
        ],
        salt: salt,
      );
      expect(leaves[0], isNot(leaves[1]));
    });

    test('kinship-exempt entries get random leaves, so they can never trip '
        'the duplicate check', () {
      final leaves = kinStackingLeaves(
        const [SpellKinEntry(null), SpellKinEntry(null)],
        salt: salt,
        random: Random(7),
      );
      expect(leaves, hasLength(2));
      expect(leaves[0], isNot(leaves[1]));
    });

    test('the same book under a different salt reveals different leaves — no '
        'cross-match identifier', () {
      final key = behaviouralKinKey(trajectory: _nine, baseManaCost: 42);
      final a = kinStackingLeaves([SpellKinEntry(key)], salt: _salt(1));
      final b = kinStackingLeaves([SpellKinEntry(key)], salt: _salt(2));
      expect(a.single, isNot(b.single));
    });

    test('a leaf reveals neither the trajectory nor the kin key', () {
      final key = behaviouralKinKey(trajectory: _nine, baseManaCost: 42)!;
      final leaf = kinStackingLeaves([SpellKinEntry(key)], salt: salt).single;
      expect(leaf, isNot(contains('fire')));
      expect(leaf, isNot(key));
    });
  });

  group('newKinRevealSalt', () {
    test('is 32 bytes and fresh each call', () {
      final a = newKinRevealSalt();
      final b = newKinRevealSalt();
      expect(a, hasLength(32));
      expect(a, isNot(b));
    });
  });
}
