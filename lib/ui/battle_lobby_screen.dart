// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_lobby_screen.dart — pre-duel lobby: chapter/settings selection, LAN
// matchmaking (host or join), and the full runDuelSetup handshake
// (LAN_BATTLE_WIREUP_PLAN.md §3.3). Host picks chapter + match settings
// first (DuelHostSettingsScreen); guest picks only a chapter
// (DuelJoinChapterScreen) since it adopts the host's MatchConfig verbatim
// (DECISION 3). Once a peer Transport connects, runDuelSetup runs the full
// handshake and this screen hands off into BattleScreen with the real
// BattleSession — Stage 1 (LAN_BATTLE_WIREUP_PLAN.md §2 DECISION 4): peer
// casts are trusted, not proof-verified.
//
// mDNS discovery/advertising (via `nsd`) is best-effort, not load-bearing:
// `nsd` has no Linux desktop backend at all (lan_discovery.dart's header
// comment), and real networks can block multicast outright (AP isolation).
// Both the hosting and joining flows fall back to manual IP entry — the
// same host:port TextField pattern already proven in gate_screen.dart's M4
// two-device gate — dialing the same listening socket directly via
// LanSocketTransport.connectTo, bypassing `nsd` entirely.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../battle/networking/duel_setup.dart';
import '../battle/models/match_config.dart';
import '../battle/models/wild_magic_effect.dart'
    show kDefaultCommunitySeed, normalizeCommunitySeed;
import '../battle/networking/match_discovery.dart';
import '../dev_flags.dart' show kShowDevSurfaces;
import '../ffi/prover.dart' as prover;
import '../ffi/srs_cache.dart';
import '../identity/identity.dart';
import '../protocol/lan_socket_transport.dart';
import '../protocol/transport.dart';
import '../spells/chapter_asset.dart';
import 'battle_screen.dart';
import 'duel_host_settings_screen.dart';
import 'duel_join_chapter_screen.dart';
import 'manuscript_theme.dart';
import 'solo_practice_settings_screen.dart';
import 'spell_test_lab_screen.dart';

enum _LobbyMode { idle, hosting, joining, connecting, preparingDuel }

class BattleLobbyScreen extends StatefulWidget {
  const BattleLobbyScreen({super.key, this.pactIdHex});

  /// Set only when this duel is a graduation battle
  /// (docs/MASTER_APPRENTICE_PLAN.md §7.3) — the already-agreed
  /// GraduationPact's id, threaded straight through to [BattleScreen] so it
  /// lands in the signed MatchOutcome at match end. Null for an ordinary
  /// duel. Not otherwise used by this screen or by `runDuelSetup` — the
  /// pact was already agreed (both signatures) before this screen was ever
  /// reached, so there is nothing for the duel HANDSHAKE itself to know
  /// about it. Per the ratified terms (the apprentice sets a graduation
  /// battle's terms), the apprentice is expected to tap Host and the master
  /// to tap Join; this is a UI convention, not enforced in code here (see
  /// "do not build a general match metadata system," §7.3).
  final String? pactIdHex;

  @override
  State<BattleLobbyScreen> createState() => _BattleLobbyScreenState();
}

class _BattleLobbyScreenState extends State<BattleLobbyScreen> {
  _LobbyMode _mode = _LobbyMode.idle;
  final List<DiscoveredPeer> _peers = [];
  StreamSubscription<DiscoveredPeer>? _peerSub;
  final LanMatchDiscovery _discovery = LanMatchDiscovery();
  Transport? _transport;

  // Chosen before networking begins — see _onHostTap/_onJoinTap.
  DuelRole? _role;
  ChapterAsset? _localChapter;
  MatchConfig? _hostConfig; // host-authored; unused (placeholder) for guest.

  // Once true, BattleScreen owns the session/transport lifecycle — dispose()
  // must not also disconnect it (see that method's doc comment).
  bool _handedOff = false;

