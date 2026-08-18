plugin = {
    id          = "dbi-map",
    name        = "DB Infinity Scouter",
    version     = "2026.08.18.000",
    author      = "Solao",
    description = "Dragonball Infinity's GMCP map, rendered as a scouter readout.",
    settings    = { saveState = true },
}

-- Protocol, as implemented by the server (ported from Penguin's Mudlet GMCPMap):
--
--   Map.Definition  id, sequence, width, height, title, scope, anchor, styles
--                   styles = { [name] = { fg, bg, bold, italic, underline, reverse } }
--   Map.Snapshot    id, sequence, definition_sequence, rows, runs
--                   rows[y] = the text of that row
--                   runs[y] = list of { x, length, styleName }, x ZERO-based
--
-- Two things drive the design here, both learned the hard way elsewhere:
--
-- 1. The server sends nothing until our Core.Supports.Add lands AFTER the
--    client's own negotiation. See negotiate() below -- that ordering is the
--    whole reason the previous canvas version rendered on Windows and stayed
--    blank on Linux and Mac.
-- 2. Everything is copied into plain Lua tables the moment a packet arrives.
--    Holding the GMCP object and reading it during a later render gives empty
--    rows and runs; the client reuses the object once the callback returns.

local VERSION = "0.8.0"

-- Every line this plugin prints carries its version. Three copies of the
-- same plugin were once live at once and nothing in the output said so.
local TAG = "[DBI Scouter " .. VERSION .. "] "

-- The client does not reliably tear down a previous load's timers -- it is the
-- same gap that makes registerWidgetEvent stack handlers across a reload. So
-- each load stamps a token, and a tick that finds a newer token in the plugin
-- variable knows it belongs to a dead instance and retires itself. Without
-- this every reload leaves another negotiation schedule running in the dark.
local INSTANCE = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local tickTimer = nil

-- Scouter palette. Server styles win wherever the server bothers to colour
-- something; these cover the frame, the chrome and unstyled text.
-- All of these follow the lens. They used to be green constants, so choosing a
-- blue lens turned the glyphs blue and left the frame, the glow, the scanlines
-- and the lit buttons green around them.
-- The scouter lens: the colours of each, the list of them, which one is on,
-- whether it just changed and what it is subscribed to. Eleven file-scope
-- locals about one piece of glass.
--
-- Called 'glass' because 'lens' is bound elsewhere in this file.
local glass = {}

glass.DEEP  = "#03100a"
glass.FILL  = "#071d12"
glass.DEEP_RGB = "3,16,10"
glass.FILL_RGB = "7,29,18"

-- the edge colour as 'r,g,b', for every rgba() the panel composes
glass.RGB   = "37,255,136"
-- two darker steps of it, for the frame's gradient
glass.MID   = "#0b6b3a"
glass.DARK  = "#04241a"

-- 1 is the solid scouter; 0 leaves the glyphs and the frame over whatever is
-- behind the widget, so the panel can sit on top of the main output and the
-- text underneath stays readable.
-- The panel: its widget, its measured size, the grid it draws on, the font
-- and the character cell, the paddings and the toggles.
--
-- Twenty-two file-scope locals for one subject, which is a ninth of Lua's
-- 200-per-chunk budget spent on describing one box.
local ui = {}

ui.alpha = 1
-- The lens.
--
-- Green because that is what a scouter looks like, but this MUD colours its own
-- text from a fixed set of tokens -- &R red, &B blue, &C light cyan, &P pink
-- and the rest -- and it describes a scouter by its lens: "a scouter with a
-- blue-crystal lens". Those are the same handful of colours, so eventually the
-- panel can just be whatever is on your face. Chosen by hand until then.
--
-- Three shades each rather than one colour lightened and darkened: deriving
-- them needs hex arithmetic, and tonumber(s, 16) does not read hex in this
-- runtime -- see sharp edge 19, which cost the mapper four releases. Written
-- out, there is nothing to get wrong.
glass.ALL = {
    green  = { edge = "#25ff88", lit = "#7dffb0", dim = "#2f7a52" },
    blue   = { edge = "#3aa0ff", lit = "#8fc8ff", dim = "#2c5c8a" },
    cyan   = { edge = "#25f0ff", lit = "#8ff4ff", dim = "#2a7480" },
    red    = { edge = "#ff4b4b", lit = "#ff9b9b", dim = "#8a3030" },
    yellow = { edge = "#ffd21f", lit = "#ffe98a", dim = "#8a7420" },
    -- Gold is its own lens here, not a shade of yellow: the MUD prints
    -- 'gold-crystal' and colours it differently from its yellow.
    gold   = { edge = "#ffbf3c", lit = "#ffdc94", dim = "#8a6520" },
    orange = { edge = "#ff9a3c", lit = "#ffc48f", dim = "#8a5726" },
    purple = { edge = "#b06bff", lit = "#d3aeff", dim = "#5f3a8a" },
    pink   = { edge = "#ff6bc7", lit = "#ffaddf", dim = "#8a3a6d" },
    white  = { edge = "#ffffff", lit = "#dcdcdc", dim = "#6f6f6f" },
    grey   = { edge = "#c8c8c8", lit = "#9a9a9a", dim = "#565656" },
}

-- Hex a digit at a time. tonumber(s, 16) ignores the base in this runtime and
-- behaves as Number(s), so "ff" comes back NaN and NaN is truthy -- sharp edge
-- 19, which cost the mapper four releases before it was found.
-- The palette, and the hex table that reads it. Nine file-scope locals for
-- one set of colours.
local hue = {}

hue.HEX = {
    ["0"] = 0, ["1"] = 1, ["2"] = 2, ["3"] = 3, ["4"] = 4,
    ["5"] = 5, ["6"] = 6, ["7"] = 7, ["8"] = 8, ["9"] = 9,
    ["a"] = 10, ["b"] = 11, ["c"] = 12, ["d"] = 13, ["e"] = 14, ["f"] = 15,
}

local function hexPair(t)
    if type(t) ~= "string" or #t ~= 2 then return nil end
    local hi = hue.HEX[t:sub(1, 1):lower()]
    local lo = hue.HEX[t:sub(2, 2):lower()]
    if hi == nil or lo == nil then return nil end
    return hi * 16 + lo
end

-- '#rrggbb' -> r, g, b. Three returns, taken into three locals at every call
-- site: a multi-value return nested into another call arrives wrapped here.
local function hexRgb(hex)
    if type(hex) ~= "string" or #hex < 7 then return nil end
    local r = hexPair(hex:sub(2, 3))
    local g = hexPair(hex:sub(4, 5))
    local b = hexPair(hex:sub(6, 7))
    if r == nil or g == nil or b == nil then return nil end
    return r, g, b
end

local function twoDigit(n)
    local hexchars = "0123456789abcdef"
    local hi = math.floor(n / 16) + 1
    local lo = (n % 16) + 1
    return hexchars:sub(hi, hi) .. hexchars:sub(lo, lo)
end

-- the same colour, dimmed toward black
local function darken(hex, f)
    local r, g, b = hexRgb(hex)
    if not r then return hex end
    return "#" .. twoDigit(math.floor(r * f))
        .. twoDigit(math.floor(g * f)) .. twoDigit(math.floor(b * f))
end

glass.cur       = "green"
-- Set by hand, so equipment must not override it. Cleared with
-- 'dbscout lens auto', which is what follows the scouter on your face.
glass.manual    = false
-- Raised when a line changed the lens. readComms sits four hundred lines above
-- applyLens and saveSettings, so it cannot call either; handleLine can, and
-- does, on the way back out.
glass.justChanged = false
hue.PHOSPHOR   = glass.ALL.green.lit
hue.PHOS_DIM   = glass.ALL.green.dim
hue.EDGE       = glass.ALL.green.edge

-- Reassigns the three the stylesheet reads. chromeCss() builds on every render,
-- so the next paint is the new colour and nothing has to be threaded through.
local function setLens(name)
    local pick = glass.ALL[tostring(name or ""):lower()]
    if not pick then return false end

    glass.cur     = tostring(name):lower()
    hue.PHOSPHOR = pick.lit
    hue.PHOS_DIM = pick.dim
    hue.EDGE     = pick.edge

    local r, g, b = hexRgb(pick.edge)
    if r then glass.RGB = r .. "," .. g .. "," .. b end

    glass.MID  = darken(pick.edge, 0.42)
    glass.DARK = darken(pick.edge, 0.14)

    -- the glass itself: nearly black, with the lens in it
    glass.DEEP = darken(pick.edge, 0.06)
    glass.FILL = darken(pick.edge, 0.11)

    local dr, dg, db = hexRgb(glass.DEEP)
    if dr then glass.DEEP_RGB = dr .. "," .. dg .. "," .. db end
    local fr, fg, fb = hexRgb(glass.FILL)
    if fr then glass.FILL_RGB = fr .. "," .. fg .. "," .. fb end
    return true
end
hue.KI_BLUE    = "#4fc3ff"
hue.ALERT      = "#ff8a3d"
hue.READOUT    = "#ffd24a"     -- the scouter's own readout, over the map
hue.READOUT_HI = "#fff2b0"

ui.id = nil
-- Fitting, matching the house arithmetic: a monospace advance is near enough
-- 0.60em on every stack that matters, and the line height is set explicitly
-- below so it is not a guess. measureText is canvas-only and this is HTML.
ui.CH_W, ui.CH_H = 0.60, 1.15
ui.FS_MIN, ui.FS_MAX = 6, 34
ui.PAD = 10
ui.BAR_H = 22

-- A size you asked for, which beats the fitted one. Fitting can only answer
-- "as large as will go", and a dense map read at a glance beats a big one you
-- have to look across. 0 means fit.
ui.zoom = 0
ui.w = 460
ui.h = 320

-- The panel follows the terminal's own font rather than dictating one. Read
-- each render so a change in settings is picked up without a reload; the stack
-- behind it is the fallback for when the call is unavailable.
ui.FALLBACK = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"
ui.family = ""
ui.size = 13

ui.fontSize = 13
ui.header = true
ui.scan = true
local lastError = "none"

-- owned copies, keyed by map id
local defsById = {}
local pendingById = {}
local lastSeqById = {}
local currentMapId = nil
local curDef = nil
local curSnap = nil

-- what the grid is drawn at, resolved per render
ui.gridFont = 13
ui.cols = 0
ui.rows = 0
glass.sub = 22

-- The GMCP map arrives with a one-cell frame drawn into it; the panel has a
-- frame of its own. mapInset is how many cells of it to drop, resolved per
-- snapshot by frameInset().
ui.stripFrame = true
ui.inset = 0

-- The game's own scouter. 'scan <target>' answers with a name, three lines of
-- ASCII art, and a power level -- or garbage and a malfunction when the target
-- reads too high. The reading belongs under the map, not in the scroll.
-- A scan in flight and what came back: the target, its power, whether the
-- scouter is broken, what is pending, when, the animation, the timings and
-- the hit count.
--
-- Called 'sweep' because 'scan' is bound elsewhere in this file.
local sweep = {}

sweep.target = ""
sweep.power = ""
sweep.broken = false
sweep.pending = 0      -- lines of art still expected after the outline line
sweep.at = 0           -- os.time() of the reading, for the fade
sweep.anim = ""        -- the readout's animation rule, rebuilt each render
sweep.STEADY = 10     -- seconds before it starts pulsing
sweep.LIFE = 30       -- seconds before it is gone

-- Said once, ever. The plugin needs the server to stop drawing the map into
-- the stream, and nothing else tells a new user that -- without it this works
-- for whoever built it and looks broken for everyone else.
local CONFIG_HINT = "config -supermap -autocompass"
local hintShown = false

local gagArt = true        -- keep the scouter's ASCII art out of the terminal
local debugOn = false
sweep.hits = 0

-- negotiation state machine, driven by the 1s tick
-- GMCP negotiation: whether it is done, how many tries, the retry schedule
-- and its cap, the connection state, and what we introduce ourselves as.
-- Thirteen file-scope locals for one handshake.
local nego = {}

nego.done = false
nego.tries = 0
nego.tick = 0
nego.nextAt = 0
nego.connected = false
nego.firstPacketAfter = nil

-- 1.5s is the shortest delay that has been reliable after the client finishes
-- its own negotiation; everything after that is backoff. Eight attempts is
-- roughly two minutes, which is long enough that a server that has not
-- answered is not going to.
nego.SCHEDULE = { 2, 4, 9, 18, 30, 60, 90, 120 }
nego.MAX = 8

-- Core.Hello opens a GMCP session. The spec puts it before any Core.Supports.*
-- and a server is within its rights to discard whatever arrives ahead of it,
-- which is one explanation for a Supports.Add that never draws a reply. Sent
-- once per connection, immediately before the first Add so the order cannot
-- drift, and never again on a retry.
--
-- This server advertises CHARSET and nothing else -- it never sends WILL GMCP
-- -- so the client, correctly, never offers GMCP either. Mudlet says hello
-- regardless of what was advertised, and a server that enables GMCP on receipt
-- rather than announcing it will answer Mudlet and ignore us. That is the
-- difference this is here to close.
--
-- If the server turns out to gate the Map module on who is asking, CLIENT is
-- the one line to change. No API exposes the running client version to a
-- plugin; 'dbscout api version' enumerates _G if that ever changes.
nego.CLIENT = "MudForge"
nego.CLIENT_VERSION = "1.2.2035"
nego.helloSent = false

----------------------------------------------------------------------
-- value hygiene
--
-- Ported from Bo's v2.5.0 and kept intact. Every guard in here exists because
-- something in the Lua-to-JavaScript boundary lied at least once.
----------------------------------------------------------------------

-- tonumber() yields NaN rather than nil for a non-numeric string, and NaN
-- passes an `if n then` guard while poisoning every later calculation. NaN is
-- the only value not equal to itself; that is how it gets rejected.
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

local function numOr(v, fallback)
    local n = safeNum(v)
    if n then return n end
    return fallback
end

-- A missing GMCP field arrives as JavaScript `undefined`, which is truthy here
-- and is NOT equal to Lua nil. Truth tests have to be whitelists.
local function flag(v)
    if v == true then return true end
    if v == 1 then return true end
    if v == "1" or v == "true" or v == "yes" then return true end
    return false
end

-- A style colour may be a hex string, a CSS colour name, or one of the
-- protocol's own "ansi.*" names. CSS understands the first two; the third is
-- ours to translate. Values match the client's MUD palette, not the terminal's.
hue.ANSI = {
    ["ansi.black"]          = "#000000", ["ansi.red"]            = "#800000",
    ["ansi.green"]          = "#008000", ["ansi.yellow"]         = "#808000",
    ["ansi.blue"]           = "#000080", ["ansi.magenta"]        = "#800080",
    ["ansi.cyan"]           = "#008080", ["ansi.white"]          = "#c0c0c0",
    ["ansi.bright_black"]   = "#808080", ["ansi.bright_red"]     = "#ff0000",
    ["ansi.bright_green"]   = "#00ff00", ["ansi.bright_yellow"]  = "#ffff00",
    ["ansi.bright_blue"]    = "#0000ff", ["ansi.bright_magenta"] = "#ff00ff",
    ["ansi.bright_cyan"]    = "#00ffff", ["ansi.bright_white"]   = "#ffffff",
}

local function isColor(v)
    if type(v) ~= "string" then return false end
    if v == "" then return false end
    if v == "undefined" or v == "null" or v == "nil" or v == "false" then return false end
    return true
end

local function cssColor(v, fallback)
    if not isColor(v) then return fallback end
    local named = hue.ANSI[v:lower()]
    if named then return named end
    return v
end

-- Normalise any GMCP container into a 1-based Lua array plus its own count.
-- Handles real arrays (ipairs) and objects keyed by number (pairs fallback).
local function normArray(v)
    local out = {}
    local n = 0
    if type(v) ~= "table" then return out, 0 end

    -- Checked BEFORE trusting ipairs. A 0-indexed array has something at [0],
    -- and ipairs starts at 1 -- so it walks from the SECOND element, drops the
    -- first, and because it found some the fallback below never runs. Three
    -- rooms came back as two that way, silently.
    if v[0] == nil then
        for _, item in ipairs(v) do
            n = n + 1
            out[n] = item
        end
        if n > 0 then return out, n end
    end

    local tmp = {}
    local minK = nil
    local maxK = nil
    for k, item in pairs(v) do
        local nk = safeNum(k)
        if nk then
            tmp[nk] = item
            if minK == nil or nk < minK then minK = nk end
            if maxK == nil or nk > maxK then maxK = nk end
        end
    end
    if minK == nil then return out, 0 end

    if maxK > minK + 4096 then maxK = minK + 4096 end   -- never spin forever
    local shift = 0
    if minK == 0 then shift = 1 end
    local i = minK
    while i <= maxK do
        local item = tmp[i]
        if item ~= nil then
            local pos = i + shift
            out[pos] = item
            if pos > n then n = pos end
        end
        i = i + 1
    end
    return out, n
end

-- A run is documented as { x, length, styleName } but has also arrived as an
-- object with named fields. Returns x, length, styleName -- or three nils, so
-- every return path of this function is the same width.
local function runFields(rawRun)
    if type(rawRun) ~= "table" then return nil, nil, nil end

    local arr, n = normArray(rawRun)
    if n >= 3 then
        return numOr(arr[1], 0), numOr(arr[2], 0), tostring(arr[3] or "default")
    end

    local x = rawRun.x
    if x == nil then x = rawRun.start end
    if x == nil then x = rawRun.col end
    if x == nil then x = rawRun.offset end

    local len = rawRun.length
    if len == nil then len = rawRun.len end
    if len == nil then len = rawRun.count end
    if len == nil then len = rawRun.width end

    local st = rawRun.style
    if st == nil then st = rawRun.styleName end
    if st == nil then st = rawRun.name end
    if st == nil then st = rawRun.s end

    if x ~= nil and len ~= nil then
        return numOr(x, 0), numOr(len, 0), tostring(st or "default")
    end
    if n == 2 then
        return numOr(arr[1], 0), numOr(arr[2], 0), "default"
    end
    return nil, nil, nil
end

----------------------------------------------------------------------
-- text handling
--
-- Row text is server-controlled and goes into innerHTML, so it is escaped at
-- the point of output. The client's sanitiser is a second line of defence,
-- not the first one.
----------------------------------------------------------------------

local function escapeHtml(s)
    local out = tostring(s or "")
    out = out:gsub("&", "&amp;")
    out = out:gsub("<", "&lt;")
    out = out:gsub(">", "&gt;")
    out = out:gsub('"', "&quot;")
    return out
end

-- A style name off the wire becomes part of a CSS class name, so anything that
-- is not plainly alphanumeric gets folded away. Keeps a hostile or merely
-- sloppy style name from closing the <style> block.
local function classFor(styleName)
    local safe = tostring(styleName or "default"):lower():gsub("[^%w]", "-")
    if safe == "" then safe = "default" end
    return "sc-" .. safe
end

local function trimRight(s)
    return (tostring(s or ""):gsub("%s+$", ""))
end

-- The client hands back a "clean" line with the ESC and '[' eaten but the
-- parameters left behind: '0;37m|      @-+    |'. stripAnsiCodes cannot help,
-- there is no escape left to match. It shows up on rooms with no coloured runs,
-- where the server sends a bare reset and nothing else.
--
-- Narrow on purpose: only a leading parameter list terminated by 'm', which is
-- not a shape any line of this game's prose starts with.
local function dropAnsiDebris(s)
    local rest = s:match("^[%d;]+m(.*)$")
    if rest then return rest end
    return s
end

local function trimBoth(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Plain finds throughout rather than patterns: these are fixed strings, and
-- the pattern engine here is JavaScript's regex, which is not what Lua pattern
-- syntax looks like.
local OUTLINE = "A yellow outline forms around "
local OUTLINE_TAIL = " in your vision"
local ARROW = "`--->"
local MALFUNCTION = "Scouter Malfunction"

-- Row offsets in the protocol are CELL offsets. Lua's # and string.sub count
-- bytes, so a row carrying any multi-byte glyph would misalign every run after
-- it. These two walk UTF-8 continuation bytes (0x80..0xBF) so the grid stays
-- addressed in characters no matter what the server draws with.
local function cellLen(s)
    local n = 0
    local i = 1
    local size = #s
    while i <= size do
        local b = s:byte(i)
        if b < 128 or b >= 192 then n = n + 1 end
        i = i + 1
    end
    return n
end

local function cellSub(s, startZero, length)
    if length <= 0 then return "" end
    local stop = startZero + length
    local cells = 0
    local from = nil
    local to = #s + 1
    local i = 1
    local size = #s
    while i <= size do
        local b = s:byte(i)
        if b < 128 or b >= 192 then
            if cells == startZero then from = i end
            if cells == stop and to > size then to = i end
            cells = cells + 1
        end
        i = i + 1
    end
    if from == nil then return "" end
    return s:sub(from, to - 1)
end

----------------------------------------------------------------------
-- eager copies -- own the data before the client takes it back
----------------------------------------------------------------------

local function mapIdOf(t)
    if type(t) == "table" and t.id ~= nil then return tostring(t.id) end
    return "local"
end

local function copyDefinition(def)
    if type(def) ~= "table" then return nil end
    if type(def.styles) ~= "table" then return nil end
    -- v1 is the only shape documented; a later one is not ours to guess at.
    if numOr(def.version, 1) ~= 1 then return nil end

    local out = {}
    out.id = mapIdOf(def)
    out.sequence = safeNum(def.sequence)
    out.width = numOr(def.width, 0)
    out.height = numOr(def.height, 0)
    out.title = tostring(def.title or "Map")
    out.styles = {}
    out.styleCount = 0

    for name, st in pairs(def.styles) do
        if type(st) == "table" then
            out.styles[tostring(name)] = {
                fg        = cssColor(st.fg, nil),
                bg        = cssColor(st.bg, nil),
                bold      = flag(st.bold),
                italic    = flag(st.italic) or flag(st.italics),
                underline = flag(st.underline),
                strikeout = flag(st.strikeout),
                overline  = flag(st.overline),
                reverse   = flag(st.reverse),
            }
            out.styleCount = out.styleCount + 1
        end
    end
    return out
end

local function copySnapshot(snap)
    if type(snap) ~= "table" then return nil end
    if type(snap.rows) ~= "table" then return nil end
    if numOr(snap.version, 1) ~= 1 then return nil end

    local out = {}
    out.id = mapIdOf(snap)
    out.sequence = safeNum(snap.sequence)
    out.defSequence = safeNum(snap.definition_sequence)
    out.width = numOr(snap.width, 0)
    out.height = numOr(snap.height, 0)
    out.rows = {}
    out.runs = {}
    out.runTotal = 0

    local rows, rowN = normArray(snap.rows)
    local i = 1
    while i <= rowN do
        out.rows[i] = tostring(rows[i] or "")
        i = i + 1
    end
    out.rowN = rowN

    -- Both return values, deliberately. Capturing only the first leaves this
    -- holding the wrapped pair instead of the array and every lookup below
    -- silently yields nothing -- which is why runs never rendered once.
    local runRows, runRowN = normArray(snap.runs)
    i = 1
    while i <= rowN do
        local list = {}
        local ln = 0
        local rr, rc = normArray(runRows[i])
        local j = 1
        while j <= rc do
            local rx, rlen, rstyle = runFields(rr[j])
            if rx then
                ln = ln + 1
                list[ln] = { x = math.floor(rx), len = math.floor(rlen), style = rstyle }
            end
            j = j + 1
        end
        -- Sort by x before the renderer sees them. It walks a cursor left to
        -- right, so a run arriving out of order would land behind the cursor
        -- and be dropped without a sound.
        table.sort(list, function(a, b) return a.x < b.x end)
        list.n = ln
        out.runs[i] = list
        out.runTotal = out.runTotal + ln
        i = i + 1
    end

    return out
end

----------------------------------------------------------------------
-- rendering
----------------------------------------------------------------------

-- One CSS rule per named style off the definition. Inline colour is stripped
-- by the sanitiser, and the protocol hands us a bounded named set anyway, so
-- classes are both the safe option and the natural one.
local function styleCss(def)
    local css = ""
    if not def then return css end

    for name, st in pairs(def.styles) do
        local fg = cssColor(st.fg, nil)
        local bg = cssColor(st.bg, nil)
        if st.reverse == true then
            local swap = fg
            fg = cssColor(bg, glass.DEEP)
            bg = cssColor(swap, hue.PHOSPHOR)
        end

        local rule = ""
        if fg then rule = rule .. "color:" .. fg .. ";" end
        if bg then rule = rule .. "background:" .. bg .. ";" end
        if st.bold == true then rule = rule .. "font-weight:700;" end
        if st.italic == true then rule = rule .. "font-style:italic;" end
        -- one declaration, or a later text-decoration overwrites an earlier one
        local deco = ""
        if st.underline == true then deco = deco .. " underline" end
        if st.strikeout == true then deco = deco .. " line-through" end
        if st.overline == true then deco = deco .. " overline" end
        if deco ~= "" then rule = rule .. "text-decoration:" .. deco:sub(2) .. ";" end

        if rule ~= "" then
            css = css .. ".dbi-map ." .. classFor(name) .. "{" .. rule .. "}"
        end
    end
    return css
end

-- Largest size at which cols x rows still fits the panel. Returns the manual
-- zoom untouched when one is set.
-- Looked up through _G: a global this build does not have throws on the way IN,
-- where a pcall around the call itself cannot catch it.
local function readTerminalFont()
    local ok, fn = pcall(function() return _G["getTerminalFont"] end)
    if not ok or type(fn) ~= "function" then return end

    local good, f = pcall(fn)
    if not good or type(f) ~= "table" then return end

    if type(f.family) == "string" and f.family ~= "" then
        -- it lands in a stylesheet, so it cannot be allowed to close a rule
        ui.family = f.family:gsub("[;}<>]", "")
    end

    local n = safeNum(f.size)
    if n and n >= 6 and n <= 72 then ui.size = math.floor(n) end
end

local function chromeFont()
    if ui.family ~= "" then return ui.family .. "," .. ui.FALLBACK end
    return ui.FALLBACK
end

-- chrome sizes as ratios of the terminal's, with floors so a tiny terminal
-- font does not make the buttons unreadable
local function barSize()  return math.max(7, math.floor(ui.size * 0.60)) end
local function scanSize() return math.max(9, math.floor(ui.size * 0.85)) end
local function idleSize() return math.max(9, math.floor(ui.size * 0.80)) end

local function fitFontSize(cols, rows)
    if ui.zoom > 0 then return ui.zoom end
    if cols < 1 or rows < 1 then return ui.fontSize end

    local availW = ui.w - ui.PAD * 2
    local availH = ui.h - ui.PAD * 2
    if ui.header then availH = availH - ui.BAR_H end
    if availW < 1 or availH < 1 then return ui.FS_MIN end

    local fs = math.floor(math.min(availW / (cols * ui.CH_W), availH / (rows * ui.CH_H)))
    return math.max(ui.FS_MIN, math.min(ui.FS_MAX, fs))
end

-- Rules only, no <style> wrapper. render() emits one tag around all three
-- sources; wrapping them individually put the later two outside the first
-- tag, where the browser rendered them as text across the top of the panel.
local function chromeCss()
    local scan = ""
    if ui.scan then
        scan = ".dbi-map .lens::after{content:'';position:absolute;inset:0;pointer-events:none;"
            .. "background:repeating-linear-gradient(180deg," .. "rgba(" .. glass.RGB .. ",0.07)" .. " 0 1px,transparent 1px 4px);}"
    end

    -- Everything the panel paints scales with alpha, so "transparent" means
    -- the terminal behind it is actually readable rather than merely tinted.
    local a = ui.alpha
    local fill = "rgba(" .. glass.FILL_RGB .. "," .. (a * 0.92) .. ")"
    local deep = "rgba(" .. glass.DEEP_RGB .. "," .. a .. ")"
    local lensFill = "rgba(" .. glass.FILL_RGB .. "," .. (a * 0.55) .. ")"

    -- Fit by measuring the box in CSS rather than asking the client, which
    -- reported 300x200 for a panel that was nothing of the sort. 100cqw/100cqh
    -- are the lens's own content box. The px size above it is the fallback for
    -- an engine without container queries; a parser that understands the second
    -- declaration overrides with it, one that does not keeps the first.
    local fitRule = ""
    if ui.cols > 0 and ui.rows > 0 then
        fitRule = "font-size:clamp(" .. ui.FS_MIN .. "px,min("
            .. "calc(100cqw / " .. (ui.cols * ui.CH_W) .. "),"
            .. "calc(100cqh / " .. (ui.rows * ui.CH_H) .. ")),"
            .. ui.FS_MAX .. "px);"
    end

    -- .dbi-map is a container so the bar can query it; .lens is a separate one
    -- so the grid measures the lens rather than the whole panel.
    -- Column flex rather than a calc() height on the lens. The scan strip was
    -- rendering correctly and being clipped: .dbi-map is overflow:hidden, so
    -- any error in the arithmetic pushed the strip past the bottom edge and it
    -- vanished. Flex gives the lens whatever is left instead of a computed
    -- number, so the strip cannot be squeezed out.
    return ".dbi-map{position:relative;height:100%;box-sizing:border-box;padding:8px;"
        .. "display:flex;flex-direction:column;container-type:inline-size;"
        .. "background:radial-gradient(120% 90% at 50% 0%," .. fill .. " 0%," .. deep .. " 70%);"
        .. "color:" .. hue.PHOSPHOR .. ";overflow:hidden;"
        .. "font-family:" .. chromeFont() .. ";}"

        -- nowrap with everything shrinkable except the buttons: the readout
        -- used to be nowrap with no shrink, which shoved 'hide' off the edge
        .. ".dbi-map .bar{flex:0 0 auto;display:flex;align-items:center;gap:4px;margin-bottom:6px;"
        .. "height:" .. (barSize() + 8) .. "px;"
        .. "font-size:" .. barSize() .. "px;letter-spacing:0.12em;text-transform:uppercase;color:" .. hue.EDGE .. ";}"
        .. ".dbi-map .bar .ttl{flex:1 1 auto;min-width:0;overflow:hidden;"
        .. "text-overflow:ellipsis;white-space:nowrap;}"
        .. ".dbi-map .bar .rd{flex:0 1 auto;min-width:0;overflow:hidden;"
        .. "text-overflow:ellipsis;white-space:nowrap;color:" .. hue.PHOS_DIM .. ";}"
        .. ".dbi-map .tb{flex:0 0 auto;font-size:" .. barSize() .. "px;letter-spacing:0.1em;text-transform:uppercase;"
        .. "padding:2px 5px;border-radius:2px;border:1px solid " .. hue.PHOS_DIM .. ";color:" .. hue.PHOS_DIM .. ";"
        .. "cursor:pointer;user-select:none;white-space:nowrap;}"
        .. ".dbi-map .tb:hover{color:" .. hue.PHOSPHOR .. ";border-color:" .. hue.EDGE .. ";}"
        .. ".dbi-map .tb.on{color:" .. hue.EDGE .. ";border-color:" .. hue.EDGE .. ";background:rgba(" .. glass.RGB .. ",0.12);}"
        -- narrow panel: the readout is the first thing to go, then the title.
        -- The buttons never go, because they are the only way to work the panel.
        .. "@container (max-width:260px){.dbi-map .bar .rd{display:none;}}"
        -- The comms row. One line, never two: it wrapped, and a second row of
        -- chrome above a 15x15 lens is most of the panel.
        .. ".dbi-map .cm{flex:0 0 auto;display:flex;align-items:center;gap:4px;"
        .. "margin-bottom:6px;flex-wrap:nowrap;overflow:hidden;}"
        -- the channel reads like the rest of the readout, not like a web form
        .. ".dbi-map .cm input{flex:1 1 auto;min-width:0;box-sizing:border-box;"
        .. "background-color:rgba(0,0,0,0.5);color:" .. hue.PHOSPHOR .. ";"
        .. "font:inherit;font-size:" .. barSize() .. "px;letter-spacing:0.16em;"
        .. "text-align:center;border:1px solid " .. hue.PHOS_DIM .. ";"
        .. "border-radius:2px;padding:2px 4px;}"
        .. ".dbi-map .cm input:focus{outline:none;border-color:" .. hue.EDGE .. ";"
        .. "color:" .. hue.EDGE .. ";}"
        -- a button carries the browser's own chrome unless it is taken off
        .. ".dbi-map .cm button{margin:0;background:none;appearance:none;"
        .. "-webkit-appearance:none;font:inherit;}"
        -- the ask fills the row it stands in for
        .. ".dbi-map .cm .ask{flex:1 1 auto;text-align:center;}"
        -- the padlock and the tick sit on the baseline like the words beside them
        .. ".dbi-map .cm .ic{display:flex;align-items:center;padding:2px 4px;}"
        -- the tick lights while the channel is being edited
        .. ".dbi-map .cm:focus-within button{color:" .. hue.EDGE .. ";"
        .. "border-color:" .. hue.EDGE .. ";background:rgba(" .. glass.RGB .. ",0.12);}"
        .. "@container (max-width:190px){.dbi-map .bar .ttl{display:none;}}"

        -- the readout itself: clipped corners give it the scouter lens outline
        -- Pinned inside the lens rather than given a row of its own. It takes
        -- no height from the map, so it cannot be squeezed out of the layout,
        -- and it reads over the grid on the rare row it covers. The shadow is
        -- what keeps it legible there.
        .. ".dbi-map .scan{position:absolute;left:0;right:0;bottom:0;z-index:2;"
        .. "padding:6px 10px;font-size:" .. scanSize() .. "px;line-height:1.35;letter-spacing:0.04em;"
        .. "color:" .. hue.READOUT .. ";pointer-events:none;"
        .. "text-shadow:0 0 5px rgba(0,0,0,0.95),0 0 2px rgba(0,0,0,1);}"
        .. ".dbi-map .scan .ln{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}"
        .. "@keyframes dbiPulse{0%,100%{opacity:1}50%{opacity:0.30}}"
        .. "@keyframes dbiOut{from{opacity:1}to{opacity:0;visibility:hidden}}"
        .. ".dbi-map .scan .val{color:" .. hue.READOUT_HI .. ";}"
        .. ".dbi-map .scan .val.bad{color:" .. hue.ALERT .. ";}"

        .. ".dbi-map .lens{position:relative;flex:1 1 auto;min-height:0;overflow:auto;"
        .. "container-type:size;"
        .. "display:flex;align-items:center;justify-content:center;"
        .. "border:1px solid rgba(" .. glass.RGB .. ",0.28);"
        .. "clip-path:polygon(10px 0,100% 0,100% calc(100% - 10px),calc(100% - 10px) 100%,0 100%,0 10px);"
        .. "background:" .. lensFill .. ";box-shadow:inset 0 0 22px rgba(" .. glass.RGB .. ",0.10);}"
        .. ".dbi-map .grid{margin:0;padding:0;white-space:pre;font:inherit;"
        .. "line-height:" .. ui.CH_H .. ";font-size:" .. ui.gridFont .. "px;" .. fitRule .. "}"

        -- targeting brackets, drawn rather than shipped as art
        .. ".dbi-map .br{position:absolute;width:12px;height:12px;pointer-events:none;"
        .. "border-color:" .. hue.EDGE .. ";opacity:0.75;}"
        .. ".dbi-map .br.tl{top:2px;left:2px;border-top:2px solid;border-left:2px solid;}"
        .. ".dbi-map .br.tr{top:2px;right:2px;border-top:2px solid;border-right:2px solid;}"
        .. ".dbi-map .br.bl{bottom:2px;left:2px;border-bottom:2px solid;border-left:2px solid;}"
        .. ".dbi-map .br.br2{bottom:2px;right:2px;border-bottom:2px solid;border-right:2px solid;}"

        .. ".dbi-map .idle{padding:14px 10px;font-size:" .. idleSize() .. "px;line-height:1.7;color:" .. hue.PHOS_DIM .. ";}"
        .. ".dbi-map .idle b{color:" .. hue.ALERT .. ";font-weight:600;}"
        .. ".dbi-map .idle .ki{color:" .. hue.KI_BLUE .. ";}"
        .. scan
end

-- Walk one row, emitting a span per run and filling the gaps between them with
-- the default style. Offsets are cell-based; cellSub keeps that true even when
-- the row carries multi-byte glyphs.
-- The scouter's own comms panel, read off 'scouter display':
--
--   Energy Detection Capacity: 100,000,000,000
--   Channel Frequency: 624
--   Transmit Function: Active
--   Receive Function: Active
--   Encrypt Function: Not Installed
--
-- Nothing here is assumed. Until that block has been seen every field is nil
-- and the panel says so, rather than drawing a switch in a position it has
-- guessed at.
local comms = { freq = nil, tx = nil, rx = nil, enc = nil, cap = nil }

-- The MUD's own commands, in one place. 'scouter (field) <value>' is the usage
-- it prints; display and smash plainly take no value and frequency plainly
-- takes one, which leaves transmit and receive ambiguous. They are sent bare,
-- as toggles. If this MUD wants 'on'/'off' after them these are the two lines
-- that change.
local CMD_TX = "scouter transmit"
local CMD_RX = "scouter receive"
local CMD_FREQ = "scouter frequency "
local CMD_SHOW = "scouter display"

-- 'Active' is on. Anything else -- 'Not Active', 'Not Installed' -- is off, and
-- the difference between those two is worth keeping, so the raw word is stored
-- rather than a boolean.
local function commsState(word)
    if type(word) ~= "string" then return nil end
    return trimBoth(word)
end

local function commsOn(word)
    return type(word) == "string" and word:lower() == "active"
end

-- One line at a time; nothing here needs the block to arrive intact, so a
-- 'scouter display' that gets interleaved with combat still lands.
-- Everything the panel thinks it knows about the scouter, dropped.
local function forgetComms()
    comms.freq = nil
    comms.tx = nil
    comms.rx = nil
    comms.enc = nil
    comms.cap = nil
end

local function readComms(clean)
    -- Dying invalidates the reading. Whether the scouter survives it or not,
    -- what it was set to before you died is not what it is set to now, and the
    -- ask button is a better answer than a stale channel.
    if clean:find("begins to fade to black", 1, true) then
        forgetComms()
        return true
    end

    -- So does changing scouters, and that is not a corner case: they are not
    -- all the same device. A Primitive Scouter reads channel 0, transmit and
    -- receive inactive, and a detection capacity of 1,000,000; the blue-crystal
    -- one reads 624, both active, and a hundred billion. Whatever the panel was
    -- told belonged to whichever was on your face at the time.
    if clean:find("You stop using", 1, true)
        and clean:lower():find("scouter", 1, true) then
        forgetComms()
        return true
    end

    -- Anything going onto your eyes displaces the scouter, whether or not the
    -- thing arriving is one.
    if clean:find("on your eyes", 1, true) then
        forgetComms()

        -- The MUD names the lens in the item: "A scouter with a blue-crystal
        -- lens". That is the colour of the thing on your face, so the panel
        -- becomes it.
        --
        -- Matched on '<colour>-crystal' rather than by looking for a colour
        -- word anywhere in the line, which would find the 'red' in 'sacred'.
        -- Anything with no lens named -- "A Primitive Scouter" -- goes back to
        -- green, so the panel is never left wearing the last scouter's colour.
        local want = clean:lower():match("(%a+)%-crystal")
        local got = false
        if want then got = setLens(want) end
        if not got then setLens("green") end
        glass.justChanged = true
        return true
    end

    local got = false

    local cap = clean:match("Energy Detection Capacity:%s*([%d,]+)")
    if cap then comms.cap = cap; got = true end

    local freq = clean:match("Channel Frequency:%s*(%d+)")
    if freq then comms.freq = freq; got = true end

    -- '(.+)$' rather than a word class: 'Not Installed' is two words and the
    -- distinction between that and 'Not Active' is real.
    local tx = clean:match("Transmit Function:%s*(.+)$")
    if tx then comms.tx = commsState(tx); got = true end

    local rx = clean:match("Receive Function:%s*(.+)$")
    if rx then comms.rx = commsState(rx); got = true end

    local enc = clean:match("Encrypt Function:%s*(.+)$")
    if enc then comms.enc = commsState(enc); got = true end

    return got
end

local function renderRow(row, list)
    local width = cellLen(row)
    local out = ""
    local cursor = 0
    local runN = 0
    if list then runN = list.n or 0 end

    local ri = 1
    while ri <= runN do
        local run = list[ri]
        if run then
            local runX = math.max(0, run.x)
            local runEnd = math.min(width, runX + math.max(0, run.len))

            if runX > cursor then
                out = out .. escapeHtml(cellSub(row, cursor, runX - cursor))
            end

            local from = math.max(cursor, runX)
            if runEnd > from then
                out = out .. '<span class="' .. classFor(run.style) .. '">'
                    .. escapeHtml(cellSub(row, from, runEnd - from)) .. "</span>"
                cursor = runEnd
            end
        end
        ri = ri + 1
    end

    if cursor < width then
        out = out .. escapeHtml(cellSub(row, cursor, width - cursor))
    end
    return out
end

-- The server draws a one-cell frame into the map itself: the first and last
-- rows open and close with '+', every row between them with '|'. Detected
-- rather than assumed, so a map that arrives without one is left alone and a
-- change of format degrades to drawing the frame instead of eating a column.
-- 'border' and 'border.htanks' are the frame's own styles in the definition.
local function isBorderStyle(name)
    return type(name) == "string" and name:sub(1, 6) == "border"
end

local function allBorderRuns(list)
    if type(list) ~= "table" then return false end
    local n = list.n or 0
    if n == 0 then return false end

    local i = 1
    while i <= n do
        if not isBorderStyle(list[i].style) then return false end
        i = i + 1
    end
    return true
end

local function frameInset(snap, rowN, width)
    if not ui.stripFrame then return 0 end
    if rowN < 3 or width < 3 then return 0 end

    -- The server names the frame, so ask it rather than matching glyphs: style
    -- names are protocol and the characters they are drawn with are cosmetic.
    if allBorderRuns(snap.runs[1]) and allBorderRuns(snap.runs[rowN]) then return 1 end

    -- No runs on those rows: fall back to the shape they are drawn in.
    local rows = snap.rows
    local top = rows[1] or ""
    local bot = rows[rowN] or ""
    if cellSub(top, 0, 1) ~= "+" or cellSub(top, width - 1, 1) ~= "+" then return 0 end
    if cellSub(bot, 0, 1) ~= "+" or cellSub(bot, width - 1, 1) ~= "+" then return 0 end

    local i = 2
    while i < rowN do
        if cellSub(rows[i] or "", 0, 1) ~= "|" then return 0 end
        i = i + 1
    end
    return 1
end

-- Runs are keyed to cell offsets, so dropping a column from the left means
-- moving every run with it and re-clipping the ones that straddle an edge.
local function shiftRuns(list, inset, innerWidth)
    local out = { n = 0 }
    if not list then return out end

    local i = 1
    local runN = list.n or 0
    while i <= runN do
        local run = list[i]
        if run then
            local x = run.x - inset
            local len = run.len
            if x < 0 then
                len = len + x
                x = 0
            end
            if x + len > innerWidth then len = innerWidth - x end
            if len > 0 then
                out.n = out.n + 1
                out[out.n] = { x = x, len = len, style = run.style }
            end
        end
        i = i + 1
    end
    return out
end

local function idleBody()
    local state = "negotiating"
    if nego.done then state = "listening"
    elseif nego.tries >= nego.MAX then state = "no answer" end

    return '<div class="idle">'
        .. "no reading yet<br><br>"
        .. "gmcp: <b>" .. state .. "</b> (" .. nego.tries .. "/" .. nego.MAX .. ")<br>"
        .. "capture: waiting for a map to scroll past<br><br>"
        .. "move a room and it should fill in<br><br>"
        .. "if the map is in your output instead, run<br>"
        .. '<span class="ki">' .. CONFIG_HINT .. "</span><br>"
        .. '<span class="ki">dbscout diag</span> for what the scouter sees'
        .. "</div>"
end

local function mapBody()
    local height = math.floor(numOr(curDef.height, curSnap.rowN))
    if height < 1 or height > curSnap.rowN then height = curSnap.rowN end
    local width = math.floor(numOr(curDef.width, 0))

    local inset = ui.inset
    local innerWidth = width - inset * 2
    if innerWidth < 1 then
        innerWidth = width
        inset = 0
    end

    local body = '<pre class="grid">'
    local first = 1 + inset
    local last = height - inset
    local y = first
    while y <= last do
        local row = curSnap.rows[y] or ""
        local pad = width - cellLen(row)
        if pad > 0 then row = row .. string.rep(" ", pad) end
        if inset > 0 then row = cellSub(row, inset, innerWidth) end
        body = body .. renderRow(row, shiftRuns(curSnap.runs[y], inset, innerWidth))
        if y < last then body = body .. "\n" end
        y = y + 1
    end
    return body .. "</pre>"
end

local function render()
    if not ui.id then return end

    -- Fit first: chromeCss reads gridFont when it builds the grid rule.
    local cols, rows = 0, 0
    if curSnap and curDef then
        local w = math.floor(numOr(curDef.width, 0))
        local h = math.floor(numOr(curDef.height, curSnap.rowN))
        if h < 1 or h > curSnap.rowN then h = curSnap.rowN end
        ui.inset = frameInset(curSnap, h, w)
        cols = w - ui.inset * 2
        rows = h - ui.inset * 2
    end
    ui.cols = cols
    ui.rows = rows

    readTerminalFont()

    -- Only the bar takes height off the lens now; the readout is pinned inside
    -- it and overlays the map instead of shortening it.
    glass.sub = 0
    if ui.header then glass.sub = glass.sub + barSize() + 14 end

    ui.gridFont = fitFontSize(cols, rows)

    local head = ""
    if ui.header then
        local title = "Scouter"
        local readout = "no signal"
        if curDef then title = curDef.title end
        -- short: this is the first thing squeezed out on a narrow panel
        if curSnap then
            readout = ui.cols .. "x" .. ui.rows .. " s" .. tostring(curSnap.sequence or "-")
        end
        local scanOn = ""
        if ui.scan then scanOn = " on" end
        head = '<div class="bar"><span class="ttl">' .. escapeHtml(title) .. "</span>"
            .. '<span class="rd">' .. escapeHtml(readout) .. "</span>"
            .. '<span class="tb" data-mud-action="smaller">&minus;</span>'
            .. '<span class="tb" data-mud-action="bigger">+</span>'
            .. '<span class="tb' .. scanOn .. '" data-mud-action="scan">scan</span>'
            .. '<span class="tb" data-mud-action="close">hide</span></div>'
    end

    local inner = idleBody()
    if curSnap and curDef then
        inner = mapBody()
    end

    local scanHtml = ""
    sweep.anim = ""
    local age = os.time() - sweep.at
    if sweep.target ~= "" and age < sweep.LIFE then
        local cls = "val"
        if sweep.broken then cls = "val bad" end

        -- The panel is rebuilt on every map update, so a fresh element would
        -- restart the animation and the readout would never age out while you
        -- walk around. Feeding the elapsed time back as a delay resumes it
        -- where it should be: negative once the phase is already under way.
        -- Into the stylesheet rather than an inline style attribute: the
        -- sanitiser is known to strip inline colour and this is not worth
        -- finding out about the hard way.
        sweep.anim = ".dbi-map .scan{animation:dbiPulse 1.4s ease-in-out "
            .. (sweep.STEADY - age) .. "s infinite,"
            .. "dbiOut 1.2s linear " .. (sweep.LIFE - 1.2 - age) .. "s forwards;}"

        scanHtml = '<div class="scan">'
            .. '<div class="ln">Target: <span class="val">' .. escapeHtml(sweep.target) .. "</span></div>"
            .. '<div class="ln">Power: <span class="' .. cls .. '">' .. escapeHtml(sweep.power) .. "</span></div>"
            .. "</div>"
    end

    -- TX, RCV and the channel. A button carries 'on' only when the MUD has
    -- actually said Active; before 'scouter display' has been seen they read
    -- '?' rather than pretending to know.
    local txOn, rxOn = "", ""
    if commsOn(comms.tx) then txOn = " on" end
    if commsOn(comms.rx) then rxOn = " on" end

    local txLbl, rxLbl = "tx ?", "rcv ?"
    if comms.tx then txLbl = "tx" end
    if comms.rx then rxLbl = "rcv" end

    local freq = ""
    if comms.freq then freq = comms.freq end

    -- A padlock rather than the words. 'no crypt' spelled out wrapped the row
    -- onto a second line, and a second row of chrome above a 15x15 lens is most
    -- of the panel.
    --
    -- Drawn rather than written: stroke="currentColor" means the shape takes
    -- the same phosphor as everything around it, including the brighter 'on'
    -- state, which no glyph or emoji does.
    local encHtml = ""
    if comms.enc then
        local shackle = "M5.5 7V5a2.5 2.5 0 0 1 5 0"
        local encOn = ""
        if commsOn(comms.enc) then
            -- closed: the shackle comes back down into the body
            shackle = shackle .. "v2"
            encOn = " on"
        end

        encHtml = '<span class="tb ic' .. encOn .. '" title="encryption">'
            .. '<svg viewBox="0 0 16 16" width="1em" height="1em" fill="none"'
            .. ' stroke="currentColor" stroke-width="1.6"'
            .. ' stroke-linecap="round" stroke-linejoin="round">'
            .. '<rect x="3" y="7" width="10" height="7" rx="1.5"></rect>'
            .. '<path d="' .. shackle .. '"></path>'
            .. "</svg></span>"
    end

    -- Nothing read yet: one button that goes and asks, rather than a row of
    -- controls in states nobody has confirmed.
    --
    -- Deliberately NOT saved between sessions. TX, RCV and the channel can all
    -- be changed in game by other means, so a restored value is last session's
    -- reading presented as this session's -- a confident answer that might be
    -- wrong, which is worse here than an empty one.
    local commsHtml = '<form class="cm">'
        .. '<span class="tb' .. txOn .. '" data-mud-action="tx">'
        .. escapeHtml(txLbl) .. "</span>"
        .. '<span class="tb' .. rxOn .. '" data-mud-action="rx">'
        .. escapeHtml(rxLbl) .. "</span>"
        .. encHtml
        .. '<input type="text" name="freq" inputmode="numeric" value="'
        .. escapeHtml(freq) .. '" placeholder="freq">'
        -- A tick rather than the word, dim until the channel is being edited.
        --
        -- It cannot know the number was ALTERED -- no script runs in a widget,
        -- so there is nothing to compare the field against its original value.
        -- :focus-within is the achievable version and lands on the same moment:
        -- it lights while you are in the field.
        .. '<button type="submit" class="tb ic" title="set the channel">'
        .. '<svg viewBox="0 0 16 16" width="1em" height="1em" fill="none"'
        .. ' stroke="currentColor" stroke-width="2"'
        .. ' stroke-linecap="round" stroke-linejoin="round">'
        .. '<path d="M3 8.5l3.5 3.5L13 4.5"></path>'
        .. "</svg></button>"
        .. "</form>"

    -- Nothing read yet: one button that goes and asks, instead of a row of
    -- controls sitting in states nobody has confirmed.
    --
    -- Deliberately NOT saved between sessions. TX, RCV and the channel can all
    -- be changed in game by other means, so a restored value is last session's
    -- reading shown as this session's -- a confident answer that might be
    -- wrong, which is worse here than an empty one.
    if comms.tx == nil and comms.rx == nil and comms.freq == nil then
        commsHtml = '<div class="cm"><span class="tb ask"'
            .. ' data-mud-action="comms">scouter display</span></div>'
    end

    setWidgetProperty(ui.id, "content",
        "<style>" .. chromeCss() .. styleCss(curDef) .. sweep.anim .. "</style>"
        .. '<div class="dbi-map">' .. head .. commsHtml
        .. '<div class="lens">' .. inner
        .. '<i class="br tl"></i><i class="br tr"></i><i class="br bl"></i><i class="br br2"></i>'
        .. scanHtml
        .. "</div></div>")
end

local function safeRender()
    local ok, err = pcall(render)
    if not ok then
        lastError = tostring(err)
        print(TAG .. "render error: " .. lastError)
    end
end

----------------------------------------------------------------------
-- protocol
----------------------------------------------------------------------

-- The object handed to an onGMCPUpdate callback has arrived without its nested
-- runs arrays while getGMCPData returned the whole thing. Try both, keep
-- whichever actually carries runs.
local function fetchPayload(pkg, field)
    local direct = getGMCPData(pkg)
    if type(direct) == "table" then return direct end
    local parent = getGMCPData("Map")
    if type(parent) == "table" and type(parent[field]) == "table" then
        return parent[field]
    end
    return nil
end

local function markAlive()
    if not nego.done then
        nego.done = true
        nego.firstPacketAfter = nego.tries
        print(TAG .. "server answered after " .. nego.tries .. " negotiation attempt(s)")
    end
end

local function acceptSnapshot(rawIn)
    local snap = copySnapshot(rawIn)
    local raw = rawIn
    if not snap or snap.runTotal == 0 then
        local fetched = fetchPayload("Map.Snapshot", "Snapshot")
        if fetched then
            local alt = copySnapshot(fetched)
            if alt and (not snap or alt.runTotal > 0) then
                snap = alt
                raw = fetched
            end
        end
    end
    if not snap then return false end
    markAlive()

    local mapId = snap.id
    local prevSeq = lastSeqById[mapId]
    if snap.sequence and prevSeq and snap.sequence <= prevSeq then return false end

    local def = nil
    if type(raw.styles) == "table" then
        def = copyDefinition(raw)
    else
        def = defsById[mapId]
        if def and snap.defSequence and def.sequence and snap.defSequence ~= def.sequence then
            def = nil
        end
    end

    if not def then
        pendingById[mapId] = snap
        return false
    end

    currentMapId = mapId
    curSnap = snap
    curDef = def
    if snap.sequence then lastSeqById[mapId] = snap.sequence end
    pendingById[mapId] = nil
    safeRender()
    return true
end

local function acceptDefinition(rawIn)
    local def = copyDefinition(rawIn)
    if not def or def.styleCount == 0 then
        local fetched = fetchPayload("Map.Definition", "Definition")
        if fetched then
            local alt = copyDefinition(fetched)
            if alt and alt.styleCount > 0 then def = alt end
        end
    end
    if not def then return false end
    markAlive()

    local mapId = def.id
    local prior = defsById[mapId]
    if def.sequence and prior and prior.sequence and def.sequence < prior.sequence then
        return false
    end

    defsById[mapId] = def
    if currentMapId == mapId then curDef = def end

    local pending = pendingById[mapId]
    if pending and (pending.defSequence == nil or pending.defSequence == def.sequence) then
        pendingById[mapId] = nil
        currentMapId = mapId
        curSnap = pending
        curDef = def
        if pending.sequence then lastSeqById[mapId] = pending.sequence end
    end
    safeRender()
    return true
end

----------------------------------------------------------------------
-- negotiation
--
-- THE FIX. MudForge sends its own Core.Supports.Set while it negotiates the
-- connection, and a Set REPLACES the server's record of what we subscribe to
-- rather than merging into it. An Add that lands before that Set is erased
-- with no error and no symptom beyond a map that stays empty forever.
--
-- The previous version sent its Add bare in init() and bare in onConnect, and
-- won that race on Windows and lost it on Linux and macOS. So: never send on
-- the connect edge, wait for the client to finish, and keep asking on a backoff
-- until a Map packet actually arrives. Bounded at NEGO_MAX so a server that
-- does not implement the module is not pestered forever.
----------------------------------------------------------------------

-- Raw one-arg form rather than the table overload: this is the exact wire
-- format the spec asks for, with no encoder between us and it.
-- Portrait needs the same handshake and each panel has to work alone, so the
-- stamp lives in the app-wide variable scope: whoever gets there first sends
-- it, the other sees a recent stamp and stays quiet. If both check inside the
-- same second two Hellos go out, which an idempotent handshake should not
-- mind, but it is a narrowed race rather than a closed one.
nego.HELLO_KEY = "dbi-gmcp-hello"
nego.HELLO_WINDOW = 30

local function sendHello(force)
    nego.helloSent = true

    if not force then
        local last = safeNum(getVariable(nego.HELLO_KEY, "global"))
        local now = os.time()
        if last and (now - last) < nego.HELLO_WINDOW then
            if debugOn then print(TAG .. "hello already sent by another plugin") end
            return
        end
    end

    setVariable(nego.HELLO_KEY, tostring(os.time()), "global")
    -- Two-arg form: the client JSON-encodes the table. Hand-building the wire
    -- string meant hand-building its quoting and escaping too, which is a
    -- source of bugs for no gain.
    sendGMCP("Core.Hello", { client = nego.CLIENT, version = nego.CLIENT_VERSION })
end

local function sendSupports()
    if not nego.helloSent then sendHello() end
    nego.tries = nego.tries + 1
    -- An array table encodes to ["Map 1"], which is what the option list is.
    sendGMCP("Core.Supports.Add", { "Map 1" })
end

-- This panel owns the GMCP handshake when it is installed, and says so.
--
-- Core.Hello and Core.Supports.Add only need sending once a session, and every
-- plugin sending its own means two of each. The stamp below is the cross-load
-- backstop; this is the same-session one, and it is the reliable half --
-- setVariable is debounced, so two plugins starting in the same tick can both
-- read 'nobody has yet' before either write lands. The bus is synchronous and
-- has no such gap.
--
-- Ownership sits here rather than in the portrait because the retry schedule
-- and the negotiation diagnostics are here. A plugin that cannot retry is the
-- wrong one to be responsible for a handshake that can go unanswered.
local function claimGmcp()
    pcall(function() emit("dbi.gmcp.owner", { by = "scouter" }) end)
end

local function armNegotiation(why)
    claimGmcp()
    nego.done = false
    nego.tries = 0
    nego.tick = 0
    nego.nextAt = nego.SCHEDULE[1]
    nego.firstPacketAfter = nil
    print(TAG .. "negotiation armed (" .. why .. ")")
end

local function negotiationTick()
    if not nego.connected then return end
    if nego.done then return end
    if nego.tries >= nego.MAX then return end

    nego.tick = nego.tick + 1
    if nego.tick < nego.nextAt then return end

    sendSupports()

    local nextGap = nego.SCHEDULE[nego.tries + 1]
    if nextGap == nil then nextGap = 120 end
    nego.nextAt = nego.tick + nextGap

    -- A definition may already be sitting in the store from before we
    -- subscribed; sweep it rather than waiting for the next push.
    local d = fetchPayload("Map.Definition", "Definition")
    if d then acceptDefinition(d) end
    local s = fetchPayload("Map.Snapshot", "Snapshot")
    if s then acceptSnapshot(s) end

    if not nego.done then safeRender() end
end

----------------------------------------------------------------------
-- widget
----------------------------------------------------------------------

local function saveSettings()
    setVariable("fontSize", tostring(ui.fontSize))
    setVariable("showHeader", ui.header and "yes" or "no")
    setVariable("showScan", ui.scan and "yes" or "no")
    setVariable("gagArt", gagArt and "yes" or "no")
    setVariable("zoom", tostring(ui.zoom))
    setVariable("panelAlpha", tostring(ui.alpha))
    setVariable("stripFrame", ui.stripFrame and "yes" or "no")
    setVariable("lens", glass.cur)
    setVariable("lensManual", tostring(glass.manual))
end

-- The frame fill is the client's, the lens fill is ours; both have to move
-- together or a "transparent" panel still has an opaque box behind it.
local function applyAlpha()
    if not ui.id then return end
    pcall(function()
        setWidgetAppearance(ui.id, { backgroundOpacity = ui.alpha })
    end)
end

-- The frame is the widget's own, not CSS, so a stylesheet rebuild does not
-- touch it: changing the lens left a green border and a green glow round a blue
-- panel until this put them back in step.
local function applyLens()
    if not ui.id then return end
    pcall(function()
        setWidgetAppearance(ui.id, {
            borderColor    = hue.EDGE,
            borderGradient = "linear-gradient(135deg," .. hue.EDGE .. ","
                .. glass.MID .. " 65%," .. glass.DARK .. ")",
            borderShadow   = "0 0 20px 3px rgba(" .. glass.RGB .. ",0.30)",
            backgroundColor = glass.DEEP,
        })
    end)
end

-- Drives zoom, not fontSize. fontSize is only the fallback declaration and the
-- container-query rule is emitted after it, so nudging fontSize moved a number
-- that nothing on screen was reading -- the buttons "worked" and did nothing.
-- Setting zoom suppresses the fit rule, which is what makes the size stick.
local function bumpFont(delta)
    local base = ui.zoom
    if base == 0 then base = ui.gridFont end
    ui.zoom = math.max(ui.FS_MIN, math.min(ui.FS_MAX, base + delta))
    saveSettings()
    safeRender()
end

local function makeWidget()
    ui.id = createWidget({
        type     = "html",
        name     = "scouter",
        title    = "Scouter",
        position = { x = 760, y = 90 },
        size     = { width = 460, height = 320 },
        scrollable = false,
        appearance = {
            showTitleBar        = false,
            autoHideSettingsCog = true,
        },
    })
    setWidgetAppearance(ui.id, {
        backgroundColor   = glass.DEEP,
        backgroundOpacity = ui.alpha,
        borderColor     = hue.EDGE,
        borderWidth     = 2,
        borderRadius    = 10,
        borderGradient  = "linear-gradient(135deg," .. hue.EDGE .. "," .. glass.MID .. " 65%," .. glass.DARK .. ")",
        borderShadow    = "0 0 20px 3px rgba(" .. glass.RGB .. ",0.30)",
    })

    -- registerWidgetEvent APPENDS, so a plugin reload would stack a second
    -- handler on the same widget and every click would fire twice. Dropping
    -- first is cheap; the call is wrapped because it is not in the API doc.
    pcall(function() unregisterWidgetEvent(ui.id, "action") end)
    pcall(function() unregisterWidgetEvent(ui.id, "resize") end)

    -- Seed the panel size so the first fit is against the real widget rather
    -- than the defaults. 3 and 4 are current width and height.
    local w0 = safeNum(widgetInfo(ui.id, 3))
    local h0 = safeNum(widgetInfo(ui.id, 4))
    if w0 and w0 > 0 then ui.w = w0 end
    if h0 and h0 > 0 then ui.h = h0 end

    registerWidgetEvent(ui.id, "resize", function(e)
        if type(e) ~= "table" then return end
        local w = safeNum(e.width)
        local h = safeNum(e.height)
        if w and w > 0 then ui.w = w end
        if h and h > 0 then ui.h = h end
        safeRender()
    end)

    pcall(function() unregisterWidgetEvent(ui.id, "submit") end)
    registerWidgetEvent(ui.id, "submit", function(data)
        if type(data) ~= "table" or type(data.formData) ~= "table" then return end

        local want = trimBoth(tostring(data.formData.freq or ""))
        if want == "" then return end

        -- Digits only, and checked here rather than left to the MUD: this is
        -- text from a field going out as a command.
        if want:match("^%d+$") == nil then
            echo(TAG .. "the channel is a number.", "#ff6666")
            return
        end

        send(CMD_FREQ .. want)
        send(CMD_SHOW)
    end)

    registerWidgetEvent(ui.id, "action", function(data)
        if type(data) ~= "table" then return end
        local act = tostring(data.action or "")

        -- The MUD owns the switch; this asks it to flip and then asks what it
        -- did, rather than keeping a second copy of the state here.
        if act == "comms" then
            send(CMD_SHOW)
            return
        end

        if act == "tx" then
            send(CMD_TX)
            send(CMD_SHOW)
            return
        elseif act == "rx" then
            send(CMD_RX)
            send(CMD_SHOW)
            return
        end

        if act == "scan" then
            ui.scan = not ui.scan
            saveSettings()
            safeRender()
        elseif act == "bigger" then
            bumpFont(1)
        elseif act == "smaller" then
            bumpFont(-1)
        elseif act == "close" then
            hideWidget(ui.id, true)
        end
    end)

    safeRender()
end

----------------------------------------------------------------------
-- the game's own scouter
--
-- The map itself is no longer read off the stream. 'config -supermap
-- -autocompass' stops the server drawing it, which is how the Mudlet package
-- this came from has always worked, and every bug that layer produced went
-- with it: an eaten who list, a double-printed mob line, and stray bars from
-- rows split across packets. GMCP is the only source now.
----------------------------------------------------------------------

-- false = gag it, true = it was ours but leave it in the scroll, nil = not ours.
-- One value with three states, because returning a pair invites nesting it into
-- a call and that is how the wrapped-pair trap gets in.
local function handleScan(clean)
    local at = clean:find(OUTLINE, 1, true)
    if at then
        -- Captures, not offsets. 'clean:sub(at + #ARROW)' advanced by zero in
        -- this runtime and kept the arrow on the front of the power reading,
        -- and the same arithmetic left the target empty. Real Lua computes
        -- both correctly, so the harness could never have caught it.
        local name = clean:match("around (.+) in your vision")
        if name then
            sweep.target = trimBoth(name)
        else
            sweep.target = trimBoth(clean:match("around (.+)$") or "")
        end
        sweep.power = "reading"
        sweep.broken = false
        sweep.pending = 4
        sweep.at = os.time()
        sweep.hits = sweep.hits + 1
        if debugOn then print(TAG .. "scan target <" .. sweep.target .. ">") end
        safeRender()
        return true
    end

    if sweep.pending <= 0 then return nil end

    local arrowAt = clean:find(ARROW, 1, true)
    if arrowAt then
        -- everything past the last '>' of the arrow
        local value = trimBoth(clean:match(">%s*(.*)$") or "")
        sweep.broken = value:find(MALFUNCTION, 1, true) ~= nil
        if sweep.broken then sweep.power = "malfunction" else sweep.power = value end
        sweep.pending = 0
        sweep.at = os.time()

        -- Published where another plugin can read it. This line is gagged --
        -- handleScan returns false for it so the art never reaches the scroll --
        -- and a line one plugin discards from onLine does not reach the next
        -- one either. So the panel that owns the parse hands the reading on
        -- rather than leaving anyone else to re-read a line that is gone.
        --
        -- '~' and not '|': a bare bar is alternation once a pattern is
        -- translated, and splitting on one has cost a release already.
        if not sweep.broken then
            pcall(function()
                setMapUserData("scouter.scan",
                    sweep.target .. "~" .. sweep.power .. "~" .. tostring(os.time()))
            end)
        end
        if debugOn then print(TAG .. "scan power <" .. sweep.power .. ">") end
        safeRender()
        if gagArt then return false end
        return true
    end

    -- The two art lines only get eaten while a scan is actually in flight, so a
    -- stray '_' anywhere else in the game is never touched.
    sweep.pending = sweep.pending - 1
    local bare = trimBoth(clean)
    if bare == "_" or bare == "(*)" then
        if gagArt then return false end
        return true
    end
    return nil
end

-- Notices that the server is still drawing the map and says so once. Detection
-- only: nothing is captured, nothing is gagged. A box exactly as wide as the
-- map GMCP described is the map, and the panel is already drawing it.
local function noticeDuplicateMap(clean)
    if hintShown or not curDef then return end
    if clean:sub(1, 1) ~= "+" or clean:sub(-1) ~= "+" then return end
    if cellLen(clean) ~= math.floor(numOr(curDef.width, 0)) then return end

    hintShown = true
    setVariable("hintShown", "yes")
    echo(TAG .. "the server is still drawing the map into your output.", hue.ALERT)
    echo(TAG .. "the panel has it -- run:  " .. CONFIG_HINT, hue.ALERT)
end

local function handleLine(sessionId, rawLine, cleanLine)
    local clean = dropAnsiDebris(trimRight(cleanLine))

    if handleScan(clean) == false then return false end
    if readComms(clean) then
        if glass.justChanged then
            glass.justChanged = false
            applyLens()
            saveSettings()
        end
        safeRender()
    end
    noticeDuplicateMap(clean)
    return nil
end

-- A fault in the scan handling must never stop a line reaching the terminal.
-- On a throw the line is shown untouched.
function onLine(sessionId, rawLine, cleanLine)
    local ok, verdict = pcall(handleLine, sessionId, rawLine, cleanLine)
    if not ok then
        lastError = tostring(verdict)
        return nil
    end
    return verdict
end

----------------------------------------------------------------------
-- diagnostics
--
-- Its own function, not a branch inside the command handler. Lua 5.1 allows a
-- function 60 upvalues and this block alone reaches for about forty of them;
-- inlined, it pushed the handler over the limit and the file stopped compiling.
----------------------------------------------------------------------

local function printDiag()
    print(TAG .. "instance=" .. INSTANCE
        .. " live=" .. tostring(getVariable("instance")))
    print(TAG .. "connected=" .. tostring(nego.connected)
        .. " negotiated=" .. tostring(nego.done)
        .. " attempts=" .. nego.tries .. "/" .. nego.MAX)
    if nego.firstPacketAfter then
        print(TAG .. "first packet arrived after attempt " .. nego.firstPacketAfter)
    end

    local defCount = 0
    for _ in pairs(defsById) do defCount = defCount + 1 end
    print(TAG .. "cached definitions=" .. defCount .. " currentMap=" .. tostring(currentMapId))

    local source = "none"
    if curSnap and curDef then source = "gmcp" end
    print(TAG .. "source=" .. source .. " gagArt=" .. tostring(gagArt))

    if curDef then
        print(TAG .. "definition: styles=" .. curDef.styleCount
            .. " w=" .. curDef.width .. " h=" .. curDef.height
            .. " title=" .. curDef.title)
    end
    if curSnap then
        print(TAG .. "snapshot: rows=" .. curSnap.rowN
            .. " runs=" .. curSnap.runTotal .. " seq=" .. tostring(curSnap.sequence))
    end

    print(TAG .. "scan target<" .. sweep.target .. "> power<" .. sweep.power
        .. "> broken=" .. tostring(sweep.broken) .. " pending=" .. sweep.pending
        .. " hits=" .. sweep.hits)
    print(TAG .. "lensSub=" .. glass.sub .. " debug=" .. tostring(debugOn))
    print(TAG .. "stripFrame=" .. tostring(ui.stripFrame) .. " inset=" .. ui.inset
        .. " drawn=" .. ui.cols .. "x" .. ui.rows)
    print(TAG .. "terminal font <" .. ui.family .. "> " .. ui.size .. "px"
        .. " -> bar=" .. barSize() .. " scan=" .. scanSize() .. " idle=" .. idleSize())
    print(TAG .. "panel=" .. ui.w .. "x" .. ui.h
        .. " grid=" .. ui.gridFont .. "px zoom=" .. ui.zoom
        .. " (fit range " .. ui.FS_MIN .. "-" .. ui.FS_MAX .. ")")
    print(TAG .. "widgetInfo w=" .. tostring(widgetInfo(ui.id, 3))
        .. " h=" .. tostring(widgetInfo(ui.id, 4)))
    print(TAG .. "lastError=" .. lastError)
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

function init()
    readTerminalFont()
    ui.fontSize = ui.size          -- the terminal's size is the default basis

    local fs = safeNum(getVariable("fontSize"))
    if fs and fs >= 6 and fs <= 32 then ui.fontSize = math.floor(fs) end
    if getVariable("showHeader") == "no" then ui.header = false end
    if getVariable("showScan") == "no" then ui.scan = false end
    if getVariable("gagArt") == "no" then gagArt = false end
    if getVariable("hintShown") == "yes" then hintShown = true end
    local z = safeNum(getVariable("zoom"))
    if z and z >= 0 and z <= ui.FS_MAX then ui.zoom = math.floor(z) end
    local pa = safeNum(getVariable("panelAlpha"))
    if pa and pa >= 0 and pa <= 1 then ui.alpha = pa end
    if getVariable("stripFrame") == "no" then ui.stripFrame = false end
    setLens(getVariable("lens"))
    glass.manual = (tostring(getVariable("lensManual")) == "true")

    makeWidget()

    -- Anything asking who owns the handshake gets an answer, whatever order the
    -- plugins happened to load in.
    on("dbi.gmcp.who", function() claimGmcp() end)

    -- The lens on your face, off char.equipment.
    --
    --   A scouter with a blue-crystal lens
    --   A scouter with a gold-crystal lens
    --
    -- The MUD names a scouter by its lens and even colours the words, and
    -- those are the same handful of colours this panel already has -- which
    -- is what the note by glass.ALL has been waiting for.
    --
    -- EQUIPMENT only, never inventory. A spare scouter in a bag is not what
    -- you are looking through, and tinting the panel from one would be a
    -- readout of the wrong instrument.
    --
    -- A lens word nobody has a colour for changes NOTHING. There is one
    -- sample of this format per colour and no list of what exists, so an
    -- unknown word means the palette has not caught up yet -- leaving the
    -- panel as it was is the honest answer, and guessing a colour from a name
    -- is how 'a-a-a.png' happened in Portrait.
    local function onGear(data)
        pcall(function()
            if glass.manual then return end
            local box = data
            if type(box) == "table" and type(box.equipment) == "table" then
                box = box.equipment
            end
            if type(box) ~= "table" then return end
            local arr, n = normArray(box.items)
            for i = 1, n do
                local it = arr[i]
                if type(it) == "table" and type(it.name) == "string" then
                    local low = it.name:lower()
                    if low:find("scouter", 1, true) ~= nil then
                        -- '<colour>-crystal lens'. %S+ rather than %a+: a
                        -- letter class inside a bracket does not survive this
                        -- runtime's pattern translation.
                        local word = low:match("(%S+)%-crystal")
                        if type(word) == "string" and glass.ALL[word] ~= nil
                            and word ~= glass.cur then
                            if setLens(word) then
                                saveSettings()
                                applyLens()
                                safeRender()
                                echo(TAG .. "lens: " .. word
                                    .. ", off the scouter you are wearing. "
                                    .. "'dbscout lens <colour>' to override.",
                                    hue.ALERT)
                            end
                        end
                        return
                    end
                end
            end
        end)
    end
    onGMCPUpdate("char.equipment", onGear)
    onGMCPUpdate("Char.Equipment", onGear)

    onGMCPUpdate("Map.Definition", function(data)
        local ok, err = pcall(function() acceptDefinition(data) end)
        if not ok then print(TAG .. "definition error: " .. tostring(err)) end
    end)

    onGMCPUpdate("Map.Snapshot", function(data)
        local ok, err = pcall(function() acceptSnapshot(data) end)
        if not ok then print(TAG .. "snapshot error: " .. tostring(err)) end
    end)

    -- A reload mid-session never sees onConnect, so arm here too. The tick
    -- still holds everything back until the first scheduled slot.
    nego.connected = true
    setVariable("instance", INSTANCE)
    armNegotiation("plugin load")

    tickTimer = addTimer(1000, function()
        if getVariable("instance") ~= INSTANCE then
            if tickTimer then removeTimer(tickTimer) end
            return
        end
        local ok, err = pcall(negotiationTick)
        if not ok then print(TAG .. "negotiation error: " .. tostring(err)) end
    end, true)

    registerCommand("dbscout", function(args)
        local cmd = tostring(args or ""):lower()

        if cmd == "enable" then
            armNegotiation("manual")
            sendSupports()
            echo(TAG .. "asked the server for the Map module.", hue.ALERT)

        elseif cmd == "hello" then
            -- Deliberately separate from 'enable'. Hello is once per session;
            -- this is the escape hatch for when you want to force another.
            sendHello(true)   -- explicit command: always send
            echo(TAG .. "Core.Hello sent as " .. nego.CLIENT .. " " .. nego.CLIENT_VERSION .. ".", hue.ALERT)

        elseif cmd == "show" then
            showWidget(ui.id, true)
            safeRender()
        elseif cmd == "hide" then
            hideWidget(ui.id, true)
        elseif cmd == "redraw" then
            safeRender()

        elseif cmd == "scan" then
            ui.scan = not ui.scan
            saveSettings()
            safeRender()
        elseif cmd == "header" then
            ui.header = not ui.header
            saveSettings()
            safeRender()

        elseif cmd:sub(1, 5) == "zoom " then
            local spec = cmd:sub(6)
            if spec == "fit" then
                ui.zoom = 0
                echo(TAG .. "fitting to the panel.", hue.ALERT)
            else
                local n = safeNum(spec)
                if n then
                    ui.zoom = math.max(ui.FS_MIN, math.min(ui.FS_MAX, math.floor(n)))
                    echo(TAG .. "locked at " .. ui.zoom .. "px.", hue.ALERT)
                else
                    echo(TAG .. "zoom: fit, or " .. ui.FS_MIN .. "-" .. ui.FS_MAX, "#ff6666")
                    return
                end
            end
            saveSettings()
            safeRender()

        elseif cmd:sub(1, 8) == "opacity " then
            local n = safeNum(cmd:sub(9))
            if not n or n < 0 or n > 100 then
                echo(TAG .. "opacity takes 0-100 (0 = see straight through)", "#ff6666")
                return
            end
            ui.alpha = math.floor(n) / 100
            saveSettings()
            applyAlpha()
            safeRender()
            echo(TAG .. "opacity " .. math.floor(n) .. "%", hue.ALERT)

        elseif cmd == "debug" then
            debugOn = not debugOn
            echo(TAG .. "debug " .. tostring(debugOn), hue.ALERT)

        elseif cmd == "frame" then
            ui.stripFrame = not ui.stripFrame
            saveSettings()
            safeRender()
            if ui.stripFrame then echo(TAG .. "server frame stripped.", hue.ALERT)
            else echo(TAG .. "server frame kept.", hue.ALERT) end

        elseif cmd == "gag" then
            gagArt = not gagArt
            saveSettings()
            if gagArt then echo(TAG .. "scouter art gagged.", hue.ALERT)
            else echo(TAG .. "scouter art left in the terminal.", hue.ALERT) end

        elseif cmd:sub(1, 5) == "font " then
            local spec = cmd:sub(6)
            if spec == "+" then
                bumpFont(1)
            elseif spec == "-" then
                bumpFont(-1)
            else
                local n = safeNum(spec)
                if n then
                    ui.fontSize = math.max(6, math.min(32, math.floor(n)))
                    saveSettings()
                    safeRender()
                else
                    echo(TAG .. "font: +, - or 6-32", "#ff6666")
                    return
                end
            end
            echo(TAG .. "font size " .. ui.fontSize, hue.ALERT)

        elseif cmd == "diag" then
            printDiag()

        elseif cmd == "raw" then
            print(TAG .. "--- Map.Definition ---")
            local d = getGMCPData("Map.Definition")
            if d then tprint(d) else print("(nil)") end
            print(TAG .. "--- Map.Snapshot ---")
            local s = getGMCPData("Map.Snapshot")
            if s then tprint(s) else print("(nil)") end

        elseif cmd == "lens" or cmd == "colour" or cmd == "color" then
            local names = {}
            for name in pairs(glass.ALL) do names[#names + 1] = name end
            table.sort(names)
            local how = "following the scouter you are wearing"
            if glass.manual then how = "held by hand" end
            echo(TAG .. "lens: " .. glass.cur .. " -- " .. how, hue.ALERT)
            echo("         dbscout lens " .. table.concat(names, " | ")
                .. " | auto", hue.ALERT)

        elseif cmd:sub(1, 5) == "lens " or cmd:sub(1, 7) == "colour "
            or cmd:sub(1, 6) == "color " then
            local want = trimRight(cmd:match("^%S+%s+(.*)$") or "")
            if want:lower() == "auto" then
                glass.manual = false
                saveSettings()
                echo(TAG .. "lens follows the scouter you are wearing.",
                    hue.ALERT)
                return
            end
            if not setLens(want) then
                echo(TAG .. "no lens called '" .. tostring(want)
                    .. "'. 'dbscout lens' lists them.", "#ff6666")
                return
            end
            -- Chosen by hand, so equipment stops changing it.
            glass.manual = true
            saveSettings()
            applyLens()
            safeRender()
            echo(TAG .. "lens: " .. glass.cur .. " (held -- 'dbscout lens "
                .. "auto' to follow the scouter again).", hue.ALERT)

        elseif cmd == "comms" then
            -- The panel fills itself in from the reply; this is just the ask.
            send(CMD_SHOW)
            echo(TAG .. "asked the scouter what it is set to.", hue.ALERT)
        elseif cmd:sub(1, 3) == "api" then
            -- The documented API is a fraction of what is bound. Enumerating
            -- _G is the only way to know what this build actually has.
            local filter = trimRight(cmd:sub(5))
            local ok, names = pcall(function()
                local found = {}
                for k, v in pairs(_G) do
                    if type(v) == "function" then
                        local key = tostring(k)
                        if filter == "" or key:lower():find(filter, 1, true) then
                            found[#found + 1] = key
                        end
                    end
                end
                table.sort(found)
                return found
            end)

            if not ok or type(names) ~= "table" then
                print(TAG .. "_G is not enumerable in this scope")
            else
                print(TAG .. "" .. #names .. " function(s) matching '" .. filter .. "'")
                local i = 1
                while i <= #names do
                    print("  " .. names[i])
                    i = i + 1
                end
            end

        elseif cmd == "packages" then
            print(TAG .. "--- every GMCP package the client holds ---")
            local all = getAllGMCPData()
            if type(all) == "table" then
                for k in pairs(all) do print("  " .. tostring(k)) end
            else
                print("(none)")
            end

        else
            echo(TAG .. "dbscout enable | show | hide | redraw", hue.ALERT)
            echo("         dbscout font +|-|<6-32> | header | scan", hue.ALERT)
            echo("         dbscout comms  - read TX, RCV and the channel back", hue.ALERT)
            echo("         dbscout lens <colour>  - what shade the panel glows", hue.ALERT)
            echo("         dbscout zoom fit|<6-34>  - fill the panel, or lock a size", hue.ALERT)
            echo("         dbscout opacity <0-100>  - 0 to read the output behind it", hue.ALERT)
            echo("         dbscout frame  - keep or drop the server's own border", hue.ALERT)
            echo("         dbscout gag    - keep the scouter art out of the terminal", hue.ALERT)
            echo("         dbscout diag | raw | packages", hue.ALERT)
        end
    end, "Scouter map control")
end

function onConnect(sessionId)
    nego.connected = true
    nego.helloSent = false        -- a new session is a new handshake
    curSnap = nil
    curDef = nil
    -- The server's sequence counter restarts with the session. Keeping the old
    -- high-water marks would mark every fresh snapshot stale and freeze the map.
    lastSeqById = {}
    pendingById = {}
    armNegotiation("connect")
    safeRender()
end

function onDisconnect(sessionId)
    nego.connected = false
    nego.done = false
end

function cleanup() end
