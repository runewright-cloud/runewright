// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_session.dart — bidirectional battle protocol session.
//
// Unlike MatchSession (strict request/response, one Completer at a time),
// BattleSession routes incoming frames by type to a broadcast stream —
// required because both clients can send simultaneously (movement commits,
// state hashes, etc.). Callers subscribe to framesOfType() for the type
// they're waiting for; the TurnLoop drives the exchange order.
//
// Lifecycle: created from a Transport AFTER MatchSession.close() has
// cancelled its subscription, then discarded at match end.
// The matchId carried over from the proof-exchange handshake is stored for
// context (BATTLE_PROTOCOL.md §0).
//
// See docs/BATTLE_PROTOCOL.md §0-§2 for the full protocol sequence.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../identity/identity.dart';
import '../../protocol/transport.dart';
import '../../spells/chapter_asset.dart' show ArtifactEntry;
import '../../spells/spell_permission.dart';
import '../engine/book_commitment.dart';
import '../engine/commit_reveal.dart';
import '../models/match_config.dart';
import '../models/match_outcome.dart';
import 'battle_wire.dart';
import 'match_discovery.dart';

/// Domain-separation tag for the identity-authentication handshake signature
/// (BATTLE_AUTH_PLAN.md §3). Distinct from [kStateHashSignatureTag] so an
/// auth signature can never be replayed as a state-hash signature or
/// vice-versa.
const kIdentityAuthSignatureTag = 'RUNEWRIGHT_BATTLE_AUTH_V1\x00';

/// The result of a successful [BattleTurnSession.exchangeIdentityAuth] — the
/// peer's raw Ed25519 public key and its derived circuit-facing owner_pubkey,
/// both *authenticated* by a fresh-nonce signature (not merely asserted by an
/// unverified proof public input — see BATTLE_AUTH_PLAN.md §0/§2).
class AuthenticatedPeer {
  const AuthenticatedPeer({required this.rawPubkey, required this.ownerPubkeyHex});

  /// Raw 32-byte Ed25519 public key, verified via a fresh-nonce signature.
  final Uint8List rawPubkey;

  /// Poseidon2(key_hi, key_lo) of [rawPubkey] — the circuit-facing identity
  /// that spell proofs declare as their owner_pubkey public input.
  final String ownerPubkeyHex;

  /// Sentinel for solo/local play, where there is no real peer to
  /// authenticate. Empty owner_pubkey hex so identity/authorization checks
  /// (which compare hex strings) never accidentally match a real spell owner.
  static final none = AuthenticatedPeer(rawPubkey: Uint8List(0), ownerPubkeyHex: '');
}

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

// ── TurnLoop exchange interface ───────────────────────────────────────────────

/// Abstract interface for the per-turn commit-reveal exchanges that [TurnLoop]
/// needs. Implemented by [BattleSession] (network) and [SoloBattleSession]
/// (local solo stub).
abstract class BattleTurnSession {
  /// Mutual Ed25519 challenge-response identity authentication
  /// (BATTLE_AUTH_PLAN.md §3). Must run once per session, before any spell
  /// cast is trusted (it feeds cast authorization and loan-permission
  /// verification). Solo/local play returns [AuthenticatedPeer.none].
  Future<AuthenticatedPeer> exchangeIdentityAuth({
    required Identity localIdentity,
    required Uint8List matchId,
  });

  /// Exchanges signed loan/transfer grants naming the authenticated peer as
  /// grantee (BATTLE_AUTH_PLAN.md §5). Returns only permissions that verify —
  /// signature valid, not expired, and [SpellPermission.granteePubkeyHex]
  /// matches [peerOwnerPubkeyHex] (the value [exchangeIdentityAuth] returned).
  /// Solo/local play returns an empty list.
  Future<List<SpellPermission>> exchangeSpellPermissions(
    List<SpellPermission> ours, {
    required String peerOwnerPubkeyHex,
  });

  Future<({Uint8List theirNonce, Uint8List theirCommit})> exchangeNonce({
    required Uint8List ourCommit,
    required Uint8List ourNonce,
  });
  Future<Uint8List> exchangeActionCommit(Uint8List ourCommit);
  Future<Uint8List> exchangeActionReveal(Uint8List ourReveal);
  Future<Uint8List> exchangeMoveCommit(Uint8List ourCommit);
  Future<Uint8List> exchangeMoveReveal(Uint8List ourReveal);
  Future<Uint8List> exchangeDelayedSpellReveals(Uint8List ourReveals);
  Future<Uint8List> exchangeStateHash(Uint8List ourHash);

  /// Phase 0 artifact-activation commit-reveal (ARTIFACT_SYSTEM_PLAN.md §4.2).
  ///
  /// The first exchange of the turn, ahead of the Phase 1 action commit: each
  /// player secretly commits which artifact (if any) they are spending this
  /// turn, then both reveal simultaneously. Shape mirrors
  /// [exchangeMeleeCommit]/[exchangeMeleeReveal] exactly, and like them it is
  /// sent uniformly every turn — `[0x00]` means "declaring nothing" — so the
  /// frame sequence is identical on both clients regardless of who spent what.
  ///
  /// Commit-reveal rather than a plain send-then-await because the declaration
  /// is a simultaneous decision: with a plain exchange a peer could stall,
  /// read our declaration, and then choose theirs.
  Future<Uint8List> exchangeArtifactActivationCommit(Uint8List ourCommit);
  Future<Uint8List> exchangeArtifactActivationReveal(Uint8List ourReveal);

  /// Resolution-phase melee commit-reveal: after movement has resolved (so
  /// both final positions are known), each player secretly commits an
  /// optional adjacent melee target, then both reveal simultaneously. Mirrors
  /// [exchangeMoveCommit]/[exchangeMoveReveal] exactly. Independent of the
  /// main-phase action — a player may cast a spell AND melee the same turn.
  Future<Uint8List> exchangeMeleeCommit(Uint8List ourCommit);
  Future<Uint8List> exchangeMeleeReveal(Uint8List ourReveal);

