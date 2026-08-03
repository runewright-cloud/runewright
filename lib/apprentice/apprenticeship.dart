// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprenticeship.dart — the Master/Apprentice relationship record
// (docs/MASTER_APPRENTICE_PLAN.md §5.1).
//
// A device holds at most one ApprenticeshipRecord per relationship it is a
// party to: one with side == apprentice for the master it studies under
// (at most one active at a time -- see activeMastership), and zero or more
// with side == master for each apprentice it teaches. Both sides persist
// their OWN half of the relationship independently; there is no shared or
// server-synced record.
//
// The 30-day clock (kApprenticeshipTermDays) is NOT a second enforcement
// layer -- it is exactly the expiresAt already carried by every loan
// SpellPermission this apprenticeship granted (see apprentice_session.dart).
// Renewal means re-signing that bundle in a fresh session; isLapsed here is
// a convenience read of the same clock, not an independent one.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../spells/chapter_asset.dart';
import '../spells/spell_asset.dart';
import '../spells/spell_permission.dart';

/// The renewal term every apprenticeship loan grant carries
/// (docs/MASTER_APPRENTICE_PLAN.md §2.3 decision 6). Not configurable —
/// changing this is a design decision, not a per-relationship setting.
const int kApprenticeshipTermDays = 30;

/// How close to lapsing an apprenticeship must be before the main menu nags
/// about it (docs/MASTER_APPRENTICE_PLAN.md §8). This is the ONLY reminder
/// that exists — there is no push channel and no server, so a player who
/// never opens the app simply lapses.
const int kApprenticeshipNagDays = 7;

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

/// Deletes each locally-persisted [SpellAsset] whose id is in [ids]. Used
/// wherever an apprenticeship's grid-withheld loan copies need cleanup —
/// abandonment ([ApprenticeshipRecord.abandon]) and renewal supersession
/// (apprentice_session.dart's `receiveChapterBundleAndSave`). [SpellAsset]
/// only exposes an instance `delete()`, so this loads everything and
/// filters rather than constructing a bare id-only instance.
Future<void> deleteApprenticeSpellAssetsByIds(List<String> ids) async {
  if (ids.isEmpty) return;
  final idSet = ids.toSet();
  for (final asset in await SpellAsset.loadAll()) {
    if (idSet.contains(asset.id)) await asset.delete();
  }
}

/// Deletes each locally-persisted [SpellPermission] whose id is in [ids].
/// See [deleteApprenticeSpellAssetsByIds]'s doc comment — same shape, same
/// reason (no id-only delete seam on [SpellPermission] either).
Future<void> deleteApprenticePermissionsByIds(List<String> ids) async {
  if (ids.isEmpty) return;
  final idSet = ids.toSet();
  for (final perm in await SpellPermission.loadAll()) {
    if (idSet.contains(perm.id)) await perm.delete();
  }
}

/// Which side of the relationship THIS device's identity plays. A device
/// studying under a master persists side == apprentice; a device teaching
/// persists side == master (one record per apprentice, since a master may
/// have unlimited apprentices — §2.2).
enum ApprenticeSide { master, apprentice }

enum ApprenticeshipStatus {
  /// Loans current or lapsed-but-not-yet-closed — see [ApprenticeshipRecord.isLapsed].
  active,

  /// The apprentice walked away (§2.4 decision 9) — apprentice-side only.
  abandoned,

  /// Ended in the apprentice's favor: a bequest, or winning a graduation
  /// battle (§2.4 decisions 10/11, §7).
  graduated,

  /// Ended in the master's favor by winning a graduation battle (§7.4).
  graduatedByLoss,
}

class ApprenticeshipRecord {
  ApprenticeshipRecord({
    required this.id,
    required this.side,
    required this.masterPubkeyHex,
    required this.apprenticePubkeyHex,
    required this.chapterName,
    required this.sourceChapterId,
    this.localChapterId,
    this.grantedCommitments = const [],
    this.permissionIds = const [],
    this.receivedSpellIds = const [],
    required this.startedAt,
    required this.lastRenewedAt,
    required this.expiresAt,
    this.status = ApprenticeshipStatus.active,
    this.closedAt,
  });

  final String id;
  final ApprenticeSide side;
  final String masterPubkeyHex;
  final String apprenticePubkeyHex;

  /// Display name of the master's chapter at grant/last-renewal time.
  final String chapterName;

  /// Master side: the local `ChapterAsset.id` that was lent.
  final String sourceChapterId;

