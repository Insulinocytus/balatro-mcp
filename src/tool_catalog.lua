---@class ToolCatalog
local ToolCatalog = {}

local json_schema_2020 = "https://json-schema.org/draft/2020-12/schema"
local visibility_values = { "fair", "omniscient" }
local phase_values = {
    "main_menu",
    "run_setup",
    "blind_selection",
    "hand_play",
    "shop",
    "booster",
    "victory",
    "defeat",
}
local encyclopedia_set_values = {
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
local reorder_area_values = { "hand", "jokers" }
local stake_values = { 1, 2, 3, 4, 5, 6, 7, 8 }
local resolution_phase_values = {
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
local resolution_event_type_values = {
    "apply",
    "trigger",
    "retrigger",
    "cash_out",
    "debuff_blocked",
}
local resolution_component_values = {
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
local resolution_effect_kind_values = {
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
local created_object_kind_values = { "playing_card", "joker", "consumable", "voucher" }
local resolution_destination_values = { "owned", "permanent_deck", "shop_offer" }
local resolution_card_state_values = {
    "rank",
    "suit",
    "enhancement",
    "edition",
    "seal",
    "facedown",
    "debuffed",
    "forced_selection",
}
local resolution_copy_mode_values = { "overwrite", "create" }
local resolution_capacity_resource_values = {
    "hand_size",
    "joker_slots",
    "consumable_slots",
    "shop_slots",
}
local resolution_allowance_resource_values = { "hands", "discards" }
local resolution_card_progress_resource_values = { "chips", "mult", "x_mult" }
local resolution_numeric_run_rule_values = {
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
}
local resolution_boolean_run_rule_values = {
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
}
local resolution_tag_operation_values = { "add", "consume" }
local resolution_blind_operation_values = {
    "disable",
    "defeat",
    "replace",
    "requirement",
    "hand_restriction",
    "draw_rule",
}
local resolution_reorder_area_values = { "hand", "jokers" }
local resolution_reorder_method_values = { "shuffle", "sort" }
local resolution_move_zone_values = { "deck", "hand", "play", "discard" }
local resolution_booster_category_values = {
    "arcana",
    "celestial",
    "spectral",
    "standard",
    "buffoon",
}
local rank_values = {
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
    "10",
    "Jack",
    "Queen",
    "King",
    "Ace",
}
local suit_values = { "Diamonds", "Clubs", "Hearts", "Spades" }
local enhancement_values = {
    "none",
    "m_bonus",
    "m_mult",
    "m_wild",
    "m_glass",
    "m_steel",
    "m_stone",
    "m_gold",
    "m_lucky",
}
local edition_values = { "none", "e_foil", "e_holo", "e_polychrome", "e_negative" }
local seal_values = { "none", "Red", "Blue", "Gold", "Purple" }

local function event_type_schema(event_type, extra_required, extra_properties)
    local properties = { type = { const = event_type } }
    for name, schema in pairs(extra_properties or {}) do
        properties[name] = schema
    end
    local required = { "type" }
    for _, name in ipairs(extra_required or {}) do
        required[#required + 1] = name
    end
    return {
        type = "object",
        properties = properties,
        required = required,
        additionalProperties = true,
    }
end

local function trigger_event_schema()
    local schema = event_type_schema("trigger", { "component" })
    schema.anyOf = {
        { type = "object", required = { "source" } },
        { type = "object", required = { "parent_order" } },
    }
    return schema
end

local function string_property(description)
    return { type = "string", description = description }
end

local function string_array(description, min_items, max_items)
    local schema = {
        type = "array",
        description = description,
        items = { type = "string" },
        uniqueItems = true,
    }
    schema.minItems = min_items
    schema.maxItems = max_items
    return schema
end

local function input_schema(properties, required)
    return {
        type = "object",
        properties = properties,
        required = required,
        additionalProperties = false,
    }
end

local function ref(name)
    return { ["$ref"] = "#/$defs/" .. name }
end

local function enum_schema(values)
    return { type = "string", enum = values }
end

local function phase_schema(phase, extra_required)
    local required = { "phase" }
    for _, name in ipairs(extra_required) do
        required[#required + 1] = name
    end
    return {
        type = "object",
        properties = { phase = { const = phase } },
        required = required,
        additionalProperties = true,
    }
end

local string_type = { type = "string" }
local integer_type = { type = "integer" }
local number_type = { type = "number" }
local boolean_type = { type = "boolean" }
local string_array_type = { type = "array", items = string_type }
local resolution_order_type = { type = "integer", minimum = 1 }

local function card_state_value_schema(state, value_schema)
    return {
        type = "object",
        properties = { state = { const = state }, value = value_schema },
        required = { "state", "value" },
    }
end

local shared_defs = {
    visibility = enum_schema(visibility_values),
    phase = enum_schema(phase_values),
    encyclopedia_set = enum_schema(encyclopedia_set_values),
    argument_value = {
        oneOf = { string_type, integer_type },
    },
    argument_constraint = {
        type = "object",
        properties = {
            allowed_values = { type = "array", items = ref("argument_value") },
            required_values = {
                type = "array",
                items = ref("argument_value"),
                uniqueItems = true,
            },
            min_items = integer_type,
            max_items = integer_type,
            minimum = number_type,
            maximum = number_type,
            unique_items = boolean_type,
            ordered = boolean_type,
            complete = boolean_type,
        },
        additionalProperties = false,
    },
    legal_action = {
        type = "object",
        properties = {
            tool = string_type,
            fixed_arguments = { type = "object", additionalProperties = ref("argument_value") },
            arguments = { type = "object", additionalProperties = ref("argument_constraint") },
        },
        required = { "tool" },
        additionalProperties = false,
    },
    named_object = {
        type = "object",
        properties = { key = string_type, name = string_type, description = string_type },
        required = { "key", "name" },
        additionalProperties = false,
    },
    deck = {
        type = "object",
        properties = { key = string_type, name = string_type, description = string_type },
        required = { "key", "name" },
        additionalProperties = false,
    },
    stake = {
        type = "object",
        properties = {
            key = string_type,
            level = integer_type,
            name = string_type,
            description = string_type,
            deck_keys = string_array_type,
        },
        required = { "key", "level", "name" },
        additionalProperties = false,
    },
    compatibility = {
        type = "object",
        properties = {
            status = string_type,
            content_mods = string_type,
            versions = string_type,
            diagnostic = string_type,
        },
        required = { "status" },
        additionalProperties = false,
    },
    active_mod = {
        type = "object",
        properties = { id = string_type, name = string_type, version = string_type },
        required = { "id", "name", "version" },
        additionalProperties = false,
    },
    modifier = {
        type = "object",
        properties = { key = string_type, name = string_type, description = string_type },
        required = { "key", "name" },
        additionalProperties = false,
    },
    hand_debuff = {
        type = "object",
        properties = {
            min_cards = integer_type,
            required_poker_hand = string_type,
            forbidden_poker_hands = {
                type = "array",
                items = string_type,
                uniqueItems = true,
            },
        },
        additionalProperties = false,
    },
    blind = {
        type = "object",
        properties = {
            id = string_type,
            slot = string_type,
            key = string_type,
            name = string_type,
            description = string_type,
            status = string_type,
            current = boolean_type,
            disabled = boolean_type,
            hand_debuff = ref("hand_debuff"),
            score_requirement = number_type,
            reward_dollars = number_type,
            chips = number_type,
            skip_tag = ref("named_object"),
        },
        required = { "id", "key", "name" },
        additionalProperties = false,
    },
    playing_card = {
        type = "object",
        properties = {
            id = string_type,
            facedown = boolean_type,
            key = string_type,
            name = string_type,
            description = string_type,
            suit = string_type,
            rank = string_type,
            enhancement = ref("modifier"),
            edition = ref("modifier"),
            seal = ref("modifier"),
            debuffed = boolean_type,
            forced_selection = boolean_type,
            chips = number_type,
        },
        required = { "id" },
        additionalProperties = false,
    },
    remaining_deck_entry = {
        type = "object",
        properties = {
            key = string_type,
            name = string_type,
            count = integer_type,
            enhancement = ref("modifier"),
            edition = ref("modifier"),
            seal = ref("modifier"),
            played_this_ante = boolean_type,
            debuffed = boolean_type,
        },
        required = { "key", "name", "count" },
        additionalProperties = false,
    },
    poker_hand = {
        type = "object",
        properties = {
            key = string_type,
            name = string_type,
            level = integer_type,
            chips = number_type,
            mult = number_type,
            played = integer_type,
        },
        required = { "key", "name", "level", "chips", "mult", "played" },
        additionalProperties = false,
    },
    owned_item = {
        type = "object",
        properties = {
            id = string_type,
            facedown = boolean_type,
            key = string_type,
            name = string_type,
            description = string_type,
            set = string_type,
            cost = number_type,
            sell_value = number_type,
            debuffed = boolean_type,
            sellable = boolean_type,
            eternal = boolean_type,
            perishable = boolean_type,
            perishable_rounds = integer_type,
            rental = boolean_type,
            pinned = boolean_type,
            edition = ref("modifier"),
            min_targets = integer_type,
            max_targets = integer_type,
        },
        required = { "id" },
        additionalProperties = false,
    },
    shop_item = {
        type = "object",
        properties = {
            id = string_type,
            category = string_type,
            key = string_type,
            name = string_type,
            description = string_type,
            cost = number_type,
            slot = string_type,
            facedown = boolean_type,
            suit = string_type,
            rank = string_type,
            enhancement = ref("modifier"),
            edition = ref("modifier"),
            seal = ref("modifier"),
            debuffed = boolean_type,
            chips = number_type,
            min_targets = integer_type,
            max_targets = integer_type,
        },
        required = { "id" },
        additionalProperties = false,
    },
    hand_order_projections = {
        type = "object",
        properties = { rank = string_array_type, suit = string_array_type },
        required = { "rank", "suit" },
        additionalProperties = false,
    },
    booster = {
        type = "object",
        properties = { category = string_type, choices_left = integer_type },
        required = { "category", "choices_left" },
        additionalProperties = false,
    },
    snapshot_common = {
        type = "object",
        properties = {
            server_name = string_type,
            server_version = string_type,
            protocol_version = { type = "string", const = "2026-07-28" },
            visibility = ref("visibility"),
            run_id = string_type,
            decision_sequence = integer_type,
            phase = ref("phase"),
            legal_actions = { type = "array", items = ref("legal_action") },
            state_hash = {
                type = "string",
                minLength = 8,
                maxLength = 8,
                pattern = "^[0-9a-f]+$",
            },
            game_version = string_type,
            steamodded_version = string_type,
            lovely_version = string_type,
            active_mods = { type = "array", items = ref("active_mod") },
            compatibility = ref("compatibility"),
            available_decks = { type = "array", items = ref("deck") },
            available_stakes = { type = "array", items = ref("stake") },
            has_saved_run = boolean_type,
            selected_deck_key = string_type,
            selected_stake_key = string_type,
            seed = string_type,
            seeded = boolean_type,
            won = boolean_type,
            ante = integer_type,
            money = number_type,
            skips = integer_type,
            deck = ref("deck"),
            stake = ref("stake"),
            tags = { type = "array", items = ref("named_object") },
            vouchers = { type = "array", items = ref("named_object") },
            jokers = { type = "array", items = ref("owned_item") },
            joker_limit = integer_type,
            consumables = { type = "array", items = ref("owned_item") },
            consumable_limit = integer_type,
            blinds = { type = "array", items = ref("blind") },
            blind_on_deck = string_type,
            current_blind = ref("blind"),
            score = number_type,
            hands_left = integer_type,
            discards_left = integer_type,
            hand = { type = "array", items = ref("playing_card") },
            remaining_deck = { type = "array", items = ref("remaining_deck_entry") },
            poker_hands = { type = "array", items = ref("poker_hand") },
            hand_order_projections = ref("hand_order_projections"),
            shop_items = { type = "array", items = ref("shop_item") },
            shop_vouchers = { type = "array", items = ref("shop_item") },
            shop_boosters = { type = "array", items = ref("shop_item") },
            reroll_cost = number_type,
            booster = ref("booster"),
            booster_items = { type = "array", items = ref("shop_item") },
            round = integer_type,
            best_hand = number_type,
            most_played_hand = string_type,
            cards_played = integer_type,
            cards_discarded = integer_type,
            cards_purchased = integer_type,
            times_rerolled = integer_type,
            new_collection = integer_type,
            defeated_by = ref("named_object"),
            deck_order = {
                type = "array",
                items = { oneOf = { string_type, ref("playing_card") } },
            },
            facedown_cards = { type = "array", items = ref("playing_card") },
            facedown_jokers = { type = "array", items = ref("owned_item") },
        },
        required = {
            "server_name",
            "server_version",
            "protocol_version",
            "visibility",
            "run_id",
            "decision_sequence",
            "phase",
            "legal_actions",
            "state_hash",
        },
        additionalProperties = false,
    },
    phase_main_menu = phase_schema("main_menu", { "available_decks", "available_stakes" }),
    phase_run_setup = phase_schema("run_setup", {
        "available_decks",
        "available_stakes",
        "selected_deck_key",
        "selected_stake_key",
    }),
    phase_blind_selection = phase_schema("blind_selection", { "blinds", "ante", "money" }),
    phase_hand_play = phase_schema("hand_play", { "hand", "hands_left", "discards_left" }),
    phase_shop = phase_schema("shop", { "shop_items", "shop_vouchers", "shop_boosters" }),
    phase_booster = phase_schema("booster", { "booster", "booster_items" }),
    phase_victory = phase_schema("victory", { "won" }),
    phase_defeat = phase_schema("defeat", { "won" }),
    state_snapshot = {
        allOf = {
            ref("snapshot_common"),
            {
                oneOf = {
                    ref("phase_main_menu"),
                    ref("phase_run_setup"),
                    ref("phase_blind_selection"),
                    ref("phase_hand_play"),
                    ref("phase_shop"),
                    ref("phase_booster"),
                    ref("phase_victory"),
                    ref("phase_defeat"),
                },
            },
        },
    },
    encyclopedia_entry = {
        type = "object",
        properties = {
            key = string_type,
            set = ref("encyclopedia_set"),
            name = string_type,
            description = string_type,
        },
        required = { "key", "set" },
        additionalProperties = false,
    },
    effect_encyclopedia = {
        type = "object",
        properties = {
            visibility = ref("visibility"),
            entries = { type = "array", items = ref("encyclopedia_entry") },
        },
        required = { "visibility", "entries" },
        additionalProperties = false,
    },
    resolution_phase = enum_schema(resolution_phase_values),
    resolution_event_type = enum_schema(resolution_event_type_values),
    resolution_component = enum_schema(resolution_component_values),
    resolution_effect_kind = enum_schema(resolution_effect_kind_values),
    created_object_kind = enum_schema(created_object_kind_values),
    resolution_destination = enum_schema(resolution_destination_values),
    resolution_card_state = enum_schema(resolution_card_state_values),
    resolution_copy_mode = enum_schema(resolution_copy_mode_values),
    resolution_capacity_resource = enum_schema(resolution_capacity_resource_values),
    resolution_allowance_resource = enum_schema(resolution_allowance_resource_values),
    resolution_card_progress_resource = enum_schema(resolution_card_progress_resource_values),
    resolution_numeric_run_rule = enum_schema(resolution_numeric_run_rule_values),
    resolution_boolean_run_rule = enum_schema(resolution_boolean_run_rule_values),
    resolution_tag_operation = enum_schema(resolution_tag_operation_values),
    resolution_blind_operation = enum_schema(resolution_blind_operation_values),
    resolution_reorder_area = enum_schema(resolution_reorder_area_values),
    resolution_reorder_method = enum_schema(resolution_reorder_method_values),
    resolution_move_zone = enum_schema(resolution_move_zone_values),
    resolution_booster_category = enum_schema(resolution_booster_category_values),
    resolution_source = {
        type = "object",
        properties = { input_target_id = string_type },
        required = { "input_target_id" },
        additionalProperties = false,
    },
    resolution_effect_scoring = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { type = "string", enum = { "chips", "mult", "x_mult", "x_chips" } },
            amount = number_type,
            chips = number_type,
            mult = number_type,
            score = number_type,
        },
        required = { "order", "kind", "amount", "chips", "mult", "score" },
        additionalProperties = false,
    },
    resolution_effect_dollars = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "dollars" },
            amount = number_type,
            money = number_type,
        },
        required = { "order", "kind", "amount", "money" },
        additionalProperties = false,
    },
    resolution_effect_destroy = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "destroy" },
            input_target_id = string_type,
        },
        required = { "order", "kind", "input_target_id" },
        additionalProperties = false,
    },
    resolution_effect_create = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "create" },
            object_kind = ref("created_object_kind"),
            destination = ref("resolution_destination"),
            key = string_type,
            rank = enum_schema(rank_values),
            suit = enum_schema(suit_values),
            enhancement = enum_schema(enhancement_values),
            edition = enum_schema(edition_values),
            seal = enum_schema(seal_values),
        },
        required = { "order", "kind", "object_kind", "destination" },
        additionalProperties = false,
    },
    resolution_effect_set_card_state = {
        allOf = {
            {
                type = "object",
                properties = {
                    order = resolution_order_type,
                    kind = { const = "set_card_state" },
                    input_target_id = string_type,
                    state = ref("resolution_card_state"),
                    value = {
                        anyOf = {
                            enum_schema(rank_values),
                            enum_schema(suit_values),
                            enum_schema(enhancement_values),
                            enum_schema(edition_values),
                            enum_schema(seal_values),
                            boolean_type,
                        },
                    },
                },
                required = { "order", "kind", "state", "value" },
                additionalProperties = false,
            },
            {
                oneOf = {
                    card_state_value_schema("rank", enum_schema(rank_values)),
                    card_state_value_schema("suit", enum_schema(suit_values)),
                    card_state_value_schema("enhancement", enum_schema(enhancement_values)),
                    card_state_value_schema("edition", enum_schema(edition_values)),
                    card_state_value_schema("seal", enum_schema(seal_values)),
                    card_state_value_schema("facedown", boolean_type),
                    card_state_value_schema("debuffed", boolean_type),
                    card_state_value_schema("forced_selection", boolean_type),
                },
            },
        },
    },
    resolution_effect_copy_overwrite = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "copy" },
            mode = { const = "overwrite" },
            source = ref("resolution_source"),
            destination = ref("resolution_source"),
        },
        required = { "order", "kind", "mode", "source", "destination" },
        additionalProperties = false,
    },
    resolution_effect_copy_create = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "copy" },
            mode = { const = "create" },
            source = ref("resolution_source"),
            object_kind = ref("created_object_kind"),
            destination = ref("resolution_destination"),
            key = string_type,
            rank = enum_schema(rank_values),
            suit = enum_schema(suit_values),
            enhancement = enum_schema(enhancement_values),
            edition = enum_schema(edition_values),
            seal = enum_schema(seal_values),
        },
        required = {
            "order",
            "kind",
            "mode",
            "source",
            "object_kind",
            "destination",
        },
        additionalProperties = false,
    },
    resolution_effect_copy = {
        oneOf = {
            ref("resolution_effect_copy_overwrite"),
            ref("resolution_effect_copy_create"),
        },
    },
    resolution_effect_poker_hand_level = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "poker_hand_level" },
            poker_hand = string_type,
            amount = integer_type,
            level = integer_type,
            chips = number_type,
            mult = number_type,
        },
        required = { "order", "kind", "poker_hand", "amount", "level", "chips", "mult" },
        additionalProperties = false,
    },
    resolution_effect_capacity = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "capacity" },
            resource = ref("resolution_capacity_resource"),
            amount = integer_type,
            value = integer_type,
        },
        required = { "order", "kind", "resource", "amount", "value" },
        additionalProperties = false,
    },
    resolution_effect_round_allowance = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "round_allowance" },
            resource = ref("resolution_allowance_resource"),
            amount = integer_type,
            base = integer_type,
            current = integer_type,
        },
        required = { "order", "kind", "resource", "amount", "base", "current" },
        additionalProperties = false,
    },
    resolution_effect_run_rule_numeric = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "run_rule" },
            rule = ref("resolution_numeric_run_rule"),
            amount = number_type,
            value = number_type,
        },
        required = { "order", "kind", "rule", "value" },
        additionalProperties = false,
    },
    resolution_effect_run_rule_boolean = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "run_rule" },
            rule = ref("resolution_boolean_run_rule"),
            enabled = boolean_type,
        },
        required = { "order", "kind", "rule", "enabled" },
        additionalProperties = false,
    },
    resolution_effect_run_rule = {
        oneOf = {
            ref("resolution_effect_run_rule_numeric"),
            ref("resolution_effect_run_rule_boolean"),
        },
    },
    resolution_effect_card_progress = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "card_progress" },
            resource = ref("resolution_card_progress_resource"),
            amount = number_type,
            value = number_type,
        },
        required = { "order", "kind", "resource", "amount", "value" },
        additionalProperties = false,
    },
    resolution_effect_tag_change = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "tag_change" },
            operation = ref("resolution_tag_operation"),
            key = string_type,
            quantity = { type = "integer", minimum = 1 },
        },
        required = { "order", "kind", "operation", "key", "quantity" },
        additionalProperties = false,
    },
    resolution_effect_blind_change_disable = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "blind_change" },
            operation = { const = "disable" },
        },
        required = { "order", "kind", "operation" },
        additionalProperties = false,
    },
    resolution_effect_blind_change_defeat = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "blind_change" },
            operation = { const = "defeat" },
        },
        required = { "order", "kind", "operation" },
        additionalProperties = false,
    },
    resolution_effect_blind_change_replace = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "blind_change" },
            operation = { const = "replace" },
            previous_key = string_type,
            key = string_type,
        },
        required = { "order", "kind", "operation", "previous_key", "key" },
        additionalProperties = false,
    },
    resolution_effect_blind_change_requirement = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "blind_change" },
            operation = { const = "requirement" },
            score_requirement = number_type,
        },
        required = { "order", "kind", "operation", "score_requirement" },
        additionalProperties = false,
    },
    resolution_effect_blind_change_hand_restriction = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "blind_change" },
            operation = { const = "hand_restriction" },
            hand_debuff = ref("hand_debuff"),
        },
        required = { "order", "kind", "operation", "hand_debuff" },
        additionalProperties = false,
    },
    resolution_effect_blind_change_draw_rule = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "blind_change" },
            operation = { const = "draw_rule" },
            cards_per_draw = { type = "integer", minimum = 0 },
        },
        required = { "order", "kind", "operation", "cards_per_draw" },
        additionalProperties = false,
    },
    resolution_effect_blind_change = {
        oneOf = {
            ref("resolution_effect_blind_change_disable"),
            ref("resolution_effect_blind_change_defeat"),
            ref("resolution_effect_blind_change_replace"),
            ref("resolution_effect_blind_change_requirement"),
            ref("resolution_effect_blind_change_hand_restriction"),
            ref("resolution_effect_blind_change_draw_rule"),
        },
    },
    resolution_effect_reorder = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "reorder" },
            area = ref("resolution_reorder_area"),
            method = ref("resolution_reorder_method"),
        },
        required = { "order", "kind", "area", "method" },
        additionalProperties = false,
    },
    resolution_effect_move_card = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "move_card" },
            input_target_id = string_type,
            from_zone = ref("resolution_move_zone"),
            to_zone = ref("resolution_move_zone"),
        },
        required = { "order", "kind", "input_target_id", "from_zone", "to_zone" },
        additionalProperties = false,
    },
    resolution_effect_open_booster = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "open_booster" },
            category = ref("resolution_booster_category"),
            size = { type = "integer", minimum = 1 },
            choices = { type = "integer", minimum = 1 },
        },
        required = { "order", "kind", "category", "size", "choices" },
        additionalProperties = false,
    },
    resolution_effect_ante_change = {
        type = "object",
        properties = {
            order = resolution_order_type,
            kind = { const = "ante_change" },
            amount = integer_type,
            ante = integer_type,
            blind_ante = integer_type,
        },
        required = { "order", "kind", "amount", "ante", "blind_ante" },
        additionalProperties = false,
    },
    resolution_effect = {
        oneOf = {
            ref("resolution_effect_scoring"),
            ref("resolution_effect_dollars"),
            ref("resolution_effect_destroy"),
            ref("resolution_effect_create"),
            ref("resolution_effect_set_card_state"),
            ref("resolution_effect_copy"),
            ref("resolution_effect_poker_hand_level"),
            ref("resolution_effect_capacity"),
            ref("resolution_effect_round_allowance"),
            ref("resolution_effect_run_rule"),
            ref("resolution_effect_card_progress"),
            ref("resolution_effect_tag_change"),
            ref("resolution_effect_blind_change"),
            ref("resolution_effect_reorder"),
            ref("resolution_effect_move_card"),
            ref("resolution_effect_open_booster"),
            ref("resolution_effect_ante_change"),
        },
    },
    resolution_event_common = {
        type = "object",
        properties = {
            order = resolution_order_type,
            phase = ref("resolution_phase"),
            type = ref("resolution_event_type"),
            component = ref("resolution_component"),
            key = string_type,
            source = ref("resolution_source"),
            cause = ref("resolution_source"),
            parent_order = resolution_order_type,
            effects = { type = "array", items = ref("resolution_effect") },
        },
        required = { "order", "phase", "type", "effects" },
        additionalProperties = false,
    },
    resolution_event_apply = event_type_schema("apply", { "component", "key" }),
    resolution_event_trigger = trigger_event_schema(),
    resolution_event_retrigger = event_type_schema(
        "retrigger",
        { "component", "source", "parent_order", "cause" }
    ),
    resolution_event_cash_out = event_type_schema(
        "cash_out",
        { "phase" },
        { phase = { const = "end_of_round" } }
    ),
    resolution_event_debuff_blocked = event_type_schema(
        "debuff_blocked",
        { "component", "source" }
    ),
    resolution_event = {
        allOf = {
            ref("resolution_event_common"),
            {
                oneOf = {
                    ref("resolution_event_apply"),
                    ref("resolution_event_trigger"),
                    ref("resolution_event_retrigger"),
                    ref("resolution_event_cash_out"),
                    ref("resolution_event_debuff_blocked"),
                },
            },
        },
    },
    resolution_trace = {
        type = "array",
        minItems = 1,
        items = ref("resolution_event"),
    },
}

