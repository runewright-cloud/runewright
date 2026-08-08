// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprenticeship_screen.dart — Master/Apprentice hub
// (docs/MASTER_APPRENTICE_PLAN.md §6.2/§7): the master's own studies (if
// any), the apprentices this device teaches, the entry point to offer a new
// apprenticeship, and any graduations awaiting settlement.
//
// "Request Graduation" (the apprentice's own panel) stays disabled: §7
// never gives the apprentice a wire message to initiate a pact with — only
// the master proposes (graduationOffer) or bequeaths unilaterally. There is
// nothing for this button to actually send.

import 'package:flutter/material.dart';

import '../apprentice/apprenticeship.dart';
import '../apprentice/graduation_pact.dart';
import '../battle/models/match_outcome.dart';
import '../identity/identity.dart';
import 'apprentice_offer_screen.dart';
import 'graduation_screen.dart';
import 'manuscript_theme.dart';

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

class ApprenticeshipScreen extends StatefulWidget {
  const ApprenticeshipScreen({super.key});

  @override
  State<ApprenticeshipScreen> createState() => _ApprenticeshipScreenState();
}

class _ApprenticeshipScreenState extends State<ApprenticeshipScreen> {
  late Future<_HubData> _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _load();
  }

  void _reload() => setState(() => _dataFuture = _load());

  Future<_HubData> _load() async {
    final identity = await Identity.loadOrCreate();
    final myOwnerPubkeyHex = await identity.ownerPubkeyHex();
    final mastership = await ApprenticeshipRecord.activeMastership();
    final apprentices = await ApprenticeshipRecord.apprentices();
    apprentices.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final pending = await _findPendingSettlements(myOwnerPubkeyHex);
    return _HubData(
      mastership: mastership,
      apprentices: apprentices,
      pendingSettlements: pending,
      // `apprentices()` is unfiltered by status — graduated relationships stay
      // in the list as history and must not gate anything.
      hasActiveApprentices: apprentices.any((r) => r.status == ApprenticeshipStatus.active),
    );
  }

  /// Any fully-signed pact whose matching, fully-signed [MatchOutcomeRecord]
  /// this device also holds, but whose relevant [ApprenticeshipRecord] (on
  /// MY side of that specific pact) hasn't yet closed — i.e. a graduation
  /// battle happened and both signed artifacts exist locally, but this
  /// device hasn't delivered/received its half of the stakes yet (§7.4).
  Future<List<_PendingSettlement>> _findPendingSettlements(String myOwnerPubkeyHex) async {
    final pacts = await SignedGraduationPact.loadAll();
    if (pacts.isEmpty) return const [];
    final outcomes = await MatchOutcomeRecord.loadAll();
    final pending = <_PendingSettlement>[];
    for (final pact in pacts) {
      if (!await pact.isFullyValid()) continue;
      MatchOutcomeRecord? matching;
      for (final o in outcomes) {
        if (_hexEq(o.outcome.pactIdHex, pact.pact.pactIdHex)) {
          matching = o;
          break;
        }
      }
      if (matching == null) continue;

      final amMaster = _hexEq(myOwnerPubkeyHex, pact.pact.masterPubkeyHex);
      final mySide = amMaster ? ApprenticeSide.master : ApprenticeSide.apprentice;
      final peerHex = amMaster ? pact.pact.apprenticePubkeyHex : pact.pact.masterPubkeyHex;
      final myRecord = await ApprenticeshipRecord.forPeer(peerHex, side: mySide);
      // Already settled on this device iff the relationship record closed.
      if (myRecord != null && myRecord.status != ApprenticeshipStatus.active) continue;

      final victor = await resolveGraduationSettlement(pact: pact, outcome: matching);
      if (victor == null) continue; // shouldn't happen given isFullyValid above, but don't offer a broken settlement

      pending.add(_PendingSettlement(
        pact: pact,
        outcome: matching,
        masterRecord: amMaster ? myRecord : null,
        wonByApprentice: victor == GraduationVictor.apprentice,
      ));
    }
    return pending;
  }

  Future<void> _offerApprenticeship() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ApprenticeOfferScreen(role: ApprenticeOfferRole.master)),
    );
    _reload();
  }

  Future<void> _renew({required bool asApprentice}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ApprenticeOfferScreen(
          role: asApprentice ? ApprenticeOfferRole.apprentice : ApprenticeOfferRole.master,
        ),
      ),
    );
    _reload();
  }

  Future<void> _receiveGrant() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GraduationScreen(mode: GraduationMode.receiveGrant)),
    );
    _reload();
  }

  Future<void> _abandon(ApprenticeshipRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kParchmentColor,
        title: Text('Abandon your studies?', style: manuscriptHeaderStyle(fontSize: 16)),
        content: Text(
          'The loaned spells fade immediately, and your master is not notified — '
          'they will only learn of it the next time you meet. This cannot be undone.',
          style: manuscriptBodyStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Abandon', style: manuscriptBodyStyle(fontSize: 14, color: kRubricRed)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await record.abandon();
    _reload();
  }

  Future<void> _bequeath(ApprenticeshipRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kParchmentColor,
        title: Text('Bequeath "${record.chapterName}"?', style: manuscriptHeaderStyle(fontSize: 16)),
        content: Text(
          'This gives your apprentice permanent full rights to every spell in this '
          'loan, including the grid states you used to create them. This cannot be '
          'undone.',
          style: manuscriptBodyStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Bequeath permanently', style: manuscriptBodyStyle(fontSize: 14, color: kRubricRed)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GraduationScreen(mode: GraduationMode.bequest, masterRecord: record),
      ),
    );
    _reload();
  }

  Future<void> _challenge(ApprenticeshipRecord record) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GraduationScreen(mode: GraduationMode.challenge, masterRecord: record),
      ),
    );
    _reload();
  }

  Future<void> _settle(_PendingSettlement settlement) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GraduationScreen(
          mode: GraduationMode.settle,
          pact: settlement.pact,
          outcome: settlement.outcome,
          masterRecord: settlement.masterRecord,
        ),
      ),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        backgroundColor: kInkColor,
        foregroundColor: kParchmentColor,
        elevation: 0,
        title: Text('APPRENTICESHIP', style: manuscriptHeaderStyle(fontSize: 20, color: kParchmentColor)),
      ),
      body: SafeArea(
        child: FutureBuilder<_HubData>(
          future: _dataFuture,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator(color: kIlluminationGold));
            }
            final data = snapshot.data!;
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (data.pendingSettlements.isNotEmpty) ...[
                  Text('Awaiting settlement', style: manuscriptHeaderStyle(fontSize: 16, color: kRubricRed)),
                  const SizedBox(height: 8),
                  ...data.pendingSettlements.map(
                    (s) => _PendingSettlementTile(settlement: s, onTap: () => _settle(s)),
                  ),
                  const SizedBox(height: 28),
                ],
                Text('Your master', style: manuscriptHeaderStyle(fontSize: 16)),
                const SizedBox(height: 8),
                _MastershipPanel(
                  record: data.mastership,
                  onRenew: () => _renew(asApprentice: true),
                  onStudy: data.hasActiveApprentices ? null : () => _renew(asApprentice: true),
                  onReceiveGrant: data.mastership == null ? null : _receiveGrant,
                  onAbandon: data.mastership == null ? null : () => _abandon(data.mastership!),
                ),
                const SizedBox(height: 28),
                Text('Your apprentices', style: manuscriptHeaderStyle(fontSize: 16)),
                const SizedBox(height: 8),
                if (data.apprentices.isEmpty)
                  Text(
                    'You have not taken on any apprentices.',
                    style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor),
                  )
                else
                  ...data.apprentices.map(
                    (r) => _ApprenticeTile(
                      record: r,
                      onRenew: () => _renew(asApprentice: false),
                      onBequeath: () => _bequeath(r),
                      onChallenge: () => _challenge(r),
                    ),
                  ),
                const SizedBox(height: 28),
                IlluminatedButton(
                  label: 'OFFER AN APPRENTICESHIP',
                  onTap: data.mastership == null ? _offerApprenticeship : null,
                ),
                if (data.mastership != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'An apprentice may not take an apprentice. Graduate first.',
                    style: manuscriptCaptionStyle(),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HubData {
  const _HubData({
    required this.mastership,
    required this.apprentices,
    required this.pendingSettlements,
    required this.hasActiveApprentices,
  });
  final ApprenticeshipRecord? mastership;
  final List<ApprenticeshipRecord> apprentices;
  final List<_PendingSettlement> pendingSettlements;

  /// Whether [apprentices] contains at least one still-active relationship —
  /// the other half of §2.2 decision 4 ("an apprentice may not take on
  /// apprentices of their own"), read from the master's side.
  final bool hasActiveApprentices;
}

class _PendingSettlement {
  const _PendingSettlement({
    required this.pact,
    required this.outcome,
    required this.masterRecord,
    required this.wonByApprentice,
  });
  final SignedGraduationPact pact;
  final MatchOutcomeRecord outcome;

  /// This device's own master-side record for the pact's apprentice — set
  /// only when this device is the master (GraduationScreen's settle mode
  /// needs it for the apprentice-won branch's sendBequest call).
  final ApprenticeshipRecord? masterRecord;
  final bool wonByApprentice;
}

class _PendingSettlementTile extends StatelessWidget {
  const _PendingSettlementTile({required this.settlement, required this.onTap});
  final _PendingSettlement settlement;
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
            border: Border.all(color: kRubricRed.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      settlement.pact.pact.chapterName,
                      style: const TextStyle(fontFamily: 'serif', fontSize: 16, color: kInkColor),
                    ),
                    Text(
                      settlement.wonByApprentice ? 'The apprentice won' : 'The master won',
                      style: manuscriptCaptionStyle(),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: kRubricRed),
            ],
          ),
        ),
      ),
    );
  }
}

