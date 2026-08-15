plugin = {
    id          = "mudlog",
    name        = "Transcript",
    version     = "0.1.5",
    author      = "Solao",
    description = "Plain-text session transcripts on disk, the way Mudlet and MushClient write them.",
    settings    = { saveState = true },
}

-- Nothing in here is specific to any MUD.
--
-- The client's own logging keeps entries in IndexedDB, caps them, and hands
-- them back only through an export. This writes a flat file you can grep, sed
-- and awk, appended as it happens.
--
-- REQUIRES the desktop app with this plugin's File System Access permission
-- ON (plugin settings -> Permissions). Without it io.open works on pseudo-files
-- inside the world file and nothing reaches the disk. savePluginFile and
-- appendPluginFile are no use here: they go through the storage engine whether
-- the toggle is on or not, which is the thing being avoided.
--
-- A relative path lands in ~/MudForge/plugin-files/mudlog/.

local VERSION = "0.1.5"

-- Every line this plugin prints carries its version. Three copies of the
-- same plugin were once live at once and nothing in the output said so.
local TAG = "[Transcript " .. VERSION .. "] "

-- The client does not reliably tear down a previous load's timers, so each
-- load stamps a token and an older tick retires itself.
local INSTANCE = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local tickTimer = nil

-- Folder and filename are separate settings: the folder is the thing anyone
-- actually wants to change, and keeping it out of the pattern means it can be
-- shown, opened and reasoned about on its own.
--
-- {date} {time} {world} {char} are substituted in the name; anything else is
-- literal.
local DEFAULT_FOLDER = "mudLogs"
local DEFAULT_NAME = "{date}-{world}.txt"

-- Where a relative path lands, per the API guide. Shown in the config panel so
-- the folder is findable without guessing.
local BASE_DIR = "~/MudForge/plugin-files/mudlog"

local enabled = true
local folder = DEFAULT_FOLDER
local namePattern = DEFAULT_NAME
local stripColour = true       -- ANSI out, like Mudlet's plain transcript
local stampLines = false       -- a per-line clock, off by default
local realFs = "unknown"       -- "yes" | "no", once the probe has run
local cmdPrefix = "> "

local handle = nil
local openPath = ""
local openMode = ""            -- which of the fallbacks actually worked
local lastError = "none"

-- Writing per line would be a syscall per line of MUD output. Lines queue and
-- go out on the tick, or when the queue gets long, or on the way down.
local queue = {}
local queued = 0
local FLUSH_LINES = 40
local written = 0
local dropped = 0

----------------------------------------------------------------------
-- helpers
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

-- Looked up through _G: a global this build does not have throws on the way
-- IN, where a pcall around the call cannot catch it.
local function callable(name)
    local ok, fn = pcall(function() return _G[name] end)
    if ok and type(fn) == "function" then return fn end
    return nil
end

local function stripAnsi(s)
    local fn = callable("stripAnsiCodes")
    if not fn then return s end
    local ok, out = pcall(fn, s)
    if ok and type(out) == "string" then return out end
    return s
end

-- Everything that reaches a filename is folded to something a filesystem will
-- take. A world called '../../etc' has to become a name, not a path.
local function safeName(s)
    local out = tostring(s or ""):gsub("[^%w%-_%. ]", "-"):gsub("%s+", "-")
    -- Separators are already gone, so this cannot traverse -- but a run of dots
    -- has no business in a filename either, and the client refuses '..' paths
    -- natively, which would silently cost the log rather than the name.
    out = out:gsub("%.%.+", "."):gsub("%-+", "-")
    out = out:gsub("^[%.%-]+", ""):gsub("[%.%-]+$", "")
    if out == "" then out = "unknown" end
    return out
end

local function trimSlashes(s)
    return (tostring(s or ""):gsub("^/+", ""):gsub("/+$", ""):gsub("//+", "/"))
end

