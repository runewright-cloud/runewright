// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_wire_codec.dart — the battle protocol's serialization boundary.
//
// ## What this is
//
// Every rule about what bytes represent a battle-protocol value, and nothing
// else. Field order, integer widths and endianness, length prefixes, sentinel
// and null encodings, the fixed-size preambles a decoder guards on, and the
// exact way each codec degrades when handed a payload it cannot fully read.
//
// ## What this is NOT
//
// It owns no BattleSession, no BattleState, and no identity. It sends no
// forfeit, awaits nothing, mutates nothing, and — the load-bearing part —
// makes no trust decision whatsoever.
//
// A codec here answers exactly one question: *what value do these bytes
// represent?* It never answers *should this value be believed?* Those are
// different questions with different answers, and conflating them is how a
// decoder ends up quietly authenticating a field by refusing to parse the
// values an attacker would choose. The layering is:
//
//     bytes → decoded claim → protocol/trust verification → resolution
//
// never `bytes → codec decides what is trustworthy`. So `decodeAction` will
// happily hand back a spell whose declared formula is a lie, and
// [ActionWire.readSummonBytes] will hand back `isSummon: true` for a spell
// that certifies nothing of the sort (M4.19 — see
// test/battle/engine/summon_declaration_trust_test.dart, which characterizes
// that gap deliberately unfixed). Deciding what to do about either is
// `TurnLoop`'s and `PeerCastVerifier`'s job, above this line.
//
// ## Compatibility
//
// These bytes are the contract between two devices that may be running
// different builds. `kBattleProtocolVersion` (match_discovery.dart, currently
// **5**) is what catches a mismatch at handshake; nothing here may change
// without bumping it, because the failure mode otherwise is a mid-match
// state-hash forfeit that looks like a cheating accusation.
//
// Two consequences worth stating outright:
//
//   * **Enum declaration order is wire-visible** wherever an index is
//     transmitted — [SummonPersonality] (summon bytes) and [AccoutrementKind]
//     (artifact activation). Append only; never reorder or remove.
//   * **Truncation is tolerated, not rejected**, almost everywhere. A short
//     payload reads as the field's default rather than throwing, so a peer
//     built before a field existed still produces a turn both devices agree
//     on. The protocol-version gate is what actually prevents version skew
//     reaching a decoder; this tolerance is the second line, chosen so that
//     the failure is a boring turn rather than a forfeit.
//
// Both directions are pinned byte-for-byte by
// test/battle/engine/wire_format_characterization_test.dart (encode) and
// test/battle/engine/wire_decode_characterization_test.dart (decode). A diff
// in either is a protocol break, not a test that needs re-blessing.
//
// ## Shape of this file
//
// One small class per message, not one generic framework. The whole point is
// that a reviewer can read a single class top to bottom and see the field
// order. Messages that merely happen to contain similar primitives are kept
// apart; the one shared envelope ([SealedExchangeFrames]) is shared because
// the two divination exchanges were *designed* to use the same transport
// shape, not because their bytes coincidentally rhyme.

import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import '../models/minion.dart' show SummonPersonality;
import '../models/wizard_avatar.dart' show AccoutrementKind;
import 'book_commitment.dart' show MembershipProof;
import 'turn_actions.dart';
import '../../sorcerer/incantation_recall.dart';

// ── Primitives ────────────────────────────────────────────────────────────────

/// Integer, coordinate and hex-string conversions shared by every codec below.
///
/// All multi-byte integers on this wire are big-endian. Coordinates are the
/// only signed values: `q` and `r` are 16-bit two's complement, which is what
/// makes a tile at `q = -1` encode as `ffff` rather than something a naive
/// unsigned reader would misplace on the far side of the battlefield.
class WireBytes {
  const WireBytes._();

  static Uint8List be2(int v) => Uint8List(2)
    ..[0] = (v >> 8) & 0xFF
    ..[1] = v & 0xFF;

  static Uint8List be4(int v) => Uint8List(4)
    ..[0] = (v >> 24) & 0xFF
    ..[1] = (v >> 16) & 0xFF
    ..[2] = (v >> 8) & 0xFF
    ..[3] = v & 0xFF;

  static int readBe2(Uint8List data, int offset) =>
      (data[offset] << 8) | data[offset + 1];

  static int readBe4(Uint8List data, int offset) =>
      (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];

  /// Signed 16-bit big-endian — the coordinate reader.
  static int readInt16(Uint8List data, int offset) {
    final u = (data[offset] << 8) | data[offset + 1];
    return u >= 0x8000 ? u - 0x10000 : u;
  }

  static Uint8List encodeCoord(HexCoord h) => Uint8List(4)
    ..[0] = (h.q >> 8) & 0xFF
    ..[1] = h.q & 0xFF
    ..[2] = (h.r >> 8) & 0xFF
    ..[3] = h.r & 0xFF;

  static HexCoord decodeCoord(Uint8List data, int offset) =>
      HexCoord(readInt16(data, offset), readInt16(data, offset + 2));

