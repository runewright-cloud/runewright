// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_wire.dart — framing for the battle protocol layer.
//
// Type bytes 0x10–0x4F; intentionally non-overlapping with the
// proof-exchange MsgType bytes (0x01–0x07) in lib/protocol/wire.dart.
// Framing format is identical: [1 byte type][4 byte BE length][payload].
// BattleFrameReader reimplements FrameReader against BattleMsgType rather
// than modifying wire.dart and mixing concerns.
//
// See docs/BATTLE_PROTOCOL.md §1-§2 for the full message catalogue.

import 'dart:async';
import 'dart:typed_data';

enum BattleMsgType {
  // Session setup (§2)
  capabilities(0x10),
  matchConfig(0x11),
  matchConfigAck(0x12),
  matchConfigReject(0x13),
  bookCommit(0x14),
  bookHash(0x15),    // Option 2: SHA-256(sorted leaf bytes) exchanged at handshake
  bookReveal(0x16),  // Option 2: sorted commitmentHex list sent at match end

  // Identity authentication (BATTLE_AUTH_PLAN.md §3) — mutual Ed25519
  // challenge-response binding each side's authenticated owner_pubkey before
  // any spell cast is trusted.
  authChallenge(0x17),    // 32-byte fresh random nonce
  authResponse(0x18),     // rawPubkey(32) ‖ sig(64) over TAG_AUTH‖matchId‖peerNonce
  // Loan-permission exchange (BATTLE_AUTH_PLAN.md §5).
  spellPermissions(0x19), // JSON array of SpellPermission.toJson()

  // LAN duel setup (LAN_BATTLE_WIREUP_PLAN.md §3.2) — run once, before
  // exchangeCapabilities, to agree a matchId neither side unilaterally
  // controls; and once alongside bookCommit, to exchange each side's public
  // artifact loadout so both devices build an identical peer WizardAvatar.
  matchIdNonce(0x1A),     // 16-byte fresh random nonce
  artifactLoadout(0x1B),  // JSON array of ArtifactEntry.toJson()
  // SPELL_DRAW_WIRING_PLAN.md §3: each side's chapter leaf count, declared
  // publicly alongside bookCommit so DrawSchedule can compute nextInt(n) for
  // the peer's chapter without ever learning its contents.
  bookLeafCount(0x1C),    // uint32 big-endian
  // Player-chosen display name (Identity.loadWizardName()), exchanged
  // unauthenticated alongside the rest of setup — presentation only, never
  // trusted for identity/authorization (that's exchangeIdentityAuth's job).
  wizardName(0x1D),       // UTF-8 bytes, may be empty
  // Player-chosen avatar id (Identity.loadAvatarId(), an AvatarArt.id from
  // lib/ui/avatars/avatar_sprites.dart), exchanged the same way and for the
  // same reason as wizardName — unauthenticated, presentation only, never
  // fed into cast authorization or the state-hash lockstep. An unknown id
  // (older peer, dropped catalog entry) degrades to the default via
  // avatarArtById returning null. See docs/AVATAR_PICKER_PLAN.md §5.2.
  avatarId(0x1E),         // UTF-8 bytes, may be empty

  // Commit-reveal entropy (§3)
  nonceCommit(0x20),
  nonceReveal(0x21),
  // Mid-resolution entropy refresh (§3b — interactive spell effects)
  refreshEntropyCommit(0x22),
  refreshEntropyReveal(0x23),

  // Turn loop (§2)
  moveCommit(0x30),
  moveReveal(0x31),
  spellCast(0x32),   // legacy / reserved
  haymaker(0x33),    // legacy / reserved
  stateHash(0x34),
  actionCommit(0x35),
  actionReveal(0x36),
  delayedSpellReveal(0x37),
  // Divination (Air-Water) scrying pattern — MESH_ARCHITECTURE.md §13b.
  scryKey(0x38),
  scryOpen(0x39),
  // Resolution-phase melee commit-reveal (post-movement, independent of casting).
  meleeCommit(0x3A),
  meleeReveal(0x3B),
  // Post-resolution free-move commit-reveal (barrier-burst reactive step).
  freeMoveCommit(0x3C),
  freeMoveReveal(0x3D),
  // Divination (Water flavor — Watery Scrying Pool) spell-list reveal.
  // Same encrypted-broadcast shape as scryKey/scryOpen but kept as its own
  // message pair since a player may have simultaneous Air + Water links to
  // the same peer and each flavor's exchange stays independent.
  spellRevealKey(0x3E),
  spellRevealOpen(0x3F),

  // Match control (§2)
  forfeit(0x40),
  matchEnd(0x41),
  // Signed match outcome (MASTER_APPRENTICE_PLAN.md §4) — each side's
  // SignedMatchOutcome, exchanged after both agree the match is over. Not
  // the same as matchEnd (0x41), which is an unauthenticated advisory only.
  matchResultSig(0x42),

  // Forced reveal-and-cast (docs/WILD_MAGIC_PLAN.md §9.5) — wild magic's
  // Spontaneous Combustion is the first caller. A player's hand CONTENTS are
  // private (DrawSchedule mirrors positions only), so an effect that resolves
  // a spell out of the peer's hand needs them to reveal it, with its proof, on
  // the spot. Slots are chosen publicly FIRST, from the position-only
  // schedule, so the revealer cannot shop for a favourable spell.
  //
  // Sent ONLY on turns where a forced cast actually fires. That is safe
  // because both clients derive the triggering wild magic from the same
  // certified proof outputs and so reach the exchange together; this is NOT
  // one of the uniform every-turn slots.
  forcedReveal(0x43),

