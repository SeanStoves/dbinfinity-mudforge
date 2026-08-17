plugin = {
    id          = "dbi-chat",
    name        = "DB Infinity Chat",
    version     = "2026.08.17.001",
    author      = "Solao",
    description = "Tabbed chat for Dragonball Infinity, with user-defined captures.",
    settings    = { saveState = true },
}

-- The routing below -- which line belongs to which channel -- is Bo's research
-- from the DBZ Chat plugin, carried over wholesale. Everything else is new:
-- HTML rather than canvas, so wrapping, scrolling and selection come from the
-- browser instead of from eighty lines of hand-rolled font arithmetic, and
-- captures can be added at runtime rather than living in the source.

local VERSION = "0.4.3"
local TAG = "[DBI Chat " .. VERSION .. "] "

-- The client does not reliably tear down a previous load's timers, so each
-- load stamps a token and an older tick retires itself.
local INSTANCE = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))

local MAX_LINES = 400
local IMG_BASE = "https://raw.githubusercontent.com/SeanStoves/dbinfinity-mudforge/HEAD/img"

local INK      = "#e6ecf5"
local INK_DIM  = "#7d8797"
local PANEL_BG = "#0a0c11"
local PANEL_RGB = "10,12,17"
local GOLD     = "#e8b45c"
local GOLD_DIM = "#8a6a2a"
local BEVEL    = "rgba(255,255,255,0.10)"

local FONT_FALLBACK = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"
local termFamily = ""
local termSize = 13

-- Chat is read at a different distance from the map: it is a column of prose in
-- the corner of the screen, not a grid you glance at. Scouter has had its own
-- size control since the start and this is the same one. Zero means follow the
-- terminal, which stays the default.
local FS_MIN, FS_MAX = 8, 28
local zoom = 0

local widget = nil
local view = "chat"           -- or "settings"
local activeId = "all"
local panelAlpha = 1
local backdrop = 0.10         -- how much of the image shows through
local bgUrl = ""              -- empty means the one that ships with the plugin
local masterGag = false
local lastError = "none"

local buffers = {}
local unread = {}
local usedColors = {}
local triggerIds = {}
local trigN = 0

----------------------------------------------------------------------
-- value hygiene
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

-- An unset table field arrives as `undefined`: truthy, and not equal to nil.
local function has(v)
    local t = type(v)
    if t == "number" then return true end
    if t == "string" then return v ~= "" and v ~= "undefined" end
    return false
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

-- Anything that could close a CSS url("...") and start a new declaration.
-- Checked with a plain find rather than a pattern: plain means the runtime does
-- no translation at all, which is the one way to be sure about a check that
-- exists to stop injection.
local URL_BAD = { '"', "'", "(", ")", "<", ">", ";", "\\", " ", "\t" }

-- Rejects rather than repairs. A URL that needs cleaning up before it is safe
-- to use is a URL worth refusing, and the fallback is the bundled image.
local function safeUrl(s)
    local u = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if u == "" then return "" end

    local low = u:lower()
    if low:sub(1, 8) ~= "https://" and low:sub(1, 7) ~= "http://" then return "" end

    for _, ch in ipairs(URL_BAD) do
        if u:find(ch, 1, true) then return "" end
    end
    return u
end

-- '%w' rather than a character range: a range inside a class does not survive
-- this runtime's pattern translation, and '%a' cannot be used in one either.
local function slug(s)
    local out = tostring(s or ""):lower():gsub("[^%w]+", "-")
    out = out:gsub("^%-+", ""):gsub("%-+$", "")
    return out
end

-- ALWAYS capture both values. `local a = normArray(x)` leaves a holding the
-- wrapped pair here, and every a[i] silently yields nothing.
local function normArray(v)
    local out = {}
    local n = 0
    if type(v) ~= "table" then return out, 0 end
    for _, item in ipairs(v) do
        n = n + 1
        out[n] = item
    end
    return out, n
end

local function callable(name)
    local ok, fn = pcall(function() return _G[name] end)
    if ok and type(fn) == "function" then return fn end
    return nil
end

----------------------------------------------------------------------
-- channels
----------------------------------------------------------------------

local CH_ORDER = {}
local CH_N = 0
local CH_LABEL = {}
local CH_COLOR = {}
local CH_ON = {}
local CH_BUILTIN = {}

local function defChannel(id, label, color, builtin)
    if CH_LABEL[id] == nil then
        CH_N = CH_N + 1
        CH_ORDER[CH_N] = id
    end
    CH_LABEL[id] = label
    CH_COLOR[id] = color
    if CH_ON[id] == nil then CH_ON[id] = true end
    CH_BUILTIN[id] = builtin and true or false
end

defChannel("all",      "All",   "#cfd6e4", true)
defChannel("personal", "Pers",  "#ffdd66", true)
defChannel("ooc",      "OOC",   "#66ccff", true)
defChannel("chat",     "Chat",  "#66ffcc", true)
defChannel("racetalk", "Race",  "#ff88ff", true)
defChannel("auction",  "Auct",  "#ffaa44", true)
defChannel("hardcore", "Hard",  "#ff6666", true)
defChannel("event",    "Event", "#88ff88", true)
defChannel("custom",   "Cust",  "#bbbbbb", true)

local function isChannel(id) return CH_LABEL[id] ~= nil end
local function channelOn(id) return CH_ON[id] == true end

