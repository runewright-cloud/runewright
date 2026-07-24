// SPDX-License-Identifier: GPL-3.0-or-later
//
// trade_screen.dart — Commune/Trade: pair with a nearby wizard over LAN,
// build a mutual offer of loans/transfers, confirm, and exchange grants.
//
// State machine mirrors battle_lobby_screen.dart's host/join/connect shape,
// extended with the trade-specific offer/confirm/exchange steps (see
// docs/COMMUNE_TRADE_PLAN.md §6.3). Non-atomic by design: once both sides
// confirm, each independently transmits its promised grants — see
// trade_session.dart's file header for why, and [TradeResult] for how a
// partial/failed exchange is reported rather than hidden.

import 'dart:async';

import 'package:flutter/material.dart';

import '../identity/identity.dart';
import '../protocol/transport.dart';
import '../spells/spell_asset.dart';
import '../trade/trade_discovery.dart';
import '../trade/trade_offer.dart';
import '../trade/trade_session.dart';
import 'manuscript_theme.dart';

enum _Stage {
  idle,
  hosting,
  joining,
  connecting,
  pairing,
  buildingOffer,
  submittingOffer,
  reviewingOffers,
  awaitingConfirm,
  exchanging,
  done,
  cancelled,
  error,
}

/// One spell's in-progress selection in the offer builder, before it
/// becomes an immutable [TradeItem].
class _Selection {
  _Selection(this.spell);
  final SpellAsset spell;
  bool included = false;
  TradeMode mode = TradeMode.loan;
  int loanDays = 3;
}

class TradeScreen extends StatefulWidget {
  const TradeScreen({super.key});

  @override
  State<TradeScreen> createState() => _TradeScreenState();
}

class _TradeScreenState extends State<TradeScreen> {
  _Stage _stage = _Stage.idle;
  String? _errorMessage;

  final TradeDiscovery _discovery = TradeDiscovery();
  final List<DiscoveredTradePeer> _peers = [];
  StreamSubscription<DiscoveredTradePeer>? _peerSub;

  Transport? _transport;
  TradeSession? _session;
  Identity? _identity;

