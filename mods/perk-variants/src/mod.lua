-- Perk Variants prototype 0.5.1 (test worlds only).
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
--   - ItemKnowledgeResource (StaticHashMap ItemId -> ItemKnowledge)
--   - GameKnowledgeResource world/player knowledge maps (an item's ItemId is
--     also its KnowledgeId)
--
-- Loot rule:
--   - Random loot: each variant's loot entry carries the original's labels with
--     the top labeled level's weights divided by the variant count. Items whose
--     rarity is rolled at drop: variant entries allow only Epic/Legendary and
--     the original keeps Common/Uncommon/Rare (both UNVERIFIED, see the loot
--     pool section). Items with a fixed Epic/Legendary rarity drop only as
--     variants (original's entry gets empty labelGroups, a state vanilla uses
--     for items that never drop randomly).
--     UNVERIFIED ASSUMPTION: label weights multiply along a branch of the label
--     tree. If they add up instead, variants drop somewhat more often than
--     vanilla. Verify (reverse engineer the loot picker) before release.
--   - Preset inventories (fixed chests etc.), fixed-rarity items only: in
--     selector groups a perk-item stack becomes one stack per variant, weight
--     divided by the count; in plain groups the stack is retargeted to one
--     variant, picked in turn (a child selector group gave nothing on pickup in
--     0.2.6). Rolled-rarity items stay vanilla there (no rarity field in presets).
-- Not covered: enemy-carried weapons (enemy setup references the item directly).
--
-- Determinism: variant GUIDs derive only from the original GUID, the variant
-- index and SEED (ItemId = game.guid.hash(GUID)), so variant k of an item has
-- the same ItemId on every launch and machine. Perks come from the pinned list
-- shipped in data/pinned.txt, so game updates cannot reshuffle them; only items
-- missing from that list are rolled (deterministically from SEED and the
-- current perk pools) and exported for the next release.
--
-- EML notes:
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

-- EML skips patching when nothing changed since the last launch and still runs
-- mods with patching disabled. The previous patch is still applied.
if not loader.features.patch then
    print("[perk-variants] patching skipped by loader (cached patch still applied)")
    return
end

local SEED = "perk-variants/v0"          -- variant GUIDs (never change: saves store them)
local ROLL_SEED = "perk-variants/rolls-v1" -- rolls of items not in the pinned list
-- Only items that can drop as Epic or Legendary get variants (~745). Total
-- variants must stay within what is known to start: 4795 worked (0.2.6/0.2.9);
-- 9579 overflowed a ~4 MiB buffer during zstd decompression (cause unknown).
local MAX_VARIANTS = 6
-- Only the first RANDOM_LOOT_VARIANTS variants of an item carry random-loot labels;
-- the rest drop from presets only.
local RANDOM_LOOT_VARIANTS = MAX_VARIANTS
-- TEST switch: preset entries that always spawn drop the original AND a variant,
-- so both can be compared side by side. false = normal behaviour (variant only).
local PAIR_TEST = false
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

local function log(msg) print("[perk-variants] " .. msg) end

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
                error("perk-variants: unterminated JSON string")
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
            if not s then error("perk-variants: unexpected JSON at " .. pos .. ": " .. text:sub(pos, pos + 20)) end
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
    if first ~= "{" and first ~= "[" then error("perk-variants: cannot copy value: " .. text:sub(1, 40)) end
    return json_decode(text)
end

---------------------------------------------------------------------------
-- Read game data (read-only, via tostring)
---------------------------------------------------------------------------

local function text_of(resource) return tostring(resource.data) end

