local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local UIManager      = require("ui/uimanager")

local Screen = Device.screen

local C_BG        = Blitbuffer.COLOR_WHITE
local C_BORDER     = Blitbuffer.COLOR_BLACK
local C_POINT_A      = Blitbuffer.COLOR_GRAY_E
local C_POINT_B        = Blitbuffer.COLOR_WHITE
local C_WHITE_CHECKER     = Blitbuffer.COLOR_WHITE
local C_BLACK_CHECKER       = Blitbuffer.COLOR_BLACK
local C_CHECKER_EDGE           = Blitbuffer.COLOR_BLACK
local C_SELECTED                  = Blitbuffer.COLOR_GRAY_5
local C_BAR                          = Blitbuffer.COLOR_GRAY_9
local C_OFF_TRAY                        = Blitbuffer.COLOR_GRAY_E

-- ---------------------------------------------------------------------------
-- BackgammonBoardWidget
--
-- Layout: two 6-column halves per row, separated by a central bar strip.
--   bottom row (left->right): points 12,11,10,9,8,7 | BAR | 6,5,4,3,2,1
--   top row    (left->right): points 13,14,15,16,17,18 | BAR | 19,20,21,22,23,24
-- Off-trays for bearing off sit at the far right of each row (white bears
-- off from the bottom-right home, black from the top-right home).
-- ---------------------------------------------------------------------------

local BackgammonBoardWidget = InputContainer:extend{
    board        = nil,
    onCellAction = nil,   -- called with "bar" | 1..24 | "off_white" | "off_black"
    width        = 560,
    height        = 360,
}

local BOTTOM_ORDER = { 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 }
local TOP_ORDER     = { 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24 }

local POINT_COL = {}
local POINT_ROW = {}
for col, p in ipairs(BOTTOM_ORDER) do POINT_COL[p] = col - 1; POINT_ROW[p] = "bottom" end
for col, p in ipairs(TOP_ORDER) do POINT_COL[p] = col - 1; POINT_ROW[p] = "top" end

local MAX_VISIBLE_CHECKERS = 5
local CHECKERS_PER_SIDE    = 15

-- Largest cfont face (starting at `size`) whose "15" fits in max_w x max_h.
local function fitFace(size, max_w, max_h)
    local face
    for sz = size, 6, -1 do
        face = Font:getFace("cfont", sz)
        local m = RenderText:sizeUtf8Text(0, 1000, face, "15", true, false)
        if m.x <= max_w and (m.y_top + m.y_bottom) <= max_h then break end
    end
    return face
end

-- Draws `label` centred on (cx, cy) by its ink box.
local function drawCentredLabel(bb, face, label, cx, cy, color)
    local m = RenderText:sizeUtf8Text(0, 1000, face, label, true, false)
    RenderText:renderUtf8Text(bb, math.floor(cx - m.x / 2),
        math.floor(cy + (m.y_top - m.y_bottom) / 2), face, label, true, false, color)
end

function BackgammonBoardWidget:init()
    local w, h = self.width, self.height
    self.off_w = math.floor(w * 0.05)
    self.bar_w = math.floor(w * 0.06)
    self.board_x0 = self.off_w
    local usable_w = w - 2 * self.off_w - self.bar_w
    self.col_w = math.floor(usable_w / 12)
    self.row_h = math.floor(h * 0.46)
    self.checker_r = math.max(4, math.floor(self.col_w * 0.32))

    self.dimen = Geom:new{ w = w, h = h }
    self.paint_rect = Geom:new{ x = 0, y = 0, w = w, h = h }

    -- Stack counts are drawn on top of a checker, off-tray counts inside
    -- the narrow tray: shrink each face until a two-digit count fits.
    -- Font:getFace scales its size by DPI; this one is derived from pixels.
    local face_size = math.max(10, math.floor(self.col_w * 0.35 / (Screen:scaleBySize(1000) / 1000)))
    self.label_face = fitFace(face_size, math.floor(self.checker_r * 1.5),
        math.floor(self.checker_r * 1.3))
    self.off_face   = fitFace(face_size, math.floor(self.off_w * 0.7), math.floor(self.height * 0.05))

    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges   = "tap",
                range = function() return self.paint_rect end,
            },
        },
    }
