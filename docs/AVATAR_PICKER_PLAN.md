# Avatar Picker Plan — sprite-pack selection in Settings

*Written 2026-08-03 on `feature/practice-mode`. Implementation plan for the "choose your
avatar" work that `lib/ui/avatars/avatar_sprites.dart`'s header has been reserving space
for since the wizard-movement pass (its item 2: "(later) The player picks their avatar
from the catalog"). This document is the spec; the file comments it names are the
authority on the seams.*

**Everything here is cosmetic.** No engine code reads an avatar id, nothing is hashed
into `BattleState.toCanonicalBytes()`, and a device with a missing atlas still plays a
byte-identical match. The one non-cosmetic-looking piece — the LAN handshake exchange in
Phase 5 — exists only so both players see the same board, and is explicitly
*unauthenticated presentation data*, exactly like `wizardName` (0x1D).

---

## 1. Goal

A **Settings → Avatar** section where the player browses the shipped character pack as
**portrait art** (the face images in the source sheets, which the pack currently throws
away) and picks the character their wizard wears on the battlefield. All three source
directories are offered: **Heroes**, **Monsters**, **NPCs**.

That means four pieces of work, in this order:

1. **Art pipeline** — teach `scripts/build_avatar_pack.py` to include `Monsters/` and to
   emit a second atlas of portraits.
2. **Dart catalog** — a `monsters` category, portrait rects, a portrait-atlas loader.
3. **Persistence** — the chosen id in `Identity`, beside the wizard name.
4. **UI + wiring** — the settings section, the picker screen, and getting the choice onto
   the battlefield on *both* devices.

### Out of scope (do not drift into these)

- Using monster sprites for **summoned minions**. Tempting adjacency, different feature,
  needs its own design pass — `Minion` has no art seam today.
- Walk/idle **animation** of the sprite (`avatar_sprites.dart` header item 3). Untouched.
- Per-spell / per-chapter avatars, unlockables, recolours, importing player art.
- Changing anything about how the walk block is cut, keyed or drawn.

---

## 2. Decisions

**D1 — Monsters are selectable.** `build_avatar_pack.py` currently excludes `Monsters/`
with the comment *"Characters wear a person, not a mushroom"*. Soren asked for monsters
in the picker, so that decision is reversed: **replace that comment** (don't leave a
comment contradicting the code) with a line noting monsters are player-selectable by
request, 2026-08-03.

**D2 — Portraits keep their opaque background; they are not colour-keyed.**
`build_avatar_pack.py`'s docstring already records why: the transparency key (teal
`(0,117,117)`) *also appears as legitimate art colour inside the portrait region*, which
is why the current script only keys the 72×128 walk block. Keying portraits would punch
holes in hair and clothing. Portrait cells therefore ship fully opaque, and read as
framed portrait cards in the picker — which is how the source art presents them anyway.

**D3 — Portrait cells are uniform 96×96, pad-centred, not scaled.** Measured portrait
sizes across all 53 sheets: min 47×60 (`Seed-01`), max 81×86 (`Shrump-01` is 81×75;
`Mushroom-01` 63×86), plus the `Flower-01` override at 81×90. 96×96 covers every one with
room to spare. Pad with the key teal `(0,117,117)` so a cell is a clean square card.
No per-portrait scaling: relative sizes are part of the art.

**D4 — `Mermaid_01.bmp` is included via a hand-measured override, not excluded.** It is
the one irregular sheet (245×245 BMP, dev annotations in red baked into the art, portrait
in the lower-left instead of the top-right). Its walk block *is* standard 24×32 3×4 at the
origin, and its portrait is cleanly locatable at `(13, 181, 63, 62)` — see §3.3. If it
turns out to render badly, dropping it is a one-line change; don't drop it pre-emptively.

**D5 — The LAN handshake gains one message and the protocol version bumps 2 → 3.** See
§5.2 for the reasoning; this is the only decision here with a wire consequence.

Nothing in this list needs Soren before you start.

---

## 3. Phase 1 — art pipeline (`scripts/build_avatar_pack.py`)

The script is deterministic and idempotent, output is a pure function of the input
sheets, and it already emits the atlas + `ATTRIBUTION.md` + the generated Dart catalog.
Extend it; do not write a second script.

### 3.1 Include Monsters

```python
SOURCE_SUBDIRS = ["Heroes", "NPC", "Monsters"]
```

