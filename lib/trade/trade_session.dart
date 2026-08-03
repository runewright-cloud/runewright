// SPDX-License-Identifier: GPL-3.0-or-later
//
// trade_session.dart — the Commune/Trade protocol: pairing handshake,
// advisory offer preview, mutual confirm gate, and grant delivery.
//
// Non-atomic by design (docs/COMMUNE_TRADE_PLAN.md §2.4, mirroring
// runewright_design_v3_0.md §"Spell Transfer"): once both sides confirm,
// each independently sends its promised grants. Nothing in this protocol
// guarantees a confirmed peer actually sends — the binding is the same
// social cost the design doc leans on for scroll/loan bargains generally.
// [TradeResult] reports what was sent and what was received-and-saved
// honestly, rather than pretending atomicity that isn't there.
//
// Frame routing reads from TradeFrameReader's broadcast stream (like
// BattleSession) rather than MatchSession's strict request/response
// Completer -- but every protocol await goes through [_nextFrame], which
// keeps ONE permanent subscription and buffers frames nobody is waiting for
// yet. That buffer is mandatory, not an optimization: a broadcast stream
// drops events delivered while unsubscribed, and every step here is gated
// on a human pressing a button, so the two peers are never subscribed at
// the same moment. See [_nextFrame] and docs/M4_findings.md (2026-07-28).

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../identity/identity.dart';
import '../protocol/transport.dart';
import '../protocol/wire.dart' show lengthPrefixedConcat, lengthPrefixedSplit;
import '../spells/spell_asset.dart';
import '../spells/spell_permission.dart';
import 'trade_offer.dart';
import 'trade_wire.dart';

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