  /// Parses a `0x`-prefixed or bare hex string. Tolerates a short string by
  /// producing a short result — a commitment shorter than 32 bytes therefore
  /// encodes as fewer than 32 bytes, which the decoder will read past. Only
  /// test fixtures ever produce one; real commitments are always full width.
  static Uint8List hexToBytes(String hex) {
    final s = hex.startsWith('0x') ? hex.substring(2) : hex;
    final result = Uint8List(s.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  /// Bare lowercase hex, no `0x`.
  static String hex(Iterable<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// `0x`-prefixed lowercase hex — the form commitments and Merkle siblings
  /// are carried in everywhere off the wire.
  static String hex0x(Iterable<int> bytes) => '0x${hex(bytes)}';
}

// ── Main-phase action ─────────────────────────────────────────────────────────

/// The proof tail appended to a spell action, resolved by the caller.
///
/// The codec knows the tail's *layout*; it does not know which chapter
/// position a spell was cast from, which is a fact about local bookkeeping
/// (hand slots, duplicate commitments) and stays in `TurnLoop`. This callback
/// is that seam: return the membership proof for [spell], or null if none can
/// be produced (which encodes as depth 0).
typedef MembershipProofResolver = MembershipProof? Function(
  SpellAsset spell,
  int? handIndex,
);

/// The main-phase action payload — the one that is committed to before
/// entropy is revealed, and therefore the one whose bytes feed a hash.
///
/// Wire encoding (see turn_loop.dart's header for the phase context):
///
///   Pass:     [0x00]
///   Spell:    [0x01][commit:32][t:2][q:2][r:2][formula_len:2][formula_utf8:N]
///             [name_len:2][name_utf8:N][isPotent:1][isVelocity:1]
///             [isEfficiency:1][hasConveyor:1]([q:2][r:2] iff hasConveyor)
///             [isSummon:1][personality:1]
///             (proof tail, iff the caster has a committed chapter)
///             (recall suffix, iff vocal components are on)
///   Mystery:  [0x03][commit:32][t:2][formula_len:2][formula_utf8:N]
///             [name_len:2][name_utf8:N][mysteryCommit:32][isImmediate:1]
///             ([q:2][r:2][nonce:16] iff isImmediate)
///             [isPotent:1][isVelocity:1][isSummon:1][personality:1]
///             (proof tail)(recall suffix)
///   Dash:     [0x04]
///   Meditate: [0x05]
///
/// A Mystery cast carries no plaintext target until it fires — that asymmetry
/// with the 0x01 form is the whole mechanic, and it is why
/// [splitActionTarget] finds a target leaf for one and not the other.
class ActionWire {
  const ActionWire._();

  /// Appends the two summon fields: `[isSummon:1][personalityIndex:1]`.
  ///
  /// Without these a summon cast arrived at the opponent as an ordinary
  /// incantation — the caster spawned a creature, the verifier resolved
  /// formula effects, and the match forfeited on the turn's state hash. See
  /// M4_findings M4.16; peer_summon_replication_test.dart is the regression.
  ///
  /// The personality travels as a [SummonPersonality] **index**, not its name:
  /// one byte instead of a length-prefixed string, and it cannot carry an
  /// arbitrary value. The cost is that **the enum's declaration order is now
  /// wire-visible — never reorder or remove a case, only append.** Same rule
  /// the element order already lives under (CLAUDE.md).
  ///
  /// Neither byte is certified by anything (M4.19). This function's job is to
  /// transcribe what the author declared, not to audit it.
  static void appendSummonBytes(BytesBuilder buf, SpellAsset spell) {
    buf.addByte(spell.isSummon ? 1 : 0);
    final idx = SummonPersonality.values
        .indexWhere((p) => p.name == spell.summonPersonality);
    buf.addByte(idx < 0 ? SummonPersonality.aggressive.index : idx);
  }

  /// Reads what [appendSummonBytes] wrote, tolerating a truncated buffer the
  /// same way every other field here does.
  static ({bool isSummon, String personality}) readSummonBytes(
    Uint8List bytes,
    int pos,
  ) {
    final isSummon = pos < bytes.length && bytes[pos] == 1;
    final rawIdx = pos + 1 < bytes.length ? bytes[pos + 1] : 0;
    // An out-of-range index means a peer built by a version that appended a
    // personality this build does not have. Falling back keeps both devices
    // agreeing on SOMETHING rather than throwing, and the protocol-version
    // gate is what actually prevents the mismatch reaching here.
    final personality = rawIdx < SummonPersonality.values.length
        ? SummonPersonality.values[rawIdx].name
        : SummonPersonality.aggressive.name;
    return (isSummon: isSummon, personality: personality);
  }

  /// Encode a [TurnAction] to bytes for commitment hashing and wire
  /// transmission.
  ///
  /// [membershipProofFor] non-null means "this caster has a committed
  /// chapter": spell actions then carry the trailing proof tail
  /// ([appendSpellProofTail]). Null omits the tail entirely, which is what a
  /// solo or unbooked session sends.
  ///
  /// [isVocalComponents] gates the trailing recall suffix. It is a game-mode
  /// flag, not a protocol version — a wizard-mode payload and a sorcerer-mode
  /// payload are both valid protocol-5 payloads, and the receiver knows which
  /// to expect because the mode is agreed at match setup.
  static Uint8List encodeAction(
    TurnAction action, {
    required bool isVocalComponents,
    MembershipProofResolver? membershipProofFor,
  }) {
    final buf = BytesBuilder();
    switch (action) {
      case PassAction():
        buf.addByte(0x00);

      case SpellCastAction(
        :final spell,
        :final targetHex,
        :final isPotent,
        :final isVelocity,
        :final isEfficiency,
        :final recall,
        :final conveyorDirection,
        :final handIndex,
      ):
        buf.addByte(0x01);
        buf.add(WireBytes.hexToBytes(spell.commitmentHex));
        buf.add(WireBytes.be2(spell.t));
        buf.add(WireBytes.encodeCoord(targetHex));
        final formulaStr = spell.formula.join(',');
        final formulaBytes = utf8.encode(formulaStr);
        buf.add(WireBytes.be2(formulaBytes.length));
        buf.add(formulaBytes);
        final nameBytes = utf8.encode(spell.name);
        buf.add(WireBytes.be2(nameBytes.length));
        buf.add(nameBytes);
        buf.addByte(isPotent ? 1 : 0);
        buf.addByte(isVelocity ? 1 : 0);
        buf.addByte(isEfficiency ? 1 : 0);
        buf.addByte(conveyorDirection != null ? 1 : 0);
        if (conveyorDirection != null) {
          buf.add(WireBytes.encodeCoord(conveyorDirection));
        }
        appendSummonBytes(buf, spell);
        appendSpellProofTail(buf, spell, handIndex, membershipProofFor);
        if (isVocalComponents) appendSorcererBytes(buf, recall);

      case DashAction():
        buf.addByte(0x04);

      case MeditateAction():
        buf.addByte(0x05);

      case MysterySpellCastAction(
        :final spell,
        :final mysteryCommitment,
        :final immediateTarget,
        :final immediateNonce,
        :final isPotent,
        :final isVelocity,
        :final recall,
        :final handIndex,
      ):
        buf.addByte(0x03);
        buf.add(WireBytes.hexToBytes(spell.commitmentHex));
        buf.add(WireBytes.be2(spell.t));
        final formulaStr = spell.formula.join(',');
        final formulaBytes = utf8.encode(formulaStr);
        buf.add(WireBytes.be2(formulaBytes.length));
        buf.add(formulaBytes);
        final nameBytes3 = utf8.encode(spell.name);
        buf.add(WireBytes.be2(nameBytes3.length));
        buf.add(nameBytes3);
        buf.add(mysteryCommitment);
        final isImmediate = immediateTarget != null && immediateNonce != null;
        buf.addByte(isImmediate ? 1 : 0);
        if (isImmediate) {
          buf.add(WireBytes.encodeCoord(immediateTarget));
          buf.add(immediateNonce);
        }
        buf.addByte(isPotent ? 1 : 0);
        buf.addByte(isVelocity ? 1 : 0);
        appendSummonBytes(buf, spell);
        appendSpellProofTail(buf, spell, handIndex, membershipProofFor);
        if (isVocalComponents) appendSorcererBytes(buf, recall);
    }
    return buf.toBytes();
  }

  /// Appends `[proof_len:4][proof_bytes:N][merkle_depth:1][path:depth*(32+1)]`
  /// to [buf] for the given [spell], but only when [membershipProofFor] is
  /// non-null (i.e. the caster has a committed chapter to prove against).
  ///
  /// [handIndex] is passed through to the resolver untouched: which position
  /// a duplicate-holding hand cast from is local bookkeeping, not framing
  /// (docs/BASIC_SPELLS_PLAN.md §7).
  ///
  /// A resolver that returns null, or a proof with no siblings, writes depth
  /// 0 — the single-spell-chapter case, where the leaf is the root.
  static void appendSpellProofTail(
    BytesBuilder buf,
    SpellAsset spell,
    int? handIndex,
    MembershipProofResolver? membershipProofFor,
  ) {
    if (membershipProofFor == null || spell.proofBytes.isEmpty) return;
    buf.add(WireBytes.be4(spell.proofBytes.length));
    buf.add(spell.proofBytes);
    final proof = membershipProofFor(spell, handIndex);
    if (proof == null || proof.siblings.isEmpty) {
      buf.addByte(0); // depth 0: leaf is the only node (single-spell chapter)
      return;
    }
    buf.addByte(proof.siblings.length);
    for (var i = 0; i < proof.siblings.length; i++) {
      buf.add(WireBytes.hexToBytes(proof.siblings[i]));
      buf.addByte(proof.directions[i] ? 1 : 0);
    }
  }

  /// Appends the sorcerer recall suffix to [buf] for spell action payloads.
  ///
  ///   [recall bytes: 2 + spokenCount][suffixLen: 1]
  ///
  /// Variable length, unlike the fixed 3-byte VocalScore suffix it replaces —
  /// a recital is one opener plus up to 48 element words. The TRAILING length
  /// byte is what keeps the decoder's read-from-the-end structure working:
  /// the payload is parsed front-to-back for the spell and proof tail, so the
  /// suffix can only be located by measuring back from the end, which a
  /// variable-length blob cannot be without first knowing its size.
  ///
  /// Only slot INDICES cross the wire, never the words filling them
  /// (VOCAL_RECALL_PLAN.md §8.10.1) — a player's vocabulary never leaves
  /// their device.
  static void appendSorcererBytes(BytesBuilder buf, IncantationRecall? recall) {
    final bytes = (recall ?? IncantationRecall.silent).toWireBytes();
    buf.add(bytes);
    buf.addByte(bytes.length);
  }

  /// Reads the trailing recall suffix written by [appendSorcererBytes].
  ///
  /// Returns null in wizard mode. A malformed suffix decodes to "no
  /// utterance" rather than throwing: every unreadable position scores as
  /// WRONG, so a corrupt recall can only cost the caster mana — there is
  /// nothing here worth forfeiting a match over.
  static IncantationRecall? decodeSorcererSuffix(
      Uint8List bytes, bool isVocalComponents) {
    if (!isVocalComponents || bytes.isEmpty) return null;
    final suffixLen = bytes[bytes.length - 1];
    final start = bytes.length - 1 - suffixLen;
    if (suffixLen < 2 || start < 0) return IncantationRecall.silent;
    return IncantationRecall.fromWireBytes(bytes, start).recall;
  }

  /// Decode a [TurnAction] from [bytes] and optionally parse the trailing
  /// proof tail (present when the peer has a committed chapter).
  ///
  /// Returns `({TurnAction action, MembershipProof? merkleProof})`.
  /// [merkleProof] is non-null only when [withProof] is true and a valid tail
  /// was found. The `root` field of the returned proof is left empty — the
  /// caller fills it from the peer's book root before calling `verify`,
  /// because which root to check against is a trust question, not a framing
  /// one.
  ///
  /// **Nothing here rejects.** Every malformed, truncated or unknown input
  /// degrades to `PassAction` or a field default. That is deliberate: a
  /// decoder that threw would hand a modified peer a way to abort the turn on
  /// the honest device.
  static ({TurnAction action, MembershipProof? merkleProof}) decodeAction(
    Uint8List bytes, {
    bool withProof = false,
    bool isVocalComponents = false,
  }) {
    // BUG FIX (found via SPELL_DRAW_WIRING_PLAN.md §10 item 4's test — a
    // pre-existing bug, dormant because every prior test used a single-spell
    // chapter, where BookCommitment.proveMembership has no siblings and
    // appendSpellProofTail writes depth=0, never exercising this path):
    // [pos] here is ALREADY past the wire's [proof_len:4][proof_bytes:N]
    // segment — both call sites below decode that segment themselves first
    // (into decodedProofBytes/decodedProofBytes3) and pass the ADVANCED
    // [pos]. This function used to re-read another [proof_len:4] from that
    // already-advanced position and skip that many (garbage) bytes, which
    // for any REAL multi-spell chapter (nonzero merkle depth) blew past
    // [b.length] and made every merkleProof silently null — book-membership
    // and hand-membership (§6) checks were both unconditionally skipped
    // for any chapter with more than one spell. The tail format is
    // [proof_len:4][proof_bytes:N][merkle_depth:1][path...] — this function
    // only ever needs to read from merkle_depth onward.
    MembershipProof? parseProofTail(
      Uint8List b,
      int pos,
      String commitmentHex,
    ) {
      if (!withProof || pos >= b.length) return null;
      final depth = b[pos++];
      final siblings = <String>[];
      final directions = <bool>[];
      for (var d = 0; d < depth; d++) {
        if (pos + 33 > b.length) return null;
        final sib = b.sublist(pos, pos + 32);
        pos += 32;
        directions.add(b[pos++] == 1);
        siblings.add(WireBytes.hex0x(sib));
      }
      if (siblings.length != depth) return null;
      return MembershipProof(
        root: '', // filled by the caller, from the peer's book root
        leafHex: commitmentHex,
        siblings: siblings,
        directions: directions,
      );
    }

    if (bytes.isEmpty) return (action: PassAction(), merkleProof: null);
    final type = bytes[0];
    switch (type) {
      case 0x00:
        return (action: PassAction(), merkleProof: null);

      case 0x01:
        if (bytes.length < 1 + 32 + 2 + 4 + 2 + 2 + 3) {
          return (action: PassAction(), merkleProof: null);
        }
        int pos = 1;
        final commitBytes = bytes.sublist(pos, pos + 32);
        pos += 32;
        final t = WireBytes.readBe2(bytes, pos);
        pos += 2;
        final q = WireBytes.readInt16(bytes, pos);
        pos += 2;
        final r = WireBytes.readInt16(bytes, pos);
        pos += 2;
        final formulaLen = WireBytes.readBe2(bytes, pos);
        pos += 2;
        final formulaStr = pos + formulaLen <= bytes.length
            ? utf8.decode(bytes.sublist(pos, pos + formulaLen))
            : '';
        pos += formulaLen;
        final formula = formulaStr.isEmpty ? <String>[] : formulaStr.split(',');
        final nameLen =
            pos + 2 <= bytes.length ? WireBytes.readBe2(bytes, pos) : 0;
        pos += 2;
        final name = pos + nameLen <= bytes.length
            ? utf8.decode(bytes.sublist(pos, pos + nameLen))
            : '';
        pos += nameLen;
        final commitmentHex = WireBytes.hex0x(commitBytes);

        final isPotent01 = pos < bytes.length && bytes[pos++] == 1;
        final isVelocity01 = pos < bytes.length && bytes[pos++] == 1;
        final isEfficiency01 = pos < bytes.length && bytes[pos++] == 1;

        HexCoord? conveyorDirection01;
        if (pos < bytes.length) {
          final hasDir = bytes[pos++] == 1;
          if (hasDir && pos + 4 <= bytes.length) {
            conveyorDirection01 = WireBytes.decodeCoord(bytes, pos);
            pos += 4;
          }
        }

        final summon01 = readSummonBytes(bytes, pos);
        pos += 2;

        // Parse proof bytes from the tail (needed for verification).
        Uint8List decodedProofBytes = Uint8List(0);
        if (withProof && pos + 4 <= bytes.length) {
          final proofLen = WireBytes.readBe4(bytes, pos);
          pos += 4;
          if (pos + proofLen <= bytes.length) {
            decodedProofBytes = bytes.sublist(pos, pos + proofLen);
          }
          pos += proofLen;
        }

        final spell = SpellAsset(
          id: '',
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          tier: 24,
          t: t,
          ownerPubkeyHex: '',
          manaCost: 0,
          segmentCount: 0,
          dotCount: 0,
          initialGrid: const [],
          proofBytes: decodedProofBytes,
          name: name,
          commitmentHex: commitmentHex,
          spellHashHex: '',
          formula: formula,
          // M4.16: without these the peer resolved a summon as an ordinary
          // incantation and the match desynced on the spot.
          isSummon: summon01.isSummon,
          summonPersonality: summon01.personality,
        );
        final merkle = parseProofTail(bytes, pos, commitmentHex);
        // [KEY STRUCTURAL CONSTRAINT — no local recalculation]
        // What the caster SAID is read verbatim from the trailing suffix. It
        // is NEVER recomputed from local audio: this is a static method
        // holding no scorer reference, making local recalculation
        // structurally impossible, and the peer's microphone is unavailable
        // to this device anyway.
        //
        // What IS recomputed locally is the EXPECTED sequence, derived from
        // the certified trajectory (see
        // DeterministicResolution.certifiedManaCost). That asymmetry is the
        // whole of the recall model: the claim is the caster's, the check is
        // ours. Pronunciation quality could never be checked this way, which
        // is why it was replaced.
        final recall01 = decodeSorcererSuffix(bytes, isVocalComponents);
        return (
          action: SpellCastAction(
            spell: spell,
            targetHex: HexCoord(q, r),
            isPotent: isPotent01,
            isVelocity: isVelocity01,
            isEfficiency: isEfficiency01,
            recall: recall01,
            conveyorDirection: conveyorDirection01,
          ),
          merkleProof: merkle,
        );

      case 0x04:
        return (action: DashAction(), merkleProof: null);

      case 0x05:
        return (action: MeditateAction(), merkleProof: null);

      case 0x03:
        if (bytes.length < 1 + 32 + 2 + 2 + 2)
          return (action: PassAction(), merkleProof: null);
        int pos3 = 1;
        final spellCommit = bytes.sublist(pos3, pos3 + 32);
        pos3 += 32;
        final t3 = WireBytes.readBe2(bytes, pos3);
        pos3 += 2;
        final formulaLen3 = WireBytes.readBe2(bytes, pos3);
        pos3 += 2;
        final formulaStr3 = pos3 + formulaLen3 <= bytes.length
            ? utf8.decode(bytes.sublist(pos3, pos3 + formulaLen3))
            : '';
        pos3 += formulaLen3;
        final nameLen3 =
            pos3 + 2 <= bytes.length ? WireBytes.readBe2(bytes, pos3) : 0;
        pos3 += 2;
        final name3 = pos3 + nameLen3 <= bytes.length
            ? utf8.decode(bytes.sublist(pos3, pos3 + nameLen3))
            : '';
        pos3 += nameLen3;
        if (pos3 + 32 + 1 > bytes.length)
          return (action: PassAction(), merkleProof: null);
        final mysteryCommit = bytes.sublist(pos3, pos3 + 32);
        pos3 += 32;
        final hasImmediate = bytes[pos3++] == 1;
        HexCoord? immTarget;
        Uint8List? immNonce;
        if (hasImmediate && pos3 + 4 + 16 <= bytes.length) {
          immTarget = WireBytes.decodeCoord(bytes, pos3);
          pos3 += 4;
          immNonce = bytes.sublist(pos3, pos3 + 16);
          pos3 += 16;
        }
        final isPotent3 = pos3 < bytes.length && bytes[pos3++] == 1;
        final isVelocity3 = pos3 < bytes.length && bytes[pos3++] == 1;
        final summon3 = readSummonBytes(bytes, pos3);
        pos3 += 2;

        Uint8List decodedProofBytes3 = Uint8List(0);
        final commitmentHex3 = WireBytes.hex0x(spellCommit);
        if (withProof && pos3 + 4 <= bytes.length) {
          final proofLen = WireBytes.readBe4(bytes, pos3);
          pos3 += 4;
          if (pos3 + proofLen <= bytes.length) {
            decodedProofBytes3 = bytes.sublist(pos3, pos3 + proofLen);
          }
          pos3 += proofLen;
        }

        final spell3 = SpellAsset(
          id: '',
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          tier: 24,
          t: t3,
          ownerPubkeyHex: '',
          manaCost: 0,
          segmentCount: 0,
          dotCount: 0,
          initialGrid: const [],
          proofBytes: decodedProofBytes3,
          name: name3,
          commitmentHex: commitmentHex3,
          spellHashHex: '',
          formula: formulaStr3.isEmpty ? [] : formulaStr3.split(','),
          // M4.16, same as the immediate-cast branch: a delayed summon has to
          // survive the wire too, or it desyncs when it eventually fires.
          isSummon: summon3.isSummon,
          summonPersonality: summon3.personality,
        );
        final merkle3 = parseProofTail(bytes, pos3, commitmentHex3);
        // Same no-local-recalculation constraint as case 0x01 above.
        final recall03 = decodeSorcererSuffix(bytes, isVocalComponents);
        return (
          action: MysterySpellCastAction(
            spell: spell3,
            mysteryCommitment: mysteryCommit,
            immediateTarget: immTarget,
            immediateNonce: immNonce,
            isPotent: isPotent3,
            isVelocity: isVelocity3,
            recall: recall03,
          ),
          merkleProof: merkle3,
        );

      default:
        return (action: PassAction(), merkleProof: null);
    }
  }

  // ── Split-leaf action commitment (MESH_ARCHITECTURE.md §13b) ──────────────
  //
  // actionCommit = SHA-256( H(remainder ‖ saltA) ‖ H(target ‖ saltB) ). The
  // two-leaf shape exists so a scryer with an active DivinationLink can
  // verifiably learn (target, saltB) early without learning remainder — spell
  // identity, formula and enhancements stay sealed.
  //
  // These live here rather than with the verification that consumes them
  // because the preimage is pure layout: which slice of the action bytes is
  // the target, and in what order the two leaves are concatenated. Whether a
  // recomputed commit MATCHES, and what to do when it does not, is
  // `TurnLoop`'s call.

  /// Splits action bytes into (targetBytes, remainderBytes): targetBytes is
  /// the plaintext (q,r) HexCoord slice a scry effect may verifiably open
  /// early; remainderBytes is everything else. Pass and delayed (non-
  /// immediate) Mystery casts have no plaintext target yet — targetBytes is
  /// empty for those.
  static (Uint8List target, Uint8List remainder) splitActionTarget(
    Uint8List actionBytes,
  ) {
    if (actionBytes.isEmpty) return (Uint8List(0), actionBytes);
    int? targetOffset;
    switch (actionBytes[0]) {
      case 0x01:
        targetOffset = 1 + 32 + 2; // SpellCastAction: after type+commit+t.
    }
    if (targetOffset == null || actionBytes.length < targetOffset + 4) {
      return (Uint8List(0), actionBytes);
    }
    final target = actionBytes.sublist(targetOffset, targetOffset + 4);
    final remainder = Uint8List.fromList([
      ...actionBytes.sublist(0, targetOffset),
      ...actionBytes.sublist(targetOffset + 4),
    ]);
    return (Uint8List.fromList(target), remainder);
  }

  static Future<Uint8List> leafHash(Uint8List data, Uint8List salt) async {
    final h = await Sha256().hash(Uint8List.fromList([...data, ...salt]));
    return Uint8List.fromList(h.bytes);
  }

  static Future<Uint8List> splitActionCommit(
    Uint8List actionBytes,
    Uint8List saltA,
    Uint8List saltB,
  ) async {
    final (target, remainder) = splitActionTarget(actionBytes);
    final leafA = await leafHash(remainder, saltA);
    final leafB = await leafHash(target, saltB);
    final h = await Sha256().hash(Uint8List.fromList([...leafA, ...leafB]));
    return Uint8List.fromList(h.bytes);
  }
}

// ── Movement phase ────────────────────────────────────────────────────────────

/// The movement commit-reveal payload.
///
/// `[isDashing:1][meditateInMove:1][count:1][q:2][r:2]…`
///
/// The Dash and move-phase Meditate flags travel with *movement*, not with the
/// action, specifically so both clients know each other's dash status before
/// avatar movement resolves — the action reveal is deliberately deferred until
/// after movement (so a spell's target can't inform the opponent's move),
/// which would otherwise make Dash's same-turn speed boost impossible to apply
/// deterministically.
class MoveWire {
  const MoveWire._();

  /// Encode a move path as `[count:1][q:2][r:2]…` (4 bytes per coord).
  ///
  /// The count is clamped to 255, so a path longer than that silently
  /// truncates rather than corrupting the frame. No legal movement budget
  /// comes close.
  static Uint8List encodePath(List<HexCoord> path) {
    final buf = BytesBuilder();
    buf.addByte(path.length.clamp(0, 255));
    for (final h in path) {
      buf.add(WireBytes.encodeCoord(h));
    }
    return buf.toBytes();
  }

  /// Decode a move path from [data] starting at [offset].
  /// Format: `[count:1][q:2][r:2]…` Returns empty list on underflow, and
  /// stops early (rather than throwing) if [count] overstates what follows.
  static List<HexCoord> decodePath(Uint8List data, int offset) {
    if (offset >= data.length) return const [];
    final count = data[offset];
    final path = <HexCoord>[];
    var pos = offset + 1;
    for (var i = 0; i < count; i++) {
      if (pos + 4 > data.length) break;
      path.add(WireBytes.decodeCoord(data, pos));
      pos += 4;
    }
    return path;
  }

  static Uint8List encodePayload({
    required bool isDashing,
    required bool meditateInMove,
    required List<HexCoord> path,
  }) {
    final buf = BytesBuilder();
    buf.addByte(isDashing ? 1 : 0);
    buf.addByte(meditateInMove ? 1 : 0);
    buf.add(encodePath(path));
    return buf.toBytes();
  }

  /// Decode a movement-phase payload from [data] starting at [offset].
  /// When [meditateInMove] is true, [path] is forced empty regardless of
  /// what was transmitted (defence-in-depth against a modified peer).
  static ({bool isDashing, bool meditateInMove, List<HexCoord> path})
      decodePayload(Uint8List data, int offset) {
    if (offset + 2 > data.length) {
      return (
        isDashing: false,
        meditateInMove: false,
        path: const <HexCoord>[],
      );
    }
    final isDashing = data[offset] == 1;
    final meditateInMove = data[offset + 1] == 1;
    final path = meditateInMove
        ? const <HexCoord>[]
        : decodePath(data, offset + 2);
    return (isDashing: isDashing, meditateInMove: meditateInMove, path: path);
  }
}

// ── Melee round ───────────────────────────────────────────────────────────────

/// The resolution-phase melee choice: `[0x00]` = none, `[0x01][q:2][r:2]` =
/// that tile.
///
/// The post-resolution free-move choice used to share this shape but now
/// carries a whole path (a Boost run can be several tiles long) and rides
/// [MoveWire.encodePath] instead, where an empty path is the "stand fast"
/// encoding. The two are kept apart deliberately: they mean different things
/// and have diverged once already.
class MeleeWire {
  const MeleeWire._();

  static Uint8List encodeTarget(HexCoord? target) {
    if (target == null) return Uint8List.fromList([0x00]);
    final buf = BytesBuilder();
    buf.addByte(0x01);
    buf.add(WireBytes.encodeCoord(target));
    return buf.toBytes();
  }

  static HexCoord? decodeTarget(Uint8List data, int offset) {
    if (offset >= data.length || data[offset] != 0x01) return null;
    if (offset + 5 > data.length) return null;
    return WireBytes.decodeCoord(data, offset + 1);
  }
}

// ── Phase 0 artifact activation ───────────────────────────────────────────────

/// The Phase 0 activation declaration: `[0x00]` = none, `[0x01][kind:1]`.
///
/// `[kind]` is the [AccoutrementKind] index. The declaration names a KIND,
/// never a specific accoutrement id — which removes a whole class of trust
/// bug, because a peer cannot name an id it does not own if it never gets to
/// name an id at all. Which instance is consumed is decided above this layer.
class ArtifactActivationWire {
  const ArtifactActivationWire._();

  static Uint8List encode(AccoutrementKind? kind) => kind == null
      ? Uint8List.fromList([0x00])
      : Uint8List.fromList([0x01, kind.index]);

  /// Decodes an activation declaration from [data] at [offset]. Anything
  /// malformed — truncated, unknown lead byte, out-of-range kind index —
  /// reads as "declared nothing", which the activation validator would have
  /// reduced it to anyway.
  static AccoutrementKind? decode(Uint8List data, int offset) {
    if (offset >= data.length || data[offset] != 0x01) return null;
    if (offset + 1 >= data.length) return null;
    final index = data[offset + 1];
    if (index >= AccoutrementKind.values.length) return null;
    return AccoutrementKind.values[index];
  }
}

// ── Delayed-spell reveals ─────────────────────────────────────────────────────

/// One decoded entry of a delayed-spell reveal payload.
///
/// A *claim*, not a fact: the id names a pending spell the sender says is
/// firing, and `delay`/`targetTile`/`nonce` are what they say opens its
/// commitment. Checking the id exists, the timing matches, and the hash opens
/// is the caller's job.
typedef DelayedRevealEntry = ({
  String id,
  HexCoord targetTile,
  int delay,
  Uint8List nonce,
});

/// Private reveals for pending delayed spells firing this turn.
///
/// `[count:1][ id:16, coord:4, delay:1, nonce:16 per entry ]`
class DelayedRevealWire {
  const DelayedRevealWire._();

  static Uint8List encode(
    List<({String pendingSpellId, HexCoord targetTile, int delay, Uint8List nonce})>
        reveals,
  ) {
    final buf = BytesBuilder();
    buf.addByte(reveals.length.clamp(0, 255));
    for (final r in reveals) {
      buf.add(WireBytes.hexToBytes(r.pendingSpellId)); // 32 hex chars → 16 bytes
      buf.add(WireBytes.encodeCoord(r.targetTile)); // 4 bytes
      buf.addByte(r.delay & 0xFF); // 1 byte
      buf.add(r.nonce); // 16 bytes
    }
    return buf.toBytes();
  }

  /// Reads as many complete entries as [payload] actually holds. A count byte
  /// that overstates the payload yields the entries that are fully present
  /// and drops the rest — same underflow rule as [MoveWire.decodePath].
  static List<DelayedRevealEntry> decode(Uint8List payload) {
    if (payload.isEmpty) return const [];
    final count = payload[0];
    final entries = <DelayedRevealEntry>[];
    var pos = 1;
    for (var i = 0; i < count; i++) {
      if (pos + 37 > payload.length) {
        break; // 16 id + 4 coord + 1 delay + 16 nonce
      }
      final idBytes = payload.sublist(pos, pos + 16);
      pos += 16;
      final targetTile = WireBytes.decodeCoord(payload, pos);
      pos += 4;
      final delay = payload[pos++];
      final nonce = payload.sublist(pos, pos + 16);
      pos += 16;
      entries.add((
        id: WireBytes.hex(idBytes),
        targetTile: targetTile,
        delay: delay,
        nonce: nonce,
      ));
    }
    return entries;
  }
}

// ── Per-turn signed state hash ────────────────────────────────────────────────

/// Domain-separation tag for the per-turn signed state hash (Phase D,
/// BATTLE_AUTH_PLAN.md §6). Distinct from battle_session.dart's
/// `kIdentityAuthSignatureTag` so a state-hash signature can never be
/// replayed as an auth signature or vice-versa.
const kStateHashSignatureTag = 'RUNEWRIGHT_BATTLE_STATE_V1\x00';

class StateHashWire {
  const StateHashWire._();

  /// The message signed/verified over a state hash: distinct per match
  /// (matchId) and per turn (turnNumber), so a signature can't be replayed
  /// across matches or turns.
  ///
  /// `tag ‖ matchId ‖ turnNumber:4 ‖ hash`
  static List<int> signatureMessage({
    required Uint8List? matchId,
    required int turnNumber,
    required Uint8List hash,
  }) =>
      [
        ...utf8.encode(kStateHashSignatureTag),
        ...(matchId ?? const <int>[]),
        ...WireBytes.be4(turnNumber),
        ...hash,
      ];
}

// ── Encrypted divination exchanges (MESH_ARCHITECTURE.md §13b) ────────────────

/// The envelope both divination exchanges ride in.
///
/// Shared deliberately, not incidentally: the Water spell-list reveal was
/// specified as reusing the §13b scrying transport verbatim, differing only in
/// what the sealed payload carries. Keeping one envelope means a change to the
/// handshake shape cannot land on one exchange and miss the other.
///
/// Both slots are always written — a uniform slot with conditional content —
/// so the *shape* of a turn's traffic never depends on secret state. `[0x00]`
/// is "no, nothing this turn"; it is what an idle player sends, and it is what
/// a player who is being scried but is not scrying sends, so the two are
/// indistinguishable on the wire.
class SealedExchangeFrames {
  const SealedExchangeFrames._();

  /// `[0x00]` — "no key / no opening this turn".
  static Uint8List decline() => Uint8List.fromList([0x00]);

  /// `[0x01][x25519_pubkey:32]`
  static Uint8List keyFrame(List<int> publicKeyBytes) =>
      Uint8List.fromList([0x01, ...publicKeyBytes]);

  /// The peer's ephemeral public key, or null if they declined.
  ///
  /// Length is checked for EXACT equality, not a minimum: an X25519 public key
  /// is 32 bytes and a frame that is any other size is not one.
  static Uint8List? keyFramePublicKey(Uint8List frame) =>
      frame.length == 33 && frame[0] == 0x01 ? frame.sublist(1) : null;

  /// `[0x01][ephemeral_pubkey:32][aead_box:…]`
  static Uint8List sealedFrame(List<int> vkPub, List<int> boxConcatenation) =>
      Uint8List.fromList([0x01, ...vkPub, ...boxConcatenation]);

  /// Splits a sealed frame into its ephemeral key and ciphertext, or null if
  /// the peer declined or the frame is too short to hold a key.
  static ({Uint8List vkPub, Uint8List box})? openSealedFrame(Uint8List frame) {
    if (frame.isEmpty || frame[0] != 0x01) return null;
    if (frame.length < 1 + 32) return null;
    return (vkPub: frame.sublist(1, 33), box: frame.sublist(33));
  }
}

/// The Air-flavour scry: an early, verifiable opening of the target leaf of
/// the peer's action commitment.
class ScryWire {
  const ScryWire._();

  /// Domain-separates the scry-key HKDF derivation by match and turn, so an
  /// ephemeral key reused (never should be, but defence-in-depth) across
  /// matches or turns still derives a distinct symmetric key.
  static Uint8List hkdfInfo({
    required Uint8List? matchId,
    required int turnNumber,
  }) =>
      Uint8List.fromList([
        ...utf8.encode('RWSCRY1'),
        ...(matchId ?? const <int>[]),
        ...WireBytes.be4(turnNumber),
      ]);

  /// The sealed payload: `targetBytes(4 or 0) ‖ saltB(16) ‖ leafA(32)`.
  ///
  /// [leafA] is the Merkle sibling needed to verify the opened target leaf
  /// against the peer's public action commitment; without it the opening
  /// would be an unverifiable assertion.
  static Uint8List encodeOpening({
    required Uint8List target,
    required Uint8List saltB,
    required Uint8List leafA,
  }) =>
      Uint8List.fromList([...target, ...saltB, ...leafA]);

  /// Reads what [encodeOpening] wrote. A zero-length target is legitimate —
  /// a Pass or a delayed Mystery cast has no plaintext target this turn — so
  /// the two valid lengths are 52 and 48, and anything else is null.
  static ({Uint8List target, Uint8List saltB, Uint8List leafA})? decodeOpening(
    List<int> opening,
  ) {
    final hasTarget = opening.length == 4 + 16 + 32;
    if (!hasTarget && opening.length != 16 + 32) return null;
    final saltOffset = hasTarget ? 4 : 0;
    return (
      target: hasTarget
          ? Uint8List.fromList(opening.sublist(0, 4))
          : Uint8List(0),
      saltB: Uint8List.fromList(opening.sublist(saltOffset, saltOffset + 16)),
      leafA: Uint8List.fromList(
        opening.sublist(saltOffset + 16, saltOffset + 48),
      ),
    );
  }
}

/// One revealed hand card plus the Merkle path that ties it to the revealer's
/// book root. The root itself is NOT carried — the receiver supplies it from
/// the handshake, so a revealer cannot name the tree they are proving against.
typedef SpellRevealEntry = ({
  SpellAsset spell,
  List<String> siblings,
  List<bool> directions,
});

/// The Water-flavour scry: the target's current hand, each card carrying its
/// own membership proof.
///
/// JSON rather than a packed binary layout because the payload is a list of
/// whole [SpellAsset]s, which already have a canonical JSON form used for
/// on-disk persistence. Keeping one representation avoids a second spell
/// serializer that could drift from the first.
class SpellRevealWire {
  const SpellRevealWire._();

  /// Mirrors [ScryWire.hkdfInfo] with a distinct tag so the two exchanges
  /// never derive the same symmetric key even if somehow run with identical
  /// ephemeral keys.
  static Uint8List hkdfInfo({
    required Uint8List? matchId,
    required int turnNumber,
  }) =>
      Uint8List.fromList([
        ...utf8.encode('RWSPELLREV1'),
        ...(matchId ?? const <int>[]),
        ...WireBytes.be4(turnNumber),
      ]);

  static Uint8List encodeEntries(List<SpellRevealEntry> entries) =>
      Uint8List.fromList(utf8.encode(jsonEncode([
        for (final e in entries)
          {
            'spell': e.spell.toJson(),
            'siblings': e.siblings,
            'directions': e.directions,
          },
      ])));

  /// Parses the sealed payload. Throws on anything malformed — unlike every
  /// other decoder here, which degrades.
  ///
  /// The difference is deliberate and reflects who can reach the code: an
  /// action payload is sent every turn by every peer, so a strict parser
  /// there hands an attacker a way to abort honest turns. A spell reveal only
  /// exists because *we* cast a Divination on them; a peer who answers it with
  /// garbage has already broken the protocol, and the caller treats the throw
  /// as exactly that.
  static List<SpellRevealEntry> decodeEntries(List<int> payloadBytes) {
    final decoded = jsonDecode(utf8.decode(payloadBytes)) as List<dynamic>;
    final entries = <SpellRevealEntry>[];
    for (final entryRaw in decoded) {
      final entry = entryRaw as Map<String, dynamic>;
      entries.add((
        spell: SpellAsset.fromJson(entry['spell'] as Map<String, dynamic>),
        siblings: (entry['siblings'] as List<dynamic>).cast<String>(),
        directions: (entry['directions'] as List<dynamic>).cast<bool>(),
      ));
    }
    return entries;
  }
}
