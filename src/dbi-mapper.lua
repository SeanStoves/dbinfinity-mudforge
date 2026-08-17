plugin = {
    id          = "dbi-mapper",
    name        = "DB Infinity Mapper",
    version     = "2026.08.17.000",
    author      = "Solao",
    description = "Builds MudForge's map from the room output, for a MUD with no GMCP room data.",
    settings    = { saveState = true },
}

-- The client's automapper follows GMCP or MSDP room packets. This MUD sends
-- neither -- it advertises CHARSET and answers a Core.Hello for the map grid,
-- which is a picture rather than room data: it has no ids, no names and no
-- exits in it. So the map is built from what the MUD prints instead, and
-- written into the client's own map database through the mapper API. Nothing
-- here draws anything; the client's map does that, and gets pathfinding,
-- walkTo, areas, flags and notes for free.
--
-- What the output gives us:
--
--   Stronghold -- Cadet Quarters [R#-wV2XH0Mh]     <- name and a stable id
--   Obvious exits:
--    North East South West Southeast Southwest.    <- the exits, next line
--
-- The id survives a server reboot. Proven rather than assumed: 49 ids appear
-- in transcripts from either side of the 08:00 restart on 2026-08-13 and not
-- one of them named a different room afterwards.

local VERSION = "0.81.1"
local TAG = "[DBI Mapper " .. VERSION .. "] "

local INSTANCE = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))

----------------------------------------------------------------------
-- directions
----------------------------------------------------------------------

-- Every spelling the MUD walks with, folded to one. The mapper API normalises
-- long names itself, but the trail and the coordinates here do not.
-- Directions, and the arithmetic on them: the canonical spellings, how far
-- one step moves, the opposite of each, the step vectors, the walk-string
-- letters and the long words. Six file-scope locals about one subject.
local nav = {}

nav.CANON = {
    n = "n", no = "n", nor = "n", north = "n",
    s = "s", so = "s", sou = "s", south = "s",
    e = "e", ea = "e", eas = "e", east = "e",
    w = "w", we = "w", wes = "w", west = "w",
    ne = "ne", northeast = "ne",
    nw = "nw", northwest = "nw",
    se = "se", southeast = "se",
    sw = "sw", southwest = "sw",
    u = "u", up = "u",
    d = "d", dn = "d", down = "d",
}

-- Where a step lands you, for laying rooms out. Up and down share the x/y of
-- the room below them and differ only in z, which is what a mapper expects.
-- The distance between two neighbouring rooms, in grid squares. One is
-- standard: room A and room B next door to each other are one apart.
--
-- Bigger buys space for a section that has to fit inside another -- the ring
-- whose interior holds more rooms than the ring encloses. It is not what makes
-- the gap between rooms on screen; the node is drawn as a fraction of whatever
-- the distance is, so they never touch at any setting. That was a bug once:
-- nodes sized for two while the rooms sat one apart, and the map drew as one
-- solid block.
nav.dist = { x = 1, y = 1 }

local function distFor(axis)
    return axis == "x" and nav.dist.x or nav.dist.y
end

-- The way back. Used to record the return leg of a step we just took, which
-- the MUD confirms by listing that direction in the room we land in.
nav.OPPOSITE = {
    n = "s", s = "n", e = "w", w = "e",
    ne = "sw", sw = "ne", nw = "se", se = "nw",
    u = "d", d = "u",
}

nav.STEP = {
    n  = {  0, -1,  0 },
    s  = {  0,  1,  0 },
    e  = {  1,  0,  0 },
    w  = { -1,  0,  0 },
    ne = {  1, -1,  0 },
    nw = { -1, -1,  0 },
    se = {  1,  1,  0 },
    sw = { -1,  1,  0 },
    u  = {  0,  0,  1 },
    d  = {  0,  0, -1 },
}

-- Every area the 'areas' command lists, so the picker can offer a name
-- before a single room of it has been walked, with the power range the MUD
-- gives for it. Ranges are its own shorthand kept verbatim -- '*' means no
-- ceiling, and turning that into a number would only lose it.
--
-- Captured 2026-08-13. Anything walked that is not on this list still works;
-- the list is a convenience, not a whitelist.
local KNOWN_AREAS = {
    { "Kami's Lookout", "Earth", "Sol System", "145m", "100b" },
    { "Roshi's Island", "Earth", "Sol System", "15k", "6b" },
    { "Gero's Lab", "Earth", "Sol System", "1", "6b" },
    { "South City", "Earth", "Sol System", "1", "50k" },
    { "Satan City", "Earth", "Sol System", "100k", "10m" },
    { "Western Desert", "Earth", "Sol System", "200k", "20t" },
    { "Capsule Corporation", "Earth", "Sol System", "100m", "25b" },
    { "Ancient Lab Basement", "Earth", "Sol System", "1b", "125b" },
    { "Western Forest", "Earth", "Sol System", "1m", "100m" },
    { "North City", "Earth", "Sol System", "500k", "15t" },
    { "Zobraizubre Mountains", "Earth", "Sol System", "100m", "50b" },
    { "C.C. Hologram Room", "Earth", "Sol System", "8b", "50t" },
    { "The Dead Zone", "Earth", "Sol System", "2t", "20t" },
    { "Piccolo's Wilderness", "Earth", "Sol System", "1k", "100k" },
    { "West City", "Earth", "Sol System", "20m", "500m" },
    { "Jingle Village", "Earth", "Sol System", "50m", "1b" },
    { "CCARRF: Tree Of Might", "Earth", "Sol System", "1m", "100m" },
    { "CCARRF: Super Android 13", "Earth", "Sol System", "10b", "300b" },
    { "Overlord's Lookout", "Earth", "Sol System", "1t", "10t" },
    { "Sector Eight", "Earth", "Sol System", "50m", "500m" },
    { "Bear Forest", "Earth", "Sol System", "1", "*" },
    { "Gin Mountains", "Earth", "Sol System", "50k", "1m" },
    { "CCARRF: Fusion Reborn", "Earth", "Sol System", "15t", "25t" },
    { "Dark Future", "Earth", "Sol System", "250b", "6t" },
    { "Makyo Castle", "Earth", "Sol System", "10", "5t" },
    { "LEGENDE", "LEGENDE", "LEGENDE", "1", "*" },
    { "Soltari City", "Vegeta", "Vegeta System", "1", "14b" },
    { "Castle Vegeta", "Vegeta", "Vegeta System", "20m", "500m" },
    { "Yasai Jungle", "Vegeta", "Vegeta System", "1b", "35b" },
    { "Yasai City", "Vegeta", "Vegeta System", "10b", "125b" },
    { "Kanassa", "Kanassa", "Vegeta System", "1m", "62b" },
    { "Crystal Rainforest", "Kanassa", "Vegeta System", "50b", "10t" },
    { "Warpcrystal Swamp", "Kanassa", "Vegeta System", "50b", "1t" },
    { "The Big Geti Star", "Namek", "Namek System", "1t", "15t" },
    { "Planet Namek", "Namek", "Namek System", "1", "50k" },
    { "Eternal Dragon Temple", "Namek", "Namek System", "1b", "10b" },
    { "Maima Region", "Namek", "Namek System", "150m", "2b" },
    { "Namekian Wilds", "Namek", "Namek System", "25t", "50t" },
    { "Namek Village", "Namek", "Namek System", "1", "*" },
    { "Mount Areukk", "Furiza", "Furiza System", "400m", "45b" },
    { "Frieza's Castle", "Furiza", "Furiza System", "25b", "250b" },
    { "Icerian Proving Grounds", "Furiza", "Furiza System", "100", "1m" },
    { "Vendetta Spacestation", "Furiza", "Furiza System", "200b", "2t" },
    { "The Ginyu Base", "Furiza", "Furiza System", "1k", "1b" },
    { "Skybase Tempest", "Furiza", "Furiza System", "100b", "500b" },
    { "Hrimfaxi's Evergaol", "Furiza", "Furiza System", "75b", "12t" },
    { "Yardrat Temple", "Yardrat", "Yardrat", "25m", "1b" },
    { "Temple Village", "Yardrat", "Yardrat", "25m", "100m" },
    { "Yardrat Moon", "Yardrat", "Yardrat", "25m", "1b" },
    { "Yardrat Forest", "Yardrat", "Yardrat", "1", "*" },
    { "Primrose Desert", "Hydia", "Hydia", "150b", "300b" },
    { "Rose City", "Hydia", "Hydia", "100b", "10t" },
    { "Underground Base", "Hydia", "Hydia", "100m", "250m" },
    { "The Lotus Temple", "Hydia", "Hydia", "1m", "100m" },
    { "Hydian Rebel Base", "Hydia", "Hydia", "100k", "50m" },
    { "A Devastated Garden", "Hydia", "Hydia", "1", "*" },
    { "Feldron", "Hydia", "Hydia", "100m", "1b" },
    { "The Polluted Delta", "Hydia", "Hydia", "1b", "20b" },
    { "The Neon Abyss", "Hydia", "Hydia", "12b", "70b" },
    { "Dr. Myuu's Lab", "Plant", "Plant", "120b", "2t" },
    { "Crimson City", "Shadow Earth", "Shadow System", "500k", "50m" },
    { "Shadowbrook", "Shadow Earth", "Shadow System", "50m", "300m" },
    { "Darkhaven", "Shadow Earth", "Shadow System", "10k", "1m" },
    { "Majin Wasteland", "Shadow Earth", "Shadow System", "10m", "500m" },
    { "Snake Way", "Afterlife", "Afterlife System", "3m", "15t" },
    { "Grand Kai's Planet", "Afterlife", "Afterlife System", "8t", "15t" },
    { "Yemma's Vault", "Afterlife", "Afterlife System", "1b", "25b" },
    { "Vessen Village", "Afterlife", "Afterlife System", "1t", "25t" },
    { "Planet of the Kais", "Afterlife", "Afterlife System", "1t", "10t" },
    { "Bibidi's Stronghold", "Afterlife", "Afterlife System", "1", "*" },
    { "Planet EvE", "EvE", "EvE", "1t", "10t" },
    { "Kayin", "Konats", "Melody System", "1", "*" },
    { "Sonata Mountains", "Konats", "Melody System", "100k", "5t" },
    { "Burgundy Village", "Concordia", "Concordia", "1", "*" },
    { "Relok", "Relok", "Yond", "100", "4b" },
}

----------------------------------------------------------------------
-- state
----------------------------------------------------------------------

local ready = false
-- What the plugin does with what it goes past.
--
--   record  follow you and write it all down. The normal state.
--   follow  keep the @ moving and write NOTHING -- no rooms, no exits, no
--           stubs, no doors, no terrain, no areas.
--   off     ignore the world entirely.
--
-- 'follow' exists because 'off' was the only way to stop a map growing, and it
-- also stopped the panel being any use: walking around a finished area with
-- recording off left the @ parked wherever it was last written down.
local mode = "record"

local function recording() return mode == "record" end
local function watching() return mode ~= "off" end

-- Where a map with nothing in it starts recording. LEGENDE because that is the
-- MUD's own level-one area, so it is where a new character actually is -- the
-- default used to be 'Ginyu Base', which is where the author happened to be
-- standing and meant a stranger's first rooms were filed under somebody else's
-- planet.
--
-- It is still a guess, and the MUD never says which area you are in, so the
-- first run says so out loud rather than letting it pass for knowledge.
local START_AREA = "LEGENDE"

local area = START_AREA       -- the current planet; areas are just strings

-- No area has ever been recorded into this map, so the one above is a guess
-- rather than something we were told. Set while the map is being adopted and
-- read once it is warm, to say so.
local firstRun = false
local bases = {}              -- area -> the vnum block it allocates from

-- Commands proven to travel, because 'dbgo' was used on them. Nothing else is
-- allowed to be a special exit, and anything in the map that is not in here is
-- wreckage from when travel was inferred rather than declared.
local travels = {}
local BLOCK = 10000
local FIRST_BLOCK = 10000

-- Where we are and how we got here: the current vnum and its hash, the room
-- we came from and the direction we came by, and whether the next room line
-- should be expecting an exits line.
--
-- Not 'at' or 'here' -- both are locals elsewhere in this file, and a
-- file-scope name a function shadows is one that function cannot reach.
local whereAt = {}

whereAt.vnum = nil
whereAt.hash = ""
-- Everything waiting on the next room line, in one place.
--
-- These were seven file-scope locals split across lines 222 and 3150, which
-- is a thousand lines apart for one lifecycle -- and this chunk is one local
-- from Lua's 200 ceiling, where a 'local' at file scope is one of the 200
-- whether it holds a number or a function.
--
--   cmd      the last compass step typed, waiting for a room
--   at       when it was typed
--   travel   an explicit 'dbgo', armed for exactly one room
--   warp     a move nobody typed, holding why. Dying is one: 'Nappa slays
--            you in cold blood!' then a misty void, Arrival, Waiting in Line
--            and King Yemma's Office -- four rooms of afterlife filed into
--            the Ginyu Base because nothing said otherwise. Asking Yemma to
--            send you home is the same thing in reverse.
--   doors    what the last snapshot said about doors
--   terrain  and about terrain
--   near     sectors read off the cells around the anchor
--
-- The last three are held for the same reason as the first four: the snapshot
-- arrives BEFORE the room line, so reading it and writing straight away put
-- every room's doors onto the room we had just left -- 10021, 10022 and 10023
-- all ended up with the one door that belongs to 10022 alone.
local pend = { cmd = nil, at = 0, travel = nil, warp = nil,
               doors = nil, terrain = nil, near = nil }
whereAt.wantExits = false

-- How we got into the room we are in, so the exits line that follows can close
-- the loop and record the way back.
whereAt.from = nil
whereAt.by = nil

-- A command only counts as a move if the room line follows it more or less
-- immediately. The training bot walks with send(), which never reaches
-- onCommand, so without this the direction you typed minutes ago gets credited
-- for a step the bot took.
local STALE = 2

-- onCommand is documented as "player typed a command", which is why the
-- training bot's send() is invisible to it. onSend is documented as "text about
-- to be sent to the MUD" with no such qualifier, but the guide does not say
-- whether it fires for text another plugin sent. These two counters answer that
-- from the client rather than from the document: run the bot, read 'dbmap'.
local sawCommands = 0
local sawSends = 0
local lastError = "none"

-- The client's own map panel centres on the room GMCP says you are in, and this
-- MUD sends no GMCP at all, so it has no idea where we are and sits on its
-- "start exploring" placeholder however many rooms the database holds. There is
-- no call to tell it -- getPlayerRoom is read-only in the API. A mapper widget
-- Everything about how the map is being LOOKED at, in one table.
--
-- Twelve file-scope locals, and a file-scope local is one of Lua's 200
-- whether it holds a number or a function. The comments stay where they were
-- written: each one still sits over the thing it explains, and only the name
-- on the left changed.
local view = {}

-- pinned with lockedArea draws the area regardless of the player's location,
-- which is the documented way out of exactly this.
view.id = nil

-- Shown unless it was hidden. A map plugin whose map is off by default is a
-- map plugin that looks broken on the first run.
view.want = true

-- Which picture the panel draws.
--
--   area  -- every room in the area at its stored coordinates. The whole thing
--            at once, which is what you want for getting your bearings, and
--            what goes wrong when a ring cannot hold its own interior.
--   local -- laid out fresh by walking exits outward from the room you are in,
--            ignoring stored coordinates entirely. Always readable, because a
--            small neighbourhood almost never contradicts itself, but it only
--            shows what is near you.
--
-- Both, because neither answers the other's question. Area is the default: it
-- is the whole map, and seeing all of it is usually the point.
view.mode = "area"

-- Where the panel is looking, as an offset from the room you are standing in.
-- Zero on all three means centred on you, which is the normal state.
--
-- Deliberately NOT saved. Walking resets it, and a look-around that survived a
-- relaunch would open the panel pointing at nothing with no clue why.
--
-- Area view only. Local view lays the neighbourhood out by walking exits
-- outward from where you are, so there is no coordinate to offset and no way to
-- reach a floor you are not on.
view.off = { x = 0, y = 0, z = 0 }

-- Drag-to-pan, so the map is pulled around like a paper one.
--
-- The work is turning pixels into rooms. A room is dist coordinate units wide
-- and the grid is (RADIUS*2+1) units across, so one room is that fraction of
-- the grid's edge -- and the redraw happens once per room CROSSED rather than
-- once per mouse event, because every redraw is a round trip out to Lua and
-- back and mousemove fires continuously.
view.drag = { on = false, x = 0, y = 0 }

-- Measured rather than asked for: widgetInfo lied about the panel size, so this
-- comes off the resize event and starts at whatever the widget was made with.
view.px = { w = 320, h = 340 }

-- The grid is a square that fits inside what is left after the head and the
-- foot, so the smaller axis sets its edge. Approximate on purpose -- this only
-- decides how far a drag travels, and being a few pixels out is invisible.
local function gridEdgePx()
    local w = view.px.w - 12
    local h = view.px.h - 70
    if w < 40 then w = 40 end
    if h < 40 then h = 40 end
    if w < h then return w end
    return h
end

local function viewCentred()
    return view.off.x == 0 and view.off.y == 0 and view.off.z == 0
end

local function recentre()
    view.off.x = 0
    view.off.y = 0
    view.off.z = 0
end

-- How many rooms out the panel draws, which is what zooming changes. Fewer
-- rooms, bigger rooms.
-- Rooms out from you, so a low number is zoomed IN. One shows you and your
-- immediate neighbours filling the panel; twenty-five is most of an area at
-- a few pixels a room.
view.ZOOM = { min = 1, max = 25 }
view.zoom = 7

-- The picker, when the area name in the footer is clicked. Its own state
-- rather than a mode of the map, because it replaces the map while it is up.
-- Which overlay is over the map, if any: "pick" or "settings".
view.overlay = nil
view.filter = ""

-- Writes land in the database without the panel noticing. refreshMap makes it
-- re-read; only worth doing when something actually changed.
view.dirty = false

-- Vnums in the order we minted them, newest last. Dying teleports you somewhere
-- with no command behind it, so the rooms on the far side get filed under
-- whatever area was current -- Snake Way ending up inside the Ginyu Base. This
-- is what lets 'dbmap take' pull them back out afterwards.
local recent = {}
local RECENT_MAX = 200

-- Vnums from the last 'dbmap find', so 'dbmap moveto' has something precise to
-- act on. Needed because 'take' is useless for rooms recorded before a reload.
local lastFind = {}

local st = { rooms = 0, exits = 0, stubs = 0, specials = 0, seen = 0 }

----------------------------------------------------------------------
-- value hygiene, same reasons as the rest of the set
----------------------------------------------------------------------

-- A number, or nil. Whitelist, not blacklist -- which is what CLAUDE.md says to
-- do with any value that has crossed the boundary, and what this did not do.
--
-- tonumber is JavaScript's Number() here, and Number() has opinions Lua does
-- not share:
--
--   Number("")     is 0      -- an empty capture from a failed string.match
--   Number(null)   is 0      -- and Lua's nil arrives as null
--   Number("35")   is 35     -- fine
--   Number("e4")   is NaN    -- and NaN is TRUTHY, so 'if n then' passes it
--
-- The second one is the nastiest: safeNum(nil) returned a real zero, so
-- 'safeNum(textOf(missing))' produced 0 rather than nil no matter how carefully
-- the capture had been normalised first. 'dbmap ground inside' was read as the
-- vnum range 0-0 because of it.
--
-- So nothing is converted unless it is already a number, or a string with
-- something in it.
local function safeNum(v)
    local t = type(v)

    if t == "number" then
        if v ~= v then return nil end
        return v
    end
    if t ~= "string" then return nil end
    if v == "" then return nil end

    local n = tonumber(v)
    if n == nil then return nil end
    if n ~= n then return nil end
    return n
end