**Monsters goes last, on purpose.** Catalog order is source order, and atlas cells are
packed in catalog order, so appending Monsters leaves every existing hero/NPC id at the
*same* atlas cell it occupies today — the walk atlas grows from 432×1024 (6×8 cells) to
432×1152 (6×9, 53 characters in 54 cells) and existing rows are untouched. Reordering
would churn the whole generated catalog for nothing.

Ids are stable and load-bearing (`AvatarArt.id` is what gets persisted): `slug()` gives
`flower_01`, `grass_spirit_01`… wait — check what `slug()` actually produces for
`GrassSpirit-01` (it splits on non-alphanumerics, so `grassspirit_01`) and just record
whatever it emits; do **not** hand-tune the slug function to prettify monster names. The
human-facing string is `AvatarArt.name`, which is free to change.

Two source-format facts to handle:

- `Mermaid_01.bmp` is a **BMP**, not a PNG. The loader globs the directory — make sure
  the glob accepts `.bmp` (and that `load_walk_block`'s "expected a palette image" check
  still passes: it's mode `P`, so it does).
- `Flower-01.png` (225×128) and `Shrump-01.png` (160×128) are **wider** than the standard
  153×128. `load_walk_block` crops `(0, 0, 72, 128)` so the extra content — Flower's
  second charset block at x≥153 — is already ignored. Verified: every monster sheet's
  walk block is the standard 3-col × 4-row grid of 24×32 frames at the origin.

### 3.2 Emit a portrait atlas

New outputs:

- `assets/art_pack/avatars/avatar_portraits.png` — RGBA, opaque cells, 96×96 per
  character, packed **left-to-right / top-to-bottom in the same catalog order** as the
  walk atlas. 53 characters at `ATLAS_COLS = 6` → 6×9 cells → 576×864.
  (Reuse `ATLAS_COLS` so the two atlases stay index-aligned and mentally interchangeable.)
- Portrait cell coordinates in `lib/ui/avatars/avatar_catalog.g.dart` — see §4.

No `pubspec.yaml` change is needed: `assets/art_pack/avatars/` is already declared as a
whole directory (pubspec.yaml:140).

### 3.3 Locating the portrait in a source sheet

The portrait region is everything right of the walk block (`x >= BLOCK_W`, i.e. 72). Its
geometry is **not** fixed — box size and offset vary per sheet, and several sheets have a
pixel-font caption ("Mage F", "flower") underneath the box. Detection rule, which I
verified against all 53 sheets:

1. Let `bg` = the most common RGB in the region `x >= 72`. For 51 of 53 sheets this is
   the sheet background grey `(107, 138, 139)`.
2. If `bg == KEY_RGB` (`(0,117,117)`), the sheet has no grey margin and the rule cannot
   work → require an entry in the override table (step 4).
3. Otherwise the portrait box is the **bounding box of key-coloured pixels within
   `x >= 72`** — the box's interior background is key teal, the surrounding margin is
   grey, and caption glyphs are white/black, so the caption is excluded automatically.
4. Manual overrides, keyed by source filename (rect is `(x, y, w, h)` in sheet
   coordinates, measured for this plan — use these numbers):

   | sheet | portrait rect | why |
   |---|---|---|
   | `Flower-01.png` | `(72, 0, 81, 90)` | whole sheet background is key teal; rows 90+ are the grey caption band |
   | `Mermaid_01.bmp` | `(13, 181, 63, 62)` | irregular sheet; portrait sits lower-left, below the walk block |

5. **Fail loudly**, listing the offending sheet and the rect it computed, if a detected
   rect is smaller than 32×32, larger than the 96×96 cell, or outside the sheet. A
   silently-garbage portrait is worse than a build error: the whole point of the picker is
   that the portrait is what the player browses. (Sanity band from the measurements: every
   auto-detected rect lands in 47..81 wide × 60..86 tall.)

Then: crop the rect, paste centred into a 96×96 cell pre-filled with key teal, opaque.
No bleed pass, no keying (D2) — `bleed()` exists for the filtered-draw halo on the
*transparent* walk sprites and has nothing to do here.

### 3.4 Contact sheet for eyeballing

Also emit `avatar_portraits_contact.png` (or write it to a path given by an env var, à la
`WIZARD_PREVIEW_DIR`) — the whole portrait atlas at 2× with each cell's id drawn under
it. This is how you check 53 portraits in one look instead of trusting the rule. It's a
build artefact for humans; keep it out of `assets/` if you'd rather not ship it, but do
generate it and *do look at it* before moving on.

### 3.5 Attribution

`ATTRIBUTION.md` is generated, so the monster rows and the new atlas's geometry appear
automatically once the script knows about them — but check the output:

- The layout section describes only `avatar_atlas.png` today. Add the portrait atlas's
  geometry (96×96 cells, catalog order, opaque, key-teal padding) and state that portraits
  are *uncropped source art* with their own backgrounds.
- ~~Leave the existing `[CONFIRM — Soren]` note about the missing licence file exactly as
  it is. It is still open.~~ **Resolved 2026-08-03:** the OpenGameArt listing's terms were
  confirmed as dual **CC BY 3.0 / OGA-BY 3.0**, and the note was dropped from
  `ATTRIBUTION.md`, `CREDITS.md`, and `scripts/build_avatar_pack.py`. Do **not** re-add it.
  Monsters come from the same pack under the same terms, so `lib/ui/credits_screen.dart`
  needs no further change (it credits Svetlana Kushnariova under both licences).

---

## 4. Phase 2 — Dart catalog and atlas (`lib/ui/avatars/`)

### 4.1 `avatar_sprites.dart`

- `enum AvatarCategory { heroes, npc, monsters }` — append `monsters`. The enum is never
  serialized (only `AvatarArt.id` is persisted), so appending is safe; say so in a
  comment so nobody later assumes ordering is load-bearing. Update the enum's doc
  comment: it currently says the category is "only a grouping hint for the future picker
  UI" — the picker is now real, so it's the tab grouping.
- Portrait geometry constants beside the frame ones:
  `kAvatarPortraitCell = 96`, and `kAvatarPortraitCols` mirroring the script's
  `ATLAS_COLS`.
- `AvatarArt` gains `portraitCol` / `portraitRow` and a
  `Rect get portraitRect => Rect.fromLTWH(portraitCol * 96, portraitRow * 96, 96, 96)`,
  matching `frameRect`'s existing shape.
- `class AvatarPortraitAtlas` — a straight copy of `AvatarAtlas`'s shape (static cached
  decode, `imageOrNull`, `load()`, `resetForTest()`), pointing at
  `assets/art_pack/avatars/avatar_portraits.png`. Same one-decode-per-process property;
  same "null means draw a placeholder, never an error" contract.
