---@class BalatroMcpConfig
---@field port integer
---@field request_timeout_ms integer
---@field max_header_bytes integer
---@field max_body_bytes integer
---@field log_level "off"|"error"|"info"|"debug"
---@field visibility "fair"|"omniscient"

---@type BalatroMcpConfig
local config = {
    port = 18790, -- outside common Windows excluded ranges around 50xxx-53xxx
    request_timeout_ms = 30000,
    max_header_bytes = 16384,
    max_body_bytes = 1048576,
    log_level = "info",
    visibility = "fair",
}

return config