class _MastershipPanel extends StatelessWidget {
  const _MastershipPanel({
    required this.record,
    required this.onRenew,
    required this.onStudy,
    required this.onReceiveGrant,
    required this.onAbandon,
  });
  final ApprenticeshipRecord? record;
  final VoidCallback onRenew;

  /// Opens the pairing flow as the *apprentice* side for a FIRST
  /// apprenticeship. Null when this device already teaches an apprentice
  /// (§2.2 decision 4). Without this the apprentice role was unreachable:
  /// `RENEW` is the only other route to it and only renders once a master
  /// already exists, so both players could only ever enter as masters — and
  /// then both sat on "Awaiting their decision..." forever.
  final VoidCallback? onStudy;
  final VoidCallback? onReceiveGrant;
  final VoidCallback? onAbandon;

  @override
  Widget build(BuildContext context) {
    final r = record;
    if (r == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'You are not currently studying under a master.',
            style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor),
          ),
          const SizedBox(height: 12),
          IlluminatedButton(label: 'STUDY UNDER A MASTER', onTap: onStudy, primary: false),
          if (onStudy == null) ...[
            const SizedBox(height: 8),
            Text(
              'An apprentice may not take an apprentice. Graduate yours first.',
              style: manuscriptCaptionStyle(),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      );
    }
    final lapsed = r.isLapsed();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kParchmentPanelColor,
        border: Border.all(color: kInkColor.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.chapterName, style: const TextStyle(fontFamily: 'serif', fontSize: 16, color: kInkColor)),
          const SizedBox(height: 4),
          Text(
            lapsed ? 'Your studies have lapsed.' : '${r.daysRemaining()} days remain',
            style: manuscriptCaptionStyle(color: lapsed ? kRubricRed : kIlluminationGold),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onRenew,
                  style: OutlinedButton.styleFrom(foregroundColor: kIlluminationGold),
                  child: const Text('RENEW'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: onReceiveGrant,
                  style: OutlinedButton.styleFrom(foregroundColor: kIlluminationGold),
                  child: const Text('RECEIVE GRANT'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: null, // §7 gives the apprentice no message to initiate with
                  style: OutlinedButton.styleFrom(foregroundColor: kInkMutedColor),
                  child: const Text('REQUEST GRADUATION'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: onAbandon,
              child: Text('Abandon apprenticeship', style: manuscriptBodyStyle(fontSize: 13, color: kRubricRed)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprenticeTile extends StatelessWidget {
  const _ApprenticeTile({
    required this.record,
    required this.onRenew,
    required this.onBequeath,
    required this.onChallenge,
  });
  final ApprenticeshipRecord record;
  final VoidCallback onRenew;
  final VoidCallback onBequeath;
  final VoidCallback onChallenge;

  @override
  Widget build(BuildContext context) {
    final lapsed = record.isLapsed();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kParchmentPanelColor,
        border: Border.all(color: kInkColor.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(record.chapterName, style: const TextStyle(fontFamily: 'serif', fontSize: 16, color: kInkColor)),
          const SizedBox(height: 4),
          Text(
            lapsed ? 'Lapsed' : '${record.daysRemaining()} days remain',
            style: manuscriptCaptionStyle(color: lapsed ? kRubricRed : kIlluminationGold),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onRenew,
                  style: OutlinedButton.styleFrom(foregroundColor: kIlluminationGold),
                  child: const Text('RENEW'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: onBequeath,
                  style: OutlinedButton.styleFrom(foregroundColor: kIlluminationGold),
                  child: const Text('BEQUEATH'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: onChallenge,
                  style: OutlinedButton.styleFrom(foregroundColor: kIlluminationGold),
                  child: const Text('CHALLENGE'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