local function output_schema(properties, required)
    return {
        ["$schema"] = json_schema_2020,
        type = "object",
        properties = properties,
        required = required,
        additionalProperties = false,
        ["$defs"] = shared_defs,
    }
end

local state_hash = string_property("State hash from the current decision state.")
-- Same sentinel GameMcpServer:_encode rewrites to {}. Empty {} encodes as [].
local empty_properties = { ["__balatro_mcp_empty_object_7b1021"] = true }

local phase_csv = table.concat(phase_values, ", ")
local set_csv = table.concat(encyclopedia_set_values, ", ")
local visibility_csv = table.concat(visibility_values, ", ")

local get_game_state_description = table.concat({
    "Return the current stable Balatro Decision State as a complete State Snapshot.",
    "",
    "Preconditions: none. The server waits for the next Decision State or times out.",
    "",
    "Arguments: none; the input is an empty object. Do not send visibility or state_hash. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. ").",
    "",
    "Static finite sets in the snapshot: visibility is "
        .. visibility_csv
        .. "; phase is "
        .. phase_csv
        .. ".",
    "",
    'Success structuredContent: { "state": State Snapshot } as announced in outputSchema.',
    "",
    "Tool execution errors:",
    "- INVALID_PARAMS: arguments are not an empty object",
    "- DECISION_TIMEOUT: timed out waiting for a Decision State; state is null",
    "- GAME_BLOCKED: a player-controlled overlay is blocking the Decision State; state is null",
    "- INTERNAL_ERROR: server or adapter failure",
}, "\n")

