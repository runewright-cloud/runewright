// SPDX-License-Identifier: GPL-3.0-or-later
//
// match_discovery.dart — MatchDiscovery seam over the existing Transport
// and mDNS/LAN discovery stack.
//
// The battle layer talks only to this abstract interface; concrete adapters
// (LanMatchDiscovery below, future BLE) live behind it. Adapter logic is
// never duplicated into game code — transport negotiation happens here.
//
// RAM tier capability (§9 of BATTLE_PROTOCOL.md):
//   DeviceCapabilities.ramTierCap advertises the max circuit tier this device
//   can prove/verify. Detection is stubbed — returns a fixed value; the field
//   and its plumbing are real so the lobby can later gate tier-48 access.
//
// See docs/BATTLE_PROTOCOL.md §9 for player/transport cap rationale.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:nsd/nsd.dart' as nsd;

import '../engine/battle_engine_version.dart'
    show kBattleEngineVersion, kUndeclaredBattleEngineVersion;
import '../../protocol/lan_discovery.dart';
import '../../protocol/lan_socket_transport.dart';
import '../../protocol/transport.dart';

// ── Capability advertisement ──────────────────────────────────────────────────

/// LAN battle wire-protocol version (LAN_BATTLE_WIREUP_PLAN.md §8 / §2
/// DECISION 4 — protocol versioning, same discipline as `RULESET_VERSION`
/// bumps). Exchanged in [exchangeCapabilities]; the setup flow aborts on
/// mismatch rather than risk two builds silently disagreeing about wire
/// framing. Bump whenever a `BattleMsgType`/payload shape changes in a way
/// that breaks an older client.
///
/// v2 (2026-07-30, core-gem removal): `BattleState.toCanonicalBytes()` dropped
/// the per-accoutrement `isCoreGem` byte, and `MatchConfig` gained the
/// negotiated `innateManaPool`. A v1 client omits `innateManaPool` (so config
/// agreement still *passes* against our default) but derives a different
/// `maxMana` and hashes an extra byte per accoutrement — i.e. it would desync
/// on the first state-hash exchange instead of failing the handshake. Aborting
/// at the gate is the whole point.
///
/// v3 (2026-08-03, avatar picker): the setup flow gained an `avatarId` (0x1E)
/// exchange in step 4b. A v2 client never sends it, so a v3 client would
/// block forever on `framesOfType(avatarId).first` — a hang, not a failure.
/// Aborting at the capabilities gate turns that into a legible error.
///
/// v4 (2026-08-04, vocal recall): the sorcerer suffix on a spell action changed
/// from a fixed 3-byte VocalScore to a variable-length IncantationRecall with a
/// trailing length byte. A v3 client would read a v4 recall's bytes as a score
/// and charge wildly wrong mana — a silent desync, which is worse than a
/// refused handshake.
///
/// v5 (2026-08-13, summon replication): a spell action now carries two extra
/// bytes, `[isSummon:1][personalityIndex:1]`, on both the immediate (0x01) and
/// Mystery (0x03) encodings. Before this the fields were never transmitted at
/// all, so a peer's summon arrived as an ordinary incantation: the caster
/// spawned a creature, the opponent spawned nothing, and the match forfeited
/// on that turn's state hash (M4_findings M4.16 — summons were unusable in any
/// real duel). A v4 client would read the two new bytes as the start of the
/// proof tail, so this MUST fail the handshake rather than proceed.
///
/// The personality is a [SummonPersonality] index, which makes that enum's
/// declaration order wire-visible: **append only, never reorder or remove.**
const kBattleProtocolVersion = 5;

/// The max circuit tier (12 / 24 / 48) this device can reliably prove.
///
/// Tier-48 requires ≥6 GB RAM (CIRCUIT_IO.md §7); detection is stubbed —
/// [detect] returns 24 as a safe default until real RAM probing lands.
class DeviceCapabilities {
  const DeviceCapabilities({
    required this.ramTierCap,
    this.battleProtocolVersion = kBattleProtocolVersion,
    this.battleEngineVersion = kBattleEngineVersion,
  });