  // Manual-IP fallback state (see header comment).
  String? _hostAddressHint; // "192.168.1.23:54321", shown while hosting.
  String? _autoDiscoveryError; // set when startDiscovering() itself fails.
  final _manualConnectController = TextEditingController();
  bool _manualConnecting = false;

  // One-time SRS readiness (see lib/ffi/srs_cache.dart). Null while the check
  // is still in flight, so the warning never flashes up before we know.
  bool? _srsReady;
  bool _preparingSrs = false;
  String? _prepareError;

  @override
  void initState() {
    super.initState();
    unawaited(_checkSrsReady());
  }

  Future<void> _checkSrsReady() async {
    final ready = await srsCacheReady();
    if (!mounted) return;
    setState(() => _srsReady = ready);
  }

  /// Runs the one-time SRS download now, on purpose, while the player still
  /// has whatever internet they are going to get.
  ///
  /// This is the same call the first duel makes anyway
  /// (`BattleScreen._initTurnLoop`) — the point is only that it happens HERE,
  /// where failing is a warning the player can act on, rather than at the
  /// venue, where failing is a blocking error mid-handshake.
  ///
  /// Uses tier 12's bytecode deliberately: the download is sized to the
  /// tier-48 floor regardless of which tier asks for it, so this fetches the
  /// same bytes as tier 48 would while loading far less of it into memory.
  Future<void> _prepareDevice() async {
    setState(() {
      _preparingSrs = true;
      _prepareError = null;
    });
    try {
      final circuitJson =
          await rootBundle.loadString('assets/circuits/ca_v2_4_tier12.json');
      final bytecode = await prover.extractBytecode(circuitJson);
      await prover.initSrsCached(bytecode, cachePath: await srsCachePath());
      if (!mounted) return;
      setState(() {
        _srsReady = true;
        _preparingSrs = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _preparingSrs = false;
        _prepareError = '$e';
      });
    }
  }

  @override
  void dispose() {
    _peerSub?.cancel();
    if (!_handedOff) {
      _transport?.disconnect();
    }
    _discovery.dispose();
    _manualConnectController.dispose();
    super.dispose();
  }

  // ── Pre-networking settings steps ───────────────────────────────────────────

  Future<void> _onHostTap() async {
    final settings = await Navigator.push<DuelHostSettings>(
      context,
      MaterialPageRoute(builder: (_) => const DuelHostSettingsScreen()),
    );
    if (settings == null || !mounted) return;
    _role = DuelRole.host;
    _localChapter = settings.chapter;
    _hostConfig = settings.config;
    await _startHosting();
  }

  Future<void> _onJoinTap() async {
    final chapter = await Navigator.push<ChapterAsset>(
      context,
      MaterialPageRoute(builder: (_) => const DuelJoinChapterScreen()),
    );
    if (chapter == null || !mounted) return;
    _role = DuelRole.guest;
    _localChapter = chapter;
    await _startJoining();
  }

  // ── LAN discovery / connection ──────────────────────────────────────────────

  Future<void> _startHosting() async {
    setState(() {
      _mode = _LobbyMode.hosting;
      _peers.clear();
      _hostAddressHint = null;
    });
    try {
      // mDNS advertising inside this call is itself best-effort (see
      // LanMatchDiscovery.startAdvertising) — this only throws on a genuine
      // socket-bind failure, not on `nsd` being unavailable.
      final wizardName = await Identity.loadWizardName();
      final displayName = (wizardName != null && wizardName.isNotEmpty)
          ? "$wizardName's Duel"
          : 'Runewright Duel';
      await _discovery.startAdvertising(
        caps: DeviceCapabilities.detect(),
        displayName: displayName,
      );
      final ip = await _discovery.localAddressHint();
      final port = _discovery.listeningPort;
      if (mounted && port != null) {
        setState(() => _hostAddressHint = '${ip ?? "?"}:$port');
      }
      _discovery.acceptConnection().then((transport) {
        if (!mounted || _mode != _LobbyMode.hosting) return;
        unawaited(_beginDuelSetup(transport));
      }).catchError((Object e) {
        if (!mounted || _mode != _LobbyMode.hosting) return;
        _showError('Connection failed: $e');
        setState(() => _mode = _LobbyMode.idle);
      });
    } catch (e) {
      if (!mounted) return;
      _showError('Could not host duel: $e');
      setState(() => _mode = _LobbyMode.idle);
    }
  }

