// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_canonical_bytes_test.dart — a worn Aetherial Armor participates in
// BattleState.toCanonicalBytes() (engine v6), in a layout slice 6 did NOT
// change (engine v7: Charger and Muddy became live behaviour, not new bytes).
//
// Armor moves deterministic gameplay as of slice 5, so two devices holding
// different readings of the same worn armor must not be able to agree on a
// state hash. The interesting half is what is encoded BEYOND the four live
// numbers: two armors can grant identical active bonuses off different counts,
// keyword sets and trajectories, and a pair that hashed equal today would
// silently desync the day the first keyword goes live.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/certified_armor.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import 'certified_armor_fixture.dart';

/// A one-wizard state whose ONLY variable is the armor worn, so any byte
/// difference is attributable to the armor encoding and nothing else.
BattleState _stateWearing(CertifiedArmor? armor, {int hp = 24}) {
  final bf = Battlefield(radius: 6);
  bf.occupancy['w'] = const HexCoord(0, 0);
  return BattleState(
    config: const MatchConfig(playerHp: 24, gridRadius: 6, maxPlayers: 2),
    avatars: [
      WizardAvatar(
        playerId: 'w',
        ownerPubkeyHex: '0x${'0' * 64}',
        hp: hp,
        mana: 100,
        maxMana: 100,
        position: const HexCoord(0, 0),
        teamId: 't',
        baseSpellRange: 3,
        armor: armor,
      ),
    ],
    teams: [const Team(id: 't', playerIds: ['w'])],
    battlefield: bf,
  );
}

Uint8List _bytesWearing(CertifiedArmor? armor, {int hp = 24}) =>
    _stateWearing(armor, hp: hp).toCanonicalBytes();

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Matcher _sameBytesAs(Uint8List expected) => predicate<Uint8List>(
      (actual) => _eq(actual, expected),
      'byte-identical canonical state',
    );

Matcher _differentBytesFrom(Uint8List other) => predicate<Uint8List>(
      (actual) => !_eq(actual, other),
      'canonical state differing from the other encoding',
    );