  final int ramTierCap; // 12 | 24 | 48

  /// See [kBattleProtocolVersion].
  final int battleProtocolVersion;

  /// The deterministic engine epoch this device implements — see
  /// [kBattleEngineVersion]. Declared here, alongside the wire-framing
  /// version, because this is the one exchange in the whole handshake where
  /// both peers state their own build simultaneously: the match config that
  /// follows is host-authored (the guest adopts it), so it can pin what the
  /// match runs under but can never reveal what the *guest* is running.
  ///
  /// Deliberately does NOT bump [battleProtocolVersion]: adding a JSON key an
  /// older client ignores breaks no framing, and conflating "we disagree about
  /// bytes" with "we disagree about rules" would make both numbers unreadable.
  final int battleEngineVersion;

  // TODO(battle): probe actual device RAM; return 48 only on ≥6 GB devices.
  static DeviceCapabilities detect() => const DeviceCapabilities(ramTierCap: 24);

  Map<String, dynamic> toJson() => {
        'ramTierCap': ramTierCap,
        'battleProtocolVersion': battleProtocolVersion,
        'battleEngineVersion': battleEngineVersion,
      };
  static DeviceCapabilities fromJson(Map<String, dynamic> j) => DeviceCapabilities(
        ramTierCap: j['ramTierCap'] as int? ?? 24,
        battleProtocolVersion: j['battleProtocolVersion'] as int? ?? 1,
        // A peer that omits this predates the gate and has declared nothing —
        // never read as agreement. See kUndeclaredBattleEngineVersion.
        battleEngineVersion:
            j['battleEngineVersion'] as int? ?? kUndeclaredBattleEngineVersion,
      );
}

// ── Discovered peer ───────────────────────────────────────────────────────────

/// A peer found during discovery, with a lazily-evaluated connection factory.
///
/// The battle layer never sees the underlying mDNS [Service] — it calls
/// [connect] and gets a [Transport] back, adapter-agnostic.
class DiscoveredPeer {
  DiscoveredPeer({
    required this.displayName,
    required this.capabilities,
    required Future<Transport> Function() connect,
  }) : _connect = connect;

  final String displayName;
  final DeviceCapabilities capabilities;
  final Future<Transport> Function() _connect;

  Future<Transport> connect() => _connect();
}

// ── Abstract seam ─────────────────────────────────────────────────────────────

abstract class MatchDiscovery {
  /// Advertise this device as a duel host with the given [caps].
  ///
  /// Registers an mDNS service and binds a listening socket (LAN adapter).
  /// Call [stopAdvertising] to clean up, or [acceptConnection] to get the
  /// connected [Transport] once a peer dials in.
  Future<void> startAdvertising({
    required DeviceCapabilities caps,
    String displayName = 'Runewright Duel',
  });

  Future<void> stopAdvertising();

  /// Returns a broadcast stream emitting peers as they are discovered.
  ///
  /// Peers can appear, resolve, and disappear; call [stopDiscovering] when
  /// the lobby screen closes.
  Future<Stream<DiscoveredPeer>> startDiscovering();

  Future<void> stopDiscovering();

  /// Accept the first incoming connection from an advertising peer (host role).
  Future<Transport> acceptConnection();
}

// ── LAN adapter ───────────────────────────────────────────────────────────────

/// [MatchDiscovery] over LAN sockets + mDNS, using the existing
/// [LanSocketTransport] / [LanListener] / lan_discovery.dart stack.
///
/// BLE is a future adapter behind the same seam (BATTLE_PROTOCOL.md §9).
class LanMatchDiscovery implements MatchDiscovery {
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  LanListener? _listener;
  final _peerController = StreamController<DiscoveredPeer>.broadcast();