  Future<void> _startJoining() async {
    setState(() {
      _mode = _LobbyMode.joining;
      _peers.clear();
      _autoDiscoveryError = null;
    });
    try {
      final stream = await _discovery.startDiscovering();
      _peerSub = stream.listen((peer) {
        if (!mounted) return;
        setState(() => _peers.add(peer));
      });
    } catch (e) {
      // Soft failure: automatic mDNS discovery isn't available on every
      // platform (`nsd` has no Linux desktop backend) or every network (AP
      // isolation can block multicast). Manual IP entry below dials the
      // same LanSocketTransport directly, so stay in the joining view
      // rather than bouncing back to idle.
      if (!mounted) return;
      setState(() => _autoDiscoveryError = '$e');
    }
  }

  Future<void> _connectToPeer(DiscoveredPeer peer) async {
    setState(() {
      _mode = _LobbyMode.connecting;
    });
    try {
      await _peerSub?.cancel();
      _peerSub = null;
      await _discovery.stopDiscovering();
      final transport = await peer.connect();
      if (!mounted) return;
      await _beginDuelSetup(transport);
    } catch (e) {
      if (!mounted) return;
      _showError('Could not connect: $e');
      await _startJoining();
    }
  }

  /// Manual IP fallback (header comment) — parses "host:port" and dials
  /// [LanSocketTransport.connectTo] directly, bypassing `nsd` discovery
  /// entirely. Same hand-off path as a peer found via mDNS.
  Future<void> _connectManual() async {
    if (_manualConnecting) return;
    final raw = _manualConnectController.text.trim();
    final colonIdx = raw.lastIndexOf(':');
    if (colonIdx <= 0) {
      _showError('Enter host:port, e.g. 192.168.1.23:54321');
      return;
    }
    final host = raw.substring(0, colonIdx);
    final port = int.tryParse(raw.substring(colonIdx + 1));
    if (port == null) {
      _showError('Bad port in "$raw"');
      return;
    }

    setState(() => _manualConnecting = true);
    try {
      await _peerSub?.cancel();
      _peerSub = null;
      await _discovery.stopDiscovering();
      final transport = await LanSocketTransport.connectTo(host, port);
      if (!mounted) return;
      setState(() => _manualConnecting = false);
      await _beginDuelSetup(transport);
    } catch (e) {
      if (!mounted) return;
      setState(() => _manualConnecting = false);
      _showError('Could not connect to $host:$port: $e');
    }
  }

  Future<void> _cancelNetworking() async {
    await _peerSub?.cancel();
    _peerSub = null;
    await _discovery.stopAdvertising();
    await _discovery.stopDiscovering();
    if (!mounted) return;
    setState(() {
      _mode = _LobbyMode.idle;
      _peers.clear();
    });
  }

  // ── Handshake + hand-off ─────────────────────────────────────────────────────