local encyclopedia_description = table.concat({
    "Return the Effect Encyclopedia of vanilla prototypes for the current profile and visibility mode.",
    "",
    "Call this tool at least once when the encyclopedia for the current visibility mode is not in context. Call it again after the visibility mode changes. A new Run in the same visibility mode does not require a repeat call. The Game MCP Server does not track whether the encyclopedia remains in context and does not refuse Semantic Actions if it has not been queried.",
    "",
    "Preconditions: none. The server waits for a stable Decision State, then reads the profile encyclopedia without advancing the run.",
    "",
    "Arguments: none; the input is an empty object. Do not send visibility or state_hash. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. ").",
    "",
    "Static finite sets: visibility is "
        .. visibility_csv
        .. "; encyclopedia entry set is "
        .. set_csv
        .. ". Fair Mode omits undiscovered identity fields and hidden legendary or secret prototypes.",
    "",
    'Success structuredContent: { "effect_encyclopedia": { "visibility": "'
        .. table.concat(visibility_values, '"|"')
        .. '", "entries": [...] } } as announced in outputSchema.',
    "",
    "Tool execution errors:",
    "- INVALID_PARAMS: arguments are not an empty object",
    "- DECISION_TIMEOUT: timed out waiting for a Decision State; state is null",
    "- GAME_BLOCKED: a player-controlled overlay is blocking the Decision State; state is null",
    "- INTERNAL_ERROR: server or adapter failure",
}, "\n")

