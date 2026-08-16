plugin = {
    id          = "dbi-codex",
    name        = "DB Infinity Codex",
    version     = "2026.08.16.005",
    author      = "Solao",
    description = "A searchable record of items and mobs: what they are, and where you found them.",
    settings    = { saveState = true },
}

-- Two records, kept from what the MUD says in passing rather than from anything
-- this asks it.
--
--   items   what 'analyze' printed, plus where the thing came from
--   mobs    a name in an area, its power level once something has scanned it,
--           and every room it has been seen in
--
-- A mob is one entry per area + name + power level, with rooms one-to-many
-- underneath. The same 'An elite warrior' standing in nine rooms of The Ginyu
-- Base is one mob with nine sightings; the same name in another area, or at a
-- different power, is a different thing and gets its own entry.
--
-- Power level is the last field to arrive and often never does, so an entry
-- starts without one and is merged into the scanned entry when a reading turns
-- up. Merging rather than duplicating is the whole reason the key is built the
-- way it is.
--
-- Nothing is sent from here without a click. Portrait learned that the hard
-- way: a plugin that talks on its own talks over the login prompt.

local VERSION = plugin.version
local TAG = "[DBI Codex " .. VERSION .. "] "

-- The client does not reliably tear down a previous load's timers or widgets,
-- so each load stamps a token and an older tick retires itself.
local INSTANCE = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))

local GOLD    = "#e8b45c"
local INK     = "#edf2f8"
local INK_DIM = "#969fab"
local RULE    = "rgba(255,255,255,0.12)"
local PANEL_BG = "rgba(15,22,33,0.92)"
local GOOD    = "#5ec966"
local UNKNOWN = "#ff9a3c"

-- Storage is shared with five other plugins and this is the only one that grows
-- on its own, so it is bounded from the start rather than when it becomes a
-- problem. Oldest-seen goes first.
local MAX_MOBS  = 400
local MAX_ITEMS = 400
local MAX_ROOMS = 40        -- sightings kept per mob
local MAX_SRC   = 12        -- sources kept per item

local widget = nil
local shown = true
local panelAlpha = 0.92
local termSize = 13

local mobs = {}
local items = {}

-- Who teaches what, keyed by room.
--
--   [vnum] = { area = "", teaches = { [skill] = 1 }, refused = { [skill] = 1 } }
--
-- Nothing in the game lists a trainer's stock -- 'practice' with no argument
-- prints YOUR tree, not theirs -- so the only way to learn one is to try and
-- remember. Same shape as the dry simulators in the trainer plugin, which
-- keep the power level a capsule stopped paying at rather than a flag.
--
-- This lives here rather than in dbi-train because it is a fact about a
-- place, which is what this plugin is for, and it is the same for everyone.
-- What a skill costs YOU, and which ones you have chosen to use, stay over
-- there.
local trainers = {}
-- The skill the last 'prac <skill>' asked for. The refusal does not name it:
--
--   An Attendant tells you, 'I do not know how to teach that.'
--
-- NOT called 'pending'. There is already one of those for the search box, and
-- two locals of one name in a chunk is a JavaScript let clash that stops the
-- whole file loading.
local pracAsk = ""
local filter = ""
-- What is in the search box right now, which is not the same as what is being
-- filtered on. Typing updates this and renders NOTHING -- rebuilding the panel
-- on a keystroke would replace the input and take the focus with it. Enter, or
-- the button, is what promotes it to the filter.
local pending = ""
-- Mobs in this area only, unless a search is running. Walking into somewhere
-- new and being shown every mob you have ever met is not a list, it is an
-- archive.
local hereOnly = true

-- How tall the panel is, and which page of the list is showing.
--
-- Measured from the resize event rather than asked for: widgetInfo lied about
-- the panel size once already and cost a release. The event carries what the
-- widget actually became, and the starting value is what createWidget asked
-- for, which is right until the first drag.
local panelH = 420
local page = 1

-- Roughly what a row costs. A mob is its name and a line of rooms under it; an
-- item is its name and a line of detail. Both are about two lines of text plus
-- the padding, and the chrome above is the bar, the search box, the header line
-- and the pager itself.
local ROW_PX = 34
local CHROME_PX = 116

local function perPage()
    local n = math.floor((panelH - CHROME_PX) / ROW_PX)
    if n < 3 then return 3 end
    if n > 40 then return 40 end
    return n
end
local view = "mobs"
-- Which item the detail view is showing, if it is. Empty means the list.
local detail = ""
-- Which mob's keyword is being edited, and what has been typed into it so
-- far. Empty means nobody is typing.
local kwEdit = ""
local kwTyped = ""
-- Whether the 'found on' tree is open. One flag, because only one item's detail
-- is on screen at a time.
local srcOpen = false

-- What the analyze reader is in the middle of. One table rather than six names:
-- Lua 5.1 caps a chunk at 200 locals and Portrait spent a release paying for
-- that lesson.
local ana = { on = false, name = "", rec = nil, n = 0 }
-- Whether the block currently open is worth announcing when it closes.
local anaFresh = false

-- Assigned far below, beside the rest of the inter-plugin section, but called
-- from the readers up here. Declared with 'local x = nil' and assigned with
-- 'x = function()' -- NOT 'function x()', which the transpiler emits as a
-- declaration shadowing the let and refuses to load the file over.
local announce = nil

