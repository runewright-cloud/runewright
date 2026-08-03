// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:test/test.dart';
import 'package:rune_duel/engine/element.dart';
import 'package:rune_duel/engine/hex_grid.dart';

void main() {
  group('HexGrid.packGridState', () {
    test('an all-dead radius-12 grid packs to 469 zeros', () {
      final grid = HexGrid(12);
      final packed = grid.packGridState();
      expect(packed.length, equals(469));
      expect(packed, equals(List.filled(469, 0)));
    });

    test('center cell (0,0) packs to index 234, per GRID_ORDERING_v2.md', () {
      final grid = HexGrid(12);
      grid.setState(Element.alive, const HexCoord(0, 0));
      final packed = grid.packGridState();
      expect(packed[234], equals(1));
      expect(packed.where((c) => c == 1).length, equals(1));
    });

    test('first cell (-12, 0) packs to index 0', () {
      final grid = HexGrid(12);
      grid.setState(Element.alive, const HexCoord(-12, 0));
      final packed = grid.packGridState();
      expect(packed[0], equals(1));
    });

    test('last cell (12, 0) packs to index 468', () {
      final grid = HexGrid(12);
      grid.setState(Element.alive, const HexCoord(12, 0));
      final packed = grid.packGridState();
      expect(packed[468], equals(1));
    });

    test('iteration order survives copy() and in-place mutation', () {
      final grid = HexGrid(12);
      grid.setState(Element.alive, const HexCoord(0, 0));
      final copy = grid.copy();
      copy.setState(Element.alive, const HexCoord(-12, 0));
      final packed = copy.packGridState();
      expect(packed[234], equals(1));
      expect(packed[0], equals(1));
      expect(packed.where((c) => c == 1).length, equals(2));
    });
  });
}