local stake_csv_parts = {}
for index, value in ipairs(stake_values) do
    stake_csv_parts[index] = tostring(value)
end
local stake_csv = table.concat(stake_csv_parts, ", ")
local resolution_phase_csv = table.concat(resolution_phase_values, ", ")
local resolution_type_csv = table.concat(resolution_event_type_values, ", ")
local resolution_component_csv = table.concat(resolution_component_values, ", ")
local resolution_kind_csv = table.concat(resolution_effect_kind_values, ", ")
local created_kind_csv = table.concat(created_object_kind_values, ", ")
local destination_csv = table.concat(resolution_destination_values, ", ")
local card_state_csv = table.concat(resolution_card_state_values, ", ")
local copy_mode_csv = table.concat(resolution_copy_mode_values, ", ")
local capacity_resource_csv = table.concat(resolution_capacity_resource_values, ", ")
local allowance_resource_csv = table.concat(resolution_allowance_resource_values, ", ")
local card_progress_resource_csv = table.concat(resolution_card_progress_resource_values, ", ")
local numeric_run_rule_csv = table.concat(resolution_numeric_run_rule_values, ", ")
local boolean_run_rule_csv = table.concat(resolution_boolean_run_rule_values, ", ")
local tag_operation_csv = table.concat(resolution_tag_operation_values, ", ")
local blind_operation_csv = table.concat(resolution_blind_operation_values, ", ")
local resolution_reorder_area_csv = table.concat(resolution_reorder_area_values, ", ")
local resolution_reorder_method_csv = table.concat(resolution_reorder_method_values, ", ")
local resolution_move_zone_csv = table.concat(resolution_move_zone_values, ", ")
local booster_category_csv = table.concat(resolution_booster_category_values, ", ")
local area_csv = table.concat(reorder_area_values, ", ")

