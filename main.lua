local mod = SMODS.current_mod
---@type BalatroMcpConfig
local config = mod.config
local server
local last_logged_state
local startup_status = { state = "disabled", port = config.port }
local debug_info = { Port = tostring(config.port), Status = startup_status.state }

local log_rank = { off = 0, error = 1, info = 2, debug = 3 }

local function current_log_rank()
    return log_rank[config.log_level] or log_rank.info
end

local function log_enabled(level)
    local rank = log_rank[level]
    return rank ~= nil and rank > 0 and rank <= current_log_rank()
end

local function log_at(level, message)
    if not log_enabled(level) then
        return
    end
    local send = level == "error" and sendErrorMessage
        or level == "debug" and sendDebugMessage
        or sendInfoMessage
    if send then
        pcall(send, message, "Balatro MCP")
    else
        pcall(print, "[Balatro MCP] " .. message)
    end
end

local function log_error(message)
    log_at("error", message)
end

local function log_info(message)
    log_at("info", message)
end

local function set_startup_error(message)
    startup_status = { state = "error", port = config.port, error = tostring(message) }
    debug_info.Status = startup_status.state
    debug_info.Error = startup_status.error
    log_error(startup_status.error)
end

local function parse_version(str)
    local major, minor, patch, rev = tostring(str or ""):match("^(%d+)%.(%d+)%.?(%d*)(.*)$")
    major = tonumber(major)
    if not major then
        return nil
    end
    return {
        major = major,
        minor = tonumber(minor) or 0,
        patch = tonumber(patch) or 0,
        beta = rev:sub(1, 1) == "~" and -1 or 0,
        rev = rev,
    }
end

local function version_at_least(actual, minimum)
    local found, required = parse_version(actual), parse_version(minimum)
    if not found or not required then
        return true
    end
    if found.major ~= required.major then
        return found.major > required.major
    end
    if found.minor ~= required.minor then
        return found.minor > required.minor
    end
    if found.patch ~= required.patch then
        return found.patch > required.patch
    end
    if found.beta ~= required.beta then
        return found.beta > required.beta
    end
    return found.rev >= required.rev
end

local love_major, love_minor, love_revision = love.getVersion()
local required_love_version = tostring(mod.minimum_love_version or "")
local compatibility_issues = {}
if not parse_version(required_love_version) then
    compatibility_issues[1] = "Invalid minimum_love_version in Mod metadata"
else
    local love_version = string.format("%d.%d.%d", love_major, love_minor, love_revision or 0)
    if not version_at_least(love_version, required_love_version) then
        compatibility_issues[#compatibility_issues + 1] = ("LÖVE %s is below %s"):format(
            love_version,
            required_love_version
        )
    end
end
if G and G.VERSION and not version_at_least(G.VERSION, "1.0.1o-FULL") then
    compatibility_issues[#compatibility_issues + 1] = ("Balatro %s is below 1.0.1o-FULL"):format(
        G.VERSION
    )
end
if SMODS.version and not version_at_least(SMODS.version, "1.0.0~BETA-2014b") then
    compatibility_issues[#compatibility_issues + 1] = ("Steamodded %s is below 1.0.0~BETA-2014b"):format(
        SMODS.version
    )
end
local lovely_ok, lovely = pcall(require, "lovely")
local lovely_version = lovely_ok and type(lovely) == "table" and lovely.version or nil
if lovely_version and not version_at_least(lovely_version, "0.7.1") then
    compatibility_issues[#compatibility_issues + 1] = ("Lovely %s is below 0.7.1"):format(
        lovely_version
    )
end

local compatibility_error = compatibility_issues[1]
        and compatibility_issues[1]:find("Invalid", 1, true)
        and compatibility_issues[1]
    or nil
debug_info.Compatibility = #compatibility_issues == 0 and "supported"
    or ("unsupported (%s)"):format(table.concat(compatibility_issues, "; "))

local port = tonumber(config.port)
if compatibility_error then
    set_startup_error(compatibility_error)
elseif not port or port % 1 ~= 0 or port < 1 or port > 65535 then
    set_startup_error("Configured port must be an integer from 1 to 65535")
