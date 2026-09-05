---@class FakeBalatroAdapter: BalatroAdapter
---@field states table[]
---@field transitions table<integer, table<string, table>>
---@field observe_transitions table<integer, integer>
---@field encyclopedias table<string, table>
---@field index integer
---@field ui table?
---@field pending table?
---@field observe_count integer
---@field observe_delay_seconds? number
---@field finished_captures integer
---@field abandoned_captures integer
local FakeBalatroAdapter = {}
FakeBalatroAdapter.__index = FakeBalatroAdapter

local default_encyclopedias = {
    fair = {
        visibility = "fair",
        entries = {
            { key = "j_joker", set = "Joker", name = "Joker", description = "+4 Mult" },
            { key = "j_blueprint", set = "Joker" },
            {
                key = "b_red",
                set = "Back",
                name = "Red Deck",
                description = "+1 discard every round",
            },
            {
                key = "stake_white",
                set = "Stake",
                name = "White Stake",
                description = "Base Difficulty",
            },
        },
    },
    omniscient = {
        visibility = "omniscient",
        entries = {
            { key = "j_joker", set = "Joker", name = "Joker", description = "+4 Mult" },
            {
                key = "j_blueprint",
                set = "Joker",
                name = "Blueprint",
                description = "Copies the ability of the Joker to the right",
            },
            {
                key = "j_caino",
                set = "Joker",
                name = "Caino",
                description = "This Joker gains X1 Mult when a face card is destroyed",
            },
            {
                key = "c_soul",
                set = "Spectral",
                name = "The Soul",
                description = "Creates a Legendary Joker",
            },
            {
                key = "b_red",
                set = "Back",
                name = "Red Deck",
                description = "+1 discard every round",
            },
            {
                key = "stake_white",
                set = "Stake",
                name = "White Stake",
                description = "Base Difficulty",
            },
            {
                key = "stake_gold",
                set = "Stake",
                name = "Gold Stake",
                description = "Rental Jokers appear",
            },
        },
    },
}

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, child in pairs(value) do
        result[copy(key)] = copy(child)
    end
    return result
end

---@param script { states: table[], transitions?: table<integer, table<string, table>>, observe_transitions?: table<integer, integer>, encyclopedias?: table<string, table> }
---@return FakeBalatroAdapter
function FakeBalatroAdapter.new(script)
    return setmetatable({
        states = assert(script.states),
        transitions = script.transitions or {},
        observe_transitions = script.observe_transitions or {},
        encyclopedias = script.encyclopedias or default_encyclopedias,
        index = 1,
        observe_count = 0,
        finished_captures = 0,
        abandoned_captures = 0,
    }, FakeBalatroAdapter)
end

---@param visibility "fair"|"omniscient"
---@return table?, table?
function FakeBalatroAdapter:encyclopedia(visibility)
    local chosen = self.encyclopedias[visibility or "fair"] or self.encyclopedias.fair
    return copy(chosen)
end

---@param visibility "fair"|"omniscient"
---@return table?, table?
function FakeBalatroAdapter:observe(visibility)
    self.observe_count = self.observe_count + 1
    if self.observe_delay_seconds then
        love.timer.sleep(self.observe_delay_seconds)
    end
    if self.pending then
        self.pending.observations = self.pending.observations - 1
        if self.pending.observations > 0 then
            local observe_block = self.pending.observe_block
            if type(observe_block) == "function" then
                observe_block = observe_block(self)
            end
            return nil,
                {
                    code = self.pending.code or "DECISION_PENDING",
                    message = "Decision is still changing",
                    observe_block = observe_block,
                    diagnostic = copy(self.pending.diagnostic),
                }
        end
        self.index = assert(self.pending.next_state)
        self.pending = nil
    end
    local observation = copy(assert(self.states[self.index]))
    observation.ui = copy(self.ui or observation.ui)
    observation.requested_visibility = visibility
    self.index = self.observe_transitions[self.index] or self.index
    return observation
end

---@param action table
---@return table?, table?
function FakeBalatroAdapter:execute(action)
    if type(action.expected_state_hash) ~= "string" then
        return nil, { code = "INTERNAL_ERROR", message = "Expected state hash was not provided" }
    end
    local transition = self.transitions[self.index] and self.transitions[self.index][action.name]
    if not transition then
        return nil, { code = "ACTION_NOT_ALLOWED", message = "Action is not scripted" }
    end
    if
        transition.expected_state_hash
        and action.expected_state_hash ~= transition.expected_state_hash
    then
        return nil, { code = "STALE_STATE", message = "Unexpected expected state hash" }
    end
    if transition.error then
        return nil, copy(transition.error)
    end
    for argument, expected in pairs(transition.arguments or {}) do
        if action.arguments[argument] ~= expected then
            return nil, { code = "INVALID_PARAMS", message = "Unexpected action argument" }
        end
    end
    for _, argument in ipairs(transition.absent_arguments or {}) do
        if action.arguments[argument] ~= nil then
            return nil, { code = "INVALID_PARAMS", message = "Unexpected action argument" }
        end
    end
    if transition.target then
        local actual = action.targets and action.targets[transition.target.argument]
        if actual ~= transition.target.reference then
            return nil, { code = "INVALID_TARGET", message = "Unexpected target reference" }
        end
    end
    if transition.target_order then
        local actual = action.targets and action.targets[transition.target_order.argument] or {}
        local expected = transition.target_order.references
        if #actual ~= #expected then
            return nil, { code = "INVALID_TARGET", message = "Unexpected target order" }
        end
        for index, reference in ipairs(expected) do
            if actual[index] ~= reference then
                return nil, { code = "INVALID_TARGET", message = "Unexpected target order" }
            end
        end
    end
    local resolution = copy(transition.resolution)
    local resolution_context = not transition.no_capture
            and { events = resolution, error = copy(transition.capture_error) }
        or nil
    if transition.pending then
        self.pending = copy(transition.pending)
        return {
            pending = true,
            events = copy(transition.events or {}),
            output = copy(transition.output),
            resolution = resolution,
            resolution_context = resolution_context,
        }
    end
    self.index = transition.next_state or self.index
    return {
        observation = self:observe(action.visibility),
        events = copy(transition.events or {}),
        output = copy(transition.output),
        resolution = resolution,
        resolution_context = resolution_context,
    }
end

function FakeBalatroAdapter:finish_resolution(context)
    self.finished_captures = self.finished_captures + 1
    if context.error then
        return nil, context.error
    end
    local events = context.events
    if type(events) ~= "table" then
        return events
    end
    local by_order, keep = {}, {}
    for _, event in ipairs(events) do
        by_order[event.order] = event
        if (event.effects and event.effects[1]) or event.type == "debuff_blocked" then
            keep[event] = true
        end
    end
    local changed = true
    while changed do
        changed = false
        for _, event in ipairs(events) do
            local parent = event.parent_order and by_order[event.parent_order]
            if keep[event] and parent and not keep[parent] then
                keep[parent] = true
                changed = true
            end
        end
    end
    local retained = {}
    for _, event in ipairs(events) do
        if keep[event] then
            retained[#retained + 1] = event
        end
    end
    return retained[1] and retained or nil
end

function FakeBalatroAdapter:abandon_resolution(_context)
    self.abandoned_captures = self.abandoned_captures + 1
end

---@param ui table
function FakeBalatroAdapter:set_ui(ui)
    self.ui = copy(ui)
end

---@param observation table
function FakeBalatroAdapter:set_observation(observation)
    self.states[self.index] = copy(observation)
end

return FakeBalatroAdapter
