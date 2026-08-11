// SPDX-License-Identifier: GPL-3.0-or-later
//
// graduation_screen.dart — the four post-loan Master/Apprentice flows
// (docs/MASTER_APPRENTICE_PLAN.md §7): bequest (a master's outright gift),
// challenge (a master proposing a graduation-battle pact), respond (the
// apprentice reviewing and accepting/declining a proposed pact), and
// settle (either side delivering their half of an already-decided
// graduation battle's stakes). One screen, one shared pairing state
// machine (mirroring apprentice_offer_screen.dart's), dispatching to a
// mode-specific exchange once paired — four nearly-identical LAN pairing
// flows would be a lot of duplication even by this codebase's existing
// "small dedicated screens" convention (trade_screen.dart,
// apprentice_offer_screen.dart each handle exactly one flow).
//
// "Receiving a bequest" and "the apprentice receiving after winning a
// graduation battle" are the SAME underlying call
// (ApprenticeSession.receiveBequestAndSave) — [GraduationMode.receiveGrant]
// exists as its own hub entry point (distinct button, distinct initiating
// context: "my master decided to gift me something" vs "I won a battle and
// I'm here to collect") but shares the implementation with
// [GraduationMode.settle]'s apprentice-won branch.

import 'dart:async';

import 'package:flutter/material.dart';

import '../apprentice/apprentice_discovery.dart';
import '../apprentice/apprentice_session.dart';
import '../apprentice/apprenticeship.dart';
import '../apprentice/graduation_pact.dart';
import '../battle/models/match_outcome.dart';
import '../identity/identity.dart';
import '../protocol/lan_socket_transport.dart';
import '../protocol/transport.dart';
import '../spells/sighting_asset.dart';
import '../spells/spell_asset.dart';
import 'battle_lobby_screen.dart';
import 'manuscript_theme.dart';

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

enum GraduationMode { bequest, challenge, respond, receiveGrant, settle }

enum _Stage {
  idle,
  hosting,
  joining,
  connecting,
  pairing,
  pickingStakes, // challenge only
  working, // the mode-specific exchange is in flight
  reviewingPact, // respond only
  done,
  declined,
  cancelled,
  error,
}

class GraduationScreen extends StatefulWidget {
  const GraduationScreen({
    super.key,
    required this.mode,
    this.masterRecord, // bequest, challenge
    this.pact, // settle
    this.outcome, // settle
  });

  final GraduationMode mode;

  /// This device's own [ApprenticeSide.master] record for the target
  /// apprentice — required for [GraduationMode.bequest] and
  /// [GraduationMode.challenge].
  final ApprenticeshipRecord? masterRecord;

  /// The already-fully-signed pact and its matching (also fully-signed)
  /// match outcome — required for [GraduationMode.settle]. Both sides
  /// independently derive who won from these via
  /// [resolveGraduationSettlement]; neither is trusted from the wire here.
  final SignedGraduationPact? pact;
  final MatchOutcomeRecord? outcome;

  @override
  State<GraduationScreen> createState() => _GraduationScreenState();
}

class _GraduationScreenState extends State<GraduationScreen> {
  _Stage _stage = _Stage.idle;
  String? _errorMessage;
  String? _declineReason;
  String? _resultSummary;

  final ApprenticeDiscovery _discovery = ApprenticeDiscovery();
  final List<DiscoveredApprenticePeer> _peers = [];
  StreamSubscription<DiscoveredApprenticePeer>? _peerSub;

  Transport? _transport;
  ApprenticeSession? _session;
  Identity? _identity;

  // Challenge-only: stakes picker state.
  List<SightingAsset> _sightings = [];
  final Set<String> _selectedStakeCommitments = {};

  // Respond-only: the received (master-signed only) offer under review.
  SignedGraduationPact? _receivedOffer;
  List<String> _unresolvableStakes = const [];

  // Challenge/respond: a fully-signed pact, once agreed -- lets the result
  // screen offer "Proceed to Battle."
  SignedGraduationPact? _agreedPact;

  String? _hostAddressHint;
  String? _autoDiscoveryError;
  final _manualConnectController = TextEditingController();
  bool _manualConnecting = false;