local function worldName()
    local fn = callable("getSession")
    if fn then
        local ok, s = pcall(fn)
        if ok and type(s) == "table" then
            for _, key in ipairs({ "worldName", "name", "world", "host" }) do
                local v = s[key]
                if type(v) == "string" and v ~= "" then return safeName(v) end
            end
        end
    end
    return "world"
end

local function charName()
    local fn = callable("getVariable")
    if fn then
        local ok, v = pcall(fn, "charName")
        if ok and type(v) == "string" and v ~= "" then return safeName(v) end
    end
    return "char"
end

local function resolveName()
    local out = namePattern
    out = out:gsub("{date}", os.date("%Y-%m-%d"))
    out = out:gsub("{time}", os.date("%H%M%S"))
    out = out:gsub("{world}", worldName())
    out = out:gsub("{char}", charName())
    return out
end

local function resolvePath()
    local dir = trimSlashes(folder)
    if dir == "" then return resolveName() end
    return dir .. "/" .. resolveName()
end

-- what to tell someone looking for the file in a file manager
local function absoluteFolder()
    local dir = trimSlashes(folder)
    if dir == "" then return BASE_DIR end
    return BASE_DIR .. "/" .. dir
end

----------------------------------------------------------------------
-- the file
--
-- Append mode is not in the API docs -- only r, r+, w and w+ are -- and
-- whether a relative path creates its directories is not documented either.
-- Both are tried in the order that loses least, and 'mudlog status' reports
-- which one actually worked so a surprise is visible rather than silent.
----------------------------------------------------------------------

local function tryOpen(path, mode)
    local ok, fh = pcall(io.open, path, mode)
    if ok and fh then return fh end
    return nil
end

-- The permission being off is invisible from inside: io.open still succeeds, it
-- just lands in a pseudo-file inside the world file, so every path this plugin
-- reports is a path it is not writing to. Reading the file back does not settle
-- it either, because the pseudo-file reads back fine.
--
-- os.remove is the one call that tells the truth. It returns true only with
-- real filesystem access and bare nil everywhere else, so a throwaway file
-- gets written and deleted once to find out. It only ever touches a name this
-- plugin made up.
local function probeRealFs()
    local fh = tryOpen(".fsprobe", "w")
    if not fh then return "no" end
    pcall(function() fh:write("probe") end)
    pcall(function() fh:close() end)

    local ok, gone = pcall(os.remove, ".fsprobe")
    if ok and gone then return "yes" end
    return "no"
end

local function closeLog()
    if handle then
        pcall(function() handle:close() end)
        handle = nil
    end
    openPath = ""
    openMode = ""
end

