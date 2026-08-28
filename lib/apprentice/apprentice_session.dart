// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprentice_session.dart — the Master/Apprentice protocol: pairing
// handshake, chapter-loan offer/accept, grant delivery, and the renewal
// supersession logic (docs/MASTER_APPRENTICE_PLAN.md §5.4-§5.7).
//
// Modeled directly on lib/trade/trade_session.dart, including its
// _nextFrame buffering scheme verbatim — see that method's doc comment
// below for why this is not optional. Every step of this protocol is
// gated on a human pressing a button, so the two peers are essentially
// never subscribed to the frame stream at the same instant; a bare
// broadcast-stream subscription would silently drop whichever side acted
// first (the real two-device bug fixed in trade_session.dart on
// 2026-07-28, docs/M4_findings.md).

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../identity/identity.dart';
import '../protocol/transport.dart';
import '../protocol/wire.dart' show lengthPrefixedConcat, lengthPrefixedSplit;
import '../spells/basic_spells.dart' show isBasicSpell;
import '../spells/chapter_asset.dart';
import '../spells/spell_asset.dart';
import '../spells/spell_permission.dart';
import 'apprentice_wire.dart';
import 'apprenticeship.dart';
import 'graduation_pact.dart';

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

String _normHex(String s) => (s.startsWith('0x') ? s.substring(2) : s).toLowerCase();

