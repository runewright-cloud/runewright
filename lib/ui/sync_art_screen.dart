// SPDX-License-Identifier: GPL-3.0-or-later
//
// sync_art_screen.dart — Commune/Sync Art: pair with a nearby wizard over
// LAN and reconcile custom spell art AND sound across each side's Sightings
// library (docs/SPELL_SOUND_PACK_PLAN.md F-4 renamed the user-facing label
// to "Sync Art & Sound" -- the message-type names and enum identifiers below
// stay as SyncArt*/SpellArtSource, same discipline as the Rod of Wind
// rename, since SpellArtSource values are persisted by name on-device).
//
// State machine mirrors trade_screen.dart's host/join/connect shape, trimmed:
// unlike Trade, Sync Art grants nothing and moves no ownership, so there is
// no offer/confirm gate — pairing implies consent to reconcile, and `sync()`
// runs automatically once paired (sync_art_session.dart).

import 'dart:async';

import 'package:flutter/material.dart';

import '../identity/identity.dart';
import '../protocol/transport.dart';
import '../trade/sync_art_discovery.dart';
import '../trade/sync_art_session.dart';
import 'manuscript_theme.dart';
import 'safe_layout.dart';

enum _Stage {
  idle,
  hosting,
  joining,
  connecting,
  pairing,
  syncing,
  done,
  error,
}

class SyncArtScreen extends StatefulWidget {
  const SyncArtScreen({super.key});

  @override
  State<SyncArtScreen> createState() => _SyncArtScreenState();
}

class _SyncArtScreenState extends State<SyncArtScreen> {
  _Stage _stage = _Stage.idle;
  String? _errorMessage;

  final SyncArtDiscovery _discovery = SyncArtDiscovery();
  final List<DiscoveredSyncArtPeer> _peers = [];
  StreamSubscription<DiscoveredSyncArtPeer>? _peerSub;

  Transport? _transport;
  SyncArtResult? _result;

  @override
  void dispose() {
    _peerSub?.cancel();
    _transport?.disconnect();
    _discovery.dispose();
    super.dispose();
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _stage = _Stage.error;
      _errorMessage = message;
    });
  }

  // ── Pairing ──────────────────────────────────────────────────────────────

  Future<void> _startHosting() async {
    setState(() {
      _stage = _Stage.hosting;
      _peers.clear();
    });
    try {
      final wizardName = await Identity.loadWizardName();
      final displayName = (wizardName != null && wizardName.isNotEmpty)
          ? "$wizardName's Sync Art"
          : 'Runewright Sync Art';
      await _discovery.startAdvertising(displayName: displayName);
      final transport = await _discovery.acceptConnection();
      if (!mounted || _stage != _Stage.hosting) return;
      await _discovery.stopAdvertising();
      _transport = transport;
      await _pair(transport, isInitiator: false);
    } catch (e) {
      _fail('Could not host a sync: $e');
    }
  }

  Future<void> _startJoining() async {
    setState(() {
      _stage = _Stage.joining;
      _peers.clear();
    });
    try {
      final stream = await _discovery.startDiscovering();
      _peerSub = stream.listen((peer) {
        if (!mounted) return;
        setState(() => _peers.add(peer));
      });
    } catch (e) {
      _fail('Could not scan for wizards: $e');
    }
  }

  Future<void> _connectToPeer(DiscoveredSyncArtPeer peer) async {
    setState(() => _stage = _Stage.connecting);
    try {
      await _peerSub?.cancel();
      _peerSub = null;
      await _discovery.stopDiscovering();
      final transport = await peer.connect();
      if (!mounted) return;
      _transport = transport;
      await _pair(transport, isInitiator: true);
    } catch (e) {
      _fail('Could not connect: $e');
    }
  }

  /// The dialer initiates the SyncArtSession handshake; the listener
  /// accepts it — a consistent mapping onto the underlying LAN transport
  /// roles. Once paired, reconciliation starts immediately (no confirm
  /// gate — see file header).
  Future<void> _pair(Transport transport, {required bool isInitiator}) async {
    if (!mounted) return;
    setState(() => _stage = _Stage.pairing);
    try {
      final identity = await Identity.loadOrCreate();
      final session = isInitiator
          ? await SyncArtSession.initiate(transport, identity)
          : await SyncArtSession.accept(transport, identity);
      if (!mounted) return;
      setState(() => _stage = _Stage.syncing);
      final result = await session.sync(ourIdentity: identity);
      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _Stage.done;
      });
    } catch (e) {
      _fail('Sync failed: $e');
    }
  }

  Future<void> _cancelNetworking() async {
    await _peerSub?.cancel();
    _peerSub = null;
    await _discovery.stopAdvertising();
    await _discovery.stopDiscovering();
    if (!mounted) return;
    setState(() {
      _stage = _Stage.idle;
      _peers.clear();
    });
  }

  void _returnToStart() {
    setState(() {
      _stage = _Stage.idle;
      _peers.clear();
      _transport = null;
      _result = null;
      _errorMessage = null;
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        backgroundColor: kInkColor,
        foregroundColor: kParchmentColor,
        elevation: 0,
        title: Text('SYNC ART & SOUND', style: manuscriptHeaderStyle(fontSize: 20, color: kParchmentColor)),
      ),
      body: SafeScreenBody(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: _buildStage(),
        ),
      ),
    );
  }

  Widget _buildStage() {
    return switch (_stage) {
      _Stage.idle => _IdleSection(onHostTap: _startHosting, onJoinTap: _startJoining),
      _Stage.hosting => _WaitingSection(
          message: 'Waiting for another wizard...',
          detail: 'Make sure you are on the same network.',
          onCancel: _cancelNetworking,
        ),
      _Stage.joining => _JoiningSection(peers: _peers, onPeerTap: _connectToPeer, onCancel: _cancelNetworking),
      _Stage.connecting => const _SpinnerSection(message: 'Connecting...'),
      _Stage.pairing => const _SpinnerSection(message: 'Establishing trust...'),
      _Stage.syncing => const _SpinnerSection(message: 'Comparing sighted spells...'),
      _Stage.done => _ResultSection(result: _result!, onDone: _returnToStart),
      _Stage.error => _MessageSection(
          icon: Icons.error_outline,
          message: _errorMessage ?? 'Something went wrong.',
          color: kRubricRed,
          onDone: _returnToStart,
        ),
    };
  }
}