- `AvatarAssignment.explicit`'s doc comment currently reads *"Empty today; the future
  picker fills it"*. Rewrite it to describe what actually happens now, and **keep its
  warning intact** — it is the single most important paragraph in this plan's blast
  radius:

  > A locally-stored choice is invisible to the peer, so a chosen avatar has to travel in
  > the handshake and be installed here via `explicit` on BOTH devices.

  Also update the file header's numbered list: item 2 is now done (point at this doc),
  item 3 (animation) still pending.
- Leave `_defaultFor` alone. It picks from `AvatarCategory.heroes` only, so adding
  monsters/NPCs to the catalog does not change any existing wizard's default sprite, and
  the "pure function of playerId, identical on both devices" property survives untouched.
  `selectableAvatars` stays "everything in the catalog" — now genuinely all three
  categories.

### 4.2 `avatar_catalog.g.dart`

Regenerated, never hand-edited. After regeneration it must contain: 53 entries, the 46
existing ids **unchanged and at their existing `atlasCol`/`atlasRow`**, 7 new monster
entries, portrait coordinates on every entry, and updated
`kAvatarAtlasWidth/Height` + new portrait-atlas dimension constants.

Diff-check that claim explicitly (`git diff` on the generated file) before proceeding.
If a hero or NPC's atlas cell moved, the pack was packed in a different order than §3.1
prescribes — fix that, don't accept it.

---

## 5. Phase 3–5 — persistence, UI, wiring

### 5.1 Persistence (`lib/identity/identity.dart`)

Add beside the wizard-name pair, following it exactly:

```dart
const _kAvatarIdKey = 'runewright.identity.avatar_id_v1';

static Future<void> saveAvatarId(String avatarId) async { ... }
static Future<String?> loadAvatarId() async { ... }   // null == "use the default"
```

Add `_kAvatarIdKey` to `deleteOnDevice()`'s wipe list — it's part of the local identity,
and the debug reset is meant to return the device to a first-launch state.

Not sensitive, no migration: a null read means "deterministic default", which is exactly
today's behaviour.

