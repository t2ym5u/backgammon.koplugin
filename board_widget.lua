local Blitbuffer     = require("ffi/blitbuffer")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local UIManager      = require("ui/uimanager")

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

    local face_size = math.max(10, math.floor(self.col_w * 0.35))
    self.label_face = Font:getFace("cfont", face_size)

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
            local label = tostring(pt.count)
            local m = RenderText:sizeUtf8Text(0, w, self.label_face, label, true, false)
            local tx = math.floor(cx - m.x / 2)
            local ty = math.floor(top and (y + h - m.y_bottom - 2) or (y + 2 - m.y_top))
            local tc = (pt.color == "white") and C_BLACK_CHECKER or C_WHITE_CHECKER
            RenderText:renderUtf8Text(bb, tx, ty + m.y_top, self.label_face, label, true, false, tc)
        end
    end
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
    if board.bar.white > 0 then
        drawChecker(bb, bar_cx, math.floor(y + self.height * 0.7), self.checker_r,
            "white", board.selected and board.selected.from == "bar" and board.turn == "white")
    end
    if board.bar.black > 0 then
        drawChecker(bb, bar_cx, math.floor(y + self.height * 0.3), self.checker_r,
            "black", board.selected and board.selected.from == "bar" and board.turn == "black")
    end

    -- Off-trays
    bb:paintRect(x + self.width - self.off_w, y, self.off_w, self.height, C_OFF_TRAY)
    local off_label = tostring(board.off.black) .. "/" .. tostring(board.off.white)
    local m = RenderText:sizeUtf8Text(0, self.off_w, self.label_face, off_label, true, false)
    RenderText:renderUtf8Text(bb, math.floor(x + self.width - self.off_w + math.max(0, (self.off_w - m.x) / 2)),
        math.floor(y + self.height / 2) + m.y_top, self.label_face, off_label, true, false, C_BORDER)

    -- Outer border
    bb:paintRect(x, y, self.width, 1, C_BORDER)
    bb:paintRect(x, y + self.height - 1, self.width, 1, C_BORDER)
    bb:paintRect(x, y, 1, self.height, C_BORDER)
    bb:paintRect(x + self.width - 1, y, 1, self.height, C_BORDER)
end

return BackgammonBoardWidget
