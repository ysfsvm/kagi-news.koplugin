--[[--
Kagi News API module.

Handles all HTTP communication with the Kagi Kite public API.
All functions are synchronous — they should be called inside a
NetworkMgr:beforeWifiAction() callback or after connectivity is confirmed.

Uses KOReader's socketutil for timeouts and ssl.https for HTTPS requests.

LuaSocket/LuaSec table-form request returns:
  success:  1, status_code, response_headers, status_line
  failure:  nil, error_message

@module kaginews.api
--]]--

local https = require("ssl.https")
local logger = require("logger")
local json = require("json")
local socketutil = require("socketutil")

local Api = {}

--- Base URL for the Kagi Kite public API.
local BASE_URL = "https://kite.kagi.com/"

--- Perform an HTTPS GET request and return the decoded JSON.
-- @string url Full URL to fetch
-- @treturn table|nil Decoded JSON table, or nil on error
-- @treturn string|nil Error message on failure
local function httpGetJson(url)
    logger.dbg("KagiNews: fetching", url)

    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)

    -- Table-form request returns: 1, status_code, headers, status_line
    -- On failure returns: nil, error_string
    local ok, status_code, headers, status_line = https.request{
        url = url,
        method = "GET",
        sink = socketutil.table_sink(sink),
    }
    socketutil:reset_timeout()

    logger.dbg("KagiNews: response — ok:", ok,
               "status_code:", status_code,
               "status_line:", status_line,
               "sink chunks:", #sink)

    if not ok then
        local err = "Connection failed: " .. tostring(status_code)
        logger.warn("KagiNews:", err)
        return nil, err
    end

    if status_code ~= 200 then
        local err = "HTTP " .. tostring(status_code) .. " " .. tostring(status_line)
        logger.warn("KagiNews:", err)
        return nil, err
    end

    local body = table.concat(sink)
    logger.dbg("KagiNews: body length:", #body)

    if not body or body == "" then
        logger.warn("KagiNews: empty response body from", url)
        return nil, "Empty response"
    end

    local success, data = pcall(json.decode, body)
    if not success or type(data) ~= "table" then
        logger.warn("KagiNews: JSON parse error —", tostring(data))
        logger.dbg("KagiNews: first 200 chars of body:", body:sub(1, 200))
        return nil, "JSON parse error"
    end

    logger.dbg("KagiNews: successfully decoded JSON from", url)
    return data
end

--- Fetch the list of available news categories.
-- @treturn table|nil Table with `timestamp`, `categories`, `supported_languages`
-- @treturn string|nil Error message on failure
function Api.fetchCategories()
    return httpGetJson(BASE_URL .. "kite.json")
end

--- Fetch article clusters for a specific category.
-- @string filename The category JSON filename (e.g. "tech.json")
-- @treturn table|nil Table with `category`, `timestamp`, `clusters`
-- @treturn string|nil Error message on failure
function Api.fetchArticles(filename)
    if not filename or filename == "" then
        return nil, "No category filename provided"
    end
    return httpGetJson(BASE_URL .. filename)
end

return Api
