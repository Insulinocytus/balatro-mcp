local socket = require("socket")

---@class JsonCodec
---@field encode fun(value: any): string
---@field decode fun(value: string): any

---@class McpImplementationInfo
---@field name string
---@field title? string
---@field version string
---@field description? string

---@class GameMcpServerOptions
---@field json JsonCodec
---@field port? integer
---@field worker_source string
---@field server_info McpImplementationInfo
---@field adapter BalatroAdapter
---@field tool_catalog ToolCatalog
---@field visibility? "fair"|"omniscient"
---@field request_timeout_ms? integer
---@field max_header_bytes? integer
---@field max_body_bytes? integer
---@field log? fun(level: "error"|"info"|"debug", message: string)
---@field log_enabled? fun(level: "error"|"info"|"debug"): boolean

---@class McpHttpRequest
---@field id integer
---@field method string
---@field path string
---@field version string
---@field headers table<string, string>
---@field body string
---@field deadline? number

---@class McpHttpResponse
---@field id? integer
---@field status integer
---@field headers table<string, string>
---@field body string

---@class McpServerStatus
---@field state "stopped"|"starting"|"listening"|"error"
---@field port integer
---@field error? string

---@class BalatroAdapterError
---@field code string
---@field message string
---@field observe_block? string
---@field diagnostic? table<string, any>
---@field path? string
---@field raw_reference? string

---@class BalatroAdapterObservation
---@field run_id string
---@field decision_sequence integer
---@field phase string
---@field public_state table<string, any> Filtered player-visible decision data.
---@field hidden_state? table<string, any> Filtered current hidden data for omniscient debugging.
---@field ui? table<string, any>

---@class BalatroAdapter
---@field observe fun(self: BalatroAdapter, visibility: "fair"|"omniscient"): BalatroAdapterObservation?, BalatroAdapterError?
---@field encyclopedia fun(self: BalatroAdapter, visibility: "fair"|"omniscient"): table?, BalatroAdapterError?
---@field execute fun(self: BalatroAdapter, action: table): table?, BalatroAdapterError?
---@field finish_resolution fun(self: BalatroAdapter, context: table): table?, BalatroAdapterError?
---@field abandon_resolution fun(self: BalatroAdapter, context?: table, reason?: string)

---@class ToolCatalog
---@field list fun(): table[]
---@field get fun(name: string): table?
---@field validate fun(name: string, arguments: table): string?
---@field validate_output fun(name: string, value: table): string?
---@field validate_output_state fun(name: string, state: table): string?
---@field validate_constraints fun(arguments: table, constraints: table<string, table>?, target_modes?: table<string, "scalar"|"array"|"complete">): string?
---@field target_arguments fun(name: string): table<string, "scalar"|"array"|"complete">

---@class GameMcpServer
---@field json JsonCodec
---@field port integer
---@field worker_source string
---@field server_info McpImplementationInfo
---@field adapter BalatroAdapter
---@field tool_catalog ToolCatalog
---@field visibility "fair"|"omniscient"
---@field hidden_public_ids table<string, string>
---@field hidden_area_order table<string, string[]>
---@field hidden_serial integer
---@field rotate_hidden table<string, boolean>
---@field preserve_hidden_area? string
---@field hidden_run_id? string
---@field request_timeout_ms integer
---@field max_header_bytes integer
---@field max_body_bytes integer
---@field channels table<string, love.Channel>
---@field channel_names table<string, string>
---@field status McpServerStatus
---@field thread? love.Thread
---@field previous_threaderror? fun(thread: love.Thread, error_message: string)
---@field threaderror_handler? fun(thread: love.Thread, error_message: string)
---@field pending_action? table
---@field log? fun(level: "error"|"info"|"debug", message: string)
---@field log_enabled? fun(level: "error"|"info"|"debug"): boolean
---@field trace_serial integer
---@field active_trace? table
---@field last_run_id? string
---@field last_snapshot_summary? table
---@field last_observe_log? string
---@field last_observe_error? BalatroAdapterError
---@field tool_log_name? string
local GameMcpServer = {}
GameMcpServer.__index = GameMcpServer

local instance_count = 0
local protocol_version = "2026-07-28"
local empty_object_key = "__balatro_mcp_empty_object_7b1021"
local null_value_key = "__balatro_mcp_null_7b1021"

local function empty_object()
    return { [empty_object_key] = true }
end

local function json_null()
    return { [null_value_key] = true }
end

local function table_is_array(value)
    local count = 0
    local maximum = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end
        count = count + 1
        maximum = math.max(maximum, key)
    end
    return count > 0 and count == maximum
end

