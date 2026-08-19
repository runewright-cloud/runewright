// SPDX-License-Identifier: GPL-3.0-or-later
//
// forced_cast.dart — the forced reveal-and-cast primitive
// (docs/WILD_MAGIC_PLAN.md §2.5, §9.5).
//
// Forces one or more players to reveal and immediately resolve spells from
// their OWN hand, at no mana cost. Wild magic's Spontaneous Combustion is the
// first caller, but nothing in this file is wild-magic-specific: Soren's stated
// intent is to reuse it for a plain "cast something at random from your hand"
// effect if other table cells disappoint in playtest, so the SEAM is the
// deliverable, not just the one effect.
//
// ── Why this needs a protocol message at all ──────────────────────────────────
// A player's hand CONTENTS are private. SPELL_DRAW_WIRING_PLAN.md deliberately
// gives each client only a POSITION-ONLY mirror of the peer's hand
// (DrawSchedule) — never the grids, formulas, or proofs. So the local client
// cannot resolve a peer's randomly-selected bookmarked spell: it does not have
// it, and fabricating one is an instant desync that the state-hash exchange
// will abort the match over. Do not attempt to fake the peer's hand.
//
// ── The ordering that makes this fair ─────────────────────────────────────────
// Slots are selected PUBLICLY FIRST, from the position-only DrawSchedule both
// clients already hold, and only then does anybody reveal anything. That means
// the revealer cannot shop for a favourable spell, and the receiver can check
// that the reveal corresponds to the slot that was actually selected.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:rune_duel/battle/models/certified_cast.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import 'book_commitment.dart' show MembershipProof;
import 'hash_rng.dart';

// ── Request ───────────────────────────────────────────────────────────────────

/// How the forced cast picks its target tile.
enum ForcedCastTargeting {
  /// A random tile within the forced caster's own effective spell range,
  /// drawn from a deterministically sorted candidate list. The only mode
  /// today.
  randomInRange,
}

class ForcedCastRequest {
  const ForcedCastRequest({
    required this.affectedPlayerIds,
    required this.countPerPlayer,
    required this.reasonTag,
    this.targeting = ForcedCastTargeting.randomInRange,
  });

  /// Iterated SORTED, always — a Set's iteration order is insertion order in
  /// Dart, and the order players are processed in decides RNG consumption.
  final Set<String> affectedPlayerIds;

  /// How many hand slots each affected player must reveal and cast.
  /// `1 + bracketSteps` for Spontaneous Combustion.
  final int countPerPlayer;

  /// Names the cause, for the UI and the event log (e.g.
  /// `'spontaneousCombustion'`). Also folded into the RNG domain so two
  /// different effects forcing a cast in the same turn never share a stream.
  final String reasonTag;

  final ForcedCastTargeting targeting;
}

/// One resolved pick: whose hand, which public chapter position, the spell
/// itself, and — once the reveal has been through the trust boundary — what
/// its PROOF says that spell does.
class ForcedCastPick {
  const ForcedCastPick({
    required this.playerId,
    required this.position,
    required this.spell,
    this.certified,
  });

  final String playerId;
  final int position;

  /// The WIRE object. Its `formula`, `isSummon` and `summonPersonality` are
  /// authored by whoever revealed it and bound by nothing (the commitment is
  /// grid-only — CLAUDE.md invariant 2). Resolution must read [certified]
  /// instead wherever the two can disagree.
  final SpellAsset spell;

  /// The proof-attested semantics of this pick (M4.20).
  ///
  /// A peer's comes from [ForcedCastHost.verifyForcedReveal] — the same
  /// derivation an ordinary peer cast gets — and the local player's from
  /// [ForcedCastHost.certifiedFromProofBytes] over its own proof bytes. Both
  /// routes end in `PeerCastVerifier.semanticsOf`, so both devices hold
  /// byte-identical formulas, element sequence and wild-magic triggers for the
  /// same pick and resolve it the same way.
  ///
  /// Null means there was no proof to derive from at all — a proofless dev-flag
  /// spell, or verification not wired up (solo) with unparseable bytes. Both
  /// devices see the same absence and fall back to the wire identically, so it
  /// is desync-safe; it is never a licence to prefer the wire when certified
  /// data exists.
  final CertifiedCast? certified;
}

