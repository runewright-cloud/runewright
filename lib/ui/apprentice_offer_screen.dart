// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprentice_offer_screen.dart — Master/Apprentice pairing + chapter-loan
// offer state machine (docs/MASTER_APPRENTICE_PLAN.md §6.3). Mirrors
// trade_screen.dart's host/join/discover/connect shape on
// `_rw-appr._tcp`, extended with the (asymmetric, role-dependent) offer
// steps: the master picks a chapter and offers it; the apprentice reviews
// the preview and accepts or declines.
//
// One screen for both roles rather than two, because everything up through
// pairing (and the result/error/cancelled terminal states) is identical —
// only the offer-building step differs, and that's already isolated in
// _MasterChapterPickerSection / _ApprenticeReviewSection.

import 'dart:async';

import 'package:flutter/material.dart';

import '../apprentice/apprentice_discovery.dart';
import '../apprentice/apprentice_session.dart';
import '../apprentice/apprenticeship.dart';
import '../identity/identity.dart';
import '../protocol/lan_socket_transport.dart';
import '../protocol/transport.dart';
import '../spells/chapter_asset.dart';
import '../spells/spell_asset.dart';
import '../spells/spell_authorization.dart';
import 'manuscript_theme.dart';

enum ApprenticeOfferRole { master, apprentice }

enum _Stage {
  idle,
  hosting,
  joining,
  connecting,
  pairing,
  pickingChapter, // master only
  sendingOffer, // master only: sent, awaiting the apprentice's decision
  awaitingOffer, // apprentice only: waiting for the master's manifest
  reviewingOffer, // apprentice only
  exchangingBundle,
  done,
  declined,
  cancelled,
  error,
}

class ApprenticeOfferScreen extends StatefulWidget {
  const ApprenticeOfferScreen({super.key, required this.role});

  final ApprenticeOfferRole role;

  @override
  State<ApprenticeOfferScreen> createState() => _ApprenticeOfferScreenState();
}

class _ApprenticeOfferScreenState extends State<ApprenticeOfferScreen> {
  _Stage _stage = _Stage.idle;
  String? _errorMessage;
  String? _declineReason;

  final ApprenticeDiscovery _discovery = ApprenticeDiscovery();
  final List<DiscoveredApprenticePeer> _peers = [];
  StreamSubscription<DiscoveredApprenticePeer>? _peerSub;

  Transport? _transport;
  ApprenticeSession? _session;
  Identity? _identity;
  bool _isRenewal = false;

  // Master-only offer-building state.
  List<_ChapterOption> _chapterOptions = [];
  ChapterAsset? _chosenChapter;
  List<SpellAsset> _allLocalSpells = [];

  // Apprentice-only review state.
  ChapterOfferManifest? _receivedManifest;

  ApprenticeGrantResult? _grantResult;
  ApprenticeReceiveResult? _receiveResult;

  // Manual-IP fallback — `nsd` has no Linux desktop backend at all
  // (lan_discovery.dart's header comment), mirrors trade_screen.dart's
  // identical fallback.
  String? _hostAddressHint;
  String? _autoDiscoveryError;
  final _manualConnectController = TextEditingController();
  bool _manualConnecting = false;

  bool get _isMaster => widget.role == ApprenticeOfferRole.master;

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

  // ── Pairing ──────────────────────────────────────────────────────────────

  Future<void> _startHosting() async {
    setState(() {
      _stage = _Stage.hosting;
      _peers.clear();
      _hostAddressHint = null;
    });
    try {
      await _discovery.startAdvertising();
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
      final existing = await ApprenticeshipRecord.forPeer(
        session.peerOwnerPubkeyHex,
        side: _isMaster ? ApprenticeSide.master : ApprenticeSide.apprentice,
      );
      final isRenewal = existing != null && existing.status == ApprenticeshipStatus.active;
      if (!mounted) return;
      _identity = identity;
      _session = session;
      _isRenewal = isRenewal;

      if (_isMaster) {
        final chapters = await ChapterAsset.loadAll();
        final allSpells = await SpellAsset.loadAll();
        final options = <_ChapterOption>[];
        for (final c in chapters) {
          final eligibility = await chapterEligibleForApprenticeLoan(
            chapter: c,
            localSpells: allSpells,
            master: identity,
          );
          options.add(_ChapterOption(chapter: c, eligibility: eligibility));
        }
        if (!mounted) return;
        setState(() {
          _allLocalSpells = allSpells;
          _chapterOptions = options;
          _stage = _Stage.pickingChapter;
        });
      } else {
        setState(() => _stage = _Stage.awaitingOffer);
        unawaited(_awaitOffer());
      }
    } catch (e) {
      _fail('Pairing failed: $e');
    }
  }