local action_finite_sets = "Static finite sets: visibility is "
    .. visibility_csv
    .. "; snapshot phase is "
    .. phase_csv
    .. "; Resolution Trace phase is "
    .. resolution_phase_csv
    .. "; event type is "
    .. resolution_type_csv
    .. "; component is "
    .. resolution_component_csv
    .. "; effect kind is "
    .. resolution_kind_csv
    .. "; created object_kind is "
    .. created_kind_csv
    .. "; create/copy destination is "
    .. destination_csv
    .. "; card state is "
    .. card_state_csv
    .. "; copy mode is "
    .. copy_mode_csv
    .. "; capacity resource is "
    .. capacity_resource_csv
    .. "; round allowance resource is "
    .. allowance_resource_csv
    .. "; card progress resource is "
    .. card_progress_resource_csv
    .. "; numeric run rule is "
    .. numeric_run_rule_csv
    .. "; boolean run rule is "
    .. boolean_run_rule_csv
    .. "; tag operation is "
    .. tag_operation_csv
    .. "; blind operation is "
    .. blind_operation_csv
    .. "; reorder area is "
    .. resolution_reorder_area_csv
    .. "; reorder method is "
    .. resolution_reorder_method_csv
    .. "; move zone is "
    .. resolution_move_zone_csv
    .. "; booster category is "
    .. booster_category_csv

local action_success =
    'Success structuredContent: { "state": State Snapshot, optional "resolution": Resolution Trace } as announced in outputSchema. Omit resolution when the action has no extra vanilla effects that change state or decisions.'

