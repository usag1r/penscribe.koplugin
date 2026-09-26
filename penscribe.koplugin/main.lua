--[[--
PenScribe plugin for KOReader.
Enables freehand drawing and annotation with stylus on supported devices.

@module koplugin.penscribe
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local PencilGeometry = require("lib/geometry")
local Screen = Device.screen
local Size = require("ui/size")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local time = require("ui/time")

local PENSCRIBE_VERSION = "1.0.0"

-- Check if device supports touch input
if not Device:isTouchDevice() then
    return { disabled = true }
end

-- Tool types
local TOOL_PEN = "pen"
local TOOL_FOUNTAIN_NIB = "fountain_nib"   -- stamp a fixed-angle chisel nib
local TOOL_FOUNTAIN_DIR = "fountain_dir"   -- round dabs, width from heading
local TOOL_HIGHLIGHTER = "highlighter"
local TOOL_ERASER = "eraser"

-- Annotation grouping constants
local GROUP_TIME_THRESHOLD_S = 10   -- seconds between strokes to be grouped
local GROUP_SPATIAL_THRESHOLD = 200 -- pixels between bboxes to be grouped

-- Annotation image constants
local IMAGE_CAPTURE_V_MARGIN_PX = 24     -- vertical padding around bbox before clamping
local IMAGE_MIN_HEIGHT_PX = 350          -- floor for captured strip height (legibility)
local IMAGE_MAX_DIM = 1280               -- only downscale captures whose longer side exceeds this
local IMAGE_JPEG_QUALITY = 85
local IMAGE_CAPTURE_DEBOUNCE_S = 4       -- seconds after last stroke before capturing
local IMAGE_BADGE_SIZE = 48              -- on-page badge edge (px) when annotation is stale
local IMAGE_BADGE_HIT_PAD = 32           -- extra pixels around badge for tap hit-test
local IMAGE_BADGE_MARGIN_GAP = 5         -- gap from text/screen edge for margin badge

-- Settings keys. Read new first, fall back to legacy; always write both so
-- existing installs keep working and an older plugin copy still finds them.
local SETTINGS_KEY = "penscribe_settings"
local SETTINGS_KEY_LEGACY = "pencil_annotation_settings"
local ENABLED_KEY = "penscribe_enabled"
local ENABLED_KEY_LEGACY = "pencil_annotation_enabled"

-- Module-level reference to the most recently initialized Pencil instance.
-- Used by the bookmark-list hook (a class-level monkey-patch installed once)
-- to find the live plugin without coupling to KOReader internals.
local _active_pencil = nil
local _bookmark_hook_installed = false

local Pencil = InputContainer:extend{
    name = "pencil_annotation",
    is_doc_only = true,  -- Only available when a document is open
    current_stroke = nil,
    strokes = nil,       -- All strokes for current document
    current_tool = TOOL_PEN,
    touch_zones_registered = false,
    undo_stack = {},     -- For undo functionality
    eraser_tool_active = false,  -- Track if physical eraser end is in use (via BTN_TOOL_RUBBER)
    eraser_button_active = false,  -- Hardware eraser button held
    eraser_button_deleted = {},    -- Track deletions for undo
    -- Text-highlight state: true while a side-button + pen-drag is building a
    -- KOReader text-highlight selection via ReaderHighlight. Sticky through
    -- pen lift so releasing the side button mid-drag doesn't abort.
    highlighting = false,

    -- Kindle Scribe: last seen input.stylus_eraser_active (BTN_STYLUS barrel)
    _kindle_barrel_active = false,
    -- Scribe palm rejection: stylus in range / recent lift
    pen_proximity = false,
    palm_reject_until = nil,
    palm_reject_grace_ms = 350,
    -- Missed lift: if contact flags are set but the digitizer has been
    -- silent this long, treat the pen as gone (hover packets count).
    stylus_stale_contact_ms = 1200,
    _last_stylus_sample = nil,
    _pen_tool_in_range = false,
    _stylus_was_contacting = false,

    -- Stylus callback for lowest latency (via Input:registerStylusCallback)
    stylus_callback_registered = false,
    pen_down = false,
    erasing = false,  -- Track if currently in erase mode (for finger modifier)
    pen_x = 0,
    pen_y = 0,

    last_refresh_time = 0,
    refresh_interval_ms = 16,  -- Pen + HL: refresh at most every 16ms during drawing
    dirty_region = nil,  -- Accumulated dirty region for batch refresh

    -- Delayed refresh - only refresh after user stops writing
    pending_refresh = nil,
    refresh_delay_ms = 600, -- Wait 600ms after last stroke before final refresh

    -- Debounced save - coalesces full O(N) serialization across consecutive strokes.
    -- Force-flushed on page change, close, and the deferred-work scheduler.
    pending_save = nil,
    save_delay_ms = 1500,
    dirty_groups = nil, -- Set of groups awaiting syncGroupBookmark (id -> group)

    -- Tool settings
    tool_settings = {
        [TOOL_PEN] = {
            width = 3,
            color = nil,  -- Blitbuffer color, set in init
            color_name = "Black",  -- For persistence and display
            alpha = 255,
        },
        [TOOL_HIGHLIGHTER] = {
            width = 20,  -- Kobo default; Scribe mode raises this in applyScribeModeSettings
            color = nil,  -- Set in init (needs Blitbuffer)
            alpha = 128,
        },
        [TOOL_ERASER] = {
            width = 40,
        },
    },

    -- Side button state
    side_button_down = false,
    side_button_used_for_highlight = false,  -- Track if button was used during a stroke

    tool_rail_tap_armed = false,
    scribe_tool_rail_side = "left",  -- "left" or "right"
    tool_rail_collapsed = false,
    _tool_rail_pressed_id = nil,  -- brief press invert (e.g. undo)
    -- Scribe horizontal thickness bar (top/bottom)
    scribe_hrail_edge = "bottom",  -- "top" or "bottom"
    scribe_hrail_collapsed = false,
    scribe_thickness_step = 3,  -- displayed step for current tool (1..5)
    scribe_thickness_by_tool = nil, -- { pen/eraser/highlighter → step }; filled on load
    scribe_colorsoft = false,  -- show color row on hrail (Colorsoft)
    notes_dir = nil,  -- New Note folder; default home_dir/penscribe_notes
    new_note_datestamp = true,  -- put a date heading in new Markdown notes

    -- After N erase lifts that actually remove ink, full-page UI settle
    -- (stock Kindle does this ~every 6; we use 3).
    _erase_hit_streak = 0,

    -- Available colors for the pen (initialized in init() with actual Blitbuffer colors)
    available_colors = {},
}

function Pencil:init()
    -- CRITICAL: Add plugin to ReaderUI widget tree so it receives ALL key events
    -- This ensures we catch Eraser button press/release events
    table.insert(self.ui, self)                -- Add to widget children for event propagation
    table.insert(self.ui.active_widgets, self) -- Always receive events even when hidden

    self.ui.menu:registerToMainMenu(self)
    self.strokes = {}
    self.page_strokes = {}  -- Index: page -> array of stroke indices
    self.annotation_groups = {}  -- Annotation groups for bookmark integration
    self.strokes_loaded = false  -- Set true after successful loadStrokes
    self.undo_stack = {}

    -- Initialize highlighter color (yellow)
    self.tool_settings[TOOL_HIGHLIGHTER].color = Blitbuffer.Color8(0xDD)  -- Light gray for e-ink

    -- Calculate gray value from highlight_lighten_factor setting
    local lighten_factor = G_reader_settings:readSetting("highlight_lighten_factor") or 0.2
    local gray_value = math.floor(255 * (1 - lighten_factor))

    -- Pen palette: 2×12 shade grid (dark over vivid of the same hue). Opaque
    -- RGB only — alpha/pastel washes to gray on Colorsoft. Neutrals are Color8
    -- so night mode does not invert them.
    self.available_colors = {
        -- Row 1: deep
        { name = "Black",       color = Blitbuffer.COLOR_BLACK },
        { name = "DarkGray",    color = Blitbuffer.Color8(0x44) },
        { name = "DarkBrown",   color = Blitbuffer.ColorRGB32(0x5C, 0x33, 0x14, 0xFF) },
        { name = "Maroon",      color = Blitbuffer.ColorRGB32(0xAA, 0x00, 0x28, 0xFF) },
        { name = "Rust",        color = Blitbuffer.ColorRGB32(0xCC, 0x44, 0x00, 0xFF) },
        { name = "Gold",        color = Blitbuffer.ColorRGB32(0xAA, 0x88, 0x00, 0xFF) },
        { name = "Forest",      color = Blitbuffer.ColorRGB32(0x00, 0x66, 0x33, 0xFF) },
        { name = "Teal",        color = Blitbuffer.ColorRGB32(0x00, 0x77, 0x77, 0xFF) },
        { name = "Navy",        color = Blitbuffer.ColorRGB32(0x1A, 0x1A, 0x99, 0xFF) },
        { name = "DarkPurple",  color = Blitbuffer.ColorRGB32(0x66, 0x00, 0x99, 0xFF) },
        { name = "DarkMagenta", color = Blitbuffer.ColorRGB32(0x99, 0x00, 0x55, 0xFF) },
        { name = "Rose",        color = Blitbuffer.ColorRGB32(0xAA, 0x33, 0x55, 0xFF) },
        -- Row 2: vivid (Amazon-like)
        { name = "Gray",        color = Blitbuffer.Color8(gray_value) },
        { name = "LightGray",   color = Blitbuffer.Color8(0x99) },
        { name = "Brown",       color = Blitbuffer.ColorRGB32(0x99, 0x55, 0x11, 0xFF) },
        { name = "Red",         color = Blitbuffer.ColorRGB32(0xFF, 0x33, 0x00, 0xFF) },
        { name = "Orange",      color = Blitbuffer.ColorRGB32(0xFF, 0x88, 0x00, 0xFF) },
        { name = "Yellow",      color = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0x33, 0xFF) },
        { name = "Green",       color = Blitbuffer.ColorRGB32(0x00, 0xAA, 0x66, 0xFF) },
        { name = "Cyan",        color = Blitbuffer.ColorRGB32(0x00, 0xFF, 0xEE, 0xFF) },
        { name = "Blue",        color = Blitbuffer.ColorRGB32(0x00, 0x66, 0xFF, 0xFF) },
        { name = "Purple",      color = Blitbuffer.ColorRGB32(0xEE, 0x00, 0xFF, 0xFF) },
        { name = "Magenta",     color = Blitbuffer.ColorRGB32(0xFF, 0x00, 0x99, 0xFF) },
        { name = "Pink",        color = Blitbuffer.ColorRGB32(0xFF, 0x55, 0x99, 0xFF) },
    }

    -- Load tool and stylus button settings
    self:loadSettings()

    -- Ensure pen color has a default value (black) if not set
    if not self.tool_settings[TOOL_PEN].color then
        self.tool_settings[TOOL_PEN].color = Blitbuffer.COLOR_BLACK
        self.tool_settings[TOOL_PEN].color_name = "Black"
    end

    -- Register as view module to render strokes
    self.view = self.ui.view
    self.view:registerViewModule("pencil_strokes", self)

    -- Try to load strokes now if doc_settings is ready
    -- (backup: they'll also be loaded in onReaderReady/onReadSettings)
    if self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir then
        logger.info("PenScribe: doc_settings available in init, loading strokes")
        self:loadStrokes()
    else
        logger.info("PenScribe: doc_settings not ready in init, will load in onReaderReady")
    end

    -- Check if plugin is enabled globally and auto-setup
    if self:isEnabled() then
        self:setupPenInput()
    end

    -- Initialize debug logging (if debug mode enabled)
    self:initDebugLog()

    -- Register custom actions for gesture mapping
    Dispatcher:registerAction("pencil_toggle_tool", {
        category = "none",
        event = "PencilToggleTool",
        title = _("PenScribe: toggle pen/eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_toggle_enabled", {
        category = "none",
        event = "PencilToggleEnabled",
        title = _("PenScribe: toggle on/off"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_pen", {
        category = "none",
        event = "PencilSelectPen",
        title = _("PenScribe: select pen"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_eraser", {
        category = "none",
        event = "PencilSelectEraser",
        title = _("PenScribe: select eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_undo", {
        category = "none",
        event = "PencilUndo",
        title = _("PenScribe: undo"),
        reader = true,
        separator = true,
    })

    -- Per-instance state for the annotation-image feature
    self.pending_image_captures = {}
    self.image_data_dirty = false
    _active_pencil = self

    -- Install the (class-level, one-time) bookmark list hook so taps on
    -- pencil bookmarks open the saved image.
    self:installBookmarkHook()

    logger.info("PenScribe: initialized, enabled =", self:isEnabled(), "tool =", self.current_tool, "strokes =", #self.strokes)
end

-- Dispatcher event handlers (for custom gesture mapping)
function Pencil:onPencilToggleTool()
    -- Dead on purpose. The old plugin (and Gesture Manager maps to this
    -- action) used a side-button tap to swap Pen/Era. Barrel is highlight.
    return true
end

function Pencil:onPencilToggleEnabled()
    local enabled = self:isEnabled()
    self:setEnabled(not enabled)
    if self:isEnabled() then
        self:setupPenInput()
        UIManager:show(InfoMessage:new{
            text = _("PenScribe enabled"),
            timeout = 1,
        })
    else
        self:teardownPenInput()
        UIManager:show(InfoMessage:new{
            text = _("PenScribe disabled"),
            timeout = 1,
        })
    end
    UIManager:setDirty(self.view, "ui")
    return true
end

function Pencil:onPencilSelectPen()
    self:setTool(TOOL_PEN, { silent = true })
    UIManager:show(InfoMessage:new{
        text = _("PenScribe tool: pen"),
        timeout = 1,
    })
    UIManager:setDirty(self.view, "ui")
    return true
end

function Pencil:onPencilSelectEraser()
    self:setTool(TOOL_ERASER, { silent = true })
    UIManager:show(InfoMessage:new{
        text = _("Eraser selected"),
        timeout = 1,
    })
    UIManager:setDirty(self.view, "ui")
    return true
end

function Pencil:onPencilUndo()
    self:undoLastStroke()
    return true
end

-- Setup stylus callback for lowest latency pen capture
-- Uses the new Input:registerStylusCallback() API that intercepts stylus events
-- before they reach the gesture detector
function Pencil:setupStylusCallback()
    if self.stylus_callback_registered then return end

    local Input = Device.input
    if not Input or not Input.registerStylusCallback then
        logger.warn("PenScribe: stylus callback API not available")
        return
    end

    local plugin = self

    -- Register the stylus callback
    -- Callback receives: input (Input object), slot (table with slot, id, x, y, tool, timev)
    -- Return true to "dominate" (remove from gesture detection)
    Input:registerStylusCallback(function(input, slot)
        return plugin:handleStylusSlot(input, slot)
    end)

    self.stylus_callback_registered = true
    logger.info("PenScribe: stylus callback registered")
end

-- Transform stylus coordinates based on screen rotation
-- Raw stylus coordinates are in hardware space; framebuffer expects logical (rotated) space
function Pencil:transformCoordinates(x, y)
    local rotation = Screen:getRotationMode()
    return PencilGeometry.transformForRotation(x, y, rotation, Screen:getWidth(), Screen:getHeight())
end


-- Handle a stylus slot from the callback
-- slot = {slot=N, id=N, x=N, y=N, tool=N, timev=timestamp}
-- Kindle Scribe: input.lua maps BTN_STYLUS → stylus_eraser_active and promotes
-- PEN to ERASER. With Scribe mode on, that barrel button freehand-highlights;
-- the real eraser end is BTN_TOOL_RUBBER (ERASER without stylus_eraser_active).
local HIGHLIGHTER_WIDTH_KOBO = 20
local HIGHLIGHTER_WIDTH_SCRIBE = 50

-- Scribe horizontal thickness bar: per-tool step → pixel widths.
-- Pen + fountain share the pen column; HL and eraser keep their own step.
-- Pen steps are moderately spaced (tighter than the earlier wide jumps).
local THICKNESS_STEPS = {
    { pen = 2,  eraser = 20, highlighter = 28 },
    { pen = 4,  eraser = 35, highlighter = 45 },
    { pen = 6,  eraser = 55, highlighter = 70 },
    { pen = 9,  eraser = 80, highlighter = 100 },
    { pen = 13, eraser = 110, highlighter = 130 },
}

-- Neutrals must not be inverted in night mode (they are already dark-on-light
-- ink). These are Color8 like Black/Gray.
local function isNeutralInkName(name)
    return name == "Black" or name == "Gray" or name == "DarkGray"
        or name == "LightGray"
end

function Pencil:isScribeMode()
    return self.scribe_mode == true
end

function Pencil:isColorsoftMode()
    return self:isScribeMode() and self.scribe_colorsoft == true
end

function Pencil:isFountainTool(tool)
    return tool == TOOL_FOUNTAIN_NIB or tool == TOOL_FOUNTAIN_DIR
end

-- Apply thickness step for one tool family. Pen + fountain share the pen
-- column; HL and eraser keep their own last-selected step.
function Pencil:thicknessKeyForTool(tool)
    tool = tool or self.current_tool
    if tool == TOOL_HIGHLIGHTER then
        return TOOL_HIGHLIGHTER
    elseif tool == TOOL_ERASER then
        return TOOL_ERASER
    end
    return TOOL_PEN -- pen + fountain nib/dir
end

function Pencil:clampThicknessStep(step)
    step = math.floor(tonumber(step) or 3)
    if step < 1 then step = 1 end
    if step > #THICKNESS_STEPS then step = #THICKNESS_STEPS end
    return step
end

function Pencil:getThicknessStepForTool(tool)
    local key = self:thicknessKeyForTool(tool)
    local by = self.scribe_thickness_by_tool
    if by and by[key] then
        return self:clampThicknessStep(by[key])
    end
    return self:clampThicknessStep(self.scribe_thickness_step or 3)
end

function Pencil:applyThicknessStep(step, tool)
    local key = self:thicknessKeyForTool(tool or self.current_tool)
    step = self:clampThicknessStep(step)
    self.scribe_thickness_by_tool = self.scribe_thickness_by_tool or {}
    self.scribe_thickness_by_tool[key] = step
    -- Hrail selection follows the tool being edited (usually current).
    if key == self:thicknessKeyForTool(self.current_tool) then
        self.scribe_thickness_step = step
    end
    local row = THICKNESS_STEPS[step]
    if key == TOOL_PEN then
        self.tool_settings[TOOL_PEN].width = row.pen
    elseif key == TOOL_ERASER then
        self.tool_settings[TOOL_ERASER].width = row.eraser
    else
        self.tool_settings[TOOL_HIGHLIGHTER].width = row.highlighter
    end
end

-- Re-apply every tool family's saved step (Scribe mode on / load).
function Pencil:applyAllThicknessSteps()
    self:applyThicknessStep(self:getThicknessStepForTool(TOOL_PEN), TOOL_PEN)
    self:applyThicknessStep(self:getThicknessStepForTool(TOOL_ERASER), TOOL_ERASER)
    self:applyThicknessStep(self:getThicknessStepForTool(TOOL_HIGHLIGHTER), TOOL_HIGHLIGHTER)
    self.scribe_thickness_step = self:getThicknessStepForTool(self.current_tool)
end

function Pencil:applyScribeModeSettings()
    if not self:isScribeMode() then
        local width = HIGHLIGHTER_WIDTH_KOBO
        self.tool_settings[TOOL_HIGHLIGHTER].width = width
        self:freeHighlighterLiveBuffers()
        self._kindle_barrel_active = false
        self.pen_proximity = false
        self.palm_reject_until = nil
        self._scribe_palm_block_latched = false
        self._last_stylus_activity = nil
        self._last_stylus_sample = nil
        self._pen_tool_in_range = false
        self._stylus_was_contacting = false
        if self:isFountainTool(self.current_tool) then
            self.current_tool = TOOL_PEN
        end
    else
        self:applyAllThicknessSteps()
        if self:isEnabled() then
            self:setupScribePalmInputHook()
        end
    end
end

-- Scribe palm rejection: ONLY while the stylus is actively in range / writing.
-- When the pen is tucked away, this must return false so finger touch works.
function Pencil:shouldRejectPalmTouches()
    if not self:isScribeMode() or not self:isEnabled() then
        return false
    end

    -- Live contact must keep palms blocked — but a missed lift used to latch
    -- pen_down forever (this gate returned true before idle expiry ran).
    -- Recover only when the digitizer is fully silent (hover still counts).
    local contact = self.pen_down or self.erasing
        or self.eraser_button_active or self.eraser_tool_active
        or self.highlighting
    if contact then
        if self:stylusSamplesAreStale(self.stylus_stale_contact_ms or 1200) then
            self:forceEndStylusContact({ grace = false })
        else
            return true
        end
    end

    local now = time.now()
    local idle_ms = nil
    if self._last_stylus_activity then
        idle_ms = time.to_ms(now - self._last_stylus_activity)
    end

    -- Pen away: drop proximity so capacitive touch works again.
    if idle_ms and idle_ms > 2000 then
        self.eraser_tool_active = false
        self.pen_proximity = false
        self:releaseStalePenSlot()
        self._last_stylus_activity = nil
        idle_ms = nil
    elseif self.pen_proximity then
        if idle_ms and idle_ms > 1200 then
            self.pen_proximity = false
            self._last_stylus_activity = nil
            idle_ms = nil
            self:releaseStalePenSlot()
        elseif not idle_ms then
            self.pen_proximity = false
        end
    end

    if self.eraser_tool_active or self.pen_proximity then
        return true
    end

    -- Brief grace after lift so a resting palm doesn't immediately tap
    if self.palm_reject_until then
        local elapsed = time.to_ms(now - self.palm_reject_until)
        if elapsed >= 0 and elapsed < (self.palm_reject_grace_ms or 350) then
            return true
        end
        self.palm_reject_until = nil
    end

    -- Pen tip currently contacting. Ignore a stuck id>=0 if we haven't seen
    -- stylus activity recently (pen in the case, TOOL_PEN release missed).
    if idle_ms and idle_ms < 1200 then
        local Input = Device.input
        if Input and Input.pen_slot then
            local pen = Input:getMtSlot(Input.pen_slot)
            if pen and pen.id and pen.id >= 0 then
                return true
            end
        end
    end
    return false
end

-- Pen slot can stay id>=0 after the stylus is docked. That made
-- shouldRejectPalmTouches() true forever until sleep/wake.
function Pencil:releaseStalePenSlot()
    local Input = Device.input
    if not Input or not Input.pen_slot or not Input.getMtSlot then return end
    local pen = Input:getMtSlot(Input.pen_slot)
    if pen and pen.id and pen.id >= 0 then
        pen.id = -1
    end
end

function Pencil:noteStylusActivity()
    if not self:isScribeMode() then return end
    self._last_stylus_activity = time.now()
    self.pen_proximity = true
end

-- Any digitizer packet (contact or hover, including a still hover). Finger
-- slots must not refresh this — a palm must not keep a stuck pen_down alive.
function Pencil:noteStylusSample(input, slot)
    if not self:isScribeMode() or not slot then return end
    if slot.tool == 0 then return end -- TOOL_TYPE_FINGER
    if input and input.pen_slot and slot.slot and slot.slot ~= input.pen_slot then
        return
    end
    self._last_stylus_sample = time.now()
end

function Pencil:stylusSamplesAreStale(ms)
    ms = ms or self.stylus_stale_contact_ms or 1200
    -- Prefer digitizer packets; fall back to in-range key activity so a
    -- TOOL_RUBBER press without a slot yet is not treated as a missed lift.
    local last = self._last_stylus_sample or self._last_stylus_activity
    if not last then
        return false
    end
    return time.to_ms(time.now() - last) >= ms
end

-- Same work as a real tip-up / out-of-range: end the stroke, unlock touch.
-- grace=false: this finger event should proceed (stuck-pen recovery).
function Pencil:forceEndStylusContact(opts)
    opts = opts or {}
    if self.highlighting then
        self:finishTextHighlight()
    end
    if self.pen_down and self.erasing then
        self.pen_down = false
        self.erasing = false
        self:commitEraseSession()
        self.eraser_deleted = nil
    elseif self.pen_down then
        self.pen_down = false
        self:endRawStroke()
    elseif self._erase_session then
        self:commitEraseSession()
    end
    if self.eraser_button_active or self.eraser_tool_active then
        self:commitEraseSession()
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        self.eraser_tool_active = false
    end
    self.pen_proximity = false
    self._last_stylus_activity = nil
    self._stylus_was_contacting = false
    self._pen_tool_in_range = false
    self:releaseStalePenSlot()
    self._scribe_palm_block_latched = false
    if opts.grace == false then
        self.palm_reject_until = nil
    else
        self:armPalmRejectGrace()
    end
    if self.input_debug_mode then
        self:writeDebugLog("=== FORCE END STYLUS CONTACT ===")
    end
end

-- Hover / leftover docked contact can stream the same x,y forever. Only
-- motion (or a fresh contact edge) should keep palm-reject armed.
function Pencil:noteStylusMotion(x, y)
    if not self:isScribeMode() then return end
    if x == nil or y == nil then return end
    local last_x, last_y = self._stylus_last_x, self._stylus_last_y
    self._stylus_last_x = x
    self._stylus_last_y = y
    if last_x ~= nil and last_y ~= nil then
        local dx, dy = x - last_x, y - last_y
        if dx * dx + dy * dy < 16 * 16 then
            return
        end
    end
    self:noteStylusActivity()
end

function Pencil:hasRecentStylusContact()
    if self.pen_down then return true end
    if not self._last_stylus_activity then return false end
    return time.to_ms(time.now() - self._last_stylus_activity) < 1200
end

function Pencil:armPalmRejectGrace()
    if self:isScribeMode() then
        self.palm_reject_until = time.now()
    end
end

-- Linux MT protocol B abs codes (capacitive finger panel). Stylus uses ABS_X/Y.
local EV_ABS = 3
local ABS_MT_FIRST = 47  -- ABS_MT_SLOT
local ABS_MT_LAST = 61   -- ABS_MT_TOOL_Y
local ABS_NOP = 100      -- not handled by Input:handleTouchEv → dropped

-- Force-clear active finger/palm contacts on non-pen slots.
function Pencil:clearFingerSlots(input)
    input = input or Device.input
    if not input or not input.ev_slots then return end
    local pen_slot = input.pen_slot
    for slot_id, data in pairs(input.ev_slots) do
        if slot_id ~= pen_slot and data then
            data.id = -1
        end
    end
end

-- Scribe: while stylus is near/down, drop ALL capacitive multitouch events at
-- the input adjust hook so they cannot stomp pen_slot or reach gestures.
function Pencil:setupScribePalmInputHook()
    if self._scribe_palm_hook_installed then return end
    local Input = Device.input
    if not Input or not Input.registerEventAdjustHook then
        logger.warn("PenScribe: event adjust hook API not available for palm filter")
        return
    end
    local plugin = self
    Input:registerEventAdjustHook(function(_input, ev)
        if not plugin:shouldRejectPalmTouches() then
            plugin._scribe_palm_block_latched = false
            return
        end
        -- First frame of a reject window: kill any live finger contacts.
        if not plugin._scribe_palm_block_latched then
            plugin:clearFingerSlots(_input)
            plugin._scribe_palm_block_latched = true
            if plugin.input_debug_mode then
                plugin:writeDebugLog("PALM BLOCK armed — dropping ABS_MT_*")
            end
        end
        if ev.type == EV_ABS and ev.code >= ABS_MT_FIRST and ev.code <= ABS_MT_LAST then
            ev.code = ABS_NOP
        end
    end)
    self._scribe_palm_hook_installed = true
    logger.info("PenScribe: Scribe capacitive palm input hook installed")
end

-- True when a capacitive finger/palm contact is active on a non-pen MT slot.
function Pencil:hasActiveFingerContact(input)
    input = input or Device.input
    if not input or not input.ev_slots then return false end
    local pen_slot = input.pen_slot
    local TOOL_TYPE_FINGER = 0
    for slot_id, data in pairs(input.ev_slots) do
        if slot_id ~= pen_slot and data and data.id and data.id >= 0 then
            if data.tool == nil or data.tool == TOOL_TYPE_FINGER then
                return true
            end
        end
    end
    return false
end

-- True when (x,y) sits on a capacitive finger/palm contact (pen_slot stomped
-- onto that contact). Real writing is near the palm but not on the MT point.
function Pencil:isPointOnFingerContact(x, y, input, radius)
    input = input or Device.input
    if not input or not input.ev_slots then return false end
    local pen_slot = input.pen_slot
    local r2 = (radius or 48) * (radius or 48)
    local TOOL_TYPE_FINGER = 0
    for slot_id, data in pairs(input.ev_slots) do
        if slot_id ~= pen_slot and data and data.id and data.id >= 0 then
            if (data.tool == nil or data.tool == TOOL_TYPE_FINGER) and data.x and data.y then
                local fx, fy = self:transformCoordinates(data.x, data.y)
                local dx, dy = x - fx, y - fy
                if dx * dx + dy * dy <= r2 then
                    return true
                end
            end
        end
    end
    return false
end

-- Scribe: finger frames can stomp pen_slot x/y while tool stays PEN.
-- Only drop TRUE teleports mid-stroke. Do NOT reject "near finger" — writing
-- with a resting palm is almost always within ~48px of a joint, and that
-- filter chopped continuous strokes into gaps.
function Pencil:isScribePenSamplePlausible(x, y, input)
    if not self:isScribeMode() then
        return true
    end
    if self.current_stroke and self.current_stroke.tool == TOOL_HIGHLIGHTER then
        return true
    end
    if not (self.pen_down or self.eraser_button_active or self.erasing) then
        return true
    end
    if self.pen_x == nil or self.pen_y == nil then
        return true
    end
    local dist = math.sqrt((x - self.pen_x) * (x - self.pen_x) + (y - self.pen_y) * (y - self.pen_y))
    local now = time.now()
    local dt_ms = 16
    if self._last_pen_sample_time then
        dt_ms = math.max(1, time.to_ms(now - self._last_pen_sample_time))
    end
    -- ~22 px/ms, floor 320px so 300ppi flicks aren't dropped; ceiling 560px
    -- still catches half-screen teleports to a fingertip.
    local max_step = math.max(320, math.min(560, dt_ms * 22))
    if dist > max_step then
        if self.input_debug_mode then
            self:writeDebugLog(string.format(
                "PALM/JUMP reject dist=%.0f max=%d from (%.0f,%.0f) to (%.0f,%.0f)",
                dist, max_step, self.pen_x, self.pen_y, x, y))
        end
        self._last_pen_sample_time = now
        return false
    end
    return true
end

function Pencil:isKindleBarrelSideButton(input)
    if not self:isScribeMode() then return false end
    input = input or Device.input
    if not (Device.isKindle and Device:isKindle()) then return false end
    if not input then return false end
    -- Stock/patched input.lua disagree on the field name. Either means barrel.
    return input.stylus_eraser_active or input.kobo_eraser_active or false
end

-- Scribe barrel: BTN_STYLUS. Some builds name the key "Eraser" (Kobo map).
function Pencil:isScribeBarrelKey(key, key_str)
    if not self:isScribeMode() then return false end
    if not (Device.isKindle and Device:isKindle()) then return false end
    local k = key and key.key
    if k == "BTN_STYLUS2" or k == "Stylus2" then return false end
    if k == "Eraser" or k == "BTN_STYLUS" or k == "Stylus" then return true end
    key_str = key_str or tostring(key)
    if key_str:match("BTN_STYLUS2") or key_str:match("Stylus2") then
        return false
    end
    return key_str:match("BTN_STYLUS") ~= nil
        or (key_str:match("Stylus") ~= nil and not key_str:match("Highlighter"))
end

-- Whether slot.tool should be treated as the physical eraser end / eraser tool.
function Pencil:slotToolMeansEraser(slot_tool, input)
    -- BTN_TOOL_RUBBER is the real rubber end.
    if self.eraser_tool_active then
        return true
    end
    -- Scribe: KOReader / old pencil input.lua sets BTN_STYLUS and then
    -- rewrites slot.tool PEN→ERASER. That is the barrel, not the eraser tip.
    -- Trust rubber only via BTN_TOOL_RUBBER above.
    if self:isScribeMode() then
        return false
    end
    if self:isKindleBarrelSideButton(input) then
        return false
    end
    if self._barrel_release_at
            and time.to_ms(time.now() - self._barrel_release_at) < 500 then
        return false
    end
    if self.swap_eraser_and_highlighter then
        return slot_tool == 3 -- TOOL_TYPE_HIGHLIGHTER
    end
    return slot_tool == 2 -- TOOL_TYPE_ERASER
end

-- Sync side-button highlight state from Kindle BTN_STYLUS without double-firing
-- when key events already called onStylusButtonPress/Release. Scribe mode only.
function Pencil:syncKindleBarrelSideButton(input)
    if not self:isScribeMode() then return end
    if not (Device.isKindle and Device:isKindle()) then return end
    input = input or Device.input
    local barrel = self:isKindleBarrelSideButton(input)
    if barrel == self._kindle_barrel_active then
        return
    end
    self._kindle_barrel_active = barrel
    if barrel then
        if not self.side_button_down then
            self:onStylusButtonPress()
        end
    elseif self.side_button_down then
        self:onStylusButtonRelease()
    end
end

-- id >= 0 means contact active, id == -1 means contact lifted
function Pencil:handleStylusSlot(input, slot)
    -- Tool types from Linux input subsystem
    local TOOL_TYPE_FINGER = 0
    local TOOL_TYPE_PEN = 1
    local TOOL_TYPE_ERASER = 2
    local TOOL_TYPE_HIGHLIGHTER = 3

    self:noteStylusSample(input, slot)

    -- Debug logging at the very start to see slot.tool
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS SLOT: id=%d x=%d y=%d tool=%d eraser_active=%s barrel=%s rubber=%s",
            slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.eraser_button_active),
            tostring(input and input.stylus_eraser_active),
            tostring(self.eraser_tool_active)))
    end

    -- Physical eraser end always wins — never let the tool rail or tip tool steal it.
    self:syncKindleBarrelSideButton(input)

    -- Do not write slot.tool. KOReader's stylus callback is built around
    -- PEN/ERASER. The old input.lua patch promotes the barrel to ERASER;
    -- that is highlight, not the rubber end (BTN_TOOL_RUBBER).
    if self:isScribeMode() and slot.tool == TOOL_TYPE_ERASER
            and not self.eraser_tool_active then
        if not self.side_button_down then
            self:onStylusButtonPress()
        end
        self._barrel_from_slot_tool = true
    elseif self:isScribeMode() and self._barrel_from_slot_tool
            and slot.tool == TOOL_TYPE_PEN
            and not self:isKindleBarrelSideButton(input) then
        self._barrel_from_slot_tool = false
        if self.side_button_down then
            self:onStylusButtonRelease()
        end
    end

    local tool_is_eraser = self:slotToolMeansEraser(slot.tool, input)
    if tool_is_eraser and not self.eraser_button_active then
        logger.info("PenScribe: Eraser end detected, activating eraser mode")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
        self.tool_rail_tap_armed = false
        -- Clear last tip sample so we don't inherit pen position.
        self.pen_x = nil
        self.pen_y = nil
        self._last_pen_sample_time = nil
    elseif self.eraser_button_active and not tool_is_eraser and not self.eraser_tool_active then
        -- Tip is back — only end eraser mode when rubber is truly gone.
        -- (slot.tool often flickers to PEN while BTN_TOOL_RUBBER is still held.)
        logger.info("PenScribe: Pen tip detected, deactivating eraser mode")
        self:commitEraseSession()
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        self.pen_x = nil
        self.pen_y = nil
        self._last_pen_sample_time = nil
        UIManager:setDirty(self.view, "ui")
    end

    -- Eraser end / rubber: always erase. Tip-tool "Era" is a separate path below.
    if self.eraser_button_active or self.eraser_tool_active then
        self.eraser_button_active = true
        if slot.id and slot.id >= 0 then
            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            -- Screen-space dab only — never scan/delete whole strokes mid-drag.
            self:eraseDabLive(x, y)
            self.pen_x = x
            self.pen_y = y
            self._last_pen_sample_time = time.now()
            self:noteStylusActivity()
        else
            self:commitEraseSession()
        end
        return true
    end

    -- Tool rail: pen tip only (never eraser end / rubber).
    if self:isEnabled()
            and slot.tool ~= TOOL_TYPE_ERASER
            and slot.tool ~= TOOL_TYPE_FINGER then
        if slot.id and slot.id >= 0 then
            if self.tool_rail_tap_armed then
                return true
            end
            local raw_x = slot.x or 0
            local raw_y = slot.y or 0
            local x, y = self:transformCoordinates(raw_x, raw_y)
            -- Barrel click is highlight, not a rail tool pick (hover can sit on Era).
            if not self.side_button_down and self:handleAnyRailTap(x, y) then
                self.tool_rail_tap_armed = true
                self.pen_down = false
                self.erasing = false
                self.current_stroke = nil
                self:freeHighlighterLiveBuffers()
                return true
            end
        else
            self.tool_rail_tap_armed = false
            self:flushAnnotMenuPending()
        end
    elseif slot.id and slot.id < 0 then
        self.tool_rail_tap_armed = false
        self:flushAnnotMenuPending()
    end

    -- Don't capture pen input when a menu or overlay is on top of the reader
    if self:isOverlayActive() then return false end

    -- Scribe: never treat finger/non-pen-slot contacts as stylus drawing
    -- while the stylus is actually in use. If the pen is away, do not eat
    -- fingers — that blocked the KOReader top menu until sleep/wake.
    if self:isScribeMode() then
        if slot.tool == TOOL_TYPE_FINGER then
            return self:shouldRejectPalmTouches()
        end
        if input and input.pen_slot and slot.slot and slot.slot ~= input.pen_slot then
            return self:shouldRejectPalmTouches()
        end
        local stylus_tool = slot.tool == TOOL_TYPE_PEN or slot.tool == TOOL_TYPE_ERASER
                or slot.tool == TOOL_TYPE_HIGHLIGHTER
        local contacting = slot.id and slot.id >= 0
        if stylus_tool then
            -- Real tip contact always draws. Keep activity fresh on EVERY
            -- contact sample (not only >16px moves) so palm-idle expiry
            -- cannot fire mid-stroke.
            if contacting then
                self:noteStylusActivity()
                self._stylus_was_contacting = true
            else
                self._stylus_was_contacting = false
                self:noteStylusMotion(slot.x, slot.y)
            end
        end
    end

    -- Native text-highlight path: runs before any draw/stroke logic.
    -- When input.lua has promoted slot.tool to HIGHLIGHTER (side button held),
    -- route pen events through KOReader's ReaderHighlight instead of creating
    -- a freehand stroke. Sticky: once we enter, we stay until pen lift even
    -- if the side button is released mid-drag.
    if self.experimental_text_highlight
            and (slot.tool == TOOL_TYPE_HIGHLIGHTER or self.highlighting) then
        local current_slot_id = slot.id or -1
        if current_slot_id >= 0 and not self.highlighting then
            self:startTextHighlight(slot.x or 0, slot.y or 0)
        elseif current_slot_id >= 0 and self.highlighting then
            self:extendTextHighlight(slot.x or 0, slot.y or 0)
        elseif current_slot_id < 0 and self.highlighting then
            self:finishTextHighlight()
        end
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Log in debug mode
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS: slot=%d id=%d x=%d y=%d tool=%d pen_down=%s tool=%s",
            slot.slot or -1, slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.pen_down), self.current_tool))
    end

    -- Determine effective tool:
    -- 1. Physical eraser end via slot.tool (TOOL_TYPE_ERASER = 2) takes priority
    --    (Kindle barrel BTN_STYLUS is excluded — that is the highlight side button)
    -- 2. Physical eraser end via BTN_TOOL_RUBBER key event (eraser_tool_active) as backup
    -- 3. Otherwise use selected tool (user can toggle via gesture)
    local effective_tool
    if self:slotToolMeansEraser(slot.tool, input) or self.eraser_tool_active then
        effective_tool = TOOL_ERASER
        if self.input_debug_mode and slot.tool == TOOL_TYPE_ERASER then
            self:writeDebugLog(string.format("ERASER END detected via slot.tool=%d", slot.tool))
        end
    else
        effective_tool = self.current_tool
    end

    -- Handle eraser mode
    if effective_tool == TOOL_ERASER then
        if self.input_debug_mode and not self.erasing then
            self:writeDebugLog(string.format("ERASER MODE: pen_down=%s slot.id=%d",
                tostring(self.pen_down), slot.id or -1))
        end
        if slot.id and slot.id >= 0 then
            -- Eraser is touching - erase at this position
            local first_touch = false
            if not self.pen_down then
                self.pen_down = true
                self.erasing = true
                self.eraser_deleted = {}
                first_touch = true
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER DOWN ===")
                end
            end

            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            -- Erase on first touch OR when position changes
            if first_touch or x ~= self.pen_x or y ~= self.pen_y then
                if self.input_debug_mode then
                    self:writeDebugLog(string.format("ERASE DAB at (%d, %d)", x, y))
                end
                self:eraseDabLive(x, y)
                self.pen_x = x
                self.pen_y = y
            end
        else
            -- Eraser lifted
            if self.pen_down and self.erasing then
                self.pen_down = false
                self.erasing = false
                self:commitEraseSession()
                self.eraser_deleted = nil
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER UP ===")
                end
            end
        end
        return true  -- Dominate: remove from gesture detection
    end

    -- Handle pen/highlighter mode
    if slot.id and slot.id >= 0 then
        -- Pen down or moving
        if not self.pen_down then
            -- Start new stroke
            self.pen_down = true
            self.erasing = false
            self:cancelPendingRefresh()
            self:cancelEraseUiSettle()
            self:startRawStroke()
            local raw_x = slot.x or 0
            local raw_y = slot.y or 0
            local x, y = self:transformCoordinates(raw_x, raw_y)
            self.pen_x = x
            self.pen_y = y
            self._last_pen_sample_time = time.now()
            -- Tip-down dab immediately (stock-feel); waiting for first move
            -- made contact feel lagged.
            self:addRawPoint(x, y)
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN DOWN ===")
            end
        else
            -- Pen is moving
            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            -- Drop finger-contaminated pen_slot samples (teleports to fingertip).
            if not self:isScribePenSamplePlausible(x, y, input) then
                return true
            end
            if x ~= self.pen_x or y ~= self.pen_y then
                self:addRawPoint(x, y)
                self.pen_x = x
                self.pen_y = y
                self._last_pen_sample_time = time.now()
            end
        end
    else
        -- Pen lifted (id == -1)
        if self.pen_down and not self.erasing then
            self.pen_down = false
            self:endRawStroke()
            self:armPalmRejectGrace()
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN UP ===")
            end
        elseif self:isScribeMode() then
            -- Tool left proximity without an active stroke
            self:armPalmRejectGrace()
        end
    end

    return true  -- Dominate: remove from gesture detection
end

-- Teardown stylus callback
function Pencil:teardownStylusCallback()
    if not self.stylus_callback_registered then return end

    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end

    self.stylus_callback_registered = false
    self.pen_down = false
    logger.info("PenScribe: stylus callback unregistered")
end

-- Start a new stroke from raw input
function Pencil:startRawStroke()
    local page = self:getCurrentPage()
    local tool = self.side_button_down and TOOL_HIGHLIGHTER or self.current_tool
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    if self.side_button_down then
        self.side_button_used_for_highlight = true
    end

    self.current_stroke = {
        page = page,
        tool = tool,
        points = {},
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }
    self._fountain_heading = nil
    self.last_refresh_time = time.now()
    self.dirty_region = nil  -- Clear any pending dirty region

    -- HL paints like pen (no live full-screen multiply buffers).
    self:freeHighlighterLiveBuffers()
    -- Never run a deferred multiply paintTo under a live stroke.
    self:cancelHlMultiplySettleTimer()
    if tool == TOOL_HIGHLIGHTER then
        -- Don't let a pen-stroke save land mid-HL (1.5s debounce hitch).
        self:cancelPendingSave()
        -- Side-button HL after A2 ink: flash on lift, not before the first dab.
        if not self._hl_flash_after_first_stroke then
            self:primeHighlighterUiMode()
        end
    end

    logger.dbg("PenScribe: raw stroke started")
end

-- Push accumulated dirty_region to the panel; clears dirty_region.
function Pencil:flushDirtyRefresh(is_hl)
    if not self.dirty_region then return end
    local r = self.dirty_region
    local rx = math.max(0, math.floor(r.x))
    local ry = math.max(0, math.floor(r.y))
    local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
    local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
    self.dirty_region = nil
    if rw <= 0 or rh <= 0 then return end
    if is_hl or not self:isScribeMode() then
        Screen:refreshUI(rx, ry, rw, rh)
        self._ink_used_fast_refresh = false
    else
        Screen:refreshFast(rx, ry, rw, rh)
        self._ink_used_fast_refresh = true
        self._panel_needs_ui_kick = true
    end
    self._last_refresh_rect = { x = rx, y = ry, w = rw, h = rh }
    self.last_refresh_time = time.now()
end

-- Add a point from raw input and draw it
function Pencil:addRawPoint(x, y)
    if not self.current_stroke then return end

    local point = { x = x, y = y }
    table.insert(self.current_stroke.points, point)

    local n = #self.current_stroke.points

    local width = self.current_stroke.width
    local color = self.current_stroke.color
    local half_w = math.floor(width / 2) + 2  -- padding for antialiasing

    -- Reinvert color in night mode (if it's not black or gray)
    if Screen.night_mode and not isNeutralInkName(self.current_stroke.color_name) then
        color = color:invert()
    end

    local is_hl = self.current_stroke.tool == TOOL_HIGHLIGHTER

    -- Draw to framebuffer and track dirty region
    local dirty_x, dirty_y, dirty_w, dirty_h
    if n == 1 then
        if is_hl then
            self:drawHighlighterDab(Screen.bb, x, y, width)
        else
            half_w = self:paintTipDab(Screen.bb, x, y, self.current_stroke, color)
        end
        dirty_x = x - half_w
        dirty_y = y - half_w
        dirty_w = half_w * 2
        dirty_h = half_w * 2
    elseif n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]
        if is_hl then
            self:drawHighlighterSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
            dirty_x = math.min(p1.x, p2.x) - half_w
            dirty_y = math.min(p1.y, p2.y) - half_w
            dirty_w = math.abs(p2.x - p1.x) + width + 4
            dirty_h = math.abs(p2.y - p1.y) + width + 4
        else
            local pad = self:paintTipSegment(Screen.bb, p1, p2, self.current_stroke, color, self)
            dirty_x = math.min(p1.x, p2.x) - pad
            dirty_y = math.min(p1.y, p2.y) - pad
            dirty_w = math.abs(p2.x - p1.x) + pad * 2
            dirty_h = math.abs(p2.y - p1.y) + pad * 2
        end
    end

    -- Accumulate dirty region for batch refresh
    if dirty_x then
        if self.dirty_region then
            local r = self.dirty_region
            local new_x = math.min(r.x, dirty_x)
            local new_y = math.min(r.y, dirty_y)
            local new_x2 = math.max(r.x + r.w, dirty_x + dirty_w)
            local new_y2 = math.max(r.y + r.h, dirty_y + dirty_h)
            self.dirty_region = { x = new_x, y = new_y, w = new_x2 - new_x, h = new_y2 - new_y }
        else
            self.dirty_region = { x = dirty_x, y = dirty_y, w = dirty_w, h = dirty_h }
        end
    end

    -- Live ink: frequent small refreshes. HL needs refreshUI so light gray
    -- shows; match pen's snappier interval on Scribe. Amazon-like two-chunk
    -- refresh is the multiply *settle* after lift — not live drawing.
    local now = time.now()
    local interval = self.refresh_interval_ms or 16
    if self:isScribeMode() and (is_hl or self.current_stroke.tool == TOOL_PEN) then
        interval = math.min(interval, 10)
    end
    if time.to_ms(now - self.last_refresh_time) >= interval then
        self:flushDirtyRefresh(is_hl)
    end
end

-- End stroke from raw input
function Pencil:endRawStroke()
    if self.input_debug_mode then
        self:writeDebugLog(string.format("endRawStroke: current_stroke=%s points=%d",
            tostring(self.current_stroke ~= nil),
            self.current_stroke and #self.current_stroke.points or 0))
    end
    local was_hl = self.current_stroke and self.current_stroke.tool == TOOL_HIGHLIGHTER
    local settle_rect = nil
    if was_hl and self.current_stroke then
        settle_rect = self:unionStrokeRefreshRect({ self.current_stroke }, nil)
    end

    -- Push any unflushed dirty rect before we leave the stroke.
    if self.dirty_region then
        self:flushDirtyRefresh(was_hl)
    end
    if settle_rect then
        self._last_refresh_rect = settle_rect
    end
    if self.current_stroke and #self.current_stroke.points >= 1 then
        local pts = self.current_stroke.points
        local min_dist = 3
        if self:isFountainTool(self.current_stroke.tool) then
            min_dist = 2
        elseif self.current_stroke.tool == TOOL_HIGHLIGHTER then
            min_dist = 4
        end
        if #pts > 8 then
            self.current_stroke.points = PencilGeometry.thinPoints(pts, min_dist)
        end
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:assignStrokeToGroup(#self.strokes)
        self:scheduleDeferredWork()
        if self.input_debug_mode then
            self:writeDebugLog(string.format("endRawStroke: SAVED stroke #%d with %d points, total strokes=%d",
                #self.strokes, #self.current_stroke.points, #self.strokes))
        end
        logger.dbg("PenScribe: raw stroke ended with", #self.current_stroke.points, "points")
    else
        if self.input_debug_mode then
            self:writeDebugLog("endRawStroke: NOT SAVED (no current_stroke or no points)")
        end
    end
    self.current_stroke = nil
    self:freeHighlighterLiveBuffers()
    -- Side-button HL after A2: full GC16 once the first stroke lifts, not
    -- on button press. Multiply settle is redundant after that flash.
    if was_hl and self._hl_flash_after_first_stroke then
        self._hl_flash_after_first_stroke = false
        self:fullPageFlashRefresh()
        return
    end
    -- HL on Scribe: live gray stays; after a short idle (~100ms), multiply
    -- translucency settles in two UI chunks (Amazon-like).
    if was_hl and self:isScribeMode() then
        self:scheduleHlMultiplySettle(settle_rect or self._last_refresh_rect)
    else
        self:scheduleDelayedRefresh("fast", self._last_refresh_rect)
    end
end

-- Paint the in-progress text selection as "invert" rectangles while a
-- highlight drag is active. Mirrors what KOReader does during a normal
-- finger long-press+drag: the reader's paintTo iterates
-- self.view.highlight.temp[page] and inversion-paints each sbox. All we
-- have to do is populate that table with our current sboxes, then
-- setDirty so a repaint runs.
function Pencil:_paintTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight and self.ui.highlight) then
        return
    end
    local rh = self.ui.highlight
    local temp = self.ui.view.highlight.temp
    -- Reset any previous frame's temp entries so stale sboxes from earlier
    -- in the drag don't linger after the selection shrinks.
    for k in pairs(temp) do temp[k] = nil end
    if rh.selected_text and rh.selected_text.sboxes and #rh.selected_text.sboxes > 0 then
        local page_key = rh.hold_pos and rh.hold_pos.page or 1
        temp[page_key] = rh.selected_text.sboxes
    end
    UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
end

-- Clear the in-progress selection preview. Called on pen lift before we
-- persist the selection as a saved highlight (which then paints itself
-- via drawSavedHighlight instead of via temp).
function Pencil:_clearTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight) then return end
    local temp = self.ui.view.highlight.temp
    for k in pairs(temp) do temp[k] = nil end
    UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
end

-- Start a native KOReader text-highlight selection at a raw stylus position.
-- Called from handleStylusSlot when slot.tool has been promoted to HIGHLIGHTER
-- by input.lua (i.e., the side button is held during a pen contact).
--
-- Manipulates self.ui.highlight (ReaderHighlight) directly because there is
-- no public "start programmatic selection" API — the standard entry points
-- (onHold / onHoldPan) do extra work (panel-zoom probing, gesture wiring)
-- that we don't need and that would interact badly with our stylus-sourced
-- events. The methods we do call (getWordFromPosition / getTextFromPositions
-- / saveHighlight) are the same ones KOReader itself invokes internally.
function Pencil:startTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return
    end
    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)
    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return end  -- Tap outside any page area

    local rh = self.ui.highlight
    rh.hold_pos = page_pos

    local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, page_pos)
    if ok and word and word.pos0 and word.pos1 then
        rh.selected_text = {
            text = word.word or "",
            pos0 = word.pos0,
            pos1 = word.pos1,
            sboxes = word.sbox and { word.sbox } or {},
            pboxes = word.pbox and { word.pbox } or {},
        }
    else
        rh.selected_text = nil
    end

    self.highlighting = true
    -- Prevent the drawing-path pen-down branch from also firing on subsequent
    -- events for this contact.
    self.pen_down = true

    -- Show the first-word preview immediately.
    self:_paintTempSelection()
end

-- Extend the active text-highlight selection to a new raw stylus position.
-- Called on each stylus slot update while self.highlighting is true.
function Pencil:extendTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return
    end
    local rh = self.ui.highlight
    if not rh.hold_pos then return end

    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)
    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return end
    rh.holdpan_pos = page_pos

    -- getTextFromPositions handles EPUB (xpointer) and PDF (x/y/page) shapes
    -- and returns a selection dict with pos0/pos1/text/sboxes/pboxes.
    local ok, selected = pcall(self.ui.document.getTextFromPositions,
                               self.ui.document, rh.hold_pos, rh.holdpan_pos)
    if ok and selected and selected.pos0 and selected.pos1 then
        rh.selected_text = selected
        -- Repaint preview with the new sboxes.
        self:_paintTempSelection()
    end
end

-- Persist the current selection as a KOReader highlight annotation and reset.
-- Called on slot.id transitioning to -1 (pen lift) while self.highlighting.
function Pencil:finishTextHighlight()
    local rh = self.ui and self.ui.highlight
    local has_selection = rh and rh.selected_text
        and rh.selected_text.pos0 and rh.selected_text.pos1

    -- Clear the in-progress preview first; the saved highlight's own paint
    -- path (drawSavedHighlight) will take over on the next frame.
    self:_clearTempSelection()

    if has_selection then
        -- saveHighlight(false) builds the annotation item from self.selected_text
        -- and calls self.ui.annotation:addItem(item) internally, handling the
        -- PDF/EPUB item-shape difference. It emits AnnotationsModified itself,
        -- so we do NOT emit a second one here — a userpatch may further wrap
        -- this call to prompt for color, but that's not the plugin's concern.
        local ok, err = pcall(rh.saveHighlight, rh, false)
        if not ok then
            logger.warn("PenScribe: saveHighlight failed:", tostring(err))
        end
    end

    if rh and rh.clear then
        pcall(rh.clear, rh)
    end

    self.highlighting = false
    self.pen_down = false
end

-- Find the index in self.ui.annotation.annotations of a saved text highlight
-- whose rendered boxes cover screen position (screen_x, screen_y).
-- Returns nil if no highlight is at that position.
-- Used by the eraser path so flipping to the eraser end and swiping across a
-- highlight removes it, the same way it removes freehand strokes.
function Pencil:findHighlightAtScreenPos(screen_x, screen_y)
    if not (self.ui and self.ui.annotation and self.ui.annotation.annotations
            and self.ui.view and self.ui.document) then
        return nil
    end

    local is_paging = self.ui.paging ~= nil
    local page_pos
    if is_paging then
        page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
        if not page_pos then return nil end
    end

    for index, item in ipairs(self.ui.annotation.annotations) do
        -- drawer is nil for page-bookmarks; only text highlights have it set.
        if item.drawer and item.pos0 and item.pos1 then
            local boxes
            if is_paging then
                if item.page == page_pos.page then
                    local ok, got = pcall(self.ui.document.getPageBoxesFromPositions,
                                          self.ui.document, page_pos.page, item.pos0, item.pos1)
                    if ok then boxes = got end
                end
            else
                -- Rolling mode (EPUB): work in screen coordinates directly.
                local ok, got = pcall(self.ui.document.getScreenBoxesFromPositions,
                                      self.ui.document, item.pos0, item.pos1, true)
                if ok then boxes = got end
            end
            if boxes then
                local px = is_paging and page_pos.x or screen_x
                local py = is_paging and page_pos.y or screen_y
                for _, box in ipairs(boxes) do
                    if px >= box.x and px < box.x + box.w
                            and py >= box.y and py < box.y + box.h then
                        return index
                    end
                end
            end
        end
    end
    return nil
end

-- Delete any KOReader text highlight at the given screen position.
-- Used by the eraser pass inside handleStylusSlot. removeItemByIndex emits
-- AnnotationsModified and does the logical cleanup, but on e-ink its
-- setDirty is not strong enough to clear the highlight's painted pixels
-- from the framebuffer — users saw the removed highlight linger until the
-- next page turn forced a full refresh. Force a UI-mode setDirty here so
-- the overlay actually disappears.
function Pencil:eraseHighlightAtScreenPos(screen_x, screen_y)
    local index = self:findHighlightAtScreenPos(screen_x, screen_y)
    if not index then return false end
    if not (self.ui and self.ui.bookmark and self.ui.bookmark.removeItemByIndex) then
        return false
    end
    local ok = pcall(self.ui.bookmark.removeItemByIndex, self.ui.bookmark, index)
    if ok then
        UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
    end
    return ok
end

-- Get the path to the plugin's log file
function Pencil:getDebugLogPath()
    -- Write to KOReader's data directory (always writable)
    local log_dir = DataStorage:getDataDir()
    return log_dir .. "/penscribe_input_debug.log"
end

-- Write a line to the debug log file
function Pencil:writeDebugLog(msg)
    if not self.input_debug_mode then return end

    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "a")
    if f then
        local timestamp = os.date("%H:%M:%S")
        f:write(string.format("[%s] %s\n", timestamp, msg))
        f:close()
    end
end

-- Clear the debug log file
function Pencil:clearDebugLog()
    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "w")
    if f then
        f:write("=== PenScribe Input Debug Log ===\n")
        f:write("Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        local device_name = "unknown"
        if Device.model then
            device_name = Device.model
        elseif Device.getDeviceName then
            device_name = Device:getDeviceName() or "unknown"
        end
        f:write("Device: " .. device_name .. "\n")
        f:write("==========================================\n\n")
        f:close()
        logger.info("PenScribe: cleared debug log at", log_path)
    end
end

-- Initialize debug logging (clear log and write header)
function Pencil:initDebugLog()
    if not self.input_debug_mode then return end
    self:clearDebugLog()
    self:writeDebugLog("Debug logging enabled")
    local Input = Device.input
    if Input then
        self:writeDebugLog("Input.pen_slot = " .. tostring(Input.pen_slot or "nil"))
    end
end

-- Load plugin settings
function Pencil:loadSettings()
    local settings = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(settings) ~= "table" then
        settings = G_reader_settings:readSetting(SETTINGS_KEY_LEGACY) or {}
    end
    -- Always start with pencil tool when opening a book
    self.current_tool = TOOL_PEN
    -- Input debug mode: log all input details
    self.input_debug_mode = settings.input_debug_mode or false
    -- Experimental features
    self.experimental_bookmark_sync = settings.experimental_bookmark_sync or false
    -- Swap eraser and highlighter
    self.swap_eraser_and_highlighter = settings.swap_eraser_and_highlighter or false
    self.experimental_text_highlight = settings.experimental_text_highlight or false
    -- Scribe mode: Kindle barrel→highlight, thicker translucent highlighter.
    -- Default on for Kindle devices when unset; Kobo stays on the classic path.
    if settings.scribe_mode ~= nil then
        self.scribe_mode = settings.scribe_mode
    else
        self.scribe_mode = Device.isKindle and Device:isKindle() or false
    end
    if settings.scribe_tool_rail_side == "left" or settings.scribe_tool_rail_side == "right" then
        self.scribe_tool_rail_side = settings.scribe_tool_rail_side
    else
        self.scribe_tool_rail_side = "left"
    end
    self.tool_rail_collapsed = settings.tool_rail_collapsed == true
    if settings.scribe_hrail_edge == "top" or settings.scribe_hrail_edge == "bottom" then
        self.scribe_hrail_edge = settings.scribe_hrail_edge
    else
        self.scribe_hrail_edge = "bottom"
    end
    self.scribe_hrail_collapsed = settings.scribe_hrail_collapsed == true
    self.scribe_colorsoft = settings.scribe_colorsoft == true
    if type(settings.notes_dir) == "string" and settings.notes_dir ~= "" then
        self.notes_dir = settings.notes_dir
    end
    self.new_note_datestamp = settings.new_note_datestamp ~= false
    local legacy_step = self:clampThicknessStep(settings.scribe_thickness_step or 3)
    self.scribe_thickness_by_tool = {
        [TOOL_PEN] = legacy_step,
        [TOOL_ERASER] = legacy_step,
        [TOOL_HIGHLIGHTER] = legacy_step,
    }
    local by = settings.scribe_thickness_by_tool
    if type(by) == "table" then
        if by[TOOL_PEN] or by.pen then
            self.scribe_thickness_by_tool[TOOL_PEN] =
                self:clampThicknessStep(by[TOOL_PEN] or by.pen)
        end
        if by[TOOL_ERASER] or by.eraser then
            self.scribe_thickness_by_tool[TOOL_ERASER] =
                self:clampThicknessStep(by[TOOL_ERASER] or by.eraser)
        end
        if by[TOOL_HIGHLIGHTER] or by.highlighter then
            self.scribe_thickness_by_tool[TOOL_HIGHLIGHTER] =
                self:clampThicknessStep(by[TOOL_HIGHLIGHTER] or by.highlighter)
        end
    end
    self.scribe_thickness_step = self:getThicknessStepForTool(self.current_tool)
    self:applyScribeModeSettings()
    -- Load pen color by name and look up the actual color value
    local color_name = settings.pen_color_name
    if color_name then
        self.tool_settings[TOOL_PEN].color_name = color_name
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == color_name then
                self.tool_settings[TOOL_PEN].color = color_info.color
                break
            end
        end
    end
    -- Non-Scribe: restore last pen width if present.
    if settings.pen_width and not self:isScribeMode() then
        self.tool_settings[TOOL_PEN].width = settings.pen_width
    end
end

-- Save plugin settings
function Pencil:saveSettings()
    local payload = {
        input_debug_mode = self.input_debug_mode,
        experimental_bookmark_sync = self.experimental_bookmark_sync,
        experimental_text_highlight = self.experimental_text_highlight,
        pen_color_name = self.tool_settings[TOOL_PEN].color_name,
        swap_eraser_and_highlighter = self.swap_eraser_and_highlighter,
        scribe_mode = self.scribe_mode,
        scribe_tool_rail_side = self.scribe_tool_rail_side or "left",
        tool_rail_collapsed = self.tool_rail_collapsed == true,
        scribe_hrail_edge = self.scribe_hrail_edge or "bottom",
        scribe_hrail_collapsed = self.scribe_hrail_collapsed == true,
        scribe_thickness_step = self:getThicknessStepForTool(self.current_tool),
        scribe_thickness_by_tool = {
            [TOOL_PEN] = self:getThicknessStepForTool(TOOL_PEN),
            [TOOL_ERASER] = self:getThicknessStepForTool(TOOL_ERASER),
            [TOOL_HIGHLIGHTER] = self:getThicknessStepForTool(TOOL_HIGHLIGHTER),
        },
        scribe_colorsoft = self.scribe_colorsoft == true,
        notes_dir = self.notes_dir,
        new_note_datestamp = self.new_note_datestamp ~= false,
        pen_width = self.tool_settings[TOOL_PEN].width,
    }
    G_reader_settings:saveSetting(SETTINGS_KEY, payload)
    G_reader_settings:saveSetting(SETTINGS_KEY_LEGACY, payload)
end

-- Set current tip tool (rail / menu). Physical eraser end is separate.
function Pencil:setTool(tool, opts)
    opts = opts or {}
    self.current_tool = tool
    if self:isScribeMode() then
        -- Restore this tool's last thickness (hrail selection follows).
        self:applyThicknessStep(self:getThicknessStepForTool(tool), tool)
    end
    self:saveSettings()
    -- Full GC16 flash on HL pick: Fast (A2) pen ink makes later HL refreshUI
    -- hitch, especially over existing strokes. Waveform reset here is cheaper
    -- than fighting it mid-stroke. Flash already paints rails.
    if tool == TOOL_HIGHLIGHTER then
        self:fullPageFlashRefresh()
    else
        self:repaintToolRailChromeOnly()
    end
    if opts.silent then
        return
    end
    local display_name
    if tool == TOOL_PEN then
        display_name = _("pen")
    elseif tool == TOOL_FOUNTAIN_NIB then
        display_name = _("nib")
    elseif tool == TOOL_FOUNTAIN_DIR then
        display_name = _("dir")
    elseif tool == TOOL_HIGHLIGHTER then
        display_name = _("highlighter")
    else
        display_name = _("eraser")
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Tool: %1"), display_name),
        timeout = 1,
    })
end

function Pencil:isEnabled()
    local v = G_reader_settings:readSetting(ENABLED_KEY)
    if v == nil then
        v = G_reader_settings:readSetting(ENABLED_KEY_LEGACY)
    end
    return v == true
end

-- Check if a menu or overlay is shown on top of the reader view.
-- When true, pen input should pass through so the overlay can handle it.
function Pencil:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    -- ReaderUI is the document view itself — anything else is an overlay.
    -- getTopmostVisibleWidget skips widgets marked invisible — transient
    -- decorations that paint but don't capture input, e.g. TrapWidget.
    return (top.name or top.id) ~= "ReaderUI"
end

-- Set enabled state (global setting)
function Pencil:setEnabled(enabled)
    G_reader_settings:saveSetting(ENABLED_KEY, enabled)
    G_reader_settings:saveSetting(ENABLED_KEY_LEGACY, enabled)
end

function Pencil:addToMainMenu(menu_items)
    menu_items.pencil_annotation = {
        text = _("PenScribe"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Enabled"),
                checked_func = function()
                    return self:isEnabled()
                end,
                callback = function()
                    self:onPencilToggleEnabled()
                end,
                separator = true,
            },
            {
                text = _("Scribe"),
                help_text = _("Kindle Scribe adaptations: side button freehand-highlights, thicker translucent highlighter, and hard palm rejection. Off = classic Kobo PenScribe behavior."),
                checked_func = function()
                    return self:isScribeMode()
                end,
                callback = function()
                    self.scribe_mode = not self.scribe_mode
                    self:applyScribeModeSettings()
                    self:saveSettings()
                    self:repaintToolRailNow()
                    UIManager:show(InfoMessage:new{
                        text = self.scribe_mode
                            and _("Scribe mode on.")
                            or _("Scribe mode off (Kobo behavior)."),
                        timeout = 2,
                    })
                    UIManager:setDirty(self.view, "ui")
                end,
            },
            {
                text = _("Kindle Scribe Colorsoft"),
                help_text = _("Show the color row on the horizontal thickness bar. For Colorsoft devices; on mono Scribe, non-black colors do not paint."),
                enabled_func = function()
                    return self:isScribeMode()
                end,
                checked_func = function()
                    return self.scribe_colorsoft == true
                end,
                callback = function()
                    self.scribe_colorsoft = not self.scribe_colorsoft
                    self:saveSettings()
                    self:repaintToolRailNow()
                    UIManager:show(InfoMessage:new{
                        text = self.scribe_colorsoft
                            and _("Colorsoft color row on.")
                            or _("Colorsoft color row off."),
                        timeout = 2,
                    })
                    UIManager:setDirty(self.view, "ui")
                end,
                separator = true,
            },
            {
                text = _("Tools"),
                help_text = _("Select pen, fountain, highlighter, or eraser."),
                sub_item_table = {
                    {
                        text = _("Pen"),
                        checked_func = function()
                            return self.current_tool == TOOL_PEN
                        end,
                        callback = function()
                            self:setTool(TOOL_PEN)
                        end,
                    },
                    {
                        text = _("Fountain (nib stamp)"),
                        checked_func = function()
                            return self.current_tool == TOOL_FOUNTAIN_NIB
                        end,
                        enabled_func = function()
                            return self:isScribeMode()
                        end,
                        callback = function()
                            self:setTool(TOOL_FOUNTAIN_NIB)
                        end,
                    },
                    {
                        text = _("Highlighter"),
                        checked_func = function()
                            return self.current_tool == TOOL_HIGHLIGHTER
                        end,
                        callback = function()
                            self:setTool(TOOL_HIGHLIGHTER)
                        end,
                    },
                    {
                        text = _("Eraser"),
                        checked_func = function()
                            return self.current_tool == TOOL_ERASER
                        end,
                        callback = function()
                            self:setTool(TOOL_ERASER)
                        end,
                    },
                },
            },
            {
                text = _("Edit"),
                help_text = _("Undo or clear strokes, pick a notes folder, or show status."),
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("Notes folder: %1"), self:getNotesDir())
                        end,
                        help_text = _("New Note and New Checklist from the rail menu create Markdown files in this folder and open them. Markdown is a blank page you can scribble on, and you can type in it later if you want."),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:chooseNotesDir(touchmenu_instance)
                        end,
                    },
                    {
                        text = _("New Note datestamp"),
                        help_text = _("When enabled, a new note or checklist starts with a date heading. Filenames still include a time so they stay unique."),
                        checked_func = function()
                            return self.new_note_datestamp ~= false
                        end,
                        callback = function()
                            self.new_note_datestamp = not (self.new_note_datestamp ~= false)
                            self:saveSettings()
                        end,
                        separator = true,
                    },
                    {
                        text = _("Undo last stroke"),
                        callback = function()
                            self:undoLastStroke()
                        end,
                        enabled_func = function()
                            return #self.undo_stack > 0
                        end,
                    },
                    {
                        text = _("Clear page strokes"),
                        callback = function()
                            self:clearPageStrokes()
                        end,
                        enabled_func = function()
                            return self:hasStrokesOnCurrentPage()
                        end,
                    },
                    {
                        text = _("Clear all strokes"),
                        callback = function()
                            self:clearAllStrokes()
                        end,
                        enabled_func = function()
                            return #self.strokes > 0
                        end,
                    },
                    {
                        text_func = function()
                            local bytes = self:getImagesSizeBytes()
                            if bytes <= 0 then
                                return _("Clear annotation images: none")
                            elseif bytes < 1024 * 1024 then
                                return T(_("Clear annotation images: %1 KB"), math.floor(bytes / 1024))
                            else
                                return T(_("Clear annotation images: %1 MB"),
                                    string.format("%.1f", bytes / (1024 * 1024)))
                            end
                        end,
                        help_text = _("Saved preview images of your annotations are used to show what you wrote even after the device is rotated, and to preview annotations from the bookmark list. Tap to clear them for this book."),
                        keep_menu_open = true,
                        enabled_func = function()
                            return self:getImagesSizeBytes() > 0
                        end,
                        callback = function(touchmenu_instance)
                            self:purgeAllImages()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                            UIManager:show(InfoMessage:new{
                                text = _("Cleared all annotation preview images for this book."),
                                timeout = 2,
                            })
                        end,
                    },
                    {
                        text = _("Show annotation status"),
                        callback = function()
                            self:showAnnotationStatus()
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Experimental"),
                sub_item_table = {
                    {
                        text = _("Bookmark sync"),
                        help_text = _("Automatically create KOReader bookmarks for PenScribe annotations so you can navigate to annotated pages from the Bookmarks menu."),
                        checked_func = function()
                            return self.experimental_bookmark_sync
                        end,
                        callback = function()
                            self.experimental_bookmark_sync = not self.experimental_bookmark_sync
                            self:saveSettings()
                            if self.experimental_bookmark_sync then
                                self:syncAllBookmarks()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync enabled. PenScribe annotations will appear in the Bookmarks menu."),
                                    timeout = 3,
                                })
                            else
                                self:removeAllPencilBookmarks()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync disabled. PenScribe bookmarks removed."),
                                    timeout = 3,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Text highlight (side button)"),
                        help_text = _("When enabled, holding the stylus side button during a pen drag creates a native KOReader text highlight on the underlying words, like a long-press \xe2\x86\x92 Highlight. Off by default because this is a new integration and has edge cases. Requires a stylus that sends BTN_STYLUS2."),
                        checked_func = function()
                            return self.experimental_text_highlight
                        end,
                        callback = function()
                            self.experimental_text_highlight = not self.experimental_text_highlight
                            self:saveSettings()
                            if self.experimental_text_highlight then
                                UIManager:show(InfoMessage:new{
                                    text = _("Text highlight enabled. Hold the side button while dragging the pen across words."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Text highlight disabled."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Swap Eraser & Highlighter"),
                        help_text = _("Swap which physical stylus end/button activates eraser vs highlighter."),
                        checked_func = function()
                            return self.swap_eraser_and_highlighter
                        end,
                        callback = function()
                            self.swap_eraser_and_highlighter = not self.swap_eraser_and_highlighter
                            self:saveSettings()
                        end,
                    },
                    {
                        text = _("Input debug mode"),
                        help_text = _("Enable detailed logging of input events to help diagnose stylus detection issues."),
                        checked_func = function()
                            return self.input_debug_mode
                        end,
                        callback = function()
                            self.input_debug_mode = not self.input_debug_mode
                            self:saveSettings()
                            if self.input_debug_mode then
                                self:initDebugLog()
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Input debug mode enabled.\n\nLog file: %1\n\nUse both pen tip and eraser end, then check the log."), self:getDebugLogPath()),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Input debug mode disabled."),
                                })
                            end
                        end,
                    },
                    {
                        text = _("Clear debug log"),
                        enabled_func = function()
                            return self.input_debug_mode
                        end,
                        callback = function()
                            self:clearDebugLog()
                            UIManager:show(InfoMessage:new{
                                text = _("Debug log cleared. Ready to capture new input events."),
                                timeout = 2,
                            })
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("About"),
                callback = function()
                    self:showAbout()
                end,
            },
        },
    }
