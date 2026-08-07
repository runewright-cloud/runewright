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

import 'dart:io';

import 'package:path_provider/path_provider.dart';

const String kSrsCacheFileName = 'runewright_srs.local';

/// Roughly how large the one-time SRS download is, for telling a player what
/// they are about to spend. Measured from a real cache file (129 MB); stated
/// as an approximation because it tracks the tier-48 point floor, not a
/// fixed constant.
const String kSrsDownloadSizeApprox = '130 MB';

/// The on-disk path for the cached SRS file --
/// `<application support directory>/runewright_srs.local`.
/// `getApplicationSupportDirectory` (not `getApplicationDocumentsDirectory`,
/// which `SpellAsset` uses) because this is internal cache data the player
/// never browses or backs up themselves, not a player-owned document.
Future<String> srsCachePath() async {
  final dir = await getApplicationSupportDirectory();
  return '${dir.path}/$kSrsCacheFileName';
}

/// Whether this device can prove or verify offline — i.e. whether the SRS is
/// already on disk.
///
/// A plain existence check is sufficient, and that rests on a property of the
/// Rust side worth stating: `get_srs_cached` sizes **every** download to at
/// least `TIER48_SRS_FLOOR`, whichever tier triggered it, and publishes the
/// file atomically (temp file + rename). So a file that exists is always
/// large enough for all three tiers and is never half-written. If that policy
/// ever changes, this check stops being sound.
///
/// Used to warn a player *before* they are standing in front of an opponent
/// with no internet: the first duel or inscription on a fresh device
/// downloads ~[kSrsDownloadSizeApprox], and there is no offline path to it.
Future<bool> srsCacheReady() async {
  try {
    return File(await srsCachePath()).existsSync();
  } catch (_) {
    // No application-support directory yet (or no path_provider, in a test
    // harness that hasn't faked it). Report not-ready rather than throwing:
    // the caller's only use for this is deciding whether to show a warning.
    return false;
  }
}
