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
import '../spells/spell_art_store.dart';
import '../spells/spell_asset.dart';
import 'sync_art_wire.dart';

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
  /// exact generation-count match; otherwise any Kin variant that has art),
  /// skips it if we have nothing new to offer, and otherwise adds it to the
  /// outgoing bundle. Sends the bundle once fully built (mirrors
  /// TradeSession.exchangeGrantsAndSave's single-send-at-the-end shape).
  Future<List<SyncArtResultItem>> _fulfillWantlist(
    List<Map<String, dynamic>> theirItems,
    String ourOwnerPubkeyHex,
  ) async {
    final ourOwned = (await SpellAsset.loadAll())
        .where((sp) => _hexEq(sp.ownerPubkeyHex, ourOwnerPubkeyHex))
        .toList();
    final sent = <SyncArtResultItem>[];
    final bundle = <Map<String, dynamic>>[];

    for (final item in theirItems) {
      final commitmentHex = item['commitmentHex'] as String;
      final t = item['t'] as int?;
      final currentArtHash = item['currentArtHash'] as String?;

      SpellAsset? candidate;
      for (final sp in ourOwned) {
        if (sp.artHash == null || !_hexEq(sp.commitmentHex, commitmentHex)) continue;
        if (t != null && sp.t == t) {
          candidate = sp;
          break;
        }
        candidate ??= sp;
      }
      if (candidate == null) continue; // we have no art to offer for this spell
      final ourArtHash = candidate.artHash!;
      if (currentArtHash != null && _hexEq(currentArtHash, ourArtHash)) {
        continue; // they already have our current art
      }

      final full = await SpellArtStore.loadFull(candidate.spellHashHex);
      final thumb = await SpellArtStore.loadThumb(candidate.spellHashHex);
      if (full == null || thumb == null) {
        continue; // artHash pointer with no blob -- shouldn't happen, skip defensively
      }

      bundle.add({
        'commitmentHex': commitmentHex,
        'artHash': ourArtHash,
        'spellName': candidate.name,
        'fullBase64': base64Encode(full),
        'thumbBase64': base64Encode(thumb),
      });
      sent.add(SyncArtResultItem(commitmentHex: commitmentHex, spellName: candidate.name, success: true));
    }

    _send(SyncArtMsgType.artBundle, utf8.encode(jsonEncode({'items': bundle})));
    return sent;
  }

  /// Validates and saves each entry in the peer's art bundle against
  /// [ourSightings] (the same list we sent our want-list from, so every
  /// entry here should have a local match). Each entry's integrity is
  /// checked by recomputing SHA-256 over the decoded bytes and comparing to
  /// the claimed artHash -- same discipline spell_art_import.dart applies on
  /// local import, now applied to network-received bytes.
  Future<List<SyncArtResultItem>> _receiveAndSaveBundle(
    SyncArtFrame theirBundleFrame,
    List<SightingAsset> ourSightings,
  ) async {
    final theirItems = _decodeItems(theirBundleFrame.payload);
    final received = <SyncArtResultItem>[];

    for (final item in theirItems) {
      final commitmentHex = item['commitmentHex'] as String;
      final artHash = item['artHash'] as String;
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

      final Uint8List full;
      final Uint8List thumb;
      try {
        full = base64Decode(item['fullBase64'] as String);
        thumb = base64Decode(item['thumbBase64'] as String);
      } catch (_) {
        received.add(SyncArtResultItem(
          commitmentHex: commitmentHex,
          spellName: spellName,
          success: false,
          error: 'malformed art payload',
        ));
        continue;
      }

      final actualHash = await _sha256Hex(full);
      if (!_hexEq(actualHash, artHash)) {
        received.add(SyncArtResultItem(
          commitmentHex: commitmentHex,
          spellName: spellName,
          success: false,
          error: 'art integrity check failed',
        ));
        continue;
      }

      await SpellArtStore.save(sighting.id, full: full, thumb: thumb);
      await sighting.withArt(hash: artHash).save();
      received.add(SyncArtResultItem(commitmentHex: commitmentHex, spellName: spellName, success: true));
    }

    return received;
  }
}