// ── Sections ─────────────────────────────────────────────────────────────────

class _IdleSection extends StatelessWidget {
  const _IdleSection({required this.onHostTap, required this.onJoinTap});
  final VoidCallback onHostTap;
  final VoidCallback onJoinTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Reconcile custom spell art and sound with a fellow wizard whose spells '
          'you\'ve faced in a duel — and yours with them.',
          style: manuscriptCaptionStyle(),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        IlluminatedButton(label: 'HOST A SYNC', onTap: onHostTap),
        const SizedBox(height: 12),
        IlluminatedButton(label: 'JOIN A SYNC', onTap: onJoinTap, primary: false),
      ],
    );
  }
}

class _WaitingSection extends StatelessWidget {
  const _WaitingSection({required this.message, required this.detail, required this.onCancel});
  final String message;
  final String detail;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(color: kIlluminationGold),
        const SizedBox(height: 20),
        Text(message, style: manuscriptBodyStyle(fontSize: 16), textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(detail, style: manuscriptCaptionStyle(), textAlign: TextAlign.center),
        const SizedBox(height: 28),
        TextButton(
          onPressed: onCancel,
          child: Text('Cancel', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor)),
        ),
      ],
    );
  }
}

class _SpinnerSection extends StatelessWidget {
  const _SpinnerSection({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(color: kIlluminationGold),
        const SizedBox(height: 20),
        Text(message, style: manuscriptBodyStyle(fontSize: 16), textAlign: TextAlign.center),
      ],
    );
  }
}

class _JoiningSection extends StatelessWidget {
  const _JoiningSection({required this.peers, required this.onPeerTap, required this.onCancel});
  final List<DiscoveredSyncArtPeer> peers;
  final void Function(DiscoveredSyncArtPeer) onPeerTap;
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
              child: CircularProgressIndicator(strokeWidth: 2, color: kIlluminationGold),
            ),
            const SizedBox(width: 10),
            Text('Scanning for wizards...', style: manuscriptCaptionStyle()),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: peers.isEmpty
              ? Center(
                  child: Text(
                    'No one found yet.\nMake sure your fellow wizard is hosting.',
                    style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: peers.length,
                  itemBuilder: (_, i) => _PeerTile(peer: peers[i], onTap: () => onPeerTap(peers[i])),
                ),
        ),
        TextButton(
          onPressed: onCancel,
          child: Text('Cancel', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor)),
        ),
      ],
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.onTap});
  final DiscoveredSyncArtPeer peer;
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
                child: Text(peer.displayName, style: const TextStyle(fontFamily: 'serif', fontSize: 16, color: kInkColor)),
              ),
              Text('Sync', style: manuscriptCaptionStyle(color: kIlluminationGold)),
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right, size: 18, color: kIlluminationGold),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultSection extends StatelessWidget {
  const _ResultSection({required this.result, required this.onDone});
  final SyncArtResult result;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle_outline, size: 48, color: kIlluminationGold),
        const SizedBox(height: 12),
        Text('Sync complete', style: manuscriptHeaderStyle(fontSize: 18), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Expanded(
          child: ListView(
            children: [
              Text('Sent', style: manuscriptCaptionStyle(color: kIlluminationGold)),
              const SizedBox(height: 6),
              if (result.sent.isEmpty)
                Text('Nothing to send — the other wizard already had it all, or hasn\'t sighted '
                        'any spells of yours with custom art or sound.',
                    style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor))
              else
                ...result.sent.map((r) => _ResultLine(item: r)),
              const SizedBox(height: 20),
              Text('Received', style: manuscriptCaptionStyle(color: kIlluminationGold)),
              const SizedBox(height: 6),
              if (result.received.isEmpty)
                Text('Nothing new — you\'re already caught up, or they have no custom art or '
                        'sound yet.',
                    style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor))
              else
                ...result.received.map((r) => _ResultLine(item: r)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        IlluminatedButton(label: 'DONE', onTap: onDone),
      ],
    );
  }
}

class _ResultLine extends StatelessWidget {
  const _ResultLine({required this.item});
  final SyncArtResultItem item;

  @override
  Widget build(BuildContext context) {
    final label = item.spellName.isNotEmpty ? item.spellName : 'Unnamed Spell';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            item.success ? Icons.check : Icons.close,
            size: 16,
            color: item.success ? kIlluminationGold : kRubricRed,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: manuscriptBodyStyle(fontSize: 14)),
                if (!item.success && item.error != null)
                  Text(item.error!, style: manuscriptCaptionStyle(color: kRubricRed)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageSection extends StatelessWidget {
  const _MessageSection({required this.icon, required this.message, required this.onDone, this.color = kInkColor});
  final IconData icon;
  final String message;
  final Color color;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 48, color: color),
        const SizedBox(height: 16),
        Text(message, style: manuscriptBodyStyle(fontSize: 16), textAlign: TextAlign.center),
        const SizedBox(height: 24),
        IlluminatedButton(label: 'DONE', onTap: onDone),
      ],
    );
  }
}
