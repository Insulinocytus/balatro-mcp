local port, request_channel_name, response_channel_name, status_channel_name, control_channel_name, request_timeout_ms, max_header_bytes, max_body_bytes =
    ...

local socket = require("socket")
local requests = love.thread.getChannel(request_channel_name)
local responses = love.thread.getChannel(response_channel_name)
local status = love.thread.getChannel(status_channel_name)
local control = love.thread.getChannel(control_channel_name)

local status_text = {
    [200] = "OK",
    [202] = "Accepted",
    [400] = "Bad Request",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [406] = "Not Acceptable",
    [408] = "Request Timeout",
    [413] = "Content Too Large",
    [415] = "Unsupported Media Type",
    [431] = "Request Header Fields Too Large",
    [500] = "Internal Server Error",
    [503] = "Service Unavailable",
}

local function send_response(client, response)
    local body = response.body or ""
    local headers = response.headers or {}
    headers["Content-Length"] = tostring(#body)
    headers["Connection"] = "close"

    local lines = {
        "HTTP/1.1 " .. response.status .. " " .. (status_text[response.status] or "Error"),
    }
    for name, value in pairs(headers) do
        lines[#lines + 1] = name .. ": " .. value
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = body
    client:send(table.concat(lines, "\r\n"))
end

local function reject(client, code, headers)
    send_response(client, { status = code, headers = headers or {}, body = "" })
end

local function read_request(client)
    client:settimeout(1)
    local request_line, line_error = client:receive("*l")
    if not request_line then
        return nil, line_error
    end
    if #request_line > 4096 then
        return nil, "headers_too_large"
    end

    local method, path, version = request_line:match("^(%S+)%s+(%S+)%s+(%S+)$")
    if not method then
        return nil, "bad_request"
    end

    local headers = {}
    local header_bytes = #request_line + 2
    while true do
        local line, err = client:receive("*l")
        if line == nil then
            return nil, err
        end
        header_bytes = header_bytes + #line + 2
        if header_bytes > max_header_bytes then
            return nil, "headers_too_large"
        end
        if line == "" then
            break
        end
        local name, value = line:match("^([^:]+):%s*(.*)$")
        if not name then
            return nil, "bad_request"
        end
        headers[name:lower()] = value:match("^(.-)%s*$")
    end

    local content_length = tonumber(headers["content-length"] or "0")
    if not content_length or content_length < 0 then
        return nil, "bad_request"
    end
    if content_length > max_body_bytes then
        return nil, "body_too_large"
    end

    local body = ""
    if content_length > 0 then
        body = select(1, client:receive(content_length))
        if body == nil then
            return nil, "bad_request"
        end
    end

    return {
        method = method,
        path = path,
        version = version,
        headers = headers,
        body = body,
    }
end

local function valid_host(value, actual_port)
    value = value and value:lower()
    return value == "127.0.0.1:" .. actual_port or value == "localhost:" .. actual_port
end

local function valid_origin(value)
    if value == nil then
        return true
    end
    local host = value:lower():match("^https?://([^/]+)$")
    if not host then
        return false
    end
    return host == "localhost"
        or host == "127.0.0.1"
        or host == "[::1]"
        or host:match("^localhost:%d+$") ~= nil
        or host:match("^127%.0%.0%.1:%d+$") ~= nil
        or host:match("^%[::1%]:%d+$") ~= nil
end

local function content_type_is_json(value)
    return value ~= nil and value:lower():match("^([^;%s]+)") == "application/json"
end

local function accepts_mcp_response(value)
    if value == nil then
        return false
    end
    value = value:lower()
    return value:find("application/json", 1, true) ~= nil
        and value:find("text/event-stream", 1, true) ~= nil
end

local function run()
    local listener, socket_error = socket.tcp()
    if not listener then
        status:push({ state = "error", port = port, error = socket_error })
        return
    end
    listener:setoption("reuseaddr", false)

    local bound, bind_error = listener:bind("127.0.0.1", port)
    if not bound then
        listener:close()
        status:push({ state = "error", port = port, error = bind_error })
        return
    end

    local listening, listen_error = listener:listen(16)
    if not listening then
        listener:close()
        status:push({ state = "error", port = port, error = listen_error })
        return
    end

    listener:settimeout(0.05)
    local _, actual_port = listener:getsockname()
    status:push({ state = "listening", port = actual_port })
    local next_request_id = 0

    while control:pop() ~= "stop" do
        local client = listener:accept()
        if client then
            local request, request_error = read_request(client)
            if not request then
                local codes = {
                    headers_too_large = 431,
                    body_too_large = 413,
                    timeout = 408,
                }
                reject(client, codes[request_error] or 400)
            elseif request.version ~= "HTTP/1.1" then
                reject(client, 400)
            elseif request.path ~= "/mcp" then
                reject(client, 404)
            elseif request.method ~= "POST" then
                reject(client, 405, { Allow = "POST" })
            elseif not valid_host(request.headers.host, actual_port) then
                reject(client, 403)
            elseif not valid_origin(request.headers.origin) then
                reject(client, 403)
            elseif not content_type_is_json(request.headers["content-type"]) then
                reject(client, 415)
            elseif not accepts_mcp_response(request.headers.accept) then
                reject(client, 406)
            else
                next_request_id = next_request_id + 1
                request.id = next_request_id
                request.deadline = socket.gettime() + request_timeout_ms / 1000
                requests:push(request)
                local response_deadline = request.deadline + 1
                local response
                repeat
                    response = responses:demand(math.max(0, response_deadline - socket.gettime()))
                until not response or response.id == request.id
                if response then
                    send_response(client, response)
                else
                    reject(client, 503)
                end
            end
            client:close()
        end
    end

    listener:close()
    status:push({ state = "stopped", port = actual_port })
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    status:push({ state = "error", port = port, error = err })
end
