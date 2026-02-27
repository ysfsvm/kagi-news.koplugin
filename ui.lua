--[[--
Kagi News UI module.

Provides all user-facing screens: category list, article list, and
article detail view. Uses a re-show pattern for back-navigation
(article detail → article list → category list).

@module kaginews.ui
--]]--

local Font = require("ui/font")
local HtmlViewer = require("htmlviewer")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local Screen = require("device").screen
local Size = require("ui/size")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = require("api")
local Storage = require("storage")
local lfs = require("libs/libkoreader-lfs")

local KagiNewsUI = {}

-- Flag to suppress back-navigation when a menu item is tapped
local navigating_forward = false

-- ─── Helpers ──────────────────────────────────────────────────────────

local function showInfo(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 2,
    })
end

local function showError(text)
    UIManager:show(InfoMessage:new{
        text = "⚠ " .. text,
        icon = "notice-warning",
    })
end

--- Download an image from URL and return the local file path.
local function downloadImage(url, allow_download)
    if not url or url == "" then return nil end

    local https = require("ssl.https")
    local socketutil = require("socketutil")

    local path = Storage.getImagePath(url)

    if lfs.attributes(path, "mode") == "file" then
        logger.dbg("KagiNews: using cached image", path)
        return path
    end

    if not allow_download then
        return nil
    end

    logger.dbg("KagiNews: downloading image", url)
    local sink = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, status_code = https.request{
        url = url,
        method = "GET",
        sink = socketutil.table_sink(sink),
    }
    socketutil:reset_timeout()

    if not ok or status_code ~= 200 then
        logger.warn("KagiNews: image download failed —", status_code, "url:", url)
        return nil
    end

    local body = table.concat(sink)
    if not body or body == "" then 
        logger.warn("KagiNews: image download returned empty body — url:", url)
        return nil 
    end

    local f = io.open(path, "wb")
    if not f then 
        logger.warn("KagiNews: could not open image path for writing:", path)
        return nil 
    end
    f:write(body)
    f:close()
    logger.dbg("KagiNews: saved image to", path)
    return path
end

local function viewImage(url, caption)
    if not url or url == "" then
        showInfo(_("No image available."))
        return
    end
    showInfo(_("Loading image…"), 1)
    local path = downloadImage(url, false)
    logger.dbg("KagiNews: viewImage path result:", path)
    if not path then
        showError(_("Image not available. Please sync first to download it."))
        return
    end
    local viewer = ImageViewer:new{
        file = path,
        title_text = caption or _("Image"),
        fullscreen = true,
        with_title_bar = true,
    }
    UIManager:show(viewer)
end

-- ─── Article text builder ─────────────────────────────────────────────

local Storage = require("storage")