local function trimBoth(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function say(msg, colour)
    echo(TAG .. msg, colour or "#7fb2ff")
end

-- Looked up through _G: a global this build does not have throws on the way IN,
-- where a pcall around the call cannot catch it.
local function callable(name)
    local ok, fn = pcall(function() return _G[name] end)
    if ok and type(fn) == "function" then return fn end
    return nil
end

-- Every mapper call goes through here. Reads are only valid once the map is
-- warm, and a write before then lands nowhere; both are documented and both
-- fail quietly rather than erroring, which is the worst way for a map to be
-- wrong.
-- Arity written out rather than forwarded.
--
-- This was 'pcall(fn, ...)' and the varargs did not survive: every call
-- received ONE JavaScript Arguments object instead of its parameters. So
-- nextFreeRoomId ignored its hint and answered 1, addMapRoom refused the
-- nonsense it was handed, and addAreaName created an area named
-- '[object Arguments]'. Three symptoms, one line.
--
-- pcall gets a closure for the same reason: passing the arguments THROUGH
-- pcall is the thing that breaks.
local function mapCall(name, a, b, c)
    if not ready then return nil end
    local fn = callable(name)
    if not fn then
        lastError = name .. " is not in this build"
        return nil
    end

    local ok, res
    if c ~= nil then
        ok, res = pcall(function() return fn(a, b, c) end)
    elseif b ~= nil then
        ok, res = pcall(function() return fn(a, b) end)
    elseif a ~= nil then
        ok, res = pcall(function() return fn(a) end)
    else
        ok, res = pcall(function() return fn() end)
    end

    if not ok then
        lastError = name .. ": " .. tostring(res)
        return nil
    end
    return res
end

-- A capture that is really there, or nil. Nothing else.
--
-- A failed string.match does not hand back nil here. It hands back undefined,
-- or an EMPTY STRING, and both of those are truthy -- so 'if not x' does not
-- fire on either and 'x or ""' keeps them.
--
-- The empty string is the nastier of the two, because it survives every type
-- check and only falls over when something finally uses it: 'dbmap nudge n'
-- read as the vnum range 0-0, because the range pattern missed, handed back
-- "" for both numbers, and tonumber("") is 0 here rather than nil.
--
-- An empty capture means the pattern did not match. It is nil.
--
-- NOT called 'word'. Two branches of the dbmap handler declare a local by that
-- name, and this runtime gives a function ONE scope for them: referring to the
-- file-scope helper from a third branch in between resolved to that local
-- before it was initialised, and threw "Can't find variable: word". A
-- file-scope helper must not share a name with any local anywhere.
local function textOf(v)
    if type(v) ~= "string" then return nil end
    if v == "" then return nil end
    return v
end

-- A keyed table from the other side, copied into one of ours before anything
-- walks it.
--
-- 'type(v) == "table"' is not enough on its own. A value can pass that and
-- still not be something pairs() can walk, and pairs() on it transpiles to
-- Object.keys(undefined), which THROWS -- taking the whole panel with it, where
-- a miss would have cost nothing. Copying inside a pcall turns that into an
-- empty table.
local function safeMap(v)
    local out = {}
    if type(v) ~= "table" then return out end
    pcall(function()
        for k, val in pairs(v) do out[k] = val end
    end)
    return out
end

----------------------------------------------------------------------
-- persistence
----------------------------------------------------------------------

-- Everything the plugin knows that is ABOUT the map goes into the map, not into
-- plugin prefs. Area and map user data ride along in exportMapJson, so a map
-- handed to someone else arrives complete: they get the vnum block each area
-- allocates from and the verbs that count as travel, and their copy behaves
-- like ours without a single setting being copied across.
--
-- Prefs are still written as a mirror. They are what survives if the map is
-- ever replaced out from under us, and they cost nothing.
--
-- Values are coerced to strings on the way in, so everything comes back as one.
local function mapPut(key, value)
    mapCall("setMapUserData", key, value)
end

local function mapGet(key)
    local v = mapCall("getMapUserData", key)
    if type(v) ~= "string" or v == "" then return nil end
    return v
end

local function publishArea(name)
    local block = bases[name]
    if block then mapCall("setAreaUserData", name, "dbmap.base", tostring(block)) end
end

-- Everything the map is DRAWN with, in one table: the sector palette, the
-- style and sector lookups built from it, the hex table, the stylesheet, the
-- flag prefixes and their looks, the fallback grey, the panel background and
-- the door cells.
--
-- Ten file-scope locals for one subject, and a file-scope local is one of
-- Lua's 200 whether it holds a number or a stylesheet.
local paint = {}

-- The server's own sector palette, captured 2026-08-13 from Map.Definition.
--
-- Baked in because the definition only arrives if Scouter is running -- the
-- Mapper deliberately never negotiates that package -- and the settings pane
-- needs a default to show either way. A live Map.Definition always wins over
-- this; it is the floor, not the answer.
paint.DEFAULT = {
    air = "#008080", barren = "#808000", blands = "#800000", bridge = "#ff00ff",
    city = "#c0c0c0", desert = "#ffff00", exit = "#ffffff", field = "#00ff00",
    forest = "#008000", glacier = "#ffffff", grassland = "#00ff00",
    hills = "#808000", ice = "#ffffff", inside = "#808080", jungle = "#008000",
    lava = "#ff0000", mountain = "#c0c0c0", ocean = "#5f87ff",
    oceanfloor = "#5f87ff", overland = "#00ff00", quicksand = "#008000",
    river = "#00afaf", road = "#ffff00", scrub = "#008000", shore = "#ffff00",
    space = "#808080", stone = "#ffffff", swamp = "#008000", trail = "#808000",
    tree = "#008000", tundra = "#00ffff", underground = "#808080",
    underwater = "#0087ff", unknown = "#808080", wall = "#ff00ff",
    water_noswim = "#005faf", water_swim = "#00ffff",
}

-- The server's live palette, filled from Map.Definition when Scouter's
-- handshake brings one in. Empty until then, which is exactly why DEFAULT_SECTOR
-- above exists.
paint.style = {}

-- Colours chosen here, overriding the server's for that sector. Kept in map
-- user data rather than plugin prefs: prefs do not survive a reinstall -- the
-- client keys them by a runtime id -- and these are meant to outlive updates.
paint.sector = {}

-- '#rrggbb' to 'r,g,b', by position rather than by pattern. %x is not on the
-- list of classes this runtime's pattern translation survives, and a colour
-- parser that silently stops matching would tint the whole map wrong.
-- Hex by hand, digit by digit.
--
-- tonumber(s, 16) does NOT read base 16 here. The base argument is dropped and
-- it behaves as Number(s), so "35" came back as thirty-five rather than
-- fifty-three, and "e4" -- and every pair with a letter in it -- came back NaN.
-- NaN is truthy, so 'if not r' waved it through and the panel emitted
-- 'rgb(35,84,NaN)'.
--
-- Which meant sector colouring never worked either, except by accident: the
-- only hexes that survived were ones like #808080 whose pairs happen to be
-- decimal digits, and those rendered as the wrong grey rather than as nothing.
paint.HEX = {
    ["0"] = 0, ["1"] = 1, ["2"] = 2, ["3"] = 3, ["4"] = 4,
    ["5"] = 5, ["6"] = 6, ["7"] = 7, ["8"] = 8, ["9"] = 9,
    ["a"] = 10, ["b"] = 11, ["c"] = 12, ["d"] = 13, ["e"] = 14, ["f"] = 15,
}

local function hexPair(s)
    if type(s) ~= "string" or #s ~= 2 then return nil end
    local hi = paint.HEX[s:sub(1, 1):lower()]
    local lo = paint.HEX[s:sub(2, 2):lower()]
    if hi == nil or lo == nil then return nil end
    return hi * 16 + lo
end

local function rgbOf(hex)
    if type(hex) ~= "string" or #hex < 7 then return nil end
    if hex:sub(1, 1) ~= "#" then return nil end

    local r = hexPair(hex:sub(2, 3))
    local g = hexPair(hex:sub(4, 5))
    local b = hexPair(hex:sub(6, 7))
    if r == nil or g == nil or b == nil then return nil end
    return r .. "," .. g .. "," .. b
end

-- The strip under the map naming what each symbol means. On once there is more
-- than one symbol to tell apart; every flag that draws a glyph gets a line.
view.legend = true

-- 'sector=#rrggbb' a line at a time. A flat string rather than a table because
-- mapPut stores strings, and one line per sector diffs readably if anyone ever
-- looks at the map file by hand.
local function publishColours()
    local out = {}
    for sector, hex in pairs(paint.sector) do
        if type(sector) == "string" and type(hex) == "string" and hex ~= "" then
            out[#out + 1] = sector .. "=" .. hex
        end
    end
    table.sort(out)
    mapPut("dbmap.colours", table.concat(out, "\n"))
end

local function readColours(blob)
    paint.sector = {}
    if type(blob) ~= "string" or blob == "" then return end

    for line in blob:gmatch("[^\n]+") do
        -- '%S' is one of the four classes that survive the pattern translation,
        -- and a sector name never has a space in it
        local sector, hex = line:match("^(%S+)=(%S+)$")
        -- checked on the way in, not only on the way out: this ends up inside a
        -- stylesheet and a map file can be edited by hand
        if sector and rgbOf(hex) then paint.sector[sector:lower()] = hex end
    end
end

local function publishTravels()
    local verbs = {}
    for cmd in pairs(travels) do verbs[#verbs + 1] = cmd end
    table.sort(verbs)
    mapPut("dbmap.travels", table.concat(verbs, "\n"))
end

local function savePrefs()
    saveTable("dbi-mapper-prefs", {
        area = area,
        bases = bases,
        travels = travels,
        recent = recent,
        distx = nav.dist.x,
        disty = nav.dist.y,
        mode = mode,
        widget = view.want and "yes" or "no",
        view = view.mode,
        zoom = view.zoom,
        stats = st,
    }, "global")

    publishColours()
    mapPut("dbmap.distance", nav.dist.x .. "," .. nav.dist.y)
    mapPut("dbmap.area", area)
    mapPut("dbmap.panel", view.want and "yes" or "no")
    mapPut("dbmap.here", whereAt.hash)
    mapPut("dbmap.zoom", tostring(view.zoom))
    mapPut("dbmap.view", view.mode)
    mapPut("dbmap.legend", view.legend and "yes" or "no")
    mapPut("dbmap.on", mode)
end

-- Read back what the map itself knows. Called once the map is warm, and it wins
-- over prefs: an imported map carries the truth about its own vnum blocks, and
-- a fresh install has no prefs at all.
local function adoptFromMap()
    local said = mapGet("dbmap.distance")
    if said then
        -- one number is the old form, both axes
        local dx, dy = said:match("^(%d+),(%d+)$")
        if not dx then dx, dy = said, said end
        local nx, ny = safeNum(dx), safeNum(dy)
        if nx and nx >= 1 and nx <= 8 then nav.dist.x = math.floor(nx) end
        if ny and ny >= 1 and ny <= 8 then nav.dist.y = math.floor(ny) end
    end

    -- Plugin prefs do not survive a reinstall: the client keys them by a
    -- runtime id and a hand-dropped copy gets a new one, so everything came
    -- back at its default. The map outlives all of that, so what we were doing
    -- lives there too.
    -- Both branches assigned. Setting the flag on the way in and never clearing
    -- it meant a second warm of the same map greeted again, on a map that had
    -- long since been told what it is.
    readColours(mapGet("dbmap.colours"))

    local wasArea = mapGet("dbmap.area")
    if wasArea then
        area = wasArea
        firstRun = false
    else
        firstRun = true
    end

    local panel = mapGet("dbmap.panel")
    if panel == "no" then view.want = false
    elseif panel == "yes" then view.want = true end

    local z = safeNum(mapGet("dbmap.zoom"))
    if z and z >= view.ZOOM.min and z <= view.ZOOM.max then view.zoom = math.floor(z) end

    local lg = mapGet("dbmap.legend")
    if lg == "no" then view.legend = false
    elseif lg == "yes" then view.legend = true end

    local vm = mapGet("dbmap.view")
    if vm == "area" or vm == "local" then view.mode = vm end

    -- NOT called 'on': a local of that name takes the global on() down for
    -- the whole file. Nothing here calls on(), and this keeps it that way on
    -- purpose rather than by luck.
    local want = mapGet("dbmap.on")
    -- 'yes' and 'no' are what versions before the third mode wrote.
    if want == "record" or want == "follow" or want == "off" then mode = want
    elseif want == "no" then mode = "off"
    elseif want == "yes" then mode = "record" end

    -- Where we were standing. The hash is bound to a vnum in the map, so this
    -- survives anything short of deleting the room -- and the next room line
    -- confirms or corrects it, so being wrong costs one step's edge.
    local wasHash = mapGet("dbmap.here")
    if wasHash and wasHash ~= "" then
        local known = safeNum(mapCall("getRoomIDbyHash", wasHash))
        if known and known >= 0 then
            whereAt.vnum = known
            whereAt.hash = wasHash
        end
    end

    local verbs = mapGet("dbmap.travels")
    if verbs then
        for cmd in verbs:gmatch("[^\n]+") do travels[cmd] = true end
    end

    -- The vnum block per area, and a floor under it. A block read from the map
    -- can still be behind what is actually in there -- someone else's map, or
    -- prefs that went missing -- so the highest vnum an area holds sets the
    -- minimum. Getting this wrong mints a room on top of one already there.
    local list = mapCall("getAreaList")
    if type(list) ~= "table" then return end

    for name in pairs(list) do
        local said = safeNum(mapCall("getAreaUserData", name, "dbmap.base"))
        local highest = nil
        local rooms = mapCall("getAreaRooms", name)
        if type(rooms) == "table" then
            for _, raw in ipairs(rooms) do
                local vnum = safeNum(raw) or raw
                local n = safeNum(vnum)
                if n and (not highest or n > highest) then highest = n end
            end
        end

        local block = said or bases[name]
        if highest then
            local floorBlock = math.floor(highest / BLOCK) * BLOCK
            if not block or block < floorBlock then block = floorBlock end
        end
        if block then
            bases[name] = block
            publishArea(name)
        end
    end

    -- Mirror what we just adopted, so prefs and the map agree rather than
    -- fighting the next time either is read.
    savePrefs()
end

local function loadPrefs()
    local p = loadTable("dbi-mapper-prefs", "global")
    if type(p) ~= "table" then return end

    -- one field at a time: a value arriving as undefined must not take the
    -- others with it
    if type(p.area) == "string" and p.area ~= "" then area = p.area end
    -- A base that is not a number poisons the next allocation: the rename left
    -- 'Ginyu Base' = null behind, and null crossing back arrives as something
    -- that is neither nil nor a number.
    if type(p.bases) == "table" then
        for name, b in pairs(p.bases) do
            if safeNum(b) then bases[name] = safeNum(b) end
        end
    end
    local px, py = safeNum(p.distx), safeNum(p.disty)
    if px and px >= 1 and px <= 8 then nav.dist.x = math.floor(px) end
    if py and py >= 1 and py <= 8 then nav.dist.y = math.floor(py) end

    -- Survives a reload, so 'take' still works on rooms recorded before one.
    if type(p.recent) == "table" then
        for _, v in ipairs(p.recent) do
            local n = safeNum(v)
            if n then recent[#recent + 1] = n end
        end
    end
    if type(p.travels) == "table" then
        for cmd, on in pairs(p.travels) do
            if on and type(cmd) == "string" then travels[cmd] = true end
        end
    end
    if p.mode == "record" or p.mode == "follow" or p.mode == "off" then
        mode = p.mode
    elseif p.enabled == "no" then
        mode = "off"
    end
    if p.widget == "yes" then view.want = true end
    if p.view == "local" or p.view == "area" then view.mode = p.view end
    local z = safeNum(p.zoom)
    if z and z >= view.ZOOM.min and z <= view.ZOOM.max then view.zoom = math.floor(z) end
    if type(p.stats) == "table" then
        for _, k in ipairs({ "rooms", "exits", "stubs", "specials", "seen" }) do
            local n = safeNum(p.stats[k])
            if n then st[k] = n end
        end
    end
end

-- Each planet gets its own block of vnums, so a room number says where it is
-- without looking anything up. 10,000 apiece is far more than enough: the
-- whole Ginyu base is 149 rooms.
local function baseFor(name)
    if bases[name] then return bases[name] end
    local highest = FIRST_BLOCK - BLOCK
    for _, b in pairs(bases) do
        local n = safeNum(b)
        if n and n > highest then highest = n end
    end
    bases[name] = highest + BLOCK
    publishArea(name)
    savePrefs()
    return bases[name]
end

----------------------------------------------------------------------
-- rooms
----------------------------------------------------------------------

-- 'Stronghold -- Cadet Quarters [R#-wV2XH0Mh]'
--
-- '%S+' rather than a character class with a range in it. A range inside a
-- class does not survive this runtime's pattern translation, and the id
-- contains a hyphen, which is exactly the case that breaks.
local function readRoomLine(line)
    local text = trimBoth(line)
    local hash = text:match("%[R#(%S+)%]")
    if not hash then return nil, nil end
    local name = trimBoth(text:match("^(.+)%[R#") or "")
    return hash, name
end

-- Where every room in the current area sits, keyed "x,y,z". Built once and
-- reused: placement and drawing both want it, and asking the map for every room
-- on every step was a sweep per move that grew with the map.
-- The position index and what it holds. Named 'place' because 'pos' is
-- already a local in takeRooms.
local place = {}

place.index = nil

-- Which floors this area actually has, collected while the index is built
-- because that pass already reads every room's z. Sorted low to high, so the
-- layer buttons know where the stack ends.
place.floors = nil

-- Which sectors this area actually contains, collected in the same pass. The
-- MUD names forty-one of them and a settings pane listing all forty-one in a
-- 320px panel is a wall; the handful you have actually walked is a list.
place.terrains = nil

local function forgetPositions()
    place.index = nil
    place.floors = nil
    place.terrains = nil
end

local function positions()
    if place.index then return place.index end
    place.index = {}
    place.floors = {}
    place.terrains = {}

    local seenT = {}
    local seen = {}
    local list = mapCall("getAreaRooms", area)
    if type(list) ~= "table" then return place.index end

    for _, raw in ipairs(list) do
        -- safeNum, because a vnum crossing back can be a string, and then
        -- 'vnum == hereVnum' is "10000" == 10000, which is false. That is why
        -- the room you were standing in drew as an ordinary room for four
        -- versions: it never matched, so it never got the @.
        local vnum = safeNum(raw) or raw
        local r = mapCall("getMapRoom", vnum)
        if type(r) == "table" then
            local x, y, z = safeNum(r.x), safeNum(r.y), safeNum(r.z)
            if x and y and z then
                place.index[x .. "," .. y .. "," .. z] = vnum
                if not seen[z] then
                    seen[z] = true
                    place.floors[#place.floors + 1] = z
                end
            end

            -- 'default' is what the client returns for a room whose terrain
            -- was never written. It is the absence of a sector, so it does not
            -- belong in a list of sectors to colour.
            local t = r.terrain
            if t == "default" then t = nil end
            if type(t) == "string" and t ~= "" and not seenT[t] then
                seenT[t] = true
                place.terrains[#place.terrains + 1] = t
            end
        end
    end
    table.sort(place.floors)
    table.sort(place.terrains)
    return place.index
end

-- Every sector there is, whether or not this map has met one.
--
-- Compiled in rather than discovered: the sector list used to come out of the
-- rooms, which meant it came out of GMCP, which meant an install without
-- Scouter had nothing to configure and everyone else could only set a colour
-- for somewhere they had already walked. The list is a known quantity -- the
-- MUD has forty-one and they do not change -- so it is written down.
--
-- Anything the server names that is not in the table still appears, because a
-- new sector on the server should show up here rather than be invisible.
local function sectorList()
    local seen, out = {}, {}
    local function put(name)
        if type(name) == "string" and name ~= "" and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end

    for name in pairs(paint.DEFAULT) do put(name) end
    for name in pairs(paint.style) do
        if type(name) == "string" and name:sub(1, 7) == "sector." then
            put(name:sub(8))
        end
    end
    for name in pairs(paint.sector) do put(name) end

    table.sort(out)
    return out
end

-- The sectors this area contains, in name order.
local function terrains()
    positions()
    if type(place.terrains) ~= "table" then return {} end
    return place.terrains
end

-- The floors this area has, low to high. positions() fills it, so ask for the
-- index first rather than trusting whatever was left from the last area.
local function floors()
    positions()
    if type(place.floors) ~= "table" then return {} end
    return place.floors
end

-- Push every room from a line outward, opening a gap along it.
--
-- The whole area moves together, so nothing changes relative to anything else:
-- a room north of another is still north of it, every exit still points the way
-- it did, and only the distance grows. That is what lets a section fit beside
-- one already drawn instead of on top of it -- the alternative is shoving one
-- room off its square, which puts it somewhere the MUD never said it was.
local function widenAt(axis, at, sign)
    local list = mapCall("getAreaRooms", area)
    if type(list) ~= "table" then return false end

    local moved = 0
    for _, raw in ipairs(list) do
        local vnum = safeNum(raw) or raw
        local r = mapCall("getMapRoom", vnum)
        if type(r) == "table" then
            local v = safeNum(axis == "x" and r.x or r.y)
            if v and ((sign > 0 and v >= at) or (sign < 0 and v <= at)) then
                local patch = {}
                patch[axis] = v + sign * distFor(axis)
                if mapCall("updateMapRoom", vnum, patch) then moved = moved + 1 end
            end
        end
    end

    if moved > 0 then
        forgetPositions()
        view.dirty = true
    end
    return moved > 0
end

-- Lay a new room next to the one we came from. Incremental placement like every
-- automapper, which is wrong wherever the MUD's geography lies.
--
-- With one addition: if the square is taken, keep going the same way until it
-- is not. Two corridors that fold back on each other used to land on the same
-- coordinates and draw as one merged blob, which is worse than a corridor drawn
-- too long -- a wrong room in the right place reads as truth.
local function placeNear(fromVnum, dir)
    if not fromVnum or not dir then return nil, nil, nil end
    local step = nav.STEP[dir]
    if not step then return nil, nil, nil end

    local room = mapCall("getMapRoom", fromVnum)
    if type(room) ~= "table" then return nil, nil, nil end

    local x = safeNum(room.x)
    local y = safeNum(room.y)
    local z = safeNum(room.z)
    if not x or not y or not z then return nil, nil, nil end

    x, y = x + step[1] * nav.dist.x, y + step[2] * nav.dist.y
    z = z + step[3]

    local at = positions()
    if not at[x .. "," .. y .. "," .. z] then return x, y, z end

    -- Taken. Keep going the way we were walking: a corridor forced to stretch
    -- still reads as a corridor, where one bent sideways does not.
    --
    -- This used to widen the whole area on every collision, and that was wrong.
    -- The elite quarters is a fully connected grid -- every pair of rooms joined
    -- both ways diagonally -- so it collides constantly, and each collision tore
    -- another slice of the map away from the rest until it drew as separate
    -- clusters strung together by long lines. Stretching is a thing to ask for,
    -- not something to do behind your back: 'dbmap stretch'.
    local px, py = x, y
    for _ = 1, 6 do
        px, py = px + step[1] * nav.dist.x, py + step[2] * nav.dist.y
        if not at[px .. "," .. py .. "," .. z] then return px, py, z end
    end

    -- Still nothing, so take the nearest free square in any direction. Wrong,
    -- but visibly wrong beats two sections drawn on top of each other, which
    -- reads as one place with exits that go nowhere.
    for ring = 1, 6 do
        for dy = -ring, ring do
            for dx = -ring, ring do
                if math.abs(dx) == ring or math.abs(dy) == ring then
                    local nx, ny = x + dx, y + dy
                    if not at[nx .. "," .. ny .. "," .. z] then return nx, ny, z end
                end
            end
        end
    end
    return x, y, z
end

-- Crossing a special exit is the only moment the planet can change, because
-- everything else is a compass step and those stay put.
--
-- The MUD never says which area you are in -- there is no line for it that we
-- can find -- so it is worked out rather than read. Landing somewhere already
-- mapped adopts that room's area, which is what coming home through a
-- teleporter looks like. Landing somewhere new starts a provisional area, so
-- the rooms are at least not filed under the planet you just left. Name it
-- properly whenever you like with 'dbmap rename', which brings them along.
-- Instant transmission, and where each of its targets lands you.
--
-- 'help itpoints' is the MUD's own list of the mobs you can IT to and the area
-- each one is in, so this is a lookup rather than a guess about travel -- which
-- matters, because guessing at travel is what once wrote 'kill captain' into
-- the map as a teleporter.
--
-- The area names are the ones the 'areas' command uses, NOT the ones itpoints
-- prints: it says 'Snakeway' for 'Snake Way', 'Burgandy' for 'Burgundy
-- Village', and 'Temple of the Eternal Dragon' for 'Eternal Dragon Temple'.
-- Matching those up is the whole value of the table; a near-miss would file
-- rooms under an area that does not exist.
--
-- Deliberately absent:
--   Vemura     -- itpoints lists them in Feldron AND The Polluted Delta
--   Lesser     -- 'Shadow Earth' is a planet of four areas, not an area
--   3.Dabura   -- same
-- Those still read as a jump, they just have no name to offer for it. Captured
-- 2026-08-14.
local IT_POINTS = {
    ["korin"] = "Kami's Lookout", ["mustard"] = "Kami's Lookout",
    ["puar"] = "Roshi's Island",
    ["2.gero"] = "Gero's Lab", ["gero"] = "Gero's Lab",
    ["kuma"] = "Bear Forest",
    ["sal"] = "Satan City",
    ["quartermaster"] = "Western Desert",
    ["marron"] = "Capsule Corporation",
    ["bolstrom"] = "North City", ["honest"] = "North City",
    ["mike"] = "Zobraizubre Mountains",
    ["chi-chi"] = "Piccolo's Wilderness", ["sabrecat"] = "Piccolo's Wilderness",
    ["dutorim"] = "Overlord's Lookout",
    ["alice"] = "Sector Eight",
    ["matt"] = "West City",
    ["cc"] = "Gin Mountains", ["larsa"] = "Gin Mountains",

    ["tailor"] = "Soltari City",
    ["monster hunter"] = "Yasai City",

    -- itpoints writes 'Planet Namek(Namek Village)' and both are real areas;
    -- the parenthetical is the specific one, so that is what is used
    ["mephablo"] = "Namek Village",
    ["super namek"] = "The Big Geti Star",
    ["solrun"] = "Eternal Dragon Temple",
    ["maima"] = "Maima Region",

    ["tzar"] = "Mount Areukk",
    ["cybrus"] = "The Ginyu Base",

    ["volk"] = "Temple Village",
    ["greeter"] = "Yardrat Forest", ["yak"] = "Yardrat Forest",

    ["dario"] = "Rose City", ["lisa"] = "Rose City",
    ["hydian thug"] = "Underground Base",
    ["mhenlo"] = "The Lotus Temple",
    ["dumastyn"] = "Feldron",
    ["murdoc"] = "The Polluted Delta",

    ["yemma"] = "Snake Way", ["tien"] = "Snake Way", ["babidi"] = "Snake Way",
    ["olibu"] = "Grand Kai's Planet", ["pikkon"] = "Grand Kai's Planet",
    ["dreina"] = "Vessen Village",
    ["shin"] = "Planet of the Kais",

    ["merzath"] = "Relok", ["grozin"] = "Relok", ["entria"] = "Relok",

    ["legende"] = "LEGENDE",
    ["auo"] = "Kanassa", ["maku"] = "Kanassa", ["isaile"] = "Kanassa",
    ["sam"] = "Planet EvE",
    ["merloh"] = "Burgundy Village",

    -- no area by these names in the 'areas' list, so they stand as provisional
    -- names until somebody renames them
    ["spaceport"] = "Planet Plant",
    ["isaac"] = "Cordican",
}

-- 'instant', 'planewalk', and 'tesseract' for androids.
local IT_VERBS = { instant = true, planewalk = true, tesseract = true }

-- Where an instant transmission is heading, from the moment it is typed.
--
-- Not the two-second window everything else uses: the MUD aligns for about six
-- seconds on the same planet and fifteen off it, so the arrival is a long way
-- behind the command.
-- One table rather than three names: Lua 5.1 caps a chunk at 200 locals and
-- this file reached it. 'want' is the destination the command asked for, 'at'
-- when it asked, 'left' whether the MUD confirmed the jump.
local it = { want = nil, at = 0, left = false }
local IT_WINDOW = 60

-- The command says where. It does NOT say that the jump happened -- an IT can
-- fail for want of Ki, for being in combat, or for a target that is not an
-- itpoint, and none of those print anything a destination should be read from.
--
-- So the command arms the destination and the MUD's own departure line arms the
-- jump. A failed instant never prints it, which is what stops a dead attempt
-- sitting there for a minute waiting to claim the next thing that moves you.

local function areaAfterTransition(destVnum, hint)
    if destVnum then
        local room = mapCall("getMapRoom", destVnum)
        if type(room) == "table" and type(room.area) == "string" and room.area ~= "" then
            return room.area
        end
    end

    -- Somewhere new, but not unknown: an instant transmission already said
    -- which area it was aiming at.
    if type(hint) == "string" and hint ~= "" then return hint end

    local n = 1
    while bases["Unknown " .. n] do n = n + 1 end
    return "Unknown " .. n
end

local function ensureRoom(hash, name, fromVnum, dir)
    -- getRoomIDbyHash answers -1 for an unknown hash, NOT nil. Mudlet
    -- convention, and -1 is truthy in both languages this runs through -- so
    -- 'if vnum then' treats every new room as one it already has and writes
    -- the whole map into a room that does not exist.
    local vnum = safeNum(mapCall("getRoomIDbyHash", hash))
    if vnum and vnum >= 0 then
        -- a room can be renamed; the id is what identifies it
        local room = mapCall("getMapRoom", vnum)
        if type(room) == "table" and name ~= "" and room.name ~= name then
            mapCall("updateMapRoom", vnum, { name = name })
        end
        return vnum, false
    end

    local fresh = mapCall("nextFreeRoomId", baseFor(area))
    if not safeNum(fresh) then
        lastError = "nextFreeRoomId gave nothing"
        return nil, false
    end

    local x, y, z = placeNear(fromVnum, dir)
    local fields = { name = name, area = area }
    if x then
        fields.x = x
        fields.y = y
        fields.z = z
    elseif fromVnum then
        -- We know where we came from but not which way we went. A movement the
        -- plugin never saw does this -- a numpad macro, anything sent by
        -- another plugin -- and sending the room to the area's origin put it
        -- across the map from the room it is actually next to.
        --
        -- Beside the room we came from is wrong in direction and right in every
        -- other way, which beats being right about nothing.
        local from = mapCall("getMapRoom", fromVnum)
        local at = positions()
        local bx = safeNum(from and from.x) or 0
        local by = safeNum(from and from.y) or 0
        local bz = safeNum(from and from.z) or 0

        local spot = nil
        for ring = 1, 4 do
            for dy = -ring, ring do
                for dx = -ring, ring do
                    if not spot and (math.abs(dx) == ring or math.abs(dy) == ring) then
                        local px = bx + dx * nav.dist.x
                        local py = by + dy * nav.dist.y
                        if not at[px .. "," .. py .. "," .. bz] then
                            spot = { px, py, bz }
                        end
                    end
                end
            end
        end

        fields.x = spot and spot[1] or bx
        fields.y = spot and spot[2] or by
        fields.z = bz
    else
        -- The first room of an area, or the first after a reconnect: nothing to
        -- place it against at all. Laid out in a row east of the origin rather
        -- than all on it, since every one of those comes through here and
        -- stacking them drew a pile that looked like one room with impossible
        -- exits.
        local ox, tries = 0, 0
        local at = positions()
        while at[ox .. ",0,0"] and tries < 500 do
            ox = ox + nav.dist.x
            tries = tries + 1
        end
        fields.x = ox
        fields.y = 0
        fields.z = 0
    end

    if not mapCall("addMapRoom", fresh, fields) then
        lastError = "addMapRoom refused " .. tostring(fresh)
        return nil, false
    end
    mapCall("setRoomIDbyHash", fresh, hash)

    st.rooms = st.rooms + 1
    view.dirty = true
    forgetPositions()

    recent[#recent + 1] = fresh
    if #recent > RECENT_MAX then table.remove(recent, 1) end

    return fresh, true
end

----------------------------------------------------------------------
-- exits
----------------------------------------------------------------------

local function alreadyExit(vnum, dir)
    local room = mapCall("getMapRoom", vnum)
    if type(room) ~= "table" or type(room.exits) ~= "table" then return false end
    return room.exits[dir] ~= nil
end

-- Where an exit already goes, or nil. Numbers crossing the boundary have come
-- back as strings before, which is why this does not return the raw value.
local function exitLeadsTo(vnum, dir)
    local room = mapCall("getMapRoom", vnum)
    if type(room) ~= "table" or type(room.exits) ~= "table" then return nil end
    return safeNum(room.exits[dir])
end

-- Every exit the room lists that we have not walked becomes a stub: a known
-- way out with an unknown destination, which is what lets the map show there
-- is more to find rather than a dead end.
local function recordStubs(vnum, dirs)
    if not vnum then return end
    for _, d in ipairs(dirs) do
        if alreadyExit(vnum, d) then
            -- An exit AND a stub for the same direction is a contradiction, and
            -- the map was full of them: one room reported six exits and the
            -- same six as unwalked. The third argument removes a stub, which
            -- fixes the data rather than hiding it when the panel is drawn --
            -- and the data is what gets exported.
            mapCall("setExitStub", vnum, d, false)
        elseif mapCall("setExitStub", vnum, d) then
            st.stubs = st.stubs + 1
            view.dirty = true
        end
    end
end

local function recordMove(fromVnum, dir, toVnum)
    if not fromVnum or not toVnum or fromVnum == toVnum then return end

    -- Walking a corridor we already know is the normal case once an area is
    -- mapped. setMapExit takes the repeat happily and reports success, so
    -- without this the exit count climbed forever and every single step
    -- repainted the map.
    if exitLeadsTo(fromVnum, dir) == toVnum then return end

    if mapCall("setMapExit", fromVnum, dir, toVnum) then
        st.exits = st.exits + 1
        view.dirty = true

        -- By destination rather than by direction. Given a vnum it works the
        -- direction out from the two rooms and, when the far room holds the
        -- matching reverse stub, sets the return exit and clears that stub as
        -- well. One call does both ways.
        mapCall("connectExitStub", fromVnum, toVnum)
    end
end

-- A teleporter, a ship, Instant Transmission. Only ever reached from an
-- explicit 'dbgo'.
--
-- This used to be inferred: any command that was not a compass direction, with
-- a room line after it, was taken for a travel method on the theory that one
-- discovered next month would then map itself. What it actually did was believe
-- 'kill captain'. The training bot moves with send(), which never reaches
-- onCommand, so a stale command sat in hand while the bot walked -- and every
-- arrival invented an area, took a fresh 10,000-vnum block and wrote a special
-- exit named after whatever had been typed last. Six areas before it was
-- noticed. Guessing at travel is not worth that; say so with 'dbgo' instead.
local function recordTravel(fromVnum, cmd, toVnum)
    if not fromVnum or not toVnum or fromVnum == toVnum then return end

    if mapCall("addSpecialExit", fromVnum, cmd, toVnum) then
        st.specials = st.specials + 1
        view.dirty = true
        -- Now on the record as a real travel verb, which is what keeps 'dbmap
        -- clean' from taking it back out again.
        travels[cmd] = true
        publishTravels()
        say("special exit: " .. cmd .. " -> " .. tostring(toVnum), "#ffb02e")
    end
end

----------------------------------------------------------------------
-- the panel
--
-- Above arrive() because arrive() calls repaint(). A file-scope local used
-- higher up the file than its declaration resolves as a nil global here, and
-- the pcall around arrive would have swallowed it.
----------------------------------------------------------------------

local function repaint()
    if not view.dirty then return end
    view.dirty = false
    mapCall("refreshMap")
end

-- The client draws a "you are here" off the room GMCP reports, and this MUD
-- sends none, so its marker never moves. A highlight is the one mark a plugin
-- can put on a room, so this is that: clear ours, paint the room just walked
-- into. It follows you around the map. It does not scroll the view to you --
-- nothing in the API centres the map on a room -- so on an area larger than the
-- panel you still have to drag.
--
-- White because that is what this MUD's own map uses for the current room.
-- Explicitly, since highlightRoom defaults to yellow and yellow is the mob.
-- The geometry the grid is drawn on: the colour of the room you are standing
-- in, the diagonal ratio, the angles, which directions count as diagonal, and
-- where the anchor sits. Six file-scope locals, one subject.
local geo = {}

geo.HERE = "#ffffff"

local function markHere()
    if not whereAt.vnum then return end
    mapCall("unhighlightRoom")     -- no argument: only this plugin's marks
    mapCall("highlightRoom", whereAt.vnum, geo.HERE)
end

local function hideMap()
    if not view.id then return false end
    local kill = callable("destroyWidget")
    if kill then
        local id = view.id
        pcall(function() return kill(id) end)
    end
    view.id = nil
    return true
end

local function esc(s)
    local t = tostring(s or "")
    t = t:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
    return t
end


local function viewScale()
    -- one radius for both axes so the box stays square and a percentage means
    -- the same thing horizontally and vertically; the wider axis sets it, so
    -- the tighter one simply shows more rooms
    local radius = math.max(nav.dist.x, nav.dist.y) * view.zoom
    local unit = 100 / (radius * 2 + 1)
    -- rooms smaller than their spacing, so the gap between two unconnected
    -- corridors stays visible
    return radius, unit, unit * math.min(nav.dist.x, nav.dist.y) * 0.56
end
geo.ROOT2 = 1.41421356

-- Which way each exit points, and how long a step is that way. Only eight
-- angles are possible, so they are written out rather than reached for through
-- atan2 -- exact, and one less thing the transpiler can get wrong.
geo.ANGLE = {
    e = 0, se = 45, s = 90, sw = 135, w = 180, nw = 225, n = 270, ne = 315,
}
geo.DIAGONAL = { ne = true, nw = true, se = true, sw = true }

-- Colour lives in classes. The widget sanitiser strips inline colour, so a
-- style attribute carrying one arrives with the colour gone and every room
-- draws the same. Position is not colour, so it can stay inline.
paint.CSS = ".dbi-wm{height:100%;box-sizing:border-box;padding:6px;overflow:hidden;"
    .. "display:flex;flex-direction:column;container-type:size;"
    .. "background-color:#0b0f16;color:#c8d2e4;font-family:ui-monospace,monospace;}"
    -- head and foot, not hd/ft: .ft is already the colour of a room with exits
    -- left to walk, and a chrome class sharing a name with a content one has
    -- gone wrong twice in this set.
    .. ".dbi-wm .head,.dbi-wm .foot{flex:0 0 auto;box-sizing:border-box;"
    .. "text-align:center;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
    .. "border:1px solid #263049;border-radius:3px;padding:3px 6px;"
    .. "background-color:#141a28;letter-spacing:0.08em;text-transform:uppercase;}"
    .. ".dbi-wm .head{font-size:clamp(8px,4.4cqw,13px);color:#e8b45c;"
    .. "margin-bottom:5px;}"
    .. ".dbi-wm .foot{font-size:clamp(7px,3.6cqw,11px);color:#7f8ba3;"
    .. "margin-top:5px;cursor:pointer;}"
    .. ".dbi-wm .foot:hover{color:#e8b45c;border-color:#3d4a63;}"

    -- zoom, sat in the head row
    .. ".dbi-wm .bar{flex:0 0 auto;display:flex;align-items:center;gap:4px;"
    .. "margin-bottom:5px;}"
    .. ".dbi-wm .bar .head{flex:1 1 auto;min-width:0;margin-bottom:0;}"
    .. ".dbi-wm .zb{flex:0 0 auto;box-sizing:border-box;cursor:pointer;"
    .. "border:1px solid #263049;border-radius:3px;background-color:#141a28;"
    .. "color:#7f8ba3;font-size:clamp(9px,4cqw,14px);line-height:1;"
    .. "padding:3px 7px;font-family:ui-monospace,monospace;}"
    .. ".dbi-wm .zb:hover{color:#e8b45c;border-color:#3d4a63;}"

    -- the area picker, which replaces the map while it is up
    .. ".dbi-wm .pk{flex:1 1 auto;min-height:0;overflow-y:auto;"
    .. "border:1px solid #263049;border-radius:3px;background-color:#0d1220;}"
    .. ".dbi-wm .pk .row{display:flex;align-items:baseline;gap:6px;padding:3px 7px;"
    .. "cursor:pointer;border-bottom:1px solid #161d2e;"
    .. "font-size:clamp(8px,3.6cqw,12px);}"
    .. ".dbi-wm .pk .row:hover{background-color:#182036;}"
    .. ".dbi-wm .pk .an{flex:1 1 auto;color:#c8d2e4;overflow:hidden;"
    .. "text-overflow:ellipsis;white-space:nowrap;}"
    .. ".dbi-wm .pk .here{color:#e8b45c;}"
    .. ".dbi-wm .pk .mapped{color:#8fd18f;}"
    .. ".dbi-wm .pk .pl{flex:0 0 auto;color:#5f6b80;font-family:ui-monospace,monospace;}"
    .. ".dbi-wm .pk .wh{flex:0 0 auto;color:#4d5570;}"
    .. ".dbi-wm .sf{display:flex;gap:4px;margin-bottom:5px;}"
    .. ".dbi-wm .sf input{flex:1 1 auto;min-width:0;box-sizing:border-box;"
    .. "border:1px solid #263049;border-radius:3px;background-color:#0d1220;"
    .. "color:#c8d2e4;font:inherit;font-size:clamp(8px,3.6cqw,12px);padding:3px 6px;}"
    .. ".dbi-wm .sf button{flex:0 0 auto;cursor:pointer;font:inherit;"
    .. "font-size:clamp(8px,3.6cqw,12px);border:1px solid #263049;border-radius:3px;"
    .. "background-color:#141a28;color:#7f8ba3;padding:3px 8px;}"
    -- Square, so a percentage means the same on both axes and a 45 degree line
    -- lands on the corner it is aimed at.
    .. ".dbi-wm .gr{flex:1 1 auto;position:relative;aspect-ratio:1;"
    .. "margin:0 auto;min-height:0;max-width:100%;max-height:100%;}"
    -- Quiet on purpose. This is the colour of a room whose ground nobody has
    -- recorded yet, and it used to be #2d3648 -- chosen when nothing else
    -- filled a room, and now the LOUDEST thing on the map: 'inside' washes to
    -- rgb(37,40,45), so the one un-sectored room in a corridor of them was the
    -- bright blue square everybody kept asking about. Absence should not draw
    -- attention; the tooltip is where it is reported.
    .. ".dbi-wm .nd{position:absolute;box-sizing:border-box;border-radius:2px;"
    .. "background-color:#252a33;border:1px solid #3d4a63;cursor:pointer;"
    .. "display:flex;align-items:center;justify-content:center;"
    .. "font-family:ui-monospace,monospace;font-weight:700;line-height:1;}"
    -- an exit we have seen but never taken: we know a room is there and
    -- nothing else about it
    .. ".dbi-wm .un{background-color:#4a1a1a;border-color:#a83a3a;color:#ff9a9a;"
    .. "border-style:dashed;cursor:default;}"
    -- The room you are in is an ordinary room with a white @ in it. Rooms are
    -- all one colour until the colouring comes off the MUD's own styles, which
    -- name a fill for every sector, mob, item and aggro state already.
    .. ".dbi-wm .me{color:#ffffff;z-index:6;}"
    -- Stairs, written the way a floorplan writes them, and inside the room
    -- rather than hanging off it: the node is quartered, up in the top right
    -- and down in the bottom left, which leaves the middle for the @.
    .. ".dbi-wm .ud{position:absolute;line-height:1;font-size:52%;"
    .. "color:#9fb4dd;pointer-events:none;}"
    .. ".dbi-wm .up{top:4%;right:8%;}"
    .. ".dbi-wm .dn{bottom:4%;left:8%;}"
    -- one we know is there and have not walked
    .. ".dbi-wm .nay{color:#a83a3a;}"
    -- Drawn from the centre of one room to the centre of the next, so it wants
    -- its origin on the left edge at mid height.
    -- The legend: one entry per flag that draws a glyph, under the map.
    .. ".dbi-wm .lg{flex:0 0 auto;display:flex;flex-wrap:wrap;gap:2px 9px;"
    .. "margin-top:5px;padding:0 2px;color:#5f6b80;"
    .. "font-size:clamp(7px,3cqw,10px);line-height:1.4;}"
    .. ".dbi-wm .lgi{white-space:nowrap;}"
    .. ".dbi-wm .lgs{font-weight:700;margin-right:3px;}"
    -- The room is quartered. Stairs already own two corners -- up top right,
    -- down bottom left -- so a flag's glyph takes one of the two that are left
    -- and the middle stays clear for the @.
    .. ".dbi-wm .fq{position:absolute;line-height:1;font-size:52%;"
    .. "pointer-events:none;}"
    .. ".dbi-wm .ftl{top:4%;left:8%;}"
    .. ".dbi-wm .fbr{bottom:4%;right:8%;}"
    -- The grid is dragged rather than nudged, so it says so on the pointer.
    .. ".dbi-wm .gr{cursor:grab;}"
    .. ".dbi-wm .gr:active{cursor:grabbing;}"
    -- Says the view is not on you any more. Only drawn when that is true, so it
    -- is never chrome you learn to ignore.
    .. ".dbi-wm .lay{position:absolute;left:2%;bottom:2%;z-index:7;"
    .. "border:1px solid #e8b45c;border-radius:2px;background-color:#191207;"
    .. "color:#e8b45c;padding:2px 5px;letter-spacing:0.06em;"
    .. "font-size:clamp(7px,2.8cqw,11px);cursor:pointer;user-select:none;}"
    .. ".dbi-wm .ln{position:absolute;height:2px;background-color:#37425a;"
    .. "transform-origin:0 50%;}"
    -- the way to somewhere we have not been
    .. ".dbi-wm .lnu{background-color:#6b2f2f;}"
    -- A door sits on the connection rather than on either room, because that
    -- is what it is: the thing between them.
    -- Thicker than the 2px connection so it reads as an interruption rather
    -- than a crossing, and rounded so it does not look like a broken line.
    .. ".dbi-wm .dr{position:absolute;z-index:5;height:4px;border-radius:2px;"
    .. "background-color:#cdd6e6;box-shadow:0 0 0 1px #0b0f16;"
    .. "transform-origin:50% 50%;cursor:pointer;}"
    .. ".dbi-wm .dr:hover{background-color:#ffffff;}"
    -- locked: same bar, and the only colour on the map that means "stop"
    .. ".dbi-wm .drl{background-color:#e8b45c;}"
    .. ".dbi-wm .drl:hover{background-color:#ffd27f;}"

    -- Hover detail, the stock map's tooltip. No script runs in a widget, so it
    -- is a child that :hover reveals rather than anything positioned at the
    -- cursor. Which side it opens on is decided when the panel is drawn --
    -- there is nothing here that can measure and flip it later, and a tooltip
    -- that opens off the edge of a 320px panel is no tooltip.
    .. ".dbi-wm .nd .tt{display:none;position:absolute;z-index:9;width:150px;"
    .. "padding:5px 7px;border-radius:3px;border:1px solid #3d4a63;"
    .. "background-color:#0d1220;color:#c8d2e4;font-size:10px;line-height:1.45;"
    .. "text-align:left;white-space:normal;pointer-events:none;}"
    .. ".dbi-wm .nd:hover{z-index:10;}"
    .. ".dbi-wm .nd:hover .tt{display:block;}"
    .. ".dbi-wm .tt .nm{color:#e8b45c;font-weight:600;display:block;"
    .. "margin-bottom:3px;}"
    .. ".dbi-wm .tt .k{color:#5f6b80;}"
    -- opens away from whichever edge the room is nearest
    .. ".dbi-wm .tt-r{left:150%;}"
    .. ".dbi-wm .tt-l{right:150%;}"
    .. ".dbi-wm .tt-d{top:0;}"
    .. ".dbi-wm .tt-u{bottom:0;}"

-- Room flags, which are the client's own subsystem rather than anything of
-- ours: a tag lives on the room, travels with a map export, and is searchable
-- with getRoomsWithFlag. Nothing here keeps a second copy.
--
-- This MUD prefixes some room names with a letter in brackets -- '(H) Healing
-- Chamber'. Only letters whose meaning is actually known go in here. An
-- unrecognised prefix is left alone rather than guessed at and given a name it
-- may not have; add a line when a meaning is confirmed, not when it is assumed.
paint.PREFIX = {
    h = "healing",
}

-- What the flags this plugin defines look like. Rooms tagged with anything not
-- in here still carry the tag; it simply draws nothing, which is the documented
-- behaviour and exactly what you want for a tag you have not decided about yet.
paint.FLAGS = {
    healing = { color = "#1d4d33", symbol = "+", symbolColor = "#66e0a0" },

    -- A room that takes you somewhere: a tesseract bay, a portal, anything you
    -- speak or type your way out of. The MUD has no style for these -- all
    -- fifty-one of its styles are sectors, mobs, doors and items -- so this one
    -- is tagged by hand, and defined here only so it draws when it is.
    -- Bright on purpose. A flag fill is composited onto a near-black panel, so
    -- a dark colour lands within a few points of the plain room it is supposed
    -- to stand out from: the first try at this was #3a2a5e, which came out
    -- rgb(34,28,58) against a base of rgb(45,54,72) and was invisible.
    teleport = { color = "#8a5cf0", symbol = "*", symbolColor = "#c9a6ff" },
}

-- '(H) Healing Chamber' -> 'healing'. Nil for everything else, including a name
-- with no prefix and a prefix that is not a single letter.
local function flagFromName(name)
    if type(name) ~= "string" then return nil end
    -- '(%a)' is a capture rather than a character class, which is the form that
    -- survives the pattern translation. Inside a bracket class %a silently
    -- stops matching letters here; outside one it expands and works.
    local letter = name:match("^%((%a)%)%s")
    if not letter then return nil end
    return paint.PREFIX[letter:lower()]
end

-- Tag a room from its name. Safe to run on every arrival: the check makes it a
-- no-op once the tag is there, and a room can be recorded before it is named.
local function applyNameFlag(vnum, name)
    local flag = flagFromName(name)
    if not vnum or not flag then return end
    if mapCall("roomHasFlag", vnum, flag) then return end
    if mapCall("setRoomFlag", vnum, flag, true) then view.dirty = true end
end

-- Teach the client what this plugin's flags look like. Called once the map is
-- warm, and again is harmless -- redefining replaces, and a redefine restores
-- the look on every room already carrying the tag.
--
-- Only the flags we invent. A flag someone defined by hand in Map Settings is
-- theirs and is not overwritten.
local function defineFlags()
    local have = safeMap(mapCall("getMapFlags"))

    local made = 0
    for name, look in pairs(paint.FLAGS) do
        local was = have[name]

        -- Only skip a definition that actually LOOKS like something. Tagging a
        -- room with a name nobody has defined is valid, and the client keeps
        -- that tag -- so 'dbmap flag teleport' before this plugin knew the word
        -- left an entry with no colour, no symbol and no icon, which this then
        -- read as "somebody configured it" and refused to touch. It drew
        -- nothing, for good.
        --
        -- A real definition, made here or by hand in Map Settings, has at least
        -- one of the three and is left alone.
        local dressed = false
        if type(was) == "table" then
            dressed = type(was.color) == "string"
                or type(was.symbol) == "string"
                or type(was.icon) == "string"
        end

        if not dressed then
            if mapCall("defineMapFlag", name, look) then made = made + 1 end
        end
    end

    -- A definition changes how rooms already on screen are drawn. This runs
    -- from the map-ready handler, which repaints and draws the panel a few
    -- lines later, so marking it is enough -- and drawPanel is declared four
    -- hundred lines below here, which a call from this scope would resolve as a
    -- nil global rather than an error.
    if made > 0 then view.dirty = true end
end

-- The MUD's own palette, off Map.Definition. It names a colour for every
-- sector, for mobs, items, aggro, doors and the rest -- 51 of them -- so there
-- is no reason to invent a second scheme and every reason not to: a room that
-- is green on the local map should be green here.
--
-- Declared up with the other palettes rather than beside the GMCP handler that
-- fills it: the settings pane reads it, and a file-scope local used above its
-- declaration resolves as a nil global in this runtime.

-- What a sector is painted with: your choice, else the MUD's.
--
-- An unset sector reads the server's palette every time rather than a copy of
-- it, which is what makes 'reset' mean reset: it deletes the override instead
-- of writing today's value, so a sector you have not touched follows the server
-- if the server ever changes its mind.
-- What a sector would be with nothing chosen for it: the server's live palette,
-- then the compiled copy, then a grey.
--
-- The grey matters. A colour input cannot be empty, so a sector the server has
-- never named still has to show SOMETHING -- and whatever it shows has to be
-- the same value this returns, or saving the form without touching a row would
-- store that placeholder as a deliberate choice.
paint.NONE = "#808080"

local function defaultColour(terrain)
    if type(terrain) ~= "string" or terrain == "" then return paint.NONE end

    local live = paint.style["sector." .. terrain]
    if type(live) == "string" and live ~= "" then return live end

    local baked = paint.DEFAULT[terrain]
    if type(baked) == "string" and baked ~= "" then return baked end
    return paint.NONE
end

local function colourFor(terrain)
    if type(terrain) ~= "string" or terrain == "" then return nil end
    local mine = paint.sector[terrain]
    if type(mine) == "string" and mine ~= "" then return mine end

    local live = paint.style["sector." .. terrain]
    if type(live) == "string" and live ~= "" then return live end
    return paint.DEFAULT[terrain]
end

-- A colour laid over the panel's own background, returned solid.
--
-- A sector fill has to be a wash rather than a block: these are
-- full-saturation terminal colours and painting a room #00ff00 leaves nothing
-- readable on top of it. Composited here rather than left as rgba(), because a
-- translucent room lets the connection behind it show through and every line
-- appears to run over the top of the rooms it joins.
paint.BG = { 11, 15, 22 }   -- #0b0f16, the panel

local function over(rgb, alpha)
    if type(rgb) ~= "string" then return nil end

    local out = {}
    local i = 1
    for part in rgb:gmatch("[^,]+") do
        local n = safeNum(part)
        if not n or i > 3 then return nil end
        out[i] = math.floor(paint.BG[i] + (n - paint.BG[i]) * alpha + 0.5)
        i = i + 1
    end
    if i ~= 4 then return nil end
    return out[1] .. "," .. out[2] .. "," .. out[3]
end

-- A terrain name to a CSS class. The name arrives over the wire and is about to
-- be written into a selector, so it is reduced rather than trusted. %w only: a
-- character range inside a class does not survive the pattern translation, and
-- %w drops the underscore in 'water_noswim' along with anything worse.
local function terrainClass(t)
    if type(t) ~= "string" then return nil end
    local slug = t:lower():gsub("[^%w]", "")
    if slug == "" then return nil end
    return "t" .. slug
end

-- Same reduction for a flag name, and a different prefix so a sector and a flag
-- called the same thing cannot end up as one class.
local function flagClass(f)
    if type(f) ~= "string" then return nil end
    local slug = f:lower():gsub("[^%w]", "")
    if slug == "" then return nil end
    return "f" .. slug
end

-- One rule per sector the MUD named, appended to the static sheet at draw time
-- because the palette arrives over GMCP well after that sheet is built.
--
-- These are full-saturation VGA colours -- sector.field is #00ff00 -- which is
-- right for a glyph on black and far too loud for a filled box. The border
-- takes the colour and the fill takes it at low alpha, so a field reads as
-- green beside a grey city without setting fire to the panel.
--
-- Rebuilt from the parsed numbers rather than echoed: the hex is server text
-- landing in a stylesheet, and '#aabbcc; content: ...' would otherwise walk
-- straight through. rgbOf validates by parsing, so nothing it did not
-- understand can reach the sheet.
-- What a flag looks like on a room, for every flag the map has a definition
-- for. Appended AFTER the terrain rules and at the same specificity, so it wins
-- on order: the client's own map paints flag colour over terrain, and the panel
-- has no business disagreeing with it.
--
-- The colour is rebuilt from its parsed numbers for the same reason the terrain
-- colours are: a definition can be written by hand in Map Settings, and it ends
-- up inside a stylesheet either way.
local function flagCss()
    local defs = safeMap(mapCall("getMapFlags"))

    local out = {}
    for name, def in pairs(defs) do
        if type(name) == "string" and type(def) == "table" then
            local cls = flagClass(name)
            local rgb = rgbOf(def.color)
            if cls and rgb then
                -- A flag is the border. Something somebody deliberately
                -- marked, drawn round the outside of whatever ground the room
                -- happens to sit on.
                out[#out + 1] = ".dbi-wm .nd." .. cls
                    .. "{border-color:rgb(" .. rgb .. ");border-width:2px;}"
            end

            -- The legend wants it as text rather than as a fill, and the glyph
            -- colour if the flag names one -- that is what the room shows.
            if cls then
                local ink = rgbOf(def.symbolColor) or rgb
                if ink then
                    out[#out + 1] = ".dbi-wm .lgi." .. cls
                        .. ",.dbi-wm .fq." .. cls
                        .. "{color:rgb(" .. ink .. ");}"
                end
            end
        end
    end
    return table.concat(out)
end

local function terrainCss()
    -- every sector the server named, plus any this map has a colour for that it
    -- did not
    local names = {}
    for name in pairs(paint.style) do
        if type(name) == "string" and name:sub(1, 7) == "sector." then
            names[name:sub(8)] = true
        end
    end
    for name in pairs(paint.sector) do
        if type(name) == "string" then names[name] = true end
    end
    for name in pairs(paint.DEFAULT) do names[name] = true end

    local out = {}
    for sector in pairs(names) do
        local cls = terrainClass(sector)
        local rgb = rgbOf(colourFor(sector))
        if cls and rgb then
            -- The ground is a wash: fill only, and faint. The border is left
            -- alone because that is what a flag uses, and the two want to be
            -- readable at the same time on the same room.
            local fill = over(rgb, 0.22)
            if fill then
                out[#out + 1] = ".dbi-wm .nd." .. cls
                    .. "{background-color:rgb(" .. fill .. ");}"
            end
        end
    end
    return table.concat(out)
end

-- Drawn from the rooms we recorded, centred on the one we are standing in.
-- The client's own panel cannot do this: it centres on the room GMCP reports
-- and this MUD sends none, so it never moves. The data still goes into the
-- client's map either way, which is where findPath, walkTo and the areas come
-- from -- this replaces the view, not the database.
-- Map settings. Everything here reports what it is set to; nothing is wired to
-- change it yet, so the rows are readouts and the commands remain the way to
-- set them. Shaped like the picker so the two behave the same when it is.
local function drawSettings()
    local function row(label, value, action)
        return "<div class='row'"
            .. (action and (" data-mud-action='" .. action .. "'") or "")
            .. "><span class='an'>" .. esc(label) .. "</span>"
            .. "<span class='pl'>" .. esc(value) .. "</span></div>"
    end

    local counts = mapCall("getAreaList")
    local here = 0
    if type(counts) == "table" then here = safeNum(counts[area]) or 0 end

    setWidgetProperty(view.id, "content",
        "<style>" .. paint.CSS .. "</style><div class='dbi-wm'>"
        .. "<div class='bar'><div class='head'>map settings</div>"
        .. "<div class='zb' data-mud-action='pickoff'>x</div></div>"
        .. "<div class='pk'>"
        .. row("view", view.mode == "area" and "whole area" or "around you")
        .. row("zoom", view.zoom .. " rooms out")
        .. row("distance east/west", tostring(nav.dist.x))
        .. row("distance north/south", tostring(nav.dist.y))
        .. row("mode", mode)
        .. row("area", area)
        .. row("rooms here", tostring(here))
        .. row("rooms recorded", tostring(st.rooms))
        .. row("exits recorded", tostring(st.exits))
        .. row("travel verbs", tostring((function()
            local n = 0
            for _ in pairs(travels) do n = n + 1 end
            return n
        end)()))
        .. row("colours and symbols", "edit", "looks")
        .. "</div>"
        .. "<div class='foot' data-mud-action='pickoff'>back to the map</div></div>")
end

-- The editable half of settings: a colour per sector and a glyph per flag.
--
-- Everything here defaults to what the MUD sent. A sector with no override
-- shows the server's own colour in the box, and clearing the box deletes the
-- override rather than freezing that value -- so an untouched sector keeps
-- following the server.
--
-- Only the sectors this area actually contains are listed. The MUD names
-- forty-one and all forty-one in a 320px panel is a wall rather than a setting.
local function drawLooks()
    local t = {}
    local function add(x) t[#t + 1] = x end

    add("<style>" .. paint.CSS .. "</style><div class='dbi-wm'>")
    add("<div class='bar'><div class='head'>colours and symbols</div>")
    add("<div class='zb' data-mud-action='pickoff'>x</div></div>")

    add("<form class='pk'>")
    add("<input type='hidden' name='op' value='looks'>")

    -- Which of them this area actually has, so the list says what is relevant
    -- without hiding the rest.
    --
    -- NOT 't' for the loop variable. That is the name of the parts table two
    -- lines above, which add() closes over, and this runtime does not keep the
    -- shadow inside the loop: every add() after it appended to a STRING, and
    -- the panel came apart with 'Object.keys(undefined)'. Real Lua scopes it
    -- correctly, so the suite never saw it.
    local present = {}
    for _, sec in ipairs(terrains()) do present[sec] = true end

    add("<div class='row'><span class='an'>sector colours</span>"
        .. "<span class='wh'>" .. tostring(#terrains()) .. " in this area</span></div>")

    local any = false
    for _, sector in ipairs(sectorList()) do
        any = true
        -- A colour input needs a real '#rrggbb' and cannot be blank, so the
        -- way back to the server's value is the reset beside it rather than
        -- clearing the box. The text form still works if the sanitiser will not
        -- have a picker -- a browser renders an unknown input type as text.
        local shown = paint.sector[sector] or defaultColour(sector)
        local mine = ""
        if paint.sector[sector] then mine = " mapped" end

        local mark = ""
        if present[sector] then mark = "<span class='wh'>here</span>" end

        add("<label class='row'><span class='an" .. mine .. "'>"
            .. esc(sector) .. "</span>" .. mark
            .. "<input type='color' name='c:" .. esc(sector) .. "' value='"
            .. esc(shown) .. "'>"
            .. "<span class='wh' data-mud-action='creset' data-mud-data='"
            .. esc(sector) .. "'>reset</span>"
            .. "</label>")
    end


    add("<div class='row'><span class='an'>flag symbols</span></div>")

    local defs = safeMap(mapCall("getMapFlags"))

    local names = {}
    for name in pairs(defs) do names[#names + 1] = tostring(name) end
    table.sort(names)

    for _, name in ipairs(names) do
        local def = defs[name]
        local sym, col = "", ""
        if type(def) == "table" then
            if type(def.symbol) == "string" then sym = def.symbol end
            if type(def.color) == "string" then col = def.color end
        end
        if col == "" then col = "#808080" end
        add("<label class='row'><span class='an'>" .. esc(name) .. "</span>"
            .. "<input type='text' name='s:" .. esc(name) .. "' value='"
            .. esc(sym) .. "' size='2'>"
            .. "<input type='color' name='f:" .. esc(name) .. "' value='"
            .. esc(col) .. "'></label>")
    end
    if #names == 0 then
        add("<div class='row'><span class='wh'>no flags defined --"
            .. " 'dbmap flag &lt;name&gt;' makes one</span></div>")
    end

    add("<div class='row'><button type='submit'>save</button>")
    add("<span class='wh' data-mud-action='looksreset'>back to the MUD's colours</span>")
    add("</div>")
    add("</form>")

    add("<div class='foot' data-mud-action='pickoff'>back to the map</div></div>")
    setWidgetProperty(view.id, "content", table.concat(t))
end

-- The area list: everything the MUD's own 'areas' command knows, plus anything
-- we have walked that it did not mention, with the ones holding rooms marked.
local function drawPicker()
    local have = {}
    local list = mapCall("getAreaList")
    if type(list) == "table" then
        for name, n in pairs(list) do have[name] = safeNum(n) or 0 end
    end

    local want = view.filter:lower()
    local rows, shown, total = {}, 0, 0
    local seen = {}

    local function row(name, where, lo, hi)
        seen[name] = true
        total = total + 1
        if want ~= "" and not name:lower():find(want, 1, true)
            and not where:lower():find(want, 1, true) then return end

        shown = shown + 1
        if shown > 60 then return end

        local cls = "an"
        if name == area then cls = "an here"
        elseif have[name] and have[name] > 0 then cls = "an mapped" end

        local count = have[name] and have[name] > 0 and (have[name] .. " rm") or ""
        rows[#rows + 1] = "<div class='row' data-mud-action='pick' data-mud-data='"
            .. esc(name) .. "'><span class='" .. cls .. "'>" .. esc(name)
            .. "</span><span class='wh'>" .. esc(where) .. "</span>"
            .. "<span class='pl'>" .. esc(lo) .. "-" .. esc(hi) .. "</span>"
            .. "<span class='pl'>" .. count .. "</span></div>"
    end

    -- Somewhere we have actually been comes first, and the one we are in comes
    -- before that. The known list is longer than the panel will draw, so
    -- ordering it the other way round hid the current area entirely.
    local where = {}
    for _, a in ipairs(KNOWN_AREAS) do where[a[1]] = { a[2], a[4], a[5] } end

    local function walked(name)
        local w = where[name]
        if w then row(name, w[1], w[2], w[3]) else row(name, "unlisted", "?", "?") end
    end

    if area ~= "" then walked(area) end
    for name in pairs(have) do
        if not seen[name] then walked(name) end
    end
    for _, a in ipairs(KNOWN_AREAS) do
        if not seen[a[1]] then row(a[1], a[2], a[4], a[5]) end
    end

    if #rows == 0 then
        rows[1] = "<div class='row'><span class='an'>nothing matching '"
            .. esc(view.filter) .. "'</span></div>"
    end

    setWidgetProperty(view.id, "content",
        "<style>" .. paint.CSS .. "</style><div class='dbi-wm'>"
        .. "<div class='bar'><div class='head'>choose an area</div>"
        .. "<div class='zb' data-mud-action='pickoff'>x</div></div>"
        .. "<form class='sf'><input type='text' name='q' value='" .. esc(view.filter)
        .. "' placeholder='search'><button type='submit'>find</button></form>"
        .. "<div class='pk'>" .. table.concat(rows) .. "</div>"
        .. "<div class='foot'>" .. shown .. " of " .. total .. "</div></div>")
end

local function drawPanel()
    if not view.id then return end
    if view.overlay == "pick" then return drawPicker() end
    if view.overlay == "settings" then return drawSettings() end
    if view.overlay == "looks" then return drawLooks() end

    local here = whereAt.vnum and mapCall("getMapRoom", whereAt.vnum)
    if type(here) ~= "table" then
        setWidgetProperty(view.id, "content",
            "<style>" .. paint.CSS .. "</style><div class='dbi-wm'>"
            .. "<div class='bar'><div class='head'>walk into a room</div></div>"
            .. "<div class='gr'></div>"
            .. "<div class='foot' data-mud-action='pickon'>" .. esc(area) .. "</div></div>")
        return
    end

    -- Read each independently. A room written before coordinates were always
    -- set can be missing one, and one missing value must not blank the panel.
    local cx = safeNum(here.x) or 0
    local cy = safeNum(here.y) or 0
    local cz = safeNum(here.z) or 0

    -- What is on screen, by offset from us. Gathered before anything is drawn
    -- so the lines can ask whether the far end is visible.
    local shown = {}
    local RADIUS, UNIT, NODE = viewScale()

    if view.mode == "area" then
        local at = positions()
        for dy = -RADIUS, RADIUS do
            for dx = -RADIUS, RADIUS do
                local vnum = at[(cx + view.off.x + dx) .. ","
                    .. (cy + view.off.y + dy) .. "," .. (cz + view.off.z)]
                if vnum then shown[vnum] = { dx, dy } end
            end
        end
    else
        -- Walked outward from here rather than read off the map. Stored
        -- coordinates carry every compromise made while the area was being
        -- explored; this carries none, because it is computed fresh and only
        -- has to hold together across a few rooms.
        local queue, head, tail = { whereAt.vnum }, 1, 1
        local depth = { [whereAt.vnum] = 0 }
        local taken = { ["0,0"] = whereAt.vnum }
        shown[whereAt.vnum] = { 0, 0 }

        while head <= tail do
            local vnum = queue[head]
            head = head + 1
            if depth[vnum] < view.zoom then
                local r = mapCall("getMapRoom", vnum)
                if type(r) == "table" and type(r.exits) == "table" then
                    for d, dest in pairs(r.exits) do
                        local step = nav.STEP[d]
                        local to = safeNum(dest)
                        if step and to and not shown[to] then
                            local nx = shown[vnum][1] + step[1] * nav.dist.x
                            local ny = shown[vnum][2] + step[2] * nav.dist.y
                            local k = nx .. "," .. ny
                            -- A square already used means this neighbourhood
                            -- folds back on itself. Leave the room out rather
                            -- than stack it: one missing room reads better than
                            -- two drawn in one place.
                            if not taken[k] and math.abs(nx) <= RADIUS
                                and math.abs(ny) <= RADIUS then
                                taken[k] = to
                                shown[to] = { nx, ny }
                                depth[to] = depth[vnum] + 1
                                tail = tail + 1
                                queue[tail] = to
                            end
                        end
                    end
                end
            end
        end
    end
    -- Keys normalised before anything compares against hereVnum. A vnum coming
    -- back from the map can be a string, and "10000" == 10000 is false, so the
    -- room you are standing in matched nothing and drew as an ordinary room.
    local norm = {}
    for v, off in pairs(shown) do
        norm[safeNum(v) or v] = off
    end
    shown = norm

    -- You are always at the centre of a view that is centred on you -- which is
    -- what puts the @ on the map even before the room has coordinates worth
    -- trusting. Once the view has been moved off you it stops being true, and
    -- forcing it anyway pinned the @ to the middle of a floor it was not on and
    -- dragged that room into the picture with it.
    local me = safeNum(whereAt.vnum)
    if me and viewCentred() then shown[me] = { 0, 0 } end

    -- Percent of the box for an offset, measured to the middle of the room.
    local function midX(dx) return (dx + RADIUS + 0.5) * UNIT end
    local function midY(dy) return (dy + RADIUS + 0.5) * UNIT end

    -- Each visible room read once. The lines, the node and its tooltip all want
    -- the same thing, and this used to ask the map three times per room.
    local info = {}
    for vnum in pairs(shown) do
        local r = mapCall("getMapRoom", vnum)
        if type(r) == "table" then
            -- A stub the map still holds for a direction that HAS an exit is
            -- stale, and the map is full of them: the whole Elite Quarters
            -- reported six exits and the same six as unwalked. Whatever failed
            -- to clear them, a direction we have an exit for has been walked,
            -- so it is filtered here rather than trusted.
            local exits = type(r.exits) == "table" and r.exits or {}
            local doors = mapCall("getDoors", vnum)
            if type(doors) ~= "table" then doors = {} end
            local stubs, sn = {}, 0
            local raw = mapCall("getExitStubs", vnum)
            if type(raw) == "table" then
                for _, d in ipairs(raw) do
                    local dir = tostring(d)
                    if exits[dir] == nil then
                        sn = sn + 1
                        stubs[sn] = dir
                    end
                end
            end
            -- 0-indexed coming back, like every other list the mapper hands
            -- over, so ipairs and never a numeric for.
            local flags = mapCall("getRoomFlags", vnum)
            if type(flags) ~= "table" then flags = {} end

            info[vnum] = { room = r, stubs = stubs, stubN = sn,
                           doors = doors, flags = flags }
        end
    end

    -- Lines first so the rooms sit on top of their own ends.
    local parts = {}

    -- One marker per doorway, not per room. Both sides of a door record it --
    -- A has one east, B has one west -- and drawn from each they would stack on
    -- the same spot.
    local doorDrawn = {}
    for vnum, off in pairs(shown) do
        local rec = info[vnum]
        local r = rec and rec.room
        if type(r) == "table" and type(r.exits) == "table" then
            for dir, dest in pairs(r.exits) do
                local to = shown[safeNum(dest)]
                local angle = geo.ANGLE[dir]
                if to then
                    local ax, ay = off[1], off[2]
                    local runX, runY = to[1] - ax, to[2] - ay

                    -- Measured, not assumed. Stretching the grid to fit a
                    -- section in leaves connections at angles that are not
                    -- multiples of 45, so the eight fixed angles this used to
                    -- pick from would have refused to draw half of them.
                    local len = math.sqrt(runX * runX + runY * runY)
                    if len > 0 then
                        local deg = math.deg(math.atan2(runY, runX))
                        parts[#parts + 1] = "<div class='ln' style='left:"
                            .. string.format("%.3f", midX(ax)) .. "%;top:"
                            .. string.format("%.3f", midY(ay)) .. "%;width:"
                            .. string.format("%.3f", len * UNIT) .. "%;transform:rotate("
                            .. string.format("%.2f", deg) .. "deg)'></div>"

                        local status = rec and type(rec.doors) == "table"
                            and safeNum(rec.doors[dir])
                        local cx2 = (midX(ax) + midX(to[1])) / 2
                        local cy2 = (midY(ay) + midY(to[2])) / 2
                        local spot = string.format("%.1f,%.1f", cx2, cy2)

                        -- Closed and locked draw; an open door does not. The
                        -- server never says a door is open, so status 1 only
                        -- ever came from a guess, and the guesses landed on
                        -- plain doorways.
                        if status and status >= 2 and status <= 3
                            and not doorDrawn[spot] then
                            doorDrawn[spot] = true
                            -- Clicking one cycles it. Adding doors is automatic
                            -- and taking them away is not, so this is the way
                            -- to correct a reading or drop a door a builder
                            -- removed.
                            -- A bar across the doorway, turned to sit square
                            -- to the connection it interrupts -- which is what
                            -- a door is on any drawn map, and the angle is
                            -- already worked out for the line itself.
                            --
                            -- The emoji this replaced rendered as a full-height
                            -- colour picture of a door, which next to 2px lines
                            -- and flat boxes looked like a sticker.
                            local drc = "dr"
                            if status == 3 then drc = "dr drl" end

                            parts[#parts + 1] = "<div class='" .. drc
                                .. "' data-mud-action='door' data-mud-data='"
                                .. tostring(vnum) .. ":" .. dir .. "' style='left:"
                                .. string.format("%.3f", cx2) .. "%;top:"
                                .. string.format("%.3f", cy2) .. "%;width:"
                                .. string.format("%.3f", NODE * 0.62) .. "%;"
                                .. "transform:translate(-50%,-50%) rotate("
                                .. string.format("%.2f", deg + 90) .. "deg)'></div>"
                        end
                    end
                end
            end
        end
    end

    -- An exit we have seen but never taken. We know a room is there and nothing
    -- whatever about it, so it gets a square of its own rather than only a
    -- coloured edge on the room that leads to it.
    local glyph = string.format("%.2f", NODE * 0.62) .. "cqw"
    local used = {}
    for _, off in pairs(shown) do used[off[1] .. "," .. off[2]] = true end

    for vnum, off in pairs(shown) do
        local rec = info[vnum]
        if rec then
            for _, d in ipairs(rec.stubs) do
                local step = nav.STEP[d]
                if step and (step[1] ~= 0 or step[2] ~= 0) then
                    local ux = off[1] + step[1] * nav.dist.x
                    local uy = off[2] + step[2] * nav.dist.y
                    local k = ux .. "," .. uy
                    local room4 = used[k]
                    local runX = step[1] * nav.dist.x
                    local runY = step[2] * nav.dist.y

                    -- The square is taken by some other room the layout put
                    -- there. Real rooms get nudged to the nearest free square
                    -- when that happens, so an unwalked one does too: drawn
                    -- near where it belongs and joined by a line, which says
                    -- more than a stub and far more than nothing.
                    -- No searching for somewhere else to put it.
                    --
                    -- This used to look for a free square nearby, as real rooms
                    -- do when they collide. Two things wrong with that. The
                    -- scan ran from -ring upward, so everything it moved went
                    -- up and left, and in a grid where most squares are taken
                    -- that was most of them -- a whole cloud of question marks
                    -- piled on one side of a map they had no business being on.
                    -- And a room we have never seen has no position to be
                    -- wrong about: the only true thing is the direction.
                    --
                    -- So when the square is taken, a stub that way and nothing
                    -- more.
                    if room4 and math.abs(ux) <= RADIUS and math.abs(uy) <= RADIUS then
                        local half = math.sqrt(runX * runX + runY * runY) * 0.45
                        if half > 0 then
                            parts[#parts + 1] = "<div class='ln lnu' style='left:"
                                .. string.format("%.3f", midX(off[1])) .. "%;top:"
                                .. string.format("%.3f", midY(off[2])) .. "%;width:"
                                .. string.format("%.3f", half * UNIT) .. "%;transform:rotate("
                                .. string.format("%.2f", math.deg(math.atan2(runY, runX)))
                                .. "deg)'></div>"
                        end
                    end

                    if not room4 and math.abs(ux) <= RADIUS and math.abs(uy) <= RADIUS then
                        used[k] = true

                        -- Joined to the room it leads off, same as any other
                        -- exit. Floating on its own it reads as a room we
                        -- found rather than a way out we have not taken.
                        local len = math.sqrt(runX * runX + runY * runY)
                        if len > 0 then
                            parts[#parts + 1] = "<div class='ln lnu' style='left:"
                                .. string.format("%.3f", midX(off[1])) .. "%;top:"
                                .. string.format("%.3f", midY(off[2])) .. "%;width:"
                                .. string.format("%.3f", len * UNIT) .. "%;transform:rotate("
                                .. string.format("%.2f", math.deg(math.atan2(runY, runX)))
                                .. "deg)'></div>"
                        end

                        parts[#parts + 1] = "<div class='nd un' style='left:"
                            .. string.format("%.3f", midX(ux) - NODE / 2) .. "%;top:"
                            .. string.format("%.3f", midY(uy) - NODE / 2) .. "%;width:"
                            .. string.format("%.3f", NODE) .. "%;height:"
                            .. string.format("%.3f", NODE) .. "%;font-size:" .. glyph .. "'>?"
                            .. "<div class='tt tt-r tt-d'><span class='nm'>not been here</span>"
                            .. "<span class='k'>" .. esc(d) .. "</span> from "
                            .. esc(rec.room and rec.room.name or "?") .. "</div></div>"
                    end
                end
            end
        end
    end

    -- Asked for once, not once per room: the definitions are the same for every
    -- node on screen and this loop runs for all of them.
    local flagDefs = safeMap(mapCall("getMapFlags"))

    for vnum, off in pairs(shown) do
        local rec = info[vnum]
        local r = rec and rec.room

        local cls = "nd"
        local mark = ""
        local size = NODE
        if me and safeNum(vnum) == me then
            cls = "nd me"
            mark = "@"
        end

        -- The MUD's own colour for this room's sector, where it named one. A
        -- room recorded before the palette arrived, or one whose sector the
        -- server never sent, keeps the plain slate rather than guessing.
        local tcls = nil
        if type(r) == "table" then tcls = terrainClass(r.terrain) end
        if tcls then cls = cls .. " " .. tcls end

        -- Whatever the room is tagged as. Every flag's class goes on, so a
        -- room carrying two of them takes whichever the stylesheet ordered
        -- last rather than whichever this loop happened to see first.
        --
        -- The symbol is only for a room with nothing of its own to show: the
        -- room's own marker wins, which is the priority the client's map uses
        -- and the reason the @ is never replaced by a '+'.
        -- Two corners are free, so two flags can show. Drawn even in the room
        -- you are standing in: they are in the corners now rather than the
        -- middle, so nothing has to give way to the @.
        local flagSym = ""
        if rec and type(rec.flags) == "table" then
            local shown = 0
            for _, fname in ipairs(rec.flags) do
                local fcls = flagClass(tostring(fname))
                if fcls then cls = cls .. " " .. fcls end

                if shown < 2 and fcls then
                    local def = flagDefs[tostring(fname):lower()]
                    if type(def) == "table" and type(def.symbol) == "string"
                        and def.symbol ~= "" then
                        local corner = "ftl"
                        if shown == 1 then corner = "fbr" end
                        flagSym = flagSym .. "<span class='fq " .. corner
                            .. " " .. fcls .. "'>"
                            .. esc(def.symbol:sub(1, 2)) .. "</span>"
                        shown = shown + 1
                    end
                end
            end
        end

        -- Up and down, in the corners.
        --
        -- Nothing else can show them: they share x and y with the room below
        -- and differ only in z, so a line to one would go nowhere. Floorplans
        -- have always written stairs as a U and a D and it reads immediately.
        -- Top right for up, bottom left for down.
        local udBits = ""
        if r and type(r.exits) == "table" then
            if r.exits["u"] ~= nil then
                udBits = udBits .. "<span class='ud up'>U</span>"
            end
            if r.exits["d"] ~= nil then
                udBits = udBits .. "<span class='ud dn'>D</span>"
            end
        end
        -- Dimmed where we know the way exists and have not taken it.
        if rec then
            for _, sd in ipairs(rec.stubs) do
                if sd == "u" and not udBits:find("up", 1, true) then
                    udBits = udBits .. "<span class='ud up nay'>U</span>"
                elseif sd == "d" and not udBits:find("dn", 1, true) then
                    udBits = udBits .. "<span class='ud dn nay'>D</span>"
                end
            end
        end

        -- Open the tooltip away from the nearest edge, decided here because
        -- nothing in the widget can measure it afterwards.
        local side = off[1] > 0 and "tt-l" or "tt-r"
        local vert = off[2] > 0 and "tt-u" or "tt-d"

        local outs = {}
        if r and type(r.exits) == "table" then
            for d, to in pairs(r.exits) do
                outs[#outs + 1] = d .. ": " .. tostring(to)
            end
        end

        -- Terrain earns a line now that it decides the colour: "why is this one
        -- a different shade" has no answer anywhere else, and the answer is
        -- usually "it is the only room here that has a sector yet".
        local ground = nil
        if type(r) == "table" and type(r.terrain) == "string"
            and r.terrain ~= "" and r.terrain ~= "default" then
            ground = r.terrain
        end

        local tip = "<span class='nm'>" .. esc(r and r.name or "?") .. "</span>"
            .. "<span class='k'>vnum</span> " .. tostring(vnum) .. "<br>"
            .. "<span class='k'>area</span> " .. esc(r and r.area or area) .. "<br>"
            .. "<span class='k'>ground</span> "
            .. (ground and esc(ground) or "not recorded yet") .. "<br>"
            .. "<span class='k'>exits</span> "
            .. (#outs > 0 and esc(table.concat(outs, ", ")) or "none")
        if rec and rec.stubN > 0 then
            tip = tip .. "<br><span class='k'>unwalked</span> "
                .. esc(table.concat(rec.stubs, " "))
        end

        -- Read off the server's own local map rather than from anything typed.
        if rec and type(rec.doors) == "table" then
            local shut = {}
            for d, status in pairs(rec.doors) do
                local n = safeNum(status)
                if n == 3 then shut[#shut + 1] = d .. " locked"
                elseif n == 2 then shut[#shut + 1] = d .. " closed" end
            end
            if #shut > 0 then
                tip = tip .. "<br><span class='k'>doors</span> "
                    .. esc(table.concat(shut, ", "))
            end
        end

        if rec and type(rec.flags) == "table" then
            local tags = {}
            for _, fname in ipairs(rec.flags) do tags[#tags + 1] = tostring(fname) end
            if #tags > 0 then
                tip = tip .. "<br><span class='k'>flags</span> "
                    .. esc(table.concat(tags, ", "))
            end
        end

        -- Where a teleport goes. Two sources answering two different questions,
        -- so they get two lines: the advertised list is what the room claims
        -- before you have ever used it, and the special exits are the ones
        -- actually walked -- the only ones with a vnum behind them.
        --
        -- LEGENDE has five tesseract bays in one section pointing five
        -- different places, and until this landed nothing on the map told them
        -- apart.
        local adv = textOf(mapCall("getRoomUserData", vnum, "dests"))
        if adv then
            tip = tip .. "<br><span class='k'>goes to</span> " .. esc(adv)
        end

        local sp = mapCall("getSpecialExits", vnum)
        if type(sp) == "table" then
            local ways = {}
            for cmd, to in pairs(sp) do
                ways[#ways + 1] = tostring(cmd) .. " -> " .. tostring(to)
            end
            if #ways > 0 then
                tip = tip .. "<br><span class='k'>walked</span> "
                    .. esc(table.concat(ways, ", "))
            end
        end

        -- The client stores a note per room and displays it nowhere: its own
        -- room menu offers colour, symbol, hidden and flags, and no editor for
        -- this. So this line and 'dbmap note' are the whole feature.
        local memo = nil
        if type(r) == "table" then memo = textOf(r.notes) end
        if memo then
            -- Escaped first, then the line breaks become markup. That order is
            -- the whole safety of it: a note is typed by hand, so nothing in it
            -- can be allowed to arrive as markup on its own.
            local safe = esc(memo)
            local shown = safe:gsub("\n", "<br>")
            tip = tip .. "<br><span class='k'>note</span> " .. shown
        end

        parts[#parts + 1] = "<div class='" .. cls .. "'"
            .. " data-mud-action='walk' data-mud-data='" .. tostring(vnum) .. "'"
            .. " style='left:"
            .. string.format("%.3f", midX(off[1]) - size / 2) .. "%;top:"
            .. string.format("%.3f", midY(off[2]) - size / 2) .. "%;width:"
            .. string.format("%.3f", size) .. "%;height:"
            .. string.format("%.3f", size) .. "%;font-size:"
            .. string.format("%.2f", size * 0.72) .. "cqw'>" .. mark .. flagSym .. udBits
            .. "<div class='tt " .. side .. " " .. vert .. "'>" .. tip .. "</div>"
            .. "</div>"
    end
    local cells = parts

    -- The floor stack, and the pad that moves the view off you. Area view only:
    -- local view lays the neighbourhood out by walking exits from where you are
    -- standing, so there is no coordinate to offset and no floor to step to.
    local layerBits, badge = "", ""
    if view.mode == "area" then
        if #floors() > 1 then
            layerBits = "<div class='zb' data-mud-action='layerup'>&#9650;</div>"
                .. "<div class='zb' data-mud-action='layerdown'>&#9660;</div>"
        end

        -- Only while the view is off you. A marker that is always there is one
        -- you stop reading, and this one has to be noticed: with the @ off
        -- screen there is otherwise nothing to say the map is not about you.
        if not viewCentred() then
            local bits = {}
            if view.off.z ~= 0 then
                local sign = view.off.z > 0 and "+" or ""
                bits[#bits + 1] = "floor " .. sign .. view.off.z
            end
            if view.off.x ~= 0 or view.off.y ~= 0 then bits[#bits + 1] = "panned" end
            badge = "<div class='lay' data-mud-action='pancentre'>"
                .. esc(table.concat(bits, " ")) .. " &#8635;</div>"
        end
    end

    -- Only flags that actually draw something get a line: a purely semantic
    -- tag has nothing to explain.
    local legendHtml = ""
    if view.legend then
        local seen = {}
        for name, def in pairs(flagDefs) do
            if type(name) == "string" and type(def) == "table"
                and type(def.symbol) == "string" and def.symbol ~= "" then
                seen[#seen + 1] = tostring(name)
            end
        end
        table.sort(seen)

        local bits = {}
        for _, name in ipairs(seen) do
            local cls = flagClass(name)
            local def = flagDefs[name]
            if cls and type(def) == "table" then
                bits[#bits + 1] = "<span class='lgi " .. cls .. "'>"
                    .. "<span class='lgs'>" .. esc(def.symbol:sub(1, 2))
                    .. "</span>" .. esc(name) .. "</span>"
            end
        end
        if #bits > 0 then
            legendHtml = "<div class='lg'>" .. table.concat(bits) .. "</div>"
        end
    end

    setWidgetProperty(view.id, "content",
        -- the sector colours go on the end, because the palette lands long
        -- after the static sheet is built
        -- flags after terrain, because a flag colour paints over a sector one
        "<style>" .. paint.CSS .. terrainCss() .. flagCss() .. "</style>"
        .. "<div class='dbi-wm'>"
        .. "<div class='bar'>"
        .. "<div class='head'>" .. esc(here.name or "?") .. "</div>"
        .. layerBits
        .. "<div class='zb' data-mud-action='zoomin'>+</div>"
        .. "<div class='zb' data-mud-action='settings'>&#9881;</div>"
        .. "<div class='zb' data-mud-action='zoomout'>-</div>"
        .. "</div>"
        .. "<div class='gr'>" .. table.concat(cells) .. badge .. "</div>"
        .. legendHtml
        .. "<div class='foot' data-mud-action='pickon'>" .. esc(area) .. "</div>"
        .. "</div>")
end

-- One callback serves every button on the panel, so anything that throws in
-- there takes the rest of them with it and the client reports it as an
-- anonymous widget error with no line and no name. Caught and named here, and
-- kept in lastError so 'dbmap diag' still has it afterwards.
local function safeDraw(what, fn)
    local ok, err = pcall(fn)
    if ok then return end
    lastError = what .. ": " .. tostring(err)
    say("the " .. what .. " page failed: " .. tostring(err), "#ff6666")
end

-- Everything the looks form sent, applied in one go.
--
-- A blank colour DELETES the override rather than storing an empty string, so
-- clearing a box is how you go back to the server's value for that one sector.
-- Anything that is not a colour is ignored rather than stored: this ends up in
-- a stylesheet, and the same check guards the way in as the way out.
local function applyLooks(f)
    if type(f) ~= "table" then return end

    local defs = safeMap(mapCall("getMapFlags"))

    -- defineMapFlag REPLACES a definition, so the symbol and the colour have to
    -- be gathered and written together or saving one would drop the other.
    local want = {}
    local function edit(name)
        if not want[name] then want[name] = {} end
        return want[name]
    end

    for k, v in pairs(f) do
        local key = tostring(k)
        local val = trimBoth(tostring(v or ""))

        local sector = key:match("^c:(.+)$")
        if sector then
            sector = sector:lower()
            -- The form sends every row, touched or not, so a value equal to
            -- the default is stored as nothing at all. Otherwise opening this
            -- page and pressing save would freeze the server's colours as
            -- overrides and the map would stop following it.
            if val == "" or val:lower() == defaultColour(sector):lower() then
                paint.sector[sector] = nil
            elseif rgbOf(val) then
                paint.sector[sector] = val
            end
        end

        local sym = key:match("^s:(.+)$")
        if sym then edit(sym:lower()).symbol = val end

        local col = key:match("^f:(.+)$")
        if col then edit(col:lower()).color = val end
    end

    for name, e in pairs(want) do
        local was = defs[name]
        if type(was) ~= "table" then was = {} end

        -- Start from what the flag already is, because defineMapFlag replaces
        -- the whole definition: a form that sent only the glyph would otherwise
        -- take the colour off with it. A field that arrived EMPTY clears; a
        -- field that did not arrive at all is left alone.
        local opts = {
            icon = was.icon,
            symbolColor = was.symbolColor,
            symbol = was.symbol,
            color = was.color,
        }
        if type(e.symbol) == "string" then
            if e.symbol == "" then opts.symbol = nil
            else opts.symbol = e.symbol:sub(1, 2) end
        end
        if type(e.color) == "string" then
            if e.color == "" then opts.color = nil
            elseif rgbOf(e.color) then opts.color = e.color end
        end
        mapCall("defineMapFlag", name, opts)
    end

    savePrefs()
    view.dirty = true
    repaint()
end

-- A drag starts anywhere on the grid, but not on the head or the foot: those
-- carry the zoom, layer, settings and area buttons, and grabbing one of those
-- should press it rather than start hauling the map about.
local function dragStart(e)
    if type(e) ~= "table" then return end
    local x, y = safeNum(e.x), safeNum(e.y)
    if not x or not y then return end
    if y < 30 or y > view.px.h - 30 then return end

    view.drag.on = true
    view.drag.x = x
    view.drag.y = y
end

local function dragEnd()
    view.drag.on = false
end

-- Pull the map the way the mouse went: drag right and the view moves left, the
-- same as dragging a sheet of paper across a desk.
local function dragMove(e)
    if not view.drag.on or type(e) ~= "table" then return end
    local x, y = safeNum(e.x), safeNum(e.y)
    if not x or not y then return end

    -- captured into locals rather than nested into a call: a multi-value return
    -- used as an argument arrives here as a wrapped pair
    local radius, unit = viewScale()
    local edge = gridEdgePx()

    local perX = edge * (nav.dist.x * unit) / 100
    local perY = edge * (nav.dist.y * unit) / 100
    if perX < 4 then perX = 4 end
    if perY < 4 then perY = 4 end

    local moved = false

    -- One room per threshold crossed, and the leftover stays on the cursor so a
    -- slow drag accumulates instead of being rounded away.
    while x - view.drag.x >= perX do
        view.off.x = view.off.x - nav.dist.x
        view.drag.x = view.drag.x + perX
        moved = true
    end
    while view.drag.x - x >= perX do
        view.off.x = view.off.x + nav.dist.x
        view.drag.x = view.drag.x - perX
        moved = true
    end
    while y - view.drag.y >= perY do
        view.off.y = view.off.y - nav.dist.y
        view.drag.y = view.drag.y + perY
        moved = true
    end
    while view.drag.y - y >= perY do
        view.off.y = view.off.y + nav.dist.y
        view.drag.y = view.drag.y - perY
        moved = true
    end

    if moved then drawPanel() end
end

local function showMap()
    -- Already up: redraw it rather than doing nothing, so 'dbmap show' is a
    -- way to refresh the panel and not just a no-op.
    if view.id then
        drawPanel()
        return true
    end

    local mk = callable("createWidget")
    if not mk then
        lastError = "createWidget is not in this build"
        return false
    end

    local ok, id = pcall(function()
        return mk({
            type     = "html",
            name     = "worldmap",
            title    = "DBI Map",
            position = { x = 760, y = 430 },
            size     = { width = 320, height = 340 },
            scrollable = false,
        })
    end)

    if not ok or not id then
        lastError = "createWidget: " .. tostring(id)
        return false
    end

    view.id = id

    -- One place that switches area, so the command and the picker cannot drift
    -- apart. New rooms go there; nothing already recorded moves.
    local function switchTo(name)
        if name == "" or name == area then return end
        area = name
        forgetPositions()
        baseFor(area)
        mapCall("addAreaName", area)
        savePrefs()
        say("new rooms go into '" .. area .. "' from vnum "
            .. tostring(bases[area]) .. ".")
    end

    -- Typing in the picker's search box. 'submit' with formData is undocumented
    -- and proven in the Aardwolf set; it is the only way to read an input from
    -- in here, since no script runs in a widget.
    local onSubmit = callable("registerWidgetEvent")
    if onSubmit then
        local wid = id
        pcall(function()
            return onSubmit(wid, "submit", function(data)
                local f = nil
                if type(data) == "table" and type(data.formData) == "table" then
                    f = data.formData
                end

                -- two forms share this one handler, so the hidden op says which
                if f and tostring(f.op or "") == "looks" then
                    safeDraw("colours", function()
                        applyLooks(f)
                        drawLooks()
                    end)
                    return
                end

                if view.overlay ~= "pick" then return end
                local q = ""
                if f then q = tostring(f.q or "") end
                view.filter = trimBoth(q)
                drawPicker()
            end)
        end)
    end

    -- Click a room, walk to it. registerWidgetEvent with "action" is
    -- undocumented but proven in the Aardwolf set: it delivers data.action from
    -- data-mud-action and the attribute's data alongside it.
    --
    -- A single click rather than a double: nothing scripted runs in a widget,
    -- so there is no way to tell the two apart from in here.
    local reg = callable("registerWidgetEvent")

    -- Drag the grid to pan, and keep the panel's real size for turning that
    -- drag into rooms. registerWidgetEvent APPENDS, so anything registered here
    -- is dropped first or a reload stacks a second copy of every handler.
    if reg then
        local wid = id
        local drop = callable("unregisterWidgetEvent")
        for _, ev in ipairs({ "mousedown", "mousemove", "mouseup", "resize" }) do
            if drop then pcall(function() return drop(wid, ev) end) end
        end

        pcall(function() return reg(wid, "mousedown", dragStart) end)
        pcall(function() return reg(wid, "mousemove", dragMove) end)
        pcall(function() return reg(wid, "mouseup", dragEnd) end)
        pcall(function()
            return reg(wid, "resize", function(e)
                if type(e) ~= "table" then return end
                local w, h = safeNum(e.width), safeNum(e.height)
                if w and w > 40 then view.px.w = w end
                if h and h > 40 then view.px.h = h end
            end)
        end)
    end

    if reg then
        local wid = id
        pcall(function()
            return reg(wid, "action", function(data)
                if type(data) ~= "table" then return end

                local what = data.action
                if what == "looks" then
                    view.overlay = "looks"
                    safeDraw("colours", drawPanel)
                    return
                end

                if what == "creset" then
                    local sector = trimBoth(tostring(data.data or "")):lower()
                    if sector ~= "" then
                        paint.sector[sector] = nil
                        savePrefs()
                        view.dirty = true
                        repaint()
                        safeDraw("colours", drawLooks)
                    end
                    return
                end

                if what == "looksreset" then
                    paint.sector = {}
                    savePrefs()
                    view.dirty = true
                    repaint()
                    safeDraw("colours", drawLooks)
                    say("sector colours back to the MUD's own.")
                    return
                end

                if what == "pancentre" then
                    recentre()
                    drawPanel()
                    return
                end

                -- To the next floor that exists, not the next number. Floors are
                -- whatever the area happens to have -- a tower with a basement
                -- and a roof and nothing between them is two steps, not four --
                -- so this walks the sorted list rather than adding one.
                if what == "layerup" or what == "layerdown" then
                    local at = whereAt.vnum and mapCall("getMapRoom", whereAt.vnum)
                    local base = safeNum(type(at) == "table" and at.z) or 0
                    local cur = base + view.off.z

                    local want = nil
                    for _, z in ipairs(floors()) do
                        if what == "layerup" then
                            if z > cur and (want == nil or z < want) then want = z end
                        else
                            if z < cur and (want == nil or z > want) then want = z end
                        end
                    end

                    if not want then
                        say("no floor " .. (what == "layerup" and "above" or "below")
                            .. " this one in " .. area .. ".", "#ffb02e")
                        return
                    end
                    view.off.z = want - base
                    drawPanel()
                    return
                end

                if what == "zoomin" or what == "zoomout" then
                    -- Finer steps close in, where one room either way is a
                    -- visible difference, and coarser further out where it is
                    -- not worth the clicks.
                    local step = view.zoom <= 8 and 1 or 3
                    if what == "zoomin" then step = -step end

                    local want = view.zoom + step
                    view.zoom = math.max(view.ZOOM.min, math.min(view.ZOOM.max, want))
                    savePrefs()
                    drawPanel()

                    -- Say so rather than appearing to ignore the click.
                    if want ~= view.zoom then
                        say("that is as far " .. (what == "zoomin" and "in" or "out")
                            .. " as it goes: " .. view.zoom .. " room(s) out.", "#ffb02e")
                    end
                    return
                end

                -- Clicking a door cycles it: closed, locked, gone. Doors are
                -- added automatically and never taken away automatically, so
                -- this is the way to correct one or drop one a builder removed.
                --
                -- Open is not a step. It does not draw, so a cycle that passed
                -- through it would leave nothing on screen to click again.
                --
                -- Both sides are set together. One doorway is recorded twice --
                -- east on this room, west on the next -- and changing only the
                -- half you clicked leaves the map disagreeing with itself.
                if what == "door" then
                    local raw = tostring(data.data or "")
                    local at, dir = raw:match("^(%d+):(%S+)$")
                    local vnum = safeNum(at)
                    if not vnum or not nav.OPPOSITE[dir] then return end

                    local doors = mapCall("getDoors", vnum)
                    local now = 0
                    if type(doors) == "table" then now = safeNum(doors[dir]) or 0 end

                    -- right button, if this build sends one, removes outright
                    local nextStatus
                    if safeNum(data.button) == 2 then
                        nextStatus = 0
                    elseif now == 2 then nextStatus = 3
                    elseif now == 3 then nextStatus = 0
                    else nextStatus = 2 end

                    mapCall("setDoor", vnum, dir, nextStatus)

                    local room = mapCall("getMapRoom", vnum)
                    local far = nil
                    if type(room) == "table" and type(room.exits) == "table" then
                        far = safeNum(room.exits[dir])
                    end
                    if far then mapCall("setDoor", far, nav.OPPOSITE[dir], nextStatus) end

                    local WORD = { [0] = "gone", "open", "closed", "locked" }
                    say("door " .. dir .. ": " .. (WORD[nextStatus] or "?"))
                    view.dirty = true
                    repaint()
                    drawPanel()
                    return
                end

                if what == "pickon" then
                    view.overlay = "pick"
                    view.filter = ""
                    drawPanel()
                    return
                end

                if what == "settings" then
                    view.overlay = "settings"
                    drawPanel()
                    return
                end

                if what == "pickoff" then
                    view.overlay = nil
                    drawPanel()
                    return
                end

                if what == "pick" then
                    switchTo(trimBoth(tostring(data.data or "")))
                    view.overlay = nil
                    drawPanel()
                    return
                end

                if what ~= "walk" then return end

                local target = safeNum(data.data)
                if not target or target == whereAt.vnum then return end

                -- Walked here rather than handed to walkTo, which needs the
                -- client's own map panel open and says so after a two second
                -- timeout -- a strange thing to require of a plugin that drew
                -- its own map. findPath works headless, so this asks for the
                -- directions and sends them.
                if not whereAt.vnum then
                    say("nowhere yet -- 'look' first.", "#ff6666")
                    return
                end

                local path = mapCall("findPath", whereAt.vnum, target)
                if type(path) ~= "table" or type(path.directions) ~= "table" then
                    say("no way there from here that the map knows about.", "#ffb02e")
                    return
                end

                local steps, n = {}, 0
                for _, d in ipairs(path.directions) do
                    n = n + 1
                    steps[n] = tostring(d)
                end
                if n == 0 then return end

                say("walking " .. n .. " step(s).")

                -- One at a time on a timer. Sent this way they never reach
                -- onCommand, so each is announced to ourselves first, or the
                -- rooms would land with no exits joining them.
                local timer = callable("addTimer")
                local i = 0
                local function stepOn()
                    i = i + 1
                    if i > n then return end
                    local d = nav.CANON[steps[i]:lower()]
                    if d then
                        pend.cmd = d
                        pend.at = os.time()
                    end
                    send(steps[i])
                    if timer and i < n then
                        pcall(function() return timer(400, stepOn) end)
                    end
                end
                stepOn()
            end)
        end)
    end

    drawPanel()
    return true
end

local function relockMap()
    drawPanel()
end

----------------------------------------------------------------------
-- doors, off the local map the server already sends
--
-- Map.Snapshot draws a 15x15 grid with the room you are in at the anchor,
-- normally 7,7. Rooms land on odd cells and the connector between two rooms on
-- the even cell between them, so the eight cells touching the anchor are the
-- eight ways out. Map.Definition names a style for each: 'exit' for an ordinary
-- one, 'door.closed' and 'door.locked' for the rest.
--
-- Which means the MUD has been telling us where the doors are the whole time.
----------------------------------------------------------------------

-- Cell offsets from the anchor, per direction.
paint.DOOR = {
    n  = {  0, -1 }, s  = {  0,  1 }, e  = {  1,  0 }, w  = { -1,  0 },
    ne = {  1, -1 }, nw = { -1, -1 }, se = {  1,  1 }, sw = { -1,  1 },
}

geo.ax, geo.ay = 7, 7

-- 'sector.inside' to 'inside'. The map stores a terrain string and the client
-- colours by it, so the prefix is ours to drop.
local function terrainOf(style)
    if type(style) ~= "string" then return nil end
    if style:sub(1, 7) ~= "sector." then return nil end
    local name = style:sub(8)
    if name == "" then return nil end
    return name
end

-- The last snapshot, kept so 'dbmap doors' can show what the server actually
-- said about the cells around you rather than us guessing why nothing matched.
-- The last snapshot and what has been worked out from it. Named 'shot'
-- rather than 'snap' on purpose: 'snap' is a parameter name in rowsOf, flat
-- and unwrapSnap, and a file-scope table those shadow is a table those
-- functions cannot reach.
local shot = {}

shot.last = nil
shot.count = 0

-- A GMCP array can arrive 0-indexed, as an object with numeric keys, or as
-- something else entirely. ipairs is the one thing that converts correctly.
local function flat(t)
    local out, n = {}, 0
    if type(t) ~= "table" then return out, 0 end
    for _, v in ipairs(t) do
        n = n + 1
        out[n] = v
    end
    return out, n
end

local function styleAt(runs, x, y)
    local rows, rn = flat(runs)
    if y + 1 > rn then return nil end

    -- Both values captured, every time. flat returns two, and taking only the
    -- first gives the WRAPPED PAIR here rather than the list -- so ipairs then
    -- walked a two-element wrapper instead of the runs and matched nothing.
    -- The row held [8, 1, "door.closed"] the whole time and this read null.
    --
    -- Sharp edge 4, and the probe three lines away got it right by accident of
    -- writing 'local entries, en = flat(row)'.
    --
    -- Runs are NOT sorted, so every one on the row has to be checked rather
    -- than walked with a cursor.
    local row, rowN = flat(rows[y + 1])
    for i = 1, rowN do
        local cells, cellN = flat(row[i])
        local rx, len = safeNum(cells[1]), safeNum(cells[2])
        if cellN >= 3 and rx and len and x >= rx and x < rx + len then
            return tostring(cells[3])
        end
    end
    return nil
end

-- The payload is not reliably the snapshot itself. The MUD's own dump shows it
-- nested -- map.snapshot.runs -- and the first read here got a callback that
-- fired with an object whose .rows was not a table, so it was handed the
-- wrapper. Dig for the level that actually has runs on it rather than assuming
-- either shape.
local function unwrapSnap(v, depth)
    if type(v) ~= "table" then return nil end
    if type(v.runs) == "table" then return v end
    if (depth or 0) > 3 then return nil end

    for _, key in ipairs({ "snapshot", "map", "Map", "Snapshot", "data" }) do
        local inner = unwrapSnap(v[key], (depth or 0) + 1)
        if inner then return inner end
    end
    return nil
end

-- Which way we moved, worked out from the local map rather than from anything
-- typed.
--
-- The anchor never moves: you are always at 7,7 and the world slides around
-- you. Step east and every row of the grid shifts two cells left, because
-- rooms sit on odd cells with a connector between. So the direction is
-- whichever shift makes the new grid line up with the old one.
--
-- This is worth more than intercepting the input. A macro's send never reaches
-- onCommand, and neither does a plugin's -- the training bot has had the same
-- blind spot from the start. The snapshot arrives whatever moved you.
shot.prev = nil
shot.dir = nil
shot.dirAt = 0

local function rowsOf(snap)
    local out, n = flat(snap.rows)
    if n == 0 then return nil end
    for i = 1, n do out[i] = tostring(out[i]) end
    return out, n
end

-- How much of the old grid, shifted, still matches the new one.
local function fitScore(old, new, n, dx, dy)
    local hits, tried = 0, 0

    -- The frame is not part of the world and does not move with it, so
    -- including it punishes the very shift we are looking for: every border
    -- character lines up only when nothing moved. Interior cells only.
    for y = 2, n - 1 do
        local from = old[y]
        local to = new[y + dy]
        if from and to then
            for x = 2, #from - 1 do
                local tx = x + dx
                if tx >= 2 and tx <= #to - 1 then
                    local a = from:sub(x, x)
                    local b = to:sub(tx, tx)
                    -- Blank against blank says nothing either way.
                    if a ~= " " or b ~= " " then
                        tried = tried + 1
                        if a == b then hits = hits + 1 end
                    end
                end
            end
        end
    end

    if tried < 8 then return -1 end
    return hits / tried
end

local function readMovement(snap)
    local new, n = rowsOf(snap)
    if not new then return end

    local old = shot.prev
    shot.prev = new
    if not old then return end

    -- Rooms are two cells apart in this grid, so one step is a two-cell shift.
    local best, bestDir, second = -1, nil, -1
    for dir, step in pairs(nav.STEP) do
        if step[3] == 0 then
            local s = fitScore(old, new, n, -step[1] * 2, -step[2] * 2)
            if s > best then
                second = best
                best = s
                bestDir = dir
            elseif s > second then
                second = s
            end
        end
    end

    -- Standing still fits perfectly, so it has to beat that too.
    local still = fitScore(old, new, n, 0, 0)

    -- Mobs wander between snapshots, so an exact match is not on offer. What is
    -- asked for is a clear winner: a good fit that beats both standing still
    -- and every other direction by a margin, or nothing is claimed at all.
    if bestDir and best > 0.85 and best > still + 0.02 and best > second + 0.02 then
        shot.dir = bestDir
        shot.dirAt = os.time()
    end
end

local function readDoors(payload)
    local snap = unwrapSnap(payload) or payload
    if type(snap) ~= "table" then return end
    shot.last = snap
    shot.count = shot.count + 1

    -- Before the door read, and whether or not we know where we are: the
    -- comparison needs every snapshot to keep its chain unbroken.
    readMovement(snap)

    if not whereAt.vnum then return end
    local runs = snap.runs
    if type(runs) ~= "table" then return end

    -- The anchor never carries a sector. Its role is 'current' -- it is spent
    -- saying where you are -- so reading terrain from it returned nil on every
    -- snapshot for eleven versions and no room ever got one. Proven with
    -- 'dbmap doors': anchor cell style=current, and the cells two out reading
    -- sector.inside.
    --
    -- The sectors are on the NEIGHBOURS, so that is where they are read from.
    -- Rooms sit two cells apart -- odd cells are rooms, even ones the connector
    -- between them -- and each is matched to a vnum through the exit that leads
    -- to it, once the room this snapshot was drawn for is known.
    --
    -- Which means a room's own sector arrives one step late: you learn it when
    -- you are standing next door. There is nowhere else it can come from.
    pend.terrain = nil
    pend.near = {}
    for dir, step in pairs(nav.STEP) do
        if step[3] == 0 then
            local t = terrainOf(styleAt(runs, geo.ax + step[1] * 2,
                                              geo.ay + step[2] * 2))
            -- A cell showing 'updown', 'mob', 'item' or 'aggro' is telling us
            -- about its contents rather than its ground, so it says nothing
            -- about the sector and nothing is recorded for it.
            if t then pend.near[dir] = t end
        end
    end

    pend.doors = {}
    for dir, off in pairs(paint.DOOR) do
        local style = styleAt(runs, geo.ax + off[1], geo.ay + off[2])
        -- Closed and locked only. The server draws a plain 'exit' for an open
        -- door and for a doorway that never had a door in it, so reading one as
        -- 'the door we know about is standing open' was an inference rather than
        -- a reading -- and a wrong door recorded once got downgraded to open
        -- instead of removed, which is how faded doorways ended up scattered
        -- over connections that have never had a door.
        if style == "door.locked" then pend.doors[dir] = 3
        elseif style == "door.closed" then pend.doors[dir] = 2 end
    end
end

-- Put the last snapshot's reading onto the room the room line just named.
local function applySnapshot(vnum)
    if not vnum then return end

    -- Each neighbour's sector, onto the neighbour. The exits are read off the
    -- room the snapshot was actually drawn for, which is why this waits for the
    -- room line rather than running where the cells were read.
    if type(pend.near) == "table" then
        local me = mapCall("getMapRoom", vnum)
        local exits = {}
        if type(me) == "table" and type(me.exits) == "table" then exits = me.exits end

        for dir, t in pairs(pend.near) do
            local to = safeNum(exits[dir])
            if to then
                local r = mapCall("getMapRoom", to)
                if type(r) == "table" and r.terrain ~= t then
                    if mapCall("updateMapRoom", to, { terrain = t }) then
                        forgetPositions()
                        view.dirty = true
                    end
                end
            end
        end
    end
    pend.near = nil

    if pend.terrain then
        local r = mapCall("getMapRoom", vnum)
        if type(r) == "table" and r.terrain ~= pend.terrain then
            mapCall("updateMapRoom", vnum, { terrain = pend.terrain })
            -- the position index carries the sector list with it, so a room
            -- learning its terrain has to drop the cache or the settings pane
            -- lists whatever was true when it was built
            forgetPositions()
            view.dirty = true
        end
    end

    -- Only ever written up, never down. A door that reads as a plain exit this
    -- pass is a door standing open, and taking the record away for it would have
    -- the doorway flicker off the map every time someone left it open. Removing
    -- a door stays a decision, which is what clicking it is for.
    if type(pend.doors) == "table" then
        for dir, status in pairs(pend.doors) do
            if status == 2 or status == 3 then
                if mapCall("setDoor", vnum, dir, status) then view.dirty = true end
            end
        end
    end

    pend.doors = nil
    pend.terrain = nil
end

----------------------------------------------------------------------
-- arriving somewhere
----------------------------------------------------------------------

local function arrive(hash, name)
    st.seen = st.seen + 1

    local fromVnum = whereAt.vnum

    -- An explicit 'dbgo' is the only thing that can cross to another planet or
    -- write a special exit.
    local travel = pend.travel
    pend.travel = nil

    local warp = pend.warp
    pend.warp = nil

    local dir = pend.cmd
    pend.cmd = nil
    if dir and os.time() - pend.at > STALE then dir = nil end

    -- Nothing typed, so ask the local map which way the world just moved. This
    -- is how a macro, an alias or another plugin's send gets its exit recorded
    -- -- none of them reach onCommand, and the numpad is most of how this MUD
    -- is walked.
    if not dir and shot.dir and os.time() - shot.dirAt <= STALE then
        dir = shot.dir
    end
    shot.dir = nil

    -- An instant transmission landing. Only when nothing else explains the
    -- move: a direction means you walked somewhere while it was still aligning,
    -- and the jump has not happened yet.
    local itArea = nil
    if it.want then
        if os.time() - it.at > IT_WINDOW then
            it.want = nil
        elseif it.left and not dir and not travel then
            itArea = it.want
            warp = "an instant transmission"
            it.want = nil
            it.left = false
        end
    end

    -- A warp is not a step. Whatever was typed did not take us here, and dying
    -- is not a route anyone can walk, so it gets no exit of either kind.
    if warp then
        dir = nil
        travel = nil
    end

    -- Following without recording. Everything below this writes to the map, so
    -- this is where it stops.
    --
    -- The room is found by its hash if it is already known. If it is not, we
    -- genuinely cannot say where you are -- and saying nothing is better than
    -- leaving the @ parked on the last room that WAS known, which is exactly
    -- the wrong-but-confident answer the rest of this plugin refuses to give.
    if not recording() then
        -- read for the panel, never applied, so they must not survive to be
        -- written the moment recording comes back on. One statement each:
        -- multi-assignment is only accepted on a declaration in this runtime.
        pend.doors = nil
        pend.near = nil
        pend.terrain = nil

        local known = safeNum(mapCall("getRoomIDbyHash", hash))
        if known and known < 0 then known = nil end

        whereAt.vnum = known
        if known then whereAt.hash = hash else whereAt.hash = "" end

        repaint()
        markHere()
        drawPanel()
        return
    end

    -- Work out the area BEFORE the room is made, or a new room on a new planet
    -- gets filed under the old one and has to be moved afterwards.
    if (travel or warp) and fromVnum then
        local known = safeNum(mapCall("getRoomIDbyHash", hash))
        if not known or known < 0 then known = nil end

        local want = areaAfterTransition(known, itArea)
        if want ~= area then
            area = want
            forgetPositions()
            baseFor(area)
            mapCall("addAreaName", area)
            relockMap()
            -- Landing somewhere already mapped adopts that room's area, so
            -- being sent home usually names itself and this reads as a
            -- confirmation rather than a question.
            say((warp or "that was a transition")
                .. " -- new rooms go into '" .. area
                .. "'. 'dbmap rename <name>' when you know what it is called.",
                "#ffb02e")
        end
    end

    local vnum, isNew = ensureRoom(hash, name, fromVnum, dir)
    if not vnum then return end

    -- Landing in a room the map already files under another area takes the
    -- recording area with it.
    --
    -- This is a lookup, not a guess: that room was filed there, by a transition
    -- or by hand. Staying put meant a teleport out of an area left the panel
    -- drawing the one you had left -- positions() only indexes the area being
    -- recorded into, so the grid came up empty with a single @ on it and the
    -- footer naming somewhere you were not.
    --
    -- Only for a room we did not just make. A new one is filed under the
    -- current area by definition and can never disagree with it.
    if not isNew then
        local its = nil
        local r = mapCall("getMapRoom", vnum)
        -- read in two steps: a guard and a field access on the same value in
        -- one expression is not safe here
        if type(r) == "table" then its = r.area end

        if type(its) == "string" and its ~= "" and its ~= area then
            area = its
            forgetPositions()
            baseFor(area)
            mapCall("addAreaName", area)
            relockMap()
            savePrefs()
            say("this room is in '" .. area .. "' -- new rooms go there now.",
                "#ffb02e")
        end
    end

    whereAt.from, whereAt.by = nil, nil
    if fromVnum then
        if travel then
            recordTravel(fromVnum, travel, vnum)
        elseif dir then
            recordMove(fromVnum, dir, vnum)
            -- Held for the exits line, which arrives next and says whether the
            -- way back exists.
            whereAt.from, whereAt.by = fromVnum, dir
        end
    end

    whereAt.vnum = vnum
    whereAt.hash = hash

    -- The MUD says what kind of room this is in the name itself, so read it.
    applyNameFlag(vnum, name)

    -- Walking snaps the view back to you. Looking around is a thing you do
    -- while standing still; the moment you move, following you is what the
    -- panel is for.
    recentre()

    -- Now that the room is named, the snapshot's reading belongs to it.
    applySnapshot(vnum)

    if isNew then savePrefs() end
    repaint()
    markHere()
    drawPanel()
end

----------------------------------------------------------------------
-- repair
----------------------------------------------------------------------

-- There is no map-wide list of special exits, so they are found the long way:
-- every area, every room in it, then that room's own specials. getAreaList is
-- name-keyed; getAreaRooms is one of the 0-indexed arrays, so ipairs.
local function eachSpecial(fn)
    local areas = mapCall("getAreaList")
    if type(areas) ~= "table" then return end

    for name in pairs(areas) do
        local list = mapCall("getAreaRooms", name)
        if type(list) == "table" then
            for _, raw in ipairs(list) do
                local vnum = safeNum(raw) or raw
                local sp = mapCall("getSpecialExits", vnum)
                if type(sp) == "table" then
                    for cmd, dest in pairs(sp) do fn(vnum, cmd, dest, name) end
                end
            end
        end
    end
end

-- Removes special exits nothing ever declared as travel, and area names left
-- holding no rooms. Rooms are never touched -- 'dbmap drop' does that, and only
-- when asked twice.
local function cleanMap(commit)
    local bogus, kept = {}, 0
    -- collected first, removed after: the walk reads lists the removal changes
    eachSpecial(function(vnum, cmd, dest)
        if travels[cmd] then
            kept = kept + 1
        else
            bogus[#bogus + 1] = { vnum = vnum, cmd = cmd, dest = dest }
        end
    end)

    local empties = {}
    local areas = mapCall("getAreaList")
    if type(areas) == "table" then
        for name, count in pairs(areas) do
            if safeNum(count) == 0 and name ~= area then
                empties[#empties + 1] = name
            end
        end
    end

    local orphans = {}
    for name in pairs(bases) do
        if type(areas) ~= "table" or areas[name] == nil then
            orphans[#orphans + 1] = name
        end
    end

    if #bogus == 0 and #empties == 0 and #orphans == 0 then
        say("nothing to clean. " .. kept .. " declared special exit(s) left alone.")
        return
    end

    for _, b in ipairs(bogus) do
        print(TAG .. (commit and "  removed " or "  would remove ")
            .. "special exit '" .. b.cmd .. "' from room " .. tostring(b.vnum)
            .. " -> " .. tostring(b.dest))
        if commit then
            if mapCall("removeSpecialExit", b.vnum, b.cmd) then
                st.specials = st.specials - 1
                view.dirty = true
            end
        end
    end

    for _, name in ipairs(empties) do
        print(TAG .. (commit and "  dropped empty area '" or "  would drop empty area '")
            .. name .. "'")
        if commit then
            mapCall("deleteArea", name)
            bases[name] = nil
        end
    end

    for _, name in ipairs(orphans) do
        print(TAG .. (commit and "  released block " or "  would release block ")
            .. tostring(bases[name]) .. " held for '" .. name .. "'")
        if commit then bases[name] = nil end
    end

    if commit then
        if st.specials < 0 then st.specials = 0 end
        savePrefs()
        repaint()
        say("cleaned. " .. kept .. " declared special exit(s) left alone.")
    else
        say(#bogus .. " bogus exit(s), " .. #empties .. " empty area(s), "
            .. #orphans .. " stale block(s). 'dbmap clean go' to do it.", "#ffb02e")
    end
end

-- A room's manual offset, kept on the room itself.
--
-- Relayout throws every coordinate away and works them out again from the
-- exits, so without this a nudge lasted until the next relayout and hand-tuning
-- a map was time spent on something that would be wiped. Room user data travels
-- with the room, which means it survives that -- and an export.
local function nudgeOf(vnum)
    local v = mapCall("getRoomUserData", vnum, "dbmap.nudge")
    if type(v) ~= "string" then return 0, 0 end
    local dx, dy = v:match("^(%-?%d+),(%-?%d+)$")
    return safeNum(dx) or 0, safeNum(dy) or 0
end

local function setNudge(vnum, dx, dy)
    if dx == 0 and dy == 0 then
        mapCall("setRoomUserData", vnum, "dbmap.nudge", nil)
    else
        mapCall("setRoomUserData", vnum, "dbmap.nudge", dx .. "," .. dy)
    end
end

-- Lay the whole area out again from the exits, rather than from the order it
-- happened to be walked in.
--
-- The case this exists for: a ring of rooms mapped first, then its interior.
-- The ring encloses however much space its own room count gives it, and if the
-- inside holds more rooms than that, they cannot fit -- the interior lands on
-- the ring. Spacing does not help, because scaling grows the ring and the
-- interior by the same factor. The ring has to grow while the interior does
-- not, and the only way to know by how much is to place everything again and
-- widen wherever it actually runs out of room.
--
-- Done as one pass from scratch, never incrementally on the live map. Doing it
-- a room at a time is what tore the elite quarters into separate clusters:
-- each widen moved rooms that were already placed, and the errors compounded.
-- Here nothing is written until the whole layout is known.
local function relayout(commit)
    local list = mapCall("getAreaRooms", area)
    if type(list) ~= "table" then
        say("nothing in '" .. area .. "'.", "#ffb02e")
        return
    end

    local all, n = {}, 0
    local inArea = {}
    for _, raw in ipairs(list) do
        local vnum = safeNum(raw) or raw
        local r = mapCall("getMapRoom", vnum)
        if type(r) == "table" then
            n = n + 1
            all[n] = { vnum = vnum, exits = r.exits }
            inArea[vnum] = n
        end
    end
    if n == 0 then
        say("nothing placed in '" .. area .. "'.", "#ffb02e")
        return
    end

    local pos, at = {}, {}
    local nudged = 0

    local function key(x, y) return x .. "," .. y end

    -- Start from the most connected room, not from wherever you are standing.
    --
    -- A dense block -- two columns with both diagonals between every pair -- has
    -- exactly one possible shape. A long loop with cut corners can be any size.
    -- Place the loop first and the block has to fit whatever space is left over,
    -- which is the whole problem; place the block first and the loop grows
    -- around it. Exit count is a good enough proxy for which is which.
    --
    -- The panel still centres on the room you are in, so this changes the
    -- layout without changing the view.
    local startAt, bestExits = 1, -1
    for i = 1, n do
        local e = 0
        if type(all[i].exits) == "table" then
            for _ in pairs(all[i].exits) do e = e + 1 end
        end
        if e > bestExits then
            bestExits = e
            startAt = i
        end
    end

    local queue, head, tail = {}, 1, 0
    local function seed(idx)
        local vnum = all[idx].vnum
        if pos[vnum] then return end
        -- somewhere clear of everything placed so far
        local x, y = 0, 0
        for _, p in pairs(pos) do
            if p[2] >= y then y = p[2] + nav.dist.y * 2 end
        end
        while at[key(x, y)] do x = x + nav.dist.x end
        pos[vnum] = { x, y }
        at[key(x, y)] = vnum
        tail = tail + 1
        queue[tail] = vnum
    end

    seed(startAt)

    local placed = 1
    while head <= tail do
        local vnum = queue[head]
        head = head + 1
        local idx = inArea[vnum]
        local exits = idx and all[idx].exits

        if type(exits) == "table" then
            for dir, dest in pairs(exits) do
                local step = nav.STEP[dir]
                local to = safeNum(dest)
                if step and to and inArea[to] and not pos[to] then
                    local px, py = pos[vnum][1], pos[vnum][2]
                    local tx = px + step[1] * nav.dist.x
                    local ty = py + step[2] * nav.dist.y

                    -- Out of room: take the nearest free square to where it
                    -- should have gone.
                    --
                    -- This used to widen -- push everything from that line
                    -- outward and try again. It made space, and it did it by
                    -- pulling apart pairs of rooms that were correctly next to
                    -- each other, so their connections then had to reach across
                    -- the new gap. Seventeen widenings drew the whole base as a
                    -- web of long crossing lines.
                    --
                    -- A room one square off where it belongs reads as very
                    -- nearly right. A room in the right place with a line
                    -- running halfway across the map does not. This graph has
                    -- rooms with eight exits including every diagonal, which no
                    -- flat grid can hold without conflicts, so the choice is
                    -- only ever which kind of wrong to draw.
                    if at[key(tx, ty)] then
                        local best = nil
                        for ring = 1, 4 do
                            for ry = -ring, ring do
                                for rx = -ring, ring do
                                    if not best and (math.abs(rx) == ring or math.abs(ry) == ring)
                                        and not at[key(tx + rx, ty + ry)] then
                                        best = { tx + rx, ty + ry }
                                    end
                                end
                            end
                        end
                        if best then
                            tx, ty = best[1], best[2]
                            nudged = nudged + 1
                        end
                    end

                    if not at[key(tx, ty)] then
                        pos[to] = { tx, ty }
                        at[key(tx, ty)] = to
                        placed = placed + 1
                        tail = tail + 1
                        queue[tail] = to
                    end
                end
            end
        end

        -- Nothing left connected, but rooms still unplaced: another island.
        if head > tail then
            for i = 1, n do
                if not pos[all[i].vnum] then
                    seed(i)
                    placed = placed + 1
                    break
                end
            end
        end
    end

    if not commit then
        say(placed .. " of " .. n .. " room(s) would be laid out again, "
            .. nudged .. " of them a square off where the exits say. "
            .. "'dbmap relayout go' to do it.", "#ffb02e")
        return
    end

    local wrote, kept = 0, 0
    for vnum, p in pairs(pos) do
        -- Whatever was moved by hand stays moved. Otherwise laying the area out
        -- again quietly undid every correction made to it, and hand-tuning a
        -- map was work with a short life.
        local dx, dy = nudgeOf(vnum)
        if dx ~= 0 or dy ~= 0 then kept = kept + 1 end
        if mapCall("updateMapRoom", vnum, { x = p[1] + dx, y = p[2] + dy }) then
            wrote = wrote + 1
        end
    end

    forgetPositions()
    view.dirty = true
    repaint()
    drawPanel()
    say(wrote .. " room(s) laid out again, " .. nudged
        .. " of them a square off where the exits say"
        .. (kept > 0 and (", and " .. kept .. " kept where you put them") or "")
        .. ".")
end

-- Move one room, and only that room.
--
-- Everything else that moves rooms moves a lot of them: stretch takes a whole
-- line, relayout takes the area. Most of what is left wrong after those is one
-- room sitting a square from where it reads best, and shoving its entire column
-- to fix it is worse than the problem.
--
-- Coordinates only. Exits, doors and stubs are untouched, so this changes where
-- the room is drawn and nothing about what it is connected to.
-- Put a room back where the layout would have put it.
local function unnudgeRoom(vnum)
    local dx, dy = nudgeOf(vnum)
    if dx == 0 and dy == 0 then
        say("that room has not been moved by hand.", "#ffb02e")
        return
    end

    local r = mapCall("getMapRoom", vnum)
    if type(r) ~= "table" then
        say("no room " .. tostring(vnum) .. ".", "#ff6666")
        return
    end

    mapCall("updateMapRoom", vnum, {
        x = (safeNum(r.x) or 0) - dx,
        y = (safeNum(r.y) or 0) - dy,
    })
    setNudge(vnum, 0, 0)

    forgetPositions()
    view.dirty = true
    repaint()
    drawPanel()
    say(tostring(r.name) .. " put back.")
end

-- A block of vnums, moved as one.
--
-- Not nudgeRoom() in a loop: that one pushes whatever is in its way, which is
-- the right answer for a single room and nonsense for a group -- each member
-- would shove the next and the shape would come apart. A range moves together,
-- so nothing inside it can collide with anything else inside it.
--
-- Vnums are handed out in walk order within an area's block, so a cluster
-- walked in one go is usually contiguous. That is the whole reason this is a
-- useful way to say "these rooms": no graph analysis, no guessing which ones
-- were meant, just the ones named.
local RANGE_MAX = 500

local function nudgeRange(fromV, toV, dirWord, howFar, undo)
    if fromV > toV then
        local swap = fromV
        fromV = toV
        toV = swap
    end
    if toV - fromV >= RANGE_MAX then
        say("that is more than " .. RANGE_MAX .. " rooms. Narrow it.", "#ff6666")
        return
    end

    local step = nil
    local dir = nil
    if not undo then
        dir = nav.CANON[dirWord or ""]
        if dir then step = nav.STEP[dir] end
        if not step then
            say("dbmap nudge <vnum>-<vnum> <dir> [squares] | reset", "#ff6666")
            return
        end
    end

    local n = math.floor(math.max(1, math.min(howFar or 1, 8)))

    -- Only this area. A range that strays into another block would otherwise
    -- drag somebody else's planet sideways, and that is not recoverable by
    -- looking at it.
    local mine = {}
    local list = mapCall("getAreaRooms", area)
    if type(list) == "table" then
        for _, raw in ipairs(list) do
            local v = safeNum(raw) or raw
            if v and v >= fromV and v <= toV then mine[#mine + 1] = v end
        end
    end

    if #mine == 0 then
        say("no rooms of '" .. area .. "' between " .. fromV .. " and " .. toV
            .. ".", "#ffb02e")
        return
    end

    local moved = 0
    for _, v in ipairs(mine) do
        if undo then
            local hx, hy = nudgeOf(v)
            local r = mapCall("getMapRoom", v)
            if type(r) == "table" and (hx ~= 0 or hy ~= 0) then
                local ok = mapCall("updateMapRoom", v, {
                    x = (safeNum(r.x) or 0) - hx,
                    y = (safeNum(r.y) or 0) - hy,
                })
                if ok then
                    setNudge(v, 0, 0)
                    moved = moved + 1
                end
            end
        else
            local r = mapCall("getMapRoom", v)
            if type(r) == "table" then
                local ok = mapCall("updateMapRoom", v, {
                    x = (safeNum(r.x) or 0) + step[1] * n,
                    y = (safeNum(r.y) or 0) + step[2] * n,
                    z = (safeNum(r.z) or 0) + step[3] * n,
                })
                if ok then
                    -- remembered per room, so relayout keeps the shape
                    local hx, hy = nudgeOf(v)
                    setNudge(v, hx + step[1] * n, hy + step[2] * n)
                    moved = moved + 1
                end
            end
        end
    end

    if moved == 0 then
        say("nothing moved.", "#ffb02e")
        return
    end

    forgetPositions()
    view.dirty = true
    repaint()
    drawPanel()

    if undo then
        say(moved .. " room(s) put back.")
        return
    end

    -- Landing on rooms outside the range is allowed -- the alternative is
    -- refusing exactly when the map most needs rearranging -- but it is said
    -- out loud rather than left to be noticed.
    local at = positions()
    local inRange = {}
    for _, v in ipairs(mine) do inRange[v] = true end

    local stacked = 0
    for _, v in ipairs(mine) do
        local r = mapCall("getMapRoom", v)
        if type(r) == "table" then
            local key = (safeNum(r.x) or 0) .. "," .. (safeNum(r.y) or 0)
                .. "," .. (safeNum(r.z) or 0)
            local other = at[key]
            if other and not inRange[safeNum(other) or other] then
                stacked = stacked + 1
            end
        end
    end

    say(moved .. " room(s) moved " .. n .. " " .. dir .. ". 'dbmap nudge "
        .. fromV .. "-" .. toV .. " reset' puts them back.")
    if stacked > 0 then
        say(stacked .. " landed on a room outside the range -- 'dbmap audit'"
            .. " lists them.", "#ffb02e")
    end
end

local function nudgeRoom(vnum, dirWord, howFar)
    local dir = nav.CANON[dirWord or ""]
    local step = dir and nav.STEP[dir]
    if not step then
        say("dbmap nudge [<vnum>] <dir|reset> [squares]", "#ff6666")
        return
    end

    local r = mapCall("getMapRoom", vnum)
    if type(r) ~= "table" then
        say("no room " .. tostring(vnum) .. ".", "#ff6666")
        return
    end

    local n = math.floor(math.max(1, math.min(howFar or 1, 8)))
    local x = (safeNum(r.x) or 0) + step[1] * n
    local y = (safeNum(r.y) or 0) + step[2] * n
    local z = (safeNum(r.z) or 0) + step[3] * n

    -- Whatever is in the way comes along.
    --
    -- Refusing was the wrong answer: on a map dense enough to need tidying,
    -- the square you want is usually taken, and "something is already there"
    -- just means the tool stops working exactly when it is needed. Pushing a
    -- room pushes the one it would land on, and so on down the line.
    local at = positions()
    local train = { vnum }
    local cx, cy, cz = x, y, z

    while #train < 12 do
        local blocker = at[cx .. "," .. cy .. "," .. cz]
        if not blocker then break end
        train[#train + 1] = blocker
        cx = cx + step[1] * n
        cy = cy + step[2] * n
        cz = cz + step[3] * n
    end

    if at[cx .. "," .. cy .. "," .. cz] then
        say("too many rooms in the way to shift them all.", "#ff6666")
        return
    end

    -- From the far end back, so each one moves into space just vacated.
    local moved = 0
    for i = #train, 1, -1 do
        local each = train[i]
        local rr = mapCall("getMapRoom", each)
        if type(rr) == "table" then
            local ex = (safeNum(rr.x) or 0) + step[1] * n
            local ey = (safeNum(rr.y) or 0) + step[2] * n
            local ez = (safeNum(rr.z) or 0) + step[3] * n
            if mapCall("updateMapRoom", each, { x = ex, y = ey, z = ez }) then
                moved = moved + 1
                -- Remembered, so relayout can put them back afterwards.
                local hadX, hadY = nudgeOf(each)
                setNudge(each, hadX + step[1] * n, hadY + step[2] * n)
            end
        end
    end

    if moved == 0 then
        say("the map refused it.", "#ff6666")
        return
    end

    forgetPositions()
    view.dirty = true
    repaint()
    drawPanel()

    if moved > 1 then
        say(moved .. " rooms moved " .. n .. " " .. dir
            .. " -- the ones in the way came too.")
    else
        say(tostring(r.name) .. " moved " .. n .. " " .. dir
            .. ". 'dbmap nudge " .. vnum .. " reset' puts it back.")
    end
end

-- The route to a room, and walking it.
--
-- The client's own 'mapper goto' and 'mapper path' cannot do either here: they
-- route from getPlayerRoom(), which is fed by GMCP, which this MUD does not
-- send. Every one of them answers "No current room found." We know exactly
-- where we are, so these work where those cannot.
local function pathTo(target)
    if not whereAt.vnum then
        say("nowhere yet -- 'look' first.", "#ff6666")
        return nil
    end
    if not target then
        say("dbmap goto <vnum>", "#ff6666")
        return nil
    end
    if target == whereAt.vnum then
        say("you are already there.", "#ffb02e")
        return nil
    end

    local r = mapCall("getMapRoom", target)
    if type(r) ~= "table" then
        say("no room " .. tostring(target) .. ".", "#ff6666")
        return nil
    end

    local path = mapCall("findPath", whereAt.vnum, target)
    if type(path) ~= "table" or type(path.directions) ~= "table" then
        say("no way there from here that the map knows about.", "#ffb02e")
        return nil
    end

    local steps, n = {}, 0
    for _, d in ipairs(path.directions) do
        n = n + 1
        steps[n] = tostring(d)
    end
    if n == 0 then return nil end
    return steps, n, r
end

-- The MUD's own speedwalk encoding, from 'help speedwalk'. The compass
-- directions are their first letter as you would expect; the diagonals are
-- not, and that is the whole reason this is a table rather than a sub(1,1):
--
--          r n q
--           \|/
--         w -x- e
--           /|\
--          y s t
--
-- 'speedwalk nnnneq' walks it in one command, which beats the client's own
-- '3n2eu' -- that reads nicely and cannot be sent anywhere.
nav.LETTER = {
    n = "n", s = "s", e = "e", w = "w", u = "u", d = "d",
    ne = "q", nw = "r", se = "t", sw = "y",
}

-- Spelled out for 'open' and 'unlock'. The MUD takes abbreviations, but a
-- route you might read back later should not need decoding.
nav.WORD = {
    n = "north", s = "south", e = "east", w = "west",
    ne = "northeast", nw = "northwest", se = "southeast", sw = "southwest",
    u = "up", d = "down",
}

-- The rooms a route departs from, worked out by walking the exits rather than
-- trusting the shape of what findPath returns alongside its directions.
local function roomsAlong(steps, n)
    local out = {}
    local at = whereAt.vnum
    for i = 1, n do
        out[i] = at
        local d = nav.CANON[steps[i]:lower()]
        local r = at and mapCall("getMapRoom", at)
        if type(r) == "table" and type(r.exits) == "table" and d then
            at = safeNum(r.exits[d])
        else
            at = nil
        end
    end
    return out
end

-- A route as lines to send, split wherever a door is in the way.
--
-- A speedwalk that meets a closed door stops there and says nothing about
-- where it stopped, so the door has to be opened between two shorter walks:
--
--   speedwalk eets
--   open east
--   speedwalk en
--
-- Locked ones get an unlock first. Doors we have recorded as open need
-- neither, which is what makes recording the open state worth doing.
local function routeLines(steps, n)
    local from = roomsAlong(steps, n)
    local lines, run = {}, {}

    local function flushRun()
        if #run > 0 then
            lines[#lines + 1] = "speedwalk " .. table.concat(run)
            run = {}
        end
    end

    for i = 1, n do
        local d = nav.CANON[steps[i]:lower()]
        local letter = d and nav.LETTER[d]
        -- One step it cannot encode makes the whole thing wrong rather than
        -- short, so say so instead of handing over a route that walks into a
        -- wall.
        if not letter then return nil end

        local doors = from[i] and mapCall("getDoors", from[i])
        local status = type(doors) == "table" and safeNum(doors[d]) or nil

        if status == 2 or status == 3 then
            flushRun()
            if status == 3 then
                lines[#lines + 1] = "unlock " .. (nav.WORD[d] or d)
            end
            lines[#lines + 1] = "open " .. (nav.WORD[d] or d)
        end

        run[#run + 1] = letter
    end

    flushRun()
    return lines
end

local function squash(steps, n)
    local lines = routeLines(steps, n)
    if not lines then return nil end
    return table.concat(lines, " ; ")
end

local function walkPath(steps, n)
    local from = roomsAlong(steps, n)
    local i = 0
    local timer = callable("addTimer")

    -- One at a time on a timer. Sent this way they never reach onCommand, so
    -- each is announced to ourselves first, or the rooms would land with no
    -- exits joining them.
    local function onward()
        i = i + 1
        if i > n then return end

        local d = nav.CANON[steps[i]:lower()]

        -- Anything shut gets opened first, or the walk stops here and the map
        -- carries on believing we went through.
        local doors = from[i] and mapCall("getDoors", from[i])
        local status = type(doors) == "table" and d and safeNum(doors[d]) or nil
        if status == 3 then send("unlock " .. (nav.WORD[d] or d)) end
        if status == 2 or status == 3 then send("open " .. (nav.WORD[d] or d)) end

        if d then
            pend.cmd = d
            pend.at = os.time()
        end
        send(steps[i])

        if timer and i < n then
            pcall(function() return timer(400, onward) end)
        end
    end
    onward()
end

-- Search results, shaped like the client's own and clickable through to ours.
--
-- The built-in 'mapper find' lists rooms you can click to walk to, and every
-- one of them answers "No current room found." here, because it routes from
-- getPlayerRoom(). Same list, same numbering, links that go somewhere.
local function findRooms(q, limit)
    if q == "" then
        say("dbmap find <text>", "#ff6666")
        return
    end

    local hits = mapCall("searchRooms", q)
    if type(hits) ~= "table" then
        say("nothing matching '" .. q .. "'.", "#ffb02e")
        return
    end

    lastFind = {}
    local shown, total = 0, 0
    local link = callable("hyperlink")

    for _, r in ipairs(hits) do
        total = total + 1
        local vnum = safeNum(r.num)
        if vnum then lastFind[#lastFind + 1] = vnum end

        if vnum and shown < limit then
            shown = shown + 1

            local mark = ""
            if vnum == whereAt.vnum then mark = " <- you are here" end

            local doorN = 0
            local doors = mapCall("getDoors", vnum)
            if type(doors) == "table" then
                for _ in pairs(doors) do doorN = doorN + 1 end
            end

            local label = "[" .. shown .. "] " .. tostring(r.name)
                .. " (" .. tostring(r.area) .. ") (" .. vnum .. ")"
                .. (doorN > 0 and (" " .. doorN .. "d") or "") .. mark

            -- Clicking sends our own goto, which knows where you are.
            if link then
                pcall(function()
                    return link(label, "dbmap goto " .. vnum,
                        { hint = "walk to " .. tostring(r.name) })
                end)
            else
                print(TAG .. "  " .. label)
            end
        end
    end

    if total == 0 then
        say("nothing matching '" .. q .. "'.", "#ffb02e")
        return
    end

    say(total .. " room(s)" .. (shown < total and (", " .. shown .. " shown") or "")
        .. ". Click one to walk there, or 'dbmap forget found go' to delete them.")
end

-- Both commands through one door. Lua 5.1 caps a function at 60 upvalues and
-- the command handler is where that ceiling gets hit, so every branch it grows
-- has to arrive as a single name.
local function routeCmd(target, walkIt)
    local steps, n, r = pathTo(target)
    if not steps then return end

    local walk = squash(steps, n)

    if walkIt then
        -- Stepped rather than sent as one speedwalk. A speedwalk that meets a
        -- closed door stops partway with nothing said about where it got to;
        -- stepping means every room on the way is recorded as it is reached.
        say("walking " .. n .. " step(s)"
            .. (walk and (": speedwalk " .. walk) or "") .. ".")
        walkPath(steps, n)
    elseif walk then
        say("speedwalk " .. walk .. "  (" .. n .. " step(s) to "
            .. tostring(r.name) .. ")")
    else
        say(n .. " step(s) to " .. tostring(r.name)
            .. ", but the route needs a direction speedwalk cannot carry.",
            "#ffb02e")
    end
end

-- Open a gap next to the room you are standing in, in one direction.
--
-- Anchored on you rather than on a connection, because a map is a rigid grid: a
-- room's position is shared by every exit touching it, so there is no way to
-- lengthen one edge without either dragging everything hanging off its far end
-- or putting a room in two places. Anchoring here makes it predictable -- push
-- everything east of me further east -- and a loop cannot confuse it.
local function stretchFrom(dirWord, amount)
    local dir = nav.CANON[dirWord or ""]
    if not dir or not nav.STEP[dir] then
        say("dbmap stretch <n|s|e|w> [squares]", "#ff6666")
        return
    end
    if not whereAt.vnum then
        say("nowhere yet -- 'look' first.", "#ff6666")
        return
    end

    local step = nav.STEP[dir]
    if step[1] ~= 0 and step[2] ~= 0 then
        say("one axis at a time: n, s, e or w.", "#ff6666")
        return
    end

    local here = mapCall("getMapRoom", whereAt.vnum)
    if type(here) ~= "table" then return end

    local axis = step[1] ~= 0 and "x" or "y"
    local sign = (step[1] ~= 0 and step[1] or step[2]) > 0 and 1 or -1
    local from = safeNum(axis == "x" and here.x or here.y)
    if not from then return end

    -- from the next square along, so the room you are in does not move
    local line = from + sign * distFor(axis)
    local n = math.floor(math.max(1, math.min(amount or 1, 6)))

    local moved = 0
    for _ = 1, n do
        if widenAt(axis, line, sign) then moved = moved + 1 end
    end

    if moved == 0 then
        say("nothing " .. dir .. " of here to move.", "#ffb02e")
        return
    end

    savePrefs()
    repaint()
    drawPanel()
    say("pushed everything " .. dir .. " of here out by "
        .. (moved * distFor(axis)) .. ".")
end

-- Put an area back on a clean grid, whatever it has been stretched to.
--
-- Every distinct x becomes the next multiple of spread, and the same for y. So
-- the order survives -- a room west of another is still west of it -- and two
-- rooms that had different coordinates still do, which is what stops a reset
-- from dropping one section back on top of another. What it discards is the
-- accumulated distance, which is the point: after enough stretching the map is
-- mostly empty space.
local function refit(commit)
    local list = mapCall("getAreaRooms", area)
    if type(list) ~= "table" then
        say("nothing in '" .. area .. "'.", "#ffb02e")
        return
    end

    local rooms, xs, ys = {}, {}, {}
    local seenX, seenY = {}, {}
    for _, raw in ipairs(list) do
        local vnum = safeNum(raw) or raw
        local r = mapCall("getMapRoom", vnum)
        if type(r) == "table" then
            local x, y = safeNum(r.x), safeNum(r.y)
            if x and y then
                rooms[#rooms + 1] = { vnum = vnum, x = x, y = y }
                if not seenX[x] then seenX[x] = true xs[#xs + 1] = x end
                if not seenY[y] then seenY[y] = true ys[#ys + 1] = y end
            end
        end
    end

    if #rooms == 0 then
        say("nothing placed in '" .. area .. "'.", "#ffb02e")
        return
    end

    table.sort(xs)
    table.sort(ys)

    -- Scaled, not ranked.
    --
    -- Ranking put every distinct coordinate on the next slot along, so a gap of
    -- four and a gap of one both came out as one: eighteen rooms squashed into
    -- five by five with the shape gone. Dividing by the smallest gap instead
    -- takes the bloat out and leaves the proportions, so a room four steps from
    -- its neighbour stays four times as far as one that is next door.
    local function scaleFor(list, unit)
        local smallest = nil
        for i = 2, #list do
            local gap = list[i] - list[i - 1]
            if gap > 0 and (not smallest or gap < smallest) then smallest = gap end
        end
        if not smallest or smallest < 1 then smallest = 1 end

        local out = {}
        local first = list[1] or 0
        for _, v in ipairs(list) do
            out[v] = math.floor((v - first) / smallest * unit + 0.5)
        end
        return out
    end

    local rankX = scaleFor(xs, nav.dist.x)
    local rankY = scaleFor(ys, nav.dist.y)

    local wide = (xs[#xs] - xs[1])
    local tall = (ys[#ys] - ys[1])
    local newWide = (rankX[xs[#xs]] or 0) - (rankX[xs[1]] or 0)
    local newTall = (rankY[ys[#ys]] or 0) - (rankY[ys[1]] or 0)

    if not commit then
        say(#rooms .. " room(s) in '" .. area .. "': " .. wide .. "x" .. tall
            .. " becomes " .. newWide .. "x" .. newTall
            .. ". 'dbmap respace fit go' to do it.", "#ffb02e")
        return
    end

    for _, r in ipairs(rooms) do
        mapCall("updateMapRoom", r.vnum, { x = rankX[r.x], y = rankY[r.y] })
    end

    forgetPositions()
    view.dirty = true
    repaint()
    drawPanel()
    say(#rooms .. " room(s) back on a clean grid, " .. newWide .. "x" .. newTall .. ".")
end

-- Scale an area's coordinates out by a factor.
--
-- Rooms recorded before the spacing changed sit one square apart, and the nodes
-- are drawn for two, so they overlap into a single blob with no lines visible
-- between them. Multiplying by two puts an old layout on the current grid
-- without rewalking any of it. Relative positions are untouched, so the map
-- still says exactly what it said before.
local function respace(factor, commit)
    if not factor or factor < 2 or factor > 8 then
        say("dbmap respace <2-8> [go] -- 2 for a map drawn before the spacing changed.", "#ff6666")
        return
    end

    local list = mapCall("getAreaRooms", area)
    if type(list) ~= "table" then
        say("nothing in '" .. area .. "'.", "#ffb02e")
        return
    end

    local n = 0
    for _, raw in ipairs(list) do
        local vnum = safeNum(raw) or raw
        local r = mapCall("getMapRoom", vnum)
        if type(r) == "table" then
            local x, y = safeNum(r.x), safeNum(r.y)
            if x and y then
                n = n + 1
                if commit then
                    mapCall("updateMapRoom", vnum, { x = x * factor, y = y * factor })
                end
            end
        end
    end

    if not commit then
        say(n .. " room(s) in '" .. area .. "' would spread out " .. factor
            .. "x. 'dbmap respace " .. factor .. " go' to do it.", "#ffb02e")
        return
    end

    forgetPositions()
    view.dirty = true
    repaint()
    drawPanel()
    say(n .. " room(s) spread out " .. factor .. "x.")
end

-- One room, or everything the last 'find' listed.
--
-- Rooms get recorded that should not exist: a room minted before a reload with
-- no way in, one the old inference filed under an invented area, a duplicate
-- from a hash that changed. Dropping a whole area to lose one of them is too
-- blunt.
local function forgetRooms(what, commit)
    local targets = {}

    if what == "found" then
        for _, vnum in ipairs(lastFind) do targets[#targets + 1] = vnum end
        if #targets == 0 then
            say("nothing found yet -- 'dbmap find <text>' first.", "#ff6666")
            return
        end
    else
        -- A range, the same shape 'nudge' takes: '10004-10021'. Only rooms of
        -- the area being recorded into, so a range that strays into another
        -- block cannot quietly delete somebody else's planet -- and unlike a
        -- nudge, that one does not undo.
        local rawA, rawB = what:match("^(%d+)%-(%d+)$")
        local fromV = safeNum(textOf(rawA))
        local toV = safeNum(textOf(rawB))

        if fromV and toV then
            if fromV > toV then
                local swap = fromV
                fromV = toV
                toV = swap
            end
            if toV - fromV >= RANGE_MAX then
                say("that is more than " .. RANGE_MAX .. " rooms. Narrow it.",
                    "#ff6666")
                return
            end

            local list = mapCall("getAreaRooms", area)
            if type(list) == "table" then
                for _, raw in ipairs(list) do
                    local v = safeNum(raw) or raw
                    if v and v >= fromV and v <= toV then
                        targets[#targets + 1] = v
                    end
                end
            end

            if #targets == 0 then
                say("no rooms of '" .. area .. "' between " .. fromV .. " and "
                    .. toV .. ".", "#ffb02e")
                return
            end
        else
            local vnum = safeNum(what)
            if not vnum then
                say("dbmap forget <vnum|<vnum>-<vnum>|found> [go]", "#ff6666")
                return
            end
            targets[1] = vnum
        end
    end

    local gone = 0
    for _, vnum in ipairs(targets) do
        local r = mapCall("getMapRoom", vnum)
        if type(r) == "table" then
            gone = gone + 1
            print(TAG .. (commit and "  deleted " or "  would delete ")
                .. tostring(vnum) .. "  " .. tostring(r.name)
                .. "  [" .. tostring(r.area) .. "]")

            if commit then
                mapCall("deleteMapRoom", vnum)
                if whereAt.vnum == vnum then
                    whereAt.vnum = nil
                    whereAt.hash = ""
                end
                for i = #recent, 1, -1 do
                    if recent[i] == vnum then table.remove(recent, i) end
                end
            end
        end
    end

    if gone == 0 then
        say("no room by that number.", "#ffb02e")
        return
    end

    if not commit then
        say(gone .. " room(s) would go. 'dbmap forget " .. what
            .. " go' to do it. There is no undo.", "#ffb02e")
        return
    end

    lastFind = {}
    st.rooms = st.rooms - gone
    if st.rooms < 0 then st.rooms = 0 end
    forgetPositions()
    savePrefs()
    view.dirty = true
    repaint()
    drawPanel()

    -- Their neighbours still hold exits pointing at them, which the client's
    -- own audit reports rather than repairs.
    say(gone .. " room(s) deleted. 'dbmap audit' for exits left pointing at them.")
end

-- What the client makes of the map: exits to rooms that do not exist, rooms
-- sharing a square, exits with no way back. It reports and never repairs, which
-- is the right way round for something that would otherwise quietly delete.
local function auditMap()
    local rep = mapCall("auditMap")
    if type(rep) ~= "table" then
        say("auditMap is not in this build.", "#ff6666")
        return
    end

    local function count(list)
        local n = 0
        if type(list) == "table" then for _ in ipairs(list) do n = n + 1 end end
        return n
    end

    local dangling = count(rep.danglingExits)
    local dupes = count(rep.duplicateCoords)
    local oneWay = count(rep.oneWayExits)

    print(TAG .. "exits to rooms that do not exist: " .. dangling)
    print(TAG .. "squares holding more than one room: " .. dupes)
    print(TAG .. "exits with no way back: " .. oneWay)

    if type(rep.danglingExits) == "table" then
        local n = 0
        for _, d in ipairs(rep.danglingExits) do
            n = n + 1
            if n <= 10 then
                print(TAG .. "  " .. tostring(d.room) .. " " .. tostring(d.direction)
                    .. " -> " .. tostring(d.target) .. " (gone)")
            end
        end
    end
end

-- Everything, gone. The map is per world -- this world's database is
-- 'mud-map-database-dragonball-infinity' -- so no other world's map is at risk,
-- but every room recorded here goes, along with the vnum blocks and the travel
-- verbs. Typed out in full because there is no undo.
local function clearAll(confirmed)
    if not confirmed then
        say("this deletes EVERY room recorded for this world.", "#ff6666")
        say("'dbmap clear all confirm' to do it. There is no undo.", "#ff6666")
        return
    end

    local names = {}
    local list = mapCall("getAreaList")
    if type(list) == "table" then
        for n in pairs(list) do names[#names + 1] = n end
    end

    local gone = 0
    for _, n in ipairs(names) do
        gone = gone + (safeNum(mapCall("deleteArea", n)) or 0)
    end

    bases = {}
    travels = {}
    recent = {}
    lastFind = {}
    whereAt.vnum = nil
    whereAt.hash = ""
    pend.cmd = nil
    pend.travel = nil
    st = { rooms = 0, exits = 0, stubs = 0, specials = 0, seen = 0 }

    forgetPositions()
    baseFor(area)
    mapCall("addAreaName", area)
    savePrefs()
    view.dirty = true
    repaint()
    drawPanel()

    say(gone .. " room(s) deleted. Recording into '" .. area
        .. "' from vnum " .. tostring(bases[area]) .. ". Walk somewhere to start.")
end

-- Moves whatever the last 'dbmap find' listed into a named area. 'take' only
-- knows about rooms this session minted; this one works on anything you can
-- search for, which is what rescues rooms filed wrongly by an older version.
local function moveFound(target, commit)
    if target == "" then
        say("dbmap moveto <area> [go]", "#ff6666")
        return
    end
    if #lastFind == 0 then
        say("nothing found yet -- 'dbmap find <text>' first.", "#ff6666")
        return
    end

    local moved = 0
    for _, vnum in ipairs(lastFind) do
        local r = mapCall("getMapRoom", vnum)
        if type(r) == "table" and r.area ~= target then
            moved = moved + 1
            print(TAG .. (commit and "  moved " or "  would move ")
                .. tostring(vnum) .. "  " .. tostring(r.name)
                .. "  from '" .. tostring(r.area) .. "'")
            if commit then
                mapCall("updateMapRoom", vnum, { area = target })
                forgetPositions()
            end
        end
    end

    if moved == 0 then
        say("all " .. #lastFind .. " already in '" .. target .. "'.", "#ffb02e")
        return
    end

    if commit then
        mapCall("addAreaName", target)
        baseFor(target)
        view.dirty = true
        repaint()
        drawPanel()
        savePrefs()
        say(moved .. " room(s) moved into '" .. target .. "'.")
    else
        say(moved .. " room(s) would move into '" .. target
            .. "'. 'dbmap moveto " .. target .. " go' to do it.", "#ffb02e")
    end
end

-- Pulls the last n rooms we recorded into the area being recorded into now.
-- For the case this exists for: you died, four rooms of afterlife went into the
-- Ginyu Base, and 'dbmap area Snake Way' followed by 'dbmap take 4 go' puts
-- them where they belong.
local function takeRooms(n, commit)
    if not n or n < 1 then
        say("dbmap take <n> [go]", "#ff6666")
        return
    end

    local from = #recent - n + 1
    if from < 1 then from = 1 end

    local found = 0
    for i = from, #recent do
        local vnum = recent[i]
        local r = mapCall("getMapRoom", vnum)
        if type(r) == "table" and r.area ~= area then
            found = found + 1
            print(TAG .. (commit and "  moved " or "  would move ")
                .. tostring(vnum) .. "  " .. tostring(r.name)
                .. "  from '" .. tostring(r.area) .. "'")
            if commit then
                mapCall("updateMapRoom", vnum, { area = area })
                forgetPositions()
            end
        end
    end

    if found == 0 then
        say("the last " .. n .. " room(s) are already in '" .. area .. "'.", "#ffb02e")
        return
    end

    if commit then
        view.dirty = true
        repaint()
        drawPanel()
        savePrefs()
        say(found .. " room(s) moved into '" .. area .. "'.")
    else
        say(found .. " room(s) would move into '" .. area
            .. "'. 'dbmap take " .. n .. " go' to do it.", "#ffb02e")
    end
end

-- Deleting an area takes its rooms with it, which is the point: the rooms
-- stranded in the invented areas sit at 0,0,0 with no way in but a fake exit,
-- and walking them again maps them properly. Asked twice because it cannot be
-- undone.
local function dropArea(name, commit)
    if name == area then
        say("that is the area you are recording into. 'dbmap area <other>' first.", "#ff6666")
        return
    end

    local areas = mapCall("getAreaList")
    if type(areas) ~= "table" or areas[name] == nil then
        say("no area called '" .. name .. "'.", "#ff6666")
        return
    end

    local count = safeNum(areas[name]) or 0
    if not commit then
        say("'" .. name .. "' holds " .. count .. " room(s). They go too. "
            .. "'dbmap drop " .. name .. " go' to do it.", "#ffb02e")
        return
    end

    local gone = safeNum(mapCall("deleteArea", name))
    bases[name] = nil
    st.rooms = st.rooms - (gone or count)
    if st.rooms < 0 then st.rooms = 0 end
    savePrefs()
    view.dirty = true
    repaint()
    say("'" .. name .. "' is gone, with " .. tostring(gone or count) .. " room(s).")
end

----------------------------------------------------------------------
-- diagnostics
--
-- Its own function: Lua 5.1 caps a function at 60 upvalues and the command
-- handler is where that ceiling gets hit.
----------------------------------------------------------------------

-- Tag the room you are standing in. The client's own right-click menu does the
-- same job; this is for when your hands are already on the keyboard, and for
-- getting the same spelling every time.
--
-- 'on' omitted toggles, which is what setRoomFlag does with the argument left
-- off. A flag does not have to be defined first -- an undefined tag is valid,
-- it simply draws nothing until someone gives it a look.
local function doFlag(name, on)
    if not whereAt.vnum then
        say("nowhere yet -- 'look' first.", "#ff6666")
        return
    end

    local flag = trimBoth(tostring(name or "")):lower()
    if flag == "" then
        say("dbmap flag <name>  |  dbmap unflag <name>", "#ff6666")
        return
    end

    local now = mapCall("setRoomFlag", whereAt.vnum, flag, on)
    if now == nil then
        say("could not set '" .. flag .. "': " .. lastError, "#ff6666")
        return
    end

    view.dirty = true
    repaint()
    drawPanel()
    say("'" .. flag .. "' is " .. (now and "on" or "off") .. " for this room.")
end

local function printFlags()
    if whereAt.vnum then
        local mine = mapCall("getRoomFlags", whereAt.vnum)
        local names = {}
        if type(mine) == "table" then
            for _, f in ipairs(mine) do names[#names + 1] = tostring(f) end
        end
        if #names > 0 then
            say("this room: " .. table.concat(names, ", "))
        else
            say("this room carries no flags.")
        end
    end

    local defs = safeMap(mapCall("getMapFlags"))

    local n = 0
    for name, def in pairs(defs) do
        n = n + 1
        local look = {}
        if type(def) == "table" then
            if type(def.color) == "string" then look[#look + 1] = def.color end
            if type(def.symbol) == "string" then
                look[#look + 1] = "'" .. def.symbol .. "'"
            end
            if type(def.icon) == "string" then look[#look + 1] = "icon" end
        end

        -- a whole-database scan per flag, which is why this is a command and
        -- not something the panel does on every repaint
        local held = mapCall("getRoomsWithFlag", name)
        local count = 0
        if type(held) == "table" then
            for _ in ipairs(held) do count = count + 1 end
        end

        local tail = ""
        if #look > 0 then tail = "   " .. table.concat(look, " ") end
        say("  " .. tostring(name) .. "  " .. count .. " room(s)" .. tail)

        -- The rule the panel actually generates for it. A flag can be defined,
        -- carry a colour, tag rooms, draw its glyph and still not tint anything
        -- if this comes out empty -- and that is the one link there is no way
        -- to see from the outside.
        local cls = flagClass(tostring(name))
        local rgb = nil
        if type(def) == "table" then rgb = rgbOf(def.color) end
        if cls and rgb then
            print(TAG .. "    css .nd." .. cls .. " border rgb(" .. rgb .. ")")
        else
            print(TAG .. "    css: none -- " .. tostring(cls) .. " / "
                .. tostring(rgb))
        end
    end

    if n == 0 then
        say("no flags defined yet. 'dbmap flag <name>' tags this room anyway --")
        say("an undefined tag is still searchable, it just draws nothing.")
    end
end

-- The whole nudge surface behind one name. The dbmap handler is at Lua 5.1's
-- 60-upvalue ceiling and mentioning nudgeRoom, unnudgeRoom and nudgeRange
-- separately went over it.
local function nudgeCommand(rest)
        -- Three ways to say which room, cheapest first:
        --   nudge <dir>                 the room you are in
        --   nudge <which> <dir> [n]     the room <which> of you
        --   nudge <vnum> <dir> [n]      that room, wherever it is
        --
        -- Naming it by the way it lies from here beats reading a vnum off
        -- a tooltip first, and the map already knows which room that is.
        --
        -- EVERY capture goes through word(). A match that fails does not
        -- come back as nil here -- it comes back as undefined, which is
        -- truthy, so 'if not at' never fired and the fallback that fills in
        -- the direction was skipped. The direction then went to :lower() as
        -- undefined and threw. Two bugs on one line, both of them the same
        -- one: a miss that does not look like a miss.
        -- A range first: '10004-10021 se 2', or '... reset'. '%-' is an
        -- escaped literal, not the lazy quantifier, which does not survive
        -- the pattern translation anyway.
        local rawA, rawB, rawRDir, rawRN =
            rest:match("^(%d+)%-(%d+)%s+(%S+)%s*(%d*)$")
        local rangeA = safeNum(textOf(rawA))
        local rangeB = safeNum(textOf(rawB))
        if rangeA and rangeB then
            local rd = textOf(rawRDir) or ""
            if rd:lower() == "reset" then
                nudgeRange(rangeA, rangeB, nil, nil, true)
            else
                nudgeRange(rangeA, rangeB, rd, safeNum(textOf(rawRN)), false)
            end
            return
        end

        local rawAt, rawWord, rawMuch = rest:match("^(%d+)%s+(%S+)%s*(%d*)$")
        local at = textOf(rawAt)
        local dir = textOf(rawWord)
        local much = textOf(rawMuch)

        if not at then
            local rawPick, rawMove, rawFar = rest:match("^(%S+)%s+(%S+)%s*(%d*)$")
            local pick = textOf(rawPick)
            local move = textOf(rawMove)
            local far = textOf(rawFar)

            -- Written out rather than 'pick and CANON[pick:lower()]': a
            -- guard and a method call on the same value in one expression
            -- is evaluated whichever way the guard goes here.
            local fromHere = nil
            if pick then fromHere = nav.CANON[pick:lower()] end

            -- BOTH words have to be directions for this to be the
            -- room-next-door form. 'nudge e s' is the room east of here
            -- moved south; 'nudge s 3' is THIS room moved south by three.
            local alsoDir = nil
            if move then alsoDir = nav.CANON[move:lower()] end

            if fromHere and alsoDir and whereAt.vnum then
                local hr = mapCall("getMapRoom", whereAt.vnum)
                if type(hr) == "table" and type(hr.exits) == "table" then
                    at = safeNum(hr.exits[fromHere])
                end
                if not at then
                    say("no room " .. fromHere .. " of here.", "#ff6666")
                    return
                end
                dir = move
                much = far
            end
        end

        if not at then
            local rawDir, rawN = rest:match("^(%S+)%s*(%d*)$")
            dir = textOf(rawDir)
            much = textOf(rawN)
            at = whereAt.vnum
        end

        if not at then
            say("nowhere yet -- walk into a room first.", "#ff6666")
            return
        end
        if not dir then
            say("dbmap nudge <dir> [n]  |  nudge <which> <dir> [n]  |  "
                .. "nudge <vnum> reset", "#ff6666")
            return
        end

        if dir:lower() == "reset" then
            unnudgeRoom(safeNum(at))
        else
            nudgeRoom(safeNum(at), dir:lower(), safeNum(much))
        end
end

-- The map-maintenance commands, lifted out of the dbmap handler for the same
-- reason as the flag ones: Lua 5.1 caps a function at 60 upvalues and that
-- handler mentions every one of auditMap, forgetRooms, clearAll, moveFound,
-- takeRooms, cleanMap and dropArea. Behind one name they cost one.
--
-- Everything destructive here is a dry run until the argument ends in ' go',
-- and that check is written out per branch rather than factored: they take
-- different arguments either side of it and three explicit copies read better
-- than one helper that has to be parameterised into agreement.
local function tidyCommand(low, cmd)
    if low == "audit" then
        auditMap()
        return true
    end

    if low:sub(1, 7) == "forget " then
        local rest = trimBoth(cmd:sub(8))
        local commit = false
        if rest:sub(-3) == " go" then
            commit = true
            rest = trimBoth(rest:sub(1, #rest - 3))
        end
        forgetRooms(rest:lower(), commit)
        return true
    end

    if low == "clear all confirm" then
        clearAll(true)
        return true
    end

    if low:sub(1, 5) == "clear" then
        clearAll(false)
        return true
    end

    if low:sub(1, 7) == "moveto " then
        local rest = trimBoth(cmd:sub(8))
        local commit = false
        if rest:sub(-3) == " go" then
            commit = true
            rest = trimBoth(rest:sub(1, #rest - 3))
        end
        moveFound(rest, commit)
        return true
    end

    if low:sub(1, 5) == "take " then
        local rest = trimBoth(cmd:sub(6))
        local commit = false
        if rest:sub(-3) == " go" then
            commit = true
            rest = trimBoth(rest:sub(1, #rest - 3))
        end
        takeRooms(safeNum(rest), commit)
        return true
    end

    if low == "clean" then
        cleanMap(false)
        return true
    end

    if low == "clean go" then
        cleanMap(true)
        return true
    end

    if low:sub(1, 5) == "drop " then
        local rest = trimBoth(cmd:sub(6))
        local commit = false
        if rest:sub(-3) == " go" then
            commit = true
            rest = trimBoth(rest:sub(1, #rest - 3))
        end
        if rest == "" then
            say("dbmap drop <area> [go]", "#ff6666")
            return true
        end
        dropArea(rest, commit)
        return true
    end

    return false
end

-- Setting a room's ground by hand.
--
-- The server only ever names the sector of a room you are standing NEXT to, so
-- a corridor you walked straight down can end up with the ends read and the
-- middle blank, and a room nobody has ever stood beside stays blank for good.
-- This fills those in.
--
-- Same shapes as nudge: this room, that vnum, or a range of them.
local function groundCommand(rest)
    rest = trimBoth(rest or "")

    if rest == "" then
        if not whereAt.vnum then
            say("nowhere yet -- walk into a room first.", "#ff6666")
            return
        end
        local r = mapCall("getMapRoom", whereAt.vnum)
        local had = nil
        if type(r) == "table" then had = r.terrain end
        if type(had) ~= "string" or had == "" or had == "default" then
            say("this room has no ground recorded. 'dbmap ground <sector>'.")
        else
            say("this room is " .. had .. ".")
        end
        return
    end

    -- <a>-<b> <sector>, <vnum> <sector>, or just <sector>
    local targets = {}
    local want = nil

    local rawA, rawB, rawR = rest:match("^(%d+)%-(%d+)%s+(%S+)$")
    local a = safeNum(textOf(rawA))
    local b = safeNum(textOf(rawB))

    if a and b then
        want = textOf(rawR)
        if a > b then
            local swap = a
            a = b
            b = swap
        end
        if b - a >= RANGE_MAX then
            say("that is more than " .. RANGE_MAX .. " rooms. Narrow it.", "#ff6666")
            return
        end
        local list = mapCall("getAreaRooms", area)
        if type(list) == "table" then
            for _, raw in ipairs(list) do
                local v = safeNum(raw) or raw
                if v and v >= a and v <= b then targets[#targets + 1] = v end
            end
        end
        if #targets == 0 then
            say("no rooms of '" .. area .. "' between " .. a .. " and " .. b .. ".",
                "#ffb02e")
            return
        end
    else
        local rawV, rawS = rest:match("^(%d+)%s+(%S+)$")
        local one = safeNum(textOf(rawV))
        if one then
            want = textOf(rawS)
            targets[1] = one
        else
            want = textOf(rest:match("^(%S+)$"))
            if not whereAt.vnum then
                say("nowhere yet -- walk into a room first.", "#ff6666")
                return
            end
            targets[1] = whereAt.vnum
        end
    end

    if not want then
        say("dbmap ground <sector> | <vnum> <sector> | <a>-<b> <sector> | none",
            "#ff6666")
        return
    end
    want = want:lower()

    -- 'none' takes it off again, which matters because a wrong sector is
    -- otherwise permanent: nothing on the wire ever contradicts it.
    local clearing = want == "none" or want == "clear"
    if not clearing then
        local known = false
        for _, name in ipairs(sectorList()) do
            if name == want then known = true end
        end
        if not known then
            say("'" .. want .. "' is not a sector this MUD names. Setting it "
                .. "anyway; it will draw plain until it has a colour.", "#ffb02e")
        end
    end

    local done = 0
    for _, v in ipairs(targets) do
        local r = mapCall("getMapRoom", v)
        if type(r) == "table" then
            local to = want
            if clearing then to = "default" end
            if mapCall("updateMapRoom", v, { terrain = to }) then done = done + 1 end
        end
    end

    if done == 0 then
        say("nothing changed.", "#ffb02e")
        return
    end

    forgetPositions()
    view.dirty = true
    repaint()
    drawPanel()

    if clearing then
        say(done .. " room(s) back to no ground.")
    else
        say(done .. " room(s) set to " .. want .. ".")
    end
end

-- One entry point for the flag commands, because the dbmap handler is already
-- at Lua 5.1's 60-upvalue ceiling and every name it mentions costs one. Returns
-- true when it took the command.
-- 'notes' is a documented room field that nothing in the client displays, so
-- writing one is only useful alongside the tooltip line that reads it back.
--
-- updateMapRoom's patch keys are documented by example rather than exhaustively
-- and 'notes' is not among the examples, so the return value is checked and
-- reported instead of assumed. A build that will not take it says so.
local function noteCommand(low, cmd)
    if low ~= "note" and low:sub(1, 5) ~= "note " then return false end
    if not whereAt.vnum then
        say("no room here yet -- walk somewhere first.", "#ffb02e")
        return true
    end

    local was = nil
    local room = mapCall("getMapRoom", whereAt.vnum)
    if type(room) == "table" then was = textOf(room.notes) end

    if low == "note" then
        if not was then
            say("note: (none)")
            return true
        end
        -- Flattened for the echo. The line breaks are real in the note and the
        -- tooltip keeps them; one echo per line would wear the tag five times.
        local oneLine = was:gsub("\n", " / ")
        say("note: " .. oneLine)
        return true
    end

    local rest = trimBoth(cmd:sub(6))
    local wipe = rest:lower() == "clear"

    -- 'add' appends on a new line rather than replacing. The cost is that a
    -- note cannot itself begin with the word add, which has never come up and
    -- is worth it for not needing a second command.
    -- Bare 'add' as well as 'add <text>': the trim above has already taken the
    -- trailing space off, so testing only for 'add ' let 'dbmap note add' set
    -- the note to the word add.
    local lowRest = rest:lower()
    local adding = lowRest == "add" or lowRest:sub(1, 4) == "add "
    if adding then rest = trimBoth(rest:sub(5)) end
    if adding and rest == "" then
        say("nothing to add.", "#ffb02e")
        return true
    end

    local text = rest
    if adding and was then text = was .. "\n" .. rest end

    local ok = mapCall("updateMapRoom", whereAt.vnum, { notes = wipe and "" or text })
    if not ok then
        say("this build would not take a note.", "#ffb02e")
        return true
    end

    view.dirty = true
    repaint()
    drawPanel()
    if wipe then say("note cleared.")
    elseif adding then say("added.")
    else say("noted.") end
    return true
end

local function flagCommand(low, cmd)
    if low == "ground" or low == "sector" then
        groundCommand("")
        return true
    end
    if low:sub(1, 7) == "ground " then
        groundCommand(cmd:sub(8))
        return true
    end
    if low:sub(1, 7) == "sector " then
        groundCommand(cmd:sub(8))
        return true
    end

    if low == "legend" then
        view.legend = not view.legend
        savePrefs()
        view.dirty = true
        repaint()
        drawPanel()
        say("legend " .. (view.legend and "on" or "off") .. ".")
        return true
    end

    if low == "flags" then
        printFlags()
        return true
    end
    if low:sub(1, 5) == "flag " then
        doFlag(cmd:sub(6), nil)
        return true
    end
    if low:sub(1, 7) == "unflag " then
        doFlag(cmd:sub(8), false)
        return true
    end
    return false
end

local function printDiag()
    -- Differ and there are two copies installed, both recording into the same
    -- map and both counting it. Chat carries the same guard.
    print(TAG .. "instance=" .. INSTANCE .. " live=" .. tostring(getVariable("instance")))
    print(TAG .. "ready=" .. tostring(ready) .. " mode=" .. mode)
    print(TAG .. "area=" .. area .. " block=" .. tostring(bases[area]))
    print(TAG .. "here=" .. tostring(whereAt.vnum) .. " hash=" .. (whereAt.hash ~= "" and whereAt.hash or "none"))
    print(TAG .. "pending=" .. tostring(pend.cmd))
    print(TAG .. "recorded rooms=" .. st.rooms .. " exits=" .. st.exits
        .. " stubs=" .. st.stubs .. " specials=" .. st.specials
        .. " room lines seen=" .. st.seen)

    local areas = mapCall("getAreaList")
    if type(areas) == "table" then
        for name, count in pairs(areas) do
            print(TAG .. "  area " .. tostring(name) .. ": " .. tostring(count) .. " rooms")
        end
    end

    if whereAt.vnum then
        local room = mapCall("getMapRoom", whereAt.vnum)
        if type(room) == "table" then
            print(TAG .. "here name=" .. tostring(room.name)
                .. " at " .. tostring(room.x) .. "," .. tostring(room.y) .. "," .. tostring(room.z))
            local outs = {}
            if type(room.exits) == "table" then
                for d, to in pairs(room.exits) do outs[#outs + 1] = d .. "->" .. tostring(to) end
            end
            print(TAG .. "here exits: " .. (#outs > 0 and table.concat(outs, " ") or "none"))
            local stubs = mapCall("getExitStubs", whereAt.vnum)
            local names = {}
            if type(stubs) == "table" then
                -- 0-INDEXED. 'for i = 1, #list' skips the first and runs one past.
                for _, d in ipairs(stubs) do names[#names + 1] = tostring(d) end
            end
            print(TAG .. "here stubs: " .. (#names > 0 and table.concat(names, " ") or "none"))
        end
    end
    print(TAG .. "widget=" .. tostring(view.id) .. " wanted=" .. tostring(view.want))
    -- sends running well ahead of commands means onSend hears the bot too
    print(TAG .. "onCommand fired=" .. sawCommands .. " onSend fired=" .. sawSends)

    local verbs = {}
    for cmd in pairs(travels) do verbs[#verbs + 1] = cmd end
    print(TAG .. "travel verbs: " .. (#verbs > 0 and table.concat(verbs, ", ") or "none yet"))
    print(TAG .. "lastError=" .. lastError)
end

-- Whether this build has any way to tell the client where we are standing.
-- The guide documents getPlayerRoom as read-only and GMCP-fed, and lists no
-- setter, but the guide has been short of the truth before -- registerWidgetEvent
-- "submit" is real and undocumented. So ask the runtime instead of the document.
local PROBE = {
    "getPlayerRoom", "setPlayerRoom", "setCurrentRoom", "setPlayerLocation",
    "centerview", "centerView", "setMapCursor", "moveMapCursor",
    "refreshMap", "createMapperWidget", "destroyWidget", "onRoomChange",
}

local function shallow(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do
        keys[#keys + 1] = tostring(k)
        if #keys >= 12 then keys[#keys + 1] = "..." break end
    end
    if #keys == 0 then return "{}" end
    return "{ " .. table.concat(keys, ", ") .. " }"
end

-- Everything the server has actually sent. GMCP cannot be faked from this side
-- -- the API reads and subscribes, and sendGMCP goes OUT -- so if the client's
-- own room tracking is ever going to work, the data has to come from the MUD.
-- Which means knowing what the MUD offers.
local function dumpGmcp()
    local get = callable("getGMCPData")
    if not get then
        say("no getGMCPData in this build.", "#ff6666")
        return
    end

    local ok, all = pcall(function() return get() end)
    if not ok or type(all) ~= "table" then
        say("no GMCP received on this session.", "#ffb02e")
        return
    end

    local n = 0
    for pkg, data in pairs(all) do
        n = n + 1
        print(TAG .. "  " .. tostring(pkg) .. " = " .. shallow(data))
    end
    if n == 0 then
        say("connected, but no packages received.", "#ffb02e")
    else
        say(n .. " package(s) received.")
    end
end

-- We ask for 'Map 1' and nothing else, so we have never found out whether this
-- server implements a Room package. If it does, the client tracks the current
-- room itself and none of the highlighting below is needed.
local function askFor(pkg)
    -- goes onto the wire inside a JSON array, so nothing but a package name
    if pkg == "" or pkg:find("[^%w%.]") then
        say("package names are letters, digits and dots.", "#ff6666")
        return
    end
    -- Two-arg form. The package name arrives from a command, so building the
    -- wire string by hand meant pasting user input into JSON.
    sendGMCP("Core.Supports.Add", { pkg .. " 1" })
    say("asked for '" .. pkg .. " 1'. Walk a room, then 'dbmap gmcp'.")
end

-- What the server said about the cells around you, and what we made of it.
-- Every step of the chain, because "east is a door and nothing was drawn" has
-- half a dozen possible causes and guessing at them is how days go missing.
local function probeDoors()
    print(TAG .. "getGMCPData Map.Snapshot -> "
        .. type(mapCall("getGMCPData", "Map.Snapshot")))
    print(TAG .. "snapshots seen=" .. shot.count
        .. " anchor=" .. geo.ax .. "," .. geo.ay
        .. " here=" .. tostring(whereAt.vnum))

    if not shot.last then
        say("no Map.Snapshot has arrived. Scouter asks for 'Map 1' -- is it on?",
            "#ff6666")
        return
    end

    -- What the server actually styles the anchor and the eight rooms around it
    -- as. The anchor's role is 'current' in the definition, which would mean it
    -- never carries a sector and the terrain read has been coming back empty
    -- since it was written -- this says so either way rather than reasoning
    -- about it from the JSON, which has now been wrong twice.
    do
        local runs = shot.last.runs
        if type(unwrapSnap(shot.last)) == "table" then
            runs = unwrapSnap(shot.last).runs or runs
        end

        print(TAG .. "anchor cell style=" .. tostring(styleAt(runs, geo.ax, geo.ay)))

        local said = {}
        for dir, step in pairs(nav.STEP) do
            -- rooms sit two cells apart: odd cells are rooms, even ones the
            -- connector between them
            if step[3] == 0 then
                said[#said + 1] = dir .. "=" .. tostring(
                    styleAt(runs, geo.ax + step[1] * 2, geo.ay + step[2] * 2))
            end
        end
        table.sort(said)
        print(TAG .. "room cells " .. table.concat(said, " "))

        local mine = whereAt.vnum and mapCall("getMapRoom", whereAt.vnum)
        if type(mine) == "table" then
            print(TAG .. "this room's stored terrain=" .. tostring(mine.terrain))
        end
    end

    -- What the object actually looks like, key by key. Reasoning about the
    -- shape from the JSON the MUD prints has now been wrong twice.
    local keys = {}
    for k, v in pairs(shot.last) do
        keys[#keys + 1] = tostring(k) .. ":" .. type(v)
    end
    print(TAG .. "snapshot keys: " .. (#keys > 0 and table.concat(keys, " ") or "none"))

    local runs = shot.last.runs
    print(TAG .. "runs is " .. type(runs))

    if type(runs) == "table" then
        local rowList, rn = flat(runs)
        print(TAG .. "runs flattens to " .. rn .. " row(s)")

        -- the anchor's row, entry by entry, element by element
        local row = rowList[geo.ay + 1]
        print(TAG .. "row " .. geo.ay .. " is " .. type(row))
        if type(row) == "table" then
            local entries, en = flat(row)
            print(TAG .. "  " .. en .. " run(s) on it")
            for i = 1, math.min(en, 6) do
                local cells, cn = flat(entries[i])
                local bits = {}
                for j = 1, cn do bits[#bits + 1] = tostring(cells[j]) end
                -- pairs as well, in case it crossed as an object rather than
                -- an array and ipairs sees nothing
                local viaPairs = {}
                if type(entries[i]) == "table" then
                    for k, v in pairs(entries[i]) do
                        viaPairs[#viaPairs + 1] = tostring(k) .. "=" .. tostring(v)
                    end
                end
                print(TAG .. "    run " .. i .. " ipairs[" .. cn .. "]: "
                    .. table.concat(bits, ", ")
                    .. "  pairs: " .. table.concat(viaPairs, ", "))
            end
        end
    end

    if type(runs) ~= "table" then
        say("the snapshot carries no runs.", "#ff6666")
        return
    end

    -- the row the anchor sits on, verbatim, so the geometry can be checked
    local rows = shot.last.rows
    if type(rows) == "table" then
        local flatRows, flatN = flat(rows)
        local line = flatRows[geo.ay + 1]
        if line then print(TAG .. "row " .. geo.ay .. ": " .. tostring(line)) end
    end

    for _, d in ipairs({ "n", "s", "e", "w", "ne", "nw", "se", "sw" }) do
        local off = paint.DOOR[d]
        local cx = geo.ax + off[1]
        local cy = geo.ay + off[2]
        print(TAG .. "  " .. d .. " cell " .. cx .. "," .. cy
            .. " = " .. tostring(styleAt(runs, cx, cy)))
    end

    if whereAt.vnum then
        local got = mapCall("getDoors", whereAt.vnum)
        local out = {}
        if type(got) == "table" then
            for d, s in pairs(got) do out[#out + 1] = d .. "=" .. tostring(s) end
        end
        print(TAG .. "doors recorded here: "
            .. (#out > 0 and table.concat(out, " ") or "none"))
    end
end

local function probeApi()
    local have, gone = {}, {}
    for _, name in ipairs(PROBE) do
        if callable(name) then
            have[#have + 1] = name
        else
            gone[#gone + 1] = name
        end
    end
    print(TAG .. "present: " .. (#have > 0 and table.concat(have, " ") or "none"))
    print(TAG .. "absent:  " .. (#gone > 0 and table.concat(gone, " ") or "none"))
    print(TAG .. "getPlayerRoom -> " .. tostring(mapCall("getPlayerRoom")))

    -- Everything else carrying 'room' or 'map', in case the setter is called
    -- something none of the guesses above covers.
    local found, line = {}, ""
    pcall(function()
        for k, v in pairs(_G) do
            local lk = tostring(k):lower()
            if type(v) == "function" and (lk:find("room", 1, true) or lk:find("map", 1, true)) then
                found[#found + 1] = tostring(k)
            end
        end
    end)

    if #found == 0 then
        print(TAG .. "could not walk _G -- the whitelist above is all we know")
        return
    end

    print(TAG .. #found .. " room/map function(s) in this build:")
    for _, name in ipairs(found) do
        line = line .. name .. " "
        if #line > 88 then
            print(TAG .. "  " .. line)
            line = ""
        end
    end
    if line ~= "" then print(TAG .. "  " .. line) end
end

-- Its own function, not inline in init. Lua 5.1 caps a function at 60
-- upvalues and init was over it: every name these callbacks close over was
-- one of init's too.
local function subscribeGmcp()
    -- The local map the server already sends, for the doors in it. Read-only:
    -- Scouter owns the handshake that asks for it, and two plugins negotiating
    -- the same package is how the map stayed empty for a week.
    local onGmcp = callable("onGMCPUpdate")
    if onGmcp then
        pcall(function()
            return onGmcp("Map.Definition", function(payload)
                local def = payload
                if type(def) == "table" and type(def.styles) ~= "table" then
                    -- nested the same way the snapshot is
                    for _, k in ipairs({ "definition", "map", "Map" }) do
                        if type(def[k]) == "table" then def = def[k] end
                    end
                end
                if type(def) ~= "table" then return end

                if type(def.anchor) == "table" then
                    local ax, ay = safeNum(def.anchor.x), safeNum(def.anchor.y)
                    if ax then geo.ax = ax end
                    if ay then geo.ay = ay end
                end

                -- The palette, kept as it arrives. Colouring by anything else
                -- would mean two schemes for one map.
                if type(def.styles) == "table" then
                    for name, spec in pairs(def.styles) do
                        if type(spec) == "table" and type(spec.fg) == "string" then
                            paint.style[tostring(name)] = spec.fg
                        end
                    end
                end
            end)
        end)
        pcall(function()
            return onGmcp("Map.Snapshot", function(snap)
                -- read while following too, so the diagnostics stay live; it
                -- is applySnapshot that does the writing, and arrive() does not
                -- reach it unless we are recording
                if not watching() or not ready then return end
                pcall(function() readDoors(snap) end)
            end)
        end)
    end
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

-- Said once, on a map with nothing in it.
--
-- The area is the one thing this plugin cannot work out for itself: the MUD
-- sends no room package, so nothing in the stream says which area a room
-- belongs to. It has to be told, and until it is, everything walked piles into
-- whichever area happens to be current -- which is easy to not notice until
-- there are two hundred rooms filed under the wrong name.
local function noticeAreas()
    say("this is a new map, so a word about areas.", "#ffb02e")
    say("the MUD never says which area you are in, so rooms are filed under")
    say("whichever one is current -- right now that is '" .. area .. "', which is")
    say("a starting guess and nothing more.")
    say("  dbmap area <name>  file new rooms under this one")
    say("  dbmap rename <name>  this area was never called that; brings its rooms")
    say("or click the area name at the foot of the map panel: the picker already")
    say("holds the MUD's area list with the power range for each, so you can pick")
    say("one without walking a room of it first.", "#ffb02e")
end

function init()
    print(TAG .. "init")
    setVariable("instance", INSTANCE)
    loadPrefs()

    -- Reads are only safe once the map is warm, and that happens after the
    -- plugin loads. Anything touching the map at load time has to start here.
    local onReady = callable("onMapReady")
    if onReady then
        onReady(function()
            ready = true
            -- before anything is allocated: an imported map knows its own vnum
            -- blocks and we would otherwise mint rooms on top of its
            adoptFromMap()
            baseFor(area)
            defineFlags()
            mapCall("addAreaName", area)
            print(TAG .. "map ready; recording into '" .. area
                .. "', rooms " .. nav.dist.x .. "x" .. nav.dist.y .. " apart")
            if firstRun then noticeAreas() end
            -- after ready, not in init: the widget renders the map engine and
            -- there is nothing to render until the map is warm
            if view.want then showMap() end
            view.dirty = true
            repaint()
        end)
    else
        print(TAG .. "no onMapReady in this build -- nothing will be recorded")
    end

    subscribeGmcp()

    -- The exits are on the line AFTER this, so onLine picks them up.
    addTrigger("Obvious exits:", function()
        whereAt.wantExits = true
    end)

    -- Walk into a closed door and the MUD says so, which is a far plainer
    -- signal than working the geometry out of the local map's cells. Proven
    -- text: 'look east' on a closed door answers 'The door is closed.'
    --
    -- pend.cmd holds the direction, and only ever a compass one, so a 'look
    -- east' that follows some other command cannot borrow its direction. The
    -- staleness window is the same one arrivals use: a door message that
    -- arrives seconds after the command it belongs to is not about it.
    local function markDoor(status)
        if not recording() then return end
        if not whereAt.vnum or not pend.cmd then return end
        if os.time() - pend.at > STALE then return end
        if mapCall("setDoor", whereAt.vnum, pend.cmd, status) then
            view.dirty = true
            repaint()
            drawPanel()
        end
    end

    -- "You raise two fingers to your forehead, then suddenly blink out of
    -- existence." Only printed when an instant transmission actually fires.
    addTrigger("blink out of existence", function()
        if it.want then
            it.left = true
            it.at = os.time()
        end
    end)

    addTrigger("The door is closed", function() markDoor(2) end)
    -- SMAUG's standard wording for the locked case. Not seen in a log here, so
    -- if a locked door reads differently this one simply never fires.
    addTrigger("The door is locked", function() markDoor(3) end)

    -- 'Nappa slays you in cold blood!' varies with whatever killed you; this
    -- line does not, and it lands before the first afterlife room.
    addTrigger("begins to fade to black", function()
        pend.warp = "you died"
    end)

    -- The way back. 'say send me home' is not a movement command, so without
    -- this the room you land in gets filed under the afterlife.
    addTrigger("I shall return you home immediately", function()
        pend.warp = "you were sent home"
    end)

    -- The client's map has a special-exit command of its own, and it works off
    -- the room GMCP says you are in. There isn't one, so this does the job:
    -- send the command AND say that it travels, in one go.
    registerCommand("dbgo", function(args)
        local cmd = trimBoth(args or "")
        if cmd == "" then
            echo(TAG .. "dbgo <command>   -- e.g. 'dbgo enter ship'", "#ffb02e")
            echo("            Sends it, and maps where it lands as a special exit.", "#ffb02e")
            return
        end

        if not whereAt.vnum then
            say("nowhere yet -- 'look' first, so there is somewhere to leave from.", "#ff6666")
            return
        end

        pend.travel = cmd:lower()
        pend.cmd = nil
        send(cmd)
    end, "Travel by something that isn't a compass direction, and map it")

    registerCommand("dbmap", function(args)
        local cmd = trimBoth(args or "")
        local low = cmd:lower()

        -- Bare and 'help' both fall through to the list at the bottom. Every
        -- plugin in this set answers the same way, so there is one thing to
        -- remember rather than six.
        if low == "status" or low == "diag" then
            printDiag()

        elseif low == "api" then
            probeApi()

        elseif noteCommand(low, cmd) then
        elseif flagCommand(low, cmd) then
        elseif low == "doors" then
            probeDoors()

        elseif low == "gmcp" then
            dumpGmcp()

        elseif low:sub(1, 4) == "ask " then
            askFor(trimBoth(cmd:sub(5)))

        elseif low == "view area" or low == "view local" then
            view.mode = low:sub(6)
            savePrefs()
            drawPanel()
            say("showing the " .. (view.mode == "area" and "whole area"
                or "rooms around you, laid out from where you stand") .. ".")

        elseif low == "view" then
            say("showing the " .. view.mode .. ". 'dbmap view area' for all of it, "
                .. "'dbmap view local' for what is around you.")

        elseif low == "distance" then
            say("east/west " .. nav.dist.x .. ", north/south " .. nav.dist.y
                .. ". 'dbmap distance <dir> <1-8>' for one axis, 'dbmap distance <1-8>'"
                .. " for both, then 'dbmap relayout go' to apply it.")

        elseif low:sub(1, 9) == "distance " then
            local rest = trimBoth(cmd:sub(10))
            local word, num = rest:match("^(%S+)%s+(%d+)$")
            local want = safeNum(num or rest)

            if not want or want < 1 or want > 8 then
                say("dbmap distance [<dir>] <1-8>", "#ff6666")
                return
            end

            local axis = nil
            if word then
                -- Per AXIS, not per direction. If east moved three and west
                -- moved one, walking out and back would not return you to the
                -- coordinate you left, and the grid stops meaning anything.
                local d = nav.CANON[word:lower()]
                local step = d and nav.STEP[d]
                if not step or (step[1] ~= 0 and step[2] ~= 0) then
                    say("a direction on one axis: n, s, e or w.", "#ff6666")
                    return
                end
                axis = step[1] ~= 0 and "x" or "y"
            end

            if axis then
                nav.dist[axis] = math.floor(want)
            else
                nav.dist.x = math.floor(want)
                nav.dist.y = math.floor(want)
            end

            savePrefs()
            drawPanel()
            say("east/west " .. nav.dist.x .. ", north/south " .. nav.dist.y
                .. ". 'dbmap relayout go' to lay out what is already mapped at that.")

        elseif low == "relayout" then
            relayout(false)

        elseif low == "relayout go" then
            relayout(true)

        elseif low:sub(1, 6) == "nudge " then
            nudgeCommand(trimBoth(cmd:sub(7)))

        elseif low:sub(1, 8) == "stretch " then
            local rest = trimBoth(cmd:sub(9))
            local word = rest:match("^(%S+)") or ""
            local much = safeNum(rest:match("%s(%d+)$"))
            stretchFrom(word:lower(), much or 1)

        elseif low:sub(1, 8) == "respace " then
            local rest = trimBoth(cmd:sub(9))
            local commit = false
            if rest:sub(-3) == " go" then
                commit = true
                rest = trimBoth(rest:sub(1, #rest - 3))
            end
            if rest:lower() == "fit" then
                refit(commit)
            else
                respace(safeNum(rest), commit)
            end

        elseif low:sub(1, 5) == "goto " then
            routeCmd(safeNum(trimBoth(cmd:sub(6))), true)

        elseif low:sub(1, 5) == "path " then
            routeCmd(safeNum(trimBoth(cmd:sub(6))), false)

        elseif tidyCommand(low, cmd) then

        elseif low == "show" then
            if showMap() then
                view.want = true
                savePrefs()
                view.dirty = true
                repaint()
                say("map panel up, pinned to '" .. area .. "'.")
            else
                say("could not open it: " .. lastError, "#ff6666")
            end

        elseif low == "hide" then
            view.want = false
            savePrefs()
            if hideMap() then
                say("map panel closed.")
            else
                say("it was not open.", "#ffb02e")
            end

        elseif low == "on" or low == "record" then
            mode = "record"
            savePrefs()
            say("following and recording.")

        elseif low == "follow" then
            mode = "follow"
            savePrefs()
            say("following. Nothing new goes into the map until 'dbmap on'.")

        elseif low == "off" then
            mode = "off"
            savePrefs()
            say("stopped. The panel will not follow you either; "
                .. "'dbmap follow' if that is what you wanted.")

        elseif low == "mode" then
            say("mode: " .. mode)

        elseif low:sub(1, 5) == "area " then
            -- Switching. New rooms go here; nothing already recorded moves.
            local name = trimBoth(cmd:sub(6))
            if name == "" then
                say("dbmap area <name>", "#ff6666")
                return
            end
            area = name
            forgetPositions()
            baseFor(area)
            mapCall("addAreaName", area)
            savePrefs()
            relockMap()
            say("new rooms go into '" .. area .. "' from vnum "
                .. tostring(bases[area]) .. ".")

        elseif low:sub(1, 7) == "rename " then
            -- Correcting. The rooms come too.
            --
            -- Kept separate from 'area' on purpose: one means "I am somewhere
            -- else now" and the other means "this place was never called
            -- that". Doing both with one verb would drag a whole planet into
            -- the next one the first time you flew anywhere.
            local name = trimBoth(cmd:sub(8))
            if name == "" then
                say("dbmap rename <name>", "#ff6666")
                return
            end
            if name == area then
                say("already called that.", "#ffb02e")
                return
            end

            local old = area
            mapCall("addAreaName", name)

            local moved = 0
            local list = mapCall("getAreaRooms", old)
            if type(list) == "table" then
                for _, raw in ipairs(list) do
                    local vnum = safeNum(raw) or raw
                    if mapCall("updateMapRoom", vnum, { area = name }) then
                        moved = moved + 1
                    end
                end
            end

            if bases[old] and not bases[name] then
                bases[name] = bases[old]
                bases[old] = nil
            end

            area = name
            forgetPositions()
            baseFor(area)
            savePrefs()
            relockMap()
            view.dirty = true
            repaint()
            say("'" .. old .. "' is now '" .. area .. "', with its "
                .. moved .. " room(s).")

        elseif low == "here" then
            if not whereAt.vnum then
                say("nowhere yet -- walk into a room, or 'look'.", "#ff6666")
                return
            end
            say("vnum " .. whereAt.vnum .. "  hash " .. whereAt.hash)

        elseif low:sub(1, 5) == "find " then
            findRooms(trimBoth(cmd:sub(6)), 20)

        else
            echo(TAG .. "dbmap diag         what it has recorded", "#ffb02e")
            echo("            dbmap show|hide    a map panel pinned to this area", "#ffb02e")
            echo("            dbmap on|follow|off  record / follow only / neither", "#ffb02e")
            echo("            dbmap area <name>  switch: new rooms go there", "#ffb02e")
            echo("            dbmap rename <name> correct this area's name, rooms and all", "#ffb02e")
            echo("            dbmap here         this room's vnum and id", "#ffb02e")
            echo("            dbmap find <text>  search the map", "#ffb02e")
            echo("            dbmap goto <vnum>  walk there", "#ffb02e")
            echo("            dbmap path <vnum>  the route, as 3n2eu", "#ffb02e")
            echo("            dbmap api          what this build exposes", "#ffb02e")
            echo("            dbmap gmcp         what the server actually sends", "#ffb02e")
            echo("            dbmap flag <name>  tag this room; again takes it off", "#ffb02e")
            echo("            dbmap unflag <name>  take one off, whatever it was", "#ffb02e")
            echo("            dbmap flags        this room's tags, and every one defined", "#ffb02e")
            echo("            dbmap legend       the symbol key under the map", "#ffb02e")
            echo("            dbmap ground <sector>|none   set this room's ground", "#ffb02e")
            echo("            dbmap ground <vnum|a-b> <sector>  or those rooms'", "#ffb02e")
            echo("            dbmap note <text>|clear      a note, shown on hover", "#ffb02e")
            echo("            dbmap note add <text>        another line on it", "#ffb02e")
            echo("            dbmap doors        the cells around you, and what we read", "#ffb02e")
            echo("            dbmap ask <pkg>    subscribe to a GMCP package, e.g. Room", "#ffb02e")
            echo("            dbgo <command>     travel that isn't a direction", "#ffb02e")
            echo("            dbmap clean [go]   undeclared special exits, empty areas", "#ffb02e")
            echo("            dbmap moveto <area> [go]  move what 'find' listed", "#ffb02e")
            echo("            dbmap take <n> [go]  pull the last n rooms into this area", "#ffb02e")
            echo("            dbmap forget <vnum|<vnum>-<vnum>|found> [go]  delete room(s)", "#ffb02e")
            echo("            dbmap audit        exits pointing nowhere, rooms stacked", "#ffb02e")
            echo("            dbmap drop <area> [go]  delete an area AND its rooms", "#ffb02e")
            echo("            dbmap respace <2-8> [go]  spread this area out", "#ffb02e")
            echo("            dbmap respace fit [go]   back to a clean grid", "#ffb02e")
            echo("            dbmap view area|local  all of it, or just around you", "#ffb02e")
            echo("            dbmap distance [<dir>] <1-8>  how far apart rooms sit", "#ffb02e")
            echo("            dbmap relayout [go]  lay the area out again from its exits", "#ffb02e")
            echo("            dbmap stretch <dir> [n]  open a gap next to you", "#ffb02e")
            echo("            dbmap nudge <dir>            move the room you are in", "#ffb02e")
            echo("            dbmap nudge <which> <dir> [n]  move the room <which> of you", "#ffb02e")
            echo("            dbmap nudge <vnum> reset      put one back", "#ffb02e")
            echo("            dbmap nudge <vnum>-<vnum> <dir> [n]  a block of them", "#ffb02e")
            echo("            dbmap clear all confirm  delete EVERY room, start over", "#ffb02e")
        end
    end, "Build the map from room output")

    print(TAG .. "init done")
end

-- A tesseract bay advertises where it goes on a hologram in its description:
--
--   ||  To use the tesseract, speak aloud your destination.  ||
--   ||                      —————————                        ||
--   || ═════════════════════Snake Way════════════════════════||
--
-- Two tests, and between them they take the destination rows and nothing else.
-- The row is fenced by '||', which the frame's own top and bottom rules are
-- not; and it carries the box-drawing rule, which the prose rows inside the
-- same frame do not -- those are padded with spaces, and so is the em-dash
-- divider.
--
-- '|' is alternation once this reaches JavaScript, hence '%|%|'.
local function destRow(text)
    if not text:find("═", 1, true) then return nil end

    local inner = textOf(text:match("%|%|(.+)%|%|"))
    if not inner then return nil end

    -- Keep what belongs to a name instead of removing what does not. That way
    -- the box glyph never has to be matched, counted or indexed past, which is
    -- the part being multi-byte makes unsafe. Apostrophe is in the set for
    -- "Yemma's Vault".
    local kept = inner:gsub("[^%w' ]", "")
    local name = trimBoth(kept)
    if name == "" then return nil end
    return name
end

-- Accumulated across the description, written when the exits land -- the first
-- moment the whole description has gone past.
local dests = { at = nil, list = nil }

-- Room lines and exit lines both arrive here. onLine rather than a trigger for
-- the room, because the name is everything before the id and a substring
-- trigger cannot tell us where that starts.
function onLine(sessionId, raw, clean)
    if not watching() or not ready then return nil end

    local text = tostring(clean or raw or "")

    if whereAt.wantExits then
        whereAt.wantExits = false

        -- Written in full rather than merged, so a bay whose list the builders
        -- change does not keep its old entries forever.
        if dests.at and type(dests.list) == "table" and #dests.list > 0
            and recording() then
            mapCall("setRoomUserData", dests.at, "dests",
                table.concat(dests.list, ", "))
            view.dirty = true
        end
        dests.at, dests.list = nil, nil

        local dirs = {}
        -- '%w+' rather than a letter class: '%a' does not survive translation
        for word in text:lower():gmatch("%w+") do
            local d = nav.CANON[word]
            if d then dirs[#dirs + 1] = d end
        end
        if #dirs > 0 and whereAt.vnum then
            -- The way back, when the MUD says there is one.
            --
            -- An exit is only recorded when it is walked, so walking a corridor
            -- once leaves every room in it knowing how to go forward and not
            -- how to return. In a place where each room lists six or eight
            -- exits, a full explore still recorded one or two per room and the
            -- rest stayed unwalked forever. Not inferred: this fires only when
            -- the room we just arrived in lists that direction itself.
            if whereAt.from and whereAt.by then
                local back = nav.OPPOSITE[whereAt.by]
                for _, d in ipairs(dirs) do
                    if d == back then
                        recordMove(whereAt.vnum, back, whereAt.from)
                        break
                    end
                end
            end
            whereAt.from, whereAt.by = nil, nil

            if recording() then recordStubs(whereAt.vnum, dirs) end
            -- The exits arrive on the line AFTER the room, so arrive() has
            -- already drawn the panel by now and drew it without them. Which
            -- exits are unwalked is most of what the panel says about a room,
            -- so it was always one room behind.
            repaint()
            drawPanel()
        end
        return nil
    end

    -- Description lines, which land between the room line and the exits. The
    -- room is already current by now -- arrive() runs off the room line, which
    -- comes first -- so these attach to hereVnum rather than to pending state.
    local dest = destRow(text)
    if dest and whereAt.vnum then
        if dests.at ~= whereAt.vnum then
            dests.at, dests.list = whereAt.vnum, {}
        end
        dests.list[#dests.list + 1] = dest
    end

    local hash, name = readRoomLine(text)
    if hash then
        local ok, err = pcall(arrive, hash, name)
        if not ok then
            lastError = tostring(err)
            print(TAG .. "arrive error: " .. lastError)
        end
    end
    return nil
end

-- 'instant <itpoint>' and its two aliases. Noted when typed, spent when the
-- room line finally lands -- which is six to fifteen seconds later.
--
-- A target that is not in the table, or one itpoints lists in two areas, still
-- arms this: the jump is happening either way and the arrival should not be
-- recorded as a step. It simply has no area to offer.
local function noteIT(text)
    local verb = textOf(text:match("^(%a+)%s"))
    if not verb or not IT_VERBS[verb:lower()] then return end

    local target = textOf(text:match("^%a+%s+(.+)$"))
    if not target then return end
    target = trimBoth(target):lower()

    -- the whole target first, so 'monster hunter' beats 'monster'
    local want = IT_POINTS[target]
    if not want then
        local first = textOf(target:match("^(%S+)"))
        if first then want = IT_POINTS[first] end
    end

    it.want = want or ""
    it.at = os.time()
    it.left = false
end

-- What you typed, so the next room line knows how you got there. A plugin's
-- own send() does not come through here, so the training loop's movement is
-- not seen -- its rooms and stubs still land, its edges do not.
--
-- Compass directions only. Anything else is not a move as far as this is
-- concerned, and pretending otherwise is what wrote 'kill captain' into the map
-- as a travel method.
function onCommand(sessionId, command)
    if not recording() then return nil end
    local c = trimBoth(tostring(command or "")):lower()
    if c == "" then return nil end
    sawCommands = sawCommands + 1

    noteIT(c)

    local dir = nav.CANON[c]
    -- 'look east' does not move you, but the door message that follows is
    -- about east, and that is the cheapest way to check a door deliberately.
    if not dir then dir = nav.CANON[c:match("^look%s+(%S+)$") or ""] end
    if not dir then return nil end

    pend.cmd = dir
    pend.at = os.time()
    return nil
end

-- Same rule, the other doorway. If this fires for the training bot's send()
-- then the bot's walking finally records its edges instead of only its rooms.
function onSend(sessionId, text)
    if not recording() then return nil end
    local c = trimBoth(tostring(text or "")):lower()
    if c == "" then return nil end
    sawSends = sawSends + 1

    noteIT(c)

    local dir = nav.CANON[c]
    if not dir then return nil end

    pend.cmd = dir
    pend.at = os.time()
    return nil
end

function onDisconnect(sessionId)
    savePrefs()
    mapCall("unhighlightRoom")
    whereAt.vnum = nil
    whereAt.hash = ""
    pend.cmd = nil
end

function cleanup()
    savePrefs()
    -- a reload that leaves the old one mounted gives you two
    hideMap()
end
