// SPDX-License-Identifier: GPL-3.0-or-later
//
// sync_art_session.dart — the Commune/Sync Art protocol: pairing handshake,
// then a symmetric want-list/art-bundle reconciliation over each side's
// Sightings library (lib/spells/sighting_asset.dart).
//
// Unlike Commune/Trade (trade_session.dart), Sync Art grants nothing and
// moves no ownership — it only fills in custom-art bytes for spells each
// side already knows the other owns (via a real battle-cast sighting), so
// there is no offer/confirm gate: pairing implies consent to reconcile.
//
// One `sync()` call does both directions in a single round trip: each side
// sends a want-list (the commitmentHexes it has sighted as belonging to the
// peer, with whatever artHash it currently holds, if any); the peer — being
// the true owner of those spells — fulfills what it can from its own
// natively-owned SpellAssets and sends back an art bundle; each side then
// verifies and saves what it receives. Frame routing mirrors
// TradeSession's broadcast-stream/framesOfType shape, not a strict
// request/response Completer -- see sync_art_wire.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../identity/identity.dart';
import '../protocol/transport.dart';
import '../spells/sighting_asset.dart';
import '../spells/spell_art_import.dart' show kSpellArtMaxImportBytes;
import '../spells/spell_art_pack.dart' show SpellArtPackEntry, kPainterlyPack;
import '../spells/spell_art_resolver.dart';
import '../spells/spell_art_store.dart';
import '../spells/spell_asset.dart';
import '../spells/spell_sound_import.dart' show kSpellSoundMaxImportBytes;
import '../spells/spell_sound_pack.dart' show SpellSoundPackEntry, kSpellSoundPack;
import '../spells/spell_sound_resolver.dart';
import '../spells/spell_sound_store.dart';
import 'sync_art_wire.dart';

/// F-2: total-bundle cap. Per-clip caps ([kSpellArtMaxImportBytes],
/// [kSpellSoundMaxImportBytes]) bound a single item; this bounds the whole
/// frame, which nothing did before (OUTSTANDING_ITEMS.md §7 added only a
/// per-item cap, and every art item was ≤288 KB so it never mattered --
/// adding sound to the same bundle is what makes a total cap matter now).
/// 4 MB comfortably covers dozens of spells' worth of art+sound in one
/// bundle while still bounding a pathological want-list.
const int kSyncBundleMaxTotalBytes = 4 * 1024 * 1024;

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