local function action_errors(opts)
    local errors = {
        "- INVALID_PARAMS: arguments fail the input schema or current quantity constraints; finite-set errors list allowed values",
        "- STALE_STATE: state_hash does not match the current Decision State",
        "- INVALID_PHASE: the tool is not in the current legal_actions",
    }
    if opts.has_targets then
        errors[#errors + 1] =
            "- INVALID_TARGET: a target is not in the current Legal Action Descriptor allowed values; the message lists allowed values"
    end
    errors[#errors + 1] = "- ACTION_NOT_ALLOWED: " .. opts.not_allowed
    errors[#errors + 1] =
        "- INCOMPATIBLE_VERSION: the game environment is below the minimum supported versions"
    errors[#errors + 1] =
        "- DECISION_TIMEOUT: timed out waiting for a Decision State; state is null"
    errors[#errors + 1] =
        "- GAME_BLOCKED: a player-controlled overlay is blocking the Decision State; state is null"
    errors[#errors + 1] = "- INTERNAL_ERROR: server or adapter failure"
    return errors
end

local function action_description(intro, preconditions, arguments, extra_sets, opts)
    local parts = {
        intro,
        "",
        preconditions,
        "",
        arguments,
        "",
        extra_sets and (action_finite_sets .. "; " .. extra_sets) or (action_finite_sets .. "."),
        "",
        action_success,
        "",
        "Tool execution errors:",
    }
    for _, line in ipairs(action_errors(opts)) do
        parts[#parts + 1] = line
    end
    return table.concat(parts, "\n")
end

local start_run_description = action_description(
    "Start a standard run with a deck, stake, and optional seed.",
    "Preconditions: the current Decision State lists start_run in legal_actions. Requires the current state_hash, a deck_key from the current Legal Action Descriptor, and a stake.",
    "Arguments: state_hash, deck_key, stake, optional seed. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. ").",
    "stake is "
        .. stake_csv
        .. "; seed uses uppercase A-Z and digits 1-9, length 1-8. deck_key is a dynamic finite set from the current Legal Action Descriptor.",
    { not_allowed = "the selected stake is locked for this deck" }
)

local select_blind_description = action_description(
    "Accept the selected Blind.",
    "Preconditions: the current Decision State lists select_blind in legal_actions. Requires the current state_hash and a blind_id from the current Legal Action Descriptor.",
    "Arguments: state_hash and blind_id. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). blind_id is a dynamic finite set from the current Legal Action Descriptor.",
    nil,
    {
        has_targets = true,
        not_allowed = "the current Blind cannot be selected",
    }
)

local skip_blind_description = action_description(
    "Skip an eligible Blind and receive its tag.",
    "Preconditions: the current Decision State lists skip_blind in legal_actions. Requires the current state_hash and a skippable blind_id from the current Legal Action Descriptor.",
    "Arguments: state_hash and blind_id. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). blind_id is a dynamic finite set from the current Legal Action Descriptor.",
    nil,
    {
        has_targets = true,
        not_allowed = "the current Blind cannot be skipped",
    }
)

local reroll_boss_description = action_description(
    "Reroll the current Boss Blind when allowed.",
    "Preconditions: the current Decision State lists reroll_boss in legal_actions. Requires the current state_hash.",
    "Arguments: state_hash only. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. ").",
    nil,
    { not_allowed = "Boss Blind reroll is not available" }
)

local play_hand_description = action_description(
    "Play one to five unique cards in the supplied processing order.",
    "Preconditions: the current Decision State lists play_hand in legal_actions. Requires the current state_hash and 1 to 5 unique card_ids from the current Legal Action Descriptor, in processing order.",
    "Arguments: state_hash and card_ids. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). card_ids are a unique dynamic finite set; array order is processing order.",
    nil,
    {
        has_targets = true,
        not_allowed = "playing a hand is not allowed",
    }
)

local discard_cards_description = action_description(
    "Discard one to five unique cards in the supplied processing order.",
    "Preconditions: the current Decision State lists discard_cards in legal_actions. Requires the current state_hash and 1 to 5 unique card_ids from the current Legal Action Descriptor, in processing order.",
    "Arguments: state_hash and card_ids. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). card_ids are a unique dynamic finite set; array order is processing order.",
    nil,
    {
        has_targets = true,
        not_allowed = "discarding is not allowed",
    }
)

local reorder_cards_description = action_description(
    "Apply a complete left-to-right ordering to the hand or Joker area.",
    "Preconditions: the current Decision State lists reorder_cards in legal_actions. Requires the current state_hash, area, and a complete unique permutation of that area's target IDs in processing order.",
    "Arguments: state_hash, area, and ordered_ids. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). ordered_ids must be a complete unique permutation of the current Legal Action Descriptor allowed values; array order is processing order.",
    "area is " .. area_csv .. ".",
    {
        has_targets = true,
        not_allowed = "the current rules rejected the reorder",
    }
)

local use_consumable_description = action_description(
    "Use an owned consumable with optional unique target_ids in processing order.",
    "Preconditions: the current Decision State lists use_consumable in legal_actions. Requires the current state_hash and a consumable_id from the current Legal Action Descriptor. target_ids are required only when that variant lists them.",
    "Arguments: state_hash, consumable_id, optional target_ids. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). consumable_id and target_ids are dynamic finite sets; target_ids are unique and array order is processing order.",
    nil,
    {
        has_targets = true,
        not_allowed = "the consumable cannot be used now",
    }
)

local sell_owned_item_description = action_description(
    "Sell an eligible owned Joker or consumable.",
    "Preconditions: the current Decision State lists sell_owned_item in legal_actions. Requires the current state_hash and an item_id from the current Legal Action Descriptor.",
    "Arguments: state_hash and item_id. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). item_id is a dynamic finite set from the current Legal Action Descriptor.",
    nil,
    {
        has_targets = true,
        not_allowed = "the item cannot be sold now",
    }
)

local buy_shop_item_description = action_description(
    "Buy a Joker, consumable, or playing card from the shop.",
    "Preconditions: the current Decision State lists buy_shop_item in legal_actions. Requires the current state_hash and an item_id from the current Legal Action Descriptor.",
    "Arguments: state_hash and item_id. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). item_id is a dynamic finite set from the current Legal Action Descriptor.",
    nil,
    {
        has_targets = true,
        not_allowed = "the shop item cannot be bought now",
    }
)

local buy_and_use_shop_item_description = action_description(
    "Buy and immediately use an eligible shop consumable.",
    "Preconditions: the current Decision State lists buy_and_use_shop_item in legal_actions. Requires the current state_hash and an item_id from the current Legal Action Descriptor. target_ids are required only when that variant lists them.",
    "Arguments: state_hash, item_id, optional target_ids. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). item_id and target_ids are dynamic finite sets; target_ids are unique and array order is processing order.",
    nil,
    {
        has_targets = true,
        not_allowed = "the shop consumable cannot be bought and used now",
    }
)

local redeem_voucher_description = action_description(
    "Buy and apply the selected voucher.",
    "Preconditions: the current Decision State lists redeem_voucher in legal_actions. Requires the current state_hash and a voucher_id from the current Legal Action Descriptor.",
    "Arguments: state_hash and voucher_id. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). voucher_id is a dynamic finite set from the current Legal Action Descriptor.",
    nil,
    {
        has_targets = true,
        not_allowed = "the voucher cannot be redeemed now",
    }
)

local open_booster_description = action_description(
    "Buy and open the selected booster pack.",
    "Preconditions: the current Decision State lists open_booster in legal_actions. Requires the current state_hash and a booster_id from the current Legal Action Descriptor.",
    "Arguments: state_hash and booster_id. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). booster_id is a dynamic finite set from the current Legal Action Descriptor.",
    nil,
    {
        has_targets = true,
        not_allowed = "the booster pack cannot be opened now",
    }
)

local reroll_shop_description = action_description(
    "Pay the displayed cost to reroll the shop.",
    "Preconditions: the current Decision State lists reroll_shop in legal_actions. Requires the current state_hash.",
    "Arguments: state_hash only. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. ").",
    nil,
    { not_allowed = "shop reroll is not available" }
)

local leave_shop_description = action_description(
    "Leave the shop and continue to Blind selection.",
    "Preconditions: the current Decision State lists leave_shop in legal_actions. Requires the current state_hash.",
    "Arguments: state_hash only. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. ").",
    nil,
    { not_allowed = "leaving the shop is not allowed" }
)

local choose_booster_item_description = action_description(
    "Choose or use an item from the current booster pack.",
    "Preconditions: the current Decision State lists choose_booster_item in legal_actions. Requires the current state_hash and an item_id from the current Legal Action Descriptor. target_ids are required only when that variant lists them.",
    "Arguments: state_hash, item_id, optional target_ids. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. "). item_id and target_ids are dynamic finite sets; target_ids are unique and array order is processing order.",
    nil,
    {
        has_targets = true,
        not_allowed = "the booster item cannot be chosen now",
    }
)

local skip_booster_description = action_description(
    "Leave the current booster pack without further choices.",
    "Preconditions: the current Decision State lists skip_booster in legal_actions. Requires the current state_hash.",
    "Arguments: state_hash only. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. ").",
    nil,
    { not_allowed = "skipping the booster is not allowed" }
)

local continue_endless_description = action_description(
    "Continue a won standard run in Endless Mode.",
    "Preconditions: the current Decision State lists continue_endless in legal_actions. Requires the current state_hash.",
    "Arguments: state_hash only. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. ").",
    nil,
    { not_allowed = "Endless Mode cannot be continued now" }
)