local function single(type_name)
    local list = game.assets.get_resources_by_type(type_name)
    if #list ~= 1 then error("perk-variants: expected one " .. type_name .. ", found " .. #list) end
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
        local info = {
            name = name, perks = perks, group = wide_group(name, class), class = class, id = id,
            tier = tonumber(name:match("_T(%d+)")), gen = gen, disabled = disabled,
            legendary = legendary, eligible = (epic or legendary) and not special,
        }
        -- Identity anchor: rings (Ring of Health, of Mana, ...) and items named after
        -- an element keep their first perk; a Ring of Health without Health is wrong.
        info.anchor = info.group == "Ring"
        for _, e in ipairs(ELEMENTS) do
            if name:find("_" .. e .. "_") or name:find("_" .. e .. "$") then info.anchor = true end
        end
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
-- Roll perks
--
-- Each variant has one theme (developer's themes): Sustain, Empower,
-- Elemental (1-2 elements), Physical, Crit, Enhance. The 6 variants of an item
-- spread over the themes its pool supports (deterministic shuffle). Slots:
--   - slot 1 of rings and element-named items keeps the vanilla perk (identity);
--   - slot 5 of Legendary-capable items is the capstone: a character skill at +2
--     (+1 if the skill has no +2 perk);
--   - Enhance: every other slot is a character skill (+1);
--   - other themes: SKILL_SLOT is a character skill, the rest theme perks, each
--     with THEME_STRAY chance of any non-skill perk of the item type;
--   - Sustain/Empower prefer the class's resource (RESOURCE_BIAS).
-- Theme perks come from the item's wide group pool, swapped for the member of
-- their tier line that fits the item's tier. Skills only from the item's class
-- (melee weapons/shields Warrior, bows/daggers Ranger, staffs/wands Mage,
-- armor by class) or Generic; a skill appears once per item. Every second
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
            local q = two and s.two or s.one
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
        elseif slot == 1 and info.anchor then
            q = vanilla
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
-- Pinned rolls (data/pinned.txt, shipped with the mod, append-only)
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
                error("perk-variants: malformed line in " .. PINNED_FILE .. ": " .. line)
            end
            local list = pinned[original] or {}
            pinned[original] = list
            if index ~= #list + 1 then
                error(string.format("perk-variants: %s: variant %d of %s out of order", PINNED_FILE, index, original))
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
    if used_ids[id] then error("perk-variants: ItemId collision for " .. info.name .. " #" .. index) end
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

for _, original in ipairs(item_order) do
    local info = items[original]
    local seen = { [table.concat(info.perks, ",")] = true } -- never duplicate vanilla
    local list = {}
    local source = game.assets.get_resource(original, "keen::ItemInfo")
    if not game.assets.get_resource(original, "keen::UiTextureResource", 0) then
        error("perk-variants: no icon texture for " .. info.name)
    end

    for _, e in ipairs(pinned[original] or {}) do
        local guid = derive_guid(SEED .. "|" .. original .. "|" .. e.index)
        if guid ~= e.guid then
            error(string.format("perk-variants: %s variant %d: GUID %s, pinned %s (derivation changed; saves would lose these items)",
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
-- Item registry + random loot pool
--
-- ItemRegistryResource.itemRefs/dbgNames and LootableItemsResource.items are
-- parallel arrays (verified: items[i].itemId == hash(itemRefs[i]) for all 4207
-- vanilla items). The game indexes them by registry position, so every variant
-- appended to the registry gets its loot entry at the same position.
---------------------------------------------------------------------------

-- ItemIds of all loot entries in order, read from text (no live references).
local function loot_item_ids(loot)
    local ids = {}
    for id in tostring(loot.items):gmatch('{"itemId":{"value":(%d+)}') do ids[#ids + 1] = tonumber(id) end
    return ids
end

-- Divides the weights of the top labeled level of each branch by n (see the
-- UNVERIFIED ASSUMPTION in the header). Works on a live view.
local function scale_label_weights(group, n)
    if #group.labels > 0 then
        for _, label in ipairs(group.labels) do label.weight = label.weight / n end
        return
    end
    for _, child in ipairs(group.childGroups) do scale_label_weights(child, n) end
end

do
    local reg = single("keen::ItemRegistryResource").data
    local loot = single("keen::LootableItemsResource").data
    local ids = loot_item_ids(loot)
    if #reg.itemRefs ~= #ids or #reg.itemRefs ~= #reg.dbgNames then
        error("perk-variants: registry/loot arrays not parallel before patching")
    end
    local loot_index = {}
    for i, id in ipairs(ids) do loot_index[id] = i end

    -- Rarity split for items whose rarity is rolled at drop: variant entries allow
    -- only Epic/Legendary, the original keeps Common/Uncommon/Rare. UNVERIFIED
    -- ASSUMPTION: the picker rolls a rarity first (globalRarityDropRates) and then
    -- picks among entries whose `rarities` mask allows it, so the original keeps
    -- its full weight and the variants share it (weights / n). Items with a fixed
    -- Epic/Legendary rarity drop only as variants (original's labels cleared).
    local LOW, HIGH = { Common = true, Uncommon = true, Rare = true }, { Epic = true, Legendary = true }
    local function mask_of(entry)
        local names = {}
        for n in ((tostring(entry):match('"rarities":%[(.-)%]')) or ""):gmatch('"(%a+)"') do names[#names + 1] = n end
        if #names == 0 then names = { "Common", "Uncommon", "Rare", "Epic", "Legendary" } end
        return names
    end
    local function keep(names, set)
        local out = {}
        for _, n in ipairs(names) do if set[n] then out[#out + 1] = n end end
        return out
    end

    local swapped, split = 0, 0
    for _, original in ipairs(item_order) do
        local list = variants_of[original]
        if #list > 0 then
            local info = items[original]
            local i = loot_index[info.id]
            if not i then error("perk-variants: no loot entry for " .. info.name) end
            local original_entry = loot.items[i]
            local labels = original_entry.labelGroups
            local random_drop = #labels.labels > 0 or #labels.childGroups > 0
            local labeled = math.min(#list, RANDOM_LOOT_VARIANTS)
            local mask = mask_of(original_entry)
            local low, high = keep(mask, LOW), keep(mask, HIGH)
            local first -- index of variant 1's entry; variants 2..n clone it (scaled weights and mask included)
            for k, v in ipairs(list) do
                table.insert(reg.itemRefs, v.guid)
                table.insert(reg.dbgNames, v.name)
                table.insert(loot.items, k == 1 and original_entry or loot.items[first])
                local entry = loot.items[#loot.items]
                entry.itemId.value = v.id
                if k == 1 then
                    first = #loot.items
                    if random_drop then scale_label_weights(entry.labelGroups, labeled) end
                    if info.gen and #high > 0 then entry.rarities = high end
                elseif k > labeled and random_drop then
                    entry.labelGroups = { labels = {}, childGroups = {} } -- presets only
                end
            end
            if random_drop then
                if info.gen and #low > 0 then
                    original_entry.rarities = low
                    split = split + 1
                else
                    original_entry.labelGroups = { labels = {}, childGroups = {} }
                    swapped = swapped + 1
                end
            end
        end
    end
    log(string.format("registry + loot pool: appended %d variants; random loot: %d items drop only as variants, %d split (original Common-Rare, variants Epic/Legendary)",
        #variants, swapped, split))
end

---------------------------------------------------------------------------
-- Preset inventories (fixed chests etc.)
--
-- DefaultInventoryResource.rootGroup is a tree of groups { isSelector, stacks,
-- groups, lootLabels }; stacks are ItemStackInfoResource { itemRef, item,
-- countMin, countMax, spawnProbability, weight, lootLabelsId }.
---------------------------------------------------------------------------

do
    -- Preset stacks have no rarity field: an item whose rarity is rolled at drop
    -- would make a fixed spot yield variants at any rarity (or, with the variants'
    -- rarity restriction, always Epic/Legendary). So presets keep vanilla items
    -- for those; only items with a fixed Epic/Legendary rarity become variants.
    local by_guid = {}
    for original, list in pairs(variants_of) do
        if #list > 0 and not items[original].gen then by_guid[original] = list end
    end
    local in_selectors, in_plain, touched = 0, 0, 0

    local function retarget(stack, v, weight)
        stack.itemRef = v.guid
        stack.item.value = v.id
        stack.weight = weight
    end

    local function walk(group)
        local count = 0
        for _, child in ipairs(group.groups) do count = count + walk(child) end
        -- Walk stacks backwards so inserting/removing at index i keeps earlier indices valid.
        for i = #group.stacks, 1, -1 do
            local list = by_guid[group.stacks[i].itemRef]
            if list then
                local n = #list
                if group.isSelector then
                    -- One entry is picked by weight: split the original's weight across its variants.
                    local weight = group.stacks[i].weight / n
                    for k = n, 2, -1 do
                        table.insert(group.stacks, i + 1, group.stacks[i]) -- clone of the untouched original
                        retarget(group.stacks[i + 1], list[k], weight)
                    end
                    retarget(group.stacks[i], list[1], weight)
                    in_selectors = in_selectors + 1
                elseif PAIR_TEST then
                    -- TEST: every entry spawns, so keep the original and add one variant next
                    -- to it (as 0.1.4 did): each such spot drops a vanilla/variant pair for a
                    -- side-by-side check. Prefer a variant whose slot 1 differs from vanilla,
                    -- the only slot a common drop shows.
                    in_plain = in_plain + 1
                    local vanilla_first = items[group.stacks[i].itemRef].perks[1]
                    local pick = list[1]
                    for _, v in ipairs(list) do
                        if v.perks[1] ~= vanilla_first then pick = v; break end
                    end
                    table.insert(group.stacks, i + 1, group.stacks[i]) -- clone of the untouched original
                    retarget(group.stacks[i + 1], pick, group.stacks[i].weight)
                else
                    -- Every entry spawns: retarget the stack to one variant, taking the
                    -- variants in turn across all plain stacks (deterministic for a given
                    -- game build). 0.2.0-0.2.6 replaced the stack by a child selector group
                    -- with one stack per variant; the ground sword in the starting area then
                    -- gave nothing on pickup (0.2.6). A direct retarget worked in 0.1.5.
                    in_plain = in_plain + 1
                    local stack = group.stacks[i]
                    retarget(stack, list[(in_plain - 1) % n + 1], stack.weight)
                end
                count = count + 1
            end
        end
        return count
    end

    for _, r in ipairs(game.assets.get_resources_by_type("keen::ecs::DefaultInventoryResource")) do
        -- Cheap read-only pre-check so untouched presets are not touched at all.
        local relevant = false
        for g in text_of(r):gmatch('"itemRef":"([%x%-]+)"') do
            if by_guid[g] then relevant = true; break end
        end
        if relevant and walk(r.data.rootGroup) > 0 then touched = touched + 1 end
    end
    log(string.format("presets: %d inventories; %d stacks split in selector groups, %d plain stacks %s",
        touched, in_selectors, in_plain, PAIR_TEST and "given a variant next to the original (PAIR_TEST)" or "retargeted"))
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
        if e.start ~= running then error("perk-variants: " .. label .. " bucket " .. b .. " not contiguous") end
        for i = e.start + 1, e.start + e.count do
            local k = keys[i]
            if not k or k % n ~= b then error("perk-variants: " .. label .. " key " .. tostring(k) .. " in wrong bucket") end
            index[k] = i
        end
        running = running + e.count
    end
    if running ~= #keys then error("perk-variants: " .. label .. " count mismatch") end
    return index
end

local ITEM_KEY = '{"value":(%d+)}'            -- keys of ItemKnowledge: ItemId
local KNOWLEDGE_KEY = '{"id":{"value":(%d+)}}' -- keys of knowledge maps: KnowledgeId

---------------------------------------------------------------------------
-- Item knowledge (ItemId -> ItemKnowledge)
---------------------------------------------------------------------------

do
    local data = single("keen::ItemKnowledgeResource").data
    local index = verify_static_hash_map(data, ITEM_KEY, "ItemKnowledge")
    local additions = {}
    for _, v in ipairs(variants) do
        if index[v.id] then error("perk-variants: variant " .. v.name .. " collides with existing item knowledge id " .. v.id) end
        local i = index[v.original_id]
        if i then additions[#additions + 1] = { key = v.id, src = i } end
    end
    insert_into_static_hash_map(data, additions,
        function(key, id) key.value = id end,
        function(value, id) value.itemId.value = id end)
    log(string.format("item knowledge: added %d entries", #additions))
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
            if index[v.id] then error("perk-variants: variant " .. v.name .. " collides with existing knowledge id " .. v.id) end
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
            error("perk-variants: vanilla item " .. items[original].name .. " was modified, aborting")
        end
    end
end
for _, v in ipairs(variants) do
    -- Variants show the texture named by their objectId, i.e. the original's.
    if not game.assets.get_resource(v.original, "keen::UiTextureResource", 0) then
        error("perk-variants: original of " .. v.name .. " has no icon texture")
    end
end

do
    local reg = single("keen::ItemRegistryResource").data
    local refs = {}
    for g in tostring(reg.itemRefs):gmatch('"([%x%-]+)"') do refs[#refs + 1] = g end
    local names = 0
    for _ in tostring(reg.dbgNames):gmatch('"[^"]*"') do names = names + 1 end
    local ids = loot_item_ids(single("keen::LootableItemsResource").data)
    if names ~= #refs or #ids ~= #refs then
        error(string.format("perk-variants: registry/loot lengths differ (%d refs, %d names, %d loot)", #refs, names, #ids))
    end

    local ik = single("keen::ItemKnowledgeResource").data
    local index = verify_static_hash_map(ik, ITEM_KEY, "ItemKnowledge (after)")
    for i, g in ipairs(refs) do
        local id = game.guid.hash(g)
        if ids[i] ~= id then error("perk-variants: registry/loot mismatch at index " .. i) end
        if not index[id] then error("perk-variants: registry item without ItemKnowledge at index " .. i) end
    end
    local value_ids = {}
    for id in tostring(ik.values):gmatch('{"itemId":{"value":(%d+)}') do value_ids[#value_ids + 1] = tonumber(id) end
    for k, i in pairs(index) do
        if value_ids[i] ~= k then error("perk-variants: ItemKnowledge key/value mismatch for " .. k) end
    end

    local gk = single("keen::GameKnowledgeResource").data
    local world = verify_static_hash_map(gk.worldKnowledge, KNOWLEDGE_KEY, "worldKnowledge (after)")
    local player = verify_static_hash_map(gk.playerKnowledge, KNOWLEDGE_KEY, "playerKnowledge (after)")
    for _, v in ipairs(variants) do
        if index[v.original_id] and not index[v.id] then error("perk-variants: ItemKnowledge missing variant " .. v.name) end
        if world[v.original_id] and not world[v.id] then error("perk-variants: worldKnowledge missing variant " .. v.name) end
        if player[v.original_id] and not player[v.id] then error("perk-variants: playerKnowledge missing variant " .. v.name) end
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
        lines[i] = string.format('{"original":"%s","originalId":%d,"index":%d,"name":"%s","variant":"%s","itemId":%d,"group":"%s","theme":"%s","rolledRarity":%s,"legendary":%s,"perks":["%s"],"vanilla":["%s"]}',
            v.original, v.original_id, v.index, v.name, v.guid, v.id, info.group, v.theme or "", tostring(info.gen), tostring(info.legendary),
            table.concat(names, '","'), table.concat(vanilla, '","'))
    end
    io.export("perk-variants/manifest.json", "[\n" .. table.concat(lines, ",\n") .. "\n]")

    -- Pinned list for the next release: every variant built now, plus pinned
    -- entries whose item is gone (kept, append-only: the item may come back).
    local out = {
        "# perk-variants pinned rolls (append-only; never edit or remove shipped lines)",
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
    io.export("perk-variants/pinned.txt", table.concat(out, "\n") .. "\n")
end
log("done")