// ── Host seam ─────────────────────────────────────────────────────────────────

/// Everything the sequence below needs from the turn loop. Implemented by
/// TurnLoop; kept as an interface so this file has no dependency on it (and so
/// tests can drive the sequence without a battle).
abstract class ForcedCastHost {
  /// The public hand positions currently held by [playerId], from the
  /// position-only DrawSchedule both clients compute for BOTH players. Empty
  /// when that player has no hand (deck exhausted, or not yet dealt).
  List<int> publicHandPositions(String playerId);

  /// 32 seed bytes for [playerId]'s slot selection under this [reasonTag],
  /// derived from this turn's joint entropy (domain tag 0x09).
  Uint8List forcedCastSeed(String playerId, String reasonTag);

  /// True when [playerId] is this device's own player — the only one whose
  /// hand contents we hold.
  bool isLocalPlayer(String playerId);

  /// The local player's own spell at chapter [position], or null when the
  /// chapter isn't loaded or the position is out of range.
  SpellAsset? localSpellAt(int position);

  /// A Merkle membership proof binding [position] to the local chapter root,
  /// so the peer can verify the reveal the same way it verifies a normal cast.
  MembershipProof? localMembershipProofAt(int position);

  /// Sends our reveal payload and returns the peer's. Must be called by both
  /// sides or not at all — both derive the same wild-magic triggers from the
  /// same certified proof outputs, so both reach this point together.
  /// Returns null in solo/practice mode, where there is no peer: the sequence
  /// then resolves only the local player's picks and never awaits a reveal
  /// that will not arrive.
  Future<Uint8List?> exchangeForcedReveal(Uint8List ours);

  /// Runs an incoming peer reveal through the SAME verification path as a
  /// normal cast — proof verification, commitment-vs-wire check, and Merkle
  /// membership against the peer's chapter root. Returns the certified spell,
  /// or throws (after forfeiting) if verification fails. A revealed spell that
  /// fails verification forfeits the match, exactly like any other bad cast;
  /// there is deliberately no lenient path.
  ///
  /// Returns null when nothing could be certified — solo, verification not
  /// wired up, or the `kAllowProoflessSpells` dev flag. That is the same
  /// "no proof to derive from" case [certifiedFromProofBytes] returns null for,
  /// and it is NOT a verification failure: a failure throws.
  ///
  /// The return type used to be `void` while this comment already said
  /// "returns the certified spell". The certified semantics were computed here
  /// and dropped, and resolution fell back to the peer's authored
  /// `SpellAsset.formula` — M4.20.
  Future<CertifiedCast?> verifyForcedReveal(
    String playerId,
    int position,
    SpellAsset spell,
    MembershipProof? merkleProof,
  );

  /// The certified semantics of a spell whose proof bytes this device already
  /// holds, parsed without verifying them.
  ///
  /// Used for the LOCAL player's own picks, which never cross
  /// [verifyForcedReveal] because nobody sends themselves a reveal. Both sides
  /// end at the same derivation over the same proof bytes, so the local
  /// device's own pick resolves exactly as the receiving device resolves it —
  /// which is what keeps the state hashes agreed. Null when there are no
  /// usable proof bytes.
  CertifiedCast? certifiedFromProofBytes(SpellAsset spell);

  /// Resolves one forced cast: zero mana, no chain update, not consumed from
  /// hand, and exempt from every on-cast global hook (see A8).
  Future<void> resolveForcedCast(ForcedCastPick pick, HashRng rng);

  /// Aborts the match. Used for a withheld or malformed reveal, matching how
  /// a withheld entropy nonce is handled.
  void forfeitMatch(String reason);
}

// ── Sequencer ─────────────────────────────────────────────────────────────────