end

-- Compact About dialog: small body text, bold section titles, brief license.
function Pencil:showAbout()
    local content_w = math.min(
        Screen:scaleBySize(420),
        math.floor(Screen:getWidth() * 0.86)
    )
    local face_title = Font:getFace("smallinfofont")
    local face_h = Font:getFace("xx_smallinfofont")
    local face_body = Font:getFace("xx_smallinfofont")
    local widgets = {}

    local function add_span(h)
        table.insert(widgets, VerticalSpan:new{ width = Screen:scaleBySize(h or 6) })
    end
    local function add_heading(text)
        table.insert(widgets, TextWidget:new{
            text = text,
            face = face_h,
            bold = true,
            max_width = content_w,
        })
    end
    local function add_line(text, bold)
        table.insert(widgets, TextWidget:new{
            text = text,
            face = face_body,
            bold = bold == true,
            max_width = content_w,
        })
    end
    local function add_para(text)
        table.insert(widgets, TextBoxWidget:new{
            text = text,
            face = face_body,
            width = content_w,
            alignment = "left",
        })
    end

    table.insert(widgets, TextWidget:new{
        text = _("PenScribe"),
        face = face_title,
        bold = true,
        max_width = content_w,
    })
    add_span(2)
    add_line(PENSCRIBE_VERSION)
    add_span(4)
    add_para(_("Annotate documents with your stylus."))
    add_span(2)
    add_para(_("Freehand drawing, highlighting, and erasing."))
    add_span(6)
    add_para(_("Heavily optimized for Kindle Scribe (enable Scribe mode). Works on other stylus devices in classic mode."))

    add_span(10)
    add_heading(_("Developer"))
    add_span(2)
    add_line("Umut Sagir")
    add_line("github.com/usag1r")

    add_span(10)
    add_heading(_("Credits"))
    add_span(2)
    add_para(_("Built upon pencil.koplugin by mysticknits"))
    add_line("github.com/mysticknits/pencil.koplugin")

    add_span(10)
    add_heading(_("Disclaimer"))
    add_span(2)
    add_para(_("This plugin is experimental. It is provided as is, without warranty of any kind. The authors and contributors shall not be liable for any damages, including data loss or device malfunction, arising from its use."))

    add_span(10)
    add_heading(_("License"))
    add_span(2)
    add_para(_("GNU Affero General Public License v3.0 (AGPL-3.0)"))
    add_para(_("Copyright (C) 2007 Free Software Foundation, Inc. <https://fsf.org/>"))
    add_para(_("Everyone is permitted to copy and distribute verbatim copies of this license document, but changing it is not allowed."))

    add_span(10)
    add_line(_("A KOReader plugin."), true)

    local content = VerticalGroup:new{ align = "left" }
    for _, w in ipairs(widgets) do
        table.insert(content, w)
    end

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        content,
    }
    local movable = MovableContainer:new{ frame }

    local about = InputContainer:new{
        modal = true,
        covers_fullscreen = false,
        [1] = CenterContainer:new{
            dimen = Screen:getSize(),
            ignore_if_over = "height",
            movable,
        },
    }
    about.ges_events = {
        TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
            },
        },
    }
    function about:onTapClose()
        UIManager:close(self)
        return true
    end
    function about:onClose()
        UIManager:close(self)
        return true
    end
    function about:onCloseWidget()
        for _, w in ipairs(widgets) do
            if w.free then w:free() end
        end
    end
    if Device:hasKeys() then
        about.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    UIManager:show(about)
