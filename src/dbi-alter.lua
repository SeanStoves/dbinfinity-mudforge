plugin = {
    id          = "dbi-alter",
    name        = "DB Infinity Map Alterer",
    version     = "2026.08.18.000",
    author      = "Solao",
    description = "Move ranges of rooms on the map, by hand, with an undo.",
    settings    = { saveState = false },
}

-- Straightening a map that the automapper laid out from exits alone.
--
-- The client's own nudge is drag-and-drop on ONE room. Measured on a room
-- nudged by hand: it comes back with new coordinates and NO room user data,
-- so the client writes x/y straight and keeps no offset. That is fine for one
-- room and useless for a corridor of twelve, which is what a hand-drawn area
-- actually needs.
--
-- This does the same write -- updateMapRoom(vnum, { x, y, z }) -- across a
-- range, from a panel.
--
-- SAVES NOTHING. No settings, no store, no room user data. The map edits are
-- the whole product; anything else this kept would be state to go stale. The
-- undo lives in memory and dies with the session, which is the honest scope
-- for it: it can put back what THIS session moved and makes no claim about
-- anything else.
--
-- Public, and nothing here is Dragonball-specific beyond the name. It is the
-- client's own map API and works on any world.

local VERSION = plugin.version
local TAG = "[DBI Alter " .. VERSION .. "] "

-- No instance token here, unlike the other plugins in this set. That exists
-- to retire an older load's TIMERS, and this books none: it acts on clicks and
-- typed commands and does nothing between them.

local INK      = "#e6ecf5"
local INK_DIM  = "#8b95a6"
local PANEL_BG = "#0a0c11"
local GOLD     = "#e8b45c"
local RULE     = "#242a36"
local GOOD     = "#7ee787"
local BAD      = "#ff6b6b"

local ui = { id = nil, open = false }
local lastError = "none"

-- What is being typed, kept apart from what has been applied.
--
-- A panel that rebuilds its own content replaces the input and takes the caret
-- with it, so nothing renders on keyup: the value is captured there and used
-- when a button is pressed.
local edit = { from = "", to = "", far = "1" }

-- What this session moved, newest last. In memory only -- see the header.
local undo = {}

----------------------------------------------------------------------
-- value hygiene
----------------------------------------------------------------------

-- A number, or nil. Whitelist rather than blacklist: tonumber here is
-- JavaScript's Number(), and Number("") is 0 rather than nil, so an empty
-- capture becomes a confident zero if it is not refused first.
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

local function escapeHtml(s)
    local out = tostring(s or "")
    out = out:gsub("&", "&amp;")
    out = out:gsub("<", "&lt;")
    out = out:gsub(">", "&gt;")
    out = out:gsub('"', "&quot;")
    return out
end

-- An array that crossed the boundary, put back in order. They do not arrive
-- reliably 1-indexed: 0-indexed and object-with-numeric-keys have both turned
-- up, and ipairs walks none of the first kind.
--
-- ALWAYS capture both values. 'local a = normArray(x)' leaves a holding the
-- wrapped pair, and every a[i] silently yields nothing.
local function normArray(v)
    local out, n = {}, 0
    if type(v) ~= "table" then return out, 0 end
    if v[0] ~= nil then
        local i = 0
        while v[i] ~= nil do
            n = n + 1
            out[n] = v[i]
            i = i + 1
        end
        if n > 0 then return out, n end
    end
    for _, item in ipairs(v) do
        n = n + 1
        out[n] = item
    end
    if n > 0 then return out, n end
    for k, item in pairs(v) do
        if safeNum(k) ~= nil then
            n = n + 1
            out[n] = item
        end
    end
    return out, n
end