  /// Apprentice side: the local `ChapterAsset.id` of the clone
  /// (`apprentice_session.dart`'s `receiveChapterBundleAndSave`). Null on
  /// the master side, and briefly null on the apprentice side only during
  /// construction of a not-yet-saved record.
  final String? localChapterId;

  /// The distinct non-Basic commitments granted in the current snapshot —
  /// what a renewal compares against to find removed/added spells (§5.7).
  final List<String> grantedCommitments;

  /// Apprentice side: the `SpellPermission.id`s to delete on abandonment or
  /// supersession-by-renewal. Empty on the master side (the master doesn't
  /// hold a copy of grants it issued).
  final List<String> permissionIds;

  /// Apprentice side: the local `SpellAsset.id`s of the grid-withheld
  /// spells received, for the same delete-on-abandon/renewal bookkeeping.
  final List<String> receivedSpellIds;

  final DateTime startedAt;
  final DateTime lastRenewedAt;

  /// == every current grant's `SpellPermission.expiresAt`. The single
  /// source of truth for [isLapsed] — see this file's header comment.
  final DateTime expiresAt;

  final ApprenticeshipStatus status;

  /// Set when [status] transitions away from [ApprenticeshipStatus.active].
  final DateTime? closedAt;

  // ── Derived ────────────────────────────────────────────────────────────

  /// True iff still [ApprenticeshipStatus.active] but the clock has run out
  /// — a live read against [now] (defaults to the current UTC time), never
  /// a persisted flag. Mirrors [SpellPermission.isExpired]'s reasoning: a
  /// lapsed apprenticeship must drop out the moment it lapses, not just
  /// when someone happened to look last.
  bool isLapsed({DateTime? now}) {
    if (status != ApprenticeshipStatus.active) return false;
    final clock = now ?? DateTime.now().toUtc();
    return !clock.isBefore(expiresAt);
  }

  /// Whole days remaining until [expiresAt], floored at 0. Meaningless
  /// (returns 0) once [isLapsed] is true.
  int daysRemaining({DateTime? now}) {
    final clock = now ?? DateTime.now().toUtc();
    final remaining = expiresAt.difference(clock).inDays;
    return remaining < 0 ? 0 : remaining;
  }

  // ── Updates ────────────────────────────────────────────────────────────

  ApprenticeshipRecord copyWith({
    String? chapterName,
    String? localChapterId,
    List<String>? grantedCommitments,
    List<String>? permissionIds,
    List<String>? receivedSpellIds,
    DateTime? lastRenewedAt,
    DateTime? expiresAt,
    ApprenticeshipStatus? status,
    DateTime? closedAt,
  }) =>
      ApprenticeshipRecord(
        id: id,
        side: side,
        masterPubkeyHex: masterPubkeyHex,
        apprenticePubkeyHex: apprenticePubkeyHex,
        chapterName: chapterName ?? this.chapterName,
        sourceChapterId: sourceChapterId,
        localChapterId: localChapterId ?? this.localChapterId,
        grantedCommitments: grantedCommitments ?? this.grantedCommitments,
        permissionIds: permissionIds ?? this.permissionIds,
        receivedSpellIds: receivedSpellIds ?? this.receivedSpellIds,
        startedAt: startedAt,
        lastRenewedAt: lastRenewedAt ?? this.lastRenewedAt,
        expiresAt: expiresAt ?? this.expiresAt,
        status: status ?? this.status,
        closedAt: closedAt ?? this.closedAt,
      );

  /// Apprentice-side, local-only walk-away (§2.4 decision 9, §5.8): deletes
  /// the loan permissions, the grid-withheld spell copies, and the cloned
  /// chapter, clearing it as the active chapter first if it was one. The
  /// record itself is kept (not deleted) — it's the relationship's lineage
  /// — with [ApprenticeshipStatus.abandoned] and [closedAt] set. There is no
  /// notification to the master; the caller's UI is responsible for making
  /// that limitation explicit before this is called (no channel exists to
  /// notify over — the master learns of it only at the next lapse or
  /// meeting).
  ///
  /// No-ops the cleanup (but still closes the record) if called on a
  /// [ApprenticeSide.master] record — abandonment is only ever a thing the
  /// apprentice does to themselves.
  Future<ApprenticeshipRecord> abandon() async {
    if (side == ApprenticeSide.apprentice) {
      await deleteApprenticePermissionsByIds(permissionIds);
      await deleteApprenticeSpellAssetsByIds(receivedSpellIds);
      final chapterId = localChapterId;
      if (chapterId != null) {
        if (await ChapterAsset.loadActiveChapterId() == chapterId) {
          await ChapterAsset.saveActiveChapterId(null);
        }
        final chapter = await ChapterAsset.loadById(chapterId);
        await chapter?.delete();
      }
    }
    final closed = copyWith(
      status: ApprenticeshipStatus.abandoned,
      closedAt: DateTime.now().toUtc(),
    );
    await closed.save();
    return closed;
  }