local function openLog()
    closeLog()
    local path = resolvePath()

    -- 1. append, which is what this wants
    local fh = tryOpen(path, "a")
    local mode = "append"

    -- 2. same again without the directory, in case relative subdirectories
    --    are not created for us
    if not fh and path:find("/", 1, true) then
        local flat = path:gsub("/", "-")
        fh = tryOpen(flat, "a")
        if fh then
            path = flat
            mode = "append (flattened, no subdirectory)"
        end
    end

    -- 3. no append: carry the existing file forward by hand, once, then hold
    --    the handle open for the rest of the session. Truncating on open is
    --    only safe because this happens once.
    if not fh then
        local prior = ""
        local rd = tryOpen(path, "r")
        if rd then
            local ok, body = pcall(function() return rd:read("*a") end)
            if ok and type(body) == "string" then prior = body end
            pcall(function() rd:close() end)
        end

        fh = tryOpen(path, "w")
        mode = "rewrite (no append mode)"
        if fh and prior ~= "" then
            pcall(function() fh:write(prior) end)
        end
    end

    if not fh then
        lastError = "could not open " .. path
        return false
    end

    handle = fh
    openPath = path
    openMode = mode

    -- Once per session, and only after something opened: a plugin that says it
    -- is writing to a path it cannot reach is worse than one that refuses.
    if realFs == "unknown" then
        realFs = probeRealFs()
        if realFs == "no" then
            -- Refuse, do not fall back.
            --
            -- Without the permission a write goes to a pseudo-file in the world
            -- storage, and appending to one of those REWRITES THE WHOLE FILE
            -- through the storage engine. A session's transcript therefore gets
            -- written again, in full, on every flush. Left alone for a day that
            -- took one IndexedDB store to 575 MB holding 2,646 copies of the
            -- same growing log.
            --
            -- Quietly writing somewhere useless would be bad enough. Quietly
            -- writing somewhere useless AND quadratic is not a fallback.
            closeLog()
            enabled = false
            lastError = "no filesystem access"
            echo(TAG .. "File System Access is OFF, so logging is off.", "#ff6666")
            echo(TAG .. "Without it every append rewrites the whole transcript into", "#ffb02e")
            echo(TAG .. "the world storage, which grows without bound.", "#ffb02e")
            echo(TAG .. "Turn it on in this plugin's settings, Permissions tab, then 'mudlog on'.", "#ffb02e")
            return false
        end
    end

    pcall(function()
        handle:write("\n-- transcript opened " .. os.date("%Y-%m-%d %H:%M:%S") .. " --\n")
    end)
    return true
end

local function flush()
    if queued == 0 then return end
    if not handle and not openLog() then
        -- nowhere to put them; drop rather than grow without bound
        dropped = dropped + queued
        queue = {}
        queued = 0
        return
    end

    local blob = table.concat(queue, "\n") .. "\n"
    queue = {}
    queued = 0

    local ok, err = pcall(function() handle:write(blob) end)
    if not ok then
        lastError = tostring(err)
        closeLog()
        return
    end
    written = written + 1
end

local function put(line)
    if not enabled then return end

    local text = tostring(line or "")
    if stripColour then text = stripAnsi(text) end
    if stampLines then text = os.date("[%H:%M:%S] ") .. text end

    queued = queued + 1
    queue[queued] = text
    if queued >= FLUSH_LINES then flush() end
end

----------------------------------------------------------------------
-- config panel
----------------------------------------------------------------------

local widget = nil

local function saveSettings()
    setVariable("folder", folder)
    setVariable("namePattern", namePattern)
    setVariable("enabled", enabled and "yes" or "no")
    setVariable("stripColour", stripColour and "yes" or "no")
    setVariable("stampLines", stampLines and "yes" or "no")
end

-- Opening a folder in the system file manager is not in the API guide, and
-- hyperlink() only accepts http(s), ftp, send: and prompt: -- file:// is
-- refused, so that route is closed. The client is Tauri and its opener plugin
-- does expose reveal_item_in_dir natively; whether any of it reaches a Lua
-- plugin is another question, so the likely names are tried and the answer is
-- reported rather than assumed. 'mudlog api' lists what this build actually has.
local OPENERS = {
    "openFolder", "openPath", "revealItem", "revealItemInDir",
    "openInFileManager", "shellOpen", "openExternal", "openUrl",
}

local function openFolder()
    local target = absoluteFolder()
    for _, name in ipairs(OPENERS) do
        local fn = callable(name)
        if fn then
            local ok = pcall(fn, target)
            if ok then return name end
        end
    end
    return nil
end

local function esc(s)
    local out = tostring(s or "")
    out = out:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
    return out
end