class ForcedCast {
  /// Runs the full sequence for [request]:
  ///
  ///   1. **Select slots publicly.** For each affected player (sorted by
  ///      playerId), pick `countPerPlayer` hand POSITIONS from that player's
  ///      public DrawSchedule. Both sides agree on which slots were chosen
  ///      before anybody reveals anything.
  ///   2. **Reveal.** Each side transmits the SpellAssets (with proofs and
  ///      Merkle paths) for its own selected slots.
  ///   3. **Verify.** Each side runs the incoming spells through the normal
  ///      peer-cast verification path. Failure forfeits.
  ///   4. **Resolve.** Each pick is cast at a random in-range tile, free, with
  ///      A8's full exemption set.
  ///
  /// A player with an empty hand reveals nothing and is skipped — reachable
  /// (deck exhausted) and a null-deref here would land mid-turn, mid-match.
  static Future<void> run(
    ForcedCastRequest request,
    ForcedCastHost host,
    HashRng Function(String playerId) rngFor,
  ) async {
    // ── 1. Public slot selection ────────────────────────────────────────
    final localPicks = <(String, int)>[];
    final peerPositions = <String, List<int>>{};

    for (final playerId in request.affectedPlayerIds.toList()..sort()) {
      final hand = host.publicHandPositions(playerId);
      if (hand.isEmpty) continue; // empty hand reveals nothing — skipped
      final selector = HashRng(host.forcedCastSeed(playerId, request.reasonTag));
      // Draw without replacement so `countPerPlayer > 1` can't pick one slot
      // twice; a copy, so the real schedule is untouched by the selection.
      final available = List<int>.from(hand);
      final chosen = <int>[];
      for (var i = 0; i < request.countPerPlayer && available.isNotEmpty; i++) {
        chosen.add(available.removeAt(selector.nextInt(available.length)));
      }
      if (host.isLocalPlayer(playerId)) {
        for (final p in chosen) {
          localPicks.add((playerId, p));
        }
      } else {
        peerPositions[playerId] = chosen;
      }
    }

    // ── 2. Reveal ───────────────────────────────────────────────────────
    final ourPayload = encodeReveal([
      for (final (_, position) in localPicks)
        (
          position: position,
          spell: host.localSpellAt(position),
          proof: host.localMembershipProofAt(position),
        ),
    ]);
    final theirPayload = await host.exchangeForcedReveal(ourPayload);

    // ── 3. Verify ───────────────────────────────────────────────────────
    final resolved = <ForcedCastPick>[];
    for (final (localId, position) in localPicks) {
      final spell = host.localSpellAt(position);
      if (spell == null) continue;
      resolved.add(
        ForcedCastPick(
          playerId: localId,
          position: position,
          spell: spell,
          // Our own pick never goes through verifyForcedReveal (we do not send
          // ourselves a reveal), so it derives the same semantics straight from
          // its own proof bytes — the pattern a delayed fire's declaration
          // already uses for the owning device. Branching on ownership rather
          // than on some shared map matters: certified data is keyed by
          // commitment and the commitment is grid-only, so a peer revealing the
          // same grid this turn must not be able to supply OUR semantics.
          certified: host.certifiedFromProofBytes(spell),
        ),
      );
    }

    if (theirPayload != null && peerPositions.isNotEmpty) {
      final List<RevealedSpell> incoming;
      try {
        incoming = decodeReveal(theirPayload);
      } on FormatException catch (e) {
        host.forfeitMatch('malformed_forced_reveal:$e');
        throw StateError('peer sent a malformed forced reveal — match forfeit');
      }
      // Flatten the expected peer positions in the same sorted player order the
      // selection used, so the reveal can be matched slot-for-slot.
      final expected = <(String, int)>[
        for (final playerId in peerPositions.keys.toList()..sort())
          for (final p in peerPositions[playerId]!) (playerId, p),
      ];
      if (incoming.length != expected.length) {
        // Withheld reveal gets the same treatment as a withheld nonce.
        host.forfeitMatch('withheld_forced_reveal');
        throw StateError(
          'peer revealed ${incoming.length} forced casts, expected '
          '${expected.length} — match forfeit',
        );
      }
      for (var i = 0; i < expected.length; i++) {
        final (playerId, position) = expected[i];
        final got = incoming[i];
        // The receiver checks the reveal corresponds to the slot that was
        // actually selected — this is what stops the revealer shopping for a
        // favourable spell.
        if (got.position != position) {
          host.forfeitMatch('forced_reveal_slot_mismatch');
          throw StateError(
            'peer revealed position ${got.position}, slot $position was '
            'selected — match forfeit',
          );
        }
        // The trust boundary, and the ONLY authority for what this reveal
        // does. Verification throws (after forfeiting) on a bad reveal, so
        // reaching the next line means the proof verified.
        final certified = await host.verifyForcedReveal(
          playerId,
          position,
          got.spell,
          got.proof,
        );
        resolved.add(
          ForcedCastPick(
            playerId: playerId,
            position: position,
            spell: got.spell,
            // Null only when there was nothing to certify (solo, verification
            // not wired up, proofless dev flag). Parsing the revealed bytes
            // unverified is then still strictly better than the authored
            // formula, and is what the revealing device itself resolved from —
            // same fallback shape as a delayed fire's.
            certified: certified ?? host.certifiedFromProofBytes(got.spell),
          ),
        );
      }
    }

    // ── 4. Resolve ──────────────────────────────────────────────────────
    // Sorted by (playerId, position) so both clients resolve in one order.
    resolved.sort((a, b) {
      final pc = a.playerId.compareTo(b.playerId);
      return pc != 0 ? pc : a.position.compareTo(b.position);
    });
    for (final pick in resolved) {
      await host.resolveForcedCast(pick, rngFor(pick.playerId));
    }
  }