  List<_Selection> _selections = [];
  TradeOffer? _theirOffer;
  TradeResult? _result;

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
      await _discovery.startAdvertising();
      final transport = await _discovery.acceptConnection();
      if (!mounted || _stage != _Stage.hosting) return;
      await _discovery.stopAdvertising();
      _transport = transport;
      await _pair(transport, isInitiator: false);
    } catch (e) {
      _fail('Could not host a trade session: $e');
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

  Future<void> _connectToPeer(DiscoveredTradePeer peer) async {
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

  /// The dialer initiates the TradeSession handshake; the listener accepts
  /// it — a consistent mapping onto the underlying LAN transport roles.
  Future<void> _pair(Transport transport, {required bool isInitiator}) async {
    if (!mounted) return;
    setState(() => _stage = _Stage.pairing);
    try {
      final identity = await Identity.loadOrCreate();
      final session = isInitiator
          ? await TradeSession.initiate(transport, identity)
          : await TradeSession.accept(transport, identity);
      final allSpells = await SpellAsset.loadAll();
      final eligible = await eligibleOfferSpellsFor(allSpells, identity);
      if (!mounted) return;
      setState(() {
        _identity = identity;
        _session = session;
        _selections = eligible.map(_Selection.new).toList();
        _stage = _Stage.buildingOffer;
      });
    } catch (e) {
      _fail('Pairing failed: $e');
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

  // ── Offer building ──────────────────────────────────────────────────────

  Future<void> _onToggleTransfer(_Selection selection) async {
    if (selection.mode == TradeMode.transfer) {
      setState(() => selection.mode = TradeMode.loan);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kParchmentColor,
        title: Text('Transfer "${selection.spell.name}"?', style: manuscriptHeaderStyle(fontSize: 16)),
        content: Text(
          'This gives the other wizard permanent full rights to this magic, '
          'including the ability to see the grid state you used to create it. '
          'This cannot be undone.',
          style: manuscriptBodyStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Transfer permanently', style: manuscriptBodyStyle(fontSize: 14, color: kRubricRed)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() => selection.mode = TradeMode.transfer);
    }
  }

  Future<void> _submitOffer() async {
    final session = _session;
    if (session == null) return;
    final offer = TradeOffer(
      items: _selections.where((s) => s.included).map((s) {
        return TradeItem(
          spellId: s.spell.id,
          commitmentHex: s.spell.commitmentHex,
          spellName: s.spell.name,
          mode: s.mode,
          loanDays: s.mode == TradeMode.loan ? s.loanDays : null,
        );
      }).toList(),
    );
    setState(() => _stage = _Stage.submittingOffer);
    try {
      final theirOffer = await session.exchangeOffer(offer);
      if (!mounted) return;
      setState(() {
        _theirOffer = theirOffer;
        _stage = _Stage.reviewingOffers;
      });
    } catch (e) {
      _fail('Offer exchange failed: $e');
    }
  }

  // ── Confirm + exchange ─────────────────────────────────────────────────

  Future<void> _decide(bool confirm) async {
    final session = _session;
    if (session == null) return;
    setState(() => _stage = _Stage.awaitingConfirm);
    try {
      final bothConfirmed = await session.exchangeConfirm(confirm);
      if (!mounted) return;
      if (!bothConfirmed) {
        setState(() => _stage = _Stage.cancelled);
        return;
      }
      setState(() => _stage = _Stage.exchanging);
      final identity = _identity!;
      final ourOffer = TradeOffer(
        items: _selections.where((s) => s.included).map((s) {
          return TradeItem(
            spellId: s.spell.id,
            commitmentHex: s.spell.commitmentHex,
            spellName: s.spell.name,
            mode: s.mode,
            loanDays: s.mode == TradeMode.loan ? s.loanDays : null,
          );
        }).toList(),
      );
      final ourSpells = _selections.map((s) => s.spell).toList();
      final result = await session.exchangeGrantsAndSave(
        ourIdentity: identity,
        ourOffer: ourOffer,
        ourSpells: ourSpells,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _Stage.done;
      });
    } catch (e) {
      _fail('Grant exchange failed: $e');
    }
  }

  void _returnToStart() {
    setState(() {
      _stage = _Stage.idle;
      _peers.clear();
      _transport = null;
      _session = null;
      _selections = [];
      _theirOffer = null;
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
        title: Text('TRADE', style: manuscriptHeaderStyle(fontSize: 20, color: kParchmentColor)),
      ),
      body: SafeArea(
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
      _Stage.buildingOffer => _OfferBuilderSection(
          selections: _selections,
          onChanged: () => setState(() {}),
          onToggleTransfer: _onToggleTransfer,
          onSubmit: _submitOffer,
        ),
      _Stage.submittingOffer => const _SpinnerSection(message: 'Waiting for their offer...'),
      _Stage.reviewingOffers => _ReviewSection(
          ourSelections: _selections,
          theirOffer: _theirOffer!,
          onConfirm: () => _decide(true),
          onCancel: () => _decide(false),
        ),
      _Stage.awaitingConfirm => const _SpinnerSection(message: 'Waiting for their decision...'),
      _Stage.exchanging => const _SpinnerSection(message: 'Exchanging grants...'),
      _Stage.done => _ResultSection(result: _result!, onDone: _returnToStart),
      _Stage.cancelled => _MessageSection(
          icon: Icons.cancel_outlined,
          message: 'Trade cancelled.',
          onDone: _returnToStart,
        ),
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
        IlluminatedButton(label: 'HOST A TRADE', onTap: onHostTap),
        const SizedBox(height: 12),
        IlluminatedButton(label: 'JOIN A TRADE', onTap: onJoinTap, primary: false),
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
  final List<DiscoveredTradePeer> peers;
  final void Function(DiscoveredTradePeer) onPeerTap;
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
  final DiscoveredTradePeer peer;
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
              Text('Trade', style: manuscriptCaptionStyle(color: kIlluminationGold)),
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right, size: 18, color: kIlluminationGold),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfferBuilderSection extends StatelessWidget {
  const _OfferBuilderSection({
    required this.selections,
    required this.onChanged,
    required this.onToggleTransfer,
    required this.onSubmit,
  });

  final List<_Selection> selections;
  final VoidCallback onChanged;
  final void Function(_Selection) onToggleTransfer;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('What do you offer?', style: manuscriptHeaderStyle(fontSize: 18)),
        const SizedBox(height: 4),
        Text(
          'Only spells you own outright can be offered. You may offer nothing.',
          style: manuscriptCaptionStyle(),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: selections.isEmpty
              ? Center(
                  child: Text(
                    'You have no spells of your own to offer.\nYou may still submit an empty offer.',
                    style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: selections.length,
                  itemBuilder: (_, i) => _SelectionTile(
                    selection: selections[i],
                    onChanged: onChanged,
                    onToggleTransfer: () => onToggleTransfer(selections[i]),
                  ),
                ),
        ),
        const SizedBox(height: 12),
        IlluminatedButton(label: 'SUBMIT OFFER', onTap: onSubmit),
      ],
    );
  }
}

class _SelectionTile extends StatelessWidget {
  const _SelectionTile({required this.selection, required this.onChanged, required this.onToggleTransfer});
  final _Selection selection;
  final VoidCallback onChanged;
  final VoidCallback onToggleTransfer;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: kParchmentPanelColor,
        border: Border.all(color: kInkColor.withValues(alpha: 0.15)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            value: selection.included,
            onChanged: (v) {
              selection.included = v ?? false;
              onChanged();
            },
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            activeColor: kIlluminationGold,
            title: Text(selection.spell.name, style: const TextStyle(fontFamily: 'serif', fontSize: 15, color: kInkColor)),
          ),
          if (selection.included)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 8, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        _ModeChip(
                          label: 'Loan',
                          selected: selection.mode == TradeMode.loan,
                          onTap: selection.mode == TradeMode.transfer ? onToggleTransfer : null,
                        ),
                        const SizedBox(width: 8),
                        _ModeChip(
                          label: 'Transfer',
                          selected: selection.mode == TradeMode.transfer,
                          color: kRubricRed,
                          onTap: selection.mode == TradeMode.loan ? onToggleTransfer : null,
                        ),
                      ],
                    ),
                  ),
                  if (selection.mode == TradeMode.loan) ...[
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 18, color: kInkMutedColor),
                      onPressed: selection.loanDays > 1
                          ? () {
                              selection.loanDays -= 1;
                              onChanged();
                            }
                          : null,
                    ),
                    Text('${selection.loanDays}d', style: manuscriptBodyStyle(fontSize: 14)),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline, size: 18, color: kInkMutedColor),
                      onPressed: () {
                        selection.loanDays += 1;
                        onChanged();
                      },
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.label, required this.selected, required this.onTap, this.color = kIlluminationGold});
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.15) : Colors.transparent,
          border: Border.all(color: selected ? color : kInkMutedColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(fontFamily: 'serif', fontSize: 12, color: selected ? color : kInkMutedColor),
        ),
      ),
    );
  }
}