### 5.2 The wire (`lib/battle/networking/`)

`battle_wire.dart` — add one type after `wizardName(0x1D)`:

```dart
avatarId(0x1E),  // UTF-8 AvatarArt.id, may be empty
```

`battle_session.dart` — add `exchangeAvatarId(String ours)` **immediately after
`exchangeWizardName`, copying its shape verbatim** (send first, then
`framesOfType(...).first`). That ordering is not stylistic: this repo has already been
bitten by a broadcast-stream frame being dropped when a listener attached after the send
(see the commune/trade two-device bugs). Follow the proven shape; don't invent a
combined name+avatar message.

Doc comment must say, in the same terms as `exchangeWizardName`'s: unauthenticated,
presentation only, never fed into cast authorization or the state-hash lockstep. An
unknown id degrades to the default via `avatarArtById` returning null.

`duel_setup.dart` — extend **step 4b** (the existing wizard-name step, right after
identity auth):

```dart
final myAvatarId = await Identity.loadAvatarId() ?? '';
final peerAvatarId = await session.exchangeAvatarId(myAvatarId);
```

Carry `peerAvatarId` (and the local one) out through new `DuelSetupResult` fields. Do
**not** thread avatar ids into `buildDuelBattleState` — `WizardAvatar` must not grow a
cosmetic field; `wizardName` is on the avatar because the HUD needs it inside engine
state, whereas the sprite map lives purely in the UI layer via `AvatarAssignment`.

`match_discovery.dart` — bump `kBattleProtocolVersion` to **3** and add a paragraph in
the same style as the v2 note:

> v3 (2026-08-03, avatar picker): the setup flow gained a `avatarId` (0x1E) exchange in
> step 4b. A v2 client never sends it, so a v3 client would block forever on
> `framesOfType(avatarId).first` — a hang, not a failure. Aborting at the capabilities
> gate turns that into a legible error.

### 5.3 The picker (`lib/ui/avatars/avatar_picker_screen.dart`)

New screen; mirror `lib/ui/spell_art_pack_screen.dart`, which is this repo's established
pattern for "browse a built-in asset pack and return an id" — including its
`Future<String?> pickX(BuildContext)` push helper, its filter chips, its
`manuscript_theme.dart` styling, and its "purely a picker over an already-built pack, no
hostile bytes, no failure path" framing.

- **Portrait grid is the primary surface** (the whole point of the feature): a
  `GridView` of 96×96-source portrait tiles drawn with `CustomPaint` from
  `AvatarPortraitAtlas`, `FilterQuality.none` and `isAntiAlias = false` — this is indexed
  pixel art; any smoothing looks wrong and the battlefield already draws it this way.
  `AvatarArt.name` under each tile.
- **Category filter chips**: All / Heroes / Monsters / NPCs (label `AvatarCategory.npc`
  as "NPCs"). Default to All so monsters are discoverable without hunting.
- **Selected tile** gets a gold `kIlluminationGold` frame; the currently-saved avatar is
  pre-selected on open.
- **Detail preview before committing**, again mirroring the art-pack screen's
  tap-to-preview: the portrait large, the name, and a **sprite strip** — the `stand` pose
  in all four `AvatarFacing` values from the walk atlas, drawn at 3–4× — then Choose /
  Cancel. The strip matters: the portrait is the browsing handle, but the walk sprite is
  what the player will actually stare at for a whole duel, and for several monsters the
  two read very differently.
- **Atlas-null tolerance.** `test/ui/wizard_movement_preview_test.dart` records that
  `rootBundle` is unavailable outside a real app, so a widget test cannot decode the
  shipped atlas the normal way. Tiles must render a labelled placeholder when
  `imageOrNull` is null, and the screen should accept optional injected
  `portraitAtlas` / `spriteAtlas` images (or expose the same via
  `@visibleForTesting`) so a widget test can drive the real layout with a fake image.
  Never let a missing atlas throw.

### 5.4 Settings section (`lib/ui/settings_screen.dart`)

Add an **Avatar** `Card` as the *first* section (it's the most concrete and least
consequential control on the page; the leyline seed deserves to stay below the fold):
current portrait thumbnail + character name + a "Change" button that awaits the picker
and, on a non-null result, `Identity.saveAvatarId(id)` + `setState`.

