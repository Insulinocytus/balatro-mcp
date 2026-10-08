package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    "./tests/?.lua",
    "./tests/vendor/?.lua",
    package.path,
}, ";")

local JSON = require("src.json")

local FakeBalatroAdapter = require("fake_balatro_adapter")
local ToolCatalog = require("src.tool_catalog")

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local content = assert(file:read("*a"))
    file:close()
    return content
end

if os.getenv("BALATRO_MCP_TEST_SERVER_PORT") then
    local GameMcpServer = require("src.game_mcp_server")
    local adapter = FakeBalatroAdapter.new({
        states = {
            {
                run_id = "conformance",
                decision_sequence = 1,
                phase = "main_menu",
                public_state = {
                    game_version = "1.0.1o-FULL",
                    steamodded_version = "1.0.0~BETA-2014b",
                    lovely_version = "0.9.0",
                    compatibility = { status = "supported" },
                    active_mods = {
                        { id = "balatro-mcp", name = "Balatro MCP", version = "0.1.0" },
                    },
                    legal_actions = {},
                    available_decks = {},
                    available_stakes = {},
                },
            },
        },
    })
    local server = GameMcpServer.new({
        json = JSON,
        adapter = adapter,
        tool_catalog = ToolCatalog,
        port = assert(tonumber(os.getenv("BALATRO_MCP_TEST_SERVER_PORT"))),
        worker_source = read_file("src/http_worker.lua"),
        server_info = {
            name = "balatro-mcp",
            title = "Balatro MCP",
            version = "0.1.0",
            description = "Expose Balatro decision states and semantic actions through MCP.",
        },
    })

    function love.load()
        assert(server:start())
    end

    function love.update()
        server:poll()
        local status = server:get_status()
        if status.state == "error" then
            error(status.error)
        end
    end

    function love.quit()
        server:stop()
    end
else
    function love.load(arguments)
        arg = { [0] = "balatro-mcp-tests" }
        local luaunit = require("luaunit")
        require("game_mcp_server_test")
        require("mod_entry_test")
        local failures = luaunit.LuaUnit.run(unpack(arguments))
        love.event.quit(failures == 0 and 0 or 1)
    end
end
