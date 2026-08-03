// SPDX-License-Identifier: GPL-3.0-or-later
//
// srs_cache.dart — device-local path for the persistent SRS (structured
// reference string) cache file used by prover.dart's initSrsCached.
//
// This is the real player-facing path, distinct from the bundled-VK assets
// (assets/circuits/*.vk) and from the diagnostic gate harness's hardcoded
// dev-machine SRS path (gate_screen.dart's _kSrsCachePath -- deliberately
// not reused here, since a hardcoded path to one developer's home directory
// would silently no-op on every other player's device): first inscription
// on a fresh device downloads the SRS over the network and writes it here;
// every inscription after that on the same device reads from this file
// instead, so the second and subsequent inscriptions work offline.

import 'package:path_provider/path_provider.dart';

const String kSrsCacheFileName = 'runewright_srs.local';

/// The on-disk path for the cached SRS file --
/// `<application support directory>/runewright_srs.local`.
/// `getApplicationSupportDirectory` (not `getApplicationDocumentsDirectory`,
/// which `SpellAsset` uses) because this is internal cache data the player
/// never browses or backs up themselves, not a player-owned document.
Future<String> srsCachePath() async {
  final dir = await getApplicationSupportDirectory();
  return '${dir.path}/$kSrsCacheFileName';
}