end

-- Show current annotation status for debugging
function Pencil:showAnnotationStatus()
    local page = self:getCurrentPage()
    local page_strokes = self.page_strokes[page] and #self.page_strokes[page] or 0
    local filepath = self:getStrokesFilePath() or "not available"

    -- Show all pages with strokes for debugging
    local pages_info = ""
    for p, indices in pairs(self.page_strokes) do
        pages_info = pages_info .. string.format("\n  %s (%s): %d", tostring(p), type(p), #indices)
    end
    if pages_info == "" then
        pages_info = "\n  (none)"
    end

    -- Stylus callback status
    local Input = Device.input
    local pen_slot = Input and Input.pen_slot or "N/A"
    local stylus_callback_status = self.stylus_callback_registered and "registered" or "not registered"
    local pen_down_status = self.pen_down and "YES" or "no"

    local status_text = T(_([[PenScribe Status

Selected tool: %1
Total strokes: %2
Strokes on this page: %3
Current page: %4 (%5)
Storage file: %6
Enabled: %7

Stylus callback: %9
Pen slot: %10
Pen down: %11

Side button: hold+drag to freehand-highlight (release returns to current tool).

Enable "Input debug mode" to log raw events for diagnosis.

Pages with strokes:%8]]),
        self.current_tool,
        #self.strokes,
        page_strokes,
        tostring(page),
        type(page),
        filepath,
        self:isEnabled() and _("Yes") or _("No"),
        pages_info,
        stylus_callback_status,
        tostring(pen_slot),
        pen_down_status
    )

    UIManager:show(InfoMessage:new{
        text = status_text,
    })
end

-- Handle stylus button press (down event)
-- Side button: hold + drag = temporary freehand highlighter; release returns
-- to the current tool. (No tap-to-toggle — that was unreliable on device.)
function Pencil:onStylusButtonPress()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    self.side_button_down = true
    self.side_button_used_for_highlight = false

    -- Defer the HL GC16 until the first side-button stroke lifts. Flashing
    -- here delayed that first dab. Skip if the panel is already clean.
    if self:isScribeMode()
            and (self._panel_needs_ui_kick or self._ink_used_fast_refresh) then
        self._hl_flash_after_first_stroke = true
    end

    logger.dbg("PenScribe: side button pressed")
    return true
end

-- Handle stylus button release (up event)
function Pencil:onStylusButtonRelease()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    self.side_button_down = false
    self.side_button_used_for_highlight = false
    self._barrel_from_slot_tool = false
    self._barrel_release_at = time.now()
    -- Pressed and released without a stroke: do not flash later.
    if not self.current_stroke then
        self._hl_flash_after_first_stroke = false
    end
    logger.dbg("PenScribe: side button released, tool =", self.current_tool)
    return true
end

-- Handle stylus button and tool events
function Pencil:onKeyPress(key)
    local key_str = tostring(key)

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY PRESS: %s key.key=%s", key_str, tostring(key.key)))
    end

    -- Scribe barrel first: KOReader names it "Eraser". Must not take the
    -- Kobo hardware-eraser path (that was swapping Pen/Era on a tap).
    if self:isScribeBarrelKey(key, key_str) then
        if not self:isEnabled() or self:isOverlayActive() then return false end
        return self:onStylusButtonPress()
    end

    -- Hardware Eraser button - works regardless of pencil enabled state
    if (not self.swap_eraser_and_highlighter and key.key == "Eraser") then
        logger.info("PenScribe: Eraser button PRESSED")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
        return true
    end

    -- BTN_TOOL_RUBBER - physical eraser end - works regardless of pencil enabled state
    if (self.swap_eraser_and_highlighter and (key_str:match("Highlighter") or key_str:match("Stylus"))) or (not self.swap_eraser_and_highlighter and (key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber"))) then
        logger.info("PenScribe: BTN_TOOL_RUBBER press - activating eraser mode")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
        self.eraser_tool_active = true
        self.pen_x = nil
        self.pen_y = nil
        self._last_pen_sample_time = nil
        self._pen_tool_in_range = true
        self:noteStylusActivity()
        return true
    end

    -- BTN_TOOL_PEN - pen tip - deactivate eraser mode.
    -- Do not arm palm-reject here: a docked Scribe pen can stay "in range"
    -- and would lock capacitive touch until sleep/wake.
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.info("PenScribe: BTN_TOOL_PEN press - deactivating eraser mode")
        self:commitEraseSession()
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        self.eraser_tool_active = false
        self.pen_x = nil
        self.pen_y = nil
        self._last_pen_sample_time = nil
        self._pen_tool_in_range = true
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- BTN_STYLUS (331) - side button on stylus (mapped to "Eraser" on Kobo)
    -- BTN_STYLUS2 (332) - second side button (mapped to "Highlighter" on Kobo)
    if (self.swap_eraser_and_highlighter and key.key == "Eraser") or (not self.swap_eraser_and_highlighter and (key_str:match("Highlighter") or key_str:match("Stylus"))) then
        logger.dbg("PenScribe: Stylus button press detected:", key_str)
        return self:onStylusButtonPress()
    end
    return false
end

function Pencil:onKeyRelease(key)
    local key_str = tostring(key)

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY RELEASE: %s key.key=%s", key_str, tostring(key.key)))
    end

    if self:isScribeBarrelKey(key, key_str) then
        if self.eraser_button_active then
            self.eraser_button_active = false
            self:commitEraseSession()
            self.eraser_button_deleted = nil
        end
        if not self:isEnabled() or self:isOverlayActive() then
            self.side_button_down = false
            return true
        end
        return self:onStylusButtonRelease()
    end

    -- Hardware Eraser button released
    if key.key == "Eraser" and self.eraser_button_active then
        logger.info("PenScribe: Eraser button RELEASED")
        self.eraser_button_active = false
        self:commitEraseSession()
        self.eraser_button_deleted = nil
        return true
    end

    -- BTN_TOOL_RUBBER released (eraser end moved away) - works regardless of pencil enabled state
    if key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber") then
        logger.info("PenScribe: BTN_TOOL_RUBBER release - deactivating eraser mode")
        self:commitEraseSession()
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        self.eraser_tool_active = false
        self._pen_tool_in_range = false
        if not self.pen_down then
            self.pen_proximity = false
            self._last_stylus_activity = nil
            self._stylus_was_contacting = false
            self:releaseStalePenSlot()
        end
        self:armPalmRejectGrace()
        UIManager:setDirty(self.view, "ui")
        return true
    end

    -- BTN_TOOL_PEN released (pen out of range / docked).
    -- Never clear the live pen slot while a stroke is in progress — Scribe can
    -- flicker TOOL_PEN release mid-drag and that used to chop strokes.
    -- If contact flags are set but the digitizer is already silent, this is a
    -- real leave after a missed lift, not flicker.
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.dbg("PenScribe: BTN_TOOL_PEN release detected")
        self._pen_tool_in_range = false
        local contact = self.pen_down or self.erasing
            or self.eraser_button_active or self.highlighting
        if contact then
            if self:stylusSamplesAreStale(self.stylus_stale_contact_ms or 1200) then
                self:forceEndStylusContact()
            end
        else
            self.pen_proximity = false
            self._last_stylus_activity = nil
            self._stylus_was_contacting = false
            self:releaseStalePenSlot()
            self:armPalmRejectGrace()
        end
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Side button released
    if key_str:match("Highlighter") or key_str:match("Stylus") then
        logger.dbg("PenScribe: Stylus button release detected:", key_str)
        return self:onStylusButtonRelease()
    end
    return false
end

-- Undo last stroke
function Pencil:strokeRefreshPad(stroke)
    if not stroke then return 8 end
    local w = stroke.width or 3
    if self:isFountainTool(stroke.tool) then
        local _, w_max = PencilGeometry.fountainWidthRange(w)
        return math.ceil(w_max / 2) + 8
    elseif stroke.tool == TOOL_HIGHLIGHTER then
        return math.ceil(w / 2) + 8
    end
    return math.ceil(w / 2) + 8
end

function Pencil:unionStrokeRefreshRect(strokes, into)
    if not strokes then return into end
    for _, stroke in ipairs(strokes) do
        local bbox = PencilGeometry.computeStrokeBbox(stroke)
        if bbox then
            local pad = self:strokeRefreshPad(stroke)
            local x = math.max(0, math.floor(bbox.x0 - pad))
            local y = math.max(0, math.floor(bbox.y0 - pad))
            local x1 = math.min(Screen:getWidth(), math.ceil(bbox.x1 + pad))
            local y1 = math.min(Screen:getHeight(), math.ceil(bbox.y1 + pad))
            local w, h = x1 - x, y1 - y
            if w > 0 and h > 0 then
                if not into then
                    into = { x = x, y = y, w = w, h = h }
                else
                    local rx1 = math.max(into.x + into.w, x + w)
                    local ry1 = math.max(into.y + into.h, y + h)
                    into.x = math.min(into.x, x)
                    into.y = math.min(into.y, y)
                    into.w = rx1 - into.x
                    into.h = ry1 - into.y
                end
            end
        end
    end
    return into
end

-- Stock-style flashing full-page refresh (GC16 / "lightning"): clears Fast
-- (A2) ghosting the way Kindle's notebook refresh does. Direct Screen call
-- because setDirty from the stylus/rail path often waits until the next page.
function Pencil:fullPageFlashRefresh()
    self:cancelPendingRefresh()
    self:cancelEraseUiSettle()
    self._erase_hit_streak = 0
    self._ink_used_fast_refresh = false
    self._panel_needs_ui_kick = false
    if not self.view then
        UIManager:setDirty("all", "full")
        return
    end
    self.view:paintTo(Screen.bb, 0, 0)
    self:paintTo(Screen.bb, 0, 0)
    local rw, rh = Screen:getWidth(), Screen:getHeight()
    if type(Screen.refreshFull) == "function" then
        Screen:refreshFull(0, 0, rw, rh)
    else
        UIManager:setDirty("all", "full")
    end
    self._last_refresh_rect = { x = 0, y = 0, w = rw, h = rh }
end

-- Immediate ink refresh after structural edits (undo). setDirty from the
-- stylus/rail path often waits until the next page turn on e-ink.
function Pencil:forceInkRefresh(rect)
    if not self.view then
        UIManager:setDirty(self.view, "ui")
        return
    end
    self.view:paintTo(Screen.bb, 0, 0)
    self:paintTo(Screen.bb, 0, 0)
    local rx, ry, rw, rh
    local full = false
    if rect and rect.w and rect.h and rect.w > 0 and rect.h > 0 then
        rx = math.max(0, math.floor(rect.x or 0))
        ry = math.max(0, math.floor(rect.y or 0))
        rw = math.min(Screen:getWidth() - rx, math.ceil(rect.w))
        rh = math.min(Screen:getHeight() - ry, math.ceil(rect.h))
    else
        rx, ry = 0, 0
        rw, rh = Screen:getWidth(), Screen:getHeight()
        full = true
    end
    if rw > 0 and rh > 0 then
        Screen:refreshUI(rx, ry, rw, rh)
        self._last_refresh_rect = { x = rx, y = ry, w = rw, h = rh }
        self._ink_used_fast_refresh = false
        if full then
            self._panel_needs_ui_kick = false
        end
    end
end

-- HL multiply settle: paint once, then Amazon-like two UI pushes (~80% + ~20%)
-- instead of one giant refreshUI on the whole stroke bbox.
function Pencil:forceInkRefreshHlTwoPass(rect)
    if not self.view then
        UIManager:setDirty(self.view, "ui")
        return
    end
    self.view:paintTo(Screen.bb, 0, 0)
    self:paintTo(Screen.bb, 0, 0)
    local rx, ry, rw, rh
    if rect and rect.w and rect.h and rect.w > 0 and rect.h > 0 then
        rx = math.max(0, math.floor(rect.x or 0))
        ry = math.max(0, math.floor(rect.y or 0))
        rw = math.min(Screen:getWidth() - rx, math.ceil(rect.w))
        rh = math.min(Screen:getHeight() - ry, math.ceil(rect.h))
    else
        rx, ry = 0, 0
        rw, rh = Screen:getWidth(), Screen:getHeight()
    end
    if rw <= 0 or rh <= 0 then return end

    self._last_refresh_rect = { x = rx, y = ry, w = rw, h = rh }
    self._ink_used_fast_refresh = false
    self._panel_needs_ui_kick = false

    -- Tiny rects: one pass is enough.
    if rw < 48 or rh < 48 then
        Screen:refreshUI(rx, ry, rw, rh)
        return
    end

    if rw >= rh then
        local w1 = math.max(1, math.floor(rw * 0.8))
        local w2 = rw - w1
        Screen:refreshUI(rx, ry, w1, rh)
        if w2 > 0 then
            Screen:refreshUI(rx + w1, ry, w2, rh)
        end
    else
        local h1 = math.max(1, math.floor(rh * 0.8))
        local h2 = rh - h1
        Screen:refreshUI(rx, ry, rw, h1)
        if h2 > 0 then
            Screen:refreshUI(rx, ry + h1, rw, h2)
        end
    end
end

function Pencil:_unionRefreshRects(a, b)
    if not b or not b.w or not b.h or b.w <= 0 or b.h <= 0 then
        return a
    end
    if not a or not a.w or not a.h or a.w <= 0 or a.h <= 0 then
        return { x = b.x, y = b.y, w = b.w, h = b.h }
    end
    local x1 = math.min(a.x, b.x)
    local y1 = math.min(a.y, b.y)
    local x2 = math.max(a.x + a.w, b.x + b.w)
    local y2 = math.max(a.y + a.h, b.y + b.h)
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

function Pencil:cancelHlMultiplySettleTimer()
    if self._hl_multiply_settle then
        UIManager:unschedule(self._hl_multiply_settle)
        self._hl_multiply_settle = nil
    end
end

-- Coalesce Scribe HL multiply settles: full paintTo after a short idle, then
-- two-pass UI like stock. Short delay avoids hitching the next stroke.
function Pencil:scheduleHlMultiplySettle(rect)
    self._hl_settle_rect = self:_unionRefreshRects(self._hl_settle_rect, rect)
    self:cancelHlMultiplySettleTimer()
    self._hl_multiply_settle = UIManager:scheduleIn(0.1, function()
        self._hl_multiply_settle = nil
        if self:isInkBusy() then
            self:scheduleHlMultiplySettle(nil)
            return
        end
        local r = self._hl_settle_rect
        self._hl_settle_rect = nil
        if r then
            self:forceInkRefreshHlTwoPass(r)
        end
    end)
end

-- After Fast (A2) ink, HL's refreshUI can hitch for seconds. Regional
-- forceInkRefresh was not enough and full paintTo on pen-lift made CPU worse.
-- Sticky kick bit survives regional UI settles; prime does one full-screen
-- refreshUI with NO paintTo (waveform reset only), then rail chrome can update.
function Pencil:primeHighlighterUiMode()
    if not self:isScribeMode() then return end
    if not (self._panel_needs_ui_kick or self._ink_used_fast_refresh) then return end
    self._panel_needs_ui_kick = false
    self._ink_used_fast_refresh = false
    self:cancelPendingRefresh()
    self:cancelPendingSave()
    Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
end

-- Tool / thickness changes: redraw opaque rail chrome only. Avoids a full
-- view:paintTo (flip/collapse still use repaintToolRailNow).
function Pencil:repaintToolRailChromeOnly()
    if not self:isEnabled() then
        UIManager:setDirty(self.view, "ui")
        return
    end
    self:paintToolRail(Screen.bb)
    self:paintHRail(Screen.bb)
    local pad = Screen:scaleBySize(12)
    local function refresh_rect(l)
        if not l then return end
        local rx = math.max(0, l.x - pad)
        local ry = math.max(0, l.y - pad)
        local rw = l.w + 2 * pad
        local rh = l.h + 2 * pad
        if rx + rw > Screen:getWidth() then
            rw = Screen:getWidth() - rx
        end
        if ry + rh > Screen:getHeight() then
            rh = Screen:getHeight() - ry
        end
        if rw > 0 and rh > 0 then
            Screen:refreshUI(rx, ry, rw, rh)
        end
    end
    refresh_rect(self:getToolRailLayout())
    refresh_rect(self:getHRailLayout())
end

function Pencil:undoLastStroke()
    if #self.undo_stack == 0 then return end

    local last_action = table.remove(self.undo_stack)
    local refresh_rect = nil

    if last_action.type == "add" then
        -- Remove the stroke that was added
        local stroke_idx = last_action.stroke_idx
        if stroke_idx and self.strokes[stroke_idx] then
            refresh_rect = self:unionStrokeRefreshRect({ self.strokes[stroke_idx] }, nil)
            table.remove(self.strokes, stroke_idx)
            self:rebuildPageIndex()
            self:rebuildAnnotationGroups()
            self:saveStrokes()
            self:forceInkRefresh(refresh_rect)
        end
    elseif last_action.type == "delete" then
        -- Restore deleted strokes
        refresh_rect = self:unionStrokeRefreshRect(last_action.strokes, nil)
        for _, stroke in ipairs(last_action.strokes) do
            table.insert(self.strokes, stroke)
        end
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        self:saveStrokes()
        self:forceInkRefresh(refresh_rect)
    elseif last_action.type == "replace_page" then
        local page = last_action.page
        -- Page-level replace can touch many strokes — refresh the whole page.
        local kept = {}
        for _, stroke in ipairs(self.strokes) do
            if stroke.page ~= page then
                table.insert(kept, stroke)
            else
                refresh_rect = self:unionStrokeRefreshRect({ stroke }, refresh_rect)
            end
        end
        for _, stroke in ipairs(last_action.strokes or {}) do
            table.insert(kept, stroke)
            refresh_rect = self:unionStrokeRefreshRect({ stroke }, refresh_rect)
        end
        self.strokes = kept
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        self:saveStrokes()
        -- Prefer full-page if the union is large / missing
        if not refresh_rect or (refresh_rect.w * refresh_rect.h)
                > (Screen:getWidth() * Screen:getHeight() * 0.45) then
            refresh_rect = nil
        end
        self:forceInkRefresh(refresh_rect)
    end
end

function Pencil:setupPenInput()
    if self.touch_zones_registered then return end

    logger.dbg("PenScribe: setting up touch zones")

    -- Setup stylus callback for lowest latency pen capture
    self:setupStylusCallback()
    if self:isScribeMode() then
        self:setupScribePalmInputHook()
    end
    -- Register touch zones through the UI so they're in the active gesture hierarchy
    -- We need to override ALL gestures that might interfere with drawing
    self.ui:registerTouchZones({
        {
            -- Touch gesture fires IMMEDIATELY on first contact - critical for capturing stroke start
            id = "pencil_draw_touch",
            ges = "touch",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {},
            handler = function(ges)
                return self:onDrawTouch(ges)
            end,
        },
        {
            id = "pencil_draw_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "tap_forward",
                "tap_backward",
                "readerfooter_tap",
                "readerconfigmenu_tap",
                "readerhighlight_tap",
                "readermenu_tap",
                "paging_tap",
                "rolling_tap",
            },
            handler = function(ges)
                return self:onDrawTap(ges)
            end,
        },
        {
            id = "pencil_draw_hold",
            ges = "hold",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "readerhighlight_hold",
                "readerfooter_hold",
            },
            handler = function(ges)
                return self:onDrawHold(ges)
            end,
        },
        {
            id = "pencil_draw_pan",
            ges = "pan",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan",
                "rolling_pan",
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_pan",
            },
            handler = function(ges)
                return self:onDrawPan(ges)
            end,
        },
        {
            id = "pencil_draw_pan_release",
            ges = "pan_release",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan_release",
                "rolling_pan_release",
                "readerhighlight_pan_release",
            },
            handler = function(ges)
                return self:onDrawPanRelease(ges)
            end,
        },
        {
            id = "pencil_draw_swipe",
            ges = "swipe",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_swipe",
            },
            handler = function(ges)
                return self:onDrawSwipe(ges)
            end,
        },
    })
    self.touch_zones_registered = true
