# Attribution — 24x32 characters (wizard avatars)

This directory contains a derived form of third-party artwork: the walk blocks are
cropped, colour-keyed to real alpha and edge-bled by `scripts/build_avatar_pack.py`.
This file is the authoritative provenance record.

## Source

**"[LPC-ish] 24x32 characters with faces (big pack)"**, by
**Svetlana Kushnariova** (*Cabbit*), published on OpenGameArt.

Dual-licensed **CC BY 3.0** (https://creativecommons.org/licenses/by/3.0/) and
**OGA-BY 3.0** (https://opengameart.org/content/oga-by-30-faq), per the OpenGameArt
listing — confirmed 2026-08-03. Attribution is a *requirement* of both, unlike the
CC0 terrain pack. The credit line below must appear in the app's about/credits screen
for any build that ships this directory:

> Character sprites by Svetlana Kushnariova (lana-chan@yandex.ru), licensed
> CC BY 3.0 / OGA-BY 3.0.

Raw sources live under `assets/art/` and are **gitignored** (see `.gitignore`); only
this derived directory is tracked. Regenerate with:

    python3 scripts/build_avatar_pack.py

## Atlas layout

`avatar_atlas.png` is 432x1024 RGBA. Each character occupies one 72x128 cell,
laid out left-to-right / top-to-bottom in catalog order. Within a cell the frames are
a 3-column x 4-row grid of 24x32 poses:

| Row | Facing | | Column | Pose |
|---|---|---|---|---|
| 0 | up (away from viewer) | | 0 | step A |
| 1 | right | | 1 | **stand / idle** |
| 2 | down (toward viewer) | | 2 | step B |
| 3 | left | | | |

That is the RPG Maker 2000 charset order, *not* RPG Maker XP's. It was verified
against the art rather than assumed — see the build script's docstring.

`lib/ui/avatars/avatar_catalog.g.dart` is generated alongside this atlas and is the
canonical id → cell mapping.

## Characters

| id | name | category | source sheet | source sha256 |
|---|---|---|---|---|
| `fighter_f_01` | Fighter F 01 | heroes | `Fighter-F-01.png` | `37cebabf3fe11b50…` |
| `fighter_f_02` | Fighter F 02 | heroes | `Fighter-F-02.png` | `7e3daddb047d9d51…` |
| `fighter_m_01` | Fighter M 01 | heroes | `Fighter-M-01.png` | `d7e94029a6561a1c…` |
| `fighter_m_02` | Fighter M 02 | heroes | `Fighter-M-02.png` | `1931470f8d2747eb…` |
| `healer_f_01` | Healer F 01 | heroes | `Healer-F-01.png` | `c4ef2ca88a762985…` |
| `healer_m_01` | Healer M 01 | heroes | `Healer-M-01.png` | `bb12f08a7605fbd6…` |
| `mage_f_01` | Mage F 01 | heroes | `Mage-F-01.png` | `6971bca749f00250…` |
| `mage_m_01` | Mage M 01 | heroes | `Mage-M-01.png` | `1b9b5dd4d3d6cdb5…` |
| `ranger_f_01` | Ranger F 01 | heroes | `Ranger-F-01.png` | `847db8eacfc29ae4…` |
| `ranger_m_01` | Ranger M 01 | heroes | `Ranger-M-01.png` | `86a480805419dbcc…` |
| `aristocrate_f_01` | Aristocrate F 01 | npc | `Aristocrate-F-01.png` | `16098d8d61a731fa…` |
| `aristocrate_f_02` | Aristocrate F 02 | npc | `Aristocrate-F-02.png` | `4eb6ec51c562a567…` |
| `aristocrate_f_03` | Aristocrate F 03 | npc | `Aristocrate-F-03.png` | `55935b34828e522c…` |
| `bard_m_01` | Bard M 01 | npc | `Bard-M-01.png` | `e4d1986c2aa93391…` |
| `clown_01` | Clown 01 | npc | `Clown_01.png` | `6919efdb11878c94…` |
| `cultist_01` | Cultist 01 | npc | `Cultist-01.png` | `c48e6b746a2803a3…` |
| `dancer_f_01` | Dancer F 01 | npc | `Dancer-F-01.png` | `bf6e8c7c887d3ea1…` |
| `king_01` | King 01 | npc | `King_01.png` | `ebe8f2d533c3e6f5…` |
| `mask_m_01` | Mask M 01 | npc | `Mask-M-01.png` | `83c01b5e81ffe457…` |
| `npc_f_amanda` | NPC F Amanda | npc | `NPC_F-(Amanda).png` | `87bc31eb750ca615…` |
| `pirate_f_01` | Pirate F 01 | npc | `Pirate-F-01.png` | `5e60026b4b6bd565…` |
| `prince_01` | Prince 01 | npc | `Prince-01.png` | `d090f5d3a203da30…` |
| `princess_01` | Princess 01 | npc | `Princess-01.png` | `e6ed6598a649844e…` |
| `snow_m_01` | Snow M 01 | npc | `Snow-M-01.png` | `d852d859bdec8cb9…` |
| `townfolk_adult_f_001` | Townfolk Adult F 001 | npc | `Townfolk-Adult-F-001.png` | `4e07065719243bba…` |
| `townfolk_adult_f_002` | Townfolk Adult F 002 | npc | `Townfolk-Adult-F-002.png` | `289b7e8b29419b23…` |
| `townfolk_adult_f_003` | Townfolk Adult F 003 | npc | `Townfolk-Adult-F-003.png` | `10c737f0d3c42982…` |
| `townfolk_adult_f_004` | Townfolk Adult F 004 | npc | `Townfolk-Adult-F-004.png` | `5a9a7a08a8d26142…` |
| `townfolk_adult_f_005` | Townfolk Adult F 005 | npc | `Townfolk-Adult-F-005.png` | `d8eba5ecc0cbe026…` |
| `townfolk_adult_f_006` | Townfolk Adult F 006 | npc | `Townfolk-Adult-F-006.png` | `57699e41a6dc5e6c…` |
| `townfolk_adult_m_001` | Townfolk Adult M 001 | npc | `Townfolk-Adult-M-001.png` | `5e9f0afc15b92e10…` |
| `townfolk_adult_m_002` | Townfolk Adult M 002 | npc | `Townfolk-Adult-M-002.png` | `411547388d80e6d8…` |
| `townfolk_adult_m_003` | Townfolk Adult M 003 | npc | `Townfolk-Adult-M-003.png` | `7a653886d8a0fe81…` |
| `townfolk_adult_m_004` | Townfolk Adult M 004 | npc | `Townfolk-Adult-M-004.png` | `21fc4275325a694f…` |
| `townfolk_adult_m_005` | Townfolk Adult M 005 | npc | `Townfolk-Adult-M-005.png` | `34aa9b6b839c0eff…` |
| `townfolk_adult_m_006` | Townfolk Adult M 006 | npc | `Townfolk-Adult-M-006.png` | `e71de117acbf0dc2…` |
| `townfolk_adult_m_007` | Townfolk Adult M 007 | npc | `Townfolk-Adult-M-007.png` | `6e9d70334c11e33e…` |
| `townfolk_adult_m_008` | Townfolk Adult M 008 | npc | `Townfolk-Adult-M-008.png` | `2e2c62029d0f78df…` |
| `townfolk_adult_m_009` | Townfolk Adult M 009 | npc | `Townfolk-Adult-M-009.png` | `caff634090d50aab…` |
| `townfolk_child_f_001` | Townfolk Child F 001 | npc | `Townfolk-Child-F-001.png` | `ffbd94bb56496f5d…` |
| `townfolk_child_f_002` | Townfolk Child F 002 | npc | `Townfolk-Child-F-002.png` | `44278230c85dbc20…` |
| `townfolk_child_m_001` | Townfolk Child M 001 | npc | `Townfolk-Child-M-001.png` | `710fcd574553bf44…` |
| `townfolk_child_m_002` | Townfolk Child M 002 | npc | `Townfolk-Child-M-002.png` | `84766cad4b4390cc…` |
| `townfolk_old_f_001` | Townfolk Old F 001 | npc | `Townfolk-Old-F-001.png` | `fa75be45dac93a7b…` |
| `townfolk_old_m_001` | Townfolk Old M 001 | npc | `Townfolk-Old-M-001.png` | `c3ea3c82d9d40d9a…` |
| `townfolk_old_m_002` | Townfolk Old M 002 | npc | `Townfolk-Old-M-002.png` | `1417bf20aad98117…` |
