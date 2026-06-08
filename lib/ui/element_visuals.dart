import 'package:flutter/material.dart' hide Element;
import '../engine/element.dart';

extension ElementVisuals on Element {
  Color get color => switch (this) {
    Element.dead  => const Color(0xFFFFFDF5), // inscribable — 5% lighter than base parchment
    Element.alive => const Color(0xFF1A1008), // ink
  };

  String get displayName => switch (this) {
    Element.dead  => 'Dead',
    Element.alive => 'Alive',
  };
}