  // Phase 0 artifact activation (docs/ARTIFACT_SYSTEM_PLAN.md §4.2) — the
  // earliest exchange in the turn, ahead of the Phase 1 action commit, so each
  // side learns whether the other has spent an artifact (and therefore has
  // their counter charms down) while there is still time to act on it.
  //
  // Commit-reveal, not a plain exchange: the declaration is public afterwards,
  // but simultaneity still has to be enforced or a peer could stall, read our
  // declaration, and then pick theirs. Sent uniformly every turn, encoding
  // [0x00] when nothing is declared, so the frame sequence never varies.
  //
  // Allocated in the 0x4x block rather than alongside the other turn-loop
  // exchanges because the 0x30–0x3F block is full.
  artifactCommit(0x44),
  artifactReveal(0x45);

  const BattleMsgType(this.byte);
  final int byte;

  static BattleMsgType fromByte(int b) => BattleMsgType.values.firstWhere(
        (t) => t.byte == b,
        orElse: () => throw ArgumentError('unknown BattleMsgType byte 0x${b.toRadixString(16)}'),
      );
}

class BattleFrame {
  BattleFrame(this.type, this.payload);

  final BattleMsgType type;
  final Uint8List payload;

  Uint8List encode() {
    final out = BytesBuilder();
    out.addByte(type.byte);
    final lenBytes = ByteData(4)..setUint32(0, payload.length, Endian.big);
    out.add(lenBytes.buffer.asUint8List());
    out.add(payload);
    return out.toBytes();
  }
}

/// Reassembles a byte stream into discrete [BattleFrame]s.
///
/// Identical to FrameReader in wire.dart but typed to [BattleMsgType].
/// Broadcast stream so multiple callers can subscribe simultaneously —
/// required for the bidirectional battle session (unlike MatchSession's
/// strict request/response).
///
/// [framesOfType] is queue-backed (see [_pendingByType]/[_waitersByType]),
/// not a bare `.where()` filter over the broadcast stream — a plain
/// broadcast `StreamController` drops any event added while it has no
/// listener, and every exchange method's `send(...); await
/// framesOfType(type).first` pattern has a real window where the peer's
/// reply can be decoded before our own `.first` call gets around to
/// subscribing (found while building the LAN duel setup flow — see
/// LAN_BATTLE_WIREUP_PLAN.md: two genuinely concurrent identities' differing
/// FFI latency during `exchangeIdentityAuth` was enough to trigger it
/// reliably, not just a rare fluke). This never drops a frame that arrives
/// first, and never replays a frame already claimed by an earlier waiter —
/// every call site's usage is "at most one active waiter per type," so a
/// later call for the same type is always for that type's NEXT occurrence
/// (e.g. next turn's `actionCommit`, not a replay of this turn's).
class BattleFrameReader {
  final _buffer = BytesBuilder();
  final _controller = StreamController<BattleFrame>.broadcast();

  /// Frames of a given type received but not yet claimed by any
  /// [framesOfType] listener.
  final Map<BattleMsgType, List<BattleFrame>> _pendingByType = {};

  /// Callbacks registered by a [framesOfType] listener that arrived before
  /// any frame of that type — delivered directly, bypassing [_pendingByType],
  /// the moment a matching frame is decoded.
  final Map<BattleMsgType, List<void Function(BattleFrame)>> _waitersByType = {};

  /// Every frame, in arrival order, regardless of type. Used only by
  /// [BattleSession.exchangeMatchConfig]'s ack/reject dual-type wait — a
  /// single, tightly-sequenced (send-then-immediately-await) case that
  /// doesn't go through [framesOfType], so it's unaffected by (and doesn't
  /// need) the buffering above.
  Stream<BattleFrame> get frames => _controller.stream;

  void addChunk(List<int> chunk) {
    _buffer.add(chunk);
    _drain();
  }

  void _drain() {
    var bytes = _buffer.toBytes();
    while (true) {
      if (bytes.length < 5) break;
      final len = ByteData.sublistView(bytes, 1, 5).getUint32(0, Endian.big);
      final frameLen = 5 + len;
      if (bytes.length < frameLen) break;
      final type = BattleMsgType.fromByte(bytes[0]);
      final payload = Uint8List.sublistView(bytes, 5, frameLen);
      _dispatch(BattleFrame(type, payload));
      bytes = Uint8List.sublistView(bytes, frameLen);
    }
    _buffer.clear();
    _buffer.add(bytes);
  }

  void _dispatch(BattleFrame frame) {
    final waiters = _waitersByType[frame.type];
    if (waiters != null && waiters.isNotEmpty) {
      waiters.removeAt(0)(frame);
    } else {
      (_pendingByType[frame.type] ??= []).add(frame);
    }
    _controller.add(frame);
  }

  /// A stream whose first (and only) element is the next frame of exactly
  /// [type] — already-arrived-and-buffered if one is pending, otherwise the
  /// next one decoded. See the class doc comment for why this exists rather
  /// than a `.where()` filter over [frames].
  Stream<BattleFrame> framesOfType(BattleMsgType type) {
    return Stream<BattleFrame>.multi((emitter) {
      final pending = _pendingByType[type];
      if (pending != null && pending.isNotEmpty) {
        emitter
          ..add(pending.removeAt(0))
          ..close();
        return;
      }
      void deliver(BattleFrame frame) {
        emitter
          ..add(frame)
          ..close();
      }

      (_waitersByType[type] ??= []).add(deliver);
      emitter.onCancel = () {
        _waitersByType[type]?.remove(deliver);
      };
    });
  }

  Future<void> close() => _controller.close();
}