class _ReviewSection extends StatelessWidget {
  const _ReviewSection({
    required this.ourSelections,
    required this.theirOffer,
    required this.onConfirm,
    required this.onCancel,
  });

  final List<_Selection> ourSelections;
  final TradeOffer theirOffer;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ourItems = ourSelections.where((s) => s.included).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Review the trade', style: manuscriptHeaderStyle(fontSize: 18)),
        const SizedBox(height: 16),
        Expanded(
          child: ListView(
            children: [
              Text('You give', style: manuscriptCaptionStyle(color: kIlluminationGold)),
              const SizedBox(height: 6),
              if (ourItems.isEmpty)
                Text('Nothing.', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor))
              else
                ...ourItems.map((s) => _OfferLine(
                      name: s.spell.name,
                      mode: s.mode,
                      loanDays: s.loanDays,
                    )),
              const SizedBox(height: 20),
              Text('You receive', style: manuscriptCaptionStyle(color: kIlluminationGold)),
              const SizedBox(height: 6),
              if (theirOffer.items.isEmpty)
                Text('Nothing.', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor))
              else
                ...theirOffer.items.map((i) => _OfferLine(
                      name: i.spellName,
                      mode: i.mode,
                      loanDays: i.loanDays,
                    )),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Once you confirm, this is not guaranteed atomic — see the design '
          'notes if that matters to you. Trust your fellow wizard.',
          style: manuscriptCaptionStyle(),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        IlluminatedButton(label: 'CONFIRM TRADE', onTap: onConfirm),
        const SizedBox(height: 8),
        TextButton(
          onPressed: onCancel,
          child: Text('Cancel', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor)),
        ),
      ],
    );
  }
}

class _OfferLine extends StatelessWidget {
  const _OfferLine({required this.name, required this.mode, this.loanDays});
  final String name;
  final TradeMode mode;
  final int? loanDays;

  @override
  Widget build(BuildContext context) {
    final tag = mode == TradeMode.loan ? '${loanDays ?? '?'}-day loan' : 'permanent transfer';
    final tagColor = mode == TradeMode.loan ? kIlluminationGold : kRubricRed;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(child: Text(name, style: manuscriptBodyStyle(fontSize: 14))),
          Text(tag, style: manuscriptCaptionStyle(color: tagColor)),
        ],
      ),
    );
  }
}

class _ResultSection extends StatelessWidget {
  const _ResultSection({required this.result, required this.onDone});
  final TradeResult result;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle_outline, size: 48, color: kIlluminationGold),
        const SizedBox(height: 12),
        Text('Trade complete', style: manuscriptHeaderStyle(fontSize: 18), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Expanded(
          child: ListView(
            children: [
              Text('Sent', style: manuscriptCaptionStyle(color: kIlluminationGold)),
              const SizedBox(height: 6),
              if (result.sent.isEmpty)
                Text('Nothing.', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor))
              else
                ...result.sent.map((r) => _ResultLine(item: r)),
              const SizedBox(height: 20),
              Text('Received', style: manuscriptCaptionStyle(color: kIlluminationGold)),
              const SizedBox(height: 6),
              if (result.received.isEmpty)
                Text('Nothing.', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor))
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
  final TradeResultItem item;

  @override
  Widget build(BuildContext context) {
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
                Text(item.item.spellName, style: manuscriptBodyStyle(fontSize: 14)),
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
