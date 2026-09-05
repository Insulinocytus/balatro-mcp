local luaunit = require("luaunit")

local globals_to_restore = {
    "G",
    "Game",
    "SMODS",
    "sendErrorMessage",
    "sendInfoMessage",
    "sendDebugMessage",
}

TestModEntry = {}

function TestModEntry:setUp()
    self.saved_love_get_version = love.getVersion
    self.saved_globals = {}
    for _, name in ipairs(globals_to_restore) do
        self.saved_globals[name] = rawget(_G, name)
    end

    self.mod = {
        config = {
            port = 18790,
            request_timeout_ms = 30000,
            max_header_bytes = 16384,
            max_body_bytes = 1048576,
            visibility = "fair",
        },
        path = "./",
        version = "0.1.0",
        minimum_love_version = "11.5",
    }
    self.server_status = { state = "starting", port = 18790 }
    self.server_options = nil
    self.module_paths = {}
    self.fake_adapter = {}
    self.fake_tool_catalog = {}
    self.logged_error = nil
    self.logged_info = nil
    self.logged_debug = nil
    self.poll_count = 0
    self.previous_update_count = 0
    local test = self

    _G.G = {
        UIT = { ROOT = "root", R = "row", T = "text" },
        C = { CLEAR = {}, RED = {}, UI = { TEXT_LIGHT = {} } },
        FUNCS = {},
    }
    _G.Game = {
        update = function(_, dt)
            test.previous_update_count = test.previous_update_count + 1
            return dt
        end,
    }
    _G.sendErrorMessage = function(message, _tag)
        test.logged_error = message
    end
    _G.sendInfoMessage = function(message, _tag)
        test.logged_info = message
    end
    _G.sendDebugMessage = function(message, _tag)
        test.logged_debug = message
    end
    _G.SMODS = {
        current_mod = self.mod,
        GUI = {
            createOptionSelector = function(args)
                return { n = "selector", config = args }
            end,
        },
        NFS = {
            read = function(path)
                test.worker_path = path
                return "worker source"
            end,
        },
        load_file = function(path)
            test.module_paths[#test.module_paths + 1] = path
            return function()
                if path == "src/balatro_adapter.lua" then
                    return {
                        new = function()
                            return test.fake_adapter
                        end,
                    }
                end
                if path == "src/tool_catalog.lua" then
                    return test.fake_tool_catalog
                end
                return {
                    new = function(options)
                        test.server_options = options
                        return {
                            start = function()
                                test.server_status = { state = "listening", port = options.port }
                                return true
                            end,
                            set_visibility = function(_, visibility)
                                test.server_visibility = visibility
                            end,
                            poll = function()
                                test.poll_count = test.poll_count + 1
                            end,
                            get_status = function()
                                return test.server_status
                            end,
                        }
                    end,
                }
            end
        end,
    }
end

function TestModEntry:tearDown()
    rawset(love, "getVersion", self.saved_love_get_version)
    for _, name in ipairs(globals_to_restore) do
        rawset(_G, name, self.saved_globals[name])
    end
end

local function find_selector(tab, label)
    for _, node in ipairs(tab.nodes) do
        if node.n == "selector" and node.config.label == label then
            return node
        end
    end
end

local function tab_has_text(tab, needle)
    local function walk(node)
        if type(node) ~= "table" then
            return false
        end
        if
            node.config
            and type(node.config.text) == "string"
            and node.config.text:find(needle, 1, true)
        then
            return true
        end
        for _, child in ipairs(node.nodes or {}) do
            if walk(child) then
                return true
            end
        end
        return false
    end
    return walk(tab)
end

function TestModEntry:test_entry_assembles_server_and_preserves_game_update_chain()
    assert(loadfile("main.lua"))()

    luaunit.assertEquals(self.worker_path, "./src/http_worker.lua")
    luaunit.assertEquals(self.module_paths, {
        "src/game_mcp_server.lua",
        "src/balatro_adapter.lua",
        "src/tool_catalog.lua",
    })
    luaunit.assertEquals(self.server_options.port, 18790)
    luaunit.assertEquals(self.server_options.visibility, "fair")
    luaunit.assertIs(self.server_options.adapter, self.fake_adapter)
    luaunit.assertIs(self.server_options.tool_catalog, self.fake_tool_catalog)
    luaunit.assertTrue(self.server_options.log_enabled("error"))
    luaunit.assertTrue(self.server_options.log_enabled("info"))
    luaunit.assertFalse(self.server_options.log_enabled("debug"))
    luaunit.assertEquals(Game:update(0.25), 0.25)
    luaunit.assertEquals(self.previous_update_count, 1)
    luaunit.assertEquals(self.poll_count, 1)
    luaunit.assertStrContains(self.logged_info, "server.ready")
    luaunit.assertStrContains(self.logged_info, "Listening on http://127.0.0.1:18790/mcp")

    local tab = self.mod.config_tab()
    luaunit.assertEquals(tab.nodes[1].nodes[1].config.text, "Port: 18790")
    luaunit.assertEquals(tab.nodes[2].nodes[1].config.text, "Status: listening")
    luaunit.assertEquals(self.mod.debug_info.Status, "listening")
end

function TestModEntry:test_lovely_logger_failure_does_not_break_game_update()
    sendInfoMessage = function()
        error("logger unavailable")
    end
    assert(loadfile("main.lua"))()

    luaunit.assertEquals(Game:update(0.25), 0.25)
    luaunit.assertEquals(self.previous_update_count, 1)
    luaunit.assertEquals(self.poll_count, 1)
end

function TestModEntry:test_old_love_version_keeps_discovery_and_reports_incompatibility()
    rawset(love, "getVersion", function()
        return 11, 4, 0
    end)

    assert(loadfile("main.lua"))()

    luaunit.assertNotNil(self.server_options)
    luaunit.assertNil(self.logged_error)
    luaunit.assertEquals(Game:update(0.5), 0.5)
    luaunit.assertEquals(self.previous_update_count, 1)
    local tab = self.mod.config_tab()
    luaunit.assertStrContains(tab.nodes[3].nodes[1].config.text, "Compatibility: unsupported")
end

function TestModEntry:test_invalid_port_disables_mcp_without_breaking_game_update()
    self.mod.config.port = 70000
    SMODS.NFS.read = function()
        error("worker must not load for invalid config")
    end

    assert(loadfile("main.lua"))()

    luaunit.assertStrContains(self.logged_error, "1 to 65535")
    luaunit.assertEquals(Game:update(0.5), 0.5)
    luaunit.assertEquals(self.previous_update_count, 1)
    local tab = self.mod.config_tab()
    luaunit.assertEquals(tab.nodes[2].nodes[1].config.text, "Status: error")
    luaunit.assertStrContains(tab.nodes[4].nodes[1].config.text, "Last startup error")
end

function TestModEntry:test_log_level_off_silences_listening_and_startup_errors()
    self.mod.config.log_level = "off"
    assert(loadfile("main.lua"))()
    luaunit.assertEquals(Game:update(0.25), 0.25)
    luaunit.assertNil(self.logged_info)
    luaunit.assertNil(self.logged_error)

    self.mod.config.port = 70000
    self.mod.config.log_level = "off"
    SMODS.NFS.read = function()
        error("worker must not load for invalid config")
    end
    assert(loadfile("main.lua"))()
    luaunit.assertNil(self.logged_error)
    local tab = self.mod.config_tab()
    luaunit.assertEquals(tab.nodes[2].nodes[1].config.text, "Status: error")
end

function TestModEntry:test_invalid_log_level_defaults_to_info_and_still_starts()
    self.mod.config.log_level = "verbose"
    assert(loadfile("main.lua"))()
    luaunit.assertNotNil(self.server_options)
    luaunit.assertEquals(Game:update(0.25), 0.25)
    luaunit.assertStrContains(self.logged_info, "127.0.0.1:18790/mcp")
end

function TestModEntry:test_invalid_visibility_defaults_to_fair_and_still_starts()
    self.mod.config.visibility = "xray"
    assert(loadfile("main.lua"))()
    luaunit.assertEquals(self.server_options.visibility, "fair")
    local selector = find_selector(self.mod.config_tab(), "Visibility")
    luaunit.assertEquals(selector.config.current_option, "fair")
    luaunit.assertFalse(
        tab_has_text(self.mod.config_tab(), "Omniscient Debug Mode exposes hidden information")
    )
end

function TestModEntry:test_config_tab_changes_log_level_immediately()
    assert(loadfile("main.lua"))()
    luaunit.assertEquals(Game:update(0.25), 0.25)
    luaunit.assertStrContains(self.logged_info, "127.0.0.1:18790/mcp")

    local tab = self.mod.config_tab()
    local selector = find_selector(tab, "Log level")
    luaunit.assertEquals(selector.n, "selector")
    luaunit.assertEquals(selector.config.current_option, "info")
    luaunit.assertEquals(selector.config.options, { "off", "error", "info", "debug" })

    G.FUNCS.balatro_mcp_set_log_level({ to_val = "debug" })
    luaunit.assertTrue(self.server_options.log_enabled("debug"))
    G.FUNCS.balatro_mcp_set_log_level({ to_val = "off" })
    luaunit.assertEquals(self.mod.config.log_level, "off")
    luaunit.assertFalse(self.server_options.log_enabled("error"))
    self.logged_error = nil
    self.server_status = { state = "error", port = 18790, error = "boom" }
    Game:update(0.1)
    luaunit.assertNil(self.logged_error)
end

function TestModEntry:test_default_visibility_is_fair_and_persisted_on_mod_config()
    local defaults = assert(loadfile("config.lua"))()
    luaunit.assertEquals(defaults.visibility, "fair")

    assert(loadfile("main.lua"))()
    local tab = self.mod.config_tab()
    local selector = find_selector(tab, "Visibility")
    luaunit.assertEquals(selector.config.options, { "fair", "omniscient" })
    luaunit.assertEquals(selector.config.current_option, "fair")
    luaunit.assertEquals(selector.config.info, {
        "Omniscient Debug Mode exposes hidden information. Do not use it for fair play.",
    })
    luaunit.assertFalse(tab_has_text(tab, "Omniscient Debug Mode exposes hidden information"))
    luaunit.assertEquals(self.server_options.visibility, "fair")
end

function TestModEntry:test_config_tab_switches_visibility_immediately_and_keeps_selector_warning()
    assert(loadfile("main.lua"))()
    luaunit.assertEquals(self.server_options.visibility, "fair")

    G.FUNCS.balatro_mcp_set_visibility({ to_val = "omniscient" })
    luaunit.assertEquals(self.mod.config.visibility, "omniscient")
    luaunit.assertEquals(self.server_visibility, "omniscient")

    local tab = self.mod.config_tab()
    local selector = find_selector(tab, "Visibility")
    luaunit.assertEquals(selector.config.current_option, "omniscient")
    luaunit.assertEquals(selector.config.info, {
        "Omniscient Debug Mode exposes hidden information. Do not use it for fair play.",
    })
    luaunit.assertFalse(tab_has_text(tab, "Omniscient Debug Mode exposes hidden information"))

    G.FUNCS.balatro_mcp_set_visibility({ to_val = "fair" })
    luaunit.assertEquals(self.mod.config.visibility, "fair")
    luaunit.assertEquals(self.server_visibility, "fair")
    luaunit.assertFalse(
        tab_has_text(self.mod.config_tab(), "Omniscient Debug Mode exposes hidden information")
    )
end