Load the saved id the way the leyline seed is loaded — via the separate,
never-blocking `_loadSeed`-style path with its own `try/catch`, for the reason that
function's doc comment already gives: secure storage has no platform channel under
`flutter test`, and awaiting it in `_load` would strand the screen on its spinner. Copy
that pattern; do not await avatar loading inside `_load`.

Also extend the file header's bullet list — it enumerates the screen's sections, and a
new section that isn't listed there is how that comment starts rotting.

### 5.5 Onto the battlefield (`lib/ui/battle_screen.dart`)

Today: `final AvatarAssignment _avatarAssignment = const AvatarAssignment();`
(battle_screen.dart:358). Change it to non-final state, built from two inputs:

- **Local:** `Identity.loadAvatarId()` in `initState`'s async load (beside
  `_loadAvatarAtlas`, battle_screen.dart:764), keyed by `widget.localPlayerId`.
  Wrap in try/catch — same secure-storage-in-tests reason as §5.4 — and on failure just
  keep the default assignment.
- **Peer:** a new optional `BattleScreen({this.peerAvatarId})` param, passed by
  `battle_lobby_screen.dart:286` from `DuelSetupResult`, keyed by
  `widget.peerOwnerPubkeyHex`. In a LAN duel `playerId == ownerPubkeyHex`
  (`duel_battle_setup.dart`: *"Player ids are the two owner hex strings themselves"*), so
  that key is correct — but assert/comment it rather than leaving a reader to rediscover
  it.

`solo_practice_settings_screen.dart:204` and `spell_test_lab_screen.dart:284` pass no
`peerAvatarId`; the dummy keeps its deterministic default, and the local wizard picks up
the player's choice for free. `battlefield_painter.dart` needs **no** change — it already
takes an `avatarAssignment`.

Update battle_screen.dart:355-358's comment ("Const-default today… the avatar picker
fills this in later") to describe the real mechanism.

---

## 6. Tests

Match the existing split: assertions in one file, eyeball previews behind an env var.

**`test/ui/avatar_catalog_test.dart`** (new, or extend the `avatar sprite seam` group in
`test/ui/wizard_movement_animation_test.dart` — that group already owns catalog
invariants):

1. All three categories are non-empty; the catalog has 53 entries.
2. **Id stability**: assert a hard-coded handful of pre-existing ids
   (`fighter_f_01`, `mage_f_01`, `npc_f_amanda`, `townfolk_old_m_002`) are still present.
   This is the regression guard for "someone reordered `SOURCE_SUBDIRS`".
3. Portrait rects stay inside the portrait atlas — the exact shape of the existing
   "frame rects stay inside the atlas" test, which needs no change itself since it reads
   the generated dimension constants.
4. Portrait rects are unique per entry (catches a packing bug that aliases two cells).
5. `_defaultFor` still only returns heroes, and is unchanged for a fixed set of playerIds
   — pin the actual ids so adding monsters can never silently reshuffle defaults.

**`test/ui/avatar_picker_test.dart`** (new): pump the picker with an injected fake atlas
image; assert a monster tile is reachable from the Monsters chip, that tapping →
Choose pops the chosen id, that Cancel pops null, and that it renders without throwing
when the atlas is null.

**`test/ui/settings_avatar_section_test.dart`** (new, `installFakeSecureStorage()` from
`test/identity/fake_secure_storage.dart`): the section renders, and a saved id survives
`saveAvatarId` → `loadAvatarId`.

**`test/battle/networking/duel_setup_test.dart`** (extend): give host and guest
*different* avatar ids and assert each ends up with the other's in `DuelSetupResult` —
the same "no stubbed peer value" discipline that test already applies to artifact
loadouts. This is the test that catches the §4.1 warning being violated.

**`test/ui/avatar_portrait_preview_test.dart`** (new, optional, no-op without an env var):
render the portrait grid to PNG, in the spirit of `wizard_movement_preview_test.dart`.
The pipeline's contact sheet (§3.4) covers most of this; add it only if useful.

Full-suite run before you call it done: `flutter test`. The suite was 1102 green at the
last milestone; nothing here should move a pre-existing test other than the generated
catalog's dimension constants.

---

## 7. Verification gate

The repo's hierarchy is *hardware run > golden corpus > integration test > unit test > "it
compiles"*, and this feature is entirely visual, so:

1. **Look at the contact sheet.** 53 portraits, correct art, nothing clipped, nothing
   showing a caption or a stray red annotation. This catches §3.3 failures the tests
   cannot.