local function buildArticleHtml(cluster)
    local parts = {}
    local references = {}
    local ref_map = {}

    -- Helper to collect and format citations
    local function process_citations(text)
        if type(text) ~= "string" then return text end
        -- Kagi citations are usually [1], [1-4], [source.com#1]
        -- We'll simplify and style them
        return text:gsub("%[([^%]]+)%]", function(ref)
            if not ref_map[ref] then
                table.insert(references, ref)
                ref_map[ref] = #references
            end
            return string.format("<sup class='cite'>[%d]</sup>", ref_map[ref])
        end)
    end

    local css = [[
        @page { margin: 0 !important; padding: 0 !important; }
        html, body { 
            font-family: sans-serif; 
            padding: 12px !important; 
            margin: 0 !important; 
            line-height: 1.5; 
        }
        .topic { 
            font-size: 0.75em; 
            font-weight: bold; 
            text-transform: uppercase; 
            color: #666; 
            margin-bottom: 4px;
            letter-spacing: 0.05em;
        }
        h1 { font-size: 1.4em; margin: 0 0 12px 0; border:none; }
        .summary { font-size: 1.1em; line-height: 1.4; margin-bottom: 16px; }
        
        h2 { 
            font-size: 1em; 
            font-weight: bold; 
            margin: 24px 0 12px 0; 
            text-transform: uppercase; 
            letter-spacing: 0.1em;
            border-bottom: 1px solid #ccc;
            padding-bottom: 4px;
        }

        .highlight-item { margin-bottom: 16px; display: table; width: 100%; }
        .hl-num { 
            display: table-cell; 
            width: 28px; 
            height: 28px; 
            border: 1px solid #666; 
            border-radius: 50%; 
            text-align: center; 
            vertical-align: middle; 
            font-weight: bold;
            font-size: 0.9em;
        }
        .hl-content { display: table-cell; padding-left: 12px; vertical-align: top; }
        .hl-title { font-weight: bold; display: block; margin-bottom: 2px; }

        .perspective-card { 
            border: 1px solid #ddd; 
            padding: 12px; 
            margin-bottom: 12px; 
            border-radius: 4px;
        }
        .perspective-title { font-weight: bold; margin-bottom: 4px; display: block; }
        .perspective-body { font-size: 0.95em; }

        .source-grid { display: block; margin-bottom: 16px; }
        .source-tag { 
            display: inline-block; 
            border: 1px solid #ccc; 
            padding: 2px 8px; 
            margin: 0 4px 4px 0; 
            font-size: 0.8em; 
            border-radius: 3px; 
        }

        .cite { font-weight: bold; text-decoration: underline; }
        
        .references { 
            margin-top: 32px; 
            padding-top: 16px; 
            border-top: 2px solid #eee; 
            font-size: 0.85em; 
        }
        .ref-item { margin-bottom: 6px; }

        .figure { text-align: center; margin: 16px 0; }
        img { max-width: 100%; height: auto; border-radius: 4px; border: 1px solid #ddd; }
        figcaption { font-size: 0.8em; margin-top: 4px; font-style: italic; }
        
        hr { border: 0; border-top: 1px solid #eee; margin: 20px 0; }
    ]]

    local function inject_image(img_obj)
        if type(img_obj) == "table" and img_obj.url and img_obj.url ~= "" then
            local cached_path = Storage.getImagePath(img_obj.url)
            local attr = lfs.attributes(cached_path)
            if attr and attr.mode == "file" then
                table.insert(parts, "<div class='figure'>")
                local filename = cached_path:match("([^/]+)$")
                table.insert(parts, string.format("<img src='images/%s' />", filename))
                if img_obj.caption and img_obj.caption ~= "" then
                    table.insert(parts, string.format("<figcaption>%s</figcaption>", img_obj.caption))
                end
                table.insert(parts, "</div>")
            end
        end
    end

    -- 1. TOPIC CHIP
    local topic = cluster.category or "News"
    table.insert(parts, string.format("<div class='topic'>%s</div>", topic))

    -- 2. TITLE
    local title = cluster.title or "Untitled"
    if cluster.emoji then
        title = cluster.emoji .. " " .. title
    end
    table.insert(parts, string.format("<h1>%s</h1>", title))

    -- 3. SUMMARY
    if cluster.short_summary and cluster.short_summary ~= "" then
        table.insert(parts, string.format("<div class='summary'>%s</div>", process_citations(cluster.short_summary)))
    end

    -- PRIMARY IMAGE
    inject_image(cluster.primary_image)

    -- 4. HIGHLIGHTS
    if type(cluster.talking_points) == "table" and #cluster.talking_points > 0 then
        table.insert(parts, string.format("<h2>%s</h2>", _("Highlights")))
        for idx, point in ipairs(cluster.talking_points) do
            local c_start, c_end = point:find(": ")
            local title, body
            if c_start then
                title = point:sub(1, c_start - 1)
                body = point:sub(c_end + 1)
            else
                title = ""
                body = point
            end
            table.insert(parts, "<div class='highlight-item'>")
            table.insert(parts, string.format("<div class='hl-num'>%d</div>", idx))
            table.insert(parts, "<div class='hl-content'>")
            if title ~= "" then
                table.insert(parts, string.format("<span class='hl-title'>%s</span>", title))
            end
            table.insert(parts, string.format("<span>%s</span>", process_citations(body)))
            table.insert(parts, "</div></div>")
        end
    end

    -- 5. PERSPECTIVES
    if type(cluster.perspectives) == "table" and #cluster.perspectives > 0 then
        table.insert(parts, string.format("<h2>%s</h2>", _("Perspectives")))
        for _, p in ipairs(cluster.perspectives) do
            table.insert(parts, "<div class='perspective-card'>")
            if type(p.sources) == "table" and #p.sources > 0 then
                table.insert(parts, string.format("<span class='perspective-title'>%s</span>", p.sources[1].name or "Source"))
            end
            table.insert(parts, string.format("<div class='perspective-body'>%s</div>", process_citations(p.text or "")))
            table.insert(parts, "</div>")
        end
    end

    -- 6. TIMELINE
    if type(cluster.timeline) == "table" and #cluster.timeline > 0 then
        table.insert(parts, string.format("<h2>%s</h2>", _("Timeline")))
        for _, event in ipairs(cluster.timeline) do
            table.insert(parts, string.format("<p><strong>%s:</strong> %s</p>", event.date or "", process_citations(event.content or "")))
        end
    end

    -- SECONDARY IMAGE
    inject_image(cluster.secondary_image)

    -- 8. SOURCES & REFERENCES
    if (type(cluster.domains) == "table" and #cluster.domains > 0) or #references > 0 then
        table.insert(parts, "<div class='references'>")
        
        -- Source Domains first
        if type(cluster.domains) == "table" and #cluster.domains > 0 then
            table.insert(parts, string.format("<strong>%s</strong>", _("Source Publishers")))
            table.insert(parts, "<div class='source-grid'>")
            for _, d in ipairs(cluster.domains) do
                table.insert(parts, string.format("<span class='source-tag'>%s</span>", d.name or "Unknown"))
            end
            table.insert(parts, "</div>")
        end

        -- Citation References second
        if #references > 0 then
            table.insert(parts, string.format("<strong>%s</strong>", _("References")))
            for i, ref in ipairs(references) do
                table.insert(parts, string.format("<div class='ref-item'>[%d] %s</div>", i, ref))
            end
        end
        
        table.insert(parts, "</div>")
    end

    return table.concat(parts, "\n"), css
end

-- ─── Screens (with back-navigation) ──────────────────────────────────

--- Show article detail. "Back" re-opens the article list.
-- @tparam table cluster Article cluster data
-- @string category_name Category name for back-navigation title
-- @tparam table clusters All clusters in this category (for back-nav)
function KagiNewsUI.showArticleDetail(cluster, category_name, clusters)
    local html, css = buildArticleHtml(cluster)
    local title = cluster.title or _("Article")

    -- Note: Images are now embedded directly in the HTML via <img> tags
    -- pointing to local cached files. Thus, we no longer need the distinct
    -- "View image" generic action buttons at the bottom.

    -- Removed redundant Back button since HtmlViewer automatically appends a Close button
    viewer = HtmlViewer:new{
        title = title,
        html = html,
        css = css,
        base_path = Storage.getCacheDir(), -- Pass the root cache dir
        covers_fullscreen = true,
        close_callback = function()
            KagiNewsUI.showArticleList(category_name, clusters)
        end,
    }
    UIManager:show(viewer)
end

--- Show article list. "Back" (close) re-opens the category list.
function KagiNewsUI.showArticleList(category_name, clusters)
    local items = {}
    for _, cluster in ipairs(clusters) do
        local title = cluster.title or _("Untitled")
        local source_count = ""
        if type(cluster.domains) == "table" and #cluster.domains > 0 then
            source_count = tostring(#cluster.domains) .. " src"
        end
        table.insert(items, {
            text = title,
            mandatory = source_count,
            callback = function()
                navigating_forward = true
                KagiNewsUI.showArticleDetail(cluster, category_name, clusters)
            end,
        })
    end

    if #items == 0 then
        showInfo(_("No articles found in this category."))
        return
    end

    local menu
    menu = Menu:new{
        title = category_name .. " (" .. tostring(#clusters) .. ")",
        item_table = items,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        is_enable_shortcut = false,
        title_bar_fm_style = true,
        onMenuClose = function()
            UIManager:close(menu)
            if not navigating_forward then
                KagiNewsUI.showCategoryList()
            end
            navigating_forward = false
        end,
    }
    menu.close_callback = function()
        UIManager:close(menu)
        if not navigating_forward then
            KagiNewsUI.showCategoryList()
        end
        navigating_forward = false
    end
    UIManager:show(menu)
end

--- Open a category from cache.
local function openCategory(category)
    local filename = category.file

    -- Try cache first
    if Storage.isCacheValid("articles_" .. filename, "articles") then
        local cached = Storage.loadArticlesCache(filename)
        if cached and cached.clusters then
            logger.dbg("KagiNews: using cached articles for", filename)
            KagiNewsUI.showArticleList(category.name, cached.clusters)
            return
        end
    end

    showInfo(_("No downloaded data for this category. Please sync first."))
end

--- Get cached article count for a category.
local function getCachedArticleCount(filename)
    local cached = Storage.loadArticlesCache(filename)
    if cached and type(cached.clusters) == "table" then
        return tostring(#cached.clusters)
    end
    return nil
end

--- Helper: fetch all categories from cache.
-- @treturn table|nil Full cached kite.json response
local function fetchAllCategories()
    if not Storage.isCacheValid("categories.json", "meta") then
        local sync_now = Trapper:confirm(
            _("No news data found. Download the category list now?"),
            _("Later"),
            _("Download")
        )
        if sync_now then
            if not NetworkMgr:isOnline() then
                showInfo(_("WiFi is required to download categories. Please turn on WiFi and try again."))
                return nil
            end
            Trapper:info(_("Downloading category list…"))
            local data, err = Api.fetchCategories()
            Trapper:clear()
            if data then
                Storage.saveCategoriesCache(data)
                showInfo(_("Category list updated."))
            else
                showError(T(_("Download failed:\n%1"), err or _("Unknown error")))
                return nil
            end
        else
            return nil
        end
    end
    return Storage.loadCategoriesCache()
end

--- Show category list. Close exits the plugin entirely.
-- Only shows followed categories if the user configured a preference.
function KagiNewsUI.showCategoryList()
    local data = fetchAllCategories()
    if not data then return end

    if not data.categories or #data.categories == 0 then
        showInfo(_("No categories available."))
        return
    end

    -- Filter by followed categories (nil = show all)
    local followed = Storage.getFollowedCategories()
    local followed_set = nil
    if type(followed) == "table" and #followed > 0 then
        followed_set = {}
        for _, f in ipairs(followed) do
            followed_set[f] = true
        end
    end

    local items = {}
    for _, cat in ipairs(data.categories) do
        if not followed_set or followed_set[cat.file] then
            local count = getCachedArticleCount(cat.file)
            table.insert(items, {
                text = cat.name,
                mandatory = count,
                callback = function()
                    navigating_forward = true
                    openCategory(cat)
                end,
            })
        end
    end

    if #items == 0 then
        showInfo(_("No followed categories. Go to Category settings to select some."))
        return
    end

    local menu
    menu = Menu:new{
        title = _("Kagi News — Categories"),
        item_table = items,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        is_enable_shortcut = false,
        title_bar_fm_style = true,
        onMenuClose = function()
            UIManager:close(menu)
        end,
    }
    menu.close_callback = function()
        UIManager:close(menu)
    end
    UIManager:show(menu)
end

--- Clear cache and show confirmation.
function KagiNewsUI.clearCacheWithConfirm()
    Storage.clearCache()
    showInfo(_("Cache cleared."))
end

--- Sync / Download news for followed categories.
function KagiNewsUI.syncNews()
    Trapper:wrap(function()
        local followed = Storage.getFollowedCategories()
        if not followed then
            followed = {}
        end

        local sync_message = _("Syncing News")

        -- STEP 1: Check if categories exist. If not, only download categories and stop.
        if not Storage.isCacheValid("categories.json", "meta") then
            Trapper:info(T(_("%1\n\nDownloading category list…"), sync_message))
            local cat_data, err = Api.fetchCategories()
            Trapper:clear()
            if cat_data then
                Storage.saveCategoriesCache(cat_data)
                showInfo(_("Category list updated. You can now select categories in settings."), 4)
            else
                showError(T(_("Could not fetch categories:\n%1"), err or _("Unknown error")))
            end
            return
        end

        -- STEP 2: Categories exist, proceed with full sync for followed categories.
        local should_sync = Trapper:confirm(
            _("Are you sure you want to download the latest news?"),
            _("Cancel"),
            _("Download")
        )
        
        if not should_sync then
            return
        end

        Trapper:info(T(_("%1\n\nRefreshing categories index…"), sync_message))

        local cat_data, err = Api.fetchCategories()
        if not cat_data then
            showError(T(_("Could not fetch categories:\n%1"), err or _("Unknown error")))
            return
        end
        
        -- Auto-clear if sync day changed
        Storage.checkAndFullClearIfNewDay(cat_data.timestamp)
        
        Storage.saveCategoriesCache(cat_data)

        -- If the user never configured "followed", default to following all
        local final_followed = {}
        if #followed > 0 then
            final_followed = followed
        else
            if type(cat_data.categories) == "table" then
                for _, cat in ipairs(cat_data.categories) do
                    table.insert(final_followed, cat.file)
                end
            end
        end

        if #final_followed == 0 then
            showInfo(_("No categories selected. Go to Category settings first."))
            return
        end
    
        local total_categories = #final_followed
        local success_count = 0
        local img_count = 0

        -- Helper to update info widget
        local function updateProgress(subtitle)
            if subtitle then
                local go_on = Trapper:info(T(_("%1\n\n%2"), sync_message, subtitle))
                if not go_on then
                    return false
                end
            end
            return true
        end

        local function dlImages(cluster, cluster_idx, cat_name)
            local function dl(img, label)
                if type(img) == "table" and img.url and img.url ~= "" then
                    if not updateProgress(T(_("Downloading %1 - Article %2 %3…"), cat_name, cluster_idx, label)) then return false end
                    if downloadImage(img.url, true) then
                        img_count = img_count + 1
                    end
                end
                return true
            end
            if not dl(cluster.primary_image, _("primary image")) then return false end
            if not dl(cluster.secondary_image, _("secondary image")) then return false end
            return true
        end

        local cancelled = false
        for i, file in ipairs(final_followed) do
            local cat_name = string.gsub(file, "%.json$", "")
            
            if not updateProgress(T(_("Downloading category: %1…"), cat_name)) then
                cancelled = true
                break
            end

            local data, err_msg = Api.fetchArticles(file)
            if data then
                Storage.saveArticlesCache(file, data)
                success_count = success_count + 1
                if type(data.clusters) == "table" then
                    for idx, cluster in ipairs(data.clusters) do
                        if not dlImages(cluster, idx, cat_name) then
                            cancelled = true
                            break
                        end
                    end
                end
            else
                logger.warn("KagiNews: Sync failed for", file, err_msg)
            end
            if cancelled then break end
        end

        Trapper:clear() -- Close Trapper UI if opened
        if cancelled then
            showInfo(_("Sync cancelled."), 2)
        else
            showInfo(T(_("Sync complete.\n%1/%2 downloaded, %3 images."), success_count, total_categories, img_count), 4)
        end
    end)
end

return KagiNewsUI
