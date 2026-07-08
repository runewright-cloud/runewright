// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_lobby_screen.dart — pre-duel lobby: chapter selection and LAN
// matchmaking (host or join). Stops at Transport establishment; the turn
// loop and combat UI are a later milestone.

import 'dart:async';

import 'package:flutter/material.dart';

import '../battle/networking/match_discovery.dart';
import '../protocol/transport.dart';
import 'manuscript_theme.dart';
import 'solo_practice_settings_screen.dart';
import 'spell_test_lab_screen.dart';

enum _LobbyMode { idle, hosting, joining, connecting, connected }

class BattleLobbyScreen extends StatefulWidget {
  const BattleLobbyScreen({super.key});

  @override
  State<BattleLobbyScreen> createState() => _BattleLobbyScreenState();
}

class _BattleLobbyScreenState extends State<BattleLobbyScreen> {
  _LobbyMode _mode = _LobbyMode.idle;
  final List<DiscoveredPeer> _peers = [];
  StreamSubscription<DiscoveredPeer>? _peerSub;
  final LanMatchDiscovery _discovery = LanMatchDiscovery();
  Transport? _transport;

  @override
  void dispose() {
    _peerSub?.cancel();
    _transport?.disconnect();
    _discovery.dispose();
    super.dispose();
  }

  Future<void> _startHosting() async {
    setState(() {
      _mode = _LobbyMode.hosting;
      _peers.clear();
    });
    try {
      await _discovery.startAdvertising(caps: DeviceCapabilities.detect());
      _discovery.acceptConnection().then((transport) {
        if (!mounted || _mode != _LobbyMode.hosting) return;
        setState(() {
          _transport = transport;
          _mode = _LobbyMode.connected;
        });
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
    });
    try {
      final stream = await _discovery.startDiscovering();
      _peerSub = stream.listen((peer) {
        if (!mounted) return;
        setState(() => _peers.add(peer));
      });
    } catch (e) {
      if (!mounted) return;
      _showError('Could not scan for duels: $e');
      setState(() => _mode = _LobbyMode.idle);
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
      setState(() {
        _transport = transport;
        _mode = _LobbyMode.connected;
      });
    } catch (e) {
      if (!mounted) return;
      _showError('Could not connect: $e');
      await _startJoining();
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
          onHostTap: _startHosting,
          onJoinTap: _startJoining,
          onSoloPracticeTap: _onSoloPracticeTap,
          onSpellTestLabTap: _onSpellTestLabTap,
        ),
      _LobbyMode.hosting => _HostingSection(onCancel: _cancelNetworking),
      _LobbyMode.joining => _JoiningSection(
          peers: _peers,
          onPeerTap: _connectToPeer,
          onCancel: _cancelNetworking,
        ),
      _LobbyMode.connecting => const _ConnectingSection(),
      _LobbyMode.connected => const _ConnectedSection(),
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
  });

  final VoidCallback onHostTap;
  final VoidCallback onJoinTap;
  final VoidCallback onSoloPracticeTap;
  final VoidCallback onSpellTestLabTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LobbyButton(label: 'HOST A DUEL', onTap: onHostTap),
        const SizedBox(height: 12),
        _LobbyButton(label: 'JOIN A DUEL', onTap: onJoinTap),
        const SizedBox(height: 24),
        Divider(color: kInkColor.withValues(alpha: 0.12)),
        const SizedBox(height: 24),
        _LobbyButton(label: 'SOLO PRACTICE', onTap: onSoloPracticeTap),
        const SizedBox(height: 24),
        Divider(color: kInkColor.withValues(alpha: 0.12)),
        const SizedBox(height: 24),
        _LobbyButton(label: 'SPELL TEST LAB', onTap: onSpellTestLabTap),
      ],
    );
  }
}

class _HostingSection extends StatelessWidget {
  const _HostingSection({required this.onCancel});

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
  });

  final List<DiscoveredPeer> peers;
  final void Function(DiscoveredPeer) onPeerTap;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        Expanded(
          child: peers.isEmpty
              ? Center(
                  child: Text(
                    'No challengers found yet.\nMake sure your opponent has hosted.',
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

class _ConnectedSection extends StatelessWidget {
  const _ConnectedSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle_outline, size: 48, color: kIlluminationGold),
        const SizedBox(height: 16),
        Text(
          'Opponent connected.',
          style: manuscriptBodyStyle(fontSize: 16),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          'Ready to duel.',
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

