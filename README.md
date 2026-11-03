# Forged & Found

An Enshrouded mod for [ShroudForge](https://github.com/bonsaibauer/shroudforge) that makes
looted and crafted equipment more interesting. It has three features plus two options.
Each one is a separate switch in the mod's ShroudForge settings, and all start **off**.

> **Beta.** Back up your saves before installing or updating it.

## Features

### Variant drops
Every item that can drop as Epic or Legendary gets six **variants**: the same item with a
different set of enhancements (the right-hand "Enhancements" column of its upgrade rows).
Variants follow themes (sustain, empower, elemental, physical, crit, character skills),
some mix skills from a second class, and a Legendary variant always ends with a +2
character skill.

When an Epic or Legendary item drops from a **random** chest, enemy remains or boss loot,
it rolls among the vanilla item and its six variants. Fixed chest contents, items you pick
up in the world or get by interacting with objects (including lore items), and the gear an
enemy carries are never changed.

Turning the switch off only stops new variants from dropping. Variants you already own
stay variants and keep working while the mod is installed.

### Crafted equipment rarity by level
Armor, shields and weapons crafted at the artisans get their rarity from their item level:
up to 5 Common, up to 10 Uncommon, up to 15 Rare, above that Epic (already Legendary items
stay Legendary). Each rarity step up or down changes the crafting cost by 25%.

### Crafted lore items
Copies of lore items crafted at the artisans become Legendary (crafting cost +50%) and are
raised to the item level of the crafted armor of their tier, also in the crafting preview.

Items crafted before you switch a crafting feature on or off keep the rarity they were
crafted with.

### Mark variants with § (display option)
Shows "§" in front of the name of every variant item (for example "§ Scorching Wand"), so
you can tell variants from vanilla items at a glance. It only changes what you see in your
own game; each player decides for themselves, and it has no effect on a server.

### Allow on untested game versions (advanced, at your own risk)
Variant drops and the § marker rely on a small native part that hooks a few game
functions. After a game update their addresses change, so by default those two features
stop until the mod is updated (everything else keeps working, and variants you own stay
safe). With this switch on, the mod looks for the functions in the new game version by
itself and uses them if every check passes. The checks confirm the functions look and
connect as before, but cannot prove the game still uses them the same way. With the switch
off, the search still runs and writes its result to the mod's log
(`<game>/shroudforge/logs/forged-and-found-native.log`).

## Requirements

- Enshrouded on Windows. Tested game versions: 1273043 and 1283531 (the update of
  2026-11-02). On other versions the native part stays inactive unless "Allow on untested
  game versions" is on (see above), and logs why.
- ShroudForge 1.7.7 or newer.
- Multiplayer: the mod also runs on a dedicated server that has ShroudForge. **Every player
  on that server needs the mod too**: a player without it cannot see variant items and loses
  them. On a server, the server's settings decide what drops and what is crafted.

## Install

1. Download the newest version:
   [forged-and-found.zip](https://github.com/theCrius/forged-and-found/releases/latest/download/forged-and-found.zip)
   (always the latest release; older versions are on the [releases](../../releases) page).
2. Copy its `forged-and-found` folder into `<game>/mods/` (next to `enshrouded.exe`).
3. Start the game, open the ShroudForge mod list and switch on the features you want.
   Changing a switch needs a restart.

Updating replaces the mod folder, which resets the switches to off.

## Dedicated server

The server needs ShroudForge installed beside `enshrouded_server.exe` (see ShroudForge's
server guide) and the `forged-and-found` folder in its `mods` folder. Hosts that only let
you edit the save files and the server config, and always start the official server
program, cannot run mods at all.

**On a server, the server's switches decide** what drops and what is crafted. Change them
in either of these ways, then restart the server:

- On a Windows server you can log into, start `shroudforge\shroudforge.exe` in the server
  folder without arguments (or double-click it). It opens the ShroudForge window for that
  installation; select "Forged & Found" and use its switches. The same from PowerShell,
  in the server folder:
  ```
  .\shroudforge\shroudforge.exe
  ```
- On any server whose files you can edit (also Docker/Proton hosts), open
  `mods/forged-and-found/extended.mod.json` and set `"value"` to `true` (on) or `false`
  (off) for each feature: `variantDrops`, `craftedEquipmentRarity`, `craftedLoreItems`.
  Example:
  ```json
  "variantDrops": {
    "value": true,
  ```

Every player needs the mod too, and should **switch on the same crafting features as the
server**: the crafting screen shows rarities and costs from the player's own game data, so
different switches would show other costs or rarities than the server applies. The
"Variant drops" switch only matters on the server, which rolls the loot.

Updating the mod on the server replaces `extended.mod.json` and resets the switches to
off, so set them again after each update.

## Removing the mod

Switching the mod off in ShroudForge (or deleting it) makes the game **delete every variant
item** the next time a character or world is loaded, because the game no longer knows them.
To keep them, convert them back into their vanilla items first with `variants-reverter.exe`
(in the release zip):

1. Switch the mod off or delete it. Do not start the game yet.
2. Back up your save folder. Characters and local worlds are in
   `<Steam>\userdata\<your Steam id>\1203620\remote\` (`character*.ksd`, `world*.ksd`); a
   dedicated server keeps its world in its `savegame` folder.
3. For each save file, check what would change, then write a converted copy:
   ```
   variants-reverter.exe character0.ksd
   variants-reverter.exe character0.ksd --out character0.converted.ksd
   ```
4. Replace the original file with the converted copy (keep your backup), then start the game.

Converted items keep their level, rarity and durability and get their vanilla
enhancements. The tool never modifies its input file, checks every file the way the game
does, and refuses to write anything it cannot convert safely.

## Building from source

Needs Windows, PowerShell 7 and the Visual Studio 2022 Build Tools (C++ workload).

```powershell
./tools/package.ps1     # builds everything and writes dist/forged-and-found-<version>.zip
```

Or separately: `native/build.ps1` (the mod's DLL, copied into `mods/forged-and-found/bin/`)
and `native/build-reverter.ps1` (`native/build/reverter-Release/variants-reverter.exe`).

Pushing a tag `v<version>` matching `mods/forged-and-found/mod.json` builds the zip on
GitHub Actions and publishes it as a release.

| Path | Contents |
|---|---|
| `mods/forged-and-found/` | The ShroudForge package: `src/mod.lua` (variants, registrations, crafting changes), `data/pinned.txt` (the fixed enhancement rolls of every variant), settings in `extended.mod.json` |
| `native/forged-and-found-native/` | The DLL that swaps random Epic/Legendary loot for variants and renders the optional "§" test marker |
| `native/variants-reverter/` | The save converter and its variant map |
| `native/third_party/zstd/` | zstd decoder (BSD license) used by the reverter |
| `tools/` | Packaging and the variant-map generator |

Variant item ids are derived from a fixed seed and the pinned list, so they stay the same
across versions, machines and game updates. Never change the seeds in `mod.lua` or remove
lines from `data/pinned.txt`: existing variant items would be lost.

## License

GPL-3.0, see [LICENSE](LICENSE). Bundled third-party code: zstd (BSD license, Meta
Platforms, `native/third_party/zstd/LICENSE`); the XXH3 checksum in the reverter is ported
from xxHash (BSD-2-Clause, Yann Collet). Built for ShroudForge (MIT, bonsaibauer).