Uint8List _randomBytes(int n) {
  final rng = Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

// ── Offer preview (advisory, no grants) ─────────────────────────────────────

/// One chapter entry's preview fields — mirrors what the offer screen shows
/// before any grant exists (docs/MASTER_APPRENTICE_PLAN.md §5.5). Entries
/// are 1:1 with the master's `ChapterAsset.entries`, NOT deduplicated by
/// commitment — a chapter may legitimately list the same Basic spell twice.
class ChapterOfferEntryPreview {
  const ChapterOfferEntryPreview({
    required this.name,
    required this.formula,
    required this.manaCost,
    required this.t,
    required this.tier,
    required this.isSummon,
    required this.commitmentHex,
  });

  final String name;
  final List<String> formula;
  final int manaCost;
  final int t;
  final int tier;
  final bool isSummon;
  final String commitmentHex;

  Map<String, dynamic> toJson() => {
        'name': name,
        'formula': formula,
        'manaCost': manaCost,
        't': t,
        'tier': tier,
        'isSummon': isSummon,
        'commitmentHex': commitmentHex,
      };

  static ChapterOfferEntryPreview fromJson(Map<String, dynamic> json) => ChapterOfferEntryPreview(
        name: json['name'] as String,
        formula: (json['formula'] as List<dynamic>? ?? []).cast<String>(),
        manaCost: json['manaCost'] as int,
        t: json['t'] as int,
        tier: json['tier'] as int,
        isSummon: json['isSummon'] as bool? ?? false,
        commitmentHex: json['commitmentHex'] as String,
      );
}

/// The `chapterOffer` payload — a preview only, no grids and no grants
/// (docs/MASTER_APPRENTICE_PLAN.md §5.5). Enough for the apprentice to
/// decide; nothing they could use without the grants that follow acceptance.
class ChapterOfferManifest {
  const ChapterOfferManifest({
    required this.chapterName,
    required this.isRenewal,
    required this.termDays,
    required this.entries,
    required this.artifacts,
  });

  final String chapterName;

  /// Set by the caller from `ApprenticeshipRecord.forPeer(...)` — the
  /// session itself has no opinion on whether this is a renewal.
  final bool isRenewal;

  /// Always [kApprenticeshipTermDays] today; carried on the wire rather
  /// than hardcoded on the receiving end so a future per-relationship term
  /// wouldn't need a wire-format change.
  final int termDays;

  final List<ChapterOfferEntryPreview> entries;
  final List<ArtifactEntry> artifacts;

  Map<String, dynamic> toJson() => {
        'chapterName': chapterName,
        'isRenewal': isRenewal,
        'termDays': termDays,
        'entries': entries.map((e) => e.toJson()).toList(),
        'artifacts': artifacts.map((a) => a.toJson()).toList(),
      };

  static ChapterOfferManifest fromJson(Map<String, dynamic> json) => ChapterOfferManifest(
        chapterName: json['chapterName'] as String,
        isRenewal: json['isRenewal'] as bool? ?? false,
        termDays: json['termDays'] as int? ?? kApprenticeshipTermDays,
        entries: (json['entries'] as List<dynamic>? ?? [])
            .map((e) => ChapterOfferEntryPreview.fromJson(e as Map<String, dynamic>))
            .toList(),
        artifacts: (json['artifacts'] as List<dynamic>? ?? [])
            .map((a) => ArtifactEntry.fromJson(a as Map<String, dynamic>))
            .toList(),
      );
}

// ── Results ──────────────────────────────────────────────────────────────

/// Result of [ApprenticeSession.sendChapterBundle] (master side).
class ApprenticeGrantResult {
  const ApprenticeGrantResult({
    required this.success,
    this.errors = const [],
    this.grantedSpellCount = 0,
    this.entryCount = 0,
    this.record,
  });

  final bool success;

  /// Populated iff [success] is false — signing failed for one or more
  /// spells (e.g. `chapterEligibleForApprenticeLoan` was bypassed and a
  /// non-owned spell slipped through). Nothing is sent in that case.
  final List<String> errors;

  /// Distinct non-Basic commitments granted.
  final int grantedSpellCount;

  /// Chapter entries sent (1:1 with the master's chapter — may exceed
  /// [grantedSpellCount] when a Basic spell appears more than once).
  final int entryCount;

  /// This device's own (just saved) [ApprenticeSide.master] record — see
  /// `sendChapterBundle`'s doc comment. Null iff [success] is false.
  final ApprenticeshipRecord? record;
}

/// Result of [ApprenticeSession.receiveChapterBundleAndSave] (apprentice
/// side).
class ApprenticeReceiveResult {
  const ApprenticeReceiveResult({
    required this.success,
    this.errors = const [],
    this.record,
    this.grantedSpellCount = 0,
  });

  final bool success;

  /// Populated iff [success] is false. Per docs/MASTER_APPRENTICE_PLAN.md
  /// §5.6, ANY failing grant fails the WHOLE bundle — nothing is saved, no
  /// record is written. A half-built chapter is worse than no chapter.
  final List<String> errors;

  final ApprenticeshipRecord? record;
  final int grantedSpellCount;
}

// ── Session ────────────────────────────────────────────────────────────────

/// One pending [ApprenticeSession._nextFrame] await: the frame types it will
/// accept, and the completer to resolve when one arrives.
class _FrameWaiter {
  _FrameWaiter(this.types, this.completer);
  final Set<ApprenticeMsgType> types;
  final Completer<ApprenticeFrame> completer;
}

class ApprenticeSession {
  ApprenticeSession._(
    this._transport,
    this.sessionId,
    this.peerOwnerPubkeyHex,
    this.peerRawPubkeyBytes,
    this._reader,
    this._sub,
  ) {
    // Subscribe ONCE, for the session's whole life, and buffer anything
    // nobody is waiting for yet -- see [_nextFrame].
    _frameSub = _reader.frames.listen(
      _routeFrame,
      onDone: () => _failPendingWaiters(StateError('apprentice connection closed by peer')),
      onError: _failPendingWaiters,
    );
  }

  final Transport _transport;

  /// Fixed at handshake time by the initiator, adopted (never re-read from
  /// a later message) by the responder — same discipline as TradeSession's
  /// tradeId.
  final Uint8List sessionId;

  final String peerOwnerPubkeyHex;
  final Uint8List peerRawPubkeyBytes;

  final ApprenticeFrameReader _reader;
  final StreamSubscription<List<int>> _sub;

  late final StreamSubscription<ApprenticeFrame> _frameSub;

  /// Frames that arrived before anything was waiting for them, oldest
  /// first. THIS IS THE LOAD-BEARING PIECE -- see [_nextFrame].
  final _buffered = <ApprenticeFrame>[];

  final _waiters = <_FrameWaiter>[];

  Object? _closedReason;

  void _routeFrame(ApprenticeFrame frame) {
    for (var i = 0; i < _waiters.length; i++) {
      if (_waiters[i].types.contains(frame.type)) {
        _waiters.removeAt(i).completer.complete(frame);
        return;
      }
    }
    _buffered.add(frame);
  }

  void _failPendingWaiters(Object error) {
    _closedReason ??= error;
    final pending = List<_FrameWaiter>.from(_waiters);
    _waiters.clear();
    for (final waiter in pending) {
      if (!waiter.completer.isCompleted) waiter.completer.completeError(error);
    }
  }

  /// Waits for the next frame of any type in [types], **including one that
  /// already arrived before this call**.
  ///
  /// Not an optimization — see trade_session.dart's identical method for
  /// the full incident writeup (docs/M4_findings.md, 2026-07-28). Short
  /// version: [_reader]'s controller is a *broadcast* controller, which
  /// drops any event added while it has no subscriber. Every step of this
  /// protocol is gated on a human (offer, accept, confirm), so the two
  /// devices are essentially never subscribed at the same instant —
  /// whoever acts first would otherwise have that frame silently discarded
  /// and the other side would hang forever, following submission order
  /// rather than host/guest role.
  Future<ApprenticeFrame> _nextFrame(Set<ApprenticeMsgType> types) {
    for (var i = 0; i < _buffered.length; i++) {
      if (types.contains(_buffered[i].type)) {
        return Future.value(_buffered.removeAt(i));
      }
    }
    if (_closedReason != null) return Future.error(_closedReason!);
    final completer = Completer<ApprenticeFrame>();
    _waiters.add(_FrameWaiter(types, completer));
    return completer.future;
  }

  void _send(ApprenticeMsgType type, List<int> payload) {
    _transport.send(ApprenticeFrame(type, Uint8List.fromList(payload)).encode());
  }

  // ── Handshake ────────────────────────────────────────────────────────────

  static Future<ApprenticeSession> initiate(Transport transport, Identity identity) async {
    final reader = ApprenticeFrameReader();
    final sub = transport.onReceive.listen(
      reader.addChunk,
      onDone: reader.close,
      onError: (Object _) => reader.close(),
    );
    final sessionId = _randomBytes(16);

    final ackFuture = reader.frames.where((f) => f.type == ApprenticeMsgType.apprHelloAck).first;
    transport.send(
      ApprenticeFrame(
        ApprenticeMsgType.apprHello,
        Uint8List.fromList(lengthPrefixedConcat([sessionId, identity.publicKeyBytes])),
      ).encode(),
    );
    final ack = await ackFuture;
    final peerRawPubkeyBytes = Uint8List.fromList(ack.payload);
    final peerOwnerPubkeyHex = await Identity.ownerPubkeyHexFromRawKey(peerRawPubkeyBytes);

    return ApprenticeSession._(transport, sessionId, peerOwnerPubkeyHex, peerRawPubkeyBytes, reader, sub);
  }

  static Future<ApprenticeSession> accept(Transport transport, Identity identity) async {
    final reader = ApprenticeFrameReader();
    final sub = transport.onReceive.listen(
      reader.addChunk,
      onDone: reader.close,
      onError: (Object _) => reader.close(),
    );

    final hello = await reader.frames.where((f) => f.type == ApprenticeMsgType.apprHello).first;
    final parts = lengthPrefixedSplit(hello.payload, 2);
    final sessionId = Uint8List.fromList(parts[0]);
    final peerRawPubkeyBytes = Uint8List.fromList(parts[1]);
    final peerOwnerPubkeyHex = await Identity.ownerPubkeyHexFromRawKey(peerRawPubkeyBytes);

    transport.send(ApprenticeFrame(ApprenticeMsgType.apprHelloAck, identity.publicKeyBytes).encode());

    return ApprenticeSession._(transport, sessionId, peerOwnerPubkeyHex, peerRawPubkeyBytes, reader, sub);
  }

  Future<void> close() async {
    await _frameSub.cancel();
    await _sub.cancel();
    await _reader.close();
    _failPendingWaiters(StateError('apprentice session closed'));
  }

  // ── Chapter offer (advisory preview) ────────────────────────────────────

  /// Master side: builds and sends the preview manifest for [chapter].
  /// [isRenewal] is the caller's own `ApprenticeshipRecord.forPeer(...)`
  /// lookup — this method has no opinion on it.
  ///
  /// Does NOT itself enforce §2.2 decision 4 ("an apprentice may not take
  /// an apprentice") — that's a check about whether THIS DEVICE's single
  /// local identity is itself an active apprentice
  /// (`ApprenticeshipRecord.activeMastership()`), which is meaningful only
  /// in the real one-identity-per-device model this app otherwise assumes
  /// everywhere. It's enforced at the UI layer (the hub screen disables
  /// "Offer an Apprenticeship" while `activeMastership() != null` — see
  /// `apprenticeship_screen.dart`), not duplicated here, the same way the
  /// offer-eligibility filter in Commune/Trade isn't duplicated at the
  /// session layer either.
  Future<ChapterOfferManifest> sendChapterOffer({
    required ChapterAsset chapter,
    required List<SpellAsset> spells,
    required bool isRenewal,
  }) async {
    final byId = {for (final s in spells) s.id: s};
    final entries = <ChapterOfferEntryPreview>[];
    for (final entry in chapter.entries) {
      final spell = byId[entry.spellId];
      if (spell == null) continue;
      entries.add(ChapterOfferEntryPreview(
        name: spell.name,
        formula: spell.formula,
        manaCost: spell.manaCost,
        t: spell.t,
        tier: spell.tier,
        isSummon: spell.isSummon,
        commitmentHex: spell.commitmentHex,
      ));
    }
    final manifest = ChapterOfferManifest(
      chapterName: chapter.name,
      isRenewal: isRenewal,
      termDays: kApprenticeshipTermDays,
      entries: entries,
      artifacts: chapter.artifacts,
    );
    _send(ApprenticeMsgType.chapterOffer, utf8.encode(jsonEncode(manifest.toJson())));
    return manifest;
  }

  /// Apprentice side: waits for the master's offer preview.
  Future<ChapterOfferManifest> awaitChapterOffer() async {
    final frame = await _nextFrame(const {ApprenticeMsgType.chapterOffer});
    return ChapterOfferManifest.fromJson(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>);
  }

  // ── Accept/decline gate ─────────────────────────────────────────────────

  /// Apprentice side: sends the accept/decline decision.
  void respondToOffer(bool accept, {String? reason}) {
    if (accept) {
      _send(ApprenticeMsgType.offerAccept, const []);
    } else {
      _send(ApprenticeMsgType.offerDecline, utf8.encode(reason ?? ''));
    }
  }

  /// Master side: waits for the apprentice's accept/decline. Returns
  /// `(accepted: false, reason: ...)` on decline.
  Future<({bool accepted, String? reason})> awaitAcceptance() async {
    final frame =
        await _nextFrame(const {ApprenticeMsgType.offerAccept, ApprenticeMsgType.offerDecline});
    if (frame.type == ApprenticeMsgType.offerAccept) return (accepted: true, reason: null);
    final reason = utf8.decode(frame.payload);
    return (accepted: false, reason: reason.isEmpty ? null : reason);
  }

  // ── Grant delivery (master side: sign + send) ───────────────────────────

  /// Signs one loan [SpellPermission] per distinct non-Basic commitment in
  /// [chapter] (looking up each entry's [SpellAsset] in [spells]), all
  /// sharing one `expiresAt = now + kApprenticeshipTermDays`, and sends the
  /// bundle. Basic spells are skipped entirely — no grant is needed or
  /// signable for them (their `ownerPubkeyHex` is a shipped placeholder, not
  /// [master]'s — `SpellPermission.createAndSign` would reject it anyway).
  ///
  /// If ANY spell fails to sign (should not happen if the caller already
  /// ran `chapterEligibleForApprenticeLoan`, but this is the last line of
  /// defense — see that function's doc comment), nothing is sent and the
  /// result reports every failure.
  ///
  /// Also builds/updates THIS device's own [ApprenticeSide.master] record
  /// (looked up via `ApprenticeshipRecord.forPeer`, same renewal detection
  /// `receiveChapterBundleAndSave` uses) — without this, "Your apprentices"
  /// on the hub screen would stay empty forever, and a later bequest/
  /// graduation-challenge (§7) would have nothing to read the relationship
  /// from. The master doesn't track `permissionIds`/`receivedSpellIds`
  /// (empty on this side — see [ApprenticeshipRecord]'s doc comment); it's
  /// bookkeeping for "what did I lend, to whom, until when."
  Future<ApprenticeGrantResult> sendChapterBundle({
    required Identity master,
    required ChapterAsset chapter,
    required List<SpellAsset> spells,
  }) async {
    final byId = {for (final s in spells) s.id: s};
    final expiresAt = DateTime.now().toUtc().add(const Duration(days: kApprenticeshipTermDays));

    final representative = <String, SpellAsset>{};
    for (final entry in chapter.entries) {
      final spell = byId[entry.spellId];
      if (spell == null || isBasicSpell(spell)) continue;
      representative.putIfAbsent(_normHex(spell.commitmentHex), () => spell);
    }

    final errors = <String>[];
    final grants = <Map<String, dynamic>>[];
    for (final spell in representative.values) {
      try {
        final perm = await SpellPermission.createAndSign(
          spell: spell,
          ownerIdentity: master,
          granteePubkeyHex: peerOwnerPubkeyHex,
          kind: SpellGrantKind.loan,
          expiresAt: expiresAt,
        );
        grants.add({'permission': perm.toJson(), 'asset': spell.withGridWithheld().toJson()});
      } catch (e) {
        errors.add("'${spell.name}': $e");
      }
    }
    if (errors.isNotEmpty) {
      return ApprenticeGrantResult(success: false, errors: errors);
    }

    final entries = <Map<String, dynamic>>[];
    for (final entry in chapter.entries) {
      final spell = byId[entry.spellId];
      if (spell == null) continue;
      entries.add({
        'commitmentHex': spell.commitmentHex,
        if (entry.summonPersonality != null) 'summonPersonality': entry.summonPersonality,
      });
    }

    final bundleJson = {
      'chapterName': chapter.name,
      'grants': grants,
      'entries': entries,
      'artifacts': chapter.artifacts.map((a) => a.toJson()).toList(),
    };

    final ackFuture = _nextFrame(const {ApprenticeMsgType.bundleAck});
    _send(ApprenticeMsgType.chapterBundle, utf8.encode(jsonEncode(bundleJson)));
    await ackFuture;

    final masterOwnerPubkeyHex = await master.ownerPubkeyHex();
    final existing = await ApprenticeshipRecord.forPeer(peerOwnerPubkeyHex, side: ApprenticeSide.master);
    final isRenewal = existing != null && existing.status == ApprenticeshipStatus.active;
    final now = DateTime.now().toUtc();
    final record = ApprenticeshipRecord(
      id: isRenewal ? existing.id : 'appr-${now.microsecondsSinceEpoch}',
      side: ApprenticeSide.master,
      masterPubkeyHex: masterOwnerPubkeyHex,
      apprenticePubkeyHex: peerOwnerPubkeyHex,
      chapterName: chapter.name,
      sourceChapterId: chapter.id,
      grantedCommitments: [for (final s in representative.values) s.commitmentHex],
      startedAt: isRenewal ? existing.startedAt : now,
      lastRenewedAt: now,
      expiresAt: expiresAt,
      status: ApprenticeshipStatus.active,
    );
    await record.save();

    return ApprenticeGrantResult(
      success: true,
      grantedSpellCount: grants.length,
      entryCount: entries.length,
      record: record,
    );
  }

  // ── Grant delivery (apprentice side: receive + validate + save) ────────

  /// Validates and saves the master's chapter bundle, building or updating
  /// (on renewal) the local [ChapterAsset] clone and [ApprenticeshipRecord]
  /// (docs/MASTER_APPRENTICE_PLAN.md §5.6/§5.7).
  ///
  /// Every grant is validated BEFORE anything is saved: grantee names [me],
  /// owner matches [masterPubkeyHex] (the connected, authenticated peer —
  /// pass the value this session's handshake derived, i.e.
  /// [peerOwnerPubkeyHex]), the signature verifies and isn't expired, and
  /// the accompanying asset carries NO grid (a loan must never reveal one).
  /// A single failing grant fails the WHOLE bundle: nothing is saved, no
  /// record is written or updated — a half-built chapter is worse than none.
  Future<ApprenticeReceiveResult> receiveChapterBundleAndSave({
    required Identity me,
    required String masterPubkeyHex,
  }) async {
    final bundleFuture = _nextFrame(const {ApprenticeMsgType.chapterBundle});
    final myOwnerPubkeyHex = await me.ownerPubkeyHex();
    final frame = await bundleFuture;
    _send(ApprenticeMsgType.bundleAck, const []);

    final json = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
    final chapterName = json['chapterName'] as String;
    final rawGrants = json['grants'] as List<dynamic>? ?? [];
    final rawEntries = json['entries'] as List<dynamic>? ?? [];
    final rawArtifacts = json['artifacts'] as List<dynamic>? ?? [];

    // ── Validate every grant before saving anything ──────────────────────
    final errors = <String>[];
    final validated = <(SpellPermission, SpellAsset)>[];
    for (final raw in rawGrants) {
      final entry = raw as Map<String, dynamic>;
      final perm = SpellPermission.fromJson(entry['permission'] as Map<String, dynamic>);
      final assetJson = entry['asset'] as Map<String, dynamic>?;
      if (assetJson == null) {
        errors.add('a grant is missing its spell asset');
        continue;
      }
      final asset = SpellAsset.fromJson(assetJson);
      if (!_hexEq(perm.granteePubkeyHex, myOwnerPubkeyHex)) {
        errors.add("grant for '${asset.name}' does not name this device as grantee");
        continue;
      }
      if (!_hexEq(perm.ownerPubkeyHex, masterPubkeyHex)) {
        errors.add("grant for '${asset.name}' owner does not match the connected master");
        continue;
      }
      if (!await perm.isCurrentlyUsable()) {
        errors.add("grant for '${asset.name}' signature invalid or already expired");
        continue;
      }
      if (asset.initialGrid.isNotEmpty) {
        errors.add("grant for '${asset.name}' unexpectedly included the grid state");
        continue;
      }
      validated.add((perm, asset));
    }
    if (errors.isNotEmpty) {
      return ApprenticeReceiveResult(success: false, errors: errors);
    }

    // ── Renewal detection (§5.7) ──────────────────────────────────────────
    final existing = await ApprenticeshipRecord.forPeer(masterPubkeyHex, side: ApprenticeSide.apprentice);
    final isRenewal = existing != null && existing.status == ApprenticeshipStatus.active;

    // §2.2 decision 4: an apprentice has exactly one master. A renewal of
    // THIS SAME relationship is fine (isRenewal, above); a fresh grant from
    // a DIFFERENT master while one is already active is not — reject rather
    // than silently letting a second apprenticeship coexist. Checked here
    // (after the wire handshake/ack already completed, before anything is
    // saved) rather than only in the UI, so the protocol enforces its own
    // invariant regardless of what any particular client's UI happens to
    // gate.
    if (!isRenewal) {
      final currentMastership = await ApprenticeshipRecord.activeMastership();
      if (currentMastership != null) {
        return const ApprenticeReceiveResult(
          success: false,
          errors: ['already have an active master — abandon or graduate first'],
        );
      }
    }

    // Commitment -> existing local asset, for spells persisting across a
    // renewal (reused, not re-saved under a new id).
    final existingByCommitment = <String, SpellAsset>{};
    if (isRenewal) {
      final oldIds = existing.receivedSpellIds.toSet();
      for (final asset in await SpellAsset.loadAll()) {
        if (oldIds.contains(asset.id)) existingByCommitment[_normHex(asset.commitmentHex)] = asset;
      }
    }

    final now = DateTime.now().toUtc();
    final localIdByCommitment = <String, String>{};
    final newReceivedSpellIds = <String>[];
    for (final (_, asset) in validated) {
      final normed = _normHex(asset.commitmentHex);
      final reused = existingByCommitment[normed];
      if (reused != null) {
        localIdByCommitment[normed] = reused.id;
        newReceivedSpellIds.add(reused.id);
        continue;
      }
      final freshId = 'appr-${now.microsecondsSinceEpoch}-${newReceivedSpellIds.length}-${asset.id}';
      final saved = SpellAsset(
        id: freshId,
        createdAt: asset.createdAt,
        tier: asset.tier,
        t: asset.t,
        ownerPubkeyHex: asset.ownerPubkeyHex,
        manaCost: asset.manaCost,
        segmentCount: asset.segmentCount,
        dotCount: asset.dotCount,
        initialGrid: const [],
        proofBytes: asset.proofBytes,
        name: asset.name,
        commitmentHex: asset.commitmentHex,
        spellHashHex: asset.spellHashHex,
        formula: asset.formula,
        supremeTags: asset.supremeTags,
        isSummon: asset.isSummon,
        summonPersonality: asset.summonPersonality,
        gridWithheld: true,
      );
      await saved.save();
      localIdByCommitment[normed] = freshId;
      newReceivedSpellIds.add(freshId);
    }

    if (isRenewal) {
      await deleteApprenticePermissionsByIds(existing.permissionIds);
      final removedIds =
          existing.receivedSpellIds.where((id) => !newReceivedSpellIds.contains(id)).toList();
      await deleteApprenticeSpellAssetsByIds(removedIds);
    }
    for (final (perm, _) in validated) {
      await perm.save();
    }
    final newPermissionIds = [for (final (perm, _) in validated) perm.id];

    // ── Resolve chapter entries (1:1 with the master's, may repeat) ──────
    final localBasicByCommitment = <String, String>{};
    for (final s in await SpellAsset.loadAll()) {
      if (isBasicSpell(s)) localBasicByCommitment[_normHex(s.commitmentHex)] = s.id;
    }

    final entries = <ChapterEntry>[];
    for (final raw in rawEntries) {
      final entry = raw as Map<String, dynamic>;
      final commitmentHex = entry['commitmentHex'] as String;
      final normed = _normHex(commitmentHex);
      // A Basic-spell commitment not present locally means the apprentice
      // deleted their own copy of a shipped spell (a supported, deliberate
      // action — docs/BASIC_SPELLS_PLAN.md's "deletable, stays deleted").
      // It's always re-obtainable, so drop just this entry rather than
      // failing the whole bundle over it.
      final localId = localIdByCommitment[normed] ?? localBasicByCommitment[normed];
      if (localId == null) continue;
      entries.add(ChapterEntry(spellId: localId, summonPersonality: entry['summonPersonality'] as String?));
    }
    final artifacts =
        rawArtifacts.map((a) => ArtifactEntry.fromJson(a as Map<String, dynamic>)).toList();

    final expiresAt = validated.isNotEmpty
        ? validated.first.$1.expiresAt!
        : now.add(const Duration(days: kApprenticeshipTermDays));

    final String chapterId;
    if (isRenewal) {
      chapterId = existing.localChapterId!;
      final priorCreatedAt = (await ChapterAsset.loadById(chapterId))?.createdAt ?? now;
      await ChapterAsset(
        id: chapterId,
        name: chapterName,
        createdAt: priorCreatedAt,
        entries: entries,
        artifacts: artifacts,
      ).save();
    } else {
      chapterId = 'appr-chapter-${now.microsecondsSinceEpoch}';
      await ChapterAsset(
        id: chapterId,
        name: '$chapterName (Apprentice)',
        createdAt: now,
        entries: entries,
        artifacts: artifacts,
      ).save();
    }

    final record = ApprenticeshipRecord(
      id: isRenewal ? existing.id : 'appr-${now.microsecondsSinceEpoch}',
      side: ApprenticeSide.apprentice,
      masterPubkeyHex: masterPubkeyHex,
      apprenticePubkeyHex: myOwnerPubkeyHex,
      chapterName: chapterName,
      sourceChapterId: '',
      localChapterId: chapterId,
      grantedCommitments: [for (final (_, asset) in validated) asset.commitmentHex],
      permissionIds: newPermissionIds,
      receivedSpellIds: newReceivedSpellIds,
      startedAt: isRenewal ? existing.startedAt : now,
      lastRenewedAt: now,
      expiresAt: expiresAt,
      status: ApprenticeshipStatus.active,
    );
    await record.save();

    return ApprenticeReceiveResult(success: true, record: record, grantedSpellCount: validated.length);
  }

  // ── Graduation pact (docs/MASTER_APPRENTICE_PLAN.md §7.2) ──────────────

  /// Master side: signs and sends a graduation-battle proposal. Pure
  /// transport + signing — the caller builds [pact] (stakes drawn from
  /// `SightingAsset` per §7.2's stakes picker) and is responsible for
  /// persisting the result once it comes back fully signed (or not at all,
  /// on decline) via [awaitGraduationResponse].
  Future<SignedGraduationPact> sendGraduationOffer({
    required Identity master,
    required GraduationPact pact,
  }) async {
    final signed = await SignedGraduationPact.proposedByMaster(pact: pact, masterIdentity: master);
    _send(ApprenticeMsgType.graduationOffer, utf8.encode(jsonEncode(signed.toJson())));
    return signed;
  }

  /// Apprentice side: waits for the master's proposal. Does not validate it
  /// — see [unresolvableStakeCommitments] and [respondToGraduationOffer]'s
  /// doc comment for where that belongs.
  Future<SignedGraduationPact> awaitGraduationOffer() async {
    final frame = await _nextFrame(const {ApprenticeMsgType.graduationOffer});
    return SignedGraduationPact.fromJson(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>);
  }

  /// Apprentice side: accepts (signing [offer] and sending it back) or
  /// declines. The caller MUST have already checked
  /// [unresolvableStakeCommitments] against [offer] and refused to pass
  /// `accept: true` if it's non-empty — this method does not re-check (it
  /// has no local spell list to check against) and will happily sign
  /// whatever it's told to. Persists the fully-signed pact to disk on
  /// accept, so it survives to settlement time even if the app is closed
  /// before the duel happens.
  Future<SignedGraduationPact?> respondToGraduationOffer({
    required Identity apprentice,
    required SignedGraduationPact offer,
    required bool accept,
    String? declineReason,
  }) async {
    if (!accept) {
      _send(ApprenticeMsgType.graduationDecline, utf8.encode(declineReason ?? ''));
      return null;
    }
    final signed = await offer.signedByApprentice(apprenticeIdentity: apprentice);
    await signed.save();
    _send(ApprenticeMsgType.graduationAccept, utf8.encode(jsonEncode(signed.toJson())));
    return signed;
  }

  /// Master side: waits for the apprentice's accept/decline. On accept,
  /// verifies the returned pact is [SignedGraduationPact.isFullyValid] (both
  /// signatures present and genuine) before persisting it — an apprentice
  /// client could in principle send back something malformed, and this is
  /// the master's last chance to reject that before treating the pact as
  /// binding.
  Future<({SignedGraduationPact? pact, String? declineReason})> awaitGraduationResponse() async {
    final frame =
        await _nextFrame(const {ApprenticeMsgType.graduationAccept, ApprenticeMsgType.graduationDecline});
    if (frame.type == ApprenticeMsgType.graduationDecline) {
      final reason = utf8.decode(frame.payload);
      return (pact: null, declineReason: reason.isEmpty ? null : reason);
    }
    final signed = SignedGraduationPact.fromJson(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>);
    if (!await signed.isFullyValid()) {
      return (pact: null, declineReason: 'returned pact failed signature validation');
    }
    await signed.save();
    return (pact: signed, declineReason: null);
  }

  // ── Bequest and graduation-battle settlement (§7.1, §7.4) ──────────────
  //
  // Both share one wire shape (settlementBundle/settlementAck: a list of
  // {permission, asset} transfer grants, grid included) because they're the
  // same underlying operation from the wire's point of view — "here are
  // perpetual transfers for these commitments." What differs is which side
  // sends, which commitments, and what local bookkeeping the receiver
  // layers on top; see the three orchestration methods below.

  /// Looks up the most recent EXISTING perpetual transfer grant for
  /// [commitmentHex] naming [currentHolderPubkeyHex] as grantee, if any, so
  /// a re-transfer's provenance chain extends a real prior chain rather than
  /// starting a new (dishonest) one. Returns an empty list for the common
  /// case — a natively-inscribed spell with no prior transfer.
  Future<List<ProvenanceStep>> _existingProvenance({
    required String commitmentHex,
    required String currentHolderPubkeyHex,
  }) async {
    final candidates = await SpellPermission.loadForCommitment(commitmentHex);
    SpellPermission? latest;
    for (final perm in candidates) {
      if (perm.kind != SpellGrantKind.transfer) continue;
      if (!_hexEq(perm.granteePubkeyHex, currentHolderPubkeyHex)) continue;
      if (latest == null || perm.grantedAt.isAfter(latest.grantedAt)) latest = perm;
    }
    return latest?.provenance ?? const [];
  }

  /// Signs perpetual transfer grants (grid included) for [commitments],
  /// resolving each to an owned [SpellAsset] in [spells], and sends them.
  /// Pure transport + signing — no chapter/record bookkeeping; see
  /// [sendBequest] / the settlement orchestration in the UI layer for that.
  Future<ApprenticeGrantResult> sendTransferBundle({
    required Identity senderIdentity,
    required List<String> commitments,
    required List<SpellAsset> spells,
  }) async {
    final senderOwnerPubkeyHex = await senderIdentity.ownerPubkeyHex();
    final byCommitment = <String, SpellAsset>{};
    for (final s in spells) {
      byCommitment[_normHex(s.commitmentHex)] = s;
    }

    final errors = <String>[];
    final grants = <Map<String, dynamic>>[];
    for (final commitment in commitments) {
      final spell = byCommitment[_normHex(commitment)];
      if (spell == null) {
        errors.add('$commitment: not found locally');
        continue;
      }
      try {
        final existingChain = await _existingProvenance(
          commitmentHex: spell.commitmentHex,
          currentHolderPubkeyHex: senderOwnerPubkeyHex,
        );
        final perm = await SpellPermission.createAndSign(
          spell: spell,
          ownerIdentity: senderIdentity,
          granteePubkeyHex: peerOwnerPubkeyHex,
          kind: SpellGrantKind.transfer,
          provenance: [
            ...existingChain,
            ProvenanceStep(pubkeyHex: senderOwnerPubkeyHex, at: DateTime.now().toUtc()),
          ],
        );
        grants.add({'permission': perm.toJson(), 'asset': spell.toJson()}); // full asset -- grid included
      } catch (e) {
        errors.add("'${spell.name}': $e");
      }
    }
    if (errors.isNotEmpty) {
      return ApprenticeGrantResult(success: false, errors: errors);
    }

    final ackFuture = _nextFrame(const {ApprenticeMsgType.settlementAck});
    _send(ApprenticeMsgType.settlementBundle, utf8.encode(jsonEncode({'grants': grants})));
    await ackFuture;

    return ApprenticeGrantResult(success: true, grantedSpellCount: grants.length, entryCount: grants.length);
  }

  /// Receives a settlementBundle, validates every transfer grant (grantee
  /// names [me], owner matches [expectedOwnerPubkeyHex], signature valid,
  /// and — the inverse of a loan's check — the asset MUST carry a non-empty
  /// grid), and saves each as a fresh, fully-owned local [SpellAsset] +
  /// perpetual [SpellPermission]. A single failing grant fails the whole
  /// bundle, same discipline as [receiveChapterBundleAndSave]. Pure
  /// transport + validation + save — no chapter/record bookkeeping; see
  /// [receiveBequestAndSave] for that layered on top.
  Future<ApprenticeReceiveResult> receiveTransferBundleAndSave({
    required Identity me,
    required String expectedOwnerPubkeyHex,
  }) async {
    final bundleFuture = _nextFrame(const {ApprenticeMsgType.settlementBundle});
    final myOwnerPubkeyHex = await me.ownerPubkeyHex();
    final frame = await bundleFuture;
    _send(ApprenticeMsgType.settlementAck, const []);

    final json = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
    final rawGrants = json['grants'] as List<dynamic>? ?? [];

    final errors = <String>[];
    final validated = <(SpellPermission, SpellAsset)>[];
    for (final raw in rawGrants) {
      final entry = raw as Map<String, dynamic>;
      final perm = SpellPermission.fromJson(entry['permission'] as Map<String, dynamic>);
      final assetJson = entry['asset'] as Map<String, dynamic>?;
      if (assetJson == null) {
        errors.add('a grant is missing its spell asset');
        continue;
      }
      final asset = SpellAsset.fromJson(assetJson);
      if (perm.kind != SpellGrantKind.transfer) {
        errors.add("grant for '${asset.name}' is not a perpetual transfer");
        continue;
      }
      if (!_hexEq(perm.granteePubkeyHex, myOwnerPubkeyHex)) {
        errors.add("grant for '${asset.name}' does not name this device as grantee");
        continue;
      }
      if (!_hexEq(perm.ownerPubkeyHex, expectedOwnerPubkeyHex)) {
        errors.add("grant for '${asset.name}' owner does not match the expected sender");
        continue;
      }
      if (!await perm.isCurrentlyUsable()) {
        errors.add("grant for '${asset.name}' signature invalid");
        continue;
      }
      if (asset.initialGrid.isEmpty) {
        errors.add("grant for '${asset.name}' is missing its grid state");
        continue;
      }
      validated.add((perm, asset));
    }
    if (errors.isNotEmpty) {
      return ApprenticeReceiveResult(success: false, errors: errors);
    }

    final now = DateTime.now().toUtc();
    final savedIds = <String>[];
    for (var i = 0; i < validated.length; i++) {
      final (perm, asset) = validated[i];
      final freshId = 'grad-${now.microsecondsSinceEpoch}-$i-${asset.id}';
      final saved = SpellAsset(
        id: freshId,
        createdAt: asset.createdAt,
        tier: asset.tier,
        t: asset.t,
        ownerPubkeyHex: asset.ownerPubkeyHex,
        manaCost: asset.manaCost,
        segmentCount: asset.segmentCount,
        dotCount: asset.dotCount,
        initialGrid: asset.initialGrid,
        proofBytes: asset.proofBytes,
        name: asset.name,
        commitmentHex: asset.commitmentHex,
        spellHashHex: asset.spellHashHex,
        formula: asset.formula,
        supremeTags: asset.supremeTags,
        isSummon: asset.isSummon,
        summonPersonality: asset.summonPersonality,
      );
      await saved.save();
      await perm.save();
      savedIds.add(freshId);
    }

    return ApprenticeReceiveResult(success: true, grantedSpellCount: savedIds.length);
  }

  /// Master side, bequeathed graduation (§7.1): sends transfer grants for
  /// [masterRecord.grantedCommitments] and, on success, closes
  /// [masterRecord] as [ApprenticeshipStatus.graduated] — a bequest always
  /// favors the apprentice, by definition.
  Future<ApprenticeGrantResult> sendBequest({
    required Identity master,
    required ApprenticeshipRecord masterRecord,
    required List<SpellAsset> spells,
  }) async {
    final result = await sendTransferBundle(
      senderIdentity: master,
      commitments: masterRecord.grantedCommitments,
      spells: spells,
    );
    if (!result.success) return result;
    final closed = masterRecord.copyWith(
      status: ApprenticeshipStatus.graduated,
      closedAt: DateTime.now().toUtc(),
    );
    await closed.save();
    return ApprenticeGrantResult(
      success: true,
      grantedSpellCount: result.grantedSpellCount,
      entryCount: result.entryCount,
      record: closed,
    );
  }

  /// Apprentice side: receives a chapter's worth of transfer grants —
  /// whether from a bequest (§7.1) or from winning a graduation battle
  /// (§7.4, "apprentice won") — and layers the chapter-specific bookkeeping
  /// on top of [receiveTransferBundleAndSave]: swaps the existing cloned
  /// chapter's entries from their old grid-withheld spells to the newly
  /// received full ones (same structure, same id — nothing about the
  /// chapter's shape changes, only what each entry points to), deletes the
  /// superseded loan permissions and withheld copies, and closes the
  /// relationship record as [ApprenticeshipStatus.graduated].
  ///
  /// Requires an existing, active apprentice-side record for
  /// [masterPubkeyHex] (`ApprenticeshipRecord.forPeer`) — fails without
  /// saving anything if there isn't one, since there would be no chapter
  /// clone to update.
  Future<ApprenticeReceiveResult> receiveBequestAndSave({
    required Identity me,
    required String masterPubkeyHex,
  }) async {
    // MUST run first and unconditionally -- this is what reads the
    // settlementBundle frame and sends settlementAck. The sender's
    // sendTransferBundle is awaiting that ack; any early return before this
    // call (e.g. gating on ApprenticeshipRecord.forPeer first, as an
    // earlier version of this method did) leaves the frame unread and the
    // sender hanging forever. Local bookkeeping problems are handled AFTER
    // the wire handshake completes, never by skipping it.
    final received = await receiveTransferBundleAndSave(me: me, expectedOwnerPubkeyHex: masterPubkeyHex);
    if (!received.success) return received;

    final existing = await ApprenticeshipRecord.forPeer(masterPubkeyHex, side: ApprenticeSide.apprentice);
    if (existing == null ||
        existing.side != ApprenticeSide.apprentice ||
        existing.status != ApprenticeshipStatus.active ||
        existing.localChapterId == null) {
      // The transfer itself is genuine and already saved (same reasoning as
      // accepting an unsolicited trade transfer elsewhere in this app) --
      // there is just no local apprenticeship record to close or chapter
      // clone to update. Report success with what was actually received.
      return ApprenticeReceiveResult(success: true, grantedSpellCount: received.grantedSpellCount);
    }

    final newLocalSpells = await SpellAsset.loadAll();
    final newByCommitment = <String, SpellAsset>{};
    for (final s in newLocalSpells) {
      // Only ours from THIS bundle -- reusing the freshly-loaded list is
      // simplest, and picking whichever has a full grid for a granted
      // commitment is unambiguous (a withheld copy has none).
      if (existing.grantedCommitments.any((c) => _hexEq(c, s.commitmentHex)) && s.initialGrid.isNotEmpty) {
        newByCommitment[_normHex(s.commitmentHex)] = s;
      }
    }

    final chapter = await ChapterAsset.loadById(existing.localChapterId!);
    if (chapter == null) {
      return const ApprenticeReceiveResult(success: false, errors: ['cloned chapter missing on disk']);
    }
    final oldById = {for (final s in newLocalSpells) s.id: s};
    final newEntries = chapter.entries.map((e) {
      final oldSpell = oldById[e.spellId];
      final normed = oldSpell != null ? _normHex(oldSpell.commitmentHex) : null;
      final upgraded = normed != null ? newByCommitment[normed] : null;
      return upgraded == null ? e : ChapterEntry(spellId: upgraded.id, summonPersonality: e.summonPersonality);
    }).toList();
    final armorId = chapter.armorSpellId;
    final upgradedArmor = armorId == null
        ? null
        : newByCommitment[_normHex(oldById[armorId]?.commitmentHex ?? '')];
    await ChapterAsset(
      id: chapter.id,
      name: chapter.name,
      createdAt: chapter.createdAt,
      entries: newEntries,
      artifacts: chapter.artifacts,
      // The armor binding survives graduation, following the same
      // commitment-keyed upgrade as the entries above when the armor itself
      // was one of the received spells.
      armorSpellId: upgradedArmor?.id ?? armorId,
    ).save();

    await deleteApprenticePermissionsByIds(existing.permissionIds);
    await deleteApprenticeSpellAssetsByIds(existing.receivedSpellIds);

    final closed = existing.copyWith(
      permissionIds: const [],
      receivedSpellIds: newByCommitment.values.map((s) => s.id).toList(),
      status: ApprenticeshipStatus.graduated,
      closedAt: DateTime.now().toUtc(),
    );
    await closed.save();

    return ApprenticeReceiveResult(success: true, record: closed, grantedSpellCount: received.grantedSpellCount);
  }

  /// Apprentice side, losing a graduation battle (§7.4, "master won"): sends
  /// transfer grants for [pact.stakeCommitments] to the master. On success,
  /// tears down the loan (deletes permissions, withheld assets, and the
  /// cloned chapter — the same §5.8 cleanup as [ApprenticeshipRecord.abandon])
  /// and closes the record as [ApprenticeshipStatus.graduatedByLoss]. Per
  /// §2.5 decision 13, the apprentice KEEPS their staked spells — this only
  /// sends copies; nothing local to the stakes is ever deleted.
  Future<ApprenticeGrantResult> sendStakeSettlement({
    required Identity apprentice,
    required SignedGraduationPact pact,
    required List<SpellAsset> spells,
  }) async {
    final result = await sendTransferBundle(
      senderIdentity: apprentice,
      commitments: pact.pact.stakeCommitments,
      spells: spells,
    );
    if (!result.success) return result;

    final existing =
        await ApprenticeshipRecord.forPeer(pact.pact.masterPubkeyHex, side: ApprenticeSide.apprentice);
    ApprenticeshipRecord? closed;
    if (existing != null &&
        existing.side == ApprenticeSide.apprentice &&
        existing.status == ApprenticeshipStatus.active) {
      await deleteApprenticePermissionsByIds(existing.permissionIds);
      await deleteApprenticeSpellAssetsByIds(existing.receivedSpellIds);
      final chapterId = existing.localChapterId;
      if (chapterId != null) {
        if (await ChapterAsset.loadActiveChapterId() == chapterId) {
          await ChapterAsset.saveActiveChapterId(null);
        }
        final chapter = await ChapterAsset.loadById(chapterId);
        await chapter?.delete();
      }
      closed = existing.copyWith(
        permissionIds: const [],
        receivedSpellIds: const [],
        status: ApprenticeshipStatus.graduatedByLoss,
        closedAt: DateTime.now().toUtc(),
      );
      await closed.save();
    }

    return ApprenticeGrantResult(
      success: true,
      grantedSpellCount: result.grantedSpellCount,
      entryCount: result.entryCount,
      record: closed,
    );
  }

  /// Master side, winning a graduation battle (§7.4, "master won"): receives
  /// the apprentice's staked spells (plain transfers — no chapter bookkeeping
  /// needed, since the master never had a clone of them) and closes its own
  /// [ApprenticeSide.master] record for this apprentice as
  /// [ApprenticeshipStatus.graduatedByLoss] — same status value as the
  /// apprentice's own closed record, since it describes the shared outcome
  /// of the SAME battle, not a subjective "who lost from my own point of
  /// view" framing. Silently skips the record-closing step if this device
  /// has no master-side record for the peer (defensive; should not happen
  /// in the normal flow).
  Future<ApprenticeReceiveResult> receiveStakeSettlementAndSave({
    required Identity master,
    required String apprenticePubkeyHex,
  }) async {
    final received = await receiveTransferBundleAndSave(me: master, expectedOwnerPubkeyHex: apprenticePubkeyHex);
    if (!received.success) return received;

    final existing = await ApprenticeshipRecord.forPeer(apprenticePubkeyHex, side: ApprenticeSide.master);
    ApprenticeshipRecord? closed;
    if (existing != null && existing.status == ApprenticeshipStatus.active) {
      closed = existing.copyWith(status: ApprenticeshipStatus.graduatedByLoss, closedAt: DateTime.now().toUtc());
      await closed.save();
    }

    return ApprenticeReceiveResult(success: true, record: closed, grantedSpellCount: received.grantedSpellCount);
  }
}