  @override
  void dispose() {
    _peerSub?.cancel();
    _transport?.disconnect();
    _discovery.dispose();
    _manualConnectController.dispose();
    super.dispose();
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _stage = _Stage.error;
      _errorMessage = message;
    });
  }

  String get _title => switch (widget.mode) {
        GraduationMode.bequest => 'BEQUEATH GRADUATION',
        GraduationMode.challenge => 'CHALLENGE TO GRADUATE',
        GraduationMode.respond => 'GRADUATION OFFER',
        GraduationMode.receiveGrant => "RECEIVE MASTER'S GRANT",
        GraduationMode.settle => 'SETTLE GRADUATION',
      };

  // ── Pairing (mirrors apprentice_offer_screen.dart) ──────────────────────

  Future<void> _startHosting() async {
    setState(() {
      _stage = _Stage.hosting;
      _peers.clear();
      _hostAddressHint = null;
    });
    try {
      final wizardName = await Identity.loadWizardName();
      final displayName = (wizardName != null && wizardName.isNotEmpty)
          ? "$wizardName's Apprenticeship"
          : 'Runewright Apprenticeship';
      await _discovery.startAdvertising(displayName: displayName);
      final ip = await _discovery.localAddressHint();
      final port = _discovery.listeningPort;
      if (mounted && port != null) {
        setState(() => _hostAddressHint = '${ip ?? "?"}:$port');
      }
      final transport = await _discovery.acceptConnection();
      if (!mounted || _stage != _Stage.hosting) return;
      await _discovery.stopAdvertising();
      _transport = transport;
      await _pair(transport, isInitiator: false);
    } catch (e) {
      _fail('Could not host: $e');
    }
  }

  Future<void> _startJoining() async {
    setState(() {
      _stage = _Stage.joining;
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
      if (!mounted) return;
      setState(() => _autoDiscoveryError = '$e');
    }
  }

  Future<void> _connectToPeer(DiscoveredApprenticePeer peer) async {
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

  Future<void> _connectManual() async {
    if (_manualConnecting) return;
    final raw = _manualConnectController.text.trim();
    final colonIdx = raw.lastIndexOf(':');
    if (colonIdx <= 0) {
      _showSnack('Enter host:port, e.g. 192.168.1.23:54321');
      return;
    }
    final host = raw.substring(0, colonIdx);
    final port = int.tryParse(raw.substring(colonIdx + 1));
    if (port == null) {
      _showSnack('Bad port in "$raw"');
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
      _transport = transport;
      await _pair(transport, isInitiator: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _manualConnecting = false);
      _showSnack('Could not connect to $host:$port: $e');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pair(Transport transport, {required bool isInitiator}) async {
    if (!mounted) return;
    setState(() => _stage = _Stage.pairing);
    try {
      final identity = await Identity.loadOrCreate();
      final session = isInitiator
          ? await ApprenticeSession.initiate(transport, identity)
          : await ApprenticeSession.accept(transport, identity);
      if (!mounted) return;
      _identity = identity;
      _session = session;

      switch (widget.mode) {
        case GraduationMode.bequest:
          setState(() => _stage = _Stage.working);
          unawaited(_doBequest());
        case GraduationMode.challenge:
          final sightings = (await SightingAsset.loadAll())
              .where((s) => _hexEq(s.opponentPubkeyHex, widget.masterRecord!.apprenticePubkeyHex))
              .toList();
          if (!mounted) return;
          setState(() {
            _sightings = sightings;
            _stage = _Stage.pickingStakes;
          });
        case GraduationMode.respond:
          setState(() => _stage = _Stage.working);
          unawaited(_awaitAndReviewOffer());
        case GraduationMode.receiveGrant:
          setState(() => _stage = _Stage.working);
          unawaited(_doReceiveGrant());
        case GraduationMode.settle:
          setState(() => _stage = _Stage.working);
          unawaited(_doSettle());
      }
    } catch (e) {
      _fail('Pairing failed: $e');
    }
  }

  Future<void> _abortExchange() async {
    await _session?.close();
    await _transport?.disconnect();
    if (!mounted) return;
    _returnToStart();
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
      _session = null;
      _identity = null;
      _sightings = [];
      _selectedStakeCommitments.clear();
      _receivedOffer = null;
      _unresolvableStakes = const [];
      _agreedPact = null;
      _errorMessage = null;
      _declineReason = null;
      _resultSummary = null;
    });
  }

  // ── Bequest (§7.1) ───────────────────────────────────────────────────────

  Future<void> _doBequest() async {
    try {
      final spells = await SpellAsset.loadAll();
      final result = await _session!.sendBequest(
        master: _identity!,
        masterRecord: widget.masterRecord!,
        spells: spells,
      );
      if (!mounted) return;
      if (!result.success) {
        _fail(result.errors.join('; '));
        return;
      }
      setState(() {
        _resultSummary = 'Bequeathed ${result.grantedSpellCount} spell'
            '${result.grantedSpellCount == 1 ? '' : 's'} to your apprentice, in full.';
        _stage = _Stage.done;
      });
    } catch (e) {
      if (!mounted || _stage == _Stage.idle) return;
      _fail('Bequest failed: $e');
    }
  }

  // ── Challenge: stakes picker, then the pact proposal (§7.2) ────────────

  Future<void> _sendChallenge() async {
    setState(() => _stage = _Stage.working);
    try {
      final masterRecord = widget.masterRecord!;
      final pact = GraduationPact(
        pactIdHex: generatePactIdHex(),
        masterPubkeyHex: masterRecord.masterPubkeyHex,
        apprenticePubkeyHex: masterRecord.apprenticePubkeyHex,
        chapterName: masterRecord.chapterName,
        chapterCommitments: masterRecord.grantedCommitments,
        stakeCommitments: _selectedStakeCommitments.toList(),
        agreedAt: DateTime.now().toUtc(),
      );
      await _session!.sendGraduationOffer(master: _identity!, pact: pact);
      final response = await _session!.awaitGraduationResponse();
      if (!mounted) return;
      if (response.pact == null) {
        setState(() {
          _declineReason = response.declineReason;
          _stage = _Stage.declined;
        });
        return;
      }
      setState(() {
        _agreedPact = response.pact;
        _resultSummary = 'Your apprentice agreed to the terms. The battle is on — '
            'as you set the terms, you join; they host.';
        _stage = _Stage.done;
      });
    } catch (e) {
      if (!mounted || _stage == _Stage.idle) return;
      _fail('Challenge failed: $e');
    }
  }

  // ── Respond: await + review + accept/decline (§7.2) ─────────────────────

  Future<void> _awaitAndReviewOffer() async {
    try {
      final offer = await _session!.awaitGraduationOffer();
      final myOwnerPubkeyHex = await _identity!.ownerPubkeyHex();
      final unresolvable = unresolvableStakeCommitments(
        stakeCommitments: offer.pact.stakeCommitments,
        apprenticeOwnerPubkeyHex: myOwnerPubkeyHex,
        localSpells: await SpellAsset.loadAll(),
      );
      if (!mounted) return;
      setState(() {
        _receivedOffer = offer;
        _unresolvableStakes = unresolvable;
        _stage = _Stage.reviewingPact;
      });
    } catch (e) {
      if (!mounted || _stage == _Stage.idle) return;
      _fail('Waiting for the offer failed: $e');
    }
  }

  Future<void> _respondToOffer(bool accept) async {
    setState(() => _stage = _Stage.working);
    try {
      final signed = await _session!.respondToGraduationOffer(
        apprentice: _identity!,
        offer: _receivedOffer!,
        accept: accept,
      );
      if (!mounted) return;
      if (signed == null) {
        setState(() => _stage = _Stage.declined);
        return;
      }
      setState(() {
        _agreedPact = signed;
        _resultSummary = 'You agreed to the terms. The battle is on — as you set '
            'the terms, you host; your master joins.';
        _stage = _Stage.done;
      });
    } catch (e) {
      if (!mounted || _stage == _Stage.idle) return;
      _fail('Responding failed: $e');
    }
  }

  // ── Receive a grant: a voluntary bequest, awaited from the apprentice's side ──

  Future<void> _doReceiveGrant() async {
    try {
      final result = await _session!.receiveBequestAndSave(
        me: _identity!,
        masterPubkeyHex: _session!.peerOwnerPubkeyHex,
      );
      if (!mounted) return;
      if (!result.success) {
        _fail(result.errors.join('; '));
        return;
      }
      setState(() {
        _resultSummary = result.grantedSpellCount > 0
            ? 'Received ${result.grantedSpellCount} spell'
                '${result.grantedSpellCount == 1 ? '' : 's'} from your master, in full.'
            : 'Nothing was sent this time.';
        _stage = _Stage.done;
      });
    } catch (e) {
      if (!mounted || _stage == _Stage.idle) return;
      _fail('Receiving failed: $e');
    }
  }

  // ── Settle: resolve who won, then send or receive accordingly (§7.4) ────

  Future<void> _doSettle() async {
    try {
      final pact = widget.pact!;
      final outcome = widget.outcome!;
      final victor = await resolveGraduationSettlement(pact: pact, outcome: outcome);
      if (victor == null) {
        _fail('This graduation cannot be settled — the pact or outcome failed validation.');
        return;
      }
      final myOwnerPubkeyHex = await _identity!.ownerPubkeyHex();
      final amMaster = _hexEq(myOwnerPubkeyHex, pact.pact.masterPubkeyHex);
      final apprenticeWon = victor == GraduationVictor.apprentice;

      final String summary;
      if (apprenticeWon) {
        if (amMaster) {
          final spells = await SpellAsset.loadAll();
          final result =
              await _session!.sendBequest(master: _identity!, masterRecord: widget.masterRecord!, spells: spells);
          if (!result.success) {
            _fail(result.errors.join('; '));
            return;
          }
          summary = 'Your apprentice won. Sent ${result.grantedSpellCount} spell'
              '${result.grantedSpellCount == 1 ? '' : 's'}, in full.';
        } else {
          final result = await _session!.receiveBequestAndSave(
            me: _identity!,
            masterPubkeyHex: _session!.peerOwnerPubkeyHex,
          );
          if (!result.success) {
            _fail(result.errors.join('; '));
            return;
          }
          summary = 'You won! Received ${result.grantedSpellCount} spell'
              '${result.grantedSpellCount == 1 ? '' : 's'} from your master, in full.';
        }
      } else {
        if (amMaster) {
          final result = await _session!.receiveStakeSettlementAndSave(
            master: _identity!,
            apprenticePubkeyHex: _session!.peerOwnerPubkeyHex,
          );
          if (!result.success) {
            _fail(result.errors.join('; '));
            return;
          }
          summary = 'You won! Received ${result.grantedSpellCount} staked spell'
              '${result.grantedSpellCount == 1 ? '' : 's'} from your apprentice.';
        } else {
          final spells = await SpellAsset.loadAll();
          final result = await _session!.sendStakeSettlement(apprentice: _identity!, pact: pact, spells: spells);
          if (!result.success) {
            _fail(result.errors.join('; '));
            return;
          }
          summary = 'Your master won. Sent ${result.grantedSpellCount} staked spell'
              '${result.grantedSpellCount == 1 ? '' : 's'} — you keep your own copies.';
        }
      }
      if (!mounted) return;
      setState(() {
        _resultSummary = summary;
        _stage = _Stage.done;
      });
    } catch (e) {
      if (!mounted || _stage == _Stage.idle) return;
      _fail('Settlement failed: $e');
    }
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
        title: Text(_title, style: manuscriptHeaderStyle(fontSize: 16, color: kParchmentColor)),
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
          addressHint: _hostAddressHint,
          onCancel: _cancelNetworking,
        ),
      _Stage.joining => _JoiningSection(
          peers: _peers,
          onPeerTap: _connectToPeer,
          onCancel: _cancelNetworking,
          autoDiscoveryError: _autoDiscoveryError,
          manualController: _manualConnectController,
          manualConnecting: _manualConnecting,
          onManualConnect: _connectManual,
        ),
      _Stage.connecting => const _SpinnerSection(message: 'Connecting...'),
      _Stage.pairing => const _SpinnerSection(message: 'Establishing trust...'),
      _Stage.pickingStakes => _StakesPickerSection(
          sightings: _sightings,
          selected: _selectedStakeCommitments,
          onChanged: () => setState(() {}),
          onSubmit: _sendChallenge,
        ),
      _Stage.working => _SpinnerSection(message: _workingMessage, onCancel: _abortExchange),
      _Stage.reviewingPact => _ReviewPactSection(
          offer: _receivedOffer!,
          unresolvableStakes: _unresolvableStakes,
          onAccept: () => _respondToOffer(true),
          onDecline: () => _respondToOffer(false),
        ),
      _Stage.done => _DoneSection(
          summary: _resultSummary ?? 'Done.',
          agreedPact: _agreedPact,
          onDone: _returnToStart,
        ),
      _Stage.declined => _MessageSection(
          icon: Icons.cancel_outlined,
          message: widget.mode == GraduationMode.respond
              ? 'You declined the offer.'
              : 'They declined the offer.${_declineReason != null ? ' (${_declineReason!})' : ''}',
          onDone: _returnToStart,
        ),
      _Stage.cancelled =>
        _MessageSection(icon: Icons.cancel_outlined, message: 'Cancelled.', onDone: _returnToStart),
      _Stage.error => _MessageSection(
          icon: Icons.error_outline,
          message: _errorMessage ?? 'Something went wrong.',
          color: kRubricRed,
          onDone: _returnToStart,
        ),
    };
  }

  String get _workingMessage => switch (widget.mode) {
        GraduationMode.bequest => 'Sending your gift...',
        GraduationMode.challenge => 'Proposing terms...',
        GraduationMode.respond => 'Waiting for terms to be proposed...',
        GraduationMode.receiveGrant => 'Waiting for your master...',
        GraduationMode.settle => 'Settling...',
      };
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
        IlluminatedButton(label: 'HOST', onTap: onHostTap),
        const SizedBox(height: 12),
        IlluminatedButton(label: 'JOIN', onTap: onJoinTap, primary: false),
      ],
    );
  }
}

