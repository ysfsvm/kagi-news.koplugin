--[[--
Kagi News category selection module.

Builds the TouchMenu sub-item table for category settings.
Each category is a native checkbox toggle that auto-saves on tap.

@module kaginews.category_select
--]]--

local Storage = require("storage")
local _ = require("gettext")

local CategorySelect = {}

--- Build category settings sub-menu with native checkboxes.
-- Uses cached categories. Each toggle auto-saves immediately.
-- @treturn table TouchMenu sub_item_table
function CategorySelect.buildMenu()
    local data = Storage.loadCategoriesCache()
    if not data or not data.categories or #data.categories == 0 then
        return {{
            text = _("Sync news first to load categories."),
        }}
    end

    -- Load current selection
    local followed = Storage.getFollowedCategories()
    local selected = {}
    if type(followed) == "table" then
        for _, f in ipairs(followed) do
            selected[f] = true
        end
    end

    -- Helper: persist selection to storage
    local function saveSelection()
        local list = {}
        for _, cat in ipairs(data.categories) do
            if selected[cat.file] then
                table.insert(list, cat.file)
            end
        end
        if #list == 0 or #list == #data.categories then
            Storage.saveFollowedCategories(nil) -- nil = follow all
        else
            Storage.saveFollowedCategories(list)
        end
    end

    local items = {}
    -- Select All
    table.insert(items, {
        text = _("Select all"),
        checked_func = function()
            for _, cat in ipairs(data.categories) do
                if not selected[cat.file] then return false end
            end
            return true
        end,
        callback = function()
            for _, cat in ipairs(data.categories) do
                selected[cat.file] = true
            end
            saveSelection()
        end,
        keep_menu_open = true,
    })
    -- Clear All (with separator after)
    table.insert(items, {
        text = _("Clear all"),
        checked_func = function()
            for _, cat in ipairs(data.categories) do
                if selected[cat.file] then return false end
            end
            return true
        end,
        callback = function()
            for k in pairs(selected) do
                selected[k] = nil
            end
            saveSelection()
        end,
        keep_menu_open = true,
        separator = true,
    })
    -- Category toggles
    for _, cat in ipairs(data.categories) do
        local file = cat.file
        table.insert(items, {
            text = cat.name,
            checked_func = function()
                return selected[file] == true
            end,
            callback = function()
                if selected[file] then
                    selected[file] = nil
                else
                    selected[file] = true
                end
                saveSelection()
            end,
            keep_menu_open = true,
        })
    end

    return items
end

return CategorySelect