end

-- Returns the x0 (left edge) of the given column (0-11) within the board.
function BackgammonBoardWidget:_colX(col)
    local x = self.board_x0 + col * self.col_w
    if col >= 6 then x = x + self.bar_w end
    return x
end

function BackgammonBoardWidget:onTap(_, ges)
    if not (ges and ges.pos) then return false end
    local rect = self.paint_rect
    local lx = ges.pos.x - rect.x
    local ly = ges.pos.y - rect.y

    -- Off-trays: far right of either row.
    if lx >= self.width - self.off_w then
        local zone = (ly < self.height / 2) and "off_black" or "off_white"
        if self.onCellAction then self.onCellAction(zone) end
        return true
    end

    -- Bar: central strip.
    local bar_x0 = self.board_x0 + 6 * self.col_w
    if lx >= bar_x0 and lx < bar_x0 + self.bar_w then
        if self.onCellAction then self.onCellAction("bar") end
        return true
    end

    local row = (ly < self.height / 2) and "top" or "bottom"
    local col = math.floor((lx - self.board_x0 - (lx >= bar_x0 + self.bar_w and self.bar_w or 0)) / self.col_w)
    if col < 0 or col > 11 then return true end

    local order = (row == "top") and TOP_ORDER or BOTTOM_ORDER
    local point = order[col + 1]
    if point and self.onCellAction then self.onCellAction(point) end
    return true
end

function BackgammonBoardWidget:refresh()
    local rect = self.paint_rect
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    end)
end

local function drawChecker(bb, cx, cy, r, color, selected)
    if color == "white" then
        bb:paintCircle(cx, cy, r, C_WHITE_CHECKER)
        bb:paintCircle(cx, cy, r, C_CHECKER_EDGE, 1)
    else
        bb:paintCircle(cx, cy, r, C_BLACK_CHECKER)
    end
    if selected then
        bb:paintCircle(cx, cy, math.max(2, r - 2), C_SELECTED, 1)
    end
end

function BackgammonBoardWidget:_drawPoint(bb, x, y, point, col)
    local board = self.board
    local w, h = self.col_w, self.row_h
    local top = (POINT_ROW[point] == "top")
    local shade = (col % 2 == 0) and C_POINT_A or C_POINT_B

    -- Triangle approximated by shrinking horizontal bands (cheap, no
    -- polygon-fill primitive needed).
    local steps = 24
    for i = 0, steps - 1 do
        local frac = i / steps
        local band_w = math.max(1, math.floor(w * (1 - frac)))
        local band_x = math.floor(x + (w - band_w) / 2)
        local band_y = math.floor(top and (y + i * (h / steps)) or (y + h - (i + 1) * (h / steps)))
        bb:paintRect(band_x, band_y, band_w, math.ceil(h / steps) + 1, shade)
    end

    local pt = board.points[point]
    if pt.count > 0 then
        local cx = math.floor(x + w / 2)
        local n = math.min(pt.count, MAX_VISIBLE_CHECKERS)
        local step = math.max(1, math.floor(self.checker_r * 1.8))
        for i = 1, n do
            local cy = math.floor(top and (y + self.checker_r + (i - 1) * step)
                            or (y + h - self.checker_r - (i - 1) * step))
            local is_sel = board.selected and board.selected.from == point and i == n
            drawChecker(bb, cx, cy, self.checker_r, pt.color, is_sel)
        end
        if pt.count > MAX_VISIBLE_CHECKERS then
            -- Count goes on the outermost visible checker, in its
            -- contrasting colour (drawn on the bare point, white-on-white
            -- for a black stack, it was invisible).
            local cy = math.floor(top and (y + self.checker_r + (n - 1) * step)
                            or (y + h - self.checker_r - (n - 1) * step))
            local tc = (pt.color == "white") and C_BLACK_CHECKER or C_WHITE_CHECKER
            drawCentredLabel(bb, self.label_face, tostring(pt.count), cx, cy, tc)
        end
    end