  /// Post-resolution free-move commit-reveal: after every spell for the turn
  /// has resolved, each avatar whose barrier burst from damage this turn
  /// (see [WizardAvatar.pendingFreeMoveBurst]) may commit an optional
  /// single-tile reactive step to an adjacent free tile. Shape mirrors
  /// [exchangeMeleeCommit]/[exchangeMeleeReveal] exactly; sent uniformly by
  /// both sides regardless of whether either avatar actually earned one.
  Future<Uint8List> exchangeFreeMoveCommit(Uint8List ourCommit);
  Future<Uint8List> exchangeFreeMoveReveal(Uint8List ourReveal);

  /// Divination (Air-Water) scrying pattern (MESH_ARCHITECTURE.md §13b).
  ///
  /// Always called once per turn regardless of whether either side has an
  /// active scry link this turn (uniform slot; content is conditional —
  /// [0x00] means "no active outgoing scry"). [ourFrame] carries a fresh,
  /// single-use X25519 public key when the local player is scrying the peer
  /// this turn.
  Future<Uint8List> exchangeScryKey(Uint8List ourFrame);

  /// The reply half of the scrying pattern: an AEAD-encrypted opening of the
  /// local player's committed spell-target leaf, addressed to the peer's
  /// [exchangeScryKey] public key, when the peer is scrying the local player
  /// this turn. [0x00] means "no active incoming scry to open."
  Future<Uint8List> exchangeScryOpen(Uint8List ourFrame);

  /// Divination (Water flavor — Watery Scrying Pool) spell-list reveal.
  /// Same shape and uniform-slot rule as [exchangeScryKey]/[exchangeScryOpen],
  /// kept as an independent exchange so simultaneous Air + Water links to the
  /// same peer never share a payload format.
  Future<Uint8List> exchangeSpellRevealKey(Uint8List ourFrame);

  /// The reply half: an AEAD-encrypted JSON spell list, addressed to the
  /// peer's [exchangeSpellRevealKey] public key, when the peer is scrying the
  /// local player's spell list this turn. [0x00] means "no active incoming
  /// reveal to open."
  Future<Uint8List> exchangeSpellRevealOpen(Uint8List ourFrame);

  /// Forced reveal-and-cast (docs/WILD_MAGIC_PLAN.md §9.5): each side sends
  /// the spells (with proofs and Merkle paths) for the hand slots that were
  /// publicly selected out of its own hand, and receives the peer's.
  ///
  /// **Not a uniform per-turn slot** — unlike the scry exchanges, this is sent
  /// only on turns where a forced cast actually fires. Both clients derive the
  /// triggering wild magic from the same certified proof outputs, so they
  /// always reach this call together or not at all.
  ///
  /// Returns null when there is no peer (solo/practice), so the caller
  /// resolves only local picks rather than awaiting a reveal that will never
  /// arrive.
  Future<Uint8List?> exchangeForcedReveal(Uint8List ourFrame);

  /// Request a fresh commit-reveal entropy exchange during spell resolution.
  ///
  /// For interactive effects where foreknowledge of pseudo-random outcomes
  /// could influence a player choice. Both clients MUST call this at the same
  /// deterministic point in the resolution sequence (the effect table
  /// hard-codes when). [reason] is a logging tag; it is not transmitted.
  ///
  /// Not yet called by any effect — this is the seam for future interactive
  /// spells. A modified client that refuses this exchange forfeits the match.
  Future<Uint8List> refreshEntropy(String reason);

  /// Announces that the local player has finished performing this turn's
  /// spell components and locked their action in — the sequential-casting
  /// pacing signal (docs/SPELL_COMPONENTS_PLAN.md §5.3).
  ///
  /// Fire-and-forget, never awaited, and information-free: it says only "I am
  /// done," which everyone in the room can already hear. Safe to call in
  /// simultaneous mode too (nobody is listening for it), and safe to call
  /// more than once for a turn.
  ///
  /// Default: a no-op, for the implementations with no peer to tell.
  void sendComponentsDone(int turnNumber) {}

  /// Completes once the peer has signalled [sendComponentsDone] for
  /// [turnNumber].
  ///
  /// **Latched, not streamed.** A signal that arrived before this was called
  /// still satisfies it — a live broadcast would drop a fast peer's signal
  /// and hang the waiting player's controls for the rest of the turn.
  ///
  /// Default: completes immediately. That is the right answer for every
  /// peerless implementation (solo, practice, test doubles): a target dummy
  /// performs no components, so nobody ever waits on it.
  Future<void> peerComponentsDone(int turnNumber) async {}

  void sendForfeit(String reason);

  /// Completes with the peer's forfeit reason the moment they send a
  /// [BattleMsgType.forfeit] frame — the receive side of [sendForfeit].
  ///
  /// Every forfeit condition in the engine is one-sided by construction: the
  /// device that detects it throws out of `runTurn` and stops, while the peer
  /// (which sees nothing wrong) sits waiting for the next frame of whatever
  /// exchange came next. Until this existed the forfeit frame was written and
  /// never read by anything, so that peer simply hung — the "desync" a real
  /// LAN test shows as one dead device and one live one.
  ///
  /// Default: a future that never completes, for the implementations with no
  /// peer to hear from (solo/practice, test doubles). Only [BattleSession]
  /// overrides it.
  Future<String> get peerForfeit => Completer<String>().future;