local function visibleTabs()
    local vis, n = {}, 0
    for i = 1, CH_N do
        local id = CH_ORDER[i]
        if id and CH_ON[id] == true then
            n = n + 1
            vis[n] = id
        end
    end
    return vis, n
end

local function firstVisible()
    local vis, n = visibleTabs()
    if n > 0 then return vis[1] end
    return "all"
end

----------------------------------------------------------------------
-- routing
--
-- Bo's patterns, unchanged. 'rx' means the matcher is JavaScript regex rather
-- than a plain substring. Mode is widget (route and hide nothing), both, or off.
----------------------------------------------------------------------

local RULE_ORDER = {}
local R_N = 0
local RULE = {}

local function defRoute(name, ch, rx, pat, builtin)
    if RULE[name] == nil then
        R_N = R_N + 1
        RULE_ORDER[R_N] = name
    end
    -- 'both' rather than 'widget': a channel that vanishes from the terminal
    -- the moment it is captured reads as lost mail. Show it in both places and
    -- let the master gag be the thing that quiets the scroll.
    RULE[name] = { ch = ch, rx = rx, pat = pat, mode = "both", builtin = builtin }
end

defRoute("yousay",    "personal", false, "You say", true)
defRoute("youtell",   "personal", false, "You tell", true)
defRoute("yell",      "personal", false, "YELL", true)
defRoute("says",      "personal", true,  "^(?:\\(\\w+\\) )?.+ says?,? ['\"].+['\"]$", true)
defRoute("yells",     "personal", true,  "^(?:\\(\\w+\\) )?.+ YELLs? '.+'$", true)
defRoute("tells",     "personal", true,  "^.+ tells? (?:you|\\w+) '.+'$", true)

defRoute("ooc",       "ooc", false, "-<OOC>-", true)
defRoute("music",     "ooc", false, "[MuSiC]", true)
defRoute("fos",       "ooc", false, "[FreedomOfSpeech]", true)
defRoute("wartalk",   "ooc", false, "{WARTALK", true)
defRoute("question",  "ooc", false, "(QUESTION)", true)
defRoute("roleplay",  "ooc", false, "[RolePlay", true)
defRoute("admin",     "ooc", false, "[ADMIN", true)

defRoute("chat",      "chat", false, "[CHAT", true)

defRoute("race",      "racetalk", true,  ">>.+<<.+:", true)
defRoute("kanassian", "racetalk", false, "*)<Kanassian>(*", true)
defRoute("konatsu",   "racetalk", false, "-<<Konatsu>>-", true)
defRoute("vinian",    "racetalk", false, ">-(Vinian)-<", true)
defRoute("yondai",    "racetalk", false, "/=Yondai=\\", true)

defRoute("auction",   "auction", false, "Auction:", true)
defRoute("traffic",   "auction", false, "[TRAFFIC", true)

defRoute("hardcore",  "hardcore", false, "[HARDCORE]", true)

defRoute("infinity",  "event", false, "[Infinity]", true)
defRoute("trivia",    "event", false, "/TRIVIA//", true)
defRoute("huntstart", "event", false, "has been released hunt it!!", true)
defRoute("huntend",   "event", false, "has defeated the monster and ended the hunt!!!", true)
defRoute("htc",       "event", false, "Your time in the Hyperbolic Time Chamber is almost up!", true)
defRoute("luck",      "event", false, "luck has changed today", true)
defRoute("prof",      "event", false, "You are now proficient with", true)

defRoute("misc",      "custom", false, "-=[Misc", true)
defRoute("khonsuon",  "custom", false, "This spar has activated Khonsubonus", true)
defRoute("khonsuoff", "custom", false, "Your KHONSUBONUS has expired", true)
defRoute("note",      "custom", false, "A new note has been posted", true)

----------------------------------------------------------------------
-- persistence
--
-- saveTable rather than setVariable: setVariable is gated behind the saveState
-- setting and debounced, and Bo found rule modes were not surviving a restart.
-- saveTable always persists.
----------------------------------------------------------------------

local function savePrefs()
    local chan, custom = {}, {}
    for i = 1, CH_N do
        local id = CH_ORDER[i]
        if id then
            if CH_ON[id] == true then chan[id] = "on" else chan[id] = "off" end
            if not CH_BUILTIN[id] then
                custom[id] = { label = CH_LABEL[id], color = CH_COLOR[id] }
            end
        end
    end

    local modes, caps = {}, {}
    for i = 1, R_N do
        local name = RULE_ORDER[i]
        local r = RULE[name]
        if name and r then
            modes[name] = r.mode or "both"
            if not r.builtin then
                caps[name] = { ch = r.ch, rx = r.rx and "yes" or "no", pat = r.pat }
            end
        end
    end

    saveTable("dbi-chat-prefs", {
        chan = chan, custom = custom, modes = modes, caps = caps,
        gag = masterGag and "yes" or "no",
        active = activeId,
        backdrop = tostring(backdrop),
        alpha = tostring(panelAlpha),
        bg = bgUrl,
        zoom = tostring(zoom),
    }, "global")
    pcall(function() saveState() end)
end