  /// Escape hatch for any mid-exchange spinner stage — none of these network
  /// awaits has a timeout (a real decision can legitimately take as long as
  /// the other wizard needs), so without this a peer that never responds
  /// leaves no way back. Mirrors trade_screen.dart's identical method.
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

  // ── Master: pick a chapter, offer it, await the decision, deliver ───────

  Future<void> _offerChapter(ChapterAsset chapter) async {
    final session = _session;
    final identity = _identity;
    if (session == null || identity == null) return;
    setState(() {
      _chosenChapter = chapter;
      _stage = _Stage.sendingOffer;
    });
    try {
      await session.sendChapterOffer(chapter: chapter, spells: _allLocalSpells, isRenewal: _isRenewal);
      final acceptance = await session.awaitAcceptance();
      if (!mounted) return;
      if (!acceptance.accepted) {
        setState(() {
          _declineReason = acceptance.reason;
          _stage = _Stage.declined;
        });
        return;
      }

      // Belt-and-braces re-check immediately before signing (§5.2) — the
      // chapter picker already filtered this, but nothing prevents the
      // player from editing the chapter (e.g. via another screen) between
      // pairing and this moment.
      final recheck = await chapterEligibleForApprenticeLoan(
        chapter: chapter,
        localSpells: _allLocalSpells,
        master: identity,
      );
      if (!recheck.eligible) {
        _fail('This chapter is no longer eligible to lend: ${recheck.reasons.join('; ')}');
        return;
      }

      setState(() => _stage = _Stage.exchangingBundle);
      final result = await session.sendChapterBundle(
        master: identity,
        chapter: chapter,
        spells: _allLocalSpells,
      );
      if (!mounted) return;
      setState(() {
        _grantResult = result;
        _stage = result.success ? _Stage.done : _Stage.error;
        if (!result.success) _errorMessage = result.errors.join('; ');
      });
    } catch (e) {
      if (!mounted || _stage == _Stage.idle) return;
      _fail('Offer failed: $e');
    }
  }

  // ── Apprentice: await the offer, review, accept/decline, receive ────────

  Future<void> _awaitOffer() async {
    final session = _session;
    if (session == null) return;
    try {
      final manifest = await session.awaitChapterOffer();
      if (!mounted) return;
      setState(() {
        _receivedManifest = manifest;
        _stage = _Stage.reviewingOffer;
      });
    } catch (e) {
      if (!mounted || _stage == _Stage.idle) return;
      _fail('Waiting for the offer failed: $e');
    }
  }

  Future<void> _respond(bool accept) async {
    final session = _session;
    final identity = _identity;
    if (session == null || identity == null) return;
    session.respondToOffer(accept);
    if (!accept) {
      setState(() => _stage = _Stage.declined);
      return;
    }
    setState(() => _stage = _Stage.exchangingBundle);
    try {
      final result = await session.receiveChapterBundleAndSave(
        me: identity,
        masterPubkeyHex: session.peerOwnerPubkeyHex,
      );
      if (!mounted) return;
      setState(() {
        _receiveResult = result;
        _stage = result.success ? _Stage.done : _Stage.error;
        if (!result.success) _errorMessage = result.errors.join('; ');
      });
    } catch (e) {
      if (!mounted || _stage == _Stage.idle) return;
      _fail('Receiving the chapter failed: $e');
    }
  }