  /// Completes when the peer's connection drops without a forfeit — the
  /// socket closed, or the read stream errored.
  ///
  /// [peerForfeit] only covers the case where the peer's device is alive,
  /// noticed a problem, and had time to say so. It cannot cover the far more
  /// ordinary way a duel dies in the field: the app is backgrounded, the
  /// screen locks long enough for the TCP connection to reset, the phone
  /// walks out of Wi-Fi range, or the process is killed. No forfeit frame is
  /// ever sent in any of those, so without this the surviving device sits
  /// blocked on an exchange whose answer is never coming — no error, no
  /// message, no way out but force-quitting. Exactly the "one dead device and
  /// one live one" shape [peerForfeit] was added to fix, arriving through the
  /// other door.
  ///
  /// Completes with a short human-readable reason, for the same purpose as
  /// [peerForfeit]'s: the player is owed a sentence about why their duel
  /// stopped.
  ///
  /// Default: a future that never completes, for the implementations with no
  /// peer whose connection could drop (solo/practice, test doubles). Only
  /// [BattleSession] overrides it.
  Future<String> get peerConnectionLost => Completer<String>().future;

  /// Releases the session and whatever it sits on. Called when the battle
  /// screen goes away, however it goes away — a finished duel, the "leave
  /// battle" button, or the route being popped.
  ///
  /// Default: a no-op, correct for every peerless implementation. Only
  /// [BattleSession] has anything to release.
  Future<void> close() async {}
}

// ── Network session ───────────────────────────────────────────────────────────

class BattleSession implements BattleTurnSession {
  BattleSession(this._transport, this.matchId) {
    _reader = BattleFrameReader();
    // onDone/onError are the only notice this layer ever gets that the peer
    // is gone when they did not forfeit — see [peerConnectionLost]. Note
    // [close] *cancels* this subscription, and cancelling never fires
    // onDone, so tearing down our own session at match end cannot raise a
    // false alarm.
    _sub = _transport.onReceive.listen(
      _reader.addChunk,
      onDone: () => _noteConnectionLost('the connection closed'),
      onError: (Object e) => _noteConnectionLost('$e'),
      cancelOnError: false,
    );
    // Pumped from the constructor so no componentsDone frame can arrive
    // before something is watching for it. This is the whole reason the
    // signal is latched rather than streamed — see [peerComponentsDone].
    _pumpComponentsDone();
  }

  final Transport _transport;
  final Uint8List matchId;
  late final BattleFrameReader _reader;
  late final StreamSubscription<List<int>> _sub;

  /// See [BattleTurnSession.peerForfeit]. Safe to register lazily (on first
  /// read) even though a forfeit can arrive at any moment — including during
  /// the handshake, long before the battle screen subscribes:
  /// [BattleFrameReader.framesOfType] is queue-backed, so a frame that
  /// arrives with no listener yet is held in `_pendingByType` and handed to
  /// this listener when it registers, rather than dropped the way a bare
  /// broadcast `.where()` would.
  @override
  late final Future<String> peerForfeit = framesOfType(BattleMsgType.forfeit)
      .first
      .then((frame) => utf8.decode(frame.payload));

  /// See [BattleTurnSession.peerConnectionLost]. Eagerly created (not
  /// `late`), because the drop it reports can happen before anything reads
  /// the future — a lazily-built completer would miss it.
  final Completer<String> _connectionLost = Completer<String>();

  @override
  Future<String> get peerConnectionLost => _connectionLost.future;

