plugin = {
    id          = "dbi-portrait",
    name        = "DB Infinity Portrait",
    version     = "2026.08.17.003",
    author      = "Solao",
    description = "Character portrait and sheet for Dragonball Infinity, off char.vitals and score.",
    settings    = { saveState = true },
}

-- Two sources, because neither is enough on its own:
--
--   char.vitals  hit, max_hit, energy, max_energy, basepl, pl. Live, pushed,
--                and the only thing that keeps the bars honest while you fight.
--   score        race, sex, age, stats, armour, kills, everything else. Only
--                arrives when asked for, so it is parsed and kept.
--
-- The score block stays in the scroll exactly as the MUD sent it. The one thing
-- that can be gagged is the stat prompt line, and only when asked: it exists for
-- the widgets rather than for reading, but it is also the line people watch, so
-- turning it off is a decision rather than a default. That gag depends on the
-- prompt ending in a newline -- a still-open line ignores omitFromOutput, and
-- gagging one eats the echo of whatever was typed.

-- Off the plugin table rather than a second copy. This was hand-kept and it
-- drifted: the panel said 0.29.2 while the repository served 0.30.1, which
-- defeats the entire point of stamping the version on every line.
local VERSION = plugin.version

-- Every line this plugin prints carries its version. Three copies of the
-- same plugin were once live at once and nothing in the output said so.
local TAG = "[DBI Portrait " .. VERSION .. "] "

-- Same reload guard as Scouter: the client does not reliably tear down a
-- previous load's timers, so each load stamps a token and an older tick retires.
local INSTANCE = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
-- Monotonic, for the tick's reload guard. A string compare cannot tell a NEWER
-- load from a STALE read; a number can.
local INSTANCE_AT = os.time() * 1000 + math.random(0, 999)
local tickTimer = nil

local AVATAR_BASE = "https://raw.githubusercontent.com/SeanStoves/dbinfinity-mudforge/HEAD/img/avatars"

-- The design's own tokens (app/globals.css), oklch converted to hex. oklch is
-- given second wherever it matters so a browser that understands it gets the
-- exact colour and one that does not keeps the approximation.
--
-- One table rather than a name each. Lua 5.1 allows a chunk 200 locals and this
-- file is at the ceiling, so a dozen colours spent a dozen of them; as fields
-- they cost one and the next feature gets the room back.
-- The panel itself: the widget id, the background alpha, which view is up,
-- how the power level is shown, the tabs, the font, the level colours and the
-- palette. Eight file-scope locals about one thing.
local panel = {}

panel.C = {
    hp       = "#ea3c3f",
    ki       = "#00acf3",
    stam     = "#5ec966",
    energy   = "#fb7c00",
    foe      = "#ff9a3c",
    gold     = "#e8b45c",           -- armour
    auc      = "#a878ff",           -- the auction pill
    panel_bg = "#080e16",
    ink      = "#edf2f8",
    ink_dim  = "#969fab",
    rule     = "rgba(255,255,255,0.12)",
    card_rgb = "15,22,33",
}

-- Where a bar changes character, mapped onto the same palette: energy at the
-- first threshold, then deeper, then the health red. 15% is the one that
-- matters -- red and moving.
panel.LV = { warn = 60, low = 30, crit = 15 }


-- Where a bar changes character, mapped onto the same palette: energy at the
-- first threshold, then deeper, then the health red. 15% is the one that
-- matters -- red and moving.


-- The terminal's font, and the user's multiplier over it.
panel.font = {
    fallback = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace",
    family   = "",
    size     = 13,
    scale    = 1,               -- user multiplier over the terminal's size
}

-- Hiding the prompt line: the trigger doing it, the ids it owns, and the text
-- it is matching on.
local gag = { on = false, triggerId = nil, ids = {}, sig = "", tag = "" }

-- Everything about reading the prompt: what has been learned, what is armed,
-- and the signature that says whether the arming is still current.
--
-- One table for the lot. Nine names for one subject is nine of the 200 a chunk
-- gets, and this file ran out of them.
-- The prompt: what it currently is, the roles a field can play, the text
-- forms, the pattern pieces and their cap, the prompts already known, and
-- what has been learned for whom. Eight file-scope locals, one subject.
local pr = {}

pr.cur = {
    learned = {},               -- the formats, as the user set them
    set     = nil,              -- the compiled set in use
    roles   = nil,              -- which fields each compiled line yields
    trigIds = {},
    used    = {},
    order   = {},
    sig     = "",
    blank   = false,
    tag     = "LifeForce:",
}

-- The GMCP handshake, which Scouter usually owns.
local nego = { connected = false, tick = 0, done = false }

panel.id = nil
panel.alpha = 1
panel.view = "portrait"      -- or "sheet"
panel.plMode = "bar"         -- or "nums": Base PL | Curr PL side by side
local avatarUrl = ""         -- override, per character
local lastError = "none"

-- The stat prompt line, out of the main window. Off by default: it is the line
-- people watch, and a gag that fires on the wrong pattern eats something else.
--
-- What the prompt actually says is learned rather than configured. This MUD
-- draws '(LifeForce:<100.00> Ki:<8,955>)'; the fprompt this was first built
-- against uses 'LF:['. The label is what the gag matches, so the brackets do not
-- come into it -- but the label has to be the right one, and the MUD announces
-- it every time it draws a prompt. promptTag is what the next gag will match;
-- gagTag is what the live trigger was built on, so a change re-arms it.



-- Transformation portraits. Each form pairs the line the MUD prints on entering
-- it with the image to wear while in it:
--
--   FORMS[name] = { pat = "the announcement text", url = "https://..." }
--
-- A url of "base" is the way back -- matching that form clears the override and
-- the portrait falls through to the usual avatar. Matched in onLine as another
-- feeder beside score and the foe; nothing is gagged, the announcement stays in
-- the scroll where it belongs.
--
-- Kept per character, alongside the sheet and the avatar. A Saiyan's Super
-- Saiyan line means nothing on a Namekian, and an alt inheriting the list would
-- transform on someone else's text.
-- Transformations: the known forms, the picture for the one we are in, and
-- its name.
local form = {}

form.ALL = {}
form.url = ""           -- the active form's image, "" = base
form.name = ""

-- char.vitals, owned copy
-- What you are actually doing, watched off the lines that say so.
--
-- 'position' comes from score, and score is a SNAPSHOT: whatever you were
-- doing when you last typed it, shown for the rest of the session. The panel
-- read RESTING through an entire fight because that is what score had said an
-- hour earlier. A stale posture is the same kind of lie as a stale opponent,
-- and this file already refuses to persist one of those.
local posture = ""

local vit = nil

-- Enemy lifeforce. GMCP carries nothing about the opponent, so this is read off
-- the fprompt's Foe token as it passes through onLine -- present in a fight,
-- absent outside one. A prompt showing lifeforce and Ki but no Foe means the
-- fight ended, which is a surer clear than any timeout; foe.stale is only the
-- backstop for a fight that ends without a further prompt.
-- One table rather than two names plus the two diagnostic fields this wanted.
-- The chunk is three locals from Lua 5.1's ceiling (sharp edge 7).
--   val  the opponent's lifeforce, a percentage
--   at   when it was last read, for the staleness backstop
--   saw  the last line that looked like it carried an opponent, verbatim
--   got  what was pulled out of it, or why nothing was
-- The opponent. 'val' is a percentage, which is all the prompt ever gave.
--
-- char.target now carries { name, hit, race } over GMCP, which is more than the
-- prompt has and does not need a trigger to read. It has no max_hit though, so
-- the peak seen since this target appeared stands in for one -- self-correcting,
-- since the first reading of a fresh target is its highest.
-- Where each part of the panel takes its reading from.
--
-- GMCP by default, everywhere. The line readers are not deleted -- they sit
-- behind these toggles -- because a MUD that changes what it sends should cost
-- a setting rather than a working panel, and because this server has changed
-- what it sends twice already.
--
--   bars   armour and the enemy bar: "gmcp" prefers char.target and score,
--          "prompt" pins both to the prompt's own tokens.
--   stats  the four attributes, the armour ceiling, zeni: "gmcp" or "score".
--   items  inventory and equipment: "gmcp", or "capture" to go back to
--          reading the output of 'inv' and 'eq'.
-- GMCP for all four, and the toggle is there for when a node disappoints.
--
-- The channel parsing stays either way -- it is the only thing that knows a
-- sale from an expiry, which is what Codex's price history is built on. This
-- decides who sets the pill, nothing more.
local src = { bars = "gmcp", stats = "gmcp", items = "gmcp", auc = "gmcp" }

local foe = { val = nil, at = 0, saw = "", got = "", why = "",
              name = nil, hit = nil, peak = nil, race = nil, max = nil,
              -- seconds before an unrefreshed opponent is dropped; the backstop
              -- behind the fight-end line and the no-opponent prompt
              stale = 10 }

-- Assigned once safeRender exists, subscribed in init. 'x = function()' and not
-- 'function x()' -- the transpiler emits the latter as a declaration shadowing
-- the let and refuses to load the file at all.
local onTarget = nil

-- everything parsed out of score
-- The prompt reader's own counters, one table rather than four names. The chunk
-- is at Lua 5.1's 200-local ceiling and folding is the fix for that, not
-- deleting. 'scoreSaw' rides along because the score reader needs somewhere to
-- put the line it last worked on and there is no room for a name of its own.
local pd = { tries = 0, hits = 0, buildErr = nil, readErr = nil, scoreSaw = "" }

local sc = {}
-- Reading the score sheet: whether we are inside the block, how many lines
-- in, the cap, and whether one has been seen at all.
--
-- Separate from 'sc', which holds what was READ. sc is reassigned wholesale
-- when a profile loads -- 'sc = prof.sc' -- so anything folded into it that
-- outlives one sheet, the cap especially, would be wiped by a profile switch.
local sheet = {}

sheet.seen = false

-- Everything the panel knows, kept per character.
--
-- The sheet comes from score, and score only arrives when it is asked for, so
-- a restart used to leave the panel blank until it was typed. It is saved now
-- and comes back -- but saved under the character it belongs to, or an alt
-- would open wearing the last one's face, race and power level.
--
-- The vitals are deliberately NOT kept. They arrive from GMCP within seconds
-- of connecting, and a stale bar reading full lifeforce on a character sitting
-- at twenty percent is worse than an empty one.
-- Which character this is, and what is kept per character: the store, the
-- key into it, the name off the panel header, whether profiles are used at
-- all, and a name set by hand.
--
-- Not 'who' -- that is a local on three lines of this file, one of them
-- 'local who = who.key', which reads the outer name and then hides it.
local profile = {}

profile.all = {}
profile.key = ""
profile.header = nil
-- Assigned once saveSettings exists. readHeader calls this hundreds of lines
-- before either is declared, and a file-scope local used above its declaration
-- resolves as a nil global here rather than erroring.
profile.use = function() end

-- score arrives as a block; these bound it
sheet.inBlock = false
sheet.lines = 0
sheet.MAX = 60

-- The rank and the name sit ABOVE the block's first rule, so by the time
-- 'STRENGTH:' identifies the block they have already gone past. Three lines of
-- look-behind is enough to reach back for them.
local recent = { "", "", "" }
profile.override = ""
-- The item tabs: what has been read, whether it is trusted, the caps and the
-- words worth skipping. Eight file-scope locals for one feature.
--
-- Called 'gear' rather than the obvious 'item' because 'item' is a local on
-- 64 lines of this file -- including 'local slot, item = line:match(...)'
-- two lines above where inEq is cleared, which would have put that assignment
-- onto the matched string.
local gear = {}

gear.inEq = false

-- Core.Hello and the supports Add belong to whichever of our plugins loads
-- first. Add merges rather than replaces, and 'Map 1' turns on char stats as
-- well, so one negotiation covers both panels -- but each has to be able to do
-- it alone. A global-scope variable is the only state two plugins share.
-- One table rather than two names. The chunk is at Lua 5.1's 200-local ceiling
-- (sharp edge 7) and folding related constants is the fix for that.
local HELLO = { key = "dbi-gmcp-hello", window = 30 }

----------------------------------------------------------------------
-- value hygiene, same reasons as Scouter
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

-- An array that crossed the boundary, put back in order.
--
-- Arrays do not arrive reliably 1-indexed here. They have come 0-indexed, as
-- objects with numeric keys, and as undefined. char.equipment.items and
-- char.inventory.items are both arrays, so nothing walks them with ipairs
-- until they have been through this.
--
-- Ported from Scouter, where it has been carrying the map runs for months.
-- Returns the table AND its length: read them into locals, never nest the call.
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

    local tmp, minK, maxK = {}, nil, nil
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

-- "9,925" and "3,130" are how this MUD writes numbers
-- 1000000 -> "1,000,000". The reverse of commaNum below, which STRIPS commas to
-- parse. Compared rather than counted: reading gsub's second return to decide
-- whether to go round again is a two-value return, and that ran one pass and
-- stopped in the codex, leaving '1000,000'.
local function withCommas(n)
    local out = tostring(math.floor(n))
    while true do
        local step = out:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
        if step == out then return out end
        out = step
    end
end

local function commaNum(s)
    if type(s) ~= "string" then return nil end
    return safeNum((s:gsub(",", "")))
end

-- Power levels reach seven and eight figures and the box is only as wide as the
-- panel minus its label, so the headline figure gets abbreviated the way the
-- MUD's own prompt does it (165.5k). Under six figures the exact number is no
-- wider than the abbreviation would be, so it stays exact.
local function short(v)
    local n = safeNum(v)
    if not n or n < 100000 then return tostring(v) end

    local div = 1000
    local suffix = "K"
    if n >= 1000000000 then
        div = 1000000000
        suffix = "B"
    elseif n >= 1000000 then
        div = 1000000
        suffix = "M"
    end

    -- built by hand rather than with string.format, which nothing else in the
    -- set uses and which the transpiler has never been asked for
    local scaled = n / div
    local whole = math.floor(scaled)
    local tenth = math.floor((scaled - whole) * 10 + 0.5)
    if tenth > 9 then
        whole = whole + 1
        tenth = 0
    end
    return whole .. "." .. tenth .. suffix
end

-- An unset table field arrives as `undefined`: truthy, and not equal to nil.
-- Everything downstream therefore asks what a value IS rather than what it is
-- not -- 'Zeni' and 'Align' printed as bare labels with empty values until this
-- existed.
local function has(v)
    local t = type(v)
    if t == "number" then return true end
    if t == "string" then return v ~= "" and v ~= "undefined" end
    return false
end

-- The client hands back "clean" lines with the ESC and '[' eaten and the
-- parameters left on the front: '0;37m          STRENGTH: ...'. stripAnsiCodes
-- cannot match that, there is no escape left in it. Scouter learned this the
-- hard way; this is the same guard.
local function dropAnsiDebris(s)
    local rest = tostring(s or ""):match("^[%d;]+m(.*)$")
    if rest then return rest end
    return s
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

