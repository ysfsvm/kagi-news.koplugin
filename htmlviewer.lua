--[[--
Kagi News HtmlViewer Widget.
Based heavily on KOReader's TextViewer, but uses ScrollHtmlWidget
to seamlessly support inline HTML and local images.

@module kaginews.htmlviewer
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Size = require("ui/size")
local _ = require("gettext")
local Screen = Device.screen

local HtmlViewer = InputContainer:extend{
    title = nil,
    html = nil,
    css = nil,
    width = nil,
    height = nil,
    buttons_table = nil,
    fgcolor = Blitbuffer.COLOR_BLACK,
    text_padding = Size.padding.small,
    text_margin = 0,
    button_padding = 0,
    default_font_size = Screen:scaleBySize(20),
    base_path = nil,
}

function HtmlViewer:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    self.align = "center"
    self.region = Geom:new{
        w = screen_w,
        h = screen_h,
    }
    self.width = self.width or screen_w
    self.height = self.height or screen_h

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    self.titlebar = TitleBar:new{
        width = self.width,
        align = "left",
        with_bottom_line = true,
        title = self.title or _("Article"),
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local buttons = self.buttons_table or {}
    table.insert(buttons, {
        {
            text = "⇱",
            id = "top",
            callback = function()
                self.scroll_html_w:scrollToRatio(0)
            end,
        },
        {
            text = "⇲",
            id = "bottom",
            callback = function()
                self.scroll_html_w:scrollToRatio(1)
            end,
        },
        {
            text = _("Close"),
            callback = function()
                self:onClose()
            end,
        },
    })

    self.button_table = ButtonTable:new{
        width = self.width - 2*self.button_padding,
        buttons = buttons,
        zero_sep = true,
        show_parent = self,
    }

    local textw_height = self.height - self.titlebar:getHeight() - self.button_table:getSize().h
    
    self.scroll_html_w = ScrollHtmlWidget:new{
        html_body = self.html,
        css = self.css,
        html_resource_directory = self.base_path,
        width = self.width - 2*self.text_padding - 2*self.text_margin,
        height = textw_height - 2*self.text_padding - 2*self.text_margin,
        default_font_size = self.default_font_size,
        dialog = self,
    }
    
    self.textw = FrameContainer:new{
        padding = self.text_padding,
        margin = self.text_margin,
        bordersize = 0,
        self.scroll_html_w
    }

    self.frame = FrameContainer:new{
        bordersize = self.covers_fullscreen and 0 or Size.border.window,
        radius = self.covers_fullscreen and 0 or Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.titlebar,
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = self.textw:getSize().h,
                },
                self.textw,
            },
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = self.button_table:getSize().h,
                },
                self.button_table,
            }
        }
    }
    self[1] = WidgetContainer:new{
        align = self.align,
        dimen = self.region,
        self.frame,
    }
end

function HtmlViewer:onClose()
    UIManager:close(self)
    if self.close_callback then
        self.close_callback()
    end
    UIManager:setDirty("all", "full")
    return true
end

function HtmlViewer:onTapClose(arg, ges_ev)
    if ges_ev.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
    end
    return true
end

return HtmlViewer