Future<String> _sha256Hex(Uint8List bytes) async {
  final hash = await Sha256().hash(bytes);
  return '0x${hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

// ── Result reporting ──────────────────────────────────────────────────────

class SyncArtResultItem {
  const SyncArtResultItem({
    required this.commitmentHex,
    required this.spellName,
    required this.success,
    this.error,
  });

  final String commitmentHex;
  final String spellName;
  final bool success;

  /// Set iff [success] is false.
  final String? error;
}

/// Summary of one [SyncArtSession.sync] call. [sent] reports art we
/// successfully sent to fulfill the peer's want-list; [received] reports
/// art we validated and saved (or rejected and why) from the peer's bundle.
class SyncArtResult {
  const SyncArtResult({required this.sent, required this.received});

  final List<SyncArtResultItem> sent;
  final List<SyncArtResultItem> received;
}

// ── Session ────────────────────────────────────────────────────────────────

class SyncArtSession {
  SyncArtSession._(this._transport, this.peerOwnerPubkeyHex, this.peerRawPubkeyBytes, this._reader, this._sub);

  final Transport _transport;
  final String peerOwnerPubkeyHex;
  final Uint8List peerRawPubkeyBytes;

  final SyncArtFrameReader _reader;
  final StreamSubscription<List<int>> _sub;

  Stream<SyncArtFrame> get frames => _reader.frames;
  Stream<SyncArtFrame> framesOfType(SyncArtMsgType type) => frames.where((f) => f.type == type);

  void _send(SyncArtMsgType type, List<int> payload) {
    _transport.send(SyncArtFrame(type, Uint8List.fromList(payload)).encode());
  }

  // ── Handshake ────────────────────────────────────────────────────────────

  /// Initiator side: sends our raw pubkey, waits for the peer's
  /// syncHelloAck (their raw pubkey), and resolves their owner_pubkey via
  /// [Identity.ownerPubkeyHexFromRawKey].
  static Future<SyncArtSession> initiate(Transport transport, Identity identity) async {
    final reader = SyncArtFrameReader();
    final sub = transport.onReceive.listen(reader.addChunk);

    final ackFuture = reader.frames.where((f) => f.type == SyncArtMsgType.syncHelloAck).first;
    transport.send(SyncArtFrame(SyncArtMsgType.syncHello, identity.publicKeyBytes).encode());
    final ack = await ackFuture;
    final peerRawPubkeyBytes = Uint8List.fromList(ack.payload);
    final peerOwnerPubkeyHex = await Identity.ownerPubkeyHexFromRawKey(peerRawPubkeyBytes);

    return SyncArtSession._(transport, peerOwnerPubkeyHex, peerRawPubkeyBytes, reader, sub);
  }

  /// Responder side: waits for the peer's syncHello, replies with our own
  /// raw pubkey.
  static Future<SyncArtSession> accept(Transport transport, Identity identity) async {
    final reader = SyncArtFrameReader();
    final sub = transport.onReceive.listen(reader.addChunk);

    final hello = await reader.frames.where((f) => f.type == SyncArtMsgType.syncHello).first;
    final peerRawPubkeyBytes = Uint8List.fromList(hello.payload);
    final peerOwnerPubkeyHex = await Identity.ownerPubkeyHexFromRawKey(peerRawPubkeyBytes);

    transport.send(SyncArtFrame(SyncArtMsgType.syncHelloAck, identity.publicKeyBytes).encode());

    return SyncArtSession._(transport, peerOwnerPubkeyHex, peerRawPubkeyBytes, reader, sub);
  }

  Future<void> close() async {
    await _sub.cancel();
    await _reader.close();
  }

  // ── Reconciliation ─────────────────────────────────────────────────────

  /// Runs one full want-list/art-bundle round trip and returns what was
  /// sent and received. Call once per paired session.
  Future<SyncArtResult> sync({required Identity ourIdentity}) async {
    final ourOwnerPubkeyHex = await ourIdentity.ownerPubkeyHex();

    // Round 1: want-lists. Subscribe BEFORE any async prep (disk reads
    // below) -- same discipline trade_session.dart documents: the
    // underlying broadcast stream does not buffer for late subscribers, so
    // a peer whose own prep finishes first could otherwise have its frame
    // silently dropped.
    final theirWantlistFuture = framesOfType(SyncArtMsgType.wantlist).first;
    final ourSightings = (await SightingAsset.loadAll())
        .where((s) => _hexEq(s.opponentPubkeyHex, peerOwnerPubkeyHex))
        .toList();
    _send(
      SyncArtMsgType.wantlist,
      utf8.encode(jsonEncode({
        'items': ourSightings
            .map((s) => {
                  'commitmentHex': s.commitmentHex,
                  't': s.t,
                  if (s.artHash != null) 'currentArtHash': s.artHash,
                  if (s.soundHash != null) 'currentSoundHash': s.soundHash,
                })
            .toList(),
      })),
    );
    final theirWantlistFrame = await theirWantlistFuture;
    final theirItems = _decodeItems(theirWantlistFrame.payload);

    // Round 2: art bundles. Subscribe before the (disk-bound) fulfillment
    // work below, same reasoning as round 1.
    final theirBundleFuture = framesOfType(SyncArtMsgType.artBundle).first;
    final sent = await _fulfillWantlist(theirItems, ourOwnerPubkeyHex);
    final theirBundleFrame = await theirBundleFuture;
    _send(SyncArtMsgType.syncDone, const []);

    final received = await _receiveAndSaveBundle(theirBundleFrame, ourSightings);

    return SyncArtResult(sent: sent, received: received);
  }

  static List<Map<String, dynamic>> _decodeItems(Uint8List payload) {
    final json = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
    return (json['items'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  }

  /// For each entry in the peer's want-list, looks for a natively-owned
  /// spell of ours sharing that commitment with art to offer (preferring an
  /// exact generation-count match; otherwise any same-grid variant that has
  /// art), skips it if we have nothing new to offer, and otherwise adds it to
  /// the outgoing bundle. Sends the bundle once fully built (mirrors
  /// TradeSession.exchangeGrantsAndSave's single-send-at-the-end shape).
  ///
  /// Matching is by grid commitment — a per-spell identity — and deliberately
  /// NOT by the behavioural kinship key introduced in
  /// docs/COUNTER_CHARM_KINSHIP_PLAN.md Phase 3: art belongs to a spell, not
  /// to a behaviour, and kin-keyed matching would hand out one spell's art
  /// for a different player's coincidentally-matching one. Moves to
  /// `spell_identity.dart`'s `uniqueSpellId` in Phase 4, along with
  /// permissions. (This comment used to say "Kin variant", back when Kin
  /// meant "same grid".)
  Future<List<SyncArtResultItem>> _fulfillWantlist(
    List<Map<String, dynamic>> theirItems,
    String ourOwnerPubkeyHex,
  ) async {
    final ourOwned = (await SpellAsset.loadAll())
        .where((sp) => _hexEq(sp.ownerPubkeyHex, ourOwnerPubkeyHex))
        .toList();
    final sent = <SyncArtResultItem>[];
    final bundle = <Map<String, dynamic>>[];
    var totalBytes = 0;

    for (final item in theirItems) {
      final commitmentHex = item['commitmentHex'] as String;
      final t = item['t'] as int?;
      final currentArtHash = item['currentArtHash'] as String?;
      final currentSoundHash = item['currentSoundHash'] as String?;

      final artCandidate = _findCandidate(ourOwned, commitmentHex, t, (sp) => sp.artHash != null);
      final soundCandidate = _findCandidate(ourOwned, commitmentHex, t, (sp) => sp.soundHash != null);

      final entry = <String, dynamic>{'commitmentHex': commitmentHex};
      String? spellName;

      if (artCandidate != null &&
          (currentArtHash == null || !_hexEq(currentArtHash, artCandidate.artHash!))) {
        // D-5/F-3: built-in pack art travels as an id, never as bytes --
        // the peer's own APK already has these WebP files.
        final Map<String, dynamic>? part;
        if (artCandidate.artSource == SpellArtSource.builtIn && artCandidate.artPackId != null) {
          part = {'artHash': artCandidate.artHash, 'artPackId': artCandidate.artPackId};
        } else {
          final full = await resolveSpellArtFull(artCandidate);
          final thumb = await resolveSpellArtThumb(artCandidate);
          part = (full != null && thumb != null)
              ? {
                  'artHash': artCandidate.artHash,
                  'fullBase64': base64Encode(full),
                  'thumbBase64': base64Encode(thumb),
                }
              : null; // artHash pointer with no blob -- shouldn't happen, skip defensively
        }
        if (part != null && totalBytes + _claimedStringBytes(part) <= kSyncBundleMaxTotalBytes) {
          entry.addAll(part);
          totalBytes += _claimedStringBytes(part);
          spellName = artCandidate.name;
        }
      }

      if (soundCandidate != null &&
          (currentSoundHash == null || !_hexEq(currentSoundHash, soundCandidate.soundHash!))) {
        final Map<String, dynamic>? part;
        if (soundCandidate.soundSource == SpellSoundSource.builtIn && soundCandidate.soundPackId != null) {
          part = {'soundHash': soundCandidate.soundHash, 'soundPackId': soundCandidate.soundPackId};
        } else {
          final bytes = await resolveSpellSound(soundCandidate);
          part = bytes != null
              ? {'soundHash': soundCandidate.soundHash, 'soundBase64': base64Encode(bytes)}
              : null;
        }
        if (part != null && totalBytes + _claimedStringBytes(part) <= kSyncBundleMaxTotalBytes) {
          entry.addAll(part);
          totalBytes += _claimedStringBytes(part);
          spellName ??= soundCandidate.name;
        }
      }

      if (spellName == null) continue; // nothing new to offer for this commitment (or cap reached)
      entry['spellName'] = spellName;
      bundle.add(entry);
      sent.add(SyncArtResultItem(commitmentHex: commitmentHex, spellName: spellName, success: true));
    }

    _send(SyncArtMsgType.artBundle, utf8.encode(jsonEncode({'items': bundle})));
    return sent;
  }

  /// Finds a natively-owned spell sharing [commitmentHex] for which [has]
  /// holds (an art or a sound pointer), preferring an exact generation-count
  /// match over any other same-grid variant. Shared by both halves of
  /// [_fulfillWantlist] -- see its doc comment for why matching is by grid
  /// commitment, not the behavioural kinship key.
  SpellAsset? _findCandidate(
    List<SpellAsset> owned,
    String commitmentHex,
    int? t,
    bool Function(SpellAsset) has,
  ) {
    SpellAsset? candidate;
    for (final sp in owned) {
      if (!has(sp) || !_hexEq(sp.commitmentHex, commitmentHex)) continue;
      if (t != null && sp.t == t) return sp;
      candidate ??= sp;
    }
    return candidate;
  }

  /// A conservative byte-size estimate for one bundle-item's payload
  /// contribution, used only to enforce [kSyncBundleMaxTotalBytes] (F-2) --
  /// summing string field lengths overcounts slightly (hashes/ids are
  /// counted too) but that only makes the cap stricter, never looser.
  static int _claimedStringBytes(Map<String, dynamic> part) {
    var total = 0;
    for (final v in part.values) {
      if (v is String) total += v.length;
    }
    return total;
  }

  /// Validates and saves each entry in the peer's art+sound bundle against
  /// [ourSightings] (the same list we sent our want-list from, so every
  /// entry here should have a local match). Each byte-carrying half's
  /// integrity is checked by recomputing SHA-256 over the decoded bytes and
  /// comparing to the claimed hash -- same discipline spell_art_import.dart
  /// applies on local import, now applied to network-received bytes. Each
  /// pack-id-carrying half is checked by looking the id up in this device's
  /// own pack catalogue and confirming its sha256 matches the claimed hash --
  /// no bytes to hash, but no bytes to trust blindly either.
  Future<List<SyncArtResultItem>> _receiveAndSaveBundle(
    SyncArtFrame theirBundleFrame,
    List<SightingAsset> ourSightings,
  ) async {
    final theirItems = _decodeItems(theirBundleFrame.payload);
    final received = <SyncArtResultItem>[];
    var totalClaimedBytes = 0;

    for (final item in theirItems) {
      final commitmentHex = item['commitmentHex'] as String;
      final spellName = item['spellName'] as String? ?? '';

      SightingAsset? sighting;
      for (final s in ourSightings) {
        if (_hexEq(s.commitmentHex, commitmentHex)) {
          sighting = s;
          break;
        }
      }
      if (sighting == null) {
        received.add(SyncArtResultItem(
          commitmentHex: commitmentHex,
          spellName: spellName,
          success: false,
          error: 'no local sighting for this commitment',
        ));
        continue;
      }

      // F-2 total-bundle cap, checked BEFORE decoding anything in this item
      // (same "measure the base64 string, don't decode first" discipline the
      // per-item cap below already used) -- a peer who front-loads small
      // items to sneak real ones past a per-item-only cap gets stopped here.
      final fullB64 = item['fullBase64'] as String? ?? '';
      final thumbB64 = item['thumbBase64'] as String? ?? '';
      final soundB64 = item['soundBase64'] as String? ?? '';
      totalClaimedBytes += ((fullB64.length + thumbB64.length + soundB64.length) * 3) ~/ 4;
      if (totalClaimedBytes > kSyncBundleMaxTotalBytes) {
        received.add(SyncArtResultItem(
          commitmentHex: commitmentHex,
          spellName: spellName,
          success: false,
          error: 'sync bundle exceeds the total size cap',
        ));
        break; // stop processing the rest of this bundle entirely
      }

      var updated = sighting;
      var ok = true;
      String? failure;

      final artHash = item['artHash'] as String?;
      if (artHash != null) {
        final artPackId = item['artPackId'] as String?;
        if (artPackId != null) {
          SpellArtPackEntry? entry;
          for (final e in kPainterlyPack) {
            if (e.id == artPackId) {
              entry = e;
              break;
            }
          }
          if (entry == null || !_hexEq(entry.sha256, artHash)) {
            ok = false;
            failure = 'unknown or mismatched art pack id';
          } else {
            updated = updated.withArt(hash: artHash, source: SpellArtSource.builtIn, packId: artPackId);
          }
        } else if (fullB64.isNotEmpty) {
          // Per-item cap, mirroring spell_art_import.dart's local import path
          // (OUTSTANDING_ITEMS.md §7) -- the total cap above bounds the whole
          // frame; this bounds one item within it.
          if (((fullB64.length + thumbB64.length) * 3) ~/ 4 > kSpellArtMaxImportBytes) {
            ok = false;
            failure = 'art payload too large';
          } else {
            try {
              final full = base64Decode(fullB64);
              final thumb = base64Decode(thumbB64);
              final actualHash = await _sha256Hex(full);
              if (!_hexEq(actualHash, artHash)) {
                ok = false;
                failure = 'art integrity check failed';
              } else {
                await SpellArtStore.save(sighting.id, full: full, thumb: thumb);
                updated = updated.withArt(hash: artHash, source: SpellArtSource.synced);
              }
            } catch (_) {
              ok = false;
              failure = 'malformed art payload';
            }
          }
        }
      }

      final soundHash = ok ? item['soundHash'] as String? : null;
      if (ok && soundHash != null) {
        final soundPackId = item['soundPackId'] as String?;
        if (soundPackId != null) {
          SpellSoundPackEntry? entry;
          for (final e in kSpellSoundPack) {
            if (e.id == soundPackId) {
              entry = e;
              break;
            }
          }
          if (entry == null || !_hexEq(entry.sha256, soundHash)) {
            ok = false;
            failure = 'unknown or mismatched sound pack id';
          } else {
            updated = updated.withSound(hash: soundHash, source: SpellSoundSource.builtIn, packId: soundPackId);
          }
        } else if (soundB64.isNotEmpty) {
          if ((soundB64.length * 3) ~/ 4 > kSpellSoundMaxImportBytes) {
            ok = false;
            failure = 'sound payload too large';
          } else {
            try {
              final bytes = base64Decode(soundB64);
              final actualHash = await _sha256Hex(bytes);
              if (!_hexEq(actualHash, soundHash)) {
                ok = false;
                failure = 'sound integrity check failed';
              } else {
                await SpellSoundStore.save(sighting.id, bytes);
                updated = updated.withSound(hash: soundHash, source: SpellSoundSource.synced);
              }
            } catch (_) {
              ok = false;
              failure = 'malformed sound payload';
            }
          }
        }
      }

      if (!ok) {
        received.add(SyncArtResultItem(
          commitmentHex: commitmentHex,
          spellName: spellName,
          success: false,
          error: failure,
        ));
        continue;
      }

      await updated.save();
      received.add(SyncArtResultItem(commitmentHex: commitmentHex, spellName: spellName, success: true));
    }

    return received;
  }
}
