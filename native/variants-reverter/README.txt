variants-reverter: save converter for Forged & Found

You need this only to remove Forged & Found, or to take a character to a server without it.
Without the mod, the game deletes every variant item the next time a character or world loads.
This tool first turns those items back into their vanilla versions.

1. Switch the mod off or delete it. Do not start the game yet.
2. Back up your save folder. Characters and local worlds are in
   <Steam>\userdata\<your Steam id>\1203620\remote\ (character*.ksd, world*.ksd).
   A dedicated server keeps its world in its savegame folder.
3. For each save file, check what would change, then write a converted copy:
     variants-reverter.exe character0.ksd
     variants-reverter.exe character0.ksd --out character0.converted.ksd
4. Replace the original file with the converted copy (keep your backup), then start the game.

Converted items keep their level, rarity and durability and get their vanilla enhancements.
The tool never modifies its input file, checks every file the way the game does, and refuses
to write anything it cannot convert safely.

Keep variant-map.txt next to the program. Use the version that matches your Forged & Found,
or a newer one.

License: GPL-3.0 (LICENSE). Includes zstd, BSD license, Meta Platforms (LICENSE-zstd), and code
ported from xxHash, BSD-2-Clause, Yann Collet.
Source: https://github.com/theCrius/forged-and-found