  // ── Serialization ──────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'id': id,
        'side': side.name,
        'masterPubkeyHex': masterPubkeyHex,
        'apprenticePubkeyHex': apprenticePubkeyHex,
        'chapterName': chapterName,
        'sourceChapterId': sourceChapterId,
        if (localChapterId != null) 'localChapterId': localChapterId,
        'grantedCommitments': grantedCommitments,
        'permissionIds': permissionIds,
        'receivedSpellIds': receivedSpellIds,
        'startedAt': startedAt.toIso8601String(),
        'lastRenewedAt': lastRenewedAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'status': status.name,
        if (closedAt != null) 'closedAt': closedAt!.toIso8601String(),
      };

  static ApprenticeshipRecord fromJson(Map<String, dynamic> json) => ApprenticeshipRecord(
        id: json['id'] as String,
        side: ApprenticeSide.values.byName(json['side'] as String),
        masterPubkeyHex: json['masterPubkeyHex'] as String,
        apprenticePubkeyHex: json['apprenticePubkeyHex'] as String,
        chapterName: json['chapterName'] as String,
        sourceChapterId: json['sourceChapterId'] as String,
        localChapterId: json['localChapterId'] as String?,
        grantedCommitments: (json['grantedCommitments'] as List<dynamic>? ?? []).cast<String>(),
        permissionIds: (json['permissionIds'] as List<dynamic>? ?? []).cast<String>(),
        receivedSpellIds: (json['receivedSpellIds'] as List<dynamic>? ?? []).cast<String>(),
        startedAt: DateTime.parse(json['startedAt'] as String),
        lastRenewedAt: DateTime.parse(json['lastRenewedAt'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        status: ApprenticeshipStatus.values.byName(json['status'] as String),
        closedAt: json['closedAt'] != null ? DateTime.parse(json['closedAt'] as String) : null,
      );

  // ── Persistence ────────────────────────────────────────────────────────

  static Future<Directory> _apprenticeshipsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/apprenticeships');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> save() async {
    final dir = await _apprenticeshipsDir();
    final file = File('${dir.path}/$id.json');
    await file.writeAsString(jsonEncode(toJson()));
    return file;
  }

  Future<void> delete() async {
    final dir = await _apprenticeshipsDir();
    final file = File('${dir.path}/$id.json');
    if (await file.exists()) await file.delete();
  }

  static Future<ApprenticeshipRecord?> loadById(String id) async {
    final dir = await _apprenticeshipsDir();
    final file = File('${dir.path}/$id.json');
    if (!await file.exists()) return null;
    return fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
  }

  static Future<List<ApprenticeshipRecord>> loadAll() async {
    final dir = await _apprenticeshipsDir();
    final entries = await dir.list().where((e) => e.path.endsWith('.json')).toList();
    final records = <ApprenticeshipRecord>[];
    for (final entry in entries) {
      final contents = await File(entry.path).readAsString();
      records.add(fromJson(jsonDecode(contents) as Map<String, dynamic>));
    }
    return records;
  }

  /// This device's one active [ApprenticeSide.apprentice] record, if any.
  /// Non-null blocks BOTH accepting a second master (§2.2 decision 4) and
  /// offering an apprenticeship of one's own (§2.2 decision 4: an apprentice
  /// may not take an apprentice).
  static Future<ApprenticeshipRecord?> activeMastership() async {
    final all = await loadAll();
    for (final r in all) {
      if (r.side == ApprenticeSide.apprentice && r.status == ApprenticeshipStatus.active) {
        return r;
      }
    }
    return null;
  }

  /// The active mastership if it is within [kApprenticeshipNagDays] of
  /// lapsing, or has already lapsed; null otherwise (including when there is
  /// no mastership at all). Drives the main menu's days-remaining nag (§8).
  static Future<ApprenticeshipRecord?> expiringMastership({DateTime? now}) async {
    final record = await activeMastership();
    if (record == null) return null;
    if (record.isLapsed(now: now)) return record;
    return record.daysRemaining(now: now) < kApprenticeshipNagDays ? record : null;
  }

  /// This device's [ApprenticeSide.master] records — the apprentices it
  /// teaches, of which there may be unlimited (§2.2 decision 4).
  static Future<List<ApprenticeshipRecord>> apprentices() async {
    final all = await loadAll();
    return all.where((r) => r.side == ApprenticeSide.master).toList();
  }

  /// The existing record (of either role) naming [peerPubkeyHex] as the
  /// other party, on MY [side] of the relationship — how a renewal offer is
  /// matched to its prior grant (§5.7) rather than creating a duplicate
  /// relationship. Prefers an [ApprenticeshipStatus.active] match; falls
  /// back to the most recently started closed record (a lapsed record is
  /// still `active` and is covered by the first branch — see [isLapsed]).
  ///
  /// [side] is required, not inferred, and matching checks ONLY the field
  /// that names the OTHER party for that side (apprentice-side: does
  /// `masterPubkeyHex` name [peerPubkeyHex]; master-side: does
  /// `apprenticePubkeyHex`). A device holds at most one relevant record per
  /// (peer, side) in normal operation, but nothing stops the SAME pubkey
  /// from appearing as both someone's master-side and apprentice-side peer
  /// on one device (e.g. two independent relationships, or — as multi-
  /// identity test harnesses can construct — the very same key playing both
  /// roles); an unfiltered lookup could then silently return the wrong
  /// record. Always pass the side the caller actually means.
  static Future<ApprenticeshipRecord?> forPeer(String peerPubkeyHex, {required ApprenticeSide side}) async {
    final all = await loadAll();
    ApprenticeshipRecord? bestClosed;
    for (final r in all) {
      if (r.side != side) continue;
      final otherPartyHex = side == ApprenticeSide.apprentice ? r.masterPubkeyHex : r.apprenticePubkeyHex;
      if (!_hexEq(otherPartyHex, peerPubkeyHex)) continue;
      if (r.status == ApprenticeshipStatus.active) return r;
      if (bestClosed == null || r.startedAt.isAfter(bestClosed.startedAt)) {
        bestClosed = r;
      }
    }
    return bestClosed;
  }
}