local function sorted_keys(value)
    local keys = {}
    for key in pairs(value) do
        assert(type(key) == "string", "canonical objects require string keys")
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function canonical_encode(json, value)
    local value_type = type(value)
    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        return json.encode(value)
    end
    assert(value_type == "table", "canonical values must be JSON-compatible")

    local encoded = {}
    if table_is_array(value) then
        for index, child in ipairs(value) do
            encoded[index] = canonical_encode(json, child)
        end
        return "[" .. table.concat(encoded, ",") .. "]"
    end

    for _, key in ipairs(sorted_keys(value)) do
        encoded[#encoded + 1] = json.encode(key) .. ":" .. canonical_encode(json, value[key])
    end
    return "{" .. table.concat(encoded, ",") .. "}"
end

---@param value string
---@return string
local function hash_hex(value)
    local digest = love.data.hash("sha256", value)
    ---@cast digest string
    local encoded = love.data.encode("string", "hex", digest)
    ---@cast encoded string
    return encoded
end

local function copy_value(value)
    if type(value) ~= "table" then
        return value
    end
    local copied = {}
    for key, child in pairs(value) do
        copied[key] = copy_value(child)
    end
    return copied
end

local function invert_target_map(target_map)
    local refs = {}
    for public_id, ref in pairs(target_map or {}) do
        refs[ref] = public_id
    end
    return refs
end

local function remap_source(source, refs, path)
    if type(source) ~= "table" or type(source.input_target_id) ~= "string" then
        return nil, path .. " must contain an internal input target reference"
    end
    local raw_reference = source.input_target_id
    local public_id = refs[raw_reference]
    if not public_id then
        return nil, path .. ".input_target_id is not an action input", raw_reference
    end
    return { input_target_id = public_id }
end

local function prepare_resolution(resolution, target_map)
    if resolution == nil or (type(resolution) == "table" and resolution[1] == nil) then
        return nil
    end
    if type(resolution) ~= "table" then
        return nil, "value.resolution must be an array"
    end
    local copied = copy_value(resolution)
    local refs = invert_target_map(target_map)
    local orders = {}
    local event_orders = {}
    local previous_event_order = 0

    for event_index, event in ipairs(copied) do
        local event_path = "value.resolution[" .. event_index .. "]"
        if type(event.order) == "number" and event.order % 1 == 0 then
            if orders[event.order] then
                return nil, event_path .. ".order duplicates global order " .. event.order
            end
            if event.order <= previous_event_order then
                return nil, event_path .. ".order is not in activation order"
            end
            orders[event.order] = event_path .. ".order"
            event_orders[event.order] = event
            previous_event_order = event.order
        end
        if event.source then
            local mapped, map_error, raw_reference =
                remap_source(event.source, refs, event_path .. ".source")
            if not mapped then
                return nil, map_error, raw_reference
            end
            event.source = mapped
        end
        if event.cause then
            local mapped, map_error, raw_reference =
                remap_source(event.cause, refs, event_path .. ".cause")
            if not mapped then
                return nil, map_error, raw_reference
            end
            event.cause = mapped
        end
        local previous_effect_order = 0
        for effect_index, effect in ipairs(event.effects or {}) do
            local effect_path = event_path .. ".effects[" .. effect_index .. "]"
            if effect.input_target_id then
                local raw_reference = effect.input_target_id
                effect.input_target_id = refs[raw_reference]
                if not effect.input_target_id then
                    return nil,
                        effect_path .. ".input_target_id is not an action input",
                        raw_reference
                end
            end
            for _, field in ipairs({ "source", "destination" }) do
                if type(effect[field]) == "table" then
                    local mapped, map_error, raw_reference =
                        remap_source(effect[field], refs, effect_path .. "." .. field)
                    if not mapped then
                        return nil, map_error, raw_reference
                    end
                    effect[field] = mapped
                end
            end
            if type(effect.order) == "number" and effect.order % 1 == 0 then
                if orders[effect.order] then
                    return nil, effect_path .. ".order duplicates global order " .. effect.order
                end
                if effect.order <= previous_effect_order then
                    return nil, effect_path .. ".order is not in application order"
                end
                if type(event.order) == "number" and effect.order <= event.order then
                    return nil, effect_path .. ".order must follow its event"
                end
                orders[effect.order] = effect_path .. ".order"
                previous_effect_order = effect.order
            end
        end
    end

    for event_index, event in ipairs(copied) do
        local event_path = "value.resolution[" .. event_index .. "]"
        if event.parent_order then
            if not event_orders[event.parent_order] then
                return nil, event_path .. ".parent_order does not reference an event"
            end
            if type(event.order) == "number" and event.parent_order >= event.order then
                return nil, event_path .. ".parent_order must precede the child event"
            end
        end
    end

    return copied
end

local function same_list(left, right)
    if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
        return false
    end
    for index = 1, #left do
        if left[index] ~= right[index] then
            return false
        end
    end
    return true
end

local function is_subsequence(part, whole)
    local next_index = 1
    for index = 1, #whole do
        if part[next_index] == whole[index] then
            next_index = next_index + 1
            if next_index > #part then
                return true
            end
        end
    end
    return next_index > #part
end

local function area_target_refs(cards, facedown_only)
    local refs = {}
    for _, card in ipairs(cards or {}) do
        if type(card) == "table" and type(card.target_ref) == "string" then
            if not facedown_only or card.facedown then
                refs[#refs + 1] = card.target_ref
            end
        end
    end
    return refs
end

local function error_result(id, code, message, data)
    return {
        jsonrpc = "2.0",
        id = id == nil and json_null() or id,
        error = {
            code = code,
            message = message,
            data = data,
        },
    }
end

---@param options GameMcpServerOptions
---@return GameMcpServer
function GameMcpServer.new(options)
    assert(type(options) == "table", "options must be a table")
    assert(type(options.json) == "table", "options.json is required")
    assert(type(options.worker_source) == "string", "options.worker_source is required")
    assert(type(options.server_info) == "table", "options.server_info is required")
    assert(type(options.adapter) == "table", "options.adapter is required")
    assert(type(options.adapter.observe) == "function", "adapter.observe is required")
    assert(type(options.adapter.encyclopedia) == "function", "adapter.encyclopedia is required")
    assert(type(options.adapter.execute) == "function", "adapter.execute is required")
    assert(
        type(options.adapter.finish_resolution) == "function",
        "adapter.finish_resolution is required"
    )
    assert(
        type(options.adapter.abandon_resolution) == "function",
        "adapter.abandon_resolution is required"
    )
    assert(type(options.tool_catalog) == "table", "options.tool_catalog is required")

    instance_count = instance_count + 1
    local channel_prefix = "balatro_mcp_" .. instance_count .. "_"

    return setmetatable({
        json = options.json,
        port = options.port or 18790,
        worker_source = options.worker_source,
        server_info = options.server_info,
        adapter = options.adapter,
        tool_catalog = options.tool_catalog,
        visibility = options.visibility == "omniscient" and "omniscient" or "fair",
        hidden_public_ids = {},
        hidden_area_order = {},
        hidden_serial = 0,
        rotate_hidden = {},
        request_timeout_ms = options.request_timeout_ms or 30000,
        max_header_bytes = options.max_header_bytes or 16384,
        max_body_bytes = options.max_body_bytes or 1048576,
        log = options.log,
        log_enabled = options.log_enabled,
        trace_serial = 0,
        channels = {
            requests = love.thread.getChannel(channel_prefix .. "requests"),
            responses = love.thread.getChannel(channel_prefix .. "responses"),
            status = love.thread.getChannel(channel_prefix .. "status"),
            control = love.thread.getChannel(channel_prefix .. "control"),
        },
        channel_names = {
            requests = channel_prefix .. "requests",
            responses = channel_prefix .. "responses",
            status = channel_prefix .. "status",
            control = channel_prefix .. "control",
        },
        status = { state = "stopped", port = options.port or 18790 },
    }, GameMcpServer)
end

---@param value any
---@return string
function GameMcpServer:_encode(value)
    local encoded = self.json.encode(value)
    encoded = encoded:gsub('{"' .. empty_object_key .. '":true}', "{}")
    encoded = encoded:gsub('{"' .. null_value_key .. '":true}', "null")
    return encoded
end

function GameMcpServer:_current_visibility()
    if self.visibility == "omniscient" then
        return "omniscient"
    end
    return "fair"
end

function GameMcpServer:set_visibility(visibility)
    local next_visibility = visibility == "omniscient" and "omniscient" or "fair"
    if self.visibility == next_visibility then
        return
    end
    self.visibility = next_visibility
    self.hidden_public_ids = {}
end

---@param status integer
---@param value table
---@return McpHttpResponse
function GameMcpServer:_json_response(status, value)
    return {
        status = status,
        headers = { ["Content-Type"] = "application/json" },
        body = self:_encode(value),
    }
end

local reserved_snapshot_keys = {
    server_name = true,
    server_version = true,
    protocol_version = true,
    visibility = true,
    run_id = true,
    decision_sequence = true,
    phase = true,
    state_hash = true,
}

function GameMcpServer:_public_target_id(target_reference, facedown)
    if not facedown then
        self.hidden_public_ids[target_reference] = nil
        return target_reference
    end
    local existing = self.hidden_public_ids[target_reference]
    if existing and not self.rotate_hidden[target_reference] then
        return existing
    end
    self.hidden_serial = (self.hidden_serial or 0) + 1
    local public_id = "h:" .. self.hidden_serial
    self.hidden_public_ids[target_reference] = public_id
    self.rotate_hidden[target_reference] = nil
    return public_id
end

function GameMcpServer:_prepare_hidden_rotation(observation)
    if type(observation) ~= "table" or type(observation.public_state) ~= "table" then
        return
    end
    if self.hidden_run_id ~= observation.run_id then
        self.hidden_run_id = observation.run_id
        self.hidden_public_ids = {}
        self.hidden_area_order = {}
    end
    self.rotate_hidden = {}
    local preserve = self.preserve_hidden_area
    self.preserve_hidden_area = nil
    local public_state = observation.public_state
    for _, area in ipairs({ "hand", "jokers" }) do
        local current = area_target_refs(public_state[area], true)
        local previous = self.hidden_area_order[area] or {}
        local already = {}
        for _, ref in ipairs(current) do
            if self.hidden_public_ids[ref] then
                already[#already + 1] = ref
            end
        end
        local keep = preserve == area or is_subsequence(already, previous)
        if not keep and area == "hand" then
            local projections = public_state.hand_order_projections
            local all_refs = area_target_refs(public_state.hand, false)
            if
                type(projections) == "table"
                and (same_list(all_refs, projections.rank) or same_list(all_refs, projections.suit))
            then
                keep = true
            end
        end
        if not keep then
            for _, ref in ipairs(already) do
                self.rotate_hidden[ref] = true
            end
        end
        self.hidden_area_order[area] = current
    end
end

function GameMcpServer:_copy_snapshot_value(value, target_map, reference_ids)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}
    if table_is_array(value) then
        for index, child in ipairs(value) do
            copied[index] = self:_copy_snapshot_value(child, target_map, reference_ids)
        end
        return copied
    end

    local target_reference = rawget(value, "target_ref")
    if target_reference ~= nil then
        assert(type(target_reference) == "string", "target_ref must be a string")
        local existing_public = reference_ids[target_reference]
        if existing_public then
            copied.id = existing_public
        else
            local public_id =
                self:_public_target_id(target_reference, not not rawget(value, "facedown"))
            target_map[public_id] = target_reference
            reference_ids[target_reference] = public_id
            copied.id = public_id
        end
    end

    for _, key in ipairs(sorted_keys(value)) do
        if key ~= "target_ref" then
            assert(not (key == "id" and target_reference), "target entities cannot provide id")
            copied[key] = self:_copy_snapshot_value(value[key], target_map, reference_ids)
        end
    end
    return copied
end

local function map_target_ids(references, reference_ids)
    local ids = {}
    for index, reference in ipairs(references) do
        ids[index] = assert(reference_ids[reference], "legal action references an unknown target")
    end
    return ids
end

local function decorate_argument_constraints(name, arguments, catalog)
    local modes = catalog.target_arguments(name)
    for argument, spec in pairs(arguments) do
        local mode = modes[argument]
        if mode == "array" or mode == "complete" then
            if spec.unique_items == nil then
                spec.unique_items = true
            end
            if spec.ordered == nil then
                spec.ordered = true
            end
            if mode == "complete" then
                spec.complete = true
            end
        end
    end
end

local function action_allowed_values(action, argument)
    if action.fixed_arguments and action.fixed_arguments[argument] ~= nil then
        return { action.fixed_arguments[argument] }
    end
    local spec = action.arguments and action.arguments[argument]
    if spec and spec.allowed_values then
        return spec.allowed_values
    end
    return {}
end

local function collect_allowed_values(snapshot, name, argument)
    local seen, values = {}, {}
    for _, action in ipairs(snapshot.legal_actions) do
        if action.tool == name then
            for _, value in ipairs(action_allowed_values(action, argument)) do
                if not seen[value] then
                    seen[value] = true
                    values[#values + 1] = value
                end
            end
        end
    end
    return values
end

local function format_allowed_values(values)
    if type(values) ~= "table" or #values == 0 then
        return nil
    end
    local parts = {}
    for index, value in ipairs(values) do
        parts[index] = tostring(value)
    end
    return table.concat(parts, ", ")
end

local function with_allowed_values(message, values)
    local listed = format_allowed_values(values)
    if not listed then
        return message
    end
    return message .. "; allowed values: " .. listed
end

function GameMcpServer:_build_snapshot(observation, visibility)
    assert(type(observation) == "table", "adapter observation must be a table")
    assert(type(observation.run_id) == "string", "adapter run_id must be a string")
    self:_prepare_hidden_rotation(observation)
    assert(
        type(observation.decision_sequence) == "number" and observation.decision_sequence % 1 == 0,
        "adapter decision_sequence must be an integer"
    )
    assert(type(observation.phase) == "string", "adapter phase must be a string")
    assert(type(observation.public_state) == "table", "adapter public_state must be a table")

    local target_map = {}
    local reference_ids = {}
    local snapshot = {}
    for _, key in ipairs(sorted_keys(observation.public_state)) do
        if key ~= "legal_actions" and not reserved_snapshot_keys[key] then
            snapshot[key] =
                self:_copy_snapshot_value(observation.public_state[key], target_map, reference_ids)
        end
    end

    if visibility == "omniscient" and observation.hidden_state then
        for _, key in ipairs(sorted_keys(observation.hidden_state)) do
            assert(
                snapshot[key] == nil and not reserved_snapshot_keys[key],
                "hidden state key collision"
            )
            snapshot[key] =
                self:_copy_snapshot_value(observation.hidden_state[key], target_map, reference_ids)
        end
    end

    local legal_actions = {}
    for index, action in ipairs(observation.public_state.legal_actions or {}) do
        assert(type(action.tool) == "string", "legal action tool must be a string")
        local visible_action = { tool = action.tool }
        local fixed_arguments = copy_value(action.fixed_arguments or {})
        if action.fixed_target_refs then
            for argument, reference in pairs(action.fixed_target_refs) do
                assert(type(reference) == "string", "fixed target ref must be a string")
                fixed_arguments[argument] =
                    assert(reference_ids[reference], "legal action references an unknown target")
            end
        end
        if next(fixed_arguments) then
            visible_action.fixed_arguments = fixed_arguments
        end

        local arguments = copy_value(action.arguments or {})
        if action.target_refs then
            for argument, references in pairs(action.target_refs) do
                arguments[argument] = arguments[argument] or {}
                arguments[argument].allowed_values = map_target_ids(references, reference_ids)
            end
        end
        if action.required_target_refs then
            for argument, references in pairs(action.required_target_refs) do
                arguments[argument] = arguments[argument] or {}
                arguments[argument].required_values = map_target_ids(references, reference_ids)
            end
        end
        decorate_argument_constraints(action.tool, arguments, self.tool_catalog)
        if next(arguments) then
            visible_action.arguments = arguments
        end
        legal_actions[index] = visible_action
    end

    snapshot.server_name = self.server_info.name
    snapshot.server_version = self.server_info.version
    snapshot.protocol_version = protocol_version
    snapshot.visibility = visibility
    snapshot.run_id = observation.run_id
    snapshot.decision_sequence = observation.decision_sequence
    snapshot.phase = observation.phase
    snapshot.legal_actions = legal_actions
    local projections = snapshot.hand_order_projections
    if type(projections) == "table" then
        for _, key in ipairs({ "rank", "suit" }) do
            if type(projections[key]) == "table" then
                projections[key] = map_target_ids(projections[key], reference_ids)
            end
        end
    end
    local hash_snapshot = copy_value(snapshot)
    for _, action in ipairs(hash_snapshot.legal_actions or {}) do
        for _, spec in pairs(action.arguments or {}) do
            if type(spec) == "table" then
                if type(spec.allowed_values) == "table" then
                    table.sort(spec.allowed_values)
                end
                if type(spec.required_values) == "table" then
                    table.sort(spec.required_values)
                end
            end
        end
    end
    snapshot.state_hash = hash_hex(canonical_encode(self.json, {
        run_id = observation.run_id,
        decision_sequence = observation.decision_sequence,
        snapshot = hash_snapshot,
    })):sub(1, 8)

    return snapshot, target_map
end

function GameMcpServer:_logging_enabled(level)
    if not self.log then
        return false
    end
    if not self.log_enabled then
        return true
    end
    local checked, enabled = pcall(self.log_enabled, level)
    return checked and enabled
end

function GameMcpServer:_log(level, message)
    if not self:_logging_enabled(level) then
        return
    end
    pcall(self.log, level, message)
end

local function safe_error_text(value)
    local value_type = type(value)
    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    return "<" .. value_type .. ">"
end

local function normalize_diagnostic_value(value, depth, seen)
    local value_type = type(value)
    if
        value_type == "nil"
        or value_type == "string"
        or value_type == "number"
        or value_type == "boolean"
    then
        return value
    end
    if value_type ~= "table" then
        return "<" .. value_type .. ">"
    end
    depth = depth or 0
    seen = seen or {}
    if depth >= 12 then
        return "<max_depth>"
    end
    if seen[value] then
        return "<cycle>"
    end
    seen[value] = true
    local normalized = {}
    local count = 0
    if table_is_array(value) then
        for index, child in ipairs(value) do
            count = count + 1
            if count > 512 then
                normalized[#normalized + 1] = "<truncated_entries>"
                break
            end
            normalized[index] = normalize_diagnostic_value(child, depth + 1, seen)
        end
    else
        for key, child in pairs(value) do
            if type(key) == "string" or type(key) == "number" then
                count = count + 1
                if count > 512 then
                    normalized.truncated_entries = true
                    break
                end
                normalized[tostring(key)] = normalize_diagnostic_value(child, depth + 1, seen)
            end
        end
    end
    seen[value] = nil
    return normalized
end

local function diagnostic_scalar(server, value)
    local value_type = type(value)
    if value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    if value_type ~= "string" then
        value = "<" .. value_type .. ">"
    end
    if value:match("^[%w_./:+%-]+$") then
        return value
    end
    local encoded, result = pcall(server._encode, server, value)
    return encoded and result or '"<encode_failed>"'
end

local diagnostic_line_bytes = 64 * 1024
local diagnostic_field_bytes = 4 * 1024

function GameMcpServer:_trace(level, event, fields)
    if not self:_logging_enabled(level) then
        return
    end
    local built, line = pcall(function()
        local values = normalize_diagnostic_value(fields or {})
        if type(values) ~= "table" then
            values = {}
        end
        if self.active_trace and values.trace == nil then
            values.trace = self.active_trace.id
        end
        local function build_line(selected)
            local parts = { event }
            for _, key in ipairs(sorted_keys(selected)) do
                local value = selected[key]
                if value ~= nil then
                    local encoded = type(value) == "table" and self:_diagnostic_json(value)
                        or diagnostic_scalar(self, value)
                    parts[#parts + 1] = key .. "=" .. encoded
                end
            end
            return table.concat(parts, " ")
        end
        local result = build_line(values)
        if #result <= diagnostic_line_bytes then
            return result
        end
        local compact = {}
        for key, value in pairs(values) do
            local text = type(value) == "table" and self:_diagnostic_json(value) or tostring(value)
            if #text > diagnostic_field_bytes then
                compact[key] = "<omitted:" .. tostring(#text) .. " bytes>"
            else
                compact[key] = value
            end
        end
        compact.original_bytes = #result
        compact.truncated = true
        local compacted = build_line(compact)
        if #compacted <= diagnostic_line_bytes then
            return compacted
        end
        return build_line({
            code = compact.code,
            decision_sequence = compact.decision_sequence,
            elapsed_ms = compact.elapsed_ms,
            expected_state_hash = compact.expected_state_hash,
            may_have_committed = compact.may_have_committed,
            original_bytes = #result,
            phase = compact.phase,
            stage = compact.stage,
            state_hash = compact.state_hash,
            tool = compact.tool,
            trace = compact.trace,
            truncated = true,
        })
    end)
    if built then
        self:_log(level, line)
    else
        self:_log("error", "diagnostic.error stage=format error=" .. safe_error_text(line))
    end
end

function GameMcpServer:_new_request_trace(request)
    self.trace_serial = self.trace_serial + 1
    return {
        id = tostring(self.trace_serial),
        started_at = socket.gettime(),
        deadline = request.deadline,
        may_have_committed = false,
    }
end

function GameMcpServer:_begin_request_trace(message)
    local trace = self.active_trace
    if not trace or trace.begun then
        return
    end
    trace.begun = true
    trace.rpc_id = message.id
    trace.method = message.method
    local params = type(message.params) == "table" and message.params or nil
    trace.tool = params and params.name or nil
    self:_trace("debug", "request.begin", {
        method = trace.method,
        rpc_id = trace.rpc_id,
        tool = trace.tool,
    })
end

local diagnostic_chunk_bytes = 24 * 1024
local diagnostic_bundle_bytes = 256 * 1024

function GameMcpServer:_trace_payload(level, event, fields, payload)
    if not self:_logging_enabled(level) then
        return
    end
    local encoded, content = pcall(self._encode, self, normalize_diagnostic_value(payload))
    if not encoded then
        self:_log("error", "diagnostic.error stage=failure_context error=encode_failed")
        return
    end
    local original_bytes = #content
    local truncated = original_bytes > diagnostic_bundle_bytes
    if truncated then
        content = content:sub(1, diagnostic_bundle_bytes)
    end
    local chunks = math.max(1, math.ceil(#content / diagnostic_chunk_bytes))
    for index = 1, chunks do
        local chunk_fields = copy_value(fields or {})
        chunk_fields.chunk = tostring(index) .. "/" .. tostring(chunks)
        chunk_fields.data =
            content:sub((index - 1) * diagnostic_chunk_bytes + 1, index * diagnostic_chunk_bytes)
        chunk_fields.original_bytes = original_bytes
        chunk_fields.truncated = truncated
        self:_trace(level, event, chunk_fields)
    end
end

function GameMcpServer:_trace_failure_context(code, state)
    local trace = self.active_trace
    local pending = self.pending_action
    self:_trace_payload("debug", "failure.context", { code = code }, {
        action = trace and trace.action,
        candidate_state = trace and trace.candidate_state,
        code = code,
        input_state = trace and trace.input_state,
        observe_error = self.last_observe_error,
        pending = pending and {
            blocked_for_entire_wait = pending.blocked_for_entire_wait,
            candidate_state_hash = pending.candidate_state_hash,
            expected_state_hash = pending.expected_state_hash,
            kind = pending.kind,
            last_error_code = pending.last_error_code,
            name = pending.name,
        } or nil,
        state = state,
    })
end

function GameMcpServer:_finish_request_trace(is_error, code, state)
    local trace = self.active_trace
    if not trace or trace.finished then
        return
    end
    trace.finished = true
    if is_error then
        self:_trace_failure_context(code, state)
    end
    local fields = {
        code = code,
        elapsed_ms = math.floor((socket.gettime() - trace.started_at) * 1000 + 0.5),
        expected_state_hash = trace.expected_state_hash,
        may_have_committed = trace.may_have_committed,
        method = trace.method,
        reason = trace.failure_reason,
        rpc_id = trace.rpc_id,
        stage = trace.failure_stage,
        tool = trace.tool,
    }
    if is_error and self.last_observe_error then
        fields.wait_code = self.last_observe_error.code
        fields.wait_reason = self.last_observe_error.message
        for key, value in pairs(self.last_observe_error.diagnostic or {}) do
            fields[key == "state" and "wait_state" or key] = value
        end
    end
    local summary = type(state) == "table" and type(state.phase) == "string" and state
        or trace.input_summary
        or self.last_snapshot_summary
    if type(summary) == "table" then
        fields.decision_sequence = summary.decision_sequence
        fields.phase = summary.phase
        fields.state_hash = summary.state_hash
    end
    self:_trace(
        is_error and "error" or "info",
        is_error and "request.error" or "request.end",
        fields
    )
end

function GameMcpServer:_finish_http_response_trace(response)
    local is_error = response.status >= 400
    local code = "http_" .. tostring(response.status)
    if is_error and type(response.body) == "string" then
        local decoded, payload = pcall(self.json.decode, response.body)
        local error = decoded and type(payload) == "table" and payload.error or nil
        if type(error) == "table" then
            code = error.code or code
            if self.active_trace then
                self.active_trace.failure_reason = error.message
                self.active_trace.failure_stage = "protocol"
            end
        end
    end
    self:_finish_request_trace(is_error, code)
end

function GameMcpServer:_note_run_snapshot(snapshot)
    if type(snapshot) ~= "table" then
        return
    end
    self.last_snapshot_summary = {
        decision_sequence = snapshot.decision_sequence,
        phase = snapshot.phase,
        state_hash = snapshot.state_hash,
    }
    local run_id = snapshot.run_id
    if type(run_id) ~= "string" or run_id == self.last_run_id then
        return
    end
    self.last_run_id = run_id
    if run_id == "menu" then
        return
    end
    local trace = self.active_trace
    local arguments = trace and trace.action_name == "start_run" and trace.run_arguments or {}
    local deck = type(snapshot.deck) == "table" and snapshot.deck.key
        or snapshot.selected_deck_key
        or arguments.deck_key
    local stake = type(snapshot.stake) == "table" and (snapshot.stake.level or snapshot.stake.key)
        or arguments.stake
    self:_trace(
        "info",
        trace and trace.action_name == "start_run" and "run.begin" or "run.resume",
        {
            deck = deck,
            phase = snapshot.phase,
            run_id = run_id,
            seed = snapshot.seed or arguments.seed,
            seeded = snapshot.seeded,
            decision_sequence = snapshot.decision_sequence,
            stake = stake,
            visibility = snapshot.visibility,
        }
    )
end

local observe_diagnostic_fields = {
    "complete",
    "hand",
    "locked",
    "money",
    "overlay",
    "paused",
    "pending_dollars",
    "pending_dollars_direction",
    "shop",
    "slot",
    "state",
    "state_value",
    "stop_use",
}

function GameMcpServer:_note_observe_wait(adapter_error)
    local diagnostic = {}
    for _, field in ipairs(observe_diagnostic_fields) do
        local value = type(adapter_error.diagnostic) == "table" and adapter_error.diagnostic[field]
            or nil
        if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
            diagnostic[field] = value
        end
    end
    self.last_observe_error = {
        code = type(adapter_error.code) == "string" and adapter_error.code or "INTERNAL_ERROR",
        diagnostic = diagnostic,
        message = safe_error_text(adapter_error.message),
    }
    if not self:_logging_enabled("debug") then
        return
    end
    local line = type(adapter_error.observe_block) == "string" and adapter_error.observe_block
        or nil
    if line then
        self.last_observe_error.observe_block = line
    end
    if not line or line == self.last_observe_log then
        return
    end
    self.last_observe_log = line
    local fields = copy_value(diagnostic)
    fields.code = self.last_observe_error.code
    fields.details = line
    fields.reason = self.last_observe_error.message
    self:_trace("debug", "observe.wait", fields)
end

function GameMcpServer:_observe_snapshot()
    local visibility = self:_current_visibility()
    local observed, observation, adapter_error =
        pcall(self.adapter.observe, self.adapter, visibility)
    if not observed then
        self:_trace("error", "diagnostic.error", {
            error = safe_error_text(observation),
            stage = "observe",
        })
        return nil, nil, { code = "INTERNAL_ERROR", message = "Balatro observation failed" }
    end
    if not observation then
        adapter_error = adapter_error
            or { code = "INTERNAL_ERROR", message = "Balatro observation failed" }
        if adapter_error.code == "DECISION_PENDING" or adapter_error.code == "GAME_BLOCKED" then
            self:_note_observe_wait(adapter_error)
        end
        return nil, nil, adapter_error
    end
    self.last_observe_log = nil
    self.last_observe_error = nil

    local built, snapshot, target_map = pcall(self._build_snapshot, self, observation, visibility)
    if not built then
        self:_trace("error", "diagnostic.error", {
            error = safe_error_text(snapshot),
            stage = "snapshot.build",
        })
        return nil, nil, { code = "INTERNAL_ERROR", message = "Invalid Balatro observation" }
    end
    self:_note_run_snapshot(snapshot)
    return snapshot, target_map
end

function GameMcpServer:_encyclopedia_result(id)
    local visibility = self:_current_visibility()
    local queried, encyclopedia, adapter_error =
        pcall(self.adapter.encyclopedia, self.adapter, visibility)
    if not queried then
        self:_trace("error", "diagnostic.error", {
            error = safe_error_text(encyclopedia),
            stage = "encyclopedia",
        })
        return self:_tool_result(id, {
            code = "INTERNAL_ERROR",
            message = "Balatro encyclopedia failed",
        }, true)
    end
    if not encyclopedia then
        adapter_error = adapter_error
            or { code = "INTERNAL_ERROR", message = "Balatro encyclopedia failed" }
        if adapter_error.code == "INTERNAL_ERROR" then
            self:_trace("error", "diagnostic.error", {
                error = safe_error_text(adapter_error.message),
                stage = "encyclopedia",
            })
            adapter_error = { code = "INTERNAL_ERROR", message = "Balatro encyclopedia failed" }
        end
        return self:_tool_result(id, adapter_error, true)
    end
    return self:_tool_result(id, { effect_encyclopedia = copy_value(encyclopedia) }, false)
end

function GameMcpServer:_diagnostic_json(value)
    local encoded, result = pcall(self._encode, self, normalize_diagnostic_value(value))
    return encoded and result or '"<encode_failed>"'
end

local function diagnostic_keys(value)
    local keys = {}
    for key in pairs(type(value) == "table" and value or {}) do
        if type(key) == "string" or type(key) == "number" then
            keys[#keys + 1] = tostring(key)
        end
    end
    table.sort(keys)
    return keys
end

local function diagnostic_target_map(value)
    local targets = {}
    for id, reference in pairs(type(value) == "table" and value or {}) do
        if type(id) == "string" and type(reference) == "string" then
            targets[#targets + 1] = { id = id, reference = reference }
        end
    end
    table.sort(targets, function(a, b)
        return a.id < b.id
    end)
    return targets
end

local function diagnostic_capture_error(value)
    if type(value) ~= "table" then
        return safe_error_text(value)
    end
    local projected = {}
    for _, field in ipairs({ "code", "message", "path", "raw_reference" }) do
        local child = value[field]
        if type(child) == "string" or type(child) == "number" or type(child) == "boolean" then
            projected[field] = child
        end
    end
    return projected
end

function GameMcpServer:_invalid_output_content(tool_name, structured_content, schema_error, audit)
    audit = audit or {}
    if self.active_trace then
        self.active_trace.failure_stage = "output.validate"
    end
    local details
    if self:_logging_enabled("debug") then
        details = {
            capture_error = diagnostic_capture_error(audit.capture_error),
            output_fields = diagnostic_keys(structured_content),
            resolution_events = type(audit.raw_resolution) == "table" and #audit.raw_resolution
                or 0,
            targets = diagnostic_target_map(audit.target_map),
        }
    end
    self:_trace("error", "diagnostic.error", {
        action = audit.action or tool_name,
        details = details,
        raw_reference = type(audit.raw_reference) == "string" and audit.raw_reference or nil,
        schema_path = schema_error,
        stage = "output.validate",
        tool = tool_name,
    })

    local content = {
        code = "INTERNAL_ERROR",
        message = audit.may_have_committed
                and "The action may have been committed, but the server could not produce a valid response; use the returned state before acting again."
            or "The server could not produce a valid tool response.",
        state = json_null(),
    }
    if
        type(structured_content.state) == "table"
        and not self.tool_catalog.validate_output_state(tool_name, structured_content.state)
    then
        content.state = copy_value(structured_content.state)
    end
    return content
end

function GameMcpServer:_tool_result(id, structured_content, is_error, audit)
    local tool_name = audit and audit.tool_name or self.tool_log_name
    assert(type(tool_name) == "string", "tool name is required for tool results")
    if not is_error then
        local schema_error = audit and audit.validation_error
            or self.tool_catalog.validate_output(tool_name, structured_content)
        if schema_error then
            structured_content =
                self:_invalid_output_content(tool_name, structured_content, schema_error, audit)
            is_error = true
        end
    end
    local code = is_error and structured_content.code or "ok"
    self:_finish_request_trace(is_error, code, structured_content.state)
    if is_error and structured_content.observe_block then
        structured_content = copy_value(structured_content)
        structured_content.observe_block = nil
    end
    return self:_json_response(200, {
        jsonrpc = "2.0",
        id = id,
        result = {
            resultType = "complete",
            content = { { type = "text", text = self:_encode(structured_content) } },
            structuredContent = structured_content,
            isError = is_error,
        },
    })
end

local snapshotless_error = { DECISION_TIMEOUT = true, GAME_BLOCKED = true }

function GameMcpServer:_semantic_action_result(id, snapshot, extras)
    extras = extras or {}
    if extras.code then
        local content = {
            code = extras.code,
            message = extras.message,
        }
        if snapshotless_error[extras.code] then
            content.state = json_null()
        elseif snapshot then
            content.state = snapshot
        end
        return self:_tool_result(id, content, true)
    end

    local content = { state = snapshot }
    if extras.resolution then
        content.resolution = copy_value(extras.resolution)
    end
    return self:_tool_result(id, content, false, extras.audit)
end

function GameMcpServer:_abandon_resolution_capture(context, reason)
    local abandoned, abandon_error =
        pcall(self.adapter.abandon_resolution, self.adapter, context, reason)
    if not abandoned then
        self:_trace("error", "diagnostic.error", {
            error = safe_error_text(abandon_error),
            stage = "resolution.abandon",
        })
    end
end

function GameMcpServer:_finish_resolution_capture(context)
    local finished, resolution, capture_error =
        pcall(self.adapter.finish_resolution, self.adapter, context)
    if not finished then
        self:_trace("error", "diagnostic.error", {
            error = safe_error_text(resolution),
            stage = "resolution.finish",
        })
        return nil,
            {
                code = "INTERNAL_ERROR",
                message = "Resolution capture finalization failed",
            }
    end
    return resolution, capture_error
end

function GameMcpServer:_action_success_result(
    id,
    name,
    snapshot,
    raw_resolution,
    target_map,
    resolution_context
)
    local audit = {
        tool_name = name,
        action = name,
        may_have_committed = true,
        raw_resolution = raw_resolution,
        target_map = target_map,
    }
    if type(raw_resolution) == "table" and next(raw_resolution) == nil then
        raw_resolution = nil
        audit.raw_resolution = nil
    end
    if raw_resolution then
        local raw_content = { state = snapshot, resolution = copy_value(raw_resolution) }
        local raw_schema_error = self.tool_catalog.validate_output(name, raw_content)
        if raw_schema_error then
            self:_abandon_resolution_capture(resolution_context, "invalid_raw_resolution")
            audit.validation_error = raw_schema_error
            return self:_semantic_action_result(id, snapshot, { audit = audit })
        end
    end
    if not resolution_context then
        self:_abandon_resolution_capture(nil, "missing_resolution_context")
        audit.validation_error = "value.resolution capture context is required"
        return self:_semantic_action_result(id, snapshot, { audit = audit })
    end
    local resolution, capture_error = self:_finish_resolution_capture(resolution_context)
    audit.capture_error = capture_error
    if capture_error then
        audit.validation_error = capture_error.path or "value.resolution capture is invalid"
        audit.raw_reference = capture_error.raw_reference
        return self:_semantic_action_result(id, snapshot, { audit = audit })
    end

    local prepared, prepare_error, raw_reference = prepare_resolution(resolution, target_map)
    if prepare_error then
        audit.validation_error = prepare_error
        audit.raw_reference = raw_reference
        return self:_semantic_action_result(id, snapshot, { audit = audit })
    end
    return self:_semantic_action_result(id, snapshot, {
        resolution = prepared,
        audit = audit,
    })
end

local function list_contains(values, expected)
    for _, value in ipairs(values) do
        if value == expected then
            return true
        end
    end
    return false
end

local function matches_fixed_arguments(arguments, fixed)
    if not fixed then
        return true
    end
    for key, expected in pairs(fixed) do
        if arguments[key] ~= expected then
            return false
        end
    end
    return true
end

local function find_legal_action(snapshot, name, arguments, catalog)
    local fallback
    local modes = catalog and catalog.target_arguments(name) or {}
    for _, action in ipairs(snapshot.legal_actions) do
        if action.tool == name then
            fallback = fallback or action
            if matches_fixed_arguments(arguments, action.fixed_arguments) then
                local targets_match = true
                for argument, mode in pairs(modes) do
                    local pinned = action.fixed_arguments
                        and action.fixed_arguments[argument] ~= nil
                    if mode == "scalar" and not pinned then
                        local value = arguments and arguments[argument]
                        local allowed = action_allowed_values(action, argument)
                        if value ~= nil and #allowed > 0 and not list_contains(allowed, value) then
                            targets_match = false
                            break
                        end
                    end
                end
                if targets_match then
                    return action, true
                end
            end
        end
    end
    return fallback, false
end

function GameMcpServer:_resolve_action_targets(
    name,
    arguments,
    legal_action,
    target_map,
    snapshot,
    matched
)
    local resolved = {}
    for argument, mode in pairs(self.tool_catalog.target_arguments(name)) do
        local value = arguments[argument]
        if value ~= nil then
            local allowed = action_allowed_values(legal_action, argument)
            if not matched then
                local union = collect_allowed_values(snapshot, name, argument)
                if #union > 0 then
                    allowed = union
                end
            end
            if mode == "scalar" then
                if not list_contains(allowed, value) or not target_map[value] then
                    return nil, with_allowed_values("Invalid target for " .. argument, allowed)
                end
                resolved[argument] = target_map[value]
            else
                if mode == "complete" and #value ~= #allowed then
                    return nil,
                        with_allowed_values(
                            argument .. " must contain the complete target set",
                            allowed
                        )
                end
                local references = {}
                for index, target_id in ipairs(value) do
                    if not list_contains(allowed, target_id) or not target_map[target_id] then
                        return nil, with_allowed_values("Invalid target for " .. argument, allowed)
                    end
                    references[index] = target_map[target_id]
                end
                resolved[argument] = references
            end
        end
    end
    return resolved
end

local diagnostic_target_fields = {
    "category",
    "cost",
    "debuffed",
    "edition",
    "enhancement",
    "facedown",
    "key",
    "name",
    "rank",
    "seal",
    "slot",
    "suit",
}

local function diagnostic_target_index(snapshot)
    local indexed = {}
    local function visit(value, zone, index)
        if type(value) ~= "table" then
            return
        end
        if type(value.id) == "string" then
            local target = { id = value.id, zone = zone, index = index }
            for _, field in ipairs(diagnostic_target_fields) do
                if value[field] ~= nil then
                    target[field] = copy_value(value[field])
                end
            end
            indexed[value.id] = target
        end
        if table_is_array(value) then
            for child_index, child in ipairs(value) do
                visit(child, zone, child_index)
            end
        else
            for _, key in ipairs(sorted_keys(value)) do
                if key ~= "legal_actions" then
                    visit(value[key], zone or key, index)
                end
            end
        end
    end
    for _, key in ipairs(sorted_keys(snapshot)) do
        if key ~= "legal_actions" then
            visit(snapshot[key], key)
        end
    end
    return indexed
end

local function diagnostic_action_targets(snapshot, arguments, target_map, catalog, name)
    local indexed = diagnostic_target_index(snapshot)
    local targets = {}
    for _, argument in ipairs(sorted_keys(catalog.target_arguments(name))) do
        local value = arguments[argument]
        local values = type(value) == "table" and value or { value }
        for _, id in ipairs(values) do
            if type(id) == "string" then
                local target = copy_value(indexed[id] or { id = id })
                target.argument = argument
                target.reference = target_map[id]
                targets[#targets + 1] = target
            end
        end
    end
    return targets[1] and targets or nil
end

function GameMcpServer:_execute_action(id, name, arguments, deadline)
    local validation_error = self.tool_catalog.validate(name, arguments)
    local visibility = self:_current_visibility()
    local current_snapshot, target_map, observation_error = self:_observe_snapshot()
    if not current_snapshot then
        if
            observation_error
            and (
                observation_error.code == "DECISION_PENDING"
                or observation_error.code == "GAME_BLOCKED"
            )
        then
            self.pending_action = {
                kind = "retry_action",
                rpc_id = id,
                name = name,
                tool_name = name,
                arguments = copy_value(arguments),
                last_error_code = observation_error.code,
                blocked_for_entire_wait = observation_error.code == "GAME_BLOCKED",
                deadline = deadline or socket.gettime() + self.request_timeout_ms / 1000,
            }
            return nil
        end
        observation_error = observation_error
            or { code = "INTERNAL_ERROR", message = "Balatro observation failed" }
        return self:_semantic_action_result(id, nil, {
            code = observation_error.code,
            message = observation_error.message,
        })
    end
    if validation_error then
        return self:_semantic_action_result(id, current_snapshot, {
            code = "INVALID_PARAMS",
            message = validation_error,
        })
    end

    if arguments.state_hash ~= current_snapshot.state_hash then
        return self:_semantic_action_result(id, current_snapshot, {
            code = "STALE_STATE",
            message = "state_hash does not match the current decision state",
        })
    end

    if
        current_snapshot.compatibility
        and current_snapshot.compatibility.versions == "unsupported"
    then
        return self:_semantic_action_result(id, current_snapshot, {
            code = "INCOMPATIBLE_VERSION",
            message = current_snapshot.compatibility.diagnostic
                or "Game environment is below the minimum supported versions",
        })
    end

    local legal_action, matched =
        find_legal_action(current_snapshot, name, arguments, self.tool_catalog)
    if not legal_action then
        return self:_semantic_action_result(id, current_snapshot, {
            code = "INVALID_PHASE",
            message = "The tool is not legal in the current decision state",
        })
    end

    local target_modes = self.tool_catalog.target_arguments(name)
    if not matched then
        local function mismatch_error(argument, allowed)
            if target_modes[argument] then
                return self:_semantic_action_result(id, current_snapshot, {
                    code = "INVALID_TARGET",
                    message = with_allowed_values("Invalid target for " .. argument, allowed),
                })
            end
            return self:_semantic_action_result(id, current_snapshot, {
                code = "INVALID_PARAMS",
                message = with_allowed_values(argument .. " has an unsupported value", allowed),
            })
        end
        for argument in pairs(legal_action.fixed_arguments or {}) do
            local allowed = collect_allowed_values(current_snapshot, name, argument)
            local value = arguments[argument]
            if value ~= nil and not list_contains(allowed, value) then
                return mismatch_error(argument, allowed)
            end
        end
        for argument, mode in pairs(target_modes) do
            if mode == "scalar" then
                local allowed = collect_allowed_values(current_snapshot, name, argument)
                local value = arguments[argument]
                if value ~= nil and #allowed > 0 and not list_contains(allowed, value) then
                    return mismatch_error(argument, allowed)
                end
            end
        end
    end

    local constraint_error =
        self.tool_catalog.validate_constraints(arguments, legal_action.arguments, target_modes)
    if constraint_error then
        return self:_semantic_action_result(id, current_snapshot, {
            code = "INVALID_PARAMS",
            message = constraint_error,
        })
    end

    local resolved_targets, target_error = self:_resolve_action_targets(
        name,
        arguments,
        legal_action,
        target_map,
        current_snapshot,
        matched
    )
    if not resolved_targets then
        return self:_semantic_action_result(id, current_snapshot, {
            code = "INVALID_TARGET",
            message = target_error,
        })
    end

    if deadline and socket.gettime() >= deadline then
        if self.active_trace then
            self.active_trace.failure_stage = "action.deadline"
        end
        return self:_semantic_action_result(id, nil, {
            code = "DECISION_TIMEOUT",
            message = "Request expired before semantic action execution",
        })
    end

    local action_arguments = copy_value(arguments)
    action_arguments.state_hash = nil
    local debug_enabled = self:_logging_enabled("debug")
    local diagnostic_targets = debug_enabled
            and diagnostic_action_targets(
                current_snapshot,
                arguments,
                target_map,
                self.tool_catalog,
                name
            )
        or nil
    if self.active_trace then
        self.active_trace.action_name = name
        self.active_trace.expected_state_hash = arguments.state_hash
        self.active_trace.input_summary = {
            decision_sequence = current_snapshot.decision_sequence,
            phase = current_snapshot.phase,
            state_hash = current_snapshot.state_hash,
        }
        if name == "start_run" then
            self.active_trace.run_arguments = {
                deck_key = action_arguments.deck_key,
                seed = action_arguments.seed,
                stake = action_arguments.stake,
            }
        end
        if debug_enabled then
            self.active_trace.input_state = copy_value(current_snapshot)
            self.active_trace.action = {
                arguments = copy_value(action_arguments),
                targets = copy_value(diagnostic_targets),
                tool = name,
            }
        end
    end
    self:_trace("debug", "action.accepted", {
        arguments = action_arguments,
        decision_sequence = current_snapshot.decision_sequence,
        phase = current_snapshot.phase,
        state_hash = current_snapshot.state_hash,
        targets = diagnostic_targets,
        tool = name,
        visibility = visibility,
    })
    local executed, result, adapter_error = pcall(self.adapter.execute, self.adapter, {
        name = name,
        expected_state_hash = arguments.state_hash,
        arguments = action_arguments,
        targets = resolved_targets,
        visibility = visibility,
    })
    if not executed then
        if self.active_trace then
            self.active_trace.may_have_committed = true
        end
        self:_abandon_resolution_capture(nil, "execute_error")
        self:_trace("error", "diagnostic.error", {
            error = safe_error_text(result),
            may_have_committed = true,
            stage = "action.execute",
            tool = name,
        })
        return self:_semantic_action_result(id, current_snapshot, {
            code = "INTERNAL_ERROR",
            message = "Balatro action failed",
        })
    end
    if not result then
        self:_abandon_resolution_capture(nil, "action_error")
        local error_code = adapter_error and adapter_error.code or "INTERNAL_ERROR"
        local error_message = adapter_error and adapter_error.message or "Balatro action failed"
        if error_code == "INTERNAL_ERROR" then
            self:_trace("error", "diagnostic.error", {
                error = safe_error_text(error_message),
                may_have_committed = false,
                stage = "action.result",
                tool = name,
            })
            error_message = "Balatro action failed"
        end
        return self:_semantic_action_result(id, current_snapshot, {
            code = error_code,
            message = error_message,
        })
    end

    local may_have_committed = true
    if self.active_trace then
        self.active_trace.may_have_committed = may_have_committed
    end
    local resolution_events = 0
    if type(result.resolution) == "table" then
        for _ in pairs(result.resolution) do
            resolution_events = resolution_events + 1
        end
    end
    self:_trace("debug", "action.dispatched", {
        may_have_committed = may_have_committed,
        pending = not not result.pending,
        resolution_events = resolution_events,
        tool = name,
    })

    if name == "reorder_cards" then
        self.preserve_hidden_area = action_arguments.area
    end

    if result.pending then
        self.pending_action = {
            kind = "action",
            name = name,
            tool_name = name,
            rpc_id = id,
            expected_state_hash = arguments.state_hash,
            resolution = result.resolution,
            resolution_context = result.resolution_context,
            input_target_map = target_map,
            blocked_for_entire_wait = true,
            deadline = deadline or socket.gettime() + self.request_timeout_ms / 1000,
        }
        return nil
    end

    local built, next_snapshot = pcall(self._build_snapshot, self, result.observation, visibility)
    if not built then
        self:_abandon_resolution_capture(result.resolution_context, "invalid_action_state")
        return self:_semantic_action_result(id, nil, {
            audit = {
                tool_name = name,
                action = name,
                may_have_committed = true,
                raw_resolution = result.resolution,
                target_map = target_map,
                validation_error = "value.state could not be built",
                capture_error = safe_error_text(next_snapshot),
            },
        })
    end
    self:_note_run_snapshot(next_snapshot)
    return self:_action_success_result(
        id,
        name,
        next_snapshot,
        result.resolution,
        target_map,
        result.resolution_context
    )
end

function GameMcpServer:_poll_pending_action()
    local pending = self.pending_action
    if not pending or not pending.http_id then
        return
    end
    self.active_trace = pending.trace or self.active_trace
    self.tool_log_name = pending.tool_name or pending.name

    if socket.gettime() >= pending.deadline then
        local _, _, final_error = self:_observe_snapshot()
        local continuously_blocked = pending.blocked_for_entire_wait
            and final_error
            and final_error.code == "GAME_BLOCKED"
        local code = continuously_blocked and "GAME_BLOCKED" or "DECISION_TIMEOUT"
        local message = code == "GAME_BLOCKED"
                and "Balatro is blocked by a player-controlled overlay"
            or "Timed out waiting for the next decision state"
        self.last_observe_log = nil
        if pending.kind == "action" then
            self:_abandon_resolution_capture(pending.resolution_context, code)
        end
        local response = self:_semantic_action_result(pending.rpc_id, nil, {
            code = code,
            message = message,
        })
        response.id = pending.http_id
        self.channels.responses:push(response)
        self.pending_action = nil
        return
    end

    if pending.kind == "retry_action" then
        local snapshot, _, observation_error = self:_observe_snapshot()
        if not snapshot then
            observation_error = observation_error
                or { code = "INTERNAL_ERROR", message = "Balatro observation failed" }
            if
                observation_error.code == "DECISION_PENDING"
                or observation_error.code == "GAME_BLOCKED"
            then
                pending.last_error_code = observation_error.code
                if observation_error.code ~= "GAME_BLOCKED" then
                    pending.blocked_for_entire_wait = false
                end
                return
            end
            local response = self:_semantic_action_result(pending.rpc_id, nil, {
                code = observation_error.code,
                message = observation_error.message,
            })
            response.id = pending.http_id
            self.channels.responses:push(response)
            self.pending_action = nil
            return
        end

        local http_id = pending.http_id
        local deadline = pending.deadline
        local rpc_id = pending.rpc_id
        local name = pending.name
        local arguments = pending.arguments
        self.pending_action = nil
        local response = self:_execute_action(rpc_id, name, arguments, deadline)
        if response then
            response.id = http_id
            self.channels.responses:push(response)
        else
            assert(self.pending_action, "retried action deferred without pending state")
            self.pending_action.http_id = http_id
            self.pending_action.deadline = math.min(self.pending_action.deadline, deadline)
            self.pending_action.blocked_for_entire_wait = false
        end
        return
    end

    local snapshot, _, observation_error = self:_observe_snapshot()
    if snapshot then
        if pending.kind == "encyclopedia" then
            local response = self:_encyclopedia_result(pending.rpc_id)
            response.id = pending.http_id
            self.channels.responses:push(response)
            self.pending_action = nil
            return
        end
        if pending.kind == "action" and snapshot.state_hash == pending.expected_state_hash then
            pending.candidate_state_hash = nil
            pending.last_error_code = nil
            pending.blocked_for_entire_wait = false
            return
        end
        if pending.kind == "action" and pending.candidate_state_hash ~= snapshot.state_hash then
            pending.candidate_state_hash = snapshot.state_hash
            pending.last_error_code = nil
            pending.blocked_for_entire_wait = false
            if self.active_trace and self:_logging_enabled("debug") then
                self.active_trace.candidate_state = copy_value(snapshot)
            end
            self:_trace("debug", "decision.candidate", {
                decision_sequence = snapshot.decision_sequence,
                phase = snapshot.phase,
                stable = false,
                state_hash = snapshot.state_hash,
            })
            return
        end
        if pending.kind == "action" then
            self:_trace("debug", "decision.candidate", {
                decision_sequence = snapshot.decision_sequence,
                phase = snapshot.phase,
                stable = true,
                state_hash = snapshot.state_hash,
            })
        end
        local response
        if pending.kind == "action" then
            response = self:_action_success_result(
                pending.rpc_id,
                pending.name,
                snapshot,
                pending.resolution,
                pending.input_target_map,
                pending.resolution_context
            )
        else
            response = self:_tool_result(pending.rpc_id, { state = snapshot }, false)
        end
        response.id = pending.http_id
        self.channels.responses:push(response)
        self.pending_action = nil
        return
    end

    observation_error = observation_error
        or { code = "INTERNAL_ERROR", message = "Balatro observation failed" }
    if observation_error.code == "DECISION_PENDING" or observation_error.code == "GAME_BLOCKED" then
        pending.last_error_code = observation_error.code
        if observation_error.code ~= "GAME_BLOCKED" then
            pending.blocked_for_entire_wait = false
        end
        return
    end
    if pending.kind == "action" then
        self:_abandon_resolution_capture(pending.resolution_context, observation_error.code)
    end
    local response = self:_semantic_action_result(pending.rpc_id, nil, {
        code = observation_error.code,
        message = observation_error.message,
    })
    response.id = pending.http_id
    self.channels.responses:push(response)
    self.pending_action = nil
end

---@param request McpHttpRequest
---@return McpHttpResponse?
function GameMcpServer:_dispatch(request)
    local ok, message = pcall(self.json.decode, request.body)
    if not ok or type(message) ~= "table" then
        self:_begin_request_trace({
            method = request.headers["mcp-method"] or "unknown",
            params = {},
        })
        return self:_json_response(400, error_result(nil, -32700, "Parse error"))
    end

    local id_type = type(message.id)
    self:_begin_request_trace({
        id = (id_type == "string" or id_type == "number") and message.id or nil,
        method = type(message.method) == "string" and message.method
            or request.headers["mcp-method"]
            or "unknown",
        params = type(message.params) == "table" and type(message.params.name) == "string" and {
            name = message.params.name,
        } or {},
    })
    if
        message.jsonrpc ~= "2.0"
        or type(message.method) ~= "string"
        or (message.id ~= nil and id_type ~= "string" and id_type ~= "number")
    then
        return self:_json_response(400, error_result(nil, -32600, "Invalid Request"))
    end

    local params = message.params
    local meta = type(params) == "table" and params._meta or nil
    local requested_version = type(meta) == "table"
            and meta["io.modelcontextprotocol/protocolVersion"]
        or nil
    local client_capabilities = type(meta) == "table"
            and meta["io.modelcontextprotocol/clientCapabilities"]
        or nil
    if
        type(params) ~= "table"
        or type(meta) ~= "table"
        or type(requested_version) ~= "string"
        or type(client_capabilities) ~= "table"
    then
        return self:_json_response(400, error_result(message.id, -32602, "Invalid params"))
    end

    local headers = request.headers
    if
        headers["mcp-protocol-version"] == nil
        or headers["mcp-method"] == nil
        or headers["mcp-protocol-version"] ~= requested_version
        or headers["mcp-method"] ~= message.method
    then
        return self:_json_response(400, error_result(message.id, -32020, "HeaderMismatch"))
    end

    if requested_version ~= protocol_version then
        return self:_json_response(
            400,
            error_result(message.id, -32022, "Unsupported protocol version", {
                requested = requested_version,
                supported = { protocol_version },
            })
        )
    end

    if message.id == nil then
        return { status = 202, headers = {}, body = "" }
    end

    if message.method == "server/discover" then
        return self:_json_response(200, {
            jsonrpc = "2.0",
            id = message.id,
            result = {
                resultType = "complete",
                ttlMs = 0,
                cacheScope = "private",
                supportedVersions = { protocol_version },
                capabilities = { tools = empty_object() },
                _meta = {
                    ["io.modelcontextprotocol/serverInfo"] = self.server_info,
                },
            },
        })
    end

    if message.method == "tools/list" then
        return self:_json_response(200, {
            jsonrpc = "2.0",
            id = message.id,
            result = {
                resultType = "complete",
                ttlMs = 0,
                cacheScope = "public",
                tools = self.tool_catalog.list(),
            },
        })
    end

    if message.method == "tools/call" then
        if
            type(params.name) ~= "string"
            or (params.arguments ~= nil and type(params.arguments) ~= "table")
            or not self.tool_catalog.get(params.name)
        then
            return self:_json_response(400, error_result(message.id, -32602, "Invalid params"))
        end

        local arguments = params.arguments or {}
        if self.active_trace and type(arguments.state_hash) == "string" then
            self.active_trace.expected_state_hash = arguments.state_hash
        end
        self.tool_log_name = params.name
        if request.deadline and socket.gettime() >= request.deadline then
            if self.active_trace then
                self.active_trace.failure_stage = "dispatch.deadline"
            end
            return self:_semantic_action_result(message.id, nil, {
                code = "DECISION_TIMEOUT",
                message = "Request expired before main-thread dispatch",
            })
        end
        if params.name == "get_game_state" or params.name == "get_effect_encyclopedia" then
            local validation_error = self.tool_catalog.validate(params.name, arguments)
            if validation_error then
                return self:_tool_result(message.id, {
                    code = "INVALID_PARAMS",
                    message = validation_error,
                }, true)
            end

            local snapshot, _, adapter_error = self:_observe_snapshot()
            if not snapshot then
                if
                    adapter_error
                    and (
                        adapter_error.code == "DECISION_PENDING"
                        or adapter_error.code == "GAME_BLOCKED"
                    )
                then
                    local kind = "observe"
                    if params.name == "get_effect_encyclopedia" then
                        kind = "encyclopedia"
                    end
                    self.pending_action = {
                        kind = kind,
                        tool_name = params.name,
                        rpc_id = message.id,
                        last_error_code = adapter_error.code,
                        blocked_for_entire_wait = adapter_error.code == "GAME_BLOCKED",
                        deadline = request.deadline
                            or socket.gettime() + self.request_timeout_ms / 1000,
                    }
                    return nil
                end
                return self:_tool_result(message.id, adapter_error, true)
            end
            if params.name == "get_game_state" then
                return self:_tool_result(message.id, { state = snapshot }, false)
            end
            return self:_encyclopedia_result(message.id)
        end

        return self:_execute_action(message.id, params.name, arguments, request.deadline)
    end

    return self:_json_response(404, error_result(message.id, -32601, "Method not found"))
end

---@return boolean
function GameMcpServer:start()
    if self.thread and self.thread:isRunning() then
        return true
    end

    if self.pending_action and self.pending_action.kind == "action" then
        self:_abandon_resolution_capture(self.pending_action.resolution_context, "server_restart")
    end
    self.pending_action = nil
    for _, channel in pairs(self.channels) do
        channel:clear()
    end

    local ok, thread_or_error = pcall(function()
        local worker_data =
            love.filesystem.newFileData(self.worker_source, "balatro-mcp-http-worker.lua")
        return love.thread.newThread(worker_data)
    end)
    if not ok then
        self.status = { state = "error", port = self.port, error = tostring(thread_or_error) }
        return false
    end

    self.thread = thread_or_error
    self.status = { state = "starting", port = self.port }
    self.previous_threaderror = love.threaderror
    self.threaderror_handler = function(thread, error_message)
        if thread == self.thread then
            self.status = { state = "error", port = self.port, error = error_message }
        elseif self.previous_threaderror then
            self.previous_threaderror(thread, error_message)
        end
    end
    love.threaderror = self.threaderror_handler
    local started, start_error = pcall(function()
        self.thread:start(
            self.port,
            self.channel_names.requests,
            self.channel_names.responses,
            self.channel_names.status,
            self.channel_names.control,
            self.request_timeout_ms,
            self.max_header_bytes,
            self.max_body_bytes
        )
    end)
    if not started then
        love.threaderror = self.previous_threaderror
        self.thread = nil
        self.status = { state = "error", port = self.port, error = tostring(start_error) }
        return false
    end
    return true
end

function GameMcpServer:poll()
    while true do
        local status = self.channels.status:pop()
        if not status then
            break
        end
        self.status = status
    end

    self:_poll_pending_action()
    if not self.pending_action and self.active_trace and self.active_trace.finished then
        self.active_trace = nil
    end
    while not self.pending_action do
        local request = self.channels.requests:pop()
        if not request then
            break
        end
        self.active_trace = self:_new_request_trace(request)
        local response = self:_dispatch(request)
        if response then
            if not self.active_trace.finished then
                self:_finish_http_response_trace(response)
            end
            response.id = request.id
            self.channels.responses:push(response)
            self.active_trace = nil
        else
            assert(self.pending_action, "dispatch deferred without a pending action")
            self.pending_action.http_id = request.id
            self.pending_action.trace = self.active_trace
        end
    end

    if self.thread then
        local thread_error = self.thread:getError()
        if thread_error and self.status.state ~= "error" then
            self.status = { state = "error", port = self.port, error = thread_error }
        end
    end
end

---@return McpServerStatus
function GameMcpServer:get_status()
    return self.status
end

function GameMcpServer:stop()
    if self.pending_action and self.pending_action.kind == "action" then
        self:_abandon_resolution_capture(self.pending_action.resolution_context, "server_stop")
    end
    self.pending_action = nil
    if self.thread then
        self.channels.control:push("stop")
        self.thread:wait()
        self.thread = nil
    end
    if love.threaderror == self.threaderror_handler then
        love.threaderror = self.previous_threaderror
    end
    self.status = { state = "stopped", port = self.status.port or self.port }
end

return GameMcpServer