-- '[^%w]' rather than '[^a-z0-9]'. A character range inside a class does not
-- survive the translation -- the '-' comes through literal, so that class read
-- as the set {a,-,z,0,9} and slug("Saiyan") returned "a-a". The avatar URL
-- resolved to a-a-a.png, which is how this was finally caught.
local function slug(s)
    local out = tostring(s or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    return out
end

----------------------------------------------------------------------
-- score
--
-- Fixed-format, but read by label and capture throughout. Offset arithmetic on
-- strings is unreliable in this runtime -- it advanced by zero once and cost an
-- evening -- so nothing here counts characters.
----------------------------------------------------------------------

local function field(line, label, pattern)
    if not line:find(label, 1, true) then return nil end
    return line:match(pattern)
end

-- STRENGTH:     52(    52.41) |     SPEED:     57(    57.61)
-- '[^%d]*' rather than '%D+'. Both mean "not a digit", but the uppercase
-- complement classes have no reliable translation here -- diag reported every
-- stat as undefined until this changed, which is what a pattern requiring a
-- literal 'D' would do. The negated class uses the lowercase form, which does
-- translate. No parens either, for the same reason as everywhere else.
-- One value per match, four matches for the two stats on a line.
--
-- This was two captures in a single pattern, which is the shape sharp edge 17
-- is about: a miss hands back undefined for both, undefined is truthy, so
-- 'if av then' let the failure through and safeNum turned it into nil. A live
-- diag read str, spd, spi and for all null off a score block whose zeni and
-- align on the same block parsed perfectly -- which is the signature of the
-- pattern, not of the block.
--
-- The bracketed figure is '(%S+)' rather than '([%d%.]+)'. %d is safe inside a
-- class and '%.' is not proven either way here; safeNum decides what is a
-- number, and it does that better than a class can.
--
--   STRENGTH:    135(   125.61) |     SPEED:    138(   128.95)
local function statPair(line, a, b)
    local function one(label)
        local v = line:match(label .. ":[^%d]*(%d+)")
        if type(v) == "string" then sc[slug(label)] = safeNum(v) end
        local r = line:match(label .. ":[^%d]*%d+%s*%(%s*(%S+)%)")
        if type(r) == "string" then sc[slug(label) .. "-real"] = safeNum(r) end
    end
    one(a)
    one(b)
end

local function parseScoreLine(line)
    -- kept verbatim for diag: reasoning about why a stat read null from the
    -- panel alone has cost more than one round
    if line:find("STRENGTH", 1, true) then pd.scoreSaw = line end

    statPair(line, "STRENGTH", "SPEED")
    statPair(line, "SPIRIT", "FORTITUDE")

    -- Read independently. These shared a line, so nesting them under the race
    -- match meant one failed pattern silently took all four.
    -- '%S+' rather than a letter class. '%a' has no JavaScript equivalent, so
    -- inside a character class the translation has nowhere to expand it and
    -- '[%a%-]' stops matching letters -- which is why Saiyan never parsed while
    -- 'Sex:%s*(%a+)' worked fine outside a class. Race is one token anyway,
    -- hyphens included: Bio-Android, Magic-Demon.
    local race = line:match("RACE%s*:%s*(%S+)")
    if race then sc.race = trimBoth(race) end

    local sex = line:match("Sex:%s*(%a+)")
    if sex then sc.sex = sex end

    local age = line:match("Age:%s*(%d+)")
    if age then sc.age = safeNum(age) end

    local hours = line:match("Hours:%s*(%d+)")
    if hours then sc.hours = safeNum(hours) end

    -- Two readings off one field, taken independently. The sheet wants the
    -- whole thing -- '10400, exceptionally crafted' -- and the meter wants the
    -- figure on its own, and one failing must not take the other with it.
    local armor = line:match("Armor%s*:%s*(.+)$")
    if type(armor) == "string" then sc.armor = trimBoth(armor) end
    local armorN = line:match("Armor%s*:%s*([%d,]+)")
    if type(armorN) == "string" then sc.armorVal = commaNum(armorN) end

    local align = line:match("Align%s*:%s*([%+%-]?%d+)")
    if align then sc.align = safeNum(align) end

    local pos = line:match("Position%s*:%s*(%a+)")
    if pos then sc.position = pos end

    -- '%b()' is a Lua balanced-match with no JavaScript regex equivalent, so it
    -- cannot survive the translation at all. Digits and separators, no brackets.
    local rpp = line:match("RPP[^%d]*([%d/:]+)")
    if rpp then sc.rpp = rpp end

    local lf = line:match("LifeForce:%s*%[([%d%.]+)%]")
    if lf then sc.lifeforce = safeNum(lf) end

    local en, enMax = line:match("Energy:%s*%[([%d,]+)/([%d,]+)%]")
    if en then
        sc.energy = commaNum(en)
        sc.energyMax = commaNum(enMax)
    end

    local zeni = line:match("ZENI:%s*([%d,]+)")
    if zeni then sc.zeni = commaNum(zeni) end

    local basepl = line:match("BASE POWERLEVEL:%s*([%d,]+)")
    if basepl then sc.basepl = commaNum(basepl) end

    local currpl = line:match("CURR POWERLEVEL:%s*([%d,]+)")
    if currpl then sc.pl = commaNum(currpl) end

    local gainpl = line:match("GAINED PL SINCE LOGON:%s*([%d,]+)")
    if gainpl then sc.gainedPl = commaNum(gainpl) end

    local gainki = line:match("GAINED KI SINCE LOGON:%s*([%d,]+)")
    if gainki then sc.gainedKi = commaNum(gainki) end

    local items, itemsMax = line:match("Items%s*:%s*(%d+)/(%d+)")
    if items then
        sc.items = safeNum(items)
        sc.itemsMax = safeNum(itemsMax)
    end

    local wt, wtMax = line:match("Weight:%s*(%d+)/(%d+)")
    if wt then
        sc.weight = safeNum(wt)
        sc.weightMax = safeNum(wtMax)
    end

    local style = line:match("Style%s*:%s*(%a+)")
    if style then sc.style = style end

    for label, key in pairs({ PKills = "pkills", PDeaths = "pdeaths",
                              MKills = "mkills", MDeaths = "mdeaths",
                              SparWins = "sparwins", SparLoss = "sparloss",
                              SplitWins = "splitwins", SplitLoss = "splitloss",
                              Crits = "crits", Tokens = "tokens" }) do
        local v = line:match(label .. "%s*:?%s*%[(%d+)%]")
        if v then sc[key] = safeNum(v) end
    end

    local eq = line:match("EQ%s+PL Gains Bonus:%s*([%d%.]+)")
    if eq then sc.eqBonus = safeNum(eq) end

    local created = line:match("Created%s*:%s*(.+)$")
    if created then sc.created = trimBoth(created) end
end

-- The block opens on the stats rule and closes on CurrTime. SCORE_MAX is the
-- ceiling that stops a machine that never sees the end from reading forever.
-- The second line of score is "<first> <last> <title>" -- "Solao Bajiuik says
-- no." Two words of name, then whatever the player set as a title, with no
-- delimiter between them. Capped at two, and stops early on a lowercase word so
-- a character with no surname keeps their title intact rather than losing its
-- first word to the name.
local function nameFrom(line)
    local out = {}
    for word in line:gmatch("%S+") do
        if #out >= 2 or not word:match("^%u") then break end
        out[#out + 1] = word
    end
    if #out == 0 then return nil, nil, nil end

    local full = table.concat(out, " ")
    return out[1], out[2], trimBoth(line:sub(#full + 1))
end

local function readHeader()
    local rank = trimBoth(recent[1]):gsub(",%s*$", "")

    -- First name is the one that matters; the surname is kept because it is
    -- there, and shows up on the sheet rather than in the headline.
    local first, last, title = nameFrom(trimBoth(recent[2]))

    -- The profile follows the name off score, which is the only place it is
    -- known: the session is the world, not the character.
    --
    -- Swapped BEFORE anything is written, because useProfile rebinds sc. Doing
    -- it the other way round put this score's name and rank into the previous
    -- character's sheet and then swapped that sheet out from under them.
    if first then profile.use(first) end

    if rank ~= "" and not rank:find("—", 1, true) then sc.rank = rank end

    if first then
        sc.first = first
        sc.last = last
        sc.title = title
        sc.name = first
        if last then sc.name = first .. " " .. last end
    end

    if profile.override ~= "" then
        sc.first = profile.override
        sc.name = profile.override
    end
end

-- 'look self' describes the character properly: build, complexion, height,
-- weight, hair, eyes, and a tail if the race has one.
--
-- Matched line by line rather than as a block. Every line here identifies
-- itself, so there is no state to get stuck in -- which is exactly how the
-- map's block capture went wrong. The only state is the equipment list, and
-- that closes on the first line that is not a slot.
local function parseLook(line)
    -- '%S+' for the same reason as the race: a letter class does not survive
    -- the translation. The name is one token.
    local build, complexion = line:match("^%S+ looks (.+), with an? (.+) col")
    if build then
        sc.build = build
        sc.complexion = complexion
        return true
    end

    local ht, wt = line:match("^You are (%d+'%d+\") and weigh (%d+) pounds")
    if ht then
        sc.height = ht
        sc.weight_lb = safeNum(wt)
        return true
    end

    local hair, eyes = line:match("^%a+ has (.+) colored hair and (.+) eyes")
    if hair then
        sc.hair = hair
        sc.eyes = eyes
        return true
    end

    if line:match("^%a+ has a tail") then
        sc.tail = true
        return true
    end

    if line:find("You are using:", 1, true) then
        sc.eq = {}
        gear.inEq = true
        return false
    end

    if gear.inEq then
        local slot, item = line:match("^<(.+)>%s+(.+)$")
        if slot and sc.eq then
            sc.eq[#sc.eq + 1] = { slot = trimBoth(slot), item = trimBoth(item) }
            return true
        end
        gear.inEq = false
    end
    return false
end

local function feedScore(clean)
    if sheet.inBlock then
        sheet.lines = sheet.lines + 1
        parseScoreLine(clean)
        if clean:find("CurrTime", 1, true) or sheet.lines > sheet.MAX then
            sheet.inBlock = false
            sheet.seen = true
            return true
        end
        return false
    end

    if clean:find("STRENGTH:", 1, true) then
        sheet.inBlock = true
        sheet.lines = 1
        readHeader()
        parseScoreLine(clean)
        return false
    end

    -- look-behind, oldest first; only useful while outside a block
    recent[1] = recent[2]
    recent[2] = recent[3]
    recent[3] = clean
    return false
end

-- What the player's prompt looks like.
--
-- Prompts are configurable on this MUD and a lot of people change them, so
-- nothing below hardcodes a label. A prompt is described by its format string
-- -- the same text 'prompt' prints back -- and that string is compiled into one
-- matcher per line.
--
-- The tokens come from 'help prompt'. Only the ones worth reading are named
-- here; every other token still has to be consumed by the matcher, it just does
-- not feed anything.
-- Every token 'help prompt' documents, not just the ones the panel draws today.
-- A token with no entry here still compiles to a capture group so the pattern
-- stays right; it just has nowhere to put the value. Naming them all means a
-- prompt carrying racial power, biomass or the sector name hands those over for
-- free the moment something wants them.
pr.ROLE = {
    h = "lf",       H = "lfMax",    m = "ki",         M = "kiMax",
    x = "plBase",   X = "plCur",    p = "plBase",     P = "plCur",
    y = "foe",      g = "zeni",     z = "ar",         Z = "arMax",
    a = "align",    S = "style",    Q = "biomass",    G = "plGain",
    K = "kiGain",   b = "battery",  B = "fmCharges",  D = "racialPower",
    e = "racialTimer", d = "drunk", u = "shards",     E = "sector",
    L = "sunlight", t = "clock",    o = "auction",    O = "plColour",
}

-- The ones that are words rather than numbers. Everything else goes through
-- promptNum, which refuses anything that is not a figure -- including 'N/A',
-- which is what a token with nothing to report prints.
-- What a %-token compiles to. num and any are the same pattern today; they are
-- separate names because the two mean different things and one of them will
-- eventually tighten.
pr.P = { num = "(%S*)", any = "(%S*)", txt = "(.*)" }

pr.TEXT = {
    style = true, sector = true, sunlight = true, clock = true,
    auction = true, racialTimer = true, plColour = true,
}

-- Anything that is not a space. It has to be this loose: a token with nothing
-- to report prints 'N/A' rather than a number or an empty string, so a prompt
-- carrying '%y' out of combat reads 'L:100.00 vs N/A Ki:9,010' and a digits-only
-- class matches none of it. What makes a matcher specific is its literals, not
-- its value class.

-- The word tokens hold more than one word. An auction item is 'black socks', a
-- sector is 'Deep Forest', a style is two words as often as one -- and '(%S*)'
-- took the first of them and left the rest to break the match.
--
-- Greedy, and deliberately. A lazy quantifier does not survive the translation
-- (sharp edge 12), and the obvious alternative -- a negated class stopping at
-- the closing bracket -- is the one shape that is actively dangerous here:
-- these fields are written '[%o]' and '[^%]]' reads in JavaScript as "any
-- character, then a ]". What bounds this is the literal that follows it in the
-- format, which is what greedy backtracking is for.

-- Trigger patterns are capped at 1024 characters by the client. Nothing this
-- generates comes close -- the longest is 88 for the stock fight prompt, and the
-- longest format the MUD documents compiles to about 250 -- but a format typed
-- by hand is arbitrary text, and a pattern over the cap is refused at the point
-- it would have been armed rather than at the point it was written.
pr.MAX = 1024

-- '|' is in the set deliberately. It is not special in a real Lua pattern, so
-- leaving it bare reads correctly here and the suite stays green -- but this
-- runtime translates Lua patterns to JavaScript regex, where a bare '|' is
-- ALTERNATION (sharp edge 12). The stock prompt's second line is
-- '(PowerLevel:<%x|%X>)', so its pattern was splitting into
--
--   ^\(PowerLevel:<(\S*)      or      (\S*)>\)
--
-- and that second branch matches any line at all with '>)' on it.
-- One gsub per character. Never a character class.
--
-- Both of these were a single gsub over a class like
-- '([%^%$%(%)%.%[%]%*%+%-%?%|])'. That class holds '%]' -- the one bracket
-- shape CLAUDE.md marks as never exercised here -- and this runtime hands the
-- subject back COMPLETELY UNCHANGED. Measured in the client:
--
--     in [(PowerLevel:<]   out [(PowerLevel:<]   expected [\(PowerLevel:<]
--
-- So every pattern went out unescaped, and unescaped is not a broken regex, it
-- is a valid one meaning something else: '(' opens a group, '|' is alternation.
-- The trigger registered cleanly, matched nothing, and said nothing.
--
-- The Lua side was worse. An unescaped '(' opens a capture, so those matches
-- "succeeded" and every one of the 321 hits was false.
--
-- Real Lua handles the class correctly, which is why the suite stayed green
-- through five releases of this.
--
-- Backslash first in both lists, so escapes added afterwards are not escaped
-- again.
local RX_SPECIAL = { "\\", "^", "$", "(", ")", ".", "[", "]",
                     "*", "+", "-", "?", "|", "{", "}" }
local LUA_SPECIAL = { "%", "^", "$", "(", ")", ".", "[", "]", "*", "+", "-", "?" }

local function promptEsc(s)
    local out = s
    for _, ch in ipairs(LUA_SPECIAL) do
        -- '(%x)' and '%1' rather than '%0'. Every gsub in these six plugins
        -- uses a numbered capture; '%0' for the whole match is not used
        -- anywhere and is not proven to survive translation.
        out = out:gsub("(%" .. ch .. ")", "%%%1")
    end
    return out
end

-- The same literal, escaped for JavaScript instead. Triggers take a real JS
-- regex, untranslated, so this is the only place the two spellings meet.
local function promptRx(s)
    local out = s
    for _, ch in ipairs(RX_SPECIAL) do
        out = out:gsub("(%" .. ch .. ")", "\\%1")
    end
    -- A run of spaces becomes '\s+'. The MUD lines up prompt fields with more
    -- than one space sometimes, and a literal count would miss.
    out = out:gsub("  +", " ")
    out = out:gsub(" ", "\\s+")
    return out
end

-- '%Y' is a newline, not a value: one prompt string can arrive as two separate
-- onLine calls, which is exactly what the stock prompt does. So a format
-- compiles to a LIST of matchers, one per line.
--
-- '&' and '^' each take the character after them as a colour code. They are
-- gone by the time the client hands us a clean line, so they are dropped here
-- too -- which is also why two tokens separated only by a colour cannot be told
-- apart afterwards. promptLearn warns about that rather than guessing.
local function promptCompile(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end

    -- Three colour tags, not two. '&x' foreground, '^x' background, and '}x'
    -- for the expanded palette -- and '&v}O' combines two of them for a
    -- background. Miss one and its letters stay in the literal, so the pattern
    -- is built expecting text the MUD never prints.
    local bare = fmt:gsub("&.", ""):gsub("%^.", ""):gsub("%}.", "")

    local lines, cur, i = {}, "", 1
    while i <= #bare do
        if bare:sub(i, i + 1) == "%Y" then
            lines[#lines + 1] = cur
            cur = ""
            i = i + 2
        else
            cur = cur .. bare:sub(i, i)
            i = i + 1
        end
    end
    lines[#lines + 1] = cur

    local out = {}
    for _, ln in ipairs(lines) do
        local body = trimBoth(ln)
        if body ~= "" then
            local pat, rx, roles, lit, head, k = "", "", {}, "", nil, 1
            while k <= #body do
                if body:sub(k, k) == "%" and k < #body then
                    local code = body:sub(k + 1, k + 1)
                    if head == nil then head = lit end
                    pat = pat .. promptEsc(lit)
                    rx = rx .. promptRx(lit)
                    lit = ""
                    local role = pr.ROLE[code]
                    roles[#roles + 1] = role or false
                    -- Every token is a capture group in the regex too, so a
                    -- trigger callback can read them positionally: captures[n]
                    -- lines up with roles[n].
                    if role and pr.TEXT[role] then
                        pat = pat .. pr.P.txt
                        rx = rx .. "(.*)"
                    elseif role then
                        pat = pat .. pr.P.num
                        rx = rx .. "(\\S*)"
                    else
                        pat = pat .. pr.P.any
                        rx = rx .. "(\\S*)"
                    end
                    k = k + 2
                else
                    lit = lit .. body:sub(k, k)
                    k = k + 1
                end
            end
            pat = pat .. promptEsc(lit)
            rx = rx .. promptRx(lit)
            -- Anchored head and tail, the way the hand-written triggers that
            -- were proven working are. '\s*$' rather than a bare '$': the stock
            -- prompt's second line ends with a space, so a tight tail anchor
            -- misses the one prompt most people are running.
            -- A bare '^'. The residue-tolerant prefix that used to be here was
            -- built on a theory the probe disproved: the line handed to a
            -- trigger is identical to the one onLine gets, colour already gone.
            -- It was also the ONLY thing left separating these patterns from
            -- ones proven to fire, and a '(?:...)' group that is not honoured
            -- shifts every capture index as well as failing to match.
            -- '^\s*' rather than a bare '^'. Each line of the format is
            -- trimmed when it is split, so a format written '%Y PL:(%x/%P)'
            -- loses the leading space that the MUD still prints -- and the
            -- pattern then anchors 'PL:' against a line that begins with one.
            -- Proven both ways: '%Y PL:' failed to gag and '%YPL:' worked.
            rx = "^\\s*" .. rx .. "\\s*$"
            if #roles > 0 then
                -- The Lua pattern is anchored and the regex is not, and that
                -- is deliberate. The pattern reads the CLEANED line, where the
                -- anchor is what stops a tell quoting a prompt from being read
                -- as one. The regex is handed to the trigger engine, which sees
                -- the line before dropAnsiDebris gets to it -- sharp edge 10,
                -- the client leaves colour parameters like '0;37m' on the front
                -- once the escape itself has been eaten. Anchored, that never
                -- matches; the old unanchored gag survived it, which is exactly
                -- why the prompt's first line kept vanishing and its second did
                -- not.
                local hasLf = false
                for _, r in ipairs(roles) do
                    if r == "lf" then hasLf = true end
                end
                out[#out + 1] = { pat = "^" .. pat, rx = rx, roles = roles,
                                  carriesLf = hasLf, fmt = fmt,
                                  lineNo = #out + 1, hits = 0,
                                  head = trimBoth(head or "") }
            end
        end
    end

    if #out == 0 then return nil end

    -- A format ending in '%Y' renders a blank line after the prompt. There is
    -- no matcher for it -- an empty segment has no literals and no tokens -- so
    -- the gag has to be told it is coming.
    if trimBoth(lines[#lines]) == "" then
        for _, m in ipairs(out) do m.blankAfter = true end
    end

    -- Each line keeps a handle on its siblings. Matching any one line of a
    -- prompt arms the gag for all of them, rather than each line leaking once
    -- before it is recognised -- which for a two-line prompt means the second
    -- half sitting in the scroll on its own until you have seen it.
    for _, m in ipairs(out) do m.kin = out end

    return out
end

-- Every prompt this MUD ships or documents, so the common cases need no setup
-- at all: the stock pair, the short pair off the website, and the four in
-- 'help prompt'. A player on any of these never types a command.
--
-- The stock pair is written from what it prints rather than copied from the
-- server -- there is no way to read another player's format -- and it is
-- checked against 15,000 real lines in the suite.
pr.KNOWN = {
    "(LifeForce:<%h> Ki:<%m>)%Y(PowerLevel:<%x|%X>)",
    -- The stock FIGHT prompt is one line: lifeforce, the enemy, and Ki with the
    -- K shouting. No powerlevel line under it.
    "(LifeForce:<%h> Enemy:<%y> KI:<%m>)",
    -- And the variant that has been seen with a second line carrying armour,
    -- which closes with a bracket it never opened. Kept as the MUD printed it
    -- rather than tidied, because it is matched literally. Its first line is
    -- identical to the one above; promptRebuild drops the duplicate.
    "(LifeForce:<%h> Enemy:<%y> KI:<%m>)%Y(PowerLevel:<%x|%X>) Armor:<%z/%Z>)",
    "L:%h Ki:%m PL:(%x/%P) %D %e $%g",
    "L:%h Ki:%m PL:(%x/%P) $%g",
    "L:%h vs %y Ki:%m PL:(%x/%P) AR:%z %D %e",
    "L:%h vs %y Ki:%m PL:(%x/%P) AR:%z",
    "LF:[%h] Ki:[%m/%M] RP[%D] Time:%e%YPL:[%x|%X] [$%g]",
    "LF:[%h/%H] Ki:[%m/%M] RP[%D]%YPL:[%x|%X] [$%g]",
    "LF:[%h] Foe:[%y] Ki:[%m] RP[%D] Time:%e%YPL:[%x|%X] A:[%z/%Z]",
    "LF:[%h] Foe:[%y] Ki:[%m]RP[%D]%YPL:[%x|%X] A:[%z/%Z]",
}

-- Learned formats go in front of the built-ins: a player who has told us what
-- their prompt is should not be matched by something that merely looks close.

-- Which of the two the header just announced, and the format learned for each.
-- Kept apart from promptLearned -- which is a flat list for compiling -- because
-- the settings page needs a box per prompt and has to know which is which.
-- Which command was last issued with an argument, so the MUD's "Replacing old
-- prompt of:" can be answered with a read-back of the right one.
pr.learnedFor = { prompt = nil, fprompt = nil }

-- What a 'prompt' or 'fprompt' round trip is waiting for. One table rather than
-- three names -- the chunk is at Lua 5.1's 200-local ceiling and these three
-- describe one thing between them.
--   expect  a format line may be next
--   want    which of the two we asked about
--   echo    a command to send once the answer has been read
local ask = { expect = false, want = nil, echo = nil }

-- What the settings fields hold while they are being typed into, which is not
-- the same as what is in force. Typing captures here and nothing is applied or
-- redrawn until a field is submitted -- rebuilding the panel on a keystroke
-- replaces the input and takes the focus with it.
local edit = { prompt = "", fprompt = "", avatar = "", name = "",
               fname = "", furl = "", fpat = "" }

-- Which compiled lines this session has actually seen. The gag is built from
-- these rather than from all ten built-in formats -- registering a trigger for
-- every prompt the MUD documents would hide other players' pasted prompts.
pr.arm = nil
-- Set when the line just seen was the last line of a prompt whose format ends
-- in a newline. The blank line that follows is part of the prompt and goes with
-- it when gagging, but only then -- a bare '^$' trigger would flatten every
-- blank line the MUD prints.

-- Longest pattern first inside each group. A matcher is anchored at the head
-- but not at the tail -- deliberately, because a prompt can carry the next line
-- of output on its tail when the server sends no GA -- so the plain
-- '(PowerLevel:<a|b>)' would otherwise match the fight prompt's second line and
-- throw the armour away. More specific wins.
local function promptAdd(into, list)
    local batch = {}
    local haveRx = {}
    for _, fmt in ipairs(list) do
        local c = promptCompile(fmt)
        if c then
            for _, m in ipairs(c) do
                -- Formats overlap: the stock fight prompt's only line is also
                -- the first line of the armour variant. Registering the same
                -- pattern twice would double every hit count and arm two
                -- triggers where one will do.
                if not haveRx[m.rx] then
                    haveRx[m.rx] = true
                    batch[#batch + 1] = m
                end
            end
        end
    end
    table.sort(batch, function(l, r) return #l.pat > #r.pat end)
    for _, m in ipairs(batch) do into[#into + 1] = m end
end

-- 9,010 -> 9010, 3.048m -> 3048000. Suffixes run k/m/b/t on this MUD.
local MULT = { k = 1000, m = 1000000, b = 1000000000, t = 1000000000000 }

-- Digits and suffix read independently and neither by counting characters:
-- string index arithmetic is unreliable here (sharp edge 5) and a value can be
-- 'N/A' rather than a number at all, which must come back nil and not zero.
local function promptNum(v)
    if type(v) ~= "string" then return nil end
    local s = trimBoth(v)
    if s == "" then return nil end

    local body = s:gsub(",", "")
    local suf = body:match("([kmbt])$")
    local digits = body:match("^([%d%.]+)")
    if type(digits) ~= "string" or digits == "" then return nil end

    local n = safeNum(digits)
    if not n then return nil end
    if type(suf) == "string" and MULT[suf] then n = n * MULT[suf] end
    return n
end

-- What the prompt has told us, parsed. Written per line as each arrives rather
-- than buffered until the whole prompt has gone by: the lines are separate
-- lines, one of them can be missing, and reading fields independently is the
-- rule this plugin has broken three times already.
local charState = {}

local function promptRebuild()
    pr.cur.set = {}
    -- Each stage says which one failed. A single pcall further up reports
    -- "something threw" and there are four candidates behind it.
    local ok, err = pcall(promptAdd, pr.cur.set, pr.cur.learned)
    if not ok then pd.buildErr = "learned: " .. tostring(err) end
    ok, err = pcall(promptAdd, pr.cur.set, pr.KNOWN)
    if not ok then pd.buildErr = "known: " .. tostring(err) end
end

-- Adding one. A format nobody has described is learned by asking the MUD: type
-- 'prompt' and it prints the string back, which is the only reliable source --
-- there is no way to read it off the wire and no way to read another player's.
--
-- Two tokens separated by nothing but a colour code cannot be told apart once
-- the colour is stripped, and 'help prompt' recommends exactly that shape
-- (PL:[&w%x&z%X&W]). Saying so beats reading one number and inventing the
-- other.
local function promptLearn(fmt, quiet)
    local text = trimBoth(fmt)
    if text == "" then return false end

    local compiled = promptCompile(text)
    if not compiled then
        if not quiet then
            echo(TAG .. "that does not read as a prompt format.", "#ff6666")
        end
        return false
    end

    local bare = text:gsub("&.", ""):gsub("%^.", ""):gsub("%}.", "")
    local a, b = bare:match("%%(%w)%%(%w)")
    if type(a) == "string" and type(b) == "string" then
        echo(TAG .. "'%" .. a .. "' and '%" .. b .. "' have nothing between them"
            .. " but colour, which", "#ffb02e")
        echo("          is gone before this plugin sees the line. Put a"
            .. " separator between them", "#ffb02e")
        echo("          -- '/' or '|' -- and run 'prompt' again.", "#ffb02e")
    end

    for _, m in ipairs(compiled) do
        local widest = #m.rx
        if widest > pr.MAX then
            echo(TAG .. "that format is too long to gag -- it needs a trigger of "
                .. widest .. " characters and the limit is " .. pr.MAX .. ".",
                "#ffb02e")
            echo("          It will still be read; only hiding it is off.", "#ffb02e")
        end
    end

    for _, have in ipairs(pr.cur.learned) do
        if have == text then return false end
    end

    pr.cur.learned[#pr.cur.learned + 1] = text
    promptRebuild()
    pcall(pr.arm)
    if not quiet then
        echo(TAG .. "learned your prompt: " .. #compiled .. " line(s), "
            .. "reading " .. tostring(pr.cur.roles(compiled)) .. ".", panel.C.energy)
    end
    return true
end

-- What a compiled format actually feeds the panel, for the message above.
--
-- Assigned rather than declared. 'local f' then 'function f()' is ordinary Lua
-- -- the definition binds the local -- but the transpiler emits 'let f' and
-- then a JavaScript function DECLARATION of the same name, which is an illegal
-- shadow and refuses to load the plugin at all:
--
--   loadPlugin(): Cannot declare a function that shadows a let/const/class/
--   function variable 'promptRoles'
pr.cur.roles = function(compiled)
    local seen, order = {}, {}
    for _, m in ipairs(compiled) do
        for _, role in ipairs(m.roles) do
            if role and not seen[role] then
                seen[role] = true
                order[#order + 1] = role
            end
        end
    end
    if #order == 0 then return "nothing" end
    return table.concat(order, ", ")
end

-- Reads every role off one line, or nil if the line is not a prompt at all.
-- Anchored at the head, which is what keeps a tell carrying prompt-shaped text
-- out: "Solao tells you: 'LF:<88> Ki:<900>'" has the fields but not at the
-- front.
local function promptScan(text)
    for _, m in ipairs(pr.cur.set) do
        -- Captured into named locals rather than '{ text:match(pat) }'. A
        -- multi-value return wrapped in a table constructor is the shape sharp
        -- edge 4 is about, and no format here needs more than ten -- the widest
        -- documented one uses eight.
        local c1, c2, c3, c4, c5, c6, c7, c8, c9, c10 = text:match(m.pat)
        local caps = { c1, c2, c3, c4, c5, c6, c7, c8, c9, c10 }
        -- type(), not '~= nil'. A failed match hands back undefined here, and
        -- undefined is truthy AND not equal to nil (sharp edges 2 and 17) -- so
        -- 'c1 ~= nil' was true for every line that had ever gone past. diag said
        -- so and I did not read it: luaTries and luaHits were identical, 261 of
        -- 261, which cannot happen if most lines are not prompts.
        --
        -- It made every non-prompt line look like a prompt, which is what was
        -- ending an item capture on its own header line.
        if type(c1) == "string" then
            for _, sib in ipairs(m.kin or { m }) do
                if sib.rx and not pr.cur.used[sib.rx] then
                    pr.cur.used[sib.rx] = true
                    pr.cur.order[#pr.cur.order + 1] = sib.rx
                    pr.cur.sig = pr.cur.sig .. sib.rx .. "\n"
                end
            end
            pr.cur.blank = m.blankAfter == true
            local got = { head = m.head }
            for n, role in ipairs(m.roles) do
                local v = caps[n]
                if role and type(v) == "string" and v ~= "" then got[role] = v end
            end
            return got
        end
    end
    return nil
end

local function promptRead(clean)
    if not pr.cur.set then promptRebuild() end
    local text = trimBoth(clean)
    if text == "" then return nil end

    pd.tries = pd.tries + 1
    local ok, got = pcall(promptScan, text)
    if not ok then
        pd.readErr = tostring(got)
        return nil
    end
    if got then pd.hits = pd.hits + 1 end
    return got
end

-- The opponent's lifeforce. The compiled formats cover it for anyone whose
-- prompt we know or have been told; these four shapes stay behind that as a
-- last resort for a prompt nobody has described, since they cost a failed match
-- and nothing else.
-- capOf lives further down the file than this does, and a file-scope local used
-- above its declaration resolves as a nil global (sharp edge 6).
local function capOfFoe(s, pat)
    local m = s:match(pat)
    if type(m) ~= "string" then return nil end
    if m == "" then return nil end
    return m
end

local function foeToken(clean)
    local seen = promptRead(clean)
    if seen and seen.foe then return seen.foe end

    -- '(%S+)' rather than '([%d%.]+)'. %d is safe in a class and %. is not
    -- proven either way, and there is no reason to find out here: %S is the one
    -- class this runtime is known to honour, and safeNum is a better filter than
    -- a character class anyway -- it refuses NaN, empty and undefined, which a
    -- pattern cannot.
    local f = capOfFoe(clean, "Enemy:<(%S+)>")
        or capOfFoe(clean, "Enemy:%[(%S+)%]")
        or capOfFoe(clean, "Foe:<(%S+)>")
        or capOfFoe(clean, "Foe:%[(%S+)%]")
    return f
end

-- Is this a prompt line at all, and what does it call lifeforce? A compiled
-- match answers both and names the label itself. The find() pair behind it is
-- the original test, kept for a prompt no format describes.
--
-- Plain find throughout down there -- '[' is a pattern special, so a pattern
-- find would be a malformed-pattern error rather than a miss, and inside
-- onLine's pcall that looks like the panel simply stopping.
local function notePrompt(clean)
    local low = clean:lower()
    if low:find("ki:", 1, true) then
        -- Anchored at the head, past an opening bracket if the format has one.
        -- Unanchored, "Solao tells you: 'LF:<88> Ki:<900>'" carries both words
        -- and read as a prompt, which cleared the enemy bar in the middle of a
        -- fight every time someone quoted their own prompt at you.
        local at = low:gsub("^%(", "")
        if at:sub(1, 10) == "lifeforce:" then
            pr.cur.tag = "LifeForce:"
            return true
        end
        if at:sub(1, 3) == "lf:" then
            pr.cur.tag = "LF:"
            return true
        end
    end

    -- A prompt the pair above does not know. The compiled formats still answer
    -- whether this is one, which is what makes the fight-end clear work for a
    -- player whose prompt says neither of those words.
    --
    -- promptTag is deliberately NOT set from here. It is concatenated raw into
    -- a JavaScript regex by applyGag, and a format's literal head routinely
    -- carries '(' or '[' -- which is a broken regex rather than a near miss.
    -- Widening the gag needs that grammar fixed first, and its test with it.
    -- The second value says whether this line carries lifeforce, which is the
    -- line the opponent appears on. A prompt line that never shows the enemy
    -- cannot mean the fight is over by not showing one -- the stock fight
    -- prompt's second line is exactly that, and treating it as a signal cleared
    -- the enemy bar on every other line of a fight.
    local seen = promptRead(clean)
    if seen then return true end
    return false
end

-- Does THIS line carry lifeforce? Its own function, returning one value.
--
-- It used to be the second half of notePrompt's return, and that is what kept
-- the enemy bar off the panel for good. 'local isPrompt, carriesLf =
-- notePrompt(clean)' cannot be trusted here when the function returns two
-- values on some paths and one on others -- the stock fight prompt's SECOND
-- line takes the one-value path, and the clear below fired on it anyway:
--
--   opponent last cleared by:
--     no opponent on [(PowerLevel:<3.097m|3.097m>) Armor:<10,400/10,000>)]
--
-- Line one of the prompt set the opponent and line two cleared it, every
-- round, so it never survived to be drawn. Sharp edge 13 was written for
-- exactly this and applied to the reading of fields but not to the guard: one
-- question, one call, one value.
local function promptCarriesLf(clean)
    local low = clean:lower()
    if low:find("ki:", 1, true) then
        local at = low:gsub("^%(", "")
        if at:sub(1, 10) == "lifeforce:" then return true end
        if at:sub(1, 3) == "lf:" then return true end
    end

    -- And the compiled formats, for a prompt that says neither word. The short
    -- format off the website is 'L:%h vs %y Ki:%m ...' -- lifeforce with no
    -- label this could look for.
    --
    -- type(), not 'seen.lf ~= nil'. A role the line did not carry comes back
    -- undefined, which is truthy AND not equal to nil, so the old test called
    -- every matched prompt a lifeforce line.
    local seen = promptRead(clean)
    if type(seen) == "table" and type(seen.lf) == "string" then return true end
    return false
end

local function feedFoe(clean)
    local isPrompt = notePrompt(clean)

    if clean:find("Enemy", 1, true) or clean:find("Foe", 1, true) then
        foe.saw = clean
    end

    -- The MUD says so outright when a fight ends, and it is the only signal
    -- here that is not an inference. 801 of them across two days of transcript,
    -- one wording. Everything below this is a backstop for a fight that ends
    -- some other way -- fleeing, or the thing wandering off.
    if clean:find("Total powerlevel gained this fight", 1, true) then
        if foe.val then
            foe.val = nil
            foe.why = "fight ended: total powerlevel line"
            return true
        end
        return false
    end

    local f = foeToken(clean)
    local fv = nil
    if f then fv = safeNum(f) end
    if foe.saw == clean and foe.saw ~= "" then
        foe.got = "[" .. tostring(f) .. "] -> " .. tostring(fv)
    end
    if fv then
        foe.val = fv
        foe.at = os.clock()
        return true
    end

    -- a prompt with no Foe on it is the fight ending, and a surer signal than
    -- the timeout behind it
    -- Two independent tests, each its own call. A prompt line that never shows
    -- an opponent cannot mean the fight is over by not showing one.
    if foe.val and isPrompt and promptCarriesLf(clean) then
        foe.val = nil
        foe.why = "no opponent on [" .. clean .. "]"
        return true
    end
    return false
end

-- A transformation line just went past. Substring, case-insensitive, first form
-- to match wins. The comparison against the CURRENT form matters: the same
-- announcement can print more than once, and re-rendering the same portrait for
-- each copy is wasted work.
-- Which form a line belongs to. Substring, case-insensitive, and the LONGEST
-- matching pattern wins rather than the first out of pairs().
--
-- pairs() order is arbitrary and these announcements contain one another:
-- 'Super Saiyan' is a substring of the Super Saiyan 2 line, so the shorter
-- pattern kept claiming the longer form's announcement and the second
-- transformation never showed. The revert line names the form it is leaving,
-- for the same reason, so base never matched either -- and a form stuck that
-- way outranks the manual avatar, which is how 'dbchar avatar' looked broken.
-- A DIRECT hit outranks a wrapped one, whatever the lengths.
--
-- Without that rule the wrap allowance below eats its own feet: 'You ascend to
-- Super Saiyan' sits inside 'You ascend to Super Saiyan 2', so the shorter
-- announcement matched the longer form and SS could never claim its own line.
-- Fixing the pairs() order bug by length alone just moves it.
local function matchForm(lowLine)
    local bestName, bestUrl, bestLen = nil, nil, -1
    local bestDirect = false
    for name, f in pairs(form.ALL) do
        if type(f) == "table" and has(f.pat) then
            local pat = tostring(f.pat):lower()
            local direct = lowLine:find(pat, 1, true) ~= nil
            local hit = direct

            -- The MUD wraps a long announcement at the terminal width, so a
            -- message saved from two of those lines can never appear inside any
            -- ONE of them -- a form that works while its message is short and
            -- never fires once it is long. Each printed line IS a piece of the
            -- stored message, so a line found inside the pattern counts too.
            -- The 20-character floor stops a short incidental line living
            -- inside somebody's saved announcement by accident.
            if not hit and #lowLine >= 20 and pat:find(lowLine, 1, true) then
                hit = true
            end

            local better = false
            if hit then
                if direct and not bestDirect then
                    better = true
                elseif direct == bestDirect and #pat > bestLen then
                    better = true
                end
            end
            if better then
                bestLen = #pat
                bestDirect = direct
                bestName = name
                bestUrl = f.url
            end
        end
    end
    return bestName, bestUrl
end

-- The four lines that actually report a posture, all confirmed in the
-- transcript rather than guessed at.
local function feedPosture(clean)
    local was = posture
    if clean == "You collapse into a deep sleep." then posture = "sleeping"
    elseif clean == "You wake and climb quickly to your feet." then posture = "standing"
    elseif clean == "You meditate peacefully, collecting energy from the cosmos." then
        posture = "meditating"
    elseif clean == "You are already standing." then posture = "standing"
    elseif clean == "You dig down into the dirt, ready to do battle!" then
        posture = "ready"
    end
    return posture ~= was
end

local function feedForm(clean)
    if clean == "" then return false end

    -- Both values into locals: a two-value return nested into a call arrives as
    -- a wrapped pair in this runtime.
    local newName, newUrl = matchForm(clean:lower())
    if not newName then return false end

    if newUrl == "base" then
        newUrl = ""
        newName = ""
    end
    if form.url == newUrl and form.name == newName then return false end
    form.url = newUrl
    form.name = newName
    return true
end

----------------------------------------------------------------------
-- gmcp
----------------------------------------------------------------------

-- The payload arrives as { char = { vitals = {...} } }, so it can reach us
-- either already unwrapped or still inside its parent -- and the callback
-- argument is not always the complete object, which is why the store is asked
-- as well. Same shape as Map.Definition and Map.Snapshot.
local function unwrapVitals(v)
    if type(v) ~= "table" then return nil end
    if has(v.hit) or has(v.energy) or has(v.pl) then return v end
    if type(v.vitals) == "table" then return v.vitals end
    if type(v.char) == "table" and type(v.char.vitals) == "table" then
        return v.char.vitals
    end
    return nil
end

local function acceptVitals(data)
    -- 'v', not 'src'. There is a file-scope table called src now, and a local
    -- of the same name makes it unreachable from this whole function -- not
    -- just after the declaration, but anywhere in it (sharp edge 15).
    local v = unwrapVitals(data)
    if not v then v = unwrapVitals(getGMCPData("char.vitals")) end
    if not v then v = unwrapVitals(getGMCPData("char")) end
    if not v then return false end

    vit = {
        hit       = safeNum(v.hit),
        maxHit    = safeNum(v.max_hit),
        energy    = safeNum(v.energy),
        maxEnergy = safeNum(v.max_energy),
        basepl    = safeNum(v.basepl),
        pl        = safeNum(v.pl),
    }
    nego.done = true
    return true
end

-- char.info: { name, race, rank }.
--
-- The name is the important one. profileKey has only ever come from a parsed
-- score header, so everything written before the first typed 'score' landed
-- under whichever profile was stored last -- which is how a session that came
-- up knowing nothing wrote an empty profile over a real one. GMCP names the
-- character on connect, before any of that can happen.
--
-- Lowercased, because the profile key is and a key that varies by case forks a
-- second empty profile for the same character.
-- The whole Char tree, however it arrived.
--
-- Read once and indexed into, rather than a handler and an unwrap dance per
-- package. The callback argument is not trustworthy for nested data -- proven
-- for Map, where the leaf sometimes arrives and sometimes its parent does --
-- so the store is asked as well and whichever answers with the tree wins.
local function charTree(data)
    local root = data
    if type(root) == "table" and type(root.char) == "table" then root = root.char end
    local function looksRight(t)
        if type(t) ~= "table" then return false end
        return type(t.info) == "table" or type(t.stats) == "table"
            or type(t.equipment) == "table" or type(t.inventory) == "table"
    end
    if looksRight(root) then return root end
    local stored = getGMCPData("char")
    if type(stored) == "table" and type(stored.char) == "table" then
        stored = stored.char
    end
    if looksRight(stored) then return stored end
    return nil
end

local function acceptInfo(v)
    if type(v) ~= "table" then return false end

    -- One guard per field. A missing one arrives as undefined, which is truthy
    -- and is not nil, so they are read independently rather than in pairs.
    local got = false
    local nm = v.name
    if type(nm) == "string" and trimBoth(nm) ~= "" and trimBoth(nm) ~= "undefined" then
        nm = trimBoth(nm)
        -- The profile FIRST. useProfile swaps the whole sc table for the stored
        -- one, so a name written before it is thrown away by it -- which is
        -- exactly what happened, and the headline read 'Unknown' with the
        -- profile correctly keyed on 'solao' right beside it.
        local key = nm:lower()
        if key ~= profile.key then
            profile.use(key)
            got = true
        end
        if sc.first ~= nm then
            sc.first = nm
            if not has(sc.name) then sc.name = nm end
            got = true
        end
    end

    if src.stats == "gmcp" then
        local rc = v.race
        if type(rc) == "string" and trimBoth(rc) ~= "" and trimBoth(rc) ~= "undefined"
            and sc.race ~= trimBoth(rc) then
            sc.race = trimBoth(rc)
            got = true
        end
        local rk = v.rank
        if type(rk) == "string" and trimBoth(rk) ~= "" and trimBoth(rk) ~= "undefined"
            and sc.rank ~= trimBoth(rk) then
            sc.rank = trimBoth(rk)
            got = true
        end
    end

    -- The sheet is gated on having seen a character at all, and now we have.
    -- The rows GMCP cannot fill stay empty until a score is typed; row() drops
    -- an empty one rather than printing a blank.
    if got then sheet.seen = true end
    return got
end

-- char.stats: the four attributes, the armour pair, zeni.
--
-- Two things here the score line does not carry at all. The armour MAXIMUM --
-- score gives '10400, exceptionally crafted' and no ceiling, which is why that
-- bar has read '--' since it was written. And a daily gains figure beside the
-- session one; score only has SINCE LOGON.
--
-- The bases are integers here where the score line has decimals (126 against
-- 126.23). Nothing has ever read the decimal: the parser puts it in
-- sc["strength-real"] and no renderer touches it. So this loses nothing on
-- screen.
local function acceptStats(v)
    if src.stats ~= "gmcp" then return false end
    if type(v) ~= "table" then return false end

    local got = false
    -- Nested two deep. 'v.strength.current' throws if strength is missing
    -- rather than yielding nil, and a guard cannot share the expression with
    -- the call it guards (sharp edge 16), so the table is taken first.
    for _, name in ipairs({ "strength", "speed", "spirit", "fortitude" }) do
        local pair = v[name]
        if type(pair) == "table" then
            local cur = safeNum(pair.current)
            if cur ~= nil and sc[name] ~= cur then
                sc[name] = cur
                got = true
            end
            local base = safeNum(pair.base)
            if base ~= nil then sc[name .. "-real"] = base end
        end
    end

    local ar = v.armor
    if type(ar) == "table" then
        local cur = safeNum(ar.current)
        local max = safeNum(ar.max)
        if cur ~= nil and sc.armorVal ~= cur then
            sc.armorVal = cur
            got = true
        end
        -- The ceiling the prompt and the score line never had.
        if max ~= nil and max > 0 and sc.armorMax ~= max then
            sc.armorMax = max
            got = true
        end
    end

    local zeni = safeNum(v.zeni)
    if zeni ~= nil and sc.zeni ~= zeni then
        sc.zeni = zeni
        got = true
    end

    local gains = v.gains
    if type(gains) == "table" then
        local ses = gains.session
        if type(ses) == "table" then
            local gp = safeNum(ses.pl)
            if gp ~= nil then sc.gainedPl = gp end
            local gk = safeNum(ses.ki)
            if gk ~= nil then sc.gainedKi = gk end
        end
    end

    return got
end

-- Whichever of our plugins connects first does the handshake. Add merges, and
-- 'Map 1' brings char stats with it, so one negotiation serves both panels --
-- and only one of them should be doing it.
--
-- Scouter owns the handshake when it is installed: it has the retry schedule
-- and the negotiation diagnostics, and a plugin that cannot retry is the wrong
-- one to be responsible for something that can go unanswered. This asks, on a
-- synchronous bus, and only negotiates when nothing answers.
--
-- The stamp stays as the cross-load backstop, but it cannot close the race on
-- its own: setVariable is debounced, so two plugins starting in the same tick
-- both read 'nobody has yet' before either write lands.
-- char.effects, in the order the server sent them: { name, cat, val }.
--
-- A LIST rather than a map, because the pills are drawn in order and the
-- server's order is as good as any. Rebuilt whole on every packet: an effect
-- that has ended is simply absent from the next one.
local effects = {}
-- A packet having ARRIVED is not the same as nothing being on. Before the
-- first one, the pl-against-base guesses below still stand.
local effectsSeen = false

local gmcpOwned = false

local function ensureGmcp()
    if gmcpOwned then return false end
    -- Ask. An owner answers during this call, not after it.
    pcall(function() emit("dbi.gmcp.who") end)
    if gmcpOwned then return false end

    local last = safeNum(getVariable(HELLO.key, "global"))
    local now = os.time()
    if last and (now - last) < HELLO.window then return false end

    setVariable(HELLO.key, tostring(now), "global")
    -- Two-arg form: the client JSON-encodes the table, so the wire string and
    -- its escaping are not this plugin's problem.
    sendGMCP("Core.Hello", { client = "MudForge", version = "1.2.2035" })
    sendGMCP("Core.Supports.Add", { "Map 1" })
    return true
end

----------------------------------------------------------------------
-- typography, matching Scouter: follow the terminal rather than dictate
----------------------------------------------------------------------

local function readTerminalFont()
    local ok, fn = pcall(function() return _G["getTerminalFont"] end)
    if not ok or type(fn) ~= "function" then return end

    local good, f = pcall(fn)
    if not good or type(f) ~= "table" then return end

    if type(f.family) == "string" and f.family ~= "" then
        panel.font.family = f.family:gsub("[;}<>]", "")
    end
    local n = safeNum(f.size)
    if n and n >= 6 and n <= 72 then panel.font.size = math.floor(n) end
end

local function chromeFont()
    if panel.font.family ~= "" then return panel.font.family .. "," .. panel.font.fallback end
    return panel.font.fallback
end

local function barSize()  return math.max(7, math.floor(panel.font.size * 0.60 * panel.font.scale)) end
local function bodySize() return math.max(9, math.floor(panel.font.size * 0.82 * panel.font.scale)) end

----------------------------------------------------------------------
-- rendering
----------------------------------------------------------------------

-- Anything that could close a CSS url("...") and start a new declaration.
-- Checked with a plain find, never a pattern: plain means the runtime does no
-- translation at all, which is the only way to be sure of a check whose whole
-- job is to stop something being injected.
local URL_BAD = { '"', "'", "(", ")", "<", ">", ";", "\\", " ", "\t" }

-- Does this already point at an image file?
local function looksLikeImage(u)
    local low = trimBoth(u):lower():gsub("%?.*$", "")
    for _, ext in ipairs({ ".png", ".jpg", ".jpeg", ".gif", ".webp" }) do
        if low:sub(-#ext) == ext then return true end
    end
    return false
end

-- Pull the canonical image out of a share page.
--
-- An imgur album link is a web page, not a picture, so putting one in a CSS
-- url() fetches markup and shows nothing. Nearly every host that serves share
-- pages advertises the real file as og:image, which is a better thing to read
-- than whichever i.imgur URL happens to appear first in the markup -- that one
-- is usually the thumbnail.
--
-- Greedy only. A lazy quantifier does not survive this runtime's pattern
-- translation, so '[^>]*' does the work of '.-' and cannot leave the tag.
local function metaImage(body)
    local text = tostring(body or "")

    local url = text:match('og:image"[^>]*content="([^"]*)"')
    if not url then url = text:match('content="([^"]*)"[^>]*og:image"') end
    -- last resort, and .png before .jpg because imgur's thumbnail is the jpg
    if not url then
        local id = text:match("i%.imgur%.com/(%w+)%.png")
        if id then url = "https://i.imgur.com/" .. id .. ".png" end
    end
    if not url then return nil end

    -- og:image often carries a cache-busting query; the file is the same
    url = url:gsub("%?.*$", "")
    if url == "" then return nil end
    return url
end

-- A local path in any form someone would type one.
local function looksLocal(u)
    local low = trimBoth(u):lower()
    return low:sub(1, 1) == "/" or low:sub(1, 2) == "~/" or low:sub(1, 7) == "file://"
end

-- Rejects rather than repairs, and http(s) only.
--
-- Local files are not reachable from widget HTML at all. Not a permission and
-- not a folder: this client's own helper converts a path to
-- 'asset://localhost/...' rather than file://, and the asset protocol is not
-- enabled in its build, so there is no scheme the webview will fetch a local
-- image over. ~/MudForge/plugin-files is where io.open is scoped, which is a
-- different question entirely and the one that sent this sideways.
--
-- Accepting a path anyway would set an avatar that never appears and leave the
-- race fallback on screen with nothing to explain it.
--
-- This also used to accept any string beginning https:// and concatenate it
-- straight into the stylesheet.
local function safeAvatarUrl(s)
    local u = trimBoth(s)
    if u == "" then return "" end

    local low = u:lower()
    local ok = low:sub(1, 8) == "https://" or low:sub(1, 7) == "http://"
    if not ok then return "" end

    for _, ch in ipairs(URL_BAD) do
        if u:find(ch, 1, true) then return "" end
    end
    return u
end

-- Turn whatever someone pasted into a url the webview can actually paint, then
-- hand it to onOk. Errors are echoed here rather than returned, so a caller is
-- three lines instead of fifteen.
--
-- A SHARE PAGE IS NOT A PICTURE. 'https://imgur.com/TkzGUH7' serves text/html,
-- so in a CSS url() it fetches markup and draws an empty frame -- no error, no
-- broken-image glyph, just a portrait that never appears. The avatar command
-- has asked pages for their og:image for a while; 'dbchar form' went straight
-- to safeAvatarUrl and stored the page url as-is, which is why a set of forms
-- built by pasting from a browser's address bar all silently did nothing.
--
-- onOk may run LATER: the page path is an http callback. Do the work inside it.
local function applyImage(url, onOk)
    local u = trimBoth(url)

    if looksLocal(u) then
        echo(TAG .. "a local file cannot be shown in a widget by this client --", "#ff6666")
        echo(TAG .. "there is no scheme its webview will fetch one over, whatever", "#ff6666")
        echo(TAG .. "the File System Access permission says.", "#ff6666")
        echo(TAG .. "Upload it and use the url. Anything serving https works.", "#ffb02e")
        return
    end

    -- The character set and the scheme first, before deciding whether to go and
    -- look: a url carrying a quote or a space is one this will never accept, so
    -- there is no reason to send a request to it.
    local clean = safeAvatarUrl(u)
    if clean == "" then
        echo(TAG .. "that takes an http(s) url to an image.", "#ff6666")
        echo(TAG .. "A path with a space or a quote in it is refused.", "#ff6666")
        return
    end

    if looksLikeImage(clean) or clean:lower():sub(1, 8) ~= "https://" then
        onOk(clean)
        return
    end
    u = clean

    -- Still a page. Ask it which image it means.
    local ok, httpTable = pcall(function() return _G["http"] end)
    if not ok or type(httpTable) ~= "table" or type(httpTable.get) ~= "function" then
        echo(TAG .. "that is a page, not an image, and this build has no", "#ff6666")
        echo(TAG .. "http to go and look. Use the direct image url.", "#ff6666")
        return
    end
    echo(TAG .. "that looks like a page; asking it for the image...", panel.C.energy)
    local asked = u
    httpTable.get(u, nil, function(status, body, err)
        if err or not status or status >= 400 then
            echo(TAG .. "could not read " .. asked .. ": " .. tostring(err or status),
                "#ff6666")
            return
        end
        local found = metaImage(body)
        if not found then
            echo(TAG .. "no image advertised on that page. Open it, right-click", "#ff6666")
            echo(TAG .. "the picture, copy the image address, and use that.", "#ff6666")
            return
        end
        local clean = safeAvatarUrl(found)
        if clean == "" then
            echo(TAG .. "that page pointed at something unusable: " .. found, "#ff6666")
            return
        end
        onOk(clean)
    end)
end

-- CSS backgrounds rather than <img>: an avatar that 404s leaves an empty frame
-- instead of a broken-image glyph, which is the failure people actually get.
local function avatarCss()
    -- the active form outranks the manual override, which outranks the race
    local url = form.url
    if url == "" then url = avatarUrl end
    if url == "" then
        local race = slug(sc.race)
        local sex = slug(sc.sex)
        if race == "" then
            url = AVATAR_BASE .. "/generic.png"
        elseif sex == "" then
            url = AVATAR_BASE .. "/" .. race .. ".png"
        else
            url = AVATAR_BASE .. "/" .. race .. "-" .. sex .. ".png"
        end
    end
    -- ONE image, then a gradient that always resolves.
    --
    -- There used to be a generic portrait layered between them as a 404 guard.
    -- It was invisible while the top layer was 'cover' -- covering is what hid
    -- it -- and the moment the top became 'contain' it showed through the
    -- letterbox bars, so the panel drew two portraits at once.
    --
    -- The guard is not worth that. A url that 404s now falls to the gradient,
    -- which is what the frame fell back to before any art existed at all and
    -- still reads as a portrait rather than an empty box.
    return ".dbi-port .face{background-image:url(\"" .. url .. "\"),"
        .. "radial-gradient(70% 60% at 50% 35%,#3a2a12 0%,#140f07 70%);}"
end

local function css()
    -- Appended rather than concatenated: a '..' chain this long builds an
    -- expression tree deep enough that Lua refuses the file outright with
    -- 'chunk has too many syntax levels'.
    local t = {}
    local function add(x) t[#t + 1] = x end

    local a = panel.alpha
    add("<style>")
    add(".dbi-port{position:relative;height:100%;box-sizing:border-box;")
    add("display:flex;flex-direction:column;container-type:inline-size;overflow:hidden;")
    add("background:rgba(" .. panel.C.card_rgb .. "," .. a .. ");color:" .. panel.C.ink .. ";")
    add("font-family:" .. chromeFont() .. ";}")

        -- header: the title, a live pulse, and the controls
    add(".dbi-port .bar{flex:0 0 auto;display:flex;align-items:center;gap:6px;")
    add("padding:6px 10px;border-bottom:1px solid rgba(251,124,0,0.25);")
    add("font-size:" .. barSize() .. "px;font-weight:600;letter-spacing:0.2em;")
    add("text-transform:uppercase;color:" .. panel.C.energy .. ";}")
    add(".dbi-port .bar .ttl{flex:1 1 auto;min-width:0;overflow:hidden;")
    add("text-overflow:ellipsis;white-space:nowrap;}")
    add(".dbi-port .dot{flex:0 0 auto;width:6px;height:6px;border-radius:50%;")
    add("background:" .. panel.C.stam .. ";box-shadow:0 0 6px " .. panel.C.stam .. ";")
    add("animation:hudPulse 2s ease-in-out infinite;}")
    add("@keyframes hudPulse{0%,100%{opacity:1}50%{opacity:0.35}}")
    add(".dbi-port .tb{flex:0 0 auto;font-size:" .. barSize() .. "px;letter-spacing:0.1em;")
    add("text-transform:uppercase;padding:2px 5px;border-radius:2px;")
    add("border:1px solid " .. panel.C.rule .. ";color:" .. panel.C.ink_dim .. ";")
    add("cursor:pointer;user-select:none;white-space:nowrap;}")
    add(".dbi-port .tb:hover{color:" .. panel.C.ink .. ";border-color:" .. panel.C.energy .. ";}")
    -- pushes the buttons to the right of the title
    add(".dbi-port .sp{flex:1 1 auto;}")

    -- The tab strip. Fixed under the portrait, so it stays put while the body
    -- scrolls -- which is the whole reason the face was hoisted out of it.
    add(".dbi-port .tabs{flex:0 0 auto;display:flex;gap:3px;padding:5px 6px 0 6px;")
    add("border-bottom:1px solid " .. panel.C.rule .. ";}")
    add(".dbi-port .tab{flex:1 1 0;text-align:center;cursor:pointer;")
    add("user-select:none;white-space:nowrap;overflow:hidden;")
    add("font-size:" .. barSize() .. "px;letter-spacing:0.06em;")
    add("text-transform:uppercase;padding:4px 2px;border-radius:3px 3px 0 0;")
    add("border:1px solid " .. panel.C.rule .. ";border-bottom:none;")
    add("color:" .. panel.C.ink_dim .. ";background:rgba(255,255,255,0.02);}")
    add(".dbi-port .tab:hover{color:" .. panel.C.ink .. ";}")

    -- Footer, pinned under the body. Only drawn when it has something in it.
    add(".dbi-port .foot{flex:0 0 auto;display:flex;gap:4px;flex-wrap:wrap;")
    add("justify-content:center;")
    add("padding:4px 6px;border-top:1px solid " .. panel.C.rule .. ";}")
    add(".dbi-port .fpill{font-size:clamp(9px,3cqw,12px);padding:2px 7px;")
    add("border-radius:9px;cursor:pointer;user-select:none;")
    add("overflow:hidden;text-overflow:ellipsis;white-space:nowrap;")
    add("border:1px solid " .. panel.C.auc .. ";color:" .. panel.C.auc .. ";")
    add("background:rgba(168,120,255,0.10);}")
    add(".dbi-port .fpill:hover{background:rgba(168,120,255,0.22);}")

    -- captured lists
    --
    -- Sized in container query units against the panel's own width rather than
    -- a fixed px, so a narrow panel gets a smaller list instead of a wider
    -- scrollbar. clamp keeps it readable at both ends -- widgetInfo cannot be
    -- asked how wide the panel is (sharp edge 11), and this does not need to.
    add(".dbi-port .items{padding:5px 7px;font-size:clamp(10px,3.4cqw,14px);")
    add("line-height:1.35;}")
    add(".dbi-port .iline{display:flex;align-items:center;gap:6px;")
    add("min-height:1.5em;padding:1px 0;}")
    add(".dbi-port .itx{flex:1 1 auto;overflow:hidden;text-overflow:ellipsis;")
    add("white-space:nowrap;}")
    add(".dbi-port .ib{flex:0 0 auto;font-size:clamp(8px,2.6cqw,11px);")
    add("padding:1px 5px;border-radius:2px;cursor:pointer;user-select:none;")
    add("border:1px solid " .. panel.C.rule .. ";color:" .. panel.C.ink_dim .. ";}")
    add(".dbi-port .ib:hover{color:" .. panel.C.energy .. ";border-color:" .. panel.C.energy .. ";}")
    -- contents of an open container, indented under it
    add(".dbi-port .isub{padding:0 0 0 14px;font-size:clamp(9px,3cqw,13px);")
    add("color:" .. panel.C.ink_dim .. ";overflow:hidden;text-overflow:ellipsis;")
    add("white-space:nowrap;border-left:1px solid " .. panel.C.rule .. ";")
    add("margin-left:4px;}")
    add(".dbi-port .iempty{font-style:italic;}")

    add(".dbi-port .stale{font-size:" .. barSize() .. "px;color:" .. panel.C.ink_dim .. ";")
    add("padding:0 0 4px 0;font-style:italic;}")
    -- the refresh sits on its own line above the rows, right aligned, so it
    -- does not join the scrum of buttons every row already carries
    add(".dbi-port .ihead{display:flex;justify-content:flex-end;")
    add("padding:0 0 3px 0;}")
    -- the slot, as its own column on the equipment tab. Fixed width so the
    -- names line up down the panel rather than starting wherever the slot ended
    add(".dbi-port .islot{flex:0 0 4.6em;font-size:clamp(8px,2.5cqw,10px);")
    add("letter-spacing:0.08em;text-transform:uppercase;color:" .. panel.C.ink_dim .. ";")
    add("overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}")
    add(".dbi-port .tab.sel{color:" .. panel.C.energy .. ";border-color:" .. panel.C.energy .. ";")
    add("background:rgba(251,124,0,0.12);}")

    -- Both labels ship and CSS picks one. widgetInfo lies about the panel size
    -- (sharp edge 11), so the choice is made here in container query units
    -- against the panel's own width rather than by asking.
    add(".dbi-port{container-type:inline-size;}")
    add(".dbi-port .ts{display:none;}")
    add("@container (max-width: 260px){")
    add(".dbi-port .tl{display:none;}")
    add(".dbi-port .ts{display:inline;}}")
    add(".dbi-port .tb.on{color:" .. panel.C.energy .. ";border-color:" .. panel.C.energy .. ";")
    add("background:rgba(251,124,0,0.12);}")

    add(".dbi-port .body{flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;}")

        -- portrait: square, faded into the card, scanlined, with the name on it
    add(".dbi-port .face{position:relative;width:100%;aspect-ratio:1/1;background:#000;")
    -- Fit the WIDTH: '100% auto' spans the panel and lets the height follow the
    -- image's own proportions. 'cover' cropped both edges to fill the square and
    -- 'contain' left bars down the sides, which is what exposed the fallback
    -- layer underneath and drew two portraits at once.
    --
    -- Anchored top, so when a tall image runs past the bottom of the box it is
    -- the feet that go rather than the face.
    add("background-size:100% auto;background-position:center top;")
    add("background-repeat:no-repeat;}")
    add(".dbi-port .face::before{content:\'\';position:absolute;inset:0;")
    add("background:linear-gradient(to top,rgba(" .. panel.C.card_rgb .. ",1) 0%,")
    add("rgba(" .. panel.C.card_rgb .. ",0.3) 45%,transparent 100%);}")
    add(".dbi-port .face::after{content:\'\';position:absolute;inset:0;opacity:0.4;")
    add("background:repeating-linear-gradient(to bottom,rgba(255,255,255,0.04) 0 1px,")
    add("transparent 1px 3px);}")
    add(".dbi-port .over{position:absolute;left:0;right:0;bottom:0;padding:10px;z-index:2;}")
    add(".dbi-port .nm{font-size:190%;font-weight:700;line-height:1;color:" .. panel.C.energy .. ";")
    add("text-shadow:0 1px 6px rgba(0,0,0,0.8);}")
    add(".dbi-port .sub{margin-top:3px;font-size:" .. bodySize() .. "px;color:" .. panel.C.stam .. ";}")
    add(".dbi-port .sub i{color:" .. panel.C.ink_dim .. ";font-style:normal;margin:0 4px;}")

    add(".dbi-port .pad{display:flex;flex-direction:column;gap:10px;padding:10px;}")

        -- power level reads as a figure, not a bar; clicking it flips the mode
    add(".dbi-port .pl{display:flex;align-items:center;justify-content:space-between;")
    add("gap:8px;padding:7px 10px;border-radius:6px;cursor:pointer;")
    add("border:1px solid rgba(251,124,0,0.3);background:rgba(0,0,0,0.4);}")
    add(".dbi-port .pl:hover{border-color:rgba(251,124,0,0.65);}")
    add(".dbi-port .pl .k{font-size:" .. barSize() .. "px;font-weight:600;")
    add("letter-spacing:0.2em;text-transform:uppercase;color:" .. panel.C.ink_dim .. ";}")
    -- The figure is the widest thing in the panel, so it tracks the panel's own
    -- width rather than the font size. A fixed 150% put a six-digit power level
    -- shoulder to shoulder with its label in a narrow column.
    local plLo = math.max(11, math.floor(panel.font.size * 0.95 * panel.font.scale))
    local plHi = math.max(16, math.floor(panel.font.size * 1.7 * panel.font.scale))
    add(".dbi-port .pl .v{font-size:clamp(" .. plLo .. "px,6.5cqw," .. plHi .. "px);")
    add("font-weight:700;color:" .. panel.C.energy .. ";")
    add("text-shadow:0 0 8px rgba(251,124,0,0.6);white-space:nowrap;}")

        -- numeric mode: Base PL and Curr PL side by side in the same frame, so
        -- both figures share a row and the clamp has to give ground
    add(".dbi-port .pl.nums{justify-content:space-around;}")
    add(".dbi-port .pl .cell{display:flex;flex-direction:column;align-items:center;")
    add("gap:2px;min-width:0;}")
    add(".dbi-port .pl.nums .v{font-size:clamp(" .. math.max(10, math.floor(plLo * 0.8))
        .. "px,4.5cqw," .. math.max(13, math.floor(plHi * 0.75)) .. "px);}")
    add(".dbi-port .pl .sep{color:" .. panel.C.ink_dim .. ";font-weight:400;}")

        -- bars: thin, rounded, gradient into a glow
    add(".dbi-port .mt{display:flex;flex-direction:column;gap:4px;}")
    add(".dbi-port .mtl{display:flex;align-items:baseline;justify-content:space-between;")
    add("gap:6px;font-size:" .. barSize() .. "px;letter-spacing:0.14em;text-transform:uppercase;}")
    add(".dbi-port .mtl .lbl{color:" .. panel.C.ink_dim .. ";}")
    add(".dbi-port .mtl .num{color:" .. panel.C.ink .. ";white-space:nowrap;}")
    add(".dbi-port .mtl .pc{color:" .. panel.C.ink_dim .. ";margin-left:4px;}")
    add(".dbi-port .trk{position:relative;height:8px;border-radius:999px;overflow:hidden;")
    add("background:rgba(0,0,0,0.5);box-shadow:inset 0 0 0 1px rgba(255,255,255,0.05);}")
    add(".dbi-port .fil{position:absolute;top:0;bottom:0;left:0;border-radius:999px;")
    add("background:linear-gradient(90deg,rgba(0,0,0,0.45),var(--c));")
    add("box-shadow:0 0 8px 0 var(--c);")
    add("transition:width 500ms cubic-bezier(0.22,1,0.36,1);}")

    add(".dbi-port .mt.lf{--c:" .. panel.C.hp .. ";}")
    add(".dbi-port .mt.ki{--c:" .. panel.C.ki .. ";}")
    add(".dbi-port .mt.ar{--c:" .. panel.C.gold .. ";}")
    -- ki runs its own ramp, deep water into bright cyan, rather than the shared
    -- dark-into-colour one
    add(".dbi-port .mt.ki .fil{background:linear-gradient(90deg,#0a2c55,#0077cc 55%,#33c6ff);}")
    add(".dbi-port .mt.pw{--c:" .. panel.C.stam .. ";}")
    add(".dbi-port .mt.foe{--c:" .. panel.C.foe .. ";}")
    add(".dbi-port .mt.warn{--c:" .. panel.C.energy .. ";}")
    add(".dbi-port .mt.low{--c:#e05a10;}")
    add(".dbi-port .mt.crit{--c:" .. panel.C.hp .. ";}")
    add(".dbi-port .mt.low .pc,.dbi-port .mt.crit .pc{color:var(--c);}")
    add("@keyframes hudBreathe{0%,100%{opacity:1}50%{opacity:0.55}}")
    add("@keyframes hudFlash{0%,100%{opacity:1}50%{opacity:0.4}}")
    add(".dbi-port .mt.low .fil{animation:hudBreathe 1.8s ease-in-out infinite;}")
    add(".dbi-port .mt.crit .fil{animation:hudFlash 0.7s ease-in-out infinite;}")
    add(".dbi-port .mt.crit .lbl{color:var(--c);}")
    -- a bar past its reference marks the overflow rather than clipping it away
    add(".dbi-port .mt .ovf{position:absolute;inset:0;border-radius:999px;")
    add("border:1px solid var(--c);pointer-events:none;}")

        -- attributes: two columns, label left, value right
    add(".dbi-port .attrs{display:grid;grid-template-columns:1fr 1fr;")
    add("gap:5px 12px;padding-top:10px;border-top:1px solid " .. panel.C.rule .. ";}")
    add(".dbi-port .attr{display:flex;align-items:baseline;justify-content:space-between;gap:6px;}")
    add(".dbi-port .attr .k{font-size:" .. barSize() .. "px;letter-spacing:0.12em;")
    add("text-transform:uppercase;color:" .. panel.C.ink_dim .. ";}")
    add(".dbi-port .attr .v{font-size:" .. bodySize() .. "px;color:" .. panel.C.ink .. ";")
    add("overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}")

        -- status pills
    add(".dbi-port .pills{display:flex;flex-wrap:wrap;gap:5px;padding-top:10px;")
    add("border-top:1px solid " .. panel.C.rule .. ";}")
    add(".dbi-port .pill{font-size:" .. barSize() .. "px;font-weight:600;letter-spacing:0.1em;")
    add("text-transform:uppercase;padding:2px 6px;border-radius:3px;")
    add("border:1px solid rgba(0,172,243,0.4);color:" .. panel.C.ki .. ";background:rgba(0,172,243,0.1);}")
    add(".dbi-port .pill.good{border-color:rgba(94,201,102,0.4);color:" .. panel.C.stam .. ";")
    add("background:rgba(94,201,102,0.1);}")
    add(".dbi-port .pill.bad{border-color:rgba(234,60,63,0.4);color:" .. panel.C.hp .. ";")
    add("background:rgba(234,60,63,0.1);}")

        -- The opponent sits apart from your own vitals, and larger: this is the
        -- number being watched mid-fight, so it gets a taller track and a bigger
        -- figure. 'foeblk' rather than 'foe' -- the bar's own kind is already
        -- 'foe', and a wrapper sharing that name is how the power bar once
        -- inherited the power-level box's border and stopped looking like a bar.
    add(".dbi-port .foeblk{padding-top:10px;border-top:1px solid " .. panel.C.rule .. ";}")
    add(".dbi-port .foeblk .trk{height:16px;}")
    add(".dbi-port .foeblk .mtl{font-size:" .. bodySize() .. "px;}")
    add(".dbi-port .foeblk .mtl .num{font-weight:700;color:" .. panel.C.foe .. ";}")

        -- sheet
    add(".dbi-port table{width:100%;table-layout:fixed;border-collapse:collapse;")
    add("font-size:" .. bodySize() .. "px;}")
    add(".dbi-port td{padding:1px 0;vertical-align:top;}")
    add(".dbi-port td.k{width:40%;color:" .. panel.C.ink_dim .. ";padding-right:10px;")
    add("overflow-wrap:anywhere;}")
    add(".dbi-port td.v{text-align:right;color:" .. panel.C.ink .. ";overflow-wrap:anywhere;}")
    add(".dbi-port table td{line-height:1.35;}")
    add(".dbi-port .cfg{gap:2px;}")
    add(".dbi-port .crow{display:flex;align-items:center;gap:6px;margin:0;")
    add("padding:2px 0;font-size:" .. barSize() .. "px;}")
    add(".dbi-port .ck{flex:1 1 auto;opacity:0.75;}")
    add(".dbi-port .cv{flex:0 1 auto;text-align:right;overflow:hidden;")
    add("text-overflow:ellipsis;white-space:nowrap;max-width:60%;}")
    -- The field has to be allowed to shrink or a long url pushes the buttons
    -- off the panel; min-width:0 is what lets flex do that.
    add(".dbi-port .crow input{flex:1 1 auto;min-width:0;background:rgba(0,0,0,0.35);")
    add("border:1px solid rgba(255,255,255,0.18);border-radius:3px;color:inherit;")
    add("font:inherit;font-size:" .. barSize() .. "px;padding:2px 5px;outline:none;}")
    add(".dbi-port .crow input:focus{border-color:" .. panel.C.energy .. ";}")
    -- The add-a-form row: three fields stacked, because the announcement is a
    -- whole sentence of the MUD's prose and will not share a line.
    add(".dbi-port .cfrm{display:flex;flex-direction:column;gap:4px;")
    add("margin:4px 0 2px;padding:6px;border:1px solid rgba(255,255,255,0.10);")
    add("border-radius:4px;}")
    add(".dbi-port .cfrm input{background:rgba(0,0,0,0.35);")
    add("border:1px solid rgba(255,255,255,0.18);border-radius:3px;color:inherit;")
    add("font:inherit;font-size:" .. barSize() .. "px;padding:2px 5px;outline:none;}")
    add(".dbi-port .cfrm input:focus{border-color:" .. panel.C.energy .. ";}")
    add(".dbi-port .cfrm .tb{align-self:flex-end;}")
    -- The stored announcement, whole. It is what the match runs against, so a
    -- truncated one on screen would hide the reason a form is not firing.
    add(".dbi-port .fpat{font-size:" .. math.max(8, barSize() - 1) .. "px;")
    add("opacity:0.55;line-height:1.25;margin:0 0 5px 6px;word-break:break-word;}")
    add(".dbi-port .fon{color:" .. panel.C.energy .. ";font-size:"
        .. math.max(8, barSize() - 1) .. "px;}")
    add(".dbi-port .sec{margin:10px 0 3px;font-size:" .. barSize() .. "px;font-weight:600;")
    add("letter-spacing:0.2em;text-transform:uppercase;color:" .. panel.C.energy .. ";")
    add("border-bottom:1px solid " .. panel.C.rule .. ";padding-bottom:3px;}")

    add(".dbi-port .idle{padding:14px 10px;font-size:" .. bodySize() .. "px;")
    add("line-height:1.7;color:" .. panel.C.ink_dim .. ";}")
    add(".dbi-port .idle b{color:" .. panel.C.energy .. ";}")

        -- Narrow: the numbers go, then the second attribute column. The enemy
        -- keeps its figure -- your own bars still show a percentage in .pc, but
        -- the enemy's only number lives in .num, so dropping it leaves a
        -- labelled track with nothing on it.
    add("@container (max-width:200px){.dbi-port .mtl .num{display:none;}")
    add(".dbi-port .foeblk .mtl .num{display:inline;}}")
    add("@container (max-width:170px){.dbi-port .attrs{grid-template-columns:1fr;}}")
    add(avatarCss())
    add("</style>")
    return table.concat(t)
end

-- Colour follows how much is left, not what the bar measures: full is the
-- meter's own colour, and everything below LV_WARN walks yellow, orange, red.
local function levelOf(p)
    if p <= panel.LV.crit then return " crit" end
    if p <= panel.LV.low then return " low" end
    if p <= panel.LV.warn then return " warn" end
    return ""
end

-- 'danger' is false for power level. You can suppress deliberately, so a low
-- reading there is a choice rather than a crisis, and colouring it like one
-- would have it flashing red mid-fight for no reason.
-- Lifeforce, Ki and Armour are on the panel whether or not anything has
-- supplied them yet. A row that disappears when a value is briefly missing
-- makes the whole stack jump, and a player with no GMCP whose prompt carries
-- neither should still see what the panel is for.
local barOrDash = nil

local function bar(label, cur, max, kind, danger)
    if not has(cur) or not has(max) or max <= 0 then return "" end

    local p = math.floor((cur / max) * 100 + 0.5)
    if p < 0 then p = 0 end

    -- A power level above its base is a boost rather than an error, so the bar
    -- fills and says so instead of clamping the number out of sight.
    local shown = p
    local over = ""
    if shown > 100 then
        shown = 100
        over = '<i class="ovf"></i>'
    end

    local lv = ""
    if danger then lv = levelOf(p) end

    return '<div class="mt ' .. kind .. lv .. '">'
        .. '<div class="mtl"><span class="lbl">' .. escapeHtml(label) .. "</span>"
        .. '<span class="num">' .. cur .. " / " .. max .. "</span>"
        .. '<span class="pc">' .. p .. "%</span></div>"
        .. '<div class="trk"><div class="fil" style="width:' .. shown .. '%"></div>'
        .. over .. "</div></div>"
end

-- The enemy's lifeforce is already a percentage -- the fprompt hands it over as
-- one -- so this carries the percent alone, without bar()'s cur/max furniture.
barOrDash = function(label, cur, max, kind, danger)
    local out = bar(label, cur, max, kind, danger)
    if out ~= "" then return out end
    return '<div class="mt ' .. kind .. '">'
        .. '<div class="mtl"><span class="lbl">' .. escapeHtml(label) .. "</span>"
        .. '<span class="num">--</span></div>'
        .. '<div class="trk"></div></div>'
end

local function foeBar()
    -- GMCP first: it names the thing, which the prompt never could.
    local label = "Enemy"
    if type(foe.name) == "string" and foe.name ~= "" then label = foe.name end

    -- The MUD's own ceiling first. Failing that, the highest reading seen since
    -- this target appeared -- which is a guess, but a self-correcting one: the
    -- first reading of a fresh target is its highest.
    local ceiling = safeNum(foe.max)
    local exact = ceiling ~= nil
    if ceiling == nil then ceiling = safeNum(foe.peak) end

    local pct, num = nil, nil
    -- src 'prompt' pins the bar to the prompt's own percentage. GMCP keeps
    -- being collected -- the name still labels the bar -- but its numbers do
    -- not drive it.
    if src.bars ~= "prompt" and safeNum(foe.hit) and ceiling and ceiling > 0 then
        pct = (foe.hit / ceiling) * 100
        num = withCommas(foe.hit)
        -- Shown against a known maximum, the pair is worth printing. Against a
        -- guessed one it would read as fact, so only the current figure goes.
        if exact then num = num .. " / " .. withCommas(ceiling) end
    elseif has(foe.val) then
        pct = foe.val
        num = tostring(foe.val) .. "%"
    end
    if pct == nil then return "" end

    local p = math.floor(pct + 0.5)
    if p < 0 then p = 0 end
    if p > 100 then p = 100 end

    return '<div class="foeblk"><div class="mt foe">'
        .. '<div class="mtl"><span class="lbl">' .. escapeHtml(label) .. "</span>"
        .. '<span class="num">' .. escapeHtml(num) .. "</span></div>"
        .. '<div class="trk"><div class="fil" style="width:' .. p .. '%"></div></div>'
        .. "</div></div>"
end

local function row(k, v)
    if not has(v) then return "" end
    return '<tr><td class="k">' .. escapeHtml(k) .. '</td><td class="v">' .. escapeHtml(tostring(v)) .. "</td></tr>"
end

local function attr(k, v)
    if not has(v) then return "" end
    return '<div class="attr"><span class="k">' .. escapeHtml(k)
        .. '</span><span class="v">' .. escapeHtml(tostring(v)) .. "</span></div>"
end

-- The portrait itself, hoisted out of the body so it shows on every tab.
--
-- It is chrome now rather than the first thing in the scroller, which is what
-- keeps the tab strip reachable while a long inventory scrolls past. The cost
-- is a panel-width of height that no tab can reclaim.
local function faceHtml()
    local t = {}
    local function add(x) t[#t + 1] = x end

    -- the name sits ON the portrait, over a gradient into the card
    add('<div class="face"><div class="over">')
    -- Through the whitelist, not through 'or'. A field that never made it into
    -- the store comes back as undefined, which is truthy, so 'or "Unknown"'
    -- never fires and the panel wrote the word across the portrait instead of
    -- a name. headerName() proves it is a real string first.
    local shownName = profile.header()
    if shownName == "Portrait" then shownName = "Unknown" end
    add('<div class="nm">' .. escapeHtml(shownName) .. "</div>")

    local sub = {}
    if has(sc.race) then sub[#sub + 1] = escapeHtml(sc.race) end
    if has(sc.rank) then sub[#sub + 1] = escapeHtml(sc.rank) end
    if #sub > 0 then
        add('<div class="sub">' .. table.concat(sub, '<i>/</i>') .. "</div>")
    end
    add("</div></div>")
    return table.concat(t)
end

-- Which tab is which. One table drives the strip and the click handler, so a
-- name can never drift between them. 'portrait' stays the id for Stats because
-- that is what 'view' has always been stored as.
panel.TABS = {
    { id = "portrait", lg = "Stats",     sm = "Stat" },
    { id = "sheet",    lg = "Sheet",     sm = "Shet" },
    { id = "inv",      lg = "Inventory", sm = "Inv" },
    { id = "eq",       lg = "Equipment", sm = "Eq" },
}

local function tabStrip()
    local t = {}
    local function add(x) t[#t + 1] = x end
    add('<div class="tabs">')
    for _, tab in ipairs(panel.TABS) do
        local sel = ""
        if panel.view == tab.id then sel = " sel" end
        -- Both labels are emitted and CSS picks one on width. Asking the client
        -- how wide the panel is does not work (sharp edge 11), so the choice is
        -- made in the stylesheet with container query units.
        add('<span class="tab' .. sel .. '" data-mud-action="tab" data-mud-data="'
            .. tab.id .. '">'
            .. '<span class="tl">' .. tab.lg .. "</span>"
            .. '<span class="ts">' .. tab.sm .. "</span></span>")
    end
    add("</div>")
    return table.concat(t)
end

local function portraitBody()
    local t = {}
    local function add(x) t[#t + 1] = x end

    add('<div class="pad">')

    -- GMCP is pushed and score is a snapshot from whenever it was last typed,
    -- so GMCP wins wherever both have an opinion
    -- Field by field, never in pairs. GMCP delivering 'energy' but not
    -- 'max_energy' left the maximum unset while the paired guard saw a value
    -- and skipped the fallback, so the whole Ki row silently vanished. Same
    -- shape as race, sex and age hiding behind one match.
    local hit, maxHit, en, maxEn = nil, nil, nil, nil
    if vit then
        hit, maxHit, en, maxEn = vit.hit, vit.maxHit, vit.energy, vit.maxEnergy
    end

    -- Then the prompt, then score. One field at a time, never in pairs: GMCP
    -- delivering 'energy' without 'max_energy' once left the maximum unset
    -- while a paired guard saw a value and skipped the fallback, and the whole
    -- Ki row vanished.
    --
    -- '%h' is a percentage and the panel's scale is 0..10000, which is the
    -- scale score's own lifeforce figure uses as well.
    if not has(hit) and has(charState.lf) then hit = math.floor(charState.lf * 100) end
    if not has(maxHit) and has(charState.lf) then maxHit = 10000 end
    if not has(hit) and has(sc.lifeforce) then hit = math.floor(sc.lifeforce * 100) end
    if not has(maxHit) and has(sc.lifeforce) then maxHit = 10000 end

    if not has(en) and has(charState.ki) then en = charState.ki end
    if not has(maxEn) and has(charState.kiMax) then maxEn = charState.kiMax end
    if not has(en) then en = sc.energy end
    if not has(maxEn) then maxEn = sc.energyMax end
    -- A prompt carrying '%m' and no '%M' gives a current with no ceiling. The
    -- figure is still worth showing, so the bar reads full rather than nothing.
    if has(en) and not has(maxEn) then maxEn = en end

    local pl = nil
    if vit and has(vit.pl) then pl = vit.pl else pl = sc.pl end
    local base = nil
    if vit and has(vit.basepl) then base = vit.basepl else base = sc.basepl end
    if not has(base) then base = pl end

    -- The figure is the ceiling -- base power level, what the character is
    -- worth at rest. Current against it is the third bar, where the design put
    -- stamina: at rest it reads 100%, drained it falls, boosted it runs past.
    -- Clicking the box swaps that for the pair of figures, which is the reading
    -- you want when the two have drifted apart and the ratio is not the point.
    local ceiling = base
    if not has(ceiling) then ceiling = pl end

    -- Both figures or neither. Guarding on 'either' and then rendering both
    -- printed the word 'nil' into a cell, and a vitals packet carrying basepl
    -- without pl before the first score is exactly that state -- sharp edge 13
    -- applied to the guard but not to what it guards. With only one known, the
    -- single figure below says the one true thing instead.
    if panel.plMode == "nums" and has(base) and has(pl) then
        add('<div class="pl nums" data-mud-action="plmode" title="switch power display">')
        add('<span class="cell"><span class="k">Base PL</span>')
        add('<span class="v">' .. escapeHtml(short(base)) .. "</span></span>")
        add('<span class="sep">|</span>')
        add('<span class="cell"><span class="k">Curr PL</span>')
        add('<span class="v">' .. escapeHtml(short(pl)) .. "</span></span>")
        add("</div>")
    elseif has(ceiling) then
        add('<div class="pl" data-mud-action="plmode" title="switch power display">')
        add('<span class="k">Power Level</span>')
        add('<span class="v">' .. escapeHtml(short(ceiling)) .. "</span></div>")
    end

    add(barOrDash("Lifeforce", hit, maxHit, "lf", true))
    add(barOrDash("Ki", en, maxEn, "ki", true))
    -- Armour comes off the prompt's own tokens and nowhere else, so it appears
    -- only for a prompt carrying %z and %Z. bar() already draws nothing when
    -- either side is missing.
    -- Armour off the prompt's tokens when it carries them, and off score when
    -- it does not. Score gives the figure and no ceiling, so the bar reads full
    -- rather than empty -- the same way Ki does with '%m' and no '%M'.
    local arCur, arMax = charState.ar, charState.arMax
    -- score stands in only when the toggle allows it: 'prompt' pins the bar to
    -- the live %z/%Z tokens and nothing staler
    if src.bars ~= "prompt" and not has(arCur) then arCur = sc.armorVal end
    -- GMCP is the only thing that has ever supplied an armour ceiling. Without
    -- one the bar fell back to reading full, which is the same picture at 100
    -- armour as at 10,400.
    if src.bars ~= "prompt" and not has(arMax) then arMax = sc.armorMax end
    if has(arCur) and not has(arMax) then arMax = arCur end
    add(barOrDash("Armor", arCur, arMax, "ar", false))
    -- the ratio bar is what the numeric mode replaces, so it goes with it
    if panel.plMode ~= "nums" and has(pl) and has(base) then
        add(bar("Power", pl, base, "pw", false))
    end

    local rows = {}
    rows[#rows + 1] = attr("Str", sc.strength)
    rows[#rows + 1] = attr("Spd", sc.speed)
    rows[#rows + 1] = attr("Spi", sc.spirit)
    rows[#rows + 1] = attr("For", sc.fortitude)
    -- The prompt's running total when there is one: autoloot adds to it and
    -- score's figure is only as fresh as the last time it was typed.
    local coins = charState.zeni
    if type(coins) ~= "number" then coins = sc.zeni end
    rows[#rows + 1] = attr("Zeni", coins)
    rows[#rows + 1] = attr("Align", sc.align)
    local grid = table.concat(rows)
    if grid ~= "" then add('<div class="attrs">' .. grid .. "</div>") end

        -- Whatever the server says is switched on, as its own pill each.
    --
    --   "char": { "effects": [
    --       { "name": "powerup",    "category": "buff" },
    --       { "name": "suppressed", "category": "debuff", "value": 6000000 },
    --       { "name": "white_pk",   "category": "pvp"  },
    --       { "name": "translight", "category": "misc" } ] }
    --
    -- GMCP rather than a trigger, and in the order the server sent them.
    -- A buff reads good, a debuff reads bad, anything else is plain -- there
    -- is no list of category names to keep up to date that way.
    local pills = {}
    for _, one in ipairs(effects) do
        -- Not every category belongs on this panel.
        --
        --   activity  'in_combat', which the fighting pill already says
        --   pvp       'white_pk', a standing flag rather than anything
        --             happening to the character right now
        --
        -- Named rather than whitelisted: a whitelist of wanted categories
        -- would silently drop every category this MUD grows that we have not
        -- seen, and there is no way to notice that from in here.
        local skip = one.cat == "activity" or one.cat == "pvp"
        local cls = "pill"
        -- 'transformation' reads as a buff, because that is what it is:
        --
        --   { "name": "ssj1",    "category": "transformation" }
        --   { "name": "powerup", "category": "transformation", "value": 2 }
        --
        -- powerup used to arrive as a 'buff' and lost its colour when the
        -- server moved it. The form pill beside it comes from the plugin's
        -- own tracking and says the same thing twice for a moment; that is
        -- worth less than losing the reading altogether.
        if one.cat == "buff" or one.cat == "transformation" then
            cls = "pill good"
        elseif one.cat == "debuff" then cls = "pill bad" end
        if not skip then
        local txt = one.name
        -- short(), the same 18.5M form the power level box uses. A pill is
        -- a few characters wide and a suppression level is eight figures.
        if one.val ~= nil then txt = txt .. " " .. short(one.val) end
        pills[#pills + 1] = '<span class="' .. cls .. '">'
            .. escapeHtml(txt) .. "</span>"
        end
    end
    if form.name ~= "" then
        pills[#pills + 1] = '<span class="pill good">' .. escapeHtml(form.name) .. "</span>"
    end
    -- Fighting beats everything: the opponent bar is up, so whatever score
    -- said about sitting down is an hour out of date.
    local pose = posture
    if foe.name ~= nil or safeNum(foe.val) ~= nil or safeNum(foe.hit) ~= nil then
        pose = "fighting"
    end
    if pose == "" then pose = sc.position end
    if has(pose) then
        pills[#pills + 1] = '<span class="pill">' .. escapeHtml(pose) .. "</span>"
    end
    -- Only when the server has not already said so. These are read off
    -- pl against base, which cannot tell a suppression from a bad day and
    -- says nothing about WHAT it is suppressed to -- char.effects carries
    -- both. Kept for builds that do not send the package.
    if not effectsSeen and has(base) and has(pl) then
        if pl > base then
            pills[#pills + 1] = '<span class="pill good">boosted</span>'
        elseif pl < base then
            pills[#pills + 1] = '<span class="pill">suppressed</span>'
        end
    end
    if has(sc.sex) or has(sc.age) then
        local who = ""
        if has(sc.sex) then who = sc.sex end
        if has(sc.age) then who = trimBoth(who .. " " .. sc.age .. "y") end
        pills[#pills + 1] = '<span class="pill">' .. escapeHtml(who) .. "</span>"
    end
    if #pills > 0 then
        add('<div class="pills">' .. table.concat(pills) .. "</div>")
    end

    -- The opponent goes last, under the pills, with its own rule above it.
    -- 0.37.0 moved it up into the meter stack and that was the wrong call: it
    -- belongs where a thing that is usually absent belongs, at the end, so
    -- nothing above it shifts when a fight starts.
    add(foeBar())

    add("</div>")
    return table.concat(t)
end

----------------------------------------------------------------------
-- captured lists: inventory, equipment, a container
--
-- Driven by the command YOU type. Capture is ARMED by the command and only
-- starts when the block's own header arrives, so channel chatter landing
-- between the two stays out of the list.
--
-- The block ends at the prompt, and which lines are prompts is a question this
-- plugin already answers for any format it knows or has been told -- so unlike
-- the version this came from, it is not limited to two hardcoded prompt shapes.
----------------------------------------------------------------------

-- One table rather than six names, for the 200-local ceiling.
-- 'dirty' rather than calling safeRender from in here: safeRender is declared
-- further down, and a file-scope local used above its declaration resolves as a
-- nil global. onLine does the redraw once it has the answer.
local cap = { kind = nil, armed = nil, at = 0, lines = {}, n = 0,
              silent = false, dirty = false, endNow = false, promptLine = nil,
              target = nil }

gear.MAX = 200
-- counters, so a capture that does not happen can say which half failed
local capCmds = 0
local capArms = 0
local capDone = 0
-- One table rather than four names. The chunk is close to Lua 5.1's 200-local
-- ceiling (sharp edge 7) and folding related names together is the fix for it.
--   seen  lines offered to the item-event reader
--   hit   lines it acted on
--   last  the last one that looked like an item moving
--   why   what the reader decided about it, which is the question diag could
--         not answer: refused, or never reached at all
local ev = { seen = 0, hit = 0, last = "", why = "" }

-- Clicks that reached the handler. A button that does nothing and a button
-- whose event never arrived look identical from the panel.
local uiCalls = 0

-- Prints what the item reader decided about every 'You ' line, as it happens.
-- Four releases were spent reasoning about which branch ran from the state it
-- left behind, and the state does not say -- an item that ends up in neither
-- list looks the same whether the rule missed, the drop failed, or the add did.
gear.trace = false
local capStand = 0     -- stood down: the reply never came
local capHead = 0      -- the block's header matched
local capSaw = ""      -- the last line offered while armed
gear.list = { inv = {}, eq = {}, cont = {} }
-- Whether a list has ever been captured, which is not the same question as
-- whether it has rows in it. An inventory emptied by dropping everything is
-- known and empty; one that was never asked for is unknown. The events may only
-- edit the first kind, and only the second kind is what 'type inv' is for.
gear.seen = { inv = false, eq = false, cont = false }
-- What each container holds, and which ones are open, both keyed by the same
-- keyword a command would address the container by. Per container rather than
-- one slot: you have more than one bag and closing a backpack to peek in a
-- pouch is not a UI.
-- Containers and the analyse block: what is in one, which is open, whether a
-- thing is a container at all, and the same pair for analyse.
local cont = {}

cont.list = {}
cont.open = {}
-- Which keywords have actually proven to be containers, by answering a 'look
-- in' with a contents block. Guessing from a name does not work -- a Proof of
-- Tranquility is not a bag and nothing about the text says so -- and offering
-- to open everything is worse than offering to open nothing.
--
-- Remembered across sessions: what is a container does not change, and asking
-- again every login would mean typing 'look in' at your own backpack forever.
cont.is = {}
-- What 'ana' said about an item, keyed the same way, and which ones are shown.
-- The block names the item on its first line and carries the one thing nothing
-- else does: the slot it is worn in.
cont.anaOf = {}
cont.anaOpen = {}
gear.stale = { inv = true, eq = true, cont = true }

-- char.equipment and char.inventory, straight into the two lists.
--
-- These replace the capture wholesale rather than editing it: GMCP sends the
-- whole list every time, so there is nothing to reconcile and no 'You get X'
-- line to track. That is most of the item machinery's reason for existing.
--
-- Row format matches what the capture produced, because the renderer splits it
-- back apart: equipment is '<slot> Name', inventory is bare. A layer becomes
-- '[16]' on the end, which is how the MUD itself prints it:
--
--     Class I Battle Armor [16]
--
-- What is LOST going this way is the MUD's own flag prefix -- '(Glowing) Proof
-- of Tranquility' arrives as 'Proof of Tranquility'. Worth knowing; the toggle
-- is there for anyone who would rather have it.
local function gearRows(list, withSlot)
    local rows = {}
    if type(list) ~= "table" then return nil end
    -- Two-value return, into locals. Nesting it hands the pair across.
    local arr, n = normArray(list.items)
    if n == 0 and type(list.items) ~= "table" then return nil end

    for i = 1, n do
        local it = arr[i]
        if type(it) == "table" then
            local nm = it.name
            if type(nm) == "string" and trimBoth(nm) ~= ""
                and trimBoth(nm) ~= "undefined" then
                nm = trimBoth(nm)
                local layer = safeNum(it.layer)
                if layer ~= nil and layer > 0 then nm = nm .. " [" .. layer .. "]" end
                -- The MUD's own spelling for a stack has never been seen in a
                -- transcript, so this one is ours rather than a guess at theirs.
                local count = safeNum(it.count)
                if count ~= nil and count > 1 then nm = nm .. " (x" .. count .. ")" end
                if withSlot then
                    local slot = it.slot
                    if type(slot) == "string" and trimBoth(slot) ~= "" then
                        nm = "<" .. trimBoth(slot) .. "> " .. nm
                    end
                end
                rows[#rows + 1] = nm
            end
        end
    end
    return rows
end

local function acceptGear(root)
    if src.items ~= "gmcp" then return false end
    if type(root) ~= "table" then return false end

    local got = false
    local eq = gearRows(root.equipment, true)
    if eq ~= nil then
        gear.list.eq = eq
        gear.seen.eq = true
        gear.stale.eq = false
        got = true
    end
    local inv = gearRows(root.inventory, false)
    if inv ~= nil then
        gear.list.inv = inv
        gear.seen.inv = true
        gear.stale.inv = false
        got = true
    end
    return got
end
gear.gag = false

-- The word a MUD command can address this item by, and nothing else reaches
-- send(). Letters and digits only: an item called 'sword;quit' or one carrying
-- a newline would otherwise turn one click into two commands.
--
-- Last word of the name is the guess. SMAUG matches on keywords and the last
-- word usually is one; a miss costs a 'you do not have that' and nothing more.
--
-- And never the whole name, which is not just cautious -- it does not work.
-- Measured on this MUD:
--
--     remove kaioshin's ring   ->  You are not using that item.
--     remove kaioshins ring    ->  You are not using that item.
--     remove kaioshin ring     ->  You stop using Kaioshin's Ring.
--
-- An apostrophe is not part of any keyword, and neither is the 's' after it.
-- '%a+' walks runs of letters, so it steps over both without being told.
-- Every word of an item name is a keyword on this MUD, so WHICH word this picks
-- is cosmetic rather than a correctness question. Proven:
--
--     look in resilient  ->  Resilient Backpack contains:
--     look in backpack   ->  Resilient Backpack contains:
--
-- The apostrophe is the part that matters, and it is excluded from all of them.
--
-- Words that are never the item.
gear.SKIP = {
    a = true, an = true, the = true, of = true, with = true,
    ["and"] = true, some = true, pair = true,
}

-- Two keywords in quotes, which is how you name one item and not another.
--
-- An ordinal cannot do it. Eight pieces of this character's equipment key on
-- 'kaioshin', so 'remove 3.kaioshin' counts in the MUD's order while the list
-- counts in its own, and when they disagree you remove something you did not
-- click. Measured:
--
--     remove kaioshin belt      ->  You stop using Kaioshin's Ring.
--     remove "kaioshin belt"    ->  You stop using Kaioshin's Belt.
--
-- Unquoted, only the first word is the target and the rest is ignored.
--
-- The two words do NOT have to be adjacent in the name -- a quoted phrase is a
-- set of keywords that all have to match:
--
--     get "fur raz" from backpack  ->  Fur of the Raz'N'Lak
--
-- so first-and-last is a good pair: they are the two most likely to be
-- distinctive, and two words are likelier to both be keywords than four.
--
-- Two genuinely identical items stay interchangeable, which is fine -- removing
-- either one is the same act.
local function itemPhrase(name)
    local s = tostring(name or "")
    s = s:gsub("<[^<>]*>", " ")
    s = s:gsub("%([^()]*%)", " ")

    local words = {}
    for word in s:gmatch("%a+") do
        local low = word:lower()
        -- single letters are the 'N' in Raz'N'Lak, never a keyword
        if not gear.SKIP[low] and #low > 1 then words[#words + 1] = low end
    end
    if #words == 0 then return "" end
    if #words == 1 then return words[1] end
    return words[1] .. " " .. words[#words]
end

-- A data-mud-data value on its way back in from the client, rebuilt as a
-- lowercase phrase of letters and single spaces.
--
-- Two reasons it is rebuilt rather than trimmed. It is markup this plugin
-- emitted and the client handed back, so it is untrusted on the way in and must
-- not be able to carry a quote or a command separator into send(). And a value
-- that never arrived is JavaScript undefined rather than nil, which tostring()
-- turns into the literal string "undefined" -- which is how 'get "fur raz" from
-- "undefined"' reached the MUD.
--
-- What it produces has to match itemPhrase, because that is the key the render
-- emitted and the key every per-item table is filed under.
local function actPhrase(v)
    if type(v) ~= "string" then return "" end
    local out = ""
    for word in v:gmatch("%a+") do
        if out == "" then out = word:lower() else out = out .. " " .. word:lower() end
    end
    return out
end

local function itemsHeader(kind, text)
    if kind == "ana" then return text:find("Object:", 1, true) ~= nil end
    if kind == "inv" then return text:find("You are carrying", 1, true) ~= nil end
    if kind == "eq" then
        if text:find("You are using", 1, true) then return true end
        if text:find("You are wearing", 1, true) then return true end
        return false
    end
    if kind == "cont" then return text:find("contains:", 1, true) ~= nil end
    return false
end

-- '<used as light>' spends most of its width saying nothing. Cut it to the slot
-- alone so the list earns the space back. The specific prefixes go first and
-- the bare 'worn ' last, which is what turns '<worn about body>' into
-- '<about body>' rather than '<body>' -- a different slot. Anchored on '<' so
-- an item NAMED something-worn is left alone.
local function stripEqSlot(text)
    local out = text:gsub("<used as ", "<")
    out = out:gsub("<worn around ", "<")
    out = out:gsub("<worn on ", "<")
    out = out:gsub("<worn over ", "<")
    out = out:gsub("<worn as ", "<")
    out = out:gsub("<worn ", "<")
    out = out:gsub("<wielded", "<wield")
    return out
end

local function finishCapture()
    -- Drop a trailing row that is the prompt. Whether onLine or the trigger
    -- sees a prompt line first is not something this can rely on, so when
    -- onLine wins the line is captured and taken off again here.
    if cap.n > 0 and cap.promptLine
        and cap.lines[cap.n] == cap.promptLine then
        cap.lines[cap.n] = nil
        cap.n = cap.n - 1
    end

    if cap.kind == "ana" and cap.n > 0 and cap.target then
        cont.anaOf[cap.target] = cap.lines
        cont.anaOpen[cap.target] = true
        capDone = capDone + 1
        cap.dirty = true
        cap.kind = nil
        cap.armed = nil
        cap.target = nil
        cap.lines = {}
        cap.n = 0
        cap.silent = false
        return
    end

    if cap.kind == "cont" and cap.n > 0 and cap.target then
        cont.list[cap.target] = cap.lines
        -- Deliberately NOT opening it here. Expanding a row is the open button's
        -- job and nothing else's, so a 'look in' you typed yourself fills the
        -- contents in and leaves the row as it found it. The button sets the
        -- flag before it sends, so its own reply still lands expanded.
        cont.is[cap.target] = true
        capDone = capDone + 1
        cap.dirty = true
        cap.kind = nil
        cap.armed = nil
        cap.target = nil
        cap.lines = {}
        cap.n = 0
        cap.silent = false
        return
    end

    if cap.kind and cap.n > 0 then
        gear.list[cap.kind] = cap.lines
        gear.stale[cap.kind] = false
        gear.seen[cap.kind] = true
        capDone = capDone + 1
        cap.dirty = true
    end
    cap.kind = nil
    cap.armed = nil
    cap.lines = {}
    cap.n = 0
    cap.silent = false
end

-- Fed every line. Returns true when the line should be hidden, which is only
-- ever a gagged capture -- the prompt that ends a block is never hidden here,
-- because the rest of the plugin is still reading it.
local function feedItems(clean)
    if cap.armed and not cap.kind then
        -- The reply never came: a mistyped command, or the MUD said no. Stand
        -- down rather than swallowing whatever arrives next.
        if (os.clock() - cap.at) > 3.0 then
            capStand = capStand + 1
            cap.armed = nil
            return false
        end
        if itemsHeader(cap.armed, clean) then
            capHead = capHead + 1
            cap.kind = cap.armed
            cap.armed = nil

            -- The container names itself: 'Resilient Backpack contains:'. Take
            -- the keyword from that rather than from what was typed -- 'look in
            -- bag' and a row reading 'Resilient Backpack' would otherwise file
            -- under 'bag' and the row would never find it.
            if cap.kind == "ana" then
                -- 'Object: Kaioshin's Sword' names it, and that is what it gets
                -- filed under -- not the word that was typed, which may be any
                -- one of its keywords.
                local named = clean:match("^Object:%s*(.+)$")
                if type(named) == "string" and named ~= "" then
                    local k = itemPhrase(named)
                    if k ~= "" then cap.target = k end
                end
            end

            if cap.kind == "cont" then
                local named = clean:match("^(.+)%s+contains:")
                if type(named) == "string" and named ~= "" then
                    local k = itemPhrase(named)
                    if k ~= "" then cap.target = k end
                end
            end

            -- 'You are carrying:' is the header, not an item. It used to fall
            -- through and become the first row of its own list.
            return false
        else
            -- kept so a header that should have matched can be looked at
            if clean ~= "" then capSaw = clean end
            return false
        end
    end
    if not cap.kind then return false end

    -- The prompt ends a block, and promptFeed -- the TRIGGER callback -- is what
    -- says a prompt went past. Not promptRead: its Lua patterns match nothing
    -- in this client, which diag showed as luaHits=0 against 255 tries with the
    -- real prompt going by seven times.
    --
    -- If the trigger got here first, this line is the prompt and the block is
    -- already closed. If it did not, capEnd is set by the time the next line
    -- arrives and the prompt is dropped from the list on the way out.
    if cap.endNow then
        cap.endNow = false
        finishCapture()
        return false
    end

    -- Second terminator, and deliberately kept even though it does nothing in
    -- the client: under real Lua the compiled patterns DO match, so this is what
    -- the suite exercises. Inert where the trigger works, load-bearing where the
    -- trigger does not exist.
    if promptRead(clean) then
        finishCapture()
        return false
    end

    -- The blank line the MUD prints before the prompt never reaches onLine at
    -- all -- the probe showed the items running straight into '(LifeForce:...' --
    -- so this is a fallback for a server that does send one, not the terminator.
    if clean == "" and cap.n > 0 then
        finishCapture()
        return false
    end

    -- The MUD lists every equipment slot, empty ones included, and a dozen rows
    -- saying Nothing is most of the panel. Both shapes are dropped -- the
    -- literal word and a slot with nothing after it -- because which one this
    -- MUD sends has never been captured here, and nothing is named 'Nothing'.
    -- Still gagged on the way out if the gag is on: dropped from the list is not
    -- the same as dropped from the screen.
    local row = clean
    if cap.kind == "eq" then
        row = stripEqSlot(clean)
        local rest = row:match("^<[^<>]+>%s*(.*)$")
        if type(rest) == "string" then
            local bare = rest:lower()
            if bare == "" or bare == "nothing" or bare == "nothing." then
                return gear.gag == true or cap.silent == true
            end
        end
    end

    cap.n = cap.n + 1
    cap.lines[cap.n] = row
    if cap.n >= gear.MAX then finishCapture() end
    return gear.gag == true or cap.silent == true
end

-- Keep the lists current without asking the MUD anything.
--
-- Re-running 'inv' on every pickup means a command per corpse during a grind,
-- and a block of output with it. The messages already say what moved, so the
-- data is edited in place and nothing is sent.
--
-- Wordings are from real transcripts, and two of them are traps:
--
--   You get 983 zeni from the corpse of A seasoned soldier   <- currency
--   You put your arm around the injured Yardrat and help...  <- not an item
--
-- so 'put' needs its ' in ' and 'get' needs to not be money.

-- One capture, normalised to a string or a real nil.
--
-- This exists so the wordings below can be an 'or' chain. Written as bare
-- matches they cannot be: a failed match comes back undefined, undefined is
-- truthy, so the chain stops at the first pattern that MISSED and every wording
-- after it is unreachable. Only 'You wear X on ...' ever fired.
local function capOf(s, pat)
    local m = s:match(pat)
    if type(m) ~= "string" then return nil end
    if m == "" then return nil end
    return m
end

-- ipairs, never '#'.
--
-- These lists are built by explicit index during a capture and then
-- table.remove'd by the event reader, and after that '#' does not agree with
-- ipairs. Measured, from a trace and a dump taken seconds apart:
--
--   reader: removed [Resilient Backpack] out of eq=true into inv=true
--   inv 1: [(Glowing) Proof of Tranquility]
--   inv 2: [(Glowing) Sprint Boots]
--
-- Inventory held three rows, the backpack was worn (table.remove, two rows
-- left), then taken off again. 'rows[#rows + 1] = name' wrote to slot 4 because
-- '#' still reported the length from before the removal. The assignment
-- succeeded, listAdd returned true, and ipairs stopped at the hole -- so the
-- row existed and nothing that walks the list could see it. Four releases of
-- 'the add fails' were the add succeeding into a place no reader looks.
--
-- Counting the way every reader walks it cannot disagree with the readers.
-- Real Lua's '#' is correct here, so the suite says nothing about any of this.
local function rowCount(rows)
    if type(rows) ~= "table" then return 0 end
    local n = 0
    for _ in ipairs(rows) do n = n + 1 end
    return n
end

local function listDrop(kind, name)
    local rows = gear.list[kind]
    if type(rows) ~= "table" or name == "" then return false end
    local want = itemPhrase(name)
    if want == "" then return false end
    for i, row in ipairs(rows) do
        if itemPhrase(row) == want then
            table.remove(rows, i)
            return true
        end
    end
    return false
end

local function listAdd(kind, name)
    local rows = gear.list[kind]
    if type(rows) ~= "table" or name == "" then return false end
    -- Never invent a list: adding to one that was never captured would put a
    -- single row up and claim that is everything you own.
    --
    -- The row count is half of the test and it matters. A list WITH rows in it
    -- has plainly been captured, whatever the flag says, and testing the flag
    -- alone was stricter than the rule it is there to enforce -- it dropped
    -- items out of both lists in both directions, silently, on 0.31.0.
    local n = rowCount(rows)
    if n == 0 and not gear.seen[kind] then return false end
    rows[n + 1] = name
    return true
end

local function feedItemEvent(clean)
    ev.seen = ev.seen + 1
    -- Anything starting 'You ' is a candidate, kept so a wording that should
    -- have matched can be read back verbatim.
    if clean:sub(1, 4) == "You " then ev.last = clean end
    -- Money first, or 'You get 983 zeni' reads as picking up an item called
    -- '983 zeni' and the inventory grows one per corpse.
    local coin = clean:match("^You get ([%d,]+) zeni")
    if type(coin) == "string" then
        local n = promptNum(coin)
        -- type(), not truthiness. A key charState has never held comes back
        -- undefined, undefined is truthy, and 'undefined + 1303' is NaN -- which
        -- then survives every later addition, because NaN plus anything is NaN
        -- and NaN is truthy too. A live diag read 'zeni=NaN' beside 'last item
        -- move: zeni +1303', which is exactly this: the running total was
        -- poisoned on the first coin picked up and never recovered.
        --
        -- Seeded off the sheet when the prompt has not supplied one, since score
        -- carries zeni and is usually the earlier of the two.
        local have = charState.zeni
        if type(have) ~= "number" then have = safeNum(sc.zeni) end
        if n and type(have) == "number" then
            charState.zeni = have + n
            ev.hit = ev.hit + 1
            ev.why = "zeni " .. tostring(have) .. " +" .. tostring(n)
            return true
        end
        ev.why = "zeni [" .. coin .. "] not added: have=" .. tostring(have)
        return false
    end

    local got = capOf(clean, "^You get (.+) from ")
    if got ~= nil then
        ev.hit = ev.hit + 1
        ev.why = "got [" .. got .. "] into inv=" .. tostring(listAdd("inv", got))
        -- and out of the bag it came from, so an open contents list stays right
        local fromWhat = capOf(clean, "^You get .+ from (.+)%.$")
        local inside = nil
        if fromWhat ~= nil then inside = cont.list[itemPhrase(fromWhat)] end
        if type(inside) == "table" then
            local want = itemPhrase(got)
            for i, row in ipairs(inside) do
                if itemPhrase(row) == want then
                    table.remove(inside, i)
                    break
                end
            end
        end
        return true
    end

    local dropped = capOf(clean, "^You drop (.+)%.$")
    if dropped ~= nil then
        ev.hit = ev.hit + 1
        local outInv = listDrop("inv", dropped)
        ev.why = "dropped [" .. dropped .. "] out of inv=" .. tostring(outInv)
        return outInv
    end

    local putIn = capOf(clean, "^You put (.+) in (.+)%.$")
    if putIn ~= nil then
        ev.hit = ev.hit + 1
        ev.why = "put [" .. putIn .. "] out of inv=" .. tostring(listDrop("inv", putIn))
        -- and into the bag, so an open contents list gains it
        local intoWhat = capOf(clean, "^You put .+ in (.+)%.$")
        local bag = nil
        if intoWhat ~= nil then bag = cont.list[itemPhrase(intoWhat)] end
        if type(bag) == "table" then bag[rowCount(bag) + 1] = putIn end
        return true
    end

    -- Worn: out of inventory and into equipment.
    --
    -- The verb is per slot on this MUD and there is no list of them -- 'wear',
    -- 'place' and 'slip' were the guesses, and then a backpack produced 'You
    -- sling Resilient Backpack on your back.' So the SHAPE is what is matched,
    -- 'You <verb> <item> <preposition> your <slot>.', and the verb is left
    -- alone.
    --
    -- That is loose enough to catch an emote, so it only counts when the thing
    -- named is already in inventory: you cannot put on what you are not
    -- carrying, and no emote names a row in your own list. listDrop doing the
    -- deciding is the whole guard.
    --
    -- The slot is read on its own (sharp edge 13, one guard per value) and left
    -- greedy so a two-word one like 'left finger' survives intact.
    local worn = capOf(clean, "^You %S+ (.+) %S+ your .+%.$")
    if worn ~= nil and not listDrop("inv", worn) then
        -- The shape matched and the item was not in inventory, so this is
        -- either an emote or a list that has drifted. Worth telling apart from
        -- 'nothing matched at all', which reads identically from the panel.
        ev.why = "wear-shaped [" .. worn .. "] but not in inv, ignored"
        return false
    end
    if worn ~= nil then
        local slot = "worn"
        local s = capOf(clean, "%S+ your (.+)%.$")
        if s ~= nil then slot = s:lower() end
        ev.hit = ev.hit + 1
        local intoEq = listAdd("eq", "<" .. slot .. ">  " .. worn)
        if not intoEq then gear.stale.eq = true end
        ev.why = "wore [" .. worn .. "] slot [" .. slot .. "] into eq="
            .. tostring(intoEq)
        return true
    end

    -- Neither of these carries a slot, so they name their own.
    local wielded = capOf(clean, "^You wield (.+)%.$")
    local held = capOf(clean, "^You hold (.+)%.$")
    if wielded ~= nil or held ~= nil then
        local name, slot = wielded, "wield"
        if held ~= nil then name = held; slot = "hold" end
        ev.hit = ev.hit + 1
        local outInv = listDrop("inv", name)
        local intoEq = listAdd("eq", "<" .. slot .. ">  " .. name)
        if not intoEq then gear.stale.eq = true end
        ev.why = slot .. " [" .. tostring(name) .. "] out of inv="
            .. tostring(outInv) .. " into eq=" .. tostring(intoEq)
        return true
    end

    local doffed = capOf(clean, "^You stop using (.+)%.$")
    if doffed ~= nil then
        ev.hit = ev.hit + 1
        local outEq = listDrop("eq", doffed)
        local intoInv = listAdd("inv", doffed)
        if not outEq then gear.stale.eq = true end
        if not intoInv then gear.stale.inv = true end
        ev.why = "removed [" .. doffed .. "] out of eq=" .. tostring(outEq)
            .. " into inv=" .. tostring(intoInv)
        return true
    end

    -- Nothing claimed it. Worth recording for a 'You ' line, because "the
    -- reader refused" and "the reader was never reached" look identical from
    -- the panel and only one of them is a pattern problem.
    if clean:sub(1, 4) == "You " then
        ev.why = "no rule matched [" .. clean .. "]"
    end
    return false
end

-- The auction channel, which names the item in full. The prompt's %o token
-- abbreviates -- 'i battle armor' where the channel says 'Class I Battle
-- Armor' -- so a channel name is not traded back for a prompt one.
--
-- Every wording the channel uses, all eight, taken out of two days of
-- transcript rather than guessed:
--
--   Auction: A new item is being auctioned: Class I Battle Armor at 0 zeni.
--   Auction: A bid of 500 zeni has been received on Armor of the Majin.
--   Auction: Armor of the Majin: going once (bid not received yet).
--   Auction: Armor of the Majin: going once for 500.
--   Auction: Armor of the Majin: going twice (bid not received yet).
--   Auction: Armor of the Majin: going twice for 500.
--   Auction: A Headdress of Eagle Feathers sold to Brettan for 12000.
--   Auction: No bids received for Class I Battle Armor - removed from auction.
--
-- Checked against all 224 distinct auction lines in the log: nothing missed.
-- 'going once' is left unanchored past the verb because it takes both the
-- with-a-bid and the without-a-bid tail.
--
-- Item names on this MUD are hostile -- '<<Orb>> of <<Infinity>>', '[TCG]
-- Raditz Booster Pack [DBI]', 'Hardened \Ginyu Force/ Battle Gauntlets',
-- 'A Ribbed )\/(ajin Vestment'. They survive because the name is always a
-- greedy capture and never a character class, and the footer escapes on the
-- way out.
--
-- A bid and both 'going' calls set rather than only refresh, so joining
-- part-way through an auction still fills the footer.
local function feedAuction(clean)
    -- The channel still runs the pill when GMCP is switched off. It is also
    -- the only thing that knows a sale from an expiry, so it keeps reading
    -- either way -- this only decides who sets the item.
    if src.auc == "gmcp" then return false end
    local gone = capOf(clean,
        "^Auction:%s+No bids received for (.+) %- removed from auction%.$")
        or capOf(clean, "^Auction:%s+(.+) sold to %S+ for %S+%.$")
    if gone ~= nil then
        charState.auction = nil
        charState.auctionSrc = nil
        return true
    end

    local fresh = capOf(clean,
        "^Auction:%s+A new item is being auctioned:%s+(.+) at %S+ zeni%.$")
        or capOf(clean,
            "^Auction:%s+A bid of %S+ zeni has been received on (.+)%.$")
        or capOf(clean, "^Auction:%s+(.+): going once")
        or capOf(clean, "^Auction:%s+(.+): going twice")
    if fresh ~= nil then
        charState.auction = fresh
        charState.auctionSrc = "chan"
        return true
    end
    return false
end

local function beginCapture(kind, silent)
    capArms = capArms + 1
    cap.lines = {}
    cap.n = 0
    cap.silent = silent == true
    cap.kind = nil          -- armed, not capturing: the header starts it
    cap.armed = kind
    cap.at = os.clock()
end

-- One captured list. Kept separate from the sheet on purpose: inventory is
-- likely to move to its own plugin later, and this is the piece that goes.
--
-- Colour is dropped. The version this came from emitted <span style="color:...">
-- per segment and the sanitiser eats inline colour (sharp edge 9), so it would
-- have rendered monochrome anyway -- and the names and the buttons are what the
-- list is for.
local function itemsBody(kind)
    local t = {}
    local function add(x) t[#t + 1] = x end

    local rows = gear.list[kind]
    if type(rows) ~= "table" or (rowCount(rows) == 0 and not gear.seen[kind]) then
        local what = "inv"
        if kind == "eq" then what = "eq" end
        if kind == "cont" then what = "look in <container>" end
        return '<div class="idle">nothing captured yet<br><br>type <b>'
            .. what .. "</b> and it fills in</div>"
    end
    if rowCount(rows) == 0 then return '<div class="idle">nothing here</div>' end

    add('<div class="items">')
    if kind == "inv" or kind == "eq" then
        local ask = "inv"
        if kind == "eq" then ask = "eq" end
        add('<div class="ihead"><span class="ib" data-mud-action="itref"')
        add(' data-mud-data="' .. ask .. '">refresh</span></div>')
    end
    if gear.stale[kind] then
        add('<div class="stale">this may be out of date</div>')
    end

    for _, line in ipairs(rows) do
        local name = trimBoth(tostring(line or ""))
        if name ~= "" then
            -- itemPhrase, not itemKeyword. The keyword is the FIRST
            -- significant word, and eight pieces of this character's equipment
            -- begin 'Kaioshin' -- so every one of them shared a key. Clicking
            -- info on the sword expanded all eight and showed the sword's
            -- reading under each, and removing the belt took the ring off the
            -- list instead. First-and-last tells them apart, and it is already
            -- what the buttons send.
            local key = itemPhrase(name)
            local act = ""
            -- Declared out here because the take button on a container's
            -- contents needs it too, and it sits below this block. Inside, it
            -- resolved as a nil global under real Lua -- no error, a take button
            -- built from nothing -- and threw outright in the client:
            --   render error: Can't find variable: target
            local target = ""
            if key ~= "" then
                target = key
                if kind == "eq" then
                    act = '<span class="ib" data-mud-action="itrem" data-mud-data="'
                        .. escapeHtml(target) .. '">remove</span>'
                else
                    act = '<span class="ib" data-mud-action="itwear" data-mud-data="'
                        .. escapeHtml(target) .. '">wear</span>'
                end

                -- A bag is a bag whether it is in your hands or on your back,
                -- so this hangs off the item rather than off which tab it is.
                -- Only something that has answered a 'look in' with a contents
                -- block gets it. The open marker is keyed on the keyword, not
                -- the ordinal, so two bags of the same name share no state.
                -- what 'ana' knows, if it has been asked
                local imark = "info"
                if cont.anaOpen[key] then imark = "hide" end
                act = act .. '<span class="ib" data-mud-action="itana" data-mud-data="'
                    .. escapeHtml(target) .. '">' .. imark .. "</span>"

                if cont.is[key] then
                    local mark = "open"
                    if cont.open[key] then mark = "close" end
                    act = act
                        .. '<span class="ib" data-mud-action="itlook" data-mud-data="'
                        .. escapeHtml(target) .. '">' .. mark .. "</span>"
                    -- only while it is open: closed, there is nothing on show
                    -- to be out of date
                    if cont.open[key] then
                        act = act .. '<span class="ib" data-mud-action="itref"'
                            .. ' data-mud-data="cont~' .. escapeHtml(target)
                            .. '">refresh</span>'
                    end
                end
            end
            -- Equipment splits into its own two columns: the slot, then the
            -- item. Read as two separate matches rather than one two-capture
            -- one, and only used when BOTH arrive -- a row that is not slot
            -- shaped falls through and renders whole.
            local slotTxt = nil
            local bodyTxt = name
            if kind == "eq" then
                local s1 = capOf(name, "^<([^<>]+)>")
                local s2 = capOf(name, "^<[^<>]+>%s*(.+)$")
                if s1 ~= nil and s2 ~= nil then
                    slotTxt = s1
                    bodyTxt = s2
                end
            end

            -- The name is ellipsised to fit beside the buttons, so the whole of
            -- it goes in a title. It is the only way to read a long one.
            local cols = ""
            if slotTxt ~= nil then
                cols = '<span class="islot" title="' .. escapeHtml(slotTxt)
                    .. '">' .. escapeHtml(slotTxt) .. "</span>"
            end
            cols = cols .. '<span class="itx" title="' .. escapeHtml(name) .. '">'
                .. escapeHtml(bodyTxt) .. "</span>"
            add('<div class="iline">' .. cols .. act .. "</div>")

            -- What 'ana' said, in place. Blank lines and the stat block are
            -- kept as they came: it is reference text, not a list.
            if cont.anaOpen[key] and type(cont.anaOf[key]) == "table" then
                for _, ln in ipairs(cont.anaOf[key]) do
                    local t2 = trimBoth(tostring(ln or ""))
                    if t2 ~= "" then
                        add('<div class="isub">' .. escapeHtml(t2) .. "</div>")
                    end
                end
            end

            -- What is inside, in place, indented under it. Only for a container
            -- that has been opened and looked in.
            if cont.open[key] and type(cont.list[key]) == "table" then
                local inside = cont.list[key]
                if rowCount(inside) == 0 then
                    add('<div class="isub iempty">empty</div>')
                end
                for _, sub in ipairs(inside) do
                    local subName = trimBoth(tostring(sub or ""))
                    if subName ~= "" then
                        -- 'get "fur raz" from resilient': both the item and the
                        -- bag by quoted keyword pair, which is the only form
                        -- proven to name one thing and not another.
                        local subT = itemPhrase(subName)
                        local take = ""
                        if subT ~= "" and target ~= "" then
                            -- '~' and not '|'. A bar is alternation once the
                            -- pattern is translated, so splitting on it matched
                            -- an empty alternative and handed back undefined.
                            take = '<span class="ib" data-mud-action="ittake"'
                                .. ' data-mud-data="' .. escapeHtml(subT)
                                .. "~" .. escapeHtml(target) .. '">take</span>'
                        end
                        add('<div class="iline isub"><span class="itx" title="'
                            .. escapeHtml(subName) .. '">' .. escapeHtml(subName)
                            .. "</span>" .. take .. "</div>")
                    end
                end
            end
        end
    end
    add("</div>")
    return table.concat(t)
end

-- Everything the panel remembers, on one screen.
--
-- Inputs are identified by id and read on keyup, because data-mud-action fires
-- on a CLICK and typing does not click. Each field has its own submit button;
-- the form wrapper gives Enter the same effect.
local function cfgBody()
    local t = {}
    local function add(x) t[#t + 1] = x end

    local function onoff(flag)
        if flag then return "on" end
        return "off"
    end

    add('<div class="pad cfg">')

    -- The two prompt formats. This MUD answers 'prompt' with '(default
    -- prompt)' rather than the format, so detect cannot always learn one --
    -- which is exactly why they are typeable.
    add('<div class="sec">prompt formats</div>')
    for _, which in ipairs({ "prompt", "fprompt" }) do
        local now = pr.learnedFor[which]
        if type(now) ~= "string" or now == "" then now = "(stock)" end
        add('<div class="crow"><span class="ck">' .. which .. "</span>")
        add('<span class="cv">' .. escapeHtml(now) .. "</span></div>")
        add('<form class="crow" id="frm' .. which .. '" data-mud-action="setfmt"'
            .. ' data-mud-data="' .. which .. '">')
        add('<input id="cfg' .. which .. '" type="text" placeholder="%h, %m, %Y ..."')
        add(' value="' .. escapeHtml(edit[which]) .. '">')
        add('<span class="tb" data-mud-action="setfmt" data-mud-data="' .. which
            .. '">set</span>')
        add('<span class="tb" data-mud-action="detect" data-mud-data="' .. which
            .. '">detect</span></form>')
    end

    add('<div class="sec">display</div>')
    add('<div class="crow"><span class="ck">prompt gag</span>')
    add('<span class="tb" data-mud-action="cfgtog" data-mud-data="gag">'
        .. onoff(gag.on) .. "</span></div>")
    add('<div class="crow"><span class="ck">hide captured lists</span>')
    add('<span class="tb" data-mud-action="cfgtog" data-mud-data="itemsgag">'
        .. onoff(gear.gag) .. "</span></div>")
    add('<div class="crow"><span class="ck">power level</span>')
    add('<span class="tb" data-mud-action="cfgtog" data-mud-data="plmode">'
        .. panel.plMode .. "</span></div>")
    add('<div class="sec">where the numbers come from</div>')
    add('<div class="crow"><span class="ck">armor + enemy</span>')
    add('<span class="tb" data-mud-action="cfgtog" data-mud-data="src">'
        .. src.bars .. "</span></div>")
    add('<div class="crow"><span class="ck">stats</span>')
    add('<span class="tb" data-mud-action="cfgtog" data-mud-data="srcstats">'
        .. src.stats .. "</span></div>")
    add('<div class="crow"><span class="ck">inventory + equipment</span>')
    add('<span class="tb" data-mud-action="cfgtog" data-mud-data="srcitems">'
        .. src.items .. "</span></div>")
    add('<div class="crow"><span class="ck">auction</span>')
    add('<span class="tb" data-mud-action="cfgtog" data-mud-data="srcauc">'
        .. src.auc .. "</span></div>")

    add('<div class="crow"><span class="ck">text size</span>')
    add('<span class="tb" data-mud-action="cfgnudge" data-mud-data="font-">-</span>')
    add('<span class="cv">' .. math.floor(panel.font.scale * 100 + 0.5) .. "%</span>")
    add('<span class="tb" data-mud-action="cfgnudge" data-mud-data="font+">+</span></div>')

    add('<div class="crow"><span class="ck">opacity</span>')
    add('<span class="tb" data-mud-action="cfgnudge" data-mud-data="alpha-">-</span>')
    add('<span class="cv">' .. math.floor(panel.alpha * 100 + 0.5) .. "%</span>")
    add('<span class="tb" data-mud-action="cfgnudge" data-mud-data="alpha+">+</span></div>')

    add('<div class="sec">this character</div>')
    local shownAv = avatarUrl
    if shownAv == "" then shownAv = "(by race)" end
    add('<div class="crow"><span class="ck">avatar</span>')
    add('<span class="cv">' .. escapeHtml(shownAv) .. "</span></div>")
    add('<form class="crow" id="frmavatar" data-mud-action="setav">')
    add('<input id="cfgavatar" type="text" placeholder="https://..." value="'
        .. escapeHtml(edit.avatar) .. '">')
    add('<span class="tb" data-mud-action="setav">set</span>')
    add('<span class="tb" data-mud-action="clearav">clear</span></form>')

    local shownNm = profile.override
    if shownNm == "" then shownNm = "(from score)" end
    add('<div class="crow"><span class="ck">name</span>')
    add('<span class="cv">' .. escapeHtml(shownNm) .. "</span></div>")
    add('<form class="crow" id="frmname" data-mud-action="setnm">')
    add('<input id="cfgname" type="text" placeholder="shown on the bar" value="'
        .. escapeHtml(edit.name) .. '">')
    add('<span class="tb" data-mud-action="setnm">set</span>')
    add('<span class="tb" data-mud-action="clearnm">clear</span></form>')

    -- Transformations. A form pairs the line the MUD prints on entering it with
    -- the portrait to wear while it lasts, and the match is a plain substring
    -- on the whole announcement -- so the message goes in as the MUD writes it,
    -- not as a pattern.
    add('<div class="sec">transformations</div>')

    local sorted = {}
    for fname in pairs(form.ALL) do
        if type(form.ALL[fname]) == "table" then sorted[#sorted + 1] = fname end
    end
    table.sort(sorted)

    if #sorted == 0 then
        add('<div class="crow"><span class="ck">none yet</span>')
        add('<span class="cv">add one below</span></div>')
    end

    for _, fname in ipairs(sorted) do
        local frec = form.ALL[fname]
        local fmark = ""
        if fname == form.name then fmark = ' <span class="fon">active</span>' end
        local shown = frec.url
        if shown == "base" then shown = "(clears the portrait)" end

        add('<div class="crow"><span class="ck">' .. escapeHtml(fname) .. fmark .. "</span>")
        add('<span class="cv">' .. escapeHtml(shown) .. "</span>")
        add('<span class="tb" data-mud-action="delform" data-mud-data="'
            .. escapeHtml(fname) .. '">remove</span></div>')
        add('<div class="fpat">' .. escapeHtml(frec.pat) .. "</div>")
    end

    -- Three fields rather than one line: the announcement is a whole sentence
    -- of the MUD's prose and does not share a row with anything.
    add('<form class="cfrm" id="frmfadd" data-mud-action="addform">')
    add('<input id="cfgfname" type="text" placeholder="name, eg ssj4" value="'
        .. escapeHtml(edit.fname) .. '">')
    add('<input id="cfgfurl" type="text" placeholder="image url, or: base" value="'
        .. escapeHtml(edit.furl) .. '">')
    add('<input id="cfgfpat" type="text" placeholder="the line the MUD prints" value="'
        .. escapeHtml(edit.fpat) .. '">')
    add('<span class="tb" data-mud-action="addform">add form</span></form>')

    if form.name ~= "" then
        add('<div class="crow"><span class="ck">wearing <b>'
            .. escapeHtml(form.name) .. "</b></span>")
        add('<span class="tb" data-mud-action="formbase">back to base</span></div>')
    end

    add('<div class="sec">&nbsp;</div>')
    add('<div class="crow"><span class="ck">everything else</span>')
    add('<span class="cv">type <b>dbchar</b></span></div>')

    add("</div>")
    return table.concat(t)
end

local function sheetBody()
    if not sheet.seen then
        return '<div class="idle">no score read yet<br><br>type <b>score</b> and it fills in</div>'
    end

    -- the surname and title live here rather than in the headline, which is
    -- the first name alone
    local out = '<div class="sec">who</div><table>'
        .. row("Name", sc.name) .. row("Surname", sc.last)
        .. row("Rank", sc.rank)
        .. row("Race", sc.race) .. row("Sex", sc.sex) .. row("Age", sc.age)
        .. "</table>"

    out = out .. '<div class="sec">stats</div><table>'
        .. row("Strength", sc.strength) .. row("Speed", sc.speed)
        .. row("Spirit", sc.spirit) .. row("Fortitude", sc.fortitude)
        .. "</table>"

    out = out .. '<div class="sec">body</div><table>'
        .. row("Armor", sc.armor) .. row("Position", sc.position)
        .. row("Style", sc.style)
        .. row("Items", sc.items and (sc.items .. "/" .. tostring(sc.itemsMax)))
        .. row("Weight", sc.weight and (sc.weight .. "/" .. tostring(sc.weightMax)))
        .. "</table>"

    if has(sc.hair) or has(sc.height) then
        local tail = nil
        if sc.tail then tail = "yes" end
        out = out .. '<div class="sec">description</div><table>'
            .. row("Build", sc.build) .. row("Complexion", sc.complexion)
            .. row("Height", sc.height)
            .. row("Weight", sc.weight_lb and (sc.weight_lb .. " lb"))
            .. row("Hair", sc.hair) .. row("Eyes", sc.eyes) .. row("Tail", tail)
            .. "</table>"
    end

    if sc.eq and #sc.eq > 0 then
        out = out .. '<div class="sec">worn</div><table>'
        for _, e in ipairs(sc.eq) do out = out .. row(e.slot, e.item) end
        out = out .. "</table>"
    end

    out = out .. '<div class="sec">record</div><table>'
        .. row("Player kills", sc.pkills) .. row("Player deaths", sc.pdeaths)
        .. row("Mob kills", sc.mkills) .. row("Mob deaths", sc.mdeaths)
        .. row("Spar W/L", sc.sparwins and (sc.sparwins .. " / " .. tostring(sc.sparloss)))
        .. row("Split W/L", sc.splitwins and (sc.splitwins .. " / " .. tostring(sc.splitloss)))
        .. row("Crits", sc.crits) .. row("Tokens", sc.tokens)
        .. "</table>"

    out = out .. '<div class="sec">session</div><table>'
        .. row("PL gained", sc.gainedPl) .. row("Ki gained", sc.gainedKi)
        .. row("EQ bonus", sc.eqBonus and (sc.eqBonus .. "%"))
        .. row("RPP", sc.rpp) .. row("Hours", sc.hours)
        .. row("Created", sc.created)
        .. "</table>"

    return out
end

-- What the title bar shows. The override wins because the player set it on
-- purpose; otherwise the first name alone, and 'Portrait' before score has said
-- who this is.
--
-- Assigned, not declared with 'function headerName()' -- a forward-declared
-- local plus a function declaration is an illegal shadow once transpiled.
profile.header = function()
    -- Whitelisted on the way OUT as well as on the way in. has() rejects the
    -- literal string "undefined", but it decides on type(v), and a value that
    -- crosses the boundary as JS undefined is not something to trust a single
    -- guard with -- the panel has shown the word itself in the headline. So
    -- the winner is proved to be a real, non-empty string before it is
    -- returned, and anything else falls through to the plugin's own name.
    local pick = nil
    if has(profile.override) then pick = profile.override
    elseif has(sc.first) then pick = sc.first
    elseif has(sc.name) then pick = sc.name end
    if type(pick) ~= "string" or pick == "" or pick == "undefined" then
        return "Portrait"
    end
    return pick
end

-- The footer. Fixed under the body so it shows on every tab, which is the point:
-- an auction ends whether or not you are looking at the Stats tab.
--
-- Empty renders nothing at all rather than an empty strip, so it costs no height
-- until it has something to say.
local function footBar()
    local t = {}
    local function add(x) t[#t + 1] = x end

    if type(charState.auction) == "string" and charState.auction ~= "" then
        -- clicking it runs 'auc', which is what you want the moment you notice
        add('<span class="fpill auc" data-mud-action="auc" title="auction">'
            .. escapeHtml(charState.auction) .. "</span>")
    end

    if #t == 0 then return "" end
    return '<div class="foot">' .. table.concat(t) .. "</div>"
end

local function render()
    if not panel.id then return end
    readTerminalFont()

    -- Asking the MUD is a button on every tab, and only a button. Nothing here
    -- sends on a timer any more.
    local ask = '<div class="ihead"><span class="ib" data-mud-action="itref"'
        .. ' data-mud-data="score">refresh</span></div>'

    local inner = ""
    if panel.view == "cfg" then
        inner = cfgBody()
    elseif panel.view == "sheet" then
        inner = '<div class="pad">' .. ask .. sheetBody() .. "</div>"
    elseif panel.view == "inv" or panel.view == "eq" then
        inner = itemsBody(panel.view)
    elseif sheet.seen or vit then
        inner = '<div class="pad">' .. ask .. "</div>" .. portraitBody()
    else
        inner = '<div class="pad">' .. ask .. "</div>"
            .. '<div class="idle">waiting on the character<br><br>'
            .. "type <b>score</b>, or press refresh above</div>"
    end

    setWidgetProperty(panel.id, "content", css()
        .. '<div class="dbi-port">'
        -- First name only. It shares this row with the buttons, and the full
        -- form was being cut off mid-word -- 'Arashi The' rather than a name.
        -- A name override is shown whole; the player chose its length.
        .. '<div class="bar"><span class="ttl">'
        .. escapeHtml(profile.header()) .. "</span>"
        .. '<span class="dot"></span><span class="sp"></span>'
        .. '<span class="tb" data-mud-action="cfg" title="settings">&#9881;</span>'
        .. '<span class="tb" data-mud-action="close">hide</span></div>'
        -- Fixed chrome, both of these: the portrait shows on every tab and the
        -- strip stays put while the body scrolls under it.
        .. faceHtml()
        .. tabStrip()
        .. '<div class="body">' .. inner .. "</div>"
        .. footBar()
        .. "</div>")
end

-- The settings screen repaints ONLY when you touch it.
--
-- render() rebuilds the whole content string, which replaces the DOM -- and
-- replacing an <input> takes the caret and whatever was half-typed in it with
-- it. The panel is driven off the prompt and the vitals push, so it rebuilds
-- every combat round: a url long enough to be worth pasting could not be typed
-- at all. MUD-driven repaints therefore hold while the settings view is up;
-- there are no live numbers on it to go stale. Anything the user did passes
-- force.
local function safeRender(force)
    if panel.view == "cfg" and not force then return end
    local ok, err = pcall(render)
    if not ok then
        lastError = tostring(err)
        print(TAG .. "render error: " .. lastError)
    end
end

-- comm.auction: { item, bid }, nulled when nothing is up.
--
-- The pill only ever shows the item, and this states it outright -- no
-- waiting for the next channel line, and nothing an item name can do to it.
-- Names on this MUD are hostile: '<<Orb>> of <<Infinity>>', 'Hardened
-- \Ginyu Force/ Battle Gauntlets'.
--
-- It also answers the case the channel cannot: connecting part-way through an
-- auction, where the footer stays empty until somebody bids.
--
-- The channel parsing stays. It is the only thing that knows a sale from an
-- expiry, and Codex's price history is built on that distinction -- this just
-- takes the pill off it.
local onAuction = nil
onAuction = function(data)
    if src.auc ~= "gmcp" then return end
    local t = data
    if type(t) == "table" and type(t.auction) == "table" then t = t.auction end
    if type(t) ~= "table" then return end

    local item = t.item
    if type(item) ~= "string" or item == "" or item == "undefined" then
        -- nulled: the auction is over, whichever way it went
        if charState.auction ~= nil then
            charState.auction = nil
            charState.auctionSrc = nil
            safeRender()
        end
        return
    end
    if charState.auction ~= item then
        charState.auction = item
        charState.auctionSrc = "gmcp"
        safeRender()
    end
end

-- A target packet. Every field checked on its own: a missing one arrives as
-- undefined, which is truthy and is not nil.
onTarget = function(data)
    local t = data
    if type(t) == "table" and type(t.target) == "table" then t = t.target end
    if type(t) ~= "table" then return end

    local nm = t.name
    if type(nm) ~= "string" or nm == "" or nm == "undefined" then nm = nil end
    local hp = safeNum(t.hit)

    -- NO OPPONENT. The MUD sends the whole packet with every field null when
    -- there is nothing to fight:
    --
    --     "target": { "name": null, "hit": null, "max_hit": null, "race": null }
    --
    -- Each field was being read correctly and then nothing happened with the
    -- answer: foe.hit is set here and was cleared nowhere in the file, and the
    -- bar prefers it over the prompt's figure. So the first GMCP target of a
    -- session pinned an enemy bar on the panel and left it there -- the
    -- prompt's clear and the stale timer only ever touched foe.val.
    --
    -- A null name with no health beside it is the end of a fight, and it says
    -- so more plainly than any line does.
    if nm == nil and hp == nil then
        if foe.name ~= nil or foe.hit ~= nil then
            foe.name, foe.hit, foe.peak, foe.max, foe.race = nil, nil, nil, nil, nil
            foe.why = "char.target came back empty"
            safeRender()
        end
        return
    end

    -- A different thing is a different fight, so the peak starts again. Without
    -- this the bar would read against whatever the last target's health was.
    if nm ~= nil and nm ~= foe.name then
        foe.name = nm
        foe.peak = nil
        foe.max = nil
        foe.val = nil
    end
    if type(t.race) == "string" then foe.race = t.race end

    -- A real ceiling if the MUD sends one. char.vitals spells it 'max_hit', so
    -- that is the likelier of the two, but both are read -- separately, because
    -- a field the packet does not carry arrives as undefined, which is truthy.
    local mx = safeNum(t.max_hit)
    if mx == nil then mx = safeNum(t.maxHit) end
    if mx ~= nil and mx > 0 then foe.max = mx end

    if hp ~= nil then
        foe.hit = hp
        if not safeNum(foe.peak) or hp > foe.peak then foe.peak = hp end
        foe.at = os.clock()
    end
    safeRender()
end

----------------------------------------------------------------------
-- widget
----------------------------------------------------------------------

-- saveTable rather than setVariable.
--
-- setVariable only persists across a reload when the plugin's saveState
-- setting is on, and that is a switch the USER owns -- so an avatar url set
-- here could vanish on the next load with nothing wrong in the plugin at all.
-- saveTable is not gated by it and always persists. Chat and Training have
-- always used it; this was the last one still writing variables.
-- Everything that belongs to the character rather than to the panel. Written
-- from two places -- saving, and stepping off one character onto another -- and
-- a field added to one and not the other is how the forms list would quietly
-- stop following its owner.
local function snapshot()
    return {
        -- When this character was last on screen. Used to pick a profile when
        -- 'last' names one that is not there.
        at = os.time(),
        sc = sc,
        avatarUrl = avatarUrl,
        nameOverride = profile.override,
        forms = form.ALL,
        -- The last numbers seen, so the panel comes up populated rather than
        -- showing four dashes until the first packet lands. The opponent is
        -- deliberately NOT among them: a stale enemy bar at login is a lie,
        -- where a stale power level is merely old.
        vitals = vit,
        prompt = { ar = charState.ar, arMax = charState.arMax,
                   ki = charState.ki, kiMax = charState.kiMax,
                   lf = charState.lf, zeni = charState.zeni,
                   plBase = charState.plBase, plCur = charState.plCur },
        -- What you were carrying and wearing. Per character, obviously, and the
        -- container scratch list is left out: it is whichever bag was looked in
        -- last, which means nothing next session.
        items = { inv = gear.list.inv, eq = gear.list.eq },
    }
end

-- The lists, back off the store and into fresh tables.
--
-- Fresh, never the stored ones: snapshot() keeps a REFERENCE to whatever is
-- live, so handing the stored table straight back would leave two profiles
-- sharing one list -- the trap the sheet fell into.
--
-- Walked by index rather than by pairs() so the order survives, and started at
-- zero when that is where it starts, because an array crossing the boundary is
-- not reliably 1-indexed. The type test is the loop condition: a missing index
-- arrives as undefined, which is truthy, so 'while t[i] do' would never end.
local function restoreItems(prof)
    local function rowsOf(t)
        local out = {}
        if type(t) ~= "table" then return out end
        local i = 1
        if type(t[0]) == "string" then i = 0 end
        while type(t[i]) == "string" and #out < gear.MAX do
            local s = trimBoth(t[i])
            if s ~= "" then out[#out + 1] = s end
            i = i + 1
        end
        return out
    end

    local it = nil
    if type(prof) == "table" then it = prof.items end
    if type(it) ~= "table" then it = {} end

    gear.list.inv = rowsOf(it.inv)
    gear.list.eq = rowsOf(it.eq)
    gear.list.cont = {}

    -- Restored rows count as captured -- the events may edit them, and the tab
    -- must not tell you to type 'inv' for a list it is already showing. They are
    -- also from a previous session, so they come back flagged out of date.
    gear.seen.inv = rowCount(gear.list.inv) > 0
    gear.seen.eq = rowCount(gear.list.eq) > 0
    gear.seen.cont = false
    gear.stale.inv = true
    gear.stale.eq = true
    gear.stale.cont = true
end

-- Guarded, and it says so when it fails. Every caller does something the user
-- can see -- switching a tab, toggling a mode -- and none of them should stop
-- happening because storage did not take the write.
-- Two rates, on purpose.
--
-- saveSettings is for things the user just did -- an avatar, a font size, a
-- toggle -- and writes and flushes immediately, because losing one of those is
-- losing an instruction.
--
-- saveNumbers is for what the MUD keeps telling us. Flushing that on every
-- prompt would be a write per line for data that is only wanted so the panel
-- comes up populated, so it goes out on a five-minute leash instead.
-- When the numbers last went out, and how often they may. One table, same
-- reason as HELLO above.
local numSave = { at = 0, every = 300 }

local function saveSettings()
    profile.all[profile.key] = snapshot()
    -- Whitelisted, not 'or 0'. numSave has no 'n' until this line runs once,
    -- and a missing key on a PLAIN LUA TABLE reads back as undefined here --
    -- which is truthy, so 'numSave.n or 0' handed back undefined rather than
    -- zero. The stamps on disk said so: '.../undefined', then '.../NaN' once
    -- undefined had been added to. Not just GMCP fields; any absent key.
    local n = numSave.n
    if type(n) ~= "number" or n ~= n then n = 0 end
    numSave.stamp = INSTANCE .. "/" .. tostring(os.time()) .. "/" .. tostring(n)
    numSave.n = n + 1
    -- saveTable's write is debounced 50ms and lands asynchronously after that,
    -- so a client killed outright loses whatever had not made it out. That is
    -- why an avatar set and confirmed came back gone: it was saved, and the
    -- save had not landed. saveState() forces it now.
    -- MERGE into what is on disk. Never replace it.
    --
    -- This is the one that was actually losing the data. init() reads the store
    -- at plugin-load time and sometimes gets NOTHING back -- the client's
    -- storage is not always ready that early -- so the panel comes up blank
    -- with profileKey "". The next save then wrote that blank state out as the
    -- whole table and took every named profile with it. Measured: storecheck
    -- read 'profiles=2 last=solao' off the disk, and the write that followed
    -- left 'profiles=1 last='.
    --
    -- So a save now keeps every profile it did not load, and refuses to write
    -- an empty 'last' over a real one. A session that came up knowing nothing
    -- can no longer delete what it failed to read.
    local disk = nil
    pcall(function() disk = loadTable("dbi-portrait-prefs", "global") end)

    local keep = {}
    if type(disk) == "table" and type(disk.profiles) == "table" then
        for k, v in pairs(disk.profiles) do
            if type(k) == "string" and type(v) == "table" then
                -- ...except the nameless profile, once we know who we are.
                -- It is where a session parks settings before the first score,
                -- and carrying it forward means writing it back on every save
                -- for the life of the store. Dropping it in memory was not
                -- enough on its own: this merge read it straight back off the
                -- disk and put it there again.
                local mine = (k == "" and profile.key ~= "")

                -- ...and except a character we are already holding under
                -- another spelling. Keeping those would undo the case fold on
                -- every save, and 'Solao' would grow back beside 'solao'
                -- forever.
                for k2 in pairs(profile.all) do
                    if type(k2) == "string" and k2:lower() == k:lower() then mine = true end
                end
                if not mine then keep[k] = v end
            end
        end
    end
    for k, v in pairs(profile.all) do
        -- Same rule on this side. Whether the nameless profile is still in
        -- memory depends on which path got us here, and one guard at the point
        -- of writing beats three that have to agree.
        if type(k) == "string" and type(v) == "table"
            and not (k == "" and profile.key ~= "") then
            keep[k] = v
        end
    end

    local lastOut = profile.key
    if lastOut == "" and type(disk) == "table" and has(disk.last) then
        lastOut = disk.last
    end

    -- The GLOBAL store, not the default one.
    --
    -- Default-scope tables live in the WORLD FILE, and init() runs before a
    -- world is open -- at which point the same call reads localStorage instead
    -- and finds nothing. That is the whole of the race this plugin spent a
    -- night on: not storage being slow, but two different stores answering the
    -- same name depending on when you ask. The global scope is documented as
    -- independent of any open world, so it answers the same way at load as it
    -- does a second later.
    --
    -- It is shared with every other plugin, keyed by name, hence the prefix.
    --
    -- TWO copies, under two keys.
    --
    -- Not paranoia. Measured: a write was confirmed byte-for-byte by
    -- storecheck, the client was restarted, and the plugin was handed back an
    -- OLDER revision -- an avatar from days earlier and no forms at all --
    -- while the newer payload sat in the client's own IndexedDB, intact and
    -- readable from outside. The write is not the part that fails; the read
    -- after a restart is. A second key does not fix the client, it just means
    -- one lost revision is no longer one lost profile, because the way back in
    -- takes whichever copy has more in it.
    local payload = nil
    local ok, err = pcall(function()
        payload = {
            -- Written on every save and remembered here, so 'dbchar storecheck'
            -- can tell a write that LANDED from one that merely did not throw.
            stamp = numSave.stamp,
            view = panel.view,
            plMode = panel.plMode,
            fontScale = tostring(panel.font.scale),
            gagPrompt = gag.on and "yes" or "no",
            itemsGag = gear.gag and "yes" or "no",
            srcMode = src.bars,
            srcStats = src.stats,
            srcItems = src.items,
            srcAuc = src.auc,
            containers = cont.is,
            panelAlpha = tostring(panel.alpha),
            profiles = keep,
            last = lastOut,
            prompts = pr.cur.learned,
            promptFmt = pr.learnedFor.prompt,
            fpromptFmt = pr.learnedFor.fprompt,
        }
        saveTable("dbi-portrait-prefs", payload, "global")
        saveTable("dbi-portrait-prefs-bak", payload, "global")
    end)
    if not ok then
        lastError = "saveSettings: " .. tostring(err)
        print(TAG .. "settings not saved: " .. tostring(err))
        return
    end
    numSave.at = os.time()
    pcall(function() saveState() end)
end

-- The numbers, on the leash. Nothing to do if the settings write just went.
local function saveNumbers()
    local now = os.time()
    if now - numSave.at < numSave.every then return end
    numSave.at = now
    saveSettings()
end

-- Learned prompt formats, checked on the way back in. Stored data is still
-- data: a table written by an older build, or edited by hand, has never been
-- through promptCompile. A format that no longer compiles is dropped rather
-- than carried, and an array crossing the boundary is not reliably 1-indexed,
-- so this walks pairs() rather than ipairs().
local function promptsFrom(t)
    local out = {}
    if type(t) ~= "table" then return out end

    local seen = {}
    for _, fmt in pairs(t) do
        if type(fmt) == "string" and fmt ~= "" and not seen[fmt] then
            if promptCompile(fmt) then
                seen[fmt] = true
                out[#out + 1] = fmt
            end
        end
    end
    return out
end

-- A saved forms list, checked on the way back in. Stored data is still data:
-- these urls go straight into a stylesheet, and a table written by an older
-- build -- or edited by hand -- has never been through safeAvatarUrl.
local function formsFrom(t)
    local out = {}
    if type(t) ~= "table" then return out end

    for name, f in pairs(t) do
        if type(name) == "string" and type(f) == "table" and has(f.pat) and has(f.url) then
            local url = tostring(f.url)
            if url ~= "base" then url = safeAvatarUrl(url) end
            if url ~= "" then out[name] = { pat = tostring(f.pat), url = url } end
        end
    end
    return out
end

-- How many profiles are actually held. By whitelist, because '#' means nothing
-- on a string-keyed table and a bare pairs() count would include whatever a
-- failed delete left behind.
local function rowCountOf(t)
    local n = 0
    if type(t) ~= "table" then return 0 end
    for k, v in pairs(t) do
        if type(k) == "string" and type(v) == "table" then n = n + 1 end
    end
    return n
end

-- The live form count, by whitelist. Used by diag and by storecheck, so the
-- two cannot disagree about how many there are.
local function formCountNow()
    local n = 0
    for _, f in pairs(form.ALL) do
        if type(f) == "table" then n = n + 1 end
    end
    return n
end

-- How much is actually in a profile.
--
-- Two spellings of one character can both be in the store -- an older build
-- wrote 'Solao', this one writes 'solao', and the code that was supposed to
-- drop the stale one assigns nil to the key, which does not remove it here. So
-- the fold on the way in had a choice to make and made it by pairs() order,
-- which is to say at random: some launches came back with the full profile and
-- some with the empty twin. That is what an intermittent "it lost my settings"
-- looks like from the outside.
--
-- Weighed rather than counted, so the answer is the same every time.
local function profileWeight(v)
    if type(v) ~= "table" then return -1 end
    local n = 0
    if type(v.forms) == "table" then
        for _ in pairs(v.forms) do n = n + 10 end
    end
    if has(v.avatarUrl) then n = n + 5 end
    if has(v.nameOverride) then n = n + 5 end
    if type(v.sc) == "table" then n = n + 2 end
    if type(v.items) == "table" then
        if type(v.items.inv) == "table" then n = n + 1 end
        if type(v.items.eq) == "table" then n = n + 1 end
    end
    if safeNum(v.at) then n = n + 1 end
    return n
end

-- A score naming somebody else. Stash what is on screen under the character it
-- belongs to, then put that character's own things on.
profile.use = function(name)
    -- Lowercased. The key comes off a parsed score header, and a key that can
    -- vary in case forks a second, empty profile for the same character.
    local key = trimBoth(name or ""):lower()
    if key == "" or key == profile.key then return end

    local oldKey = profile.key
    profile.all[oldKey] = snapshot()

    profile.key = key
    local prof = profile.all[key]

    -- Adopt an existing profile whatever case its key was stored under, and
    -- drop the stale spelling so it cannot fork again.
    if type(prof) ~= "table" then
        -- Rebuilt rather than nil'd. 'profiles[k] = nil' leaves the key
        -- standing here, so the stale spelling went back to the store and the
        -- next launch had two profiles for one character to choose between.
        local best = nil
        for k, v in pairs(profile.all) do
            if type(k) == "string" and k:lower() == key and type(v) == "table" then
                if best == nil or profileWeight(v) > profileWeight(best) then best = v end
            end
        end
        if type(best) == "table" then
            local kept = {}
            for k, v in pairs(profile.all) do
                if type(k) == "string" and type(v) == "table"
                    and k:lower() ~= key then kept[k] = v end
            end
            kept[key] = best
            profile.all = kept
            prof = best
        end
    end
    if type(prof) ~= "table" then prof = {} end

    -- one field at a time; a missing one must not take the others with it
    if type(prof.avatarUrl) == "string" then avatarUrl = safeAvatarUrl(prof.avatarUrl)
    else avatarUrl = "" end
    if type(prof.nameOverride) == "string" then profile.override = prof.nameOverride else profile.override = "" end
    form.ALL = formsFrom(prof.forms)

    -- The sheet has to be rebound too, and this is the one that was missed.
    -- snapshot() stores a REFERENCE to the live table, so leaving sc pointing at
    -- it meant the incoming character parsed straight into the previous one's
    -- sheet -- both profiles ending up as the same table, and the alt inheriting
    -- whatever 'look self' had said about somebody else. A character with no
    -- stored sheet starts empty rather than borrowing the last one's.
    if type(prof.sc) == "table" then sc = prof.sc else sc = {} end
    if type(prof.vitals) == "table" then vit = prof.vitals else vit = nil end

    -- Items are the one thing the incoming profile does not always win. The
    -- first 'score' of a session identifies whoever is already logged in, so a
    -- list captured moments ago belongs to them and is fresher than anything
    -- stored. A real alt switch has an oldKey to prove it is one.
    local keepLive = oldKey == ""
        and (rowCount(gear.list.inv) > 0 or rowCount(gear.list.eq) > 0)
    if not keepLive then restoreItems(prof) end

    -- Anything set before the first score of a session lived under the
    -- anonymous "" profile, and there was no other character it could have been
    -- meant for. The first named profile inherits whatever it is missing rather
    -- than dropping it -- which is exactly how a freshly set avatar vanished the
    -- moment score identified the character.
    --
    -- One field at a time, again: a stored profile with an avatar but no name
    -- override must not lose the anonymous name override.
    if oldKey == "" then
        local anon = profile.all[""]
        if type(anon) == "table" then
            if avatarUrl == "" and type(anon.avatarUrl) == "string" then
                avatarUrl = safeAvatarUrl(anon.avatarUrl)
            end
            if profile.override == "" and type(anon.nameOverride) == "string" then
                profile.override = anon.nameOverride
            end
            local haveForms = false
            for _ in pairs(form.ALL) do haveForms = true end
            if not haveForms then form.ALL = formsFrom(anon.forms) end
        end
        profile.all[""] = nil
    end

    -- whoever just walked in is standing in their base form, whatever the last
    -- character was wearing
    form.url = ""
    form.name = ""
    saveSettings()
end

-- The prompt line, out of the main window: a substring trigger with
-- omitFromOutput and no callback. onLine still sees the line and reads the Foe
-- token off it -- gagging does not reach onLine.
--
-- Re-armed whenever the label changes, so turning the gag on before the first
-- prompt has been seen still ends up matching the right one.
local function applyGag()
    for _, id in ipairs(gag.ids) do
        pcall(function() removeTrigger(id) end)
    end
    gag.ids = {}
    gag.triggerId = nil
    gag.tag = ""
    gag.sig = ""
    if not gag.on then return end

    -- Hiding is done HERE, with a nil callback, and reading is done in
    -- armPrompt, with a callback and no omitFromOutput. They are deliberately
    -- two triggers on the same pattern rather than one doing both, because one
    -- doing both does neither.
    -- Every compiled line of every known format, not only the ones this session
    -- has happened to see. Gagging "the prompt" means both prompts, and the
    -- fight one does not appear until you are in a fight -- so arming on first
    -- sight leaked the opening line of every combat.
    --
    -- Safe to arm all of them only because each pattern is anchored at both
    -- ends: someone pasting their prompt at you sits mid-line inside a tell and
    -- cannot match.
    if type(pr.cur.set) == "table" then
        for _, m in ipairs(pr.cur.set) do
            if type(m.rx) == "string" and #m.rx <= pr.MAX then
                local id = addTrigger(m.rx, nil,
                    { type = "regex", omitFromOutput = true, priority = 90 })
                if id then gag.ids[#gag.ids + 1] = id end
            end
        end
    end
    gag.sig = pr.cur.sig

    -- The original test as well, always, not only when nothing compiled. A
    -- player whose prompt no format describes still gets gagged, and seeing one
    -- recognised format must not quietly drop the cover for the rest -- which is
    -- exactly what returning early here did.
    --
    -- Two triggers matching the same line is free: omitFromOutput twice hides it
    -- once.
    --
    -- Falls back to the original test: the line
    -- carrying both the lifeforce label and a Ki reading. Bare-substring was
    -- tried and was wrong -- 'LifeForce:' also appears in the score block, as
    --
    --   PKills  : [000000]| Items :   1/15    | LifeForce: [49.88]%
    --
    -- and gagging that took a row nothing parses straight out of the scroll,
    -- invisibly, because gagging never reaches onLine.
    gag.tag = pr.cur.tag
    if gag.tag ~= "" then
        local id = addTrigger(gag.tag .. ".*[Kk][Ii]:", nil,
            { type = "regex", omitFromOutput = true, priority = 90 })
        if id then gag.ids[#gag.ids + 1] = id end
    end
    gag.triggerId = gag.ids[1]
end

-- One trigger per line of every format, each anchored at both ends so nothing
-- matches a prompt quoted inside somebody's tell. The regex goes to the engine
-- untranslated, which is the whole reason this reads captures from a trigger
-- rather than from string.match: the Lua-pattern path never matched once in the
-- client, whatever it did under lua5.1.
--
-- captures[n] lines up with roles[n] because every token compiles to a capture
-- group, mapped or not.
-- Where the first capture group actually is.
--
-- Measured, not assumed, and both of my assumptions were wrong. A two-group
-- regex comes back as
--
--     0=3.048m  1=6.095m  2=null
--
-- so the groups are ZERO-indexed and there is no full match in there at all.
-- That is sharp edge 3 -- an array crossing this boundary is not reliably
-- 1-indexed -- and it is why every field was read one slot late and thrown
-- away without an error.
--
-- Still worked out per match rather than hardcoded to 0. The same guide
-- documents 1-indexed-with-full-match for aliases, this runtime does something
-- else again for triggers, and a build that changes its mind should degrade to
-- reading the wrong field rather than to reading nothing.
local capFirst = nil
local feedCalls = 0

local function promptFeed(m, captures, line)
    feedCalls = feedCalls + 1
    if type(captures) ~= "table" then return end

    local groups = 0
    for _ in ipairs(m.roles) do groups = groups + 1 end

    if captures[0] ~= nil then
        capFirst = 0
    elseif #captures > groups then
        capFirst = 2          -- full match at 1, groups after it
    else
        capFirst = 1
    end

    local got = false
    for n, role in ipairs(m.roles) do
        if role then
            local slot = capFirst + n - 1
            if pr.TEXT[role] then
                local word = captures[slot]
                if type(word) == "string" then
                    -- Trimmed, because the capture is greedy now: a token at the
                    -- end of a line takes the trailing spaces with it.
                    word = trimBoth(word)
                    -- The channel's name is the FULLER one. The prompt's %o
                    -- abbreviates -- 'i battle armor' for 'Class I Battle
                    -- Armor' -- so a channel reading is not traded for it.
                    local fromChan = role == "auction"
                        and charState.auctionSrc == "chan"
                    -- A token the MUD never expanded. It echoes the format
                    -- back when you set or query a prompt, and that echo is
                    -- prompt-shaped enough to match:
                    --
                    --   AH: %o HP: %h
                    --
                    -- so '%o' became the auction item and sat in the footer as
                    -- a purple pill reading '%o'. A numeric role is safe from
                    -- this already -- promptNum refuses anything that is not a
                    -- figure -- so it is only the word tokens that leak.
                    local unexpanded = #word == 2 and word:sub(1, 1) == "%"

                    -- A CROSS-FORMAT MISREAD, refused outright.
                    --
                    -- The fight prompt's line can match the NON-fight format
                    -- while only one of the two has been learned. 'Auct:[%o]'
                    -- compiles to a greedy capture followed by a literal ']',
                    -- and run against
                    --
                    --   ... Auct:[socks] Foe:[42.5]
                    --
                    -- the capture backtracks to the LAST bracket and takes
                    -- 'socks] Foe:[42.5' with it -- which then sat in the
                    -- footer as an auction item reading 'Foe'.
                    --
                    -- Tested on 'Foe:' alone, NOT on brackets. Brackets were
                    -- the obvious tell and they are wrong here: this MUD
                    -- auctions '[TCG] Thirteen Booster Pack [DBI]', and 96 of
                    -- the auction lines in the transcript carry them. Refusing
                    -- a bracket would refuse the most commonly traded item on
                    -- the game. No item name contains 'Foe:' -- zero in the
                    -- same sample -- and the misread always does, because that
                    -- is the token it swallowed to get there.
                    --
                    -- Neither set nor cleared: the pill keeps what it last
                    -- knew correctly. Learning the fprompt format removes the
                    -- ambiguity at the root; this covers the sessions before
                    -- that happens.
                    local misread = role == "auction"
                        and word:lower():find("foe:", 1, true) ~= nil

                    if misread then                      -- no write, no clear
                        got = got
                    elseif word == "" or word == "N/A" or unexpanded then
                        -- The token IS on this prompt and has nothing to
                        -- report, so whatever it held is over. Leaving the old
                        -- value stood the auction pill in the footer until the
                        -- next auction started.
                        --
                        -- type(), not '~= nil'. A key this table never had comes
                        -- back undefined, which is truthy and is not nil, so the
                        -- cheaper test would call every empty token a change and
                        -- re-render on every prompt.
                        if type(charState[role]) == "string" then
                            charState[role] = nil
                            got = true
                        end
                        if fromChan then charState.auctionSrc = nil end
                    elseif not fromChan then
                        charState[role] = word
                        got = true
                    end
                end
            else
                local num = promptNum(captures[slot])
                if num then
                    charState[role] = num
                    got = true
                end
            end
        end
    end
    if not got then return end

    m.hits = (m.hits or 0) + 1
    if type(line) == "string" then cap.promptLine = trimBoth(line) end

    -- A prompt closes any open capture. This runs from the trigger, which is
    -- the only path that reliably fires on a prompt line here.
    if cap.kind then
        finishCapture()
    else
        cap.endNow = false
    end

    -- The opponent, which is the one value nothing else supplies. A line that
    -- COULD carry a foe and did not is the fight ending; a line that never
    -- carries one says nothing either way.
    local canFoe = false
    for _, role in ipairs(m.roles) do
        if role == "foe" then canFoe = true end
    end
    if canFoe then
        if charState.foe then
            foe.val = charState.foe
            foe.at = os.clock()
        end
    end
    -- No clear here. feedFoe already ends the fight off the same line, in
    -- onLine, on the same test -- a prompt that could carry an opponent and did
    -- not. Two paths clearing one value is how a bar that reads correctly ends
    -- up empty, and the version of this that has always shown the opponent has
    -- only the onLine one.
    safeRender()
end

pr.arm = function()
    for _, id in ipairs(pr.cur.trigIds) do
        pcall(function() removeTrigger(id) end)
    end
    pr.cur.trigIds = {}
    if not pr.cur.set then promptRebuild() end
    if type(pr.cur.set) ~= "table" then return end

    for _, m in ipairs(pr.cur.set) do
        if type(m.rx) == "string" and #m.rx <= pr.MAX then
            local mine = m
            -- No omitFromOutput here, deliberately, whatever the gag setting
            -- is. A trigger given BOTH a callback and omitFromOutput did
            -- neither: it never hid the line and never called back, silently,
            -- while the same pattern with a callback and omitFromOutput=false
            -- fired fifteen times in the same session. Hiding is applyGag's
            -- job and it does it with a nil callback.
            local id = addTrigger(m.rx, function(captures, line)
                promptFeed(mine, captures, line)
            end, { type = "regex", priority = 90 })
            if id then pr.cur.trigIds[#pr.cur.trigIds + 1] = id end
        end
    end
end

local function applyAlpha()
    if not panel.id then return end
    pcall(function()
        setWidgetAppearance(panel.id, { backgroundOpacity = panel.alpha })
    end)
end

local function makeWidget()
    panel.id = createWidget({
        type     = "html",
        name     = "portrait",
        title    = "Portrait",
        position = { x = 60, y = 90 },
        size     = { width = 240, height = 420 },
        appearance = { showTitleBar = false, autoHideSettingsCog = true },
    })
    setWidgetAppearance(panel.id, {
        backgroundColor   = panel.C.panel_bg,
        backgroundOpacity = panel.alpha,
        borderColor       = panel.C.energy,
        borderWidth       = 2,
        borderRadius      = 10,
        borderGradient    = "linear-gradient(135deg," .. panel.C.energy .. ",#8a4400 60%,#2a1400)",
        borderShadow      = "0 0 22px -4px rgba(251,124,0,0.45)",
    })

    -- registerWidgetEvent appends, so a reload would stack a second handler
    pcall(function() unregisterWidgetEvent(panel.id, "action") end)

    -- Named, so the registration below can wrap it. Nothing in here was
    -- guarded, and a throw in any branch went nowhere at all: no message, no
    -- repaint, no lastError. Switching tabs saved before it drew, so a storage
    -- failure changed the view and then died on the way to the render -- which
    -- looks exactly like a tab that does not redraw.
    local onAction = function(data)
        if type(data) ~= "table" then return end
        local act = tostring(data.action or "")
        local arg = ""
        if type(data.data) == "string" then arg = data.data end

        if act == "tab" then
            -- Checked against TABS rather than trusted. data-mud-data is
            -- markup this plugin emitted, but it arrives back through the
            -- client and an unknown value would leave the body rendering
            -- nothing at all.
            local want = tostring(data.data or "")
            for _, tab in ipairs(panel.TABS) do
                if tab.id == want and panel.view ~= want then
                    panel.view = want
                    -- Draw first. Remembering which tab you were on is worth
                    -- having and worth nothing next to actually showing it.
                    safeRender(true)
                    saveSettings()
                    return
                end
            end
        elseif act == "auc" then
            pcall(function() send("auc") end)
        elseif act == "cfg" then
            -- A toggle: the gear both opens and leaves. Clicking a tab leaves
            -- too, so there is no way to be stuck in here.
            local leaving = (panel.view == "cfg")
            if leaving then panel.view = "portrait" else panel.view = "cfg" end
            safeRender(true)
            saveSettings()
            -- On the way out, say so. Every control here already writes on the
            -- click, so this is belt and braces -- but a settings screen that
            -- has never once confirmed a write is a settings screen you cannot
            -- tell has failed, and this one has come back empty at least once.
            if leaving then
                -- Named, because the store is per character and a settings
                -- screen that saved under a key you did not expect looks
                -- exactly like one that did not save at all.
                local who = profile.key
                if who == "" then who = "this session (no score read yet)" end
                echo(TAG .. "settings saved for " .. who .. ".", panel.C.energy)
            end


        elseif act == "itlook" then
            -- The target is a quoted phrase now, not an ordinal. This still
            -- parsed '1.backpack' and so matched nothing at all -- the button
            -- did nothing and a bag that was open stayed open.
            -- The whole phrase is the key, not its first word. actPhrase has
            -- already reduced it to lowercase letters and single spaces, which
            -- is exactly what itemPhrase produced on the way out.
            local phrase = actPhrase(data.data)
            local key = phrase
            if key ~= "" then
                if cont.open[key] then
                    cont.open[key] = false
                    safeRender(true)
                elseif type(cont.list[key]) == "table" then
                    cont.open[key] = true          -- already know what is in it
                    safeRender(true)
                else
                    -- Mark it open first, then ask. The render needs both the
                    -- flag and a contents list, so nothing shows until the reply
                    -- lands -- and a 'look in' typed rather than clicked never
                    -- sets the flag, so it stays collapsed.
                    cont.open[key] = true
                    pcall(function() send('look in "' .. phrase .. '"') end)
                end
            end

        elseif act == "itana" then
            local phrase = actPhrase(data.data)
            local key = phrase
            if key ~= "" then
                if cont.anaOpen[key] then
                    cont.anaOpen[key] = false
                    safeRender(true)
                elseif type(cont.anaOf[key]) == "table" then
                    cont.anaOpen[key] = true
                    safeRender(true)
                else
                    pcall(function() send('ana "' .. phrase .. '"') end)
                end
            end

        elseif act == "itref" then
            -- Just ask again. onCommand arms the capture off what goes out, so
            -- the reply lands through the ordinary path and nothing here has to
            -- know anything about capturing.
            local raw = ""
            if type(data.data) == "string" then raw = data.data end
            local parts = {}
            for chunk in raw:gmatch("[^~]+") do parts[#parts + 1] = chunk end
            local which = actPhrase(parts[1])
            if which == "inv" or which == "eq" or which == "score" then
                pcall(function() send(which) end)
            elseif which == "cont" then
                local phrase = actPhrase(parts[2])
                if phrase ~= "" then
                    pcall(function() send('look in "' .. phrase .. '"') end)
                end
            end

        elseif act == "ittake" then
            -- 'item~bag'. It was 'item|bag' split with '^([^|]*)|' and
            -- '|([^|]*)$', and the second one is the trap: an unescaped bar is
            -- alternation once translated, so the regex was "empty OR
            -- ([^|]*)$", the empty branch matched at offset zero, the capture
            -- came back undefined and tostring() made it the string
            -- "undefined". The MUD answered 'I see no undefined here.'
            local raw = ""
            if type(data.data) == "string" then raw = data.data end
            local parts = {}
            for chunk in raw:gmatch("[^~]+") do parts[#parts + 1] = chunk end
            local item, bag = actPhrase(parts[1]), actPhrase(parts[2])
            if item ~= "" and bag ~= "" then
                pcall(function()
                    send('get "' .. item .. '" from "' .. bag .. '"')
                end)
            end

        elseif act == "itwear" or act == "itrem" then
            -- Rebuilt from letters here rather than trusted: it went out to the
            -- client as markup and came back. Letters and single spaces only,
            -- so nothing can carry a quote of its own and break out of the
            -- quoting, and nothing can carry a command separator.
            local phrase = actPhrase(data.data)
            if phrase ~= "" then
                local verb = "wear "
                if act == "itrem" then verb = "remove " end
                pcall(function() send(verb .. '"' .. phrase .. '"') end)
                -- No stale marking here. The reply moves the row between the
                -- two lists on its own, and marking both out of date on every
                -- click left the banner up for good.
            end
        elseif act == "setfmt" then
            -- A format the user typed, which is the only way to get one on a
            -- MUD that answers 'prompt' with '(default prompt)'.
            local which = arg
            if which ~= "prompt" and which ~= "fprompt" then which = "prompt" end
            local txt = trimBoth(edit[which] or "")
            if txt == "" then
                echo(TAG .. "type the format first -- the %-tokens, as you set "
                    .. "them on the MUD.", panel.C.energy)
            elseif promptCompile(txt) == nil then
                echo(TAG .. "that does not compile as a prompt format. It needs "
                    .. "at least one %-token.", "#ff6666")
            else
                -- Colour tags are stripped the same way the command path does
                -- it: three of them on this MUD, and they are not part of the
                -- format the panel has to match against.
                local bare = txt:gsub("&.", ""):gsub("%^.", ""):gsub("%}.", "")
                bare = trimBoth(bare)
                pr.learnedFor[which] = bare
                promptLearn(bare, true)
                edit[which] = ""
                echo(TAG .. which .. " set to: " .. txt, panel.C.energy)
                safeRender(true)
                saveSettings()
            end

        elseif act == "detect" then
            -- Ask the MUD. It may well answer '(default prompt)', in which case
            -- nothing is learned and the reader says so -- that is the whole
            -- reason the field above it exists.
            local which = arg
            if which ~= "prompt" and which ~= "fprompt" then which = "prompt" end
            pcall(function() send(which) end)
            echo(TAG .. "asked the MUD for your " .. which .. ".", panel.C.energy)

        elseif act == "cfgtog" then
            if arg == "gag" then
                gag.on = not gag.on
                applyGag()
            elseif arg == "itemsgag" then
                gear.gag = not gear.gag
            elseif arg == "plmode" then
                if panel.plMode == "nums" then panel.plMode = "bar" else panel.plMode = "nums" end
            elseif arg == "src" then
                if src.bars == "prompt" then src.bars = "gmcp" else src.bars = "prompt" end
            elseif arg == "srcstats" then
                if src.stats == "score" then src.stats = "gmcp" else src.stats = "score" end
            elseif arg == "srcitems" then
                if src.items == "capture" then src.items = "gmcp" else src.items = "capture" end
            elseif arg == "srcauc" then
                if src.auc == "chan" then src.auc = "gmcp" else src.auc = "chan" end
            end
            safeRender(true)
            saveSettings()

        elseif act == "cfgnudge" then
            if arg == "font-" then panel.font.scale = math.max(0.5, panel.font.scale - 0.1) end
            if arg == "font+" then panel.font.scale = math.min(2, panel.font.scale + 0.1) end
            if arg == "alpha-" then panel.alpha = math.max(0, panel.alpha - 0.05) end
            if arg == "alpha+" then panel.alpha = math.min(1, panel.alpha + 0.05) end
            applyAlpha()
            safeRender(true)
            saveSettings()

        elseif act == "addform" then
            local fnm = trimBoth(edit.fname or ""):lower()
            local furl = trimBoth(edit.furl or "")
            local fpat = trimBoth(edit.fpat or "")
            if fnm == "" or furl == "" or fpat == "" then
                echo(TAG .. "a form needs a name, an image url (or 'base'), and "
                    .. "the line the MUD prints.", "#ff6666")
            elseif furl == "base" then
                form.ALL[fnm] = { pat = fpat, url = "base" }
                edit.fname, edit.furl, edit.fpat = "", "", ""
                safeRender(true)
                saveSettings()
            else
                -- Through the same resolver the avatar uses. A share page is
                -- markup, not a picture, and lands as an empty frame.
                applyImage(furl, function(clean)
                    form.ALL[fnm] = { pat = fpat, url = clean }
                    edit.fname, edit.furl, edit.fpat = "", "", ""
                    safeRender(true)
                    saveSettings()
                end)
            end

        elseif act == "delform" then
            -- Rebuilt, not deleted. Setting the key to nil leaves it standing
            -- in this runtime, and pairs() goes on yielding it (sharp edge 3b).
            local kept = {}
            for fnm, frec in pairs(form.ALL) do
                if fnm ~= arg and type(frec) == "table" then kept[fnm] = frec end
            end
            form.ALL = kept
            if form.name == arg then
                form.name = ""
                form.url = ""
            end
            safeRender(true)
            saveSettings()

        elseif act == "formbase" then
            form.name = ""
            form.url = ""
            safeRender(true)

        elseif act == "setav" then
            local url = trimBoth(edit.avatar or "")
            if url == "" then
                echo(TAG .. "an avatar takes an http(s) url.", "#ff6666")
            else
                applyImage(url, function(clean)
                    avatarUrl = clean
                    edit.avatar = ""
                    safeRender(true)
                    saveSettings()
                end)
            end

        elseif act == "clearav" then
            avatarUrl = ""
            edit.avatar = ""
            safeRender(true)
            saveSettings()

        elseif act == "setnm" then
            local nm = trimBoth(edit.name or "")
            if nm ~= "" then
                profile.override = nm
                edit.name = ""
                safeRender(true)
                saveSettings()
            end

        elseif act == "clearnm" then
            profile.override = ""
            edit.name = ""
            safeRender(true)
            saveSettings()

        elseif act == "plmode" then
            if panel.plMode == "nums" then panel.plMode = "bar" else panel.plMode = "nums" end
            safeRender(true)
            saveSettings()
        elseif act == "close" then
            hideWidget(panel.id, true)
        end
    end

    -- The settings fields. Captured on keyup and applied on submit, because an
    -- action fires on a click and typing does not click -- and because
    -- redrawing mid-keystroke replaces the input and takes the focus with it.
    local FIELDS = { cfgprompt = "prompt", cfgfprompt = "fprompt",
                     cfgavatar = "avatar", cfgname = "name",
                     cfgfname = "fname", cfgfurl = "furl", cfgfpat = "fpat" }

    pcall(function() unregisterWidgetEvent(panel.id, "keyup") end)
    registerWidgetEvent(panel.id, "keyup", function(e)
        if type(e) ~= "table" then return end
        local which = FIELDS[tostring(e.targetId or "")]
        if which and type(e.targetValue) == "string" then edit[which] = e.targetValue end
    end)

    -- Enter. Which form it came from is not documented, so try the dataset the
    -- form carries, then the id of whatever was focused, then give up quietly.
    local SUBMITS = { prompt = { "setfmt", "prompt" }, fprompt = { "setfmt", "fprompt" },
                      avatar = { "setav", "" }, name = { "setnm", "" },
                      fname = { "addform", "" }, furl = { "addform", "" },
                      fpat = { "addform", "" } }

    pcall(function() unregisterWidgetEvent(panel.id, "submit") end)
    registerWidgetEvent(panel.id, "submit", function(e)
        if type(e) ~= "table" then return end
        local id = tostring(e.targetId or "")
        local which = FIELDS[id]
        -- gsub returns two values; indexing with the call directly hands the
        -- pair across the boundary, so it lands in a local first.
        local asInput = id:gsub("^frm", "cfg")
        if which == nil then which = FIELDS[asInput] end
        if which and type(e.targetValue) == "string" then edit[which] = e.targetValue end

        local act, arg = nil, ""
        if type(e.dataset) == "table" then
            if type(e.dataset.mudAction) == "string" then act = e.dataset.mudAction end
            if type(e.dataset.mudData) == "string" then arg = e.dataset.mudData end
        end
        if act == nil and which then
            act = SUBMITS[which][1]
            arg = SUBMITS[which][2]
        end
        if act == nil then return end
        pcall(onAction, { action = act, data = arg })
    end)

    registerWidgetEvent(panel.id, "action", function(data)
        uiCalls = uiCalls + 1
        local ok, err = pcall(onAction, data)
        if not ok then
            lastError = "widget action: " .. tostring(err)
            print(TAG .. "widget action error: " .. tostring(err))
        end
    end)

    safeRender(true)
end

----------------------------------------------------------------------
-- diagnostics, in its own function -- Lua 5.1 caps a function at 60 upvalues
-- and the command handler is where that ceiling gets hit
----------------------------------------------------------------------

local function printDiag()
    print(TAG .. "instance=" .. INSTANCE)
    local raw = getGMCPData("char")
    print(TAG .. "char package present=" .. tostring(type(raw) == "table")
        .. " char.vitals present=" .. tostring(type(getGMCPData("char.vitals")) == "table"))
    print(TAG .. "connected=" .. tostring(nego.connected)
        .. " vitalsSeen=" .. tostring(vit ~= nil)
        .. " scoreSeen=" .. tostring(sheet.seen)
        .. " parsing=" .. tostring(sheet.inBlock))
    if vit then
        print(TAG .. "vitals hit=" .. tostring(vit.hit) .. "/" .. tostring(vit.maxHit)
            .. " energy=" .. tostring(vit.energy) .. "/" .. tostring(vit.maxEnergy)
            .. " pl=" .. tostring(vit.pl) .. " base=" .. tostring(vit.basepl))
    end
    print(TAG .. "first=" .. tostring(sc.first) .. " last=" .. tostring(sc.last) .. " race=" .. tostring(sc.race)
        .. " sex=" .. tostring(sc.sex) .. " age=" .. tostring(sc.age))
    print(TAG .. "stats str=" .. tostring(sc.strength) .. " spd=" .. tostring(sc.speed)
        .. " spi=" .. tostring(sc.spirit) .. " for=" .. tostring(sc.fortitude))
    print(TAG .. "last STRENGTH line: [" .. tostring(pd.scoreSaw) .. "]")
    local foeAge = "-"
    if foe.val then foeAge = tostring(math.floor(os.clock() - foe.at)) end
    print(TAG .. "plMode=" .. panel.plMode .. " foe=" .. tostring(foe.val) .. " foeAge=" .. foeAge
        .. " src=" .. src.bars .. "/" .. src.stats .. "/" .. src.items
        .. "/" .. src.auc)
    print(TAG .. "last opponent line: [" .. tostring(foe.saw) .. "]")
    print(TAG .. "read off it: " .. tostring(foe.got)
        .. "  held at clock " .. tostring(foe.at))
    print(TAG .. "opponent last cleared by: " .. tostring(foe.why))
    print(TAG .. "fontScale=" .. panel.font.scale .. " gagPrompt=" .. tostring(gag.on)
        .. " feedCalls=" .. tostring(feedCalls)
        .. " esc=[" .. tostring(promptRx("(a|b)")) .. "]"
        .. " capFirst=" .. tostring(capFirst)
        .. " promptTrigs=" .. tostring(#pr.cur.trigIds)
        .. " compiled=" .. tostring(pr.cur.set and #pr.cur.set or -1)
        .. " luaTries=" .. tostring(pd.tries)
        .. " luaHits=" .. tostring(pd.hits)
        .. " buildErr=" .. tostring(pd.buildErr or "none")
        .. " readErr=" .. tostring(pd.readErr or "none")
        .. " gagTriggers=" .. tostring(#gag.ids)
        .. " formatsArmed=" .. tostring(#pr.cur.order)
        .. " learned=" .. tostring(#pr.cur.learned)
        .. " promptTag=" .. pr.cur.tag .. " gagTag=" .. (gag.tag ~= "" and gag.tag or "(none)"))

    local formCount = 0
    for _ in pairs(form.ALL) do formCount = formCount + 1 end
    -- Everything the prompt has handed over, whatever it happened to carry.
    -- Sorted so two runs can be diffed against each other.
    local fieldNames = {}
    for k in pairs(charState) do fieldNames[#fieldNames + 1] = k end
    table.sort(fieldNames)
    if #fieldNames == 0 then
        print(TAG .. "prompt fields: none read yet")
    else
        local bits = {}
        for _, k in ipairs(fieldNames) do
            bits[#bits + 1] = k .. "=" .. tostring(charState[k])
        end
        print(TAG .. "prompt fields: " .. table.concat(bits, " "))
    end

    -- The patterns themselves, always, not only when nothing was read. Every
    -- round of this has been spent inferring what the client built from what it
    -- did; printing it costs three lines.
    -- Grouped by the format they came from, so the two stock prompts read as
    -- two prompts rather than as sixteen loose regexes.
    print(TAG .. "learned prompt  = " .. tostring(pr.learnedFor.prompt or "(stock)"))
    print(TAG .. "learned fprompt = " .. tostring(pr.learnedFor.fprompt or "(stock)"))
    local nInv, nEq, nCont = 0, 0, 0
    for _ in ipairs(gear.list.inv or {}) do nInv = nInv + 1 end
    for _ in ipairs(gear.list.eq or {}) do nEq = nEq + 1 end
    for _ in ipairs(gear.list.cont or {}) do nCont = nCont + 1 end
    print(TAG .. "items cmds=" .. capCmds .. " armed=" .. capArms
        .. " captured=" .. capDone
        .. " kind=" .. tostring(cap.kind) .. " waiting=" .. tostring(cap.armed)
        .. " inv=" .. nInv .. " eq=" .. nEq .. " cont=" .. nCont
        .. " gag=" .. tostring(gear.gag) .. " clock=" .. tostring(os.clock()))
    print(TAG .. "item events: seen=" .. ev.seen .. " acted=" .. ev.hit
        .. "  last 'You ' line: [" .. tostring(ev.last) .. "]")
    print(TAG .. "last item move: " .. tostring(ev.why))
    print(TAG .. "widget clicks handled=" .. uiCalls)
    print(TAG .. "lists captured: inv=" .. tostring(gear.seen.inv)
        .. " eq=" .. tostring(gear.seen.eq) .. " cont=" .. tostring(gear.seen.cont))
    print(TAG .. "items stood-down=" .. capStand .. " header-hits=" .. capHead
        .. "  last line while armed: [" .. tostring(capSaw) .. "]")

    print(TAG .. "Prompt Triggers")
    if type(pr.cur.set) ~= "table" or #pr.cur.set == 0 then
        print("   (none compiled)")
    else
        -- promptSet is ordered longest-pattern-first because that is what
        -- matching needs. Reading it wants format order and then line order, so
        -- the display sorts its own copy.
        local shownList = {}
        for _, m in ipairs(pr.cur.set) do shownList[#shownList + 1] = m end
        table.sort(shownList, function(l, r)
            if l.fmt ~= r.fmt then return tostring(l.fmt) < tostring(r.fmt) end
            return (l.lineNo or 0) < (r.lineNo or 0)
        end)

        local lastFmt = nil
        for _, m in ipairs(shownList) do
            if m.fmt ~= lastFmt then
                lastFmt = m.fmt
                print("   " .. tostring(m.fmt))
            end
            local mark = ""
            if gag.on then mark = "  [gagging]" end
            if pr.cur.used[m.rx] then mark = mark .. " [seen]" end
            print("     Line " .. tostring(m.lineNo)
                .. "   hits=" .. tostring(m.hits or 0) .. mark)
            print("       " .. tostring(m.rx))
        end
    end

    -- What is on disk RIGHT NOW, beside what is in memory. The two disagreeing
    -- is the whole diagnosis; a count of one alone never was.
    local onDisk = nil
    pcall(function() onDisk = loadTable("dbi-portrait-prefs", "global") end)
    local dn = "unreadable"
    if type(onDisk) == "table" then
        local mine = (onDisk.profiles or {})[profile.key]
        local fn = 0
        if type(mine) == "table" then
            for _ in pairs(mine.forms or {}) do fn = fn + 1 end
        end
        dn = tostring(fn)
    end
    print(TAG .. "stored forms for [" .. profile.key .. "]=" .. dn
        .. "  (in memory=" .. formCountNow() .. ")")
    print(TAG .. "forms=" .. formCount .. " activeForm="
        .. (form.name ~= "" and form.name or "base"))

    -- the URL actually written into the stylesheet, so a wrong avatar is a
    -- question about the file rather than about the plugin
    local shown = form.url
    if shown == "" then shown = avatarUrl end
    if shown == "" then
        local r, x = slug(sc.race), slug(sc.sex)
        if r == "" then shown = AVATAR_BASE .. "/generic.png"
        elseif x == "" then shown = AVATAR_BASE .. "/" .. r .. ".png"
        else shown = AVATAR_BASE .. "/" .. r .. "-" .. x .. ".png" end
    end
    print(TAG .. "avatar url=" .. shown)
    print(TAG .. "override=" .. (avatarUrl ~= "" and avatarUrl or "(none)")
        .. " view=" .. panel.view .. " helloStamp=" .. tostring(getVariable(HELLO.key, "global"))
        .. " profile=[" .. profile.key .. "]"
        .. " gmcpOwnedElsewhere=" .. tostring(gmcpOwned))
    print(TAG .. "lastError=" .. lastError)
end

-- Everything the server is actually sending, dumped raw. Run it MID-FIGHT: if
-- the opponent's health travels over GMCP or MSDP at all it is somewhere in this
-- output, and the field name it uses is the one thing a probe can tell us that
-- guessing cannot.
local function printProbe()
    print(TAG .. "--- every GMCP package ---")
    local all = nil
    pcall(function() all = getAllGMCPData() end)
    if type(all) == "table" then
        tprint(all)
    else
        print(TAG .. "(no GMCP data in the store)")
    end

    print(TAG .. "--- every MSDP variable ---")
    local ms = nil
    pcall(function() ms = getAllMSDPVariables() end)
    if type(ms) ~= "table" then
        print(TAG .. "(no MSDP data)")
        return
    end

    local count = 0
    for _ in pairs(ms) do count = count + 1 end
    if count > 0 then tprint(ms) else print(TAG .. "(MSDP table is empty)") end
end

-- The dbchar handler, at file scope rather than as a closure inside init().
--
-- Not style: init() was at 52 upvalues of 60. Upvalues propagate through
-- nesting, so every file-scope name this body touches was also one of init's,
-- and fourteen of them are referenced nowhere else in init. Lifting it out is
-- what buys the room for the tabs and the item panes.
local function charCommand(args)
    local cmd = trimBoth(tostring(args or ""))
    local low = cmd:lower()

    if low == "show" then
        showWidget(panel.id, true)
        safeRender(true)
    elseif low == "hide" then
        hideWidget(panel.id, true)
    elseif low == "items gag on" or low == "items gag off" then
        gear.gag = (low == "items gag on")
        saveSettings()
        if gear.gag then
            echo(TAG .. "captured lists are hidden from the main window; the "
                .. "tabs still fill in.", panel.C.energy)
        else
            echo(TAG .. "captured lists show in the main window as usual.", panel.C.energy)
        end

    elseif low == "items trace on" or low == "items trace off" then
        gear.trace = (low == "items trace on")
        if gear.trace then
            echo(TAG .. "every 'You ' line will say what the item reader made "
                .. "of it. 'dbchar items trace off' when you have seen enough.", panel.C.energy)
        else
            echo(TAG .. "item reader is quiet again.", panel.C.energy)
        end

    elseif low == "items list" then
        -- The rows themselves, verbatim and numbered. Counts said the lists were
        -- being edited correctly while the panel disagreed, and a count cannot
        -- tell you what is actually in a row -- whether the empty-slot filter
        -- caught this MUD's wording, or where an added row landed.
        for _, kind in ipairs({ "inv", "eq", "cont" }) do
            local rows = gear.list[kind]
            local n = 0
            if type(rows) == "table" then
                for i, row in ipairs(rows) do
                    print(TAG .. kind .. " " .. i .. ": [" .. tostring(row) .. "]")
                    n = i
                end
            end
            if n == 0 then print(TAG .. kind .. ": empty") end
        end
        print(TAG .. "captured: inv=" .. tostring(gear.seen.inv)
            .. " eq=" .. tostring(gear.seen.eq))
        print(TAG .. "last move: " .. tostring(ev.why))
        for key, rows in pairs(cont.list) do
            if type(rows) == "table" then
                for i, row in ipairs(rows) do
                    print(TAG .. "in " .. tostring(key) .. " " .. i
                        .. ": [" .. tostring(row) .. "]")
                end
            end
        end

    elseif low == "items clear" then
        gear.list = { inv = {}, eq = {}, cont = {} }
        gear.stale = { inv = true, eq = true, cont = true }
        gear.seen = { inv = false, eq = false, cont = false }
        -- What each bag holds goes with them, and every bag closes. Which items
        -- ARE containers is kept: that was learned, not captured, and it is the
        -- one thing here worth remembering.
        for k in pairs(cont.list) do cont.list[k] = nil end
        for k in pairs(cont.open) do cont.open[k] = nil end
        -- and what 'ana' said about each item, which was surviving a clear and
        -- then answering the next click out of a stale reading
        for k in pairs(cont.anaOf) do cont.anaOf[k] = nil end
        for k in pairs(cont.anaOpen) do cont.anaOpen[k] = nil end
        safeRender(true)
        echo(TAG .. "captured lists dropped.", panel.C.energy)

    elseif low:sub(1, 7) == "avatar " then
        local url = trimBoth(cmd:sub(8))
        if url == "clear" then
            avatarUrl = ""
            echo(TAG .. "back to the race avatar.", panel.C.energy)
        else
            applyImage(url, function(clean)
                avatarUrl = clean
                echo(TAG .. "avatar set: " .. clean, panel.C.energy)
                saveSettings()
                safeRender(true)
            end)
            return
        end
        saveSettings()
        safeRender(true)
    elseif low:sub(1, 8) == "opacity " then
        local n = safeNum(low:sub(9))
        if not n or n < 0 or n > 100 then
            echo(TAG .. "opacity takes 0-100.", "#ff6666")
            return
        end
        panel.alpha = math.floor(n) / 100
        saveSettings()
        applyAlpha()
        safeRender(true)
    elseif low:sub(1, 5) == "name " then
        local n = trimBoth(cmd:sub(6))
        if n == "clear" then
            profile.override = ""
            echo(TAG .. "name back to what score reports.", panel.C.energy)
        else
            profile.override = n
            sc.name = n
            echo(TAG .. "name set to " .. n .. ".", panel.C.energy)
        end
        saveSettings()
        safeRender(true)

    elseif low == "pl" then
        if panel.plMode == "nums" then panel.plMode = "bar" else panel.plMode = "nums" end
        saveSettings()
        safeRender(true)
        echo(TAG .. "power display: " .. panel.plMode, panel.C.energy)
    elseif low:sub(1, 5) == "font " then
        local spec = trimBoth(low:sub(6))
        if spec == "+" then
            panel.font.scale = math.min(2, panel.font.scale + 0.1)
        elseif spec == "-" then
            panel.font.scale = math.max(0.5, panel.font.scale - 0.1)
        else
            local n = safeNum(spec)
            if not n or n < 50 or n > 200 then
                echo(TAG .. "font takes +, - or a percent 50-200.", "#ff6666")
                return
            end
            panel.font.scale = n / 100
        end
        -- one decimal, so the +/- steps land on clean values
        panel.font.scale = math.floor(panel.font.scale * 10 + 0.5) / 10
        saveSettings()
        safeRender(true)
        echo(TAG .. "font " .. math.floor(panel.font.scale * 100 + 0.5) .. "%", panel.C.energy)
    elseif low == "gag on" or low == "gag off" then
        gag.on = (low == "gag on")
        saveSettings()
        applyGag()
        pr.arm()
        if gag.on then
            echo(TAG .. "hiding prompt lines matching '" .. pr.cur.tag
                .. "' from the main window.", panel.C.energy)
        else
            echo(TAG .. "the prompt line shows in the main window.", panel.C.energy)
        end

    elseif low == "forms" then
        local n = 0
        for name, f in pairs(form.ALL) do
            n = n + 1
            local marker = ""
            if name == form.name then marker = "   <- active" end
            echo(TAG .. name .. "  " .. f.url .. marker, panel.C.energy)
            echo("           when a line contains: " .. f.pat, panel.C.ink_dim)
        end
        if n == 0 then
            echo(TAG .. "no forms yet. Add one on the settings screen (the gear),", panel.C.energy)
            echo("           or: dbchar form <name> <url|base> <message>", panel.C.energy)
        end

    elseif low:sub(1, 5) == "form " then
        -- dbchar form <name> <url|base> <the announcement text...>
        -- The url is one token and the message is everything after it, which
        -- is why the url comes second: messages have spaces in them.
        -- One capture per value. A three-capture match that MISSES hands back
        -- undefined for all of them, and undefined is truthy -- so 'if not name'
        -- passed and the ':lower()' below threw on 'dbchar form ssj' with an
        -- argument short. Sharp edges 13 and 17.
        local name = cmd:match("^%S+%s+(%S+)%s+%S+%s+.+$")
        local url  = cmd:match("^%S+%s+%S+%s+(%S+)%s+.+$")
        local msg  = cmd:match("^%S+%s+%S+%s+%S+%s+(.+)$")
        if type(name) ~= "string" or type(url) ~= "string" or type(msg) ~= "string"
            or name == "" or url == "" or trimBoth(msg) == "" then
            echo(TAG .. "dbchar form <name> <http(s) url|base> <message text>", "#ff6666")
            return
        end
        local key = name:lower()
        local said = trimBoth(msg)

        -- 'base' means back-to-normal rather than a picture, so it skips the
        -- resolver. Everything else goes through it: this url is concatenated
        -- into a CSS url(), and a share page put there fetches markup and draws
        -- nothing at all.
        if url == "base" then
            form.ALL[key] = { pat = said, url = "base" }
            saveSettings()
            safeRender(true)
            echo(TAG .. "form " .. key .. " set to base. It clears the portrait "
                .. "when a line contains: " .. said, panel.C.energy)
            return
        end

        applyImage(url, function(clean)
            form.ALL[key] = { pat = said, url = clean }
            saveSettings()
            safeRender(true)
            echo(TAG .. "form " .. key .. " set: " .. clean, panel.C.energy)
            echo(TAG .. "it shows when a line contains: " .. said, panel.C.energy)
        end)

    elseif low == "formfix" then
        -- Repair forms already stored pointing at a share page.
        --
        -- Every form set before the resolver was wired in went in raw, so a set
        -- built by pasting from a browser's address bar is a list of web pages
        -- and draws nothing. Re-asking each page for its image beats retyping
        -- five announcements a paragraph long.
        local todo = {}
        for fnm, frec in pairs(form.ALL) do
            if type(frec) == "table" and type(frec.url) == "string"
                and frec.url ~= "base" and looksLikeImage(frec.url) == false then
                todo[#todo + 1] = fnm
            end
        end
        if #todo == 0 then
            echo(TAG .. "every form already points at an image file.", panel.C.energy)
            return
        end
        echo(TAG .. #todo .. " form(s) point at a page rather than an image. "
            .. "Asking each one...", panel.C.energy)
        for _, fnm in ipairs(todo) do
            local frec = form.ALL[fnm]
            applyImage(frec.url, function(clean)
                -- Read the record again: this lands after a round trip, and the
                -- list may have been edited in between.
                local now = form.ALL[fnm]
                if type(now) ~= "table" then return end
                now.url = clean
                saveSettings()
                safeRender(true)
                echo(TAG .. fnm .. " -> " .. clean, panel.C.energy)
            end)
        end

    elseif low:sub(1, 7) == "unform " then
        local name = trimBoth(low:sub(8))
        if not form.ALL[name] then
            echo(TAG .. "no form called " .. name .. ". 'dbchar forms' lists them.",
                "#ff6666")
            return
        end
        -- Rebuilt rather than nil'd: sharp edge 3b leaves the key standing.
        local kept = {}
        for fnm, frec in pairs(form.ALL) do
            if fnm ~= name and type(frec) == "table" then kept[fnm] = frec end
        end
        form.ALL = kept
        if form.name == name then
            form.name = ""
            form.url = ""
        end
        saveSettings()
        safeRender(true)
        echo(TAG .. "form " .. name .. " removed.", panel.C.energy)

    elseif low == "base" then
        -- manual reset, for a revert line that was missed or never set
        form.url = ""
        form.name = ""
        safeRender(true)
        echo(TAG .. "back to the base portrait.", panel.C.energy)

    elseif low == "diag" then
        printDiag()
    elseif low == "storecheck" then
        -- Does a write actually survive?
        --
        -- 'lastError=none' only says saveTable did not throw. It says nothing
        -- about whether anything was kept, and a settings screen that saves
        -- into a hole looks exactly like one that saved. So: write, force the
        -- flush, read straight back, and compare.
        -- Read and report FIRST. This used to save before reading, which meant
        -- running it after a restart to see what survived overwrote the
        -- anonymous profile with the empty state it had just come up in --
        -- destroying the evidence it was called to collect.
        local was, wasBak = nil, nil
        pcall(function() was = loadTable("dbi-portrait-prefs", "global") end)
        pcall(function() wasBak = loadTable("dbi-portrait-prefs-bak", "global") end)
        for _, pair in ipairs({ { "primary", was }, { "backup ", wasBak } }) do
            local t = pair[2]
            if type(t) ~= "table" then
                echo(TAG .. "before: " .. pair[1] .. " unreadable", "#ffb02e")
            else
                local pc, fc = 0, 0
                for _ in pairs(t.profiles or {}) do pc = pc + 1 end
                local m = (t.profiles or {})[profile.key]
                if type(m) == "table" then
                    for _ in pairs(m.forms or {}) do fc = fc + 1 end
                end
                echo(TAG .. "before: " .. pair[1] .. " profiles=" .. pc
                    .. " last=" .. tostring(t.last) .. " forms[" .. profile.key
                    .. "]=" .. fc, panel.C.energy)
            end
        end

        saveSettings()
        local back = nil
        local ok = pcall(function() back = loadTable("dbi-portrait-prefs", "global") end)
        if not ok or type(back) ~= "table" then
            echo(TAG .. "STORE BROKEN: wrote, and loadTable gave back "
                .. type(back) .. ". Nothing this plugin saves is being kept.",
                "#ff6666")
            return
        end
        if back.stamp ~= numSave.stamp then
            echo(TAG .. "STORE STALE: wrote stamp " .. tostring(numSave.stamp), "#ff6666")
            echo(TAG .. "            read back  " .. tostring(back.stamp), "#ff6666")
            echo(TAG .. "The write is not landing. Everything below is the OLD "
                .. "contents.", "#ff6666")
        else
            echo(TAG .. "store ok -- the write came back byte for byte.", panel.C.energy)
        end

        -- and what is actually in there, whichever way that went
        local pn, fn = 0, 0
        for _ in pairs(back.profiles or {}) do pn = pn + 1 end
        local mine = (back.profiles or {})[profile.key]
        if type(mine) == "table" then
            for _ in pairs(mine.forms or {}) do fn = fn + 1 end
        end
        echo(TAG .. "on disk: profiles=" .. pn .. " last=" .. tostring(back.last), panel.C.energy)
        echo(TAG .. "  for [" .. profile.key .. "]: forms=" .. fn
            .. " avatar=" .. tostring(type(mine) == "table" and mine.avatarUrl or "-"), panel.C.energy)
        echo(TAG .. "in memory: forms=" .. tostring(formCountNow())
            .. " avatar=" .. tostring(avatarUrl), panel.C.energy)

    elseif low == "probe" then
        printProbe()
    else
        echo(TAG .. "dbchar show | hide | pl", panel.C.energy)
        echo("          the tabs under the portrait pick the view", panel.C.ink_dim)
        echo("          the gear opens settings -- everything below is on it", panel.C.ink_dim)
        echo("          dbchar font +|-|<50-200>   text size (saved)", panel.C.energy)
        echo("          dbchar gag on|off          hide the prompt line", panel.C.energy)
        echo("          dbchar avatar <http(s) url>|clear", panel.C.energy)
        echo("          dbchar form <name> <url|base> <message>", panel.C.energy)
        echo("          dbchar forms | unform <name> | base", panel.C.energy)
        echo("          dbchar formfix             re-ask share pages for the image", panel.C.energy)
        echo("          dbchar name <name>|clear", panel.C.energy)
        echo("          dbchar items gag on|off      hide captured lists", panel.C.energy)
        echo("          dbchar items list            print the rows as stored", panel.C.energy)
        echo("          dbchar items trace on|off    say what each line did", panel.C.energy)
        echo("          dbchar items clear           forget them", panel.C.energy)
        echo("          dbchar storecheck          prove a write survives", panel.C.energy)
        echo("          dbchar opacity <0-100> | diag | probe", panel.C.energy)
    end
end


----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

function init()
    readTerminalFont()

    -- One field at a time, and the old variables read as a fallback so
    -- settings made before this changed are not thrown away.
    local p = loadTable("dbi-portrait-prefs", "global")
    if type(p) ~= "table" then p = {} end

    -- Anything written before the move to the global store, merged in rather
    -- than swapped for.
    --
    -- This guard used to be 'only if the global store has no profiles at all',
    -- and that was too weak by exactly one step: after the move, the plugin
    -- came up knowing nothing, read a score, and wrote an EMPTY solao profile
    -- to the new key. From then on the new store had a profile, so the
    -- migration never ran again and five transformations sat unreachable in
    -- the old one. Merging field by field cannot get stuck that way -- an empty
    -- profile takes everything, a full one takes nothing.
    --
    -- The old store is default-scope, which means the world file, which is not
    -- readable until a world is open. At init it usually is not, so this is
    -- expected to do nothing on the first pass and the late re-read below is
    -- what actually lands it.
    local legacy = nil
    pcall(function() legacy = loadTable("portraitprefs") end)
    if type(legacy) == "table" and type(legacy.profiles) == "table" then
        if type(p.profiles) ~= "table" then p.profiles = {} end
        for k, v in pairs(legacy.profiles) do
            if type(k) == "string" and type(v) == "table" then
                local mine = p.profiles[k]
                if type(mine) ~= "table" then
                    p.profiles[k] = v
                else
                    for fk, fv in pairs(v) do
                        local cur = mine[fk]
                        local empty = (cur == nil or cur == "")
                        if not empty and type(cur) == "table" then
                            empty = true
                            for _ in pairs(cur) do empty = false end
                        end
                        if empty then mine[fk] = fv end
                    end
                end
            end
        end
        if not has(p.last) and has(legacy.last) then p.last = legacy.last end
    end

    -- The backup, and a per-profile merge taking whichever copy has more in it.
    --
    -- This exists because the client has handed back an older revision after a
    -- restart -- confirmed write, stale read -- and losing a profile that way
    -- is silent. Merged per character rather than choosing one table wholesale,
    -- so a copy that is newer for one alt and older for another cannot take the
    -- other one down with it. All of it inline: the chunk is one local off Lua
    -- 5.1's 200 ceiling and a helper would be the two-hundred-and-first.
    local bak = nil
    pcall(function() bak = loadTable("dbi-portrait-prefs-bak", "global") end)
    if type(bak) == "table" then
        if type(p.profiles) ~= "table" then p.profiles = {} end
        if type(bak.profiles) == "table" then
            for k, v in pairs(bak.profiles) do
                if type(k) == "string" and type(v) == "table" then
                    local mine = p.profiles[k]
                    if type(mine) ~= "table" then
                        p.profiles[k] = v
                    else
                        -- Field by field, never wholesale. Taking the heavier
                        -- profile entire looked right and was not: a backup
                        -- rich in forms but with no item lists would replace
                        -- one that had them, so restoring one thing lost
                        -- another. Filling only what is missing cannot.
                        for fk, fv in pairs(v) do
                            local cur = mine[fk]
                            local empty = (cur == nil or cur == "")
                            if not empty and type(cur) == "table" then
                                empty = true
                                for _ in pairs(cur) do empty = false end
                            end
                            if empty then mine[fk] = fv end
                        end
                    end
                end
            end
        end
        -- and the scalars, when the primary came back with nothing to say
        if not has(p.last) and has(bak.last) then p.last = bak.last end
        if type(p.prompts) ~= "table" and type(bak.prompts) == "table" then
            p.prompts = bak.prompts
        end
    end

    -- Restored before anything can read a prompt, so a returning session knows
    -- its own format on the first line rather than after seeing one.
    pr.cur.learned = promptsFrom(p.prompts)
    -- Revalidated the same way the list is: a stored string that no longer
    -- compiles is dropped rather than shown as if it were live.
    if type(p.promptFmt) == "string" and promptCompile(p.promptFmt) then
        pr.learnedFor.prompt = p.promptFmt
    end
    if type(p.fpromptFmt) == "string" and promptCompile(p.fpromptFmt) then
        pr.learnedFor.fprompt = p.fpromptFmt
    end
    promptRebuild()

    local v = p.view
    if not has(v) then v = getVariable("view") end
    -- The tab comes back, the settings screen does not: booting into a config
    -- panel hides the character you logged in to look at.
    for _, tb in ipairs(panel.TABS) do
        if v == tb.id then panel.view = v end
    end

    local pm = p.plMode
    if not has(pm) then pm = getVariable("plMode") end
    if pm == "nums" then panel.plMode = "nums" end

    local fsc = safeNum(p.fontScale)
    if not fsc then fsc = safeNum(getVariable("fontScale")) end
    if fsc and fsc >= 0.5 and fsc <= 2 then panel.font.scale = fsc end

    local gp = p.gagPrompt
    if not has(gp) then gp = getVariable("gagPrompt") end
    if gp == "yes" then gag.on = true end

    if p.itemsGag == "yes" then gear.gag = true end
    if p.srcMode == "prompt" then src.bars = "prompt" end
    if p.srcStats == "score" then src.stats = "score" end
    if p.srcItems == "capture" then src.items = "capture" end
    if p.srcAuc == "chan" then src.auc = "chan" end

    -- Stored data is still data: a table written by an older build, or edited
    -- by hand, has never been through itemPhrase. Letters, digits and single
    -- spaces -- a key is two words now, so the old letters-only test threw away
    -- every container it had learned. '%w' rather than a range, which does not
    -- survive translation inside a class.
    if type(p.containers) == "table" then
        for k, v in pairs(p.containers) do
            if type(k) == "string" and v == true and k:match("^[%w ]+$") then
                cont.is[k] = true
            end
        end
    end

    local pa = safeNum(p.panelAlpha)
    if not pa then pa = safeNum(getVariable("panelAlpha")) end
    if pa and pa >= 0 and pa <= 1 then panel.alpha = pa end

    if type(p.profiles) == "table" then profile.all = p.profiles end

    -- Lowercased on the way in, because keys are lowercased now and a 'last'
    -- written by an older build still says 'Solao'. Without this the restore
    -- looks up a key that no longer exists and you come back to an empty panel
    -- with your own profile sitting right there unused.
    if type(p.last) == "string" then profile.key = trimBoth(p.last):lower() end

    -- Same migration for the profiles themselves: fold any differently-cased
    -- key onto its lowercase spelling once, rather than leaving two.
    local folded = {}
    for k, v in pairs(profile.all) do
        if type(k) == "string" and type(v) == "table" then
            local lk = k:lower()
            -- The fuller one wins. This used to keep whichever pairs() yielded
            -- first, so a character with two spellings in the store came back
            -- configured or blank depending on the run.
            if folded[lk] == nil or profileWeight(v) > profileWeight(folded[lk]) then
                folded[lk] = v
            end
        end
    end
    profile.all = folded

    -- Whoever was on last. If 'last' names nothing -- an empty string from a
    -- session that never read a score, or a key whose profile did not survive
    -- -- fall back to the fullest profile in the store rather than coming up
    -- blank with the settings sitting right there unused. A launch should never
    -- show less than the last one did.
    local prof = profile.all[profile.key]
    if profileWeight(prof) <= 0 then
        local bestKey, bestAt = nil, -1
        for k, v in pairs(profile.all) do
            if type(k) == "string" and k ~= "" then
                local w = profileWeight(v)
                if w > bestAt then
                    bestAt = w
                    bestKey = k
                end
            end
        end
        if bestKey ~= nil and bestAt > 0 then
            profile.key = bestKey
            prof = profile.all[bestKey]
        end
    end
    if type(prof) ~= "table" then prof = {} end

    if type(prof.sc) == "table" then
        sc = prof.sc
        sheet.seen = true
    end

    -- Last known, so the bars are drawn before anything arrives. Live data
    -- overwrites every one of these the moment it turns up.
    if type(prof.vitals) == "table" then vit = prof.vitals end
    if type(prof.prompt) == "table" then
        for k, v in pairs(prof.prompt) do
            if safeNum(v) then charState[k] = safeNum(v) end
        end
    end

    local au = prof.avatarUrl
    if not has(au) then au = p.avatarUrl end
    if not has(au) then au = getVariable("avatarUrl") end
    -- Through the same check the write path uses. This lands in a raw CSS
    -- url() concatenation, and a stored value has been trusted since it was
    -- written by a build whose rules may not have been today's.
    if type(au) == "string" then avatarUrl = safeAvatarUrl(au) end

    local no = prof.nameOverride
    if not has(no) then no = p.nameOverride end
    if not has(no) then no = getVariable("nameOverride") end
    if type(no) == "string" then profile.override = no end

    -- The forms belong to the character. The active one deliberately does not
    -- come back: a session starts in base form, and a portrait insisting you are
    -- still Super Saiyan from two days ago is worse than none.
    form.ALL = formsFrom(prof.forms)

    restoreItems(prof)

    -- Came up knowing nothing? Look again in a moment.
    --
    -- The client's storage is not always readable at plugin-load time, and when
    -- it is not, init() gets nil and the panel comes up blank with no character
    -- at all. Seconds later the same read works -- storecheck proved that,
    -- reporting 'profiles=2 last=solao' off a store this function had just read
    -- as empty. The save path no longer destroys anything in that state, but
    -- coming up blank for a whole session is still wrong when the settings are
    -- sitting right there.
    --
    -- Only when nothing was found, so a real first run is untouched.
    -- Nothing the user configured? Then keep looking.
    --
    -- The test used to be 'no profiles at all', which missed the case that
    -- actually happened: a profile that exists and is EMPTY. After the move to
    -- the global store this plugin came up blank, read a score, wrote an empty
    -- solao, and from then on had "a profile" -- so it stopped looking while
    -- five transformations sat in the store it had stopped reading.
    --
    -- An avatar, a name or a form is what a person put there. None of the
    -- three means there is nothing to lose by looking again.
    if avatarUrl == "" and profile.override == "" and formCountNow() == 0 then
        -- Backed off rather than one shot at three seconds. The race is not
        -- rare -- it fired on the first restart after this shipped -- so the
        -- panel would sit blank for three seconds on most launches. First look
        -- is a quarter second in, which is usually enough, and the later ones
        -- are there for a slow start rather than the normal case.
        --
        -- Declared then assigned. 'local function f' that refers to itself is
        -- the forward-declaration shape, and this transpiler turns that into an
        -- illegal shadow (sharp edge 6); the assignment form is fine.
        local waits = { 250, 600, 1500, 3000, 6000 }
        local tryLate = nil
        tryLate = function(step)
            if avatarUrl ~= "" or profile.override ~= "" or formCountNow() > 0 then return end

            -- BOTH stores, every time. The new one may hold a profile that is
            -- merely empty, and stopping there is what left the old one
            -- unreachable; whichever actually has something wins.
            local rec, who = nil, ""
            for _, from in ipairs({ "global", "legacy" }) do
                local late = nil
                if from == "global" then
                    pcall(function() late = loadTable("dbi-portrait-prefs", "global") end)
                else
                    -- world file: only readable once a world is open, which is
                    -- the whole reason this runs late rather than at init
                    pcall(function() late = loadTable("portraitprefs") end)
                end
                if type(late) == "table" and type(late.profiles) == "table" then
                    local key = ""
                    if has(late.last) then key = trimBoth(tostring(late.last)):lower() end
                    if key == "" and profile.key ~= "" then key = profile.key end
                    local got = late.profiles[key]
                    if type(got) == "table" and profileWeight(got) > profileWeight(rec) then
                        rec, who = got, key
                        if type(profile.all) ~= "table" or rowCountOf(profile.all) == 0 then
                            profile.all = late.profiles
                        end
                    end
                end
            end

            -- Nothing worth having in either. Come back, unless patience is out.
            if type(rec) ~= "table" or profileWeight(rec) <= 1 then
                local nxt = waits[step + 1]
                if nxt then
                    pcall(function() addTimer(nxt, function() tryLate(step + 1) end) end)
                end
                return
            end

            if who ~= "" then profile.key = who end
            if type(profile.all[profile.key]) ~= "table" then profile.all[profile.key] = rec end
            if type(rec.avatarUrl) == "string" then avatarUrl = safeAvatarUrl(rec.avatarUrl) end
            if type(rec.nameOverride) == "string" then profile.override = rec.nameOverride end
            form.ALL = formsFrom(rec.forms)
            if type(rec.sc) == "table" then sc = rec.sc end
            restoreItems(rec)
            safeRender(true)
            saveSettings()
            echo(TAG .. "picked up " .. profile.key .. "'s settings "
                .. tostring(waits[step]) .. "ms in ("
                .. formCountNow() .. " form(s)).", panel.C.energy)
        end
        pcall(function() addTimer(waits[1], function() tryLate(1) end) end)
    end

    makeWidget()
    -- pcall: a stored format that will not compile must cost a gag, not the
    -- rest of init. Everything below here -- the GMCP hook, the tick, the
    -- dbchar command itself -- sits after this call, and losing dbchar means
    -- losing the only way to fix a bad stored value.
    pcall(applyGag)
    pcall(pr.arm)

    -- One handler for the tree. Whichever package fired, everything under it
    -- is re-read -- they arrive together and a partial refresh would leave the
    -- panel showing one packet's idea of the character and another's numbers.
    -- ONE handler for the whole tree, subscribed under every spelling.
    --
    -- Not one per package: the client keys its subscriptions by package name,
    -- so registering a second callback for "char" REPLACES the first. Vitals
    -- and the tree both wanted that name, and the suite caught the vitals
    -- handler disappearing the moment they both asked for it.
    --
    -- Everything is re-read on any of them, because they arrive together and a
    -- partial refresh would leave the panel showing one packet's character
    -- beside another's numbers.
    local function onChar(data)
        local ok, err = pcall(function()
            local drew = acceptVitals(data)
            local root = charTree(data)
            if type(root) == "table" then
                if acceptInfo(root.info) then drew = true end
                if acceptStats(root.stats) then drew = true end
                if acceptGear(root) then drew = true end
            end
            if drew then safeRender() end
        end)
        if not ok then print(TAG .. "char error: " .. tostring(err)) end
    end

    for _, pkg in ipairs({ "char", "Char",
                           "char.vitals", "Char.Vitals",
                           "char.info", "Char.Info",
                           "char.stats", "Char.Stats",
                           "char.equipment", "Char.Equipment",
                           "char.inventory", "Char.Inventory" }) do
        onGMCPUpdate(pkg, onChar)
    end

    -- char.effects: everything switched on, with its category and sometimes
    -- a figure. Arrays cross this boundary 0-indexed and as objects with
    -- numeric keys, so the list goes through normArray, and a missing field
    -- arrives as the string 'undefined' rather than absent.
    local function onEffects(data)
        local raw = data
        if type(raw) == "table" and type(raw.effects) == "table" then
            raw = raw.effects
        end
        local list, n = normArray(raw)
        local now = {}
        for i = 1, n do
            local one = list[i]
            if type(one) == "table" and type(one.name) == "string"
                and one.name ~= "" and one.name ~= "undefined" then
                local cat = one.category
                if type(cat) ~= "string" or cat == "undefined" then cat = "" end
                now[#now + 1] = { name = one.name, cat = cat,
                                  val = safeNum(one.value) }
            end
        end
        effects = now
        effectsSeen = true
        safeRender()
    end
    onGMCPUpdate("char.effects", onEffects)
    onGMCPUpdate("Char.Effects", onEffects)

    -- char.target: { name, hit, race }. More than the prompt ever gave -- it
    -- names the thing -- and no trigger needed to read it. Both spellings,
    -- because this client has answered to either for vitals.
    onGMCPUpdate("char.target", onTarget)
    onGMCPUpdate("Char.Target", onTarget)

    -- comm.auction: { item, bid }. Both spellings and both shapes -- the node
    -- may arrive as the leaf or as its parent.
    onGMCPUpdate("comm.auction", onAuction)
    onGMCPUpdate("Comm.Auction", onAuction)
    onGMCPUpdate("comm", onAuction)

    setVariable("instance", INSTANCE)
    pcall(setVariable, "instanceAt", tostring(INSTANCE_AT))
    nego.connected = true

    tickTimer = addTimer(1000, function()
        -- Reload guard, fail OPEN. The string-equality check this replaces
        -- killed the tick whenever getVariable answered with a stale value --
        -- setVariable rides the saveState debounce, so just after a reload it
        -- can still hand back the PREVIOUS load's stamp, and the only live tick
        -- shot itself on its first second.
        --
        -- That tick is not decoration: it is the only thing that runs
        -- ensureGmcp, the late vitals retries, and the unsolicited score. Now
        -- only a provably NEWER load stops this one, and a stale or missing
        -- stamp is corrected rather than obeyed.
        local seen = safeNum(getVariable("instanceAt"))
        if seen and seen > INSTANCE_AT then
            if tickTimer then removeTimer(tickTimer) end
            return
        end
        if seen ~= INSTANCE_AT then
            pcall(setVariable, "instanceAt", tostring(INSTANCE_AT))
        end

        -- a fight ending without another prompt would leave the enemy bar up
        -- forever; this is the backstop behind the no-Foe-on-the-prompt clear
        -- The numbers, on their five-minute leash. Settings do not wait for
        -- this -- they write and flush the moment they change.
        saveNumbers()

        if foe.val and (os.clock() - foe.at) > foe.stale then
            foe.why = "went stale after " .. tostring(os.clock() - foe.at) .. "s"
            foe.val = nil
            safeRender()
        end

        if not nego.connected then return end

        nego.tick = nego.tick + 1
        -- staggered a second behind Scouter so its stamp is already down and
        -- only one Core.Hello goes out when both are installed
        if nego.tick == 3 then ensureGmcp() end
        -- a packet may already be sitting in the store from before we subscribed
        if nego.tick == 4 or nego.tick == 10 then
            if acceptVitals(nil) then safeRender() end
        end
        -- Nothing is sent from here. This used to fire one unsolicited 'score'
        -- six ticks after connect to fill the panel at login, and six ticks
        -- after connect on this MUD is while you are still at the name or the
        -- password prompt -- so the word went into the login, not the game.
        --
        -- The panel fills from the stored profile instead, and the refresh
        -- button on each tab asks when you want it asked.
    end, true)

    -- Whoever owns the GMCP handshake says so here.
    on("dbi.gmcp.owner", function() gmcpOwned = true end)

    registerCommand("dbchar", charCommand, "Character portrait")
end

function onConnect(sessionId)
    nego.connected = true
    nego.tick = 0
    vit = nil
    foe.val = nil
    foe.why = "reconnected"
    -- Everything the prompt fed us dies with the connection it was read from.
    -- charState was never cleared anywhere, so reconnecting on an alt carried
    -- the previous character's zeni, armour and opponent lifeforce until each
    -- field happened to be overwritten -- the same lie this file's own header
    -- warns about for vitals.
    charState = {}
    posture = ""
    -- a fresh login stands in base form whatever was active before
    form.url = ""
    form.name = ""
    safeRender()
end

function onDisconnect(sessionId)
    nego.connected = false
end

-- Read, never rewritten. The only line that can disappear is the prompt, and
-- only when the gag is deliberately on -- that happens in a trigger, not here.
function onLine(sessionId, rawLine, cleanLine)
    local drop = false
    local ok, err = pcall(function()
        local clean = dropAnsiDebris(trimBoth(cleanLine))

        if feedItems(clean) then drop = true end
        if feedAuction(clean) then cap.dirty = true end
        if not cap.kind then
            if feedItemEvent(clean) then cap.dirty = true end
            if gear.trace and clean:sub(1, 4) == "You " then
                print(TAG .. "reader: " .. tostring(ev.why))
            end
        end
        if cap.dirty then
            cap.dirty = false
            safeRender()
        end

        -- The blank line a prompt format ending in '%Y' leaves behind. Only the
        -- one, and only straight after such a prompt.
        if clean == "" then
            if gag.on and pr.cur.blank then drop = true end
            pr.cur.blank = false
            return
        end

        -- 'prompt' with no argument prints the format string on the line after
        -- "Your current prompt string:", all on one line however many '%Y' it
        -- carries. That is the only reliable way to learn a prompt this plugin
        -- does not already know.
        --
        -- Deliberately not "Replacing old prompt of:", which the MUD prints
        -- when you CHANGE your prompt and which is followed by the one you just
        -- got rid of.
        if ask.expect then
            ask.expect = false
            local low = clean:lower()
            if low:find("default prompt", 1, true) then
                echo(TAG .. "that is the stock prompt, which is already known.",
                    panel.C.energy)
            -- Plain find rather than the pattern '%%'. Not a fix: diag showed
            -- learned=4 with both formats captured, so the pattern form works.
            -- Kept because a plain find cannot be translated wrong, and this
            -- gate decides whether a line is a format at all.
            elseif not clean:find("%", 1, true) then
                -- A format with no tokens in it at all. 'prompt hello' does
                -- this. Whatever was learned for that slot is not what is
                -- running any more, so it goes rather than sitting there armed.
                if ask.want then
                    pr.learnedFor[ask.want] = nil
                    saveSettings()
                    echo(TAG .. "your " .. ask.want .. " has no fields in it; "
                        .. "nothing to read.", "#ffb02e")
                end

            elseif clean:find("%", 1, true) then
                -- Two facts, two guards. Which prompt this is gets recorded
                -- whether or not the format turns out to be new -- promptLearn
                -- returns false for one it already holds, and hanging both on
                -- that return meant re-running 'prompt' recorded nothing.
                if ask.want then pr.learnedFor[ask.want] = clean end
                promptLearn(clean)
                saveSettings()
            end
            ask.want = nil
        elseif clean:find("Replacing old prompt of", 1, true) then
            -- The MUD prints this and then the format being REPLACED, which is
            -- no use. Ask it what it now holds instead of trusting what was
            -- typed: it normalises, and it accepts junk.
            if ask.echo then
                -- 'again', not 'ask'. A local of the same name as the table
                -- shadows it, and the next line then indexes a string.
                local again = ask.echo
                ask.echo = nil
                pcall(function() send(again) end)
            end

        elseif clean:find("prompt string", 1, true) then
            -- "Your current prompt string:" versus "Your current fighting
            -- prompt string:". Both confirmed from the MUD.
            if clean:lower():find("fighting", 1, true) then
                ask.want = "fprompt"
            else
                ask.want = "prompt"
            end
            -- 'prompt string' rather than 'current prompt string': there are two
            -- prompts on this MUD and only one of them has been seen announcing
            -- itself. Whatever 'fprompt' calls its own header, it almost
            -- certainly contains those two words, and a format is only learned
            -- if the line after it actually carries a '%'.
            ask.expect = true
        end
        local changed = feedScore(clean)
        if parseLook(clean) then changed = true end
        if feedFoe(clean) then changed = true end
        if feedForm(clean) then changed = true end
        if feedPosture(clean) then changed = true end

        -- The first prompt names the label this session uses. If the gag was
        -- turned on before that -- or armed against the other format -- re-arm
        -- it now that the MUD has said which one it is.
        if gag.on and (gag.tag ~= pr.cur.tag or gag.sig ~= pr.cur.sig) then
            applyGag()
        end

        if changed then safeRender() end
    end)
    if not ok then
        lastError = tostring(err)
        sheet.inBlock = false
    end
    if drop then return false end
    return nil
end

-- Learn a prompt the moment it is SET, rather than waiting for someone to run
-- 'prompt' afterwards to read it back.
--
-- onSend rather than an alias. An alias replaces the command, so a mistake in it
-- costs you the ability to set a prompt at all; this only watches, and never
-- returns false, so nothing it does can block a send.
--
-- Captured from the ORIGINAL text, never from a lowercased copy: '%Y' is a
-- newline and '%y' is the enemy's lifeforce, so case-folding the argument would
-- quietly turn one token into another.
--
-- The colour codes the player types are still in here ('&WL:&Y%h'), which is
-- fine -- promptCompile strips '&x' and '^x' before it does anything else, so
-- this compiles to the same patterns the MUD's own echo would give.
function onSend(sessionId, text)
    local c = trimBoth(tostring(text or ""))
    if c == "" then return nil end

    local which, rest = nil, nil
    local got = c:match("^prompt%s+(.+)$")
    if type(got) == "string" and got ~= "" then which, rest = "prompt", got end
    if not which then
        got = c:match("^fprompt%s+(.+)$")
        if type(got) == "string" and got ~= "" then which, rest = "fprompt", got end
    end
    -- Remembered for ANY argument, not only one carrying tokens. 'prompt hello'
    -- is accepted by the MUD and leaves you running a prompt with no fields at
    -- all, so that case has to reach the read-back too.
    ask.echo = which

    if not which then return nil end

    -- 'prompt default' puts the stock one back, so whatever we had learned for
    -- that slot is no longer what the player is running.
    if rest:lower() == "default" then
        pr.learnedFor[which] = nil
        saveSettings()
        return nil
    end

    if rest:find("%", 1, true) then
        -- Colour codes come off before it is stored. promptCompile strips them
        -- anyway so the triggers are identical either way, but the settings box
        -- and 'dbchar diag' should show the same clean format the MUD echoes
        -- back, not the '&W' soup that was typed.
        local bare = rest:gsub("&.", "")
        bare = bare:gsub("%^.", "")
        bare = bare:gsub("%}.", "")
        bare = trimBoth(bare)
        if bare ~= "" then
            pr.learnedFor[which] = bare
            promptLearn(bare, true)
            saveSettings()
        end
    end
    return nil
end

-- What you type is what arms a capture. onCommand rather than a trigger on the
-- reply: the reply's header is not unique enough on its own, and arming on the
-- command means chatter arriving before it cannot be mistaken for the list.
function onCommand(sessionId, text)
    capCmds = capCmds + 1
    local c = trimBoth(tostring(text or "")):lower()
    if c == "" then return nil end

    -- Whatever you type ends a capture that is still open. Without this a block
    -- the prompt never closed runs on into the next command's output, and the
    -- eq list ended up holding a score block.
    if cap.kind then finishCapture() end

    if c == "i" or c == "inv" or c == "inventory" then
        beginCapture("inv", false)
    elseif c == "eq" or c == "equipment" then
        beginCapture("eq", false)
    elseif c:find("^ana ", 1, false) or c:find("^analyze ", 1, false) then
        beginCapture("ana", false)
        local what = c:match("^%a+%s+(.+)$")
        if type(what) == "string" then cap.target = itemPhrase(what) end

    elseif c:find(" in ", 1, true)
        and (c:find("^l ", 1, false) or c:find("^look ", 1, false)) then
        -- 'look in <thing>' is the only look that produces a list. The thing is
        -- what the contents get filed under, so it has to survive the trip.
        local what = c:match(" in%s+(.+)$")
        beginCapture("cont", false)
        if type(what) == "string" then cap.target = itemPhrase(what) end
    end
    return nil
end

function cleanup() end