-- The mapper calls are globals the client installs. Named directly, so one
-- that is absent is a nil call rather than a missing feature.
local function mcall(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil end
    local ok, res = pcall(fn, ...)
    if not ok then
        lastError = name .. ": " .. tostring(res)
        return nil
    end
    return res
end

local function say(text, colour)
    pcall(function() echo(TAG .. text, colour or INK) end)
end

----------------------------------------------------------------------
-- the map
----------------------------------------------------------------------

-- Which way a square moves. North is UP, so its y is negative -- the same
-- convention the client draws with.
local STEP = {
    n  = {  0, -1,  0 },   s  = {  0,  1,  0 },
    e  = {  1,  0,  0 },   w  = { -1,  0,  0 },
    ne = {  1, -1,  0 },   nw = { -1, -1,  0 },
    se = {  1,  1,  0 },   sw = { -1,  1,  0 },
    u  = {  0,  0,  1 },   d  = {  0,  0, -1 },
}

local ORDER = { "n", "ne", "e", "se", "s", "sw", "w", "nw", "u", "d" }

local LONG = {
    north = "n", south = "s", east = "e", west = "w",
    northeast = "ne", northwest = "nw",
    southeast = "se", southwest = "sw",
    up = "u", down = "d",
}

local function hereVnum()
    return safeNum(mcall("getPlayerRoom"))
end

local function areaHere()
    local at = hereVnum()
    if at == nil then return "" end
    local r = mcall("getMapRoom", at)
    if type(r) ~= "table" then return "" end
    local a = r.area
    if type(a) ~= "string" then a = r.zone end
    if type(a) ~= "string" then return "" end
    return a
end

-- Every room of this area inside the range.
--
-- Bounded by AREA as well as by vnum, and that is not belt-and-braces: a vnum
-- range that strays into the next block drags somebody else's rooms sideways,
-- and there is no way to see that happen or to work out afterwards what moved.
local function roomsIn(fromV, toV)
    local area = areaHere()
    if area == "" then return {}, 0, "" end
    local arr, n = normArray(mcall("getAreaRooms", area))
    local out, k = {}, 0
    for i = 1, n do
        local v = safeNum(arr[i])
        if v ~= nil and v >= fromV and v <= toV then
            k = k + 1
            out[k] = v
        end
    end
    return out, k, area
end

-- Move a range, and remember enough to put it back.
local function nudge(fromV, toV, dir, far)
    local step = STEP[dir]
    if step == nil then
        say("no direction called '" .. tostring(dir) .. "'.", BAD)
        return
    end

    -- Clamped. This is straightening a map by hand; anything past a few
    -- squares is a mistake with a long walk back.
    local n = math.floor(math.max(1, math.min(safeNum(far) or 1, 8)))

    local list, k, area = roomsIn(fromV, toV)
    if area == "" then
        say("no area yet -- walk somewhere first.", BAD)
        return
    end
    if k == 0 then
        say("no rooms of " .. area .. " between " .. fromV .. " and " .. toV
            .. ".", BAD)
        return
    end

    local dx, dy, dz = step[1] * n, step[2] * n, step[3] * n
    local moved, done = 0, {}
    for i = 1, k do
        local v = list[i]
        local r = mcall("getMapRoom", v)
        if type(r) == "table" then
            local ok = mcall("updateMapRoom", v, {
                x = (safeNum(r.x) or 0) + dx,
                y = (safeNum(r.y) or 0) + dy,
                z = (safeNum(r.z) or 0) + dz,
            })
            if ok then
                moved = moved + 1
                done[moved] = v
            end
        end
    end

    if moved == 0 then
        say("nothing moved.", BAD)
        return
    end

    undo[#undo + 1] = { rooms = done, n = moved, dx = dx, dy = dy, dz = dz,
                        dir = dir, far = n, area = area,
                        from = fromV, to = toV }
    say(moved .. " room(s) in " .. area .. " moved " .. n .. " " .. dir
        .. ". Undo puts them back.", GOOD)
end

local function undoLast()
    local last = undo[#undo]
    if last == nil then
        say("nothing to undo this session.", BAD)
        return
    end

    local back = 0
    for i = 1, last.n do
        local v = last.rooms[i]
        local r = mcall("getMapRoom", v)
        if type(r) == "table" then
            local ok = mcall("updateMapRoom", v, {
                x = (safeNum(r.x) or 0) - last.dx,
                y = (safeNum(r.y) or 0) - last.dy,
                z = (safeNum(r.z) or 0) - last.dz,
            })
            if ok then back = back + 1 end
        end
    end

    -- Rebuilt rather than shortened with table.remove: '#' does not follow a
    -- remove on a table built by explicit index here, so the next append can
    -- write past the end and leave a hole no ipairs walk can see.
    local kept, kn = {}, 0
    for i = 1, #undo - 1 do
        kn = kn + 1
        kept[kn] = undo[i]
    end
    undo = kept

    say(back .. " room(s) put back " .. last.far .. " " .. last.dir .. ".",
        GOOD)
end

----------------------------------------------------------------------
-- the panel
----------------------------------------------------------------------

local function sheet()
    local t = {}
    local function add(s) t[#t + 1] = s end

    -- One <style> element. Inline colour is stripped by the sanitiser, so
    -- everything that has to be coloured is a class.
    add("<style>")
    add(".dbi-alt{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;")
    add("color:" .. INK .. ";padding:6px 8px;}")
    add(".dbi-alt .hd{color:" .. GOLD .. ";letter-spacing:.06em;")
    add("border-bottom:1px solid " .. RULE .. ";padding-bottom:4px;margin-bottom:6px;}")
    add(".dbi-alt .row{display:flex;align-items:center;gap:6px;margin:4px 0;}")
    add(".dbi-alt .k{color:" .. INK_DIM .. ";flex:0 0 auto;}")
    add(".dbi-alt input{background:#11151d;color:" .. INK .. ";")
    add("border:1px solid " .. RULE .. ";border-radius:2px;padding:1px 4px;")
    add("width:5.5em;font:inherit;}")
    add(".dbi-alt .g{display:flex;flex-wrap:wrap;gap:3px;margin:4px 0;}")
    add(".dbi-alt .b{border:1px solid " .. RULE .. ";border-radius:2px;")
    add("padding:2px 7px;cursor:pointer;user-select:none;color:" .. INK .. ";}")
    add(".dbi-alt .b:hover{border-color:" .. GOLD .. ";color:" .. GOLD .. ";}")
    add(".dbi-alt .b.warn{color:" .. BAD .. ";}")
    add(".dbi-alt .note{color:" .. INK_DIM .. ";margin-top:6px;line-height:1.4;}")
    add("</style>")

    add('<div class="dbi-alt">')
    add('<div class="hd">MAP ALTERER</div>')

    local area = areaHere()
    if area == "" then area = "(nowhere yet)" end
    add('<div class="row"><span class="k">area</span><span>'
        .. escapeHtml(area) .. "</span></div>")

    -- value="..." re-emitted every render from what is being typed, because a
    -- repaint replaces the input and would otherwise wipe the field.
    add('<form class="row" data-mud-action="apply">')
    add('<span class="k">rooms</span>')
    add('<input id="altfrom" type="text" placeholder="from" value="'
        .. escapeHtml(edit.from) .. '">')
    add('<input id="altto" type="text" placeholder="to" value="'
        .. escapeHtml(edit.to) .. '">')
    add('<span class="k">by</span>')
    add('<input id="altfar" type="text" placeholder="1" value="'
        .. escapeHtml(edit.far) .. '">')
    add("</form>")

    add('<div class="g">')
    for _, d in ipairs(ORDER) do
        add('<span class="b" data-mud-action="go" data-mud-data="' .. d
            .. '">' .. d .. "</span>")
    end
    add("</div>")

    add('<div class="g">')
    add('<span class="b warn" data-mud-action="undo">undo last</span>')
    add('<span class="b" data-mud-action="close">close</span>')
    add("</div>")

    local pending = #undo
    add('<div class="note">' .. pending .. " move(s) undoable this session. ")
    add("Nothing is saved: the undo goes when the client does.</div>")
    add("</div>")
    return table.concat(t)
end

local function render()
    if ui.id == nil then return end
    pcall(function() setWidgetProperty(ui.id, "content", sheet()) end)
end

-- Rendering replaces the inputs and takes the caret with them, so a repaint
-- while someone is typing loses what they typed. Nothing here repaints off
-- anything but a click.
local function safeRender()
    local ok, err = pcall(render)
    if not ok then lastError = "render: " .. tostring(err) end
end

----------------------------------------------------------------------
-- commands
----------------------------------------------------------------------

local function help()
    say("dbalter                 show the panel", GOLD)
    say("        dbalter hide            hide it", INK_DIM)
    say("        dbalter <a>-<b> <dir> [n]   move a range", INK_DIM)
    say("        dbalter undo            put the last move back", INK_DIM)
    say("        dbalter diag            what it can see", INK_DIM)
end

local function runCmd(cmd)
    local low = trimBoth(tostring(cmd or "")):lower()

    if low == "" or low == "show" then
        -- force = true: this is a typed command, so it overrides the
        -- user-hidden preference the plugin manager's hide button sets.
        -- Without it 'show' does nothing at all once that has been used.
        pcall(function() showWidget(ui.id, true) end)
        ui.open = true
        safeRender()
        return
    end

    if low == "hide" then
        pcall(function() hideWidget(ui.id, true) end)
        ui.open = false
        return
    end

    if low == "undo" then
        undoLast()
        safeRender()
        return
    end

    if low == "diag" then
        say("here=" .. tostring(hereVnum()) .. " area=" .. areaHere(), GOLD)
        say("        undo stack=" .. #undo .. "  lastError=" .. lastError,
            INK_DIM)
        local calls = {}
        for _, n in ipairs({ "getPlayerRoom", "getMapRoom", "getAreaRooms",
                             "updateMapRoom" }) do
            calls[#calls + 1] = n .. "=" .. type(_G[n])
        end
        say("        " .. table.concat(calls, "  "), INK_DIM)
        return
    end

    -- '<from>-<to> <dir> [n]'. Two explicit number captures rather than one
    -- pattern holding a character range: a range inside a class does not
    -- survive this runtime's pattern translation, and %d does.
    local a, b, tail = low:match("^(%d+)%s*%-%s*(%d+)%s*(.*)$")
    local fromV, toV = safeNum(a), safeNum(b)
    if fromV == nil or toV == nil then
        help()
        return
    end
    if toV < fromV then fromV, toV = toV, fromV end

    local word, far = trimBoth(tail):match("^(%S+)%s*(%d*)$")
    if type(word) ~= "string" then
        help()
        return
    end
    local dir = LONG[word] or word
    nudge(fromV, toV, dir, safeNum(far))
    safeRender()
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

function init()
    ui.id = createWidget({
        type     = "html",
        name     = "alterer",
        title    = "Map Alterer",
        position = { x = 40, y = 520 },
        size     = { width = 300, height = 250 },
        scrollable = false,
        appearance = { showTitleBar = true, autoHideSettingsCog = true },
    })
    pcall(function()
        setWidgetAppearance(ui.id, {
            backgroundColor = PANEL_BG,
            borderColor     = GOLD,
            borderWidth     = 2,
            borderRadius    = 6,
        })
    end)

    -- registerWidgetEvent APPENDS, so a reload would stack a second handler
    -- and every click would fire twice.
    pcall(function() unregisterWidgetEvent(ui.id, "action") end)
    pcall(function() unregisterWidgetEvent(ui.id, "keyup") end)
    pcall(function() unregisterWidgetEvent(ui.id, "submit") end)

    -- Captured on keyup and used on a click. NOT rendered here: rebuilding the
    -- content replaces the input and takes the focus with it, so a url long
    -- enough to be worth typing could not be typed at all.
    local function grab(e)
        if type(e) ~= "table" then return end
        local id = tostring(e.targetId or "")
        local val = e.targetValue
        if type(val) ~= "string" then return end
        if id == "altfrom" then edit.from = val
        elseif id == "altto" then edit.to = val
        elseif id == "altfar" then edit.far = val end
    end
    pcall(function() registerWidgetEvent(ui.id, "keyup", grab) end)
    pcall(function() registerWidgetEvent(ui.id, "submit", grab) end)

    pcall(function()
        registerWidgetEvent(ui.id, "action", function(e)
            if type(e) ~= "table" then return end
            local act = tostring(e.action or "")

            if act == "close" then
                pcall(function() hideWidget(ui.id, true) end)
                ui.open = false
                return
            end

            if act == "undo" then
                undoLast()
                safeRender()
                return
            end

            if act == "go" then
                local dir = tostring(e.data or "")
                local fromV = safeNum(trimBoth(edit.from))
                local toV = safeNum(trimBoth(edit.to))
                if fromV == nil or toV == nil then
                    say("give a from and a to first.", BAD)
                    return
                end
                if toV < fromV then fromV, toV = toV, fromV end
                nudge(fromV, toV, dir, safeNum(trimBoth(edit.far)))
                safeRender()
                return
            end
        end)
    end)

    registerCommand("dbalter", runCmd,
        "Move ranges of rooms on the map, with an undo")

    safeRender()
    print(TAG .. "ready. 'dbalter' for the panel. Nothing is saved.")
end

function onLine(sessionId, rawLine, cleanLine) return nil end
function onConnect(sessionId) end
function onDisconnect(sessionId) end

-- Nothing to flush. Every write went straight into the map when it happened,
-- and the map is the client's to persist -- which is the point of keeping it
-- there rather than in a store this plugin would have to own.
function cleanup()
    if ui.id ~= nil then
        pcall(function() unregisterWidgetEvent(ui.id, "action") end)
        pcall(function() unregisterWidgetEvent(ui.id, "keyup") end)
        pcall(function() unregisterWidgetEvent(ui.id, "submit") end)
    end
end