local function configHtml()
    local onCls = ""
    if enabled then onCls = " on" end
    local colCls = ""
    if stripColour then colCls = " on" end
    local stampCls = ""
    if stampLines then stampCls = " on" end

    local state = "not opened yet"
    if openPath ~= "" then state = openPath .. "  (" .. openMode .. ")" end

    return "<style>"
        .. ".ml{height:100%;box-sizing:border-box;padding:10px;overflow:auto;"
        .. "background:#0f1115;color:#d7d3c8;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;"
        .. "font-size:11px;line-height:1.5;}"
        .. ".ml h4{margin:0 0 8px;font-size:9px;letter-spacing:0.18em;text-transform:uppercase;"
        .. "color:#7fb2ff;border-bottom:1px solid rgba(127,178,255,0.25);padding-bottom:4px;}"
        .. ".ml label{display:block;margin:9px 0 3px;font-size:9px;letter-spacing:0.12em;"
        .. "text-transform:uppercase;color:#8a8272;}"
        .. ".ml input{width:100%;box-sizing:border-box;padding:4px 6px;border-radius:3px;"
        .. "border:1px solid #2c3340;background:#171b22;color:#d7d3c8;font:inherit;}"
        .. ".ml .tb{display:inline-block;font-size:9px;letter-spacing:0.1em;text-transform:uppercase;"
        .. "padding:3px 7px;margin:6px 4px 0 0;border-radius:2px;border:1px solid #4a5568;"
        .. "color:#8a8272;cursor:pointer;user-select:none;}"
        .. ".ml .tb:hover{color:#d7d3c8;border-color:#7fb2ff;}"
        .. ".ml .tb.on{color:#7fb2ff;border-color:#7fb2ff;background:rgba(127,178,255,0.12);}"
        .. ".ml .note{margin-top:8px;font-size:9px;color:#6f7787;word-break:break-all;}"
        .. ".ml .note b{color:#d7d3c8;font-weight:600;}"
        .. "</style>"

        .. '<div class="ml"><h4>Transcript</h4>'
        .. '<form data-mud-action="save">'
        .. "<label>Folder</label>"
        .. '<input type="text" name="folder" value="' .. esc(folder) .. '">'
        .. "<label>Filename</label>"
        .. '<input type="text" name="name" value="' .. esc(namePattern) .. '">'
        .. '<div class="tb on" data-mud-action="save">save</div>'
        .. "</form>"

        .. '<div class="tb' .. onCls .. '" data-mud-action="toggle">logging</div>'
        .. '<div class="tb' .. colCls .. '" data-mud-action="colour">strip colour</div>'
        .. '<div class="tb' .. stampCls .. '" data-mud-action="stamp">timestamps</div>'
        .. '<div class="tb" data-mud-action="open">open folder</div>'
        .. '<div class="tb" data-mud-action="close">hide</div>'

        .. '<div class="note">{date} {time} {world} {char}<br><br>'
        .. "writing to <b>" .. esc(state) .. "</b><br>"
        .. "under <b>" .. esc(absoluteFolder()) .. "</b><br><br>"
        .. "needs File System Access on for this plugin, or nothing reaches disk"
        .. "</div></div>"
end

local function renderConfig()
    if not widget then return end
    setWidgetProperty(widget, "content", configHtml())
end

local function makeWidget()
    widget = createWidget({
        type     = "html",
        name     = "mudlog-config",
        title    = "Transcript",
        position = { x = 140, y = 140 },
        size     = { width = 300, height = 380 },
        scrollable = true,
    })

    -- registerWidgetEvent appends, so a reload would stack a second handler
    pcall(function() unregisterWidgetEvent(widget, "action") end)
    registerWidgetEvent(widget, "action", function(data)
        if type(data) ~= "table" then return end
        local act = tostring(data.action or "")

        if act == "save" then
            local f = data.formData
            if type(f) == "table" then
                if type(f.folder) == "string" then folder = trimSlashes(f.folder) end
                if type(f.name) == "string" and f.name ~= "" then namePattern = f.name end
            end
            saveSettings()
            flush()
            closeLog()          -- the next line opens at the new path
            echo(TAG .. "now writing to " .. resolvePath(), "#7fb2ff")

        elseif act == "toggle" then
            enabled = not enabled
            if not enabled then flush() end
            saveSettings()

        elseif act == "colour" then
            flush()
            stripColour = not stripColour
            saveSettings()

        elseif act == "stamp" then
            stampLines = not stampLines
            saveSettings()

        elseif act == "open" then
            local via = openFolder()
            if via then
                echo(TAG .. "opened " .. absoluteFolder() .. " via " .. via, "#7fb2ff")
            else
                echo(TAG .. "this build exposes no way to open a folder.", "#ff6666")
                echo(TAG .. "it is at: " .. absoluteFolder(), "#7fb2ff")
            end

        elseif act == "close" then
            hideWidget(widget)
            return
        end
        renderConfig()
    end)

    renderConfig()
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