local function loadPrefs()
    local p = loadTable("dbi-chat-prefs", "global")
    if type(p) ~= "table" then return end

    -- custom channels first, so a saved mode can point at one
    if type(p.custom) == "table" then
        for id, spec in pairs(p.custom) do
            if type(spec) == "table" and has(spec.label) then
                defChannel(id, spec.label, spec.color or "#bbbbbb", false)
            end
        end
    end
    if type(p.caps) == "table" then
        for name, spec in pairs(p.caps) do
            if type(spec) == "table" and has(spec.pat) and isChannel(spec.ch) then
                defRoute(name, spec.ch, spec.rx == "yes", spec.pat, false)
            end
        end
    end

    if type(p.chan) == "table" then
        for i = 1, CH_N do
            local id = CH_ORDER[i]
            if id and p.chan[id] == "off" then CH_ON[id] = false end
        end
    end
    if type(p.modes) == "table" then
        for name, m in pairs(p.modes) do
            if RULE[name] and (m == "widget" or m == "both" or m == "off") then
                RULE[name].mode = m
            end
        end
    end

    if p.gag == "yes" then masterGag = true end
    if has(p.active) and isChannel(p.active) then activeId = p.active end
    local b = safeNum(p.backdrop)
    if b and b >= 0 and b <= 1 then backdrop = b end
    local a = safeNum(p.alpha)
    if a and a >= 0 and a <= 1 then panelAlpha = a end
    if type(p.bg) == "string" then bgUrl = safeUrl(p.bg) end
    local z = safeNum(p.zoom)
    if z and (z == 0 or (z >= FS_MIN and z <= FS_MAX)) then zoom = math.floor(z) end

    local vis, n = visibleTabs()
    if n == 0 then CH_ON.all = true end
end

----------------------------------------------------------------------
-- lines
----------------------------------------------------------------------

-- Colour becomes a class: the sanitiser strips inline colour from widget HTML.
local function classForColor(hex)
    if type(hex) ~= "string" then return nil end
    local body = hex:match("^#(%x%x%x%x%x%x)$")
    if not body then return nil end
    body = body:lower()
    usedColors[body] = true
    return "c" .. body
end

-- Parsed ON RECEIPT, never during a draw: the client reuses the object once
-- the callback returns.
local function segmentsFor(raw, clean)
    local out, n = {}, 0

    if type(raw) == "string" and raw ~= "" then
        pcall(function()
            local arr, an = normArray(parseAnsiText(raw))
            local i = 1
            while i <= an do
                local s = arr[i]
                if type(s) == "table" and type(s.text) == "string" and s.text ~= "" then
                    n = n + 1
                    out[n] = { text = s.text, cls = classForColor(s.color) }
                end
                i = i + 1
            end
        end)
    end

    if n == 0 then
        local plain = clean
        if not has(plain) then
            plain = raw
            local fn = callable("stripAnsiCodes")
            if fn then
                local ok, stripped = pcall(fn, raw)
                if ok and type(stripped) == "string" then plain = stripped end
            end
        end
        return { { text = tostring(plain or ""), cls = nil } }, 1
    end
    return out, n
end

local lastText, lastAt

-- One line can match several rules; the first one to claim it wins.
local function claim(text)
    local now = os.clock()
    if text == lastText and lastAt and (now - lastAt) < 0.05 then return false end
    lastText = text
    lastAt = now
    return true
end

local function push(chId, clean, raw)
    if not isChannel(chId) or not channelOn(chId) then return end

    local segs, n = segmentsFor(raw, clean)
    local entry = {
        ts = os.date("%H:%M"),
        tag = CH_LABEL[chId] or chId,
        ch = chId,
        segs = segs,
        n = n,
    }

    buffers[chId] = buffers[chId] or {}
    table.insert(buffers[chId], entry)
    while #buffers[chId] > MAX_LINES do table.remove(buffers[chId], 1) end

    if chId ~= "all" and channelOn("all") then
        buffers.all = buffers.all or {}
        table.insert(buffers.all, entry)
        while #buffers.all > MAX_LINES do table.remove(buffers.all, 1) end
    end

    if activeId ~= chId and activeId ~= "all" then
        unread[chId] = (unread[chId] or 0) + 1
    end
end

----------------------------------------------------------------------
-- typography, following the terminal rather than dictating
----------------------------------------------------------------------

local function readTerminalFont()
    local fn = callable("getTerminalFont")
    if not fn then return end
    local ok, f = pcall(fn)
    if not ok or type(f) ~= "table" then return end

    if type(f.family) == "string" and f.family ~= "" then
        termFamily = f.family:gsub("[;}<>]", "")
    end
    local n = safeNum(f.size)
    if n and n >= 6 and n <= 72 then termSize = math.floor(n) end
end

local function chromeFont()
    if termFamily ~= "" then return termFamily .. "," .. FONT_FALLBACK end
    return FONT_FALLBACK
end

local function baseSize()
    if zoom > 0 then return zoom end
    return termSize
end

local function tabSize()  return math.max(8, math.floor(baseSize() * 0.72)) end
local function bodySize() return math.max(9, math.floor(baseSize() * 0.92)) end

----------------------------------------------------------------------
-- rendering
--
-- Appended into a table rather than concatenated: a '..' chain this long
-- builds an expression tree deep enough that Lua refuses the file with
-- 'chunk has too many syntax levels'.
----------------------------------------------------------------------

local function paletteCss(add)
    for hex in pairs(usedColors) do
        add(".dbi-ch .c" .. hex .. "{color:#" .. hex .. ";}")
    end
end

