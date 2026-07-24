// SPDX-License-Identifier: GPL-3.0-or-later
//
// recipe_book.dart — persisted record of which formula -> effect
// combinations (affinity + EffectKind) the player has completed in the CA
// at least once. Backs the Recipes reference screen (ui/recipes_screen.dart),
// which starts blank and reveals an entry the first time its formula
// completes during Rune Craft play (main.dart's GameScreen).

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../battle/models/creature_spec.dart' show SummonAbility;
import '../battle/models/effect_kind.dart';

/// Stable string key identifying a (affinity, effect kind) pair -- the
/// on-disk identity of a discovered recipe.
String recipeKey(SpellAffinity affinity, EffectKind kind) => '${affinity.name}:${kind.name}';

/// Stable string key identifying a discovered [SummonAbility] -- shares the
/// same on-disk discovered-set as [recipeKey] (a distinct 'summon:' prefix
/// keeps the two key spaces from colliding).
String summonAbilityKey(SummonAbility ability) => 'summon:${ability.name}';

class RecipeBook {
  // Every load()/markDiscovered() call is chained onto this future so file
  // access is strictly serialized. Without it, two formulas completing in
  // quick succession (each firing an unawaited markDiscovered from
  // main.dart) race on the same file: both read the same stale "existing"
  // set and each writes only its own key (a lost update), or one write's
  // bytes land mid-way through another's (a torn/corrupted file) --
  // reproduced by a widget test where a 12-step run completes two formulas
  // a few generations apart.
  static Future<void> _queue = Future.value();

  static Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _queue.then((_) => body());
    // Swallow the result/error for chaining purposes only -- callers still
    // see it via the returned Future; this just keeps the queue moving even
    // if a call throws.
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  static Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/recipe_book.json');
  }

  static Future<Set<String>> _loadUnlocked() async {
    final file = await _file();
    if (!await file.exists()) return {};
    final contents = await file.readAsString();
    final json = jsonDecode(contents) as Map<String, dynamic>;
    return (json['discovered'] as List<dynamic>? ?? []).cast<String>().toSet();
  }

  /// Loads the set of discovered recipe keys (see [recipeKey]). Empty if
  /// nothing has been discovered yet, including on first launch.
  static Future<Set<String>> load() => _serialized(_loadUnlocked);

  /// Merges [keys] into the persisted discovered set and saves if that
  /// changes anything. Returns the resulting full set.
  static Future<Set<String>> markDiscovered(Iterable<String> keys) => _serialized(() async {
        final existing = await _loadUnlocked();
        final merged = {...existing, ...keys};
        if (merged.length == existing.length) return existing;
        final file = await _file();
        // Write to a sibling temp file and rename over the target so a
        // reader (or a crash mid-write) never observes a partially-written
        // file -- rename is atomic on the same filesystem.
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(jsonEncode({'discovered': merged.toList()}));
        await tmp.rename(file.path);
        return merged;
      });
}