2. **`flutter run -d linux`** — Settings → Avatar → browse all three categories → pick a
   monster → start a solo practice battle → confirm the wizard token wears it, at all four
   facings, unsmoothed. This is the cheap UI target and it is not optional.
3. **Two-device LAN pass is the real gate for §5.2/§5.5**, and it is the *only* thing that
   proves the property `AvatarAssignment` warns about: pick different avatars on the two
   devices and confirm **both screens show the same two sprites**. A choice applied only
   locally does not fail loudly — each player just sees a different board. If a
   two-device run isn't possible in this session, say so explicitly and leave it on the
   outstanding list; do not report the feature as complete.

No circuit, stepper, vector-corpus or `RULESET_VERSION` involvement. `bb gates` is not
needed — nothing here touches a constraint.

---

## 8. File-by-file summary

| file | change |
|---|---|
| `scripts/build_avatar_pack.py` | + Monsters, + portrait atlas, + override table, + fail-loud checks, + contact sheet |
| `assets/art_pack/avatars/avatar_atlas.png` | regenerated (432×1152) |
| `assets/art_pack/avatars/avatar_portraits.png` | **new** (576×864) |
| `assets/art_pack/avatars/ATTRIBUTION.md` | regenerated + portrait-atlas geometry |
| `lib/ui/avatars/avatar_catalog.g.dart` | regenerated (53 entries + portrait coords) |
| `lib/ui/avatars/avatar_sprites.dart` | `monsters` category, portrait rects, `AvatarPortraitAtlas`, doc updates |
| `lib/ui/avatars/avatar_picker_screen.dart` | **new** |
| `lib/ui/settings_screen.dart` | + Avatar section, + header bullet |
| `lib/identity/identity.dart` | + `save/loadAvatarId`, + wipe key |
| `lib/battle/networking/battle_wire.dart` | + `avatarId(0x1E)` |
| `lib/battle/networking/battle_session.dart` | + `exchangeAvatarId` |
| `lib/battle/networking/duel_setup.dart` | step 4b exchange + `DuelSetupResult` fields |
| `lib/battle/networking/match_discovery.dart` | `kBattleProtocolVersion` 2 → 3 + note |
| `lib/ui/battle_screen.dart` | local + peer avatar → `_avatarAssignment` |
| `lib/ui/battle_lobby_screen.dart` | pass `peerAvatarId` |
| tests | per §6 |

`pubspec.yaml`, `credits_screen.dart`, `battlefield_painter.dart`, and every engine file:
**unchanged**.

---

## 9. Traps

- **Never hand-edit `avatar_catalog.g.dart`.** It says so at the top. Regenerate.
- **`git diff` the regenerated catalog and confirm no existing id changed atlas cell.**
  Ids are what get persisted; a shifted cell means yesterday's saved choice now shows a
  different character.
- **Don't `dart-format` whole files.** This repo is not format-clean; a whole-file format
  balloons the diff by a thousand lines and drags in other people's WIP. Match the
  surrounding indentation by hand. (`git status` on this branch is already dirty with
  unrelated work — keep your diff surgical.)
- **Portrait keying is a trap with a comment already attached to it** — see D2 and the
  build script's docstring. If you find yourself calling the key-out path on a portrait,
  stop.
- **The peer-avatar path is the seam that fails quietly.** §5.2 + §5.5 + the duel-setup
  test + the two-device pass all exist for that one property.
- **`AvatarCategory.npc` is the enum name; "NPCs" is the label.** Don't rename the enum
  value — it appears in the generated catalog and regeneration must stay a no-op diff.
- Write anything you learn — especially anything about portrait geometry that this plan
  got wrong — into `docs/M4_findings.md`, not just into the chat.

---

## 10. Suggested commits

Small and legible, in dependency order:

1. `Avatar pack: include Monsters and emit a portrait atlas` (script + regenerated
   assets + regenerated catalog)
2. `Avatar sprites: monsters category and portrait atlas loader` (`avatar_sprites.dart`)
3. `Identity: persist the chosen avatar id`
4. `Settings: avatar picker section` (picker screen + settings section + tests)
5. `Battle: wear the chosen avatar, locally and over LAN` (wire + duel_setup + battle
   screen + protocol bump + tests)

Commits 1–4 are independently reviewable and none of them changes battle behaviour;
commit 5 is the one that touches the wire, and it's the one that needs the two-device run.