-- The last thing scanned, waiting for its reading. The scouter's own anchors,
-- because they are already proven against this MUD:
--
--   A yellow outline forms around A Soldier of Baal in your vision.
--     _
--    (*)
--     `---> 10,000,000
--
-- A scan does NOT always answer. 'scan eng' in the transcript produced the
-- outline line and then nothing at all, so the pending target has to expire
-- rather than wait forever for an arrow that is not coming.
local scan = { who = "", at = 0 }
local SCAN_WAIT = 8

-- Mobs already offered a scan link this session, so walking a corridor of nine
-- elite warriors does not print nine invitations to scan the same thing.
local offered = {}

-- The word that actually scanned a given mob, learned rather than guessed.
-- Keyed on the cleaned name, because the working keyword is a property of the
-- mob and not of the room it happened to be standing in.
local scanKw = {}

-- The last scan link this plugin offered: which mob, which word, and which
-- candidate that was. If the MUD answers "They aren't here." the next word is
-- tried, and whichever finally works is kept.
local tried = { name = "", word = "", idx = 0, at = 0 }

-- 'dbdex scanall' works through the room one mob at a time.
--
-- One at a time because 'tried' is a single slot: it holds which mob a scan
-- was sent for and which word was used, and that is how a returning outline
-- gets attached to the right name. Fire three scans together and the outlines
-- come back with no way to tell whose is whose, and the keyword learned goes
-- on the wrong mob.
local bulk = { list = {}, at = 0, on = false }
local linkOn = true

-- The vnum we were standing in when the last line came through. Nothing else
-- tracks this; the readers all ask here() fresh.
local atRoom = nil

-- Set by the reader when it has replaced a line, read by onLine. A flag rather
-- than a second return value: a function that returns two values on some paths
-- and one on others cannot be read back into two locals here, and that has
-- already cost five releases on another panel.
local dropLine = false

-- How many entries the sweep has removed. In-place deletion did not work here
-- and the count is how you tell the rebuild is doing its job.
local sweptOff = 0

-- Which store the records came back out of, for the banner and for diag.
local loadedFrom = "nothing"
-- Whether the store answered at all when init() asked it.
--
-- It does not always. Default-scope tables live in the world file and init()
-- runs before a world is open; this plugin is on the global scope, which is
-- documented as independent of that, but "the read returned nothing" is a
-- state worth knowing either way -- because a save made in it must not be
-- allowed to stand in for everything that was there.
local loadedOk = false

-- Every widget event, printed as it arrives, when asked for. Which of them the
-- client actually delivers for an <input> -- and what fields ride along -- is
-- the whole question, and it is one reload away from being answered rather than
-- guessed at.
local uiTrace = false
local lastUi = "nothing yet"

local lastError = "none"
local sawRooms = 0
local sawMobs = 0
local sawItems = 0
local sawSales = 0

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

local function trimBoth(s)
    local out = tostring(s or "")
    out = out:gsub("^%s+", "")
    out = out:gsub("%s+$", "")
    return out
end

-- A value is a number only if it says so. tonumber is Number() here, which
-- turns nil and "" into 0 and a bad string into NaN -- and NaN is truthy, so a
-- plain 'if n then' waves it straight through.
local function safeNum(v)
    local t = type(v)
    if t == "number" then
        if v ~= v then return nil end
        return v
    end
    if t ~= "string" then return nil end
    local s = trimBoth(v):gsub(",", "")
    if s == "" then return nil end
    local n = tonumber(s)
    if type(n) ~= "number" then return nil end
    if n ~= n then return nil end
    return n
end

-- One capture, normalised to a string or a real nil. A failed match hands back
-- undefined here, and undefined is truthy -- so 'if m then' passes and the
-- value flows on as the word "undefined".
local function capOf(s, pat)
    local m = s:match(pat)
    if type(m) ~= "string" then return nil end
    if m == "" then return nil end
    return m
end

local function escapeHtml(s)
    local out = tostring(s or "")
    out = out:gsub("&", "&amp;")
    out = out:gsub("<", "&lt;")
    out = out:gsub(">", "&gt;")
    out = out:gsub('"', "&quot;")
    return out
end

-- ipairs, never '#'. These lists are edited in place, and '#' does not follow
-- table.remove in this runtime -- an append lands past the end and every reader
-- stops at the hole. Portrait lost four releases to it.
local function rowCount(rows)
    if type(rows) ~= "table" then return 0 end
    local n = 0
    for _ in ipairs(rows) do n = n + 1 end
    return n
end

local function push(rows, v)
    rows[rowCount(rows) + 1] = v
end

-- Three colour tags on this MUD, not two: '&x' foreground, '^x' background and
-- '}x' for the expanded palette. They reach the map's stored room names --
-- 'dbdex diag' read back 'Songhold -- Elite Quarters&D' -- so anything shown or
-- keyed has to drop them first.
--
-- The missing 'tr' in that name is damage already done upstream and there is
-- nothing here that can undo it. This only stops it getting worse.
local function stripTags(s)
    local out = tostring(s or "")
    out = out:gsub("&.", "")
    out = out:gsub("%^.", "")
    out = out:gsub("%}.", "")
    return trimBoth(out)
end

-- Names arrive with a count on them off a corpse -- 'Hardened Combat Boots (5)'
-- -- and with an equipped marker off analyze -- 'Kaioshin's Boots (Equipped)'.
-- Neither is part of the name.
local function cleanName(s)
    local out = stripTags(s)
    out = out:gsub("%s*%([^()]*%)%s*$", "")
    return trimBoth(out)
end

-- Words that are never what you would type at the MUD. 'An elite warrior'
-- scanned as 'an' otherwise, which is an article rather than a target.
local SKIP = {
    a = true, an = true, the = true, of = true, ["and"] = true,
    some = true, ["in"] = true, ["on"] = true,
}

-- Every word worth typing, in the order worth trying.
--
-- The first is usually right and the transcript says so: across three days,
-- 'ginyu', 'captain', 'elite', 'giga', 'zeta', 'starship', 'legende' and
-- 'dissection' all scanned their mob, and every one of them is the first word
-- of the name. It is also the more DISTINCTIVE end -- 'A captain of Frieza's
-- army' is a captain, not an army, and Giga, Zeta and Dissection Android would
-- all collapse onto 'android' if the last word won.
--
-- But it is not always right. 'A seasoned soldier' answers to 'soldier', not
-- to 'seasoned'. So the rest of the words are kept as fallbacks, tried in turn
-- when the MUD says the first one is not here, and the one that works is
-- remembered against the mob.
local function keywords(s)
    local out = {}
    for w in stripTags(s):gmatch("%a+") do
        local low = w:lower()
        if not SKIP[low] and #low > 1 then out[#out + 1] = low end
    end
    return out
end

local function keyword(s)
    local words = keywords(s)
    if #words == 0 then return "" end
    return words[1]
end

-- 1000000 -> 1,000,000. Read off the panel a hundred times a night, and an
-- unbroken run of digits is the one thing nobody can read at a glance.
local function commas(n)
    local out = tostring(math.floor(n))
    -- Compared, not counted.
    --
    -- This was 'out, more = out:gsub(...)' looping while more > 0, and gsub's
    -- second return is a two-value return -- the shape that is not reliable
    -- here. The loop ran one pass and stopped, so a seven-figure power level
    -- came out as '1000,000' with the comma in the wrong place.
    --
    -- Comparing the result against what went in needs no second value at all.
    while true do
        local step = out:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
        if step == out then return out end
        out = step
    end
end

local function keyOf(s)
    return cleanName(s):lower()
end

----------------------------------------------------------------------
-- where we are
----------------------------------------------------------------------

-- Looked up through _G, the way the mapper does it. A global this build does
-- not have throws on the way IN -- before the call happens -- where a pcall
-- wrapped around the call cannot catch it. So the name is fetched first and
-- only called if it is really there.
local function callable(name)
    local ok, fn = pcall(function() return _G[name] end)
    if ok and type(fn) == "function" then return fn end
    return nil
end

local function mapCall(name, a)
    local fn = callable(name)
    if not fn then return nil end
    local ok, v = pcall(fn, a)
    if not ok then return nil end
    return v
end

-- getPlayerRoom() returns a bare vnum NUMBER, not a room table -- the guide
-- calls that the single most common trap with this call. It is nil until the
-- client has tracked a room, so everything below has to survive that.
local function here()
    local n = safeNum(mapCall("getPlayerRoom"))
    if not n then return nil end

    local room = mapCall("getMapRoom", n)
    if type(room) ~= "table" then return nil end

    -- 'area' and 'zone' are both spellings of the same field, and either can be
    -- the one this build fills in.
    local areaName = room.area
    if type(areaName) ~= "string" or areaName == "" then areaName = room.zone end
    if type(areaName) ~= "string" then areaName = "" end

    -- Only the vnum and the area are kept. The room's NAME is not: the map
    -- already holds one, it can be corrected there, and a copy taken at
    -- sighting time cannot. It is resolved for display instead, so a name fixed
    -- later shows fixed everywhere.
    return { num = n, area = stripTags(areaName) }
end

-- The map's name for a room, now, rather than whatever it was called when the
-- sighting was recorded. Falls back to the number, which is the thing that
-- actually identifies it.
local function roomLabel(vnum)
    local n = safeNum(vnum)
    if not n then return "?" end
    local room = mapCall("getMapRoom", n)
    if type(room) == "table" and type(room.name) == "string" then
        local nm = stripTags(room.name)
        if nm ~= "" then return nm end
    end
    return "#" .. tostring(n)
end

-- What the named race-skill trainers teach, and where they stand.
--
-- Seeded rather than learned, because there is no way to learn it: you would
-- have to already be standing in front of one. Compiled by the DBI community
-- at dbi.quest.fyi/raceskill-trainers -- game facts rather than anyone's
-- code, and the same for every player, which is why they are here and not in
-- the private trainer plugin.
--
-- The generic attendant in a training room is a different animal and IS
-- learned, below. These are the named ones you go looking for.
local TAUGHT_BY = {
    { who = "Piccolo",       race = "any",       where = "Bear Forest (w, n, n from Zaede)",
      skills = { "ki-heal", "split-form" } },
    { who = "King Kai",      race = "any",       where = "north then east from Pikkon, via IT",
      skills = { "kaio" } },
    { who = "Tien",          race = "any",       where = "Snake Way from Yemma",
      skills = { "dodon", "solar flare" } },
    { who = "Master Roshi",  race = "any",       where = "base of Korin's Tower (eeeeeeeeqeeqnnn)",
      skills = { "kamehameha", "super kamehameha" } },
    { who = "Krillin",       race = "any",       where = "SW side of Capsule Corp",
      skills = { "destructo disk" } },
    { who = "Prince Vegeta", race = "saiyan",    where = "Castle Vegeta, top level, behind closed doors",
      skills = { "bigbang", "gallic gun", "final flash" } },
    { who = "Goku",          race = "saiyan",    where = "Roshi's Island",
      skills = { "sdf" } },
    { who = "Garlic Jr.",    race = "ghetti",    where = "Korin's Tower",
      skills = { "ghetti skills" } },
    { who = "Zarbon",        race = "hydian",    where = "Hydia",
      skills = { "all except sauzer blade" } },
    { who = "Frieza",        race = "hydian",    where = "HFIL",
      skills = { "sauzer blade" } },
    { who = "Frieza",        race = "icer",      where = "HFIL, next to Cell, via Babidi IT",
      skills = { "non-trainer attacks" } },
    { who = "Piccolo",       race = "namek",     where = "Battlescarred Clearing, via Sabre IT",
      skills = { "split-form", "multi-form", "ki-heal" } },
    { who = "Temple Masters", race = "kanassian", where = "Kanassa Temple, via IT Planewalk",
      skills = { "dreamstate", "farstate", "astralstate" } },
}

-- Two skills that no trainer teaches at all: they come off a quest, and the
-- quest is what puts them on the tree in the first place. Worth saying so
-- rather than sending anyone looking for an attendant who has them.
local BY_QUEST = {
    ["instant transmission"] = "Yardrat Temple -- beat Instant Destruction twice. ~5m PL, and it must already be on your alist.",
    ["zanzoken"] = "Sonata -- Gollos in The Root & Mineral, then Kemoya at the Starport. ~500k-1m PL, and it must already be on your slist.",
}

-- The record for the room we are standing in, made if this is the first time.
local function trainerHere()
    local at = here()
    if type(at) ~= "table" then return nil end
    local key = tostring(at.num)
    if type(trainers[key]) ~= "table" then
        trainers[key] = { area = at.area, teaches = {}, refused = {}, at = os.time() }
    end
    -- The area can be filled in later than the first sighting was.
    if trainers[key].area == "" then trainers[key].area = at.area end
    return trainers[key]
end

----------------------------------------------------------------------
-- the records
----------------------------------------------------------------------

-- area + name + power level. Power is part of the identity on purpose: two
-- things sharing a name in one area but not a power level are two things.
-- Until something scans one, its power is unknown and it keys on '?', and the
-- unknown entry is folded into the scanned one the moment a reading arrives.
local function mobKey(area, name, pl)
    local p = "?"
    if safeNum(pl) then p = tostring(safeNum(pl)) end
    return trimBoth(area):lower() .. "|" .. keyOf(name) .. "|" .. p
end

-- A mob with no sightings left is not a mob. The unknown bucket empties as its
-- rooms are read one at a time and has to leave with the last of them --
-- otherwise it sits in the panel forever offering to scan a thing that is not
-- anywhere, which is exactly what it did.
--
-- Swept, rather than only deleted at the point of removal. The delete at the
-- point of removal is right there and real Lua honours it -- the suite passes
-- without this -- and the client kept the entry anyway. Whatever route leaves
-- an empty one behind, this is the invariant that matters and it is cheap.
-- The rooms a record actually has.
--
-- Counted by whitelist, not by pairs(). 'rooms[k] = nil' leaves the key in
-- place here -- same as deleting from any other table -- so a removed room is
-- still yielded by pairs() with a value that is not a number. dropEmpty counted
-- those and saw one room; diag counted only real numbers and saw none. The
-- entry sat between the two answers and never got swept:
--
--   [A captain of Frieza's army] pl=null rooms=0 ()
--   empty entries swept off: 0
--
-- One counter, used by the sweep, the panel and diag alike, so they cannot
-- disagree about whether a mob has anywhere to be.
local function roomList(rec)
    local out = {}
    if type(rec) ~= "table" or type(rec.rooms) ~= "table" then return out end
    for _, vnum in pairs(rec.rooms) do
        local n = safeNum(vnum)
        if n then push(out, n) end
    end
    table.sort(out)
    return out
end

-- Rebuilt, not deleted in place.
--
-- 'mobs[k] = nil' does not remove the key here. Two separate delete sites ran
-- against the same entry and diag showed it still standing afterwards:
--
--   [A captain of Frieza's army] pl=null rooms=0 ()  key=...|?
--
-- Real Lua removes it and the suite passes without any of this, so nothing
-- local could have caught it. A fresh table carrying only what should survive
-- cannot fail that way, and it steps around mutating a table while pairs() is
-- walking it as well.
local function dropEmpty()
    local kept, dropped = {}, 0
    for k, v in pairs(mobs) do
        if type(v) == "table" and rowCount(roomList(v)) > 0 then
            -- and the rooms table is rebuilt too, so a removed room stops being
            -- yielded by pairs() with a value that is no longer a number
            local rooms = {}
            for _, n in ipairs(roomList(v)) do rooms[tostring(n)] = n end
            v.rooms = rooms
            kept[k] = v
        else
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        mobs = kept
        sweptOff = sweptOff + dropped
    end
end

-- Walking past something is not recording it.
--
-- A mob with no power level is a SIGHTING, not a record: a name and a room and
-- nothing anyone wanted to know. Left alone they accumulate one entry per mob
-- per room for every corridor ever walked, and the panel fills with things
-- nobody asked about. So an unread sighting lives exactly as long as you stand
-- in the room with it -- long enough for the [scan] link beside its name to be
-- worth offering, and no longer.
--
-- Every blind room EXCEPT the one we are in now, rather than just the one we
-- left. If the client's room ever lags the 'X is here.' lines by a packet, a
-- sighting lands against the previous vnum, and dropping only that vnum would
-- leave it stranded in a room the player is not in. Keeping only the current
-- room cannot strand anything.
--
-- Anything scanned is untouched: a power level is the whole point of the store.
local function keepBlindOnly(vnum)
    local now = safeNum(vnum)
    for _, v in pairs(mobs) do
        if type(v) == "table" and safeNum(v.pl) == nil then
            local rooms = {}
            for _, r in ipairs(roomList(v)) do
                if now ~= nil and r == now then rooms[tostring(r)] = r end
            end
            v.rooms = rooms
        end
    end

    -- And the offer that went with it. The link is once per mob per room per
    -- session, so a record dropped without its offer means walking back in and
    -- being shown nothing at all -- no figure, because it was never read, and
    -- no link, because it was already offered.
    --
    -- The vnum is read back out with a capture rather than by measuring off the
    -- end of the string: index arithmetic is not reliable here, and a plain
    -- find of '@11216' also matches inside '@112166'.
    local keptOffers = {}
    for k in pairs(offered) do
        if type(k) == "string" then
            local at = safeNum(k:match("@(%d+)$"))
            if at ~= nil and now ~= nil and at == now then keptOffers[k] = true end
        end
    end
    offered = keptOffers

    dropEmpty()
end

-- Newest kept, oldest dropped, by rebuilding. Returns the table to use.
--
-- This deleted keys in place, and 'tbl[k] = nil' does not remove a key in this
-- runtime -- so the loop counted down and finished while every entry it meant
-- to drop was still there, leaving the store permanently over its cap with
-- nothing to show for the work. Same fix as dropEmpty: build the survivors.
local function pruneTo(tbl, cap)
    local keys = {}
    for k, v in pairs(tbl) do
        if type(v) == "table" then push(keys, k) end
    end
    if rowCount(keys) <= cap then return tbl end

    table.sort(keys, function(a, b)
        local aa = safeNum(tbl[a].at) or 0
        local bb = safeNum(tbl[b].at) or 0
        if aa == bb then return tostring(a) < tostring(b) end
        return aa > bb            -- newest first
    end)

    local kept, n = {}, 0
    for _, k in ipairs(keys) do
        n = n + 1
        if n <= cap then kept[k] = tbl[k] end
    end
    return kept
end


local function noteMob(name, spot, pl)
    if type(spot) ~= "table" then return nil end
    local clean = cleanName(name)
    if clean == "" then return nil end

    local key = mobKey(spot.area, clean, pl)
    local rec = nil

    -- A sighting with no reading, in a room that has already been read, is that
    -- same thing -- a reading identifies what stands in ONE room. The same name
    -- in the next room along is still unknown and stays that way, because it
    -- may be a different power entirely.
    --
    -- Checked BEFORE the unknown bucket, not after. The bucket is keyed on name
    -- and area alone, so it matches every sighting of that name anywhere in the
    -- area -- including rooms already read. Looking there first put a read room
    -- straight back into the bucket, and the bucket then outlived the room that
    -- was supposed to empty it.
    if not safeNum(pl) then
        local want = trimBoth(spot.area):lower()
        for _, v in pairs(mobs) do
            if type(v) == "table" and safeNum(v.pl)
                and trimBoth(tostring(v.area or "")):lower() == want
                and keyOf(v.name) == keyOf(clean)
                and type(v.rooms) == "table"
                and v.rooms[tostring(spot.num)] ~= nil then
                rec = v
                break
            end
        end
    end

    if type(rec) ~= "table" then rec = mobs[key] end
    if type(rec) ~= "table" then
        rec = { name = clean, area = spot.area, pl = safeNum(pl), rooms = {}, at = 0 }
    end
    if rec.pl == nil then rec.pl = safeNum(pl) end
    rec.at = os.time()

    -- rooms are one-to-many, keyed by vnum so a second visit is not a second row
    if type(rec.rooms) ~= "table" then rec.rooms = {} end
    if safeNum(rec.rooms[tostring(spot.num)]) == nil then
        if rowCount(roomList(rec)) < MAX_ROOMS then
            rec.rooms[tostring(spot.num)] = spot.num
        end
    end

    -- Filed under the key its own power level gives it, which is not the key
    -- that was looked up when a sighting landed in a room already read.
    mobs[mobKey(spot.area, clean, rec.pl)] = rec

    -- A reading identifies the thing in THIS room and nothing else.
    --
    -- 'An elite warrior' stands in a dozen rooms of The Ginyu Base and they are
    -- not all the same power, so scanning one says nothing about the others.
    -- Only the room that was scanned leaves the unknown bucket; the rest stay
    -- there waiting to be read. The bucket goes when its last room does.
    if safeNum(pl) then
        local blindKey = mobKey(spot.area, clean, nil)
        local blind = mobs[blindKey]
        if type(blind) == "table" and type(blind.rooms) == "table" then
            -- The room goes; the entry itself is left to dropEmpty below, which
            -- rebuilds rather than deleting. 'mobs[blindKey] = nil' was here
            -- and did not remove the key.
            blind.rooms[tostring(spot.num)] = nil
        end
    end

    dropEmpty()
    mobs = pruneTo(mobs, MAX_MOBS)
    return rec
end

local function itemRec(name)
    local clean = cleanName(name)
    if clean == "" then return nil end
    local key = keyOf(clean)
    local rec = items[key]
    if type(rec) ~= "table" then
        rec = { name = clean, src = {}, at = 0 }
    end
    rec.name = clean
    rec.at = os.time()
    items[key] = rec
    items = pruneTo(items, MAX_ITEMS)
    return rec
end

-- Where a thing came from: the area and room it dropped in, and what dropped
-- it. Recorded per source rather than as one field, because the same item comes
-- off more than one mob.
local function noteSource(name, mobName, spot)
    local rec = itemRec(name)
    if type(rec) ~= "table" then return end
    if type(rec.src) ~= "table" then rec.src = {} end

    local area, roomNum = "", nil
    if type(spot) == "table" then
        area = spot.area
        roomNum = spot.num
    end
    local who = cleanName(mobName)

    for _, s in ipairs(rec.src) do
        if type(s) == "table" and s.mob == who and s.room == roomNum then return end
    end
    if rowCount(rec.src) >= MAX_SRC then return end
    push(rec.src, { mob = who, area = area, room = roomNum })
end

----------------------------------------------------------------------
-- reading the MUD
----------------------------------------------------------------------

-- 'analyze' answers in two shapes. The one off your own inventory:
--
--   Object: Kaioshin's Boots (Equipped)
--   Pl Req: 100
--   Special properties: bless deathrot groundrot noauction nocontest
--   Item's wear location: feet
--   Weight: 1
--   Affects powerlevel gains by: 1.750000%
--   Layers: Not Layerable
--   Armor rating is 1500/1500.
--   Affects strength by 25. (25)
--
-- and the one the auction house prints, which names the item in quotes and
-- rolls three figures into a sentence:
--
--   Object 'Class I Battle Armor' is an armor
--   Its weight is 15, value is 15, and powerlevel is 1,000.
--
-- Every field is read on its own line and stored on its own. One pattern
-- carrying two captures is the shape that hid every stat in Portrait's score
-- block for a month.
local function feedAna(clean)
    local opened = capOf(clean, "^Object:%s*(.+)$")
    if opened == nil then
        local quoted = capOf(clean, "^Object%s+'([^']+)'%s+is%s+")
        if quoted ~= nil then opened = quoted end
    end
    if opened ~= nil then
        ana.on = true
        ana.n = 0
        ana.name = cleanName(opened)
        ana.rec = itemRec(ana.name)
        anaFresh = true
        -- A second analyze of the same thing replaces what the first said
        -- rather than stacking on top of it.
        if type(ana.rec) == "table" then
            ana.rec.raw = {}
            ana.rec.fields = {}
        end
        sawItems = sawItems + 1
        if type(ana.rec) == "table" then
            local kind = capOf(clean, "^Object%s+'[^']+'%s+is%s+an?%s+(%S+)")
            if kind ~= nil then ana.rec.kind = kind end
        end
        return true
    end

    if not ana.on or type(ana.rec) ~= "table" then return false end

    ana.n = ana.n + 1
    -- The block runs until the prompt. A cap behind that, because a block that
    -- never closes would swallow the rest of the session.
    if ana.n > 40 then
        ana.on = false
        return false
    end

    local rec = ana.rec
    local v = nil

    v = capOf(clean, "^Pl Req:%s*(%S+)")
    if v ~= nil then rec.plReq = safeNum(v) end

    v = capOf(clean, "^Special properties:%s*(.+)$")
    if v ~= nil then rec.props = trimBoth(v) end

    v = capOf(clean, "^Item's wear location:%s*(%S+)")
    if v ~= nil then rec.wear = v end

    v = capOf(clean, "^Weight:%s*(%S+)")
    if v ~= nil then rec.weight = safeNum(v) end

    v = capOf(clean, "^Layers:%s*(.+)$")
    if v ~= nil then rec.layers = trimBoth(v) end

    v = capOf(clean, "^Armor rating is%s*(%S+)")
    if v ~= nil then rec.armor = trimBoth(v):gsub("%.$", "") end

    v = capOf(clean, "^Affects powerlevel gains by:%s*(%S+)")
    if v ~= nil then rec.gains = trimBoth(v) end

    -- 'Its weight is 15, value is 15, and powerlevel is 1,000.' -- three
    -- figures in one sentence, read as three separate matches.
    v = capOf(clean, "Its weight is%s*([%d,]+)")
    if v ~= nil then rec.weight = safeNum(v) end
    v = capOf(clean, "value is%s*([%d,]+)")
    if v ~= nil then rec.value = safeNum(v) end
    v = capOf(clean, "powerlevel is%s*([%d,]+)")
    if v ~= nil then rec.plReq = safeNum(v) end

    -- 'Affects strength by 25. (25)' and 'Affects strength by 25' both appear.
    -- The stat name is not in a character class: %a inside one stops matching
    -- letters here.
    local stat = capOf(clean, "^Affects%s+(%S+)%s+by%s")
    local amt = capOf(clean, "^Affects%s+%S+%s+by%s+([%-%d]+)")
    if stat ~= nil and amt ~= nil and stat ~= "powerlevel" then
        if type(rec.affects) ~= "table" then rec.affects = {} end
        rec.affects[stat:lower()] = safeNum(amt)
    end

    -- EVERY 'Label: value' line, whatever the label is.
    --
    -- The named reads above exist so a field can be sorted and filtered on. This
    -- exists so nothing is thrown away: a label this does not know about is
    -- still a label, and the MUD adds them. Read as two single-capture matches
    -- rather than one pattern with two captures -- a multi-capture miss hands
    -- back undefined for both and undefined is truthy.
    local label = capOf(clean, "^([^:]+):")
    local value = capOf(clean, "^[^:]+:%s*(.+)$")
    if label ~= nil and value ~= nil then
        if type(rec.fields) ~= "table" then rec.fields = {} end
        local k = trimBoth(label):lower()
        -- 'Object' is the name and already the record's own; the rest go in
        local v = trimBoth(value)
        if k ~= "" and k ~= "object" and v ~= "undefined" then rec.fields[k] = v end
    end

    -- And the block verbatim, in the order it arrived, for anything that is not
    -- 'Label: value' at all -- 'Armor rating is 1500/1500.' and every 'Affects'
    -- line are exactly that. A record you cannot read back in full is a record
    -- that quietly loses whatever nobody thought to parse.
    -- 'Label: undefined' is a value that did not survive the crossing, not
    -- something the MUD said. It is the one line worth dropping from a block
    -- that is otherwise kept exactly as it arrived.
    if type(rec.raw) ~= "table" then rec.raw = {} end
    if rowCount(rec.raw) < 40 and capOf(clean, ":%s*undefined%s*$") == nil then
        push(rec.raw, clean)
    end

    return false
end

local function feedScan(clean)
    local who = capOf(clean, "^A yellow outline forms around%s+(.+)%s+in your vision%.$")
    if who ~= nil then
        -- one down; the next goes out on the following tick
        if bulk.on then bulk.at = 0 end
        scan.who = cleanName(who)
        scan.at = os.time()
        -- Whatever word we last offered got an outline, so it is the right one
        -- for this mob. Remembered against the name, so the next offer uses it
        -- instead of guessing again.
        if tried.word ~= "" and keyOf(tried.name) == keyOf(scan.who) then
            scanKw[keyOf(scan.who)] = tried.word
            tried.word = ""
        end
        return true
    end

    -- "They aren't here." after a scan we offered means the WORD was wrong,
    -- not that the mob left -- we printed its name a moment ago. Try the next
    -- candidate. 'A seasoned soldier' is the case this exists for: it answers
    -- to 'soldier' and not to 'seasoned', where nine other mobs in the same
    -- transcript answer to their first word.
    --
    -- Bounded: only when we offered one, only within the window a scan is
    -- allowed to answer in, and only forward through the candidate list.
    if clean == "They aren't here." and tried.word ~= "" and tried.idx > 0
        and os.time() - tried.at <= SCAN_WAIT then
        local words = keywords(tried.name)
        local nxt = words[tried.idx + 1]
        tried.idx = tried.idx + 1
        if type(nxt) == "string" and nxt ~= "" then
            tried.word = nxt
            tried.at = os.time()
            local ok = pcall(function() send("scan " .. nxt) end)
            if ok then
                print(TAG .. "'" .. tried.name .. "' does not answer to that; "
                    .. "trying '" .. nxt .. "'.")
            end
        else
            tried.word = ""
        end
        return true
    end

    if scan.who == "" then return false end
    if os.time() - scan.at > SCAN_WAIT then
        -- A scan does not always answer -- 'scan eng' printed the outline and
        -- no reading at all -- so the target expires rather than waiting for
        -- one that is not coming.
        scan.who = ""
        return false
    end

    -- Off the line first, exactly the way the scouter reads it: a plain find
    -- for the arrow, then everything past its '>'. Plain find because '`--->'
    -- is four pattern specials in a row and a translated pattern is the last
    -- thing this should depend on.
    --
    -- Whether the line even arrives is the open question. The scouter gags it
    -- by returning false from its own onLine, and a line one plugin discards
    -- that way may not reach the next. If it does arrive this fires and the
    -- published value below is never needed; if it does not, that one covers it.
    if clean:find("`--->", 1, true) then
        local tail = clean:match(">%s*(.*)$")
        local pl = nil
        if type(tail) == "string" then pl = safeNum((tail:gsub("[^%d]", ""))) end
        if pl then
            local spot = here()
            if spot then noteMob(scan.who, spot, pl) end
            scan.who = ""
            return true
        end
    end

    -- And the reading the scouter published, for when the line never came.
    --
    -- The arrow line is GAGGED: scouter's own onLine returns false for it so
    -- the art never reaches the scroll, and a line one plugin discards that way
    -- does not reach the next plugin either. Reading it here was never going to
    -- work, which is exactly what the panel showed -- the outline arrived, the
    -- reading never did.
    --
    -- So scouter publishes what it parsed and this reads it. Split on '~': a
    -- bare bar is alternation once a pattern is translated.
    local raw = mapCall("getMapUserData", "scouter.scan")
    if type(raw) ~= "string" or raw == "" then return false end

    local parts = {}
    for chunk in raw:gmatch("[^~]+") do push(parts, chunk) end
    -- 'said' rather than a second 'who'. This function already has one, and two
    -- 'local who' in one function is ordinary Lua shadowing that becomes two
    -- 'let who' in one JavaScript scope -- which is illegal, so NOTHING in the
    -- file loads:
    --   loadPlugin(): Cannot declare a let variable twice: 'who'
    local said, power, stamp = parts[1], parts[2], safeNum(parts[3])
    if type(said) ~= "string" or type(power) ~= "string" then return false end
    -- Only a reading taken since this scan started counts, or the last one
    -- would be credited to every target after it.
    if not stamp or stamp < scan.at then return false end

    local pl = safeNum(power)
    if not pl then return false end
    if keyOf(said) ~= keyOf(scan.who) then return false end

    local spot = here()
    if spot then
        local rec = noteMob(scan.who, spot, pl)
        if type(rec) == "table" then announce("mob", rec) end
    end
    scan.who = ""
    return true