  // ── Wire codec ──────────────────────────────────────────────────────────
  //
  // [count:1]
  //   per entry:
  //     [position:2 BE]
  //     [commitment:32]
  //     [t:2 BE]
  //     [formula_len:2 BE][formula utf8, comma-joined]
  //     [name_len:2 BE][name utf8]
  //     [isSummon:1][personality_len:2][personality utf8]
  //     [proof_len:4 BE][proof bytes]
  //     [merkle_depth:1][depth × (sibling:32, direction:1)]
  //
  // A local pick whose spell can't be found (chapter not loaded) is encoded as
  // a zero-length proof entry rather than dropped, so the count still lines up
  // with the slots the peer independently selected.

  static Uint8List encodeReveal(
    List<({int position, SpellAsset? spell, MembershipProof? proof})> picks,
  ) {
    final buf = BytesBuilder();
    buf.addByte(picks.length.clamp(0, 255));
    for (final pick in picks) {
      final spell = pick.spell;
      buf.add(_be2(pick.position));
      buf.add(
        spell == null ? Uint8List(32) : _hexToBytes(spell.commitmentHex),
      );
      buf.add(_be2(spell?.t ?? 0));
      _addLenPrefixed(buf, (spell?.formula ?? const <String>[]).join(','));
      _addLenPrefixed(buf, spell?.name ?? '');
      buf.addByte((spell?.isSummon ?? false) ? 1 : 0);
      _addLenPrefixed(buf, spell?.summonPersonality ?? '');
      final proofBytes = spell?.proofBytes ?? Uint8List(0);
      buf.add(_be4(proofBytes.length));
      buf.add(proofBytes);
      final merkle = pick.proof;
      if (merkle == null || merkle.siblings.isEmpty) {
        buf.addByte(0); // single-spell chapter, or no proof available
      } else {
        buf.addByte(merkle.siblings.length);
        for (var i = 0; i < merkle.siblings.length; i++) {
          buf.add(_hexToBytes(merkle.siblings[i]));
          buf.addByte(merkle.directions[i] ? 1 : 0);
        }
      }
    }
    return buf.toBytes();
  }