end

-- One half of the off-tray: a thin bar per borne-off checker, stacked from
-- the tray's outer edge inward, with the count just inside the centre line.
function BackgammonBoardWidget:_drawOffHalf(bb, x, y, h, count, color, top)
    local pad     = math.max(2, math.floor(self.off_w * 0.12))
    local face    = self.off_face
    local m       = RenderText:sizeUtf8Text(0, 1000, face, "15", true, false)
    local label_h = m.y_top + m.y_bottom + 2 * pad
    local step    = math.max(2, math.floor((h - label_h - pad) / CHECKERS_PER_SIDE))
    local tile_h  = math.max(1, step - math.max(1, math.floor(step * 0.25)))
    local tile_w  = self.off_w - 2 * pad
    for i = 1, math.min(count, CHECKERS_PER_SIDE) do
        local ty = top and (y + pad + (i - 1) * step) or (y + h - pad - i * step + (step - tile_h))
        if color == "white" then
            bb:paintRect(x + pad, ty, tile_w, tile_h, C_CHECKER_EDGE)
            if tile_h > 2 then
                bb:paintRect(x + pad + 1, ty + 1, tile_w - 2, tile_h - 2, C_WHITE_CHECKER)
            end
        else
            bb:paintRect(x + pad, ty, tile_w, tile_h, C_BLACK_CHECKER)
        end
    end
    local label_cy = top and (y + h - label_h / 2) or (y + label_h / 2)
    drawCentredLabel(bb, face, tostring(count), x + self.off_w / 2, label_cy, C_BORDER)
end

function BackgammonBoardWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, C_BG)

    local board = self.board

    for col, point in ipairs(TOP_ORDER) do
        self:_drawPoint(bb, x + self:_colX(col - 1), y, point, col - 1)
    end
    for col, point in ipairs(BOTTOM_ORDER) do
        self:_drawPoint(bb, x + self:_colX(col - 1), y + self.height - self.row_h, point, col - 1)
    end

    -- Bar
    local bar_x = x + self.board_x0 + 6 * self.col_w
    bb:paintRect(bar_x, y, self.bar_w, self.height, C_BAR)
    local bar_cx = math.floor(bar_x + self.bar_w / 2)
    -- Only one checker per colour is drawn on the bar; a count on it says
    -- how many are actually waiting to re-enter.
    for _, side in ipairs({ { "white", 0.7 }, { "black", 0.3 } }) do
        local color, cnt = side[1], board.bar[side[1]]
        if cnt > 0 then
            local cy = math.floor(y + self.height * side[2])
            drawChecker(bb, bar_cx, cy, self.checker_r, color,
                board.selected and board.selected.from == "bar" and board.turn == color)
            if cnt > 1 then
                drawCentredLabel(bb, self.label_face, tostring(cnt), bar_cx, cy,
                    color == "white" and C_BLACK_CHECKER or C_WHITE_CHECKER)
            end
        end
    end

    -- Off-trays: black bears off top-right, white bottom-right. Kept inside
    -- the outer border (1px on each edge) so neither touches the frame.
    local off_x = x + self.width - self.off_w - 1
    local half  = math.floor((self.height - 2) / 2)
    bb:paintRect(off_x, y + 1, self.off_w, self.height - 2, C_OFF_TRAY)
    bb:paintRect(off_x, y + 1 + half, self.off_w, 1, C_BORDER)
    self:_drawOffHalf(bb, off_x, y + 1, half, board.off.black, "black", true)
    self:_drawOffHalf(bb, off_x, y + 1 + half + 1, self.height - 2 - half - 1,
        board.off.white, "white", false)

    -- Outer border
    bb:paintRect(x, y, self.width, 1, C_BORDER)
    bb:paintRect(x, y + self.height - 1, self.width, 1, C_BORDER)
    bb:paintRect(x, y, 1, self.height, C_BORDER)
    bb:paintRect(x + self.width - 1, y, 1, self.height, C_BORDER)
end

return BackgammonBoardWidget