end

-- The link is offered once per mob per session. Dropping the record has to drop
-- that too, or nothing would ever be offered again.
local function forgetOffers()
    for k in pairs(offered) do offered[k] = nil end
end

-- One clickable word inside an otherwise plain line.
--
-- hyperlink() would make the WHOLE line a link, and hyperlinkInline -- which
-- the guide calls the no-newline variant -- ended the line here anyway, so
-- composing text and label from two calls put the label on a row of its own.
--
-- The guide says what a link actually is: "these emit a standard OSC 8
-- hyperlink through the same path as utilprint". So the escape goes into the
-- utilprint string directly and only the label carries it. Safe schemes are
-- listed there too -- 'send:' is one, and it is the one that runs a command.
--
--   ESC ] 8 ; ; <uri> ESC \   <label>   ESC ] 8 ; ; ESC \
local function linkTo(label, command)
    return "\27]8;;send:" .. command .. "\27\\" .. label .. "\27]8;;\27\\"
end

-- The MUD's own colours, rebuilt as '$' codes so utilprint can print them back.
--
-- parseAnsiText hands back the runs of a line with the colour each was printed
-- in, and '$X' takes six hex digits with no '#'. Rebuilding beats passing the
-- raw line through: the result is something the documented printers understand,
-- and the line keeps the colours it arrived in rather than turning into the
-- plugin's print colour.
--
-- An array crossing the boundary is not reliably 1-indexed, so this starts
-- wherever the first entry actually is.
local function recolour(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local segs = nil
    local ok = pcall(function() segs = parseAnsiText(raw) end)
    if not ok or type(segs) ~= "table" then return nil end

    local i = 1
    if type(segs[0]) == "table" then i = 0 end
    local out, n = {}, 0
    while type(segs[i]) == "table" do
        local seg = segs[i]
        if type(seg.text) == "string" and seg.text ~= "" then
            local col = seg.color
            if type(col) == "string" and #col == 7 and col:sub(1, 1) == "#" then
                push(out, "$X" .. col:sub(2))
            end
            push(out, seg.text)
            n = n + 1
        end
        i = i + 1
    end
    if n == 0 then return nil end
    return table.concat(out)
end

-- 'An elite warrior is here.' -- 454 of them in two days of transcript, one
-- shape. The trailing '+You sense a laughable power.' line is the game's own
-- hint and carries no figure, so it is ignored.
local function feedRoom(clean, raw)
    local who = capOf(clean, "^(.+) is here%.$")
    if who == nil then return false end
    -- a player standing there is not a mob, and neither is a corpse
    if clean:find("corpse", 1, true) then return false end

    -- The room is not always known the instant you walk in. here() needs BOTH
    -- getPlayerRoom and getMapRoom to answer, and while a move is still
    -- settling either can decline -- so this used to return, the line printed
    -- plain, and the [scan] link only turned up once you typed 'look'. That is
    -- exactly how it was reported, and it is not the room's emotes: those
    -- arrive after the line and cannot reach back.
    --
    -- The RECORD needs a room; there is nowhere to file a sighting without
    -- one. The OFFER does not. So a mob seen before the map has caught up
    -- still gets its link, and the sighting is picked up on the next line that
    -- knows where it is.
    local spot = here()
    local rec = nil
    if spot then
        sawMobs = sawMobs + 1
        rec = noteMob(who, spot, nil)
    end

    -- The line itself, with a scan link on the end of it.
    --
    -- The original is dropped and rewritten, because there is no documented way
    -- to print plain text without a newline -- hyperlinkInline is the only
    -- no-newline primitive there is. So the whole line is composed from links,
    -- which makes the mob's own name clickable too. Clicking either scans it.
    --
    -- Keyed on the ROOM. The same name in the next room along may be a
    -- different power, so each room is worth its own reading and its own offer.
    if not linkOn then return true end

    -- Known: put the figure on the line. Every time, not once -- the whole
    -- point is seeing what you are about to walk into. utilprint is plain
    -- output that honours the colour codes, so no link is involved at all.
    -- The line as the MUD coloured it, with the figure on the end. '$n' resets
    -- -- '$x' does NOT, it is '$x###' for xterm-256, and written bare it came
    -- out as the literal text '$x' on the end of every line.
    local shown = recolour(raw)
    if shown == nil then shown = clean end

    local known = nil
    if type(rec) == "table" then known = safeNum(rec.pl) end
    if known then
        local ok = pcall(function()
            utilprint(shown .. "  $Y(" .. commas(known) .. ")$n")
        end)
        if ok then dropLine = true end
        return true
    end

    -- Unknown: the same line with something to click on the end of it. Once per
    -- room -- the same name next door may be a different power, and that room
    -- is worth its own reading.
    -- Named from the record when there is one, from the line when there is
    -- not. Same cleaning either way, so the two agree on the keyword.
    local name = cleanName(who)
    if type(rec) == "table" and type(rec.name) == "string" then name = rec.name end
    if name == "" then return true end

    -- '?' for a room that has not resolved. It means the offer made on the way
    -- in and the one made after a 'look' are different keys, so the link can
    -- appear twice for one mob -- which is the right way round: showing it
    -- twice costs a line, showing it never costs the reading.
    local at = "?"
    local area = ""
    if spot then
        at = tostring(spot.num)
        area = spot.area
    end
    local key = mobKey(area, name, nil) .. "@" .. at
    if offered[key] then return true end

    -- A word that has worked for this mob before beats the guess.
    local word = scanKw[keyOf(name)]
    local idx = 0
    if type(word) ~= "string" or word == "" then
        local words = keywords(name)
        if #words == 0 then return true end
        word = words[1]
        idx = 1
    end
    if word == "" then return true end
    offered[key] = true
    tried.name, tried.word, tried.idx, tried.at = name, word, idx, os.time()

    -- The line stays plain and only the label is clickable, in the same place
    -- the figure sits for something already read.
    local ok = pcall(function()
        utilprint(shown .. "  $Y" .. linkTo("[scan]", "scan " .. word) .. "$n")
    end)
    -- Only drop the original once the replacement is actually on the screen. A
    -- failed rewrite that also ate the line would lose the mob from the scroll.
    if ok then dropLine = true end
    return true
end

-- Whoever is standing here, if exactly one thing is. A shop is a mob in a room
-- -- 'Arman is here.' above the stock list -- and naming it beats recording
-- every purchase against an anonymous seller. With two mobs in the room there
-- is no telling which one sells, so it stays anonymous.
--
-- 'a shop' rather than '(shop)': cleanName strips a trailing bracketed group,
-- which is the whole of '(shop)', so it arrived at the tree as an empty name.
local function keeperHere(spot)
    if type(spot) ~= "table" then return "a shop" end
    local found, seen = nil, 0
    local want = trimBoth(spot.area):lower()
    for _, v in pairs(mobs) do
        if type(v) == "table"
            and trimBoth(tostring(v.area or "")):lower() == want
            and type(v.rooms) == "table"
            and safeNum(v.rooms[tostring(spot.num)]) then
            found = v.name
            seen = seen + 1
        end
    end
    if seen == 1 and type(found) == "string" then return found end
    return "a shop"
end

-- A shop's stock list. Verbatim, and the header rows go with it:
--
--   [ #   PL Needed        Price] Item
--   [--+-------------+----------] ----
--   [ 1|  100,000,000|    25,000] Class IV Battle Armor.
--   [ 4|        1,000|       500] Class I Battle Armor.
--
-- Worth more than the purchase line: it records everything the shop sells
-- without buying any of it.
--
-- '%|' and not '|'. A bare bar is alternation once the pattern is translated,
-- and every field here is separated by one. Each value is its own match, since
-- a multi-capture miss hands back undefined for all of them at once.
local function feedShop(clean, spot)
    if clean:sub(1, 1) ~= "[" then return false end
    local idx = capOf(clean, "^%[%s*(%d+)%s*%|")
    if idx == nil then return false end

    local nm = capOf(clean, "%]%s*(.+)%.%s*$")
    if nm == nil then nm = capOf(clean, "%]%s*(.+)$") end
    if nm == nil then return false end

    local rec = itemRec(nm)
    if type(rec) ~= "table" then return false end

    local need = capOf(clean, "^%[%s*%d+%s*%|%s*([%d,]+)%s*%|")
    if need ~= nil then rec.plReq = safeNum(need) end
    local cost = capOf(clean, "^%[%s*%d+%s*%|%s*[%d,]+%s*%|%s*([%d,]+)%s*%]")
    if cost ~= nil then rec.price = safeNum(cost) end

    noteSource(nm, keeperHere(spot), spot)
    sawItems = sawItems + 1
    return true
end

-- 'Auction: [TCG] Thirteen Booster Pack [DBI] sold to Zodion for 25,000.'
--
-- The settled price, which is the only auction line worth keeping: the bids and
-- the going-once calls are noise once something has actually changed hands.
-- What it buys is a price history per item -- what players really pay, rather
-- than what a shopkeeper asks.
--
-- Three separate matches, one per value, per the house rule. A nested
-- multi-capture hands back undefined on a miss and undefined is truthy.
local MAX_SALES = 40

local function feedAuction(clean)
    if not clean:find(" sold to ", 1, true) then return false end
    if not clean:find("Auction:", 1, true) then return false end

    -- Anchored at the end rather than the start: a colour code eaten upstream
    -- can leave junk in front of 'Auction:' and there is no escape left to
    -- strip. The tail is the part that is reliably intact.
    local nm = capOf(clean, "Auction: (.+) sold to %S+ for [%d,]+%.$")
    if nm == nil then return false end
    local who = capOf(clean, " sold to (%S+) for [%d,]+%.$")
    local paid = safeNum(capOf(clean, " for ([%d,]+)%.$"))
    if paid == nil then return false end

    local rec = itemRec(nm)
    if type(rec) ~= "table" then return false end
    if type(rec.sales) ~= "table" then rec.sales = {} end

    -- The same line twice is two installed copies or a repaint, not two sales.
    -- Nobody sells the same thing to the same player for the same money inside
    -- a minute.
    local now = os.time()
    local n = rowCount(rec.sales)
    if n > 0 then
        local last = rec.sales[n]
        if type(last) == "table" and last.price == paid and last.buyer == who
            and safeNum(last.at) and now - last.at < 60 then
            return false
        end
    end

    push(rec.sales, { price = paid, buyer = who, at = now })

    -- Oldest off the front once it is full. Rebuilt rather than
    -- table.remove'd: # does not follow a remove in this runtime.
    if rowCount(rec.sales) > MAX_SALES then
        local keep = {}
        local drop = rowCount(rec.sales) - MAX_SALES
        local seen = 0
        for _, sale in ipairs(rec.sales) do
            seen = seen + 1
            if seen > drop then push(keep, sale) end
        end
        rec.sales = keep
    end

    sawSales = sawSales + 1
    announce("item", rec)
    return true
end

-- count, low, high, mean and the most recent, off whatever history there is.
-- Nil when there is none, so a caller can skip the whole section.
local function saleStats(rec)
    if type(rec) ~= "table" or type(rec.sales) ~= "table" then return nil end
    local n, sum, low, high, last = 0, 0, nil, nil, nil
    for _, sale in ipairs(rec.sales) do
        local paid = nil
        if type(sale) == "table" then paid = safeNum(sale.price) end
        if paid then
            n = n + 1
            sum = sum + paid
            if low == nil or paid < low then low = paid end
            if high == nil or paid > high then high = paid end
            last = sale
        end
    end
    if n == 0 then return nil end
    return { count = n, min = low, max = high,
             avg = math.floor(sum / n + 0.5), last = last }
end

-- 'You get Spiked Combat Shoulderplates from the corpse of An elite warrior''
-- names both halves. Money is not an item and your own corpse is not a mob.
local function feedLoot(clean)
    local what = capOf(clean, "^You get (.+) from the corpse of ")
    if what == nil then return false end
    if capOf(clean, "^You get [%d,]+ zeni from") ~= nil then return false end

    local who = capOf(clean, "^You get .+ from the corpse of (.+)$")
    if who == nil then return false end
    noteSource(what, who, here())
    return true
end

----------------------------------------------------------------------
-- storage
----------------------------------------------------------------------

-- Written and FLUSHED, every time, no throttle.
--
-- saveTable's write is debounced 50ms and lands asynchronously after that, so a
-- client killed outright -- alt+F4 -- loses whatever had not made it out.
-- saveState() forces it now.
--
-- This was throttled to one flush every few seconds and that is exactly the
-- window that loses data. saveAll is only called when something was actually
-- recorded, so a flush per call is a flush per real change, which is the rate
-- it should be.
local writes = 0

-- The GLOBAL store, not the per-character one.
--
-- The default scope goes to the world file when one is loaded and falls back to
-- localStorage when none is; global goes through the storage engine -- real
-- files on desktop -- independent of any open world. Two restarts lost
-- everything out of the default one.
--
-- It also suits the data. What lives in a room and what a shop sells is the
-- same for every character on this MUD, so a codex kept per character is the
-- same facts learned over again on each alt.
--
-- The name is prefixed because the global namespace is shared by every plugin
-- and an unprefixed 'codexdata' is exactly the sort of thing another one would
-- also pick.
local STORE = "dbi-codex-data"

local function saveAll()
    local outMobs, outItems = mobs, items

    -- If the load came up empty, this session does not know what is in the
    -- store -- so it writes ALONGSIDE it rather than over it. Portrait lost a
    -- night to the other behaviour: read nothing at startup, then save that
    -- nothing as the whole table.
    --
    -- Only in that state. A session that DID load is authoritative, and its
    -- deletions have to stick: this plugin sweeps unread sightings and prunes
    -- to a cap, and a merge that kept every record on disk would quietly undo
    -- both on the next write.
    if not loadedOk then
        local disk = nil
        pcall(function() disk = loadTable(STORE, "global") end)
        if type(disk) == "table" then
            outMobs, outItems = {}, {}
            for _, pair in ipairs({ { disk.mobs, outMobs }, { disk.items, outItems } }) do
                if type(pair[1]) == "table" then
                    for k, v in pairs(pair[1]) do
                        if type(k) == "string" and type(v) == "table" then pair[2][k] = v end
                    end
                end
            end
            for k, v in pairs(mobs) do
                if type(k) == "string" and type(v) == "table" then outMobs[k] = v end
            end
            for k, v in pairs(items) do
                if type(k) == "string" and type(v) == "table" then outItems[k] = v end
            end
        end
    end

    local ok, err = pcall(function()
        -- scanKw goes with them. A confirmed keyword is learned once, from a
        -- scan that may not come round again for an hour, which is the same
        -- reason everything else here saves on every change.
        saveTable(STORE, { mobs = outMobs, items = outItems, view = view,
                           kw = scanKw, trainers = trainers }, "global")
    end)
    if not ok then
        lastError = "save: " .. tostring(err)
        print(TAG .. "not saved: " .. tostring(err))
        return
    end
    writes = writes + 1
    pcall(function() saveState() end)
end

-- Stored data is still data. A table written by an older build, or edited by
-- hand, has never been through any of the readers above.
local function loadAll()
    local p = nil
    pcall(function() p = loadTable(STORE, "global") end)

    -- Anything written by a build that used the per-character store, brought
    -- over rather than abandoned. Reads and writes must use the same scope they
    -- were made with, so the old name is read with no scope at all.
    if type(p) ~= "table" then
        pcall(function() p = loadTable("codexdata") end)
        if type(p) == "table" then loadedFrom = "the old per-character store" end
    else
        loadedFrom = "the global store"
    end
    if type(p) ~= "table" then return end
    loadedOk = true

    if type(p.trainers) == "table" then
        for k, v in pairs(p.trainers) do
            if type(k) == "string" and type(v) == "table" then
                if type(v.teaches) ~= "table" then v.teaches = {} end
                if type(v.refused) ~= "table" then v.refused = {} end
                if type(v.area) ~= "string" then v.area = "" end
                trainers[k] = v
            end
        end
    end

    if type(p.mobs) == "table" then
        for k, v in pairs(p.mobs) do
            if type(k) == "string" and type(v) == "table" and type(v.name) == "string" then
                if type(v.rooms) ~= "table" then v.rooms = {} end
                mobs[k] = v
            end
        end
    end
    if type(p.items) == "table" then
        for k, v in pairs(p.items) do
            if type(k) == "string" and type(v) == "table" and type(v.name) == "string" then
                if type(v.src) ~= "table" then v.src = {} end
                items[k] = v
            end
        end
    end
    if p.view == "items" then view = "items" end
    if type(p.kw) == "table" then
        for name, word in pairs(p.kw) do
            if type(name) == "string" and type(word) == "string" and word ~= "" then
                scanKw[name] = word
            end
        end
    end

    -- and heal a store that already carries one
    dropEmpty()
end

----------------------------------------------------------------------
-- the panel
----------------------------------------------------------------------

local function css()
    local base = math.max(9, math.floor(termSize * 0.9))
    local t = {}
    local function add(x) t[#t + 1] = x end
    add("<style>")
    add(".dbi-dex{position:relative;height:100%;box-sizing:border-box;display:flex;")
    add("flex-direction:column;container-type:inline-size;overflow:hidden;")
    add("background:" .. PANEL_BG .. ";color:" .. INK .. ";")
    add("font-family:Fira Code,ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;")
    add("font-size:" .. base .. "px;}")
    add(".dbi-dex .bar{flex:0 0 auto;display:flex;align-items:center;gap:6px;")
    add("padding:6px 10px;border-bottom:1px solid " .. RULE .. ";font-weight:600;")
    add("letter-spacing:0.18em;text-transform:uppercase;color:" .. GOLD .. ";}")
    add(".dbi-dex .sp{flex:1 1 auto;}")
    add(".dbi-dex .tb{flex:0 0 auto;padding:2px 6px;border-radius:2px;cursor:pointer;")
    add("user-select:none;border:1px solid " .. RULE .. ";color:" .. INK_DIM .. ";")
    add("text-transform:uppercase;letter-spacing:0.1em;}")
    -- Hover and selected must not look the same. They shared one rule, so a tab
    -- under the cursor was indistinguishable from the tab you were on and the
    -- panel appeared to have two selected at once. Hover brightens the text;
    -- selected also fills.
    add(".dbi-dex .tb:hover{color:" .. GOLD .. ";}")
    add(".dbi-dex .tb.on{color:" .. GOLD .. ";border-color:" .. GOLD .. ";")
    add("background:rgba(232,180,92,0.14);}")
    add(".dbi-dex .body{flex:1 1 auto;min-height:0;overflow-y:auto;padding:6px 8px;}")
    add(".dbi-dex .row{display:flex;align-items:baseline;gap:8px;padding:2px 0;")
    add("border-bottom:1px solid rgba(255,255,255,0.05);}")
    add(".dbi-dex .nm{flex:1 1 auto;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}")
    add(".dbi-dex .pl{flex:0 0 auto;color:" .. GOOD .. ";}")
    add(".dbi-dex .pl.none{color:" .. UNKNOWN .. ";}")
    add(".dbi-dex .sub{padding:0 0 4px 14px;color:" .. INK_DIM .. ";")
    add("border-left:1px solid " .. RULE .. ";margin-left:4px;}")
    add(".dbi-dex .go{flex:0 0 auto;padding:1px 5px;border-radius:2px;cursor:pointer;")
    add("user-select:none;border:1px solid " .. UNKNOWN .. ";color:" .. UNKNOWN .. ";}")
    add(".dbi-dex .go:hover{background:rgba(255,154,60,0.15);}")
    add(".dbi-dex .idle{padding:14px 10px;color:" .. INK_DIM .. ";line-height:1.7;}")
    add(".dbi-dex .idle b{color:" .. GOLD .. ";}")
    add(".dbi-dex .hint{padding:2px 8px;color:" .. INK_DIM .. ";border-bottom:1px solid " .. RULE .. ";}")
    add(".dbi-dex .hint b{color:" .. GOLD .. ";font-weight:600;}")
    -- the detail screen
    add(".dbi-dex .pick{cursor:pointer;}")
    add(".dbi-dex .pick:hover{background:rgba(255,255,255,0.05);}")
    add(".dbi-dex .head{display:flex;align-items:center;gap:8px;")
    add("padding:0 0 6px 0;border-bottom:1px solid " .. RULE .. ";margin-bottom:6px;}")
    add(".dbi-dex .dn{flex:1 1 auto;color:" .. GOLD .. ";font-weight:600;")
    add("overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}")
    add(".dbi-dex .dk{flex:0 0 45%;color:" .. INK_DIM .. ";}")
    add(".dbi-dex .dv{flex:1 1 auto;text-align:right;overflow-wrap:anywhere;}")
    add(".dbi-dex .sec{margin:8px 0 3px;font-size:90%;letter-spacing:0.14em;")
    add("text-transform:uppercase;color:" .. GOLD .. ";")
    add("border-bottom:1px solid " .. RULE .. ";padding-bottom:2px;}")
    add(".dbi-dex .rawln{color:" .. INK_DIM .. ";font-size:92%;")
    add("overflow-wrap:anywhere;padding:1px 0;}")
    -- the found-on tree: area, then what dropped it
    add(".dbi-dex .t1{padding:3px 0 1px 6px;color:" .. INK .. ";}")
    add(".dbi-dex .t2{padding:0 0 1px 22px;color:" .. INK_DIM .. ";")
    add("border-left:1px solid " .. RULE .. ";margin-left:10px;")
    add("overflow-wrap:anywhere;}")
    add(".dbi-dex .sec .tb{float:right;text-transform:none;letter-spacing:0;}")
    -- the search bar
    add(".dbi-dex .find{flex:0 0 auto;display:flex;align-items:center;gap:5px;")
    add("padding:5px 8px;border-bottom:1px solid " .. RULE .. ";}")
    add(".dbi-dex .find input{flex:1 1 auto;min-width:0;background:rgba(0,0,0,0.35);")
    add("border:1px solid " .. RULE .. ";border-radius:3px;color:" .. INK .. ";")
    add("padding:3px 6px;font:inherit;outline:none;}")
    add(".dbi-dex .find input:focus{border-color:" .. GOLD .. ";}")
    -- the scope switch reads as set without being a tab
    add(".dbi-dex .tb.sw{color:" .. GOLD .. ";border-color:" .. GOLD .. ";}")
    -- the pager, pinned under the list rather than scrolling with it
    add(".dbi-dex .pager{flex:0 0 auto;display:flex;align-items:center;gap:6px;")
    add("justify-content:center;padding:4px 8px;border-top:1px solid " .. RULE .. ";}")
    add(".dbi-dex .pn{color:" .. INK_DIM .. ";}")
    -- a room you can walk to
    add(".dbi-dex .go2{display:inline-block;margin:0 3px 2px 0;padding:0 5px;")
    add("border-radius:2px;cursor:pointer;user-select:none;")
    add("border:1px solid " .. RULE .. ";color:" .. INK_DIM .. ";}")
    add(".dbi-dex .go2:hover{color:" .. GOOD .. ";border-color:" .. GOOD .. ";}")
    add("</style>")
    return table.concat(t)
end

local function matches(rec)
    if filter == "" then
        -- No search: mobs are the ones where you are standing. Items have no
        -- area of their own, so they are never narrowed this way.
        if not hereOnly then return true end
        if type(rec.area) ~= "string" then return true end
        local spot = here()
        if type(spot) ~= "table" or spot.area == "" then return true end
        return trimBoth(rec.area):lower() == trimBoth(spot.area):lower()
    end
    local hay = tostring(rec.name or ""):lower()
    if hay:find(filter, 1, true) then return true end
    local area = tostring(rec.area or ""):lower()
    if area:find(filter, 1, true) then return true end

    -- Everything analyze said, label and value alike. 'dbdex find bless' finds
    -- what is blessed; 'dbdex find feet' finds what goes on them.
    for k, v in pairs(rec.fields or {}) do
        if tostring(k):lower():find(filter, 1, true) then return true end
        if tostring(v):lower():find(filter, 1, true) then return true end
    end
    for _, line in ipairs(rec.raw or {}) do
        if tostring(line):lower():find(filter, 1, true) then return true end
    end
    return false
end

-- Sorted by name so the list does not reshuffle between renders. pairs() order
-- is not stable and a list that jumps under the cursor is unusable.
local function sortedKeys(tbl)
    local out = {}
    for k, v in pairs(tbl) do
        if type(v) == "table" and matches(v) then push(out, k) end
    end
    table.sort(out, function(a, b)
        local ra, rb = tbl[a], tbl[b]
        local na = tostring(ra.name or ""):lower()
        local nb = tostring(rb.name or ""):lower()
        if na == nb then return tostring(a) < tostring(b) end
        return na < nb
    end)
    return out
end

-- The slice of a sorted list that fits, and the strip that says so. Returns the
-- keys to draw; the pager is added by the caller after the rows.
local pageKeys = nil
local pageBar = ""

pageKeys = function(keys)
    local total = rowCount(keys)
    local per = perPage()
    local pages = math.floor((total + per - 1) / per)
    if pages < 1 then pages = 1 end
    if page > pages then page = pages end
    if page < 1 then page = 1 end

    if pages == 1 then
        pageBar = ""
        return keys
    end

    local out = {}
    local from = (page - 1) * per + 1
    for i = from, from + per - 1 do
        if keys[i] ~= nil then push(out, keys[i]) end
    end

    local back, fwd = "", ""
    if page > 1 then
        back = '<span class="tb" data-mud-action="page" data-mud-data="prev">prev</span>'
    end
    if page < pages then
        fwd = '<span class="tb" data-mud-action="page" data-mud-data="next">next</span>'
    end
    pageBar = '<div class="pager">' .. back
        .. '<span class="pn">' .. page .. " / " .. pages
        .. " &middot; " .. total .. "</span>" .. fwd .. "</div>"
    return out
end

local function mobsBody()
    local t = {}
    local function add(x) t[#t + 1] = x end
    local keys = sortedKeys(mobs)
    if rowCount(keys) == 0 then
        if filter ~= "" then
            return '<div class="idle">nothing matches <b>' .. escapeHtml(filter)
                .. "</b></div>"
        end
        return '<div class="idle">no mobs recorded yet<br><br>walk into a room '
            .. "and anything standing there is noted</div>"
    end

    for _, k in ipairs(pageKeys(keys)) do
        local m = mobs[k]
        -- Belt and braces over dropEmpty: an entry with no sightings is not a
        -- mob and must not be drawn even if one somehow survives in the data.
        -- The client kept one after its last room was read, and the panel
        -- offering to scan a thing that is nowhere is the part that is wrong.
        local rooms = 0
        for _ in pairs(m.rooms or {}) do rooms = rooms + 1 end
        if rooms > 0 then

        local plTxt, plCls = "unknown", " none"
        if safeNum(m.pl) then
            plTxt = commas(m.pl)
            plCls = ""
        end
        add('<div class="row"><span class="nm">' .. escapeHtml(m.name) .. "</span>")
        add('<span class="pl' .. plCls .. '">' .. escapeHtml(plTxt) .. "</span>")
        -- Only offer to scan what has no reading. The button sends 'scan
        -- <name>' and nothing else; the reply comes back through the ordinary
        -- reader.
        if not safeNum(m.pl) then
            add('<span class="go" data-mud-action="scan" data-mud-data="'
                .. escapeHtml(m.name) .. '">scan</span>')
        end

        -- The word this mob answers to, and a way to change it. Clicking it
        -- turns this row into a field; anything else stays as it was.
        if kwEdit == keyOf(m.name) then
            -- value re-emitted from what has been typed, because a repaint
            -- that DOES happen would otherwise empty the box
            -- NO data-mud-action on the form. An action fires on a click
            -- anywhere inside the element carrying it -- including the input
            -- -- so clicking into the box saved and closed it. Tabbing in
            -- worked, which is what gives it away.
            --
            -- The form still submits on enter; submit is its own event and
            -- does not need the attribute.
            add('<form><input id="dexkw" type="text"'
                .. ' value="' .. escapeHtml(kwTyped) .. '" size="8"></form>')
            add('<span class="go" data-mud-action="kwsave">save</span>')
        else
            local word = scanKw[keyOf(m.name)]
            if type(word) ~= "string" or word == "" then word = "kw?" end
            add('<span class="go2" data-mud-action="kwedit" data-mud-data="'
                .. escapeHtml(m.name) .. '">' .. escapeHtml(word) .. "</span>")
        end
        add("</div>")

        -- Vnums, not names. A vnum is what identifies a room and it does not
        -- rot; the map's own name for 11216 came back as 'Songhold -- Elite
        -- Quarters&D', damaged upstream and beyond fixing from here. Anything
        -- that wants a name can ask the mapper for one.
        local where = roomList(m)
        if rowCount(where) > 0 then
            add('<div class="sub">' .. escapeHtml(m.area) .. " &middot; ")
            for _, n in ipairs(where) do
                -- Each room is a button that walks you there. The mapper's own
                -- auto-walker does it, so it honours move delay, fastwalk and
                -- every lock and weight the map carries.
                add('<span class="go2" data-mud-action="goto" data-mud-data="'
                    .. tostring(n) .. '">' .. tostring(n) .. "</span>")
            end
            add("</div>")
        end

        end
    end
    return table.concat(t)
end

local function itemsBody()
    local t = {}
    local function add(x) t[#t + 1] = x end
    local keys = sortedKeys(items)
    if rowCount(keys) == 0 then
        if filter ~= "" then
            return '<div class="idle">nothing matches <b>' .. escapeHtml(filter)
                .. "</b></div>"
        end
        return '<div class="idle">no items recorded yet<br><br>type <b>ana '
            .. "&lt;item&gt;</b> and it fills in</div>"
    end

    for _, k in ipairs(pageKeys(keys)) do
        local it = items[k]
        add('<div class="row pick" data-mud-action="item" data-mud-data="'
            .. escapeHtml(k) .. '"><span class="nm">'
            .. escapeHtml(it.name) .. "</span>")
        if safeNum(it.plReq) then
            add('<span class="pl">req ' .. escapeHtml(commas(it.plReq)) .. "</span>")
        end
        add("</div>")

        local bits = {}
        if type(it.wear) == "string" then push(bits, "worn " .. it.wear) end
        if type(it.armor) == "string" then push(bits, "armor " .. it.armor) end
        if safeNum(it.weight) then push(bits, "wt " .. tostring(it.weight)) end
        if type(it.gains) == "string" then push(bits, "gains " .. it.gains) end
        for _, s in ipairs(it.src or {}) do
            if type(s) == "table" and type(s.mob) == "string" and s.mob ~= "" then
                push(bits, "from " .. s.mob)
            end
        end
        if rowCount(bits) > 0 then
            add('<div class="sub">' .. escapeHtml(table.concat(bits, " &middot; "))
                :gsub("&amp;middot;", "&middot;") .. "</div>")
        end
    end
    return table.concat(t)
end

-- Everything the codex knows about one item, on its own screen.
--
-- The named fields first because they are the ones worth comparing, then every
-- other label analyze printed, then what it said verbatim. A record that cannot
-- be read back in full is a record that quietly loses whatever nobody thought
-- to parse -- so the raw block is kept and shown, not just the parsed parts.
local function detailBody()
    local it = items[detail]
    if type(it) ~= "table" then
        detail = ""
        return itemsBody()
    end

    local t = {}
    local function add(x) t[#t + 1] = x end

    add('<div class="head"><span class="tb" data-mud-action="back">back</span>')
    add('<span class="dn">' .. escapeHtml(it.name) .. "</span></div>")

    local function line(k, v)
        local t = type(v)
        if t ~= "string" and t ~= "number" then return end
        if v == "" or v == "undefined" then return end
        add('<div class="row"><span class="dk">' .. escapeHtml(k) .. "</span>")
        add('<span class="dv">' .. escapeHtml(tostring(v)) .. "</span></div>")
    end

    if safeNum(it.plReq) then line("power required", commas(it.plReq)) end
    line("wear location", it.wear)
    line("armor rating", it.armor)
    if safeNum(it.weight) then line("weight", tostring(it.weight)) end
    if safeNum(it.value) then line("value", commas(it.value)) end
    if safeNum(it.price) then line("shop price", commas(it.price)) end
    line("layers", it.layers)
    line("gains", it.gains)
    line("properties", it.props)

    local aff = {}
    for k, v in pairs(it.affects or {}) do
        if safeNum(v) then push(aff, k .. " " .. tostring(v)) end
    end
    table.sort(aff)
    if rowCount(aff) > 0 then line("affects", table.concat(aff, ", ")) end

    -- every other label it printed, sorted so the screen does not reshuffle
    local seen = {
        ["pl req"] = true, ["item's wear location"] = true, weight = true,
        layers = true, ["special properties"] = true,
        ["affects powerlevel gains by"] = true,
    }
    local extra = {}
    for k in pairs(it.fields or {}) do
        if not seen[k] then push(extra, k) end
    end
    table.sort(extra)
    if rowCount(extra) > 0 then
        add('<div class="sec">also</div>')
        for _, k in ipairs(extra) do line(k, it.fields[k]) end
    end

    -- What it actually goes for between players, which is the only price on
    -- this screen that anyone bargained over.
    local st = saleStats(it)
    if st then
        add('<div class="sec">sold at auction for</div>')
        if st.count == 1 then
            line("price", commas(st.min))
        else
            line("average", commas(st.avg) .. " over " .. st.count .. " sales")
            line("range", commas(st.min) .. " to " .. commas(st.max))
        end
        if type(st.last) == "table" then
            local when = ""
            if safeNum(st.last.at) then
                when = os.date("%d %b", st.last.at)
            end
            local to = st.last.buyer
            if type(to) ~= "string" or to == "" then to = "someone" end
            line("last", commas(st.last.price) .. " to " .. to .. " " .. when)
        end
    end

    -- Where it came from, as a tree that stays shut until asked.
    --
    -- Flat, this was a line per sighting -- the same mob repeated once for every
    -- room it dropped in -- and it is the part of the screen that grows without
    -- limit. Area, then what dropped it, then the rooms that happened in.
    local srcN = rowCount(it.src or {})
    if srcN > 0 then
        local mark = "show"
        if srcOpen then mark = "hide" end
        add('<div class="sec">found on <span class="tb" data-mud-action="srcs">')
        add(mark .. " " .. srcN .. "</span></div>")

        if srcOpen then
            local byArea = {}
            for _, sc in ipairs(it.src) do
                if type(sc) == "table" then
                    local a = trimBoth(tostring(sc.area or ""))
                    if a == "" then a = "somewhere unmapped" end
                    local m = cleanName(sc.mob)
                    if m == "" then m = "something" end
                    if type(byArea[a]) ~= "table" then byArea[a] = {} end
                    if type(byArea[a][m]) ~= "table" then byArea[a][m] = {} end
                    local n = safeNum(sc.room)
                    if n then byArea[a][m][tostring(n)] = n end
                end
            end

            local areas = {}
            for a in pairs(byArea) do push(areas, a) end
            table.sort(areas)
            for _, a in ipairs(areas) do
                add('<div class="t1">' .. escapeHtml(a) .. "</div>")
                local whos = {}
                for m in pairs(byArea[a]) do push(whos, m) end
                table.sort(whos)
                for _, m in ipairs(whos) do
                    local rooms = {}
                    for _, n in pairs(byArea[a][m]) do
                        if safeNum(n) then push(rooms, n) end
                    end
                    table.sort(rooms)
                    local txt = {}
                    for _, n in ipairs(rooms) do push(txt, tostring(n)) end
                    local tail = ""
                    if rowCount(txt) > 0 then
                        tail = " &middot; rooms " .. table.concat(txt, ", ")
                    end
                    add('<div class="t2">' .. escapeHtml(m) .. tail .. "</div>")
                end
            end
        end
    end

    if rowCount(it.raw or {}) > 0 then
        add('<div class="sec">as the MUD said it</div>')
        for _, l in ipairs(it.raw) do
            add('<div class="rawln">' .. escapeHtml(l) .. "</div>")
        end
    end

    return table.concat(t)
end

local function render()
    if not widget then return end

    local inner = ""
    pageBar = ""
    if detail ~= "" and view == "items" then
        inner = detailBody()
    elseif view == "items" then
        inner = itemsBody()
    else
        inner = mobsBody()
    end

    local mobOn, itemOn = " on", ""
    if view == "items" then mobOn, itemOn = "", " on" end

    -- The box carries whatever is pending, so a re-render for any other reason
    -- puts back what was being typed.
    -- The input is identified by id, not by data-mud-action. An action fires on
    -- a CLICK; typing does not click anything, so a keyup handler is what reads
    -- the box, and it tells the box apart by targetId.
    local bar = '<form class="find" data-mud-action="find">'
        .. '<input id="dexfind" type="text" placeholder="search"'
        .. ' value="' .. escapeHtml(pending) .. '">'
        .. '<span class="tb" data-mud-action="find">find</span>'
    if filter ~= "" then
        bar = bar .. '<span class="tb" data-mud-action="clear">clear</span>'
    elseif view == "mobs" then
        -- The label is what clicking DOES, not what is showing. Showing the
        -- state made it read 'here' while it was already showing here, so the
        -- only way to know what the button would do was to press it. The line
        -- underneath is what reports the state.
        local mark = "all"
        if not hereOnly then mark = "here" end
        bar = bar .. '<span class="tb sw" data-mud-action="scope">' .. mark .. "</span>"
    end
    bar = bar .. "</form>"

    -- What you are looking at, said plainly, with the area kept in every mode.
    -- It used to appear only on the mobs tab scoped to here, so switching to
    -- items or running a search took away the one line that said which area any
    -- of this belonged to.
    local spot = here()
    local area = ""
    if type(spot) == "table" and spot.area ~= "" then area = spot.area end

    -- One shape: 'Viewing:' dim, and the thing being viewed bright. Weight and
    -- colour separate the label from the value more strongly than punctuation
    -- does, and cost no characters in a panel this narrow.
    --
    -- The quotes around a search term stay, because that is arbitrary text the
    -- user typed and its edges matter -- 'the ginyu' and 'the ginyu base' are
    -- different searches. They are literal markup rather than part of the
    -- escaped value, or they come out as '&quot;' in the source for no reason.
    local said = ""
    if filter ~= "" then
        said = 'Viewing: Search Results for <b>"' .. escapeHtml(filter) .. '"</b>'
    elseif view == "mobs" and not hereOnly then
        said = "Viewing: <b>All</b>"
    elseif area ~= "" then
        said = "Viewing: <b>" .. escapeHtml(area) .. "</b>"
    end

    local hint = ""
    if said ~= "" then hint = '<div class="hint">' .. said .. "</div>" end

    setWidgetProperty(widget, "content", css()
        .. '<div class="dbi-dex">'
        .. '<div class="bar"><span>Codex</span><span class="sp"></span>'
        .. '<span class="tb' .. mobOn .. '" data-mud-action="tab" data-mud-data="mobs">mobs</span>'
        .. '<span class="tb' .. itemOn .. '" data-mud-action="tab" data-mud-data="items">items</span>'
        .. '<span class="tb" data-mud-action="close">hide</span></div>'
        .. bar
        .. hint
        .. '<div class="body">' .. inner .. "</div>"
        .. pageBar
        .. "</div>")
end

-- force = true for anything the USER just did.
--
-- This panel repaints whenever the MUD teaches it something, and a repaint
-- replaces the input the user is typing into -- taking the caret with it.
-- Portrait learned this the hard way with a url long enough to be worth
-- pasting, which could not be typed at all.
local function safeRender(force)
    if kwEdit ~= "" and force ~= true then return end
    local ok, err = pcall(render)
    if not ok then
        lastError = tostring(err)
        print(TAG .. "render error: " .. lastError)
    end
end

----------------------------------------------------------------------
-- commands
----------------------------------------------------------------------

-- ': it is locked' rather than a bare full stop, when the walker says why.
local function suffixOf(res)
    if type(res) ~= "table" then return "." end
    if type(res.error) == "string" and res.error ~= "" then
        return ": " .. res.error
    end
    return "."
end

local function countOf(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

-- Who teaches this, and where.
--
-- A plain function rather than only a route, because the command needs it too
-- and 'route' is declared a few hundred lines further down -- a local used
-- above its declaration resolves as a nil global here.
local function queryTrainers(want)
    local out, n = {}, 0

    -- The named ones first: they are the answer to "where do I go", and a
    -- room we have stood in cannot be.
    for _, t in ipairs(TAUGHT_BY) do
        local hit = want == ""
        if not hit then
            for _, sk in ipairs(t.skills) do
                if sk:find(want, 1, true) ~= nil then hit = true end
            end
        end
        if hit then
            n = n + 1
            out[n] = { kind = "named", who = t.who, race = t.race,
                       where = t.where, skills = t.skills }
        end
    end

    -- Then the rooms we have actually practised in.
    for key, rec in pairs(trainers) do
        local teaches, tn = {}, 0
        for sk in pairs(rec.teaches) do
            if want == "" or sk:find(want, 1, true) ~= nil then
                tn = tn + 1
                teaches[tn] = sk
            end
        end
        local refused, rn = {}, 0
        for sk in pairs(rec.refused) do
            rn = rn + 1
            refused[rn] = sk
        end
        table.sort(teaches)
        table.sort(refused)
        -- A room that refused the very thing being asked about is an
        -- answer too -- it is the one place not to walk to.
        if want == "" or tn > 0 or rec.refused[want] ~= nil then
            n = n + 1
            out[n] = { kind = "room", vnum = safeNum(key),
                       room = roomLabel(key), area = rec.area,
                       teaches = teaches, refused = refused,
                       refusedThis = rec.refused[want] ~= nil }
        end
    end

    local quest = nil
    if want ~= "" then
        for sk, howto in pairs(BY_QUEST) do
            if sk:find(want, 1, true) ~= nil then quest = howto end
        end
    end

    return { trainers = out, quest = quest }
end

local function dexCommand(cmd)
    local low = trimBoth(tostring(cmd or "")):lower()

    if low == "" or low == "show" then
        shown = true
        if widget then showWidget(widget) end
        safeRender()

    elseif low == "hide" then
        shown = false
        if widget then hideWidget(widget) end

    elseif low == "trainers" or low:sub(1, 9) == "trainers " then
        local want = ""
        if #low > 9 then want = trimBoth(low:sub(10)) end
        local body = queryTrainers(want)

        if want == "" then
            print(TAG .. "trainers:")
        else
            print(TAG .. "trainers for '" .. want .. "':")
        end
        if body.quest ~= nil then
            print("   not taught by anyone -- " .. body.quest)
        end
        local shownAny = false
        for _, t in ipairs(body.trainers) do
            shownAny = true
            if t.kind == "named" then
                print(string.format("   %-14s %-9s %s", t.who, t.race,
                    table.concat(t.skills, ", ")))
                print("                            " .. t.where)
            else
                local mark = ""
                if t.refusedThis then mark = "  -- refused it here" end
                print(string.format("   [%s] %s (%s)%s", tostring(t.vnum),
                    t.room, t.area, mark))
                if #t.teaches > 0 then
                    print("      teaches: " .. table.concat(t.teaches, ", "))
                end
                if #t.refused > 0 then
                    print("      refused: " .. table.concat(t.refused, ", "))
                end
            end
        end
        if not shownAny then print("   nothing known.") end

    elseif low == "mobs" or low == "items" then
        view = low
        detail = ""
        safeRender()
        saveAll()

    elseif low:sub(1, 5) == "find " then
        filter = trimBoth(low:sub(6))
        pending = filter
        safeRender()
        echo(TAG .. countOf(mobs) .. " mobs, " .. countOf(items)
            .. " items; showing what matches '" .. filter .. "'.", GOLD)

    elseif low == "trace on" or low == "trace off" then
        uiTrace = (low == "trace on")
        if uiTrace then
            echo(TAG .. "every widget event will print. Click and type in the "
                .. "search box, then 'dbdex trace off'.", GOLD)
        else
            echo(TAG .. "widget events are quiet again.", GOLD)
        end

    elseif low == "here" or low == "all" then
        hereOnly = (low == "here")
        safeRender()
        if hereOnly then
            echo(TAG .. "mobs in this area only.", GOLD)
        else
            echo(TAG .. "mobs everywhere.", GOLD)
        end

    elseif low == "clear" then
        filter = ""
        pending = ""
        detail = ""
        safeRender()

    elseif low == "link on" or low == "link off" then
        linkOn = (low == "link on")
        if linkOn then
            echo(TAG .. "a mob with no power level will offer a scan link.", GOLD)
        else
            echo(TAG .. "scan links off; the panel still has its button.", GOLD)
        end

    elseif low == "forget" then
        mobs = {}
        items = {}
        forgetOffers()
        saveAll()
        safeRender()
        echo(TAG .. "everything dropped.", GOLD)

    -- 'dbdex sales' for the whole board, 'dbdex sales <name>' for one thing's
    -- history. Player-to-player prices, so it says what something is worth
    -- rather than what a shopkeeper wants for it.
    elseif low == "sales" or low:sub(1, 6) == "sales " then
        local want = trimBoth(low:sub(7))
        local rows = {}
        for _, v in pairs(items) do
            local st = nil
            if type(v) == "table" then st = saleStats(v) end
            local hit = false
            if st then
                if want == "" then hit = true
                elseif tostring(v.name):lower():find(want, 1, true) then hit = true end
            end
            if hit then push(rows, { name = v.name, st = st, rec = v }) end
        end
        table.sort(rows, function(a, b) return a.st.avg > b.st.avg end)

        if rowCount(rows) == 0 then
            echo(TAG .. "no sales recorded yet. They land as the auction "
                .. "channel calls them.", GOLD)
        elseif want ~= "" and rowCount(rows) == 1 then
            -- One item named: print every sale it has, newest last.
            local one = rows[1]
            echo(TAG .. one.name, GOLD)
            for _, sale in ipairs(one.rec.sales or {}) do
                if type(sale) == "table" and safeNum(sale.price) then
                    local when = ""
                    if safeNum(sale.at) then when = os.date("%d %b %H:%M", sale.at) end
                    local to = sale.buyer
                    if type(to) ~= "string" or to == "" then to = "someone" end
                    print("    " .. commas(sale.price) .. "  to " .. to .. "  " .. when)
                end
            end
            print("    -- low " .. commas(one.st.min) .. ", high "
                .. commas(one.st.max) .. ", average " .. commas(one.st.avg)
                .. " over " .. one.st.count)
        else
            echo(TAG .. "auction prices, dearest first:", GOLD)
            for _, r in ipairs(rows) do
                print("    " .. commas(r.st.avg) .. "  " .. r.name
                    .. "  (" .. r.st.count .. " sale(s), " .. commas(r.st.min)
                    .. " to " .. commas(r.st.max) .. ")")
            end
        end

    -- 'dbdex kw soldier' -- the word that scans whatever this plugin last
    -- offered a link for.
    --
    -- The guess is right nine times in ten and the retry learns most of the
    -- rest, but a retry only fires when the MUD actually answers "They aren't
    -- here." -- and a mob that answers to two words, one of them somebody
    -- else's, never produces that line. This is the way to just say so.
    elseif low == "kw" or low:sub(1, 3) == "kw " then
        local word = trimBoth(low:sub(4))
        -- 'kw <word> <mob name>' names it outright, for a room holding more
        -- than one. Split on the first space; everything after is the mob.
        local named = ""
        local space = word:find(" ", 1, true)
        if space ~= nil then
            named = trimBoth(word:sub(space + 1))
            word = trimBoth(word:sub(1, space - 1))
        end
        if word == "" then
            local n = 0
            for name, kw in pairs(scanKw) do
                n = n + 1
                print(TAG .. "  " .. name .. "  ->  scan " .. kw)
            end
            if n == 0 then
                echo(TAG .. "no keywords learned yet. Stand where one is and "
                    .. "'dbdex kw <word>' after it offers the wrong one.", GOLD)
            end
            return
        end
        local who = named
        if who == "" then who = tried.name end
        if type(who) ~= "string" or who == "" then who = scan.who end

        -- Nothing pending? Then use what is recorded in this room.
        --
        -- A scan is only ever OFFERED for a mob with no reading, so a mob
        -- already known never becomes 'tried.name' -- and those are exactly
        -- the ones worth naming, because they are the ones being hunted. This
        -- used to refuse while the mob was standing in front of you.
        if type(who) ~= "string" or who == "" then
            local at = here()
            local vnum = nil
            if type(at) == "table" then vnum = safeNum(at.num) end
            local found = {}
            if vnum ~= nil then
                for _, v in pairs(mobs) do
                    if type(v) == "table" and type(v.name) == "string" then
                        for _, r in ipairs(roomList(v)) do
                            if r == vnum then
                                push(found, v.name)
                                break
                            end
                        end
                    end
                end
            end
            if rowCount(found) == 1 then
                who = found[1]
            elseif rowCount(found) > 1 then
                echo(TAG .. "more than one thing is recorded here. Name it: "
                    .. "'dbdex kw <word> <mob>'.", GOLD)
                for _, nm in ipairs(found) do print(TAG .. "   " .. nm) end
                return
            end
        end

        if type(who) ~= "string" or who == "" then
            echo(TAG .. "nothing to attach that to -- walk into a room with a "
                .. "mob in it first.", "#ff6666")
            return
        end
        scanKw[keyOf(who)] = word
        -- Offer it again here rather than making them leave and come back.
        forgetOffers()
        echo(TAG .. "'" .. who .. "' will be scanned as '" .. word .. "'.", GOLD)

    -- Read everything in this room that has not been read.
    --
    -- They queue. The MUD answers one scan at a time and this plugin tracks
    -- one -- 'tried' holds which mob was asked about and with which word --
    -- so three at once come back with no way to tell whose outline is whose.
    elseif low == "scanall" then
        local at = here()
        local vnum = nil
        if type(at) == "table" then vnum = safeNum(at.num) end
        if vnum == nil then
            echo(TAG .. "no room yet.", "#ff6666")
            return
        end

        local todo = {}
        for _, v in pairs(mobs) do
            if type(v) == "table" and type(v.name) == "string"
                and safeNum(v.pl) == nil then
                for _, r in ipairs(roomList(v)) do
                    if r == vnum then
                        push(todo, v.name)
                        break
                    end
                end
            end
        end

        if rowCount(todo) == 0 then
            echo(TAG .. "nothing here left to read.", GOLD)
            return
        end
        bulk.list = todo
        bulk.on = true
        bulk.at = 0
        echo(TAG .. "reading " .. rowCount(todo) .. ", one at a time.", GOLD)

    elseif low == "diag" then
        print(TAG .. "instance=" .. INSTANCE)
        local spot = here()
        if spot then
            print(TAG .. "here: vnum=" .. tostring(spot.num)
                .. " area=[" .. tostring(spot.area) .. "]"
                .. " map calls it [" .. roomLabel(spot.num) .. "]")
        else
            print(TAG .. "here: unknown -- getPlayerRoom gave nothing")
        end
        print(TAG .. "mobs=" .. countOf(mobs) .. " items=" .. countOf(items)
            .. " sales=" .. sawSales)
        -- Each one with its room count. A total says two entries; it does not
        -- say whether one of them has no sightings left, and that is the
        -- difference between correct and a stale bucket sitting in the panel.
        local shownN = 0
        for k, v in pairs(mobs) do
            if type(v) == "table" and shownN < 20 then
                shownN = shownN + 1
                local rooms = {}
                for _, n in ipairs(roomList(v)) do push(rooms, tostring(n)) end
                print(TAG .. "  [" .. tostring(v.name) .. "] pl="
                    .. tostring(v.pl) .. " rooms=" .. rowCount(rooms)
                    .. " (" .. table.concat(rooms, ",") .. ")  key=" .. tostring(k))
            end
        end
        print(TAG .. "lines seen: rooms=" .. sawRooms .. " mobs=" .. sawMobs
            .. " items=" .. sawItems)
        print(TAG .. "analyze open=" .. tostring(ana.on) .. " on [" .. ana.name .. "]")
        print(TAG .. "scan waiting on [" .. scan.who .. "]")
        -- Which of the map calls this build actually has, and what the scouter
        -- last published. The reading comes from there rather than off the
        -- line, so if it is empty the scouter is either older than 0.8.1 or not
        -- installed, and no amount of scanning will fill anything in.
        local have = {}
        for _, n in ipairs({ "getPlayerRoom", "getMapRoom",
                             "getMapUserData", "setMapUserData" }) do
            local mark = "no"
            if callable(n) then mark = "yes" end
            push(have, n .. "=" .. mark)
        end
        print(TAG .. "map calls: " .. table.concat(have, " "))
        print(TAG .. "scouter published: ["
            .. tostring(mapCall("getMapUserData", "scouter.scan")) .. "]")
        print(TAG .. "empty entries swept off: " .. sweptOff)
        print(TAG .. "last widget event: " .. lastUi)
        print(TAG .. "search box holds [" .. pending .. "] filtering on ["
            .. filter .. "]")
        print(TAG .. "writes flushed: " .. writes
            .. "  loaded from " .. loadedFrom)
        print(TAG .. "lastError=" .. tostring(lastError))

    else
        echo(TAG .. "dbdex show | hide | mobs | items", GOLD)
        echo("          dbdex find <text>     filter both lists", GOLD)
        echo("          dbdex clear           drop the filter", GOLD)
        echo("          dbdex here|all        this area, or everywhere", GOLD)
        echo("          dbdex trace on|off    print every widget event", GOLD)
        echo("          dbdex link on|off     offer a scan link in the scroll", GOLD)
        echo("          dbdex forget          drop everything recorded", GOLD)
        echo("          dbdex scanall         read everything in this room", GOLD)
        echo("          dbdex diag            what it knows and where it thinks you are", GOLD)
    end
    return true
end

----------------------------------------------------------------------
-- answering other plugins
----------------------------------------------------------------------

-- Everything below is documented in notes/codex-api.md. Two ways in:
--
--   1. Read the store directly. It is saved in the app-wide GLOBAL scope, so
--      any plugin can help itself with no cooperation from this one and no
--      round trip:
--
--        local dex = getPluginTable("dbi-codex", "dbi-codex-data", "global")
--
--   2. Ask, over the event bus, which is what the rest of this section is for.
--      Better when you want the matching done here rather than reimplemented,
--      or when you want telling as things are learned.
--
-- Records are handed out as COPIES. The tables here are live and edited in
-- place, and a caller holding one would see it change under them -- or worse,
-- change it.

local function mobOut(rec)
    -- kw is the word the MUD itself answered to. It is only ever set from a
    -- scan that came back with an outline, so it is confirmed rather than
    -- guessed -- which is what makes it safe for another plugin to send.
    -- Absent when nothing has confirmed one, and a caller should fall back to
    -- the full name rather than inventing something.
    local out = { name = rec.name, area = rec.area, pl = safeNum(rec.pl),
                  kw = scanKw[keyOf(rec.name)], rooms = {} }
    for _, n in ipairs(roomList(rec)) do push(out.rooms, n) end
    return out
end

local function itemOut(rec)
    local out = { name = rec.name, plReq = safeNum(rec.plReq),
                  price = safeNum(rec.price), wear = rec.wear,
                  armor = rec.armor, weight = safeNum(rec.weight),
                  props = rec.props, fields = {}, src = {}, sales = {} }
    for _, sale in ipairs(rec.sales or {}) do
        if type(sale) == "table" then
            push(out.sales, { price = safeNum(sale.price), buyer = sale.buyer,
                              at = safeNum(sale.at) })
        end
    end
    for k, v in pairs(rec.fields or {}) do
        if type(v) == "string" and v ~= "" and v ~= "undefined" then out.fields[k] = v end
    end
    for _, sc in ipairs(rec.src or {}) do
        if type(sc) == "table" then
            push(out.src, { mob = sc.mob, area = sc.area, room = safeNum(sc.room) })
        end
    end
    return out
end

-- A REST-shaped request/response envelope over the event bus.
--
-- One channel, one shape, so the next plugin that wants to answer questions
-- implements the same thing rather than inventing its own. emit() is one-way,
-- so a request names where the answer should go.
--
--   emit("dbi.request", {
--       id     = "whatever-you-like",   -- echoed back, for matching
--       to     = "codex",               -- which service; ignored by others
--       method = "GET",
--       path   = "/mobs",
--       query  = { q = "elite", area = "The Ginyu Base" },
--       reply  = "myplugin.reply",      -- optional, defaults to dbi.response
--   })
--
--   on("myplugin.reply", function(res)
--       -- res = { id, from = "codex", status = 200, body = {...} }
--       -- or   { id, from = "codex", status = 404, error = "..." }
--   end)
--
-- Routes are in notes/codex-api.md. Status codes are the obvious three: 200
-- found, 400 malformed, 404 no such route or no such thing.
local SERVICE = "codex"

local function lower(v) return tostring(v or ""):lower() end

-- Every mob with something in it, filtered. Kept separate from the panel's own
-- filter, which answers to the search box and the area switch.
local function queryMobs(q)
    local want = lower(q.q)
    local area = lower(q.area)
    local out = {}
    for _, v in pairs(mobs) do
        if type(v) == "table" and rowCount(roomList(v)) > 0 then
            local ok = true
            if area ~= "" and lower(v.area) ~= area then ok = false end
            if ok and want ~= "" then
                local hay = lower(v.name) .. " " .. lower(v.area)
                if not hay:find(want, 1, true) then ok = false end
            end
            if ok then push(out, mobOut(v)) end
        end
    end
    return out
end

local function queryItems(q)
    local want = lower(q.q)
    local out = {}
    for _, v in pairs(items) do
        if type(v) == "table" then
            local ok = (want == "")
            if not ok and lower(v.name):find(want, 1, true) then ok = true end
            if not ok then
                for k2, v2 in pairs(v.fields or {}) do
                    if lower(k2):find(want, 1, true)
                        or lower(v2):find(want, 1, true) then ok = true end
                end
            end
            if ok then push(out, itemOut(v)) end
        end
    end
    return out
end

-- One table out, never three values.
--
-- This used to return 'status, body, err' and onRequest read it back with
--
--     local ok, status, body, err = pcall(route, method, path, q)
--
-- which is sharp edge 4. The multi-value return came through the transpiler
-- wrapped into a single value, so 'status' held the whole tuple and 'body'
-- and 'err' arrived undefined. On the wire that looked like
--
--     status=200,[object Object],   mobs=0
--
-- a status no safeNum can read and an empty body, so every caller decided
-- Codex had nothing and said so. dbi-train reported 'Codex has nothing
-- scanned in The Ginyu Base' against a store holding fifteen mobs.
--
-- Real Lua handles the multi-return correctly, which is why luac, the linter
-- and a green suite all had nothing to say about it.
local function route(method, path, q)
    if method ~= "GET" then
        return { status = 400, body = nil, err = "only GET is served" }
    end

    if path == "/trainers" then
        local want = ""
        if type(q) == "table" and type(q.skill) == "string" then
            want = trimBoth(q.skill):lower()
        end
        return { status = 200, body = queryTrainers(want) }
    end

    if path == "/mobs" then return { status = 200, body = queryMobs(q) } end
    if path == "/items" then return { status = 200, body = queryItems(q) } end

    -- /mobs/<name> and /items/<name>. A name is not unique -- the same mob in
    -- two areas at two powers is two records -- so this answers with a list as
    -- well, and the caller picks.
    local one = capOf(path, "^/mobs/(.+)$")
    if one ~= nil then
        local found = {}
        for _, v in pairs(mobs) do
            if type(v) == "table" and keyOf(v.name) == keyOf(one)
                and rowCount(roomList(v)) > 0 then
                push(found, mobOut(v))
            end
        end
        if rowCount(found) == 0 then
            return { status = 404, body = nil, err = "no mob by that name" }
        end
        return { status = 200, body = found }
    end

    one = capOf(path, "^/items/(.+)$")
    if one ~= nil then
        local rec = items[keyOf(one)]
        if type(rec) ~= "table" then
            return { status = 404, body = nil, err = "no item by that name" }
        end
        return { status = 200, body = itemOut(rec) }
    end

    if path == "/areas" then
        local seen, out = {}, {}
        for _, v in pairs(mobs) do
            if type(v) == "table" and type(v.area) == "string" and v.area ~= "" then
                seen[v.area] = (seen[v.area] or 0) + 1
            end
        end
        for a, n in pairs(seen) do push(out, { area = a, mobs = n }) end
        table.sort(out, function(x, y) return x.area < y.area end)
        return { status = 200, body = out }
    end

    -- What things go for. Only items that have actually sold, so the caller
    -- gets a price history rather than the whole catalogue with holes in it.
    if path == "/sales" then
        local want = lower(q.q)
        local out = {}
        for _, v in pairs(items) do
            local st = nil
            if type(v) == "table" then st = saleStats(v) end
            local hit = false
            if st then
                if want == "" then hit = true
                elseif lower(v.name):find(want, 1, true) then hit = true end
            end
            if hit then
                push(out, { name = v.name, count = st.count, min = st.min,
                            max = st.max, avg = st.avg })
            end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return { status = 200, body = out }
    end

    one = capOf(path, "^/sales/(.+)$")
    if one ~= nil then
        local rec = items[keyOf(one)]
        local st = nil
        if type(rec) == "table" then st = saleStats(rec) end
        if st == nil then
            return { status = 404, body = nil, err = "nothing sold by that name" }
        end
        local body = itemOut(rec)
        body.count = st.count
        body.min = st.min
        body.max = st.max
        body.avg = st.avg
        return { status = 200, body = body }
    end

    if path == "/stats" then
        return { status = 200, body = { mobs = countOf(mobs),
            items = countOf(items), sales = sawSales, version = VERSION } }
    end

    return { status = 404, body = nil,
             err = "no such route: " .. tostring(path) }
end

local function onRequest(req)
    if type(req) ~= "table" then return end
    -- Addressed elsewhere. 'to' is optional so a broadcast reaches everyone,
    -- but a request naming another service is none of this one's business.
    local to = lower(req.to)
    if to ~= "" and to ~= SERVICE then return end

    local reply = "dbi.response"
    if type(req.reply) == "string" and req.reply ~= "" then reply = req.reply end

    local q = req.query
    if type(q) ~= "table" then q = {} end

    local method = tostring(req.method or "GET"):upper()
    local path = tostring(req.path or "")
    -- One value out of pcall, assigned inside the closure. Capturing route's
    -- returns through pcall is what broke this; capturing pcall's own pair
    -- would be the same trap one step out, since its arity varies with
    -- whether the call threw.
    local res = nil
    local ok = pcall(function() res = route(method, path, q) end)
    if not ok or type(res) ~= "table" then
        res = { status = 500, body = nil, err = "route failed" }
    end

    pcall(function()
        emit(reply, { id = req.id, from = SERVICE, status = res.status,
                      body = res.body, error = res.err })
    end)
end

-- Said whenever something is learned, so a plugin can follow along rather than
-- poll. 'kind' is "mob" or "item".
announce = function(kind, rec)
    pcall(function()
        if kind == "mob" then
            emit("dbi-codex.learned", { kind = kind, mob = mobOut(rec) })
        else
            emit("dbi-codex.learned", { kind = kind, item = itemOut(rec) })
        end
    end)
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

function init()
    loadAll()

    -- Came up with nothing? Look again.
    --
    -- The store is not always readable the instant a plugin loads. Until it is,
    -- this session knows no mobs and no items -- and while saveAll() will no
    -- longer write that over the real store, running the whole session blind is
    -- still wrong when the records are sitting right there.
    --
    -- Backed off, and it stops at the first read that answers.
    if not loadedOk then
        local waits = { 250, 600, 1500, 3000, 6000 }
        local again = nil
        again = function(step)
            if loadedOk then return end
            loadAll()
            if loadedOk then
                if shown then safeRender() end
                print(TAG .. "store was not ready at load; picked it up "
                    .. tostring(waits[step]) .. "ms in -- "
                    .. countOf(mobs) .. " mobs, " .. countOf(items) .. " items.")
                return
            end
            local nxt = waits[step + 1]
            if nxt then
                pcall(function() addTimer(nxt, function() again(step + 1) end) end)
            end
        end
        pcall(function() addTimer(waits[1], function() again(1) end) end)
    end

    widget = createWidget({
        type     = "html",
        name     = "codex",
        title    = "Codex",
        position = { x = 980, y = 120 },
        size     = { width = 380, height = 420 },
        scrollable = false,
        appearance = { showTitleBar = false, autoHideSettingsCog = true },
    })
    setWidgetAppearance(widget, {
        backgroundColor   = PANEL_BG,
        backgroundOpacity = panelAlpha,
        borderColor       = GOLD,
        borderWidth       = 2,
        borderRadius      = 6,
    })

    -- registerWidgetEvent appends, so a reload would stack a second handler
    pcall(function() unregisterWidgetEvent(widget, "action") end)

    local onAction = function(data)
        if type(data) ~= "table" then return end
        local act = tostring(data.action or "")
        local arg = ""
        if type(data.data) == "string" then arg = data.data end

        if act == "tab" then
            if arg == "mobs" or arg == "items" then
                view = arg
                detail = ""
                page = 1
                safeRender()
                saveAll()
            end
        elseif act == "item" then
            -- Checked against what is actually stored rather than trusted: this
            -- went out as markup and came back through the client.
            if type(items[arg]) == "table" then
                detail = arg
                view = "items"
                srcOpen = false
                safeRender()
            end
        elseif act == "srcs" then
            srcOpen = not srcOpen
            safeRender()
        elseif act == "back" then
            detail = ""
            srcOpen = false
            safeRender()
        elseif act == "find" then
            -- targetValue if the event carries one, and what typing captured
            -- if it does not -- a submit is not documented to carry the input's
            -- value the way a key event is.
            local v = data.targetValue
            if type(v) == "string" then pending = v end
            filter = trimBoth(pending):lower()
            detail = ""
            page = 1
            safeRender()

        elseif act == "page" then
            if arg == "next" then page = page + 1 end
            if arg == "prev" then page = page - 1 end
            if page < 1 then page = 1 end
            safeRender()

        elseif act == "scope" then
            hereOnly = not hereOnly
            page = 1
            safeRender()

        elseif act == "goto" then
            local vnum = safeNum(arg)
            if vnum then
                local ok2 = pcall(function()
                    walkTo(vnum, function(res)
                        if type(res) == "table" and res.success ~= true then
                            echo(TAG .. "no way there from here"
                                .. suffixOf(res), UNKNOWN)
                        end
                    end)
                end)
                if not ok2 then
                    echo(TAG .. "this build cannot walk you there.", UNKNOWN)
                end
            end

        elseif act == "clear" then
            filter = ""
            pending = ""
            detail = ""
            page = 1
            safeRender()
        elseif act == "scan" then
            -- Letters and single spaces only. This went out as markup and came
            -- back, so it must not be able to carry a command separator.
            local word = keyword(arg)
            if word ~= "" then
                pcall(function() send("scan " .. word) end)
            end
        elseif act == "kwedit" then
            -- Open the field on this mob, seeded with whatever it answers to
            -- now so a small correction is a small edit.
            local nm = tostring(arg or "")
            if nm ~= "" then
                kwEdit = keyOf(nm)
                kwTyped = scanKw[kwEdit] or ""
                -- forced: the user asked for this, and the hold is only meant
                -- to stop the MUD redrawing underneath them
                safeRender(true)
            end
        elseif act == "kwsave" then
            local word = trimBoth(kwTyped):lower()
            if kwEdit ~= "" and word ~= "" then
                scanKw[kwEdit] = word
                forgetOffers()
                saveAll()
            elseif kwEdit ~= "" and word == "" then
                -- emptied on purpose: forget it and go back to guessing
                scanKw[kwEdit] = nil
                saveAll()
            end
            kwEdit = ""
            kwTyped = ""
            safeRender(true)
        elseif act == "close" then
            shown = false
            hideWidget(widget)
        end
    end

    -- The panel's real height, from the event that reports it. widgetInfo lied
    -- about the size once and cost a release, so this is the number that gets
    -- believed. registerWidgetEvent APPENDS, so the old one goes first.
    pcall(function() unregisterWidgetEvent(widget, "resize") end)
    registerWidgetEvent(widget, "resize", function(data)
        if type(data) ~= "table" then return end
        local h = safeNum(data.height)
        if h and h > 0 and h ~= panelH then
            panelH = h
            safeRender()
        end
    end)

    -- One place that records every widget event, so the trace cannot disagree
    -- with what the handlers actually saw.
    local noteUi = function(kind, e)
        local bits = { kind }
        if type(e) == "table" then
            for _, f in ipairs({ "action", "data", "targetId", "targetTag",
                                 "targetValue", "key", "targetName" }) do
                if e[f] ~= nil then push(bits, f .. "=[" .. tostring(e[f]) .. "]") end
            end
            if type(e.dataset) == "table" then
                for k, v in pairs(e.dataset) do
                    push(bits, "dataset." .. tostring(k) .. "=[" .. tostring(v) .. "]")
                end
            end
        end
        lastUi = table.concat(bits, " ")
        if uiTrace then print(TAG .. "ui: " .. lastUi) end
    end

    -- Typing. Captured, NOT applied: rendering on a keystroke would replace the
    -- input and take the focus with it, so nothing is drawn until the search is
    -- submitted. data-mud-action would not do -- an action fires on a click.
    pcall(function() unregisterWidgetEvent(widget, "keyup") end)
    registerWidgetEvent(widget, "keyup", function(e)
        noteUi("keyup", e)
        if type(e) ~= "table" then return end
        -- The keyword field, if that is the one being typed in. Captured
        -- only -- rendering here would replace the input mid-word.
        if e.targetId == "dexkw" then
            if type(e.targetValue) == "string" then kwTyped = e.targetValue end
            return
        end
        if e.targetId ~= "dexfind" then return end
        if type(e.targetValue) == "string" then pending = e.targetValue end
        -- Enter, if the event says so. It is not documented to carry a key, so
        -- this is a bonus rather than the mechanism -- the form's submit and the
        -- button are what are relied on.
        if e.key == "Enter" then
            filter = trimBoth(pending):lower()
            detail = ""
            page = 1
            safeRender()
        end
    end)

    -- Enter in the box. The form fires this; the FIND button fires the action.
    pcall(function() unregisterWidgetEvent(widget, "submit") end)
    registerWidgetEvent(widget, "submit", function(e)
        noteUi("submit", e)
        -- Enter in the keyword field saves it, same as the button.
        if kwEdit ~= "" then
            if type(e) == "table" and type(e.targetValue) == "string" then
                kwTyped = e.targetValue
            end
            local word = trimBoth(kwTyped):lower()
            if word ~= "" then
                scanKw[kwEdit] = word
            else
                scanKw[kwEdit] = nil
            end
            forgetOffers()
            saveAll()
            kwEdit = ""
            kwTyped = ""
            safeRender(true)
            return
        end
        if type(e) == "table" and type(e.targetValue) == "string" then
            pending = e.targetValue
        end
        filter = trimBoth(pending):lower()
        detail = ""
        page = 1
        safeRender()
    end)

    registerWidgetEvent(widget, "action", function(data)
        noteUi("action", data)
        local ok, err = pcall(onAction, data)
        if not ok then
            lastError = "widget action: " .. tostring(err)
            print(TAG .. "widget action error: " .. tostring(err))
        end
    end)

    -- Other plugins can ask. One envelope, documented in notes/codex-api.md, so
    -- the next plugin that answers questions implements the same shape.
    -- The bulk scan's pacing. One a second: the MUD answers inside a round,
    -- and anything faster is several scans in flight with one slot to track
    -- them.
    local beat2 = nil
    beat2 = function()
        pcall(function()
            if bulk.on and bulk.at == 0 then
                local name = nil
                local left = {}
                for i, nm in ipairs(bulk.list) do
                    if i == 1 then name = nm else push(left, nm) end
                end
                bulk.list = left
                if name == nil then
                    bulk.on = false
                    echo(TAG .. "done reading the room.", GOLD)
                else
                    local word = scanKw[keyOf(name)]
                    if type(word) ~= "string" or word == "" then
                        local words = keywords(name)
                        word = words[1] or ""
                    end
                    if word ~= "" then
                        tried.name, tried.word = name, word
                        tried.idx, tried.at = 1, os.time()
                        bulk.at = os.time()
                        pcall(function() send("scan " .. word) end)
                    end
                end
            elseif bulk.on and bulk.at > 0
                and os.time() - bulk.at > SCAN_WAIT then
                -- nothing came back for that one; move on rather than stall
                bulk.at = 0
            end
        end)
        pcall(function() addTimer(1000, beat2) end)
    end
    pcall(function() addTimer(1000, beat2) end)

    on("dbi.request", onRequest)

    registerCommand("dbdex", dexCommand, "Item and mob codex")
    safeRender()
    -- Counted out loud. 'lost everything on restart' and 'never had anything'
    -- read the same on a fresh panel, and this is the line that tells them
    -- apart without being asked for.
    print(TAG .. "ready. restored " .. countOf(mobs) .. " mobs, "
        .. countOf(items) .. " items from " .. loadedFrom
        .. ". 'dbdex' for what it does.")
    -- Whatever it came out of, it goes back into the global one.
    if countOf(mobs) > 0 or countOf(items) > 0 then saveAll() end
end

-- What a trainer just said. Three lines, all verbatim off the stream.
--
--   You practice suppress.                              it taught us
--   I've taught you everything I can about suppress.    it can, we are capped
--   I do not know how to teach that.                    it cannot
--
-- The first two name the skill and the third does not, which is why the ask
-- is remembered on the way out.
--
-- 'only Yardrats have the ability to teach it' is NOT in here. It reads like
-- a fourth answer and it is helpfile prose -- the last line of instant
-- transmission's own help. Parsing it would file flavour text as a rule.
local function readTrainer(clean)
    local rec = nil

    -- Prefixed by the prompt often enough that anchoring loses it:
    --   (PowerLevel:<1.882m|1.882m>) You practice defensive style.
    local won = clean:match("You practice (.+)%.")
    if type(won) == "string" and won ~= "" then
        rec = trainerHere()
        if rec == nil then return false end
        rec.teaches[won:lower()] = 1
        rec.refused[won:lower()] = nil
        return true
    end

    local had = clean:match("taught you everything I can about (.+)%.")
    if type(had) == "string" and had ~= "" then
        rec = trainerHere()
        if rec == nil then return false end
        -- It CAN teach it. That we are already at the cap is about us, not
        -- about this room, and the room is what is being recorded.
        rec.teaches[had:lower()] = 1
        rec.refused[had:lower()] = nil
        return true
    end

    if clean:find("I do not know how to teach that", 1, true) ~= nil then
        if pracAsk == "" then return false end
        rec = trainerHere()
        if rec == nil then return false end
        if rec.teaches[pracAsk] == nil then rec.refused[pracAsk] = 1 end
        pracAsk = ""
        return true
    end

    return false
end

function onLine(sessionId, rawLine, cleanLine)
    local ok, err = pcall(function()
        local clean = trimBoth(cleanLine)
        if clean == "" then return end

        dropLine = false
        local touched = false
        if readTrainer(clean) then
            saveAll()
            return
        end
        -- The prompt closes an analyze block, and that is when what it said is
    -- worth telling anyone about -- mid-block the record is half written. Checked before the readers so a
        -- block cannot run on into whatever follows it.
        if ana.on and clean:find("LifeForce:", 1, true) then
            ana.on = false
            touched = true
            if anaFresh and type(ana.rec) == "table" then announce("item", ana.rec) end
            anaFresh = false
        end

        -- Left the room? Everything unread that was standing in the last one
        -- goes with it. Checked before the readers, so a sighting recorded on
        -- this very line is filed against the room we are now in.
        local at = here()
        local nowNum = nil
        if type(at) == "table" then nowNum = safeNum(at.num) end
        if nowNum ~= nil then
            if atRoom ~= nil and atRoom ~= nowNum then
                keepBlindOnly(nowNum)
                touched = true
            end
            atRoom = nowNum
        end

        if feedAna(clean) then touched = true end
        if feedScan(clean) then touched = true end
        if feedRoom(clean, rawLine) then touched = true end
        if feedLoot(clean) then touched = true end
        if feedShop(clean, here()) then touched = true end
        if feedAuction(clean) then touched = true end

        -- 'You buy Class I Battle Armor.' -- the stock list above it already
        -- said where and for how much, so this only records that it was here.
        local bought = capOf(clean, "^You buy (.+)%.$")
        if bought ~= nil then
            noteSource(bought, keeperHere(here()), here())
            touched = true
        end

        if clean:find("[R#", 1, true) then sawRooms = sawRooms + 1 end

        if touched then
            saveAll()
            if shown then safeRender() end
        end
    end)
    if not ok then lastError = tostring(err) end
    -- false discards the line. Only when it has been rewritten with the link on
    -- it, and only after the rewrite went out.
    if dropLine then
        dropLine = false
        return false
    end
    return nil
end

-- The refusal does not name the skill, so the ask has to be caught going out.
--
-- 'prac' with no argument is the tree listing and not a practice at all;
-- 'prac compact' and 'prac condensed' are its options. None of those are a
-- skill and none should be remembered as one.
function onSend(sessionId, text)
    local ok = pcall(function()
        local low = trimBoth(tostring(text or "")):lower()
        local want = low:match("^prac%s+(.+)$")
        if type(want) ~= "string" then want = low:match("^practice%s+(.+)$") end
        if type(want) ~= "string" or want == "" then return end
        want = trimBoth(want)
        if want == "compact" or want == "condensed" then return end
        pracAsk = want
    end)
    if not ok then lastError = "onSend" end
end

function onConnect(sessionId) end

-- Both of these can be the last thing that runs, so neither waits for the
-- throttle. A kill runs neither, which is what the throttle above is for.
function onDisconnect(sessionId)
    saveAll()
end

function cleanup()
    saveAll()
end