end

function Pencil:teardownPenInput()
    if not self.touch_zones_registered then return end

    -- Teardown stylus callback
    self:teardownStylusCallback()

    self.ui:unRegisterTouchZones({
        { id = "pencil_draw_touch" },  -- Must unregister touch zone too
        { id = "pencil_draw_tap" },
        { id = "pencil_draw_hold" },
        { id = "pencil_draw_pan" },
        { id = "pencil_draw_pan_release" },
        { id = "pencil_draw_swipe" },
    })
    self.touch_zones_registered = false
end

-- Handle swipe gestures (block them when drawing mode is active)
function Pencil:onDrawSwipe(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    if self:shouldBlockNavAfterToolRail() then return true end
    if ges and ges.pos and self:pointInAnyRail(ges.pos.x, ges.pos.y) then return true end

    -- Scribe: eat finger/palm gestures while stylus is in range
    if self:shouldRejectPalmTouches() then return true end

    -- If raw input detected pen, block swipe to prevent page turns
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then return false end

    -- Block the swipe - we don't want page turns while drawing
    return true
end

-- Handle tip long press (hold gesture)
function Pencil:onDrawHold(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    if self:shouldBlockNavAfterToolRail() then return true end
    if ges and ges.pos and self:pointInAnyRail(ges.pos.x, ges.pos.y) then return true end

    if self:shouldRejectPalmTouches() then return true end

    -- If raw input detected pen, block hold to prevent reader highlight mode
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then return false end

    -- Block pen hold gestures while drawing mode is active
    return true
end

-- Local panel settle after ink. Do not full-view setDirty: that re-paints
-- every stroke on the page and is what stalled drawing after a few marks.
function Pencil:scheduleDelayedRefresh(mode, rect)
    mode = mode or "fast"
    self:cancelPendingRefresh()
    rect = rect or self._last_refresh_rect

    self.pending_refresh = UIManager:scheduleIn(self.refresh_delay_ms / 1000, function()
        self.pending_refresh = nil
        -- Don't Fast-settle over live HL (same class of mid-ink hitch as save).
        if self:isInkBusy() then
            return
        end
        if not rect then return end
        local rx = math.max(0, math.floor(rect.x or rect.x0 or 0))
        local ry = math.max(0, math.floor(rect.y or rect.y0 or 0))
        local rw, rh
        if rect.w then
            rw = math.ceil(rect.w)
            rh = math.ceil(rect.h)
        else
            rw = math.ceil((rect.x1 or rx) - rx)
            rh = math.ceil((rect.y1 or ry) - ry)
        end
        rw = math.min(Screen:getWidth() - rx, rw)
        rh = math.min(Screen:getHeight() - ry, rh)
        if rw > 0 and rh > 0 then
            if mode == "ui" then
                Screen:refreshUI(rx, ry, rw, rh)
                self._ink_used_fast_refresh = false
            else
                Screen:refreshFast(rx, ry, rw, rh)
                self._ink_used_fast_refresh = true
                self._panel_needs_ui_kick = true
            end
        end
        logger.dbg("PenScribe: delayed refresh triggered mode=", mode)
    end)
end

-- Cancel pending refresh (called when new stroke starts)
function Pencil:cancelPendingRefresh()
    if self.pending_refresh then
        UIManager:unschedule(self.pending_refresh)
        self.pending_refresh = nil
    end
end

-- Schedule a debounced save + bookmark flush after writing pauses.
-- Never run mid-stroke: after pen→HL the first HL lift re-arms this timer, and
-- a save landing during the next stroke matches the "fine for ~2s then glitchy"
-- hitch (save_delay_ms = 1.5s). Reschedule until the tip is up.
function Pencil:scheduleDeferredWork()
    self:cancelPendingSave()
    self.pending_save = UIManager:scheduleIn(self.save_delay_ms / 1000, function()
        self.pending_save = nil
        if self:isInkBusy() then
            self:scheduleDeferredWork()
            return
        end
        self:flushDirtyGroups()
        self:saveStrokes()
    end)
end

function Pencil:cancelPendingSave()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
end

-- Run any pending deferred work immediately. Called before close, page change,
-- or any path that must persist state synchronously.
function Pencil:flushDeferredWork()
    if not self.pending_save and not (self.dirty_groups and next(self.dirty_groups)) then
        return
    end
    self:cancelPendingSave()
    self:flushDirtyGroups()
    self:saveStrokes()
end

-- Sync bookmarks for any groups marked dirty since the last flush. No-op when
-- the experimental bookmark sync feature is off or nothing is pending.
function Pencil:flushDirtyGroups()
    if not self.dirty_groups then return end
    if not self.experimental_bookmark_sync then
        self.dirty_groups = nil
        return
    end
    for _, group in pairs(self.dirty_groups) do
        self:syncGroupBookmark(group)
    end
    self.dirty_groups = nil
end

-- Soft hairline tray (no heavy black slab). Buttons carry the visual weight.
function Pencil:paintRailTray(bb, x, y, w, h)
    if w <= 0 or h <= 0 then return end
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    local b = 1
    bb:paintRect(x, y, w, b, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + h - b, w, b, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, b, h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + w - b, y, b, h, Blitbuffer.COLOR_BLACK)
end

-- Light cell chrome. Selected tools: left accent (vrail). Thickness: bottom
-- underline (hrail). Optional invert for press / strong selected fill.
function Pencil:paintRailCellChrome(bb, btn, opts)
    opts = opts or {}
    local x, y, w, h = btn.x, btn.y, btn.w, btn.h
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    local b = 1
    bb:paintRect(x, y, w, b, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + h - b, w, b, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, b, h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + w - b, y, b, h, Blitbuffer.COLOR_BLACK)
    if opts.selected and opts.accent == "left" then
        local aw = math.max(3, Screen:scaleBySize(4))
        bb:paintRect(x + b, y + b, aw, h - 2 * b, Blitbuffer.COLOR_BLACK)
    elseif opts.selected and opts.accent == "bottom" then
        local ah = math.max(3, Screen:scaleBySize(4))
        bb:paintRect(x + b, y + h - b - ah, w - 2 * b, ah, Blitbuffer.COLOR_BLACK)
    elseif opts.selected and opts.accent == "ring" then
        local t = math.max(2, Screen:scaleBySize(2))
        bb:paintRect(x, y, w, t, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x, y + h - t, w, t, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x, y, t, h, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + w - t, y, t, h, Blitbuffer.COLOR_BLACK)
    end
    if opts.invert and bb.invertRect then
        bb:invertRect(x, y, w, h)
    end
end

-- Collapsed-only grip ticks so the chip reads as a pull-handle, not a tool.
function Pencil:paintRailPillGrips(bb, btn, orientation)
    local tick = math.max(2, Screen:scaleBySize(2))
    local inset = math.max(5, Screen:scaleBySize(6))
    if orientation == "vertical" then
        local tw = math.max(8, math.floor(btn.w * 0.45))
        local tx = btn.x + math.floor((btn.w - tw) / 2)
        bb:paintRect(tx, btn.y + inset, tw, tick, Blitbuffer.COLOR_BLACK)
        bb:paintRect(tx, btn.y + btn.h - inset - tick, tw, tick, Blitbuffer.COLOR_BLACK)
    else
        local th = math.max(8, math.floor(btn.h * 0.4))
        local ty = btn.y + math.floor((btn.h - th) / 2)
        bb:paintRect(btn.x + inset, ty, tick, th, Blitbuffer.COLOR_BLACK)
        bb:paintRect(btn.x + btn.w - inset - tick, ty, tick, th, Blitbuffer.COLOR_BLACK)
    end
end

-- Always-on tool rail (painted in paintTo when Pencil is enabled).
-- ^ collapses/expands; Pen / Nib / HL / Era / undo / light / menu / < or > flip when open.
-- Nib is Scribe-only (stamp-the-nib fountain).
function Pencil:getToolRailLayout()
    -- ~20% smaller again vs prior 42/5/5 cells
    local button = Screen:scaleBySize(34)
    local spacing = Screen:scaleBySize(4)
    local padding = Screen:scaleBySize(4)
    local margin = Screen:scaleBySize(19) -- ~0.5 cm from edge
    local border = 1 -- hairline tray
    local collapsed = self.tool_rail_collapsed == true
    local on_right = self.scribe_tool_rail_side == "right"
    local items = {
        { id = "collapse", label = collapsed and "v" or "^" },
    }
    if not collapsed then
        table.insert(items, { id = TOOL_PEN, label = _("Pen") })
        if self:isScribeMode() then
            -- BLACK NIB (U+2712). Color emoji (🖋️) is missing on Scribe fonts.
            table.insert(items, { id = TOOL_FOUNTAIN_NIB, label = "✒" })
        end
        table.insert(items, { id = TOOL_HIGHLIGHTER, label = _("HL") })
        table.insert(items, { id = TOOL_ERASER, label = _("Era") })
        -- ↺ anticlockwise open circle arrow
        table.insert(items, { id = "undo", label = "\xe2\x86\xba" })
        -- ☼ WHITE SUN WITH RAYS (light). Color emoji (💡) is missing on Scribe fonts.
        table.insert(items, { id = "full_refresh", label = "\xe2\x98\xbc" })
        -- ☰ TRIGRAM FOR HEAVEN (menu). Opens clear / status.
        table.insert(items, { id = "annot_menu", label = "\xe2\x98\xb0" })
        -- Point toward the other side (where flip will move the rail).
        table.insert(items, { id = "flip", label = on_right and "<" or ">" })
    end

    local btn_w, btn_h = button, button
    if collapsed then
        -- Tall narrow tab: reads as a side pull-handle, not a tool cell.
        btn_w = Screen:scaleBySize(27)
        btn_h = Screen:scaleBySize(45)
        padding = Screen:scaleBySize(3)
    end

    local n = #items
    local w = btn_w + 2 * padding + 2 * border
    local h = n * btn_h + (n - 1) * spacing + 2 * padding + 2 * border
    local x
    if on_right then
        x = Screen:getWidth() - w - margin
    else
        x = margin
    end
    -- Upper third of the screen (not vertically centered)
    local y = math.floor(Screen:getHeight() * 0.18)
    if y + h > Screen:getHeight() - margin then
        y = math.max(margin, Screen:getHeight() - h - margin)
    end
    local buttons = {}
    for i, item in ipairs(items) do
        local by = y + border + padding + (i - 1) * (btn_h + spacing)
        buttons[i] = {
            id = item.id,
            label = item.label,
            x = x + border + padding,
            y = by,
            w = btn_w,
            h = btn_h,
            pill = collapsed,
        }
    end
    return {
        x = x, y = y, w = w, h = h,
        border = border,
        collapsed = collapsed,
        buttons = buttons,
    }
end

function Pencil:paintToolRail(bb)
    if not self:isEnabled() then return end
    local layout = self:getToolRailLayout()
    self:paintRailTray(bb, layout.x, layout.y, layout.w, layout.h)
    for _, btn in ipairs(layout.buttons) do
        local selected = (btn.id == self.current_tool)
        local pressed = (btn.id == self._tool_rail_pressed_id)
        local accent_w = selected and math.max(3, Screen:scaleBySize(4)) or 0
        -- Chrome without accent: accent is painted after invert so it stays grey
        -- on the black selected fill (pre-invert black accent becomes white).
        self:paintRailCellChrome(bb, btn, {})
        if btn.pill then
            self:paintRailPillGrips(bb, btn, "vertical")
        end
        local face_name = (btn.id == TOOL_FOUNTAIN_NIB or btn.id == "undo"
                or btn.id == "full_refresh" or btn.id == "annot_menu")
            and "smallinfofont" or "xx_smallinfofont"
        local label = TextWidget:new{
            text = btn.label,
            face = Font:getFace(face_name),
            bold = selected or btn.pill,
        }
        -- Center in the area beside the accent so glyphs keep full weight.
        local lx = btn.x + accent_w + math.floor((btn.w - accent_w - label:getSize().w) / 2)
        local ly = btn.y + math.floor((btn.h - label:getSize().h) / 2)
        label:paintTo(bb, lx, ly)
        label:free()
        -- Invert selected; press toggles so selected cells still flash.
        -- Light (full refresh) is always white-on-black so it reads as a flash action.
        local invert = selected or (btn.id == "full_refresh")
        if pressed then invert = not invert end
        if invert and bb.invertRect then
            bb:invertRect(btn.x, btn.y, btn.w, btn.h)
        end
        -- Grey accent on inverted (black) selected cell — visible, not white-on-white.
        if selected and not pressed and accent_w > 0 then
            local grey = Blitbuffer.COLOR_GRAY or Blitbuffer.Color8(0x99)
            local b = 1
            bb:paintRect(btn.x + b, btn.y + b, accent_w, btn.h - 2 * b, grey)
        end
    end
    -- Remember where we last drew so flip/collapse can refresh the old spot
    self._tool_rail_last_layout = {
        x = layout.x, y = layout.y, w = layout.w, h = layout.h,
    }
end

-- Brief invert on a rail button so taps (esp. undo) read as pressed on e-ink.
function Pencil:flashToolRailButton(id)
    if not id then return end
    self._tool_rail_pressed_id = id
    if self._tool_rail_press_clear then
        UIManager:unschedule(self._tool_rail_press_clear)
        self._tool_rail_press_clear = nil
    end

    local function refresh_button()
        if not self:isEnabled() then return end
        local layout = self:getToolRailLayout()
        self:paintToolRail(Screen.bb)
        for _, btn in ipairs(layout.buttons) do
            if btn.id == id then
                Screen:refreshUI(btn.x, btn.y, btn.w, btn.h)
                break
            end
        end
    end

    refresh_button()
    self._tool_rail_press_clear = UIManager:scheduleIn(0.2, function()
        self._tool_rail_press_clear = nil
        self._tool_rail_pressed_id = nil
        refresh_button()
    end)
end

-- Immediate rail refresh — setDirty alone often waits until the next page turn
-- when called from the stylus callback.
-- Flip/collapse move or shrink the rail: the framebuffer is repainted fully,
-- but e-ink must also refresh the *previous* rect or the old menu ghosts.
function Pencil:repaintToolRailNow()
    if not self:isEnabled() or not self.view then
        UIManager:setDirty(self.view, "ui")
        return
    end
    local prev_v = self._tool_rail_last_layout
    local prev_h = self._hrail_last_layout
    local layout_v = self:getToolRailLayout()
    local layout_h = self:getHRailLayout()
    local pad = Screen:scaleBySize(12)

    local function refresh_rect(l)
        if not l then return end
        local rx = math.max(0, l.x - pad)
        local ry = math.max(0, l.y - pad)
        local rw = l.w + 2 * pad
        local rh = l.h + 2 * pad
        if rx + rw > Screen:getWidth() then
            rw = Screen:getWidth() - rx
        end
        if ry + rh > Screen:getHeight() then
            rh = Screen:getHeight() - ry
        end
        Screen:refreshUI(rx, ry, rw, rh)
    end

    -- Restore page under old + new rails in the buffer
    self.view:paintTo(Screen.bb, 0, 0)
    self:paintTo(Screen.bb, 0, 0)

    -- Push regions to the panel (old first so ghosts clear)
    if prev_v and layout_v and (prev_v.x ~= layout_v.x or prev_v.y ~= layout_v.y
            or prev_v.w ~= layout_v.w or prev_v.h ~= layout_v.h) then
        refresh_rect(prev_v)
    end
    if prev_h and layout_h and (prev_h.x ~= layout_h.x or prev_h.y ~= layout_h.y
            or prev_h.w ~= layout_h.w or prev_h.h ~= layout_h.h) then
        refresh_rect(prev_h)
    elseif prev_h and not layout_h then
        refresh_rect(prev_h)
    end
    refresh_rect(layout_v)
    refresh_rect(layout_h)
end

-- After ^ / <> the rail moves or shrinks; the follow-up tap/swipe lands off-rail
-- and KOReader treats it as a page turn. Eat navigation briefly after any rail hit.
function Pencil:noteToolRailGestureGuard()
    self._tool_rail_block_nav_at = time.now()
end

function Pencil:shouldBlockNavAfterToolRail()
    if not self._tool_rail_block_nav_at then return false end
    return time.to_ms(time.now() - self._tool_rail_block_nav_at) < 700
end

function Pencil:pointInToolRail(x, y)
    if not self:isEnabled() or not x or not y then return false end
    local layout = self:getToolRailLayout()
    return x >= layout.x and x < layout.x + layout.w
        and y >= layout.y and y < layout.y + layout.h
end

-- Returns true if (x,y) hit the rail (and the action was applied).
-- Any tap inside the rail frame maps to the nearest button by Y —
-- easier than needing an exact button pixel.
function Pencil:handleToolRailTap(x, y)
    if not self:isEnabled() then return false end
    if not x or not y then return false end
    local layout = self:getToolRailLayout()
    if x < layout.x or x >= layout.x + layout.w
            or y < layout.y or y >= layout.y + layout.h then
        return false
    end
    self:noteToolRailGestureGuard()

    local best, best_dist = nil, math.huge
    for _, btn in ipairs(layout.buttons) do
        local cy = btn.y + btn.h / 2
        local dist = math.abs(y - cy)
        if dist < best_dist then
            best_dist = dist
            best = btn
        end
    end
    if not best then return true end

    -- Debounce touch+tap double delivery (and accidental re-hits)
    local now = time.now()
    if self._tool_rail_last_id == best.id and self._tool_rail_last_time
            and time.to_ms(now - self._tool_rail_last_time) < 400 then
        return true
    end
    self._tool_rail_last_id = best.id
    self._tool_rail_last_time = now

    if best.id == "collapse" then
        self.tool_rail_collapsed = not self.tool_rail_collapsed
        self:saveSettings()
        self:repaintToolRailNow()
    elseif best.id == "flip" then
        self.scribe_tool_rail_side =
            (self.scribe_tool_rail_side == "right") and "left" or "right"
        self:saveSettings()
        self:repaintToolRailNow()
    elseif best.id == "undo" then
        self:flashToolRailButton("undo")
        self:undoLastStroke()
    elseif best.id == "full_refresh" then
        self:fullPageFlashRefresh()
    elseif best.id == "annot_menu" then
        self:flashToolRailButton("annot_menu")
        -- Don't open on down: ButtonDialog treats that same tap as "outside"
        -- and closes at once. Don't wait for lift either: a brief Scribe tap
        -- often has no lift packet until a later hover, so the menu did nothing.
        self._annot_menu_pending = true
        self:scheduleAnnotMenuOpen()
    else
        self:setTool(best.id, { silent = true })
    end
    return true
end

function Pencil:scheduleAnnotMenuOpen()
    if self._annot_menu_open then
        UIManager:unschedule(self._annot_menu_open)
        self._annot_menu_open = nil
    end
    self._annot_menu_open = UIManager:scheduleIn(0.16, function()
        self._annot_menu_open = nil
        self:flushAnnotMenuPending()
    end)
end

function Pencil:flushAnnotMenuPending()
    if self._annot_menu_open then
        UIManager:unschedule(self._annot_menu_open)
        self._annot_menu_open = nil
    end
    if not self._annot_menu_pending then return false end
    self._annot_menu_pending = false
    -- A missed lift left this latched and ate the next stylus samples.
    self.tool_rail_tap_armed = false
    self:showAnnotationActionsDialog()
    return true
end

-- Idle rail picker: same three Edit items as the KOReader menu.
function Pencil:showAnnotationActionsDialog()
    local dialog
    -- Default ButtonDialog is 90% of the short screen edge and hits the
    -- vertical rail. Cap width and shrink to the button text; stays centered.
    local max_w = math.min(Screen:scaleBySize(280), math.floor(Screen:getWidth() * 0.42))
    dialog = ButtonDialog:new{
        title = _("PenScribe"),
        width = max_w,
        shrink_unneeded_width = true,
        buttons = (function()
            local buttons = {
                {
                    {
                        text = _("New Note"),
                        callback = function()
                            UIManager:close(dialog)
                            self:createNewNote()
                        end,
                    },
                },
                {
                    {
                        text = _("New Checklist"),
                        callback = function()
                            UIManager:close(dialog)
                            self:createNewChecklist()
                        end,
                    },
                },
            }
            if self:isNotesMarkdownDocument() then
                table.insert(buttons, {
                    {
                        text = _("New page"),
                        callback = function()
                            UIManager:close(dialog)
                            self:appendNewPage()
                        end,
                    },
                })
            end
            table.insert(buttons, {
                {
                    text = _("Clear this page"),
                    enabled = self:hasStrokesOnCurrentPage(),
                    callback = function()
                        UIManager:close(dialog)
                        self:clearPageStrokes()
                    end,
                },
            })
            table.insert(buttons, {
                {
                    text = _("Clear all annotations"),
                    enabled = self.strokes and #self.strokes > 0,
                    callback = function()
                        UIManager:close(dialog)
                        self:clearAllStrokes()
                    end,
                },
            })
            table.insert(buttons, {
                {
                    text = _("Show annotation status"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showAnnotationStatus()
                    end,
                },
            })
            return buttons
        end)(),
    }
    UIManager:show(dialog)
end

function Pencil:getNotesDir()
    if type(self.notes_dir) == "string" and self.notes_dir ~= "" then
        return self.notes_dir:gsub("/$", "")
    end
    local home = G_reader_settings:readSetting("home_dir")
    if type(home) ~= "string" or home == "" then
        home = DataStorage:getDataDir()
    end
    return (home:gsub("/$", "")) .. "/penscribe_notes"
end

function Pencil:ensureNotesDir()
    local dir = self:getNotesDir()
    local util = require("util")
    if util.makePath then
        util.makePath(dir)
    else
        lfs.mkdir(dir)
    end
    local mode = lfs.attributes(dir, "mode")
    return mode == "directory" and dir or nil
end

function Pencil:chooseNotesDir(touchmenu_instance)
    local start = self:getNotesDir()
    if lfs.attributes(start, "mode") ~= "directory" then
        start = start:match("^(.*)/") or start
    end
    local ok_pc, PathChooser = pcall(require, "ui/widget/pathchooser")
    if ok_pc and PathChooser then
        UIManager:show(PathChooser:new{
            title = _("Notes folder"),
            path = start,
            select_directory = true,
            select_file = false,
            onConfirm = function(dir)
                if type(dir) == "string" and dir ~= "" then
                    self.notes_dir = dir:gsub("/$", "")
                    self:saveSettings()
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end
            end,
        })
        return
    end
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Notes folder"),
        input = self:getNotesDir(),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local dir = dialog:getInputText()
                    UIManager:close(dialog)
                    if type(dir) == "string" and dir ~= "" then
                        self.notes_dir = dir:gsub("/$", "")
                        self:saveSettings()
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        dialog:onShowKeyboard()
    end
end

-- Write a Markdown file in the notes folder and open it as a document.
function Pencil:createMarkdownInNotesDir(prefix, body, fail_kind)
    local dir = self:ensureNotesDir()
    if not dir then
        UIManager:show(InfoMessage:new{
            text = T(_("Could not create notes folder:\n%1"), self:getNotesDir()),
            timeout = 3,
        })
        return
    end
    local base = os.date(prefix .. "-%Y%m%d-%H%M%S")
    local path = dir .. "/" .. base .. ".md"
    local n = 2
    while lfs.attributes(path, "mode") do
        path = dir .. "/" .. base .. "-" .. n .. ".md"
        n = n + 1
    end
    local f, err = io.open(path, "w")
    if not f then
        local msg = fail_kind == "checklist"
            and T(_("Could not create checklist:\n%1"), tostring(err))
            or T(_("Could not create note:\n%1"), tostring(err))
        UIManager:show(InfoMessage:new{
            text = msg,
            timeout = 3,
        })
        return
    end
    f:write(body)
    f:close()

    self:flushDeferredWork()
    if self.ui and self.ui.switchDocument then
        self.ui:switchDocument(path)
        return
    end
    local ReaderUI = require("apps/reader/readerui")
    if self.ui and self.ui.onClose then
        self.ui:onClose()
    end
    ReaderUI:showReader(path)
end

-- Empty Markdown note: KOReader opens it as a document you can scribble on.
function Pencil:createNewNote()
    local body
    -- Heading is optional (Edit menu). A newline keeps CRE happy on an empty file.
    if self.new_note_datestamp ~= false then
        -- #### is about half of a # heading in CRE. Keep it a heading so it
        -- stays a title, just smaller.
        body = "#### " .. os.date("%Y-%m-%d %H:%M") .. "\n\n"
    else
        body = "\n"
    end
    self:createMarkdownInNotesDir("note", body, "note")
end

-- Empty ballot box (U+2610). Markdown joins adjacent text into one
-- paragraph, so NBSP "blank" lines put every box on a single line.
-- Each box is its own HTML block; <br> is the gap CRE will not collapse.
local NEW_CHECKLIST_ITEMS = 20
local CHECKLIST_BOX = "\xe2\x98\x90" -- ☐

function Pencil:createNewChecklist()
    local lines = {}
    if self.new_note_datestamp ~= false then
        lines[#lines + 1] = "#### " .. os.date("%Y-%m-%d %H:%M")
        lines[#lines + 1] = ""
    end
    for _ = 1, NEW_CHECKLIST_ITEMS do
        lines[#lines + 1] = "<p>" .. CHECKLIST_BOX .. "</p>"
        lines[#lines + 1] = "<p><br></p>"
    end
    lines[#lines + 1] = ""
    self:createMarkdownInNotesDir("checklist", table.concat(lines, "\n"), "checklist")
end

function Pencil:getCurrentDocumentPath()
    if self.ui and self.ui.document and type(self.ui.document.file) == "string" then
        return self.ui.document.file
    end
    return nil
end

-- New page is only for PenScribe notes/checklists, not random Markdown books.
function Pencil:isNotesMarkdownDocument()
    local path = self:getCurrentDocumentPath()
    if not path then return false end
    if not path:lower():match("%.md$") then return false end
    local dir = self:getNotesDir()
    if type(dir) == "string" and dir ~= "" then
        dir = dir:gsub("/$", "")
        if path == dir or path:sub(1, #dir + 1) == dir .. "/" then
            return true
        end
    end
    local base = path:match("([^/]+)$") or ""
    return base:match("^note%-") ~= nil or base:match("^checklist%-") ~= nil
end

-- CRE page-break. section + inline style so a new page exists even if one
-- of those is ignored. &nbsp; keeps the page from collapsing as empty.
local NOTE_PAGE_BREAK = "\n\n<section class=\"penscribe-page\" style=\"page-break-before: always;\">&nbsp;</section>\n"

-- Set before reload; the new plugin instance reads it in onReaderReady.
local pending_goto_last_page = false

function Pencil:jumpToLastPage()
    local ui = self.ui
    if not ui or not ui.document then return end
    local n = ui.document.getPageCount and ui.document:getPageCount() or nil
    if ui.rolling then
        if n and n > 0 and ui.rolling.onGotoPage then
            ui.rolling:onGotoPage(n)
        elseif ui.rolling.onGotoPercent then
            ui.rolling:onGotoPercent(100)
        end
    elseif ui.paging and n and n > 0 and ui.paging.onGotoPage then
        ui.paging:onGotoPage(n)
    end
end

-- Append a blank drawing page to the open note/checklist and go there.
function Pencil:appendNewPage()
    if not self:isNotesMarkdownDocument() then
        UIManager:show(InfoMessage:new{
            text = _("New page is only available in a note or checklist."),
            timeout = 2,
        })
        return
    end
    local path = self:getCurrentDocumentPath()
    local f, err = io.open(path, "a")
    if not f then
        UIManager:show(InfoMessage:new{
            text = T(_("Could not add a page:\n%1"), tostring(err)),
            timeout = 3,
        })
        return
    end
    f:write(NOTE_PAGE_BREAK)
    f:close()

    pending_goto_last_page = true
    self:flushDeferredWork()

    -- after_open is called as a method on the new ReaderUI.
    local function after_open(reader)
        if not reader or not reader.document then return end
        pending_goto_last_page = false
        local n = reader.document.getPageCount and reader.document:getPageCount() or nil
        if reader.rolling and n and n > 0 and reader.rolling.onGotoPage then
            reader.rolling:onGotoPage(n)
        elseif reader.paging and n and n > 0 and reader.paging.onGotoPage then
            reader.paging:onGotoPage(n)
        end
    end

    if self.ui and self.ui.reloadDocument then
        self.ui:reloadDocument(nil, true, after_open)
        return
    end
    if self.ui and self.ui.switchDocument then
        self.ui:switchDocument(path, true, after_open)
    end
end

-- Scribe horizontal thickness bar (top/bottom). Row 1 = 2×12 color swatches
-- (dark over vivid of the same hue) when Colorsoft is on; row 2 =
-- ^ | steps | <> . Collapsed = pill handle at <>.
function Pencil:getHRailLayout()
    if not self:isScribeMode() or not self:isEnabled() then
        return nil
    end
    local button = Screen:scaleBySize(42)
    local spacing = Screen:scaleBySize(5)
    local padding = Screen:scaleBySize(5)
    local margin = Screen:scaleBySize(19)
    local border = 1 -- hairline tray
    local collapsed = self.scribe_hrail_collapsed == true
    local at_top = self.scribe_hrail_edge == "top"
    local show_colors = self:isColorsoftMode()

    -- Always size as if expanded so collapse anchors to the <> cell.
    local n_cols_full = 2 + #THICKNESS_STEPS  -- ^ + steps + <>
    local n_rows_full = show_colors and 2 or 1
    local w_full = n_cols_full * button + (n_cols_full - 1) * spacing
        + 2 * padding + 2 * border
    local h_full = n_rows_full * button + (n_rows_full - 1) * spacing
        + 2 * padding + 2 * border
    local x_full = math.floor((Screen:getWidth() - w_full) / 2)
    if x_full < margin then x_full = margin end
    local y_full
    if at_top then
        y_full = margin
    else
        y_full = Screen:getHeight() - h_full - margin
    end

    local items_tools = {}
    if not collapsed then
        table.insert(items_tools, {
            id = "h_flip",
            label = at_top and "v" or "^",
            kind = "label",
        })
        for i = 1, #THICKNESS_STEPS do
            table.insert(items_tools, {
                id = "thickness_" .. i,
                step = i,
                kind = "thickness",
                bar_h = THICKNESS_STEPS[i].pen,
            })
        end
    end
    table.insert(items_tools, { id = "h_collapse", label = "<>", kind = "label" })

    local tools_row = show_colors and 2 or 1
    local pill_w = Screen:scaleBySize(64)
    local pill_h = Screen:scaleBySize(34)
    local w, h, x, y
    if collapsed then
        local pill_pad = Screen:scaleBySize(4)
        w = pill_w + 2 * pill_pad + 2 * border
        h = pill_h + 2 * pill_pad + 2 * border
        -- Anchor to expanded <> cell (tools row, last col), vertically centered.
        x = x_full + w_full - w
        local expand_btn_y = y_full + border + padding
            + (tools_row - 1) * (button + spacing)
        y = expand_btn_y + math.floor(button / 2) - math.floor(h / 2)
        if at_top then
            y = math.max(margin, y)
        else
            y = math.min(y, Screen:getHeight() - h - margin)
        end
    else
        w, h, x, y = w_full, h_full, x_full, y_full
    end

    local buttons = {}
    local function add_btn(item, col, row)
        local bx, by, bw, bh
        if collapsed then
            local pill_pad = Screen:scaleBySize(4)
            bx = x + border + pill_pad
            by = y + border + pill_pad
            bw, bh = pill_w, pill_h
        else
            bx = x + border + padding + (col - 1) * (button + spacing)
            by = y + border + padding + (row - 1) * (button + spacing)
            bw, bh = button, button
        end
        buttons[#buttons + 1] = {
            id = item.id,
            label = item.label,
            kind = item.kind,
            step = item.step,
            bar_h = item.bar_h,
            color = item.color,
            color_name = item.color_name,
            x = bx, y = by, w = bw, h = bh,
            row = row,
            pill = collapsed,
        }
    end
    if collapsed then
        add_btn(items_tools[1], 1, 1)
    else
        if show_colors then
            local colors = self.available_colors or {}
            local n = #colors
            local n_rows = 2
            local n_cols = math.max(1, math.ceil(n / n_rows))
            local inner_x = x + border + padding
            local inner_y = y + border + padding
            local inner_w = n_cols_full * button + (n_cols_full - 1) * spacing
            local inner_h = button
            local gap = math.max(2, Screen:scaleBySize(2))
            local cell_w = math.floor((inner_w - (n_cols - 1) * gap) / n_cols)
            local cell_h = math.floor((inner_h - (n_rows - 1) * gap) / n_rows)
            if cell_w < 1 then cell_w = 1 end
            if cell_h < 1 then cell_h = 1 end
            local used_w = n_cols * cell_w + (n_cols - 1) * gap
            local used_h = n_rows * cell_h + (n_rows - 1) * gap
            local ox = inner_x + math.floor((inner_w - used_w) / 2)
            local oy = inner_y + math.floor((inner_h - used_h) / 2)
            for i, c in ipairs(colors) do
                local idx = i - 1
                local col = idx % n_cols
                local row = math.floor(idx / n_cols)
                buttons[#buttons + 1] = {
                    id = "color_" .. c.name,
                    kind = "color",
                    color_name = c.name,
                    color = c.color,
                    x = ox + col * (cell_w + gap),
                    y = oy + row * (cell_h + gap),
                    w = cell_w,
                    h = cell_h,
                    row = 1,
                }
            end
        end
        for col, item in ipairs(items_tools) do
            add_btn(item, col, tools_row)
        end
    end
    return {
        x = x, y = y, w = w, h = h,
        border = border,
        buttons = buttons,
        collapsed = collapsed,
    }
end

function Pencil:paintHRail(bb)
    local layout = self:getHRailLayout()
    if not layout then return end
    self:paintRailTray(bb, layout.x, layout.y, layout.w, layout.h)
    local cur_step = self:getThicknessStepForTool(self.current_tool)
    local cur_color = self.tool_settings[TOOL_PEN].color_name or "Black"
    for _, btn in ipairs(layout.buttons) do
        local selected = (btn.kind == "thickness" and btn.step == cur_step)
            or (btn.kind == "color" and btn.color_name == cur_color)
        if btn.kind == "color" and btn.color then
            -- Tight swatch: no cell chrome so the 2×12 shade grid stays readable.
            if bb.paintRectRGB32 then
                bb:paintRectRGB32(btn.x, btn.y, btn.w, btn.h, btn.color)
            else
                bb:paintRect(btn.x, btn.y, btn.w, btn.h, btn.color)
            end
            if selected then
                local t = math.max(2, Screen:scaleBySize(2))
                bb:paintRect(btn.x, btn.y, btn.w, t, Blitbuffer.COLOR_BLACK)
                bb:paintRect(btn.x, btn.y + btn.h - t, btn.w, t, Blitbuffer.COLOR_BLACK)
                bb:paintRect(btn.x, btn.y, t, btn.h, Blitbuffer.COLOR_BLACK)
                bb:paintRect(btn.x + btn.w - t, btn.y, t, btn.h, Blitbuffer.COLOR_BLACK)
                local t2 = math.max(1, Screen:scaleBySize(1))
                local ix = btn.x + t
                local iy = btn.y + t
                local iw = btn.w - 2 * t
                local ih = btn.h - 2 * t
                if iw > 0 and ih > 0 then
                    bb:paintRect(ix, iy, iw, t2, Blitbuffer.COLOR_WHITE)
                    bb:paintRect(ix, iy + ih - t2, iw, t2, Blitbuffer.COLOR_WHITE)
                    bb:paintRect(ix, iy, t2, ih, Blitbuffer.COLOR_WHITE)
                    bb:paintRect(ix + iw - t2, iy, t2, ih, Blitbuffer.COLOR_WHITE)
                end
            end
        else
            local accent = nil
            if selected and btn.kind == "thickness" then
                accent = "bottom"
            end
            self:paintRailCellChrome(bb, btn, {
                selected = selected,
                accent = accent,
            })
            if btn.pill then
                self:paintRailPillGrips(bb, btn, "horizontal")
            end
            if btn.kind == "thickness" then
                local bar_h = math.max(2, math.min(btn.h - 10, btn.bar_h or 3))
                local bar_w = math.max(4, math.floor(btn.w * 0.45))
                local bx = btn.x + math.floor((btn.w - bar_w) / 2)
                -- Sit above the bottom accent when selected.
                local by = btn.y + math.floor((btn.h - bar_h) / 2)
                if selected then
                    by = by - math.max(1, Screen:scaleBySize(2))
                end
                bb:paintRect(bx, by, bar_w, bar_h, Blitbuffer.COLOR_BLACK)
            elseif btn.kind == "label" and btn.label then
                local label = TextWidget:new{
                    text = btn.label,
                    face = Font:getFace("xx_smallinfofont"),
                    bold = btn.pill == true,
                }
                local lx = btn.x + math.floor((btn.w - label:getSize().w) / 2)
                local ly = btn.y + math.floor((btn.h - label:getSize().h) / 2)
                label:paintTo(bb, lx, ly)
                label:free()
            end
        end
    end
    self._hrail_last_layout = {
        x = layout.x, y = layout.y, w = layout.w, h = layout.h,
    }
end

function Pencil:pointInHRail(x, y)
    if not self:isEnabled() or not x or not y then return false end
    local layout = self:getHRailLayout()
    if not layout then return false end
    return x >= layout.x and x < layout.x + layout.w
        and y >= layout.y and y < layout.y + layout.h
end

function Pencil:pointInAnyRail(x, y)
    return self:pointInToolRail(x, y) or self:pointInHRail(x, y)
end

-- Horizontal bar tap. Nearest button by distance within the frame.
function Pencil:handleHRailTap(x, y)
    if not self:isEnabled() or not self:isScribeMode() then return false end
    if not x or not y then return false end
    local layout = self:getHRailLayout()
    if not layout then return false end
    if x < layout.x or x >= layout.x + layout.w
            or y < layout.y or y >= layout.y + layout.h then
        return false
    end
    self:noteToolRailGestureGuard()

    local best, best_dist = nil, math.huge
    for _, btn in ipairs(layout.buttons) do
        local cx = btn.x + btn.w / 2
        local cy = btn.y + btn.h / 2
        local dx, dy = x - cx, y - cy
        local dist = dx * dx + dy * dy
        if dist < best_dist then
            best_dist = dist
            best = btn
        end
    end
    if not best then return true end

    local now = time.now()
    local deb_id = "h:" .. tostring(best.id)
    if self._tool_rail_last_id == deb_id and self._tool_rail_last_time
            and time.to_ms(now - self._tool_rail_last_time) < 400 then
        return true
    end
    self._tool_rail_last_id = deb_id
    self._tool_rail_last_time = now

    if best.id == "h_collapse" then
        self.scribe_hrail_collapsed = not self.scribe_hrail_collapsed
        self:saveSettings()
        self:repaintToolRailNow()
    elseif best.id == "h_flip" then
        self.scribe_hrail_edge =
            (self.scribe_hrail_edge == "top") and "bottom" or "top"
        self:saveSettings()
        self:repaintToolRailNow()
    elseif best.kind == "thickness" and best.step then
        self:applyThicknessStep(best.step)
        self:saveSettings()
        self:repaintToolRailNow()
    elseif best.kind == "color" and best.color and best.color_name then
        self:setPenColor(best.color, best.color_name)
        self:repaintToolRailNow()
    end
    return true
end

-- Try horizontal then vertical rail (stylus / finger).
function Pencil:handleAnyRailTap(x, y)
    if self:handleHRailTap(x, y) then return true end
    if self:handleToolRailTap(x, y) then return true end
    return false
end

-- Set pen color
function Pencil:setPenColor(color, color_name)
    self.tool_settings[TOOL_PEN].color = color
    self.tool_settings[TOOL_PEN].color_name = color_name
    logger.info("PenScribe: setPenColor - color_name =", color_name)
    self:saveSettings()
end

-- Handle initial touch - fires IMMEDIATELY on first contact
-- This is critical for capturing the start of strokes without delay
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and is a backup if raw input not working
function Pencil:onDrawTouch(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    if self:shouldBlockNavAfterToolRail() then return true end

    -- Tool rail first (finger or pen) — before palm rejection / stroke logic
    if ges and ges.pos and self:handleAnyRailTap(ges.pos.x, ges.pos.y) then
        return true
    end

    -- Scribe: ignore capacitive palm/finger while stylus is active; never
    -- start strokes from the gesture path (stylus callback owns drawing).
    if self:isScribeMode() then
        if self:shouldRejectPalmTouches() then
            return true
        end
        if self.stylus_callback_registered then
            return false
        end
    end

    -- Check if this is a finger touch (not pen) - let gesture system handle it
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    -- Check if raw input hook detected pen - if so, block gesture but don't duplicate
    -- This is the primary pen detection method (lowest latency)
    if self.pen_down then
        -- Raw input is handling drawing - just block the gesture
        self:cancelPendingRefresh()
        return true
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then return false end

    -- Cancel any pending refresh - user is still writing
    self:cancelPendingRefresh()

    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- For eraser, we handle in pan (need movement to erase)
    if effective_tool == TOOL_ERASER then
        return true  -- Block but don't start stroke
    end

    -- Fallback: handle via gesture system if raw input not working
    local page = self:getCurrentPage()

    -- If side button is held for highlighting
    if self.side_button_down then
        self.side_button_used_for_highlight = true
    end

    -- Start new stroke immediately with first point
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    self.current_stroke = {
        page = page,
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }
    self._fountain_heading = nil

    -- Draw first point to framebuffer - NO REFRESH during drawing
    -- E-ink displays show "ghost" pixels when framebuffer changes, providing visual feedback
    -- Refresh only happens after user stops writing (delayed refresh)
    local width = tool_settings.width
    if effective_tool == TOOL_HIGHLIGHTER then
        self:drawHighlighterDab(Screen.bb, ges.pos.x, ges.pos.y, width)
    else
        self._fountain_heading = nil
        local color = tool_settings.color
        self:paintTipDab(Screen.bb, ges.pos.x, ges.pos.y, self.current_stroke, color)
    end

    return true
end

-- Check if this is a stylus/pen event (not finger)
-- Returns: is_pen (boolean), is_eraser_end (boolean), is_highlighter (boolean)
function Pencil:isPenInput(ges)
    if Device:isEmulator() then
        return true, false, false
    end

    local Input = Device.input
    if not Input or not Input.pen_slot then
        return false, false, false
    end

    -- Scribe: a docked pen can leave pen_slot.id >= 0. Treating that as a
    -- stylus gesture ate the top-menu swipe until sleep/wake reset input.
    if self:isScribeMode() and not self:hasRecentStylusContact() then
        return false, false, false
    end

    local TOOL_TYPE_PEN = 1
    local TOOL_TYPE_ERASER = 2
    local TOOL_TYPE_HIGHLIGHTER = 3

    local pen_slot_data = Input:getMtSlot(Input.pen_slot)
    if pen_slot_data and pen_slot_data.id and pen_slot_data.id ~= -1 then
        if pen_slot_data.tool == TOOL_TYPE_PEN then
            return true, false, false
        elseif pen_slot_data.tool == TOOL_TYPE_ERASER then
            -- Kindle barrel promotes PEN→ERASER; treat as highlighter side button.
            if self:isKindleBarrelSideButton(Input) then
                return true, false, true
            end
            return true, true, false
        elseif pen_slot_data.tool == TOOL_TYPE_HIGHLIGHTER then
            return true, false, true
        end
    end

    return false, false, false
end

-- Get the effective tool (considers physical eraser end and side button)
function Pencil:getEffectiveTool(is_eraser_end, is_highlighter)
    -- Check both the tool type detection AND the BTN_TOOL_RUBBER state
    if self.eraser_tool_active or ((self.swap_eraser_and_highlighter and is_highlighter) or (not self.swap_eraser_and_highlighter and is_eraser_end)) then
        return TOOL_ERASER
    end

    -- Side button held = highlighter mode (for hold+drag highlighting)
    if self.side_button_down or ((self.swap_eraser_and_highlighter and is_eraser_end) or (not self.swap_eraser_and_highlighter and is_highlighter)) then
        return TOOL_HIGHLIGHTER
    end

    return self.current_tool
end

-- Called on tap - create a dot or erase at point
function Pencil:onDrawTap(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Collapse/flip move the rail; the follow-up tap would otherwise page-turn.
    if self:shouldBlockNavAfterToolRail() then return true end

    -- Tool rail before palm rejection so finger/pen can always pick a tip tool
    if ges and ges.pos and self:handleAnyRailTap(ges.pos.x, ges.pos.y) then
        self:flushAnnotMenuPending()
        return true
    end
    if self:flushAnnotMenuPending() then
        return true
    end

    -- Scribe: swallow finger taps while stylus is in range (prevents page
    -- turns / stray dots from palm). Badge hits still work when pen is away.
    if self:shouldRejectPalmTouches() then
        return true
    end

    -- If raw input detected pen recently, block tap to prevent navigation
    -- Note: pen_down will be false by tap time, but we may have just drawn
    -- We should block taps if there's a current stroke or recent drawing
    if self.current_stroke then
        return true  -- Block tap while stroke in progress
    end

    -- Rotation badge hit-test: consume taps (pen or finger) over the camera
    -- badge of a stale-rotation annotation and open its saved image.
    if ges and ges.pos then
        local hit = self:findGroupBadgeAtPoint(ges.pos.x, ges.pos.y)
        if hit then
            logger.info("PenScribe: badge tap hit group", hit.id,
                "at (", ges.pos.x, ",", ges.pos.y, ")")
            self:showGroupImagePreview(hit)
            return true
        end
    end

    -- Scribe + stylus callback: leave remaining finger taps to the reader
    if self:isScribeMode() and self.stylus_callback_registered then
        return false
    end

    -- Check if finger tap - let gesture system handle it
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)
    logger.dbg("PenScribe: onDrawTap - effective_tool =", effective_tool)

    -- Log to debug file for analysis
    self:writeDebugLog(string.format("=== TAP at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    if effective_tool == TOOL_ERASER then
        logger.info("PenScribe: eraser tap at", ges.pos.x, ges.pos.y, "page =", page)
        self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        return true
    end

    -- Pen or Highlighter: create a dot
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    local stroke = {
        page = page,
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }

    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, page)
    self:scheduleDeferredWork()

    -- Add to undo stack
    table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })

    -- Draw directly to screen buffer
    self:renderStroke(Screen.bb, stroke)

    -- Direct framebuffer refresh for instant feedback
    local w = stroke.width
    if self:isFountainTool(stroke.tool) then
        local _, w_max = PencilGeometry.fountainWidthRange(w)
        w = w_max
    end
    Screen:refreshFast(ges.pos.x - w, ges.pos.y - w, w * 2, w * 2)
    self._ink_used_fast_refresh = true
    self._panel_needs_ui_kick = true

    return true
end

-- Called during pan - continues stroke started by onDrawTouch
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and handles eraser mode
function Pencil:onDrawPan(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    if self:shouldBlockNavAfterToolRail() then return true end
    if ges and ges.pos and self:pointInAnyRail(ges.pos.x, ges.pos.y) then return true end

    -- Scribe: eat palm/finger pans while stylus is active; never append
    -- gesture coordinates into the stroke (that's what caused jumps).
    if self:isScribeMode() then
        if self:shouldRejectPalmTouches() or self.pen_down then
            return true
        end
        if self.stylus_callback_registered then
            return false
        end
    end

    -- Check if raw input hook detected pen - if so, block gesture
    -- Raw input handles all drawing; this just needs to block swipe/pan gestures
    if self.pen_down then
        return true  -- Block pan gesture, raw input is drawing
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then return false end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- If side button is held and we're drawing, mark it as used for highlighting
    if self.side_button_down and effective_tool == TOOL_HIGHLIGHTER then
        self.side_button_used_for_highlight = true
    end

    -- Eraser mode: erase along path (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        self:eraseDabLive(ges.pos.x, ges.pos.y)
        return true
    end

    -- Fallback: handle via gesture system if raw input not working
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]

    -- Stroke should already exist from onDrawTouch, but handle fallback cases
    if not self.current_stroke or self.current_stroke.page ~= page or self.current_stroke.tool ~= effective_tool then
        -- Fallback: create stroke if touch event was missed or context changed
        logger.dbg("PenScribe: onDrawPan creating fallback stroke")
        self.current_stroke = {
            page = page,
            tool = effective_tool,
            points = {},
            width = tool_settings.width,
            color = tool_settings.color,
            color_name = tool_settings.color_name,
            alpha = tool_settings.alpha,
            datetime = os.time(),
        }
        self._fountain_heading = nil
        -- Use start_pos if available for the first point
        if ges.start_pos then
            table.insert(self.current_stroke.points, { x = ges.start_pos.x, y = ges.start_pos.y })
        end
    end

    -- Add current point to stroke
    local point = { x = ges.pos.x, y = ges.pos.y }
    table.insert(self.current_stroke.points, point)

    -- Draw the new segment to framebuffer - NO REFRESH during drawing
    -- E-ink shows ghost pixels, refresh happens on pan_release
    local n = #self.current_stroke.points
    local width = self.current_stroke.width
    local color = self.current_stroke.color

    if n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]

        if effective_tool == TOOL_HIGHLIGHTER then
            self:drawHighlighterSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        else
            self:paintTipSegment(Screen.bb, p1, p2, self.current_stroke, color, self)
        end
    elseif n == 1 then
        local p = self.current_stroke.points[1]
        if effective_tool == TOOL_HIGHLIGHTER then
            self:drawHighlighterDab(Screen.bb, p.x, p.y, width)
        else
            self:paintTipDab(Screen.bb, p.x, p.y, self.current_stroke, color)
        end
    end

    return true
end

-- Called when pan ends - finalize stroke
-- NOTE: For pen/highlighter, raw input hook may have already finalized the stroke
function Pencil:onDrawPanRelease(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    if self:flushAnnotMenuPending() then return true end

    if self:shouldBlockNavAfterToolRail() then return true end

    if self:shouldRejectPalmTouches() then
        return true
    end
    if self:isScribeMode() and self.stylus_callback_registered then
        if self.pen_down then return true end
        return false
    end

    -- Let finger releases be handled by gesture system
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- Log pan end to debug file
    self:writeDebugLog(string.format("=== PAN END at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    -- Handle eraser pan release (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        self:commitEraseSession()
        return true
    end

    -- For pen/highlighter: raw input hook already finalized the stroke
    -- Just consume the event and ensure delayed refresh is scheduled
    if not self.current_stroke then
        -- Raw input already handled it, just schedule refresh if not already pending
        self:scheduleDelayedRefresh()
        return true
    end

    -- Fallback: finalize stroke via gesture system
    if #self.current_stroke.points >= 1 then
        -- Finalize the stroke
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self:scheduleDeferredWork()

        -- Add to undo stack
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:assignStrokeToGroup(#self.strokes)

        logger.dbg("PenScribe: stroke completed with", #self.current_stroke.points, "points")
    end

    self.current_stroke = nil

    -- Schedule delayed refresh - will fire after user stops writing
    -- If user starts another stroke, the refresh will be canceled and rescheduled
    self:scheduleDelayedRefresh()

    return true
end

-- Get current page number (stable reference for both paged and rolling modes)
function Pencil:getCurrentPage()
    if self.ui.paging then
        return self.view.state.page
    else
        -- For rolling/EPUB documents, convert XPointer to stable page number
        local xp = self.ui.document:getXPointer()
        if xp and self.ui.document.getPageFromXPointer then
            return self.ui.document:getPageFromXPointer(xp)
        end
        -- Fallback to XPointer if conversion not available
        return xp
    end
end

-- Index a stroke by page for quick lookup
function Pencil:indexStroke(stroke_idx, page)
    if not self.page_strokes[page] then
        self.page_strokes[page] = {}
    end
    table.insert(self.page_strokes[page], stroke_idx)
end

-- Get an XPointer for a screen-space position on the current rolling-mode
-- page. Used to remember WHERE an annotation lives (so it can be re-resolved
-- to a post-rotation page) rather than just the top of the page it was
-- drawn on. Returns nil for paging docs or when the API is unavailable.
function Pencil:getXPointerAtBboxCenter(bbox)
    if not bbox then return nil end
    if not self.ui.rolling then return nil end
    if not self.ui.document or not self.ui.document.getTextFromPositions then
        return nil
    end
    local cx = math.floor((bbox.x0 + bbox.x1) / 2)
    local cy = math.floor((bbox.y0 + bbox.y1) / 2)
    local ok, range = pcall(self.ui.document.getTextFromPositions,
        self.ui.document, { x = cx, y = cy }, { x = cx, y = cy }, true)
    if ok and range and range.pos0 then
        return range.pos0
    end
    -- Fallback: nearest-line xpointer via the current scroll top.
    if self.ui.document.getXPointer then
        local ok2, xp = pcall(self.ui.document.getXPointer, self.ui.document)
        if ok2 and xp then return xp end
    end
    return nil
end

-- Resolve a group's page number in the current layout. For paging docs (PDF)
-- the saved group.page is stable. For rolling docs (EPUB) page numbers shift
-- with rotation / font / spacing changes, so re-derive from the saved
-- XPointer if we have one. Falls back to the original page number when no
-- XPointer was stored (older groups created before this code shipped).
function Pencil:getGroupCurrentPage(group)
    if not group then return nil end
    if self.ui.rolling and group.xpointer
            and self.ui.document and self.ui.document.getPageFromXPointer then
        local ok, pn = pcall(self.ui.document.getPageFromXPointer,
            self.ui.document, group.xpointer)
        if ok and pn then return pn end
    end
    return group.page
end

-- Lazily store / upgrade an XPointer for rolling-doc groups on the current
-- page. Two paths:
--   1. Legacy group with no xpointer: drop in the page-top xpointer so at
--      least same-rotation matching keeps working.
--   2. Group whose xpointer was stored at page-top (old buggy code) or for
--      any reason isn't marked precise: when we're on the same page AND in
--      the rotation the annotation was captured at, the bbox coords are
--      valid on the current screen, so we can resolve a precise per-bbox
--      xpointer. Mark xpointer_v2 to avoid repeated work.
function Pencil:backfillGroupXPointers()
    if not self.ui.rolling then return end
    if not self.ui.document or not self.ui.document.getXPointer
            or not self.ui.document.getPageFromXPointer then
        return
    end
    local cur_page = self:getCurrentPage()
    local cur_rot = Screen:getRotationMode()
    local cur_xp_top = nil
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.page == cur_page then
            local upgraded = false
            if not group.xpointer_v2 and group.bbox
                    and (group.image_rotation == nil
                            or group.image_rotation == cur_rot) then
                local precise = self:getXPointerAtBboxCenter(group.bbox)
                if precise then
                    group.xpointer = precise
                    group.xpointer_v2 = true
                    self.image_data_dirty = true
                    upgraded = true
                end
            end
            if not upgraded and not group.xpointer then
                cur_xp_top = cur_xp_top or self.ui.document:getXPointer()
                if cur_xp_top then
                    group.xpointer = cur_xp_top
                    self.image_data_dirty = true
                end
            end
        end
    end
end

-- Assign a newly-added stroke to an annotation group (or create a new one).
-- Called after a stroke is finalized and inserted into self.strokes.
-- @param stroke_idx number  index of the stroke in self.strokes
-- @param skip_bookmark boolean  if true, skip bookmark sync (used during bootstrap)
function Pencil:assignStrokeToGroup(stroke_idx, skip_bookmark)
    local stroke = self.strokes[stroke_idx]
    if not stroke then return end

    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    if not bbox then return end
    if self:isFountainTool(stroke.tool) then
        local _, w_max = PencilGeometry.fountainWidthRange(stroke.width or 3)
        bbox = PencilGeometry.bboxExpand(bbox, math.ceil(w_max / 2))
    end

    local stroke_time = stroke.datetime or 0
    local best_group = nil

    for _, group in ipairs(self.annotation_groups) do
        if group.page == stroke.page then
            local time_diff = math.abs(stroke_time - (group.datetime_last or group.datetime or 0))
            if time_diff <= GROUP_TIME_THRESHOLD_S then
                local dist = PencilGeometry.bboxDistance(bbox, group.bbox)
                if dist <= GROUP_SPATIAL_THRESHOLD then
                    best_group = group
                    break
                end
            end
        end
    end

    if best_group then
        -- Merge into existing group
        table.insert(best_group.stroke_indices, stroke_idx)
        best_group.bbox = PencilGeometry.bboxUnion(best_group.bbox, bbox)
        best_group.datetime_last = math.max(best_group.datetime_last or 0, stroke_time)
        -- Update tool to majority
        local pen_count, hl_count = 0, 0
        for _, si in ipairs(best_group.stroke_indices) do
            local s = self.strokes[si]
            if s then
                if s.tool == TOOL_HIGHLIGHTER then hl_count = hl_count + 1
                else pen_count = pen_count + 1 end
            end
        end
        best_group.tool = hl_count > pen_count and TOOL_HIGHLIGHTER or TOOL_PEN
        if not skip_bookmark then
            self:markGroupDirty(best_group)
            -- Don't recapture/JPEG while writing — that froze the pen for seconds.
            best_group.image_stale = true
        end
    else
        -- Create new group
        local group = {
            id = "pencil_" .. os.date("%Y%m%d%H%M%S") .. "_" .. stroke_idx,
            page = stroke.page,
            stroke_indices = { stroke_idx },
            bbox = bbox,
            datetime = stroke_time,
            datetime_last = stroke_time,
            tool = (stroke.tool == TOOL_HIGHLIGHTER) and TOOL_HIGHLIGHTER or TOOL_PEN,
        }
        -- For rolling/EPUB docs, capture an XPointer AT THE ANNOTATION'S
        -- POSITION (bbox center) so we can re-resolve which page the
        -- annotation falls on after rotation / font change. CRITICAL: only
        -- valid when we're actually viewing the page this stroke was drawn
        -- on, because getTextFromPositions reads from the currently
        -- rendered page. During a full rebuild (after erase / undo) we
        -- process strokes from every page; for off-current-page strokes
        -- we skip the xpointer and let getGroupCurrentPage fall back to
        -- the saved group.page number. Backfill upgrades them later.
        if stroke.page == self:getCurrentPage() then
            local annot_xp = self:getXPointerAtBboxCenter(bbox)
            if annot_xp then
                group.xpointer = annot_xp
                group.xpointer_v2 = true
            end
        end
        table.insert(self.annotation_groups, group)
        if not skip_bookmark then
            self:markGroupDirty(group)
            group.image_stale = true
        end
    end
end

-- Mark a group as needing a bookmark sync on the next deferred-work flush.
-- Keeps the heavy getPageXPointer / annotation insertion off the writing path.
function Pencil:markGroupDirty(group)
    if not self.experimental_bookmark_sync then return end
    self.dirty_groups = self.dirty_groups or {}
    self.dirty_groups[group.id] = group
end

-- Rebuild all annotation groups from scratch by re-running the grouping algorithm
-- on all existing strokes sorted by datetime. Called after erase/undo operations.
function Pencil:rebuildAnnotationGroups()
    local ok, err = pcall(function()
        -- Remove all existing bookmarks for pencil groups, and cancel any
        -- pending image captures (group ids will change).
        for _, group in ipairs(self.annotation_groups) do
            self:removeGroupBookmark(group)
            self:cancelGroupImageCapture(group.id)
        end

        self.annotation_groups = {}

        -- Build list of {index, datetime} sorted by datetime
        local sorted = {}
        for i, stroke in ipairs(self.strokes) do
            table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
        end
        table.sort(sorted, function(a, b) return a.dt < b.dt end)

        -- Re-assign each stroke without JPEG/bookmark side effects. Captures
        -- run later on page change / idle, not on the erase hot path.
        for _, entry in ipairs(sorted) do
            self:assignStrokeToGroup(entry.idx, true)
        end
    end)
    if not ok then
        logger.warn("PenScribe: rebuildAnnotationGroups failed:", err)
        self.annotation_groups = self.annotation_groups or {}
    end
    -- Any JPEGs whose stem no longer matches a current group.id are now stale.
    self:purgeOrphanImages()
end

-- Get page number for bookmark display (always numeric).
function Pencil:getPageNumber(page_ref)
    if type(page_ref) == "number" then
        return page_ref
    end
    -- For XPointer (rolling docs), try to convert
    if self.ui.document and self.ui.document.getPageFromXPointer then
        local pn = self.ui.document:getPageFromXPointer(page_ref)
        if pn then return pn end
    end
    return 0
end

-- Get the bookmark page reference for a group.
-- For paging mode (PDF), this is the page number.
-- For rolling mode (EPUB), this must be an XPointer.
function Pencil:getBookmarkPageRef(group_page)
    if self.ui.rolling and self.ui.document and self.ui.document.getPageXPointer then
        -- group.page is a number (from getCurrentPage), convert back to XPointer
        return self.ui.document:getPageXPointer(group_page)
    end
    return group_page
end

-- Sync a group's bookmark into KOReader's annotation system.
function Pencil:syncGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then
        logger.dbg("PenScribe: annotation module not available, skipping bookmark sync")
        return
    end
    if not self.ui.annotation.annotations then
        logger.dbg("PenScribe: annotations not loaded yet, skipping bookmark sync")
        return
    end

    local ok, err = pcall(function()
        -- Remove existing bookmark for this group first
        self:removeGroupBookmark(group)

        local pageno = self:getPageNumber(group.page)
        local bookmark_page = self:getBookmarkPageRef(group.page)
        local chapter = ""
        if self.ui.toc and self.ui.toc.getTocTitleByPage then
            chapter = self.ui.toc:getTocTitleByPage(bookmark_page) or ""
        end

        local datetime = group.id  -- use group id as unique datetime key
        group.bookmark_datetime = datetime

        local item = {
            page = bookmark_page,
            datetime = datetime,
            text = string.format("PenScribe annotation on page %d", pageno),
            chapter = chapter,
        }

        if self.ui.annotation.addItem then
            self.ui.annotation:addItem(item)
            logger.dbg("PenScribe: synced bookmark for group", group.id, "on page", pageno)
        else
            logger.warn("PenScribe: annotation.addItem not available")
        end
    end)
    if not ok then
        logger.warn("PenScribe: bookmark sync failed:", err)
    end
end

-- Remove a group's bookmark from KOReader's annotation system.
function Pencil:removeGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then return end
    if not group.bookmark_datetime then return end

    local ok, err = pcall(function()
        local annotations = self.ui.annotation.annotations
        if not annotations then return end

        for i, ann in ipairs(annotations) do
            if ann.datetime == group.bookmark_datetime then
                table.remove(annotations, i)
                logger.dbg("PenScribe: removed bookmark for group", group.id)
                return
            end
        end
    end)
    if not ok then
        logger.warn("PenScribe: bookmark removal failed:", err)
    end
end

-- Remove ALL pencil bookmarks from KOReader's annotation system.
-- Used before re-syncing to avoid duplicates.
-- Note: always runs regardless of feature flag, so disabling cleans up.
function Pencil:removeAllPencilBookmarks()
    if not self.ui or not self.ui.annotation then return end
    local annotations = self.ui.annotation.annotations
    if not annotations then return end

    -- Remove in reverse order to maintain indices
    for i = #annotations, 1, -1 do
        if annotations[i].datetime and annotations[i].datetime:match("^pencil_") then
            table.remove(annotations, i)
        end
    end
end

-- Sync all annotation groups to bookmarks (used after load/rebuild).
function Pencil:syncAllBookmarks()
    if not self.experimental_bookmark_sync then return end

    -- Clean slate: remove all pencil bookmarks first to avoid duplicates
    self:removeAllPencilBookmarks()

    for _, group in ipairs(self.annotation_groups) do
        self:syncGroupBookmark(group)
    end
    logger.info("PenScribe: synced", #self.annotation_groups, "annotation group bookmarks")
end

------------------------------------------------------------------------------
-- Annotation image capture & preview (issue #51)
------------------------------------------------------------------------------

-- Directory holding per-group preview JPEGs for this document.
function Pencil:getImagesDir()
    if not self.ui or not self.ui.doc_settings then return nil end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if not sidecar_dir then return nil end
    return sidecar_dir .. "/pencil_images"
end

function Pencil:ensureImagesDir()
    local dir = self:getImagesDir()
    if not dir then return nil end
    local ok, err = lfs.mkdir(dir)
    if not ok and err ~= "File exists" then
        logger.warn("PenScribe: failed to create images dir:", err)
        return nil
    end
    return dir
end

function Pencil:getGroupImagePath(group)
    local dir = self:getImagesDir()
    if not dir or not group or not group.image_path then return nil end
    return dir .. "/" .. group.image_path
end

-- Render the captured-page-context image for a group into a Blitbuffer and
-- write it as a JPEG. Returns true on success.
function Pencil:captureGroupImage(group)
    if not group or not group.bbox then return false end
    if not self.view or not self.view.paintTo then return false end

    local dir = self:ensureImagesDir()
    if not dir then return false end

    -- Only capture if the group's page matches the current pagination;
    -- otherwise ReaderView would render the wrong content. For rolling docs
    -- this uses the group's XPointer (rotation-stable) when available.
    local gpage = self:getGroupCurrentPage(group)
    if gpage ~= self:getCurrentPage() then
        logger.dbg("PenScribe: captureGroupImage: page mismatch (group=", tostring(gpage),
            " current=", tostring(self:getCurrentPage()), "), deferring")
        return false
    end

    -- Capture a full-screen-width strip vertically bounded by the bbox + a
    -- small margin. This gives the user enough context (full line of text)
    -- when they preview the annotation from the bookmark list or rotation
    -- badge, instead of a tight crop that just shows the strokes.
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local rect = PencilGeometry.captureStripRect(
        group.bbox, sw, sh, IMAGE_CAPTURE_V_MARGIN_PX, IMAGE_MIN_HEIGHT_PX)
    local w = math.floor(rect.x1 - rect.x0)
    local h = math.floor(rect.y1 - rect.y0)
    if w < 8 or h < 8 then return false end

    -- Allocate offscreen buffer of the same type as Screen.bb so paintTo writes
    -- pixels in the format ReaderView expects.
    local bb_type = Screen.bb:getType()
    local ok_bb, off_bb = pcall(Blitbuffer.new, w, h, bb_type)
    if not ok_bb or not off_bb then
        logger.warn("PenScribe: failed to allocate offscreen buffer for capture")
        return false
    end

    -- Paint the page (and other plugins / highlights / dogear etc.) into the
    -- offscreen buffer. The (-x, -y) offset places the captured page region
    -- at (0, 0) inside off_bb; Blitbuffer paints clip to buffer bounds.
    local x0, y0 = math.floor(rect.x0), math.floor(rect.y0)
    self._capturing = true
    local ok_paint, paint_err = pcall(self.view.paintTo, self.view, off_bb, -x0, -y0)
    self._capturing = false
    if not ok_paint then
        logger.warn("PenScribe: ReaderView paint to offscreen failed:", paint_err)
        if off_bb.free then off_bb:free() end
        return false
    end

    -- Render this group's strokes over the painted page background.
    for _, idx in ipairs(group.stroke_indices or {}) do
        local stroke = self.strokes[idx]
        if stroke then
            self:renderStrokeOffset(off_bb, stroke, -x0, -y0)
        end
    end

    -- Downscale if longer side exceeds IMAGE_MAX_DIM (storage / encode budget).
    local final_bb = off_bb
    local longer = math.max(w, h)
    if longer > IMAGE_MAX_DIM and off_bb.scale then
        local scale = IMAGE_MAX_DIM / longer
        local sw_new = math.max(1, math.floor(w * scale))
        local sh_new = math.max(1, math.floor(h * scale))
        local ok_scale, scaled = pcall(off_bb.scale, off_bb, sw_new, sh_new)
        if ok_scale and scaled then
            final_bb = scaled
        end
    end

    -- Encode + write.
    local filename = group.id .. ".jpg"
    local fullpath = dir .. "/" .. filename
    local ok_write, write_err = pcall(final_bb.writeJPG, final_bb, fullpath, IMAGE_JPEG_QUALITY)

    -- Free buffers we own (final_bb might be the same object as off_bb after
    -- skipping the downscale path).
    if final_bb ~= off_bb and final_bb.free then final_bb:free() end
    if off_bb.free then off_bb:free() end

    if not ok_write then
        logger.warn("PenScribe: failed to write JPEG:", write_err)
        return false
    end

    group.image_path = filename
    group.image_rotation = Screen:getRotationMode()
    self.image_data_dirty = true
    logger.info("PenScribe: captured image for group", group.id, "rotation", group.image_rotation, "->", fullpath)
    return true
end

-- Variant of renderStroke that translates points by (dx, dy) before drawing.
-- Used during capture to render a group's strokes onto an offscreen buffer
-- whose origin corresponds to the bbox top-left.
function Pencil:renderStrokeOffset(bb, stroke, dx, dy)
    if not stroke or not stroke.points or #stroke.points < 1 then return end

    local tool = stroke.tool or TOOL_PEN
    if tool == TOOL_HIGHLIGHTER and self:isScribeMode() then
        self:renderHighlighterStroke(bb, stroke, dx, dy)
        return
    end

    local width = stroke.width or self.tool_settings[tool].width or 3
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK

    if Screen.night_mode and not isNeutralInkName(stroke.color_name) then
        color = color:invert()
    end

    local is_highlighter = (tool == TOOL_HIGHLIGHTER)

    if #stroke.points == 1 then
        local p = stroke.points[1]
        if is_highlighter then
            self:drawHighlighterDab(bb, p.x + dx, p.y + dy, width)
        else
            self:paintTipDab(bb, p.x + dx, p.y + dy, stroke, color)
        end
    else
        local heading_state = {}
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            if is_highlighter then
                self:drawHighlighterSegment(bb, p1.x + dx, p1.y + dy, p2.x + dx, p2.y + dy, width, color)
            else
                self:paintTipSegment(bb,
                    { x = p1.x + dx, y = p1.y + dy },
                    { x = p2.x + dx, y = p2.y + dy },
                    stroke, color, heading_state)
            end
        end
    end
end

function Pencil:isInkBusy()
    if self._flushing_captures then return false end
    return self.pen_down or self.current_stroke ~= nil or self._erase_session ~= nil
end

-- Schedule a deferred capture for the group. If a capture is already pending
-- for this group id, cancel and re-arm so we only capture once after the
-- grouping window has settled.
-- delay (optional): seconds before firing. Defaults to IMAGE_CAPTURE_DEBOUNCE_S
-- so we wait past the GROUP_TIME_THRESHOLD_S merge window before capturing a
-- fresh stroke. Backfill uses a shorter delay since no merges are pending.
function Pencil:scheduleGroupImageCapture(group, delay)
    if not group or not group.id then return end
    self.pending_image_captures = self.pending_image_captures or {}

    self:cancelGroupImageCapture(group.id)

    local cb = function()
        self.pending_image_captures[group.id] = nil
        if self:isInkBusy() then
            self:scheduleGroupImageCapture(group, 2)
            return
        end
        -- The group might have been deleted by the eraser by now.
        local current = nil
        for _, g in ipairs(self.annotation_groups) do
            if g.id == group.id then current = g; break end
        end
        if not current then return end
        local ok, err = pcall(self.captureGroupImage, self, current)
        if not ok then
            logger.warn("PenScribe: captureGroupImage error:", err)
        else
            current.image_stale = false
        end
        if self.image_data_dirty then
            self.image_data_dirty = false
            self:scheduleDeferredWork()
        end
    end

    self.pending_image_captures[group.id] = cb
    local d = delay or IMAGE_CAPTURE_DEBOUNCE_S
    UIManager:scheduleIn(d, cb)
    logger.dbg("PenScribe: scheduled image capture for group", group.id, "in", d, "seconds")
end

function Pencil:cancelGroupImageCapture(group_id)
    if not self.pending_image_captures then return end
    local cb = self.pending_image_captures[group_id]
    if cb then
        UIManager:unschedule(cb)
        self.pending_image_captures[group_id] = nil
    end
end

-- Run all pending captures synchronously and clear the queue. Called on
-- document close / suspend so we don't lose freshly drawn annotations.
function Pencil:flushPendingCaptures()
    self._flushing_captures = true
    if not self.pending_image_captures then
        self._flushing_captures = false
        return
    end
    local pending = self.pending_image_captures
    self.pending_image_captures = {}
    for _, cb in pairs(pending) do
        UIManager:unschedule(cb)
        local ok, err = pcall(cb)
        if not ok then
            logger.warn("PenScribe: flushPendingCaptures error:", err)
        end
    end
    self._flushing_captures = false
end

function Pencil:queueStaleImageCaptures()
    local page = self:getCurrentPage()
    for _, group in ipairs(self.annotation_groups or {}) do
        if self:getGroupCurrentPage(group) == page
                and (not group.image_path or group.image_stale) then
            self:scheduleGroupImageCapture(group, 0)
        end
    end
end

function Pencil:removeGroupImage(group)
    local path = self:getGroupImagePath(group)
    if not path then return end
    os.remove(path)
    group.image_path = nil
    group.image_rotation = nil
end

-- Delete any JPEG in pencil_images/ whose stem isn't a current group.id.
-- Called after group rebuilds (which regenerate ids) and during saveStrokes.
function Pencil:purgeOrphanImages()
    local dir = self:getImagesDir()
    if not dir then return end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return end

    local valid = {}
    for _, g in ipairs(self.annotation_groups or {}) do
        if g.image_path then
            valid[g.image_path] = true
        end
    end

    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." and file:match("%.jpg$") and not valid[file] then
            os.remove(dir .. "/" .. file)
            logger.dbg("PenScribe: purged orphan image", file)
        end
    end
end

-- Open the saved image for a group in an ImageViewer popup.
function Pencil:showGroupImagePreview(group)
    if not group then return end
    local path = self:getGroupImagePath(group)
    if not path then
        UIManager:show(InfoMessage:new{
            text = _("No saved image for this annotation yet."),
            timeout = 2,
        })
        return
    end
    local attr = lfs.attributes(path)
    if not attr then
        UIManager:show(InfoMessage:new{
            text = _("Annotation image is missing on disk."),
            timeout = 2,
        })
        return
    end
    local ImageViewer = require("ui/widget/imageviewer")
    local pageno = self:getPageNumber(group.page) or 0
    UIManager:show(ImageViewer:new{
        file = path,
        with_title_bar = true,
        title_text = T(_("Annotation - page %1"), pageno),
        fullscreen = false,
    })
end

-- Compute the on-screen badge rect for a stale-rotation group. The badge is
-- pinned to the right edge of the screen (i.e. in the margin) at a vertical
-- position proportional to the original bbox center Y, so multiple stale
-- annotations stack along the right side in roughly their original reading
-- order.
function Pencil:getGroupBadgeRect(group)
    if not group or not group.bbox or not group.image_rotation then return nil end
    local current_rot = Screen:getRotationMode()
    if current_rot == group.image_rotation then return nil end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    -- Source-rotation screen height: rotations 0/2 vs 1/3 swap width/height.
    local src_sh = sh
    if (group.image_rotation == 1 or group.image_rotation == 3) ~=
            (current_rot == 1 or current_rot == 3) then
        src_sh = sw
    end

    -- Vertical: proportional remap of the bbox center onto current screen.
    local cy = (group.bbox.y0 + group.bbox.y1) / 2
    local y_fraction = src_sh > 0 and (cy / src_sh) or 0.5
    local target_y = math.floor(y_fraction * sh)

    -- Horizontal: fixed position in the right margin. Simple and reliable;
    -- avoids depending on the document's reported page margins which can
    -- behave unexpectedly across EPUB engines.
    local badge_x = sw - IMAGE_BADGE_SIZE - IMAGE_BADGE_MARGIN_GAP

    local half = math.floor(IMAGE_BADGE_SIZE / 2)
    local x = math.max(0, math.min(sw - IMAGE_BADGE_SIZE, badge_x))
    local y = math.max(0, math.min(sh - IMAGE_BADGE_SIZE, target_y - half))
    return { x = x, y = y, w = IMAGE_BADGE_SIZE, h = IMAGE_BADGE_SIZE }
end

-- Pick a representative color for an annotation group: the first stroke's
-- saved color. Returns nil if no usable color is found, so the caller can
-- fall back to a default.
function Pencil:getGroupColor(group)
    if not group or not group.stroke_indices then return nil end
    for _, idx in ipairs(group.stroke_indices) do
        local stroke = self.strokes[idx]
        if stroke and stroke.color then
            return stroke.color
        end
    end
    return nil
end

function Pencil:renderRotationBadge(bb, group)
    local rect = self:getGroupBadgeRect(group)
    if not rect then return end
    -- Fill matches the annotation color so users can tell badges apart when
    -- a page has annotations in different colors. Black border for
    -- definition, white inner mark to suggest interactivity (and to keep
    -- light colors like gray / highlighter yellow visible).
    -- Must use paintRectRGB32 (not paintRect) to preserve the color channels
    -- of ColorRGB32 fills; paintRect treats the value as a luminance and
    -- would render colored fills as gray.
    local fill = self:getGroupColor(group)
            or Blitbuffer.ColorRGB32(0xCC, 0x00, 0x00, 0xFF)
    bb:paintRectRGB32(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_BLACK)
    bb:paintRectRGB32(rect.x + 2, rect.y + 2, rect.w - 4, rect.h - 4, fill)
    local inset = math.floor(rect.w / 3)
    bb:paintRectRGB32(rect.x + inset, rect.y + inset,
        rect.w - 2 * inset, rect.h - 2 * inset, Blitbuffer.COLOR_WHITE)
end

-- Compute the list of stale-rotation groups whose badges should be drawn on
-- the current page in the current rotation. Returns nil if no badges should
-- show (no stale groups, or suppressed because a native annotation is also
-- on this page). Shared by paintTo and findGroupBadgeAtPoint to keep
-- drawing and hit-testing in lockstep.
function Pencil:getStaleGroupsForCurrentView()
    local current_rot = Screen:getRotationMode()
    local page = self:getCurrentPage()
    local stale = nil
    local has_native = false
    for _, group in ipairs(self.annotation_groups or {}) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            if group.image_rotation == nil
                    or group.image_rotation == current_rot then
                has_native = true
            elseif group.image_path then
                stale = stale or {}
                stale[#stale + 1] = group
            end
        end
    end
    if has_native then return nil end
    return stale
end

-- Hit-test the rotation badges on the current page. Mirrors the drawing
-- logic in paintTo: a badge is tappable iff its group would have its badge
-- drawn by the current render pass.
function Pencil:findGroupBadgeAtPoint(x, y)
    local stale = self:getStaleGroupsForCurrentView()
    if not stale then return nil end
    for _, group in ipairs(stale) do
        local rect = self:getGroupBadgeRect(group)
        if rect
                and x >= rect.x - IMAGE_BADGE_HIT_PAD
                and x <= rect.x + rect.w + IMAGE_BADGE_HIT_PAD
                and y >= rect.y - IMAGE_BADGE_HIT_PAD
                and y <= rect.y + rect.h + IMAGE_BADGE_HIT_PAD then
            return group
        end
    end
    return nil
end

-- Called by the bookmark-list hook on menu select. Returns true if we
-- handled the tap (and the original navigation should be skipped).
function Pencil:tryShowImageForBookmark(item)
    if not item or not item.datetime then return false end
    if not item.datetime:match("^pencil_") then return false end
    -- Find the matching group by id (group.id is stored as the bookmark datetime).
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.id == item.datetime then
            if group.image_path then
                self:showGroupImagePreview(group)
                return true
            end
            return false  -- pencil bookmark but no image yet; fall through to navigate
        end
    end
    return false
end

-- Total disk usage of pencil_images/ for the current document, in bytes.
function Pencil:getImagesSizeBytes()
    local dir = self:getImagesDir()
    if not dir then return 0 end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return 0 end
    local total = 0
    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." then
            local fattr = lfs.attributes(dir .. "/" .. file)
            if fattr and fattr.size then total = total + fattr.size end
        end
    end
    return total
end

-- Remove all preview images for the current book and clear group references.
function Pencil:purgeAllImages()
    local dir = self:getImagesDir()
    if dir then
        local attr = lfs.attributes(dir)
        if attr and attr.mode == "directory" then
            for file in lfs.dir(dir) do
                if file ~= "." and file ~= ".." then
                    os.remove(dir .. "/" .. file)
                end
            end
        end
    end
    for _, group in ipairs(self.annotation_groups or {}) do
        group.image_path = nil
        group.image_rotation = nil
    end
    self:saveStrokes()
    UIManager:setDirty(self.view, "ui")
end

-- Re-capture missing images for groups on the currently visible page.
-- Called from onReaderReady and onPageUpdate so the user sees rotation
-- badges work without needing to redraw the annotation. Uses a short delay
-- so the page has fully rendered before we ask ReaderView to repaint into
-- our offscreen, but no merge-window wait since the group is already final.
function Pencil:backfillMissingImages()
    local page = self:getCurrentPage()
    for _, group in ipairs(self.annotation_groups or {}) do
        if self:getGroupCurrentPage(group) == page
                and (not group.image_path or group.image_stale) then
            self:scheduleGroupImageCapture(group, 1.0)
        end
    end
end

-- Install a one-time class-level patch on ReaderBookmark so that
-- long-pressing a pencil bookmark that has a saved image opens a
-- full-screen ImageViewer popup directly, instead of the standard
-- bookmark detail dialog. Closing the ImageViewer returns to the
-- bookmark list with nothing else stacked behind it.
--
-- Falls through to the standard dialog for non-pencil bookmarks and for
-- pencil bookmarks without a saved image. Short-tap still navigates to
-- the bookmark (default behavior, untouched).
function Pencil:installBookmarkHook()
    if _bookmark_hook_installed then return end

    local ok, ReaderBookmark = pcall(require, "apps/reader/modules/readerbookmark")
    if not ok or not ReaderBookmark or not ReaderBookmark.showBookmarkDetails then
        logger.warn("PenScribe: ReaderBookmark module not available, skipping hook")
        return
    end

    local original_showBookmarkDetails = ReaderBookmark.showBookmarkDetails
    function ReaderBookmark:showBookmarkDetails(item_or_index)
        local item = type(item_or_index) == "table"
            and item_or_index
            or (self.ui.annotation and self.ui.annotation.annotations
                    and self.ui.annotation.annotations[item_or_index])
        if item and item.datetime and item.datetime:match("^pencil_")
                and _active_pencil and _active_pencil.annotation_groups then
            for _, group in ipairs(_active_pencil.annotation_groups) do
                if group.id == item.datetime and group.image_path then
                    local path = _active_pencil:getGroupImagePath(group)
                    if path and lfs.attributes(path) then
                        _active_pencil:showGroupImagePreview(group)
                        return true  -- suppress standard dialog
                    end
                    break
                end
            end
        end
        return original_showBookmarkDetails(self, item_or_index)
    end

    _bookmark_hook_installed = true
    logger.info("PenScribe: installed bookmark list hook")
end

-- Rebuild page index from strokes
function Pencil:rebuildPageIndex()
    self.page_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        self:indexStroke(i, stroke.page)
    end
end

-- Get strokes for a specific page
function Pencil:getStrokesForPage(page)
    local result = {}
    local indices = self.page_strokes[page] or {}
    for _, idx in ipairs(indices) do
        if self.strokes[idx] then
            table.insert(result, self.strokes[idx])
        end
    end
    return result
end

-- Check if current page has strokes
function Pencil:hasStrokesOnCurrentPage()
    local page = self:getCurrentPage()
    return self.page_strokes[page] and #self.page_strokes[page] > 0
end

-- Clear strokes on current page
function Pencil:clearPageStrokes()
    local page = self:getCurrentPage()
    local indices_to_remove = self.page_strokes[page]

    if not indices_to_remove or #indices_to_remove == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No annotations found on this page."),
            timeout = 1,
        })
        return
    end

    -- Copy and sort in reverse order to maintain indices during removal
    local sorted_indices = {}
    for _, idx in ipairs(indices_to_remove) do
        table.insert(sorted_indices, idx)
    end
    table.sort(sorted_indices, function(a, b) return a > b end)

    local deleted_strokes = {}
    for _, idx in ipairs(sorted_indices) do
        if self.strokes[idx] then
            table.insert(deleted_strokes, self.strokes[idx])
            table.remove(self.strokes, idx)
        end
    end

    if #deleted_strokes > 0 then
        table.insert(self.undo_stack, { type = "delete", strokes = deleted_strokes })
    end

    self:rebuildPageIndex()
    self:rebuildAnnotationGroups()
    self:saveStrokes()

    UIManager:show(InfoMessage:new{
        text = T(_("Cleared %1 annotation(s) from page."), #deleted_strokes),
        timeout = 1,
    })
    UIManager:setDirty(self.view, "ui")
end

-- Clear all strokes
function Pencil:clearAllStrokes()
    -- Remove all bookmarks for annotation groups + delete their images.
    for _, group in ipairs(self.annotation_groups) do
        self:removeGroupBookmark(group)
        self:cancelGroupImageCapture(group.id)
        self:removeGroupImage(group)
    end
    self.strokes = {}
    self.page_strokes = {}
    self.annotation_groups = {}
    self:saveStrokes()
    -- Belt-and-suspenders: any leftover files get reaped.
    self:purgeOrphanImages()

    UIManager:setDirty(self.view, "ui")
end

-- Highlighter: live path stamps light-gray disks like the pen (fast refresh).
-- Finished Scribe paint uses a bbox mask + multiply so text shows through
-- without overlap darkening. Live no longer uses full-screen hl_bg/hl_mask.
local HIGHLIGHT_MUL_GRAY = 0xB8
local HIGHLIGHT_LIVE_GRAY = 0xDD

function Pencil:getHighlighterMaskColor()
    return Blitbuffer.Color8(HIGHLIGHT_MUL_GRAY)
end

function Pencil:getHighlighterLiveColor()
    return Blitbuffer.Color8(HIGHLIGHT_LIVE_GRAY)
end

function Pencil:freeHighlighterLiveBuffers()
    if self.hl_bg then
        self.hl_bg:free()
        self.hl_bg = nil
    end
    if self.hl_mask then
        self.hl_mask:free()
        self.hl_mask = nil
    end
    self._hl_sample_count = 0
    self._hl_stroke_dirty = nil
end

-- Filled disk dab (circular brush). Works on BB8 masks and RGB screen buffers.
function Pencil:paintDisk(bb, cx, cy, diameter, color)
    if not bb or not diameter or diameter < 1 then return end
    cx = math.floor(cx + 0.5)
    cy = math.floor(cy + 0.5)
    local r = math.max(0, math.floor(diameter / 2))
    local use_bb8 = bb.getType and bb:getType() == Blitbuffer.TYPE_BB8
    local use_rgb32 = (not use_bb8) and bb.paintRectRGB32
    if r < 1 then
        if use_bb8 then
            bb:paintRect(cx, cy, 1, 1, color)
        elseif use_rgb32 then
            bb:paintRectRGB32(cx, cy, 1, 1, color)
        else
            bb:paintRect(cx, cy, 1, 1, color)
        end
        return
    end
    local r2 = r * r
    for dy = -r, r do
        local dx_max = math.floor(math.sqrt(r2 - dy * dy) + 0.5)
        local x = cx - dx_max
        local y = cy + dy
        local w = 2 * dx_max + 1
        if use_bb8 then
            bb:paintRect(x, y, w, 1, color)
        elseif use_rgb32 then
            bb:paintRectRGB32(x, y, w, 1, color)
        else
            bb:paintRect(x, y, w, 1, color)
        end
    end
end

-- Paint a finished highlighter stroke once through a bbox mask (no overlap darkening).
function Pencil:renderHighlighterStroke(bb, stroke, dx, dy)
    dx = dx or 0
    dy = dy or 0
    if not stroke or not stroke.points or #stroke.points < 1 then return end

    local width = stroke.width or self.tool_settings[TOOL_HIGHLIGHTER].width or 50
    local pad = math.floor(width / 2) + 2
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    for _, p in ipairs(stroke.points) do
        min_x = math.min(min_x, p.x)
        min_y = math.min(min_y, p.y)
        max_x = math.max(max_x, p.x)
        max_y = math.max(max_y, p.y)
    end
    min_x = math.floor(min_x - pad)
    min_y = math.floor(min_y - pad)
    max_x = math.ceil(max_x + pad)
    max_y = math.ceil(max_y + pad)

    local bw = max_x - min_x + 1
    local bh = max_y - min_y + 1
    if bw <= 0 or bh <= 0 then return end

    local mask = Blitbuffer.new(bw, bh, Blitbuffer.TYPE_BB8)
    mask:fill(Blitbuffer.COLOR_WHITE)
    local ink = self:getHighlighterMaskColor()

    if #stroke.points == 1 then
        local p = stroke.points[1]
        self:paintDisk(mask, p.x - min_x, p.y - min_y, width, ink)
    else
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            self:paintHighlighterDiskSegment(mask,
                p1.x - min_x, p1.y - min_y,
                p2.x - min_x, p2.y - min_y,
                width, ink)
        end
    end

    bb:blitFrom(mask, min_x + dx, min_y + dy, 0, 0, bw, bh, bb.setPixelMultiply)
    mask:free()
end

function Pencil:paintHighlighterDiskSegment(bb, x1, y1, x2, y2, width, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then
        self:paintDisk(bb, x1, y1, width, color)
        return
    end
    -- Overlap disks enough for a smooth ribbon without 1px CPU thrash.
    local step_px = math.max(1, math.floor(width / 4))
    local steps = math.max(1, math.ceil(dist / step_px))
    for i = 0, steps do
        local t = i / steps
        self:paintDisk(bb,
            math.floor(x1 + dx * t + 0.5),
            math.floor(y1 + dy * t + 0.5),
            width, color)
    end
end

-- Live highlighter: light-gray circular stamps (same feel as pen ink).
function Pencil:drawHighlighterDab(bb, x, y, width)
    self:paintDisk(bb, x, y, width, self:getHighlighterLiveColor())
end

function Pencil:drawHighlighterSegment(bb, x1, y1, x2, y2, width, _color)
    self:paintHighlighterDiskSegment(bb, x1, y1, x2, y2, width, self:getHighlighterLiveColor())
end

-- Render a line segment using rectangles (since BlitBuffer has no native line drawing)
function Pencil:drawLineSegment(bb, x1, y1, x2, y2, width, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local half_w = math.floor(width / 2)
    -- BB8 masks need paintRect; RGB screen buffers use paintRectRGB32.
    local use_bb8 = bb.getType and bb:getType() == Blitbuffer.TYPE_BB8
    local function dab(x, y)
        if use_bb8 then
            bb:paintRect(x - half_w, y - half_w, width, width, color)
        else
            bb:paintRectRGB32(x - half_w, y - half_w, width, width, color)
        end
    end

    if dist < 1 then
        dab(x1, y1)
        return
    end

    -- Step by a fraction of brush size — 1px steps on a width-50 HL were crushing the CPU.
    local step_px = math.max(1, math.floor(width / 3))
    local steps = math.max(1, math.ceil(dist / step_px))
    for i = 0, steps do
        local t = i / steps
        dab(math.floor(x1 + dx * t), math.floor(y1 + dy * t))
    end
end

function Pencil:fountainWidthParams(stroke)
    local w_max = (stroke and stroke.width) or self.tool_settings[TOOL_PEN].width or 3
    local w_min
    w_min, w_max = PencilGeometry.fountainWidthRange(w_max)
    return w_min, w_max, PencilGeometry.FOUNTAIN_NIB_ANGLE
end

-- Stamp a solid black chisel edge at the fixed nib angle.
function Pencil:stampFountainNib(bb, x, y, w_min, nib_len, angle, color)
    local half = math.max(w_min, nib_len) / 2
    local nx, ny = math.cos(angle), math.sin(angle)
    self:drawLineSegment(bb,
        x - nx * half, y - ny * half,
        x + nx * half, y + ny * half,
        math.max(1, math.floor(w_min + 0.5)),
        color)
end

-- Heading sets chisel length for this segment (wider thin zone via FOUNTAIN_THIN_POWER).
function Pencil:drawFountainNibSegment(bb, x1, y1, x2, y2, w_min, w_max, angle, color, heading)
    local nib_len = PencilGeometry.nibLengthForHeading(heading, angle, w_min, w_max)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local step_px = math.max(1, math.floor(w_min))
    local steps = math.max(1, math.ceil(dist / step_px))
    for i = 0, steps do
        local t = i / steps
        self:stampFountainNib(bb, x1 + dx * t, y1 + dy * t, w_min, nib_len, angle, color)
    end
end

-- Ballpoint / Nib / Dir dab. Returns dirty pad in pixels.
function Pencil:paintTipDab(bb, x, y, stroke, color)
    local tool = stroke.tool or TOOL_PEN
    if tool == TOOL_FOUNTAIN_NIB then
        local w_min, w_max, angle = self:fountainWidthParams(stroke)
        -- No heading yet: hairline dab, not a full chisel blob.
        self:stampFountainNib(bb, x, y, w_min, w_min, angle, color)
        return math.ceil(w_max / 2 + w_min / 2) + 2
    end
    if tool == TOOL_FOUNTAIN_DIR then
        local w_min = self:fountainWidthParams(stroke)
        local w = math.max(1, math.floor(w_min + 0.5))
        self:drawLineSegment(bb, x, y, x, y, w, color)
        return math.ceil(w / 2) + 2
    end
    local width = stroke.width or 3
    -- Round stamps (not square paintRect) — rect tips look blocky on e-ink.
    self:paintDisk(bb, x, y, width, color)
    return math.floor(width / 2) + 2
end

-- Ballpoint / Nib / Dir segment. heading_state is mutated for Dir/Nib smoothing
-- (live: self; replay: a fresh {}). Returns dirty pad in pixels.
function Pencil:paintTipSegment(bb, p1, p2, stroke, color, heading_state)
    local tool = stroke.tool or TOOL_PEN
    if tool == TOOL_FOUNTAIN_NIB then
        local w_min, w_max, angle = self:fountainWidthParams(stroke)
        heading_state = heading_state or {}
        local heading = PencilGeometry.strokeHeading(p1, p2)
        if heading then
            heading_state._fountain_heading = PencilGeometry.smoothHeading(
                heading_state._fountain_heading, heading, PencilGeometry.FOUNTAIN_HEADING_SMOOTH)
        end
        self:drawFountainNibSegment(bb, p1.x, p1.y, p2.x, p2.y, w_min, w_max, angle, color,
            heading_state._fountain_heading)
        return math.ceil(w_max / 2 + w_min / 2) + 2
    end
    if tool == TOOL_FOUNTAIN_DIR then
        local w_min, w_max, angle = self:fountainWidthParams(stroke)
        heading_state = heading_state or {}
        local heading = PencilGeometry.strokeHeading(p1, p2)
        if heading then
            heading_state._fountain_heading = PencilGeometry.smoothHeading(
                heading_state._fountain_heading, heading, PencilGeometry.FOUNTAIN_HEADING_SMOOTH)
        end
        local width = w_min
        if heading_state._fountain_heading then
            width = PencilGeometry.nibWidth(heading_state._fountain_heading, angle, w_min, w_max)
        end
        width = math.max(1, math.floor(width + 0.5))
        self:drawLineSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color)
        return math.ceil(width / 2) + 2
    end
    local width = stroke.width or 3
    self:paintHighlighterDiskSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color)
    return math.floor(width / 2) + 2
end

-- Check if a point is near a stroke (for eraser)
function Pencil:isPointNearStroke(px, py, stroke, threshold)
    return PencilGeometry.isPointNearStroke(px, py, stroke, threshold)
end

function Pencil:cloneStroke(stroke)
    local c = {
        page = stroke.page,
        tool = stroke.tool,
        width = stroke.width,
        color = stroke.color,
        color_name = stroke.color_name,
        alpha = stroke.alpha,
        datetime = stroke.datetime,
        points = {},
    }
    if stroke.points then
        for i, p in ipairs(stroke.points) do
            c.points[i] = { x = p.x, y = p.y }
        end
    end
    return c
end

function Pencil:beginEraseSession()
    if self._erase_session then return end
    self:cancelEraseUiSettle()
    self._erase_session = {
        dabs = {},
        page = self:getCurrentPage(),
        changed = false,
        dirty = nil,
        -- Local rect for the latest paint only (live refresh). Full-session
        -- dirty is kept separately for the lift-time UI settle.
        paint_dirty = nil,
        last_paint_x = nil,
        last_paint_y = nil,
        last_refresh_time = time.now(),
    }
end

function Pencil:expandEraseDirty(x, y, width)
    local half = math.floor(width / 2) + 2
    local x0, y0 = x - half, y - half
    local x1, y1 = x + half, y + half
    local session = self._erase_session
    local function union_into(r)
        if not r then
            return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
        end
        local nx = math.min(r.x, x0)
        local ny = math.min(r.y, y0)
        local nx2 = math.max(r.x + r.w, x1)
        local ny2 = math.max(r.y + r.h, y1)
        return { x = nx, y = ny, w = nx2 - nx, h = ny2 - ny }
    end
    local full = union_into(session and session.dirty or self._erase_dirty)
    if session then
        session.dirty = full
        -- Live refresh must stay local: only this dab (plus a little), not the
        -- whole erase trail. Refreshing the union every sample is what froze
        -- long continuous erasures.
        session.paint_dirty = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    end
    self._erase_dirty = full
end

function Pencil:refreshEraseDirty(force, mode)
    local session = self._erase_session
    -- Prefer the latest dab rect while dragging; fall back to full dirty on lift.
    local r = (session and session.paint_dirty)
        or (session and session.dirty)
        or self._erase_dirty
    if not r then return end
    local now = time.now()
    if not force and session and session.last_refresh_time then
        if time.to_ms(now - session.last_refresh_time) < (self.refresh_interval_ms or 16) then
            return
        end
    end
    if session then
        session.last_refresh_time = now
        session.paint_dirty = nil
    end
    local rx = math.max(0, math.floor(r.x))
    local ry = math.max(0, math.floor(r.y))
    local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
    local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
    if rw > 0 and rh > 0 then
        if mode == "ui" then
            Screen:refreshUI(rx, ry, rw, rh)
            self._ink_used_fast_refresh = false
        else
            Screen:refreshFast(rx, ry, rw, rh)
            self._ink_used_fast_refresh = true
            self._panel_needs_ui_kick = true
        end
        self._last_refresh_rect = { x = rx, y = ry, w = rw, h = rh }
    end
end

function Pencil:paintEraseDab(x, y, width)
    local half = math.floor(width / 2)
    local use_bb8 = Screen.bb.getType and Screen.bb:getType() == Blitbuffer.TYPE_BB8
    if use_bb8 then
        Screen.bb:paintRect(x - half, y - half, width, width, Blitbuffer.COLOR_WHITE)
    else
        Screen.bb:paintRectRGB32(x - half, y - half, width, width, Blitbuffer.COLOR_WHITE)
    end
    self:expandEraseDirty(x, y, width)
end

-- Screen-space erase: cover ink under the tip now; punch polylines on lift.
function Pencil:eraseDabLive(x, y)
    self:beginEraseSession()
    local session = self._erase_session
    local width = self.tool_settings[TOOL_ERASER].width or 40
    local radius = math.ceil(width / 2)

    -- Paint from the last *painted* tip, not the last stored dab.
    -- Using stored dabs as the baseline re-stamped the whole trail on every
    -- sample (O(n²) paint) during a long drag without lift.
    local from_x = session.last_paint_x
    local from_y = session.last_paint_y
    if from_x == nil then
        table.insert(session.dabs, { x = x, y = y, r = radius })
        self:paintEraseDab(x, y, width)
        session.last_paint_x, session.last_paint_y = x, y
    else
        local dx, dy = x - from_x, y - from_y
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < 1 then return end
        -- White 40px dabs; sparse steps are fine and much cheaper.
        local paint_step = math.max(1, math.floor(width / 2))
        local store_step = radius
        local last_stored = session.dabs[#session.dabs]
        local steps = math.max(1, math.ceil(dist / paint_step))
        for i = 1, steps do
            local t = i / steps
            local px, py = from_x + dx * t, from_y + dy * t
            self:paintEraseDab(px, py, width)
            if last_stored then
                local sdx, sdy = px - last_stored.x, py - last_stored.y
                if (sdx * sdx + sdy * sdy) >= (store_step * store_step) then
                    last_stored = { x = px, y = py, r = radius }
                    table.insert(session.dabs, last_stored)
                end
            end
        end
        session.last_paint_x, session.last_paint_y = x, y
    end
    self:refreshEraseDirty(false, "fast")
    local hl = session._last_hl
    if not hl or (x - hl.x) * (x - hl.x) + (y - hl.y) * (y - hl.y) >= 24 * 24 then
        session._last_hl = { x = x, y = y }
        self:eraseHighlightAtScreenPos(x, y)
    end
end

function Pencil:cancelEraseUiSettle()
    if self._erase_ui_settle then
        UIManager:unschedule(self._erase_ui_settle)
        self._erase_ui_settle = nil
    end
end

-- REVERT-ERASE-SETTLE: (1) skip heavy punch when no ink hit; (2) defer UI
-- settle so lift returns immediately. Remove this helper + call sites to revert.
function Pencil:scheduleEraseUiSettle(dirty)
    if not dirty then
        self._erase_dirty = nil
        return
    end
    self:cancelEraseUiSettle()
    local region = Geom:new{
        x = math.max(0, math.floor(dirty.x)),
        y = math.max(0, math.floor(dirty.y)),
        w = math.max(1, math.ceil(dirty.w)),
        h = math.max(1, math.ceil(dirty.h)),
    }
    region.w = math.min(Screen:getWidth() - region.x, region.w)
    region.h = math.min(Screen:getHeight() - region.y, region.h)
    self._last_refresh_rect = { x = region.x, y = region.y, w = region.w, h = region.h }
    self._erase_dirty = nil
    -- Short defer: tip-up stays responsive; text under white dabs restores next tick.
    self._erase_ui_settle = UIManager:scheduleIn(0.05, function()
        self._erase_ui_settle = nil
        if region.w > 0 and region.h > 0 then
            UIManager:setDirty(self.view, "ui", region)
            self._ink_used_fast_refresh = false
            self._panel_needs_ui_kick = false
        end
    end)
end

function Pencil:commitEraseSession()
    local session = self._erase_session
    self._erase_session = nil
    if not session or not session.dabs or #session.dabs == 0 then
        return
    end
    local page = session.page
    local dabs = session.dabs
    local dab_bbox = PencilGeometry.dabsBbox(dabs, 8)
    local dirty = session.dirty or self._erase_dirty

    -- (1) No ink under the trail: skip clone/split/rebuild entirely.
    local any_hit = false
    if dab_bbox then
        for _, stroke in ipairs(self.strokes) do
            if stroke.page == page then
                local extra = 0
                if self:isFountainTool(stroke.tool) then
                    extra = math.ceil((stroke.width or 3) / 2)
                elseif stroke.tool == TOOL_HIGHLIGHTER then
                    extra = math.ceil((stroke.width or 20) / 4)
                end
                local sb = PencilGeometry.computeStrokeBbox(stroke)
                if sb and PencilGeometry.bboxesOverlap(
                        PencilGeometry.bboxExpand(sb, extra + 2), dab_bbox) then
                    any_hit = true
                    break
                end
            end
        end
    end
    if not any_hit then
        -- White dabs may still cover page text — deferred settle only.
        self:scheduleEraseUiSettle(dirty)
        return
    end

    local kept = {}
    local changed = false

    for _, stroke in ipairs(self.strokes) do
        if stroke.page ~= page then
            table.insert(kept, stroke)
        else
            local extra = 0
            if self:isFountainTool(stroke.tool) then
                extra = math.ceil((stroke.width or 3) / 2)
            elseif stroke.tool == TOOL_HIGHLIGHTER then
                extra = math.ceil((stroke.width or 20) / 4)
            end
            local sb = PencilGeometry.computeStrokeBbox(stroke)
            if sb and dab_bbox and not PencilGeometry.bboxesOverlap(
                    PencilGeometry.bboxExpand(sb, extra + 2), dab_bbox) then
                table.insert(kept, stroke)
            else
                local frags = PencilGeometry.splitStrokeByEraseDabs(stroke, dabs, extra)
                if #frags ~= 1 or (frags[1] and #frags[1].points ~= #(stroke.points or {})) then
                    changed = true
                end
                for _, frag in ipairs(frags) do
                    table.insert(kept, frag)
                end
            end
        end
    end

    if changed then
        local old_page = {}
        for _, stroke in ipairs(self.strokes) do
            if stroke.page == page then
                table.insert(old_page, self:cloneStroke(stroke))
            end
        end
        self.strokes = kept
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        table.insert(self.undo_stack, {
            type = "replace_page",
            page = page,
            strokes = old_page,
        })
        self:scheduleDeferredWork()

        -- Stock-style periodic full refresh cleans ghosting from Fast erase
        -- dabs. Only count lifts that actually removed ink.
        self._erase_hit_streak = (self._erase_hit_streak or 0) + 1
        if self._erase_hit_streak >= 3 then
            self._erase_hit_streak = 0
            self:cancelEraseUiSettle()
            self._erase_dirty = nil
            self:forceInkRefresh(nil)
            return
        end
    end

    -- (2) Always defer UI settle (restore text under white); never block tip-up.
    self:scheduleEraseUiSettle(dirty)
end

-- Legacy name: one-shot punch at a point (tap / fallback).
function Pencil:eraseAtPoint(x, y, page)
    self:beginEraseSession()
    if page then self._erase_session.page = page end
    self:eraseDabLive(x, y)
    self:commitEraseSession()
    return true
end

-- Render a complete stroke
function Pencil:renderStroke(bb, stroke)
    if not stroke.points or #stroke.points < 1 then
        return
    end

    local tool = stroke.tool or TOOL_PEN
    if tool == TOOL_HIGHLIGHTER and self:isScribeMode() then
        self:renderHighlighterStroke(bb, stroke)
        return
    end

    local width = stroke.width or self.tool_settings[tool].width or 3

    -- Get color directly (it's already a Blitbuffer color)
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK

    -- Reinvert color in night mode (if it's not black or gray)
    if Screen.night_mode and not isNeutralInkName(stroke.color_name) then
        color = color:invert()
    end

    local is_highlighter = (tool == TOOL_HIGHLIGHTER)
    if is_highlighter then
        color = stroke.color or Blitbuffer.Color8(0xDD)
    end

    if #stroke.points == 1 then
        local p = stroke.points[1]
        if is_highlighter then
            self:drawHighlighterDab(bb, p.x, p.y, width)
        else
            self:paintTipDab(bb, p.x, p.y, stroke, color)
        end
    else
        local heading_state = {}
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            if is_highlighter then
                self:drawHighlighterSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color)
            else
                self:paintTipSegment(bb, p1, p2, stroke, color, heading_state)
            end
        end
    end
end

-- View module paintTo method - called by ReaderView during repaints.
-- When the captureGroupImage routine asks ReaderView to repaint into our
-- offscreen buffer, this method is invoked recursively as part of the view
-- module loop; the _capturing guard suppresses re-entry so we can paint the
-- group's strokes deliberately onto the captured page background.
function Pencil:paintTo(bb, x, y)
    if self._capturing then return end

    local page = self:getCurrentPage()
    local current_rot = Screen:getRotationMode()

    -- Backfill XPointers for legacy groups before we filter, so the
    -- rotation-aware page resolution below sees them.
    self:backfillGroupXPointers()

    -- Identify groups whose captured-image rotation no longer matches the
    -- current screen rotation. Their strokes will draw in the wrong place,
    -- so we skip them and draw a badge instead. For EPUB we match by the
    -- group's XPointer re-resolved to the current pagination, since the
    -- saved group.page would be stale across rotations.
    --
    -- Suppression: if any group on this page renders natively at the
    -- current rotation (i.e. matches current_rot, or pre-dates the feature
    -- entirely), we hide badges for OTHER stale groups on the same page so
    -- the view isn't cluttered with badges next to a visible annotation.
    -- Re-rotate to see the suppressed annotation.
    local stale_indices = nil
    local stale_groups = nil
    local groups_on_page = 0
    local groups_with_image = 0
    local has_native_annotation = false
    for _, group in ipairs(self.annotation_groups) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            groups_on_page = groups_on_page + 1
            if group.image_path then
                groups_with_image = groups_with_image + 1
            end
            if group.image_rotation == nil
                    or group.image_rotation == current_rot then
                -- Renders natively (same rotation as capture, or legacy group
                -- without rotation info — render strokes as-is).
                has_native_annotation = true
            elseif group.image_path then
                stale_groups = stale_groups or {}
                stale_groups[#stale_groups + 1] = group
                stale_indices = stale_indices or {}
                for _, idx in ipairs(group.stroke_indices or {}) do
                    stale_indices[idx] = true
                end
            end
        end
    end
    if has_native_annotation then
        -- Drop badges entirely; native-rotation strokes will render below.
        stale_groups = nil
        stale_indices = nil
    end
    local stale_count = stale_groups and #stale_groups or 0
    if not self._last_paint_log
            or self._last_paint_log.page ~= page
            or self._last_paint_log.rot ~= current_rot
            or self._last_paint_log.on_page ~= groups_on_page
            or self._last_paint_log.with_image ~= groups_with_image
            or self._last_paint_log.stale ~= stale_count
            or self._last_paint_log.native ~= has_native_annotation then
        logger.info("PenScribe: paintTo page=", page, " rot=", current_rot,
            " groups_on_page=", groups_on_page,
            " with_image=", groups_with_image,
            " native=", tostring(has_native_annotation),
            " badges=", stale_count)
        self._last_paint_log = {
            page = page,
            rot = current_rot,
            on_page = groups_on_page,
            with_image = groups_with_image,
            stale = stale_count,
            native = has_native_annotation,
        }
    end

    -- Render saved strokes for current page (skipping stale ones).
    local indices = self.page_strokes[page] or {}
    for _, idx in ipairs(indices) do
        if not (stale_indices and stale_indices[idx]) then
            local stroke = self.strokes[idx]
            if stroke then
                self:renderStroke(bb, stroke)
            end
        end
    end

    -- Draw rotation-mismatch badges over the spots where the strokes would
    -- have appeared. Tapping a badge opens the saved image.
    if stale_groups then
        for _, group in ipairs(stale_groups) do
            self:renderRotationBadge(bb, group)
        end
    end

    -- Render current stroke being drawn (only if on current page)
    if self.current_stroke and self.current_stroke.page == page then
        self:renderStroke(bb, self.current_stroke)
    end

    -- Always-on tool rails when Pencil is enabled
    self:paintToolRail(bb)
    self:paintHRail(bb)
end

-- Get the pencil strokes file path for this document
function Pencil:getStrokesFilePath()
    if not self.ui or not self.ui.doc_settings then
        logger.warn("PenScribe: doc_settings not available")
        return nil
    end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/pencil_strokes.lua"
    end
    logger.warn("PenScribe: sidecar_dir not available")
    return nil
end

-- Load strokes from our own file
function Pencil:loadStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("PenScribe: loadStrokes - filepath =", filepath)

    if not filepath then
        logger.warn("PenScribe: no filepath available for loading strokes")
        self.strokes = {}
        self.page_strokes = {}
        return
    end

    -- Check if file exists
    local file_exists = io.open(filepath, "r")
    if not file_exists then
        logger.info("PenScribe: strokes file does not exist yet:", filepath)
        self.strokes = {}
        self.page_strokes = {}
        self.strokes_loaded = true
        return
    end
    file_exists:close()

    local ok, data = pcall(dofile, filepath)
    if ok and data and data.strokes then
        -- Convert saved strokes back to usable format
        self.strokes = {}
        for i, saved in ipairs(data.strokes) do
            self.strokes[i] = self:strokeFromSaved(saved)
        end
        self:rebuildPageIndex()

        -- Load annotation groups or bootstrap from v1 data
        if data.annotation_groups and #data.annotation_groups > 0 then
            self.annotation_groups = data.annotation_groups
            logger.info("PenScribe: loaded", #self.annotation_groups, "annotation groups")
        else
            -- v1 data or no groups — bootstrap by running grouping on all strokes
            -- skip_bookmark=true because annotation module isn't ready yet during load
            logger.info("PenScribe: bootstrapping annotation groups from strokes")
            self.annotation_groups = {}
            local sorted = {}
            for i, stroke in ipairs(self.strokes) do
                table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
            end
            table.sort(sorted, function(a, b) return a.dt < b.dt end)
            for _, entry in ipairs(sorted) do
                self:assignStrokeToGroup(entry.idx, true)
            end
        end

        self.strokes_loaded = true
        logger.info("PenScribe: loaded", #self.strokes, "strokes from", filepath)
    else
        logger.warn("PenScribe: failed to load strokes from", filepath, "error:", data)
        self.strokes = {}
        self.page_strokes = {}
        self.annotation_groups = {}
    end
end

-- Convert stroke for saving (remove non-serializable values)
function Pencil:strokeToSaveable(stroke)
    return {
        page = stroke.page,
        tool = stroke.tool,
        width = stroke.width,
        alpha = stroke.alpha,
        datetime = stroke.datetime,
        points = stroke.points,
        color_name = stroke.color_name,  -- Save color name for persistence
    }
end

-- Convert saved stroke back to usable format
function Pencil:strokeFromSaved(saved)
    local tool = saved.tool or TOOL_PEN
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    -- Look up color from color_name
    local color = tool_settings.color
    if saved.color_name then
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == saved.color_name then
                color = color_info.color
                break
            end
        end
    end

    return {
        page = saved.page,
        tool = saved.tool,
        width = saved.width or tool_settings.width,
        color = color,
        color_name = saved.color_name,
        alpha = saved.alpha or tool_settings.alpha,
        datetime = saved.datetime,
        points = saved.points,
    }
end

-- Save strokes to our own file
function Pencil:saveStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("PenScribe: saveStrokes - filepath =", filepath, "strokes count =", #self.strokes)

    if not filepath then
        logger.warn("PenScribe: no filepath available for saving strokes")
        return
    end

    -- Safety: don't save empty data if strokes were never successfully loaded
    -- (prevents data loss if a crash causes save before load completes)
    if #self.strokes == 0 and not self.strokes_loaded then
        logger.warn("PenScribe: refusing to save empty strokes (strokes never loaded)")
        return
    end

    -- Ensure the directory exists
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        local ok, err = lfs.mkdir(sidecar_dir)
        if not ok and err ~= "File exists" then
            logger.warn("PenScribe: failed to create sidecar dir:", err)
        end
    end

    -- Convert strokes to saveable format (remove non-serializable values)
    local saveable_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        saveable_strokes[i] = self:strokeToSaveable(stroke)
    end

    -- Serialize and write. Version 3 marks files that may contain image_path /
    -- image_rotation fields on annotation groups; older readers can ignore
    -- those fields and continue to use the strokes directly.
    local data = {
        version = 3,
        strokes = saveable_strokes,
        annotation_groups = self.annotation_groups,
    }

    local f, err = io.open(filepath, "w")
    if f then
        f:write("return " .. require("dump")(data))
        f:close()
        logger.info("PenScribe: saved", #self.strokes, "strokes to", filepath)
    else
        logger.err("PenScribe: failed to open file for writing:", filepath, "error:", err)
    end
end

-- Handle document close
function Pencil:onCloseDocument()
    logger.info("PenScribe: onCloseDocument called, strokes count =", #self.strokes)

    -- Cancel any pending refresh
    self:cancelPendingRefresh()
    self:cancelEraseUiSettle()
    -- Drop any scheduled debounced save - we save unconditionally below.
    self:cancelPendingSave()
    self.dirty_groups = nil

    -- Save any in-progress stroke
    if self.current_stroke and #self.current_stroke.points >= 2 then
        logger.info("PenScribe: saving in-progress stroke before close")
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self.current_stroke = nil
    end

    self:teardownPenInput()

    -- Run any pending deferred image captures synchronously before close so
    -- we don't lose a fresh annotation. Must happen before the final save so
    -- new image_path / image_rotation fields land in the strokes file.
    self:queueStaleImageCaptures()
    self:flushPendingCaptures()

    -- Final bookmark sync before close
    self:syncAllBookmarks()

    -- Always save strokes on close (even if empty, to clear any previous data)
    logger.info("PenScribe: saving strokes on document close")
    self:saveStrokes()

    -- Clear state
    self.eraser_deleted = nil
    self.undo_stack = {}

    if _active_pencil == self then _active_pencil = nil end
end

function Pencil:onSuspend()
    -- Same idea as onCloseDocument: don't lose a freshly drawn annotation
    -- across a device sleep.
    self:queueStaleImageCaptures()
    self:flushPendingCaptures()
end

-- Handle reader ready (document fully loaded)
function Pencil:onReaderReady()
    logger.info("PenScribe: onReaderReady called")
    logger.info("PenScribe: doc_settings available:", self.ui.doc_settings ~= nil)
    if self.ui.doc_settings then
        logger.info("PenScribe: sidecar_dir:", self.ui.doc_settings.doc_sidecar_dir)
    end

    -- Force reload strokes (in case they weren't loaded in init)
    if #self.strokes == 0 then
        self:loadStrokes()
    end
    logger.info("PenScribe: after loadStrokes, strokes count =", #self.strokes,
        "groups =", #self.annotation_groups)

    -- Sync annotation group bookmarks now that UI modules are ready
    self:syncAllBookmarks()

    -- Re-setup touch zones if enabled
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end

    -- Lazy backfill: any group on the currently visible page that's missing
    -- an image (e.g. created in an older version, or capture was lost mid-
    -- session) gets re-captured now that ReaderView can paint the page.
    self:backfillMissingImages()

    if pending_goto_last_page then
        pending_goto_last_page = false
        UIManager:scheduleIn(0.1, function()
            self:jumpToLastPage()
        end)
    end
end

-- Handle read settings (document opened) - backup in case onReaderReady not called
function Pencil:onReadSettings(config)
    logger.dbg("PenScribe: onReadSettings called")
    -- Only load if not already loaded
    if not self.strokes or #self.strokes == 0 then
        self:loadStrokes()
    end
    -- Re-setup touch zones if enabled (in case they were torn down)
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end
end

-- Handle page changes (paging mode)
function Pencil:onPageUpdate(pageno)
    -- Clear any in-progress stroke when page changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        -- Save the stroke before clearing. The inline saveStrokes below covers
        -- everything in self.strokes, so drop any queued debounced save first.
        self:cancelPendingSave()
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        -- No in-progress stroke, but a debounced save may still be queued from
        -- earlier strokes on this page. Persist it before navigating away.
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self.eraser_deleted = nil
    self._erase_hit_streak = 0
    -- Re-schedule capture for any group on the newly visible page that's
    -- still missing an image (e.g. user turned past the original page before
    -- the debounce fired).
    self:backfillMissingImages()
end

-- Handle position changes (rolling/scroll mode)
function Pencil:onUpdatePos()
    -- Clear any in-progress stroke when position changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        self:cancelPendingSave()
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self.eraser_deleted = nil
    self:backfillMissingImages()
end

return Pencil