  @override
  Future<void> startAdvertising({
    required DeviceCapabilities caps,
    String displayName = 'Runewright Duel',
  }) async {
    _listener = await LanSocketTransport.bind();
    try {
      _registration = await advertiseDuelHost(
        port: _listener!.port,
        displayName: displayName,
      );
    } catch (e) {
      // Soft failure by design (mirrors gate_screen.dart's connect-path
      // note): `nsd` has no Linux desktop backend at all
      // (lan_discovery.dart's header comment) and mDNS can fail for other
      // reasons on real networks (AP isolation, multicast deprioritized).
      // The listening socket above doesn't depend on it — a peer can still
      // reach this host via manual IP entry (battle_lobby_screen.dart),
      // which dials the same socket directly. Advertise failing must never
      // block hosting.
      debugPrint('mDNS advertise failed (manual IP entry still works): $e');
      _registration = null;
    }
    // TODO(battle): encode caps into mDNS TXT records so discovering peers
    //   can read ramTierCap without connecting; depends on nsd TXT record API.
  }

  @override
  Future<void> stopAdvertising() async {
    if (_registration != null) {
      await stopAdvertisingDuelHost(_registration!);
      _registration = null;
    }
    await _listener?.close();
    _listener = null;
  }

  /// This device's listening port once [startAdvertising] has bound it, for
  /// display alongside [localAddressHint] so a peer can connect via manual
  /// IP entry when mDNS discovery isn't available on their platform/network.
  int? get listeningPort => _listener?.port;

  /// Best-effort local IPv4 address hint for manual-IP display — see
  /// [preferredLocalAddress]. Null if undeterminable; display-only, never
  /// blocks anything.
  Future<String?> localAddressHint() async {
    try {
      final addr = await preferredLocalAddress();
      return addr?.address;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Stream<DiscoveredPeer>> startDiscovering() async {
    _discovery = await discoverDuelHosts();
    _discovery!.addServiceListener((service, status) {
      if (status == nsd.ServiceStatus.found) {
        // TODO(battle): parse ramTierCap from service TXT records once
        //   startAdvertising encodes it; until then assume 24.
        final caps = const DeviceCapabilities(ramTierCap: 24);
        _peerController.add(DiscoveredPeer(
          displayName: service.name ?? 'Unknown Wizard',
          capabilities: caps,
          connect: () => connectToDiscoveredService(service),
        ));
      }
    });
    return _peerController.stream;
  }

  @override
  Future<void> stopDiscovering() async {
    if (_discovery != null) {
      await stopDiscoveringDuelHosts(_discovery!);
      _discovery = null;
    }
  }

  @override
  Future<Transport> acceptConnection() async {
    final listener = _listener;
    if (listener == null) throw StateError('not advertising — call startAdvertising first');
    return listener.acceptOnce();
  }

  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovering();
    await _peerController.close();
  }
}

// ── Solo (no-network) stub ────────────────────────────────────────────────────

/// [MatchDiscovery] for solo mode — bypasses networking entirely.
///
/// Solo mode runs the battle engine against a single local avatar with no
/// peer Transport. [acceptConnection] and [startDiscovering] throw; callers
/// must branch on [MatchConfig.maxPlayers] == 1 before instantiating the
/// session (see BATTLE_PROTOCOL.md §9, solo = 1).
class SoloMatchDiscovery implements MatchDiscovery {
  @override
  Future<void> startAdvertising({required DeviceCapabilities caps, String displayName = ''}) async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<Stream<DiscoveredPeer>> startDiscovering() async => const Stream.empty();

  @override
  Future<void> stopDiscovering() async {}

  @override
  Future<Transport> acceptConnection() =>
      throw UnsupportedError('solo mode has no peer transport');
}

/// A fake [Transport] that loopbacks to itself — used by solo mode to let
/// [BattleSession] instantiate without a peer (all sends are silently dropped,
/// receive stream never emits). A [Uint8List] type alias so imports stay tidy.
///
// TODO(battle): wire SoloTransport into TurnLoop's solo path so it can run
//   the engine without a live peer on the other end.
class SoloTransport implements Transport {
  final _incoming = StreamController<List<int>>.broadcast();

  @override Future<void> advertise() async {}
  @override Future<void> discover() async {}
  @override Future<void> connect(String peerId) async {}
  @override void send(List<int> bytes) {}
  @override Stream<List<int>> get onReceive => _incoming.stream;
  @override Future<void> disconnect() => _incoming.close();
}
