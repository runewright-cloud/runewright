# Step 1 — Identity Onboarding: Runekey Generation, Backup & Restore

This is the first real player-facing UI; everything prior was throwaway diagnostic harnesses. **Orient and propose before building:** read the M4 identity/backup code and the design doc's key/onboarding sections, propose the flow + the exact d20→seed derivation + the sigil port, surface the two design decisions below, and wait for approval.

## Build on what exists — don't reinvent

- **M4 identity module** (`lib/identity/`): Ed25519 keypair generation, secure storage (`flutter_secure_storage` / Android Keystore), `key_hi`/`key_lo` split, ownership signing.
- **M4 backup system** (`lib/identity/backup*.dart`): encrypted (Argon2id + XChaCha20-Poly1305) PEM-armored export, `file_picker` save/import, round-trip tested. The "export key file" and "restore from file" logic already exist — this step **wires them into onboarding UI**, it doesn't rebuild them.

## The flow: first-boot identity bootstrap

On boot, check secure storage for a Runekey.
- **Present** → proceed (toward the main menu, step 2 — out of scope here).
- **Absent** → onboarding offering four paths:
  1. **Create new (auto)** — OS CSPRNG → Ed25519 seed via existing M4 keygen. The low-friction path.
  2. **Create new (A UI showing 4 Hexagons, each representing one of the four elements 24 slots in total)** — the ritual: the player rolls a d20 24 times and enters each result (1–20) in each of the slots; the app derives the seed from those 24 values (~104 bits entropy). Framing: each roll adds randomness no one — not even the app — can predict.
  3. **Restore from backup file** — wire the existing M4 import (`file_picker` → decrypt → validate → store; M4 already handles the destructive-overwrite warning).
  4. **Restore from rolls** — re-enter the 24 values from a sigil/paper record → the *same* derivation as path 2 → the same key. This is the recovery counterpart to the sigil backup.

## Correctness-critical: the d20 → seed derivation must be deterministic and canonical

The sigil/paper backup records the 24 roll values; recovery re-enters them and must regenerate the **identical** key. So:

- Encode the 24 values canonically (fixed order, fixed representation), then derive the 32-byte Ed25519 seed via a fixed construction (e.g. SHA-512 over the canonical encoding with a fixed domain-separation constant, take 32 bytes — or a named KDF). **Document the exact construction.**
- **No un-recorded salt.** A random salt would mean the 24 rolls alone can't rebuild the key, defeating the paper backup. A fixed domain tag (in the open-source code) is fine; per-key randomness is not.
- The human-recordable artifact is the **24 rolls**, not the seed bytes. The sigil encodes the rolls.
- **Tests:** a fixed roll sequence derives a pinned, fixed key; and generate-from-rolls then restore-from-the-same-rolls yields byte-identical keys. (Effective entropy on this path is ~173 bits vs. the auto path's full 256 — comfortable for the game; state it, don't over-warn.)

## Backup prompt after generation

Once a key is created, prompt to back it up:
- **Auto-generated key → encrypted key file only.** A random seed has no recordable rolls, so the sigil doesn't apply — state this in the UI.
- **Sacred-Forty key → both** the encrypted key file **and** the **paper sigil glyph**, since the rolls are recordable. (Coherence worth leaning into: the hand-crafted key earns a hand-drawable soul-glyph; the convenient path gets a file.)

**implement strong-but-skippable warning with the following text):** "You probably want to back your Runekey up in a really secure place. Losing access to your Runekey (because you dropped your spellbook in a lake or something) means you'd have to rebuild all your spells from scratch, even if you back them up. Also, if someone else get gains access... well probably nothing will happen. But theoretically if it was found by a both mean and motivated individual they could access spells crafted by you, impersonate you in narrative interactions, and babies may mistake them for you while playing peek-a-boo."

## The sigil (paper mnemonic) — port, don't redesign

The spiral-sigil encoding is already designed and prototyped: a spiral of 24 sequence-nodes spiraling inward, an outer ring of 20 result-values, and a chord from each roll's sequence-node to its result-value — the spiral guarantees repeated values stay visually distinct via different origin points, so it's hand-drawable and reconstructable. **Soren will provide the prototype (`sigil_concept.html`)** — use it as the spec for both the encoding geometry and the visual aesthetic. Port it to Flutter (`CustomPainter` or an SVG widget). It must render the player's actual 24 rolls, be legible enough to hand-draw and reconstruct, and be exportable/shareable as an image. **Do not invent a different encoding** — match the prototype.

## Aesthetic — the game's visual identity starts here

The sigil prototype establishes a direction worth adopting as the nascent design language: the game should visually match the appearance of a medieval manuscript of illuminated folio. Warm parchment backgrounds, inky black text, gothic style fonts, uppercase letterspaced headers. Colors appear as a visual metaphor for magic in the book becoming active.  Extend it across the onboarding screens so the key ritual feels of-a-piece.

Specific assets will be chosen and added later, so don't spend too much time trying to get details right, just approximate placeholders. (This is real UI, not a throwaway harness — visual craft matters here in a way it didn't for the diagnostic screens, clarity is important for now, precise aesthetic feel less so for now.)

## Scope

- **In:** the boot check, the four-path onboarding, the d20 derivation + tests, the post-generation backup prompt, the sigil port + image export, and wiring the existing M4 file import/export.
- **Out:** key rotation/revocation (the design's recover-from-theft mechanic — an explicit later event; M4 logged the delegation-resigning gap); the main menu (step 2); anything past identity bootstrap.
- **Don't modify** the M4 identity/backup library logic — wire it. If something there needs changing, flag it (that'd be a library gap, not a UI concern).

## Proceed

Read the M4 identity/backup code and the design doc's key/onboarding sections, propose the flow + the exact d20→seed derivation + the sigil port plan, surface the two design decisions (backup friction, aesthetic commitment), and wait for approval before building.