  /// Runs the full LAN duel handshake (LAN_BATTLE_WIREUP_PLAN.md §3.2) over
  /// the just-connected [transport], then pushes [BattleScreen] with the
  /// real [BattleSession]. On any handshake failure, disconnects and returns
  /// to the idle lobby with an error.
  Future<void> _beginDuelSetup(Transport transport) async {
    if (!mounted) return;
    setState(() {
      _transport = transport;
      _mode = _LobbyMode.preparingDuel;
    });
    try {
      final identity = await Identity.loadOrCreate();
      final result = await runDuelSetup(
        transport: transport,
        role: _role!,
        localIdentity: identity,
        localChapter: _localChapter!,
        hostConfig: _hostConfig ?? const MatchConfig(),
      );
      if (!mounted) return;
      // The host is authoritative over MatchConfig (DECISION 3), so the guest
      // simply adopts the host's leyline seed word — no mismatch is possible,
      // but the guest must be TOLD, because it silently changes every spell in
      // their book's wild magic for this duel (WILD_MAGIC_PLAN.md §7.5: a
      // difference should read as "you follow different traditions", not as an
      // error).
      if (_role == DuelRole.guest) {
        final theirs = normalizeCommunitySeed(result.state.config.communitySeed);
        final mine = normalizeCommunitySeed(
          await Identity.loadCommunitySeed() ?? kDefaultCommunitySeed,
        );
        if (mounted && theirs != mine) {
          _showError(
            'Your host follows a different tradition — this duel is fought '
            'under "$theirs". Your spells will find different wild magic.',
          );
        }
      }
      if (!mounted) return;
      // BattleScreen now owns the session/transport lifecycle — see dispose().
      _handedOff = true;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => BattleScreen(
            state: result.state,
            localPlayerId: result.localPlayerId,
            chapter: result.localChapter,
            session: result.session,
            matchId: result.matchId,
            peerBookRoot: result.peerBookRootHex,
            peerBookLeafCount: result.peerBookLeafCount,
            peerOwnerPubkeyHex: result.peer.ownerPubkeyHex,
            peerRawPubkey: result.peer.rawPubkey,
            peerPermissions: result.peerPermissions,
            pactIdHex: widget.pactIdHex,
            peerAvatarId: result.peerAvatarId,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showError('Duel setup failed: $e');
      await transport.disconnect();
      if (!mounted) return;
      setState(() {
        _mode = _LobbyMode.idle;
        _transport = null;
      });
    }
  }

  // ── Solo / test surfaces (no networking) ────────────────────────────────────

  void _onSoloPracticeTap() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SoloPracticeSettingsScreen()),
    );
  }

  void _onSpellTestLabTap() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SpellTestLabScreen()),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        backgroundColor: kInkColor,
        foregroundColor: kParchmentColor,
        elevation: 0,
        title: Text(
          'BATTLE',
          style: manuscriptHeaderStyle(fontSize: 20, color: kParchmentColor),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildModeSection()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeSection() {
    return switch (_mode) {
      _LobbyMode.idle => _IdleSection(
          onHostTap: _onHostTap,
          onJoinTap: _onJoinTap,
          onSoloPracticeTap: _onSoloPracticeTap,
          onSpellTestLabTap: _onSpellTestLabTap,
          srsReady: _srsReady,
          preparingSrs: _preparingSrs,
          prepareError: _prepareError,
          onPrepareTap: _prepareDevice,
        ),
      _LobbyMode.hosting => _HostingSection(
          addressHint: _hostAddressHint,
          onCancel: _cancelNetworking,
        ),
      _LobbyMode.joining => _JoiningSection(
          peers: _peers,
          onPeerTap: _connectToPeer,
          onCancel: _cancelNetworking,
          autoDiscoveryError: _autoDiscoveryError,
          manualController: _manualConnectController,
          manualConnecting: _manualConnecting,
          onManualConnect: _connectManual,
        ),
      _LobbyMode.connecting => const _ConnectingSection(),
      _LobbyMode.preparingDuel => const _PreparingDuelSection(),
    };
  }
}

// ── Mode sections ─────────────────────────────────────────────────────────────

class _IdleSection extends StatelessWidget {
  const _IdleSection({
    required this.onHostTap,
    required this.onJoinTap,
    required this.onSoloPracticeTap,
    required this.onSpellTestLabTap,
    required this.srsReady,
    required this.preparingSrs,
    required this.prepareError,
    required this.onPrepareTap,
  });

  final VoidCallback onHostTap;
  final VoidCallback onJoinTap;
  final VoidCallback onSoloPracticeTap;
  final VoidCallback onSpellTestLabTap;