class _WaitingSection extends StatelessWidget {
  const _WaitingSection({required this.addressHint, required this.onCancel});
  final String? addressHint;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(color: kIlluminationGold),
        const SizedBox(height: 20),
        Text('Waiting for another wizard...', style: manuscriptBodyStyle(fontSize: 16), textAlign: TextAlign.center),
        if (addressHint != null) ...[
          const SizedBox(height: 20),
          Text(
            'If they can\'t find this automatically,\nhave them enter this address manually:',
            style: manuscriptCaptionStyle(),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          SelectableText(
            addressHint!,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 16, fontWeight: FontWeight.w600, color: kInkColor),
            textAlign: TextAlign.center,
          ),
        ],
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
  const _SpinnerSection({required this.message, this.onCancel});
  final String message;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(color: kIlluminationGold),
        const SizedBox(height: 20),
        Text(message, style: manuscriptBodyStyle(fontSize: 16), textAlign: TextAlign.center),
        if (onCancel != null) ...[
          const SizedBox(height: 28),
          TextButton(
            onPressed: onCancel,
            child: Text('Cancel', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor)),
          ),
        ],
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
  final List<DiscoveredApprenticePeer> peers;
  final void Function(DiscoveredApprenticePeer) onPeerTap;
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
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: InkWell(
                      onTap: () => onPeerTap(peers[i]),
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
                              child: Text(peers[i].displayName,
                                  style: const TextStyle(fontFamily: 'serif', fontSize: 16, color: kInkColor)),
                            ),
                            const Icon(Icons.chevron_right, size: 18, color: kIlluminationGold),
                          ],
                        ),
                      ),
                    ),
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
              child: const Text('Connect', style: TextStyle(fontFamily: 'serif', fontSize: 14)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: onCancel,
          child: Text('Cancel', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor)),
        ),
      ],
    );
  }
}