  /// Records the drop, once. Guarded because onError-then-onDone is a normal
  /// socket teardown sequence, and completing twice throws.
  void _noteConnectionLost(String reason) {
    if (_connectionLost.isCompleted) return;
    _connectionLost.complete(reason);
    // Release anyone blocked on the sequential-components gate. Their signal
    // rides the same dead socket, so waiting on it now means waiting forever;
    // the screen is about to show the connection-lost error over the top
    // regardless. Without this the trailing player's controls stay locked
    // even after they know the duel is over.
    for (final waiter in _componentsDoneWaiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _componentsDoneWaiters.clear();
  }

  /// All incoming battle frames, broadcast. Only used directly by
  /// [exchangeMatchConfig]'s ack/reject dual-type wait — everything else
  /// should use [framesOfType].
  Stream<BattleFrame> get frames => _reader.frames;

  // ── Stall diagnostics ───────────────────────────────────────────────────────
  //
  // Every exchange is "send ours, await theirs". If the peer never sends its
  // half, that await never completes, `runTurn` never returns, and the battle
  // screen sits with `_isBusy` true — a frozen board with no error, which is
  // exactly what a playtest reported. These two fields name which frame the
  // device is waiting for so the freeze can be identified from a screenshot
  // instead of guessed at.
  //
  // Single-slot on purpose: the artifact-entropy exchange for the NEXT turn is
  // deliberately started (unawaited) while the current turn is still settling,
  // so two waits can briefly overlap and the later one wins. That is fine for a
  // diagnostic — it reports the most recent wait, not a full stack.

  String? _pendingExchange;
  DateTime? _pendingSince;

  /// Name of the frame this device has been waiting on for longer than
  /// [_kStallThreshold], or null if nothing is overdue.
  ///
  /// Read by the battle screen to replace a silent frozen board with a
  /// "waiting for opponent" banner naming the stuck exchange.
  ///
  /// Deliberately NOT on [BattleTurnSession]: that interface is `implements`-ed
  /// (not extended) by every test double and by [SoloBattleSession], so adding
  /// a member there forces a stub into each of them for a field only a real
  /// network session can ever populate.
  String? get stalledExchange {
    final label = _pendingExchange;
    final since = _pendingSince;
    if (label == null || since == null) return null;
    return DateTime.now().difference(since) >= _kStallThreshold ? label : null;
  }

  static const _kStallThreshold = Duration(seconds: 8);

  /// [framesOfType].first, wrapped so the wait is visible to [stalledExchange].
  Future<BattleFrame> _awaitFrame(BattleMsgType type) {
    final label = type.name;
    _pendingExchange = label;
    _pendingSince = DateTime.now();
    return framesOfType(type).first.whenComplete(() {
      // Guarded: a longer-running overlapping wait must not have its marker
      // cleared by this one finishing first.
      if (_pendingExchange == label) {
        _pendingExchange = null;
        _pendingSince = null;
      }
    });
  }

  /// The next frame of exactly [type] — buffers if it already arrived, never
  /// drops it. See [BattleFrameReader.framesOfType]'s doc comment for why
  /// this isn't a `.where()` filter over [frames].
  Stream<BattleFrame> framesOfType(BattleMsgType type) => _reader.framesOfType(type);

  void send(BattleMsgType type, Uint8List payload) {
    _transport.send(BattleFrame(type, payload).encode());
  }

  // ── Identity authentication (BATTLE_AUTH_PLAN.md §3) ────────────────────────

  /// Mutual Ed25519 challenge-response: each side signs the *peer's* fresh
  /// nonce and presents its raw public key, proving both freshness (the
  /// verifier chose the nonce, so a captured signature can't be replayed from
  /// a prior session) and possession (only the private-key holder can sign).
  /// The presented raw key is then hashed via
  /// [Identity.ownerPubkeyHexFromRawKey] to bind it to the circuit-facing
  /// owner_pubkey that spell proofs declare — this is what proof verification
  /// alone cannot do (CLAUDE.md invariant 5: the circuit never proves key
  /// possession).
  ///
  /// Forfeits and throws on: an invalid signature (forged, wrong nonce, or a
  /// raw key that doesn't match what was signed) or the peer presenting our
  /// own identity (self/reflection).
  @override
  Future<AuthenticatedPeer> exchangeIdentityAuth({
    required Identity localIdentity,
    required Uint8List matchId,
  }) async {
    final nonceLocal = CommitRevealEntropy.generateNonce();
    send(BattleMsgType.authChallenge, nonceLocal);
    final noncePeer = (await _awaitFrame(BattleMsgType.authChallenge)).payload;

    final tag = utf8.encode(kIdentityAuthSignatureTag);
    final ourSig = await localIdentity.sign([...tag, ...matchId, ...noncePeer]);
    send(
      BattleMsgType.authResponse,
      Uint8List.fromList([...localIdentity.publicKeyBytes, ...ourSig]),
    );
    final responsePayload =
        (await _awaitFrame(BattleMsgType.authResponse)).payload;
    if (responsePayload.length < 32 + 64) {
      sendForfeit('auth_malformed_response');
      throw StateError('peer auth response too short — match forfeit');
    }
    final peerRawPubkey = responsePayload.sublist(0, 32);
    final peerSig = responsePayload.sublist(32, 96);

    final sigOk = await Identity.verify(
      message: [...tag, ...matchId, ...nonceLocal],
      signatureBytes: peerSig,
      publicKeyBytes: peerRawPubkey,
    );
    if (!sigOk) {
      sendForfeit('auth_failed');
      throw StateError('peer identity signature invalid — match forfeit');
    }

    final peerOwnerPubkeyHex =
        await Identity.ownerPubkeyHexFromRawKey(peerRawPubkey);
    final myOwnerPubkeyHex = await localIdentity.ownerPubkeyHex();
    if (_hexEq(peerOwnerPubkeyHex, myOwnerPubkeyHex)) {
      sendForfeit('auth_self');
      throw StateError('peer presented our own identity — match forfeit');
    }

    return AuthenticatedPeer(
      rawPubkey: Uint8List.fromList(peerRawPubkey),
      ownerPubkeyHex: peerOwnerPubkeyHex,
    );
  }

  /// Exchanges signed [SpellPermission] grants (BATTLE_AUTH_PLAN.md §5).
  /// [ours] should be the local grants naming the peer as grantee. The
  /// returned list is filtered to only permissions that are currently usable
  /// (valid signature, not expired) AND name [peerOwnerPubkeyHex] as grantee —
  /// a permission that fails either check is silently dropped, not trusted.
  @override
  Future<List<SpellPermission>> exchangeSpellPermissions(
    List<SpellPermission> ours, {
    required String peerOwnerPubkeyHex,
  }) async {
    final payload = Uint8List.fromList(
      utf8.encode(jsonEncode(ours.map((p) => p.toJson()).toList())),
    );
    send(BattleMsgType.spellPermissions, payload);
    final frame = await _awaitFrame(BattleMsgType.spellPermissions);
    final decoded = jsonDecode(utf8.decode(frame.payload)) as List<dynamic>;
    final received = decoded
        .map((j) => SpellPermission.fromJson(j as Map<String, dynamic>))
        .toList();

    final verified = <SpellPermission>[];
    for (final perm in received) {
      if (!_hexEq(perm.granteePubkeyHex, peerOwnerPubkeyHex)) continue;
      if (!await perm.isCurrentlyUsable()) continue;
      verified.add(perm);
    }
    return verified;
  }

  // ── Setup exchanges ─────────────────────────────────────────────────────────

  /// Symmetric matchId establishment (LAN_BATTLE_WIREUP_PLAN.md §3.2 step 1;
  /// DECISION 1). Both sides exchange a fresh 16-byte nonce, then each
  /// independently derives `matchId = SHA-256(sorted(ourNonce, theirNonce))[0:16]`
  /// — neither side unilaterally controls it, and both compute the same value
  /// regardless of arrival order (sorted by byte value before concatenating).
  ///
  /// Must be called on `this` session before [matchId] is meaningfully used
  /// elsewhere (e.g. [exchangeIdentityAuth]'s `matchId` parameter) — this
  /// session is typically constructed with a placeholder `matchId` (e.g. 16
  /// zero bytes) specifically so this exchange can run over its one
  /// persistent frame reader before the real value is known. The `matchId`
  /// this returns should be threaded through as an explicit parameter to
  /// every subsequent call that needs it (`this.matchId` stays the
  /// placeholder — it is inert plumbing, read by nothing internal to this
  /// class).
  Future<Uint8List> exchangeMatchIdNonce(Uint8List ourNonce) async {
    send(BattleMsgType.matchIdNonce, ourNonce);
    final frame = await _awaitFrame(BattleMsgType.matchIdNonce);
    return frame.payload;
  }

  /// Both sides send capabilities simultaneously; we return what we received.
  ///
  /// The lobby uses the peer's [DeviceCapabilities.ramTierCap] to gate
  /// tier-48 in [MatchConfig.tier] negotiation.
  Future<DeviceCapabilities> exchangeCapabilities(DeviceCapabilities ours) async {
    send(BattleMsgType.capabilities, Uint8List.fromList(utf8.encode(jsonEncode(ours.toJson()))));
    final frame = await _awaitFrame(BattleMsgType.capabilities);
    return DeviceCapabilities.fromJson(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>);
  }

  /// Both sides send their [MatchConfig] simultaneously; returns the peer's
  /// config on agreement, null on mismatch (caller should abort the session).
  ///
  /// Agreement check is real (field-by-field comparison); conflict-resolution
  /// UI is out of scope for this pass.
  Future<MatchConfig?> exchangeMatchConfig(MatchConfig ours) async {
    send(BattleMsgType.matchConfig, Uint8List.fromList(utf8.encode(jsonEncode(ours.toJson()))));
    final frame = await _awaitFrame(BattleMsgType.matchConfig);
    final theirs = MatchConfig.fromJson(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>);

    if (!ours.matches(theirs)) {
      send(BattleMsgType.matchConfigReject, Uint8List.fromList(utf8.encode('config mismatch')));
      // TODO(battle): surface conflict-resolution UI; for now abort.
      return null;
    }
    send(BattleMsgType.matchConfigAck, Uint8List(0));
    // Wait for their ack or reject — filter the broadcast stream for either type.
    final ack = await frames
        .where((f) => f.type == BattleMsgType.matchConfigAck || f.type == BattleMsgType.matchConfigReject)
        .first;
    if (ack.type == BattleMsgType.matchConfigReject) return null;
    return theirs;
  }

  /// Host-authoritative variant of [exchangeMatchConfig] (DECISION 3,
  /// LAN_BATTLE_WIREUP_PLAN.md §2): the host authors [config] and the guest
  /// has no separate opinion to assert, so there is nothing to compare — the
  /// guest simply adopts what it receives via [receiveHostMatchConfig].
  /// [exchangeMatchConfig]'s strict mutual-equality check can't express this
  /// (both sides would need to already know the same value *before* the one
  /// round trip that's supposed to convey it); this pair sidesteps that by
  /// only ever having one side originate the value. Reuses the existing
  /// `matchConfig`/`matchConfigAck` wire types — call this from the host,
  /// [receiveHostMatchConfig] from the guest.
  Future<void> sendHostMatchConfig(MatchConfig config) async {
    send(BattleMsgType.matchConfig, Uint8List.fromList(utf8.encode(jsonEncode(config.toJson()))));
    await _awaitFrame(BattleMsgType.matchConfigAck);
  }

  /// See [sendHostMatchConfig]. Call from the guest.
  Future<MatchConfig> receiveHostMatchConfig() async {
    final frame = await _awaitFrame(BattleMsgType.matchConfig);
    final config = MatchConfig.fromJson(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>);
    send(BattleMsgType.matchConfigAck, Uint8List(0));
    return config;
  }

  /// Both sides send their player-chosen wizard name simultaneously.
  /// Unauthenticated — presentation only (battle_screen.dart's status panel
  /// and HUD chip), never fed into cast authorization or the state-hash
  /// lockstep. Returns the peer's name, or '' if they haven't set one.
  Future<String> exchangeWizardName(String ours) async {
    send(BattleMsgType.wizardName, Uint8List.fromList(utf8.encode(ours)));
    final frame = await _awaitFrame(BattleMsgType.wizardName);
    return utf8.decode(frame.payload);
  }

  /// Both sides send their player-chosen avatar id simultaneously.
  /// Unauthenticated — presentation only (which sprite the wizard wears on
  /// the battlefield), never fed into cast authorization or the state-hash
  /// lockstep. Returns the peer's avatar id, or '' if they haven't chosen
  /// one. Copies [exchangeWizardName]'s shape verbatim (send first, then
  /// await the frame) — this repo has already been bitten by a broadcast
  /// stream frame being dropped when a listener attached after the send.
  Future<String> exchangeAvatarId(String ours) async {
    send(BattleMsgType.avatarId, Uint8List.fromList(utf8.encode(ours)));
    final frame = await _awaitFrame(BattleMsgType.avatarId);
    return utf8.decode(frame.payload);
  }

  /// Both sides send their Chapter Merkle root simultaneously.
  /// Returns the peer's root bytes (32 bytes).
  Future<Uint8List> exchangeBookCommitment(Uint8List ourRoot) async {
    send(BattleMsgType.bookCommit, ourRoot);
    final frame = await _awaitFrame(BattleMsgType.bookCommit);
    return frame.payload;
  }

  /// Both sides send their batch leaf hash simultaneously (Option 2).
  ///
  /// [ourHash] is [BookCommitment.hashLeaves] over the local chapter's sorted
  /// commitmentHex values. Returns the peer's 32-byte hash; store it for
  /// verification at [exchangeBookReveal].
  Future<Uint8List> exchangeBookHash(Uint8List ourHash) async {
    send(BattleMsgType.bookHash, ourHash);
    final frame = await _awaitFrame(BattleMsgType.bookHash);
    return frame.payload;
  }

  /// Both sides declare their chapter's leaf count simultaneously
  /// (SPELL_DRAW_WIRING_PLAN.md §3). Minor disclosure (how many spells are in
  /// the chapter) — needed publicly so DrawSchedule can compute
  /// `nextInt(leafCount)` for the *peer's* chapter without ever learning its
  /// contents (only the Merkle root of which is committed via
  /// [exchangeBookCommitment]). Returns the peer's leaf count.
  Future<int> exchangeBookLeafCount(int ourCount) async {
    final payload = ByteData(4)..setUint32(0, ourCount, Endian.big);
    send(BattleMsgType.bookLeafCount, payload.buffer.asUint8List());
    final frame = await _awaitFrame(BattleMsgType.bookLeafCount);
    return ByteData.sublistView(frame.payload).getUint32(0, Endian.big);
  }

  /// Both sides send their Chapter's public artifact loadout simultaneously
  /// (LAN_BATTLE_WIREUP_PLAN.md §3.1/§3.2 step 8). Required — not optional
  /// hardening — because `BattleState.toCanonicalBytes()` hashes each
  /// avatar's full accoutrement list and its mana-gem-derived maxMana/mana;
  /// a peer avatar built from any other loadout diverges the state-hash
  /// lockstep on the very first turn. Unlike the Chapter's *spells* (kept
  /// secret behind [exchangeBookCommitment]'s Merkle root), artifact loadout
  /// is public equipment — safe to exchange in the clear.
  Future<List<ArtifactEntry>> exchangeArtifactLoadout(List<ArtifactEntry> ours) async {
    final payload = Uint8List.fromList(
      utf8.encode(jsonEncode(ours.map((a) => a.toJson()).toList())),
    );
    send(BattleMsgType.artifactLoadout, payload);
    final frame = await _awaitFrame(BattleMsgType.artifactLoadout);
    final decoded = jsonDecode(utf8.decode(frame.payload)) as List<dynamic>;
    return decoded
        .map((j) => ArtifactEntry.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Post-match: both sides reveal their sorted KIN-STACKING LEAF list
  /// simultaneously, so each can check the other's book for internal
  /// duplicates.
  ///
  /// The leaves are salted behavioural-kinship hashes (spell_identity.dart's
  /// `kinStackingLeaves`), not grid commitments. Two changes at once, both
  /// improvements (docs/COUNTER_CHARM_KINSHIP_PLAN.md §3.5):
  ///
  ///   * Kinship is behavioural now, so the duplicate check has to run over
  ///     kin keys or it stops detecting what it exists to detect — a player
  ///     carrying two "different" spells that do the same thing.
  ///   * The old form revealed a stable, unsalted identifier for every spell
  ///     in your book, including ones you never cast, usable to recognise
  ///     that spell in any future match. Revealing raw trajectories would be
  ///     worse still — a trajectory says what a spell DOES. A fresh per-match
  ///     salt keeps duplicates colliding while leaking neither.
  ///
  /// The salt is per-player, never transmitted, and never needed by the
  /// receiver: this check only ever compares entries within ONE player's own
  /// list.
  ///
  /// The chapter Merkle root ([exchangeBookCommitment]) deliberately does NOT
  /// move with this. That tree is per-spell membership — it authenticates
  /// which card was cast from which hand slot — and membership needs a
  /// one-to-one identity, which behavioural kinship is not.
  ///
  /// [ourSortedLeaves] must be sorted, matching the order
  /// [BookCommitment.hashLeaves] was given at [exchangeBookHash].
  /// [expectedPeerHash] is the hash received during [exchangeBookHash].
  ///
  /// Returns the peer's verified leaf list, or null if:
  ///   - The peer's revealed list's SHA-256 does not match [expectedPeerHash].
  ///   - The list contains duplicate leaves (Kin-stacking).
  ///
  /// Both sends happen simultaneously before verification so neither side can
  /// withhold based on the other's reveal.
  Future<List<String>?> exchangeBookReveal(
    List<String> ourSortedLeaves, {
    required Uint8List expectedPeerHash,
  }) async {
    final payload = Uint8List.fromList(
      utf8.encode(jsonEncode(ourSortedLeaves)),
    );
    send(BattleMsgType.bookReveal, payload);
    final frame = await _awaitFrame(BattleMsgType.bookReveal);
    final theirLeaves =
        (jsonDecode(utf8.decode(frame.payload)) as List<dynamic>).cast<String>();

    // Verify hash matches the commitment made at session start.
    final actualHash = BookCommitment.hashLeaves(theirLeaves);
    if (!_constantTimeEqual(actualHash, expectedPeerHash)) return null;

    // Verify no duplicate kin keys (Kin-stacking detection). A kinship-exempt
    // spell contributed a random leaf and so can never trip this — that is
    // the ≥9-element exemption (§2.6/§3.4) made concrete.
    final seen = <String>{};
    for (final leaf in theirLeaves) {
      if (!seen.add(leaf)) return null;
    }

    return theirLeaves;
  }

  static bool _constantTimeEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ── Per-turn commit-reveal ──────────────────────────────────────────────────

  /// Commit-reveal entropy exchange (BATTLE_PROTOCOL.md §3).
  ///
  /// Both sides commit simultaneously, then reveal simultaneously. Returns
  /// `(theirNonce, theirCommit)` so the caller can verify via
  /// [CommitRevealEntropy.revealAndCombine] and detect withheld reveals.
  @override
  Future<({Uint8List theirNonce, Uint8List theirCommit})> exchangeNonce({
    required Uint8List ourCommit,
    required Uint8List ourNonce,
  }) async {
    // Commit phase — both send simultaneously.
    send(BattleMsgType.nonceCommit, ourCommit);
    final theirCommitFrame = await _awaitFrame(BattleMsgType.nonceCommit);
    final theirCommit = theirCommitFrame.payload;

    // Reveal phase.
    send(BattleMsgType.nonceReveal, ourNonce);
    final theirRevealFrame = await _awaitFrame(BattleMsgType.nonceReveal);
    return (theirNonce: theirRevealFrame.payload, theirCommit: theirCommit);
  }

  // ── Per-turn movement ───────────────────────────────────────────────────────

  @override
  Future<Uint8List> exchangeMoveCommit(Uint8List ourCommit) async {
    send(BattleMsgType.moveCommit, ourCommit);
    final frame = await _awaitFrame(BattleMsgType.moveCommit);
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeMoveReveal(Uint8List ourReveal) async {
    send(BattleMsgType.moveReveal, ourReveal);
    final frame = await _awaitFrame(BattleMsgType.moveReveal);
    return frame.payload;
  }

  // ── Phase 0 artifact-activation commit-reveal ───────────────────────────────

  @override
  Future<Uint8List> exchangeArtifactActivationCommit(Uint8List ourCommit) async {
    send(BattleMsgType.artifactCommit, ourCommit);
    final frame = await _awaitFrame(BattleMsgType.artifactCommit);
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeArtifactActivationReveal(Uint8List ourReveal) async {
    send(BattleMsgType.artifactReveal, ourReveal);
    final frame = await _awaitFrame(BattleMsgType.artifactReveal);
    return frame.payload;
  }

  // ── Resolution-phase melee commit-reveal ────────────────────────────────────

  @override
  Future<Uint8List> exchangeMeleeCommit(Uint8List ourCommit) async {
    send(BattleMsgType.meleeCommit, ourCommit);
    final frame = await _awaitFrame(BattleMsgType.meleeCommit);
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeMeleeReveal(Uint8List ourReveal) async {
    send(BattleMsgType.meleeReveal, ourReveal);
    final frame = await _awaitFrame(BattleMsgType.meleeReveal);
    return frame.payload;
  }

  // ── Post-resolution free-move commit-reveal ─────────────────────────────────

  @override
  Future<Uint8List> exchangeFreeMoveCommit(Uint8List ourCommit) async {
    send(BattleMsgType.freeMoveCommit, ourCommit);
    final frame = await _awaitFrame(BattleMsgType.freeMoveCommit);
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeFreeMoveReveal(Uint8List ourReveal) async {
    send(BattleMsgType.freeMoveReveal, ourReveal);
    final frame = await _awaitFrame(BattleMsgType.freeMoveReveal);
    return frame.payload;
  }

  // ── Per-turn action commit-reveal ──────────────────────────────────────────

  /// Both sides commit their action (spell / haymaker / pass) simultaneously.
  /// Returns the peer's action commit (32-byte SHA-256 hash).
  @override
  Future<Uint8List> exchangeActionCommit(Uint8List ourCommit) async {
    send(BattleMsgType.actionCommit, ourCommit);
    final frame = await _awaitFrame(BattleMsgType.actionCommit);
    return frame.payload;
  }

  /// Both sides reveal their action (nonce ‖ action_bytes) simultaneously.
  /// Caller verifies SHA-256(action_bytes ‖ nonce) == received commit.
  @override
  Future<Uint8List> exchangeActionReveal(Uint8List ourReveal) async {
    send(BattleMsgType.actionReveal, ourReveal);
    final frame = await _awaitFrame(BattleMsgType.actionReveal);
    return frame.payload;
  }

  /// Both sides simultaneously declare any pending delayed spells firing this
  /// turn. Payload format: [count:1][commitment:32, q:2, r:2, delay:1, nonce:16
  /// per spell]. Send [0x00] if nothing fires this turn.
  @override
  Future<Uint8List> exchangeDelayedSpellReveals(Uint8List ourReveals) async {
    send(BattleMsgType.delayedSpellReveal, ourReveals);
    final frame = await _awaitFrame(BattleMsgType.delayedSpellReveal);
    return frame.payload;
  }

  // ── Divination scrying pattern (§13b) ──────────────────────────────────────

  @override
  Future<Uint8List> exchangeScryKey(Uint8List ourFrame) async {
    send(BattleMsgType.scryKey, ourFrame);
    final frame = await _awaitFrame(BattleMsgType.scryKey);
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeScryOpen(Uint8List ourFrame) async {
    send(BattleMsgType.scryOpen, ourFrame);
    final frame = await _awaitFrame(BattleMsgType.scryOpen);
    return frame.payload;
  }

  // ── Divination (Water) spell-list reveal ───────────────────────────────────

  @override
  Future<Uint8List> exchangeSpellRevealKey(Uint8List ourFrame) async {
    send(BattleMsgType.spellRevealKey, ourFrame);
    final frame = await _awaitFrame(BattleMsgType.spellRevealKey);
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeSpellRevealOpen(Uint8List ourFrame) async {
    send(BattleMsgType.spellRevealOpen, ourFrame);
    final frame = await _awaitFrame(BattleMsgType.spellRevealOpen);
    return frame.payload;
  }

  @override
  Future<Uint8List?> exchangeForcedReveal(Uint8List ourFrame) async {
    send(BattleMsgType.forcedReveal, ourFrame);
    final frame = await _awaitFrame(BattleMsgType.forcedReveal);
    return frame.payload;
  }

  // ── Mid-resolution entropy refresh ─────────────────────────────────────────

  @override
  Future<Uint8List> refreshEntropy(String reason) async {
    final ourNonce = CommitRevealEntropy.generateNonce();
    final ourCommit = await CommitRevealEntropy.commit(ourNonce);

    // Commit phase — simultaneous, same protocol as turn-start nonce exchange.
    send(BattleMsgType.refreshEntropyCommit, ourCommit);
    final theirCommitFrame = await _awaitFrame(BattleMsgType.refreshEntropyCommit);

    // Reveal phase.
    send(BattleMsgType.refreshEntropyReveal, ourNonce);
    final theirRevealFrame = await _awaitFrame(BattleMsgType.refreshEntropyReveal);

    final jointEntropy = await CommitRevealEntropy.revealAndCombine(
      ourNonce: ourNonce,
      theirNonce: theirRevealFrame.payload,
      theirCommit: theirCommitFrame.payload,
    );
    if (jointEntropy == null) {
      sendForfeit('withheld_refresh_reveal:$reason');
      throw StateError('peer withheld entropy refresh ($reason) — match forfeit');
    }
    return jointEntropy;
  }

  // ── Per-turn state hash (lockstep seam) ─────────────────────────────────────

  /// Send our state hash and receive the peer's; returns peer hash.
  ///
  /// Signing is stubbed — the hash exchange is real. See BATTLE_PROTOCOL.md §6.
  @override
  Future<Uint8List> exchangeStateHash(Uint8List ourHash) async {
    // TODO(battle): prepend Ed25519 signature to ourHash before sending;
    //   depends on identity module (lib/identity/identity.dart).
    send(BattleMsgType.stateHash, ourHash);
    final frame = await _awaitFrame(BattleMsgType.stateHash);
    return frame.payload;
  }

  // ── Sequential-casting pacing (SPELL_COMPONENTS_PLAN.md §5.3) ───────────────

  /// Turn numbers the peer has already signalled. A set, not a "latest turn"
  /// int, because the signal is not part of the lockstep sequence: it is sent
  /// once per player per turn and never awaited by the engine, so there is no
  /// exchange keeping the two sides' turn counters in step at the moment it
  /// arrives. Recording exactly which turns were signalled means an early or
  /// duplicate frame can never satisfy the wrong turn's wait.
  final Set<int> _peerComponentsDoneTurns = {};

  /// Waiters registered by [peerComponentsDone] before their turn's frame
  /// arrived, keyed by turn number.
  final Map<int, Completer<void>> _componentsDoneWaiters = {};

  /// Re-subscribes after every frame: [framesOfType] hands back a
  /// single-element stream that closes, so a continuous listener has to
  /// re-arm itself. Runs for the life of the session.
  ///
  /// This pump CLAIMS every [BattleMsgType.componentsDone] frame —
  /// [BattleFrameReader] delivers each frame to exactly one waiter — so
  /// [peerComponentsDone] is the only way to observe the signal. Anything
  /// else calling `framesOfType(componentsDone)` would simply wait forever.
  void _pumpComponentsDone() {
    framesOfType(BattleMsgType.componentsDone).first.then((frame) {
      if (frame.payload.length >= 4) {
        final turn = ByteData.sublistView(frame.payload, 0, 4)
            .getUint32(0, Endian.big);
        _peerComponentsDoneTurns.add(turn);
        _componentsDoneWaiters.remove(turn)?.complete();
      }
      _pumpComponentsDone();
    }).catchError((_) {
      // Transport closed (match over, peer gone). Stop re-arming; anyone
      // still waiting is released by the forfeit/match-end path instead.
    });
  }

  @override
  void sendComponentsDone(int turnNumber) {
    final payload = Uint8List(4);
    ByteData.sublistView(payload).setUint32(0, turnNumber, Endian.big);
    send(BattleMsgType.componentsDone, payload);
  }

  @override
  Future<void> peerComponentsDone(int turnNumber) {
    if (_peerComponentsDoneTurns.contains(turnNumber)) return Future.value();
    return (_componentsDoneWaiters[turnNumber] ??= Completer<void>()).future;
  }

  // ── Match control ───────────────────────────────────────────────────────────

  @override
  void sendForfeit(String reason) =>
      send(BattleMsgType.forfeit, Uint8List.fromList(utf8.encode(reason)));


  void sendMatchEnd({required String winningTeamId, required String finalStateHashHex}) {
    final body = jsonEncode({'winningTeamId': winningTeamId, 'finalStateHash': finalStateHashHex});
    send(BattleMsgType.matchEnd, Uint8List.fromList(utf8.encode(body)));
  }

  /// Exchanges our signed [MatchOutcome] for the peer's (MASTER_APPRENTICE_
  /// PLAN.md §4.2). Both sides send simultaneously — safe because, unlike a
  /// wall-clock timestamp, every field of [mine] is a pure function of
  /// state the per-turn lockstep already agreed on (see [MatchOutcome]'s doc
  /// comment). This method only transports the exchange; the caller is
  /// responsible for validating the returned [SignedMatchOutcome] before
  /// trusting it — at minimum: signature valid, its raw pubkey binds to the
  /// ALREADY-AUTHENTICATED peer identity (from [exchangeIdentityAuth], never
  /// a bare claim here), its `outcome` fields equal [mine]'s, and its
  /// `signerPubkeyHex` names the OTHER party to the match (not our own).
  /// [MatchOutcomeRecord.isFullyValid] checks the signature/party shape of
  /// the combined pair; matching field-for-field against [mine] is the
  /// caller's job since this method has no opinion on what "ours" should be.
  Future<SignedMatchOutcome> exchangeMatchOutcome(SignedMatchOutcome mine) async {
    send(
      BattleMsgType.matchResultSig,
      Uint8List.fromList(utf8.encode(jsonEncode(mine.toJson()))),
    );
    final frame = await _awaitFrame(BattleMsgType.matchResultSig);
    return SignedMatchOutcome.fromJson(
      jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>,
    );
  }

  /// Tears down the session AND the transport under it.
  ///
  /// The transport is disconnected here because this session owns it from the
  /// moment the lobby hands off (see battle_lobby_screen.dart's `_handedOff`),
  /// and because leaving the socket open is what the peer experiences as a
  /// hang: they stay blocked on an exchange from a device that has walked
  /// away but never closed the connection. Closing it is what turns their
  /// silent freeze into [peerConnectionLost].
  @override
  Future<void> close() async {
    await _sub.cancel();
    await _reader.close();
    await _transport.disconnect();
  }
}
