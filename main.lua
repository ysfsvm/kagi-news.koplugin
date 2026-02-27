--[[--
Kagi News — KOReader Plugin Entry Point.

Displays curated news from Kagi Kite with clustered stories,
multiple perspectives, and source links. Optimized for e-ink.

@module koplugin.KagiNews
--]]--

local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local time = require("ui/time")

local KagiNews = WidgetContainer:extend{
    name = "kaginews",
    is_doc_only = false,
}

function KagiNews:init()
    self.ui.menu:registerToMainMenu(self)
    logger.dbg("KagiNews: plugin initialized")
end

function KagiNews:addToMainMenu(menu_items)
    menu_items.kagi_news = {
        text = _("Kagi News"),
        sorting_hint = "more_tools",
        sub_item_table_func = function()
            local Storage = require("storage")
            local items = {
                {
                    text = _("Browse news"),
                    keep_menu_open = false,
                    callback = function()
                        self:openNews()
                    end,
                },
                {
                    text = _("Sync / Download news"),
                    keep_menu_open = false,
                    callback = function()
                        self:syncNews()
                    end,
                },
            }

            local last_sync_time = Storage.getLastSyncTime()
            if last_sync_time then
                local date_str = os.date("%Y-%m-%d %H:%M", last_sync_time)
                local now = os.time()
                local next_update = last_sync_time + (24 * 3600)
                local diff = next_update - now
                
                local remaining_str = ""
                if diff > 0 then
                    local hours = math.floor(diff / 3600)
                    local mins = math.floor((diff % 3600) / 60)
                    remaining_str = string.format(_(" (Next in %dh %dm)"), hours, mins)
                else
                    remaining_str = _(" (Update available)")
                end
                
                table.insert(items, {
                    text = string.format("  ↳ %s: %s%s", _("Updated"), date_str, remaining_str),
                    keep_menu_open = false,
                    callback = function()
                        self:syncNews()
                    end,
                })
            end

            table.insert(items, {
                text = _("Category settings"),
                sub_item_table_func = function()
                    local CategorySelect = require("category_select")
                    return CategorySelect.buildMenu()
                end,
            })
            table.insert(items, {
                text = _("Clear cache"),
                keep_menu_open = true,
                callback = function()
                    local KagiNewsUI = require("ui")
                    KagiNewsUI.clearCacheWithConfirm()
                end,
            })

            return items
        end,
    }
end

function KagiNews:openNews()
    local KagiNewsUI = require("ui")
    KagiNewsUI.showCategoryList()
end

function KagiNews:syncNews()
    local KagiNewsUI = require("ui")

    if NetworkMgr:isOnline() then
        KagiNewsUI.syncNews()
    else
        NetworkMgr:beforeWifiAction(function()
            KagiNewsUI.syncNews()
        end)
    end
end

return KagiNews
