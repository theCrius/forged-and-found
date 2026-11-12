-- Forged & Found 0.16.1 (ShroudForge only; variants via native post-draw swap; optional "§" marker rendered by the DLL; client and dedicated server; three features and two options switchable in ShroudForge, all off by default).
--
-- Vanilla items are never changed. For every item with perks that can drop as
-- Epic or Legendary, this creates up to MAX_VARIANTS variants (clones with
-- rerolled perks, see "Roll perks" for the rules) that exist only as Epic or
-- Legendary, and registers each one everywhere the game looks items up by
-- ItemId or GUID:
--   - ItemInfo clone that keeps the original's objectId. The item icon renderer
--     ("doItemRenderFrame", enshrouded.exe+0xBEFAE0 -> +0xCF5260) loads the
--     UiTextureResource named by ItemInfo.objectId (+4), so variants show the
--     original's pre-rendered icon and need no texture of their own (the UI
--     texture loader has a fixed number of slots). Tested in 0.2.10: variant
--     and original stay independent (equip, storage, reload, upgrades).
--   - ItemRegistryResource (itemRefs + dbgNames) and LootableItemsResource.items
--     (parallel arrays, appended at the same index)
--   - not ItemKnowledgeResource since 0.15.2: entries there broke item knowledge for
--     ~2000 vanilla items (see "Item knowledge" below)
--   - GameKnowledgeResource world/player knowledge maps (an item's ItemId is
--     also its KnowledgeId)
--   - Name "§ <original name>" in every language, rendered at runtime by the
--     native DLL (see "Variant marker"). Optional: the variantMarker setting.
--
-- Loot (developer's design, 2026-11-01): this script changes no loot data. All
-- loot tables, fixed chests and world items stay vanilla; variant loot entries
-- carry no labels, so random loot never picks them (adding them overflowed the
-- picker's 1024-entry candidate list, research/loot-candidate-cap.md). Variants
-- reach players only through the native DLL: after the game has picked an item
-- and its rarity in random container loot (chests, enemy remains, boss loot), an
-- Epic or Legendary item with variants is rolled among {vanilla, its variants}.
-- Fixed chest contents, world pickups, anything obtained by interacting with an
-- object, and direct enemy drops (carcasses, harvest, an enemy's own gear) are
-- never swapped: a specific item placed there is intended.
--
-- Determinism: variant GUIDs derive only from the original GUID, the variant
-- index and SEED (ItemId = game.guid.hash(GUID)), so variant k of an item has
-- the same ItemId on every launch and machine. Perks come from the pinned list
-- shipped in data/pinned.txt, so game updates cannot reshuffle them; only items
-- missing from that list are rolled (deterministically from SEED and the
-- current perk pools) and exported for the next release.
--
-- Loader notes (ShroudForge's asset API, whose value engine is a fork of EML's;
-- see shroudforge/modules/mod-runtime/lua/resource_values/):
--   - resource.data is a cached live view; edits to it are tracked (dirty flags
--     propagate up) and written when patches are applied. Do not reassign
--     `resource.data = data` after editing: that clones the whole view again.
--   - Indexing resource.data marks values as touched, so read-only access goes
--     through tostring().
--   - Every value the loader keeps alive costs a Lua reference slot (limit ~1M,
--     "out of auxiliary stack space"). A Lua table assigned/inserted into a
--     resource becomes a full tree of such values; an existing element inserted
--     with table.insert is cloned cheaply (shared bytes). So: insert clones of
--     existing elements and edit only the fields that change.
--   - Arrays grow only via table.insert.

-- ShroudForge runs this script with patch access in its pregame asset pass. In any
-- other phase (e.g. the in-game runtime, which the export capability opts into)
-- there is nothing to do: the patch from the asset pass is already in the files.
if not loader.features.patch then
    shroudforge.log.info("[forged-and-found] no patch access in this phase, nothing to do")
    return
end

-- The seeds keep the mod's first name (Perk Variants) on purpose: every variant GUID and
-- ItemId is derived from SEED, so renaming it would orphan every variant in every save.
local SEED = "perk-variants/v0"          -- variant GUIDs (never change: saves store them)
local ROLL_SEED = "perk-variants/rolls-v1" -- rolls of items not in the pinned list
-- Only items that can drop as Epic or Legendary get variants (~745). Total
-- variants must stay within what is known to start: 4795 worked (0.2.6/0.2.9);
-- 9579 overflowed a ~4 MiB buffer during zstd decompression (cause unknown).
local MAX_VARIANTS = 6
local ROLL_ATTEMPTS = 12                -- rolls tried per variant (theme) to find an acceptable one
local MAX_SAME_PERK = 2                 -- the same perk at most twice on one item (skills: once)
-- Families (first word of the perk name, with a few merged); a theme needs up to
-- 3 perks of one family (Crit, Max_Adder) and Enhance up to 5 skills.
local FAMILY_CAP = { Skill = 5, Damage = 3, DamageAgainst = 1, Crit = 3, Max = 3 }
local DEFAULT_FAMILY_CAP = 2
-- Composition (developer's rules, 2026-10-31). Epic shows slots 1-4: 3 theme
-- perks + 1 character skill (SKILL_SLOT); Enhance: 4 skills. Legendary adds
-- slot 5, the capstone: always a character skill at +2.
local SKILL_SLOT = 3
local THEME_STRAY = 0.1                 -- chance a theme slot takes any perk of the item type instead (themes are not exclusive)
local RESOURCE_BIAS = 0.7               -- Sustain/Empower prefer the class's resource
local CLASS_RESOURCE = { Warrior = "Health", Ranger = "Stamina", Mage = "Mana" }
local MIN_CHANGES = 2                   -- a variant differs from vanilla in >= 2 of the slots an epic shows (1-4)
local MIN_DISTINCT = 2                  -- ... and from each sibling variant in >= 2 perks (as a multiset)
-- Core skills about building, gathering and fishing never roll on equipment
-- (developer's rule: equipment is for fighting). Vanilla items keep theirs.
local EXCLUDED_PERKS = {
    "^Perk_Skill_Level_Generic_Lumberjack", "^Perk_Skill_Level_Generic_Mason",
    "^Perk_Skill_Level_Generic_Prospector", "^Perk_Skill_Level_Generic_Miner",
    "^Perk_Skill_Level_Generic_FishermansResolve",
}
-- Elemental variants focus on 1-2 elements; items named after an element
-- (e.g. Weapon_T3_1H_Wand_01_Fire) keep their first perk. "Fog" is Shroud.
local ELEMENTS = { "Fire", "Ice", "Lightning", "Poison", "Fog" }
local NONE = game.guid.NONE
local u32 = integer.u32

-- shroudforge.log.info logs at INFO, ShroudForge's default level (print() would be
-- logged at DEBUG and dropped). Lines land in <game>/shroudforge/logs.
local function log(msg) shroudforge.log.info("[forged-and-found] " .. msg) end

-- The dedicated server (enshrouded_server.exe) has no UI, so its data may lack icon
-- textures, UI bundles and text tables. It builds the same variants, registrations
-- and crafting changes as the client (the server creates loot and crafted items in
-- multiplayer) and skips only the UI parts: icon checks and the marker.
local IS_SERVER = loader.is_server == true
log("process: " .. (IS_SERVER and "dedicated server (UI checks and marker skipped)" or "client"))

-- Features (ShroudForge settings in extended.mod.json, all off by default; a change
-- rewrites extended.mod.json, so the next start re-runs this asset pass).
--   variantDrops: the native DLL swaps random Epic/Legendary loot for variants. Variants
--     are registered either way, so variants players already own keep working.
--   craftedEquipmentRarity: crafted armor/shields/weapons get rarity by item level.
--   craftedLoreItems: crafted lore copies become Legendary at their tier's armor level.
-- Crafting costs follow whichever rarity changes are on. On a dedicated server the
-- server's settings decide what is created; clients only show their own data.
local function feature(key) return shroudforge.settings.get(key, false) == true end
local VARIANT_DROPS = feature("variantDrops")
local CRAFTED_EQUIPMENT = feature("craftedEquipmentRarity")
local CRAFTED_LORE = feature("craftedLoreItems")
-- Display only: "§ " in front of variant names in this player's game (no effect on a server).
local VARIANT_MARKER = feature("variantMarker")
-- Native part only: on a game build it has no addresses for, the DLL may use the targets it
-- finds by rule (allowUntestedGameVersions); off, it only logs them.
local AUTO_DETECT = feature("allowUntestedGameVersions")
log(string.format("features: variant drops %s, crafted equipment rarity %s, crafted lore items %s, variant marker %s, untested game versions %s",
    VARIANT_DROPS and "on" or "off", CRAFTED_EQUIPMENT and "on" or "off", CRAFTED_LORE and "on" or "off",
    VARIANT_MARKER and "on" or "off", AUTO_DETECT and "allowed" or "not allowed"))

---------------------------------------------------------------------------
-- Deterministic helpers
---------------------------------------------------------------------------

local function hex8(n) return string.format("%08x", u32.truncate(n)) end

local function derive_guid(key)
    local h = hex8(hasher.fnv1a32(key .. "#0")) .. hex8(hasher.fnv1a32(key .. "#1"))
        .. hex8(hasher.fnv1a32(key .. "#2")) .. hex8(hasher.fnv1a32(key .. "#3"))
    return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16) .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
end

-- xorshift32 seeded from a string
local function rng(key)
    local state = u32.truncate(hasher.fnv1a32(key))
    if state == 0 then state = 0x9e3779b9 end
    return function(n)
        state = u32.bit_xor(state, u32.truncate(u32.shl(state, 13)))
        state = u32.bit_xor(state, u32.shr(state, 17))
        state = u32.bit_xor(state, u32.truncate(u32.shl(state, 5)))
        return (state % n) + 1
    end
end

---------------------------------------------------------------------------
-- Minimal JSON decoder for read-only copies: tostring() of a value gives JSON;
-- decoding it yields plain Lua tables that hold no loader references.
---------------------------------------------------------------------------

local function json_decode(text)
    local pos = 1
    local function ws() pos = text:find("[^ \t\r\n]", pos) or #text + 1 end
    local value
    local function str()
        local close = text:find('"', pos + 1, true)
        local raw = text:sub(pos + 1, close - 1)
        if not raw:find("\\", 1, true) then pos = close + 1; return raw end
        local out, i = {}, pos + 1
        while true do
            local c = text:sub(i, i)
            if c == '"' then pos = i + 1; return table.concat(out) end
            if c == "\\" then
                local n = text:sub(i + 1, i + 1)
                if n == "u" then
                    out[#out + 1] = utf8.char(tonumber(text:sub(i + 2, i + 5), 16)); i = i + 6
                else
                    out[#out + 1] = ({ b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[n] or n; i = i + 2
                end
            elseif c == "" then
                error("forged-and-found: unterminated JSON string")
            else
                out[#out + 1] = c; i = i + 1
            end
        end
    end
    function value()
        ws()
        local c = text:sub(pos, pos)
        if c == "{" then
            local obj = {}
            pos = pos + 1; ws()
            if text:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while true do
                ws(); local k = str(); ws()
                pos = pos + 1 -- ':'
                obj[k] = value(); ws()
                local d = text:sub(pos, pos); pos = pos + 1
                if d == "}" then return obj end
            end
        elseif c == "[" then
            local arr = {}
            pos = pos + 1; ws()
            if text:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = value(); ws()
                local d = text:sub(pos, pos); pos = pos + 1
                if d == "]" then return arr end
            end
        elseif c == '"' then
            return str()
        elseif text:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif text:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif text:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        else
            local s, e = text:find("^-?[%d%.eE%+%-]+", pos)
            if not s then error("forged-and-found: unexpected JSON at " .. pos .. ": " .. text:sub(pos, pos + 20)) end
            pos = e + 1
            local num = text:sub(s, e)
            return math.tointeger(tonumber(num)) or tonumber(num)
        end
    end
    return value()
end

local function read_copy(view)
    local text = tostring(view)
    local first = text:sub(1, 1)
    if first ~= "{" and first ~= "[" then error("forged-and-found: cannot copy value: " .. text:sub(1, 40)) end
    return json_decode(text)
end

---------------------------------------------------------------------------
-- Read game data (read-only, via tostring)
---------------------------------------------------------------------------

local function text_of(resource) return tostring(resource.data) end

local function single(type_name)
    local list = game.assets.get_resources_by_type(type_name)
    if #list ~= 1 then error("forged-and-found: expected one " .. type_name .. ", found " .. #list) end
    return list[1]
end

-- Perk metadata from debugName:
--   class:  Generic/Mage/Ranger/Warrior for skill-level perks, nil otherwise
--   family: coarse theme used to cap repetition (Leech, Skill, Damage, Crit, ...)
-- Diagnostic: serialized byte size of the big tables this mod grows, before and
-- after patching (0.2.2 crashed while the game decompressed a patched resource).
local SIZE_TYPES = { "keen::ItemRegistryResource", "keen::LootableItemsResource",
    "keen::ItemKnowledgeResource", "keen::GameKnowledgeResource" }
local function serialized_size(type_name)
    local ok, size = pcall(function()
        local b = buffer.create(1024 * 1024)
        b:write_resource(type_name, single(type_name).data)
        local n = b:tail()
        b:close()
        return n
    end)
    return ok and size or ("error: " .. tostring(size))
end
local sizes_before = {}
for _, t in ipairs(SIZE_TYPES) do sizes_before[t] = serialized_size(t) end

---------------------------------------------------------------------------
-- Perks: class, family (caps), theme (soft archetypes) and tier line.
-- A tier line groups perks that differ only in their _T<n> / _T<n>_T<m> token
-- (Perk_Max_Adder_Stamina_T1 ... _T7, Perk_Increase_Crit_Chance_T1_T2 ...), so
-- a perk taken from any tier can be swapped for the member matching the item.
---------------------------------------------------------------------------

local perk_names, perk_class, perk_family, perk_theme = {}, {}, {}, {}
local perk_by_name = {}   -- debug name -> guid (finds the +1/+2 versions of a skill perk)
local perk_line = {}      -- perk guid -> tier line (name without its tier token)
local line_members = {}   -- tier line -> list of { guid, lo, hi }

-- Theme of a perk (developer's themes, 2026-10-31): Sustain (leech/regen of
-- health, mana, stamina), Empower (max health/mana/stamina), Elemental, Physical
-- (maximum damage), Crit, Enhance (character skills). Everything else (armor,
-- resistances, utility) is "Other" and only appears as an off-theme pick.
local function theme_of(body)
    if body:find("^Skill_Level") then return "Enhance" end
    if body:find("Crit") then return "Crit" end
    if body:find("^Max_Adder") then return "Empower" end
    if body:find("^Leech") or body:find("^Recharge") or body:find("StaminaBuff") or body:find("StaminaGain")
        or body:find("Mana_Cost") then return "Sustain" end
    if body:find("^Damage_Against") then return "Physical" end -- before elements: "Fogger" contains "Fog"
    for _, e in ipairs(ELEMENTS) do
        if body:find("^Damage_" .. e) or body:find("^DamageMod_" .. e) then return "Elemental" end
    end
    if body:find("^Damage_") or body:find("^DamageMod_") or body:find("Backstab") or body:find("MercilessStrike")
        or body:find("SneakAttack") or body:find("InAirDamage") then return "Physical" end
    return "Other"
end

for _, r in ipairs(game.assets.get_resources_by_type("keen::Perk")) do
    local name = text_of(r):match('"debugName":"([^"]*)"') or r.guid
    perk_names[r.guid] = name
    perk_by_name[name] = r.guid
    perk_class[r.guid] = name:match("^Perk_Skill_Level_(%a+)_")
    local body = name:gsub("^Perk_", "")
    local family
    if body:find("^Skill_Level") then family = "Skill"
    elseif body:find("^Damage_Against") then family = "DamageAgainst"
    elseif body:find("^Increase_Crit") then family = "Crit"
    elseif body:find("^DamageMod") then family = "Damage"
    else family = body:match("^(%a+)") or body end
    perk_family[r.guid] = family
    perk_theme[r.guid] = theme_of(body)
    local lo, hi = name:match("_T(%d+)_T(%d+)")
    local line
    if lo then
        line = name:gsub("_T%d+_T%d+", "", 1)
    else
        lo = name:match("_T(%d+)")
        hi = lo
        if lo then line = name:gsub("_T%d+", "", 1) end
    end
    if line then
        perk_line[r.guid] = line
        line_members[line] = line_members[line] or {}
        table.insert(line_members[line], { guid = r.guid, lo = tonumber(lo), hi = tonumber(hi) })
    end
end

-- The member of p's tier line that fits an item of the given tier: the one
-- whose range covers it, else the highest below it. nil if every member is
-- above the tier (lines that only exist at high tiers, e.g. *_Vs_Soaked_T6,
-- would otherwise land on low-tier items).
local function at_tier(p, tier)
    local line = perk_line[p]
    if not line or not tier then return p end
    local best, best_lo
    for _, m in ipairs(line_members[line]) do
        if m.lo <= tier and tier <= m.hi then return m.guid end
        if m.lo <= tier and (not best_lo or m.lo > best_lo) then best, best_lo = m.guid, m.lo end
    end
    return best
end

local registered = {}
do
    local refs = text_of(single("keen::ItemRegistryResource")):match('"itemRefs":%[(.-)%]') or ""
    for g in refs:gmatch('"([%x%-]+)"') do registered[g] = true end
end

-- Wide pool groups, so variants are more than reshuffles of one item type's
-- perks: one-/two-handed melee, bows, staffs, wands, daggers, shields, rings,
-- ammo, and armor by class across all slots.
local function wide_group(debug_name, class)
    local n = debug_name:gsub("^Craft_", "")
    if n:find("^Ring_") then return "Ring" end
    if n:find("^Shield_") then return "Shield" end
    if n:find("^Ammo_") then return "Ammo" end
    if n:find("^Armor_") then
        local c = n:match("_(Mage)_") or n:match("_(Ranger)_") or n:match("_(Warrior)_")
        if not c and class and class ~= "None" then c = class end
        return "Armor_" .. (c or "Other")
    end
    if n:find("^Weapon_") then
        if n:find("Dagger") then return "Daggers" end
        if n:find("Bow") then return "Bow" end
        if n:find("Staff") then return "Staff" end
        if n:find("Wand") then return "Wand" end
        if n:find("_1H_") then return "Melee_1H" end
        if n:find("_2H_") then return "Melee_2H" end
    end
    return n:match("^(%a+)_") or "Other"
end

local items, item_order = {}, {}  -- guid -> { name, perks, group, class, id, tier, gen, legendary, eligible }
local used_ids = {}                -- ItemId -> true, to detect collisions
local pools = {}                   -- key -> { list, seen }; one entry per tier line

local function excluded(perk)
    local name = perk_names[perk] or ""
    for _, pattern in ipairs(EXCLUDED_PERKS) do
        if name:find(pattern) then return true end
    end
    return false
end

local function pool_add(key, perk)
    if excluded(perk) then return end
    local p = pools[key]
    if not p then p = { list = {}, seen = {} }; pools[key] = p end
    local k = perk_line[perk] or perk
    if not p.seen[k] then p.seen[k] = true; p.list[#p.list + 1] = perk end
end

local eligible_count = 0
local skill_bases = {}             -- class -> { skill base name -> a vanilla perk guid }
for _, r in ipairs(game.assets.get_resources_by_type("keen::ItemInfo")) do
    local text = text_of(r)
    local id = tonumber(text:match('^{"itemId":{"value":(%d+)}'))
    if id then used_ids[id] = true end
    local list = text:match('"perkReferences":%[(.-)%]')
    local perks, has = {}, false
    for g in (list or ""):gmatch('"([%x%-]+)"') do
        perks[#perks + 1] = g
        if g ~= NONE then has = true end
    end
    if has and registered[r.guid] then
        local name = text:match('"debugName":"([^"]*)"}$') or r.guid
        local class = text:match('"itemClassAlignment":"(%a+)"')
        -- Rarity: fixed (generateRarity false) or rolled at drop minus disabled ones.
        local gen = text:match('"generateRarity":(%a+)') == "true"
        local rarity = text:match('"rarity":"(%a+)"')
        local disabled = text:match('"disableRarityGeneration":%[(.-)%]') or ""
        local epic, legendary
        if gen then
            epic = not disabled:find("Epic")
            legendary = not disabled:find("Legendary")
        else
            epic = rarity == "Epic"
            legendary = rarity == "Legendary"
        end
        -- Special sets keep their identity and stay out of the pools: dungeon/enemy
        -- "_TX_" items (Hollow Halls: Blunt + vs Skeleton on every weapon type, even
        -- bows; Fog Nest: Shroud) and NPC-only gear. Normal "T1-TX" enemy drops stay.
        local special = name:find("_TX_") or name:find("NPC_ONLY")
        -- Lore items stay as designed (developer: "there is a reason they are as
        -- they are"), and craftable copies ("Craft_") never get variants: crafting
        -- always yields the vanilla item, so their variants could never appear.
        -- Both still feed the pools (they are normal perks of their item type).
        local fixed_design = name:find("_Lore_") or name:find("^Craft_")
        local info = {
            name = name, perks = perks, group = wide_group(name, class), class = class, id = id,
            tier = tonumber(name:match("_T(%d+)")), gen = gen, disabled = disabled,
            legendary = legendary, eligible = (epic or legendary) and not special and not fixed_design,
        }
        -- No identity anchor (0.4.2-0.5.2 kept slot 1 on rings and element-named
        -- items): an item's base stats already carry its identity, so a Ring of
        -- Health whose upgrades go for crit fits a damage-focused warrior (developer).
        items[r.guid] = info
        item_order[#item_order + 1] = r.guid
        if info.eligible then eligible_count = eligible_count + 1 end
        for _, p in ipairs(special and {} or perks) do
            if p ~= NONE and perk_class[p] and not excluded(p) then
                -- Character skills seen on any vanilla item, per class (Generic = all).
                local base = (perk_names[p] or ""):gsub("_%d+$", "")
                skill_bases[perk_class[p]] = skill_bases[perk_class[p]] or {}
                skill_bases[perk_class[p]][base] = p
            end
            -- Pool of the item's wide group (theme perks are taken from here).
            if p ~= NONE then pool_add(info.group, p) end
        end
    end
end
table.sort(item_order)
log(string.format("%d registered items have perks, %d can drop as Epic or Legendary (only these get variants)",
    #item_order, eligible_count))

---------------------------------------------------------------------------
-- Character skills per class: the +1 (normal slots) and +2 (capstone) perk of
-- every skill seen on a vanilla item. Generic (core) combat skills fit all.
---------------------------------------------------------------------------

local CLASSES = { "Mage", "Ranger", "Warrior" }
local skills = {}   -- class -> list of { base, one, two }, sorted (pairs() order is not deterministic)
for _, c in ipairs(CLASSES) do
    local list, seen = {}, {}
    for _, source in ipairs({ c, "Generic" }) do
        for base, p in pairs(skill_bases[source] or {}) do
            if not seen[base] then
                seen[base] = true
                list[#list + 1] = { base = base, one = perk_by_name[base .. "_1"] or p, two = perk_by_name[base .. "_2"] }
            end
        end
    end
    table.sort(list, function(a, b) return a.base < b.base end)
    skills[c] = list
    local twos = 0
    for _, s in ipairs(list) do if s.two then twos = twos + 1 end end
    log(string.format("%s skills (incl. Generic): %d, %d with a +2 perk for capstones", c, #list, twos))
end

-- Melee / ranged / caster: which class's skills (and resource) an item gets.
local GROUP_CLASS = {
    Melee_1H = "Warrior", Melee_2H = "Warrior", Shield = "Warrior", Bow = "Ranger", Daggers = "Ranger",
    Staff = "Mage", Wand = "Mage", Armor_Warrior = "Warrior", Armor_Ranger = "Ranger", Armor_Mage = "Mage",
}
local function known_class(info)
    local c = GROUP_CLASS[info.group]
    if not c and info.group == "Ammo" then
        if info.name:find("Arrow") then c = "Ranger" elseif info.name:find("Spell") then c = "Mage" end
    end
    if not c and (info.class == "Warrior" or info.class == "Ranger" or info.class == "Mage") then c = info.class end
    return c
end

---------------------------------------------------------------------------
-- Weapon skills (developer's rules, 2026-11-09, since 0.16.0). Skills listed in
-- WEAPON_SKILLS work only with some weapons; the others work with any (resistances,
-- elemental damage, attributes, auras, movement, backstab, ...).
--   - Weapons: a weapon's perks apply only while it is selected in the hotbar, so
--     a skill on a weapon must work with that weapon in hand.
--   - Armor follows archetypes: light (Mage armor) for wands and staves; medium
--     (Ranger armor) for bows, daggers and two-handed weapons (warriors wear it
--     too); heavy (Warrior armor) for one- and two-handed melee. A skill fits if it
--     works with any weapon of the archetype; Thrust and Sleight of Hand also fit
--     medium and heavy (vanilla puts both on heavy armor: warriors may take daggers
--     or fight unarmed). Unique Greatsword arms: greatsword skills.
--   - Everything else (rings, shields, wards, multi-class and other unique armor)
--     keeps any skill.
-- Sources: the skill texts (research/skills.md), weapon damage types from vanilla
-- damage perks (axes and swords Cut, maces and hammers Blunt, daggers and bows
-- Pierce), and the developer: spells are cast from staves; daggers can parry; a
-- wand's perks stay active while the ward in the other hand parries; any weapon
-- can backstab; ranged weapons have no Merciless Attacks. Table:
-- research/weapon-skills.md.
---------------------------------------------------------------------------

-- Weapon kinds per group, in the order names are searched.
local WEAPON_KINDS = {
    Melee_1H = { "Axe", "Mace", "Sword" }, Melee_2H = { "GreatAxe", "GreatSword", "Hammer" },
    Bow = { "Bow" }, Daggers = { "Daggers" }, Staff = { "Staff" }, Wand = { "Wand" },
}
local function kinds(list, ...)
    local s = {}
    for _, k in ipairs(list or {}) do s[k] = true end
    for _, k in ipairs({ ... }) do s[k] = true end
    return s
end
local MELEE = kinds({ "Axe", "Mace", "Sword", "GreatAxe", "GreatSword", "Hammer", "Daggers" })
local PARRY = kinds({ "Axe", "Mace", "Sword", "GreatAxe", "GreatSword", "Hammer", "Daggers" }, "Wand")
local WAND, STAFF, MAGIC = kinds(nil, "Wand"), kinds(nil, "Staff"), kinds(nil, "Wand", "Staff")
local BOW, DAGGERS, BOW_DAGGERS = kinds(nil, "Bow"), kinds(nil, "Daggers"), kinds(nil, "Bow", "Daggers")
-- Key: the skill part of the perk name (Perk_Skill_Level_<Class>_<Key>_<level>).
local WEAPON_SKILLS = {
    WandMastery = WAND, Unity = WAND, EternalSpark = WAND,
    MageApprenticeship = MAGIC, Wizard = MAGIC, Necromancer = MAGIC, ShroudFilter = MAGIC,
    Spellslinger = STAFF,
    -- spells (cast from staves)
    BloodLetting = STAFF, Terror = STAFF, QuickCharge = STAFF, RighteousFire = STAFF, Healer = STAFF,
    SleightOfHand = kinds(nil),   -- unarmed damage: never with a weapon in hand
    Marksman = BOW, Sniper = BOW, Skillshot = BOW, BlessedArrows = BOW, SwiftshotSustenance = BOW,
    Puncture = BOW,                -- ranged piercing
    DaggerMastery = DAGGERS, Thrust = DAGGERS, -- melee piercing
    SurvivalInstinct = BOW_DAGGERS, VitalitySurge = BOW_DAGGERS,
    WarriorsPath = kinds(nil, "Axe", "Mace", "Sword"),
    Finesse = kinds(nil, "Axe", "Mace", "Sword", "Daggers"),
    BarbariansPath = kinds(nil, "GreatAxe", "Hammer"),
    TitanEdge = kinds(nil, "GreatSword"),
    Purification = kinds(nil, "Axe", "Mace", "Sword", "GreatAxe", "GreatSword", "Hammer"),
    Slasher = kinds(nil, "Axe", "Sword", "GreatAxe", "GreatSword"), -- melee cutting
    Brute = kinds(nil, "Mace", "Hammer"),                            -- melee blunt
    Veteran = MELEE, BattleHeal = MELEE, BloodRage = MELEE, SoulLeech = MELEE, Steadfast = MELEE,
    HeavyHanded = MELEE, Opportunity = MELEE,
    Bash = PARRY, VigorousDeflection = PARRY, ArcaneDeflection = PARRY, PowerParry = PARRY,
}

local function skill_key(p) return (perk_names[p] or ""):match("^Perk_Skill_Level_%a+_(%a+)") end

-- The weapon kind of an item (nil if it is no weapon or its name names no kind)
-- and its group's kinds.
local function weapon_kind(info)
    local list = WEAPON_KINDS[info.group]
    if not list then return nil, nil end
    if #list == 1 then return list[1], list end
    -- Case-insensitive: Weapon_T5_2H_Greatsword_01/_02 spell it with a small s.
    local name = info.name:lower()
    for _, k in ipairs(list) do
        if name:find("_" .. k:lower(), 1, true) then return k, list end
    end
    return nil, list
end

-- Armor archetypes: the weapons each one is for, and skills it takes besides.
local ARMOR_KINDS = {
    Armor_Mage = { "Wand", "Staff" },
    Armor_Ranger = { "Bow", "Daggers", "GreatAxe", "GreatSword", "Hammer" },
    Armor_Warrior = { "Axe", "Mace", "Sword", "GreatAxe", "GreatSword", "Hammer" },
}
local ARMOR_EXTRA = {
    Armor_Ranger = kinds(nil, "Thrust", "SleightOfHand"),
    Armor_Warrior = kinds(nil, "Thrust", "SleightOfHand"),
}

-- Whether the item's skills are restricted (weapons, class armor, the Greatsword
-- arms); everything else takes any skill.
local function skill_rule(info)
    if WEAPON_KINDS[info.group] or ARMOR_KINDS[info.group] then return true end
    return info.name:find("_Unique_Greatsword_", 1, true) ~= nil
end

-- Whether perk p may sit on the item: always for non-skills, skills that work
-- with any weapon and unrestricted items. A weapon whose kind is not in its name
-- takes only skills that fit every kind of its group.
local function fits_item(info, p)
    if not perk_class[p] then return true end
    local key = skill_key(p) or ""
    local allowed = WEAPON_SKILLS[key]
    if not allowed then return true end
    local armor = ARMOR_KINDS[info.group]
    if armor then
        if ARMOR_EXTRA[info.group] and ARMOR_EXTRA[info.group][key] then return true end
        for _, k in ipairs(armor) do
            if allowed[k] then return true end
        end
        return false
    end
    if info.name:find("_Unique_Greatsword_", 1, true) then return allowed.GreatSword == true end
    local kind, list = weapon_kind(info)
    if not list then return true end
    if kind then return allowed[kind] == true end
    for _, k in ipairs(list) do
        if not allowed[k] then return false end
    end
    return true
end

do
    -- A key that names no skill would let that skill through unchecked.
    local known = {}
    for _, c in ipairs(CLASSES) do
        for _, s in ipairs(skills[c]) do known[skill_key(s.one) or ""] = true end
    end
    local unknown = {}
    for k in pairs(WEAPON_SKILLS) do
        if not known[k] then unknown[#unknown + 1] = k end
    end
    table.sort(unknown)
    if #unknown > 0 then
        log("WARNING: weapon skill rules name skills no vanilla item carries (typo?): " .. table.concat(unknown, ", "))
    end
end

---------------------------------------------------------------------------
-- Roll perks
--
-- Each variant has one theme (developer's themes): Sustain, Empower,
-- Elemental (1-2 elements), Physical, Crit, Enhance. The 6 variants of an item
-- spread over the themes its pool supports (deterministic shuffle). Slots:
--   - slot 5 of Legendary-capable items is the capstone: a character skill at +2
--     (+1 if the skill has no +2 perk);
--   - Enhance: every other slot is a character skill (+1);
--   - other themes: SKILL_SLOT is a character skill, the rest theme perks, each
--     with THEME_STRAY chance of any non-skill perk of the item type;
--   - Sustain/Empower prefer the class's resource (RESOURCE_BIAS).
-- Theme perks come from the item's wide group pool, swapped for the member of
-- their tier line that fits the item's tier. Skills only from the item's class
-- (melee weapons/shields Warrior, bows/daggers Ranger, staffs/wands Mage,
-- armor by class) or Generic; a skill appears once per item; on weapons only
-- skills that work with that weapon in hand ("Weapon skills"). Every second
-- variant is a hybrid whose skill slot and capstone come from another class.
---------------------------------------------------------------------------

local THEMES = { "Sustain", "Empower", "Elemental", "Physical", "Crit", "Enhance" }

local function element_of(p)
    if perk_theme[p] ~= "Elemental" then return nil end
    local name = perk_names[p] or ""
    for _, e in ipairs(ELEMENTS) do if name:find(e) then return e end end
    return nil
end

-- Perks of one theme in the item's group pool, at the given tier.
local function theme_lines(info, theme, tier)
    local out = {}
    for _, p in ipairs(pools[info.group].list) do
        if perk_theme[p] == theme then
            local q = at_tier(p, tier)
            if q then out[#out + 1] = q end
        end
    end
    return out
end

-- Themes an item can carry (>= 2 perk lines in its pool; Enhance: >= 4 skills),
-- shuffled deterministically so its variants spread over different themes.
local function themes_for(guid, info)
    local list = {}
    for _, t in ipairs(THEMES) do
        local ok
        if t == "Enhance" then
            local c = known_class(info)
            ok = not c or #skills[c] >= 4
        else
            ok = #theme_lines(info, t, info.tier) >= 2
        end
        if ok then list[#list + 1] = t end
    end
    local next_int = rng(ROLL_SEED .. "|" .. guid .. "|themes")
    for i = #list, 2, -1 do
        local j = next_int(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local function skill_base(p) return ((perk_names[p] or ""):gsub("_%d+$", "")) end

local function roll_perks(guid, info, theme, attempt, hybrid)
    local next_int = rng(ROLL_SEED .. "|" .. guid .. "|" .. theme .. "|" .. attempt)
    local class = known_class(info) or CLASSES[next_int(#CLASSES)]
    local resource = CLASS_RESOURCE[class]
    -- Hybrid variants (paladin, spellblade, battle mage, ...) take their character
    -- skills from a second class: the skill slot and the capstone; Enhance mixes
    -- both classes (even slots from the second one).
    local secondary
    if hybrid then
        local others = {}
        for _, c in ipairs(CLASSES) do if c ~= class then others[#others + 1] = c end end
        secondary = others[next_int(#others)]
    end

    local elements
    if theme == "Elemental" then
        local offered, seen = {}, {}
        for _, q in ipairs(theme_lines(info, theme, info.tier)) do
            local e = element_of(q)
            if e and not seen[e] then seen[e] = true; offered[#offered + 1] = e end
        end
        table.sort(offered)
        elements = {}
        if #offered > 0 then
            local first = next_int(#offered)
            elements[offered[first]] = true
            if #offered > 1 and next_int(2) == 2 then
                local second = next_int(#offered - 1)
                if second >= first then second = second + 1 end
                elements[offered[second]] = true
            end
        end
    end

    local same, family, bases = {}, {}, {}
    local function allowed(p)
        local c = perk_class[p]
        if c then
            if c ~= "Generic" and c ~= class and c ~= secondary then return false end
            if bases[skill_base(p)] then return false end
            if not fits_item(info, p) then return false end
        end
        if elements then
            local e = element_of(p)
            if e and not elements[e] then return false end
        end
        if (same[p] or 0) >= MAX_SAME_PERK then return false end
        local f = perk_family[p]
        if (family[f] or 0) >= (FAMILY_CAP[f] or DEFAULT_FAMILY_CAP) then return false end
        return true
    end
    local function pick(list, prefer_resource)
        local ok = {}
        for _, q in ipairs(list) do if allowed(q) then ok[#ok + 1] = q end end
        if #ok == 0 then return nil end
        if prefer_resource and resource and next_int(1000) <= RESOURCE_BIAS * 1000 then
            local res = {}
            for _, q in ipairs(ok) do if (perk_names[q] or ""):find(resource) then res[#res + 1] = q end end
            if #res > 0 then ok = res end
        end
        return ok[next_int(#ok)]
    end
    local function skill_list(two, of_class)
        local out = {}
        for _, s in ipairs(skills[of_class or class] or {}) do
            -- Not `two and s.two or s.one`: that falls back to the +1 perk of skills
            -- without a +2 version (0.5.1 bug: only 37% of capstones were +2).
            local q
            if two then q = s.two else q = s.one end
            if q then out[#out + 1] = q end
        end
        return out
    end
    local function any_list()   -- off-theme: any non-skill perk of the item type
        local out = {}
        for _, p in ipairs(pools[info.group].list) do
            if not perk_class[p] then
                local q = at_tier(p, info.tier)
                if q then out[#out + 1] = q end
            end
        end
        return out
    end

    local result = {}
    for slot, vanilla in ipairs(info.perks) do
        local q
        if vanilla == NONE then
            q = NONE
        else
            -- Skill class of this slot: the second class for hybrids' skill slot and
            -- capstone, and for every even slot of a hybrid Enhance variant.
            local skill_class = class
            if secondary and (slot == 5 or slot == SKILL_SLOT or (theme == "Enhance" and slot % 2 == 0)) then
                skill_class = secondary
            end
            if slot == 5 and info.legendary then
                q = pick(skill_list(true, skill_class)) or pick(skill_list(false, skill_class))
            elseif theme == "Enhance" or slot == SKILL_SLOT then
                q = pick(skill_list(false, skill_class))
            elseif next_int(1000) <= THEME_STRAY * 1000 then
                q = pick(any_list())
            end
            if not q and theme ~= "Enhance" then
                q = pick(theme_lines(info, theme, info.tier), theme == "Sustain" or theme == "Empower")
            end
            q = q or pick(any_list()) or vanilla
        end
        result[slot] = q
        if q ~= NONE then
            same[q] = (same[q] or 0) + 1
            local f = perk_family[q]
            family[f] = (family[f] or 0) + 1
            if perk_class[q] then bases[skill_base(q)] = true end
        end
    end
    return result, secondary
end
-- Acceptance: a variant must be visibly different from vanilla (>= MIN_CHANGES
-- of the slots an epic shows) and not a reshuffle of vanilla or a sibling
-- (>= MIN_DISTINCT perks not matched in the other's multiset).
local function new_perks(a, b)
    local count = {}
    for _, p in ipairs(b) do if p ~= NONE then count[p] = (count[p] or 0) + 1 end end
    local n = 0
    for _, p in ipairs(a) do
        if p ~= NONE then
            if (count[p] or 0) > 0 then count[p] = count[p] - 1 else n = n + 1 end
        end
    end
    return n
end

local function acceptable(perks, info, siblings)
    local slots, visible_changes = 0, 0
    for i, p in ipairs(info.perks) do
        if p ~= NONE then
            slots = slots + 1
            if i <= 4 and perks[i] ~= p then visible_changes = visible_changes + 1 end
        end
    end
    local need = math.min(MIN_CHANGES, slots)
    if visible_changes < need then return false end
    if new_perks(perks, info.perks) < math.min(MIN_DISTINCT, slots) then return false end
    for _, v in ipairs(siblings) do
        if new_perks(perks, v.perks) < math.min(MIN_DISTINCT, slots) then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Create variants (clone first, then edit only the clone's live view)
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Pinned rolls (data/pinned.txt, shipped with the mod; lines are never removed,
-- and their perks change only by a deliberate rule change, e.g. 0.16.0 weapon skills)
--
-- Saves store a variant's ItemId, and its perks come from this list, so a
-- game update that adds, removes or renames perks cannot silently change the
-- perks of items players already own. One line per variant:
--   <original GUID> <index> <variant GUID> <perk GUID per slot ...>  # names
-- A pinned perk that no longer exists falls back to the original's current
-- perk for that slot. Items without pinned entries (new in a game update) are
-- rolled as before; the exported pinned.txt then lists them for the next
-- release. Pinned variants whose original item is gone cannot be rebuilt.
---------------------------------------------------------------------------

local PINNED_FILE = "data/pinned.txt"
local pinned = {}         -- original guid -> list of { index, guid, perks } in index order
local pinned_count = 0
if io.exists(PINNED_FILE) then
    for line in io.read_to_string(PINNED_FILE):gmatch("[^\r\n]+") do
        local body = line:gsub("%s*#.*$", "")
        if body ~= "" then
            local fields = {}
            for f in body:gmatch("%S+") do fields[#fields + 1] = f end
            local original, index, guid = fields[1], tonumber(fields[2]), fields[3]
            if not (original and index and guid and #fields >= 4) then
                error("forged-and-found: malformed line in " .. PINNED_FILE .. ": " .. line)
            end
            local list = pinned[original] or {}
            pinned[original] = list
            if index ~= #list + 1 then
                error(string.format("forged-and-found: %s: variant %d of %s out of order", PINNED_FILE, index, original))
            end
            local perks = {}
            for k = 4, #fields do perks[#perks + 1] = fields[k] end
            list[index] = { index = index, guid = guid, perks = perks }
            pinned_count = pinned_count + 1
        end
    end
    log(string.format("pinned rolls: %d variants read from %s", pinned_count, PINNED_FILE))
else
    log("pinned rolls: no " .. PINNED_FILE .. ", rolling every variant")
end

---------------------------------------------------------------------------
-- Create variants (clone first, then edit only the clone's live view)
---------------------------------------------------------------------------

local variants = {}       -- all variants: { original, original_id, index, guid, id, name, perks, pinned }
local variants_of = {}    -- original guid -> list of its variants
local count_hist = {}     -- variants per item -> number of items
local stats = { pinned = 0, rolled = 0, fallback_slots = 0 }

local function create_variant(original, info, source, index, perks)
    local guid = derive_guid(SEED .. "|" .. original .. "|" .. index)
    local id = game.guid.hash(guid)
    if used_ids[id] then error("forged-and-found: ItemId collision for " .. info.name .. " #" .. index) end
    used_ids[id] = true

    local item = game.assets.create_resource(source.data, "keen::ItemInfo", guid, 0)
    local data = item.data
    local name = info.name .. "__PV" .. index
    data.itemId.value = id
    -- objectId stays the original's GUID: the icon renderer loads the texture
    -- named by objectId. Setting it to the variant's GUID made chests assert
    -- "corrupted game ui texture" (0.2.6); cloning textures instead caps the
    -- total at ~2 variants per item (UI texture slots, 0.2.3/0.2.7).
    data.debugName = name
    for slot, p in ipairs(perks) do
        if p ~= NONE and p ~= info.perks[slot] then
            data.perkReferences[slot] = p
            data.perkIds[slot].value = game.guid.hash(p)
        end
    end
    if info.gen then
        -- Variants exist only as Epic/Legendary: their generated rarity can never be
        -- Common/Uncommon/Rare (the original keeps those, see the loot pool).
        local mask = { "Common", "Uncommon", "Rare" }
        if info.disabled:find("Epic") then mask[#mask + 1] = "Epic" end
        if info.disabled:find("Legendary") then mask[#mask + 1] = "Legendary" end
        data.disableRarityGeneration = mask
    end
    return { original = original, original_id = info.id, index = index, guid = guid, id = id, name = name, perks = perks }
end

-- Skills on pinned variants (0.16.0): a skill that breaks the weapon/armor rules
-- (see "Weapon skills") is replaced by one that fits, at the same level (+2 stays
-- +2 where the new skill has a +2 perk), from the class of the skill it replaces
-- when one fits (keeps hybrids hybrid), else from the item's class, else any class;
-- Generic skills count for all. Every other slot, the GUID and the ItemId stay, so
-- items players own keep existing and take the new perks (perks live in the
-- variant's ItemInfo, not in saves). Deterministic, so client and server build the
-- same perks. Once the exported pinned.txt is shipped, this finds nothing to replace.
local SKILL_FIX_SEED = "perk-variants/skill-fit-v1"
local function fix_skills(original, info, index, perks)
    if not skill_rule(info) then return 0, 0 end
    local bases = {}
    for _, p in ipairs(perks) do
        if p ~= NONE and perk_class[p] then bases[skill_base(p)] = true end
    end
    local fixed, unfixed = 0, 0
    for slot, p in ipairs(perks) do
        if p ~= NONE and perk_class[p] and not fits_item(info, p) then
            local next_int = rng(SKILL_FIX_SEED .. "|" .. original .. "|" .. index .. "|" .. slot)
            local classes, listed = {}, {}
            local function add(c)
                if c and skills[c] and not listed[c] then listed[c] = true; classes[#classes + 1] = c end
            end
            add(perk_class[p])     -- Generic has no list of its own: skipped
            add(known_class(info))
            for _, c in ipairs(CLASSES) do add(c) end
            local levels = (perk_names[p] or ""):find("_2$") and { true, false } or { false }
            local q
            for _, c in ipairs(classes) do
                for _, two in ipairs(levels) do
                    local ok = {}
                    for _, s in ipairs(skills[c]) do
                        local cand
                        if two then cand = s.two else cand = s.one end
                        if cand and not bases[s.base] and fits_item(info, cand) then ok[#ok + 1] = cand end
                    end
                    if #ok > 0 then q = ok[next_int(#ok)]; break end
                end
                if q then break end
            end
            if q then
                perks[slot] = q
                bases[skill_base(q)] = true
                fixed = fixed + 1
            else
                unfixed = unfixed + 1
                log(string.format("WARNING: no fitting skill to replace %s on %s__PV%d slot %d", perk_names[p] or p, info.name, index, slot))
            end
        end
    end
    return fixed, unfixed
end
stats.skill_fixed, stats.skill_fixed_variants, stats.skill_unfixed = 0, 0, 0

for _, original in ipairs(item_order) do
    local info = items[original]
    local seen = { [table.concat(info.perks, ",")] = true } -- never duplicate vanilla
    local list = {}
    local source = game.assets.get_resource(original, "keen::ItemInfo")
    if not IS_SERVER and not game.assets.get_resource(original, "keen::UiTextureResource", 0) then
        error("forged-and-found: no icon texture for " .. info.name)
    end

    for _, e in ipairs(pinned[original] or {}) do
        local guid = derive_guid(SEED .. "|" .. original .. "|" .. e.index)
        if guid ~= e.guid then
            error(string.format("forged-and-found: %s variant %d: GUID %s, pinned %s (derivation changed; saves would lose these items)",
                info.name, e.index, guid, e.guid))
        end
        local perks = {}
        for slot, vanilla in ipairs(info.perks) do
            local p = e.perks[slot]
            -- Keep the item's current slot layout; a pinned perk that no longer
            -- exists falls back to the original's perk for that slot.
            if vanilla == NONE or p == nil or p == NONE then
                perks[slot] = vanilla
            elseif perk_names[p] then
                perks[slot] = p
            else
                perks[slot] = vanilla
                stats.fallback_slots = stats.fallback_slots + 1
                log(string.format("pinned perk %s of %s slot %d no longer exists, using vanilla", p, info.name, slot))
            end
        end
        local fixed, unfixed = fix_skills(original, info, e.index, perks)
        stats.skill_fixed = stats.skill_fixed + fixed
        stats.skill_unfixed = stats.skill_unfixed + unfixed
        if fixed > 0 then stats.skill_fixed_variants = stats.skill_fixed_variants + 1 end
        seen[table.concat(perks, ",")] = true
        local v = create_variant(original, info, source, e.index, perks)
        v.pinned = true
        list[e.index] = v
        variants[#variants + 1] = v
        stats.pinned = stats.pinned + 1
    end

    -- New rolls only for items that can drop as Epic/Legendary (pinned variants of
    -- other items are still rebuilt above, so saves keep them).
    -- Variant k takes the k-th of the item's themes (shuffled per item), so the 6
    -- variants spread over different themes; a theme that yields no acceptable
    -- roll is skipped for the next one.
    local themes = info.eligible and themes_for(original, info) or {}
    for k = 1, #themes > 0 and MAX_VARIANTS * 2 or 0 do
        if #list >= MAX_VARIANTS then break end
        local theme = themes[(k - 1) % #themes + 1]
        -- Every second variant (3 of 6) is a hybrid: its skills come from a second
        -- class, to encourage mixing builds (developer's call).
        local hybrid = (#list + 1) % 2 == 0
        for attempt = 1, ROLL_ATTEMPTS do
            local perks, secondary = roll_perks(original, info, theme, k * 100 + attempt, hybrid)
            local signature = table.concat(perks, ",")
            if not seen[signature] and acceptable(perks, info, list) then
                seen[signature] = true
                local index = #list + 1
                local v = create_variant(original, info, source, index, perks)
                v.theme = secondary and (theme .. "+" .. secondary) or theme
                list[index] = v
                variants[#variants + 1] = v
                stats.rolled = stats.rolled + 1
                break
            end
        end
    end
    variants_of[original] = list
    count_hist[#list] = (count_hist[#list] or 0) + 1
end
do
    local parts = {}
    for n = 0, MAX_VARIANTS do
        if count_hist[n] then parts[#parts + 1] = n .. " variants: " .. count_hist[n] .. " items" end
    end
    log(string.format("created %d variants (%s)", #variants, table.concat(parts, ", ")))
    log(string.format("pinned rolls: %d variants from the pinned list (%d slots fell back to vanilla), %d newly rolled (not pinned yet)",
        stats.pinned, stats.fallback_slots, stats.rolled))
    -- Every variant, pinned or rolled, checked against the weapon and armor rules.
    local broken = 0
    for _, v in ipairs(variants) do
        for _, p in ipairs(v.perks) do
            if p ~= NONE and not fits_item(items[v.original], p) then broken = broken + 1 end
        end
    end
    log(string.format("skill fit: %d pinned skills replaced on %d variants (%d without a fitting replacement); skills breaking the weapon/armor rules now: %d",
        stats.skill_fixed, stats.skill_fixed_variants, stats.skill_unfixed, broken))
    local lost = {}
    for original, list in pairs(pinned) do
        if not items[original] then lost[#lost + 1] = original .. " (" .. #list .. " variants)" end
    end
    table.sort(lost)
    if #lost > 0 then
        log(string.format("WARNING: %d pinned items no longer exist or have no perks; their variants cannot be rebuilt and are lost from saves: %s",
            #lost, table.concat(lost, ", ")))
    end
end

---------------------------------------------------------------------------
-- Crafted lore items at Legendary (developer, 2026-10-31)
--
-- Once a lore item is found, its artisan crafts copies ("Craft_..._Lore_...",
-- one per tier, all with 5 perks) at a fixed Rare rarity, which shows 3 perks.
-- The mod makes them Legendary (all 5 perks). This is the mod's only edit of
-- vanilla items: the item keeps its ItemId, and the game recomputes how many
-- perk rows an item shows from its type's rarity on every load (rebalance pass
-- at enshrouded.exe+0x404A0C), so removing the mod should turn them back to Rare
-- (inferred, to be tested).
---------------------------------------------------------------------------

-- Lore copies: "Craft_..._Lore_..." and, since 0.16.0, the Lunar Year event
-- weapons the event trader sells ("Craft_..._chineseNewYear_..."). Those are lore
-- copies in all but name (fixed Rare, 5 perks, the lore copies' item levels and
-- the same item tags); 0.15.x left them to the level rule below, which made them
-- Epic at most (a player's report, 2026-11-09).
local function is_lore_copy(name)
    return name:find("^Craft_") ~= nil and (name:find("_Lore_") ~= nil or name:find("_chineseNewYear_") ~= nil)
end

local RARITY_RANK = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5 }
local rarity_steps = {}   -- crafted item guid -> rarity steps changed by the mod (+ up, - down)
local CRAFTED_LORE_RARITY = "Legendary"
if not CRAFTED_LORE then
    log("crafted lore items: off (vanilla rarity)")
else
    local changed, event = 0, 0
    for _, original in ipairs(item_order) do
        if is_lore_copy(items[original].name) then
            if not items[original].name:find("_Lore_") then event = event + 1 end
            local resource = game.assets.get_resource(original, "keen::ItemInfo")
            local text = text_of(resource)
            if text:match('"rarity":"(%a+)"') ~= CRAFTED_LORE_RARITY or text:match('"generateRarity":(%a+)') ~= "false" then
                local vanilla = text:match('"rarity":"(%a+)"')
                if RARITY_RANK[vanilla] then
                    rarity_steps[original] = RARITY_RANK[CRAFTED_LORE_RARITY] - RARITY_RANK[vanilla]
                end
                local data = resource.data
                data.generateRarity = false -- a few copies roll their rarity (data quirk)
                data.rarity = CRAFTED_LORE_RARITY
                changed = changed + 1
            end
        end
    end
    log(string.format("crafted lore items: %d set to %s (%d of the lore copies are Lunar Year event weapons)",
        changed, CRAFTED_LORE_RARITY, event))
end

---------------------------------------------------------------------------
-- Crafted equipment rarity by base level (developer's rule, 2026-11-01)
--
-- Non-lore armor, shields and weapons the artisans craft (recipe outputs:
-- Armor_*, Shield_*, Weapon_*, and Craft_* that are no lore copy; the Lunar Year
-- event weapons count as lore copies since 0.16.0) get their rarity from their base item level: up to 5
-- Common, up to 10 Uncommon, up to 15 Rare, above that Epic. Already Legendary
-- crafted items (Vorgoth set) stay Legendary. Crafted items are separate types
-- from loot items (*_Loot) and never get variants, so loot is unaffected.
-- This lowers T1 (level 5, vanilla Uncommon) and T2 (level 10, vanilla Rare)
-- by one step, as the developer specified.
---------------------------------------------------------------------------

local CRAFTED_RARITY_BY_LEVEL = { { 5, "Common" }, { 10, "Uncommon" }, { 15, "Rare" }, { math.huge, "Epic" } }
local crafted = {}   -- GUIDs of every recipe output
for list in text_of(single("keen::RecipeRegistryResource")):gmatch('"output":%[(.-)%]') do
    for g in list:gmatch('"itemRef":"([%x%-]+)"') do crafted[g] = true end
end
if not CRAFTED_EQUIPMENT then
    log("crafted equipment rarity by level: off (vanilla rarity)")
else
    local changed, moves = 0, {}
    for _, original in ipairs(item_order) do
        local info = items[original]
        local n = info.name
        local equipment = n:find("^Armor_") or n:find("^Shield_") or n:find("^Weapon_")
            or (n:find("^Craft_") and not is_lore_copy(n))
        if crafted[original] and equipment and not info.gen then
            local resource = game.assets.get_resource(original, "keen::ItemInfo")
            local text = text_of(resource)
            local level = tonumber(text:match('"itemLevelRange":{"minLevel":(%d+)'))
            local rarity = text:match('"rarity":"(%a+)"')
            if level and rarity and rarity ~= "Legendary" then
                local target
                for _, rule in ipairs(CRAFTED_RARITY_BY_LEVEL) do
                    if level <= rule[1] then target = rule[2]; break end
                end
                if target ~= rarity then
                    if RARITY_RANK[rarity] then rarity_steps[original] = RARITY_RANK[target] - RARITY_RANK[rarity] end
                    resource.data.rarity = target
                    changed = changed + 1
                    local key = rarity .. "->" .. target
                    moves[key] = (moves[key] or 0) + 1
                end
            end
        end
    end
    local parts = {}
    for key, count in pairs(moves) do parts[#parts + 1] = key .. " " .. count end
    table.sort(parts)
    log(string.format("crafted equipment rarity by level: %d items changed (%s)", changed, table.concat(parts, ", ")))
end

---------------------------------------------------------------------------
-- Crafted lore items at the armor level of their tier (developer, 2026-11-01)
--
-- Lore recipes open at the same flame altar levels as the armor sets of their
-- tier (T2..T7 = flame 3,4,5,6,8,9), but the lore copies' fixed item levels
-- (6,11,16,21,26,36,46) fall behind the armor from T5 on (armor 30, 40, 45; two
-- T7 lore shields are at 36). Each lore copy gets at least the most common
-- level of the crafted armor of its tier, read from the data (follows updates).
-- Part of the craftedLoreItems feature.
---------------------------------------------------------------------------

if not CRAFTED_LORE then
    log("crafted lore item levels: off (vanilla levels and crafting preview)")
else
    local counts = {}   -- tier -> level -> count, crafted armor only
    for _, original in ipairs(item_order) do
        local info = items[original]
        if crafted[original] and info.name:find("^Armor_") and info.tier then
            local level = tonumber(text_of(game.assets.get_resource(original, "keen::ItemInfo")):match('"itemLevelRange":{"minLevel":(%d+)'))
            if level then
                counts[info.tier] = counts[info.tier] or {}
                counts[info.tier][level] = (counts[info.tier][level] or 0) + 1
            end
        end
    end
    local armor_level, parts = {}, {}
    for tier = 0, 9 do
        local best, best_n = nil, 0
        for level, n in pairs(counts[tier] or {}) do
            if n > best_n or (n == best_n and level > best) then best, best_n = level, n end
        end
        if best then armor_level[tier] = best; parts[#parts + 1] = "T" .. tier .. "=" .. best end
    end
    log("crafted armor level per tier: " .. table.concat(parts, " "))

    local raised = 0
    local lore_counts = {}   -- tier -> vanilla lore level -> count (for the UI table below)
    for _, original in ipairs(item_order) do
        local info = items[original]
        local target = info.tier and armor_level[info.tier]
        if target and is_lore_copy(info.name) then
            local resource = game.assets.get_resource(original, "keen::ItemInfo")
            local min, max = text_of(resource):match('"itemLevelRange":{"minLevel":(%d+),"maxLevel":(%d+)}')
            min, max = tonumber(min), tonumber(max)
            -- The crafting preview table below is about lore crafting: real lore copies only.
            if min and info.name:find("_Lore_") then
                lore_counts[info.tier] = lore_counts[info.tier] or {}
                lore_counts[info.tier][min] = (lore_counts[info.tier][min] or 0) + 1
            end
            if min and min < target then
                local range = resource.data.itemLevelRange
                range.minLevel = target
                if max < target then range.maxLevel = target end
                raised = raised + 1
            end
        end
    end
    log(string.format("crafted lore items: %d raised to their tier's armor level", raised))

    -- The crafting screen previews the next lore level ("Base Lore Item Level:
    -- 26 > 36", The Flame Level 7/8) from its own table, FbUiBundle.menu.crafting
    -- .loreWeaponUpgrades = { flameLevel, itemLevel }, which repeats the vanilla
    -- lore levels. Each entry is matched to its tier by that vanilla level and
    -- gets the raised level, so the preview matches the crafted items.
    local new_level = {}   -- vanilla lore level -> raised level
    for tier, levels in pairs(lore_counts) do
        local best, best_n = nil, 0
        for level, n in pairs(levels) do
            if n > best_n or (n == best_n and level > best) then best, best_n = level, n end
        end
        if best and armor_level[tier] and armor_level[tier] > best then new_level[best] = armor_level[tier] end
    end
    local previews, changes = 0, {}
    for _, bundle in ipairs(game.assets.get_resources_by_type("keen::FbUiBundle")) do
        local upgrades = bundle.data.menu.crafting.loreWeaponUpgrades
        local i = 0
        for flame, level in tostring(upgrades):gmatch('"flameLevel":(%d+),"itemLevel":(%d+)') do
            i = i + 1
            local target = new_level[tonumber(level)]
            if target then
                upgrades[i].itemLevel = target
                previews = previews + 1
                changes[#changes + 1] = "flame " .. flame .. ": " .. level .. "->" .. target
            end
        end
    end
    log(string.format("lore upgrade preview table: %d entries raised (%s)", previews, table.concat(changes, ", ")))
end

---------------------------------------------------------------------------
-- Crafting cost follows the rarity change (developer's rule, 2026-11-01)
--
-- Every crafted item whose rarity the mod changed costs 25% more per rarity
-- step up and 25% less per step down, relative to its vanilla recipe (Rare ->
-- Epic 125%, Rare -> Legendary 150%, Rare -> Uncommon 75%). Same materials,
-- only the amounts: rounded to the nearest whole number, never below 1.
---------------------------------------------------------------------------

local COST_PER_RARITY_STEP = 0.25
do
    -- Recipe index (1-based, registry order) of every output item, from text.
    local text = text_of(single("keen::RecipeRegistryResource"))
    local recipes_text = text:sub((text:find('"recipes":%[') or 1))
    local recipes_of, index = {}, 0
    for list in recipes_text:gmatch('"output":%[(.-)%]') do
        index = index + 1
        for g in list:gmatch('"itemRef":"([%x%-]+)"') do
            recipes_of[g] = recipes_of[g] or {}
            table.insert(recipes_of[g], index)
        end
    end

    local recipes = single("keen::RecipeRegistryResource").data.recipes
    if #recipes ~= index then
        error(string.format("forged-and-found: recipe registry has %d recipes, text parse found %d outputs", #recipes, index))
    end
    local changed, examples, by_factor = 0, {}, {}
    for _, original in ipairs(item_order) do
        local steps = rarity_steps[original]
        if steps and steps ~= 0 then
            local factor = 1 + COST_PER_RARITY_STEP * steps
            for _, i in ipairs(recipes_of[original] or {}) do
                local inputs = recipes[i].input
                local before, after = {}, {}
                for j = 1, #inputs do
                    for _, field in ipairs({ "itemStack", "inputItemCategory" }) do
                        local part = inputs[j][field]
                        local count = part.count
                        if count > 0 then
                            local scaled = math.max(1, math.floor(count * factor + 0.5))
                            if scaled ~= count then part.count = scaled end
                            before[#before + 1] = count
                            after[#after + 1] = scaled
                        end
                    end
                end
                changed = changed + 1
                by_factor[factor] = (by_factor[factor] or 0) + 1
                if #examples < 6 then
                    examples[#examples + 1] = string.format("%s x%.2f: %s -> %s", items[original].name, factor,
                        table.concat(before, "/"), table.concat(after, "/"))
                end
            end
        end
    end
    local parts = {}
    for factor, n in pairs(by_factor) do parts[#parts + 1] = string.format("x%.2f %d", factor, n) end
    table.sort(parts)
    log(string.format("crafting cost by rarity change: %d recipes scaled (%s)", changed, table.concat(parts, ", ")))
    for _, e in ipairs(examples) do log("  cost example " .. e) end
end

---------------------------------------------------------------------------
-- Variant marker (setting variantMarker, off by default; client only): variants show as
-- "§ <original name>" in every language, rendered at runtime by the native DLL.
--
-- A name is a LocaTagReference: a GUID whose game.guid.hash is a LocaTagId,
-- looked up by binary search in the language's LocaTagCollectionResourceData
-- (enshrouded.exe+0x11FA0D0). Each item with variants gets a marker GUID whose
-- LocaTagId is in no text table, and its variants' ItemInfo.name points at it.
-- The manifest exports markerId/nameId per variant; the DLL answers a lookup of
-- a marker id with "§ " + the original name's text in the current language.
-- Nothing is added to text tables or archives (0.7.x did, and under EML the
-- archive stayed behind after uninstalling): removing the mod restores all.
-- Without the DLL the variants' names show as missing text (visible, harmless).
---------------------------------------------------------------------------

local LOCA_DATA = "keen::LocaTagCollectionResourceData"

local function content_of(hash)
    local ok, c = pcall(game.assets.get_content, hash)
    if ok and c then return c end
    return game.assets.get_content(game.guid.from_content_hash(hash))
end

-- Text ids in table order, read from text (no live references). LocaTagArgument
-- ids are plain numbers, so the pattern only matches LocaTagResource entries.
local function text_ids(data)
    local ids = {}
    for id in tostring(data):gmatch('{"id":{"value":(%d+)}') do ids[#ids + 1] = tonumber(id) end
    return ids
end

-- Index of id in the sorted ids, or nil.
local function find_sorted(ids, id)
    local lo, hi = 1, #ids
    while lo <= hi do
        local mid = (lo + hi) // 2
        if ids[mid] == id then return mid end
        if ids[mid] < id then lo = mid + 1 else hi = mid - 1 end
    end
    return nil
end

local marker_of = {} -- original GUID -> { id = marker LocaTagId, name_id = original name's LocaTagId }

if IS_SERVER then
    log("marker skipped (dedicated server: names are rendered by each client)")
elseif not VARIANT_MARKER then
    log("marker off (setting \"Mark variants with \194\167\")")
else
    local ok, err = pcall(function()
        -- Read-only check against the English table: a marker id must not be a real
        -- text id, and the original name must exist (else "§ " + nothing).
        local coll = single("keen::LocaTagCollectionResource").data
        local en
        for _, l in ipairs(coll.languages) do
            if l.language == "En_Us" then en = l.data end
        end
        if not en then error("no En_Us text table") end
        local ids = text_ids(content_of(en.hash):read_data():read_resource(LOCA_DATA))
        for i = 2, #ids do
            if ids[i - 1] >= ids[i] then error("En_Us text ids not ascending at " .. i) end
        end
        local renamed, marked, skipped = 0, 0, 0
        for _, original in ipairs(item_order) do
            local list = variants_of[original]
            if list and #list > 0 then
                local name = tostring(game.assets.get_resource(list[1].guid, "keen::ItemInfo").data.name)
                local guid = derive_guid(SEED .. "|name|" .. original)
                local id, name_id = game.guid.hash(guid), name ~= NONE and game.guid.hash(name)
                if find_sorted(ids, id) then error("marker text id " .. id .. " is already a text id") end
                if name_id and find_sorted(ids, name_id) then
                    marker_of[original] = { id = id, name_id = name_id }
                    marked = marked + 1
                    for _, v in ipairs(list) do
                        game.assets.get_resource(v.guid, "keen::ItemInfo").data.name = guid
                        renamed = renamed + 1
                    end
                else
                    skipped = skipped + 1
                end
            end
        end
        log(string.format("marker: %d variants of %d items point at marker names (%d items without an English name skipped); the native DLL renders them",
            renamed, marked, skipped))
    end)
    if not ok then
        marker_of = {}
        log("WARNING marker skipped, variants keep the original names: " .. tostring(err))
    end
end

---------------------------------------------------------------------------
-- Item registry + loot pool
--
-- ItemRegistryResource.itemRefs/dbgNames and LootableItemsResource.items are
-- parallel arrays (verified: items[i].itemId == hash(itemRefs[i]) for all 4207
-- vanilla items). The game indexes them by registry position, so every variant
-- appended to the registry gets its loot entry at the same position. A variant's
-- entry is a clone of its original's without labels (random loot never picks it)
-- and, for items whose rarity is rolled at drop, allows only Epic/Legendary.
-- The originals' entries are not changed.
---------------------------------------------------------------------------

-- ItemIds of all loot entries in order, read from text (no live references).
local function loot_item_ids(loot)
    local ids = {}
    for id in tostring(loot.items):gmatch('{"itemId":{"value":(%d+)}') do ids[#ids + 1] = tonumber(id) end
    return ids
end

do
    local reg = single("keen::ItemRegistryResource").data
    local loot = single("keen::LootableItemsResource").data
    local ids = loot_item_ids(loot)
    if #reg.itemRefs ~= #ids or #reg.itemRefs ~= #reg.dbgNames then
        error("forged-and-found: registry/loot arrays not parallel before patching")
    end
    local loot_index = {}
    for i, id in ipairs(ids) do loot_index[id] = i end

    -- Epic/Legendary part of an entry's rarity mask (an empty mask allows all five).
    local function epic_legendary(entry)
        local listed, out = false, {}
        for n in ((tostring(entry):match('"rarities":%[(.-)%]')) or ""):gmatch('"(%a+)"') do
            listed = true
            if n == "Epic" or n == "Legendary" then out[#out + 1] = n end
        end
        return listed and out or { "Epic", "Legendary" }
    end

    for _, original in ipairs(item_order) do
        local list = variants_of[original]
        if #list > 0 then
            local info = items[original]
            local i = loot_index[info.id]
            if not i then error("forged-and-found: no loot entry for " .. info.name) end
            local original_entry = loot.items[i]
            local labels = original_entry.labelGroups
            local has_labels = #labels.labels > 0 or #labels.childGroups > 0
            local high = epic_legendary(original_entry)
            local first -- index of variant 1's entry; variants 2..n clone it (cleared labels and mask included)
            for k, v in ipairs(list) do
                table.insert(reg.itemRefs, v.guid)
                table.insert(reg.dbgNames, v.name)
                table.insert(loot.items, k == 1 and original_entry or loot.items[first])
                local entry = loot.items[#loot.items]
                entry.itemId.value = v.id
                if k == 1 then
                    first = #loot.items
                    if info.gen and #high > 0 then entry.rarities = high end
                    if has_labels then entry.labelGroups = { labels = {}, childGroups = {} } end
                end
            end
        end
    end
    log(string.format("registry + loot pool: appended %d unlabeled variant entries (loot tables and presets stay vanilla)",
        #variants))
end

---------------------------------------------------------------------------
-- StaticHashMap insertion (in place)
--
-- Layout (verified on build 1273043): bucket = key % #entries; entries[b] =
-- {start, count} with buckets stored contiguously in bucket order; keys/values
-- are parallel arrays; order inside a bucket does not matter.
-- Inserts clones of the original's key/value at the end of the new key's
-- bucket, highest bucket first so pending positions stay valid, then rewrites
-- the bucket offsets once.
-- additions: list of { key = <u32>, src = <index of the original's entry> }
-- set_key(key_view, key), set_value(value_view, key): edit a cloned element.
---------------------------------------------------------------------------

local function insert_into_static_hash_map(map, additions, set_key, set_value)
    local layout = read_copy(map.entries)
    local n = #layout
    -- Hold the source elements before any insertion shifts positions.
    for _, a in ipairs(additions) do
        a.key_src, a.value_src = map.keys[a.src], map.values[a.src]
        a.bucket = a.key % n
    end
    table.sort(additions, function(x, y) return x.bucket > y.bucket end)
    local added = {}
    for _, a in ipairs(additions) do
        local e = layout[a.bucket + 1]
        local pos = e.start + e.count + 1
        table.insert(map.keys, pos, a.key_src)
        table.insert(map.values, pos, a.value_src)
        set_key(map.keys[pos], a.key)
        set_value(map.values[pos], a.key)
        added[a.bucket] = (added[a.bucket] or 0) + 1
    end
    local running = 0
    for b = 0, n - 1 do
        local e = layout[b + 1]
        local count = e.count + (added[b] or 0)
        if e.start ~= running or added[b] then
            local live = map.entries[b + 1]
            live.start = running
            live.count = count
        end
        running = running + count
    end
end

-- Checks bucket placement and contiguity from text (no live references);
-- returns key -> index.
local function verify_static_hash_map(map, key_pattern, label)
    local entries = read_copy(map.entries)
    local keys = {}
    for k in tostring(map.keys):gmatch(key_pattern) do keys[#keys + 1] = tonumber(k) end
    local n, running, index = #entries, 0, {}
    for b = 0, n - 1 do
        local e = entries[b + 1]
        if e.start ~= running then error("forged-and-found: " .. label .. " bucket " .. b .. " not contiguous") end
        for i = e.start + 1, e.start + e.count do
            local k = keys[i]
            if not k or k % n ~= b then error("forged-and-found: " .. label .. " key " .. tostring(k) .. " in wrong bucket") end
            index[k] = i
        end
        running = running + e.count
    end
    if running ~= #keys then error("forged-and-found: " .. label .. " count mismatch") end
    return index
end

local ITEM_KEY = '{"value":(%d+)}'            -- keys of ItemKnowledge: ItemId
local KNOWLEDGE_KEY = '{"id":{"value":(%d+)}}' -- keys of knowledge maps: KnowledgeId

---------------------------------------------------------------------------
-- Item knowledge (ItemId -> ItemKnowledge)
---------------------------------------------------------------------------

-- Item knowledge. Variants get NO ItemKnowledge entry (0.15.2, proven 2026-11-07). The game's item knowledge
-- (Name, Description, Lore, Recipes, Inspected flags per item) stops working for vanilla items
-- pushed past about position 5000 of this table: inserting 4224 variants moved ~2000 of them
-- there, which then showed a "new" pip forever and a "special item" popup on every pickup.
-- Without the entries the pips and popups behave as in vanilla, and variants still work:
-- inventory, crafting stations, lore crafting and pickups were tested in game. The cause
-- inside the game is unknown (a capacity of ~5120 entries is inferred, not proven).
do
    local data = single("keen::ItemKnowledgeResource").data
    local index = verify_static_hash_map(data, ITEM_KEY, "ItemKnowledge")
    for _, v in ipairs(variants) do
        if index[v.id] then error("forged-and-found: variant " .. v.name .. " collides with existing item knowledge id " .. v.id) end
    end
    log("item knowledge: variants not added (vanilla table kept as it is)")
end

---------------------------------------------------------------------------
-- World/player knowledge (an item's ItemId is also its KnowledgeId)
---------------------------------------------------------------------------

do
    local data = single("keen::GameKnowledgeResource").data
    for _, field in ipairs({ "worldKnowledge", "playerKnowledge" }) do
        local map = data[field]
        local index = verify_static_hash_map(map, KNOWLEDGE_KEY, field)
        local additions = {}
        for _, v in ipairs(variants) do
            if index[v.id] then error("forged-and-found: variant " .. v.name .. " collides with existing knowledge id " .. v.id) end
            local i = index[v.original_id]
            if i then additions[#additions + 1] = { key = v.id, src = i } end
        end
        insert_into_static_hash_map(map, additions,
            function(key, id) key.id.value = id end,
            function(value, id) value.id.id.value = id end)
        log(string.format("%s: added %d entries", field, #additions))
    end
end

---------------------------------------------------------------------------
-- Safety net (read from text). Abort startup (fatal error, nothing written to
-- saves) if a vanilla item changed or a lookup table is inconsistent.
---------------------------------------------------------------------------

for _, original in ipairs(item_order) do
    if #variants_of[original] > 0 then
        local text = text_of(game.assets.get_resource(original, "keen::ItemInfo"))
        local id = tonumber(text:match('^{"itemId":{"value":(%d+)}'))
        if id ~= items[original].id then
            error("forged-and-found: vanilla item " .. items[original].name .. " was modified, aborting")
        end
    end
end
for _, v in ipairs(variants) do
    -- Variants show the texture named by their objectId, i.e. the original's.
    if not IS_SERVER and not game.assets.get_resource(v.original, "keen::UiTextureResource", 0) then
        error("forged-and-found: original of " .. v.name .. " has no icon texture")
    end
end

-- Client and server must build the same variants (ItemIds and perks per slot), or a
-- player would see other enhancements than the server applies. Compare this line in
-- shroudforge-client.log and shroudforge-server.log.
do
    local parts = {}
    for i, v in ipairs(variants) do parts[i] = v.id .. ":" .. table.concat(v.perks, ",") end
    log(string.format("variant table fingerprint: %s (%d variants)", hex8(hasher.fnv1a32(table.concat(parts, ";"))),
        #variants))
end

do
    local reg = single("keen::ItemRegistryResource").data
    local refs = {}
    for g in tostring(reg.itemRefs):gmatch('"([%x%-]+)"') do refs[#refs + 1] = g end
    local names = 0
    for _ in tostring(reg.dbgNames):gmatch('"[^"]*"') do names = names + 1 end
    local ids = loot_item_ids(single("keen::LootableItemsResource").data)
    if names ~= #refs or #ids ~= #refs then
        error(string.format("forged-and-found: registry/loot lengths differ (%d refs, %d names, %d loot)", #refs, names, #ids))
    end

    local ik = single("keen::ItemKnowledgeResource").data
    local index = verify_static_hash_map(ik, ITEM_KEY, "ItemKnowledge (after)")
    for i, g in ipairs(refs) do
        local id = game.guid.hash(g)
        if ids[i] ~= id then error("forged-and-found: registry/loot mismatch at index " .. i) end
        -- Variants are appended at the end of the registry and have no ItemKnowledge (see above).
        if not index[id] and i <= #refs - #variants then
            error("forged-and-found: registry item without ItemKnowledge at index " .. i)
        end
    end
    local value_ids = {}
    for id in tostring(ik.values):gmatch('{"itemId":{"value":(%d+)}') do value_ids[#value_ids + 1] = tonumber(id) end
    for k, i in pairs(index) do
        if value_ids[i] ~= k then error("forged-and-found: ItemKnowledge key/value mismatch for " .. k) end
    end

    local gk = single("keen::GameKnowledgeResource").data
    local world = verify_static_hash_map(gk.worldKnowledge, KNOWLEDGE_KEY, "worldKnowledge (after)")
    local player = verify_static_hash_map(gk.playerKnowledge, KNOWLEDGE_KEY, "playerKnowledge (after)")
    for _, v in ipairs(variants) do
        if index[v.id] then error("forged-and-found: variant " .. v.name .. " has an ItemKnowledge entry") end
        if world[v.original_id] and not world[v.id] then error("forged-and-found: worldKnowledge missing variant " .. v.name) end
        if player[v.original_id] and not player[v.id] then error("forged-and-found: playerKnowledge missing variant " .. v.name) end
    end
end

for _, t in ipairs(SIZE_TYPES) do
    log(string.format("size %s: %s -> %s bytes", t, tostring(sizes_before[t]), tostring(serialized_size(t))))
end

---------------------------------------------------------------------------
-- Manifest
---------------------------------------------------------------------------

if loader.features.export then
    local lines = {}
    for i, v in ipairs(variants) do
        local names, vanilla = {}, {}
        for s, p in ipairs(v.perks) do names[s] = perk_names[p] or p end
        -- The original's perks too: low-rarity drops show only the first slot(s), so
        -- telling a variant from vanilla in game needs the vanilla perks side by side.
        for s, p in ipairs(items[v.original].perks) do vanilla[s] = perk_names[p] or p end
        local info = items[v.original]
        -- markerId/nameId (only with the marker on): read by the native DLL, which
        -- renders the marker name as "§ " + the text of nameId.
        local mark = marker_of[v.original]
        local marker = mark and string.format(',"markerId":%d,"nameId":%d', mark.id, mark.name_id) or ""
        lines[i] = string.format('{"original":"%s","originalId":%d,"index":%d,"name":"%s","variant":"%s","itemId":%d%s,"group":"%s","theme":"%s","rolledRarity":%s,"legendary":%s,"perks":["%s"],"vanilla":["%s"]}',
            v.original, v.original_id, v.index, v.name, v.guid, v.id, marker, info.group, v.theme or "", tostring(info.gen), tostring(info.legendary),
            table.concat(names, '","'), table.concat(vanilla, '","'))
    end
    -- First element: the switches the DLL needs. A manifest without this line (older
    -- versions) means variant drops off.
    table.insert(lines, 1, string.format('{"settings":{"variantDrops":%s,"autoDetect":%s}}', tostring(VARIANT_DROPS),
        tostring(AUTO_DETECT)))
    io.export("forged-and-found/manifest.json", "[\n" .. table.concat(lines, ",\n") .. "\n]")

    -- Pinned list for the next release: every variant built now, plus pinned
    -- entries whose item is gone (kept, append-only: the item may come back).
    local out = {
        "# forged-and-found pinned rolls (never remove shipped lines; perks change only by a deliberate rule change)",
        "# <original GUID> <index> <variant GUID> <perk GUID per slot>  # debug names",
    }
    local originals, listed = {}, {}
    for _, o in ipairs(item_order) do originals[#originals + 1] = o; listed[o] = true end
    for o in pairs(pinned) do if not listed[o] then originals[#originals + 1] = o end end
    table.sort(originals)
    for _, o in ipairs(originals) do
        local list = variants_of[o]
        if list and #list > 0 then
            for _, v in ipairs(list) do
                local names = {}
                for s, p in ipairs(v.perks) do names[s] = perk_names[p] or "-" end
                out[#out + 1] = string.format("%s %d %s %s  # %s: %s", o, v.index, v.guid, table.concat(v.perks, " "),
                    v.name, table.concat(names, ", "))
            end
        elseif pinned[o] then
            for _, e in ipairs(pinned[o]) do
                out[#out + 1] = string.format("%s %d %s %s  # original item missing in this game build", o, e.index, e.guid,
                    table.concat(e.perks, " "))
            end
        end
    end
    io.export("forged-and-found/pinned.txt", table.concat(out, "\n") .. "\n")
end
log("done")