class _StakesPickerSection extends StatelessWidget {
  const _StakesPickerSection({
    required this.sightings,
    required this.selected,
    required this.onChanged,
    required this.onSubmit,
  });
  final List<SightingAsset> sightings;
  final Set<String> selected;
  final VoidCallback onChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Wager stakes?', style: manuscriptHeaderStyle(fontSize: 18)),
        const SizedBox(height: 4),
        Text(
          'You may only wager spells you have actually seen your apprentice cast. '
          'You may propose the battle unwagered.',
          style: manuscriptCaptionStyle(),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: sightings.isEmpty
              ? Center(
                  child: Text(
                    'You have never dueled this apprentice.\nYou may still propose an unwagered battle.',
                    style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: sightings.length,
                  itemBuilder: (_, i) {
                    final s = sightings[i];
                    final isSelected = selected.contains(s.commitmentHex);
                    return CheckboxListTile(
                      value: isSelected,
                      onChanged: (v) {
                        if (v ?? false) {
                          selected.add(s.commitmentHex);
                        } else {
                          selected.remove(s.commitmentHex);
                        }
                        onChanged();
                      },
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: kIlluminationGold,
                      title: Text(s.spellName, style: const TextStyle(fontFamily: 'serif', fontSize: 15, color: kInkColor)),
                      subtitle: Text(
                        '${s.manaCost} mana · seen ${s.timesSeen} time${s.timesSeen == 1 ? '' : 's'}',
                        style: manuscriptCaptionStyle(),
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 12),
        IlluminatedButton(
          label: selected.isEmpty ? 'PROPOSE UNWAGERED BATTLE' : 'PROPOSE BATTLE (${selected.length} STAKED)',
          onTap: onSubmit,
        ),
      ],
    );
  }
}

class _ReviewPactSection extends StatelessWidget {
  const _ReviewPactSection({
    required this.offer,
    required this.unresolvableStakes,
    required this.onAccept,
    required this.onDecline,
  });
  final SignedGraduationPact offer;
  final List<String> unresolvableStakes;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final blocked = unresolvableStakes.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Graduation battle proposed', style: manuscriptHeaderStyle(fontSize: 18)),
        const SizedBox(height: 4),
        Text('For: ${offer.pact.chapterName}', style: manuscriptBodyStyle(fontSize: 14)),
        const SizedBox(height: 16),
        Text('If you win', style: manuscriptCaptionStyle(color: kIlluminationGold)),
        Text(
          'You keep everything: the whole chapter becomes fully yours.',
          style: manuscriptBodyStyle(fontSize: 13),
        ),
        const SizedBox(height: 12),
        Text('If your master wins', style: manuscriptCaptionStyle(color: kRubricRed)),
        Text(
          offer.pact.stakeCommitments.isEmpty
              ? 'Nothing — this battle is unwagered.'
              : 'They receive a copy of ${offer.pact.stakeCommitments.length} of your own '
                  'spells. You keep your own copies — the wager costs secrecy, not '
                  'access.',
          style: manuscriptBodyStyle(fontSize: 13),
        ),
        if (blocked) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kParchmentPanelColor,
              border: Border.all(color: kRubricRed.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'This proposal cannot be accepted: it stakes ${unresolvableStakes.length} '
              'spell${unresolvableStakes.length == 1 ? '' : 's'} you do not natively own.',
              style: manuscriptBodyStyle(fontSize: 13, color: kRubricRed),
            ),
          ),
        ],
        const Spacer(),
        IlluminatedButton(label: 'ACCEPT', onTap: blocked ? null : onAccept),
        const SizedBox(height: 8),
        TextButton(
          onPressed: onDecline,
          child: Text('Decline', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor)),
        ),
      ],
    );
  }
}

class _DoneSection extends StatelessWidget {
  const _DoneSection({required this.summary, required this.agreedPact, required this.onDone});
  final String summary;
  final SignedGraduationPact? agreedPact;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle_outline, size: 48, color: kIlluminationGold),
        const SizedBox(height: 16),
        Text(summary, style: manuscriptBodyStyle(fontSize: 15), textAlign: TextAlign.center),
        const SizedBox(height: 28),
        if (agreedPact != null) ...[
          IlluminatedButton(
            label: 'PROCEED TO BATTLE',
            onTap: () {
              Navigator.of(context).pop();
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BattleLobbyScreen(pactIdHex: agreedPact!.pact.pactIdHex),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
        ],
        IlluminatedButton(label: 'DONE', onTap: onDone, primary: agreedPact == null),
      ],
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