Uint8List _randomBytes(int n) {
  final rng = Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

// ── Result reporting ──────────────────────────────────────────────────────

class TradeResultItem {
  const TradeResultItem({required this.item, required this.success, this.error});

  final TradeItem item;
  final bool success;

  /// Set iff [success] is false — a human-readable reason a grant we tried
  /// to send couldn't be signed, or a grant we received failed validation.
  final String? error;
}

/// Summary of one [TradeSession.exchangeGrantsAndSave] call. [sent] reports
/// whether we successfully signed and transmitted each of our offered
/// items — NOT whether the peer received them (no atomicity guarantee, see
/// file header). [received] reports each of the peer's grants we validated
/// and saved, or rejected and why.
class TradeResult {
  const TradeResult({required this.sent, required this.received});

  final List<TradeResultItem> sent;
  final List<TradeResultItem> received;
}

// ── Session ────────────────────────────────────────────────────────────────

/// One pending [TradeSession._nextFrame] await: the frame types it will
/// accept, and the completer to resolve when one arrives.
class _FrameWaiter {
  _FrameWaiter(this.types, this.completer);
  final Set<TradeMsgType> types;
  final Completer<TradeFrame> completer;
}

class TradeSession {
  TradeSession._(
    this._transport,
    this.tradeId,
    this.peerOwnerPubkeyHex,
    this.peerRawPubkeyBytes,
    this._reader,
    this._sub,
  ) {
    // Subscribe ONCE, for the session's whole life, and buffer anything
    // nobody is waiting for yet -- see [_nextFrame].
    _frameSub = _reader.frames.listen(
      _routeFrame,
      onDone: () => _failPendingWaiters(StateError('trade connection closed by peer')),
      onError: _failPendingWaiters,
    );
  }

  final Transport _transport;

  /// Fixed at handshake time by the initiator, adopted (never re-read from
  /// a later message) by the responder — same discipline as MatchSession's
  /// matchId, though nothing in this protocol currently signs over it.
  final Uint8List tradeId;

  final String peerOwnerPubkeyHex;
  final Uint8List peerRawPubkeyBytes;

  final TradeFrameReader _reader;
  final StreamSubscription<List<int>> _sub;

  /// The session's single, permanent subscription to [_reader] -- see the
  /// constructor and [_nextFrame].
  late final StreamSubscription<TradeFrame> _frameSub;

  /// Frames that arrived before anything was waiting for them, oldest
  /// first. THIS IS THE LOAD-BEARING PIECE -- see [_nextFrame].
  final _buffered = <TradeFrame>[];

  final _waiters = <_FrameWaiter>[];

  /// Set once the connection closes or errors; makes every subsequent
  /// [_nextFrame] fail fast instead of waiting for a frame that can no
  /// longer arrive.
  Object? _closedReason;

  /// Raw frame stream. Prefer [_nextFrame] for anything the protocol
  /// awaits: this is a *broadcast* stream, so subscribing to it late means
  /// silently missing everything that already arrived (see [_nextFrame]).
  Stream<TradeFrame> get frames => _reader.frames;
  Stream<TradeFrame> framesOfType(TradeMsgType type) => frames.where((f) => f.type == type);

  void _routeFrame(TradeFrame frame) {
    for (var i = 0; i < _waiters.length; i++) {
      if (_waiters[i].types.contains(frame.type)) {
        _waiters.removeAt(i).completer.complete(frame);
        return;
      }
    }
    _buffered.add(frame);
  }

  void _failPendingWaiters(Object error) {
    _closedReason ??= error;
    final pending = List<_FrameWaiter>.from(_waiters);
    _waiters.clear();
    for (final waiter in pending) {
      if (!waiter.completer.isCompleted) waiter.completer.completeError(error);
    }
  }

  /// Waits for the next frame of any type in [types], **including one that
  /// already arrived before this call**.
  ///
  /// This buffering is not an optimization, it is the correctness fix for a
  /// real two-device hang (2026-07-28, docs/M4_findings.md). [_reader]'s
  /// controller is a *broadcast* controller, and a broadcast stream drops
  /// any event added while it has no subscriber. Every step of this
  /// protocol is gated on a human: the two players hit "Submit offer" (and
  /// later "Confirm") seconds or minutes apart. Whoever acted FIRST sent
  /// their frame while the other device was still sitting in its offer-
  /// builder UI with nothing subscribed -- so that frame was discarded, and
  /// the second player's await could never be satisfied. The hang followed
  /// submission order, not host/guest role, which is exactly this.
  ///
  /// Subscribing before sending (as the callers below still do) does NOT
  /// fix it: the gap that matters is between the two peers *calling the
  /// method at all*, not between subscribe and send within one method.
  Future<TradeFrame> _nextFrame(Set<TradeMsgType> types) {
    for (var i = 0; i < _buffered.length; i++) {
      if (types.contains(_buffered[i].type)) {
        return Future.value(_buffered.removeAt(i));
      }
    }
    if (_closedReason != null) return Future.error(_closedReason!);
    final completer = Completer<TradeFrame>();
    _waiters.add(_FrameWaiter(types, completer));
    return completer.future;
  }

  void _send(TradeMsgType type, List<int> payload) {
    _transport.send(TradeFrame(type, Uint8List.fromList(payload)).encode());
  }

  // ── Handshake ────────────────────────────────────────────────────────────

  /// Initiator side: generates a fresh tradeId, sends our raw pubkey, waits
  /// for the peer's tradeHelloAck (their raw pubkey), and resolves their
  /// owner_pubkey via [Identity.ownerPubkeyHexFromRawKey].
  static Future<TradeSession> initiate(Transport transport, Identity identity) async {
    final reader = TradeFrameReader();
    // onDone/onError close the reader so a dropped connection surfaces as a
    // failed await rather than an indefinite stall (TradeSession's
    // _frameSub turns the resulting stream-close into an error on every
    // pending waiter).
    final sub = transport.onReceive.listen(
      reader.addChunk,
      onDone: reader.close,
      onError: (Object _) => reader.close(),
    );
    final tradeId = _randomBytes(16);

    final ackFuture = reader.frames.where((f) => f.type == TradeMsgType.tradeHelloAck).first;
    transport.send(
      TradeFrame(
        TradeMsgType.tradeHello,
        Uint8List.fromList(lengthPrefixedConcat([tradeId, identity.publicKeyBytes])),
      ).encode(),
    );
    final ack = await ackFuture;
    final peerRawPubkeyBytes = Uint8List.fromList(ack.payload);
    final peerOwnerPubkeyHex = await Identity.ownerPubkeyHexFromRawKey(peerRawPubkeyBytes);

    return TradeSession._(transport, tradeId, peerOwnerPubkeyHex, peerRawPubkeyBytes, reader, sub);
  }

  /// Responder side: waits for the peer's tradeHello, adopts its tradeId,
  /// and replies with our own raw pubkey.
  static Future<TradeSession> accept(Transport transport, Identity identity) async {
    final reader = TradeFrameReader();
    // onDone/onError close the reader so a dropped connection surfaces as a
    // failed await rather than an indefinite stall (TradeSession's
    // _frameSub turns the resulting stream-close into an error on every
    // pending waiter).
    final sub = transport.onReceive.listen(
      reader.addChunk,
      onDone: reader.close,
      onError: (Object _) => reader.close(),
    );

    final hello = await reader.frames.where((f) => f.type == TradeMsgType.tradeHello).first;
    final parts = lengthPrefixedSplit(hello.payload, 2);
    final tradeId = Uint8List.fromList(parts[0]);
    final peerRawPubkeyBytes = Uint8List.fromList(parts[1]);
    final peerOwnerPubkeyHex = await Identity.ownerPubkeyHexFromRawKey(peerRawPubkeyBytes);

    transport.send(TradeFrame(TradeMsgType.tradeHelloAck, identity.publicKeyBytes).encode());

    return TradeSession._(transport, tradeId, peerOwnerPubkeyHex, peerRawPubkeyBytes, reader, sub);
  }

  Future<void> close() async {
    await _frameSub.cancel();
    await _sub.cancel();
    await _reader.close();
    // Explicit, because cancelling [_frameSub] above means its onDone will
    // never fire -- without this, a caller who closed the session out from
    // under an in-flight exchange (trade_screen.dart's Cancel button) would
    // leave that await hanging forever, which is the very bug this class
    // was just fixed for.
    _failPendingWaiters(StateError('trade session closed'));
  }

  // ── Offer exchange (advisory preview) ─────────────────────────────────────

  /// Sends our offer and returns the peer's — both sides see "you give /
  /// you get" before confirming. Advisory only: the binding step is
  /// [exchangeConfirm] + [exchangeGrantsAndSave].
  Future<TradeOffer> exchangeOffer(TradeOffer ours) async {
    final theirsFuture = _nextFrame(const {TradeMsgType.offer});
    _send(TradeMsgType.offer, utf8.encode(jsonEncode(ours.toJson())));
    final frame = await theirsFuture;
    return TradeOffer.fromJson(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>);
  }

  // ── Mutual confirm gate ────────────────────────────────────────────────────

  /// Sends our confirm/cancel decision and waits for the peer's. Returns
  /// true only if both sides confirmed — a cancel from either side (or a
  /// cancel we send ourselves) means no grants should be exchanged.
  Future<bool> exchangeConfirm(bool weConfirm) async {
    // Same human-scale gap as exchangeOffer -- the two players decide
    // independently, so whichever confirms first would otherwise have its
    // decision dropped. See [_nextFrame].
    final theirsFuture = _nextFrame(const {TradeMsgType.confirm, TradeMsgType.cancel});
    _send(weConfirm ? TradeMsgType.confirm : TradeMsgType.cancel, const []);
    final theirs = await theirsFuture;
    return weConfirm && theirs.type == TradeMsgType.confirm;
  }

  // ── Grant delivery ─────────────────────────────────────────────────────────

  /// Signs a grant for each item in [ourOffer] (looking up the full
  /// [SpellAsset] by id in [ourSpells]), sends the bundle, and concurrently
  /// receives, validates, and saves the peer's bundle. Only call after both
  /// sides have confirmed via [exchangeConfirm].
  ///
  /// Each received grant is checked before saving: it must name us as
  /// grantee, name the peer as owner, and be currently usable (valid
  /// signature, and for loans, not yet expired — see
  /// [SpellPermission.isCurrentlyUsable]). Transfer grants must carry an
  /// accompanying [SpellAsset]; it is saved under a fresh local id so it
  /// never collides with anything already on disk.
  Future<TradeResult> exchangeGrantsAndSave({
    required Identity ourIdentity,
    required TradeOffer ourOffer,
    required List<SpellAsset> ourSpells,
  }) async {
    // Registered BEFORE any async prep work (signing below involves several
    // FFI round-trips) so a peer whose own prep finishes first is handled
    // in order. Since 2026-07-28 this is belt-and-braces rather than the
    // whole defence: [_nextFrame] buffers a bundle that arrives before this
    // call, so an early peer can no longer be missed either way.
    final theirsFuture = _nextFrame(const {TradeMsgType.grantBundle});

    final ourOwnerPubkeyHex = await ourIdentity.ownerPubkeyHex();
    final bundleEntries = <Map<String, dynamic>>[];
    final sent = <TradeResultItem>[];

    for (final item in ourOffer.items) {
      SpellAsset? spell;
      for (final candidate in ourSpells) {
        if (candidate.id == item.spellId) {
          spell = candidate;
          break;
        }
      }
      if (spell == null) {
        sent.add(TradeResultItem(item: item, success: false, error: 'spell not found locally'));
        continue;
      }
      try {
        final SpellPermission perm;
        if (item.mode == TradeMode.loan) {
          perm = await SpellPermission.createAndSign(
            spell: spell,
            ownerIdentity: ourIdentity,
            granteePubkeyHex: peerOwnerPubkeyHex,
            kind: SpellGrantKind.loan,
            expiresAt: DateTime.now().toUtc().add(Duration(days: item.loanDays!)),
          );
        } else {
          perm = await SpellPermission.createAndSign(
            spell: spell,
            ownerIdentity: ourIdentity,
            granteePubkeyHex: peerOwnerPubkeyHex,
            kind: SpellGrantKind.transfer,
            provenance: [ProvenanceStep(pubkeyHex: ourOwnerPubkeyHex, at: DateTime.now().toUtc())],
          );
        }
        // A loan sends proof bytes (zero-knowledge -- they don't leak the
        // grid) plus every other field, with the grid itself redacted; a
        // transfer sends the full asset, grid included. Without this, a
        // loanee would have nothing locally to reference: localIdentityMayUse
        // takes a SpellAsset, and there is no other source for one.
        bundleEntries.add({
          'permission': perm.toJson(),
          'asset': (item.mode == TradeMode.loan ? spell.withGridWithheld() : spell).toJson(),
        });
        sent.add(TradeResultItem(item: item, success: true));
      } catch (e) {
        sent.add(TradeResultItem(item: item, success: false, error: e.toString()));
      }
    }

    _send(TradeMsgType.grantBundle, utf8.encode(jsonEncode({'entries': bundleEntries})));
    final theirsFrame = await theirsFuture;
    _send(TradeMsgType.bundleAck, const []);

    final received = await _receiveAndSaveBundle(theirsFrame, ourOwnerPubkeyHex);

    return TradeResult(sent: sent, received: received);
  }

  Future<List<TradeResultItem>> _receiveAndSaveBundle(TradeFrame theirsFrame, String ourOwnerPubkeyHex) async {
    final theirsJson = jsonDecode(utf8.decode(theirsFrame.payload)) as Map<String, dynamic>;
    final theirEntries = theirsJson['entries'] as List<dynamic>? ?? [];
    final received = <TradeResultItem>[];

    for (final raw in theirEntries) {
      final entry = raw as Map<String, dynamic>;
      final perm = SpellPermission.fromJson(entry['permission'] as Map<String, dynamic>);
      final assetJson = entry['asset'] as Map<String, dynamic>?;
      final mode = perm.kind == SpellGrantKind.loan ? TradeMode.loan : TradeMode.transfer;
      final loanDays =
          perm.kind == SpellGrantKind.loan ? perm.expiresAt!.difference(perm.grantedAt).inDays : null;

      String describedSpellName() => assetJson?['name'] as String? ?? '(unnamed spell)';

      TradeItem placeholderItem(String spellId) => TradeItem(
            spellId: spellId,
            commitmentHex: perm.commitmentHex,
            spellName: describedSpellName(),
            mode: mode,
            loanDays: loanDays,
          );

      if (!_hexEq(perm.granteePubkeyHex, ourOwnerPubkeyHex)) {
        received.add(TradeResultItem(
          item: placeholderItem(perm.id),
          success: false,
          error: 'grant does not name this device as grantee',
        ));
        continue;
      }
      if (!_hexEq(perm.ownerPubkeyHex, peerOwnerPubkeyHex)) {
        received.add(TradeResultItem(
          item: placeholderItem(perm.id),
          success: false,
          error: 'grant owner does not match the connected peer',
        ));
        continue;
      }
      if (!await perm.isCurrentlyUsable()) {
        received.add(TradeResultItem(
          item: placeholderItem(perm.id),
          success: false,
          error: 'grant signature invalid or already expired',
        ));
        continue;
      }

      // Both loan and transfer bundle entries carry an asset -- a loan's is
      // grid-redacted (SpellAsset.withGridWithheld, set by the sender),
      // a transfer's carries the real grid. Without SOME local SpellAsset,
      // a grantee would have nothing for localIdentityMayUse to check
      // against, so both kinds require one here.
      if (assetJson == null) {
        received.add(TradeResultItem(
          item: placeholderItem(perm.id),
          success: false,
          error: 'grant missing its spell asset',
        ));
        continue;
      }
      final incoming = SpellAsset.fromJson(assetJson);
      if (perm.kind == SpellGrantKind.loan && incoming.initialGrid.isNotEmpty) {
        // The sender's own TradeSession always redacts a loan's grid before
        // sending (see exchangeGrantsAndSave above) -- a non-empty grid here
        // means either a protocol bug on the sender's side or a forged
        // bundle entry. Reject rather than silently accept a grid we were
        // never supposed to receive.
        received.add(TradeResultItem(
          item: placeholderItem(perm.id),
          success: false,
          error: 'loan grant unexpectedly included the grid state',
        ));
        continue;
      }
      final freshId = 'received-${DateTime.now().toUtc().microsecondsSinceEpoch}-${incoming.id}';
      final saved = SpellAsset(
        id: freshId,
        createdAt: incoming.createdAt,
        tier: incoming.tier,
        t: incoming.t,
        ownerPubkeyHex: incoming.ownerPubkeyHex,
        manaCost: incoming.manaCost,
        segmentCount: incoming.segmentCount,
        dotCount: incoming.dotCount,
        initialGrid: incoming.initialGrid,
        proofBytes: incoming.proofBytes,
        name: incoming.name,
        commitmentHex: incoming.commitmentHex,
        spellHashHex: incoming.spellHashHex,
        formula: incoming.formula,
        supremeTags: incoming.supremeTags,
        isSummon: incoming.isSummon,
        summonPersonality: incoming.summonPersonality,
        gridWithheld: perm.kind == SpellGrantKind.loan,
      );
      await saved.save();
      await perm.save();
      received.add(TradeResultItem(item: placeholderItem(saved.id), success: true));
    }

    return received;
  }
}