  /// Null while the check is in flight — the warning must not flash up and
  /// then vanish on a device that was ready all along.
  final bool? srsReady;
  final bool preparingSrs;
  final String? prepareError;
  final VoidCallback onPrepareTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (srsReady == false) ...[
          _PrepareDeviceCard(
            preparing: preparingSrs,
            error: prepareError,
            onPrepareTap: onPrepareTap,
          ),
          const SizedBox(height: 24),
        ],
        _LobbyButton(label: 'HOST A DUEL', onTap: onHostTap),
        const SizedBox(height: 12),
        _LobbyButton(label: 'JOIN A DUEL', onTap: onJoinTap),
        const SizedBox(height: 24),
        Divider(color: kInkColor.withValues(alpha: 0.12)),
        const SizedBox(height: 24),
        _LobbyButton(label: 'SOLO PRACTICE', onTap: onSoloPracticeTap),
        // DEV FLAG (kShowDevSurfaces — lib/dev_flags.dart). The lab's spells
        // carry no proof, so they need kAllowProoflessSpells too.
        if (kShowDevSurfaces) ...[
          const SizedBox(height: 24),
          Divider(color: kInkColor.withValues(alpha: 0.12)),
          const SizedBox(height: 24),
          _LobbyButton(label: 'SPELL TEST LAB', onTap: onSpellTestLabTap),
        ],
      ],
    );
  }
}

/// Warns that this device has never fetched its proving data, and offers to
/// do it now.
///
/// Every duel verifies the opponent's proofs, which needs the SRS on disk —
/// and a device that has never inscribed a spell does not have it. The first
/// duel would fetch it silently, except that duels happen in person, on
/// whatever network the venue has, and a failure there is a blocking error
/// with nothing the player can do about it. Saying so in the lobby moves that
/// discovery to somewhere it is still fixable.
///
/// Deliberately not an automatic background download: [kSrsDownloadSizeApprox]
/// is far too much to spend of someone's mobile data without asking.
class _PrepareDeviceCard extends StatelessWidget {
  const _PrepareDeviceCard({
    required this.preparing,
    required this.error,
    required this.onPrepareTap,
  });

  final bool preparing;
  final String? error;
  final VoidCallback onPrepareTap;

  @override
  Widget build(BuildContext context) {
    final err = error;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: kInkColor.withValues(alpha: 0.35)),
        color: kInkColor.withValues(alpha: 0.04),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'THIS DEVICE IS NOT READY TO DUEL',
            style: manuscriptHeaderStyle(fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          const Text(
            'Before its first duel, a device fetches the proving data it '
            'needs to check an opponent\'s spells — about '
            '$kSrsDownloadSizeApprox, downloaded once and kept. Do it now, '
            'on a connection you trust: duelling itself works offline, but '
            'this step cannot.',
            style: TextStyle(fontSize: 13, height: 1.4),
          ),
          if (err != null) ...[
            const SizedBox(height: 10),
            Text(
              'That did not work:\n$err',
              style: const TextStyle(fontSize: 12, color: Color(0xFF8C2F2F)),
            ),
          ],
          const SizedBox(height: 14),
          if (preparing)
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('Fetching — this takes a few minutes.'),
              ],
            )
          else
            _LobbyButton(label: 'PREPARE THIS DEVICE', onTap: onPrepareTap),
        ],
      ),
    );
  }
}

class _HostingSection extends StatelessWidget {
  const _HostingSection({required this.addressHint, required this.onCancel});

  final String? addressHint;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(color: kIlluminationGold),
        const SizedBox(height: 20),
        Text(
          'Waiting for challenger...',
          style: manuscriptBodyStyle(fontSize: 16),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          'Make sure you are on the same network.',
          style: manuscriptCaptionStyle(),
          textAlign: TextAlign.center,
        ),
        if (addressHint != null) ...[
          const SizedBox(height: 20),
          Text(
            'If your opponent can\'t find this duel automatically,\n'
            'have them enter this address manually:',
            style: manuscriptCaptionStyle(),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          SelectableText(
            addressHint!,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: kInkColor,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 28),
        TextButton(
          onPressed: onCancel,
          child: const Text(
            'Cancel',
            style: TextStyle(
              fontFamily: 'serif',
              letterSpacing: 1,
              color: kInkMutedColor,
            ),
          ),
        ),
      ],
    );
  }
}