local return_to_menu_description = action_description(
    "Return to the main menu from a terminal run state.",
    "Preconditions: the current Decision State lists return_to_menu in legal_actions. Requires the current state_hash.",
    "Arguments: state_hash only. Do not send visibility. Visibility is the persistent in-game Mod setting ("
        .. visibility_csv
        .. ").",
    nil,
    { not_allowed = "returning to the menu is not allowed" }
)

local action_output = output_schema({
    state = ref("state_snapshot"),
    resolution = ref("resolution_trace"),
}, { "state" })

local tools = {
    {
        name = "get_game_state",
        description = get_game_state_description,
        inputSchema = input_schema(empty_properties),
        outputSchema = output_schema({ state = ref("state_snapshot") }, { "state" }),
    },
    {
        name = "get_effect_encyclopedia",
        description = encyclopedia_description,
        inputSchema = input_schema(empty_properties),
        outputSchema = output_schema({
            effect_encyclopedia = ref("effect_encyclopedia"),
        }, { "effect_encyclopedia" }),
    },
    {
        name = "start_run",
        description = start_run_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            deck_key = string_property(
                "Internal deck key from the current Legal Action Descriptor."
            ),
            stake = {
                type = "integer",
                description = "Stake level.",
                enum = stake_values,
            },
            seed = {
                type = "string",
                description = "Optional fixed seed using one to eight uppercase letters or digits 1-9.",
                minLength = 1,
                maxLength = 8,
                pattern = "^[A-Z1-9]+$",
            },
        }, { "state_hash", "deck_key", "stake" }),
        outputSchema = action_output,
    },
    {
        name = "select_blind",
        description = select_blind_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            blind_id = string_property("Blind target ID from the current Legal Action Descriptor."),
        }, { "state_hash", "blind_id" }),
        outputSchema = action_output,
    },
    {
        name = "skip_blind",
        description = skip_blind_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            blind_id = string_property("Blind target ID from the current Legal Action Descriptor."),
        }, { "state_hash", "blind_id" }),
        outputSchema = action_output,
    },
    {
        name = "reroll_boss",
        description = reroll_boss_description,
        inputSchema = input_schema({ state_hash = state_hash }, { "state_hash" }),
        outputSchema = action_output,
    },
    {
        name = "play_hand",
        description = play_hand_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            card_ids = string_array("Unique card target IDs in processing order.", 1, 5),
        }, { "state_hash", "card_ids" }),
        outputSchema = action_output,
    },
    {
        name = "discard_cards",
        description = discard_cards_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            card_ids = string_array("Unique card target IDs in processing order.", 1, 5),
        }, { "state_hash", "card_ids" }),
        outputSchema = action_output,
    },
    {
        name = "reorder_cards",
        description = reorder_cards_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            area = {
                type = "string",
                description = "Area to reorder.",
                enum = reorder_area_values,
            },
            ordered_ids = string_array(
                "Complete unique permutation of the area target IDs in left-to-right processing order.",
                1
            ),
        }, { "state_hash", "area", "ordered_ids" }),
        outputSchema = action_output,
    },
    {
        name = "use_consumable",
        description = use_consumable_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            consumable_id = string_property(
                "Consumable target ID from the current Legal Action Descriptor."
            ),
            target_ids = string_array("Optional unique target IDs in processing order.", 1),
        }, { "state_hash", "consumable_id" }),
        outputSchema = action_output,
    },
    {
        name = "buy_shop_item",
        description = buy_shop_item_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            item_id = string_property(
                "Shop item target ID from the current Legal Action Descriptor."
            ),
        }, { "state_hash", "item_id" }),
        outputSchema = action_output,
    },
    {
        name = "buy_and_use_shop_item",
        description = buy_and_use_shop_item_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            item_id = string_property(
                "Shop item target ID from the current Legal Action Descriptor."
            ),
            target_ids = string_array("Optional unique target IDs in processing order.", 1),
        }, { "state_hash", "item_id" }),
        outputSchema = action_output,
    },
    {
        name = "redeem_voucher",
        description = redeem_voucher_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            voucher_id = string_property(
                "Voucher target ID from the current Legal Action Descriptor."
            ),
        }, { "state_hash", "voucher_id" }),
        outputSchema = action_output,
    },
    {
        name = "open_booster",
        description = open_booster_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            booster_id = string_property(
                "Booster target ID from the current Legal Action Descriptor."
            ),
        }, { "state_hash", "booster_id" }),
        outputSchema = action_output,
    },
    {
        name = "reroll_shop",
        description = reroll_shop_description,
        inputSchema = input_schema({ state_hash = state_hash }, { "state_hash" }),
        outputSchema = action_output,
    },
    {
        name = "sell_owned_item",
        description = sell_owned_item_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            item_id = string_property(
                "Owned Joker or consumable target ID from the current Legal Action Descriptor."
            ),
        }, { "state_hash", "item_id" }),
        outputSchema = action_output,
    },
    {
        name = "leave_shop",
        description = leave_shop_description,
        inputSchema = input_schema({ state_hash = state_hash }, { "state_hash" }),
        outputSchema = action_output,
    },
    {
        name = "choose_booster_item",
        description = choose_booster_item_description,
        inputSchema = input_schema({
            state_hash = state_hash,
            item_id = string_property(
                "Booster item target ID from the current Legal Action Descriptor."
            ),
            target_ids = string_array("Optional unique target IDs in processing order.", 1),
        }, { "state_hash", "item_id" }),
        outputSchema = action_output,
    },
    {
        name = "skip_booster",
        description = skip_booster_description,
        inputSchema = input_schema({ state_hash = state_hash }, { "state_hash" }),
        outputSchema = action_output,
    },
    {
        name = "continue_endless",
        description = continue_endless_description,
        inputSchema = input_schema({ state_hash = state_hash }, { "state_hash" }),
        outputSchema = action_output,
    },
    {
        name = "return_to_menu",
        description = return_to_menu_description,
        inputSchema = input_schema({ state_hash = state_hash }, { "state_hash" }),
        outputSchema = action_output,
    },
}

local by_name = {}
for _, tool in ipairs(tools) do
    by_name[tool.name] = tool
end

local target_arguments = {
    select_blind = { blind_id = "scalar" },
    skip_blind = { blind_id = "scalar" },
    play_hand = { card_ids = "array" },
    discard_cards = { card_ids = "array" },
    reorder_cards = { ordered_ids = "complete" },
    use_consumable = { consumable_id = "scalar", target_ids = "array" },
    buy_shop_item = { item_id = "scalar" },
    buy_and_use_shop_item = { item_id = "scalar", target_ids = "array" },
    redeem_voucher = { voucher_id = "scalar" },
    open_booster = { booster_id = "scalar" },
    sell_owned_item = { item_id = "scalar" },
    choose_booster_item = { item_id = "scalar", target_ids = "array" },
}

