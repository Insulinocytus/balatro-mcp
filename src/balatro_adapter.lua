---@class ProductionBalatroAdapter: BalatroAdapter
---@field english table?
---@field game_identity table?
---@field run_serial integer
---@field decision_sequence integer
---@field last_signature? string
local ProductionBalatroAdapter = {}
ProductionBalatroAdapter.__index = ProductionBalatroAdapter

local blind_slots = { "Small", "Big", "Boss" }
local poker_hand_order
local resolution_adapter
local hooked_smods

local function adapter_error(code, message, observe_block, diagnostic)
    return {
        code = code,
        message = message,
        observe_block = observe_block,
        diagnostic = diagnostic,
    }
end

local function sorted_keys(value)
    local keys = {}
    for key in pairs(value or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function compact_text(value)
    value = tostring(value or ""):gsub("{[^}]*}", "")
    return value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function load_english_localization()
    local source = love.filesystem.read("localization/en-us.lua")
    if not source then
        return nil
    end
    local chunk = loadstring(source, "@localization/en-us.lua")
    if not chunk then
        return nil
    end
    local ok, localization = pcall(chunk)
    return ok and localization or nil
end

local function lovely_version()
    local ok, lovely = pcall(require, "lovely")
    return ok and type(lovely) == "table" and tostring(lovely.version or "unknown") or "unknown"
end

local function active_mods()
    local mods = {}
    for _, mod in ipairs(SMODS.mod_list or {}) do
        if mod.can_load and not mod.meta_mod then
            mods[#mods + 1] = {
                id = tostring(mod.id),
                name = tostring(mod.name or mod.id),
                version = tostring(mod.version or "unknown"),
            }
        end
    end
    table.sort(mods, function(a, b)
        return a.id < b.id
    end)
    return mods
end

local minimum_versions = {
    balatro = "1.0.1o-FULL",
    love = "11.5",
    steamodded = "1.0.0~BETA-2014b",
    lovely = "0.7.1",
}

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

local function love_version_string()
    local major, minor, revision = love.getVersion()
    return string.format("%d.%d.%d", major, minor, revision or 0)
end

local function version_issues()
    local found = {
        { name = "Balatro", actual = G and G.VERSION, minimum = minimum_versions.balatro },
        { name = "LÖVE", actual = love_version_string(), minimum = minimum_versions.love },
        {
            name = "Steamodded",
            actual = SMODS and SMODS.version,
            minimum = minimum_versions.steamodded,
        },
        { name = "Lovely", actual = lovely_version(), minimum = minimum_versions.lovely },
    }
    local issues = {}
    for _, item in ipairs(found) do
        if
            item.actual
            and item.actual ~= "unknown"
            and not version_at_least(item.actual, item.minimum)
        then
            issues[#issues + 1] = ("%s %s is below %s"):format(
                item.name,
                tostring(item.actual),
                item.minimum
            )
        end
    end
    return issues
end

local function compatibility(mods)
    local extra_content_mod = false
    for _, mod in ipairs(mods) do
        if mod.id ~= "balatro-mcp" then
            extra_content_mod = true
            break
        end
    end
    local issues = version_issues()
    local versions_ok = #issues == 0
    return {
        status = (versions_ok and not extra_content_mod) and "supported" or "unsupported",
        content_mods = extra_content_mod and "unsupported" or "supported",
        versions = versions_ok and "supported" or "unsupported",
        diagnostic = #issues > 0 and table.concat(issues, "; ") or nil,
    }
end

---@return ProductionBalatroAdapter
function ProductionBalatroAdapter.new()
    return setmetatable({
        english = load_english_localization(),
        run_serial = 0,
        decision_sequence = 0,
    }, ProductionBalatroAdapter)
end

function ProductionBalatroAdapter:_english_entry(set, key, vars, fallback_name)
    local descriptions = self.english and self.english.descriptions
    local entry = descriptions and descriptions[set] and descriptions[set][key]
    local name = entry and entry.name or fallback_name or key
    local lines = {}
    for _, line in ipairs(entry and entry.text or {}) do
        line = line:gsub("#(%d+)#", function(index)
            local value = vars and vars[tonumber(index)]
            return value == nil and ("#" .. index .. "#") or tostring(value)
        end)
        line = compact_text(line)
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end
    return tostring(name), table.concat(lines, " ")
end

function ProductionBalatroAdapter:_deck_vars(center)
    local config = center.config or {}
    local key = center.key
    if key == "b_red" then
        return { config.discards }
    elseif key == "b_blue" then
        return { config.hands }
    elseif key == "b_yellow" then
        return { config.dollars }
    elseif key == "b_green" then
        return { config.extra_hand_bonus, config.extra_discard_bonus }
    elseif key == "b_black" then
        return { config.joker_slot, -(config.hands or 0) }
    elseif key == "b_magic" then
        local voucher = self:_english_entry("Voucher", "v_crystal_ball", nil, "Crystal Ball")
        local tarot = self:_english_entry("Tarot", "c_fool", nil, "The Fool")
        return { voucher, tarot }
    elseif key == "b_nebula" then
        local voucher = self:_english_entry("Voucher", "v_telescope", nil, "Telescope")
        return { voucher, -1 }
    elseif key == "b_zodiac" then
        local tarot = self:_english_entry("Voucher", "v_tarot_merchant", nil, "Tarot Merchant")
        local planet = self:_english_entry("Voucher", "v_planet_merchant", nil, "Planet Merchant")
        local overstock = self:_english_entry("Voucher", "v_overstock_norm", nil, "Overstock")
        return { tarot, planet, overstock }
    elseif key == "b_painted" then
        return { config.hand_size, config.joker_slot }
    elseif key == "b_anaglyph" then
        local tag = self:_english_entry("Tag", "tag_double", nil, "Double Tag")
        return { tag }
    elseif key == "b_plasma" then
        return { config.ante_scaling }
    end
    return {}
end

function ProductionBalatroAdapter:_deck(center)
    local name, description =
        self:_english_entry("Back", center.key, self:_deck_vars(center), center.name)
    return { key = center.key, name = name, description = description }
end

function ProductionBalatroAdapter:_stake(stake)
    local name, description = self:_english_entry("Stake", stake.key, nil, stake.name)
    return {
        key = stake.key,
        level = stake.order,
        name = name,
        description = description,
    }
end

function ProductionBalatroAdapter:_tag_vars(proto, tag, slot)
    local config = tag and tag.config or proto.config or {}
    local name = proto.name
    if name == "Investment Tag" then
        return { config.dollars }
    elseif name == "Handy Tag" then
        return { config.dollars_per_hand, config.dollars_per_hand * (G.GAME.hands_played or 0) }
    elseif name == "Garbage Tag" then
        return {
            config.dollars_per_discard,
            config.dollars_per_discard * (G.GAME.unused_discards or 0),
        }
    elseif name == "Juggle Tag" then
        return { config.h_size }
    elseif name == "Top-up Tag" then
        return { config.spawn_jokers }
    elseif name == "Skip Tag" then
        return { config.skip_bonus, config.skip_bonus * ((G.GAME.skips or 0) + 1) }
    elseif name == "Orbital Tag" then
        local choices = G.GAME.orbital_choices and G.GAME.orbital_choices[G.GAME.round_resets.ante]
        return { choices and choices[slot] or "Poker Hand", config.levels }
    elseif name == "Economy Tag" then
        return { config.max }
    end
    return {}
end

function ProductionBalatroAdapter:_tag(key, tag, slot)
    local proto = G.P_TAGS[key]
    if not proto then
        return { key = key, name = key, description = "" }
    end
    local name, description =
        self:_english_entry("Tag", key, self:_tag_vars(proto, tag, slot), proto.name)
    return { key = key, name = name, description = description }
end

local function active_hand_debuff(key, blind)
    if not blind or blind.disabled then
        return nil
    end
    if key == "bl_psychic" then
        local minimum = blind.debuff and blind.debuff.h_size_ge
        return minimum and { min_cards = minimum } or nil
    end
    if key == "bl_mouth" then
        return blind.only_hand and { required_poker_hand = blind.only_hand } or nil
    end
    if key == "bl_eye" then
        local forbidden = {}
        for _, hand in ipairs(poker_hand_order) do
            if blind.hands and blind.hands[hand] then
                forbidden[#forbidden + 1] = hand
            end
        end
        return { forbidden_poker_hands = forbidden }
    end
end

local function same_hand_debuff(left, right)
    if left == nil or right == nil then
        return left == right
    end
    if
        left.min_cards ~= right.min_cards
        or left.required_poker_hand ~= right.required_poker_hand
    then
        return false
    end
    local left_forbidden = left.forbidden_poker_hands or {}
    local right_forbidden = right.forbidden_poker_hands or {}
    if #left_forbidden ~= #right_forbidden then
        return false
    end
    for index, hand in ipairs(left_forbidden) do
        if right_forbidden[index] ~= hand then
            return false
        end
    end
    return true
end

function ProductionBalatroAdapter:_blind(slot, key, active_blind)
    local proto = G.P_BLINDS[key]
    local vars = key == "bl_ox" and { G.GAME.current_round.most_played_poker_hand } or nil
    local name, description = self:_english_entry("Blind", key, vars, proto and proto.name)
    local reward = proto and proto.dollars or 0
    if G.GAME.modifiers.no_blind_reward and G.GAME.modifiers.no_blind_reward[slot] then
        reward = 0
    end
    local score = 0
    local get_blind_amount = rawget(_G, "get_blind_amount")
    if proto and type(get_blind_amount) == "function" then
        score = get_blind_amount(G.GAME.round_resets.blind_ante or G.GAME.round_resets.ante)
            * proto.mult
            * G.GAME.starting_params.ante_scaling
    end
    if active_blind then
        reward = active_blind.dollars or reward
        score = active_blind.chips or score
    end
    local blind = {
        target_ref = "blind:" .. slot .. ":" .. key,
        slot = slot,
        key = key,
        name = name,
        description = description,
        status = G.GAME.round_resets.blind_states[slot],
        current = G.GAME.blind_on_deck == slot,
        score_requirement = math.floor(score),
        reward_dollars = reward,
    }
    if active_blind then
        blind.disabled = not not active_blind.disabled
        blind.hand_debuff = active_hand_debuff(key, active_blind)
    end
    local tag_key = G.GAME.round_resets.blind_tags[slot]
    if tag_key and slot ~= "Boss" then
        blind.skip_tag = self:_tag(tag_key, nil, slot)
    end
    return blind
end

function ProductionBalatroAdapter:_available_decks()
    local decks = {}
    for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
        if
            center.key
            and center.set == "Back"
            and not center.omit
            and center.unlocked ~= false
            and center.discovered ~= false
            and not center.mod
        then
            decks[#decks + 1] = self:_deck(center)
        end
    end
    table.sort(decks, function(a, b)
        return a.key < b.key
    end)
    return decks
end

function ProductionBalatroAdapter:_available_stakes(decks)
    local stakes = {}
    for _, stake in ipairs(G.P_CENTER_POOLS.Stake or {}) do
        if stake.key and not stake.mod then
            local deck_keys = {}
            for _, deck in ipairs(decks) do
                if SMODS.stake_is_unlocked(stake.key, deck.key) then
                    deck_keys[#deck_keys + 1] = deck.key
                end
            end
            if #deck_keys > 0 then
                local value = self:_stake(stake)
                value.deck_keys = deck_keys
                stakes[#stakes + 1] = value
            end
        end
    end
    table.sort(stakes, function(a, b)
        return a.level < b.level
    end)
    return stakes
end

function ProductionBalatroAdapter:_environment_state()
    local mods = active_mods()
    return {
        game_version = tostring(G.VERSION or "unknown"),
        steamodded_version = tostring(SMODS.version or "unknown"),
        lovely_version = lovely_version(),
        active_mods = mods,
        compatibility = compatibility(mods),
    }
end

function ProductionBalatroAdapter:_run_id()
    if G.STAGE == G.STAGES.RUN and G.GAME then
        if self.game_identity ~= G.GAME then
            self.game_identity = G.GAME
            self.run_serial = self.run_serial + 1
            self.continued_endless = false
            self.last_custom_hand_order = nil
            self.last_hand_identity = nil
        end
        return "run:" .. self.run_serial
    end
    return "menu"
end

function ProductionBalatroAdapter:_expect_dollars(delta)
    delta = tonumber(delta) or 0
    if delta == 0 or not G.GAME then
        return
    end
    self.pending_dollars = (G.GAME.dollars or 0) + delta
    self.pending_dollars_dir = delta > 0 and 1 or -1
end

local current_blind_reference

local action_phases = {
    start_run = "run_start",
    select_blind = "blind_selection",
    skip_blind = "blind_selection",
    reroll_boss = "blind_selection",
    discard_cards = "discard",
    buy_shop_item = "shop",
    buy_and_use_shop_item = "shop",
    redeem_voucher = "shop",
    open_booster = "shop",
    reroll_shop = "shop",
    leave_shop = "shop",
    choose_booster_item = "booster",
    skip_booster = "booster",
}

local joker_progress_fields = {
    { resource = "chips", field = "chips" },
    { resource = "mult", field = "mult" },
    { resource = "x_mult", field = "x_mult" },
}

local function joker_progress_snapshot(card)
    local snapshot = {}
    for _, entry in ipairs(joker_progress_fields) do
        local value = card and card.ability and tonumber(card.ability[entry.field])
        if value ~= nil then
            snapshot[entry.resource] = value
        end
    end
    if
        card
        and card.ability
        and card.ability.name == "Throwback"
        and G
        and G.GAME
        and type(G.GAME.skips) == "number"
        and type(card.ability.extra) == "number"
    then
        snapshot.x_mult = 1 + G.GAME.skips * card.ability.extra
    end
    return snapshot
end

local function action_resolution_phase(name)
    if (name == "use_consumable" or name == "sell_owned_item") and G and G.STATES then
        if G.STATE == G.STATES.SHOP then
            return "shop"
        elseif G.STATE == G.STATES.BLIND_SELECT then
            return "blind_selection"
        elseif
            G.STATE == G.STATES.TAROT_PACK
            or G.STATE == G.STATES.PLANET_PACK
            or G.STATE == G.STATES.SPECTRAL_PACK
            or G.STATE == G.STATES.STANDARD_PACK
            or G.STATE == G.STATES.BUFFOON_PACK
            or G.STATE == G.STATES.SMODS_BOOSTER_OPENED
        then
            return "booster"
        end
    end
    return action_phases[name] or "hand"
end

local mechanic_source_arguments = {
    use_consumable = "consumable_id",
    sell_owned_item = "item_id",
    buy_shop_item = "item_id",
    buy_and_use_shop_item = "item_id",
    redeem_voucher = "voucher_id",
    open_booster = "booster_id",
    choose_booster_item = "item_id",
}

local function register_input_area(context, area, prefix)
    for index, card in ipairs(area and area.cards or {}) do
        if type(card) == "table" then
            local reference = prefix .. ":" .. tostring(card.sort_id or index)
            context.input_objects[card] = reference
            context.input_references[reference] = card
        end
    end
end

function ProductionBalatroAdapter:_abandon_resolution(context)
    context = context or self.resolution_capture
    if context then
        context.active = false
    end
    if not context or context == self.resolution_capture then
        self.resolution_capture = nil
        self.action_resolution = nil
    end
end

function ProductionBalatroAdapter:abandon_resolution(context, _reason)
    self:_abandon_resolution(context)
end

function ProductionBalatroAdapter:_begin_resolution(action)
    self:_abandon_resolution()
    self:_ensure_resolution_hooks()
    local context = {
        active = true,
        action = action.name,
        visibility = action.visibility or "fair",
        events = {},
        scope_stack = {},
        event_stack = {},
        component_origins = {},
        input_objects = {},
        input_references = {},
        mechanic_objects = {},
        destroyed_cards = {},
        created_records = {},
        joker_progress = {},
        card_state_records = {},
        card_change_stack = {},
        application_depth = 0,
        suppress_card_state = 0,
        blind_effect_depth = 0,
        cash_out_content_dollars = 0,
        next_order = 0,
    }
    context.serpent_draw_rule_recorded = false
    register_input_area(context, G and G.hand, "card")
    register_input_area(context, G and G.jokers, "joker")
    register_input_area(context, G and G.consumeables, "consumable")
    register_input_area(context, G and G.shop_jokers, "shop_item")
    register_input_area(context, G and G.shop_vouchers, "shop_voucher")
    register_input_area(context, G and G.shop_booster, "shop_booster")
    register_input_area(context, G and G.pack_cards, "booster_item")
    for _, card in ipairs(G and G.jokers and G.jokers.cards or {}) do
        context.joker_progress[card] = joker_progress_snapshot(card)
    end
    local blind_slot, blind_key, blind_reference = current_blind_reference()
    local blind = blind_slot and blind_key and G and G.P_BLINDS and G.P_BLINDS[blind_key]
    if blind and blind_reference then
        context.input_objects[blind] = blind_reference
        context.input_references[blind_reference] = blind
    end

    local source_argument = mechanic_source_arguments[action.name]
    local source_reference = source_argument and action.targets and action.targets[source_argument]
    local source_object = source_reference and context.input_references[source_reference]
    if source_object then
        context.mechanic_objects[source_object] = true
    end
    context.scope_stack[1] = {
        kind = "action_mechanics",
        phase = action_resolution_phase(action.name),
    }
    self.resolution_capture = context
    self.action_resolution = context.events
    return context
end

local function retain_resolution_events(context)
    local keep = {}
    local by_order = {}
    for _, event in ipairs(context.events) do
        by_order[event.order] = event
        if (event.effects and event.effects[1]) or event.type == "debuff_blocked" then
            keep[event] = true
        end
    end
    local changed = true
    while changed do
        changed = false
        for _, event in ipairs(context.events) do
            local parent = event.parent_order and by_order[event.parent_order]
            if keep[event] and parent and not keep[parent] then
                keep[parent] = true
                changed = true
            end
        end
    end
    local events = {}
    for _, event in ipairs(context.events) do
        if keep[event] then
            events[#events + 1] = event
        end
    end
    return events
end

function ProductionBalatroAdapter:finish_resolution(context)
    context = context or self.resolution_capture
    if not context or context ~= self.resolution_capture then
        return nil, adapter_error("INTERNAL_ERROR", "Resolution capture context is unavailable")
    end
    local invalid = context.invalid
    local events = retain_resolution_events(context)
    self:_abandon_resolution(context)
    if invalid then
        return nil,
            {
                code = "INTERNAL_ERROR",
                message = invalid.message,
                path = invalid.path,
                raw_reference = invalid.raw_reference,
            }
    end
    return events[1] and events or nil
end

function ProductionBalatroAdapter:_finish(phase, public_state, signature, hidden_state)
    self.pending_dollars = nil
    self.pending_dollars_dir = nil
    local run_id = self:_run_id()
    signature = run_id .. "|" .. signature
    if signature ~= self.last_signature then
        self.last_signature = signature
        self.decision_sequence = self.decision_sequence + 1
    end
    return {
        run_id = run_id,
        decision_sequence = self.decision_sequence,
        phase = phase,
        public_state = public_state,
        hidden_state = hidden_state,
    }
end

local function controller_is_locked()
    local controller = G.CONTROLLER
    local locks = controller and controller.locks or {}
    return not controller
        or controller.lock_input == true
        or controller.locked
        or locks.frame
        or locks.load
        or locks.skip_blind
        or locks.boss_reroll
        or locks.selling_card
        or locks.use
        or locks.shop_reroll
        or locks.toggle_shop
end

local function runtime_is_busy()
    return controller_is_locked() or (G.GAME and (G.GAME.STOP_USE or 0) ~= 0)
end

local function money_is_pending(adapter)
    if adapter.pending_dollars == nil then
        return false
    end
    local dollars = G.GAME and G.GAME.dollars or 0
    if adapter.pending_dollars_dir and adapter.pending_dollars_dir > 0 then
        return dollars < adapter.pending_dollars
    end
    return dollars > adapter.pending_dollars
end

local function owned_signature(state)
    local parts = {}
    for _, joker in ipairs(state.jokers or {}) do
        parts[#parts + 1] = joker.target_ref
    end
    parts[#parts + 1] = "/"
    for _, consumable in ipairs(state.consumables or {}) do
        parts[#parts + 1] = consumable.target_ref
    end
    return table.concat(parts, ",")
end

local suit_nominal = { Diamonds = 0.01, Clubs = 0.02, Hearts = 0.03, Spades = 0.04 }
local suit_nominal_original = { Diamonds = 0.001, Clubs = 0.002, Hearts = 0.003, Spades = 0.004 }

local function card_sort_nominal(card, by_suit)
    if card.get_nominal then
        local ok, value = pcall(card.get_nominal, card, by_suit and "suit" or nil)
        if ok and type(value) == "number" then
            return value
        end
    end
    local base = card.base or {}
    local mult = by_suit and 1000 or 1
    if card.ability and card.ability.effect == "Stone Card" then
        mult = -1000
    end
    return (tonumber(base.nominal) or 0)
        + (tonumber(base.suit_nominal) or suit_nominal[base.suit] or 0) * mult
        + (tonumber(base.suit_nominal_original) or suit_nominal_original[base.suit] or 0) * 0.0001 * mult
        + (tonumber(base.face_nominal) or 0)
        + 0.000001 * (tonumber(card.unique_val) or 0)
end

local function cards_match_desc_sort(cards, by_suit)
    for index = 1, #cards - 1 do
        if
            card_sort_nominal(cards[index], by_suit) < card_sort_nominal(cards[index + 1], by_suit)
        then
            return false
        end
    end
    return true
end

local function is_standard_hand_sort(cards)
    if not cards or #cards < 2 then
        return true
    end
    return cards_match_desc_sort(cards, false) or cards_match_desc_sort(cards, true)
end

local function projected_hand_refs(cards, snapshots, by_suit)
    local order = {}
    for index = 1, #cards do
        order[index] = index
    end
    table.sort(order, function(left, right)
        return card_sort_nominal(cards[left], by_suit) > card_sort_nominal(cards[right], by_suit)
    end)
    local refs = {}
    for index, card_index in ipairs(order) do
        refs[index] = snapshots[card_index].target_ref
    end
    return refs
end

local function apply_hand_order_projections(state, cards)
    for _, card in ipairs(state.hand or {}) do
        if card.facedown then
            state.hand_order_projections = {
                rank = projected_hand_refs(cards, state.hand, false),
                suit = projected_hand_refs(cards, state.hand, true),
            }
            return
        end
    end
end

local function hand_order_signature(adapter, cards, card_signature)
    local identity = {}
    for index, reference in ipairs(card_signature) do
        identity[index] = reference
    end
    table.sort(identity)
    local identity_part = table.concat(identity, ",")
    if adapter.last_hand_identity ~= identity_part then
        adapter.last_custom_hand_order = nil
        adapter.last_hand_identity = identity_part
    end
    if not is_standard_hand_sort(cards) then
        adapter.last_custom_hand_order = table.concat(card_signature, ",")
    end
    return identity_part .. "|" .. (adapter.last_custom_hand_order or "")
end

function ProductionBalatroAdapter:_menu_observation()
    if
        not G
        or G.STAGE ~= G.STAGES.MAIN_MENU
        or G.STATE ~= G.STATES.MENU
        or controller_is_locked()
    then
        return nil
    end

    local phase = "main_menu"
    if G.OVERLAY_MENU then
        if G.SETTINGS.current_setup ~= "New Run" then
            return nil
        end
        phase = "run_setup"
    elseif not G.MAIN_MENU_UI then
        return nil
    end

    local state = self:_environment_state()
    local decks = self:_available_decks()
    local stakes = self:_available_stakes(decks)
    state.available_decks = decks
    state.available_stakes = stakes
    state.has_saved_run = G.SAVED_GAME ~= nil

    local choices = SMODS.RunSelect and SMODS.RunSelect.Setup and SMODS.RunSelect.Setup.choices
        or {}
    local selected_deck_key = choices.deck_choice
        or (G.GAME.viewed_back and G.GAME.viewed_back.effect.center.key)
        or "b_red"
    local selected_stake_key = choices.stake_choice or SMODS.stake_from_index(G.viewed_stake or 1)
    state.selected_deck_key = selected_deck_key
    state.selected_stake_key = selected_stake_key
    if phase == "run_setup" and choices.enable_seed then
        state.seed = choices.seed
    end

    state.legal_actions = {}
    for _, deck in ipairs(decks) do
        local maximum_stake = 1
        for _, stake in ipairs(stakes) do
            for _, key in ipairs(stake.deck_keys or {}) do
                if key == deck.key then
                    maximum_stake = math.max(maximum_stake, stake.level)
                end
            end
        end
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "start_run",
            fixed_arguments = { deck_key = deck.key },
            arguments = { stake = { minimum = 1, maximum = maximum_stake } },
        }
    end

    return self:_finish(
        phase,
        state,
        table.concat({ phase, selected_deck_key, selected_stake_key, state.seed or "" }, "|")
    )
end

function ProductionBalatroAdapter:_run_state()
    local state = self:_environment_state()
    local selected_back = G.GAME.selected_back and G.GAME.selected_back.effect.center
    local stake_key = SMODS.stake_from_index(G.GAME.stake or 1)
    local stake = G.P_STAKES[stake_key] or G.P_CENTER_POOLS.Stake[G.GAME.stake or 1]
    state.seed = G.GAME.pseudorandom.seed
    state.seeded = not not G.GAME.seeded
    state.won = not not G.GAME.won
    state.ante = G.GAME.round_resets.ante
    state.money = G.GAME.dollars
    state.skips = G.GAME.skips or 0
    state.deck = selected_back and self:_deck(selected_back) or nil
    state.stake = stake and self:_stake(stake) or nil

    state.tags = {}
    for _, tag in ipairs(G.GAME.tags or {}) do
        state.tags[#state.tags + 1] = self:_tag(tag.key, tag)
    end
    state.vouchers = {}
    for _, key in ipairs(sorted_keys(G.GAME.used_vouchers)) do
        if G.GAME.used_vouchers[key] then
            local center = G.P_CENTERS[key]
            local extra = center
                and center.config
                and (center.config.extra_disp or center.config.extra)
            local vars = (type(extra) == "number" or type(extra) == "string") and { extra } or nil
            local name, description =
                self:_english_entry("Voucher", key, vars, center and center.name)
            state.vouchers[#state.vouchers + 1] = {
                key = key,
                name = name,
                description = description,
            }
        end
    end
    local owned = self:_collect_owned()
    state.jokers = owned.jokers
    state.joker_limit = owned.joker_limit
    state.consumables = owned.consumables
    state.consumable_limit = owned.consumable_limit
    return state
end

local function blind_option(slot)
    return G.blind_select_opts and G.blind_select_opts[string.lower(slot)]
end

local function select_is_available(slot)
    local option = blind_option(slot)
    local button = option and option.get_UIE_by_ID and option:get_UIE_by_ID("select_blind_button")
    return button and button.config and button.config.button == "select_blind"
end

local function skip_is_available(slot)
    local option = blind_option(slot)
    local tag = option and option.get_UIE_by_ID and option:get_UIE_by_ID("tag_" .. slot)
    local button = tag and tag.children and tag.children[2]
    return button and button.config and button.config.button == "skip_blind"
end

local function reroll_is_available()
    return G.blind_select_opts
        and G.blind_select_opts.boss
        and ((G.GAME.dollars - G.GAME.bankrupt_at) - 10 >= 0)
        and (
            G.GAME.used_vouchers.v_retcon
            or (G.GAME.used_vouchers.v_directors_cut and not G.GAME.round_resets.boss_rerolled)
        )
end

function ProductionBalatroAdapter:_blind_observation()
    if
        G.STAGE ~= G.STAGES.RUN
        or G.STATE ~= G.STATES.BLIND_SELECT
        or not G.STATE_COMPLETE
        or G.SETTINGS.paused
        or controller_is_locked()
        or not G.GAME
        or not G.GAME.round_resets
        or not G.GAME.blind_on_deck
        or not G.blind_select
        or not G.blind_prompt_box
        or not G.blind_select_opts
        or runtime_is_busy()
        or (G.blind_select.VT and G.blind_select.VT.y >= 10)
    then
        return nil
    end

    local state = self:_run_state()
    state.blind_on_deck = G.GAME.blind_on_deck
    state.blinds = {}
    local choice_signature = {}
    for _, slot in ipairs(blind_slots) do
        local key = G.GAME.round_resets.blind_choices[slot]
        if key and G.P_BLINDS[key] then
            state.blinds[#state.blinds + 1] = self:_blind(slot, key)
            choice_signature[#choice_signature + 1] = table.concat({
                slot,
                key,
                tostring(G.GAME.round_resets.blind_states[slot]),
            }, ":")
        end
    end

    state.legal_actions = {}
    local current_slot = G.GAME.blind_on_deck
    local current_key = G.GAME.round_resets.blind_choices[current_slot]
    local current_reference = "blind:" .. current_slot .. ":" .. current_key
    if select_is_available(current_slot) then
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "select_blind",
            target_refs = { blind_id = { current_reference } },
        }
    end
    if current_slot ~= "Boss" and skip_is_available(current_slot) then
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "skip_blind",
            target_refs = { blind_id = { current_reference } },
        }
    end
    if reroll_is_available() then
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "reroll_boss",
        }
    end
    self:_append_owned_actions(state)

    local signature = table.concat({
        "blind_selection",
        tostring(state.ante),
        tostring(state.money),
        current_slot,
        table.concat(choice_signature, ","),
        tostring(G.GAME.round_resets.boss_rerolled),
        tostring(G.GAME.skips or 0),
        owned_signature(state),
    }, "|")
    return self:_finish("blind_selection", state, signature)
end

poker_hand_order = {
    "Flush Five",
    "Flush House",
    "Five of a Kind",
    "Straight Flush",
    "Four of a Kind",
    "Full House",
    "Flush",
    "Straight",
    "Three of a Kind",
    "Two Pair",
    "Pair",
    "High Card",
}

function ProductionBalatroAdapter:_modifier(set, key, vars, fallback_name)
    if not key then
        return nil
    end
    local name, description = self:_english_entry(set, key, vars, fallback_name or key)
    return { key = key, name = name, description = description }
end

local vanilla_editions = { negative = true, polychrome = true, holo = true, foil = true }

function ProductionBalatroAdapter:_edition(card)
    local edition = card and card.edition
    if not edition then
        return nil
    end
    local edition_type = edition.type
    if not vanilla_editions[edition_type] then
        for _, candidate in ipairs({ "negative", "polychrome", "holo", "foil" }) do
            if edition[candidate] then
                edition_type = candidate
                break
            end
        end
    end
    if not vanilla_editions[edition_type] then
        return nil
    end

    local key = "e_" .. edition_type
    local config = G.P_CENTERS and G.P_CENTERS[key] and G.P_CENTERS[key].config or {}
    local value
    if edition_type == "foil" then
        value = edition.chips or config.chips or config.extra
    elseif edition_type == "holo" then
        value = edition.mult or config.mult or config.extra
    elseif edition_type == "polychrome" then
        value = edition.x_mult or config.x_mult or config.extra
    else
        value = edition.card_limit or config.card_limit or config.extra
    end
    local localization_key = edition_type == "negative"
            and card.ability
            and card.ability.consumeable
            and "e_negative_consumable"
        or key
    local name, description =
        self:_english_entry("Edition", localization_key, { value }, edition_type)
    return { key = key, name = name, description = description }
end

function ProductionBalatroAdapter:_playing_card(card, index, hide_identity)
    local facedown = card.facing == "back"
    local snapshot = {
        target_ref = "card:" .. tostring(card.sort_id or index),
    }
    if facedown then
        snapshot.facedown = true
    end
    if card.ability and card.ability.forced_selection then
        snapshot.forced_selection = true
    end
    if facedown and hide_identity then
        return snapshot
    end
    local key = card.config and card.config.card_key or ("unknown_" .. tostring(index))
    local proto = G.P_CARDS and G.P_CARDS[key]
    local name = proto and proto.name or key
    local enhancement_center = card.config and card.config.center
    local enhancement
    if enhancement_center and enhancement_center.set == "Enhanced" then
        local extra = enhancement_center.config and enhancement_center.config.extra
        enhancement = self:_modifier(
            "Enhanced",
            enhancement_center.key,
            extra ~= nil and { extra } or nil,
            enhancement_center.name
        )
    end
    local edition = self:_edition(card)
    local seal
    if card.seal then
        seal =
            self:_modifier("Other", string.lower(card.seal) .. "_seal", nil, card.seal .. " Seal")
    end
    local chips = card.get_chip_bonus and card:get_chip_bonus()
        or (card.base and card.base.nominal)
        or 0
    snapshot.key = key
    snapshot.name = name
    snapshot.description = enhancement and enhancement.description or ""
    snapshot.suit = card.base and card.base.suit or proto and proto.suit
    snapshot.rank = card.base and card.base.value or proto and proto.value
    snapshot.enhancement = enhancement
    snapshot.edition = edition
    snapshot.seal = seal
    snapshot.debuffed = not not card.debuff
    snapshot.chips = chips
    return snapshot
end

function ProductionBalatroAdapter:_remaining_deck()
    local groups = {}
    for index, card in ipairs(G.deck and G.deck.cards or {}) do
        local snapshot = self:_playing_card(card, index)
        local group_key = table.concat({
            snapshot.key,
            snapshot.enhancement and snapshot.enhancement.key or "",
            snapshot.edition and snapshot.edition.key or "",
            snapshot.seal and snapshot.seal.key or "",
            tostring(not not (card.ability and card.ability.played_this_ante)),
            tostring(snapshot.debuffed),
        }, "|")
        local group = groups[group_key]
        if not group then
            group = {
                key = snapshot.key,
                name = snapshot.name,
                count = 0,
                enhancement = snapshot.enhancement,
                edition = snapshot.edition,
                seal = snapshot.seal,
                played_this_ante = not not (card.ability and card.ability.played_this_ante),
                debuffed = snapshot.debuffed,
            }
            groups[group_key] = group
        end
        group.count = group.count + 1
    end
    local remaining = {}
    for _, key in ipairs(sorted_keys(groups)) do
        remaining[#remaining + 1] = groups[key]
    end
    return remaining
end

function ProductionBalatroAdapter:_poker_hands()
    local hands = {}
    for _, key in ipairs(poker_hand_order) do
        local hand = G.GAME.hands and G.GAME.hands[key]
        if hand and hand.visible then
            local name = self.english
                    and self.english.misc
                    and self.english.misc.poker_hands
                    and self.english.misc.poker_hands[key]
                or key
            hands[#hands + 1] = {
                key = key,
                name = name,
                level = hand.level,
                chips = hand.chips,
                mult = hand.mult,
                played = hand.played,
            }
        end
    end
    return hands
end

function ProductionBalatroAdapter:_card_loc_vars(card)
    local center = card.config and card.config.center or {}
    local set = center.set or (card.ability and card.ability.set)
    local consumeable = card.ability and card.ability.consumeable or {}
    local config = center.config or consumeable
    if set == "Planet" then
        local hand_type = config.hand_type or consumeable.hand_type
        local hand = hand_type and G.GAME and G.GAME.hands and G.GAME.hands[hand_type]
        if hand then
            local hand_name = self.english
                    and self.english.misc
                    and self.english.misc.poker_hands
                    and self.english.misc.poker_hands[hand_type]
                or hand_type
            return { hand.level, hand_name, hand.l_mult, hand.l_chips }
        end
    elseif set == "Tarot" then
        local name = center.name or (card.ability and card.ability.name)
        local max_highlighted = config.max_highlighted or consumeable.max_highlighted
        if name == "Strength" or name == "The Hanged Man" or name == "Death" then
            return { max_highlighted }
        elseif name == "The High Priestess" then
            return { config.planets or consumeable.planets }
        elseif name == "The Emperor" then
            return { config.tarots or consumeable.tarots }
        elseif name == "The Hermit" then
            return { config.extra or consumeable.extra }
        elseif name == "The Wheel of Fortune" then
            return {
                G.GAME and G.GAME.probabilities and G.GAME.probabilities.normal or 1,
                config.extra or consumeable.extra,
            }
        elseif name == "Temperance" then
            local money = 0
            for _, joker in ipairs(G.jokers and G.jokers.cards or {}) do
                if joker.ability and joker.ability.set == "Joker" then
                    money = money + (joker.sell_cost or 0)
                end
            end
            local maximum = config.extra or consumeable.extra or 0
            return { maximum, math.min(maximum, money) }
        elseif
            name == "The Star"
            or name == "The Moon"
            or name == "The Sun"
            or name == "The World"
        then
            local suit = config.suit_conv or consumeable.suit_conv
            local suit_name = self.english
                    and self.english.misc
                    and self.english.misc.suits_plural
                    and self.english.misc.suits_plural[suit]
                or suit
            return { max_highlighted, suit_name }
        elseif config.mod_conv or consumeable.mod_conv then
            local key = config.mod_conv or consumeable.mod_conv
            local entry = self.english
                and self.english.descriptions
                and self.english.descriptions.Enhanced
                and self.english.descriptions.Enhanced[key]
            return { max_highlighted, entry and entry.name or key }
        end
    end
    if not card.generate_UIBox_ability_table then
        local ability = card.ability or {}
        if type(ability.extra) == "number" then
            return { ability.extra }
        end
        if type(ability.mult) == "number" then
            return { ability.mult }
        end
        return nil
    end
    local previous = G and G.localization
    if self.english and G then
        G.localization = self.english
    end
    local ok, vars = pcall(card.generate_UIBox_ability_table, card, true)
    if self.english and G then
        G.localization = previous
    end
    if ok and type(vars) == "table" then
        return vars
    end
end

function ProductionBalatroAdapter:_consumable_target_rule(card)
    local consumeable = card.ability and card.ability.consumeable or {}
    local max_highlighted = consumeable.max_highlighted
    if card.ability and card.ability.name == "Aura" then
        max_highlighted = 1
    end
    if not max_highlighted then
        return nil
    end
    return {
        min_items = consumeable.min_highlighted or 1,
        max_items = max_highlighted,
    }
end

function ProductionBalatroAdapter:_could_use_consumable(card)
    if
        not card
        or not card.ability
        or not (
            card.ability.consumeable
            or card.ability.set == "Tarot"
            or card.ability.set == "Planet"
            or card.ability.set == "Spectral"
        )
    then
        return false
    end
    local rule = self:_consumable_target_rule(card)
    if rule then
        if not G.STATE or G.STATE ~= G.STATES.SELECTING_HAND then
            return false
        end
        local count = G.hand and G.hand.cards and #G.hand.cards or 0
        if count < rule.min_items then
            return false
        end
        if card.ability.name == "Aura" then
            local editionless = false
            for _, hand_card in ipairs(G.hand.cards or {}) do
                if not hand_card.edition then
                    editionless = true
                    break
                end
            end
            if not editionless then
                return false
            end
        end
        return true
    end
    if card.can_use_consumeable then
        local ok, usable = pcall(card.can_use_consumeable, card)
        return ok and usable or false
    end
    return false
end

function ProductionBalatroAdapter:_consumable_action(tool, argument, reference, card, state)
    local action = {
        tool = tool,
        fixed_target_refs = { [argument] = reference },
    }
    local rule = self:_consumable_target_rule(card)
    if not rule then
        return action
    end
    local target_refs = {}
    for index, hand_card in ipairs(state.hand or {}) do
        local hand_card_instance = G.hand and G.hand.cards and G.hand.cards[index]
        if
            card.ability.name ~= "Aura" or not (hand_card_instance and hand_card_instance.edition)
        then
            target_refs[#target_refs + 1] = hand_card.target_ref
        end
    end
    if #target_refs < rule.min_items then
        return nil
    end
    action.target_refs = { target_ids = target_refs }
    action.arguments = {
        target_ids = {
            min_items = rule.min_items,
            max_items = math.min(rule.max_items, #target_refs),
        },
    }
    return action
end

function ProductionBalatroAdapter:_owned_item(card, kind, index, hide_identity)
    local facedown = card.facing == "back"
    local sellable = false
    if card.can_sell_card then
        local ok, result = pcall(card.can_sell_card, card)
        sellable = ok and result or false
    end
    if facedown and hide_identity then
        return {
            target_ref = kind .. ":" .. tostring(card.sort_id or index),
            facedown = true,
            sellable = sellable,
        }
    end
    local center = card.config and card.config.center
    local key = center and center.key or (kind .. "_" .. tostring(index))
    local set = center and center.set or (kind == "joker" and "Joker" or "Tarot")
    local name, description =
        self:_english_entry(set, key, self:_card_loc_vars(card), center and center.name or key)
    local item = {
        target_ref = kind .. ":" .. tostring(card.sort_id or index),
        key = key,
        name = name,
        description = description,
        set = set,
        cost = card.cost or 0,
        sell_value = card.sell_cost or 0,
        debuffed = not not card.debuff,
        sellable = sellable,
    }
    if facedown then
        item.facedown = true
    end
    if card.ability and card.ability.eternal then
        item.eternal = true
    end
    if card.ability and card.ability.perishable then
        item.perishable = true
        item.perishable_rounds = card.ability.perish_tally
    end
    if card.ability and card.ability.rental then
        item.rental = true
    end
    if card.pinned then
        item.pinned = true
    end
    item.edition = self:_edition(card)
    if kind == "consumable" then
        local rule = self:_consumable_target_rule(card)
        item.min_targets = rule and rule.min_items or 0
        item.max_targets = rule and rule.max_items or 0
    end
    return item
end

function ProductionBalatroAdapter:_collect_owned()
    local owned = {
        jokers = {},
        joker_limit = G.jokers and G.jokers.config and G.jokers.config.card_limit or 0,
        consumables = {},
        consumable_limit = G.consumeables
                and G.consumeables.config
                and G.consumeables.config.card_limit
            or 0,
    }
    for index, card in ipairs(G.jokers and G.jokers.cards or {}) do
        owned.jokers[index] = self:_owned_item(card, "joker", index, true)
    end
    for index, card in ipairs(G.consumeables and G.consumeables.cards or {}) do
        owned.consumables[index] = self:_owned_item(card, "consumable", index)
    end
    return owned
end

function ProductionBalatroAdapter:_append_owned_actions(state)
    if G.STATE == G.STATES.SELECTING_HAND and state.hand and #state.hand >= 2 then
        local hand_refs = {}
        for index, card in ipairs(state.hand) do
            hand_refs[index] = card.target_ref
        end
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "reorder_cards",
            fixed_arguments = { area = "hand" },
            target_refs = { ordered_ids = hand_refs },
        }
    end
    if #state.jokers >= 2 then
        local joker_refs = {}
        for index, joker in ipairs(state.jokers) do
            joker_refs[index] = joker.target_ref
        end
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "reorder_cards",
            fixed_arguments = { area = "jokers" },
            target_refs = { ordered_ids = joker_refs },
        }
    end
    for _, consumable in ipairs(state.consumables) do
        local card = self:_find_owned(consumable.target_ref)
        if card and self:_could_use_consumable(card) then
            local action = self:_consumable_action(
                "use_consumable",
                "consumable_id",
                consumable.target_ref,
                card,
                state
            )
            if action then
                state.legal_actions[#state.legal_actions + 1] = action
            end
        end
    end
    local sellable = {}
    for _, joker in ipairs(state.jokers) do
        if joker.sellable then
            sellable[#sellable + 1] = joker.target_ref
        end
    end
    for _, consumable in ipairs(state.consumables) do
        if consumable.sellable then
            sellable[#sellable + 1] = consumable.target_ref
        end
    end
    if #sellable > 0 then
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "sell_owned_item",
            target_refs = { item_id = sellable },
        }
    end
end

function ProductionBalatroAdapter:_hand_observation()
    if
        G.STAGE ~= G.STAGES.RUN
        or G.STATE ~= G.STATES.SELECTING_HAND
        or not G.STATE_COMPLETE
        or G.SETTINGS.paused
        or runtime_is_busy()
        or (G.GAME.blind and G.GAME.blind.block_play)
        or not G.hand
        or not G.hand.cards
        or #G.hand.cards < 1
    then
        return nil
    end
    local state = self:_run_state()
    local blind = G.GAME.blind and G.GAME.blind.config and G.GAME.blind.config.blind
    state.current_blind = blind
            and self:_blind(G.GAME.blind_on_deck or "Current", blind.key, G.GAME.blind)
        or nil
    state.score = G.GAME.chips or 0
    state.hands_left = G.GAME.current_round.hands_left
    state.discards_left = G.GAME.current_round.discards_left
    state.hand = {}
    local card_refs = {}
    local card_signature = {}
    local facedown_cards = {}
    local forced_refs = {}
    for index, card in ipairs(G.hand.cards) do
        local snapshot = self:_playing_card(card, index, true)
        state.hand[index] = snapshot
        card_refs[index] = snapshot.target_ref
        card_signature[index] = snapshot.target_ref
        if card.ability and card.ability.forced_selection then
            forced_refs[#forced_refs + 1] = snapshot.target_ref
        end
        if card.facing == "back" then
            facedown_cards[#facedown_cards + 1] = self:_playing_card(card, index)
        end
    end
    apply_hand_order_projections(state, G.hand.cards)
    state.remaining_deck = self:_remaining_deck()
    state.poker_hands = self:_poker_hands()
    local max_cards = math.min(5, #state.hand)
    local card_targets = { card_ids = card_refs }
    local card_arguments = { card_ids = { min_items = 1, max_items = max_cards } }
    local required_targets = #forced_refs > 0 and { card_ids = forced_refs } or nil
    state.legal_actions = {}
    if state.hands_left > 0 and not (G.GAME.blind and G.GAME.blind.block_play) then
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "play_hand",
            target_refs = card_targets,
            required_target_refs = required_targets,
            arguments = card_arguments,
        }
    end
    if state.discards_left > 0 then
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "discard_cards",
            target_refs = card_targets,
            required_target_refs = required_targets,
            arguments = card_arguments,
        }
    end
    self:_append_owned_actions(state)
    local hidden_state = { deck_order = {} }
    local deck_cards = G.deck and G.deck.cards or {}
    for index = #deck_cards, 1, -1 do
        hidden_state.deck_order[#hidden_state.deck_order + 1] =
            self:_playing_card(deck_cards[index], index)
    end
    if #facedown_cards > 0 then
        hidden_state.facedown_cards = facedown_cards
    end
    local facedown_jokers = {}
    for index, card in ipairs(G.jokers and G.jokers.cards or {}) do
        if card.facing == "back" then
            facedown_jokers[#facedown_jokers + 1] = self:_owned_item(card, "joker", index)
        end
    end
    if #facedown_jokers > 0 then
        hidden_state.facedown_jokers = facedown_jokers
    end
    return self:_finish(
        "hand_play",
        state,
        table.concat({
            "hand_play",
            tostring(state.ante),
            tostring(state.money),
            blind and blind.key or "",
            tostring(state.score),
            tostring(state.hands_left),
            tostring(state.discards_left),
            hand_order_signature(self, G.hand.cards, card_signature),
            tostring(#state.remaining_deck),
            owned_signature(state),
        }, "|"),
        hidden_state
    )
end

local pack_kind_category = {
    Arcana = "arcana",
    Celestial = "celestial",
    Spectral = "spectral",
    Standard = "standard",
    Buffoon = "buffoon",
}

local function pack_category_from_booster(booster)
    local center = booster and booster.config and booster.config.center
    local kind = center and center.kind
    if pack_kind_category[kind] then
        return pack_kind_category[kind]
    end
    local name = booster and booster.ability and booster.ability.name or ""
    if name:find("Arcana") then
        return "arcana"
    elseif name:find("Celestial") then
        return "celestial"
    elseif name:find("Spectral") then
        return "spectral"
    elseif name:find("Standard") then
        return "standard"
    elseif name:find("Buffoon") then
        return "buffoon"
    end
end

local vanilla_auto_booster_tags = {
    tag_charm = true,
    tag_meteor = true,
    tag_ethereal = true,
    tag_standard = true,
    tag_buffoon = true,
}

local function booster_size(booster)
    local ability = booster and booster.ability or {}
    local center = booster and booster.config and booster.config.center or {}
    local base = tonumber(ability.extra)
        or tonumber(center.extra)
        or tonumber(center.config and center.config.extra)
    if not base then
        return nil
    end
    local modifier = tonumber(
        G and G.GAME and G.GAME.modifiers and G.GAME.modifiers.booster_size_mod
    ) or 0
    return math.max(1, base + modifier)
end

local function pack_category()
    if not G.STATES then
        return nil
    end
    if G.STATE == G.STATES.TAROT_PACK then
        return "arcana"
    elseif G.STATE == G.STATES.PLANET_PACK then
        return "celestial"
    elseif G.STATE == G.STATES.SPECTRAL_PACK then
        return "spectral"
    elseif G.STATE == G.STATES.STANDARD_PACK then
        return "standard"
    elseif G.STATE == G.STATES.BUFFOON_PACK then
        return "buffoon"
    elseif G.STATE == G.STATES.SMODS_BOOSTER_OPENED then
        return pack_category_from_booster(SMODS and SMODS.OPENED_BOOSTER)
    end
end

local function pack_is_visible()
    return pack_category()
        and G.STAGE == G.STAGES.RUN
        and G.STATE_COMPLETE
        and G.booster_pack
        and G.pack_cards
        and G.pack_cards.cards
        and #G.pack_cards.cards >= 1
end

local function overlay_uie(id)
    return G.OVERLAY_MENU and G.OVERLAY_MENU.get_UIE_by_ID and G.OVERLAY_MENU:get_UIE_by_ID(id)
end

local function victory_overlay_is_visible()
    return overlay_uie("you_win_UI") or overlay_uie("from_game_won")
end

local function defeat_overlay_is_visible()
    return G.STATE == G.STATES.GAME_OVER and overlay_uie("from_game_over")
end

local function score_amount(name)
    local score = G.GAME and G.GAME.round_scores and G.GAME.round_scores[name]
    return score and score.amt or 0
end

local function most_played_hand()
    local name, count = nil, 0
    for key, usage in pairs(G.GAME.hand_usage or {}) do
        local played = usage.count or 0
        if played > count then
            name = usage.order or key
            count = played
        end
    end
    return name
end

function ProductionBalatroAdapter:_terminal_observation(phase)
    local state = self:_run_state()
    state.round = G.GAME.round
    state.best_hand = score_amount("hand")
    state.most_played_hand = most_played_hand()
    state.cards_played = score_amount("cards_played")
    state.cards_discarded = score_amount("cards_discarded")
    state.cards_purchased = score_amount("cards_purchased")
    state.times_rerolled = score_amount("times_rerolled")
    state.new_collection = score_amount("new_collection")
    if phase == "defeat" then
        local blind = G.GAME.blind and G.GAME.blind.config and G.GAME.blind.config.blind
        if blind and blind.key then
            local name, description =
                self:_english_entry("Blind", blind.key, nil, blind.name or blind.key)
            state.defeated_by = {
                key = blind.key,
                name = name,
                description = description,
            }
        end
    end
    state.legal_actions = {}
    if phase == "victory" then
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "continue_endless",
        }
    end
    state.legal_actions[#state.legal_actions + 1] = {
        tool = "return_to_menu",
    }
    return self:_finish(
        phase,
        state,
        table.concat({
            phase,
            tostring(state.ante),
            tostring(state.round),
            tostring(state.best_hand),
            tostring(state.won),
            state.defeated_by and state.defeated_by.key or "",
        }, "|")
    )
end

local function state_label()
    if not G then
        return "nil"
    end
    for name, value in pairs(G.STATES or {}) do
        if value == G.STATE then
            return name
        end
    end
    return tostring(G.STATE)
end

local function observe_slot()
    if not G or not G.STATES then
        return "none"
    end
    if G.STATE == G.STATES.BLIND_SELECT then
        return "blind"
    end
    if G.STATE == G.STATES.SELECTING_HAND then
        return "hand"
    end
    if G.STATE == G.STATES.SHOP then
        return "shop"
    end
    if pack_category() then
        return "booster"
    end
    return "none"
end

local function observe_block_diagnostic(adapter)
    return {
        complete = G and G.STATE_COMPLETE,
        hand = G and G.hand and G.hand.cards and #G.hand.cards or 0,
        locked = not not controller_is_locked(),
        money = G and G.GAME and G.GAME.dollars,
        overlay = not not (G and G.OVERLAY_MENU),
        paused = G and G.SETTINGS and G.SETTINGS.paused,
        pending_dollars = adapter and adapter.pending_dollars,
        pending_dollars_direction = adapter and adapter.pending_dollars_dir,
        shop = not not (G and G.shop),
        slot = observe_slot(),
        state = state_label(),
        state_value = G and G.STATE,
        stop_use = G and G.GAME and G.GAME.STOP_USE,
    }
end

local function observe_block_line(diagnostic, code)
    local prefix = code == "GAME_BLOCKED" and "observe blocked" or "observe pending"
    return table.concat({
        prefix,
        "state=" .. tostring(diagnostic.state),
        "complete=" .. tostring(diagnostic.complete),
        "paused=" .. tostring(diagnostic.paused),
        "stop_use=" .. tostring(diagnostic.stop_use),
        "locked=" .. tostring(diagnostic.locked),
        "money=" .. tostring(diagnostic.money),
        "pending_d=" .. tostring(diagnostic.pending_dollars),
        "pending_dir=" .. tostring(diagnostic.pending_dollars_direction),
        "shop=" .. tostring(diagnostic.shop),
        "hand=" .. tostring(diagnostic.hand),
        "overlay=" .. tostring(diagnostic.overlay),
        "slots=" .. tostring(diagnostic.slot),
    }, " ")
end

local function observe_block_error(adapter, code, message)
    local diagnostic = observe_block_diagnostic(adapter)
    return adapter_error(code, message, observe_block_line(diagnostic, code), diagnostic)
end

---@param _visibility "fair"|"omniscient"
---@return BalatroAdapterObservation?, BalatroAdapterError?
function ProductionBalatroAdapter:observe(_visibility)
    self:_run_id()
    if not G or not G.GAME or self.game_identity ~= G.GAME then
        self.continued_endless = false
    end
    if victory_overlay_is_visible() then
        return self:_terminal_observation("victory")
    end
    if G.STATE == G.STATES.GAME_OVER then
        if defeat_overlay_is_visible() then
            return self:_terminal_observation("defeat")
        end
        if G.OVERLAY_MENU then
            return nil,
                observe_block_error(
                    self,
                    "GAME_BLOCKED",
                    "Balatro is blocked by a player-controlled overlay"
                )
        end
        return nil,
            observe_block_error(self, "DECISION_PENDING", "Balatro is opening the game over screen")
    end
    local menu = self:_menu_observation()
    if menu then
        return menu
    end
    if G.OVERLAY_MENU then
        return nil,
            observe_block_error(
                self,
                "GAME_BLOCKED",
                "Balatro is blocked by a player-controlled overlay"
            )
    end
    if
        G.GAME
        and G.GAME.won
        and G.STATE == G.STATES.ROUND_EVAL
        and not self.continued_endless
        and (G.GAME.current_round and G.GAME.current_round.round_text) ~= "Endless Round "
    then
        return nil,
            observe_block_error(self, "DECISION_PENDING", "Balatro is opening the victory screen")
    end
    if self:_maybe_cash_out() then
        return nil,
            observe_block_error(self, "DECISION_PENDING", "Balatro is applying a forced cash out")
    end
    if money_is_pending(self) and not pack_is_visible() then
        return nil, observe_block_error(self, "DECISION_PENDING", "Balatro is applying money")
    end
    local observation = self:_blind_observation()
        or self:_hand_observation()
        or self:_shop_observation()
        or self:_booster_observation()
    if observation then
        return observation
    end
    return nil,
        observe_block_error(
            self,
            "DECISION_PENDING",
            "Balatro is not at a stable supported decision state"
        )
end

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

local function vanilla_proto(proto)
    return proto and not proto.mod and not proto.omit and not proto.demo and not proto.wip
end

local function hidden_proto(proto)
    return proto.hidden or proto.rarity == 4
end

function ProductionBalatroAdapter:_loc_misc(group, key)
    local misc = self.english and self.english.misc
    return misc and misc[group] and misc[group][key] or key
end

function ProductionBalatroAdapter:_encyclopedia_tag_vars(proto)
    local config = proto.config or {}
    local name = proto.name
    if name == "Investment Tag" then
        return { config.dollars }
    elseif name == "Handy Tag" then
        return { config.dollars_per_hand, 0 }
    elseif name == "Garbage Tag" then
        return { config.dollars_per_discard, 0 }
    elseif name == "Juggle Tag" then
        return { config.h_size }
    elseif name == "Top-up Tag" then
        return { config.spawn_jokers }
    elseif name == "Skip Tag" then
        return { config.skip_bonus, config.skip_bonus }
    elseif name == "Orbital Tag" then
        return { "Poker Hand", config.levels }
    elseif name == "Economy Tag" then
        return { config.max }
    end
    return {}
end

function ProductionBalatroAdapter:_encyclopedia_voucher_vars(proto)
    local config = proto.config or {}
    local name = proto.name
    if
        name == "Tarot Merchant"
        or name == "Tarot Tycoon"
        or name == "Planet Merchant"
        or name == "Planet Tycoon"
    then
        return { config.extra_disp }
    elseif name == "Seed Money" or name == "Money Tree" then
        return { (config.extra or 0) / 5 }
    elseif config.extra ~= nil then
        return { config.extra }
    end
end

function ProductionBalatroAdapter:_encyclopedia_enhanced_vars(proto)
    local config = proto.config or {}
    if proto.effect == "Mult Card" then
        return { config.mult }
    elseif proto.effect == "Glass Card" then
        return { config.Xmult, 1, config.extra }
    elseif proto.effect == "Steel Card" then
        return { config.h_x_mult }
    elseif proto.effect == "Stone Card" then
        return { config.bonus }
    elseif proto.effect == "Gold Card" then
        return { config.h_dollars }
    elseif proto.effect == "Lucky Card" then
        return { 1, config.mult, 5, config.p_dollars, 15 }
    end
    return { config.bonus or config.mult or config.extra }
end

local planet_level_vars = {
    ["Flush Five"] = { 3, 50 },
    ["Flush House"] = { 4, 40 },
    ["Five of a Kind"] = { 3, 35 },
    ["Straight Flush"] = { 4, 40 },
    ["Four of a Kind"] = { 3, 30 },
    ["Full House"] = { 2, 25 },
    Flush = { 2, 15 },
    Straight = { 3, 30 },
    ["Three of a Kind"] = { 2, 20 },
    ["Two Pair"] = { 1, 20 },
    Pair = { 1, 15 },
    ["High Card"] = { 1, 10 },
}

function ProductionBalatroAdapter:_encyclopedia_planet_vars(proto)
    local hand_type = proto.config and proto.config.hand_type
    local increment = planet_level_vars[hand_type] or { 1, 1 }
    return {
        1,
        self:_loc_misc("poker_hands", hand_type),
        increment[1],
        increment[2],
    }
end

function ProductionBalatroAdapter:_encyclopedia_tarot_vars(proto)
    local config = proto.config or {}
    local name = proto.name
    if name == "Strength" or name == "The Hanged Man" or name == "Death" then
        return { config.max_highlighted }
    elseif name == "The High Priestess" then
        return { config.planets }
    elseif name == "The Emperor" then
        return { config.tarots }
    elseif name == "The Hermit" then
        return { config.extra }
    elseif name == "The Wheel of Fortune" then
        return { 1, config.extra }
    elseif name == "Temperance" then
        return { config.extra, 0 }
    elseif name == "The Star" or name == "The Moon" or name == "The Sun" or name == "The World" then
        return { config.max_highlighted, self:_loc_misc("suits_plural", config.suit_conv) }
    elseif config.mod_conv then
        local entry = self.english
            and self.english.descriptions
            and self.english.descriptions.Enhanced
            and self.english.descriptions.Enhanced[config.mod_conv]
        return { config.max_highlighted, entry and entry.name or config.mod_conv }
    end
end

function ProductionBalatroAdapter:_encyclopedia_spectral_vars(proto)
    local config = proto.config or {}
    local extra = config.extra
    if proto.name == "Immolate" and type(extra) == "table" then
        return { extra.destroy, extra.dollars }
    elseif proto.name == "Ectoplasm" then
        return { 1 }
    elseif extra ~= nil then
        return { extra }
    end
end

function ProductionBalatroAdapter:_encyclopedia_joker_vars(proto)
    local config = proto.config or {}
    local extra = config.extra
    local extra_t = type(extra) == "table" and extra or nil
    local name = proto.name
    local poker = function(key)
        return self:_loc_misc("poker_hands", key)
    end
    local suit = function(key, plural)
        return self:_loc_misc(plural and "suits_plural" or "suits_singular", key)
    end
    local mult = config.mult or 0
    local x_mult = config.Xmult or 1

    if name == "Joker" then
        return { mult }
    elseif
        name == "Jolly Joker"
        or name == "Zany Joker"
        or name == "Mad Joker"
        or name == "Crazy Joker"
        or name == "Droll Joker"
    then
        return { config.t_mult, poker(config.type) }
    elseif
        name == "Sly Joker"
        or name == "Wily Joker"
        or name == "Clever Joker"
        or name == "Devious Joker"
        or name == "Crafty Joker"
    then
        return { config.t_chips, poker(config.type) }
    elseif name == "Half Joker" then
        return extra_t and { extra_t.mult, extra_t.size }
    elseif name == "Fortune Teller" then
        return { extra or 0, 0 }
    elseif name == "Steel Joker" then
        return { extra, 1 }
    elseif name == "Stone Joker" then
        return { extra, 0 }
    elseif name == "Joker Stencil" or name == "Ceremonial Dagger" or name == "Swashbuckler" then
        return { name == "Joker Stencil" and x_mult or mult }
    elseif
        name == "Greedy Joker"
        or name == "Lusty Joker"
        or name == "Wrathful Joker"
        or name == "Gluttonous Joker"
    then
        return extra_t and { extra_t.s_mult, suit(extra_t.suit) }
    elseif name == "Green Joker" then
        return extra_t and { extra_t.hand_add, extra_t.discard_sub, mult }
    elseif name == "Hack" or name == "Dusk" or name == "Sock and Buskin" then
        return { (extra or 0) + 1 }
    elseif name == "Faceless Joker" then
        return extra_t and { extra_t.dollars, extra_t.faces }
    elseif name == "Drunkard" then
        return { config.d_size }
    elseif name == "Juggler" then
        return { config.h_size }
    elseif name == "Mystic Summit" then
        return extra_t and { extra_t.mult, extra_t.d_remaining }
    elseif name == "Loyalty Card" then
        return extra_t and { extra_t.Xmult, (extra_t.every or 0) + 1, extra_t.remaining }
    elseif name == "Scholar" then
        return extra_t and { extra_t.mult, extra_t.chips }
    elseif
        name == "Space Joker"
        or name == "8 Ball"
        or name == "Business Card"
        or name == "Hallucination"
    then
        return { 1, extra }
    elseif name == "Gros Michel" then
        return extra_t and { extra_t.mult, 1, extra_t.odds }
    elseif name == "Cavendish" then
        return extra_t and { extra_t.Xmult, 1, extra_t.odds }
    elseif name == "Bloodstone" then
        return extra_t and { 1, extra_t.odds, extra_t.Xmult }
    elseif name == "Reserved Parking" then
        return extra_t and { extra_t.dollars, 1, extra_t.odds }
    elseif name == "Blackboard" then
        return { extra, suit("Spades", true), suit("Clubs", true) }
    elseif
        name == "Runner"
        or name == "Ice Cream"
        or name == "Wee Joker"
        or name == "Square Joker"
    then
        return extra_t and { extra_t.chips, extra_t.chip_mod }
    elseif name == "To Do List" then
        return extra_t and { extra_t.dollars, poker("High Card") }
    elseif name == "Troubadour" then
        return extra_t and { extra_t.h_size, -(extra_t.h_plays or 0) }
    elseif name == "Merry Andy" then
        return { config.d_size, config.h_size }
    elseif name == "The Idol" then
        return { extra, "Ace", suit("Spades", true) }
    elseif name == "Mail-In Rebate" then
        return { extra, "Ace" }
    elseif name == "Ancient Joker" then
        return { extra, suit("Spades") }
    elseif name == "Castle" then
        return extra_t and { extra_t.chip_mod, suit("Spades"), extra_t.chips or 0 }
    elseif name == "Walkie Talkie" then
        return extra_t and { extra_t.chips, extra_t.mult }
    elseif name == "Stuntman" then
        return extra_t and { extra_t.chip_mod, extra_t.h_size }
    elseif name == "Turtle Bean" then
        return extra_t and { extra_t.h_size, extra_t.h_mod }
    elseif name == "Rocket" then
        return extra_t and { extra_t.dollars, extra_t.increase }
    elseif name == "Yorick" then
        return extra_t and { extra_t.xmult, extra_t.discards, extra_t.discards, x_mult }
    elseif name == "Seance" then
        return extra_t and { poker(extra_t.poker_hand) }
    elseif name == "Diet Cola" then
        local tag_name = self:_english_entry("Tag", "tag_double", nil, "Double Tag")
        return { tag_name }
    elseif
        name == "The Duo"
        or name == "The Trio"
        or name == "The Family"
        or name == "The Order"
        or name == "The Tribe"
    then
        return { x_mult, poker(config.type) }
    elseif name == "Spare Trousers" then
        return { extra, poker("Two Pair"), mult }
    elseif name == "Ride the Bus" then
        return { extra, mult }
    elseif name == "Red Card" or name == "Flash Card" then
        return { extra, mult }
    elseif
        name == "Constellation"
        or name == "Throwback"
        or name == "Glass Joker"
        or name == "Hit the Road"
        or name == "Madness"
        or name == "Vampire"
        or name == "Hologram"
        or name == "Obelisk"
        or name == "Lucky Cat"
        or name == "Campfire"
    then
        return { extra, x_mult }
    elseif name == "Popcorn" then
        return { mult, extra }
    elseif name == "Ramen" then
        return { x_mult, extra }
    elseif name == "Invisible Joker" then
        return { extra, 0 }
    elseif name == "Blue Joker" then
        return { extra, (extra or 0) * 52 }
    elseif name == "Satellite" or name == "Cloud 9" or name == "Abstract Joker" then
        return { extra, 0 }
    elseif name == "Erosion" then
        return { extra, 0, 52 }
    elseif name == "Bull" then
        return { extra, 0 }
    elseif name == "Bootstraps" then
        return extra_t and { extra_t.mult, extra_t.dollars, 0 }
    elseif name == "Caino" then
        return { extra, 1 }
    elseif name == "Driver's License" then
        return { extra, 0 }
    elseif extra_t then
        return { extra_t.mult or extra_t.Xmult or extra_t.chips or extra }
    elseif extra ~= nil then
        return { extra }
    elseif config.t_mult then
        return { config.t_mult, poker(config.type) }
    elseif config.t_chips then
        return { config.t_chips, poker(config.type) }
    elseif config.mult ~= nil then
        return { config.mult }
    else
        return { x_mult }
    end
end

function ProductionBalatroAdapter:_encyclopedia_vars(proto, set)
    if set == "Back" then
        return self:_deck_vars(proto)
    elseif set == "Tag" then
        return self:_encyclopedia_tag_vars(proto)
    elseif set == "Voucher" then
        return self:_encyclopedia_voucher_vars(proto)
    elseif set == "Edition" then
        return proto.config and { proto.config.extra }
    elseif set == "Enhanced" then
        return self:_encyclopedia_enhanced_vars(proto)
    elseif set == "Booster" then
        local config = proto.config or {}
        return { config.choose, config.extra }
    elseif set == "Planet" then
        return self:_encyclopedia_planet_vars(proto)
    elseif set == "Tarot" then
        return self:_encyclopedia_tarot_vars(proto)
    elseif set == "Spectral" then
        return self:_encyclopedia_spectral_vars(proto)
    elseif set == "Blind" then
        return proto.vars
    elseif set == "Joker" then
        return self:_encyclopedia_joker_vars(proto)
    end
end

function ProductionBalatroAdapter:_encyclopedia_items(set)
    local items = {}
    if set == "Blind" then
        for _, key in ipairs(sorted_keys(G.P_BLINDS or {})) do
            local proto = G.P_BLINDS[key]
            if proto then
                items[#items + 1] = { proto = proto, key = proto.key or key }
            end
        end
        table.sort(items, function(left, right)
            return (left.proto.order or 0) < (right.proto.order or 0)
        end)
        return items
    end
    for _, proto in ipairs(G.P_CENTER_POOLS[set] or {}) do
        if proto and proto.key then
            items[#items + 1] = { proto = proto, key = proto.key }
        end
    end
    return items
end

function ProductionBalatroAdapter:_encyclopedia_include(proto, set, key, visibility)
    if not vanilla_proto(proto) or not key then
        return false
    end
    if visibility == "omniscient" then
        return true
    end
    if hidden_proto(proto) then
        return false
    end
    if set == "Stake" then
        for _, deck in ipairs(G.P_CENTER_POOLS.Back or {}) do
            if
                vanilla_proto(deck)
                and deck.key
                and deck.unlocked ~= false
                and deck.discovered
                and SMODS.stake_is_unlocked(key, deck.key)
            then
                return true
            end
        end
        return false
    end
    return proto.unlocked ~= false
end

function ProductionBalatroAdapter:_encyclopedia_entry(proto, set, key, visibility)
    if set == "Seal" and not tostring(key):match("_seal$") then
        key = string.lower(key) .. "_seal"
    end
    local entry = { key = key, set = set }
    if visibility ~= "omniscient" and proto.discovered == false then
        return entry
    end
    local loc_set = (set == "Seal" or set == "Booster") and "Other" or set
    local loc_key = key
    if set == "Booster" then
        loc_key = key:match("^(p_.+)_%d+$") or key
    end
    local name, description = self:_english_entry(
        loc_set,
        loc_key,
        self:_encyclopedia_vars(proto, set),
        proto.name or key
    )
    entry.name = name
    entry.description = description
    return entry
end

---@param visibility "fair"|"omniscient"
---@return table?, BalatroAdapterError?
function ProductionBalatroAdapter:encyclopedia(visibility)
    local entries = {}
    for _, set in ipairs(encyclopedia_sets) do
        for _, item in ipairs(self:_encyclopedia_items(set)) do
            if self:_encyclopedia_include(item.proto, set, item.key, visibility) then
                entries[#entries + 1] =
                    self:_encyclopedia_entry(item.proto, set, item.key, visibility)
            end
        end
    end
    return { visibility = visibility, entries = entries }
end

local function valid_seed(seed)
    return seed == nil
        or (type(seed) == "string" and #seed >= 1 and #seed <= 8 and seed:match("^[A-Z1-9]+$"))
end

function ProductionBalatroAdapter:_execute_start_run(arguments)
    local menu = self:_menu_observation()
    if not menu or (menu.phase ~= "main_menu" and menu.phase ~= "run_setup") then
        return nil, adapter_error("INVALID_PHASE", "start_run requires the main menu or run setup")
    end
    local deck = G.P_CENTERS[arguments.deck_key]
    if
        not deck
        or deck.set ~= "Back"
        or deck.omit
        or deck.mod
        or deck.unlocked == false
        or deck.discovered == false
    then
        return nil, adapter_error("INVALID_PARAMS", "deck_key is not an available standard deck")
    end
    local stake = G.P_CENTER_POOLS.Stake[arguments.stake]
    if not stake or stake.mod then
        return nil, adapter_error("INVALID_PARAMS", "stake is not a standard stake level")
    end
    if not SMODS.stake_is_unlocked(stake.key, deck.key) then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "The stake is locked for this deck")
    end
    if not valid_seed(arguments.seed) then
        return nil,
            adapter_error(
                "INVALID_PARAMS",
                "seed must use one to eight uppercase letters or digits 1-9"
            )
    end

    if not G.GAME or (not G.GAME.won and not G.GAME.seeded) then
        if G.SAVED_GAME then
            if not G.SAVED_GAME.GAME.won then
                G.PROFILES[G.SETTINGS.profile].high_scores.current_streak.amt = 0
            end
            G:save_settings()
        end
    end

    local ok, call_error = pcall(G.FUNCS.start_run, nil, {
        deck_choice = { name = deck.name },
        stake_choice = stake.order,
        seed = arguments.seed,
    })
    if not ok then
        return nil, adapter_error("INTERNAL_ERROR", "Could not start run: " .. tostring(call_error))
    end
    return {
        pending = true,
        events = {
            {
                type = "run_started",
                deck_key = deck.key,
                stake = stake.order,
                seeded = arguments.seed ~= nil,
            },
        },
    }
end

current_blind_reference = function()
    local slot = G.GAME and G.GAME.blind_on_deck
    local key = slot and G.GAME.round_resets.blind_choices[slot]
    return slot, key, slot and key and ("blind:" .. slot .. ":" .. key) or nil
end

function ProductionBalatroAdapter:_execute_select_blind(targets)
    local observation = self:_blind_observation()
    if not observation then
        return nil, adapter_error("INVALID_PHASE", "select_blind requires Blind selection")
    end
    local slot, key, reference = current_blind_reference()
    if targets.blind_id ~= reference then
        return nil, adapter_error("INVALID_TARGET", "blind_id is not the current Blind")
    end
    if not select_is_available(slot) then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "The current Blind cannot be selected")
    end
    local option = blind_option(slot)
    local button = option:get_UIE_by_ID("select_blind_button")
    local ok, call_error = pcall(G.FUNCS.select_blind, button)
    if not ok then
        return nil,
            adapter_error("INTERNAL_ERROR", "Could not select Blind: " .. tostring(call_error))
    end
    return {
        pending = true,
        events = { { type = "blind_selected", blind_key = key, slot = slot } },
    }
end

function ProductionBalatroAdapter:_execute_skip_blind(targets)
    local observation = self:_blind_observation()
    if not observation then
        return nil, adapter_error("INVALID_PHASE", "skip_blind requires Blind selection")
    end
    local slot, key, reference = current_blind_reference()
    if targets.blind_id ~= reference then
        return nil, adapter_error("INVALID_TARGET", "blind_id is not the current Blind")
    end
    if slot == "Boss" or not skip_is_available(slot) then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "The current Blind cannot be skipped")
    end
    local tag_key = G.GAME.round_resets.blind_tags[slot]
    local ok, call_error = pcall(G.FUNCS.skip_blind, { UIBox = blind_option(slot) })
    if not ok then
        return nil,
            adapter_error("INTERNAL_ERROR", "Could not skip Blind: " .. tostring(call_error))
    end
    return {
        pending = true,
        events = {
            { type = "blind_skipped", blind_key = key, slot = slot, tag_key = tag_key },
        },
    }
end

function ProductionBalatroAdapter:_cards_from_targets(card_ids)
    if type(card_ids) ~= "table" or #card_ids < 1 or #card_ids > 5 then
        return nil, adapter_error("INVALID_PARAMS", "card_ids must contain one to five cards")
    end
    local by_ref = {}
    for index, card in ipairs(G.hand and G.hand.cards or {}) do
        by_ref["card:" .. tostring(card.sort_id or index)] = card
    end
    local cards = {}
    local seen = {}
    for _, reference in ipairs(card_ids) do
        local card = by_ref[reference]
        if not card then
            return nil, adapter_error("INVALID_TARGET", "card_ids contains an unknown card")
        end
        if seen[card] then
            return nil, adapter_error("INVALID_TARGET", "card_ids contains a duplicate card")
        end
        seen[card] = true
        cards[#cards + 1] = card
    end
    return cards
end

function ProductionBalatroAdapter:_highlight_cards(cards)
    if G.hand.unhighlight_all then
        G.hand:unhighlight_all()
    elseif G.hand.highlighted then
        for index = #G.hand.highlighted, 1, -1 do
            G.hand.highlighted[index] = nil
        end
    end
    for index, card in ipairs(cards) do
        if card.T then
            card.T.x = index
        end
        if G.hand.add_to_highlighted then
            G.hand:add_to_highlighted(card)
        else
            G.hand.highlighted = G.hand.highlighted or {}
            G.hand.highlighted[#G.hand.highlighted + 1] = card
            card.highlighted = true
        end
    end
end

local scoring_kinds = {
    chips = "chips",
    h_chips = "chips",
    chip_mod = "chips",
    mult = "mult",
    h_mult = "mult",
    mult_mod = "mult",
    x_mult = "x_mult",
    Xmult = "x_mult",
    xmult = "x_mult",
    x_mult_mod = "x_mult",
    Xmult_mod = "x_mult",
    x_chips = "x_chips",
    xchips = "x_chips",
    Xchip_mod = "x_chips",
}

local money_kinds = {
    dollars = "dollars",
    p_dollars = "dollars",
    h_dollars = "dollars",
}

local component_keys = {
    playing_card = "playing_card",
    enhancement = "enhancement",
    edition = "edition",
    seals = "seal",
    jokers = "joker",
}

local function lifecycle_joker_phase(context, parent_phase)
    if type(context) ~= "table" then
        return nil
    end
    if
        context.open_booster
        or context.buying_card
        or context.selling_self
        or context.selling_card
    then
        return parent_phase or "shop"
    end
    if context.reroll_shop or context.ending_shop then
        return "shop"
    end
    if context.skip_blind or context.setting_blind then
        return "blind_selection"
    end
    if context.skipping_booster then
        return "booster"
    end
    if context.first_hand_drawn then
        return "hand"
    end
    if context.playing_card_added then
        return parent_phase or "hand"
    end
end

local function context_phase(context, parent_phase)
    if type(context) ~= "table" then
        return "playing_card"
    end
    local lifecycle_phase = lifecycle_joker_phase(context, parent_phase)
    if lifecycle_phase then
        return lifecycle_phase
    end
    if context.joker_main or context.pre_joker or context.post_joker then
        return "joker_main"
    end
    if context.discard or context.pre_discard then
        return "discard"
    end
    if context.before then
        return "before"
    end
    if context.after then
        return "after"
    end
    if context.end_of_round then
        return "end_of_round"
    end
    if context.debuffed_hand then
        return "debuffed_hand"
    end
    if context.destroy_card or context.destroying_card or context.remove_playing_cards then
        return "destroying_card"
    end
    if G and context.cardarea == G.hand then
        return "held_in_hand"
    end
    return "playing_card"
end

local function is_joker_card(card)
    return type(card) == "table"
        and (
            (card.ability and card.ability.set == "Joker")
            or (G and G.jokers and card.area == G.jokers)
        )
end

local function joker_source(effect, card)
    if type(effect) == "table" then
        for _, candidate in ipairs({ effect.card, effect.juice_card, card }) do
            if is_joker_card(candidate) then
                return candidate
            end
        end
    end
    return card
end

local function current_calculation_context()
    local stack = SMODS and SMODS.context_stack
    if type(stack) ~= "table" then
        return nil
    end
    for index = #stack, 1, -1 do
        local entry = stack[index]
        if type(entry) == "table" and type(entry.context) == "table" then
            return entry.context
        end
    end
end

function ProductionBalatroAdapter:_capture()
    local context = self.resolution_capture
    return context and context.active and context or nil
end

function ProductionBalatroAdapter:_next_resolution_order()
    local context = self:_capture()
    if not context then
        return nil
    end
    context.next_order = context.next_order + 1
    return context.next_order
end

function ProductionBalatroAdapter:_current_scope()
    local context = self:_capture()
    return context and context.scope_stack[#context.scope_stack] or nil
end

function ProductionBalatroAdapter:_current_resolution_event()
    local context = self:_capture()
    return context and context.event_stack[#context.event_stack] or nil
end

function ProductionBalatroAdapter:_mark_resolution_invalid(path, message, raw_reference)
    local context = self:_capture()
    if context and not context.invalid then
        context.invalid = {
            path = path or "value.resolution",
            message = message or "Resolution capture is invalid",
            raw_reference = raw_reference,
        }
    end
end

function ProductionBalatroAdapter:_push_resolution_scope(scope)
    local context = self:_capture()
    if not context then
        return
    end
    context.scope_stack[#context.scope_stack + 1] = scope
    if scope.event then
        context.event_stack[#context.event_stack + 1] = scope.event
    end
end

function ProductionBalatroAdapter:_pop_resolution_scope(scope)
    local context = self:_capture()
    if not context then
        return
    end
    if scope.event then
        assert(context.event_stack[#context.event_stack] == scope.event, "resolution event stack")
        context.event_stack[#context.event_stack] = nil
    end
    assert(context.scope_stack[#context.scope_stack] == scope, "resolution scope stack")
    context.scope_stack[#context.scope_stack] = nil
end

local function area_limit(area)
    return area and area.config and tonumber(area.config.card_limit) or nil
end

local function value_or(value, fallback)
    return value ~= nil and value or fallback
end

local function run_mutation_snapshot()
    local game = G and G.GAME or {}
    local starting = game.starting_params or {}
    local round_resets = game.round_resets or {}
    local current_round = game.current_round or {}
    local modifiers = game.modifiers or {}
    local shop = game.shop or {}
    return {
        numeric_rules = {
            tarot_rate = tonumber(game.tarot_rate),
            planet_rate = tonumber(game.planet_rate),
            spectral_rate = tonumber(game.spectral_rate),
            edition_rate = tonumber(game.edition_rate),
            playing_card_rate = tonumber(game.playing_card_rate),
            shop_discount_percent = tonumber(game.discount_percent),
            shop_reroll_cost = tonumber(current_round.reroll_cost)
                or tonumber(round_resets.reroll_cost),
            interest_cap = tonumber(game.interest_cap) and game.interest_cap / 5 or nil,
            money_per_hand = tonumber(value_or(modifiers.money_per_hand, 1)),
            money_per_discard = tonumber(value_or(modifiers.money_per_discard, 0)),
            ante_scaling = tonumber(starting.ante_scaling),
        },
        boolean_rules = {
            no_interest = not not modifiers.no_interest,
            face_cards_removed = not not starting.no_faces,
            randomized_starting_deck = not not starting.erratic_suits_and_ranks,
            shop_free = not not game.shop_free,
        },
        capacities = {
            hand_size = area_limit(G and G.hand) or tonumber(starting.hand_size),
            joker_slots = area_limit(G and G.jokers) or tonumber(starting.joker_slots),
            consumable_slots = area_limit(G and G.consumeables)
                or tonumber(starting.consumable_slots),
            shop_slots = area_limit(G and G.shop_jokers) or tonumber(shop.joker_max),
        },
        starting_allowances = {
            hands = tonumber(starting.hands),
            discards = tonumber(starting.discards),
        },
        allowances = {
            hands = {
                base = tonumber(round_resets.hands),
                current = tonumber(current_round.hands_left),
            },
            discards = {
                base = tonumber(round_resets.discards),
                current = tonumber(current_round.discards_left),
            },
        },
        starting_dollars = tonumber(starting.dollars),
        ante = tonumber(round_resets.ante),
        blind_ante = tonumber(round_resets.blind_ante),
    }
end

local function effect_recorded_since(context, order, kind, field, value)
    for _, event in ipairs(context.events) do
        for _, effect in ipairs(event.effects or {}) do
            if
                effect.order > order
                and effect.kind == kind
                and (field == nil or effect[field] == value)
            then
                return true
            end
        end
    end
    return false
end

function ProductionBalatroAdapter:_record_application_mutations(before, since_order, settled)
    local context = self:_capture()
    local event = self:_current_resolution_event()
    if not context or not event or event.type ~= "apply" then
        return
    end
    local after = run_mutation_snapshot()

    local function record_numeric_rule(rule)
        local previous = before.numeric_rules[rule]
        local value = after.numeric_rules[rule]
        if
            type(previous) == "number"
            and type(value) == "number"
            and previous ~= value
            and not effect_recorded_since(context, since_order, "run_rule", "rule", rule)
        then
            self:_append_effect({
                kind = "run_rule",
                rule = rule,
                amount = value - previous,
                value = value,
            })
        end
    end

    local function record_boolean_rule(rule)
        local previous = before.boolean_rules[rule]
        local enabled = after.boolean_rules[rule]
        if
            previous ~= enabled
            and not effect_recorded_since(context, since_order, "run_rule", "rule", rule)
        then
            self:_append_effect({ kind = "run_rule", rule = rule, enabled = enabled })
        end
    end

    local function record_capacity(resource)
        local previous = before.capacities[resource]
        local value = after.capacities[resource]
        if
            type(previous) == "number"
            and type(value) == "number"
            and previous ~= value
            and not effect_recorded_since(context, since_order, "capacity", "resource", resource)
        then
            self:_record_capacity(resource, value - previous, value)
        end
    end

    local function record_allowance(resource)
        local previous
        local value
        local base
        local current
        if event.component == "back" then
            previous = before.starting_allowances[resource]
            value = after.starting_allowances[resource]
            base = value
            current = value
        else
            local previous_base = before.allowances[resource].base
            local previous_current = before.allowances[resource].current
            base = after.allowances[resource].base
            current = after.allowances[resource].current
            if
                settled
                and type(previous_base) == "number"
                and type(base) == "number"
                and previous_base ~= base
            then
                previous = previous_base
                value = base
            else
                previous = previous_current
                value = current
            end
        end
        if
            type(previous) == "number"
            and type(value) == "number"
            and type(base) == "number"
            and type(current) == "number"
            and previous ~= value
            and not effect_recorded_since(
                context,
                since_order,
                "round_allowance",
                "resource",
                resource
            )
        then
            self:_append_effect({
                kind = "round_allowance",
                resource = resource,
                amount = value - previous,
                base = base,
                current = current,
            })
        end
    end

    record_allowance("hands")
    if
        event.component == "back"
        and type(before.starting_dollars) == "number"
        and type(after.starting_dollars) == "number"
        and before.starting_dollars ~= after.starting_dollars
        and not effect_recorded_since(context, since_order, "dollars")
    then
        self:_append_effect({
            kind = "dollars",
            amount = after.starting_dollars - before.starting_dollars,
            money = after.starting_dollars,
        })
    end
    record_boolean_rule("face_cards_removed")
    record_numeric_rule("spectral_rate")
    record_allowance("discards")
    record_numeric_rule("shop_reroll_cost")
    record_boolean_rule("randomized_starting_deck")
    record_capacity("joker_slots")
    record_capacity("hand_size")
    record_numeric_rule("ante_scaling")
    record_capacity("consumable_slots")
    record_boolean_rule("no_interest")
    record_boolean_rule("shop_free")
    record_numeric_rule("money_per_hand")
    record_numeric_rule("money_per_discard")

    for _, rule in ipairs({
        "tarot_rate",
        "planet_rate",
        "edition_rate",
        "playing_card_rate",
        "shop_discount_percent",
        "interest_cap",
    }) do
        record_numeric_rule(rule)
    end
    record_capacity("shop_slots")

    if
        type(before.ante) == "number"
        and type(after.ante) == "number"
        and before.ante ~= after.ante
        and type(after.blind_ante) == "number"
        and not effect_recorded_since(context, since_order, "ante_change")
    then
        self:_append_effect({
            kind = "ante_change",
            amount = after.ante - before.ante,
            ante = after.ante,
            blind_ante = after.blind_ante,
        })
    end
end

function ProductionBalatroAdapter:_with_resolution_scope(scope, callback, ...)
    local args = { ... }
    local before = scope.kind == "apply" and run_mutation_snapshot() or nil
    local context = self:_capture()
    local since_order = context and context.next_order or 0
    self:_push_resolution_scope(scope)
    local results = { pcall(callback, unpack(args)) }
    if results[1] and before then
        self:_record_application_mutations(before, since_order)
    end
    if results[1] and scope.progress_card then
        self:_record_card_progress(scope.progress_card)
    end
    self:_pop_resolution_scope(scope)
    if not results[1] then
        error(results[2])
    end
    return unpack(results, 2)
end

function ProductionBalatroAdapter:_resolution_scope_token()
    local context = self:_capture()
    local scope = self:_current_scope()
    if not context or not scope or scope.kind == "action_mechanics" then
        return nil
    end
    return {
        capture = context,
        kind = scope.kind,
        phase = scope.phase,
        event = scope.event,
        progress_card = scope.progress_card,
    }
end

function ProductionBalatroAdapter:_source_ref(card)
    local context = self:_capture()
    local id = context and context.input_objects[card]
    return id and { input_target_id = id } or nil
end

function ProductionBalatroAdapter:_new_resolution_event(event)
    local context = self:_capture()
    if not context then
        return nil
    end
    event.order = self:_next_resolution_order()
    event.effects = event.effects or {}
    context.events[#context.events + 1] = event
    return event
end

local function component_origin(context, card, component, phase)
    local by_card = card and context.component_origins[card]
    return by_card and by_card[component .. "\0" .. phase] or nil
end

local function set_component_origin(context, card, component, phase, event)
    if not card then
        return
    end
    context.component_origins[card] = context.component_origins[card] or {}
    context.component_origins[card][component .. "\0" .. phase] = event
end

function ProductionBalatroAdapter:_open_component(key, effect, card, explicit_game_context)
    local context = self:_capture()
    local component = component_keys[key]
    if not context or not component then
        return nil
    end
    local source_card = component == "joker" and joker_source(effect, card) or card
    local game_context = explicit_game_context or current_calculation_context()
    local scope = self:_current_scope()
    local phase = game_context and context_phase(game_context, scope and scope.phase)
        or scope and scope.phase
        or "playing_card"
    local is_retrigger = (source_card and source_card.repetition_trigger)
        or (game_context and game_context.retrigger_joker)
    local created_record = context.created_records[source_card]
    local parent = self:_current_resolution_event() or created_record and created_record.parent
    if not parent and game_context and game_context.using_consumeable then
        parent = context.pending_consumable_application
    end
    if not parent and game_context and game_context.debuffed_hand then
        parent = context.pending_hand_debuff_event
    end
    if parent and not parent.order then
        parent = nil
    end
    local source = self:_source_ref(source_card)
    local event = {
        phase = phase,
        type = is_retrigger and "retrigger" or "trigger",
        component = component,
        source = source,
    }
    if is_retrigger then
        local origin = component_origin(context, source_card, component, phase)
        event.parent_order = origin and origin.order or (parent and parent.order)
        local cause_card = context.pending_retrigger_cause
        if game_context and type(game_context.retrigger_joker) == "table" then
            cause_card = game_context.retrigger_joker
        end
        event.cause = self:_source_ref(cause_card or source_card)
        if not event.parent_order or not event.cause then
            self:_mark_resolution_invalid(
                "value.resolution.retrigger",
                "Resolution retrigger causality is incomplete",
                tostring(cause_card or source_card)
            )
        end
    elseif parent then
        event.parent_order = parent.order
    end
    if not source and not parent then
        event._unattributed = true
        event.effects = {}
        event._source_card = source_card
    else
        self:_new_resolution_event(event)
    end
    if event.type == "trigger" then
        set_component_origin(context, source_card, component, phase, event)
        context.pending_retrigger_cause = nil
    end
    local event_scope = {
        kind = event.type,
        phase = phase,
        event = event,
        progress_card = component == "joker"
                and not (game_context and game_context.blueprint)
                and card
            or nil,
    }
    event._scope = event_scope
    self:_push_resolution_scope(event_scope)
    return event
end

function ProductionBalatroAdapter:_close_component(event)
    if event and event._scope then
        self:_pop_resolution_scope(event._scope)
        event._scope = nil
    end
end

function ProductionBalatroAdapter:_append_effect(effect)
    local context = self:_capture()
    if not context or type(effect) ~= "table" then
        return
    end
    local event = self:_current_resolution_event()
    if event and event._unattributed then
        self:_mark_resolution_invalid(
            "value.resolution.source",
            "Resolution component source is not an input object",
            tostring(event._source_card)
        )
        event._unattributed = nil
        event._source_card = nil
    end
    if not event then
        local scope = self:_current_scope()
        if scope and scope.kind ~= "action_mechanics" then
            self:_mark_resolution_invalid(
                "value.resolution.effects",
                "Resolution effect has no explicit event scope"
            )
        end
        return
    end
    effect.order = self:_next_resolution_order()
    event.effects[#event.effects + 1] = effect
    return effect
end

function ProductionBalatroAdapter:_record_card_progress(card)
    local context = self:_capture()
    local event = self:_current_resolution_event()
    if not context or not event or event.component ~= "joker" or type(card) ~= "table" then
        return
    end
    local before = context.joker_progress[card] or {}
    local after = joker_progress_snapshot(card)
    context.joker_progress[card] = after
    for _, entry in ipairs(joker_progress_fields) do
        local previous = before[entry.resource]
        local value = after[entry.resource]
        if type(previous) == "number" and type(value) == "number" and previous ~= value then
            self:_append_effect({
                kind = "card_progress",
                resource = entry.resource,
                amount = value - previous,
                value = value,
            })
        end
    end
end

function ProductionBalatroAdapter:_record_scope_card_progress()
    local scope = self:_current_scope()
    if scope and scope.progress_card then
        self:_record_card_progress(scope.progress_card)
    end
end

local function created_kind(card)
    if type(card) == "table" and card.ability and card.ability.set == "Joker" then
        return "joker"
    end
    local set = card.ability and card.ability.set
    if card.ability and card.ability.consumeable then
        return "consumable"
    end
    if set == "Voucher" then
        return "voucher"
    end
    if set == "Tarot" or set == "Planet" or set == "Spectral" then
        return "consumable"
    end
    return "playing_card"
end

local function created_key(card)
    if created_kind(card) == "playing_card" then
        return card.config and card.config.card_key or nil
    end
    local center = card.config and card.config.center
    return center and center.key or nil
end

local function created_destination(card, area, copied_from)
    if
        area ~= nil
        and G
        and (area == G.shop_jokers or area == G.shop_vouchers or area == G.shop_booster)
    then
        return "shop_offer"
    end
    if created_kind(card) == "playing_card" then
        return (area or copied_from) and "permanent_deck" or nil
    end
    return (area or copied_from) and "owned" or nil
end

local function enhancement_state(card)
    local center = card and card.config and card.config.center
    return center and center.set == "Enhanced" and center.key or "none"
end

local function edition_state(card)
    local edition = card and card.edition
    if type(edition) ~= "table" then
        return "none"
    end
    for _, value in ipairs({ "negative", "polychrome", "holo", "foil" }) do
        if edition.type == value or edition[value] then
            return "e_" .. value
        end
    end
    return "none"
end

local function seal_state(card)
    return card and card.seal or "none"
end

local function card_state_snapshot(card)
    return {
        rank = card and card.base and card.base.value,
        suit = card and card.base and card.base.suit,
        enhancement = enhancement_state(card),
        edition = edition_state(card),
        seal = seal_state(card),
        facedown = card and card.facing == "back" or false,
        debuffed = not not (card and card.debuff),
        forced_selection = not not (card and card.ability and card.ability.forced_selection),
    }
end

local function add_public_card_features(effect, card)
    if created_kind(card) == "playing_card" then
        effect.rank = card and card.base and card.base.value or nil
        effect.suit = card and card.base and card.base.suit or nil
        local enhancement = enhancement_state(card)
        if enhancement ~= "none" then
            effect.enhancement = enhancement
        end
        local seal = seal_state(card)
        if seal ~= "none" then
            effect.seal = seal
        end
    end
    local edition = edition_state(card)
    if edition ~= "none" then
        effect.edition = edition
    end
    return effect
end

function ProductionBalatroAdapter:_with_suppressed_card_state(callback, ...)
    local context = self:_capture()
    if not context then
        return callback(...)
    end
    context.suppress_card_state = context.suppress_card_state + 1
    local results = { pcall(callback, ...) }
    context.suppress_card_state = context.suppress_card_state - 1
    if not results[1] then
        error(results[2])
    end
    return unpack(results, 2)
end

local function is_run_start_playing_card(card)
    for _, playing_card in ipairs(G and G.playing_cards or {}) do
        if playing_card == card then
            return true
        end
    end
    return false
end

function ProductionBalatroAdapter:_record_card_state(card, state, value)
    local context = self:_capture()
    local event = self:_current_resolution_event()
    if not context or context.suppress_card_state > 0 or not event then
        return
    end
    local input_target_id = context.input_objects[card]
    local anonymous_blind_state = (event.type == "apply" and event.component == "blind")
        or context.blind_effect_depth > 0
    anonymous_blind_state = anonymous_blind_state
        and (state == "facedown" or state == "debuffed" or state == "forced_selection")
    local created_record = not input_target_id and context.created_records[card]
    if created_record then
        local created_output = created_record.effect
        if
            state == "rank"
            or state == "suit"
            or state == "enhancement"
            or state == "edition"
            or state == "seal"
        then
            created_output[state] = value == "none" and nil or value
            return
        end
        if not anonymous_blind_state then
            self:_mark_resolution_invalid(
                "value.resolution.effects.create",
                "Created object state cannot be encoded",
                tostring(card)
            )
            return
        end
    end
    if
        not input_target_id
        and event.type == "apply"
        and event.component == "tag"
        and state == "edition"
        and G
        and card.area == G.shop_jokers
    then
        self:_record_created(card, card.area)
        return
    end
    if
        not input_target_id
        and not anonymous_blind_state
        and not (
            event.type == "apply"
            and event.component == "back"
            and event.phase == "run_start"
            and is_run_start_playing_card(card)
        )
    then
        self:_mark_resolution_invalid(
            "value.resolution.effects.input_target_id",
            "Changed card is not an action input",
            tostring(card)
        )
        return
    end
    local effect = self:_append_effect({
        kind = "set_card_state",
        input_target_id = input_target_id,
        state = state,
        value = value,
    })
    if effect then
        context.card_state_records[#context.card_state_records + 1] = {
            order = effect.order,
            card = card,
            state = state,
        }
    end
end

local function card_state_recorded_since(context, order, card, state)
    for _, record in ipairs(context and context.card_state_records or {}) do
        if record.order > order and record.card == card and record.state == state then
            return true
        end
    end
    return false
end

function ProductionBalatroAdapter:_record_card_changes(card, before, fields, since_order)
    local context = self:_capture()
    local after = card_state_snapshot(card)
    for _, field in ipairs(fields) do
        if
            before[field] ~= after[field]
            and not (since_order and card_state_recorded_since(context, since_order, card, field))
        then
            self:_record_card_state(card, field, after[field])
        end
    end
end

function ProductionBalatroAdapter:_record_capacity(resource, amount, value)
    if amount ~= 0 and self:_current_resolution_event() then
        self:_append_effect({
            kind = "capacity",
            resource = resource,
            amount = amount,
            value = value,
        })
    end
end

function ProductionBalatroAdapter:_record_copy(source, destination, copied)
    local context = self:_capture()
    local event = self:_current_resolution_event()
    if
        not context
        or not event
        or (
            event.component == "voucher"
            and source
            and source.ability
            and source.ability.set == "Voucher"
        )
    then
        return
    end
    local source_input_target_id = context.input_objects[source]
    if not source_input_target_id then
        self:_mark_resolution_invalid(
            "value.resolution.effects.copy.source.input_target_id",
            "Copied source is not an action input",
            tostring(source)
        )
        return
    end
    if type(destination) == "table" then
        local destination_input_target_id = context.input_objects[destination]
        if not destination_input_target_id then
            self:_mark_resolution_invalid(
                "value.resolution.effects.copy.destination.input_target_id",
                "Copy destination is not an action input",
                tostring(destination)
            )
            return
        end
        self:_append_effect({
            kind = "copy",
            mode = "overwrite",
            source = { input_target_id = source_input_target_id },
            destination = { input_target_id = destination_input_target_id },
        })
        return
    end
    if type(copied) ~= "table" then
        self:_mark_resolution_invalid(
            "value.resolution.effects.copy",
            "Created copy is unavailable",
            tostring(copied)
        )
        return
    end
    if context.visibility ~= "omniscient" and copied.facing == "back" then
        self:_mark_resolution_invalid(
            "value.resolution.effects.copy",
            "Created copy identity is not visible",
            tostring(copied)
        )
        return
    end
    local copy_effect = add_public_card_features({
        kind = "copy",
        mode = "create",
        source = { input_target_id = source_input_target_id },
        object_kind = created_kind(copied),
        destination = created_destination(copied, nil, source),
        key = created_key(copied),
    }, copied)
    if not copy_effect.destination then
        self:_mark_resolution_invalid(
            "value.resolution.effects.copy.destination",
            "Created copy destination is not visible",
            tostring(copied)
        )
        return
    end
    context.created_records[copied] = {
        effect = self:_append_effect(copy_effect),
        parent = event,
    }
end

function ProductionBalatroAdapter:_record_destroy(card)
    local context = self:_capture()
    if
        type(card) ~= "table"
        or not context
        or context.mechanic_objects[card]
        or not self:_current_resolution_event()
    then
        return
    end
    if context.destroyed_cards[card] then
        return
    end
    local input_target_id = context.input_objects[card]
    if not input_target_id then
        self:_mark_resolution_invalid(
            "value.resolution.effects.input_target_id",
            "Destroyed object is not an action input",
            tostring(card)
        )
        return
    end
    context.destroyed_cards[card] = true
    self:_append_effect({ kind = "destroy", input_target_id = input_target_id })
end

function ProductionBalatroAdapter:_record_created(card, area, copied_from)
    local context = self:_capture()
    if
        type(card) ~= "table"
        or not context
        or not self:_current_resolution_event()
        or context.input_objects[card]
        or context.created_records[card]
        or (area ~= nil and G and area == G.pack_cards)
    then
        return
    end
    local visible_area = area ~= nil
        and G
        and (
            area == G.hand
            or area == G.play
            or area == G.jokers
            or area == G.consumeables
            or area == G.pack_cards
            or area == G.shop_jokers
            or area == G.shop_vouchers
            or area == G.shop_booster
        )
    local visible_copy = copied_from and self:_source_ref(copied_from)
    if
        context.visibility ~= "omniscient"
        and (card.facing == "back" or (not visible_area and not visible_copy))
    then
        local event = self:_current_resolution_event()
        if
            event
            and event.type == "apply"
            and (
                event.component == "voucher"
                or event.component == "back"
                or event.component == "tag"
            )
        then
            return
        end
        self:_mark_resolution_invalid(
            "value.resolution.effects.create",
            "Created object identity is not visible",
            tostring(card)
        )
        return
    end
    local destination = created_destination(card, area, copied_from)
    if not destination then
        self:_mark_resolution_invalid(
            "value.resolution.effects.create.destination",
            "Created object destination is not visible",
            tostring(card)
        )
        return
    end
    context.created_records[card] = {
        effect = self:_append_effect(add_public_card_features({
            kind = "create",
            object_kind = created_kind(card),
            destination = destination,
            key = created_key(card),
        }, card)),
        parent = self:_current_resolution_event(),
    }
end

function ProductionBalatroAdapter:_record_cash_out(payout)
    local context = self:_capture()
    if not context then
        return
    end
    local parent = self:_current_resolution_event()
    local event = self:_new_resolution_event({
        phase = "end_of_round",
        type = "cash_out",
        parent_order = parent and parent.order or nil,
    })
    local scope = { kind = "cash_out", phase = "end_of_round", event = event }
    self:_push_resolution_scope(scope)
    local amount = payout - context.cash_out_content_dollars
    if amount ~= 0 then
        self:_append_effect({
            kind = "dollars",
            amount = amount,
            money = self.cash_out_expected_money or (G.GAME and G.GAME.dollars or 0),
        })
    end
    self:_pop_resolution_scope(scope)
end

local unencoded_effect_keys = {
    balance = true,
    blind_size = true,
    blindsize = true,
    debuff = true,
    h_blind_size = true,
    h_blindsize = true,
    h_score = true,
    h_x_score = true,
    h_xscore = true,
    level_up = true,
    score = true,
    swap = true,
    x_blind_size = true,
    x_blindsize = true,
    x_score = true,
    xblind_size = true,
    xblindsize = true,
    xscore = true,
}

function ProductionBalatroAdapter:_record_atomic_effect(key, amount)
    if amount == nil then
        return
    end
    local kind = scoring_kinds[key] or money_kinds[key]
    if not kind then
        if unencoded_effect_keys[key] and self:_current_resolution_event() then
            self:_mark_resolution_invalid(
                "value.resolution.effects",
                "Known vanilla effect cannot be encoded: " .. tostring(key)
            )
        end
        return
    end
    if kind == "x_mult" and amount == 1 then
        return
    end
    local effect = { kind = kind, amount = amount }
    if money_kinds[key] then
        effect.money = G.GAME and G.GAME.dollars or 0
    else
        local chips = tonumber(rawget(_G, "hand_chips")) or 0
        local current_mult = tonumber(rawget(_G, "mult")) or 0
        effect.chips = chips
        effect.mult = current_mult
        effect.score = math.floor(chips * current_mult)
    end
    self:_append_effect(effect)
end

function ProductionBalatroAdapter:_record_debuff_blocked(card)
    local context = self:_capture()
    if not context then
        return
    end
    local source = self:_source_ref(card)
    if not source then
        self:_mark_resolution_invalid(
            "value.resolution.source",
            "Debuffed object is not an action input",
            tostring(card)
        )
        return
    end
    local game_context = current_calculation_context()
    local scope = self:_current_scope()
    local parent = self:_current_resolution_event()
    self:_new_resolution_event({
        phase = game_context and context_phase(game_context)
            or scope and scope.phase
            or "playing_card",
        type = "debuff_blocked",
        component = "playing_card",
        source = source,
        parent_order = parent and rawget(parent, "order") or nil,
    })
end

local application_components = {
    Back = "back",
    Blind = "blind",
    Booster = "booster",
    Joker = "joker",
    Planet = "planet",
    Spectral = "spectral",
    Tag = "tag",
    Tarot = "tarot",
    Voucher = "voucher",
}
local application_component_values = {}
for _, component in pairs(application_components) do
    application_component_values[component] = true
end

local static_application_rules = {
    voucher = {
        v_telescope = {
            { rule = "celestial_pack_planet", enabled = true },
        },
        v_omen_globe = {
            { rule = "arcana_pack_spectral", enabled = true },
        },
        v_observatory = {
            { rule = "held_planet_x_mult", amount = 0.5, value = 1.5 },
        },
        v_illusion = {
            { rule = "enhanced_shop_playing_cards", enabled = true },
        },
        v_directors_cut = {
            { rule = "boss_reroll_once_per_ante", enabled = true },
            { rule = "boss_reroll_cost", value = 10 },
        },
        v_retcon = {
            { rule = "unlimited_boss_rerolls", enabled = true },
            { rule = "boss_reroll_cost", value = 10 },
        },
    },
    back = {
        b_anaglyph = {
            { rule = "boss_defeat_double_tag", enabled = true },
        },
        b_plasma = {
            { rule = "balanced_scoring", enabled = true },
        },
    },
}

function ProductionBalatroAdapter:_record_static_application_rules(component, key)
    for _, rule in
        ipairs(
            static_application_rules[component] and static_application_rules[component][key] or {}
        )
    do
        self:_append_effect({
            kind = "run_rule",
            rule = rule.rule,
            amount = rule.amount,
            value = rule.value,
            enabled = rule.enabled,
        })
    end
end

local function application_phase(component, context)
    local root_scope = context.scope_stack[1]
    local phase = root_scope and root_scope.phase or "hand"
    if
        component == "blind"
        and phase == "blind_selection"
        and G
        and G.STATES
        and G.STATE ~= G.STATES.BLIND_SELECT
    then
        return "hand"
    end
    return phase
end

function ProductionBalatroAdapter:_with_prototype_application(
    component,
    key,
    source_object,
    source_required,
    callback,
    ...
)
    local context = self:_capture()
    if not context then
        return callback(...)
    end
    if not application_component_values[component] then
        self:_mark_resolution_invalid(
            "value.resolution.apply.component",
            "Vanilla application component cannot be encoded",
            tostring(component)
        )
        return callback(...)
    end
    if type(key) ~= "string" then
        self:_mark_resolution_invalid(
            "value.resolution.apply.key",
            "Vanilla application key cannot be encoded",
            tostring(key)
        )
        return callback(...)
    end
    local parent = self:_current_resolution_event()
    local source = self:_source_ref(source_object)
    if source_required and not source then
        self:_mark_resolution_invalid(
            "value.resolution.source",
            "Application source is not an input object",
            tostring(source_object)
        )
    end
    local event = assert(self:_new_resolution_event({
        phase = application_phase(component, context),
        type = "apply",
        component = component,
        key = key,
        source = source,
        parent_order = parent and parent.order or nil,
    }))
    local previous_application_event = context.latest_application_event
    context.application_depth = context.application_depth + 1
    context.latest_application_event = event
    local scope = { kind = "apply", phase = event.phase, event = event }
    local results = {
        pcall(self._with_resolution_scope, self, scope, function(...)
            self:_record_static_application_rules(component, key)
            return callback(...)
        end, ...),
    }
    context.application_depth = context.application_depth - 1
    context.latest_application_event = context.application_depth > 0 and previous_application_event
        or event
    if not results[1] then
        error(results[2])
    end
    return unpack(results, 2)
end

function ProductionBalatroAdapter:_with_application(card, callback, ...)
    local center = card and card.config and card.config.center
    local set = card and card.ability and card.ability.set or center and center.set
    local component = application_components[set]
    local key = center and center.key or card and card.config and card.config.card_key
    return self:_with_prototype_application(component, key, card, true, callback, ...)
end

local function blind_prototype(blind)
    return blind and blind.config and blind.config.blind
end

function ProductionBalatroAdapter:_with_blind_prototype_application(prototype, callback, ...)
    local context = self:_capture()
    local key = prototype and prototype.key
    if not context or not key then
        return callback(...)
    end
    local event = self:_current_resolution_event()
    local phase = application_phase("blind", context)
    if
        context.blind_effect_depth > 0
        or (event and event.component == "blind" and event.key == key and event.phase == phase)
    then
        return callback(...)
    end

    local suppressed = context.suppress_card_state
    local pending = context.card_change_stack[#context.card_change_stack]
    if suppressed > 0 and pending then
        context.suppress_card_state = 0
        self:_record_card_changes(pending.card, pending.before, pending.fields, pending.since_order)
    end
    context.suppress_card_state = 0
    local results = {
        pcall(self._with_prototype_application, self, "blind", key, prototype, true, callback, ...),
    }
    context.suppress_card_state = suppressed
    if not results[1] then
        error(results[2])
    end
    return unpack(results, 2)
end

function ProductionBalatroAdapter:_with_blind_application(blind, callback, ...)
    return self:_with_blind_prototype_application(blind_prototype(blind), callback, ...)
end

local function resolution_zone(area)
    return G and area == G.deck and "deck"
        or G and area == G.hand and "hand"
        or G and area == G.play and "play"
        or G and area == G.discard and "discard"
end

local function area_contains(area, card)
    if card and card.area == area then
        return true
    end
    for _, current in ipairs(area and area.cards or {}) do
        if current == card then
            return true
        end
    end
    return false
end

function ProductionBalatroAdapter:_record_blind_hand_restriction(key, blind, before)
    local after = active_hand_debuff(key, blind)
    if after and not same_hand_debuff(before, after) then
        self:_append_effect({
            kind = "blind_change",
            operation = "hand_restriction",
            hand_debuff = after,
        })
    end
end

function ProductionBalatroAdapter:_record_hand_debuff_blocked(blind)
    local context = self:_capture()
    local parent = self:_current_resolution_event()
    local prototype = blind_prototype(blind)
    local source = self:_source_ref(prototype)
    if not context or not parent or not source then
        self:_mark_resolution_invalid(
            "value.resolution.source",
            "Debuffing Blind is not an action input",
            tostring(prototype)
        )
        return
    end
    context.pending_hand_debuff_event = self:_new_resolution_event({
        phase = "debuffed_hand",
        type = "debuff_blocked",
        component = "blind",
        source = source,
        parent_order = parent.order,
    })
end

function ProductionBalatroAdapter:_record_move_card(card, from, to)
    local context = self:_capture()
    local event = self:_current_resolution_event()
    if not context or not event then
        return
    end
    local input_target_id = context.input_objects[card]
    local from_zone = resolution_zone(from)
    local to_zone = resolution_zone(to)
    if not input_target_id or not from_zone or not to_zone then
        self:_mark_resolution_invalid(
            "value.resolution.effects.move_card",
            "Forced card move cannot be encoded",
            tostring(card)
        )
        return
    end
    self:_append_effect({
        kind = "move_card",
        input_target_id = input_target_id,
        from_zone = from_zone,
        to_zone = to_zone,
    })
end

local function wrap_smods(name, wrapper)
    local previous = SMODS[name]
    if type(previous) ~= "function" then
        return
    end
    rawset(SMODS, name, wrapper(previous))
end

local wrapped_globals = {}
local wrapped_event_managers = setmetatable({}, { __mode = "k" })
local function wrap_global(name, after)
    local current = rawget(_G, name)
    if type(current) ~= "function" or wrapped_globals[current] then
        return
    end
    local wrapped = function(...)
        local results = { current(...) }
        after(results, ...)
        return unpack(results)
    end
    wrapped_globals[current] = true
    wrapped_globals[wrapped] = true
    rawset(_G, name, wrapped)
end

local function wrap_global_around(name, wrapper)
    local current = rawget(_G, name)
    if type(current) ~= "function" or wrapped_globals[current] then
        return
    end
    local wrapped = wrapper(current)
    wrapped_globals[current] = true
    wrapped_globals[wrapped] = true
    rawset(_G, name, wrapped)
end

local resolution_event_scope_key = "__balatro_mcp_resolution_scope_7b1021"

local function bind_resolution_event_scope(event, token)
    if
        not token
        or type(event) ~= "table"
        or type(event.func) ~= "function"
        or event[resolution_event_scope_key]
    then
        return
    end
    event[resolution_event_scope_key] = token
    local callback = event.func
    event.func = function(...)
        local active = resolution_adapter
        if active and token.capture.active and active.resolution_capture == token.capture then
            return active:_with_resolution_scope({
                kind = token.kind,
                phase = token.phase,
                event = token.event,
                progress_card = token.progress_card,
            }, callback, ...)
        end
        return callback(...)
    end
end

function ProductionBalatroAdapter:_ensure_event_scope_hook()
    local manager = G and G.E_MANAGER
    if type(manager) ~= "table" or type(manager.add_event) ~= "function" then
        return
    end
    if wrapped_event_managers[manager] == manager.add_event then
        return
    end
    ---@type fun(...): any
    local previous = manager.add_event
    local wrapped = function(event_manager, event, ...)
        local adapter = resolution_adapter
        bind_resolution_event_scope(event, adapter and adapter:_resolution_scope_token())
        return previous(event_manager, event, ...)
    end
    manager.add_event = wrapped
    wrapped_event_managers[manager] = wrapped
end

function ProductionBalatroAdapter:_ensure_resolution_hooks()
    resolution_adapter = self
    self:_ensure_event_scope_hook()

    local function scoped_event(callback)
        local event = { trigger = "immediate", func = callback }
        local event_factory = rawget(_G, "Event")
        local metatable = type(event_factory) == "table" and getmetatable(event_factory)
        if
            type(event_factory) == "function"
            or (metatable and type(metatable.__call) == "function")
        then
            return event_factory(event)
        end
        return event
    end

    local function wrap_created_global(name)
        wrap_global_around(name, function(previous)
            return function(card_init, area, ...)
                local adapter = resolution_adapter
                local results = adapter
                        and {
                            adapter:_with_suppressed_card_state(previous, card_init, area, ...),
                        }
                    or { previous(card_init, area, ...) }
                if adapter then
                    adapter:_record_created(results[1], area)
                end
                return unpack(results)
            end
        end)
    end
    wrap_created_global("create_card")
    wrap_created_global("create_playing_card")
    wrap_global("create_shop_card_ui", function(_results, card, _set, area)
        local adapter = resolution_adapter
        if adapter and created_kind(card) == "voucher" then
            adapter:_record_created(card, area)
        end
    end)

    local function tag_count(key)
        local count = 0
        for _, tag in ipairs(G and G.GAME and G.GAME.tags or {}) do
            if tag.key == key then
                count = count + 1
            end
        end
        return count
    end

    wrap_global_around("add_tag", function(previous)
        return function(tag, ...)
            local adapter = resolution_adapter
            local key = type(tag) == "table" and tag.key or nil
            local before = key and tag_count(key) or 0
            local recorded = false
            local function record()
                if recorded or not adapter or not adapter:_current_resolution_event() then
                    return
                end
                local quantity = key and tag_count(key) - before or 0
                if quantity > 0 then
                    recorded = true
                    adapter:_append_effect({
                        kind = "tag_change",
                        operation = "add",
                        key = key,
                        quantity = quantity,
                    })
                end
            end

            local smods = rawget(_G, "SMODS")
            local calculate_context = type(smods) == "table" and smods.calculate_context
            local intercepted
            if key and type(calculate_context) == "function" then
                intercepted = function(context, ...)
                    if type(context) == "table" and context.tag_added == tag then
                        record()
                    end
                    return calculate_context(context, ...)
                end
                smods.calculate_context = intercepted
            end
            local results = { pcall(previous, tag, ...) }
            if intercepted and smods.calculate_context == intercepted then
                smods.calculate_context = calculate_context
            end
            if not results[1] then
                error(results[2])
            end
            record()
            return unpack(results, 2)
        end
    end)
    wrap_global_around("get_new_boss", function(previous)
        return function(...)
            local adapter = resolution_adapter
            local previous_key = G
                and G.GAME
                and G.GAME.round_resets
                and G.GAME.round_resets.blind_choices
                and G.GAME.round_resets.blind_choices.Boss
            local results = { previous(...) }
            local key = results[1]
            local event = adapter and adapter:_current_resolution_event()
            if
                event
                and event.type == "apply"
                and event.component == "tag"
                and event.key == "tag_boss"
                and type(previous_key) == "string"
                and type(key) == "string"
                and previous_key ~= key
            then
                adapter:_append_effect({
                    kind = "blind_change",
                    operation = "replace",
                    previous_key = previous_key,
                    key = key,
                })
            end
            return unpack(results)
        end
    end)
    wrap_global_around("draw_card", function(previous)
        return function(from, to, percent, direction, sort, card, ...)
            local adapter = resolution_adapter
            local context = adapter and adapter:_capture()
            local event = adapter and adapter:_current_resolution_event()
            local manager = G and G.E_MANAGER
            local hook_move = context
                and event
                and event.component == "blind"
                and event.key == "bl_hook"
                and type(card) == "table"
            if not hook_move then
                if
                    context
                    and event
                    and (event.component == "blind" or context.blind_effect_depth > 0)
                then
                    return adapter:_with_resolution_scope({
                        kind = "action_mechanics",
                        phase = event.phase,
                    }, previous, from, to, percent, direction, sort, card, ...)
                end
                return previous(from, to, percent, direction, sort, card, ...)
            end
            if type(manager) ~= "table" or type(manager.add_event) ~= "function" then
                return previous(from, to, percent, direction, sort, card, ...)
            end

            local add_event = manager.add_event
            local instrumented = false
            local intercept
            intercept = function(event_manager, queued_event, ...)
                if
                    not instrumented
                    and type(queued_event) == "table"
                    and type(queued_event.func) == "function"
                then
                    instrumented = true
                    local callback = queued_event.func
                    local recorded = false
                    queued_event.func = function(...)
                        local results = { pcall(callback, ...) }
                        local active = resolution_adapter
                        if
                            results[1]
                            and not recorded
                            and active
                            and active:_capture() == context
                            and active:_current_resolution_event()
                            and area_contains(to, card)
                        then
                            recorded = true
                            active:_record_move_card(card, from, to)
                        end
                        if not results[1] then
                            error(results[2])
                        end
                        return unpack(results, 2)
                    end
                end
                return add_event(event_manager, queued_event, ...)
            end
            manager.add_event = intercept
            local results = { pcall(previous, from, to, percent, direction, sort, card, ...) }
            if manager.add_event == intercept then
                manager.add_event = add_event
            end
            if not results[1] then
                error(results[2])
            end
            return unpack(results, 2)
        end
    end)
    local draw_from_deck_to_hand = G and G.FUNCS and G.FUNCS.draw_from_deck_to_hand
    if
        type(draw_from_deck_to_hand) == "function"
        and not wrapped_globals[draw_from_deck_to_hand]
    then
        local wrapped = function(...)
            local adapter = resolution_adapter
            local context = adapter and adapter:_capture()
            local blind = G and G.GAME and G.GAME.blind
            local prototype = blind_prototype(blind)
            local current_round = G and G.GAME and G.GAME.current_round or {}
            local active = prototype
                and prototype.key == "bl_serpent"
                and not blind.disabled
                and (
                    (current_round.hands_played or 0) > 0
                    or (current_round.discards_used or 0) > 0
                )
            if not context or not active or context.serpent_draw_rule_recorded then
                return draw_from_deck_to_hand(...)
            end
            context.serpent_draw_rule_recorded = true
            adapter:_with_blind_application(blind, function()
                adapter:_append_effect({
                    kind = "blind_change",
                    operation = "draw_rule",
                    cards_per_draw = 3,
                })
            end)
            return draw_from_deck_to_hand(...)
        end
        wrapped_globals[draw_from_deck_to_hand] = true
        wrapped_globals[wrapped] = true
        G.FUNCS.draw_from_deck_to_hand = wrapped
    end
    wrap_global_around("copy_card", function(previous)
        return function(other, new_card, ...)
            local adapter = resolution_adapter
            local results = adapter
                    and {
                        adapter:_with_suppressed_card_state(previous, other, new_card, ...),
                    }
                or { previous(other, new_card, ...) }
            if adapter then
                adapter:_record_copy(other, new_card, results[1])
            end
            return unpack(results)
        end
    end)
    wrap_global_around("ease_dollars", function(previous)
        return function(amount, instant, ...)
            local adapter = resolution_adapter
            local before = G and G.GAME and G.GAME.dollars
            local results = { previous(amount, instant, ...) }
            if
                not adapter
                or not adapter:_current_resolution_event()
                or type(before) ~= "number"
                or tonumber(amount) == 0
            then
                return unpack(results)
            end
            local after = G and G.GAME and G.GAME.dollars
            if type(after) == "number" and after ~= before then
                adapter:_append_effect({ kind = "dollars", amount = after - before, money = after })
            elseif G and G.E_MANAGER and type(G.E_MANAGER.add_event) == "function" then
                G.E_MANAGER:add_event(scoped_event(function()
                    local active = resolution_adapter
                    local money = G and G.GAME and G.GAME.dollars
                    if active and type(money) == "number" then
                        active:_append_effect({ kind = "dollars", amount = amount, money = money })
                    end
                    return true
                end))
            else
                adapter:_mark_resolution_invalid(
                    "value.resolution.effects.dollars",
                    "Deferred dollars application cannot be observed"
                )
            end
            return unpack(results)
        end
    end)
    local function allowance_value(resource)
        local current_round = G and G.GAME and G.GAME.current_round
        return current_round
            and tonumber(
                resource == "hands" and current_round.hands_left or current_round.discards_left
            )
    end

    local function wrap_allowance(name, resource)
        wrap_global_around(name, function(previous)
            return function(...)
                local adapter = resolution_adapter
                local context = adapter and adapter:_capture()
                local event = adapter and adapter:_current_resolution_event()
                local before = event and allowance_value(resource)
                local since_order = context and context.next_order or 0
                local results = { previous(...) }
                if type(before) ~= "number" then
                    return unpack(results)
                end
                local function record()
                    local active = resolution_adapter
                    local active_context = active and active:_capture()
                    local current = allowance_value(resource)
                    local base = G
                        and G.GAME
                        and G.GAME.round_resets
                        and tonumber(G.GAME.round_resets[resource])
                    if
                        active
                        and active_context
                        and active:_current_resolution_event()
                        and type(current) == "number"
                        and type(base) == "number"
                        and current ~= before
                        and not effect_recorded_since(
                            active_context,
                            since_order,
                            "round_allowance",
                            "resource",
                            resource
                        )
                    then
                        active:_append_effect({
                            kind = "round_allowance",
                            resource = resource,
                            amount = current - before,
                            base = base,
                            current = current,
                        })
                    end
                    return true
                end
                if allowance_value(resource) ~= before then
                    record()
                elseif G and G.E_MANAGER and type(G.E_MANAGER.add_event) == "function" then
                    G.E_MANAGER:add_event(scoped_event(record))
                else
                    adapter:_mark_resolution_invalid(
                        "value.resolution.effects.round_allowance",
                        "Deferred round allowance application cannot be observed"
                    )
                end
                return unpack(results)
            end
        end)
    end
    wrap_allowance("ease_discard", "discards")
    wrap_allowance("ease_hands_played", "hands")

    wrap_global_around("level_up_hand", function(previous)
        return function(card, hand, ...)
            local adapter = resolution_adapter
            local before = G and G.GAME and G.GAME.hands and G.GAME.hands[hand]
            local previous_level = before and before.level
            local results = { previous(card, hand, ...) }
            local value = G and G.GAME and G.GAME.hands and G.GAME.hands[hand]
            if
                adapter
                and adapter:_current_resolution_event()
                and value
                and type(previous_level) == "number"
            then
                adapter:_append_effect({
                    kind = "poker_hand_level",
                    poker_hand = hand,
                    amount = value.level - previous_level,
                    level = value.level,
                    chips = value.chips,
                    mult = value.mult,
                })
            end
            return unpack(results)
        end
    end)

    local function wrap_card_method(name, wrapper)
        local class = rawget(_G, "Card")
        if type(class) ~= "table" then
            return
        end
        local current = class[name]
        if type(current) ~= "function" or wrapped_globals[current] then
            return
        end
        local wrapped = wrapper(current)
        wrapped_globals[current] = true
        wrapped_globals[wrapped] = true
        class[name] = wrapped
    end

    wrap_card_method("calculate_seal", function(previous)
        return function(card, game_context, ...)
            local adapter = resolution_adapter
            if
                not adapter
                or not adapter:_capture()
                or not (game_context and game_context.discard)
            then
                return previous(card, game_context, ...)
            end
            local event = adapter:_open_component("seals", {}, card, game_context)
            local results = { pcall(previous, card, game_context, ...) }
            adapter:_close_component(event)
            if not results[1] then
                error(results[2])
            end
            return unpack(results, 2)
        end
    end)

    wrap_card_method("calculate_joker", function(previous)
        return function(card, game_context, ...)
            local adapter = resolution_adapter
            if not adapter or not adapter:_capture() or not lifecycle_joker_phase(game_context) then
                return previous(card, game_context, ...)
            end
            local source_card = game_context.blueprint_card or card
            local event =
                adapter:_open_component("jokers", { card = source_card }, card, game_context)
            if not game_context.blueprint then
                adapter:_record_card_progress(card)
            end
            local results = { pcall(previous, card, game_context, ...) }
            if not game_context.blueprint then
                adapter:_record_card_progress(card)
            end
            adapter:_close_component(event)
            if not results[1] then
                error(results[2])
            end
            return unpack(results, 2)
        end
    end)

    local function card_slot_limits()
        return G and G.jokers and G.jokers.config.card_limit,
            G and G.consumeables and G.consumeables.config.card_limit
    end

    local function record_card_slot_changes(adapter, joker_limit, consumable_limit)
        local next_joker_limit, next_consumable_limit = card_slot_limits()
        if type(joker_limit) == "number" and type(next_joker_limit) == "number" then
            adapter:_record_capacity(
                "joker_slots",
                next_joker_limit - joker_limit,
                next_joker_limit
            )
        end
        if type(consumable_limit) == "number" and type(next_consumable_limit) == "number" then
            adapter:_record_capacity(
                "consumable_slots",
                next_consumable_limit - consumable_limit,
                next_consumable_limit
            )
        end
    end

    local function wrap_card_state_method(name, fields, capacity_before_state)
        wrap_card_method(name, function(previous)
            return function(card, ...)
                local adapter = resolution_adapter
                local context = adapter and adapter:_capture()
                local suppressed = context and context.suppress_card_state > 0
                local before = card_state_snapshot(card)
                local since_order = context and context.next_order or 0
                local joker_limit, consumable_limit = card_slot_limits()
                local pending
                if context then
                    pending = {
                        card = card,
                        before = before,
                        fields = fields,
                        since_order = since_order,
                    }
                    context.card_change_stack[#context.card_change_stack + 1] = pending
                    context.suppress_card_state = context.suppress_card_state + 1
                end
                local results = { pcall(previous, card, ...) }
                if context then
                    assert(context.card_change_stack[#context.card_change_stack] == pending)
                    context.card_change_stack[#context.card_change_stack] = nil
                    context.suppress_card_state = context.suppress_card_state - 1
                end
                if not results[1] then
                    error(results[2])
                end
                if adapter and not suppressed then
                    if capacity_before_state then
                        record_card_slot_changes(adapter, joker_limit, consumable_limit)
                    end
                    adapter:_record_card_changes(card, before, fields, since_order)
                end
                return unpack(results, 2)
            end
        end)
    end

    wrap_card_method("open", function(previous)
        return function(card, ...)
            local adapter = resolution_adapter
            local event = adapter and adapter:_current_resolution_event()
            local should_record = event
                and event.type == "apply"
                and event.component == "tag"
                and vanilla_auto_booster_tags[event.key]
            local results = { previous(card, ...) }
            if should_record then
                local category = pack_category_from_booster(card)
                local size = booster_size(card)
                local choices = tonumber(G and G.GAME and G.GAME.pack_choices)
                if
                    category
                    and size
                    and choices
                    and size == math.floor(size)
                    and choices == math.floor(choices)
                    and choices > 0
                then
                    adapter:_append_effect({
                        kind = "open_booster",
                        category = category,
                        size = size,
                        choices = choices,
                    })
                else
                    adapter:_mark_resolution_invalid(
                        "value.resolution.effects.open_booster",
                        "Opened vanilla Booster cannot be encoded"
                    )
                end
            end
            return unpack(results)
        end
    end)

    wrap_card_method("flip", function(previous)
        return function(card, ...)
            local adapter = resolution_adapter
            local context = adapter and adapter:_capture()
            local event = adapter and adapter:_current_resolution_event()
            local before = event
                and (event.component == "blind" or context.blind_effect_depth > 0)
                and card_state_snapshot(card)
            local results = { previous(card, ...) }
            if before then
                adapter:_record_card_changes(card, before, { "facedown" })
            end
            return unpack(results)
        end
    end)
    wrap_card_state_method("set_base", { "rank", "suit", "debuffed" })
    wrap_card_state_method("set_ability", { "enhancement", "debuffed", "forced_selection" })
    wrap_card_state_method("set_edition", { "edition" }, true)
    wrap_card_state_method("set_seal", { "seal" })
    wrap_card_state_method("set_debuff", { "debuffed" })
    for _, name in ipairs({ "add_to_deck", "remove_from_deck" }) do
        wrap_card_method(name, function(previous)
            return function(card, ...)
                local adapter = resolution_adapter
                local joker_limit, consumable_limit = card_slot_limits()
                local results = { previous(card, ...) }
                if adapter then
                    record_card_slot_changes(adapter, joker_limit, consumable_limit)
                end
                return unpack(results)
            end
        end)
    end
    wrap_card_method("apply_to_run", function(previous)
        return function(card, center, ...)
            local adapter = resolution_adapter
            local context = adapter and adapter:_capture()
            if not context then
                return previous(card, center, ...)
            end
            local prototype = center or card and card.config and card.config.center
            local before = run_mutation_snapshot()
            local since_order = context.next_order
            local application_event
            local function apply(...)
                application_event = context.latest_application_event
                local manager = G and G.E_MANAGER
                local previous_add = manager and manager.add_event
                if type(previous_add) == "function" then
                    manager.add_event = function(event_manager, event, ...)
                        bind_resolution_event_scope(event, {
                            capture = context,
                            kind = "apply",
                            phase = application_event.phase,
                            event = application_event,
                        })
                        return previous_add(event_manager, event, ...)
                    end
                end
                local results = { pcall(previous, ...) }
                if manager then
                    manager.add_event = previous_add
                end
                if not results[1] then
                    error(results[2])
                end
                return unpack(results, 2)
            end
            local results = {
                adapter:_with_prototype_application(
                    "voucher",
                    prototype and prototype.key,
                    card,
                    card ~= nil,
                    apply,
                    card,
                    center,
                    ...
                ),
            }
            if
                application_event
                and G
                and G.E_MANAGER
                and type(G.E_MANAGER.add_event) == "function"
            then
                G.E_MANAGER:add_event(scoped_event(function()
                    local active = resolution_adapter
                    if active and active:_capture() == context then
                        active:_with_resolution_scope({
                            kind = "apply",
                            phase = application_event.phase,
                            event = application_event,
                        }, function()
                            active:_record_application_mutations(before, since_order, true)
                        end)
                    end
                    return true
                end))
            end
            return unpack(results)
        end
    end)
    wrap_card_method("use_consumeable", function(previous)
        return function(card, ...)
            local adapter = resolution_adapter
            local context = adapter and adapter:_capture()
            if not context then
                return previous(card, ...)
            end
            context.latest_application_event = nil
            local results = { pcall(adapter._with_application, adapter, card, previous, card, ...) }
            context.pending_consumable_application = context.latest_application_event
            if not results[1] then
                error(results[2])
            end
            return unpack(results, 2)
        end
    end)
    local function destroy_wrapper(previous)
        return function(card, ...)
            local adapter = resolution_adapter
            if adapter then
                adapter:_record_scope_card_progress()
                adapter:_record_destroy(card)
            end
            return previous(card, ...)
        end
    end
    wrap_card_method("shatter", destroy_wrapper)
    wrap_card_method("start_dissolve", destroy_wrapper)

    local blind_class = rawget(_G, "Blind")
    local set_blind = type(blind_class) == "table" and blind_class.set_blind
    if type(set_blind) == "function" and not wrapped_globals[set_blind] then
        local wrapped = function(blind, prototype, ...)
            local adapter = resolution_adapter
            if not adapter then
                return set_blind(blind, prototype, ...)
            end
            return adapter:_with_blind_prototype_application(prototype, function(...)
                local key = prototype and prototype.key
                local before = key and active_hand_debuff(key, blind)
                local results = { set_blind(...) }
                if key then
                    adapter:_record_blind_hand_restriction(key, blind, before)
                    if
                        (key == "bl_wall" or key == "bl_final_vessel")
                        and type(blind.chips) == "number"
                    then
                        adapter:_append_effect({
                            kind = "blind_change",
                            operation = "requirement",
                            score_requirement = blind.chips,
                        })
                    end
                end
                return unpack(results)
            end, blind, prototype, ...)
        end
        wrapped_globals[set_blind] = true
        wrapped_globals[wrapped] = true
        blind_class.set_blind = wrapped
    end
    local defeat = type(blind_class) == "table" and blind_class.defeat
    if type(defeat) == "function" and not wrapped_globals[defeat] then
        local wrapped = function(blind, ...)
            local adapter = resolution_adapter
            if not adapter then
                return defeat(blind, ...)
            end
            return adapter:_with_blind_application(blind, defeat, blind, ...)
        end
        wrapped_globals[defeat] = true
        wrapped_globals[wrapped] = true
        blind_class.defeat = wrapped
    end
    local modify_hand = type(blind_class) == "table" and blind_class.modify_hand
    if type(modify_hand) == "function" and not wrapped_globals[modify_hand] then
        local wrapped = function(blind, cards, poker_hands, text, hand_mult, hand_chips, ...)
            local adapter = resolution_adapter
            if not adapter then
                return modify_hand(blind, cards, poker_hands, text, hand_mult, hand_chips, ...)
            end
            return adapter:_with_blind_application(blind, function(...)
                local results = { modify_hand(...) }
                local next_mult, next_chips = results[1], results[2]
                local prototype = blind_prototype(blind)
                if prototype and prototype.key == "bl_flint" then
                    if type(next_mult) == "number" and next_mult ~= hand_mult then
                        adapter:_append_effect({
                            kind = "x_mult",
                            amount = 0.5,
                            chips = hand_chips,
                            mult = next_mult,
                            score = math.floor(hand_chips * next_mult),
                        })
                    end
                    if type(next_chips) == "number" and next_chips ~= hand_chips then
                        adapter:_append_effect({
                            kind = "x_chips",
                            amount = 0.5,
                            chips = next_chips,
                            mult = next_mult,
                            score = math.floor(next_chips * next_mult),
                        })
                    end
                end
                return unpack(results)
            end, blind, cards, poker_hands, text, hand_mult, hand_chips, ...)
        end
        wrapped_globals[modify_hand] = true
        wrapped_globals[wrapped] = true
        blind_class.modify_hand = wrapped
    end
    local debuff_hand = type(blind_class) == "table" and blind_class.debuff_hand
    if type(debuff_hand) == "function" and not wrapped_globals[debuff_hand] then
        local wrapped = function(blind, cards, hand, hand_name, check, ...)
            local adapter = resolution_adapter
            if not adapter then
                return debuff_hand(blind, cards, hand, hand_name, check, ...)
            end
            return adapter:_with_blind_application(blind, function(...)
                local prototype = blind_prototype(blind)
                local key = prototype and prototype.key
                local before = active_hand_debuff(key, blind)
                local results = { debuff_hand(...) }
                adapter:_record_blind_hand_restriction(key, blind, before)
                if results[1] and not check then
                    adapter:_record_hand_debuff_blocked(blind)
                end
                return unpack(results)
            end, blind, cards, hand, hand_name, check, ...)
        end
        wrapped_globals[debuff_hand] = true
        wrapped_globals[wrapped] = true
        blind_class.debuff_hand = wrapped
    end
    local debuff_card = type(blind_class) == "table" and blind_class.debuff_card
    if type(debuff_card) == "function" and not wrapped_globals[debuff_card] then
        local wrapped = function(blind, ...)
            local adapter = resolution_adapter
            if not adapter then
                return debuff_card(blind, ...)
            end
            return adapter:_with_blind_application(blind, debuff_card, blind, ...)
        end
        wrapped_globals[debuff_card] = true
        wrapped_globals[wrapped] = true
        blind_class.debuff_card = wrapped
    end
    local drawn_to_hand = type(blind_class) == "table" and blind_class.drawn_to_hand
    if type(drawn_to_hand) == "function" and not wrapped_globals[drawn_to_hand] then
        local wrapped = function(blind, ...)
            local adapter = resolution_adapter
            if not adapter then
                return drawn_to_hand(blind, ...)
            end
            return adapter:_with_blind_application(blind, function(...)
                local before = {}
                for _, card in ipairs(G and G.hand and G.hand.cards or {}) do
                    before[#before + 1] = { card = card, state = card_state_snapshot(card) }
                end
                local results = { drawn_to_hand(...) }
                for _, entry in ipairs(before) do
                    adapter:_record_card_changes(entry.card, entry.state, { "forced_selection" })
                end
                return unpack(results)
            end, blind, ...)
        end
        wrapped_globals[drawn_to_hand] = true
        wrapped_globals[wrapped] = true
        blind_class.drawn_to_hand = wrapped
    end
    local stay_flipped = type(blind_class) == "table" and blind_class.stay_flipped
    if type(stay_flipped) == "function" and not wrapped_globals[stay_flipped] then
        local wrapped = function(blind, area, card, ...)
            local adapter = resolution_adapter
            if not adapter then
                return stay_flipped(blind, area, card, ...)
            end
            return adapter:_with_blind_application(blind, function(...)
                local results = { stay_flipped(...) }
                if results[1] then
                    adapter:_record_card_state(card, "facedown", true)
                end
                return unpack(results)
            end, blind, area, card, ...)
        end
        wrapped_globals[stay_flipped] = true
        wrapped_globals[wrapped] = true
        blind_class.stay_flipped = wrapped
    end
    local press_play = type(blind_class) == "table" and blind_class.press_play
    if type(press_play) == "function" and not wrapped_globals[press_play] then
        local wrapped = function(blind, ...)
            local adapter = resolution_adapter
            if not adapter then
                return press_play(blind, ...)
            end
            return adapter:_with_blind_application(blind, press_play, blind, ...)
        end
        wrapped_globals[press_play] = true
        wrapped_globals[wrapped] = true
        blind_class.press_play = wrapped
    end
    local disable_blind = type(blind_class) == "table" and blind_class.disable
    if type(disable_blind) == "function" and not wrapped_globals[disable_blind] then
        local function capture_disable(adapter, blind, ...)
            local context = adapter:_capture()
            local event = adapter:_current_resolution_event()
            if not context or not event or blind.disabled then
                return disable_blind(blind, ...)
            end
            local prototype = blind_prototype(blind)
            local key = prototype and prototype.key
            local before_chips = blind.chips
            local before = {}
            for _, card in ipairs(G and G.playing_cards or {}) do
                before[#before + 1] = { card = card, state = card_state_snapshot(card) }
            end
            adapter:_append_effect({ kind = "blind_change", operation = "disable" })
            context.blind_effect_depth = context.blind_effect_depth + 1
            local results = { pcall(disable_blind, blind, ...) }
            if results[1] then
                for _, entry in ipairs(before) do
                    adapter:_record_card_changes(entry.card, entry.state, { "forced_selection" })
                end
                if
                    (key == "bl_wall" or key == "bl_final_vessel")
                    and type(before_chips) == "number"
                    and type(blind.chips) == "number"
                    and blind.chips ~= before_chips
                then
                    adapter:_append_effect({
                        kind = "blind_change",
                        operation = "requirement",
                        score_requirement = blind.chips,
                    })
                end
            end
            context.blind_effect_depth = context.blind_effect_depth - 1
            if not results[1] then
                error(results[2])
            end
            return unpack(results, 2)
        end

        local wrapped = function(blind, ...)
            local adapter = resolution_adapter
            if not adapter or not adapter:_capture() then
                return disable_blind(blind, ...)
            end
            if adapter:_current_resolution_event() then
                return capture_disable(adapter, blind, ...)
            end
            return adapter:_with_blind_application(blind, capture_disable, adapter, blind, ...)
        end
        wrapped_globals[disable_blind] = true
        wrapped_globals[wrapped] = true
        blind_class.disable = wrapped
    end

    local tag_class = rawget(_G, "Tag")
    local apply_tag = type(tag_class) == "table" and tag_class.apply_to_run
    if type(apply_tag) == "function" and not wrapped_globals[apply_tag] then
        local wrapped = function(tag, ...)
            local adapter = resolution_adapter
            local context = adapter and adapter:_capture()
            if not context then
                return apply_tag(tag, ...)
            end
            return adapter:_with_prototype_application(
                "tag",
                tag and tag.key,
                nil,
                false,
                function(...)
                    local results = { apply_tag(...) }
                    local amount = tag.key == "tag_investment"
                        and type(results[1]) == "table"
                        and tonumber(results[1].dollars)
                    if amount and amount ~= 0 then
                        context.cash_out_content_dollars = context.cash_out_content_dollars + amount
                        adapter:_append_effect({
                            kind = "dollars",
                            amount = amount,
                            money = (G.GAME and G.GAME.dollars or 0)
                                + context.cash_out_content_dollars,
                        })
                    end
                    return unpack(results)
                end,
                tag,
                ...
            )
        end
        wrapped_globals[apply_tag] = true
        wrapped_globals[wrapped] = true
        tag_class.apply_to_run = wrapped
    end
    local remove_tag = type(tag_class) == "table" and tag_class.remove_from_game
    if type(remove_tag) == "function" and not wrapped_globals[remove_tag] then
        local wrapped = function(tag, ...)
            local adapter = resolution_adapter
            local key = type(tag) == "table" and tag.key or nil
            local before = key and tag_count(key) or 0
            local results = { remove_tag(tag, ...) }
            local quantity = key and before - tag_count(key) or 0
            if adapter and adapter:_current_resolution_event() and quantity > 0 then
                adapter:_append_effect({
                    kind = "tag_change",
                    operation = "consume",
                    key = key,
                    quantity = quantity,
                })
            end
            return unpack(results)
        end
        wrapped_globals[remove_tag] = true
        wrapped_globals[wrapped] = true
        tag_class.remove_from_game = wrapped
    end

    local back_class = rawget(_G, "Back")
    local apply_back = type(back_class) == "table" and back_class.apply_to_run
    if type(apply_back) == "function" and not wrapped_globals[apply_back] then
        local wrapped = function(back, ...)
            local adapter = resolution_adapter
            local context = adapter and adapter:_capture()
            if not context then
                return apply_back(back, ...)
            end
            local center = back and back.effect and back.effect.center
            return adapter:_with_prototype_application(
                "back",
                center and center.key,
                nil,
                false,
                apply_back,
                back,
                ...
            )
        end
        wrapped_globals[apply_back] = true
        wrapped_globals[wrapped] = true
        back_class.apply_to_run = wrapped
    end

    local card_area = rawget(_G, "CardArea")
    local emplace = type(card_area) == "table" and card_area.emplace
    if type(emplace) == "function" and not wrapped_globals[emplace] then
        local wrapped = function(area, card, ...)
            local results = { emplace(area, card, ...) }
            local adapter = resolution_adapter
            if adapter then
                adapter:_record_created(card, area)
            end
            return unpack(results)
        end
        wrapped_globals[emplace] = true
        wrapped_globals[wrapped] = true
        card_area.emplace = wrapped
    end
    local change_size = type(card_area) == "table" and card_area.change_size
    if type(change_size) == "function" and not wrapped_globals[change_size] then
        local wrapped = function(area, amount, ...)
            local adapter = resolution_adapter
            local resource = G and area == G.hand and "hand_size"
                or G and area == G.jokers and "joker_slots"
                or G and area == G.consumeables and "consumable_slots"
                or G and area == G.shop_jokers and "shop_slots"
            local before = area and area.config and area.config.card_limit
            local context = adapter and adapter:_capture()
            local since_order = context and context.next_order or 0
            local results = { change_size(area, amount, ...) }
            local after = area and area.config and area.config.card_limit
            if adapter and resource and type(before) == "number" then
                if type(after) == "number" and after ~= before then
                    adapter:_record_capacity(resource, after - before, after)
                elseif
                    adapter:_current_resolution_event()
                    and G
                    and G.E_MANAGER
                    and type(G.E_MANAGER.add_event) == "function"
                then
                    G.E_MANAGER:add_event(scoped_event(function()
                        local active = resolution_adapter
                        local active_context = active and active:_capture()
                        local value = area and area.config and area.config.card_limit
                        if
                            active
                            and active_context
                            and type(value) == "number"
                            and not effect_recorded_since(
                                active_context,
                                since_order,
                                "capacity",
                                "resource",
                                resource
                            )
                        then
                            active:_record_capacity(resource, value - before, value)
                        end
                        return true
                    end))
                end
            end
            return unpack(results)
        end
        wrapped_globals[change_size] = true
        wrapped_globals[wrapped] = true
        card_area.change_size = wrapped
    end
    local shuffle = type(card_area) == "table" and card_area.shuffle
    if type(shuffle) == "function" and not wrapped_globals[shuffle] then
        local wrapped = function(area, ...)
            local results = { shuffle(area, ...) }
            local adapter = resolution_adapter
            local event = adapter and adapter:_current_resolution_event()
            if
                event
                and event.component == "blind"
                and event.key == "bl_final_acorn"
                and G
                and area == G.jokers
            then
                for _, effect in ipairs(event.effects or {}) do
                    if
                        effect.kind == "reorder"
                        and effect.area == "jokers"
                        and effect.method == "shuffle"
                    then
                        return unpack(results)
                    end
                end
                adapter:_append_effect({ kind = "reorder", area = "jokers", method = "shuffle" })
            end
            return unpack(results)
        end
        wrapped_globals[shuffle] = true
        wrapped_globals[wrapped] = true
        card_area.shuffle = wrapped
    end
    if not SMODS or hooked_smods == SMODS then
        return
    end
    hooked_smods = SMODS
    wrap_smods("calculate_effect_table_key", function(previous)
        return function(effect_table, key, card, ret)
            local adapter = resolution_adapter
            local event = adapter
                    and adapter:_open_component(key, effect_table and effect_table[key], card)
                or nil
            local results = { pcall(previous, effect_table, key, card, ret) }
            if adapter then
                adapter:_close_component(event)
            end
            if not results[1] then
                error(results[2])
            end
            return unpack(results, 2)
        end
    end)
    wrap_smods("calculate_effect", function(previous)
        return function(effect, scored_card, from_edition, pre_jokers)
            local adapter = resolution_adapter
            local context = adapter and adapter:_capture()
            if context and type(effect) == "table" then
                if effect.repetitions or effect.retrigger_card or effect.retrigger_flag then
                    context.pending_retrigger_cause = effect.retrigger_card
                        or effect.card
                        or scored_card
                end
            end
            return previous(effect, scored_card, from_edition, pre_jokers)
        end
    end)
    wrap_smods("calculate_individual_effect", function(previous)
        return function(effect, scored_card, key, amount, from_edition)
            local result = previous(effect, scored_card, key, amount, from_edition)
            local adapter = resolution_adapter
            if adapter and result then
                if key == "remove" then
                    local context = current_calculation_context()
                    local destroyed = scored_card
                    if type(context) == "table" then
                        if type(context.destroy_card) == "table" then
                            destroyed = context.destroy_card
                        elseif type(context.destroying_card) == "table" then
                            destroyed = context.destroying_card
                        end
                    end
                    adapter:_record_destroy(destroyed)
                else
                    adapter:_record_atomic_effect(key, amount)
                end
            end
            return result
        end
    end)
    local previous_status = _G.card_eval_status_text
    if type(previous_status) == "function" then
        rawset(_G, "card_eval_status_text", function(card, eval_type, ...)
            local adapter = resolution_adapter
            if adapter and adapter:_capture() and eval_type == "debuff" then
                adapter:_record_debuff_blocked(card)
            end
            return previous_status(card, eval_type, ...)
        end)
    end
end

function ProductionBalatroAdapter:on_calculate(_context) end

local function cash_out_button()
    local areas = { G.round_eval }
    for _, box in ipairs(G.I and G.I.UIBOX or {}) do
        areas[#areas + 1] = box
    end
    for _, area in ipairs(areas) do
        local button = area and area.get_UIE_by_ID and area:get_UIE_by_ID("cash_out_button")
        if button and button.config and button.config.button == "cash_out" then
            return button
        end
    end
end

function ProductionBalatroAdapter:_maybe_cash_out()
    if
        G.STATE ~= G.STATES.ROUND_EVAL
        or not G.round_eval
        or not G.FUNCS
        or not G.FUNCS.cash_out
    then
        self.cash_out_pending = nil
        return false
    end
    if self.cash_out_pending then
        return true
    end
    local button = cash_out_button()
    if not button then
        return true
    end
    self.cash_out_pending = true
    local payout = G.GAME.current_round and G.GAME.current_round.dollars or 0
    self.cash_out_expected_money = (G.GAME.dollars or 0) + payout
    local ok = pcall(G.FUNCS.cash_out, button)
    if ok then
        self:_record_cash_out(payout)
    else
        self.cash_out_pending = nil
    end
    return true
end

local function can_afford(cost)
    cost = tonumber(cost) or 0
    if cost <= 0 then
        return true
    end
    local dollars = G.GAME and G.GAME.dollars or 0
    local bankrupt_at = G.GAME and G.GAME.bankrupt_at or 0
    return cost <= dollars - bankrupt_at
end

function ProductionBalatroAdapter:_shop_category(card)
    local set = card.ability and card.ability.set
        or card.config and card.config.center and card.config.center.set
    if set == "Joker" then
        return "joker"
    elseif set == "Voucher" then
        return "voucher"
    elseif set == "Booster" then
        return "booster"
    elseif set == "Default" or set == "Enhanced" then
        return "playing_card"
    elseif
        set == "Tarot"
        or set == "Planet"
        or set == "Spectral"
        or (card.ability and card.ability.consumeable)
    then
        return "consumable"
    end
    return "unknown"
end

function ProductionBalatroAdapter:_shop_loc(card, category)
    local center = card.config and card.config.center
    local key = center and center.key or ""
    if category == "booster" then
        local extra = center and center.config or {}
        return "Other", key:gsub("_%d+$", ""), { extra.choose or 1, extra.extra }
    end
    if category == "voucher" then
        local extra = center and center.config and (center.config.extra_disp or center.config.extra)
        local vars = (type(extra) == "number" or type(extra) == "string") and { extra } or nil
        return "Voucher", key, vars
    end
    if category == "joker" or category == "consumable" then
        return center and center.set or "Joker", key, self:_card_loc_vars(card)
    end
    return center and center.set or "Joker", key, nil
end

function ProductionBalatroAdapter:_shop_listing(card, prefix, index)
    local category = self:_shop_category(card)
    local item
    if category == "playing_card" then
        item = self:_playing_card(card, index)
    else
        local loc_set, loc_key, vars = self:_shop_loc(card, category)
        local center = card.config and card.config.center
        local key = center and center.key
            or card.config and card.config.card_key
            or (prefix .. "_" .. tostring(index))
        local name, description =
            self:_english_entry(loc_set, loc_key, vars, center and center.name or key)
        item = {
            key = key,
            name = name,
            description = description,
        }
    end
    item.target_ref = prefix .. ":" .. tostring(card.sort_id or index)
    item.category = category
    item.cost = card.cost or 0
    if category == "joker" then
        item.slot = "joker"
    elseif category == "consumable" then
        item.slot = "consumable"
    end
    if category ~= "playing_card" then
        item.edition = self:_edition(card)
    end
    return item
end

function ProductionBalatroAdapter:_collect_shop_area(area, prefix)
    local items = {}
    for index, card in ipairs(area and area.cards or {}) do
        items[index] = self:_shop_listing(card, prefix, index)
    end
    return items
end

local function shop_signature(state)
    local parts = {}
    for _, group in ipairs({ state.shop_items, state.shop_vouchers, state.shop_boosters }) do
        for _, item in ipairs(group or {}) do
            parts[#parts + 1] = item.target_ref .. "=" .. tostring(item.cost)
        end
        parts[#parts + 1] = "/"
    end
    parts[#parts + 1] = tostring(state.reroll_cost or 0)
    return table.concat(parts, ",")
end

function ProductionBalatroAdapter:_has_buy_space(card)
    local set = card.ability and card.ability.set
    if set == "Voucher" or set == "Enhanced" or set == "Default" or set == "Booster" then
        return true
    end
    local extra = (card.edition and card.edition.negative) and 1 or 0
    if set == "Joker" then
        return G.jokers
            and #G.jokers.cards
                < ((G.jokers.config and G.jokers.config.card_limit) or 0) + extra
    end
    if card.ability and card.ability.consumeable then
        return G.consumeables
            and #G.consumeables.cards
                < ((G.consumeables.config and G.consumeables.config.card_limit) or 0) + extra
    end
    return true
end

function ProductionBalatroAdapter:_shop_consumable_usable(card)
    if card.can_use_consumeable then
        local ok, usable = pcall(card.can_use_consumeable, card)
        return ok and usable or false
    end
    return self:_could_use_consumable(card)
end

function ProductionBalatroAdapter:_append_shop_actions(state)
    local buy_refs = {}
    for _, item in ipairs(state.shop_items or {}) do
        local card = self:_find_shop_card(item.target_ref)
        if card and can_afford(card.cost) and self:_has_buy_space(card) then
            buy_refs[#buy_refs + 1] = item.target_ref
        end
        if item.category == "consumable" and card and can_afford(card.cost) then
            local rule = self:_consumable_target_rule(card)
            if rule or self:_shop_consumable_usable(card) then
                local action = self:_consumable_action(
                    "buy_and_use_shop_item",
                    "item_id",
                    item.target_ref,
                    card,
                    state
                )
                if action then
                    state.legal_actions[#state.legal_actions + 1] = action
                end
            end
        end
    end
    if #buy_refs > 0 then
        table.insert(state.legal_actions, 1, {
            tool = "buy_shop_item",
            target_refs = { item_id = buy_refs },
        })
    end
    local voucher_refs = {}
    for _, voucher in ipairs(state.shop_vouchers or {}) do
        local card = self:_find_shop_card(voucher.target_ref, "shop_voucher")
        if card and can_afford(card.cost) then
            voucher_refs[#voucher_refs + 1] = voucher.target_ref
        end
    end
    if #voucher_refs > 0 then
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "redeem_voucher",
            target_refs = { voucher_id = voucher_refs },
        }
    end
    local booster_refs = {}
    for _, booster in ipairs(state.shop_boosters or {}) do
        local card = self:_find_shop_card(booster.target_ref, "shop_booster")
        if card and can_afford(card.cost) then
            booster_refs[#booster_refs + 1] = booster.target_ref
        end
    end
    if #booster_refs > 0 then
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "open_booster",
            target_refs = { booster_id = booster_refs },
        }
    end
    if can_afford(state.reroll_cost) then
        state.legal_actions[#state.legal_actions + 1] = {
            tool = "reroll_shop",
        }
    end
end

function ProductionBalatroAdapter:_shop_observation()
    if
        G.STAGE ~= G.STAGES.RUN
        or G.STATE ~= G.STATES.SHOP
        or not G.STATE_COMPLETE
        or G.SETTINGS.paused
        or runtime_is_busy()
        or not G.shop
        or (self.cash_out_expected_money and (G.GAME.dollars or 0) < self.cash_out_expected_money)
    then
        return nil
    end
    self.cash_out_expected_money = nil
    local state = self:_run_state()
    state.reroll_cost = G.GAME.current_round and G.GAME.current_round.reroll_cost or 0
    if G.hand and G.hand.cards and #G.hand.cards > 0 then
        state.hand = {}
        for index, card in ipairs(G.hand.cards) do
            state.hand[index] = self:_playing_card(card, index, true)
        end
        apply_hand_order_projections(state, G.hand.cards)
    end
    state.shop_items = self:_collect_shop_area(G.shop_jokers, "shop_item")
    state.shop_vouchers = self:_collect_shop_area(G.shop_vouchers, "shop_voucher")
    state.shop_boosters = self:_collect_shop_area(G.shop_booster, "shop_booster")
    state.legal_actions = {}
    self:_append_shop_actions(state)
    self:_append_owned_actions(state)
    state.legal_actions[#state.legal_actions + 1] = {
        tool = "leave_shop",
    }
    return self:_finish(
        "shop",
        state,
        table.concat({
            "shop",
            tostring(state.ante),
            tostring(state.money),
            owned_signature(state),
            shop_signature(state),
        }, "|")
    )
end

function ProductionBalatroAdapter:_collect_booster_items()
    local items = {}
    for index, card in ipairs(G.pack_cards and G.pack_cards.cards or {}) do
        local item = self:_shop_listing(card, "booster_item", index)
        item.cost = nil
        item.slot = nil
        if item.category == "consumable" then
            local rule = self:_consumable_target_rule(card)
            item.min_targets = rule and rule.min_items or 0
            item.max_targets = rule and rule.max_items or 0
        end
        items[index] = item
    end
    return items
end

function ProductionBalatroAdapter:_pack_consumable_usable(card)
    local rule = self:_consumable_target_rule(card)
    if rule then
        return (G.hand and G.hand.cards and #G.hand.cards or 0) >= rule.min_items
    end
    if card.can_use_consumeable then
        local ok, usable = pcall(card.can_use_consumeable, card)
        return ok and usable or false
    end
    return true
end

function ProductionBalatroAdapter:_pack_item_allowed(card)
    local category = self:_shop_category(card)
    if category == "joker" then
        return self:_has_buy_space(card)
    end
    if category == "consumable" then
        return self:_pack_consumable_usable(card)
    end
    return true
end

function ProductionBalatroAdapter:_append_booster_actions(state)
    local plain_refs = {}
    for _, item in ipairs(state.booster_items or {}) do
        local card = self:_find_shop_card(item.target_ref, "booster_item")
        if card and self:_pack_item_allowed(card) then
            local rule = item.category == "consumable" and self:_consumable_target_rule(card)
            if rule then
                local action = self:_consumable_action(
                    "choose_booster_item",
                    "item_id",
                    item.target_ref,
                    card,
                    state
                )
                if action then
                    state.legal_actions[#state.legal_actions + 1] = action
                end
            else
                plain_refs[#plain_refs + 1] = item.target_ref
            end
        end
    end
    if #plain_refs > 0 then
        table.insert(state.legal_actions, 1, {
            tool = "choose_booster_item",
            target_refs = { item_id = plain_refs },
        })
    end
    state.legal_actions[#state.legal_actions + 1] = {
        tool = "skip_booster",
    }
end

function ProductionBalatroAdapter:_booster_observation()
    local category = pack_category()
    if
        not category
        or not pack_is_visible()
        or G.SETTINGS.paused
        or runtime_is_busy()
        or (SMODS and SMODS.cards_to_draw or 0) ~= 0
        or G.TAROT_INTERRUPT
    then
        return nil
    end
    local state = self:_run_state()
    if G.hand and G.hand.cards and #G.hand.cards > 0 then
        state.hand = {}
        for index, card in ipairs(G.hand.cards) do
            state.hand[index] = self:_playing_card(card, index, true)
        end
        apply_hand_order_projections(state, G.hand.cards)
    end
    state.booster = {
        category = category,
        choices_left = G.GAME.pack_choices or 0,
    }
    state.booster_items = self:_collect_booster_items()
    local hand_count = #(state.hand or {})
    for _, item in ipairs(state.booster_items) do
        if (item.min_targets or 0) > hand_count then
            return nil
        end
    end
    state.legal_actions = {}
    self:_append_booster_actions(state)
    self:_append_owned_actions(state)
    local hand_refs = {}
    for index, card in ipairs(state.hand or {}) do
        hand_refs[index] = card.target_ref
    end
    return self:_finish(
        "booster",
        state,
        table.concat({
            "booster",
            category,
            tostring(state.booster.choices_left),
            shop_signature({ shop_items = state.booster_items }),
            table.concat(hand_refs, ","),
            owned_signature(state),
        }, "|")
    )
end

function ProductionBalatroAdapter:_execute_play_hand(targets)
    local observation = self:_hand_observation()
    if not observation then
        return nil, adapter_error("INVALID_PHASE", "play_hand requires a hand decision")
    end
    if G.GAME.current_round.hands_left < 1 or (G.GAME.blind and G.GAME.blind.block_play) then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "Playing a hand is not allowed")
    end
    local cards, card_error = self:_cards_from_targets(targets.card_ids)
    if not cards then
        return nil, card_error
    end
    self:_highlight_cards(cards)
    local ok, call_error = pcall(G.FUNCS.play_cards_from_highlighted)
    if not ok then
        return nil, adapter_error("INTERNAL_ERROR", "Could not play hand: " .. tostring(call_error))
    end
    return { pending = true }
end

function ProductionBalatroAdapter:_execute_discard_cards(targets)
    local observation = self:_hand_observation()
    if not observation then
        return nil, adapter_error("INVALID_PHASE", "discard_cards requires a hand decision")
    end
    if G.GAME.current_round.discards_left < 1 then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "Discarding is not allowed")
    end
    local cards, card_error = self:_cards_from_targets(targets.card_ids)
    if not cards then
        return nil, card_error
    end
    local card_keys = {}
    for index, card in ipairs(cards) do
        card_keys[index] = card.config and card.config.card_key or tostring(index)
    end
    self.action_events = { { type = "discarded", card_keys = card_keys } }
    self:_highlight_cards(cards)
    local ok, call_error = pcall(G.FUNCS.discard_cards_from_highlighted)
    if not ok then
        self.action_events = nil
        return nil, adapter_error("INTERNAL_ERROR", "Could not discard: " .. tostring(call_error))
    end
    return { pending = true, events = self.action_events }
end

function ProductionBalatroAdapter:_find_owned(reference)
    if type(reference) ~= "string" then
        return nil
    end
    local kind = reference:match("^([^:]+):")
    local area = kind == "joker" and G.jokers
        or kind == "consumable" and G.consumeables
        or kind == "card" and G.hand
    if not area then
        return nil
    end
    for index, card in ipairs(area.cards or {}) do
        if kind .. ":" .. tostring(card.sort_id or index) == reference then
            return card, kind, area
        end
    end
end

function ProductionBalatroAdapter:_execute_reorder_cards(action)
    local area_name = action.arguments and action.arguments.area
    local area = area_name == "hand" and G.hand or area_name == "jokers" and G.jokers
    if not area or not area.cards then
        return nil, adapter_error("INVALID_PHASE", "The area cannot be reordered")
    end
    local prefix = area_name == "hand" and "card" or "joker"
    local ordered = action.targets and action.targets.ordered_ids
    if type(ordered) ~= "table" or #ordered ~= #area.cards then
        return nil, adapter_error("INVALID_TARGET", "ordered_ids must contain the complete area")
    end
    local by_ref = {}
    for index, card in ipairs(area.cards) do
        by_ref[prefix .. ":" .. tostring(card.sort_id or index)] = card
    end
    local next_cards = {}
    local seen = {}
    for index, reference in ipairs(ordered) do
        local card = by_ref[reference]
        if not card or seen[card] then
            return nil, adapter_error("INVALID_TARGET", "ordered_ids is not a complete permutation")
        end
        seen[card] = true
        next_cards[index] = card
    end
    for index, card in ipairs(next_cards) do
        if card.T then
            card.T.x = index
        end
    end
    area.cards = next_cards
    if area.set_ranks then
        area:set_ranks()
    end
    if area.align_cards then
        area:align_cards()
    end
    local resolution = self.action_resolution
    local observation = self:observe(action.visibility or "fair")
    if not observation then
        return { pending = true, resolution = resolution }
    end
    return { observation = observation, resolution = resolution }
end

function ProductionBalatroAdapter:_execute_use_consumable(action)
    local card = self:_find_owned(action.targets and action.targets.consumable_id)
    if not card then
        return nil, adapter_error("INVALID_TARGET", "consumable_id is not an owned consumable")
    end
    local rule = self:_consumable_target_rule(card)
    local target_ids = action.targets and action.targets.target_ids
    if rule then
        if
            type(target_ids) ~= "table"
            or #target_ids < rule.min_items
            or #target_ids > rule.max_items
        then
            return nil, adapter_error("INVALID_PARAMS", "target_ids does not match this consumable")
        end
        local cards, card_error = self:_cards_from_targets(target_ids)
        if not cards then
            return nil, card_error
        end
        self:_highlight_cards(cards)
    else
        if target_ids and #target_ids > 0 then
            return nil, adapter_error("INVALID_PARAMS", "This consumable does not take targets")
        end
        if G.hand and G.hand.unhighlight_all then
            G.hand:unhighlight_all()
        end
    end
    if card.can_use_consumeable then
        local ok, usable = pcall(card.can_use_consumeable, card)
        if not ok or not usable then
            return nil, adapter_error("ACTION_NOT_ALLOWED", "The consumable cannot be used now")
        end
    elseif not self:_could_use_consumable(card) then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "The consumable cannot be used now")
    end
    if not G.FUNCS or not G.FUNCS.use_card then
        return nil, adapter_error("INTERNAL_ERROR", "use_card is unavailable")
    end
    local target_keys = {}
    for index, hand_card in ipairs(G.hand and G.hand.highlighted or {}) do
        target_keys[index] = hand_card.config and hand_card.config.card_key or tostring(index)
    end
    local key = card.config and card.config.center and card.config.center.key
    local ok, call_error = pcall(G.FUNCS.use_card, { config = { ref_table = card } })
    if not ok then
        return nil,
            adapter_error("INTERNAL_ERROR", "Could not use consumable: " .. tostring(call_error))
    end
    return {
        pending = true,
        events = {
            {
                type = "consumable_used",
                key = key,
                target_keys = #target_keys > 0 and target_keys or nil,
            },
        },
    }
end

function ProductionBalatroAdapter:_execute_sell_owned_item(action)
    local card = self:_find_owned(action.targets and action.targets.item_id)
    if not card then
        return nil, adapter_error("INVALID_TARGET", "item_id is not an owned item")
    end
    if card.can_sell_card then
        local ok, sellable = pcall(card.can_sell_card, card)
        if not ok or not sellable then
            return nil, adapter_error("ACTION_NOT_ALLOWED", "The item cannot be sold now")
        end
    end
    if not G.FUNCS or not G.FUNCS.sell_card then
        return nil, adapter_error("INTERNAL_ERROR", "sell_card is unavailable")
    end
    local key = card.config and card.config.center and card.config.center.key
    local money = card.sell_cost or 0
    self:_expect_dollars(money)
    local ok, call_error = pcall(G.FUNCS.sell_card, { config = { ref_table = card } })
    if not ok then
        return nil, adapter_error("INTERNAL_ERROR", "Could not sell item: " .. tostring(call_error))
    end
    return {
        pending = true,
        events = { { type = "item_sold", key = key, money = money } },
    }
end

function ProductionBalatroAdapter:_find_shop_card(reference, expected_prefix)
    if type(reference) ~= "string" then
        return nil
    end
    local prefix = reference:match("^([^:]+):")
    if expected_prefix and prefix ~= expected_prefix then
        return nil
    end
    local area = prefix == "shop_item" and G.shop_jokers
        or prefix == "shop_voucher" and G.shop_vouchers
        or prefix == "shop_booster" and G.shop_booster
        or prefix == "booster_item" and G.pack_cards
    if not area then
        return nil
    end
    for index, card in ipairs(area.cards or {}) do
        if prefix .. ":" .. tostring(card.sort_id or index) == reference then
            return card
        end
    end
end

function ProductionBalatroAdapter:_prepare_consumable_targets(card, target_ids)
    local rule = self:_consumable_target_rule(card)
    if rule then
        if
            type(target_ids) ~= "table"
            or #target_ids < rule.min_items
            or #target_ids > rule.max_items
        then
            return nil, adapter_error("INVALID_PARAMS", "target_ids does not match this consumable")
        end
        local cards, card_error = self:_cards_from_targets(target_ids)
        if not cards then
            return nil, card_error
        end
        self:_highlight_cards(cards)
    else
        if target_ids and #target_ids > 0 then
            return nil, adapter_error("INVALID_PARAMS", "This consumable does not take targets")
        end
        if G.hand and G.hand.unhighlight_all then
            G.hand:unhighlight_all()
        end
    end
    return true
end

function ProductionBalatroAdapter:_execute_buy_shop_item(action, use)
    if not self:_shop_observation() then
        return nil, adapter_error("INVALID_PHASE", "Shop actions require the shop")
    end
    local card = self:_find_shop_card(action.targets and action.targets.item_id, "shop_item")
    if not card then
        return nil, adapter_error("INVALID_TARGET", "item_id is not a shop item")
    end
    local category = self:_shop_category(card)
    if category ~= "joker" and category ~= "consumable" and category ~= "playing_card" then
        return nil, adapter_error("INVALID_TARGET", "item_id is not a buyable shop item")
    end
    if not can_afford(card.cost) then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "Not enough money")
    end
    if use then
        if category ~= "consumable" then
            return nil,
                adapter_error("ACTION_NOT_ALLOWED", "Only consumables can be bought and used")
        end
        local prepared, prepare_error =
            self:_prepare_consumable_targets(card, action.targets and action.targets.target_ids)
        if not prepared then
            return nil, prepare_error
        end
        if not self:_shop_consumable_usable(card) then
            return nil, adapter_error("ACTION_NOT_ALLOWED", "The consumable cannot be used now")
        end
    elseif not self:_has_buy_space(card) then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "Not enough space")
    end
    if not G.FUNCS or not G.FUNCS.buy_from_shop then
        return nil, adapter_error("INTERNAL_ERROR", "buy_from_shop is unavailable")
    end
    local key = card.config
        and (card.config.card_key or (card.config.center and card.config.center.key))
    local money = -(card.cost or 0)
    local target_keys = {}
    for index, hand_card in ipairs(G.hand and G.hand.highlighted or {}) do
        target_keys[index] = hand_card.config and hand_card.config.card_key or tostring(index)
    end
    if not use then
        self:_expect_dollars(money)
    end
    local function buy()
        return G.FUNCS.buy_from_shop({
            config = { ref_table = card, id = use and "buy_and_use" or nil },
        })
    end
    local ok, call_error = pcall(buy)
    if not ok then
        return nil,
            adapter_error("INTERNAL_ERROR", "Could not buy shop item: " .. tostring(call_error))
    end
    if use then
        return {
            pending = true,
            events = {
                {
                    type = "item_bought_and_used",
                    key = key,
                    money = money,
                    target_keys = #target_keys > 0 and target_keys or nil,
                },
            },
        }
    end
    return {
        pending = true,
        events = { { type = "item_bought", key = key, money = money, category = category } },
    }
end

function ProductionBalatroAdapter:_execute_redeem_voucher(action)
    if not self:_shop_observation() then
        return nil, adapter_error("INVALID_PHASE", "redeem_voucher requires the shop")
    end
    local card = self:_find_shop_card(action.targets and action.targets.voucher_id, "shop_voucher")
    if not card then
        return nil, adapter_error("INVALID_TARGET", "voucher_id is not a shop voucher")
    end
    if not can_afford(card.cost) then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "Not enough money")
    end
    if not G.FUNCS or not G.FUNCS.use_card then
        return nil, adapter_error("INTERNAL_ERROR", "use_card is unavailable")
    end
    local key = card.config and card.config.center and card.config.center.key
    local money = -(card.cost or 0)
    self:_expect_dollars(money)
    local ok, call_error = pcall(G.FUNCS.use_card, { config = { ref_table = card } })
    if not ok then
        return nil,
            adapter_error("INTERNAL_ERROR", "Could not redeem voucher: " .. tostring(call_error))
    end
    return {
        pending = true,
        events = { { type = "voucher_redeemed", key = key, money = money } },
    }
end

function ProductionBalatroAdapter:_execute_open_booster(action)
    if not self:_shop_observation() then
        return nil, adapter_error("INVALID_PHASE", "open_booster requires the shop")
    end
    local card = self:_find_shop_card(action.targets and action.targets.booster_id, "shop_booster")
    if not card then
        return nil, adapter_error("INVALID_TARGET", "booster_id is not a shop booster")
    end
    if not can_afford(card.cost) then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "Not enough money")
    end
    if not G.FUNCS or not G.FUNCS.use_card then
        return nil, adapter_error("INTERNAL_ERROR", "use_card is unavailable")
    end
    local key = card.config and card.config.center and card.config.center.key
    local money = -(card.cost or 0)
    self:_expect_dollars(money)
    local ok, call_error = pcall(G.FUNCS.use_card, { config = { ref_table = card } })
    if not ok then
        return nil,
            adapter_error("INTERNAL_ERROR", "Could not open booster: " .. tostring(call_error))
    end
    return {
        pending = true,
        events = { { type = "booster_opened", key = key, money = money } },
    }
end

function ProductionBalatroAdapter:_execute_choose_booster_item(action)
    if not self:_booster_observation() then
        return nil, adapter_error("INVALID_PHASE", "choose_booster_item requires a booster")
    end
    local card = self:_find_shop_card(action.targets and action.targets.item_id, "booster_item")
    if not card then
        return nil, adapter_error("INVALID_TARGET", "item_id is not a booster item")
    end
    if not self:_pack_item_allowed(card) then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "The booster item cannot be chosen now")
    end
    local category = self:_shop_category(card)
    if category == "consumable" then
        local prepared, prepare_error =
            self:_prepare_consumable_targets(card, action.targets and action.targets.target_ids)
        if not prepared then
            return nil, prepare_error
        end
        if card.can_use_consumeable then
            local ok, usable = pcall(card.can_use_consumeable, card)
            if not ok or not usable then
                return nil, adapter_error("ACTION_NOT_ALLOWED", "The consumable cannot be used now")
            end
        end
    elseif action.targets and action.targets.target_ids and #action.targets.target_ids > 0 then
        return nil, adapter_error("INVALID_PARAMS", "This booster item does not take targets")
    end
    if not G.FUNCS or not G.FUNCS.use_card then
        return nil, adapter_error("INTERNAL_ERROR", "use_card is unavailable")
    end
    local key = card.config
        and (card.config.card_key or (card.config.center and card.config.center.key))
    local target_keys = {}
    for index, hand_card in ipairs(G.hand and G.hand.highlighted or {}) do
        target_keys[index] = hand_card.config and hand_card.config.card_key or tostring(index)
    end
    local function choose()
        return G.FUNCS.use_card({ config = { ref_table = card } })
    end
    local ok, call_error = pcall(choose)
    if not ok then
        return nil,
            adapter_error(
                "INTERNAL_ERROR",
                "Could not choose booster item: " .. tostring(call_error)
            )
    end
    local still_in_pack = false
    for _, pack_card in ipairs(G.pack_cards and G.pack_cards.cards or {}) do
        if pack_card == card then
            still_in_pack = true
            break
        end
    end
    if still_in_pack then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "The booster item cannot be chosen now")
    end
    if category == "consumable" then
        return {
            pending = true,
            events = {
                {
                    type = "booster_item_used",
                    key = key,
                    target_keys = #target_keys > 0 and target_keys or nil,
                },
            },
        }
    end
    return {
        pending = true,
        events = { { type = "booster_item_chosen", key = key, category = category } },
    }
end

function ProductionBalatroAdapter:_execute_skip_booster()
    if not self:_booster_observation() then
        return nil, adapter_error("INVALID_PHASE", "skip_booster requires a booster")
    end
    if not G.FUNCS or not G.FUNCS.skip_booster then
        return nil, adapter_error("INTERNAL_ERROR", "skip_booster is unavailable")
    end
    local ok, call_error = pcall(G.FUNCS.skip_booster)
    if not ok then
        return nil,
            adapter_error("INTERNAL_ERROR", "Could not skip booster: " .. tostring(call_error))
    end
    return {
        pending = true,
        events = { { type = "booster_skipped" } },
    }
end

function ProductionBalatroAdapter:_execute_reroll_shop()
    if not self:_shop_observation() then
        return nil, adapter_error("INVALID_PHASE", "reroll_shop requires the shop")
    end
    local cost = G.GAME.current_round and G.GAME.current_round.reroll_cost or 0
    if not can_afford(cost) then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "Not enough money")
    end
    if not G.FUNCS or not G.FUNCS.reroll_shop then
        return nil, adapter_error("INTERNAL_ERROR", "reroll_shop is unavailable")
    end
    self:_expect_dollars(-cost)
    local ok, call_error = pcall(G.FUNCS.reroll_shop)
    if not ok then
        return nil,
            adapter_error("INTERNAL_ERROR", "Could not reroll shop: " .. tostring(call_error))
    end
    return {
        pending = true,
        events = { { type = "shop_rerolled", money = -cost } },
    }
end

function ProductionBalatroAdapter:_execute_leave_shop()
    if not self:_shop_observation() then
        return nil, adapter_error("INVALID_PHASE", "leave_shop requires the shop")
    end
    if not G.FUNCS or not G.FUNCS.toggle_shop then
        return nil, adapter_error("INTERNAL_ERROR", "toggle_shop is unavailable")
    end
    local ok, call_error = pcall(G.FUNCS.toggle_shop)
    if not ok then
        return nil,
            adapter_error("INTERNAL_ERROR", "Could not leave shop: " .. tostring(call_error))
    end
    return {
        pending = true,
        events = { { type = "left_shop" } },
    }
end

function ProductionBalatroAdapter:_execute_continue_endless()
    if not victory_overlay_is_visible() then
        return nil, adapter_error("INVALID_PHASE", "continue_endless requires a standard victory")
    end
    if not G.FUNCS or not G.FUNCS.exit_overlay_menu then
        return nil, adapter_error("INTERNAL_ERROR", "exit_overlay_menu is unavailable")
    end
    local ok, call_error = pcall(G.FUNCS.exit_overlay_menu)
    if not ok then
        return nil,
            adapter_error(
                "INTERNAL_ERROR",
                "Could not continue Endless Mode: " .. tostring(call_error)
            )
    end
    self.continued_endless = true
    self.action_events = { { type = "continued_endless" } }
    return { pending = true, events = self.action_events }
end

function ProductionBalatroAdapter:_execute_return_to_menu()
    if not victory_overlay_is_visible() and not defeat_overlay_is_visible() then
        return nil, adapter_error("INVALID_PHASE", "return_to_menu requires a terminal run state")
    end
    if not G.FUNCS or not G.FUNCS.go_to_menu then
        return nil, adapter_error("INTERNAL_ERROR", "go_to_menu is unavailable")
    end
    local ok, call_error = pcall(G.FUNCS.go_to_menu)
    if not ok then
        return nil,
            adapter_error(
                "INTERNAL_ERROR",
                "Could not return to the menu: " .. tostring(call_error)
            )
    end
    return {
        pending = true,
        events = { { type = "returned_to_menu" } },
    }
end

function ProductionBalatroAdapter:_execute_reroll_boss()
    local observation = self:_blind_observation()
    if not observation then
        return nil, adapter_error("INVALID_PHASE", "reroll_boss requires Blind selection")
    end
    if not reroll_is_available() then
        return nil, adapter_error("ACTION_NOT_ALLOWED", "Boss Blind reroll is not available")
    end
    local previous_key = G.GAME.round_resets.blind_choices.Boss
    local ok, call_error = pcall(G.FUNCS.reroll_boss)
    if not ok then
        return nil,
            adapter_error("INTERNAL_ERROR", "Could not reroll Boss Blind: " .. tostring(call_error))
    end
    return {
        pending = true,
        events = { { type = "boss_rerolled", previous_blind_key = previous_key } },
    }
end

---@param action table
---@return table?, BalatroAdapterError?
function ProductionBalatroAdapter:execute(action)
    if type(action.expected_state_hash) ~= "string" then
        return nil, adapter_error("INTERNAL_ERROR", "Expected state hash is required")
    end
    local environment = self:_environment_state()
    if environment.compatibility.versions == "unsupported" then
        return nil,
            adapter_error(
                "INCOMPATIBLE_VERSION",
                environment.compatibility.diagnostic
                    or "Game environment is below the minimum supported versions"
            )
    end
    self:_begin_resolution(action)
    local result, err
    if action.name == "start_run" then
        result, err = self:_execute_start_run(action.arguments)
    elseif action.name == "select_blind" then
        result, err = self:_execute_select_blind(action.targets)
    elseif action.name == "skip_blind" then
        result, err = self:_execute_skip_blind(action.targets)
    elseif action.name == "reroll_boss" then
        result, err = self:_execute_reroll_boss()
    elseif action.name == "play_hand" then
        result, err = self:_execute_play_hand(action.targets)
    elseif action.name == "discard_cards" then
        result, err = self:_execute_discard_cards(action.targets)
    elseif action.name == "reorder_cards" then
        result, err = self:_execute_reorder_cards(action)
    elseif action.name == "use_consumable" then
        result, err = self:_execute_use_consumable(action)
    elseif action.name == "sell_owned_item" then
        result, err = self:_execute_sell_owned_item(action)
    elseif action.name == "buy_shop_item" then
        result, err = self:_execute_buy_shop_item(action)
    elseif action.name == "buy_and_use_shop_item" then
        result, err = self:_execute_buy_shop_item(action, true)
    elseif action.name == "redeem_voucher" then
        result, err = self:_execute_redeem_voucher(action)
    elseif action.name == "open_booster" then
        result, err = self:_execute_open_booster(action)
    elseif action.name == "choose_booster_item" then
        result, err = self:_execute_choose_booster_item(action)
    elseif action.name == "skip_booster" then
        result, err = self:_execute_skip_booster()
    elseif action.name == "reroll_shop" then
        result, err = self:_execute_reroll_shop()
    elseif action.name == "leave_shop" then
        result, err = self:_execute_leave_shop()
    elseif action.name == "continue_endless" then
        result, err = self:_execute_continue_endless()
    elseif action.name == "return_to_menu" then
        result, err = self:_execute_return_to_menu()
    else
        self:_abandon_resolution()
        return nil, adapter_error("ACTION_NOT_ALLOWED", "The semantic action is not implemented")
    end
    if not result then
        self:_abandon_resolution()
        return nil, err
    end
    result.events = nil
    local context = self.resolution_capture
    result.resolution = context and context.events or nil
    result.resolution_context = context
    return result
end

return ProductionBalatroAdapter