/// The apprentice-side facts the library UI needs in order to *label* what
/// this device holds from a master, and to keep the cloned chapter read-only
/// (docs/MASTER_APPRENTICE_PLAN.md §8).
///
/// Presentation support only. It grants nothing and enforces nothing at the
/// authorization layer — the right to cast a loaned spell still comes from
/// the signed [SpellPermission] alone (`spell_authorization.dart`), and a
/// device with no apprenticeship record at all simply gets [none], with every
/// predicate false and every surface unchanged.
class MasterLoanView {
  const MasterLoanView(this.record);

  /// The "no master" case — safe to use as a synchronous default while the
  /// real value is still loading.
  static const MasterLoanView none = MasterLoanView(null);

  /// The active [ApprenticeSide.apprentice] record, or null. There is at most
  /// one (§2.2 decision 4), which is why this can be a single record rather
  /// than a list.
  final ApprenticeshipRecord? record;

  static Future<MasterLoanView> load() async =>
      MasterLoanView(await ApprenticeshipRecord.activeMastership());

  bool get hasMaster => record != null;

  /// True for the cloned chapter this device received from its master
  /// (`ApprenticeshipRecord.localChapterId`). That chapter is rewritten
  /// wholesale by the next renewal (§5.7), so anything the apprentice adds to
  /// or removes from it is silently lost — hence read-only in the UI.
  bool isChapterFromMaster(String? chapterId) =>
      chapterId != null && record?.localChapterId == chapterId;

  /// True for a grid-withheld [SpellAsset] saved by the apprenticeship bundle
  /// (as opposed to an ordinary Commune/Trade loan of the same shape).
  bool isSpellFromMaster(String spellId) =>
      record?.receivedSpellIds.contains(spellId) ?? false;

  /// True for a loan [SpellPermission] issued by this apprenticeship.
  bool isPermissionFromMaster(String permissionId) =>
      record?.permissionIds.contains(permissionId) ?? false;

  /// "12 days remain" / "Lapsed" — the clock line shown wherever the
  /// apprenticeship surfaces. Empty when there is no master.
  String remainingLabel({DateTime? now}) {
    final r = record;
    if (r == null) return '';
    if (r.isLapsed(now: now)) return 'Lapsed';
    final days = r.daysRemaining(now: now);
    return days == 1 ? '1 day remains' : '$days days remain';
  }
}