  static List<RevealedSpell> decodeReveal(Uint8List bytes) {
    if (bytes.isEmpty) return const [];
    var pos = 0;
    final count = bytes[pos++];
    final out = <RevealedSpell>[];
    for (var i = 0; i < count; i++) {
      int need(int n) {
        if (pos + n > bytes.length) {
          throw const FormatException('forced reveal truncated');
        }
        return pos;
      }

      need(2);
      final position = _readBe2(bytes, pos);
      pos += 2;
      need(32);
      final commitBytes = bytes.sublist(pos, pos + 32);
      pos += 32;
      need(2);
      final t = _readBe2(bytes, pos);
      pos += 2;
      final formulaStr = _readLenPrefixed(bytes, pos);
      pos = formulaStr.$2;
      final nameStr = _readLenPrefixed(bytes, pos);
      pos = nameStr.$2;
      need(1);
      final isSummon = bytes[pos++] == 1;
      final personality = _readLenPrefixed(bytes, pos);
      pos = personality.$2;
      need(4);
      final proofLen = _readBe4(bytes, pos);
      pos += 4;
      need(proofLen);
      final proofBytes = bytes.sublist(pos, pos + proofLen);
      pos += proofLen;
      need(1);
      final depth = bytes[pos++];
      final siblings = <String>[];
      final directions = <bool>[];
      for (var d = 0; d < depth; d++) {
        need(33);
        siblings.add(_bytesToHex(bytes.sublist(pos, pos + 32)));
        pos += 32;
        directions.add(bytes[pos++] == 1);
      }

      final commitmentHex = _bytesToHex(commitBytes);
      out.add(
        RevealedSpell(
          position: position,
          spell: SpellAsset(
            id: '',
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
            tier: 24,
            t: t,
            ownerPubkeyHex: '',
            manaCost: 0,
            segmentCount: 0,
            dotCount: 0,
            initialGrid: const [],
            proofBytes: proofBytes,
            name: nameStr.$1,
            commitmentHex: commitmentHex,
            spellHashHex: '',
            formula: formulaStr.$1.isEmpty ? const [] : formulaStr.$1.split(','),
            isSummon: isSummon,
            summonPersonality:
                personality.$1.isEmpty ? 'aggressive' : personality.$1,
          ),
          proof: depth == 0
              ? null
              : MembershipProof(
                  root: '', // filled by the verifier from peerBookRoot
                  leafHex: commitmentHex,
                  siblings: siblings,
                  directions: directions,
                ),
        ),
      );
    }
    return out;
  }

  // ── Byte helpers ────────────────────────────────────────────────────────

  static void _addLenPrefixed(BytesBuilder buf, String s) {
    final b = utf8.encode(s);
    buf.add(_be2(b.length));
    buf.add(b);
  }

  static (String, int) _readLenPrefixed(Uint8List b, int pos) {
    if (pos + 2 > b.length) throw const FormatException('forced reveal truncated');
    final len = _readBe2(b, pos);
    pos += 2;
    if (pos + len > b.length) {
      throw const FormatException('forced reveal truncated');
    }
    return (utf8.decode(b.sublist(pos, pos + len)), pos + len);
  }

  static Uint8List _be2(int v) => Uint8List(2)
    ..[0] = (v >> 8) & 0xFF
    ..[1] = v & 0xFF;

  static Uint8List _be4(int v) => Uint8List(4)
    ..[0] = (v >> 24) & 0xFF
    ..[1] = (v >> 16) & 0xFF
    ..[2] = (v >> 8) & 0xFF
    ..[3] = v & 0xFF;

  static int _readBe2(Uint8List b, int pos) => (b[pos] << 8) | b[pos + 1];

  static int _readBe4(Uint8List b, int pos) =>
      (b[pos] << 24) | (b[pos + 1] << 16) | (b[pos + 2] << 8) | b[pos + 3];

  static Uint8List _hexToBytes(String hex) {
    final s = hex.startsWith('0x') ? hex.substring(2) : hex;
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _bytesToHex(List<int> b) =>
      '0x${b.map((x) => x.toRadixString(16).padLeft(2, '0')).join()}';
}

/// One entry decoded from a peer's forced-reveal payload. The spell is a WIRE
/// object — untrusted until [ForcedCastHost.verifyForcedReveal] has run it
/// through the normal proof + Merkle path.
class RevealedSpell {
  const RevealedSpell({
    required this.position,
    required this.spell,
    required this.proof,
  });

  final int position;
  final SpellAsset spell;
  final MembershipProof? proof;
}