function init()
    local fd = getVariable("folder")
    if type(fd) == "string" then folder = trimSlashes(fd) end
    local np = getVariable("namePattern")
    if type(np) == "string" and np ~= "" then namePattern = np end
    if getVariable("enabled") == "no" then enabled = false end
    if getVariable("stripColour") == "no" then stripColour = false end
    if getVariable("stampLines") == "yes" then stampLines = true end
    local cp = getVariable("cmdPrefix")
    if type(cp) == "string" then cmdPrefix = cp end

    setVariable("instance", INSTANCE)
    makeWidget()

    tickTimer = addTimer(2000, function()
        if getVariable("instance") ~= INSTANCE then
            if tickTimer then removeTimer(tickTimer) end
            return
        end
        local ok, err = pcall(flush)
        if not ok then lastError = tostring(err) end
    end, true)

    registerCommand("mudlog", function(args)
        local cmd = tostring(args or "")
        local low = cmd:lower()

        if low == "on" or low == "off" then
            enabled = (low == "on")
            saveSettings()
            if not enabled then flush() end
            renderConfig()
            echo(TAG .. "logging " .. low .. ".", "#ffb02e")

        elseif low == "flush" then
            flush()
            echo(TAG .. "flushed to " .. (openPath ~= "" and openPath or "nowhere"), "#ffb02e")

        elseif low == "config" then
            showWidget(widget)
            renderConfig()

        elseif low:sub(1, 7) == "folder " then
            folder = trimSlashes(cmd:sub(8))
            saveSettings()
            flush()
            closeLog()
            echo(TAG .. "next line opens " .. resolvePath(), "#ffb02e")
            renderConfig()

        elseif low:sub(1, 5) == "name " then
            namePattern = cmd:sub(6)
            if namePattern == "" then namePattern = DEFAULT_NAME end
            saveSettings()
            flush()
            closeLog()
            echo(TAG .. "next line opens " .. resolvePath(), "#ffb02e")
            renderConfig()

        elseif low == "open" then
            local via = openFolder()
            if via then
                echo(TAG .. "opened via " .. via, "#ffb02e")
            else
                echo(TAG .. "no folder opener in this build; it is at:", "#ff6666")
                echo(TAG .. "" .. absoluteFolder(), "#ffb02e")
            end

        elseif low == "api" then
            -- what this build actually exposes, rather than what is documented
            local ok, names = pcall(function()
                local found = {}
                for k, v in pairs(_G) do
                    local key = tostring(k)
                    if type(v) == "function" and key:lower():find("open")
                        or type(v) == "function" and key:lower():find("reveal")
                        or type(v) == "function" and key:lower():find("shell") then
                        found[#found + 1] = key
                    end
                end
                table.sort(found)
                return found
            end)
            if ok and type(names) == "table" then
                print(TAG .. "" .. #names .. " opener-ish global(s):")
                for _, n in ipairs(names) do print("  " .. n) end
            else
                print(TAG .. "_G is not enumerable here")
            end

        elseif low == "colour" or low == "color" then
            flush()
            stripColour = not stripColour
            saveSettings()
            if stripColour then echo(TAG .. "escape codes stripped.", "#ffb02e")
            else echo(TAG .. "escape codes kept.", "#ffb02e") end

        elseif low == "stamp" then
            stampLines = not stampLines
            saveSettings()
            echo(TAG .. "per-line timestamps " .. tostring(stampLines), "#ffb02e")

        elseif low == "purge" then
            -- The pseudo-file copies live in the world storage and the client
            -- is the only thing that can remove them properly.
            local fn = callable("deletePluginFile")
            if not fn then
                echo(TAG .. "this build exposes no deletePluginFile.", "#ff6666")
                return
            end
            closeLog()
            local path = resolvePath()
            local ok = pcall(fn, path)
            local ok2 = pcall(fn, (path:gsub("/", "-")))
            if ok or ok2 then
                echo(TAG .. "dropped the stored copy of " .. path .. ".", "#ffb02e")
                echo(TAG .. "Storage will not shrink on disk until the client compacts it.", "#ffb02e")
            else
                echo(TAG .. "could not drop it.", "#ff6666")
            end

        elseif low == "status" then
            print(TAG .. "enabled=" .. tostring(enabled))
            print(TAG .. "folder=" .. folder .. "  name=" .. namePattern)
            print(TAG .. "resolves to=" .. resolvePath())
            if openPath ~= "" then
                print(TAG .. "open=" .. openPath .. "  mode=" .. openMode)
            else
                print(TAG .. "not open yet (opens on the first line)")
            end
            print(TAG .. "queued=" .. queued .. " flushes=" .. written
                .. " dropped=" .. dropped)
            print(TAG .. "stripColour=" .. tostring(stripColour)
                .. " stamp=" .. tostring(stampLines))
            print(TAG .. "lastError=" .. lastError)
            print(TAG .. "realFilesystem=" .. realFs)
            -- The old guard here was 'openMode == ""', which never fired: with
            -- the permission off the open still succeeds against a pseudo-file,
            -- so the one case that needed the hint was the one case that
            -- reported everything as fine.
            if realFs == "no" then
                print(TAG .. "nothing is reaching your disk. Turn on File System")
                print(TAG .. "Access in this plugin's settings, Permissions tab.")
            elseif realFs == "unknown" then
                print(TAG .. "not probed yet; it runs when the file first opens.")
            end

        else
            echo(TAG .. "mudlog config | on | off | flush | status", "#ffb02e")
            echo("            mudlog folder <dir>     where the files go", "#ffb02e")
            echo("            mudlog name <pattern>   {date} {time} {world} {char}", "#ffb02e")
            echo("            mudlog open             folder in your file manager", "#ffb02e")
            echo("            mudlog colour           keep or strip escape codes", "#ffb02e")
            echo("            mudlog stamp            per-line timestamps", "#ffb02e")
            echo("            mudlog purge            drop transcripts left in world storage", "#ffb02e")
        end
    end, "Plain-text session transcript")
end

-- Every line the MUD sends. Returning nil leaves the terminal untouched: this
-- plugin only ever reads.
function onLine(sessionId, rawLine, cleanLine)
    local ok, err = pcall(function()
        if stripColour then put(cleanLine) else put(rawLine) end
    end)
    if not ok then lastError = tostring(err) end
    return nil
end

-- What you typed, before aliases rewrite it, so the transcript reads back the
-- way the session actually happened.
function onCommand(sessionId, command)
    local ok, err = pcall(function() put(cmdPrefix .. tostring(command or "")) end)
    if not ok then lastError = tostring(err) end
    return nil
end

function onConnect(sessionId)
    -- the world name is part of the path, and it is not knowable until now
    flush()
    closeLog()
    put("-- connected " .. os.date("%Y-%m-%d %H:%M:%S") .. " --")
end

function onDisconnect(sessionId)
    put("-- disconnected " .. os.date("%Y-%m-%d %H:%M:%S") .. " --")
    flush()
    closeLog()
end

function cleanup()
    flush()
    closeLog()
end