void main() {
  group('presence', () {
    test('wearing an armor changes the canonical bytes', () {
      expect(_bytesWearing(armorOf(kEarthArmorCodes)),
          _differentBytesFrom(_bytesWearing(null)));
    });

    test('an armor whose certified sequence is EMPTY is still not "no armor"',
        () {
      // Four neutral generations: T is real, slot cost is real, every count and
      // bonus is zero and the sequence is empty. Without a presence byte of its
      // own this would encode identically to an unarmored wizard.
      final blank = armorOf('nnnn');
      expect(blank.elementSequence, isEmpty);
      expect(blank.keywords, isEmpty);
      expect(_bytesWearing(blank), _differentBytesFrom(_bytesWearing(null)));
    });

    test('the same armor on both devices encodes identically', () {
      // The lockstep case: this is what must hold for an honest match, and a
      // fixture that failed it would make every difference below meaningless.
      expect(_bytesWearing(armorOf(runOfCode('E', 12))),
          _sameBytesAs(_bytesWearing(armorOf(runOfCode('E', 12)))));
    });
  });

  group('armors that differ only beneath the live numbers', () {
    test('equal bonuses, different element counts', () {
      // 4 fires and 9 fires are both melee +1 (the next rung is 10), and equal
      // in every other live number. They are not the same armor.
      final four = armorOf(runOfCode('F', 4));
      final nine = armorOf(runOfCode('F', 9));
      expect(four.meleeBonus, nine.meleeBonus);
      expect(four.keywords, nine.keywords);
      expect(_bytesWearing(four), _differentBytesFrom(_bytesWearing(nine)));
    });

    test('equal bonuses and counts, different element ORDER', () {
      // FFFFAAAA and AAAAFFFF: identical counts (4/4), identical bonuses
      // (melee +1, move +1), identical keywords ({cleave, flying}). Only the
      // trajectory differs — so only the sequence encoding can catch it.
      final fa = armorOf('FFFFAAAA');
      final af = armorOf('AAAAFFFF');
      expect(fa.fireCount, af.fireCount);
      expect(fa.airCount, af.airCount);
      expect(fa.meleeBonus, af.meleeBonus);
      expect(fa.moveSpeedBonus, af.moveSpeedBonus);
      expect(fa.keywords, af.keywords);
      expect(fa.elementSequence, isNot(af.elementSequence));
      expect(_bytesWearing(fa), _differentBytesFrom(_bytesWearing(af)));
    });

    test('equal bonuses and counts, different keyword sets', () {
      // FAFA (Charger) vs FFAA: two fires and two airs either way, no rung
      // reached by either, so every bonus is 0 on both. The keyword is the
      // whole difference.
      final charger = armorOf('FAFA');
      final plain = armorOf('FFAA');
      expect(charger.keywords, {ArmorKeyword.charger});
      expect(plain.keywords, isEmpty);
      expect(charger.meleeBonus, plain.meleeBonus);
      expect(charger.moveSpeedBonus, plain.moveSpeedBonus);
      expect(
          _bytesWearing(charger), _differentBytesFrom(_bytesWearing(plain)));
    });

    test('equal everything derived, different certified T', () {
      // Same seven fires, but one proof ran 8 generations and the other 12 —
      // different slot cost (2 vs 3) off an identical element sequence. T is
      // encoded alongside slotCost because the cost is a lossy function of it.
      final shortT = armorOf(runOfCode('F', 7), t: 8);
      final longT = armorOf(runOfCode('F', 7), t: 12);
      expect(shortT.elementSequence, longT.elementSequence);
      expect(shortT.meleeBonus, longT.meleeBonus);
      expect(
          _bytesWearing(shortT), _differentBytesFrom(_bytesWearing(longT)));
    });

    test('the same armor worn but different HP is a different state anyway', () {
      // Guard against a fixture that accidentally compares only the HP field:
      // HP moves the bytes on its own, which is why every comparison above
      // holds HP fixed.
      final armor = armorOf(kEarthArmorCodes);
      expect(_bytesWearing(armor, hp: 24),
          _differentBytesFrom(_bytesWearing(armor, hp: 26)));
    });
  });

  group('keyword encoding is a deterministic bitmask', () {
    test('keyword set iteration order does not move a byte', () {
      // The one place a CertifiedArmor is built by hand: two armors identical
      // except for the INSERTION ORDER of an unordered Set. Dart Sets iterate
      // in insertion order, so serialising that order rather than a bitmask
      // would make the canonical bytes depend on which keyword pattern the
      // derivation happened to match first.
      CertifiedArmor withKeywords(Set<ArmorKeyword> keywords) => CertifiedArmor(
            t: 8,
            slotCost: 2,
            fireCount: 4,
            airCount: 4,
            waterCount: 0,
            earthCount: 0,
            meleeBonus: 1,
            moveSpeedBonus: 1,
            spellRangeBonus: 0,
            armorHpBonus: 0,
            keywords: keywords,
            elementSequence: const [
              BorderZone.fire, BorderZone.fire, BorderZone.fire, BorderZone.fire,
              BorderZone.air, BorderZone.air, BorderZone.air, BorderZone.air,
            ],
          );
      final ab = withKeywords({ArmorKeyword.cleave, ArmorKeyword.flying});
      final ba = withKeywords({ArmorKeyword.flying, ArmorKeyword.cleave});
      expect(ab.keywords.toList(), isNot(ba.keywords.toList()),
          reason: 'fixture check: the two sets really do iterate differently');
      expect(_bytesWearing(ab), _sameBytesAs(_bytesWearing(ba)));
    });

    test('each keyword occupies its own bit', () {
      // Every single-keyword armor must encode differently from every other,
      // which is what a per-keyword bit buys over, say, a count.
      const codes = {
        ArmorKeyword.flying: 'AAAA',
        ArmorKeyword.cleave: 'FFFF',
        ArmorKeyword.charger: 'FAFA',
        ArmorKeyword.muddy: 'WEWE',
        ArmorKeyword.moltenCarapace: 'EFEF',
        ArmorKeyword.stealthy: 'AWAW',
        ArmorKeyword.anchored: 'EEEE',
      };
      expect(codes.keys.toSet(), ArmorKeyword.values.toSet());
      final seen = <ArmorKeyword, Uint8List>{};
      for (final entry in codes.entries) {
        final bytes = _bytesWearing(armorOf(entry.value));
        for (final prior in seen.entries) {
          expect(bytes, _differentBytesFrom(prior.value),
              reason: '${entry.key.name} and ${prior.key.name} must not '
                  'encode alike');
        }
        seen[entry.key] = bytes;
      }
    });
  });

  group('the encoding shape is fixed', () {
    /// The armor record, re-encoded by hand from the certified object. Any
    /// field production adds, drops or reorders makes this disagree — which is
    /// the point: activating a keyword must change engine semantics, never
    /// serialization. Mirrors `BattleState.toCanonicalBytes`'s armor block.
    List<int> expectedRecord(CertifiedArmor a) {
      var mask = 0;
      for (final k in a.keywords) {
        mask |= 1 << k.index;
      }
      return [
        1, // present
        a.t,
        a.slotCost,
        a.fireCount, a.airCount, a.waterCount, a.earthCount,
        a.meleeBonus, a.moveSpeedBonus, a.spellRangeBonus, a.armorHpBonus,
        (mask >> 8) & 0xFF, mask & 0xFF, // uint16, big-endian
        a.elementSequence.length,
        for (final z in a.elementSequence) z.index,
      ];
    }

    /// Index of the presence byte: the first place a worn state and a bare one
    /// can differ, since everything before it is armor-independent.
    int recordStart(Uint8List worn, Uint8List bare) {
      for (var i = 0; i < bare.length; i++) {
        if (worn[i] != bare[i]) return i;
      }
      fail('a worn state must differ from a bare one somewhere');
    }

    test('a worn armor writes exactly the documented record and nothing else',
        () {
      // Charger + Muddy: the two keywords slice 6 made live. They must ride in
      // the same bitmask they rode in when they were inert.
      final armor = armorOf('FAFAWEWE', t: 9);
      expect(armor.keywords, {ArmorKeyword.charger, ArmorKeyword.muddy});

      final worn = _bytesWearing(armor);
      final bare = _bytesWearing(null);
      final at = recordStart(worn, bare);
      final expected = expectedRecord(armor);

      expect(worn.sublist(at, at + expected.length), expected,
          reason: 'the armor record is 14 + sequenceLength bytes, in this '
              'order — no field was added for Charger or Muddy');
      expect(worn.sublist(at + expected.length), bare.sublist(at + 1),
          reason: 'and everything after the record is byte-identical to the '
              'unarmored stream, so the record did not grow into it');
    });

    test('a live-keyword armor is the same size as an inert-keyword one', () {
      // Same T, same sequence length, different keywords: behaviour differs
      // (v7), byte count does not.
      final live = armorOf('FAFAWEWE');
      final inert = armorOf('AAAAEFEF');
      expect(live.keywords, {ArmorKeyword.charger, ArmorKeyword.muddy});
      expect(inert.keywords,
          {ArmorKeyword.flying, ArmorKeyword.moltenCarapace});
      expect(_bytesWearing(live).length, _bytesWearing(inert).length);
      expect(_bytesWearing(live), _differentBytesFrom(_bytesWearing(inert)),
          reason: 'same size, different content — the bitmask, as before');
    });
  });
}
