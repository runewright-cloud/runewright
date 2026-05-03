import 'package:flutter/material.dart' hide Element;
import '../engine/element.dart';

extension ElementVisuals on Element {
  Color get color => switch (this) {
    Element.empty      => const Color(0xFF1E1E3A),
    Element.fire       => const Color(0xFFCC2211),
    Element.water      => const Color(0xFF1A6FCC),
    Element.earth      => const Color(0xFF7A5C28),
    Element.air        => const Color(0xFF88BBDD),
    Element.fireWater  => const Color(0xFF882299),
    Element.fireEarth  => const Color(0xFF993322),
    Element.fireAir    => const Color(0xFFCCAA00),
    Element.waterEarth => const Color(0xFF2D7A50),
    Element.waterAir   => const Color(0xFF0099BB),
    Element.earthAir   => const Color(0xFF669944),
    Element.chaos      => const Color(0xFFBB0055),
    Element.voidEl     => const Color(0xFF220044),
  };

  String get displayName => switch (this) {
    Element.empty      => 'Empty',
    Element.fire       => 'Fire',
    Element.water      => 'Water',
    Element.earth      => 'Earth',
    Element.air        => 'Air',
    Element.fireWater  => 'Fire·Water',
    Element.fireEarth  => 'Fire·Earth',
    Element.fireAir    => 'Fire·Air',
    Element.waterEarth => 'Water·Earth',
    Element.waterAir   => 'Water·Air',
    Element.earthAir   => 'Earth·Air',
    Element.chaos      => 'Chaos',
    Element.voidEl     => 'Void',
  };
}