else
    local path_separator = mod.path:match("[/\\]$") and "" or "/"
    local worker_source, read_error =
        SMODS.NFS.read(mod.path .. path_separator .. "src/http_worker.lua")
    if not worker_source then
        set_startup_error("Could not load HTTP worker: " .. tostring(read_error))
    else
        local ok, server_or_error = pcall(function()
            local Server = assert(SMODS.load_file("src/game_mcp_server.lua"))()
            local Adapter = assert(SMODS.load_file("src/balatro_adapter.lua"))()
            local ToolCatalog = assert(SMODS.load_file("src/tool_catalog.lua"))()
            return Server.new({
                json = JSON,
                port = port,
                worker_source = worker_source,
                adapter = Adapter.new(),
                tool_catalog = ToolCatalog,
                visibility = config.visibility == "omniscient" and "omniscient" or "fair",
                request_timeout_ms = config.request_timeout_ms,
                max_header_bytes = config.max_header_bytes,
                max_body_bytes = config.max_body_bytes,
                log = log_at,
                log_enabled = log_enabled,
                server_info = {
                    name = "balatro-mcp",
                    title = "Balatro MCP",
                    version = mod.version,
                    description = "Expose Balatro decision states and semantic actions through MCP.",
                },
            })
        end)
        if not ok then
            set_startup_error("Could not load MCP server: " .. tostring(server_or_error))
        else
            server = server_or_error
            if not server:start() then
                set_startup_error(server:get_status().error)
            end
        end
    end
end

local function current_status()
    return server and server:get_status() or startup_status
end

local function poll_server()
    if not server then
        return
    end
    server:poll()
    local status = server:get_status()
    debug_info.Status = status.state
    debug_info.Error = status.error
    if status.state ~= last_logged_state then
        last_logged_state = status.state
        if status.state == "listening" then
            local endpoint = "http://127.0.0.1:" .. status.port .. "/mcp"
            log_info(table.concat({
                "server.ready",
                "endpoint=" .. endpoint,
                "game=" .. tostring(G and G.VERSION),
                "log_level=" .. tostring(config.log_level or "info"),
                "lovely=" .. tostring(lovely_version),
                'message="Listening on ' .. endpoint .. '"',
                "server=" .. tostring(mod.version),
                "steamodded=" .. tostring(SMODS.version),
                "visibility=" .. tostring(config.visibility or "fair"),
            }, " "))
        elseif status.state == "error" then
            log_error(status.error or "MCP server failed")
        end
    end
end

local previous_update = Game.update
function Game:update(dt)
    local result = previous_update(self, dt)
    poll_server()
    return result
end

local function text_row(text, colour)
    return {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.05 },
        nodes = {
            {
                n = G.UIT.T,
                config = {
                    text = text,
                    scale = 0.35,
                    colour = colour or G.C.UI.TEXT_LIGHT,
                },
            },
        },
    }
end

G.FUNCS = G.FUNCS or {}
function G.FUNCS.balatro_mcp_set_log_level(e)
    local level = e and e.to_val
    if log_rank[level] then
        config.log_level = level
    end
end

function G.FUNCS.balatro_mcp_set_visibility(e)
    local visibility = e and e.to_val
    if visibility ~= "fair" and visibility ~= "omniscient" then
        return
    end
    config.visibility = visibility
    if server then
        server:set_visibility(visibility)
    end
end

function mod.config_tab()
    local status = current_status()
    local nodes = {
        text_row("Port: " .. tostring(config.port)),
        text_row("Status: " .. tostring(status.state)),
        text_row("Compatibility: " .. tostring(debug_info.Compatibility)),
    }
    if status.error then
        local first_line = tostring(status.error):match("^[^\r\n]+")
        nodes[#nodes + 1] = text_row("Last startup error: " .. first_line, G.C.RED)
    end
    local visibility = config.visibility == "omniscient" and "omniscient" or "fair"
    nodes[#nodes + 1] = SMODS.GUI.createOptionSelector({
        label = "Visibility",
        options = { "fair", "omniscient" },
        current_option = visibility,
        opt_callback = "balatro_mcp_set_visibility",
        info = {
            "Omniscient Debug Mode exposes hidden information. Do not use it for fair play.",
        },
    })
    local level = log_rank[config.log_level] and config.log_level or "info"
    nodes[#nodes + 1] = SMODS.GUI.createOptionSelector({
        label = "Log level",
        options = { "off", "error", "info", "debug" },
        current_option = level,
        opt_callback = "balatro_mcp_set_log_level",
    })
    return {
        n = G.UIT.ROOT,
        config = { align = "cm", padding = 0.1, colour = G.C.CLEAR },
        nodes = nodes,
    }
end

function mod.calculate(_self, context)
    if server and server.adapter and server.adapter.on_calculate then
        server.adapter:on_calculate(context)
    end
end

mod.debug_info = debug_info
