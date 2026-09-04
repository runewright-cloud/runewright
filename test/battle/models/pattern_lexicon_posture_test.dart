// SPDX-License-Identifier: GPL-3.0-or-later
//
// pattern_lexicon_posture_test.dart — the Slice F architecture, asserted
// against the source tree (audit R-8).
//
// `incantation_meaning_test.dart` does this for the Incantation seam; this is
// its Summon/Armor counterpart, and the properties are the same three:
//
//   1. **One derivation site per domain.** A dictionary derived twice, from two
//      configs, in one match is a silent fork. Each domain's lexicon factory is
//      the only place its own dictionary is built.
//   2. **Three independent domains.** §9: *"Incantation, Summon, and Armor
//      dictionaries must be independently derived despite sharing the same
//      human-readable leyline seed."* Independence is not only a property of
//      the hash — it is a property of the code that must not be able to consult
//      the wrong one.
//   3. **The proof layer never sees a dictionary.** Derived semantics are
//      derived; nothing about them is proven, transmitted, persisted or
//      certified.
//
// The allowlists below ARE the architecture, written down. Adding a file to one
// is a real decision — it means a second place in the codebase knows what a
// leyline does to a creature or an armor — and it should be made deliberately,
// in review, not by editing a list to make a test pass.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = _libDir();

  test('the source scan is not vacuous', () {
    // A guard test that silently stops guarding is worse than no guard.
    final files = _dartFiles(lib).toList();
    expect(files.length, greaterThan(50),
        reason: 'the walk found ${files.length} dart files under ${lib.path} '
            '— it is not looking at lib/');
    expect(files.map(_rel), contains('battle/models/summon_lexicon.dart'));
    expect(files.map(_rel), contains('battle/models/armor_lexicon.dart'));
    // And the comment stripper still strips, so prose about an identifier is
    // not counted as a use of it.
    expect(_stripComments('// SummonLexicon\ncode();'),
        isNot(contains('SummonLexicon')));
  });

  group('one derivation site per domain', () {
    test('only the summon lexicon names the summon domain', () {
      const allowed = {
        // Defines the tag.
        'battle/models/leyline_stream.dart',
        // Re-exports it, and its header explains why Summon is not derived
        // there.
        'battle/models/leyline_codebook.dart',
        // Derives the dictionary. The only one.
        'battle/models/summon_lexicon.dart',
      };
      expect(_filesContaining(lib, 'kLeylineSummonDomain'), allowed);
    });

    test('only the armor lexicon names the armor domain', () {
      const allowed = {
        'battle/models/leyline_stream.dart',
        'battle/models/leyline_codebook.dart',
        'battle/models/armor_lexicon.dart',
      };
      expect(_filesContaining(lib, 'kLeylineArmorDomain'), allowed);
    });

    test('only the two lexicons construct a pattern codebook', () {
      const allowed = {
        'battle/models/summon_lexicon.dart',
        'battle/models/armor_lexicon.dart',
      };
      expect(
        _filesContaining(lib, 'LeylinePatternCodebook.derive(',
            excludeBasename: 'leyline_pattern_codebook.dart'),
        allowed,
      );
    });

    test('nothing outside the two lexicons imports the pattern codebook', () {
      const allowed = {
        'battle/models/summon_lexicon.dart',
        'battle/models/armor_lexicon.dart',
      };
      expect(
        _filesContaining(lib, 'leyline_pattern_codebook.dart',
            excludeBasename: 'leyline_pattern_codebook.dart'),
        allowed,
      );
    });
  });

  group('three independent domains', () {
    test('the summon lexicon knows nothing about armor', () {
      final src = _codeOf(File('${lib.path}/battle/models/summon_lexicon.dart'));
      for (final forbidden in const [
        'ArmorLexicon',
        'armor_lexicon',
        'ArmorKeyword',
        'kLeylineArmorDomain',
        'IncantationLexicon',
        'IncantationCodebook',
        'leyline_codebook',
      ]) {
        expect(src.contains(forbidden), isFalse,
            reason: 'summon_lexicon.dart must not know about $forbidden');
      }
    });

    test('the armor lexicon knows nothing about summons', () {
      final src = _codeOf(File('${lib.path}/battle/models/armor_lexicon.dart'));
      for (final forbidden in const [
        'SummonLexicon',
        'summon_lexicon',
        'SummonAbility',
        'kLeylineSummonDomain',
        'IncantationLexicon',
        'IncantationCodebook',
        'leyline_codebook',
      ]) {
        expect(src.contains(forbidden), isFalse,
            reason: 'armor_lexicon.dart must not know about $forbidden');
      }
    });

    test('the incantation codebook knows nothing about the pattern one', () {
      final src = _codeOf(File('${lib.path}/battle/models/leyline_codebook.dart'));
      for (final forbidden in const [
        'LeylinePatternCodebook',
        'leyline_pattern_codebook',
        'SummonLexicon',
        'ArmorLexicon',
      ]) {
        expect(src.contains(forbidden), isFalse,
            reason: 'leyline_codebook.dart must not know about $forbidden — '
                'the two constructions share a hash, not a dictionary');
      }
    });

    test('the vocabularies do not know what a leyline is', () {
      // `CreatureSpec` is CA-derived identity and `armor_keyword.dart` /
      // `summon_ability.dart` are vocabularies. All three must stay answerable
      // with no leyline in the room — which is what makes the ordinary reading
      // available to the library and the inscription editor without a config.
      for (final rel in const [
        'battle/models/creature_spec.dart',
        'battle/models/summon_ability.dart',
        'battle/models/armor_keyword.dart',
      ]) {
        final file = File('${lib.path}/$rel');
        expect(file.existsSync(), isTrue,
            reason: '$rel moved — this guard is now scanning nothing');
        final src = _codeOf(file);
        for (final forbidden in const [
          'LeylineConfig',
          'SummonLexicon',
          'ArmorLexicon',
          'mutableMagic',
        ]) {
          expect(src.contains(forbidden), isFalse,
              reason: '$rel must not know about $forbidden');
        }
      }
    });
  });

  group('the interpretation boundaries', () {
    test('every SummonLexicon holder is one of the known seams', () {
      const allowed = {
        // The seam itself.
        'battle/models/summon_lexicon.dart',
        // The match's holder.
        'battle/engine/deterministic_resolution.dart',
        // Takes one so a reformed morphic creature reads under the match's
        // tradition.
        'battle/models/minion.dart',
        // Surfaces that PASS one down.
        'ui/spell_card_painter.dart',
        'ui/battle_screen.dart',
      };
      expect(_filesContaining(lib, 'SummonLexicon'), allowed,
          reason: 'a new SummonLexicon holder is a new interpretation site — '
              'prefer consuming a CreatureSpec that was already derived');
    });

    test('every ArmorLexicon holder is one of the known seams', () {
      const allowed = {
        // The seam itself.
        'battle/models/armor_lexicon.dart',
        // Takes one; re-exports it so its callers need no second import.
        'battle/models/certified_armor.dart',
        // The certification boundary — where it is REQUIRED, not defaulted.
        'battle/engine/armor_certification.dart',
        // Passes the agreed leyline in.
        'battle/networking/duel_setup.dart',
        // The local read-back of a persisted armor.
        'spells/armor_summary.dart',
        // The one widget that shows keywords.
        'ui/widgets/armor_summary_view.dart',
      };
      expect(_filesContaining(lib, 'ArmorLexicon'), allowed,
          reason: 'a new ArmorLexicon holder is a new interpretation site — '
              'prefer consuming a CertifiedArmor that was already derived');
    });

    test('the certification boundary cannot default its lexicon', () {
      // M4.22's lesson, applied: a trust boundary must not be able to fall back
      // to a tradition by omission. `certifyOwnArmor`/`certifyPeerArmor` take a
      // REQUIRED lexicon so `runDuelSetup` has to name one.
      final src = _codeOf(
          File('${lib.path}/battle/engine/armor_certification.dart'));
      expect(src.contains('required ArmorLexicon lexicon'), isTrue);
      expect(src.contains('ArmorLexicon lexicon = ArmorLexicon.ordinary'),
          isFalse,
          reason: 'armor certification must never default to the ordinary '
              'tradition — that is how one device reads Flying off an armor '
              'the other reads nothing off');
      // …and duel setup passes the AGREED config, not a local opinion.
      expect(
        _codeOf(File('${lib.path}/battle/networking/duel_setup.dart'))
            .contains('ArmorLexicon.of(effectiveConfig.leyline)'),
        isTrue,
      );
    });

    test('in-match summon derivation goes through the lexicon', () {
      // `CreatureSpec.fromElements` is the ORDINARY/reference derivation.
      // Calling it in a match would read ordinary abilities under a mutable
      // tradition — the failure this seam exists to prevent. The three
      // remaining engine calls read `.affinity` only, which is CA-derived and
      // leyline-independent, and they must stay that way: a certified price
      // must not move because a dictionary did.
      final engine = _codeOf(
          File('${lib.path}/battle/engine/deterministic_resolution.dart'));
      expect(engine.contains('summonLexicon.specOf('), isTrue,
          reason: 'the summon cast must derive through the lexicon');
      for (final match
          in RegExp(r'CreatureSpec\.fromElements\([^;]*').allMatches(engine)) {
        expect(match.group(0), contains('affinity'),
            reason: 'an engine CreatureSpec.fromElements call that reads more '
                'than .affinity must go through summonLexicon.specOf');
      }
    });
  });

  group('the proof layer never sees a dictionary', () {
    test('no proof, circuit or persistence file depends on one', () {
      const proofLayer = [
        'spells/inscribe.dart',
        'spells/spell_asset.dart',
        'spells/spell_asset_integrity.dart',
        'battle/engine/proof_intake.dart',
        'battle/engine/proof_outputs.dart',
        'battle/models/armor_envelope.dart',
        'battle/engine/trajectory_parser.dart',
      ];
      for (final rel in proofLayer) {
        final file = File('${lib.path}/$rel');
        expect(file.existsSync(), isTrue,
            reason: '$rel moved — this guard is now scanning nothing');
        final src = _codeOf(file);
        for (final forbidden in const [
          'SummonLexicon',
          'ArmorLexicon',
          'LeylinePatternCodebook',
          'leylineTraditionHash',
        ]) {
          expect(src.contains(forbidden), isFalse,
              reason: '$rel must not depend on $forbidden — derived semantics '
                  'are derived, never proven, transmitted or persisted');
        }
      }
    });

    test('nothing transmits a derived ability or keyword', () {
      // The wire carries a proof and a routing tier. If a codec ever learns
      // these words, a peer has started asserting its own semantics.
      for (final rel in const [
        'battle/engine/battle_wire_codec.dart',
        'battle/networking/battle_session.dart',
        'battle/models/armor_envelope.dart',
      ]) {
        final src = _codeOf(File('${lib.path}/$rel'));
        for (final forbidden in const [
          'ArmorKeyword',
          'SummonLexicon',
          'ArmorLexicon',
        ]) {
          expect(src.contains(forbidden), isFalse,
              reason: '$rel must not carry $forbidden across the wire');
        }
      }
    });

    test('the tradition hash is read only by the scoring primitive', () {
      expect(
        _filesContaining(lib, 'leylineTraditionHash'),
        {
          // Defines it.
          'battle/models/leyline_config.dart',
          // The one consumer: the domain-separated score.
          'battle/models/leyline_stream.dart',
        },
      );
    });
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Every file under [lib] whose comment-stripped source contains [needle].
Set<String> _filesContaining(
  Directory lib,
  String needle, {
  String? excludeBasename,
}) =>
    {
      for (final file in _dartFiles(lib))
        if ((excludeBasename == null ||
                !file.path.endsWith('/$excludeBasename')) &&
            _codeOf(file).contains(needle))
          _rel(file),
    };

String _codeOf(File file) => _stripComments(file.readAsStringSync());

/// [source] with `//` comments stripped.
///
/// The scans look for identifiers, and prose about an identifier is not a use of
/// it — this file's own allowlist rationale names half of them. Crude on
/// purpose: a `//` inside a string literal is truncated too, which costs nothing
/// here and keeps the helper something you can verify by reading it.
String _stripComments(String source) => source
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

Directory _libDir() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = Directory('${dir.path}/lib');
    if (candidate.existsSync() &&
        File('${candidate.path}/main.dart').existsSync()) {
      return candidate;
    }
    dir = dir.parent;
  }
  throw StateError('could not locate the package lib/ directory');
}

Iterable<File> _dartFiles(Directory dir) => dir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _rel(File file) => file.path.split('/lib/').last;