local function array_length(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil
        end
        count = count + 1
    end
    return count
end

local function format_allowed_values(values)
    local parts = {}
    for index, value in ipairs(values) do
        parts[index] = tostring(value)
    end
    return table.concat(parts, ", ")
end

-- ponytail: JSON Schema 2020-12 subset ($ref, allOf, oneOf, const, enum); full validator if more keywords appear
local function validate(schema, value, path, root)
    root = root or schema
    if schema["$ref"] then
        local name = type(schema["$ref"]) == "string" and schema["$ref"]:match("^#/%$defs/([^/]+)$")
        local resolved = name and root["$defs"] and root["$defs"][name]
        if not resolved then
            return path .. " has an unresolved $ref"
        end
        return validate(resolved, value, path, root)
    end
    if schema.allOf then
        for _, part in ipairs(schema.allOf) do
            local child_error = validate(part, value, path, root)
            if child_error then
                return child_error
            end
        end
    end
    if schema.oneOf then
        local matches = 0
        for _, part in ipairs(schema.oneOf) do
            if not validate(part, value, path, root) then
                matches = matches + 1
            end
        end
        if matches ~= 1 then
            return path .. " must match exactly one schema"
        end
    end
    if schema.anyOf then
        local matched = false
        for _, part in ipairs(schema.anyOf) do
            if not validate(part, value, path, root) then
                matched = true
                break
            end
        end
        if not matched then
            return path .. " must match at least one schema"
        end
    end

    local expected = schema.type
    local value_type = type(value)
    if expected == "integer" then
        if value_type ~= "number" or value % 1 ~= 0 then
            return path .. " must be an integer"
        end
    elseif expected == "number" then
        if value_type ~= "number" then
            return path .. " must be a number"
        end
    elseif expected == "array" then
        if value_type ~= "table" then
            return path .. " must be an array"
        end
        local length = array_length(value)
        if not length then
            return path .. " must be an array"
        end
        if schema.minItems and length < schema.minItems then
            return path .. " must contain at least " .. schema.minItems .. " items"
        end
        if schema.maxItems and length > schema.maxItems then
            return path .. " must contain at most " .. schema.maxItems .. " items"
        end
        local seen = {}
        for index = 1, length do
            if schema.items then
                local child_error =
                    validate(schema.items, value[index], path .. "[" .. index .. "]", root)
                if child_error then
                    return child_error
                end
            end
            if schema.uniqueItems then
                if seen[value[index]] then
                    return path .. " must contain unique items"
                end
                seen[value[index]] = true
            end
        end
    elseif expected == "object" then
        if value_type ~= "table" then
            return path .. " must be an object"
        end
        for _, required in ipairs(schema.required or {}) do
            if value[required] == nil then
                return path .. "." .. required .. " is required"
            end
        end
        for key, child in pairs(value) do
            if type(key) ~= "string" then
                return path .. " must be an object"
            end
            local child_schema = schema.properties and schema.properties[key]
            if not child_schema then
                if schema.additionalProperties == false then
                    return path .. "." .. key .. " is not allowed"
                end
                child_schema = type(schema.additionalProperties) == "table"
                        and schema.additionalProperties
                    or nil
            end
            if child_schema then
                local child_error = validate(child_schema, child, path .. "." .. key, root)
                if child_error then
                    return child_error
                end
            end
        end
    elseif expected and value_type ~= expected then
        return path .. " must be a " .. expected
    end

    if schema.minimum and value < schema.minimum then
        return path .. " must be at least " .. schema.minimum
    end
    if schema.maximum and value > schema.maximum then
        return path .. " must be at most " .. schema.maximum
    end
    if schema.minLength and #value < schema.minLength then
        return path .. " must contain at least " .. schema.minLength .. " characters"
    end
    if schema.maxLength and #value > schema.maxLength then
        return path .. " must contain at most " .. schema.maxLength .. " characters"
    end
    if schema.pattern and not value:match(schema.pattern) then
        return path .. " has an unsupported format"
    end
    if schema.const ~= nil and value ~= schema.const then
        return path .. " must equal " .. tostring(schema.const)
    end
    if schema.enum then
        for _, allowed in ipairs(schema.enum) do
            if value == allowed then
                return nil
            end
        end
        return path
            .. " has an unsupported value; allowed values: "
            .. format_allowed_values(schema.enum)
    end
end

---@return table[]
function ToolCatalog.list()
    return tools
end

---@param name string
---@return table?
function ToolCatalog.get(name)
    return by_name[name]
end

---@param name string
---@param arguments table
---@return string?
function ToolCatalog.validate(name, arguments)
    local tool = by_name[name]
    if not tool then
        return "Unknown tool"
    end
    return validate(tool.inputSchema, arguments, "arguments")
end

---@param schema table
---@param value any
---@return string?
function ToolCatalog.validate_schema(schema, value)
    return validate(schema, value, "value", schema)
end

---@param name string
---@param value table
---@return string?
function ToolCatalog.validate_output(name, value)
    local tool = by_name[name]
    if not tool then
        return "Unknown tool"
    end
    return validate(tool.outputSchema, value, "value", tool.outputSchema)
end

---@param name string
---@param state table
---@return string?
function ToolCatalog.validate_output_state(name, state)
    local tool = by_name[name]
    local schema = tool and tool.outputSchema.properties.state
    if not schema then
        return "value.state is not available for this tool"
    end
    return validate(schema, state, "value.state", tool.outputSchema)
end

---@param arguments table
---@param constraints table<string, table>?
---@param target_modes table<string, "scalar"|"array"|"complete">?
---@return string?
function ToolCatalog.validate_constraints(arguments, constraints, target_modes)
    target_modes = target_modes or {}
    for argument, constraint in pairs(constraints or {}) do
        local value = arguments[argument]
        if
            constraint.min_items
            and constraint.min_items > 0
            and (value == nil or #value < constraint.min_items)
        then
            return argument .. " must contain at least " .. constraint.min_items .. " items"
        end
        if constraint.required_values and #constraint.required_values > 0 then
            if type(value) ~= "table" then
                return argument
                    .. " must include required values: "
                    .. format_allowed_values(constraint.required_values)
            end
            for _, required in ipairs(constraint.required_values) do
                local included = false
                for _, candidate in ipairs(value) do
                    if candidate == required then
                        included = true
                        break
                    end
                end
                if not included then
                    return argument
                        .. " must include required values: "
                        .. format_allowed_values(constraint.required_values)
                end
            end
        end
        if value ~= nil then
            if constraint.max_items and #value > constraint.max_items then
                return argument .. " must contain at most " .. constraint.max_items .. " items"
            end
            if constraint.minimum and value < constraint.minimum then
                return argument .. " must be at least " .. constraint.minimum
            end
            if constraint.maximum and value > constraint.maximum then
                return argument .. " must be at most " .. constraint.maximum
            end
            if constraint.allowed_values and not target_modes[argument] then
                local allowed = false
                for _, candidate in ipairs(constraint.allowed_values) do
                    if value == candidate then
                        allowed = true
                        break
                    end
                end
                if not allowed then
                    return argument
                        .. " has an unsupported value; allowed values: "
                        .. format_allowed_values(constraint.allowed_values)
                end
            end
        end
    end
end

---@param name string
---@return table<string, "scalar"|"array"|"complete">
function ToolCatalog.target_arguments(name)
    return target_arguments[name] or {}
end

return ToolCatalog