  void _returnToStart() {
    setState(() {
      _stage = _Stage.idle;
      _peers.clear();
      _transport = null;
      _session = null;
      _identity = null;
      _chapterOptions = [];
      _chosenChapter = null;
      _allLocalSpells = [];
      _receivedManifest = null;
      _grantResult = null;
      _receiveResult = null;
      _errorMessage = null;
      _declineReason = null;
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final title = _isMaster ? 'OFFER APPRENTICESHIP' : 'STUDY UNDER A MASTER';
    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        backgroundColor: kInkColor,
        foregroundColor: kParchmentColor,
        elevation: 0,
        title: Text(title, style: manuscriptHeaderStyle(fontSize: 18, color: kParchmentColor)),
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
      _Stage.pickingChapter => _MasterChapterPickerSection(
          options: _chapterOptions,
          isRenewal: _isRenewal,
          onChosen: _offerChapter,
        ),
      _Stage.sendingOffer =>
        _SpinnerSection(message: 'Awaiting their decision...', onCancel: _abortExchange),
      _Stage.awaitingOffer =>
        _SpinnerSection(message: 'Waiting for a chapter offer...', onCancel: _abortExchange),
      _Stage.reviewingOffer => _ApprenticeReviewSection(
          manifest: _receivedManifest!,
          onAccept: () => _respond(true),
          onDecline: () => _respond(false),
        ),
      _Stage.exchangingBundle =>
        _SpinnerSection(message: 'Delivering the chapter...', onCancel: _abortExchange),
      _Stage.done => _DoneSection(
          isMaster: _isMaster,
          chapterName: _chosenChapter?.name ?? _receivedManifest?.chapterName ?? '',
          grantResult: _grantResult,
          receiveResult: _receiveResult,
          onDone: _returnToStart,
        ),
      _Stage.declined => _MessageSection(
          icon: Icons.cancel_outlined,
          message: _isMaster
              ? 'They declined the offer.${_declineReason != null ? ' (${_declineReason!})' : ''}'
              : 'You declined the offer.',
          onDone: _returnToStart,
        ),
      _Stage.cancelled => _MessageSection(
          icon: Icons.cancel_outlined,
          message: 'Cancelled.',
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

// ── Master: chapter option + picker ─────────────────────────────────────────

class _ChapterOption {
  const _ChapterOption({required this.chapter, required this.eligibility});
  final ChapterAsset chapter;
  final ChapterEligibility eligibility;
}

class _MasterChapterPickerSection extends StatelessWidget {
  const _MasterChapterPickerSection({required this.options, required this.isRenewal, required this.onChosen});
  final List<_ChapterOption> options;
  final bool isRenewal;
  final void Function(ChapterAsset) onChosen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          isRenewal ? 'Renew with which chapter?' : 'Lend which chapter?',
          style: manuscriptHeaderStyle(fontSize: 18),
        ),
        const SizedBox(height: 4),
        Text(
          'Only a chapter of spells you fully own may be lent — a spell you '
          'hold on loan cannot be re-lent onward.',
          style: manuscriptCaptionStyle(),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: options.isEmpty
              ? Center(
                  child: Text(
                    'You have no chapters to offer.',
                    style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: options.length,
                  itemBuilder: (_, i) {
                    final o = options[i];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: kParchmentPanelColor,
                        border: Border.all(color: kInkColor.withValues(alpha: 0.15)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: ListTile(
                        enabled: o.eligibility.eligible,
                        title: Text(
                          o.chapter.name,
                          style: TextStyle(
                            fontFamily: 'serif',
                            fontSize: 15,
                            color: o.eligibility.eligible ? kInkColor : kInkMutedColor,
                          ),
                        ),
                        subtitle: o.eligibility.eligible
                            ? Text('${o.chapter.entries.length} spells', style: manuscriptCaptionStyle())
                            : Text(
                                o.eligibility.reasons.join('; '),
                                style: manuscriptCaptionStyle(color: kRubricRed),
                              ),
                        trailing: o.eligibility.eligible
                            ? const Icon(Icons.chevron_right, color: kIlluminationGold)
                            : null,
                        onTap: o.eligibility.eligible ? () => onChosen(o.chapter) : null,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ── Apprentice: manifest review ─────────────────────────────────────────────

class _ApprenticeReviewSection extends StatelessWidget {
  const _ApprenticeReviewSection({required this.manifest, required this.onAccept, required this.onDecline});
  final ChapterOfferManifest manifest;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          manifest.isRenewal ? 'Renewal offer' : 'Apprenticeship offer',
          style: manuscriptHeaderStyle(fontSize: 18),
        ),
        const SizedBox(height: 4),
        Text(manifest.chapterName, style: const TextStyle(fontFamily: 'serif', fontSize: 16, color: kInkColor)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kParchmentPanelColor,
            border: Border.all(color: kIlluminationGold.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            'These runes are lent, not given. You will be able to cast them '
            'but never to see how they were drawn, and they fade in '
            '${manifest.termDays} days unless your master renews them.',
            style: manuscriptBodyStyle(fontSize: 13),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView.builder(
            itemCount: manifest.entries.length,
            itemBuilder: (_, i) {
              final e = manifest.entries[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(child: Text(e.name, style: manuscriptBodyStyle(fontSize: 14))),
                    Text('${e.manaCost} mana', style: manuscriptCaptionStyle()),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        IlluminatedButton(label: 'ACCEPT', onTap: onAccept),
        const SizedBox(height: 8),
        TextButton(
          onPressed: onDecline,
          child: Text('Decline', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor)),
        ),
      ],
    );
  }
}

// ── Shared sections (mirrors trade_screen.dart's) ───────────────────────────

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
  const _WaitingSection({
    required this.message,
    required this.detail,
    required this.addressHint,
    required this.onCancel,
  });
  final String message;
  final String detail;
  final String? addressHint;
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
        if (addressHint != null) ...[
          const SizedBox(height: 20),
          Text(
            'If they can\'t find this automatically,\n'
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
        if (autoDiscoveryError == null) ...[
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
        ] else ...[
          Text(
            'Automatic discovery isn\'t available here '
            '(enter their address below instead).',
            style: manuscriptCaptionStyle(color: kInkMutedColor),
          ),
          const SizedBox(height: 12),
        ],
        Expanded(
          child: peers.isEmpty
              ? Center(
                  child: Text(
                    autoDiscoveryError == null
                        ? 'No one found yet.\nMake sure your fellow wizard is hosting.'
                        : 'No one found automatically.\nEnter their address below.',
                    style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: peers.length,
                  itemBuilder: (_, i) => _PeerTile(peer: peers[i], onTap: () => onPeerTap(peers[i])),
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

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.onTap});
  final DiscoveredApprenticePeer peer;
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
              const Icon(Icons.chevron_right, size: 18, color: kIlluminationGold),
            ],
          ),
        ),
      ),
    );
  }
}

class _DoneSection extends StatelessWidget {
  const _DoneSection({
    required this.isMaster,
    required this.chapterName,
    required this.grantResult,
    required this.receiveResult,
    required this.onDone,
  });
  final bool isMaster;
  final String chapterName;
  final ApprenticeGrantResult? grantResult;
  final ApprenticeReceiveResult? receiveResult;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final String summary;
    if (isMaster) {
      final r = grantResult!;
      summary = '$chapterName lent — ${r.grantedSpellCount} spell'
          '${r.grantedSpellCount == 1 ? '' : 's'} granted (${r.entryCount} chapter '
          'entries).';
    } else {
      final r = receiveResult!;
      summary = '$chapterName received — ${r.grantedSpellCount} spell'
          '${r.grantedSpellCount == 1 ? '' : 's'} now in your chapter.';
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle_outline, size: 48, color: kIlluminationGold),
        const SizedBox(height: 16),
        Text(summary, style: manuscriptBodyStyle(fontSize: 15), textAlign: TextAlign.center),
        const SizedBox(height: 28),
        IlluminatedButton(label: 'DONE', onTap: onDone),
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
