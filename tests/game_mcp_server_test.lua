local luaunit = require("luaunit")
local socket = require("socket")
local GameMcpServer = require("src.game_mcp_server")
local FakeBalatroAdapter = require("fake_balatro_adapter")
local ToolCatalog = require("src.tool_catalog")
local ProductionBalatroAdapter = require("src.balatro_adapter")
local VanillaConsumablePrototypes = require("vanilla_consumable_prototypes")
local VanillaVoucherBackPrototypes = require("vanilla_voucher_back_prototypes")
local VanillaTagPrototypes = require("vanilla_tag_prototypes")
local VanillaLifecycleJokerPrototypes = require("vanilla_lifecycle_joker_prototypes")
local VanillaBlindPrototypes = require("vanilla_blind_prototypes")

local default_active_mods = {
    { id = "balatro-mcp", name = "Balatro MCP", version = "0.6.1" },
}

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local content = assert(file:read("*a"))
    file:close()
    return content
end

local function wait_until(server, predicate, timeout_seconds)
    local deadline = love.timer.getTime() + timeout_seconds
    repeat
        server:poll()
        if predicate() then
            return
        end
        love.timer.sleep(0.001)
    until love.timer.getTime() >= deadline
    error("timed out waiting for server")
end

local function send_http(server, port, request)
    local client = assert(socket.tcp())
    client:settimeout(1)
    assert(client:connect("127.0.0.1", port))
    assert(client:send(request))
    client:settimeout(0)

    local response = ""
    local deadline = love.timer.getTime() + 4
    while love.timer.getTime() < deadline do
        server:poll()
        local chunk, err, partial = client:receive(4096)
        response = response .. (chunk or partial or "")
        if err == "closed" then
            client:close()
            return response
        end
        if err and err ~= "timeout" then
            error(err)
        end
        love.timer.sleep(0.001)
    end

    client:close()
    error("timed out waiting for HTTP response")
end

local function receive_open_http(server, client, timeout_seconds)
    client:settimeout(0)
    local response = ""
    local deadline = love.timer.getTime() + timeout_seconds
    while love.timer.getTime() < deadline do
        server:poll()
        local chunk, err, partial = client:receive(4096)
        response = response .. (chunk or partial or "")
        if err == "closed" then
            client:close()
            return response
        end
        if err and err ~= "timeout" then
            error(err)
        end
        love.timer.sleep(0.001)
    end
    client:close()
    error("timed out waiting for open HTTP response")
end

local function send_http_concurrently(server, port, requests)
    local clients = {}
    local responses = {}
    for index, request in ipairs(requests) do
        local client = assert(socket.tcp())
        client:settimeout(1)
        assert(client:connect("127.0.0.1", port))
        assert(client:send(request))
        client:settimeout(0)
        clients[index] = client
        responses[index] = ""
    end

    local remaining = #clients
    local deadline = love.timer.getTime() + 3
    while remaining > 0 and love.timer.getTime() < deadline do
        server:poll()
        for index, client in ipairs(clients) do
            if client then
                local chunk, err, partial = client:receive(4096)
                responses[index] = responses[index] .. (chunk or partial or "")
                if err == "closed" then
                    client:close()
                    clients[index] = false
                    remaining = remaining - 1
                elseif err and err ~= "timeout" then
                    error(err)
                end
            end
        end
        love.timer.sleep(0.001)
    end
    if remaining > 0 then
        error("timed out waiting for concurrent HTTP responses")
    end
    return responses
end

local function parse_http(response)
    local header_end = assert(response:find("\r\n\r\n", 1, true))
    local head = response:sub(1, header_end - 1)
    local body = response:sub(header_end + 4)
    local status = assert(tonumber(head:match("^HTTP/1%.1 (%d%d%d)")))
    local headers = {}
    for name, value in head:gmatch("\r\n([^:]+):%s*([^\r\n]+)") do
        headers[name:lower()] = value
    end
    return status, headers, body
end

local function make_request(port, body, overrides)
    overrides = overrides or {}
    local headers = {
        Accept = "application/json, text/event-stream",
        ["Content-Type"] = "application/json",
        ["MCP-Protocol-Version"] = "2026-07-28",
        ["Mcp-Method"] = "server/discover",
        Host = "127.0.0.1:" .. port,
    }
    for name, value in pairs(overrides.headers or {}) do
        headers[name] = value
    end

    local lines = {
        (overrides.method or "POST") .. " " .. (overrides.path or "/mcp") .. " HTTP/1.1",
    }
    for name, value in pairs(headers) do
        if value ~= false then
            lines[#lines + 1] = name .. ": " .. value
        end
    end
    lines[#lines + 1] = "Content-Length: " .. (overrides.content_length or #body)
    lines[#lines + 1] = "Connection: close"
    lines[#lines + 1] = ""
    lines[#lines + 1] = body
    return table.concat(lines, "\r\n")
end

local function rpc_body(id, method, params)
    params = params or {}
    params._meta = {
        ["io.modelcontextprotocol/protocolVersion"] = "2026-07-28",
        ["io.modelcontextprotocol/clientCapabilities"] = {},
    }
    local body = JSON.encode({ jsonrpc = "2.0", id = id, method = method, params = params })
    return body:gsub(
        '"io.modelcontextprotocol/clientCapabilities":%[%]',
        '"io.modelcontextprotocol/clientCapabilities":{}'
    )
end

local function main_menu_observation()
    return {
        run_id = "menu",
        decision_sequence = 1,
        phase = "main_menu",
        public_state = {
            game_version = "1.0.1o-FULL",
            steamodded_version = "1.0.0~BETA-2014b",
            lovely_version = "0.9.0",
            compatibility = { status = "supported", content_mods = "supported" },
            active_mods = default_active_mods,
            available_decks = {
                { key = "b_red", name = "Red Deck", description = "+1 discard every round." },
            },
            available_stakes = {
                { key = "stake_white", level = 1, name = "White Stake" },
            },
            legal_actions = {
                {
                    tool = "start_run",
                    fixed_arguments = { deck_key = "b_red" },
                    arguments = { stake = { minimum = 1, maximum = 1 } },
                },
            },
        },
    }
end

local function run_setup_observation()
    local observation = main_menu_observation()
    observation.phase = "run_setup"
    observation.public_state.selected_deck_key = "b_red"
    observation.public_state.selected_stake_key = "stake_white"
    observation.public_state.has_saved_run = false
    return observation
end

local function blind_selection_observation()
    return {
        run_id = "run-alpha",
        decision_sequence = 7,
        phase = "blind_selection",
        public_state = {
            game_version = "1.0.1o-FULL",
            steamodded_version = "1.0.0~BETA-2014b",
            lovely_version = "0.9.0",
            compatibility = { status = "supported", content_mods = "supported" },
            active_mods = default_active_mods,
            ante = 1,
            money = 4,
            blinds = {
                {
                    target_ref = "small-blind",
                    key = "bl_small",
                    name = "Small Blind",
                    description = "Score at least 300 chips.",
                },
            },
            legal_actions = {
                {
                    tool = "select_blind",
                    target_refs = { blind_id = { "small-blind" } },
                },
            },
        },
        hidden_state = {
            deck_order = { "S_A", "H_K" },
            facedown_cards = { { target_ref = "hidden-card", key = "S_A" } },
        },
        ui = { hovered_target = "small-blind" },
        raw_global = { G = "must not cross the adapter seam" },
        future_prediction = { next_shop = "must not be exposed" },
    }
end

local function hand_observation()
    return {
        run_id = "run-alpha",
        decision_sequence = 8,
        phase = "hand_play",
        public_state = {
            game_version = "1.0.1o-FULL",
            steamodded_version = "1.0.0~BETA-2014b",
            lovely_version = "0.9.0",
            compatibility = { status = "supported", content_mods = "supported" },
            active_mods = default_active_mods,
            ante = 1,
            money = 4,
            current_blind = {
                target_ref = "current-small-blind",
                key = "bl_small",
                name = "Small Blind",
                chips = 300,
            },
            score = 0,
            hands_left = 4,
            discards_left = 3,
            hand = {
                {
                    target_ref = "card-a",
                    key = "S_A",
                    name = "Ace of Spades",
                    description = "",
                    suit = "Spades",
                    rank = "Ace",
                    chips = 11,
                    debuffed = false,
                },
                {
                    target_ref = "card-b",
                    key = "H_K",
                    name = "King of Hearts",
                    description = "",
                    suit = "Hearts",
                    rank = "King",
                    chips = 10,
                    debuffed = false,
                },
                {
                    target_ref = "card-c",
                    key = "D_Q",
                    name = "Queen of Diamonds",
                    description = "",
                    suit = "Diamonds",
                    rank = "Queen",
                    chips = 10,
                    debuffed = false,
                },
            },
            remaining_deck = {
                { key = "C_2", name = "2 of Clubs", count = 1 },
                { key = "S_2", name = "2 of Spades", count = 1 },
            },
            poker_hands = {
                {
                    key = "Pair",
                    name = "Pair",
                    level = 1,
                    chips = 10,
                    mult = 2,
                    played = 0,
                },
            },
            legal_actions = {
                {
                    tool = "play_hand",
                    target_refs = { card_ids = { "card-a", "card-b", "card-c" } },
                    arguments = { card_ids = { min_items = 1, max_items = 2 } },
                },
                {
                    tool = "discard_cards",
                    target_refs = { card_ids = { "card-a", "card-b", "card-c" } },
                    arguments = { card_ids = { min_items = 1, max_items = 3 } },
                },
            },
        },
    }
end

local function owned_items_observation()
    return {
        run_id = "run-alpha",
        decision_sequence = 8,
        phase = "hand_play",
        public_state = {
            game_version = "1.0.1o-FULL",
            steamodded_version = "1.0.0~BETA-2014b",
            lovely_version = "0.9.0",
            compatibility = { status = "supported", content_mods = "supported" },
            active_mods = default_active_mods,
            ante = 1,
            money = 6,
            hands_left = 4,
            discards_left = 3,
            joker_limit = 5,
            consumable_limit = 2,
            hand = {
                {
                    target_ref = "card-a",
                    key = "S_A",
                    name = "Ace of Spades",
                    suit = "Spades",
                    rank = "Ace",
                    chips = 11,
                    facedown = false,
                },
                {
                    target_ref = "card-b",
                    key = "H_K",
                    name = "King of Hearts",
                    suit = "Hearts",
                    rank = "King",
                    chips = 10,
                    facedown = false,
                },
                {
                    target_ref = "card-hidden",
                    facedown = true,
                },
            },
            jokers = {
                {
                    target_ref = "joker-left",
                    key = "j_joker",
                    name = "Joker",
                    description = "+4 Mult",
                    set = "Joker",
                    cost = 2,
                    sell_value = 1,
                    debuffed = false,
                    eternal = false,
                    sellable = true,
                },
                {
                    target_ref = "joker-right",
                    key = "j_greedy_joker",
                    name = "Greedy Joker",
                    description = "Played cards with Diamond suit give +3 Mult when scored",
                    set = "Joker",
                    cost = 5,
                    sell_value = 2,
                    debuffed = false,
                    eternal = false,
                    sellable = true,
                },
            },
            consumables = {
                {
                    target_ref = "planet-pluto",
                    key = "c_pluto",
                    name = "Pluto",
                    description = "Level up High Card",
                    set = "Planet",
                    cost = 3,
                    sell_value = 1,
                    min_targets = 0,
                    max_targets = 0,
                    sellable = true,
                },
                {
                    target_ref = "tarot-strength",
                    key = "c_strength",
                    name = "Strength",
                    description = "Increases rank of up to 2 selected cards by 1",
                    set = "Tarot",
                    cost = 3,
                    sell_value = 1,
                    min_targets = 1,
                    max_targets = 2,
                    sellable = true,
                },
            },
            legal_actions = {
                {
                    tool = "reorder_cards",
                    fixed_arguments = { area = "hand" },
                    target_refs = { ordered_ids = { "card-a", "card-b", "card-hidden" } },
                },
                {
                    tool = "reorder_cards",
                    fixed_arguments = { area = "jokers" },
                    target_refs = { ordered_ids = { "joker-left", "joker-right" } },
                },
                {
                    tool = "use_consumable",
                    fixed_target_refs = { consumable_id = "planet-pluto" },
                },
                {
                    tool = "use_consumable",
                    fixed_target_refs = { consumable_id = "tarot-strength" },
                    target_refs = { target_ids = { "card-a", "card-b", "card-hidden" } },
                    arguments = { target_ids = { min_items = 1, max_items = 2 } },
                },
                {
                    tool = "sell_owned_item",
                    target_refs = {
                        item_id = { "joker-left", "joker-right", "planet-pluto", "tarot-strength" },
                    },
                },
            },
        },
        hidden_state = {
            deck_order = { "C_2", "S_2" },
            facedown_cards = {
                {
                    target_ref = "card-hidden",
                    key = "D_Q",
                    name = "Queen of Diamonds",
                    suit = "Diamonds",
                    rank = "Queen",
                    chips = 10,
                    facedown = true,
                },
            },
        },
    }
end

local function owned_items_after_observation()
    local observation = owned_items_observation()
    observation.decision_sequence = 9
    observation.public_state.money = 7
    observation.public_state.jokers = { observation.public_state.jokers[2] }
    observation.public_state.consumables = { observation.public_state.consumables[1] }
    observation.public_state.hand = {
        observation.public_state.hand[2],
        observation.public_state.hand[1],
        observation.public_state.hand[3],
    }
    observation.public_state.legal_actions = {
        {
            tool = "reorder_cards",
            fixed_arguments = { area = "hand" },
            target_refs = { ordered_ids = { "card-b", "card-a", "card-hidden" } },
        },
        {
            tool = "sell_owned_item",
            target_refs = { item_id = { "joker-right", "planet-pluto" } },
        },
    }
    return observation
end

local function shop_observation()
    return {
        run_id = "run-alpha",
        decision_sequence = 9,
        phase = "shop",
        public_state = {
            game_version = "1.0.1o-FULL",
            steamodded_version = "1.0.0~BETA-2014b",
            lovely_version = "0.9.0",
            compatibility = { status = "supported", content_mods = "supported" },
            active_mods = default_active_mods,
            ante = 1,
            money = 7,
            shop_items = {},
            shop_vouchers = {},
            shop_boosters = {},
            legal_actions = {
                { tool = "leave_shop" },
            },
        },
    }
end

local function shop_catalog_observation()
    return {
        run_id = "run-alpha",
        decision_sequence = 9,
        phase = "shop",
        public_state = {
            game_version = "1.0.1o-FULL",
            steamodded_version = "1.0.0~BETA-2014b",
            lovely_version = "0.9.0",
            compatibility = { status = "supported", content_mods = "supported" },
            active_mods = default_active_mods,
            ante = 1,
            money = 12,
            joker_limit = 5,
            consumable_limit = 2,
            reroll_cost = 5,
            jokers = {
                {
                    target_ref = "owned-joker",
                    key = "j_joker",
                    name = "Joker",
                    sellable = true,
                    sell_value = 1,
                },
            },
            consumables = {},
            hand = {
                { target_ref = "hand-a", key = "H_K", name = "King of Hearts" },
                { target_ref = "hand-b", key = "S_A", name = "Ace of Spades" },
            },
            shop_items = {
                {
                    target_ref = "shop-joker",
                    category = "joker",
                    key = "j_greedy_joker",
                    name = "Greedy Joker",
                    description = "Played cards with Diamond suit give +3 Mult when scored",
                    cost = 5,
                    slot = "joker",
                },
                {
                    target_ref = "shop-planet",
                    category = "consumable",
                    key = "c_pluto",
                    name = "Pluto",
                    description = "Level up High Card",
                    cost = 3,
                    slot = "consumable",
                },
                {
                    target_ref = "shop-card",
                    category = "playing_card",
                    key = "S_A",
                    name = "Ace of Spades",
                    description = "",
                    cost = 1,
                },
                {
                    target_ref = "shop-strength",
                    category = "consumable",
                    key = "c_strength",
                    name = "Strength",
                    description = "Increases rank of up to 2 selected cards by 1",
                    cost = 3,
                    slot = "consumable",
                },
            },
            shop_vouchers = {
                {
                    target_ref = "shop-voucher",
                    category = "voucher",
                    key = "v_overstock_norm",
                    name = "Overstock",
                    description = "+1 card slot available in shop",
                    cost = 10,
                },
            },
            shop_boosters = {
                {
                    target_ref = "shop-booster",
                    category = "booster",
                    key = "p_arcana_normal_1",
                    name = "Arcana Pack",
                    description = "Choose 1 of up to 3 Tarot cards to be used immediately",
                    cost = 4,
                },
            },
            legal_actions = {
                {
                    tool = "buy_shop_item",
                    target_refs = {
                        item_id = {
                            "shop-joker",
                            "shop-planet",
                            "shop-card",
                            "shop-strength",
                        },
                    },
                },
                {
                    tool = "buy_and_use_shop_item",
                    fixed_target_refs = { item_id = "shop-planet" },
                },
                {
                    tool = "buy_and_use_shop_item",
                    fixed_target_refs = { item_id = "shop-strength" },
                    target_refs = { target_ids = { "hand-a", "hand-b" } },
                    arguments = { target_ids = { min_items = 1, max_items = 2 } },
                },
                {
                    tool = "redeem_voucher",
                    target_refs = { voucher_id = { "shop-voucher" } },
                },
                {
                    tool = "open_booster",
                    target_refs = { booster_id = { "shop-booster" } },
                },
                { tool = "reroll_shop" },
                {
                    tool = "sell_owned_item",
                    target_refs = { item_id = { "owned-joker" } },
                },
                { tool = "leave_shop" },
            },
        },
    }
end

local function shop_after_buy_observation()
    local observation = shop_catalog_observation()
    observation.decision_sequence = 10
    observation.public_state.money = 7
    observation.public_state.jokers = {
        observation.public_state.jokers[1],
        {
            target_ref = "bought-joker",
            key = "j_greedy_joker",
            name = "Greedy Joker",
            sellable = true,
            sell_value = 2,
        },
    }
    observation.public_state.shop_items = {
        observation.public_state.shop_items[2],
        observation.public_state.shop_items[3],
        observation.public_state.shop_items[4],
    }
    observation.public_state.legal_actions[1].target_refs.item_id =
        { "shop-planet", "shop-card", "shop-strength" }
    observation.public_state.legal_actions[7].target_refs.item_id =
        { "owned-joker", "bought-joker" }
    return observation
end

local function shop_after_use_observation()
    local observation = shop_catalog_observation()
    observation.decision_sequence = 10
    observation.public_state.money = 9
    observation.public_state.shop_items = {
        observation.public_state.shop_items[1],
        observation.public_state.shop_items[3],
        observation.public_state.shop_items[4],
    }
    observation.public_state.legal_actions[1].target_refs.item_id =
        { "shop-joker", "shop-card", "shop-strength" }
    observation.public_state.legal_actions[2] = observation.public_state.legal_actions[3]
    table.remove(observation.public_state.legal_actions, 3)
    return observation
end

local function shop_after_redeem_observation()
    local observation = shop_catalog_observation()
    observation.decision_sequence = 10
    observation.public_state.money = 2
    observation.public_state.vouchers = {
        {
            key = "v_overstock_norm",
            name = "Overstock",
            description = "+1 card slot available in shop",
        },
    }
    observation.public_state.shop_vouchers = {}
    table.remove(observation.public_state.legal_actions, 4)
    return observation
end

local function shop_after_reroll_observation()
    local observation = shop_catalog_observation()
    observation.decision_sequence = 10
    observation.public_state.money = 7
    observation.public_state.reroll_cost = 6
    observation.public_state.shop_items = {
        {
            target_ref = "rerolled-joker",
            category = "joker",
            key = "j_jolly",
            name = "Jolly Joker",
            description = "+8 Mult if played hand contains a Pair",
            cost = 3,
            slot = "joker",
        },
    }
    observation.public_state.legal_actions = {
        {
            tool = "buy_shop_item",
            target_refs = { item_id = { "rerolled-joker" } },
        },
        {
            tool = "redeem_voucher",
            target_refs = { voucher_id = { "shop-voucher" } },
        },
        {
            tool = "open_booster",
            target_refs = { booster_id = { "shop-booster" } },
        },
        { tool = "reroll_shop" },
        {
            tool = "sell_owned_item",
            target_refs = { item_id = { "owned-joker" } },
        },
        { tool = "leave_shop" },
    }
    return observation
end

local function shop_after_sell_observation()
    local observation = shop_catalog_observation()
    observation.decision_sequence = 10
    observation.public_state.money = 13
    observation.public_state.jokers = {}
    table.remove(observation.public_state.legal_actions, 7)
    return observation
end

local function booster_pack_observation(category, items, choices_left, extra)
    local item_refs = {}
    for index, item in ipairs(items) do
        item_refs[index] = item.target_ref
    end
    local observation = {
        run_id = "run-alpha",
        decision_sequence = 10,
        phase = "booster",
        public_state = {
            game_version = "1.0.1o-FULL",
            steamodded_version = "1.0.0~BETA-2014b",
            lovely_version = "0.9.0",
            compatibility = { status = "supported", content_mods = "supported" },
            active_mods = default_active_mods,
            ante = 1,
            money = 8,
            booster = { category = category, choices_left = choices_left or 1 },
            booster_items = items,
            legal_actions = {
                {
                    tool = "choose_booster_item",
                    target_refs = { item_id = item_refs },
                },
                { tool = "skip_booster" },
            },
        },
    }
    for key, value in pairs(extra or {}) do
        observation.public_state[key] = value
    end
    return observation
end

local function booster_decision_observation()
    return booster_pack_observation("arcana", {
        {
            target_ref = "pack-fool",
            category = "consumable",
            key = "c_fool",
            name = "The Fool",
            description = "Creates the last Tarot or Planet card used during this run",
            min_targets = 0,
            max_targets = 0,
        },
    })
end

local function victory_observation()
    return {
        run_id = "run-alpha",
        decision_sequence = 20,
        phase = "victory",
        public_state = {
            game_version = "1.0.1o-FULL",
            steamodded_version = "1.0.0~BETA-2014b",
            lovely_version = "0.9.0",
            compatibility = { status = "supported", content_mods = "supported" },
            active_mods = default_active_mods,
            ante = 8,
            round = 24,
            money = 42,
            won = true,
            seed = "MCPTEST",
            best_hand = 12000,
            most_played_hand = "Flush",
            cards_played = 80,
            cards_discarded = 20,
            cards_purchased = 12,
            times_rerolled = 3,
            new_collection = 5,
            legal_actions = {
                { tool = "continue_endless" },
                { tool = "return_to_menu" },
            },
        },
    }
end

local function defeat_observation()
    return {
        run_id = "run-alpha",
        decision_sequence = 12,
        phase = "defeat",
        public_state = {
            game_version = "1.0.1o-FULL",
            steamodded_version = "1.0.0~BETA-2014b",
            lovely_version = "0.9.0",
            compatibility = { status = "supported", content_mods = "supported" },
            active_mods = default_active_mods,
            ante = 2,
            round = 5,
            money = 3,
            won = false,
            seed = "MCPTEST",
            best_hand = 400,
            most_played_hand = "Pair",
            cards_played = 18,
            cards_discarded = 6,
            cards_purchased = 2,
            times_rerolled = 0,
            new_collection = 1,
            defeated_by = {
                key = "bl_small",
                name = "Small Blind",
                description = "Score at least 300 chips.",
            },
            legal_actions = {
                { tool = "return_to_menu" },
            },
        },
    }
end

local function endless_shop_observation()
    local observation = shop_observation()
    observation.decision_sequence = 21
    observation.public_state.ante = 9
    observation.public_state.money = 47
    observation.public_state.won = true
    return observation
end

local valid_discovery_body = rpc_body(1, "server/discover")

local function call_tool(server, port, id, name, arguments)
    local body = rpc_body(id, "tools/call", { name = name, arguments = arguments })
    local request = make_request(port, body, {
        headers = { ["Mcp-Method"] = "tools/call" },
    })
    local status, headers, response_body = parse_http(send_http(server, port, request))
    return status, headers, JSON.decode(response_body)
end

local function list_tools(server, port, id)
    local body = rpc_body(id, "tools/list")
    local request = make_request(port, body, {
        headers = { ["Mcp-Method"] = "tools/list" },
    })
    local status, _, response_body = parse_http(send_http(server, port, request))
    local payload = JSON.decode(response_body)
    luaunit.assertEquals(status, 200)
    local by_name = {}
    for _, tool in ipairs(payload.result.tools) do
        by_name[tool.name] = tool
    end
    return by_name
end

local function assert_semantic_envelope(payload, is_error)
    local result = payload.result.structuredContent
    luaunit.assertEquals(payload.result.isError, is_error)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.output)
    luaunit.assertNil(result.effect_encyclopedia)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(JSON.decode(payload.result.content[1].text), result)
    return result
end

TestDiscovery = {}

function TestDiscovery:setUp()
    self.adapter = FakeBalatroAdapter.new({
        states = { blind_selection_observation(), hand_observation() },
        transitions = {
            [1] = {
                select_blind = {
                    next_state = 2,
                    target = { argument = "blind_id", reference = "small-blind" },
                },
            },
        },
    })
    self.server = GameMcpServer.new({
        adapter = self.adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        max_header_bytes = 512,
        max_body_bytes = 512,
        server_info = {
            name = "balatro-mcp",
            title = "Balatro MCP",
            version = "0.1.0",
            description = "Expose Balatro decision states and semantic actions through MCP.",
        },
    })
    luaunit.assertTrue(self.server:start())
    wait_until(self.server, function()
        return self.server:get_status().state == "listening"
    end, 2)
    self.port = self.server:get_status().port
end

function TestDiscovery:tearDown()
    self.server:stop()
end

function TestDiscovery:test_client_can_discover_server_over_http()
    local request = make_request(self.port, valid_discovery_body)
    local status, headers, response_body = parse_http(send_http(self.server, self.port, request))
    local payload = JSON.decode(response_body)

    luaunit.assertEquals(status, 200)
    luaunit.assertEquals(headers["content-type"], "application/json")
    luaunit.assertEquals(headers["connection"], "close")
    luaunit.assertEquals(payload.jsonrpc, "2.0")
    luaunit.assertEquals(payload.id, 1)
    luaunit.assertEquals(payload.result.resultType, "complete")
    luaunit.assertEquals(payload.result.ttlMs, 0)
    luaunit.assertEquals(payload.result.cacheScope, "private")
    luaunit.assertEquals(payload.result.supportedVersions, { "2026-07-28" })
    luaunit.assertEquals(payload.result.capabilities, { tools = {} })
    luaunit.assertEquals(payload.result._meta["io.modelcontextprotocol/serverInfo"], {
        name = "balatro-mcp",
        title = "Balatro MCP",
        version = "0.1.0",
        description = "Expose Balatro decision states and semantic actions through MCP.",
    })
end

function TestDiscovery:test_tools_list_describes_fixed_catalog()
    local body = rpc_body(2, "tools/list")
    local request = make_request(self.port, body, {
        headers = { ["Mcp-Method"] = "tools/list" },
    })
    local status, _, response_body = parse_http(send_http(self.server, self.port, request))
    local payload = JSON.decode(response_body)
    local names = {}
    for _, tool in ipairs(payload.result.tools) do
        names[#names + 1] = tool.name
        luaunit.assertTrue(type(tool.description) == "string" and #tool.description > 0)
        luaunit.assertEquals(tool.inputSchema.type, "object")
        local required = tool.inputSchema.required or {}
        local requires_state_hash = false
        for _, name in ipairs(required) do
            if name == "state_hash" then
                requires_state_hash = true
            end
        end
        if tool.name == "get_game_state" or tool.name == "get_effect_encyclopedia" then
            luaunit.assertFalse(requires_state_hash)
            luaunit.assertEquals(type(tool.inputSchema.properties), "table")
            luaunit.assertNil(next(tool.inputSchema.properties))
            luaunit.assertNil(tool.inputSchema.properties.visibility)
            luaunit.assertNil(tool.inputSchema.properties.state_hash)
            luaunit.assertEquals(tool.inputSchema.required, nil)
        else
            luaunit.assertTrue(requires_state_hash)
            luaunit.assertNil(tool.inputSchema.properties.visibility)
        end
    end

    luaunit.assertEquals(status, 200)
    luaunit.assertEquals(payload.result.resultType, "complete")
    luaunit.assertEquals(payload.result.cacheScope, "public")
    luaunit.assertEquals(payload.result.ttlMs, 0)
    luaunit.assertNotStrContains(response_body, '"properties":[]')
    luaunit.assertEquals(#names, 21)
    luaunit.assertEquals(names, {
        "get_game_state",
        "get_effect_encyclopedia",
        "start_run",
        "select_blind",
        "skip_blind",
        "reroll_boss",
        "play_hand",
        "discard_cards",
        "reorder_cards",
        "use_consumable",
        "buy_shop_item",
        "buy_and_use_shop_item",
        "redeem_voucher",
        "open_booster",
        "reroll_shop",
        "sell_owned_item",
        "leave_shop",
        "choose_booster_item",
        "skip_booster",
        "continue_endless",
        "return_to_menu",
    })
end

function TestDiscovery:test_readonly_tools_announce_json_schema_contracts()
    local tools = list_tools(self.server, self.port, 9100)
    local phases = {
        "main_menu",
        "run_setup",
        "blind_selection",
        "hand_play",
        "shop",
        "booster",
        "victory",
        "defeat",
    }
    local encyclopedia_sets = {
        "Joker",
        "Back",
        "Stake",
        "Voucher",
        "Tarot",
        "Planet",
        "Spectral",
        "Enhanced",
        "Seal",
        "Edition",
        "Booster",
        "Tag",
        "Blind",
    }
    local readonly = {
        get_game_state = {
            errors = {
                "INVALID_PARAMS",
                "DECISION_TIMEOUT",
                "GAME_BLOCKED",
                "INTERNAL_ERROR",
            },
            phrases = { "Preconditions", "empty object", "fair", "omniscient" },
        },
        get_effect_encyclopedia = {
            errors = {
                "INVALID_PARAMS",
                "DECISION_TIMEOUT",
                "GAME_BLOCKED",
                "INTERNAL_ERROR",
            },
            phrases = {
                "not in context",
                "visibility mode",
                "new Run",
                "does not track",
            },
        },
    }

    for name, expected in pairs(readonly) do
        local tool = tools[name]
        luaunit.assertNotNil(tool)
        luaunit.assertEquals(
            tool.outputSchema["$schema"],
            "https://json-schema.org/draft/2020-12/schema"
        )
        luaunit.assertEquals(tool.outputSchema.type, "object")
        luaunit.assertNotNil(tool.outputSchema["$defs"])
        luaunit.assertEquals(tool.outputSchema["$defs"].visibility.enum, { "fair", "omniscient" })
        luaunit.assertEquals(tool.outputSchema["$defs"].phase.enum, phases)
        luaunit.assertEquals(tool.outputSchema["$defs"].encyclopedia_set.enum, encyclopedia_sets)
        luaunit.assertEquals(
            tool.outputSchema["$defs"].state_snapshot.allOf[1]["$ref"],
            "#/$defs/snapshot_common"
        )
        luaunit.assertEquals(#tool.outputSchema["$defs"].state_snapshot.allOf[2].oneOf, #phases)
        luaunit.assertNil(tool.errors)
        luaunit.assertNotStrContains(tool.description, "HeaderMismatch")
        luaunit.assertNotStrContains(tool.description, "JSON-RPC")
        luaunit.assertNotStrContains(tool.description, "Parse error")
        luaunit.assertStrContains(tool.description, "fair")
        luaunit.assertStrContains(tool.description, "omniscient")
        for _, code in ipairs(expected.errors) do
            luaunit.assertStrContains(tool.description, code)
        end
        for _, phrase in ipairs(expected.phrases) do
            luaunit.assertStrContains(tool.description, phrase)
        end
    end
    for _, phase in ipairs(phases) do
        luaunit.assertStrContains(tools.get_game_state.description, phase)
    end

    luaunit.assertEquals(
        tools.get_game_state.outputSchema.properties.state["$ref"],
        "#/$defs/state_snapshot"
    )
    luaunit.assertEquals(tools.get_game_state.outputSchema.required, { "state" })
    luaunit.assertEquals(
        tools.get_effect_encyclopedia.outputSchema.properties.effect_encyclopedia["$ref"],
        "#/$defs/effect_encyclopedia"
    )
    luaunit.assertEquals(
        tools.get_effect_encyclopedia.outputSchema.required,
        { "effect_encyclopedia" }
    )
    for _, set_name in ipairs(encyclopedia_sets) do
        luaunit.assertStrContains(tools.get_effect_encyclopedia.description, set_name)
    end
end

function TestDiscovery:test_run_hand_owned_tools_announce_json_schema_contracts()
    local tools = list_tools(self.server, self.port, 9500)
    local phases = {
        "main_menu",
        "run_setup",
        "blind_selection",
        "hand_play",
        "shop",
        "booster",
        "victory",
        "defeat",
    }
    local resolution_phases = {
        "run_start",
        "blind_selection",
        "hand",
        "discard",
        "shop",
        "booster",
        "before",
        "playing_card",
        "held_in_hand",
        "joker_main",
        "after",
        "end_of_round",
        "destroying_card",
        "debuffed_hand",
    }
    local event_types = { "apply", "trigger", "retrigger", "cash_out", "debuff_blocked" }
    local components = {
        "playing_card",
        "enhancement",
        "edition",
        "seal",
        "joker",
        "back",
        "voucher",
        "tarot",
        "planet",
        "spectral",
        "tag",
        "blind",
        "booster",
    }
    local effect_kinds = {
        "chips",
        "mult",
        "x_mult",
        "x_chips",
        "dollars",
        "destroy",
        "create",
        "set_card_state",
        "copy",
        "poker_hand_level",
        "capacity",
        "round_allowance",
        "run_rule",
        "card_progress",
        "tag_change",
        "blind_change",
        "reorder",
        "move_card",
        "open_booster",
        "ante_change",
    }
    local public_errors = {
        "INVALID_PARAMS",
        "STALE_STATE",
        "INVALID_PHASE",
        "ACTION_NOT_ALLOWED",
        "INCOMPATIBLE_VERSION",
        "DECISION_TIMEOUT",
        "GAME_BLOCKED",
        "INTERNAL_ERROR",
    }
    local action_tools = {
        start_run = {
            phrases = {
                "Preconditions",
                "deck_key",
                "stake",
                "seed",
                "1, 2, 3, 4, 5, 6, 7, 8",
                "A-Z",
                "legal_actions",
                "resolution",
            },
            has_targets = false,
        },
        select_blind = {
            phrases = { "Preconditions", "blind_id", "legal_actions", "resolution" },
            has_targets = true,
        },
        skip_blind = {
            phrases = { "Preconditions", "blind_id", "tag", "legal_actions", "resolution" },
            has_targets = true,
        },
        reroll_boss = {
            phrases = { "Preconditions", "Boss", "legal_actions", "resolution" },
            has_targets = false,
        },
        play_hand = {
            phrases = {
                "Preconditions",
                "card_ids",
                "processing order",
                "unique",
                "legal_actions",
                "resolution",
            },
            has_targets = true,
        },
        discard_cards = {
            phrases = {
                "Preconditions",
                "card_ids",
                "processing order",
                "unique",
                "legal_actions",
                "resolution",
            },
            has_targets = true,
        },
        reorder_cards = {
            phrases = {
                "Preconditions",
                "complete",
                "processing order",
                "hand",
                "jokers",
                "legal_actions",
                "resolution",
            },
            has_targets = true,
        },
        use_consumable = {
            phrases = {
                "Preconditions",
                "consumable_id",
                "target_ids",
                "processing order",
                "legal_actions",
                "resolution",
            },
            has_targets = true,
        },
        sell_owned_item = {
            phrases = {
                "Preconditions",
                "item_id",
                "Joker",
                "legal_actions",
                "resolution",
            },
            has_targets = true,
        },
    }

    for name, expected in pairs(action_tools) do
        local tool = tools[name]
        luaunit.assertNotNil(tool)
        luaunit.assertEquals(
            tool.outputSchema["$schema"],
            "https://json-schema.org/draft/2020-12/schema"
        )
        luaunit.assertEquals(tool.outputSchema.type, "object")
        luaunit.assertEquals(tool.outputSchema.additionalProperties, false)
        luaunit.assertEquals(tool.outputSchema.required, { "state" })
        luaunit.assertEquals(tool.outputSchema.properties.state["$ref"], "#/$defs/state_snapshot")
        luaunit.assertEquals(
            tool.outputSchema.properties.resolution["$ref"],
            "#/$defs/resolution_trace"
        )
        luaunit.assertEquals(
            tool.outputSchema["$defs"].state_snapshot.allOf[1]["$ref"],
            "#/$defs/snapshot_common"
        )
        luaunit.assertEquals(#tool.outputSchema["$defs"].state_snapshot.allOf[2].oneOf, #phases)
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_phase.enum, resolution_phases)
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_event_type.enum, event_types)
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_component.enum, components)
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_effect_kind.enum, effect_kinds)
        luaunit.assertEquals(#tool.outputSchema["$defs"].resolution_event.allOf[2].oneOf, 5)
        luaunit.assertEquals(#tool.outputSchema["$defs"].resolution_effect.oneOf, 17)
        luaunit.assertEquals(
            tool.outputSchema["$defs"].resolution_effect_scoring.required[1],
            "order"
        )
        luaunit.assertEquals(tool.outputSchema["$defs"].created_object_kind.enum, {
            "playing_card",
            "joker",
            "consumable",
            "voucher",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_destination.enum, {
            "owned",
            "permanent_deck",
            "shop_offer",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_card_state.enum, {
            "rank",
            "suit",
            "enhancement",
            "edition",
            "seal",
            "facedown",
            "debuffed",
            "forced_selection",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_copy_mode.enum, {
            "overwrite",
            "create",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_capacity_resource.enum, {
            "hand_size",
            "joker_slots",
            "consumable_slots",
            "shop_slots",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_allowance_resource.enum, {
            "hands",
            "discards",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_card_progress_resource.enum, {
            "chips",
            "mult",
            "x_mult",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_numeric_run_rule.enum, {
            "tarot_rate",
            "planet_rate",
            "spectral_rate",
            "edition_rate",
            "playing_card_rate",
            "shop_discount_percent",
            "shop_reroll_cost",
            "interest_cap",
            "money_per_hand",
            "money_per_discard",
            "ante_scaling",
            "held_planet_x_mult",
            "boss_reroll_cost",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_boolean_run_rule.enum, {
            "celestial_pack_planet",
            "arcana_pack_spectral",
            "enhanced_shop_playing_cards",
            "boss_reroll_once_per_ante",
            "unlimited_boss_rerolls",
            "no_interest",
            "face_cards_removed",
            "randomized_starting_deck",
            "boss_defeat_double_tag",
            "balanced_scoring",
            "shop_free",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_tag_operation.enum, {
            "add",
            "consume",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_blind_operation.enum, {
            "disable",
            "defeat",
            "replace",
            "requirement",
            "hand_restriction",
            "draw_rule",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_reorder_area.enum, {
            "hand",
            "jokers",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_reorder_method.enum, {
            "shuffle",
            "sort",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_move_zone.enum, {
            "deck",
            "hand",
            "play",
            "discard",
        })
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_booster_category.enum, {
            "arcana",
            "celestial",
            "spectral",
            "standard",
            "buffoon",
        })
        luaunit.assertEquals(
            tool.outputSchema["$defs"].resolution_effect_create.required,
            { "order", "kind", "object_kind", "destination" }
        )
        luaunit.assertNil(tool.errors)
        luaunit.assertNil(tool.inputSchema.properties.visibility)
        luaunit.assertNotStrContains(tool.description, "HeaderMismatch")
        luaunit.assertNotStrContains(tool.description, "JSON-RPC")
        luaunit.assertNotStrContains(tool.description, "Parse error")
        luaunit.assertNotStrContains(tool.description, "Compact Projection")
        luaunit.assertNotStrContains(tool.description, "`detail`")
        luaunit.assertNotStrContains(tool.description, "action-specific")
        luaunit.assertStrContains(tool.description, "fair")
        luaunit.assertStrContains(tool.description, "omniscient")
        luaunit.assertStrContains(tool.description, "state_hash")
        for _, code in ipairs(public_errors) do
            luaunit.assertStrContains(tool.description, code)
        end
        if expected.has_targets then
            luaunit.assertStrContains(tool.description, "INVALID_TARGET")
        end
        for _, phrase in ipairs(expected.phrases) do
            luaunit.assertStrContains(tool.description, phrase)
        end
        for _, phase in ipairs(phases) do
            luaunit.assertStrContains(tool.description, phase)
        end
        for _, phase in ipairs(resolution_phases) do
            luaunit.assertStrContains(tool.description, phase)
        end
        luaunit.assertStrContains(tool.description, "reorder area is hand, jokers")
        luaunit.assertStrContains(tool.description, "reorder method is shuffle, sort")
        luaunit.assertStrContains(tool.description, "move zone is deck, hand, play, discard")
    end

    luaunit.assertFalse(tools.start_run.inputSchema.properties.deck_key == nil)
    luaunit.assertEquals(
        tools.start_run.inputSchema.properties.stake.enum,
        { 1, 2, 3, 4, 5, 6, 7, 8 }
    )
    luaunit.assertStrContains(tools.start_run.description, "1, 2, 3, 4, 5, 6, 7, 8")
    luaunit.assertEquals(tools.play_hand.inputSchema.properties.card_ids.uniqueItems, true)
    luaunit.assertEquals(tools.play_hand.inputSchema.properties.card_ids.minItems, 1)
    luaunit.assertEquals(tools.play_hand.inputSchema.properties.card_ids.maxItems, 5)
    luaunit.assertStrContains(
        tools.play_hand.inputSchema.properties.card_ids.description,
        "processing order"
    )
    luaunit.assertEquals(tools.discard_cards.inputSchema.properties.card_ids.uniqueItems, true)
    luaunit.assertEquals(tools.reorder_cards.inputSchema.properties.ordered_ids.uniqueItems, true)
    luaunit.assertStrContains(
        tools.reorder_cards.inputSchema.properties.ordered_ids.description,
        "Complete"
    )
    luaunit.assertStrContains(
        tools.reorder_cards.inputSchema.properties.ordered_ids.description,
        "processing order"
    )
    luaunit.assertEquals(tools.use_consumable.inputSchema.properties.target_ids.uniqueItems, true)
    luaunit.assertStrContains(
        tools.use_consumable.inputSchema.properties.target_ids.description,
        "processing order"
    )
    luaunit.assertNil(tools.use_consumable.inputSchema.required[3])

    self.adapter:set_observation(owned_items_observation())
    local _, _, owned_payload = call_tool(self.server, self.port, 9501, "get_game_state")
    local owned = owned_payload.result.structuredContent.state
    luaunit.assertTrue(owned.legal_actions[1].arguments.ordered_ids.complete)
    luaunit.assertTrue(owned.legal_actions[1].arguments.ordered_ids.unique_items)
    luaunit.assertTrue(owned.legal_actions[1].arguments.ordered_ids.ordered)
    luaunit.assertTrue(owned.legal_actions[4].arguments.target_ids.unique_items)
    luaunit.assertTrue(owned.legal_actions[4].arguments.target_ids.ordered)
    luaunit.assertNil(owned.legal_actions[4].arguments.target_ids.complete)
end

function TestDiscovery:test_run_rule_schema_rejects_unknown_and_mixed_variants()
    local defs = assert(ToolCatalog.get("start_run")).outputSchema["$defs"]
    local schema = { ["$ref"] = "#/$defs/resolution_effect", ["$defs"] = defs }
    luaunit.assertNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "run_rule",
        rule = "tarot_rate",
        amount = 5.6,
        value = 9.6,
    }))
    luaunit.assertNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "run_rule",
        rule = "no_interest",
        enabled = true,
    }))
    luaunit.assertNotNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "run_rule",
        rule = "arbitrary_lua_field",
        value = 1,
    }))
    luaunit.assertNotNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "run_rule",
        rule = "no_interest",
        enabled = true,
        value = 1,
    }))
end

function TestDiscovery:test_lifecycle_effect_schemas_reject_unknown_and_mixed_variants()
    local defs = assert(ToolCatalog.get("skip_blind")).outputSchema["$defs"]
    local schema = { ["$ref"] = "#/$defs/resolution_effect", ["$defs"] = defs }
    luaunit.assertNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "card_progress",
        resource = "x_mult",
        amount = 0.25,
        value = 1.5,
    }))
    luaunit.assertNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "blind_change",
        operation = "disable",
    }))
    luaunit.assertNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "tag_change",
        operation = "add",
        key = "tag_double",
        quantity = 1,
    }))
    luaunit.assertNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "blind_change",
        operation = "replace",
        previous_key = "bl_head",
        key = "bl_hook",
    }))
    luaunit.assertNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "open_booster",
        category = "arcana",
        size = 5,
        choices = 2,
    }))
    luaunit.assertNotNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "card_progress",
        resource = "prototype_lua_field",
        amount = 1,
        value = 2,
    }))
    luaunit.assertNotNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "blind_change",
        operation = "disable",
        key = "bl_head",
    }))
    luaunit.assertNotNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "tag_change",
        operation = "remove",
        key = "tag_double",
        quantity = 1,
    }))
    luaunit.assertNotNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "blind_change",
        operation = "replace",
        previous_key = "bl_head",
        key = "bl_hook",
        quantity = 1,
    }))
    luaunit.assertNotNil(ToolCatalog.validate_schema(schema, {
        order = 1,
        kind = "open_booster",
        category = "modded",
        size = 5,
        choices = 2,
    }))
end

function TestDiscovery:test_blind_effect_schemas_reject_unknown_and_mixed_variants()
    local defs = assert(ToolCatalog.get("play_hand")).outputSchema["$defs"]
    local schema = { ["$ref"] = "#/$defs/resolution_effect", ["$defs"] = defs }
    for _, effect in ipairs({
        { order = 1, kind = "blind_change", operation = "defeat" },
        {
            order = 1,
            kind = "blind_change",
            operation = "requirement",
            score_requirement = 400,
        },
        {
            order = 1,
            kind = "blind_change",
            operation = "hand_restriction",
            hand_debuff = { forbidden_poker_hands = { "Pair" } },
        },
        {
            order = 1,
            kind = "blind_change",
            operation = "draw_rule",
            cards_per_draw = 3,
        },
        { order = 1, kind = "reorder", area = "jokers", method = "shuffle" },
        {
            order = 1,
            kind = "move_card",
            input_target_id = "card:1",
            from_zone = "hand",
            to_zone = "discard",
        },
    }) do
        luaunit.assertNil(ToolCatalog.validate_schema(schema, effect))
    end
    for _, effect in ipairs({
        {
            order = 1,
            kind = "blind_change",
            operation = "requirement",
            score_requirement = 400,
            cards_per_draw = 3,
        },
        {
            order = 1,
            kind = "blind_change",
            operation = "hand_restriction",
            hand_debuff = { arbitrary_lua_field = true },
        },
        { order = 1, kind = "reorder", area = "deck", method = "shuffle" },
        { order = 1, kind = "reorder", area = "jokers", method = "random" },
        {
            order = 1,
            kind = "move_card",
            input_target_id = "card:1",
            from_zone = "hand",
            to_zone = "owned",
        },
    }) do
        luaunit.assertNotNil(ToolCatalog.validate_schema(schema, effect))
    end
end

function TestDiscovery:test_static_enum_errors_list_allowed_values()
    local tools = list_tools(self.server, self.port, 9199)
    luaunit.assertEquals(tools.reorder_cards.inputSchema.properties.area.enum, { "hand", "jokers" })
    luaunit.assertStrContains(tools.reorder_cards.description, "hand")
    luaunit.assertStrContains(tools.reorder_cards.description, "jokers")
    self.adapter:set_observation(owned_items_observation())
    local _, _, owned_payload = call_tool(self.server, self.port, 9200, "get_game_state")
    local owned = owned_payload.result.structuredContent.state
    local _, _, bad_area = call_tool(self.server, self.port, 9201, "reorder_cards", {
        state_hash = owned.state_hash,
        area = "deck",
        ordered_ids = { owned.hand[1].id, owned.hand[2].id, owned.hand[3].id },
    })
    luaunit.assertTrue(bad_area.result.isError)
    luaunit.assertEquals(bad_area.result.structuredContent.code, "INVALID_PARAMS")
    luaunit.assertStrContains(
        bad_area.result.structuredContent.message,
        "allowed values: hand, jokers"
    )

    self.adapter:set_observation(main_menu_observation())
    local _, _, menu_payload = call_tool(self.server, self.port, 9202, "get_game_state")
    local menu = menu_payload.result.structuredContent.state
    local _, _, bad_stake = call_tool(self.server, self.port, 9203, "start_run", {
        state_hash = menu.state_hash,
        deck_key = "b_red",
        stake = 9,
    })
    luaunit.assertTrue(bad_stake.result.isError)
    luaunit.assertEquals(bad_stake.result.structuredContent.code, "INVALID_PARAMS")
    luaunit.assertStrContains(
        bad_stake.result.structuredContent.message,
        "allowed values: 1, 2, 3, 4, 5, 6, 7, 8"
    )
end

function TestDiscovery:test_readonly_success_fixtures_match_announced_output_schema()
    local tools = list_tools(self.server, self.port, 9300)
    local observations = {
        main_menu_observation(),
        run_setup_observation(),
        blind_selection_observation(),
        hand_observation(),
        shop_catalog_observation(),
        booster_decision_observation(),
        victory_observation(),
        defeat_observation(),
    }
    for index, observation in ipairs(observations) do
        self.adapter:set_observation(observation)
        local _, _, payload = call_tool(self.server, self.port, 9300 + index, "get_game_state")
        local err = ToolCatalog.validate_schema(
            tools.get_game_state.outputSchema,
            payload.result.structuredContent
        )
        luaunit.assertTrue(err == nil, observation.phase .. ": " .. tostring(err))
    end

    self.adapter:set_observation(main_menu_observation())
    local _, _, encyclopedia_payload =
        call_tool(self.server, self.port, 9320, "get_effect_encyclopedia")
    luaunit.assertEquals(
        ToolCatalog.validate_schema(
            tools.get_effect_encyclopedia.outputSchema,
            encyclopedia_payload.result.structuredContent
        ),
        nil
    )

    self.server:set_visibility("omniscient")
    local _, _, omniscient_encyclopedia =
        call_tool(self.server, self.port, 9321, "get_effect_encyclopedia")
    luaunit.assertEquals(
        ToolCatalog.validate_schema(
            tools.get_effect_encyclopedia.outputSchema,
            omniscient_encyclopedia.result.structuredContent
        ),
        nil
    )
    self.server:set_visibility("fair")

    local invalid = {
        state = {
            server_name = "balatro-mcp",
            server_version = "0.1.0",
            protocol_version = "2026-07-28",
            visibility = "fair",
            run_id = "menu",
            decision_sequence = 1,
            phase = "not_a_phase",
            legal_actions = {},
            state_hash = "deadbeef",
        },
    }
    luaunit.assertNotNil(ToolCatalog.validate_schema(tools.get_game_state.outputSchema, invalid))

    local unexpected = main_menu_observation()
    unexpected.public_state.unknown_field = true
    self.adapter:set_observation(unexpected)
    local _, _, unexpected_payload = call_tool(self.server, self.port, 9322, "get_game_state")
    luaunit.assertTrue(unexpected_payload.result.isError)
    luaunit.assertEquals(unexpected_payload.result.structuredContent.code, "INTERNAL_ERROR")
    luaunit.assertNil(unexpected_payload.result.structuredContent.state)
    luaunit.assertNil(unexpected_payload.result.structuredContent.resolution)
    luaunit.assertStrContains(unexpected_payload.result.content[1].text, '"state":null')

    local hidden_identity = hand_observation()
    hidden_identity.public_state.hand[1].hidden_identity = "S_A"
    self.adapter:set_observation(hidden_identity)
    local _, _, hidden_identity_payload = call_tool(self.server, self.port, 9323, "get_game_state")
    luaunit.assertTrue(hidden_identity_payload.result.isError)
    luaunit.assertNil(hidden_identity_payload.result.structuredContent.state)
    luaunit.assertNotStrContains(hidden_identity_payload.result.content[1].text, "S_A")

    local string_mod = main_menu_observation()
    string_mod.public_state.active_mods = { "balatro-mcp" }
    self.adapter:set_observation(string_mod)
    local _, _, string_mod_payload = call_tool(self.server, self.port, 9324, "get_game_state")
    luaunit.assertTrue(string_mod_payload.result.isError)
    luaunit.assertNil(string_mod_payload.result.structuredContent.state)

    local empty_card = hand_observation()
    empty_card.public_state.hand[1] = {}
    empty_card.public_state.legal_actions = {}
    self.adapter:set_observation(empty_card)
    local _, _, empty_card_payload = call_tool(self.server, self.port, 9325, "get_game_state")
    luaunit.assertTrue(empty_card_payload.result.isError)
    luaunit.assertNil(empty_card_payload.result.structuredContent.state)
end

function TestDiscovery:test_run_hand_owned_success_fixtures_match_announced_output_schema()
    local tools = list_tools(self.server, self.port, 9600)
    local function assert_valid(name, payload)
        luaunit.assertFalse(payload.result.isError)
        luaunit.assertEquals(
            ToolCatalog.validate_schema(tools[name].outputSchema, payload.result.structuredContent),
            nil
        )
        luaunit.assertNil(payload.result.structuredContent.output)
        luaunit.assertNil(payload.result.structuredContent.detail)
        luaunit.assertNil(payload.result.structuredContent.state.detail)
        luaunit.assertNil(payload.result.structuredContent.events)
        luaunit.assertNil(payload.result.structuredContent.effect_encyclopedia)
    end

    self.adapter.index = 1
    self.adapter.pending = nil
    self.adapter.states = { main_menu_observation(), blind_selection_observation() }
    self.adapter.transitions = {
        [1] = {
            start_run = {
                arguments = { deck_key = "b_red", stake = 1 },
                pending = { observations = 1, next_state = 2 },
            },
        },
    }
    local _, _, menu_payload = call_tool(self.server, self.port, 9601, "get_game_state")
    local menu = menu_payload.result.structuredContent.state
    local _, _, started = call_tool(self.server, self.port, 9602, "start_run", {
        state_hash = menu.state_hash,
        deck_key = "b_red",
        stake = 1,
    })
    assert_valid("start_run", started)
    luaunit.assertNil(started.result.structuredContent.resolution)

    local skip_from = blind_selection_observation()
    skip_from.public_state.legal_actions[#skip_from.public_state.legal_actions + 1] = {
        tool = "skip_blind",
        target_refs = { blind_id = { "small-blind" } },
    }
    local skip_to = blind_selection_observation()
    skip_to.decision_sequence = 8
    skip_to.public_state.blind_on_deck = "Big"
    self.adapter.index = 1
    self.adapter.pending = nil
    self.adapter.states = { skip_from, skip_to }
    self.adapter.transitions = {
        [1] = {
            skip_blind = {
                target = { argument = "blind_id", reference = "small-blind" },
                pending = { observations = 1, next_state = 2 },
            },
        },
    }
    local _, _, skip_state_payload = call_tool(self.server, self.port, 9603, "get_game_state")
    local skip_state = skip_state_payload.result.structuredContent.state
    local _, _, skipped = call_tool(self.server, self.port, 9604, "skip_blind", {
        state_hash = skip_state.state_hash,
        blind_id = skip_state.blinds[1].id,
    })
    assert_valid("skip_blind", skipped)
    luaunit.assertNil(skipped.result.structuredContent.resolution)

    local reroll_from = blind_selection_observation()
    reroll_from.public_state.legal_actions[#reroll_from.public_state.legal_actions + 1] =
        { tool = "reroll_boss" }
    local reroll_to = blind_selection_observation()
    reroll_to.decision_sequence = 8
    reroll_to.public_state.blinds[1].key = "bl_hook"
    self.adapter.index = 1
    self.adapter.pending = nil
    self.adapter.states = { reroll_from, reroll_to }
    self.adapter.transitions = {
        [1] = {
            reroll_boss = { pending = { observations = 1, next_state = 2 } },
        },
    }
    local _, _, reroll_state_payload = call_tool(self.server, self.port, 9605, "get_game_state")
    local reroll_state = reroll_state_payload.result.structuredContent.state
    local _, _, rerolled = call_tool(self.server, self.port, 9606, "reroll_boss", {
        state_hash = reroll_state.state_hash,
    })
    assert_valid("reroll_boss", rerolled)
    luaunit.assertNil(rerolled.result.structuredContent.resolution)

    self.adapter.index = 1
    self.adapter.pending = nil
    self.adapter.states = { blind_selection_observation(), hand_observation() }
    self.adapter.transitions = {
        [1] = {
            select_blind = {
                next_state = 2,
                target = { argument = "blind_id", reference = "small-blind" },
            },
        },
    }
    local _, _, blind_payload = call_tool(self.server, self.port, 9607, "get_game_state")
    local blinds = blind_payload.result.structuredContent.state
    local _, _, selected = call_tool(self.server, self.port, 9608, "select_blind", {
        state_hash = blinds.state_hash,
        blind_id = blinds.blinds[1].id,
    })
    assert_valid("select_blind", selected)
    luaunit.assertNil(selected.result.structuredContent.resolution)

    self.adapter.index = 1
    self.adapter.pending = nil
    self.adapter.states = { hand_observation(), shop_catalog_observation() }
    self.adapter.transitions = {
        [1] = {
            play_hand = {
                next_state = 2,
                target_order = { argument = "card_ids", references = { "card-a" } },
                resolution = {
                    {
                        order = 1,
                        phase = "playing_card",
                        type = "trigger",
                        component = "playing_card",
                        source = { input_target_id = "card-a" },
                        effects = {
                            {
                                order = 2,
                                kind = "chips",
                                amount = 11,
                                chips = 16,
                                mult = 1,
                                score = 16,
                            },
                        },
                    },
                    {
                        order = 3,
                        phase = "playing_card",
                        type = "retrigger",
                        component = "playing_card",
                        source = { input_target_id = "card-a" },
                        parent_order = 1,
                        cause = { input_target_id = "card-b" },
                        effects = {
                            {
                                order = 4,
                                kind = "chips",
                                amount = 11,
                                chips = 27,
                                mult = 1,
                                score = 27,
                            },
                        },
                    },
                    {
                        order = 5,
                        phase = "playing_card",
                        type = "debuff_blocked",
                        component = "playing_card",
                        source = { input_target_id = "card-b" },
                        effects = {},
                    },
                    {
                        order = 6,
                        phase = "destroying_card",
                        type = "trigger",
                        component = "enhancement",
                        source = { input_target_id = "card-a" },
                        effects = {
                            { order = 7, kind = "destroy", input_target_id = "card-a" },
                        },
                    },
                    {
                        order = 8,
                        phase = "before",
                        type = "trigger",
                        component = "playing_card",
                        source = { input_target_id = "card-a" },
                        effects = {
                            {
                                order = 9,
                                kind = "create",
                                object_kind = "consumable",
                                destination = "owned",
                                key = "c_sigil",
                            },
                        },
                    },
                    {
                        order = 10,
                        phase = "end_of_round",
                        type = "cash_out",
                        effects = { { order = 11, kind = "dollars", amount = 5, money = 9 } },
                    },
                },
            },
        },
    }
    local _, _, hand_payload = call_tool(self.server, self.port, 9609, "get_game_state")
    local hand = hand_payload.result.structuredContent.state
    local _, _, played = call_tool(self.server, self.port, 9610, "play_hand", {
        state_hash = hand.state_hash,
        card_ids = { hand.hand[1].id },
    })
    assert_valid("play_hand", played)
    luaunit.assertEquals(#played.result.structuredContent.resolution, 6)
    luaunit.assertEquals(played.result.structuredContent.resolution[1].type, "trigger")
    luaunit.assertEquals(played.result.structuredContent.resolution[2].type, "retrigger")
    luaunit.assertEquals(played.result.structuredContent.resolution[3].type, "debuff_blocked")
    luaunit.assertEquals(played.result.structuredContent.resolution[6].type, "cash_out")

    local discarded_to = hand_observation()
    discarded_to.decision_sequence = 8
    self.adapter.index = 1
    self.adapter.pending = nil
    self.adapter.states = { hand_observation(), discarded_to }
    self.adapter.transitions = {
        [1] = {
            discard_cards = {
                next_state = 2,
                target_order = { argument = "card_ids", references = { "card-c" } },
            },
        },
    }
    local _, _, discard_state_payload = call_tool(self.server, self.port, 9611, "get_game_state")
    local discard_state = discard_state_payload.result.structuredContent.state
    local _, _, discarded = call_tool(self.server, self.port, 9612, "discard_cards", {
        state_hash = discard_state.state_hash,
        card_ids = { discard_state.hand[3].id },
    })
    assert_valid("discard_cards", discarded)
    luaunit.assertNil(discarded.result.structuredContent.resolution)

    local owned_from = owned_items_observation()
    owned_from.public_state.hands_left = 4
    owned_from.public_state.discards_left = 3
    local owned_to = owned_items_after_observation()
    owned_to.public_state.hands_left = 4
    owned_to.public_state.discards_left = 3
    self.adapter.index = 1
    self.adapter.pending = nil
    self.adapter.states = { owned_from, owned_to }
    self.adapter.transitions = {
        [1] = {
            reorder_cards = {
                next_state = 2,
                arguments = { area = "jokers" },
                target_order = {
                    argument = "ordered_ids",
                    references = { "joker-right", "joker-left" },
                },
            },
            use_consumable = {
                next_state = 2,
                target = { argument = "consumable_id", reference = "planet-pluto" },
            },
            sell_owned_item = {
                next_state = 2,
                target = { argument = "item_id", reference = "joker-left" },
            },
        },
    }
    local _, _, owned_payload = call_tool(self.server, self.port, 9613, "get_game_state")
    local owned = owned_payload.result.structuredContent.state
    local _, _, reordered = call_tool(self.server, self.port, 9614, "reorder_cards", {
        state_hash = owned.state_hash,
        area = "jokers",
        ordered_ids = { owned.jokers[2].id, owned.jokers[1].id },
    })
    assert_valid("reorder_cards", reordered)
    luaunit.assertNil(reordered.result.structuredContent.resolution)

    self.adapter.index = 1
    self.adapter.pending = nil
    self.adapter.states = { owned_from, owned_to }
    local _, _, owned_again_payload = call_tool(self.server, self.port, 9615, "get_game_state")
    local owned_again = owned_again_payload.result.structuredContent.state
    local _, _, used = call_tool(self.server, self.port, 9616, "use_consumable", {
        state_hash = owned_again.state_hash,
        consumable_id = owned_again.consumables[1].id,
    })
    assert_valid("use_consumable", used)
    luaunit.assertNil(used.result.structuredContent.resolution)

    self.adapter.index = 1
    self.adapter.pending = nil
    self.adapter.states = { owned_from, owned_to }
    local _, _, owned_sell_payload = call_tool(self.server, self.port, 9617, "get_game_state")
    local owned_sell = owned_sell_payload.result.structuredContent.state
    local _, _, sold = call_tool(self.server, self.port, 9618, "sell_owned_item", {
        state_hash = owned_sell.state_hash,
        item_id = owned_sell.jokers[1].id,
    })
    assert_valid("sell_owned_item", sold)
    luaunit.assertNil(sold.result.structuredContent.resolution)

    local shop_state = played.result.structuredContent.state
    luaunit.assertNotNil(ToolCatalog.validate_schema(tools.play_hand.outputSchema, {
        state = shop_state,
        resolution = {
            { phase = "joker_main", type = "hand_played", effects = {} },
        },
    }))
    luaunit.assertNotNil(ToolCatalog.validate_schema(tools.play_hand.outputSchema, {
        state = shop_state,
        resolution = {
            {
                order = 1,
                phase = "playing_card",
                type = "trigger",
                component = "playing_card",
                effects = { { kind = "chips", amount = 11 } },
            },
        },
    }))
    luaunit.assertNotNil(ToolCatalog.validate_schema(tools.play_hand.outputSchema, {
        state = shop_state,
        resolution = {
            {
                order = 1,
                phase = "playing_card",
                type = "retrigger",
                component = "playing_card",
                source = { input_target_id = "card-a" },
                parent_order = 1,
                effects = {
                    { kind = "chips", amount = 11, chips = 16, mult = 1, score = 16 },
                },
            },
        },
    }))
end

function TestDiscovery:test_shop_booster_terminal_tools_announce_json_schema_contracts()
    local tools = list_tools(self.server, self.port, 9700)
    local phases = {
        "main_menu",
        "run_setup",
        "blind_selection",
        "hand_play",
        "shop",
        "booster",
        "victory",
        "defeat",
    }
    local resolution_phases = {
        "run_start",
        "blind_selection",
        "hand",
        "discard",
        "shop",
        "booster",
        "before",
        "playing_card",
        "held_in_hand",
        "joker_main",
        "after",
        "end_of_round",
        "destroying_card",
        "debuffed_hand",
    }
    local public_errors = {
        "INVALID_PARAMS",
        "STALE_STATE",
        "INVALID_PHASE",
        "ACTION_NOT_ALLOWED",
        "INCOMPATIBLE_VERSION",
        "DECISION_TIMEOUT",
        "GAME_BLOCKED",
        "INTERNAL_ERROR",
    }
    local action_tools = {
        buy_shop_item = {
            phrases = {
                "Preconditions",
                "item_id",
                "Legal Action Descriptor",
                "legal_actions",
                "resolution",
            },
            has_targets = true,
        },
        buy_and_use_shop_item = {
            phrases = {
                "Preconditions",
                "item_id",
                "target_ids",
                "processing order",
                "unique",
                "legal_actions",
                "resolution",
            },
            has_targets = true,
        },
        redeem_voucher = {
            phrases = {
                "Preconditions",
                "voucher_id",
                "legal_actions",
                "resolution",
            },
            has_targets = true,
        },
        open_booster = {
            phrases = {
                "Preconditions",
                "booster_id",
                "legal_actions",
                "resolution",
            },
            has_targets = true,
        },
        reroll_shop = {
            phrases = { "Preconditions", "reroll", "legal_actions", "resolution" },
            has_targets = false,
        },
        leave_shop = {
            phrases = { "Preconditions", "Blind", "legal_actions", "resolution" },
            has_targets = false,
        },
        choose_booster_item = {
            phrases = {
                "Preconditions",
                "item_id",
                "target_ids",
                "processing order",
                "unique",
                "legal_actions",
                "resolution",
            },
            has_targets = true,
        },
        skip_booster = {
            phrases = { "Preconditions", "booster", "legal_actions", "resolution" },
            has_targets = false,
        },
        continue_endless = {
            phrases = { "Preconditions", "Endless", "legal_actions", "resolution" },
            has_targets = false,
        },
        return_to_menu = {
            phrases = { "Preconditions", "main menu", "legal_actions", "resolution" },
            has_targets = false,
        },
    }

    for name, expected in pairs(action_tools) do
        local tool = tools[name]
        luaunit.assertNotNil(tool)
        luaunit.assertEquals(
            tool.outputSchema["$schema"],
            "https://json-schema.org/draft/2020-12/schema"
        )
        luaunit.assertEquals(tool.outputSchema.type, "object")
        luaunit.assertEquals(tool.outputSchema.additionalProperties, false)
        luaunit.assertEquals(tool.outputSchema.required, { "state" })
        luaunit.assertEquals(tool.outputSchema.properties.state["$ref"], "#/$defs/state_snapshot")
        luaunit.assertEquals(
            tool.outputSchema.properties.resolution["$ref"],
            "#/$defs/resolution_trace"
        )
        luaunit.assertEquals(#tool.outputSchema["$defs"].state_snapshot.allOf[2].oneOf, #phases)
        luaunit.assertEquals(tool.outputSchema["$defs"].resolution_phase.enum, resolution_phases)
        luaunit.assertEquals(#tool.outputSchema["$defs"].resolution_event.allOf[2].oneOf, 5)
        luaunit.assertNil(tool.errors)
        luaunit.assertNil(tool.inputSchema.properties.visibility)
        luaunit.assertNotStrContains(tool.description, "HeaderMismatch")
        luaunit.assertNotStrContains(tool.description, "JSON-RPC")
        luaunit.assertNotStrContains(tool.description, "Parse error")
        luaunit.assertNotStrContains(tool.description, "Compact Projection")
        luaunit.assertNotStrContains(tool.description, "`detail`")
        luaunit.assertNotStrContains(tool.description, "action-specific")
        luaunit.assertStrContains(tool.description, "fair")
        luaunit.assertStrContains(tool.description, "omniscient")
        luaunit.assertStrContains(tool.description, "state_hash")
        for _, code in ipairs(public_errors) do
            luaunit.assertStrContains(tool.description, code)
        end
        if expected.has_targets then
            luaunit.assertStrContains(tool.description, "INVALID_TARGET")
        else
            luaunit.assertNotStrContains(tool.description, "INVALID_TARGET")
        end
        for _, phrase in ipairs(expected.phrases) do
            luaunit.assertStrContains(tool.description, phrase)
        end
        for _, phase in ipairs(phases) do
            luaunit.assertStrContains(tool.description, phase)
        end
    end

    luaunit.assertEquals(
        tools.buy_and_use_shop_item.inputSchema.properties.target_ids.uniqueItems,
        true
    )
    luaunit.assertStrContains(
        tools.buy_and_use_shop_item.inputSchema.properties.target_ids.description,
        "processing order"
    )
    luaunit.assertNil(tools.buy_and_use_shop_item.inputSchema.required[3])
    luaunit.assertEquals(
        tools.choose_booster_item.inputSchema.properties.target_ids.uniqueItems,
        true
    )
    luaunit.assertStrContains(
        tools.choose_booster_item.inputSchema.properties.target_ids.description,
        "processing order"
    )
    luaunit.assertNil(tools.choose_booster_item.inputSchema.required[3])
    luaunit.assertStrContains(
        tools.buy_shop_item.inputSchema.properties.item_id.description,
        "Legal Action Descriptor"
    )
    luaunit.assertStrContains(
        tools.redeem_voucher.inputSchema.properties.voucher_id.description,
        "Legal Action Descriptor"
    )
    luaunit.assertStrContains(
        tools.open_booster.inputSchema.properties.booster_id.description,
        "Legal Action Descriptor"
    )

    self.adapter:set_observation(shop_catalog_observation())
    local _, _, shop_payload = call_tool(self.server, self.port, 9701, "get_game_state")
    local shop = shop_payload.result.structuredContent.state
    luaunit.assertEquals(shop.legal_actions[1].arguments.item_id.allowed_values, {
        "shop-joker",
        "shop-planet",
        "shop-card",
        "shop-strength",
    })
    luaunit.assertEquals(shop.legal_actions[3].fixed_arguments.item_id, "shop-strength")
    luaunit.assertTrue(shop.legal_actions[3].arguments.target_ids.unique_items)
    luaunit.assertTrue(shop.legal_actions[3].arguments.target_ids.ordered)
    luaunit.assertEquals(shop.legal_actions[4].arguments.voucher_id.allowed_values, {
        "shop-voucher",
    })
    luaunit.assertEquals(shop.legal_actions[5].arguments.booster_id.allowed_values, {
        "shop-booster",
    })

    self.adapter:set_observation(booster_pack_observation(
        "arcana",
        {
            {
                target_ref = "pack-fool",
                category = "consumable",
                key = "c_fool",
                name = "The Fool",
            },
            {
                target_ref = "pack-strength",
                category = "consumable",
                key = "c_strength",
                name = "Strength",
                min_targets = 1,
                max_targets = 2,
            },
        },
        1,
        {
            hand = {
                { target_ref = "hand-a", key = "H_K", name = "King of Hearts" },
                { target_ref = "hand-b", key = "S_A", name = "Ace of Spades" },
            },
            legal_actions = {
                {
                    tool = "choose_booster_item",
                    target_refs = { item_id = { "pack-fool" } },
                },
                {
                    tool = "choose_booster_item",
                    fixed_target_refs = { item_id = "pack-strength" },
                    target_refs = { target_ids = { "hand-a", "hand-b" } },
                    arguments = { target_ids = { min_items = 1, max_items = 2 } },
                },
                { tool = "skip_booster" },
            },
        }
    ))
    local _, _, booster_payload = call_tool(self.server, self.port, 9702, "get_game_state")
    local booster = booster_payload.result.structuredContent.state
    luaunit.assertEquals(booster.legal_actions[1].arguments.item_id.allowed_values, {
        "pack-fool",
    })
    luaunit.assertEquals(booster.legal_actions[2].fixed_arguments.item_id, "pack-strength")
    luaunit.assertTrue(booster.legal_actions[2].arguments.target_ids.unique_items)
    luaunit.assertTrue(booster.legal_actions[2].arguments.target_ids.ordered)
    luaunit.assertEquals(booster.legal_actions[2].arguments.target_ids.allowed_values, {
        "hand-a",
        "hand-b",
    })
end

function TestDiscovery:test_shop_booster_terminal_success_fixtures_match_announced_output_schema()
    local tools = list_tools(self.server, self.port, 9800)
    local next_id = 9801
    local function assert_valid(name, payload)
        luaunit.assertFalse(payload.result.isError)
        luaunit.assertEquals(
            ToolCatalog.validate_schema(tools[name].outputSchema, payload.result.structuredContent),
            nil
        )
        luaunit.assertNil(payload.result.structuredContent.output)
        luaunit.assertNil(payload.result.structuredContent.detail)
        luaunit.assertNil(payload.result.structuredContent.state.detail)
        luaunit.assertNil(payload.result.structuredContent.events)
        luaunit.assertNil(payload.result.structuredContent.effect_encyclopedia)
    end
    local function call_action(name, from_observation, to_observation, transition, build_arguments)
        self.adapter.index = 1
        self.adapter.pending = nil
        self.adapter.states = { from_observation, to_observation }
        self.adapter.transitions = { [1] = { [name] = transition } }
        local id = next_id
        next_id = next_id + 2
        local _, _, state_payload = call_tool(self.server, self.port, id, "get_game_state")
        local state = state_payload.result.structuredContent.state
        local _, _, payload =
            call_tool(self.server, self.port, id + 1, name, build_arguments(state))
        assert_valid(name, payload)
        luaunit.assertNil(payload.result.structuredContent.resolution)
        return payload
    end

    call_action("buy_shop_item", shop_catalog_observation(), shop_after_buy_observation(), {
        next_state = 2,
        target = { argument = "item_id", reference = "shop-joker" },
    }, function(state)
        return { state_hash = state.state_hash, item_id = state.shop_items[1].id }
    end)
    call_action("buy_and_use_shop_item", shop_catalog_observation(), shop_after_use_observation(), {
        next_state = 2,
        target = { argument = "item_id", reference = "shop-planet" },
        absent_arguments = { "target_ids" },
    }, function(state)
        return { state_hash = state.state_hash, item_id = state.shop_items[2].id }
    end)
    call_action("redeem_voucher", shop_catalog_observation(), shop_after_redeem_observation(), {
        next_state = 2,
        target = { argument = "voucher_id", reference = "shop-voucher" },
    }, function(state)
        return { state_hash = state.state_hash, voucher_id = state.shop_vouchers[1].id }
    end)
    call_action("open_booster", shop_catalog_observation(), booster_decision_observation(), {
        next_state = 2,
        target = { argument = "booster_id", reference = "shop-booster" },
    }, function(state)
        return { state_hash = state.state_hash, booster_id = state.shop_boosters[1].id }
    end)
    call_action("reroll_shop", shop_catalog_observation(), shop_after_reroll_observation(), {
        next_state = 2,
    }, function(state)
        return { state_hash = state.state_hash }
    end)
    local after_leave = blind_selection_observation()
    after_leave.decision_sequence = 10
    call_action("leave_shop", shop_catalog_observation(), after_leave, {
        next_state = 2,
    }, function(state)
        return { state_hash = state.state_hash }
    end)
    local after_booster = shop_catalog_observation()
    after_booster.decision_sequence = 11
    call_action("choose_booster_item", booster_decision_observation(), after_booster, {
        next_state = 2,
        target = { argument = "item_id", reference = "pack-fool" },
        absent_arguments = { "target_ids" },
    }, function(state)
        return { state_hash = state.state_hash, item_id = state.booster_items[1].id }
    end)
    call_action("skip_booster", booster_decision_observation(), after_booster, {
        next_state = 2,
    }, function(state)
        return { state_hash = state.state_hash }
    end)
    call_action("continue_endless", victory_observation(), endless_shop_observation(), {
        next_state = 2,
    }, function(state)
        return { state_hash = state.state_hash }
    end)
    local menu = main_menu_observation()
    menu.decision_sequence = 21
    call_action("return_to_menu", victory_observation(), menu, {
        next_state = 2,
    }, function(state)
        return { state_hash = state.state_hash }
    end)
end

function TestDiscovery:test_scripted_run_path_covers_decision_loop()
    local blinds = blind_selection_observation()
    blinds.public_state.seed = "MCPTEST"
    blinds.public_state.seeded = true
    local after_booster = shop_observation()
    after_booster.decision_sequence = 11
    local menu_after = main_menu_observation()
    menu_after.decision_sequence = 21
    self.adapter.states = {
        main_menu_observation(),
        blinds,
        hand_observation(),
        shop_catalog_observation(),
        booster_decision_observation(),
        after_booster,
        victory_observation(),
        menu_after,
    }
    self.adapter.index = 1
    self.adapter.transitions = {
        [1] = {
            start_run = {
                arguments = { deck_key = "b_red", stake = 1, seed = "MCPTEST" },
                next_state = 2,
            },
        },
        [2] = {
            select_blind = {
                target = { argument = "blind_id", reference = "small-blind" },
                next_state = 3,
            },
        },
        [3] = {
            play_hand = {
                target_order = { argument = "card_ids", references = { "card-a" } },
                next_state = 4,
                events = {
                    { type = "scored", source_key = "S_A", trigger = "played", chips = 11 },
                    { type = "cash_out", money = 3 },
                },
            },
        },
        [4] = {
            open_booster = {
                target = { argument = "booster_id", reference = "shop-booster" },
                next_state = 5,
                events = { { type = "booster_opened", key = "p_arcana_normal_1", money = -4 } },
            },
        },
        [5] = {
            skip_booster = {
                next_state = 6,
                events = { { type = "booster_skipped" } },
            },
        },
        [6] = {
            leave_shop = {
                next_state = 7,
                events = { { type = "left_shop" } },
            },
        },
        [7] = {
            return_to_menu = {
                next_state = 8,
                events = { { type = "returned_to_menu" } },
            },
        },
    }

    local _, _, menu_payload = call_tool(self.server, self.port, 200, "get_game_state")
    local menu = menu_payload.result.structuredContent.state
    local _, _, started = call_tool(self.server, self.port, 201, "start_run", {
        state_hash = menu.state_hash,
        deck_key = "b_red",
        stake = 1,
        seed = "MCPTEST",
    })
    local started_state = started.result.structuredContent.state
    local _, _, selected = call_tool(self.server, self.port, 202, "select_blind", {
        state_hash = started_state.state_hash,
        blind_id = started_state.blinds[1].id,
    })
    local hand = selected.result.structuredContent.state
    local _, _, played = call_tool(self.server, self.port, 203, "play_hand", {
        state_hash = hand.state_hash,
        card_ids = { hand.hand[1].id },
    })
    local shop = played.result.structuredContent.state
    local _, _, opened = call_tool(self.server, self.port, 204, "open_booster", {
        state_hash = shop.state_hash,
        booster_id = shop.shop_boosters[1].id,
    })
    local booster = opened.result.structuredContent.state
    local _, _, skipped = call_tool(self.server, self.port, 205, "skip_booster", {
        state_hash = booster.state_hash,
    })
    local after_pack = skipped.result.structuredContent.state
    local _, _, left = call_tool(self.server, self.port, 206, "leave_shop", {
        state_hash = after_pack.state_hash,
    })
    local victory = left.result.structuredContent.state
    local _, _, finished = call_tool(self.server, self.port, 207, "return_to_menu", {
        state_hash = victory.state_hash,
    })
    local finished_state = finished.result.structuredContent.state

    luaunit.assertFalse(started.result.isError)
    luaunit.assertEquals(started_state.phase, "blind_selection")
    luaunit.assertEquals(started_state.seed, "MCPTEST")
    luaunit.assertEquals(started_state.blinds[1].name, "Small Blind")
    luaunit.assertNil(started.result.structuredContent.effect_encyclopedia)
    luaunit.assertNil(started.result.structuredContent.resolution)
    luaunit.assertEquals(selected.result.structuredContent.state.phase, "hand_play")
    luaunit.assertEquals(shop.phase, "shop")
    luaunit.assertNil(played.result.structuredContent.events)
    luaunit.assertNil(played.result.structuredContent.resolution)
    luaunit.assertEquals(booster.phase, "booster")
    luaunit.assertEquals(after_pack.phase, "shop")
    luaunit.assertEquals(victory.phase, "victory")
    luaunit.assertTrue(victory.won)
    luaunit.assertEquals(finished_state.phase, "main_menu")
end

function TestDiscovery:test_get_game_state_returns_flat_decision_snapshot()
    local body = rpc_body(3, "tools/call", { name = "get_game_state" })
    local request = make_request(self.port, body, {
        headers = { ["Mcp-Method"] = "tools/call" },
    })
    local status, _, response_body = parse_http(send_http(self.server, self.port, request))
    local payload = JSON.decode(response_body)
    local state = payload.result.structuredContent.state
    local blind = state.blinds[1]

    luaunit.assertEquals(status, 200)
    luaunit.assertEquals(payload.result.resultType, "complete")
    luaunit.assertFalse(payload.result.isError)
    luaunit.assertEquals(payload.result.content[1].type, "text")
    luaunit.assertEquals(state.server_name, "balatro-mcp")
    luaunit.assertEquals(state.server_version, "0.1.0")
    luaunit.assertEquals(state.protocol_version, "2026-07-28")
    luaunit.assertEquals(state.visibility, "fair")
    luaunit.assertEquals(state.run_id, "run-alpha")
    luaunit.assertEquals(state.decision_sequence, 7)
    luaunit.assertEquals(state.phase, "blind_selection")
    luaunit.assertEquals(state.game_version, "1.0.1o-FULL")
    luaunit.assertEquals(state.compatibility.status, "supported")
    luaunit.assertEquals(state.ante, 1)
    luaunit.assertNil(state.deck_order)
    luaunit.assertNil(state.ui)
    luaunit.assertNil(state.raw_global)
    luaunit.assertNil(state.future_prediction)
    luaunit.assertNil(blind.target_ref)
    luaunit.assertEquals(blind.id, "small-blind")
    luaunit.assertEquals(state.legal_actions[1].tool, "select_blind")
    luaunit.assertNil(state.legal_actions[1].fixed_arguments)
    luaunit.assertNil(state.legal_actions[1].parameters)
    luaunit.assertNil(state.legal_actions[1].targets)
    luaunit.assertNil(state.legal_actions[1].target_sources)
    luaunit.assertEquals(
        state.legal_actions[1].arguments.blind_id.allowed_values,
        { "small-blind" }
    )
    luaunit.assertStrMatches(
        state.state_hash,
        "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"
    )
end

function TestDiscovery:test_get_game_state_waits_for_a_stable_decision()
    self.adapter.pending = { observations = 2, next_state = 1 }
    local _, _, payload = call_tool(self.server, self.port, 4, "get_game_state")

    luaunit.assertFalse(payload.result.isError)
    luaunit.assertEquals(payload.result.structuredContent.state.phase, "blind_selection")
end

function TestDiscovery:test_decision_timeout_reaches_client_before_worker_timeout()
    local adapter = FakeBalatroAdapter.new({ states = { blind_selection_observation() } })
    adapter.pending = { observations = 100000, next_state = 1 }
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local body = rpc_body(5, "tools/call", { name = "get_game_state" })
    local request = make_request(port, body, {
        headers = { ["Mcp-Method"] = "tools/call" },
    })
    local status, _, response_body = parse_http(send_http(server, port, request))
    server:stop()

    luaunit.assertEquals(status, 200)
    luaunit.assertEquals(
        JSON.decode(response_body).result.structuredContent.code,
        "DECISION_TIMEOUT"
    )
end

function TestDiscovery:test_persistent_blocked_overlay_returns_game_blocked_after_wait()
    local adapter = FakeBalatroAdapter.new({ states = { blind_selection_observation() } })
    adapter.pending = { observations = 100000, next_state = 1, code = "GAME_BLOCKED" }
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local body = rpc_body(6, "tools/call", { name = "get_game_state" })
    local request = make_request(port, body, {
        headers = { ["Mcp-Method"] = "tools/call" },
    })
    local status, _, response_body = parse_http(send_http(server, port, request))
    server:stop()
    local error = JSON.decode(response_body).result.structuredContent

    luaunit.assertEquals(status, 200)
    luaunit.assertEquals(error.code, "GAME_BLOCKED")
    luaunit.assertNil(error.state)
    luaunit.assertTrue(adapter.observe_count > 1)
end

function TestDiscovery:test_expired_queued_action_does_not_execute_late()
    local adapter = FakeBalatroAdapter.new({
        states = { blind_selection_observation(), hand_observation() },
        transitions = { [1] = { select_blind = { next_state = 2 } } },
    })
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local _, _, state_payload = call_tool(server, port, 7, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local logs = {}
    server.log = function(level, message)
        logs[#logs + 1] = level .. " " .. message
    end
    local body = rpc_body(8, "tools/call", {
        name = "select_blind",
        arguments = { state_hash = state.state_hash, blind_id = state.blinds[1].id },
    })
    local client = assert(socket.tcp())
    client:settimeout(1)
    assert(client:connect("127.0.0.1", port))
    assert(client:send(make_request(port, body, {
        headers = { ["Mcp-Method"] = "tools/call" },
    })))
    love.timer.sleep(0.04)
    local _, _, response_body = parse_http(receive_open_http(server, client, 2))
    server:stop()
    local error = JSON.decode(response_body).result.structuredContent

    luaunit.assertEquals(error.code, "DECISION_TIMEOUT")
    luaunit.assertEquals(adapter.index, 1)
    local request_error
    for _, line in ipairs(logs) do
        if line:find("error request.error", 1, true) then
            request_error = line
        end
    end
    luaunit.assertNotNil(request_error)
    luaunit.assertStrContains(request_error, "may_have_committed=false")
    luaunit.assertStrContains(request_error, "stage=dispatch.deadline")
    luaunit.assertStrContains(request_error, "phase=blind_selection")
    luaunit.assertStrContains(request_error, "state_hash=" .. state.state_hash)
    luaunit.assertStrContains(request_error, "expected_state_hash=" .. state.state_hash)
end

function TestDiscovery:test_action_does_not_execute_when_observation_crosses_deadline()
    local adapter = FakeBalatroAdapter.new({
        states = { blind_selection_observation(), hand_observation() },
        transitions = { [1] = { select_blind = { next_state = 2 } } },
    })
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local _, _, state_payload = call_tool(server, port, 9, "get_game_state")
    local state = state_payload.result.structuredContent.state
    adapter.observe_delay_seconds = 0.03
    local _, _, action_payload = call_tool(server, port, 10, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    server:stop()

    luaunit.assertEquals(action_payload.result.structuredContent.code, "DECISION_TIMEOUT")
    luaunit.assertEquals(adapter.index, 1)
end

function TestDiscovery:test_omniscient_visibility_only_adds_current_hidden_information()
    local _, _, fair_payload = call_tool(self.server, self.port, 4, "get_game_state")
    self.server:set_visibility("omniscient")
    local _, _, omniscient_payload = call_tool(self.server, self.port, 5, "get_game_state")
    local fair = fair_payload.result.structuredContent.state
    local omniscient = omniscient_payload.result.structuredContent.state

    luaunit.assertEquals(fair.visibility, "fair")
    luaunit.assertNil(fair.deck_order)
    luaunit.assertNil(fair.facedown_cards)
    luaunit.assertEquals(omniscient.visibility, "omniscient")
    luaunit.assertEquals(omniscient.deck_order, { "S_A", "H_K" })
    luaunit.assertEquals(omniscient.facedown_cards, { { id = "hidden-card", key = "S_A" } })
    luaunit.assertNil(omniscient.raw_global)
    luaunit.assertNil(omniscient.future_prediction)
    luaunit.assertEquals(omniscient.blinds, fair.blinds)
    luaunit.assertEquals(omniscient.legal_actions, fair.legal_actions)
    luaunit.assertEquals(omniscient.phase, fair.phase)
    luaunit.assertEquals(omniscient.run_id, fair.run_id)
    luaunit.assertNotEquals(omniscient.state_hash, fair.state_hash)
end

function TestDiscovery:test_visibility_setting_controls_queries_and_invalidates_tokens()
    self.adapter:set_observation(owned_items_observation())
    local _, _, fair_payload = call_tool(self.server, self.port, 500, "get_game_state")
    local fair = fair_payload.result.structuredContent.state
    local hidden_id = fair.hand[3].id

    luaunit.assertEquals(fair.visibility, "fair")
    luaunit.assertNil(fair.deck_order)
    luaunit.assertStrMatches(hidden_id, "^h:%d+$")

    local _, _, state_rejected = call_tool(self.server, self.port, 501, "get_game_state", {
        visibility = "omniscient",
    })
    local _, _, encyclopedia_rejected =
        call_tool(self.server, self.port, 502, "get_effect_encyclopedia", {
            visibility = "omniscient",
        })
    luaunit.assertTrue(state_rejected.result.isError)
    luaunit.assertEquals(state_rejected.result.structuredContent.code, "INVALID_PARAMS")
    luaunit.assertTrue(encyclopedia_rejected.result.isError)
    luaunit.assertEquals(encyclopedia_rejected.result.structuredContent.code, "INVALID_PARAMS")

    self.server:set_visibility("omniscient")
    local _, _, omniscient_payload = call_tool(self.server, self.port, 503, "get_game_state")
    local omniscient = omniscient_payload.result.structuredContent.state
    luaunit.assertEquals(omniscient.visibility, "omniscient")
    luaunit.assertEquals(omniscient.deck_order, { "C_2", "S_2" })
    luaunit.assertNotEquals(omniscient.state_hash, fair.state_hash)
    luaunit.assertEquals(omniscient.hand[1].id, fair.hand[1].id)
    luaunit.assertNotEquals(omniscient.hand[3].id, hidden_id)

    local _, _, stale = call_tool(self.server, self.port, 504, "reorder_cards", {
        state_hash = fair.state_hash,
        area = "hand",
        ordered_ids = { fair.hand[1].id, fair.hand[2].id, hidden_id },
    })
    luaunit.assertTrue(stale.result.isError)
    luaunit.assertEquals(stale.result.structuredContent.code, "STALE_STATE")
    luaunit.assertEquals(stale.result.structuredContent.state.visibility, "omniscient")
    luaunit.assertEquals(stale.result.structuredContent.state.state_hash, omniscient.state_hash)
    luaunit.assertNotEquals(stale.result.structuredContent.state.hand[3].id, hidden_id)

    local _, _, stale_hidden_id = call_tool(self.server, self.port, 506, "reorder_cards", {
        state_hash = omniscient.state_hash,
        area = "hand",
        ordered_ids = { omniscient.hand[1].id, omniscient.hand[2].id, hidden_id },
    })
    luaunit.assertTrue(stale_hidden_id.result.isError)
    luaunit.assertEquals(stale_hidden_id.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertEquals(
        stale_hidden_id.result.structuredContent.state.state_hash,
        omniscient.state_hash
    )

    local _, _, encyclopedia = call_tool(self.server, self.port, 505, "get_effect_encyclopedia")
    luaunit.assertEquals(
        encyclopedia.result.structuredContent.effect_encyclopedia.visibility,
        "omniscient"
    )
end

function TestDiscovery:test_state_hash_is_canonical_and_ignores_ui_only_changes()
    local _, _, initial_payload = call_tool(self.server, self.port, 6, "get_game_state")
    local initial_hash = initial_payload.result.structuredContent.state.state_hash

    self.adapter:set_ui({
        hovered_target = "boss-blind",
        highlighted = { "small-blind" },
        expanded_description = "small-blind",
        sort_mode = "suit desc",
    })
    local _, _, ui_payload = call_tool(self.server, self.port, 7, "get_game_state")
    luaunit.assertEquals(ui_payload.result.structuredContent.state.state_hash, initial_hash)

    local equivalent = blind_selection_observation()
    local original_state = equivalent.public_state
    equivalent.public_state = {}
    for _, key in ipairs({
        "legal_actions",
        "blinds",
        "money",
        "ante",
        "active_mods",
        "compatibility",
        "lovely_version",
        "steamodded_version",
        "game_version",
    }) do
        equivalent.public_state[key] = original_state[key]
    end
    self.adapter:set_observation(equivalent)
    local _, _, equivalent_payload = call_tool(self.server, self.port, 8, "get_game_state")
    luaunit.assertEquals(equivalent_payload.result.structuredContent.state.state_hash, initial_hash)

    local semantic_change = blind_selection_observation()
    semantic_change.public_state.money = 5
    self.adapter:set_observation(semantic_change)
    local _, _, semantic_payload = call_tool(self.server, self.port, 8, "get_game_state")
    luaunit.assertNotEquals(
        semantic_payload.result.structuredContent.state.state_hash,
        initial_hash
    )

    local next_decision = blind_selection_observation()
    next_decision.decision_sequence = 8
    self.adapter:set_observation(next_decision)
    local _, _, sequence_payload = call_tool(self.server, self.port, 9, "get_game_state")
    luaunit.assertNotEquals(
        sequence_payload.result.structuredContent.state.state_hash,
        initial_hash
    )

    local next_run = blind_selection_observation()
    next_run.run_id = "run-beta"
    self.adapter:set_observation(next_run)
    local _, _, run_payload = call_tool(self.server, self.port, 10, "get_game_state")
    luaunit.assertNotEquals(run_payload.result.structuredContent.state.state_hash, initial_hash)
end

function TestDiscovery:test_hand_order_changes_hash_and_invalidates_old_actions()
    self.adapter:set_observation(hand_observation())
    self.adapter.transitions[1].play_hand = {
        next_state = 2,
        target_order = {
            argument = "card_ids",
            references = { "card-a", "card-b" },
        },
    }
    local _, _, first_payload = call_tool(self.server, self.port, 60, "get_game_state")
    local first = first_payload.result.structuredContent.state
    local sorted = hand_observation()
    sorted.public_state.hand = {
        sorted.public_state.hand[3],
        sorted.public_state.hand[2],
        sorted.public_state.hand[1],
    }
    local reversed_refs = { "card-c", "card-b", "card-a" }
    for _, action in ipairs(sorted.public_state.legal_actions) do
        if action.target_refs and action.target_refs.card_ids then
            action.target_refs.card_ids = reversed_refs
        end
    end
    self.adapter:set_observation(sorted)
    local _, _, sorted_payload = call_tool(self.server, self.port, 61, "get_game_state")
    local sorted_state = sorted_payload.result.structuredContent.state
    local ids = {}
    for _, card in ipairs(first.hand) do
        ids[card.key] = card.id
    end

    luaunit.assertNotEquals(sorted_state.state_hash, first.state_hash)
    luaunit.assertEquals(sorted_state.hand[1].id, ids.D_Q)
    luaunit.assertEquals(sorted_state.hand[3].id, ids.S_A)

    local _, _, play_payload = call_tool(self.server, self.port, 62, "play_hand", {
        state_hash = first.state_hash,
        card_ids = { ids.S_A, ids.H_K },
    })
    luaunit.assertTrue(play_payload.result.isError)
    luaunit.assertEquals(play_payload.result.structuredContent.code, "STALE_STATE")
    luaunit.assertEquals(
        play_payload.result.structuredContent.state.state_hash,
        sorted_state.state_hash
    )
end

function TestDiscovery:test_duplicate_card_keys_keep_distinct_target_ids()
    local observation = hand_observation()
    observation.public_state.hand[1].target_ref = "card:12"
    observation.public_state.hand[2].target_ref = "card:13"
    observation.public_state.hand[2].key = "S_A"
    observation.public_state.hand[2].name = "Ace of Spades"
    observation.public_state.hand[2].suit = "Spades"
    observation.public_state.hand[2].rank = "Ace"
    observation.public_state.hand[2].chips = 11
    for _, action in ipairs(observation.public_state.legal_actions) do
        action.target_refs.card_ids = { "card:12", "card:13", "card-c" }
    end
    self.adapter:set_observation(observation)
    local _, _, payload = call_tool(self.server, self.port, 70, "get_game_state")
    local state = payload.result.structuredContent.state

    luaunit.assertEquals(state.hand[1].key, "S_A")
    luaunit.assertEquals(state.hand[2].key, "S_A")
    luaunit.assertEquals(state.hand[1].id, "card:12")
    luaunit.assertEquals(state.hand[2].id, "card:13")
    luaunit.assertNil(state.legal_actions[2].targets)
    luaunit.assertNil(state.legal_actions[2].target_sources)
    luaunit.assertEquals(
        state.legal_actions[2].arguments.card_ids.allowed_values,
        { "card:12", "card:13", "card-c" }
    )
end

function TestDiscovery:test_old_hash_is_stale_when_visible_cards_repeat()
    self.adapter:set_observation(hand_observation())
    local _, _, first_payload = call_tool(self.server, self.port, 71, "get_game_state")
    local first = first_payload.result.structuredContent.state
    local later = hand_observation()
    later.decision_sequence = first.decision_sequence + 1
    self.adapter:set_observation(later)
    local _, _, stale_payload = call_tool(self.server, self.port, 72, "play_hand", {
        state_hash = first.state_hash,
        card_ids = { first.hand[1].id },
    })

    luaunit.assertTrue(stale_payload.result.isError)
    luaunit.assertEquals(stale_payload.result.structuredContent.code, "STALE_STATE")
    luaunit.assertEquals(
        stale_payload.result.structuredContent.state.hand[1].key,
        first.hand[1].key
    )
    luaunit.assertEquals(stale_payload.result.structuredContent.state.hand[1].id, first.hand[1].id)
    luaunit.assertNotEquals(
        stale_payload.result.structuredContent.state.state_hash,
        first.state_hash
    )
end

function TestDiscovery:test_target_ids_can_reappear_but_need_current_hash()
    self.adapter:set_observation(hand_observation())
    self.adapter.states[2] = hand_observation()
    self.adapter.states[2].decision_sequence = 9
    self.adapter.transitions[1].play_hand = {
        next_state = 2,
        target_order = { argument = "card_ids", references = { "card-a" } },
    }
    self.adapter.transitions[2] = {
        play_hand = {
            next_state = 2,
            target_order = { argument = "card_ids", references = { "card-a" } },
        },
    }
    local _, _, first_payload = call_tool(self.server, self.port, 73, "get_game_state")
    local first = first_payload.result.structuredContent.state
    local reused_id = first.hand[1].id
    local _, _, played = call_tool(self.server, self.port, 74, "play_hand", {
        state_hash = first.state_hash,
        card_ids = { reused_id },
    })
    local next_state = played.result.structuredContent.state
    local _, _, stale = call_tool(self.server, self.port, 75, "play_hand", {
        state_hash = first.state_hash,
        card_ids = { reused_id },
    })
    local _, _, again = call_tool(self.server, self.port, 76, "play_hand", {
        state_hash = next_state.state_hash,
        card_ids = { reused_id },
    })

    luaunit.assertFalse(played.result.isError)
    luaunit.assertEquals(reused_id, "card-a")
    luaunit.assertEquals(next_state.hand[1].id, reused_id)
    luaunit.assertNotEquals(next_state.state_hash, first.state_hash)
    luaunit.assertTrue(stale.result.isError)
    luaunit.assertEquals(stale.result.structuredContent.code, "STALE_STATE")
    luaunit.assertFalse(again.result.isError)
end

function TestDiscovery:test_human_semantic_change_returns_stale_state()
    local _, _, first_payload = call_tool(self.server, self.port, 63, "get_game_state")
    local first = first_payload.result.structuredContent.state
    local after_buy = blind_selection_observation()
    after_buy.decision_sequence = first.decision_sequence + 1
    after_buy.public_state.money = 1
    self.adapter:set_observation(after_buy)
    local _, _, stale_payload = call_tool(self.server, self.port, 64, "select_blind", {
        state_hash = first.state_hash,
        blind_id = first.blinds[1].id,
    })
    local error = stale_payload.result.structuredContent

    luaunit.assertTrue(stale_payload.result.isError)
    luaunit.assertEquals(error.code, "STALE_STATE")
    luaunit.assertEquals(error.state.money, 1)
    luaunit.assertEquals(error.state.decision_sequence, first.decision_sequence + 1)
end

function TestDiscovery:test_extra_content_mods_are_unsupported_but_actions_continue()
    local observation = blind_selection_observation()
    observation.public_state.active_mods = {
        { id = "balatro-mcp", name = "Balatro MCP", version = "0.6.1" },
        { id = "MoreJokers", name = "More Jokers", version = "1.0.0" },
    }
    observation.public_state.compatibility = {
        status = "unsupported",
        content_mods = "unsupported",
        versions = "supported",
    }
    self.adapter:set_observation(observation)
    local list_body = rpc_body(65, "tools/list")
    local list_request = make_request(self.port, list_body, {
        headers = { ["Mcp-Method"] = "tools/list" },
    })
    local _, _, list_response = parse_http(send_http(self.server, self.port, list_request))
    local list_payload = JSON.decode(list_response)
    local _, _, state_payload = call_tool(self.server, self.port, 66, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 67, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })

    luaunit.assertEquals(#list_payload.result.tools, 21)
    luaunit.assertEquals(state.compatibility.status, "unsupported")
    luaunit.assertEquals(state.compatibility.content_mods, "unsupported")
    luaunit.assertEquals(state.active_mods, {
        { id = "balatro-mcp", name = "Balatro MCP", version = "0.6.1" },
        { id = "MoreJokers", name = "More Jokers", version = "1.0.0" },
    })
    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertEquals(action_payload.result.structuredContent.state.phase, "hand_play")
end

function TestDiscovery:test_below_minimum_versions_disable_actions()
    local observation = blind_selection_observation()
    observation.public_state.game_version = "1.0.0"
    observation.public_state.compatibility = {
        status = "unsupported",
        content_mods = "supported",
        versions = "unsupported",
        diagnostic = "Balatro 1.0.0 is below 1.0.1o-FULL",
    }
    self.adapter:set_observation(observation)
    local _, _, state_payload = call_tool(self.server, self.port, 68, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 69, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    local error = action_payload.result.structuredContent

    luaunit.assertFalse(state_payload.result.isError)
    luaunit.assertEquals(state.compatibility.versions, "unsupported")
    luaunit.assertStrContains(state.compatibility.diagnostic, "1.0.0")
    luaunit.assertTrue(action_payload.result.isError)
    luaunit.assertEquals(error.code, "INCOMPATIBLE_VERSION")
    luaunit.assertEquals(error.state.state_hash, state.state_hash)
end

function TestDiscovery:test_newer_unverified_versions_remain_compatible()
    local observation = blind_selection_observation()
    observation.public_state.game_version = "1.0.1z-FULL"
    observation.public_state.lovely_version = "1.4.0"
    observation.public_state.steamodded_version = "1.0.0~BETA-9999z"
    self.adapter:set_observation(observation)
    local _, _, state_payload = call_tool(self.server, self.port, 70, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 71, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })

    luaunit.assertEquals(state.game_version, "1.0.1z-FULL")
    luaunit.assertEquals(state.compatibility.status, "supported")
    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertEquals(action_payload.result.structuredContent.state.phase, "hand_play")
end

function TestDiscovery:test_start_run_rejects_invalid_seed()
    self.adapter:set_observation(main_menu_observation())
    local _, _, state_payload = call_tool(self.server, self.port, 10, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 11, "start_run", {
        state_hash = state.state_hash,
        deck_key = "b_red",
        stake = 1,
        seed = "bad0seed",
    })

    luaunit.assertTrue(action_payload.result.isError)
    luaunit.assertEquals(action_payload.result.structuredContent.code, "INVALID_PARAMS")
end

function TestDiscovery:test_start_run_forwards_deck_stake_and_seed()
    self.adapter:set_observation(main_menu_observation())
    local next_state = blind_selection_observation()
    next_state.public_state.seed = "TEST123"
    next_state.public_state.seeded = true
    self.adapter.states[2] = next_state
    self.adapter.transitions[1].start_run = {
        arguments = { deck_key = "b_red", stake = 1, seed = "TEST123" },
        pending = { observations = 1, next_state = 2 },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 12, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local logs = {}
    self.server.log_enabled = function(level)
        return level ~= "debug"
    end
    self.server.log = function(level, message)
        logs[#logs + 1] = level .. " " .. message
    end
    local _, _, action_payload = call_tool(self.server, self.port, 13, "start_run", {
        state_hash = state.state_hash,
        deck_key = "b_red",
        stake = 1,
        seed = "TEST123",
    })

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertEquals(action_payload.result.structuredContent.state.phase, "blind_selection")
    luaunit.assertEquals(action_payload.result.structuredContent.state.seed, "TEST123")
    luaunit.assertTrue(action_payload.result.structuredContent.state.seeded)
    local run_begin
    for _, line in ipairs(logs) do
        if line:find("info run.begin", 1, true) then
            run_begin = line
        end
    end
    luaunit.assertNotNil(run_begin)
    luaunit.assertStrContains(run_begin, "deck=b_red")
    luaunit.assertStrContains(run_begin, "seed=TEST123")
    luaunit.assertStrContains(run_begin, "stake=1")
end

function TestDiscovery:test_start_run_without_seed_preserves_normal_run_mode()
    self.adapter:set_observation(main_menu_observation())
    local next_state = blind_selection_observation()
    next_state.public_state.seed = "RANDOM"
    next_state.public_state.seeded = false
    self.adapter.states[2] = next_state
    self.adapter.transitions[1].start_run = {
        arguments = { deck_key = "b_red", stake = 1 },
        absent_arguments = { "seed" },
        pending = { observations = 1, next_state = 2 },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 14, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 15, "start_run", {
        state_hash = state.state_hash,
        deck_key = "b_red",
        stake = 1,
    })

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertFalse(action_payload.result.structuredContent.state.seeded)
    luaunit.assertNil(action_payload.result.structuredContent.effect_encyclopedia)
end

function TestDiscovery:test_start_run_returns_full_next_state_without_encyclopedia()
    self.adapter:set_observation(main_menu_observation())
    self.adapter.states[2] = blind_selection_observation()
    self.adapter.transitions[1].start_run = {
        arguments = { deck_key = "b_red", stake = 1 },
        absent_arguments = { "seed" },
        next_state = 2,
    }
    local _, _, menu_payload = call_tool(self.server, self.port, 20, "get_game_state")
    local menu = menu_payload.result.structuredContent.state
    local _, _, started = call_tool(self.server, self.port, 22, "start_run", {
        state_hash = menu.state_hash,
        deck_key = "b_red",
        stake = 1,
    })
    local result = assert_semantic_envelope(started, false)
    local _, _, after = call_tool(self.server, self.port, 23, "get_game_state")
    local full = after.result.structuredContent.state

    luaunit.assertEquals(result.state.phase, "blind_selection")
    luaunit.assertEquals(result.state.blinds[1].name, "Small Blind")
    luaunit.assertEquals(result.state.blinds[1].description, "Score at least 300 chips.")
    luaunit.assertEquals(result.state.game_version, "1.0.1o-FULL")
    luaunit.assertEquals(result.state.legal_actions[1].tool, "select_blind")
    luaunit.assertEquals(result.state, full)
    luaunit.assertNil(full.detail)
    luaunit.assertNil(after.result.structuredContent.effect_encyclopedia)
end

function TestDiscovery:test_start_run_rejects_visibility_and_omits_encyclopedia_on_failure()
    self.adapter:set_observation(main_menu_observation())
    local _, _, menu_payload = call_tool(self.server, self.port, 24, "get_game_state")
    local menu = menu_payload.result.structuredContent.state
    local _, _, with_visibility = call_tool(self.server, self.port, 25, "start_run", {
        state_hash = menu.state_hash,
        deck_key = "b_red",
        stake = 1,
        visibility = "omniscient",
    })
    local _, _, bad_seed = call_tool(self.server, self.port, 26, "start_run", {
        state_hash = menu.state_hash,
        deck_key = "b_red",
        stake = 1,
        seed = "bad0seed",
    })

    luaunit.assertTrue(with_visibility.result.isError)
    luaunit.assertEquals(with_visibility.result.structuredContent.code, "INVALID_PARAMS")
    luaunit.assertNil(with_visibility.result.structuredContent.effect_encyclopedia)
    luaunit.assertNil(with_visibility.result.structuredContent.resolution)
    luaunit.assertEquals(
        with_visibility.result.structuredContent.state.available_decks[1].name,
        "Red Deck"
    )
    luaunit.assertEquals(
        with_visibility.result.structuredContent.state.legal_actions[1].tool,
        "start_run"
    )
    luaunit.assertTrue(bad_seed.result.isError)
    luaunit.assertEquals(bad_seed.result.structuredContent.code, "INVALID_PARAMS")
    luaunit.assertNil(bad_seed.result.structuredContent.effect_encyclopedia)
    luaunit.assertNil(bad_seed.result.structuredContent.resolution)
    luaunit.assertEquals(bad_seed.result.structuredContent.state.legal_actions[1].tool, "start_run")
end

function TestDiscovery:test_other_actions_do_not_attach_encyclopedia()
    local _, _, state_payload = call_tool(self.server, self.port, 27, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, selected = call_tool(self.server, self.port, 28, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    local _, _, stale = call_tool(self.server, self.port, 29, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })

    luaunit.assertFalse(selected.result.isError)
    luaunit.assertNil(selected.result.structuredContent.effect_encyclopedia)
    luaunit.assertNil(JSON.decode(selected.result.content[1].text).effect_encyclopedia)
    luaunit.assertTrue(stale.result.isError)
    luaunit.assertEquals(stale.result.structuredContent.code, "STALE_STATE")
    luaunit.assertNil(stale.result.structuredContent.effect_encyclopedia)
    luaunit.assertNil(JSON.decode(stale.result.content[1].text).effect_encyclopedia)
end

function TestDiscovery:test_start_run_timeout_does_not_attach_encyclopedia()
    local adapter = FakeBalatroAdapter.new({
        states = { main_menu_observation(), blind_selection_observation() },
        transitions = {
            [1] = {
                start_run = {
                    arguments = { deck_key = "b_red", stake = 1 },
                    pending = { observations = 100000, next_state = 2 },
                },
            },
        },
    })
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local _, _, menu_payload = call_tool(server, port, 30, "get_game_state")
    local menu = menu_payload.result.structuredContent.state
    local _, _, started = call_tool(server, port, 31, "start_run", {
        state_hash = menu.state_hash,
        deck_key = "b_red",
        stake = 1,
    })
    server:stop()

    luaunit.assertTrue(started.result.isError)
    luaunit.assertEquals(started.result.structuredContent.code, "DECISION_TIMEOUT")
    luaunit.assertNil(started.result.structuredContent.effect_encyclopedia)
    luaunit.assertNil(started.result.structuredContent.resolution)
    luaunit.assertNil(started.result.structuredContent.state)
    luaunit.assertStrContains(started.result.content[1].text, '"state":null')
end

function TestDiscovery:test_start_run_does_not_require_encyclopedia()
    self.adapter:set_observation(main_menu_observation())
    self.adapter.states[2] = blind_selection_observation()
    self.adapter.transitions[1].start_run = {
        arguments = { deck_key = "b_red", stake = 1 },
        absent_arguments = { "seed" },
        next_state = 2,
    }
    self.adapter.encyclopedia = function()
        return nil, { code = "INTERNAL_ERROR", message = "encyclopedia down" }
    end
    local _, _, menu_payload = call_tool(self.server, self.port, 32, "get_game_state")
    local menu = menu_payload.result.structuredContent.state
    local _, _, started = call_tool(self.server, self.port, 33, "start_run", {
        state_hash = menu.state_hash,
        deck_key = "b_red",
        stake = 1,
    })
    local result = assert_semantic_envelope(started, false)
    local _, _, after = call_tool(self.server, self.port, 34, "get_game_state")

    luaunit.assertEquals(result.state.phase, "blind_selection")
    luaunit.assertEquals(after.result.structuredContent.state.phase, "blind_selection")
    luaunit.assertEquals(after.result.structuredContent.state.state_hash, result.state.state_hash)
end

function TestDiscovery:test_action_resolves_snapshot_target_and_returns_next_state()
    local _, _, state_payload = call_tool(self.server, self.port, 10, "get_game_state")
    local state = state_payload.result.structuredContent.state
    self.adapter.transitions[1].select_blind.expected_state_hash = state.state_hash
    local _, _, action_payload = call_tool(self.server, self.port, 11, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertEquals(action_payload.result.structuredContent.state.phase, "hand_play")
    luaunit.assertEquals(action_payload.result.structuredContent.state.decision_sequence, 8)
    luaunit.assertNil(action_payload.result.structuredContent.events)
    luaunit.assertNil(action_payload.result.structuredContent.resolution)
end

function TestDiscovery:test_action_response_returns_full_next_state()
    local next_hand = hand_observation()
    next_hand.public_state.jokers = {
        {
            target_ref = "joker-left",
            key = "j_joker",
            name = "Joker",
            description = "+4 Mult",
            sell_value = 1,
            debuffed = false,
            edition = {
                key = "e_foil",
                name = "Foil",
                description = "+50 Chips",
            },
        },
    }
    next_hand.public_state.hand[1].enhancement = {
        key = "m_bonus",
        name = "Bonus Card",
        description = "+30 chips",
    }
    next_hand.public_state.hand[1].seal = {
        key = "red_seal",
        name = "Red Seal",
        description = "Retrigger this card 1 time",
    }
    self.adapter.states[2] = next_hand

    local _, _, state_payload = call_tool(self.server, self.port, 12, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 13, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    local next_state = assert_semantic_envelope(action_payload, false).state

    luaunit.assertNil(state.detail)
    luaunit.assertEquals(state.blinds[1].name, "Small Blind")
    luaunit.assertEquals(state.blinds[1].description, "Score at least 300 chips.")
    luaunit.assertEquals(next_state.hand[1].key, "S_A")
    luaunit.assertNotNil(next_state.hand[1].id)
    luaunit.assertEquals(next_state.hand[1].chips, 11)
    luaunit.assertFalse(next_state.hand[1].debuffed)
    luaunit.assertEquals(next_state.hand[1].name, "Ace of Spades")
    luaunit.assertEquals(next_state.hand[1].suit, "Spades")
    luaunit.assertEquals(next_state.hand[1].rank, "Ace")
    luaunit.assertEquals(next_state.hand[1].enhancement.key, "m_bonus")
    luaunit.assertEquals(next_state.hand[1].enhancement.name, "Bonus Card")
    luaunit.assertEquals(next_state.hand[1].enhancement.description, "+30 chips")
    luaunit.assertEquals(next_state.hand[1].seal.key, "red_seal")
    luaunit.assertEquals(next_state.hand[1].seal.name, "Red Seal")
    luaunit.assertEquals(next_state.hand[1].seal.description, "Retrigger this card 1 time")
    luaunit.assertEquals(next_state.current_blind.key, "bl_small")
    luaunit.assertEquals(next_state.current_blind.chips, 300)
    luaunit.assertEquals(next_state.current_blind.name, "Small Blind")
    luaunit.assertEquals(next_state.jokers[1].key, "j_joker")
    luaunit.assertEquals(next_state.jokers[1].id, "joker-left")
    luaunit.assertEquals(next_state.jokers[1].sell_value, 1)
    luaunit.assertFalse(next_state.jokers[1].debuffed)
    luaunit.assertEquals(next_state.jokers[1].name, "Joker")
    luaunit.assertEquals(next_state.jokers[1].description, "+4 Mult")
    luaunit.assertEquals(next_state.jokers[1].edition.key, "e_foil")
    luaunit.assertEquals(next_state.jokers[1].edition.name, "Foil")
    luaunit.assertEquals(next_state.jokers[1].edition.description, "+50 Chips")
    luaunit.assertEquals(next_state.remaining_deck[1], {
        key = "C_2",
        name = "2 of Clubs",
        count = 1,
    })
    luaunit.assertEquals(next_state.poker_hands[1].name, "Pair")
    luaunit.assertEquals(next_state.poker_hands[1].key, "Pair")
    luaunit.assertEquals(next_state.poker_hands[1].chips, 10)
    luaunit.assertEquals(next_state.game_version, "1.0.1o-FULL")
    luaunit.assertEquals(next_state.steamodded_version, "1.0.0~BETA-2014b")
    luaunit.assertEquals(next_state.lovely_version, "0.9.0")
    luaunit.assertEquals(next_state.active_mods, default_active_mods)
    luaunit.assertEquals(next_state.compatibility.content_mods, "supported")
    luaunit.assertNil(next_state.legal_actions[1].targets)
    luaunit.assertNil(next_state.legal_actions[1].target_sources)
    luaunit.assertEquals(
        next_state.legal_actions[1].arguments.card_ids.allowed_values,
        { "card-a", "card-b", "card-c" }
    )

    local _, _, full_payload = call_tool(self.server, self.port, 14, "get_game_state")
    local full = full_payload.result.structuredContent.state
    luaunit.assertNil(full.detail)
    luaunit.assertEquals(full, next_state)

    self.adapter.transitions[2] = {
        play_hand = {
            next_state = 2,
            target_order = { argument = "card_ids", references = { "card-a" } },
        },
    }
    local _, _, played = call_tool(self.server, self.port, 15, "play_hand", {
        state_hash = next_state.state_hash,
        card_ids = { next_state.hand[1].id },
    })
    luaunit.assertFalse(played.result.isError)
    luaunit.assertNil(played.result.structuredContent.resolution)
end

function TestDiscovery:test_content_text_is_structured_json()
    local _, _, state_payload = call_tool(self.server, self.port, 12, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local query = JSON.decode(state_payload.result.content[1].text)
    luaunit.assertNil(state.detail)
    luaunit.assertEquals(query, state_payload.result.structuredContent)
    luaunit.assertEquals(query.state.blinds[1].id, state.blinds[1].id)
    luaunit.assertEquals(
        query.state.legal_actions[1].arguments.blind_id.allowed_values,
        { "small-blind" }
    )

    local _, _, action_payload = call_tool(self.server, self.port, 13, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    local result = assert_semantic_envelope(action_payload, false)
    luaunit.assertEquals(result.state.phase, "hand_play")
    luaunit.assertEquals(result.state.current_blind.name, "Small Blind")
    luaunit.assertNotNil(result.state.legal_actions)

    local _, _, stale_payload = call_tool(self.server, self.port, 14, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    local error = assert_semantic_envelope(stale_payload, true)
    luaunit.assertEquals(error.code, "STALE_STATE")
    luaunit.assertNotNil(error.message)
    luaunit.assertEquals(error.state.phase, "hand_play")
    luaunit.assertEquals(error.state.current_blind.name, "Small Blind")
    luaunit.assertEquals(error.state.legal_actions[1].tool, "play_hand")
end

function TestDiscovery:test_legal_actions_list_current_allowed_values()
    local observation = hand_observation()
    observation.public_state.legal_actions[1].target_refs.card_ids = { "card-a", "card-b" }
    self.adapter:set_observation(observation)
    local _, _, state_payload = call_tool(self.server, self.port, 16, "get_game_state")
    local full = state_payload.result.structuredContent.state
    local play = full.legal_actions[1]
    local discard = full.legal_actions[2]

    luaunit.assertNil(full.detail)
    luaunit.assertNil(play.targets)
    luaunit.assertNil(play.target_sources)
    luaunit.assertNil(play.parameters)
    luaunit.assertEquals(play.arguments.card_ids.allowed_values, { "card-a", "card-b" })
    luaunit.assertEquals(play.arguments.card_ids.min_items, 1)
    luaunit.assertEquals(play.arguments.card_ids.max_items, 2)
    luaunit.assertTrue(play.arguments.card_ids.unique_items)
    luaunit.assertTrue(play.arguments.card_ids.ordered)
    luaunit.assertNil(play.arguments.card_ids.complete)
    luaunit.assertEquals(discard.arguments.card_ids.allowed_values, {
        "card-a",
        "card-b",
        "card-c",
    })

    local _, _, excluded = call_tool(self.server, self.port, 18, "play_hand", {
        state_hash = full.state_hash,
        card_ids = { full.hand[3].id },
    })
    luaunit.assertTrue(excluded.result.isError)
    luaunit.assertEquals(excluded.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertStrContains(
        excluded.result.structuredContent.message,
        "allowed values: card-a, card-b"
    )

    local _, _, invented = call_tool(self.server, self.port, 19, "discard_cards", {
        state_hash = full.state_hash,
        card_ids = { "hand" },
    })
    luaunit.assertTrue(invented.result.isError)
    luaunit.assertEquals(invented.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertStrContains(
        invented.result.structuredContent.message,
        "allowed values: card-a, card-b, card-c"
    )
end

function TestDiscovery:test_legal_action_variants_are_not_merged()
    self.adapter:set_observation(owned_items_observation())
    local _, _, payload = call_tool(self.server, self.port, 80, "get_game_state")
    local state = payload.result.structuredContent.state
    local hidden_id = state.hand[3].id
    local reorder_hand = state.legal_actions[1]
    local reorder_jokers = state.legal_actions[2]
    local planet = state.legal_actions[3]
    local strength = state.legal_actions[4]

    luaunit.assertEquals(reorder_hand.tool, "reorder_cards")
    luaunit.assertEquals(reorder_hand.fixed_arguments.area, "hand")
    luaunit.assertEquals(reorder_hand.arguments.ordered_ids.allowed_values, {
        "card-a",
        "card-b",
        hidden_id,
    })
    luaunit.assertTrue(reorder_hand.arguments.ordered_ids.complete)
    luaunit.assertTrue(reorder_hand.arguments.ordered_ids.unique_items)
    luaunit.assertTrue(reorder_hand.arguments.ordered_ids.ordered)
    luaunit.assertEquals(reorder_jokers.tool, "reorder_cards")
    luaunit.assertEquals(reorder_jokers.fixed_arguments.area, "jokers")
    luaunit.assertEquals(reorder_jokers.arguments.ordered_ids.allowed_values, {
        "joker-left",
        "joker-right",
    })

    luaunit.assertEquals(planet.tool, "use_consumable")
    luaunit.assertEquals(planet.fixed_arguments.consumable_id, "planet-pluto")
    luaunit.assertNil(planet.arguments)
    luaunit.assertEquals(strength.tool, "use_consumable")
    luaunit.assertEquals(strength.fixed_arguments.consumable_id, "tarot-strength")
    luaunit.assertEquals(strength.arguments.target_ids.allowed_values, {
        "card-a",
        "card-b",
        hidden_id,
    })
    luaunit.assertEquals(strength.arguments.target_ids.min_items, 1)
    luaunit.assertEquals(strength.arguments.target_ids.max_items, 2)
    luaunit.assertTrue(strength.arguments.target_ids.ordered)
    luaunit.assertNil(strength.arguments.target_ids.complete)
end

function TestDiscovery:test_shop_consumable_variants_keep_separate_target_bounds()
    self.adapter:set_observation(shop_catalog_observation())
    local _, _, payload = call_tool(self.server, self.port, 81, "get_game_state")
    local state = payload.result.structuredContent.state
    local buy = state.legal_actions[1]
    local planet = state.legal_actions[2]
    local strength = state.legal_actions[3]

    luaunit.assertEquals(buy.tool, "buy_shop_item")
    luaunit.assertEquals(buy.arguments.item_id.allowed_values, {
        "shop-joker",
        "shop-planet",
        "shop-card",
        "shop-strength",
    })
    luaunit.assertEquals(planet.tool, "buy_and_use_shop_item")
    luaunit.assertEquals(planet.fixed_arguments.item_id, "shop-planet")
    luaunit.assertNil(planet.arguments)
    luaunit.assertEquals(strength.tool, "buy_and_use_shop_item")
    luaunit.assertEquals(strength.fixed_arguments.item_id, "shop-strength")
    luaunit.assertEquals(strength.arguments.target_ids.min_items, 1)
    luaunit.assertEquals(strength.arguments.target_ids.max_items, 2)
    luaunit.assertEquals(strength.arguments.target_ids.allowed_values, { "hand-a", "hand-b" })
end

function TestDiscovery:test_booster_item_variants_are_not_merged()
    self.adapter:set_observation(booster_pack_observation(
        "arcana",
        {
            {
                target_ref = "pack-fool",
                category = "consumable",
                key = "c_fool",
                name = "The Fool",
            },
            {
                target_ref = "pack-strength",
                category = "consumable",
                key = "c_strength",
                name = "Strength",
                min_targets = 1,
                max_targets = 2,
            },
        },
        1,
        {
            hand = {
                { target_ref = "hand-a", key = "H_K", name = "King of Hearts" },
                { target_ref = "hand-b", key = "S_A", name = "Ace of Spades" },
            },
            legal_actions = {
                {
                    tool = "choose_booster_item",
                    target_refs = { item_id = { "pack-fool" } },
                },
                {
                    tool = "choose_booster_item",
                    fixed_target_refs = { item_id = "pack-strength" },
                    target_refs = { target_ids = { "hand-a", "hand-b" } },
                    arguments = { target_ids = { min_items = 1, max_items = 2 } },
                },
                { tool = "skip_booster" },
            },
        }
    ))
    local _, _, payload = call_tool(self.server, self.port, 88, "get_game_state")
    local state = payload.result.structuredContent.state
    local fool = state.legal_actions[1]
    local strength = state.legal_actions[2]

    luaunit.assertEquals(fool.tool, "choose_booster_item")
    luaunit.assertNil(fool.fixed_arguments)
    luaunit.assertEquals(fool.arguments.item_id.allowed_values, { "pack-fool" })
    luaunit.assertNil(fool.arguments.target_ids)
    luaunit.assertEquals(strength.tool, "choose_booster_item")
    luaunit.assertEquals(strength.fixed_arguments.item_id, "pack-strength")
    luaunit.assertEquals(strength.arguments.target_ids.min_items, 1)
    luaunit.assertEquals(strength.arguments.target_ids.max_items, 2)
    luaunit.assertEquals(strength.arguments.target_ids.allowed_values, { "hand-a", "hand-b" })
end

function TestDiscovery:test_legal_actions_omit_static_schema()
    self.adapter:set_observation(main_menu_observation())
    local _, _, payload = call_tool(self.server, self.port, 82, "get_game_state")
    local start_run = payload.result.structuredContent.state.legal_actions[1]

    luaunit.assertEquals(start_run.tool, "start_run")
    luaunit.assertNil(start_run.parameters)
    luaunit.assertEquals(start_run.fixed_arguments.deck_key, "b_red")
    luaunit.assertEquals(start_run.arguments.stake.minimum, 1)
    luaunit.assertEquals(start_run.arguments.stake.maximum, 1)
    luaunit.assertNil(start_run.arguments.seed)
    luaunit.assertNil(start_run.arguments.deck_key)
    luaunit.assertNil(start_run.arguments.stake.required)
    luaunit.assertNil(start_run.arguments.stake.type)
end

function TestDiscovery:test_dynamic_finite_set_errors_list_allowed_values()
    self.adapter:set_observation(main_menu_observation())
    local _, _, menu_payload = call_tool(self.server, self.port, 83, "get_game_state")
    local menu = menu_payload.result.structuredContent.state
    local _, _, bad_deck = call_tool(self.server, self.port, 84, "start_run", {
        state_hash = menu.state_hash,
        deck_key = "b_ghost",
        stake = 1,
    })
    luaunit.assertTrue(bad_deck.result.isError)
    luaunit.assertEquals(bad_deck.result.structuredContent.code, "INVALID_PARAMS")
    luaunit.assertStrContains(bad_deck.result.structuredContent.message, "allowed values: b_red")

    self.adapter:set_observation(owned_items_observation())
    local _, _, owned_payload = call_tool(self.server, self.port, 85, "get_game_state")
    local owned = owned_payload.result.structuredContent.state
    local _, _, bad_consumable = call_tool(self.server, self.port, 86, "use_consumable", {
        state_hash = owned.state_hash,
        consumable_id = "missing-consumable",
    })
    luaunit.assertTrue(bad_consumable.result.isError)
    luaunit.assertEquals(bad_consumable.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertStrContains(
        bad_consumable.result.structuredContent.message,
        "allowed values: planet-pluto, tarot-strength"
    )

    local _, _, bad_area = call_tool(self.server, self.port, 87, "reorder_cards", {
        state_hash = owned.state_hash,
        area = "jokers",
        ordered_ids = { owned.hand[1].id, owned.hand[2].id, owned.hand[3].id },
    })
    luaunit.assertTrue(bad_area.result.isError)
    luaunit.assertEquals(bad_area.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertStrContains(
        bad_area.result.structuredContent.message,
        "allowed values: joker-left, joker-right"
    )

    self.adapter:set_observation(shop_catalog_observation())
    local _, _, shop_payload = call_tool(self.server, self.port, 88, "get_game_state")
    local shop = shop_payload.result.structuredContent.state
    local _, _, bad_item = call_tool(self.server, self.port, 89, "buy_shop_item", {
        state_hash = shop.state_hash,
        item_id = "missing-item",
    })
    luaunit.assertTrue(bad_item.result.isError)
    luaunit.assertEquals(bad_item.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertStrContains(
        bad_item.result.structuredContent.message,
        "allowed values: shop-joker, shop-planet, shop-card, shop-strength"
    )
    local _, _, bad_voucher = call_tool(self.server, self.port, 90, "redeem_voucher", {
        state_hash = shop.state_hash,
        voucher_id = "missing-voucher",
    })
    luaunit.assertTrue(bad_voucher.result.isError)
    luaunit.assertEquals(bad_voucher.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertStrContains(
        bad_voucher.result.structuredContent.message,
        "allowed values: shop-voucher"
    )
    local _, _, bad_booster = call_tool(self.server, self.port, 91, "open_booster", {
        state_hash = shop.state_hash,
        booster_id = "missing-booster",
    })
    luaunit.assertTrue(bad_booster.result.isError)
    luaunit.assertEquals(bad_booster.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertStrContains(
        bad_booster.result.structuredContent.message,
        "allowed values: shop-booster"
    )
    local _, _, bad_buy_use = call_tool(self.server, self.port, 92, "buy_and_use_shop_item", {
        state_hash = shop.state_hash,
        item_id = "missing-item",
    })
    luaunit.assertTrue(bad_buy_use.result.isError)
    luaunit.assertEquals(bad_buy_use.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertStrContains(
        bad_buy_use.result.structuredContent.message,
        "allowed values: shop-planet, shop-strength"
    )
    local _, _, bad_buy_use_targets =
        call_tool(self.server, self.port, 93, "buy_and_use_shop_item", {
            state_hash = shop.state_hash,
            item_id = shop.shop_items[4].id,
            target_ids = { "missing-card" },
        })
    luaunit.assertTrue(bad_buy_use_targets.result.isError)
    luaunit.assertEquals(bad_buy_use_targets.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertStrContains(
        bad_buy_use_targets.result.structuredContent.message,
        "allowed values: hand-a, hand-b"
    )

    self.adapter:set_observation(booster_pack_observation(
        "arcana",
        {
            {
                target_ref = "pack-fool",
                category = "consumable",
                key = "c_fool",
                name = "The Fool",
            },
            {
                target_ref = "pack-strength",
                category = "consumable",
                key = "c_strength",
                name = "Strength",
                min_targets = 1,
                max_targets = 2,
            },
        },
        1,
        {
            hand = {
                { target_ref = "hand-a", key = "H_K", name = "King of Hearts" },
                { target_ref = "hand-b", key = "S_A", name = "Ace of Spades" },
            },
            legal_actions = {
                {
                    tool = "choose_booster_item",
                    target_refs = { item_id = { "pack-fool" } },
                },
                {
                    tool = "choose_booster_item",
                    fixed_target_refs = { item_id = "pack-strength" },
                    target_refs = { target_ids = { "hand-a", "hand-b" } },
                    arguments = { target_ids = { min_items = 1, max_items = 2 } },
                },
                { tool = "skip_booster" },
            },
        }
    ))
    local _, _, pack_payload = call_tool(self.server, self.port, 94, "get_game_state")
    local pack = pack_payload.result.structuredContent.state
    local _, _, bad_pack_item = call_tool(self.server, self.port, 95, "choose_booster_item", {
        state_hash = pack.state_hash,
        item_id = "missing-pack-item",
    })
    luaunit.assertTrue(bad_pack_item.result.isError)
    luaunit.assertEquals(bad_pack_item.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertStrContains(
        bad_pack_item.result.structuredContent.message,
        "allowed values: pack-fool, pack-strength"
    )
    local _, _, bad_pack_targets = call_tool(self.server, self.port, 96, "choose_booster_item", {
        state_hash = pack.state_hash,
        item_id = pack.booster_items[2].id,
        target_ids = { "missing-card" },
    })
    luaunit.assertTrue(bad_pack_targets.result.isError)
    luaunit.assertEquals(bad_pack_targets.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertStrContains(
        bad_pack_targets.result.structuredContent.message,
        "allowed values: hand-a, hand-b"
    )
end

function TestDiscovery:test_skip_blind_advances_to_the_next_blind()
    local current = blind_selection_observation()
    current.public_state.legal_actions[#current.public_state.legal_actions + 1] = {
        tool = "skip_blind",
        target_refs = { blind_id = { "small-blind" } },
    }
    self.adapter:set_observation(current)
    local next_state = blind_selection_observation()
    next_state.decision_sequence = 8
    next_state.public_state.blind_on_deck = "Big"
    next_state.public_state.blinds[1].current = false
    self.adapter.states[2] = next_state
    self.adapter.transitions[1].skip_blind = {
        target = { argument = "blind_id", reference = "small-blind" },
        events = { { type = "blind_skipped", blind_key = "bl_small" } },
        pending = { observations = 1, next_state = 2 },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 16, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 17, "skip_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertEquals(action_payload.result.structuredContent.state.blind_on_deck, "Big")
    luaunit.assertNil(action_payload.result.structuredContent.events)
    luaunit.assertNil(action_payload.result.structuredContent.resolution)
end

function TestDiscovery:test_reroll_boss_replaces_the_boss_choice()
    local current = blind_selection_observation()
    current.public_state.legal_actions[#current.public_state.legal_actions + 1] = {
        tool = "reroll_boss",
    }
    self.adapter:set_observation(current)
    local next_state = blind_selection_observation()
    next_state.decision_sequence = 8
    next_state.public_state.blinds[1].key = "bl_hook"
    next_state.public_state.blinds[1].name = "The Hook"
    self.adapter.states[2] = next_state
    self.adapter.transitions[1].reroll_boss = {
        events = { { type = "boss_rerolled", previous_blind_key = "bl_head" } },
        pending = { observations = 1, next_state = 2 },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 18, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 19, "reroll_boss", {
        state_hash = state.state_hash,
    })

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertEquals(action_payload.result.structuredContent.state.blinds[1].key, "bl_hook")
    luaunit.assertEquals(action_payload.result.structuredContent.state.blinds[1].name, "The Hook")
    luaunit.assertNil(action_payload.result.structuredContent.events)
    luaunit.assertNil(action_payload.result.structuredContent.resolution)
end

function TestDiscovery:test_pending_action_waits_for_next_decision_state()
    local resolution = {
        {
            order = 1,
            phase = "blind_selection",
            type = "apply",
            component = "blind",
            key = "bl_small",
            source = { input_target_id = "small-blind" },
            effects = {
                { order = 2, kind = "dollars", amount = 1, money = 5 },
            },
        },
    }
    self.adapter.transitions[1].select_blind.next_state = nil
    self.adapter.transitions[1].select_blind.pending = { observations = 2, next_state = 2 }
    self.adapter.transitions[1].select_blind.resolution = resolution
    self.adapter.transitions[1].select_blind.capture = true
    local _, _, state_payload = call_tool(self.server, self.port, 12, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local logs = {}
    self.server.log = function(level, message)
        logs[#logs + 1] = level .. " " .. message
    end
    local _, _, action_payload = call_tool(self.server, self.port, 13, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    local result = action_payload.result.structuredContent

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertEquals(result.state.phase, "hand_play")
    luaunit.assertEquals(result.state.decision_sequence, 8)
    luaunit.assertEquals(result.state.current_blind.name, "Small Blind")
    luaunit.assertEquals(result.resolution, resolution)
    luaunit.assertEquals(ToolCatalog.validate_output("select_blind", result), nil)
    luaunit.assertEquals(self.adapter.finished_captures, 1)
    luaunit.assertEquals(self.adapter.abandoned_captures, 0)
    luaunit.assertNil(result.events)
    luaunit.assertEquals(JSON.decode(action_payload.result.content[1].text), result)
    luaunit.assertEquals(#logs, 6)
    luaunit.assertStrContains(logs[1], "debug request.begin")
    luaunit.assertStrContains(logs[1], "trace=2")
    luaunit.assertStrContains(logs[2], "debug action.accepted")
    luaunit.assertStrContains(logs[2], "phase=blind_selection")
    luaunit.assertStrContains(logs[2], "bl_small")
    luaunit.assertStrContains(logs[3], "debug action.dispatched")
    luaunit.assertStrContains(logs[3], "pending=true")
    luaunit.assertStrContains(logs[3], "may_have_committed=true")
    luaunit.assertStrContains(logs[4], "debug decision.candidate")
    luaunit.assertStrContains(logs[4], "stable=false")
    luaunit.assertStrContains(logs[5], "debug decision.candidate")
    luaunit.assertStrContains(logs[5], "stable=true")
    luaunit.assertStrContains(logs[6], "info request.end")
    luaunit.assertStrContains(logs[6], "phase=hand_play")
end

function TestDiscovery:test_pending_action_ignores_a_transient_changed_snapshot()
    local intermediate = booster_decision_observation()
    intermediate.decision_sequence = 8
    local settled = shop_observation()
    settled.decision_sequence = 9
    local adapter = FakeBalatroAdapter.new({
        states = { blind_selection_observation(), intermediate, settled },
        transitions = {
            [1] = {
                select_blind = {
                    pending = { observations = 1, next_state = 2 },
                    target = { argument = "blind_id", reference = "small-blind" },
                },
            },
        },
        observe_transitions = { [2] = 3 },
    })
    local logs = {}
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        server_info = { name = "test", version = "0.1.0" },
        log = function(level, message)
            logs[#logs + 1] = level .. " " .. message
        end,
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local _, _, state_payload = call_tool(server, port, 14, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(server, port, 15, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    server:stop()

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertEquals(action_payload.result.structuredContent.state.phase, "shop")
    local candidates = {}
    for _, line in ipairs(logs) do
        if line:find("debug decision.candidate", 1, true) then
            candidates[#candidates + 1] = line
        end
    end
    luaunit.assertEquals(#candidates, 3)
    luaunit.assertStrContains(candidates[1], "phase=booster")
    luaunit.assertStrContains(candidates[1], "stable=false")
    luaunit.assertStrContains(candidates[2], "phase=shop")
    luaunit.assertStrContains(candidates[2], "stable=false")
    luaunit.assertStrContains(candidates[3], "phase=shop")
    luaunit.assertStrContains(candidates[3], "stable=true")
end

function TestDiscovery:test_hand_state_exposes_queryable_play_information()
    self.adapter:set_observation(hand_observation())
    local _, _, payload = call_tool(self.server, self.port, 40, "get_game_state")
    local state = payload.result.structuredContent.state
    local tools = {}
    for _, action in ipairs(state.legal_actions) do
        tools[#tools + 1] = action.tool
    end

    luaunit.assertEquals(state.phase, "hand_play")
    luaunit.assertEquals(state.current_blind.key, "bl_small")
    luaunit.assertEquals(state.score, 0)
    luaunit.assertEquals(state.hands_left, 4)
    luaunit.assertEquals(state.discards_left, 3)
    luaunit.assertEquals(state.hand[1].key, "S_A")
    luaunit.assertEquals(state.hand[1].suit, "Spades")
    luaunit.assertEquals(state.hand[1].rank, "Ace")
    luaunit.assertEquals(state.hand[1].chips, 11)
    luaunit.assertEquals(state.remaining_deck[1].key, "C_2")
    luaunit.assertEquals(state.poker_hands[1].key, "Pair")
    luaunit.assertEquals(tools, { "play_hand", "discard_cards" })
end

function TestDiscovery:test_play_hand_uses_card_id_order_as_processing_order()
    self.adapter:set_observation(hand_observation())
    self.adapter.states[2] = shop_observation()
    self.adapter.transitions[1].play_hand = {
        next_state = 2,
        target_order = { argument = "card_ids", references = { "card-b", "card-a" } },
        events = { { type = "scored", source_key = "H_K" } },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 41, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 42, "play_hand", {
        state_hash = state.state_hash,
        card_ids = { state.hand[2].id, state.hand[1].id },
    })

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertEquals(action_payload.result.structuredContent.state.phase, "shop")
    luaunit.assertNil(action_payload.result.structuredContent.events)
    luaunit.assertNil(action_payload.result.structuredContent.resolution)
end

function TestDiscovery:test_action_success_omits_resolution_and_query_has_no_trace()
    self.adapter:set_observation(hand_observation())
    self.adapter.states[2] = shop_observation()
    self.adapter.transitions[1].play_hand = {
        pending = { observations = 2, next_state = 2 },
        events = {
            { type = "scored", source_key = "S_A", trigger = "played", chips = 11 },
            { type = "cash_out", money = 3 },
        },
    }
    self.adapter.transitions[2] = {
        leave_shop = {
            next_state = 2,
            events = { { type = "left_shop" } },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 43, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, play_payload = call_tool(self.server, self.port, 44, "play_hand", {
        state_hash = state.state_hash,
        card_ids = { state.hand[1].id },
    })
    local _, _, followup_payload = call_tool(self.server, self.port, 45, "get_game_state")
    local shop = play_payload.result.structuredContent.state
    local _, _, next_payload = call_tool(self.server, self.port, 46, "leave_shop", {
        state_hash = shop.state_hash,
    })
    local _, _, replaced_payload = call_tool(self.server, self.port, 47, "get_game_state")

    luaunit.assertFalse(play_payload.result.isError)
    luaunit.assertEquals(play_payload.result.structuredContent.state.phase, "shop")
    luaunit.assertNil(play_payload.result.structuredContent.events)
    luaunit.assertNil(play_payload.result.structuredContent.resolution)
    luaunit.assertNil(followup_payload.result.structuredContent.events)
    luaunit.assertNil(followup_payload.result.structuredContent.resolution)
    luaunit.assertFalse(next_payload.result.isError)
    luaunit.assertNil(next_payload.result.structuredContent.events)
    luaunit.assertNil(next_payload.result.structuredContent.resolution)
    luaunit.assertNil(replaced_payload.result.structuredContent.events)
    luaunit.assertNil(replaced_payload.result.structuredContent.resolution)
end

function TestDiscovery:test_invalid_adapter_resolution_fails_closed_without_leaking_diagnostics()
    local logs = {}
    self.server.log = function(level, message)
        logs[#logs + 1] = level .. " " .. message
    end
    self.adapter.transitions[1].select_blind.resolution = {
        {
            order = 1,
            phase = "joker_main",
            type = "trigger",
            component = "joker",
            source = { input_target_id = "private-joker-ref" },
            effects = {
                { order = 2, kind = "mult", amount = 4, chips = 5, mult = 5, score = 25 },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 48, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 49, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    local result = action_payload.result.structuredContent
    local diagnostic = table.concat(logs, "\n")

    luaunit.assertTrue(action_payload.result.isError)
    luaunit.assertEquals(result.code, "INTERNAL_ERROR")
    luaunit.assertStrContains(result.message, "may have been committed")
    luaunit.assertEquals(result.state.phase, "hand_play")
    luaunit.assertNotEquals(result.state.state_hash, state.state_hash)
    luaunit.assertNil(result.resolution)
    luaunit.assertNil(result.schema_path)
    luaunit.assertNotStrContains(result.message, "private-joker-ref")
    luaunit.assertNotStrContains(action_payload.result.content[1].text, "private-joker-ref")
    luaunit.assertEquals(JSON.decode(action_payload.result.content[1].text), result)
    luaunit.assertStrContains(diagnostic, "tool=select_blind")
    luaunit.assertStrContains(diagnostic, "action=select_blind")
    luaunit.assertStrContains(diagnostic, "value.resolution[1].source.input_target_id")
    luaunit.assertStrContains(diagnostic, "private-joker-ref")
    luaunit.assertStrContains(diagnostic, "resolution")
end

function TestDiscovery:test_semantic_action_without_capture_context_fails_closed()
    self.adapter.transitions[1].select_blind.no_capture = true
    local _, _, state_payload = call_tool(self.server, self.port, 4904, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 4905, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    local result = action_payload.result.structuredContent

    luaunit.assertTrue(action_payload.result.isError)
    luaunit.assertEquals(result.code, "INTERNAL_ERROR")
    luaunit.assertStrContains(result.message, "may have been committed")
    luaunit.assertEquals(result.state.phase, "hand_play")
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(self.adapter.abandoned_captures, 1)
end

function TestDiscovery:test_invalid_no_effect_resolution_is_not_silently_pruned()
    self.adapter.transitions[1].select_blind.resolution = {
        {
            order = 1,
            phase = "playing_card",
            type = "trigger",
            effects = {},
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 4906, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 4907, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    local result = action_payload.result.structuredContent

    luaunit.assertTrue(action_payload.result.isError)
    luaunit.assertEquals(result.code, "INTERNAL_ERROR")
    luaunit.assertEquals(result.state.phase, "hand_play")
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(self.adapter.abandoned_captures, 1)
end

function TestDiscovery:test_immediate_capture_error_uses_committed_state_recovery()
    local logs = {}
    self.server.log = function(level, message)
        logs[#logs + 1] = level .. " " .. message
    end
    self.adapter.transitions[1].select_blind.capture = true
    self.adapter.transitions[1].select_blind.capture_error = {
        code = "INTERNAL_ERROR",
        message = "Created object identity is not visible",
        path = "value.resolution.effects.create",
        raw_reference = "private-created-card",
    }
    local _, _, state_payload = call_tool(self.server, self.port, 4908, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 4909, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    local result = action_payload.result.structuredContent
    local diagnostic = table.concat(logs, "\n")

    luaunit.assertTrue(action_payload.result.isError)
    luaunit.assertEquals(result.code, "INTERNAL_ERROR")
    luaunit.assertStrContains(result.message, "may have been committed")
    luaunit.assertEquals(result.state.phase, "hand_play")
    luaunit.assertNotEquals(result.state.state_hash, state.state_hash)
    luaunit.assertNil(result.resolution)
    luaunit.assertNotStrContains(action_payload.result.content[1].text, "private-created-card")
    luaunit.assertStrContains(diagnostic, "value.resolution.effects.create")
    luaunit.assertStrContains(diagnostic, "private-created-card")
end

function TestDiscovery:test_pending_invalid_resolution_returns_latest_stable_state()
    self.adapter.transitions[1].select_blind.next_state = nil
    self.adapter.transitions[1].select_blind.pending = { observations = 2, next_state = 2 }
    self.adapter.transitions[1].select_blind.resolution = {
        {
            order = 1,
            phase = "playing_card",
            type = "trigger",
            source = { input_target_id = "small-blind" },
            effects = {
                { order = 2, kind = "dollars", amount = 1, money = 5 },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 4910, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 4911, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    local result = action_payload.result.structuredContent

    luaunit.assertTrue(action_payload.result.isError)
    luaunit.assertEquals(result.code, "INTERNAL_ERROR")
    luaunit.assertEquals(result.state.phase, "hand_play")
    luaunit.assertNotEquals(result.state.state_hash, state.state_hash)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(JSON.decode(action_payload.result.content[1].text), result)
end

function TestDiscovery:test_invalid_readonly_output_fails_closed_with_null_state()
    self.adapter.encyclopedia = function()
        return { visibility = "private", entries = {} }
    end
    local _, _, payload = call_tool(self.server, self.port, 4912, "get_effect_encyclopedia")
    local result = payload.result.structuredContent

    luaunit.assertTrue(payload.result.isError)
    luaunit.assertEquals(result.code, "INTERNAL_ERROR")
    luaunit.assertNil(result.state)
    luaunit.assertNil(result.effect_encyclopedia)
    luaunit.assertStrContains(payload.result.content[1].text, '"state":null')
    luaunit.assertEquals(JSON.decode(payload.result.content[1].text), result)
end

function TestDiscovery:test_invalid_resolution_shapes_fail_closed_after_commit()
    local hidden = "j_caino"
    local cases = {
        {
            name = "missing_component",
            resolution = {
                {
                    order = 1,
                    phase = "playing_card",
                    type = "trigger",
                    source = { input_target_id = "small-blind" },
                    effects = {
                        { order = 2, kind = "dollars", amount = 1, money = 5 },
                    },
                },
            },
        },
        {
            name = "missing_source",
            resolution = {
                {
                    order = 1,
                    phase = "playing_card",
                    type = "trigger",
                    component = "playing_card",
                    effects = {
                        {
                            order = 2,
                            kind = "chips",
                            amount = 11,
                            chips = 16,
                            mult = 1,
                            score = 16,
                        },
                    },
                },
            },
        },
        {
            name = "unknown_destroy",
            resolution = {
                {
                    order = 1,
                    phase = "destroying_card",
                    type = "trigger",
                    component = "enhancement",
                    source = { input_target_id = "small-blind" },
                    effects = {
                        { order = 2, kind = "destroy", input_target_id = "ghost-card" },
                    },
                },
            },
        },
        {
            name = "invalid_scoring",
            resolution = {
                {
                    order = 1,
                    phase = "playing_card",
                    type = "trigger",
                    component = "playing_card",
                    source = { input_target_id = "small-blind" },
                    effects = { { order = 2, kind = "chips", amount = 11 } },
                },
            },
        },
        {
            name = "extra_properties",
            resolution = {
                {
                    order = 1,
                    phase = "playing_card",
                    type = "trigger",
                    component = "playing_card",
                    source = { input_target_id = "small-blind" },
                    hidden_key = hidden,
                    effects = {
                        { order = 2, kind = "dollars", amount = 1, money = 5 },
                    },
                },
            },
        },
        {
            name = "illegal_oneof",
            resolution = {
                {
                    order = 1,
                    phase = "hand",
                    type = "apply",
                    component = "tarot",
                    effects = {
                        { order = 2, kind = "dollars", amount = 1, money = 5 },
                    },
                },
            },
        },
    }

    for index, case in ipairs(cases) do
        self.adapter.index = 1
        self.adapter.pending = nil
        self.adapter.states = { blind_selection_observation(), hand_observation() }
        self.adapter.transitions = {
            [1] = {
                select_blind = {
                    next_state = 2,
                    target = { argument = "blind_id", reference = "small-blind" },
                    resolution = case.resolution,
                },
            },
        }
        local id = 4920 + index * 2
        local _, _, state_payload = call_tool(self.server, self.port, id, "get_game_state")
        local state = state_payload.result.structuredContent.state
        local _, _, action_payload = call_tool(self.server, self.port, id + 1, "select_blind", {
            state_hash = state.state_hash,
            blind_id = state.blinds[1].id,
        })
        local result = action_payload.result.structuredContent
        luaunit.assertTrue(action_payload.result.isError, case.name)
        luaunit.assertEquals(result.code, "INTERNAL_ERROR", case.name)
        luaunit.assertStrContains(result.message, "may have been committed")
        luaunit.assertEquals(result.state.phase, "hand_play", case.name)
        luaunit.assertNotEquals(result.state.state_hash, state.state_hash, case.name)
        luaunit.assertNil(result.resolution)
        luaunit.assertNotStrContains(result.message, hidden)
        luaunit.assertNotStrContains(result.message, "ghost-card")
        luaunit.assertNotStrContains(action_payload.result.content[1].text, hidden)
        luaunit.assertNotStrContains(action_payload.result.content[1].text, "ghost-card")
        luaunit.assertEquals(JSON.decode(action_payload.result.content[1].text), result)
    end
end

function TestDiscovery:test_invalid_terminal_resolution_fails_closed()
    local menu = main_menu_observation()
    menu.decision_sequence = 21
    self.adapter.index = 1
    self.adapter.pending = nil
    self.adapter.states = { victory_observation(), menu }
    self.adapter.transitions = {
        [1] = {
            return_to_menu = {
                next_state = 2,
                resolution = {
                    {
                        order = 1,
                        phase = "end_of_round",
                        type = "cash_out",
                        hidden_key = "j_caino",
                        effects = { { order = 2, kind = "dollars", amount = 1, money = 5 } },
                    },
                },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 4940, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 4941, "return_to_menu", {
        state_hash = state.state_hash,
    })
    local result = action_payload.result.structuredContent
    luaunit.assertTrue(action_payload.result.isError)
    luaunit.assertEquals(result.code, "INTERNAL_ERROR")
    luaunit.assertStrContains(result.message, "may have been committed")
    luaunit.assertEquals(result.state.phase, "main_menu")
    luaunit.assertNil(result.resolution)
    luaunit.assertNotStrContains(result.message, "j_caino")
    luaunit.assertNotStrContains(action_payload.result.content[1].text, "j_caino")
end

function TestDiscovery:test_play_hand_forwards_resolution_and_omits_empty()
    self.adapter:set_observation(hand_observation())
    self.adapter.states[2] = shop_observation()
    self.adapter.transitions[1].play_hand = {
        next_state = 2,
        target_order = { argument = "card_ids", references = { "card-a" } },
        resolution = {
            {
                order = 1,
                phase = "playing_card",
                type = "trigger",
                component = "playing_card",
                source = { input_target_id = "card-a" },
                effects = {
                    {
                        order = 2,
                        kind = "chips",
                        amount = 11,
                        chips = 16,
                        mult = 1,
                        score = 16,
                    },
                },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 481, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, play_payload = call_tool(self.server, self.port, 482, "play_hand", {
        state_hash = state.state_hash,
        card_ids = { state.hand[1].id },
    })
    local result = play_payload.result.structuredContent

    luaunit.assertFalse(play_payload.result.isError)
    luaunit.assertEquals(result.resolution[1].source.input_target_id, state.hand[1].id)
    luaunit.assertEquals(result.resolution[1].component, "playing_card")
    luaunit.assertNil(result.events)
    luaunit.assertEquals(JSON.decode(play_payload.result.content[1].text), result)

    self.adapter.index = 1
    self.adapter:set_observation(hand_observation())
    self.adapter.states[2] = shop_observation()
    self.adapter.transitions[1].play_hand = {
        next_state = 2,
        target_order = { argument = "card_ids", references = { "card-a" } },
        resolution = {
            {
                order = 1,
                phase = "hand",
                type = "apply",
                component = "tarot",
                key = "c_wheel_of_fortune",
                source = { input_target_id = "card-a" },
                effects = {},
            },
        },
    }
    local _, _, empty_state_payload = call_tool(self.server, self.port, 483, "get_game_state")
    local empty_state = empty_state_payload.result.structuredContent.state
    local _, _, empty_play = call_tool(self.server, self.port, 484, "play_hand", {
        state_hash = empty_state.state_hash,
        card_ids = { empty_state.hand[1].id },
    })
    luaunit.assertFalse(empty_play.result.isError)
    luaunit.assertNil(empty_play.result.structuredContent.resolution)
end

function TestDiscovery:test_play_hand_resolution_uses_input_public_ids_for_facedown_jokers()
    local visible = hand_observation()
    visible.public_state.jokers = {
        {
            target_ref = "joker-left",
            key = "j_joker",
            name = "Joker",
            set = "Joker",
            sellable = true,
        },
    }
    self.adapter:set_observation(visible)
    local _, _, visible_payload = call_tool(self.server, self.port, 485, "get_game_state")
    local visible_id = visible_payload.result.structuredContent.state.jokers[1].id

    local facedown = hand_observation()
    facedown.public_state.jokers = { { target_ref = "joker-left", facedown = true } }
    self.adapter:set_observation(facedown)
    local _, _, facedown_payload = call_tool(self.server, self.port, 486, "get_game_state")
    local facedown_state = facedown_payload.result.structuredContent.state
    luaunit.assertNotEquals(facedown_state.jokers[1].id, visible_id)
    luaunit.assertEquals(facedown_state.jokers[1].facedown, true)
    luaunit.assertNil(facedown_state.jokers[1].key)

    self.adapter.states[2] = shop_observation()
    self.adapter.transitions[1].play_hand = {
        next_state = 2,
        target_order = { argument = "card_ids", references = { "card-a" } },
        resolution = {
            {
                order = 1,
                phase = "joker_main",
                type = "trigger",
                component = "joker",
                source = { input_target_id = "joker-left" },
                effects = {
                    { order = 2, kind = "mult", amount = 4, chips = 16, mult = 5, score = 80 },
                },
            },
        },
    }
    local _, _, play_payload = call_tool(self.server, self.port, 487, "play_hand", {
        state_hash = facedown_state.state_hash,
        card_ids = { facedown_state.hand[1].id },
    })
    local result = play_payload.result.structuredContent
    luaunit.assertFalse(play_payload.result.isError)
    luaunit.assertEquals(result.resolution[1].source.input_target_id, facedown_state.jokers[1].id)
    luaunit.assertNil(result.resolution[1].source.key)
end

function TestDiscovery:test_consumable_effect_fixtures_match_announced_output_schema()
    self.adapter:set_observation(owned_items_observation())
    self.adapter.states[2] = owned_items_after_observation()
    self.adapter.transitions[1] = {
        use_consumable = {
            next_state = 2,
            target = { argument = "consumable_id", reference = "planet-pluto" },
            resolution = {
                {
                    order = 1,
                    phase = "hand",
                    type = "apply",
                    component = "planet",
                    key = "c_pluto",
                    source = { input_target_id = "planet-pluto" },
                    effects = {
                        { order = 2, kind = "dollars", amount = 3, money = 9 },
                        {
                            order = 3,
                            kind = "create",
                            object_kind = "joker",
                            destination = "owned",
                            key = "j_joker",
                        },
                        {
                            order = 4,
                            kind = "set_card_state",
                            input_target_id = "card-a",
                            state = "rank",
                            value = "King",
                        },
                        {
                            order = 5,
                            kind = "copy",
                            mode = "overwrite",
                            source = { input_target_id = "card-a" },
                            destination = { input_target_id = "card-b" },
                        },
                        {
                            order = 6,
                            kind = "copy",
                            mode = "create",
                            source = { input_target_id = "card-a" },
                            object_kind = "playing_card",
                            destination = "permanent_deck",
                            key = "S_A",
                            rank = "Ace",
                            suit = "Spades",
                        },
                        {
                            order = 7,
                            kind = "poker_hand_level",
                            poker_hand = "High Card",
                            amount = 1,
                            level = 2,
                            chips = 15,
                            mult = 2,
                        },
                        {
                            order = 8,
                            kind = "capacity",
                            resource = "hand_size",
                            amount = -1,
                            value = 7,
                        },
                    },
                },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 487, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, use_payload = call_tool(self.server, self.port, 488, "use_consumable", {
        state_hash = state.state_hash,
        consumable_id = state.consumables[1].id,
    })

    luaunit.assertFalse(use_payload.result.isError)
    luaunit.assertEquals(
        ToolCatalog.validate_output("use_consumable", use_payload.result.structuredContent),
        nil
    )
    local effects = use_payload.result.structuredContent.resolution[1].effects
    luaunit.assertEquals(effects[4].source.input_target_id, state.hand[1].id)
    luaunit.assertEquals(effects[4].destination.input_target_id, state.hand[2].id)
    luaunit.assertNil(effects[5].input_target_id)
end

function TestDiscovery:test_resolution_maps_destroy_omits_created_ids_and_failed_actions()
    self.adapter:set_observation(hand_observation())
    local after = shop_observation()
    after.public_state.consumables = {
        {
            target_ref = "new-spectral",
            key = "c_sigil",
            set = "Spectral",
            name = "Sigil",
        },
    }
    self.adapter.states[2] = after
    self.adapter.transitions[1].play_hand = {
        next_state = 2,
        target_order = { argument = "card_ids", references = { "card-a" } },
        resolution = {
            {
                order = 1,
                phase = "destroying_card",
                type = "trigger",
                component = "enhancement",
                source = { input_target_id = "card-a" },
                effects = { { order = 2, kind = "destroy", input_target_id = "card-a" } },
            },
            {
                order = 3,
                phase = "destroying_card",
                type = "trigger",
                component = "playing_card",
                source = { input_target_id = "card-a" },
                effects = {
                    {
                        order = 4,
                        kind = "create",
                        object_kind = "consumable",
                        destination = "owned",
                        key = "c_sigil",
                    },
                },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 488, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, play_payload = call_tool(self.server, self.port, 489, "play_hand", {
        state_hash = state.state_hash,
        card_ids = { state.hand[1].id },
    })
    local result = play_payload.result.structuredContent
    luaunit.assertFalse(play_payload.result.isError)
    luaunit.assertEquals(result.resolution[1].effects[1].kind, "destroy")
    luaunit.assertEquals(result.resolution[1].effects[1].input_target_id, state.hand[1].id)
    luaunit.assertEquals(result.resolution[2].effects[1].kind, "create")
    luaunit.assertEquals(result.resolution[2].effects[1].object_kind, "consumable")
    luaunit.assertEquals(result.resolution[2].effects[1].key, "c_sigil")
    luaunit.assertNil(result.resolution[2].effects[1].input_target_id)
    luaunit.assertNil(result.resolution[2].effects[1].id)
    luaunit.assertEquals(result.state.consumables[1].key, "c_sigil")
    luaunit.assertNotNil(result.state.consumables[1].id)
    luaunit.assertNotEquals(result.state.consumables[1].id, "c_sigil")
    luaunit.assertNil(result.events)

    self.adapter.index = 1
    self.adapter:set_observation(hand_observation())
    self.adapter.transitions[1].play_hand = {
        error = { code = "ACTION_NOT_ALLOWED", message = "Playing a hand is not allowed" },
        resolution = {
            {
                order = 1,
                phase = "playing_card",
                type = "trigger",
                effects = { { kind = "chips", amount = 11 } },
            },
        },
    }
    local _, _, fail_state = call_tool(self.server, self.port, 490, "get_game_state")
    local fail = fail_state.result.structuredContent.state
    local _, _, fail_play = call_tool(self.server, self.port, 491, "play_hand", {
        state_hash = fail.state_hash,
        card_ids = { fail.hand[1].id },
    })
    luaunit.assertTrue(fail_play.result.isError)
    luaunit.assertNil(fail_play.result.structuredContent.resolution)
    luaunit.assertNil(fail_play.result.structuredContent.events)
end

function TestDiscovery:test_owned_items_expose_keys_values_and_flags()
    self.adapter:set_observation(owned_items_observation())
    local _, _, payload = call_tool(self.server, self.port, 50, "get_game_state")
    local state = payload.result.structuredContent.state
    local tools = {}
    for _, action in ipairs(state.legal_actions) do
        tools[#tools + 1] = action.tool
    end

    luaunit.assertEquals(state.jokers[1].key, "j_joker")
    luaunit.assertEquals(state.jokers[1].name, "Joker")
    luaunit.assertEquals(state.jokers[1].description, "+4 Mult")
    luaunit.assertEquals(state.jokers[1].cost, 2)
    luaunit.assertEquals(state.jokers[1].sell_value, 1)
    luaunit.assertFalse(state.jokers[1].debuffed)
    luaunit.assertTrue(state.jokers[1].sellable)
    luaunit.assertEquals(state.joker_limit, 5)
    luaunit.assertEquals(state.consumables[2].key, "c_strength")
    luaunit.assertEquals(state.consumables[2].min_targets, 1)
    luaunit.assertEquals(state.consumables[2].max_targets, 2)
    luaunit.assertEquals(state.consumable_limit, 2)
    luaunit.assertEquals(state.hand[3].facedown, true)
    luaunit.assertNil(state.hand[3].key)
    luaunit.assertNil(state.deck_order)
    luaunit.assertNil(state.facedown_cards)
    luaunit.assertEquals(tools, {
        "reorder_cards",
        "reorder_cards",
        "use_consumable",
        "use_consumable",
        "sell_owned_item",
    })
end

function TestDiscovery:test_omniscient_owned_state_reveals_hidden_identities()
    self.adapter:set_observation(owned_items_observation())
    self.server:set_visibility("omniscient")
    local _, _, payload = call_tool(self.server, self.port, 51, "get_game_state")
    local state = payload.result.structuredContent.state

    luaunit.assertEquals(state.deck_order, { "C_2", "S_2" })
    luaunit.assertEquals(state.facedown_cards[1].key, "D_Q")
    luaunit.assertEquals(state.facedown_cards[1].name, "Queen of Diamonds")
    luaunit.assertEquals(state.hand[3].facedown, true)
    luaunit.assertNil(state.hand[3].key)
end

function TestDiscovery:test_omniscient_duplicate_facedown_target_refs_do_not_fail()
    local observation = owned_items_observation()
    observation.hidden_state.facedown_cards[1].target_ref = "card-hidden"
    observation.hidden_state.facedown_cards[1].facedown = true
    observation.public_state.jokers[1] = {
        target_ref = "joker-left",
        facedown = true,
    }
    observation.hidden_state.facedown_jokers = {
        {
            target_ref = "joker-left",
            facedown = true,
            key = "j_joker",
            name = "Joker",
        },
    }
    self.adapter:set_observation(observation)
    self.server:set_visibility("omniscient")
    local _, _, payload = call_tool(self.server, self.port, 520, "get_game_state")
    local state = payload.result.structuredContent.state

    luaunit.assertFalse(payload.result.isError)
    luaunit.assertEquals(state.visibility, "omniscient")
    luaunit.assertEquals(state.hand[3].facedown, true)
    luaunit.assertNil(state.hand[3].key)
    luaunit.assertEquals(state.facedown_cards[1].key, "D_Q")
    luaunit.assertEquals(state.facedown_cards[1].id, state.hand[3].id)
    luaunit.assertEquals(state.jokers[1].facedown, true)
    luaunit.assertNil(state.jokers[1].key)
    luaunit.assertEquals(state.facedown_jokers[1].key, "j_joker")
    luaunit.assertEquals(state.facedown_jokers[1].id, state.jokers[1].id)
end

function TestDiscovery:test_hand_order_projections_reuse_ids_and_are_not_actions()
    local observation = owned_items_observation()
    observation.public_state.hand_order_projections = {
        rank = { "card-hidden", "card-b", "card-a" },
        suit = { "card-a", "card-b", "card-hidden" },
    }
    self.adapter:set_observation(observation)
    local _, _, payload = call_tool(self.server, self.port, 521, "get_game_state")
    local state = payload.result.structuredContent.state
    local ids = {}
    for _, card in ipairs(state.hand) do
        ids[card.id] = true
    end
    local tools = {}
    for _, action in ipairs(state.legal_actions) do
        tools[#tools + 1] = action.tool
        luaunit.assertNil(action.fixed_arguments and action.fixed_arguments.sort)
    end

    local hidden_id = state.hand[3].id
    luaunit.assertEquals(state.hand[1].id, "card-a")
    luaunit.assertEquals(state.hand[2].id, "card-b")
    luaunit.assertStrMatches(hidden_id, "^h:%d+$")
    luaunit.assertEquals(state.hand_order_projections.rank, {
        hidden_id,
        "card-b",
        "card-a",
    })
    luaunit.assertEquals(state.hand_order_projections.suit, {
        "card-a",
        "card-b",
        hidden_id,
    })
    luaunit.assertTrue(ids[state.hand_order_projections.rank[1]])
    luaunit.assertTrue(ids[state.hand_order_projections.suit[1]])
    luaunit.assertNil(state.active_sort)
    luaunit.assertEquals(tools, {
        "reorder_cards",
        "reorder_cards",
        "use_consumable",
        "use_consumable",
        "sell_owned_item",
    })
end

function TestDiscovery:test_hidden_ids_rotate_on_flip_or_shuffle_and_keep_on_reorder()
    local visible = owned_items_observation()
    self.adapter:set_observation(visible)
    local _, _, visible_payload = call_tool(self.server, self.port, 522, "get_game_state")
    local start = visible_payload.result.structuredContent.state
    local hidden_card_id = start.hand[3].id
    local joker_left_id = start.jokers[1].id
    local joker_right_id = start.jokers[2].id

    local flipped = owned_items_observation()
    flipped.public_state.jokers[1] = { target_ref = "joker-left", facedown = true }
    flipped.public_state.jokers[2] = { target_ref = "joker-right", facedown = true }
    self.adapter:set_observation(flipped)
    local _, _, flipped_payload = call_tool(self.server, self.port, 523, "get_game_state")
    local after_flip = flipped_payload.result.structuredContent.state
    luaunit.assertEquals(after_flip.hand[3].id, hidden_card_id)
    luaunit.assertEquals(after_flip.jokers[1].facedown, true)
    luaunit.assertNil(after_flip.jokers[1].key)
    luaunit.assertNotEquals(after_flip.jokers[1].id, joker_left_id)
    luaunit.assertNotEquals(after_flip.jokers[2].id, joker_right_id)
    luaunit.assertNil((after_flip.jokers[1].id):find(joker_left_id, 1, true))
    luaunit.assertNil((after_flip.jokers[2].id):find(joker_right_id, 1, true))
    luaunit.assertNotEquals(after_flip.jokers[1].id, after_flip.jokers[2].id)
    local flipped_left_id = after_flip.jokers[1].id
    local flipped_right_id = after_flip.jokers[2].id

    local remaining_jokers = owned_items_observation()
    remaining_jokers.public_state.jokers = {
        { target_ref = "joker-left", facedown = true },
    }
    remaining_jokers.public_state.legal_actions[2].target_refs.ordered_ids = {
        "joker-left",
    }
    remaining_jokers.public_state.legal_actions[5].target_refs.item_id = {
        "joker-left",
        "planet-pluto",
        "tarot-strength",
    }
    self.adapter:set_observation(remaining_jokers)
    local _, _, remaining_payload = call_tool(self.server, self.port, 5231, "get_game_state")
    luaunit.assertEquals(
        remaining_payload.result.structuredContent.state.jokers[1].id,
        flipped_left_id
    )

    local shuffled = owned_items_observation()
    shuffled.public_state.jokers = {
        { target_ref = "joker-right", facedown = true },
        { target_ref = "joker-left", facedown = true },
    }
    shuffled.public_state.legal_actions[2].target_refs.ordered_ids = {
        "joker-right",
        "joker-left",
    }
    self.adapter:set_observation(shuffled)
    local _, _, shuffled_payload = call_tool(self.server, self.port, 524, "get_game_state")
    local after_shuffle = shuffled_payload.result.structuredContent.state
    luaunit.assertEquals(after_shuffle.hand[3].id, hidden_card_id)
    luaunit.assertNotEquals(after_shuffle.jokers[1].id, flipped_right_id)
    luaunit.assertNotEquals(after_shuffle.jokers[2].id, flipped_left_id)
    luaunit.assertNotEquals(after_shuffle.jokers[1].id, after_shuffle.jokers[2].id)

    local after_discard = owned_items_observation()
    after_discard.public_state.hand = {
        after_discard.public_state.hand[2],
        after_discard.public_state.hand[3],
    }
    after_discard.public_state.legal_actions[1].target_refs.ordered_ids = {
        "card-b",
        "card-hidden",
    }
    after_discard.public_state.legal_actions[4].target_refs.target_ids = {
        "card-b",
        "card-hidden",
    }
    self.adapter:set_observation(after_discard)
    local _, _, after_discard_payload = call_tool(self.server, self.port, 525, "get_game_state")
    luaunit.assertEquals(
        after_discard_payload.result.structuredContent.state.hand[2].id,
        hidden_card_id
    )

    local before_reorder = owned_items_observation()
    before_reorder.public_state.jokers[1] = { target_ref = "joker-left", facedown = true }
    before_reorder.public_state.jokers[2] = { target_ref = "joker-right", facedown = true }
    self.adapter:set_observation(before_reorder)
    local _, _, before_payload = call_tool(self.server, self.port, 526, "get_game_state")
    local before = before_payload.result.structuredContent.state
    local after_reorder = owned_items_observation()
    after_reorder.decision_sequence = 9
    after_reorder.public_state.jokers = {
        { target_ref = "joker-right", facedown = true },
        { target_ref = "joker-left", facedown = true },
    }
    after_reorder.public_state.legal_actions[2].target_refs.ordered_ids = {
        "joker-right",
        "joker-left",
    }
    self.adapter.states[2] = after_reorder
    self.adapter.transitions[1] = {
        reorder_cards = {
            next_state = 2,
            arguments = { area = "jokers" },
            target_order = {
                argument = "ordered_ids",
                references = { "joker-right", "joker-left" },
            },
        },
    }
    local _, _, reorder_payload = call_tool(self.server, self.port, 527, "reorder_cards", {
        state_hash = before.state_hash,
        area = "jokers",
        ordered_ids = { before.jokers[2].id, before.jokers[1].id },
    })
    local reordered = reorder_payload.result.structuredContent.state
    luaunit.assertFalse(reorder_payload.result.isError)
    luaunit.assertEquals(reordered.jokers[1].id, before.jokers[2].id)
    luaunit.assertEquals(reordered.jokers[2].id, before.jokers[1].id)
    luaunit.assertEquals(reordered.hand[3].id, hidden_card_id)
end

function TestDiscovery:test_area_order_is_semantic_in_the_state_hash()
    self.adapter:set_observation(owned_items_observation())
    local _, _, first_payload = call_tool(self.server, self.port, 52, "get_game_state")
    local first = first_payload.result.structuredContent.state
    local reordered = owned_items_observation()
    reordered.public_state.jokers = {
        reordered.public_state.jokers[2],
        reordered.public_state.jokers[1],
    }
    self.adapter:set_observation(reordered)
    local _, _, second_payload = call_tool(self.server, self.port, 53, "get_game_state")
    local second = second_payload.result.structuredContent.state

    luaunit.assertEquals(second.jokers[1].key, "j_greedy_joker")
    luaunit.assertNotEquals(second.state_hash, first.state_hash)
end

function TestDiscovery:test_reorder_cards_applies_a_complete_hand_or_joker_order()
    self.adapter:set_observation(owned_items_observation())
    self.adapter.states[2] = owned_items_after_observation()
    self.adapter.transitions[1] = {
        reorder_cards = {
            next_state = 2,
            arguments = { area = "jokers" },
            target_order = {
                argument = "ordered_ids",
                references = { "joker-right", "joker-left" },
            },
            events = { { type = "cards_reordered", area = "jokers" } },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 54, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 55, "reorder_cards", {
        state_hash = state.state_hash,
        area = "jokers",
        ordered_ids = { state.jokers[2].id, state.jokers[1].id },
    })
    local result = action_payload.result.structuredContent

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.jokers[1].key, "j_greedy_joker")
    luaunit.assertEquals(result.state.jokers[1].name, "Greedy Joker")
    luaunit.assertEquals(result.state.decision_sequence, 9)
end

function TestDiscovery:test_reorder_cards_rejects_invalid_permutations_without_changing_state()
    self.adapter:set_observation(owned_items_observation())
    self.adapter.transitions[1] = {
        reorder_cards = {
            next_state = 2,
            events = { { type = "cards_reordered", area = "hand" } },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 56, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local cases = {
        {
            ordered_ids = { state.hand[1].id, state.hand[2].id },
            area = "hand",
        },
        {
            ordered_ids = { state.hand[1].id, state.hand[2].id, state.jokers[1].id },
            area = "hand",
        },
        {
            ordered_ids = { state.hand[1].id, state.hand[2].id, state.hand[3].id },
            area = "jokers",
        },
        {
            ordered_ids = { state.hand[1].id, state.hand[1].id, state.hand[2].id },
            area = "hand",
        },
    }
    for index, arguments in ipairs(cases) do
        arguments.state_hash = state.state_hash
        local _, _, payload =
            call_tool(self.server, self.port, 56 + index, "reorder_cards", arguments)
        luaunit.assertTrue(payload.result.isError)
        luaunit.assertNotNil(payload.result.structuredContent.code)
        luaunit.assertEquals(payload.result.structuredContent.state.state_hash, state.state_hash)
        luaunit.assertEquals(self.adapter.index, 1)
    end
end

function TestDiscovery:test_use_consumable_keeps_target_order()
    self.adapter:set_observation(owned_items_observation())
    self.adapter.states[2] = owned_items_after_observation()
    self.adapter.transitions[1] = {
        use_consumable = {
            next_state = 2,
            target = { argument = "consumable_id", reference = "tarot-strength" },
            target_order = { argument = "target_ids", references = { "card-b", "card-a" } },
            events = {
                {
                    type = "consumable_used",
                    key = "c_strength",
                    target_keys = { "H_K", "S_A" },
                },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 61, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 62, "use_consumable", {
        state_hash = state.state_hash,
        consumable_id = state.consumables[2].id,
        target_ids = { state.hand[2].id, state.hand[1].id },
    })
    local result = action_payload.result.structuredContent
    local _, _, followup_payload = call_tool(self.server, self.port, 63, "get_game_state")

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.consumables[1].key, "c_pluto")
    luaunit.assertNil(followup_payload.result.structuredContent.events)
    luaunit.assertNil(followup_payload.result.structuredContent.resolution)
end

function TestDiscovery:test_sell_owned_item_updates_money_capacity_and_legal_actions()
    self.adapter:set_observation(owned_items_observation())
    self.adapter.states[2] = owned_items_after_observation()
    self.adapter.transitions[1] = {
        sell_owned_item = {
            next_state = 2,
            target = { argument = "item_id", reference = "joker-left" },
            events = { { type = "item_sold", key = "j_joker", money = 1 } },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 64, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 65, "sell_owned_item", {
        state_hash = state.state_hash,
        item_id = state.jokers[1].id,
    })
    local result = action_payload.result.structuredContent
    local tools = {}
    for _, action in ipairs(result.state.legal_actions) do
        tools[#tools + 1] = action.tool
    end

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.money, 7)
    luaunit.assertEquals(#result.state.jokers, 1)
    luaunit.assertEquals(result.state.jokers[1].key, "j_greedy_joker")
    luaunit.assertEquals(result.state.jokers[1].name, "Greedy Joker")
    luaunit.assertEquals(tools, { "reorder_cards", "sell_owned_item" })
end

function TestDiscovery:test_use_consumable_without_targets_and_sell_consumable()
    self.adapter:set_observation(owned_items_observation())
    self.adapter.states[2] = owned_items_after_observation()
    self.adapter.transitions[1] = {
        use_consumable = {
            next_state = 2,
            target = { argument = "consumable_id", reference = "planet-pluto" },
            absent_arguments = { "target_ids" },
            events = { { type = "consumable_used", key = "c_pluto" } },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 70, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, use_payload = call_tool(self.server, self.port, 71, "use_consumable", {
        state_hash = state.state_hash,
        consumable_id = state.consumables[1].id,
    })
    luaunit.assertFalse(use_payload.result.isError)
    luaunit.assertNil(use_payload.result.structuredContent.events)
    luaunit.assertNil(use_payload.result.structuredContent.resolution)
    luaunit.assertEquals(use_payload.result.structuredContent.state.phase, "hand_play")

    self.adapter.index = 1
    self.adapter:set_observation(owned_items_observation())
    self.adapter.states[2] = owned_items_after_observation()
    self.adapter.transitions[1] = {
        sell_owned_item = {
            next_state = 2,
            target = { argument = "item_id", reference = "planet-pluto" },
            events = { { type = "item_sold", key = "c_pluto", money = 1 } },
        },
    }
    local _, _, again = call_tool(self.server, self.port, 72, "get_game_state")
    local current = again.result.structuredContent.state
    local _, _, sell_payload = call_tool(self.server, self.port, 73, "sell_owned_item", {
        state_hash = current.state_hash,
        item_id = current.consumables[1].id,
    })
    luaunit.assertFalse(sell_payload.result.isError)
    luaunit.assertNil(sell_payload.result.structuredContent.events)
    luaunit.assertNil(sell_payload.result.structuredContent.resolution)
    luaunit.assertEquals(sell_payload.result.structuredContent.state.money, 7)
end

function TestDiscovery:test_reorder_hand_and_reject_expired_ids()
    self.adapter:set_observation(owned_items_observation())
    self.adapter.states[2] = owned_items_after_observation()
    self.adapter.transitions[1] = {
        reorder_cards = {
            next_state = 2,
            arguments = { area = "hand" },
            target_order = {
                argument = "ordered_ids",
                references = { "card-b", "card-a", "card-hidden" },
            },
            events = { { type = "cards_reordered", area = "hand" } },
        },
    }
    local _, _, first = call_tool(self.server, self.port, 74, "get_game_state")
    local first_state = first.result.structuredContent.state
    local _, _, reorder_payload = call_tool(self.server, self.port, 75, "reorder_cards", {
        state_hash = first_state.state_hash,
        area = "hand",
        ordered_ids = { first_state.hand[2].id, first_state.hand[1].id, first_state.hand[3].id },
    })
    luaunit.assertFalse(reorder_payload.result.isError)
    luaunit.assertEquals(reorder_payload.result.structuredContent.state.hand[1].key, "H_K")

    local expired = owned_items_observation()
    expired.decision_sequence = 10
    expired.public_state.hand[1].target_ref = "card-new-a"
    expired.public_state.hand[2].target_ref = "card-new-b"
    expired.public_state.hand[3].target_ref = "card-new-hidden"
    expired.public_state.legal_actions = {
        {
            tool = "reorder_cards",
            fixed_arguments = { area = "hand" },
            target_refs = { ordered_ids = { "card-new-a", "card-new-b", "card-new-hidden" } },
        },
    }
    self.adapter:set_observation(expired)
    local _, _, current_payload = call_tool(self.server, self.port, 76, "get_game_state")
    local current = current_payload.result.structuredContent.state
    local _, _, stale_target = call_tool(self.server, self.port, 77, "reorder_cards", {
        state_hash = current.state_hash,
        area = "hand",
        ordered_ids = {
            first_state.hand[1].id,
            first_state.hand[2].id,
            first_state.hand[3].id,
        },
    })
    luaunit.assertTrue(stale_target.result.isError)
    luaunit.assertEquals(stale_target.result.structuredContent.code, "INVALID_TARGET")
end

function TestDiscovery:test_shop_snapshot_exposes_inventory_costs_and_capacity()
    self.adapter:set_observation(shop_catalog_observation())
    local _, _, payload = call_tool(self.server, self.port, 80, "get_game_state")
    local state = payload.result.structuredContent.state
    local tools = {}
    for _, action in ipairs(state.legal_actions) do
        tools[#tools + 1] = action.tool
    end

    luaunit.assertEquals(state.phase, "shop")
    luaunit.assertEquals(state.money, 12)
    luaunit.assertEquals(state.joker_limit, 5)
    luaunit.assertEquals(state.consumable_limit, 2)
    luaunit.assertEquals(state.reroll_cost, 5)
    luaunit.assertEquals(state.shop_items[1].category, "joker")
    luaunit.assertEquals(state.shop_items[1].key, "j_greedy_joker")
    luaunit.assertEquals(state.shop_items[1].name, "Greedy Joker")
    luaunit.assertEquals(
        state.shop_items[1].description,
        "Played cards with Diamond suit give +3 Mult when scored"
    )
    luaunit.assertEquals(state.shop_items[1].cost, 5)
    luaunit.assertEquals(state.shop_items[1].slot, "joker")
    luaunit.assertEquals(state.shop_items[2].category, "consumable")
    luaunit.assertEquals(state.shop_items[3].category, "playing_card")
    luaunit.assertEquals(state.shop_vouchers[1].key, "v_overstock_norm")
    luaunit.assertEquals(state.shop_boosters[1].key, "p_arcana_normal_1")
    luaunit.assertNotNil(state.shop_items[1].id)
    luaunit.assertEquals(tools, {
        "buy_shop_item",
        "buy_and_use_shop_item",
        "buy_and_use_shop_item",
        "redeem_voucher",
        "open_booster",
        "reroll_shop",
        "sell_owned_item",
        "leave_shop",
    })
end

function TestDiscovery:test_buy_shop_item_moves_item_into_owned_area()
    self.adapter:set_observation(shop_catalog_observation())
    self.adapter.states[2] = shop_after_buy_observation()
    self.adapter.transitions[1] = {
        buy_shop_item = {
            next_state = 2,
            target = { argument = "item_id", reference = "shop-joker" },
            events = {
                { type = "item_bought", key = "j_greedy_joker", money = -5, category = "joker" },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 81, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 82, "buy_shop_item", {
        state_hash = state.state_hash,
        item_id = state.shop_items[1].id,
    })
    local result = action_payload.result.structuredContent

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.money, 7)
    luaunit.assertEquals(#result.state.jokers, 2)
    luaunit.assertEquals(result.state.jokers[2].key, "j_greedy_joker")
    luaunit.assertEquals(#result.state.shop_items, 3)
end

function TestDiscovery:test_buy_and_use_shop_item_keeps_target_order()
    self.adapter:set_observation(shop_catalog_observation())
    self.adapter.states[2] = shop_after_use_observation()
    self.adapter.transitions[1] = {
        buy_and_use_shop_item = {
            next_state = 2,
            target = { argument = "item_id", reference = "shop-strength" },
            target_order = { argument = "target_ids", references = { "hand-b", "hand-a" } },
            events = {
                {
                    type = "item_bought_and_used",
                    key = "c_strength",
                    money = -3,
                    target_keys = { "S_A", "H_K" },
                },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 83, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 84, "buy_and_use_shop_item", {
        state_hash = state.state_hash,
        item_id = state.shop_items[4].id,
        target_ids = { state.hand[2].id, state.hand[1].id },
    })
    local result = action_payload.result.structuredContent

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.money, 9)
end

function TestDiscovery:test_redeem_voucher_updates_run_effects()
    self.adapter:set_observation(shop_catalog_observation())
    self.adapter.states[2] = shop_after_redeem_observation()
    self.adapter.transitions[1] = {
        redeem_voucher = {
            next_state = 2,
            target = { argument = "voucher_id", reference = "shop-voucher" },
            events = {
                { type = "voucher_redeemed", key = "v_overstock_norm", money = -10 },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 85, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 86, "redeem_voucher", {
        state_hash = state.state_hash,
        voucher_id = state.shop_vouchers[1].id,
    })
    local result = action_payload.result.structuredContent
    local tools = {}
    for _, action in ipairs(result.state.legal_actions) do
        tools[#tools + 1] = action.tool
    end

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.money, 2)
    luaunit.assertEquals(result.state.vouchers[1].key, "v_overstock_norm")
    luaunit.assertEquals(#result.state.shop_vouchers, 0)
    luaunit.assertEquals(tools, {
        "buy_shop_item",
        "buy_and_use_shop_item",
        "buy_and_use_shop_item",
        "open_booster",
        "reroll_shop",
        "sell_owned_item",
        "leave_shop",
    })
end

function TestDiscovery:test_open_booster_enters_booster_decision_state()
    self.adapter:set_observation(shop_catalog_observation())
    self.adapter.states[2] = booster_decision_observation()
    self.adapter.transitions[1] = {
        open_booster = {
            next_state = 2,
            target = { argument = "booster_id", reference = "shop-booster" },
            events = {
                { type = "booster_opened", key = "p_arcana_normal_1", money = -4 },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 87, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 88, "open_booster", {
        state_hash = state.state_hash,
        booster_id = state.shop_boosters[1].id,
    })
    local result = action_payload.result.structuredContent

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.phase, "booster")
    luaunit.assertEquals(result.state.booster.category, "arcana")
    luaunit.assertEquals(result.state.booster_items[1].key, "c_fool")
end

function TestDiscovery:test_booster_snapshot_covers_each_vanilla_pack_category()
    local cases = {
        {
            category = "arcana",
            item = {
                target_ref = "pack-fool",
                category = "consumable",
                key = "c_fool",
                name = "The Fool",
                description = "Creates the last Tarot or Planet card used during this run",
            },
        },
        {
            category = "celestial",
            item = {
                target_ref = "pack-pluto",
                category = "consumable",
                key = "c_pluto",
                name = "Pluto",
                description = "Level up High Card",
            },
        },
        {
            category = "spectral",
            item = {
                target_ref = "pack-familiar",
                category = "consumable",
                key = "c_familiar",
                name = "Familiar",
                description = "Destroy 1 random card in your hand, add 3 random Enhanced face cards to your hand",
            },
        },
        {
            category = "standard",
            item = {
                target_ref = "pack-king",
                category = "playing_card",
                key = "H_K",
                name = "King of Hearts",
                description = "",
                suit = "Hearts",
                rank = "King",
            },
        },
        {
            category = "buffoon",
            item = {
                target_ref = "pack-joker",
                category = "joker",
                key = "j_joker",
                name = "Joker",
                description = "+4 Mult",
            },
        },
    }
    for index, case in ipairs(cases) do
        self.adapter:set_observation(booster_pack_observation(case.category, { case.item }))
        local _, _, payload = call_tool(self.server, self.port, 110 + index, "get_game_state")
        local state = payload.result.structuredContent.state
        local tools = {}
        for _, action in ipairs(state.legal_actions) do
            tools[#tools + 1] = action.tool
        end

        luaunit.assertEquals(state.phase, "booster")
        luaunit.assertEquals(state.booster.category, case.category)
        luaunit.assertEquals(state.booster.choices_left, 1)
        luaunit.assertNotNil(state.booster_items[1].id)
        luaunit.assertEquals(state.booster_items[1].key, case.item.key)
        luaunit.assertEquals(state.booster_items[1].name, case.item.name)
        luaunit.assertEquals(state.booster_items[1].description, case.item.description)
        luaunit.assertEquals(state.booster_items[1].category, case.item.category)
        luaunit.assertEquals(state.booster_items[1].suit, case.item.suit)
        luaunit.assertEquals(state.booster_items[1].rank, case.item.rank)
        luaunit.assertNil(state.upcoming_pack_cards)
        luaunit.assertEquals(tools, { "choose_booster_item", "skip_booster" })
    end

    self.adapter:set_observation(booster_decision_observation())
    self.server:set_visibility("omniscient")
    local _, _, omniscient = call_tool(self.server, self.port, 116, "get_game_state")
    luaunit.assertEquals(#omniscient.result.structuredContent.state.booster_items, 1)
    luaunit.assertNil(omniscient.result.structuredContent.state.upcoming_pack_cards)
end

function TestDiscovery:test_choose_booster_item_uses_planet_and_selects_card_or_joker()
    local after_planet = shop_observation()
    after_planet.decision_sequence = 11
    self.adapter:set_observation(booster_pack_observation("celestial", {
        {
            target_ref = "pack-pluto",
            category = "consumable",
            key = "c_pluto",
            name = "Pluto",
            description = "Level up High Card",
        },
    }))
    self.adapter.states[2] = after_planet
    self.adapter.transitions[1] = {
        choose_booster_item = {
            next_state = 2,
            target = { argument = "item_id", reference = "pack-pluto" },
            absent_arguments = { "target_ids" },
            events = { { type = "booster_item_used", key = "c_pluto" } },
        },
    }
    local _, _, planet_state = call_tool(self.server, self.port, 117, "get_game_state")
    local planet = planet_state.result.structuredContent.state
    local _, _, planet_payload = call_tool(self.server, self.port, 118, "choose_booster_item", {
        state_hash = planet.state_hash,
        item_id = planet.booster_items[1].id,
    })
    luaunit.assertFalse(planet_payload.result.isError)
    luaunit.assertNil(planet_payload.result.structuredContent.events)
    luaunit.assertNil(planet_payload.result.structuredContent.resolution)
    luaunit.assertEquals(planet_payload.result.structuredContent.state.phase, "shop")

    local after_card = shop_catalog_observation()
    after_card.decision_sequence = 11
    self.adapter.index = 1
    self.adapter:set_observation(booster_pack_observation("standard", {
        {
            target_ref = "pack-king",
            category = "playing_card",
            key = "H_K",
            name = "King of Hearts",
            description = "",
            suit = "Hearts",
            rank = "King",
        },
    }))
    self.adapter.states[2] = after_card
    self.adapter.transitions[1] = {
        choose_booster_item = {
            next_state = 2,
            target = { argument = "item_id", reference = "pack-king" },
            events = { { type = "booster_item_chosen", key = "H_K", category = "playing_card" } },
        },
    }
    local _, _, card_state = call_tool(self.server, self.port, 119, "get_game_state")
    local card = card_state.result.structuredContent.state
    local _, _, card_payload = call_tool(self.server, self.port, 120, "choose_booster_item", {
        state_hash = card.state_hash,
        item_id = card.booster_items[1].id,
    })
    luaunit.assertFalse(card_payload.result.isError)
    luaunit.assertNil(card_payload.result.structuredContent.events)
    luaunit.assertNil(card_payload.result.structuredContent.resolution)
    luaunit.assertEquals(card_payload.result.structuredContent.state.phase, "shop")

    local after_joker = shop_catalog_observation()
    after_joker.decision_sequence = 11
    self.adapter.index = 1
    self.adapter:set_observation(booster_pack_observation("buffoon", {
        {
            target_ref = "pack-joker",
            category = "joker",
            key = "j_joker",
            name = "Joker",
            description = "+4 Mult",
        },
    }))
    self.adapter.states[2] = after_joker
    self.adapter.transitions[1] = {
        choose_booster_item = {
            next_state = 2,
            target = { argument = "item_id", reference = "pack-joker" },
            events = { { type = "booster_item_chosen", key = "j_joker", category = "joker" } },
        },
    }
    local _, _, joker_state = call_tool(self.server, self.port, 121, "get_game_state")
    local joker = joker_state.result.structuredContent.state
    local _, _, joker_payload = call_tool(self.server, self.port, 122, "choose_booster_item", {
        state_hash = joker.state_hash,
        item_id = joker.booster_items[1].id,
    })
    luaunit.assertFalse(joker_payload.result.isError)
    luaunit.assertNil(joker_payload.result.structuredContent.events)
    luaunit.assertNil(joker_payload.result.structuredContent.resolution)
    luaunit.assertEquals(joker_payload.result.structuredContent.state.phase, "shop")
end

function TestDiscovery:test_choose_booster_item_keeps_tarot_target_order()
    local observation = booster_pack_observation(
        "arcana",
        {
            {
                target_ref = "pack-strength",
                category = "consumable",
                key = "c_strength",
                name = "Strength",
                description = "Increases rank of up to 2 selected cards by 1",
                min_targets = 1,
                max_targets = 2,
            },
        },
        1,
        {
            hand = {
                { target_ref = "hand-a", key = "H_K", name = "King of Hearts" },
                { target_ref = "hand-b", key = "S_A", name = "Ace of Spades" },
            },
            legal_actions = {
                {
                    tool = "choose_booster_item",
                    fixed_target_refs = { item_id = "pack-strength" },
                    target_refs = { target_ids = { "hand-a", "hand-b" } },
                    arguments = { target_ids = { min_items = 1, max_items = 2 } },
                },
                { tool = "skip_booster" },
            },
        }
    )
    local after = shop_catalog_observation()
    after.decision_sequence = 11
    self.adapter:set_observation(observation)
    self.adapter.states[2] = after
    self.adapter.transitions[1] = {
        choose_booster_item = {
            next_state = 2,
            target = { argument = "item_id", reference = "pack-strength" },
            target_order = { argument = "target_ids", references = { "hand-b", "hand-a" } },
            events = {
                {
                    type = "booster_item_used",
                    key = "c_strength",
                    target_keys = { "S_A", "H_K" },
                },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 123, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 124, "choose_booster_item", {
        state_hash = state.state_hash,
        item_id = state.booster_items[1].id,
        target_ids = { state.hand[2].id, state.hand[1].id },
    })
    local result = action_payload.result.structuredContent

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.phase, "shop")
end

function TestDiscovery:test_choose_booster_item_keeps_spectral_target_order()
    local observation = booster_pack_observation(
        "spectral",
        {
            {
                target_ref = "pack-aura",
                category = "consumable",
                key = "c_aura",
                name = "Aura",
                description = "Add Foil, Holographic, or Polychrome effect to 1 selected card in hand",
                min_targets = 1,
                max_targets = 1,
            },
        },
        1,
        {
            hand = {
                { target_ref = "hand-a", key = "H_K", name = "King of Hearts" },
                { target_ref = "hand-b", key = "S_A", name = "Ace of Spades" },
            },
            legal_actions = {
                {
                    tool = "choose_booster_item",
                    fixed_target_refs = { item_id = "pack-aura" },
                    target_refs = { target_ids = { "hand-a", "hand-b" } },
                    arguments = { target_ids = { min_items = 1, max_items = 1 } },
                },
                { tool = "skip_booster" },
            },
        }
    )
    local after = shop_catalog_observation()
    after.decision_sequence = 11
    self.adapter:set_observation(observation)
    self.adapter.states[2] = after
    self.adapter.transitions[1] = {
        choose_booster_item = {
            next_state = 2,
            target = { argument = "item_id", reference = "pack-aura" },
            target_order = { argument = "target_ids", references = { "hand-b" } },
            events = {
                {
                    type = "booster_item_used",
                    key = "c_aura",
                    target_keys = { "S_A" },
                },
            },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 136, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 137, "choose_booster_item", {
        state_hash = state.state_hash,
        item_id = state.booster_items[1].id,
        target_ids = { state.hand[2].id },
    })
    local result = action_payload.result.structuredContent

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.phase, "shop")
end

function TestDiscovery:test_multi_choice_booster_invalidates_old_item_targets()
    local first = booster_pack_observation("arcana", {
        {
            target_ref = "pack-fool",
            category = "consumable",
            key = "c_fool",
            name = "The Fool",
            description = "Creates the last Tarot or Planet card used during this run",
        },
        {
            target_ref = "pack-emperor",
            category = "consumable",
            key = "c_emperor",
            name = "The Emperor",
            description = "Creates up to 2 random Tarot cards",
        },
    }, 2)
    local second = booster_pack_observation("arcana", {
        {
            target_ref = "pack-emperor-left",
            category = "consumable",
            key = "c_emperor",
            name = "The Emperor",
            description = "Creates up to 2 random Tarot cards",
        },
    }, 1)
    second.decision_sequence = 11
    self.adapter:set_observation(first)
    self.adapter.states[2] = second
    self.adapter.transitions[1] = {
        choose_booster_item = {
            next_state = 2,
            target = { argument = "item_id", reference = "pack-fool" },
            events = { { type = "booster_item_used", key = "c_fool" } },
        },
    }
    self.adapter.transitions[2] = {
        choose_booster_item = {
            error = { code = "INVALID_TARGET", message = "item_id is not a booster item" },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 125, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local old_second = state.booster_items[2].id
    local _, _, choose_payload = call_tool(self.server, self.port, 126, "choose_booster_item", {
        state_hash = state.state_hash,
        item_id = state.booster_items[1].id,
    })
    local next_state = choose_payload.result.structuredContent.state
    local _, _, stale = call_tool(self.server, self.port, 127, "choose_booster_item", {
        state_hash = next_state.state_hash,
        item_id = old_second,
    })

    luaunit.assertFalse(choose_payload.result.isError)
    luaunit.assertEquals(next_state.phase, "booster")
    luaunit.assertEquals(next_state.booster.choices_left, 1)
    luaunit.assertEquals(next_state.booster_items[1].key, "c_emperor")
    luaunit.assertNotEquals(next_state.booster_items[1].id, old_second)
    luaunit.assertTrue(stale.result.isError)
    luaunit.assertEquals(stale.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertEquals(stale.result.structuredContent.state.state_hash, next_state.state_hash)
end

function TestDiscovery:test_skip_booster_leaves_remaining_choices()
    local after = shop_catalog_observation()
    after.decision_sequence = 11
    self.adapter:set_observation(booster_decision_observation())
    self.adapter.states[2] = after
    self.adapter.transitions[1] = {
        skip_booster = {
            next_state = 2,
            events = { { type = "booster_skipped" } },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 128, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 129, "skip_booster", {
        state_hash = state.state_hash,
    })
    local result = action_payload.result.structuredContent

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.phase, "shop")
    luaunit.assertNil(result.state.booster)
end

function TestDiscovery:test_booster_action_errors_include_latest_safe_snapshot()
    self.adapter:set_observation(booster_decision_observation())
    local _, _, state_payload = call_tool(self.server, self.port, 130, "get_game_state")
    local state = state_payload.result.structuredContent.state

    self.adapter:set_observation(hand_observation())
    local _, _, hand_payload = call_tool(self.server, self.port, 131, "get_game_state")
    local hand = hand_payload.result.structuredContent.state
    local _, _, wrong_phase = call_tool(self.server, self.port, 132, "choose_booster_item", {
        state_hash = hand.state_hash,
        item_id = state.booster_items[1].id,
    })
    luaunit.assertTrue(wrong_phase.result.isError)
    luaunit.assertEquals(wrong_phase.result.structuredContent.code, "INVALID_PHASE")
    luaunit.assertEquals(wrong_phase.result.structuredContent.state.state_hash, hand.state_hash)

    local later = booster_decision_observation()
    later.decision_sequence = 11
    self.adapter:set_observation(later)
    local _, _, booster_payload = call_tool(self.server, self.port, 133, "get_game_state")
    local booster = booster_payload.result.structuredContent.state
    local _, _, stale_hash = call_tool(self.server, self.port, 134, "skip_booster", {
        state_hash = state.state_hash,
    })
    luaunit.assertTrue(stale_hash.result.isError)
    luaunit.assertEquals(stale_hash.result.structuredContent.code, "STALE_STATE")
    luaunit.assertEquals(stale_hash.result.structuredContent.state.state_hash, booster.state_hash)

    local _, _, bad_target = call_tool(self.server, self.port, 135, "choose_booster_item", {
        state_hash = booster.state_hash,
        item_id = hand.hand[1].id,
    })
    luaunit.assertTrue(bad_target.result.isError)
    luaunit.assertEquals(bad_target.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertEquals(bad_target.result.structuredContent.state.state_hash, booster.state_hash)
end

function TestDiscovery:test_victory_snapshot_exposes_continue_endless_and_return_to_menu()
    self.adapter:set_observation(victory_observation())
    local _, _, payload = call_tool(self.server, self.port, 140, "get_game_state")
    local state = payload.result.structuredContent.state
    local tools = {}
    for _, action in ipairs(state.legal_actions) do
        tools[#tools + 1] = action.tool
    end

    luaunit.assertFalse(payload.result.isError)
    luaunit.assertEquals(state.phase, "victory")
    luaunit.assertTrue(state.won)
    luaunit.assertEquals(state.ante, 8)
    luaunit.assertEquals(state.round, 24)
    luaunit.assertEquals(state.best_hand, 12000)
    luaunit.assertEquals(state.most_played_hand, "Flush")
    luaunit.assertEquals(state.seed, "MCPTEST")
    luaunit.assertEquals(tools, { "continue_endless", "return_to_menu" })
    luaunit.assertNil(state.cash_out)
end

function TestDiscovery:test_continue_endless_keeps_run_and_enters_endless_decision()
    self.adapter:set_observation(victory_observation())
    self.adapter.states[2] = endless_shop_observation()
    self.adapter.transitions[1] = {
        continue_endless = {
            next_state = 2,
            events = { { type = "continued_endless" }, { type = "cash_out", money = 5 } },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 141, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 142, "continue_endless", {
        state_hash = state.state_hash,
    })
    local result = action_payload.result.structuredContent
    local _, _, replay = call_tool(self.server, self.port, 143, "get_game_state")

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.phase, "shop")
    luaunit.assertEquals(result.state.run_id, "run-alpha")
    luaunit.assertTrue(result.state.won)
    luaunit.assertEquals(result.state.ante, 9)
    luaunit.assertNil(replay.result.structuredContent.events)
    luaunit.assertNil(replay.result.structuredContent.resolution)
    luaunit.assertNotEquals(result.state.state_hash, state.state_hash)
end

function TestDiscovery:test_defeat_snapshot_exposes_only_return_to_menu()
    self.adapter:set_observation(defeat_observation())
    local _, _, payload = call_tool(self.server, self.port, 144, "get_game_state")
    local state = payload.result.structuredContent.state
    local tools = {}
    for _, action in ipairs(state.legal_actions) do
        tools[#tools + 1] = action.tool
    end

    luaunit.assertFalse(payload.result.isError)
    luaunit.assertEquals(state.phase, "defeat")
    luaunit.assertFalse(state.won)
    luaunit.assertEquals(state.defeated_by.key, "bl_small")
    luaunit.assertEquals(state.defeated_by.name, "Small Blind")
    luaunit.assertEquals(state.best_hand, 400)
    luaunit.assertEquals(tools, { "return_to_menu" })
end

function TestDiscovery:test_return_to_menu_from_terminal_states_returns_main_menu()
    local menu = main_menu_observation()
    menu.decision_sequence = 21
    self.adapter:set_observation(victory_observation())
    self.adapter.states[2] = menu
    self.adapter.states[3] = defeat_observation()
    self.adapter.states[4] = menu
    self.adapter.transitions[1] = {
        return_to_menu = {
            next_state = 2,
            events = { { type = "returned_to_menu" } },
        },
    }
    self.adapter.transitions[3] = {
        return_to_menu = {
            next_state = 4,
            events = { { type = "returned_to_menu" } },
        },
    }

    local _, _, victory_payload = call_tool(self.server, self.port, 145, "get_game_state")
    local victory = victory_payload.result.structuredContent.state
    local _, _, from_victory = call_tool(self.server, self.port, 146, "return_to_menu", {
        state_hash = victory.state_hash,
    })
    luaunit.assertFalse(from_victory.result.isError)
    luaunit.assertNil(from_victory.result.structuredContent.events)
    luaunit.assertNil(from_victory.result.structuredContent.resolution)
    luaunit.assertEquals(from_victory.result.structuredContent.state.phase, "main_menu")
    luaunit.assertEquals(from_victory.result.structuredContent.state.run_id, "menu")
    luaunit.assertEquals(
        from_victory.result.structuredContent.state.available_decks[1].name,
        "Red Deck"
    )
    luaunit.assertEquals(
        from_victory.result.structuredContent.state.legal_actions[1].tool,
        "start_run"
    )
    luaunit.assertNil(from_victory.result.structuredContent.state.detail)

    self.adapter.index = 3
    local _, _, defeat_payload = call_tool(self.server, self.port, 147, "get_game_state")
    local defeat = defeat_payload.result.structuredContent.state
    local _, _, from_defeat = call_tool(self.server, self.port, 148, "return_to_menu", {
        state_hash = defeat.state_hash,
    })
    luaunit.assertFalse(from_defeat.result.isError)
    luaunit.assertEquals(from_defeat.result.structuredContent.state.phase, "main_menu")
    luaunit.assertEquals(
        from_defeat.result.structuredContent.state.legal_actions[1].tool,
        "start_run"
    )
end

function TestDiscovery:test_terminal_action_errors_include_latest_safe_snapshot()
    self.adapter:set_observation(defeat_observation())
    local _, _, defeat_payload = call_tool(self.server, self.port, 149, "get_game_state")
    local defeat = defeat_payload.result.structuredContent.state
    local _, _, endless_on_defeat = call_tool(self.server, self.port, 150, "continue_endless", {
        state_hash = defeat.state_hash,
    })
    luaunit.assertTrue(endless_on_defeat.result.isError)
    luaunit.assertEquals(endless_on_defeat.result.structuredContent.code, "INVALID_PHASE")
    luaunit.assertEquals(
        endless_on_defeat.result.structuredContent.state.state_hash,
        defeat.state_hash
    )

    self.adapter:set_observation(hand_observation())
    local _, _, hand_payload = call_tool(self.server, self.port, 151, "get_game_state")
    local hand = hand_payload.result.structuredContent.state
    local _, _, abandon = call_tool(self.server, self.port, 152, "return_to_menu", {
        state_hash = hand.state_hash,
    })
    luaunit.assertTrue(abandon.result.isError)
    luaunit.assertEquals(abandon.result.structuredContent.code, "INVALID_PHASE")
    luaunit.assertEquals(abandon.result.structuredContent.state.state_hash, hand.state_hash)
    luaunit.assertEquals(hand.phase, "hand_play")

    self.adapter:set_observation(victory_observation())
    local _, _, victory_payload = call_tool(self.server, self.port, 153, "get_game_state")
    local victory = victory_payload.result.structuredContent.state
    local later = victory_observation()
    later.decision_sequence = 21
    self.adapter:set_observation(later)
    local _, _, latest_payload = call_tool(self.server, self.port, 154, "get_game_state")
    local latest = latest_payload.result.structuredContent.state
    local _, _, stale = call_tool(self.server, self.port, 155, "continue_endless", {
        state_hash = victory.state_hash,
    })
    luaunit.assertTrue(stale.result.isError)
    luaunit.assertEquals(stale.result.structuredContent.code, "STALE_STATE")
    luaunit.assertEquals(stale.result.structuredContent.state.state_hash, latest.state_hash)
end

function TestDiscovery:test_reroll_shop_invalidates_old_inventory_targets()
    self.adapter:set_observation(shop_catalog_observation())
    self.adapter.states[2] = shop_after_reroll_observation()
    self.adapter.transitions[1] = {
        reroll_shop = {
            next_state = 2,
            events = { { type = "shop_rerolled", money = -5 } },
        },
        buy_shop_item = {
            next_state = 2,
            events = { { type = "item_bought", key = "should-not-run" } },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 89, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local old_item = state.shop_items[1].id
    local _, _, reroll_payload = call_tool(self.server, self.port, 90, "reroll_shop", {
        state_hash = state.state_hash,
    })
    local next_state = reroll_payload.result.structuredContent.state
    local _, _, stale_buy = call_tool(self.server, self.port, 91, "buy_shop_item", {
        state_hash = next_state.state_hash,
        item_id = old_item,
    })

    luaunit.assertFalse(reroll_payload.result.isError)
    luaunit.assertNil(reroll_payload.result.structuredContent.events)
    luaunit.assertNil(reroll_payload.result.structuredContent.resolution)
    luaunit.assertEquals(next_state.shop_items[1].key, "j_jolly")
    luaunit.assertNotEquals(next_state.shop_items[1].id, old_item)
    luaunit.assertTrue(stale_buy.result.isError)
    luaunit.assertEquals(stale_buy.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertEquals(stale_buy.result.structuredContent.state.state_hash, next_state.state_hash)
end

function TestDiscovery:test_sell_owned_item_in_shop_updates_money_and_capacity()
    self.adapter:set_observation(shop_catalog_observation())
    self.adapter.states[2] = shop_after_sell_observation()
    self.adapter.transitions[1] = {
        sell_owned_item = {
            next_state = 2,
            target = { argument = "item_id", reference = "owned-joker" },
            events = { { type = "item_sold", key = "j_joker", money = 1 } },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 92, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 93, "sell_owned_item", {
        state_hash = state.state_hash,
        item_id = state.jokers[1].id,
    })
    local result = action_payload.result.structuredContent
    local tools = {}
    for _, action in ipairs(result.state.legal_actions) do
        tools[#tools + 1] = action.tool
    end

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.money, 13)
    luaunit.assertEquals(#result.state.jokers, 0)
    luaunit.assertEquals(tools, {
        "buy_shop_item",
        "buy_and_use_shop_item",
        "buy_and_use_shop_item",
        "redeem_voucher",
        "open_booster",
        "reroll_shop",
        "leave_shop",
    })
end

function TestDiscovery:test_leave_shop_returns_blind_selection()
    self.adapter:set_observation(shop_catalog_observation())
    local next_blind = blind_selection_observation()
    next_blind.decision_sequence = 10
    next_blind.public_state.money = 12
    self.adapter.states[2] = next_blind
    self.adapter.transitions[1] = {
        leave_shop = {
            next_state = 2,
            events = { { type = "left_shop" } },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 94, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 95, "leave_shop", {
        state_hash = state.state_hash,
    })
    local result = action_payload.result.structuredContent

    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertNil(result.events)
    luaunit.assertNil(result.resolution)
    luaunit.assertEquals(result.state.phase, "blind_selection")
    luaunit.assertEquals(result.state.blinds[1].key, "bl_small")
    luaunit.assertEquals(result.state.blinds[1].name, "Small Blind")
end

function TestDiscovery:test_shop_action_errors_include_latest_safe_snapshot()
    self.adapter:set_observation(shop_catalog_observation())
    self.adapter.transitions[1] = {
        buy_shop_item = {
            error = { code = "ACTION_NOT_ALLOWED", message = "Not enough money" },
        },
    }
    local _, _, state_payload = call_tool(self.server, self.port, 96, "get_game_state")
    local state = state_payload.result.structuredContent.state

    local _, _, funds = call_tool(self.server, self.port, 97, "buy_shop_item", {
        state_hash = state.state_hash,
        item_id = state.shop_items[1].id,
    })
    luaunit.assertTrue(funds.result.isError)
    luaunit.assertEquals(funds.result.structuredContent.code, "ACTION_NOT_ALLOWED")
    luaunit.assertEquals(funds.result.structuredContent.message, "Not enough money")
    luaunit.assertEquals(funds.result.structuredContent.state.state_hash, state.state_hash)
    luaunit.assertNil(funds.result.structuredContent.resolution)
    luaunit.assertNil(funds.result.structuredContent.state.detail)
    luaunit.assertEquals(funds.result.structuredContent.state.shop_items[1].name, "Greedy Joker")
    luaunit.assertEquals(
        funds.result.structuredContent.state.legal_actions[1].tool,
        "buy_shop_item"
    )

    self.adapter.transitions[1].buy_shop_item.error =
        { code = "ACTION_NOT_ALLOWED", message = "Not enough space" }
    local _, _, capacity = call_tool(self.server, self.port, 98, "buy_shop_item", {
        state_hash = state.state_hash,
        item_id = state.shop_items[2].id,
    })
    luaunit.assertTrue(capacity.result.isError)
    luaunit.assertEquals(capacity.result.structuredContent.code, "ACTION_NOT_ALLOWED")
    luaunit.assertEquals(capacity.result.structuredContent.message, "Not enough space")
    luaunit.assertEquals(capacity.result.structuredContent.state.state_hash, state.state_hash)

    self.adapter:set_observation(hand_observation())
    local _, _, hand_payload = call_tool(self.server, self.port, 100, "get_game_state")
    local hand = hand_payload.result.structuredContent.state
    local _, _, wrong_phase = call_tool(self.server, self.port, 101, "buy_shop_item", {
        state_hash = hand.state_hash,
        item_id = state.shop_items[1].id,
    })
    luaunit.assertTrue(wrong_phase.result.isError)
    luaunit.assertEquals(wrong_phase.result.structuredContent.code, "INVALID_PHASE")
    luaunit.assertEquals(wrong_phase.result.structuredContent.state.state_hash, hand.state_hash)

    self.adapter:set_observation(shop_catalog_observation())
    local _, _, shop_again = call_tool(self.server, self.port, 102, "get_game_state")
    local shop = shop_again.result.structuredContent.state
    local expired = shop_catalog_observation()
    expired.decision_sequence = 11
    expired.public_state.shop_items[1].target_ref = "shop-joker-next"
    expired.public_state.legal_actions[1].target_refs.item_id =
        { "shop-joker-next", "shop-planet", "shop-card", "shop-strength" }
    self.adapter:set_observation(expired)
    local _, _, latest = call_tool(self.server, self.port, 103, "get_game_state")
    local current = latest.result.structuredContent.state
    local _, _, stale_target = call_tool(self.server, self.port, 104, "buy_shop_item", {
        state_hash = current.state_hash,
        item_id = shop.shop_items[1].id,
    })
    luaunit.assertTrue(stale_target.result.isError)
    luaunit.assertEquals(stale_target.result.structuredContent.code, "INVALID_TARGET")
    luaunit.assertEquals(stale_target.result.structuredContent.state.state_hash, current.state_hash)
end

function TestDiscovery:test_snapshot_parameter_limits_are_enforced()
    self.adapter:set_observation(hand_observation())
    local _, _, state_payload = call_tool(self.server, self.port, 14, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, action_payload = call_tool(self.server, self.port, 15, "play_hand", {
        state_hash = state.state_hash,
        card_ids = { state.hand[1].id, state.hand[2].id, state.hand[3].id },
    })

    luaunit.assertTrue(action_payload.result.isError)
    luaunit.assertEquals(action_payload.result.structuredContent.code, "INVALID_PARAMS")
    luaunit.assertEquals(action_payload.result.structuredContent.state.state_hash, state.state_hash)
end

function TestDiscovery:test_required_card_values_are_public_and_enforced()
    local forced = hand_observation()
    forced.public_state.hand[2].forced_selection = true
    forced.public_state.current_blind.score_requirement = 600
    forced.public_state.current_blind.disabled = false
    forced.public_state.current_blind.hand_debuff = {
        min_cards = 5,
        required_poker_hand = "Pair",
        forbidden_poker_hands = { "High Card" },
    }
    forced.public_state.remaining_deck[1].played_this_ante = true
    forced.public_state.remaining_deck[1].debuffed = true
    for _, action in ipairs(forced.public_state.legal_actions) do
        action.required_target_refs = { card_ids = { "card-b" } }
    end
    self.adapter:set_observation(forced)

    local _, _, state_payload = call_tool(self.server, self.port, 150, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local defs = ToolCatalog.get("get_game_state").outputSchema["$defs"]
    luaunit.assertEquals(defs.argument_constraint.properties.required_values.type, "array")
    luaunit.assertEquals(defs.playing_card.properties.forced_selection.type, "boolean")
    luaunit.assertEquals(defs.remaining_deck_entry.properties.played_this_ante.type, "boolean")
    luaunit.assertEquals(defs.remaining_deck_entry.properties.debuffed.type, "boolean")
    luaunit.assertEquals(defs.blind.properties.disabled.type, "boolean")
    luaunit.assertEquals(defs.blind.properties.hand_debuff["$ref"], "#/$defs/hand_debuff")
    luaunit.assertNil(
        ToolCatalog.validate_schema(
            ToolCatalog.get("get_game_state").outputSchema,
            state_payload.result.structuredContent
        )
    )
    luaunit.assertTrue(state.hand[2].forced_selection)
    luaunit.assertEquals(state.current_blind.score_requirement, 600)
    luaunit.assertFalse(state.current_blind.disabled)
    luaunit.assertEquals(state.current_blind.hand_debuff.min_cards, 5)
    luaunit.assertTrue(state.remaining_deck[1].played_this_ante)
    luaunit.assertTrue(state.remaining_deck[1].debuffed)

    for _, name in ipairs({ "play_hand", "discard_cards" }) do
        local legal_action
        for _, action in ipairs(state.legal_actions) do
            if action.tool == name then
                legal_action = action
                break
            end
        end
        luaunit.assertNotNil(legal_action)
        luaunit.assertEquals(legal_action.arguments.card_ids.required_values, {
            state.hand[2].id,
        })

        local _, _, rejected = call_tool(self.server, self.port, 151, name, {
            state_hash = state.state_hash,
            card_ids = { state.hand[1].id },
        })
        luaunit.assertTrue(rejected.result.isError)
        luaunit.assertEquals(rejected.result.structuredContent.code, "INVALID_PARAMS")
        luaunit.assertStrContains(
            rejected.result.structuredContent.message,
            "card_ids must include"
        )
        luaunit.assertEquals(rejected.result.structuredContent.state.state_hash, state.state_hash)
    end
end

function TestDiscovery:test_stale_state_error_contains_latest_safe_snapshot()
    local _, _, state_payload = call_tool(self.server, self.port, 12, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local _, _, stale_payload = call_tool(self.server, self.port, 13, "select_blind", {
        state_hash = "deadbeef",
        blind_id = state.blinds[1].id,
    })
    local error = stale_payload.result.structuredContent

    luaunit.assertTrue(stale_payload.result.isError)
    luaunit.assertEquals(error.code, "STALE_STATE")
    luaunit.assertEquals(error.message, "state_hash does not match the current decision state")
    luaunit.assertNil(error.resolution)
    luaunit.assertNil(error.events)
    luaunit.assertNil(error.state.detail)
    luaunit.assertEquals(error.state.state_hash, state.state_hash)
    luaunit.assertEquals(error.state.visibility, "fair")
    luaunit.assertEquals(error.state.phase, "blind_selection")
    luaunit.assertEquals(error.state.blinds[1].key, "bl_small")
    luaunit.assertEquals(error.state.blinds[1].id, "small-blind")
    luaunit.assertEquals(error.state.blinds[1].name, "Small Blind")
    luaunit.assertEquals(error.state.blinds[1].description, "Score at least 300 chips.")
    luaunit.assertEquals(error.state.game_version, "1.0.1o-FULL")
    luaunit.assertEquals(error.state.legal_actions[1].tool, "select_blind")
    luaunit.assertEquals(JSON.decode(stale_payload.result.content[1].text), error)
end

function TestDiscovery:test_target_ids_expire_with_their_source_snapshot()
    local _, _, first_payload = call_tool(self.server, self.port, 14, "get_game_state")
    local first_state = first_payload.result.structuredContent.state
    local next_observation = blind_selection_observation()
    next_observation.decision_sequence = 8
    next_observation.public_state.blinds[1].target_ref = "boss-blind"
    next_observation.public_state.blinds[1].key = "bl_boss"
    next_observation.public_state.blinds[1].name = "The Hook"
    next_observation.public_state.legal_actions[1].target_refs.blind_id = { "boss-blind" }
    self.adapter:set_observation(next_observation)
    local _, _, current_payload = call_tool(self.server, self.port, 15, "get_game_state")
    local current_state = current_payload.result.structuredContent.state
    local _, _, target_payload = call_tool(self.server, self.port, 16, "select_blind", {
        state_hash = current_state.state_hash,
        blind_id = first_state.blinds[1].id,
    })
    local error = target_payload.result.structuredContent

    luaunit.assertTrue(target_payload.result.isError)
    luaunit.assertEquals(error.code, "INVALID_TARGET")
    luaunit.assertEquals(error.state.state_hash, current_state.state_hash)
    luaunit.assertNotEquals(current_state.blinds[1].id, first_state.blinds[1].id)
    luaunit.assertStrContains(error.message, "allowed values: boss-blind")
end

function TestDiscovery:test_concurrent_modifications_with_one_hash_have_one_winner()
    local _, _, state_payload = call_tool(self.server, self.port, 17, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local arguments = { state_hash = state.state_hash, blind_id = state.blinds[1].id }
    local first_body = rpc_body(18, "tools/call", {
        name = "select_blind",
        arguments = arguments,
    })
    local second_body = rpc_body(19, "tools/call", {
        name = "select_blind",
        arguments = arguments,
    })
    local requests = {
        make_request(self.port, first_body, {
            headers = { ["Mcp-Method"] = "tools/call" },
        }),
        make_request(self.port, second_body, {
            headers = { ["Mcp-Method"] = "tools/call" },
        }),
    }
    local responses = send_http_concurrently(self.server, self.port, requests)
    local success
    local stale
    for _, response in ipairs(responses) do
        local _, _, response_body = parse_http(response)
        local payload = JSON.decode(response_body)
        if payload.result.isError then
            stale = payload.result.structuredContent
        else
            success = payload.result.structuredContent
        end
    end

    luaunit.assertNotNil(success)
    luaunit.assertNotNil(stale)
    luaunit.assertEquals(success.state.decision_sequence, 8)
    luaunit.assertEquals(stale.code, "STALE_STATE")
    luaunit.assertEquals(stale.state.decision_sequence, 8)
end

function TestDiscovery:test_tool_validation_errors_are_structured()
    local _, _, state_payload = call_tool(self.server, self.port, 20, "get_game_state")
    local state = state_payload.result.structuredContent.state

    local _, _, missing_hash = call_tool(self.server, self.port, 21, "select_blind", {
        blind_id = state.blinds[1].id,
    })
    luaunit.assertTrue(missing_hash.result.isError)
    luaunit.assertEquals(missing_hash.result.structuredContent.code, "INVALID_PARAMS")
    luaunit.assertNil(missing_hash.result.structuredContent.resolution)
    luaunit.assertNil(missing_hash.result.structuredContent.state.detail)
    luaunit.assertEquals(missing_hash.result.structuredContent.state.state_hash, state.state_hash)
    luaunit.assertEquals(missing_hash.result.structuredContent.state.blinds[1].name, "Small Blind")
    luaunit.assertEquals(
        missing_hash.result.structuredContent.state.legal_actions[1].tool,
        "select_blind"
    )

    local _, _, invalid_phase = call_tool(self.server, self.port, 22, "reroll_shop", {
        state_hash = state.state_hash,
    })
    luaunit.assertTrue(invalid_phase.result.isError)
    luaunit.assertEquals(invalid_phase.result.structuredContent.code, "INVALID_PHASE")
    luaunit.assertNil(invalid_phase.result.structuredContent.resolution)
    luaunit.assertNil(invalid_phase.result.structuredContent.state.detail)
    luaunit.assertEquals(invalid_phase.result.structuredContent.state.state_hash, state.state_hash)
    luaunit.assertEquals(invalid_phase.result.structuredContent.state.blinds[1].name, "Small Blind")

    local _, _, invalid_visibility = call_tool(self.server, self.port, 23, "get_game_state", {
        visibility = "xray",
    })
    luaunit.assertTrue(invalid_visibility.result.isError)
    luaunit.assertEquals(invalid_visibility.result.structuredContent.code, "INVALID_PARAMS")
end

function TestDiscovery:test_timeout_and_blocked_errors_do_not_include_snapshots()
    local _, _, state_payload = call_tool(self.server, self.port, 25, "get_game_state")
    local state = state_payload.result.structuredContent.state
    for index, code in ipairs({ "DECISION_TIMEOUT", "GAME_BLOCKED" }) do
        self.adapter.transitions[1].select_blind.error = {
            code = code,
            message = "Decision state is unavailable",
        }
        local _, _, error_payload = call_tool(self.server, self.port, 25 + index, "select_blind", {
            state_hash = state.state_hash,
            blind_id = state.blinds[1].id,
        })
        local error = error_payload.result.structuredContent
        luaunit.assertEquals(error.code, code)
        luaunit.assertNil(error.state)
        luaunit.assertNil(error.resolution)
        luaunit.assertNil(error.events)
        luaunit.assertStrContains(error_payload.result.content[1].text, '"state":null')
        luaunit.assertEquals(JSON.decode(error_payload.result.content[1].text), error)
    end
end

function TestDiscovery:test_action_waits_before_returning_game_blocked()
    local adapter = FakeBalatroAdapter.new({
        states = { blind_selection_observation(), hand_observation() },
        transitions = { [1] = { select_blind = { next_state = 2 } } },
    })
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local _, _, state_payload = call_tool(server, port, 28, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local observations_before = adapter.observe_count
    local logs = {}
    server.log = function(level, message)
        logs[#logs + 1] = level .. " " .. message
    end
    adapter.pending = { observations = 100000, next_state = 1, code = "GAME_BLOCKED" }
    local _, _, blocked_payload = call_tool(server, port, 29, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    server:stop()
    local error = blocked_payload.result.structuredContent

    luaunit.assertEquals(error.code, "GAME_BLOCKED")
    luaunit.assertNil(error.state)
    luaunit.assertNil(error.resolution)
    luaunit.assertStrContains(blocked_payload.result.content[1].text, '"state":null')
    luaunit.assertTrue(adapter.observe_count > observations_before + 1)
    local failure_context
    local request_error
    for _, line in ipairs(logs) do
        if line:find("debug failure.context", 1, true) then
            failure_context = line
        elseif line:find("error request.error", 1, true) then
            request_error = line
        end
    end
    luaunit.assertNotNil(failure_context)
    luaunit.assertStrContains(failure_context, "retry_action")
    luaunit.assertNotNil(request_error)
    luaunit.assertStrContains(request_error, "code=GAME_BLOCKED")
    luaunit.assertNotStrContains(request_error, "may_have_committed=true")
end

function TestDiscovery:test_pending_timeout_abandons_resolution_capture()
    local adapter = FakeBalatroAdapter.new({
        states = { blind_selection_observation(), hand_observation() },
        transitions = {
            [1] = {
                select_blind = {
                    pending = { observations = 100000, next_state = 2 },
                    capture = true,
                },
            },
        },
    })
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local _, _, state_payload = call_tool(server, port, 3001, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local logs = {}
    server.log = function(level, message)
        logs[#logs + 1] = level .. " " .. message
    end
    local _, _, result_payload = call_tool(server, port, 3002, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    server:stop()

    luaunit.assertEquals(result_payload.result.structuredContent.code, "DECISION_TIMEOUT")
    luaunit.assertEquals(adapter.finished_captures, 0)
    luaunit.assertEquals(adapter.abandoned_captures, 1)
    local failure_context
    local request_error
    for _, line in ipairs(logs) do
        if line:find("debug failure.context", 1, true) then
            failure_context = line
        elseif line:find("error request.error", 1, true) then
            request_error = line
        end
    end
    luaunit.assertNotNil(failure_context)
    luaunit.assertStrContains(failure_context, "bl_small")
    luaunit.assertNotNil(request_error)
    luaunit.assertStrContains(request_error, "may_have_committed=true")
    luaunit.assertStrContains(request_error, "tool=select_blind")
end

function TestDiscovery:test_hermit_timeout_trace_explains_cost_and_money_effect()
    local shop = shop_catalog_observation()
    shop.public_state.money = 9
    shop.public_state.shop_items[2].key = "c_hermit"
    shop.public_state.shop_items[2].name = "The Hermit"
    shop.public_state.shop_items[2].description = "Doubles money"
    local adapter = FakeBalatroAdapter.new({
        states = { shop },
        transitions = {
            [1] = {
                buy_and_use_shop_item = {
                    pending = {
                        observations = 100000,
                        next_state = 1,
                        observe_block = "observe pending state=SHOP money=12 pending_d=6 pending_dir=-1",
                        diagnostic = {
                            money = 12,
                            pending_dollars = 6,
                            pending_dollars_direction = -1,
                            state = "SHOP",
                        },
                    },
                    target = { argument = "item_id", reference = "shop-planet" },
                },
            },
        },
    })
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local _, _, state_payload = call_tool(server, port, 3005, "get_game_state")
    local state = state_payload.result.structuredContent.state
    local logs = {}
    server.log = function(level, message)
        logs[#logs + 1] = level .. " " .. message
    end
    local _, _, result_payload = call_tool(server, port, 3006, "buy_and_use_shop_item", {
        state_hash = state.state_hash,
        item_id = state.shop_items[2].id,
    })
    server:stop()

    luaunit.assertEquals(result_payload.result.structuredContent.code, "DECISION_TIMEOUT")
    local failure_context
    for _, line in ipairs(logs) do
        if line:find("debug failure.context", 1, true) then
            failure_context = line
        end
    end
    luaunit.assertNotNil(failure_context)
    luaunit.assertStrContains(failure_context, "c_hermit")
    luaunit.assertStrContains(failure_context, 'money\\":9')
    luaunit.assertStrContains(failure_context, 'money\\":12')
    luaunit.assertStrContains(failure_context, "pending_dollars")
    luaunit.assertStrContains(failure_context, "pending_dollars_direction")
end

function TestDiscovery:test_adapter_exception_logs_structured_internal_error_after_dispatch()
    local adapter = FakeBalatroAdapter.new({ states = { blind_selection_observation() } })
    local logs = {}
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        server_info = { name = "test", version = "0.1.0" },
        log = function(level, message)
            logs[#logs + 1] = level .. " " .. message
        end,
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local _, _, state_payload = call_tool(server, port, 3003, "get_game_state")
    local state = state_payload.result.structuredContent.state
    logs = {}
    adapter.execute = function()
        error({ reason = "adapter exploded", callback = function() end })
    end
    local _, _, result_payload = call_tool(server, port, 3004, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    server:stop()

    luaunit.assertEquals(result_payload.result.structuredContent.code, "INTERNAL_ERROR")
    local diagnostic_error
    local request_error
    for _, line in ipairs(logs) do
        if line:find("error diagnostic.error", 1, true) then
            diagnostic_error = line
        elseif line:find("error request.error", 1, true) then
            request_error = line
        end
    end
    luaunit.assertNotNil(diagnostic_error)
    luaunit.assertStrContains(diagnostic_error, 'error="<table>"')
    luaunit.assertStrContains(diagnostic_error, "stage=action.execute")
    luaunit.assertStrContains(diagnostic_error, "tool=select_blind")
    luaunit.assertNotStrContains(diagnostic_error, "0x")
    luaunit.assertNotNil(request_error)
    luaunit.assertStrContains(request_error, "may_have_committed=true")
end

function TestDiscovery:test_recovered_overlay_is_not_reported_as_continuously_blocked()
    local adapter = FakeBalatroAdapter.new({
        states = { blind_selection_observation(), hand_observation() },
        transitions = {
            [1] = {
                select_blind = {
                    pending = { observations = 100000, next_state = 2, code = "GAME_BLOCKED" },
                },
            },
        },
    })
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local _, _, state_payload = call_tool(server, port, 30, "get_game_state")
    local state = state_payload.result.structuredContent.state
    adapter.pending = { observations = 2, next_state = 1, code = "GAME_BLOCKED" }
    local _, _, result_payload = call_tool(server, port, 31, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    server:stop()

    luaunit.assertEquals(result_payload.result.structuredContent.code, "DECISION_TIMEOUT")
end

function TestDiscovery:test_unknown_tool_is_invalid_json_rpc_params()
    local logs = {}
    self.server.log = function(level, message)
        logs[#logs + 1] = level .. " " .. message
    end
    local body = rpc_body(24, "tools/call", { name = "not_a_tool" })
    local request = make_request(self.port, body, {
        headers = { ["Mcp-Method"] = "tools/call" },
    })
    local status, _, response_body = parse_http(send_http(self.server, self.port, request))
    local payload = JSON.decode(response_body)

    luaunit.assertEquals(status, 400)
    luaunit.assertEquals(payload.error.code, -32602)
    luaunit.assertStrContains(logs[1], "debug request.begin")
    luaunit.assertStrContains(logs[1], "tool=not_a_tool")
    luaunit.assertStrContains(logs[#logs], "error request.error")
    luaunit.assertStrContains(logs[#logs], "code=-32602")
    luaunit.assertStrContains(logs[#logs], "stage=protocol")
end

function TestDiscovery:test_missing_request_metadata_is_invalid_params()
    local body = [[{"jsonrpc":"2.0","id":101,"method":"server/discover","params":{}}]]
    local status, _, response_body =
        parse_http(send_http(self.server, self.port, make_request(self.port, body)))
    local payload = JSON.decode(response_body)

    luaunit.assertEquals(status, 400)
    luaunit.assertEquals(payload.id, 101)
    luaunit.assertEquals(payload.error.code, -32602)
end

function TestDiscovery:test_unsupported_protocol_version_lists_supported_versions()
    local body =
        [[{"jsonrpc":"2.0","id":301,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"v999.0.0","io.modelcontextprotocol/clientCapabilities":{}}}}]]
    local request = make_request(self.port, body, {
        headers = { ["MCP-Protocol-Version"] = "v999.0.0" },
    })
    local status, _, response_body = parse_http(send_http(self.server, self.port, request))
    local payload = JSON.decode(response_body)

    luaunit.assertEquals(status, 400)
    luaunit.assertEquals(payload.id, 301)
    luaunit.assertEquals(payload.error.code, -32022)
    luaunit.assertEquals(payload.error.data.requested, "v999.0.0")
    luaunit.assertEquals(payload.error.data.supported, { "2026-07-28" })
end

function TestDiscovery:test_header_and_body_metadata_must_match()
    local body =
        [[{"jsonrpc":"2.0","id":302,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"v999.0.0","io.modelcontextprotocol/clientCapabilities":{}}}}]]
    local status, _, response_body =
        parse_http(send_http(self.server, self.port, make_request(self.port, body)))
    local payload = JSON.decode(response_body)

    luaunit.assertEquals(status, 400)
    luaunit.assertEquals(payload.id, 302)
    luaunit.assertEquals(payload.error.code, -32020)
end

function TestDiscovery:test_malformed_json_returns_parse_error()
    local logs = {}
    self.server.log = function(level, message)
        logs[#logs + 1] = level .. " " .. message
    end
    local status, _, response_body =
        parse_http(send_http(self.server, self.port, make_request(self.port, "{")))
    local payload = JSON.decode(response_body)

    luaunit.assertEquals(status, 400)
    luaunit.assertStrContains(response_body, '"id":null')
    luaunit.assertEquals(payload.error.code, -32700)
    luaunit.assertStrContains(logs[1], "debug request.begin")
    luaunit.assertStrContains(logs[#logs], "error request.error")
    luaunit.assertStrContains(logs[#logs], "code=-32700")
end

function TestDiscovery:test_non_scalar_request_id_is_invalid_request()
    local body =
        [[{"jsonrpc":"2.0","id":{},"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}]]
    local status, _, response_body =
        parse_http(send_http(self.server, self.port, make_request(self.port, body)))
    local payload = JSON.decode(response_body)

    luaunit.assertEquals(status, 400)
    luaunit.assertEquals(payload.error.code, -32600)
end

function TestDiscovery:test_unknown_method_returns_json_rpc_method_not_found()
    local body =
        [[{"jsonrpc":"2.0","id":401,"method":"ping","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}]]
    local request = make_request(self.port, body, {
        headers = { ["Mcp-Method"] = "ping" },
    })
    local status, _, response_body = parse_http(send_http(self.server, self.port, request))
    local payload = JSON.decode(response_body)

    luaunit.assertEquals(status, 404)
    luaunit.assertEquals(payload.id, 401)
    luaunit.assertEquals(payload.error.code, -32601)
end

function TestDiscovery:test_notification_returns_accepted_without_body()
    local body =
        [[{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}]]
    local request = make_request(self.port, body, {
        headers = { ["Mcp-Method"] = "notifications/cancelled" },
    })
    local status, headers, response_body = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 202)
    luaunit.assertEquals(headers["connection"], "close")
    luaunit.assertEquals(response_body, "")
end

function TestDiscovery:test_local_browser_origin_is_allowed()
    local request = make_request(self.port, valid_discovery_body, {
        headers = { Origin = "http://localhost:3000" },
    })
    local status = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 200)
end

function TestDiscovery:test_non_local_host_is_rejected()
    local request = make_request(self.port, valid_discovery_body, {
        headers = { Host = "example.com" },
    })
    local status = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 403)
end

function TestDiscovery:test_non_local_origin_is_rejected()
    local request = make_request(self.port, valid_discovery_body, {
        headers = { Origin = "https://example.com" },
    })
    local status = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 403)
end

function TestDiscovery:test_host_without_port_is_rejected()
    local request = make_request(self.port, valid_discovery_body, {
        headers = { Host = "127.0.0.1" },
    })
    local status = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 403)
end

function TestDiscovery:test_localhost_host_is_allowed()
    local request = make_request(self.port, valid_discovery_body, {
        headers = { Host = "localhost:" .. self.port },
    })
    local status, headers = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 200)
    luaunit.assertEquals(headers.connection, "close")
end

function TestDiscovery:test_loopback_origin_without_port_is_allowed()
    local request = make_request(self.port, valid_discovery_body, {
        headers = { Origin = "http://127.0.0.1" },
    })
    local status = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 200)
end

function TestDiscovery:test_non_post_method_is_rejected()
    local request = make_request(self.port, valid_discovery_body, { method = "GET" })
    local status, headers = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 405)
    luaunit.assertEquals(headers.allow, "POST")
end

function TestDiscovery:test_non_json_content_type_is_rejected()
    local request = make_request(self.port, valid_discovery_body, {
        headers = { ["Content-Type"] = "application/json-seq" },
    })
    local status = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 415)
end

function TestDiscovery:test_oversized_body_is_rejected_before_reading_it()
    local request = make_request(self.port, valid_discovery_body, { content_length = 513 })
    local status = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 413)
end

function TestDiscovery:test_oversized_headers_are_rejected()
    local request = make_request(self.port, valid_discovery_body, {
        headers = { ["X-Fill"] = string.rep("x", 512) },
    })
    local status = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 431)
end

function TestDiscovery:test_accept_header_must_allow_json_and_event_stream()
    local request = make_request(self.port, valid_discovery_body, {
        headers = { Accept = "application/json" },
    })
    local status = parse_http(send_http(self.server, self.port, request))

    luaunit.assertEquals(status, 406)
end

function TestDiscovery:test_port_conflict_disables_only_the_second_server()
    local second_server = GameMcpServer.new({
        json = JSON,
        adapter = self.adapter,
        tool_catalog = ToolCatalog,
        port = self.port,
        worker_source = read_file("src/http_worker.lua"),
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(second_server:start())
    wait_until(second_server, function()
        return second_server:get_status().state ~= "starting"
    end, 2)

    local state = second_server:get_status().state
    second_server:stop()
    luaunit.assertEquals(state, "error")

    local status =
        parse_http(send_http(self.server, self.port, make_request(self.port, valid_discovery_body)))
    luaunit.assertEquals(status, 200)
end

function TestDiscovery:test_encyclopedia_query_succeeds_in_menu_and_run_without_advancing()
    self.adapter.states = { main_menu_observation(), blind_selection_observation() }
    self.adapter.index = 1

    local _, _, menu_state = call_tool(self.server, self.port, 300, "get_game_state")
    local menu = menu_state.result.structuredContent.state
    local _, _, menu_encyclopedia =
        call_tool(self.server, self.port, 301, "get_effect_encyclopedia")
    local _, _, menu_after = call_tool(self.server, self.port, 302, "get_game_state")
    local encyclopedia = menu_encyclopedia.result.structuredContent.effect_encyclopedia

    luaunit.assertFalse(menu_encyclopedia.result.isError)
    luaunit.assertNil(menu_encyclopedia.result.structuredContent.state)
    luaunit.assertEquals(encyclopedia.visibility, "fair")
    luaunit.assertEquals(encyclopedia.entries[1].key, "j_joker")
    luaunit.assertEquals(menu_after.result.structuredContent.state.state_hash, menu.state_hash)
    luaunit.assertEquals(
        menu_after.result.structuredContent.state.decision_sequence,
        menu.decision_sequence
    )
    for _, action in ipairs(menu.legal_actions) do
        luaunit.assertNotEquals(action.tool, "get_effect_encyclopedia")
    end
    luaunit.assertNil(menu_state.result.structuredContent.effect_encyclopedia)
    luaunit.assertEquals(menu.available_decks[1].name, "Red Deck")

    self.adapter.index = 2
    local _, _, run_state = call_tool(self.server, self.port, 303, "get_game_state")
    local run = run_state.result.structuredContent.state
    local _, _, run_encyclopedia = call_tool(self.server, self.port, 304, "get_effect_encyclopedia")
    local _, _, run_after = call_tool(self.server, self.port, 305, "get_game_state")

    luaunit.assertFalse(run_encyclopedia.result.isError)
    luaunit.assertEquals(run.phase, "blind_selection")
    luaunit.assertEquals(run.blinds[1].name, "Small Blind")
    luaunit.assertEquals(run_after.result.structuredContent.state.state_hash, run.state_hash)
    luaunit.assertEquals(
        run_after.result.structuredContent.state.decision_sequence,
        run.decision_sequence
    )
    for _, action in ipairs(run.legal_actions) do
        luaunit.assertNotEquals(action.tool, "get_effect_encyclopedia")
    end
end

function TestDiscovery:test_encyclopedia_visibility_filters_fixture_entries()
    local _, _, default_payload = call_tool(self.server, self.port, 310, "get_effect_encyclopedia")
    local _, _, fair_payload = call_tool(self.server, self.port, 311, "get_effect_encyclopedia")
    local _, _, hashed = call_tool(self.server, self.port, 313, "get_effect_encyclopedia", {
        state_hash = "deadbeef",
    })
    self.server:set_visibility("omniscient")
    local _, _, omniscient_payload =
        call_tool(self.server, self.port, 312, "get_effect_encyclopedia")

    local default_entries = default_payload.result.structuredContent.effect_encyclopedia.entries
    local fair = fair_payload.result.structuredContent.effect_encyclopedia
    local omniscient = omniscient_payload.result.structuredContent.effect_encyclopedia
    local by_key = {}
    for _, entry in ipairs(fair.entries) do
        by_key[entry.key] = entry
    end
    local omniscient_keys = {}
    for _, entry in ipairs(omniscient.entries) do
        omniscient_keys[entry.key] = entry
    end

    luaunit.assertEquals(default_entries, fair.entries)
    luaunit.assertEquals(fair.visibility, "fair")
    luaunit.assertEquals(by_key.j_joker, {
        key = "j_joker",
        set = "Joker",
        name = "Joker",
        description = "+4 Mult",
    })
    luaunit.assertEquals(by_key.j_blueprint, { key = "j_blueprint", set = "Joker" })
    luaunit.assertNil(by_key.j_blueprint.name)
    luaunit.assertNil(by_key.j_blueprint.description)
    luaunit.assertNil(by_key.j_caino)
    luaunit.assertNil(by_key.c_soul)
    luaunit.assertEquals(omniscient.visibility, "omniscient")
    luaunit.assertEquals(omniscient_keys.j_blueprint.name, "Blueprint")
    luaunit.assertEquals(omniscient_keys.j_caino.name, "Caino")
    luaunit.assertNotNil(omniscient_keys.j_caino.description)
    luaunit.assertEquals(omniscient_keys.c_soul.name, "The Soul")
    luaunit.assertNotNil(omniscient_keys.c_soul.description)
    luaunit.assertTrue(hashed.result.isError)
    luaunit.assertEquals(hashed.result.structuredContent.code, "INVALID_PARAMS")
end

function TestDiscovery:test_encyclopedia_text_is_structured_json()
    self.server:set_visibility("omniscient")
    local _, _, payload = call_tool(self.server, self.port, 320, "get_effect_encyclopedia")
    local encyclopedia = payload.result.structuredContent.effect_encyclopedia
    local text = payload.result.content[1].text

    luaunit.assertEquals(JSON.decode(text), payload.result.structuredContent)
    luaunit.assertEquals(JSON.decode(text).effect_encyclopedia.visibility, "omniscient")
    luaunit.assertEquals(#JSON.decode(text).effect_encyclopedia.entries, #encyclopedia.entries)
    luaunit.assertStrContains(
        JSON.decode(text).effect_encyclopedia.entries[1].description,
        encyclopedia.entries[1].description
    )
end

function TestDiscovery:test_pending_observe_logs_reason_changes_without_leaking_to_mcp()
    local logs = {}
    local adapter = FakeBalatroAdapter.new({ states = { blind_selection_observation() } })
    adapter.pending = {
        observations = 100000,
        next_state = 1,
        observe_block = function(self)
            if self.observe_count == 1 then
                return "observe pending state=SHOP paused=true"
            end
            return "observe pending state=SHOP paused=false"
        end,
    }
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
        log = function(level, message)
            logs[#logs + 1] = level .. " " .. message
        end,
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local _, _, payload = call_tool(server, server:get_status().port, 400, "get_game_state")
    server:stop()

    luaunit.assertTrue(payload.result.isError)
    luaunit.assertEquals(payload.result.structuredContent.code, "DECISION_TIMEOUT")
    luaunit.assertNil(payload.result.structuredContent.observe_block)

    local info = {}
    local errors = {}
    local debugs = {}
    for _, line in ipairs(logs) do
        if line:find("^info ", 1, false) then
            info[#info + 1] = line
        elseif line:find("^error ", 1, false) then
            errors[#errors + 1] = line
        elseif line:find("^debug ", 1, false) then
            debugs[#debugs + 1] = line
        end
    end
    luaunit.assertEquals(info, {})
    luaunit.assertEquals(#errors, 1)
    luaunit.assertStrContains(errors[1], "error request.error")
    luaunit.assertStrContains(errors[1], "code=DECISION_TIMEOUT")
    luaunit.assertStrContains(errors[1], "trace=1")
    luaunit.assertEquals(#debugs, 4)
    luaunit.assertStrContains(debugs[1], "debug request.begin")
    luaunit.assertStrContains(debugs[2], "debug observe.wait")
    luaunit.assertStrContains(debugs[2], "paused=true")
    luaunit.assertStrContains(debugs[3], "debug observe.wait")
    luaunit.assertStrContains(debugs[3], "paused=false")
    luaunit.assertStrContains(debugs[4], "debug failure.context")
    luaunit.assertStrContains(debugs[4], "chunk=1/1")
    luaunit.assertStrContains(debugs[4], "DECISION_TIMEOUT")
    luaunit.assertStrContains(debugs[4], "paused=false")
    luaunit.assertStrContains(debugs[4], "trace=1")
end

function TestDiscovery:test_diagnostic_trace_bounds_large_lines_and_failure_context()
    local logs = {}
    local adapter = FakeBalatroAdapter.new({ states = { blind_selection_observation() } })
    adapter.pending = {
        observations = 100000,
        next_state = 1,
        observe_block = "observe pending details=" .. string.rep(string.char(34, 92), 150 * 1024),
    }
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
        log = function(level, message)
            logs[#logs + 1] = level .. " " .. message
        end,
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local _, _, payload = call_tool(server, server:get_status().port, 402, "get_game_state")
    server:stop()

    luaunit.assertEquals(payload.result.structuredContent.code, "DECISION_TIMEOUT")
    local bounded_wait = false
    local context_chunks = 0
    local truncated_context = false
    for _, line in ipairs(logs) do
        luaunit.assertTrue(#line <= 64 * 1024)
        if line:find("debug observe.wait", 1, true) then
            bounded_wait = line:find("truncated=true", 1, true) ~= nil
        elseif line:find("debug failure.context", 1, true) then
            context_chunks = context_chunks + 1
            truncated_context = truncated_context or line:find("truncated=true", 1, true) ~= nil
        end
    end
    luaunit.assertTrue(bounded_wait, table.concat(logs, "\n"))
    luaunit.assertTrue(context_chunks > 1, table.concat(logs, "\n"))
    luaunit.assertTrue(truncated_context, table.concat(logs, "\n"))
end

function TestDiscovery:test_error_logging_keeps_core_wait_summary_without_debug_details()
    local logs = {}
    local adapter = FakeBalatroAdapter.new({ states = { blind_selection_observation() } })
    adapter.pending = {
        observations = 100000,
        next_state = 1,
        observe_block = "observe pending " .. string.rep("x", 100 * 1024),
        diagnostic = {
            money = 12,
            pending_dollars = 6,
            pending_dollars_direction = -1,
            state = "SHOP",
        },
    }
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
        log_enabled = function(level)
            return level ~= "debug"
        end,
        log = function(level, message)
            logs[#logs + 1] = level .. " " .. message
        end,
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local _, _, payload = call_tool(server, server:get_status().port, 405, "get_game_state")
    server:stop()

    luaunit.assertEquals(payload.result.structuredContent.code, "DECISION_TIMEOUT")
    luaunit.assertEquals(#logs, 1)
    luaunit.assertStrContains(logs[1], "error request.error")
    luaunit.assertStrContains(logs[1], "money=12")
    luaunit.assertStrContains(logs[1], "pending_dollars=6")
    luaunit.assertStrContains(logs[1], "pending_dollars_direction=-1")
    luaunit.assertStrContains(logs[1], "wait_state=SHOP")
    luaunit.assertNotStrContains(logs[1], "details=")
    luaunit.assertTrue(#logs[1] < 64 * 1024)
end

function TestDiscovery:test_successful_tool_logs_correlated_diagnostic_trace()
    local logs = {}
    local server = GameMcpServer.new({
        adapter = FakeBalatroAdapter.new({ states = { blind_selection_observation() } }),
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        server_info = { name = "test", version = "0.1.0" },
        log = function(level, message)
            logs[#logs + 1] = level .. " " .. message
        end,
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local _, _, payload = call_tool(server, server:get_status().port, 401, "get_game_state")
    server:stop()
    luaunit.assertFalse(payload.result.isError)
    luaunit.assertEquals(#logs, 3)
    luaunit.assertStrContains(logs[1], "debug request.begin")
    luaunit.assertStrContains(logs[1], "rpc_id=401")
    luaunit.assertStrContains(logs[1], "tool=get_game_state")
    luaunit.assertStrContains(logs[1], "trace=1")
    luaunit.assertStrContains(logs[2], "info run.resume")
    luaunit.assertStrContains(logs[2], "run_id=run-alpha")
    luaunit.assertStrContains(logs[3], "info request.end")
    luaunit.assertStrContains(logs[3], "code=ok")
    luaunit.assertStrContains(logs[3], "phase=blind_selection")
    luaunit.assertStrContains(logs[3], "trace=1")
end

function TestDiscovery:test_info_logging_skips_debug_trace_construction()
    local logs = {}
    local adapter = FakeBalatroAdapter.new({
        states = { blind_selection_observation(), hand_observation() },
        transitions = {
            [1] = {
                select_blind = {
                    next_state = 2,
                    target = { argument = "blind_id", reference = "small-blind" },
                },
            },
        },
    })
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        server_info = { name = "test", version = "0.1.0" },
        log_enabled = function(level)
            return level ~= "debug"
        end,
        log = function(level, message)
            logs[#logs + 1] = level .. " " .. message
        end,
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local _, _, payload = call_tool(server, server:get_status().port, 403, "get_game_state")
    local state = payload.result.structuredContent.state
    local _, _, action_payload = call_tool(server, server:get_status().port, 404, "select_blind", {
        state_hash = state.state_hash,
        blind_id = state.blinds[1].id,
    })
    server:stop()

    luaunit.assertFalse(payload.result.isError)
    luaunit.assertFalse(action_payload.result.isError)
    luaunit.assertEquals(#logs, 3)
    luaunit.assertStrContains(logs[1], "info run.resume")
    luaunit.assertStrContains(logs[2], "info request.end")
    luaunit.assertStrContains(logs[3], "info request.end")
    for _, line in ipairs(logs) do
        luaunit.assertNotStrContains(line, "action.accepted")
        luaunit.assertNotStrContains(line, "action.dispatched")
    end
end

function TestDiscovery:test_encyclopedia_timeout_and_blocked_match_game_state()
    local adapter = FakeBalatroAdapter.new({ states = { blind_selection_observation() } })
    adapter.pending = { observations = 100000, next_state = 1 }
    local server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    local port = server:get_status().port
    local _, _, timeout_payload = call_tool(server, port, 330, "get_effect_encyclopedia")
    server:stop()

    luaunit.assertTrue(timeout_payload.result.isError)
    luaunit.assertEquals(timeout_payload.result.structuredContent.code, "DECISION_TIMEOUT")
    luaunit.assertNil(timeout_payload.result.structuredContent.state)
    luaunit.assertNil(timeout_payload.result.structuredContent.effect_encyclopedia)

    adapter = FakeBalatroAdapter.new({ states = { blind_selection_observation() } })
    adapter.pending = { observations = 100000, next_state = 1, code = "GAME_BLOCKED" }
    server = GameMcpServer.new({
        adapter = adapter,
        tool_catalog = ToolCatalog,
        json = JSON,
        port = 0,
        worker_source = read_file("src/http_worker.lua"),
        request_timeout_ms = 20,
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(server:start())
    wait_until(server, function()
        return server:get_status().state == "listening"
    end, 2)
    port = server:get_status().port
    local _, _, blocked_payload = call_tool(server, port, 331, "get_effect_encyclopedia")
    server:stop()

    luaunit.assertTrue(blocked_payload.result.isError)
    luaunit.assertEquals(blocked_payload.result.structuredContent.code, "GAME_BLOCKED")
    luaunit.assertNil(blocked_payload.result.structuredContent.state)
    luaunit.assertNil(blocked_payload.result.structuredContent.effect_encyclopedia)
end

function TestDiscovery:test_encyclopedia_waits_for_a_stable_decision()
    self.adapter.pending = { observations = 2, next_state = 1 }
    local _, _, payload = call_tool(self.server, self.port, 332, "get_effect_encyclopedia")

    luaunit.assertFalse(payload.result.isError)
    luaunit.assertEquals(payload.result.structuredContent.effect_encyclopedia.visibility, "fair")
    luaunit.assertEquals(
        payload.result.structuredContent.effect_encyclopedia.entries[1].key,
        "j_joker"
    )
end

TestProductionAdapter = {}

local vanilla_consumable_coverage = {
    c_fool = { category = "content_effect", mutation = "create" },
    c_magician = { category = "content_effect", mutation = "set_card_state" },
    c_high_priestess = { category = "content_effect", mutation = "create" },
    c_empress = { category = "content_effect", mutation = "set_card_state" },
    c_emperor = { category = "content_effect", mutation = "create" },
    c_heirophant = { category = "content_effect", mutation = "set_card_state" },
    c_lovers = { category = "content_effect", mutation = "set_card_state" },
    c_chariot = { category = "content_effect", mutation = "set_card_state" },
    c_justice = { category = "content_effect", mutation = "set_card_state" },
    c_hermit = { category = "content_effect", mutation = "dollars" },
    c_wheel_of_fortune = { category = "content_effect", mutation = "set_card_state_or_noop" },
    c_strength = { category = "content_effect", mutation = "set_card_state" },
    c_hanged_man = { category = "content_effect", mutation = "destroy" },
    c_death = { category = "content_effect", mutation = "copy_overwrite" },
    c_temperance = { category = "content_effect", mutation = "dollars" },
    c_devil = { category = "content_effect", mutation = "set_card_state" },
    c_tower = { category = "content_effect", mutation = "set_card_state" },
    c_star = { category = "content_effect", mutation = "set_card_state" },
    c_moon = { category = "content_effect", mutation = "set_card_state" },
    c_sun = { category = "content_effect", mutation = "set_card_state" },
    c_judgement = { category = "content_effect", mutation = "create" },
    c_world = { category = "content_effect", mutation = "set_card_state" },
    c_mercury = { category = "content_effect", mutation = "poker_hand_level" },
    c_venus = { category = "content_effect", mutation = "poker_hand_level" },
    c_earth = { category = "content_effect", mutation = "poker_hand_level" },
    c_mars = { category = "content_effect", mutation = "poker_hand_level" },
    c_jupiter = { category = "content_effect", mutation = "poker_hand_level" },
    c_saturn = { category = "content_effect", mutation = "poker_hand_level" },
    c_uranus = { category = "content_effect", mutation = "poker_hand_level" },
    c_neptune = { category = "content_effect", mutation = "poker_hand_level" },
    c_pluto = { category = "content_effect", mutation = "poker_hand_level" },
    c_planet_x = { category = "content_effect", mutation = "poker_hand_level" },
    c_ceres = { category = "content_effect", mutation = "poker_hand_level" },
    c_eris = { category = "content_effect", mutation = "poker_hand_level" },
    c_familiar = { category = "content_effect", mutation = "destroy_create" },
    c_grim = { category = "content_effect", mutation = "destroy_create" },
    c_incantation = { category = "content_effect", mutation = "destroy_create" },
    c_talisman = { category = "content_effect", mutation = "set_card_state" },
    c_aura = { category = "content_effect", mutation = "set_card_state" },
    c_wraith = { category = "content_effect", mutation = "create_dollars" },
    c_sigil = { category = "content_effect", mutation = "set_card_state" },
    c_ouija = { category = "content_effect", mutation = "set_card_state_capacity" },
    c_ectoplasm = { category = "content_effect", mutation = "set_card_state_capacity" },
    c_immolate = { category = "content_effect", mutation = "destroy_dollars" },
    c_ankh = { category = "content_effect", mutation = "destroy_copy_create" },
    c_deja_vu = { category = "content_effect", mutation = "set_card_state" },
    c_hex = { category = "content_effect", mutation = "set_card_state_destroy" },
    c_trance = { category = "content_effect", mutation = "set_card_state" },
    c_medium = { category = "content_effect", mutation = "set_card_state" },
    c_cryptid = { category = "content_effect", mutation = "copy_create" },
    c_soul = { category = "content_effect", mutation = "create" },
    c_black_hole = { category = "content_effect", mutation = "poker_hand_level" },
}

local vanilla_voucher_coverage = {
    v_overstock_norm = { category = "content_effect", mutation = "capacity" },
    v_overstock_plus = { category = "content_effect", mutation = "capacity" },
    v_clearance_sale = { category = "content_effect", mutation = "run_rule" },
    v_liquidation = { category = "content_effect", mutation = "run_rule" },
    v_hone = { category = "content_effect", mutation = "run_rule" },
    v_glow_up = { category = "content_effect", mutation = "run_rule" },
    v_reroll_surplus = { category = "content_effect", mutation = "run_rule" },
    v_reroll_glut = { category = "content_effect", mutation = "run_rule" },
    v_crystal_ball = { category = "content_effect", mutation = "capacity" },
    v_omen_globe = { category = "content_effect", mutation = "run_rule" },
    v_telescope = { category = "content_effect", mutation = "run_rule" },
    v_observatory = { category = "content_effect", mutation = "run_rule" },
    v_grabber = { category = "content_effect", mutation = "round_allowance" },
    v_nacho_tong = { category = "content_effect", mutation = "round_allowance" },
    v_wasteful = { category = "content_effect", mutation = "round_allowance" },
    v_recyclomancy = { category = "content_effect", mutation = "round_allowance" },
    v_tarot_merchant = { category = "content_effect", mutation = "run_rule" },
    v_tarot_tycoon = { category = "content_effect", mutation = "run_rule" },
    v_planet_merchant = { category = "content_effect", mutation = "run_rule" },
    v_planet_tycoon = { category = "content_effect", mutation = "run_rule" },
    v_seed_money = { category = "content_effect", mutation = "run_rule" },
    v_money_tree = { category = "content_effect", mutation = "run_rule" },
    v_blank = { category = "noop", mutation = "noop" },
    v_antimatter = { category = "content_effect", mutation = "capacity" },
    v_magic_trick = { category = "content_effect", mutation = "run_rule" },
    v_illusion = { category = "content_effect", mutation = "run_rule" },
    v_hieroglyph = { category = "content_effect", mutation = "ante_change_round_allowance" },
    v_petroglyph = { category = "content_effect", mutation = "ante_change_round_allowance" },
    v_directors_cut = { category = "content_effect", mutation = "run_rule" },
    v_retcon = { category = "content_effect", mutation = "run_rule" },
    v_paint_brush = { category = "content_effect", mutation = "capacity" },
    v_palette = { category = "content_effect", mutation = "capacity" },
}

local vanilla_back_coverage = {
    b_red = { category = "content_effect", mutation = "round_allowance" },
    b_blue = { category = "content_effect", mutation = "round_allowance" },
    b_yellow = { category = "content_effect", mutation = "dollars" },
    b_green = { category = "content_effect", mutation = "run_rule" },
    b_black = { category = "content_effect", mutation = "capacity_round_allowance" },
    b_magic = { category = "content_effect", mutation = "nested_apply_create" },
    b_nebula = { category = "content_effect", mutation = "nested_apply_capacity" },
    b_ghost = { category = "content_effect", mutation = "run_rule_create" },
    b_abandoned = { category = "content_effect", mutation = "run_rule" },
    b_checkered = { category = "content_effect", mutation = "set_card_state" },
    b_zodiac = { category = "content_effect", mutation = "nested_apply" },
    b_painted = { category = "content_effect", mutation = "capacity" },
    b_anaglyph = { category = "content_effect", mutation = "run_rule" },
    b_plasma = { category = "content_effect", mutation = "run_rule" },
    b_erratic = { category = "content_effect", mutation = "run_rule" },
}

local vanilla_lifecycle_joker_coverage = {
    j_blueprint = { category = "content_effect", mutation = "copies_lifecycle" },
    j_brainstorm = { category = "content_effect", mutation = "copies_lifecycle" },
    j_hallucination = { category = "content_effect", mutation = "create_consumable" },
    j_luchador = { category = "content_effect", mutation = "blind_change" },
    j_diet_cola = { category = "content_effect", mutation = "tag_change" },
    j_invisible = { category = "content_effect", mutation = "copy_create" },
    j_campfire = { category = "content_effect", mutation = "card_progress" },
    j_flash = { category = "content_effect", mutation = "card_progress" },
    j_perkeo = { category = "content_effect", mutation = "copy_create_edition" },
    j_throwback = { category = "content_effect", mutation = "card_progress" },
    j_red_card = { category = "content_effect", mutation = "card_progress" },
    j_hologram = { category = "content_effect", mutation = "card_progress" },
    j_certificate = { category = "content_effect", mutation = "create_playing_card" },
    j_dna = { category = "animation", mutation = "readiness_only" },
    j_trading = { category = "animation", mutation = "readiness_only" },
    j_chicot = { category = "content_effect", mutation = "blind_change" },
    j_madness = { category = "content_effect", mutation = "card_progress_destroy" },
    j_burglar = { category = "content_effect", mutation = "round_allowance" },
    j_riff_raff = { category = "content_effect", mutation = "create_joker" },
    j_cartomancer = { category = "content_effect", mutation = "create_consumable" },
    j_ceremonial = { category = "content_effect", mutation = "card_progress_destroy" },
    j_marble = { category = "content_effect", mutation = "create_playing_card" },
}

local vanilla_blind_coverage = {
    bl_small = { category = "action_mechanics", mutation = "action_mechanics" },
    bl_big = { category = "action_mechanics", mutation = "action_mechanics" },
    bl_ox = { category = "content_effect", mutation = "dollars" },
    bl_hook = { category = "content_effect", mutation = "move_card" },
    bl_mouth = { category = "content_effect", mutation = "hand_restriction" },
    bl_fish = { category = "content_effect", mutation = "set_card_state" },
    bl_club = { category = "content_effect", mutation = "set_card_state" },
    bl_manacle = { category = "content_effect", mutation = "capacity" },
    bl_tooth = { category = "content_effect", mutation = "dollars" },
    bl_wall = { category = "content_effect", mutation = "requirement" },
    bl_house = { category = "content_effect", mutation = "set_card_state" },
    bl_mark = { category = "content_effect", mutation = "set_card_state" },
    bl_final_bell = { category = "content_effect", mutation = "set_card_state" },
    bl_wheel = { category = "content_effect", mutation = "set_card_state" },
    bl_arm = { category = "content_effect", mutation = "poker_hand_level" },
    bl_psychic = { category = "content_effect", mutation = "hand_restriction" },
    bl_goad = { category = "content_effect", mutation = "set_card_state" },
    bl_water = { category = "content_effect", mutation = "round_allowance" },
    bl_eye = { category = "content_effect", mutation = "hand_restriction" },
    bl_plant = { category = "content_effect", mutation = "set_card_state" },
    bl_needle = { category = "content_effect", mutation = "round_allowance" },
    bl_head = { category = "content_effect", mutation = "set_card_state" },
    bl_final_leaf = { category = "content_effect", mutation = "set_card_state_disable" },
    bl_final_vessel = { category = "content_effect", mutation = "requirement" },
    bl_window = { category = "content_effect", mutation = "set_card_state" },
    bl_serpent = { category = "content_effect", mutation = "draw_rule" },
    bl_pillar = { category = "content_effect", mutation = "set_card_state" },
    bl_flint = { category = "content_effect", mutation = "scoring" },
    bl_final_acorn = { category = "content_effect", mutation = "set_card_state_reorder" },
    bl_final_heart = { category = "content_effect", mutation = "set_card_state" },
}

local vanilla_tag_coverage = {
    tag_uncommon = { category = "content_effect", mutation = "create_shop_offer" },
    tag_rare = { category = "content_effect", mutation = "create_shop_offer_or_consume" },
    tag_negative = { category = "content_effect", mutation = "create_edition_shop_offer" },
    tag_foil = { category = "content_effect", mutation = "create_edition_shop_offer" },
    tag_holo = { category = "content_effect", mutation = "create_edition_shop_offer" },
    tag_polychrome = { category = "content_effect", mutation = "create_edition_shop_offer" },
    tag_investment = { category = "content_effect", mutation = "dollars" },
    tag_voucher = { category = "content_effect", mutation = "create_shop_offer" },
    tag_boss = { category = "content_effect", mutation = "blind_change" },
    tag_standard = { category = "content_effect", mutation = "open_booster" },
    tag_charm = { category = "content_effect", mutation = "open_booster" },
    tag_meteor = { category = "content_effect", mutation = "open_booster" },
    tag_buffoon = { category = "content_effect", mutation = "open_booster" },
    tag_handy = { category = "content_effect", mutation = "dollars" },
    tag_garbage = { category = "content_effect", mutation = "dollars" },
    tag_ethereal = { category = "content_effect", mutation = "open_booster" },
    tag_coupon = { category = "content_effect", mutation = "run_rule" },
    tag_double = { category = "content_effect", mutation = "tag_change" },
    tag_juggle = { category = "content_effect", mutation = "capacity" },
    tag_d_six = { category = "content_effect", mutation = "run_rule" },
    tag_top_up = { category = "content_effect", mutation = "create_owned" },
    tag_skip = { category = "content_effect", mutation = "dollars" },
    tag_orbital = { category = "content_effect", mutation = "poker_hand_level" },
    tag_economy = { category = "content_effect", mutation = "dollars" },
}

local coverage_categories = {
    content_effect = true,
    action_mechanics = true,
    animation = true,
    noop = true,
}

local mutation_branch_tests = {
    action_mechanics = "test_normal_play_draw_and_discard_remain_action_mechanics",
    ante_change_round_allowance = "test_voucher_application_records_run_upgrades_only",
    blind_change = "test_boss_tag_records_automatic_replacement_and_consumption",
    capacity = "test_voucher_application_records_run_upgrades_only",
    capacity_round_allowance = "test_back_application_separates_run_setup_and_keeps_nested_order",
    card_progress = "test_lifecycle_shop_and_booster_contexts_record_content_only",
    card_progress_destroy = "test_setting_blind_jokers_keep_source_parent_and_effect_order",
    copies_lifecycle = "test_setting_blind_jokers_keep_source_parent_and_effect_order",
    copy_create = "test_consumable_mutation_seams_preserve_effect_order",
    copy_create_edition = "test_lifecycle_shop_and_booster_contexts_record_content_only",
    copy_overwrite = "test_death_overwrites_an_input_card_without_create",
    create = "test_consumable_mutation_seams_preserve_effect_order",
    create_consumable = "test_lifecycle_shop_and_booster_contexts_record_content_only",
    create_dollars = "test_wraith_records_created_joker_before_money_reset",
    create_edition_shop_offer = "test_shop_offer_tags_record_owned_offer_and_edition_creation",
    create_joker = "test_setting_blind_jokers_keep_source_parent_and_effect_order",
    create_owned = "test_shop_offer_tags_record_owned_offer_and_edition_creation",
    create_playing_card = "test_first_hand_created_card_carries_seal_and_child_hologram_source",
    create_shop_offer = "test_shop_offer_tags_record_owned_offer_and_edition_creation",
    create_shop_offer_or_consume = "test_shop_offer_tags_record_owned_offer_and_edition_creation",
    destroy = "test_consumable_mutation_seams_preserve_effect_order",
    destroy_copy_create = "test_ankh_destroys_inputs_and_creates_one_unidentified_copy",
    destroy_create = "test_familiar_records_destroy_and_public_playing_card_features",
    destroy_dollars = "test_consumable_mutation_seams_preserve_effect_order",
    dollars = "test_consumable_mutation_seams_preserve_effect_order",
    draw_rule = "test_psychic_and_serpent_record_rules_without_illegal_actions",
    hand_restriction = "test_eye_and_mouth_record_dynamic_hand_restrictions",
    move_card = "test_hook_records_forced_discards_as_moves_only",
    nested_apply = "test_back_application_separates_run_setup_and_keeps_nested_order",
    nested_apply_capacity = "test_back_application_separates_run_setup_and_keeps_nested_order",
    nested_apply_create = "test_back_application_separates_run_setup_and_keeps_nested_order",
    noop = "test_voucher_application_records_run_upgrades_only",
    open_booster = "test_automatic_booster_tags_record_pack_shape_without_candidates",
    poker_hand_level = "test_black_hole_records_every_upgraded_hand",
    readiness_only = "test_first_hand_created_card_carries_seal_and_child_hologram_source",
    requirement = "test_requirement_capacity_allowance_and_hand_level_blind_effects",
    round_allowance = "test_voucher_application_records_run_upgrades_only",
    run_rule = "test_voucher_application_records_run_upgrades_only",
    run_rule_create = "test_back_application_separates_run_setup_and_keeps_nested_order",
    scoring = "test_flint_ox_and_tooth_record_scoring_and_money_effects",
    set_card_state = "test_consumable_mutation_seams_preserve_effect_order",
    set_card_state_capacity = "test_consumable_mutation_seams_preserve_effect_order",
    set_card_state_destroy = "test_consumable_mutation_seams_preserve_effect_order",
    set_card_state_disable = "test_verdant_leaf_async_disable_opens_blind_application",
    set_card_state_or_noop = "test_consumable_mutation_seams_preserve_effect_order",
    set_card_state_reorder = "test_amber_acorn_records_hidden_jokers_and_anonymous_shuffle",
    tag_change = "test_double_tag_records_copy_and_consumption_without_target_ids",
}

local compound_path_tests = {
    {
        test = "test_death_overwrites_an_input_card_without_create",
        keys = { "c_death" },
    },
    {
        test = "test_ankh_destroys_inputs_and_creates_one_unidentified_copy",
        keys = { "c_ankh" },
    },
    {
        test = "test_consumable_mutation_seams_preserve_effect_order",
        keys = {
            "c_cryptid",
            "c_judgement",
            "c_hermit",
            "c_wheel_of_fortune",
            "c_ouija",
            "c_ectoplasm",
            "c_hex",
        },
    },
    {
        test = "test_wraith_records_created_joker_before_money_reset",
        keys = { "c_wraith" },
    },
    {
        test = "test_black_hole_records_every_upgraded_hand",
        keys = { "c_black_hole" },
    },
    {
        test = "test_amber_acorn_records_hidden_jokers_and_anonymous_shuffle",
        keys = { "bl_final_acorn" },
    },
    {
        test = "test_debuffs_and_cerulean_forced_selection_use_card_state_effects",
        keys = { "bl_final_bell" },
    },
    {
        test = "test_hook_records_forced_discards_as_moves_only",
        keys = { "bl_hook" },
    },
    {
        test = "test_boss_tag_records_automatic_replacement_and_consumption",
        keys = { "tag_boss" },
    },
    {
        test = "test_automatic_booster_tags_record_pack_shape_without_candidates",
        keys = { "tag_charm", "tag_meteor", "tag_ethereal", "tag_standard", "tag_buffoon" },
    },
}

local function classified_keys(coverage, set_filter)
    local keys = {}
    for key, entry in pairs(coverage) do
        if not set_filter or set_filter[key] then
            luaunit.assertEquals(type(entry), "table", key)
            luaunit.assertTrue(coverage_categories[entry.category] == true, key)
            luaunit.assertNotNil(entry.mutation, key)
            luaunit.assertNotEquals(entry.mutation, "", key)
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    return keys
end

local function sorted_prototype_keys(list)
    local keys = {}
    if type(list[1]) == "string" then
        for _, key in ipairs(list) do
            keys[#keys + 1] = key
        end
    else
        for _, items in pairs(list) do
            for _, key in ipairs(items) do
                keys[#keys + 1] = key
            end
        end
    end
    table.sort(keys)
    return keys
end

local function vanilla_keys_from_game_source()
    local source = assert(
        os.getenv("BALATRO_SOURCE"),
        "BALATRO_SOURCE must point to the Balatro source checkout"
    )
    local content = read_file(source .. "/game.lua")
    local by_set = {
        Tarot = {},
        Planet = {},
        Spectral = {},
        Voucher = {},
        Back = {},
        Tag = {},
        Blind = {},
        Joker = {},
    }
    local skip = {
        c_base = true,
        c_locked = true,
        t_undiscovered = true,
        p_undiscovered = true,
        s_undiscovered = true,
        v_locked = true,
        v_undiscovered = true,
    }
    for line in content:gmatch("[^\n]+") do
        local key, set = line:match("^%s*([%w_]+)%s*=%s*{.*set%s*=%s*['\"]([%w]+)['\"]")
        if
            key
            and by_set[set]
            and not skip[key]
            and not line:find("omit%s*=%s*true")
            and not key:find("undiscovered")
            and not key:find("_locked$")
        then
            by_set[set][#by_set[set] + 1] = key
        end
    end
    local blinds_block = content:match("self%.P_BLINDS%s*=%s*%b{}")
    luaunit.assertNotNil(blinds_block)
    for key in blinds_block:gmatch("(bl_[%w_]+)%s*=") do
        by_set.Blind[#by_set.Blind + 1] = key
    end
    for _, keys in pairs(by_set) do
        table.sort(keys)
    end
    return by_set
end

local function encyclopedia_keys(set)
    local encyclopedia = assert(ProductionBalatroAdapter.new():encyclopedia("omniscient"))
    local keys = {}
    for _, entry in ipairs(encyclopedia.entries) do
        if entry.set == set then
            keys[#keys + 1] = entry.key
        end
    end
    table.sort(keys)
    return keys
end

local function key_filter(items)
    local filter = {}
    for _, key in ipairs(items) do
        filter[key] = true
    end
    return filter
end

function TestProductionAdapter:test_vanilla_runtime_coverage_matches_encyclopedia()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local ok, test_error = xpcall(function()
        local vanilla = vanilla_keys_from_game_source()
        luaunit.assertEquals(
            vanilla.Tarot,
            classified_keys(vanilla_consumable_coverage, key_filter(vanilla.Tarot))
        )
        luaunit.assertEquals(
            vanilla.Planet,
            classified_keys(vanilla_consumable_coverage, key_filter(vanilla.Planet))
        )
        luaunit.assertEquals(
            vanilla.Spectral,
            classified_keys(vanilla_consumable_coverage, key_filter(vanilla.Spectral))
        )
        luaunit.assertEquals(vanilla.Voucher, classified_keys(vanilla_voucher_coverage))
        luaunit.assertEquals(vanilla.Back, classified_keys(vanilla_back_coverage))
        luaunit.assertEquals(vanilla.Blind, classified_keys(vanilla_blind_coverage))
        luaunit.assertEquals(vanilla.Tag, classified_keys(vanilla_tag_coverage))
        local consumable_vanilla = {}
        for _, set in ipairs({ "Tarot", "Planet", "Spectral" }) do
            for _, key in ipairs(vanilla[set]) do
                consumable_vanilla[#consumable_vanilla + 1] = key
            end
        end
        table.sort(consumable_vanilla)
        luaunit.assertEquals(consumable_vanilla, classified_keys(vanilla_consumable_coverage))
        local lifecycle = classified_keys(vanilla_lifecycle_joker_coverage)
        local joker_set = key_filter(vanilla.Joker)
        for _, key in ipairs(lifecycle) do
            luaunit.assertTrue(joker_set[key] == true, key)
        end
        luaunit.assertEquals(
            sorted_prototype_keys(VanillaConsumablePrototypes),
            classified_keys(vanilla_consumable_coverage)
        )
        luaunit.assertEquals(
            sorted_prototype_keys(VanillaVoucherBackPrototypes.Voucher),
            classified_keys(vanilla_voucher_coverage)
        )
        luaunit.assertEquals(
            sorted_prototype_keys(VanillaVoucherBackPrototypes.Back),
            classified_keys(vanilla_back_coverage)
        )
        luaunit.assertEquals(
            sorted_prototype_keys(VanillaLifecycleJokerPrototypes),
            classified_keys(vanilla_lifecycle_joker_coverage)
        )
        luaunit.assertEquals(
            sorted_prototype_keys(VanillaBlindPrototypes),
            classified_keys(vanilla_blind_coverage)
        )
        luaunit.assertEquals(
            sorted_prototype_keys(VanillaTagPrototypes),
            classified_keys(vanilla_tag_coverage)
        )

        local pools = {
            Tarot = {},
            Planet = {},
            Spectral = {},
            Voucher = {},
            Back = {},
            Joker = {},
            Tag = {},
        }
        for set, keys in pairs(VanillaConsumablePrototypes) do
            for _, key in ipairs(keys) do
                pools[set][#pools[set] + 1] = {
                    key = key,
                    set = set,
                    name = key,
                    config = {},
                }
            end
        end
        for _, key in ipairs(VanillaVoucherBackPrototypes.Voucher) do
            pools.Voucher[#pools.Voucher + 1] = {
                key = key,
                set = "Voucher",
                name = key,
                config = {},
            }
        end
        for _, key in ipairs(VanillaVoucherBackPrototypes.Back) do
            pools.Back[#pools.Back + 1] = {
                key = key,
                set = "Back",
                name = key,
                config = {},
            }
        end
        for _, key in ipairs(VanillaLifecycleJokerPrototypes) do
            pools.Joker[#pools.Joker + 1] = {
                key = key,
                set = "Joker",
                name = key,
                config = {},
            }
        end
        for _, key in ipairs(VanillaTagPrototypes) do
            pools.Tag[#pools.Tag + 1] = {
                key = key,
                set = "Tag",
                name = key,
                config = {},
            }
        end
        local blinds = {}
        for _, key in ipairs(VanillaBlindPrototypes) do
            blinds[key] = {
                key = key,
                set = "Blind",
                name = key,
                dollars = 5,
                mult = 2,
                debuff = {},
            }
        end
        _G.G = { P_CENTER_POOLS = pools, P_BLINDS = blinds }
        _G.SMODS = {}

        for set, keys in pairs(VanillaConsumablePrototypes) do
            luaunit.assertEquals(
                encyclopedia_keys(set),
                classified_keys(vanilla_consumable_coverage, key_filter(keys))
            )
        end
        luaunit.assertEquals(
            encyclopedia_keys("Voucher"),
            classified_keys(vanilla_voucher_coverage)
        )
        luaunit.assertEquals(encyclopedia_keys("Back"), classified_keys(vanilla_back_coverage))
        luaunit.assertEquals(
            encyclopedia_keys("Joker"),
            classified_keys(vanilla_lifecycle_joker_coverage)
        )
        luaunit.assertEquals(encyclopedia_keys("Blind"), classified_keys(vanilla_blind_coverage))
        luaunit.assertEquals(encyclopedia_keys("Tag"), classified_keys(vanilla_tag_coverage))
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_vanilla_runtime_coverage_is_test_only()
    for _, file_path in ipairs({
        "src/balatro_adapter.lua",
        "src/game_mcp_server.lua",
        "src/tool_catalog.lua",
        "src/http_worker.lua",
        "main.lua",
        "config.lua",
    }) do
        local content = read_file(file_path)
        for _, marker in ipairs({
            "vanilla_consumable_coverage",
            "vanilla_voucher_coverage",
            "vanilla_back_coverage",
            "vanilla_lifecycle_joker_coverage",
            "vanilla_blind_coverage",
            "vanilla_tag_coverage",
            "vanilla_consumable_prototypes",
            "vanilla_voucher_back_prototypes",
            "vanilla_lifecycle_joker_prototypes",
            "vanilla_blind_prototypes",
            "vanilla_tag_prototypes",
            "mutation_branch_tests",
        }) do
            luaunit.assertNotStrContains(content, marker)
        end
    end
end

local function production_test_body(name)
    local source = read_file("tests/game_mcp_server_test.lua")
    local header = "function TestProductionAdapter:" .. name .. "()"
    local start_at = source:find(header, 1, true)
    luaunit.assertNotNil(start_at, name)
    local next_at = source:find("\nfunction TestProductionAdapter:", start_at + 1, true)
    return source:sub(start_at, (next_at or #source) - 1)
end

function TestProductionAdapter:test_vanilla_mutation_branches_have_top_level_behavior_tests()
    local seen = {}
    for _, coverage in ipairs({
        vanilla_consumable_coverage,
        vanilla_voucher_coverage,
        vanilla_back_coverage,
        vanilla_lifecycle_joker_coverage,
        vanilla_blind_coverage,
        vanilla_tag_coverage,
    }) do
        for key, entry in pairs(coverage) do
            local mutation = entry.mutation
            luaunit.assertNotNil(mutation_branch_tests[mutation], key .. " " .. tostring(mutation))
            seen[mutation] = true
        end
    end
    for mutation, test_name in pairs(mutation_branch_tests) do
        luaunit.assertTrue(seen[mutation], mutation)
        luaunit.assertEquals(type(TestProductionAdapter[test_name]), "function", mutation)
        luaunit.assertNotNil(production_test_body(test_name):find(test_name, 1, true), mutation)
    end
    for _, path in ipairs(compound_path_tests) do
        luaunit.assertEquals(type(TestProductionAdapter[path.test]), "function", path.test)
        local body = production_test_body(path.test)
        for _, key in ipairs(path.keys) do
            luaunit.assertNotNil(body:find(key, 1, true), path.test .. " " .. key)
        end
    end
end

local edition_localization = {
    e_foil = { name = "Foil", text = { "+#1# chips" } },
    e_holo = { name = "Holographic", text = { "+#1# Mult" } },
    e_negative = { name = "Negative", text = { "+#1# Joker slot" } },
    e_negative_consumable = { name = "Negative", text = { "+#1# consumable slot" } },
}

function TestProductionAdapter:test_start_run_preserves_normal_new_run_bookkeeping()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local save_count = 0
    local started_with
    local red_deck = {
        key = "b_red",
        name = "Red Deck",
        set = "Back",
        config = { discards = 1 },
        unlocked = true,
        discovered = true,
    }
    local white_stake = {
        key = "stake_white",
        name = "White Stake",
        set = "Stake",
        order = 1,
    }

    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            stake_from_index = function(_index)
                return "stake_white"
            end,
            stake_is_unlocked = function(_stake_key, _deck_key)
                return true
            end,
        }
        _G.G = {
            VERSION = "1.0.1o-FULL",
            STAGES = { MAIN_MENU = 1, RUN = 2 },
            STATES = { MENU = 11 },
            STAGE = 1,
            STATE = 11,
            CONTROLLER = { locks = {}, lock_input = false },
            SETTINGS = { current_setup = "New Run", profile = 1 },
            MAIN_MENU_UI = {},
            GAME = {},
            SAVED_GAME = { GAME = { won = false } },
            PROFILES = {
                [1] = {
                    high_scores = { current_streak = { amt = 7 } },
                    all_unlocked = true,
                    deck_usage = {},
                },
            },
            P_CENTER_POOLS = { Back = { red_deck }, Stake = { white_stake } },
            P_CENTERS = { b_red = red_deck },
            P_STAKES = { stake_white = white_stake },
            FUNCS = {
                start_run = function(_, arguments)
                    started_with = arguments
                end,
            },
            save_settings = function()
                save_count = save_count + 1
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "start_run",
            expected_state_hash = "sha256:test",
            arguments = { deck_key = "b_red", stake = 1 },
            targets = {},
        })

        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        luaunit.assertTrue(result.pending)
        luaunit.assertEquals(G.PROFILES[1].high_scores.current_streak.amt, 0)
        luaunit.assertEquals(save_count, 1)
        luaunit.assertEquals(started_with.deck_choice.name, "Red Deck")
        luaunit.assertEquals(started_with.stake_choice, 1)
        luaunit.assertNil(started_with.seed)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_hand_observation_includes_cards_deck_and_hand_levels()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local ace = {
        sort_id = 1,
        config = { card_key = "S_A", center = { key = "c_base", set = "Default" } },
        base = { suit = "Spades", value = "Ace", nominal = 11 },
        ability = { effect = "Base", set = "Default" },
        debuff = false,
        get_chip_bonus = function()
            return 11
        end,
    }
    local remaining = {
        sort_id = 2,
        config = { card_key = "C_2", center = { key = "c_base", set = "Default" } },
        base = { suit = "Clubs", value = "2", nominal = 2 },
        ability = { effect = "Base", set = "Default" },
        debuff = false,
        get_chip_bonus = function()
            return 2
        end,
    }
    local red_deck = {
        key = "b_red",
        name = "Red Deck",
        set = "Back",
        config = { discards = 1 },
    }
    local white_stake = { key = "stake_white", name = "White Stake", order = 1 }
    local small_blind = { key = "bl_small", name = "Small Blind", dollars = 3, mult = 1 }

    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            stake_from_index = function()
                return "stake_white"
            end,
        }
        _G.G = {
            VERSION = "1.0.1o-FULL",
            STAGES = { MAIN_MENU = 1, RUN = 2 },
            STATES = { SELECTING_HAND = 1, SHOP = 5 },
            STAGE = 2,
            STATE = 1,
            STATE_COMPLETE = true,
            CONTROLLER = { locks = {}, lock_input = false },
            SETTINGS = { paused = false },
            P_CARDS = {
                S_A = { name = "Ace of Spades", suit = "Spades", value = "Ace" },
                C_2 = { name = "2 of Clubs", suit = "Clubs", value = "2" },
            },
            P_BLINDS = { bl_small = small_blind },
            P_STAKES = { stake_white = white_stake },
            P_CENTERS = {},
            P_TAGS = {},
            hand = { cards = { ace } },
            deck = { cards = { remaining } },
            GAME = {
                selected_back = { effect = { center = red_deck } },
                stake = 1,
                dollars = 4,
                chips = 0,
                skips = 0,
                seeded = true,
                tags = {},
                used_vouchers = {},
                modifiers = {},
                starting_params = { ante_scaling = 1 },
                current_round = { hands_left = 4, discards_left = 3 },
                blind = { config = { blind = small_blind } },
                blind_on_deck = "Small",
                hands = {
                    ["High Card"] = {
                        visible = true,
                        level = 1,
                        chips = 5,
                        mult = 1,
                        played = 0,
                    },
                    Pair = {
                        visible = true,
                        level = 1,
                        chips = 10,
                        mult = 2,
                        played = 0,
                    },
                    ["Flush Five"] = {
                        visible = false,
                        level = 1,
                        chips = 160,
                        mult = 16,
                        played = 0,
                    },
                },
                round_resets = {
                    ante = 1,
                    blind_ante = 1,
                    blind_choices = { Small = "bl_small" },
                    blind_states = { Small = "Current" },
                    blind_tags = {},
                },
                pseudorandom = { seed = "MCPTEST" },
            },
        }

        local observation, observe_error = ProductionBalatroAdapter.new():observe("fair")
        luaunit.assertNil(observe_error)
        luaunit.assertNotNil(observation)
        ---@cast observation table
        luaunit.assertEquals(observation.phase, "hand_play")
        luaunit.assertEquals(observation.public_state.hand[1].key, "S_A")
        luaunit.assertEquals(observation.public_state.hand[1].suit, "Spades")
        luaunit.assertEquals(observation.public_state.hand[1].rank, "Ace")
        luaunit.assertEquals(observation.public_state.hand[1].chips, 11)
        luaunit.assertEquals(observation.public_state.remaining_deck[1].key, "C_2")
        luaunit.assertEquals(observation.public_state.poker_hands[1].key, "Pair")
        luaunit.assertEquals(observation.public_state.hands_left, 4)
        luaunit.assertEquals(observation.public_state.current_blind.key, "bl_small")
        luaunit.assertEquals(#observation.public_state.legal_actions, 2)

        local highlighted = {}
        G.hand.highlighted = highlighted
        G.hand.add_to_highlighted = function(_, card)
            highlighted[#highlighted + 1] = card
        end
        G.hand.unhighlight_all = function()
            for index = #highlighted, 1, -1 do
                highlighted[index] = nil
            end
        end
        G.FUNCS = {}

        local king = {
            sort_id = 3,
            T = { x = 9 },
            config = { card_key = "H_K", center = { key = "c_base", set = "Default" } },
            base = { suit = "Hearts", value = "King", nominal = 10 },
            ability = { effect = "Base", set = "Default" },
            debuff = false,
            get_chip_bonus = function()
                return 10
            end,
        }
        ace.T = { x = 1 }
        G.hand.cards = { ace, king }
        G.P_CARDS.H_K = { name = "King of Hearts", suit = "Hearts", value = "King" }
        local played
        local discarded
        G.FUNCS.get_poker_hand_info = function(cards)
            return #cards == 2 and "Pair" or "High Card",
                nil,
                {},
                cards,
                #cards == 2 and "Pair" or "High Card"
        end
        G.FUNCS.play_cards_from_highlighted = function()
            played = {}
            for _, card in ipairs(G.hand.highlighted) do
                played[#played + 1] = card.config.card_key
            end
        end
        G.FUNCS.discard_cards_from_highlighted = function()
            discarded = {}
            for _, card in ipairs(G.hand.highlighted) do
                discarded[#discarded + 1] = card.config.card_key
            end
        end
        local play_result, play_error = ProductionBalatroAdapter.new():execute({
            name = "play_hand",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { card_ids = { "card:3", "card:1" } },
        })
        luaunit.assertNil(play_error)
        luaunit.assertNotNil(play_result)
        ---@cast play_result table
        luaunit.assertTrue(play_result.pending)
        luaunit.assertEquals(played, { "H_K", "S_A" })
        luaunit.assertNil(play_result.events)

        local discard_result, discard_error = ProductionBalatroAdapter.new():execute({
            name = "discard_cards",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { card_ids = { "card:1" } },
        })
        luaunit.assertNil(discard_error)
        luaunit.assertNotNil(discard_result)
        ---@cast discard_result table
        luaunit.assertTrue(discard_result.pending)
        luaunit.assertEquals(discarded, { "S_A" })

        G.STATE = G.STATES.SHOP
        G.shop = {}
        local shop = ProductionBalatroAdapter.new():observe("fair")
        luaunit.assertNotNil(shop)
        ---@cast shop table
        luaunit.assertEquals(shop.phase, "shop")
        luaunit.assertEquals(shop.public_state.money, 4)

        G.STATE = 8
        G.STATES.ROUND_EVAL = 8
        G.round_eval = {}
        local cash_out_called = false
        G.FUNCS.cash_out = function()
            cash_out_called = true
        end
        local waiting = ProductionBalatroAdapter.new():observe("fair")
        luaunit.assertNil(waiting)
        luaunit.assertFalse(cash_out_called)

        G.GAME.current_round.dollars = 5
        G.round_eval = {
            get_UIE_by_ID = function(_, key)
                if key == "cash_out_button" then
                    return { config = { button = "cash_out" } }
                end
            end,
        }
        local cashier = ProductionBalatroAdapter.new()
        local pending, pending_error = cashier:observe("fair")
        luaunit.assertNil(pending)
        luaunit.assertNotNil(pending_error)
        ---@cast pending_error table
        luaunit.assertEquals(pending_error.code, "DECISION_PENDING")
        luaunit.assertTrue(cash_out_called)

        G.STATE = G.STATES.SHOP
        G.shop = {}
        G.GAME.dollars = 4
        local unpaid, unpaid_error = cashier:observe("fair")
        luaunit.assertNil(unpaid)
        luaunit.assertNotNil(unpaid_error)
        ---@cast unpaid_error table
        luaunit.assertEquals(unpaid_error.code, "DECISION_PENDING")

        G.GAME.dollars = 9
        local paid = cashier:observe("fair")
        luaunit.assertNotNil(paid)
        ---@cast paid table
        luaunit.assertEquals(paid.phase, "shop")
        luaunit.assertEquals(paid.public_state.money, 9)

        G.STATE = G.STATES.SELECTING_HAND
        G.round_eval = nil
        G.GAME.blind.block_play = true
        local blocked, blocked_error = ProductionBalatroAdapter.new():observe("fair")
        luaunit.assertNil(blocked)
        luaunit.assertNotNil(blocked_error)
        ---@cast blocked_error table
        luaunit.assertEquals(blocked_error.code, "DECISION_PENDING")
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_hand_projection_exposes_forced_cards_dynamic_blind_and_deck_state()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local ace = {
        sort_id = 1,
        config = { card_key = "S_A", center = { key = "c_base", set = "Default" } },
        base = { suit = "Spades", value = "Ace", nominal = 11 },
        ability = { effect = "Base", set = "Default", forced_selection = true },
        debuff = false,
        get_chip_bonus = function()
            return 11
        end,
    }
    local king = {
        sort_id = 2,
        config = { card_key = "H_K", center = { key = "c_base", set = "Default" } },
        base = { suit = "Hearts", value = "King", nominal = 10 },
        ability = { effect = "Base", set = "Default" },
        debuff = false,
        get_chip_bonus = function()
            return 10
        end,
    }
    local played = {
        sort_id = 3,
        config = { card_key = "C_2", center = { key = "c_base", set = "Default" } },
        base = { suit = "Clubs", value = "2", nominal = 2 },
        ability = { effect = "Base", set = "Default", played_this_ante = true },
        debuff = true,
        get_chip_bonus = function()
            return 2
        end,
    }
    local unplayed = {
        sort_id = 4,
        config = { card_key = "C_2", center = { key = "c_base", set = "Default" } },
        base = { suit = "Clubs", value = "2", nominal = 2 },
        ability = { effect = "Base", set = "Default" },
        debuff = false,
        get_chip_bonus = function()
            return 2
        end,
    }
    local eye = { key = "bl_eye", name = "The Eye", dollars = 5, mult = 2, debuff = {} }
    local mouth = { key = "bl_mouth", name = "The Mouth", dollars = 5, mult = 2, debuff = {} }
    local pillar = { key = "bl_pillar", name = "The Pillar", dollars = 5, mult = 2, debuff = {} }
    local psychic = {
        key = "bl_psychic",
        name = "The Psychic",
        dollars = 5,
        mult = 2,
        debuff = { h_size_ge = 5 },
    }
    local blind = {
        config = { blind = eye },
        chips = 777,
        dollars = 5,
        disabled = false,
        debuff = eye.debuff,
        hands = { Pair = true, ["High Card"] = false },
    }
    local red_deck = { key = "b_red", name = "Red Deck", set = "Back", config = {} }
    local white_stake = { key = "stake_white", name = "White Stake", order = 1 }

    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            stake_from_index = function()
                return "stake_white"
            end,
        }
        _G.G = {
            VERSION = "1.0.1o-FULL",
            STAGES = { MAIN_MENU = 1, RUN = 2 },
            STATES = { SELECTING_HAND = 1 },
            STAGE = 2,
            STATE = 1,
            STATE_COMPLETE = true,
            CONTROLLER = { locks = {}, lock_input = false },
            SETTINGS = { paused = false },
            P_CARDS = {
                S_A = { name = "Ace of Spades", suit = "Spades", value = "Ace" },
                H_K = { name = "King of Hearts", suit = "Hearts", value = "King" },
                C_2 = { name = "2 of Clubs", suit = "Clubs", value = "2" },
            },
            P_BLINDS = {
                bl_eye = eye,
                bl_mouth = mouth,
                bl_pillar = pillar,
                bl_psychic = psychic,
            },
            P_STAKES = { stake_white = white_stake },
            P_CENTERS = {},
            P_TAGS = {},
            hand = { cards = { ace, king } },
            deck = { cards = { played, unplayed } },
            jokers = { cards = {}, config = { card_limit = 5 } },
            consumeables = { cards = {}, config = { card_limit = 2 } },
            GAME = {
                selected_back = { effect = { center = red_deck } },
                stake = 1,
                dollars = 4,
                chips = 0,
                skips = 0,
                seeded = true,
                tags = {},
                used_vouchers = {},
                modifiers = {},
                starting_params = { ante_scaling = 1 },
                current_round = { hands_left = 4, discards_left = 3 },
                blind = blind,
                blind_on_deck = "Boss",
                hands = {},
                round_resets = {
                    ante = 3,
                    blind_ante = 3,
                    blind_states = { Boss = "Current" },
                    blind_tags = {},
                },
                pseudorandom = { seed = "MCPTEST" },
            },
        }

        local adapter = ProductionBalatroAdapter.new()
        local observation = adapter:observe("fair")
        luaunit.assertNotNil(observation)
        ---@cast observation table
        luaunit.assertTrue(observation.public_state.hand[1].forced_selection)
        luaunit.assertNil(observation.public_state.hand[2].forced_selection)
        for index = 1, 2 do
            local action = observation.public_state.legal_actions[index]
            luaunit.assertEquals(action.required_target_refs.card_ids, { "card:1" })
            luaunit.assertEquals(action.arguments.card_ids.min_items, 1)
        end
        luaunit.assertEquals(observation.public_state.current_blind.score_requirement, 777)
        luaunit.assertFalse(observation.public_state.current_blind.disabled)
        luaunit.assertEquals(
            observation.public_state.current_blind.hand_debuff.forbidden_poker_hands,
            { "Pair" }
        )
        blind.config.blind = pillar
        blind.hands = nil
        blind.debuff = pillar.debuff
        local pillar_observation = adapter:observe("fair")
        luaunit.assertNotNil(pillar_observation)
        ---@cast pillar_observation table
        luaunit.assertEquals(pillar_observation.public_state.current_blind.key, "bl_pillar")
        luaunit.assertEquals(#pillar_observation.public_state.remaining_deck, 2)
        local remaining = {}
        for _, entry in ipairs(pillar_observation.public_state.remaining_deck) do
            remaining[tostring(entry.played_this_ante)] = entry
        end
        luaunit.assertFalse(remaining["false"].debuffed)
        luaunit.assertTrue(remaining["true"].debuffed)

        blind.config.blind = mouth
        blind.only_hand = "Pair"
        blind.hands = nil
        blind.debuff = mouth.debuff
        blind.chips = 666
        local mouth_observation = adapter:observe("fair")
        luaunit.assertNotNil(mouth_observation)
        ---@cast mouth_observation table
        luaunit.assertEquals(
            mouth_observation.public_state.current_blind.hand_debuff.required_poker_hand,
            "Pair"
        )
        luaunit.assertEquals(mouth_observation.public_state.current_blind.score_requirement, 666)

        blind.config.blind = psychic
        blind.only_hand = nil
        blind.debuff = psychic.debuff
        blind.chips = 555
        local psychic_observation = adapter:observe("fair")
        luaunit.assertNotNil(psychic_observation)
        ---@cast psychic_observation table
        luaunit.assertEquals(
            psychic_observation.public_state.current_blind.hand_debuff.min_cards,
            5
        )
        luaunit.assertEquals(
            psychic_observation.public_state.legal_actions[2].arguments.card_ids.max_items,
            2
        )

        blind.disabled = true
        blind.chips = 333
        local disabled_observation = adapter:observe("fair")
        luaunit.assertNotNil(disabled_observation)
        ---@cast disabled_observation table
        luaunit.assertTrue(disabled_observation.public_state.current_blind.disabled)
        luaunit.assertEquals(disabled_observation.public_state.current_blind.score_requirement, 333)
        luaunit.assertNil(disabled_observation.public_state.current_blind.hand_debuff)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_pending_observe_reports_block_gates()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            stake_from_index = function()
                return "stake_white"
            end,
        }
        _G.G = {
            VERSION = "1.0.1o-FULL",
            STAGES = { MAIN_MENU = 1, RUN = 2 },
            STATES = { SELECTING_HAND = 1, SHOP = 5, BLIND_SELECT = 7 },
            STAGE = 2,
            STATE = 5,
            STATE_COMPLETE = true,
            CONTROLLER = { locks = {}, lock_input = false },
            SETTINGS = { paused = true },
            shop = {},
            hand = { cards = {} },
            GAME = { STOP_USE = 0, dollars = 12 },
        }
        local adapter = ProductionBalatroAdapter.new()
        adapter.pending_dollars = 6
        adapter.pending_dollars_dir = -1
        local _, pending_error = adapter:observe("fair")
        luaunit.assertNotNil(pending_error)
        ---@cast pending_error table
        luaunit.assertEquals(pending_error.code, "DECISION_PENDING")
        luaunit.assertEquals(
            pending_error.observe_block,
            "observe pending state=SHOP complete=true paused=true stop_use=0 locked=false money=12 pending_d=6 pending_dir=-1 shop=true hand=0 overlay=false slots=shop"
        )
        luaunit.assertEquals(pending_error.diagnostic, {
            complete = true,
            hand = 0,
            locked = false,
            money = 12,
            overlay = false,
            paused = true,
            pending_dollars = 6,
            pending_dollars_direction = -1,
            shop = true,
            slot = "shop",
            state = "SHOP",
            state_value = 5,
            stop_use = 0,
        })
    end, debug.traceback)
    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_owned_items_can_be_observed_reordered_used_and_sold()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local ace = {
        sort_id = 1,
        facing = "front",
        edition = { foil = true, chips = 50 },
        T = { x = 1, w = 1 },
        config = { card_key = "S_A", center = { key = "c_base", set = "Default" } },
        base = { suit = "Spades", value = "Ace", nominal = 11 },
        ability = { effect = "Base", set = "Default" },
        debuff = false,
        get_chip_bonus = function()
            return 11
        end,
    }
    local king = {
        sort_id = 2,
        facing = "back",
        edition = { negative = true, card_limit = 1 },
        T = { x = 2, w = 1 },
        config = { card_key = "H_K", center = { key = "c_base", set = "Default" } },
        base = { suit = "Hearts", value = "King", nominal = 10 },
        ability = { effect = "Base", set = "Default" },
        debuff = false,
        get_chip_bonus = function()
            return 10
        end,
    }
    local joker = {
        sort_id = 11,
        T = { x = 1, w = 1 },
        edition = { negative = true, card_limit = 1 },
        cost = 2,
        sell_cost = 1,
        debuff = false,
        ability = { set = "Joker", name = "Joker", mult = 4 },
        config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
        can_sell_card = function()
            return true
        end,
    }
    local stencil = {
        sort_id = 12,
        T = { x = 2, w = 1 },
        cost = 8,
        sell_cost = 4,
        debuff = false,
        ability = { set = "Joker", name = "Joker Stencil", eternal = true },
        config = { center = { key = "j_stencil", set = "Joker", name = "Joker Stencil" } },
        can_sell_card = function()
            return false
        end,
    }
    local hermit = {
        sort_id = 21,
        cost = 3,
        edition = { negative = true, card_limit = 1 },
        sell_cost = 1,
        debuff = false,
        ability = {
            set = "Tarot",
            name = "The Hermit",
            consumeable = { extra = 20 },
        },
        config = { center = { key = "c_hermit", set = "Tarot", name = "The Hermit" } },
        can_sell_card = function()
            return true
        end,
        can_use_consumeable = function()
            return true
        end,
    }
    local strength = {
        sort_id = 22,
        cost = 3,
        edition = { holo = true, mult = 10 },
        sell_cost = 1,
        debuff = false,
        ability = {
            set = "Tarot",
            name = "Strength",
            consumeable = { max_highlighted = 2, min_highlighted = 1 },
        },
        config = { center = { key = "c_strength", set = "Tarot", name = "Strength" } },
        can_sell_card = function()
            return true
        end,
        can_use_consumeable = function()
            return #G.hand.highlighted >= 1
        end,
    }
    local red_deck = {
        key = "b_red",
        name = "Red Deck",
        set = "Back",
        config = { discards = 1 },
    }
    local white_stake = { key = "stake_white", name = "White Stake", order = 1 }
    local small_blind = { key = "bl_small", name = "Small Blind", dollars = 3, mult = 1 }
    local highlighted = {}
    local used
    local sold

    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            stake_from_index = function()
                return "stake_white"
            end,
        }
        _G.G = {
            VERSION = "1.0.1o-FULL",
            STAGES = { MAIN_MENU = 1, RUN = 2 },
            STATES = { SELECTING_HAND = 1, SHOP = 5, BLIND_SELECT = 7 },
            STAGE = 2,
            STATE = 1,
            STATE_COMPLETE = true,
            CONTROLLER = { locks = {}, lock_input = false },
            SETTINGS = { paused = false, tutorial_complete = true },
            P_CARDS = {
                S_A = { name = "Ace of Spades", suit = "Spades", value = "Ace" },
                H_K = { name = "King of Hearts", suit = "Hearts", value = "King" },
            },
            P_BLINDS = { bl_small = small_blind },
            P_STAKES = { stake_white = white_stake },
            P_CENTERS = {},
            P_TAGS = {},
            hand = {
                cards = { ace, king },
                highlighted = highlighted,
                add_to_highlighted = function(_, card)
                    highlighted[#highlighted + 1] = card
                end,
                unhighlight_all = function()
                    for index = #highlighted, 1, -1 do
                        highlighted[index] = nil
                    end
                end,
                set_ranks = function(self)
                    for index, card in ipairs(self.cards) do
                        card.rank = index
                    end
                end,
                align_cards = function(self)
                    table.sort(self.cards, function(a, b)
                        return (a.T and a.T.x or 0) < (b.T and b.T.x or 0)
                    end)
                end,
            },
            jokers = {
                cards = { joker, stencil },
                config = { card_limit = 5, type = "joker" },
                set_ranks = function(self)
                    for index, card in ipairs(self.cards) do
                        card.rank = index
                    end
                end,
                align_cards = function(self)
                    table.sort(self.cards, function(a, b)
                        return (a.T and a.T.x or 0) < (b.T and b.T.x or 0)
                    end)
                end,
            },
            consumeables = {
                cards = { hermit, strength },
                config = { card_limit = 2, type = "joker" },
            },
            deck = { cards = {} },
            FUNCS = {
                use_card = function(e)
                    used = {
                        key = e.config.ref_table.config.center.key,
                        targets = {},
                    }
                    for _, card in ipairs(G.hand.highlighted) do
                        used.targets[#used.targets + 1] = card.config.card_key
                    end
                    for index, card in ipairs(G.consumeables.cards) do
                        if card == e.config.ref_table then
                            table.remove(G.consumeables.cards, index)
                            break
                        end
                    end
                end,
                sell_card = function(e)
                    sold = e.config.ref_table.config.center.key
                    G.GAME.dollars = G.GAME.dollars + e.config.ref_table.sell_cost
                    for index, card in ipairs(G.jokers.cards) do
                        if card == e.config.ref_table then
                            table.remove(G.jokers.cards, index)
                            break
                        end
                    end
                end,
            },
            GAME = {
                selected_back = { effect = { center = red_deck } },
                stake = 1,
                dollars = 6,
                chips = 0,
                skips = 0,
                seeded = true,
                tags = {},
                used_vouchers = {},
                modifiers = {},
                starting_params = { ante_scaling = 1 },
                current_round = { hands_left = 4, discards_left = 3 },
                blind = { config = { blind = small_blind } },
                blind_on_deck = "Small",
                hands = {
                    Pair = { visible = true, level = 1, chips = 10, mult = 2, played = 0 },
                },
                round_resets = {
                    ante = 1,
                    blind_ante = 1,
                    blind_choices = { Small = "bl_small" },
                    blind_states = { Small = "Current" },
                    blind_tags = {},
                },
                pseudorandom = { seed = "MCPTEST" },
            },
        }
        joker.area = G.jokers
        stencil.area = G.jokers
        hermit.area = G.consumeables
        strength.area = G.consumeables

        local adapter = ProductionBalatroAdapter.new()
        adapter.english = { descriptions = { Edition = edition_localization } }
        local observation, observe_error = adapter:observe("fair")
        luaunit.assertNil(observe_error)
        luaunit.assertNotNil(observation)
        ---@cast observation table
        luaunit.assertEquals(observation.public_state.hand[1].edition, {
            key = "e_foil",
            name = "Foil",
            description = "+50 chips",
        })
        luaunit.assertNil(observation.public_state.hand[2].edition)
        luaunit.assertEquals(observation.hidden_state.facedown_cards[1].edition.key, "e_negative")
        luaunit.assertEquals(observation.public_state.jokers[1].edition, {
            key = "e_negative",
            name = "Negative",
            description = "+1 Joker slot",
        })
        luaunit.assertEquals(observation.public_state.jokers[1].key, "j_joker")
        luaunit.assertEquals(observation.public_state.jokers[1].sell_value, 1)
        luaunit.assertTrue(observation.public_state.jokers[1].sellable)
        luaunit.assertTrue(observation.public_state.jokers[2].eternal)
        luaunit.assertFalse(observation.public_state.jokers[2].sellable)
        luaunit.assertEquals(observation.public_state.joker_limit, 5)
        luaunit.assertEquals(observation.public_state.consumables[1].key, "c_hermit")
        luaunit.assertEquals(observation.public_state.consumables[1].edition, {
            key = "e_negative",
            name = "Negative",
            description = "+1 consumable slot",
        })
        luaunit.assertEquals(observation.public_state.consumables[1].min_targets, 0)
        luaunit.assertEquals(observation.public_state.consumables[2].edition.key, "e_holo")
        luaunit.assertEquals(observation.public_state.consumables[2].max_targets, 2)
        luaunit.assertEquals(observation.public_state.hand[2].facedown, true)
        luaunit.assertNil(observation.public_state.hand[2].key)
        luaunit.assertEquals(observation.hidden_state.facedown_cards[1].key, "H_K")
        local tools = {}
        for _, action in ipairs(observation.public_state.legal_actions) do
            tools[#tools + 1] = action.tool
        end
        luaunit.assertEquals(tools[3], "reorder_cards")
        luaunit.assertEquals(tools[4], "reorder_cards")
        luaunit.assertEquals(tools[5], "use_consumable")
        luaunit.assertEquals(tools[6], "use_consumable")
        luaunit.assertEquals(tools[7], "sell_owned_item")

        local reorder, reorder_error = adapter:execute({
            name = "reorder_cards",
            expected_state_hash = "sha256:test",
            visibility = "fair",
            arguments = { area = "jokers" },
            targets = { ordered_ids = { "joker:12", "joker:11" } },
        })
        luaunit.assertNil(reorder_error)
        luaunit.assertNotNil(reorder)
        ---@cast reorder table
        luaunit.assertEquals(G.jokers.cards[1].config.center.key, "j_stencil")
        luaunit.assertNil(reorder.events)
        luaunit.assertEquals(reorder.observation.public_state.jokers[1].key, "j_stencil")

        local rejected, rejected_error = adapter:execute({
            name = "reorder_cards",
            expected_state_hash = "sha256:test",
            arguments = { area = "jokers" },
            targets = { ordered_ids = { "joker:12" } },
        })
        luaunit.assertNil(rejected)
        luaunit.assertNotNil(rejected_error)
        ---@cast rejected_error table
        luaunit.assertEquals(rejected_error.code, "INVALID_TARGET")
        luaunit.assertEquals(G.jokers.cards[1].config.center.key, "j_stencil")

        local used_result, used_error = adapter:execute({
            name = "use_consumable",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = {
                consumable_id = "consumable:22",
                target_ids = { "card:2", "card:1" },
            },
        })
        luaunit.assertNil(used_error)
        luaunit.assertNotNil(used_result)
        ---@cast used_result table
        luaunit.assertTrue(used_result.pending)
        luaunit.assertEquals(used.key, "c_strength")
        luaunit.assertEquals(used.targets, { "H_K", "S_A" })
        luaunit.assertNil(used_result.events)

        local hermit_result, hermit_error = adapter:execute({
            name = "use_consumable",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { consumable_id = "consumable:21" },
        })
        luaunit.assertNil(hermit_error)
        luaunit.assertNotNil(hermit_result)
        ---@cast hermit_result table
        luaunit.assertEquals(used.key, "c_hermit")
        luaunit.assertNil(hermit_result.events)

        local sold_result, sold_error = adapter:execute({
            name = "sell_owned_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "joker:11" },
        })
        luaunit.assertNil(sold_error)
        luaunit.assertNotNil(sold_result)
        ---@cast sold_result table
        luaunit.assertTrue(sold_result.pending)
        luaunit.assertEquals(sold, "j_joker")
        luaunit.assertEquals(G.GAME.dollars, 7)
        luaunit.assertEquals(#G.jokers.cards, 1)
        luaunit.assertNil(sold_result.events)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_shop_inventory_can_be_bought_rerolled_and_left()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_create = rawget(_G, "create_card")
    local shop_joker = {
        sort_id = 31,
        cost = 5,
        ability = {
            set = "Joker",
            name = "Greedy Joker",
            extra = { s_mult = 3, suit = "Diamonds" },
        },
        config = { center = { key = "j_greedy_joker", set = "Joker", name = "Greedy Joker" } },
    }
    local shop_planet = {
        sort_id = 32,
        cost = 3,
        ability = { set = "Planet", name = "Pluto", consumeable = { hand_type = "High Card" } },
        config = { center = { key = "c_pluto", set = "Planet", name = "Pluto" } },
        can_use_consumeable = function()
            return true
        end,
    }
    local shop_card = {
        sort_id = 33,
        cost = 1,
        ability = { set = "Default", effect = "Base" },
        config = { card_key = "S_A", center = { key = "c_base", set = "Default" } },
        base = { suit = "Spades", value = "Ace", nominal = 11 },
        get_chip_bonus = function()
            return 11
        end,
    }
    local shop_negative_joker = {
        sort_id = 134,
        cost = 100,
        edition = { negative = true, card_limit = 1 },
        ability = { set = "Joker", name = "Joker" },
        config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
    }
    local shop_negative_consumable = {
        sort_id = 135,
        cost = 100,
        edition = { negative = true, card_limit = 1 },
        ability = { set = "Tarot", name = "The Hermit", consumeable = { extra = 20 } },
        config = { center = { key = "c_hermit", set = "Tarot", name = "The Hermit" } },
    }
    local shop_voucher = {
        sort_id = 41,
        cost = 10,
        ability = { set = "Voucher", name = "Overstock" },
        config = {
            center = {
                key = "v_overstock_norm",
                set = "Voucher",
                name = "Overstock",
                config = {},
            },
        },
    }
    local shop_booster = {
        sort_id = 51,
        cost = 4,
        ability = { set = "Booster", name = "Arcana Pack", extra = 3 },
        config = {
            center = {
                key = "p_arcana_normal_1",
                set = "Booster",
                name = "Arcana Pack",
                config = { extra = 3, choose = 1 },
            },
        },
    }
    local owned_joker = {
        sort_id = 11,
        cost = 2,
        sell_cost = 1,
        ability = { set = "Joker", name = "Joker", mult = 4 },
        config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
        can_sell_card = function()
            return true
        end,
    }
    local pack_tarot = {
        sort_id = 61,
        edition = { negative = true, card_limit = 1 },
        ability = { set = "Tarot", name = "The Fool", consumeable = {} },
        config = { center = { key = "c_fool", set = "Tarot", name = "The Fool" } },
    }
    local bought = {}
    local used
    local redeemed
    local opened
    local rerolled
    local left
    local queued = {}
    local red_deck = { key = "b_red", name = "Red Deck", set = "Back", config = { discards = 1 } }
    local white_stake = { key = "stake_white", name = "White Stake", order = 1 }

    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            stake_from_index = function()
                return "stake_white"
            end,
        }
        _G.G = {
            VERSION = "1.0.1o-FULL",
            STAGES = { MAIN_MENU = 1, RUN = 2 },
            STATES = {
                SELECTING_HAND = 1,
                SHOP = 5,
                BLIND_SELECT = 7,
                TAROT_PACK = 8,
            },
            STAGE = 2,
            STATE = 5,
            STATE_COMPLETE = true,
            CONTROLLER = { locks = {}, lock_input = false },
            SETTINGS = { paused = false, tutorial_complete = true },
            P_CARDS = { S_A = { name = "Ace of Spades", suit = "Spades", value = "Ace" } },
            P_BLINDS = {},
            P_STAKES = { stake_white = white_stake },
            P_CENTERS = {},
            P_TAGS = {},
            shop = {},
            shop_jokers = {
                cards = {
                    shop_joker,
                    shop_planet,
                    shop_card,
                    shop_negative_joker,
                    shop_negative_consumable,
                },
            },
            shop_vouchers = { cards = { shop_voucher } },
            shop_booster = { cards = { shop_booster } },
            jokers = { cards = { owned_joker }, config = { card_limit = 5 } },
            consumeables = { cards = {}, config = { card_limit = 2 } },
            hand = { cards = {}, highlighted = {}, unhighlight_all = function() end },
            deck = { cards = {} },
            E_MANAGER = {
                add_event = function(_, event)
                    queued[#queued + 1] = event
                end,
            },
            FUNCS = {
                buy_from_shop = function(e)
                    bought[#bought + 1] = {
                        key = e.config.ref_table.config.card_key
                            or e.config.ref_table.config.center.key,
                        id = e.config.id,
                    }
                    G.GAME.dollars = G.GAME.dollars - e.config.ref_table.cost
                    if e.config.id == "buy_and_use" then
                        used = e.config.ref_table.config.center.key
                        if used == "c_hermit" then
                            G.GAME.dollars = G.GAME.dollars * 2
                        end
                    elseif e.config.ref_table.ability.set == "Joker" then
                        G.jokers.cards[#G.jokers.cards + 1] = e.config.ref_table
                    elseif e.config.ref_table.ability.consumeable then
                        G.consumeables.cards[#G.consumeables.cards + 1] = e.config.ref_table
                    end
                    local area = e.config.ref_table.area
                    for index, card in ipairs(area.cards) do
                        if card == e.config.ref_table then
                            table.remove(area.cards, index)
                            break
                        end
                    end
                end,
                use_card = function(e)
                    local card = e.config.ref_table
                    if card.ability.set == "Voucher" then
                        redeemed = card.config.center.key
                        G.GAME.dollars = G.GAME.dollars - card.cost
                        G.GAME.used_vouchers[card.config.center.key] = true
                        G.shop_vouchers.cards = {}
                    elseif card.ability.set == "Booster" then
                        opened = card.config.center.key
                        G.GAME.dollars = G.GAME.dollars - card.cost
                        G.E_MANAGER:add_event({
                            func = function()
                                create_card("Tarot", G.consumeables)
                                return true
                            end,
                        })
                        G.STATE = G.STATES.TAROT_PACK
                        G.booster_pack = {}
                        G.pack_cards = { cards = { pack_tarot } }
                        G.GAME.pack_choices = 1
                        G.shop_booster.cards = {}
                    end
                end,
                reroll_shop = function()
                    rerolled = true
                    G.GAME.dollars = G.GAME.dollars - G.GAME.current_round.reroll_cost
                    G.GAME.current_round.reroll_cost = 6
                    G.shop_jokers.cards = {
                        {
                            sort_id = 99,
                            cost = 3,
                            ability = { set = "Joker", name = "Jolly Joker" },
                            config = {
                                center = { key = "j_jolly", set = "Joker", name = "Jolly Joker" },
                            },
                        },
                    }
                end,
                toggle_shop = function()
                    left = true
                    G.STATE = G.STATES.BLIND_SELECT
                    G.shop = nil
                end,
            },
            GAME = {
                selected_back = { effect = { center = red_deck } },
                stake = 1,
                dollars = 40,
                bankrupt_at = 0,
                chips = 0,
                skips = 0,
                seeded = true,
                tags = {},
                used_vouchers = {},
                modifiers = {},
                starting_params = { ante_scaling = 1 },
                current_round = { reroll_cost = 5, hands_left = 0, discards_left = 0 },
                hands = {},
                round_resets = { ante = 1, blind_ante = 1 },
                pack_choices = 0,
                pseudorandom = { seed = "MCPTEST" },
            },
        }
        shop_joker.area = G.shop_jokers
        shop_planet.area = G.shop_jokers
        shop_card.area = G.shop_jokers
        shop_negative_joker.area = G.shop_jokers
        shop_negative_consumable.area = G.shop_jokers
        shop_voucher.area = G.shop_vouchers
        shop_booster.area = G.shop_booster
        owned_joker.area = G.jokers
        rawset(_G, "create_card", function(_type, _area)
            return {
                sort_id = 88,
                facing = "front",
                ability = { consumeable = true, set = "Tarot" },
                config = { center = { key = "c_fool", set = "Tarot" } },
            }
        end)

        local adapter = ProductionBalatroAdapter.new()
        adapter.english = { descriptions = { Edition = edition_localization } }
        local observation, observe_error = adapter:observe("fair")
        luaunit.assertNil(observe_error)
        luaunit.assertNotNil(observation)
        ---@cast observation table
        luaunit.assertEquals(observation.phase, "shop")
        luaunit.assertEquals(observation.public_state.money, 40)
        luaunit.assertEquals(observation.public_state.reroll_cost, 5)
        luaunit.assertEquals(observation.public_state.joker_limit, 5)
        luaunit.assertEquals(observation.public_state.shop_items[1].key, "j_greedy_joker")
        luaunit.assertEquals(observation.public_state.shop_items[1].category, "joker")
        luaunit.assertEquals(observation.public_state.shop_items[1].cost, 5)
        luaunit.assertEquals(observation.public_state.shop_items[1].slot, "joker")
        luaunit.assertEquals(observation.public_state.shop_items[2].category, "consumable")
        luaunit.assertEquals(observation.public_state.shop_items[3].category, "playing_card")
        luaunit.assertEquals(observation.public_state.shop_items[4].edition, {
            key = "e_negative",
            name = "Negative",
            description = "+1 Joker slot",
        })
        luaunit.assertEquals(observation.public_state.shop_items[5].edition, {
            key = "e_negative",
            name = "Negative",
            description = "+1 consumable slot",
        })
        luaunit.assertEquals(observation.public_state.shop_vouchers[1].key, "v_overstock_norm")
        luaunit.assertEquals(observation.public_state.shop_boosters[1].key, "p_arcana_normal_1")
        local tools = {}
        for _, action in ipairs(observation.public_state.legal_actions) do
            tools[#tools + 1] = action.tool
        end
        luaunit.assertEquals(tools[1], "buy_shop_item")
        luaunit.assertEquals(tools[2], "buy_and_use_shop_item")
        luaunit.assertEquals(tools[#tools], "leave_shop")

        local buy, buy_error = adapter:execute({
            name = "buy_shop_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "shop_item:31" },
        })
        luaunit.assertNil(buy_error)
        luaunit.assertNotNil(buy)
        ---@cast buy table
        luaunit.assertTrue(buy.pending)
        luaunit.assertEquals(bought[1].key, "j_greedy_joker")
        luaunit.assertNil(buy.events)
        luaunit.assertEquals(#G.jokers.cards, 2)

        local use, use_error = adapter:execute({
            name = "buy_and_use_shop_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "shop_item:32" },
        })
        luaunit.assertNil(use_error)
        luaunit.assertNotNil(use)
        ---@cast use table
        luaunit.assertEquals(used, "c_pluto")
        luaunit.assertNil(use.events)
        local use_resolution, use_capture_error = adapter:finish_resolution(use.resolution_context)
        luaunit.assertNil(use_capture_error)
        luaunit.assertNil(use_resolution)

        local card_buy, card_error = adapter:execute({
            name = "buy_shop_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "shop_item:33" },
        })
        luaunit.assertNil(card_error)
        luaunit.assertNotNil(card_buy)
        ---@cast card_buy table
        luaunit.assertEquals(bought[3].key, "S_A")

        local shop_tarot = {
            sort_id = 34,
            cost = 3,
            ability = { set = "Tarot", name = "The Hermit", consumeable = { extra = 20 } },
            config = { center = { key = "c_hermit", set = "Tarot", name = "The Hermit" } },
            area = G.shop_jokers,
            can_use_consumeable = function()
                return true
            end,
        }
        G.shop_jokers.cards[#G.shop_jokers.cards + 1] = shop_tarot
        local money_before_hermit = G.GAME.dollars
        local hermit, hermit_error = adapter:execute({
            name = "buy_and_use_shop_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "shop_item:34" },
        })
        luaunit.assertNil(hermit_error)
        luaunit.assertNotNil(hermit)
        luaunit.assertEquals(G.GAME.dollars, (money_before_hermit - shop_tarot.cost) * 2)
        local after_hermit, after_hermit_error = adapter:observe("fair")
        luaunit.assertNil(after_hermit_error)
        luaunit.assertNotNil(after_hermit)

        G.shop_jokers.cards[#G.shop_jokers.cards + 1] = shop_tarot
        local hold, hold_error = adapter:execute({
            name = "buy_shop_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "shop_item:34" },
        })
        luaunit.assertNil(hold_error)
        luaunit.assertNotNil(hold)
        ---@cast hold table
        luaunit.assertNil(hold.events)
        luaunit.assertEquals(#G.consumeables.cards, 1)
        luaunit.assertEquals(G.consumeables.cards[1].config.center.key, "c_hermit")

        local redeem, redeem_error = adapter:execute({
            name = "redeem_voucher",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { voucher_id = "shop_voucher:41" },
        })
        luaunit.assertNil(redeem_error)
        luaunit.assertNotNil(redeem)
        ---@cast redeem table
        luaunit.assertEquals(redeemed, "v_overstock_norm")
        luaunit.assertNil(redeem.events)
        luaunit.assertTrue(G.GAME.used_vouchers.v_overstock_norm)

        local open, open_error = adapter:execute({
            name = "open_booster",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { booster_id = "shop_booster:51" },
        })
        luaunit.assertNil(open_error)
        luaunit.assertNotNil(open)
        ---@cast open table
        luaunit.assertEquals(opened, "p_arcana_normal_1")
        luaunit.assertNil(open.events)
        luaunit.assertEquals(#queued, 1)
        queued[1].func()
        local open_resolution, open_capture_error =
            adapter:finish_resolution(open.resolution_context)
        luaunit.assertNil(open_capture_error)
        luaunit.assertNil(open_resolution)
        local booster, booster_error = adapter:observe("fair")
        luaunit.assertNil(booster_error)
        luaunit.assertNotNil(booster)
        ---@cast booster table
        luaunit.assertEquals(booster.phase, "booster")
        luaunit.assertEquals(booster.public_state.booster.category, "arcana")
        luaunit.assertEquals(booster.public_state.booster_items[1].key, "c_fool")
        luaunit.assertEquals(booster.public_state.booster_items[1].edition, {
            key = "e_negative",
            name = "Negative",
            description = "+1 consumable slot",
        })

        G.STATE = G.STATES.SHOP
        G.shop = {}
        G.booster_pack = nil
        G.pack_cards = nil
        local reroll, reroll_error = adapter:execute({
            name = "reroll_shop",
            expected_state_hash = "sha256:test",
            arguments = {},
        })
        luaunit.assertNil(reroll_error)
        luaunit.assertNotNil(reroll)
        ---@cast reroll table
        luaunit.assertTrue(rerolled)
        luaunit.assertNil(reroll.events)
        luaunit.assertEquals(G.shop_jokers.cards[1].config.center.key, "j_jolly")

        local leave, leave_error = adapter:execute({
            name = "leave_shop",
            expected_state_hash = "sha256:test",
            arguments = {},
        })
        luaunit.assertNil(leave_error)
        luaunit.assertNotNil(leave)
        ---@cast leave table
        luaunit.assertTrue(left)
        luaunit.assertNil(leave.events)

        G.STATE = G.STATES.SHOP
        G.shop = {}
        G.GAME.dollars = 10
        G.shop_jokers.cards = { shop_joker }
        shop_joker.area = G.shop_jokers
        shop_joker.cost = 4
        G.FUNCS.buy_from_shop = function()
            bought[#bought + 1] = { key = "delayed" }
        end
        local delayed, delayed_error = adapter:execute({
            name = "buy_shop_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "shop_item:31" },
        })
        luaunit.assertNil(delayed_error)
        luaunit.assertNotNil(delayed)
        local waiting_money, waiting_error = adapter:observe("fair")
        luaunit.assertNil(waiting_money)
        luaunit.assertNotNil(waiting_error)
        ---@cast waiting_error table
        luaunit.assertEquals(waiting_error.code, "DECISION_PENDING")
        G.GAME.dollars = 6
        local paid_shop = adapter:observe("fair")
        luaunit.assertNotNil(paid_shop)
        ---@cast paid_shop table
        luaunit.assertEquals(paid_shop.phase, "shop")
        luaunit.assertEquals(paid_shop.public_state.money, 6)

        G.GAME.dollars = 0
        local broke, broke_error = adapter:execute({
            name = "buy_shop_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "shop_item:31" },
        })
        luaunit.assertNil(broke)
        luaunit.assertNotNil(broke_error)
        ---@cast broke_error table
        luaunit.assertEquals(broke_error.code, "ACTION_NOT_ALLOWED")

        G.GAME.dollars = 20
        G.jokers.cards = { owned_joker, shop_joker, shop_joker, shop_joker, shop_joker }
        G.jokers.config.card_limit = 5
        local full, full_error = adapter:execute({
            name = "buy_shop_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "shop_item:31" },
        })
        luaunit.assertNil(full)
        luaunit.assertNotNil(full_error)
        ---@cast full_error table
        luaunit.assertEquals(full_error.code, "ACTION_NOT_ALLOWED")

        local hand_king = {
            sort_id = 71,
            ability = { set = "Default", effect = "Base" },
            config = { card_key = "H_K", center = { key = "c_base", set = "Default" } },
            base = { suit = "Hearts", value = "King", nominal = 10 },
            get_chip_bonus = function()
                return 10
            end,
        }
        local hand_ace = {
            sort_id = 72,
            edition = { type = "foil" },
            ability = { set = "Default", effect = "Base" },
            config = { card_key = "S_A", center = { key = "c_base", set = "Default" } },
            base = { suit = "Spades", value = "Ace", nominal = 11 },
            get_chip_bonus = function()
                return 11
            end,
        }
        local shop_aura = {
            sort_id = 73,
            cost = 3,
            ability = { set = "Spectral", name = "Aura", consumeable = { max_highlighted = 1 } },
            config = { center = { key = "c_aura", set = "Spectral", name = "Aura" } },
            can_use_consumeable = function()
                return #G.hand.highlighted >= 1
            end,
        }
        G.GAME.dollars = 20
        G.hand.cards = { hand_king, hand_ace }
        G.hand.highlighted = {}
        G.shop_jokers.cards = { shop_aura }
        shop_aura.area = G.shop_jokers
        local aura_shop = adapter:observe("fair")
        luaunit.assertNotNil(aura_shop)
        ---@cast aura_shop table
        local immediate
        for _, action in ipairs(aura_shop.public_state.legal_actions) do
            if action.tool == "buy_and_use_shop_item" then
                immediate = action
            end
        end
        luaunit.assertNotNil(immediate)
        luaunit.assertEquals(immediate.target_refs.target_ids, { "card:71" })
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "create_card", saved_create)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_booster_decision_stays_stable_and_supports_choices()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local booster_server
    local hand_king = {
        sort_id = 1,
        ability = { set = "Default", effect = "Base" },
        config = { card_key = "H_K", center = { key = "c_base", set = "Default" } },
        base = { suit = "Hearts", value = "King", nominal = 10 },
        get_chip_bonus = function()
            return 10
        end,
    }
    local hand_ace = {
        sort_id = 2,
        ability = { set = "Default", effect = "Base" },
        config = { card_key = "S_A", center = { key = "c_base", set = "Default" } },
        base = { suit = "Spades", value = "Ace", nominal = 11 },
        get_chip_bonus = function()
            return 11
        end,
    }
    local pack_fool = {
        sort_id = 61,
        edition = { negative = true, card_limit = 1 },
        ability = { set = "Tarot", name = "The Fool", consumeable = {} },
        config = { center = { key = "c_fool", set = "Tarot", name = "The Fool" } },
        can_use_consumeable = function()
            return true
        end,
    }
    local pack_strength = {
        sort_id = 62,
        ability = {
            set = "Tarot",
            name = "Strength",
            consumeable = { max_highlighted = 2, min_highlighted = 1 },
        },
        config = { center = { key = "c_strength", set = "Tarot", name = "Strength" } },
        can_use_consumeable = function()
            return true
        end,
    }
    local pack_aura = {
        sort_id = 67,
        ability = { set = "Spectral", name = "Aura", consumeable = { max_highlighted = 1 } },
        config = { center = { key = "c_aura", set = "Spectral", name = "Aura" } },
    }
    local pack_temperance = {
        sort_id = 66,
        ability = { set = "Tarot", name = "Temperance", consumeable = { extra = 50 } },
        config = { center = { key = "c_temperance", set = "Tarot", name = "Temperance" } },
        can_use_consumeable = function()
            return true
        end,
    }
    local pack_pluto = {
        sort_id = 63,
        ability = { set = "Planet", name = "Pluto", consumeable = { hand_type = "High Card" } },
        config = { center = { key = "c_pluto", set = "Planet", name = "Pluto" } },
        can_use_consumeable = function()
            return true
        end,
    }
    local pack_card = {
        sort_id = 64,
        ability = { set = "Default", effect = "Base" },
        config = { card_key = "H_K", center = { key = "c_base", set = "Default" } },
        base = { suit = "Hearts", value = "King", nominal = 10 },
        get_chip_bonus = function()
            return 10
        end,
    }
    local pack_joker = {
        sort_id = 65,
        ability = { set = "Joker", name = "Joker", mult = 4 },
        config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
    }
    local used = {}
    local skipped = false
    local red_deck = { key = "b_red", name = "Red Deck", set = "Back", config = { discards = 1 } }
    local white_stake = { key = "stake_white", name = "White Stake", order = 1 }

    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            stake_from_index = function()
                return "stake_white"
            end,
        }
        _G.G = {
            VERSION = "1.0.1o-FULL",
            STAGES = { MAIN_MENU = 1, RUN = 2 },
            STATES = {
                SELECTING_HAND = 1,
                SHOP = 5,
                BLIND_SELECT = 7,
                TAROT_PACK = 8,
                PLANET_PACK = 9,
                SPECTRAL_PACK = 10,
                STANDARD_PACK = 11,
                BUFFOON_PACK = 12,
                SMODS_BOOSTER_OPENED = 999,
            },
            STAGE = 2,
            STATE = 8,
            STATE_COMPLETE = true,
            CONTROLLER = { locks = {}, lock_input = false },
            SETTINGS = { paused = false, tutorial_complete = true },
            P_CARDS = {
                H_K = { name = "King of Hearts", suit = "Hearts", value = "King" },
                S_A = { name = "Ace of Spades", suit = "Spades", value = "Ace" },
            },
            P_BLINDS = {},
            P_STAKES = { stake_white = white_stake },
            P_CENTERS = {},
            P_TAGS = {},
            booster_pack = {},
            pack_cards = {
                cards = { pack_fool, pack_strength },
                config = { card_limit = 2 },
            },
            jokers = { cards = {}, config = { card_limit = 5 } },
            consumeables = { cards = {}, config = { card_limit = 2 } },
            hand = {
                cards = { hand_king, hand_ace },
                highlighted = {},
                unhighlight_all = function(self)
                    self.highlighted = {}
                end,
            },
            deck = { cards = {} },
            FUNCS = {
                use_card = function(e)
                    local card = e.config.ref_table
                    used[#used + 1] = {
                        key = card.config.card_key or card.config.center.key,
                        targets = {},
                    }
                    for index, hand_card in ipairs(G.hand.highlighted) do
                        used[#used].targets[index] = hand_card.config.card_key
                    end
                    for index, pack_card in ipairs(G.pack_cards.cards) do
                        if pack_card == card then
                            table.remove(G.pack_cards.cards, index)
                            break
                        end
                    end
                    G.GAME.pack_choices = G.GAME.pack_choices - 1
                    if G.GAME.pack_choices < 1 or #G.pack_cards.cards < 1 then
                        G.STATE = G.STATES.SHOP
                        G.shop = {}
                        G.booster_pack = nil
                        G.pack_cards = { cards = {} }
                    end
                end,
                sell_card = function(e)
                    local card = e.config.ref_table
                    for index, joker in ipairs(G.jokers.cards) do
                        if joker == card then
                            table.remove(G.jokers.cards, index)
                            break
                        end
                    end
                    G.GAME.dollars = G.GAME.dollars + card.sell_cost
                end,
                skip_booster = function()
                    skipped = true
                    G.STATE = G.STATES.SHOP
                    G.shop = {}
                    G.booster_pack = nil
                    G.pack_cards = { cards = {} }
                end,
            },
            GAME = {
                selected_back = { effect = { center = red_deck } },
                stake = 1,
                dollars = 8,
                bankrupt_at = 0,
                chips = 0,
                skips = 0,
                seeded = true,
                tags = {},
                used_vouchers = {},
                modifiers = {},
                starting_params = { ante_scaling = 1 },
                current_round = { reroll_cost = 5, hands_left = 0, discards_left = 0 },
                hands = {},
                round_resets = { ante = 1, blind_ante = 1 },
                pack_choices = 2,
                pseudorandom = { seed = "MCPTEST" },
            },
        }
        pack_fool.area = G.pack_cards
        pack_strength.area = G.pack_cards

        local adapter = ProductionBalatroAdapter.new()
        adapter.english = {
            descriptions = {
                Edition = edition_localization,
                Planet = {
                    c_pluto = {
                        name = "Pluto",
                        text = { "(lvl.#1#) Level up #2#", "+#3# Mult and +#4# chips" },
                    },
                },
                Tarot = {
                    c_strength = {
                        name = "Strength",
                        text = { "Increases rank of up to #1# selected cards by 1" },
                    },
                    c_temperance = {
                        name = "Temperance",
                        text = { "Maximum #1#, currently #2#" },
                    },
                },
            },
            misc = { poker_hands = { ["High Card"] = "High Card" } },
        }
        local hand_cards = G.hand.cards
        G.hand.cards = { hand_king }
        SMODS.cards_to_draw = 1
        local raw_observe = adapter.observe
        local observe_count = 0
        adapter.observe = function(self, visibility)
            observe_count = observe_count + 1
            if observe_count == 3 then
                G.hand.cards = hand_cards
                SMODS.cards_to_draw = 0
            end
            return raw_observe(self, visibility)
        end
        booster_server = GameMcpServer.new({
            adapter = adapter,
            tool_catalog = ToolCatalog,
            json = JSON,
            port = 0,
            worker_source = read_file("src/http_worker.lua"),
            server_info = { name = "test", version = "0.1.0" },
        })
        luaunit.assertTrue(booster_server:start())
        wait_until(booster_server, function()
            return booster_server:get_status().state == "listening"
        end, 2)
        local booster_port = booster_server:get_status().port
        local _, _, first_payload = call_tool(booster_server, booster_port, 7600, "get_game_state")
        local first_complete = first_payload.result.structuredContent.state
        luaunit.assertFalse(first_payload.result.isError)
        luaunit.assertTrue(observe_count >= 3)
        luaunit.assertEquals(#first_complete.hand, 2)
        local _, _, repeat_payload = call_tool(booster_server, booster_port, 7601, "get_game_state")
        luaunit.assertEquals(
            repeat_payload.result.structuredContent.state.state_hash,
            first_complete.state_hash
        )
        booster_server:stop()
        booster_server = nil

        local function assert_booster_pending()
            local pending_pack, pending_pack_error = adapter:observe("fair")
            luaunit.assertNil(pending_pack)
            luaunit.assertNotNil(pending_pack_error)
            ---@cast pending_pack_error table
            luaunit.assertEquals(pending_pack_error.code, "DECISION_PENDING")
        end

        G.CONTROLLER.locks.use = true
        assert_booster_pending()
        G.CONTROLLER.locks.use = nil
        G.CONTROLLER.locks.frame = true
        assert_booster_pending()
        G.CONTROLLER.locks.frame = nil
        G.GAME.STOP_USE = 1
        assert_booster_pending()
        G.GAME.STOP_USE = 0
        G.TAROT_INTERRUPT = G.STATE
        assert_booster_pending()
        G.TAROT_INTERRUPT = nil
        local booster_pack = G.booster_pack
        G.booster_pack = nil
        assert_booster_pending()
        G.booster_pack = booster_pack
        local pack_cards = G.pack_cards
        G.pack_cards = nil
        assert_booster_pending()
        G.pack_cards = { cards = {} }
        assert_booster_pending()
        G.pack_cards = pack_cards

        hand_ace.edition = { type = "foil" }
        G.STATE = G.STATES.SPECTRAL_PACK
        G.pack_cards = { cards = { pack_aura } }
        pack_aura.area = G.pack_cards
        G.GAME.pack_choices = 1
        local aura = adapter:observe("fair")
        luaunit.assertNotNil(aura)
        ---@cast aura table
        luaunit.assertEquals(#aura.public_state.legal_actions, 2)
        luaunit.assertEquals(aura.public_state.legal_actions[1].tool, "choose_booster_item")
        luaunit.assertEquals(
            aura.public_state.legal_actions[1].target_refs.target_ids,
            { "card:1" }
        )

        hand_king.edition = { type = "holo" }
        local unavailable_aura = adapter:observe("fair")
        luaunit.assertNotNil(unavailable_aura)
        ---@cast unavailable_aura table
        luaunit.assertEquals(#unavailable_aura.public_state.legal_actions, 1)
        luaunit.assertEquals(unavailable_aura.public_state.legal_actions[1].tool, "skip_booster")
        hand_king.edition = nil
        hand_ace.edition = nil
        G.GAME.pack_choices = 2
        G.pack_cards = {
            cards = { pack_fool, pack_strength },
            config = { card_limit = 2 },
        }
        pack_fool.area = G.pack_cards
        pack_strength.area = G.pack_cards

        local categories = {
            { state = G.STATES.TAROT_PACK, category = "arcana" },
            { state = G.STATES.PLANET_PACK, category = "celestial" },
            { state = G.STATES.SPECTRAL_PACK, category = "spectral" },
            { state = G.STATES.STANDARD_PACK, category = "standard" },
            { state = G.STATES.BUFFOON_PACK, category = "buffoon" },
            {
                state = G.STATES.SMODS_BOOSTER_OPENED,
                category = "standard",
                opened = {
                    ability = { name = "Mega Standard Pack", set = "Booster" },
                    config = {
                        center = {
                            key = "p_standard_mega_2",
                            kind = "Standard",
                        },
                    },
                },
            },
        }
        for _, case in ipairs(categories) do
            G.STATE = case.state
            SMODS.OPENED_BOOSTER = case.opened
            local observation = adapter:observe("fair")
            luaunit.assertNotNil(observation)
            ---@cast observation table
            luaunit.assertEquals(observation.phase, "booster")
            luaunit.assertEquals(observation.public_state.booster.category, case.category)
            luaunit.assertEquals(observation.public_state.booster.choices_left, 2)
            luaunit.assertEquals(observation.public_state.booster_items[1].key, "c_fool")
            luaunit.assertEquals(observation.public_state.booster_items[1].name, "The Fool")
            luaunit.assertEquals(observation.public_state.booster_items[1].edition, {
                key = "e_negative",
                name = "Negative",
                description = "+1 consumable slot",
            })
            luaunit.assertNotNil(observation.public_state.booster_items[1].description)
            luaunit.assertEquals(
                observation.public_state.booster_items[2].description,
                "Increases rank of up to 2 selected cards by 1"
            )
            luaunit.assertNil(observation.public_state.booster_items[1].cost)
            luaunit.assertNil(observation.hidden_state)
        end

        G.STATE = G.STATES.TAROT_PACK
        local first = adapter:observe("fair")
        luaunit.assertNotNil(first)
        ---@cast first table
        local tools = {}
        for _, action in ipairs(first.public_state.legal_actions) do
            tools[#tools + 1] = action.tool
        end
        luaunit.assertEquals(tools[1], "choose_booster_item")
        luaunit.assertEquals(tools[#tools], "skip_booster")

        local choose, choose_error = adapter:execute({
            name = "choose_booster_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "booster_item:61" },
        })
        luaunit.assertNil(choose_error)
        luaunit.assertNotNil(choose)
        ---@cast choose table
        luaunit.assertNil(choose.events)
        luaunit.assertEquals(used[1].key, "c_fool")
        local choose_resolution, choose_capture_error =
            adapter:finish_resolution(choose.resolution_context)
        luaunit.assertNil(choose_capture_error)
        luaunit.assertNil(choose_resolution)

        local remaining = adapter:observe("fair")
        luaunit.assertNotNil(remaining)
        ---@cast remaining table
        luaunit.assertEquals(remaining.phase, "booster")
        luaunit.assertEquals(remaining.public_state.booster.choices_left, 1)
        luaunit.assertEquals(#remaining.public_state.booster_items, 1)
        luaunit.assertEquals(G.pack_cards.config.card_limit, 2)
        luaunit.assertEquals(remaining.public_state.booster_items[1].key, "c_strength")

        local targeted, targeted_error = adapter:execute({
            name = "choose_booster_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = {
                item_id = "booster_item:62",
                target_ids = { "card:2", "card:1" },
            },
        })
        luaunit.assertNil(targeted_error)
        luaunit.assertNotNil(targeted)
        ---@cast targeted table
        luaunit.assertNil(targeted.events)
        luaunit.assertEquals(used[2].targets, { "S_A", "H_K" })

        G.STATE = G.STATES.PLANET_PACK
        G.booster_pack = {}
        G.pack_cards = { cards = { pack_pluto } }
        pack_pluto.area = G.pack_cards
        G.GAME.pack_choices = 1
        G.GAME.hands["High Card"] = { level = 2, l_mult = 1, l_chips = 10 }
        local planet_observation = adapter:observe("fair")
        luaunit.assertNotNil(planet_observation)
        ---@cast planet_observation table
        luaunit.assertEquals(
            planet_observation.public_state.booster_items[1].description,
            "(lvl.2) Level up High Card +1 Mult and +10 chips"
        )
        local planet, planet_error = adapter:execute({
            name = "choose_booster_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "booster_item:63" },
        })
        luaunit.assertNil(planet_error)
        luaunit.assertNotNil(planet)
        ---@cast planet table
        luaunit.assertNil(planet.events)

        G.STATE = G.STATES.TAROT_PACK
        G.booster_pack = {}
        G.pack_cards = { cards = { pack_temperance } }
        pack_temperance.area = G.pack_cards
        G.GAME.pack_choices = 1
        G.jokers.cards = { { ability = { set = "Joker" }, sell_cost = 3 } }
        local temperance = adapter:observe("fair")
        luaunit.assertNotNil(temperance)
        ---@cast temperance table
        luaunit.assertEquals(
            temperance.public_state.booster_items[1].description,
            "Maximum 50, currently 3"
        )
        G.jokers.cards = {}

        G.STATE = G.STATES.STANDARD_PACK
        G.booster_pack = {}
        G.pack_cards = { cards = { pack_card } }
        pack_card.area = G.pack_cards
        G.GAME.pack_choices = 1
        local card, card_error = adapter:execute({
            name = "choose_booster_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "booster_item:64" },
        })
        luaunit.assertNil(card_error)
        luaunit.assertNotNil(card)
        ---@cast card table
        luaunit.assertNil(card.events)

        G.STATE = G.STATES.BUFFOON_PACK
        G.booster_pack = {}
        G.pack_cards = { cards = { pack_joker } }
        pack_joker.area = G.pack_cards
        G.GAME.pack_choices = 1
        for index = 1, 5 do
            local owned_joker = {
                sort_id = 70 + index,
                sell_cost = 1,
                ability = { set = "Joker", name = "Joker" },
                config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
                can_sell_card = function()
                    return true
                end,
            }
            owned_joker.area = G.jokers
            G.jokers.cards[index] = owned_joker
        end
        local full_buffoon = assert(adapter:observe("fair"))
        luaunit.assertEquals(#full_buffoon.public_state.jokers, 5)
        local full_buffoon_tools = {}
        local sell_action
        for _, action in ipairs(full_buffoon.public_state.legal_actions) do
            full_buffoon_tools[action.tool] = true
            if action.tool == "sell_owned_item" then
                sell_action = action
            end
        end
        luaunit.assertNil(full_buffoon_tools.choose_booster_item)
        luaunit.assertNotNil(sell_action)
        ---@cast sell_action table
        luaunit.assertTrue(full_buffoon_tools.skip_booster)
        local sold, sold_error = adapter:execute({
            name = "sell_owned_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = sell_action.target_refs.item_id[1] },
        })
        luaunit.assertNil(sold_error)
        luaunit.assertNotNil(sold)
        ---@cast sold table
        luaunit.assertEquals(sold.resolution_context.scope_stack[1].phase, "booster")
        luaunit.assertNil(adapter:finish_resolution(sold.resolution_context))
        local after_sale = assert(adapter:observe("fair"))
        luaunit.assertEquals(#after_sale.public_state.jokers, 4)
        luaunit.assertEquals(after_sale.public_state.legal_actions[1].tool, "choose_booster_item")
        local joker, joker_error = adapter:execute({
            name = "choose_booster_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "booster_item:65" },
        })
        luaunit.assertNil(joker_error)
        luaunit.assertNotNil(joker)
        ---@cast joker table
        luaunit.assertNil(joker.events)

        G.STATE = G.STATES.TAROT_PACK
        G.booster_pack = {}
        G.pack_cards = { cards = { pack_fool } }
        pack_fool.area = G.pack_cards
        G.GAME.pack_choices = 1
        local previous_use = G.FUNCS.use_card
        G.FUNCS.use_card = function() end
        local blocked, blocked_error = adapter:execute({
            name = "choose_booster_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "booster_item:61" },
        })
        G.FUNCS.use_card = previous_use
        luaunit.assertNil(blocked)
        luaunit.assertNotNil(blocked_error)
        ---@cast blocked_error table
        luaunit.assertEquals(blocked_error.code, "ACTION_NOT_ALLOWED")

        local skip, skip_error = adapter:execute({
            name = "skip_booster",
            expected_state_hash = "sha256:test",
            arguments = {},
        })
        luaunit.assertNil(skip_error)
        luaunit.assertNotNil(skip)
        ---@cast skip table
        luaunit.assertTrue(skipped)
        luaunit.assertNil(skip.events)
        local shop = adapter:observe("fair")
        luaunit.assertNotNil(shop)
        ---@cast shop table
        luaunit.assertEquals(shop.phase, "shop")

        local phase, phase_error = adapter:execute({
            name = "choose_booster_item",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { item_id = "booster_item:61" },
        })
        luaunit.assertNil(phase)
        luaunit.assertNotNil(phase_error)
        ---@cast phase_error table
        luaunit.assertEquals(phase_error.code, "INVALID_PHASE")
    end, debug.traceback)

    if booster_server then
        booster_server:stop()
    end
    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_terminal_states_are_recognized_and_resolved()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local red_deck = {
        key = "b_red",
        name = "Red Deck",
        set = "Back",
        config = { discards = 1 },
    }
    local white_stake = { key = "stake_white", name = "White Stake", order = 1 }
    local small_blind = { key = "bl_small", name = "Small Blind", dollars = 3, mult = 1 }
    local hook = { key = "bl_hook", name = "The Hook", dollars = 5, mult = 2 }

    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            stake_from_index = function()
                return "stake_white"
            end,
            stake_is_unlocked = function()
                return true
            end,
        }
        local cash_out_called = false
        local overlay_ids = { you_win_UI = true, from_game_won = true }
        _G.G = {
            VERSION = "1.0.1o-FULL",
            STAGES = { MAIN_MENU = 1, RUN = 2 },
            STATES = { SHOP = 5, GAME_OVER = 4, ROUND_EVAL = 8, MENU = 11 },
            STAGE = 2,
            STATE = 8,
            STATE_COMPLETE = true,
            CONTROLLER = { locks = {}, lock_input = false },
            SETTINGS = { paused = true },
            P_BLINDS = { bl_small = small_blind, bl_hook = hook },
            P_STAKES = { stake_white = white_stake },
            P_CENTER_POOLS = { Back = { red_deck }, Stake = { white_stake } },
            P_CENTERS = { b_red = red_deck },
            P_TAGS = {},
            OVERLAY_MENU = {
                get_UIE_by_ID = function(_, id)
                    if overlay_ids[id] then
                        return { config = { id = id } }
                    end
                end,
            },
            round_eval = {
                get_UIE_by_ID = function(_, key)
                    if key == "cash_out_button" then
                        return { config = { button = "cash_out" } }
                    end
                end,
            },
            FUNCS = {
                cash_out = function()
                    cash_out_called = true
                end,
                exit_overlay_menu = function()
                    G.OVERLAY_MENU = nil
                    G.SETTINGS.paused = false
                    G.GAME.current_round.round_text = "Endless Round "
                end,
                go_to_menu = function()
                    G.STAGE = G.STAGES.MAIN_MENU
                    G.STATE = G.STATES.MENU
                    G.OVERLAY_MENU = nil
                    G.SETTINGS.paused = false
                    G.MAIN_MENU_UI = {}
                    G.SETTINGS.current_setup = nil
                    G.GAME = {}
                end,
            },
            GAME = {
                selected_back = { effect = { center = red_deck } },
                stake = 1,
                dollars = 20,
                chips = 0,
                skips = 0,
                seeded = true,
                won = true,
                win_notified = true,
                win_ante = 8,
                round = 24,
                tags = {},
                used_vouchers = {},
                modifiers = {},
                starting_params = { ante_scaling = 1 },
                current_round = { dollars = 5, round_text = "Ante 8" },
                blind = { config = { blind = hook } },
                hand_usage = { Flush = { count = 6, order = "Flush" } },
                round_scores = {
                    hand = { amt = 12000 },
                    cards_played = { amt = 80 },
                    cards_discarded = { amt = 20 },
                    cards_purchased = { amt = 12 },
                    times_rerolled = { amt = 3 },
                    new_collection = { amt = 5 },
                },
                round_resets = { ante = 8 },
                pseudorandom = { seed = "MCPTEST" },
            },
        }

        local adapter = ProductionBalatroAdapter.new()
        local victory, victory_error = adapter:observe("fair")
        luaunit.assertNil(victory_error)
        luaunit.assertNotNil(victory)
        ---@cast victory table
        luaunit.assertEquals(victory.phase, "victory")
        luaunit.assertTrue(victory.public_state.won)
        luaunit.assertEquals(victory.public_state.best_hand, 12000)
        luaunit.assertEquals(victory.public_state.most_played_hand, "Flush")
        luaunit.assertEquals(victory.public_state.legal_actions[1].tool, "continue_endless")
        luaunit.assertEquals(victory.public_state.legal_actions[2].tool, "return_to_menu")
        luaunit.assertFalse(cash_out_called)

        local continued, continue_error = adapter:execute({
            name = "continue_endless",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = {},
        })
        luaunit.assertNil(continue_error)
        luaunit.assertNotNil(continued)
        ---@cast continued table
        luaunit.assertTrue(continued.pending)
        luaunit.assertNil(continued.events)
        luaunit.assertNil(G.OVERLAY_MENU)

        local payout, payout_error = adapter:observe("fair")
        luaunit.assertNil(payout)
        luaunit.assertNotNil(payout_error)
        ---@cast payout_error table
        luaunit.assertEquals(payout_error.code, "DECISION_PENDING")
        luaunit.assertTrue(cash_out_called)

        G.STATE = G.STATES.SHOP
        G.shop = {}
        G.GAME.dollars = 25
        local endless, endless_error = adapter:observe("fair")
        luaunit.assertNil(endless_error)
        luaunit.assertNotNil(endless)
        ---@cast endless table
        luaunit.assertEquals(endless.phase, "shop")
        luaunit.assertTrue(endless.public_state.won)

        overlay_ids = {}
        G.STAGE = G.STAGES.RUN
        G.STATE = G.STATES.GAME_OVER
        G.STATE_COMPLETE = true
        G.SETTINGS.paused = true
        G.shop = nil
        G.OVERLAY_MENU = {
            get_UIE_by_ID = function(_, id)
                if overlay_ids[id] then
                    return { config = { id = id } }
                end
            end,
        }
        G.GAME.won = false
        local human_overlay, human_overlay_error = adapter:observe("fair")
        luaunit.assertNil(human_overlay)
        luaunit.assertNotNil(human_overlay_error)
        ---@cast human_overlay_error table
        luaunit.assertEquals(human_overlay_error.code, "GAME_BLOCKED")

        overlay_ids = { from_game_over = true }
        G.GAME.round_resets.ante = 2
        G.GAME.round = 5
        G.GAME.blind = { config = { blind = small_blind } }
        local defeat, defeat_error = adapter:observe("fair")
        luaunit.assertNil(defeat_error)
        luaunit.assertNotNil(defeat)
        ---@cast defeat table
        luaunit.assertEquals(defeat.phase, "defeat")
        luaunit.assertEquals(defeat.public_state.defeated_by.key, "bl_small")
        luaunit.assertEquals(#defeat.public_state.legal_actions, 1)
        luaunit.assertEquals(defeat.public_state.legal_actions[1].tool, "return_to_menu")

        local blocked, blocked_error = adapter:execute({
            name = "continue_endless",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = {},
        })
        luaunit.assertNil(blocked)
        luaunit.assertNotNil(blocked_error)
        ---@cast blocked_error table
        luaunit.assertEquals(blocked_error.code, "INVALID_PHASE")

        local returned, return_error = adapter:execute({
            name = "return_to_menu",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = {},
        })
        luaunit.assertNil(return_error)
        luaunit.assertNotNil(returned)
        ---@cast returned table
        luaunit.assertTrue(returned.pending)
        luaunit.assertNil(returned.events)
        luaunit.assertEquals(G.STATE, G.STATES.MENU)

        local menu, menu_error = adapter:observe("fair")
        luaunit.assertNil(menu_error)
        luaunit.assertNotNil(menu)
        ---@cast menu table
        luaunit.assertEquals(menu.phase, "main_menu")

        local from_menu, from_menu_error = adapter:execute({
            name = "return_to_menu",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = {},
        })
        luaunit.assertNil(from_menu)
        luaunit.assertNotNil(from_menu_error)
        ---@cast from_menu_error table
        luaunit.assertEquals(from_menu_error.code, "INVALID_PHASE")

        cash_out_called = false
        G.STAGE = G.STAGES.RUN
        G.STATE = G.STATES.ROUND_EVAL
        G.MAIN_MENU_UI = nil
        G.OVERLAY_MENU = nil
        G.SETTINGS.paused = false
        G.GAME = {
            won = true,
            current_round = { dollars = 5, round_text = "Ante 8" },
        }
        local waiting, waiting_error = adapter:observe("fair")
        luaunit.assertNil(waiting)
        luaunit.assertNotNil(waiting_error)
        ---@cast waiting_error table
        luaunit.assertEquals(waiting_error.code, "DECISION_PENDING")
        luaunit.assertEquals(waiting_error.message, "Balatro is opening the victory screen")
        luaunit.assertFalse(cash_out_called)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_runtime_hardening_versions_races_and_overlays()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local ace = {
        sort_id = 1,
        config = { card_key = "S_A", center = { key = "c_base", set = "Default" } },
        base = { suit = "Spades", value = "Ace", nominal = 11 },
        ability = { effect = "Base", set = "Default" },
        get_chip_bonus = function()
            return 11
        end,
    }
    local two = {
        sort_id = 2,
        config = { card_key = "C_2", center = { key = "c_base", set = "Default" } },
        base = { suit = "Clubs", value = "2", nominal = 2 },
        ability = { effect = "Base", set = "Default" },
        get_chip_bonus = function()
            return 2
        end,
    }
    local king = {
        sort_id = 3,
        config = { card_key = "H_K", center = { key = "c_base", set = "Default" } },
        base = { suit = "Hearts", value = "King", nominal = 10 },
        ability = { effect = "Base", set = "Default" },
        get_chip_bonus = function()
            return 10
        end,
    }
    local red_deck = {
        key = "b_red",
        name = "Red Deck",
        set = "Back",
        config = { discards = 1 },
        unlocked = true,
        discovered = true,
    }
    local white_stake = { key = "stake_white", name = "White Stake", order = 1 }
    local small_blind = { key = "bl_small", name = "Small Blind", dollars = 3, mult = 1 }
    local started_with

    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {
                {
                    id = "balatro-mcp",
                    name = "Balatro MCP",
                    version = "0.1.0",
                    can_load = true,
                },
            },
            stake_from_index = function()
                return "stake_white"
            end,
            stake_is_unlocked = function()
                return true
            end,
        }
        _G.G = {
            VERSION = "1.0.0",
            STAGES = { MAIN_MENU = 1, RUN = 2 },
            STATES = { MENU = 11, SELECTING_HAND = 1 },
            STAGE = 1,
            STATE = 11,
            STATE_COMPLETE = true,
            CONTROLLER = { locks = {}, lock_input = false },
            SETTINGS = { current_setup = "New Run", profile = 1, paused = false },
            MAIN_MENU_UI = {},
            GAME = {},
            P_CENTER_POOLS = { Back = { red_deck }, Stake = { white_stake } },
            P_CENTERS = { b_red = red_deck },
            P_STAKES = { stake_white = white_stake },
            P_CARDS = {
                S_A = { name = "Ace of Spades", suit = "Spades", value = "Ace" },
                C_2 = { name = "2 of Clubs", suit = "Clubs", value = "2" },
                H_K = { name = "King of Hearts", suit = "Hearts", value = "King" },
            },
            P_BLINDS = { bl_small = small_blind },
            P_TAGS = {},
            FUNCS = {
                start_run = function(_, arguments)
                    started_with = arguments
                end,
            },
        }

        local adapter = ProductionBalatroAdapter.new()
        local old, old_error = adapter:observe("fair")
        luaunit.assertNil(old_error)
        luaunit.assertNotNil(old)
        ---@cast old table
        luaunit.assertEquals(old.public_state.compatibility.versions, "unsupported")
        luaunit.assertStrContains(old.public_state.compatibility.diagnostic, "1.0.0")
        local blocked, blocked_error = adapter:execute({
            name = "start_run",
            expected_state_hash = "sha256:test",
            arguments = { deck_key = "b_red", stake = 1 },
            targets = {},
        })
        luaunit.assertNil(blocked)
        luaunit.assertNotNil(blocked_error)
        ---@cast blocked_error table
        luaunit.assertEquals(blocked_error.code, "INCOMPATIBLE_VERSION")
        luaunit.assertNil(started_with)

        G.VERSION = "1.0.1z-FULL"
        SMODS.version = "1.0.0~BETA-9999z"
        SMODS.mod_list[2] = {
            id = "MoreJokers",
            name = "More Jokers",
            version = "1.2.0",
            can_load = true,
        }
        local extra, extra_error = adapter:observe("fair")
        luaunit.assertNil(extra_error)
        luaunit.assertNotNil(extra)
        ---@cast extra table
        luaunit.assertEquals(extra.public_state.compatibility.status, "unsupported")
        luaunit.assertEquals(extra.public_state.compatibility.content_mods, "unsupported")
        luaunit.assertEquals(extra.public_state.compatibility.versions, "supported")
        luaunit.assertEquals(extra.public_state.active_mods[1].id, "MoreJokers")
        luaunit.assertEquals(extra.public_state.active_mods[2].id, "balatro-mcp")
        local started, start_error = adapter:execute({
            name = "start_run",
            expected_state_hash = "sha256:test",
            arguments = { deck_key = "b_red", stake = 1 },
            targets = {},
        })
        luaunit.assertNil(start_error)
        luaunit.assertNotNil(started)
        luaunit.assertEquals(started_with.deck_choice.name, "Red Deck")

        SMODS.mod_list[2] = nil
        G.STAGE = G.STAGES.RUN
        G.STATE = G.STATES.SELECTING_HAND
        G.MAIN_MENU_UI = nil
        G.hand = { cards = { two, ace, king } }
        G.deck = { cards = {} }
        G.GAME = {
            selected_back = { effect = { center = red_deck } },
            stake = 1,
            dollars = 4,
            chips = 0,
            skips = 0,
            seeded = true,
            tags = {},
            used_vouchers = {},
            modifiers = {},
            starting_params = { ante_scaling = 1 },
            current_round = { hands_left = 4, discards_left = 3 },
            blind = { config = { blind = small_blind } },
            blind_on_deck = "Small",
            hands = {
                ["High Card"] = {
                    visible = true,
                    level = 1,
                    chips = 5,
                    mult = 1,
                    played = 0,
                },
            },
            round_resets = {
                ante = 1,
                blind_ante = 1,
                blind_choices = { Small = "bl_small" },
                blind_states = { Small = "Current" },
                blind_tags = {},
            },
            pseudorandom = { seed = "MCPTEST" },
        }

        local first, first_error = adapter:observe("fair")
        luaunit.assertNil(first_error)
        luaunit.assertNotNil(first)
        ---@cast first table
        luaunit.assertEquals(first.phase, "hand_play")
        local first_sequence = first.decision_sequence

        G.hand.cards = { ace, king, two }
        local sorted, sorted_error = adapter:observe("fair")
        luaunit.assertNil(sorted_error)
        luaunit.assertNotNil(sorted)
        ---@cast sorted table
        luaunit.assertEquals(sorted.decision_sequence, first_sequence)

        ace.ability_UIBox_table = { name = "Ace of Spades" }
        G.hand.highlighted = { ace }
        local inspected, inspected_error = adapter:observe("fair")
        luaunit.assertNil(inspected_error)
        luaunit.assertNotNil(inspected)
        ---@cast inspected table
        luaunit.assertEquals(inspected.decision_sequence, first_sequence)

        G.hand.cards = { king, two, ace }
        local custom, custom_error = adapter:observe("fair")
        luaunit.assertNil(custom_error)
        luaunit.assertNotNil(custom)
        ---@cast custom table
        luaunit.assertTrue(custom.decision_sequence > first_sequence)

        G.GAME.dollars = 12
        local bought, bought_error = adapter:observe("fair")
        luaunit.assertNil(bought_error)
        luaunit.assertNotNil(bought)
        ---@cast bought table
        luaunit.assertEquals(bought.public_state.money, 12)
        luaunit.assertTrue(bought.decision_sequence > custom.decision_sequence)

        local overlay = {
            get_UIE_by_ID = function(_, id)
                if id == "options" or id == "your_collection" then
                    return { config = { id = id } }
                end
            end,
        }
        G.OVERLAY_MENU = overlay
        G.SETTINGS.paused = true
        local blocked_overlay, overlay_error = adapter:observe("fair")
        luaunit.assertNil(blocked_overlay)
        luaunit.assertNotNil(overlay_error)
        ---@cast overlay_error table
        luaunit.assertEquals(overlay_error.code, "GAME_BLOCKED")
        luaunit.assertIs(G.OVERLAY_MENU, overlay)
        luaunit.assertTrue(G.SETTINGS.paused)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_encyclopedia_filters_and_interpolates_prototype_defaults()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local joker = {
        key = "j_joker",
        set = "Joker",
        name = "Joker",
        unlocked = true,
        discovered = true,
        order = 1,
        config = { mult = 4 },
    }
    local blueprint = {
        key = "j_blueprint",
        set = "Joker",
        name = "Blueprint",
        unlocked = true,
        discovered = false,
        order = 2,
        config = {},
    }
    local green = {
        key = "j_green_joker",
        set = "Joker",
        name = "Green Joker",
        unlocked = true,
        discovered = true,
        order = 3,
        config = { extra = { hand_add = 1, discard_sub = 1 } },
    }
    local superposition = {
        key = "j_superposition",
        set = "Joker",
        name = "Superposition",
        unlocked = true,
        discovered = true,
        order = 4,
        config = {},
    }
    local stencil = {
        key = "j_stencil",
        set = "Joker",
        name = "Joker Stencil",
        unlocked = true,
        discovered = true,
        order = 4.1,
        config = {},
    }
    local ceremonial = {
        key = "j_ceremonial",
        set = "Joker",
        name = "Ceremonial Dagger",
        unlocked = true,
        discovered = true,
        order = 4.2,
        config = { mult = 0 },
    }
    local steel = {
        key = "j_steel_joker",
        set = "Joker",
        name = "Steel Joker",
        unlocked = true,
        discovered = true,
        order = 4.3,
        config = { extra = 0.2 },
    }
    local blue = {
        key = "j_blue_joker",
        set = "Joker",
        name = "Blue Joker",
        unlocked = true,
        discovered = true,
        order = 4.4,
        config = { extra = 2 },
    }
    local hallucination = {
        key = "j_hallucination",
        set = "Joker",
        name = "Hallucination",
        unlocked = true,
        discovered = true,
        order = 4.5,
        config = { extra = 2 },
    }
    local locked = {
        key = "j_locked",
        set = "Joker",
        name = "Locked Joker",
        unlocked = false,
        discovered = false,
        order = 5,
        config = { mult = 8 },
    }
    local caino = {
        key = "j_caino",
        set = "Joker",
        name = "Caino",
        unlocked = false,
        discovered = false,
        hidden = true,
        rarity = 4,
        order = 6,
        config = { extra = 1 },
    }
    local modded = {
        key = "j_mod",
        set = "Joker",
        name = "Mod Joker",
        unlocked = true,
        discovered = true,
        mod = { id = "other" },
        order = 7,
        config = { mult = 9 },
    }
    local omitted = {
        key = "j_omit",
        set = "Joker",
        omit = true,
        unlocked = true,
        discovered = true,
        order = 8,
        config = {},
    }
    local demo = {
        key = "j_demo",
        set = "Joker",
        demo = true,
        unlocked = true,
        discovered = true,
        order = 9,
        config = {},
    }
    local wip = {
        key = "j_wip",
        set = "Joker",
        wip = true,
        unlocked = true,
        discovered = true,
        order = 10,
        config = {},
    }
    local red_deck = {
        key = "b_red",
        set = "Back",
        name = "Red Deck",
        unlocked = true,
        discovered = true,
        order = 1,
        config = { discards = 1 },
    }
    local locked_deck = {
        key = "b_blue",
        set = "Back",
        name = "Blue Deck",
        unlocked = false,
        discovered = false,
        order = 2,
        config = { hands = 1 },
    }
    local white_stake = { key = "stake_white", set = "Stake", name = "White Stake", order = 1 }
    local gold_stake = { key = "stake_gold", set = "Stake", name = "Gold Stake", order = 8 }
    local voucher = {
        key = "v_grabber",
        set = "Voucher",
        name = "Grabber",
        unlocked = true,
        discovered = true,
        order = 1,
        config = { extra = 1 },
    }
    local tarot = {
        key = "c_hermit",
        set = "Tarot",
        name = "The Hermit",
        unlocked = true,
        discovered = true,
        order = 1,
        config = { extra = 20 },
    }
    local planet = {
        key = "c_jupiter",
        set = "Planet",
        name = "Jupiter",
        unlocked = true,
        discovered = true,
        order = 1,
        config = { hand_type = "Flush" },
    }
    local spectral = {
        key = "c_familiar",
        set = "Spectral",
        name = "Familiar",
        unlocked = true,
        discovered = true,
        order = 1,
        config = { extra = 3 },
    }
    local soul = {
        key = "c_soul",
        set = "Spectral",
        name = "The Soul",
        hidden = true,
        discovered = false,
        order = 2,
        config = {},
    }
    local enhanced = {
        key = "m_bonus",
        set = "Enhanced",
        name = "Bonus Card",
        effect = "Bonus Card",
        discovered = true,
        order = 1,
        config = { bonus = 30 },
    }
    local seal = { key = "Red", set = "Seal", discovered = true, order = 1 }
    local edition = {
        key = "e_foil",
        set = "Edition",
        name = "Foil",
        discovered = true,
        order = 1,
        config = { extra = 50 },
    }
    local booster = {
        key = "p_arcana_normal_1",
        set = "Booster",
        name = "Arcana Pack",
        discovered = true,
        order = 1,
        config = { choose = 1, extra = 3 },
    }
    local tag = {
        key = "tag_investment",
        set = "Tag",
        name = "Investment Tag",
        discovered = true,
        order = 1,
        config = { dollars = 25 },
    }
    local small_blind = {
        key = "bl_small",
        name = "Small Blind",
        discovered = true,
        order = 1,
    }

    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            stake_is_unlocked = function(stake_key, deck_key)
                return stake_key == "stake_white" and deck_key == "b_red"
            end,
        }
        _G.G = {
            VERSION = "1.0.1o-FULL",
            GAME = {
                dollars = 99,
                probabilities = { normal = 4 },
                hands = {
                    Flush = { level = 7, l_mult = 99, l_chips = 99, chips = 200, mult = 20 },
                },
                consumeable_usage_total = { tarot = 12 },
            },
            jokers = { cards = { { ability = { set = "Joker", extra = 99, mult = 99 } } } },
            P_CENTER_POOLS = {
                Joker = {
                    joker,
                    blueprint,
                    green,
                    superposition,
                    stencil,
                    ceremonial,
                    steel,
                    blue,
                    hallucination,
                    locked,
                    caino,
                    modded,
                    omitted,
                    demo,
                    wip,
                },
                Back = { red_deck, locked_deck },
                Stake = { white_stake, gold_stake },
                Voucher = { voucher },
                Tarot = { tarot },
                Planet = { planet },
                Spectral = { spectral, soul },
                Enhanced = { enhanced },
                Seal = { seal },
                Edition = { edition },
                Booster = { booster },
                Tag = { tag },
            },
            P_BLINDS = { bl_small = small_blind },
            P_TAGS = { tag_investment = tag },
            P_SEALS = { Red = seal },
        }

        local adapter = ProductionBalatroAdapter.new()
        adapter.english = {
            descriptions = {
                Joker = {
                    j_joker = { name = "Joker", text = { "+#1# Mult" } },
                    j_blueprint = {
                        name = "Blueprint",
                        text = { "Copies ability of Joker to the right" },
                    },
                    j_green_joker = {
                        name = "Green Joker",
                        text = {
                            "+#1# Mult per hand played",
                            "-#2# Mult per discard",
                            "(Currently +#3# Mult)",
                        },
                    },
                    j_superposition = {
                        name = "Superposition",
                        text = {
                            "Create a Tarot card if poker hand contains an Ace and a Straight",
                        },
                    },
                    j_stencil = {
                        name = "Joker Stencil",
                        text = { "X1 Mult for each empty Joker slot (Currently X#1#)" },
                    },
                    j_ceremonial = {
                        name = "Ceremonial Dagger",
                        text = { "Destroy Joker to the right (Currently +#1# Mult)" },
                    },
                    j_steel_joker = {
                        name = "Steel Joker",
                        text = { "Gives X#1# Mult for each Steel Card (Currently X#2# Mult)" },
                    },
                    j_blue_joker = {
                        name = "Blue Joker",
                        text = { "+#1# Chips for each remaining card (Currently +#2# Chips)" },
                    },
                    j_hallucination = {
                        name = "Hallucination",
                        text = {
                            "#1# in #2# chance to create a Tarot card when any Booster Pack is opened",
                        },
                    },
                    j_locked = { name = "Locked Joker", text = { "+#1# Mult" } },
                    j_caino = {
                        name = "Caino",
                        text = { "This Joker gains X#1# Mult when a face card is destroyed" },
                    },
                },
                Back = {
                    b_red = { name = "Red Deck", text = { "+#1# discard every round" } },
                    b_blue = { name = "Blue Deck", text = { "+#1# hand every round" } },
                },
                Stake = {
                    stake_white = { name = "White Stake", text = { "Base Difficulty" } },
                    stake_gold = { name = "Gold Stake", text = { "Rentals appear in shop" } },
                },
                Voucher = {
                    v_grabber = {
                        name = "Grabber",
                        text = { "Permanently gain +#1# hand per round" },
                    },
                },
                Tarot = {
                    c_hermit = { name = "The Hermit", text = { "Doubles money, up to $#1#" } },
                },
                Planet = {
                    c_jupiter = {
                        name = "Jupiter",
                        text = { "Level up #2#", "+#3# Mult and +#4# chips" },
                    },
                },
                Spectral = {
                    c_familiar = {
                        name = "Familiar",
                        text = { "Destroy 1 card, add #1# random face cards" },
                    },
                    c_soul = { name = "The Soul", text = { "Creates a Legendary Joker" } },
                },
                Enhanced = {
                    m_bonus = { name = "Bonus Card", text = { "+#1# extra chips" } },
                },
                Other = {
                    red_seal = { name = "Red Seal", text = { "Retrigger this card 1 time" } },
                    p_arcana_normal = {
                        name = "Arcana Pack",
                        text = { "Choose #1# of up to #2# Tarot cards" },
                    },
                },
                Edition = {
                    e_foil = { name = "Foil", text = { "+#1# Chips" } },
                },
                Tag = {
                    tag_investment = {
                        name = "Investment Tag",
                        text = { "Gain $#1# after defeating Blind" },
                    },
                },
                Blind = {
                    bl_small = { name = "Small Blind", text = { "Score at least Base" } },
                },
            },
            misc = {
                poker_hands = { Flush = "Flush" },
            },
        }

        local fair, fair_error = adapter:encyclopedia("fair")
        local omniscient, omniscient_error = adapter:encyclopedia("omniscient")
        luaunit.assertNil(fair_error)
        luaunit.assertNil(omniscient_error)
        ---@cast fair table
        ---@cast omniscient table

        local function by_key(entries)
            local found = {}
            for _, entry in ipairs(entries) do
                found[entry.key] = entry
            end
            return found
        end
        local fair_by_key = by_key(fair.entries)
        local omniscient_by_key = by_key(omniscient.entries)
        local sets = {}
        for _, entry in ipairs(omniscient.entries) do
            sets[entry.set] = true
            luaunit.assertNotEquals(entry.set, "PokerHand")
            luaunit.assertNil((entry.description or ""):match("#%d+#"))
        end

        luaunit.assertEquals(fair.visibility, "fair")
        luaunit.assertEquals(fair_by_key.j_joker, {
            key = "j_joker",
            set = "Joker",
            name = "Joker",
            description = "+4 Mult",
        })
        luaunit.assertEquals(fair_by_key.j_blueprint, { key = "j_blueprint", set = "Joker" })
        luaunit.assertEquals(
            fair_by_key.j_green_joker.description,
            "+1 Mult per hand played -1 Mult per discard (Currently +0 Mult)"
        )
        luaunit.assertEquals(
            fair_by_key.j_superposition.description,
            "Create a Tarot card if poker hand contains an Ace and a Straight"
        )
        luaunit.assertEquals(
            fair_by_key.j_stencil.description,
            "X1 Mult for each empty Joker slot (Currently X1)"
        )
        luaunit.assertEquals(
            fair_by_key.j_ceremonial.description,
            "Destroy Joker to the right (Currently +0 Mult)"
        )
        luaunit.assertEquals(
            fair_by_key.j_steel_joker.description,
            "Gives X0.2 Mult for each Steel Card (Currently X1 Mult)"
        )
        luaunit.assertEquals(
            fair_by_key.j_blue_joker.description,
            "+2 Chips for each remaining card (Currently +104 Chips)"
        )
        luaunit.assertEquals(
            fair_by_key.j_hallucination.description,
            "1 in 2 chance to create a Tarot card when any Booster Pack is opened"
        )
        luaunit.assertNil(fair_by_key.j_locked)
        luaunit.assertNil(fair_by_key.j_caino)
        luaunit.assertNil(fair_by_key.c_soul)
        luaunit.assertNil(fair_by_key.j_mod)
        luaunit.assertNil(fair_by_key.j_omit)
        luaunit.assertNil(fair_by_key.j_demo)
        luaunit.assertNil(fair_by_key.j_wip)
        luaunit.assertNil(fair_by_key.b_blue)
        luaunit.assertEquals(fair_by_key.stake_white.name, "White Stake")
        luaunit.assertNil(fair_by_key.stake_gold)
        luaunit.assertEquals(
            fair_by_key.v_grabber.description,
            "Permanently gain +1 hand per round"
        )
        luaunit.assertEquals(fair_by_key.c_hermit.description, "Doubles money, up to $20")
        luaunit.assertEquals(
            fair_by_key.c_jupiter.description,
            "Level up Flush +2 Mult and +15 chips"
        )
        luaunit.assertEquals(
            fair_by_key.c_familiar.description,
            "Destroy 1 card, add 3 random face cards"
        )
        luaunit.assertEquals(fair_by_key.m_bonus.description, "+30 extra chips")
        luaunit.assertEquals(fair_by_key.red_seal.name, "Red Seal")
        luaunit.assertEquals(fair_by_key.e_foil.description, "+50 Chips")
        luaunit.assertEquals(
            fair_by_key.p_arcana_normal_1.description,
            "Choose 1 of up to 3 Tarot cards"
        )
        luaunit.assertEquals(
            fair_by_key.tag_investment.description,
            "Gain $25 after defeating Blind"
        )
        luaunit.assertEquals(fair_by_key.bl_small.name, "Small Blind")
        luaunit.assertEquals(fair.entries[1].set, "Joker")

        luaunit.assertEquals(omniscient.visibility, "omniscient")
        luaunit.assertEquals(omniscient_by_key.j_blueprint.name, "Blueprint")
        luaunit.assertEquals(omniscient_by_key.j_locked.name, "Locked Joker")
        luaunit.assertEquals(omniscient_by_key.j_locked.description, "+8 Mult")
        luaunit.assertEquals(omniscient_by_key.j_caino.name, "Caino")
        luaunit.assertEquals(
            omniscient_by_key.j_caino.description,
            "This Joker gains X1 Mult when a face card is destroyed"
        )
        luaunit.assertEquals(omniscient_by_key.c_soul.name, "The Soul")
        luaunit.assertEquals(omniscient_by_key.stake_gold.name, "Gold Stake")
        luaunit.assertEquals(omniscient_by_key.b_blue.name, "Blue Deck")
        luaunit.assertNil(omniscient_by_key.j_mod)
        for _, set_name in ipairs({
            "Joker",
            "Back",
            "Stake",
            "Voucher",
            "Tarot",
            "Planet",
            "Spectral",
            "Enhanced",
            "Seal",
            "Edition",
            "Booster",
            "Tag",
            "Blind",
        }) do
            luaunit.assertTrue(sets[set_name])
        end
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

local function test_get_nominal(card, mod)
    local mult = 1
    if mod == "suit" then
        mult = 1000
    end
    if card.ability and card.ability.effect == "Stone Card" then
        mult = -1000
    end
    local base = card.base or {}
    return (base.nominal or 0)
        + (base.suit_nominal or 0) * mult
        + (base.suit_nominal_original or 0) * 0.0001 * mult
        + (base.face_nominal or 0)
        + 0.000001 * (card.unique_val or 0)
end

local function test_playing_card(opts)
    local card = {
        sort_id = opts.sort_id,
        facing = opts.facing or "front",
        config = { card_key = opts.key, center = { key = "c_base", set = "Default" } },
        base = {
            suit = opts.suit,
            value = opts.rank,
            nominal = opts.nominal,
            suit_nominal = opts.suit_nominal,
            suit_nominal_original = opts.suit_nominal_original,
            face_nominal = opts.face_nominal or 0,
        },
        ability = { effect = "Base", set = "Default" },
        unique_val = opts.unique_val or opts.sort_id,
        debuff = false,
        get_chip_bonus = function()
            return opts.nominal
        end,
        get_nominal = test_get_nominal,
    }
    return card
end

local function selecting_hand_globals(hand_cards, joker_cards)
    local red_deck = { key = "b_red", name = "Red Deck", set = "Back", config = { discards = 1 } }
    local white_stake = { key = "stake_white", name = "White Stake", order = 1 }
    local small_blind = { key = "bl_small", name = "Small Blind", dollars = 3, mult = 1 }
    local p_cards = {}
    for _, card in ipairs(hand_cards or {}) do
        local key = card.config and card.config.card_key
        if key then
            p_cards[key] = {
                name = key,
                suit = card.base and card.base.suit,
                value = card.base and card.base.value,
            }
        end
    end
    _G.SMODS = {
        version = "1.0.0~BETA-2014b",
        mod_list = {},
        stake_from_index = function()
            return "stake_white"
        end,
    }
    _G.G = {
        VERSION = "1.0.1o-FULL",
        STAGES = { MAIN_MENU = 1, RUN = 2 },
        STATES = { SELECTING_HAND = 1, SHOP = 5, BLIND_SELECT = 7 },
        STAGE = 2,
        STATE = 1,
        STATE_COMPLETE = true,
        CONTROLLER = { locks = {}, lock_input = false },
        SETTINGS = { paused = false, tutorial_complete = true },
        P_CARDS = p_cards,
        P_BLINDS = { bl_small = small_blind },
        P_STAKES = { stake_white = white_stake },
        P_CENTERS = {},
        P_TAGS = {},
        hand = {
            cards = hand_cards or {},
            set_ranks = function(self)
                for index, card in ipairs(self.cards) do
                    card.rank = index
                end
            end,
            align_cards = function(self)
                table.sort(self.cards, function(left, right)
                    return (left.T and left.T.x or 0) < (right.T and right.T.x or 0)
                end)
            end,
        },
        jokers = {
            cards = joker_cards or {},
            config = { card_limit = 5, type = "joker" },
            set_ranks = function(self)
                for index, card in ipairs(self.cards) do
                    card.rank = index
                end
            end,
            align_cards = function(self)
                table.sort(self.cards, function(left, right)
                    return (left.T and left.T.x or 0) < (right.T and right.T.x or 0)
                end)
            end,
        },
        consumeables = { cards = {}, config = { card_limit = 2 } },
        deck = { cards = {} },
        GAME = {
            selected_back = { effect = { center = red_deck } },
            stake = 1,
            dollars = 6,
            chips = 0,
            skips = 0,
            seeded = true,
            tags = {},
            used_vouchers = {},
            modifiers = {},
            starting_params = { ante_scaling = 1 },
            current_round = { hands_left = 4, discards_left = 3 },
            blind = { config = { blind = small_blind } },
            blind_on_deck = "Small",
            hands = {
                ["High Card"] = { visible = true, level = 1, chips = 5, mult = 1, played = 0 },
            },
            round_resets = {
                ante = 1,
                blind_ante = 1,
                blind_choices = { Small = "bl_small" },
                blind_states = { Small = "Current" },
                blind_tags = {},
            },
            pseudorandom = { seed = "MCPTEST" },
        },
    }
    for _, card in ipairs(joker_cards or {}) do
        card.area = G.jokers
    end
end

local function install_smods_calculate_fixture()
    _G.hand_chips = 5
    _G.mult = 1
    SMODS.calculation_keys = {
        "chips",
        "h_chips",
        "chip_mod",
        "mult",
        "h_mult",
        "mult_mod",
        "x_mult",
        "Xmult",
        "xmult",
        "x_mult_mod",
        "Xmult_mod",
        "p_dollars",
        "dollars",
        "h_dollars",
        "message",
        "extra",
        "remove",
        "func",
    }
    SMODS.context_stack = {}
    rawset(SMODS, "calculate_individual_effect", function(_effect, _scored_card, key, amount)
        if key == "chips" or key == "h_chips" or key == "chip_mod" then
            _G.hand_chips = _G.hand_chips + amount
        elseif key == "mult" or key == "h_mult" or key == "mult_mod" then
            _G.mult = _G.mult + amount
        elseif
            key == "x_mult"
            or key == "Xmult"
            or key == "xmult"
            or key == "x_mult_mod"
            or key == "Xmult_mod"
        then
            _G.mult = _G.mult * amount
        elseif key == "dollars" or key == "p_dollars" or key == "h_dollars" then
            G.GAME.dollars = G.GAME.dollars + amount
        elseif key == "func" then
            amount()
        end
        return true
    end)
    rawset(SMODS, "calculate_effect", function(effect, scored_card, from_edition)
        for _, key in ipairs(SMODS.calculation_keys) do
            if effect[key] ~= nil then
                SMODS.calculate_individual_effect(
                    effect,
                    scored_card,
                    key,
                    effect[key],
                    from_edition
                )
            end
        end
        return {}
    end)
    rawset(SMODS, "calculate_effect_table_key", function(effect_table, key, card)
        local effect = effect_table[key]
        if type(effect) == "table" then
            SMODS.calculate_effect(effect, effect.scored_card or card, key == "edition")
        end
    end)
    rawset(_G, "card_eval_status_text", function(_card, _eval_type) end)
    rawset(SMODS, "calculate_main_scoring", function(context, scoring_hand)
        if type(scoring_hand) ~= "table" then
            return
        end
        local cards = context.cardarea and context.cardarea.cards or scoring_hand
        for _, card in ipairs(cards) do
            if card.debuff then
                for _, other in ipairs(scoring_hand) do
                    if other == card then
                        card_eval_status_text(card, "debuff")
                        break
                    end
                end
            end
        end
    end)
end

local function push_smods_context(context)
    SMODS.context_stack = { { context = context } }
end

local function assert_resolution_matches_announced_schema(resolution, tool_name)
    if not resolution then
        return
    end
    local output_schema = assert(ToolCatalog.get(tool_name or "use_consumable")).outputSchema
    luaunit.assertEquals(
        ToolCatalog.validate_schema(output_schema, {
            state = {
                server_name = "balatro-mcp",
                server_version = "0.6.1",
                protocol_version = "2026-07-28",
                visibility = "fair",
                run_id = "schema",
                decision_sequence = 1,
                phase = "main_menu",
                legal_actions = {},
                state_hash = "deadbeef",
                available_decks = {},
                available_stakes = {},
            },
            resolution = resolution,
        }),
        nil
    )
end

local function with_tag_fixture(callback)
    local saved = {}
    for _, name in ipairs({
        "G",
        "SMODS",
        "Card",
        "CardArea",
        "Tag",
        "Event",
        "add_tag",
        "create_card",
        "create_shop_card_ui",
        "ease_dollars",
        "get_new_boss",
        "hand_chips",
        "level_up_hand",
        "mult",
    }) do
        saved[name] = { value = rawget(_G, name) }
    end
    local ace = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        T = { x = 1 },
    })
    local queued = {}
    local fixture = { apply_tag = function(_tag, _context) end, new_boss_key = "bl_hook" }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ ace }, {})
        _G.Event = setmetatable({}, {
            __call = function(_, event)
                return event
            end,
        })
        G.E_MANAGER = {
            add_event = function(_, event)
                queued[#queued + 1] = event
            end,
        }
        _G.CardArea = {
            change_size = function(area, amount)
                area.config.card_limit = area.config.card_limit + amount
            end,
        }
        G.hand.config = { card_limit = 8 }
        setmetatable(G.hand, { __index = CardArea })
        local function area(limit)
            return {
                cards = {},
                config = { card_limit = limit },
                emplace = function(self, card)
                    self.cards[#self.cards + 1] = card
                    card.area = self
                end,
            }
        end
        G.shop_jokers = area(2)
        G.shop_vouchers = area(1)
        G.shop_booster = area(2)
        G.consumeables = area(2)
        G.jokers = area(5)
        G.STATES.ROUND_EVAL = 6
        G.GAME.round_resets.blind_choices.Boss = "bl_head"
        G.GAME.round_resets.reroll_cost = 5
        G.GAME.current_round.reroll_cost = 5
        G.GAME.shop = {}
        G.GAME.modifiers = {}
        G.GAME.hands["High Card"] = {
            visible = true,
            level = 1,
            chips = 5,
            mult = 1,
        }

        _G.Tag = {
            apply_to_run = function(tag, context)
                return fixture.apply_tag(tag, context)
            end,
            remove_from_game = function(tag)
                for index, current in ipairs(G.GAME.tags) do
                    if current == tag then
                        table.remove(G.GAME.tags, index)
                        break
                    end
                end
            end,
        }
        fixture.tag = function(key, fields)
            local tag = fields or {}
            tag.key = key
            tag.triggered = tag.triggered or false
            return setmetatable(tag, { __index = Tag })
        end

        _G.Card = {
            set_edition = function(card, edition)
                card.edition = edition
            end,
            open = function(card)
                local size = math.max(
                    1,
                    (card.ability.extra or card.config.center.extra or 1)
                        + (G.GAME.modifiers.booster_size_mod or 0)
                )
                G.GAME.pack_choices = math.min(
                    (card.ability.choose or card.config.center.config.choose or 1)
                        + (G.GAME.modifiers.booster_choice_mod or 0),
                    size
                )
            end,
        }
        _G.add_tag = function(tag)
            for _, current in ipairs(G.GAME.tags) do
                current:apply_to_run({ type = "tag_add", tag = tag })
            end
            G.GAME.tags[#G.GAME.tags + 1] = tag
            if type(SMODS.calculate_context) == "function" then
                SMODS.calculate_context({ tag_added = tag })
            end
        end
        _G.create_card = function(_set, target_area, _legendary, rarity)
            local key = rarity == 1 and "j_rare" or rarity == 0.9 and "j_uncommon" or "j_top_up"
            return setmetatable({
                facing = "front",
                ability = { set = "Joker", name = key },
                config = { center = { key = key, set = "Joker" } },
                area = target_area,
            }, { __index = Card })
        end
        _G.create_shop_card_ui = function(card, _set, target_area)
            card.area = target_area
        end
        _G.ease_dollars = function(amount)
            G.GAME.dollars = G.GAME.dollars + amount
        end
        _G.level_up_hand = function(_tag, hand, _instant, amount)
            local value = G.GAME.hands[hand]
            value.level = value.level + amount
            value.chips = value.chips + 10 * amount
            value.mult = value.mult + amount
        end
        _G.get_new_boss = function()
            return fixture.new_boss_key
        end

        fixture.drain = function()
            while queued[1] do
                local event = table.remove(queued, 1)
                event.func()
            end
        end
        fixture.capture = function(action, before_finish)
            queued = {}
            G.FUNCS = {
                discard_cards_from_highlighted = action,
            }
            local adapter = ProductionBalatroAdapter.new()
            local result, action_error = adapter:execute({
                name = "discard_cards",
                expected_state_hash = "sha256:test",
                visibility = "fair",
                arguments = {},
                targets = { card_ids = { "card:1" } },
            })
            luaunit.assertNil(action_error)
            luaunit.assertNotNil(result)
            ---@cast result table
            fixture.drain()
            if before_finish then
                before_finish(adapter, result)
                fixture.drain()
            end
            local resolution, resolution_error =
                adapter:finish_resolution(result.resolution_context)
            luaunit.assertNil(resolution_error)
            assert_resolution_matches_announced_schema(resolution)
            return resolution
        end

        callback(fixture)
    end, debug.traceback)

    for name, entry in pairs(saved) do
        rawset(_G, name, entry.value)
    end
    if not ok then
        error(test_error)
    end
end

local function with_lifecycle_joker_fixture(callback)
    local saved = {}
    for _, name in ipairs({
        "G",
        "SMODS",
        "Blind",
        "Card",
        "CardArea",
        "Event",
        "Tag",
        "add_tag",
        "card_eval_status_text",
        "copy_card",
        "create_card",
        "create_playing_card",
        "ease_discard",
        "ease_hands_played",
        "hand_chips",
        "juice_card_until",
        "mult",
        "playing_card_joker_effects",
    }) do
        saved[name] = { value = rawget(_G, name) }
    end

    local ace = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
    })
    local queued = {}
    local created_serial = 0
    local fixture = {}

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ ace }, {})
        _G.Event = setmetatable({}, {
            __call = function(_, event)
                return event
            end,
        })
        G.E_MANAGER = {
            add_event = function(_, event)
                queued[#queued + 1] = event
            end,
        }
        _G.CardArea = {
            emplace = function(area, card)
                area.cards[#area.cards + 1] = card
                card.area = area
            end,
        }
        local function area(limit, area_type)
            return setmetatable({
                cards = {},
                config = { card_limit = limit, type = area_type },
            }, { __index = CardArea })
        end
        G.jokers = area(12, "joker")
        G.consumeables = area(4, "consumeable")
        G.play = area(52, "play")
        G.deck = area(52, "deck")
        G.hand.config = { card_limit = 8, type = "hand" }
        setmetatable(G.hand, { __index = CardArea })
        G.shop_jokers = area(2, "shop")
        G.shop_vouchers = area(1, "shop")
        G.shop_booster = area(2, "shop")
        G.playing_cards = {}
        G.P_CENTERS.c_base = { key = "c_base", set = "Default" }
        G.P_CENTERS.m_stone = { key = "m_stone", set = "Enhanced" }
        G.GAME.consumeable_buffer = 0
        G.GAME.joker_buffer = 0
        G.GAME.probabilities = { normal = 1 }
        G.GAME.current_round.hands_left = 4
        G.GAME.current_round.discards_left = 3
        G.GAME.round_resets.hands = 4
        G.GAME.round_resets.discards = 3
        G.GAME.blind = setmetatable({
            disabled = false,
            config = { blind = { key = "bl_small", boss = true } },
        }, {
            __index = function(_, key)
                return Blind[key]
            end,
        })

        _G.Blind = {
            disable = function(blind)
                blind.disabled = true
            end,
        }
        _G.Card = {
            add_to_deck = function(_card) end,
            can_sell_card = function(_card)
                return true
            end,
            juice_up = function(_card) end,
            set_edition = function(card, edition)
                card.edition = edition
            end,
            set_seal = function(card, seal)
                card.seal = seal
            end,
            start_dissolve = function(card)
                card.dissolved = true
            end,
        }

        local joker_keys = {
            Blueprint = "j_blueprint",
            Brainstorm = "j_brainstorm",
            ["Hallucination"] = "j_hallucination",
            Luchador = "j_luchador",
            ["Diet Cola"] = "j_diet_cola",
            ["Invisible Joker"] = "j_invisible",
            Campfire = "j_campfire",
            ["Flash Card"] = "j_flash",
            Perkeo = "j_perkeo",
            Throwback = "j_throwback",
            ["Red Card"] = "j_red_card",
            Hologram = "j_hologram",
            Certificate = "j_certificate",
            DNA = "j_dna",
            ["Trading Card"] = "j_trading",
            Chicot = "j_chicot",
            Madness = "j_madness",
            Burglar = "j_burglar",
            ["Riff-raff"] = "j_riff_raff",
            Cartomancer = "j_cartomancer",
            ["Ceremonial Dagger"] = "j_ceremonial",
            ["Marble Joker"] = "j_marble",
        }
        fixture.joker = function(name, sort_id, fields)
            local ability = { set = "Joker", name = name }
            for key, value in pairs(fields or {}) do
                ability[key] = value
            end
            return setmetatable({
                sort_id = sort_id,
                facing = "front",
                sell_cost = 3,
                ability = ability,
                config = {
                    center = { key = assert(joker_keys[name]), set = "Joker", name = name },
                },
            }, { __index = Card })
        end
        fixture.consumable = function(key, sort_id)
            return setmetatable({
                sort_id = sort_id,
                facing = "front",
                ability = { set = "Tarot", consumeable = {}, name = key },
                config = { center = { key = key, set = "Tarot" } },
            }, { __index = Card })
        end

        _G.add_tag = function(tag)
            G.GAME.tags[#G.GAME.tags + 1] = tag
        end
        _G.copy_card = function(source)
            local ability = {}
            for key, value in pairs(source.ability or {}) do
                ability[key] = value
            end
            return setmetatable({
                facing = "front",
                ability = ability,
                config = { center = source.config.center },
            }, { __index = Card })
        end
        _G.create_card = function(set, target_area)
            created_serial = created_serial + 1
            local is_joker = set == "Joker"
            local key = is_joker and "j_created_" .. created_serial
                or "c_created_" .. created_serial
            return setmetatable({
                facing = "front",
                ability = {
                    set = is_joker and "Joker" or "Tarot",
                    consumeable = not is_joker and {} or nil,
                    name = key,
                },
                config = { center = { key = key, set = is_joker and "Joker" or "Tarot" } },
                area = target_area,
            }, { __index = Card })
        end
        _G.create_playing_card = function(_spec, target_area)
            local card = test_playing_card({
                sort_id = 100 + created_serial,
                key = "S_A",
                suit = "Spades",
                rank = "Ace",
                nominal = 11,
                suit_nominal = 0.04,
                suit_nominal_original = 0.004,
            })
            setmetatable(card, { __index = Card })
            target_area:emplace(card)
            G.playing_cards[#G.playing_cards + 1] = card
            return card
        end
        _G.ease_discard = function(amount)
            G.E_MANAGER:add_event(Event({
                func = function()
                    G.GAME.current_round.discards_left = G.GAME.current_round.discards_left + amount
                    return true
                end,
            }))
        end
        _G.ease_hands_played = function(amount)
            G.E_MANAGER:add_event(Event({
                func = function()
                    G.GAME.current_round.hands_left = G.GAME.current_round.hands_left + amount
                    return true
                end,
            }))
        end
        _G.card_eval_status_text = function(_card, _type) end
        _G.juice_card_until = function(_card, _predicate) end
        _G.playing_card_joker_effects = function(cards)
            SMODS.calculate_context({ playing_card_added = true, cards = cards })
        end

        Card.calculate_joker = function(card, context)
            local name = card.ability.name
            if (name == "Blueprint" or name == "Brainstorm") and card.copy_target then
                local previous_blueprint = context.blueprint
                local previous_blueprint_card = context.blueprint_card
                context.blueprint = (context.blueprint or 0) + 1
                context.blueprint_card = context.blueprint_card or card
                card.copy_target:calculate_joker(context)
                context.blueprint = previous_blueprint
                context.blueprint_card = previous_blueprint_card
            elseif context.open_booster and name == "Hallucination" then
                G.E_MANAGER:add_event(Event({
                    func = function()
                        local created = create_card("Tarot", G.consumeables)
                        created:add_to_deck()
                        G.consumeables:emplace(created)
                        return true
                    end,
                }))
            elseif context.selling_self and name == "Luchador" then
                G.GAME.blind:disable()
            elseif context.selling_self and name == "Diet Cola" then
                G.E_MANAGER:add_event(Event({
                    func = function()
                        add_tag({ key = "tag_double" })
                        return true
                    end,
                }))
            elseif context.selling_self and name == "Invisible Joker" then
                for _, other in ipairs(G.jokers.cards) do
                    if other ~= card then
                        local copied = copy_card(other)
                        copied:add_to_deck()
                        G.jokers:emplace(copied)
                        break
                    end
                end
            elseif context.selling_card and name == "Campfire" then
                card.ability.x_mult = card.ability.x_mult + card.ability.extra
            elseif context.reroll_shop and name == "Flash Card" then
                card.ability.mult = card.ability.mult + card.ability.extra
            elseif context.ending_shop and name == "Perkeo" then
                G.E_MANAGER:add_event(Event({
                    func = function()
                        local copied = copy_card(G.consumeables.cards[1])
                        copied:set_edition({ negative = true, type = "negative" })
                        copied:add_to_deck()
                        G.consumeables:emplace(copied)
                        return true
                    end,
                }))
            elseif context.skipping_booster and name == "Red Card" then
                card.ability.mult = card.ability.mult + card.ability.extra
            elseif context.playing_card_added and name == "Hologram" then
                card.ability.x_mult = card.ability.x_mult + #context.cards * card.ability.extra
            elseif context.first_hand_drawn and name == "Certificate" then
                G.E_MANAGER:add_event(Event({
                    func = function()
                        local created = create_playing_card({}, G.hand)
                        created:set_seal("Red")
                        return true
                    end,
                }))
                playing_card_joker_effects({ true })
            elseif context.first_hand_drawn and (name == "DNA" or name == "Trading Card") then
                juice_card_until(card, function()
                    return true
                end)
            elseif context.setting_blind and name == "Chicot" then
                G.E_MANAGER:add_event(Event({
                    func = function()
                        G.E_MANAGER:add_event(Event({
                            func = function()
                                G.GAME.blind:disable()
                                return true
                            end,
                        }))
                        return true
                    end,
                }))
            elseif context.setting_blind and name == "Madness" then
                card.ability.x_mult = card.ability.x_mult + card.ability.extra
                G.E_MANAGER:add_event(Event({
                    func = function()
                        card.destroy_target:start_dissolve()
                        return true
                    end,
                }))
            elseif context.setting_blind and name == "Burglar" then
                G.E_MANAGER:add_event(Event({
                    func = function()
                        ease_discard(-G.GAME.current_round.discards_left)
                        ease_hands_played(card.ability.extra)
                        return true
                    end,
                }))
            elseif context.setting_blind and name == "Riff-raff" then
                G.E_MANAGER:add_event(Event({
                    func = function()
                        for _ = 1, 2 do
                            local created = create_card("Joker", G.jokers)
                            created:add_to_deck()
                            G.jokers:emplace(created)
                        end
                        return true
                    end,
                }))
            elseif context.setting_blind and name == "Cartomancer" then
                G.E_MANAGER:add_event(Event({
                    func = function()
                        G.E_MANAGER:add_event(Event({
                            func = function()
                                local created = create_card("Tarot", G.consumeables)
                                created:add_to_deck()
                                G.consumeables:emplace(created)
                                return true
                            end,
                        }))
                        return true
                    end,
                }))
            elseif context.setting_blind and name == "Ceremonial Dagger" then
                G.E_MANAGER:add_event(Event({
                    func = function()
                        card.ability.mult = card.ability.mult + card.destroy_target.sell_cost * 2
                        card.destroy_target:start_dissolve()
                        return true
                    end,
                }))
            elseif context.setting_blind and name == "Marble Joker" then
                G.E_MANAGER:add_event(Event({
                    func = function()
                        local created = test_playing_card({
                            sort_id = 200 + created_serial,
                            key = "H_2",
                            suit = "Hearts",
                            rank = "2",
                            nominal = 2,
                            suit_nominal = 0.03,
                            suit_nominal_original = 0.003,
                        })
                        created.config.center = G.P_CENTERS.m_stone
                        created.ability = { effect = "Stone Card", set = "Enhanced" }
                        setmetatable(created, { __index = Card })
                        G.play:emplace(created)
                        G.playing_cards[#G.playing_cards + 1] = created
                        return true
                    end,
                }))
                playing_card_joker_effects({ true })
            elseif context.skip_blind and name == "Throwback" then
                card_eval_status_text(card, "extra")
            end
        end

        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            context_stack = {},
            stake_from_index = function()
                return "stake_white"
            end,
        }
        SMODS.calculate_context = function(context)
            SMODS.context_stack[#SMODS.context_stack + 1] = { context = context }
            local cards = {}
            for index, card in ipairs(G.jokers.cards) do
                cards[index] = card
            end
            for _, card in ipairs(cards) do
                card:calculate_joker(context)
            end
            SMODS.context_stack[#SMODS.context_stack] = nil
        end

        fixture.reset = function(jokers, consumables)
            queued = {}
            created_serial = 0
            G.jokers.cards = jokers or {}
            G.consumeables.cards = consumables or {}
            G.play.cards = {}
            G.deck.cards = {}
            G.playing_cards = {}
            G.GAME.tags = {}
            G.GAME.skips = 0
            G.GAME.blind.disabled = false
            G.GAME.current_round.hands_left = 4
            G.GAME.current_round.discards_left = 3
            for _, card in ipairs(G.jokers.cards) do
                card.area = G.jokers
                card.dissolved = nil
            end
            for _, card in ipairs(G.consumeables.cards) do
                card.area = G.consumeables
            end
        end
        fixture.drain = function()
            while queued[1] do
                local event = table.remove(queued, 1)
                event.func()
            end
        end
        local function finish_capture(adapter, result, tool_name)
            fixture.drain()
            local resolution, resolution_error =
                adapter:finish_resolution(result.resolution_context)
            luaunit.assertNil(resolution_error)
            assert_resolution_matches_announced_schema(resolution, tool_name)
            return resolution
        end
        fixture.capture = function(jokers, consumables, invoke)
            fixture.reset(jokers, consumables)
            G.FUNCS = { discard_cards_from_highlighted = invoke }
            local adapter = ProductionBalatroAdapter.new()
            local result, action_error = adapter:execute({
                name = "discard_cards",
                expected_state_hash = "sha256:test",
                visibility = "fair",
                arguments = {},
                targets = { card_ids = { "card:1" } },
            })
            luaunit.assertNil(action_error)
            luaunit.assertNotNil(result)
            ---@cast result table
            return finish_capture(adapter, result, "discard_cards")
        end
        fixture.capture_open = function(jokers)
            fixture.reset(jokers, {})
            local booster = setmetatable({
                sort_id = 31,
                facing = "front",
                cost = 0,
                ability = {
                    set = "Booster",
                    name = "Arcana Pack",
                    extra = 3,
                    choose = 1,
                },
                config = {
                    center = {
                        key = "p_arcana_normal_1",
                        set = "Booster",
                        name = "Arcana Pack",
                        kind = "Arcana",
                        config = { choose = 1, extra = 3 },
                    },
                },
            }, { __index = Card })
            G.STATE = G.STATES.SHOP
            G.shop = {}
            G.shop_booster.cards = { booster }
            G.FUNCS = {
                use_card = function()
                    SMODS.calculate_context({ open_booster = true, card = booster })
                end,
            }
            local adapter = ProductionBalatroAdapter.new()
            local result, action_error = adapter:execute({
                name = "open_booster",
                expected_state_hash = "sha256:test",
                visibility = "fair",
                arguments = {},
                targets = { booster_id = "shop_booster:31" },
            })
            luaunit.assertNil(action_error)
            luaunit.assertNotNil(result)
            ---@cast result table
            local resolution = finish_capture(adapter, result, "open_booster")
            G.STATE = G.STATES.SELECTING_HAND
            G.shop = nil
            G.shop_booster.cards = {}
            return resolution
        end
        fixture.capture_shop_added = function(jokers)
            fixture.reset(jokers, {})
            local shop_card = test_playing_card({
                sort_id = 32,
                key = "H_2",
                suit = "Hearts",
                rank = "2",
                nominal = 2,
                suit_nominal = 0.03,
                suit_nominal_original = 0.003,
            })
            shop_card.cost = 0
            shop_card.area = G.shop_jokers
            setmetatable(shop_card, { __index = Card })
            G.STATE = G.STATES.SHOP
            G.shop = {}
            G.shop_jokers.cards = { shop_card }
            G.FUNCS = {
                buy_from_shop = function()
                    SMODS.calculate_context({ playing_card_added = true, cards = { shop_card } })
                end,
            }
            local adapter = ProductionBalatroAdapter.new()
            local result, action_error = adapter:execute({
                name = "buy_shop_item",
                expected_state_hash = "sha256:test",
                visibility = "fair",
                arguments = {},
                targets = { item_id = "shop_item:32" },
            })
            luaunit.assertNil(action_error)
            luaunit.assertNotNil(result)
            ---@cast result table
            local resolution = finish_capture(adapter, result, "buy_shop_item")
            G.STATE = G.STATES.SELECTING_HAND
            G.shop = nil
            G.shop_jokers.cards = {}
            return resolution
        end
        fixture.capture_sell = function(jokers, sold, state)
            fixture.reset(jokers, {})
            G.STATE = state or G.STATES.SELECTING_HAND
            G.FUNCS = {
                sell_card = function(e)
                    local card = e.config.ref_table
                    card:calculate_joker({ selling_self = true })
                    local cards = {}
                    for index, joker in ipairs(G.jokers.cards) do
                        cards[index] = joker
                    end
                    for _, joker in ipairs(cards) do
                        if joker ~= card then
                            joker:calculate_joker({ selling_card = true, card = card })
                        end
                    end
                    card:start_dissolve()
                end,
            }
            local adapter = ProductionBalatroAdapter.new()
            local result, action_error = adapter:execute({
                name = "sell_owned_item",
                expected_state_hash = "sha256:test",
                visibility = "fair",
                arguments = {},
                targets = { item_id = "joker:" .. sold.sort_id },
            })
            luaunit.assertNil(action_error)
            luaunit.assertNotNil(result)
            ---@cast result table
            local resolution = finish_capture(adapter, result, "sell_owned_item")
            G.STATE = G.STATES.SELECTING_HAND
            return resolution
        end

        callback(fixture)
    end, debug.traceback)

    for name, entry in pairs(saved) do
        rawset(_G, name, entry.value)
    end
    if not ok then
        error(test_error)
    end
end

local function with_blind_fixture(callback)
    local saved = {}
    for _, name in ipairs({
        "G",
        "SMODS",
        "Blind",
        "Card",
        "CardArea",
        "Event",
        "draw_card",
        "ease_discard",
        "ease_dollars",
        "ease_hands_played",
        "level_up_hand",
    }) do
        saved[name] = { value = rawget(_G, name) }
    end

    local function playing_card(sort_id, key, rank)
        local card = test_playing_card({
            sort_id = sort_id,
            key = key,
            suit = "Spades",
            rank = rank,
            nominal = sort_id,
            suit_nominal = 0.04,
            suit_nominal_original = 0.004,
        })
        card.T = { x = sort_id }
        return card
    end

    local ace = playing_card(1, "S_A", "Ace")
    local king = playing_card(2, "S_K", "King")
    local queen = playing_card(3, "S_Q", "Queen")
    local joker_one = {
        sort_id = 11,
        facing = "front",
        ability = { set = "Joker", name = "Joker" },
        config = { center = { key = "j_joker", set = "Joker" } },
    }
    local joker_two = {
        sort_id = 12,
        facing = "front",
        ability = { set = "Joker", name = "Greedy Joker" },
        config = { center = { key = "j_greedy_joker", set = "Joker" } },
    }
    local queued = {}
    local fixture = {
        cards = { ace, king, queen },
        jokers = { joker_one, joker_two },
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals(fixture.cards, fixture.jokers)
        local hook = {
            key = "bl_hook",
            name = "The Hook",
            dollars = 5,
            mult = 2,
            debuff = {},
            boss = { min = 1, max = 10 },
        }
        local acorn = {
            key = "bl_final_acorn",
            name = "Amber Acorn",
            dollars = 8,
            mult = 2,
            debuff = {},
            boss = { showdown = true, min = 10, max = 10 },
        }
        local facedown_blinds = {
            wheel = { key = "bl_wheel", name = "The Wheel" },
            house = { key = "bl_house", name = "The House" },
            fish = { key = "bl_fish", name = "The Fish" },
            mark = { key = "bl_mark", name = "The Mark" },
        }
        local state_blinds = {
            club = { key = "bl_club", name = "The Club", debuff = { suit = "Spades" } },
            heart = { key = "bl_final_heart", name = "Crimson Heart" },
            bell = { key = "bl_final_bell", name = "Cerulean Bell" },
            leaf = { key = "bl_final_leaf", name = "Verdant Leaf" },
            wall = { key = "bl_wall", name = "The Wall" },
            vessel = { key = "bl_final_vessel", name = "Violet Vessel" },
            eye = { key = "bl_eye", name = "The Eye" },
            mouth = { key = "bl_mouth", name = "The Mouth" },
            psychic = {
                key = "bl_psychic",
                name = "The Psychic",
                debuff = { h_size_ge = 5 },
            },
            serpent = { key = "bl_serpent", name = "The Serpent" },
            manacle = { key = "bl_manacle", name = "The Manacle" },
            water = { key = "bl_water", name = "The Water" },
            needle = { key = "bl_needle", name = "The Needle" },
            arm = { key = "bl_arm", name = "The Arm" },
            flint = { key = "bl_flint", name = "The Flint" },
            ox = { key = "bl_ox", name = "The Ox" },
            tooth = { key = "bl_tooth", name = "The Tooth" },
        }
        G.P_BLINDS.bl_hook = hook
        G.P_BLINDS.bl_final_acorn = acorn
        for _, prototypes in ipairs({ facedown_blinds, state_blinds }) do
            for _, prototype in pairs(prototypes) do
                prototype.dollars = prototype.dollars or 5
                prototype.mult = prototype.mult or 2
                prototype.debuff = prototype.debuff or {}
                prototype.boss = prototype.boss or { min = 1, max = 10 }
                G.P_BLINDS[prototype.key] = prototype
            end
        end
        state_blinds.wall.requirement = 400
        state_blinds.vessel.requirement = 600
        G.P_CENTERS.j_joker = joker_one.config.center
        G.P_CENTERS.j_greedy_joker = joker_two.config.center
        G.GAME.blind_on_deck = "Boss"
        G.GAME.round_resets.blind_choices = { Boss = "bl_hook" }
        G.GAME.round_resets.blind_states = { Boss = "Current" }
        G.GAME.current_round.hands_played = 0
        G.GAME.current_round.discards_used = 0
        G.GAME.round_resets.hands = 4
        G.GAME.round_resets.discards = 3
        G.GAME.hands.Pair = { visible = true, level = 2, chips = 20, mult = 2, played = 0 }
        G.playing_cards = fixture.cards
        G.hand.config = { card_limit = 8, type = "hand" }
        G.discard = { cards = {}, config = { card_limit = 52, type = "discard" } }
        G.play = { cards = {}, config = { card_limit = 52, type = "play" } }

        _G.Event = setmetatable({}, {
            __call = function(_, event)
                return event
            end,
        })
        G.E_MANAGER = {
            add_event = function(_, event)
                queued[#queued + 1] = event
            end,
        }
        _G.Card = {
            calculate_seal = function(card, context)
                if context.discard and card.seal == "Purple" then
                    G.E_MANAGER:add_event(Event({
                        func = function()
                            G.consumeables:emplace(fixture.new_consumable())
                            return true
                        end,
                    }))
                end
            end,
            flip = function(card)
                card.facing = card.facing == "back" and "front" or "back"
            end,
            set_base = function(card, base)
                card.base.suit = base.suit
                card.base.value = base.value
                G.GAME.blind:debuff_card(card)
            end,
            set_debuff = function(card, value)
                card.debuff = value
            end,
        }
        _G.CardArea = {
            remove_card = function(area, card)
                for index, current in ipairs(area.cards) do
                    if current == card then
                        table.remove(area.cards, index)
                        return card
                    end
                end
            end,
            emplace = function(area, card)
                area.cards[#area.cards + 1] = card
                card.area = area
            end,
            change_size = function(area, amount)
                G.E_MANAGER:add_event(Event({
                    func = function()
                        area.config.card_limit = area.config.card_limit + amount
                        if amount > 0 and area == G.hand and G.deck.cards[1] then
                            draw_card(G.deck, G.hand, 100, "up", false, G.deck.cards[1])
                        end
                        return true
                    end,
                }))
            end,
            shuffle = function(area, _seed)
                local reversed = {}
                for index = #area.cards, 1, -1 do
                    reversed[#reversed + 1] = area.cards[index]
                end
                area.cards = reversed
            end,
        }
        for _, area in ipairs({
            G.hand,
            G.play,
            G.discard,
            G.deck,
            G.jokers,
            G.consumeables,
        }) do
            setmetatable(area, { __index = CardArea })
        end
        for _, card in ipairs(fixture.cards) do
            card.area = G.hand
            setmetatable(card, { __index = Card })
        end
        for _, joker in ipairs(fixture.jokers) do
            joker.area = G.jokers
            setmetatable(joker, { __index = Card })
        end
        _G.draw_card = function(from, to, _percent, _dir, _sort, card)
            G.E_MANAGER:add_event(Event({
                func = function()
                    local moved = from:remove_card(card)
                    local stay_flipped = G.GAME.blind:stay_flipped(to, moved)
                    to:emplace(moved, nil, stay_flipped)
                    return true
                end,
            }))
        end
        _G.ease_discard = function(amount)
            G.E_MANAGER:add_event(Event({
                func = function()
                    G.GAME.current_round.discards_left = G.GAME.current_round.discards_left + amount
                    return true
                end,
            }))
        end
        _G.ease_dollars = function(amount)
            G.GAME.dollars = G.GAME.dollars + amount
        end
        _G.ease_hands_played = function(amount)
            G.E_MANAGER:add_event(Event({
                func = function()
                    G.GAME.current_round.hands_left = G.GAME.current_round.hands_left + amount
                    return true
                end,
            }))
        end
        _G.level_up_hand = function(_source, hand_name, _instant, amount)
            local hand = G.GAME.hands[hand_name]
            hand.level = hand.level + amount
            hand.chips = hand.chips + amount * 10
            hand.mult = hand.mult + amount
        end
        SMODS.context_stack = {}
        SMODS.calculate_effect_table_key = function(effect_table, key, card)
            local effect = effect_table[key]
            if effect and effect.func then
                return effect.func(card)
            end
        end
        _G.Blind = {
            set_blind = function(blind, prototype)
                if not prototype then
                    blind.config.blind = {}
                    blind.name = ""
                    blind.chips = 0
                    return
                end
                blind.config.blind = prototype
                blind.name = prototype.name
                blind.debuff = prototype.debuff
                blind.disabled = false
                blind.chips = prototype.requirement or blind.chips
                if prototype.name == "The Eye" then
                    blind.hands = {}
                elseif prototype.name == "The Mouth" then
                    blind.only_hand = false
                elseif prototype.name == "The Water" then
                    blind.discards_sub = G.GAME.current_round.discards_left
                    ease_discard(-blind.discards_sub)
                elseif prototype.name == "The Needle" then
                    blind.hands_sub = G.GAME.round_resets.hands - 1
                    ease_hands_played(-blind.hands_sub)
                elseif prototype.name == "The Manacle" then
                    G.hand:change_size(-1)
                end
                if prototype.name == "Amber Acorn" then
                    for _, joker in ipairs(G.jokers.cards) do
                        joker:flip()
                    end
                    for _ = 1, 3 do
                        G.E_MANAGER:add_event(Event({
                            func = function()
                                G.jokers:shuffle("aajk")
                                return true
                            end,
                        }))
                    end
                end
            end,
            debuff_hand = function(blind, cards, _hand, hand_name, check)
                if blind.name == "The Psychic" and #cards < 5 then
                    return true
                elseif blind.name == "The Eye" then
                    if blind.hands[hand_name] then
                        return true
                    end
                    if not check then
                        blind.hands[hand_name] = true
                    end
                elseif blind.name == "The Mouth" then
                    if blind.only_hand and blind.only_hand ~= hand_name then
                        return true
                    end
                    if not check then
                        blind.only_hand = hand_name
                    end
                elseif blind.name == "The Arm" and not check then
                    local hand = G.GAME.hands[hand_name]
                    if hand.level > 1 then
                        level_up_hand(nil, hand_name, nil, -1)
                    end
                elseif blind.name == "The Ox" and not check then
                    ease_dollars(-G.GAME.dollars)
                end
            end,
            modify_hand = function(blind, _cards, _hands, _text, hand_mult, hand_chips)
                if blind.name == "The Flint" then
                    return math.max(math.floor(hand_mult * 0.5 + 0.5), 1),
                        math.max(math.floor(hand_chips * 0.5 + 0.5), 0),
                        true
                end
                return hand_mult, hand_chips, false
            end,
            debuff_card = function(blind, card)
                card:set_debuff(
                    not blind.disabled
                        and (blind.name == "The Club" or blind.name == "Verdant Leaf")
                )
            end,
            drawn_to_hand = function(blind)
                if blind.disabled then
                    return
                end
                if blind.name == "Cerulean Bell" then
                    G.hand.cards[1].ability.forced_selection = true
                elseif blind.name == "Crimson Heart" then
                    for _, joker in ipairs(G.jokers.cards) do
                        joker:set_debuff(false)
                    end
                    G.jokers.cards[1]:set_debuff(true)
                end
            end,
            disable = function(blind)
                blind.disabled = true
                for _, joker in ipairs(G.jokers.cards) do
                    if joker.facing == "back" then
                        joker:flip()
                    end
                end
                if blind.name == "The Water" then
                    ease_discard(blind.discards_sub)
                elseif blind.name == "The Needle" then
                    ease_hands_played(blind.hands_sub)
                elseif blind.name == "The Manacle" then
                    G.hand:change_size(1)
                elseif blind.name == "The Wall" then
                    blind.chips = blind.chips / 2
                elseif blind.name == "Violet Vessel" then
                    blind.chips = blind.chips / 3
                elseif blind.name == "Cerulean Bell" then
                    for _, card in ipairs(G.playing_cards) do
                        card.ability.forced_selection = nil
                    end
                end
                for _, card in ipairs(G.playing_cards) do
                    blind:debuff_card(card)
                end
                for _, joker in ipairs(G.jokers.cards) do
                    blind:debuff_card(joker)
                end
            end,
            defeat = function(blind)
                G.E_MANAGER:add_event(Event({
                    func = function()
                        blind:set_blind(nil)
                        return true
                    end,
                }))
                if blind.name == "The Manacle" and not blind.disabled then
                    G.hand:change_size(1)
                end
            end,
            stay_flipped = function(blind, area, _card)
                if area == G.hand then
                    for _, prototype in pairs(facedown_blinds) do
                        if blind.name == prototype.name then
                            return true
                        end
                    end
                end
            end,
            press_play = function(blind)
                if blind.name == "The Tooth" then
                    G.E_MANAGER:add_event(Event({
                        func = function()
                            for _ = 1, #G.play.cards do
                                ease_dollars(-1)
                            end
                            return true
                        end,
                    }))
                    return true
                end
                if blind.name ~= "The Hook" then
                    return
                end
                G.E_MANAGER:add_event(Event({
                    func = function()
                        if fixture.before_hook_move then
                            G.E_MANAGER:add_event(Event({
                                func = function()
                                    fixture.before_hook_move()
                                    return true
                                end,
                            }))
                        end
                        local cards = {}
                        for _, card in ipairs(G.hand.cards) do
                            cards[#cards + 1] = card
                        end
                        for index = 1, math.min(2, #cards) do
                            cards[index]:calculate_seal({ discard = true })
                            draw_card(G.hand, G.discard, index * 50, "down", false, cards[index])
                        end
                        return true
                    end,
                }))
                return true
            end,
        }
        G.GAME.blind = setmetatable({
            name = hook.name,
            config = { blind = hook },
            disabled = false,
            chips = 200,
            dollars = 5,
            debuff = {},
        }, { __index = Blind })

        fixture.activate = function(prototype)
            G.P_BLINDS[prototype.key] = prototype
            G.GAME.round_resets.blind_choices.Boss = prototype.key
            G.GAME.blind.config.blind = prototype
            G.GAME.blind.name = prototype.name
            G.GAME.blind.debuff = prototype.debuff
            G.GAME.blind.chips = prototype.requirement or 200
            G.GAME.blind.disabled = false
            G.GAME.blind.hands = prototype.name == "The Eye" and {} or nil
            G.GAME.blind.only_hand = prototype.name == "The Mouth" and false or nil
        end
        fixture.blinds = {
            hook = hook,
            acorn = acorn,
            wheel = facedown_blinds.wheel,
            house = facedown_blinds.house,
            fish = facedown_blinds.fish,
            mark = facedown_blinds.mark,
            club = state_blinds.club,
            heart = state_blinds.heart,
            bell = state_blinds.bell,
            leaf = state_blinds.leaf,
            wall = state_blinds.wall,
            vessel = state_blinds.vessel,
            eye = state_blinds.eye,
            mouth = state_blinds.mouth,
            psychic = state_blinds.psychic,
            serpent = state_blinds.serpent,
            manacle = state_blinds.manacle,
            water = state_blinds.water,
            needle = state_blinds.needle,
            arm = state_blinds.arm,
            flint = state_blinds.flint,
            ox = state_blinds.ox,
            tooth = state_blinds.tooth,
        }
        fixture.drawn_card = playing_card(21, "H_2", "2")
        fixture.drawn_card.facing = "back"
        fixture.drawn_card.area = G.deck
        setmetatable(fixture.drawn_card, { __index = Card })
        G.deck.cards = { fixture.drawn_card }
        fixture.new_card = function()
            local card = playing_card(22, "D_2", "2")
            card.base.suit = "Diamonds"
            setmetatable(card, { __index = Card })
            return card
        end
        fixture.new_consumable = function()
            return setmetatable({
                facing = "front",
                ability = { set = "Tarot", consumeable = {}, name = "The Fool" },
                config = { center = { key = "c_fool", set = "Tarot" } },
            }, { __index = Card })
        end
        fixture.drain = function()
            while queued[1] do
                local event = table.remove(queued, 1)
                event.func()
            end
        end
        fixture.capture_play = function(invoke)
            queued = {}
            G.FUNCS = {
                play_cards_from_highlighted = function()
                    local played = G.hand.highlighted[1]
                    draw_card(G.hand, G.play, 100, "up", false, played)
                    fixture.drain()
                    invoke()
                end,
                draw_from_deck_to_hand = function()
                    fixture.draw_count = (fixture.draw_count or 0) + 1
                    if G.deck.cards[1] then
                        draw_card(G.deck, G.hand, 100, "up", false, G.deck.cards[1])
                    end
                end,
            }
            local adapter = ProductionBalatroAdapter.new()
            local result, action_error = adapter:execute({
                name = "play_hand",
                expected_state_hash = "sha256:test",
                visibility = "fair",
                arguments = {},
                targets = { card_ids = { "card:1" } },
            })
            luaunit.assertNil(action_error)
            luaunit.assertNotNil(result)
            ---@cast result table
            fixture.drain()
            local resolution, resolution_error =
                adapter:finish_resolution(result.resolution_context)
            luaunit.assertNil(resolution_error)
            assert_resolution_matches_announced_schema(resolution, "play_hand")
            return resolution
        end
        fixture.capture_select = function(invoke)
            queued = {}
            G.STATE = G.STATES.BLIND_SELECT
            G.blind_select = { VT = { y = 0 } }
            G.blind_prompt_box = {}
            G.blind_select_opts = {
                boss = {
                    get_UIE_by_ID = function(_, id)
                        if id == "select_blind_button" then
                            return { config = { button = "select_blind" } }
                        end
                    end,
                },
            }
            G.GAME.round_resets.blind_states.Boss = "Select"
            G.GAME.bankrupt_at = 0
            G.FUNCS = {
                select_blind = function()
                    G.GAME.blind:set_blind(G.GAME.blind.config.blind)
                    G.E_MANAGER:add_event(Event({
                        func = function()
                            G.STATE = G.STATES.SELECTING_HAND
                            invoke()
                            return true
                        end,
                    }))
                end,
            }
            local adapter = ProductionBalatroAdapter.new()
            local prototype = G.GAME.blind.config.blind
            local result, action_error = adapter:execute({
                name = "select_blind",
                expected_state_hash = "sha256:test",
                visibility = "fair",
                arguments = {},
                targets = { blind_id = "blind:Boss:" .. prototype.key },
            })
            luaunit.assertNil(action_error)
            luaunit.assertNotNil(result)
            ---@cast result table
            fixture.drain()
            local resolution, resolution_error =
                adapter:finish_resolution(result.resolution_context)
            luaunit.assertNil(resolution_error)
            assert_resolution_matches_announced_schema(resolution, "select_blind")
            return resolution
        end
        fixture.capture_discard = function(invoke)
            queued = {}
            G.FUNCS = {
                discard_cards_from_highlighted = function()
                    local discarded = G.hand.highlighted[1]
                    draw_card(G.hand, G.discard, 100, "down", false, discarded)
                    fixture.drain()
                    invoke()
                end,
                draw_from_deck_to_hand = function()
                    fixture.draw_count = (fixture.draw_count or 0) + 1
                    if G.deck.cards[1] then
                        draw_card(G.deck, G.hand, 100, "up", false, G.deck.cards[1])
                    end
                end,
            }
            local adapter = ProductionBalatroAdapter.new()
            local result, action_error = adapter:execute({
                name = "discard_cards",
                expected_state_hash = "sha256:test",
                visibility = "fair",
                arguments = {},
                targets = { card_ids = { "card:1" } },
            })
            luaunit.assertNil(action_error)
            luaunit.assertNotNil(result)
            ---@cast result table
            fixture.drain()
            local resolution, resolution_error =
                adapter:finish_resolution(result.resolution_context)
            luaunit.assertNil(resolution_error)
            assert_resolution_matches_announced_schema(resolution, "discard_cards")
            return resolution
        end

        callback(fixture)
    end, debug.traceback)

    for name, entry in pairs(saved) do
        rawset(_G, name, entry.value)
    end
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_requirement_capacity_allowance_and_hand_level_blind_effects()
    for _, entry in ipairs({
        { key = "wall", value = 400 },
        { key = "vessel", value = 600 },
    }) do
        with_blind_fixture(function(fixture)
            fixture.activate(fixture.blinds[entry.key])
            G.GAME.blind.chips = 1
            local resolution = assert(fixture.capture_play(function()
                G.GAME.blind:set_blind(fixture.blinds[entry.key])
            end))
            luaunit.assertEquals(resolution[1].effects[1], {
                order = resolution[1].effects[1].order,
                kind = "blind_change",
                operation = "requirement",
                score_requirement = entry.value,
            })
        end)
    end

    for _, entry in ipairs({
        { key = "manacle", kind = "capacity", resource = "hand_size", amount = -1, value = 7 },
        {
            key = "water",
            kind = "round_allowance",
            resource = "discards",
            amount = -3,
            base = 3,
            current = 0,
        },
        {
            key = "needle",
            kind = "round_allowance",
            resource = "hands",
            amount = -3,
            base = 4,
            current = 1,
        },
    }) do
        with_blind_fixture(function(fixture)
            fixture.activate(fixture.blinds[entry.key])
            local resolution = assert(fixture.capture_play(function()
                G.GAME.blind:set_blind(fixture.blinds[entry.key])
            end))
            luaunit.assertEquals(#resolution[1].effects, 1)
            local effect = resolution[1].effects[1]
            for field, value in pairs(entry) do
                if field ~= "key" then
                    luaunit.assertEquals(effect[field], value)
                end
            end
        end)
    end

    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.arm)
        local resolution = assert(fixture.capture_play(function()
            G.GAME.blind:debuff_hand({}, {}, "Pair", false)
        end))
        luaunit.assertEquals(resolution[1].effects[1], {
            order = resolution[1].effects[1].order,
            kind = "poker_hand_level",
            poker_hand = "Pair",
            amount = -1,
            level = 1,
            chips = 10,
            mult = 1,
        })
    end)

    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.manacle)
        G.hand.config.card_limit = 7
        local resolution = assert(fixture.capture_play(function()
            G.GAME.blind:defeat()
        end))
        luaunit.assertEquals(resolution[1].effects[1].kind, "capacity")
        luaunit.assertEquals(resolution[1].effects[1].amount, 1)
        luaunit.assertEquals(#resolution[1].effects, 1)
        for _, effect in ipairs(resolution[1].effects) do
            luaunit.assertFalse(effect.kind == "blind_change" and effect.operation == "defeat")
        end
    end)
end

function TestProductionAdapter:test_wall_disable_uses_live_requirement_value()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.wall)
        local resolution = assert(fixture.capture_play(function()
            SMODS.calculate_effect_table_key({
                jokers = {
                    func = function()
                        G.GAME.blind:disable()
                    end,
                },
            }, "jokers", fixture.jokers[1])
        end))
        local effects = resolution[1].effects
        luaunit.assertEquals(effects[1].operation, "disable")
        luaunit.assertEquals(effects[2], {
            order = effects[2].order,
            kind = "blind_change",
            operation = "requirement",
            score_requirement = 200,
        })
        local observation = assert(ProductionBalatroAdapter.new():observe("fair"))
        luaunit.assertEquals(observation.public_state.current_blind.score_requirement, 200)
    end)
end

function TestProductionAdapter:test_flint_ox_and_tooth_record_scoring_and_money_effects()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.flint)
        local resolution = assert(fixture.capture_play(function()
            local hand_mult, hand_chips = G.GAME.blind:modify_hand({}, {}, "Pair", 5, 9)
            luaunit.assertEquals(hand_mult, 3)
            luaunit.assertEquals(hand_chips, 5)
        end))
        luaunit.assertEquals(resolution[1].effects[1].kind, "x_mult")
        luaunit.assertEquals(resolution[1].effects[1].amount, 0.5)
        luaunit.assertEquals(resolution[1].effects[1].mult, 3)
        luaunit.assertEquals(resolution[1].effects[2].kind, "x_chips")
        luaunit.assertEquals(resolution[1].effects[2].amount, 0.5)
        luaunit.assertEquals(resolution[1].effects[2].chips, 5)
        luaunit.assertTrue(resolution[1].effects[1].order < resolution[1].effects[2].order)
    end)

    for _, entry in ipairs({
        {
            key = "ox",
            invoke = function()
                G.GAME.blind:debuff_hand({}, {}, "Pair", false)
            end,
            amount = -6,
            money = 0,
        },
        {
            key = "tooth",
            invoke = function()
                G.GAME.blind:press_play()
            end,
            amount = -1,
            money = 5,
        },
    }) do
        with_blind_fixture(function(fixture)
            fixture.activate(fixture.blinds[entry.key])
            local resolution = assert(fixture.capture_play(entry.invoke))
            luaunit.assertEquals(resolution[1].effects[1].kind, "dollars")
            luaunit.assertEquals(resolution[1].effects[1].amount, entry.amount)
            luaunit.assertEquals(resolution[1].effects[1].money, entry.money)
        end)
    end
end

function TestProductionAdapter:test_normal_play_draw_and_discard_remain_action_mechanics()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.hook)
        luaunit.assertNil(fixture.capture_play(function()
            draw_card(G.deck, G.hand, 100, "up", false, fixture.drawn_card)
            fixture.cards[2].flipping = "f2b"
            fixture.cards[2].sprite_facing = "back"
            G.GAME.chips = G.GAME.blind.chips
        end))
    end)
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.hook)
        luaunit.assertNil(fixture.capture_discard(function() end))
    end)
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.wall)
        luaunit.assertNil(fixture.capture_play(function()
            G.GAME.blind:defeat()
        end))
    end)
end

function TestProductionAdapter:test_eye_and_mouth_record_dynamic_hand_restrictions()
    for _, key in ipairs({ "eye", "mouth" }) do
        with_blind_fixture(function(fixture)
            fixture.activate(fixture.blinds[key])
            local resolution = assert(fixture.capture_play(function()
                luaunit.assertNil(G.GAME.blind:debuff_hand({}, {}, "Pair", false))
            end))
            luaunit.assertEquals(resolution[1].key, fixture.blinds[key].key)
            local effect = resolution[1].effects[1]
            luaunit.assertEquals(effect.kind, "blind_change")
            luaunit.assertEquals(effect.operation, "hand_restriction")
            if key == "eye" then
                luaunit.assertEquals(effect.hand_debuff, {
                    forbidden_poker_hands = { "Pair" },
                })
            else
                luaunit.assertEquals(effect.hand_debuff, { required_poker_hand = "Pair" })
            end
        end)
    end
end

function TestProductionAdapter:test_psychic_and_serpent_record_rules_without_illegal_actions()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.psychic)
        G.GAME.blind.debuff = {}
        local resolution = assert(fixture.capture_play(function()
            G.GAME.blind:set_blind(fixture.blinds.psychic)
        end))
        luaunit.assertEquals(resolution[1].effects[1], {
            order = resolution[1].effects[1].order,
            kind = "blind_change",
            operation = "hand_restriction",
            hand_debuff = { min_cards = 5 },
        })
    end)

    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.serpent)
        local resolution = assert(fixture.capture_play(function()
            G.GAME.current_round.hands_played = 1
            G.FUNCS.draw_from_deck_to_hand()
        end))
        luaunit.assertEquals(fixture.draw_count, 1)
        luaunit.assertEquals(#resolution, 1)
        luaunit.assertEquals(#resolution[1].effects, 1)
        luaunit.assertEquals(resolution[1].effects[1], {
            order = resolution[1].effects[1].order,
            kind = "blind_change",
            operation = "draw_rule",
            cards_per_draw = 3,
        })
    end)

    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.serpent)
        G.GAME.current_round.hands_played = 1
        local resolution = assert(fixture.capture_discard(function()
            G.GAME.current_round.discards_used = 1
            G.FUNCS.draw_from_deck_to_hand()
        end))
        luaunit.assertEquals(resolution[1].effects[1].operation, "draw_rule")
        luaunit.assertEquals(resolution[1].effects[1].cards_per_draw, 3)
    end)

    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.eye)
        local observation = assert(ProductionBalatroAdapter.new():observe("fair"))
        for _, action in ipairs(observation.public_state.legal_actions) do
            if action.tool == "play_hand" then
                luaunit.assertEquals(action.arguments.card_ids.max_items, 3)
            end
        end
    end)
end

function TestProductionAdapter:test_debuffs_and_cerulean_forced_selection_use_card_state_effects()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.club)
        local resolution = assert(fixture.capture_play(function()
            G.GAME.blind:debuff_card(G.hand.cards[1])
        end))
        luaunit.assertEquals(resolution[1].effects, {
            {
                order = resolution[1].effects[1].order,
                kind = "set_card_state",
                input_target_id = "card:2",
                state = "debuffed",
                value = true,
            },
        })
    end)

    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.club)
        local resolution = assert(fixture.capture_play(function()
            G.GAME.blind:debuff_card(fixture.drawn_card)
        end))
        luaunit.assertEquals(resolution[1].effects[1].state, "debuffed")
        luaunit.assertTrue(resolution[1].effects[1].value)
        luaunit.assertNil(resolution[1].effects[1].input_target_id)
    end)

    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.heart)
        local resolution = assert(fixture.capture_play(function()
            G.GAME.blind:drawn_to_hand()
        end))
        luaunit.assertEquals(resolution[1].effects[1].input_target_id, "joker:11")
        luaunit.assertEquals(resolution[1].effects[1].state, "debuffed")
        luaunit.assertTrue(resolution[1].effects[1].value)
    end)

    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.bell)
        local resolution = assert(fixture.capture_play(function()
            G.GAME.blind:drawn_to_hand()
        end))
        luaunit.assertEquals(resolution[1].key, "bl_final_bell")
        luaunit.assertEquals(resolution[1].effects[1].input_target_id, "card:2")
        luaunit.assertEquals(resolution[1].effects[1].state, "forced_selection")
        luaunit.assertTrue(resolution[1].effects[1].value)
    end)
end

function TestProductionAdapter:test_invalid_dynamic_hands_emit_blind_debuff_events()
    for _, entry in ipairs({
        {
            key = "eye",
            prepare = function(blind)
                blind.hands.Pair = true
            end,
            cards = { 1, 2, 3, 4, 5 },
            hand = "Pair",
        },
        {
            key = "mouth",
            prepare = function(blind)
                blind.only_hand = "Pair"
            end,
            cards = { 1, 2, 3, 4, 5 },
            hand = "Flush",
        },
        {
            key = "psychic",
            prepare = function(_blind) end,
            cards = { 1, 2, 3, 4 },
            hand = "Pair",
        },
    }) do
        with_blind_fixture(function(fixture)
            fixture.activate(fixture.blinds[entry.key])
            entry.prepare(G.GAME.blind)
            local resolution = assert(fixture.capture_play(function()
                luaunit.assertTrue(G.GAME.blind:debuff_hand(entry.cards, {}, entry.hand, false))
            end))
            luaunit.assertEquals(#resolution, 2)
            luaunit.assertEquals(resolution[1].type, "apply")
            luaunit.assertEquals(resolution[1].component, "blind")
            luaunit.assertEquals(resolution[2], {
                order = resolution[2].order,
                phase = "debuffed_hand",
                type = "debuff_blocked",
                component = "blind",
                source = {
                    input_target_id = "blind:Boss:" .. fixture.blinds[entry.key].key,
                },
                parent_order = resolution[1].order,
                effects = {},
            })
        end)
    end
end

function TestProductionAdapter:test_debuffed_hand_joker_effects_follow_blind_block_event()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.eye)
        G.GAME.blind.hands.Pair = true
        local resolution = assert(fixture.capture_play(function()
            luaunit.assertTrue(G.GAME.blind:debuff_hand({}, {}, "Pair", false))
            SMODS.context_stack = { { context = { debuffed_hand = true } } }
            SMODS.calculate_effect_table_key({
                jokers = {
                    func = function()
                        ease_dollars(-1)
                    end,
                },
            }, "jokers", fixture.jokers[1])
            SMODS.context_stack = {}
        end))
        luaunit.assertEquals(#resolution, 3)
        local blocked = resolution[2]
        local joker = resolution[3]
        luaunit.assertEquals(blocked.type, "debuff_blocked")
        luaunit.assertEquals(joker.type, "trigger")
        luaunit.assertEquals(joker.phase, "debuffed_hand")
        luaunit.assertEquals(joker.parent_order, blocked.order)
        luaunit.assertEquals(joker.effects[1].kind, "dollars")
        luaunit.assertTrue(blocked.order < joker.order)
        luaunit.assertTrue(joker.order < joker.effects[1].order)
    end)
end

function TestProductionAdapter:test_verdant_leaf_async_disable_opens_blind_application()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.leaf)
        fixture.cards[2].debuff = true
        local resolution = assert(fixture.capture_play(function()
            G.E_MANAGER:add_event(Event({
                func = function()
                    G.GAME.blind:disable()
                    return true
                end,
            }))
        end))
        luaunit.assertEquals(#resolution, 1)
        luaunit.assertEquals(resolution[1].component, "blind")
        luaunit.assertEquals(resolution[1].key, "bl_final_leaf")
        luaunit.assertEquals(resolution[1].effects[1].operation, "disable")
        luaunit.assertEquals(resolution[1].effects[2].input_target_id, "card:2")
        luaunit.assertEquals(resolution[1].effects[2].state, "debuffed")
        luaunit.assertFalse(resolution[1].effects[2].value)
    end)
end

function TestProductionAdapter:test_blind_disable_cleanup_stays_on_parent_joker_timeline()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.bell)
        fixture.cards[2].ability.forced_selection = true
        fixture.cards[2].debuff = true
        fixture.jokers[2].debuff = true
        fixture.jokers[2].facing = "back"
        local resolution = assert(fixture.capture_play(function()
            SMODS.calculate_effect_table_key({
                jokers = {
                    func = function()
                        G.GAME.blind:disable()
                    end,
                },
            }, "jokers", fixture.jokers[1])
        end))
        luaunit.assertEquals(#resolution, 1)
        local event = resolution[1]
        luaunit.assertEquals(event.component, "joker")
        luaunit.assertEquals(event.source, { input_target_id = "joker:11" })
        luaunit.assertEquals(event.effects[1].kind, "blind_change")
        luaunit.assertEquals(event.effects[1].operation, "disable")
        local states = {}
        for _, effect in ipairs(event.effects) do
            if effect.kind == "set_card_state" then
                states[(effect.input_target_id or "anonymous") .. ":" .. effect.state] =
                    effect.value
                luaunit.assertTrue(event.effects[1].order < effect.order)
            end
        end
        luaunit.assertFalse(states["joker:12:facedown"])
        luaunit.assertFalse(states["card:2:forced_selection"])
        luaunit.assertFalse(states["card:2:debuffed"])
        luaunit.assertFalse(states["joker:12:debuffed"])
    end)
end

function TestProductionAdapter:test_post_selection_draw_keeps_mechanics_outside_hand_blind_effect()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.wheel)
        G.GAME.current_round.hands_left = 1
        G.GAME.current_round.discards_left = 0
        local resolution = assert(fixture.capture_select(function()
            G.GAME.current_round.hands_left = 4
            G.GAME.current_round.discards_left = 3
            draw_card(G.deck, G.hand, 100, "up", false, fixture.drawn_card)
        end))
        luaunit.assertEquals(#resolution, 1)
        luaunit.assertEquals(resolution[1].phase, "hand")
        luaunit.assertNil(resolution[1].parent_order)
        luaunit.assertEquals(resolution[1].effects[1].state, "facedown")
        for _, effect in ipairs(resolution[1].effects) do
            luaunit.assertNotEquals(effect.kind, "create")
            luaunit.assertNotEquals(effect.kind, "round_allowance")
        end
    end)
end

function TestProductionAdapter:test_nested_blind_debuff_keeps_changed_card_source_and_order()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.club)
        fixture.cards[2].base.suit = "Hearts"
        local resolution = assert(fixture.capture_play(function()
            SMODS.calculate_effect_table_key({
                jokers = {
                    func = function()
                        G.hand.cards[1]:set_base({ suit = "Spades", value = "King" })
                    end,
                },
            }, "jokers", fixture.jokers[1])
        end))
        luaunit.assertEquals(#resolution, 2)
        local joker = resolution[1]
        local blind = resolution[2]
        luaunit.assertEquals(joker.component, "joker")
        luaunit.assertEquals(joker.effects, {
            {
                order = joker.effects[1].order,
                kind = "set_card_state",
                input_target_id = "card:2",
                state = "suit",
                value = "Spades",
            },
        })
        luaunit.assertEquals(blind.component, "blind")
        luaunit.assertEquals(blind.parent_order, joker.order)
        luaunit.assertEquals(blind.effects, {
            {
                order = blind.effects[1].order,
                kind = "set_card_state",
                input_target_id = "card:2",
                state = "debuffed",
                value = true,
            },
        })
        luaunit.assertTrue(joker.order < joker.effects[1].order)
        luaunit.assertTrue(joker.effects[1].order < blind.order)
        luaunit.assertTrue(blind.order < blind.effects[1].order)
    end)
end

function TestProductionAdapter:test_consumable_parent_survives_nested_blind_application()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.club)
        fixture.cards[2].base.suit = "Hearts"
        local tarot = fixture.new_consumable()
        tarot.sort_id = 31
        tarot.area = G.consumeables
        G.consumeables.cards = { tarot }
        local adapter = ProductionBalatroAdapter.new()
        local context = adapter:_begin_resolution({
            name = "use_consumable",
            visibility = "fair",
            targets = { consumable_id = "consumable:31" },
        })
        adapter:_with_application(tarot, function()
            fixture.cards[2]:set_base({ suit = "Spades", value = "King" })
        end)
        context.pending_consumable_application = context.latest_application_event
        SMODS.context_stack = { { context = { using_consumeable = true } } }
        SMODS.calculate_effect_table_key({
            jokers = {
                func = function()
                    ease_dollars(1)
                end,
            },
        }, "jokers", fixture.jokers[1])
        SMODS.context_stack = {}
        local resolution, resolution_error = adapter:finish_resolution(context)
        luaunit.assertNil(resolution_error)
        assert_resolution_matches_announced_schema(resolution, "use_consumable")
        luaunit.assertNotNil(resolution)
        ---@cast resolution table
        luaunit.assertEquals(#resolution, 3)
        local tarot_event = resolution[1]
        local blind_event = resolution[2]
        local joker_event = resolution[3]
        luaunit.assertEquals(tarot_event.component, "tarot")
        luaunit.assertEquals(tarot_event.source, { input_target_id = "consumable:31" })
        luaunit.assertEquals(blind_event.component, "blind")
        luaunit.assertEquals(blind_event.parent_order, tarot_event.order)
        luaunit.assertEquals(joker_event.component, "joker")
        luaunit.assertEquals(joker_event.parent_order, tarot_event.order)
        luaunit.assertEquals(joker_event.effects[1].kind, "dollars")
    end)
end

function TestProductionAdapter:test_created_cards_receive_anonymous_child_blind_debuffs()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.leaf)
        local resolution = assert(fixture.capture_play(function()
            SMODS.calculate_effect_table_key({
                jokers = {
                    func = function()
                        local created = fixture.new_card()
                        G.play:emplace(created)
                        G.playing_cards[#G.playing_cards + 1] = created
                        G.GAME.blind:debuff_card(created)
                    end,
                },
            }, "jokers", fixture.jokers[1])
        end))
        luaunit.assertEquals(#resolution, 2)
        luaunit.assertEquals(resolution[1].component, "joker")
        luaunit.assertEquals(resolution[1].effects[1].kind, "create")
        luaunit.assertEquals(resolution[2].component, "blind")
        luaunit.assertEquals(resolution[2].parent_order, resolution[1].order)
        luaunit.assertEquals(resolution[2].effects[1].kind, "set_card_state")
        luaunit.assertEquals(resolution[2].effects[1].state, "debuffed")
        luaunit.assertTrue(resolution[2].effects[1].value)
        luaunit.assertNil(resolution[2].effects[1].input_target_id)
    end)
end

function TestProductionAdapter:test_wheel_house_fish_and_mark_record_persistent_facedown_without_identity()
    for _, key in ipairs({ "wheel", "house", "fish", "mark" }) do
        with_blind_fixture(function(fixture)
            fixture.activate(fixture.blinds[key])
            local resolution = assert(fixture.capture_play(function()
                luaunit.assertTrue(G.GAME.blind:stay_flipped(G.hand, fixture.drawn_card))
            end))
            luaunit.assertEquals(#resolution, 1)
            luaunit.assertEquals(resolution[1].key, fixture.blinds[key].key)
            luaunit.assertEquals(resolution[1].effects, {
                {
                    order = resolution[1].effects[1].order,
                    kind = "set_card_state",
                    state = "facedown",
                    value = true,
                },
            })
            luaunit.assertNil(resolution[1].effects[1].input_target_id)
        end)
    end
end

function TestProductionAdapter:test_hook_move_order_follows_earlier_queued_content()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.hook)
        fixture.before_hook_move = function()
            ease_dollars(-1)
        end
        local resolution = assert(fixture.capture_play(function()
            G.GAME.blind:press_play()
        end))
        luaunit.assertEquals(resolution[1].effects[1].kind, "dollars")
        luaunit.assertEquals(resolution[1].effects[2].kind, "move_card")
        luaunit.assertTrue(resolution[1].effects[1].order < resolution[1].effects[2].order)
    end)
end

function TestProductionAdapter:test_hook_purple_seal_keeps_component_parent_and_move_order()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.hook)
        fixture.cards[2].seal = "Purple"
        local resolution = assert(fixture.capture_play(function()
            G.GAME.blind:press_play()
        end))
        luaunit.assertEquals(#resolution, 2)
        local hook = resolution[1]
        local seal = resolution[2]
        luaunit.assertEquals(hook.component, "blind")
        luaunit.assertEquals(seal.component, "seal")
        luaunit.assertEquals(seal.source, { input_target_id = "card:2" })
        luaunit.assertEquals(seal.parent_order, hook.order)
        luaunit.assertEquals(seal.effects[1].kind, "create")
        luaunit.assertEquals(seal.effects[1].object_kind, "consumable")
        luaunit.assertEquals(hook.effects[1].kind, "move_card")
        luaunit.assertTrue(seal.effects[1].order < hook.effects[1].order)
    end)
end

function TestProductionAdapter:test_amber_acorn_records_hidden_jokers_and_anonymous_shuffle()
    with_blind_fixture(function(fixture)
        fixture.activate(fixture.blinds.acorn)
        local resolution = assert(fixture.capture_play(function()
            G.GAME.blind:set_blind(fixture.blinds.acorn)
        end))
        luaunit.assertEquals(#resolution, 1)
        luaunit.assertEquals(resolution[1].key, "bl_final_acorn")
        luaunit.assertEquals(resolution[1].effects[1].kind, "set_card_state")
        luaunit.assertEquals(resolution[1].effects[1].input_target_id, "joker:11")
        luaunit.assertEquals(resolution[1].effects[1].state, "facedown")
        luaunit.assertTrue(resolution[1].effects[1].value)
        luaunit.assertEquals(resolution[1].effects[2].kind, "set_card_state")
        luaunit.assertEquals(resolution[1].effects[2].input_target_id, "joker:12")
        luaunit.assertEquals(resolution[1].effects[3], {
            order = resolution[1].effects[3].order,
            kind = "reorder",
            area = "jokers",
            method = "shuffle",
        })
        luaunit.assertNil(resolution[1].effects[3].ordered_ids)
        luaunit.assertNil(resolution[1].effects[3].input_target_ids)
        luaunit.assertEquals(#resolution[1].effects, 3)
    end)
end

function TestProductionAdapter:test_hook_records_forced_discards_as_moves_only()
    with_blind_fixture(function(fixture)
        local resolution = assert(fixture.capture_play(function()
            G.GAME.blind:press_play()
        end))
        luaunit.assertEquals(#resolution, 1)
        luaunit.assertEquals(resolution[1].component, "blind")
        luaunit.assertEquals(resolution[1].key, "bl_hook")
        luaunit.assertEquals(resolution[1].source, {
            input_target_id = "blind:Boss:bl_hook",
        })
        luaunit.assertEquals(resolution[1].effects, {
            {
                order = resolution[1].effects[1].order,
                kind = "move_card",
                input_target_id = "card:2",
                from_zone = "hand",
                to_zone = "discard",
            },
            {
                order = resolution[1].effects[2].order,
                kind = "move_card",
                input_target_id = "card:3",
                from_zone = "hand",
                to_zone = "discard",
            },
        })
        for _, effect in ipairs(resolution[1].effects) do
            luaunit.assertNotEquals(effect.kind, "destroy")
        end
    end)
end

local function lifecycle_event_by_source(resolution, source)
    for _, event in ipairs(resolution or {}) do
        if event.source and event.source.input_target_id == source then
            return event
        end
    end
end

function TestProductionAdapter:test_lifecycle_shop_and_booster_contexts_record_content_only()
    with_lifecycle_joker_fixture(function(fixture)
        local hallucination = fixture.joker("Hallucination", 11)
        hallucination.facing = "back"
        local opened = assert(fixture.capture_open({ hallucination }))
        luaunit.assertEquals(#opened, 1)
        luaunit.assertEquals(opened[1].phase, "shop")
        luaunit.assertEquals(opened[1].component, "joker")
        luaunit.assertEquals(opened[1].source, { input_target_id = "joker:11" })
        luaunit.assertNil(opened[1].key)
        luaunit.assertEquals(opened[1].effects[1].kind, "create")
        luaunit.assertEquals(opened[1].effects[1].object_kind, "consumable")
        luaunit.assertEquals(opened[1].effects[1].destination, "owned")
        for _, effect in ipairs(opened[1].effects) do
            luaunit.assertNotEquals(effect.kind, "open_booster")
        end

        local flash = fixture.joker("Flash Card", 12, { mult = 0, extra = 2 })
        local rerolled = assert(fixture.capture({ flash }, {}, function()
            SMODS.calculate_context({ reroll_shop = true })
        end))
        luaunit.assertEquals(rerolled[1].phase, "shop")
        luaunit.assertEquals(rerolled[1].effects[1], {
            order = rerolled[1].effects[1].order,
            kind = "card_progress",
            resource = "mult",
            amount = 2,
            value = 2,
        })

        local shop_hologram = fixture.joker("Hologram", 13, { x_mult = 1, extra = 0.25 })
        local shop_added = assert(fixture.capture_shop_added({ shop_hologram }))
        luaunit.assertEquals(shop_added[1].phase, "shop")
        luaunit.assertEquals(shop_added[1].source, { input_target_id = "joker:13" })
        luaunit.assertEquals(shop_added[1].effects[1].resource, "x_mult")

        local red = fixture.joker("Red Card", 14, { mult = 0, extra = 3 })
        local skipped = assert(fixture.capture({ red }, {}, function()
            SMODS.calculate_context({ skipping_booster = true })
        end))
        luaunit.assertEquals(skipped[1].phase, "booster")
        luaunit.assertEquals(skipped[1].effects[1].resource, "mult")

        local perkeo = fixture.joker("Perkeo", 15)
        local source = fixture.consumable("c_fool", 21)
        local copied = assert(fixture.capture({ perkeo }, { source }, function()
            SMODS.calculate_context({ ending_shop = true })
        end))
        luaunit.assertEquals(copied[1].phase, "shop")
        luaunit.assertEquals(copied[1].effects[1], {
            order = copied[1].effects[1].order,
            kind = "copy",
            mode = "create",
            source = { input_target_id = "consumable:21" },
            object_kind = "consumable",
            destination = "owned",
            key = "c_fool",
            edition = "e_negative",
        })
        luaunit.assertNil(copied[1].effects[1].input_target_id)
    end)
end

function TestProductionAdapter:test_selling_jokers_record_effects_without_self_destroy()
    with_lifecycle_joker_fixture(function(fixture)
        local function assert_no_self_destroy(resolution, source)
            for _, event in ipairs(resolution or {}) do
                for _, effect in ipairs(event.effects or {}) do
                    luaunit.assertFalse(
                        effect.kind == "destroy" and effect.input_target_id == source
                    )
                end
            end
        end

        local luchador = fixture.joker("Luchador", 11)
        local disabled = assert(fixture.capture_sell({ luchador }, luchador))
        luaunit.assertEquals(disabled[1].phase, "hand")
        luaunit.assertEquals(disabled[1].effects[1].kind, "blind_change")
        luaunit.assertEquals(disabled[1].effects[1].operation, "disable")
        assert_no_self_destroy(disabled, "joker:11")

        local cola = fixture.joker("Diet Cola", 12)
        local tagged = assert(fixture.capture_sell({ cola }, cola, G.STATES.SHOP))
        luaunit.assertEquals(tagged[1].phase, "shop")
        luaunit.assertEquals(tagged[1].effects[1].kind, "tag_change")
        luaunit.assertEquals(tagged[1].effects[1].key, "tag_double")
        assert_no_self_destroy(tagged, "joker:12")

        local invisible = fixture.joker("Invisible Joker", 13)
        local target = fixture.joker("Flash Card", 14, { mult = 4, extra = 2 })
        local copied =
            assert(fixture.capture_sell({ invisible, target }, invisible, G.STATES.BLIND_SELECT))
        local invisible_event = assert(lifecycle_event_by_source(copied, "joker:13"))
        luaunit.assertEquals(invisible_event.phase, "blind_selection")
        luaunit.assertEquals(invisible_event.effects[1].kind, "copy")
        luaunit.assertEquals(invisible_event.effects[1].source, {
            input_target_id = "joker:14",
        })
        luaunit.assertNil(invisible_event.effects[1].input_target_id)
        assert_no_self_destroy(copied, "joker:13")

        local sold = fixture.joker("Diet Cola", 15)
        local campfire = fixture.joker("Campfire", 16, { x_mult = 1, extra = 0.25 })
        local grown = assert(fixture.capture_sell({ sold, campfire }, sold))
        local campfire_event = assert(lifecycle_event_by_source(grown, "joker:16"))
        luaunit.assertEquals(campfire_event.effects[1].resource, "x_mult")
        luaunit.assertEquals(campfire_event.effects[1].amount, 0.25)
        luaunit.assertEquals(campfire_event.effects[1].value, 1.25)
    end)
end

function TestProductionAdapter:test_setting_blind_jokers_keep_source_parent_and_effect_order()
    with_lifecycle_joker_fixture(function(fixture)
        local chicot = fixture.joker("Chicot", 11)
        local madness = fixture.joker("Madness", 12, { x_mult = 1, extra = 0.5 })
        local madness_target = fixture.joker("Flash Card", 13, { mult = 0, extra = 2 })
        madness.destroy_target = madness_target
        local burglar = fixture.joker("Burglar", 14, { extra = 3 })
        local riff = fixture.joker("Riff-raff", 15)
        local cartomancer = fixture.joker("Cartomancer", 16)
        local dagger = fixture.joker("Ceremonial Dagger", 17, { mult = 0 })
        local dagger_target = fixture.joker("Flash Card", 18, { mult = 0, extra = 2 })
        dagger_target.sell_cost = 4
        dagger.destroy_target = dagger_target
        local marble = fixture.joker("Marble Joker", 19)
        local hologram = fixture.joker("Hologram", 20, { x_mult = 1, extra = 0.25 })
        local jokers = {
            chicot,
            madness,
            madness_target,
            burglar,
            riff,
            cartomancer,
            dagger,
            dagger_target,
            marble,
            hologram,
        }
        local resolution = assert(fixture.capture(jokers, {}, function()
            SMODS.calculate_context({ setting_blind = true, blind = { boss = true } })
        end))

        local chicot_event = assert(lifecycle_event_by_source(resolution, "joker:11"))
        luaunit.assertEquals(chicot_event.phase, "blind_selection")
        luaunit.assertEquals(chicot_event.effects[1].operation, "disable")

        local madness_event = assert(lifecycle_event_by_source(resolution, "joker:12"))
        luaunit.assertEquals(madness_event.effects[1].kind, "card_progress")
        luaunit.assertEquals(madness_event.effects[2].kind, "destroy")
        luaunit.assertEquals(madness_event.effects[2].input_target_id, "joker:13")
        luaunit.assertTrue(madness_event.effects[1].order < madness_event.effects[2].order)

        local burglar_event = assert(lifecycle_event_by_source(resolution, "joker:14"))
        luaunit.assertEquals(burglar_event.effects[1].resource, "discards")
        luaunit.assertEquals(burglar_event.effects[1].amount, -3)
        luaunit.assertEquals(burglar_event.effects[2].resource, "hands")
        luaunit.assertEquals(burglar_event.effects[2].amount, 3)
        luaunit.assertTrue(burglar_event.effects[1].order < burglar_event.effects[2].order)

        local riff_event = assert(lifecycle_event_by_source(resolution, "joker:15"))
        luaunit.assertEquals(#riff_event.effects, 2)
        luaunit.assertEquals(riff_event.effects[1].object_kind, "joker")
        luaunit.assertEquals(riff_event.effects[2].object_kind, "joker")

        local cartomancer_event = assert(lifecycle_event_by_source(resolution, "joker:16"))
        luaunit.assertEquals(cartomancer_event.effects[1].object_kind, "consumable")

        local dagger_event = assert(lifecycle_event_by_source(resolution, "joker:17"))
        luaunit.assertEquals(dagger_event.effects[1].kind, "card_progress")
        luaunit.assertEquals(dagger_event.effects[1].resource, "mult")
        luaunit.assertEquals(dagger_event.effects[1].value, 8)
        luaunit.assertEquals(dagger_event.effects[2].kind, "destroy")
        luaunit.assertEquals(dagger_event.effects[2].input_target_id, "joker:18")
        luaunit.assertTrue(dagger_event.effects[1].order < dagger_event.effects[2].order)

        local marble_event = assert(lifecycle_event_by_source(resolution, "joker:19"))
        luaunit.assertEquals(marble_event.effects[1].kind, "create")
        luaunit.assertEquals(marble_event.effects[1].object_kind, "playing_card")
        luaunit.assertEquals(marble_event.effects[1].destination, "permanent_deck")
        luaunit.assertEquals(marble_event.effects[1].enhancement, "m_stone")

        local hologram_event = assert(lifecycle_event_by_source(resolution, "joker:20"))
        luaunit.assertEquals(hologram_event.phase, "blind_selection")
        luaunit.assertEquals(hologram_event.parent_order, marble_event.order)
        luaunit.assertEquals(hologram_event.effects[1].kind, "card_progress")
        luaunit.assertEquals(hologram_event.effects[1].resource, "x_mult")
    end)
end

function TestProductionAdapter:test_first_hand_created_card_carries_seal_and_child_hologram_source()
    with_lifecycle_joker_fixture(function(fixture)
        local certificate = fixture.joker("Certificate", 11)
        local hologram = fixture.joker("Hologram", 12, { x_mult = 1, extra = 0.25 })
        local resolution = assert(fixture.capture({ certificate, hologram }, {}, function()
            SMODS.calculate_context({ first_hand_drawn = true })
        end))
        local certificate_event = assert(lifecycle_event_by_source(resolution, "joker:11"))
        local hologram_event = assert(lifecycle_event_by_source(resolution, "joker:12"))
        luaunit.assertEquals(certificate_event.phase, "hand")
        luaunit.assertEquals(certificate_event.effects[1].kind, "create")
        luaunit.assertEquals(certificate_event.effects[1].destination, "permanent_deck")
        luaunit.assertEquals(certificate_event.effects[1].rank, "Ace")
        luaunit.assertEquals(certificate_event.effects[1].suit, "Spades")
        luaunit.assertEquals(certificate_event.effects[1].seal, "Red")
        luaunit.assertEquals(hologram_event.phase, "hand")
        luaunit.assertEquals(hologram_event.parent_order, certificate_event.order)
        luaunit.assertEquals(hologram_event.source, { input_target_id = "joker:12" })
        luaunit.assertNil(hologram_event.effects[1].input_target_id)

        local dna = fixture.joker("DNA", 13)
        local trading = fixture.joker("Trading Card", 14)
        luaunit.assertNil(fixture.capture({ dna, trading }, {}, function()
            SMODS.calculate_context({ first_hand_drawn = true })
        end))
    end)
end

function TestProductionAdapter:test_throwback_progress_uses_blind_selection_phase()
    with_lifecycle_joker_fixture(function(fixture)
        local throwback = fixture.joker("Throwback", 11, { x_mult = 1, extra = 0.25 })
        local resolution = assert(fixture.capture({ throwback }, {}, function()
            G.GAME.skips = G.GAME.skips + 1
            SMODS.calculate_context({ skip_blind = true })
        end))
        luaunit.assertEquals(resolution[1].phase, "blind_selection")
        luaunit.assertEquals(resolution[1].effects[1], {
            order = resolution[1].effects[1].order,
            kind = "card_progress",
            resource = "x_mult",
            amount = 0.25,
            value = 1.25,
        })

        local blueprint = fixture.joker("Blueprint", 12)
        local copied_throwback = fixture.joker("Throwback", 13, { x_mult = 1, extra = 0.25 })
        blueprint.copy_target = copied_throwback
        local copied_resolution =
            assert(fixture.capture({ blueprint, copied_throwback }, {}, function()
                G.GAME.skips = G.GAME.skips + 1
                SMODS.calculate_context({ skip_blind = true })
            end))
        luaunit.assertEquals(#copied_resolution, 1)
        luaunit.assertEquals(copied_resolution[1].source, { input_target_id = "joker:13" })
        luaunit.assertEquals(copied_resolution[1].effects[1].kind, "card_progress")
    end)
end

function TestProductionAdapter:test_explicit_skip_and_boss_reroll_do_not_duplicate_content_effects()
    with_tag_fixture(function(fixture)
        local function option(slot)
            return {
                get_UIE_by_ID = function(_, id)
                    if id == "tag_" .. slot then
                        return { children = { nil, { config = { button = "skip_blind" } } } }
                    end
                end,
            }
        end
        G.STATE = G.STATES.BLIND_SELECT
        G.blind_select = { VT = { y = 0 } }
        G.blind_prompt_box = {}
        G.blind_select_opts = {
            small = option("Small"),
            boss = option("Boss"),
        }
        G.GAME.blind_on_deck = "Small"
        G.GAME.bankrupt_at = 0
        G.GAME.dollars = 20
        G.GAME.round_resets.blind_choices = {
            Small = "bl_small",
            Boss = "bl_head",
        }
        G.GAME.round_resets.blind_states = {
            Small = "Select",
            Boss = "Upcoming",
        }
        G.GAME.round_resets.blind_tags = { Small = "tag_rare" }
        G.P_BLINDS.bl_head = { key = "bl_head", name = "The Head", dollars = 5, mult = 2 }
        G.P_BLINDS.bl_hook = { key = "bl_hook", name = "The Hook", dollars = 5, mult = 2 }
        G.P_TAGS.tag_rare = { key = "tag_rare", name = "Rare Tag", config = {} }
        G.FUNCS = {
            skip_blind = function()
                add_tag(fixture.tag("tag_rare"))
                G.GAME.blind_on_deck = "Boss"
            end,
        }

        local skip_adapter = ProductionBalatroAdapter.new()
        local skip, skip_error = skip_adapter:execute({
            name = "skip_blind",
            expected_state_hash = "sha256:test",
            visibility = "fair",
            arguments = {},
            targets = { blind_id = "blind:Small:bl_small" },
        })
        luaunit.assertNil(skip_error)
        luaunit.assertNotNil(skip)
        ---@cast skip table
        local skip_resolution, skip_capture_error =
            skip_adapter:finish_resolution(skip.resolution_context)
        luaunit.assertNil(skip_capture_error)
        luaunit.assertNil(skip_resolution)
        luaunit.assertEquals(#G.GAME.tags, 1)

        G.GAME.used_vouchers.v_retcon = true
        G.FUNCS.reroll_boss = function()
            G.GAME.round_resets.blind_choices.Boss = get_new_boss()
        end
        local reroll_adapter = ProductionBalatroAdapter.new()
        local reroll, reroll_error = reroll_adapter:execute({
            name = "reroll_boss",
            expected_state_hash = "sha256:test",
            visibility = "fair",
            arguments = {},
            targets = {},
        })
        luaunit.assertNil(reroll_error)
        luaunit.assertNotNil(reroll)
        ---@cast reroll table
        local reroll_resolution, reroll_capture_error =
            reroll_adapter:finish_resolution(reroll.resolution_context)
        luaunit.assertNil(reroll_capture_error)
        luaunit.assertNil(reroll_resolution)
        luaunit.assertEquals(G.GAME.round_resets.blind_choices.Boss, "bl_hook")
    end)
end

function TestProductionAdapter:test_double_tag_records_copy_and_consumption_without_target_ids()
    with_tag_fixture(function(fixture)
        local double = fixture.tag("tag_double")
        G.GAME.tags = { double }
        fixture.apply_tag = function(tag, context)
            if tag == double and context.type == "tag_add" and not tag.triggered then
                tag.triggered = true
                G.E_MANAGER:add_event({
                    func = function()
                        add_tag(fixture.tag(context.tag.key))
                        return true
                    end,
                })
                G.E_MANAGER:add_event({
                    func = function()
                        tag:remove_from_game()
                        return true
                    end,
                })
                return true
            end
        end

        local resolution = assert(fixture.capture(function()
            add_tag(fixture.tag("tag_rare"))
        end))
        luaunit.assertEquals(#resolution, 1)
        luaunit.assertEquals(resolution[1].type, "apply")
        luaunit.assertEquals(resolution[1].component, "tag")
        luaunit.assertEquals(resolution[1].key, "tag_double")
        luaunit.assertNil(resolution[1].source)
        luaunit.assertEquals(resolution[1].effects, {
            {
                order = resolution[1].effects[1].order,
                kind = "tag_change",
                operation = "add",
                key = "tag_rare",
                quantity = 1,
            },
            {
                order = resolution[1].effects[2].order,
                kind = "tag_change",
                operation = "consume",
                key = "tag_double",
                quantity = 1,
            },
        })
        luaunit.assertTrue(resolution[1].order < resolution[1].effects[1].order)
        luaunit.assertTrue(resolution[1].effects[1].order < resolution[1].effects[2].order)
        luaunit.assertNil(resolution[1].effects[1].input_target_id)
        luaunit.assertNil(resolution[1].effects[2].input_target_id)
    end)
end

function TestProductionAdapter:test_tag_add_effect_precedes_tag_added_child_trigger()
    with_tag_fixture(function(fixture)
        local joker = {
            sort_id = 11,
            facing = "front",
            ability = { set = "Joker", name = "Tag Added Joker" },
            config = { center = { key = "j_tag_added", set = "Joker" } },
            area = G.jokers,
        }
        G.jokers.cards = { joker }
        _G.hand_chips = 5
        _G.mult = 1
        SMODS.context_stack = {}
        SMODS.calculate_individual_effect = function(_effect, _card, key, amount, _from_edition)
            if key == "mult" then
                _G.mult = _G.mult + amount
            end
            return true
        end
        SMODS.calculate_effect_table_key = function(effect_table, key, card)
            local effect = effect_table[key]
            return SMODS.calculate_individual_effect(effect, card, "mult", effect.mult)
        end
        SMODS.calculate_context = function(context)
            if context.tag_added and context.tag_added.copied then
                SMODS.calculate_effect_table_key({ jokers = { mult = 2 } }, "jokers", joker)
            end
        end

        local double = fixture.tag("tag_double")
        G.GAME.tags = { double }
        fixture.apply_tag = function(tag, context)
            if tag == double and context.type == "tag_add" and not tag.triggered then
                tag.triggered = true
                G.E_MANAGER:add_event({
                    func = function()
                        add_tag(fixture.tag(context.tag.key, { copied = true }))
                        return true
                    end,
                })
                G.E_MANAGER:add_event({
                    func = function()
                        tag:remove_from_game()
                        return true
                    end,
                })
                return true
            end
        end

        local resolution = assert(fixture.capture(function()
            add_tag(fixture.tag("tag_rare"))
        end))
        luaunit.assertEquals(#resolution, 2)
        luaunit.assertEquals(resolution[1].component, "tag")
        luaunit.assertEquals(resolution[2].component, "joker")
        luaunit.assertEquals(resolution[2].parent_order, resolution[1].order)
        luaunit.assertTrue(resolution[1].effects[1].order < resolution[2].order)
        luaunit.assertEquals(resolution[1].effects[1].kind, "tag_change")
        luaunit.assertEquals(resolution[2].effects[1].kind, "mult")
    end)
end

function TestProductionAdapter:test_tag_triggered_child_and_async_parent_effects_keep_global_order()
    with_tag_fixture(function(fixture)
        local joker = {
            sort_id = 11,
            facing = "front",
            ability = { set = "Joker", name = "Tag Joker" },
            config = { center = { key = "j_tag_joker", set = "Joker" } },
            area = G.jokers,
        }
        G.jokers.cards = { joker }
        _G.hand_chips = 5
        _G.mult = 1
        SMODS.context_stack = {}
        SMODS.calculate_individual_effect = function(_effect, _card, key, amount, _from_edition)
            if key == "mult" then
                _G.mult = _G.mult + amount
            end
            return true
        end
        SMODS.calculate_effect_table_key = function(effect_table, key, card)
            local effect = effect_table[key]
            return SMODS.calculate_individual_effect(effect, card, "mult", effect.mult)
        end

        local tag = fixture.tag("tag_skip")
        G.GAME.tags = { tag }
        fixture.apply_tag = function(current, context)
            if current == tag and context.type == "immediate" and not current.triggered then
                current.triggered = true
                SMODS.calculate_effect_table_key({ jokers = { mult = 2 } }, "jokers", joker)
                G.E_MANAGER:add_event({
                    func = function()
                        ease_dollars(3)
                        return true
                    end,
                })
                G.E_MANAGER:add_event({
                    func = function()
                        current:remove_from_game()
                        return true
                    end,
                })
                return true
            end
        end

        local resolution = assert(fixture.capture(function()
            tag:apply_to_run({ type = "immediate" })
        end))
        luaunit.assertEquals(#resolution, 2)
        luaunit.assertEquals(resolution[1].order, 1)
        luaunit.assertEquals(resolution[1].component, "tag")
        luaunit.assertEquals(resolution[1].key, "tag_skip")
        luaunit.assertEquals(resolution[2].order, 2)
        luaunit.assertEquals(resolution[2].type, "trigger")
        luaunit.assertEquals(resolution[2].component, "joker")
        luaunit.assertEquals(resolution[2].source, { input_target_id = "joker:11" })
        luaunit.assertEquals(resolution[2].parent_order, 1)
        luaunit.assertEquals(resolution[2].effects[1].order, 3)
        luaunit.assertEquals(resolution[2].effects[1].kind, "mult")
        luaunit.assertEquals(resolution[1].effects[1], {
            order = 4,
            kind = "dollars",
            amount = 3,
            money = 9,
        })
        luaunit.assertEquals(resolution[1].effects[2].order, 5)
        luaunit.assertEquals(resolution[1].effects[2].kind, "tag_change")
    end)
end

function TestProductionAdapter:test_vanilla_tag_mutations_use_closed_semantic_effects()
    with_tag_fixture(function(fixture)
        fixture.apply_tag = function(tag, context)
            if tag.triggered then
                return
            end
            if tag.key == "tag_skip" and context.type == "immediate" then
                ease_dollars(10)
            elseif tag.key == "tag_orbital" and context.type == "immediate" then
                level_up_hand(tag, "High Card", true, 3)
            elseif tag.key == "tag_juggle" and context.type == "round_start_bonus" then
                G.hand:change_size(3)
            elseif tag.key == "tag_coupon" and context.type == "shop_final_pass" then
                G.GAME.shop_free = true
            elseif tag.key == "tag_d_six" and context.type == "shop_start" then
                G.E_MANAGER:add_event({
                    func = function()
                        G.GAME.current_round.reroll_cost = 0
                        return true
                    end,
                })
            elseif tag.key == "tag_investment" and context.type == "eval" then
                tag.triggered = true
                G.E_MANAGER:add_event({
                    func = function()
                        tag:remove_from_game()
                        return true
                    end,
                })
                return { dollars = 25, tag = tag }
            else
                return
            end
            tag.triggered = true
            G.E_MANAGER:add_event({
                func = function()
                    tag:remove_from_game()
                    return true
                end,
            })
            return true
        end

        local function capture(key, context)
            G.GAME.dollars = 6
            G.GAME.shop_free = false
            G.GAME.current_round.reroll_cost = 5
            G.hand.config.card_limit = 8
            G.GAME.hands["High Card"] = {
                visible = true,
                level = 1,
                chips = 5,
                mult = 1,
            }
            local tag = fixture.tag(key)
            G.GAME.tags = { tag }
            return assert(fixture.capture(function()
                tag:apply_to_run(context)
            end))
        end

        local dollars = capture("tag_skip", { type = "immediate" })
        luaunit.assertEquals(dollars[1].effects[1], {
            order = dollars[1].effects[1].order,
            kind = "dollars",
            amount = 10,
            money = 16,
        })

        local orbital = capture("tag_orbital", { type = "immediate" })
        luaunit.assertEquals(orbital[1].effects[1], {
            order = orbital[1].effects[1].order,
            kind = "poker_hand_level",
            poker_hand = "High Card",
            amount = 3,
            level = 4,
            chips = 35,
            mult = 4,
        })

        local juggle = capture("tag_juggle", { type = "round_start_bonus" })
        luaunit.assertEquals(juggle[1].effects[1], {
            order = juggle[1].effects[1].order,
            kind = "capacity",
            resource = "hand_size",
            amount = 3,
            value = 11,
        })

        local coupon = capture("tag_coupon", { type = "shop_final_pass" })
        luaunit.assertEquals(coupon[1].effects[1], {
            order = coupon[1].effects[1].order,
            kind = "run_rule",
            rule = "shop_free",
            enabled = true,
        })

        local d_six = capture("tag_d_six", { type = "shop_start" })
        luaunit.assertEquals(d_six[1].effects[1], {
            order = d_six[1].effects[1].order,
            kind = "run_rule",
            rule = "shop_reroll_cost",
            amount = -5,
            value = 0,
        })

        local investment = capture("tag_investment", { type = "eval" })
        luaunit.assertEquals(investment[1].effects[1], {
            order = investment[1].effects[1].order,
            kind = "dollars",
            amount = 25,
            money = 31,
        })

        for _, resolution in ipairs({ dollars, orbital, juggle, coupon, d_six, investment }) do
            local consume = resolution[1].effects[#resolution[1].effects]
            luaunit.assertEquals(consume.kind, "tag_change")
            luaunit.assertEquals(consume.operation, "consume")
        end
    end)
end

function TestProductionAdapter:test_investment_tag_is_not_duplicated_by_cash_out()
    with_tag_fixture(function(fixture)
        local tag = fixture.tag("tag_investment")
        G.GAME.tags = { tag }
        fixture.apply_tag = function(current, context)
            if current == tag and context.type == "eval" and not current.triggered then
                current.triggered = true
                G.E_MANAGER:add_event({
                    func = function()
                        current:remove_from_game()
                        return true
                    end,
                })
                return { dollars = 25, tag = current }
            end
        end

        local resolution = assert(fixture.capture(function()
            tag:apply_to_run({ type = "eval" })
        end, function(adapter)
            G.STATE = G.STATES.ROUND_EVAL
            G.round_eval = {
                get_UIE_by_ID = function(_, key)
                    if key == "cash_out_button" then
                        return { config = { button = "cash_out" } }
                    end
                end,
            }
            G.GAME.current_round.dollars = 30
            G.FUNCS.cash_out = function()
                G.GAME.dollars = G.GAME.dollars + 30
            end
            local observation, observe_error = adapter:observe("fair")
            luaunit.assertNil(observation)
            luaunit.assertEquals(observe_error.code, "DECISION_PENDING")
        end))
        luaunit.assertEquals(resolution[1].effects[1].amount, 25)
        luaunit.assertEquals(resolution[1].effects[1].money, 31)
        luaunit.assertEquals(resolution[2], {
            order = resolution[2].order,
            phase = "end_of_round",
            type = "cash_out",
            effects = {
                {
                    order = resolution[2].effects[1].order,
                    kind = "dollars",
                    amount = 5,
                    money = 36,
                },
            },
        })
    end)
end

function TestProductionAdapter:test_shop_offer_tags_record_owned_offer_and_edition_creation()
    with_tag_fixture(function(fixture)
        fixture.apply_tag = function(tag, context)
            if tag.triggered then
                return
            end
            if tag.key == "tag_top_up" and context.type == "immediate" then
                tag.triggered = true
                G.E_MANAGER:add_event({
                    func = function()
                        for _ = 1, 2 do
                            G.jokers:emplace(create_card("Joker", G.jokers))
                        end
                        return true
                    end,
                })
            elseif
                (tag.key == "tag_uncommon" or tag.key == "tag_rare")
                and context.type == "store_joker_create"
            then
                tag.triggered = true
                local rarity = tag.key == "tag_rare" and 1 or 0.9
                local card = create_card("Joker", context.area, nil, rarity)
                create_shop_card_ui(card, "Joker", context.area)
                context.area:emplace(card)
            elseif tag.key == "tag_voucher" and context.type == "voucher_add" then
                tag.triggered = true
                G.E_MANAGER:add_event({
                    func = function()
                        local card = setmetatable({
                            facing = "front",
                            ability = { set = "Voucher", name = "Voucher" },
                            config = {
                                center = {
                                    key = "v_overstock_norm",
                                    set = "Voucher",
                                },
                            },
                        }, { __index = Card })
                        create_shop_card_ui(card, "Voucher", G.shop_vouchers)
                        G.shop_vouchers:emplace(card)
                        return true
                    end,
                })
            elseif tag.key == "tag_negative" and context.type == "store_joker_modify" then
                tag.triggered = true
                G.E_MANAGER:add_event({
                    func = function()
                        context.card:set_edition({ negative = true, type = "negative" })
                        return true
                    end,
                })
            else
                return
            end
            G.E_MANAGER:add_event({
                func = function()
                    tag:remove_from_game()
                    return true
                end,
            })
            return true
        end

        local function capture(key, context)
            G.GAME.tags = { fixture.tag(key) }
            G.jokers.cards = {}
            G.shop_jokers.cards = {}
            G.shop_vouchers.cards = {}
            return assert(fixture.capture(function()
                G.GAME.tags[1]:apply_to_run(context)
            end))
        end

        local top_up = capture("tag_top_up", { type = "immediate" })
        luaunit.assertEquals(top_up[1].effects[1].destination, "owned")
        luaunit.assertEquals(top_up[1].effects[2].destination, "owned")
        luaunit.assertEquals(top_up[1].effects[1].key, "j_top_up")
        luaunit.assertEquals(top_up[1].effects[3].operation, "consume")

        for _, key in ipairs({ "tag_uncommon", "tag_rare" }) do
            local offer = capture(key, { type = "store_joker_create", area = G.shop_jokers })
            luaunit.assertEquals(offer[1].effects[1].object_kind, "joker")
            luaunit.assertEquals(offer[1].effects[1].destination, "shop_offer")
            luaunit.assertEquals(offer[1].effects[2].operation, "consume")
        end

        local voucher = capture("tag_voucher", { type = "voucher_add" })
        luaunit.assertEquals(voucher[1].effects[1], {
            order = voucher[1].effects[1].order,
            kind = "create",
            object_kind = "voucher",
            destination = "shop_offer",
            key = "v_overstock_norm",
        })
        luaunit.assertEquals(voucher[1].effects[2].operation, "consume")

        local edition_card = setmetatable({
            facing = "front",
            ability = { set = "Joker", name = "Edition Joker" },
            config = { center = { key = "j_edition", set = "Joker" } },
            area = G.shop_jokers,
        }, { __index = Card })
        local edition = capture("tag_negative", {
            type = "store_joker_modify",
            card = edition_card,
        })
        luaunit.assertEquals(edition[1].effects[1], {
            order = edition[1].effects[1].order,
            kind = "create",
            object_kind = "joker",
            destination = "shop_offer",
            key = "j_edition",
            edition = "e_negative",
        })
        luaunit.assertEquals(edition[1].effects[2].operation, "consume")
    end)
end

function TestProductionAdapter:test_boss_tag_records_automatic_replacement_and_consumption()
    with_tag_fixture(function(fixture)
        local boss = fixture.tag("tag_boss")
        G.GAME.tags = { boss }
        fixture.apply_tag = function(tag, context)
            if tag == boss and context.type == "new_blind_choice" and not tag.triggered then
                tag.triggered = true
                G.E_MANAGER:add_event({
                    func = function()
                        G.GAME.round_resets.blind_choices.Boss = get_new_boss()
                        return true
                    end,
                })
                G.E_MANAGER:add_event({
                    func = function()
                        tag:remove_from_game()
                        return true
                    end,
                })
                return true
            end
        end

        local resolution = assert(fixture.capture(function()
            boss:apply_to_run({ type = "new_blind_choice" })
        end))
        luaunit.assertEquals(#resolution, 1)
        luaunit.assertEquals(resolution[1].key, "tag_boss")
        luaunit.assertEquals(resolution[1].effects[1], {
            order = resolution[1].effects[1].order,
            kind = "blind_change",
            operation = "replace",
            previous_key = "bl_head",
            key = "bl_hook",
        })
        luaunit.assertEquals(resolution[1].effects[2].kind, "tag_change")
        luaunit.assertEquals(resolution[1].effects[2].operation, "consume")
        luaunit.assertEquals(G.GAME.round_resets.blind_choices.Boss, "bl_hook")
    end)
end

function TestProductionAdapter:test_automatic_booster_tags_record_pack_shape_without_candidates()
    with_tag_fixture(function(fixture)
        local cases = {
            tag_charm = { kind = "Arcana", size = 5, choices = 2 },
            tag_meteor = { kind = "Celestial", size = 5, choices = 2 },
            tag_ethereal = { kind = "Spectral", size = 2, choices = 1 },
            tag_standard = { kind = "Standard", size = 5, choices = 2 },
            tag_buffoon = { kind = "Buffoon", size = 4, choices = 2 },
        }
        fixture.apply_tag = function(tag, context)
            local case = cases[tag.key]
            if case and context.type == "new_blind_choice" and not tag.triggered then
                tag.triggered = true
                G.E_MANAGER:add_event({
                    func = function()
                        local card = setmetatable({
                            facing = "front",
                            ability = {
                                set = "Booster",
                                name = case.kind .. " Pack",
                                extra = case.size,
                                choose = case.choices,
                            },
                            config = {
                                center = {
                                    key = "p_" .. case.kind:lower(),
                                    set = "Booster",
                                    kind = case.kind,
                                    config = { choose = case.choices },
                                },
                            },
                        }, { __index = Card })
                        card:open()
                        return true
                    end,
                })
                G.E_MANAGER:add_event({
                    func = function()
                        tag:remove_from_game()
                        return true
                    end,
                })
                return true
            end
        end

        for key, case in pairs(cases) do
            local tag = fixture.tag(key)
            G.GAME.tags = { tag }
            local resolution = assert(fixture.capture(function()
                tag:apply_to_run({ type = "new_blind_choice" })
            end))
            luaunit.assertEquals(#resolution, 1)
            luaunit.assertEquals(resolution[1].key, key)
            luaunit.assertEquals(resolution[1].effects[1], {
                order = resolution[1].effects[1].order,
                kind = "open_booster",
                category = case.kind:lower(),
                size = case.size,
                choices = case.choices,
            })
            luaunit.assertEquals(resolution[1].effects[2].kind, "tag_change")
            luaunit.assertEquals(resolution[1].effects[2].operation, "consume")
            luaunit.assertEquals(resolution[1].effects[2].key, key)
            luaunit.assertNil(resolution[1].effects[1].items)
            luaunit.assertNil(resolution[1].effects[1].input_target_id)
        end
    end)
end

function TestProductionAdapter:test_voucher_application_records_run_upgrades_only()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_card = rawget(_G, "Card")
    local saved_card_area = rawget(_G, "CardArea")
    local saved_copy_card = rawget(_G, "copy_card")
    local saved_event = rawget(_G, "Event")
    local queued = {}
    local red_deck = { key = "b_red", name = "Red Deck", set = "Back", config = {} }
    local white_stake = { key = "stake_white", name = "White Stake", order = 1 }

    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            stake_from_index = function()
                return "stake_white"
            end,
        }
        _G.Event = setmetatable({}, {
            __call = function(_, event)
                event.is = function()
                    return true
                end
                return event
            end,
        })
        _G.CardArea = {
            change_size = function(area, amount)
                area.config.card_limit = area.config.card_limit + amount
            end,
        }
        _G.Card = {
            apply_to_run = function(card)
                copy_card(card)
                local key = card.config.center.key
                if key == "v_overstock_norm" then
                    G.E_MANAGER:add_event({
                        func = function()
                            G.GAME.shop.joker_max = G.GAME.shop.joker_max + 1
                            G.shop_jokers.config.card_limit = G.GAME.shop.joker_max
                            return true
                        end,
                    })
                elseif key == "v_tarot_merchant" then
                    G.E_MANAGER:add_event({
                        func = function()
                            G.GAME.tarot_rate = 9.6
                            return true
                        end,
                    })
                elseif key == "v_clearance_sale" then
                    G.E_MANAGER:add_event({
                        func = function()
                            G.GAME.discount_percent = 25
                            return true
                        end,
                    })
                elseif key == "v_reroll_surplus" then
                    G.E_MANAGER:add_event({
                        func = function()
                            G.GAME.round_resets.reroll_cost = G.GAME.round_resets.reroll_cost - 2
                            G.GAME.current_round.reroll_cost = G.GAME.current_round.reroll_cost - 2
                            return true
                        end,
                    })
                elseif key == "v_seed_money" then
                    G.E_MANAGER:add_event({
                        func = function()
                            G.GAME.interest_cap = 50
                            return true
                        end,
                    })
                elseif key == "v_grabber" then
                    G.GAME.round_resets.hands = G.GAME.round_resets.hands + 1
                    G.E_MANAGER:add_event({
                        func = function()
                            G.GAME.current_round.hands_left = G.GAME.current_round.hands_left + 1
                            return true
                        end,
                    })
                elseif key == "v_hieroglyph" then
                    G.E_MANAGER:add_event({
                        func = function()
                            G.GAME.round_resets.ante = G.GAME.round_resets.ante - 1
                            return true
                        end,
                    })
                    G.GAME.round_resets.blind_ante = G.GAME.round_resets.blind_ante - 1
                    G.GAME.round_resets.hands = G.GAME.round_resets.hands - 1
                    G.E_MANAGER:add_event({
                        func = function()
                            G.GAME.current_round.hands_left = G.GAME.current_round.hands_left - 1
                            return true
                        end,
                    })
                elseif key == "v_petroglyph" then
                    G.E_MANAGER:add_event({
                        func = function()
                            G.GAME.round_resets.ante = G.GAME.round_resets.ante - 1
                            return true
                        end,
                    })
                    G.GAME.round_resets.blind_ante = G.GAME.round_resets.blind_ante - 1
                    G.GAME.round_resets.discards = G.GAME.round_resets.discards - 1
                    G.E_MANAGER:add_event({
                        func = function()
                            if G.GAME.current_round.discards_left > 0 then
                                G.GAME.current_round.discards_left = G.GAME.current_round.discards_left
                                    - 1
                            end
                            return true
                        end,
                    })
                elseif key == "v_paint_brush" then
                    G.hand:change_size(1)
                elseif key == "v_crystal_ball" then
                    G.E_MANAGER:add_event({
                        func = function()
                            G.consumeables.config.card_limit = G.consumeables.config.card_limit + 1
                            return true
                        end,
                    })
                elseif key == "v_antimatter" then
                    G.E_MANAGER:add_event({
                        func = function()
                            G.jokers.config.card_limit = G.jokers.config.card_limit + 1
                            return true
                        end,
                    })
                elseif key == "v_illusion" then
                    G.E_MANAGER:add_event({
                        func = function()
                            G.GAME.playing_card_rate = 4
                            return true
                        end,
                    })
                end
            end,
            start_dissolve = function(card)
                card.dissolved = true
            end,
        }
        rawset(_G, "copy_card", function(card, ...)
            return {
                facing = "front",
                ability = card.ability,
                config = { center = card.config.center },
            }
        end)
        _G.G = {
            VERSION = "1.0.1o-FULL",
            STAGES = { MAIN_MENU = 1, RUN = 2 },
            STATES = { SHOP = 5 },
            STAGE = 2,
            STATE = 5,
            STATE_COMPLETE = true,
            CONTROLLER = { locks = {}, lock_input = false },
            SETTINGS = { paused = false, tutorial_complete = true },
            P_CARDS = {},
            P_BLINDS = {},
            P_STAKES = { stake_white = white_stake },
            P_CENTERS = {},
            P_TAGS = {},
            shop = {},
            shop_jokers = { cards = {}, config = { card_limit = 2 } },
            shop_vouchers = { cards = {} },
            shop_booster = { cards = {} },
            jokers = { cards = {}, config = { card_limit = 5 } },
            consumeables = { cards = {}, config = { card_limit = 2 } },
            hand = { cards = {}, highlighted = {}, config = { card_limit = 8 } },
            deck = { cards = {} },
            E_MANAGER = {
                add_event = function(_, event)
                    if event.trigger == "immediate" then
                        luaunit.assertEquals(type(event.is), "function")
                    end
                    queued[#queued + 1] = event
                end,
            },
            GAME = {},
        }
        setmetatable(G.hand, { __index = CardArea })

        local function reset_run()
            G.GAME = {
                selected_back = { effect = { center = red_deck } },
                stake = 1,
                dollars = 30,
                bankrupt_at = 0,
                chips = 0,
                skips = 0,
                seeded = true,
                tags = {},
                used_vouchers = {},
                modifiers = {},
                starting_params = {
                    dollars = 4,
                    hands = 4,
                    discards = 3,
                    hand_size = 8,
                    joker_slots = 5,
                    consumable_slots = 2,
                    ante_scaling = 1,
                    no_faces = false,
                    erratic_suits_and_ranks = false,
                },
                current_round = {
                    reroll_cost = 5,
                    hands_left = 4,
                    discards_left = 3,
                },
                hands = {},
                round_resets = {
                    hands = 4,
                    discards = 3,
                    reroll_cost = 5,
                    ante = 3,
                    blind_ante = 3,
                },
                shop = { joker_max = 2 },
                tarot_rate = 4,
                planet_rate = 4,
                spectral_rate = 0,
                edition_rate = 1,
                playing_card_rate = 0,
                discount_percent = 0,
                interest_cap = 25,
                pseudorandom = { seed = "MCPTEST" },
            }
            G.shop_jokers.config.card_limit = 2
            G.jokers.config.card_limit = 5
            G.consumeables.config.card_limit = 2
            G.hand.config.card_limit = 8
            queued = {}
        end

        G.FUNCS = {
            use_card = function(e)
                local card = e.config.ref_table
                G.GAME.dollars = G.GAME.dollars - card.cost
                G.GAME.used_vouchers[card.config.center.key] = true
                Card.apply_to_run(card)
                Card.start_dissolve(card)
                G.shop_vouchers.cards = {}
            end,
        }

        local function capture(key)
            reset_run()
            if key == "v_petroglyph" then
                G.GAME.current_round.discards_left = 0
            end
            local card = {
                sort_id = 41,
                cost = 10,
                ability = { set = "Voucher", name = key },
                config = { center = { key = key, set = "Voucher", name = key } },
            }
            setmetatable(card, { __index = Card })
            card.area = G.shop_vouchers
            G.shop_vouchers.cards = { card }
            local adapter = ProductionBalatroAdapter.new()
            local result, action_error = adapter:execute({
                name = "redeem_voucher",
                expected_state_hash = "sha256:test",
                visibility = "fair",
                arguments = {},
                targets = { voucher_id = "shop_voucher:41" },
            })
            luaunit.assertNil(action_error)
            luaunit.assertNotNil(result)
            ---@cast result table
            while queued[1] do
                table.remove(queued, 1).func()
            end
            local resolution, resolution_error =
                adapter:finish_resolution(result.resolution_context)
            luaunit.assertNil(resolution_error)
            assert_resolution_matches_announced_schema(resolution)
            luaunit.assertTrue(card.dissolved)
            return resolution
        end

        luaunit.assertEquals(capture("v_overstock_norm")[1].effects, {
            { order = 2, kind = "capacity", resource = "shop_slots", amount = 1, value = 3 },
        })
        luaunit.assertEquals(capture("v_tarot_merchant")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "tarot_rate",
                amount = 5.6,
                value = 9.6,
            },
        })
        luaunit.assertEquals(capture("v_clearance_sale")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "shop_discount_percent",
                amount = 25,
                value = 25,
            },
        })
        luaunit.assertEquals(capture("v_reroll_surplus")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "shop_reroll_cost",
                amount = -2,
                value = 3,
            },
        })
        luaunit.assertEquals(capture("v_seed_money")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "interest_cap",
                amount = 5,
                value = 10,
            },
        })
        luaunit.assertEquals(capture("v_grabber")[1].effects, {
            {
                order = 2,
                kind = "round_allowance",
                resource = "hands",
                amount = 1,
                base = 5,
                current = 5,
            },
        })
        luaunit.assertEquals(capture("v_hieroglyph")[1].effects, {
            {
                order = 2,
                kind = "ante_change",
                amount = -1,
                ante = 2,
                blind_ante = 2,
            },
            {
                order = 3,
                kind = "round_allowance",
                resource = "hands",
                amount = -1,
                base = 3,
                current = 3,
            },
        })
        luaunit.assertEquals(capture("v_petroglyph")[1].effects, {
            {
                order = 2,
                kind = "ante_change",
                amount = -1,
                ante = 2,
                blind_ante = 2,
            },
            {
                order = 3,
                kind = "round_allowance",
                resource = "discards",
                amount = -1,
                base = 2,
                current = 0,
            },
        })
        luaunit.assertEquals(capture("v_paint_brush")[1].effects, {
            { order = 2, kind = "capacity", resource = "hand_size", amount = 1, value = 9 },
        })
        luaunit.assertEquals(capture("v_crystal_ball")[1].effects, {
            {
                order = 2,
                kind = "capacity",
                resource = "consumable_slots",
                amount = 1,
                value = 3,
            },
        })
        luaunit.assertEquals(capture("v_antimatter")[1].effects, {
            {
                order = 2,
                kind = "capacity",
                resource = "joker_slots",
                amount = 1,
                value = 6,
            },
        })
        luaunit.assertEquals(capture("v_telescope")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "celestial_pack_planet",
                enabled = true,
            },
        })
        luaunit.assertEquals(capture("v_observatory")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "held_planet_x_mult",
                amount = 0.5,
                value = 1.5,
            },
        })
        luaunit.assertEquals(capture("v_illusion")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "enhanced_shop_playing_cards",
                enabled = true,
            },
            {
                order = 3,
                kind = "run_rule",
                rule = "playing_card_rate",
                amount = 4,
                value = 4,
            },
        })
        luaunit.assertEquals(capture("v_directors_cut")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "boss_reroll_once_per_ante",
                enabled = true,
            },
            {
                order = 3,
                kind = "run_rule",
                rule = "boss_reroll_cost",
                value = 10,
            },
        })
        luaunit.assertEquals(capture("v_retcon")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "unlimited_boss_rerolls",
                enabled = true,
            },
            {
                order = 3,
                kind = "run_rule",
                rule = "boss_reroll_cost",
                value = 10,
            },
        })
        luaunit.assertNil(capture("v_blank"))
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "Card", saved_card)
    rawset(_G, "CardArea", saved_card_area)
    rawset(_G, "copy_card", saved_copy_card)
    rawset(_G, "Event", saved_event)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_back_application_separates_run_setup_and_keeps_nested_order()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_back = rawget(_G, "Back")
    local saved_card = rawget(_G, "Card")
    local saved_card_area = rawget(_G, "CardArea")
    local saved_create_card = rawget(_G, "create_card")
    local saved_create_playing_card = rawget(_G, "create_playing_card")
    local queued = {}
    local created_key
    local white_stake = { key = "stake_white", name = "White Stake", set = "Stake", order = 1 }
    local backs = {
        b_black = { hands = -1, joker_slot = 1 },
        b_yellow = { dollars = 10 },
        b_green = { no_interest = true, extra_hand_bonus = 2, extra_discard_bonus = 1 },
        b_magic = { voucher = "v_crystal_ball", consumables = { "c_fool", "c_fool" } },
        b_ghost = { spectral_rate = 2, consumables = { "c_hex" } },
        b_abandoned = { remove_faces = true },
        b_checkered = {},
        b_anaglyph = {},
        b_plasma = { ante_scaling = 2 },
        b_erratic = { randomize_rank_suit = true },
    }
    local centers = {}
    local back_pool = {}
    for key, config in pairs(backs) do
        local center = {
            key = key,
            name = key,
            set = "Back",
            config = config,
            unlocked = true,
            discovered = true,
        }
        centers[key] = center
        back_pool[#back_pool + 1] = center
    end
    centers.v_crystal_ball = {
        key = "v_crystal_ball",
        name = "Crystal Ball",
        set = "Voucher",
        config = { extra = 3 },
    }

    local ok, test_error = xpcall(function()
        _G.SMODS = {
            version = "1.0.0~BETA-2014b",
            mod_list = {},
            stake_from_index = function()
                return "stake_white"
            end,
            stake_is_unlocked = function()
                return true
            end,
            calculate_effect_table_key = function(...) end,
        }
        _G.CardArea = {
            change_size = function(area, amount)
                area.config.card_limit = area.config.card_limit + amount
            end,
        }
        _G.Card = {
            apply_to_run = function(_card, center)
                if center.key == "v_crystal_ball" then
                    G.E_MANAGER:add_event({
                        func = function()
                            G.consumeables.config.card_limit = G.consumeables.config.card_limit + 1
                            return true
                        end,
                    })
                end
            end,
            set_base = function(card, base)
                card.base = { suit = base.suit, value = base.value }
            end,
        }
        _G.Back = {
            apply_to_run = function(back)
                local center = back.effect.center
                local config = center.config
                if config.voucher then
                    G.GAME.used_vouchers[config.voucher] = true
                    G.E_MANAGER:add_event({
                        func = function()
                            Card.apply_to_run(nil, G.P_CENTERS[config.voucher])
                            return true
                        end,
                    })
                end
                if config.hands then
                    G.GAME.starting_params.hands = G.GAME.starting_params.hands + config.hands
                end
                if config.consumables then
                    G.E_MANAGER:add_event({
                        func = function()
                            for _, key in ipairs(config.consumables) do
                                created_key = key
                                local card = create_card("Tarot", G.consumeables)
                                G.consumeables.cards[#G.consumeables.cards + 1] = card
                            end
                            return true
                        end,
                    })
                end
                if config.dollars then
                    G.GAME.starting_params.dollars = G.GAME.starting_params.dollars + config.dollars
                end
                if config.remove_faces then
                    G.GAME.starting_params.no_faces = true
                end
                if config.spectral_rate then
                    G.GAME.spectral_rate = config.spectral_rate
                end
                if center.key == "b_checkered" then
                    G.E_MANAGER:add_event({
                        func = function()
                            for _, card in ipairs(G.playing_cards) do
                                if card.base.suit == "Clubs" then
                                    Card.set_base(card, {
                                        suit = "Spades",
                                        value = card.base.value,
                                    })
                                elseif card.base.suit == "Diamonds" then
                                    Card.set_base(card, {
                                        suit = "Hearts",
                                        value = card.base.value,
                                    })
                                end
                            end
                            return true
                        end,
                    })
                end
                if config.randomize_rank_suit then
                    G.GAME.starting_params.erratic_suits_and_ranks = true
                end
                if config.joker_slot then
                    G.GAME.starting_params.joker_slots = G.GAME.starting_params.joker_slots
                        + config.joker_slot
                end
                if config.ante_scaling then
                    G.GAME.starting_params.ante_scaling = config.ante_scaling
                end
                if config.no_interest then
                    G.GAME.modifiers.no_interest = true
                end
                if config.extra_hand_bonus then
                    G.GAME.modifiers.money_per_hand = config.extra_hand_bonus
                end
                if config.extra_discard_bonus then
                    G.GAME.modifiers.money_per_discard = config.extra_discard_bonus
                end
            end,
        }
        rawset(_G, "create_card", function(_set, _area, ...)
            return {
                facing = "front",
                ability = { set = "Tarot", consumeable = true },
                config = { center = { key = created_key, set = "Tarot" } },
            }
        end)
        rawset(_G, "create_playing_card", function(card_init, area)
            local card = {
                facing = "front",
                ability = { set = "Default" },
                config = { card_key = card_init.key, center = { key = "c_base", set = "Default" } },
                base = { suit = card_init.suit, value = card_init.value },
            }
            area.cards[#area.cards + 1] = card
            G.playing_cards[#G.playing_cards + 1] = card
            setmetatable(card, { __index = Card })
            return card
        end)
        _G.G = {
            VERSION = "1.0.1o-FULL",
            STAGES = { MAIN_MENU = 1, RUN = 2 },
            STATES = { MENU = 11, BLIND_SELECT = 7 },
            STAGE = 1,
            STATE = 11,
            STATE_COMPLETE = true,
            CONTROLLER = { locks = {}, lock_input = false },
            SETTINGS = { current_setup = "New Run", profile = 1 },
            MAIN_MENU_UI = {},
            PROFILES = { [1] = { high_scores = { current_streak = { amt = 0 } } } },
            P_CENTER_POOLS = { Back = back_pool, Stake = { white_stake } },
            P_CENTERS = centers,
            P_STAKES = { stake_white = white_stake },
            P_BLINDS = {},
            P_TAGS = {},
            E_MANAGER = {
                add_event = function(_, event)
                    queued[#queued + 1] = event
                end,
            },
            GAME = {},
        }

        local selected_key
        G.FUNCS = {
            start_run = function(_, arguments)
                local selected
                for _, center in ipairs(back_pool) do
                    if center.name == arguments.deck_choice.name then
                        selected = center
                        break
                    end
                end
                luaunit.assertNotNil(selected)
                selected_key = selected.key
                G.STAGE = G.STAGES.RUN
                G.STATE = G.STATES.BLIND_SELECT
                G.hand = nil
                G.jokers = nil
                G.consumeables = nil
                G.shop_jokers = nil
                G.playing_cards = nil
                G.GAME = {
                    selected_back = setmetatable({
                        name = selected.name,
                        effect = { center = selected, config = selected.config },
                    }, { __index = Back }),
                    stake = 1,
                    dollars = 0,
                    chips = 0,
                    skips = 0,
                    seeded = true,
                    tags = {},
                    used_vouchers = {},
                    modifiers = {},
                    starting_params = {
                        dollars = 4,
                        hands = 4,
                        discards = 3,
                        hand_size = 8,
                        joker_slots = 5,
                        consumable_slots = 2,
                        ante_scaling = 1,
                        no_faces = false,
                        erratic_suits_and_ranks = false,
                    },
                    current_round = { hands_left = 0, discards_left = 0, reroll_cost = 5 },
                    round_resets = {
                        hands = 4,
                        discards = 3,
                        reroll_cost = 5,
                        ante = 1,
                        blind_ante = 1,
                    },
                    shop = { joker_max = 2 },
                    tarot_rate = 4,
                    planet_rate = 4,
                    spectral_rate = 0,
                    edition_rate = 1,
                    playing_card_rate = 0,
                    discount_percent = 0,
                    interest_cap = 25,
                    pseudorandom = { seed = "MCPTEST" },
                }
                Back.apply_to_run(G.GAME.selected_back)
                G.consumeables = {
                    cards = {},
                    config = { card_limit = G.GAME.starting_params.consumable_slots },
                }
                G.jokers = {
                    cards = {},
                    config = { card_limit = G.GAME.starting_params.joker_slots },
                }
                G.hand = {
                    cards = {},
                    config = { card_limit = G.GAME.starting_params.hand_size },
                }
                G.shop_jokers = {
                    cards = {},
                    config = { card_limit = G.GAME.shop.joker_max },
                }
                G.deck = { cards = {} }
                G.playing_cards = {}
                for _, suit in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
                    for rank = 2, 14 do
                        local card = create_playing_card({
                            key = suit .. tostring(rank),
                            suit = suit,
                            value = rank == 14 and "Ace" or tostring(rank),
                        }, G.deck)
                        SMODS.calculate_effect_table_key(
                            { playing_card = {} },
                            "playing_card",
                            card
                        )
                    end
                end
                G.GAME.dollars = G.GAME.starting_params.dollars
                G.GAME.current_round.hands_left = G.GAME.starting_params.hands
                G.GAME.current_round.discards_left = G.GAME.starting_params.discards
            end,
        }

        local function capture(key)
            G.STAGE = G.STAGES.MAIN_MENU
            G.STATE = G.STATES.MENU
            G.GAME = {}
            queued = {}
            local adapter = ProductionBalatroAdapter.new()
            local result, action_error = adapter:execute({
                name = "start_run",
                expected_state_hash = "sha256:test",
                visibility = "fair",
                arguments = { deck_key = key, stake = 1 },
                targets = {},
            })
            luaunit.assertNil(action_error)
            luaunit.assertNotNil(result)
            luaunit.assertEquals(selected_key, key)
            ---@cast result table
            while queued[1] do
                table.remove(queued, 1).func()
            end
            local resolution, resolution_error =
                adapter:finish_resolution(result.resolution_context)
            luaunit.assertNil(resolution_error)
            assert_resolution_matches_announced_schema(resolution)
            luaunit.assertEquals(#G.playing_cards, 52)
            return resolution
        end

        luaunit.assertEquals(capture("b_black")[1].effects, {
            {
                order = 2,
                kind = "round_allowance",
                resource = "hands",
                amount = -1,
                base = 3,
                current = 3,
            },
            {
                order = 3,
                kind = "capacity",
                resource = "joker_slots",
                amount = 1,
                value = 6,
            },
        })
        luaunit.assertEquals(capture("b_yellow")[1].effects, {
            { order = 2, kind = "dollars", amount = 10, money = 14 },
        })
        luaunit.assertEquals(capture("b_green")[1].effects, {
            { order = 2, kind = "run_rule", rule = "no_interest", enabled = true },
            {
                order = 3,
                kind = "run_rule",
                rule = "money_per_hand",
                amount = 1,
                value = 2,
            },
            {
                order = 4,
                kind = "run_rule",
                rule = "money_per_discard",
                amount = 1,
                value = 1,
            },
        })
        luaunit.assertEquals(capture("b_plasma")[1].effects, {
            { order = 2, kind = "run_rule", rule = "balanced_scoring", enabled = true },
            { order = 3, kind = "run_rule", rule = "ante_scaling", amount = 1, value = 2 },
        })
        luaunit.assertEquals(capture("b_abandoned")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "face_cards_removed",
                enabled = true,
            },
        })
        luaunit.assertEquals(capture("b_erratic")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "randomized_starting_deck",
                enabled = true,
            },
        })
        luaunit.assertEquals(capture("b_anaglyph")[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "boss_defeat_double_tag",
                enabled = true,
            },
        })

        local ghost = capture("b_ghost")
        luaunit.assertNotNil(ghost)
        ---@cast ghost table
        luaunit.assertEquals(#ghost, 1)
        luaunit.assertEquals(ghost[1].effects, {
            {
                order = 2,
                kind = "run_rule",
                rule = "spectral_rate",
                amount = 2,
                value = 2,
            },
            {
                order = 3,
                kind = "create",
                object_kind = "consumable",
                destination = "owned",
                key = "c_hex",
            },
        })

        local magic = capture("b_magic")
        luaunit.assertEquals(magic, {
            {
                order = 1,
                phase = "run_start",
                type = "apply",
                component = "back",
                key = "b_magic",
                effects = {
                    {
                        order = 3,
                        kind = "create",
                        object_kind = "consumable",
                        destination = "owned",
                        key = "c_fool",
                    },
                    {
                        order = 4,
                        kind = "create",
                        object_kind = "consumable",
                        destination = "owned",
                        key = "c_fool",
                    },
                },
            },
            {
                order = 2,
                phase = "run_start",
                type = "apply",
                component = "voucher",
                key = "v_crystal_ball",
                parent_order = 1,
                effects = {
                    {
                        order = 5,
                        kind = "capacity",
                        resource = "consumable_slots",
                        amount = 1,
                        value = 3,
                    },
                },
            },
        })

        local checkered = capture("b_checkered")
        luaunit.assertNotNil(checkered)
        ---@cast checkered table
        luaunit.assertEquals(#checkered, 1)
        luaunit.assertEquals(#checkered[1].effects, 26)
        luaunit.assertEquals(checkered[1].effects[1], {
            order = 2,
            kind = "set_card_state",
            state = "suit",
            value = "Spades",
        })
        luaunit.assertEquals(checkered[1].effects[26], {
            order = 27,
            kind = "set_card_state",
            state = "suit",
            value = "Hearts",
        })
        for _, effect in ipairs(checkered[1].effects) do
            luaunit.assertNil(effect.input_target_id)
            luaunit.assertEquals(effect.kind, "set_card_state")
        end
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "Back", saved_back)
    rawset(_G, "Card", saved_card)
    rawset(_G, "CardArea", saved_card_area)
    rawset(_G, "create_card", saved_create_card)
    rawset(_G, "create_playing_card", saved_create_playing_card)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_facedown_cards_and_jokers_omit_identity_and_project_hand_order()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local two = test_playing_card({
        sort_id = 1,
        key = "S_2",
        suit = "Spades",
        rank = "2",
        nominal = 2,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        facing = "front",
        T = { x = 1 },
    })
    local ace = test_playing_card({
        sort_id = 2,
        key = "D_A",
        suit = "Diamonds",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.01,
        suit_nominal_original = 0.001,
        face_nominal = 0.4,
        facing = "back",
        T = { x = 2 },
    })
    local king = test_playing_card({
        sort_id = 3,
        key = "H_K",
        suit = "Hearts",
        rank = "King",
        nominal = 10,
        suit_nominal = 0.03,
        suit_nominal_original = 0.003,
        face_nominal = 0.3,
        facing = "front",
        T = { x = 3 },
    })
    local joker = {
        sort_id = 11,
        facing = "back",
        edition = { negative = true, card_limit = 1 },
        T = { x = 1 },
        cost = 2,
        sell_cost = 1,
        debuff = false,
        ability = { set = "Joker", name = "Joker", mult = 4 },
        config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
        can_sell_card = function()
            return true
        end,
    }
    local stencil = {
        sort_id = 12,
        facing = "back",
        T = { x = 2 },
        cost = 8,
        sell_cost = 4,
        debuff = false,
        ability = { set = "Joker", name = "Joker Stencil", eternal = true },
        config = { center = { key = "j_stencil", set = "Joker", name = "Joker Stencil" } },
        can_sell_card = function()
            return false
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ two, ace, king }, { joker, stencil })
        local adapter = ProductionBalatroAdapter.new()
        local observation, observe_error = adapter:observe("fair")
        luaunit.assertNil(observe_error)
        luaunit.assertNotNil(observation)
        ---@cast observation table
        luaunit.assertEquals(observation.public_state.hand[1].key, "S_2")
        luaunit.assertEquals(observation.public_state.hand[2].facedown, true)
        luaunit.assertNil(observation.public_state.hand[2].key)
        luaunit.assertEquals(observation.public_state.hand[2].target_ref, "card:2")
        luaunit.assertEquals(observation.public_state.jokers[1].facedown, true)
        luaunit.assertNil(observation.public_state.jokers[1].key)
        luaunit.assertNil(observation.public_state.jokers[1].name)
        luaunit.assertNil(observation.public_state.jokers[1].description)
        luaunit.assertNil(observation.public_state.jokers[1].edition)
        luaunit.assertEquals(observation.public_state.jokers[1].target_ref, "joker:11")
        luaunit.assertEquals(observation.public_state.jokers[2].facedown, true)
        luaunit.assertNil(observation.public_state.jokers[2].key)
        luaunit.assertEquals(observation.public_state.hand_order_projections.rank, {
            "card:2",
            "card:3",
            "card:1",
        })
        luaunit.assertEquals(observation.public_state.hand_order_projections.suit, {
            "card:1",
            "card:3",
            "card:2",
        })
        luaunit.assertEquals(observation.hidden_state.facedown_cards[1].key, "D_A")
        luaunit.assertEquals(observation.hidden_state.facedown_jokers[1].key, "j_joker")
        luaunit.assertEquals(observation.hidden_state.facedown_jokers[1].edition.key, "e_negative")
        luaunit.assertEquals(observation.hidden_state.facedown_jokers[2].key, "j_stencil")
        luaunit.assertNil(observation.public_state.active_sort)

        ace.facing = "front"
        local revealed, revealed_error = adapter:observe("fair")
        luaunit.assertNil(revealed_error)
        ---@cast revealed table
        luaunit.assertNil(revealed.public_state.hand_order_projections)
        luaunit.assertEquals(revealed.public_state.hand[2].key, "D_A")
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_facedown_reorder_keeps_refs_and_shuffle_hides_jokers()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local two = test_playing_card({
        sort_id = 1,
        key = "S_2",
        suit = "Spades",
        rank = "2",
        nominal = 2,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        facing = "front",
        T = { x = 1 },
    })
    local ace = test_playing_card({
        sort_id = 2,
        key = "D_A",
        suit = "Diamonds",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.01,
        suit_nominal_original = 0.001,
        face_nominal = 0.4,
        facing = "back",
        T = { x = 2 },
    })
    local joker = {
        sort_id = 11,
        facing = "front",
        T = { x = 1 },
        cost = 2,
        sell_cost = 1,
        ability = { set = "Joker", name = "Joker", mult = 4 },
        config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
        can_sell_card = function()
            return true
        end,
    }
    local stencil = {
        sort_id = 12,
        facing = "front",
        T = { x = 2 },
        cost = 8,
        sell_cost = 4,
        ability = { set = "Joker", name = "Joker Stencil", eternal = true },
        config = { center = { key = "j_stencil", set = "Joker", name = "Joker Stencil" } },
        can_sell_card = function()
            return false
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ two, ace }, { joker, stencil })
        local adapter = ProductionBalatroAdapter.new()
        local first, first_error = adapter:observe("fair")
        luaunit.assertNil(first_error)
        ---@cast first table
        luaunit.assertEquals(first.public_state.jokers[1].key, "j_joker")

        local reorder, reorder_error = adapter:execute({
            name = "reorder_cards",
            expected_state_hash = "sha256:test",
            visibility = "fair",
            arguments = { area = "hand" },
            targets = { ordered_ids = { "card:2", "card:1" } },
        })
        luaunit.assertNil(reorder_error)
        ---@cast reorder table
        luaunit.assertEquals(reorder.observation.public_state.hand[1].target_ref, "card:2")
        luaunit.assertEquals(reorder.observation.public_state.hand[1].facedown, true)
        luaunit.assertEquals(reorder.observation.public_state.hand[2].target_ref, "card:1")
        luaunit.assertEquals(G.hand.cards[1], ace)

        joker.facing = "back"
        stencil.facing = "back"
        G.jokers.cards = { stencil, joker }
        local shuffled, shuffled_error = adapter:observe("fair")
        luaunit.assertNil(shuffled_error)
        ---@cast shuffled table
        luaunit.assertEquals(shuffled.public_state.jokers[1].target_ref, "joker:12")
        luaunit.assertEquals(shuffled.public_state.jokers[2].target_ref, "joker:11")
        luaunit.assertEquals(shuffled.public_state.jokers[1].facedown, true)
        luaunit.assertNil(shuffled.public_state.jokers[1].key)
        luaunit.assertNil(shuffled.public_state.jokers[2].name)
        luaunit.assertEquals(shuffled.hidden_state.facedown_jokers[1].key, "j_stencil")
        luaunit.assertEquals(shuffled.hidden_state.facedown_jokers[2].key, "j_joker")
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_resolution_context_preserves_nested_and_async_global_order()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_create = rawget(_G, "create_card")
    local ace = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        T = { x = 1 },
    })
    local joker = {
        sort_id = 11,
        facing = "front",
        T = { x = 1 },
        ability = { set = "Joker", name = "Joker" },
        config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
        can_sell_card = function()
            return true
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ ace }, { joker })
        install_smods_calculate_fixture()
        SMODS.calculation_keys = { "chips", "func", "mult" }
        local queued = {}
        G.E_MANAGER = {
            add_event = function(_, event)
                queued[#queued + 1] = event
            end,
        }
        rawset(_G, "create_card", function(_type, _area)
            return {
                sort_id = 101,
                ability = { consumeable = true, set = "Tarot" },
                config = { center = { key = "c_fool", set = "Tarot" } },
            }
        end)
        G.FUNCS = {
            get_poker_hand_info = function()
                return "High Card", "High Card", {}, { ace }, "High Card"
            end,
            play_cards_from_highlighted = function()
                push_smods_context({ joker_main = true, cardarea = G.jokers })
                SMODS.calculate_effect_table_key({
                    jokers = {
                        chips = 10,
                        func = function()
                            SMODS.calculate_effect_table_key({
                                playing_card = { mult = 3 },
                            }, "playing_card", ace)
                            G.E_MANAGER:add_event({
                                func = function()
                                    create_card("Tarot", G.consumeables)
                                    return true
                                end,
                            })
                        end,
                        mult = 2,
                    },
                }, "jokers", joker)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "play_hand",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { card_ids = { "card:1" } },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        luaunit.assertEquals(#queued, 1)
        queued[1].func()
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution_error)
        luaunit.assertNotNil(resolution)
        ---@cast resolution table
        luaunit.assertEquals(resolution, {
            {
                order = 1,
                phase = "joker_main",
                type = "trigger",
                component = "joker",
                source = { input_target_id = "joker:11" },
                effects = {
                    { order = 2, kind = "chips", amount = 10, chips = 15, mult = 1, score = 15 },
                    { order = 5, kind = "mult", amount = 2, chips = 15, mult = 6, score = 90 },
                    {
                        order = 6,
                        kind = "create",
                        object_kind = "consumable",
                        destination = "owned",
                        key = "c_fool",
                    },
                },
            },
            {
                order = 3,
                parent_order = 1,
                phase = "joker_main",
                type = "trigger",
                component = "playing_card",
                source = { input_target_id = "card:1" },
                effects = {
                    { order = 4, kind = "mult", amount = 3, chips = 15, mult = 4, score = 60 },
                },
            },
        })
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "create_card", saved_create)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_created_component_trigger_is_source_less_with_parent()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_create = rawget(_G, "create_card")
    local ace = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        T = { x = 1 },
    })
    local joker = {
        sort_id = 11,
        facing = "front",
        T = { x = 1 },
        ability = { set = "Joker", name = "Joker" },
        config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
        can_sell_card = function()
            return true
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ ace }, { joker })
        install_smods_calculate_fixture()
        rawset(_G, "create_card", function(_type, area)
            return {
                sort_id = 101,
                facing = "front",
                area = area,
                ability = { set = "Joker", name = "Joker" },
                config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
            }
        end)
        G.FUNCS = {
            get_poker_hand_info = function()
                return "High Card", "High Card", {}, { ace }, "High Card"
            end,
            play_cards_from_highlighted = function()
                push_smods_context({ joker_main = true, cardarea = G.jokers })
                SMODS.calculate_effect_table_key({
                    jokers = {
                        func = function()
                            local created = create_card("Joker", G.jokers)
                            G.jokers.cards[#G.jokers.cards + 1] = created
                            SMODS.calculate_effect_table_key({
                                jokers = { chips = 4 },
                            }, "jokers", created)
                        end,
                    },
                }, "jokers", joker)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "play_hand",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { card_ids = { "card:1" } },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution_error)
        luaunit.assertNotNil(resolution)
        ---@cast resolution table
        assert_resolution_matches_announced_schema(resolution, "play_hand")
        luaunit.assertEquals(#resolution, 2)
        luaunit.assertEquals(resolution[1].type, "trigger")
        luaunit.assertEquals(resolution[1].component, "joker")
        luaunit.assertEquals(resolution[1].source, { input_target_id = "joker:11" })
        luaunit.assertEquals(resolution[1].effects[1].kind, "create")
        luaunit.assertEquals(resolution[1].effects[1].object_kind, "joker")
        luaunit.assertEquals(resolution[1].effects[1].destination, "owned")
        luaunit.assertEquals(resolution[1].effects[1].key, "j_joker")
        luaunit.assertNil(resolution[1].effects[1].input_target_id)
        luaunit.assertEquals(resolution[2].type, "trigger")
        luaunit.assertEquals(resolution[2].component, "joker")
        luaunit.assertNil(resolution[2].source)
        luaunit.assertEquals(resolution[2].parent_order, resolution[1].order)
        luaunit.assertEquals(resolution[2].effects[1].kind, "chips")
        luaunit.assertNil(resolution[2].effects[1].input_target_id)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "create_card", saved_create)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_empty_calculate_on_unregistered_card_is_omitted()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local ace = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        T = { x = 1 },
    })
    local stranger = test_playing_card({
        sort_id = 99,
        key = "H_2",
        suit = "Hearts",
        rank = "2",
        nominal = 2,
        suit_nominal = 0.03,
        suit_nominal_original = 0.003,
        T = { x = 2 },
    })

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ ace }, {})
        install_smods_calculate_fixture()
        G.FUNCS = {
            get_poker_hand_info = function()
                return "High Card", "High Card", {}, { ace }, "High Card"
            end,
            play_cards_from_highlighted = function()
                push_smods_context({ main_scoring = true, cardarea = G.play })
                SMODS.calculate_effect_table_key({
                    playing_card = {},
                    enhancement = {},
                    edition = {},
                    seals = {},
                }, "playing_card", stranger)
                SMODS.calculate_effect_table_key({
                    enhancement = {},
                }, "enhancement", stranger)
                SMODS.calculate_effect_table_key({
                    edition = {},
                }, "edition", stranger)
                SMODS.calculate_effect_table_key({
                    seals = {},
                }, "seals", stranger)
                SMODS.calculate_effect_table_key({
                    playing_card = {
                        func = function()
                            SMODS.calculate_effect_table_key({
                                enhancement = {},
                            }, "enhancement", stranger)
                        end,
                    },
                }, "playing_card", stranger)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "play_hand",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { card_ids = { "card:1" } },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        luaunit.assertEquals(result.resolution and #result.resolution or 0, 0)
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution_error)
        luaunit.assertNil(resolution)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_resolution_source_requires_registered_input_identity()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local ace = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        T = { x = 1 },
    })
    local imposter = test_playing_card({
        sort_id = 1,
        key = "H_A",
        suit = "Hearts",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.03,
        suit_nominal_original = 0.003,
        T = { x = 2 },
    })

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ ace }, {})
        install_smods_calculate_fixture()
        G.FUNCS = {
            get_poker_hand_info = function()
                return "High Card", "High Card", {}, { ace }, "High Card"
            end,
            play_cards_from_highlighted = function()
                push_smods_context({ main_scoring = true, cardarea = G.play })
                SMODS.calculate_effect_table_key({
                    playing_card = { chips = 11 },
                }, "playing_card", imposter)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "play_hand",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { card_ids = { "card:1" } },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution)
        luaunit.assertNotNil(resolution_error)
        ---@cast resolution_error table
        luaunit.assertEquals(resolution_error.code, "INTERNAL_ERROR")
        luaunit.assertStrContains(resolution_error.message, "input object")
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_known_unencoded_vanilla_effect_invalidates_capture()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local ace = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        T = { x = 1 },
    })

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ ace }, {})
        install_smods_calculate_fixture()
        SMODS.calculation_keys = { "level_up" }
        G.FUNCS = {
            get_poker_hand_info = function()
                return "High Card", "High Card", {}, { ace }, "High Card"
            end,
            play_cards_from_highlighted = function()
                push_smods_context({ main_scoring = true, cardarea = G.play })
                SMODS.calculate_effect_table_key({
                    playing_card = { level_up = 1 },
                }, "playing_card", ace)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "play_hand",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { card_ids = { "card:1" } },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution)
        luaunit.assertNotNil(resolution_error)
        ---@cast resolution_error table
        luaunit.assertEquals(resolution_error.code, "INTERNAL_ERROR")
        luaunit.assertStrContains(resolution_error.message, "level_up")
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_fair_create_without_public_identity_invalidates_capture()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_create = rawget(_G, "create_card")
    local ace = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        T = { x = 1 },
    })

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ ace }, {})
        install_smods_calculate_fixture()
        rawset(_G, "create_card", function(_type)
            return {
                sort_id = 99,
                facing = "front",
                ability = { consumeable = true, set = "Tarot" },
                config = { center = { key = "c_fool", set = "Tarot" } },
            }
        end)
        G.FUNCS = {
            get_poker_hand_info = function()
                return "High Card", "High Card", {}, { ace }, "High Card"
            end,
            play_cards_from_highlighted = function()
                push_smods_context({ main_scoring = true, cardarea = G.play })
                SMODS.calculate_effect_table_key({
                    playing_card = {
                        func = function()
                            create_card("Tarot")
                        end,
                    },
                }, "playing_card", ace)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "play_hand",
            expected_state_hash = "sha256:test",
            visibility = "fair",
            arguments = {},
            targets = { card_ids = { "card:1" } },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution)
        luaunit.assertNotNil(resolution_error)
        ---@cast resolution_error table
        luaunit.assertStrContains(resolution_error.message, "not visible")
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "create_card", saved_create)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_death_overwrites_an_input_card_without_create()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_card = rawget(_G, "Card")
    local saved_copy = rawget(_G, "copy_card")
    local source = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
    })
    local destination = test_playing_card({
        sort_id = 2,
        key = "H_K",
        suit = "Hearts",
        rank = "King",
        nominal = 10,
        suit_nominal = 0.03,
        suit_nominal_original = 0.003,
    })
    local death = {
        sort_id = 21,
        ability = {
            set = "Tarot",
            name = "Death",
            consumeable = { mod_conv = "card", min_highlighted = 2, max_highlighted = 2 },
        },
        config = { center = { key = "c_death", set = "Tarot" } },
        can_use_consumeable = function()
            return true
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ source, destination }, {})
        local highlighted = {}
        G.hand.highlighted = highlighted
        G.hand.add_to_highlighted = function(_, card)
            highlighted[#highlighted + 1] = card
        end
        G.hand.unhighlight_all = function() end
        G.consumeables.cards = { death }
        death.area = G.consumeables
        _G.Card = {
            use_consumeable = function()
                copy_card(source, destination)
            end,
            start_dissolve = function(card)
                card.dissolved = true
            end,
        }
        rawset(_G, "copy_card", function(other, new_card)
            new_card.config.card_key = other.config.card_key
            new_card.config.center = other.config.center
            new_card.base = other.base
            new_card.ability = other.ability
            return new_card
        end)
        G.FUNCS = {
            use_card = function(e)
                Card.use_consumeable(e.config.ref_table)
                Card.start_dissolve(e.config.ref_table)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "use_consumable",
            expected_state_hash = "sha256:test",
            visibility = "fair",
            arguments = {},
            targets = {
                consumable_id = "consumable:21",
                target_ids = { "card:1", "card:2" },
            },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution_error)
        assert_resolution_matches_announced_schema(resolution)
        luaunit.assertEquals(resolution, {
            {
                order = 1,
                phase = "hand",
                type = "apply",
                component = "tarot",
                key = "c_death",
                source = { input_target_id = "consumable:21" },
                effects = {
                    {
                        order = 2,
                        kind = "copy",
                        mode = "overwrite",
                        source = { input_target_id = "card:1" },
                        destination = { input_target_id = "card:2" },
                    },
                },
            },
        })
        luaunit.assertTrue(death.dissolved)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "Card", saved_card)
    rawset(_G, "copy_card", saved_copy)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_ankh_destroys_inputs_and_creates_one_unidentified_copy()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_card = rawget(_G, "Card")
    local saved_copy = rawget(_G, "copy_card")
    local source = {
        sort_id = 11,
        facing = "front",
        edition = { foil = true, type = "foil" },
        ability = { set = "Joker", name = "Joker" },
        config = { center = { key = "j_joker", set = "Joker" } },
    }
    local destroyed = {
        sort_id = 12,
        facing = "front",
        added_to_deck = true,
        edition = { negative = true, type = "negative" },
        ability = { set = "Joker", name = "Jolly Joker" },
        config = { center = { key = "j_jolly", set = "Joker" } },
    }
    local ankh = {
        sort_id = 21,
        ability = { set = "Spectral", name = "Ankh", consumeable = {} },
        config = { center = { key = "c_ankh", set = "Spectral" } },
        can_use_consumeable = function()
            return true
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({}, { source, destroyed })
        G.jokers.config.card_limit = 6
        G.consumeables.cards = { ankh }
        ankh.area = G.consumeables
        _G.Card = {
            use_consumeable = function()
                Card.start_dissolve(destroyed)
                copy_card(source)
            end,
            start_dissolve = function(card)
                Card.remove_from_deck(card)
                card.dissolved = true
            end,
            remove_from_deck = function(card)
                if card.added_to_deck and card.edition and card.edition.negative then
                    G.jokers.config.card_limit = G.jokers.config.card_limit - 1
                    card.added_to_deck = false
                end
            end,
        }
        rawset(_G, "copy_card", function(other)
            return {
                facing = "front",
                edition = other.edition,
                ability = { set = "Joker", name = other.ability.name },
                config = { center = other.config.center },
            }
        end)
        G.FUNCS = {
            use_card = function(e)
                Card.use_consumeable(e.config.ref_table)
                Card.start_dissolve(e.config.ref_table)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "use_consumable",
            expected_state_hash = "sha256:test",
            visibility = "fair",
            arguments = {},
            targets = { consumable_id = "consumable:21" },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution_error)
        luaunit.assertNotNil(resolution)
        ---@cast resolution table
        assert_resolution_matches_announced_schema(resolution)
        luaunit.assertEquals(resolution[1].effects, {
            { order = 2, kind = "destroy", input_target_id = "joker:12" },
            {
                order = 3,
                kind = "capacity",
                resource = "joker_slots",
                amount = -1,
                value = 5,
            },
            {
                order = 4,
                kind = "copy",
                mode = "create",
                source = { input_target_id = "joker:11" },
                object_kind = "joker",
                destination = "owned",
                key = "j_joker",
                edition = "e_foil",
            },
        })
        luaunit.assertNil(resolution[1].effects[3].input_target_id)
        luaunit.assertEquals(resolution[1].effects[3].destination, "owned")
        luaunit.assertTrue(destroyed.dissolved)
        luaunit.assertTrue(ankh.dissolved)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "Card", saved_card)
    rawset(_G, "copy_card", saved_copy)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_consumable_mutation_seams_preserve_effect_order()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_card = rawget(_G, "Card")
    local saved_card_area = rawget(_G, "CardArea")
    local saved_ease_dollars = rawget(_G, "ease_dollars")
    local saved_level_up_hand = rawget(_G, "level_up_hand")
    local saved_create = rawget(_G, "create_card")
    local saved_copy = rawget(_G, "copy_card")
    local ace = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
    })
    local king = test_playing_card({
        sort_id = 2,
        key = "H_K",
        suit = "Hearts",
        rank = "King",
        nominal = 10,
        suit_nominal = 0.03,
        suit_nominal_original = 0.003,
    })
    local joker = {
        sort_id = 11,
        facing = "front",
        added_to_deck = true,
        ability = { set = "Joker", name = "Joker" },
        config = { center = { key = "j_joker", set = "Joker" } },
    }
    local other_joker = {
        sort_id = 12,
        facing = "front",
        added_to_deck = true,
        ability = { set = "Joker", name = "Jolly Joker" },
        config = { center = { key = "j_jolly", set = "Joker" } },
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ ace, king }, { joker, other_joker })
        G.hand.config = { card_limit = 8 }
        G.P_CARDS.S_K = { name = "King of Spades", suit = "Spades", value = "King" }
        G.P_CARDS.S_Q = { name = "Queen of Spades", suit = "Spades", value = "Queen" }
        G.P_CARDS.H_Q = { name = "Queen of Hearts", suit = "Hearts", value = "Queen" }
        G.P_CENTERS.m_lucky = { key = "m_lucky", set = "Enhanced", name = "Lucky Card" }
        G.GAME.hands["High Card"] = {
            visible = true,
            level = 1,
            chips = 5,
            mult = 1,
            s_chips = 5,
            l_chips = 10,
            s_mult = 1,
            l_mult = 1,
            played = 0,
        }
        local queued = {}
        G.E_MANAGER = {
            add_event = function(_, event)
                queued[#queued + 1] = event
            end,
        }
        _G.CardArea = {
            change_size = function(area, amount)
                area.config.card_limit = area.config.card_limit + amount
            end,
        }
        setmetatable(G.hand, { __index = CardArea })
        _G.Card = {
            set_base = function(card, base)
                card.config.card_key = base.key
                card.base = { suit = base.suit, value = base.value }
            end,
            set_ability = function(card, center)
                card.config.center = center
                card.ability = { set = center.set, name = center.name }
                card.debuff = true
            end,
            set_seal = function(card, seal)
                card.seal = seal
            end,
            set_edition = function(card, edition)
                if edition and edition.negative and not card.edition and card.added_to_deck then
                    G.jokers.config.card_limit = G.jokers.config.card_limit + 1
                end
                if edition and edition.negative then
                    card.edition = { negative = true, type = "negative" }
                elseif edition and edition.polychrome then
                    card.edition = { polychrome = true, type = "polychrome" }
                else
                    card.edition = nil
                end
            end,
            start_dissolve = function(card)
                card.dissolved = true
            end,
            use_consumeable = function(card)
                local key = card.config.center.key
                if key == "c_hermit" then
                    ease_dollars(4, true)
                elseif key == "c_temperance" then
                    ease_dollars(3, true)
                elseif key == "c_pluto" then
                    level_up_hand(card, "High Card", true, 1)
                elseif key == "c_strength" then
                    Card.set_base(ace, {
                        key = "S_K",
                        suit = "Spades",
                        value = "King",
                    })
                elseif key == "c_magician" then
                    Card.set_ability(king, G.P_CENTERS.m_lucky)
                elseif key == "c_talisman" then
                    Card.set_seal(king, "Gold")
                elseif key == "c_ouija" then
                    Card.set_base(ace, {
                        key = "S_Q",
                        suit = "Spades",
                        value = "Queen",
                    })
                    Card.set_base(king, {
                        key = "H_Q",
                        suit = "Hearts",
                        value = "Queen",
                    })
                    G.hand:change_size(-1)
                elseif key == "c_sigil" then
                    Card.set_base(ace, {
                        key = "D_Q",
                        suit = "Diamonds",
                        value = "Queen",
                    })
                elseif key == "c_ectoplasm" then
                    Card.set_edition(joker, { negative = true })
                    G.hand:change_size(-2)
                elseif key == "c_wheel_of_fortune" and not card.noop then
                    Card.set_edition(joker, { polychrome = true })
                elseif key == "c_hex" then
                    Card.set_edition(other_joker, { polychrome = true })
                    Card.start_dissolve(joker)
                elseif key == "c_immolate" then
                    Card.start_dissolve(ace)
                    Card.start_dissolve(king)
                    ease_dollars(20)
                elseif key == "c_cryptid" then
                    copy_card(ace)
                    copy_card(ace)
                elseif key == "c_judgement" then
                    create_card("Joker", G.jokers)
                end
            end,
        }
        setmetatable(ace, { __index = Card })
        setmetatable(king, { __index = Card })
        setmetatable(joker, { __index = Card })
        setmetatable(other_joker, { __index = Card })
        rawset(_G, "ease_dollars", function(amount, instant)
            if instant then
                G.GAME.dollars = G.GAME.dollars + amount
            else
                G.E_MANAGER:add_event({
                    func = function()
                        G.GAME.dollars = G.GAME.dollars + amount
                        return true
                    end,
                })
            end
        end)
        rawset(_G, "level_up_hand", function(_card, hand, _instant, amount)
            local value = G.GAME.hands[hand]
            value.level = value.level + amount
            value.chips = value.s_chips + value.l_chips * (value.level - 1)
            value.mult = value.s_mult + value.l_mult * (value.level - 1)
        end)
        rawset(_G, "create_card", function()
            return {
                facing = "front",
                ability = { set = "Joker", name = "Judgement Joker" },
                config = { center = { key = "j_judgement", set = "Joker" } },
            }
        end)
        rawset(_G, "copy_card", function(source)
            return {
                facing = "front",
                ability = source.ability,
                config = {
                    card_key = source.config.card_key,
                    center = source.config.center,
                },
                base = source.base,
                edition = source.edition,
                seal = source.seal,
            }
        end)
        G.FUNCS = {
            use_card = function(e)
                Card.use_consumeable(e.config.ref_table)
                Card.start_dissolve(e.config.ref_table)
            end,
        }

        local function consumable(key, set, config)
            local card = {
                sort_id = 20 + #G.consumeables.cards + 1,
                ability = {
                    set = set,
                    name = key,
                    consumeable = config or {},
                },
                config = { center = { key = key, set = set } },
                can_use_consumeable = function()
                    return true
                end,
            }
            setmetatable(card, { __index = Card })
            G.consumeables.cards = { card }
            card.area = G.consumeables
            return card
        end

        local function capture(card, target_ids)
            local adapter = ProductionBalatroAdapter.new()
            local result, action_error = adapter:execute({
                name = "use_consumable",
                expected_state_hash = "sha256:test",
                visibility = "fair",
                arguments = {},
                targets = {
                    consumable_id = "consumable:" .. tostring(card.sort_id),
                    target_ids = target_ids,
                },
            })
            luaunit.assertNil(action_error)
            luaunit.assertNotNil(result)
            ---@cast result table
            while queued[1] do
                table.remove(queued, 1).func()
            end
            local resolution, resolution_error =
                adapter:finish_resolution(result.resolution_context)
            luaunit.assertNil(resolution_error)
            assert_resolution_matches_announced_schema(resolution)
            return resolution
        end

        local function apply(card, target_ids)
            return assert(capture(card, target_ids))
        end

        G.STATE = G.STATES.SHOP
        local hermit = apply(consumable("c_hermit", "Tarot"))
        luaunit.assertEquals(hermit[1].phase, "shop")
        luaunit.assertEquals(hermit[1].effects, {
            { order = 2, kind = "dollars", amount = 4, money = 10 },
        })

        G.STATE = G.STATES.SELECTING_HAND
        local temperance = apply(consumable("c_temperance", "Tarot"))
        luaunit.assertEquals(temperance[1].effects, {
            { order = 2, kind = "dollars", amount = 3, money = 13 },
        })

        local pluto = apply(consumable("c_pluto", "Planet", { hand_type = "High Card" }))
        luaunit.assertEquals(pluto[1].component, "planet")
        luaunit.assertEquals(pluto[1].effects, {
            {
                order = 2,
                kind = "poker_hand_level",
                poker_hand = "High Card",
                amount = 1,
                level = 2,
                chips = 15,
                mult = 2,
            },
        })

        local strength = apply(
            consumable("c_strength", "Tarot", { max_highlighted = 2, min_highlighted = 1 }),
            { "card:1" }
        )
        luaunit.assertEquals(strength[1].effects, {
            {
                order = 2,
                kind = "set_card_state",
                input_target_id = "card:1",
                state = "rank",
                value = "King",
            },
        })

        local magician = apply(
            consumable("c_magician", "Tarot", { max_highlighted = 2, min_highlighted = 1 }),
            { "card:2" }
        )
        luaunit.assertEquals(magician[1].effects, {
            {
                order = 2,
                kind = "set_card_state",
                input_target_id = "card:2",
                state = "enhancement",
                value = "m_lucky",
            },
            {
                order = 3,
                kind = "set_card_state",
                input_target_id = "card:2",
                state = "debuffed",
                value = true,
            },
        })

        local talisman = apply(
            consumable("c_talisman", "Spectral", { max_highlighted = 1, min_highlighted = 1 }),
            { "card:2" }
        )
        luaunit.assertEquals(talisman[1].effects[1].state, "seal")
        luaunit.assertEquals(talisman[1].effects[1].value, "Gold")

        local ouija = apply(consumable("c_ouija", "Spectral"))
        luaunit.assertEquals(ouija[1].effects, {
            {
                order = 2,
                kind = "set_card_state",
                input_target_id = "card:1",
                state = "rank",
                value = "Queen",
            },
            {
                order = 3,
                kind = "set_card_state",
                input_target_id = "card:2",
                state = "rank",
                value = "Queen",
            },
            {
                order = 4,
                kind = "capacity",
                resource = "hand_size",
                amount = -1,
                value = 7,
            },
        })

        local sigil = apply(consumable("c_sigil", "Spectral"))
        luaunit.assertEquals(sigil[1].effects, {
            {
                order = 2,
                kind = "set_card_state",
                input_target_id = "card:1",
                state = "suit",
                value = "Diamonds",
            },
        })

        local ectoplasm = apply(consumable("c_ectoplasm", "Spectral"))
        luaunit.assertEquals(ectoplasm[1].effects, {
            {
                order = 2,
                kind = "capacity",
                resource = "joker_slots",
                amount = 1,
                value = 6,
            },
            {
                order = 3,
                kind = "set_card_state",
                input_target_id = "joker:11",
                state = "edition",
                value = "e_negative",
            },
            {
                order = 4,
                kind = "capacity",
                resource = "hand_size",
                amount = -2,
                value = 5,
            },
        })

        local wheel = apply(consumable("c_wheel_of_fortune", "Tarot"))
        luaunit.assertEquals(wheel[1].effects, {
            {
                order = 2,
                kind = "set_card_state",
                input_target_id = "joker:11",
                state = "edition",
                value = "e_polychrome",
            },
        })
        local wheel_noop = consumable("c_wheel_of_fortune", "Tarot")
        wheel_noop.noop = true
        luaunit.assertNil(capture(wheel_noop))

        local hex = apply(consumable("c_hex", "Spectral"))
        luaunit.assertEquals(hex[1].effects, {
            {
                order = 2,
                kind = "set_card_state",
                input_target_id = "joker:12",
                state = "edition",
                value = "e_polychrome",
            },
            { order = 3, kind = "destroy", input_target_id = "joker:11" },
        })

        local immolate = apply(consumable("c_immolate", "Spectral"))
        luaunit.assertEquals(immolate[1].effects, {
            { order = 2, kind = "destroy", input_target_id = "card:1" },
            { order = 3, kind = "destroy", input_target_id = "card:2" },
            { order = 4, kind = "dollars", amount = 20, money = 33 },
        })

        local cryptid = apply(consumable("c_cryptid", "Spectral"))
        luaunit.assertEquals(cryptid[1].effects, {
            {
                order = 2,
                kind = "copy",
                mode = "create",
                source = { input_target_id = "card:1" },
                object_kind = "playing_card",
                destination = "permanent_deck",
                key = "D_Q",
                rank = "Queen",
                suit = "Diamonds",
            },
            {
                order = 3,
                kind = "copy",
                mode = "create",
                source = { input_target_id = "card:1" },
                object_kind = "playing_card",
                destination = "permanent_deck",
                key = "D_Q",
                rank = "Queen",
                suit = "Diamonds",
            },
        })
        for _, effect in ipairs(cryptid[1].effects) do
            luaunit.assertNil(effect.input_target_id)
        end

        local judgement = apply(consumable("c_judgement", "Tarot"))
        luaunit.assertEquals(judgement[1].effects, {
            {
                order = 2,
                kind = "create",
                object_kind = "joker",
                destination = "owned",
                key = "j_judgement",
            },
        })
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "Card", saved_card)
    rawset(_G, "CardArea", saved_card_area)
    rawset(_G, "ease_dollars", saved_ease_dollars)
    rawset(_G, "level_up_hand", saved_level_up_hand)
    rawset(_G, "create_card", saved_create)
    rawset(_G, "copy_card", saved_copy)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_black_hole_records_every_upgraded_hand()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_card = rawget(_G, "Card")
    local saved_level_up_hand = rawget(_G, "level_up_hand")
    local black_hole = {
        sort_id = 21,
        ability = { set = "Spectral", name = "Black Hole", consumeable = {} },
        config = { center = { key = "c_black_hole", set = "Spectral" } },
        can_use_consumeable = function()
            return true
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({}, {})
        G.GAME.hands = {
            ["High Card"] = { visible = true, level = 1, chips = 5, mult = 1 },
            ["Flush Five"] = { visible = false, level = 1, chips = 160, mult = 16 },
        }
        G.consumeables.cards = { black_hole }
        black_hole.area = G.consumeables
        _G.Card = {
            use_consumeable = function(card)
                level_up_hand(card, "High Card", true, 1)
                level_up_hand(card, "Flush Five", true, 1)
            end,
            start_dissolve = function(card)
                card.dissolved = true
            end,
        }
        rawset(_G, "level_up_hand", function(_card, hand, _instant, amount)
            local value = G.GAME.hands[hand]
            value.level = value.level + amount
            value.chips = value.chips + (hand == "High Card" and 10 or 50)
            value.mult = value.mult + (hand == "High Card" and 1 or 3)
        end)
        G.FUNCS = {
            use_card = function(e)
                Card.use_consumeable(e.config.ref_table)
                Card.start_dissolve(e.config.ref_table)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "use_consumable",
            expected_state_hash = "sha256:test",
            visibility = "fair",
            arguments = {},
            targets = { consumable_id = "consumable:21" },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution_error)
        luaunit.assertNotNil(resolution)
        ---@cast resolution table
        assert_resolution_matches_announced_schema(resolution)
        luaunit.assertEquals(resolution[1].effects, {
            {
                order = 2,
                kind = "poker_hand_level",
                poker_hand = "High Card",
                amount = 1,
                level = 2,
                chips = 15,
                mult = 2,
            },
            {
                order = 3,
                kind = "poker_hand_level",
                poker_hand = "Flush Five",
                amount = 1,
                level = 2,
                chips = 210,
                mult = 19,
            },
        })
        luaunit.assertEquals(G.GAME.hands["Flush Five"].level, 2)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "Card", saved_card)
    rawset(_G, "level_up_hand", saved_level_up_hand)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_wraith_records_created_joker_before_money_reset()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_card = rawget(_G, "Card")
    local saved_create = rawget(_G, "create_card")
    local saved_ease_dollars = rawget(_G, "ease_dollars")
    local wraith = {
        sort_id = 21,
        ability = { set = "Spectral", name = "Wraith", consumeable = {} },
        config = { center = { key = "c_wraith", set = "Spectral" } },
        can_use_consumeable = function()
            return true
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({}, {})
        G.consumeables.cards = { wraith }
        wraith.area = G.consumeables
        _G.Card = {
            use_consumeable = function()
                create_card("Joker", G.jokers)
                ease_dollars(-G.GAME.dollars, true)
            end,
            start_dissolve = function(card)
                card.dissolved = true
            end,
        }
        rawset(_G, "create_card", function()
            return {
                facing = "front",
                edition = { holo = true, type = "holo" },
                ability = { set = "Joker", name = "Rare Joker" },
                config = { center = { key = "j_rare", set = "Joker" } },
            }
        end)
        rawset(_G, "ease_dollars", function(amount, _instant)
            G.GAME.dollars = G.GAME.dollars + amount
        end)
        G.FUNCS = {
            use_card = function(e)
                Card.use_consumeable(e.config.ref_table)
                Card.start_dissolve(e.config.ref_table)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "use_consumable",
            expected_state_hash = "sha256:test",
            visibility = "fair",
            arguments = {},
            targets = { consumable_id = "consumable:21" },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution_error)
        luaunit.assertNotNil(resolution)
        ---@cast resolution table
        assert_resolution_matches_announced_schema(resolution)
        luaunit.assertEquals(resolution[1].effects, {
            {
                order = 2,
                kind = "create",
                object_kind = "joker",
                destination = "owned",
                key = "j_rare",
                edition = "e_holo",
            },
            { order = 3, kind = "dollars", amount = -6, money = 0 },
        })
        luaunit.assertTrue(wraith.dissolved)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "Card", saved_card)
    rawset(_G, "create_card", saved_create)
    rawset(_G, "ease_dollars", saved_ease_dollars)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_familiar_records_destroy_and_public_playing_card_features()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_card = rawget(_G, "Card")
    local saved_create_playing = rawget(_G, "create_playing_card")
    local victim = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
    })
    local familiar = {
        sort_id = 21,
        ability = { set = "Spectral", name = "Familiar", consumeable = {} },
        config = { center = { key = "c_familiar", set = "Spectral" } },
        can_use_consumeable = function()
            return true
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ victim }, {})
        G.consumeables.cards = { familiar }
        familiar.area = G.consumeables
        _G.Card = {
            use_consumeable = function()
                Card.start_dissolve(victim)
                create_playing_card({}, G.hand)
            end,
            start_dissolve = function(card)
                card.dissolved = true
            end,
        }
        rawset(_G, "create_playing_card", function(_card_init, _area)
            return {
                facing = "front",
                edition = { foil = true, type = "foil" },
                seal = "Red",
                ability = { set = "Enhanced", name = "Lucky Card" },
                config = {
                    card_key = "H_Q",
                    center = { key = "m_lucky", set = "Enhanced" },
                },
                base = { suit = "Hearts", value = "Queen" },
            }
        end)
        G.FUNCS = {
            use_card = function(e)
                Card.use_consumeable(e.config.ref_table)
                Card.start_dissolve(e.config.ref_table)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "use_consumable",
            expected_state_hash = "sha256:test",
            visibility = "fair",
            arguments = {},
            targets = { consumable_id = "consumable:21" },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution_error)
        luaunit.assertNotNil(resolution)
        ---@cast resolution table
        assert_resolution_matches_announced_schema(resolution)
        luaunit.assertEquals(resolution[1].effects, {
            { order = 2, kind = "destroy", input_target_id = "card:1" },
            {
                order = 3,
                kind = "create",
                object_kind = "playing_card",
                destination = "permanent_deck",
                key = "H_Q",
                rank = "Queen",
                suit = "Hearts",
                enhancement = "m_lucky",
                edition = "e_foil",
                seal = "Red",
            },
        })
        luaunit.assertTrue(victim.dissolved)
        luaunit.assertTrue(familiar.dissolved)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "Card", saved_card)
    rawset(_G, "create_playing_card", saved_create_playing)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_consumable_apply_keeps_child_and_suppresses_self_destroy()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_card = rawget(_G, "Card")
    local ace = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        T = { x = 1 },
    })
    local joker = {
        sort_id = 11,
        facing = "front",
        T = { x = 1 },
        ability = { set = "Joker", name = "Joker" },
        config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
        can_sell_card = function()
            return true
        end,
    }
    local tarot = {
        sort_id = 21,
        ability = { set = "Tarot", consumeable = {}, name = "Wheel of Fortune" },
        config = { center = { key = "c_wheel_of_fortune", set = "Tarot" } },
        can_use_consumeable = function()
            return true
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ ace }, { joker })
        install_smods_calculate_fixture()
        G.consumeables.cards = { tarot }
        local queued = {}
        G.E_MANAGER = {
            add_event = function(_, event)
                queued[#queued + 1] = event
            end,
        }
        _G.Card = {
            use_consumeable = function()
                G.E_MANAGER:add_event({
                    func = function()
                        push_smods_context({
                            joker_main = true,
                            cardarea = G.jokers,
                            using_consumeable = true,
                        })
                        SMODS.calculate_effect_table_key({
                            jokers = { chips = 7 },
                        }, "jokers", joker)
                        return true
                    end,
                })
            end,
            start_dissolve = function(card)
                card.dissolved = true
            end,
        }
        G.FUNCS = {
            use_card = function(e)
                Card.use_consumeable(e.config.ref_table)
                Card.start_dissolve(e.config.ref_table)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local result, action_error = adapter:execute({
            name = "use_consumable",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { consumable_id = "consumable:21" },
        })
        luaunit.assertNil(action_error)
        luaunit.assertNotNil(result)
        ---@cast result table
        luaunit.assertEquals(#queued, 1)
        queued[1].func()
        local resolution, resolution_error = adapter:finish_resolution(result.resolution_context)
        luaunit.assertNil(resolution_error)
        luaunit.assertNotNil(resolution)
        ---@cast resolution table
        assert_resolution_matches_announced_schema(resolution)
        luaunit.assertEquals(resolution, {
            {
                order = 1,
                phase = "hand",
                type = "apply",
                component = "tarot",
                key = "c_wheel_of_fortune",
                source = { input_target_id = "consumable:21" },
                effects = {},
            },
            {
                order = 2,
                parent_order = 1,
                phase = "joker_main",
                type = "trigger",
                component = "joker",
                source = { input_target_id = "joker:11" },
                effects = {
                    { order = 3, kind = "chips", amount = 7, chips = 12, mult = 1, score = 12 },
                },
            },
        })
        luaunit.assertTrue(tarot.dissolved)
        for _, event in ipairs(resolution) do
            for _, effect in ipairs(event.effects) do
                luaunit.assertNotEquals(effect.kind, "destroy")
            end
        end
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "Card", saved_card)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_play_hand_resolution_groups_vanilla_scoring_components()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local ace = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        T = { x = 1 },
    })
    local king = test_playing_card({
        sort_id = 2,
        key = "H_K",
        suit = "Hearts",
        rank = "King",
        nominal = 10,
        suit_nominal = 0.03,
        suit_nominal_original = 0.003,
        T = { x = 2 },
    })
    king.debuff = true
    local steel = test_playing_card({
        sort_id = 3,
        key = "D_2",
        suit = "Diamonds",
        rank = "2",
        nominal = 2,
        suit_nominal = 0.01,
        suit_nominal_original = 0.001,
        T = { x = 3 },
    })
    local hanging_chad = {
        sort_id = 11,
        facing = "front",
        T = { x = 1 },
        ability = { set = "Joker", name = "Hanging Chad" },
        config = { center = { key = "j_hanging_chad", set = "Joker", name = "Hanging Chad" } },
        can_sell_card = function()
            return true
        end,
    }
    local joker = {
        sort_id = 12,
        facing = "front",
        T = { x = 2 },
        ability = { set = "Joker", name = "Joker", mult = 4 },
        config = { center = { key = "j_joker", set = "Joker", name = "Joker" } },
        can_sell_card = function()
            return true
        end,
    }
    local facedown_joker = {
        sort_id = 13,
        facing = "back",
        T = { x = 3 },
        ability = { set = "Joker", name = "Fibonacci" },
        config = { center = { key = "j_fibonacci", set = "Joker", name = "Fibonacci" } },
        can_sell_card = function()
            return true
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ ace, king, steel }, { hanging_chad, joker, facedown_joker })
        install_smods_calculate_fixture()
        G.play = { cards = { ace, king } }
        G.FUNCS = {
            get_poker_hand_info = function()
                return "High Card", "High Card", {}, { ace }, "High Card"
            end,
            play_cards_from_highlighted = function()
                push_smods_context({ main_scoring = true, cardarea = G.play })
                SMODS.calculate_effect_table_key({
                    playing_card = { chips = 11 },
                }, "playing_card", ace)
                SMODS.calculate_effect_table_key({
                    enhancement = { x_mult = 2 },
                }, "enhancement", ace)
                SMODS.calculate_effect_table_key({
                    edition = { chips = 50 },
                }, "edition", ace)
                SMODS.calculate_effect_table_key({
                    seals = { p_dollars = 3 },
                }, "seals", ace)
                SMODS.calculate_effect({
                    message = "Again!",
                    repetitions = 1,
                    card = hanging_chad,
                }, hanging_chad)
                ace.repetition_trigger = 1
                SMODS.calculate_effect_table_key({
                    playing_card = { chips = 11 },
                }, "playing_card", ace)
                ace.repetition_trigger = nil
                SMODS.calculate_effect_table_key({
                    jokers = { message = "Nope" },
                }, "jokers", hanging_chad)
                SMODS.calculate_main_scoring({
                    cardarea = G.play,
                    main_scoring = true,
                }, { ace, king })
                push_smods_context({ main_scoring = true, cardarea = G.hand })
                SMODS.calculate_effect_table_key({
                    playing_card = { x_mult = 2 },
                }, "playing_card", steel)
                push_smods_context({ joker_main = true, cardarea = G.jokers })
                SMODS.calculate_effect_table_key({
                    jokers = { chips = 30, mult = 4, x_mult = 2 },
                }, "jokers", joker)
                SMODS.calculate_effect_table_key({
                    jokers = { mult = 4 },
                }, "jokers", facedown_joker)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local play_result, play_error = adapter:execute({
            name = "play_hand",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { card_ids = { "card:1", "card:2" } },
        })
        luaunit.assertNil(play_error)
        luaunit.assertNotNil(play_result)
        ---@cast play_result table
        local resolution, resolution_error =
            adapter:finish_resolution(play_result.resolution_context)
        luaunit.assertNil(resolution_error)
        luaunit.assertNotNil(resolution)
        ---@cast resolution table
        luaunit.assertEquals(#resolution, 9)
        luaunit.assertNotEquals(resolution[1].type, "hand_played")
        luaunit.assertEquals(resolution[1], {
            order = 1,
            phase = "playing_card",
            type = "trigger",
            component = "playing_card",
            source = { input_target_id = "card:1" },
            effects = {
                { order = 2, kind = "chips", amount = 11, chips = 16, mult = 1, score = 16 },
            },
        })
        luaunit.assertEquals(resolution[2], {
            order = 3,
            phase = "playing_card",
            type = "trigger",
            component = "enhancement",
            source = { input_target_id = "card:1" },
            effects = {
                { order = 4, kind = "x_mult", amount = 2, chips = 16, mult = 2, score = 32 },
            },
        })
        luaunit.assertEquals(resolution[3], {
            order = 5,
            phase = "playing_card",
            type = "trigger",
            component = "edition",
            source = { input_target_id = "card:1" },
            effects = {
                { order = 6, kind = "chips", amount = 50, chips = 66, mult = 2, score = 132 },
            },
        })
        luaunit.assertEquals(resolution[4], {
            order = 7,
            phase = "playing_card",
            type = "trigger",
            component = "seal",
            source = { input_target_id = "card:1" },
            effects = { { order = 8, kind = "dollars", amount = 3, money = 9 } },
        })
        luaunit.assertEquals(resolution[5], {
            order = 9,
            phase = "playing_card",
            type = "retrigger",
            component = "playing_card",
            source = { input_target_id = "card:1" },
            parent_order = 1,
            cause = { input_target_id = "joker:11" },
            effects = {
                { order = 10, kind = "chips", amount = 11, chips = 77, mult = 2, score = 154 },
            },
        })
        luaunit.assertEquals(resolution[6], {
            order = 12,
            phase = "playing_card",
            type = "debuff_blocked",
            component = "playing_card",
            source = { input_target_id = "card:2" },
            effects = {},
        })
        luaunit.assertEquals(resolution[7], {
            order = 13,
            phase = "held_in_hand",
            type = "trigger",
            component = "playing_card",
            source = { input_target_id = "card:3" },
            effects = {
                { order = 14, kind = "x_mult", amount = 2, chips = 77, mult = 4, score = 308 },
            },
        })
        luaunit.assertEquals(resolution[8], {
            order = 15,
            phase = "joker_main",
            type = "trigger",
            component = "joker",
            source = { input_target_id = "joker:12" },
            effects = {
                { order = 16, kind = "chips", amount = 30, chips = 107, mult = 4, score = 428 },
                { order = 17, kind = "mult", amount = 4, chips = 107, mult = 8, score = 856 },
                { order = 18, kind = "x_mult", amount = 2, chips = 107, mult = 16, score = 1712 },
            },
        })
        luaunit.assertEquals(resolution[9], {
            order = 19,
            phase = "joker_main",
            type = "trigger",
            component = "joker",
            source = { input_target_id = "joker:13" },
            effects = {
                { order = 20, kind = "mult", amount = 4, chips = 107, mult = 20, score = 2140 },
            },
        })
        luaunit.assertNil(resolution[9].source.key)
        luaunit.assertNil(resolution[9].source.name)
        for _, event in ipairs(resolution) do
            luaunit.assertNil(event.message)
            for _, effect in ipairs(event.effects) do
                luaunit.assertNotEquals(effect.kind, "message")
            end
        end

        selecting_hand_globals({ ace }, { joker })
        install_smods_calculate_fixture()
        G.FUNCS = {
            get_poker_hand_info = function()
                return "High Card", "High Card", {}, { ace }, "High Card"
            end,
            play_cards_from_highlighted = function() end,
        }
        local pending, pending_error = ProductionBalatroAdapter.new():execute({
            name = "play_hand",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { card_ids = { "card:1" } },
        })
        luaunit.assertNil(pending_error)
        ---@cast pending table
        luaunit.assertEquals(pending.resolution, {})
        push_smods_context({ joker_main = true, cardarea = G.jokers })
        SMODS.calculate_effect_table_key({
            jokers = { chips = 30, mult = 4 },
        }, "jokers", joker)
        luaunit.assertEquals(pending.resolution, {
            {
                order = 1,
                phase = "joker_main",
                type = "trigger",
                component = "joker",
                source = { input_target_id = "joker:12" },
                effects = {
                    { order = 2, kind = "chips", amount = 30, chips = 35, mult = 1, score = 35 },
                    { order = 3, kind = "mult", amount = 4, chips = 35, mult = 5, score = 175 },
                },
            },
        })
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    if not ok then
        error(test_error)
    end
end

function TestProductionAdapter:test_play_hand_resolution_records_vanilla_outcomes()
    local saved_g = rawget(_G, "G")
    local saved_smods = rawget(_G, "SMODS")
    local saved_create = rawget(_G, "create_card")
    local saved_copy = rawget(_G, "copy_card")
    local glass = test_playing_card({
        sort_id = 1,
        key = "S_A",
        suit = "Spades",
        rank = "Ace",
        nominal = 11,
        suit_nominal = 0.04,
        suit_nominal_original = 0.004,
        T = { x = 1 },
    })
    glass.ability.effect = "Glass Card"
    glass.ability.name = "Glass Card"
    local six = test_playing_card({
        sort_id = 4,
        key = "C_6",
        suit = "Clubs",
        rank = "6",
        nominal = 6,
        suit_nominal = 0.01,
        suit_nominal_original = 0.001,
        T = { x = 2 },
    })
    local sixth_sense = {
        sort_id = 14,
        facing = "front",
        T = { x = 1 },
        ability = { set = "Joker", name = "Sixth Sense" },
        config = { center = { key = "j_sixth_sense", set = "Joker", name = "Sixth Sense" } },
        can_sell_card = function()
            return true
        end,
    }
    local dna = {
        sort_id = 15,
        facing = "front",
        T = { x = 2 },
        ability = { set = "Joker", name = "DNA" },
        config = { center = { key = "j_dna", set = "Joker", name = "DNA" } },
        can_sell_card = function()
            return true
        end,
    }

    local ok, test_error = xpcall(function()
        selecting_hand_globals({ glass, six }, { sixth_sense, dna })
        install_smods_calculate_fixture()
        G.play = { cards = { glass, six } }
        G.STATES.ROUND_EVAL = 8
        rawset(_G, "create_card", function(_type, _area)
            return {
                sort_id = 101,
                ability = { consumeable = true, set = _type },
                config = { center = { key = "c_sigil", set = _type } },
            }
        end)
        rawset(_G, "copy_card", function(other)
            return {
                sort_id = 100,
                config = {
                    card_key = other.config.card_key,
                    center = other.config.center,
                },
                ability = { set = "Default" },
                base = other.base,
            }
        end)
        G.FUNCS = {
            get_poker_hand_info = function()
                return "High Card", "High Card", {}, { glass }, "High Card"
            end,
            play_cards_from_highlighted = function()
                push_smods_context({ main_scoring = true, cardarea = G.play })
                SMODS.calculate_effect_table_key({
                    playing_card = { chips = 11 },
                }, "playing_card", glass)
                SMODS.calculate_effect_table_key({
                    enhancement = { x_mult = 2 },
                }, "enhancement", glass)
                push_smods_context({
                    destroy_card = glass,
                    main_scoring = true,
                    cardarea = G.play,
                })
                SMODS.calculate_effect_table_key({
                    enhancement = { remove = true },
                }, "enhancement", glass)
                push_smods_context({
                    destroying_card = six,
                    full_hand = { six },
                    cardarea = G.play,
                })
                SMODS.calculate_effect_table_key({
                    jokers = {
                        remove = true,
                        func = function()
                            create_card("Spectral", G.consumeables)
                        end,
                    },
                }, "jokers", sixth_sense)
                push_smods_context({ before = true, full_hand = { glass } })
                SMODS.calculate_effect_table_key({
                    jokers = {
                        func = function()
                            copy_card(glass)
                        end,
                    },
                }, "jokers", dna)
            end,
        }

        local adapter = ProductionBalatroAdapter.new()
        local play_result, play_error = adapter:execute({
            name = "play_hand",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { card_ids = { "card:1", "card:4" } },
        })
        luaunit.assertNil(play_error)
        ---@cast play_result table
        luaunit.assertNil(play_result.events)
        local resolution = play_result.resolution
        luaunit.assertEquals(#resolution, 5)
        luaunit.assertEquals(resolution[1], {
            order = 1,
            phase = "playing_card",
            type = "trigger",
            component = "playing_card",
            source = { input_target_id = "card:1" },
            effects = {
                { order = 2, kind = "chips", amount = 11, chips = 16, mult = 1, score = 16 },
            },
        })
        luaunit.assertEquals(resolution[2], {
            order = 3,
            phase = "playing_card",
            type = "trigger",
            component = "enhancement",
            source = { input_target_id = "card:1" },
            effects = {
                { order = 4, kind = "x_mult", amount = 2, chips = 16, mult = 2, score = 32 },
            },
        })
        luaunit.assertEquals(resolution[3], {
            order = 5,
            phase = "destroying_card",
            type = "trigger",
            component = "enhancement",
            source = { input_target_id = "card:1" },
            effects = { { order = 6, kind = "destroy", input_target_id = "card:1" } },
        })
        luaunit.assertEquals(resolution[4], {
            order = 7,
            phase = "destroying_card",
            type = "trigger",
            component = "joker",
            source = { input_target_id = "joker:14" },
            effects = {
                { order = 8, kind = "destroy", input_target_id = "card:4" },
                {
                    order = 9,
                    kind = "create",
                    object_kind = "consumable",
                    destination = "owned",
                    key = "c_sigil",
                },
            },
        })
        luaunit.assertNil(resolution[4].effects[2].input_target_id)
        luaunit.assertNil(resolution[4].effects[2].id)
        luaunit.assertEquals(resolution[5], {
            order = 10,
            phase = "before",
            type = "trigger",
            component = "joker",
            source = { input_target_id = "joker:15" },
            effects = {
                {
                    order = 11,
                    kind = "copy",
                    mode = "create",
                    source = { input_target_id = "card:1" },
                    object_kind = "playing_card",
                    destination = "permanent_deck",
                    key = "S_A",
                    rank = "Ace",
                    suit = "Spades",
                },
            },
        })
        luaunit.assertNil(resolution[5].effects[1].input_target_id)
        for _, event in ipairs(resolution) do
            luaunit.assertNotEquals(event.type, "hand_played")
            luaunit.assertNil(event.message)
        end

        G.STATE = G.STATES.ROUND_EVAL
        G.round_eval = {
            get_UIE_by_ID = function(_, key)
                if key == "cash_out_button" then
                    return { config = { button = "cash_out" } }
                end
            end,
        }
        G.GAME.current_round.dollars = 5
        G.FUNCS.cash_out = function()
            G.GAME.dollars = G.GAME.dollars + 5
        end
        local pending_observe, pending_error = adapter:observe("fair")
        luaunit.assertNil(pending_observe)
        luaunit.assertNotNil(pending_error)
        ---@cast pending_error table
        luaunit.assertEquals(pending_error.code, "DECISION_PENDING")
        local final_resolution, resolution_error =
            adapter:finish_resolution(play_result.resolution_context)
        luaunit.assertNil(resolution_error)
        luaunit.assertNotNil(final_resolution)
        ---@cast final_resolution table
        resolution = final_resolution
        luaunit.assertEquals(resolution[6], {
            order = 12,
            phase = "end_of_round",
            type = "cash_out",
            effects = { { order = 13, kind = "dollars", amount = 5, money = 11 } },
        })

        selecting_hand_globals({ glass }, { dna })
        install_smods_calculate_fixture()
        G.FUNCS = {
            get_poker_hand_info = function()
                return "High Card", "High Card", {}, { glass }, "High Card"
            end,
            play_cards_from_highlighted = function()
                SMODS.calculate_effect_table_key({
                    playing_card = { chips = 11 },
                }, "playing_card", glass)
                error("boom")
            end,
        }
        local failed, failed_error = ProductionBalatroAdapter.new():execute({
            name = "play_hand",
            expected_state_hash = "sha256:test",
            arguments = {},
            targets = { card_ids = { "card:1" } },
        })
        luaunit.assertNil(failed)
        luaunit.assertNotNil(failed_error)
        ---@cast failed_error table
        luaunit.assertEquals(failed_error.code, "INTERNAL_ERROR")

        selecting_hand_globals({ glass }, { dna })
        local reorder_adapter = ProductionBalatroAdapter.new()
        local reorder, reorder_error = reorder_adapter:execute({
            name = "reorder_cards",
            expected_state_hash = "sha256:test",
            visibility = "fair",
            arguments = { area = "hand" },
            targets = { ordered_ids = { "card:1" } },
        })
        luaunit.assertNil(reorder_error)
        ---@cast reorder table
        luaunit.assertNil(reorder.events)
        local reorder_resolution, reorder_capture_error =
            reorder_adapter:finish_resolution(reorder.resolution_context)
        luaunit.assertNil(reorder_capture_error)
        luaunit.assertNil(reorder_resolution)
    end, debug.traceback)

    rawset(_G, "G", saved_g)
    rawset(_G, "SMODS", saved_smods)
    rawset(_G, "create_card", saved_create)
    rawset(_G, "copy_card", saved_copy)
    if not ok then
        error(test_error)
    end
end

function TestDiscovery:test_thread_failure_disables_only_the_failed_server()
    local failed_server = GameMcpServer.new({
        json = JSON,
        adapter = self.adapter,
        tool_catalog = ToolCatalog,
        port = 0,
        worker_source = [[error("thread boom")]],
        server_info = { name = "test", version = "0.1.0" },
    })
    luaunit.assertTrue(failed_server:start())
    wait_until(failed_server, function()
        return failed_server:get_status().state == "error"
    end, 2)
    luaunit.assertNotNil(failed_server:get_status().error)

    local status =
        parse_http(send_http(self.server, self.port, make_request(self.port, valid_discovery_body)))
    luaunit.assertEquals(status, 200)

    love.event.pump()
    for name, thread, error_message in love.event.poll() do
        if name == "threaderror" then
            love.threaderror(thread, error_message)
        end
    end
    failed_server:stop()
end