local function css()
    local t = {}
    local function add(x) t[#t + 1] = x end
    local a = panelAlpha

    add("<style>")
    add(".dbi-ch{position:relative;height:100%;box-sizing:border-box;")
    add("display:flex;flex-direction:column;overflow:hidden;")
    add("container-type:inline-size;")
    add("background:rgba(" .. PANEL_RGB .. "," .. a .. ");")
    add("color:" .. INK .. ";font-family:" .. chromeFont() .. ";}")

    -- The backdrop sits under everything, dimmed to texture. The gradient is
    -- listed second so it shows when the image is absent -- a background-image
    -- that 404s falls through silently rather than leaving a broken frame, so
    -- the panel looks deliberate either way.
    add(".dbi-ch::before{content:'';position:absolute;inset:0;pointer-events:none;")
    local img = bgUrl
    if img == "" then img = IMG_BASE .. "/chat-bg.png" end
    add("background-image:url(\"" .. img .. "\"),")
    add("radial-gradient(120% 80% at 50% 0%,#16202e 0%,#0a0c11 70%);")
    add("background-size:cover;background-position:center;")
    add("opacity:" .. backdrop .. ";}")

    -- tab strip
    add(".dbi-ch .tabs{position:relative;z-index:1;flex:0 0 auto;display:flex;")
    add("flex-wrap:wrap;gap:2px;padding:4px 4px 0;")
    add("border-bottom:1px solid " .. GOLD_DIM .. ";}")
    add(".dbi-ch .tab{font-size:" .. tabSize() .. "px;letter-spacing:0.08em;")
    add("text-transform:uppercase;padding:3px 7px;border-radius:3px 3px 0 0;")
    add("border:1px solid " .. BEVEL .. ";border-bottom:none;color:" .. INK_DIM .. ";")
    add("background:rgba(255,255,255,0.03);cursor:pointer;user-select:none;")
    add("white-space:nowrap;}")
    add(".dbi-ch .tab:hover{color:" .. INK .. ";}")
    add(".dbi-ch .tab.on{color:" .. GOLD .. ";border-color:" .. GOLD_DIM .. ";")
    add("background:rgba(232,180,92,0.12);box-shadow:inset 0 -2px 0 " .. GOLD .. ";}")
    add(".dbi-ch .tab .u{margin-left:4px;color:" .. GOLD .. ";font-weight:700;}")
    add(".dbi-ch .tab.gear{margin-left:auto;}")

    -- Newest first into a column-reverse list. A full setWidgetProperty rebuild
    -- resets scroll position, and column-reverse makes the newest line the
    -- natural anchor, so a repaint stays pinned to the bottom for free.
    add(".dbi-ch .log{position:relative;z-index:1;flex:1 1 auto;min-height:0;")
    add("display:flex;flex-direction:column-reverse;overflow-y:auto;overflow-x:hidden;")
    add("padding:6px 8px;font-size:" .. bodySize() .. "px;line-height:1.45;}")
    add(".dbi-ch .ln{display:block;margin:0 0 2px;overflow-wrap:anywhere;}")
    add(".dbi-ch .ts{color:#5a6373;margin-right:6px;}")
    add(".dbi-ch .tg{color:" .. GOLD_DIM .. ";margin-right:6px;}")
    add(".dbi-ch a,.dbi-ch .url{color:#6fb6ff;text-decoration:underline;cursor:pointer;}")

    -- settings
    add(".dbi-ch .set{position:relative;z-index:1;flex:1 1 auto;min-height:0;")
    add("overflow-y:auto;padding:8px;font-size:" .. bodySize() .. "px;}")
    add(".dbi-ch .sec{margin:10px 0 4px;font-size:" .. tabSize() .. "px;font-weight:600;")
    add("letter-spacing:0.18em;text-transform:uppercase;color:" .. GOLD .. ";")
    add("border-bottom:1px solid " .. BEVEL .. ";padding-bottom:3px;}")
    add(".dbi-ch .row{display:flex;align-items:center;gap:6px;padding:2px 0;}")
    add(".dbi-ch .row .nm{flex:1 1 auto;min-width:0;overflow:hidden;")
    add("text-overflow:ellipsis;white-space:nowrap;color:" .. INK .. ";}")
    add(".dbi-ch .row .pat{flex:1 1 auto;min-width:0;overflow:hidden;")
    add("text-overflow:ellipsis;white-space:nowrap;color:#5a6373;font-size:90%;}")
    add(".dbi-ch .tb{flex:0 0 auto;font-size:" .. tabSize() .. "px;letter-spacing:0.08em;")
    add("text-transform:uppercase;padding:2px 6px;border-radius:2px;")
    add("border:1px solid " .. BEVEL .. ";color:" .. INK_DIM .. ";")
    add("cursor:pointer;user-select:none;white-space:nowrap;}")
    add(".dbi-ch .tb:hover{color:" .. INK .. ";border-color:" .. GOLD .. ";}")
    add(".dbi-ch .tb.on{color:" .. GOLD .. ";border-color:" .. GOLD_DIM .. ";")
    add("background:rgba(232,180,92,0.12);}")
    add(".dbi-ch .note{margin-top:8px;color:#5a6373;font-size:90%;}")

        -- settings are a form now: native controls, styled to match the panel.
        -- '.hd' is the channel heading inside routing -- it used to carry an
        -- inline colour, which the sanitiser strips.
    add(".dbi-ch .set label.row{cursor:pointer;}")
    add(".dbi-ch .set .hd{margin-top:6px;}")
    add(".dbi-ch .set .hd .nm{color:" .. GOLD .. ";font-weight:600;}")
    -- 'appearance:none' is the whole trick. A native select honours 'color' and
    -- ignores 'background-color', so styling it without this gives you the
    -- panel's near-white text on the platform's white box -- invisible, which
    -- is exactly what it looked like.
    add(".dbi-ch .set select{flex:0 0 auto;font:inherit;font-size:90%;")
    add("appearance:none;-webkit-appearance:none;-moz-appearance:none;")
    add("color:" .. INK .. ";background-color:" .. PANEL_BG .. ";")
    add("border:1px solid " .. GOLD_DIM .. ";border-radius:3px;")
    add("padding:2px 20px 2px 7px;cursor:pointer;")
    -- and the caret, drawn here because dropping the native appearance drops
    -- the native arrow with it
    add("background-image:linear-gradient(45deg,transparent 50%," .. GOLD .. " 50%),")
    add("linear-gradient(135deg," .. GOLD .. " 50%,transparent 50%);")
    add("background-position:calc(100% - 12px) 55%,calc(100% - 8px) 55%;")
    add("background-size:4px 4px;background-repeat:no-repeat;}")
    add(".dbi-ch .set select:hover{border-color:" .. GOLD .. ";}")
    -- the opened list is painted by the platform, so it needs telling too
    add(".dbi-ch .set option{color:" .. INK .. ";background-color:" .. PANEL_BG .. ";}")

    add(".dbi-ch .set input[type=checkbox]{flex:0 0 auto;width:13px;height:13px;")
    add("margin:0;accent-color:" .. GOLD .. ";cursor:pointer;}")
    add(".dbi-ch .set input[type=text]{flex:1 1 auto;min-width:0;font:inherit;")
    add("font-size:90%;color:" .. INK .. ";background-color:" .. PANEL_BG .. ";")
    add("border:1px solid " .. GOLD_DIM .. ";border-radius:3px;padding:2px 6px;}")
    add(".dbi-ch .set input[type=text]:focus{outline:none;border-color:" .. GOLD .. ";}")
    add(".dbi-ch .set button{font:inherit;font-size:90%;letter-spacing:0.08em;")
    add("text-transform:uppercase;color:" .. PANEL_BG .. ";background:" .. GOLD .. ";")
    add("border:0;border-radius:3px;padding:4px 14px;margin-top:8px;cursor:pointer;}")
    add(".dbi-ch .set button:hover{background:#ffd98a;}")

    add("@container (max-width:260px){.dbi-ch .ts{display:none;}}")
    paletteCss(add)
    add("</style>")
    return table.concat(t)
end

-- http(s) only. hyperlink() refuses anything else, and a chat line is the most
-- attacker-influenced text this plugin handles.
local function linkify(text)
    local out = text:gsub("(https?://[^%s<>\"]+)",
        '<span class="url" data-mud-action="url" data-mud-data="%1">%1</span>')
    return out
end

local function renderLine(e, showTag)
    local t = {}
    local function add(x) t[#t + 1] = x end

    add('<div class="ln"><span class="ts">' .. escapeHtml(e.ts) .. "</span>")
    if showTag then
        add('<span class="tg">' .. escapeHtml(e.tag) .. "</span>")
    end

    local i = 1
    while i <= e.n do
        local s = e.segs[i]
        if s then
            local body = linkify(escapeHtml(s.text))
            if s.cls then
                add('<span class="' .. s.cls .. '">' .. body .. "</span>")
            else
                add(body)
            end
        end
        i = i + 1
    end
    add("</div>")
    return table.concat(t)
end

local function logBody()
    local buf = buffers[activeId]
    local n = 0
    if buf then n = #buf end
    if n == 0 then
        return '<div class="ln"><span class="ts">--</span>nothing here yet</div>'
    end

    local showTag = (activeId == "all")
    local t = {}
    -- newest first, because the list is column-reverse
    local i = n
    while i >= 1 do
        t[#t + 1] = renderLine(buf[i], showTag)
        i = i - 1
    end
    return table.concat(t)
end

local function tabsHtml()
    local t = {}
    local function add(x) t[#t + 1] = x end
    add('<div class="tabs">')

    local vis, vn = visibleTabs()
    for v = 1, vn do
        local id = vis[v]
        -- NOT called 'on'. A local of that name anywhere in a file takes the
        -- global on() down for the whole of it -- the transpiler hoists it to
        -- module scope, so every reference resolves to this let and anything
        -- running before this point gets 'Can't find variable: on'. dbtrain
        -- lost both its event subscriptions that way, silently, for weeks.
        -- Nothing here calls on() today; this is so that stays true by
        -- accident rather than becoming a silent failure the day it does.
        local sel = ""
        if id == activeId then sel = " on" end
        local badge = ""
        local u = unread[id] or 0
        if id ~= activeId and u > 0 then
            badge = '<span class="u">' .. u .. "</span>"
        end
        add('<span class="tab' .. sel .. '" data-mud-action="tab" data-mud-data="'
            .. escapeHtml(id) .. '">' .. escapeHtml(CH_LABEL[id] or id) .. badge .. "</span>")
    end

    local gearOn = ""
    if view == "settings" then gearOn = " on" end
    add('<span class="tab gear' .. gearOn .. '" data-mud-action="view">setup</span>')
    add("</div>")
    return table.concat(t)
end

-- Options are (value, label) pairs so the stored number and the shown text can
-- differ -- zoom 0 reads as "follow terminal" rather than as a zero.
local function selectOf(field, options, current)
    local out = '<select name="' .. escapeHtml(field) .. '">'
    for i = 1, #options do
        local o = options[i]
        local sel = ""
        if tostring(o[1]) == tostring(current) then sel = " selected" end
        out = out .. '<option value="' .. escapeHtml(tostring(o[1])) .. '"' .. sel .. ">"
            .. escapeHtml(o[2]) .. "</option>"
    end
    return out .. "</select>"
end

local MODE_OPTS = { { "widget", "widget" }, { "both", "both" }, { "off", "off" } }

local function zoomOpts()
    local out = { { 0, "follow terminal" } }
    for px = FS_MIN, FS_MAX do out[#out + 1] = { px, px .. "px" } end
    return out
end

local function pctOpts(from, to, step)
    local out = {}
    for v = from, to, step do out[#out + 1] = { v, v .. "%" } end
    return out
end

local function settingsBody()
    local t = {}
    local function add(x) t[#t + 1] = x end
    add('<div class="set">')

    -- One form, one Save.
    --
    -- Every control in here used to be a button that rebuilt the widget, and a
    -- rebuild puts the scroll back at the top -- unusable by the time you are
    -- down among the routing rules. A checkbox or a select changes in the
    -- browser with no round trip, so nothing repaints until you ask it to.
    -- Same fix and same reason as the Aardwolf Comms panel, which hit this with
    -- forty-odd channels.
    add('<form><input type="hidden" name="op" value="settings">')

    add('<div class="sec">tabs</div>')
    for i = 1, CH_N do
        local id = CH_ORDER[i]
        if id then
            local kind = "built in"
            if not CH_BUILTIN[id] then kind = "yours" end
            local chk = ""
            if CH_ON[id] == true then chk = " checked" end
            add('<label class="row"><span class="nm">' .. escapeHtml(CH_LABEL[id] or id)
                .. '</span><span class="pat">' .. kind .. "</span>"
                .. '<input type="checkbox" name="ch:' .. escapeHtml(id) .. '"' .. chk
                .. "></label>")
        end
    end

    add('<div class="sec">routing</div>')
    for c = 1, CH_N do
        local cid = CH_ORDER[c]
        if cid and cid ~= "all" then
            local shown = false
            for i = 1, R_N do
                local name = RULE_ORDER[i]
                local r = RULE[name]
                if name and r and r.ch == cid then
                    if not shown then
                        add('<div class="row hd"><span class="nm">'
                            .. escapeHtml(CH_LABEL[cid] or cid) .. "</span></div>")
                        shown = true
                    end
                    add('<label class="row"><span class="pat">' .. escapeHtml(name)
                        .. "</span>"
                        .. selectOf("md:" .. name, MODE_OPTS, r.mode or "both")
                        .. "</label>")
                end
            end
        end
    end

    add('<div class="sec">display</div>')
    local gagOn = ""
    if masterGag then gagOn = " checked" end
    add('<label class="row"><span class="nm">hide routed lines from the main window</span>'
        .. '<input type="checkbox" name="gag"' .. gagOn .. "></label>")
    add('<label class="row"><span class="nm">text size</span>'
        .. selectOf("zoom", zoomOpts(), zoom) .. "</label>")
    add('<label class="row"><span class="nm">backdrop</span>'
        .. selectOf("bd", pctOpts(0, 60, 10), math.floor(backdrop * 100 + 0.5)) .. "</label>")
    add('<label class="row"><span class="nm">image</span>'
        .. '<input type="text" name="bg" value="' .. escapeHtml(bgUrl)
        .. '" placeholder="https://...  (blank for the one that ships)"></label>')
    add('<label class="row"><span class="nm">opacity</span>'
        .. selectOf("alpha", pctOpts(25, 100, 15), math.floor(panelAlpha * 100 + 0.5))
        .. "</label>")

    add('<div class="row"><button type="submit">Save</button></div>')
    add("</form>")

    -- Deleting a capture changes the shape of the list, so it redraws and is
    -- meant to. It sits after the form for that reason: nothing above it moves.
    add('<div class="sec">captures</div>')
    local anyCustom = false
    for i = 1, R_N do
        local name = RULE_ORDER[i]
        local r = RULE[name]
        if name and r and not r.builtin then
            anyCustom = true
            add('<div class="row"><span class="nm">' .. escapeHtml(name)
                .. '</span><span class="pat">' .. escapeHtml(r.ch) .. "  "
                .. escapeHtml(r.pat) .. "</span>"
                .. '<span class="tb" data-mud-action="uncap" data-mud-data="'
                .. escapeHtml(name) .. '">del</span></div>')
        end
    end
    if not anyCustom then
        add('<div class="note">none yet &mdash; dbchat capture &lt;name&gt; &lt;tab&gt; &lt;text&gt;</div>')
    end

    add('<div class="note">dbchat capture &lt;name&gt; &lt;tab&gt; &lt;text&gt;<br>'
        .. "dbchat capture &lt;name&gt; &lt;tab&gt; re:&lt;regex&gt;<br>"
        .. "dbchat tab &lt;id&gt; &lt;Label&gt;<br>dbchat diag</div>")
    add("</div>")
    return table.concat(t)
end

local function render()
    if not widget then return end
    readTerminalFont()

    if not isChannel(activeId) or not channelOn(activeId) then
        activeId = firstVisible()
    end

    local inner = ""
    if view == "settings" then
        inner = settingsBody()
    else
        inner = '<div class="log">' .. logBody() .. "</div>"
    end

    setWidgetProperty(widget, "content",
        css() .. '<div class="dbi-ch">' .. tabsHtml() .. inner .. "</div>")
end

local function safeRender()
    local ok, err = pcall(render)
    if not ok then
        lastError = tostring(err)
        print(TAG .. "render error: " .. lastError)
    end
end

----------------------------------------------------------------------
-- triggers
----------------------------------------------------------------------

local function registerTriggers()
    for i = 1, trigN do
        if triggerIds[i] then removeTrigger(triggerIds[i]) end
    end
    triggerIds = {}
    trigN = 0

    for i = 1, R_N do
        local name = RULE_ORDER[i]
        local r = RULE[name]
        if name and r and channelOn(r.ch) and r.mode ~= "off" and has(r.pat) then
            local ttype = "substring"
            if r.rx == true then ttype = "regex" end

            local hide = false
            if masterGag and r.mode == "widget" then hide = true end

            local ch = r.ch
            -- The fourth argument is the raw line with its ANSI intact, which is
            -- where the MUD's own colours come from. Parameters need DISTINCT
            -- names: two '_' placeholders is legal Lua but transpiles to a
            -- JavaScript function with duplicate parameters, a hard SyntaxError.
            local id = addTrigger(r.pat, function(caps, line, wilds, rawLine)
                local text = line or ""
                if claim(text) then
                    push(ch, text, rawLine)
                    safeRender()
                end
            end, {
                type = ttype,
                omitFromOutput = hide,
                priority = (ch == "personal") and 80 or 70,
            })
            trigN = trigN + 1
            triggerIds[trigN] = id
        end
    end
end

----------------------------------------------------------------------
-- widget
----------------------------------------------------------------------

-- An unchecked box is simply absent from formData, so presence is the value.
-- Booleans are written as real true/false and never left nil: a nil that
-- round-trips through storage comes back as JS undefined, which is truthy.
local function applySettingsForm(f)
    for i = 1, CH_N do
        local id = CH_ORDER[i]
        if id then CH_ON[id] = (f["ch:" .. id] ~= nil) end
    end

    -- clearing every box leaves nothing to render, so All comes back
    local vis, n = visibleTabs()
    if n == 0 then
        CH_ON.all = true
        echo(TAG .. "every tab was off; All is back on.", "#ff6666")
    end
    if not isChannel(activeId) or not channelOn(activeId) then
        activeId = firstVisible()
    end

    for i = 1, R_N do
        local name = RULE_ORDER[i]
        local r = RULE[name]
        if name and r then
            local m = tostring(f["md:" .. name] or "")
            if m == "widget" or m == "both" or m == "off" then r.mode = m end
        end
    end

    masterGag = (f.gag ~= nil)

    -- Rejected rather than repaired, and only http(s): this ends up inside a
    -- CSS url(), where a stray quote would close the declaration and let the
    -- rest of the string become rules.
    local url = safeUrl(f.bg)
    if url ~= bgUrl then
        if url == "" and tostring(f.bg or "") ~= "" then
            echo(TAG .. "that backdrop URL was refused; using the bundled one.", "#ff6666")
        end
        bgUrl = url
    end

    -- Each of these is read and range-checked on its own. A field that did not
    -- come back must not take the others down with it.
    local z = safeNum(f.zoom)
    if z and (z == 0 or (z >= FS_MIN and z <= FS_MAX)) then zoom = math.floor(z) end

    local b = safeNum(f.bd)
    if b and b >= 0 and b <= 100 then backdrop = b / 100 end

    local a = safeNum(f.alpha)
    if a and a >= 10 and a <= 100 then
        panelAlpha = a / 100
        pcall(function()
            setWidgetAppearance(widget, { backgroundOpacity = panelAlpha })
        end)
    end

    savePrefs()
    registerTriggers()
    safeRender()
end

local function makeWidget()
    widget = createWidget({
        type     = "html",
        name     = "chat",
        title    = "Chat",
        position = { x = 430, y = 120 },
        size     = { width = 560, height = 320 },
        scrollable = false,
        appearance = { showTitleBar = false, autoHideSettingsCog = true },
    })
    setWidgetAppearance(widget, {
        backgroundColor   = PANEL_BG,
        backgroundOpacity = panelAlpha,
        borderColor       = GOLD_DIM,
        borderWidth       = 2,
        borderRadius      = 6,
        borderGradient    = "linear-gradient(135deg,#ffd98a,#8a5a12 60%,#2a1c06)",
        borderShadow      = "0 0 14px 2px rgba(255,185,80,0.20)",
    })

    pcall(function() unregisterWidgetEvent(widget, "action") end)
    registerWidgetEvent(widget, "action", function(data)
        if type(data) ~= "table" then return end
        local act = tostring(data.action or "")
        local arg = tostring(data.data or "")

        if act == "tab" then
            if isChannel(arg) then
                activeId = arg
                unread[arg] = 0
                view = "chat"
                savePrefs()
            end
        elseif act == "view" then
            if view == "settings" then view = "chat" else view = "settings" end
        elseif act == "uncap" then
            if RULE[arg] and not RULE[arg].builtin then
                RULE[arg] = nil
                local out, n = {}, 0
                for i = 1, R_N do
                    local nm = RULE_ORDER[i]
                    if nm and RULE[nm] then n = n + 1; out[n] = nm end
                end
                RULE_ORDER = out
                R_N = n
                savePrefs()
                registerTriggers()
            end
        elseif act == "url" then
            if arg:sub(1, 8) == "https://" or arg:sub(1, 7) == "http://" then
                pcall(function() hyperlink(arg, arg) end)
            end
            return
        end
        safeRender()
    end)

    -- A form submit is its own event, not an action. Everything named in the
    -- form arrives together in data.formData, which is the whole point: one
    -- round trip instead of one per control.
    pcall(function() unregisterWidgetEvent(widget, "submit") end)
    registerWidgetEvent(widget, "submit", function(data)
        if type(data) ~= "table" then return end
        local f = data.formData
        if type(f) ~= "table" then return end
        if tostring(f.op or "") ~= "settings" then return end
        applySettingsForm(f)
    end)

    safeRender()
end

----------------------------------------------------------------------
-- diagnostics
--
-- Its own function: Lua 5.1 caps a function at 60 upvalues and the command
-- handler is where that ceiling gets hit.
----------------------------------------------------------------------

local function printDiag()
    print(TAG .. "instance=" .. INSTANCE .. " live=" .. tostring(getVariable("instance")))
    print(TAG .. "view=" .. view .. " active=" .. tostring(activeId)
        .. " gag=" .. tostring(masterGag))
    print(TAG .. "channels=" .. CH_N .. " rules=" .. R_N .. " triggers=" .. trigN)
    print(TAG .. "font=" .. termSize .. "px <" .. termFamily .. ">"
        .. " backdrop=" .. backdrop .. " alpha=" .. panelAlpha
        .. " zoom=" .. zoom .. " body=" .. bodySize() .. "px")

    for i = 1, CH_N do
        local id = CH_ORDER[i]
        if id then
            local b = buffers[id] or {}
            print(TAG .. "  " .. id .. " on=" .. tostring(CH_ON[id])
                .. " lines=" .. #b .. " unread=" .. tostring(unread[id] or 0))
        end
    end

    local saved = loadTable("dbi-chat-prefs", "global")
    if type(saved) == "table" then
        print(TAG .. "prefs saved (gag=" .. tostring(saved.gag) .. ")")
    else
        print(TAG .. "prefs MISSING - settings will not survive a restart")
    end
    print(TAG .. "lastError=" .. lastError)
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

function init()
    readTerminalFont()

    for i = 1, CH_N do
        local id = CH_ORDER[i]
        if id then
            buffers[id] = {}
            unread[id] = 0
        end
    end

    loadPrefs()
    for i = 1, CH_N do
        local id = CH_ORDER[i]
        if id and buffers[id] == nil then
            buffers[id] = {}
            unread[id] = 0
        end
    end
    activeId = firstVisible()

    setVariable("instance", INSTANCE)
    makeWidget()
    registerTriggers()

    registerCommand("dbchat", function(args)
        local raw = trimBoth(tostring(args or ""))
        local low = raw:lower()

        if low == "show" then
            showWidget(widget, true)
            safeRender()
        elseif low == "hide" then
            hideWidget(widget, true)
        elseif low == "setup" then
            view = "settings"
            safeRender()
        elseif low == "clear" then
            for i = 1, CH_N do
                local id = CH_ORDER[i]
                if id then buffers[id] = {} end
            end
            safeRender()
        elseif low == "diag" then
            printDiag()

        elseif low:sub(1, 8) == "capture " then
            -- chat capture <name> <tab> <text>   |   ... re:<regex>
            local name, tab, pat = raw:match("^%S+%s+(%S+)%s+(%S+)%s+(.+)$")
            if not name then
                echo(TAG .. "dbchat capture <name> <tab> <text|re:regex>", "#ff6666")
                return
            end
            if not isChannel(tab) then
                echo(TAG .. "no such tab: " .. tab, "#ff6666")
                return
            end
            local rx = false
            if pat:sub(1, 3) == "re:" then
                rx = true
                pat = pat:sub(4)
            end
            defRoute(slug(name), tab, rx, pat, false)
            savePrefs()
            registerTriggers()
            safeRender()
            echo(TAG .. "capture " .. slug(name) .. " -> " .. tab, "#66ccff")

        elseif low:sub(1, 4) == "tab " then
            -- chat tab <id> <Label>
            local id, label = raw:match("^%S+%s+(%S+)%s+(.+)$")
            if not id then
                echo(TAG .. "dbchat tab <id> <Label>", "#ff6666")
                return
            end
            defChannel(slug(id), label, "#bbbbbb", false)
            buffers[slug(id)] = buffers[slug(id)] or {}
            unread[slug(id)] = 0
            savePrefs()
            safeRender()
            echo(TAG .. "tab " .. slug(id) .. " added", "#66ccff")

        else
            echo(TAG .. "dbchat show | hide | setup | clear | diag", "#e8b45c")
            echo("      dbchat capture <name> <tab> <text>   route a line", "#e8b45c")
            echo("      dbchat capture <name> <tab> re:<rx>  same, as regex", "#e8b45c")
            echo("      dbchat tab <id> <Label>              a tab of your own", "#e8b45c")
            echo("      (everything else is on the setup tab)", "#7d8797")
        end
    end, "Chat window")
end

function cleanup() end
