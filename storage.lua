--[[--
Kagi News storage module.

Handles local file caching of API responses and user settings.
Cache files are stored under DataStorage:getDataDir()/kagi-news/.

@module kaginews.storage
--]]--

local DataStorage = require("datastorage")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local md5 = require("ffi/sha2").md5

local Storage = {}

--- Default cache TTL (deprecated, kept for compatibility if needed).
local DEFAULT_CACHE_TTL = 30 * 60

--- Get (and create if needed) the cache directory (or a subfolder).
-- @string[opt] sub Subfolder name (e.g. "meta", "articles", "images")
-- @treturn string Absolute path to the directory (ends with slash)
function Storage.getCacheDir(sub)
    local dir = DataStorage:getDataDir() .. "/kagi-news"
    if sub then
        dir = dir .. "/" .. sub
    end

    if lfs.attributes(dir, "mode") ~= "directory" then
        logger.dbg("KagiNews: creating directory:", dir)
        util.makePath(dir)
    end
    -- Ensure trailing slash for consistent joining
    if dir:sub(-1) ~= "/" then
        dir = dir .. "/"
    end
    return dir
end

--- Get the path for a specific cache file.
-- @string name Filename
-- @string[opt] sub Subfolder name
-- @treturn string Full path to the cache file
local function cachePath(name, sub)
    return Storage.getCacheDir(sub) .. name
end

--- Save a Lua table as JSON to a cache file.
-- @string name Cache filename
-- @tparam table data Data to serialize
-- @treturn bool True on success
local function saveJson(name, data, sub)
    local path = cachePath(name, sub)
    local content = json.encode(data)
    if not content then
        logger.warn("KagiNews: failed to encode JSON for", name)
        return false
    end

    local f = io.open(path, "w")
    if not f then
        logger.warn("KagiNews: cannot open for writing:", path)
        return false
    end
    f:write(content)
    f:close()
    logger.dbg("KagiNews: saved cache", path)
    return true
end

--- Load a JSON cache file and decode it to a Lua table.
-- @string name Cache filename
-- @treturn table|nil Decoded data, or nil if missing/corrupt
local function loadJson(name, sub)
    local path = cachePath(name, sub)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()

    if not content or content == "" then
        return nil
    end

    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then
        logger.warn("KagiNews: corrupt cache file", path)
        return nil
    end
    return data
end

--- Check if a cache file exists.
-- @string name Cache filename
-- @string[opt] sub Subfolder name
-- @treturn bool True if the cache file exists
function Storage.isCacheValid(name, sub)
    local path = cachePath(name, sub)
    local attr = lfs.attributes(path)
    return attr ~= nil
end

--- Save the categories index to cache.
-- @tparam table data The full kite.json response
function Storage.saveCategoriesCache(data)
    saveJson("categories.json", data, "meta")
end

--- Load the categories index from cache.
-- @treturn table|nil Cached categories data
function Storage.loadCategoriesCache()
    return loadJson("categories.json", "meta")
end

--- Get the last sync timestamp.
-- @treturn number|nil The timestamp of the last successful sync, or nil if no sync has occurred.
function Storage.getLastSyncTime()
    local data = Storage.loadCategoriesCache()
    if data and data.timestamp then
        return tonumber(data.timestamp)
    end
    return nil
end

--- Save a category's article clusters to cache.
-- @string filename The category filename (e.g. "tech.json")
-- @tparam table data The full category response
function Storage.saveArticlesCache(filename, data)
    saveJson("articles_" .. filename, data, "articles")
end

--- Load a category's article clusters from cache.
-- @string filename The category filename
-- @treturn table|nil Cached article data
function Storage.loadArticlesCache(filename)
    return loadJson("articles_" .. filename, "articles")
end

--- Recursive helper to clear a directory.
local function clearDir(dir, keep_settings)
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for f in lfs.dir(dir) do
        if f ~= "." and f ~= ".." then
            local path = dir .. "/" .. f
            local attr = lfs.attributes(path)
            if attr then
                if attr.mode == "directory" then
                    clearDir(path, keep_settings)
                    os.remove(path) -- Try to remove empty dir
                else
                    if not (keep_settings and f == "settings.lua") then
                        os.remove(path)
                    end
                end
            end
        end
    end
end

--- Clear all cached files (except settings).
function Storage.clearCache()
    local base_dir = DataStorage:getDataDir() .. "/kagi-news"
    logger.dbg("KagiNews: clearing all cache in", base_dir)
    clearDir(base_dir, true)
end

--- Check if the provided timestamp belongs to a new day compared to last sync.
-- If so, clear the entire cache to keep things fresh.
function Storage.checkAndFullClearIfNewDay(new_timestamp)
    local last_sync = Storage.getLastSyncTime()
    if not last_sync then return end

    local last_day = os.date("%Y-%m-%d", last_sync)
    local new_day = os.date("%Y-%m-%d", new_timestamp or os.time())

    if last_day ~= new_day then
        logger.info("KagiNews: New day detected (" .. last_day .. " -> " .. new_day .. "), wiping cache.")
        Storage.clearCache()
    end
end

--- Settings file path.
local function settingsPath()
    return Storage.getCacheDir() .. "/settings.lua"
end

--- Load user settings.
-- @treturn table Settings table (may be empty)
function Storage.getSettings()
    local data = loadJson("settings.lua", "meta")
    return data or {}
end

--- Save user settings.
-- @tparam table settings The settings table to persist
function Storage.saveSettings(settings)
    saveJson("settings.lua", settings, "meta")
end



--- Get the list of followed category filenames.
-- @treturn table|nil List of category filenames (e.g. {"tech.json", "world.json"}),
--   or nil if no preference is set (meaning "show all categories").
function Storage.getFollowedCategories()
    local settings = Storage.getSettings()
    return settings.followed_categories  -- nil = all
end

--- Save the list of followed category filenames.
-- @tparam table|nil list Category filenames to follow, or nil to follow all.
function Storage.saveFollowedCategories(list)
    local settings = Storage.getSettings()
    settings.followed_categories = list
    Storage.saveSettings(settings)
end

--- Get the local path for a cached image URL.
-- @string url The full image URL
-- @treturn string The local path where the image is/should be cached
function Storage.getImagePath(url)
    if not url or url == "" then return nil end
    -- Use MD5 hash for safe, short filenames. 
    -- require("ffi/sha2").md5(str) returns a hex string.
    local hash = md5(url)
    local cache_name = "img_" .. hash .. ".jpg"
    local path = Storage.getCacheDir("images") .. cache_name
    return path
end

return Storage