class _JoiningSection extends StatelessWidget {
  const _JoiningSection({
    required this.peers,
    required this.onPeerTap,
    required this.onCancel,
    required this.autoDiscoveryError,
    required this.manualController,
    required this.manualConnecting,
    required this.onManualConnect,
  });

  final List<DiscoveredPeer> peers;
  final void Function(DiscoveredPeer) onPeerTap;
  final VoidCallback onCancel;
  final String? autoDiscoveryError;
  final TextEditingController manualController;
  final bool manualConnecting;
  final VoidCallback onManualConnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (autoDiscoveryError == null) ...[
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: kIlluminationGold,
                ),
              ),
              const SizedBox(width: 10),
              Text('Scanning for duels...', style: manuscriptCaptionStyle()),
            ],
          ),
          const SizedBox(height: 12),
        ] else ...[
          Text(
            'Automatic discovery isn\'t available here '
            '(enter your opponent\'s address below instead).',
            style: manuscriptCaptionStyle(color: kInkMutedColor),
          ),
          const SizedBox(height: 12),
        ],
        Expanded(
          child: peers.isEmpty
              ? Center(
                  child: Text(
                    autoDiscoveryError == null
                        ? 'No challengers found yet.\nMake sure your opponent has hosted.'
                        : 'No challengers found automatically.\n'
                            'Enter their address below.',
                    style: manuscriptBodyStyle(
                      fontSize: 14,
                      color: kInkMutedColor,
                    ),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: peers.length,
                  itemBuilder: (_, i) => _PeerTile(
                    peer: peers[i],
                    onTap: () => onPeerTap(peers[i]),
                  ),
                ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: manualController,
                style: const TextStyle(fontFamily: 'serif', fontSize: 14, color: kInkColor),
                decoration: InputDecoration(
                  hintText: 'host:port',
                  hintStyle: const TextStyle(color: kInkMutedColor),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: kInkColor.withValues(alpha: 0.3)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: manualConnecting ? null : onManualConnect,
              style: OutlinedButton.styleFrom(
                foregroundColor: kIlluminationGold,
                side: const BorderSide(color: kIlluminationGold),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              ),
              child: const Text(
                'Connect',
                style: TextStyle(fontFamily: 'serif', fontSize: 14),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: onCancel,
          child: const Text(
            'Cancel',
            style: TextStyle(
              fontFamily: 'serif',
              letterSpacing: 1,
              color: kInkMutedColor,
            ),
          ),
        ),
      ],
    );
  }
}

class _ConnectingSection extends StatelessWidget {
  const _ConnectingSection();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircularProgressIndicator(color: kIlluminationGold),
        SizedBox(height: 20),
        Text(
          'Connecting...',
          style: TextStyle(
            fontFamily: 'serif',
            fontSize: 16,
            color: kInkColor,
          ),
        ),
      ],
    );
  }
}

class _PreparingDuelSection extends StatelessWidget {
  const _PreparingDuelSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(color: kIlluminationGold),
        const SizedBox(height: 20),
        Text(
          'Preparing duel...',
          style: manuscriptBodyStyle(fontSize: 16),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          'Authenticating and syncing with your opponent.',
          style: manuscriptCaptionStyle(),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _LobbyButton extends StatelessWidget {
  const _LobbyButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = enabled ? kInkColor : kInkMutedColor;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color),
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'serif',
          fontSize: 16,
          letterSpacing: 3,
          fontWeight: FontWeight.w300,
          color: color,
        ),
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.onTap});

  final DiscoveredPeer peer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: kParchmentPanelColor,
            border: Border.all(color: kInkColor.withValues(alpha: 0.2)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  peer.displayName,
                  style: const TextStyle(
                    fontFamily: 'serif',
                    fontSize: 16,
                    color: kInkColor,
                  ),
                ),
              ),
              Text('Join', style: manuscriptCaptionStyle(color: kIlluminationGold)),
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right, size: 18, color: kIlluminationGold),
            ],
          ),
        ),
      ),
    );
  }
}
